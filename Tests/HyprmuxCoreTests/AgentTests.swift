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
}
