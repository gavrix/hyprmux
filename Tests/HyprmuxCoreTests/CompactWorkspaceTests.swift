import CoreGraphics
import XCTest
@testable import HyprmuxCore

/// `compactWorkspaces`: regular workspaces stay numbered 1…N, and the ones after a
/// closed workspace shift down.
final class CompactWorkspaceTests: XCTestCase {
    func makeWM(names: [Int: String] = [:]) -> WindowManager {
        var s = WMSettings()
        s.gapsIn = .zero
        s.gapsOut = .zero
        s.autoGroup = false
        s.workspaceNames = names
        XCTAssertTrue(s.compactWorkspaces, "on by default")
        return WindowManager(monitor: CGRect(x: 0, y: 0, width: 1600, height: 1000), settings: s)
    }

    /// Clients 1…n, one on each of workspaces 1…n. Ends on workspace 1.
    func makeFilled(_ n: Int, names: [Int: String] = [:]) -> WindowManager {
        let wm = makeWM(names: names)
        for i in 1...n {
            wm.addClient(ClientID(UInt64(i)), workspace: .regular(i), focus: false)
        }
        XCTAssertEqual(wm.snapshot().workspaces, Array(1...n))
        return wm
    }

    func testClosingAWorkspaceShiftsTheOnesAfterIt() {
        let wm = makeFilled(4)
        wm.removeClient(ClientID(2))  // in the background
        XCTAssertEqual(wm.snapshot().workspaces, [1, 2, 3])
        XCTAssertEqual(wm.workspace(of: ClientID(3)), .regular(2))
        XCTAssertEqual(wm.workspace(of: ClientID(4)), .regular(3))
        XCTAssertEqual(wm.activeWorkspace, 1)
    }

    func testLeavingAnEmptiedWorkspaceShiftsTheActiveNumber() {
        let wm = makeFilled(4)
        wm.dispatch(.workspace(.id(2)))
        wm.removeClient(ClientID(2))
        XCTAssertEqual(wm.snapshot().workspaces, [1, 2, 3, 4], "the active workspace stays while you're on it")
        wm.dispatch(.workspace(.id(4)))
        XCTAssertEqual(wm.activeWorkspace, 3)
        XCTAssertEqual(wm.focused, ClientID(4))
        XCTAssertEqual(wm.snapshot().workspaces, [1, 2, 3])
    }

    func testMovingTheLastWindowOutShifts() {
        let wm = makeFilled(3)
        wm.focus(ClientID(1))
        wm.dispatch(.moveToWorkspace(.id(3), silent: false))
        XCTAssertEqual(wm.activeWorkspace, 2)
        XCTAssertEqual(wm.workspace(of: ClientID(1)), .regular(2))
        XCTAssertEqual(wm.workspace(of: ClientID(2)), .regular(1))
        XCTAssertEqual(wm.snapshot().workspaces, [1, 2])
    }

    func testANumberPastTheEndOpensTheNextWorkspace() {
        let wm = makeFilled(3)
        wm.dispatch(.workspace(.id(9)))
        XCTAssertEqual(wm.activeWorkspace, 4)
        wm.dispatch(.workspace(.id(1)))
        XCTAssertEqual(wm.snapshot().workspaces, [1, 2, 3], "the empty one closed")
        wm.focus(ClientID(1))
        wm.dispatch(.moveToWorkspace(.id(7), silent: true))
        XCTAssertEqual(wm.workspace(of: ClientID(1)), .regular(4))
        wm.addClient(ClientID(9), workspace: .regular(12), focus: false)
        XCTAssertEqual(wm.workspace(of: ClientID(9)), .regular(5))
        XCTAssertEqual(wm.snapshot().workspaces, [1, 2, 3, 4, 5], "the active one stays, empty")
        wm.dispatch(.workspace(.id(2)))
        XCTAssertEqual(wm.activeWorkspace, 1)
        XCTAssertEqual(wm.workspace(of: ClientID(1)), .regular(3))
        XCTAssertEqual(wm.snapshot().workspaces, [1, 2, 3, 4])
    }

    func testRelativeTargetsStayInRange() {
        let wm = makeFilled(2)
        wm.dispatch(.workspace(.id(2)))
        wm.dispatch(.workspace(.relative(5)))
        XCTAssertEqual(wm.activeWorkspace, 3)
        wm.dispatch(.workspace(.relative(-1)))
        XCTAssertEqual(wm.activeWorkspace, 2)
        XCTAssertEqual(wm.snapshot().workspaces, [1, 2])
    }

    func testANamedWorkspaceStaysOpenUntilItsNameIsCleared() {
        let wm = makeFilled(2)
        wm.dispatch(.workspace(.id(3)))
        wm.dispatch(.renameWorkspace(3, "notes"))
        wm.dispatch(.workspace(.id(1)))
        var snap = wm.snapshot()
        XCTAssertEqual(snap.workspaces, [1, 2, 3], "shown in the bar, empty")
        XCTAssertEqual(snap.workspaceNames, [3: "notes"])
        XCTAssertEqual(wm.workspaceChoices().map(\.id), [.regular(1), .regular(2), .regular(3)])
        XCTAssertEqual(wm.workspace(named: "NOTES"), 3)
        // It's in the e+1 ring too.
        wm.dispatch(.workspace(.relativeExisting(-1)))
        XCTAssertEqual(wm.activeWorkspace, 3)
        wm.dispatch(.workspace(.id(1)))

        wm.dispatch(.renameWorkspace(3, ""))
        snap = wm.snapshot()
        XCTAssertEqual(snap.workspaces, [1, 2])
        XCTAssertNil(wm.name(of: 3))
    }

    func testClearingTheNameOfAMiddleWorkspaceShifts() {
        let wm = makeFilled(1)
        wm.dispatch(.workspace(.named("mail")))   // 2, named
        wm.dispatch(.workspace(.id(3)))
        wm.addClient(ClientID(3))
        wm.dispatch(.renameWorkspace(2, ""))
        XCTAssertEqual(wm.snapshot().workspaces, [1, 2])
        XCTAssertEqual(wm.activeWorkspace, 2)
        XCTAssertEqual(wm.workspace(of: ClientID(3)), .regular(2))
    }

    func testNamesShiftWithTheirWorkspaces() {
        let wm = makeFilled(3)
        wm.dispatch(.renameWorkspace(3, "mail"))
        wm.removeClient(ClientID(2))
        XCTAssertEqual(wm.name(of: 2), "mail")
        XCTAssertNil(wm.name(of: 3))
        XCTAssertEqual(wm.snapshot().workspaceNames, [2: "mail"])
    }

    func testRenamingAClosedNumberDoesNothing() {
        let wm = makeFilled(2)
        wm.dispatch(.renameWorkspace(5, "x"))
        XCTAssertNil(wm.name(of: 5))
        XCTAssertEqual(wm.snapshot().workspaces, [1, 2])
    }

    func testANewNameOpensAWorkspaceAfterTheOthers() {
        let wm = makeFilled(2, names: [7: "music"])
        wm.dispatch(.workspace(.named("mail")))
        XCTAssertEqual(wm.activeWorkspace, 3)
        XCTAssertEqual(wm.name(of: 3), "mail")
        // A rule's name past the end opens the next number and names it.
        wm.dispatch(.workspace(.named("music")))
        XCTAssertEqual(wm.activeWorkspace, 4)
        XCTAssertEqual(wm.name(of: 4), "music")
        XCTAssertEqual(wm.workspace(named: "music"), 4)
        // Silent claims, as `new-surface --workspace name:NEW` makes them, open it too.
        XCTAssertEqual(wm.claimWorkspace(.named("chat")), .regular(5))
        XCTAssertEqual(wm.snapshot().workspaces, [1, 2, 3, 4, 5])
    }

    func testPreviousFollowsAShiftAndForgetsAClosedWorkspace() {
        let wm = makeFilled(3)
        wm.dispatch(.workspace(.id(3)))
        wm.dispatch(.workspace(.id(1)))
        XCTAssertEqual(wm.previousWorkspace, 3)
        wm.removeClient(ClientID(2))
        XCTAssertEqual(wm.previousWorkspace, 2)
        wm.dispatch(.workspace(.previous))
        XCTAssertEqual(wm.focused, ClientID(3))

        wm.dispatch(.workspace(.id(3)))  // new, empty
        wm.dispatch(.workspace(.id(1)))  // closes it
        XCTAssertNil(wm.previousWorkspace)
    }

    // MARK: Snapshots across a shift

    func testABackgroundShiftIsNotASwitch() {
        let wm = makeFilled(4)
        wm.dispatch(.workspace(.id(4)))
        let before = wm.snapshot()
        wm.removeClient(ClientID(2))
        let after = wm.snapshot()
        XCTAssertEqual(after.activeWorkspace, 3)
        XCTAssertEqual(after.workspaceSwitch(from: before), 0)
        XCTAssertTrue(after.isSameWorkspace(.regular(3), as: .regular(4), in: before))
        XCTAssertFalse(after.isSameWorkspace(.regular(2), as: .regular(2), in: before))
        XCTAssertEqual(after.renumbering(from: before), [3: 2, 4: 3])
    }

    func testSwitchingFromAnEmptiedWorkspaceGoesRight() {
        let wm = makeFilled(3)
        wm.dispatch(.workspace(.id(2)))
        wm.removeClient(ClientID(2))
        let before = wm.snapshot()
        wm.dispatch(.workspace(.id(3)))
        let after = wm.snapshot()
        XCTAssertEqual(after.activeWorkspace, 2, "same number, other workspace")
        XCTAssertGreaterThan(after.workspaceSwitch(from: before), 0)
        wm.dispatch(.workspace(.id(1)))
        XCTAssertLessThan(wm.snapshot().workspaceSwitch(from: after), 0)
    }

    func testANewWorkspaceOpensToTheRight() {
        let wm = makeFilled(2)
        wm.dispatch(.workspace(.id(3)))
        let before = wm.snapshot()
        wm.dispatch(.workspace(.id(9)))  // 4, then the empty 3 closes
        let after = wm.snapshot()
        XCTAssertEqual(after.activeWorkspace, 3)
        XCTAssertGreaterThan(after.workspaceSwitch(from: before), 0)
    }

    func testEventsDescribeTheNewNumbers() {
        let wm = makeFilled(4)
        wm.dispatch(.renameWorkspace(4, "mail"))
        wm.dispatch(.workspace(.id(4)))
        let before = wm.snapshot()
        wm.removeClient(ClientID(2))
        let events = EventDiff.events(from: before, to: wm.snapshot()) { _ in EventDiff.Tile(kind: "terminal", title: "") }
            .map { "\($0.name)>>\($0.data)" }
        XCTAssertEqual(Set(events), [
            "closewindow>>2", "movewindow>>3,2", "movewindow>>4,3",
            "renameworkspace>>3,mail", "workspace>>3", "workspacev2>>3,mail", "destroyworkspace>>4",
        ])
    }

    // MARK: Sessions and layouts

    func testRestoringASessionWithGapsCompactsIt() throws {
        let json = """
        {
          "activeWorkspace": 5,
          "names": {"5": "web", "7": "notes"},
          "workspaces": [
            {"id": "2", "tiled": {"kind": "terminal"}},
            {"id": "5", "tiled": {"kind": "terminal"}}
          ]
        }
        """
        let wm = makeWM()
        var n: UInt64 = 0
        wm.restoreSession(try SessionState.decode(Data(json.utf8))) { _ in n += 1; return ClientID(n) }
        let snap = wm.snapshot()
        XCTAssertEqual(snap.workspaces, [1, 2, 3])
        XCTAssertEqual(snap.workspaceNames, [2: "web", 3: "notes"])
        XCTAssertEqual(wm.activeWorkspace, 2)
        XCTAssertEqual(wm.focused, ClientID(2))
    }

    func testLoadingALayoutReportsShiftedNumbers() throws {
        let layout = try SessionState.decode(Data(#"{"workspaces": [{"tiled": {"kind": "terminal"}}]}"#.utf8))
        // 1 has only a rule's name, so the layout skips it, and it closes when the layout shows.
        let wm = makeWM(names: [1: "home"])
        wm.addClient(ClientID(1), workspace: .regular(2), focus: false)
        var n: UInt64 = 10
        XCTAssertEqual(wm.loadLayout(layout, defaultName: "dev") { _ in n += 1; return ClientID(n) }, [2])
        XCTAssertEqual(wm.activeWorkspace, 2)
        XCTAssertEqual(wm.name(of: 2), "dev")
        XCTAssertEqual(wm.workspace(of: ClientID(1)), .regular(1))
        XCTAssertEqual(wm.focused, ClientID(11))
    }

    func testConfig() {
        XCTAssertTrue(ConfigParser.parse("").wm.compactWorkspaces)
        XCTAssertFalse(ConfigParser.parse("hyprmux {\n compact_workspaces = false\n}").wm.compactWorkspaces)
    }
}
