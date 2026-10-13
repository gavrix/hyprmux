import Foundation
import XCTest
@testable import HyprmuxCore

final class AgentBrowserRouterTests: XCTestCase {
    private var router: AgentBrowserRouter!
    private var sessionCount = 0

    override func setUp() {
        sessionCount = 0
        router = AgentBrowserRouter(makeSessionID: { [unowned self] in
            sessionCount += 1
            return "S\(sessionCount)"
        })
    }

    private func target(_ tile: UInt64, url: String = "https://example.com/") -> AgentBrowserTarget {
        AgentBrowserTarget(tile: tile, targetID: "T\(tile)", url: url, title: "Tile \(tile)")
    }

    /// Messages the actions send to a connection.
    private func sent(_ actions: [AgentBrowserAction], to connection: Int) -> [CDPMessage] {
        actions.compactMap {
            if case .client(let c, let m) = $0, c == connection { return m }
            return nil
        }
    }

    private func toTile(_ actions: [AgentBrowserAction]) -> [(UInt64, CDPMessage, Bool)] {
        actions.compactMap {
            if case .tile(let t, let m, let w) = $0 { return (t, m, w) }
            return nil
        }
    }

    private func result(_ m: CDPMessage) -> [String: Any]? { m["result"] as? [String: Any] }

    private func attach(_ connection: Int, _ tile: UInt64, id: Int = 1) -> String {
        let actions = router.receive(connection, ["id": id, "method": "Target.attachToTarget",
                                                  "params": ["targetId": "T\(tile)", "flatten": true]])
        return result(sent(actions, to: connection).last!)!["sessionId"] as! String
    }

    func testListsTilesAsPageTargetsWithTheFocusedOneFirst() {
        router.connect(1, scope: .all)
        _ = router.tileOpened(target(3))
        _ = router.tileOpened(target(5))
        router.preferredTile = 5
        let reply = sent(router.receive(1, ["id": 7, "method": "Target.getTargets"]), to: 1)
        XCTAssertEqual(reply.count, 1)
        XCTAssertEqual(reply[0]["id"] as? Int, 7)
        let infos = result(reply[0])?["targetInfos"] as? [[String: Any]]
        XCTAssertEqual(infos?.map { $0["targetId"] as? String }, ["T5", "T3"])
        XCTAssertEqual(infos?.first?["type"] as? String, "page")
        XCTAssertEqual(infos?.first?["url"] as? String, "https://example.com/")
    }

    func testAttachAnnouncesTheSessionAndRoutesItsMessagesToTheTile() {
        router.connect(1, scope: .all)
        _ = router.tileOpened(target(3))
        let actions = router.receive(1, ["id": 1, "method": "Target.attachToTarget",
                                         "params": ["targetId": "T3", "flatten": true]])
        XCTAssertTrue(actions.contains { if case .attach(3) = $0 { return true } else { return false } })
        let messages = sent(actions, to: 1)
        XCTAssertEqual(messages.first?["method"] as? String, "Target.attachedToTarget")
        XCTAssertEqual(result(messages.last!)?["sessionId"] as? String, "S1")
        XCTAssertTrue(router.isAttached(3))

        let forward = toTile(router.receive(1, ["id": 2, "sessionId": "S1", "method": "Runtime.evaluate",
                                                "params": ["expression": "1"]]))
        XCTAssertEqual(forward.count, 1)
        XCTAssertEqual(forward[0].0, 3)
        XCTAssertNil(forward[0].1["sessionId"], "the tile's own session has no session id")
        let upstream = forward[0].1["id"] as! Int
        XCTAssertGreaterThanOrEqual(upstream, AgentBrowserRouter.firstUpstreamID)

        let reply = sent(router.tileMessage(3, ["id": upstream, "result": ["result": ["value": 1]]]), to: 1)
        XCTAssertEqual(reply.first?["id"] as? Int, 2)
        XCTAssertEqual(reply.first?["sessionId"] as? String, "S1")
    }

    func testRepliesForOtherDevToolsUsersAreIgnored() {
        router.connect(1, scope: .all)
        _ = router.tileOpened(target(3))
        _ = attach(1, 3)
        XCTAssertTrue(router.tileMessage(3, ["id": 4, "result": [:]]).isEmpty)
    }

    func testEventsReachEverySessionOnTheTile() {
        router.connect(1, scope: .all)
        router.connect(2, scope: .all)
        _ = router.tileOpened(target(3))
        let a = attach(1, 3)
        let b = attach(2, 3)
        let actions = router.tileMessage(3, ["method": "Page.loadEventFired", "params": ["timestamp": 1]])
        XCTAssertEqual(sent(actions, to: 1).first?["sessionId"] as? String, a)
        XCTAssertEqual(sent(actions, to: 2).first?["sessionId"] as? String, b)
    }

    func testChildSessionsKeepChromiumsIds() {
        router.connect(1, scope: .all)
        _ = router.tileOpened(target(3))
        let session = attach(1, 3)
        let attached = router.tileMessage(3, ["method": "Target.attachedToTarget",
                                              "params": ["sessionId": "CHILD", "targetInfo": ["type": "iframe"]]])
        XCTAssertEqual(sent(attached, to: 1).first?["sessionId"] as? String, session)

        let forward = toTile(router.receive(1, ["id": 9, "sessionId": "CHILD", "method": "Runtime.enable"]))
        XCTAssertEqual(forward.first?.1["sessionId"] as? String, "CHILD")
        let upstream = forward.first!.1["id"] as! Int
        let reply = sent(router.tileMessage(3, ["id": upstream, "sessionId": "CHILD", "result": [:]]), to: 1)
        XCTAssertEqual(reply.first?["id"] as? Int, 9)
        XCTAssertEqual(reply.first?["sessionId"] as? String, "CHILD")

        let event = sent(router.tileMessage(3, ["method": "Runtime.executionContextCreated", "sessionId": "CHILD",
                                                "params": [:]]), to: 1)
        XCTAssertEqual(event.first?["sessionId"] as? String, "CHILD")
    }

    func testAnotherConnectionCantUseASession() {
        router.connect(1, scope: .all)
        router.connect(2, scope: .all)
        _ = router.tileOpened(target(3))
        let session = attach(1, 3)
        let actions = router.receive(2, ["id": 5, "sessionId": session, "method": "Runtime.evaluate"])
        XCTAssertTrue(toTile(actions).isEmpty)
        XCTAssertNotNil(sent(actions, to: 2).first?["error"])
    }

    func testPressesWaitForTheCursor() {
        router.connect(1, scope: .all)
        _ = router.tileOpened(target(3))
        let session = attach(1, 3)
        let press = router.receive(1, ["id": 2, "sessionId": session, "method": "Input.dispatchMouseEvent",
                                       "params": ["type": "mousePressed", "x": 10, "y": 20.5, "button": "left"]])
        guard case .cursor(3, .press(10, 20.5))? = press.first else { return XCTFail("expected a press first") }
        XCTAssertEqual(toTile(press).first?.2, true)

        let move = router.receive(1, ["id": 3, "sessionId": session, "method": "Input.dispatchMouseEvent",
                                      "params": ["type": "mouseMoved", "x": 1, "y": 2]])
        guard case .cursor(3, .move(1, 2))? = move.first else { return XCTFail("expected a move") }
        XCTAssertEqual(toTile(move).first?.2, false)

        let typing = toTile(router.receive(1, ["id": 4, "sessionId": session, "method": "Input.insertText",
                                               "params": ["text": "hi"]]))
        XCTAssertEqual(typing.map { $0.1["method"] as? String }, ["Runtime.evaluate", "Input.insertText"])
        XCTAssertEqual(typing.map(\.2), [false, false], "typing doesn't wait for the cursor")
    }

    /// Sends typing and returns the focus lookup the router asks the tile for first.
    private func type(_ session: String, id: Int) -> (lookup: CDPMessage?, actions: [AgentBrowserAction]) {
        let actions = router.receive(1, ["id": id, "sessionId": session, "method": "Input.insertText",
                                         "params": ["text": "a"]])
        let lookup = toTile(actions).first { $0.1["method"] as? String == "Runtime.evaluate" }?.1
        return (lookup, actions)
    }

    private func cursorEffects(_ actions: [AgentBrowserAction]) -> [AgentCursorEffect] {
        actions.compactMap { if case .cursor(_, let e) = $0 { return e } else { return nil } }
    }

    func testTypingMovesTheCursorToTheFocusedElement() {
        router.connect(1, scope: .all)
        _ = router.tileOpened(target(3))
        let session = attach(1, 3)
        let (lookup, actions) = type(session, id: 2)
        XCTAssertNotNil(lookup, "the router asks where the focused element is")
        XCTAssertTrue(cursorEffects(actions).isEmpty, "the cursor waits for the answer")
        XCTAssertEqual((lookup?["params"] as? [String: Any])?["returnByValue"] as? Bool, true)

        // A second keystroke while the lookup is out only pulses.
        let (second, more) = type(session, id: 3)
        XCTAssertNil(second)
        XCTAssertEqual(cursorEffects(more), [.typing])

        // The reply is the router's own: the agent never sees it.
        let found = router.tileMessage(3, ["id": lookup!["id"]!, "result": ["result": ["type": "object",
                                                                                     "value": ["x": 40, "y": 60.5]]]])
        XCTAssertTrue(sent(found, to: 1).isEmpty)
        XCTAssertEqual(cursorEffects(found), [.move(x: 40, y: 60.5), .typing])

        // The next lookup tells the page where the cursor is, so it can stay on the element.
        let (next, _) = type(session, id: 4)
        XCTAssertTrue(((next?["params"] as? [String: Any])?["expression"] as? String)?.contains("[40.0, 60.5]") == true)
        let stay = router.tileMessage(3, ["id": next!["id"]!, "result": ["result": ["type": "object", "subtype": "null",
                                                                                  "value": NSNull()]]])
        XCTAssertEqual(cursorEffects(stay), [.typing])
    }

    func testAFocusReplyAfterAClickLeavesTheCursorAtTheClick() {
        router.connect(1, scope: .all)
        _ = router.tileOpened(target(3))
        let session = attach(1, 3)
        let (lookup, _) = type(session, id: 2)
        _ = router.receive(1, ["id": 3, "sessionId": session, "method": "Input.dispatchMouseEvent",
                               "params": ["type": "mousePressed", "x": 5, "y": 5, "button": "left"]])
        let late = router.tileMessage(3, ["id": lookup!["id"]!, "result": ["result": ["value": ["x": 40, "y": 60]]]])
        XCTAssertTrue(late.isEmpty)
    }

    func testAFailedFocusLookupStillPulses() {
        router.connect(1, scope: .all)
        _ = router.tileOpened(target(3))
        let session = attach(1, 3)
        let (lookup, _) = type(session, id: 2)
        let failed = router.tileMessage(3, ["id": lookup!["id"]!, "error": ["code": -32000, "message": "nope"]])
        XCTAssertEqual(cursorEffects(failed), [.typing])
        XCTAssertTrue(sent(failed, to: 1).isEmpty)
    }

    func testFocusLookupsEndWithTheAgent() {
        router.connect(1, scope: .all)
        _ = router.tileOpened(target(3))
        let session = attach(1, 3)
        let (lookup, _) = type(session, id: 2)
        _ = router.disconnect(1)
        XCTAssertTrue(router.tileMessage(3, ["id": lookup!["id"]!, "result": ["result": ["value": ["x": 1, "y": 1]]]])
            .isEmpty)

        // A new agent starts with a fresh lookup.
        router.connect(2, scope: .all)
        let again = router.receive(2, ["id": 1, "method": "Target.attachToTarget",
                                       "params": ["targetId": "T3", "flatten": true]])
        let sid = result(sent(again, to: 2).last!)!["sessionId"] as! String
        let typed = toTile(router.receive(2, ["id": 2, "sessionId": sid, "method": "Input.insertText",
                                              "params": ["text": "a"]]))
        XCTAssertEqual(typed.first?.1["method"] as? String, "Runtime.evaluate")
    }

    func testBringToFrontLeavesFocusAlone() {
        router.connect(1, scope: .all)
        _ = router.tileOpened(target(3))
        let session = attach(1, 3)
        let actions = router.receive(1, ["id": 2, "sessionId": session, "method": "Page.bringToFront"])
        XCTAssertTrue(toTile(actions).isEmpty)
        XCTAssertNotNil(result(sent(actions, to: 1).first!))
    }

    func testStopDetachesAndKeepsAutoAttachAway() {
        router.connect(1, scope: .all)
        _ = router.tileOpened(target(3))
        let auto = router.receive(1, ["id": 1, "method": "Target.setAutoAttach",
                                      "params": ["autoAttach": true, "waitForDebuggerOnStart": true, "flatten": true]])
        XCTAssertEqual(sent(auto, to: 1).first?["method"] as? String, "Target.attachedToTarget")
        let session = (sent(auto, to: 1).first?["params"] as? [String: Any])?["sessionId"] as? String
        let pendingCall = toTile(router.receive(1, ["id": 2, "sessionId": session!, "method": "Page.navigate"]))
        XCTAssertEqual(pendingCall.count, 1)

        let stop = router.stop(3)
        let messages = sent(stop, to: 1)
        XCTAssertTrue(messages.contains { $0["method"] as? String == "Target.detachedFromTarget" })
        XCTAssertTrue(messages.contains { $0["id"] as? Int == 2 && $0["error"] != nil }, "the pending call fails")
        XCTAssertTrue(stop.contains { if case .release(3) = $0 { return true } else { return false } })
        XCTAssertFalse(router.isAttached(3))

        let after = sent(router.receive(1, ["id": 3, "sessionId": session!, "method": "Runtime.evaluate"]), to: 1)
        XCTAssertTrue(((after.first?["error"] as? [String: Any])?["message"] as? String)?.contains("Stop") == true)

        // A new tile still auto-attaches; the stopped one doesn't come back.
        let opened = router.tileOpened(target(4))
        XCTAssertTrue(opened.contains { if case .attach(4) = $0 { return true } else { return false } })
        XCTAssertFalse(router.isAttached(3))
    }

    func testScopedConnectionsSeeOnlyTheirTiles() {
        router.connect(1, scope: .tiles([3]))
        _ = router.tileOpened(target(3))
        _ = router.tileOpened(target(4))
        let infos = result(sent(router.receive(1, ["id": 1, "method": "Target.getTargets"]), to: 1)[0])?["targetInfos"]
            as? [[String: Any]]
        XCTAssertEqual(infos?.count, 1)
        let denied = sent(router.receive(1, ["id": 2, "method": "Target.attachToTarget",
                                             "params": ["targetId": "T4", "flatten": true]]), to: 1)
        XCTAssertNotNil(denied.first?["error"])

        // A tile the connection opens joins its scope.
        let create = router.receive(1, ["id": 3, "method": "Target.createTarget", "params": ["url": "about:blank"]])
        guard case .openTile("about:blank", let request)? = create.first else { return XCTFail("expected openTile") }
        let created = sent(router.tileCreated(request: request, target: target(9, url: "about:blank")), to: 1)
        XCTAssertEqual(result(created.last!)?["targetId"] as? String, "T9")
        let after = result(sent(router.receive(1, ["id": 4, "method": "Target.getTargets"]), to: 1)[0])?["targetInfos"]
            as? [[String: Any]]
        XCTAssertEqual(after?.count, 2)
    }

    func testDiscoveryReportsTileChanges() {
        router.connect(1, scope: .all)
        _ = router.tileOpened(target(3))
        let discover = sent(router.receive(1, ["id": 1, "method": "Target.setDiscoverTargets",
                                               "params": ["discover": true]]), to: 1)
        XCTAssertEqual(discover.first?["method"] as? String, "Target.targetCreated")
        XCTAssertEqual(sent(router.tileOpened(target(4)), to: 1).first?["method"] as? String, "Target.targetCreated")
        XCTAssertEqual(sent(router.tileUpdated(target(4, url: "https://other.example/")), to: 1).first?["method"] as? String,
                       "Target.targetInfoChanged")
        XCTAssertEqual(sent(router.tileClosed(4), to: 1).first?["method"] as? String, "Target.targetDestroyed")
    }

    func testClosingATileEndsItsSessions() {
        router.connect(1, scope: .all)
        _ = router.tileOpened(target(3))
        _ = attach(1, 3)
        let closed = sent(router.tileClosed(3), to: 1)
        XCTAssertEqual(closed.first?["method"] as? String, "Target.detachedFromTarget")
        XCTAssertTrue(router.attachedTiles.isEmpty)
    }

    func testDisconnectReleasesTiles() {
        router.connect(1, scope: .all)
        _ = router.tileOpened(target(3))
        _ = attach(1, 3)
        let actions = router.disconnect(1)
        XCTAssertTrue(actions.contains { if case .release(3) = $0 { return true } else { return false } })
        XCTAssertFalse(router.isAttached(3))
    }

    func testTheLastAgentLeavingResetsTheTilesSession() {
        router.connect(1, scope: .all)
        _ = router.tileOpened(target(3))
        let session = attach(1, 3)
        let add = toTile(router.receive(1, ["id": 2, "sessionId": session, "method": "Page.addScriptToEvaluateOnNewDocument",
                                            "params": ["source": "1"]]))
        _ = router.tileMessage(3, ["id": add[0].1["id"]!, "result": ["identifier": "7"]])
        _ = router.receive(1, ["id": 3, "sessionId": session, "method": "Runtime.addBinding", "params": ["name": "pw"]])

        let actions = router.disconnect(1)
        let methods = toTile(actions).map { $0.1["method"] as? String }
        XCTAssertEqual(methods.first, "Page.removeScriptToEvaluateOnNewDocument")
        XCTAssertTrue(methods.contains("Runtime.removeBinding"))
        XCTAssertTrue(methods.contains("Fetch.disable"))
        XCTAssertTrue(methods.contains("Runtime.disable"))
        guard case .release(3)? = actions.last else { return XCTFail("the tile is released after its reset") }
        // The reset's replies belong to nobody.
        let resetID = toTile(actions)[0].1["id"] as! Int
        XCTAssertTrue(router.tileMessage(3, ["id": resetID, "result": [:]]).isEmpty)
    }

    func testUnknownAndMalformedRequestsGetErrors() {
        router.connect(1, scope: .all)
        let unknown = sent(router.receive(1, ["id": 1, "method": "Nope.nothing"]), to: 1)
        XCTAssertEqual((unknown.first?["error"] as? [String: Any])?["code"] as? Int, -32601)
        let malformed = sent(router.receive(1, ["id": 2]), to: 1)
        XCTAssertNotNil(malformed.first?["error"])
        let unflattened = sent(router.receive(1, ["id": 3, "method": "Target.attachToTarget",
                                                  "params": ["targetId": "T1"]]), to: 1)
        XCTAssertNotNil(unflattened.first?["error"])
        XCTAssertNotNil(result(sent(router.receive(1, ["id": 4, "method": "Browser.getVersion"]), to: 1)[0])?["product"])
    }
}

final class WebSocketTests: XCTestCase {
    private func request(_ extra: String = "", host: String = "127.0.0.1:9333") -> Data {
        Data(("GET /devtools/browser/abc HTTP/1.1\r\nHost: \(host)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
              + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\(extra)\r\n").utf8)
    }

    func testHandshake() throws {
        XCTAssertNil(try WebSocketHandshake.parse(Data("GET / HTTP/1.1\r\n".utf8)).get())
        let (req, consumed) = try XCTUnwrap(try WebSocketHandshake.parse(request() + Data([1, 2])).get())
        XCTAssertEqual(req.path, "/devtools/browser/abc")
        XCTAssertEqual(consumed, request().count)
        // RFC 6455's example.
        XCTAssertEqual(WebSocketHandshake.acceptValue(for: "dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
        XCTAssertNil(WebSocketHandshake.refusal(req, port: 9333))
    }

    func testRefusesWebPagesAndOtherHosts() throws {
        let (fromPage, _) = try XCTUnwrap(try WebSocketHandshake.parse(request("Origin: https://evil.example\r\n")).get())
        XCTAssertNotNil(WebSocketHandshake.refusal(fromPage, port: 9333))
        let (rebound, _) = try XCTUnwrap(try WebSocketHandshake.parse(request(host: "evil.example:9333")).get())
        XCTAssertNotNil(WebSocketHandshake.refusal(rebound, port: 9333))
        XCTAssertThrowsError(try WebSocketHandshake.parse(Data("POST / HTTP/1.1\r\n\r\n".utf8)).get())
    }

    private func masked(_ opcode: UInt8, _ payload: Data, fin: Bool = true) -> Data {
        let mask: [UInt8] = [1, 2, 3, 4]
        var head: [UInt8] = [(fin ? 0x80 : 0) | opcode]
        if payload.count < 126 {
            head.append(0x80 | UInt8(payload.count))
        } else {
            head += [0x80 | 126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        }
        let body = payload.enumerated().map { $0.element ^ mask[$0.offset & 3] }
        return Data(head + mask + body)
    }

    func testDecodesSplitAndFragmentedMessages() throws {
        var decoder = WebSocketDecoder()
        let big = Data(repeating: 0x61, count: 300)
        let frame = masked(0x1, big)
        XCTAssertEqual(try decoder.push(frame.prefix(5)).get(), [])
        XCTAssertEqual(try decoder.push(frame.dropFirst(5)).get(), [.text(big)])

        let parts = masked(0x1, Data("he".utf8), fin: false) + masked(0x9, Data("p".utf8)) + masked(0x0, Data("llo".utf8))
        XCTAssertEqual(try decoder.push(parts).get(), [.ping(Data("p".utf8)), .text(Data("hello".utf8))])
        XCTAssertEqual(try decoder.push(masked(0x8, Data([0x03, 0xE8]))).get(), [.close(1000)])
    }

    func testRejectsUnmaskedClientFrames() {
        var decoder = WebSocketDecoder()
        XCTAssertThrowsError(try decoder.push(WebSocketEncoder.text(Data("x".utf8))).get())
    }

    func testEncodesLengths() {
        XCTAssertEqual(WebSocketEncoder.text(Data("hi".utf8)), Data([0x81, 2, 0x68, 0x69]))
        XCTAssertEqual(WebSocketEncoder.text(Data(count: 300)).prefix(4), Data([0x81, 126, 0x01, 0x2C]))
        XCTAssertEqual(WebSocketEncoder.text(Data(count: 70000)).prefix(10), Data([0x81, 127, 0, 0, 0, 0, 0, 1, 0x11, 0x70]))
    }
}

extension IPCTests {
    func testCDPURLRequests() {
        XCTAssertEqual(try? IPCRequest.parse("cdp-url").get(), .cdpURL(surface: nil))
        XCTAssertEqual(try? IPCRequest.parse("cdp-url --surface surface:4").get(), .cdpURL(surface: SurfaceReference(4)))
        XCTAssertThrowsError(try IPCRequest.parse("cdp-url extra").get())
    }
}
