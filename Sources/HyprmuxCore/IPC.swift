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

/// An app-global surface handle accepted as either `7` or `surface:7`.
public struct SurfaceReference: Equatable, Hashable, Sendable, CustomStringConvertible {
    public let raw: UInt64

    public init(_ raw: UInt64) { self.raw = raw }

    public var description: String { "surface:\(raw)" }

    public static func parse(_ value: String) -> Result<SurfaceReference, ParseError> {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = trimmed.lowercased().hasPrefix("surface:") ? String(trimmed.dropFirst(8)) : trimmed
        guard let raw = UInt64(number), raw > 0 else {
            return .failure(ParseError("invalid surface '\(value)'"))
        }
        return .success(SurfaceReference(raw))
    }
}

/// A terminal key expressed in cmux-style form: `enter`, `ctrl+c`, `shift+tab`.
public struct TerminalKey: Equatable, Sendable {
    public let modifiers: Modifiers
    public let keyCode: UInt16

    public init(modifiers: Modifiers, keyCode: UInt16) {
        self.modifiers = modifiers
        self.keyCode = keyCode
    }

    public static func parse(_ value: String) -> Result<TerminalKey, ParseError> {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !normalized.contains("+") {
            for prefix in ["ctrl", "control", "shift", "alt", "option", "cmd", "command", "super"] {
                if normalized.hasPrefix(prefix + "-") {
                    normalized.replaceSubrange(normalized.index(normalized.startIndex, offsetBy: prefix.count)..<normalized.index(normalized.startIndex, offsetBy: prefix.count + 1), with: "+")
                    break
                }
            }
        }
        let parts = normalized.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let keyName = parts.last, !keyName.isEmpty,
              case .key(let keyCode)? = KeyCodes.parse(keyName) else {
            return .failure(ParseError("invalid terminal key '\(value)'"))
        }
        let modifierText = parts.dropLast().joined(separator: "+")
        guard case .success(let modifiers) = Modifiers.parse(modifierText) else {
            return .failure(ParseError("invalid terminal key '\(value)'"))
        }
        return .success(TerminalKey(modifiers: modifiers, keyCode: keyCode))
    }
}

public enum IPCText {
    /// cmux-style command-line escapes. Unknown escapes keep their backslash.
    public static func unescape(_ value: String) -> String {
        var result = ""
        var escaped = false
        for character in value {
            if escaped {
                switch character {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "\\": result.append("\\")
                default:
                    result.append("\\")
                    result.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        if escaped { result.append("\\") }
        return result
    }

    /// Returns the last logical lines while preserving a trailing newline.
    public static func tailLines(_ text: String, count: Int) -> String {
        guard count > 0, !text.isEmpty else { return "" }
        let end = text.endIndex
        var scan = end
        // A final newline terminates the last line; it does not create another one.
        if scan > text.startIndex {
            let previous = text.index(before: scan)
            if text[previous] == "\n" { scan = previous }
        }
        var separators = 0
        while scan > text.startIndex {
            let previous = text.index(before: scan)
            if text[previous] == "\n" {
                separators += 1
                if separators == count { return String(text[scan..<end]) }
            }
            scan = previous
        }
        return text
    }
}

/// Minimal line protocol, modeled on hyprctl. Replies are JSON, plain text,
/// `ok`, or `error: ...`. New surface commands accept explicit surface handles.
public enum IPCRequest: Equatable {
    case dispatch(Dispatcher)
    case clients
    case surfaces
    case identify(SurfaceReference?)
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
    case readScreen(surface: SurfaceReference?, scrollback: Bool, lines: Int?, json: Bool)
    case sendSurfaceText(surface: SurfaceReference?, text: String)
    case sendSurfaceKey(surface: SurfaceReference?, key: TerminalKey)
    /// Mouse drag in monitor coordinates (top-left origin). Button: 272 left, 273 right.
    case sendDrag(Modifiers, button: Int, from: CGPoint, to: CGPoint)
    /// One mouse event (down / drag / up), for holds and hand-timed gestures.
    case sendMouse(phase: String, Modifiers, button: Int, at: CGPoint)
    /// An agent says how to bring its terminal back: `resume {"client":…, ...}`.
    case resume(ResumeReport)
    /// Demo recordings: a caption at the top of the window. Empty clears it.
    case caption(String)

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
        case "surfaces": return .success(.surfaces)
        case "identify":
            var args = words(rest)
            switch takeOption("--surface", from: &args) {
            case .failure(let error): return .failure(error)
            case .success(let value):
                guard args.isEmpty else { return .failure(ParseError("identify: unexpected arguments")) }
                return parseSurface(value).map { .identify($0) }
            }
        case "read-screen":
            var args = words(rest)
            let surfaceValue: String?
            let linesValue: String?
            switch takeOption("--surface", from: &args) {
            case .failure(let error): return .failure(error)
            case .success(let value): surfaceValue = value
            }
            switch takeOption("--lines", from: &args) {
            case .failure(let error): return .failure(error)
            case .success(let value): linesValue = value
            }
            let scrollback = removeFlag("--scrollback", from: &args) || linesValue != nil
            let wantsJSON = removeFlag("--json", from: &args)
            guard args.isEmpty else { return .failure(ParseError("read-screen: unexpected arguments")) }
            let lines: Int?
            if let linesValue {
                guard let count = Int(linesValue), count > 0 else {
                    return .failure(ParseError("read-screen: --lines must be greater than 0"))
                }
                lines = count
            } else {
                lines = nil
            }
            return parseSurface(surfaceValue).map {
                .readScreen(surface: $0, scrollback: scrollback, lines: lines, json: wantsJSON)
            }
        case "send":
            var args = words(rest)
            let surfaceValue: String?
            let encoded: String?
            switch takeOption("--surface", from: &args) {
            case .failure(let error): return .failure(error)
            case .success(let value): surfaceValue = value
            }
            switch takeOption("--base64", from: &args) {
            case .failure(let error): return .failure(error)
            case .success(let value): encoded = value
            }
            if args.first == "--" { args.removeFirst() }
            let text: String
            if let encoded {
                guard args.isEmpty, let data = Data(base64Encoded: encoded) else {
                    return .failure(ParseError("send: invalid base64 text"))
                }
                text = String(decoding: data, as: UTF8.self)
            } else {
                text = IPCText.unescape(args.joined(separator: " "))
            }
            guard !text.isEmpty else { return .failure(ParseError("send: expected text")) }
            return parseSurface(surfaceValue).map { .sendSurfaceText(surface: $0, text: text) }
        case "send-key":
            var args = words(rest)
            let surfaceValue: String?
            switch takeOption("--surface", from: &args) {
            case .failure(let error): return .failure(error)
            case .success(let value): surfaceValue = value
            }
            if args.first == "--" { args.removeFirst() }
            guard args.count == 1 else { return .failure(ParseError("send-key: expected one key")) }
            guard case .success(let key) = TerminalKey.parse(args[0]) else {
                return .failure(ParseError("send-key: invalid key '\(args[0])'"))
            }
            return parseSurface(surfaceValue).map { .sendSurfaceKey(surface: $0, key: key) }
        case "workspaces": return .success(.workspaces)
        case "activewindow": return .success(.activeWindow)
        case "reload": return .success(.reload)
        case "version": return .success(.version)
        case "debug": return .success(.debug)
        case "caption": return .success(.caption(rest))
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

    private static func words(_ value: String) -> [String] {
        value.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func takeOption(_ name: String, from args: inout [String]) -> Result<String?, ParseError> {
        var found: String?
        var index = 0
        while index < args.count {
            if args[index] == name {
                guard found == nil, index + 1 < args.count else {
                    return .failure(ParseError("\(name): expected one value"))
                }
                found = args[index + 1]
                args.removeSubrange(index...index + 1)
            } else if args[index].hasPrefix(name + "=") {
                guard found == nil else { return .failure(ParseError("\(name): specified more than once")) }
                found = String(args[index].dropFirst(name.count + 1))
                args.remove(at: index)
            } else {
                index += 1
            }
        }
        return .success(found)
    }

    private static func removeFlag(_ flag: String, from args: inout [String]) -> Bool {
        let present = args.contains(flag)
        args.removeAll { $0 == flag }
        return present
    }

    private static func parseSurface(_ value: String?) -> Result<SurfaceReference?, ParseError> {
        guard let value else { return .success(nil) }
        return SurfaceReference.parse(value).map(Optional.some)
    }
}
