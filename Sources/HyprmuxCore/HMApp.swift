import Foundation

// A `.hmapp` is a folder bundle that only Hyprmux understands (docs/APPS.md): an
// `Info.json` that says how to open an app in a tile, an optional `icon.png`, and an
// optional payload. Hyprmux generates them for the apps it can lift, and users install
// their own. It isn't a macOS app, so Spotlight, Launchpad, and the Dock never list it.

/// The `Info.json` of a `.hmapp`, format 1.
public struct HMAppManifest: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        /// The target speaks the client protocol itself.
        case native
        /// An adapter lifts the target.
        case adapter
    }

    public static let format = 1
    /// `generatedBy` on bundles Hyprmux owns. Only these may be rewritten or deleted.
    public static let generator = "hyprmux"
    public static let defaultArgs = ["{args}"]

    public var id: String
    public var name: String
    public var kind: Kind
    /// The adapter id, for adapter-kind apps.
    public var adapter: String?
    /// Absolute path of the `.app` it opens or lifts.
    public var app: String?
    /// The target's `CFBundleShortVersionString`, when generated.
    public var version: String?
    /// The executable: absolute, relative to the bundle (contains `/`), or a bare name
    /// looked up in the adapter bin directories.
    public var exec: String?
    /// `{app}`, `{bundle}`, and an `{args}` element that splices the user's arguments.
    public var args: [String]
    public var generatedBy: String?

    public init(id: String, name: String, kind: Kind, adapter: String? = nil, app: String? = nil,
                version: String? = nil, exec: String? = nil, args: [String] = HMAppManifest.defaultArgs,
                generatedBy: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.adapter = adapter
        self.app = app
        self.version = version
        self.exec = exec
        self.args = args
        self.generatedBy = generatedBy
    }

    public var isGenerated: Bool { generatedBy == Self.generator }

    static let keys: Set<String> = ["format", "id", "name", "kind", "adapter", "app", "version", "exec", "args", "generatedBy"]

    /// Letters, digits, `.`, `_`, `-`.
    public static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { ($0.isLetter || $0.isNumber) && $0.isASCII || "._-".contains($0) }
    }

    /// Parses and validates `Info.json`. Unknown keys are errors, like adapter manifests.
    public static func parse(_ data: Data) -> Result<HMAppManifest, ParseError> {
        guard let any = try? JSONSerialization.jsonObject(with: data), let o = any as? [String: Any] else {
            return .failure(ParseError("not a JSON object"))
        }
        if let unknown = Set(o.keys).subtracting(keys).sorted().first {
            return .failure(ParseError("unknown key \"\(unknown)\""))
        }
        guard let format = o["format"] else { return .failure(ParseError("\"format\" is required")) }
        guard CFGetTypeID(format as CFTypeRef) != CFBooleanGetTypeID(), let n = format as? Int, n == Self.format else {
            return .failure(ParseError("\"format\" must be \(Self.format)"))
        }
        func string(_ key: String, required: Bool = false) -> Result<String?, ParseError> {
            guard let v = o[key] else {
                return required ? .failure(ParseError("\"\(key)\" is required")) : .success(nil)
            }
            guard let s = v as? String else { return .failure(ParseError("\"\(key)\" must be a string")) }
            guard !s.isEmpty else { return .failure(ParseError("\"\(key)\" must not be empty")) }
            return .success(s)
        }
        do {
            let id = try string("id", required: true).get()!
            guard isValidID(id) else { return .failure(ParseError("\"id\" must use letters, digits, . _ -")) }
            let name = try string("name", required: true).get()!
            let kindName = try string("kind", required: true).get()!
            guard let kind = Kind(rawValue: kindName) else {
                return .failure(ParseError("\"kind\" must be native or adapter"))
            }
            var m = HMAppManifest(id: id, name: name, kind: kind)
            m.adapter = try string("adapter").get()
            m.app = try string("app").get()
            m.version = try string("version").get()
            m.exec = try string("exec").get()
            m.generatedBy = try string("generatedBy").get()
            if let v = o["args"] {
                guard let a = v as? [String] else { return .failure(ParseError("\"args\" must be an array of strings")) }
                m.args = a
            }
            if kind == .adapter, m.adapter == nil {
                return .failure(ParseError("\"adapter\" is required when \"kind\" is adapter"))
            }
            if let app = m.app, !app.hasPrefix("/") {
                return .failure(ParseError("\"app\" must be an absolute path"))
            }
            guard m.exec != nil || m.app != nil else {
                return .failure(ParseError("needs \"exec\" or \"app\""))
            }
            return .success(m)
        } catch let e as ParseError {
            return .failure(e)
        } catch {
            return .failure(ParseError("\(error)"))
        }
    }

    /// `Info.json` bytes: sorted keys, so an unchanged manifest writes the same bytes.
    public func encoded() -> Data {
        var o: [String: Any] = ["format": Self.format, "id": id, "name": name, "kind": kind.rawValue]
        if let adapter { o["adapter"] = adapter }
        if let app { o["app"] = app }
        if let version { o["version"] = version }
        if let exec { o["exec"] = exec }
        if args != Self.defaultArgs { o["args"] = args }
        if let generatedBy { o["generatedBy"] = generatedBy }
        let data = (try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return data + Data("\n".utf8)
    }

    /// `args` with placeholders filled in. `{app}` is the target app, `{bundle}` the
    /// `.hmapp`, and an `{args}` element is replaced by the user's arguments.
    public static func expand(_ template: [String], app: String?, bundle: String, args: [String]) -> [String] {
        template.flatMap { word -> [String] in
            if word == "{args}" { return args }
            return [word.replacingOccurrences(of: "{app}", with: app ?? "")
                .replacingOccurrences(of: "{bundle}", with: bundle)]
        }
    }

    /// The executable's path, if it exists. Absolute names stand; names with a `/` are
    /// relative to the bundle; bare names resolve in `binDirectories`, then the bundle.
    public func resolveExecutable(bundle: String, binDirectories: [String]) -> String? {
        guard let exec else { return nil }
        return AdapterRegistry.resolveExecutable(exec, manifestDir: bundle, binDirectories: binDirectories)
    }
}

/// Where a `.hmapp` came from. An installed one with a generated one's id replaces it.
public enum HMAppSource: String, Sendable, CaseIterable {
    case generated, installed
}

/// A loaded `.hmapp`.
public struct HMApp: Equatable, Sendable {
    public var manifest: HMAppManifest
    /// The `.hmapp` folder.
    public var path: String
    public var source: HMAppSource
    /// The generated bundle this installed one replaces, if any.
    public var overrides: String?

    public init(manifest: HMAppManifest, path: String, source: HMAppSource, overrides: String? = nil) {
        self.manifest = manifest
        self.path = path
        self.source = source
        self.overrides = overrides
    }

    public var id: String { manifest.id }
    public var name: String { manifest.name }
    public static let infoFile = "Info.json"
    public static let iconFile = "icon.png"
    public static let pathExtension = "hmapp"

    public var iconPath: String { (path as NSString).appendingPathComponent(Self.iconFile) }

    /// Reads `PATH/Info.json`.
    public static func load(_ path: String, source: HMAppSource) -> Result<HMApp, ParseError> {
        let info = (path as NSString).appendingPathComponent(infoFile)
        guard let data = FileManager.default.contents(atPath: info) else {
            return .failure(ParseError("no \(infoFile)"))
        }
        return HMAppManifest.parse(data).map { HMApp(manifest: $0, path: path, source: source) }
    }

    /// Writes `manifest` as `PATH/Info.json`, creating the folder. Returns whether the
    /// bytes changed.
    @discardableResult
    public static func write(_ manifest: HMAppManifest, to path: String) throws -> Bool {
        let fm = FileManager.default
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        let info = (path as NSString).appendingPathComponent(infoFile)
        let data = manifest.encoded()
        if fm.contents(atPath: info) == data { return false }
        try data.write(to: URL(fileURLWithPath: info), options: .atomic)
        return true
    }

    /// The command line for a launch: the resolved executable, or nil to open `app`
    /// with `arguments`.
    public struct Command: Equatable, Sendable {
        public var executable: String?
        public var app: String?
        public var arguments: [String]
    }

    public func command(args: [String], binDirectories: [String]) -> Result<Command, ParseError> {
        let m = manifest
        let arguments = HMAppManifest.expand(m.args, app: m.app, bundle: path, args: args)
        if let exec = m.exec {
            guard let exe = m.resolveExecutable(bundle: path, binDirectories: binDirectories) else {
                return .failure(ParseError("\(m.name): executable \(exec) not found"))
            }
            return .success(Command(executable: exe, app: m.app, arguments: arguments))
        }
        guard let app = m.app else { return .failure(ParseError("\(m.name): needs exec or app")) }
        guard FileManager.default.fileExists(atPath: app) else {
            return .failure(ParseError("\(m.name): \(app) doesn't exist"))
        }
        return .success(Command(executable: nil, app: app, arguments: arguments))
    }

    /// Whether the executable is inside the bundle: code that came with it.
    public func carriesExecutable(_ executable: String) -> Bool {
        let base = (path as NSString).standardizingPath + "/"
        return (executable as NSString).standardizingPath.hasPrefix(base)
    }

    public var json: [String: Any] {
        let m = manifest
        var o: [String: Any] = ["id": m.id, "name": m.name, "kind": m.kind.rawValue, "source": source.rawValue,
                                "path": path, "args": m.args]
        if let a = m.adapter { o["adapter"] = a }
        if let a = m.app { o["app"] = a }
        if let v = m.version { o["version"] = v }
        if let e = m.exec { o["exec"] = e }
        if m.isGenerated { o["generatedBy"] = m.generatedBy }
        if let overrides { o["overrides"] = overrides }
        return o
    }

    /// `Zed (dev)` → `zed-dev`, for ids of installed apps that aren't `.app` bundles.
    public static func slug(_ name: String) -> String {
        var out = ""
        for c in name.lowercased() {
            if c.isASCII, c.isLetter || c.isNumber {
                out.append(c)
            } else if !out.isEmpty, out.last != "-" {
                out.append("-")
            }
        }
        while out.last == "-" { out.removeLast() }
        return out.isEmpty ? "app" : out
    }

    /// A folder name for `name`: no `/` or `:`.
    public static func folderName(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + "." + pathExtension
    }
}
