import CoreGraphics
import XCTest
@testable import HypermuxCore

final class SessionTests: XCTestCase {
    func makeWM() -> WindowManager {
        var s = WMSettings()
        s.gapsIn = .zero
        s.gapsOut = .zero
        s.dwindle.forceSplit = 2
        s.autoGroup = false
        return WindowManager(monitor: CGRect(x: 0, y: 0, width: 1600, height: 1000), settings: s)
    }

    /// A busy session: splits with a changed ratio, a group, a float, a scratchpad, names, focus.
    func sampleWM() -> WindowManager {
        let wm = makeWM()
        for i in 1...3 { wm.addClient(ClientID(UInt64(i))) }       // ws 1: 1 | (2 / 3)
        wm.dispatch(.splitRatio(0.4, exact: true))                   // the 2/3 split
        wm.addClient(ClientID(4), floating: true)                    // ws 1 float
        wm.dispatch(.workspace(.id(2)))
        wm.addClient(ClientID(5))
        wm.addClient(ClientID(6))
        wm.focus(ClientID(5))
        wm.dispatch(.moveIntoGroup(.right))                          // 5 joins 6's group
        wm.dispatch(.renameWorkspace(2, "mail"))
        wm.addClient(ClientID(7), workspace: .special("magic"))
        wm.dispatch(.workspace(.id(1)))
        wm.focus(ClientID(2))
        return wm
    }

    func tile(_ id: ClientID) -> SessionTile { SessionTile(kind: "terminal", cwd: "/c\(id.raw)") }

    /// Placements keyed by the tile's cwd, so two managers with different ids compare.
    func layout(_ wm: WindowManager, cwd: (ClientID) -> String) -> [String: String] {
        var out: [String: String] = [:]
        for p in wm.snapshot().placements {
            out[cwd(p.id)] = "\(p.workspace) \(p.frame) vis=\(p.visible) foc=\(p.focused) float=\(p.floating) "
                + "group=\(p.group.map { "\($0.members.count):\(cwd($0.active))" } ?? "-")"
        }
        return out
    }

    func testRoundTrip() throws {
        let wm = sampleWM()
        let s = wm.exportSession(tile: tile)
        let data = try s.encoded()
        let decoded = try SessionState.decode(data)
        XCTAssertEqual(decoded, s)

        let restored = makeWM()
        var cwds: [ClientID: String] = [:]
        var next: UInt64 = 100
        restored.restoreSession(decoded) { t in
            let id = ClientID(next)
            next += 1
            cwds[id] = t.cwd
            return id
        }
        XCTAssertEqual(layout(restored) { cwds[$0]! }, layout(wm) { "/c\($0.raw)" })
        XCTAssertEqual(restored.activeWorkspace, 1)
        XCTAssertEqual(cwds[restored.focused!], "/c2")
        XCTAssertEqual(restored.name(of: 2), "mail")
        // The group on 2 keeps its shown tab when revisited.
        restored.dispatch(.workspace(.id(2)))
        XCTAssertEqual(layout(restored) { cwds[$0]! }, { wm.dispatch(.workspace(.id(2))); return layout(wm) { "/c\($0.raw)" } }())
    }

    func testSkippedTileCollapsesItsSplit() {
        let wm = makeWM()
        wm.addClient(ClientID(1))
        wm.addClient(ClientID(2))
        let s = wm.exportSession(tile: tile)
        let restored = makeWM()
        var n: UInt64 = 10
        restored.restoreSession(s) { t in
            guard t.cwd != "/c2" else { return nil }   // e.g. a simulator that's gone
            n += 1
            return ClientID(n)
        }
        let p = restored.snapshot().placements
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p[0].frame, CGRect(x: 0, y: 0, width: 1600, height: 1000))
    }

    func testExportLeavesOutUndescribedClients() {
        let wm = makeWM()
        wm.addClient(ClientID(1))
        wm.addClient(ClientID(2))
        let s = wm.exportSession { $0 == ClientID(1) ? self.tile($0) : nil }
        XCTAssertEqual(s.workspaces.count, 1)
        guard case .slot(let slot)? = s.workspaces[0].tiled else { return XCTFail("expected a lone slot") }
        XCTAssertEqual(slot.tabs.map(\.cwd), ["/c1"])
    }

    func testHandWrittenJSON() throws {
        let json = """
        {
          "activeWorkspace": 2,
          "workspaces": [
            {"id": "2", "tiled": {"split": "h", "ratio": 1.2, "children": [
              {"kind": "terminal", "cwd": "~/src", "command": "nvim ."},
              {"tabs": [{"kind": "web", "url": "https://example.com"}, {"kind": "terminal"}], "active": 1}
            ]}},
            {"id": "special:magic", "floating": [{"kind": "terminal", "rect": [0.1, 0.1, 0.5, 0.5]}]}
          ]
        }
        """
        let s = try SessionState.decode(Data(json.utf8))
        let wm = makeWM()
        var kinds: [ClientID: SessionTile] = [:]
        var n: UInt64 = 0
        wm.restoreSession(s) { t in
            n += 1
            kinds[ClientID(n)] = t
            return ClientID(n)
        }
        XCTAssertEqual(wm.activeWorkspace, 2)
        let snap = wm.snapshot()
        let visible = snap.placements.filter(\.visible)
        XCTAssertEqual(visible.count, 2)
        let left = visible.min { $0.frame.minX < $1.frame.minX }!
        XCTAssertEqual(kinds[left.id]?.command, "nvim .")
        XCTAssertEqual(left.frame.width, 960, accuracy: 0.5)  // ratio 1.2 of an even split
        let right = visible.first { $0.id != left.id }!
        XCTAssertEqual(right.group?.members.count, 2)
        XCTAssertEqual(kinds[right.id]?.kind, "terminal", "active: 1 shows the second tab")
        let float = snap.placements.first { $0.workspace == .special("magic") }!
        XCTAssertTrue(float.floating)
        XCTAssertEqual(float.frame, CGRect(x: 160, y: 100, width: 800, height: 500))
    }
}

final class RestorePolicyTests: XCTestCase {
    func testPrograms() {
        var s = RestoreSettings()
        XCTAssertEqual(RestorePolicy.programCommand(argv: ["/opt/homebrew/bin/nvim", "."], settings: s), "nvim .")
        XCTAssertEqual(RestorePolicy.programCommand(argv: ["nvim", "my notes.md"], settings: s), "nvim 'my notes.md'")
        XCTAssertNil(RestorePolicy.programCommand(argv: ["-zsh"], settings: s), "the shell itself")
        XCTAssertNil(RestorePolicy.programCommand(argv: ["make", "deploy"], settings: s), "not on the list")
        s.programs = ["*"]
        s.deny = ["ssh"]
        XCTAssertEqual(RestorePolicy.programCommand(argv: ["make", "deploy"], settings: s), "make deploy")
        XCTAssertNil(RestorePolicy.programCommand(argv: ["/usr/bin/ssh", "prod"], settings: s))
    }

    func testResumeAndQuoting() {
        var s = RestoreSettings()
        s.resume["pi"] = "mywrapper pi --session {id}"
        XCTAssertEqual(RestorePolicy.resumeCommand(SessionAgent(kind: "pi", session: "01a0-c9"), settings: s),
                       "mywrapper pi --session 01a0-c9")
        XCTAssertNil(RestorePolicy.resumeCommand(SessionAgent(kind: "codex", session: "x"), settings: s))
        XCTAssertEqual(RestorePolicy.shellQuote("it's"), "'it'\\''s'")
        XCTAssertEqual(RestorePolicy.shellQuote(""), "''")
        XCTAssertEqual(RestorePolicy.shellQuote("~/x"), "'~/x'")
    }

    func testConfigAndIPC() {
        let c = ConfigParser.parse("""
        session {
            restore = false
            programs = *, nvim
            deny = ssh, make
            resume {
                pi = mywrapper pi --session {id}
                bad = no placeholder
            }
        }
        """)
        XCTAssertEqual(c.errors.count, 1)
        XCTAssertFalse(c.session.enabled)
        XCTAssertEqual(c.session.programs, ["*", "nvim"])
        XCTAssertEqual(c.session.deny, ["ssh", "make"])
        XCTAssertEqual(c.session.resume, ["pi": "mywrapper pi --session {id}"])
        XCTAssertEqual(ConfigParser.parse(defaultConfig).session.resume["pi"], "pi --session {id}")

        let r = IPCRequest.parse(#"resume {"client": 3, "pid": 123, "kind": "pi", "session": "abc", "cwd": "/a b"}"#)
        XCTAssertEqual(r, .success(.resume(ResumeReport(client: 3, pid: 123, kind: "pi", session: "abc", cwd: "/a b"))))
        if case .success = IPCRequest.parse("resume nope") { XCTFail("bad JSON must fail") }
    }
}
