import CoreGraphics
import Foundation

// MARK: Schema

/// Everything needed to bring a Hyprmux session back: workspaces, their split trees,
/// floating windows, groups, focus, and names. Tiles carry what their surface needs
/// (a directory, a URL, a simulator). JSON; the same schema serves saved sessions and
/// (later) hand-written layouts, so every field but `kind` is optional.
public struct SessionState: Codable, Equatable, Sendable {
    public var version = 1
    public var activeWorkspace = 1
    public var specialVisible: String?
    public var workspaces: [SessionWorkspace] = []
    /// Names set at runtime (`renameworkspace`), by workspace number.
    public var names: [String: String] = [:]

    public init() {}

    enum CodingKeys: String, CodingKey { case version, activeWorkspace, specialVisible, workspaces, names }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        activeWorkspace = try c.decodeIfPresent(Int.self, forKey: .activeWorkspace) ?? 1
        specialVisible = try c.decodeIfPresent(String.self, forKey: .specialVisible)
        workspaces = try c.decodeIfPresent([SessionWorkspace].self, forKey: .workspaces) ?? []
        names = try c.decodeIfPresent([String: String].self, forKey: .names) ?? [:]
    }
}

public struct SessionWorkspace: Codable, Equatable, Sendable {
    /// "3" or "special:magic", as in dispatchers. Layouts leave it out and use `name`.
    public var id: String
    /// Layouts: the workspace's name. Loading finds the workspace with it, or makes one.
    public var name: String?
    public var tiled: SessionNode?
    public var floating: [SessionFloating] = []
    /// Key of the tile that had focus here.
    public var focused: Int?
    public var fullscreen: SessionFullscreen?

    public init(id: String, tiled: SessionNode? = nil, floating: [SessionFloating] = [],
                focused: Int? = nil, fullscreen: SessionFullscreen? = nil) {
        self.id = id
        self.tiled = tiled
        self.floating = floating
        self.focused = focused
        self.fullscreen = fullscreen
    }

    enum CodingKeys: String, CodingKey { case id, name, tiled, floating, focused, fullscreen }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name)
        tiled = try c.decodeIfPresent(SessionNode.self, forKey: .tiled)
        floating = try c.decodeIfPresent([SessionFloating].self, forKey: .floating) ?? []
        focused = try c.decodeIfPresent(Int.self, forKey: .focused)
        fullscreen = try c.decodeIfPresent(SessionFullscreen.self, forKey: .fullscreen)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if !id.isEmpty { try c.encode(id, forKey: .id) }
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(tiled, forKey: .tiled)
        if !floating.isEmpty { try c.encode(floating, forKey: .floating) }
        try c.encodeIfPresent(focused, forKey: .focused)
        try c.encodeIfPresent(fullscreen, forKey: .fullscreen)
    }
}

public struct SessionFullscreen: Codable, Equatable, Sendable {
    public var tile: Int
    /// 0 = fullscreen, 1 = maximize.
    public var mode: Int
    public init(tile: Int, mode: Int) { self.tile = tile; self.mode = mode }
}

/// One window's content.
public struct SessionTile: Codable, Equatable, Sendable {
    /// "terminal", "web", "sim", "android", or "app".
    public var kind: String
    /// Unique within the file. Focus and fullscreen refer to tiles by key.
    public var key: Int?
    public var title: String?
    /// Terminal: working directory.
    public var cwd: String?
    /// Terminal: a program to start in the shell (typed as its first input).
    public var command: String?
    /// Terminal: an agent session to resume, turned into a command by `session:resume`.
    public var agent: SessionAgent?
    /// Web: the page.
    public var url: String?
    /// Simulator: UDID (or a device name).
    public var sim: String?
    /// Android Emulator: stable Android Virtual Device id.
    public var avd: String?
    /// Android Emulator: display name, retained as a restore fallback and for hand-written layouts.
    public var avdName: String?
    /// Client app: what `new-surface --type app` was given (target and arguments).
    /// Tiles that came from one launch share it, and are relaunched together.
    public var app: String?
    /// Client app: the toplevel's restore token (docs/CLIENT_PROTOCOL.md, section 10).
    public var restoreToken: String?

    public init(kind: String, key: Int? = nil, title: String? = nil, cwd: String? = nil, command: String? = nil,
                agent: SessionAgent? = nil, url: String? = nil, sim: String? = nil,
                avd: String? = nil, avdName: String? = nil, app: String? = nil, restoreToken: String? = nil) {
        self.kind = kind
        self.key = key
        self.title = title
        self.cwd = cwd
        self.command = command
        self.agent = agent
        self.url = url
        self.sim = sim
        self.avd = avd
        self.avdName = avdName
        self.app = app
        self.restoreToken = restoreToken
    }
}

public struct SessionAgent: Codable, Equatable, Sendable {
    /// Matches a `session:resume:KIND` template, e.g. "pi".
    public var kind: String
    /// Nil starts a new session with `session:start:KIND` (layouts do this).
    public var session: String?
    public init(kind: String, session: String? = nil) { self.kind = kind; self.session = session }
}

/// A slot: one tile, or a group of tabs.
public struct SessionSlot: Equatable, Sendable {
    public var tabs: [SessionTile]
    /// Index of the shown tab.
    public var active: Int

    public init(tabs: [SessionTile], active: Int = 0) {
        self.tabs = tabs
        self.active = active
    }

    enum CodingKeys: String, CodingKey { case tabs, active }

    /// A single tile is written flat (`{"kind": "terminal", ...}`), a group as `{"tabs": [...]}`.
    static func decode(from decoder: Decoder) throws -> SessionSlot {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let tabs = try c.decodeIfPresent([SessionTile].self, forKey: .tabs) {
            return SessionSlot(tabs: tabs, active: try c.decodeIfPresent(Int.self, forKey: .active) ?? 0)
        }
        return SessionSlot(tabs: [try SessionTile(from: decoder)])
    }

    func encode(to encoder: Encoder) throws {
        if tabs.count == 1 {
            try tabs[0].encode(to: encoder)
        } else {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(tabs, forKey: .tabs)
            try c.encode(active, forKey: .active)
        }
    }
}

/// The split tree: a split with two children, or a slot.
public indirect enum SessionNode: Codable, Equatable, Sendable {
    /// `vertical`: stacked top/bottom ("v"); otherwise side by side ("h").
    case split(vertical: Bool, ratio: Double, first: SessionNode, second: SessionNode)
    case slot(SessionSlot)

    enum CodingKeys: String, CodingKey { case split, ratio, children }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let dir = try c.decodeIfPresent(String.self, forKey: .split) else {
            self = .slot(try SessionSlot.decode(from: decoder))
            return
        }
        let children = try c.decode([SessionNode].self, forKey: .children)
        guard children.count == 2 else {
            throw DecodingError.dataCorruptedError(forKey: .children, in: c, debugDescription: "a split has two children")
        }
        self = .split(vertical: dir.lowercased().hasPrefix("v"), ratio: try c.decodeIfPresent(Double.self, forKey: .ratio) ?? 1,
                      first: children[0], second: children[1])
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .slot(let s):
            try s.encode(to: encoder)
        case .split(let vertical, let ratio, let a, let b):
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(vertical ? "v" : "h", forKey: .split)
            try c.encode(ratio, forKey: .ratio)
            try c.encode([a, b], forKey: .children)
        }
    }
}

/// A floating window (or group): its slot and its rectangle as fractions of the work area.
public struct SessionFloating: Codable, Equatable, Sendable {
    public var slot: SessionSlot
    /// [x, y, width, height], each 0...1 of the work area, so it fits another display.
    public var rect: [Double]

    public init(slot: SessionSlot, rect: [Double]) {
        self.slot = slot
        self.rect = rect
    }

    enum CodingKeys: String, CodingKey { case rect }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rect = try c.decodeIfPresent([Double].self, forKey: .rect) ?? [0.2, 0.2, 0.6, 0.6]
        slot = try SessionSlot.decode(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try slot.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(rect, forKey: .rect)
    }
}

extension SessionState {
    public static func decode(_ data: Data) throws -> SessionState {
        try JSONDecoder().decode(SessionState.self, from: data)
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }
}

// MARK: Export and restore

extension WindowManager {
    /// The current layout as a session. `tile` describes a client's content; clients it
    /// returns nil for are left out (their splits collapse).
    public func exportSession(tile: (ClientID) -> SessionTile?) -> SessionState {
        var s = SessionState()
        s.activeWorkspace = activeWorkspace
        s.specialVisible = specialVisible
        let ordered = workspaces.values.sorted { a, b in
            switch (a.id, b.id) {
            case let (.regular(x), .regular(y)): return x < y
            case (.regular, .special): return true
            case (.special, .regular): return false
            case let (.special(x), .special(y)): return x < y
            }
        }
        var nextKey = 1
        for ws in ordered {
            if let w = export(ws, tile: tile, nextKey: &nextKey) { s.workspaces.append(w) }
        }
        for (n, name) in renamed { s.names[String(n)] = name }
        return s
    }

    /// One workspace, for a layout file. Nil when it has no windows.
    public func exportWorkspace(_ id: WorkspaceID, tile: (ClientID) -> SessionTile?) -> SessionWorkspace? {
        guard let ws = workspaces[id] else { return nil }
        var nextKey = 1
        return export(ws, tile: tile, nextKey: &nextKey)
    }

    private func export(_ ws: Workspace, tile: (ClientID) -> SessionTile?, nextKey: inout Int) -> SessionWorkspace? {
        guard !ws.isEmpty else { return nil }
        var keys: [ClientID: Int] = [:]
        var counter = nextKey
        defer { nextKey = counter }
        func describe(_ id: ClientID) -> SessionTile? {
            guard var t = tile(id) else { return nil }
            t.key = counter
            keys[id] = counter
            counter += 1
            return t
        }
        func slot(_ id: ClientID) -> SessionSlot? {
            let members = group(of: id)?.members ?? [id]
            var tabs: [SessionTile] = []
            var active = 0
            for m in members {
                guard let t = describe(m) else { continue }
                if m == id { active = tabs.count }
                tabs.append(t)
            }
            return tabs.isEmpty ? nil : SessionSlot(tabs: tabs, active: active)
        }
        func node(_ n: DwindleLayout.Node) -> SessionNode? {
            if let c = n.client { return slot(c).map { .slot($0) } }
            guard n.children.count == 2 else { return n.children.first.flatMap(node) }
            let a = node(n.children[0]), b = node(n.children[1])
            switch (a, b) {
            case let (a?, b?): return .split(vertical: n.splitTop, ratio: n.ratio, first: a, second: b)
            case let (a?, nil): return a
            case let (nil, b?): return b
            default: return nil
            }
        }
        let area = workArea
        var w = SessionWorkspace(id: ws.id.description)
        w.tiled = ws.tiled.root.flatMap(node)
        for id in ws.floating {
            guard let sl = slot(id) else { continue }
            let r = clients[id]?.floatRect ?? defaultFloatRect()
            let rect: [Double] = area.width > 0 && area.height > 0
                ? [Double((r.minX - area.minX) / area.width), Double((r.minY - area.minY) / area.height),
                   Double(r.width / area.width), Double(r.height / area.height)]
                : [0.2, 0.2, 0.6, 0.6]
            w.floating.append(SessionFloating(slot: sl, rect: rect.map { ($0 * 10_000).rounded() / 10_000 }))
        }
        w.focused = ws.lastFocused.flatMap { keys[$0] }
        if let fs = ws.fullscreen, let k = keys[fs.id] { w.fullscreen = SessionFullscreen(tile: k, mode: fs.mode.rawValue) }
        guard w.tiled != nil || !w.floating.isEmpty else { return nil }
        return w
    }

    /// Rebuilds a saved session into an empty manager. `make` creates each tile's client and
    /// returns its id, or nil to skip it (a simulator that's gone). Returns the clients made.
    @discardableResult
    public func restoreSession(_ s: SessionState, make: (SessionTile) -> ClientID?) -> [ClientID] {
        precondition(clients.isEmpty, "restore into an empty window manager")
        var made: [ClientID] = []
        for w in s.workspaces {
            guard let target = WorkspaceTarget(hyprland: w.id) else { continue }
            let id: WorkspaceID
            switch target {
            case .id(let n) where n >= 1: id = .regular(n)
            case .special(let name): id = .special(name)
            default: continue
            }
            made += restoreWorkspace(w, into: id, make: make)
        }
        for (k, v) in s.names { if let n = Int(k) { renamed[n] = v } }
        activeWorkspace = max(1, s.activeWorkspace)
        ensure(.regular(activeWorkspace))
        if let sp = s.specialVisible, workspaces[.special(sp)].map({ !$0.isEmpty }) == true {
            specialVisible = sp
        }
        focused = nil
        let shown = workspaces[specialVisible.map { .special($0) } ?? .regular(activeWorkspace)]
        if let ws = shown, let f = ws.lastFocused ?? mostRecent(in: ws) ?? ws.clients.first { focus(f) }
        collectEmptyWorkspaces()
        return made
    }

    /// Opens a layout (a template). Each of its workspaces is found by name and left alone
    /// when it already has windows, so loading twice doesn't duplicate anything. Otherwise
    /// it's built on the first free number (or the empty workspace with that name) and named.
    /// A single-workspace layout without a name takes `defaultName` (the file's name).
    /// Shows the first of them and returns their numbers.
    @discardableResult
    public func loadLayout(_ layout: SessionState, defaultName: String?, make: (SessionTile) -> ClientID?) -> [Int] {
        var touched: [Int] = []
        let single = layout.workspaces.count == 1
        for w in layout.workspaces {
            let own = w.name?.trimmingCharacters(in: .whitespaces)
            let name = own?.isEmpty == false ? own : (single ? defaultName : nil)
            if let name, let n = workspace(named: name), !(workspaces[.regular(n)]?.isEmpty ?? true) {
                touched.append(n)
                continue
            }
            let n = name.flatMap { workspace(named: $0) } ?? freeWorkspaceNumber()
            guard !restoreWorkspace(w, into: .regular(n), make: make).isEmpty else { continue }
            if let name, self.name(of: n) != name { renamed[n] = name }
            touched.append(n)
        }
        if let first = touched.first {
            specialVisible = nil
            if first != activeWorkspace { switchTo(first, focusAfter: true) }
            if let ws = workspaces[.regular(first)], focused.flatMap({ clients[$0]?.workspace }) != .regular(first) {
                focused = nil
                if let f = ws.lastFocused ?? mostRecent(in: ws) ?? ws.clients.first { focus(f) }
            }
        }
        collectEmptyWorkspaces()
        return touched
    }

    /// The first workspace number with no windows and no name.
    func freeWorkspaceNumber() -> Int {
        var n = 1
        while !(workspaces[.regular(n)]?.isEmpty ?? true) || name(of: n) != nil { n += 1 }
        return n
    }

    /// Builds one saved workspace into `id` (which must be empty or new).
    ///
    /// `make` can run the main run loop (a simulator tile waits for a helper process), so
    /// queued work such as a web tile taking focus runs in the middle of this. A focus
    /// change that switches workspaces collects empty ones, and this one looks empty until
    /// its tree is set: it's marked as being built so it isn't collected.
    func restoreWorkspace(_ w: SessionWorkspace, into id: WorkspaceID, make: (SessionTile) -> ClientID?) -> [ClientID] {
        building.insert(id)
        defer { building.remove(id) }
        let ws = ensure(id)
        var byKey: [Int: ClientID] = [:]
        var made: [ClientID] = []
        func slot(_ sl: SessionSlot, floating: Bool) -> ClientID? {
            var members: [ClientID] = []
            var active: ClientID?
            for (i, t) in sl.tabs.enumerated() {
                guard let c = make(t) else { continue }
                clients[c] = ClientState(workspace: id, floating: floating)
                if let k = t.key { byKey[k] = c }
                members.append(c)
                made.append(c)
                if i == sl.active || active == nil { active = c }
            }
            guard let shown = active else { return nil }
            if members.count > 1 {
                let gid = GroupID(raw: nextGroupID)
                nextGroupID += 1
                let g = Group(shown)
                g.members = members
                groups[gid] = g
                for m in members { clients[m]!.group = gid }
            }
            return shown
        }
        func node(_ n: SessionNode) -> DwindleLayout.Node? {
            switch n {
            case .slot(let sl):
                return slot(sl, floating: false).map { DwindleLayout.Node(client: $0) }
            case .split(let vertical, let ratio, let a, let b):
                let na = node(a), nb = node(b)
                guard let na, let nb else { return na ?? nb }
                let p = DwindleLayout.Node(client: nil)
                p.splitTop = vertical
                p.ratio = DwindleLayout.clamp(ratio)
                p.children = [na, nb]
                return p
            }
        }
        ws.tiled.setRoot(w.tiled.flatMap(node))
        let area = workArea
        for f in w.floating {
            guard let c = slot(f.slot, floating: true) else { continue }
            let r = f.rect.count == 4 ? f.rect : [0.2, 0.2, 0.6, 0.6]
            clients[c]!.floatRect = CGRect(x: area.minX + r[0] * area.width, y: area.minY + r[1] * area.height,
                                           width: max(120, r[2] * area.width), height: max(80, r[3] * area.height))
            ws.floating.append(c)
        }
        if let fs = w.fullscreen, let c = byKey[fs.tile], ws.clients.contains(c) {
            ws.fullscreen = (c, FullscreenMode(rawValue: fs.mode) ?? .fullscreen)
        }
        if let k = w.focused, let c = byKey[k] {
            // A hidden tab that had focus becomes the shown one.
            if isHiddenMember(c) { activate(c) }
            ws.lastFocused = c
        }
        return made
    }
}

// MARK: What comes back

/// The `session { }` config section.
public struct RestoreSettings: Equatable, Sendable {
    /// Restore the last session on launch.
    public var enabled = true
    /// Programs relaunched (same arguments, same directory) when they were in the
    /// foreground at save time. "*" allows any program; `deny` then excludes some.
    public var programs: [String] = ["nvim", "vim", "lazygit", "htop", "btop", "less", "man"]
    public var deny: [String] = []
    /// Agent resume commands by kind, with `{id}` for the session id.
    public var resume: [String: String] = [:]
    /// Commands that start a new agent session, by kind (layouts use them).
    public var start: [String: String] = [:]

    public init() {}
}

/// An agent's report that its terminal can be brought back with a session id
/// (`hyprmuxctl resume {json}`).
public struct ResumeReport: Codable, Equatable, Sendable {
    /// HYPRMUX_CLIENT of the reporting terminal.
    public var client: UInt64
    /// The agent's process. The report counts only while it runs in the terminal's foreground.
    public var pid: Int32
    public var kind: String
    public var session: String
    public var cwd: String?
    /// The session file. When given, it must exist at save time (a session with no
    /// messages yet has none, and can't be resumed).
    public var file: String?

    public init(client: UInt64, pid: Int32, kind: String, session: String, cwd: String? = nil, file: String? = nil) {
        self.client = client
        self.pid = pid
        self.kind = kind
        self.session = session
        self.cwd = cwd
        self.file = file
    }
}

public enum RestorePolicy {
    /// A foreground shell means nothing else is running.
    static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "tcsh", "csh", "ksh", "nu", "xonsh", "login"]

    /// The command to relaunch a terminal's foreground program with, or nil when it isn't
    /// allowed (or is just the shell).
    ///
    /// `typed` is the command line as the shell reported it: Ghostty's shell integration
    /// sets the title to it when a command starts. It's preferred, because the process
    /// often isn't what was typed: `tool release` runs as `ruby …/tool release`
    /// (tool is a shell function), and a wrapper may exec something else entirely. It's used
    /// only when it matches an entry by name, since a program can set its own title.
    /// Entries can be several words: `tool release` allows that and not `tool deploy`.
    public static func programCommand(argv: [String], typed: String? = nil, settings: RestoreSettings) -> String? {
        guard let first = argv.first, !first.isEmpty else { return nil }
        var name = (first as NSString).lastPathComponent
        if name.hasPrefix("-") { name.removeFirst() }  // login shells: "-zsh"
        guard !shells.contains(name) else { return nil }
        if let line = typed?.trimmingCharacters(in: .whitespaces), !line.isEmpty {
            var words = line.split(separator: " ").map(String.init)
            // Leading VAR=value assignments aren't the program.
            while let w = words.first, w.contains("="), !w.hasPrefix("=") { words.removeFirst() }
            if !words.isEmpty, !denied(words, settings), listed(words, settings.programs) { return line }
        }
        let words = [name] + argv.dropFirst()
        guard !denied(words, settings), settings.programs.contains("*") || listed(words, settings.programs) else { return nil }
        return words.map(shellQuote).joined(separator: " ")
    }

    /// Whether a list entry (one or more words) is a prefix of the command's words.
    static func listed(_ words: [String], _ entries: [String]) -> Bool {
        let name = (words[0] as NSString).lastPathComponent
        let w = [name] + words.dropFirst()
        return entries.contains { e in
            let ew = e.split(separator: " ").map(String.init)
            return !ew.isEmpty && ew != ["*"] && w.count >= ew.count && Array(w.prefix(ew.count)) == ew
        }
    }

    static func denied(_ words: [String], _ s: RestoreSettings) -> Bool { listed(words, s.deny) }

    /// The command that resumes an agent session (`session:resume:KIND`), or starts a new
    /// one when there's no session id (`session:start:KIND`).
    public static func resumeCommand(_ a: SessionAgent, settings: RestoreSettings) -> String? {
        guard let id = a.session, !id.isEmpty else {
            return settings.start[a.kind].flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let t = settings.resume[a.kind], !t.isEmpty else { return nil }
        return t.replacingOccurrences(of: "{id}", with: shellQuote(id))
    }

    /// Quotes a word for sh/zsh when it needs it.
    public static func shellQuote(_ s: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./_-~")
        if !s.isEmpty, s.unicodeScalars.allSatisfy({ safe.contains($0) }), !s.hasPrefix("~") { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
