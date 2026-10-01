import HyprmuxCore
import XCTest

final class ShellWordsTests: XCTestCase {
    func testSplitsLikeAShell() {
        XCTAssertEqual(shellWords("a b  c"), ["a", "b", "c"])
        XCTAssertEqual(shellWords("  "), [])
        XCTAssertEqual(shellWords("\"/Applications/Visual Studio Code.app\" --x"), ["/Applications/Visual Studio Code.app", "--x"])
        XCTAssertEqual(shellWords("'it''s' ok"), ["its", "ok"])
        XCTAssertEqual(shellWords("a\\ b c"), ["a b", "c"])
        XCTAssertEqual(shellWords("\"a \\\"q\\\" b\""), ["a \"q\" b"])
        XCTAssertEqual(shellWords("'no \\ escape'"), ["no \\ escape"])
        XCTAssertEqual(shellWords("\"\" x"), ["", "x"], "an empty quoted word is a word")
        XCTAssertNil(shellWords("\"open"))
        XCTAssertNil(shellWords("trailing\\"))
    }

    func testQuoteRoundTrips() {
        for words in [["/tmp/demo"], ["/Applications/Visual Studio Code.app", "--flag"], ["it's", ""], ["a\"b"]] {
            XCTAssertEqual(shellWords(words.map(shellQuote).joined(separator: " ")), words)
        }
        XCTAssertEqual(shellQuote("/tmp/demo"), "/tmp/demo")
    }
}
