import AppKit
import HyprmuxClientProtocol
import HyprmuxCore

/// Client apps (docs/CLIENT_PROTOCOL.md): launching them into reserved tiles,
/// restoring them, and giving unsolicited toplevels a tile of their own.
extension Compositor: ClientServerHost {
    /// `message` is for developers: `hyprmuxctl` prints it. Users see `notice`, or
    /// "Couldn't open NAME." (`launchFailureNotice`).
    struct AppLaunchError: LocalizedError {
        let message: String
        var notice: String?
        var errorDescription: String? { message }
    }

    /// What a user sees when an app doesn't open. The UI never explains why
    /// (docs/APPS.md); the reason goes to the log, and for adapters to
    /// `hyprmuxctl adapters` and the adapter log.
    func launchFailureNotice(_ error: Error, name: String, restoring: Bool = false) -> String {
        log.warning("app \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        if let notice = (error as? AppLaunchError)?.notice { return notice }
        return restoring ? "Couldn't reopen \(name)." : "Couldn't open \(name)."
    }

    /// How long a reserved tile waits for its client's toplevel.
    static let appConnectTimeout: TimeInterval = 20
    static let appRestoreTimeout: TimeInterval = 40
    /// A launched process that is still running keeps its tiles this long. Large apps
    /// (a debug Zed build) take longer than `appConnectTimeout` to open a window.
    static let appRunningTimeout: TimeInterval = 120

    func startClientServer() {
        clientServer.host = self
        clientServer.start()
    }

    /// `new-surface --type app -- TARGET [ARGS...]`, with shell quoting. TARGET is an
    /// executable, an `.app`, a `.hmapp`, or a bundle identifier. An app that isn't a client
    /// itself runs through the adapter that matches it (Compositor+Adapters). Returns the
    /// reserved tile, not yet managed.
    func makeApp(_ argument: String) throws -> ClientSurface {
        let command = try resolveApp(argument)
        let tile = ClientSurface(id: allocateID(), launchToken: nil, label: command.label, launchArgument: argument)
        tile.onClose = { [weak self] t in self?.removeClient(t.clientID) }
        try launch(command, argument: argument, into: [tile], timeout: Self.appConnectTimeout)
        return tile
    }

    struct AppCommand {
        var executable: URL?
        var bundle: URL?
        var arguments: [String]
        var label: String
        /// The adapter lifting the app, when it doesn't speak the protocol itself.
        var adapterID: String?
        /// The app an adapter lifts.
        var app: String?
        /// The `.hmapp` it came from, when launched by id (`launch`, the launcher, a session).
        var entry: String?
        var entryArgs: [String] = []
    }

    func resolveApp(_ argument: String) throws -> AppCommand {
        guard var words = shellWords(argument) else { throw AppLaunchError(message: "app: unbalanced quotes in \(argument)") }
        guard !words.isEmpty else { throw AppLaunchError(message: "app: name an executable, an .app, or a bundle id") }
        let target = (words.removeFirst() as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: target, isDirectory: &isDirectory)
        let bundle: URL? = exists
            ? (isDirectory.boolValue ? URL(fileURLWithPath: target) : nil)
            : NSWorkspace.shared.urlForApplication(withBundleIdentifier: target)
        guard exists || bundle != nil else { throw AppLaunchError(message: "app: no executable, .app, or bundle id \(target)") }
        if let bundle, bundle.pathExtension == HMApp.pathExtension {
            switch HMApp.load(bundle.path, source: AppRuntime.source(of: bundle.path)) {
            case .success(let app): return try appCommand(for: app, args: words)
            case .failure(let e): throw AppLaunchError(message: "app: \(bundle.path): \(e.message)")
            }
        }
        let label = bundle?.deletingPathExtension().lastPathComponent ?? (target as NSString).lastPathComponent
        if let bundle, let adapter = adapter(for: bundle), let exe = adapter.executable {
            let args = AdapterManifest.expand(adapter.manifest.args, app: bundle.path, args: words)
            return AppCommand(executable: URL(fileURLWithPath: exe), bundle: nil, arguments: args, label: label,
                              adapterID: adapter.id, app: bundle.path)
        }
        return bundle.map { AppCommand(executable: nil, bundle: $0, arguments: words, label: label) }
            ?? AppCommand(executable: URL(fileURLWithPath: target), bundle: nil, arguments: words, label: label)
    }

    /// An app that speaks the protocol itself says so in its Info.plist.
    static func isClient(_ bundle: URL) -> Bool {
        (Bundle(url: bundle)?.object(forInfoDictionaryKey: "HyprmuxClient") as? Bool) == true
    }

    /// Starts `command` with a new launch token that `tiles` wait on. `restoring` tiles
    /// come from a session or a layout, which changes the notice when they fail.
    func launch(_ command: AppCommand, argument: String, into tiles: [ClientSurface], timeout: TimeInterval,
                restoring: Bool = false) throws {
        let token = UUID().uuidString
        for t in tiles { t.setLaunchToken(token) }
        clientServer.reserve(tiles, token: token,
                             launch: .init(argument: argument, entry: command.entry, entryArgs: command.entryArgs))
        let env = [HMProtocol.launchTokenVariable: token, HMProtocol.instanceVariable: clientServer.instance]
        let label = command.label
        var launched: Process?

        if let bundle = command.bundle {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.arguments = command.arguments
            cfg.environment = env
            cfg.createsNewApplicationInstance = true
            cfg.activates = false
            cfg.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: bundle, configuration: cfg) { [weak self] _, error in
                guard let error else { return }
                DispatchQueue.main.async {
                    self?.appLaunchFailed(token: token, label: label, error.localizedDescription,
                                          notice: restoring ? "Couldn't reopen \(label)." : "Couldn't open \(label).")
                }
            }
        } else if let exe = command.executable {
            let p = Process()
            p.executableURL = exe
            p.arguments = command.arguments
            p.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
            p.standardOutput = FileHandle.nullDevice
            // Keep the end of stderr: when the process exits before connecting, its last
            // line says why (a locked-down Electron app, a missing broker, ...).
            let err = Pipe()
            p.standardError = err
            let tail = StderrTail()
            var instance: AdapterInstance?
            // Adapters log to a file too: their stderr is the only way to see inside one.
            let logPath = command.adapterID.map { AdapterRuntime.newLogPath(adapter: $0, label: label) }
            let log = logPath.flatMap { path -> FileHandle? in
                FileManager.default.createFile(atPath: path, contents: nil)
                return FileHandle(forWritingAtPath: path)
            }
            err.fileHandleForReading.readabilityHandler = { h in
                let data = h.availableData
                if data.isEmpty {
                    h.readabilityHandler = nil
                    try? log?.close()
                } else {
                    tail.append(data)
                    try? log?.write(contentsOf: data)
                }
            }
            p.terminationHandler = { [weak self] proc in
                DispatchQueue.main.async {
                    if let i = instance {
                        i.endedAt = Date()
                        i.exitStatus = proc.terminationStatus
                        i.lastError = tail.lastLine
                        self?.adapters.ended(i)
                    }
                    guard let self, !self.clientServer.reservedTiles(token).isEmpty else { return }
                    let why = tail.lastLine ?? "exited with status \(proc.terminationStatus)"
                    self.appLaunchFailed(token: token, label: label, why,
                                         notice: restoring ? "Couldn't reopen \(label)." : "Couldn't open \(label).")
                }
            }
            do { try p.run() } catch {
                _ = clientServer.cancelReservation(token)
                if let a = command.adapterID {
                    let i = adapters.started(adapter: a, app: command.app ?? argument, label: label, pid: 0, token: token)
                    i.failure = error.localizedDescription
                    i.endedAt = Date()
                    adapters.ended(i)
                }
                throw AppLaunchError(message: "app: \(error.localizedDescription)")
            }
            launched = p
            if let a = command.adapterID {
                instance = adapters.started(adapter: a, app: command.app ?? argument, label: label,
                                            pid: p.processIdentifier, token: token)
                instance?.logPath = logPath
            }
        }

        clientServer.warnIfUnavailable()
        // Give up after `timeout`, unless the process Hyprmux started is still running:
        // then keep waiting, up to `appRunningTimeout`. Its exit fails the launch sooner.
        let started = Date()
        func check(after delay: TimeInterval) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.clientServer.reservedTiles(token).isEmpty else { return }
                if let launched, launched.isRunning, Date().timeIntervalSince(started) < Self.appRunningTimeout {
                    check(after: 5)
                    return
                }
                self.appLaunchFailed(token: token, label: label,
                                     "no window within \(Int(Date().timeIntervalSince(started))) s",
                                     notice: restoring ? "Couldn't reopen \(label)." : "\(label) didn't open.")
            }
        }
        check(after: timeout)
    }

    /// `reason` is for developers (the log); `notice` is what the user sees.
    private func appLaunchFailed(token: String, label: String, _ reason: String, notice: String) {
        let tiles = clientServer.cancelReservation(token)
        guard !tiles.isEmpty else { return }
        log.warning("app \(label, privacy: .public) didn't open: \(reason, privacy: .public)")
        flash(notice)
        for t in tiles { t.clientLeft() }
    }

    // MARK: Session restore

    /// A saved app tile: it waits, with its restore token, for a relaunch. Every tile
    /// saved from one launch is relaunched once, on the next run-loop turn, after the
    /// whole session (or layout) has made its tiles.
    func restoreAppTile(_ t: SessionTile) -> ClientSurface? {
        let entry = t.appEntry.flatMap { $0.isEmpty ? nil : $0 }
        let app = t.app.flatMap { $0.isEmpty ? nil : $0 }
        guard entry != nil || app != nil else { return nil }
        let tile = ClientSurface(id: allocateID(), launchToken: nil, label: t.title ?? "app",
                                 launchArgument: entry == nil ? app : nil, restoreToken: t.restoreToken)
        tile.appEntry = entry
        tile.entryArgs = t.appArgs ?? []
        tile.onClose = { [weak self] s in self?.removeClient(s.clientID) }
        if pendingAppRestores.isEmpty {
            DispatchQueue.main.async { [weak self] in self?.relaunchRestoredApps() }
        }
        pendingAppRestores.append(tile)
        return tile
    }

    private func relaunchRestoredApps() {
        let tiles = pendingAppRestores
        pendingAppRestores.removeAll()
        var groups: [String: [ClientSurface]] = [:]
        var order: [String] = []
        // Tiles from one launch share an entry and arguments, or a launch argument.
        for t in tiles {
            let key: String
            if let entry = t.appEntry {
                key = "entry:" + ([entry] + t.entryArgs).map(shellQuote).joined(separator: " ")
            } else if let app = t.launchArgument {
                key = app
            } else {
                continue
            }
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(t)
        }
        for key in order {
            let group = groups[key]!
            do {
                if let entry = group[0].appEntry {
                    // Restores by id: the app may have moved, or been customized since.
                    guard let app = apps.catalog.app(id: entry) else {
                        throw AppLaunchError(message: "no app \(entry)")
                    }
                    let args = group[0].entryArgs
                    try launch(try entryCommand(for: app, args: args), argument: Self.entryArgument(app, args),
                               into: group, timeout: Self.appRestoreTimeout, restoring: true)
                } else {
                    try launch(try resolveApp(key), argument: key, into: group, timeout: Self.appRestoreTimeout,
                               restoring: true)
                }
            } catch {
                // The app's name when the catalog still knows it, else the saved window title.
                let name = group[0].appEntry.flatMap { apps.catalog.app(id: $0)?.name } ?? group[0].title
                flash(launchFailureNotice(error, name: name, restoring: true))
                for t in group { t.clientLeft() }
            }
        }
    }

    // MARK: ClientServerHost

    func clientServer(_ server: ClientServer, newSurfaceFor appID: String, name: String) -> ClientSurface {
        let tile = ClientSurface(id: allocateID(), launchToken: nil, label: name.isEmpty ? appID : name)
        tile.onClose = { [weak self] t in self?.removeClient(t.clientID) }
        manage(tile)
        return tile
    }

    func clientServer(_ server: ClientServer, titleChanged surface: ClientSurface) {
        surfaceTitleDidChange(surface)
    }

    func clientServerUnavailable(_ server: ClientServer) {
        explainBrokerUnavailable()
    }
}

/// The last few KB a launched process wrote to stderr.
private final class StderrTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        if data.count > 4096 { data = data.suffix(4096) }
    }

    var lastLine: String? {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline).last.map { String($0).trimmingCharacters(in: .whitespaces) }
    }
}
