import XCTest
@testable import HyprmuxCore

final class CommandMenuTests: XCTestCase {
    private let all = CommandMenu.Context(hasWindow: true, hasCredentialTile: true)

    func testParsesMenuPicker() {
        XCTAssertEqual(try Dispatcher.parse("picker", "menu").get(), .picker(.menu))
        XCTAssertEqual(Dispatcher.picker(.menu).command.args, "menu")
    }

    func testDefaultConfigBindsMenuToCommandSlash() {
        let c = ConfigParser.parse(defaultConfig)
        XCTAssertTrue(c.errors.isEmpty, "\(c.errors)")
        XCTAssertTrue(c.binds.contains { $0.dispatcher == .picker(.menu) && $0.mods == .super && $0.trigger == KeyCodes.parse("slash") })
    }

    func testRowsShowTheirBinds() {
        let c = ConfigParser.parse("""
        bind = SUPER, P, picker, workspace
        bind = SUPER SHIFT, P, picker, movetoworkspace
        bind = SUPER, slash, picker, menu
        """)
        let items = CommandMenu.items(binds: c.binds, context: all)
        XCTAssertEqual(items.first { $0.id == "workspace" }?.detail, "⌘P")
        XCTAssertEqual(items.first { $0.id == "movetoworkspace" }?.detail, "⇧⌘P")
        XCTAssertEqual(items.first { $0.id == "layout" }?.detail, "", "unbound rows show no chord")
        XCTAssertNil(items.first { $0.id == "menu" }, "the menu doesn't list itself")
    }

    func testFirstBindWinsAndAliasesCount() {
        let c = ConfigParser.parse("""
        bind = SUPER, Return, exec,
        bind = SUPER, T, exec,
        bind = SUPER SHIFT, D, launch,
        """)
        let items = CommandMenu.items(binds: c.binds, context: all)
        XCTAssertEqual(items.first { $0.id == "terminal" }?.detail, "⌘↩")
        XCTAssertEqual(items.first { $0.id == "apps" }?.detail, "⇧⌘D", "launch with no app opens the launcher too")
    }

    func testSubmapBindsAreIgnored() {
        let c = ConfigParser.parse("""
        bind = SUPER, R, submap, resize
        submap = resize
        bind = , P, picker, workspace
        submap = reset
        """)
        XCTAssertEqual(CommandMenu.items(binds: c.binds, context: all).first { $0.id == "workspace" }?.detail, "")
    }

    func testRowsThatCantRunAreHidden() {
        let none = CommandMenu.Context(hasWindow: false, hasCredentialTile: false)
        let ids = CommandMenu.items(binds: [], context: none).map(\.id)
        XCTAssertFalse(ids.contains("movetoworkspace"))
        XCTAssertFalse(ids.contains("movetoworkspacesilent"))
        XCTAssertFalse(ids.contains("fillcredential"))
        XCTAssertTrue(ids.contains("workspace"))
        XCTAssertEqual(CommandMenu.items(binds: [], context: all).count, CommandMenu.entries.count)
    }

    func testIDsAreUniqueAndResolve() {
        let ids = CommandMenu.entries.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for e in CommandMenu.entries { XCTAssertEqual(CommandMenu.dispatcher(for: e.id), e.dispatcher) }
        XCTAssertNil(CommandMenu.dispatcher(for: "nope"))
    }
}
