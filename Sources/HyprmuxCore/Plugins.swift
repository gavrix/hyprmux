import Foundation

/// A plugin's manifest (`plugin.json`): what Hyprmux needs to run it. The rest is
/// the QML host's (docs/PLUGINS.md).
public struct PluginManifest: Equatable, Sendable {
    public let id: String
    public let name: String
    public let permissions: Set<String>

    public init(id: String, name: String, permissions: Set<String>) {
        self.id = id
        self.name = name
        self.permissions = permissions
    }

    public static func parse(_ data: Data) -> Result<PluginManifest, PluginError> {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(PluginError("plugin.json isn't a JSON object"))
        }
        guard let id = o["id"] as? String, !id.isEmpty else { return .failure(PluginError("plugin.json has no id")) }
        return .success(PluginManifest(id: id, name: o["name"] as? String ?? id,
                                       permissions: Set(o["permissions"] as? [String] ?? [])))
    }

    public static func load(_ dir: String) -> Result<PluginManifest, PluginError> {
        let path = (dir as NSString).appendingPathComponent("plugin.json")
        guard let data = FileManager.default.contents(atPath: path) else {
            return .failure(PluginError("no plugin.json in \(dir)"))
        }
        return parse(data)
    }
}

public struct PluginError: Error, Equatable, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ d: String) { description = d }
}

/// Where a `plugin =` value points (docs/PLUGINS.md, Loading plugins).
public enum PluginLocation {
    /// A bare name is a folder in `plugins/` next to the config, else one of the
    /// plugins built into Hyprmux. A path is taken as written: `~` expanded, a
    /// relative one from the config's folder.
    public static func directory(for spec: String, configDir: String, builtinDir: String?,
                                 exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String {
        guard spec.contains("/") else {
            let user = ((configDir as NSString).appendingPathComponent("plugins") as NSString).appendingPathComponent(spec)
            if exists((user as NSString).appendingPathComponent("plugin.json")) { return user }
            if let builtinDir {
                let builtin = (builtinDir as NSString).appendingPathComponent(spec)
                if exists((builtin as NSString).appendingPathComponent("plugin.json")) { return builtin }
            }
            return user   // missing: the error names where it looked first
        }
        let expanded = (spec as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return (expanded as NSString).standardizingPath }
        return ((configDir as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
    }
}
