// hyprmux-electron-bridge: a Hyprmux client (docs/CLIENT_PROTOCOL.md) that lifts an
// Electron app into tiles. It launches the app with its main-process inspector open,
// injects Resources/electron-hook.js into it, and speaks the protocol for every
// window: paint bitmaps out, input and native-UI requests in.
//
//   hyprmux-electron-bridge [--adapter vscode|cursor|generic] /path/App.app [app args...]
//   hyprmux-electron-bridge probe /path/App.app [--adapter A]   (adapter registry: can it lift this?)
//   hyprmux-electron-bridge sync-dialog SOCKET KIND WIN_ID OPTIONS_JSON   (hook's blocking dialogs)
import AppKit
import Foundation
import HyprmuxClientKit

/// Logs to stderr with write(2). FileHandle.write raises an Objective-C exception when
/// the reader is gone (Hyprmux quit and closed the pipe), which aborted the bridge.
func stderr(_ s: String) {
    let line = s + "\n"
    line.utf8CString.withUnsafeBufferPointer { p in _ = write(STDERR_FILENO, p.baseAddress, p.count - 1) }
}

/// Debug timing, with HYPRMUX_HOOK_DEBUG: wall-clock ms, comparable with the hook's Date.now().
let tracing = ProcessInfo.processInfo.environment["HYPRMUX_HOOK_DEBUG"] != nil
func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }
func trace(_ s: @autoclosure () -> String) {
    guard tracing else { return }
    stderr(String(format: "t=%.1f ", nowMs().truncatingRemainder(dividingBy: 100_000)) + s())
}

// MARK: sync-dialog subcommand (called with spawnSync from inside the app)

if CommandLine.arguments.count >= 6, CommandLine.arguments[1] == "sync-dialog" {
    let (path, kind, win, optionsJSON) = (CommandLine.arguments[2], CommandLine.arguments[3],
                                          Int(CommandLine.arguments[4]) ?? 0, CommandLine.arguments[5])
    let semaphore = DispatchSemaphore(value: 0)
    var out: [String: Any] = kind == "message" ? ["response": 0, "checkboxChecked": false] : ["canceled": true]
    // A one-shot connection to the bridge's hook socket.
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
    path.withCString { cstr in
        withUnsafeMutableBytes(of: &addr) { raw in
            // sun_path is the bytes right after the family field.
            strncpy(raw.baseAddress!.advanced(by: MemoryLayout.offset(of: \sockaddr_un.sun_path)!).assumingMemoryBound(to: CChar.self), cstr, maxPath - 1)
        }
    }
    var bound = addr
    let rc = withUnsafePointer(to: &bound) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    if rc != 0 { print(String(data: try! JSONSerialization.data(withJSONObject: out), encoding: .utf8)!); exit(0) }
    let conn = UnixChannel.Conn(fd: fd)
    conn.onMessage = { json, _ in
        if let result = json["result"] as? [String: Any] { out = result }
        semaphore.signal()
    }
    conn.start()
    conn.send(["t": "dialog", "win": win, "kind": kind,
               "options": (try? JSONSerialization.jsonObject(with: Data(optionsJSON.utf8))) ?? [:]])
    _ = semaphore.wait(timeout: .now() + 300)
    print(String(data: try! JSONSerialization.data(withJSONObject: out), encoding: .utf8)!)
    exit(0)
}

// MARK: fuses

/// Whether the app's EnableNodeCliInspectArguments fuse is on, or nil when the app has
/// no fuse wire. The wire lives in Electron Framework, not the app's executable: a
/// sentinel, a version byte, a length byte, then one byte per fuse ('0' off, '1' on,
/// 'r' removed). Fuse 3 is EnableNodeCliInspectArguments.
func cliInspectEnabled(appBundle: URL) -> Bool? {
    let framework = appBundle.appendingPathComponent("Contents/Frameworks/Electron Framework.framework/Electron Framework")
    guard let data = try? Data(contentsOf: framework, options: .mappedIfSafe) else { return nil }
    let sentinel = Data("dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX".utf8)
    guard let range = data.range(of: sentinel) else { return nil }
    let start = range.upperBound + 2
    let length = Int(data[range.upperBound + 1])
    guard length > 3, start + 3 < data.count else { return nil }
    return data[start + 3] == UInt8(ascii: "1")
}

// MARK: probe subcommand (docs/ADAPTERS.md)

/// Prints `{"ok": …, "reason": …}` plus details, and exits. Never launches the app.
func probe(_ arguments: [String]) -> Never {
    var args = arguments
    var profile = "generic"
    if let i = args.firstIndex(of: "--adapter"), i + 1 < args.count {
        profile = args[i + 1]
        args.removeSubrange(i...(i + 1))
    }
    var out: [String: Any] = ["profile": profile]
    func finish(_ ok: Bool, _ reason: String?) -> Never {
        out["ok"] = ok
        if let reason { out["reason"] = reason }
        let data = (try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])) ?? Data("{\"ok\":false}".utf8)
        FileHandle.standardOutput.write(data + Data("\n".utf8))
        exit(0)
    }
    guard let path = args.first else { finish(false, "usage: probe App.app [--adapter A]") }
    let app = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    guard let bundle = Bundle(url: app), bundle.executableURL != nil else { finish(false, "\(app.path) isn't an app bundle") }
    let framework = app.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
    guard FileManager.default.fileExists(atPath: framework.path) else { finish(false, "not an Electron app") }
    if let version = Bundle(url: framework)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
        out["electron"] = version
    }
    switch cliInspectEnabled(appBundle: app) {
    case false?:
        out["inspectFuse"] = "off"
        finish(false, "the app disables the main-process inspector (EnableNodeCliInspectArguments fuse)")
    case true?:
        out["inspectFuse"] = "on"
    case nil:
        out["inspectFuse"] = "unknown"
    }
    finish(true, nil)
}

if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "probe" {
    probe(Array(CommandLine.arguments.dropFirst(2)))
}

// MARK: main

struct Options {
    /// The profile from `--adapter`. Adapter manifests always pass one; nil (a manual
    /// run) guesses from the bundle id.
    var adapter: String?
    var appPath = ""
    var appArgs: [String] = []
}

func parseOptions() throws -> Options {
    var args = Array(CommandLine.arguments.dropFirst())
    var o = Options()
    while let first = args.first, first.hasPrefix("--") {
        args.removeFirst()
        if first == "--adapter" {
            guard !args.isEmpty else { throw NSError(domain: "bridge", code: 2, userInfo: [NSLocalizedDescriptionKey: "--adapter needs a value"]) }
            o.adapter = args.removeFirst()
        }
    }
    guard let app = args.first else {
        throw NSError(domain: "bridge", code: 2, userInfo: [NSLocalizedDescriptionKey: "usage: hyprmux-electron-bridge [--adapter A] App.app [args...]"])
    }
    o.appPath = (app as NSString).expandingTildeInPath
    o.appArgs = Array(args.dropFirst())
    return o
}

// Refusals (bad arguments, a fused-off inspector) end with a message, not a trap.
// Hyprmux shows the last stderr line when a launch fails before connecting.
let bridge: Bridge
do { bridge = try Bridge(options: parseOptions()) } catch {
    stderr("hyprmux-electron-bridge: \(error.localizedDescription)")
    exit(1)
}
bridge.run()
dispatchMain()
