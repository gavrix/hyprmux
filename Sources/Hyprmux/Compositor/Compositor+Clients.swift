import AppKit
import HyprmuxClientProtocol
import HyprmuxCore

/// Client apps (docs/CLIENT_PROTOCOL.md): launching them into reserved tiles,
/// restoring them, and giving unsolicited toplevels a tile of their own.
extension Compositor: ClientServerHost {
    struct AppLaunchError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// How long a reserved tile waits for its client's toplevel.
    static let appConnectTimeout: TimeInterval = 20
    static let appRestoreTimeout: TimeInterval = 40

    func startClientServer() {
        clientServer.host = self
        clientServer.start()
    }

    /// `new-surface --type app -- TARGET [ARGS...]`, with shell quoting. TARGET is an
    /// executable, an `.app`, or a bundle identifier. An app that isn't a client itself runs
    /// through the adapter that matches it (Compositor+Adapters). Returns the reserved tile,
    /// not yet managed.
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
        var adapter: AdapterEntry?
        /// The app an adapter lifts.
        var app: String?
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
        let label = bundle?.deletingPathExtension().lastPathComponent ?? (target as NSString).lastPathComponent
        if let bundle, let adapter = adapter(for: bundle), let exe = adapter.executable {
            let args = AdapterManifest.expand(adapter.manifest.args, app: bundle.path, args: words)
            return AppCommand(executable: URL(fileURLWithPath: exe), bundle: nil, arguments: args, label: label,
                              adapter: adapter, app: bundle.path)
        }
        return bundle.map { AppCommand(executable: nil, bundle: $0, arguments: words, label: label) }
            ?? AppCommand(executable: URL(fileURLWithPath: target), bundle: nil, arguments: words, label: label)
    }

    /// An app that speaks the protocol itself says so in its Info.plist.
    static func isClient(_ bundle: URL) -> Bool {
        (Bundle(url: bundle)?.object(forInfoDictionaryKey: "HyprmuxClient") as? Bool) == true
    }

    /// Starts `command` with a new launch token that `tiles` wait on.
    private func launch(_ command: AppCommand, argument: String, into tiles: [ClientSurface], timeout: TimeInterval) throws {
        let token = UUID().uuidString
        for t in tiles { t.setLaunchToken(token) }
        clientServer.reserve(tiles, token: token, launch: argument)
        let env = [HMProtocol.launchTokenVariable: token, HMProtocol.instanceVariable: clientServer.instance]
        let label = command.label

        if let bundle = command.bundle {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.arguments = command.arguments
            cfg.environment = env
            cfg.createsNewApplicationInstance = true
            cfg.activates = false
            cfg.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: bundle, configuration: cfg) { [weak self] _, error in
                guard let error else { return }
                DispatchQueue.main.async { self?.appLaunchFailed(token: token, "\(label): \(error.localizedDescription)") }
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
            let logPath = command.adapter.map { AdapterRuntime.newLogPath(adapter: $0.id, label: label) }
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
                    self.appLaunchFailed(token: token, "\(label): \(why)")
                }
            }
            do { try p.run() } catch {
                _ = clientServer.cancelReservation(token)
                if let a = command.adapter {
                    let i = adapters.started(adapter: a, app: command.app ?? argument, label: label, pid: 0, token: token)
                    i.failure = error.localizedDescription
                    i.endedAt = Date()
                    adapters.ended(i)
                }
                throw AppLaunchError(message: "app: \(error.localizedDescription)")
            }
            if let a = command.adapter {
                instance = adapters.started(adapter: a, app: command.app ?? argument, label: label,
                                            pid: p.processIdentifier, token: token)
                instance?.logPath = logPath
            }
        }

        clientServer.warnIfUnavailable()
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, !self.clientServer.reservedTiles(token).isEmpty else { return }
            self.appLaunchFailed(token: token, "\(label) didn't connect to Hyprmux.")
        }
    }

    private func appLaunchFailed(token: String, _ message: String) {
        let tiles = clientServer.cancelReservation(token)
        guard !tiles.isEmpty else { return }
        flash(message)
        for t in tiles { t.clientLeft() }
    }

    // MARK: Session restore

    /// A saved app tile: it waits, with its restore token, for a relaunch. Every tile
    /// saved from one launch is relaunched once, on the next run-loop turn, after the
    /// whole session (or layout) has made its tiles.
    func restoreAppTile(_ t: SessionTile) -> ClientSurface? {
        guard let app = t.app, !app.isEmpty else { return nil }
        let tile = ClientSurface(id: allocateID(), launchToken: nil, label: t.title ?? "app",
                                 launchArgument: app, restoreToken: t.restoreToken)
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
        for t in tiles {
            guard let app = t.launchArgument else { continue }
            if groups[app] == nil { order.append(app) }
            groups[app, default: []].append(t)
        }
        for app in order {
            let group = groups[app]!
            do {
                try launch(try resolveApp(app), argument: app, into: group, timeout: Self.appRestoreTimeout)
            } catch {
                flash("Couldn't restore \(group[0].title): \(error.localizedDescription)")
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

    func clientServer(_ server: ClientServer, notice message: String) {
        flash(message)
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
