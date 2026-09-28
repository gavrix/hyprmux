import AppKit
import HyprmuxCore

/// How Hyprmux's own UI looks: type and colors from the terminal (Ghostty config),
/// frame from the window decoration (Hyprmux config). Rebuilt on every config reload.
struct HUDTheme {
    var font: NSFont
    var boldFont: NSFont
    var foreground: NSColor
    /// Secondary text: the foreground, faded.
    var secondary: NSColor
    /// The terminal background, with Ghostty's background-opacity.
    var background: NSColor
    /// The 16 ANSI colors.
    var palette: [NSColor]
    /// A focused tile's decoration. Panels are always drawn "active".
    var decoration: Decoration
    /// The first active-border color, as the bar uses it.
    var accent: NSColor

    init(config: HyprmuxConfig, terminal: GhosttyRuntime.TerminalStyle, background: NSColor) {
        let size = CGFloat(config.hud.fontSize ?? Double(terminal.fontSize))
        let family = config.hud.fontFamily ?? terminal.fontFamily
        let regular = family.flatMap { Self.font(family: $0, size: size, bold: false) }
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        font = regular
        boldFont = family.flatMap { Self.font(family: $0, size: size, bold: true) }
            ?? NSFontManager.shared.convert(regular, toHaveTrait: .boldFontMask)
        foreground = terminal.foreground
        secondary = terminal.foreground.withAlphaComponent(0.62)
        self.background = background
        palette = terminal.palette.count >= 16 ? terminal.palette : GhosttyRuntime.TerminalStyle.fallbackPalette
        var d = Decoration(config)
        // Blur only shows through a translucent panel.
        d.blur = d.blur && background.alphaComponent < 1
        decoration = d
        let c = config.activeBorder.colors.first ?? HyprmuxCore.Color(r: 0.2, g: 0.8, b: 1, a: 1)
        accent = NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }

    /// A family name ("JetBrains Mono") or a PostScript name ("JetBrainsMono-Regular").
    private static func font(family: String, size: CGFloat, bold: Bool) -> NSFont? {
        let fm = NSFontManager.shared
        if let f = fm.font(withFamily: family, traits: bold ? .boldFontMask : [], weight: bold ? 9 : 5, size: size) {
            return f
        }
        guard let f = NSFont(name: family, size: size) else { return nil }
        return bold ? fm.convert(f, toHaveTrait: .boldFontMask) : f
    }

    /// Text color for a level: the terminal's own red, yellow, and green.
    func color(for level: NoticeLevel) -> NSColor {
        switch level {
        case .info: accent
        case .success: palette[10]
        case .warning: palette[11]
        case .error: palette[9]
        }
    }

    /// Decoration for a notice: info keeps the window border; the others take the level color.
    func decoration(for level: NoticeLevel) -> Decoration {
        var d = decoration
        if level != .info {
            let c = color(for: level).usingColorSpace(.sRGB) ?? .red
            let border = HyprmuxCore.Color(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: 0.93)
            d.activeBorder = Gradient([border])
        }
        return d
    }
}
