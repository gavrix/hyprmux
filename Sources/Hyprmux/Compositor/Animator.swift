import AppKit
import HyprmuxCore

/// A value animated with a Hyprland-style bezier curve.
struct Tween<Value> {
    var from: Value
    var to: Value
    var start: CFTimeInterval
    var duration: Double
    var curve: Bezier

    func progress(_ now: CFTimeInterval) -> Double {
        guard duration > 0 else { return 1 }
        return curve.value(at: min(1, max(0, (now - start) / duration)))
    }

    func finished(_ now: CFTimeInterval) -> Bool { now - start >= duration }
}

extension CGRect {
    func lerp(to b: CGRect, _ t: Double) -> CGRect {
        CGRect(x: minX + (b.minX - minX) * t, y: minY + (b.minY - minY) * t,
               width: width + (b.width - width) * t, height: height + (b.height - height) * t)
    }

    /// Scales the rect around its center.
    func scaled(_ f: Double) -> CGRect {
        let w = width * f, h = height * f
        return CGRect(x: midX - w / 2, y: midY - h / 2, width: w, height: h)
    }
}

protocol Animatable: AnyObject {
    /// Advances animations. Returns true while still animating.
    func step(_ now: CFTimeInterval) -> Bool
}

/// Drives all running animations from one display link.
final class Animator {
    private var link: CADisplayLink?
    private var active: [ObjectIdentifier: Animatable] = [:]
    private weak var hostView: NSView?

    init(hostView: NSView) { self.hostView = hostView }

    static var now: CFTimeInterval { CACurrentMediaTime() }

    func add(_ a: Animatable) {
        active[ObjectIdentifier(a)] = a
        if link == nil, let hostView {
            let l = hostView.displayLink(target: self, selector: #selector(tick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
    }

    @objc private func tick(_ l: CADisplayLink) {
        let now = Self.now
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (k, a) in active where !a.step(now) { active[k] = nil }
        CATransaction.commit()
        if active.isEmpty {
            link?.invalidate()
            link = nil
        }
    }
}
