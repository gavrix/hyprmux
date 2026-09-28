import AppKit
import GhosttyKit
import HypermuxCore
import os

let log = Logger(subsystem: "dev.gavrix.hypermux", category: "hypermux")

/// Owns the libghostty app and config, and routes runtime callbacks to terminal views.
final class GhosttyRuntime {
    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?

    /// Terminal background, so gaps around a resizing surface match its color.
    private(set) var backgroundColor = NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.13, alpha: 1)

    init(extraConfig: [String]) {
        guard let cfg = Self.makeConfig(extraConfig) else { return }
        config = cfg
        readColors(cfg)

        var rt = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: true,
            wakeup_cb: { ud in GhosttyRuntime.wakeup(ud) },
            action_cb: { app, target, action in GhosttyRuntime.action(app!, target: target, action: action) },
            read_clipboard_cb: { ud, loc, state in GhosttyRuntime.readClipboard(ud, location: loc, state: state) },
            confirm_read_clipboard_cb: { ud, str, state, req in GhosttyRuntime.confirmReadClipboard(ud, string: str, state: state, request: req) },
            write_clipboard_cb: { ud, loc, content, len, confirm in
                GhosttyRuntime.writeClipboard(ud, location: loc, content: content, len: len, confirm: confirm) },
            close_surface_cb: { ud, alive in GhosttyRuntime.closeSurface(ud, processAlive: alive) },
            tmux_control_cb: nil)
        app = ghostty_app_new(&rt, cfg)
        if app == nil { log.critical("ghostty_app_new failed") }

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            if let a = self?.app { ghostty_app_set_focus(a, true) }
        }
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            if let a = self?.app { ghostty_app_set_focus(a, false) }
        }
        nc.addObserver(forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            if let a = self?.app { ghostty_app_keyboard_changed(a) }
        }
    }

    /// The user's normal Ghostty config first, then hypermux's `ghostty { }` overrides.
    private static func makeConfig(_ extra: [String]) -> ghostty_config_t? {
        guard let cfg = ghostty_config_new() else { return nil }
        ghostty_config_load_default_files(cfg)
        ghostty_config_load_recursive_files(cfg)
        if !extra.isEmpty {
            let text = extra.joined(separator: "\n") + "\n"
            text.withCString { ptr in
                ghostty_config_load_string(cfg, ptr, UInt(text.utf8.count), "hypermux.conf")
            }
        }
        ghostty_config_finalize(cfg)
        let n = ghostty_config_diagnostics_count(cfg)
        for i in 0..<n {
            let d = ghostty_config_get_diagnostic(cfg, i)
            if let m = d.message { log.warning("ghostty config: \(String(cString: m), privacy: .public)") }
        }
        return cfg
    }

    func reload(extraConfig: [String]) {
        guard let app, let cfg = Self.makeConfig(extraConfig) else { return }
        ghostty_app_update_config(app, cfg)
        readColors(cfg)
        if let old = config { ghostty_config_free(old) }
        config = cfg
    }

    private func readColors(_ cfg: ghostty_config_t) {
        var c = ghostty_config_color_s()
        let key = "background"
        if ghostty_config_get(cfg, &c, key, UInt(key.utf8.count)) {
            backgroundColor = NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
        }
    }

    func tick() {
        if let app { ghostty_app_tick(app) }
    }

    // MARK: Callbacks

    private static func runtime(_ ud: UnsafeMutableRawPointer?) -> GhosttyRuntime {
        Unmanaged<GhosttyRuntime>.fromOpaque(ud!).takeUnretainedValue()
    }

    /// Surface callbacks get the surface's userdata, which is its TerminalView.
    private static func view(_ ud: UnsafeMutableRawPointer?) -> TerminalView? {
        guard let ud else { return nil }
        return Unmanaged<TerminalView>.fromOpaque(ud).takeUnretainedValue()
    }

    private static func view(_ target: ghostty_target_s) -> TerminalView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE, let s = target.target.surface else { return nil }
        return view(ghostty_surface_userdata(s))
    }

    static func wakeup(_ ud: UnsafeMutableRawPointer?) {
        let rt = runtime(ud)
        DispatchQueue.main.async { rt.tick() }
    }

    static func action(_ app: ghostty_app_t, target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        let v = view(target)
        switch action.tag {
        case GHOSTTY_ACTION_QUIT:
            NSApp.terminate(nil)
        case GHOSTTY_ACTION_NEW_WINDOW, GHOSTTY_ACTION_NEW_TAB, GHOSTTY_ACTION_NEW_SPLIT:
            guard let v else { return false }
            v.host?.terminalDidRequestSpawn(v)
        case GHOSTTY_ACTION_CLOSE_WINDOW, GHOSTTY_ACTION_CLOSE_TAB:
            v?.requestClose()
        case GHOSTTY_ACTION_GOTO_SPLIT:
            guard let v else { return false }
            let d: Dispatcher
            switch action.action.goto_split {
            case GHOSTTY_GOTO_SPLIT_LEFT: d = .moveFocus(.left)
            case GHOSTTY_GOTO_SPLIT_RIGHT: d = .moveFocus(.right)
            case GHOSTTY_GOTO_SPLIT_UP: d = .moveFocus(.up)
            case GHOSTTY_GOTO_SPLIT_DOWN: d = .moveFocus(.down)
            case GHOSTTY_GOTO_SPLIT_PREVIOUS: d = .cycleNext(previous: true)
            default: d = .cycleNext(previous: false)
            }
            v.host?.terminal(v, perform: d)
        case GHOSTTY_ACTION_RESIZE_SPLIT:
            guard let v else { return false }
            let r = action.action.resize_split
            let a = Double(r.amount)
            let d: Dispatcher
            switch r.direction {
            case GHOSTTY_RESIZE_SPLIT_LEFT: d = .resizeActive(dx: -a, dy: 0)
            case GHOSTTY_RESIZE_SPLIT_RIGHT: d = .resizeActive(dx: a, dy: 0)
            case GHOSTTY_RESIZE_SPLIT_UP: d = .resizeActive(dx: 0, dy: -a)
            default: d = .resizeActive(dx: 0, dy: a)
            }
            v.host?.terminal(v, perform: d)
        case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
            guard let v else { return false }
            v.host?.terminal(v, perform: .fullscreen(.maximize))
        case GHOSTTY_ACTION_TOGGLE_FULLSCREEN:
            guard let v else { return false }
            v.host?.terminalDidToggleWindowFullscreen(v)
        case GHOSTTY_ACTION_SET_TITLE:
            guard let v, let t = action.action.set_title.title else { return false }
            v.runtimeSetTitle(String(cString: t))
        case GHOSTTY_ACTION_PWD:
            guard let v, let p = action.action.pwd.pwd else { return false }
            v.runtimeSetPwd(String(cString: p))
        case GHOSTTY_ACTION_CELL_SIZE:
            guard let v else { return false }
            let s = action.action.cell_size
            let scale = v.window?.backingScaleFactor ?? 2
            v.runtimeSetCellSize(CGSize(width: CGFloat(s.width) / scale, height: CGFloat(s.height) / scale))
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            v?.runtimeSetMouseShape(action.action.mouse_shape)
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            NSCursor.setHiddenUntilMouseMoves(action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN)
        case GHOSTTY_ACTION_OPEN_URL:
            let u = action.action.open_url
            guard let ptr = u.url else { return false }
            let data = Data(bytes: ptr, count: Int(u.len))
            guard let str = String(data: data, encoding: .utf8) else { return false }
            let url = URL(string: str) ?? URL(fileURLWithPath: (str as NSString).expandingTildeInPath)
            NSWorkspace.shared.open(url)
        case GHOSTTY_ACTION_RING_BELL:
            NSSound.beep()
        case GHOSTTY_ACTION_RENDER:
            return false
        default:
            return false
        }
        return true
    }

    static func closeSurface(_ ud: UnsafeMutableRawPointer?, processAlive: Bool) {
        guard let v = view(ud) else { return }
        v.host?.terminalDidClose(v, processAlive: processAlive)
    }

    private static let selectionPasteboard = NSPasteboard(name: .init("dev.gavrix.hypermux.selection"))

    private static func pasteboard(_ loc: ghostty_clipboard_e) -> NSPasteboard {
        loc == GHOSTTY_CLIPBOARD_SELECTION ? selectionPasteboard : .general
    }

    static func readClipboard(_ ud: UnsafeMutableRawPointer?, location: ghostty_clipboard_e, state: UnsafeMutableRawPointer?) -> Bool {
        guard let v = view(ud), let s = v.surface else { return false }
        let pb = pasteboard(location)
        var str = pb.string(forType: .string)
        if str == nil, let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            str = urls.map { $0.isFileURL ? $0.path : $0.absoluteString }.joined(separator: " ")
        }
        guard let str else { return false }
        str.withCString { ghostty_surface_complete_clipboard_request(s, $0, state, false) }
        return true
    }

    static func confirmReadClipboard(
        _ ud: UnsafeMutableRawPointer?, string: UnsafePointer<CChar>?,
        state: UnsafeMutableRawPointer?, request: ghostty_clipboard_request_e
    ) {
        guard let v = view(ud), let s = v.surface, let string else { return }
        let text = String(cString: string)
        let alert = NSAlert()
        switch request {
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ:
            alert.messageText = "A program wants to read your clipboard"
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE:
            alert.messageText = "A program wants to write to your clipboard"
        default:
            alert.messageText = "Paste text that may run commands?"
        }
        alert.informativeText = String(text.prefix(500))
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Cancel")
        let ok = alert.runModal() == .alertFirstButtonReturn
        let reply = ok ? text : ""
        reply.withCString { ghostty_surface_complete_clipboard_request(s, $0, state, true) }
    }

    static func writeClipboard(
        _ ud: UnsafeMutableRawPointer?, location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?, len: Int, confirm: Bool
    ) {
        guard let content, len > 0 else { return }
        for i in 0..<len {
            let item = content[i]
            guard let mime = item.mime, let data = item.data, String(cString: mime) == "text/plain" else { continue }
            let pb = pasteboard(location)
            pb.clearContents()
            pb.setString(String(cString: data), forType: .string)
            return
        }
    }
}
