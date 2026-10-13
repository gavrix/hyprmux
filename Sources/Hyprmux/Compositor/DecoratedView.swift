import AppKit
import HyprmuxCore

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
    var shadowColor: HyprmuxCore.Color
    var blur = false
    /// The title pill on the top border (TitlePill).
    var title = false
    var titleFontSize: CGFloat = 11
    var titleShowsID = true
    /// Unfocused tiles' borders take their activity's color (TileStatus).
    var activityBorder = true
    var activity: TileStatus.Palette

    init(_ c: HyprmuxConfig) {
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
        title = c.titleEnabled
        titleFontSize = c.titleFontSize
        titleShowsID = c.titleShowsID
        activityBorder = c.activityBorder
        activity = TileStatus.Palette(c)
    }
}

extension HyprmuxCore.Color {
    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

/// A frame with Hyprmux's window decoration: gradient border, outside-only shadow,
/// rounded or squircle clip, optional blur, and frame/alpha animation (see Animation).
/// Tiles (`ClientView`) and HUD panels share it, so they look alike.
///
/// Content goes in `clip`. Subclasses hook in through the `…DidChange` methods.
class DecoratedView: NSView {
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
    private(set) var decoration: Decoration
    private(set) var isActive = false
    /// What the content is doing (TileStatus). While unfocused, the border shows it.
    private(set) var activityStatus: String?

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

    /// The content's activity changed: the border recolors (unfocused) and pulses.
    func setActivityStatus(_ status: String?, duration: Double) {
        guard status != activityStatus else { return }
        activityStatus = status
        applyDecoration(animated: duration > 0, duration: duration)
    }

    /// The border's activity color, when it shows one: unfocused, with a status.
    var borderActivity: String? {
        guard decoration.activityBorder, !isActive, TileStatus.rgba(activityStatus) != nil else { return nil }
        return activityStatus
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
            ctx.timingFunction = curve.timingFunction
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
        var g = isActive ? decoration.activeBorder : decoration.inactiveBorder
        if let c = TileStatus.rgba(borderActivity) { g = Gradient([c]) }
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
        updateBorderPulse()
        shadowLayer.shadowOpacity = decoration.shadow ? 1 : 0
        shadowLayer.shadowRadius = decoration.shadowRange / 2
        shadowLayer.shadowColor = decoration.shadowColor.cg
        updateBlur()
        layoutChrome()
    }

    /// An activity border breathes: it fades toward transparent and back.
    private func updateBorderPulse() {
        let period = borderActivity.flatMap(TileStatus.pulsePeriod)
        let key = "activityPulse"
        let current = (borderLayer.animation(forKey: key) as? CABasicAnimation)?.duration
        guard period != current else { return }
        borderLayer.removeAnimation(forKey: key)
        guard let period else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1
        a.toValue = 0.3
        a.duration = period
        TileStatus.addInPhase(a, to: borderLayer, key: key)
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

    // Frame and alpha are state: `move` and `fade` set the final values at once, so the
    // view is always where the layout put it. Core Animation then plays the change on
    // screen: record every chrome layer's geometry at the start frame, lay out at the
    // target, and animate each layer from its first value to its last (FLIP). The
    // window server runs those animations. No clock in the app drives a view, so
    // nothing strands a tile half-way when the app is hidden or a display link stops.

    private static let animationKeyPrefix = "hyprmux."
    /// Layers carrying this view's geometry animations, so the next move can replace them.
    private var animatedLayers: [CALayer] = []
    /// Bumped by every move or fade, so a newer one supersedes a pending completion.
    private var frameGeneration = 0
    private var alphaGeneration = 0
    private var frameAnimationEnd: CFTimeInterval = 0
    private var alphaAnimationEnd: CFTimeInterval = 0

    /// Layers that are laid out for the final frame and never animated with the chrome,
    /// with everything under them. Tiles return their content (the surface).
    var layersOutsideChromeAnimation: [CALayer] { [] }

    /// Moves to `target`. With a duration, the screen shows a move from `from` (or from
    /// what's on screen now); `completion` runs when that ends.
    func move(to target: CGRect, from: CGRect? = nil, duration: Double, curve: Bezier, completion: (() -> Void)? = nil) {
        targetFrame = target
        // Resize the content once, to its final size.
        targetFrameDidChange()
        frameGeneration += 1
        guard duration > 0 else {
            removeGeometryAnimations()
            frameAnimationEnd = 0
            setFrameNow(target)
            completion?()
            return
        }
        let first: [GeometryValue]
        if let from {
            setFrameNow(from)
            first = recordGeometry(presented: false)
        } else {
            first = recordGeometry(presented: true)
        }
        removeGeometryAnimations()
        setFrameNow(target)
        let last = Dictionary(recordGeometry(presented: false).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let timing = curve.timingFunction
        var moved = false
        for a in first {
            guard let b = last[a.id], !a.equals(b) else { continue }
            moved = true
            let animation = CABasicAnimation(keyPath: a.key)
            animation.fromValue = a.value
            animation.toValue = b.value
            animation.duration = duration
            animation.timingFunction = timing
            a.layer.add(animation, forKey: Self.animationKeyPrefix + a.key)
            if !animatedLayers.contains(where: { $0 === a.layer }) { animatedLayers.append(a.layer) }
        }
        // Already on screen at the target: nothing to play, so it's done now.
        guard moved else {
            frameAnimationEnd = 0
            completion?()
            return
        }
        frameAnimationEnd = CACurrentMediaTime() + duration
        after(duration, generation: frameGeneration, current: { $0.frameGeneration }, completion)
    }

    /// Sets the whole view's alpha to `to`. With a duration, the screen shows a fade from
    /// `from` (or from what's on screen now); `completion` runs when that ends.
    func fade(from: CGFloat? = nil, to: CGFloat, duration: Double, curve: Bezier, completion: (() -> Void)? = nil) {
        // Whole-view alpha: only open/close/workspace fades. Active/inactive opacity lives on `clip`.
        let key = Self.animationKeyPrefix + "opacity"
        let shown = layer?.animation(forKey: key) != nil ? layer?.presentation().map { CGFloat($0.opacity) } : nil
        let start = from ?? shown ?? alphaValue
        alphaGeneration += 1
        layer?.removeAnimation(forKey: key)
        alphaValue = to
        guard duration > 0 else {
            alphaAnimationEnd = 0
            completion?()
            return
        }
        if start != to {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = Float(start)
            animation.toValue = Float(to)
            animation.duration = duration
            animation.timingFunction = curve.timingFunction
            layer?.add(animation, forKey: key)
        }
        alphaAnimationEnd = CACurrentMediaTime() + duration
        after(duration, generation: alphaGeneration, current: { $0.alphaGeneration }, completion)
    }

    /// True while the screen still shows a move or fade.
    var isAnimating: Bool { CACurrentMediaTime() < max(frameAnimationEnd, alphaAnimationEnd) }

    /// Runs `completion` after `delay`, unless a newer move or fade came first.
    private func after(_ delay: Double, generation: Int, current: @escaping (DecoratedView) -> Int,
                       _ completion: (() -> Void)?) {
        guard let completion else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, current(self) == generation else { return }
            completion()
        }
    }

    private func setFrameNow(_ rect: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = rect
        CATransaction.commit()
    }

    private func removeGeometryAnimations() {
        for layer in animatedLayers {
            for key in GeometryValue.keys { layer.removeAnimation(forKey: Self.animationKeyPrefix + key) }
        }
        animatedLayers.removeAll()
    }

    /// One animatable geometry property of one layer.
    private struct GeometryValue {
        static let keys = ["position", "bounds", "cornerRadius", "path", "shadowPath"]
        let layer: CALayer
        let key: String
        let value: Any?

        func equals(_ other: GeometryValue) -> Bool {
            switch (value, other.value) {
            case (nil, nil): true
            // NSValue, NSNumber, and CGPath all compare by value.
            case let (a?, b?): CFEqual(a as CFTypeRef, b as CFTypeRef)
            default: false
            }
        }

        var id: String { "\(ObjectIdentifier(layer).hashValue).\(key)" }
    }

    /// The geometry of this view's layer and its chrome, in a fixed order. `presented`
    /// reads what's on screen for properties that are animating now.
    private func recordGeometry(presented: Bool) -> [GeometryValue] {
        guard let root = layer else { return [] }
        let skip = layersOutsideChromeAnimation
        var out: [GeometryValue] = []
        func visit(_ l: CALayer) {
            guard !skip.contains(where: { $0 === l }) else { return }
            let shown = presented ? l.presentation() : nil
            func value(_ key: String) -> Any? {
                if let shown, l.animation(forKey: Self.animationKeyPrefix + key) != nil { return shown.value(forKey: key) }
                return l.value(forKey: key)
            }
            out.append(GeometryValue(layer: l, key: "position", value: value("position")))
            out.append(GeometryValue(layer: l, key: "bounds", value: value("bounds")))
            out.append(GeometryValue(layer: l, key: "cornerRadius", value: value("cornerRadius")))
            if l is CAShapeLayer { out.append(GeometryValue(layer: l, key: "path", value: value("path"))) }
            if l.shadowPath != nil { out.append(GeometryValue(layer: l, key: "shadowPath", value: value("shadowPath"))) }
            // A blur view's insides belong to AppKit: it moves as one layer.
            if l === blurView?.layer { return }
            if let mask = l.mask { visit(mask) }
            for s in l.sublayers ?? [] { visit(s) }
        }
        visit(root)
        return out
    }
}

extension CGRect {
    /// Scales the rect around its center.
    func scaled(_ f: Double) -> CGRect {
        let w = width * f, h = height * f
        return CGRect(x: midX - w / 2, y: midY - h / 2, width: w, height: h)
    }
}

extension Bezier {
    var timingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: Float(x1), Float(y1), Float(x2), Float(y2))
    }
}
