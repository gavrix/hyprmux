import XCTest
@testable import HyprmuxCore

final class EventsTests: XCTestCase {
    // MARK: Dispatcher round trip

    func testCommandParsesBack() {
        let all: [Dispatcher] = [
            .exec(""), .exec("htop -d 5"), .web("github.com"), .webNav(.back), .fillCredential(nil), .fillCredential("op"),
            .launch("Zed"), .killActive,
            .moveFocus(.left), .moveWindow(.up), .swapWindow(.down), .resizeActive(dx: -40, dy: 0),
            .moveActive(dx: 10.5, dy: -3), .workspace(.id(3)), .workspace(.relative(-1)), .workspace(.relativeExisting(1)),
            .workspace(.previous), .workspace(.empty), .workspace(.special("magic")), .workspace(.named("notes")),
            .moveToWorkspace(.id(2), silent: false), .moveToWorkspace(.special("magic"), silent: true),
            .toggleSpecialWorkspace("special"), .toggleSpecialWorkspace("magic"), .toggleFloating,
            .fullscreen(.maximize), .fullscreen(.fullscreen), .toggleSplit, .swapSplit, .splitRatio(0.1, exact: false),
            .splitRatio(1.5, exact: true), .cycleNext(previous: false), .cycleNext(previous: true), .focusCurrentOrLast,
            .centerWindow, .submap("resize"), .submap("reset"), .renameWorkspace(2, "web"), .renameWorkspace(2, ""),
            .picker(.apps), .monitorFullscreen, .toggleGroup, .changeGroupActive(.next), .changeGroupActive(.previous),
            .changeGroupActive(.index(2)), .moveIntoGroup(.right), .moveOutOfGroup, .moveGroupWindow(forward: false),
            .reload, .exit,
        ]
        for d in all {
            let c = d.command
            XCTAssertEqual(try? Dispatcher.parse(c.name, c.args).get(), d, "\(c.name), \(c.args)")
        }
    }

    // MARK: Lines

    func testLines() {
        XCTAssertEqual(HyprmuxEvent.dispatch(.moveFocus(.left), source: .key).line, "dispatch>>key,movefocus,l")
        XCTAssertEqual(HyprmuxEvent.drag(resize: true).line, "dispatch>>mouse,resizewindow,")
        XCTAssertEqual(HyprmuxEvent.submap("reset").line, "submap>>")
        XCTAssertEqual(HyprmuxEvent.appActive(false).line, "appactive>>0")

        let e = HyprmuxEvent.parse("dispatch>>key,exec,echo a, b")
        XCTAssertEqual(e?.dispatched?.source, "key")
        XCTAssertEqual(e?.dispatched?.name, "exec")
        XCTAssertEqual(e?.dispatched?.args, "echo a, b")
        XCTAssertEqual(HyprmuxEvent.parse("configreloaded>>"), HyprmuxEvent.configReloaded)
        XCTAssertNil(HyprmuxEvent.parse("ok"))
        XCTAssertEqual(HyprmuxEvent.parse("openwindow>>3,1,terminal,a, b")?.fields(4), ["3", "1", "terminal", "a, b"])
    }

    // MARK: Snapshot diffs

    func place(_ id: UInt64, ws: WorkspaceID = .regular(1), focused: Bool = false, floating: Bool = false,
               fullscreen: FullscreenMode? = nil, group: GroupInfo? = nil) -> Placement {
        Placement(id: ClientID(id), workspace: ws, frame: .zero, visible: true, focused: focused, floating: floating,
                  fullscreen: fullscreen, z: 0, group: group)
    }

    func snap(_ p: [Placement], active: Int = 1, special: String? = nil, names: [Int: String] = [:]) -> Snapshot {
        var workspaces = Set(p.compactMap { if case .regular(let n) = $0.workspace { return n }; return nil })
        workspaces.insert(active)
        var s = Snapshot(placements: p, activeWorkspace: active, specialVisible: special, workspaces: workspaces.sorted(),
                         focused: p.first { $0.focused }?.id)
        s.workspaceNames = names
        return s
    }

    func diff(_ a: Snapshot?, _ b: Snapshot) -> [String] {
        EventDiff.events(from: a, to: b) { id in EventDiff.Tile(kind: "terminal", title: "t\(id.raw)") }.map(\.line)
    }

    func testFirstSnapshotIsQuiet() {
        XCTAssertEqual(diff(nil, snap([place(1, focused: true)])), [])
        let s = snap([place(1, focused: true)])
        XCTAssertEqual(diff(s, s), [])
    }

    func testOpenFocusAndClose() {
        let one = snap([place(1, focused: true)])
        let two = snap([place(1), place(2, focused: true)])
        XCTAssertEqual(diff(one, two), ["openwindow>>2,1,terminal,t2", "activewindow>>terminal,t2", "activewindowv2>>2"])
        XCTAssertEqual(diff(two, one), ["closewindow>>2", "activewindow>>terminal,t1", "activewindowv2>>1"])
    }

    func testWorkspacesAndScratchpad() {
        let a = snap([place(1, focused: true)])
        let b = snap([place(1), place(2, ws: .regular(2), focused: true)], active: 2, names: [2: "web"])
        XCTAssertEqual(diff(a, b), [
            "createworkspace>>2", "openwindow>>2,2,terminal,t2", "workspace>>2", "workspacev2>>2,web",
            "activewindow>>terminal,t2", "activewindowv2>>2",
        ])
        let c = snap([place(1), place(2, ws: .regular(2), focused: true)], active: 2, special: "magic", names: [2: "web"])
        XCTAssertEqual(diff(b, c), ["activespecial>>special:magic,hyprmux"])
        XCTAssertEqual(diff(c, b), ["activespecial>>,hyprmux"])
        let renamed = snap([place(1), place(2, ws: .regular(2), focused: true)], active: 2, names: [2: "docs"])
        XCTAssertEqual(diff(b, renamed), ["renameworkspace>>2,docs"])
    }

    func testMoveFloatFullscreen() {
        let a = snap([place(1, focused: true), place(2)])
        XCTAssertEqual(diff(a, snap([place(1, focused: true), place(2, ws: .regular(3))])),
                       ["createworkspace>>3", "movewindow>>2,3"])
        XCTAssertEqual(diff(a, snap([place(1, focused: true, floating: true), place(2)])), ["changefloatingmode>>1,1"])
        XCTAssertEqual(diff(a, snap([place(1, focused: true, fullscreen: .maximize), place(2)])), ["fullscreen>>1"])
    }

    func testGroups() {
        let g = GroupID(raw: 7)
        let a = snap([place(1, focused: true), place(2)])
        let one = snap([place(1, focused: true, group: GroupInfo(id: g, members: [ClientID(1)], active: ClientID(1))), place(2)])
        XCTAssertEqual(diff(a, one), ["togglegroup>>1,1"])
        let both = GroupInfo(id: g, members: [ClientID(1), ClientID(2)], active: ClientID(2))
        let two = snap([place(1, group: both), place(2, focused: true, group: both)])
        XCTAssertEqual(diff(one, two), ["moveintogroup>>2", "activewindow>>terminal,t2", "activewindowv2>>2"])
        XCTAssertEqual(diff(two, a), ["togglegroup>>0,1,2", "activewindow>>terminal,t1", "activewindowv2>>1"])
    }

    // MARK: Hooks

    func manifest(_ json: String) -> Result<HookManifest, ParseError> { HookManifest.parse(Data(json.utf8)) }

    func testHookManifests() throws {
        let tour = try manifest(#"{"id":"tour","on":"firstlaunch","run":"terminal","command":"hyprmux-tour --welcome"}"#).get()
        XCTAssertEqual(tour, HookManifest(id: "tour", on: ["firstlaunch"], run: .terminal, command: "hyprmux-tour --welcome"))
        let exec = try manifest(#"{"id":"log","on":["openwindow","closewindow"],"command":"echo $HYPRMUX_EVENT"}"#).get()
        XCTAssertEqual(exec.run, .exec)
        XCTAssertEqual(exec.on, ["openwindow", "closewindow"])
        XCTAssertEqual(try manifest(#"{"id":"tour","disabled":true}"#).get().disabled, true)

        func error(_ json: String) -> String? {
            if case .failure(let e) = manifest(json) { return e.message }
            return nil
        }
        XCTAssertEqual(error(#"{"id":"x","on":"nope","command":"true"}"#), "\"on\": unknown event \"nope\"")
        XCTAssertEqual(error(#"{"id":"x","on":"openwindow","run":"terminal","command":"true"}"#),
                       "\"run\": terminal hooks run on launch or firstlaunch only, not \"openwindow\"")
        XCTAssertEqual(error(#"{"id":"x","on":"launch"}"#), "\"command\" is required")
        XCTAssertEqual(error(#"{"id":"x","on":"launch","command":"true","when":1}"#), "unknown key \"when\"")
    }

    func testUserHooksReplaceBuiltins() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("hooks-\(UUID().uuidString)")
        let builtin = root.appendingPathComponent("builtin"), user = root.appendingPathComponent("user")
        try fm.createDirectory(at: builtin, withIntermediateDirectories: true)
        try fm.createDirectory(at: user, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data(#"{"id":"tour","on":"firstlaunch","run":"terminal","command":"hyprmux-tour --welcome"}"#.utf8)
            .write(to: builtin.appendingPathComponent("tour.json"))
        try Data(#"{"id":"notes","on":"launch","command":"true"}"#.utf8).write(to: builtin.appendingPathComponent("notes.json"))
        try Data(#"{"id":"tour","disabled":true}"#.utf8).write(to: user.appendingPathComponent("no-tour.json"))
        try Data("{".utf8).write(to: user.appendingPathComponent("broken.json"))

        let r = HookRegistry.load(directories: [(.builtin, builtin.path), (.user, user.path)])
        XCTAssertEqual(r.hooks(for: "firstlaunch").map(\.id), [])
        XCTAssertEqual(r.hooks(for: "launch").map(\.id), ["notes"])
        XCTAssertEqual(r.entries.first { $0.id == "tour" }?.source, .user)
        XCTAssertEqual(r.errors.map(\.message), ["not a JSON object"])
    }

    func testConfigCreationIsReported() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cfg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("hyprmux.conf").path
        XCTAssertTrue(ConfigParser.loadOrCreate(path: path).createdFile)
        XCTAssertFalse(ConfigParser.loadOrCreate(path: path).createdFile)
    }
}
