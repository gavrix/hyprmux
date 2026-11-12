import Foundation

/// Turns a cmux session snapshot into Hyprmux layouts, one per cmux workspace.
///
/// cmux (github.com/manaflow-ai/cmux) saves its session to
/// `~/Library/Application Support/cmux/session-<bundle id>.json`, plus a
/// `session-<bundle id>-previous.json` backup. Each install (stable
/// `com.cmuxterm.app`, `.nightly`, `.rc`, tagged debug builds) has its own file.
/// A workspace there holds a split tree of panes; a pane holds tabs ("panels"):
/// terminals, browsers, and markdown files.
public enum CmuxImport {
    /// The snapshot schema this reads. cmux keeps a newer one in a side file
    /// (`session-<id>.schema-vN.json`), so the main file stays at this version.
    public static let supportedVersion = 1

    /// The stable install's bundle id. Other channels add a suffix.
    public static let stableBundleID = "com.cmuxterm.app"

    /// `~/Library/Application Support/cmux`.
    public static var defaultDirectory: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cmux").path
    }

    // MARK: Finding snapshots

    /// One install's snapshot file.
    public struct Source: Equatable, Sendable {
        public var path: String
        public var bundleID: String
        public var modified: Date

        public init(path: String, bundleID: String, modified: Date) {
            self.path = path
            self.bundleID = bundleID
            self.modified = modified
        }

        /// "cmux", "cmux nightly", "cmux debug.foo".
        public var label: String {
            bundleID == stableBundleID ? "cmux" : "cmux " + bundleID.dropFirst(stableBundleID.count + 1)
        }
    }

    /// The snapshot of each install in `directory`, stable first, then the newest. An
    /// install's main file wins over its `-previous` backup; the backup counts only when
    /// the main file is missing.
    public static func sources(in directory: String, fileManager fm: FileManager = .default) -> [Source] {
        guard let files = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        var primary: [String: Source] = [:]
        var backup: [String: Source] = [:]
        for f in files {
            guard let (id, isBackup) = parseFileName(f) else { continue }
            let path = (directory as NSString).appendingPathComponent(f)
            let modified = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
            let s = Source(path: path, bundleID: id, modified: modified)
            if isBackup { backup[id] = s } else { primary[id] = s }
        }
        for (id, s) in backup where primary[id] == nil { primary[id] = s }
        return primary.values.sorted { a, b in
            if (a.bundleID == stableBundleID) != (b.bundleID == stableBundleID) { return a.bundleID == stableBundleID }
            if a.modified != b.modified { return a.modified > b.modified }
            return a.bundleID < b.bundleID
        }
    }

    /// `session-com.cmuxterm.app.nightly-previous.json` → ("com.cmuxterm.app.nightly", true).
    /// Side files (`.schema-v2`, `.unusable`) aren't snapshots this can read.
    static func parseFileName(_ name: String) -> (bundleID: String, isBackup: Bool)? {
        guard name.hasPrefix("session-"), name.hasSuffix(".json") else { return nil }
        var id = String(name.dropFirst("session-".count).dropLast(".json".count))
        let isBackup = id.hasSuffix("-previous")
        if isBackup { id.removeLast("-previous".count) }
        guard id == stableBundleID || id.hasPrefix(stableBundleID + "."),
              !id.contains(".schema-v"), !id.contains(".unusable") else { return nil }
        return (id, isBackup)
    }

    // MARK: Converting

    public enum ImportError: Error, Equatable, CustomStringConvertible {
        /// The file isn't a cmux snapshot.
        case unreadable(String)
        /// A schema this doesn't know. Guessing could restore the wrong thing.
        case unsupportedVersion(Int)

        public var description: String {
            switch self {
            case .unreadable(let why): return "not a cmux session: \(why)"
            case .unsupportedVersion(let v): return "cmux session version \(v) isn't supported (expected \(CmuxImport.supportedVersion))"
            }
        }
    }

    public struct Result: Equatable, Sendable {
        /// One per cmux workspace that has something to show, each with a unique `name`.
        public var workspaces: [SessionWorkspace]
        /// Agent sessions that resume (they were running when cmux saved).
        public var agents: Int
        public var tiles: Int
    }

    public static func convert(_ data: Data) throws -> Result {
        let snapshot: Snapshot
        do {
            snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        } catch {
            throw ImportError.unreadable(String(describing: error))
        }
        let version = snapshot.version ?? supportedVersion
        guard version == supportedVersion else { throw ImportError.unsupportedVersion(version) }
        var out = Result(workspaces: [], agents: 0, tiles: 0)
        var names = Set<String>()
        var index = 0
        for window in snapshot.windows ?? [] {
            for ws in window.tabManager?.workspaces ?? [] {
                index += 1
                guard var w = convert(ws, agents: &out.agents, tiles: &out.tiles) else { continue }
                let base = name(of: ws, index: index)
                var name = base
                var n = 2
                while names.contains(name) { name = "\(base) \(n)"; n += 1 }
                names.insert(name)
                w.name = name
                out.workspaces.append(w)
            }
        }
        return out
    }

    /// The workspace's title in cmux, else its git branch, else its directory's name.
    static func name(of ws: Workspace, index: Int) -> String {
        let candidates = [ws.customTitle, ws.gitBranch, ws.currentDirectory.map { ($0 as NSString).lastPathComponent }]
        for c in candidates {
            // A title can be a whole pasted prompt: keep its first line, shortened.
            guard let line = c?.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces),
                  !line.isEmpty, line != "/" else { continue }
            return line.count > 60 ? String(line.prefix(59)) + "…" : line
        }
        return "cmux \(index)"
    }

    static func convert(_ ws: Workspace, agents: inout Int, tiles: inout Int) -> SessionWorkspace? {
        let panels = Dictionary((ws.panels ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var key = 0
        var focused: Int?
        func tile(_ p: Panel) -> SessionTile? {
            var t: SessionTile
            switch p.type {
            case "terminal":
                let term = p.terminal
                t = SessionTile(kind: "terminal", cwd: p.directory ?? term?.workingDirectory ?? ws.currentDirectory)
                // An agent that had exited left a plain shell; cmux doesn't resume those either.
                if let a = term?.agent, let kind = a.kind, !kind.isEmpty, let id = a.sessionId, !id.isEmpty,
                   term?.wasAgentRunning == true {
                    t.agent = SessionAgent(kind: kind, session: id)
                    // The agent finds its session from here.
                    if let c = a.workingDirectory { t.cwd = c }
                    agents += 1
                }
            case "browser":
                guard let url = p.browser?.urlString, !url.isEmpty else { return nil }
                t = SessionTile(kind: "web", url: url)
            case "markdown":
                // A web tile on a markdown file is the markdown viewer.
                guard let path = p.markdown?.filePath, !path.isEmpty else { return nil }
                t = SessionTile(kind: "web", url: URL(fileURLWithPath: path).absoluteString)
            default:
                return nil
            }
            key += 1
            t.key = key
            if p.id == ws.focusedPanelId { focused = key }
            tiles += 1
            return t
        }
        func node(_ n: Node) -> SessionNode? {
            switch n {
            case .pane(let ids, let selected):
                var tabs: [SessionTile] = []
                var active = 0
                for id in ids {
                    guard let p = panels[id], let t = tile(p) else { continue }
                    if id == selected { active = tabs.count }
                    tabs.append(t)
                }
                return tabs.isEmpty ? nil : .slot(SessionSlot(tabs: tabs, active: active))
            case .split(let horizontal, let divider, let first, let second):
                let a = node(first), b = node(second)
                guard let a, let b else { return a ?? b }
                // cmux: the first child's share, 0...1. Hyprmux: 1 is even, the first child
                // gets ratio/2 of the space.
                let ratio = (DwindleLayout.clamp(2 * divider) * 10_000).rounded() / 10_000
                return .split(vertical: !horizontal, ratio: ratio, first: a, second: b)
            case .unknown:
                return nil
            }
        }
        guard let layout = ws.layout, let tree = node(layout) else { return nil }
        var w = SessionWorkspace(id: "", tiled: tree)
        w.focused = focused
        return w
    }

    // MARK: The cmux schema (only what's imported)

    struct Snapshot: Decodable {
        var version: Int?
        var windows: [Window]?
    }

    struct Window: Decodable {
        var tabManager: TabManager?
    }

    struct TabManager: Decodable {
        var workspaces: [Workspace]?
    }

    struct Workspace: Decodable {
        var customTitle: String?
        var gitBranch: String?
        var currentDirectory: String?
        var focusedPanelId: String?
        var layout: Node?
        var panels: [Panel]?

        enum CodingKeys: String, CodingKey { case customTitle, gitBranch, currentDirectory, focusedPanelId, layout, panels }
        struct Branch: Decodable { var branch: String? }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            customTitle = try? c.decodeIfPresent(String.self, forKey: .customTitle)
            // `{"branch": "main", "isDirty": false}`; a plain string is accepted too.
            gitBranch = (try? c.decodeIfPresent(Branch.self, forKey: .gitBranch))?.branch
                ?? (try? c.decodeIfPresent(String.self, forKey: .gitBranch))
            currentDirectory = try? c.decodeIfPresent(String.self, forKey: .currentDirectory)
            focusedPanelId = try? c.decodeIfPresent(String.self, forKey: .focusedPanelId)
            layout = try c.decodeIfPresent(Node.self, forKey: .layout)
            // One panel cmux added later and this can't read shouldn't lose the workspace.
            panels = (try? c.decodeIfPresent([Lenient<Panel>].self, forKey: .panels))?.compactMap(\.value)
        }
    }

    /// `{"type": "split", "split": {...}}` or `{"type": "pane", "pane": {...}}`.
    indirect enum Node: Decodable {
        case split(horizontal: Bool, divider: Double, first: Node, second: Node)
        case pane(ids: [String], selected: String?)
        case unknown

        enum CodingKeys: String, CodingKey { case type, split, pane }
        enum SplitKeys: String, CodingKey { case orientation, dividerPosition, first, second }
        enum PaneKeys: String, CodingKey { case panelIds, selectedPanelId }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decodeIfPresent(String.self, forKey: .type) {
            case "split":
                let s = try c.nestedContainer(keyedBy: SplitKeys.self, forKey: .split)
                // "horizontal" lays the children out left to right.
                self = .split(horizontal: (try s.decodeIfPresent(String.self, forKey: .orientation) ?? "horizontal") == "horizontal",
                              divider: try s.decodeIfPresent(Double.self, forKey: .dividerPosition) ?? 0.5,
                              first: try s.decode(Node.self, forKey: .first),
                              second: try s.decode(Node.self, forKey: .second))
            case "pane":
                let p = try c.nestedContainer(keyedBy: PaneKeys.self, forKey: .pane)
                self = .pane(ids: try p.decodeIfPresent([String].self, forKey: .panelIds) ?? [],
                             selected: try p.decodeIfPresent(String.self, forKey: .selectedPanelId))
            default:
                self = .unknown
            }
        }
    }

    struct Panel: Decodable {
        var id: String
        var type: String
        var directory: String?
        var terminal: Terminal?
        var browser: Browser?
        var markdown: Markdown?
    }

    struct Terminal: Decodable {
        var workingDirectory: String?
        var wasAgentRunning: Bool?
        var agent: Agent?
    }

    struct Agent: Decodable {
        var kind: String?
        var sessionId: String?
        var workingDirectory: String?
    }

    struct Browser: Decodable {
        var urlString: String?
    }

    struct Markdown: Decodable {
        var filePath: String?
    }

    /// Decodes to nil instead of failing the whole list.
    struct Lenient<T: Decodable>: Decodable {
        var value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }
}
