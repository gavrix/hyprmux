import AppKit
import HyprmuxCore

/// One job in a tile's job bar.
struct JobChip: Equatable {
    let id: ClientID
    let title: String
    /// TileStatus: working, blocked, done.
    let status: String?
    let started: Date?
    let ended: Date?
}

/// A tile's job bar, along its bottom edge: one chip per background job
/// (WindowManager+Attached.swift). Hovering a chip peeks at its job, a click expands it.
/// The compositor handles the pointer: this view draws and answers `hit`.
final class JobBarView: NSView {
    enum Hit: Equatable {
        case chip(ClientID, CGRect)
        /// The "+N" chip: the jobs behind it.
        case overflow([ClientID], CGRect)
    }

    private var chips: [JobChip] = []
    private var expanded: ClientID?
    private var peeked: ClientID?
    private var style: GroupBarStyle?
    private var layout = JobBarLayout(natural: [], available: 0)
    private var timer: Timer?
    /// The pointer left the bar. Mouse-moved events stop at the window's edge, so this is
    /// how a peek ends when the pointer leaves the window through the bar.
    var onPointerExit: (() -> Void)?
    /// Horizontal inset so the first and last chip clear rounded corners.
    var sideInset: CGFloat = 0 { didSet { if sideInset != oldValue { relayout() } } }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// Clicks on the bar never reach the terminal under it.
    override func mouseDown(with event: NSEvent) {}

    func update(chips: [JobChip], expanded: ClientID?, peeked: ClientID?, style: GroupBarStyle) {
        guard chips != self.chips || expanded != self.expanded || peeked != self.peeked || style != self.style else { return }
        self.chips = chips
        self.expanded = expanded
        self.peeked = peeked
        self.style = style
        relayout()
        updateTimer()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { relayout() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseExited(with event: NSEvent) { onPointerExit?() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTimer()
    }

    /// What's under a point in this view's coordinates. Rects are in its coordinates too.
    func hit(_ p: CGPoint) -> Hit? {
        guard bounds.contains(p) else { return nil }
        for (i, r) in layout.frames.enumerated() where chipRect(r).contains(p) {
            return .chip(chips[i].id, chipRect(r))
        }
        if let r = layout.overflow, chipRect(r).contains(p) {
            return .overflow(chips.suffix(layout.hidden).map(\.id), chipRect(r))
        }
        return nil
    }

    /// A shown chip's rect, in this view's coordinates.
    func rect(of id: ClientID) -> CGRect? {
        guard let i = chips.firstIndex(where: { $0.id == id }), i < layout.frames.count else { return nil }
        return chipRect(layout.frames[i])
    }

    // MARK: Layout

    private static let pad: CGFloat = 7
    private static let dotSize: CGFloat = 7
    private static let maxChip: CGFloat = 240

    private var font: NSFont { NSFont.systemFont(ofSize: style?.fontSize ?? 11, weight: .medium) }
    private var timeFont: NSFont { NSFont.monospacedDigitSystemFont(ofSize: (style?.fontSize ?? 11) - 1, weight: .regular) }
    private var inset: CGFloat { max(4, sideInset) }

    private func chipRect(_ r: ClosedRange<CGFloat>) -> CGRect {
        CGRect(x: inset + r.lowerBound, y: 3, width: r.upperBound - r.lowerBound, height: max(0, bounds.height - 6))
    }

    private func relayout() {
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: font]
        let timeAttrs: [NSAttributedString.Key: Any] = [.font: timeFont]
        let now = Date()
        let natural = chips.map { c -> CGFloat in
            var w = Self.pad + Self.dotSize + 5 + ceil((displayTitle(c) as NSString).size(withAttributes: titleAttrs).width)
            if let t = elapsed(c, now: now) { w += 6 + ceil((t as NSString).size(withAttributes: timeAttrs).width) }
            return min(Self.maxChip, w + Self.pad)
        }
        layout = JobBarLayout(natural: natural, available: bounds.width - 2 * inset) { [timeAttrs] n in
            ceil(("+\(n)" as NSString).size(withAttributes: timeAttrs).width) + 14
        }
        needsDisplay = true
    }

    private func displayTitle(_ c: JobChip) -> String { c.title.isEmpty ? "job" : c.title }

    private func elapsed(_ c: JobChip, now: Date) -> String? {
        guard let start = c.started else { return nil }
        return JobBarLayout.elapsed((c.ended ?? now).timeIntervalSince(start))
    }

    /// Running jobs' times tick once a second.
    private func updateTimer() {
        let ticking = window != nil && chips.contains { $0.started != nil && $0.ended == nil }
        if ticking, timer == nil {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.relayout() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !ticking {
            timer?.invalidate()
            timer = nil
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let style else { return }
        let inactive = NSColor(cgColor: style.inactive.cg) ?? .gray
        let active = NSColor(cgColor: style.active.cg) ?? .white
        let ink = NSColor(cgColor: style.text.cg) ?? .white
        inactive.withAlphaComponent(0.35).setFill()
        bounds.fill()
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let now = Date()
        for (i, r) in layout.frames.enumerated() {
            let c = chips[i]
            let rect = chipRect(r)
            let isExpanded = c.id == expanded, isPeeked = c.id == peeked
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            (isExpanded ? active : inactive).setFill()
            path.fill()
            if isPeeked {
                active.setStroke()
                path.lineWidth = 1
                path.stroke()
            }
            let d = Self.dotSize
            let dotX = layout.style == .dot ? rect.midX - d / 2 : rect.minX + Self.pad
            (TileStatus.color(c.status) ?? ink.withAlphaComponent(0.5)).setFill()
            NSBezierPath(ovalIn: CGRect(x: dotX, y: rect.midY - d / 2, width: d, height: d)).fill()
            guard layout.style == .full else { continue }
            let alpha: CGFloat = isExpanded || isPeeked ? 1 : 0.75
            var textRight = rect.maxX - Self.pad
            if let t = elapsed(c, now: now) {
                let attrs: [NSAttributedString.Key: Any] = [.font: timeFont, .foregroundColor: ink.withAlphaComponent(alpha * 0.7)]
                let s = (t as NSString).size(withAttributes: attrs)
                let x = textRight - s.width
                if x > dotX + d + 24 {
                    (t as NSString).draw(at: CGPoint(x: x, y: rect.midY - s.height / 2), withAttributes: attrs)
                    textRight = x - 6
                }
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font, .paragraphStyle: para, .foregroundColor: ink.withAlphaComponent(alpha),
            ]
            let title = displayTitle(c) as NSString
            let h = title.size(withAttributes: attrs).height
            let x = dotX + d + 5
            title.draw(with: CGRect(x: x, y: rect.midY - h / 2, width: max(0, textRight - x), height: h),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        }
        if let r = layout.overflow {
            let rect = chipRect(r)
            inactive.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: timeFont, .foregroundColor: ink.withAlphaComponent(0.85)]
            let s = ("+\(layout.hidden)" as NSString)
            let size = s.size(withAttributes: attrs)
            s.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
        }
    }
}
