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

    func testPreviewSitsInParentsTopRightCornerAboveIt() throws {
        let wm = makeWM()
        wm.addClient(parent)
        wm.addAttached(job, to: parent)
        let snap = wm.snapshot()
        let p = try XCTUnwrap(snap.placement(parent))
        let a = try XCTUnwrap(snap.placement(job))
        XCTAssertEqual(wm.focused, parent, "attaching doesn't take focus")
        XCTAssertTrue(a.visible)
        XCTAssertEqual(a.attachment?.parent, parent)
        XCTAssertEqual(a.attachment?.expanded, false)
        XCTAssertTrue(p.frame.contains(a.frame))
        XCTAssertEqual(a.frame.maxX, p.frame.maxX - 12)
        XCTAssertEqual(a.frame.minY, p.frame.minY + 12)
        // Content scales uniformly from the expanded frame.
        let e = try XCTUnwrap(a.attachment?.expandedFrame)
        XCTAssertEqual(a.frame.width - 4, ((e.width - 4) * 0.25).rounded())
        XCTAssertEqual(a.frame.height - 4, ((e.height - 4) * 0.25).rounded())
        XCTAssertEqual(snap.placements.last?.id, job, "stacks just above its parent")
        XCTAssertEqual(wm.workspace(of: job), .regular(1))
    }

    func testSecondPreviewStacksBelowFirst() throws {
        let wm = makeWM()
        wm.addClient(parent)
        wm.addAttached(job, to: parent)
        wm.addAttached(job2, to: parent)
        let snap = wm.snapshot()
        let a = try XCTUnwrap(snap.placement(job)), b = try XCTUnwrap(snap.placement(job2))
        XCTAssertEqual(b.frame.minX, a.frame.minX)
        XCTAssertEqual(b.frame.minY, a.frame.maxY + 8)
    }

    func testPreviewIsNotInLayout() {
        let wm = makeWM()
        wm.addClient(parent)
        wm.addAttached(job, to: parent)
        XCTAssertEqual(wm.snapshot().placement(parent)?.frame, CGRect(x: 0, y: 0, width: 1600, height: 1000))
        wm.addClient(other)
        XCTAssertEqual(wm.snapshot().placement(parent)?.frame.width, 800)
    }

    func testUnrevealedPreviewIsHiddenAndTakesNoSlot() throws {
        let wm = makeWM()
        wm.addClient(parent)
        wm.addAttached(job, to: parent, revealed: false)
        wm.addAttached(job2, to: parent)
        var snap = wm.snapshot()
        XCTAssertEqual(snap.placement(job)?.visible, false)
        XCTAssertEqual(snap.preview(of: .regular(1)).map(\.id), [parent, job2])
        let first = try XCTUnwrap(snap.placement(job2)).frame
        XCTAssertEqual(first.minY, 12, "the hidden one leaves the first slot free")
        wm.setAttachedRevealed(job, true)
        snap = wm.snapshot()
        XCTAssertEqual(snap.placement(job)?.visible, true)
        XCTAssertEqual(snap.placement(job)?.frame.minY, 12)
    }

    func testFocusExpandsAndLeavingCollapses() throws {
        let wm = makeWM()
        wm.addClient(parent)
        wm.addClient(other)
        wm.focus(parent)
        wm.addAttached(job, to: parent)
        wm.focus(job)
        var a = try XCTUnwrap(wm.snapshot().placement(job))
        XCTAssertEqual(a.attachment?.expanded, true)
        XCTAssertEqual(a.frame, a.attachment?.expandedFrame)
        let p = try XCTUnwrap(wm.snapshot().placement(parent))
        XCTAssertEqual(a.frame, p.frame.insetBy(dx: 24, dy: 24))
        wm.focus(other)
        a = try XCTUnwrap(wm.snapshot().placement(job))
        XCTAssertEqual(a.attachment?.expanded, false)
        XCTAssertLessThan(a.frame.width, p.frame.width / 2)
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
        XCTAssertEqual(wm.snapshot().placement(job)?.visible, true)
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
        XCTAssertEqual(wm.snapshot().placement(job)?.visible, false)
        wm.focus(job)
        let snap = wm.snapshot()
        XCTAssertEqual(snap.placement(parent)?.visible, true, "expanding it shows its tab")
        XCTAssertEqual(snap.placement(job)?.visible, true)
    }

    func testFullscreenParentCarriesPreview() throws {
        let wm = makeWM()
        wm.addClient(parent)
        wm.addClient(other)
        wm.focus(parent)
        wm.addAttached(job, to: parent)
        wm.dispatch(.fullscreen(.fullscreen))
        let snap = wm.snapshot()
        let p = try XCTUnwrap(snap.placement(parent)), a = try XCTUnwrap(snap.placement(job))
        XCTAssertEqual(a.z, p.z)
        XCTAssertEqual(a.frame.maxX, p.frame.maxX - 12)
    }

    func testHoverOverPreviewTargetsParent() throws {
        let wm = makeWM()
        wm.addClient(parent)
        wm.addAttached(job, to: parent)
        let a = try XCTUnwrap(wm.snapshot().placement(job))
        let center = CGPoint(x: a.frame.midX, y: a.frame.midY)
        XCTAssertEqual(wm.client(at: center), job, "clicks reach it")
        XCTAssertEqual(wm.hoverTarget(at: center), parent, "hover doesn't expand it")
        wm.focus(job)
        XCTAssertEqual(wm.hoverTarget(at: center), job)
    }

    func testAttachRequestParses() {
        let line = #"attach {"parent": 3, "command": "make test", "cwd": "/tmp", "owner": 42, "reveal_after": 1.5}"#
        guard case .success(.attach(let r)) = IPCRequest.parse(line) else { return XCTFail("didn't parse") }
        XCTAssertEqual(r, AttachRequest(parent: 3, command: "make test", cwd: "/tmp", owner: 42, revealAfter: 1.5))
        guard case .failure = IPCRequest.parse(#"attach {"parent": 3, "command": ""}"#) else { return XCTFail() }
    }
}
