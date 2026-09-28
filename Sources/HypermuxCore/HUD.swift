import CoreGraphics
import Foundation

/// Where a HUD element sits inside its anchor area. Like a Hyprland layer
/// surface's anchor edges, reduced to nine spots.
public enum HUDPosition: String, CaseIterable, Sendable {
    case center, top, bottom, left, right
    case topLeft = "top_left", topRight = "top_right"
    case bottomLeft = "bottom_left", bottomRight = "bottom_right"

    /// Accepts `top_right`, `top-right`, `topright`, and `top right`.
    public init?(config raw: String) {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        if let p = HUDPosition(rawValue: s) {
            self = p
        } else if let p = HUDPosition.allCases.first(where: { $0.rawValue.replacingOccurrences(of: "_", with: "") == s }) {
            self = p
        } else {
            return nil
        }
    }

    /// -1 = left, 0 = centered, 1 = right.
    var column: Int {
        switch self {
        case .left, .topLeft, .bottomLeft: -1
        case .right, .topRight, .bottomRight: 1
        default: 0
        }
    }

    /// -1 = top, 0 = centered, 1 = bottom.
    var row: Int {
        switch self {
        case .top, .topLeft, .topRight: -1
        case .bottom, .bottomLeft, .bottomRight: 1
        default: 0
        }
    }

    /// The edge a plain `slide` comes in from: the nearest one, preferring the side
    /// (a corner toast slides in sideways, like most notification daemons).
    public var nearestEdge: Direction? {
        if column != 0 { return column < 0 ? .left : .right }
        if row != 0 { return row < 0 ? .up : .down }
        return nil
    }
}

/// The `hud { }` config section. Anything unset follows Ghostty (font) or the
/// window decoration (borders, rounding, shadow, blur).
public struct HUDSettings: Equatable, Sendable {
    /// Nil = Ghostty's `font-family`, else the system monospaced font.
    public var fontFamily: String?
    /// Nil = Ghostty's `font-size`.
    public var fontSize: Double?
    public var notificationPosition: HUDPosition = .topRight
    /// Seconds. 0 keeps notifications until clicked.
    public var notificationTimeout: Double = 5
    public var maxNotifications = 5
    public var notificationWidth: Double = 380

    public init() {}
}

/// What a HUD element is positioned against.
public enum HUDAnchor: Equatable, Sendable {
    /// The whole monitor window.
    case monitor(HUDPosition)
    /// The monitor minus reserved space (the bar).
    case workArea(HUDPosition)
    /// One tile's frame. The element follows the tile.
    case client(ClientID, HUDPosition)

    public var position: HUDPosition {
        switch self {
        case .monitor(let p), .workArea(let p), .client(_, let p): p
        }
    }
}

public enum HUDLayout {
    /// The rect an anchor refers to. Nil when a client anchor's tile is gone.
    public static func area(
        for anchor: HUDAnchor, monitor: CGRect, workArea: CGRect, clientFrame: (ClientID) -> CGRect?
    ) -> CGRect? {
        switch anchor {
        case .monitor: monitor
        case .workArea: workArea
        case .client(let id, _): clientFrame(id)
        }
    }

    /// Frame for an element of `size` at `position` in `area`, `margin` in from the edges it touches.
    /// An element larger than the area is shrunk to fit.
    public static func place(_ size: CGSize, at position: HUDPosition, in area: CGRect, margin: Double) -> CGRect {
        let inner = area.insetBy(dx: min(margin, area.width / 2), dy: min(margin, area.height / 2))
        let w = min(size.width, inner.width), h = min(size.height, inner.height)
        let x: Double = switch position.column {
        case -1: inner.minX
        case 1: inner.maxX - w
        default: area.midX - w / 2
        }
        let y: Double = switch position.row {
        case -1: inner.minY
        case 1: inner.maxY - h
        default: area.midY - h / 2
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Frames for a stack of elements. The first one sits at `position`; the rest
    /// follow away from its edge (downward, or upward for bottom positions).
    /// Centered rows stack as one block centered on the anchor.
    public static func stack(
        _ sizes: [CGSize], at position: HUDPosition, in area: CGRect, margin: Double, spacing: Double
    ) -> [CGRect] {
        guard !sizes.isEmpty else { return [] }
        let blockW = sizes.map(\.width).max() ?? 0
        let blockH = sizes.map(\.height).reduce(0, +) + spacing * Double(sizes.count - 1)
        let block = place(CGSize(width: blockW, height: blockH), at: position, in: area, margin: margin)
        let upward = position.row == 1
        var y = upward ? block.maxY : block.minY
        return sizes.map { s in
            let w = min(s.width, block.width)
            let x: Double = switch position.column {
            case -1: block.minX
            case 1: block.maxX - w
            default: block.midX - w / 2
            }
            let r: CGRect
            if upward {
                r = CGRect(x: x, y: y - s.height, width: w, height: s.height)
                y -= s.height + spacing
            } else {
                r = CGRect(x: x, y: y, width: w, height: s.height)
                y += s.height + spacing
            }
            return r
        }
    }
}

/// A Hyprland layer animation style: `slide [top|bottom|left|right]`, `popin [N%]`, or `fade`.
public enum LayerAnimationStyle: Equatable, Sendable {
    /// From an edge. Nil = the element's nearest edge.
    case slide(Direction?)
    /// Scaled around the center, from `scale` to full size.
    case popin(Double)
    case fade

    /// Unknown or missing styles fall back to a nearest-edge slide.
    public init(_ raw: String?) {
        let parts = (raw ?? "").lowercased().split(separator: " ").map(String.init)
        switch parts.first {
        case "popin":
            let pct = parts.dropFirst().first.map { $0.replacingOccurrences(of: "%", with: "") }.flatMap(Double.init) ?? 80
            self = .popin(min(max(pct, 10), 100) / 100)
        case "fade":
            self = .fade
        default:
            self = .slide(parts.dropFirst().first.flatMap(Direction.init(hyprland:)))
        }
    }

    /// Where an element with final frame `frame` starts (on the way in) or ends (on the way out).
    /// A slide travels `distance` points; Hyprland moves it fully off the edge, which inside
    /// a window would cross other tiles, so the host passes something shorter.
    public func offscreen(_ frame: CGRect, position: HUDPosition, distance: Double) -> CGRect {
        switch self {
        case .fade:
            return frame
        case .popin(let s):
            let w = frame.width * s, h = frame.height * s
            return CGRect(x: frame.midX - w / 2, y: frame.midY - h / 2, width: w, height: h)
        case .slide(let edge):
            switch edge ?? position.nearestEdge ?? .up {
            case .left: return frame.offsetBy(dx: -distance, dy: 0)
            case .right: return frame.offsetBy(dx: distance, dy: 0)
            case .up: return frame.offsetBy(dx: 0, dy: -distance)
            case .down: return frame.offsetBy(dx: 0, dy: distance)
            }
        }
    }
}
