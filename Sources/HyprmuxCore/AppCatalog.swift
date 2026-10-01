import Foundation

/// Every `.hmapp` Hyprmux can open: the generated folder, then the installed one. An
/// installed app with a generated one's id replaces it. Files that don't load are
/// listed with the reason, like adapter manifests.
public struct AppCatalog: Sendable {
    public struct Directory: Sendable {
        public var source: HMAppSource
        public var path: String
        public var exists: Bool
    }

    public struct LoadError: Sendable, Equatable {
        public var path: String
        public var message: String
    }

    /// The effective apps, by name.
    public private(set) var apps: [HMApp] = []
    /// Generated apps an installed one replaced.
    public private(set) var overridden: [HMApp] = []
    public private(set) var errors: [LoadError] = []
    public private(set) var directories: [Directory] = []
    public private(set) var loadedAt = Date()

    public init() {}

    /// Loads `*.hmapp` folders from each directory, in order. Later sources win.
    public static func load(directories: [(HMAppSource, String)]) -> AppCatalog {
        var c = AppCatalog()
        var byID: [String: HMApp] = [:]
        let fm = FileManager.default
        for (source, dir) in directories {
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: dir, isDirectory: &isDir) && isDir.boolValue
            c.directories.append(Directory(source: source, path: dir, exists: exists))
            guard exists, let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in names.sorted() where (name as NSString).pathExtension == HMApp.pathExtension {
                let path = (dir as NSString).appendingPathComponent(name)
                guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
                    c.errors.append(LoadError(path: path, message: "not a folder"))
                    continue
                }
                switch HMApp.load(path, source: source) {
                case .failure(let e):
                    c.errors.append(LoadError(path: path, message: e.message))
                case .success(var app):
                    if let previous = byID[app.id] {
                        if previous.source == source {
                            c.errors.append(LoadError(path: path, message: "duplicate id \"\(app.id)\", also in \(previous.path)"))
                            continue
                        }
                        app.overrides = previous.path
                        c.overridden.append(previous)
                    }
                    byID[app.id] = app
                }
            }
        }
        c.apps = byID.values.sorted(by: Self.byName)
        c.loadedAt = Date()
        return c
    }

    static func byName(_ a: HMApp, _ b: HMApp) -> Bool {
        let order = a.name.localizedStandardCompare(b.name)
        return order == .orderedSame ? a.id < b.id : order == .orderedAscending
    }

    public func app(id: String) -> HMApp? { apps.first { $0.id == id } }

    /// `launch NAME|ID`: an exact id first, then a name, ignoring case.
    public func find(_ nameOrID: String) -> HMApp? {
        app(id: nameOrID)
            ?? apps.first { $0.name.caseInsensitiveCompare(nameOrID) == .orderedSame }
            ?? apps.first { $0.id.caseInsensitiveCompare(nameOrID) == .orderedSame }
    }

    /// Launcher order: the most recent launches first, then by name.
    public func launcherOrder(recent: [String: Date]) -> [HMApp] {
        apps.sorted { a, b in
            switch (recent[a.id], recent[b.id]) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return Self.byName(a, b)
            }
        }
    }
}
