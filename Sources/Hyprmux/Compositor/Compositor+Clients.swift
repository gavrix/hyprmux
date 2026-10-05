import AppKit
import HyprmuxClientProtocol
import HyprmuxCore

/// Client apps (docs/CLIENT_PROTOCOL.md, section 10): launches and their answers (a
/// window, an offer, or nothing), the launch picker, restoring app tiles, and giving
/// unsolicited toplevels a tile of their own.
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

    /// How long a launch waits for the app's first answer: a window or an offer.
    static let appConnectTimeout: TimeInterval = 20
    static let appRestoreTimeout: TimeInterval = 40
    /// A launched process that is still running keeps its launch this long. Large apps
    /// (a debug Zed build) take longer than `appConnectTimeout` to open a window.
    static let appRunningTimeout: TimeInterval = 120

    func startClientServer() {
        clientServer.host = self
        clientServer.start()
    }

    /// Where a launch's window goes and who waits for it.
    struct LaunchRequest {
        /// Nil: where a new window goes when the launch starts.
        var workspace: WorkspaceID?
        var focus = true
        var floating = false
        /// A person launched it: an offer of several windows opens the picker.
        var interactive = false
        /// The offered window to open without asking.
        var window: String?
        /// Escape in the picker reopens this (the launcher).
        var back: (() -> Void)?
        var completion: ((AppLaunch.Outcome) -> Void)?
    }

    /// `new-surface --type app -- TARGET [ARGS...]`, with shell quoting. TARGET is an
    /// executable, an `.app`, a `.hmapp`, or a bundle identifier. An app that isn't a client
    /// itself runs through the adapter that matches it (Compositor+Adapters).
    @discardableResult
    func launchTarget(_ argument: String, _ request: LaunchRequest) throws -> AppLaunch {
        try startLaunch(try resolveApp(argument), argument: argument, request: request)
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
        /// The `.hmapp` id, when it runs a single process (`"instances": "single"`).
        var single: String?
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

    // MARK: Launching

    /// Starts a launch. A single-instance app that's running (or starting) gets it over
    /// its connection; otherwise a new process starts with the launch's token. No tile is
    /// made until the app answers. `reserved` tiles come from a session or a layout and
    /// wait for windows with their restore tokens.
    @discardableResult
    func startLaunch(_ command: AppCommand, argument: String, request: LaunchRequest,
                     reserved: [ClientSurface] = [], restoring: Bool = false) throws -> AppLaunch {
        let l = AppLaunch(label: command.label, argument: argument, entry: command.entry,
                          entryArgs: command.entryArgs, singleApp: command.single)
        l.workspace = request.workspace ?? wm.newWindowWorkspace
        l.focus = request.focus
        l.floating = request.floating
        l.interactive = request.interactive
        l.window = request.window
        l.back = request.back
        l.completion = request.completion
        l.reserved = reserved
        l.restoring = restoring
        for t in reserved { t.setLaunchToken(l.token) }
        clientServer.add(l)

        if let app = command.single, let running = clientServer.single(app) {
            // Still starting: its startup counts against the launch, as for a new process.
            if running.connection == nil { l.process = running.process }
            clientServer.deliver(l, to: running)
        } else {
            do {
                try spawn(command, for: l, argument: argument)
            } catch {
                clientServer.remove(l)
                throw error
            }
            if let app = command.single { clientServer.setSingle(app, .init(process: l.process, token: l.token)) }
        }

        clientServer.warnIfUnavailable()
        scheduleLaunchTimeout(l, after: restoring ? Self.appRestoreTimeout : Self.appConnectTimeout)
        if l.interactive { showLaunchPicker(l) }
        return l
    }

    /// Runs the launch's process with its token in the environment.
    private func spawn(_ command: AppCommand, for l: AppLaunch, argument: String) throws {
        let token = l.token
        let env = [HMProtocol.launchTokenVariable: token, HMProtocol.instanceVariable: clientServer.instance]
        let label = command.label

        if let bundle = command.bundle {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.arguments = command.arguments
            cfg.environment = env
            cfg.createsNewApplicationInstance = true
            cfg.activates = false
            cfg.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: bundle, configuration: cfg) { [weak self, weak l] _, error in
                guard let error else { return }
                DispatchQueue.main.async {
                    guard let self, let l else { return }
                    self.launchFailed(l, error.localizedDescription)
                }
            }
            return
        }
        guard let exe = command.executable else { return }
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
        p.terminationHandler = { [weak self, weak l] proc in
            DispatchQueue.main.async {
                if let i = instance {
                    i.endedAt = Date()
                    i.exitStatus = proc.terminationStatus
                    i.lastError = tail.lastLine
                    self?.adapters.ended(i)
                }
                self?.clientServer.processEnded(proc)
                guard let self, let l, l.pending else { return }
                self.launchFailed(l, tail.lastLine ?? "exited with status \(proc.terminationStatus)")
            }
        }
        do { try p.run() } catch {
            if let a = command.adapterID {
                let i = adapters.started(adapter: a, app: command.app ?? argument, label: label, pid: 0, token: token)
                i.failure = error.localizedDescription
                i.endedAt = Date()
                adapters.ended(i)
            }
            throw AppLaunchError(message: "app: \(error.localizedDescription)")
        }
        l.process = p
        if let a = command.adapterID {
            instance = adapters.started(adapter: a, app: command.app ?? argument, label: label,
                                        pid: p.processIdentifier, token: token)
            instance?.logPath = logPath
        }
    }

    /// Gives up after `delay`, unless the process Hyprmux started is still running: then
    /// it keeps waiting, up to `appRunningTimeout`. Its exit fails the launch sooner.
    /// Opening the picker pauses it; a pick restarts it.
    private func scheduleLaunchTimeout(_ l: AppLaunch, after delay: TimeInterval) {
        l.timerGeneration += 1
        let generation = l.timerGeneration
        let started = Date()
        func check(after delay: TimeInterval) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak l] in
                guard let self, let l, l.pending, l.timerGeneration == generation, l.state != .picking else { return }
                if let p = l.process, p.isRunning, Date().timeIntervalSince(started) < Self.appRunningTimeout {
                    check(after: 5)
                    return
                }
                self.launchFailed(l, "no window within \(Int(Date().timeIntervalSince(started))) s",
                                  notice: l.restoring ? nil : "\(l.label) didn't open.")
            }
        }
        check(after: delay)
    }

    /// `reason` is for developers (the log); the user sees `notice`, or "Couldn't open NAME."
    private func launchFailed(_ l: AppLaunch, _ reason: String, notice: String? = nil) {
        guard l.pending else { return }
        log.warning("app \(l.label, privacy: .public) didn't open: \(reason, privacy: .public)")
        flash(notice ?? (l.restoring ? "Couldn't reopen \(l.label)." : "Couldn't open \(l.label)."))
        endLaunch(l, .failed(reason))
    }

    /// Ends a launch that is still pending: closes its picker, tells the app, drops
    /// restored tiles still waiting, and answers whoever waits.
    private func endLaunch(_ l: AppLaunch, _ outcome: AppLaunch.Outcome, tellApp: Bool = true) {
        closeLaunchPicker(l)
        dropReserved(l)
        if tellApp, let c = l.connection { c.send(HMOp.launchCancel, ["launch_token": l.token]) }
        // A single-instance app that never connected won't take launches.
        if let app = l.singleApp, let s = clientServer.single(app), s.connection == nil, !(s.process?.isRunning ?? false) {
            clientServer.setSingle(app, nil)
        }
        clientServer.remove(l)
        l.finish(outcome)
    }

    private func dropReserved(_ l: AppLaunch) {
        let tiles = l.reserved
        l.reserved.removeAll()
        for t in tiles { t.clientLeft() }
    }

    /// Asks the app for an offered window.
    private func openOffered(_ l: AppLaunch, _ window: String) {
        guard let c = l.connection else { return }
        l.state = .opening
        c.send(HMOp.launchOpen, ["launch_token": l.token, "window": window])
        scheduleLaunchTimeout(l, after: Self.appConnectTimeout)
    }

    // MARK: Launch picker

    /// "Opening NAME…" until the app answers. An offer of several windows fills it.
    private func showLaunchPicker(_ l: AppLaunch) {
        let request = UUID()
        l.pickerRequest = request
        var picker = Picker(title: l.label, maxVisible: config.hud.pickerMaxRows)
        picker.emptyText = "Opening \(l.label)…"
        picker.placeholder = "type to filter"
        hud.picker.nextBack = l.back
        hud.picker.present(picker, requestID: request) { [weak self, weak l] result in
            guard let self, let l, l.pickerRequest == request else { return }
            l.pickerRequest = nil
            guard l.pending else { return }
            if case .item(let id)? = result, l.offer.contains(where: { $0.id == id }) {
                self.openOffered(l, id)
            } else {
                // Dismissed: the app hears it, and nothing opens.
                self.endLaunch(l, .nothing)
            }
        }
    }

    private func showOffer(_ l: AppLaunch) {
        l.state = .picking
        l.timerGeneration += 1
        let items = l.offer.map { PickerItem(id: $0.id, title: $0.title, detail: $0.detail) }
        if let request = l.pickerRequest, hud.picker.update(items: items, status: nil, icons: [:], requestID: request) {
            return
        }
        // The "Opening" picker is gone (another picker replaced it): show the offer anew.
        showLaunchPicker(l)
        if let request = l.pickerRequest { hud.picker.update(items: items, status: nil, icons: [:], requestID: request) }
    }

    private func closeLaunchPicker(_ l: AppLaunch) {
        guard let request = l.pickerRequest else { return }
        l.pickerRequest = nil
        hud.picker.cancel(requestID: request)
    }

    /// Places a launch's window where the launch started. It takes focus only if that
    /// workspace is still in view: a late window doesn't pull the user away.
    private func place(_ tile: ClientSurface, for l: AppLaunch) {
        let now = wm.newWindowWorkspace
        let ws = l.workspace ?? now
        wm.addClient(tile.clientID, floating: l.floating, workspace: ws == now ? nil : ws,
                     focus: l.focus && wm.isVisible(ws))
        apply(animated: true)
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
                    try startLaunch(try entryCommand(for: app, args: args), argument: Self.entryArgument(app, args),
                                    request: LaunchRequest(focus: false), reserved: group, restoring: true)
                } else {
                    try startLaunch(try resolveApp(key), argument: key, request: LaunchRequest(focus: false),
                                    reserved: group, restoring: true)
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

    func clientServer(_ server: ClientServer, newSurfaceFor appID: String, name: String, launch: AppLaunch?) -> ClientSurface {
        let tile = ClientSurface(id: allocateID(), launchToken: nil, label: launch?.label ?? (name.isEmpty ? appID : name))
        tile.onClose = { [weak self] t in self?.removeClient(t.clientID) }
        if let launch, launch.pending {
            adopt(tile)
            place(tile, for: launch)
        } else {
            // A window the app opened on its own: where the user is.
            manage(tile)
        }
        return tile
    }

    func clientServer(_ server: ClientServer, opened tile: ClientSurface, for launch: AppLaunch) {
        // A restore settles once every saved tile has its window back.
        guard launch.pending, launch.reserved.isEmpty else { return }
        closeLaunchPicker(launch)
        launch.state = .settled
        // Answer at the first frame, when the title and size are in, or after a second.
        var answered = false
        let answer = { [weak launch] in
            guard !answered else { return }
            answered = true
            launch?.finish(.window(tile))
        }
        tile.onFirstFrame = answer
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: answer)
    }

    func clientServer(_ server: ClientServer, offered windows: [HMWindowOffer], for launch: AppLaunch) {
        guard launch.pending else { return }
        if launch.restoring {
            // Restored tiles want their windows back by restore token. Nobody is there to
            // pick from an offer, so the tiles go.
            log.info("app \(launch.label, privacy: .public) offered windows instead of restoring them")
            endLaunch(launch, .nothing)
            return
        }
        launch.offer = windows
        if let wanted = launch.window {
            guard windows.contains(where: { $0.id == wanted }) else {
                let ids = windows.map(\.id).joined(separator: ", ")
                endLaunch(launch, .failed("\(launch.label) offers no window \(wanted) (it offers: \(ids))"))
                return
            }
            openOffered(launch, wanted)
            return
        }
        switch windows.count {
        case 0:
            endLaunch(launch, .nothing)
        case 1:
            openOffered(launch, windows[0].id)
        default:
            if launch.interactive {
                showOffer(launch)
            } else {
                // `hyprmuxctl launch` without --window: the caller gets the list.
                endLaunch(launch, .offer(windows))
            }
        }
    }

    func clientServer(_ server: ClientServer, finished launch: AppLaunch) {
        // Saved tiles the app didn't bring back go quietly: restore is best effort.
        dropReserved(launch)
        guard launch.pending else { return }
        endLaunch(launch, .nothing, tellApp: false)
    }

    func clientServer(_ server: ClientServer, lost launch: AppLaunch) {
        launchFailed(launch, "the app's connection closed")
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
