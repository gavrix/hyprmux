import CoreGraphics

/// Hyprland-style groups: several clients stacked as tabs in one slot.
///
/// The slot (a dwindle leaf, or an entry in the floating list) always holds the
/// group's active member. Other members are "hidden": still managed and on the
/// same workspace, but not in the tree. Switching tabs swaps which client sits
/// in the slot, so the layout code never has to know about groups.
public struct GroupID: Hashable, Comparable, Sendable {
    public let raw: UInt64
    public static func < (a: GroupID, b: GroupID) -> Bool { a.raw < b.raw }
}

/// Group details for a placement (both the active member and hidden ones).
public struct GroupInfo: Equatable, Sendable {
    public let id: GroupID
    /// Tab order.
    public let members: [ClientID]
    public let active: ClientID
}

public enum GroupStep: Equatable, Sendable {
    case next, previous
    case index(Int)  // 1-based, like Hyprland
}

final class Group {
    var members: [ClientID]
    var active: ClientID
    init(_ c: ClientID) { members = [c]; active = c }
}

extension WindowManager {
    func group(of id: ClientID) -> Group? {
        clients[id]?.group.flatMap { groups[$0] }
    }

    func groupInfo(of id: ClientID) -> GroupInfo? {
        guard let gid = clients[id]?.group, let g = groups[gid] else { return nil }
        return GroupInfo(id: gid, members: g.members, active: g.active)
    }

    /// A group member that isn't the one shown.
    func isHiddenMember(_ id: ClientID) -> Bool {
        guard let g = group(of: id) else { return false }
        return g.active != id
    }

    /// Puts `new` into `old`'s slot: tree leaf, floating entry, fullscreen.
    func replaceInSlot(_ old: ClientID, with new: ClientID, in ws: Workspace) {
        if ws.tiled.contains(old) {
            ws.tiled.replaceClient(old, with: new)
        } else if let i = ws.floating.firstIndex(of: old) {
            ws.floating[i] = new
            let rect = clients[old]?.floatRect
            clients[new]?.floatRect = rect
        }
        if ws.fullscreen?.id == old { ws.fullscreen = (new, ws.fullscreen!.mode) }
        if ws.lastFocused == old { ws.lastFocused = new }
    }

    /// Shows a hidden member in its group's slot.
    func activate(_ id: ClientID) {
        guard let g = group(of: id), g.active != id,
              let ws = clients[id].flatMap({ workspaces[$0.workspace] }) else { return }
        replaceInSlot(g.active, with: id, in: ws)
        g.active = id
    }

    /// Takes a client out of its group. If it was shown, the next member takes the slot.
    /// Returns the member now shown in the slot (nil if the group is gone).
    @discardableResult
    func leaveGroup(_ id: ClientID) -> ClientID? {
        guard let gid = clients[id]?.group, let g = groups[gid],
              let ws = clients[id].flatMap({ workspaces[$0.workspace] }) else { return nil }
        let i = g.members.firstIndex(of: id)!
        g.members.remove(at: i)
        clients[id]!.group = nil
        if g.members.isEmpty {
            groups[gid] = nil
            return nil
        }
        if g.active == id {
            let next = g.members[min(i, g.members.count - 1)]
            replaceInSlot(id, with: next, in: ws)
            g.active = next
        }
        return g.active
    }

    // MARK: Dispatchers

    /// Makes the focused window a one-tab group, or dissolves its group into separate windows.
    func toggleGroup() {
        guard let (f, ws, st) = focusedContext() else { return }
        if let gid = st.group, let g = groups[gid] {
            let hidden = g.members.filter { $0 != g.active }
            for m in g.members { clients[m]!.group = nil }
            groups[gid] = nil
            for m in hidden {
                if st.floating {
                    var r = clients[f]?.floatRect ?? defaultFloatRect()
                    r = r.offsetBy(dx: 30, dy: 30)
                    clients[m]!.floatRect = r
                    ws.floating.append(m)
                } else {
                    ws.tiled.insert(m, target: f, focalPoint: nil, area: tileArea)
                }
            }
        } else {
            let gid = GroupID(raw: nextGroupID)
            nextGroupID += 1
            groups[gid] = Group(f)
            clients[f]!.group = gid
        }
    }

    func changeGroupActive(_ step: GroupStep) {
        guard let f = focused, let g = group(of: f), g.members.count > 1 else { return }
        let i = g.members.firstIndex(of: g.active)!
        let j: Int
        switch step {
        case .next: j = (i + 1) % g.members.count
        case .previous: j = (i - 1 + g.members.count) % g.members.count
        case .index(let n): j = min(max(n - 1, 0), g.members.count - 1)
        }
        focus(g.members[j])  // focus() activates hidden members
    }

    /// Moves the focused window into the group (or plain window, which becomes a
    /// group) next to it in `dir`.
    func moveIntoGroup(_ dir: Direction) {
        guard let (f, ws, _) = focusedContext() else { return }
        let all = frames(in: ws)
        guard let from = all[f] else { return }
        let others = all.filter { $0.key != f && group(of: $0.key).map { !$0.members.contains(f) } ?? true }
        guard let n = DirectionalSearch.neighbor(of: from, direction: dir,
                                                 candidates: others.map { ($0.key, $0.value) }, recency: recency)
        else { return }
        // Target group: the neighbor's, or a new one around the neighbor.
        let gid: GroupID
        if let existing = clients[n]?.group {
            gid = existing
        } else {
            gid = GroupID(raw: nextGroupID)
            nextGroupID += 1
            groups[gid] = Group(n)
            clients[n]!.group = gid
        }
        // Take f out of wherever it is.
        if clients[f]?.group != nil { leaveGroup(f) }
        if ws.tiled.contains(f) || ws.floating.contains(f) { detach(f, from: ws) }
        // Join after the active tab and show it.
        let g = groups[gid]!
        let at = g.members.firstIndex(of: g.active)! + 1
        g.members.insert(f, at: at)
        clients[f]!.group = gid
        clients[f]!.floating = clients[n]!.floating
        replaceInSlot(g.active, with: f, in: ws)
        g.active = f
        focus(f)
    }

    /// Takes the focused window out of its group into a window of its own, next to the group.
    func moveOutOfGroup() {
        guard let (f, ws, st) = focusedContext(), let g = group(of: f), g.members.count > 1 else { return }
        let slotRect = clients[f]?.floatRect
        guard let shown = leaveGroup(f) else { return }
        if st.floating {
            clients[f]!.floatRect = (slotRect ?? defaultFloatRect()).offsetBy(dx: 30, dy: 30)
            ws.floating.append(f)
        } else {
            ws.tiled.insert(f, target: shown, focalPoint: nil, area: tileArea)
        }
        focus(f)
    }

    /// Moves the active tab left/right in the tab order.
    func moveGroupWindow(forward: Bool) {
        guard let f = focused, let g = group(of: f), let i = g.members.firstIndex(of: f) else { return }
        let j = forward ? i + 1 : i - 1
        guard j >= 0, j < g.members.count else { return }
        g.members.swapAt(i, j)
    }
}
