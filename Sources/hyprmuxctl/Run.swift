import Foundation
import HyprmuxCore

// `hyprmuxctl run`: runs a command in a terminal attached to the caller's tile, shown
// there as a live preview, and streams its output back here as if it ran in place.
// An agent's shell tool runs commands through it (Resources/agents/pi/hyprmux-run.ts).
//
// The command runs under script(1) in the attached terminal, so it has a real terminal
// (colors, progress bars, prompts you can answer) and its output also goes to a log
// this process follows. A small shell wrapper writes the exit status next to the log.

func runUsage() -> String {
    """
    usage: hyprmuxctl run [options] [--] <command> [args...]
      Runs the command in a terminal attached to this tile, as a preview on it. Output
      streams here, and the exit status is the command's. Outside Hyprmux it just runs it.
      --surface <id>       attach to this tile instead of the caller's
      --title <text>       the preview's title (default: the command)
      --reveal-after <s>   show the preview only if it still runs after s seconds (default 0)
      --linger <s>         keep a finished preview s seconds after success (default 5; 0 keeps it)
      --no-wait            print the attached terminal as JSON and return at once
      --raw                pass output through as is (default when stdout is a terminal);
                           otherwise escape sequences go and carriage-return redraws collapse
      --keep-pager         leave PAGER and GIT_PAGER alone (default: cat, so nothing waits)
    """
}

/// One request on the control socket. Nil when Hyprmux can't be reached.
func controlRequest(_ line: String) -> String? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var noSigPipe: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout.size(ofValue: noSigPipe)))
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
        IPCPath.default.utf8CString.withUnsafeBytes { source in
            memcpy(buffer.baseAddress!, source.baseAddress!, min(buffer.count - 1, source.count))
        }
    }
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { return nil }
    let data = Array((line.hasSuffix("\n") ? line : line + "\n").utf8)
    var offset = 0
    while offset < data.count {
        let n = data[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if n < 0, errno == EINTR { continue }
        if n <= 0 { return nil }
        offset += n
    }
    shutdown(fd, SHUT_WR)
    var out = [UInt8]()
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
        let n = read(fd, &buffer, buffer.count)
        if n < 0, errno == EINTR { continue }
        if n <= 0 { break }
        out += buffer[0..<n]
    }
    return String(decoding: out, as: UTF8.self)
}

/// Environment the command shouldn't inherit: the terminal it runs in sets its own.
private let terminalEnvironment: Set<String> = [
    "TERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "COLORTERM", "TERMINFO", "TERM_SESSION_ID",
    "HYPRMUX_CLIENT", "HYPRMUX_SURFACE_ID", "SHLVL", "PWD", "OLDPWD", "_", "COLUMNS", "LINES",
]

private func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
    var offset = 0
    while offset < bytes.count {
        let n = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if n < 0, errno == EINTR { continue }
        if n <= 0 { return }
        offset += n
    }
}

private func fail(_ message: String) -> Int32 {
    FileHandle.standardError.write(Data("hyprmuxctl: run: \(message)\n".utf8))
    return 1
}

/// Runs the command here, replacing this process: no Hyprmux to attach to.
private func execInPlace(_ argv: [String]) -> Int32 {
    let cargs = argv.map { strdup($0) } + [nil]
    execvp(argv[0], cargs)
    return fail("\(argv[0]): \(String(cString: strerror(errno)))")
}

/// A short title from the command: the script of `sh -c SCRIPT`, else the words.
private func defaultTitle(_ argv: [String]) -> String {
    var text = argv.joined(separator: " ")
    if argv.count >= 3, ["-c", "-lc", "-ic"].contains(argv[1]),
       ["sh", "bash", "zsh", "dash", "fish"].contains((argv[0] as NSString).lastPathComponent) {
        text = argv[2]
    }
    let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    let trimmed = first.trimmingCharacters(in: .whitespaces)
    return trimmed.count > 60 ? String(trimmed.prefix(59)) + "…" : trimmed
}

/// The attached terminal's entry, or nil when it's gone.
private func attachedEntry(_ id: UInt64) -> [String: Any]? {
    guard let reply = controlRequest("identify --surface \(id)"), !reply.hasPrefix("error:") else { return nil }
    return (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any]
}

private var runningSurface: UInt64 = 0

func runCommand(_ arguments: [String]) -> Int32 {
    var surface: String?
    var title: String?
    var revealAfter = 0.0
    var linger: Double?
    var wait = true
    var raw: Bool?
    var keepPager = false
    var argv: [String] = []
    var index = 0
    func value(_ name: String) -> String? {
        guard index + 1 < arguments.count else { return nil }
        index += 1
        return arguments[index]
    }
    while index < arguments.count {
        let a = arguments[index]
        switch a {
        case "-h", "--help":
            print(runUsage())
            return 0
        case "--":
            argv = Array(arguments[(index + 1)...])
            index = arguments.count
            continue
        case "--surface":
            guard let v = value(a), case .success = SurfaceReference.parse(v) else { return fail("--surface needs a surface id") }
            surface = v
        case "--title":
            guard let v = value(a) else { return fail("--title needs text") }
            title = v
        case "--reveal-after":
            guard let v = value(a).flatMap(Double.init), v >= 0 else { return fail("--reveal-after needs seconds") }
            revealAfter = v
        case "--linger":
            guard let v = value(a).flatMap(Double.init) else { return fail("--linger needs seconds") }
            linger = v
        case "--no-wait": wait = false
        case "--raw": raw = true
        case "--keep-pager": keepPager = true
        default:
            guard !a.hasPrefix("--") else { return fail("unknown option \(a)\n\(runUsage())") }
            argv = Array(arguments[index...])
            index = arguments.count
            continue
        }
        index += 1
    }
    guard !argv.isEmpty else { return fail("name a command\n\(runUsage())") }

    let env = ProcessInfo.processInfo.environment
    let parentText = surface ?? env["HYPRMUX_SURFACE_ID"].flatMap { $0.isEmpty ? nil : $0 }
        ?? env["HYPRMUX_CLIENT"].flatMap { $0.isEmpty ? nil : $0 }
    guard let parentText, case .success(let parentRef) = SurfaceReference.parse(parentText) else {
        return execInPlace(argv)
    }

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hyprmux-run-\(getpid())-\(UUID().uuidString.prefix(8))")
    do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
        return fail("can't create \(dir.path): \(error.localizedDescription)")
    }
    // Without waiting, the command still writes there after this returns: leave it.
    defer { if wait { try? FileManager.default.removeItem(at: dir) } }
    let logPath = dir.appendingPathComponent("output").path
    let statusPath = logPath + ".status"
    FileManager.default.createFile(atPath: logPath, contents: nil)

    // script(1) gives the command a terminal of its own and copies its output to the log.
    let wrapper = #"/usr/bin/script -q -a -F "$0" "$@"; s=$?; echo "$s" > "$0.status"; exit "$s""#
    let command = (["/bin/sh", "-c", wrapper, logPath] + argv).map(shellQuote).joined(separator: " ")
    var childEnv = env.filter { !terminalEnvironment.contains($0.key) && !$0.key.hasPrefix("GHOSTTY_") }
    if !keepPager {
        childEnv["PAGER"] = "cat"
        childEnv["GIT_PAGER"] = "cat"
    }
    var request: [String: Any] = [
        "parent": parentRef.raw, "command": command, "cwd": FileManager.default.currentDirectoryPath,
        "env": childEnv, "title": title ?? defaultTitle(argv), "reveal_after": revealAfter,
        "status_file": statusPath,
    ]
    if wait { request["owner"] = Int(getpid()) }
    if let linger { request["linger"] = linger }
    guard let json = try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]) else {
        return fail("can't encode the request")
    }
    guard let reply = controlRequest("attach " + String(decoding: json, as: UTF8.self)) else {
        // Hyprmux went away (or this is a stale HYPRMUX_CLIENT): run it here instead.
        return execInPlace(argv)
    }
    guard !reply.hasPrefix("error:") else { return fail(String(reply.dropFirst("error: ".count))) }
    guard let entry = (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any],
          let id = (entry["id"] as? NSNumber)?.uint64Value else { return fail("unexpected reply: \(reply)") }
    guard wait else {
        print(reply)
        return 0
    }

    // Interrupted (an agent aborting, ctrl-c): close the attached terminal, which hangs
    // up on the command. A SIGKILL can't be caught; Hyprmux watches this process for that.
    runningSurface = id
    for sig in [SIGINT, SIGTERM, SIGHUP] {
        signal(sig) { s in
            _ = controlRequest("close-surface --surface \(runningSurface)")
            _exit(128 + s)
        }
    }
    signal(SIGPIPE, SIG_IGN)

    let plain = !(raw ?? (isatty(STDOUT_FILENO) != 0))
    var filter = PlainTextFilter()
    guard let log = FileHandle(forReadingAtPath: logPath) else { return fail("can't read \(logPath)") }
    func pump() -> Bool {
        let data = log.availableData
        guard !data.isEmpty else { return false }
        writeAll(STDOUT_FILENO, plain ? filter.feed(data) : Array(data))
        return true
    }
    var lastCheck = Date()
    var status: Int32?
    while status == nil {
        if pump() { continue }
        if let text = try? String(contentsOfFile: statusPath, encoding: .utf8),
           let code = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            status = code
            break
        }
        if Date().timeIntervalSince(lastCheck) > 1 {
            lastCheck = Date()
            if attachedEntry(id) == nil {
                while pump() {}
                if plain { writeAll(STDOUT_FILENO, filter.finish()) }
                FileHandle.standardError.write(Data("hyprmuxctl: run: the attached terminal closed before the command finished\n".utf8))
                return 129
            }
        }
        usleep(30_000)
    }
    while pump() {}
    if plain { writeAll(STDOUT_FILENO, filter.finish()) }
    // Let Hyprmux see the command end before this process does: it closes a terminal
    // whose waiting process is gone while its command still runs.
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
        guard let e = attachedEntry(id), let a = e["attached"] as? [String: Any], (a["running"] as? Bool) == true else { break }
        usleep(30_000)
    }
    return status ?? 1
}
