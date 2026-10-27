import AppKit
import HyprmuxClientProtocol
import IOSurface
import QuartzCore

/// A client surface in Hyprmux's own chrome rather than a tile (plans/qml-plugins.md):
///
/// - a **bar item** (`bar_item.create`): a plugin's slot in the workspace bar, such as a
///   system-load readout. The bar decides its place and height; the client asks for a
///   width, and the bar grants it up to `maxBarWidth`.
/// - a **popup** (`popup.create`): a panel that drops from a bar item, such as the
///   readout's details. The client asks for a size; Hyprmux places it under the item
///   and closes it on a click elsewhere or Esc.
///
/// Like a tile, it shows the client's last committed buffer and paces the client with
/// frame callbacks from its display link. It takes pointer input, never the keyboard.
final class ClientPanelView: FlippedView {
    enum Role {
        case barItem(slot: String, order: Int)
        /// `anchor`: the bar item it drops from.
        case popup(anchor: ClientPanelView)
    }

    static let maxBarWidth: CGFloat = 360
    static let maxPopupSize = CGSize(width: 720, height: 900)

    private(set) weak var connection: ClientConnection?
    /// The role object's id: the bar item or the popup.
    let itemID: UInt64
    let surfaceID: UInt64
    let role: Role
    /// The size the client asked for, in points. A bar item asks only for a width.
    private(set) var requestedSize = CGSize.zero
    /// The bar or the popup's host relays out when the requested size changes.
    var onSizeChange: ((ClientPanelView) -> Void)?

    var order: Int { if case .barItem(_, let o) = role { o } else { 0 } }
    var isPopup: Bool { if case .popup = role { true } else { false } }

    private var currentBuffer: ClientConnection.Buffer?
    private var retiring: [ClientConnection.Buffer] = []
    private var frameCallbacks: [UInt64] = []
    private var link: CADisplayLink?
    private var pollingRetired = false
    private var closed = false

    private var serial: UInt64 = 0
    private var sentSize = CGSize.zero
    private var sentScale: CGFloat = 0

    private var tracking: NSTrackingArea?
    private var pointerInside = false
    private var cursorName = "arrow"

    init(connection: ClientConnection, id: UInt64, surface: UInt64, role: Role) {
        self.connection = connection
        itemID = id
        surfaceID = surface
        self.role = role
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contentsGravity = .topLeft
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var mouseDownCanMoveWindow: Bool { false }

    /// A bar item's width in the bar.
    var granted: CGFloat { min(Self.maxBarWidth, max(0, requestedSize.width)) }

    /// A popup's size on screen.
    var grantedPopupSize: CGSize {
        CGSize(width: min(Self.maxPopupSize.width, max(0, requestedSize.width)),
               height: min(Self.maxPopupSize.height, max(0, requestedSize.height)))
    }

    func setRequestedSize(_ size: CGSize) {
        guard size != requestedSize else { return }
        requestedSize = size
        onSizeChange?(self)
    }

    // MARK: Surface

    func commit(buffer: ClientConnection.Buffer?, scale: CGFloat, callbacks: [UInt64]) {
        guard !closed else { return }
        frameCallbacks += callbacks
        if let buffer {
            if buffer !== currentBuffer, let old = currentBuffer { retiring.append(old) }
            currentBuffer = buffer
            buffer.busy = true
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contents = nil
            layer?.contents = buffer.surface
            layer?.contentsScale = scale
            CATransaction.commit()
        }
        updateLink()
    }

    func bufferDestroyed(_ buffer: ClientConnection.Buffer) {
        retiring.removeAll { $0 === buffer }
        if currentBuffer === buffer {
            currentBuffer = nil
            layer?.contents = nil
        }
    }

    var isClosed: Bool { closed }

    /// The client left or destroyed the item, or Hyprmux dismissed the popup.
    func close() {
        guard !closed else { return }
        closed = true
        link?.invalidate()
        link = nil
        for b in retiring { release(b) }
        retiring.removeAll()
        if let b = currentBuffer { release(b) }
        currentBuffer = nil
        layer?.contents = nil
        removeFromSuperview()
    }

    private func release(_ b: ClientConnection.Buffer) {
        b.busy = false
        connection?.send(HMOp.bufferRelease, ["id": b.id])
    }

    // MARK: Frame pacing

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, link == nil, !closed {
            link = displayLink(target: self, selector: #selector(tick(_:)))
            link?.add(to: .main, forMode: .common)
            link?.isPaused = true
        }
        updateLink()
        sendConfigureIfNeeded()
    }

    private func updateLink() {
        link?.isPaused = frameCallbacks.isEmpty && retiring.isEmpty
    }

    @objc private func tick(_ link: CADisplayLink) {
        releaseRetired()
        if !frameCallbacks.isEmpty, let connection {
            let now = CACurrentMediaTime()
            for cb in frameCallbacks {
                connection.send(HMOp.surfaceFrameDone, ["callback": cb, "time": now, "target_time": link.targetTimestamp])
            }
            frameCallbacks.removeAll()
        }
        updateLink()
    }

    /// Releases replaced buffers once Core Animation stops reading them, as tiles do.
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

    // MARK: Configure

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        sendConfigureIfNeeded()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        sendConfigureIfNeeded()
    }

    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    private func sendConfigureIfNeeded() {
        guard let connection, window != nil, !closed, bounds.width > 0, bounds.height > 0 else { return }
        guard bounds.size != sentSize || scale != sentScale else { return }
        sentSize = bounds.size
        sentScale = scale
        serial += 1
        connection.send(isPopup ? HMOp.popupConfigure : HMOp.barItemConfigure, [
            "id": itemID, "serial": serial, "w": Double(bounds.width), "h": Double(bounds.height),
            "scale": Double(scale),
        ])
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func serial(activating: Bool = false) -> UInt64 { connection?.nextInputSerial(activating: activating) ?? 0 }
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
        connection?.send(HMOp.pointerEnter, ["surface": surfaceID, "serial": serial(), "x": Double(p.x), "y": Double(p.y)])
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        connection?.send(HMOp.pointerLeave, ["surface": surfaceID, "serial": serial()])
    }

    override func mouseMoved(with event: NSEvent) { sendPointer(HMOp.pointerMotion, event) }
    override func mouseDragged(with event: NSEvent) { sendPointer(HMOp.pointerMotion, event) }

    private func button(_ event: NSEvent, down: Bool) {
        let b: UInt64 = event.type == .leftMouseDown || event.type == .leftMouseUp ? 0
            : event.type == .rightMouseDown || event.type == .rightMouseUp ? 1 : UInt64(max(2, event.buttonNumber))
        sendPointer(HMOp.pointerButton, event, ["serial": serial(activating: down), "button": b, "state": down ? "down" : "up",
                                                "click_count": UInt64(max(1, event.clickCount))])
    }

    override func mouseDown(with event: NSEvent) { button(event, down: true) }
    override func mouseUp(with event: NSEvent) { button(event, down: false) }
    override func rightMouseDown(with event: NSEvent) { button(event, down: true) }
    override func rightMouseUp(with event: NSEvent) { button(event, down: false) }

    override func scrollWheel(with event: NSEvent) {
        sendPointer(HMOp.pointerScroll, event, [
            "dx": Double(event.scrollingDeltaX), "dy": Double(event.scrollingDeltaY),
            "precise": event.hasPreciseScrollingDeltas,
            "phase": UInt64(event.phase.rawValue), "momentum_phase": UInt64(event.momentumPhase.rawValue),
            "ticks_x": 0.0, "ticks_y": 0.0,
        ])
    }

    // MARK: Cursor

    func setCursor(_ name: String) {
        cursorName = name
        if pointerInside { cursor.set() }
    }

    private var cursor: NSCursor {
        switch cursorName {
        case "pointing_hand": .pointingHand
        case "ibeam": .iBeam
        case "crosshair": .crosshair
        default: .arrow
        }
    }

    override func cursorUpdate(with event: NSEvent) { cursor.set() }
}
