import Foundation

// Hooks: commands Hyprmux runs when an event happens (docs/HOOKS.md). A hook is a JSON
// manifest in a hooks directory: the app bundle's, then the user's next to the config.

/// How a hook's command runs.
public enum HookRun: String, Sendable, CaseIterable {
    /// In the background, with the event in its environment. Output goes to the log.
    case exec
    /// Typed into a new terminal's shell, so the shell stays when the command ends.
    /// Lifecycle events only: a terminal on every `openwindow` would never stop.
    case terminal
}

public enum HookSource: String, Sendable, CaseIterable {
    case builtin, user
}

public struct HookManifest: Equatable, Sendable {
    public var id: String
    public var description: String
    /// Event names (`HyprmuxEvent.names`).
    public var on: [String]
    public var run: HookRun
    /// A shell command line (`/bin/sh -c` for exec).
    public var command: String
    /// A disabled manifest turns off the hook with the same id.
    public var disabled: Bool

    public init(id: String, description: String = "", on: [String], run: HookRun = .exec, command: String,
                disabled: Bool = false) {
        self.id = id
        self.description = description
        self.on = on
        self.run = run
        self.command = command
        self.disabled = disabled
    }

    static let keys: Set<String> = ["id", "description", "on", "run", "command", "disabled"]

    /// Parses and validates a manifest. Errors name the offending field.
    public static func parse(_ data: Data) -> Result<HookManifest, ParseError> {
        guard let any = try? JSONSerialization.jsonObject(with: data), let o = any as? [String: Any] else {
            return .failure(ParseError("not a JSON object"))
        }
        if let unknown = Set(o.keys).subtracting(keys).sorted().first {
            return .failure(ParseError("unknown key \"\(unknown)\""))
        }
        guard let id = o["id"] as? String, !id.isEmpty else { return .failure(ParseError("\"id\" is required")) }
        guard id.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }), id.first?.isLetter == true else {
            return .failure(ParseError("\"id\" must start with a letter and use letters, digits, . _ -"))
        }
        if o["disabled"] != nil, !(o["disabled"] is Bool) { return .failure(ParseError("\"disabled\" must be true or false")) }
        let disabled = (o["disabled"] as? Bool) ?? false
        if o["description"] != nil, !(o["description"] is String) {
            return .failure(ParseError("\"description\" must be a string"))
        }
        // A disable-only manifest needs nothing else.
        if disabled, o["on"] == nil, o["command"] == nil {
            return .success(HookManifest(id: id, description: o["description"] as? String ?? "", on: [], command: "",
                                         disabled: true))
        }
        var on: [String]
        switch o["on"] {
        case let s as String: on = [s]
        case let a as [Any]:
            guard let strings = a as? [String] else { return .failure(ParseError("\"on\" must be event names")) }
            on = strings
        default: return .failure(ParseError("\"on\" is required: an event name or a list of them"))
        }
        on = on.map { $0.trimmingCharacters(in: .whitespaces) }
        guard !on.isEmpty else { return .failure(ParseError("\"on\" is empty")) }
        if let bad = on.first(where: { !HyprmuxEvent.names.contains($0) }) {
            return .failure(ParseError("\"on\": unknown event \"\(bad)\""))
        }
        let run: HookRun
        switch o["run"] {
        case nil: run = .exec
        case let s as String:
            guard let r = HookRun(rawValue: s) else { return .failure(ParseError("\"run\" must be exec or terminal")) }
            run = r
        default: return .failure(ParseError("\"run\" must be exec or terminal"))
        }
        if run == .terminal, let bad = on.first(where: { !HyprmuxEvent.lifecycle.contains($0) }) {
            return .failure(ParseError("\"run\": terminal hooks run on launch or firstlaunch only, not \"\(bad)\""))
        }
        guard let command = o["command"] as? String,
              !command.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .failure(ParseError("\"command\" is required"))
        }
        return .success(HookManifest(id: id, description: o["description"] as? String ?? "", on: on, run: run,
                                     command: command, disabled: disabled))
    }
}

/// A loaded manifest and where it came from.
public struct HookEntry: Sendable {
    public var manifest: HookManifest
    public var source: HookSource
    public var path: String
    /// The manifest this one replaced (a user hook with a built-in's id).
    public var overrides: String?

    public var id: String { manifest.id }
}

/// Every hook Hyprmux knows about.
public struct HookRegistry: Sendable {
    public struct LoadError: Sendable, Equatable {
        public var path: String
        public var message: String
    }

    /// Effective hooks by id, disabled ones included.
    public private(set) var entries: [HookEntry] = []
    public private(set) var errors: [LoadError] = []

    public init() {}

    /// Loads `*.json` from each directory, in order. A later source replaces an earlier
    /// one's hook with the same id.
    public static func load(directories: [(HookSource, String)]) -> HookRegistry {
        var r = HookRegistry()
        var byID: [String: HookEntry] = [:]
        let fm = FileManager.default
        for (source, dir) in directories {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in names.sorted() where name.hasSuffix(".json") {
                let path = (dir as NSString).appendingPathComponent(name)
                guard let data = fm.contents(atPath: path) else {
                    r.errors.append(LoadError(path: path, message: "can't read the file"))
                    continue
                }
                switch HookManifest.parse(data) {
                case .failure(let e):
                    r.errors.append(LoadError(path: path, message: e.message))
                case .success(let manifest):
                    var entry = HookEntry(manifest: manifest, source: source, path: path)
                    if let previous = byID[manifest.id] {
                        if previous.source == source {
                            r.errors.append(LoadError(path: path, message: "duplicate id \"\(manifest.id)\", also in \(previous.path)"))
                            continue
                        }
                        entry.overrides = previous.path
                    }
                    byID[manifest.id] = entry
                }
            }
        }
        r.entries = byID.values.sorted { $0.id < $1.id }
        return r
    }

    /// Enabled hooks for an event, in id order.
    public func hooks(for event: String) -> [HookEntry] {
        entries.filter { !$0.manifest.disabled && $0.manifest.on.contains(event) }
    }
}
