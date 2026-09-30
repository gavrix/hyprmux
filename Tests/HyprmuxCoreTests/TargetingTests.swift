import CoreGraphics
import XCTest
@testable import HyprmuxCore

/// Opening windows in the background and dispatching on a window that isn't focused
/// (`new-surface`, `dispatch --surface`).
final class TargetingTests: XCTestCase {
    func makeWM() -> WindowManager {
        var s = WMSettings()
        s.gapsIn = .zero
        s.gapsOut = .zero
        s.dwindle.forceSplit = 2
        return WindowManager(monitor: CGRect(x: 0, y: 0, width: 1600, height: 1000), settings: s)
    }

    // MARK: Opening without focus

    func testBackgroundClientOnAnotherWorkspace() {
        let wm = makeWM()
        wm.addClient(ClientID(1))
        wm.addClient(ClientID(2), workspace: .regular(3), focus: false)
        XCTAssertEqual(wm.focused, ClientID(1))
        XCTAssertEqual(wm.activeWorkspace, 1)
        XCTAssertEqual(wm.workspace(of: ClientID(2)), .regular(3))
        XCTAssertEqual(wm.snapshot().placement(ClientID(2))?.visible, false)
        XCTAssertEqual(wm.snapshot().workspaces, [1, 3])
        wm.dispatch(.workspace(.id(3)))
        XCTAssertEqual(wm.focused, ClientID(2), "arriving focuses it")
    }

    func testBackgroundClientDoesNotSwitchWorkspaceWhenNothingIsFocused() {
        let wm = makeWM()
        wm.addClient(ClientID(1), workspace: .regular(2), focus: false)
        XCTAssertNil(wm.focused)
        XCTAssertEqual(wm.activeWorkspace, 1)
    }

    func testBackgroundClientInViewTakesFocusOnlyWhenNothingHasIt() {
        let wm = makeWM()
        wm.addClient(ClientID(1), focus: false)
        XCTAssertEqual(wm.focused, ClientID(1), "an empty screen gives it focus")
        wm.addClient(ClientID(2), focus: false)
        XCTAssertEqual(wm.focused, ClientID(1))
        XCTAssertEqual(wm.snapshot().placement(ClientID(2))?.frame.width, 800, "still tiles next to it")
    }

    func testBackgroundClientJoinsFocusedGroupAsHiddenTab() {
        let wm = makeWM()
        wm.addClient(ClientID(1))
        wm.dispatch(.toggleGroup)
        wm.addClient(ClientID(2), focus: false)
        let info = wm.snapshot().placement(ClientID(1))?.group
        XCTAssertEqual(info?.members, [ClientID(1), ClientID(2)])
        XCTAssertEqual(info?.active, ClientID(1))
        XCTAssertEqual(wm.focused, ClientID(1))
    }

    func testBackgroundClientKeepsFullscreen() {
        let wm = makeWM()
        wm.addClient(ClientID(1))
        wm.dispatch(.fullscreen(.fullscreen))
        wm.addClient(ClientID(2), focus: false)
        XCTAssertEqual(wm.snapshot().placement(ClientID(1))?.fullscreen, .fullscreen)
        wm.addClient(ClientID(3))
        XCTAssertNil(wm.snapshot().placement(ClientID(1))?.fullscreen, "a focused new window ends it")
    }

    func testClaimWorkspaceNamesANewOne() {
        let wm = makeWM()
        wm.addClient(ClientID(1))
        XCTAssertEqual(wm.claimWorkspace(.named("mail")), .regular(2))
        XCTAssertEqual(wm.name(of: 2), "mail")
        XCTAssertEqual(wm.claimWorkspace(.named("mail")), .regular(2))
        XCTAssertNil(wm.claimWorkspace(.previous))
    }

    // MARK: Dispatching on another window

    func testTargetedSilentMoveLeavesFocusAlone() {
        let wm = makeWM()
        wm.addClient(ClientID(1))
        wm.addClient(ClientID(2))
        wm.dispatch(.moveToWorkspace(.id(4), silent: true), target: ClientID(1))
        XCTAssertEqual(wm.focused, ClientID(2))
        XCTAssertEqual(wm.activeWorkspace, 1)
        XCTAssertEqual(wm.workspace(of: ClientID(1)), .regular(4))
        XCTAssertEqual(wm.snapshot().placement(ClientID(2))?.frame.width, 1600)
    }

    func testTargetedSilentMoveIntoTheFocusedWorkspaceKeepsItsLastFocus() {
        let wm = makeWM()
        wm.addClient(ClientID(1))
        wm.addClient(ClientID(2), workspace: .regular(2), focus: false)
        wm.dispatch(.moveToWorkspace(.id(1), silent: true), target: ClientID(2))
        XCTAssertEqual(wm.focused, ClientID(1))
        wm.dispatch(.workspace(.id(3)))
        wm.dispatch(.workspace(.id(1)))
        XCTAssertEqual(wm.focused, ClientID(1), "coming back focuses what was focused, not the arrival")
    }

    func testTargetedMoveFollows() {
        let wm = makeWM()
        wm.addClient(ClientID(1))
        wm.addClient(ClientID(2))
        wm.dispatch(.moveToWorkspace(.id(4), silent: false), target: ClientID(1))
        XCTAssertEqual(wm.activeWorkspace, 4)
        XCTAssertEqual(wm.focused, ClientID(1))
    }

    func testTargetedLayoutDispatchersKeepFocus() {
        let wm = makeWM()
        wm.addClient(ClientID(1))
        wm.addClient(ClientID(2))
        wm.dispatch(.moveWindow(.right), target: ClientID(1))
        var snap = wm.snapshot()
        XCTAssertEqual(snap.placement(ClientID(1))?.frame.minX, 800)
        XCTAssertEqual(snap.focused, ClientID(2))
        wm.dispatch(.toggleFloating, target: ClientID(1))
        snap = wm.snapshot()
        XCTAssertEqual(snap.placement(ClientID(1))?.floating, true)
        XCTAssertEqual(snap.placement(ClientID(2))?.frame.width, 1600)
        XCTAssertEqual(snap.focused, ClientID(2))
    }

    func testTargetOnAHiddenWorkspace() {
        let wm = makeWM()
        wm.addClient(ClientID(1))
        wm.addClient(ClientID(2), workspace: .regular(2), focus: false)
        wm.addClient(ClientID(3), workspace: .regular(2), focus: false)
        wm.dispatch(.swapWindow(.left), target: ClientID(3))
        let snap = wm.snapshot()
        XCTAssertEqual(snap.placement(ClientID(3))?.frame.minX, 0)
        XCTAssertEqual(snap.activeWorkspace, 1)
        XCTAssertEqual(snap.focused, ClientID(1))
    }

    func testTargetedHiddenTabMovesItsGroup() {
        let wm = makeWM()
        wm.addClient(ClientID(1))
        wm.dispatch(.toggleGroup)
        wm.addClient(ClientID(2))  // auto-grouped, shown
        wm.addClient(ClientID(3), workspace: .regular(2), focus: false)
        wm.dispatch(.workspace(.id(2)))
        XCTAssertEqual(wm.focused, ClientID(3))
        wm.dispatch(.moveToWorkspace(.id(5), silent: true), target: ClientID(1))  // hidden tab
        XCTAssertEqual(wm.workspace(of: ClientID(1)), .regular(5))
        XCTAssertEqual(wm.workspace(of: ClientID(2)), .regular(5))
        XCTAssertEqual(wm.snapshot().workspaces, [2, 5], "workspace 1 emptied")
        XCTAssertEqual(wm.focused, ClientID(3))
        wm.dispatch(.moveToWorkspace(.id(2), silent: false), target: ClientID(1))
        XCTAssertEqual(wm.focused, ClientID(1), "following a hidden tab shows and focuses it")
        XCTAssertEqual(wm.snapshot().placement(ClientID(1))?.group?.active, ClientID(1))
    }

    func testTargetedGroupDispatchers() {
        let wm = makeWM()
        wm.addClient(ClientID(1))
        wm.addClient(ClientID(2))
        wm.dispatch(.toggleGroup, target: ClientID(1))
        XCTAssertNotNil(wm.snapshot().placement(ClientID(1))?.group)
        // 3 joins 1's group from the right, behind the shown tab.
        wm.addClient(ClientID(3), focus: false)
        wm.dispatch(.moveIntoGroup(.left), target: ClientID(3))
        var info = wm.snapshot().placement(ClientID(1))?.group
        XCTAssertEqual(info?.members, [ClientID(1), ClientID(3)])
        XCTAssertEqual(info?.active, ClientID(1))
        XCTAssertEqual(wm.focused, ClientID(2))
        wm.dispatch(.changeGroupActive(.next), target: ClientID(1))
        info = wm.snapshot().placement(ClientID(3))?.group
        XCTAssertEqual(info?.active, ClientID(3))
        XCTAssertEqual(wm.focused, ClientID(2), "shows the tab without focusing it")
        wm.dispatch(.moveOutOfGroup, target: ClientID(1))
        XCTAssertNil(wm.snapshot().placement(ClientID(1))?.group)
        XCTAssertEqual(wm.snapshot().placement(ClientID(1))?.visible, true)
        XCTAssertEqual(wm.focused, ClientID(2))
    }

    func testTargetedFocusDispatchersMoveFocus() {
        let wm = makeWM()
        wm.addClient(ClientID(1))
        wm.addClient(ClientID(2))
        wm.addClient(ClientID(3), workspace: .regular(2), focus: false)
        wm.addClient(ClientID(4), workspace: .regular(2), focus: false)
        wm.dispatch(.cycleNext(previous: false), target: ClientID(3))
        XCTAssertEqual(wm.focused, ClientID(4), "the next window after the target")
        XCTAssertEqual(wm.activeWorkspace, 2)
    }

    func testTargetedCloseAndIgnoredTargets() {
        let wm = makeWM()
        var effects: [Effect] = []
        wm.perform = { effects.append($0) }
        wm.addClient(ClientID(1))
        wm.addClient(ClientID(2))
        wm.dispatch(.killActive, target: ClientID(1))
        XCTAssertEqual(effects, [.close(ClientID(1))])
        wm.dispatch(.workspace(.id(3)), target: ClientID(1))
        XCTAssertEqual(wm.activeWorkspace, 1, "workspace doesn't act on a window")
        wm.dispatch(.killActive, target: ClientID(9))
        XCTAssertEqual(effects.count, 1, "an unknown window does nothing")
    }
}
