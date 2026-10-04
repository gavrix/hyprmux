import Foundation

// Events: what changed in Hyprmux, one line each, like Hyprland's socket2.
// `hyprmuxctl events` streams them, and hooks (Hooks.swift) run commands on them.
// See docs/HOOKS.md for the list.

/// What caused a dispatch: a bind, a mouse drag or the bar, the control socket, a
/// picker, or Hyprmux itself (a terminal's split request, a layout).
public enum EventSource: String, Sendable, CaseIterable {
    case key, mouse, ipc, picker, app
}

/// One event. On the wire it's `NAME>>DATA`, Hyprland's format.
public struct HyprmuxEvent: Equatable, Sendable, CustomStringConvertible {
    public var name: String
    public var data: String

    public init(_ name: String, _ data: String = "") {
        self.name = name
        self.data = data
    }

    public var line: String { "\(name)>>\(data)" }
    public var description: String { line }

    public static func parse(_ line: String) -> HyprmuxEvent? {
        guard let r = line.range(of: ">>") else { return nil }
        let name = String(line[..<r.lowerBound])
        guard !name.isEmpty, !name.contains(" ") else { return nil }
        return HyprmuxEvent(name, String(line[r.upperBound...]))
    }

    /// Fields split on commas. `count` caps the split so a last field (a title) keeps
    /// its own commas.
    public func fields(_ count: Int) -> [String] {
        data.split(separator: ",", maxSplits: max(0, count - 1), omittingEmptySubsequences: false).map(String.init)
    }

    // MARK: Hyprmux's own events

    /// `dispatch>>SOURCE,NAME,ARGS`, sent before the dispatcher runs.
    public static func dispatch(_ d: Dispatcher, source: EventSource) -> HyprmuxEvent {
        let c = d.command
        return HyprmuxEvent("dispatch", "\(source.rawValue),\(c.name),\(c.args)")
    }

    /// A mouse drag that moved or resized a window (`bindm`): `dispatch>>mouse,movewindow,`.
    public static func drag(resize: Bool) -> HyprmuxEvent {
        HyprmuxEvent("dispatch", "mouse,\(resize ? "resizewindow" : "movewindow"),")
    }

    /// For a `dispatch` event: its source, dispatcher name, and arguments.
    public var dispatched: (source: String, name: String, args: String)? {
        guard name == "dispatch" else { return nil }
        let f = fields(3)
        guard f.count == 3 else { return nil }
        return (f[0], f[1], f[2])
    }

    public static func appActive(_ active: Bool) -> HyprmuxEvent { HyprmuxEvent("appactive", active ? "1" : "0") }
    /// Empty for the default submap, like Hyprland.
    public static func submap(_ name: String) -> HyprmuxEvent { HyprmuxEvent("submap", name == "reset" ? "" : name) }
    public static let configReloaded = HyprmuxEvent("configreloaded")
    /// Every launch, after the session is restored or the startup programs run.
    public static let launch = HyprmuxEvent("launch")
    /// The first launch: Hyprmux wrote a new config file. Comes before `launch`.
    public static let firstLaunch = HyprmuxEvent("firstlaunch")

    public static func windowTitle(_ id: ClientID, _ title: String) -> [HyprmuxEvent] {
        [HyprmuxEvent("windowtitle", "\(id.raw)"), HyprmuxEvent("windowtitlev2", "\(id.raw),\(title)")]
    }

    /// Lifecycle events: emitted once, while Hyprmux starts.
    public static let lifecycle: Set<String> = ["launch", "firstlaunch"]

    /// Every event name Hyprmux emits.
    public static let names: Set<String> = [
        "workspace", "workspacev2", "createworkspace", "destroyworkspace", "renameworkspace", "activespecial",
        "openwindow", "closewindow", "movewindow", "activewindow", "activewindowv2", "windowtitle", "windowtitlev2",
        "changefloatingmode", "fullscreen", "togglegroup", "moveintogroup", "moveoutofgroup",
        "submap", "configreloaded", "dispatch", "appactive", "launch", "firstlaunch",
    ]
}

/// The events between two snapshots: windows opening, closing, moving between
/// workspaces, focus, floating, fullscreen, groups, and workspace changes.
public enum EventDiff {
    /// What the model doesn't know about a window.
    public struct Tile: Equatable, Sendable {
        public var kind: String
        public var title: String

        public init(kind: String, title: String) {
            self.kind = kind
            self.title = title
        }
    }

    /// Hyprmux has one monitor; Hyprland events that name one use this.
    public static let monitor = "hyprmux"

    public static func events(from old: Snapshot?, to new: Snapshot, tile: (ClientID) -> Tile) -> [HyprmuxEvent] {
        guard let old else { return [] }
        var out: [HyprmuxEvent] = []
        func name(_ n: Int, _ s: Snapshot) -> String { s.workspaceNames[n] ?? "\(n)" }

        let oldWS = Set(old.workspaces), newWS = Set(new.workspaces)
        for n in new.workspaces where !oldWS.contains(n) { out.append(HyprmuxEvent("createworkspace", "\(n)")) }

        let oldIDs = Set(old.placements.map(\.id))
        let newIDs = Set(new.placements.map(\.id))
        for p in new.placements where !oldIDs.contains(p.id) {
            let t = tile(p.id)
            out.append(HyprmuxEvent("openwindow", "\(p.id.raw),\(p.workspace),\(t.kind),\(t.title)"))
        }
        for p in new.placements {
            guard let o = old.placement(p.id) else { continue }
            if o.workspace != p.workspace { out.append(HyprmuxEvent("movewindow", "\(p.id.raw),\(p.workspace)")) }
            if o.floating != p.floating {
                out.append(HyprmuxEvent("changefloatingmode", "\(p.id.raw),\(p.floating ? 1 : 0)"))
            }
            if (o.fullscreen == nil) != (p.fullscreen == nil) {
                out.append(HyprmuxEvent("fullscreen", p.fullscreen == nil ? "0" : "1"))
            }
        }
        for p in old.placements where !newIDs.contains(p.id) {
            out.append(HyprmuxEvent("closewindow", "\(p.id.raw)"))
        }

        // Groups, by id: made, dissolved, and members joining or leaving.
        func groups(_ s: Snapshot) -> [GroupID: [ClientID]] {
            var g: [GroupID: [ClientID]] = [:]
            for p in s.placements { if let info = p.group { g[info.id] = info.members } }
            return g
        }
        let oldGroups = groups(old), newGroups = groups(new)
        func list(_ ids: [ClientID]) -> String { ids.map { "\($0.raw)" }.joined(separator: ",") }
        for (id, members) in newGroups.sorted(by: { $0.key.raw < $1.key.raw }) {
            guard let before = oldGroups[id] else {
                out.append(HyprmuxEvent("togglegroup", "1,\(list(members))"))
                continue
            }
            for m in members where !before.contains(m) { out.append(HyprmuxEvent("moveintogroup", "\(m.raw)")) }
            for m in before where !members.contains(m) && newIDs.contains(m) {
                out.append(HyprmuxEvent("moveoutofgroup", "\(m.raw)"))
            }
        }
        for (id, members) in oldGroups.sorted(by: { $0.key.raw < $1.key.raw }) where newGroups[id] == nil {
            out.append(HyprmuxEvent("togglegroup", "0,\(list(members))"))
        }

        for n in new.workspaces where oldWS.contains(n) {
            let before = old.workspaceNames[n], after = new.workspaceNames[n]
            if before != after { out.append(HyprmuxEvent("renameworkspace", "\(n),\(after ?? "\(n)")")) }
        }
        if old.activeWorkspace != new.activeWorkspace {
            out.append(HyprmuxEvent("workspace", "\(new.activeWorkspace)"))
            out.append(HyprmuxEvent("workspacev2", "\(new.activeWorkspace),\(name(new.activeWorkspace, new))"))
        }
        if old.specialVisible != new.specialVisible {
            let ws = new.specialVisible.map { WorkspaceID.special($0).description } ?? ""
            out.append(HyprmuxEvent("activespecial", "\(ws),\(monitor)"))
        }
        for n in old.workspaces where !newWS.contains(n) { out.append(HyprmuxEvent("destroyworkspace", "\(n)")) }

        if old.focused != new.focused {
            if let f = new.focused {
                let t = tile(f)
                out.append(HyprmuxEvent("activewindow", "\(t.kind),\(t.title)"))
                out.append(HyprmuxEvent("activewindowv2", "\(f.raw)"))
            } else {
                out.append(HyprmuxEvent("activewindow", ","))
                out.append(HyprmuxEvent("activewindowv2", ""))
            }
        }
        return out
    }
}
