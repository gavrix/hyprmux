import Foundation
import XCTest
@testable import HyprmuxCore

final class IPCTests: XCTestCase {
    func testSurfaceReferences() {
        XCTAssertEqual(try? SurfaceReference.parse("7").get(), SurfaceReference(7))
        XCTAssertEqual(try? SurfaceReference.parse("surface:42").get(), SurfaceReference(42))
        XCTAssertEqual(SurfaceReference(7).description, "surface:7")
        XCTAssertThrowsError(try SurfaceReference.parse("surface:0").get())
        XCTAssertThrowsError(try SurfaceReference.parse("client:7").get())
    }

    func testTerminalKeys() {
        XCTAssertEqual(try? TerminalKey.parse("enter").get(), TerminalKey(modifiers: [], keyCode: 0x24))
        XCTAssertEqual(try? TerminalKey.parse("ctrl+c").get(), TerminalKey(modifiers: [.ctrl], keyCode: 0x08))
        XCTAssertEqual(try? TerminalKey.parse("ctrl-c").get(), TerminalKey(modifiers: [.ctrl], keyCode: 0x08))
        XCTAssertEqual(try? TerminalKey.parse("shift+tab").get(), TerminalKey(modifiers: [.shift], keyCode: 0x30))
        XCTAssertThrowsError(try TerminalKey.parse("ctrl+not-a-key").get())
    }

    func testIPCTextUnescapesKnownSequences() {
        XCTAssertEqual(IPCText.unescape(#"one\ntwo\t\\three"#), "one\ntwo\t\\three")
        XCTAssertEqual(IPCText.unescape(#"keep\q"#), #"keep\q"#)
        XCTAssertEqual(IPCText.unescape(#"tail\"#), #"tail\"#)
    }

    func testTailLinesHandlesTerminatedAndUnterminatedText() {
        XCTAssertEqual(IPCText.tailLines("one\ntwo\nthree", count: 2), "two\nthree")
        XCTAssertEqual(IPCText.tailLines("one\ntwo\nthree\n", count: 2), "two\nthree\n")
        XCTAssertEqual(IPCText.tailLines("one\ntwo\nthree\n", count: 1), "three\n")
        XCTAssertEqual(IPCText.tailLines("one\n", count: 10), "one\n")
        XCTAssertEqual(IPCText.tailLines("", count: 2), "")
    }

    func testSurfaceDiscoveryAndIdentifyRequests() throws {
        XCTAssertEqual(try IPCRequest.parse("surfaces").get(), .surfaces)
        XCTAssertEqual(try IPCRequest.parse("identify").get(), .identify(nil))
        XCTAssertEqual(try IPCRequest.parse("identify --surface surface:9").get(), .identify(SurfaceReference(9)))
    }

    func testReadScreenRequest() throws {
        XCTAssertEqual(
            try IPCRequest.parse("read-screen --surface surface:8 --lines 25 --json").get(),
            .readScreen(surface: SurfaceReference(8), scrollback: true, lines: 25, json: true)
        )
        XCTAssertEqual(
            try IPCRequest.parse("read-screen --scrollback").get(),
            .readScreen(surface: nil, scrollback: true, lines: nil, json: false)
        )
        XCTAssertThrowsError(try IPCRequest.parse("read-screen --lines 0").get())
        XCTAssertThrowsError(try IPCRequest.parse("read-screen extra").get())
    }

    func testSendRequestUsesBase64ForArbitraryText() throws {
        let text = "echo one\necho two\\three"
        let encoded = Data(text.utf8).base64EncodedString()
        XCTAssertEqual(
            try IPCRequest.parse("send --surface 3 --base64 \(encoded)").get(),
            .sendSurfaceText(surface: SurfaceReference(3), text: text)
        )
        XCTAssertEqual(
            try IPCRequest.parse(#"send --surface=3 echo\nhello"#).get(),
            .sendSurfaceText(surface: SurfaceReference(3), text: "echo\nhello")
        )
    }

    func testSendKeyRequest() throws {
        XCTAssertEqual(
            try IPCRequest.parse("send-key --surface 4 ctrl+c").get(),
            .sendSurfaceKey(surface: SurfaceReference(4), key: TerminalKey(modifiers: [.ctrl], keyCode: 0x08))
        )
        XCTAssertThrowsError(try IPCRequest.parse("send-key --surface 4 ctrl+c enter").get())
    }
}
