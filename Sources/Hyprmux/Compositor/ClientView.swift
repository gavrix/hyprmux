import AppKit
import HyprmuxCore

/// One managed window: the decorated frame (see `DecoratedView`) around a surface,
/// plus the inactive dim and the group tab strip.
///
/// During geometry animations the terminal jumps to its final size once and the
/// clip animates around it. That avoids sending a resize to the shell every frame.
final class ClientView: DecoratedView {
    let id: ClientID
    let surface: Surface
    private let dimView = PassthroughView()
    /// The title on the top border; it also shows the activity (TileStatus).
    private let titlePill = TitlePill()
    private(set) var status: String?
    private lazy var surfaceMenu: NSMenu = {
        let reference = SurfaceReference(id.raw).description
        let menu = NSMenu(title: "Surface")
        let copy = NSMenuItem(
            title: "Copy Surface ID (\(reference))",
            action: #selector(copySurfaceID),
            keyEquivalent: ""
        )
        copy.target = self
        menu.addItem(copy)
        return menu
    }()

    /// Whether the compositor currently shows this client (its workspace is visible).
    var shown = false

    /// Tab strip for grouped windows, inside the rounded clip above the content.
    private var groupBar: GroupBarView?
    private var barHeight: CGFloat { groupBar == nil ? 0 : groupBarHeight }
    private var groupBarHeight: CGFloat = 20
    var onSelectTab: ((Int) -> Void)?

    /// What the tile's content is doing (TileStatus): the title pill takes its color, and
    /// so does the border while the tile is unfocused. Both pulse.
    func setStatus(_ status: String?) {
        guard status != self.status else { return }
        self.status = status
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        updateTitlePill()
        CATransaction.commit()
        layoutTitlePill()
        setActivityStatus(status, duration: 0.3)
    }

    /// The surface's title changed.
    func titleDidChange() {
        updateTitlePill()
        layoutTitlePill()
    }

    /// Grouped tiles show titles and activity in their tabs.
    private var showsTitlePill: Bool {
        groupBar == nil && (decoration.title
            ? !surface.title.isEmpty || decoration.titleShowsID
            : TileStatus.label(status) != nil)
    }

    private func updateTitlePill() {
        let text = decoration.title ? surface.title : (TileStatus.label(status) ?? "")
        let border = (isActive ? decoration.activeBorder : decoration.inactiveBorder).colors.first
        guard let color = TileStatus.rgba(status) ?? border else { return }
        titlePill.update(string: text, id: decoration.titleShowsID ? id.raw : nil, color: color, status: status,
                         fontSize: decoration.titleFontSize)
    }

    /// On the top border, after the corner's curve. As wide as its text, up to a label's
    /// width: past that the title truncates, so the pill never becomes a bar.
    private func layoutTitlePill() {
        let h = TitlePill.height(fontSize: decoration.titleFontSize)
        let x = max(decoration.rounding, 8) + 6
        let room = bounds.width - 2 * x
        let w = min(max(titlePill.preferredWidth, h * 1.6), min(room, max(bounds.width * 0.6, 120), 420))
        let shown = showsTitlePill && room >= h * 1.6
        titlePill.isHidden = !shown
        guard shown else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        titlePill.frame = CGRect(x: x, y: decoration.borderSize / 2 - h / 2, width: w, height: h)
        CATransaction.commit()
    }

    /// Shows (or removes, with nil) the tab strip.
    func setGroupBar(_ tabs: (titles: [String], statuses: [String?], ids: [UInt64?], active: Int)?, style: GroupBarStyle) {
        guard let tabs else {
            if groupBar != nil {
                groupBar?.removeFromSuperview()
                groupBar = nil
                layoutContent()
                layoutTitlePill()
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
            layoutTitlePill()
        }
        let heightChanged = groupBarHeight != style.height
        groupBarHeight = style.height
        bar.update(titles: tabs.titles, statuses: tabs.statuses, ids: tabs.ids, active: tabs.active, style: style)
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
        menu = surfaceMenu
        clip.menu = surfaceMenu
        if surface.view.menu == nil { surface.view.menu = surfaceMenu }

        dimView.wantsLayer = true
        dimView.layer?.backgroundColor = NSColor.black.cgColor
        dimView.alphaValue = 0
        clip.addSubview(dimView)
        titlePill.isHidden = true
        addSubview(titlePill)
        finishSetup()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    @objc private func copySurfaceID() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(SurfaceReference(id.raw).description, forType: .string)
    }

    // Clicks inside go to the terminal; the view itself never takes focus.
    override var acceptsFirstResponder: Bool { false }

    func refreshBackdrop() { clip.layer?.backgroundColor = surface.backdropColor.cgColor }

    override func decorationDidApply() {
        dimView.alphaValue = (!isActive && decoration.dimInactive) ? decoration.dimStrength : 0
        // In the decoration's transaction: the pill recolors with the border.
        updateTitlePill()
    }

    override func chromeDidLayout() {
        dimView.frame = clip.bounds
        layoutTitlePill()
    }
}
