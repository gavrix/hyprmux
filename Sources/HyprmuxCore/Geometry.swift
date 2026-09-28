import CoreGraphics

/// Identifies one managed client (a terminal surface today; maybe a browser later).
public struct ClientID: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let raw: UInt64
    public init(_ raw: UInt64) { self.raw = raw }
    public static func < (a: ClientID, b: ClientID) -> Bool { a.raw < b.raw }
    public var description: String { "c\(raw)" }
}

public enum Direction: String, Sendable, CaseIterable {
    case left, right, up, down

    /// Accepts Hyprland spellings: l/r/u/d, t/b, left/right/up/down/top/bottom.
    public init?(hyprland s: String) {
        switch s.trimmingCharacters(in: .whitespaces).lowercased() {
        case "l", "left": self = .left
        case "r", "right": self = .right
        case "u", "t", "up", "top": self = .up
        case "d", "b", "down", "bottom": self = .down
        default: return nil
        }
    }

    public var isHorizontal: Bool { self == .left || self == .right }
}

/// CSS-style insets, as used by `gaps_in` / `gaps_out`.
public struct Insets: Equatable, Sendable {
    public var top, right, bottom, left: Double
    public init(top: Double, right: Double, bottom: Double, left: Double) {
        self.top = top; self.right = right; self.bottom = bottom; self.left = left
    }
    public init(all v: Double) { self.init(top: v, right: v, bottom: v, left: v) }
    public static let zero = Insets(all: 0)
}

// All rects in HyprmuxCore use a top-left origin (y grows downward), like Hyprland.
public extension CGRect {
    func inset(by i: Insets) -> CGRect {
        CGRect(x: minX + i.left, y: minY + i.top,
               width: max(0, width - i.left - i.right),
               height: max(0, height - i.top - i.bottom))
    }

    var center: CGPoint { CGPoint(x: midX, y: midY) }

    /// Nearest point inside the rect.
    func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, minX), maxX), y: min(max(p.y, minY), maxY))
    }

    func distance(to p: CGPoint) -> Double {
        let c = clamp(p)
        return hypot(c.x - p.x, c.y - p.y)
    }
}

enum DirectionalSearch {
    /// Picks the best neighbor of `from` in `direction`.
    ///
    /// Candidates must lie on that side of `from`. Among them we prefer ones
    /// that overlap `from` on the perpendicular axis, then the closest edge,
    /// then the most recently focused (`recency`: higher = more recent).
    static func neighbor(
        of from: CGRect,
        direction: Direction,
        candidates: [(ClientID, CGRect)],
        recency: [ClientID: Int]
    ) -> ClientID? {
        let eps = 2.0
        struct Scored { let id: ClientID; let overlaps: Bool; let dist: Double; let overlap: Double; let recent: Int }
        var scored: [Scored] = []
        for (id, r) in candidates {
            let onSide: Bool
            let dist: Double
            let overlap: Double
            switch direction {
            case .left:
                onSide = r.maxX <= from.minX + eps
                dist = from.minX - r.maxX
                overlap = min(r.maxY, from.maxY) - max(r.minY, from.minY)
            case .right:
                onSide = r.minX >= from.maxX - eps
                dist = r.minX - from.maxX
                overlap = min(r.maxY, from.maxY) - max(r.minY, from.minY)
            case .up:
                onSide = r.maxY <= from.minY + eps
                dist = from.minY - r.maxY
                overlap = min(r.maxX, from.maxX) - max(r.minX, from.minX)
            case .down:
                onSide = r.minY >= from.maxY - eps
                dist = r.minY - from.maxY
                overlap = min(r.maxX, from.maxX) - max(r.minX, from.minX)
            }
            guard onSide else { continue }
            scored.append(Scored(id: id, overlaps: overlap > 0, dist: max(0, dist), overlap: overlap, recent: recency[id] ?? -1))
        }
        let best = scored.min { a, b in
            if a.overlaps != b.overlaps { return a.overlaps }
            if abs(a.dist - b.dist) > eps { return a.dist < b.dist }
            if a.recent != b.recent { return a.recent > b.recent }
            return a.overlap > b.overlap
        }
        return best?.id
    }
}
