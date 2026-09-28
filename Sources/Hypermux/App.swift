import AppKit
import GhosttyKit
import HypermuxCore

/// Watches the config directory. Editors often save by rename, so we watch the
/// directory and compare the file's modification date.
final class ConfigWatcher {
    private var source: DispatchSourceFileSystemObject?
    private let path: String
    private var lastModified: Date?
    private let onChange: () -> Void

    init?(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
        let dir = (path as NSString).deletingLastPathComponent
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { return nil }
        lastModified = Self.mtime(path)
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in self?.check() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    deinit { source?.cancel() }

    private static func mtime(_ p: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date
    }

    private func check() {
        // Let the editor finish writing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            let m = Self.mtime(self.path)
            guard m != nil, m != self.lastModified else { return }
            self.lastModified = m
            self.onChange()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var runtime: GhosttyRuntime!
    private var compositor: Compositor!
    private var watcher: ConfigWatcher?
    private var ipc: IPCServer?

    static let configPath: String = {
        if let p = ProcessInfo.processInfo.environment["HYPERMUX_CONFIG"], !p.isEmpty { return p }
        return ("~/.config/hypermux/hypermux.conf" as NSString).expandingTildeInPath
    }()

    static func loadConfig() -> HypermuxConfig {
        if FileManager.default.fileExists(atPath: configPath) {
            return ConfigParser.load(path: configPath)
        }
        return ConfigParser.parse(defaultConfig)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let config = Self.loadConfig()
        for e in config.errors { log.warning("config: \(e, privacy: .public)") }
        runtime = GhosttyRuntime(extraConfig: config.ghostty)
        guard runtime.app != nil else {
            let a = NSAlert()
            a.messageText = "libghostty failed to start"
            a.runModal()
            NSApp.terminate(nil)
            return
        }
        compositor = Compositor(runtime: runtime, config: config)
        ipc = IPCServer(path: IPCPath.default) { [weak self] line in
            self?.compositor.handleIPC(line) ?? "error: not ready"
        }
        compositor.ipcPath = ipc?.path
        compositor.start()
        watcher = ConfigWatcher(path: Self.configPath) { [weak self] in self?.reloadConfig() }
        NotificationCenter.default.addObserver(forName: .hypermuxReloadConfig, object: nil, queue: .main) { [weak self] _ in
            self?.reloadConfig()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func reloadConfig() {
        compositor.reload(Self.loadConfig())
    }

    @objc func openConfig() {
        let path = Self.configPath
        if !FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? defaultConfig.write(toFile: path, atomically: true, encoding: .utf8)
            watcher = ConfigWatcher(path: path) { [weak self] in self?.reloadConfig() }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let app = NSMenu()
        app.addItem(withTitle: "About Hypermux", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Open Config…", action: #selector(openConfig), keyEquivalent: ",")
        app.addItem(withTitle: "Reload Config", action: #selector(reloadConfig), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Hypermux", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(TerminalView.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(TerminalView.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let winItem = NSMenuItem()
        main.addItem(winItem)
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "")
        winItem.submenu = win
        NSApp.windowsMenu = win
        NSApp.mainMenu = main
    }
}
