import XCTest
@testable import HyprmuxCore

final class KeycastTests: XCTestCase {
    func testChords() {
        XCTAssertEqual(KeyChord.display([.super], .key(0x24)), "⌘↩")
        XCTAssertEqual(KeyChord.display([.super, .shift, .ctrl, .alt], .key(0x25)), "⌃⌥⇧⌘L")
        XCTAssertEqual(KeyChord.display([.super, .shift], .key(0x31)), "⇧⌘Space")
        XCTAssertEqual(KeyChord.display([.ctrl, .shift], .key(0x30)), "⌃⇧⇥")
        XCTAssertEqual(KeyChord.display([.super], .key(0x12)), "⌘1")
        XCTAssertEqual(KeyChord.display([.super], .key(0x21)), "⌘[")
        XCTAssertEqual(KeyChord.display([], .key(0x35)), "⎋")
        XCTAssertEqual(KeyChord.display([.super], .mouse(272)), "⌘click")
    }

    func testLabels() {
        XCTAssertEqual(Dispatcher.exec("").label, "New terminal")
        XCTAssertEqual(Dispatcher.moveFocus(.left).label, "Focus left")
        XCTAssertEqual(Dispatcher.workspace(.id(2)).label, "Workspace 2")
        XCTAssertEqual(Dispatcher.moveToWorkspace(.special("magic"), silent: false).label, "Move to scratchpad magic")
        XCTAssertEqual(Dispatcher.submap("resize").label, "Resize mode")
        XCTAssertEqual(Dispatcher.submap("reset").label, "Leave mode")
        XCTAssertEqual(Dispatcher.picker(.workspace).label, "Go to workspace")
    }

    func testBinddDescription() {
        let c = ConfigParser.parse("""
        bindd = SUPER, Return, Open a shell, exec,
        bind = SUPER, W, killactive
        """)
        XCTAssertEqual(c.errors, [])
        XCTAssertEqual(c.binds[0].description, "Open a shell")
        XCTAssertEqual(c.binds[0].dispatcher, .exec(""))
        XCTAssertEqual(c.binds[0].label, "Open a shell")
        XCTAssertEqual(c.binds[1].label, "Close window")
        XCTAssertTrue(ConfigParser.parse("hud:keycast = true").hud.keycast)
        XCTAssertFalse(ConfigParser.parse(defaultConfig).hud.keycast)
    }

    func testRepeatsCountUp() {
        var k = KeycastState()
        k.press(chord: "⌃⌘L", label: "Resize", now: 0)
        k.press(chord: "⌃⌘L", label: "Resize", now: 0.5)
        k.press(chord: "⌃⌘L", label: "Resize", now: 1.0)
        XCTAssertEqual(k.count, 3)
        k.press(chord: "⌃⌘L", label: "Resize", now: 5)
        XCTAssertEqual(k.count, 1, "a pause starts over")
        k.press(chord: "⌘H", label: "Focus left", now: 5.1)
        XCTAssertEqual(k.chord, "⌘H")
        XCTAssertEqual(k.count, 1)
    }
}
