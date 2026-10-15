import CoreGraphics
import XCTest
@testable import HyprmuxCore

final class PointerFocusTests: XCTestCase {
    let a = ClientID(1), b = ClientID(2), c = ClientID(3)
    let left = CGRect(x: 0, y: 0, width: 100, height: 100)
    let right = CGRect(x: 100, y: 0, width: 100, height: 100)

    func testMovingInsideATileDoesNotUndoAKeyboardFocusChange() {
        var pf = PointerFocus()
        XCTAssertEqual(pf.pointerMoved(over: a, focused: b), a, "entering a tile focuses it")
        _ = pf.layoutApplied(focus: a, frame: left, pointer: CGPoint(x: 50, y: 50), under: a, mayWarp: false)
        // The keyboard moves focus to b; the pointer stays over a.
        XCTAssertNil(pf.layoutApplied(focus: b, frame: right, pointer: CGPoint(x: 50, y: 50), under: a, mayWarp: true))
        XCTAssertNil(pf.pointerMoved(over: a, focused: b), "a bump inside a keeps focus on b")
        XCTAssertNil(pf.pointerMoved(over: nil, focused: b), "a gap focuses nothing")
        XCTAssertEqual(pf.pointerMoved(over: a, focused: b), a, "crossing back into a focuses it")
    }

    func testCrossingIntoAnotherTileFocusesIt() {
        var pf = PointerFocus()
        _ = pf.layoutApplied(focus: b, frame: right, pointer: CGPoint(x: 50, y: 50), under: a, mayWarp: true)
        XCTAssertEqual(pf.pointerMoved(over: c, focused: b), c)
    }

    func testATileMovingUnderTheRestingPointerIsNotACrossing() {
        var pf = PointerFocus()
        _ = pf.pointerMoved(over: a, focused: a)
        // A swap puts b under the pointer without the pointer moving.
        _ = pf.layoutApplied(focus: a, frame: right, pointer: CGPoint(x: 50, y: 50), under: b, mayWarp: true)
        XCTAssertNil(pf.pointerMoved(over: b, focused: a))
    }

    func testMouseRefocusRefocusesOnAnyMove() {
        var pf = PointerFocus(mouseRefocus: true)
        _ = pf.pointerMoved(over: a, focused: a)
        _ = pf.layoutApplied(focus: b, frame: right, pointer: CGPoint(x: 50, y: 50), under: a, mayWarp: true)
        XCTAssertEqual(pf.pointerMoved(over: a, focused: b), a)
    }

    func testNoWarpUnlessEnabled() {
        var pf = PointerFocus()
        _ = pf.layoutApplied(focus: a, frame: left, pointer: CGPoint(x: 50, y: 50), under: a, mayWarp: true)
        XCTAssertNil(pf.layoutApplied(focus: b, frame: right, pointer: CGPoint(x: 50, y: 50), under: a, mayWarp: true))
    }

    func testWarpsToTheMiddleOfANewlyFocusedTile() {
        var pf = PointerFocus(warps: true)
        _ = pf.layoutApplied(focus: a, frame: left, pointer: CGPoint(x: 50, y: 50), under: a, mayWarp: true)
        XCTAssertEqual(pf.layoutApplied(focus: b, frame: right, pointer: CGPoint(x: 50, y: 50), under: a, mayWarp: true),
                       CGPoint(x: 150, y: 50))
        XCTAssertEqual(pf.hovered, b, "the pointer is over b now")
        XCTAssertNil(pf.pointerMoved(over: b, focused: b))
    }

    func testWarpSkips() {
        var pf = PointerFocus(warps: true)
        _ = pf.layoutApplied(focus: a, frame: left, pointer: CGPoint(x: 50, y: 50), under: a, mayWarp: true)
        XCTAssertNil(pf.layoutApplied(focus: a, frame: left, pointer: CGPoint(x: 150, y: 50), under: b, mayWarp: true),
                     "focus didn't change: a layout change alone doesn't warp")
        XCTAssertNil(pf.layoutApplied(focus: b, frame: right, pointer: CGPoint(x: 150, y: 50), under: b, mayWarp: true),
                     "the pointer is already inside the new tile")
        XCTAssertNil(pf.layoutApplied(focus: a, frame: left, pointer: CGPoint(x: 150, y: 50), under: b, mayWarp: false),
                     "the pointer caused it, or Hyprmux isn't active")
        XCTAssertNil(pf.layoutApplied(focus: a, frame: left, pointer: CGPoint(x: 150, y: 50), under: b, mayWarp: true),
                     "a change seen without a warp doesn't warp later")
        XCTAssertNil(pf.layoutApplied(focus: nil, frame: nil, pointer: CGPoint(x: 150, y: 50), under: b, mayWarp: true),
                     "nothing focused")
    }

    func testConfig() {
        let d = ConfigParser.parse(defaultConfig)
        XCTAssertFalse(d.mouseRefocus)
        XCTAssertTrue(d.noWarps)
        XCTAssertFalse(HyprmuxConfig().mouseRefocus)
        XCTAssertTrue(HyprmuxConfig().noWarps)
        let c = ConfigParser.parse("input {\n    mouse_refocus = true\n}\ncursor {\n    no_warps = false\n}")
        XCTAssertEqual(c.errors, [])
        XCTAssertTrue(c.mouseRefocus)
        XCTAssertFalse(c.noWarps)
        XCTAssertEqual(ConfigParser.parse("cursor:no_warps = maybe").errors.count, 1)
    }
}
