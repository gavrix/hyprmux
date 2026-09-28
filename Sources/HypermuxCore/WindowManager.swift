import CoreGraphics

public enum WorkspaceID: Hashable, Sendable, CustomStringConvertible {
    case regular(Int)
    case special(String)

    public var description: String {
        switch self {
        case .regular(let n): return "\(n)"
        case .special(let s): return "special:\(s)"
        }
    }
}

public struct WMSettings: Equatable, Sendable {
    public var gapsIn = Insets(all: 5)
    public var gapsOut = Insets(all: 20)
    public var borderSize: Double = 2
    public var dwindle = DwindleSettings()
    public var workspaceBackAndForth = false
    /// Size of a new floating window relative to the work area.
    public var floatSizeFraction: Double = 0.6
    public init() {}
}

/// Side effects the host must perform. The model never touches AppKit.
public enum Effect: Equatable, Sendable {
    case spawn(command: String)
    case spawnWeb(url: String)
    case spawnSim(query: String)
    case simButton(ClientID, String)
    case webNav(ClientID, WebNav)
    case close(ClientID)
    case submap(String)
    case monitorFullscreen
    case reload
    case exit
}

public struct Placement: Equatable, Sendable {
    public let id: ClientID
    public let workspace: WorkspaceID
    /// Outer frame including the border, top-left origin, monitor coordinates.
    public let frame: CGRect
    public let visible: Bool
    public let focused: Bool
    public let floating: Bool
    public let fullscreen: FullscreenMode?
    public let z: Int
}

public struct Snapshot: Equatable, Sendable {
    public let placements: [Placement]
    public let activeWorkspace: Int
    public let specialVisible: String?
    /// Regular workspaces that have clients, plus the active one. Sorted.
    public let workspaces: [Int]
    public let focused: ClientID?

    public func placement(_ id: ClientID) -> Placement? { placements.first { $0.id == id } }
}

/// The window manager model: workspaces, layouts, focus, dispatchers.
public final class WindowManager {
    final class Workspace {
        let id: WorkspaceID
        let tiled: DwindleLayout
        var floating: [ClientID] = []  // bottom → top
        var fullscreen: (id: ClientID, mode: FullscreenMode)?
        var lastFocused: ClientID?

        init(id: WorkspaceID, settings: DwindleSettings) {
            self.id = id
            self.tiled = DwindleLayout(settings: settings)
        }

        var clients: [ClientID] { tiled.clients + floating }
        var isEmpty: Bool { tiled.isEmpty && floating.isEmpty }
    }

    struct ClientState {
        var workspace: WorkspaceID
        var floating: Bool
        var floatRect: CGRect?
        /// Where the client was tiled before it floated, to return there.
        var tiledSlot: DwindleLayout.Slot?
    }

    public var settings: WMSettings {
        didSet { for ws in workspaces.values { ws.tiled.settings = settings.dwindle } }
    }
    /// Whole monitor area (top-left origin).
    public var monitor: CGRect
    /// Space reserved at the edges (title bar, status bar).
    public var reserved: Insets = .zero
    /// Last known pointer position, used as the dwindle focal point.
    public var cursor: CGPoint?
    public var perform: (Effect) -> Void = { _ in }

    public private(set) var activeWorkspace = 1
    public private(set) var previousWorkspace: Int?
    public private(set) var specialVisible: String?
    public private(set) var focused: ClientID?

    private var clients: [ClientID: ClientState] = [:]
    private var workspaces: [WorkspaceID: Workspace] = [:]
    private var recency: [ClientID: Int] = [:]
    private var focusCounter = 0

    public init(monitor: CGRect, settings: WMSettings = .init()) {
        self.monitor = monitor
        self.settings = settings
    }

    public var workArea: CGRect { monitor.inset(by: reserved) }
    public var clientIDs: [ClientID] { Array(clients.keys).sorted() }
    public func workspace(of id: ClientID) -> WorkspaceID? { clients[id]?.workspace }
    public func isFloating(_ id: ClientID) -> Bool { clients[id]?.floating ?? false }

    // MARK: Client lifecycle

    public func addClient(_ id: ClientID, floating: Bool = false, workspace: WorkspaceID? = nil, focus: Bool = true) {
        precondition(clients[id] == nil, "\(id) already managed")
        let wsID = workspace ?? targetWorkspace
        let ws = ensure(wsID)
        if ws.fullscreen != nil { ws.fullscreen = nil }
        clients[id] = ClientState(workspace: wsID, floating: floating)
        if floating {
            clients[id]!.floatRect = defaultFloatRect()
            ws.floating.append(id)
        } else {
            insertTiled(id, into: ws)
        }
        if focus || focused == nil { self.focus(id) }
    }

    public func removeClient(_ id: ClientID) {
        guard let state = clients[id], let ws = workspaces[state.workspace] else { return }
        detach(id, from: ws)
        clients[id] = nil
        recency[id] = nil
        if ws.lastFocused == id { ws.lastFocused = mostRecent(in: ws) }
        if focused == id {
            focused = nil
            if let next = mostRecent(in: ws) ?? fallbackFocus() { focus(next) }
        }
        collectEmptyWorkspaces()
    }

    /// Focuses a client, switching to its workspace if needed.
    public func focus(_ id: ClientID) {
        guard let state = clients[id], let ws = workspaces[state.workspace] else { return }
        switch state.workspace {
        case .regular(let n):
            if n != activeWorkspace { switchTo(n, focusAfter: false) }
            if specialVisible != nil { specialVisible = nil }
        case .special(let name):
            specialVisible = name
        }
        focused = id
        focusCounter += 1
        recency[id] = focusCounter
        ws.lastFocused = id
        if state.floating, let i = ws.floating.firstIndex(of: id) {
            ws.floating.remove(at: i)
            ws.floating.append(id)
        }
    }

    // MARK: Dispatch

    public func dispatch(_ d: Dispatcher) {
        switch d {
        case .exec(let cmd): perform(.spawn(command: cmd))
        case .web(let url): perform(.spawnWeb(url: url))
        case .sim(let q): perform(.spawnSim(query: q))
        case .simButton(let b): if let f = focused { perform(.simButton(f, b)) }
        case .webNav(let n): if let f = focused { perform(.webNav(f, n)) }
        case .killActive: if let f = focused { perform(.close(f)) }
        case .moveFocus(let dir): moveFocus(dir)
        case .moveWindow(let dir): moveWindow(dir)
        case .swapWindow(let dir): swapWindow(dir)
        case .resizeActive(let dx, let dy): resizeActive(dx: dx, dy: dy)
        case .moveActive(let dx, let dy): moveActive(dx: dx, dy: dy)
        case .workspace(let t): gotoWorkspace(t)
        case .moveToWorkspace(let t, let silent): moveToWorkspace(t, silent: silent)
        case .toggleSpecialWorkspace(let name): toggleSpecial(name)
        case .toggleFloating: toggleFloating()
        case .fullscreen(let mode): toggleFullscreen(mode)
        case .toggleSplit: withTiledFocus { $0.tiled.toggleSplit($1) }
        case .swapSplit: withTiledFocus { $0.tiled.swapSplit($1) }
        case .splitRatio(let v, let exact): withTiledFocus { $0.tiled.splitRatio($1, v, exact: exact) }
        case .cycleNext(let prev): cycleNext(previous: prev)
        case .focusCurrentOrLast: focusCurrentOrLast()
        case .centerWindow: centerWindow()
        case .submap(let name): perform(.submap(name))
        case .monitorFullscreen: perform(.monitorFullscreen)
        case .reload: perform(.reload)
        case .exit: perform(.exit)
        }
    }

    // MARK: Snapshot

    public func snapshot() -> Snapshot {
        var out: [Placement] = []
        let visibleIDs = Set(visibleWorkspaces)
        for ws in workspaces.values {
            let visible = visibleIDs.contains(ws.id)
            let zBase: Int
            if case .special = ws.id { zBase = 10_000 } else { zBase = 0 }
            let tiledFrames = tiledFrames(ws)
            // Tiles stack by focus recency (most recent on top). Settled tiles never overlap,
            // but while animating, the window you just touched stays above the rest.
            let stacked = ws.tiled.clients.sorted { (recency[$0] ?? -1) < (recency[$1] ?? -1) }
            for (i, id) in stacked.enumerated() {
                let fs = ws.fullscreen?.id == id ? ws.fullscreen?.mode : nil
                out.append(Placement(
                    id: id, workspace: ws.id,
                    frame: fs.map(fullscreenRect) ?? tiledFrames[id]!,
                    visible: visible, focused: focused == id, floating: false,
                    fullscreen: fs, z: zBase + (fs != nil ? 5_000 : i)))
            }
            for (i, id) in ws.floating.enumerated() {
                let fs = ws.fullscreen?.id == id ? ws.fullscreen?.mode : nil
                let rect = clients[id]?.floatRect ?? defaultFloatRect()
                out.append(Placement(
                    id: id, workspace: ws.id,
                    frame: fs.map(fullscreenRect) ?? rect,
                    visible: visible, focused: focused == id, floating: true,
                    fullscreen: fs, z: zBase + (fs != nil ? 5_000 : 1_000 + i)))
            }
        }
        out.sort { $0.z < $1.z || ($0.z == $1.z && $0.id < $1.id) }
        var nums = Set(workspaces.keys.compactMap { id -> Int? in
            if case .regular(let n) = id, !(workspaces[id]?.isEmpty ?? true) { return n }
            return nil
        })
        nums.insert(activeWorkspace)
        return Snapshot(placements: out, activeWorkspace: activeWorkspace,
                        specialVisible: specialVisible, workspaces: nums.sorted(), focused: focused)
    }

    /// Top-most visible client under a point.
    public func client(at p: CGPoint) -> ClientID? {
        snapshot().placements.last { $0.visible && $0.frame.contains(p) }?.id
    }

    // MARK: Internals: workspaces

    private var visibleWorkspaces: [WorkspaceID] {
        var v: [WorkspaceID] = [.regular(activeWorkspace)]
        if let s = specialVisible { v.append(.special(s)) }
        return v
    }

    /// Where new clients go: the focused client's workspace when it is visible.
    private var targetWorkspace: WorkspaceID {
        if let f = focused, let ws = clients[f]?.workspace, visibleWorkspaces.contains(ws) { return ws }
        if let s = specialVisible { return .special(s) }
        return .regular(activeWorkspace)
    }

    @discardableResult
    private func ensure(_ id: WorkspaceID) -> Workspace {
        if let ws = workspaces[id] { return ws }
        let ws = Workspace(id: id, settings: settings.dwindle)
        workspaces[id] = ws
        return ws
    }

    private func collectEmptyWorkspaces() {
        for (id, ws) in workspaces where ws.isEmpty {
            if id == .regular(activeWorkspace) { continue }
            if case .special(let s) = id, s == specialVisible { continue }
            workspaces[id] = nil
        }
    }

    private func resolve(_ t: WorkspaceTarget) -> WorkspaceID? {
        let used = workspaces.compactMap { id, ws -> Int? in
            if case .regular(let n) = id, !ws.isEmpty { return n }
            return nil
        }.sorted()
        switch t {
        case .id(let n): return .regular(n)
        case .relative(let d): return .regular(max(1, activeWorkspace + d))
        case .relativeExisting(let d):
            var ring = Set(used)
            ring.insert(activeWorkspace)
            let sorted = ring.sorted()
            guard let i = sorted.firstIndex(of: activeWorkspace) else { return nil }
            let j = ((i + d) % sorted.count + sorted.count) % sorted.count
            return .regular(sorted[j])
        case .previous: return previousWorkspace.map { .regular($0) }
        case .empty:
            var n = 1
            while used.contains(n) { n += 1 }
            return .regular(n)
        case .special(let s): return .special(s)
        }
    }

    private func gotoWorkspace(_ t: WorkspaceTarget) {
        guard let target = resolve(t) else { return }
        switch target {
        case .special(let s): toggleSpecial(s)
        case .regular(var n):
            if n == activeWorkspace {
                guard settings.workspaceBackAndForth, let p = previousWorkspace else {
                    if specialVisible != nil { closeSpecial() }
                    return
                }
                n = p
            }
            switchTo(n, focusAfter: true)
        }
    }

    private func switchTo(_ n: Int, focusAfter: Bool) {
        guard n != activeWorkspace else { return }
        previousWorkspace = activeWorkspace
        activeWorkspace = n
        specialVisible = nil
        let ws = ensure(.regular(n))
        collectEmptyWorkspaces()
        if focusAfter {
            focused = nil
            if let f = ws.lastFocused ?? mostRecent(in: ws) { focus(f) }
        }
    }

    private func toggleSpecial(_ name: String) {
        if specialVisible == name {
            closeSpecial()
            return
        }
        specialVisible = name
        let ws = ensure(.special(name))
        focused = nil
        if let f = ws.lastFocused ?? mostRecent(in: ws) { focus(f) }
    }

    private func closeSpecial() {
        specialVisible = nil
        collectEmptyWorkspaces()
        focused = nil
        let ws = ensure(.regular(activeWorkspace))
        if let f = ws.lastFocused ?? mostRecent(in: ws) { focus(f) }
    }

    private func moveToWorkspace(_ t: WorkspaceTarget, silent: Bool) {
        guard let id = focused, let state = clients[id], let target = resolve(t),
              target != state.workspace, let from = workspaces[state.workspace] else { return }
        detach(id, from: from)
        if from.lastFocused == id { from.lastFocused = nil }
        clients[id]!.tiledSlot = nil  // a slot only makes sense on its own workspace
        let to = ensure(target)
        if to.fullscreen != nil { to.fullscreen = nil }
        clients[id]!.workspace = target
        if state.floating { to.floating.append(id) } else { insertTiled(id, into: to, useCursor: false) }
        to.lastFocused = id

        if silent {
            focused = nil
            if let next = mostRecent(in: from) { focus(next) }
            else if case .special = from.id { closeSpecial() }
        } else {
            focus(id)
        }
        collectEmptyWorkspaces()
    }

    // MARK: Internals: tiling

    private var tileArea: CGRect { workArea }

    private func insertTiled(_ id: ClientID, into ws: Workspace, useCursor: Bool = true, focal: CGPoint? = nil) {
        let target = ws.lastFocused.flatMap { ws.tiled.contains($0) ? $0 : nil }
        var focalPoint = focal
        if focalPoint == nil, useCursor, settings.dwindle.forceSplit == 0, let c = cursor, tileArea.contains(c) {
            focalPoint = c
        }
        ws.tiled.insert(id, target: target, focalPoint: focalPoint, area: tileArea)
    }

    private func detach(_ id: ClientID, from ws: Workspace) {
        ws.tiled.remove(id)
        ws.floating.removeAll { $0 == id }
        if ws.fullscreen?.id == id { ws.fullscreen = nil }
    }

    private func tiledFrames(_ ws: Workspace) -> [ClientID: CGRect] {
        let area = tileArea
        let boxes = ws.tiled.layout(in: area)
        return boxes.mapValues { applyGaps($0, area: area) }
    }

    private func applyGaps(_ box: CGRect, area: CGRect) -> CGRect {
        let eps = 1.0
        let gi = settings.gapsIn, go = settings.gapsOut
        let insets = Insets(
            top: abs(box.minY - area.minY) < eps ? go.top : gi.top,
            right: abs(box.maxX - area.maxX) < eps ? go.right : gi.right,
            bottom: abs(box.maxY - area.maxY) < eps ? go.bottom : gi.bottom,
            left: abs(box.minX - area.minX) < eps ? go.left : gi.left)
        return box.inset(by: insets)
    }

    private func fullscreenRect(_ mode: FullscreenMode) -> CGRect {
        switch mode {
        case .fullscreen: return monitor
        case .maximize: return workArea.inset(by: settings.gapsOut)
        }
    }

    private func defaultFloatRect() -> CGRect {
        let a = workArea
        let w = (a.width * settings.floatSizeFraction).rounded()
        let h = (a.height * settings.floatSizeFraction).rounded()
        return CGRect(x: (a.midX - w / 2).rounded(), y: (a.midY - h / 2).rounded(), width: w, height: h)
    }

    // MARK: Internals: focus

    private func mostRecent(in ws: Workspace) -> ClientID? {
        ws.clients.max { (recency[$0] ?? -1) < (recency[$1] ?? -1) }
    }

    private func fallbackFocus() -> ClientID? {
        for id in visibleWorkspaces.reversed() {
            if let ws = workspaces[id], let f = mostRecent(in: ws) { return f }
        }
        return nil
    }

    private func focusedContext() -> (ClientID, Workspace, ClientState)? {
        guard let f = focused, let st = clients[f], let ws = workspaces[st.workspace] else { return nil }
        return (f, ws, st)
    }

    private func withTiledFocus(_ body: (Workspace, ClientID) -> Void) {
        guard let (f, ws, st) = focusedContext(), !st.floating else { return }
        body(ws, f)
    }

    private func frames(in ws: Workspace) -> [ClientID: CGRect] {
        var out = tiledFrames(ws)
        for id in ws.floating { out[id] = clients[id]?.floatRect }
        return out
    }

    private func moveFocus(_ dir: Direction) {
        guard let (f, ws, st) = focusedContext() else {
            if let any = fallbackFocus() { focus(any) }
            return
        }
        let all = frames(in: ws)
        guard let from = all[f] else { return }
        let candidates = all.filter { $0.key != f && (clients[$0.key]?.floating ?? false) == st.floating }
            .map { ($0.key, $0.value) }
        if let n = DirectionalSearch.neighbor(of: from, direction: dir, candidates: candidates, recency: recency) {
            focus(n)
        }
    }

    private func moveWindow(_ dir: Direction) {
        guard let (f, ws, st) = focusedContext() else { return }
        if st.floating {
            // Floating: snap to the work-area edge in that direction.
            guard var r = clients[f]?.floatRect else { return }
            let a = workArea.inset(by: settings.gapsOut)
            switch dir {
            case .left: r.origin.x = a.minX
            case .right: r.origin.x = a.maxX - r.width
            case .up: r.origin.y = a.minY
            case .down: r.origin.y = a.maxY - r.height
            }
            clients[f]!.floatRect = r
            return
        }
        let boxes = ws.tiled.layout(in: tileArea)
        guard let box = boxes[f], boxes.count > 1 else { return }
        let focal: CGPoint
        switch dir {
        case .left: focal = CGPoint(x: box.minX - 1, y: box.midY)
        case .right: focal = CGPoint(x: box.maxX + 1, y: box.midY)
        case .up: focal = CGPoint(x: box.midX, y: box.minY - 1)
        case .down: focal = CGPoint(x: box.midX, y: box.maxY + 1)
        }
        guard tileArea.contains(focal) else { return }
        ws.tiled.remove(f)
        ws.tiled.insert(f, target: nil, focalPoint: focal, area: tileArea, focalDecidesSide: true)
    }

    private func swapWindow(_ dir: Direction) {
        guard let (f, ws, st) = focusedContext(), !st.floating else { return }
        let tiled = tiledFrames(ws)
        guard let from = tiled[f] else { return }
        let candidates = tiled.filter { $0.key != f }.map { ($0.key, $0.value) }
        guard let n = DirectionalSearch.neighbor(of: from, direction: dir, candidates: candidates, recency: recency) else { return }
        ws.tiled.swap(f, n)
    }

    private func resizeActive(dx: Double, dy: Double) {
        guard let (f, ws, st) = focusedContext() else { return }
        if st.floating {
            guard var r = clients[f]?.floatRect else { return }
            r.size.width = max(80, r.width + dx)
            r.size.height = max(60, r.height + dy)
            clients[f]!.floatRect = r
        } else {
            ws.tiled.layout(in: tileArea)
            ws.tiled.resize(f, dx: dx, dy: dy)
        }
    }

    private func moveActive(dx: Double, dy: Double) {
        guard let (f, _, st) = focusedContext(), st.floating, var r = clients[f]?.floatRect else { return }
        r.origin.x += dx
        r.origin.y += dy
        clients[f]!.floatRect = r
    }

    /// Used by mouse drags on floating windows.
    public func setFloatingFrame(_ id: ClientID, _ rect: CGRect) {
        guard clients[id]?.floating == true else { return }
        clients[id]!.floatRect = rect
    }

    /// Mouse resize of a tiled client: moves the grabbed edges with the pointer.
    public func moveTiledEdges(_ id: ClientID, horizontal: Direction, dx: Double, vertical: Direction, dy: Double) {
        guard let st = clients[id], !st.floating, let ws = workspaces[st.workspace] else { return }
        ws.tiled.layout(in: tileArea)
        ws.tiled.moveEdge(id, horizontal, by: dx)
        ws.tiled.moveEdge(id, vertical, by: dy)
    }

    /// Drops a tiled client at a point: re-inserts it next to the client there,
    /// on the side of the point. Used by mouse drag-and-drop.
    public func dropTiled(_ id: ClientID, at point: CGPoint) {
        guard let st = clients[id], !st.floating, let ws = workspaces[st.workspace], ws.tiled.clients.count > 1 else { return }
        ws.tiled.remove(id)
        ws.tiled.insert(id, target: nil, focalPoint: point, area: tileArea, focalDecidesSide: true)
    }

    private func toggleFloating() {
        guard let (f, ws, st) = focusedContext() else { return }
        if ws.fullscreen?.id == f { ws.fullscreen = nil }
        if st.floating {
            let center = clients[f]?.floatRect?.center
            ws.floating.removeAll { $0 == f }
            clients[f]!.floating = false
            // Back to where it was tiled, if that spot still makes sense.
            if let slot = clients[f]?.tiledSlot, ws.tiled.insert(f, at: slot) {
                clients[f]!.tiledSlot = nil
            } else {
                clients[f]!.tiledSlot = nil
                insertTiled(f, into: ws, useCursor: false, focal: center)
            }
        } else {
            let current = tiledFrames(ws)[f]
            clients[f]!.tiledSlot = ws.tiled.slot(of: f)
            ws.tiled.remove(f)
            clients[f]!.floating = true
            if clients[f]!.floatRect == nil {
                // Keep the tiled size, like Hyprland, unless that nearly fills the
                // work area (e.g. the only window): then floating would look like
                // nothing happened, so start centered at hypermux:float_size.
                let a = workArea
                if let c = current, c.width < a.width * 0.8 || c.height < a.height * 0.8 {
                    clients[f]!.floatRect = c
                } else {
                    clients[f]!.floatRect = defaultFloatRect()
                }
            }
            ws.floating.append(f)
        }
    }

    private func toggleFullscreen(_ mode: FullscreenMode) {
        guard let (f, ws, _) = focusedContext() else { return }
        if let cur = ws.fullscreen, cur.id == f, cur.mode == mode {
            ws.fullscreen = nil
        } else {
            ws.fullscreen = (f, mode)
        }
    }

    private func cycleNext(previous: Bool) {
        guard let (f, ws, _) = focusedContext() else {
            if let any = fallbackFocus() { focus(any) }
            return
        }
        let order = ws.clients
        guard order.count > 1, let i = order.firstIndex(of: f) else { return }
        let j = previous ? (i - 1 + order.count) % order.count : (i + 1) % order.count
        focus(order[j])
    }

    private func focusCurrentOrLast() {
        let byRecency = recency.sorted { $0.value > $1.value }.map(\.key)
        guard byRecency.count > 1 else { return }
        focus(byRecency[1])
    }

    private func centerWindow() {
        guard let (f, _, st) = focusedContext(), st.floating, var r = clients[f]?.floatRect else { return }
        let a = workArea
        r.origin = CGPoint(x: (a.midX - r.width / 2).rounded(), y: (a.midY - r.height / 2).rounded())
        clients[f]!.floatRect = r
    }
}
