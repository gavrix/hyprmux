import AppKit
import GhosttyKit
import HyprmuxCore

/// Callbacks from a terminal to whoever manages it.
protocol TerminalViewHost: AnyObject {
    func terminalDidRequestFocus(_ view: TerminalView)
    func terminalTitleDidChange(_ view: TerminalView)
    func terminalDidClose(_ view: TerminalView, processAlive: Bool)
    /// Ghostty asked for a new window/tab/split from this terminal.
    func terminalDidRequestSpawn(_ view: TerminalView)
    func terminal(_ view: TerminalView, perform dispatcher: Dispatcher)
    func terminalDidToggleWindowFullscreen(_ view: TerminalView)
    /// A link was opened (cmd+click). Return true if handled, else it goes to macOS.
    func terminal(_ view: TerminalView, openURL url: URL) -> Bool
    /// A desktop notification (OSC 9 / OSC 777).
    func terminal(_ view: TerminalView, notifyTitle title: String, body: String)
}

struct SurfaceOptions {
    var workingDirectory: String?
    var command: String?
    var fontSize: Float = 0  // 0 = inherit from config
    /// Typed into the shell as its first input (a restored program: "nvim .\n").
    var initialInput: String?
    var env: [String: String] = [:]

    /// Takes cwd and font size from an existing surface, like a Ghostty split.
    static func inherited(from parent: TerminalView?) -> SurfaceOptions {
        var o = SurfaceOptions()
        guard let s = parent?.surface else { return o }
        let cfg = ghostty_surface_inherited_config(s, GHOSTTY_SURFACE_CONTEXT_SPLIT)
        if let wd = cfg.working_directory { o.workingDirectory = String(cString: wd) }
        o.fontSize = cfg.font_size
        return o
    }
}

/// An NSView that hosts one libghostty surface. libghostty installs its own
/// Metal layer on this view and renders on its own thread.
///
/// Key and IME handling is ported from Ghostty's SurfaceView_AppKit.swift (MIT).
final class TerminalView: NSView, NSTextInputClient {
    let clientID: ClientID
    private(set) var surface: ghostty_surface_t?
    weak var host: TerminalViewHost?

    private(set) var title = ""
    private(set) var pwd: String?
    private(set) var cellSize: CGSize = .zero
    private(set) var focused = false
    /// Terminal background, set by the compositor (see Surface.backdropColor).
    var backdrop: NSColor = .black

    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var lastPerformKeyEvent: TimeInterval?
    private var contentSize: CGSize = .zero

    init(app: ghostty_app_t, id: ClientID, options: SurfaceOptions) {
        self.clientID = id
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        setAccessibilityIdentifier("hyprmux-terminal-\(id.raw)")

        var cfg = ghostty_surface_config_new()
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        cfg.font_size = options.fontSize
        cfg.context = GHOSTTY_SURFACE_CONTEXT_SPLIT
        cfg.wait_after_command = false

        let wd = options.workingDirectory.flatMap { strdup($0) }
        let cmd = options.command.flatMap { $0.isEmpty ? nil : strdup($0) }
        let input = options.initialInput.flatMap { $0.isEmpty ? nil : strdup($0) }
        let envC = options.env.map { (strdup($0.key), strdup($0.value)) }
        defer {
            free(wd); free(cmd); free(input)
            for (k, v) in envC { free(k); free(v) }
        }
        cfg.working_directory = UnsafePointer(wd)
        cfg.command = UnsafePointer(cmd)
        cfg.initial_input = UnsafePointer(input)
        var envVars = envC.map { ghostty_env_var_s(key: UnsafePointer($0.0), value: UnsafePointer($0.1)) }
        surface = envVars.withUnsafeMutableBufferPointer { buf -> ghostty_surface_t? in
            cfg.env_vars = buf.baseAddress
            cfg.env_var_count = buf.count
            return ghostty_surface_new(app, &cfg)
        }

        updateTrackingAreas()
        registerForDraggedTypes(TerminalPasteboard.dropTypes)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: Drag and drop

    // Dropped files insert their paths, text inserts as is, and a dragged image is saved
    // to a temporary file whose path is inserted, like a paste (see TerminalPasteboard).
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let types = Set(sender.draggingPasteboard.types ?? [])
        return types.isDisjoint(with: TerminalPasteboard.dropTypes) ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let s = surface, let text = TerminalPasteboard.contents(sender.draggingPasteboard) else { return false }
        // As a paste (bracketed when the program asks for it), like Ghostty.
        text.withCString { ghostty_surface_text(s, $0, UInt(text.utf8.count)) }
        return true
    }

    /// Frees the libghostty surface. Call once when the client is gone.
    func destroy() {
        guard let s = surface else { return }
        surface = nil
        ghostty_surface_free(s)
    }

    /// Process group in the terminal's foreground (the shell when idle, else what it runs). 0 if unknown.
    var foregroundPID: pid_t {
        guard let s = surface else { return 0 }
        return pid_t(truncatingIfNeeded: ghostty_surface_foreground_pid(s))
    }

    func requestClose() {
        guard let s = surface else { return }
        ghostty_surface_request_close(s)
    }

    /// Types text as keyboard input (not a paste). Uses the cmux fork's text_input API.
    func sendText(_ text: String) {
        guard let s = surface else { return }
        text.withCString { ghostty_surface_text_input(s, $0, UInt(text.utf8.count)) }
    }

    func setTerminalOccluded(_ occluded: Bool) {
        guard let s = surface else { return }
        ghostty_surface_set_occlusion(s, !occluded)
    }

    @discardableResult
    func performBindingAction(_ action: String) -> Bool {
        guard let s = surface else { return false }
        return action.withCString { ghostty_surface_binding_action(s, $0, UInt(action.utf8.count)) }
    }

    // MARK: Called by the runtime (main thread)

    func runtimeSetTitle(_ t: String) {
        title = t
        host?.terminalTitleDidChange(self)
    }

    func runtimeSetPwd(_ p: String) { pwd = p }
    /// The link under the pointer while the link modifier (Cmd) is held, else nil.
    private(set) var hoveredLink: String?
    func runtimeSetHoveredLink(_ l: String?) { hoveredLink = l }
    func runtimeSetCellSize(_ s: CGSize) { cellSize = s }

    func runtimeSetMouseShape(_ shape: ghostty_action_mouse_shape_e) {
        let cursor: NSCursor
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_TEXT, GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: cursor = .iBeam
        case GHOSTTY_MOUSE_SHAPE_POINTER: cursor = .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR, GHOSTTY_MOUSE_SHAPE_CELL: cursor = .crosshair
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP: cursor = .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_GRAB: cursor = .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: cursor = .closedHand
        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE, GHOSTTY_MOUSE_SHAPE_COL_RESIZE: cursor = .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE, GHOSTTY_MOUSE_SHAPE_ROW_RESIZE: cursor = .resizeUpDown
        default: cursor = .arrow
        }
        currentCursor = cursor
        window?.invalidateCursorRects(for: self)
    }

    private var currentCursor: NSCursor = .iBeam

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: currentCursor)
    }

    // MARK: Focus

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { focusDidChange(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { focusDidChange(false) }
        return ok
    }

    private func focusDidChange(_ f: Bool) {
        guard focused != f, let s = surface else { return }
        focused = f
        ghostty_surface_set_focus(s, f)
    }

    // MARK: Size and scale

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        sizeDidChange(newSize)
    }

    private func sizeDidChange(_ size: CGSize) {
        guard let s = surface, size.width > 0, size.height > 0 else { return }
        contentSize = size
        let px = convertToBacking(size)
        ghostty_surface_set_size(s, UInt32(px.width), UInt32(px.height))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
    }

    private func updateScale() {
        guard let window, let s = surface else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = window.backingScaleFactor
        CATransaction.commit()
        let fb = convertToBacking(frame)
        if frame.width > 0, frame.height > 0 {
            ghostty_surface_set_content_scale(s, fb.width / frame.width, fb.height / frame.height)
        }
        if contentSize != .zero { sizeDidChange(contentSize) } else { sizeDidChange(frame.size) }
        if let screen = window.screen,
           let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            ghostty_surface_set_display_id(s, id.uint32Value)
        }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
            owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if !focused { host?.terminalDidRequestFocus(self) }
        guard let s = surface else { return }
        ghostty_surface_mouse_button(s, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GhosttyInput.mods(event.modifierFlags))
    }

    override func mouseUp(with event: NSEvent) {
        guard let s = surface else { return }
        ghostty_surface_mouse_button(s, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GhosttyInput.mods(event.modifierFlags))
        ghostty_surface_mouse_pressure(s, 0, 0)
    }

    override func rightMouseDown(with event: NSEvent) {
        if !focused { host?.terminalDidRequestFocus(self) }
        guard let s = surface,
              ghostty_surface_mouse_button(s, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, GhosttyInput.mods(event.modifierFlags))
        else { return super.rightMouseDown(with: event) }
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let s = surface,
              ghostty_surface_mouse_button(s, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, GhosttyInput.mods(event.modifierFlags))
        else { return super.rightMouseUp(with: event) }
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let s = surface else { return }
        ghostty_surface_mouse_button(s, GHOSTTY_MOUSE_PRESS, GhosttyInput.mouseButton(event.buttonNumber), GhosttyInput.mods(event.modifierFlags))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let s = surface else { return }
        ghostty_surface_mouse_button(s, GHOSTTY_MOUSE_RELEASE, GhosttyInput.mouseButton(event.buttonNumber), GhosttyInput.mods(event.modifierFlags))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        sendMousePos(event)
    }

    override func mouseExited(with event: NSEvent) {
        guard let s = surface, NSEvent.pressedMouseButtons == 0 else { return }
        ghostty_surface_mouse_pos(s, -1, -1, GhosttyInput.mods(event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) { sendMousePos(event) }
    override func mouseDragged(with event: NSEvent) { sendMousePos(event) }
    override func rightMouseDragged(with event: NSEvent) { sendMousePos(event) }
    override func otherMouseDragged(with event: NSEvent) { sendMousePos(event) }

    private func sendMousePos(_ event: NSEvent) {
        guard let s = surface else { return }
        let p = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(s, p.x, frame.height - p.y, GhosttyInput.mods(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let s = surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise { x *= 2; y *= 2 }
        ghostty_surface_mouse_scroll(s, x, y, GhosttyInput.scrollMods(precision: precise, momentum: event.momentumPhase))
    }

    override func pressureChange(with event: NSEvent) {
        guard let s = surface else { return }
        ghostty_surface_mouse_pressure(s, UInt32(event.stage), Double(event.pressure))
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let s = surface else {
            interpretKeyEvents([event])
            return
        }

        // Some configs (e.g. macos-option-as-alt) change which mods translate to text.
        let translationGhostty = GhosttyInput.flags(ghostty_surface_key_translation_mods(s, GhosttyInput.mods(event.modifierFlags)))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translationGhostty.contains(flag) { translationMods.insert(flag) } else { translationMods.remove(flag) }
        }
        // Reuse the original event when possible; AppKit IMEs (e.g. Korean) rely on identity.
        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type, location: event.locationInWindow, modifierFlags: translationMods,
                timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        let markedTextBefore = markedText.length > 0
        lastPerformKeyEvent = nil

        interpretKeyEvents([translationEvent])

        syncPreedit(clearIfNeeded: markedTextBefore)
        let composing = markedText.length > 0 || markedTextBefore

        if let list = keyTextAccumulator, !list.isEmpty {
            for text in list {
                if Self.suppressComposingControl(text, composing: composing) { continue }
                if markedTextBefore {
                    _ = committedPreeditText(action, text: text)
                } else {
                    _ = keyAction(action, event: event, translationEvent: translationEvent, text: text)
                }
            }
        } else {
            if Self.suppressComposingControl(event.characters, composing: composing) { return }
            _ = keyAction(action, event: event, translationEvent: translationEvent,
                          text: translationEvent.ghosttyCharacters, composing: composing)
        }
    }

    override func keyUp(with event: NSEvent) {
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        if hasMarkedText() { return }
        let mods = GhosttyInput.mods(event.modifierFlags)
        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            let sidePressed: Bool
            switch event.keyCode {
            case 0x3C: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
            default: sidePressed = true
            }
            if sidePressed { action = GHOSTTY_ACTION_PRESS }
        }
        _ = keyAction(action, event: event)
    }

    /// Command/control keys arrive here first. Ghostty bindings (cmd+c, cmd+v, ...)
    /// are handled directly; everything else goes back through AppKit.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, focused, let s = surface else { return false }

        var ev = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
        var flags = ghostty_binding_flags_e(0)
        let isBinding = (event.characters ?? "").withCString { ptr -> Bool in
            ev.text = ptr
            return ghostty_surface_key_is_binding(s, ev, &flags)
        }
        if isBinding {
            keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"
        case "/":
            guard event.modifierFlags.contains(.control),
                  event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) else { return false }
            equivalent = "_"
        default:
            if event.timestamp == 0 { return false }
            if !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.control) {
                lastPerformKeyEvent = nil
                return false
            }
            if let last = lastPerformKeyEvent {
                lastPerformKeyEvent = nil
                if last == event.timestamp {
                    equivalent = event.characters ?? ""
                    break
                }
            }
            lastPerformKeyEvent = event.timestamp
            return false
        }

        guard let final = NSEvent.keyEvent(
            with: .keyDown, location: event.locationInWindow, modifierFlags: event.modifierFlags,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: equivalent, charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat, keyCode: event.keyCode) else { return false }
        keyDown(with: final)
        return true
    }

    private func keyAction(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationEvent: NSEvent? = nil,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let s = surface else { return false }
        var ev = event.ghosttyKeyEvent(action, translationMods: translationEvent?.modifierFlags)
        ev.composing = composing
        if let text, !text.isEmpty, !text.startsWithASCIIControl {
            return text.withCString { ptr in
                ev.text = ptr
                return ghostty_surface_key(s, ev)
            }
        }
        return ghostty_surface_key(s, ev)
    }

    private func committedPreeditText(_ action: ghostty_input_action_e, text: String) -> Bool {
        guard let s = surface else { return false }
        var ev = ghostty_input_key_s()
        ev.action = action
        ev.mods = GHOSTTY_MODS_NONE
        ev.consumed_mods = GHOSTTY_MODS_NONE
        return text.withCString { ptr in
            ev.text = ptr
            return ghostty_surface_key(s, ev)
        }
    }

    private static func suppressComposingControl(_ text: String?, composing: Bool) -> Bool {
        guard composing, let text, text.unicodeScalars.count == 1, let sc = text.unicodeScalars.first else { return false }
        return sc.value < 0x20
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let s = surface else { return }
        if markedText.length > 0 {
            let str = markedText.string
            str.withCString { ptr in ghostty_surface_preedit(s, ptr, UInt(str.utf8.count)) }
        } else if clearIfNeeded {
            ghostty_surface_preedit(s, nil, 0)
        }
    }

    // MARK: Menu actions (responder chain)

    @objc func copy(_ sender: Any?) { performBindingAction("copy_to_clipboard") }
    @objc func paste(_ sender: Any?) { performBindingAction("paste_from_clipboard") }
    @objc override func selectAll(_ sender: Any?) { performBindingAction("select_all") }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }

    override func accessibilityHelp() -> String? { "Terminal content area" }

    override func accessibilityValue() -> Any? { accessibilitySelectedText() ?? "" }

    override func accessibilitySelectedTextRange() -> NSRange { selectedRange() }

    override func accessibilitySelectedText() -> String? {
        guard let s = surface else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(s, &text) else { return nil }
        defer { ghostty_surface_free_text(s, &text) }
        guard let ptr = text.text, text.text_len > 0 else { return nil }
        return String(decoding: Data(bytes: ptr, count: Int(text.text_len)), as: UTF8.self)
    }

    // MARK: NSTextInputClient

    func hasMarkedText() -> Bool { markedText.length > 0 }

    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange()
    }

    func selectedRange() -> NSRange {
        guard let s = surface else { return NSRange() }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(s, &text) else { return NSRange() }
        defer { ghostty_surface_free_text(s, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString: markedText = NSMutableAttributedString(attributedString: v)
        case let v as String: markedText = NSMutableAttributedString(string: v)
        default: return
        }
        if keyTextAccumulator == nil { syncPreedit() }
    }

    func unmarkText() {
        if markedText.length > 0 {
            markedText.mutableString.setString("")
            syncPreedit()
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let s = surface, range.length > 0 else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(s, &text) else { return nil }
        defer { ghostty_surface_free_text(s, &text) }
        return NSAttributedString(string: String(cString: text.text))
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let s = surface else { return NSRect(origin: frame.origin, size: .zero) }
        var x = 0.0, y = 0.0, w = Double(cellSize.width), h = Double(cellSize.height)
        ghostty_surface_ime_point(s, &x, &y, &w, &h)
        if range.length == 0 { w = 0 }
        let viewRect = NSRect(x: x, y: frame.height - y, width: w, height: max(h, Double(cellSize.height)))
        let winRect = convert(viewRect, to: nil)
        return window?.convertToScreen(winRect) ?? winRect
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil, let s = surface else { return }
        let chars: String
        switch string {
        case let v as NSAttributedString: chars = v.string
        case let v as String: chars = v
        default: return
        }
        let hadMarked = hasMarkedText()
        unmarkText()
        if var acc = keyTextAccumulator {
            acc.append(chars)
            keyTextAccumulator = acc
            return
        }
        if hadMarked, !chars.isEmpty {
            _ = committedPreeditText(GHOSTTY_ACTION_PRESS, text: chars)
            return
        }
        chars.withCString { ghostty_surface_text(s, $0, UInt(chars.utf8.count)) }
    }

    /// Swallows unhandled selectors (no beep) and re-sends command keys that
    /// performKeyEquivalent passed through, so they get encoded.
    override func doCommand(by selector: Selector) {
        if let last = lastPerformKeyEvent, let current = NSApp.currentEvent, last == current.timestamp {
            NSApp.sendEvent(current)
        }
    }
}
