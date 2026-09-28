import AppKit
import HypermuxCore

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

struct Decoration: Equatable {
    var borderSize: CGFloat = 2
    var rounding: CGFloat = 10
    var activeBorder: Gradient
    var inactiveBorder: Gradient
    var activeOpacity: CGFloat = 1
    var inactiveOpacity: CGFloat = 1
    var dimInactive = false
    var dimStrength: CGFloat = 0.5
    var shadow = true
    var shadowRange: CGFloat = 12
    var shadowColor: HypermuxCore.Color

    init(_ c: HypermuxConfig) {
        borderSize = c.wm.borderSize
        rounding = c.rounding
        activeBorder = c.activeBorder
        inactiveBorder = c.inactiveBorder
        activeOpacity = c.activeOpacity
        inactiveOpacity = c.inactiveOpacity
        dimInactive = c.dimInactive
        dimStrength = c.dimStrength
        shadow = c.shadowEnabled
        shadowRange = c.shadowRange
        shadowColor = c.shadowColor
    }
}

extension HypermuxCore.Color {
    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

/// One managed window: border, shadow, rounded clip, and the terminal inside.
///
/// During geometry animations the terminal jumps to its final size once and the
/// clip animates around it. That avoids sending a resize to the shell every frame.
final class ClientView: NSView, Animatable {
    let id: ClientID
    let terminal: TerminalView
    private let clip = FlippedView()
    private let dimView = NSView()
    private let borderLayer = CAGradientLayer()
    private let borderMask = CAShapeLayer()

    private(set) var targetFrame: CGRect = .zero
    private var frameTween: Tween<CGRect>?
    private var alphaTween: Tween<CGFloat>?
    private var frameDone: (() -> Void)?
    private var alphaDone: (() -> Void)?
    private var decoration: Decoration
    private var isActive = false

    /// Whether the compositor currently shows this client (its workspace is visible).
    var shown = false

    init(id: ClientID, terminal: TerminalView, decoration: Decoration, background: NSColor) {
        self.id = id
        self.terminal = terminal
        self.decoration = decoration
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false

        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.layer?.backgroundColor = background.cgColor
        addSubview(clip)
        clip.addSubview(terminal)

        dimView.wantsLayer = true
        dimView.layer?.backgroundColor = NSColor.black.cgColor
        dimView.alphaValue = 0
        clip.addSubview(dimView)

        borderLayer.mask = borderMask
        borderLayer.zPosition = 100
        borderMask.fillColor = nil
        borderMask.strokeColor = NSColor.black.cgColor
        layer?.addSublayer(borderLayer)
        applyDecoration(animated: false, duration: 0)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }

    // Clicks inside go to the terminal; the view itself never takes focus.
    override var acceptsFirstResponder: Bool { false }

    func setBackground(_ c: NSColor) { clip.layer?.backgroundColor = c.cgColor }

    // MARK: Decoration

    func setDecoration(_ d: Decoration, active: Bool, borderDuration: Double) {
        let changed = d != decoration || active != isActive
        decoration = d
        isActive = active
        if changed { applyDecoration(animated: borderDuration > 0, duration: borderDuration) }
    }

    private func applyDecoration(animated: Bool, duration: Double) {
        let g = isActive ? decoration.activeBorder : decoration.inactiveBorder
        let colors = (g.colors.count == 1 ? [g.colors[0], g.colors[0]] : g.colors).map(\.cg)
        // Hyprland angles: 0deg runs left to right; positive angles rotate clockwise.
        let rad = g.angle * .pi / 180
        let dx = cos(rad) / 2, dy = sin(rad) / 2
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? duration : 0)
        CATransaction.setDisableActions(!animated)
        borderLayer.colors = colors
        borderLayer.startPoint = CGPoint(x: 0.5 - dx, y: 0.5 - dy)
        borderLayer.endPoint = CGPoint(x: 0.5 + dx, y: 0.5 + dy)
        dimView.alphaValue = (!isActive && decoration.dimInactive) ? decoration.dimStrength : 0
        CATransaction.commit()
        if alphaTween == nil { alphaValue = baseAlpha }
        if let l = layer {
            l.shadowOpacity = decoration.shadow ? 1 : 0
            l.shadowRadius = decoration.shadowRange / 2
            l.shadowColor = decoration.shadowColor.cg
            l.shadowOffset = .zero
        }
        layoutChrome()
    }

    private var baseAlpha: CGFloat { isActive ? decoration.activeOpacity : decoration.inactiveOpacity }

    // MARK: Geometry

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutChrome()
    }

    private func layoutChrome() {
        let b = decoration.borderSize
        let r = decoration.rounding
        let bounds = self.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.frame = bounds.insetBy(dx: b, dy: b)
        clip.layer?.cornerRadius = max(0, r - b)
        borderLayer.frame = bounds
        borderMask.frame = bounds
        borderMask.lineWidth = b
        let inset = bounds.insetBy(dx: b / 2, dy: b / 2)
        borderMask.path = CGPath(roundedRect: inset, cornerWidth: max(0, r - b / 2), cornerHeight: max(0, r - b / 2), transform: nil)
        borderLayer.isHidden = b <= 0
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: r, cornerHeight: r, transform: nil)
        dimView.frame = clip.bounds
        CATransaction.commit()
    }

    /// Moves to `target`, animating from `from` (or the current frame) when a duration is given.
    func move(to target: CGRect, from: CGRect? = nil, duration: Double, curve: Bezier, animator: Animator, completion: (() -> Void)? = nil) {
        targetFrame = target
        // Resize the terminal once, to its final size.
        let b = decoration.borderSize
        let content = CGSize(width: max(1, target.width - 2 * b), height: max(1, target.height - 2 * b))
        if terminal.frame.size != content {
            terminal.frame = CGRect(origin: .zero, size: content)
        }
        let start = from ?? frame
        if duration <= 0 || start == target {
            // A newer move supersedes any pending completion (e.g. hide after slide-out).
            frameTween = nil
            frameDone = nil
            frame = target
            completion?()
            return
        }
        if from != nil { frame = start }
        frameDone = completion
        frameTween = Tween(from: start, to: target, start: Animator.now, duration: duration, curve: curve)
        animator.add(self)
    }

    func fade(from: CGFloat? = nil, to: CGFloat, duration: Double, curve: Bezier, animator: Animator, completion: (() -> Void)? = nil) {
        let target = to * baseAlpha
        let start = from.map { $0 * baseAlpha } ?? alphaValue
        if duration <= 0 {
            alphaTween = nil
            alphaDone = nil
            alphaValue = target
            completion?()
            return
        }
        alphaValue = start
        alphaDone = completion
        alphaTween = Tween(from: start, to: target, start: Animator.now, duration: duration, curve: curve)
        animator.add(self)
    }

    var isAnimating: Bool { frameTween != nil || alphaTween != nil }

    func step(_ now: CFTimeInterval) -> Bool {
        if let t = frameTween {
            frame = t.from.lerp(to: t.to, t.progress(now)).integralish
            if t.finished(now) {
                frame = t.to
                frameTween = nil
                let done = frameDone
                frameDone = nil
                done?()
            }
        }
        if let t = alphaTween {
            alphaValue = t.from + (t.to - t.from) * t.progress(now)
            if t.finished(now) {
                alphaValue = t.to
                alphaTween = nil
                let done = alphaDone
                alphaDone = nil
                done?()
            }
        }
        return isAnimating
    }
}

private extension CGRect {
    /// Rounds to half points so borders stay crisp mid-animation.
    var integralish: CGRect {
        CGRect(x: (minX * 2).rounded() / 2, y: (minY * 2).rounded() / 2,
               width: (width * 2).rounded() / 2, height: (height * 2).rounded() / 2)
    }
}
