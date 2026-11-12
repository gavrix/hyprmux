import AppKit
import HyprmuxClientKit

/// A device's screen above a slim bar of hardware buttons. The screen is a subsurface,
/// letterboxed in the area above the bar, so a device frame never redraws the chrome.
/// The pointer becomes touches on the screen and presses on the bar.
class DeviceWindow: MobileWindow {
    struct Button {
        let symbol: String
        let label: String
        let action: () -> Void
    }

    /// The device screen's subsurface. Made with the toplevel, before its first commit.
    private(set) var deviceScreen: HMSubsurface!
    /// Where the device screen sits, in points.
    private(set) var screenRect = CGRect.zero
    /// The screen's size in pixels, for its aspect ratio. Zero until the first frame.
    var screenPixels = CGSize.zero {
        didSet {
            guard screenPixels != oldValue else { return }
            layout()
            redrawChrome()
        }
    }
    /// Shown in place of the screen: a stream that failed, input that can't be delivered.
    var message: String? {
        didSet { if message != oldValue { redrawChrome() } }
    }

    var barHeight: CGFloat { 28 }
    var buttons: [Button] { [] }
    private var buttonRects: [CGRect] = []
    private var pressed: Int?
    private var touching = false
    private var modifiers: UInt64 = 0
    /// Two fingers from the pointer: an Option-drag, or a trackpad pinch or rotation.
    private var fingers: Fingers?

    override init(mobile: Mobile, title: String, restoreToken: String?, launch: HMLaunch?) {
        super.init(mobile: mobile, title: title, restoreToken: restoreToken, launch: launch)
        // Configure events come later, on the queue: the toplevel hasn't committed yet.
        deviceScreen = toplevel.makeSubsurface()
        self.toplevel.onPointer = { [weak self] e in self?.pointer(e) }
        self.toplevel.onKey = { [weak self] k in self?.key(k) }
        self.toplevel.onModifiers = { [weak self] m in self?.modifiersChanged(m) }
        self.toplevel.onKeyboardFocus = { [weak self] focused in
            guard let self, !focused else { return }
            // Keys held when focus leaves would stay down on the device.
            self.modifiersChanged(0)
        }
    }

    override func layout() {
        let s = size
        let bar = min(barHeight, s.height)
        let area = CGRect(x: 0, y: 0, width: s.width, height: s.height - bar)
        screenRect = Draw.aspectFit(screenPixels, in: area)
        let side: CGFloat = 22, gap: CGFloat = 42
        let count = CGFloat(buttons.count)
        let total = count * side + max(0, count - 1) * gap
        var x = (s.width - total) / 2
        buttonRects = buttons.map { _ in
            defer { x += side + gap }
            return CGRect(x: x, y: s.height - bar + (bar - side) / 2, width: side, height: side)
        }
    }

    override func drawChrome(_ ctx: CGContext, size: CGSize) {
        super.drawChrome(ctx, size: size)
        let bar = min(barHeight, size.height)
        Draw.fill(ctx, CGRect(x: 0, y: size.height - bar, width: size.width, height: bar), Draw.bar)
        for (i, b) in buttons.enumerated() where i < buttonRects.count {
            let r = buttonRects[i]
            if pressed == i {
                ctx.setFillColor(Draw.pressed.cgColor)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: 5, cornerHeight: 5, transform: nil))
                ctx.fillPath()
            }
            Draw.symbol(b.symbol, in: r)
        }
        if let message {
            let area = CGRect(x: 20, y: 0, width: max(0, size.width - 40), height: size.height - bar)
            Draw.text(message, in: area, size: 13, color: Draw.note)
        }
    }

    override func willCommitChrome() {
        let r = message == nil ? screenRect : .zero
        deviceScreen.setRect(x: r.minX, y: r.minY, width: r.width, height: r.height)
    }

    override func close() {
        guard !closed else { return }
        deviceScreen.destroy()
        super.close()
    }

    // MARK: Input

    /// Touches, as 0...1 of the screen from its top-left. `down` starts on the screen;
    /// moves and the end are clamped to it.
    func touch(_ ratio: CGPoint, phase: TouchPhase) {}

    enum TouchPhase { case down, move, up }

    /// Whether the device takes `touches`. Without it, Option-drag is a plain touch and
    /// trackpad pinches do nothing.
    var supportsMultiTouch: Bool { false }

    /// Two fingers, as 0...1 of the screen, from the start of a two-finger touch to its end.
    func touches(_ first: CGPoint, _ second: CGPoint, phase: TouchPhase) {}

    func key(_ event: HMKeyEvent) {}

    /// One modifier key changed: `flag` is an `NSEvent.ModifierFlags` raw value.
    func modifier(_ flag: UInt64, down: Bool) {}

    private func ratio(_ x: Double, _ y: Double) -> CGPoint {
        let r = screenRect
        guard r.width > 0, r.height > 0 else { return .zero }
        return CGPoint(x: (x - r.minX) / r.width, y: (y - r.minY) / r.height)
    }

    private func clamped(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1))
    }

    private func pointer(_ e: HMPointerEvent) {
        switch e {
        case .button(let x, let y, let button, let down, _, let flags) where button == 0:
            if down {
                if let i = buttonRects.firstIndex(where: { $0.insetBy(dx: -8, dy: -4).contains(CGPoint(x: x, y: y)) }) {
                    pressed = i
                    redrawChrome()
                    return
                }
                let r = ratio(x, y)
                // Only presses that start on the device screen are touches, not the letterbox.
                guard message == nil, fingers == nil, (0...1).contains(r.x), (0...1).contains(r.y) else { return }
                if supportsMultiTouch, flags & UInt64(NSEvent.ModifierFlags.option.rawValue) != 0 {
                    let shift = flags & UInt64(NSEvent.ModifierFlags.shift.rawValue) != 0
                    startDrag(at: CGPoint(x: x, y: y), together: shift)
                    return
                }
                touching = true
                touch(r, phase: .down)
            } else if case .drag = fingers?.source {
                endFingers()
            } else if let i = pressed {
                pressed = nil
                redrawChrome()
                if buttonRects[i].insetBy(dx: -8, dy: -4).contains(CGPoint(x: x, y: y)) { buttons[i].action() }
            } else if touching {
                touching = false
                touch(clamped(ratio(x, y)), phase: .up)
            }
        case .motion(let x, let y, let held, _):
            if case .drag(let start, let together) = fingers?.source {
                if held & 1 == 0 { endFingers(); return }
                moveDrag(to: CGPoint(x: x, y: y), from: start, together: together)
                return
            }
            guard touching else { return }
            if held & 1 == 0 {
                // The button came up outside the tile.
                touching = false
                touch(clamped(ratio(x, y)), phase: .up)
            } else {
                touch(clamped(ratio(x, y)), phase: .move)
            }
        case .gesture(let x, let y, let kind, let value, let phase, _):
            gesture(kind, value, phase: NSEvent.Phase(rawValue: UInt(phase)), at: CGPoint(x: x, y: y))
        default:
            break
        }
    }

    // MARK: Two fingers

    private struct Fingers {
        enum Source {
            /// Option-drag: the fingers mirror each other about the screen's center, as in
            /// Simulator.app. With Shift, they keep their offset and move together.
            case drag(start: CGPoint, together: Bool)
            /// A trackpad pinch or rotation, about where the pointer was when it began.
            case gesture(Set<HMGestureKind>)
        }
        var source: Source
        var center: CGPoint
        /// Half the distance between the fingers, in points.
        var radius: CGFloat
        /// Radians counterclockwise from the first finger on the left.
        var angle: CGFloat = 0
        var scale: CGFloat = 1

        /// The two fingers, in tile points. y grows downwards, so counterclockwise subtracts.
        var points: (CGPoint, CGPoint) {
            let r = radius * scale
            let dx = r * cos(angle), dy = -r * sin(angle)
            return (CGPoint(x: center.x - dx, y: center.y - dy), CGPoint(x: center.x + dx, y: center.y + dy))
        }
    }

    private func sendFingers(_ phase: TouchPhase) {
        guard let f = fingers else { return }
        let (a, b) = f.points
        touches(clamped(ratio(a.x, a.y)), clamped(ratio(b.x, b.y)), phase: phase)
    }

    /// The pointer is the first finger; the second mirrors it about the screen's center.
    private func startDrag(at start: CGPoint, together: Bool) {
        let c = CGPoint(x: screenRect.midX, y: screenRect.midY)
        let dx = c.x - start.x, dy = c.y - start.y
        fingers = Fingers(source: .drag(start: start, together: together), center: c,
                          radius: max(1, hypot(dx, dy)), angle: atan2(-dy, dx))
        sendFingers(.down)
    }

    private func moveDrag(to p: CGPoint, from start: CGPoint, together: Bool) {
        guard var f = fingers else { return }
        if together {
            let c = CGPoint(x: screenRect.midX, y: screenRect.midY)
            f.center = CGPoint(x: c.x + p.x - start.x, y: c.y + p.y - start.y)
        } else {
            let dx = f.center.x - p.x, dy = f.center.y - p.y
            f.radius = max(1, hypot(dx, dy))
            f.angle = atan2(-dy, dx)
        }
        fingers = f
        sendFingers(.move)
    }

    private func endFingers() {
        sendFingers(.up)
        fingers = nil
    }

    /// Trackpad pinch and rotation become two fingers about the pointer. AppKit sends the two
    /// as separate streams, each with its own phases; the fingers lift when both end.
    private func gesture(_ kind: HMGestureKind, _ value: Double, phase: NSEvent.Phase, at p: CGPoint) {
        if phase.contains(.began) {
            guard supportsMultiTouch, message == nil, !touching else { return }
            if case .gesture(var kinds) = fingers?.source {
                kinds.insert(kind)
                fingers?.source = .gesture(kinds)
                return
            }
            guard fingers == nil, screenRect.contains(p) else { return }
            // Start the fingers a third of the screen's width apart, wholly on the screen.
            let s = screenRect
            let r = min(s.width, s.height) / 6
            let c = CGPoint(x: min(max(p.x, s.minX + r), s.maxX - r), y: min(max(p.y, s.minY + r), s.maxY - r))
            fingers = Fingers(source: .gesture([kind]), center: c, radius: r)
            sendFingers(.down)
            return
        }
        guard case .gesture(var kinds) = fingers?.source, kinds.contains(kind) else { return }
        if phase.contains(.changed) {
            switch kind {
            case .magnify:
                // Keep the fingers apart: a pinch that closed them would be a tap.
                let minimum = 8 / max(fingers!.radius, 1)
                fingers!.scale = max(minimum, fingers!.scale * (1 + value))
            case .rotate:
                fingers!.angle += value * .pi / 180
            }
            sendFingers(.move)
        } else if phase.contains(.ended) || phase.contains(.cancelled) {
            kinds.remove(kind)
            fingers?.source = .gesture(kinds)
            if kinds.isEmpty { endFingers() }
        }
    }

    private static let modifierFlags: [UInt64] = [
        NSEvent.ModifierFlags.shift, .control, .option, .command, .capsLock,
    ].map { UInt64($0.rawValue) }

    private func modifiersChanged(_ bits: UInt64) {
        for flag in Self.modifierFlags where (bits & flag) != (modifiers & flag) {
            modifier(flag, down: bits & flag != 0)
        }
        modifiers = bits
    }
}
