import Foundation

// Agents: coding agents (pi, Claude Code, Codex) that run in Hyprmux terminals and
// report what they're doing. The agent, or a hook it runs, sends `agent {…}` on the
// control socket; Hyprmux shows the state on the tile and posts a notice when the
// agent needs the user or finishes. See docs/AUTOMATION.md, Agent state.

/// What an agent is doing. Agents report `working`, `blocked`, and `idle`; Hyprmux
/// shows `done` for a finished turn the user hasn't looked at yet.
public enum AgentState: String, Codable, CaseIterable, Sendable {
    case working
    /// Waits for the user: a question, an approval.
    case blocked
    /// Ready for input, and seen.
    case idle
    /// Ready for input after a turn, not looked at yet.
    case done

    /// How much the state wants attention: blocked, then done, then working.
    public var priority: Int {
        switch self {
        case .blocked: 4
        case .done: 3
        case .working: 2
        case .idle: 1
        }
    }
}

/// `agent {"client": 12, "pid": 4711, "kind": "pi", "state": "working", …}`: an agent
/// says what it does in the terminal `client` (its `HYPRMUX_CLIENT`). The report counts
/// while `pid` runs in the terminal's foreground, like `resume`.
public struct AgentReport: Codable, Equatable, Sendable {
    public var client: UInt64
    public var pid: Int32
    /// "pi", "claude", "codex": a `session:resume:KIND` template name.
    public var kind: String
    /// Nil reports only the session (as `resume` does). `done` counts as `idle`.
    public var state: AgentState?
    /// The agent's session, for restore (see ResumeReport).
    public var session: String?
    public var cwd: String?
    public var file: String?
    /// What the agent works on, in a few words.
    public var title: String?
    /// Why it's blocked: the question or the approval it waits for.
    public var message: String?

    public init(client: UInt64, pid: Int32, kind: String, state: AgentState? = nil, session: String? = nil,
                cwd: String? = nil, file: String? = nil, title: String? = nil, message: String? = nil) {
        self.client = client
        self.pid = pid
        self.kind = kind
        self.state = state
        self.session = session
        self.cwd = cwd
        self.file = file
        self.title = title
        self.message = message
    }

    /// The session part, for session restore.
    public var resume: ResumeReport? {
        guard let session, !session.isEmpty else { return nil }
        return ResumeReport(client: client, pid: pid, kind: kind, session: session, cwd: cwd, file: file)
    }
}

/// Every terminal's agent, and the state Hyprmux shows for it.
public struct AgentTracker: Equatable, Sendable {
    public struct Agent: Equatable, Sendable {
        public var kind: String
        public var pid: Int32
        /// The state Hyprmux shows: what the agent reported, with `done` for a turn that
        /// finished unseen.
        public var state: AgentState
        public var title: String?
        public var message: String?
    }

    /// A shown state changed. `to` is nil when the agent went away.
    public struct Change: Equatable, Sendable {
        public var id: ClientID
        public var kind: String
        public var from: AgentState?
        public var to: AgentState?
        public var message: String?

        /// The notice this change is worth: the agent needs the user, or it finished.
        public var notice: (title: String, body: String)? {
            guard from != to else { return nil }
            switch to {
            case .blocked: return (kind, message.flatMap { $0.isEmpty ? nil : $0 } ?? "Needs you")
            case .done: return (kind, "Finished")
            default: return nil
            }
        }
    }

    public private(set) var agents: [ClientID: Agent] = [:]

    public init() {}

    public subscript(id: ClientID) -> Agent? { agents[id] }

    public var isEmpty: Bool { agents.isEmpty }

    /// Applies a report with a state. `seen`: the user is looking at the terminal now,
    /// so a finished turn shows as idle, not done. Nil when the shown state stays the same.
    @discardableResult
    public mutating func report(_ r: AgentReport, seen: Bool) -> Change? {
        guard let reported = r.state else { return nil }
        let id = ClientID(r.client)
        let old = agents[id]
        let shown: AgentState
        switch reported {
        case .working, .blocked:
            shown = reported
        case .idle, .done:
            // A turn ended: unseen, it's news until the user looks.
            if seen {
                shown = .idle
            } else if old?.state == .done || old?.state == .working || old?.state == .blocked {
                shown = .done
            } else {
                shown = .idle
            }
        }
        let message = shown == .blocked ? r.message : nil
        agents[id] = Agent(kind: r.kind, pid: r.pid, state: shown, title: r.title ?? old?.title, message: message)
        guard old?.state != shown || old?.kind != r.kind || old?.message != message else { return nil }
        return Change(id: id, kind: r.kind, from: old?.state, to: shown, message: message)
    }

    /// The user looked at the terminal: a finished turn is seen now.
    @discardableResult
    public mutating func seen(_ id: ClientID) -> Change? {
        guard var a = agents[id], a.state == .done else { return nil }
        a.state = .idle
        agents[id] = a
        return Change(id: id, kind: a.kind, from: .done, to: .idle)
    }

    /// The agent exited, or its terminal closed.
    @discardableResult
    public mutating func remove(_ id: ClientID) -> Change? {
        guard let a = agents.removeValue(forKey: id) else { return nil }
        return Change(id: id, kind: a.kind, from: a.state, to: nil)
    }

    /// Drops agents that stopped: `alive` says whether a terminal's agent process still
    /// runs in its foreground.
    public mutating func prune(alive: (ClientID, Int32) -> Bool) -> [Change] {
        agents.compactMap { id, a in alive(id, a.pid) ? nil : id }.sorted().compactMap { remove($0) }
    }

    /// A group of terminals' state: its most urgent agent's. Nil without agents.
    public func rollup(_ ids: [ClientID]) -> AgentState? {
        ids.compactMap { agents[$0]?.state }.max { $0.priority < $1.priority }
    }
}

extension HyprmuxEvent {
    /// `agent>>ID,KIND,STATE`: a terminal's agent changed state. STATE is empty when the
    /// agent went away.
    public static func agent(_ c: AgentTracker.Change) -> HyprmuxEvent {
        HyprmuxEvent("agent", "\(c.id.raw),\(c.kind),\(c.to?.rawValue ?? "")")
    }
}

/// How many tiles on a workspace are doing something, by status (working, blocked, done:
/// an agent's state, or what an app tile set). The workspace bar shows it on the pill.
public struct WorkspaceActivity: Equatable, Sendable {
    public var blocked = 0
    public var done = 0
    public var working = 0

    public init(blocked: Int = 0, done: Int = 0, working: Int = 0) {
        self.blocked = blocked
        self.done = done
        self.working = working
    }

    public var isEmpty: Bool { blocked + done + working == 0 }

    /// The statuses with tiles in them, most urgent first.
    public var counts: [(status: String, count: Int)] {
        [("blocked", blocked), ("done", done), ("working", working)].filter { $0.1 > 0 }.map { ($0.0, $0.1) }
    }

    /// Counts one tile. Idle and unknown statuses don't count.
    public mutating func add(_ status: String?) {
        switch status {
        case "blocked": blocked += 1
        case "done": done += 1
        case "working": working += 1
        default: break
        }
    }

    /// Each workspace's activity, special ones included, from every tile's workspace and
    /// status. Workspaces with nothing going on are left out.
    public static func byWorkspace(_ tiles: [(workspace: WorkspaceID?, status: String?)]) -> [WorkspaceID: WorkspaceActivity] {
        var out: [WorkspaceID: WorkspaceActivity] = [:]
        for t in tiles {
            guard let ws = t.workspace else { continue }
            var a = out[ws] ?? WorkspaceActivity()
            a.add(t.status)
            if !a.isEmpty { out[ws] = a }
        }
        return out
    }

    /// Each regular workspace's activity, by number, for the bar's pills. Special
    /// workspaces have no pill.
    public static func tally(_ tiles: [(workspace: WorkspaceID?, status: String?)]) -> [Int: WorkspaceActivity] {
        var out: [Int: WorkspaceActivity] = [:]
        for (ws, a) in byWorkspace(tiles) {
            if case .regular(let n) = ws { out[n] = a }
        }
        return out
    }

    /// The tiles that finished between `old` and `new`, by the status each finished from
    /// ("blocked" or "working"): done went up, and needs-you or working went down by as
    /// much. Working counts first, since a turn usually ends from working.
    public static func finished(from old: WorkspaceActivity, to new: WorkspaceActivity) -> [String] {
        let gained = new.done - old.done
        guard gained > 0 else { return [] }
        let fromWorking = min(gained, max(0, old.working - new.working))
        let fromBlocked = min(gained - fromWorking, max(0, old.blocked - new.blocked))
        return Array(repeating: "working", count: fromWorking) + Array(repeating: "blocked", count: fromBlocked)
    }

    /// "2 working, 1 needs you", for a tooltip.
    public var summary: String {
        counts.map { "\($0.count) \($0.status == "blocked" ? "need\($0.count == 1 ? "s" : "") you" : $0.status)" }
            .joined(separator: ", ")
    }
}
