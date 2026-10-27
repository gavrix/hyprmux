import AppKit
import HyprmuxCore

/// A tile's title, stamped on its top border like a label on a jar (decoration:title).
/// It takes the border's color, or the tile's activity color (TileStatus) when its
/// content is working, needs you, or is done, and then breathes in step with the border.
///
/// With titles off it still shows an activity, as its label ("working"), so a focused
/// tile, whose border keeps the focus color, shows what it's doing.
///
/// It can lead with the surface's id, like tmux's pane numbers, in a pill of its own
/// in the same style, a small gap apart, so the number never runs into the title.
final class TitlePill: NSView {
    static let horizontalPadding: CGFloat = 8
    /// Between the id pill and the title pill.
    static let gap: CGFloat = 3
    private let fill = CALayer()
    private let text = CATextLayer()
    private let idFill = CALayer()
    private let idText = CATextLayer()
    private var font = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private var idFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
    private var label = NSAttributedString()
    private var idLabel: NSAttributedString?
    /// The running pulse's period; nil when still.
    private var period: CFTimeInterval?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        // Above the border (zPosition 100).
        layer?.zPosition = 150
        for f in [fill, idFill] {
            f.shadowOffset = .zero
            f.shadowRadius = 5
            f.shadowOpacity = 0
            f.actions = ["bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        }
        for t in [text, idText] {
            t.alignmentMode = .center
            t.truncationMode = .end
            t.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull(),
                         "font": NSNull(), "fontSize": NSNull(), "foregroundColor": NSNull()]
        }
        layer?.addSublayer(idFill)
        layer?.addSublayer(idText)
        layer?.addSublayer(fill)
        layer?.addSublayer(text)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static func height(fontSize: CGFloat) -> CGFloat { ceil(fontSize + 7) }

    /// The id pill's width: a circle for one digit, a capsule for more.
    private var idWidth: CGFloat {
        guard let idLabel else { return 0 }
        return max(bounds.height > 0 ? bounds.height : Self.height(fontSize: font.pointSize), ceil(idLabel.size().width) + 12)
    }

    /// The width both pills want, padding and gap included.
    var preferredWidth: CGFloat {
        let title = label.length > 0 ? ceil(label.size().width) + 2 * Self.horizontalPadding : 0
        let id = idWidth
        return id + (id > 0 && title > 0 ? Self.gap : 0) + title
    }

    /// The pill's fill for a border or activity color, and the text that reads on it:
    /// opaque enough to read over the content it overlaps, dark text on bright colors
    /// (cyan, orange, green), light on dark ones. Plugins draw tile numbers with it too.
    static func palette(_ color: HyprmuxCore.Color) -> (fill: HyprmuxCore.Color, ink: NSColor) {
        var c = color
        c.a = max(c.a, 0.92)
        let luminance = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
        return (c, luminance > 0.55 ? NSColor(white: 0.08, alpha: 1) : NSColor(white: 1, alpha: 0.95))
    }

    /// Sets what it says and its color. Runs inside the decoration's transaction, so a
    /// color change animates like the border's.
    func update(string: String, id: UInt64?, color: HyprmuxCore.Color, status: String?, fontSize: CGFloat) {
        if font.pointSize != fontSize {
            font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
            idFont = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)
        }
        let (c, ink) = Self.palette(color)
        fill.backgroundColor = c.cg
        fill.shadowColor = c.cg
        label = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: ink])
        text.string = label
        // A truncated line ends in an ellipsis drawn with the layer's own font, size, and
        // color, not the string's. At the default 36 pt, that line is taller than the
        // pill, and Core Text draws nothing: long titles showed an empty pill.
        for (t, f) in [(text, font), (idText, idFont)] {
            t.font = f
            t.fontSize = f.pointSize
            t.foregroundColor = ink.cgColor
        }

        // The id pill: the same color, apart from the title.
        idFill.backgroundColor = c.cg
        idFill.shadowColor = c.cg
        idLabel = id.map { NSAttributedString(string: "\($0)", attributes: [.font: idFont, .foregroundColor: ink]) }
        idText.string = idLabel

        let period = TileStatus.pulsePeriod(status)
        if period != self.period {
            self.period = period
            updatePulse()
        }
        layoutLayers()
    }

    override func layout() {
        super.layout()
        layoutLayers()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutLayers()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layoutLayers()
    }

    private func layoutLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let h = bounds.height
        let scale = window?.backingScaleFactor ?? 2
        let idW = min(idWidth, bounds.width)
        idFill.isHidden = idLabel == nil
        idText.isHidden = idLabel == nil
        idFill.frame = CGRect(x: 0, y: 0, width: idW, height: h)
        idFill.cornerRadius = h / 2
        let idLine = ceil(idFont.ascender - idFont.descender)
        idText.frame = CGRect(x: 0, y: (h - idLine) / 2, width: idW, height: idLine)
        idText.contentsScale = scale

        let titleX = idW > 0 ? idW + Self.gap : 0
        let titleW = max(0, bounds.width - titleX)
        let showsTitle = label.length > 0 && titleW > 2 * Self.horizontalPadding
        fill.isHidden = !showsTitle
        text.isHidden = !showsTitle
        fill.frame = CGRect(x: titleX, y: 0, width: titleW, height: h)
        fill.cornerRadius = h / 2
        let lineHeight = ceil(font.ascender - font.descender)
        text.frame = CGRect(x: titleX + Self.horizontalPadding, y: (h - lineHeight) / 2,
                            width: max(0, titleW - 2 * Self.horizontalPadding), height: lineHeight)
        text.contentsScale = scale
        CATransaction.commit()
    }

    /// Glows and dims in step with the border's pulse: bright border, bright glow.
    private func updatePulse() {
        for f in [fill, idFill] {
            f.removeAnimation(forKey: "glow")
            f.removeAnimation(forKey: "breathe")
        }
        guard let period else { return }
        for f in [fill, idFill] {
            let glow = CABasicAnimation(keyPath: "shadowOpacity")
            glow.fromValue = 0.9
            glow.toValue = 0.05
            glow.duration = period
            TileStatus.addInPhase(glow, to: f, key: "glow")
        }
        for f in [fill, idFill] {
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 1
            breathe.toValue = 0.72
            breathe.duration = period
            TileStatus.addInPhase(breathe, to: f, key: "breathe")
        }
    }
}
