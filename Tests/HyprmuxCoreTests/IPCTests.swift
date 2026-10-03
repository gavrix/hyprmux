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

    func testReadSelectionRequest() throws {
        XCTAssertEqual(
            try IPCRequest.parse("read-selection --surface surface:8 --json").get(),
            .readSelection(surface: SurfaceReference(8), json: true)
        )
        XCTAssertEqual(try IPCRequest.parse("read-selection").get(), .readSelection(surface: nil, json: false))
        XCTAssertThrowsError(try IPCRequest.parse("read-selection extra").get())
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

    func testDispatchTakesALeadingSurface() throws {
        XCTAssertEqual(try IPCRequest.parse("dispatch movewindow l").get(), .dispatch(.moveWindow(.left), surface: nil))
        XCTAssertEqual(
            try IPCRequest.parse("dispatch --surface surface:5 movetoworkspacesilent 3").get(),
            .dispatch(.moveToWorkspace(.id(3), silent: true), surface: SurfaceReference(5))
        )
        XCTAssertEqual(
            try IPCRequest.parse("dispatch --surface=5 killactive").get(),
            .dispatch(.killActive, surface: SurfaceReference(5))
        )
        // An exec command line keeps its own options and spacing.
        XCTAssertEqual(
            try IPCRequest.parse("dispatch exec ls --surface  -la").get(),
            .dispatch(.exec("ls --surface  -la"), surface: nil)
        )
        XCTAssertThrowsError(try IPCRequest.parse("dispatch --surface 5 workspace 2").get(), "not a window dispatcher")
        XCTAssertThrowsError(try IPCRequest.parse("dispatch --surface 5").get())
        XCTAssertThrowsError(try IPCRequest.parse("dispatch --surface nope killactive").get())
    }

    func testNewSurfaceRequest() throws {
        XCTAssertEqual(try IPCRequest.parse("new-surface").get(), .newSurface(NewSurfaceRequest()))
        let command = Data("devx pi --session x".utf8).base64EncodedString()
        let cwd = Data("/tmp/a b".utf8).base64EncodedString()
        let input = Data("echo hi\n".utf8).base64EncodedString()
        let workspace = Data("name:My work".utf8).base64EncodedString()
        XCTAssertEqual(
            try IPCRequest.parse(
                "new-surface --workspace-base64 \(workspace) --focus --floating --cwd-base64 \(cwd) --input-base64 \(input) --base64 \(command)"
            ).get(),
            .newSurface(NewSurfaceRequest(kind: .terminal, workspace: .named("My work"), focus: true, floating: true,
                                          argument: "devx pi --session x", cwd: "/tmp/a b", input: "echo hi\n"))
        )
        XCTAssertEqual(
            try IPCRequest.parse("new-surface --type web --workspace special:notes github.com").get(),
            .newSurface(NewSurfaceRequest(kind: .web, workspace: .special("notes"), argument: "github.com"))
        )
        XCTAssertEqual(
            try IPCRequest.parse("new-surface -- htop --focus").get(),
            .newSurface(NewSurfaceRequest(argument: "htop --focus"))
        )
        XCTAssertEqual(
            try IPCRequest.parse("new-surface --type app --workspace 3 -- /tmp/demo --flag x").get(),
            .newSurface(NewSurfaceRequest(kind: .app, workspace: .id(3), argument: "/tmp/demo --flag x"))
        )
        XCTAssertThrowsError(try IPCRequest.parse("new-surface --type app --cwd /tmp /tmp/demo").get(), "--cwd is for terminals")
        XCTAssertThrowsError(try IPCRequest.parse("new-surface --type tv").get())
        XCTAssertThrowsError(try IPCRequest.parse("new-surface --workspace nowhere").get())
        XCTAssertThrowsError(try IPCRequest.parse("new-surface --type web --cwd /tmp").get())
        XCTAssertThrowsError(try IPCRequest.parse("new-surface --focus --no-focus").get())
        XCTAssertThrowsError(try IPCRequest.parse("new-surface --bogus").get())
        XCTAssertThrowsError(try IPCRequest.parse("new-surface --workspace 2 --workspace-base64 Mg==").get())
    }

    func testSurfaceLifecycleRequests() throws {
        XCTAssertEqual(try IPCRequest.parse("close-surface").get(), .closeSurface(nil))
        XCTAssertEqual(try IPCRequest.parse("close-surface --surface 4").get(), .closeSurface(SurfaceReference(4)))
        XCTAssertEqual(try IPCRequest.parse("focus-surface --surface surface:4").get(), .focusSurface(SurfaceReference(4)))
        XCTAssertThrowsError(try IPCRequest.parse("close-surface 4").get())
        XCTAssertEqual(
            try IPCRequest.parse("move-surface --surface 4 --workspace e+1").get(),
            .moveSurface(surface: SurfaceReference(4), workspace: .relativeExisting(1), focus: false)
        )
        XCTAssertEqual(
            try IPCRequest.parse("move-surface --workspace-base64 \(Data("2".utf8).base64EncodedString()) --focus").get(),
            .moveSurface(surface: nil, workspace: .id(2), focus: true)
        )
        XCTAssertThrowsError(try IPCRequest.parse("move-surface --surface 4").get(), "needs a workspace")
    }

    func testSendKeyRequest() throws {
        XCTAssertEqual(
            try IPCRequest.parse("send-key --surface 4 ctrl+c").get(),
            .sendSurfaceKey(surface: SurfaceReference(4), key: TerminalKey(modifiers: [.ctrl], keyCode: 0x08))
        )
        XCTAssertThrowsError(try IPCRequest.parse("send-key --surface 4 ctrl+c enter").get())
    }

    func testBrokerRequest() throws {
        XCTAssertEqual(try IPCRequest.parse("broker").get(), .broker(.status))
        XCTAssertEqual(try IPCRequest.parse("broker status").get(), .broker(.status))
        XCTAssertEqual(try IPCRequest.parse("broker register").get(), .broker(.register))
        XCTAssertEqual(try IPCRequest.parse("broker unregister").get(), .broker(.unregister))
        XCTAssertThrowsError(try IPCRequest.parse("broker load").get())
        XCTAssertThrowsError(try IPCRequest.parse("broker status now").get())
    }

    func testSendMenuRequest() throws {
        XCTAssertEqual(try IPCRequest.parse("sendmenu Open App…").get(), .sendMenu("Open App…"))
        XCTAssertEqual(try IPCRequest.parse("sendmenu  Reload Config ").get(), .sendMenu("Reload Config"))
        XCTAssertThrowsError(try IPCRequest.parse("sendmenu").get())
    }
}
