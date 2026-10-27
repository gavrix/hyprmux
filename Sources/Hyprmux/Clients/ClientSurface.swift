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
///
/// A terminal toplevel (`toplevel.create_terminal`) shows a Hyprmux terminal instead of
/// the client's buffers. The client runs the command and owns the tile; the terminal
/// handles its own input.
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
    /// The `.hmapp` this tile was launched from, with the user's arguments (docs/APPS.md).
    /// The session restores it by id.
    var appEntry: String?
    var entryArgs: [String] = []

    private let screen = PassthroughView()
    private let placeholder = NSTextField(labelWithString: "")
    private var clientTitle = ""
    private(set) var closed = false

    /// A terminal toplevel's terminal. It has this tile's id.
    private(set) var terminal: TerminalView?
    /// Gets the terminal's callbacks this tile doesn't handle itself (the compositor).
    weak var terminalHost: TerminalViewHost?
    /// The title changed (a terminal's own title, shown while the client sets none).
    var onTitleChange: ((ClientSurface) -> Void)?
    /// `toplevel.set_status`: what the content is doing (`HMToplevelStatus`). The tile
    /// draws it (ClientView.setStatus).
    private(set) var status: String?
    var onStatusChange: ((ClientSurface) -> Void)?

    // Surface state (current, after the last commit).
    private var currentBuffer: ClientConnection.Buffer?
    private var currentScale: CGFloat = 1
    // Committed frame callbacks waiting for the next display refresh.
    private var frameCallbacks: [UInt64] = []
    /// The menu and sheet the client has open (ClientSurface+WindowUI.swift): they
    /// close with the client.
    var openMenu: NSMenu?
    var openSheet: NSWindow?
    // Buffers replaced by a newer commit; released once Core Animation stops using them.
    private var retiring: [ClientConnection.Buffer] = []
    /// Subsurfaces, in stacking order: each shows a buffer scaled to a rect in the
    /// toplevel's points.
    private final class Child {
        let id: UInt64
        let view = PassthroughView()
        var buffer: ClientConnection.Buffer?
        var rect = CGRect.zero
        init(id: UInt64) { self.id = id }
    }
    private var children: [Child] = []
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var watchdogScheduled = false
    private var observingDisplays = false

    // Configure state.
    private var serial: UInt64 = 0
    private var ackedSerial: UInt64 = 0
    private var sentSize = CGSize.zero
    private var sentScale: CGFloat = 0
    private var sentStates: [String] = []
    private var occluded = false
    private var activated = false
    /// The client declared `anchored-resize`: frames show 1:1 at the top-left.
    private var anchored = false

    // Input state.
    private var cursorName = "arrow"
    private var tracking: NSTrackingArea?
    private var pointerInside = false
    private(set) var framesShown = 0
    /// Runs once, at the first commit with a buffer: the window's title and size are in.
    var onFirstFrame: (() -> Void)?
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
        terminal?.frame = bounds
        layoutChildren()
        placeholder.sizeToFit()
        placeholder.frame.origin = CGPoint(x: (bounds.width - placeholder.frame.width) / 2,
                                           y: (bounds.height - placeholder.frame.height) / 2)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, link == nil { makeLink() }
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged), name: NSWindow.didChangeScreenNotification, object: window)
        }
        if !observingDisplays {
            observingDisplays = true
            NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged),
                                                   name: NSApplication.didChangeScreenParametersNotification, object: nil)
        }
        sendConfigureIfNeeded()
    }

    private func makeLink() {
        link?.invalidate()
        link = displayLink(target: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
        link?.isPaused = true
        lastTick = CACurrentMediaTime()
        updateLink()
    }

    /// A view's display link can stop for good when displays change (sleep, wake, a
    /// monitor plugged in), while still reporting itself unpaused. Rebuild it.
    @objc private func displaysChanged() {
        guard window != nil, !closed else { return }
        makeLink()
    }

    /// Callbacks that wait well past a refresh with no tick: the link died. Rebuild it,
    /// so a client's frame request is never lost (a lost one froze Zed).
    private func checkLinkAlive() {
        guard !closed, window != nil, !occluded, !frameCallbacks.isEmpty || !retiring.isEmpty else { return }
        if CACurrentMediaTime() - lastTick > 0.25 {
            log.warning("client tile \(self.clientID.raw): display link stalled, rebuilding")
            makeLink()
        }
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
        // A client that keeps up with configures: its last frame shows at its own
        // size until the new one arrives, so a resize never stretches its content.
        anchored = connection.capabilities.contains(HMCapability.anchoredResize)
        screen.layer?.contentsGravity = anchored ? .topLeft : .resizeAspect
        launchToken = nil
        placeholder.stringValue = ""
        sentSize = .zero  // force a configure
        sendConfigureIfNeeded()
        // Focused before the client connected (a launch with --focus): the enter it
        // missed. Without it, the client never thinks it has the keyboard.
        if window?.firstResponder === self {
            connection.send(HMOp.keyboardEnter, ["surface": surfaceID, "serial": nextSerial(),
                                                  "modifiers": modifierBits(NSEvent.modifierFlags)])
        }
    }

    /// A launch token for a tile that is still waiting (a restored session relaunches).
    func setLaunchToken(_ token: String) { launchToken = token }

    /// The pending tile gave up waiting.
    func launchFailed(_ message: String) {
        placeholder.stringValue = message
        layoutContent()
    }

    /// A terminal toplevel's terminal fills the tile.
    func attachTerminal(_ term: TerminalView) {
        terminal = term
        term.host = self
        term.onFocusChange = { [weak self] focused in
            guard let self else { return }
            self.activated = focused
            self.sendConfigureIfNeeded()
        }
        term.onChildExited = { [weak self, weak term] status in
            guard let self, let term else { return }
            self.terminalExited(term, status: Int(status))
        }
        term.frame = bounds
        addSubview(term, positioned: .below, relativeTo: placeholder)
        placeholder.stringValue = ""
        layer?.backgroundColor = term.backdrop.cgColor
        framesShown += 1
        if let first = onFirstFrame {
            onFirstFrame = nil
            first()
        }
    }

    func setStatus(_ status: String?) {
        guard status != self.status else { return }
        self.status = status
        onStatusChange?(self)
    }

    /// The toplevel was destroyed, or the client disconnected.
    func clientLeft() {
        guard !closed else { return }
        connection = nil
        closed = true
        dismissWindowUI()
        releaseAllBuffers()
        onClose?(self)
    }

    // MARK: Surface

    var view: NSView { self }
    var focusTarget: NSView { terminal ?? self }
    var title: String {
        if !clientTitle.isEmpty { return clientTitle }
        if let t = terminal?.title, !t.isEmpty { return t }
        return launchLabel
    }
    var kind: String { "app" }
    var automationCapabilities: [String] {
        if let terminal { return terminal.automationCapabilities }
        return textInput.enabled ? ["send_text"] : []
    }
    var backdropColor: NSColor { terminal?.backdrop ?? NSColor(white: 0.08, alpha: 1) }
    var info: [String: Any] {
        var result: [String: Any] = ["app": appID.isEmpty ? launchLabel : appID, "state": connection == nil ? "pending" : "connected",
                                     "framesShown": framesShown]
        if terminal != nil { result["content"] = "terminal" }
        if let status { result["status"] = status }
        if let c = connection { result["pid"] = Int(c.pid) }
        if let launchArgument { result["launch"] = launchArgument }
        if let appEntry { result["entry"] = appEntry }
        if let restoreToken { result["restoreToken"] = restoreToken }
        if let b = currentBuffer { result["pixels"] = [b.width, b.height]; result["scale"] = Double(currentScale) }
        if !children.isEmpty {
            result["subsurfaces"] = children.map { c -> [String: Any] in
                let f = c.view.frame
                var o: [String: Any] = ["id": c.id, "rect": [c.rect.minX, c.rect.minY, c.rect.width, c.rect.height],
                                        "frame": [f.minX, f.minY, f.width, f.height], "visible": !c.view.isHidden]
                if let b = c.buffer { o["pixels"] = [b.width, b.height] }
                return o
            }
        }
        // Frame pacing, for stalls: callbacks waiting for a display-link tick.
        result["frames"] = ["pendingCallbacks": frameCallbacks.count, "linkPaused": link?.isPaused ?? true,
                            "occluded": occluded, "retiring": retiring.count]
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

    /// Writes the frame on screen to a PNG: the client's own pixels, straight from
    /// its IOSurface, so it needs no screen-recording permission.
    func writeSnapshot(to url: URL) throws {
        guard let surface = currentBuffer?.surface else { throw SnapshotError.noFrame }
        var image = CIImage(ioSurface: surface)
        // Subsurfaces on top, in the buffer's pixels. Core Image's origin is bottom-left.
        let height = image.extent.height
        for c in children where !c.view.isHidden {
            guard let b = c.buffer else { continue }
            let child = CIImage(ioSurface: b.surface)
            let r = CGRect(x: c.rect.minX * currentScale, y: height - c.rect.maxY * currentScale,
                           width: c.rect.width * currentScale, height: c.rect.height * currentScale)
            let scaled = child.transformed(by: CGAffineTransform(scaleX: r.width / child.extent.width,
                                                                y: r.height / child.extent.height))
                .transformed(by: CGAffineTransform(translationX: r.minX, y: r.minY))
            image = scaled.composited(over: image)
        }
        image = image.cropped(to: CGRect(x: 0, y: 0, width: CGFloat(IOSurfaceGetWidth(surface)), height: height))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        try CIContext().writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: space)
    }

    enum SnapshotError: LocalizedError {
        case noFrame
        var errorDescription: String? { "the tile has no frame yet" }
    }

    func setOccluded(_ occluded: Bool) {
        terminal?.setTerminalOccluded(occluded)
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
        dismissWindowUI()
        terminal?.destroy()
        link?.invalidate()
        link = nil
        releaseAllBuffers()
        connection?.surfaceDestroyed(self)
        connection = nil
    }

    // MARK: Protocol, from ClientConnection

    func setClientTitle(_ title: String) { clientTitle = title }

    /// Applies a new terminal background (a config reload).
    func refreshTerminalBackdrop(_ color: NSColor) {
        guard let terminal else { return }
        terminal.backdrop = color
        layer?.backgroundColor = color.cgColor
    }

    func ackConfigure(_ serial: UInt64) { ackedSerial = max(ackedSerial, serial) }

    /// Makes the pending state current: a new buffer, scale, and frame callbacks.
    func commit(buffer: ClientConnection.Buffer?, scale: CGFloat, callbacks: [UInt64]) {
        guard !closed else { return }
        frameCallbacks += callbacks
        if let buffer {
            // The buffer on screen again: its pixels changed (a simulator's framebuffer,
            // shown by reference). It stays current and isn't released.
            if buffer !== currentBuffer, let old = currentBuffer { retiring.append(old) }
            let resized = currentBuffer.map { $0.width != buffer.width || $0.height != buffer.height } ?? true
            currentBuffer = buffer
            currentScale = scale
            buffer.busy = true
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // Re-assigning makes Core Animation re-read the surface, even the same one.
            screen.layer?.contents = nil
            screen.layer?.contents = buffer.surface
            screen.layer?.contentsScale = scale
            if resized { layoutChildren() }
            CATransaction.commit()
            framesShown += 1
            if let first = onFirstFrame {
                onFirstFrame = nil
                first()
            }
        }
        updateLink()
    }

    // MARK: Subsurfaces, from ClientConnection

    private func child(_ id: UInt64) -> Child {
        if let c = children.first(where: { $0.id == id }) { return c }
        let c = Child(id: id)
        c.view.wantsLayer = true
        c.view.layer?.contentsGravity = .resize
        c.view.layer?.magnificationFilter = .linear
        c.view.layer?.minificationFilter = .trilinear
        c.view.isHidden = true
        addSubview(c.view, positioned: .below, relativeTo: placeholder)
        children.append(c)
        return c
    }

    /// A subsurface committed. Like the toplevel's own buffer, the one on screen again
    /// means its pixels changed.
    func commitChild(_ id: UInt64, buffer: ClientConnection.Buffer?, callbacks: [UInt64]) {
        guard !closed else { return }
        frameCallbacks += callbacks
        if let buffer {
            let c = child(id)
            if buffer !== c.buffer, let old = c.buffer { retiring.append(old) }
            c.buffer = buffer
            buffer.busy = true
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            c.view.layer?.contents = nil
            c.view.layer?.contents = buffer.surface
            CATransaction.commit()
            framesShown += 1
        }
        updateLink()
    }

    /// Applied at the toplevel's commit: where each subsurface sits, in its points.
    func setChildRect(_ id: UInt64, _ rect: CGRect) {
        guard !closed else { return }
        child(id).rect = rect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutChildren()
        CATransaction.commit()
    }

    func removeChild(_ id: UInt64) {
        guard let i = children.firstIndex(where: { $0.id == id }) else { return }
        let c = children.remove(at: i)
        if let b = c.buffer { retiring.append(b) }
        c.view.removeFromSuperview()
        updateLink()
    }

    /// The toplevel's points to tile points: the client's last buffer is drawn scaled to
    /// fit until it catches up with a resize, and subsurfaces scale with it.
    private var contentTransform: (scale: CGFloat, origin: CGPoint) {
        guard !anchored else { return (1, .zero) }
        guard let b = currentBuffer, currentScale > 0, b.width > 0, b.height > 0 else { return (1, .zero) }
        let w = CGFloat(b.width) / currentScale, h = CGFloat(b.height) / currentScale
        let s = min(bounds.width / w, bounds.height / h)
        return (s, CGPoint(x: (bounds.width - w * s) / 2, y: (bounds.height - h * s) / 2))
    }

    private func layoutChildren() {
        let t = contentTransform
        for c in children {
            let r = c.rect
            c.view.isHidden = r.width <= 0 || r.height <= 0 || c.buffer == nil
            c.view.frame = CGRect(x: t.origin.x + r.minX * t.scale, y: t.origin.y + r.minY * t.scale,
                                  width: r.width * t.scale, height: r.height * t.scale)
        }
    }

    /// A buffer the client destroyed: stop showing it.
    func bufferDestroyed(_ buffer: ClientConnection.Buffer) {
        retiring.removeAll { $0 === buffer }
        if currentBuffer === buffer {
            currentBuffer = nil
            screen.layer?.contents = nil
        }
        for c in children where c.buffer === buffer {
            c.buffer = nil
            c.view.layer?.contents = nil
            c.view.isHidden = true
        }
    }

    // MARK: Frame pacing

    private func updateLink() {
        let paused = (frameCallbacks.isEmpty || occluded) && retiring.isEmpty
        if link?.isPaused == true, !paused { lastTick = CACurrentMediaTime() }
        link?.isPaused = paused
        guard !paused, !watchdogScheduled else { return }
        watchdogScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.watchdogScheduled = false
            self?.checkLinkAlive()
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        lastTick = CACurrentMediaTime()
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
        for c in children {
            if let b = c.buffer { release(b) }
            c.buffer = nil
            c.view.layer?.contents = nil
        }
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

    /// Serials count per connection. A press's serial can activate another of the
    /// client's toplevels (`toplevel.request_activate`).
    func nextSerial(activating: Bool = false) -> UInt64 { connection?.nextInputSerial(activating: activating) ?? 0 }
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
        sendPointer(HMOp.pointerButton, event, ["serial": nextSerial(activating: down), "button": b, "state": down ? "down" : "up",
                                                "click_count": UInt64(max(1, event.clickCount))])
    }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); button(event, down: true) }
    override func mouseUp(with event: NSEvent) { button(event, down: false) }
    override func rightMouseDown(with event: NSEvent) { button(event, down: true) }
    override func rightMouseUp(with event: NSEvent) { button(event, down: false) }
    override func otherMouseDown(with event: NSEvent) { button(event, down: true) }
    override func otherMouseUp(with event: NSEvent) { button(event, down: false) }

    // Trackpad pinch and rotate (CLIENT_PROTOCOL 6.1, pointer.gesture).
    override func magnify(with event: NSEvent) { sendGesture("magnify", Double(event.magnification), event) }
    override func rotate(with event: NSEvent) { sendGesture("rotate", Double(event.rotation), event) }

    private func sendGesture(_ kind: String, _ value: Double, _ event: NSEvent) {
        sendPointer(HMOp.pointerGesture, event, ["kind": kind, "value": value, "phase": UInt64(event.phase.rawValue)])
    }

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
            "surface": surfaceID, "serial": nextSerial(activating: down), "time": event.timestamp,
            "key_code": UInt64(event.keyCode), "state": down ? "down" : "up", "repeat": down && event.isARepeat,
            "characters": event.characters ?? "", "characters_ignoring_modifiers": event.charactersIgnoringModifiers ?? "",
            "modifiers": modifierBits(event.modifierFlags),
        ])
    }

    /// Whether the focused app's `pass` list claims a chord (set by the compositor).
    static var passes: ((ClientSurface, NSEvent) -> Bool)?

    /// AppKit offers Cmd chords to the main menu before keyDown. A chord the app's pass
    /// list claims must reach the app, not Hyprmux's menu (Open Config is ⌘,).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, connection != nil, window?.firstResponder === self,
              Self.passes?(self, event) == true else {
            return super.performKeyEquivalent(with: event)
        }
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

    private var cursor: NSCursor { Self.cursor(named: cursorName) }

    /// A `pointer.set_cursor` name's cursor (HMCursor.all). Unknown names, `wait`,
    /// and `progress` are the arrow: macOS shows its own busy cursor.
    static func cursor(named name: String) -> NSCursor {
        switch name {
        case "ibeam": return .iBeam
        case "vertical_ibeam": return .iBeamCursorForVerticalLayout
        case "pointing_hand": return .pointingHand
        case "crosshair": return .crosshair
        case "open_hand", "move": return .openHand
        case "closed_hand": return .closedHand
        case "resize_left_right": return .resizeLeftRight
        case "resize_up_down": return .resizeUpDown
        case "resize_left": return .resizeLeft
        case "resize_right": return .resizeRight
        case "resize_up": return .resizeUp
        case "resize_down": return .resizeDown
        case "resize_nwse", "resize_nesw":
            if #available(macOS 15, *) {
                return .frameResize(position: name == "resize_nwse" ? .topLeft : .topRight, directions: .all)
            }
            return .crosshair
        case "copy": return .dragCopy
        case "link": return .dragLink
        case "context_menu": return .contextualMenu
        case "help":
            // AppKit's help cursor has no public name; Qt uses the same one.
            let help = NSSelectorFromString("_helpCursor")
            if NSCursor.responds(to: help), let c = NSCursor.perform(help)?.takeUnretainedValue() as? NSCursor { return c }
            return .arrow
        case "zoom_in", "zoom_out":
            if #available(macOS 15, *) { return name == "zoom_in" ? .zoomIn : .zoomOut }
            return .arrow
        case "not_allowed": return .operationNotAllowed
        default: return .arrow
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        if cursorName == "hidden" { NSCursor.arrow.set(); return }
        cursor.set()
    }
}


// MARK: Terminal toplevels

/// The tile's terminal reports here. Closing tells the client; the title is the
/// tile's; the rest goes to the compositor, as for any terminal.
extension ClientSurface: TerminalViewHost {
    func terminalDidRequestFocus(_ view: TerminalView) { terminalHost?.terminalDidRequestFocus(view) }

    func terminalTitleDidChange(_ view: TerminalView) { onTitleChange?(self) }

    func terminalDidClose(_ view: TerminalView, processAlive: Bool) { terminalExited(view, status: nil) }

    /// The command exited, or the terminal closed. The client decides what happens to the
    /// tile; without a client, the tile goes.
    func terminalExited(_ view: TerminalView, status: Int?) {
        guard view === terminal else { return }
        terminal = nil
        view.removeFromSuperview()
        // Not inside Ghostty's callback: it still holds the surface.
        DispatchQueue.main.async { view.destroy() }
        placeholder.stringValue = "Exited"
        layoutContent()
        if let connection, toplevelID != 0 {
            var fields: [String: Any] = ["id": toplevelID]
            if let status { fields["status"] = status }
            connection.send(HMOp.toplevelTerminalExited, fields)
        } else {
            clientLeft()
        }
    }

    func terminalDidRequestSpawn(_ view: TerminalView) { terminalHost?.terminalDidRequestSpawn(view) }
    func terminal(_ view: TerminalView, perform dispatcher: Dispatcher) { terminalHost?.terminal(view, perform: dispatcher) }
    func terminalDidToggleWindowFullscreen(_ view: TerminalView) { terminalHost?.terminalDidToggleWindowFullscreen(view) }
    func terminal(_ view: TerminalView, openURL url: URL) -> Bool { terminalHost?.terminal(view, openURL: url) ?? false }
    func terminal(_ view: TerminalView, notifyTitle title: String, body: String) {
        terminalHost?.terminal(view, notifyTitle: title, body: body)
    }
}
