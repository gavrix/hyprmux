import AppKit
import HyprmuxCore

struct GroupBarStyle: Equatable {
    var height: CGFloat
    var fontSize: CGFloat
    var active: HyprmuxCore.Color
    var inactive: HyprmuxCore.Color
    var text: HyprmuxCore.Color

    init(_ c: HyprmuxConfig) {
        height = c.groupbarHeight
        fontSize = c.groupbarFontSize
        active = c.groupbarActive
        inactive = c.groupbarInactive
        text = c.groupbarText
    }
}

/// Tabs for a group: one equal-width tab per window, click to switch.
final class GroupBarView: NSView {
    var onSelect: ((Int) -> Void)?
    private var titles: [String] = []
    /// Each tab's status (TileStatus), drawn as a dot before its title.
    private var statuses: [String?] = []
    private var active = 0
    private var style: GroupBarStyle?
    /// Horizontal inset so the first and last tab clear rounded corners.
    var sideInset: CGFloat = 0 { didSet { if sideInset != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(titles: [String], statuses: [String?] = [], active: Int, style: GroupBarStyle) {
        guard titles != self.titles || statuses != self.statuses || active != self.active || style != self.style else { return }
        self.titles = titles
        self.statuses = statuses
        self.active = active
        self.style = style
        needsDisplay = true
    }

    private func tabRect(_ i: Int) -> CGRect {
        let n = CGFloat(max(1, titles.count))
        let gap: CGFloat = 2
        let inset = max(gap, sideInset)
        let w = (bounds.width - 2 * inset - gap * (n - 1)) / n
        return CGRect(x: inset + CGFloat(i) * (w + gap), y: 2, width: max(0, w), height: max(0, bounds.height - 4))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let style else { return }
        NSColor(cgColor: style.inactive.cg)?.withAlphaComponent(0.35).setFill()
        bounds.fill()
        let font = NSFont.systemFont(ofSize: style.fontSize, weight: .medium)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        for (i, title) in titles.enumerated() {
            let r = tabRect(i)
            let isActive = i == active
            (NSColor(cgColor: (isActive ? style.active : style.inactive).cg) ?? .gray).setFill()
            NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font, .paragraphStyle: para,
                .foregroundColor: (NSColor(cgColor: style.text.cg) ?? .white).withAlphaComponent(isActive ? 1 : 0.7),
            ]
            let text = (title.isEmpty ? "—" : title) as NSString
            let h = text.size(withAttributes: attrs).height
            var textRect = CGRect(x: r.minX + 6, y: r.midY - h / 2, width: r.width - 12, height: h)
            if i < statuses.count, let dot = TileStatus.color(statuses[i]) {
                let d: CGFloat = 7
                dot.setFill()
                NSBezierPath(ovalIn: CGRect(x: r.minX + 7, y: r.midY - d / 2, width: d, height: d)).fill()
                textRect.origin.x += d + 5
                textRect.size.width -= d + 5
            }
            text.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = titles.indices.first(where: { tabRect($0).contains(p) }) { onSelect?(i) }
    }
}
