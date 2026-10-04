import Foundation
import HyprmuxCore

/// The tour's steps. Each lesson ends by coming back to the tour tile, and every way
/// back uses something an earlier step taught: the mouse, then ⌘H/J/K/L, ⌘`, ⌃Tab,
/// ⌘1…9, ⌘S, and finally ⌘Tab.
public enum Curriculum {
    public static let ids = [
        "welcome", "open", "focus", "dwindle", "move", "resize", "float", "web", "group",
        "workspaces", "send", "scratchpad", "cleanup", "config", "finish",
    ]

    public static var count: Int { ids.count }

    public static func index(_ id: String) -> Int { ids.firstIndex(of: id) ?? count }

    /// Steps numbered "3 of 13" in the header: everything but the welcome and the end.
    public static func number(_ index: Int) -> (Int, Int)? {
        guard index > 0, index < count - 1 else { return nil }
        return (index, count - 2)
    }

    public static func step(_ index: Int, _ c: TourContext) -> TourStep {
        switch ids[max(0, min(index, count - 1))] {
        case "welcome": welcome(c)
        case "open": open(c)
        case "focus": focus(c)
        case "dwindle": dwindle(c)
        case "move": move(c)
        case "resize": resize(c)
        case "float": float(c)
        case "web": web(c)
        case "group": group(c)
        case "workspaces": workspaces(c)
        case "send": send(c)
        case "scratchpad": scratchpad(c)
        case "cleanup": cleanup(c)
        case "config": config(c)
        default: finish(c)
        }
    }

    private static func key(_ chord: String?, _ action: String) -> String { TourMarkup.key(chord, unbound: action) }

    // MARK: Steps

    static func welcome(_ c: TourContext) -> TourStep {
        TourStep(id: "welcome", title: "Welcome to Hyprmux", body: [
            "Hyprmux tiles terminals, web pages, and devices inside one window, the way Hyprland tiles windows on Linux.",
            "This tour takes about five minutes. You do every step yourself, with the real keys from your config.",
            "\(key("⌘", "")) is the main modifier. Keys are physical positions, so they work with any keyboard layout. \(key("⌘C", "")) and \(key("⌘V", "")) still copy and paste.",
            "This tile is the tour. You'll leave it often, and each step teaches a new way to come back.",
        ])
    }

    static func open(_ c: TourContext) -> TourStep {
        let back = c.followsMouse
            ? "Come back: point at this tile. Focus follows the mouse, so it's enough to move the pointer here."
            : "Come back: click this tile."
        return TourStep(id: "open", title: "Open a terminal", body: [
            "Every tile is a window. You never place them: a new tile splits the focused one in half.",
        ], tasks: [
            TourTask("Press \(key(c.keys.newTerminal, "exec")) to open a terminal. Focus moves to it.") { i in
                !i.newSinceMark.isEmpty && !i.tutorFocused
            },
            .back(back),
        ])
    }

    static func focus(_ c: TourContext) -> TourStep {
        let t = c.tutorSurface
        let neighbor = c.world.surfaces.first { $0.id != c.tutor && $0.workspace == t?.workspace && $0.visible }
        let d = t.flatMap { t in neighbor.map { TourGeometry.direction(from: t.frame, to: $0.frame) } }
        let go = d.flatMap { c.keys.focus($0) }.map { key($0, "") } ?? key(c.keys.focusAll, "movefocus")
        let back = d.flatMap { c.keys.focus(TourGeometry.opposite($0)) }.map { key($0, "") } ?? key(c.keys.focusAll, "movefocus")
        let target = d.map { "the tile on the \(TourGeometry.word($0))" } ?? "another tile"
        return TourStep(id: "focus", title: "Move focus with the keyboard", body: [
            "The mouse works, but the keyboard is faster. \(key(c.keys.focusAll, "movefocus")) moves focus left, down, up, or right, like h, j, k, and l in Vim. ⌘ with the arrow keys works too.",
        ], tasks: [
            TourTask("Press \(go) to move focus to \(target).", progress: { i in
                guard let f = i.world.focused, f.id != i.tutor else { return nil }
                return i.focusArrived(at: f.id, by: ["movefocus"]) ? nil : "That was the mouse. Come back and try \(go)."
            }) { i in
                guard let f = i.world.focused, f.id != i.tutor, f.workspace == i.tutorSurface?.workspace else { return false }
                return i.focusArrived(at: f.id, by: ["movefocus"])
            },
            TourTask("Come back with \(back). Leave the mouse alone for this one.", isReturn: true, progress: { i in
                i.tutorFocused ? "That was the mouse. Leave with \(go), then come back with \(back)." : nil
            }) { i in
                i.tutorFocused && i.focusArrived(at: i.tutor, by: ["movefocus"])
            },
        ], notes: c.followsMouse ? [
            "Focus follows the mouse. If focus jumps while you type, the pointer moved over another tile.",
        ] : [])
    }

    static func dwindle(_ c: TourContext) -> TourStep {
        let last = key(c.keys.last, "focuscurrentorlast")
        let t = c.tutorSurface
        let neighbor = c.world.surfaces.first { $0.id != c.tutor && $0.workspace == t?.workspace && $0.visible }
        let toward = t.flatMap { t in neighbor.map { TourGeometry.direction(from: t.frame, to: $0.frame) } }
        let go = toward.flatMap { c.keys.focus($0) }.map { key($0, "") } ?? key(c.keys.focusAll, "movefocus")
        let all = key(c.keys.focusAll, "movefocus")
        return TourStep(id: "dwindle", title: "More tiles", body: [
            "A new tile splits the focused one along its longer side, so tiles keep a sensible shape. Hyprland calls this layout dwindle.",
        ], tasks: [
            TourTask("Go to the other terminal with \(go) and press \(key(c.keys.newTerminal, "exec")) there. The new tile splits that one, so this tile keeps its size.") { i in
                !i.newSinceMark.isEmpty && !i.tutorFocused
            },
            TourTask("Come back with \(all).", isReturn: true, progress: { i in
                i.tutorFocused ? "That was the mouse. Leave again and come back with \(all)." : nil
            }) { i in
                i.tutorFocused && i.focusArrived(at: i.tutor, by: ["movefocus"])
            },
            TourTask("Now a faster way back. Leave this tile again with \(go).") { i in
                !i.tutorFocused && i.world.focused?.workspace == i.tutorSurface?.workspace
            },
            TourTask("Press \(last). It jumps back to the tile you were on before.", isReturn: true, progress: { i in
                i.tutorFocused ? "That wasn't \(last). Leave again with \(go) and press \(last)." : nil
            }) { i in
                i.tutorFocused && i.focusArrived(at: i.tutor, by: ["focuscurrentorlast"])
            },
        ], notes: [
            "\(last) works from anywhere, even from another workspace. It's the quickest way back.",
        ])
    }

    static func move(_ c: TourContext) -> TourStep {
        func moved(by name: String, from source: String) -> @Sendable (TaskInput) -> Bool {
            { i in i.dispatched(name, from: source) && i.tutorMoved }
        }
        return TourStep(id: "move", title: "Move the tour tile", body: [
            "Focus stays here for this step. You move the tour tile itself.",
        ], tasks: [
            TourTask("Press \(key(c.keys.moveAll, "movewindow")) to move this tile. Try a few directions.",
                     check: moved(by: "movewindow", from: "key")),
            TourTask("Press \(key(c.keys.swapAll, "swapwindow")) to swap it with a neighbor.",
                     check: moved(by: "swapwindow", from: "key")),
            TourTask("Now the mouse: hold ⌘, drag this tile onto another one, and let go. It takes that spot.",
                     check: moved(by: "movewindow", from: "mouse")),
        ])
    }

    static func resize(_ c: TourContext) -> TourStep {
        func resized(by name: String, from source: String) -> @Sendable (TaskInput) -> Bool {
            { i in i.dispatched(name, from: source) && i.tutorResized }
        }
        return TourStep(id: "resize", title: "Resize", body: [
            "Resizing moves the split between tiles.",
        ], tasks: [
            TourTask("Press \(key(c.keys.resize, "resizeactive")) to make this tile wider or narrower. Hold it down to keep going.",
                     check: resized(by: "resizeactive", from: "key")),
            TourTask("Now resize mode: press \(key(c.keys.resizeMode, "submap")). The bar shows the mode while it's on.") { i in
                i.saw("submap") { !$0.isEmpty }
            },
            TourTask("Press H, J, K, or L a few times. No ⌘ needed in this mode.",
                     check: resized(by: "resizeactive", from: "key")),
            TourTask("Press \(key("Esc", "")) to leave resize mode.") { i in i.saw("submap") { $0.isEmpty } },
            TourTask("And the mouse: hold ⌘ and drag with the right button near an edge of this tile.",
                     check: resized(by: "resizewindow", from: "mouse")),
        ])
    }

    static func float(_ c: TourContext) -> TourStep {
        let float = key(c.keys.float, "togglefloating")
        let max = key(c.keys.maximize, "fullscreen, 1")
        return TourStep(id: "float", title: "Float and maximize", body: [
            "A floating tile sits above the others, and you can put it anywhere. Maximize fills the window but keeps the gaps.",
        ], tasks: [
            TourTask("Press \(float) to float this tile.") { $0.tutorSurface?.floating == true },
            TourTask("Hold ⌘ and drag it somewhere else. A right-drag resizes it.") { i in
                i.tutorSurface?.floating == true && i.dispatched("movewindow", from: "mouse") && i.tutorMoved
            },
            TourTask("Press \(float) again. It goes back to its old spot.") { $0.tutorSurface?.floating == false },
            TourTask("Press \(max) to maximize it.") { $0.tutorSurface?.fullscreen != nil },
            TourTask("Press \(max) again to restore it.") { $0.tutorSurface.map { $0.fullscreen == nil } ?? false },
        ], notes: [
            "\(key(c.keys.fullscreen, "fullscreen, 0")) is true fullscreen, with no gaps or border.",
        ])
    }

    static func web(_ c: TourContext) -> TourStep {
        let started = c.world.ids
        return TourStep(id: "web", title: "A web tile", body: [
            "Web pages are tiles too.",
        ], tasks: [
            TourTask("Press \(key(c.keys.web, "web")). A web tile opens with its address bar ready.") { i in
                i.world.surfaces.contains { $0.kind == "web" && !started.contains($0.id) }
            },
            TourTask("Type an address or a search, like `hyprland.org`, and press Return.") { i in
                i.world.surfaces.contains { s in
                    guard s.kind == "web", !started.contains(s.id), let url = s.url, !url.isEmpty else { return false }
                    return !url.hasPrefix("about:") && !url.hasPrefix("data:")
                }
            },
            .back("Come back with \(key(c.keys.last, "focuscurrentorlast")) or \(key(c.keys.focusAll, "movefocus")). Hyprmux keys work inside web pages too."),
        ], notes: [
            "\(key(c.keys.addressBar, "webnav, focusurl")) puts the cursor in the address bar. ⌘-click a link in a terminal to open it in a web tile.",
        ])
    }

    static func group(_ c: TourContext) -> TourStep {
        let g = key(c.keys.group, "togglegroup")
        let tab = key(c.keys.nextTab, "changegroupactive")
        let join = c.config.wm.autoGroup
            ? "Press \(key(c.keys.newTerminal, "exec")). The new terminal joins the group as a tab, on top of this one."
            : "Your config turns off `group:auto_group`, so new windows don't join groups. Press s to skip this step."
        return TourStep(id: "group", title: "Tabs", body: [
            "A group holds several windows as tabs in one tile. The tab strip at the top shows them.",
        ], tasks: [
            TourTask("Press \(g) to turn this tile into a group.") { $0.tutorSurface?.group != nil },
            TourTask(join) { i in
                guard let gr = i.tutorSurface?.group else { return false }
                return gr.members.count > 1 && gr.active != i.tutor
            },
            TourTask("Come back with \(tab). It switches tabs.", isReturn: true) { i in
                i.tutorFocused && i.tutorSurface?.group?.active == i.tutor
            },
            TourTask("Switch to the other tab with \(tab) and close it with \(key(c.keys.close, "killactive")).") { i in
                (i.tutorSurface?.group?.members.count ?? 1) == 1
            },
            TourTask("Press \(g) to turn the group back into a plain tile.") { $0.tutorSurface.map { $0.group == nil } ?? false },
        ], notes: [
            "Careful: \(key(c.keys.close, "killactive")) on the tour's own tab ends the tour. Run `hyprmux-tour` to pick up again.",
        ])
    }

    /// A workspace number other than the tour's, preferring one that already holds
    /// practice tiles, then an empty one.
    static func otherWorkspace(_ c: TourContext) -> Int {
        let practice = Set(c.world.surfaces.filter { !c.tourSurfaces.contains($0.id) && $0.id != c.tutor }
            .compactMap(\.workspaceNumber))
        if let n = practice.filter({ $0 != c.home }).min() { return n }
        let occupied = c.world.occupiedWorkspaces
        return (1...9).first { $0 != c.home && !occupied.contains($0) } ?? (c.home == 9 ? 8 : c.home + 1)
    }

    static func workspaces(_ c: TourContext) -> TourStep {
        let home = c.home
        let occupied = c.world.occupiedWorkspaces
        let n = (1...9).first { $0 != home && !occupied.contains($0) } ?? (home == 9 ? 8 : home + 1)
        let before = c.world.surfaces(on: "\(n)").count
        return TourStep(id: "workspaces", title: "Workspaces", body: [
            "Workspaces are separate screens of tiles. The pills in the bar show them. The tour lives on workspace \(home).",
        ], tasks: [
            TourTask("Press \(key(c.keys.workspace(n), "workspace, \(n)")) to go to workspace \(n). The tour slides away, so read the next two lines first.") {
                $0.world.activeWorkspace == n
            },
            TourTask("Open a terminal there with \(key(c.keys.newTerminal, "exec")).") { $0.world.surfaces(on: "\(n)").count > before },
            .back("Come back with \(key(c.keys.workspace(home), "workspace, \(home)"))."),
        ], notes: [
            "Clicking a pill in the bar works too.",
        ])
    }

    static func send(_ c: TourContext) -> TourStep {
        let home = c.home
        let n = otherWorkspace(c)
        return TourStep(id: "send", title: "Send a tile to another workspace", body: [
            "\(key(c.keys.moveToWorkspace(n), "movetoworkspace, \(n)")) sends the focused tile to workspace \(n), and you go with it.",
        ], tasks: [
            TourTask("Go to one of the practice terminals here, any way you like.") { i in
                !i.tutorFocused && i.world.focused?.workspace == i.tutorSurface?.workspace
            },
            TourTask("Press \(key(c.keys.moveToWorkspace(n), "movetoworkspace, \(n)")) to send it to workspace \(n).") { i in
                guard let sent = i.mark.focused, sent.id != i.tutor, let now = i.world.surface(sent.id) else { return false }
                return now.workspace != i.tutorSurface?.workspace
            },
            .back("Come back with \(key(c.keys.workspace(home), "workspace, \(home)")). If you land on another tile, use \(key(c.keys.last, "focuscurrentorlast")) or \(key(c.keys.focusAll, "movefocus"))."),
        ], notes: [
            "\(key(c.keys.workspacePicker, "picker, workspace")) lists workspaces: type a number or a name and press Return. \(key(c.keys.renameWorkspace, "picker, renameworkspace")) names the current one.",
        ])
    }

    static func scratchpad(_ c: TourContext) -> TourStep {
        let s = key(c.keys.scratchpad, "togglespecialworkspace")
        let before = c.world.surfaces.filter(\.inScratchpad).count
        let sendKey = c.keys.chord {
            if case .moveToWorkspace(.special(_), _) = $0 { return true }
            return false
        }
        return TourStep(id: "scratchpad", title: "The scratchpad", body: [
            "The scratchpad is a hidden workspace that slides in over the current one. It's a good home for a quick shell.",
        ], tasks: [
            TourTask("Press \(s) to show it.") { $0.world.scratchpadVisible },
            TourTask("Open a terminal in it with \(key(c.keys.newTerminal, "exec")).") { i in
                i.world.surfaces.filter(\.inScratchpad).count > before
            },
            TourTask("Press \(s) again to hide it.") { !$0.world.scratchpadVisible },
            .back("Come back here, if focus didn't land on the tour."),
        ], notes: sendKey.map { ["\(key($0, "")) moves the focused tile into the scratchpad."] } ?? [])
    }

    /// Where the practice tiles are: "2 here, 1 on workspace 3, 1 in the scratchpad".
    @Sendable static func whereabouts(_ i: TaskInput) -> String? {
        let practice = i.practice
        guard !practice.isEmpty else { return nil }
        let home = i.tutorSurface?.workspace
        var parts: [String] = []
        let here = practice.filter { $0.workspace == home }.count
        if here > 0 { parts.append("\(here) here") }
        let others = Dictionary(grouping: practice.compactMap { $0.workspace == home ? nil : $0.workspaceNumber }, by: { $0 })
        for n in others.keys.sorted() { parts.append("\(others[n]!.count) on workspace \(n)") }
        let scratch = practice.filter(\.inScratchpad).count
        if scratch > 0 { parts.append("\(scratch) in the scratchpad") }
        return "\(practice.count) left: " + parts.joined(separator: ", ")
    }

    static func cleanup(_ c: TourContext) -> TourStep {
        TourStep(id: "cleanup", title: "Clean up", body: [
            "\(key(c.keys.close, "killactive")) closes the focused tile. Close every tile you opened during the tour. Some sit on other workspaces and in the scratchpad: use what you learned to reach them.",
        ], tasks: [
            TourTask("Close the practice tiles with \(key(c.keys.close, "killactive")).", progress: whereabouts) { $0.practice.isEmpty },
            .back("Come back here."),
        ], notes: [
            "Careful: \(key(c.keys.close, "killactive")) on this tile ends the tour. Run `hyprmux-tour` to pick up where you left off.",
        ])
    }

    static func number(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }

    static func config(_ c: TourContext) -> TourStep {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = c.configPath.hasPrefix(home + "/") ? "~" + c.configPath.dropFirst(home.count) : c.configPath
        let gaps = c.config.wm.gapsIn.top
        let suggested: Double = gaps >= 15 ? 5 : 20
        return TourStep(id: "config", title: "Make it yours", body: [
            "Everything is set in `\(path)`. Hyprmux reloads it each time you save.",
            "Open it with \(key("⌘,", "")) in your default editor, or run `$EDITOR \(path)` in a new terminal.",
        ], tasks: [
            TourTask("Change `gaps_in = \(number(gaps))` to `gaps_in = \(number(suggested))` and save. The gaps between tiles change at once.") { i in
                i.saw("configreloaded")
            },
            TourTask("Come back here: \(key("⌘Tab", "")) from another app, or \(key(c.keys.last, "focuscurrentorlast")) from a terminal.", isReturn: true) { i in
                i.tutorFocused && i.world.appActive != false
            },
        ], notes: [
            "Every option in that file has a comment. If a line is wrong, Hyprmux shows the error in a notice and keeps the rest.",
        ])
    }

    static func finish(_ c: TourContext) -> TourStep {
        let k = c.keys
        var more: [String] = []
        if let d = k.device { more.append("• \(key(d, "")) shows a booted iOS Simulator or a running Android emulator in a tile.") }
        if let a = k.apps { more.append("• \(key(a, "")) opens apps such as VS Code and Cursor in a tile.") }
        if let s = k.saveLayout, let l = k.layout {
            more.append("• \(key(s, "")) saves this workspace as a layout, and \(key(l, "")) brings it back.")
        }
        more.append("• `hyprmuxctl` lets scripts and coding agents drive Hyprmux.")
        var ways: [String] = [c.followsMouse ? "the mouse" : "a click"]
        for chord in [k.focusAll, k.last, k.nextTab] { if let chord { ways.append(key(chord, "")) } }
        if let one = k.workspace(1), let nine = k.workspace(9) { ways.append("\(key(one, ""))…\(key(nine, ""))") }
        if let s = k.scratchpad { ways.append(key(s, "")) }
        ways.append("and \(key("⌘Tab", "")) from other apps")
        return TourStep(id: "finish", title: "You're set", body: [
            "Ways back to any tile: " + ways.joined(separator: ", ") + ".",
            "More to try:",
        ] + more + [
            "Run `hyprmux-tour --restart` to take the tour again.",
        ])
    }
}
