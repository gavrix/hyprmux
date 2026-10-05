import AppKit
import HyprmuxClientKit
import SimulatorBridge

/// A booted iOS Simulator. Its framebuffer is an IOSurface the simulator draws into;
/// Mobile registers that very surface with Hyprmux and presents it again on each frame,
/// so no pixel is copied (docs/CLIENT_PROTOCOL.md, Subsurfaces).
final class IOSWindow: DeviceWindow {
    let display: HMSimDisplay
    private var buffer: HMBuffer?
    private var bufferSurface: IOSurfaceRef?
    private var touchEdge: HMSimEdge = .none
    private var lastRatio = CGPoint.zero
    private var touching = false
    /// A real digitizer keeps reporting a resting finger; the Mac sends nothing while the
    /// button is held still. Without these repeats the guest drops the contact (no long press).
    private var holdTimer: Timer?

    init(mobile: Mobile, display: HMSimDisplay, restoreToken: String?, launch: HMLaunch?) {
        self.display = display
        super.init(mobile: mobile, title: display.name, restoreToken: restoreToken, launch: launch)
        display.onFrame = { [weak self] in self?.frame() }
        frame()
    }

    override var buttons: [Button] {
        [Button(symbol: "house", label: "Home") { [weak self] in self?.press(.home) },
         Button(symbol: "lock", label: "Lock") { [weak self] in self?.press(.lock) }]
    }

    override func drawChrome(_ ctx: CGContext, size: CGSize) {
        super.drawChrome(ctx, size: size)
        if let why = display.inputUnavailableReason {
            Draw.text("Input unavailable: \(why)", in: CGRect(x: 8, y: size.height - 24, width: size.width / 2 - 60, height: 20),
                      size: 10, color: Draw.note)
        }
    }

    /// The simulator drew a frame, or replaced its framebuffer (rotation, a new display).
    private func frame() {
        guard !closed, let surface = display.surface else { return }
        if surface != bufferSurface {
            if let old = buffer { deviceScreen.unregister(old) }
            buffer = deviceScreen.register(surface)
            bufferSurface = surface
            screenPixels = CGSize(width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface))
        }
        // A hidden tile reads nothing; the next frame after it shows again catches up.
        guard !occluded, let buffer else { return }
        deviceScreen.present(buffer)
    }

    override func occlusionChanged(_ occluded: Bool) {
        if !occluded { frame() }
    }

    // MARK: Input

    /// A touch starting this close to a screen edge (fraction of the side) is an edge gesture.
    private static let edgeBand: CGFloat = 0.03

    private static func edge(for r: CGPoint) -> HMSimEdge {
        if r.y >= 1 - edgeBand { return .bottom }
        if r.y <= edgeBand { return .top }
        if r.x <= edgeBand { return .left }
        if r.x >= 1 - edgeBand { return .right }
        return .none
    }

    override func touch(_ ratio: CGPoint, phase: TouchPhase) {
        lastRatio = ratio
        switch phase {
        case .down:
            touching = true
            touchEdge = Self.edge(for: ratio)
            display.sendTouch(atRatio: ratio, phase: .down, edge: touchEdge)
            startHold()
        case .move:
            display.sendTouch(atRatio: ratio, phase: .move, edge: touchEdge)
        case .up:
            touching = false
            stopHold()
            display.sendTouch(atRatio: ratio, phase: .up, edge: touchEdge)
        }
    }

    private func startHold() {
        holdTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self, self.touching else { return }
            self.display.sendTouch(atRatio: self.lastRatio, phase: .move, edge: self.touchEdge)
        }
        RunLoop.main.add(t, forMode: .common)
        holdTimer = t
    }

    private func stopHold() {
        holdTimer?.invalidate()
        holdTimer = nil
    }

    override func key(_ e: HMKeyEvent) {
        // iOS repeats held keys itself.
        guard !(e.down && e.isRepeat), let usage = SimulatorKeys.usage(forKeyCode: e.keyCode) else { return }
        display.sendKeyUsage(usage, down: e.down)
    }

    override func modifier(_ flag: UInt64, down: Bool) {
        let usage: UInt32
        switch NSEvent.ModifierFlags(rawValue: UInt(flag)) {
        case .shift: usage = 0xE1
        case .control: usage = 0xE0
        case .option: usage = 0xE2
        case .command: usage = 0xE3
        default: usage = 0x39  // caps lock
        }
        display.sendKeyUsage(usage, down: down)
    }

    /// A hardware button: pressed, then released 80 ms later.
    func press(_ button: HMSimButton) {
        display.send(button, down: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.display.send(button, down: false)
        }
    }

    override func stop() {
        stopHold()
        display.onFrame = nil
        display.stop()
    }
}
