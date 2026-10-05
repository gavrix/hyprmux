import AppKit
import ChromiumBridge
import HyprmuxCore

/// Where the session is saved. HYPRMUX_SESSION moves it (a test instance must not
/// overwrite the real one).
enum SessionStore {
    static var path: String {
        if let p = ProcessInfo.processInfo.environment["HYPRMUX_SESSION"], !p.isEmpty { return p }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hyprmux/session.json").path
    }

    /// The session from the launch before this one, kept in case a restore goes wrong.
    static var previousPath: String {
        ((path as NSString).deletingPathExtension) + "-previous.json"
    }

    static func load() -> SessionState? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        do {
            return try SessionState.decode(data)
        } catch {
            log.error("session: can't read \(path, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    static func save(_ s: SessionState) {
        do {
            let dir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try s.encoded().write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            log.error("session: can't write \(path, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Copies the last session aside before this launch starts overwriting it.
    static func keepPrevious() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return }
        try? fm.removeItem(atPath: previousPath)
        try? fm.copyItem(atPath: path, toPath: previousPath)
    }
}

extension Compositor {
    // MARK: Saving

    /// Saves shortly after layout changes, every 30 s (directories and foreground programs
    /// change without a layout change), and on quit.
    func startSessionSaving() {
        SessionStore.keepPrevious()
        sessionTimer?.invalidate()
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.saveSession()
        }
    }

    func scheduleSessionSave() {
        guard sessionSavingEnabled else { return }
        sessionSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveSession() }
        sessionSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// Writes the session now. On quit this runs before the shells close, so foreground
    /// programs can still be read.
    func saveSession() {
        guard sessionSavingEnabled else { return }
        sessionSaveWork?.cancel()
        sessionSaveWork = nil
        SessionStore.save(wm.exportSession { [weak self] id in self?.sessionTile(id, forLayout: false) })
    }

    /// What a client's surface needs to come back. For a layout, an agent is kept as its
    /// kind only, so loading the layout starts a new session instead of reopening this one.
    func sessionTile(_ id: ClientID, forLayout: Bool) -> SessionTile? {
        guard let surface = views[id]?.surface else { return nil }
        let title = surface.title.isEmpty ? nil : surface.title
        switch surface {
        case let t as TerminalView:
            var tile = SessionTile(kind: "terminal", title: title)
            let fg = t.foregroundPID
            tile.cwd = t.pwd ?? ProcessInspector.cwd(fg)
            if let r = resumeReports[id], ProcessInspector.isRunning(r.pid, inGroup: fg),
               r.file.map({ FileManager.default.fileExists(atPath: $0) }) ?? true {
                // An agent still running in this terminal's foreground.
                tile.agent = SessionAgent(kind: r.kind, session: forLayout ? nil : r.session)
                if let c = r.cwd { tile.cwd = c }
            } else if let argv = ProcessInspector.argv(fg),
                      let cmd = RestorePolicy.programCommand(argv: argv, typed: t.title, settings: config.session) {
                tile.command = cmd
                tile.cwd = ProcessInspector.cwd(fg) ?? tile.cwd
            }
            return tile
        case let b as BrowserSurface:
            var tile = SessionTile(kind: "web", title: title)
            if let u = b.restorableURL, !u.hasPrefix("about:"), !u.hasPrefix("data:") { tile.url = u }
            return tile
        case let app as ClientSurface:
            // Only launched apps can be relaunched; a client that connected on its own can't.
            // Apps from the catalog come back by id.
            if let entry = app.appEntry {
                return SessionTile(kind: "app", title: title, restoreToken: forLayout ? nil : app.restoreToken,
                                   appEntry: entry, appArgs: app.entryArgs.isEmpty ? nil : app.entryArgs)
            }
            guard let launch = app.launchArgument else { return nil }
            return SessionTile(kind: "app", title: title, app: launch, restoreToken: forLayout ? nil : app.restoreToken)
        default:
            return nil
        }
    }

    // MARK: Restoring

    /// Rebuilds the saved session. Returns false when there's nothing to restore (off, no
    /// file, or no tiles), so startup runs as usual.
    func restoreSession() -> Bool {
        defer { sessionSavingEnabled = true }
        guard config.session.enabled, let s = SessionStore.load(), !s.workspaces.isEmpty else { return false }
        let made = wm.restoreSession(s) { [weak self] tile in self?.restoreTile(tile) }
        guard !made.isEmpty else { return false }
        log.info("session: restored \(made.count) windows")
        apply(animated: false)
        return true
    }

    /// Creates a tile's surface and view. Nil skips it (an app tile with nothing to relaunch).
    func restoreTile(_ t: SessionTile) -> ClientID? {
        switch t.kind {
        case "web":
            let web = makeWeb(t.url ?? "")
            adopt(web)
            return web.clientID
        case "app":
            guard let app = restoreAppTile(t) else { return nil }
            adopt(app)
            return app.clientID
        default:
            // Terminals, and anything unknown: a shell, in its directory, maybe running something.
            var opts = SurfaceOptions()
            if let c = t.cwd.map({ ($0 as NSString).expandingTildeInPath }) {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: c, isDirectory: &isDir), isDir.boolValue { opts.workingDirectory = c }
            }
            let command = t.agent.flatMap { RestorePolicy.resumeCommand($0, settings: config.session) } ?? t.command
            if let command, !command.isEmpty { opts.initialInput = command + "\n" }
            guard let term = makeTerminal(opts) else { return nil }
            adopt(term)
            return term.clientID
        }
    }
}
