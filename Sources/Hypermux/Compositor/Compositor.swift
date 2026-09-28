import AppKit
import HypermuxCore
import ChromiumBridge
import SimulatorBridge

/// Glue between the model (WindowManager), the monitor window, and terminal surfaces.
final class Compositor: NSObject, TerminalViewHost, BrowserSurfaceHost, NSWindowDelegate {
    let runtime: GhosttyRuntime
    private(set) var config: HypermuxConfig
    let wm: WindowManager

    let window: MonitorWindow
    let root: CompositorView
    private let bar = BarView()
    private let banner = BannerView()
    private let hint = HintView()
    private let specialDim = NSView()
    private let animator: Animator

    private var views: [ClientID: ClientView] = [:]
    private var closing: [ClientID: ClientView] = [:]
    private var nextID: UInt64 = 1
    private var submap = "reset"
    private var last: Snapshot?
    private var consumedKeyUps: Set<UInt16> = []
    private var monitors: [Any] = []
    private var drag: Drag?

    private struct Drag {
        let id: ClientID
        let resize: Bool
        let floating: Bool
        let startMouse: CGPoint
        let startFrame: CGRect
        var lastMouse: CGPoint
        let button: Int
        /// Edges being resized: the ones nearest the grab point, like Hyprland.
        var hEdge: Direction { startMouse.x < startFrame.midX ? .left : .right }
        var vEdge: Direction { startMouse.y < startFrame.midY ? .up : .down }
    }

    private let barHeight: CGFloat = 30
    /// Exported to child shells as HYPERMUX_SOCKET.
    var ipcPath: String?

    init(runtime: GhosttyRuntime, config: HypermuxConfig) {
        self.runtime = runtime
        self.config = config
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = screen.insetBy(dx: screen.width * 0.04, dy: screen.height * 0.04)
        window = MonitorWindow(
            contentRect: frame,
            styleMask: MonitorWindow.windowedStyle,
            backing: .buffered, defer: false)
        root = CompositorView(frame: NSRect(origin: .zero, size: frame.size))
        animator = Animator(hostView: root)
        wm = WindowManager(monitor: CGRect(origin: .zero, size: frame.size), settings: config.wm)
        super.init()

        window.title = "Hypermux"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.acceptsMouseMovedEvents = true
        // Fill style: the green button zooms (we turn that into fill); native: real full screen.
        window.collectionBehavior = config.fullscreenStyle == "native" ? [.fullScreenPrimary] : [.fullScreenNone]
        window.contentView = root
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("HypermuxMonitor")

        specialDim.wantsLayer = true
        specialDim.layer?.backgroundColor = NSColor.black.cgColor
        specialDim.alphaValue = 0
        specialDim.isHidden = true
        root.addSubview(specialDim)
        root.addSubview(hint)
        root.addSubview(bar)
        root.addSubview(banner)
        bar.onSelectWorkspace = { [weak self] n in self?.dispatch(.workspace(.id(n))) }

        wm.perform = { [weak self] e in self?.handle(e) }
        root.onResize = { [weak self] in self?.monitorChanged(animated: false) }
        applyConfigVisuals()
        monitorChanged(animated: false)
        installEventMonitors()
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.window.refit()
        }
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.window.applyPresentation()
        }
    }

    func start() {
        window.makeKeyAndOrderFront(nil)
        if config.fullscreenStyle == "fill", MonitorWindow.wasFilledAtQuit { setMonitorFullscreen(true) }
        let startup = config.execOnce + config.exec
        if startup.isEmpty {
            spawn(command: "", inheritFrom: nil)
        } else {
            for cmd in startup { spawn(command: cmd, inheritFrom: nil) }
        }
    }

    // MARK: Config

    func reload(_ newConfig: HypermuxConfig) {
        let ghosttyChanged = newConfig.ghostty != config.ghostty
        config = newConfig
        wm.settings = newConfig.wm
        window.collectionBehavior = newConfig.fullscreenStyle == "native" ? [.fullScreenPrimary] : [.fullScreenNone]
        if newConfig.fullscreenStyle == "native", window.isFilled { window.exitFill() }
        if ghosttyChanged { runtime.reload(extraConfig: newConfig.ghostty) }
        if submap != "reset" && !newConfig.binds.contains(where: { $0.submap == submap }) { submap = "reset" }
        applyConfigVisuals()
        for c in newConfig.exec { spawn(command: c, inheritFrom: nil) }
        monitorChanged(animated: true)
    }

    private func applyConfigVisuals() {
        // A background alpha below 1 makes the monitor window see-through (desktop shows in the gaps).
        let bg = config.backgroundColor
        let transparent = bg.a < 1
        window.isOpaque = !transparent
        window.hasShadow = !transparent
        window.backgroundColor = transparent ? .clear : NSColor(cgColor: bg.cg)
        // Keep a sliver of alpha: fully clear pixels let clicks fall through to apps behind.
        var paint = bg
        if transparent { paint.a = max(paint.a, 0.01) }
        root.layer?.backgroundColor = paint.cg
        if let c = config.activeBorder.colors.first {
            bar.accent = NSColor(cgColor: HypermuxCore.Color(r: c.r, g: c.g, b: c.b, a: 1).cg) ?? bar.accent
        }
        for v in views.values {
            (v.surface as? TerminalView)?.backdrop = runtime.backgroundColor
            v.refreshBackdrop()
        }
        hint.stringValue = hintText()
    }

    private func hintText() -> String {
        if let b = config.binds.first(where: {
            if case .exec(let c) = $0.dispatcher { return c.isEmpty && $0.submap == "reset" }
            return false
        }), case .key(let code) = b.trigger {
            return "Press \(Self.describe(b.mods))\(Self.keyName(code)) to open a terminal"
        }
        return "Empty workspace"
    }

    private static func describe(_ m: Modifiers) -> String {
        var s = ""
        if m.contains(.ctrl) { s += "⌃" }
        if m.contains(.alt) { s += "⌥" }
        if m.contains(.shift) { s += "⇧" }
        if m.contains(.super) { s += "⌘" }
        return s
    }

    private static func keyName(_ code: UInt16) -> String {
        switch code {
        case 0x24: return "↩"
        case 0x31: return "Space"
        default:
            return KeyCodes.table.first { $0.value == code && $0.key.count == 1 }?.key.uppercased() ?? "key \(code)"
        }
    }

    // MARK: Monitor geometry

    private var titlebarHeight: CGFloat {
        guard !window.styleMask.contains(.fullScreen) else { return 0 }
        return max(0, root.bounds.height - window.contentLayoutRect.height)
    }

    private func monitorChanged(animated: Bool) {
        let b = root.bounds
        wm.monitor = CGRect(origin: .zero, size: b.size)
        let top = max(barHeight, titlebarHeight)
        wm.reserved = Insets(top: top, right: 0, bottom: 0, left: 0)
        bar.frame = CGRect(x: 0, y: 0, width: b.width, height: top)
        bar.leadingInset = titlebarHeight > 0 ? 70 : 0
        specialDim.frame = b
        apply(animated: animated)
    }

    // MARK: Spawning and closing

    private func spawn(command: String, inheritFrom parent: TerminalView?) {
        guard let app = runtime.app else { return }
        let id = ClientID(nextID)
        nextID += 1
        var opts = SurfaceOptions.inherited(from: parent ?? focusedTerminal ?? lastTerminal)
        opts.command = command.isEmpty ? nil : command
        opts.env["HYPERMUX_CLIENT"] = "\(id.raw)"
        if let ipcPath { opts.env["HYPERMUX_SOCKET"] = ipcPath }
        let term = TerminalView(app: app, id: id, options: opts)
        guard term.surface != nil else {
            log.error("failed to create terminal surface")
            return
        }
        term.host = self
        term.backdrop = runtime.backgroundColor
        manage(term)
    }

    /// Engine for new web tiles. Chromium only if CEF started (see main.swift).
    var webEngine: String { HMChromium.isRunning ? "chromium" : "webkit" }

    private func allocateID() -> ClientID {
        defer { nextID += 1 }
        return ClientID(nextID)
    }

    /// Opens a web tile. Empty input = new-tab start page with the address bar focused.
    @discardableResult
    private func spawnWeb(_ input: String) -> BrowserSurface {
        let options = BrowserOptions(config)
        let id = allocateID()
        let web: BrowserSurface = webEngine == "chromium"
            ? ChromiumSurface(id: id, options: options)
            : WebKitSurface(id: id, options: options)
        web.host = self
        if input.isEmpty {
            // Deferred so the focus pass in apply() doesn't move focus back to the page.
            DispatchQueue.main.async { web.openStartPage() }
        } else {
            web.open(input)
        }
        manage(web)
        return web
    }

    /// Shows a booted simulator's screen in a tile. The simulator keeps running when the tile closes.
    /// Empty query: the only booted device, or a menu to pick one when several are booted.
    private func spawnSim(_ query: String) {
        if query.isEmpty {
            let booted: [HMSimDeviceInfo]
            do {
                booted = try HMSimulator.devices().filter(\.booted)
            } catch {
                flash("Simulator: \(error.localizedDescription)")
                return
            }
            switch booted.count {
            case 0: flash("No booted simulator. Boot one in Xcode or with xcrun simctl boot.")
            case 1: spawnSim(booted[0].udid)
            default: pickSimulator(booted)
            }
            return
        }
        let display: HMSimDisplay
        do {
            display = try HMSimDisplay(query: query)
        } catch {
            flash("Simulator: \(error.localizedDescription)")
            return
        }
        let sim = SimulatorSurface(id: allocateID(), display: display)
        sim.onClose = { [weak self] s in self?.removeClient(s.clientID) }
        manage(sim)
    }

    /// Menu of booted simulators, centered in the work area. Arrow keys + Return work.
    private func pickSimulator(_ devices: [HMSimDeviceInfo]) {
        let menu = NSMenu(title: "Simulators")
        let header = NSMenuItem(title: "Show simulator", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for d in devices {
            let item = NSMenuItem(title: "\(d.name)   \(Self.runtimeName(d.runtime))",
                                  action: #selector(pickedSimulator(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = d.udid
            menu.addItem(item)
        }
        let area = wm.workArea
        let at = NSPoint(x: area.midX - 150, y: area.midY - CGFloat(devices.count) * 11)
        // popUp runs a modal tracking loop; start it after the current event/IPC call returns.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            menu.popUp(positioning: nil, at: at, in: self.root)
        }
    }

    @objc private func pickedSimulator(_ item: NSMenuItem) {
        if let udid = item.representedObject as? String { spawnSim(udid) }
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-27-0" → "iOS 27.0".
    static func runtimeName(_ id: String) -> String {
        guard let last = id.split(separator: ".").last else { return id }
        let parts = last.split(separator: "-")
        guard let os = parts.first else { return String(last) }
        return os + " " + parts.dropFirst().joined(separator: ".")
    }

    /// Shows a message in the banner for a few seconds.
    private func flash(_ message: String) {
        transientNotes = [message]
        if let last { updateChrome(last) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.transientNotes == [message] else { return }
            self.transientNotes = []
            if let last = self.last { self.updateChrome(last) }
        }
    }

    private func manage(_ surface: Surface) {
        let v = ClientView(id: surface.clientID, surface: surface, decoration: Decoration(config))
        v.isHidden = true
        root.addSubview(v, positioned: .below, relativeTo: bar)
        views[surface.clientID] = v
        wm.addClient(surface.clientID)
        apply(animated: true)
    }

    private var focusedSurface: Surface? { wm.focused.flatMap { views[$0]?.surface } }
    private var focusedTerminal: TerminalView? { focusedSurface as? TerminalView }
    /// The most recently focused terminal, for inheriting cwd when spawning from a web surface.
    private weak var lastTerminal: TerminalView?
    /// Focused client as of the last updateFocus, to tell focus changes from re-applies.
    private var lastFocusApplied: ClientID?
    /// Short-lived messages shown in the banner (e.g. "no booted simulator").
    private var transientNotes: [String] = []

    private func removeClient(_ id: ClientID) {
        guard let v = views.removeValue(forKey: id) else { return }
        wm.removeClient(id)
        closing[id] = v
        let out = config.animation("windowsOut")
        let fade = config.animation("fadeOut")
        let finish = { [weak self, weak v] in
            guard let self, let v else { return }
            v.removeFromSuperview()
            v.surface.destroy()
            self.closing[id] = nil
        }
        if v.shown, out.enabled {
            let end = Self.popin(v.frame, style: out.style)
            v.move(to: end, duration: out.duration, curve: out.curve, animator: animator)
            v.fade(to: 0, duration: fade.enabled ? fade.duration : out.duration, curve: fade.curve, animator: animator, completion: finish)
        } else {
            finish()
        }
        apply(animated: true)
    }

    // MARK: Dispatch

    func dispatch(_ d: Dispatcher) {
        log.debug("dispatch \(String(describing: d), privacy: .public)")
        wm.dispatch(d)
        apply(animated: true)
    }

    private func handle(_ e: Effect) {
        switch e {
        case .spawn(let cmd):
            // Defer so the current dispatch finishes before the layout changes.
            DispatchQueue.main.async { [weak self] in self?.spawn(command: cmd, inheritFrom: nil) }
        case .close(let id):
            log.debug("killactive client=\(id.raw)")
            views[id]?.surface.requestClose()
        case .spawnSim(let q):
            DispatchQueue.main.async { [weak self] in self?.spawnSim(q) }
        case .simButton(let id, let name):
            (views[id]?.surface as? SimulatorSurface)?.press(name == "lock" ? .lock : .home)
        case .spawnWeb(let url):
            DispatchQueue.main.async { [weak self] in self?.spawnWeb(url) }
        case .webNav(let id, let nav):
            (views[id]?.surface as? BrowserSurface)?.perform(nav)
        case .submap(let name):
            submap = name
            bar.submap = name
        case .reload:
            NotificationCenter.default.post(name: .hypermuxReloadConfig, object: nil)
        case .monitorFullscreen:
            toggleMonitorFullscreen()
        case .exit:
            NSApp.terminate(nil)
        }
    }

    // MARK: Applying snapshots

    /// Brings views in line with the model, animating the difference.
    func apply(animated: Bool) {
        let snap = wm.snapshot()
        let prev = last
        last = snap
        let wsDelta = (prev?.activeWorkspace).map { snap.activeWorkspace - $0 } ?? 0
        let specialOpened = snap.specialVisible != nil && prev?.specialVisible != snap.specialVisible
        let specialClosed = prev?.specialVisible != nil && snap.specialVisible != prev?.specialVisible
        let deco = Decoration(config)
        let border = config.animation("border")
        let fadeSwitch = config.animation("fadeSwitch")
        let move = config.animation("windowsMove")
        let winIn = config.animation("windowsIn")
        let fadeIn = config.animation("fadeIn")
        let wsAnim = config.animation(wsDelta != 0 ? "workspaces" : "specialWorkspace")
        let spAnim = config.animation("specialWorkspace")
        let width = root.bounds.width, height = root.bounds.height

        func dur(_ a: ResolvedAnimation) -> Double { animated && a.enabled ? a.duration : 0 }

        for p in snap.placements {
            guard let v = views[p.id] else { continue }
            v.setDecoration(deco, active: p.focused, borderDuration: dur(border),
                            opacityAnimation: (dur(fadeSwitch), fadeSwitch.curve))
            let before = prev?.placement(p.id)

            if p.visible {
                if !v.shown {
                    v.shown = true
                    v.isHidden = false
                    v.surface.setOccluded(false)
                    if before == nil {
                        // New window.
                        let from = Self.popin(p.frame, style: winIn.style)
                        v.move(to: p.frame, from: from, duration: dur(winIn), curve: winIn.curve, animator: animator)
                        v.fade(from: 0, to: 1, duration: dur(fadeIn.enabled ? fadeIn : winIn), curve: fadeIn.curve, animator: animator)
                    } else if case .special = p.workspace, specialOpened {
                        let from = Self.offset(p.frame, style: spAnim.style, delta: -1, width: width, height: height)
                        v.move(to: p.frame, from: from, duration: dur(spAnim), curve: spAnim.curve, animator: animator)
                        v.fade(from: Self.fades(spAnim.style) ? 0 : 1, to: 1, duration: dur(spAnim), curve: spAnim.curve, animator: animator)
                    } else if wsDelta != 0 {
                        let from = Self.offset(p.frame, style: wsAnim.style, delta: wsDelta > 0 ? 1 : -1, width: width, height: height)
                        v.move(to: p.frame, from: from, duration: dur(wsAnim), curve: wsAnim.curve, animator: animator)
                        v.fade(from: Self.fades(wsAnim.style) ? 0 : 1, to: 1, duration: dur(wsAnim), curve: wsAnim.curve, animator: animator)
                    } else {
                        v.move(to: p.frame, duration: 0, curve: .linear, animator: animator)
                        v.fade(from: 0, to: 1, duration: dur(fadeIn), curve: fadeIn.curve, animator: animator)
                    }
                } else if v.targetFrame != p.frame {
                    v.move(to: p.frame, duration: drag?.id == p.id ? 0 : dur(move), curve: move.curve, animator: animator)
                }
            } else if v.shown {
                v.shown = false
                let hide = { [weak v] in
                    guard let v, !v.shown else { return }
                    v.isHidden = true
                    v.surface.setOccluded(true)
                }
                let anim: ResolvedAnimation
                let to: CGRect
                if case .special = p.workspace, specialClosed {
                    anim = spAnim
                    to = Self.offset(p.frame, style: spAnim.style, delta: -1, width: width, height: height)
                } else if wsDelta != 0, before?.visible == true, before?.workspace == p.workspace {
                    anim = wsAnim
                    to = Self.offset(p.frame, style: wsAnim.style, delta: wsDelta > 0 ? -1 : 1, width: width, height: height)
                } else {
                    anim = config.animation("fadeOut")
                    to = p.frame
                }
                if dur(anim) > 0 {
                    v.move(to: to, duration: dur(anim), curve: anim.curve, animator: animator, completion: hide)
                    if Self.fades(anim.style) || to == p.frame {
                        v.fade(to: 0, duration: dur(anim), curve: anim.curve, animator: animator)
                    }
                } else {
                    v.move(to: p.frame, duration: 0, curve: .linear, animator: animator)
                    hide()
                }
            } else if !v.isAnimating {
                // Hidden: keep geometry current so the next slide-in starts right.
                v.move(to: p.frame, duration: 0, curve: .linear, animator: animator)
            }
        }

        updateSpecialDim(visible: snap.specialVisible != nil, duration: dur(config.animation("fadeDim")))
        restack(snap)
        updateChrome(snap)
        updateFocus(snap)
    }

    private static func fades(_ style: String?) -> Bool {
        guard let s = style?.lowercased() else { return false }
        return s.hasPrefix("fade") || s.contains("fade")
    }

    /// Start/end frame for workspace transitions. `delta` > 0 means the rect sits to the right (or below).
    private static func offset(_ r: CGRect, style: String?, delta: Int, width: CGFloat, height: CGFloat) -> CGRect {
        let s = (style ?? "slide").lowercased()
        if s.hasPrefix("fade") { return r }
        if s.hasPrefix("slidevert") || s.hasPrefix("slidefadevert") {
            return r.offsetBy(dx: 0, dy: CGFloat(delta) * height)
        }
        return r.offsetBy(dx: CGFloat(delta) * width, dy: 0)
    }

    /// Start/end frame for window open/close: "popin 80%" scales around the center.
    private static func popin(_ r: CGRect, style: String?) -> CGRect {
        guard let s = style?.lowercased(), s.hasPrefix("popin") else {
            if style?.lowercased().hasPrefix("slide") == true { return r.offsetBy(dx: 0, dy: r.height / 3) }
            return r.scaled(0.9)
        }
        let pct = s.dropFirst("popin".count).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
        let f = (Double(pct) ?? 80) / 100
        return r.scaled(min(max(f, 0.1), 1))
    }

    private func updateSpecialDim(visible: Bool, duration: Double) {
        let target = visible ? CGFloat(config.dimSpecial) : 0
        if visible { specialDim.isHidden = false }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            specialDim.animator().alphaValue = target
        }, completionHandler: { [weak self] in
            guard let self, self.last?.specialVisible == nil else { return }
            self.specialDim.isHidden = true
        })
    }

    private func restack(_ snap: Snapshot) {
        var order: [ObjectIdentifier: Int] = [:]
        for p in snap.placements { if let v = views[p.id] { order[ObjectIdentifier(v)] = p.z } }
        for v in closing.values { order[ObjectIdentifier(v)] = 20_000 }
        order[ObjectIdentifier(specialDim)] = 9_999
        order[ObjectIdentifier(hint)] = -1
        order[ObjectIdentifier(bar)] = 30_000
        order[ObjectIdentifier(banner)] = 30_001
        if let d = drag, let v = views[d.id] { order[ObjectIdentifier(v)] = 25_000 }
        let current = root.subviews
        let sorted = current.sorted { (order[ObjectIdentifier($0)] ?? 0) < (order[ObjectIdentifier($1)] ?? 0) }
        guard sorted.map(ObjectIdentifier.init) != current.map(ObjectIdentifier.init) else { return }
        let box = Unmanaged.passRetained(ZOrder(order))
        defer { box.release() }
        root.sortSubviews({ a, b, ctx in
            let z = Unmanaged<ZOrder>.fromOpaque(ctx!).takeUnretainedValue().z
            let za = z[ObjectIdentifier(a)] ?? 0
            let zb = z[ObjectIdentifier(b)] ?? 0
            return za < zb ? .orderedAscending : (za > zb ? .orderedDescending : .orderedSame)
        }, context: box.toOpaque())
    }

    private func updateChrome(_ snap: Snapshot) {
        bar.workspaces = snap.workspaces
        bar.active = snap.activeWorkspace
        bar.special = snap.specialVisible
        bar.title = focusedSurface?.title ?? ""
        window.title = "Hypermux — \(snap.activeWorkspace)"

        let area = wm.workArea
        let empty = !snap.placements.contains { $0.visible }
        hint.isHidden = !empty
        hint.sizeToFit()
        hint.frame = CGRect(x: area.midX - 250, y: area.midY - hint.frame.height / 2, width: 500, height: hint.frame.height)

        let notes = config.errors + transientNotes
        if notes.isEmpty {
            banner.isHidden = true
        } else {
            banner.isHidden = false
            let w = min(900, area.width - 40)
            let h = banner.show(notes, width: w)
            banner.frame = CGRect(x: area.midX - w / 2, y: area.minY + 10, width: w, height: h)
        }
    }

    private func updateFocus(_ snap: Snapshot) {
        let changed = snap.focused != lastFocusApplied
        if changed { log.debug("focus \(self.lastFocusApplied?.raw ?? 0) -> \(snap.focused?.raw ?? 0)") }
        lastFocusApplied = snap.focused
        guard let id = snap.focused, let s = views[id]?.surface else {
            if window.firstResponder !== root { window.makeFirstResponder(root) }
            return
        }
        if let t = s as? TerminalView { lastTerminal = t }
        // Leave focus alone if it is already somewhere inside the surface (e.g. a web
        // page's address bar), unless the focused window just changed.
        if !changed && s.ownsFirstResponder(in: window) { return }
        if window.firstResponder !== s.focusTarget { s.takeFocus(in: window) }
    }

    // MARK: Input

    private func modifiers(_ f: NSEvent.ModifierFlags) -> Modifiers {
        var m: Modifiers = []
        if f.contains(.shift) { m.insert(.shift) }
        if f.contains(.control) { m.insert(.ctrl) }
        if f.contains(.option) { m.insert(.alt) }
        if f.contains(.command) { m.insert(.super) }
        return m
    }

    private func installEventMonitors() {
        // Note: `self?.handleKey(e) ?? e` would be wrong: a nil ("consumed") result
        // would fall back to `e` and leak the key to the terminal.
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] e in
            guard let self else { return e }
            return self.handleKey(e)
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] e in
            self?.handleMouseMoved(e)
            return e
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .leftMouseDragged, .rightMouseDragged, .leftMouseUp, .rightMouseUp]
        ) { [weak self] e in
            guard let self else { return e }
            return self.handleMouseBind(e)
        } as Any)
    }

    private func handleKey(_ e: NSEvent) -> NSEvent? {
        guard e.window === window else { return e }
        if e.type == .keyUp {
            return consumedKeyUps.remove(e.keyCode) != nil ? nil : e
        }
        let mods = modifiers(e.modifierFlags)
        guard let bind = config.binds.first(where: {
            $0.submap == submap && !$0.flags.contains("m") && $0.mods == mods && $0.trigger == .key(e.keyCode)
        }) else { return e }
        consumedKeyUps.insert(e.keyCode)
        if e.isARepeat && !bind.flags.contains("e") { return nil }
        dispatch(bind.dispatcher)
        return bind.flags.contains("n") ? e : nil
    }

    private func point(_ e: NSEvent) -> CGPoint { root.convert(e.locationInWindow, from: nil) }

    private func handleMouseMoved(_ e: NSEvent) {
        guard e.window === window, drag == nil else { return }
        let p = point(e)
        wm.cursor = p
        guard config.followMouse == 1, let id = wm.client(at: p), id != wm.focused else { return }
        log.debug("focus reason=mouse client=\(id.raw)")
        wm.focus(id)
        apply(animated: true)
    }

    private func handleMouseBind(_ e: NSEvent) -> NSEvent? {
        guard e.window === window else { return e }
        let p = point(e)
        switch e.type {
        case .leftMouseDown, .rightMouseDown:
            let button = e.type == .leftMouseDown ? 272 : 273
            let mods = modifiers(e.modifierFlags)
            guard let bind = config.binds.first(where: {
                $0.flags.contains("m") && $0.mods == mods && $0.trigger == .mouse(button)
            }), let id = wm.client(at: p), let v = views[id] else {
                // Plain click: focus the window under the pointer (web views don't report clicks to us).
                if let id = wm.client(at: p), id != wm.focused {
                    log.debug("focus reason=click client=\(id.raw)")
                    wm.focus(id)
                    apply(animated: true)
                }
                return e
            }
            let resize: Bool
            if case .resizeActive = bind.dispatcher { resize = true } else { resize = false }
            wm.focus(id)
            drag = Drag(id: id, resize: resize, floating: wm.isFloating(id), startMouse: p,
                        startFrame: v.targetFrame, lastMouse: p, button: button)
            apply(animated: true)
            if !resize { NSCursor.closedHand.push() }
            return nil
        case .leftMouseDragged, .rightMouseDragged:
            guard var d = drag, let v = views[d.id] else { return e }
            let dx = p.x - d.startMouse.x, dy = p.y - d.startMouse.y
            if d.floating {
                var r = d.startFrame
                if d.resize {
                    // Resize from the grabbed corner; the opposite corner stays put.
                    let minW: CGFloat = 120, minH: CGFloat = 80
                    if d.hEdge == .left {
                        let w = max(minW, r.width - dx)
                        r.origin.x = r.maxX - w
                        r.size.width = w
                    } else {
                        r.size.width = max(minW, r.width + dx)
                    }
                    if d.vEdge == .up {
                        let h = max(minH, r.height - dy)
                        r.origin.y = r.maxY - h
                        r.size.height = h
                    } else {
                        r.size.height = max(minH, r.height + dy)
                    }
                } else {
                    r.origin.x += dx
                    r.origin.y += dy
                }
                wm.setFloatingFrame(d.id, r)
                apply(animated: false)
            } else if d.resize {
                wm.moveTiledEdges(d.id, horizontal: d.hEdge, dx: p.x - d.lastMouse.x,
                                  vertical: d.vEdge, dy: p.y - d.lastMouse.y)
                apply(animated: false)
            } else {
                // Tiled drag: the window follows the pointer; it lands on mouse-up.
                v.move(to: d.startFrame.offsetBy(dx: dx, dy: dy), duration: 0, curve: .linear, animator: animator)
            }
            d.lastMouse = p
            drag = d
            return nil
        case .leftMouseUp, .rightMouseUp:
            guard let d = drag else { return e }
            drag = nil
            if !d.resize { NSCursor.pop() }
            if !d.floating && !d.resize && !d.startFrame.contains(p) {
                wm.dropTiled(d.id, at: p)
            }
            apply(animated: true)
            return nil
        default:
            return e
        }
    }

    // MARK: IPC

    func handleIPC(_ line: String) -> String {
        switch IPCRequest.parse(line) {
        case .failure(let e):
            return "error: \(e)"
        case .success(let req):
            switch req {
            case .dispatch(let d):
                dispatch(d)
                return "ok"
            case .clients:
                return json(wm.snapshot().placements.map(clientInfo))
            case .activeWindow:
                guard let f = wm.focused, let p = wm.snapshot().placement(f) else { return "{}" }
                return json(clientInfo(p))
            case .workspaces:
                let snap = wm.snapshot()
                var ids: [WorkspaceID] = snap.workspaces.map { .regular($0) }
                if let s = snap.specialVisible { ids.append(.special(s)) }
                return json(ids.map { id -> [String: Any] in
                    let members = snap.placements.filter { $0.workspace == id }
                    return ["id": id.description, "windows": members.count,
                            "active": id == .regular(snap.activeWorkspace) || id == snap.specialVisible.map { .special($0) }]
                })
            case .reload:
                handle(.reload)
                return "ok"
            case .version:
                return "hypermux 0.1.0"
            case .debug:
                let fr = window.firstResponder
                var frDesc = fr.map { String(describing: type(of: $0)) } ?? "nil"
                if let tv = fr as? NSTextView, tv.isFieldEditor, let d = tv.delegate { frDesc += " (editing \(type(of: d)))" }
                return json(["appActive": NSApp.isActive, "isKeyWindow": window.isKeyWindow,
                             "firstResponder": frDesc, "focused": wm.focused?.raw as Any? ?? NSNull()])
            case .sendText(let t):
                guard let term = focusedTerminal else { return "error: no focused terminal" }
                term.sendText(t)
                return "ok"
            case .sendKey(let mods, let code):
                injectKey(mods, code)
                return "ok"
            case .hitTest(let p):
                // Walk up from the hit view so the reply shows the whole chain.
                // hitTest takes the point in the receiver's superview coordinates.
                guard let frameView = root.superview else { return "error: no frame view" }
                let pInFrame = frameView.convert(root.convert(p, to: nil), from: nil)
                var chain: [String] = []
                var v = frameView.hitTest(pInFrame)
                while let cur = v, cur !== root { chain.append(String(describing: type(of: cur))); v = cur.superview }
                return json(["hit": chain])
            case .sendDrag(let mods, let button, let from, let to):
                injectDrag(mods, button: button, from: from, to: to)
                return "ok"
            }
        }
    }

    private func clientInfo(_ p: Placement) -> [String: Any] {
        let s = views[p.id]?.surface
        var info: [String: Any] = [
            "id": p.id.raw, "workspace": p.workspace.description, "floating": p.floating,
            "fullscreen": p.fullscreen.map { $0.rawValue } as Any? ?? NSNull(),
            "focused": p.focused, "visible": p.visible,
            "at": [p.frame.minX, p.frame.minY], "size": [p.frame.width, p.frame.height],
            "title": s?.title ?? "", "kind": s?.kind ?? "",
        ]
        for (k, v) in s?.info ?? [:] { info[k] = v }
        return info
    }

    private func json(_ v: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return "error: json" }
        return s
    }

    private func nsFlags(_ mods: Modifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if mods.contains(.shift) { flags.insert(.shift) }
        if mods.contains(.ctrl) { flags.insert(.control) }
        if mods.contains(.alt) { flags.insert(.option) }
        if mods.contains(.super) { flags.insert(.command) }
        return flags
    }

    /// Posts a synthetic mouse drag (down, 10 drag steps, up) through the normal event path.
    private func injectDrag(_ mods: Modifiers, button: Int, from: CGPoint, to: CGPoint) {
        let flags = nsFlags(mods)
        let right = button == 273
        let types: (NSEvent.EventType, NSEvent.EventType, NSEvent.EventType) = right
            ? (.rightMouseDown, .rightMouseDragged, .rightMouseUp)
            : (.leftMouseDown, .leftMouseDragged, .leftMouseUp)
        func post(_ type: NSEvent.EventType, _ p: CGPoint) {
            let loc = root.convert(p, to: nil)
            if let e = NSEvent.mouseEvent(
                with: type, location: loc, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == types.2 ? 0 : 1) {
                NSApp.postEvent(e, atStart: false)
            }
        }
        // Paced like a hand: ~16 ms per step, so gesture recognizers see a real drag, not a teleport.
        post(types.0, from)
        let steps = 20
        for i in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16 * i)) {
                let t = CGFloat(i) / CGFloat(steps)
                post(types.1, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16 * (steps + 1))) { post(types.2, to) }
    }

    /// Posts a synthetic key press through the normal event path (monitors, then responders).
    private func injectKey(_ mods: Modifiers, _ code: UInt16) {
        let flags = nsFlags(mods)
        let name = KeyCodes.table.first { $0.value == code && $0.key.count == 1 }?.key ?? ""
        let chars: String
        switch code {
        case 0x24: chars = "\r"
        case 0x30: chars = "\t"
        case 0x31: chars = " "
        case 0x35: chars = "\u{1b}"
        default: chars = mods.contains(.shift) ? name.uppercased() : name
        }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: chars,
                charactersIgnoringModifiers: name.isEmpty ? chars : name, isARepeat: false, keyCode: code) else { continue }
            if NSApp.isActive {
                NSApp.postEvent(e, atStart: false)
            } else {
                // Background app: AppKit drops key events for a window that isn't key,
                // so run the bind check ourselves and hand the rest to the first responder.
                guard let pass = handleKey(e), let r = window.firstResponder else { continue }
                if pass.type == .keyDown { r.keyDown(with: pass) } else { r.keyUp(with: pass) }
            }
        }
    }

    // MARK: TerminalViewHost

    func terminalDidRequestFocus(_ view: TerminalView) {
        guard wm.focused != view.clientID else { return }
        log.debug("focus reason=terminal client=\(view.clientID.raw)")
        wm.focus(view.clientID)
        apply(animated: true)
    }

    func terminalTitleDidChange(_ view: TerminalView) {
        if view.clientID == wm.focused { bar.title = view.title }
    }

    func terminalDidClose(_ view: TerminalView, processAlive: Bool) {
        log.debug("close cb client=\(view.clientID.raw) alive=\(processAlive)")
        removeClient(view.clientID)
    }

    func terminalDidRequestSpawn(_ view: TerminalView) {
        spawn(command: "", inheritFrom: view)
    }

    func terminal(_ view: TerminalView, perform dispatcher: Dispatcher) {
        if wm.focused != view.clientID { wm.focus(view.clientID) }
        dispatch(dispatcher)
    }

    func terminalDidToggleWindowFullscreen(_ view: TerminalView) {
        toggleMonitorFullscreen()
    }

    // MARK: Monitor full screen

    @objc func toggleMonitorFullscreen() {
        if config.fullscreenStyle == "native" {
            window.toggleFullScreen(nil)
        } else {
            setMonitorFullscreen(!window.isFilled)
        }
    }

    private func setMonitorFullscreen(_ on: Bool) {
        if on { window.enterFill() } else { window.exitFill() }
        // Style-mask changes can reset these.
        applyConfigVisuals()
        monitorChanged(animated: true)
        if let last { updateFocus(last) }
    }

    /// Green button in fill style: fill instead of zooming.
    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        guard config.fullscreenStyle == "fill" else { return true }
        setMonitorFullscreen(true)
        return false
    }

    func terminal(_ view: TerminalView, openURL url: URL) -> Bool {
        guard config.webOpenTerminalLinks, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        spawnWeb(url.absoluteString)
        return true
    }

    // MARK: BrowserSurfaceHost

    func browserSurfaceDidRequestFocus(_ s: BrowserSurface) {
        guard wm.focused != s.clientID, views[s.clientID] != nil else { return }
        log.debug("focus reason=web client=\(s.clientID.raw)")
        wm.focus(s.clientID)
        apply(animated: true)
    }

    func browserSurfaceTitleDidChange(_ s: BrowserSurface) {
        if s.clientID == wm.focused { bar.title = s.title }
    }

    func browserSurfaceDidClose(_ s: BrowserSurface) {
        removeClient(s.clientID)
    }

    func browserSurfaceDidBecomeReady(_ s: BrowserSurface) {
        // Chromium's view arrives after the tile; give it focus if its tile has it,
        // unless the user is already typing in the address bar.
        guard wm.focused == s.clientID, !s.ownsFirstResponder(in: window) || window.firstResponder === s.content else { return }
        s.takeFocus(in: window)
    }

    func browserSurface(_ s: BrowserSurface, openInNewTile url: String) {
        spawnWeb(url)
    }

    func browserSurfaceNextClientID(_ s: BrowserSurface) -> ClientID { allocateID() }

    func browserSurface(_ s: BrowserSurface, adoptPopup popup: BrowserSurface) {
        popup.host = self
        manage(popup)
    }

    // MARK: NSWindowDelegate

    func windowDidEnterFullScreen(_ notification: Notification) { monitorChanged(animated: true) }
    func windowDidExitFullScreen(_ notification: Notification) { monitorChanged(animated: true) }

    func windowDidBecomeKey(_ notification: Notification) {
        if let last { updateFocus(last) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }
}

private final class ZOrder {
    let z: [ObjectIdentifier: Int]
    init(_ z: [ObjectIdentifier: Int]) { self.z = z }
}

extension Notification.Name {
    static let hypermuxReloadConfig = Notification.Name("hypermuxReloadConfig")
}
