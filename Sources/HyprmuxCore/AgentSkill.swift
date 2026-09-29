import Foundation

public enum AgentSkillStatus: Equatable, Sendable {
    case notInstalled
    case current
    case outdated
    case unmanaged
}

public enum AgentSkillError: Error, LocalizedError, Equatable {
    case sourceMissing(String)
    case sourceUnmanaged(String)
    case destinationIsDirectory(String)
    case unmanagedDestination(String)

    public var errorDescription: String? {
        switch self {
        case .sourceMissing(let path):
            return "agent skill is missing at \(path)"
        case .sourceUnmanaged(let path):
            return "agent skill source is not managed by Hyprmux: \(path)"
        case .destinationIsDirectory(let path):
            return "agent skill destination is a directory: \(path)"
        case .unmanagedDestination(let path):
            return "refusing to modify an unmanaged skill at \(path); use --force"
        }
    }
}

/// Installs the skill shipped with Hyprmux into the portable user-level Agent Skills directory.
public enum AgentSkillInstaller {
    public static let name = "hyprmuxctl"
    public static let managedMarker = "<!-- managed-by-hyprmux -->"

    public static func destination(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent(".agents/skills", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("SKILL.md", isDirectory: false)
    }

    public static func status(
        source: URL,
        destination: URL,
        fileManager: FileManager = .default
    ) throws -> AgentSkillStatus {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory) else {
            return .notInstalled
        }
        guard !isDirectory.boolValue else {
            throw AgentSkillError.destinationIsDirectory(destination.path)
        }
        let installed = try Data(contentsOf: destination)
        guard isManaged(installed) else { return .unmanaged }
        let bundled = try sourceData(at: source, fileManager: fileManager)
        return installed == bundled ? .current : .outdated
    }

    @discardableResult
    public static func install(
        source: URL,
        destination: URL,
        force: Bool = false,
        fileManager: FileManager = .default
    ) throws -> Bool {
        let bundled = try sourceData(at: source, fileManager: fileManager)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue else {
                throw AgentSkillError.destinationIsDirectory(destination.path)
            }
            let installed = try Data(contentsOf: destination)
            if !isManaged(installed), !force {
                throw AgentSkillError.unmanagedDestination(destination.path)
            }
            if installed == bundled { return false }
        }

        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try bundled.write(to: destination, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)
        return true
    }

    @discardableResult
    public static func uninstall(
        destination: URL,
        force: Bool = false,
        fileManager: FileManager = .default
    ) throws -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory) else { return false }
        guard !isDirectory.boolValue else {
            throw AgentSkillError.destinationIsDirectory(destination.path)
        }
        let installed = try Data(contentsOf: destination)
        if !isManaged(installed), !force {
            throw AgentSkillError.unmanagedDestination(destination.path)
        }
        try fileManager.removeItem(at: destination)
        let directory = destination.deletingLastPathComponent()
        if (try? fileManager.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
            try? fileManager.removeItem(at: directory)
        }
        return true
    }

    private static func sourceData(at source: URL, fileManager: FileManager) throws -> Data {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw AgentSkillError.sourceMissing(source.path)
        }
        let data = try Data(contentsOf: source)
        guard isManaged(data) else { throw AgentSkillError.sourceUnmanaged(source.path) }
        return data
    }

    private static func isManaged(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains(managedMarker)
    }
}
