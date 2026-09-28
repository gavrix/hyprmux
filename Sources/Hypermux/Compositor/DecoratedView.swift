import AppKit
import HypermuxCore

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Visual-only overlay: never takes mouse events. A plain NSView, even at
/// alpha 0, would sit on top of the content and swallow every click.
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct Decoration: Equatable {
    var borderSize: CGFloat = 2
    var rounding: CGFloat = 10
    var roundingPower: CGFloat = 2
    var activeBorder: Gradient
    var inactiveBorder: Gradient
    var activeOpacity: CGFloat = 1
    var inactiveOpacity: CGFloat = 1
    var dimInactive = false
    var dimStrength: CGFloat = 0.5
    var shadow = true
    var shadowRange: CGFloat = 12
    var shadowColor: HypermuxCore.Color
    var blur = false

    init(_ c: HypermuxConfig) {
        borderSize = c.wm.borderSize
        rounding = c.rounding
        roundingPower = c.roundingPower
        activeBorder = c.activeBorder
        inactiveBorder = c.inactiveBorder
        activeOpacity = c.activeOpacity
        inactiveOpacity = c.inactiveOpacity
        dimInactive = c.dimInactive
        dimStrength = c.dimStrength
        shadow = c.shadowEnabled
        shadowRange = c.shadowRange
        shadowColor = c.shadowColor
        blur = c.blurEnabled
    }
}

extension HypermuxCore.Color {
    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

/// A frame with Hypermux's window decoration: gradient border, outside-only shadow,
/// rounded or squircle clip, optional blur, and frame/alpha animation.
/// Tiles (`ClientView`) and HUD panels share it, so they look alike.
///
/// Content goes in `clip`. Subclasses hook in through the `…DidChange` methods.
class DecoratedView: NSView, Animatable {
    /// Holds the content, clipped to the inner shape.
    let clip = FlippedView()
    private let borderLayer = CAGradientLayer()
    private let borderMask = CAShapeLayer()
    /// Drawn only outside the window, like Hyprland, so it never shows through translucent content.
    private let shadowLayer = CALayer()
    private let shadowMask = CAShapeLayer()
    /// Blurs what is behind the view. Only with `decoration:blur`.
    private var blurView: NSVisualEffectView?
    /// `.behindWindow` blurs other apps and the desktop (tiles); `.withinWindow` blurs
    /// the tiles underneath (HUD panels).
    private let blurBlending: NSVisualEffectView.BlendingMode
    /// Holds the blur and gives it the window's shape (NSVisualEffectView manages its own layers).
    private let blurHost = NSView()
    private let blurMask = CAShapeLayer()
    /// Content clip shape when corners aren't circular (Core Animation's cornerRadius only does arcs).
    private let clipMask = CAShapeLayer()

    private(set) var targetFrame: CGRect = .zero
    private var frameTween: Tween<CGRect>?
    private var alphaTween: Tween<CGFloat>?
    private var frameDone: (() -> Void)?
    private var alphaDone: (() -> Void)?
    private(set) var decoration: Decoration
    private(set) var isActive = false

    init(decoration: Decoration, active: Bool = false, blurBlending: NSVisualEffectView.BlendingMode = .behindWindow) {
        self.decoration = decoration
        self.isActive = active
        self.blurBlending = blurBlending
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false

        shadowLayer.zPosition = -100
        shadowLayer.shadowOffset = .zero
        shadowMask.fillRule = .evenOdd
        shadowLayer.mask = shadowMask
        layer?.addSublayer(shadowLayer)

        blurHost.wantsLayer = true
        blurHost.layer?.mask = blurMask

        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        // Opacity applies to the content and its backdrop as one image.
        clip.layer?.allowsGroupOpacity = true
        addSubview(blurHost)  // below the content
        addSubview(clip)

        borderLayer.mask = borderMask
        borderLayer.zPosition = 100
        borderMask.fillColor = nil
        borderMask.strokeColor = NSColor.black.cgColor
        layer?.addSublayer(borderLayer)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }

    /// Subclasses call this at the end of their init, once their own views exist.
    func finishSetup() {
        applyDecoration(animated: false, duration: 0)
        applyOpacity(animation: nil)
    }

    // MARK: Hooks

    /// `targetFrame` or the border width changed: lay out the content for the final size.
    func targetFrameDidChange() {}
    /// Inside the decoration's animation transaction.
    func decorationDidApply() {}
    /// After the clip, border, and shadow got their frames.
    func chromeDidLayout() {}

    // MARK: Decoration

    /// `opacityAnimation` is Hyprland's fadeSwitch: the active/inactive opacity change.
    func setDecoration(_ d: Decoration, active: Bool, borderDuration: Double, opacityAnimation: (Double, Bezier)? = nil) {
        let changed = d != decoration || active != isActive
        let borderChanged = d.borderSize != decoration.borderSize
        decoration = d
        isActive = active
        guard changed else { return }
        applyDecoration(animated: borderDuration > 0, duration: borderDuration)
        applyOpacity(animation: opacityAnimation)
        // The content sits inside the border, so a new width resizes it.
        if borderChanged { targetFrameDidChange() }
    }

    private var contentOpacity: CGFloat { isActive ? decoration.activeOpacity : decoration.inactiveOpacity }

    private func applyOpacity(animation: (Double, Bezier)?) {
        let target = contentOpacity
        guard clip.alphaValue != target else { return }
        guard let (duration, curve) = animation, duration > 0 else {
            clip.alphaValue = target
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(
                controlPoints: Float(curve.x1), Float(curve.y1), Float(curve.x2), Float(curve.y2))
            clip.animator().alphaValue = target
        }
    }

    private func updateBlur() {
        if decoration.blur, blurView == nil {
            let v = NSVisualEffectView()
            v.blendingMode = blurBlending
            v.material = .hudWindow
            v.state = .active
            v.appearance = NSAppearance(named: .darkAqua)
            blurHost.addSubview(v)
            v.autoresizingMask = [.width, .height]
            v.frame = blurHost.bounds
            blurView = v
        } else if !decoration.blur, let v = blurView {
            v.removeFromSuperview()
            blurView = nil
        }
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
        decorationDidApply()
        CATransaction.commit()
        shadowLayer.shadowOpacity = decoration.shadow ? 1 : 0
        shadowLayer.shadowRadius = decoration.shadowRange / 2
        shadowLayer.shadowColor = decoration.shadowColor.cg
        updateBlur()
        layoutChrome()
    }

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
        let power = Double(decoration.roundingPower)
        func shape(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
            RoundedShape.path(in: rect, radius: Double(radius), power: power)
        }
        clip.frame = bounds.insetBy(dx: b, dy: b)
        let clipRadius = max(0, r - b)
        if abs(power - 2) < 0.01 {
            // Circular corners: Core Animation's own rounding is cheaper than a mask.
            clip.layer?.mask = nil
            clip.layer?.cornerRadius = clipRadius
        } else {
            clip.layer?.cornerRadius = 0
            clipMask.frame = clip.bounds
            clipMask.path = shape(clip.bounds, clipRadius)
            if clip.layer?.mask !== clipMask { clip.layer?.mask = clipMask }
        }
        borderLayer.frame = bounds
        borderMask.frame = bounds
        borderMask.lineWidth = b
        borderMask.path = shape(bounds.insetBy(dx: b / 2, dy: b / 2), max(0, r - b / 2))
        borderLayer.isHidden = b <= 0
        let outline = shape(bounds, r)
        shadowLayer.frame = bounds
        shadowLayer.shadowPath = outline
        // Mask = a generous outer rect minus the window shape (even-odd).
        let spread = decoration.shadowRange * 3 + 10
        let maskPath = CGMutablePath()
        maskPath.addRect(bounds.insetBy(dx: -spread, dy: -spread))
        maskPath.addPath(outline)
        shadowMask.frame = bounds
        shadowMask.path = maskPath
        blurHost.frame = clip.frame
        blurHost.isHidden = blurView == nil
        blurMask.frame = blurHost.bounds
        blurMask.path = shape(blurHost.bounds, clipRadius)
        chromeDidLayout()
        CATransaction.commit()
    }

    // MARK: Animation

    /// Moves to `target`, animating from `from` (or the current frame) when a duration is given.
    func move(to target: CGRect, from: CGRect? = nil, duration: Double, curve: Bezier, animator: Animator, completion: (() -> Void)? = nil) {
        targetFrame = target
        // Resize the content once, to its final size.
        targetFrameDidChange()
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
        // Whole-view alpha: only open/close/workspace fades. Active/inactive opacity lives on `clip`.
        let target = to
        let start = from ?? alphaValue
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
