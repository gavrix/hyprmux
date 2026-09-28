import CoreGraphics
import XCTest
@testable import HypermuxCore

final class WorkspaceNameTests: XCTestCase {
    func makeWM(names: [Int: String] = [:]) -> WindowManager {
        var s = WMSettings()
        s.gapsIn = .zero
        s.gapsOut = .zero
        s.workspaceNames = names
        return WindowManager(monitor: CGRect(x: 0, y: 0, width: 1600, height: 1000), settings: s)
    }

    func testRenameAndClear() {
        let wm = makeWM(names: [2: "web"])
        wm.addClient(ClientID(1))
        wm.dispatch(.renameWorkspace(1, "  code "))
        XCTAssertEqual(wm.name(of: 1), "code")
        XCTAssertEqual(wm.snapshot().workspaceNames, [1: "code"])
        // A runtime name wins over the rule's; clearing it falls back to the rule's.
        wm.dispatch(.renameWorkspace(2, "mail"))
        XCTAssertEqual(wm.name(of: 2), "mail")
        wm.dispatch(.renameWorkspace(2, ""))
        XCTAssertEqual(wm.name(of: 2), "web")
        wm.dispatch(.renameWorkspace(1, ""))
        XCTAssertNil(wm.name(of: 1))
    }

    func testNamesOutliveEmptyWorkspaces() {
        let wm = makeWM()
        wm.dispatch(.workspace(.id(3)))
        wm.dispatch(.renameWorkspace(3, "notes"))
        wm.dispatch(.workspace(.id(1)))
        XCTAssertFalse(wm.snapshot().workspaces.contains(3))
        XCTAssertEqual(wm.name(of: 3), "notes")
        XCTAssertEqual(wm.workspace(named: "NOTES"), 3)
    }

    func testNamedTargetFindsOrCreates() {
        let wm = makeWM(names: [2: "web"])
        wm.addClient(ClientID(1))  // on 1
        wm.dispatch(.workspace(.named("web")))
        XCTAssertEqual(wm.activeWorkspace, 2)
        // A new name skips numbers with windows (1) or a name (2).
        wm.dispatch(.workspace(.named("mail")))
        XCTAssertEqual(wm.activeWorkspace, 3)
        XCTAssertEqual(wm.name(of: 3), "mail")
        wm.dispatch(.workspace(.id(1)))
        wm.dispatch(.moveToWorkspace(.named("chat"), silent: true))
        XCTAssertEqual(wm.workspace(of: ClientID(1)), .regular(4))
        XCTAssertEqual(wm.name(of: 4), "chat")
    }

    func testChoices() {
        let wm = makeWM(names: [5: "music"])
        wm.addClient(ClientID(1))
        wm.addClient(ClientID(2))
        wm.dispatch(.workspace(.id(2)))
        let c = wm.workspaceChoices(extraSpecials: ["magic"])
        XCTAssertEqual(c.map(\.id), [.regular(1), .regular(2), .regular(5), .special("magic")])
        XCTAssertEqual(c.map(\.windows), [2, 0, 0, 0])
        XCTAssertEqual(c.map(\.active), [false, true, false, false])
        XCTAssertEqual(c[2].name, "music")

        let items = WorkspacePicker.items(c)
        XCTAssertEqual(items.map(\.title), ["1", "2", "5  music", "special:magic"])
        XCTAssertEqual(items.map(\.detail), ["2 windows", "empty · current", "empty", "empty"])
        XCTAssertEqual(items.map(\.id), ["1", "2", "5", "special:magic"])
    }

    func testPickerTargets() {
        XCTAssertEqual(WorkspacePicker.target(for: .item("3")), .id(3))
        XCTAssertEqual(WorkspacePicker.target(for: .item("special:magic")), .special("magic"))
        XCTAssertEqual(WorkspacePicker.target(for: .text(" 12 ")), .id(12))
        XCTAssertEqual(WorkspacePicker.target(for: .text("mail")), .named("mail"))
        XCTAssertNil(WorkspacePicker.target(for: .text("  ")))
    }

    func testDetailNotSearchedForWorkspaces() {
        let items = [PickerItem(id: "1", title: "1", detail: "2 windows")]
        var p = Picker(title: "ws", items: items, allowsCustom: true, searchesDetail: false)
        p.setQuery("12")
        XCTAssertTrue(p.rows.isEmpty)
        XCTAssertEqual(p.result, .text("12"))
    }

    func testParsing() {
        XCTAssertEqual(WorkspaceTarget(hyprland: "name:mail"), .named("mail"))
        XCTAssertNil(WorkspaceTarget(hyprland: "name:"))
        XCTAssertEqual(try Dispatcher.parse("renameworkspace", "2 my work").get(), .renameWorkspace(2, "my work"))
        XCTAssertEqual(try Dispatcher.parse("renameworkspace", "2").get(), .renameWorkspace(2, ""))
        XCTAssertThrowsError(try Dispatcher.parse("renameworkspace", "x").get())
        XCTAssertEqual(try Dispatcher.parse("picker", "movetoworkspace").get(), .picker(.moveToWorkspace))
        XCTAssertThrowsError(try Dispatcher.parse("picker", "nope").get())
        let c = ConfigParser.parse("""
        workspace = 3, defaultName:mail, persistent:true
        workspace = 4, gapsout:0
        workspace = name:foo, defaultName:bar
        """)
        XCTAssertEqual(c.errors, [])
        XCTAssertEqual(c.wm.workspaceNames, [3: "mail"])
    }
}
