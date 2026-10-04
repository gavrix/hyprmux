import AppKit
import GhosttyKit
import HyprmuxCore

/// Watches the config file for changes.
///
/// Editors save in two ways: writing the file in place, or writing a temp file
/// and renaming it over the original. So we watch both the directory (renames,
/// creation) and the file itself (in-place writes), and re-arm the file watch
/// when the file is replaced. A modification-date check filters duplicates.
final class ConfigWatcher {
    private var dirSource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private let path: String
    private var lastModified: Date?
    private let onChange: () -> Void

    init?(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
        let dir = (path as NSString).deletingLastPathComponent
        guard let d = Self.watch(dir, [.write, .rename, .delete], handler: { [weak self] in self?.changed() }) else { return nil }
        dirSource = d
        lastModified = Self.mtime(path)
        armFileWatch()
    }

    deinit {
        dirSource?.cancel()
        fileSource?.cancel()
    }

    private static func watch(
        _ p: String, _ mask: DispatchSource.FileSystemEvent, handler: @escaping () -> Void
    ) -> DispatchSourceFileSystemObject? {
        let fd = open(p, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
        src.setEventHandler(handler: handler)
        src.setCancelHandler { close(fd) }
        src.resume()
        return src
    }

    /// (Re)opens the watch on the file. The old descriptor goes stale when an editor replaces the file.
    private func armFileWatch() {
        fileSource?.cancel()
        fileSource = Self.watch(path, [.write, .extend, .attrib, .rename, .delete]) { [weak self] in
            guard let self else { return }
            if let ev = self.fileSource?.data, !ev.isDisjoint(with: [.rename, .delete]) { self.armFileWatch() }
            self.changed()
        }
    }

    private static func mtime(_ p: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date
    }

    private func changed() {
        // Let the editor finish writing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            if self.fileSource == nil { self.armFileWatch() }  // file created after launch
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
    /// Problems found before launch, shown in the config error banner.
    var startupNotes: [String] = []
    /// main.swift's first config load wrote a new file: Hyprmux emits `firstlaunch`.
    var firstLaunch = false
    /// `.hmapp`s opened before the compositor started.
    private var pendingOpens: [URL] = []

    static let configPath: String = {
        if let p = ProcessInfo.processInfo.environment["HYPRMUX_CONFIG"], !p.isEmpty {
            return (p as NSString).expandingTildeInPath
        }
        return ("~/.config/hyprmux/hyprmux.conf" as NSString).expandingTildeInPath
    }()

    static func loadConfig() -> HyprmuxConfig {
        ConfigParser.loadOrCreate(path: configPath)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        var config = Self.loadConfig()
        config.errors += startupNotes
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
        compositor.firstLaunch = firstLaunch
        ipc = IPCServer(path: IPCPath.default) { [weak self] line in
            self?.compositor.handleIPCReply(line) ?? .text("error: not ready")
        }
        ipc?.greeting = { [weak self] in self?.compositor.eventGreeting ?? [] }
        compositor.eventSink = { [weak ipc] lines in ipc?.broadcast(lines) }
        compositor.ipcPath = ipc?.path
        compositor.start()
        let opens = pendingOpens
        pendingOpens.removeAll()
        if !opens.isEmpty { DispatchQueue.main.async { [weak self] in self?.application(NSApp, open: opens) } }
        watcher = ConfigWatcher(path: Self.configPath) { [weak self] in self?.reloadConfig() }
        NotificationCenter.default.addObserver(forName: .hyprmuxReloadConfig, object: nil, queue: .main) { [weak self] _ in
            self?.reloadConfig()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func toggleMonitorFullscreen() { compositor.toggleMonitorFullscreen() }

    /// The launcher, for configs that have no bind for it (docs/APPS.md, "The launcher").
    @objc func openAppLauncher() { compositor?.presentAppLauncher() }

    /// Finder (or `open`) opened `.hmapp`s: each launches into a tile (docs/APPS.md).
    func application(_ application: NSApplication, open urls: [URL]) {
        let bundles = urls.filter { $0.isFileURL && $0.pathExtension == HMApp.pathExtension }
        guard let compositor else {
            pendingOpens += bundles
            return
        }
        for url in bundles { compositor.openHMApp(at: url.path) }
    }

    /// Until when a second ⌘Q quits.
    private var quitArmedUntil: Date?
    private static let quitWindow: TimeInterval = 2

    /// ⌘Q: the first press shows "Press ⌘Q again to quit"; a second one within two seconds
    /// quits. An accidental ⌘Q would otherwise close every shell at once.
    @objc func quitPressed(_ sender: Any?) {
        guard let compositor, compositor.config.confirmQuit else {
            NSApp.terminate(sender)
            return
        }
        if let t = quitArmedUntil, Date() < t {
            quitArmedUntil = nil
            NSApp.terminate(sender)
            return
        }
        quitArmedUntil = Date().addingTimeInterval(Self.quitWindow)
        compositor.hud.notifications.post(.info, "Press ⌘Q again to quit", timeout: Self.quitWindow, key: "quit")
    }

    @objc func reloadConfig() {
        var c = Self.loadConfig()
        c.errors += startupNotes
        if c.webEngine != compositor.webEngine {
            c.errors.append("web:engine = \(c.webEngine) takes effect after restarting Hyprmux")
        }
        compositor.reload(c)
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

    /// Saves the session while the shells still run (their foreground programs are read).
    /// With Chromium, main.swift's terminate handler calls this instead: CEF's quit path
    /// skips applicationShouldTerminate.
    func saveSessionBeforeQuit() {
        compositor?.saveSession()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        saveSessionBeforeQuit()
        return .terminateNow
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let app = NSMenu()
        app.addItem(withTitle: "About Hyprmux", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        // No key equivalent: binds own the keyboard (`picker, apps`, ⌘D by default).
        app.addItem(withTitle: "Open App…", action: #selector(openAppLauncher), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Open Config…", action: #selector(openConfig), keyEquivalent: ",")
        app.addItem(withTitle: "Reload Config", action: #selector(reloadConfig), keyEquivalent: "")
        app.addItem(.separator())
        // ⌘Q goes through quitPressed (press twice); the Dock's Quit, logout, and `exit` don't.
        app.addItem(withTitle: "Quit Hyprmux", action: #selector(quitPressed(_:)), keyEquivalent: "q")
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
        win.addItem(withTitle: "Toggle Full Screen", action: #selector(toggleMonitorFullscreen), keyEquivalent: "")
        winItem.submenu = win
        NSApp.windowsMenu = win
        NSApp.mainMenu = main
    }
}
