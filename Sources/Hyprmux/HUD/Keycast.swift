import AppKit
import HyprmuxCore

/// The keycast panel: the shortcut in the accent color, what it did, and a repeat count.
/// It never takes clicks.
final class KeycastView: DecoratedView {
    private let chordLabel = NSTextField(labelWithString: "")
    private let textLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")

    init(theme: HUDTheme) {
        super.init(decoration: theme.decoration, active: true, blurBlending: .withinWindow)
        for l in [chordLabel, textLabel, countLabel] {
            l.isSelectable = false
            l.drawsBackground = false
            l.isBordered = false
            l.lineBreakMode = .byTruncatingTail
            clip.addSubview(l)
        }
        finishSetup()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Fills in the state and returns the panel's size.
    func update(_ k: KeycastState, theme: HUDTheme, maxWidth: CGFloat) -> CGSize {
        setDecoration(theme.decoration, active: true, borderDuration: 0)
        clip.layer?.backgroundColor = theme.background.cgColor
        let big = NSFontManager.shared.convert(theme.boldFont, toSize: theme.boldFont.pointSize * 1.25)
        chordLabel.font = big
        chordLabel.textColor = theme.accent
        chordLabel.stringValue = k.chord
        textLabel.font = theme.font
        textLabel.textColor = theme.foreground
        textLabel.stringValue = k.label
        countLabel.font = theme.font
        countLabel.textColor = theme.secondary
        countLabel.stringValue = k.count > 1 ? "×\(k.count)" : ""
        countLabel.isHidden = k.count <= 1

        let d = decoration
        let lineH = ceil(big.ascender - big.descender)
        let vPad = max(9, round(lineH * 0.45))
        let h = lineH + 2 * vPad
        let r = min(max(0, d.rounding - d.borderSize), h / 2)
        let hPad = max(16, ceil(CGFloat(RoundedShape.edgeInset(radius: Double(r), power: Double(d.roundingPower),
                                                               depth: Double(vPad)))) + 10)
        let gap: CGFloat = 12
        // Measured from the strings: a label's intrinsic size lags behind a new value.
        func width(_ s: String, _ f: NSFont) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: f]).width) + 4 }
        let chordW = width(k.chord, big)
        let countW = countLabel.isHidden ? 0 : width(countLabel.stringValue, theme.font)
        let textW = min(width(k.label, theme.font),
                        maxWidth - 2 * hPad - chordW - gap - (countW > 0 ? countW + gap : 0) - 2 * d.borderSize)
        let textH = ceil(theme.font.ascender - theme.font.descender)
        var x = hPad
        chordLabel.frame = CGRect(x: x, y: vPad, width: chordW, height: lineH)
        x += chordW + gap
        // Baselines line up: the smaller label sits lower.
        let textY = vPad + (big.ascender - theme.font.ascender)
        textLabel.frame = CGRect(x: x, y: textY, width: max(0, textW), height: textH)
        x += max(0, textW)
        if countW > 0 {
            x += gap
            countLabel.frame = CGRect(x: x, y: textY, width: countW, height: textH)
            x += countW
        }
        return CGSize(width: x + hPad + 2 * d.borderSize, height: h + 2 * d.borderSize)
    }
}

/// Shows each shortcut Hyprmux acts on at the bottom of the window (`hud:keycast`).
/// A new shortcut replaces the last; quick repeats count up; it fades after a moment.
final class KeycastPresenter {
    private unowned let hud: HUD
    private var state = KeycastState()
    private var view: KeycastView?
    private var hideWork: DispatchWorkItem?
    /// Seconds the panel stays after the last key.
    private let linger = 1.6
    private let defaultStyle = LayerAnimationStyle.popin(0.9)

    init(hud: HUD) { self.hud = hud }

    func press(chord: String, label: String) {
        guard hud.config.hud.keycast else { return }
        state.press(chord: chord, label: label, now: CACurrentMediaTime())
        if let v = view {
            v.move(to: frame(for: v), duration: 0, curve: .linear, animator: hud.animator)
        } else {
            let v = KeycastView(theme: hud.theme)
            view = v
            hud.layer.addSubview(v)  // on top of pickers and notifications
            hud.animateIn(v, to: frame(for: v), position: .bottom, defaultStyle: defaultStyle)
        }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + linger, execute: work)
    }

    private func hide() {
        guard let v = view else { return }
        view = nil
        hud.animateOut(v, position: .bottom, defaultStyle: defaultStyle)
    }

    func relayout() {
        guard let v = view else { return }
        v.move(to: frame(for: v), duration: 0, curve: .linear, animator: hud.animator)
    }

    /// Config reloaded: restyle, or go away if the keycast was turned off.
    func reload() {
        guard let v = view else { return }
        guard hud.config.hud.keycast else {
            hideWork?.cancel()
            v.removeFromSuperview()
            view = nil
            return
        }
        relayout()
    }

    private func frame(for v: KeycastView) -> CGRect {
        let area = hud.workArea
        let size = v.update(state, theme: hud.theme, maxWidth: area.width - 2 * hud.margin)
        return HUDLayout.place(size, at: .bottom, in: area, margin: hud.margin * 2)
    }
}
