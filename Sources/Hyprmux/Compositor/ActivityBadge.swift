import AppKit
import HyprmuxCore
import QuartzCore

/// A workspace pill's activity (WorkspaceActivity): a row of bubbles, one per status
/// with tiles in it, most urgent first, each with its count.
///
/// The bubbles are alive. A working bubble wobbles like a drop of liquid, breathes, and
/// sends out a slow ripple. A needs-you bubble wobbles and ripples faster. A done bubble
/// sits still and glows. Bubbles pop in on a spring, squash when their count changes,
/// and slide over when a neighbor comes or goes.
///
/// When a tile finishes, a drop leaves its bubble, hops over to the done bubble, and
/// changes color on the way. It lands with a splash: the done bubble squashes, a ring
/// and sparks burst out, and its count goes up. With Reduce Motion the bubbles only fade.
final class ActivityBadge: CALayer {
    static let height: CGFloat = 14
    /// Space between bubbles. Touching bubbles read as one number ("1" "2" as "12").
    private static let gap: CGFloat = 2
    /// A drop's flight, and the wait between drops when several tiles finish at once.
    private static let flight: CFTimeInterval = 0.55
    private static let stagger: CFTimeInterval = 0.16
    static let font: NSFont = {
        let base = NSFont.systemFont(ofSize: 9.5, weight: .bold)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 9.5) } ?? base
    }()

    private var bubbles: [String: Bubble] = [:]
    private(set) var activity = WorkspaceActivity()
    /// Every bubble's ripple, below all the bubbles, so a ripple never covers a neighbor.
    private let ripples = CALayer()

    override init() {
        super.init()
        masksToBounds = false
        // Adding a layer (a bubble, a drop) would otherwise crossfade the whole badge.
        actions = ["sublayers": NSNull()]
        ripples.actions = ["sublayers": NSNull()]
        ripples.zPosition = -1
        addSublayer(ripples)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// The width a cluster for `a` takes, so its pill can make room.
    static func width(for a: WorkspaceActivity) -> CGFloat {
        let widths = a.counts.map { Bubble.width(for: $0.count) }
        guard !widths.isEmpty else { return 0 }
        return widths.reduce(0, +) + gap * CGFloat(widths.count - 1)
    }

    /// Shows `a`: bubbles come, go, and change count. `finished` names the status each
    /// newly done tile came from (WorkspaceActivity.finished); each sends a drop.
    ///
    /// The layer has no size: it marks the middle of the trailing edge, and the bubbles
    /// extend to its left. So a bubble that leaves doesn't shift the others, and a pill
    /// that's still growing doesn't move them.
    func update(_ a: WorkspaceActivity, scale: CGFloat, finished: [String] = []) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let before = bubbles.mapValues(\.frame)
        // Drops start where their bubble was; one whose bubble wasn't shown just counts.
        let drops = reduceMotion ? [] : finished.filter { before[$0] != nil }
        let counts = a.counts
        let wanted = Set(counts.map(\.status))
        for (status, b) in bubbles where !wanted.contains(status) {
            bubbles[status] = nil
            b.leave(reduceMotion: reduceMotion)
        }
        var x = -Self.width(for: a)
        for c in counts {
            let w = Bubble.width(for: c.count)
            let frame = CGRect(x: x, y: -Self.height / 2, width: w, height: Self.height)
            // The done bubble waits for its drops before it counts them.
            let held = c.status == "done" ? drops.count : 0
            if let b = bubbles[c.status] {
                // A bubble a drop leaves flinches (pinch) instead of squashing.
                b.move(to: frame, count: c.count, held: held, quiet: drops.contains(c.status), reduceMotion: reduceMotion)
            } else {
                let b = Bubble(status: c.status, scale: scale)
                bubbles[c.status] = b
                addSublayer(b)
                ripples.addSublayer(b.ripple)
                b.arrive(at: frame, count: c.count, held: held, reduceMotion: reduceMotion)
            }
            x += w + Self.gap
        }
        activity = a
        guard let target = bubbles["done"] else { return }
        for (i, from) in drops.enumerated() {
            let delay = Double(i) * Self.stagger
            bubbles[from]?.pinch(after: delay)
            drop(from: before[from]!, to: target.frame, status: from, delay: delay) { [weak self, weak target] in
                // The done bubble may have gone while the drop flew (its tile was looked at).
                guard let self, let target, target.superlayer === self else { return }
                target.land()
                self.splash(at: target.frame)
            }
        }
    }

    /// The screen moved to another display: text renders at its scale.
    func setScale(_ scale: CGFloat) {
        for b in bubbles.values { b.setScale(scale) }
    }

    /// Fades the whole cluster out and removes it.
    func leave() {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for b in bubbles.values { b.leave(reduceMotion: reduceMotion) }
        bubbles = [:]
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.removeFromSuperlayer() }
    }

    // MARK: Finishing

    /// A drop hops in an arc from one bubble to another, stretching as it flies and turning
    /// from its bubble's color to done's green.
    private func drop(from: CGRect, to: CGRect, status: String, delay: CFTimeInterval, landed: @escaping () -> Void) {
        let d: CGFloat = 7
        let green = Bubble.color("done")
        let dot = CAShapeLayer()
        dot.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        dot.path = CGPath(ellipseIn: dot.bounds, transform: nil)
        dot.fillColor = green
        dot.shadowColor = green
        dot.shadowOffset = .zero
        dot.shadowRadius = 2.5
        dot.shadowOpacity = 0.8
        // Behind the bubbles, above the ripples: it squeezes out from behind its bubble
        // instead of covering the count.
        dot.zPosition = -0.5
        dot.opacity = 0
        dot.position = CGPoint(x: to.midX, y: to.midY)
        addSublayer(dot)

        // Up and over: in the bar's flipped layers, up is -y.
        let start = CGPoint(x: from.midX, y: from.midY), end = CGPoint(x: to.midX, y: to.midY)
        let arc = CGMutablePath()
        arc.move(to: start)
        // A short hop goes higher, so a drop that lands where it started still jumps.
        let lift = 15 + max(0, 10 - abs(end.x - start.x) / 2)
        arc.addQuadCurve(to: end, control: CGPoint(x: (start.x + end.x) / 2, y: min(start.y, end.y) - lift))
        let path = CAKeyframeAnimation(keyPath: "position")
        path.path = arc
        path.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.55, 1)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.12, 0.96, 1]
        let stretch = CAKeyframeAnimation(keyPath: "transform")
        stretch.values = [
            CATransform3DMakeScale(0.4, 0.4, 1),
            CATransform3DMakeScale(0.85, 1.25, 1),
            CATransform3DMakeScale(1.15, 0.9, 1),
            CATransform3DMakeScale(1.25, 0.7, 1),
        ].map { NSValue(caTransform3D: $0) }
        stretch.keyTimes = [0, 0.3, 0.75, 1]
        let tint = CABasicAnimation(keyPath: "fillColor")
        tint.fromValue = Bubble.color(status)
        tint.toValue = green
        let group = CAAnimationGroup()
        group.animations = [path, fade, stretch, tint]
        group.duration = Self.flight
        group.beginTime = convertTime(CACurrentMediaTime(), from: nil) + delay
        group.fillMode = .backwards
        dot.add(group, forKey: "drop")

        // Lands a moment before the drop is gone, so the splash takes over from it.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + Self.flight - 0.05) {
            dot.removeFromSuperlayer()
            landed()
        }
    }

    /// A ring and a handful of sparks burst out of the done bubble, once.
    private func splash(at frame: CGRect) {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let green = Bubble.color("done")
        let r = frame.height / 2

        let ring = CAShapeLayer()
        ring.bounds = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        ring.path = CGPath(roundedRect: ring.bounds, cornerWidth: r, cornerHeight: r, transform: nil)
        ring.fillColor = nil
        ring.strokeColor = green
        ring.lineWidth = 1.5
        ring.position = center
        ring.opacity = 0
        ring.zPosition = 5
        addSublayer(ring)
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = 2.4
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0
        let burst = CAAnimationGroup()
        burst.animations = [grow, fade]
        burst.duration = 0.5
        burst.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(burst, forKey: "burst")

        var parts: [CALayer] = [ring]
        let n = 7
        for i in 0..<n {
            let angle = CGFloat(i) / CGFloat(n) * 2 * .pi + .random(in: -0.25...0.25)
            let dist = r + .random(in: 7...11)
            let spark = CALayer()
            spark.bounds = CGRect(x: 0, y: 0, width: 2.6, height: 2.6)
            spark.cornerRadius = 1.3
            spark.backgroundColor = i.isMultiple(of: 2) ? green : NSColor.white.cgColor
            spark.position = center
            spark.opacity = 0
            spark.zPosition = 5
            addSublayer(spark)
            let fly = CABasicAnimation(keyPath: "position")
            fly.fromValue = NSValue(point: center)
            fly.toValue = NSValue(point: CGPoint(x: center.x + cos(angle) * dist, y: center.y + sin(angle) * dist))
            let shrink = CABasicAnimation(keyPath: "transform.scale")
            shrink.fromValue = 1.2
            shrink.toValue = 0.3
            let out = CABasicAnimation(keyPath: "opacity")
            out.fromValue = 1
            out.toValue = 0
            let g = CAAnimationGroup()
            g.animations = [fly, shrink, out]
            g.duration = .random(in: 0.42...0.55)
            g.timingFunction = CAMediaTimingFunction(controlPoints: 0.1, 0.8, 0.3, 1)
            spark.add(g, forKey: "spark")
            parts.append(spark)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { parts.forEach { $0.removeFromSuperlayer() } }
    }
}

/// One status's bubble: a ripple, a wobbling body with a glow, and the count.
private final class Bubble: CALayer {
    let status: String
    /// Lives in the badge's ripple layer, under every bubble, and follows this bubble.
    let ripple = CAShapeLayer()
    private let body = CAShapeLayer()
    private let label = CATextLayer()
    /// The count it stands for, and how many of those are drops still in flight. It shows
    /// the difference, so the count goes up as each drop lands.
    private var count = 0
    private var pending = 0
    private var size = CGSize.zero
    /// Created for a drop that hasn't landed yet: it appears when the drop does.
    private var waitingForDrop = false

    static func text(_ count: Int) -> String { count > 99 ? "99+" : "\(count)" }

    static func color(_ status: String) -> CGColor { (TileStatus.color(status) ?? .gray).cgColor }

    static func width(for count: Int) -> CGFloat {
        let w = (text(count) as NSString).size(withAttributes: [.font: ActivityBadge.font]).width
        return max(ActivityBadge.height, ceil(w) + 8)
    }

    init(status: String, scale: CGFloat) {
        self.status = status
        super.init()
        let color = Self.color(status)
        ripple.fillColor = color
        ripple.opacity = 0
        body.fillColor = color
        body.shadowColor = color
        body.shadowOffset = .zero
        body.shadowRadius = 3
        body.shadowOpacity = status == "done" ? 0.5 : 0.7
        label.font = ActivityBadge.font
        label.fontSize = ActivityBadge.font.pointSize
        label.foregroundColor = NSColor.white.cgColor
        label.alignmentMode = .center
        label.contentsScale = scale
        // The number changes with a jump, not a crossfade.
        label.actions = ["contents": NSNull()]
        addSublayer(ripple)
        addSublayer(body)
        addSublayer(label)
    }

    override init(layer: Any) {
        status = (layer as? Bubble)?.status ?? ""
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func setScale(_ scale: CGFloat) { label.contentsScale = scale }

    /// `held`: drops on their way here. With all of the count in flight, the bubble waits
    /// unseen for the first one.
    func arrive(at frame: CGRect, count: Int, held: Int, reduceMotion: Bool) {
        self.count = count
        pending = held
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.frame = frame
        ripple.frame = frame
        layout()
        waitingForDrop = held >= count
        if waitingForDrop { opacity = 0 }
        CATransaction.commit()
        if !waitingForDrop { pop(reduceMotion: reduceMotion) }
        startLiving(reduceMotion: reduceMotion)
    }

    func move(to frame: CGRect, count: Int, held: Int, quiet: Bool = false, reduceMotion: Bool) {
        let changed = count != self.count
        let resized = frame.size != self.frame.size
        self.count = count
        pending += held
        CATransaction.begin()
        if reduceMotion {
            CATransaction.setDisableActions(true)
        } else {
            // A little overshoot, like the bubble is pushed over.
            CATransaction.setAnimationDuration(0.45)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.34, 1.5, 0.64, 1))
        }
        self.frame = frame
        ripple.frame = frame
        CATransaction.commit()
        guard changed || resized else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layout()
        CATransaction.commit()
        if resized { startLiving(reduceMotion: reduceMotion) }
        // Drops squash it when they land instead.
        if changed, held == 0, !quiet, !reduceMotion { squash() }
    }

    /// A drop arrived: the count goes up by one, with a squash.
    func land() {
        pending = max(0, pending - 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layout()
        if waitingForDrop {
            waitingForDrop = false
            opacity = 1
        }
        CATransaction.commit()
        squash()
    }

    /// A drop leaves: the bubble flinches.
    func pinch(after delay: CFTimeInterval) {
        let a = CASpringAnimation(keyPath: "transform.scale")
        a.fromValue = 0.8
        a.toValue = 1
        a.stiffness = 300
        a.damping = 9
        a.duration = a.settlingDuration
        a.beginTime = convertTime(CACurrentMediaTime(), from: nil) + delay
        add(a, forKey: "pinch")
    }

    func leave(reduceMotion: Bool) {
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.ripple.removeFromSuperlayer()
            self?.removeFromSuperlayer()
        }
        ripple.removeAllAnimations()
        let fade = Self.basic("opacity", from: 1, to: 0, duration: 0.2)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        add(fade, forKey: "leave")
        if !reduceMotion {
            let shrink = Self.basic("transform.scale", from: 1, to: 0.1, duration: 0.2)
            shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
            shrink.fillMode = .forwards
            shrink.isRemovedOnCompletion = false
            add(shrink, forKey: "shrink")
        }
        CATransaction.commit()
    }

    private func pop(reduceMotion: Bool) {
        if reduceMotion {
            add(Self.basic("opacity", from: 0, to: 1, duration: 0.2), forKey: "arrive")
            return
        }
        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.1
        pop.toValue = 1
        pop.mass = 1
        pop.stiffness = 320
        pop.damping = 11
        pop.duration = pop.settlingDuration
        add(pop, forKey: "arrive")
        add(Self.basic("opacity", from: 0, to: 1, duration: 0.12), forKey: "fade")
    }

    /// The count changed: the bubble squashes, the number jumps.
    private func squash() {
        let squash = CASpringAnimation(keyPath: "transform")
        squash.fromValue = CATransform3DMakeScale(1.3, 0.75, 1)
        squash.toValue = CATransform3DIdentity
        squash.stiffness = 260
        squash.damping = 8
        squash.duration = squash.settlingDuration
        add(squash, forKey: "squash")
        let jump = CASpringAnimation(keyPath: "transform.scale")
        jump.fromValue = 1.6
        jump.toValue = 1
        jump.stiffness = 300
        jump.damping = 10
        jump.duration = jump.settlingDuration
        label.add(jump, forKey: "jump")
    }

    private func layout() {
        size = bounds.size
        let rect = CGRect(origin: .zero, size: size)
        body.frame = rect
        ripple.bounds = rect
        let shape = CGPath(roundedRect: rect, cornerWidth: size.height / 2, cornerHeight: size.height / 2, transform: nil)
        body.path = shape
        ripple.path = shape
        body.shadowPath = shape
        let lineHeight = ceil(ActivityBadge.font.ascender - ActivityBadge.font.descender)
        label.string = Self.text(max(0, count - pending))
        label.frame = CGRect(x: 0, y: (size.height - lineHeight) / 2, width: size.width, height: lineHeight)
    }

    /// The idle motion for this status. Restarted when the size changes, since the wobble
    /// is drawn for a size.
    private func startLiving(reduceMotion: Bool) {
        body.removeAnimation(forKey: "wobble")
        body.removeAnimation(forKey: "glow")
        removeAnimation(forKey: "breathe")
        ripple.removeAllAnimations()
        guard !reduceMotion else { return }
        switch status {
        case "working":
            wobble(amplitude: 0.07, period: 2.6)
            breathe(from: 0.94, to: 1.05, period: 1.1)
            rippleOut(scale: 1.8, opacity: 0.45, period: 1.9)
        case "blocked":
            wobble(amplitude: 0.1, period: 1.3)
            breathe(from: 0.92, to: 1.08, period: 0.55)
            rippleOut(scale: 2.0, opacity: 0.6, period: 1.1)
        default:
            glow(period: 2.2)
        }
    }

    /// The body's outline drifts through blob shapes and back, like liquid.
    private func wobble(amplitude: CGFloat, period: CFTimeInterval) {
        let steps = 16
        let frames = (0...steps).map { i in
            Self.blob(size: size, amplitude: amplitude, phase: CGFloat(i) / CGFloat(steps) * 2 * .pi)
        }
        let a = CAKeyframeAnimation(keyPath: "path")
        a.values = frames
        a.duration = period
        a.repeatCount = .infinity
        a.calculationMode = .linear
        body.add(a, forKey: "wobble")
    }

    private func breathe(from: CGFloat, to: CGFloat, period: CFTimeInterval) {
        let a = Self.basic("transform.scale", from: from, to: to, duration: period)
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // Bubbles don't breathe in lockstep.
        a.timeOffset = Double.random(in: 0..<period)
        add(a, forKey: "breathe")
    }

    private func rippleOut(scale: CGFloat, opacity: Float, period: CFTimeInterval) {
        let grow = Self.basic("transform.scale", from: 1, to: scale, duration: period)
        let fade = Self.basic("opacity", from: opacity, to: 0, duration: period)
        let g = CAAnimationGroup()
        g.animations = [grow, fade]
        g.duration = period
        g.repeatCount = .infinity
        g.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ripple.add(g, forKey: "live")
    }

    private func glow(period: CFTimeInterval) {
        let a = Self.basic("shadowOpacity", from: 0.25, to: 0.9, duration: period)
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        body.add(a, forKey: "glow")
    }

    /// A capsule of `size` with its outline pushed in and out by two slow waves. `phase`
    /// runs 0…2π, and 2π is the same shape as 0, so the motion loops without a seam.
    static func blob(size: CGSize, amplitude: CGFloat, phase: CGFloat) -> CGPath {
        let n = size.width > size.height + 1 ? 16 : 12
        let cx = size.width / 2, cy = size.height / 2
        let r = size.height / 2
        // Half the capsule's straight part; 0 for a circle.
        let l = max(0, size.width / 2 - r)
        let points: [CGPoint] = (0..<n).map { i in
            let t = CGFloat(i) / CGFloat(n) * 2 * .pi
            let c = cos(t), s = sin(t)
            // Where a ray from the center at angle t leaves the capsule.
            var d = abs(s) > 1e-6 ? r / abs(s) : .infinity
            if abs(d * c) > l { d = l * abs(c) + sqrt(max(0, l * l * c * c - l * l + r * r)) }
            let k = 1 + amplitude * (0.6 * sin(3 * t + phase) + 0.4 * sin(2 * t - 2 * phase))
            return CGPoint(x: cx + d * c * k, y: cy + d * s * k)
        }
        // Catmull-Rom through the points, as cubic curves.
        let path = CGMutablePath()
        path.move(to: points[0])
        for i in 0..<n {
            let p0 = points[(i - 1 + n) % n], p1 = points[i], p2 = points[(i + 1) % n], p3 = points[(i + 2) % n]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        path.closeSubpath()
        return path
    }

    private static func basic(_ key: String, from: Any, to: Any, duration: CFTimeInterval) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: key)
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        return a
    }
}
