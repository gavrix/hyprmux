import AppKit
import HyprmuxCore

/// Root view of the monitor window. Top-left origin, like the core model.
final class CompositorView: FlippedView {
    var onResize: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // Holds focus when no client is focused (e.g. empty workspace), so keys don't beep.
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {}

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onResize?()
    }
}

/// A minimal waybar-like strip: workspaces on the left, focused title in the middle.
/// A workspace with tiles doing something shows their counts at the end of its pill
/// (ActivityBadge), and the pill grows to make room. Pills that don't fit scroll like
/// tabs (PillStrip): the active one stays in view, and a count marks each clipped edge.
final class BarView: NSView, NSViewToolTipOwner {
    var leadingInset: CGFloat = 0 { didSet { if leadingInset != oldValue { pillsChanged() } } }
    var workspaces: [Int] = [] { didSet { if workspaces != oldValue { pillsChanged() } } }
    /// Workspace names, shown after the number (the number always stays, for ⌘1…9).
    var names: [Int: String] = [:] { didSet { if names != oldValue { pillsChanged() } } }
    var active = 1 { didSet { if active != oldValue { pillsChanged() } } }
    var special: String? { didSet { if special != oldValue { pillsChanged() } } }
    var title = "" { didSet { if title != oldValue { needsDisplay = true } } }
    var submap = "reset" { didSet { if submap != oldValue { pillsChanged() } } }
    var accent = NSColor(srgbRed: 0.2, green: 0.8, blue: 1, alpha: 1)
    var onSelectWorkspace: ((Int) -> Void)?
    /// The area the workspace pills cover, in the bar's coordinates. Called when it changes.
    var onPillsFrame: ((CGRect) -> Void)?
    /// What each workspace's tiles are doing. Workspaces with nothing going on are absent.
    var activity: [Int: WorkspaceActivity] {
        get { storedActivity }
        set {
            let old = storedActivity
            storedActivity = newValue
            if newValue != old { activityChanged(from: old) }
        }
    }
    /// Behind `activity`, so `renumber` can move it without counting a change.
    private var storedActivity: [Int: WorkspaceActivity] = [:]

    /// `shown`: the whole pill is in view, not under a count or past an edge.
    private struct Pill { let id: Int; let rect: CGRect; let label: NSAttributedString; let shown: Bool }
    private var pills: [Pill] = []
    /// Where pills draw: the strip without its counts. The whole bar when everything fits.
    private var clip: CGRect = .zero
    /// The strip the pills scroll in, and the counts at its clipped edges.
    private var strip: CGRect = .zero
    private var before: (rect: CGRect, ids: [Int])?
    private var after: (rect: CGRect, ids: [Int])?
    /// The strip's scroll offset now, and where it's going. It eases there.
    private var scroll: CGFloat = 0
    private var scrollTarget: CGFloat = 0
    private var scrollTimer: Timer?
    private var lastPillsFrame: CGRect?
    private var badges: [Int: ActivityBadge] = [:]
    /// The room each pill makes for its badge now. It eases toward the badge's width.
    private var room: [Int: CGFloat] = [:]
    private var roomTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
    private static let nameFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let pillGap: CGFloat = 5
    /// Room the pills leave for the focused window's title when they don't fit.
    private static let minTitleWidth: CGFloat = 180
    private static let smallAttrs: (NSColor) -> [NSAttributedString.Key: Any] = { [.font: font, .foregroundColor: $0] }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { pillsChanged() }
    }

    /// Union of the pills, or of the strip when they scroll. An empty rect at the start
    /// when there are none.
    var pillsFrame: CGRect {
        guard let first = pills.first?.rect, let last = pills.last?.rect else {
            return CGRect(x: leadingInset + 8, y: 0, width: 0, height: bounds.height)
        }
        guard before != nil || after != nil else { return first.union(last) }
        return CGRect(x: strip.minX, y: first.minY, width: strip.width, height: first.height)
    }

    /// The special workspace and submap, drawn at the right end.
    private var rightLabels: [String] {
        var right: [String] = []
        if let special { right.append("special:\(special)") }
        if submap != "reset" { right.append("submap: \(submap)") }
        return right
    }

    /// Where the right-end labels start.
    private var rightLabelsMinX: CGFloat {
        let attrs = Self.smallAttrs(accent)
        return rightLabels.reduce(bounds.maxX - 12) { x, s in x - (s as NSString).size(withAttributes: attrs).width - 14 } + 14
    }

    private func pillsChanged() {
        layoutPills()
        updateToolTips()
        needsDisplay = true
        let f = pillsFrame
        if f != lastPillsFrame {
            lastPillsFrame = f
            onPillsFrame?(f)
        }
    }

    private func layoutPills() {
        pills = []
        let h = bounds.height
        let start = leadingInset + 8
        let pillH: CGFloat = min(18, h - 6)
        var made: [(id: Int, width: CGFloat, label: NSAttributedString)] = []
        for n in workspaces {
            let isActive = n == active
            let color = isActive ? NSColor.black : NSColor(white: 0.92, alpha: 1)
            let label = NSMutableAttributedString(string: "\(n)", attributes: [.font: Self.font, .foregroundColor: color])
            if var name = names[n] {
                if name.count > 18 { name = String(name.prefix(17)) + "…" }
                label.append(NSAttributedString(string: " " + name, attributes: [
                    .font: Self.nameFont, .foregroundColor: isActive ? color : NSColor(white: 0.92, alpha: 0.8),
                ]))
            }
            let size = label.size()
            let w = max(pillH + (isActive ? 10 : 0), size.width + (names[n] == nil ? 12 : 16)) + (room[n] ?? 0)
            made.append((n, w, label))
        }
        let widths = made.map(\.width)
        let available = max(80, rightLabelsMinX - 14 - start - Self.minTitleWidth)
        scrollTarget = PillStrip.offset(widths: widths, gap: Self.pillGap, available: available,
                                        active: workspaces.firstIndex(of: active), previous: scrollTarget)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || window == nil { scroll = scrollTarget }
        let layout = PillStrip(widths: widths, gap: Self.pillGap, available: available, offset: scroll)
        scroll = layout.offset
        if scroll != scrollTarget { startScrollAnimation() }

        strip = CGRect(x: start, y: 0, width: available, height: h)
        let vis = layout.visible
        clip = layout.fits ? bounds : CGRect(x: start + vis.lowerBound - scroll, y: 0, width: vis.upperBound - vis.lowerBound, height: h)
        let hidden = Set(layout.hiddenBefore + layout.hiddenAfter)
        for (i, m) in made.enumerated() {
            let rect = CGRect(x: start + layout.starts[i] - scroll, y: (h - pillH) / 2, width: m.width, height: pillH)
            pills.append(Pill(id: m.id, rect: rect, label: m.label, shown: !hidden.contains(i)))
        }
        let ind = PillStrip.indicatorWidth
        before = layout.leftIndicator
            ? (CGRect(x: start, y: 0, width: ind, height: h), layout.hiddenBefore.map { made[$0].id }) : nil
        after = layout.rightIndicator
            ? (CGRect(x: strip.maxX - ind, y: 0, width: ind, height: h), layout.hiddenAfter.map { made[$0].id }) : nil
    }

    private func startScrollAnimation() {
        guard scrollTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.stepScroll() }
        RunLoop.main.add(t, forMode: .common)
        scrollTimer = t
    }

    private func stepScroll() {
        scroll = abs(scrollTarget - scroll) < 0.5 ? scrollTarget : scroll + (scrollTarget - scroll) * 0.3
        if scroll == scrollTarget {
            scrollTimer?.invalidate()
            scrollTimer = nil
        }
        pillsChanged()
    }

    override func draw(_ dirtyRect: NSRect) {
        // Here, not when the pills change: the badges then move in the same frame as the
        // pills they sit on are drawn.
        positionBadges()
        let font = Self.font
        let h = bounds.height
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: clip).addClip()
        for p in pills where p.rect.intersects(clip) {
            let r = p.rect
            let path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
            if p.id == active {
                accent.setFill()
                path.fill()
            }
            let size = p.label.size()
            let labelMidX = r.midX - (room[p.id] ?? 0) / 2
            p.label.draw(at: CGPoint(x: labelMidX - size.width / 2, y: r.midY - size.height / 2))
        }
        NSGraphicsContext.restoreGraphicsState()
        if let before { drawCount(before.ids, in: before.rect, arrowFirst: true) }
        if let after { drawCount(after.ids, in: after.rect, arrowFirst: false) }
        let x = (before != nil || after != nil ? strip.maxX : pills.last?.rect.maxX ?? leadingInset + 8) + 5
        let small = Self.smallAttrs(accent)
        var rx = bounds.maxX - 12
        for s in rightLabels.reversed() {
            let str = s as NSString
            let size = str.size(withAttributes: small)
            rx -= size.width
            str.draw(at: CGPoint(x: rx, y: (h - size.height) / 2), withAttributes: small)
            rx -= 14
        }
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor(white: 0.8, alpha: 1),
        ]
        let t = title as NSString
        let ts = t.size(withAttributes: titleAttrs)
        let maxW = max(0, min(rx, bounds.width) - x - 20)
        let drawW = min(ts.width, maxW)
        let tx = max(x + 10, (bounds.width - drawW) / 2)
        t.draw(with: CGRect(x: tx, y: (h - ts.height) / 2, width: drawW, height: ts.height),
               options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: titleAttrs)
    }

    /// For `hyprmuxctl debug`: the pills in full view, the ones past each clipped edge,
    /// and the strip, in the bar's points.
    var debugState: [String: Any] {
        ["width": bounds.width, "strip": [strip.minX, strip.width], "offset": scroll,
         "shown": pills.filter(\.shown).map(\.id),
         "before": before?.ids ?? [], "after": after?.ids ?? []]
    }

    /// The count at a clipped edge: how many pills are past it. It takes the color of the
    /// most urgent activity among them, so a tile needing you isn't hidden.
    private func drawCount(_ ids: [Int], in rect: CGRect, arrowFirst: Bool) {
        var a = WorkspaceActivity()
        for n in ids { if let w = activity[n] { a.blocked += w.blocked; a.done += w.done; a.working += w.working } }
        let color = a.counts.first.flatMap { TileStatus.color($0.status) } ?? NSColor(white: 0.92, alpha: 0.7)
        let text = (arrowFirst ? "‹\(ids.count)" : "\(ids.count)›") as NSString
        let attrs = Self.smallAttrs(color)
        let size = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
    }

    // MARK: Activity

    /// The room a pill needs for its badge: the badge, and a little space after it.
    private func targetRoom(_ n: Int) -> CGFloat {
        guard let a = activity[n], !a.isEmpty else { return 0 }
        return ActivityBadge.width(for: a) + 1
    }

    /// Workspaces shifted to new numbers (`hyprmux:compact_workspaces`): their badges and
    /// activity go with them, so a shift doesn't look like a tile finishing. A closed
    /// workspace's badge leaves when the next one takes its number.
    func renumber(_ map: [Int: Int]) {
        guard !map.isEmpty else { return }
        func moved<V>(_ d: [Int: V], dropped: (V) -> Void = { _ in }) -> [Int: V] {
            var out: [Int: V] = [:]
            for (n, v) in d { if let m = map[n] { out[m] = v } }
            for (n, v) in d where map[n] == nil {
                if out[n] == nil { out[n] = v } else { dropped(v) }
            }
            return out
        }
        badges = moved(badges) { $0.leave() }
        room = moved(room)
        storedActivity = moved(storedActivity)
        needsDisplay = true
    }

    private func activityChanged(from old: [Int: WorkspaceActivity]) {
        let scale = window?.backingScaleFactor ?? 2
        for (n, badge) in badges where activity[n] == nil {
            badges[n] = nil
            badge.leave()
        }
        for n in activity.keys where badges[n] == nil {
            let badge = ActivityBadge()
            badges[n] = badge
            layer?.addSublayer(badge)
        }
        startRoomAnimation()
        needsDisplay = true
        for (n, a) in activity {
            let finished = WorkspaceActivity.finished(from: old[n] ?? WorkspaceActivity(), to: a)
            badges[n]?.update(a, scale: scale, finished: finished)
        }
    }

    /// The activity colors changed: badges are made again, in the new colors.
    func resetBadges() {
        for b in badges.values { b.removeFromSuperlayer() }
        badges = [:]
        activityChanged(from: activity)
    }

    /// Pills grow and shrink smoothly when a badge comes or goes.
    private func startRoomAnimation() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            room = Dictionary(uniqueKeysWithValues: workspaces.map { ($0, targetRoom($0)) }.filter { $0.1 > 0 })
            pillsChanged()
            return
        }
        guard roomTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.stepRoom() }
        RunLoop.main.add(t, forMode: .common)
        roomTimer = t
        stepRoom()
    }

    private func stepRoom() {
        var moving = false
        for n in Set(room.keys).union(activity.keys) {
            let target = targetRoom(n), current = room[n] ?? 0
            let next = abs(target - current) < 0.3 ? target : current + (target - current) * 0.3
            room[n] = next > 0 ? next : nil
            if next != target { moving = true }
        }
        pillsChanged()
        if !moving {
            roomTimer?.invalidate()
            roomTimer = nil
        }
    }

    /// Each badge marks the middle of its pill's trailing edge, inside; its bubbles extend left.
    private func positionBadges() {
        guard !badges.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for p in pills {
            guard let b = badges[p.id] else { continue }
            b.frame = CGRect(x: p.rect.maxX - 2, y: p.rect.midY, width: 0, height: 0)
            // A clipped pill's badge would spill past the strip; its count shows the activity.
            b.isHidden = !p.shown
        }
        CATransaction.commit()
    }

    private func updateToolTips() {
        removeAllToolTips()
        for p in pills where activity[p.id] != nil && p.rect.intersects(clip) {
            addToolTip(p.rect.intersection(clip), owner: self, userData: nil)
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        guard let p = pills.first(where: { $0.rect.contains(point) }), let a = activity[p.id] else { return "" }
        return a.summary
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for b in badges.values { b.setScale(scale) }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // A count goes to the nearest workspace past it.
        if let before, before.rect.contains(p), let n = before.ids.last {
            onSelectWorkspace?(n)
        } else if let after, after.rect.contains(p), let n = after.ids.first {
            onSelectWorkspace?(n)
        } else if clip.contains(p), let hit = pills.first(where: { $0.rect.contains(p) }) {
            onSelectWorkspace?(hit.id)
        } else {
            window?.performDrag(with: event)
        }
    }
}

/// A frosted capsule behind the workspace pills, so they read over any wallpaper.
/// macOS 26 gets Liquid Glass; older systems get a vibrancy blur with a hairline edge.
/// Stacked below the tiles, so it never covers one.
final class BarBackdrop: NSView {
    /// Space between the capsule's edge and the pills.
    static let padding: CGFloat = 4

    private var effect: NSView?
    /// Under the glass in a transparent window: the glass may only refract the window's
    /// own content, which is clear there, so this supplies a blur of the desktop.
    private var base: NSVisualEffectView?
    private let hairline = CAShapeLayer()
    private var transparentWindow = true
    private var enabled = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        hairline.fillColor = nil
        hairline.lineWidth = 1
        hairline.strokeColor = NSColor(white: 1, alpha: 0.14).cgColor
        hairline.zPosition = 10
        layer?.addSublayer(hairline)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// `transparent`: the window shows the desktop, so the blur samples what's behind it.
    func configure(enabled: Bool, transparent: Bool) {
        self.enabled = enabled
        isHidden = !enabled || frame.isEmpty
        guard enabled, effect == nil || transparent != transparentWindow else { return }
        transparentWindow = transparent
        effect?.removeFromSuperview()
        base?.removeFromSuperview()
        base = nil
        let v: NSView
        if #available(macOS 26.0, *) {
            if transparent {
                let b = Self.blur(transparent: true)
                install(b)
                base = b
            }
            let g = NSGlassEffectView()
            g.style = .regular
            v = g
            hairline.isHidden = true  // the glass draws its own edge
        } else {
            v = Self.blur(transparent: transparent)
            hairline.isHidden = false
        }
        install(v)
        effect = v
        needsLayout = true
    }

    private func install(_ v: NSView) {
        v.appearance = NSAppearance(named: .darkAqua)
        v.autoresizingMask = [.width, .height]
        v.frame = bounds
        addSubview(v)
    }

    private static func blur(transparent: Bool) -> NSVisualEffectView {
        let e = NSVisualEffectView()
        // Behind-window blur only sees the desktop through a transparent window.
        e.blendingMode = transparent ? .behindWindow : .withinWindow
        e.material = .hudWindow
        e.state = .active
        return e
    }

    /// Places the capsule around the pills (`pills` in the superview's coordinates).
    func wrap(_ pills: CGRect) {
        let p = Self.padding
        let f = pills.isEmpty ? .zero : pills.insetBy(dx: -p, dy: -p)
        isHidden = !enabled || f.isEmpty
        frame = f
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let r = bounds.height / 2
        if #available(macOS 26.0, *), let g = effect as? NSGlassEffectView {
            g.cornerRadius = r
        }
        for case let e as NSVisualEffectView in [base, effect] {
            e.maskImage = Self.capsuleMask(height: bounds.height)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hairline.frame = bounds
        hairline.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                               cornerWidth: max(0, r - 0.5), cornerHeight: max(0, r - 0.5), transform: nil)
        CATransaction.commit()
    }

    /// A stretchable capsule: the caps stay round while the middle stretches.
    private static func capsuleMask(height: CGFloat) -> NSImage {
        let r = height / 2
        let img = NSImage(size: NSSize(width: height + 1, height: height), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }
}

/// Centered hint shown on an empty workspace.
final class HintView: NSTextField {
    convenience init() {
        self.init(labelWithString: "")
        font = .systemFont(ofSize: 15, weight: .medium)
        textColor = NSColor(white: 1, alpha: 0.35)
        alignment = .center
    }
}

/// An outline along the edges of a see-through window that isn't full screen.
/// A clear window has no visible edge or shadow, so without it people can't tell
/// where the window ends or where macOS lets them resize it. A light line over a
/// dark one reads on light and dark wallpapers.
final class WindowFrameView: NSView {
    private let outer = CALayer()
    private let inner = CALayer()
    private var radius: CGFloat = 10

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for l in [outer, inner] {
            l.borderWidth = 1
            l.cornerCurve = .continuous
            layer?.addSublayer(l)
        }
        outer.borderColor = NSColor(white: 0, alpha: 0.35).cgColor
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(color: CGColor, cornerRadius: CGFloat) {
        inner.borderColor = color
        radius = cornerRadius
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outer.frame = bounds
        outer.cornerRadius = radius
        inner.frame = bounds.insetBy(dx: 1, dy: 1)
        inner.cornerRadius = max(0, radius - 1)
        CATransaction.commit()
    }
}
