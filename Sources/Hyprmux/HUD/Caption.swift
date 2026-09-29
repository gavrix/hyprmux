import AppKit
import HyprmuxCore

/// A title (and optional subtitle) at the top of the window, for demo recordings
/// (`hyprmuxctl caption "Title | subtitle"`). Never takes clicks.
final class CaptionView: DecoratedView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    init(theme: HUDTheme) {
        super.init(decoration: theme.decoration, active: true, blurBlending: .withinWindow)
        for l in [titleLabel, subtitleLabel] {
            l.isSelectable = false
            l.drawsBackground = false
            l.isBordered = false
            l.alignment = .center
            l.lineBreakMode = .byClipping
            clip.addSubview(l)
        }
        finishSetup()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(title: String, subtitle: String, theme: HUDTheme, maxWidth: CGFloat) -> CGSize {
        setDecoration(theme.decoration, active: true, borderDuration: 0)
        clip.layer?.backgroundColor = theme.background.cgColor
        let big = NSFontManager.shared.convert(theme.boldFont, toSize: theme.boldFont.pointSize * 1.6)
        titleLabel.font = big
        titleLabel.textColor = theme.foreground
        titleLabel.stringValue = title
        subtitleLabel.font = theme.font
        subtitleLabel.textColor = theme.secondary
        subtitleLabel.stringValue = subtitle
        subtitleLabel.isHidden = subtitle.isEmpty

        // NSTextField draws with a few points of inset on each side: leave room for them.
        func width(_ s: String, _ f: NSFont) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: f]).width) + 12 }
        let d = decoration
        let titleH = ceil(big.ascender - big.descender)
        let subH = ceil(theme.font.ascender - theme.font.descender)
        let vPad = max(12, round(titleH * 0.45))
        let innerH = vPad + titleH + (subtitle.isEmpty ? 0 : 4 + subH) + vPad
        let r = min(max(0, d.rounding - d.borderSize), innerH / 2)
        let hPad = max(22, ceil(CGFloat(RoundedShape.edgeInset(radius: Double(r), power: Double(d.roundingPower),
                                                               depth: Double(vPad)))) + 14)
        let textW = min(max(width(title, big), subtitle.isEmpty ? 0 : width(subtitle, theme.font)),
                        maxWidth - 2 * hPad - 2 * d.borderSize)
        titleLabel.frame = CGRect(x: hPad, y: vPad, width: textW, height: titleH)
        subtitleLabel.frame = CGRect(x: hPad, y: vPad + titleH + 4, width: textW, height: subH)
        return CGSize(width: textW + 2 * hPad + 2 * d.borderSize, height: innerH + 2 * d.borderSize)
    }
}

final class CaptionPresenter {
    private unowned let hud: HUD
    private var view: CaptionView?
    private var title = ""
    private var subtitle = ""
    private let defaultStyle = LayerAnimationStyle.slide(.up)

    init(hud: HUD) { self.hud = hud }

    /// "Title | subtitle" shows (or replaces) the caption; empty text hides it.
    func show(_ text: String) {
        let parts = text.components(separatedBy: " | ")
        title = parts[0].trimmingCharacters(in: .whitespaces)
        subtitle = parts.count > 1 ? parts[1...].joined(separator: " | ").trimmingCharacters(in: .whitespaces) : ""
        guard !title.isEmpty else {
            if let v = view {
                view = nil
                hud.animateOut(v, position: .top, defaultStyle: defaultStyle)
            }
            return
        }
        if let v = view {
            v.move(to: frame(for: v), duration: 0, curve: .linear, animator: hud.animator)
        } else {
            let v = CaptionView(theme: hud.theme)
            view = v
            hud.layer.addSubview(v)
            hud.animateIn(v, to: frame(for: v), position: .top, defaultStyle: defaultStyle)
        }
    }

    func relayout() {
        guard let v = view else { return }
        v.move(to: frame(for: v), duration: 0, curve: .linear, animator: hud.animator)
    }

    private func frame(for v: CaptionView) -> CGRect {
        let area = hud.workArea
        let size = v.update(title: title, subtitle: subtitle, theme: hud.theme, maxWidth: area.width - 2 * hud.margin)
        return HUDLayout.place(size, at: .top, in: area, margin: hud.margin * 2.5)
    }
}
