import CoreGraphics

/// How a tile's job bar fits its chips (WindowManager+Attached.swift). Chips that need
/// attention come first. When they don't fit, they shrink in steps: titles truncate to a
/// shared width, then chips drop to a status dot, then the last ones go behind a "+N" chip.
public struct JobBarLayout: Equatable, Sendable {
    public enum Style: Equatable, Sendable {
        /// A dot, the title, and the time.
        case full
        /// Only the status dot.
        case dot
    }

    /// Fixed sizes, in points.
    public struct Metrics: Equatable, Sendable {
        public var gap: CGFloat = 4
        /// Narrowest a full chip gets before chips turn into dots.
        public var minFull: CGFloat = 72
        public var dot: CGFloat = 20
        public init() {}
    }

    public let style: Style
    /// Each shown chip's x range, from the bar's leading edge. The first `frames.count`
    /// chips show; the rest sit behind `overflow`.
    public let frames: [ClosedRange<CGFloat>]
    /// The "+N" chip's x range, when some chips don't show.
    public let overflow: ClosedRange<CGFloat>?

    /// How many chips sit behind `overflow`: the last ones.
    public let hidden: Int

    /// Lays out chips whose full widths are `natural` in `available` points.
    /// `overflowWidth(n)` is how wide a "+n" chip is.
    public init(natural: [CGFloat], available: CGFloat, metrics m: Metrics = Metrics(),
                overflowWidth: (Int) -> CGFloat = { _ in 32 }) {
        let n = natural.count
        let gaps = m.gap * CGFloat(max(0, n - 1))
        if n == 0 {
            self.init(style: .full, widths: [], overflow: nil, hidden: 0, gap: m.gap)
            return
        }
        if natural.reduce(0, +) + gaps <= available {
            self.init(style: .full, widths: natural, overflow: nil, hidden: 0, gap: m.gap)
            return
        }
        // Truncate the widest titles first: every chip gets min(natural, cap).
        let cap = Self.waterLevel(natural, total: available - gaps)
        if cap >= m.minFull {
            self.init(style: .full, widths: natural.map { min($0, cap) }, overflow: nil, hidden: 0, gap: m.gap)
            return
        }
        if CGFloat(n) * m.dot + gaps <= available {
            self.init(style: .dot, widths: Array(repeating: m.dot, count: n), overflow: nil, hidden: 0, gap: m.gap)
            return
        }
        var shown = n - 1
        while shown > 0, CGFloat(shown) * (m.dot + m.gap) + overflowWidth(n - shown) > available { shown -= 1 }
        self.init(style: .dot, widths: Array(repeating: m.dot, count: shown),
                  overflow: overflowWidth(n - shown), hidden: n - shown, gap: m.gap)
    }

    private init(style: Style, widths: [CGFloat], overflow: CGFloat?, hidden: Int, gap: CGFloat) {
        var x: CGFloat = 0
        var frames: [ClosedRange<CGFloat>] = []
        for w in widths {
            frames.append(x...(x + w))
            x += w + gap
        }
        self.style = style
        self.frames = frames
        self.overflow = overflow.map { x...(x + $0) }
        self.hidden = hidden
    }

    /// The largest cap where the sum of min(width, cap) fits `total`.
    static func waterLevel(_ widths: [CGFloat], total: CGFloat) -> CGFloat {
        guard total > 0 else { return 0 }
        var remaining = total
        var left = widths.count
        for w in widths.sorted() {
            let even = remaining / CGFloat(left)
            if w > even { return even }
            remaining -= w
            left -= 1
        }
        return widths.max() ?? 0
    }

    /// Chip order: blocked (needs you, or failed) first, then running, then the rest,
    /// then finished; oldest first within each.
    public static func order(_ ids: [ClientID], status: (ClientID) -> String?) -> [ClientID] {
        func rank(_ s: String?) -> Int {
            switch s {
            case "blocked": 0
            case "working": 1
            case "done": 3
            default: 2
            }
        }
        return ids.map { ($0, rank(status($0))) }.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }.map(\.0)
    }

    /// A job's run time, short: 8s, 1m12s, 1h03m.
    public static func elapsed(_ seconds: Double) -> String {
        let t = max(0, Int(seconds))
        if t < 60 { return "\(t)s" }
        func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        if t < 3600 { return "\(t / 60)m\(two(t % 60))s" }
        return "\(t / 3600)h\(two((t % 3600) / 60))m"
    }
}
