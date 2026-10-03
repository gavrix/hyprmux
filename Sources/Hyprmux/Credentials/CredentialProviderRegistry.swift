import Darwin
import Foundation
import HyprmuxCore

public enum CredentialProviderSource: String, Sendable {
    case builtin, user
}

public struct CredentialProviderEntry: Sendable {
    public var manifest: CredentialProviderManifest
    public var source: CredentialProviderSource
    public var path: String
    public var executable: String?
    public var problem: String?
    public var overrides: String?

    public var id: String { manifest.id }
    public var usable: Bool { !manifest.disabled && problem == nil && executable != nil }
}

public struct CredentialProviderRegistry: Sendable {
    public struct LoadError: Sendable {
        public let path: String
        public let message: String
    }

    public private(set) var entries: [CredentialProviderEntry] = []
    public private(set) var overridden: [CredentialProviderEntry] = []
    public private(set) var errors: [LoadError] = []

    public init() {}

    /// Loads directories in order. A later source overrides an earlier one by id.
    public static func load(directories: [(CredentialProviderSource, String)],
                            binDirectories: [String], bundlePath: String = Bundle.main.bundlePath) -> Self {
        var registry = Self()
        var byID: [String: CredentialProviderEntry] = [:]
        let manager = FileManager.default
        for (source, directory) in directories {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            if source == .user, let problem = trustProblem(directory) {
                registry.errors.append(.init(path: directory, message: "untrusted provider directory: \(problem)"))
                continue
            }
            guard let names = try? manager.contentsOfDirectory(atPath: directory) else { continue }
            for name in names.sorted() where name.hasSuffix(".json") {
                let path = (directory as NSString).appendingPathComponent(name)
                if source == .user, let problem = trustProblem(path) {
                    registry.errors.append(.init(path: path, message: "untrusted manifest: \(problem)"))
                    continue
                }
                guard let data = manager.contents(atPath: path) else {
                    registry.errors.append(.init(path: path, message: "can't read the file"))
                    continue
                }
                let manifest: CredentialProviderManifest
                switch CredentialProviderManifest.parse(data) {
                case .failure(let error):
                    registry.errors.append(.init(path: path, message: error.message))
                    continue
                case .success(let value): manifest = value
                }
                var entry = CredentialProviderEntry(manifest: manifest, source: source, path: path)
                if let previous = byID[manifest.id] {
                    if previous.source == source {
                        registry.errors.append(.init(path: path,
                                                     message: "duplicate id \"\(manifest.id)\", also in \(previous.path)"))
                        continue
                    }
                    entry.overrides = previous.path
                    registry.overridden.append(previous)
                    if manifest.disabled, manifest.exec.isEmpty {
                        var inherited = previous.manifest
                        inherited.disabled = true
                        entry.manifest = inherited
                    }
                }
                byID[manifest.id] = entry
            }
        }

        registry.entries = byID.values.map { original in
            var entry = original
            guard !entry.manifest.disabled else { return entry }
            let manifestDirectory = (entry.path as NSString).deletingLastPathComponent
            entry.executable = resolveExecutable(entry.manifest.exec, manifestDirectory: manifestDirectory,
                                                  binDirectories: binDirectories)
            guard let executable = entry.executable else {
                entry.problem = "executable \(entry.manifest.exec) not found"
                return entry
            }
            if let problem = executableTrustProblem(executable, source: entry.source, bundlePath: bundlePath) {
                entry.problem = "untrusted executable: \(problem)"
            }
            return entry
        }.sorted { $0.id < $1.id }
        return registry
    }

    public func entry(_ id: String) -> CredentialProviderEntry? { entries.first { $0.id == id } }
    public var usableEntries: [CredentialProviderEntry] { entries.filter(\.usable) }

    static func resolveExecutable(_ executable: String, manifestDirectory: String,
                                  binDirectories: [String]) -> String? {
        let manager = FileManager.default
        let expanded = (executable as NSString).expandingTildeInPath
        let candidates: [String]
        if expanded.hasPrefix("/") { candidates = [expanded] }
        else if expanded.contains("/") {
            candidates = [(manifestDirectory as NSString).appendingPathComponent(expanded)]
        } else {
            candidates = (binDirectories + [manifestDirectory]).map {
                ($0 as NSString).appendingPathComponent(expanded)
            }
        }
        return candidates.map { resolvedPath(($0 as NSString).standardizingPath) }
            .first { manager.isExecutableFile(atPath: $0) }
    }

    static func executableTrustProblem(_ executable: String, source: CredentialProviderSource,
                                       bundlePath: String = Bundle.main.bundlePath) -> String? {
        let resolvedExecutable = resolvedPath(executable)
        let resolvedBundle = resolvedPath(bundlePath)
        let isBundled = resolvedExecutable == resolvedBundle || resolvedExecutable.hasPrefix(resolvedBundle + "/")
        guard source == .user || !isBundled else { return nil }
        return trustProblem(resolvedExecutable)
    }

    /// Trusted files and directories may belong to this user or root and cannot be group/world writable.
    /// Symlinks are resolved before inspecting both the object and its immediate parent directory.
    static func trustProblem(_ path: String) -> String? {
        let resolved = resolvedPath(path)
        if let problem = permissionProblem(resolved) { return problem }
        let parent = (resolved as NSString).deletingLastPathComponent
        if let problem = permissionProblem(parent) { return "parent directory \(problem)" }
        return nil
    }

    private static func permissionProblem(_ path: String) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let owner = attributes[.ownerAccountID] as? NSNumber,
              let permissions = attributes[.posixPermissions] as? NSNumber else {
            return "can't be inspected for ownership and permissions"
        }
        guard owner.uint32Value == getuid() || owner.uint32Value == 0 else {
            return "is not owned by the current user or root"
        }
        if permissions.uint16Value & 0o022 != 0 { return "is writable by group or others" }
        return nil
    }

    private static func resolvedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
