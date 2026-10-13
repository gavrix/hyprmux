import AppKit

/// What a surface reports back to its tile's find bar.
protocol FindBarHost: AnyObject {
    /// Match count text ("2/14"), or empty.
    func findStatusChanged(_ status: String)
    /// The surface opened a search itself (Ghostty's `search_selection`), with an optional query.
    func surfaceRequestsFind(query: String?)
    /// The surface ended its search (Ghostty's `end_search`).
    func surfaceEndedFind()
}

/// A surface that can search its content. Its tile (`ClientView`) shows the find bar
/// and calls these; the surface only matches and highlights.
protocol FindableSurface: Surface {
    var findHost: FindBarHost? { get set }
    /// `next` false: a new query, highlight its matches. True: go to the next or previous match.
    func find(_ text: String, forward: Bool, next: Bool)
    /// Clear match highlights.
    func endFind()
}

/// Find-in-tile bar along the bottom of a tile, like vim's command line:
/// "/", the query, the match count, previous/next, close.
final class FindBar: FlippedView, NSTextFieldDelegate {
    let field = AddressField()
    private let prompt = NSTextField(labelWithString: "/")
    private let previous = BarButton(symbol: "chevron.up", label: "Previous match")
    private let next = BarButton(symbol: "chevron.down", label: "Next match")
    private let done = BarButton(symbol: "xmark", label: "Close find bar")
    private let statusLabel = NSTextField(labelWithString: "")
    private let topLine = NSView()

    /// The query changed.
    var onChange: ((String) -> Void)?
    /// Return / Shift+Return, or the arrow buttons.
    var onNavigate: ((_ forward: Bool) -> Void)?
    /// Esc or the close button.
    var onClose: (() -> Void)?
    /// Keeps the controls clear of the tile's rounded bottom corners.
    var sideInset: CGFloat = 0 { didSet { if sideInset != oldValue { needsLayout = true } } }

    static let height: CGFloat = 30

    var query: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    var status: String {
        get { statusLabel.stringValue }
        set { statusLabel.stringValue = newValue; needsLayout = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.95).cgColor
        topLine.wantsLayer = true
        topLine.layer?.backgroundColor = NSColor(white: 1, alpha: 0.1).cgColor

        prompt.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        prompt.textColor = NSColor(srgbRed: 0.2, green: 0.8, blue: 1, alpha: 1)
        field.placeholderString = "Find"
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.focusRingType = .none
        field.isBordered = false
        field.drawsBackground = false
        field.textColor = NSColor(white: 0.92, alpha: 1)
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        field.onCancel = { [weak self] in self?.onClose?() }
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = NSColor(white: 0.55, alpha: 1)
        statusLabel.alignment = .right

        previous.target = self
        previous.action = #selector(previousClicked)
        next.target = self
        next.action = #selector(nextClicked)
        done.target = self
        done.action = #selector(closeClicked)
        for v in [topLine, prompt, field, statusLabel, previous, next, done] as [NSView] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Puts the cursor in the field with the query selected.
    func focusField() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    override func layout() {
        super.layout()
        let h = bounds.height, button: CGFloat = 22, side = max(8, sideInset)
        topLine.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
        var x = bounds.width - side + 4  // the symbols have their own padding
        for b in [done, next, previous] {
            x -= button
            b.frame = CGRect(x: x, y: (h - button) / 2, width: button, height: button)
        }
        let statusWidth = status.isEmpty ? 0 : ceil(statusLabel.intrinsicContentSize.width)
        x -= statusWidth + (statusWidth > 0 ? 8 : 0)
        statusLabel.frame = CGRect(x: x, y: (h - 16) / 2, width: statusWidth, height: 16)
        prompt.sizeToFit()
        prompt.frame.origin = CGPoint(x: side, y: (h - prompt.frame.height) / 2)
        let fieldX = prompt.frame.maxX + 4, fieldHeight: CGFloat = 18
        field.frame = CGRect(x: fieldX, y: (h - fieldHeight) / 2, width: max(0, x - fieldX - 6), height: fieldHeight)
    }

    // Clicks on the bar's background must not reach the content below.
    override func mouseDown(with event: NSEvent) {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func previousClicked() { onNavigate?(false) }
    @objc private func nextClicked() { onNavigate?(true) }
    @objc private func closeClicked() { onClose?() }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ note: Notification) { onChange?(field.stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            // Return: next match. Shift+Return: previous.
            onNavigate?(!(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false))
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}
