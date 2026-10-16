import XCTest
@testable import HyprmuxCore

final class PlainTextFilterTests: XCTestCase {
    func plain(_ chunks: [String]) -> String {
        var f = PlainTextFilter()
        var out: [UInt8] = []
        for c in chunks { out += f.feed(Array(c.utf8)) }
        out += f.finish()
        return String(decoding: out, as: UTF8.self)
    }

    func testDropsColorsAndTitlesAndKeepsText() {
        XCTAssertEqual(plain(["\u{1B}[31mred\u{1B}[0m ok\r\n", "\u{1B}]0;title\u{07}next\r\n"]), "red ok\nnext\n")
    }

    func testCarriageReturnRedrawKeepsLastState() {
        XCTAssertEqual(plain(["10%\r50%\r", "100%\r\ndone"]), "100%\ndone")
    }

    func testCRLFSplitAcrossChunks() {
        XCTAssertEqual(plain(["a\r", "\nb\r\n"]), "a\nb\n")
    }

    func testBackspaceAndEraseSequences() {
        XCTAssertEqual(plain(["^D\u{08}\u{08}hi\u{1B}[K\r\n"]), "hi\n")
    }

    func testUTF8Survives() {
        XCTAssertEqual(plain(["✓ passed — 3 tests\n"]), "✓ passed — 3 tests\n")
    }
}
