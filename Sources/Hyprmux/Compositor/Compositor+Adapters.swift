import AppKit
import HyprmuxCore

/// The adapter registry at run time: what Hyprmux loaded, and every process it started
/// through an adapter. `hyprmuxctl adapters` shows both.
final class AdapterRuntime {
    private(set) var registry = AdapterRegistry()
    private(set) var instances: [AdapterInstance] = []
    /// Last probe per app, for `adapters` after a `match`.
    private(set) var probes: [String: ProbeResult] = [:]
    private var nextInstance = 1
    /// Ended instances kept for `hyprmuxctl adapters`.
    static let history = 10

    struct ProbeResult {
        var adapter: String
        var ok: Bool
        var reason: String?
        var details: [String: Any]
        var at: Date
    }

    /// Built-ins from the app bundle, then the user's, next to the config file.
    static var directories: [(AdapterSource, String)] {
        var dirs: [(AdapterSource, String)] = []
        if let builtin = Bundle.main.resourceURL?.appendingPathComponent("adapters").path {
            dirs.append((.builtin, builtin))
        }
        let configDir = (AppDelegate.configPath as NSString).deletingLastPathComponent
        dirs.append((.user, (configDir as NSString).appendingPathComponent("adapters")))
        return dirs
    }

    /// Where bare executable names resolve: HYPRMUX_ADAPTER_BIN (development builds,
    /// colon separated), then the app bundle's executables.
    static var binDirectories: [String] {
        var dirs = (ProcessInfo.processInfo.environment["HYPRMUX_ADAPTER_BIN"] ?? "")
            .split(separator: ":").map { (String($0) as NSString).expandingTildeInPath }
        if let macOS = Bundle.main.executableURL?.deletingLastPathComponent().path { dirs.append(macOS) }
        return dirs
    }

    func reload() {
        registry = AdapterRegistry.load(directories: Self.directories, binDirectories: Self.binDirectories)
        for e in registry.errors { log.warning("adapter \(e.path, privacy: .public): \(e.message, privacy: .public)") }
    }

    func started(adapter: String, app: String, label: String, pid: Int32, token: String) -> AdapterInstance {
        let i = AdapterInstance(number: nextInstance, adapter: adapter, app: app, label: label, pid: pid, token: token)
        nextInstance += 1
        instances.append(i)
        return i
    }

    func ended(_ instance: AdapterInstance) {
        let ended = instances.filter { $0.endedAt != nil }
        if ended.count > Self.history, let oldest = ended.first {
            instances.removeAll { $0 === oldest }
        }
    }

    func instance(pid: Int32) -> AdapterInstance? {
        instances.last { $0.pid == pid && $0.endedAt == nil }
    }

    func recordProbe(app: String, _ result: ProbeResult) { probes[app] = result }

    /// ~/Library/Logs/Hyprmux/adapters, per HYPRMUX_INSTANCE so a test copy keeps its own.
    static var logDirectory: String {
        let instance = ProcessInfo.processInfo.environment["HYPRMUX_INSTANCE"].flatMap { $0.isEmpty ? nil : $0 } ?? "default"
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Hyprmux/adapters")
        return (instance == "default" ? base : base.appendingPathComponent(instance)).path
    }
    static let keptLogs = 20

    /// A fresh log file for one launch. Keeps the newest `keptLogs` files.
    static func newLogPath(adapter: String, label: String) -> String {
        let dir = logDirectory
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let names = try? fm.contentsOfDirectory(atPath: dir) {
            for old in names.filter({ $0.hasSuffix(".log") }).sorted().dropLast(keptLogs - 1) {
                try? fm.removeItem(atPath: (dir as NSString).appendingPathComponent(old))
            }
        }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let safe = label.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return (dir as NSString).appendingPathComponent("\(f.string(from: Date()))-\(adapter)-\(String(safe)).log")
    }
}

/// One process Hyprmux started through an adapter.
final class AdapterInstance {
    let number: Int
    let adapter: String
    let app: String
    let label: String
    let pid: Int32
    let token: String
    let startedAt = Date()
    var endedAt: Date?
    var exitStatus: Int32?
    /// The last line the process wrote to stderr, kept when it exits.
    var lastError: String?
    /// Set when the launch failed outright (never started, or never connected).
    var failure: String?
    /// Everything the process wrote to stderr.
    var logPath: String?

    init(number: Int, adapter: String, app: String, label: String, pid: Int32, token: String) {
        self.number = number
        self.adapter = adapter
        self.app = app
        self.label = label
        self.pid = pid
        self.token = token
    }
}

extension Compositor {
    func loadAdapters() {
        adapters.reload()
    }

    /// The adapter that lifts `bundle`, if any. Apps that speak the protocol themselves
    /// (`HyprmuxClient` in Info.plist) never get one.
    func adapter(for bundle: URL) -> AdapterEntry? {
        guard !Self.isClient(bundle) else { return nil }
        let id = Bundle(url: bundle)?.bundleIdentifier
        return adapters.registry.match(bundleID: id) { relative in
            FileManager.default.fileExists(atPath: bundle.appendingPathComponent(relative).path)
        }.selected
    }

    /// Every tile an instance has: restored ones still waiting, and connected ones.
    private func tiles(of i: AdapterInstance) -> [ClientSurface] {
        var result = clientServer.launch(for: i.token)?.reserved ?? []
        for case let c as ClientSurface in views.values.map(\.surface) where c.connection?.pid == i.pid {
            if !result.contains(where: { $0 === c }) { result.append(c) }
        }
        return result.sorted { $0.clientID.raw < $1.clientID.raw }
    }

    private func state(of i: AdapterInstance, tiles: [ClientSurface]) -> String {
        if i.failure != nil { return "failed" }
        if i.endedAt != nil { return "exited" }
        if tiles.contains(where: { $0.connection != nil }) { return "running" }
        if clientServer.launch(for: i.token)?.pending == true { return "launching" }
        // Alive, but no tiles: every window closed, or it never connected in time.
        return "idle"
    }

    func adapterName(forPid pid: Int32) -> String? { adapters.instance(pid: pid)?.adapter }

    // MARK: hyprmuxctl adapters

    func adaptersJSON() -> [String: Any] {
        let r = adapters.registry
        let iso = ISO8601DateFormatter()
        let now = Date()
        let instances: [[String: Any]] = adapters.instances.map { i in
            let t = tiles(of: i)
            var o: [String: Any] = [
                "instance": i.number, "adapter": i.adapter, "app": i.app, "label": i.label, "pid": Int(i.pid),
                "state": state(of: i, tiles: t), "tiles": t.map { Int($0.clientID.raw) },
                "startedAt": iso.string(from: i.startedAt),
                "uptime": Int((i.endedAt ?? now).timeIntervalSince(i.startedAt)),
            ]
            if let e = i.endedAt { o["endedAt"] = iso.string(from: e) }
            if let s = i.exitStatus { o["exitStatus"] = Int(s) }
            if let f = i.failure { o["failure"] = f }
            if let l = i.lastError { o["lastError"] = l }
            if let l = i.logPath { o["log"] = l }
            return o
        }
        let probes: [[String: Any]] = adapters.probes.sorted { $0.key < $1.key }.map { app, p in
            var o: [String: Any] = ["app": app, "adapter": p.adapter, "ok": p.ok, "at": iso.string(from: p.at)]
            if let reason = p.reason { o["reason"] = reason }
            if !p.details.isEmpty { o["details"] = p.details }
            return o
        }
        return [
            "adapters": r.entries.map(\.json),
            "overridden": r.overridden.map(\.json),
            "errors": r.errors.map { ["path": $0.path, "message": $0.message] },
            "directories": r.directories.map { ["source": $0.source.rawValue, "path": $0.path, "exists": $0.exists] },
            "binDirectories": AdapterRuntime.binDirectories,
            "logDirectory": AdapterRuntime.logDirectory,
            "loadedAt": iso.string(from: r.loadedAt),
            "instances": instances,
            "probes": probes,
        ]
    }

    /// `adapters match`: the decision for one app. Runs on main; the probe doesn't.
    func adaptersMatch(_ target: String) -> IPCReply {
        let expanded = (target as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        let bundle: URL? = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) && isDir.boolValue
            ? URL(fileURLWithPath: expanded)
            : NSWorkspace.shared.urlForApplication(withBundleIdentifier: target)
        guard let bundle else { return .text("error: no .app or bundle id \(target)") }
        let bundleID = Bundle(url: bundle)?.bundleIdentifier
        var out: [String: Any] = ["app": bundle.path, "bundleId": bundleID ?? NSNull()]
        if Self.isClient(bundle) {
            out["client"] = true
            out["candidates"] = []
            out["selected"] = NSNull()
            out["reason"] = "the app speaks the client protocol itself (HyprmuxClient in Info.plist)"
            return .text(jsonText(out))
        }
        let (candidates, selected) = adapters.registry.match(bundleID: bundleID) { relative in
            FileManager.default.fileExists(atPath: bundle.appendingPathComponent(relative).path)
        }
        out["candidates"] = candidates.map { c -> [String: Any] in
            ["id": c.entry.id, "priority": c.entry.manifest.priority, "state": c.entry.state,
             "matched": c.matched, "reason": c.reason]
        }
        out["selected"] = selected?.id ?? NSNull()
        guard let selected, let exe = selected.executable else {
            out["reason"] = "no adapter matches: Hyprmux would start it as a normal macOS app, and its tile would time out"
            return .text(jsonText(out))
        }
        out["command"] = [exe] + AdapterManifest.expand(selected.manifest.args, app: bundle.path, args: [])
        guard let probe = selected.manifest.probe else { return .text(jsonText(out)) }
        let probeArgs = AdapterManifest.expand(probe, app: bundle.path, args: [])
        let app = bundle.path, adapterID = selected.id
        return .background { [weak self] in
            let result = Self.runProbe(executable: exe, arguments: probeArgs, adapter: adapterID)
            DispatchQueue.main.sync { self?.adapters.recordProbe(app: app, result) }
            var o = out
            var p: [String: Any] = ["ok": result.ok]
            if let r = result.reason { p["reason"] = r }
            for (k, v) in result.details { p[k] = v }
            o["probe"] = p
            return Self.jsonText(o)
        }
    }

    /// Runs an adapter's probe: one JSON object on stdout, `ok` required. Five seconds at most.
    static func runProbe(executable: String, arguments: [String], adapter: String) -> AdapterRuntime.ProbeResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        func fail(_ why: String) -> AdapterRuntime.ProbeResult {
            .init(adapter: adapter, ok: false, reason: why, details: [:], at: Date())
        }
        do { try p.run() } catch { return fail("probe didn't start: \(error.localizedDescription)") }
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        var data = Data()
        let reader = DispatchQueue(label: "adapter-probe")
        reader.async { data = out.fileHandleForReading.readDataToEndOfFile() }
        if done.wait(timeout: .now() + 5) == .timedOut {
            p.terminate()
            return fail("probe timed out")
        }
        reader.sync {}
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let ok = o["ok"] as? Bool else {
            return fail("probe printed no result (exit \(p.terminationStatus))")
        }
        var details = o
        details["ok"] = nil
        let reason = details.removeValue(forKey: "reason") as? String
        return .init(adapter: adapter, ok: ok, reason: reason, details: details, at: Date())
    }

    static func jsonText(_ v: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return "error: json" }
        return s
    }
    func jsonText(_ v: Any) -> String { Self.jsonText(v) }
}
