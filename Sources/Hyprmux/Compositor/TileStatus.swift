import AppKit
import HyprmuxCore

/// What a tile's content is doing: an agent's state in a terminal, or what an app
/// tile set (`toplevel.set_status`). The same names: working, blocked, done. Shown on
/// the tile's title pill and border (TitlePill, DecoratedView), its tab's dot in a
/// group, and its workspace in the bar (ActivityBadge).
enum TileStatus {
    /// The `activity { }` colors, set from the config.
    struct Palette: Equatable {
        var working: HyprmuxCore.Color
        var blocked: HyprmuxCore.Color
        var done: HyprmuxCore.Color
        var pulse: Bool

        init(_ c: HyprmuxConfig) {
            working = c.activityWorking
            blocked = c.activityBlocked
            done = c.activityDone
            pulse = c.activityPulse
        }
    }

    static var palette = Palette(HyprmuxConfig())

    static func rgba(_ status: String?) -> HyprmuxCore.Color? {
        switch status {
        case "working": palette.working
        case "blocked": palette.blocked
        case "done": palette.done
        default: nil
        }
    }

    static func color(_ status: String?) -> NSColor? { rgba(status).flatMap { NSColor(cgColor: $0.cg) } }

    static func label(_ status: String?) -> String? {
        switch status {
        case "working": "working"
        case "blocked": "needs you"
        case "done": "done"
        default: nil
        }
    }

    /// How long one breath of a status's pulse takes, or nil when it doesn't pulse:
    /// needs you is urgent, working is busy, done is calm.
    static func pulsePeriod(_ status: String?) -> CFTimeInterval? {
        guard palette.pulse, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return nil }
        switch status {
        case "blocked": return 0.45
        case "working": return 0.9
        case "done": return 1.4
        default: return nil
        }
    }

    /// Adds `animation` to `layer` phased to the wall clock, so every tile with the same
    /// period breathes in step. The animation autoreverses: one cycle is two periods.
    static func addInPhase(_ animation: CABasicAnimation, to layer: CALayer, key: String) {
        let cycle = animation.duration * 2
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil)
        animation.timeOffset = CACurrentMediaTime().truncatingRemainder(dividingBy: cycle)
        layer.add(animation, forKey: key)
    }
}
