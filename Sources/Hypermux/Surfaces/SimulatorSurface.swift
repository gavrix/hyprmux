import AppKit
import HypermuxCore
import SimulatorBridge

/// A booted iOS Simulator's screen, read straight from its framebuffer IOSurface
/// (no Simulator.app window, no screen recording). Letterboxed in the tile.
final class SimulatorSurface: FlippedView, Surface {
    let clientID: ClientID
    let display: HMSimDisplay
    var onClose: ((SimulatorSurface) -> Void)?

    private let screen = PassthroughView()  // clicks go to the surface, not the image
    private var touchesSent = 0
    private var closed = false

    init(id: ClientID, display: HMSimDisplay) {
        clientID = id
        self.display = display
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 800))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        screen.wantsLayer = true
        screen.layer?.contentsGravity = .resizeAspect
        screen.layer?.magnificationFilter = .linear
        screen.layer?.minificationFilter = .trilinear
        screen.autoresizingMask = [.width, .height]
        screen.frame = bounds
        addSubview(screen)

        display.onFrame = { [weak self] in self?.refresh() }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Point the layer at the current framebuffer. Re-assigning makes Core Animation
    /// re-read the surface; the surface object itself can change (e.g. on rotation).
    private func refresh() {
        guard let layer = screen.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = nil
        if let s = display.surface { layer.contents = s }
        CATransaction.commit()
    }

    // MARK: Surface

    var view: NSView { self }
    var focusTarget: NSView { self }
    var title: String { display.name }
    var kind: String { "sim" }
    var backdropColor: NSColor { .black }
    var info: [String: Any] {
        var i: [String: Any] = ["udid": display.udid, "device": display.name]
        if let s = display.surface { i["pixels"] = [IOSurfaceGetWidth(s), IOSurfaceGetHeight(s)] }
        i["touchesSent"] = touchesSent
        if let why = display.inputUnavailableReason { i["inputError"] = why }
        return i
    }

    // MARK: Input

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Where the device screen is drawn inside the tile (aspect-fit), top-left origin.
    private var screenRect: CGRect {
        guard let s = display.surface else { return bounds }
        let w = CGFloat(IOSurfaceGetWidth(s)), h = CGFloat(IOSurfaceGetHeight(s))
        guard w > 0, h > 0 else { return bounds }
        let scale = min(bounds.width / w, bounds.height / h)
        let size = CGSize(width: w * scale, height: h * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    private func ratio(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        let r = screenRect
        return CGPoint(x: (p.x - r.minX) / r.width, y: (p.y - r.minY) / r.height)
    }

    private var touching = false
    private var touchEdge: HMSimEdge = .none

    /// A touch starting this close to a screen edge (fraction of the side) is an edge gesture.
    private static let edgeBand: CGFloat = 0.03

    private static func edge(for r: CGPoint) -> HMSimEdge {
        if r.y >= 1 - edgeBand { return .bottom }
        if r.y <= edgeBand { return .top }
        if r.x <= edgeBand { return .left }
        if r.x >= 1 - edgeBand { return .right }
        return .none
    }

    override func mouseDown(with event: NSEvent) {
        let r = ratio(event)
        // Only presses that start on the device screen become touches (not the letterbox bars).
        guard (0...1).contains(r.x), (0...1).contains(r.y) else { return }
        touching = true
        touchEdge = Self.edge(for: r)
        touchesSent += 1
        display.sendTouch(atRatio: r, phase: .down, edge: touchEdge)
    }

    override func mouseDragged(with event: NSEvent) {
        guard touching else { return }
        display.sendTouch(atRatio: ratio(event), phase: .move, edge: touchEdge)
    }

    override func mouseUp(with event: NSEvent) {
        guard touching else { return }
        touching = false
        display.sendTouch(atRatio: ratio(event), phase: .up, edge: touchEdge)
    }

    override func keyDown(with event: NSEvent) {
        // iOS repeats held keys itself.
        guard !event.isARepeat, let u = SimulatorKeys.usage(forKeyCode: event.keyCode) else { return }
        display.sendKeyUsage(u, down: true)
    }

    override func keyUp(with event: NSEvent) {
        guard let u = SimulatorKeys.usage(forKeyCode: event.keyCode) else { return }
        display.sendKeyUsage(u, down: false)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let u = SimulatorKeys.modifiers[event.keyCode] else { return }
        let flag: NSEvent.ModifierFlags
        switch u {
        case 0xE1, 0xE5: flag = .shift
        case 0xE0, 0xE4: flag = .control
        case 0xE2, 0xE6: flag = .option
        case 0xE3, 0xE7: flag = .command
        default: flag = .capsLock
        }
        display.sendKeyUsage(u, down: event.modifierFlags.contains(flag))
    }

    /// Hardware buttons from binds (`simbutton, home`).
    func press(_ button: HMSimButton) {
        display.send(button, down: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.display.send(button, down: false)
        }
    }

    func setOccluded(_ occluded: Bool) {}

    func requestClose() {
        guard !closed else { return }
        closed = true
        display.stop()
        onClose?(self)
    }

    func destroy() { display.stop() }
}
