import CoreGraphics
import XCTest
@testable import HypermuxCore

final class DwindleTests: XCTestCase {
    let area = CGRect(x: 0, y: 0, width: 1600, height: 1000)

    func testFirstClientFillsArea() {
        let d = DwindleLayout()
        d.insert(ClientID(1), target: nil, focalPoint: nil, area: area)
        XCTAssertEqual(d.layout(in: area)[ClientID(1)], area)
    }

    func testSecondClientSplitsSideBySideOnWideArea() {
        let d = DwindleLayout()
        d.insert(ClientID(1), target: nil, focalPoint: nil, area: area)
        d.insert(ClientID(2), target: ClientID(1), focalPoint: nil, area: area)
        let l = d.layout(in: area)
        XCTAssertEqual(l[ClientID(1)], CGRect(x: 0, y: 0, width: 800, height: 1000))
        XCTAssertEqual(l[ClientID(2)], CGRect(x: 800, y: 0, width: 800, height: 1000))
    }

    func testDwindleSpiral() {
        let d = DwindleLayout()
        for i in 1...3 {
            d.insert(ClientID(UInt64(i)), target: i > 1 ? ClientID(UInt64(i - 1)) : nil, focalPoint: nil, area: area)
        }
        let l = d.layout(in: area)
        // 3rd client splits the right half (800x1000, tall) top/bottom.
        XCTAssertEqual(l[ClientID(2)], CGRect(x: 800, y: 0, width: 800, height: 500))
        XCTAssertEqual(l[ClientID(3)], CGRect(x: 800, y: 500, width: 800, height: 500))
    }

    func testFocalPointPicksSide() {
        let d = DwindleLayout()
        d.insert(ClientID(1), target: nil, focalPoint: nil, area: area)
        d.insert(ClientID(2), target: nil, focalPoint: CGPoint(x: 100, y: 500), area: area)
        let l = d.layout(in: area)
        XCTAssertEqual(l[ClientID(2)]?.minX, 0, "new client should take the half under the focal point")
    }

    func testRemovePromotesSibling() {
        let d = DwindleLayout()
        for i in 1...3 { d.insert(ClientID(UInt64(i)), target: ClientID(UInt64(max(1, i - 1))), focalPoint: nil, area: area) }
        d.remove(ClientID(2))
        let l = d.layout(in: area)
        XCTAssertEqual(l[ClientID(3)], CGRect(x: 800, y: 0, width: 800, height: 1000))
        XCTAssertEqual(d.clients, [ClientID(1), ClientID(3)])
    }

    func testResizeGrowsTheClient() {
        let d = DwindleLayout()
        d.insert(ClientID(1), target: nil, focalPoint: nil, area: area)
        d.insert(ClientID(2), target: ClientID(1), focalPoint: nil, area: area)
        d.layout(in: area)
        d.resize(ClientID(2), dx: 100, dy: 0)  // right client grows by moving its left edge
        XCTAssertEqual(d.layout(in: area)[ClientID(2)]?.width, 900)
        d.resize(ClientID(1), dx: 100, dy: 0)  // left client grows by moving its right edge
        XCTAssertEqual(d.layout(in: area)[ClientID(1)]?.width, 800)
    }

    func testMoveEdgeFollowsPointer() {
        // [1 | 2 | 3]: dragging an edge right moves that divider right, whichever client grabs it.
        let d = DwindleLayout()
        d.insert(ClientID(1), target: nil, focalPoint: nil, area: area)
        d.insert(ClientID(2), target: ClientID(1), focalPoint: nil, area: area)
        d.layout(in: area)
        d.moveEdge(ClientID(2), .left, by: 100)   // right client's left edge, dragged right
        var l = d.layout(in: area)
        XCTAssertEqual(l[ClientID(1)]?.width, 900)
        XCTAssertEqual(l[ClientID(2)]?.minX, 900)
        d.moveEdge(ClientID(1), .right, by: -200) // left client's right edge, dragged left
        l = d.layout(in: area)
        XCTAssertEqual(l[ClientID(2)]?.minX, 700)
        d.moveEdge(ClientID(1), .left, by: 50)    // on the work-area border: no-op
        XCTAssertEqual(d.layout(in: area)[ClientID(1)]?.minX, 0)
    }

    func testMoveEdgePicksTheRightDivider() {
        // [1 | [2 | 3]]: 2's left edge is the root divider; its right edge is the inner one.
        let d = DwindleLayout(settings: { var s = DwindleSettings(); s.preserveSplit = true; return s }())
        d.insert(ClientID(1), target: nil, focalPoint: nil, area: area)
        d.insert(ClientID(2), target: ClientID(1), focalPoint: nil, area: area)
        d.insert(ClientID(3), target: ClientID(2), focalPoint: nil, area: area)
        d.toggleSplit(ClientID(3))  // make the inner split side by side
        d.layout(in: area)
        d.moveEdge(ClientID(2), .left, by: -100)
        let l = d.layout(in: area)
        XCTAssertEqual(l[ClientID(1)]?.width, 700)
        XCTAssertEqual(l[ClientID(3)]?.maxX, 1600)
        XCTAssertEqual(l[ClientID(2)]?.minX, 700)
    }

    func testToggleSplitWithPreserve() {
        var s = DwindleSettings()
        s.preserveSplit = true
        let d = DwindleLayout(settings: s)
        d.insert(ClientID(1), target: nil, focalPoint: nil, area: area)
        d.insert(ClientID(2), target: ClientID(1), focalPoint: nil, area: area)
        d.toggleSplit(ClientID(2))
        let l = d.layout(in: area)
        XCTAssertEqual(l[ClientID(2)], CGRect(x: 0, y: 500, width: 1600, height: 500))
    }
}

final class WindowManagerTests: XCTestCase {
    func makeWM() -> WindowManager {
        var s = WMSettings()
        s.gapsIn = .zero
        s.gapsOut = .zero
        s.dwindle.forceSplit = 2
        return WindowManager(monitor: CGRect(x: 0, y: 0, width: 1600, height: 1000), settings: s)
    }

    func testFocusFollowsNewClient() {
        let wm = makeWM()
        wm.addClient(ClientID(1))
        wm.addClient(ClientID(2))
        XCTAssertEqual(wm.focused, ClientID(2))
    }

    func testMoveFocus() {
        let wm = makeWM()
        wm.addClient(ClientID(1))
        wm.addClient(ClientID(2))
        wm.dispatch(.moveFocus(.left))
        XCTAssertEqual(wm.focused, ClientID(1))
        wm.dispatch(.moveFocus(.left))
        XCTAssertEqual(wm.focused, ClientID(1), "no neighbor: focus stays")
        wm.dispatch(.moveFocus(.right))
        XCTAssertEqual(wm.focused, ClientID(2))
    }

    func testMoveWindowSwapsSidesOfTwo() {
        let wm = makeWM()
        wm.addClient(ClientID(1))
        wm.addClient(ClientID(2))
        wm.dispatch(.moveWindow(.left))
        let snap = wm.snapshot()
        XCTAssertEqual(snap.placement(ClientID(2))?.frame.minX, 0)
        XCTAssertEqual(snap.placement(ClientID(1))?.frame.minX, 800)
    }

    func testMoveWindowOutOfStack() {
        // [1 | 2/3]: moving 3 left puts it next to 1, and 2 takes the full right column.
        let wm = makeWM()
        wm.addClient(ClientID(1))
        wm.addClient(ClientID(2))
        wm.addClient(ClientID(3))
        wm.dispatch(.moveWindow(.left))
        let snap = wm.snapshot()
        XCTAssertEqual(snap.placement(ClientID(2))?.frame, CGRect(x: 800, y: 0, width: 800, height: 1000))
        XCTAssertLessThan(snap.placement(ClientID(3))!.frame.minX, 800)
    }

    func testWorkspaces() {
        let wm = makeWM()
        wm.addClient(ClientID(1))
        wm.dispatch(.workspace(.id(2)))
        XCTAssertNil(wm.focused)
        wm.addClient(ClientID(2))
        XCTAssertEqual(wm.workspace(of: ClientID(2)), .regular(2))
        XCTAssertEqual(wm.snapshot().workspaces, [1, 2])
        wm.dispatch(.workspace(.id(1)))
        XCTAssertEqual(wm.focused, ClientID(1))
        XCTAssertEqual(wm.snapshot().placement(ClientID(2))?.visible, false)
        wm.dispatch(.workspace(.previous))
        XCTAssertEqual(wm.activeWorkspace, 2)
    }

    func testMoveToWorkspaceFollowsAndSilent() {
        let wm = makeWM()
        wm.addClient(ClientID(1))
        wm.addClient(ClientID(2))
        wm.dispatch(.moveToWorkspace(.id(3), silent: true))
        XCTAssertEqual(wm.activeWorkspace, 1)
        XCTAssertEqual(wm.focused, ClientID(1))
        XCTAssertEqual(wm.snapshot().placement(ClientID(1))?.frame.width, 1600)
        wm.dispatch(.moveToWorkspace(.id(3), silent: false))
        XCTAssertEqual(wm.activeWorkspace, 3)
        XCTAssertEqual(wm.focused, ClientID(1))
        XCTAssertEqual(wm.snapshot().workspaces, [3])
    }

    func testEmptyWorkspacesAreCollected() {
        let wm = makeWM()
        wm.dispatch(.workspace(.id(4)))
        wm.dispatch(.workspace(.id(5)))
        XCTAssertEqual(wm.snapshot().workspaces, [5])
    }

    func testRelativeExisting() {
        let wm = makeWM()
        wm.addClient(ClientID(1))
        wm.dispatch(.workspace(.id(3)))
        wm.addClient(ClientID(2))
        wm.dispatch(.workspace(.relativeExisting(1)))
        XCTAssertEqual(wm.activeWorkspace, 1, "wraps around")
        wm.dispatch(.workspace(.relativeExisting(1)))
        XCTAssertEqual(wm.activeWorkspace, 3)
    }

    func testSpecialWorkspace() {
        let wm = makeWM()
        wm.addClient(ClientID(1))
        wm.dispatch(.toggleSpecialWorkspace("magic"))
        XCTAssertEqual(wm.specialVisible, "magic")
        wm.addClient(ClientID(2))
        XCTAssertEqual(wm.workspace(of: ClientID(2)), .special("magic"))
        wm.dispatch(.toggleSpecialWorkspace("magic"))
        XCTAssertNil(wm.specialVisible)
        XCTAssertEqual(wm.focused, ClientID(1))
        XCTAssertEqual(wm.snapshot().placement(ClientID(2))?.visible, false)
    }

    func testFloatingToggleKeepsFrame() {
        let wm = makeWM()
        wm.addClient(ClientID(1))
        wm.addClient(ClientID(2))
        let before = wm.snapshot().placement(ClientID(2))!.frame
        wm.dispatch(.toggleFloating)
        let snap = wm.snapshot()
        XCTAssertEqual(snap.placement(ClientID(2))?.frame, before)
        XCTAssertEqual(snap.placement(ClientID(2))?.floating, true)
        XCTAssertEqual(snap.placement(ClientID(1))?.frame.width, 1600)
        XCTAssertGreaterThan(snap.placement(ClientID(2))!.z, snap.placement(ClientID(1))!.z)
        wm.dispatch(.toggleFloating)
        XCTAssertEqual(wm.snapshot().placement(ClientID(2))?.floating, false)
    }

    func testUnfloatReturnsToSameSpot() {
        let wm = makeWM()
        for i in 1...4 { wm.addClient(ClientID(UInt64(i))) }
        let before = wm.snapshot().placements.reduce(into: [ClientID: CGRect]()) { $0[$1.id] = $1.frame }
        for id in [2, 1, 4].map({ ClientID(UInt64($0)) }) {
            wm.focus(id)
            wm.dispatch(.toggleFloating)
            wm.setFloatingFrame(id, CGRect(x: 1200, y: 800, width: 200, height: 100))  // far from its old spot
            wm.dispatch(.toggleFloating)
            let after = wm.snapshot().placements.reduce(into: [ClientID: CGRect]()) { $0[$1.id] = $1.frame }
            XCTAssertEqual(after, before, "re-tiling \(id) should restore the layout exactly")
        }
    }

    func testUnfloatFallsBackWhenNeighborGone() {
        let wm = makeWM()
        wm.addClient(ClientID(1))
        wm.addClient(ClientID(2))
        wm.dispatch(.toggleFloating)       // float 2; its sibling was 1
        wm.addClient(ClientID(3))          // 3 tiles next to 1
        wm.removeClient(ClientID(1))
        wm.focus(ClientID(2))
        wm.dispatch(.toggleFloating)
        let snap = wm.snapshot()
        XCTAssertEqual(snap.placement(ClientID(2))?.floating, false)
        XCTAssertEqual(snap.placements.filter { !$0.floating }.count, 2)
    }

    func testFloatingAloneStartsCentered() {
        let wm = makeWM()
        wm.addClient(ClientID(1))
        wm.dispatch(.toggleFloating)
        let f = wm.snapshot().placement(ClientID(1))!.frame
        XCTAssertEqual(f, CGRect(x: 320, y: 200, width: 960, height: 600), "60% of 1600x1000, centered")
    }

    func testFullscreen() {
        let wm = makeWM()
        wm.reserved = Insets(top: 30, right: 0, bottom: 0, left: 0)
        wm.addClient(ClientID(1))
        wm.addClient(ClientID(2))
        wm.dispatch(.fullscreen(.fullscreen))
        XCTAssertEqual(wm.snapshot().placement(ClientID(2))?.frame, wm.monitor)
        wm.dispatch(.fullscreen(.fullscreen))
        XCTAssertNil(wm.snapshot().placement(ClientID(2))?.fullscreen)
    }

    func testRemoveFocusesMostRecent() {
        let wm = makeWM()
        wm.addClient(ClientID(1))
        wm.addClient(ClientID(2))
        wm.addClient(ClientID(3))
        wm.focus(ClientID(1))
        wm.focus(ClientID(3))
        wm.removeClient(ClientID(3))
        XCTAssertEqual(wm.focused, ClientID(1))
    }

    func testGaps() {
        var s = WMSettings()
        s.gapsIn = Insets(all: 5)
        s.gapsOut = Insets(all: 20)
        s.dwindle.forceSplit = 2
        let wm = WindowManager(monitor: CGRect(x: 0, y: 0, width: 1600, height: 1000), settings: s)
        wm.addClient(ClientID(1))
        wm.addClient(ClientID(2))
        let snap = wm.snapshot()
        XCTAssertEqual(snap.placement(ClientID(1))?.frame, CGRect(x: 20, y: 20, width: 775, height: 960))
        XCTAssertEqual(snap.placement(ClientID(2))?.frame, CGRect(x: 805, y: 20, width: 775, height: 960))
    }

    func testEffects() {
        let wm = makeWM()
        var effects: [Effect] = []
        wm.perform = { effects.append($0) }
        wm.addClient(ClientID(7))
        wm.dispatch(.exec("htop"))
        wm.dispatch(.killActive)
        XCTAssertEqual(effects, [.spawn(command: "htop"), .close(ClientID(7))])
    }
}
