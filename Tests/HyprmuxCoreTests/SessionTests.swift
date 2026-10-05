import CoreGraphics
import XCTest
@testable import HyprmuxCore

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

    /// Creating a surface can run the main run loop (a simulator tile waits for a helper
    /// process), so queued focus changes land while a workspace is half built. The
    /// workspace under construction looks empty then, and used to be thrown away, leaving
    /// its clients running but in no workspace.
    func testFocusChangeDuringRestoreKeepsTheWorkspaceBeingBuilt() {
        var s = SessionState()
        func ws(_ id: String, _ cwds: [String]) -> SessionWorkspace {
            let tiles = cwds.map { SessionNode.slot(SessionSlot(tabs: [SessionTile(kind: "terminal", cwd: $0)])) }
            let tree = tiles.dropFirst().reduce(tiles[0]) { .split(vertical: false, ratio: 1, first: $0, second: $1) }
            return SessionWorkspace(id: id, tiled: tree)
        }
        s.workspaces = [ws("1", ["/a"]), ws("2", ["/b"]), ws("3", ["/c1", "/c2", "/c3"]), ws("4", ["/d"])]
        let wm = makeWM()
        var n: UInt64 = 0
        var cwds: [ClientID: String] = [:]
        wm.restoreSession(s) { t in
            // The last tile of 3: a web tile on 2 takes focus in the middle of it.
            if t.cwd == "/c3", let b = cwds.first(where: { $0.value == "/b" })?.key { wm.focus(b) }
            n += 1
            cwds[ClientID(n)] = t.cwd
            return ClientID(n)
        }
        let placed = Dictionary(uniqueKeysWithValues: wm.snapshot().placements.map { (cwds[$0.id]!, $0.workspace) })
        XCTAssertEqual(placed.count, 6)
        XCTAssertEqual(placed["/c1"], .regular(3))
        XCTAssertEqual(placed["/c3"], .regular(3))
        XCTAssertEqual(wm.exportSession { cwds[$0].map { SessionTile(kind: "terminal", cwd: $0) } }.workspaces.map(\.id),
                       ["1", "2", "3", "4"])
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

    func testAppTileKeepsItsRestoreToken() throws {
        let json = #"{"workspaces":[{"id":"1","tiled":{"kind":"app","appEntry":"dev.gavrix.hyprmux.mobile","restoreToken":"ios:ABC"}}]}"#
        let state = try SessionState.decode(Data(json.utf8))
        guard case .slot(let slot)? = state.workspaces.first?.tiled else { return XCTFail("expected a slot") }
        let tile = try XCTUnwrap(slot.tabs.first)
        XCTAssertEqual(tile.appEntry, "dev.gavrix.hyprmux.mobile")
        XCTAssertEqual(tile.restoreToken, "ios:ABC")
        let encoded = String(decoding: try state.encoded(), as: UTF8.self)
        XCTAssertTrue(encoded.contains(#""restoreToken" : "ios:ABC""#))
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

    func testTypedCommandLine() {
        var s = RestoreSettings()
        s.programs = ["nvim", "tool release"]
        let ruby = ["/nix/store/x-ruby/bin/ruby", "--disable-all", "/usr/local/libexec/tool", "release"]
        // The shell's title is what was typed; the process is ruby.
        XCTAssertEqual(RestorePolicy.programCommand(argv: ruby, typed: "tool release", settings: s), "tool release")
        XCTAssertEqual(RestorePolicy.programCommand(argv: ruby, typed: "FOO=1 tool release --fast", settings: s),
                       "FOO=1 tool release --fast")
        XCTAssertNil(RestorePolicy.programCommand(argv: ruby, typed: "tool deploy", settings: s), "entry is two words")
        XCTAssertNil(RestorePolicy.programCommand(argv: ruby, settings: s), "ruby isn't listed")
        // A title the program set itself doesn't match, so argv is used.
        XCTAssertEqual(RestorePolicy.programCommand(argv: ["nvim", "a.txt"], typed: "a.txt - NVIM", settings: s), "nvim a.txt")
        // The shell in the foreground: nothing, whatever the title says.
        XCTAssertNil(RestorePolicy.programCommand(argv: ["-zsh"], typed: "tool release", settings: s))
        s.deny = ["tool release"]
        XCTAssertNil(RestorePolicy.programCommand(argv: ruby, typed: "tool release", settings: s))
        // "*" trusts only argv, never a title.
        s = RestoreSettings()
        s.programs = ["*"]
        XCTAssertEqual(RestorePolicy.programCommand(argv: ["htop"], typed: "π - whatever", settings: s), "htop")
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

final class LayoutTemplateTests: XCTestCase {
    func makeWM(names: [Int: String] = [:]) -> WindowManager {
        var s = WMSettings()
        s.gapsIn = .zero
        s.gapsOut = .zero
        s.workspaceNames = names
        return WindowManager(monitor: CGRect(x: 0, y: 0, width: 1600, height: 1000), settings: s)
    }

    let layout = try! SessionState.decode(Data("""
    {"workspaces": [{"tiled": {"split": "h", "children": [
        {"kind": "terminal", "cwd": "~/src", "agent": {"kind": "pi"}},
        {"kind": "web", "url": "http://localhost:3000"}]}}]}
    """.utf8))

    func testLoadBuildsNamesAndShows() {
        let wm = makeWM()
        wm.addClient(ClientID(1))                       // workspace 1 is busy
        var n: UInt64 = 10
        let touched = wm.loadLayout(layout, defaultName: "dev") { _ in n += 1; return ClientID(n) }
        XCTAssertEqual(touched, [2])
        XCTAssertEqual(wm.name(of: 2), "dev")
        XCTAssertEqual(wm.activeWorkspace, 2)
        XCTAssertEqual(wm.snapshot().placements.filter(\.visible).count, 2)
        XCTAssertNotNil(wm.focused)
        XCTAssertEqual(wm.workspace(of: wm.focused!), .regular(2))
    }

    func testLoadingAgainOnlyGoesThere() {
        let wm = makeWM()
        var n: UInt64 = 0
        let make: (SessionTile) -> ClientID? = { _ in n += 1; return ClientID(n) }
        wm.loadLayout(layout, defaultName: "dev", make: make)
        wm.dispatch(.workspace(.id(5)))
        let before = n
        XCTAssertEqual(wm.loadLayout(layout, defaultName: "dev", make: make), [1])
        XCTAssertEqual(n, before, "no new windows")
        XCTAssertEqual(wm.activeWorkspace, 1)
    }

    func testFillsAnEmptyNamedWorkspace() {
        let wm = makeWM(names: [4: "dev"])
        wm.addClient(ClientID(1))
        var n: UInt64 = 10
        XCTAssertEqual(wm.loadLayout(layout, defaultName: "dev") { _ in n += 1; return ClientID(n) }, [4])
        XCTAssertEqual(wm.activeWorkspace, 4)
    }

    func testExportWorkspaceAndStartTemplates() throws {
        let wm = makeWM()
        wm.addClient(ClientID(1))
        wm.addClient(ClientID(2))
        var w = try XCTUnwrap(wm.exportWorkspace(.regular(1)) { SessionTile(kind: "terminal", cwd: "/c\($0.raw)") })
        w.id = ""
        w.name = "pair"
        var file = SessionState()
        file.workspaces = [w]
        let decoded = try SessionState.decode(try file.encoded())
        XCTAssertEqual(decoded.workspaces[0].name, "pair")
        XCTAssertEqual(decoded.workspaces[0].id, "")

        var s = RestoreSettings()
        s.start["pi"] = "mywrapper pi"
        XCTAssertEqual(RestorePolicy.resumeCommand(SessionAgent(kind: "pi"), settings: s), "mywrapper pi")
        XCTAssertNil(RestorePolicy.resumeCommand(SessionAgent(kind: "codex"), settings: s))
        XCTAssertEqual(ConfigParser.parse("session:start:pi = mywrapper pi").session.start, ["pi": "mywrapper pi"])
    }
}
