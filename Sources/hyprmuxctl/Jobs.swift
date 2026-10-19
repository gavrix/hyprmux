import Foundation
import HyprmuxCore

// `hyprmuxctl jobs`: commands `run` attached to tiles, background (`run --no-wait`) or
// not. Hyprmux keeps their records after their terminals close, so an agent can still
// wait for one or read its output. Typing into a job and stopping it use the ordinary
// surface commands: `send`, `send-key`, and `close-surface`.

func jobsUsage() -> String {
    """
    usage: hyprmuxctl jobs [--all] [--json]       this tile's jobs (--all: every tile's)
           hyprmuxctl jobs wait <id> [--timeout <s>]
                                                 wait for it to end; exits with its status
                                                 (124 when the timeout passes first)
           hyprmuxctl jobs log <id> [--new [--reader <name>]] [--lines <n>]
                                                 its output as plain text, also after it closed;
                                                 --new: only what came since this reader's last
                                                 --new read (reader: the calling tile), then the
                                                 job's state on stderr
    <id> is the job's surface: 14 or surface:14. To answer a prompt or stop a job, use
    send --surface <id>, send-key --surface <id>, or close-surface --surface <id>.
    """
}

private func jobsFail(_ message: String) -> Int32 {
    FileHandle.standardError.write(Data("hyprmuxctl: jobs: \(message)\n".utf8))
    return 1
}

private func jobList(parent: UInt64?) -> [[String: Any]]? {
    guard let reply = controlRequest(parent.map { "jobs --parent \($0)" } ?? "jobs"), !reply.hasPrefix("error:") else {
        return nil
    }
    return (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [[String: Any]]
}

private func job(_ id: UInt64) -> [String: Any]? {
    jobList(parent: nil)?.first { ($0["id"] as? NSNumber)?.uint64Value == id }
}

private func parseID(_ text: String?) -> UInt64? {
    guard let text, case .success(let ref) = SurfaceReference.parse(text) else { return nil }
    return ref.raw
}

private func callerSurfaceID() -> String? {
    let env = ProcessInfo.processInfo.environment
    return env["HYPRMUX_SURFACE_ID"].flatMap { $0.isEmpty ? nil : $0 } ?? env["HYPRMUX_CLIENT"].flatMap { $0.isEmpty ? nil : $0 }
}

/// How the job ended, for people and agents: "surface:14 done (exit 0)".
private func summary(_ j: [String: Any]) -> String {
    let ref = j["ref"] as? String ?? "?", state = j["state"] as? String ?? "?"
    return (j["exitStatus"] as? Int).map { "\(ref) \(state) (exit \($0))" } ?? "\(ref) \(state)"
}

private func duration(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m\(s % 60)s" }
    return "\(s / 3600)h\(s % 3600 / 60)m"
}

private func plain(_ data: Data, lines: Int?) -> String {
    var f = PlainTextFilter()
    let text = String(decoding: f.feed(data) + f.finish(), as: UTF8.self)
    return lines.map { IPCText.tailLines(text, count: $0) } ?? text
}

func jobsCommand(_ arguments: [String]) -> Int32 {
    var rest = arguments
    let sub = rest.first.flatMap { ["wait", "log", "list", "-h", "--help"].contains($0) ? $0 : nil } ?? "list"
    if rest.first == sub { rest.removeFirst() }
    switch sub {
    case "-h", "--help":
        print(jobsUsage())
        return 0
    case "list": return listJobs(rest)
    case "wait": return waitForJob(rest)
    default: return readLog(rest)
    }
}

private func listJobs(_ args: [String]) -> Int32 {
    guard args.allSatisfy({ $0 == "--all" || $0 == "--json" }) else { return jobsFail(jobsUsage()) }
    let caller = args.contains("--all") ? nil : callerSurfaceID().flatMap(parseID)
    guard let list = jobList(parent: caller) else { return jobsFail("can't reach Hyprmux") }
    if args.contains("--json") {
        let data = (try? JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        FileHandle.standardOutput.write(data + Data("\n".utf8))
        return 0
    }
    guard !list.isEmpty else {
        print(caller == nil ? "No jobs." : "No jobs on this tile. jobs --all lists every tile's.")
        return 0
    }
    let now = Date().timeIntervalSince1970
    var rows = [["ID", "STATE", "EXIT", "TIME", "TITLE"]]
    for j in list {
        let started = j["started"] as? Double ?? now
        rows.append([j["ref"] as? String ?? "?", j["state"] as? String ?? "?", (j["exitStatus"] as? Int).map(String.init) ?? "-",
                     duration((j["ended"] as? Double ?? now) - started), j["title"] as? String ?? ""])
    }
    var widths = rows[0].map(\.count)
    for r in rows { for (i, c) in r.enumerated() { widths[i] = max(widths[i], c.count) } }
    for r in rows {
        print(r.enumerated().map { i, c in i == r.count - 1 ? c : c.padding(toLength: widths[i], withPad: " ", startingAt: 0) }
            .joined(separator: "  "))
    }
    return 0
}

/// Exits with the job's status: 129 for a stopped job, 124 when the timeout passes first.
private func waitForJob(_ args: [String]) -> Int32 {
    guard let id = parseID(args.first) else { return jobsFail("wait needs a job id\n\(jobsUsage())") }
    var deadline: Date?
    if args.count == 3, args[1] == "--timeout", let t = Double(args[2]), t >= 0 { deadline = Date().addingTimeInterval(t) }
    else if args.count != 1 { return jobsFail("usage: jobs wait <id> [--timeout <s>]") }
    while true {
        guard let j = job(id) else { return jobsFail("no job \(id)") }
        if j["state"] as? String != "running" {
            print(summary(j))
            if let code = j["exitStatus"] as? Int { return Int32(truncatingIfNeeded: code) }
            return j["state"] as? String == "stopped" ? 129 : 1
        }
        if let deadline, Date() >= deadline {
            print("\(summary(j)) after the timeout")
            return 124
        }
        usleep(200_000)
    }
}

private func readLog(_ args: [String]) -> Int32 {
    guard let id = parseID(args.first) else { return jobsFail("log needs a job id\n\(jobsUsage())") }
    var lines: Int?, new = false, reader: String?
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--new": new = true
        case "--lines", "--reader":
            guard i + 1 < args.count else { return jobsFail("\(args[i]) needs a value") }
            if args[i] == "--reader" { reader = args[i + 1] }
            else if let n = Int(args[i + 1]), n > 0 { lines = n }
            else { return jobsFail("--lines needs a count") }
            i += 1
        default: return jobsFail("unexpected \(args[i])")
        }
        i += 1
    }
    guard let j = job(id) else { return jobsFail("no job \(id)") }
    guard let path = j["log"] as? String else {
        return jobsFail("job \(id) has no log: it ran in the foreground, and its output went to its caller")
    }
    guard let handle = FileHandle(forReadingAtPath: path) else { return jobsFail("can't read \(path)") }
    guard new else {
        FileHandle.standardOutput.write(Data(plain(handle.readDataToEndOfFile(), lines: lines).utf8))
        return 0
    }
    // --new: from this reader's last position to the end, then the job's state. The
    // position is a small file next to the log.
    let name = reader ?? callerSurfaceID() ?? "default"
    let cursor = "\(path).read-" + String(name.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
    let offset = (try? String(contentsOfFile: cursor, encoding: .utf8)).flatMap { UInt64($0) } ?? 0
    handle.seek(toFileOffset: min(offset, handle.seekToEndOfFile()))
    let chunk = handle.readDataToEndOfFile()
    try? String(handle.offsetInFile).write(toFile: cursor, atomically: true, encoding: .utf8)
    var text = plain(chunk, lines: lines)
    // A running job whose output ends mid-line most likely shows a prompt.
    let prompt = j["state"] as? String == "running" && !chunk.isEmpty && chunk.last != 0x0A
    if prompt, !text.hasSuffix("\n") { text += "\n" }
    FileHandle.standardOutput.write(Data(text.utf8))
    let note = prompt ? ", its last line has no newline: it may wait for input" : chunk.isEmpty ? ", no new output" : ""
    FileHandle.standardError.write(Data("[\(summary(j))\(note)]\n".utf8))
    return 0
}
