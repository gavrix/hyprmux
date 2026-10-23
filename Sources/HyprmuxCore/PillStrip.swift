import CoreGraphics

/// Which part of the bar's workspace pills shows when they don't all fit. The pills
/// scroll like a tab strip: the active one stays in view, and the strip only moves when
/// the active pill would leave it. A clipped edge shows a count of the pills past it.
///
/// Positions are in content coordinates: the first pill starts at 0, and `offset` is the
/// content position at the strip's left edge.
public struct PillStrip: Equatable, Sendable {
    /// The count at a clipped edge covers this much of the strip.
    public static let indicatorWidth: CGFloat = 28
    /// Room kept beside the active pill, so the pill next to it peeks in.
    public static let context: CGFloat = 14

    public let starts: [CGFloat]
    public let widths: [CGFloat]
    public let offset: CGFloat
    /// The strip's width.
    public let available: CGFloat
    /// An edge with pills past it, which shows their count.
    public let leftIndicator: Bool
    public let rightIndicator: Bool

    /// Lays the pills out side by side, `gap` apart, at a given scroll offset (clamped).
    public init(widths: [CGFloat], gap: CGFloat, available: CGFloat, offset: CGFloat) {
        var x: CGFloat = 0
        var starts: [CGFloat] = []
        for w in widths {
            starts.append(x)
            x += w + gap
        }
        self.starts = starts
        self.widths = widths
        self.available = available
        let total = Self.total(starts, widths)
        let maxOffset = max(0, total - available)
        let o = min(max(0, offset), maxOffset)
        self.offset = o
        leftIndicator = o > 0.5
        rightIndicator = o < maxOffset - 0.5
    }

    /// Everything fits: no scrolling.
    public var fits: Bool { !leftIndicator && !rightIndicator }

    /// The content range pills show in, between the counts.
    public var visible: ClosedRange<CGFloat> {
        let lo = offset + (leftIndicator ? Self.indicatorWidth : 0)
        let hi = offset + available - (rightIndicator ? Self.indicatorWidth : 0)
        return lo...max(lo, hi)
    }

    /// Pills cut off on the left, and on the right, fully or partly. By index.
    public var hiddenBefore: [Int] { starts.indices.filter { starts[$0] < visible.lowerBound - 0.5 } }
    public var hiddenAfter: [Int] { starts.indices.filter { starts[$0] + widths[$0] > visible.upperBound + 0.5 } }

    /// The offset that keeps the pill at `active` in view, moving as little as possible
    /// from `previous`. Room for the counts is kept on both sides, except at the ends.
    public static func offset(widths: [CGFloat], gap: CGFloat, available: CGFloat, active: Int?,
                              previous: CGFloat) -> CGFloat {
        let strip = PillStrip(widths: widths, gap: gap, available: available, offset: previous)
        guard let active, strip.starts.indices.contains(active), total(strip.starts, widths) > available else {
            return strip.offset
        }
        let a0 = strip.starts[active], a1 = a0 + widths[active]
        let edge = indicatorWidth + context
        var o = strip.offset
        if o < a1 + edge - available { o = a1 + edge - available }
        if o > a0 - edge { o = a0 - edge }  // a pill wider than the strip shows its start
        return PillStrip(widths: widths, gap: gap, available: available, offset: o).offset
    }

    private static func total(_ starts: [CGFloat], _ widths: [CGFloat]) -> CGFloat {
        guard let s = starts.last, let w = widths.last else { return 0 }
        return s + w
    }
}
