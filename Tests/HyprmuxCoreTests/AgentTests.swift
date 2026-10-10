import Foundation
import XCTest
@testable import HyprmuxCore

final class AgentTests: XCTestCase {
    private func report(_ state: AgentState?, client: UInt64 = 3, kind: String = "pi", message: String? = nil,
                        session: String? = nil) -> AgentReport {
        AgentReport(client: client, pid: 100, kind: kind, state: state, session: session, message: message)
    }

    func testParsesTheReport() throws {
        guard case .agent(let r) = try IPCRequest.parse(
            #"agent {"client": 12, "pid": 4711, "kind": "claude", "state": "blocked", "message": "Allow rm?"}"#).get()
        else { return XCTFail("not an agent report") }
        XCTAssertEqual(r, AgentReport(client: 12, pid: 4711, kind: "claude", state: .blocked, message: "Allow rm?"))
        // A session-only report, like resume.
        guard case .agent(let s) = try IPCRequest.parse(#"agent {"client": 1, "pid": 2, "kind": "pi", "session": "abc"}"#).get()
        else { return XCTFail("not an agent report") }
        XCTAssertNil(s.state)
        XCTAssertEqual(s.resume, ResumeReport(client: 1, pid: 2, kind: "pi", session: "abc"))
        XCTAssertThrowsError(try IPCRequest.parse(#"agent {"client": 1, "pid": 2, "kind": "pi", "state": "sleeping"}"#).get())
        XCTAssertThrowsError(try IPCRequest.parse("agent working").get())
    }

    func testTurnFinishedUnseenShowsDone() {
        var t = AgentTracker()
        XCTAssertEqual(t.report(report(.idle), seen: false)?.to, .idle)  // a fresh agent, ready
        XCTAssertEqual(t.report(report(.working), seen: false)?.to, .working)
        let done = t.report(report(.idle), seen: false)
        XCTAssertEqual(done?.to, .done)
        XCTAssertEqual(done?.notice?.body, "Finished")
        // Repeating idle keeps it done; looking at it makes it idle.
        XCTAssertNil(t.report(report(.idle), seen: false))
        XCTAssertEqual(t.seen(ClientID(3))?.to, .idle)
        XCTAssertNil(t.seen(ClientID(3)))
    }

    func testTurnFinishedWhileWatchedIsIdle() {
        var t = AgentTracker()
        t.report(report(.working), seen: true)
        let c = t.report(report(.idle), seen: true)
        XCTAssertEqual(c?.to, .idle)
        XCTAssertNil(c?.notice)
    }

    func testBlockedCarriesItsMessage() {
        var t = AgentTracker()
        t.report(report(.working), seen: false)
        let c = t.report(report(.blocked, message: "Allow rm -rf build?"), seen: false)
        XCTAssertEqual(c?.to, .blocked)
        XCTAssertEqual(c?.notice?.title, "pi")
        XCTAssertEqual(c?.notice?.body, "Allow rm -rf build?")
        XCTAssertEqual(t[ClientID(3)]?.message, "Allow rm -rf build?")
        // Answered: back to work, the message goes.
        t.report(report(.working), seen: false)
        XCTAssertNil(t[ClientID(3)]?.message)
        // A block without a message still says so.
        XCTAssertEqual(t.report(report(.blocked), seen: false)?.notice?.body, "Needs you")
    }

    func testSessionOnlyReportsChangeNothing() {
        var t = AgentTracker()
        XCTAssertNil(t.report(report(nil, session: "abc"), seen: false))
        XCTAssertTrue(t.isEmpty)
    }

    func testRemoveAndPrune() {
        var t = AgentTracker()
        t.report(report(.working, client: 3), seen: false)
        t.report(report(.working, client: 5), seen: false)
        t.report(report(.working, client: 7), seen: false)
        XCTAssertEqual(t.remove(ClientID(3))?.to, nil)
        XCTAssertNil(t.remove(ClientID(3)))
        let gone = t.prune { id, _ in id == ClientID(5) }
        XCTAssertEqual(gone.map(\.id), [ClientID(7)])
        XCTAssertEqual(gone.first?.from, .working)
        XCTAssertEqual(Array(t.agents.keys), [ClientID(5)])
    }

    func testRollupIsTheMostUrgent() {
        var t = AgentTracker()
        t.report(report(.working, client: 1), seen: false)
        t.report(report(.working, client: 2), seen: false)
        t.report(report(.idle, client: 2), seen: false)  // done
        XCTAssertEqual(t.rollup([ClientID(1), ClientID(2)]), .done)
        t.report(report(.blocked, client: 1), seen: false)
        XCTAssertEqual(t.rollup([ClientID(1), ClientID(2), ClientID(9)]), .blocked)
        XCTAssertNil(t.rollup([ClientID(9)]))
    }

    func testEvent() {
        let c = AgentTracker.Change(id: ClientID(4), kind: "codex", from: .working, to: .done)
        XCTAssertEqual(HyprmuxEvent.agent(c).line, "agent>>4,codex,done")
        XCTAssertEqual(HyprmuxEvent.agent(AgentTracker.Change(id: ClientID(4), kind: "codex", from: .idle, to: nil)).line,
                       "agent>>4,codex,")
        XCTAssertTrue(HyprmuxEvent.names.contains("agent"))
    }

    func testWorkspaceActivityTally() {
        let tally = WorkspaceActivity.tally([
            (.regular(1), "working"), (.regular(1), "working"), (.regular(1), "blocked"),
            (.regular(2), "done"), (.regular(2), nil), (.regular(3), "idle"),
            (.special("magic"), "working"), (nil, "working"),
        ])
        XCTAssertEqual(tally, [1: WorkspaceActivity(blocked: 1, working: 2), 2: WorkspaceActivity(done: 1)])
        XCTAssertEqual(tally[1]?.counts.map(\.status), ["blocked", "working"])
        XCTAssertEqual(tally[1]?.summary, "1 needs you, 2 working")
        XCTAssertEqual(WorkspaceActivity(blocked: 2).summary, "2 need you")
        XCTAssertTrue(WorkspaceActivity().isEmpty)
    }

    func testWorkspaceActivityFinished() {
        typealias A = WorkspaceActivity
        // A turn ends: working becomes done.
        XCTAssertEqual(A.finished(from: A(working: 2), to: A(done: 1, working: 1)), ["working"])
        // Two at once, one of them from needs-you.
        XCTAssertEqual(A.finished(from: A(blocked: 1, working: 1), to: A(done: 2)), ["working", "blocked"])
        // A done tile appears with nothing ending (moved here): no drop.
        XCTAssertEqual(A.finished(from: A(working: 1), to: A(done: 1, working: 1)), [])
        // An agent exits without finishing, or a done tile is looked at.
        XCTAssertEqual(A.finished(from: A(working: 1), to: A()), [])
        XCTAssertEqual(A.finished(from: A(done: 1), to: A()), [])
    }

    func testWorkspacePickerActivity() {
        let tiles: [(workspace: WorkspaceID?, status: String?)] = [
            (.regular(1), "working"), (.special("magic"), "done"), (.regular(2), nil),
        ]
        let all = WorkspaceActivity.byWorkspace(tiles)
        XCTAssertEqual(all, [.regular(1): WorkspaceActivity(working: 1), .special("magic"): WorkspaceActivity(done: 1)])
        let choices = [
            WindowManager.WorkspaceChoice(id: .regular(1), name: "code", windows: 1, active: true),
            WindowManager.WorkspaceChoice(id: .regular(2), name: nil, windows: 1, active: false),
            WindowManager.WorkspaceChoice(id: .special("magic"), name: nil, windows: 1, active: false),
        ]
        let items = WorkspacePicker.items(choices, activity: all)
        XCTAssertEqual(items.map(\.activity), [WorkspaceActivity(working: 1), nil, WorkspaceActivity(done: 1)])
    }
}
