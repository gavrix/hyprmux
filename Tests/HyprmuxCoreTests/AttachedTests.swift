import CoreGraphics
import XCTest
@testable import HyprmuxCore

/// Terminals attached to a tile as previews (WindowManager+Attached.swift).
final class AttachedTests: XCTestCase {
    func makeWM() -> WindowManager {
        var s = WMSettings()
        s.gapsIn = .zero
        s.gapsOut = .zero
        s.borderSize = 2
        s.dwindle.forceSplit = 2
        return WindowManager(monitor: CGRect(x: 0, y: 0, width: 1600, height: 1000), settings: s)
    }

    let parent = ClientID(1), other = ClientID(2), job = ClientID(3), job2 = ClientID(4)

    func testJobGetsAChipInItsParentsJobBar() throws {
        let wm = makeWM()
        wm.addClient(parent)
        wm.addAttached(job, to: parent)
        wm.addAttached(job2, to: parent)
        let snap = wm.snapshot()
        let p = try XCTUnwrap(snap.placement(parent))
        let a = try XCTUnwrap(snap.placement(job))
        XCTAssertEqual(wm.focused, parent, "attaching doesn't take focus")
        XCTAssertEqual(p.jobs, JobBarInfo(members: [job, job2], expanded: nil, peeked: nil, height: 22))
        XCTAssertFalse(a.visible, "a collapsed job is only its chip")
        XCTAssertEqual(a.attachment?.parent, parent)
        XCTAssertEqual(a.attachment?.expanded, false)
        XCTAssertEqual(wm.workspace(of: job), .regular(1))
    }

    func testJobIsNotInLayout() {
        let wm = makeWM()
        wm.addClient(parent)
        wm.addAttached(job, to: parent)
        XCTAssertEqual(wm.snapshot().placement(parent)?.frame, CGRect(x: 0, y: 0, width: 1600, height: 1000))
        wm.addClient(other)
        XCTAssertEqual(wm.snapshot().placement(parent)?.frame.width, 800)
    }

    func testUnrevealedJobHasNoChip() {
        let wm = makeWM()
        wm.addClient(parent)
        wm.addAttached(job, to: parent, revealed: false)
        XCTAssertNil(wm.snapshot().placement(parent)?.jobs, "no bar without a revealed job")
        wm.peekAttached(job)
        XCTAssertNil(wm.peekedAttached, "nothing to peek at")
        wm.setAttachedRevealed(job, true)
        XCTAssertEqual(wm.snapshot().placement(parent)?.jobs?.members, [job])
    }

    func testBarIsAtMostHalfASmallTile() throws {
        let wm = makeWM()
        wm.monitor = CGRect(x: 0, y: 0, width: 400, height: 30)
        wm.addClient(parent)
        wm.addAttached(job, to: parent)
        XCTAssertEqual(try XCTUnwrap(wm.snapshot().placement(parent)?.jobs).height, 13)
    }

    func testPeekSitsAboveTheBarOnItsChip() throws {
        let wm = makeWM()
        wm.addClient(parent)
        wm.addAttached(job, to: parent)
        XCTAssertTrue(wm.peekAttached(job, anchorX: 500))
        XCTAssertFalse(wm.peekAttached(job, anchorX: 500), "no change")
        var snap = wm.snapshot()
        let p = try XCTUnwrap(snap.placement(parent))
        var a = try XCTUnwrap(snap.placement(job))
        XCTAssertTrue(a.visible)
        XCTAssertEqual(a.attachment?.peeked, true)
        XCTAssertEqual(p.jobs?.peeked, job)
        let bar = WindowManager.jobBarFrame(parent: p.frame, height: 22, border: 2)
        XCTAssertEqual(bar, CGRect(x: 2, y: 976, width: 1596, height: 22))
        XCTAssertEqual(a.frame.maxY, bar.minY - 8)
        XCTAssertEqual(a.frame.midX, 500, accuracy: 1)
        // Content scales uniformly from the expanded frame.
        let e = try XCTUnwrap(a.attachment?.expandedFrame)
        XCTAssertEqual(a.frame.width - 4, ((e.width - 4) * 0.4).rounded())
        XCTAssertEqual(a.frame.height - 4, ((e.height - 4) * 0.4).rounded())
        XCTAssertEqual(snap.placements.last?.id, job, "stacks just above its parent")

        wm.peekAttached(job, anchorX: 1590)
        a = try XCTUnwrap(wm.snapshot().placement(job))
        XCTAssertEqual(a.frame.maxX, p.frame.maxX - 2 - 8, "kept inside the tile")
        XCTAssertTrue(wm.peekAttached(nil))
        snap = wm.snapshot()
        XCTAssertEqual(snap.placement(job)?.visible, false)
        XCTAssertNil(snap.placement(parent)?.jobs?.peeked)
    }

    func testExpandedJobLeavesTheBarClear() throws {
        let wm = makeWM()
        wm.addClient(parent)
        wm.addClient(other)
        wm.focus(parent)
        wm.addAttached(job, to: parent)
        wm.focus(job)
        var snap = wm.snapshot()
        var a = try XCTUnwrap(snap.placement(job))
        let p = try XCTUnwrap(snap.placement(parent))
        XCTAssertEqual(a.attachment?.expanded, true)
        XCTAssertTrue(a.visible)
        XCTAssertEqual(a.frame, a.attachment?.expandedFrame)
        XCTAssertEqual(p.jobs?.expanded, job)
        var area = p.frame
        area.size.height -= 22
        XCTAssertEqual(a.frame, area.insetBy(dx: 24, dy: 24))
        wm.focus(other)
        snap = wm.snapshot()
        a = try XCTUnwrap(snap.placement(job))
        XCTAssertEqual(a.attachment?.expanded, false)
        XCTAssertFalse(a.visible)
        XCTAssertNil(snap.placement(parent)?.jobs?.expanded)
    }

    func testFocusEndsThePeek() throws {
        let wm = makeWM()
        wm.addClient(parent)
        wm.addAttached(job, to: parent)
        wm.peekAttached(job, anchorX: 100)
        wm.focus(job)
        XCTAssertNil(wm.peekedAttached)
        XCTAssertEqual(wm.snapshot().placement(job)?.attachment?.peeked, false)
        wm.focus(parent)
        XCTAssertEqual(wm.snapshot().placement(job)?.visible, false, "collapsing doesn't bring the peek back")
    }

    func testWorkspacePreviewLeavesOutCollapsedJobs() {
        let wm = makeWM()
        wm.addClient(parent)
        wm.addAttached(job, to: parent)
        wm.addAttached(job2, to: parent)
        wm.peekAttached(job2)
        XCTAssertEqual(wm.snapshot().preview(of: .regular(1)).map(\.id), [parent])
        wm.focus(job)
        XCTAssertEqual(wm.snapshot().preview(of: .regular(1)).map(\.id), [parent, job])
    }

    func testFocusAttachedToggles() {
        let wm = makeWM()
        wm.addClient(parent)
        wm.addAttached(job, to: parent, revealed: false)
        wm.dispatch(.focusAttached)
        XCTAssertEqual(wm.focused, parent, "nothing revealed to expand")
        wm.setAttachedRevealed(job, true)
        wm.addAttached(job2, to: parent)
        wm.dispatch(.focusAttached)
        XCTAssertEqual(wm.focused, job2, "the newest one")
        wm.dispatch(.focusAttached)
        XCTAssertEqual(wm.focused, parent)
        wm.focus(job)
        wm.focus(parent)
        wm.dispatch(.focusAttached)
        XCTAssertEqual(wm.focused, job, "the one looked at last")
    }

    func testLayoutDispatchersActOnParent() {
        let wm = makeWM()
        wm.addClient(parent)
        wm.addClient(other)
        wm.focus(parent)
        wm.addAttached(job, to: parent)
        wm.focus(job)
        wm.dispatch(.toggleFloating)
        XCTAssertTrue(wm.isFloating(parent))
        XCTAssertFalse(wm.isFloating(job))
        wm.dispatch(.moveToWorkspace(.id(2), silent: true))
        XCTAssertEqual(wm.workspace(of: parent), .regular(2))
        XCTAssertEqual(wm.workspace(of: job), .regular(2), "follows its parent")
        XCTAssertEqual(wm.snapshot().placement(job)?.visible, false)
        wm.dispatch(.workspace(.id(2)))
        let p = wm.snapshot().placement(parent)
        XCTAssertEqual(p?.visible, true)
        XCTAssertEqual(p?.jobs?.members, [job], "its job bar went along")
    }

    func testKillActiveClosesAttachedItself() {
        let wm = makeWM()
        var closed: [ClientID] = []
        wm.perform = { if case .close(let id) = $0 { closed.append(id) } }
        wm.addClient(parent)
        wm.addAttached(job, to: parent)
        wm.focus(job)
        wm.dispatch(.killActive)
        XCTAssertEqual(closed, [job])
    }

    func testRemovingAttachedFocusesParent() {
        let wm = makeWM()
        wm.addClient(parent)
        wm.addClient(other)
        wm.addAttached(job, to: parent)
        wm.focus(job)
        wm.removeClient(job)
        XCTAssertEqual(wm.focused, parent)
        XCTAssertNil(wm.snapshot().placement(job))
    }

    func testRemovingParentDropsAttached() {
        let wm = makeWM()
        wm.addClient(parent)
        wm.addClient(other)
        wm.addAttached(job, to: parent)
        wm.focus(job)
        wm.removeClient(parent)
        XCTAssertNil(wm.snapshot().placement(job))
        XCTAssertEqual(wm.focused, other)
        XCTAssertEqual(wm.attached(to: parent), [])
    }

    func testAttachingToAttachedUsesItsParent() {
        let wm = makeWM()
        wm.addClient(parent)
        wm.addAttached(job, to: parent)
        wm.addAttached(job2, to: job)
        XCTAssertEqual(wm.attachedParent(of: job2), parent)
    }

    func testHiddenGroupTabHidesItsAttached() {
        let wm = makeWM()
        wm.addClient(parent)
        wm.dispatch(.toggleGroup)
        wm.addClient(other)  // joins the group as the shown tab
        wm.addAttached(job, to: parent)
        wm.peekAttached(job)
        XCTAssertEqual(wm.snapshot().placement(job)?.visible, false)
        wm.focus(job)
        let snap = wm.snapshot()
        XCTAssertEqual(snap.placement(parent)?.visible, true, "expanding it shows its tab")
        XCTAssertEqual(snap.placement(job)?.visible, true)
    }

    func testFullscreenParentCarriesItsJobs() throws {
        let wm = makeWM()
        wm.addClient(parent)
        wm.addClient(other)
        wm.focus(parent)
        wm.addAttached(job, to: parent)
        wm.dispatch(.fullscreen(.fullscreen))
        wm.peekAttached(job)
        let snap = wm.snapshot()
        let p = try XCTUnwrap(snap.placement(parent)), a = try XCTUnwrap(snap.placement(job))
        XCTAssertEqual(a.z, p.z)
        XCTAssertEqual(p.jobs?.members, [job])
        XCTAssertEqual(a.frame.maxX, p.frame.maxX - 10)
    }

    func testHoverOverPeekTargetsParent() throws {
        let wm = makeWM()
        wm.addClient(parent)
        wm.addAttached(job, to: parent)
        wm.peekAttached(job)
        let a = try XCTUnwrap(wm.snapshot().placement(job))
        let center = CGPoint(x: a.frame.midX, y: a.frame.midY)
        XCTAssertEqual(wm.client(at: center), job, "clicks reach it")
        XCTAssertEqual(wm.hoverTarget(at: center), parent, "hover doesn't expand it")
        wm.focus(job)
        XCTAssertEqual(wm.hoverTarget(at: center), job)
    }

    func testPeekStaysAboveExpandedSibling() throws {
        let wm = makeWM()
        wm.addClient(parent)
        wm.addAttached(job, to: parent)
        wm.addAttached(job2, to: parent)
        wm.focus(job)
        wm.peekAttached(job2, anchorX: 800)
        let snap = wm.snapshot()
        XCTAssertEqual(snap.placements.map(\.id), [parent, job, job2])
        let peek = try XCTUnwrap(snap.placement(job2)).frame
        let center = CGPoint(x: peek.midX, y: peek.midY)
        XCTAssertEqual(wm.client(at: center), job2, "a click reaches the peek over the expanded one")
        XCTAssertEqual(wm.hoverTarget(at: center), parent)
    }

    func testAttachRequestParses() {
        let line = #"attach {"parent": 3, "command": "make test", "cwd": "/tmp", "owner": 42, "reveal_after": 1.5}"#
        guard case .success(.attach(let r)) = IPCRequest.parse(line) else { return XCTFail("didn't parse") }
        XCTAssertEqual(r, AttachRequest(parent: 3, command: "make test", cwd: "/tmp", owner: 42, revealAfter: 1.5))
        guard case .failure = IPCRequest.parse(#"attach {"parent": 3, "command": ""}"#) else { return XCTFail() }
    }
}

final class JobBarLayoutTests: XCTestCase {
    func testFitsAtFullWidth() {
        let l = JobBarLayout(natural: [100, 50], available: 300)
        XCTAssertEqual(l.style, .full)
        XCTAssertEqual(l.frames, [0...100, 104...154])
        XCTAssertNil(l.overflow)
    }

    func testWidestTitlesTruncateFirst() {
        let l = JobBarLayout(natural: [300, 50, 200], available: 358)
        XCTAssertEqual(l.style, .full)
        XCTAssertEqual(l.frames.map { $0.upperBound - $0.lowerBound }, [150, 50, 150])
    }

    func testDotsWhenTitlesGetTooNarrow() {
        let l = JobBarLayout(natural: Array(repeating: 120, count: 10), available: 300)
        XCTAssertEqual(l.style, .dot)
        XCTAssertEqual(l.frames.count, 10)
        XCTAssertEqual(l.frames.last, 216...236)
        XCTAssertEqual(l.hidden, 0)
    }

    func testOverflowAfterDots() {
        let l = JobBarLayout(natural: Array(repeating: 120, count: 30), available: 200, overflowWidth: { _ in 30 })
        XCTAssertEqual(l.style, .dot)
        XCTAssertEqual(l.frames.count, 7, "7 × 24 + 30 fits 200")
        XCTAssertEqual(l.hidden, 23)
        XCTAssertEqual(l.overflow, 168...198)
    }

    func testOrderPutsAttentionFirst() {
        let status: [UInt64: String] = [1: "done", 2: "working", 3: "blocked", 4: "working"]
        let ids = [1, 2, 3, 4, 5].map { ClientID(UInt64($0)) }
        XCTAssertEqual(JobBarLayout.order(ids) { status[$0.raw] }.map(\.raw), [3, 2, 4, 5, 1])
    }

    func testElapsed() {
        XCTAssertEqual(JobBarLayout.elapsed(8.9), "8s")
        XCTAssertEqual(JobBarLayout.elapsed(72), "1m12s")
        XCTAssertEqual(JobBarLayout.elapsed(3600 + 180 + 5), "1h03m")
    }
}

final class JobBookTests: XCTestCase {
    func record(_ n: UInt64) -> JobRecord {
        JobRecord(id: ClientID(n), parent: ClientID(1), title: "job \(n)", log: nil, started: Date(timeIntervalSince1970: 0))
    }

    func testStates() {
        var book = JobBook()
        book.started(record(2))
        book.started(record(3))
        book.started(record(4))
        XCTAssertEqual(book.records[ClientID(2)]?.state, "running")
        book.exited(ClientID(2), status: 0)
        book.exited(ClientID(3), status: 2)
        book.closed(ClientID(4))
        XCTAssertEqual(book.list().map(\.state), ["done", "failed", "stopped"])
        book.closed(ClientID(2))
        book.exited(ClientID(4), status: 0)
        XCTAssertEqual(book.list().map(\.state), ["done", "failed", "stopped"], "closing keeps the exit; a late exit doesn't revive")
    }

    func testClosedOnesArePrunedOldestFirst() {
        var book = JobBook()
        book.keepClosed = 2
        for n in 2...5 { book.started(record(UInt64(n))) }
        for n in 2...4 { book.closed(ClientID(UInt64(n)), at: Date(timeIntervalSince1970: Double(n))) }
        XCTAssertEqual(book.list().map(\.id.raw), [3, 4, 5])
    }

    func testListByParent() {
        var book = JobBook()
        book.started(record(2))
        book.started(JobRecord(id: ClientID(3), parent: ClientID(9), title: "", log: nil, started: Date()))
        XCTAssertEqual(book.list(parent: ClientID(9)).map(\.id.raw), [3])
        guard case .success(.jobs(parent: 9)) = IPCRequest.parse("jobs --parent 9") else { return XCTFail() }
        guard case .success(.jobs(parent: nil)) = IPCRequest.parse("jobs") else { return XCTFail() }
    }
}
