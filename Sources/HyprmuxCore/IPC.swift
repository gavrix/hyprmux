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

/// Surface kinds `new-surface` opens. The names match the `kind` field of `surfaces`.
/// `app` launches a client app (docs/CLIENT_PROTOCOL.md); the reply waits for its window.
public enum SurfaceKind: String, Equatable, Sendable, CaseIterable {
    case terminal, web, app
}

/// `new-surface`: what to open, where, and whether it takes focus.
public struct NewSurfaceRequest: Equatable, Sendable {
    public var kind: SurfaceKind
    /// Nil: the focused window's workspace, as a bind opens it.
    public var workspace: WorkspaceTarget?
    /// False keeps focus and the visible workspace as they are.
    public var focus: Bool
    public var floating: Bool
    /// Terminal: a command to run instead of the login shell (empty: the shell).
    /// Web: a URL or search terms (empty: the start page).
    /// App: an executable, an `.app`, or a bundle id, then its arguments.
    public var argument: String
    /// Terminal only. Nil: the focused terminal's directory, as a bind does.
    public var cwd: String?
    /// Terminal only: typed into the shell as its first input, e.g. "npm test\n".
    public var input: String?

    public init(kind: SurfaceKind = .terminal, workspace: WorkspaceTarget? = nil, focus: Bool = false,
                floating: Bool = false, argument: String = "", cwd: String? = nil, input: String? = nil) {
        self.kind = kind
        self.workspace = workspace
        self.focus = focus
        self.floating = floating
        self.argument = argument
        self.cwd = cwd
        self.input = input
    }
}

/// `broker` subcommands: the client-protocol broker's launch agent (docs/CLIENT_PROTOCOL.md).
public enum BrokerAction: String, Equatable, Sendable, CaseIterable {
    case status, register, unregister
}

/// Minimal line protocol, modeled on hyprctl. Replies are JSON, plain text,
/// `ok`, or `error: ...`. New surface commands accept explicit surface handles.
/// Free text that may contain spaces travels as `--NAME-base64` (or `--base64` for
/// the main text), because the line is split on whitespace.
public enum IPCRequest: Equatable {
    /// A dispatcher. With a surface it acts on that window instead of the focused one.
    case dispatch(Dispatcher, surface: SurfaceReference?)
    case newSurface(NewSurfaceRequest)
    case closeSurface(SurfaceReference?)
    case focusSurface(SurfaceReference?)
    /// Moves a surface (its whole group) to a workspace. `focus` follows it there.
    case moveSurface(surface: SurfaceReference?, workspace: WorkspaceTarget, focus: Bool)
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
    /// Reads the terminal's most recent mouse selection without using the clipboard.
    case readSelection(surface: SurfaceReference?, json: Bool)
    case sendSurfaceText(surface: SurfaceReference?, text: String)
    case sendSurfaceKey(surface: SurfaceReference?, key: TerminalKey)
    /// Mouse drag in monitor coordinates (top-left origin). Button: 272 left, 273 right.
    case sendDrag(Modifiers, button: Int, from: CGPoint, to: CGPoint)
    /// One mouse event (down / drag / up), for holds and hand-timed gestures.
    case sendMouse(phase: String, Modifiers, button: Int, at: CGPoint)
    /// A notched mouse-wheel scroll of `lines` (positive scrolls up) at a point, for tests.
    case sendScroll(Modifiers, lines: Int, at: CGPoint)
    /// Writes an app tile's current frame to a PNG at `path`, for tests and bug reports.
    case snapshot(surface: SurfaceReference?, path: String)
    /// An agent says how to bring its terminal back: `resume {"client":…, ...}`.
    case resume(ResumeReport)
    /// Demo recordings: a caption at the top of the window. Empty clears it.
    case caption(String)
    /// Tests: performs a main-menu item by title, as a click on it would.
    case sendMenu(String)
    /// The adapter registry: adapters, launched instances, and manifest errors.
    case adapters
    /// Rescans the adapter directories.
    case adaptersReload
    /// Which adapter would lift an app (`.app` path or bundle id), with its probe.
    case adaptersMatch(String)
    /// The broker agent: its status, or register / unregister it with macOS.
    case broker(BrokerAction)
    /// The app catalog (docs/APPS.md): every `.hmapp`, load errors, and the folders.
    case apps
    /// Regenerates the generated apps; the reply waits for it.
    case appsRefresh
    /// Writes an installed `.hmapp`: NAME, PATH, then default arguments.
    case appsAdd([String])
    /// Opens a catalog app in a new tile: NAME or ID, then arguments.
    /// `window`: the offered window to open (`--window ID`).
    case launch([String], focus: Bool, window: String?)

    public static func parse(_ line: String) -> Result<IPCRequest, ParseError> {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let (cmd, rest): (String, String) = {
            guard let sp = trimmed.firstIndex(of: " ") else { return (trimmed, "") }
            return (String(trimmed[..<sp]), String(trimmed[trimmed.index(after: sp)...]))
        }()
        switch cmd {
        case "dispatch":
            return parseDispatch(rest)
        case "new-surface":
            return parseNewSurface(rest)
        case "close-surface", "focus-surface":
            var args = words(rest)
            switch takeOption("--surface", from: &args) {
            case .failure(let error): return .failure(error)
            case .success(let value):
                guard args.isEmpty else { return .failure(ParseError("\(cmd): unexpected arguments")) }
                return parseSurface(value).map { cmd == "close-surface" ? .closeSurface($0) : .focusSurface($0) }
            }
        case "move-surface":
            var args = words(rest)
            let surface: SurfaceReference?
            let workspace: WorkspaceTarget?
            switch takeOption("--surface", from: &args).flatMap(parseSurface) {
            case .failure(let error): return .failure(error)
            case .success(let value): surface = value
            }
            switch takeWorkspace(from: &args) {
            case .failure(let error): return .failure(error)
            case .success(let value): workspace = value
            }
            let focus = removeFlag("--focus", from: &args)
            let noFocus = removeFlag("--no-focus", from: &args)
            guard !(focus && noFocus) else { return .failure(ParseError("move-surface: --focus and --no-focus conflict")) }
            guard args.isEmpty else { return .failure(ParseError("move-surface: unexpected arguments")) }
            guard let workspace else { return .failure(ParseError("move-surface: expected --workspace")) }
            return .success(.moveSurface(surface: surface, workspace: workspace, focus: focus))
        case "clients": return .success(.clients)
        case "surfaces": return .success(.surfaces)
        case "snapshot":
            // snapshot [--surface S] --base64 PATH
            var args = words(rest)
            let surface: SurfaceReference?
            switch takeOption("--surface", from: &args).flatMap(parseSurface) {
            case .failure(let error): return .failure(error)
            case .success(let value): surface = value
            }
            guard args.count == 2, args[0] == "--base64", let path = decodeBase64(args[1]), path.hasPrefix("/") else {
                return .failure(ParseError("snapshot: expected an absolute PNG path"))
            }
            return .success(.snapshot(surface: surface, path: path))
        case "identify":
            var args = words(rest)
            switch takeOption("--surface", from: &args) {
            case .failure(let error): return .failure(error)
            case .success(let value):
                guard args.isEmpty else { return .failure(ParseError("identify: unexpected arguments")) }
                return parseSurface(value).map { .identify($0) }
            }
        case "read-selection":
            var args = words(rest)
            let surfaceValue: String?
            switch takeOption("--surface", from: &args) {
            case .failure(let error): return .failure(error)
            case .success(let value): surfaceValue = value
            }
            let wantsJSON = removeFlag("--json", from: &args)
            guard args.isEmpty else { return .failure(ParseError("read-selection: unexpected arguments")) }
            return parseSurface(surfaceValue).map { .readSelection(surface: $0, json: wantsJSON) }
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
        case "adapters":
            var args = words(rest)
            guard let sub = args.first else { return .success(.adapters) }
            args.removeFirst()
            switch sub {
            case "list":
                guard args.isEmpty else { return .failure(ParseError("adapters list: unexpected arguments")) }
                return .success(.adapters)
            case "reload":
                guard args.isEmpty else { return .failure(ParseError("adapters reload: unexpected arguments")) }
                return .success(.adaptersReload)
            case "match":
                // The target may hold spaces, so it travels as --base64.
                if args.count == 2, args[0] == "--base64" {
                    guard let target = decodeBase64(args[1]), !target.isEmpty else {
                        return .failure(ParseError("adapters match: invalid base64 target"))
                    }
                    return .success(.adaptersMatch(target))
                }
                guard args.count == 1 else { return .failure(ParseError("adapters match: expected one app")) }
                return .success(.adaptersMatch(args[0]))
            default:
                return .failure(ParseError("adapters: expected list, match, or reload"))
            }
        case "broker":
            let args = words(rest)
            guard let sub = args.first else { return .success(.broker(.status)) }
            guard let action = BrokerAction(rawValue: sub) else {
                return .failure(ParseError("broker: expected status, register, or unregister"))
            }
            guard args.count == 1 else { return .failure(ParseError("broker \(sub): unexpected arguments")) }
            return .success(.broker(action))
        case "apps":
            var args = words(rest)
            guard let sub = args.first else { return .success(.apps) }
            args.removeFirst()
            switch sub {
            case "list":
                guard args.isEmpty else { return .failure(ParseError("apps list: unexpected arguments")) }
                return .success(.apps)
            case "refresh":
                guard args.isEmpty else { return .failure(ParseError("apps refresh: unexpected arguments")) }
                return .success(.appsRefresh)
            case "add":
                // NAME PATH [ARGS...], shell-quoted, as --base64: names and paths hold spaces.
                guard args.count == 2, args[0] == "--base64", let text = decodeBase64(args[1]),
                      let parts = shellWords(text) else {
                    return .failure(ParseError("apps add: expected --base64 with NAME PATH [ARGS...]"))
                }
                guard parts.count >= 2 else { return .failure(ParseError("apps add: expected NAME PATH [ARGS...]")) }
                return .success(.appsAdd(parts))
            default:
                return .failure(ParseError("apps: expected list, refresh, or add"))
            }
        case "launch":
            // launch [--focus] [--window ID] (--base64 B64 | NAME [ARGS...]), shell-quoted words.
            var args = words(rest)
            let focus = removeFlag("--focus", from: &args)
            let window: String?
            switch takeOption("--window", from: &args) {
            case .failure(let error): return .failure(error)
            case .success(let value): window = value
            }
            let text: String
            switch takeOption("--base64", from: &args) {
            case .failure(let error): return .failure(error)
            case .success(let encoded?):
                guard args.isEmpty, let decoded = decodeBase64(encoded) else {
                    return .failure(ParseError("launch: invalid base64 text"))
                }
                text = decoded
            case .success(nil):
                text = args.joined(separator: " ")
            }
            guard let parts = shellWords(text) else { return .failure(ParseError("launch: unbalanced quotes")) }
            guard !parts.isEmpty else { return .failure(ParseError("launch: name an app")) }
            return .success(.launch(parts, focus: focus, window: window))
        case "version": return .success(.version)
        case "debug": return .success(.debug)
        case "caption": return .success(.caption(rest))
        case "sendmenu":
            let title = rest.trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return .failure(ParseError("sendmenu: name a menu item")) }
            return .success(.sendMenu(title))
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
        case "sendscroll":
            // sendscroll MODS, LINES, x y
            let p = rest.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            let xy = p.count == 3 ? p[2].split(separator: " ").compactMap { Double($0) } : []
            guard p.count == 3, case .success(let m) = Modifiers.parse(p[0]), let lines = Int(p[1]), xy.count == 2 else {
                return .failure(ParseError("sendscroll: expected 'MODS, lines, x y'"))
            }
            return .success(.sendScroll(m, lines: lines, at: CGPoint(x: xy[0], y: xy[1])))
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

    /// `dispatch [--surface S] NAME ARGS`. Only options before the name count, so a
    /// dispatcher's own arguments (an `exec` command line) pass through untouched.
    private static func parseDispatch(_ rest: String) -> Result<IPCRequest, ParseError> {
        var body = Substring(rest)
        var surface: SurfaceReference?
        func nextWord() -> String {
            body = body.drop(while: { $0.isWhitespace })
            let word = body.prefix(while: { !$0.isWhitespace })
            body = body.dropFirst(word.count)
            return String(word)
        }
        var name = nextWord()
        if name == "--surface" || name.hasPrefix("--surface=") {
            let value = name == "--surface" ? nextWord() : String(name.dropFirst("--surface=".count))
            switch SurfaceReference.parse(value) {
            case .failure(let error): return .failure(error)
            case .success(let reference): surface = reference
            }
            name = nextWord()
        }
        guard !name.isEmpty else { return .failure(ParseError("dispatch: expected a dispatcher")) }
        // The dispatcher's arguments start after the one space that ends its name.
        let args = body.first == " " ? String(body.dropFirst()) : String(body)
        return Dispatcher.parse(name, args).flatMap { d in
            if surface != nil, !d.targetsWindow {
                return .failure(ParseError("dispatch: \(name) does not act on a surface"))
            }
            return .success(.dispatch(d, surface: surface))
        }
    }

    /// `new-surface [--type KIND] [--workspace WS] [--focus] [--floating] [--cwd DIR]
    /// [--input-base64 B64] [--base64 B64 | [--] ARGUMENT...]`.
    private static func parseNewSurface(_ rest: String) -> Result<IPCRequest, ParseError> {
        var args = words(rest)
        // Everything after `--` is the argument, even words that look like options.
        var positional: [String] = []
        if let end = args.firstIndex(of: "--") {
            positional = Array(args[(end + 1)...])
            args.removeSubrange(end...)
        }
        var request = NewSurfaceRequest()
        switch takeOption("--type", from: &args) {
        case .failure(let error): return .failure(error)
        case .success(let value?):
            guard let kind = SurfaceKind(rawValue: value.lowercased()) else {
                let kinds = SurfaceKind.allCases.map(\.rawValue).joined(separator: ", ")
                return .failure(ParseError("new-surface: --type must be one of \(kinds)"))
            }
            request.kind = kind
        case .success(nil): break
        }
        switch takeWorkspace(from: &args) {
        case .failure(let error): return .failure(error)
        case .success(let value): request.workspace = value
        }
        switch takeText("--cwd", from: &args) {
        case .failure(let error): return .failure(error)
        case .success(let value): request.cwd = value
        }
        switch takeText("--input", from: &args) {
        case .failure(let error): return .failure(error)
        case .success(let value): request.input = value
        }
        let encoded: String?
        switch takeOption("--base64", from: &args) {
        case .failure(let error): return .failure(error)
        case .success(let value): encoded = value
        }
        request.focus = removeFlag("--focus", from: &args)
        let noFocus = removeFlag("--no-focus", from: &args)
        guard !(request.focus && noFocus) else { return .failure(ParseError("new-surface: --focus and --no-focus conflict")) }
        request.floating = removeFlag("--floating", from: &args)
        if let option = args.first(where: { $0.hasPrefix("--") }) {
            return .failure(ParseError("new-surface: unknown option \(option)"))
        }
        positional = args + positional
        if let encoded {
            guard positional.isEmpty else { return .failure(ParseError("new-surface: --base64 and a plain argument conflict")) }
            guard let text = decodeBase64(encoded) else { return .failure(ParseError("new-surface: invalid base64 argument")) }
            request.argument = text
        } else {
            request.argument = positional.joined(separator: " ")
        }
        if request.kind != .terminal, request.cwd != nil || request.input != nil {
            return .failure(ParseError("new-surface: --cwd and --input are for terminals"))
        }
        return .success(.newSurface(request))
    }

    /// `--workspace WS` or `--workspace-base64 B64`, in Hyprland workspace syntax.
    private static func takeWorkspace(from args: inout [String]) -> Result<WorkspaceTarget?, ParseError> {
        takeText("--workspace", from: &args).flatMap { value in
            guard let value else { return .success(nil) }
            guard let target = WorkspaceTarget(hyprland: value) else {
                return .failure(ParseError("invalid workspace '\(value)'"))
            }
            return .success(target)
        }
    }

    /// A free-text option, given plainly (`--cwd /tmp`) or encoded (`--cwd-base64 L3RtcA==`).
    private static func takeText(_ name: String, from args: inout [String]) -> Result<String?, ParseError> {
        let plain: String?
        let encoded: String?
        switch takeOption(name, from: &args) {
        case .failure(let error): return .failure(error)
        case .success(let value): plain = value
        }
        switch takeOption(name + "-base64", from: &args) {
        case .failure(let error): return .failure(error)
        case .success(let value): encoded = value
        }
        switch (plain, encoded) {
        case (nil, nil): return .success(nil)
        case (let value?, nil): return .success(value)
        case (nil, let value?):
            guard let text = decodeBase64(value) else { return .failure(ParseError("\(name)-base64: invalid base64")) }
            return .success(text)
        default: return .failure(ParseError("\(name): specified more than once"))
        }
    }

    private static func decodeBase64(_ value: String) -> String? {
        Data(base64Encoded: value).map { String(decoding: $0, as: UTF8.self) }
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
