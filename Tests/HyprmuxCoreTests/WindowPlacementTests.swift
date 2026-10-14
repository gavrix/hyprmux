import CoreGraphics
import XCTest
@testable import HyprmuxCore

final class WindowPlacementTests: XCTestCase {
    // The two displays from the bug report: a built-in screen and a larger external one
    // to its right, in AppKit coordinates (bottom-left origin).
    let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 949)
    let external = CGRect(x: 1512, y: -458, width: 2560, height: 1410)

    func testInsideItsAreaStaysPut() {
        let f = CGRect(x: 100, y: 50, width: 800, height: 600)
        XCTAssertEqual(WindowPlacement.fit(f, into: builtIn), f)
    }

    func testTooLargeShrinksToTheArea() {
        let f = CGRect(x: -948, y: 0, width: 2560, height: 949)
        XCTAssertEqual(WindowPlacement.fit(f, into: builtIn), builtIn)
    }

    func testOverhangingMovesInside() {
        let f = CGRect(x: 1200, y: 600, width: 800, height: 600)
        XCTAssertEqual(WindowPlacement.fit(f, into: builtIn), CGRect(x: 712, y: 349, width: 800, height: 600))
    }

    func testKeepsItsOffsetOnAnotherDisplay() {
        let f = CGRect(x: 100, y: 50, width: 800, height: 600)
        XCTAssertEqual(WindowPlacement.fit(f, from: builtIn, into: external),
                       CGRect(x: 1612, y: -408, width: 800, height: 600))
    }

    // Full display frames, as AppKit reports them after the moves in the bug report.
    let builtInFull = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let externalFull = CGRect(x: 1512, y: -458, width: 2560, height: 1440)
    var displays: [CGRect] { [builtInFull, externalFull] }

    func testMoveToTheSmallerDisplayPicksIt() {
        // Window > Move to: the external-sized window's corner at the built-in's corner.
        let moved = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        XCTAssertEqual(WindowPlacement.display(for: moved, among: displays), 0)
    }

    func testMoveToTheLargerDisplayPicksIt() {
        let moved = CGRect(x: 1512, y: -458, width: 1512, height: 982)
        XCTAssertEqual(WindowPlacement.display(for: moved, among: displays), 1)
    }

    func testADragPicksTheDisplayItMostlyCovers() {
        let dropped = CGRect(x: -1048, y: -490, width: 2560, height: 1440)
        XCTAssertEqual(WindowPlacement.display(for: dropped, among: displays), 0)
        XCTAssertEqual(WindowPlacement.display(for: externalFull, among: displays), 1)
    }

    func testOffEveryDisplayIsNil() {
        XCTAssertNil(WindowPlacement.display(for: CGRect(x: -5000, y: 0, width: 100, height: 100), among: displays))
    }

    func testAFullDisplayWindowFillsTheSmallerOne() {
        XCTAssertEqual(WindowPlacement.fit(external, from: external, into: builtIn), builtIn)
        XCTAssertEqual(WindowPlacement.fit(external, from: builtIn, into: builtIn), builtIn)
    }
}
