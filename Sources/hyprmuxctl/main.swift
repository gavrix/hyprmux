import Foundation
import HyprmuxCore

// hyprctl-style client for the Hyprmux control socket.

struct CLIError: Error {
    let message: String
}

let args = Array(CommandLine.arguments.dropFirst())

guard !args.isEmpty, args[0] != "-h", args[0] != "--help" else {
    print("""
    usage: hyprmuxctl <command> [args]
      dispatch [--surface <id>] <dispatcher> [args]
                                      run a dispatcher (same names as bind lines); window
                                      dispatchers act on --surface instead of the focused one
      clients | surfaces             list every managed surface as JSON
      identify [--surface <id>]      describe the caller, target, or focused surface
      new-surface [--type terminal|web|sim|android|app] [--workspace <ws>] [--focus] [--floating]
                  [--cwd <dir>] [--input <text>] [[--] <command | url | device | app>]
                                      open a surface and print it as JSON; it takes focus
                                      only with --focus
      close-surface [--surface <id>]  close a surface
      focus-surface [--surface <id>]  focus a surface, switching to its workspace
      move-surface [--surface <id>] --workspace <ws> [--focus]
                                      move a surface (and its group) to a workspace
      read-screen [--surface <id>] [--scrollback] [--lines N] [--json]
      read-selection [--surface <id>] [--json]
                                      read the terminal's most recent mouse selection
      send [--surface <id>] <text>   type text into a terminal; reads stdin when omitted
      send-key [--surface <id>] <key>  send a terminal key, e.g. ctrl+c or enter
      skill install|status|path|source|uninstall [--force]
                                      manage the bundled agent skill locally
      apps [list | refresh] [--json]  the apps Hyprmux can open (.hmapp bundles), load errors,
                                      and their folders; refresh regenerates the generated ones
      apps add <name> <path> [args]  install an app: an .app (checked like generated ones) or
                                      an executable, with default arguments
      launch [--focus] <name | id> [args]
                                      open an app in a new tile and print it as JSON
      adapters [list | match <app> | reload] [--json]
                                      the adapter registry: what Hyprmux loaded, which adapter
                                      would lift an app (with its probe), and running instances
      broker [status | register | unregister] [--json]
                                      the helper app tiles connect through: whether macOS runs it,
                                      which program launchd starts, and this instance's registration;
                                      register / unregister its launch agent with macOS
      workspaces | activewindow | version
      reload                         reload the config
      sendtext <text>                legacy: type into the focused terminal (\\n = enter)
      sendkey <MODS>, <key>          legacy: inject through the app input path
      senddrag <MODS>, <button>, <x1 y1>, <x2 y2>   inject a mouse drag
      sendscroll <MODS>, <lines>, <x y>    inject a notched mouse-wheel scroll (positive = up)
      snapshot [--surface <id>] <file.png>  write an app tile's current frame to a PNG
      sendmenu <title>               perform a menu item by title, e.g. "Open App..."
    """)
    exit(args.isEmpty ? 1 : 0)
}

let maximumSendBytes = 750 * 1024
let maximumResponseBytes = 64 * 1024 * 1024

func skillSourceURL() throws -> URL {
    let environment = ProcessInfo.processInfo.environment
    var candidates: [URL] = []
    if let value = environment["HYPRMUX_SKILL_PATH"], !value.isEmpty {
        candidates.append(URL(fileURLWithPath: value))
    }
    if let executable = Bundle.main.executableURL {
        candidates.append(
            executable.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/skills/hyprmuxctl/SKILL.md")
        )
    }
    candidates.append(
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".agents/skills/hyprmuxctl/SKILL.md")
    )

    for candidate in candidates {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else { continue }
        return isDirectory.boolValue ? candidate.appendingPathComponent("SKILL.md") : candidate
    }
    throw CLIError(message: "cannot find the bundled agent skill; run this command inside Hyprmux")
}

func skillUsage() -> String {
    """
    usage: hyprmuxctl skill <command>
      install [--force]   install or update ~/.agents/skills/hyprmuxctl/SKILL.md
      status              show whether the installed skill matches this Hyprmux version
      path                print the global installation path
      source              print the bundled skill path
      uninstall [--force] remove the globally installed skill
    """
}

func forceOption(_ arguments: [String]) throws -> Bool {
    guard arguments.allSatisfy({ $0 == "--force" }), arguments.count <= 1 else {
        throw CLIError(message: "only --force is accepted")
    }
    return arguments == ["--force"]
}

func runSkillCommand(_ arguments: [String]) throws -> Int32 {
    guard let command = arguments.first, command != "-h", command != "--help" else {
        print(skillUsage())
        return arguments.isEmpty ? 1 : 0
    }
    let commandArguments = Array(arguments.dropFirst())
    let destination = AgentSkillInstaller.destination()
    switch command {
    case "install":
        let changed = try AgentSkillInstaller.install(
            source: skillSourceURL(),
            destination: destination,
            force: forceOption(commandArguments)
        )
        print("\(changed ? "installed" : "already installed") \(destination.path)")
        print("New agent sessions discover it automatically. Run /reload in an existing Pi session.")
        return 0
    case "status":
        guard commandArguments.isEmpty else { throw CLIError(message: "skill status takes no arguments") }
        let status = try AgentSkillInstaller.status(source: skillSourceURL(), destination: destination)
        switch status {
        case .notInstalled:
            print("not installed: \(destination.path)")
            return 1
        case .current:
            print("installed and current: \(destination.path)")
            return 0
        case .outdated:
            print("installed but outdated: \(destination.path)")
            return 1
        case .unmanaged:
            print("unmanaged skill exists: \(destination.path)")
            return 1
        }
    case "path":
        guard commandArguments.isEmpty else { throw CLIError(message: "skill path takes no arguments") }
        print(destination.path)
        return 0
    case "source":
        guard commandArguments.isEmpty else { throw CLIError(message: "skill source takes no arguments") }
        print(try skillSourceURL().path)
        return 0
    case "uninstall":
        let changed = try AgentSkillInstaller.uninstall(
            destination: destination,
            force: forceOption(commandArguments)
        )
        print("\(changed ? "removed" : "not installed") \(destination.path)")
        return 0
    default:
        throw CLIError(message: "unknown skill command \(command)\n\(skillUsage())")
    }
}

if args.first == "skill" {
    do {
        exit(try runSkillCommand(Array(args.dropFirst())))
    } catch let error as CLIError {
        FileHandle.standardError.write("hyprmuxctl: \(error.message)\n".data(using: .utf8)!)
        exit(1)
    } catch {
        FileHandle.standardError.write("hyprmuxctl: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
}

func callerSurface() -> String? {
    let env = ProcessInfo.processInfo.environment
    return env["HYPRMUX_SURFACE_ID"].flatMap { $0.isEmpty ? nil : $0 }
        ?? env["HYPRMUX_CLIENT"].flatMap { $0.isEmpty ? nil : $0 }
}

func validatedSurface(_ value: String) throws -> String {
    switch SurfaceReference.parse(value) {
    case .success: return value
    case .failure(let error): throw CLIError(message: error.description)
    }
}

func takeSurface(from arguments: [String]) throws -> (surface: String?, remaining: [String]) {
    var surface: String?
    var remaining: [String] = []
    var index = 0
    var optionsEnded = false
    while index < arguments.count {
        let argument = arguments[index]
        if argument == "--" {
            optionsEnded = true
            remaining.append(argument)
            index += 1
        } else if !optionsEnded, argument == "--surface" {
            guard surface == nil, index + 1 < arguments.count else {
                throw CLIError(message: "--surface requires one value")
            }
            surface = try validatedSurface(arguments[index + 1])
            index += 2
        } else if !optionsEnded, argument.hasPrefix("--surface=") {
            guard surface == nil else { throw CLIError(message: "--surface specified more than once") }
            surface = try validatedSurface(String(argument.dropFirst("--surface=".count)))
            index += 1
        } else {
            remaining.append(argument)
            index += 1
        }
    }
    return (surface, remaining)
}

func targetArguments(_ surface: String?) -> [String] {
    guard let surface = surface ?? callerSurface() else { return [] }
    return ["--surface", surface]
}

func encodedText(_ value: String) -> String { Data(value.utf8).base64EncodedString() }

/// Splits `--name=value` into its parts; other arguments come back whole.
func splitOption(_ argument: String) -> (name: String, inline: String?) {
    guard argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") else { return (argument, nil) }
    return (String(argument[..<equals]), String(argument[argument.index(after: equals)...]))
}

/// Reads the value of the option at `index` (inline or the next argument) and moves past it.
func optionValue(_ name: String, inline: String?, in arguments: [String], at index: inout Int) throws -> String {
    if let inline {
        index += 1
        return inline
    }
    guard index + 1 < arguments.count else { throw CLIError(message: "\(name) requires a value") }
    index += 2
    return arguments[index - 1]
}

/// Relative directories are relative to the caller, not to Hyprmux.
func absolutePath(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    return URL(fileURLWithPath: expanded, relativeTo: base).standardizedFileURL.path
}

/// Free text goes over the wire base64-encoded, because the protocol splits lines on spaces.
/// Options end at `--` or at the first plain word, which starts the command, URL, or device.
func newSurfaceLine(_ arguments: [String]) throws -> String {
    var wire = ["new-surface"]
    var positional: [String] = []
    var kind = "terminal"
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        if argument == "--" {
            positional = Array(arguments[(index + 1)...])
            break
        }
        let (name, inline) = splitOption(argument)
        switch name {
        case "--type":
            kind = try optionValue(name, inline: inline, in: arguments, at: &index)
            wire += ["--type", kind]
        case "--workspace":
            wire += ["--workspace-base64", encodedText(try optionValue(name, inline: inline, in: arguments, at: &index))]
        case "--cwd":
            let directory = absolutePath(try optionValue(name, inline: inline, in: arguments, at: &index))
            wire += ["--cwd-base64", encodedText(directory)]
        case "--input":
            let text = IPCText.unescape(try optionValue(name, inline: inline, in: arguments, at: &index))
            wire += ["--input-base64", encodedText(text)]
        case "--focus", "--no-focus", "--floating":
            guard inline == nil else { throw CLIError(message: "\(name) takes no value") }
            wire.append(name)
            index += 1
        default:
            guard !argument.hasPrefix("--") else { throw CLIError(message: "new-surface: unknown option \(argument)") }
            positional = Array(arguments[index...])
            index = arguments.count
        }
    }
    // App tiles take argv, like exec: quote each word so paths with spaces survive the
    // compositor's shell-word split. Other kinds keep taking a joined command line.
    let text = kind == "app" ? positional.map(shellQuote).joined(separator: " ") : positional.joined(separator: " ")
    if !text.isEmpty { wire += ["--base64", encodedText(text)] }
    return wire.joined(separator: " ")
}

func moveSurfaceLine(_ arguments: [String]) throws -> String {
    let parsed = try takeSurface(from: arguments)
    var wire = ["move-surface"] + targetArguments(parsed.surface)
    var workspace: String?
    var index = 0
    let rest = parsed.remaining
    while index < rest.count {
        let (name, inline) = splitOption(rest[index])
        switch name {
        case "--workspace":
            guard workspace == nil else { throw CLIError(message: "--workspace specified more than once") }
            workspace = try optionValue(name, inline: inline, in: rest, at: &index)
        case "--focus", "--no-focus":
            guard inline == nil else { throw CLIError(message: "\(name) takes no value") }
            wire.append(name)
            index += 1
        default:
            throw CLIError(message: "move-surface: unexpected argument \(rest[index])")
        }
    }
    guard let workspace else { throw CLIError(message: "move-surface requires --workspace") }
    return (wire + ["--workspace-base64", encodedText(workspace)]).joined(separator: " ")
}

/// `dispatch` names a surface only explicitly, before the dispatcher. Without one, window
/// dispatchers act on the focused window, as they always have.
func dispatchLine(_ arguments: [String]) throws -> String {
    guard let first = arguments.first else { throw CLIError(message: "dispatch requires a dispatcher") }
    let (name, inline) = splitOption(first)
    guard name == "--surface" else { return (["dispatch"] + arguments).joined(separator: " ") }
    var index = 0
    let surface = try validatedSurface(try optionValue(name, inline: inline, in: arguments, at: &index))
    let rest = Array(arguments[index...])
    guard !rest.isEmpty else { throw CLIError(message: "dispatch requires a dispatcher") }
    return (["dispatch", "--surface", surface] + rest).joined(separator: " ")
}

var unwrapTextResponse: String?
/// `adapters` prints tables unless --json; the reply is always JSON.
var adaptersView: String?

func adaptersLine(_ arguments: [String]) throws -> String {
    var rest = arguments
    let json = rest.contains("--json")
    rest.removeAll { $0 == "--json" }
    let sub = rest.first ?? "list"
    if !rest.isEmpty { rest.removeFirst() }
    if !json { adaptersView = sub }
    switch sub {
    case "list", "reload":
        guard rest.isEmpty else { throw CLIError(message: "adapters \(sub) takes no arguments") }
        return "adapters \(sub)"
    case "match":
        guard rest.count == 1 else { throw CLIError(message: "adapters match needs one app: a .app path or a bundle id") }
        var target = rest[0]
        // A relative .app path means the caller's directory, not Hyprmux's.
        if FileManager.default.fileExists(atPath: target) { target = absolutePath(target) }
        return "adapters match --base64 \(encodedText(target))"
    default:
        throw CLIError(message: "adapters: expected list, match, or reload")
    }
}

/// Human-readable `adapters` output.
func renderAdapters(_ view: String, _ data: Data) -> String? {
    guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    func s(_ v: Any?) -> String {
        switch v {
        case let x as String: return x
        case let x as Int: return String(x)
        case let x as Bool: return x ? "yes" : "no"
        case nil, is NSNull: return "-"
        default: return "\(v!)"
        }
    }
    func table(_ rows: [[String]]) -> String {
        guard let first = rows.first else { return "" }
        var widths = first.map(\.count)
        for r in rows { for (i, c) in r.enumerated() where i < widths.count { widths[i] = max(widths[i], c.count) } }
        return rows.map { r in
            r.enumerated().map { i, c in i == r.count - 1 ? c : c.padding(toLength: widths[i], withPad: " ", startingAt: 0) }
                .joined(separator: "  ")
        }.joined(separator: "\n")
    }
    func shortPath(_ p: String) -> String {
        let home = NSHomeDirectory()
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
    var out: [String] = []
    if view == "match" {
        out.append("app        \(s(o["app"]))")
        out.append("bundle id  \(s(o["bundleId"]))")
        let selected = o["selected"] as? String
        out.append("adapter    \(selected ?? "none")")
        if let reason = o["reason"] as? String { out.append("           \(reason)") }
        if let cmd = o["command"] as? [String] {
            out.append("command    \(cmd.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " "))")
        }
        if let p = o["probe"] as? [String: Any] {
            let ok = (p["ok"] as? Bool) == true
            let extra = p.filter { $0.key != "ok" && $0.key != "reason" }.sorted { $0.key < $1.key }
                .map { "\($0.key)=\(s($0.value))" }.joined(separator: " ")
            out.append("probe      \(ok ? "ok" : "FAILED")\(p["reason"].map { ": \(s($0))" } ?? "")\(extra.isEmpty ? "" : "  (\(extra))")")
        }
        let candidates = o["candidates"] as? [[String: Any]] ?? []
        if !candidates.isEmpty {
            out.append("")
            var rows = [["", "ADAPTER", "PRIORITY", "STATE", "WHY"]]
            for c in candidates {
                let mark = (c["id"] as? String) == selected ? "→" : (c["matched"] as? Bool) == true ? "·" : " "
                rows.append([mark, s(c["id"]), s(c["priority"]), s(c["state"]), s(c["reason"])])
            }
            out.append(table(rows))
        }
        return out.joined(separator: "\n") + "\n"
    }
    let adapters = o["adapters"] as? [[String: Any]] ?? []
    var rows = [["ADAPTER", "STATE", "SOURCE", "PRIO", "MATCH", "EXECUTABLE"]]
    for a in adapters {
        let m = a["match"] as? [String: Any] ?? [:]
        var match: [String] = []
        if let ids = m["bundleIds"] as? [String] { match.append(ids.joined(separator: ",")) }
        if let files = m["bundleFiles"] as? [String] { match.append(files.map { ($0 as NSString).lastPathComponent }.joined(separator: ",")) }
        let exe = (a["executable"] as? String).map(shortPath) ?? s(a["problem"])
        rows.append([s(a["id"]), s(a["state"]), s(a["source"]) + (a["overrides"] != nil ? "*" : ""), s(a["priority"]),
                     match.joined(separator: " + "), exe])
    }
    out.append(adapters.isEmpty ? "No adapters loaded." : table(rows))
    if adapters.contains(where: { $0["overrides"] != nil }) { out.append("* overrides a built-in manifest") }
    let errors = o["errors"] as? [[String: Any]] ?? []
    if !errors.isEmpty {
        out.append("")
        out.append("Manifest errors:")
        for e in errors { out.append("  \(shortPath(s(e["path"]))): \(s(e["message"]))") }
    }
    let instances = o["instances"] as? [[String: Any]] ?? []
    out.append("")
    if instances.isEmpty {
        out.append("No adapter processes launched yet.")
    } else {
        var rows = [["#", "ADAPTER", "APP", "PID", "STATE", "TILES", "UPTIME", "NOTE"]]
        for i in instances {
            let tiles = (i["tiles"] as? [Int] ?? []).map(String.init).joined(separator: ",")
            let up = (i["uptime"] as? Int).map { t in t >= 3600 ? "\(t / 3600)h\(t % 3600 / 60)m" : t >= 60 ? "\(t / 60)m\(t % 60)s" : "\(t)s" } ?? "-"
            var note = s(i["failure"] ?? i["lastError"])
            if note == "-", let st = i["exitStatus"] { note = "exit \(s(st))" }
            rows.append([s(i["instance"]), s(i["adapter"]), s(i["label"]), s(i["pid"]), s(i["state"]),
                         tiles.isEmpty ? "-" : tiles, up, note])
        }
        out.append(table(rows))
    }
    if let latest = instances.last, let log = latest["log"] as? String {
        out.append("log of #\(s(latest["instance"])): \(shortPath(log))")
    }
    let dirs = o["directories"] as? [[String: Any]] ?? []
    out.append("")
    for d in dirs {
        out.append("\(s(d["source"])) adapters: \(shortPath(s(d["path"])))\((d["exists"] as? Bool) == true ? "" : " (missing)")")
    }
    return out.joined(separator: "\n") + "\n"
}

/// `broker` prints a summary unless --json; the reply is always JSON.
var brokerView = false

func brokerLine(_ arguments: [String]) throws -> String {
    var rest = arguments
    let json = rest.contains("--json")
    rest.removeAll { $0 == "--json" }
    let sub = rest.first ?? "status"
    guard ["status", "register", "unregister"].contains(sub) else {
        throw CLIError(message: "broker: expected status, register, or unregister")
    }
    guard rest.count <= 1 else { throw CLIError(message: "broker \(sub) takes no arguments") }
    brokerView = !json
    return "broker \(sub)"
}

/// Human-readable `broker` output.
func renderBroker(_ data: Data) -> String? {
    guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    let home = NSHomeDirectory()
    func short(_ p: String) -> String { p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p }
    var rows: [(String, String)] = []
    let agent = o["agent"] as? String ?? "-"
    let agentText: String
    switch agent {
    case "enabled": agentText = "enabled: macOS runs the broker for this copy of Hyprmux"
    case "requires-approval": agentText = "waiting for approval: allow Hyprmux in System Settings → General → Login Items & Extensions"
    case "not-registered": agentText = "not registered"
    case "not-found": agentText = "not registered: macOS doesn't know this copy's agent"
    case "not-bundled": agentText = "not available: Hyprmux isn't running from an app bundle"
    default: agentText = agent
    }
    rows.append(("agent", agentText))
    let outcome = o["outcome"] as? String ?? "-"
    let outcomeText: String
    switch outcome {
    case "other-broker": outcomeText = "skipped: another broker holds the label (dev-broker.sh or another copy)"
    case "disabled": outcomeText = "skipped: misc:register_broker = false"
    case "not-bundled": outcomeText = "skipped: not an app bundle"
    case "failed": outcomeText = "failed: \(o["failure"] as? String ?? "?")"
    case "not-found": outcomeText = "failed: the bundle has no broker launch agent"
    case "not-checked": outcomeText = "not checked yet"
    default: outcomeText = outcome
    }
    rows.append(("on launch", outcomeText))
    rows.append(("lookup", (o["lookup"] as? Bool) == true ? "answers (a broker holds the service name)" : "no broker holds the service name"))
    if let job = o["launchd"] as? [String: Any] {
        var state = job["state"] as? String ?? "?"
        if let pid = job["pid"] { state += ", pid \(pid)" }
        switch job["loadedBy"] as? String {
        case "dev-broker.sh": state += ", loaded by scripts/dev-broker.sh"
        case "app": state += ", registered by an app with SMAppService"
        default: break
        }
        rows.append(("launchd job", state))
        if let exe = job["executable"] as? String {
            rows.append(("program", short(exe)))
        } else if let program = job["program"] as? String {
            rows.append(("program", short(program)))
        }
        if let path = job["path"] as? String, path.hasPrefix("/") { rows.append(("job plist", short(path))) }
        if let parent = job["parentBundle"] as? String { rows.append(("app", parent)) }
    } else {
        rows.append(("launchd job", "none"))
    }
    let instance = o["instance"] as? String ?? "-"
    let registered = (o["registered"] as? Bool) == true
    rows.append(("instance", "\(instance), \(registered ? "registered with the broker" : "not registered with the broker")"))
    rows.append(("clients", "\(o["clients"] as? Int ?? 0) connected"))
    rows.append(("setting", "misc:register_broker = \((o["setting"] as? Bool) == false ? "false" : "true")"))
    let width = rows.map(\.0.count).max() ?? 0
    return rows.map { $0.0.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + $0.1 }.joined(separator: "\n") + "\n"
}

/// `apps` prints tables unless --json; the reply is always JSON.
var appsView: String?

func appsLine(_ arguments: [String]) throws -> String {
    var rest = arguments
    let json = rest.contains("--json")
    rest.removeAll { $0 == "--json" }
    let sub = rest.first ?? "list"
    if !rest.isEmpty { rest.removeFirst() }
    if !json { appsView = sub }
    switch sub {
    case "list", "refresh":
        guard rest.isEmpty else { throw CLIError(message: "apps \(sub) takes no arguments") }
        return "apps \(sub)"
    case "add":
        guard rest.count >= 2 else { throw CLIError(message: "apps add needs a name and a path: an .app or an executable") }
        // A relative path means the caller's directory, not Hyprmux's.
        rest[1] = absolutePath(rest[1])
        return "apps add --base64 \(encodedText(rest.map(shellQuote).joined(separator: " ")))"
    default:
        throw CLIError(message: "apps: expected list, refresh, or add")
    }
}

func launchLine(_ arguments: [String]) throws -> String {
    var rest = arguments
    var wire = ["launch"]
    if rest.first == "--focus" {
        rest.removeFirst()
        wire.append("--focus")
    }
    if rest.first == "--" { rest.removeFirst() }
    guard !rest.isEmpty else { throw CLIError(message: "launch needs an app name or id (hyprmuxctl apps lists them)") }
    return (wire + ["--base64", encodedText(rest.map(shellQuote).joined(separator: " "))]).joined(separator: " ")
}

/// Human-readable `apps` output.
func renderApps(_ view: String, _ data: Data) -> String? {
    guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    func s(_ v: Any?) -> String { (v as? String) ?? "-" }
    func shortPath(_ p: String) -> String {
        let home = NSHomeDirectory()
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
    func table(_ rows: [[String]]) -> String {
        var widths = rows[0].map(\.count)
        for r in rows { for (i, c) in r.enumerated() { widths[i] = max(widths[i], c.count) } }
        return rows.map { r in
            r.enumerated().map { i, c in i == r.count - 1 ? c : c.padding(toLength: widths[i], withPad: " ", startingAt: 0) }
                .joined(separator: "  ")
        }.joined(separator: "\n")
    }
    if view == "add" {
        return "installed \(s(o["name"])) (\(s(o["id"]))): \(s(o["kind"]))\(o["adapter"].map { " (\(s($0)))" } ?? ""), \(shortPath(s(o["path"])))\n"
    }
    var out: [String] = []
    let apps = o["apps"] as? [[String: Any]] ?? []
    if apps.isEmpty {
        out.append((o["generating"] as? Bool) == true ? "No apps yet: Hyprmux is still looking." : "No apps.")
    } else {
        var rows = [["ID", "NAME", "KIND", "SOURCE", "ADAPTER", "APP/EXEC"]]
        for a in apps {
            let target = (a["app"] as? String).map(shortPath) ?? (a["exec"] as? String).map(shortPath) ?? "-"
            rows.append([s(a["id"]), s(a["name"]), s(a["kind"]), s(a["source"]) + (a["overrides"] != nil ? "*" : ""),
                         s(a["adapter"]), target])
        }
        out.append(table(rows))
        if apps.contains(where: { $0["overrides"] != nil }) { out.append("* replaces a generated app") }
    }
    let errors = o["errors"] as? [[String: Any]] ?? []
    if !errors.isEmpty {
        out.append("")
        out.append("Load errors:")
        for e in errors { out.append("  \(shortPath(s(e["path"]))): \(s(e["message"]))") }
    }
    out.append("")
    for d in o["directories"] as? [[String: Any]] ?? [] {
        out.append("\(s(d["source"])) apps: \(shortPath(s(d["path"])))\((d["exists"] as? Bool) == true ? "" : " (missing)")")
    }
    return out.joined(separator: "\n") + "\n"
}

func commandLine() throws -> String {
    let command = args[0]
    let commandArgs = Array(args.dropFirst())
    switch command {
    case "send":
        let parsed = try takeSurface(from: commandArgs)
        var textArguments = parsed.remaining
        if textArguments.first == "--" { textArguments.removeFirst() }
        let text: String
        if textArguments.isEmpty {
            guard isatty(STDIN_FILENO) == 0 else { throw CLIError(message: "send requires text or stdin") }
            let data = try FileHandle.standardInput.read(upToCount: maximumSendBytes + 1) ?? Data()
            guard data.count <= maximumSendBytes else {
                throw CLIError(message: "send input exceeds \(maximumSendBytes) bytes")
            }
            text = String(decoding: data, as: UTF8.self)
        } else {
            text = IPCText.unescape(textArguments.joined(separator: " "))
        }
        guard !text.isEmpty else { throw CLIError(message: "send requires non-empty text") }
        guard text.utf8.count <= maximumSendBytes else {
            throw CLIError(message: "send input exceeds \(maximumSendBytes) bytes")
        }
        let encoded = Data(text.utf8).base64EncodedString()
        return ([command] + targetArguments(parsed.surface) + ["--base64", encoded]).joined(separator: " ")
    case "send-key":
        let parsed = try takeSurface(from: commandArgs)
        var keyArguments = parsed.remaining
        if keyArguments.first == "--" { keyArguments.removeFirst() }
        guard keyArguments.count == 1 else { throw CLIError(message: "send-key requires one key") }
        return ([command] + targetArguments(parsed.surface) + keyArguments).joined(separator: " ")
    case "read-screen":
        let parsed = try takeSurface(from: commandArgs)
        var options = parsed.remaining
        if !options.contains("--json") {
            options.append("--json")
            unwrapTextResponse = command
        }
        return ([command] + targetArguments(parsed.surface) + options).joined(separator: " ")
    case "read-selection":
        let parsed = try takeSurface(from: commandArgs)
        var options = parsed.remaining
        guard options.allSatisfy({ $0 == "--json" }), options.count <= 1 else {
            throw CLIError(message: "read-selection takes only --surface and --json")
        }
        if !options.contains("--json") {
            options.append("--json")
            unwrapTextResponse = command
        }
        return ([command] + targetArguments(parsed.surface) + options).joined(separator: " ")
    case "snapshot":
        let parsed = try takeSurface(from: commandArgs)
        guard parsed.remaining.count == 1 else { throw CLIError(message: "snapshot needs one PNG path") }
        return ([command] + targetArguments(parsed.surface) + ["--base64", encodedText(absolutePath(parsed.remaining[0]))]).joined(separator: " ")
    case "identify":
        let parsed = try takeSurface(from: commandArgs)
        guard parsed.remaining.isEmpty else { throw CLIError(message: "identify takes only --surface") }
        return ([command] + targetArguments(parsed.surface)).joined(separator: " ")
    case "surfaces":
        guard commandArgs.isEmpty else { throw CLIError(message: "surfaces takes no arguments") }
        return command
    case "adapters":
        return try adaptersLine(commandArgs)
    case "apps":
        return try appsLine(commandArgs)
    case "broker":
        return try brokerLine(commandArgs)
    case "launch":
        return try launchLine(commandArgs)
    case "dispatch":
        return try dispatchLine(commandArgs)
    case "new-surface":
        return try newSurfaceLine(commandArgs)
    case "close-surface", "focus-surface":
        let parsed = try takeSurface(from: commandArgs)
        guard parsed.remaining.isEmpty else { throw CLIError(message: "\(command) takes only --surface") }
        return ([command] + targetArguments(parsed.surface)).joined(separator: " ")
    case "move-surface":
        return try moveSurfaceLine(commandArgs)
    default:
        return args.joined(separator: " ")
    }
}

let line: String
do {
    line = try commandLine() + "\n"
} catch let error as CLIError {
    FileHandle.standardError.write("hyprmuxctl: \(error.message)\n".data(using: .utf8)!)
    exit(1)
} catch {
    FileHandle.standardError.write("hyprmuxctl: \(error)\n".data(using: .utf8)!)
    exit(1)
}

let path = IPCPath.default
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { perror("socket"); exit(1) }
var noSigPipe: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout.size(ofValue: noSigPipe)))
var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
_ = withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
    path.utf8CString.withUnsafeBytes { source in
        memcpy(buffer.baseAddress!, source.baseAddress!, min(buffer.count - 1, source.count))
    }
}
let connected = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard connected == 0 else {
    FileHandle.standardError.write("hyprmuxctl: cannot connect to \(path) (is Hyprmux running?)\n".data(using: .utf8)!)
    close(fd)
    exit(1)
}

let request = Data(line.utf8)
let wroteRequest = request.withUnsafeBytes { bytes -> Bool in
    guard let base = bytes.baseAddress else { return true }
    var offset = 0
    while offset < bytes.count {
        let count = write(fd, base.advanced(by: offset), bytes.count - offset)
        if count < 0, errno == EINTR { continue }
        if count <= 0 { return false }
        offset += count
    }
    return true
}
guard wroteRequest else {
    FileHandle.standardError.write("hyprmuxctl: failed to write request\n".data(using: .utf8)!)
    close(fd)
    exit(1)
}
shutdown(fd, SHUT_WR)

var output = Data()
var buffer = [UInt8](repeating: 0, count: 65_536)
while true {
    let count = read(fd, &buffer, buffer.count)
    if count < 0, errno == EINTR { continue }
    if count <= 0 { break }
    guard output.count + count <= maximumResponseBytes else {
        FileHandle.standardError.write("hyprmuxctl: response exceeds \(maximumResponseBytes) bytes\n".data(using: .utf8)!)
        close(fd)
        exit(1)
    }
    output.append(buffer, count: count)
}
close(fd)

let failed = output.starts(with: Data("error:".utf8))
if failed {
    FileHandle.standardError.write(output)
} else if let textCommand = unwrapTextResponse {
    guard let object = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
          let text = object["text"] as? String else {
        FileHandle.standardError.write("hyprmuxctl: invalid \(textCommand) response\n".data(using: .utf8)!)
        exit(1)
    }
    FileHandle.standardOutput.write(Data(text.utf8))
} else if let view = adaptersView, let text = renderAdapters(view, output) {
    FileHandle.standardOutput.write(Data(text.utf8))
} else if let view = appsView, let text = renderApps(view, output) {
    FileHandle.standardOutput.write(Data(text.utf8))
} else if brokerView, let text = renderBroker(output) {
    FileHandle.standardOutput.write(Data(text.utf8))
} else {
    FileHandle.standardOutput.write(output)
}
exit(failed ? 1 : 0)
