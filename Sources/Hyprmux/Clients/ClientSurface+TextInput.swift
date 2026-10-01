import AppKit
import HyprmuxClientProtocol

/// Text input for client tiles (docs/CLIENT_PROTOCOL.md, section 6.3).
///
/// A client process never has the key window, so it can't talk to input methods. The
/// tile is the `NSTextInputClient` instead. While a client has text input enabled,
/// every key goes through the input context first:
///
/// - A key the input method uses (a dead key, a composition, a press-and-hold accent)
///   goes out as `text_input.preedit` / `commit` / `delete_surrounding`, then `done`.
///   Its `keyboard.key` press and release are swallowed.
/// - Any other key stays a plain `keyboard.key`, so shortcuts and arrows don't change.
/// - Text from outside a key press (the emoji picker, dictation) commits directly.
///
/// The tile keeps no document. Ranges count characters committed since text input
/// was enabled, which is enough for press-and-hold to replace the last character.
final class TextInputState {
    var enabled = false
    /// The client can't draw preedit text, so the tile shows it in an overlay.
    var compositorPreedit = false
    /// The caret, in tile points (top-left origin), for the candidate window.
    var cursorRect: CGRect?
    var marked = ""
    var markedSelection = NSRange(location: 0, length: 0)
    /// Committed characters, for `selectedRange`.
    var cursor = 0
    /// Characters before the caret the next commit replaces.
    var pendingDelete = 0
    // Within one keyDown.
    var accumulating = false
    var accumulated: [String] = []
    var commandSeen = false
    /// The last key's outcome, for `hyprmuxctl surfaces`.
    var lastKey = ""
    var consumedKeyUps: Set<UInt16> = []
    var serial: UInt64 = 0
    var overlay: NSTextField?
}

extension ClientSurface: NSTextInputClient {
    // MARK: Protocol requests

    func setTextInput(enabled: Bool, compositorPreedit: Bool) {
        if !enabled { cancelComposition() }
        textInput.enabled = enabled
        textInput.compositorPreedit = compositorPreedit
        textInput.cursor = 0
    }

    func setTextCursorRect(_ rect: CGRect) {
        textInput.cursorRect = rect
        layoutPreeditOverlay()
        inputContext?.invalidateCharacterCoordinates()
    }

    // MARK: Key handling

    /// Runs a key press through the input method. True when the input method used it.
    func handleTextInput(_ event: NSEvent) -> Bool {
        guard textInput.enabled, connection != nil, let context = inputContext else { return false }
        // Command and control chords are shortcuts, unless a composition is open.
        if !event.modifierFlags.intersection([.command, .control]).isEmpty, textInput.marked.isEmpty { return false }
        let hadMarked = hasMarkedText()
        textInput.accumulating = true
        textInput.accumulated = []
        textInput.commandSeen = false
        let handled = context.handleEvent(event)
        textInput.accumulating = false
        let text = textInput.accumulated.joined()
        textInput.lastKey = "key \(event.keyCode) handled=\(handled) text=\(text.debugDescription) command=\(textInput.commandSeen) marked=\(textInput.marked.debugDescription)"
        // The input method swallowed the key: a repeat under the press-and-hold accent
        // picker, or a dead key (no characters of its own).
        let swallowed = handled && text.isEmpty && !textInput.commandSeen
            && (event.isARepeat || Self.isDeadKey(event))
        let usedByInputMethod = hadMarked || hasMarkedText() || textInput.pendingDelete > 0 || swallowed
            || (!text.isEmpty && text != (event.characters ?? ""))
        guard usedByInputMethod else {
            // A plain key: the client gets keyboard.key and inserts characters itself.
            textInput.cursor += text.count
            return false
        }
        textInput.consumedKeyUps.insert(event.keyCode)
        flushTextInput(commit: text)
        return true
    }

    /// A dead key has no characters of its own but a printable base key ("e" for ⌥E).
    /// Function and arrow keys (private-use characters) never qualify.
    static func isDeadKey(_ event: NSEvent) -> Bool {
        guard (event.characters ?? "").isEmpty, let base = event.charactersIgnoringModifiers?.unicodeScalars.first else { return false }
        return base.value >= 0x20 && base.value != 0x7F && !(0xF700...0xF8FF).contains(base.value)
    }

    /// Types text as one commit, like dictation does. For `hyprmuxctl send`. False when
    /// the client hasn't enabled text input.
    func commitText(_ text: String) -> Bool {
        guard textInput.enabled, connection != nil else { return false }
        cancelComposition()
        flushTextInput(commit: text)
        return true
    }

    /// Ends a composition without committing it (focus moved, text input turned off).
    func cancelComposition() {
        guard !textInput.marked.isEmpty else { return }
        inputContext?.discardMarkedText()
        textInput.marked = ""
        flushTextInput(commit: "")
    }

    /// Sends one atomic update: deletion, commit, the current preedit, then `done`.
    private func flushTextInput(commit text: String) {
        guard let connection else { return }
        if textInput.pendingDelete > 0 {
            connection.send(HMOp.textInputDeleteSurrounding, ["surface": surfaceID, "before": UInt64(textInput.pendingDelete), "after": UInt64(0)])
            textInput.cursor = max(0, textInput.cursor - textInput.pendingDelete)
            textInput.pendingDelete = 0
        }
        if !text.isEmpty {
            connection.send(HMOp.textInputCommit, ["surface": surfaceID, "text": text])
            textInput.cursor += text.count
        }
        let sel = textInput.markedSelection
        connection.send(HMOp.textInputPreedit, [
            "surface": surfaceID, "text": textInput.marked,
            "cursor_begin": UInt64(sel.location), "cursor_end": UInt64(sel.location + sel.length),
        ])
        textInput.serial += 1
        connection.send(HMOp.textInputDone, ["surface": surfaceID, "serial": textInput.serial])
        updatePreeditOverlay()
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let s = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        // Press-and-hold replaces the character it was opened on.
        if textInput.marked.isEmpty, replacementRange.location != NSNotFound, replacementRange.length > 0,
           replacementRange.location + replacementRange.length <= textInput.cursor {
            textInput.pendingDelete += replacementRange.length
        }
        textInput.marked = ""
        textInput.markedSelection = NSRange(location: 0, length: 0)
        if textInput.accumulating { textInput.accumulated.append(s) } else { flushTextInput(commit: s) }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        textInput.marked = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        textInput.markedSelection = selectedRange
        if !textInput.accumulating { flushTextInput(commit: "") }
    }

    func unmarkText() {
        let t = textInput.marked
        textInput.marked = ""
        guard !t.isEmpty else { return }
        if textInput.accumulating { textInput.accumulated.append(t) } else { flushTextInput(commit: t) }
    }

    func selectedRange() -> NSRange {
        textInput.marked.isEmpty
            ? NSRange(location: textInput.cursor, length: 0)
            : NSRange(location: textInput.cursor + textInput.markedSelection.location, length: textInput.markedSelection.length)
    }

    func markedRange() -> NSRange {
        textInput.marked.isEmpty ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: textInput.cursor, length: (textInput.marked as NSString).length)
    }

    func hasMarkedText() -> Bool { !textInput.marked.isEmpty }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        // Without a caret from the client, use the tile's top-left corner.
        let caret = textInput.cursorRect ?? CGRect(x: 8, y: 8, width: 1, height: 18)
        return window.convertToScreen(convert(caret, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    /// Commands (moveLeft:, insertNewline:, ...) mean the key wasn't text. The plain
    /// keyboard.key carries it.
    override func doCommand(by selector: Selector) { textInput.commandSeen = true }

    // MARK: Preedit overlay

    /// For clients that can't draw a composition (Electron): the composing text,
    /// underlined, at the caret.
    private func updatePreeditOverlay() {
        guard textInput.compositorPreedit, !textInput.marked.isEmpty else {
            textInput.overlay?.removeFromSuperview()
            textInput.overlay = nil
            return
        }
        let label = textInput.overlay ?? {
            let l = NSTextField(labelWithString: "")
            l.wantsLayer = true
            l.drawsBackground = true
            l.backgroundColor = NSColor(white: 0.12, alpha: 0.95)
            l.layer?.cornerRadius = 3
            addSubview(l)
            textInput.overlay = l
            return l
        }()
        let size = max(12, (textInput.cursorRect?.height ?? 18) * 0.8)
        label.attributedStringValue = NSAttributedString(string: textInput.marked, attributes: [
            .font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.white,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        layoutPreeditOverlay()
    }

    private func layoutPreeditOverlay() {
        guard let label = textInput.overlay else { return }
        label.sizeToFit()
        let caret = textInput.cursorRect ?? CGRect(x: 8, y: 8, width: 1, height: 18)
        var f = CGRect(x: caret.minX, y: caret.minY + (caret.height - label.frame.height) / 2,
                       width: label.frame.width + 4, height: label.frame.height)
        f.origin.x = min(max(0, f.origin.x), max(0, bounds.width - f.width))
        f.origin.y = min(max(0, f.origin.y), max(0, bounds.height - f.height))
        label.frame = f
    }
}
