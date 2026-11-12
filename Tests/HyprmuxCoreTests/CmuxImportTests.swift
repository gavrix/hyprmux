import CoreGraphics
import XCTest
@testable import HyprmuxCore

final class CmuxImportTests: XCTestCase {
    /// A cmux snapshot, trimmed to the shape cmux 0.64 writes: one window, three workspaces.
    let snapshot = #"""
    {
      "version": 1,
      "createdAt": 1791600750.8,
      "windows": [{
        "windowId": "W",
        "sidebar": {"isVisible": true},
        "tabManager": {
          "selectedWorkspaceIndex": 0,
          "workspaces": [
            {
              "customTitle": "Feed work",
              "currentDirectory": "/src/shop",
              "focusedPanelId": "P3",
              "layoutMode": "splits",
              "layout": {"type": "split", "split": {
                "orientation": "horizontal", "dividerPosition": 0.7,
                "first": {"type": "pane", "pane": {"panelIds": ["P1"], "selectedPanelId": "P1"}},
                "second": {"type": "split", "split": {
                  "orientation": "vertical", "dividerPosition": 0.25,
                  "first": {"type": "pane", "pane": {"panelIds": ["P2", "P3", "P4"], "selectedPanelId": "P2"}},
                  "second": {"type": "pane", "pane": {"panelIds": ["GONE"], "selectedPanelId": "GONE"}}
                }}
              }},
              "panels": [
                {"id": "P1", "type": "terminal", "directory": "/src/shop/app", "title": "π - feed",
                 "terminal": {"wasAgentRunning": true, "isRemoteTerminal": false,
                   "agent": {"kind": "pi", "sessionId": "01a0-pi", "workingDirectory": "/src/shop/agent"}}},
                {"id": "P2", "type": "browser", "browser": {"urlString": "http://localhost:3000", "pageZoom": 1}},
                {"id": "P3", "type": "terminal", "directory": "/src/shop",
                 "terminal": {"wasAgentRunning": false, "agent": {"kind": "pi", "sessionId": "01a0-exited"}}},
                {"id": "P4", "type": "markdown", "markdown": {"filePath": "/src/shop/My Notes.md"}},
                {"id": "P5", "type": "somethingNew", "somethingNew": {}}
              ]
            },
            {
              "gitBranch": {"branch": "feature/lazy-feed", "isDirty": true},
              "currentDirectory": "/src/shop",
              "layout": {"type": "pane", "pane": {"panelIds": ["Q1"], "selectedPanelId": "Q1"}},
              "panels": [{"id": "Q1", "type": "terminal", "terminal": {"workingDirectory": "/src/q",
                "agent": {"kind": "codex", "sessionId": "01a0-codex"}, "wasAgentRunning": true}}]
            },
            {
              "customTitle": "Feed work",
              "layout": {"type": "pane", "pane": {"panelIds": ["R1"]}},
              "panels": [{"id": "R1", "type": "terminal", "directory": "/r"}]
            },
            {
              "customTitle": "Empty",
              "layout": {"type": "pane", "pane": {"panelIds": []}},
              "panels": []
            }
          ]
        }
      }]
    }
    """#

    func convert() throws -> CmuxImport.Result {
        try CmuxImport.convert(Data(snapshot.utf8))
    }

    func testWorkspacesBecomeNamedLayouts() throws {
        let r = try convert()
        XCTAssertEqual(r.workspaces.map(\.name), ["Feed work", "feature/lazy-feed", "Feed work 2"],
                       "the title, else the git branch; duplicates numbered; empty workspaces left out")
        XCTAssertTrue(r.workspaces.allSatisfy { $0.id.isEmpty }, "layouts are found by name, not number")
        XCTAssertEqual(r.agents, 2)
        XCTAssertEqual(r.tiles, 6)
    }

    func testSplitTreeTabsAndTiles() throws {
        let w = try convert().workspaces[0]
        guard case .split(let v1, let r1, let left, let right)? = w.tiled else { return XCTFail("\(String(describing: w.tiled))") }
        XCTAssertFalse(v1, "horizontal in cmux is side by side")
        XCTAssertEqual(r1, 1.4, accuracy: 0.0001, "a 0.7 share is ratio 1.4")
        guard case .slot(let agentSlot) = left else { return XCTFail() }
        XCTAssertEqual(agentSlot.tabs, [SessionTile(kind: "terminal", key: 1, cwd: "/src/shop/agent",
                                                    agent: SessionAgent(kind: "pi", session: "01a0-pi"))],
                       "a running agent resumes, from its own directory")
        // The second split lost its pane (its panel is gone), so the tab group stands alone.
        guard case .slot(let group) = right else { return XCTFail("\(right)") }
        XCTAssertEqual(group.tabs.map(\.kind), ["web", "terminal", "web"], "unknown panel types are skipped")
        XCTAssertEqual(group.active, 0)
        XCTAssertEqual(group.tabs[0].url, "http://localhost:3000")
        XCTAssertNil(group.tabs[1].agent, "an agent that had exited comes back as a shell")
        XCTAssertEqual(group.tabs[1].cwd, "/src/shop")
        XCTAssertEqual(group.tabs[2].url, "file:///src/shop/My%20Notes.md", "markdown opens in the viewer")
        XCTAssertEqual(w.focused, 3, "focus follows cmux's focused panel")
    }

    func testVerticalSplitAndClamp() throws {
        let json = #"""
        {"version": 1, "windows": [{"tabManager": {"workspaces": [{"customTitle": "x",
          "layout": {"type": "split", "split": {"orientation": "vertical", "dividerPosition": 0.01,
            "first": {"type": "pane", "pane": {"panelIds": ["a"]}},
            "second": {"type": "pane", "pane": {"panelIds": ["b"]}}}},
          "panels": [{"id": "a", "type": "terminal"}, {"id": "b", "type": "terminal"}]}]}}]}
        """#
        let w = try CmuxImport.convert(Data(json.utf8)).workspaces[0]
        guard case .split(let vertical, let ratio, _, _)? = w.tiled else { return XCTFail() }
        XCTAssertTrue(vertical)
        XCTAssertEqual(ratio, 0.1, "clamped to what Hyprmux allows")
    }

    func testAgentCwdFallsBackToTerminalDirectory() throws {
        let w = try convert().workspaces[1]
        guard case .slot(let s)? = w.tiled else { return XCTFail() }
        XCTAssertEqual(s.tabs[0].agent, SessionAgent(kind: "codex", session: "01a0-codex"))
        XCTAssertEqual(s.tabs[0].cwd, "/src/q")
    }

    func testResultIsAValidLayoutFile() throws {
        let r = try convert()
        var file = SessionState()
        file.workspaces = [r.workspaces[0]]
        XCTAssertEqual(try SessionState.decode(file.encoded()), file)

        var s = WMSettings()
        s.gapsIn = .zero
        s.gapsOut = .zero
        let wm = WindowManager(monitor: CGRect(x: 0, y: 0, width: 1000, height: 800), settings: s)
        var next: UInt64 = 1
        var made: [String: ClientID] = [:]
        wm.loadLayout(file, defaultName: nil) { t in
            let id = ClientID(next)
            next += 1
            made[t.url ?? t.cwd ?? "?"] = id
            return id
        }
        let placements = Dictionary(uniqueKeysWithValues: wm.snapshot().placements.map { ($0.id, $0) })
        let agent = try XCTUnwrap(made["/src/shop/agent"].flatMap { placements[$0] })
        let web = try XCTUnwrap(made["http://localhost:3000"].flatMap { placements[$0] })
        XCTAssertEqual(agent.frame.width, 700, accuracy: 1, "the first child keeps its 70 % share")
        XCTAssertEqual(web.frame.minX, 700, accuracy: 1)
        XCTAssertEqual(wm.name(of: wm.activeWorkspace), "Feed work")
    }

    func testRejectsOtherVersions() {
        XCTAssertThrowsError(try CmuxImport.convert(Data(#"{"version": 2, "windows": []}"#.utf8))) { e in
            XCTAssertEqual(e as? CmuxImport.ImportError, .unsupportedVersion(2))
        }
        XCTAssertThrowsError(try CmuxImport.convert(Data("[]".utf8)))
    }

    func testLongTitlesKeepTheirFirstLine() throws {
        let title = "please look at this PR\n\nand explain " + String(repeating: "x", count: 100)
        let json = """
        {"version": 1, "windows": [{"tabManager": {"workspaces": [
          {"customTitle": \(String(data: try JSONEncoder().encode(title), encoding: .utf8)!),
           "layout": {"type": "pane", "pane": {"panelIds": ["a"]}}, "panels": [{"id": "a", "type": "terminal"}]},
          {"customTitle": "\(String(repeating: "y", count: 80))",
           "layout": {"type": "pane", "pane": {"panelIds": ["b"]}}, "panels": [{"id": "b", "type": "terminal"}]},
          {"currentDirectory": "/src/app",
           "layout": {"type": "pane", "pane": {"panelIds": ["c"]}}, "panels": [{"id": "c", "type": "terminal"}]},
          {"layout": {"type": "pane", "pane": {"panelIds": ["d"]}}, "panels": [{"id": "d", "type": "terminal"}]}
        ]}}]}
        """
        let names = try CmuxImport.convert(Data(json.utf8)).workspaces.map(\.name)
        XCTAssertEqual(names, ["please look at this PR", String(repeating: "y", count: 59) + "…", "app", "cmux 4"])
    }

    // MARK: Finding snapshots

    func testFileNames() {
        XCTAssertEqual(CmuxImport.parseFileName("session-com.cmuxterm.app.json")?.bundleID, "com.cmuxterm.app")
        XCTAssertEqual(CmuxImport.parseFileName("session-com.cmuxterm.app-previous.json")?.isBackup, true)
        XCTAssertEqual(CmuxImport.parseFileName("session-com.cmuxterm.app.nightly.json")?.bundleID, "com.cmuxterm.app.nightly")
        XCTAssertNil(CmuxImport.parseFileName("session-com.cmuxterm.app.schema-v2.json"))
        XCTAssertNil(CmuxImport.parseFileName("session-com.cmuxterm.app.unusable.json"))
        XCTAssertNil(CmuxImport.parseFileName("session-com.other.app.json"))
        XCTAssertNil(CmuxImport.parseFileName("closed-item-history-com.cmuxterm.app.json"))
    }

    func testSourcesPreferStableAndMainFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for f in ["session-com.cmuxterm.app.json", "session-com.cmuxterm.app-previous.json",
                  "session-com.cmuxterm.app.nightly-previous.json", "search.db"] {
            try Data("{}".utf8).write(to: dir.appendingPathComponent(f))
        }
        let found = CmuxImport.sources(in: dir.path)
        XCTAssertEqual(found.map { ($0.path as NSString).lastPathComponent },
                       ["session-com.cmuxterm.app.json", "session-com.cmuxterm.app.nightly-previous.json"],
                       "a backup counts only without its main file")
        XCTAssertEqual(found.map(\.label), ["cmux", "cmux nightly"])
        XCTAssertEqual(CmuxImport.sources(in: dir.appendingPathComponent("missing").path), [])
    }
}
