import AppKit
import HyprmuxCore

/// A client popup on a frosted panel (`popup.create`). It drops from its bar item,
/// right-aligned to it, above every tile.
final class PopupHostView: FlippedView {
    static let cornerRadius: CGFloat = 12
    let panel: ClientPanelView
    private var effect: NSView?

    init(panel: ClientPanelView, transparentWindow: Bool) {
        self.panel = panel
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        let e: NSView
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.style = .regular
            g.cornerRadius = Self.cornerRadius
            e = g
        } else {
            let v = NSVisualEffectView()
            v.blendingMode = transparentWindow ? .behindWindow : .withinWindow
            v.material = .hudWindow
            v.state = .active
            e = v
        }
        e.appearance = NSAppearance(named: .darkAqua)
        e.autoresizingMask = [.width, .height]
        addSubview(e)
        effect = e
        panel.autoresizingMask = [.width, .height]
        addSubview(panel)
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var mouseDownCanMoveWindow: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        effect?.frame = bounds
        panel.frame = bounds
    }
}

extension Compositor {
    /// `popup.create`: one popup at a time, so a new one closes the last.
    func showPopup(_ popup: ClientPanelView) {
        if let open = openPopup { open.panel.connection?.dismiss(open.panel) }
        let host = PopupHostView(panel: popup, transparentWindow: !window.isOpaque)
        host.isHidden = true
        openPopup = host
        popup.onSizeChange = { [weak self] _ in self?.layoutPopup() }
        root.addSubview(host)
        layoutPopup()
        restackNow()
    }

    func popupRemoved(_ popup: ClientPanelView) {
        guard let host = openPopup, host.panel === popup else { return }
        openPopup = nil
        host.removeFromSuperview()
    }

    /// Under its bar item, right-aligned to it, and kept on screen.
    func layoutPopup() {
        guard let host = openPopup, case .popup(let anchor) = host.panel.role else { return }
        let size = host.panel.grantedPopupSize
        host.isHidden = size.width <= 0 || size.height <= 0
        guard !host.isHidden else { return }
        let a = anchor.convert(anchor.bounds, to: root)
        let margin: CGFloat = 8
        let maxH = max(80, root.bounds.height - bar.frame.maxY - 2 * margin)
        let w = min(size.width, root.bounds.width - 2 * margin)
        let h = min(size.height, maxH)
        let x = min(max(margin, a.maxX - w), root.bounds.width - w - margin)
        let frame = CGRect(x: x, y: bar.frame.maxY + 4, width: w, height: h).integral
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if host.frame != frame { host.frame = frame }
        CATransaction.commit()
    }

    /// Whether a press at `p` (root points) closes the open popup: anywhere outside it
    /// and its bar item. The item's own click is the client's to toggle.
    func pressClosesPopup(at p: CGPoint) -> Bool {
        guard let host = openPopup, case .popup(let anchor) = host.panel.role else { return false }
        if host.frame.contains(p) { return false }
        return !anchor.convert(anchor.bounds, to: root).contains(p)
    }

    func dismissPopup() {
        guard let host = openPopup else { return }
        host.panel.connection?.dismiss(host.panel)
    }

    // MARK: Tiles, for plugins

    /// `tiles.query`: `surfaces`, plus the processes behind each tile and Hyprmux's own.
    func tilesForClients() -> [String: Any] {
        let tiles: [[String: Any]] = wm.snapshot().placements.map { p in
            var info = clientInfo(p)
            let roots = processRoots(p.id)
            info["pids"] = roots.pids.map(Int.init)
            info["sessions"] = roots.sessions.map(Int.init)
            // The id pill's colors on the tile's border, so a plugin can draw the same pill.
            if let v = views[p.id], let color = v.pillColor {
                let (fill, ink) = TitlePill.palette(color)
                info["pill"] = ["fill": Self.hex(fill), "ink": Self.hex(ink), "font_size": Double(v.decoration.titleFontSize)]
            }
            return info
        }
        // Plugins run in hosts Hyprmux started: rows of their own, not part of Hyprmux's.
        let hosts: [[String: Any]] = plugins.plugins.compactMap { p in
            guard p.pid > 0, let m = p.manifest else { return nil }
            return ["id": m.id, "name": m.name, "pid": Int(p.pid)]
        }
        return ["tiles": tiles, "plugins": hosts, "hyprmux_pid": Int(getpid())]
    }

    // MARK: Theme, for clients

    /// How Hyprmux looks, for QML apps and plugins to match (`welcome`, `theme.changed`):
    /// its own UI's colors and type, which come from the terminal, and the tiles' frame.
    func clientTheme() -> [String: Any] {
        let t = HUDTheme(config: config, terminal: runtime.style, background: runtime.backgroundColor)
        var theme: [String: Any] = [
            "accent": Self.hex(t.accent), "foreground": Self.hex(t.foreground), "secondary": Self.hex(t.secondary),
            "background": Self.hex(t.background), "colors": t.palette.map { Self.hex($0) },
            "rounding": Double(t.decoration.rounding), "terminal_font_size": Double(t.font.pointSize),
        ]
        if let family = t.font.familyName { theme["terminal_font"] = family }
        return theme
    }

    /// `#RRGGBBAA`.
    private static func hex(_ c: HyprmuxCore.Color) -> String {
        let v = [c.r, c.g, c.b, c.a].map { UInt8(max(0, min(1, $0)) * 255 + 0.5) }
        return "#" + v.map { String(format: "%02x", $0) }.joined()
    }

    private static func hex(_ c: NSColor) -> String {
        let s = c.usingColorSpace(.sRGB) ?? c
        return hex(HyprmuxCore.Color(r: Double(s.redComponent), g: Double(s.greenComponent),
                                     b: Double(s.blueComponent), a: Double(s.alphaComponent)))
    }

    /// The processes a tile runs. A terminal: its session, so every program started in
    /// it counts, even one that left the process tree. An app tile: its client process.
    /// Web tiles render in Hyprmux's own helpers, which no tile owns yet.
    private func processRoots(_ id: ClientID) -> (pids: [pid_t], sessions: [pid_t]) {
        let surface = views[id]?.surface
        if let t = shellTerminal(id) ?? (surface as? ClientSurface)?.terminal {
            let fg = t.foregroundPID
            guard fg > 0 else { return ([], []) }
            let sid = getsid(fg)
            return sid > 0 ? ([], [sid]) : ([fg], [])
        }
        if let c = surface as? ClientSurface, let pid = c.connection?.pid, pid > 0 { return ([pid], []) }
        return ([], [])
    }

    /// `tiles.focus`: what clicking a row in a plugin's list does.
    func focusTileForClient(_ raw: UInt64) {
        let id = ClientID(raw)
        guard views[id] != nil else { return }
        dismissPopup()
        wm.focus(id)
        apply(animated: true)
    }
}
