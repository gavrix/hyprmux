import AppKit
import HyprmuxCore

/// What the compositor tracks for an attached terminal's command.
struct AttachedJob {
    /// Seconds the preview stays after the command succeeds; zero or less keeps it.
    var linger: Double
    /// Watches the process that waits for the command (`hyprmuxctl run`).
    var owner: DispatchSourceProcess?
    /// Where the command's exit status lands (AttachRequest.statusFile).
    var statusFile: String?
}

/// Attached terminals: `attach {…}` (hyprmuxctl run) runs a command in a terminal shown as
/// a preview on the caller's tile. See WindowManager+Attached.swift for placement.
extension Compositor {
    func openAttached(_ r: AttachRequest) -> String {
        let requested = ClientID(r.parent)
        guard views[requested] != nil, wm.workspace(of: requested) != nil else {
            return "error: no surface \(r.parent)"
        }
        let parent = wm.attachedParent(of: requested) ?? requested
        if let owner = r.owner, owner > 0, kill(owner, 0) != 0, errno == ESRCH {
            return "error: process \(owner) isn't running"
        }
        var opts = SurfaceOptions()
        opts.workingDirectory = r.cwd ?? views[parent].flatMap { Self.terminal(in: $0.surface)?.pwd }
        opts.command = r.command
        opts.env = r.env ?? [:]
        guard let term = makeTerminal(opts, keepPath: r.env?["PATH"] != nil) else {
            return "error: failed to create terminal"
        }
        let surface = AttachedTerminal(terminal: term, parent: parent, title: r.title)
        let id = surface.clientID
        term.onChildExited = { [weak self] status in
            // Not inside Ghostty's callback: closing frees the surface it holds.
            DispatchQueue.main.async { self?.attachedExited(id, status: Int(status)) }
        }
        surface.onCloseAfterExit = { [weak self] in self?.removeClient(id) }
        attachedJobs[id] = AttachedJob(linger: r.linger ?? 5, statusFile: r.statusFile)
        adopt(surface)
        jobs.started(JobRecord(id: id, parent: parent, title: surface.title, log: r.log, started: Date()))
        let reveal = r.revealAfter ?? 0
        wm.addAttached(id, to: parent, revealed: reveal <= 0)
        if reveal > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + reveal) { [weak self] in self?.revealAttached(id) }
        }
        if let owner = r.owner, owner > 0 { watchOwner(owner, of: id) }
        refreshStatus(id)
        apply(animated: true)
        log.debug("attach client=\(id.raw) parent=\(parent.raw) owner=\(r.owner ?? 0)")
        guard let p = wm.snapshot().placement(id) else { return "error: surface closed while opening" }
        return json(clientInfo(p))
    }

    private func revealAttached(_ id: ClientID) {
        guard let s = views[id]?.surface as? AttachedTerminal, s.isRunning else { return }
        wm.setAttachedRevealed(id, true)
        apply(animated: true)
    }

    /// The command ended. One nobody saw goes at once; a success lingers, then goes; a
    /// failure stays until it's closed.
    private func attachedExited(_ id: ClientID, status reported: Int) {
        guard let s = views[id]?.surface as? AttachedTerminal, s.isRunning else { return }
        let status = attachedJobs[id]?.statusFile
            .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? reported
        s.exited(status)
        jobs.exited(id, status: status)
        attachedJobs[id]?.owner?.cancel()
        attachedJobs[id]?.owner = nil
        log.debug("attach exited client=\(id.raw) status=\(status)")
        guard wm.isAttachedRevealed(id) else {
            removeClient(id)
            return
        }
        views[id]?.titleDidChange()
        refreshStatus(id)
        emit(HyprmuxEvent.windowTitle(id, s.title))
        if status == 0, let linger = attachedJobs[id]?.linger, linger > 0 { scheduleLingerClose(id, after: linger) }
    }

    /// Closes a finished preview after a while, unless it's expanded then: it waits for
    /// focus to leave.
    private func scheduleLingerClose(_ id: ClientID, after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.views[id] != nil else { return }
            if self.wm.focused == id {
                self.scheduleLingerClose(id, after: seconds)
            } else {
                self.removeClient(id)
            }
        }
    }

    /// When the waiting process dies first (an agent aborted the command), the job goes
    /// too: closing the terminal hangs up on it.
    private func watchOwner(_ pid: Int32, of id: ClientID) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in self?.attachedOwnerExited(id) }
        attachedJobs[id]?.owner = source
        source.resume()
        // It may have exited before the source existed.
        if kill(pid, 0) != 0, errno == ESRCH { attachedOwnerExited(id) }
    }

    private func attachedOwnerExited(_ id: ClientID) {
        attachedJobs[id]?.owner?.cancel()
        attachedJobs[id]?.owner = nil
        guard let s = views[id]?.surface as? AttachedTerminal, s.isRunning else { return }
        log.debug("attach owner gone client=\(id.raw)")
        removeClient(id)
    }

    /// Before the compositor forgets a client: its attached terminals close with it.
    func removeAttachedClients(of id: ClientID) {
        for child in wm.attached(to: id) { removeClient(child) }
        attachedJobs[id]?.owner?.cancel()
        attachedJobs[id] = nil
        jobs.closed(id)
    }

    /// `hyprmuxctl jobs`: one job, open or closed.
    func jobInfo(_ r: JobRecord) -> [String: Any] {
        var info: [String: Any] = [
            "id": r.id.raw, "ref": SurfaceReference(r.id.raw).description, "parent": r.parent.raw,
            "title": r.title, "state": r.state, "open": views[r.id] != nil,
            "started": r.started.timeIntervalSince1970,
        ]
        if let code = r.exitStatus { info["exitStatus"] = code }
        if let e = r.ended { info["ended"] = e.timeIntervalSince1970 }
        if let log = r.log { info["log"] = log }
        if let p = wm.snapshot().placement(r.id), let a = p.attachment {
            info["expanded"] = a.expanded
            info["revealed"] = a.revealed
        }
        return info
    }

    /// Each layout: an attached terminal learns its expanded size and whether it's a preview.
    func configureAttached(_ v: ClientView, _ p: Placement, borderSize b: CGFloat) {
        guard let a = p.attachment, let s = v.surface as? AttachedTerminal else { return }
        let size = CGSize(width: max(1, a.expandedFrame.width - 2 * b), height: max(1, a.expandedFrame.height - 2 * b))
        s.configure(logicalSize: size, collapsed: !a.expanded)
    }

    func attachmentInfo(_ p: Placement) -> [String: Any]? {
        guard let a = p.attachment else { return nil }
        var info: [String: Any] = ["parent": a.parent.raw, "expanded": a.expanded, "revealed": a.revealed]
        if let log = jobs.records[p.id]?.log { info["log"] = log }
        if let s = views[p.id]?.surface as? AttachedTerminal {
            info["running"] = s.isRunning
            if let code = s.exitStatus { info["exitStatus"] = code }
        }
        return info
    }
}
