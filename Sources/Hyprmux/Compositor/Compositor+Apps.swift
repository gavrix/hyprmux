import AppKit
import HyprmuxCore
import Security

/// The app catalog at run time (docs/APPS.md): the `.hmapp`s Hyprmux can open, the
/// background generation that keeps the generated ones current, recent launches, and
/// trust answers for downloaded apps that carry their own code.
final class AppRuntime {
    private(set) var catalog = AppCatalog()
    /// The last generation, for `hyprmuxctl apps --json`.
    private(set) var report: AppGenerator.Report?
    private(set) var generating = false
    /// A refresh asked for while one runs: it runs again after, with this registry.
    private var again: AdapterRegistry?
    private var waiting: [() -> Void] = []
    /// App id → last launch, for the launcher's order.
    private(set) var recent: [String: Date] = [:]
    private var trust: [TrustAnswer] = []
    private var icons: [String: NSImage] = [:]
    private let queue = DispatchQueue(label: "hyprmux-apps", qos: .utility)

    struct TrustAnswer: Codable, Equatable {
        var path: String
        var modified: Date
        var allowed: Bool
    }

    init() {
        recent = Self.read([String: Date].self, Self.recentFile) ?? [:]
        trust = Self.read([TrustAnswer].self, Self.trustFile) ?? []
    }

    // MARK: Folders

    static var instanceName: String {
        ProcessInfo.processInfo.environment["HYPRMUX_INSTANCE"].flatMap { $0.isEmpty ? nil : $0 } ?? "default"
    }

    /// ~/Library/Application Support/Hyprmux/Apps, per HYPRMUX_INSTANCE so a test copy
    /// keeps its own. Hyprmux owns everything generated here.
    static var generatedDirectory: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hyprmux/Apps")
        return (instanceName == "default" ? base : base.appendingPathComponent(instanceName)).path
    }

    /// `apps/` next to the config file, normally ~/.config/hyprmux/apps. The user's.
    static var installedDirectory: String {
        ((AppDelegate.configPath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("apps")
    }

    /// First-party apps in the bundle: `Hyprmux.app/Contents/Resources/apps`.
    static var builtinDirectory: String? {
        Bundle.main.resourceURL?.appendingPathComponent("apps").path
    }

    /// Lowest precedence first: an installed app replaces a generated or builtin one.
    static var directories: [(HMAppSource, String)] {
        var dirs: [(HMAppSource, String)] = []
        if let builtin = builtinDirectory { dirs.append((.builtin, builtin)) }
        dirs.append((.generated, generatedDirectory))
        dirs.append((.installed, installedDirectory))
        return dirs
    }

    /// A `.hmapp` opened by path: builtin or generated if it lives in their folder.
    static func source(of path: String) -> HMAppSource {
        let p = (path as NSString).standardizingPath
        func inside(_ dir: String) -> Bool { p.hasPrefix((dir as NSString).standardizingPath + "/") }
        if let b = builtinDirectory, inside(b) { return .builtin }
        return inside(generatedDirectory) ? .generated : .installed
    }

    static var recentFile: String { (generatedDirectory as NSString).appendingPathComponent("recent.json") }
    static var trustFile: String { (generatedDirectory as NSString).appendingPathComponent("trust.json") }

    // MARK: Catalog

    func reloadCatalog() {
        catalog = AppCatalog.load(directories: Self.directories)
        icons.removeAll()
        for e in catalog.errors { log.warning("app \(e.path, privacy: .public): \(e.message, privacy: .public)") }
    }

    /// Regenerates in the background, then reloads the catalog on main. `completion` runs
    /// on main once the catalog includes this refresh.
    func refresh(registry: AdapterRegistry, completion: (() -> Void)? = nil) {
        if let completion { waiting.append(completion) }
        guard !generating else {
            again = registry
            return
        }
        generating = true
        let dir = Self.generatedDirectory
        let home = NSHomeDirectory()
        let directories = Self.directories
        queue.async { [weak self] in
            let scanned = AppScanner.scan(AppScanner.defaultFolders(home: home))
            let report = AppGenerator.generate(apps: scanned, registry: registry, directory: dir,
                                               probe: Self.probe, icon: { Self.pngIcon(forFile: $0.path) })
            let catalog = AppCatalog.load(directories: directories)
            DispatchQueue.main.async { self?.finish(report, catalog) }
        }
    }

    private func finish(_ report: AppGenerator.Report, _ catalog: AppCatalog) {
        generating = false
        self.report = report
        self.catalog = catalog
        icons.removeAll()
        log.info("apps: \(report.apps.count) generated, \(report.written.count) written, \(report.deleted.count) deleted, \(report.probed) probed")
        for e in report.errors { log.warning("apps: \(e, privacy: .public)") }
        if let r = again {
            again = nil
            refresh(registry: r)
            return
        }
        let done = waiting
        waiting.removeAll()
        for d in done { d() }
    }

    private static func probe(_ adapter: AdapterEntry, _ app: ScannedApp) -> AppGenerator.ProbeOutcome {
        guard let exe = adapter.executable, let probe = adapter.manifest.probe else { return .init(ok: true) }
        let r = Compositor.runProbe(executable: exe, arguments: AdapterManifest.expand(probe, app: app.path, args: []),
                                    adapter: adapter.id)
        return .init(ok: r.ok, reason: r.reason)
    }

    /// The Finder icon of a file, as a 256 px PNG.
    static func pngIcon(forFile path: String, size: Int = 256) -> Data? {
        let image = NSWorkspace.shared.icon(forFile: path)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// The launcher's icon for an app: its `icon.png`, else the target's Finder icon.
    func icon(for app: HMApp) -> NSImage {
        if let cached = icons[app.path] { return cached }
        let target = app.manifest.app ?? app.manifest.exec.flatMap { $0.hasPrefix("/") ? $0 : nil } ?? app.path
        let image = NSImage(contentsOfFile: app.iconPath) ?? NSWorkspace.shared.icon(forFile: target)
        icons[app.path] = image
        return image
    }

    // MARK: Recent launches

    func recordLaunch(_ id: String) {
        recent[id] = Date()
        Self.write(recent, Self.recentFile)
    }

    // MARK: Trust

    func trustAnswer(path: String, modified: Date) -> Bool? {
        trust.first { $0.path == path && $0.modified == modified }?.allowed
    }

    func remember(path: String, modified: Date, allowed: Bool) {
        trust.removeAll { $0.path == path }
        trust.append(TrustAnswer(path: path, modified: modified, allowed: allowed))
        Self.write(trust, Self.trustFile)
    }

    // MARK: Files

    private static func read<T: Decodable>(_ type: T.Type, _ path: String) -> T? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(type, from: data)
    }

    private static func write<T: Encodable>(_ value: T, _ path: String) {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? e.encode(value) else { return }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

extension Compositor {
    func loadApps() {
        apps.reloadCatalog()
    }

    /// Regenerates the generated apps in the background (startup, reload, the launcher).
    func refreshApps(completion: (() -> Void)? = nil) {
        apps.refresh(registry: adapters.registry, completion: completion)
    }

    // MARK: Launching

    /// The command for a `.hmapp`: its executable, or the `.app` it opens. A downloaded
    /// app that carries its own executable must pass the trust check first.
    func appCommand(for app: HMApp, args: [String]) throws -> AppCommand {
        let m = app.manifest
        let c: HMApp.Command
        switch app.command(args: args, binDirectories: AdapterRuntime.binDirectories) {
        case .success(let v): c = v
        case .failure(let e): throw AppLaunchError(message: e.message)
        }
        let adapter = m.kind == .adapter ? m.adapter : nil
        let single = m.instances == .single ? m.id : nil
        if let exe = c.executable {
            try checkTrust(app, executable: exe)
            return AppCommand(executable: URL(fileURLWithPath: exe), bundle: nil, arguments: c.arguments, label: m.name,
                              adapterID: adapter, app: m.app, single: single)
        }
        return AppCommand(executable: nil, bundle: c.app.map { URL(fileURLWithPath: $0) }, arguments: c.arguments,
                          label: m.name, adapterID: nil, app: m.app, single: single)
    }

    /// `appCommand`, marked so the session restores the tiles by app id.
    func entryCommand(for app: HMApp, args: [String]) throws -> AppCommand {
        var c = try appCommand(for: app, args: args)
        c.entry = app.id
        c.entryArgs = args
        return c
    }

    /// What a launch by id shows as its launch text (`clientServer` keeps it per token).
    static func entryArgument(_ app: HMApp, _ args: [String]) -> String {
        ([app.id] + args).map(shellQuote).joined(separator: " ")
    }

    /// Launches a catalog app. Its window gets a tile when the app answers.
    @discardableResult
    func launchApp(_ app: HMApp, args: [String], _ request: LaunchRequest) throws -> AppLaunch {
        let command = try entryCommand(for: app, args: args)
        let l = try startLaunch(command, argument: Self.entryArgument(app, args), request: request)
        apps.recordLaunch(app.id)
        return l
    }

    /// A person launched it: the picker shows "Opening NAME…", then any offer.
    func interactiveLaunch(back: (() -> Void)? = nil) -> LaunchRequest {
        LaunchRequest(focus: true, interactive: true, back: back)
    }

    /// `launch, NAME|ID [ARGS]` from a bind: the whole text names an app, or its first
    /// shell word does and the rest are arguments.
    func launchFromBind(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else {
            presentAppLauncher()
            return
        }
        var app = apps.catalog.find(t)
        var args: [String] = []
        if app == nil, let words = shellWords(t), let first = words.first {
            app = apps.catalog.find(first)
            args = Array(words.dropFirst())
        }
        guard let app else {
            flash("No app named \(t).")
            return
        }
        do {
            try launchApp(app, args: args, interactiveLaunch())
        } catch {
            flash(launchFailureNotice(error, name: app.name))
        }
    }

    /// A `.hmapp` opened in Finder (or with `open`): launch it into a tile.
    func openHMApp(at path: String) {
        do {
            try launchTarget(shellQuote(path), interactiveLaunch())
        } catch {
            let name = (try? HMApp.load(path, source: AppRuntime.source(of: path)).get().name)
                ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            flash(launchFailureNotice(error, name: name))
        }
    }

    // MARK: Trust

    /// Decision 8 of docs/APPS.md: code that came inside a downloaded `.hmapp` runs only
    /// when it's signed (by a certificate Apple issued), or when the user said yes once.
    private func checkTrust(_ app: HMApp, executable: String) throws {
        guard app.source == .installed, app.carriesExecutable(executable),
              Self.isQuarantined(app.path) || Self.isQuarantined(executable) else { return }
        if Self.hasValidSignature(executable) { return }
        let modified = ((try? FileManager.default.attributesOfItem(atPath: executable))?[.modificationDate] as? Date) ?? .distantPast
        if let answer = apps.trustAnswer(path: executable, modified: modified) {
            guard answer else {
                throw AppLaunchError(message: "\(app.name): not opened, you chose not to trust it",
                                     notice: "Didn't open \(app.name): you chose not to trust it.")
            }
            return
        }
        let alert = NSAlert()
        alert.messageText = "Open “\(app.name)”?"
        alert.informativeText = """
            \((app.path as NSString).lastPathComponent) was downloaded and carries its own program, \
            which no identified developer signed. Open it only if you trust where it came from.
            """
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Don't Open")
        let allowed = alert.runModal() == .alertFirstButtonReturn
        apps.remember(path: executable, modified: modified, allowed: allowed)
        guard allowed else { throw AppLaunchError(message: "\(app.name): not opened", notice: "Didn't open \(app.name).") }
    }

    static func isQuarantined(_ path: String) -> Bool {
        getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
    }

    /// A valid signature from a certificate Apple issued (Developer ID, Apple Development).
    static func hasValidSignature(_ path: String) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else {
            return false
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple generic" as CFString, [], &requirement) == errSecSuccess else {
            return false
        }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess
    }

    // MARK: Launcher

    /// `picker, apps`: every app Hyprmux can open, recent first. Enter opens one in a new
    /// tile on the current workspace.
    func presentAppLauncher() {
        // Cheap: a rescan, and probes only for new app versions. The picker shows the
        // catalog as it is now.
        refreshApps()
        let ordered = apps.catalog.launcherOrder(recent: apps.recent)
        let items = ordered.map { PickerItem(id: $0.id, title: $0.name) }
        var picker = Picker(title: "apps", items: items, searchesDetail: false, maxVisible: config.hud.pickerMaxRows)
        picker.emptyText = "No apps"
        var icons: [String: NSImage] = [:]
        for a in ordered { icons[a.id] = apps.icon(for: a) }
        hud.picker.present(picker, icons: icons) { [weak self] r in
            guard let self, case .item(let id)? = r else { return }
            guard let app = self.apps.catalog.app(id: id) else { return }
            do {
                // Escape while it opens comes back to the launcher.
                try self.launchApp(app, args: [], self.interactiveLaunch { [weak self] in self?.presentAppLauncher() })
            } catch {
                self.flash(self.launchFailureNotice(error, name: app.name))
            }
        }
    }

    // MARK: hyprmuxctl apps

    func appsJSON() -> [String: Any] {
        let c = apps.catalog
        let iso = ISO8601DateFormatter()
        var o: [String: Any] = [
            "apps": c.apps.map(\.json),
            "overridden": c.overridden.map(\.json),
            "errors": c.errors.map { ["path": $0.path, "message": $0.message] },
            "directories": c.directories.map { ["source": $0.source.rawValue, "path": $0.path, "exists": $0.exists] },
            "generating": apps.generating,
            "loadedAt": iso.string(from: c.loadedAt),
            "recent": apps.recent.mapValues { iso.string(from: $0) },
        ]
        if let r = apps.report {
            o["generation"] = ["finishedAt": iso.string(from: r.finishedAt), "apps": r.apps.count, "written": r.written,
                               "deleted": r.deleted, "probed": r.probed, "skipped": r.skipped.count, "errors": r.errors]
        }
        return o
    }

    /// `apps refresh`: regenerates, and replies once the catalog has the result.
    func appsRefresh() -> IPCReply {
        let done = DispatchSemaphore(value: 0)
        refreshApps { done.signal() }
        return .background { [weak self] in
            done.wait()
            var text = "error: not ready"
            DispatchQueue.main.sync { if let self { text = self.jsonText(self.appsJSON()) } }
            return text
        }
    }

    /// `apps add NAME PATH [ARGS...]`: writes an installed `.hmapp`. An `.app` is
    /// classified like generation (native, or an adapter with its probe); anything else
    /// becomes the `exec`.
    func appsAdd(_ words: [String]) -> IPCReply {
        guard words.count >= 2 else { return .text("error: apps add: expected NAME PATH [ARGS...]") }
        let name = words[0].trimmingCharacters(in: .whitespaces)
        let path = (words[1] as NSString).expandingTildeInPath
        let extra = Array(words.dropFirst(2))
        guard !name.isEmpty else { return .text("error: apps add: the name is empty") }
        guard path.hasPrefix("/") else { return .text("error: apps add: \(path) isn't an absolute path") }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return .text("error: apps add: no such file \(path)") }
        let userArgs = extra + ["{args}"]

        guard (path as NSString).pathExtension == "app", isDir.boolValue else {
            guard !isDir.boolValue, fm.isExecutableFile(atPath: path) else {
                return .text("error: apps add: \(path) is neither an .app nor an executable")
            }
            let m = HMAppManifest(id: "user." + HMApp.slug(name), name: name, kind: .native, exec: path, args: userArgs)
            return .text(installApp(m))
        }
        guard let scanned = AppScanner.read(path) else { return .text("error: apps add: \(path) has no Info.plist") }
        let id = scanned.bundleID ?? "user." + HMApp.slug(name)
        switch AppGenerator.classify(scanned, registry: adapters.registry, fileExists: { fm.fileExists(atPath: $0) }) {
        case .none:
            return .text("error: Hyprmux can't open \(name). `hyprmuxctl adapters match \(shellQuote(path))` shows why.")
        case .native:
            let m = HMAppManifest(id: id, name: name, kind: .native, app: path, version: scanned.version, args: userArgs)
            return .text(installApp(m))
        case .adapter(let adapter):
            var m = AppGenerator.manifest(for: scanned, adapter: adapter)
            m.id = id
            m.name = name
            m.generatedBy = nil
            // The user's arguments go where the adapter splices arguments.
            let template = adapter.manifest.args
            m.args = template.contains("{args}") ? template.flatMap { $0 == "{args}" ? userArgs : [$0] } : template + extra
            guard let exe = adapter.executable, let probe = adapter.manifest.probe else { return .text(installApp(m)) }
            let probeArgs = AdapterManifest.expand(probe, app: path, args: [])
            return .background { [weak self] in
                let result = Self.runProbe(executable: exe, arguments: probeArgs, adapter: adapter.id)
                var text = "error: not ready"
                DispatchQueue.main.sync {
                    guard let self else { return }
                    self.adapters.recordProbe(app: path, result)
                    text = result.ok
                        ? self.installApp(m)
                        : "error: Hyprmux can't open \(name): \(result.reason ?? "its adapter's probe failed")"
                }
                return text
            }
        }
    }

    /// Writes an installed `.hmapp` and replies with its entry. An installed app with the
    /// same id is replaced in place.
    private func installApp(_ m: HMAppManifest) -> String {
        let dir = AppRuntime.installedDirectory
        let path = apps.catalog.apps.first { $0.id == m.id && $0.source == .installed }?.path
            ?? (dir as NSString).appendingPathComponent(HMApp.folderName(m.name))
        if FileManager.default.fileExists(atPath: path), case .success(let other) = HMApp.load(path, source: .installed), other.id != m.id {
            return "error: apps add: \(path) already holds \(other.id)"
        }
        do {
            try HMApp.write(m, to: path)
        } catch {
            return "error: apps add: \(error.localizedDescription)"
        }
        loadApps()
        guard let app = apps.catalog.app(id: m.id) else { return "error: apps add: \(path) didn't load" }
        return jsonText(app.json)
    }

    /// `launch [--window ID] NAME|ID [ARGS...]` over IPC: replies with the window's tile,
    /// like `new-surface`, once the app opens it. An app that offers several windows and
    /// no `--window` replies with the offer instead.
    func launchReply(_ words: [String], focus: Bool, window: String?) -> IPCReply {
        guard let first = words.first else { return .text("error: launch: name an app") }
        guard let app = apps.catalog.find(first) else { return .text("error: no app \(first) (hyprmuxctl apps lists them)") }
        return awaitLaunch(name: app.name) { request in
            var r = request
            r.focus = focus
            r.window = window
            try self.launchApp(app, args: Array(words.dropFirst()), r)
        }
    }

    /// Runs a launch for IPC, and replies when it ends: the tile's `surfaces` entry, the
    /// offered windows, or an error.
    func awaitLaunch(name: String, workspace: WorkspaceID? = nil, floating: Bool = false,
                     _ start: (LaunchRequest) throws -> Void) -> IPCReply {
        let done = DispatchSemaphore(value: 0)
        var outcome: AppLaunch.Outcome?
        var request = LaunchRequest(workspace: workspace, focus: false)
        request.floating = floating
        request.completion = { result in
            outcome = result
            done.signal()
        }
        do {
            try start(request)
        } catch {
            return .text("error: \(error.localizedDescription)")
        }
        return .background { [weak self] in
            _ = done.wait(timeout: .now() + Self.appRunningTimeout + 30)
            var text = "error: \(name) didn't open"
            // On main, after messages already queued: the window's title lands first.
            DispatchQueue.main.sync {
                guard let self, let outcome else { return }
                text = self.launchReplyText(outcome, name: name)
            }
            return text
        }
    }

    private func launchReplyText(_ outcome: AppLaunch.Outcome, name: String) -> String {
        switch outcome {
        case .window(let tile):
            guard let p = wm.snapshot().placement(tile.clientID) else { return "error: surface closed while opening" }
            return jsonText(clientInfo(p))
        case .offer(let windows):
            return jsonText(["app": name, "windows": windows.map { w -> [String: String] in
                var o = ["id": w.id, "title": w.title]
                if !w.detail.isEmpty { o["detail"] = w.detail }
                return o
            }])
        case .nothing:
            return "error: \(name) opened no window"
        case .failed(let why):
            return "error: \(why)"
        }
    }
}
