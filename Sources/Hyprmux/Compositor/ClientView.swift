import AppKit
import HyprmuxCore

/// One managed window: the decorated frame (see `DecoratedView`) around a surface,
/// plus the inactive dim, the group tab strip, and the job bar.
///
/// During geometry animations the terminal jumps to its final size once and the
/// clip animates around it. That avoids sending a resize to the shell every frame.
final class ClientView: DecoratedView, FindBarHost {
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

    /// Background jobs along the bottom, inside the rounded clip below the content.
    private var jobBar: JobBarView?
    private var jobBarHeight: CGFloat = 0
    var onJobBarExit: (() -> Void)?

    /// Find bar along the bottom, for surfaces that can search. Made on first use.
    private var findBar: FindBar?
    private var findable: FindableSurface? { surface as? FindableSurface }
    var isFinding: Bool { findBar.map { !$0.isHidden } ?? false }
    var findQuery: String { findBar?.query ?? "" }
    var findStatus: String { findBar?.status ?? "" }

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

    /// Shows (or removes, with nil) the job bar. The content shrinks to make room.
    func setJobBar(_ chips: [JobChip]?, expanded: ClientID?, peeked: ClientID?, height: CGFloat, style: GroupBarStyle) {
        guard let chips, !chips.isEmpty, height > 0 else {
            if let bar = jobBar {
                bar.removeFromSuperview()
                jobBar = nil
                jobBarHeight = 0
                layoutContent()
            }
            return
        }
        let bar: JobBarView
        var created = false
        if let existing = jobBar {
            bar = existing
        } else {
            created = true
            bar = JobBarView()
            bar.onPointerExit = { [weak self] in self?.onJobBarExit?() }
            // Above the inactive dim: the bar stays readable while one of its jobs has focus.
            clip.addSubview(bar, positioned: .above, relativeTo: dimView)
            jobBar = bar
        }
        bar.update(chips: chips, expanded: expanded, peeked: peeked, style: style)
        if jobBarHeight != height || created {
            jobBarHeight = height
            layoutContent()
        }
    }

    /// What's under `p` (in `view`'s coordinates) in the job bar, with the rect in `view`'s.
    func jobBarHit(at p: CGPoint, in view: NSView) -> JobBarView.Hit? {
        guard let bar = jobBar, !bar.isHidden else { return nil }
        switch bar.hit(bar.convert(p, from: view)) {
        case .chip(let id, let r): return .chip(id, bar.convert(r, to: view))
        case .overflow(let ids, let r): return .overflow(ids, bar.convert(r, to: view))
        case nil: return nil
        }
    }

    /// A job's chip, in `view`'s coordinates.
    func jobChipRect(_ id: ClientID, in view: NSView) -> CGRect? {
        guard let bar = jobBar, let r = bar.rect(of: id) else { return nil }
        return bar.convert(r, to: view)
    }

    override func targetFrameDidChange() { layoutContent() }

    /// Laid out for the target frame, so they don't move while the chrome animates.
    override var layersOutsideChromeAnimation: [CALayer] {
        [surface.view.layer, groupBar?.layer, jobBar?.layer, findBar?.layer].compactMap { $0 }
    }

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
        let jh = min(jobBarHeight, max(0, h - bh - 1))
        jobBar?.frame = CGRect(x: 0, y: h - jh, width: w, height: jh)
        jobBar?.sideInset = CGFloat(RoundedShape.edgeInset(
            radius: Double(innerR), power: Double(decoration.roundingPower), depth: Double(jh) / 2))
        let content = CGRect(x: 0, y: bh, width: w, height: h - bh - jh)
        if surface.view.frame != content { surface.view.frame = content }
        // Over the bottom of the content, so the terminal doesn't resize when it opens.
        findBar?.frame = CGRect(x: 0, y: content.maxY - FindBar.height, width: w, height: FindBar.height)
        findBar?.sideInset = CGFloat(RoundedShape.edgeInset(
            radius: Double(innerR), power: Double(decoration.roundingPower), depth: Double(FindBar.height) / 2))
    }

    // MARK: Find

    /// Opens the find bar, or selects its query if it's already open.
    func showFind() {
        guard let findable else { return }
        let bar = findBar ?? makeFindBar()
        if bar.isHidden {
            bar.isHidden = false
            bar.status = ""
            layoutContent()
            // Reopened with the old query: highlight its matches again.
            if !bar.query.isEmpty { findable.find(bar.query, forward: true, next: false) }
        }
        bar.focusField()
    }

    func closeFind() {
        guard let bar = findBar, !bar.isHidden else { return }
        hideFindBar()
        findable?.endFind()
    }

    private func hideFindBar() {
        guard let bar = findBar, let window else { return }
        let hadFocus = Self.responder(window.firstResponder, isIn: bar)
        bar.isHidden = true
        if hadFocus { surface.takeFocus(in: window) }
    }

    private func makeFindBar() -> FindBar {
        let bar = FindBar()
        bar.isHidden = true
        bar.onChange = { [weak self] text in self?.findable?.find(text, forward: true, next: false) }
        bar.onNavigate = { [weak self, weak bar] forward in
            guard let self, let bar, !bar.query.isEmpty else { return }
            findable?.find(bar.query, forward: forward, next: true)
        }
        bar.onClose = { [weak self] in self?.closeFind() }
        // Above the content, below the inactive dim.
        clip.addSubview(bar, positioned: .above, relativeTo: surface.view)
        findBar = bar
        return bar
    }

    /// True if the window's first responder is in this tile: its surface or its find bar.
    func ownsFirstResponder(in window: NSWindow) -> Bool {
        surface.ownsFirstResponder(in: window) || findBar.map { Self.responder(window.firstResponder, isIn: $0) } ?? false
    }

    private static func responder(_ r: NSResponder?, isIn view: NSView) -> Bool {
        guard let v = r as? NSView else { return false }
        // Field editors live outside the view tree; use their delegate (the text field).
        if let tv = v as? NSTextView, tv.isFieldEditor, let owner = tv.delegate as? NSView {
            return owner.isDescendant(of: view)
        }
        return v.isDescendant(of: view)
    }

    // MARK: FindBarHost

    func findStatusChanged(_ status: String) {
        guard let bar = findBar, !bar.isHidden, !bar.query.isEmpty || status.isEmpty else { return }
        bar.status = status
    }

    func surfaceRequestsFind(query: String?) {
        // Ghostty also reports searches the bar started; leave the bar alone then.
        if isFinding {
            if let query, query != findQuery, let bar = findBar {
                bar.query = query
                findable?.find(query, forward: true, next: false)
            }
            return
        }
        if let query { (findBar ?? makeFindBar()).query = query }
        showFind()
    }

    func surfaceEndedFind() {
        guard isFinding else { return }
        hideFindBar()
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
        findable?.findHost = self
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
