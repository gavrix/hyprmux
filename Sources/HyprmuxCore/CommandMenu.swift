import Foundation

/// `picker, menu`: one list that opens every other picker and a few common actions.
/// Each row shows the bind that runs the same thing, so the menu teaches the shortcuts.
public enum CommandMenu {
    /// What a row needs before it can run. Rows that can't run are left out.
    public enum Requirement: Equatable, Sendable {
        case none
        /// A focused window (moving it to a workspace).
        case window
        /// A focused browser or terminal tile (credential fill).
        case credentialTile
    }

    public struct Entry: Equatable, Sendable {
        public var id: String
        public var title: String
        public var dispatcher: Dispatcher
        /// Other dispatchers that do the same thing, for finding the row's bind.
        public var aliases: [Dispatcher]
        public var requires: Requirement

        init(_ id: String, _ title: String, _ dispatcher: Dispatcher, aliases: [Dispatcher] = [],
             requires: Requirement = .none) {
            self.id = id
            self.title = title
            self.dispatcher = dispatcher
            self.aliases = aliases
            self.requires = requires
        }
    }

    /// What the app knows about the focused tile when the menu opens.
    public struct Context: Equatable, Sendable {
        public var hasWindow: Bool
        public var hasCredentialTile: Bool

        public init(hasWindow: Bool, hasCredentialTile: Bool) {
            self.hasWindow = hasWindow
            self.hasCredentialTile = hasCredentialTile
        }
    }

    /// The rows, in menu order. A trailing "…" means the row opens another picker.
    public static let entries: [Entry] = [
        Entry("workspace", "Go to workspace…", .picker(.workspace)),
        Entry("movetoworkspace", "Move window to workspace…", .picker(.moveToWorkspace), requires: .window),
        Entry("movetoworkspacesilent", "Send window to workspace…", .picker(.moveToWorkspaceSilent), requires: .window),
        Entry("renameworkspace", "Name workspace…", .picker(.renameWorkspace)),
        Entry("layout", "Open layout…", .picker(.layout)),
        Entry("savelayout", "Save workspace as layout…", .picker(.saveLayout)),
        Entry("apps", "Open app…", .picker(.apps), aliases: [.launch("")]),
        Entry("terminal", "New terminal", .exec("")),
        Entry("web", "New web tile", .web("")),
        Entry("device", "Show device…", .sim("")),
        Entry("fillcredential", "Fill credential…", .fillCredential(nil), requires: .credentialTile),
        Entry("reload", "Reload config", .reload),
        Entry("exit", "Quit Hyprmux", .exit),
    ]

    /// Picker rows for the entries that can run now. The detail is the bind, if any.
    public static func items(binds: [KeyBind], context: Context) -> [PickerItem] {
        entries.filter { available($0, context) }.map {
            PickerItem(id: $0.id, title: $0.title, detail: chord(for: $0, in: binds) ?? "")
        }
    }

    public static func dispatcher(for id: String) -> Dispatcher? {
        entries.first { $0.id == id }?.dispatcher
    }

    static func available(_ e: Entry, _ c: Context) -> Bool {
        switch e.requires {
        case .none: true
        case .window: c.hasWindow
        case .credentialTile: c.hasCredentialTile
        }
    }

    /// The first key bind outside submaps that runs the entry, written like ⇧⌘P.
    static func chord(for e: Entry, in binds: [KeyBind]) -> String? {
        let wanted = [e.dispatcher] + e.aliases
        guard let b = binds.first(where: { b in
            guard b.submap == "reset", case .key = b.trigger else { return false }
            return wanted.contains(b.dispatcher)
        }) else { return nil }
        return KeyChord.display(b.mods, b.trigger)
    }
}
