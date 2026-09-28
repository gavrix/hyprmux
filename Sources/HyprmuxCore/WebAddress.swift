import Foundation

public enum WebAddress {
    /// Turns address-bar input into a URL: full URLs pass through, host-like input
    /// gets a scheme, anything else becomes a search.
    public static func resolve(_ raw: String, search: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let lower = s.lowercased()
        if let u = URL(string: s), let scheme = u.scheme?.lowercased(),
           ["http", "https", "file", "about", "data", "chrome", "chrome-extension", "devtools", "view-source"].contains(scheme) {
            return u
        }
        if s.hasPrefix("/") || s.hasPrefix("~") {
            return URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
        }
        let local = lower.hasPrefix("localhost") || lower.hasPrefix("127.0.0.1") || lower.hasPrefix("0.0.0.0")
            || lower.hasPrefix("[::1]")
        if local, !s.contains(" ") { return URL(string: "http://" + s) }
        let hostPart = s.split(separator: "/", maxSplits: 1).first.map(String.init) ?? s
        if !s.contains(" "), hostPart.contains("."), !hostPart.hasSuffix("."), hostPart.first != "." {
            return URL(string: "https://" + s)
        }
        let q = s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? s
        return URL(string: search.replacingOccurrences(of: "%s", with: q))
    }
}
