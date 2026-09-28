import AppKit
import HypermuxCore
import SimulatorBridge

/// A booted iOS Simulator's screen, read straight from its framebuffer IOSurface
/// (no Simulator.app window, no screen recording). Letterboxed in the tile.
final class SimulatorSurface: FlippedView, Surface {
    let clientID: ClientID
    let display: HMSimDisplay
    var onClose: ((SimulatorSurface) -> Void)?

    private let screen = NSView()
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
        return i
    }

    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {}  // input comes in a later step

    func setOccluded(_ occluded: Bool) {}

    func requestClose() {
        guard !closed else { return }
        closed = true
        display.stop()
        onClose?(self)
    }

    func destroy() { display.stop() }
}
