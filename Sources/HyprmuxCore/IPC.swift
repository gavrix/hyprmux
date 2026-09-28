import CoreGraphics
import Foundation

/// Where the control socket lives. Child shells get HYPRMUX_SOCKET so
/// `hyprmuxctl` talks to the instance it runs in.
public enum IPCPath {
    public static var `default`: String {
        if let p = ProcessInfo.processInfo.environment["HYPRMUX_SOCKET"], !p.isEmpty { return p }
        return "/tmp/hyprmux-\(getuid())/hyprmux.sock"
    }
}

/// Minimal line protocol, modeled on hyprctl:
///   dispatch <dispatcher> [args]   clients   workspaces   activewindow
///   reload   version   sendtext <text>   sendkey <MODS>, <key>
/// Replies are JSON or "ok" / "error: ...".
public enum IPCRequest: Equatable {
    case dispatch(Dispatcher)
    case clients
    case workspaces
    case activeWindow
    case reload
    case version
    /// Focus internals: app active, key window, first responder.
    case debug
    /// Which view would receive a click at a point (monitor coordinates).
    case hitTest(CGPoint)
    case sendText(String)
    case sendKey(Modifiers, UInt16)
    /// Mouse drag in monitor coordinates (top-left origin). Button: 272 left, 273 right.
    case sendDrag(Modifiers, button: Int, from: CGPoint, to: CGPoint)
    /// One mouse event (down / drag / up), for holds and hand-timed gestures.
    case sendMouse(phase: String, Modifiers, button: Int, at: CGPoint)
    /// An agent says how to bring its terminal back: `resume {"client":…, "pid":…, "kind":…, "session":…}`.
    case resume(ResumeReport)

    public static func parse(_ line: String) -> Result<IPCRequest, ParseError> {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let (cmd, rest): (String, String) = {
            guard let sp = trimmed.firstIndex(of: " ") else { return (trimmed, "") }
            return (String(trimmed[..<sp]), String(trimmed[trimmed.index(after: sp)...]))
        }()
        switch cmd {
        case "dispatch":
            let (name, args): (String, String) = {
                guard let sp = rest.firstIndex(of: " ") else { return (rest, "") }
                return (String(rest[..<sp]), String(rest[rest.index(after: sp)...]))
            }()
            return Dispatcher.parse(name, args).map { .dispatch($0) }
        case "clients": return .success(.clients)
        case "workspaces": return .success(.workspaces)
        case "activewindow": return .success(.activeWindow)
        case "reload": return .success(.reload)
        case "version": return .success(.version)
        case "debug": return .success(.debug)
        case "resume":
            guard let r = try? JSONDecoder().decode(ResumeReport.self, from: Data(rest.utf8)) else {
                return .failure(ParseError("resume: expected JSON with client, pid, kind, session"))
            }
            return .success(.resume(r))
        case "hittest":
            let n = rest.split(separator: " ").compactMap { Double($0) }
            guard n.count == 2 else { return .failure(ParseError("hittest: expected 'x y'")) }
            return .success(.hitTest(CGPoint(x: n[0], y: n[1])))
        case "sendtext": return .success(.sendText(rest.replacingOccurrences(of: "\\n", with: "\n")))
        case "sendkey":
            // Keep empty pieces: ", g" means no modifiers.
            let parts = rest.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { return .failure(ParseError("sendkey: expected 'MODS, key'")) }
            guard case .success(let m) = Modifiers.parse(parts[0]) else { return .failure(ParseError("sendkey: bad mods")) }
            guard case .key(let k)? = KeyCodes.parse(parts[1]) else { return .failure(ParseError("sendkey: bad key")) }
            return .success(.sendKey(m, k))
        case "sendmouse":
            // sendmouse down|drag|up MODS, button, x y
            guard let sp = rest.firstIndex(of: " ") else { return .failure(ParseError("sendmouse: expected 'down|drag|up MODS, button, x y'")) }
            let phase = String(rest[..<sp]).lowercased()
            let p = rest[rest.index(after: sp)...].split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let xy = p.count == 3 ? p[2].split(separator: " ").compactMap { Double($0) } : []
            guard ["down", "drag", "up", "move"].contains(phase), p.count == 3, case .success(let m) = Modifiers.parse(p[0]),
                  let b = Int(p[1]), xy.count == 2 else {
                return .failure(ParseError("sendmouse: expected 'down|drag|up MODS, button, x y'"))
            }
            return .success(.sendMouse(phase: phase, m, button: b, at: CGPoint(x: xy[0], y: xy[1])))
        case "senddrag":
            // senddrag MODS, 273, x1 y1, x2 y2
            let p = rest.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            func pt(_ s: String) -> CGPoint? {
                let n = s.split(separator: " ").compactMap { Double($0) }
                return n.count == 2 ? CGPoint(x: n[0], y: n[1]) : nil
            }
            guard p.count == 4, case .success(let m) = Modifiers.parse(p[0]), let b = Int(p[1]),
                  let a = pt(p[2]), let z = pt(p[3]) else {
                return .failure(ParseError("senddrag: expected 'MODS, button, x1 y1, x2 y2'"))
            }
            return .success(.sendDrag(m, button: b, from: a, to: z))
        default:
            return .failure(ParseError("unknown command '\(cmd)'"))
        }
    }
}
