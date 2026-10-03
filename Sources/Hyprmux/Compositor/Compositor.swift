import AndroidEmulatorBridge
import AppKit
import Carbon
import HyprmuxCore
import HyprmuxCredentialSupport
import ChromiumBridge
import SimulatorBridge

/// Glue between the model (WindowManager), the monitor window, and terminal surfaces.
final class Compositor: NSObject, TerminalViewHost, BrowserSurfaceHost, NSWindowDelegate {
    let runtime: GhosttyRuntime
    private(set) var config: HyprmuxConfig
    let wm: WindowManager

    let window: MonitorWindow
    let root: CompositorView
    private let bar = BarView()
    private let barBackdrop = BarBackdrop()
    private let hint = HintView()
    private let specialDim = NSView()
    private let animator: Animator
    /// Hyprmux's own UI (notifications), above all tiles.
    let hud: HUD

    var views: [ClientID: ClientView] = [:]
    /// Serves client apps (docs/CLIENT_PROTOCOL.md).
    let clientServer = ClientServer()
    /// Registers the bundled broker agent with macOS (Compositor+Clients).
    let broker = BrokerRegistration()
    /// The Login Items notice shows once per launch on its own.
    var brokerApprovalShown = false
    /// Restored app tiles waiting to be relaunched together.
    var pendingAppRestores: [ClientSurface] = []
    let adapters = AdapterRuntime()
    /// The `.hmapp`s the launcher lists (docs/APPS.md).
    let apps = AppRuntime()
    /// Agents' resume reports, by terminal (see `hyprmuxctl resume`).
    var resumeReports: [ClientID: ResumeReport] = [:]
    let credentialProviders = CredentialProviderRuntime()
    /// The active credential picker flow. It contains no item or field data.
    var credentialRequest: UUID?
    /// Pending debounced session save.
    var sessionSaveWork: DispatchWorkItem?
    var sessionTimer: Timer?
    /// Off while a session is being rebuilt, so a half-built layout is never saved.
    var sessionSavingEnabled = false
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

    /// HYPRMUX_WINDOW_SIZE=1600x1000 opens the window at that size, centered, for
    /// reproducible demo recordings (scripts/demo/record.sh).
    static let fixedWindowSize: CGSize? = {
        guard let v = ProcessInfo.processInfo.environment["HYPRMUX_WINDOW_SIZE"] else { return nil }
        let p = v.lowercased().split(separator: "x").compactMap { Double($0) }
        return p.count == 2 && p[0] >= 400 && p[1] >= 300 ? CGSize(width: p[0], height: p[1]) : nil
    }()
    /// Exported to child shells as HYPRMUX_SOCKET.
    var ipcPath: String?

    init(runtime: GhosttyRuntime, config: HyprmuxConfig) {
        self.runtime = runtime
        self.config = config
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var frame = screen.insetBy(dx: screen.width * 0.04, dy: screen.height * 0.04)
        if let size = Self.fixedWindowSize {
            frame = NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height)
        }
        window = MonitorWindow(
            contentRect: frame,
            styleMask: MonitorWindow.windowedStyle,
            backing: .buffered, defer: false)
        root = CompositorView(frame: NSRect(origin: .zero, size: frame.size))
        animator = Animator(hostView: root)
        wm = WindowManager(monitor: CGRect(origin: .zero, size: frame.size), settings: config.wm)
        hud = HUD(config: config, theme: HUDTheme(config: config, terminal: runtime.style, background: runtime.backgroundColor),
                  animator: animator)
        super.init()

        window.title = "Hyprmux"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.acceptsMouseMovedEvents = true
        // Fill style: the green button zooms (we turn that into fill); native: real full screen.
        window.collectionBehavior = config.fullscreenStyle == "native" ? [.fullScreenPrimary] : [.fullScreenNone]
        window.contentView = root
        window.delegate = self
        window.isReleasedWhenClosed = false
        // A fixed size (demo recordings) neither restores nor saves the window's frame.
        if Self.fixedWindowSize == nil {
            window.setFrameAutosaveName("HyprmuxMonitor")
        } else {
            // A recording plays in the background: keep the window above others so nothing
            // covers it (macOS stops drawing fully covered windows). No title bar: macOS
            // draws its "being captured" badge where the window buttons would be.
            window.level = .floating
            window.styleMask = [.borderless]
        }

        specialDim.wantsLayer = true
        specialDim.layer?.backgroundColor = NSColor.black.cgColor
        specialDim.alphaValue = 0
        specialDim.isHidden = true
        root.addSubview(barBackdrop)
        root.addSubview(specialDim)
        root.addSubview(hint)
        root.addSubview(bar)
        root.addSubview(hud.layer)
        bar.onSelectWorkspace = { [weak self] n in self?.dispatch(.workspace(.id(n))) }
        // The bar sits at the root's origin, so its coordinates are the root's.
        bar.onPillsFrame = { [weak self] f in self?.barBackdrop.wrap(f) }
        hud.clientFrame = { [weak self] id in self?.views[id]?.targetFrame }
        hud.onFocusClient = { [weak self] id in self?.focusFromHUD(id) }
        hud.picker.onClose = { [weak self] in
            guard let self, let last = self.last else { return }
            self.lastFocusApplied = nil  // hand the keyboard back to the focused tile
            self.updateFocus(last)
        }

        wm.perform = { [weak self] e in self?.handle(e) }
        root.onResize = { [weak self] in self?.monitorChanged(animated: false) }
        applyConfigVisuals()
        monitorChanged(animated: false)
        syncConfigErrors()
        installEventMonitors()
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.window.refit()
        }
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.window.applyPresentation()
            // Back from System Settings: the user may have allowed the broker.
            self?.broker.recheck()
        }
    }

    func start() {
        ClientSurface.passes = { [weak self] tile, event in
            guard let self else { return false }
            return self.appPasses(tile, self.modifiers(event.modifierFlags), event.keyCode)
        }
        loadAdapters()
        loadCredentialProviders()
        // The catalog as it was on disk, so a restored session finds its apps by id; the
        // generated ones are refreshed in the background.
        loadApps()
        refreshApps()
        startBrokerRegistration()
        startClientServer()
        window.makeKeyAndOrderFront(nil)
        if config.fullscreenStyle == "fill", MonitorWindow.wasFilledAtQuit, Self.fixedWindowSize == nil { setMonitorFullscreen(true) }
        startSessionSaving()
        // A restored session replaces the startup programs.
        if restoreSession() { return }
        let startup = config.execOnce + config.exec
        if startup.isEmpty {
            spawn(command: "", inheritFrom: nil)
        } else {
            for cmd in startup { spawn(command: cmd, inheritFrom: nil) }
        }
    }

    // MARK: Config

    func reload(_ newConfig: HyprmuxConfig) {
        let ghosttyChanged = newConfig.ghostty != config.ghostty
        let brokerSettingChanged = newConfig.registerBroker != config.registerBroker
        config = newConfig
        if brokerSettingChanged { broker.update(setting: newConfig.registerBroker) }

        wm.settings = newConfig.wm
        window.collectionBehavior = newConfig.fullscreenStyle == "native" ? [.fullScreenPrimary] : [.fullScreenNone]
        if newConfig.fullscreenStyle == "native", window.isFilled { window.exitFill() }
        if ghosttyChanged { runtime.reload(extraConfig: newConfig.ghostty) }
        if submap != "reset" && !newConfig.binds.contains(where: { $0.submap == submap }) { submap = "reset" }
        applyConfigVisuals()
        hud.reload(config: newConfig, theme: HUDTheme(config: newConfig, terminal: runtime.style, background: runtime.backgroundColor))
        syncConfigErrors()
        for c in newConfig.exec { spawn(command: c, inheritFrom: nil) }
        loadAdapters()
        loadCredentialProviders()
        loadApps()
        refreshApps()
        monitorChanged(animated: true)
    }

    /// Config errors stay on screen as one notice until the config is fixed (or it's clicked away).
    private func syncConfigErrors() {
        let errors = config.errors
        guard !errors.isEmpty else {
            hud.notifications.dismiss(key: "config-errors")
            return
        }
        let shown = errors.prefix(5) + (errors.count > 5 ? ["…and \(errors.count - 5) more"] : [])
        hud.notifications.post(.error, title: errors.count == 1 ? "Config error" : "\(errors.count) config errors",
                               shown.joined(separator: "\n"), sticky: true, key: "config-errors")
    }

    /// A notice raised by a tile was clicked: show that tile.
    private func focusFromHUD(_ id: ClientID) {
        guard views[id] != nil else { return }
        wm.focus(id)  // switches to its workspace (or scratchpad) and shows a hidden group tab
        apply(animated: true)
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
        barBackdrop.configure(enabled: config.barBackdrop, transparent: transparent)
        barBackdrop.wrap(bar.pillsFrame)
        if let c = config.activeBorder.colors.first {
            bar.accent = NSColor(cgColor: HyprmuxCore.Color(r: c.r, g: c.g, b: c.b, a: 1).cg) ?? bar.accent
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

    /// What a picker key did, for the keycast. Nil for keys not worth showing.
    private static func pickerKeyLabel(_ code: UInt16) -> String? {
        switch code {
        case 0x24, 0x4C: "Choose"
        case 0x35: "Cancel"
        case 0x7E, 0x7D, 0x30, 0x23, 0x2D: "Select"
        default: nil
        }
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
        hud.layout(monitor: wm.monitor, workArea: wm.workArea, animated: animated)
        apply(animated: animated)
    }

    // MARK: Spawning and closing

    private func spawn(command: String, inheritFrom parent: TerminalView?) {
        var opts = SurfaceOptions.inherited(from: parent ?? focusedTerminal ?? lastTerminal)
        opts.command = command.isEmpty ? nil : command
        guard let term = makeTerminal(opts) else { return }
        manage(term)
    }

    /// A terminal surface with Hyprmux's environment, not yet managed.
    func makeTerminal(_ options: SurfaceOptions) -> TerminalView? {
        guard let app = runtime.app else { return nil }
        let id = allocateID()
        var opts = options
        opts.env["HYPRMUX_CLIENT"] = "\(id.raw)"
        opts.env["HYPRMUX_SURFACE_ID"] = "\(id.raw)"
        opts.env["HYPRMUX_PID"] = "\(getpid())"
        if let ipcPath { opts.env["HYPRMUX_SOCKET"] = ipcPath }
        if let executable = Bundle.main.executableURL {
            let directory = executable.deletingLastPathComponent()
            let control = directory.appendingPathComponent("hyprmuxctl")
            if FileManager.default.isExecutableFile(atPath: control.path) {
                opts.env["HYPRMUXCTL_PATH"] = control.path
                let inherited = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
                let entries = inherited.split(separator: ":").map(String.init)
                opts.env["PATH"] = entries.contains(directory.path) ? inherited : "\(directory.path):\(inherited)"
            }
        }
        if let resources = Bundle.main.resourceURL {
            let skill = resources.appendingPathComponent("skills/hyprmuxctl/SKILL.md")
            if FileManager.default.fileExists(atPath: skill.path) {
                opts.env["HYPRMUX_SKILL_PATH"] = skill.path
            }
        }
        let term = TerminalView(app: app, id: id, options: opts)
        guard term.surface != nil else {
            log.error("failed to create terminal surface")
            return nil
        }
        term.host = self
        term.backdrop = runtime.backgroundColor
        return term
    }

    /// Engine for new web tiles. Chromium only if CEF started (see main.swift).
    var webEngine: String { HMChromium.isRunning ? "chromium" : "webkit" }

    func allocateID() -> ClientID {
        defer { nextID += 1 }
        return ClientID(nextID)
    }

    /// Opens a web tile. Empty input = new-tab start page with the address bar focused.
    @discardableResult
    private func spawnWeb(_ input: String) -> BrowserSurface {
        let web = makeWeb(input)
        manage(web)
        return web
    }

    /// A web surface loading `input` (empty: the start page), not yet managed.
    func makeWeb(_ input: String, focusStartPage: Bool = true) -> BrowserSurface {
        let options = BrowserOptions(config)
        let id = allocateID()
        let web: BrowserSurface = webEngine == "chromium"
            ? ChromiumSurface(id: id, options: options)
            : WebKitSurface(id: id, options: options)
        web.host = self
        if input.isEmpty {
            // Deferred so the focus pass in apply() doesn't move focus back to the page.
            DispatchQueue.main.async { web.openStartPage(focusAddress: focusStartPage) }
        } else {
            web.open(input)
        }
        return web
    }

    /// Shows an iOS Simulator or Android Emulator in a tile.
    /// Empty query: the only running device, or one picker containing both platforms.
    private func spawnSim(_ query: String) {
        if query.isEmpty {
            let booted: [HMSimDeviceInfo]
            let simulatorError: Error?
            do {
                booted = try HMSimulator.devices().filter(\.booted)
                simulatorError = nil
            } catch {
                booted = []
                simulatorError = error
            }
            let android = AndroidEmulatorDiscovery.running()
            switch booted.count + android.count {
            case 0:
                if let simulatorError {
                    flash("No running device. Simulator: \(simulatorError.localizedDescription)")
                } else {
                    flash("No booted iOS Simulator or running Android emulator.")
                }
            case 1:
                if let device = booted.first { spawnSim(device.udid) }
                else if let endpoint = android.first { openAndroid(endpoint) }
            default:
                pickDevice(booted, android)
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
        manage(makeSim(display))
    }

    func makeSim(_ display: HMSimDisplay) -> SimulatorSurface {
        let sim = SimulatorSurface(id: allocateID(), display: display)
        sim.onClose = { [weak self] s in self?.removeClient(s.clientID) }
        return sim
    }

    /// Attaches to a running Android Virtual Device. Hyprmux never boots an AVD.
    /// Empty query: the sole running AVD, or a picker when several are running.
    private func spawnAndroid(_ query: String) {
        let endpoints = AndroidEmulatorDiscovery.running()
        if query.isEmpty {
            switch endpoints.count {
            case 0: flash("No running Android emulator. Start an AVD first.")
            case 1: openAndroid(endpoints[0])
            default: pickAndroidEmulator(endpoints)
            }
            return
        }
        guard let endpoint = AndroidEmulatorDiscovery.match(query, in: endpoints) else {
            flash("No running Android AVD matches \(query).")
            return
        }
        openAndroid(endpoint)
    }

    private func openAndroid(_ endpoint: AndroidEmulatorEndpoint) {
        do {
            manage(try makeAndroid(endpoint))
        } catch {
            flash("Android Emulator: \(error.localizedDescription)")
        }
    }

    func makeAndroid(_ endpoint: AndroidEmulatorEndpoint) throws -> AndroidSurface {
        let android = try AndroidSurface(id: allocateID(), endpoint: endpoint)
        android.onClose = { [weak self] surface in self?.removeClient(surface.clientID) }
        android.onError = { [weak self] message in self?.flash("Android Emulator: \(message)") }
        return android
    }

    // MARK: Pickers

    /// `picker, KIND`: the workspace pickers and the rename prompt.
    private func presentPicker(_ kind: PickerKind) {
        switch kind {
        case .workspace, .moveToWorkspace, .moveToWorkspaceSilent:
            let moving = kind != .workspace
            guard !moving || wm.focused != nil else {
                flash("No window to move")
                return
            }
            let choices = wm.workspaceChoices(extraSpecials: moving ? scratchpadNames : [])
            var picker = Picker(title: moving ? "move to" : "workspace", items: WorkspacePicker.items(choices),
                                allowsCustom: true, searchesDetail: false, maxVisible: config.hud.pickerMaxRows)
            picker.placeholder = "number or name; a new name makes a workspace"
            hud.picker.present(picker) { [weak self] r in
                guard let self, let r, let t = WorkspacePicker.target(for: r) else { return }
                self.dispatch(moving ? .moveToWorkspace(t, silent: kind == .moveToWorkspaceSilent) : .workspace(t))
            }
        case .layout:
            presentLayoutPicker()
        case .saveLayout:
            presentSaveLayoutPrompt()
        case .apps:
            presentAppLauncher()
        case .renameWorkspace:
            let n = wm.activeWorkspace
            var picker = Picker(title: "name \(n)", mode: .prompt, query: wm.name(of: n) ?? "")
            picker.placeholder = "empty clears the name"
            hud.picker.present(picker) { [weak self] r in
                guard case .text(let name)? = r else { return }
                self?.dispatch(.renameWorkspace(n, name))
            }
        }
    }

    /// Special workspaces the binds use, so "move to" offers them even when empty.
    private var scratchpadNames: [String] {
        Array(Set(config.binds.compactMap { b -> String? in
            switch b.dispatcher {
            case .toggleSpecialWorkspace(let s): return s
            case .moveToWorkspace(.special(let s), _): return s
            default: return nil
            }
        })).sorted()
    }

    /// One picker for every running mobile device Hyprmux can embed.
    private func pickDevice(_ devices: [HMSimDeviceInfo], _ endpoints: [AndroidEmulatorEndpoint]) {
        let ios = devices.map {
            PickerItem(id: "ios:\($0.udid)", title: $0.name, detail: Self.runtimeName($0.runtime))
        }
        let android = endpoints.map {
            let detail = $0.avdID == $0.name ? "Android" : "Android · \($0.avdID)"
            return PickerItem(id: "android:\($0.avdID)", title: $0.name, detail: detail)
        }
        hud.picker.present(Picker(title: "device", items: ios + android, maxVisible: config.hud.pickerMaxRows)) { [weak self] result in
            guard case .item(let id)? = result else { return }
            if id.hasPrefix("ios:") {
                self?.spawnSim(String(id.dropFirst(4)))
            } else if id.hasPrefix("android:") {
                self?.spawnAndroid(String(id.dropFirst(8)))
            }
        }
    }

    /// Picker of AVDs that already have a live emulator process.
    private func pickAndroidEmulator(_ endpoints: [AndroidEmulatorEndpoint]) {
        let items = endpoints.map {
            PickerItem(id: String($0.pid), title: $0.name, detail: $0.avdID == $0.name ? "running" : $0.avdID)
        }
        hud.picker.present(Picker(title: "android emulator", items: items, maxVisible: config.hud.pickerMaxRows)) { [weak self] result in
            guard case .item(let rawPID)? = result, let pid = Int32(rawPID),
                  let endpoint = endpoints.first(where: { $0.pid == pid }) else { return }
            self?.openAndroid(endpoint)
        }
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-27-0" → "iOS 27.0".
    static func runtimeName(_ id: String) -> String {
        guard let last = id.split(separator: ".").last else { return id }
        let parts = last.split(separator: "-")
        guard let os = parts.first else { return String(last) }
        return os + " " + parts.dropFirst().joined(separator: ".")
    }

    /// A short-lived warning, e.g. "no booted simulator".
    func flash(_ message: String) {
        hud.notifications.post(.warning, message)
    }

    func manage(_ surface: Surface) {
        adopt(surface)
        wm.addClient(surface.clientID)
        apply(animated: true)
    }

    /// Gives a surface its view, without placing it in the layout (session restore places it).
    func adopt(_ surface: Surface) {
        let v = ClientView(id: surface.clientID, surface: surface, decoration: Decoration(config))
        v.isHidden = true
        root.addSubview(v, positioned: .below, relativeTo: bar)
        views[surface.clientID] = v
    }

    private var focusedSurface: Surface? { wm.focused.flatMap { views[$0]?.surface } }
    private var focusedTerminal: TerminalView? { focusedSurface as? TerminalView }
    /// The most recently focused terminal, for inheriting cwd when spawning from a web surface.
    private weak var lastTerminal: TerminalView?
    /// Focused client as of the last updateFocus, to tell focus changes from re-applies.
    private var lastFocusApplied: ClientID?

    func removeClient(_ id: ClientID) {
        guard let v = views.removeValue(forKey: id) else { return }
        resumeReports[id] = nil
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

    func dispatch(_ d: Dispatcher, target: ClientID? = nil) {
        log.debug("dispatch \(String(describing: d), privacy: .public) target=\(target?.raw ?? 0)")
        wm.dispatch(d, target: target)
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
        case .spawnAndroid(let q):
            DispatchQueue.main.async { [weak self] in self?.spawnAndroid(q) }
        case .simButton(let id, let name):
            (views[id]?.surface as? SimulatorSurface)?.press(name == "lock" ? .lock : .home)
        case .spawnWeb(let url):
            DispatchQueue.main.async { [weak self] in self?.spawnWeb(url) }
        case .webNav(let id, let nav):
            (views[id]?.surface as? BrowserSurface)?.perform(nav)
        case .credentialFill(let id, let provider):
            DispatchQueue.main.async { [weak self] in self?.credentialFill(id, providerID: provider) }
        case .submap(let name):
            submap = name
            bar.submap = name
        case .picker(let kind):
            DispatchQueue.main.async { [weak self] in self?.presentPicker(kind) }
        case .launch(let app):
            DispatchQueue.main.async { [weak self] in self?.launchFromBind(app) }
        case .reload:
            NotificationCenter.default.post(name: .hyprmuxReloadConfig, object: nil)
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
            var d = deco
            if p.group != nil {
                d.activeBorder = config.groupActiveBorder
                d.inactiveBorder = config.groupInactiveBorder
                if let w = config.groupBorderSize { d.borderSize = w }
            }
            // Hidden tabs look "active" too, so a tab switch doesn't flash dimmed content.
            let isActive = p.focused || (p.group.map { $0.members.contains(snap.focused ?? ClientID(0)) } ?? false)
            v.setDecoration(d, active: isActive, borderDuration: dur(border),
                            opacityAnimation: (dur(fadeSwitch), fadeSwitch.curve))
            updateGroupBar(v, p.group)
            let before = prev?.placement(p.id)

            // A group switching tabs (same group, same workspace): swap instantly, like
            // Hyprland. A cross-fade let the transparent background blink through.
            let tabSwitch = wsDelta == 0 && before != nil && p.group != nil && before?.group?.id == p.group?.id
                && before?.workspace == p.workspace

            if p.visible {
                if !v.shown {
                    v.shown = true
                    v.isHidden = false
                    v.surface.setOccluded(false)
                    if tabSwitch {
                        v.move(to: p.frame, duration: 0, curve: .linear, animator: animator)
                        v.fade(from: 1, to: 1, duration: 0, curve: .linear, animator: animator)
                    } else if before == nil {
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
                if tabSwitch {
                    // Hidden in the same frame the new tab appears.
                    v.move(to: p.frame, duration: 0, curve: .linear, animator: animator)
                    hide()
                    continue
                } else if case .special = p.workspace, specialClosed {
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
        scheduleSessionSave()
    }

    /// Tab strip for a grouped placement (nil removes it).
    private func updateGroupBar(_ v: ClientView, _ info: GroupInfo?) {
        guard let info, config.groupbarEnabled else {
            v.setGroupBar(nil, style: GroupBarStyle(config))
            return
        }
        let titles = info.members.map { m -> String in
            guard let s = views[m]?.surface else { return "" }
            return s.title.isEmpty ? s.kind : s.title
        }
        let active = info.members.firstIndex(of: info.active) ?? 0
        v.setGroupBar((titles, active), style: GroupBarStyle(config))
        let members = info.members
        v.onSelectTab = { [weak self] i in
            guard let self, i < members.count else { return }
            self.wm.focus(members[i])
            self.apply(animated: true)
        }
    }

    /// Titles changed: refresh the tab strips without touching layout.
    private func refreshGroupBars() {
        guard let last else { return }
        for p in last.placements where p.group != nil {
            if let v = views[p.id] { updateGroupBar(v, p.group) }
        }
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
        order[ObjectIdentifier(barBackdrop)] = -2
        order[ObjectIdentifier(bar)] = 30_000
        order[ObjectIdentifier(hud.layer)] = 30_001
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
        bar.names = snap.workspaceNames
        bar.active = snap.activeWorkspace
        bar.special = snap.specialVisible
        bar.title = focusedSurface?.title ?? ""
        window.title = "Hyprmux — \(snap.activeWorkspace)"

        let area = wm.workArea
        let empty = !snap.placements.contains { $0.visible }
        hint.isHidden = !empty
        hint.sizeToFit()
        hint.frame = CGRect(x: area.midX - 250, y: area.midY - hint.frame.height / 2, width: 500, height: hint.frame.height)
    }

    private func updateFocus(_ snap: Snapshot) {
        if hud.picker.isOpen {
            hud.picker.focus(in: window)
            return
        }
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

    /// Binds win in every tile, except chords the focused app's `pass` list claims.
    /// Submaps are Hyprmux's own modes, so they keep their keys.
    private func appPasses(_ tile: ClientSurface, _ mods: Modifiers, _ code: UInt16) -> Bool {
        guard submap == "reset", tile.connection != nil, window.firstResponder === tile,
              let id = tile.appEntry, let pass = config.appPass[id] else { return false }
        return pass.contains(AppChord(mods: mods, key: code))
    }

    private var focusedAppTile: ClientSurface? {
        guard let f = wm.focused else { return nil }
        return views[f]?.surface as? ClientSurface
    }

    private func handleKey(_ e: NSEvent) -> NSEvent? {
        guard e.window === window else { return e }
        if e.type == .keyUp {
            return consumedKeyUps.remove(e.keyCode) != nil ? nil : e
        }
        // An open picker holds the keyboard: no binds; its keys, or the query field's.
        if hud.picker.isOpen {
            hud.picker.focus(in: window)
            guard hud.picker.handleKey(e) else { return e }
            consumedKeyUps.insert(e.keyCode)
            if let label = Self.pickerKeyLabel(e.keyCode) {
                hud.keycast.press(chord: KeyChord.display(modifiers(e.modifierFlags), .key(e.keyCode)), label: label)
            }
            return nil
        }
        let mods = modifiers(e.modifierFlags)
        if let tile = focusedAppTile, appPasses(tile, mods, e.keyCode) { return e }
        guard let bind = config.binds.first(where: {
            $0.submap == submap && !$0.flags.contains("m") && $0.mods == mods && $0.trigger == .key(e.keyCode)
        }) else { return e }
        consumedKeyUps.insert(e.keyCode)
        if e.isARepeat && !bind.flags.contains("e") { return nil }
        hud.keycast.press(chord: KeyChord.display(bind.mods, bind.trigger), label: bind.label)
        dispatch(bind.dispatcher)
        return bind.flags.contains("n") ? e : nil
    }

    private func point(_ e: NSEvent) -> CGPoint { root.convert(e.locationInWindow, from: nil) }

    private func handleMouseMoved(_ e: NSEvent) {
        guard e.window === window, drag == nil else { return }
        let p = point(e)
        wm.cursor = p
        // Views track the mouse even while Hyprmux is in the background. Without this,
        // passing the pointer over the window from another app silently moved focus.
        guard NSApp.isActive, window.isKeyWindow, !hud.contains(p) else { return }
        guard config.followMouse == 1, let id = wm.client(at: p), id != wm.focused else { return }
        log.debug("focus reason=mouse client=\(id.raw)")
        wm.focus(id)
        apply(animated: true)
    }

    private func hasHoveredLink(_ s: Surface?) -> Bool {
        switch s {
        case let t as TerminalView: t.hoveredLink != nil
        case let b as BrowserSurface: b.hoveredLink != nil
        default: false
        }
    }

    private func handleMouseBind(_ e: NSEvent) -> NSEvent? {
        guard e.window === window else { return e }
        let p = point(e)
        switch e.type {
        case .leftMouseDown, .rightMouseDown:
            // HUD panels take their own clicks; the tile under them must not react.
            if hud.contains(p) { return e }
            let button = e.type == .leftMouseDown ? 272 : 273
            let mods = modifiers(e.modifierFlags)
            // Cmd+click on a link (terminal or web) opens the link, even when $mod+click moves windows.
            if button == 272, e.modifierFlags.contains(.command), let id = wm.client(at: p), hasHoveredLink(views[id]?.surface) {
                if id != wm.focused {
                    wm.focus(id)
                    apply(animated: true)
                }
                return e
            }
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

    /// `adapters match`, `apps refresh`, `apps add`, and `broker` wait off the main thread
    /// (probes, a scan, launchd); everything else replies here.
    func handleIPCReply(_ line: String) -> IPCReply {
        switch IPCRequest.parse(line) {
        case .success(.adaptersMatch(let target)): return adaptersMatch(target)
        case .success(.appsRefresh): return appsRefresh()
        case .success(.appsAdd(let words)): return appsAdd(words)
        case .success(.broker(let action)): return brokerReply(action)
        default: return .text(handleIPC(line))
        }
    }

    func handleIPC(_ line: String) -> String {
        switch IPCRequest.parse(line) {
        case .failure(let e):
            return "error: \(e)"
        case .success(let req):
            switch req {
            case .dispatch(let d, nil):
                dispatch(d)
                return "ok"
            case .dispatch(let d, let reference?):
                guard let (id, surface) = automationTarget(reference) else { return "error: surface not found" }
                switch d {
                case .webNav where !(surface is BrowserSurface):
                    return "error: surface \(id.raw) is not a web surface"
                case .simButton where !(surface is SimulatorSurface):
                    return "error: surface \(id.raw) is not an iOS simulator"
                default:
                    dispatch(d, target: id)
                    return "ok"
                }
            case .newSurface(let request):
                return openSurface(request)
            case .closeSurface(let reference):
                guard let (id, surface) = automationTarget(reference) else { return "error: surface not found" }
                log.debug("close-surface client=\(id.raw)")
                surface.requestClose()
                return "ok"
            case .focusSurface(let reference):
                guard let (id, _) = automationTarget(reference) else { return "error: surface not found" }
                log.debug("focus reason=ipc client=\(id.raw)")
                wm.focus(id)
                apply(animated: true)
                return "ok"
            case .moveSurface(let reference, let workspace, let focus):
                guard let (id, _) = automationTarget(reference) else { return "error: surface not found" }
                // Replies with the surface's entry, so the caller sees where it ended up.
                dispatch(.moveToWorkspace(workspace, silent: !focus), target: id)
                guard let p = wm.snapshot().placement(id) else { return "error: surface not found" }
                return json(clientInfo(p))
            case .clients, .surfaces:
                return json(wm.snapshot().placements.map(clientInfo))
            case .identify(let reference):
                guard let (id, _) = automationTarget(reference), let placement = wm.snapshot().placement(id) else {
                    return "error: surface not found"
                }
                return json(clientInfo(placement))
            case .activeWindow:
                guard let f = wm.focused, let p = wm.snapshot().placement(f) else { return "{}" }
                return json(clientInfo(p))
            case .workspaces:
                let snap = wm.snapshot()
                var ids: [WorkspaceID] = snap.workspaces.map { .regular($0) }
                if let s = snap.specialVisible { ids.append(.special(s)) }
                return json(ids.map { id -> [String: Any] in
                    let members = snap.placements.filter { $0.workspace == id }
                    var name: Any = NSNull()
                    if case .regular(let n) = id, let s = wm.name(of: n) { name = s }
                    return ["id": id.description, "name": name, "windows": members.count,
                            "active": id == .regular(snap.activeWorkspace) || id == snap.specialVisible.map { .special($0) }]
                })
            case .reload:
                handle(.reload)
                return "ok"
            case .adapters:
                return json(adaptersJSON())
            case .adaptersReload:
                loadAdapters()
                return json(adaptersJSON())
            case .adaptersMatch, .appsRefresh, .appsAdd, .broker:
                return "error: this request runs through handleIPCReply"
            case .apps:
                return json(appsJSON())
            case .launch(let words, let focus):
                return launchReply(words, focus: focus)
            case .caption(let text):
                hud.caption.show(text)
                return "ok"
            case .sendMenu(let title):
                return Self.performMenuItem(title) ? "ok" : "error: no enabled menu item \(title)"
            case .resume(let r):
                let id = ClientID(r.client)
                guard views[id]?.surface is TerminalView else { return "error: no terminal \(r.client)" }
                resumeReports[id] = r
                log.debug("resume report client=\(r.client) kind=\(r.kind, privacy: .public)")
                scheduleSessionSave()
                return "ok"
            case .version:
                let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                return "hyprmux \(v ?? "dev")"
            case .debug:
                let fr = window.firstResponder
                var frDesc = fr.map { String(describing: type(of: $0)) } ?? "nil"
                if let tv = fr as? NSTextView, tv.isFieldEditor, let d = tv.delegate { frDesc += " (editing \(type(of: d)))" }
                // Which client's surface holds the keyboard (walk up from the first responder).
                var owner: Any = NSNull()
                if let v = fr as? NSView {
                    var cur: NSView? = v
                    while let c = cur, !(c is ClientView) { cur = c.superview }
                    if let cv = cur as? ClientView { owner = cv.id.raw }
                }
                return json(["appActive": NSApp.isActive, "isKeyWindow": window.isKeyWindow,
                             "firstResponder": frDesc, "keyboardClient": owner,
                             "focused": wm.focused?.raw as Any? ?? NSNull(),
                             "hud": hud.debugFrames.map { [$0.minX, $0.minY, $0.width, $0.height] },
                             "picker": hud.debugPicker])
            case .sendText(let t):
                guard let term = focusedTerminal else { return "error: no focused terminal" }
                term.sendText(t)
                return "ok"
            case .sendKey(let mods, let code):
                injectKey(mods, code)
                return "ok"
            case .readSelection(let reference, let wantsJSON):
                guard let (id, surface) = automationTarget(reference) else { return "error: surface not found" }
                guard let term = surface as? TerminalView else { return "error: surface \(id.raw) is not a terminal" }
                guard let selection = term.readTerminalSelection() else {
                    return "error: terminal \(id.raw) has no selected text"
                }
                let maximumBytes = 64 * 1024
                guard selection.text.utf8.count <= maximumBytes else {
                    return "error: terminal selection exceeds \(maximumBytes) bytes"
                }
                if wantsJSON {
                    return json(["id": id.raw, "ref": SurfaceReference(id.raw).description,
                                 "text": selection.text, "selectedAt": selection.selectedAt])
                }
                return selection.text
            case .readScreen(let reference, let scrollback, let lines, let wantsJSON):
                guard let (id, surface) = automationTarget(reference) else { return "error: surface not found" }
                guard let term = surface as? TerminalView else { return "error: surface \(id.raw) is not a terminal" }
                guard let text = term.readTerminalText(includeScrollback: scrollback, lines: lines) else {
                    return "error: failed to read terminal \(id.raw)"
                }
                let maximumBytes = 16 * 1024 * 1024
                guard text.utf8.count <= maximumBytes else {
                    return "error: terminal content exceeds \(maximumBytes) bytes; use --lines"
                }
                if wantsJSON {
                    return json(["id": id.raw, "ref": SurfaceReference(id.raw).description, "text": text,
                                 "scrollback": scrollback, "lines": lines as Any? ?? NSNull()])
                }
                return text
            case .sendSurfaceText(let reference, let text):
                guard let (id, surface) = automationTarget(reference) else { return "error: surface not found" }
                if let app = surface as? ClientSurface {
                    // App tiles type through text input, the path dictation uses.
                    return app.commitText(text) ? "ok" : "error: surface \(id.raw) doesn't accept text input"
                }
                guard let term = surface as? TerminalView else { return "error: surface \(id.raw) is not a terminal" }
                term.sendText(text)
                return "ok"
            case .sendSurfaceKey(let reference, let key):
                guard let (id, surface) = automationTarget(reference) else { return "error: surface not found" }
                guard let term = surface as? TerminalView else { return "error: surface \(id.raw) is not a terminal" }
                guard term.sendTerminalKey(key) else { return "error: failed to send key to terminal \(id.raw)" }
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
            case .snapshot(let reference, let path):
                guard let (id, surface) = automationTarget(reference) else { return "error: surface not found" }
                guard let tile = surface as? ClientSurface else { return "error: surface \(id.raw) is not an app tile" }
                do { try tile.writeSnapshot(to: URL(fileURLWithPath: path)) } catch { return "error: \(error.localizedDescription)" }
                return "ok"
            case .sendScroll(let mods, let lines, let at):
                // A line-unit CGEvent, like a notched wheel: AppKit derives deltaY and the
                // raw notch count from it, as for real hardware.
                guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                       wheel1: Int32(lines), wheel2: 0, wheel3: 0) else { return "error: scroll event" }
                // A scroll event made from a CGEvent has no window, and AppKit reads its
                // location as window coordinates. So place it at the window point and
                // hand it to the window, which routes it to the view under that point.
                let inWindow = root.convert(at, to: nil)
                let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
                cg.location = CGPoint(x: inWindow.x, y: primaryHeight - inWindow.y)
                cg.flags = CGEventFlags(rawValue: UInt64(nsFlags(mods).rawValue))
                guard let e = NSEvent(cgEvent: cg) else { return "error: scroll event" }
                window.sendEvent(e)
                return "ok"
            case .sendMouse(let phase, let mods, let button, let at):
                let right = button == 273, middle = button == 274
                let type: NSEvent.EventType = switch phase {
                case "down": middle ? .otherMouseDown : right ? .rightMouseDown : .leftMouseDown
                case "drag": middle ? .otherMouseDragged : right ? .rightMouseDragged : .leftMouseDragged
                case "move": .mouseMoved
                default: middle ? .otherMouseUp : right ? .rightMouseUp : .leftMouseUp
                }
                if var e = NSEvent.mouseEvent(
                    with: type, location: root.convert(at, to: nil), modifierFlags: nsFlags(mods),
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: phase == "up" ? 0 : 1) {
                    // mouseEvent(with:) can't set the button; other-mouse events default to 0.
                    if middle, let cg = e.cgEvent {
                        cg.setIntegerValueField(.mouseEventButtonNumber, value: 2)
                        e = NSEvent(cgEvent: cg) ?? e
                    }
                    NSApp.postEvent(e, atStart: false)
                }
                return "ok"
            }
        }
    }

    func clientInfo(_ p: Placement) -> [String: Any] {
        let s = views[p.id]?.surface
        var info: [String: Any] = [
            "id": p.id.raw, "ref": SurfaceReference(p.id.raw).description,
            "workspace": p.workspace.description, "floating": p.floating,
            "fullscreen": p.fullscreen.map { $0.rawValue } as Any? ?? NSNull(),
            "focused": p.focused, "visible": p.visible,
            "at": [p.frame.minX, p.frame.minY], "size": [p.frame.width, p.frame.height],
            "title": s?.title ?? "", "kind": s?.kind ?? "",
            "capabilities": s?.automationCapabilities ?? [],
        ]
        for (k, v) in s?.info ?? [:] { info[k] = v }
        if let c = s as? ClientSurface, let pid = c.connection?.pid, let a = adapterName(forPid: pid) { info["adapter"] = a }
        if let g = p.group {
            info["group"] = ["id": g.id.raw, "members": g.members.map(\.raw), "active": g.active.raw]
        }
        return info
    }

    /// `new-surface`: opens a surface synchronously and replies with its `surfaces` entry.
    private func openSurface(_ r: NewSurfaceRequest) -> String {
        var workspace: WorkspaceID?
        if let t = r.workspace {
            guard let id = wm.claimWorkspace(t) else { return "error: no such workspace" }
            workspace = id
        }
        let surface: Surface
        switch r.kind {
        case .terminal:
            var opts = SurfaceOptions.inherited(from: focusedTerminal ?? lastTerminal)
            if let cwd = r.cwd { opts.workingDirectory = cwd }
            opts.command = r.argument.isEmpty ? nil : r.argument
            opts.initialInput = r.input
            guard let term = makeTerminal(opts) else { return "error: failed to create terminal" }
            surface = term
        case .web:
            surface = makeWeb(r.argument, focusStartPage: r.focus)
        case .sim:
            let query = r.argument.isEmpty ? "booted" : r.argument
            do {
                surface = makeSim(try HMSimDisplay(query: query))
            } catch {
                return "error: simulator: \(error.localizedDescription)"
            }
        case .android:
            let endpoints = AndroidEmulatorDiscovery.running()
            let endpoint: AndroidEmulatorEndpoint
            if r.argument.isEmpty {
                guard endpoints.count == 1 else {
                    return endpoints.isEmpty
                        ? "error: no running Android emulator"
                        : "error: several Android emulators are running; name one"
                }
                endpoint = endpoints[0]
            } else {
                guard let match = AndroidEmulatorDiscovery.match(r.argument, in: endpoints) else {
                    return "error: no running Android AVD matches \(r.argument)"
                }
                endpoint = match
            }
            do {
                surface = try makeAndroid(endpoint)
            } catch {
                return "error: Android Emulator: \(error.localizedDescription)"
            }
        case .app:
            do {
                surface = try makeApp(r.argument)
            } catch {
                return "error: \(error.localizedDescription)"
            }
        }
        adopt(surface)
        wm.addClient(surface.clientID, floating: r.floating, workspace: workspace, focus: r.focus)
        apply(animated: true)
        guard let p = wm.snapshot().placement(surface.clientID) else { return "error: surface closed while opening" }
        return json(clientInfo(p))
    }

    private func automationTarget(_ reference: SurfaceReference?) -> (ClientID, Surface)? {
        guard let id = reference.map({ ClientID($0.raw) }) ?? wm.focused,
              let surface = views[id]?.surface else { return nil }
        return (id, surface)
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

    /// `sendmenu TITLE`: performs the main-menu item with that title, as a click would.
    /// Case doesn't matter, and "..." matches "…". False when no enabled item matches.
    static func performMenuItem(_ title: String) -> Bool {
        func normalized(_ s: String) -> String { s.replacingOccurrences(of: "...", with: "…").lowercased() }
        let wanted = normalized(title)
        func search(_ menu: NSMenu) -> Bool {
            menu.update()
            for (i, item) in menu.items.enumerated() {
                if let sub = item.submenu, search(sub) { return true }
                if normalized(item.title) == wanted, item.isEnabled, item.action != nil {
                    menu.performActionForItem(at: i)
                    return true
                }
            }
            return false
        }
        return NSApp.mainMenu.map(search) ?? false
    }

    /// What an Option chord types on the current keyboard layout, like a real key event:
    /// "ß" for ⌥S, and "" for a dead key such as ⌥E, which input methods turn into a
    /// composition. Nil when the layout can't be read.
    static func layoutCharacters(_ code: UInt16, shift: Bool) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { bytes -> String? in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var dead: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 8)
            // Carbon modifier bits, shifted right by 8: optionKey (0x800) and shiftKey (0x200).
            let mods = UInt32((0x800 | (shift ? 0x200 : 0)) >> 8)
            let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), mods, UInt32(LMGetKbdType()),
                                        0, &dead, chars.count, &length, &chars)
            guard status == noErr else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
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
        default:
            // US layout: what Shift makes of punctuation and digits (":" from ";", ...).
            let shifted: [String: String] = [
                "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
                "-": "_", "=": "+", "[": "{", "]": "}", "\\": "|", ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?", "`": "~",
            ]
            chars = mods.contains(.alt) ? (Self.layoutCharacters(code, shift: mods.contains(.shift)) ?? name)
                : mods.contains(.shift) ? (shifted[name] ?? name.uppercased()) : name
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
        refreshGroupBars()
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

    func terminal(_ view: TerminalView, notifyTitle title: String, body: String) {
        // OSC 9 has no title. The body then reads as the headline; clicking still finds the tile.
        hud.notifications.post(.info, title: title, body, source: view.clientID)
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

    func browserSurfaceShouldTakeNavigationFocus(_ s: BrowserSurface) -> Bool {
        wm.focused == s.clientID
    }

    func browserSurfaceTitleDidChange(_ s: BrowserSurface) {
        surfaceTitleDidChange(s)
    }

    /// Refreshes the bar and tab strips after a surface's title changed.
    func surfaceTitleDidChange(_ s: Surface) {
        refreshGroupBars()
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
    static let hyprmuxReloadConfig = Notification.Name("hyprmuxReloadConfig")
}
