import Foundation

// Adapters lift apps that don't speak the client protocol (docs/ADAPTERS.md). An adapter
// is a manifest plus an executable that is itself a protocol client: Hyprmux runs it in
// place of the app, and it translates the app's windows into toplevels.

/// One adapter manifest, a JSON file in an adapters directory.
public struct AdapterManifest: Equatable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    /// Bundle identifiers, any of which matches. A trailing `*` matches a prefix.
    public var bundleIDs: [String]
    /// Paths inside the bundle that must all exist.
    public var bundleFiles: [String]
    /// The executable: absolute, relative to the manifest (contains `/`), or a bare name
    /// looked up in the adapter bin directories.
    public var exec: String
    /// Arguments. `{app}` is the bundle path; an `{args}` element splices the user's
    /// arguments. Default: `["{app}", "{args}"]`.
    public var args: [String]
    /// Probe arguments, same placeholders. The probe prints `{"ok": Bool, "reason": …}`.
    public var probe: [String]?
    /// Higher wins when several adapters match one app.
    public var priority: Int
    /// A disabled manifest turns off the adapter with the same id.
    public var disabled: Bool

    public init(id: String, name: String = "", description: String = "", bundleIDs: [String] = [],
                bundleFiles: [String] = [], exec: String = "", args: [String] = ["{app}", "{args}"],
                probe: [String]? = nil, priority: Int = 0, disabled: Bool = false) {
        self.id = id
        self.name = name.isEmpty ? id : name
        self.description = description
        self.bundleIDs = bundleIDs
        self.bundleFiles = bundleFiles
        self.exec = exec
        self.args = args
        self.probe = probe
        self.priority = priority
        self.disabled = disabled
    }

    static let keys: Set<String> = ["id", "name", "description", "match", "exec", "args", "probe", "priority", "disabled"]
    static let matchKeys: Set<String> = ["bundleIds", "bundleFiles"]

    /// Parses and validates a manifest. Errors name the offending field.
    public static func parse(_ data: Data) -> Result<AdapterManifest, ParseError> {
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
        func strings(_ v: Any?, _ name: String) -> Result<[String]?, ParseError> {
            guard let v else { return .success(nil) }
            guard let a = v as? [String] else { return .failure(ParseError("\"\(name)\" must be an array of strings")) }
            return .success(a)
        }
        // JSON numbers and booleans are both NSNumber, and Swift bridges 0 and 1 to Bool.
        // Tell them apart by CoreFoundation type.
        func isBool(_ v: Any) -> Bool { CFGetTypeID(v as CFTypeRef) == CFBooleanGetTypeID() }
        var m = AdapterManifest(id: id)
        if let v = o["disabled"] {
            guard isBool(v), let b = v as? Bool else { return .failure(ParseError("\"disabled\" must be true or false")) }
            m.disabled = b
        }
        if let v = o["name"] {
            guard let s = v as? String else { return .failure(ParseError("\"name\" must be a string")) }
            m.name = s.isEmpty ? id : s
        }
        if let v = o["description"] {
            guard let s = v as? String else { return .failure(ParseError("\"description\" must be a string")) }
            m.description = s
        }
        if let v = o["priority"] {
            guard !isBool(v), let n = v as? Int else { return .failure(ParseError("\"priority\" must be an integer")) }
            m.priority = n
        }
        // A manifest that only disables another needs nothing else.
        if m.disabled, o["exec"] == nil, o["match"] == nil { return .success(m) }

        guard let exec = o["exec"] as? String, !exec.isEmpty else { return .failure(ParseError("\"exec\" is required")) }
        m.exec = exec
        switch strings(o["args"], "args") {
        case .failure(let e): return .failure(e)
        case .success(let a): if let a { m.args = a }
        }
        switch strings(o["probe"], "probe") {
        case .failure(let e): return .failure(e)
        case .success(let a): m.probe = a
        }
        guard let match = o["match"] as? [String: Any] else { return .failure(ParseError("\"match\" is required")) }
        if let unknown = Set(match.keys).subtracting(matchKeys).sorted().first {
            return .failure(ParseError("unknown key \"match.\(unknown)\""))
        }
        switch strings(match["bundleIds"], "match.bundleIds") {
        case .failure(let e): return .failure(e)
        case .success(let a): m.bundleIDs = a ?? []
        }
        switch strings(match["bundleFiles"], "match.bundleFiles") {
        case .failure(let e): return .failure(e)
        case .success(let a): m.bundleFiles = a ?? []
        }
        // An empty match would claim every app.
        guard !m.bundleIDs.isEmpty || !m.bundleFiles.isEmpty else {
            return .failure(ParseError("\"match\" needs bundleIds or bundleFiles"))
        }
        return .success(m)
    }

    /// Whether this manifest matches an app, and if not, why.
    public func matches(bundleID: String?, fileExists: (String) -> Bool) -> (Bool, String) {
        if !bundleIDs.isEmpty {
            guard let bundleID, !bundleID.isEmpty else { return (false, "app has no bundle id") }
            let hit = bundleIDs.contains { pattern in
                pattern.hasSuffix("*")
                    ? bundleID.lowercased().hasPrefix(pattern.dropLast().lowercased())
                    : bundleID.caseInsensitiveCompare(pattern) == .orderedSame
            }
            guard hit else { return (false, "bundle id \(bundleID) isn't \(bundleIDs.joined(separator: ", "))") }
        }
        if let missing = bundleFiles.first(where: { !fileExists($0) }) {
            return (false, "no \(missing) in the bundle")
        }
        var why: [String] = []
        if let bundleID, !bundleIDs.isEmpty { why.append("bundle id \(bundleID)") }
        if !bundleFiles.isEmpty { why.append("has \(bundleFiles.joined(separator: ", "))") }
        return (true, why.joined(separator: "; "))
    }

    /// `args` (or `probe`) with placeholders filled in.
    public static func expand(_ template: [String], app: String, args: [String]) -> [String] {
        template.flatMap { word -> [String] in
            if word == "{args}" { return args }
            return [word.replacingOccurrences(of: "{app}", with: app)]
        }
    }
}

/// Where a manifest came from. Later sources override earlier ones by id.
public enum AdapterSource: String, Sendable, CaseIterable {
    case builtin, user
}

/// A loaded manifest and what Hyprmux made of it.
public struct AdapterEntry: Sendable {
    public var manifest: AdapterManifest
    public var source: AdapterSource
    public var path: String
    /// The resolved executable, when found.
    public var executable: String?
    /// Why the adapter can't be used, when it can't.
    public var problem: String?
    /// The manifest this one overrides, if any.
    public var overrides: String?

    public var id: String { manifest.id }
    public var state: String { manifest.disabled ? "disabled" : problem == nil ? "ready" : "error" }
    public var usable: Bool { state == "ready" }

    public var json: [String: Any] {
        var o: [String: Any] = [
            "id": id, "name": manifest.name, "source": source.rawValue, "path": path,
            "state": state, "priority": manifest.priority,
        ]
        if !manifest.description.isEmpty { o["description"] = manifest.description }
        var match: [String: Any] = [:]
        if !manifest.bundleIDs.isEmpty { match["bundleIds"] = manifest.bundleIDs }
        if !manifest.bundleFiles.isEmpty { match["bundleFiles"] = manifest.bundleFiles }
        if !match.isEmpty { o["match"] = match }
        if !manifest.exec.isEmpty { o["exec"] = manifest.exec }
        if let executable { o["executable"] = executable }
        if let problem { o["problem"] = problem }
        if let overrides { o["overrides"] = overrides }
        return o
    }
}

/// Every adapter Hyprmux knows about, from the adapter directories.
public struct AdapterRegistry: Sendable {
    public struct Directory: Sendable {
        public var source: AdapterSource
        public var path: String
        public var exists: Bool
    }

    public struct LoadError: Sendable {
        public var path: String
        public var message: String
    }

    /// The effective adapters, highest priority first.
    public private(set) var entries: [AdapterEntry] = []
    /// Manifests another source replaced.
    public private(set) var overridden: [AdapterEntry] = []
    public private(set) var errors: [LoadError] = []
    public private(set) var directories: [Directory] = []
    public private(set) var loadedAt = Date()

    public init() {}

    /// Loads `*.json` from each directory, in order. `binDirectories` resolve bare
    /// executable names, first match wins.
    public static func load(directories: [(AdapterSource, String)], binDirectories: [String]) -> AdapterRegistry {
        var r = AdapterRegistry()
        var byID: [String: AdapterEntry] = [:]
        let fm = FileManager.default
        for (source, dir) in directories {
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: dir, isDirectory: &isDir) && isDir.boolValue
            r.directories.append(Directory(source: source, path: dir, exists: exists))
            guard exists, let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in names.sorted() where name.hasSuffix(".json") {
                let path = (dir as NSString).appendingPathComponent(name)
                guard let data = fm.contents(atPath: path) else {
                    r.errors.append(LoadError(path: path, message: "can't read the file"))
                    continue
                }
                switch AdapterManifest.parse(data) {
                case .failure(let e):
                    r.errors.append(LoadError(path: path, message: e.message))
                case .success(let manifest):
                    var entry = AdapterEntry(manifest: manifest, source: source, path: path)
                    if let previous = byID[manifest.id] {
                        if previous.source == source {
                            r.errors.append(LoadError(path: path, message: "duplicate id \"\(manifest.id)\", also in \(previous.path)"))
                            continue
                        }
                        entry.overrides = previous.path
                        r.overridden.append(previous)
                        // A disable-only manifest keeps the original's details for display.
                        if manifest.disabled, manifest.exec.isEmpty {
                            var m = previous.manifest
                            m.disabled = true
                            entry.manifest = m
                        }
                    }
                    byID[manifest.id] = entry
                }
            }
        }
        r.entries = byID.values.map { e in
            var e = e
            guard !e.manifest.disabled else { return e }
            let resolved = resolveExecutable(e.manifest.exec, manifestDir: (e.path as NSString).deletingLastPathComponent,
                                             binDirectories: binDirectories)
            e.executable = resolved
            if resolved == nil { e.problem = "executable \(e.manifest.exec) not found" }
            return e
        }.sorted { ($0.manifest.priority, $1.id) > ($1.manifest.priority, $0.id) }
        r.loadedAt = Date()
        return r
    }

    static func resolveExecutable(_ exec: String, manifestDir: String, binDirectories: [String]) -> String? {
        let fm = FileManager.default
        let expanded = (exec as NSString).expandingTildeInPath
        let candidates: [String]
        if expanded.hasPrefix("/") {
            candidates = [expanded]
        } else if expanded.contains("/") {
            candidates = [(manifestDir as NSString).appendingPathComponent(expanded)]
        } else {
            candidates = (binDirectories + [manifestDir]).map { ($0 as NSString).appendingPathComponent(expanded) }
        }
        return candidates.map { ($0 as NSString).standardizingPath }.first { fm.isExecutableFile(atPath: $0) }
    }

    public struct Candidate: Sendable {
        public var entry: AdapterEntry
        public var matched: Bool
        public var reason: String
    }

    /// Which adapters match an app, in priority order, and which one Hyprmux would use:
    /// the first usable match.
    public func match(bundleID: String?, fileExists: (String) -> Bool) -> (candidates: [Candidate], selected: AdapterEntry?) {
        var candidates: [Candidate] = []
        var selected: AdapterEntry?
        for e in entries {
            var (ok, reason) = e.manifest.matches(bundleID: bundleID, fileExists: fileExists)
            if ok, !e.usable {
                reason += e.manifest.disabled ? " (disabled)" : " (\(e.problem ?? "unusable"))"
            }
            candidates.append(Candidate(entry: e, matched: ok, reason: reason))
            if ok, e.usable, selected == nil { selected = e }
        }
        return (candidates, selected)
    }

    public func entry(_ id: String) -> AdapterEntry? { entries.first { $0.id == id } }
}
