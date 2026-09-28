import Foundation

/// Reads the few Ghostty options that libghostty's C API doesn't expose
/// (`ghostty_config_get` can't return repeatable strings like `font-family`).
public enum GhosttyConfigScan {
    /// Ghostty's default config files on macOS, in load order.
    public static var defaultFiles: [String] {
        let home = NSHomeDirectory()
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.config"
        let support = home + "/Library/Application Support/com.mitchellh.ghostty"
        return [xdg + "/ghostty/config", xdg + "/ghostty/config.ghostty",
                support + "/config", support + "/config.ghostty"]
    }

    /// The primary font family: the first `font-family` after the last reset (`font-family =`).
    /// `texts` are config file contents in load order.
    public static func fontFamily(in texts: [String]) -> String? {
        var families: [String] = []
        for text in texts {
            for (key, value) in pairs(text) where key == "font-family" {
                if value.isEmpty { families.removeAll() } else { families.append(value) }
            }
        }
        return families.first
    }

    /// Default files plus the files they include with `config-file`, then `extra` (hyprmux's
    /// `ghostty { }` lines), as texts in load order.
    public static func loadTexts(extra: [String]) -> [String] {
        var out: [String] = []
        var seen: Set<String> = []
        func load(_ path: String, depth: Int) {
            let p = (path as NSString).standardizingPath
            guard depth < 5, !seen.contains(p), let text = try? String(contentsOfFile: p, encoding: .utf8) else { return }
            seen.insert(p)
            out.append(text)
            let dir = (p as NSString).deletingLastPathComponent
            for (key, value) in pairs(text) where key == "config-file" && !value.isEmpty {
                var v = value.hasPrefix("?") ? String(value.dropFirst()) : value
                v = (v as NSString).expandingTildeInPath
                load(v.hasPrefix("/") ? v : dir + "/" + v, depth: depth + 1)
            }
        }
        for f in defaultFiles { load(f, depth: 0) }
        if !extra.isEmpty { out.append(extra.joined(separator: "\n")) }
        return out
    }

    /// `key = value` pairs, with Ghostty's rules: `#` only starts a comment at the line start,
    /// and a quoted value is unquoted.
    static func pairs(_ text: String) -> [(String, String)] {
        text.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { return nil }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            return (key, value)
        }
    }
}
