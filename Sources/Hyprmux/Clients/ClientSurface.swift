import AppKit
import HyprmuxClientProtocol
import HyprmuxCore
import IOSurface
import QuartzCore

/// A tile drawn by an external client process (docs/CLIENT_PROTOCOL.md).
///
/// The compositor creates one per toplevel. A tile opened with `new-surface --type app`
/// exists before its client connects: it waits, with a launch token, for the first
/// toplevel that presents that token.
final class ClientSurface: FlippedView, Surface {
    let clientID: ClientID
    /// Set while the tile waits for a launched client.
    private(set) var launchToken: String?
    var onClose: ((ClientSurface) -> Void)?

    /// Bound toplevel. Nil while pending, and after the client leaves.
    private(set) weak var connection: ClientConnection?
    private(set) var toplevelID: UInt64 = 0
    /// The client's `surface` object under the toplevel. Input events name it.
    private(set) var surfaceID: UInt64 = 0
    private(set) var appID = ""
    private var launchLabel: String
    /// What `new-surface --type app` ran, shared by every tile of that launch. The
    /// session saves it with the restore token, and relaunches it on restore.
    var launchArgument: String?
    /// The client's restore token, or the saved one while a restored tile waits.
    var restoreToken: String?

    private let screen = PassthroughView()
    private let placeholder = NSTextField(labelWithString: "")
    private var clientTitle = ""
    private var closed = false

    // Surface state (current, after the last commit).
    private var currentBuffer: ClientConnection.Buffer?
    private var currentScale: CGFloat = 1
    // Committed frame callbacks waiting for the next display refresh.
    private var frameCallbacks: [UInt64] = []
    // Buffers replaced by a newer commit; released once Core Animation stops using them.
    private var retiring: [ClientConnection.Buffer] = []
    private var link: CADisplayLink?

    // Configure state.
    private var serial: UInt64 = 0
    private var ackedSerial: UInt64 = 0
    private var sentSize = CGSize.zero
    private var sentScale: CGFloat = 0
    private var sentStates: [String] = []
    private var occluded = false
    private var activated = false

    // Input state.
    private var cursorName = "arrow"
    private var tracking: NSTrackingArea?
    private var pointerInside = false
    private var inputSerial: UInt64 = 0
    private(set) var framesShown = 0
    /// IME state (ClientSurface+TextInput).
    let textInput = TextInputState()

    init(id: ClientID, launchToken: String?, label: String, launchArgument: String? = nil, restoreToken: String? = nil) {
        clientID = id
        self.launchToken = launchToken
        launchLabel = label
        self.launchArgument = launchArgument
        self.restoreToken = restoreToken
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        wantsLayer = true
        layer?.backgroundColor = backdropColor.cgColor
        screen.wantsLayer = true
        screen.layer?.contentsGravity = .resizeAspect
        screen.layer?.magnificationFilter = .linear
        addSubview(screen)
        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center
        placeholder.stringValue = launchToken == nil ? "" : "Starting \(label)…"
        addSubview(placeholder)
        layoutContent()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutContent()
        sendConfigureIfNeeded()
    }

    private func layoutContent() {
        screen.frame = bounds
        placeholder.sizeToFit()
        placeholder.frame.origin = CGPoint(x: (bounds.width - placeholder.frame.width) / 2,
                                           y: (bounds.height - placeholder.frame.height) / 2)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, link == nil {
            link = displayLink(target: self, selector: #selector(tick(_:)))
            link?.add(to: .main, forMode: .common)
            link?.isPaused = true
        }
        sendConfigureIfNeeded()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        sendConfigureIfNeeded()
    }

    // MARK: Binding

    /// The client's toplevel takes over this tile.
    func bind(connection: ClientConnection, toplevel: UInt64, surface: UInt64, appID: String) {
        self.connection = connection
        toplevelID = toplevel
        surfaceID = surface
        self.appID = appID
        launchToken = nil
        placeholder.stringValue = ""
        sentSize = .zero  // force a configure
        sendConfigureIfNeeded()
    }

    /// A launch token for a tile that is still waiting (a restored session relaunches).
    func setLaunchToken(_ token: String) { launchToken = token }

    /// The pending tile gave up waiting.
    func launchFailed(_ message: String) {
        placeholder.stringValue = message
        layoutContent()
    }

    /// The toplevel was destroyed, or the client disconnected.
    func clientLeft() {
        guard !closed else { return }
        connection = nil
        closed = true
        releaseAllBuffers()
        onClose?(self)
    }

    // MARK: Surface

    var view: NSView { self }
    var focusTarget: NSView { self }
    var title: String { clientTitle.isEmpty ? launchLabel : clientTitle }
    var kind: String { "app" }
    var automationCapabilities: [String] { textInput.enabled ? ["send_text"] : [] }
    var backdropColor: NSColor { NSColor(white: 0.08, alpha: 1) }
    var info: [String: Any] {
        var result: [String: Any] = ["app": appID.isEmpty ? launchLabel : appID, "state": connection == nil ? "pending" : "connected",
                                     "framesShown": framesShown]
        if let c = connection { result["pid"] = Int(c.pid) }
        if let launchArgument { result["launch"] = launchArgument }
        if let restoreToken { result["restoreToken"] = restoreToken }
        if let b = currentBuffer { result["pixels"] = [b.width, b.height]; result["scale"] = Double(currentScale) }
        if textInput.enabled {
            var t: [String: Any] = ["preedit": textInput.compositorPreedit ? "compositor" : "client",
                                    "inputContext": inputContext != nil]
            if !textInput.marked.isEmpty { t["composing"] = textInput.marked }
            if !textInput.lastKey.isEmpty { t["lastKey"] = textInput.lastKey }
            if let r = textInput.cursorRect { t["cursorRect"] = [r.minX, r.minY, r.width, r.height] }
            result["textInput"] = t
        }
        return result
    }

    func setOccluded(_ occluded: Bool) {
        guard occluded != self.occluded else { return }
        self.occluded = occluded
        updateLink()
        sendConfigureIfNeeded()
    }

    func requestClose() {
        if let connection, toplevelID != 0 {
            connection.send(HMOp.toplevelCloseRequested, ["id": toplevelID])
        } else {
            clientLeft()
        }
    }

    func destroy() {
        closed = true
        link?.invalidate()
        link = nil
        releaseAllBuffers()
        connection?.surfaceDestroyed(self)
        connection = nil
    }

    // MARK: Protocol, from ClientConnection

    func setClientTitle(_ title: String) { clientTitle = title }

    func ackConfigure(_ serial: UInt64) { ackedSerial = max(ackedSerial, serial) }

    /// Makes the pending state current: a new buffer, scale, and frame callbacks.
    func commit(buffer: ClientConnection.Buffer?, scale: CGFloat, callbacks: [UInt64]) {
        guard !closed else { return }
        frameCallbacks += callbacks
        if let buffer, buffer !== currentBuffer {
            if let old = currentBuffer { retiring.append(old) }
            currentBuffer = buffer
            currentScale = scale
            buffer.busy = true
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // Re-assigning makes Core Animation re-read the surface, even the same one.
            screen.layer?.contents = nil
            screen.layer?.contents = buffer.surface
            screen.layer?.contentsScale = scale
            CATransaction.commit()
            framesShown += 1
        }
        updateLink()
    }

    /// A buffer the client destroyed: stop showing it.
    func bufferDestroyed(_ buffer: ClientConnection.Buffer) {
        retiring.removeAll { $0 === buffer }
        if currentBuffer === buffer {
            currentBuffer = nil
            screen.layer?.contents = nil
        }
    }

    // MARK: Frame pacing

    private func updateLink() {
        link?.isPaused = (frameCallbacks.isEmpty || occluded) && retiring.isEmpty
    }

    @objc private func tick(_ link: CADisplayLink) {
        releaseRetired()
        if !occluded, !frameCallbacks.isEmpty, let connection {
            let now = CACurrentMediaTime()
            for cb in frameCallbacks {
                connection.send(HMOp.surfaceFrameDone, ["callback": cb, "time": now, "target_time": link.targetTimestamp])
            }
            frameCallbacks.removeAll()
        }
        updateLink()
    }

    private var pollingRetired = false

    /// Releases replaced buffers Core Animation no longer reads: the render server holds
    /// a use count while a surface is on screen. It lets go a few ms after a refresh, so
    /// checking only on display-link ticks would hold every buffer for a whole extra frame.
    private func releaseRetired() {
        retiring.removeAll { b in
            guard !IOSurfaceIsInUse(b.surface) else { return false }
            release(b)
            return true
        }
        guard !retiring.isEmpty, !pollingRetired else { return }
        pollingRetired = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.002) { [weak self] in
            guard let self else { return }
            self.pollingRetired = false
            if !self.closed { self.releaseRetired() }
        }
    }

    private func release(_ b: ClientConnection.Buffer) {
        b.busy = false
        connection?.send(HMOp.bufferRelease, ["id": b.id])
    }

    private func releaseAllBuffers() {
        for b in retiring { release(b) }
        retiring.removeAll()
        if let b = currentBuffer { release(b) }
        currentBuffer = nil
        frameCallbacks.removeAll()
        screen.layer?.contents = nil
    }

    // MARK: Configure

    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    private func sendConfigureIfNeeded() {
        guard let connection, toplevelID != 0, bounds.width > 0, bounds.height > 0 else { return }
        var states: [String] = []
        if activated { states.append(HMToplevelState.activated) }
        if occluded { states.append(HMToplevelState.occluded) }
        let size = bounds.size
        guard size != sentSize || scale != sentScale || states != sentStates else { return }
        sentSize = size; sentScale = scale; sentStates = states
        serial += 1
        connection.send(HMOp.toplevelConfigure, [
            "id": toplevelID, "serial": serial, "w": Double(size.width), "h": Double(size.height),
            "scale": Double(scale), "states": states,
        ])
    }

    // MARK: Input

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        activated = true
        connection?.send(HMOp.keyboardEnter, ["surface": surfaceID, "serial": nextSerial(),
                                              "modifiers": modifierBits(NSEvent.modifierFlags)])
        sendConfigureIfNeeded()
        return true
    }

    override func resignFirstResponder() -> Bool {
        cancelComposition()
        activated = false
        connection?.send(HMOp.keyboardLeave, ["surface": surfaceID, "serial": nextSerial()])
        sendConfigureIfNeeded()
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    func nextSerial() -> UInt64 { inputSerial += 1; return inputSerial }
    private func modifierBits(_ flags: NSEvent.ModifierFlags) -> UInt64 {
        UInt64(flags.intersection(.deviceIndependentFlagsMask).rawValue)
    }
    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    private func sendPointer(_ op: String, _ event: NSEvent, _ extra: [String: Any] = [:]) {
        guard let connection else { return }
        let p = point(event)
        var fields: [String: Any] = ["surface": surfaceID, "time": event.timestamp, "x": Double(p.x), "y": Double(p.y),
                                     "modifiers": modifierBits(event.modifierFlags), "buttons": UInt64(NSEvent.pressedMouseButtons)]
        for (k, v) in extra { fields[k] = v }
        connection.send(op, fields)
    }

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        let p = point(event)
        connection?.send(HMOp.pointerEnter, ["surface": surfaceID, "serial": nextSerial(), "x": Double(p.x), "y": Double(p.y)])
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        connection?.send(HMOp.pointerLeave, ["surface": surfaceID, "serial": nextSerial()])
    }

    override func mouseMoved(with event: NSEvent) { sendPointer(HMOp.pointerMotion, event) }
    override func mouseDragged(with event: NSEvent) { sendPointer(HMOp.pointerMotion, event) }
    override func rightMouseDragged(with event: NSEvent) { sendPointer(HMOp.pointerMotion, event) }
    override func otherMouseDragged(with event: NSEvent) { sendPointer(HMOp.pointerMotion, event) }

    private func button(_ event: NSEvent, down: Bool) {
        let b: UInt64 = event.type == .leftMouseDown || event.type == .leftMouseUp ? 0
            : event.type == .rightMouseDown || event.type == .rightMouseUp ? 1 : UInt64(max(2, event.buttonNumber))
        sendPointer(HMOp.pointerButton, event, ["serial": nextSerial(), "button": b, "state": down ? "down" : "up",
                                                "click_count": UInt64(max(1, event.clickCount))])
    }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); button(event, down: true) }
    override func mouseUp(with event: NSEvent) { button(event, down: false) }
    override func rightMouseDown(with event: NSEvent) { button(event, down: true) }
    override func rightMouseUp(with event: NSEvent) { button(event, down: false) }
    override func otherMouseDown(with event: NSEvent) { button(event, down: true) }
    override func otherMouseUp(with event: NSEvent) { button(event, down: false) }

    override func scrollWheel(with event: NSEvent) {
        // A notched wheel's raw notch count lives only on the CGEvent. Chromium uses
        // it for wheel ticks, and VS Code scrolls by ticks.
        var ticksX = 0.0, ticksY = 0.0
        if !event.hasPreciseScrollingDeltas, let cg = event.cgEvent {
            ticksX = Double(cg.getIntegerValueField(.scrollWheelEventDeltaAxis2))
            ticksY = Double(cg.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        }
        sendPointer(HMOp.pointerScroll, event, [
            "dx": Double(event.scrollingDeltaX), "dy": Double(event.scrollingDeltaY),
            "precise": event.hasPreciseScrollingDeltas,
            "phase": UInt64(event.phase.rawValue), "momentum_phase": UInt64(event.momentumPhase.rawValue),
            "ticks_x": ticksX, "ticks_y": ticksY,
        ])
    }

    private func sendKey(_ event: NSEvent, down: Bool) {
        connection?.send(HMOp.keyboardKey, [
            "surface": surfaceID, "serial": nextSerial(), "time": event.timestamp,
            "key_code": UInt64(event.keyCode), "state": down ? "down" : "up", "repeat": down && event.isARepeat,
            "characters": event.characters ?? "", "characters_ignoring_modifiers": event.charactersIgnoringModifiers ?? "",
            "modifiers": modifierBits(event.modifierFlags),
        ])
    }

    /// `app:shortcuts = app`: focused app tiles get chords before Hyprmux (set by the compositor).
    static var shortcutsFirst = false

    /// AppKit offers Cmd chords to the main menu before keyDown, so Open Config would
    /// eat the app's Cmd+, and Minimize its Cmd+M. Under `app:shortcuts = app` the tile
    /// takes them first; Cmd+Q still quits Hyprmux.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard Self.shortcutsFirst, event.type == .keyDown, connection != nil, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command, event.charactersIgnoringModifiers == "q" { return false }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if handleTextInput(event) { return }
        sendKey(event, down: true)
    }
    override func keyUp(with event: NSEvent) {
        // The input method took this key's press, so the release is ours too.
        if textInput.consumedKeyUps.remove(event.keyCode) != nil { return }
        sendKey(event, down: false)
    }
    override func flagsChanged(with event: NSEvent) {
        connection?.send(HMOp.keyboardModifiers, ["surface": surfaceID, "modifiers": modifierBits(event.modifierFlags)])
    }

    // MARK: Cursor

    func setCursor(_ name: String) {
        cursorName = name
        if pointerInside { cursor.set() }
    }

    private var cursor: NSCursor {
        switch cursorName {
        case "ibeam": .iBeam
        case "pointing_hand": .pointingHand
        case "crosshair": .crosshair
        case "open_hand": .openHand
        case "closed_hand": .closedHand
        case "resize_left_right": .resizeLeftRight
        case "resize_up_down": .resizeUpDown
        case "not_allowed": .operationNotAllowed
        default: .arrow
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        if cursorName == "hidden" { NSCursor.arrow.set(); return }
        cursor.set()
    }
}
