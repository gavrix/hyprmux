import XCTest
import HyprmuxCore
@testable import HyprmuxTour

final class TourTests: XCTestCase {
    let config = ConfigParser.parse(defaultConfig)
    var keys: TourKeys { TourKeys(config: config) }

    // MARK: Keys

    func testKeysComeFromTheConfig() {
        XCTAssertEqual(keys.newTerminal, "⌘↩")
        XCTAssertEqual(keys.focusAll, "⌘H/J/K/L")
        XCTAssertEqual(keys.focus(.left), "⌘H")
        XCTAssertEqual(keys.moveAll, "⇧⌘H/J/K/L")
        XCTAssertEqual(keys.swapAll, "⌥⌘H/J/K/L")
        XCTAssertEqual(keys.resize, "⌃⌘H/L")
        XCTAssertEqual(keys.resizeMode, "⌘R")
        XCTAssertEqual(keys.last, "⌘`")
        XCTAssertEqual(keys.float, "⇧⌘Space")
        XCTAssertEqual(keys.maximize, "⌘F")
        XCTAssertEqual(keys.nextTab, "⌃Tab")
        XCTAssertEqual(keys.workspace(2), "⌘2")
        XCTAssertEqual(keys.moveToWorkspace(3), "⇧⌘3")
        XCTAssertEqual(keys.scratchpad, "⌘S")
        XCTAssertEqual(keys.close, "⌘W")
    }

    func testRebindsAndMissingBinds() {
        let c = ConfigParser.parse("""
        bind = SUPER, N, exec,
        bind = SUPER, A, movefocus, l
        bind = SUPER, S, movefocus, d
        bind = SUPER, W, movefocus, u
        bind = SUPER ALT, D, movefocus, r
        """)
        let k = TourKeys(config: c)
        XCTAssertEqual(k.newTerminal, "⌘N")
        XCTAssertEqual(k.focusAll, "⌘A ⌘S ⌘W ⌥⌘D", "mixed modifiers are listed one by one")
        XCTAssertNil(k.last)
        XCTAssertTrue(TourMarkup.key(k.last, unbound: "focuscurrentorlast").contains("unbound"))
    }

    // MARK: Markup and wrapping

    func testMarkup() {
        let line = TourMarkup.parse("Press \(TourMarkup.key("⌘`", unbound: "")) in `~/.config` *now*.")
        XCTAssertEqual(line, [
            TourSpan("Press "), TourSpan("⌘`", .key), TourSpan(" in "), TourSpan("~/.config", .code),
            TourSpan(" "), TourSpan("now", .bold), TourSpan("."),
        ])
        XCTAssertEqual(TourMarkup.plain("Press \(TourMarkup.key("⌘1", unbound: "")) now."), "Press ⌘1 now.")
    }

    func testWrapKeepsKeysWholeAndIndents() {
        let line = [TourSpan("▸ "), TourSpan("Press ")] + [TourSpan("⇧⌘Space", .key)] + [TourSpan(" to float this tile.")]
        let rows = TourWrap.wrap(line, width: 16, indent: 2)
        let text = rows.map { String($0.map(\.character)) }
        XCTAssertEqual(text, ["▸ Press", "  \u{A0}⇧⌘Space\u{A0} to", "  float this", "  tile."])
        XCTAssertTrue(rows.allSatisfy { $0.count <= 16 })
    }

    func testWrapCutsWordsLongerThanARow() {
        let rows = TourWrap.wrap([TourSpan("abcdefghijklmnopqrst")], width: 8)
        XCTAssertEqual(rows.map { String($0.map(\.character)) }, ["abcdefgh", "ijklmnop", "qrst"])
    }

    // MARK: World

    func testDecodesHyprmuxReplies() throws {
        let clients = """
        [{"id":2,"ref":"surface:2","workspace":"1","floating":false,"fullscreen":null,"focused":true,"visible":true,
          "at":[14,40],"size":[600,800],"title":"zsh","kind":"terminal","capabilities":[]},
         {"id":5,"workspace":"special:magic","floating":false,"fullscreen":1,"focused":false,"visible":false,
          "at":[0,0],"size":[10,10],"kind":"web","url":"https://hyprland.org/",
          "group":{"id":5,"members":[5,6],"active":6}}]
        """
        let workspaces = """
        [{"id":"1","name":null,"windows":1,"active":true},{"id":"special:magic","name":null,"windows":1,"active":true}]
        """
        let w = try TourWorld.decode(clients: Data(clients.utf8), workspaces: Data(workspaces.utf8), appActive: false)
        XCTAssertEqual(w.focused?.id, 2)
        XCTAssertEqual(w.surface(2)?.frame, TourRect(x: 14, y: 40, width: 600, height: 800))
        XCTAssertEqual(w.surface(5)?.fullscreen, 1)
        XCTAssertEqual(w.surface(5)?.group, TourSurface.Group(members: [5, 6], active: 6))
        XCTAssertEqual(w.surface(5)?.url, "https://hyprland.org/")
        XCTAssertTrue(w.surface(5)!.inScratchpad)
        XCTAssertEqual(w.activeWorkspace, 1)
        XCTAssertTrue(w.scratchpadVisible)
        XCTAssertEqual(w.appActive, false)
    }

    func testRejectsErrors() {
        XCTAssertThrowsError(try TourWorld.decode(clients: Data("error: nope".utf8), workspaces: Data("[]".utf8)))
    }

    // MARK: Engine

    let left = TourRect(x: 0, y: 0, width: 500, height: 800)
    let right = TourRect(x: 510, y: 0, width: 500, height: 800)
    let full = TourRect(x: 0, y: 0, width: 1010, height: 800)

    func world(_ surfaces: [TourSurface], active: String = "1", scratchpad: Bool = false) -> TourWorld {
        var ws = Set(surfaces.map(\.workspace)).map { TourWorkspace(id: $0, windows: 1, active: $0 == active) }
        if scratchpad { ws.append(TourWorkspace(id: "special:magic", windows: 0, active: true)) }
        return TourWorld(surfaces: surfaces, workspaces: ws)
    }

    func engine(at step: String, _ w: TourWorld, tourSurfaces: Set<UInt64> = [1]) -> TourEngine {
        TourEngine(index: Curriculum.ids.firstIndex(of: step)!, world: w, tutor: 1, tourSurfaces: tourSurfaces,
                   config: config, configPath: "/tmp/hyprmux.conf")
    }

    func testOpenStepWaitsForANewTileThenTheReturn() {
        var e = engine(at: "open", world([TourSurface(id: 1, focused: true, frame: full)]))
        XCTAssertEqual(e.update(world([TourSurface(id: 1, focused: true, frame: full)])), 0)
        XCTAssertEqual(e.update(world([TourSurface(id: 1, frame: left), TourSurface(id: 2, focused: true, frame: right)])), 1)
        XCTAssertEqual(e.currentTask?.isReturn, true)
        XCTAssertFalse(e.isStepDone)
        XCTAssertEqual(e.update(world([TourSurface(id: 1, focused: true, frame: left), TourSurface(id: 2, frame: right)])), 1)
        XCTAssertTrue(e.isStepDone)
    }

    func testFocusStepPointsTowardTheNeighbor() {
        let e = engine(at: "focus", world([TourSurface(id: 1, focused: true, frame: left), TourSurface(id: 2, frame: right)]))
        XCTAssertTrue(e.step.tasks[0].text.contains("⌘L"))
        XCTAssertTrue(e.step.tasks[0].text.contains("right"))
        XCTAssertTrue(e.step.tasks[1].text.contains("⌘H"))
    }

    /// The events a focus change sends: the dispatch (none for the mouse), then the focus.
    func focus(_ id: UInt64, by name: String? = nil, from source: String = "key") -> [HyprmuxEvent] {
        (name.map { [HyprmuxEvent("dispatch", "\(source),\($0),")] } ?? [])
            + [HyprmuxEvent("activewindow", "terminal,zsh"), HyprmuxEvent("activewindowv2", "\(id)")]
    }

    func testFocusStepWantsTheKeyboard() {
        let here = world([TourSurface(id: 1, focused: true, frame: left), TourSurface(id: 2, frame: right)])
        let there = world([TourSurface(id: 1, frame: left), TourSurface(id: 2, focused: true, frame: right)])
        var e = engine(at: "focus", here)
        // The pointer doesn't count, and the tour says so.
        XCTAssertEqual(e.update(there, events: focus(2)), 0)
        XCTAssertEqual(e.currentTask?.progress?(e.input).map(TourMarkup.plain), "That was the mouse. Come back and try ⌘L.")
        XCTAssertEqual(e.update(here, events: focus(1)), 0)
        XCTAssertEqual(e.update(there, events: focus(2, by: "movefocus")), 1)
        XCTAssertEqual(e.update(here, events: focus(1)), 0, "came back with the mouse")
        XCTAssertNotNil(e.currentTask?.progress?(e.input))
        XCTAssertEqual(e.update(there, events: focus(2, by: "movefocus")), 0)
        XCTAssertEqual(e.update(here, events: focus(1, by: "movefocus")), 1)
        XCTAssertTrue(e.isStepDone)
    }

    func testDwindleOpensFromThePracticeTileThenTeachesTheQuickWayBack() {
        var e = engine(at: "dwindle", world([TourSurface(id: 1, focused: true, frame: left), TourSurface(id: 2, frame: right)]))
        XCTAssertTrue(e.step.tasks[0].text.contains("⌘L"), "points toward the other terminal")
        // Leaving focus without a new tile doesn't count.
        XCTAssertEqual(e.update(world([TourSurface(id: 1, frame: left), TourSurface(id: 2, focused: true, frame: right)])), 0)
        XCTAssertEqual(e.update(world([TourSurface(id: 1, frame: left), TourSurface(id: 2, frame: right),
                                       TourSurface(id: 3, focused: true)])), 1)
        let home = world([TourSurface(id: 1, focused: true, frame: left), TourSurface(id: 2), TourSurface(id: 3)])
        let away = world([TourSurface(id: 1, frame: left), TourSurface(id: 2, focused: true), TourSurface(id: 3)])
        XCTAssertEqual(e.update(home, events: focus(1, by: "movefocus")), 1)
        XCTAssertEqual(e.update(home), 0)
        XCTAssertEqual(e.update(away, events: focus(2, by: "movefocus")), 1)
        XCTAssertEqual(e.update(home, events: focus(1, by: "movefocus")), 0, "⌘H isn't ⌘`")
        XCTAssertEqual(e.update(away, events: focus(2, by: "movefocus")), 0)
        XCTAssertEqual(e.update(home, events: focus(1, by: "focuscurrentorlast")), 1)
        XCTAssertTrue(e.isStepDone)
    }

    func testMoveStepTellsKeysFromTheMouse() {
        let a = world([TourSurface(id: 1, focused: true, frame: left), TourSurface(id: 2, frame: right)])
        let b = world([TourSurface(id: 1, focused: true, frame: right), TourSurface(id: 2, frame: left)])
        var e = engine(at: "move", a)
        XCTAssertEqual(e.update(b, events: [.dispatch(.swapWindow(.right), source: .key)]), 0, "a swap isn't a move")
        XCTAssertEqual(e.update(a, events: [.dispatch(.moveWindow(.left), source: .key)]), 1)
        XCTAssertEqual(e.update(b, events: [.dispatch(.swapWindow(.right), source: .key)]), 1)
        XCTAssertEqual(e.update(a, events: [.dispatch(.moveWindow(.left), source: .key)]), 0, "the keyboard isn't the mouse")
        XCTAssertEqual(e.update(b, events: [.drag(resize: false)]), 1)
        XCTAssertTrue(e.isStepDone)
    }

    func testResizeStepWalksThroughResizeMode() {
        let narrow = TourRect(x: 0, y: 0, width: 400, height: 800)
        let wide = TourRect(x: 0, y: 0, width: 600, height: 800)
        var e = engine(at: "resize", world([TourSurface(id: 1, focused: true, frame: left)]))
        e.update(world([TourSurface(id: 1, focused: true, frame: wide)]), events: [.dispatch(.resizeActive(dx: 40, dy: 0), source: .key)])
        e.update(world([TourSurface(id: 1, focused: true, frame: wide)]), events: [.submap("resize")])
        e.update(world([TourSurface(id: 1, focused: true, frame: narrow)]), events: [.dispatch(.resizeActive(dx: -30, dy: 0), source: .key)])
        XCTAssertEqual(e.taskIndex, 3)
        e.update(world([TourSurface(id: 1, focused: true, frame: narrow)]), events: [.submap("reset")])
        e.update(world([TourSurface(id: 1, focused: true, frame: wide)]), events: [.drag(resize: true)])
        XCTAssertTrue(e.isStepDone)
    }

    func testFloatStepRunsThroughEachState() {
        var e = engine(at: "float", world([TourSurface(id: 1, focused: true)]))
        e.update(world([TourSurface(id: 1, floating: true, focused: true, frame: left)]))
        e.update(world([TourSurface(id: 1, floating: true, focused: true, frame: right)]), events: [.drag(resize: false)])
        e.update(world([TourSurface(id: 1, focused: true)]))
        e.update(world([TourSurface(id: 1, fullscreen: 1, focused: true)]))
        XCTAssertEqual(e.taskIndex, 4)
        e.update(world([TourSurface(id: 1, focused: true)]))
        XCTAssertTrue(e.isStepDone)
    }

    func testGroupStepReturnNeedsTheTourTab() {
        var e = engine(at: "group", world([TourSurface(id: 1, focused: true)]))
        e.update(world([TourSurface(id: 1, focused: true, group: .init(members: [1], active: 1))]))
        e.update(world([TourSurface(id: 1, visible: false, group: .init(members: [1, 2], active: 2)),
                        TourSurface(id: 2, focused: true, group: .init(members: [1, 2], active: 2))]))
        XCTAssertEqual(e.taskIndex, 2)
        XCTAssertEqual(e.wayBack.map(TourMarkup.plain), "Press ⌃Tab to show the tour's tab.")
        e.update(world([TourSurface(id: 1, focused: true, group: .init(members: [1, 2], active: 1)),
                        TourSurface(id: 2, visible: false, group: .init(members: [1, 2], active: 1))]))
        XCTAssertEqual(e.taskIndex, 3)
        e.update(world([TourSurface(id: 1, visible: false, group: .init(members: [1, 2], active: 2)),
                        TourSurface(id: 2, focused: true, group: .init(members: [1, 2], active: 2))]))
        XCTAssertEqual(e.taskIndex, 3, "the other tab is still open")
        e.update(world([TourSurface(id: 1, focused: true, group: .init(members: [1], active: 1))]))
        XCTAssertEqual(e.taskIndex, 4)
        e.update(world([TourSurface(id: 1, focused: true)]))
        XCTAssertTrue(e.isStepDone)
    }

    func testWorkspacesStepPicksAnEmptyWorkspace() {
        let start = world([TourSurface(id: 1, focused: true), TourSurface(id: 9, workspace: "2")])
        var e = engine(at: "workspaces", start, tourSurfaces: [1, 9])
        XCTAssertTrue(e.step.tasks[0].text.contains("⌘3"), "workspace 2 is taken")
        e.update(world([TourSurface(id: 1, visible: false), TourSurface(id: 9, workspace: "2")], active: "3"))
        e.update(world([TourSurface(id: 1, visible: false), TourSurface(id: 9, workspace: "2"),
                        TourSurface(id: 4, workspace: "3", focused: true)], active: "3"))
        XCTAssertEqual(e.taskIndex, 2)
        XCTAssertEqual(e.wayBack.map(TourMarkup.plain), "Press ⌘1 to go back to workspace 1.")
    }

    func testScratchpadWayBack() {
        var e = engine(at: "scratchpad", world([TourSurface(id: 1, focused: true)]))
        e.update(world([TourSurface(id: 1)], scratchpad: true))
        e.update(world([TourSurface(id: 1), TourSurface(id: 3, workspace: "special:magic", focused: true)], scratchpad: true))
        XCTAssertEqual(e.taskIndex, 2)
        e.update(world([TourSurface(id: 1, focused: true), TourSurface(id: 3, workspace: "special:magic", visible: false)]))
        XCTAssertTrue(e.isStepDone, "hiding the scratchpad lands back on the tour")
    }

    func testCleanupCountsPracticeTilesEverywhere() {
        let surfaces = [
            TourSurface(id: 1, focused: true), TourSurface(id: 7), // 7 was there before the tour
            TourSurface(id: 2), TourSurface(id: 3, workspace: "3"), TourSurface(id: 4, workspace: "special:magic"),
        ]
        var e = engine(at: "cleanup", world(surfaces), tourSurfaces: [1, 7])
        XCTAssertEqual(e.currentTask?.progress?(e.input), "3 left: 1 here, 1 on workspace 3, 1 in the scratchpad")
        e.update(world([TourSurface(id: 1, focused: true), TourSurface(id: 7)]))
        XCTAssertTrue(e.isStepDone)
    }

    func testConfigStepWaitsForAReloadAndHyprmuxInFront() {
        var start = world([TourSurface(id: 1, focused: true)])
        start.appActive = true
        var e = engine(at: "config", start)
        XCTAssertTrue(e.step.tasks[0].text.contains("gaps_in = 5"))
        XCTAssertTrue(e.step.tasks[0].text.contains("gaps_in = 20"))
        var away = start
        away.appActive = false
        XCTAssertEqual(e.update(away, events: [.appActive(false)]), 0)
        e.update(away, events: [.configReloaded])
        XCTAssertEqual(e.taskIndex, 1, "focus is still on the tour, but Hyprmux isn't in front")
        XCTAssertEqual(e.wayBack.map(TourMarkup.plain), "Switch back to Hyprmux with ⌘Tab.")
        e.update(start, events: [.appActive(true)])
        XCTAssertTrue(e.isStepDone)
    }

    func testWayBackPrefersTheDirectionToTheTour() {
        let w = world([TourSurface(id: 1, frame: left), TourSurface(id: 2, focused: true, frame: right)])
        XCTAssertEqual(TourWayBack.hint(w, tutor: 1, keys: keys, followsMouse: true).map(TourMarkup.plain),
                       "Press ⌘H or ⌘`.")
        let focused = world([TourSurface(id: 1, focused: true)])
        XCTAssertNil(TourWayBack.hint(focused, tutor: 1, keys: keys, followsMouse: true))
    }

    func testEveryStepBuilds() {
        let w = world([TourSurface(id: 1, focused: true)])
        for i in 0..<Curriculum.count {
            let step = Curriculum.step(i, TourContext(config: config, configPath: "/tmp/x.conf", world: w, tutor: 1,
                                                      tourSurfaces: [1]))
            XCTAssertEqual(step.id, Curriculum.ids[i])
            XCTAssertFalse(step.title.isEmpty)
            for task in step.tasks { XCTAssertFalse(task.text.contains("unbound"), "\(step.id): \(task.text)") }
        }
    }
}

extension TourTests {
    func testWayBackOnlySuggestsWhatWasTaught() {
        let w = world([TourSurface(id: 1, frame: left), TourSurface(id: 2, focused: true, frame: right)])
        func hint(_ step: String) -> String? {
            TourWayBack.hint(w, tutor: 1, keys: keys, followsMouse: true, step: Curriculum.index(step)).map(TourMarkup.plain)
        }
        XCTAssertEqual(hint("open"), "Point at the tour tile.")
        XCTAssertEqual(hint("focus"), "Press ⌘H.")
        XCTAssertEqual(hint("dwindle"), "Press ⌘H.", "⌘` is still being taught")
        XCTAssertEqual(hint("move"), "Press ⌘H or ⌘`.")
        // Another workspace has one way back, taught or not.
        let away = world([TourSurface(id: 1, visible: false), TourSurface(id: 2, workspace: "2", focused: true)], active: "2")
        XCTAssertEqual(TourWayBack.hint(away, tutor: 1, keys: keys, followsMouse: true, step: 1).map(TourMarkup.plain),
                       "Press ⌘1 to go back to workspace 1.")
    }
}

extension TourTests {
    func testQuickWayBackOnlyWhenTheTourWasTheLastTile() {
        let three: (UInt64) -> TourWorld = { f in
            self.world([TourSurface(id: 1, focused: f == 1, frame: self.left), TourSurface(id: 2, focused: f == 2, frame: self.right),
                        TourSurface(id: 3, focused: f == 3, frame: self.right)])
        }
        var w = engine(at: "web", three(1))
        w.update(three(1))
        // Open a web tile from the tour, load a page: focus 1 → 4.
        var withWeb = three(4)
        withWeb.surfaces.append(TourSurface(id: 4, focused: true, frame: right, kind: "web", url: "https://hyprland.org/"))
        w.update(withWeb)
        XCTAssertEqual(w.taskIndex, 2)
        XCTAssertEqual(w.wayBack.map(TourMarkup.plain), "Press ⌘H or ⌘`.")
        // Through another tile first: ⌘` would land there, not on the tour.
        var viaTwo = withWeb
        viaTwo.surfaces = viaTwo.surfaces.map { var s = $0; s.focused = s.id == 2; return s }
        w.update(viaTwo)
        var backOnWeb = withWeb
        backOnWeb.surfaces = backOnWeb.surfaces.map { var s = $0; s.focused = s.id == 4; return s }
        w.update(backOnWeb)
        XCTAssertEqual(w.wayBack.map(TourMarkup.plain), "Press ⌘H.")
    }
}
