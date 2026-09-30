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
      new-surface [--type terminal|web|sim|android] [--workspace <ws>] [--focus] [--floating]
                  [--cwd <dir>] [--input <text>] [[--] <command | url | device>]
                                      open a surface and print it as JSON; it takes focus
                                      only with --focus
      close-surface [--surface <id>]  close a surface
      focus-surface [--surface <id>]  focus a surface, switching to its workspace
      move-surface [--surface <id>] --workspace <ws> [--focus]
                                      move a surface (and its group) to a workspace
      read-screen [--surface <id>] [--scrollback] [--lines N] [--json]
      send [--surface <id>] <text>   type text into a terminal; reads stdin when omitted
      send-key [--surface <id>] <key>  send a terminal key, e.g. ctrl+c or enter
      skill install|status|path|source|uninstall [--force]
                                      manage the bundled agent skill locally
      workspaces | activewindow | version
      reload                         reload the config
      sendtext <text>                legacy: type into the focused terminal (\\n = enter)
      sendkey <MODS>, <key>          legacy: inject through the app input path
      senddrag <MODS>, <button>, <x1 y1>, <x2 y2>   inject a mouse drag
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
            wire += ["--type", try optionValue(name, inline: inline, in: arguments, at: &index)]
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
    let text = positional.joined(separator: " ")
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

var unwrapReadScreenResponse = false

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
            unwrapReadScreenResponse = true
        }
        return ([command] + targetArguments(parsed.surface) + options).joined(separator: " ")
    case "identify":
        let parsed = try takeSurface(from: commandArgs)
        guard parsed.remaining.isEmpty else { throw CLIError(message: "identify takes only --surface") }
        return ([command] + targetArguments(parsed.surface)).joined(separator: " ")
    case "surfaces":
        guard commandArgs.isEmpty else { throw CLIError(message: "surfaces takes no arguments") }
        return command
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
} else if unwrapReadScreenResponse {
    guard let object = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
          let text = object["text"] as? String else {
        FileHandle.standardError.write("hyprmuxctl: invalid read-screen response\n".data(using: .utf8)!)
        exit(1)
    }
    FileHandle.standardOutput.write(Data(text.utf8))
} else {
    FileHandle.standardOutput.write(output)
}
exit(failed ? 1 : 0)
