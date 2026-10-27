import AppKit
import HyprmuxClientProtocol
import HyprmuxCore
import os

private let pluginLog = Logger(subsystem: "dev.gavrix.hyprmux", category: "plugins")

/// The plugins the config's `plugin =` lines name, and the host process each one runs
/// in. Hyprmux starts them, restarts one that exits, and tells their connections apart
/// by pid, for permissions.
final class PluginRuntime {
    final class Plugin {
        /// The config line's value, as written.
        let spec: String
        let dir: String
        var manifest: PluginManifest?
        /// Why it can't run: no manifest, no host. Nil when it can.
        var error: String?
        var process: Process?
        var startedAt: Date?
        var restarts = 0
        var lastExit: Int32?
        var lastError: String?
        var logPath: String?
        /// Still listed in the config. A stopped plugin isn't restarted.
        var wanted = true
        var restart: DispatchWorkItem?

        init(spec: String, dir: String) { self.spec = spec; self.dir = dir }

        var pid: pid_t { process?.isRunning == true ? process!.processIdentifier : 0 }
        var state: String {
            if error != nil { return "error" }
            if process?.isRunning == true { return "running" }
            if restart != nil { return "restarting" }
            return wanted ? "starting" : "stopped"
        }
    }

    /// In config order.
    private(set) var plugins: [Plugin] = []

    func plugin(pid: pid_t) -> Plugin? { pid > 0 ? plugins.first { $0.pid == pid } : nil }
    func plugin(dir: String) -> Plugin? { plugins.first { $0.dir == dir } }
    func add(_ p: Plugin) { plugins.append(p) }
    func remove(_ p: Plugin) { plugins.removeAll { $0 === p } }
    func reorder(_ dirs: [String]) {
        plugins.sort { (dirs.firstIndex(of: $0.dir) ?? .max) < (dirs.firstIndex(of: $1.dir) ?? .max) }
    }
}

extension Compositor {
    /// `plugins/` next to the config: where `plugin = NAME` looks.
    static var pluginsDirectory: String {
        ((AppDelegate.configPath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("plugins")
    }

    /// A plugin's own settings folder: `plugin-config/<id>/` next to Hyprmux's config.
    /// Hyprmux never reads or creates it (docs/PLUGINS.md, Settings).
    static func pluginConfigDirectory(_ id: String) -> String {
        ((AppDelegate.configPath as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("plugin-config/\(id)")
    }

    /// The plugins built into Hyprmux: `Resources/plugins` in the bundle.
    static var builtinPluginsDirectory: String? {
        Bundle.main.resourceURL.map { $0.appendingPathComponent("plugins").path }
    }

    /// A `plugin =` value to its folder (PluginLocation).
    static func pluginDirectory(_ spec: String) -> String {
        PluginLocation.directory(for: spec, configDir: (AppDelegate.configPath as NSString).deletingLastPathComponent,
                                 builtinDir: builtinPluginsDirectory)
    }

    /// The QML host: next to Hyprmux in the bundle, else `hyprmux-qml` on PATH.
    /// `HYPRMUX_QML_HOST` overrides both, for a host built elsewhere.
    static var pluginHost: String? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["HYPRMUX_QML_HOST"], !env.isEmpty {
            return fm.isExecutableFile(atPath: env) ? env : nil
        }
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/hyprmux-qml").path
        if fm.isExecutableFile(atPath: bundled) { return bundled }
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let p = (String(dir) as NSString).appendingPathComponent("hyprmux-qml")
            if fm.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Starts the plugins the config lists and stops the ones it no longer does. At
    /// launch and on every reload.
    func syncPlugins() {
        let wanted = config.plugins.map { ($0, Self.pluginDirectory($0)) }
        let dirs = wanted.map(\.1)
        for p in plugins.plugins where !dirs.contains(p.dir) {
            stopPlugin(p)
            plugins.remove(p)
        }
        for (spec, dir) in wanted where plugins.plugin(dir: dir) == nil {
            let p = PluginRuntime.Plugin(spec: spec, dir: dir)
            plugins.add(p)
            startPlugin(p)
        }
        plugins.reorder(dirs)
    }

    private func startPlugin(_ p: PluginRuntime.Plugin) {
        p.restart = nil
        switch PluginManifest.load(p.dir) {
        case .failure(let e):
            p.error = e.description
            pluginLog.error("plugin \(p.spec, privacy: .public): \(e.description, privacy: .public)")
            return
        case .success(let m):
            p.manifest = m
        }
        // The bundled Qt needs macOS 14.4; Hyprmux itself runs on 14.0.
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 14, minorVersion: 4, patchVersion: 0)) else {
            p.error = "plugins need macOS 14.4 or later"
            return
        }
        guard let host = Self.pluginHost else {
            p.error = "the QML host (hyprmux-qml) isn't installed"
            return
        }
        if let other = plugins.plugins.first(where: { $0 !== p && $0.manifest?.id == p.manifest?.id && $0.pid > 0 }) {
            p.error = "another plugin line runs \(p.manifest!.id) already (\(other.spec))"
            return
        }
        p.error = nil
        let m = p.manifest!
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: host)
        proc.arguments = [p.dir]
        var env = ProcessInfo.processInfo.environment
        env[HMProtocol.instanceVariable] = clientServer.instance
        env["HYPRMUX_PLUGIN_CONFIG_DIR"] = Self.pluginConfigDirectory(m.id)
        env[HMProtocol.launchTokenVariable] = nil
        proc.environment = env
        proc.currentDirectoryURL = URL(fileURLWithPath: p.dir)

        // Its output goes to a log, one per plugin, started fresh each run; the last
        // line says why it exited.
        let logPath = Self.pluginLogPath(m.id)
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let log = FileHandle(forWritingAtPath: logPath)
        p.logPath = logPath
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = out
        let tail = StderrTail()
        out.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                try? log?.close()
            } else {
                tail.append(data)
                try? log?.write(contentsOf: data)
            }
        }
        proc.terminationHandler = { [weak self, weak p] proc in
            DispatchQueue.main.async {
                guard let self, let p, p.process === proc else { return }
                p.lastExit = proc.terminationStatus
                p.lastError = tail.lastLine
                self.pluginExited(p)
            }
        }
        do {
            try proc.run()
        } catch {
            p.error = "couldn't start the host: \(error.localizedDescription)"
            return
        }
        p.process = proc
        p.startedAt = Date()
        pluginLog.info("plugin \(m.id, privacy: .public) started: pid \(proc.processIdentifier)")
    }

    /// Restarts a plugin that exited while still listed, waiting longer each time it
    /// exits soon after starting: 1 s, 2 s, 4 s, up to a minute. A run of a minute or
    /// more resets the wait.
    private func pluginExited(_ p: PluginRuntime.Plugin) {
        let ranFor = p.startedAt.map { Date().timeIntervalSince($0) } ?? 0
        p.process = nil
        guard p.wanted else { return }
        if ranFor >= 60 { p.restarts = 0 }
        let delay = min(60, pow(2, Double(p.restarts)))
        p.restarts += 1
        pluginLog.info("plugin \(p.spec, privacy: .public) exited (\(p.lastExit ?? -1)); restarting in \(Int(delay)) s")
        let work = DispatchWorkItem { [weak self, weak p] in
            guard let self, let p, p.wanted, p.restart != nil else { return }
            self.startPlugin(p)
        }
        p.restart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func stopPlugin(_ p: PluginRuntime.Plugin) {
        p.wanted = false
        p.restart?.cancel()
        p.restart = nil
        // The host leaves when its connection drops; SIGTERM covers one still starting.
        if let proc = p.process, proc.isRunning { proc.terminate() }
        pluginLog.info("plugin \(p.spec, privacy: .public) stopped")
    }

    /// ~/Library/Logs/Hyprmux/plugins/<id>.log, per HYPRMUX_INSTANCE like adapter logs.
    static func pluginLogPath(_ id: String) -> String {
        let instance = ProcessInfo.processInfo.environment[HMProtocol.instanceVariable].flatMap { $0.isEmpty ? nil : $0 } ?? "default"
        var dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Hyprmux/plugins")
        if instance != "default" { dir = dir.appendingPathComponent(instance) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(id).log").path
    }

    /// `hyprmuxctl plugins`.
    func pluginsJSON() -> [String: Any] {
        let list: [[String: Any]] = plugins.plugins.map { p in
            var o: [String: Any] = ["spec": p.spec, "dir": p.dir, "state": p.state, "restarts": p.restarts]
            if let m = p.manifest {
                o["id"] = m.id
                o["name"] = m.name
                o["permissions"] = m.permissions.sorted()
                o["settings"] = Self.pluginConfigDirectory(m.id)
            }
            if p.pid > 0 { o["pid"] = Int(p.pid) }
            if let e = p.error { o["error"] = e }
            if let x = p.lastExit { o["lastExit"] = Int(x) }
            if let e = p.lastError { o["lastError"] = e }
            if let l = p.logPath { o["log"] = l }
            return o
        }
        return ["plugins": list, "host": Self.pluginHost ?? NSNull(), "folder": Self.pluginsDirectory,
                "builtin": Self.builtinPluginsDirectory ?? NSNull()]
    }

    /// The plugin a client connection belongs to, by its process.
    func pluginConnection(pid: pid_t) -> (id: String, name: String, permissions: Set<String>)? {
        guard let p = plugins.plugin(pid: pid), let m = p.manifest else { return nil }
        return (m.id, m.name, m.permissions)
    }
}
