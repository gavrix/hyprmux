import CoreGraphics
import XCTest
@testable import HyprmuxCore

final class PillStripTests: XCTestCase {
    /// Twenty 20-point pills, 5 apart: 495 points in all.
    let widths = [CGFloat](repeating: 20, count: 20)
    let edge = PillStrip.indicatorWidth + PillStrip.context

    func offset(_ active: Int?, from previous: CGFloat = 0, available: CGFloat = 200) -> CGFloat {
        PillStrip.offset(widths: widths, gap: 5, available: available, active: active, previous: previous)
    }

    func testEverythingFits() {
        let s = PillStrip(widths: widths, gap: 5, available: 600, offset: 80)
        XCTAssertEqual(s.offset, 0)
        XCTAssertTrue(s.fits)
        XCTAssertEqual(s.hiddenBefore, [])
        XCTAssertEqual(s.hiddenAfter, [])
        XCTAssertEqual(offset(19, available: 600), 0)
    }

    func testStaysPutWhileTheActivePillIsInView() {
        XCTAssertEqual(offset(0), 0)
        XCTAssertEqual(offset(3), 0)
        XCTAssertEqual(offset(8, from: 100), 100)
    }

    func testShiftsJustEnoughAtTheRightEdge() {
        // Pill 8 spans 200…220: its end, plus room for the count and a peek, meets the edge.
        XCTAssertEqual(offset(8), 220 + edge - 200)
        let s = PillStrip(widths: widths, gap: 5, available: 200, offset: offset(8))
        XCTAssertTrue(s.visible.contains(200) && s.visible.contains(220))
        XCTAssertTrue(s.leftIndicator && s.rightIndicator)
    }

    func testShiftsJustEnoughAtTheLeftEdge() {
        // Pill 6 spans 150…170.
        XCTAssertEqual(offset(6, from: 250), 150 - edge)
    }

    func testTheEndsHaveNoCountOnTheirSide() {
        let last = PillStrip(widths: widths, gap: 5, available: 200, offset: offset(19))
        XCTAssertEqual(last.offset, 295)
        XCTAssertTrue(last.leftIndicator)
        XCTAssertFalse(last.rightIndicator)
        XCTAssertEqual(last.hiddenAfter, [])
        XCTAssertEqual(last.hiddenBefore.count, 13)  // 0…12 fully or partly under the count

        let first = PillStrip(widths: widths, gap: 5, available: 200, offset: offset(0, from: 295))
        XCTAssertEqual(first.offset, 0)
        XCTAssertFalse(first.leftIndicator)
        XCTAssertEqual(first.hiddenBefore, [])
        XCTAssertEqual(first.hiddenAfter.first, 7)  // 175…195 runs under the count at 172
    }

    func testFewerPillsPullTheStripBack() {
        let twelve = [CGFloat](repeating: 20, count: 12)  // 295 points
        let o = PillStrip.offset(widths: twelve, gap: 5, available: 200, active: 11, previous: 295)
        XCTAssertEqual(o, 95)
    }
}
