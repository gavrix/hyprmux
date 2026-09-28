import AppKit
import HypermuxCore

/// One managed window: the decorated frame (see `DecoratedView`) around a surface,
/// plus the inactive dim and the group tab strip.
///
/// During geometry animations the terminal jumps to its final size once and the
/// clip animates around it. That avoids sending a resize to the shell every frame.
final class ClientView: DecoratedView {
    let id: ClientID
    let surface: Surface
    private let dimView = PassthroughView()

    /// Whether the compositor currently shows this client (its workspace is visible).
    var shown = false

    /// Tab strip for grouped windows, inside the rounded clip above the content.
    private var groupBar: GroupBarView?
    private var barHeight: CGFloat { groupBar == nil ? 0 : groupBarHeight }
    private var groupBarHeight: CGFloat = 20
    var onSelectTab: ((Int) -> Void)?

    /// Shows (or removes, with nil) the tab strip.
    func setGroupBar(_ tabs: (titles: [String], active: Int)?, style: GroupBarStyle) {
        guard let tabs else {
            if groupBar != nil {
                groupBar?.removeFromSuperview()
                groupBar = nil
                layoutContent()
            }
            return
        }
        let bar: GroupBarView
        if let existing = groupBar {
            bar = existing
        } else {
            bar = GroupBarView()
            bar.onSelect = { [weak self] i in self?.onSelectTab?(i) }
            clip.addSubview(bar, positioned: .above, relativeTo: surface.view)
            groupBar = bar
        }
        let heightChanged = groupBarHeight != style.height
        groupBarHeight = style.height
        bar.update(titles: tabs.titles, active: tabs.active, style: style)
        if heightChanged || bar.frame.height != style.height { layoutContent() }
    }

    override func targetFrameDidChange() { layoutContent() }

    /// Sizes the content (and tab strip) for the current target frame.
    private func layoutContent() {
        let b = decoration.borderSize
        let w = max(1, targetFrame.width - 2 * b)
        let h = max(1, targetFrame.height - 2 * b)
        let bh = min(barHeight, h - 1)
        groupBar?.frame = CGRect(x: 0, y: 0, width: w, height: bh)
        // Keep tabs clear of the (inner) corner curve: measured halfway down the bar.
        let innerR = max(0, decoration.rounding - b)
        groupBar?.sideInset = CGFloat(RoundedShape.edgeInset(
            radius: Double(innerR), power: Double(decoration.roundingPower), depth: Double(bh) / 2))
        // A browser's address bar sits at the top of the content when there are no tabs.
        (surface as? BrowserSurface)?.topCornerInset = bh > 0 ? 0 : CGFloat(RoundedShape.edgeInset(
            radius: Double(innerR), power: Double(decoration.roundingPower), depth: 15))
        let content = CGRect(x: 0, y: bh, width: w, height: h - bh)
        if surface.view.frame != content { surface.view.frame = content }
    }

    init(id: ClientID, surface: Surface, decoration: Decoration) {
        self.id = id
        self.surface = surface
        super.init(decoration: decoration)
        clip.layer?.backgroundColor = surface.backdropColor.cgColor
        clip.addSubview(surface.view)

        dimView.wantsLayer = true
        dimView.layer?.backgroundColor = NSColor.black.cgColor
        dimView.alphaValue = 0
        clip.addSubview(dimView)
        finishSetup()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // Clicks inside go to the terminal; the view itself never takes focus.
    override var acceptsFirstResponder: Bool { false }

    func refreshBackdrop() { clip.layer?.backgroundColor = surface.backdropColor.cgColor }

    override func decorationDidApply() {
        dimView.alphaValue = (!isActive && decoration.dimInactive) ? decoration.dimStrength : 0
    }

    override func chromeDidLayout() {
        dimView.frame = clip.bounds
    }
}
