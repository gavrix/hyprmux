import Foundation
import HyprmuxCore

// `hyprmuxctl jobs`: background jobs started with `run --no-wait`, and every other
// command `run` attached to a tile. Hyprmux keeps their records after their terminals
// close, so an agent can still wait for one or read its output.

func jobsUsage() -> String {
    """
    usage: hyprmuxctl jobs [--all] [--json]       this tile's jobs (--all: every tile's)
           hyprmuxctl jobs wait <id> [--timeout <s>]
                                                 wait for it to end; exits with its status
                                                 (124 when the timeout passes first)
           hyprmuxctl jobs log <id> [--lines <n>] [--follow] [--raw]
                                                 its output as plain text, also after it closed;
                                                 --follow streams it until the job ends
           hyprmuxctl jobs stop <id>             close its terminal, which ends it
    <id> is the job's surface: 14 or surface:14.
    """
}

private func jobsFail(_ message: String) -> Int32 {
    FileHandle.standardError.write(Data("hyprmuxctl: jobs: \(message)\n".utf8))
    return 1
}

private func jobList(parent: UInt64?) -> [[String: Any]]? {
    guard let reply = controlRequest(parent.map { "jobs --parent \($0)" } ?? "jobs") else { return nil }
    if reply.hasPrefix("error:") { return nil }
    return (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [[String: Any]]
}

private func job(_ id: UInt64) -> [String: Any]? {
    jobList(parent: nil)?.first { ($0["id"] as? NSNumber)?.uint64Value == id }
}

private func duration(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m\(s % 60)s" }
    return "\(s / 3600)h\(s % 3600 / 60)m"
}

/// How the job ended, for people and agents: "done (exit 0)", "failed (exit 2)".
private func summary(_ j: [String: Any]) -> String {
    let state = j["state"] as? String ?? "?"
    let ref = j["ref"] as? String ?? "?"
    if let code = j["exitStatus"] as? Int { return "\(ref) \(state) (exit \(code))" }
    return "\(ref) \(state)"
}

private func exitCode(_ j: [String: Any]) -> Int32 {
    if let code = j["exitStatus"] as? Int { return Int32(truncatingIfNeeded: code) }
    return j["state"] as? String == "stopped" ? 129 : 1
}

/// The log as text: plain unless raw, the last `lines` lines when set.
private func render(_ data: Data, raw: Bool, lines: Int?) -> String {
    var text: String
    if raw {
        text = String(decoding: data, as: UTF8.self)
    } else {
        var f = PlainTextFilter()
        text = String(decoding: f.feed(data) + f.finish(), as: UTF8.self)
    }
    if let lines { text = IPCText.tailLines(text, count: lines) }
    return text
}

private func parseID(_ text: String?) -> UInt64? {
    guard let text, case .success(let ref) = SurfaceReference.parse(text) else { return nil }
    return ref.raw
}

func jobsCommand(_ arguments: [String]) -> Int32 {
    var rest = arguments
    let sub = rest.first.flatMap { ["wait", "log", "stop", "list", "-h", "--help"].contains($0) ? $0 : nil } ?? "list"
    if !rest.isEmpty, rest[0] == sub { rest.removeFirst() }
    switch sub {
    case "-h", "--help":
        print(jobsUsage())
        return 0
    case "list":
        var all = false, json = false
        for a in rest {
            switch a {
            case "--all": all = true
            case "--json": json = true
            default: return jobsFail("unexpected \(a)\n\(jobsUsage())")
            }
        }
        let env = ProcessInfo.processInfo.environment
        let caller = (env["HYPRMUX_SURFACE_ID"].flatMap { $0.isEmpty ? nil : $0 } ?? env["HYPRMUX_CLIENT"]).flatMap(parseID)
        guard let list = jobList(parent: all ? nil : caller) else { return jobsFail("can't reach Hyprmux") }
        if json {
            let data = (try? JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted, .sortedKeys])) ?? Data()
            FileHandle.standardOutput.write(data + Data("\n".utf8))
            return 0
        }
        if list.isEmpty {
            print(all || caller == nil ? "No jobs." : "No jobs on this tile. jobs --all lists every tile's.")
            return 0
        }
        let now = Date().timeIntervalSince1970
        var rows = [["ID", "STATE", "EXIT", "TIME", "TITLE"]]
        for j in list {
            let started = j["started"] as? Double ?? now
            rows.append([j["ref"] as? String ?? "?", j["state"] as? String ?? "?",
                         (j["exitStatus"] as? Int).map(String.init) ?? "-",
                         duration((j["ended"] as? Double ?? now) - started), j["title"] as? String ?? ""])
        }
        var widths = rows[0].map(\.count)
        for r in rows { for (i, c) in r.enumerated() { widths[i] = max(widths[i], c.count) } }
        for r in rows {
            print(r.enumerated().map { i, c in i == r.count - 1 ? c : c.padding(toLength: widths[i], withPad: " ", startingAt: 0) }
                .joined(separator: "  "))
        }
        return 0
    case "wait":
        guard let id = parseID(rest.first) else { return jobsFail("wait needs a job id\n\(jobsUsage())") }
        var timeout: Double?
        if rest.count == 3, rest[1] == "--timeout", let t = Double(rest[2]), t >= 0 { timeout = t }
        else if rest.count != 1 { return jobsFail("usage: jobs wait <id> [--timeout <s>]") }
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while true {
            guard let j = job(id) else { return jobsFail("no job \(id)") }
            if j["state"] as? String != "running" {
                print(summary(j))
                return exitCode(j)
            }
            if let deadline, Date() >= deadline {
                print("\(summary(j)) after the timeout")
                return 124
            }
            usleep(200_000)
        }
    case "log":
        guard let id = parseID(rest.first) else { return jobsFail("log needs a job id\n\(jobsUsage())") }
        var lines: Int?, follow = false, raw = false
        var i = 1
        while i < rest.count {
            switch rest[i] {
            case "--lines":
                guard i + 1 < rest.count, let n = Int(rest[i + 1]), n > 0 else { return jobsFail("--lines needs a count") }
                lines = n
                i += 1
            case "--follow": follow = true
            case "--raw": raw = true
            default: return jobsFail("unexpected \(rest[i])")
            }
            i += 1
        }
        guard let j = job(id) else { return jobsFail("no job \(id)") }
        guard let path = j["log"] as? String else {
            return jobsFail("job \(id) has no log: it ran in the foreground, and its output went to its caller")
        }
        guard let handle = FileHandle(forReadingAtPath: path) else { return jobsFail("can't read \(path)") }
        let data = handle.readDataToEndOfFile()
        FileHandle.standardOutput.write(Data(render(data, raw: raw, lines: lines).utf8))
        guard follow else { return 0 }
        // Keep streaming new output until the job ends, then report how it ended.
        var filter = PlainTextFilter()
        var lastCheck = Date.distantPast
        while true {
            let chunk = handle.availableData
            if !chunk.isEmpty {
                FileHandle.standardOutput.write(raw ? chunk : Data(filter.feed(chunk)))
                continue
            }
            if Date().timeIntervalSince(lastCheck) > 0.5 {
                lastCheck = Date()
                guard let now = job(id) else { return jobsFail("no job \(id)") }
                if now["state"] as? String != "running" {
                    let tail = handle.readDataToEndOfFile()
                    if !tail.isEmpty { FileHandle.standardOutput.write(raw ? tail : Data(filter.feed(tail))) }
                    if !raw { FileHandle.standardOutput.write(Data(filter.finish())) }
                    FileHandle.standardError.write(Data("\(summary(now))\n".utf8))
                    return exitCode(now)
                }
            }
            usleep(50_000)
        }
    case "stop":
        guard rest.count == 1, let id = parseID(rest.first) else { return jobsFail("usage: jobs stop <id>") }
        guard let j = job(id) else { return jobsFail("no job \(id)") }
        if (j["open"] as? Bool) == true, let reply = controlRequest("close-surface --surface \(id)"), reply.hasPrefix("error:") {
            return jobsFail(reply)
        }
        usleep(200_000)
        print(job(id).map(summary) ?? "surface:\(id) stopped")
        return 0
    default:
        return jobsFail(jobsUsage())
    }
}
