import AppKit
import HyprmuxCore

/// Agents in terminals (docs/AUTOMATION.md, Agent state): their reports, the state
/// shown for them, and noticing when they stop.
extension Compositor {
    /// `agent {…}` on the control socket.
    func handleAgentReport(_ r: AgentReport) -> String {
        let id = ClientID(r.client)
        guard let term = views[id]?.surface as? TerminalView else { return "error: no terminal \(r.client)" }
        // Like resume: the report counts while the agent runs in the terminal's foreground.
        guard ProcessInspector.isRunning(r.pid, inGroup: term.foregroundPID) else {
            return "error: process \(r.pid) isn't in terminal \(r.client)'s foreground"
        }
        if let resume = r.resume {
            resumeReports[id] = resume
            restoredAgents[id] = nil
            scheduleSessionSave()
        }
        if let change = agents.report(r, seen: agentSeen(id)) { agentChanged(change) }
        watchAgents()
        return "ok"
    }

    /// The user is looking at this terminal: its tile has focus while Hyprmux is in front.
    func agentSeen(_ id: ClientID) -> Bool {
        NSApp.isActive && wm.focused == id
    }

    /// Focus or activation changed: the focused agent's finished turn is seen.
    func agentFocusChanged() {
        guard let id = wm.focused, agentSeen(id), let change = agents.seen(id) else { return }
        agentChanged(change)
    }

    func agentClientRemoved(_ id: ClientID) {
        if let change = agents.remove(id) { agentChanged(change) }
    }

    /// Every change shows: the event, the notice.
    func agentChanged(_ c: AgentTracker.Change) {
        log.debug("agent client=\(c.id.raw) kind=\(c.kind, privacy: .public) \(c.from?.rawValue ?? "-", privacy: .public) -> \(c.to?.rawValue ?? "gone", privacy: .public)")
        emit(.agent(c))
        refreshStatus(c.id)
        if let n = c.notice, !agentSeen(c.id) {
            hud.notifications.post(c.to == .blocked ? .warning : .success, title: n.title, n.body,
                                   key: "agent-\(c.id.raw)", source: c.id)
        }
    }

    /// Checks every couple of seconds, while there are agents, that each still runs in
    /// its terminal's foreground. An agent that exited without saying so goes.
    func watchAgents() {
        guard !agentWatchScheduled, !agents.isEmpty else { return }
        agentWatchScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.agentWatchScheduled = false
            let gone = self.agents.prune { id, pid in
                guard let term = self.views[id]?.surface as? TerminalView else { return false }
                return ProcessInspector.isRunning(pid, inGroup: term.foregroundPID)
            }
            for c in gone { self.agentChanged(c) }
            self.watchAgents()
        }
    }

    /// What a tile shows (TileStatus): its agent's state, or what its app set. Idle shows
    /// nothing.
    func tileStatus(_ id: ClientID) -> String? {
        if let a = agents[id] { return a.state == .idle ? nil : a.state.rawValue }
        if let t = views[id]?.surface as? AttachedTerminal { return t.status }
        return (views[id]?.surface as? ClientSurface)?.status
    }

    /// Redraws a tile's status pill, and the tab strip of its group.
    func refreshStatus(_ id: ClientID) {
        views[id]?.setStatus(tileStatus(id))
        refreshGroupBars()
        refreshBarActivity()
    }

    /// `hyprmuxctl surfaces`: a terminal's agent.
    func agentInfo(_ id: ClientID) -> [String: Any]? {
        guard let a = agents[id] else { return nil }
        var info: [String: Any] = ["kind": a.kind, "state": a.state.rawValue]
        if let t = a.title { info["title"] = t }
        if let m = a.message { info["message"] = m }
        return info
    }
}
