import AppKit
import HyprmuxCore

/// A notice in a decorated panel: a title in the level color, a count for repeats,
/// and the body in the terminal's font and colors.
final class NotificationView: DecoratedView {
    let noticeID: Notice.ID
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private var tracking: NSTrackingArea?

    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    /// Set when the notice goes away, so a dying view ignores the pointer.
    var closing = false

    init(id: Notice.ID, theme: HUDTheme, level: NoticeLevel) {
        noticeID = id
        super.init(decoration: theme.decoration(for: level), active: true, blurBlending: .withinWindow)
        for l in [titleLabel, countLabel, bodyLabel] {
            l.isSelectable = false
            l.drawsBackground = false
            l.isBordered = false
            clip.addSubview(l)
        }
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        bodyLabel.maximumNumberOfLines = 8
        bodyLabel.lineBreakMode = .byWordWrapping
        bodyLabel.cell?.truncatesLastVisibleLine = true
        countLabel.alignment = .right
        finishSetup()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    // The labels inside never take clicks; the whole panel is one button.
    override func hitTest(_ point: NSPoint) -> NSView? { !isHidden && frame.contains(point) ? self : nil }

    /// Fills in the notice and returns the panel height for `width`.
    func update(_ n: Notice, theme: HUDTheme, width: CGFloat) -> CGFloat {
        setDecoration(theme.decoration(for: n.level), active: true, borderDuration: 0)
        clip.layer?.backgroundColor = theme.background.cgColor
        titleLabel.font = theme.boldFont
        titleLabel.textColor = theme.color(for: n.level)
        titleLabel.stringValue = n.title
        titleLabel.isHidden = n.title.isEmpty
        countLabel.font = theme.font
        countLabel.textColor = theme.secondary
        countLabel.stringValue = n.count > 1 ? "×\(n.count)" : ""
        countLabel.isHidden = n.count <= 1
        bodyLabel.font = theme.font
        // Without a title the body is the headline, so it takes the full foreground.
        bodyLabel.textColor = n.title.isEmpty ? theme.foreground : theme.secondary
        bodyLabel.stringValue = n.body
        bodyLabel.isHidden = n.body.isEmpty
        return layoutLabels(width: width, theme: theme)
    }

    private func layoutLabels(width: CGFloat, theme: HUDTheme) -> CGFloat {
        let d = decoration
        let lineH = ceil(theme.font.ascender - theme.font.descender + theme.font.leading)
        let vPad = max(10, round(lineH * 0.7))
        // A big radius would clip the first and last lines: keep them clear of the corner curve.
        // The curve is measured at the middle of the first line.
        let innerW = width - 2 * d.borderSize
        let firstLine = vPad + lineH / 2
        func sideInset(forHeight h: CGFloat) -> CGFloat {
            let r = min(max(0, d.rounding - d.borderSize), min(innerW, h) / 2)
            return CGFloat(RoundedShape.edgeInset(radius: Double(r), power: Double(d.roundingPower), depth: Double(firstLine)))
        }
        // The height depends on the insets and the insets on the height (through the radius cap):
        // measure once with a guess, then settle.
        var height: CGFloat = 0
        var hPad: CGFloat = 14
        for _ in 0..<2 {
            let textW = max(40, innerW - 2 * hPad)
            var h = vPad
            if !titleLabel.isHidden {
                h += lineH
                if !bodyLabel.isHidden { h += 3 }
            }
            if !bodyLabel.isHidden {
                bodyLabel.preferredMaxLayoutWidth = textW
                h += ceil(bodyLabel.sizeThatFits(CGSize(width: textW, height: 10_000)).height)
            }
            h += vPad
            height = h + 2 * d.borderSize
            hPad = max(14, ceil(sideInset(forHeight: h)) + 8)
        }
        let textW = max(40, innerW - 2 * hPad)
        var y = vPad
        if !titleLabel.isHidden {
            let countW = countLabel.isHidden ? 0 : ceil(countLabel.intrinsicContentSize.width) + 6
            titleLabel.frame = CGRect(x: hPad, y: y, width: textW - countW, height: lineH)
            countLabel.frame = CGRect(x: hPad + textW - countW, y: y, width: countW, height: lineH)
            y += lineH + (bodyLabel.isHidden ? 0 : 3)
        } else if !countLabel.isHidden {
            // No title: the count sits at the top right of the body.
            let countW = ceil(countLabel.intrinsicContentSize.width) + 6
            countLabel.frame = CGRect(x: hPad + textW - countW + 6, y: y, width: countW, height: lineH)
        }
        if !bodyLabel.isHidden {
            let w = countLabel.isHidden || !titleLabel.isHidden ? textW : textW - ceil(countLabel.intrinsicContentSize.width) - 6
            let h = ceil(bodyLabel.sizeThatFits(CGSize(width: w, height: 10_000)).height)
            bodyLabel.frame = CGRect(x: hPad, y: y, width: w, height: h)
        }
        return height
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .cursorUpdate, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseEntered(with event: NSEvent) { if !closing { onHover?(true) } }
    override func mouseExited(with event: NSEvent) { if !closing { onHover?(false) } }
    // A click on a notice acts even while Hyprmux is in the background.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard !closing, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }
}
