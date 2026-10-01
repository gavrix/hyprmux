import Foundation

// Generated apps (docs/APPS.md): Hyprmux scans the app folders, decides which apps it can
// open (native clients, and apps an adapter lifts and whose probe passes), and writes a
// `.hmapp` for each into its own folder. Users see apps, never adapters.

/// One `.app` found by a scan.
public struct ScannedApp: Equatable, Sendable {
    public var path: String
    public var bundleID: String?
    public var name: String
    public var version: String?
    /// `HyprmuxClient = true` in Info.plist: the app speaks the protocol itself.
    public var isClient: Bool

    public init(path: String, bundleID: String?, name: String, version: String? = nil, isClient: Bool = false) {
        self.path = path
        self.bundleID = bundleID
        self.name = name
        self.version = version
        self.isClient = isClient
    }
}

/// Finds `.app` bundles in fixed folders. No Spotlight, no running apps.
public enum AppScanner {
    public struct Folder: Equatable, Sendable {
        public var path: String
        /// Also look one level down, in folders that aren't apps (`/Applications/Google Meet/`).
        public var subfolders: Bool

        public init(_ path: String, subfolders: Bool = false) {
            self.path = path
            self.subfolders = subfolders
        }
    }

    public static func defaultFolders(home: String) -> [Folder] {
        let user = (home as NSString).appendingPathComponent("Applications")
        return [
            Folder("/Applications", subfolders: true),
            Folder("/Applications/Utilities"),
            Folder(user, subfolders: true),
            Folder("/System/Applications"),
            Folder("/System/Applications/Utilities"),
        ]
    }

    /// Every app in `folders`, in folder order, each path once.
    public static func scan(_ folders: [Folder]) -> [ScannedApp] {
        let fm = FileManager.default
        var seen = Set<String>()
        var found: [ScannedApp] = []
        func visit(_ path: String) {
            let key = (path as NSString).standardizingPath
            guard seen.insert(key).inserted, let app = read(path) else { return }
            found.append(app)
        }
        func isDirectory(_ path: String) -> Bool {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
        for folder in folders {
            guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names.sorted() where !name.hasPrefix(".") {
                let path = (folder.path as NSString).appendingPathComponent(name)
                if (name as NSString).pathExtension == "app" {
                    visit(path)
                } else if folder.subfolders, isDirectory(path), let inner = try? fm.contentsOfDirectory(atPath: path) {
                    for n in inner.sorted() where (n as NSString).pathExtension == "app" {
                        visit((path as NSString).appendingPathComponent(n))
                    }
                }
            }
        }
        return found
    }

    /// Reads one bundle's Info.plist. Nil when it has none.
    public static func read(_ path: String) -> ScannedApp? {
        let plist = (path as NSString).appendingPathComponent("Contents/Info.plist")
        guard let data = FileManager.default.contents(atPath: plist),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            return nil
        }
        func string(_ key: String) -> String? {
            (info[key] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        }
        let file = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let name = string("CFBundleDisplayName") ?? string("CFBundleName") ?? file
        return ScannedApp(path: path, bundleID: string("CFBundleIdentifier"), name: name,
                          version: string("CFBundleShortVersionString"), isClient: (info["HyprmuxClient"] as? Bool) == true)
    }
}

/// How Hyprmux would open an app.
public enum AppClassification: Sendable {
    case native
    case adapter(AdapterEntry)
    /// It can't open the app. The reason is for logs and `hyprmuxctl adapters match`.
    case none(String)
}

/// Writes and prunes the generated `.hmapp`s.
public enum AppGenerator {
    public struct ProbeOutcome: Codable, Equatable, Sendable {
        public var ok: Bool
        public var reason: String?
        public init(ok: Bool, reason: String? = nil) {
            self.ok = ok
            self.reason = reason
        }
    }

    /// One cached probe, in `probes.json`. A probe runs once per app version and adapter.
    struct CachedProbe: Codable, Equatable {
        var app: String
        var version: String?
        var adapter: String
        var ok: Bool
        var reason: String?
    }

    public struct Skip: Equatable, Sendable {
        public var app: String
        public var reason: String
    }

    public struct Report: Sendable {
        /// Ids of every generated app, after this run.
        public var apps: [String] = []
        /// Ids whose `Info.json` was written.
        public var written: [String] = []
        /// Bundles removed: their app vanished or no longer qualifies.
        public var deleted: [String] = []
        /// Apps Hyprmux can't open, and why.
        public var skipped: [Skip] = []
        /// Probes that ran (cache misses).
        public var probed = 0
        public var errors: [String] = []
        public var finishedAt = Date()
    }

    public static let probeCacheFile = "probes.json"

    /// `fileExists` takes absolute paths.
    public static func classify(_ app: ScannedApp, registry: AdapterRegistry,
                                fileExists: (String) -> Bool) -> AppClassification {
        if app.isClient { return .native }
        guard app.bundleID != nil else { return .none("no bundle id") }
        let (_, selected) = registry.match(bundleID: app.bundleID) { fileExists((app.path as NSString).appendingPathComponent($0)) }
        guard let selected else { return .none("no adapter matches") }
        return .adapter(selected)
    }

    /// The generated `Info.json` for an app.
    public static func manifest(for app: ScannedApp, adapter: AdapterEntry?) -> HMAppManifest {
        var m = HMAppManifest(id: app.bundleID ?? HMApp.slug(app.name), name: app.name, kind: adapter == nil ? .native : .adapter,
                              app: app.path, version: app.version, generatedBy: HMAppManifest.generator)
        if let adapter {
            m.adapter = adapter.id
            // A bare name keeps resolving in the bin directories, wherever Hyprmux lives.
            m.exec = adapter.manifest.exec.contains("/") ? (adapter.executable ?? adapter.manifest.exec) : adapter.manifest.exec
            m.args = adapter.manifest.args
        }
        return m
    }

    /// Generates `directory` from `apps`. `probe` runs an adapter's probe (cache misses
    /// only); `icon` returns PNG bytes for an app. Only bundles with `generatedBy:
    /// hyprmux` are rewritten or deleted; nothing else in the folder is touched.
    public static func generate(apps: [ScannedApp], registry: AdapterRegistry, directory: String,
                                probe: (AdapterEntry, ScannedApp) -> ProbeOutcome,
                                icon: (ScannedApp) -> Data?) -> Report {
        let fm = FileManager.default
        var report = Report()
        do {
            try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        } catch {
            report.errors.append("\(directory): \(error.localizedDescription)")
            return report
        }

        // What's there now: generated bundles by id, and every other folder name taken.
        var existing: [String: [String]] = [:]
        var foreign = Set<String>()
        for name in ((try? fm.contentsOfDirectory(atPath: directory)) ?? []).sorted() {
            let path = (directory as NSString).appendingPathComponent(name)
            guard (name as NSString).pathExtension == HMApp.pathExtension else { continue }
            if case .success(let app) = HMApp.load(path, source: .generated), app.manifest.isGenerated {
                existing[app.id, default: []].append(path)
            } else {
                foreign.insert(name.lowercased())
            }
        }

        let cachePath = (directory as NSString).appendingPathComponent(probeCacheFile)
        let oldCache = fm.contents(atPath: cachePath).flatMap { try? JSONDecoder().decode([CachedProbe].self, from: $0) } ?? []
        var cache: [CachedProbe] = []

        // Decide what each app becomes. First app per id wins (folder order).
        var desired: [(ScannedApp, HMAppManifest)] = []
        var ids = Set<String>()
        for app in apps {
            let adapter: AdapterEntry?
            switch classify(app, registry: registry, fileExists: { fm.fileExists(atPath: $0) }) {
            case .none(let why):
                report.skipped.append(Skip(app: app.path, reason: why))
                continue
            case .native:
                adapter = nil
            case .adapter(let a):
                adapter = a
                if a.manifest.probe != nil {
                    let outcome: ProbeOutcome
                    if let hit = oldCache.first(where: { $0.app == app.path && $0.version == app.version && $0.adapter == a.id }) {
                        outcome = ProbeOutcome(ok: hit.ok, reason: hit.reason)
                    } else {
                        outcome = probe(a, app)
                        report.probed += 1
                    }
                    cache.append(CachedProbe(app: app.path, version: app.version, adapter: a.id, ok: outcome.ok, reason: outcome.reason))
                    guard outcome.ok else {
                        report.skipped.append(Skip(app: app.path, reason: "\(a.id) probe failed: \(outcome.reason ?? "no reason")"))
                        continue
                    }
                }
            }
            let m = manifest(for: app, adapter: adapter)
            guard ids.insert(m.id).inserted else {
                report.skipped.append(Skip(app: app.path, reason: "another app has id \(m.id)"))
                continue
            }
            desired.append((app, m))
        }

        // Write. Folder names are case-insensitive on APFS.
        var taken = foreign
        for (app, m) in desired {
            var name = HMApp.folderName(m.name)
            let mine = Set((existing[m.id] ?? []).map { ($0 as NSString).lastPathComponent.lowercased() })
            if taken.contains(name.lowercased()) && !mine.contains(name.lowercased()) {
                name = HMApp.folderName("\(m.name) (\(m.id))")
            }
            guard !taken.contains(name.lowercased()) || mine.contains(name.lowercased()) else {
                report.skipped.append(Skip(app: app.path, reason: "folder \(name) is taken"))
                continue
            }
            taken.insert(name.lowercased())
            let path = (directory as NSString).appendingPathComponent(name)
            // The same app under an old name (renamed, or a name clash that went away).
            for old in existing[m.id] ?? [] where old != path {
                do {
                    try fm.removeItem(atPath: old)
                    report.deleted.append(old)
                } catch {
                    report.errors.append("\(old): \(error.localizedDescription)")
                }
            }
            existing[m.id] = nil
            do {
                let changed = try HMApp.write(m, to: path)
                if changed { report.written.append(m.id) }
                let iconPath = (path as NSString).appendingPathComponent(HMApp.iconFile)
                if changed || !fm.fileExists(atPath: iconPath), let png = icon(app) {
                    try png.write(to: URL(fileURLWithPath: iconPath), options: .atomic)
                }
                report.apps.append(m.id)
            } catch {
                report.errors.append("\(path): \(error.localizedDescription)")
            }
        }

        // Generated bundles for apps that vanished or no longer qualify.
        for path in existing.values.flatMap({ $0 }).sorted() {
            do {
                try fm.removeItem(atPath: path)
                report.deleted.append(path)
            } catch {
                report.errors.append("\(path): \(error.localizedDescription)")
            }
        }

        if cache != oldCache {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            if let data = try? encoder.encode(cache) {
                try? data.write(to: URL(fileURLWithPath: cachePath), options: .atomic)
            }
        }
        report.finishedAt = Date()
        return report
    }
}
