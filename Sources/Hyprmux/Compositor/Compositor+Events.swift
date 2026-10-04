import AppKit
import HyprmuxCore

/// Events and hooks (docs/HOOKS.md). Every event goes to the control socket's `events`
/// subscribers and to the exec hooks listening for it. Terminal hooks run in `start()`.
extension Compositor {
    /// Built-ins from the app bundle, then the user's, next to the config file.
    static var hookDirectories: [(HookSource, String)] {
        var dirs: [(HookSource, String)] = []
        if let builtin = Bundle.main.resourceURL?.appendingPathComponent("hooks").path {
            dirs.append((.builtin, builtin))
        }
        let configDir = (AppDelegate.configPath as NSString).deletingLastPathComponent
        dirs.append((.user, (configDir as NSString).appendingPathComponent("hooks")))
        return dirs
    }

    /// Loads the hook manifests. Broken ones stay on screen as one notice until fixed.
    func loadHooks() {
        hooks = HookRegistry.load(directories: Self.hookDirectories)
        let errors = hooks.errors
        for e in errors { log.warning("hook \(e.path, privacy: .public): \(e.message, privacy: .public)") }
        guard !errors.isEmpty else {
            hud.notifications.dismiss(key: "hook-errors")
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let lines = errors.prefix(5).map { e -> String in
            let path = e.path.hasPrefix(home + "/") ? "~" + e.path.dropFirst(home.count) : e.path
            return "\(path): \(e.message)"
        }
        hud.notifications.post(.warning, title: errors.count == 1 ? "Hook error" : "\(errors.count) hook errors",
                               lines.joined(separator: "\n"), sticky: true, key: "hook-errors")
    }

    /// What a new `events` subscriber learns first: the state behind stateful events.
    var eventGreeting: [String] {
        [HyprmuxEvent.appActive(NSApp.isActive).line, HyprmuxEvent.submap(submap).line]
    }

    func emit(_ event: HyprmuxEvent) { emit([event]) }

    func emit(_ events: [HyprmuxEvent]) {
        guard !events.isEmpty else { return }
        eventSink?(events.map(\.line))
        for e in events {
            for h in hooks.hooks(for: e.name) where h.manifest.run == .exec { runHook(h, e) }
        }
    }

    /// Runs an exec hook with `/bin/sh -c`, in the background, with the event in
    /// `HYPRMUX_EVENT` and `HYPRMUX_EVENT_DATA`.
    private func runHook(_ hook: HookEntry, _ event: HyprmuxEvent) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", hook.manifest.command]
        var env = ProcessInfo.processInfo.environment
        env.merge(hyprmuxEnvironment) { _, ours in ours }
        env["HYPRMUX_EVENT"] = event.name
        env["HYPRMUX_EVENT_DATA"] = event.data
        env["HYPRMUX_HOOK"] = hook.id
        p.environment = env
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let id = hook.id
        p.terminationHandler = { proc in
            if proc.terminationStatus != 0 {
                log.warning("hook \(id, privacy: .public) exited with \(proc.terminationStatus)")
            }
        }
        do {
            try p.run()
        } catch {
            log.warning("hook \(id, privacy: .public) didn't start: \(error.localizedDescription, privacy: .public)")
        }
    }
}
