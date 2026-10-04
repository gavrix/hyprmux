import Foundation

/// A rectangle in Hyprmux's monitor coordinates (top-left origin).
public struct TourRect: Equatable, Sendable {
    public var x, y, width, height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
}

/// One tile, as `hyprmuxctl clients` reports it.
public struct TourSurface: Equatable, Sendable {
    public struct Group: Equatable, Sendable {
        public var members: [UInt64]
        public var active: UInt64

        public init(members: [UInt64], active: UInt64) {
            self.members = members
            self.active = active
        }
    }

    public var id: UInt64
    /// "1", "2", ... or "special:NAME".
    public var workspace: String
    public var floating: Bool
    /// 0 = fullscreen, 1 = maximized, nil = neither.
    public var fullscreen: Int?
    public var focused: Bool
    public var visible: Bool
    public var frame: TourRect
    public var kind: String
    /// Web tiles only: the page's address.
    public var url: String?
    public var group: Group?

    public init(id: UInt64, workspace: String = "1", floating: Bool = false, fullscreen: Int? = nil,
                focused: Bool = false, visible: Bool = true, frame: TourRect = TourRect(x: 0, y: 0, width: 100, height: 100),
                kind: String = "terminal", url: String? = nil, group: Group? = nil) {
        self.id = id
        self.workspace = workspace
        self.floating = floating
        self.fullscreen = fullscreen
        self.focused = focused
        self.visible = visible
        self.frame = frame
        self.kind = kind
        self.url = url
        self.group = group
    }

    /// The regular workspace number, nil for the scratchpad.
    public var workspaceNumber: Int? { Int(workspace) }
    public var inScratchpad: Bool { workspace.hasPrefix("special:") }
}

/// One workspace, as `hyprmuxctl workspaces` reports it.
public struct TourWorkspace: Equatable, Sendable {
    public var id: String
    public var windows: Int
    public var active: Bool

    public init(id: String, windows: Int, active: Bool) {
        self.id = id
        self.windows = windows
        self.active = active
    }
}

/// What the tour knows about Hyprmux at one moment: the `clients` and `workspaces`
/// replies it fetches after each event. The tour never changes Hyprmux's state itself.
public struct TourWorld: Equatable, Sendable {
    public var surfaces: [TourSurface]
    public var workspaces: [TourWorkspace]
    /// Whether Hyprmux is the front app, from `appactive` events. Nil before the first one.
    public var appActive: Bool?

    public init(surfaces: [TourSurface] = [], workspaces: [TourWorkspace] = [], appActive: Bool? = nil) {
        self.surfaces = surfaces
        self.workspaces = workspaces
        self.appActive = appActive
    }

    public func surface(_ id: UInt64) -> TourSurface? { surfaces.first { $0.id == id } }
    public var focused: TourSurface? { surfaces.first { $0.focused } }
    public var ids: Set<UInt64> { Set(surfaces.map(\.id)) }

    /// The regular workspace on screen.
    public var activeWorkspace: Int? {
        workspaces.first { $0.active && Int($0.id) != nil }.flatMap { Int($0.id) }
    }

    /// The scratchpad on screen, if one is.
    public var scratchpadVisible: Bool {
        workspaces.contains { $0.active && $0.id.hasPrefix("special:") }
    }

    public func surfaces(on workspace: String) -> [TourSurface] {
        surfaces.filter { $0.workspace == workspace }
    }

    /// Workspace numbers that hold tiles.
    public var occupiedWorkspaces: Set<Int> { Set(surfaces.compactMap(\.workspaceNumber)) }

    // MARK: Decoding

    public enum DecodeError: Error, Equatable {
        case notJSON(String)
    }

    /// Builds a world from the JSON replies of `clients` and `workspaces`.
    public static func decode(clients: Data, workspaces: Data, appActive: Bool? = nil) throws -> TourWorld {
        guard let list = try? JSONSerialization.jsonObject(with: clients) as? [[String: Any]] else {
            throw DecodeError.notJSON(String(decoding: clients.prefix(200), as: UTF8.self))
        }
        guard let ws = try? JSONSerialization.jsonObject(with: workspaces) as? [[String: Any]] else {
            throw DecodeError.notJSON(String(decoding: workspaces.prefix(200), as: UTF8.self))
        }
        var world = TourWorld(appActive: appActive)
        world.surfaces = list.compactMap(surface)
        world.workspaces = ws.compactMap { w in
            guard let id = w["id"] as? String else { return nil }
            return TourWorkspace(id: id, windows: (w["windows"] as? NSNumber)?.intValue ?? 0,
                                 active: (w["active"] as? Bool) ?? false)
        }
        return world
    }

    private static func number(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

    private static func surface(_ c: [String: Any]) -> TourSurface? {
        guard let id = (c["id"] as? NSNumber)?.uint64Value else { return nil }
        let at = (c["at"] as? [Any])?.compactMap(number) ?? []
        let size = (c["size"] as? [Any])?.compactMap(number) ?? []
        let frame = TourRect(x: at.first ?? 0, y: at.count > 1 ? at[1] : 0,
                             width: size.first ?? 0, height: size.count > 1 ? size[1] : 0)
        var group: TourSurface.Group?
        if let g = c["group"] as? [String: Any] {
            let members = (g["members"] as? [Any])?.compactMap { ($0 as? NSNumber)?.uint64Value } ?? []
            group = TourSurface.Group(members: members, active: (g["active"] as? NSNumber)?.uint64Value ?? 0)
        }
        return TourSurface(
            id: id,
            workspace: c["workspace"] as? String ?? "",
            floating: (c["floating"] as? Bool) ?? false,
            fullscreen: (c["fullscreen"] as? NSNumber)?.intValue,
            focused: (c["focused"] as? Bool) ?? false,
            visible: (c["visible"] as? Bool) ?? false,
            frame: frame,
            kind: c["kind"] as? String ?? "",
            url: c["url"] as? String,
            group: group)
    }
}
