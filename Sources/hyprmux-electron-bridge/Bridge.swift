// The bridge itself: launches the app, injects the hook, and speaks the client
// protocol for every window the hook reports.
import AppKit
import Foundation
import HyprmuxClientKit
import IOSurface

/// Stops the app and exits. Electron apps may delay or veto SIGTERM (VS Code runs its
/// own quit lifecycle), so SIGKILL follows after a grace period.
func stopApp(_ process: Process?, exitCode: Int32) -> Never {
    if let process, process.isRunning {
        process.terminate()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    exit(exitCode)
}

final class Bridge {
    private let options: Options
    private var client: HMClient!
    private var channel: UnixChannel!
    private var appProcess: Process?
    private var hook: UnixChannel.Conn?
    /// Hook window id -> window state.
    private var windows: [Int: BridgedWindow] = [:]
    /// Toplevel surface id -> hook window id.
    private var surfaces: [UInt64: Int] = [:]
    private var windowCount = 0
    /// The hook window whose tile has keyboard focus. Dialogs and menus without a
    /// parent window go here.
    private var focusedWindow: Int?
    private var nextCaretRequest = 1
    private var caretRequests: [Int: Int] = [:]
    private let bundle: Bundle
    private let appName: String
    private var appScale: Double = 2
    private var signalSources: [DispatchSourceSignal] = []
    private let debug = ProcessInfo.processInfo.environment["HYPRMUX_HOOK_DEBUG"] != nil

    init(options: Options) throws {
        self.options = options
        bundle = Bundle(url: URL(fileURLWithPath: options.appPath)) ?? Bundle()
        appName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? URL(fileURLWithPath: options.appPath).deletingPathExtension().lastPathComponent
        if cliInspectEnabled(appBundle: URL(fileURLWithPath: options.appPath)) == false {
            throw NSError(domain: "bridge", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "\(appName) disables the main-process inspector (EnableNodeCliInspectArguments), so Hyprmux can't lift it."])
        }
    }

    func run() {
        signal(SIGPIPE, SIG_IGN)
        // 1. The hook's socket, up before the app starts.
        stderr("bridge: listening on the hook socket")
        let socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("hyprmux-electron-\(ProcessInfo.processInfo.processIdentifier).sock").path
        channel = UnixChannel(path: socketPath)
        channel.onAccept = { [weak self] conn in self?.acceptHook(conn) }
        do { try channel.start() } catch { stderr("bridge: can't listen on \(socketPath): \(error)"); exit(1) }

        // 2. The compositor. Hyprmux sets HYPRMUX_LAUNCH_TOKEN; the kit's hello carries it.
        client = HMClient(appID: "dev.gavrix.hyprmux.electron", name: appName)
        do { try client.connect() } catch { stderr("bridge: \(error)"); exit(1) }
        stderr("bridge: connected to Hyprmux")
        client.onDisconnect = { [weak self] reason in
            stderr("bridge: compositor disconnected: \(reason)")
            stopApp(self?.appProcess, exitCode: 0)
        }

        // 3. The app itself.
        guard let exe = bundle.executableURL else { stderr("bridge: no executable in \(options.appPath)"); exit(1) }
        let port = freePort()
        var args = ["--inspect-brk=\(port)"]
        args += adapterArguments()
        args += options.appArgs
        let selfPath = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let bundled = selfPath.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/electron-hook.js").path
        let hookPath = ProcessInfo.processInfo.environment["HYPRMUX_ELECTRON_HOOK"]
            ?? (FileManager.default.fileExists(atPath: bundled) ? bundled : nil)
            ?? {
                // Development from the SwiftPM build tree: walk up from the bridge binary
                // (…/hypermux/.build/…/hyprmux-electron-bridge) to the repo's Resources/.
                var dir = selfPath.deletingLastPathComponent()
                for _ in 0..<5 {
                    let candidate = dir.appendingPathComponent("Resources/electron-hook.js").path
                    if FileManager.default.fileExists(atPath: candidate) { return candidate }
                    dir.deleteLastPathComponent()
                }
                return bundled
            }()
        let entryRegex = ProcessInfo.processInfo.environment["HYPRMUX_ELECTRON_ENTRY"] ?? "/Contents/Resources/app"

        var env = ProcessInfo.processInfo.environment
        env["EE_HOOK_SOCKET"] = socketPath
        env["EE_SCALE"] = "\(NSScreen.main?.backingScaleFactor ?? 2)"
        env["EE_BRIDGE_BIN"] = selfPath.path
        env["EE_APP"] = adapter()

        let process = Process()
        process.executableURL = exe
        process.arguments = args
        process.environment = env
        process.terminationHandler = { [weak self] _ in
            stderr("bridge: \(self?.appName ?? "app") exited")
            exit(0)
        }
        do { try process.run() } catch { stderr("bridge: can't start \(appName): \(error.localizedDescription)"); exit(1) }
        appProcess = process
        // The app lives and dies with the bridge: killing the bridge must not orphan it.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak process] in
                stderr("bridge: signal \(sig), stopping the app")
                stopApp(process, exitCode: 0)
            }
            source.resume()
            signalSources.append(source)
        }
        if debug {
            // Debug: SIGUSR1 dumps every window's latest frame to /tmp, for testing
            // without screen capture.
            signal(SIGUSR1, SIG_IGN)
            let dump = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
            dump.setEventHandler { [weak self] in
                for (id, w) in self?.windows ?? [:] {
                    let path = "/tmp/hyprmux-bridge-win\(id).png"
                    stderr("bridge: dump \(path): \(w.writePNG(to: path) ? "ok" : "empty")")
                }
            }
            dump.resume()
            signalSources.append(dump)
        }

        stderr("bridge: \(appName) started (pid \(process.processIdentifier)), injecting")
        // 4. Inject the hook.
        Task {
            do {
                try await Injector().inject(port: port, hookPath: hookPath, entryRegex: entryRegex)
                stderr("bridge: hook injected into \(appName)")
            } catch {
                stderr("bridge: injection failed: \(error.localizedDescription)")
                stopApp(process, exitCode: 1)
            }
        }
    }

    /// Per-adapter launch arguments. Profiles under Hyprmux's support directory keep a
    /// lifted app from colliding with the user's own instance.
    private func adapterArguments() -> [String] {
        let adapter = adapter()
        let given = Set(options.appArgs.filter { $0.hasPrefix("--") }.map { $0.components(separatedBy: "=")[0] })
        var extra: [String] = []
        switch adapter {
        case "vscode", "cursor":
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Hyprmux/electron-apps/\(appName)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if !given.contains("--user-data-dir") { extra += ["--user-data-dir", dir.appendingPathComponent("userdata").path] }
            if !given.contains("--extensions-dir") { extra += ["--extensions-dir", dir.appendingPathComponent("extensions").path] }
        default: break
        }
        return extra
    }

    private func adapter() -> String {
        if let explicit = options.adapter { return explicit }
        let id = (bundle.bundleIdentifier ?? "").lowercased()
        if id.hasPrefix("com.microsoft.vscode") { return "vscode" }
        if id.contains("cursor") || appName.lowercased() == "cursor" { return "cursor" }
        return "generic"
    }

    private func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        addr.sin_port = 0
        withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var out = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &out) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &len) }
        }
        return Int(UInt16(bigEndian: out.sin_port))
    }

    // MARK: Hook messages

    private func acceptHook(_ conn: UnixChannel.Conn) {
        // The kit and the window table live on main, like the XPC handlers.
        conn.onMessage = { [weak self] json, payload in
            DispatchQueue.main.async { self?.onHookMessage(conn, json, payload) }
        }
        // The long-lived hook connection is the one that sends frames.
        DispatchQueue.main.async { if self.hook == nil { self.hook = conn } }
    }

    private func onHookMessage(_ conn: UnixChannel.Conn, _ m: [String: Any], _ payload: Data?) {
        switch m["t"] as? String {
        case "log":
            if let msg = m["msg"] as? String { stderr("\(appName) hook: \(msg)") }
        case "window":
            addWindow(id: m["win"] as? Int ?? 0, title: m["title"] as? String ?? appName,
                      width: m["w"] as? Int ?? 800, height: m["h"] as? Int ?? 600)
        case "closed":
            guard let id = m["win"] as? Int, let w = windows.removeValue(forKey: id) else { return }
            if focusedWindow == id { focusedWindow = nil }
            surfaces[w.toplevel.surfaceID] = nil
            w.toplevel.destroy()
        case "frame":
            guard let id = m["win"] as? Int, let w = windows[id] else { return }
            if tracing, let ts = m["ts"] as? Double {
                trace("frame win\(id) \(m["w"] ?? 0)x\(m["h"] ?? 0) of \(m["fw"] ?? 0)x\(m["fh"] ?? 0) hook \(m["cost"] ?? 0)ms transit \(Int(nowMs() - ts))ms")
            }
            let fw = m["fw"] as? Int ?? 0, fh = m["fh"] as? Int ?? 0
            if let file = m["file"] as? String {
                // Pixels are in the window's shared pixel file; the message only says what changed.
                w.applyFileFrame(path: file, fullW: fw, fullH: fh)
            } else if let payload {
                w.applyFrame(dirtyX: m["x"] as? Int ?? 0, dirtyY: m["y"] as? Int ?? 0,
                             dirtyW: m["w"] as? Int ?? 0, dirtyH: m["h"] as? Int ?? 0,
                             fullW: fw, fullH: fh, pixels: payload)
            }
        case "caret":
            // The reply to a caret request: the focused element's caret, in window points.
            guard let req = m["caret"] as? Int, let id = caretRequests.removeValue(forKey: req), let w = windows[id],
                  let x = m["x"] as? Double, let y = m["y"] as? Double else { return }
            w.toplevel.setTextInputCursorRect(x: x, y: y, width: m["w"] as? Double ?? 1, height: m["h"] as? Double ?? 18)
        case "cursor":
            guard let id = m["win"] as? Int, let w = windows[id] else { return }
            w.toplevel.setCursor(Self.cursorName(m["cursor"] as? String ?? "default"))
        case "title":
            guard let id = m["win"] as? Int, let w = windows[id] else { return }
            w.toplevel.setTitle(m["title"] as? String ?? appName)
        case "dialog":
            let id = m["win"] as? Int ?? 0
            guard let w = targetWindow(id) else { conn.send(["reply": m["req"] as? Int ?? 0, "result": ["canceled": true]]); return }
            let kind = m["kind"] as? String ?? "open"
            let options = m["options"] as? [String: Any] ?? [:]
            w.toplevel.openDialog(kind: kind, options: options) { result in
                conn.send(["reply": m["req"] as? Int ?? 0, "result": result])
            }
        case "menu":
            let id = m["win"] as? Int ?? 0
            guard let w = targetWindow(id) else { conn.send(["reply": m["req"] as? Int ?? 0]); return }
            w.toplevel.popupMenu(m["items"] as? [[String: Any]] ?? [],
                                 x: m["x"] as? Double ?? 0, y: m["y"] as? Double ?? 0) { item in
                var reply: [String: Any] = ["reply": m["req"] as? Int ?? 0]
                if let item { reply["item"] = item }
                conn.send(reply)
            }
        default:
            break
        }
    }

    /// The window a request names, else the focused one, else the lowest id.
    private func targetWindow(_ id: Int) -> BridgedWindow? {
        windows[id] ?? focusedWindow.flatMap { windows[$0] } ?? windows.keys.min().flatMap { windows[$0] }
    }

    private static func cursorName(_ type: String) -> String {
        switch type {
        case "text", "IBeam": "ibeam"
        case "hand", "pointer" where type == "hand": "pointing_hand"
        case "crosshair": "crosshair"
        case "grab": "open_hand"
        case "grabbing": "closed_hand"
        case "col-resize", "ew-resize", "e-resize", "w-resize": "resize_left_right"
        case "row-resize", "ns-resize", "n-resize", "s-resize": "resize_up_down"
        case "not-allowed", "no-drop": "not_allowed"
        default: "arrow"
        }
    }

    // MARK: Windows

    private func addWindow(id: Int, title: String, width: Int, height: Int) {
        windowCount += 1
        let top = client.makeToplevel(title: title.isEmpty ? appName : title, restoreToken: "window-\(windowCount)")
        let w = BridgedWindow(id: id, toplevel: top, pointWidth: width, pointHeight: height)
        windows[id] = w
        surfaces[top.surfaceID] = id

        top.onConfigure = { [weak self, weak w] c in
            guard let w else { return }
            w.pointWidth = Int(c.width); w.pointHeight = Int(c.height)
            self?.hook?.send(["t": "resize", "win": id, "w": c.width, "h": c.height])
        }
        top.onCloseRequested = { [weak self] in self?.hook?.send(["t": "close", "win": id]) }
        top.onKeyboardFocus = { [weak self] on in
            guard let self else { return }
            if on { focusedWindow = id } else if focusedWindow == id { focusedWindow = nil }
            hook?.send(["t": on ? "focus" : "blur", "win": id])
        }
        top.onPointer = { [weak self] event in self?.sendPointer(event, to: id) }
        top.onKey = { [weak self] key in self?.sendKey(key, to: id) }
        top.onBufferReleased = { [weak w] in w?.releasedBuffer() }
        // Electron has no API to show a composition, so Hyprmux draws the preedit.
        top.enableTextInput(compositorPreedit: true)
        top.onTextInput = { [weak self] u in self?.applyTextInput(u, to: id) }
    }

    /// IME results go to the app as text; while composing, Hyprmux needs the caret
    /// for the candidate window and the preedit overlay.
    private func applyTextInput(_ u: HMTextInputUpdate, to win: Int) {
        trace("text input win\(win) delete \(u.deleteBefore)/\(u.deleteAfter) commit \(u.commit.debugDescription) preedit \(u.preedit.debugDescription)")
        if u.deleteBefore > 0 || u.deleteAfter > 0 || !u.commit.isEmpty {
            hook?.send(["t": "ime", "win": win, "before": u.deleteBefore, "after": u.deleteAfter, "commit": u.commit])
        }
        guard !u.preedit.isEmpty, let hook else { return }
        let req = nextCaretRequest
        nextCaretRequest += 1
        caretRequests[req] = win
        hook.send(["t": "caret", "win": win, "req": req])
    }

    private func sendPointer(_ event: HMPointerEvent, to win: Int) {
        var events: [[String: Any]] = []
        func mods(_ flags: UInt64, buttons: UInt64 = 0) -> [String] {
            var m: [String] = []
            if flags & (1 << 17) != 0 { m.append("shift") }
            if flags & (1 << 18) != 0 { m.append("control") }
            if flags & (1 << 19) != 0 { m.append("alt") }
            if flags & (1 << 20) != 0 { m.append("meta") }
            if buttons & 1 != 0 { m.append("leftButtonDown") }
            if buttons & 4 != 0 { m.append("middleButtonDown") }
            if buttons & 2 != 0 { m.append("rightButtonDown") }
            return m
        }
        switch event {
        case .enter(let x, let y):
            events.append(["type": "mouseEnter", "x": x, "y": y, "globalX": x, "globalY": y])
            events.append(["type": "mouseMove", "x": x, "y": y])
        case .leave:
            events.append(["type": "mouseLeave", "x": 0, "y": 0])
        case .motion(let x, let y, let buttons, let flags):
            events.append(["type": "mouseMove", "x": x, "y": y, "modifiers": mods(flags, buttons: buttons)])
        case .button(let x, let y, let button, let down, let clicks, let flags):
            trace("button \(button) \(down ? "down" : "up") at \(Int(x)),\(Int(y)) clicks \(clicks)")
            events.append(["type": down ? "mouseDown" : "mouseUp", "x": x, "y": y,
                           "button": ["left", "right", "middle"][min(button, 2)],
                           "clickCount": clicks, "modifiers": mods(flags)])
        case .scroll(let x, let y, let dx, let dy, let precise, _, _, let ticksX, let ticksY):
            // Chromium's own conversion (WebMouseWheelEventBuilder on macOS): a trackpad's
            // point deltas are pixels, with ticks = pixels / 40; a notched wheel's line
            // deltas are 40 pixels each, with ticks = raw notches. Signs match AppKit:
            // positive scrolls toward the top, in AppKit, in Chromium, and in Electron's
            // sendInputEvent. Apps that read wheelDeltaY (ticks × 120) first, like VS
            // Code, scroll by nothing without ticks.
            let pixelsPerLine = 40.0
            let px = precise ? dx : dx * pixelsPerLine, py = precise ? dy : dy * pixelsPerLine
            let tx = precise ? dx / pixelsPerLine : (ticksX != 0 ? ticksX : dx)
            let ty = precise ? dy / pixelsPerLine : (ticksY != 0 ? ticksY : dy)
            trace("scroll \(precise ? "precise" : "wheel") d \(dx),\(dy) ticks \(ticksX),\(ticksY) -> px \(py)")
            events.append(["type": "mouseWheel", "x": x, "y": y, "deltaX": px, "deltaY": py,
                           "wheelTicksX": tx, "wheelTicksY": ty,
                           "canScroll": true, "hasPreciseScrollingDeltas": precise])
        }
        hook?.send(["t": "input", "win": win, "events": events])
    }

    private func sendKey(_ key: HMKeyEvent, to win: Int) {
        var mods: [String] = []
        if key.modifiers & (1 << 17) != 0 { mods.append("shift") }
        if key.modifiers & (1 << 18) != 0 { mods.append("control") }
        if key.modifiers & (1 << 19) != 0 { mods.append("alt") }
        if key.modifiers & (1 << 20) != 0 { mods.append("meta") }
        let name = Self.keyName(key)
        trace("key \(key.keyCode) down=\(key.down) chars=\(key.characters.debugDescription) mods=\(mods) -> \(name ?? "nil")")
        guard let name else { return }
        var events: [[String: Any]] = []
        if key.down {
            events.append(["type": "keyDown", "keyCode": name, "modifiers": mods])
            // Printable text goes as a char event; command/control chords never insert text.
            let text = key.characters
            let chord = key.modifiers & ((1 << 18) | (1 << 20)) != 0
            if !text.isEmpty, !chord, name.count > 1 || !text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) {
                let special = ["Return": "\r", "Enter": "\r", "Tab": "\t", "Space": " "][name]
                if let special { events.append(["type": "char", "keyCode": special, "modifiers": mods]) }
            } else if !text.isEmpty, !chord {
                events.append(["type": "char", "keyCode": text, "modifiers": mods])
            }
        } else {
            events.append(["type": "keyUp", "keyCode": name, "modifiers": mods])
        }
        hook?.send(["t": "input", "win": win, "events": events])
    }

    /// macOS key code to Electron's key names.
    private static func keyName(_ k: HMKeyEvent) -> String? {
        switch k.keyCode {
        case 36, 76: return "Return"
        case 48: return "Tab"
        case 49: return "Space"
        case 51: return "Backspace"
        case 53: return "Escape"
        case 117: return "Delete"
        case 115: return "Home"
        case 119: return "End"
        case 116: return "PageUp"
        case 121: return "PageDown"
        case 123: return "Left"
        case 124: return "Right"
        case 125: return "Down"
        case 126: return "Up"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        default:
            let c = k.charactersIgnoringModifiers
            if c.count == 1 { return c }
            return nil
        }
    }
}

/// One lifted window: a protocol toplevel plus the window's pixels. Normally those live
/// in a pixel file the hook writes and the bridge maps (Unix sockets move megabyte
/// frames far too slowly from a busy Electron main process). Frames that carry their
/// pixels inline go to a private backing store instead. Each present copies the whole
/// image into the swapchain; per-buffer damage tracking would avoid that, later.
final class BridgedWindow {
    let id: Int
    let toplevel: HMToplevel
    var pointWidth: Int
    var pointHeight: Int
    private var backing = Data()
    private var pixelWidth = 0
    private var pixelHeight = 0
    private var scale = 2.0
    private var pending = false
    private var map: UnsafeMutableRawPointer?
    private var mapSize = 0
    private var mapPath = ""

    init(id: Int, toplevel: HMToplevel, pointWidth: Int, pointHeight: Int) {
        self.id = id
        self.toplevel = toplevel
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
    }

    deinit { unmap() }

    private func unmap() {
        if let map { munmap(map, mapSize) }
        map = nil; mapSize = 0; mapPath = ""
    }

    /// The hook grows the file but never shrinks it, so a mapping stays valid while the
    /// hook writes. Remap only for a new file or a bigger image.
    private func mapFile(_ path: String, need: Int) -> Bool {
        if map != nil, path == mapPath, mapSize >= need { return true }
        unmap()
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, Int(st.st_size) >= need else { return false }
        let size = Int(st.st_size)
        guard let p = mmap(nil, size, PROT_READ, MAP_SHARED, fd, 0), p != MAP_FAILED else { return false }
        map = p; mapSize = size; mapPath = path
        return true
    }

    func applyFileFrame(path: String, fullW: Int, fullH: Int) {
        guard fullW > 0, fullH > 0, mapFile(path, need: fullW * fullH * 4) else { return }
        if pixelWidth != fullW || pixelHeight != fullH {
            pixelWidth = fullW; pixelHeight = fullH
            scale = Double(fullW) / Double(max(1, pointWidth))
        }
        backing = Data()
        present()
    }

    /// The current image, from the pixel file or the inline backing store.
    private func withPixels(_ body: (UnsafeRawPointer) -> Void) {
        if let map { body(UnsafeRawPointer(map)) }
        else if !backing.isEmpty { backing.withUnsafeBytes { body($0.baseAddress!) } }
    }

    func applyFrame(dirtyX: Int, dirtyY: Int, dirtyW: Int, dirtyH: Int, fullW: Int, fullH: Int, pixels: Data) {
        guard fullW > 0, fullH > 0, pixels.count >= dirtyW * dirtyH * 4 else { return }
        if pixelWidth != fullW || pixelHeight != fullH {
            pixelWidth = fullW; pixelHeight = fullH
            scale = Double(fullW) / Double(max(1, pointWidth))
            backing = Data(count: fullW * fullH * 4)
        }
        if map != nil { unmap(); backing = Data(count: fullW * fullH * 4) }
        guard dirtyW > 0, dirtyH > 0, dirtyX >= 0, dirtyY >= 0,
              dirtyX + dirtyW <= fullW, dirtyY + dirtyH <= fullH else { return }
        backing.withUnsafeMutableBytes { dst in
            pixels.withUnsafeBytes { src in
                for row in 0..<dirtyH {
                    let dstOffset = ((dirtyY + row) * fullW + dirtyX) * 4
                    let srcOffset = row * dirtyW * 4
                    memcpy(dst.baseAddress! + dstOffset, src.baseAddress! + srcOffset, dirtyW * 4)
                }
            }
        }
        present()
    }

    private func present() {
        let presentStart = nowMs()
        guard let buffer = toplevel.acquireBuffer() else {
            pending = true  // try again when the compositor releases one
            trace("win\(id) no free buffer")
            return
        }
        pending = false
        // Row by row: IOSurface may pad rows, and during a resize the paint size and
        // the buffer size differ until Electron catches up.
        IOSurfaceLock(buffer.surface, [], nil)
        let dstStride = buffer.bytesPerRow, srcStride = pixelWidth * 4
        let rowBytes = min(buffer.width, pixelWidth) * 4, rows = min(buffer.height, pixelHeight)
        let dst = IOSurfaceGetBaseAddress(buffer.surface)
        if rowBytes < dstStride || rows < buffer.height { memset(dst, 0, buffer.height * dstStride) }
        withPixels { src in
            for row in 0..<rows {
                memcpy(dst + row * dstStride, src + row * srcStride, rowBytes)
            }
        }
        IOSurfaceUnlock(buffer.surface, [], nil)
        let t0 = nowMs()
        toplevel.present(buffer)
        trace("win\(id) presented, copy+present \(String(format: "%.1f", nowMs() - presentStart))ms, send \(String(format: "%.1f", nowMs() - t0))ms")
    }

    /// Debug: the backing store as a PNG.
    func writePNG(to path: String) -> Bool {
        guard pixelWidth > 0, pixelHeight > 0 else { return false }
        var data = Data()
        withPixels { data = Data(bytes: $0, count: pixelWidth * pixelHeight * 4) }
        guard !data.isEmpty else { return false }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: pixelWidth * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    func releasedBuffer() {
        if pending { present() }
    }
}
