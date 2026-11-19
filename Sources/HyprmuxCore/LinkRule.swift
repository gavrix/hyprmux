import Foundation

/// `linkrule = MATCH, ACTION[, ARGS]`: where a link clicked in a terminal goes.
///
/// A rule only routes. The URL reaches the handler as it was clicked, so
/// `source:///a/b.swift#L12` stays whole and the handler decides what `#L12` means.
///
/// ```
/// linkrule = scheme:source ext:md, web
/// linkrule = scheme:source, exec, nvim
/// linkrule = scheme:zed, launch, Zed
/// ```
public struct LinkRule: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// A new terminal running the command, with the URL appended as its last argument.
        case exec(String)
        /// A web tile loading the URL.
        case web
        /// The app with this name or id, launched with the URL as its argument.
        case launch(String)
    }

    /// Lowercased, without `:`. Nil matches any scheme, and links without one.
    public var scheme: String?
    /// Lowercased, without the dot. Nil matches any extension.
    public var ext: String?
    public var action: Action

    public init(scheme: String? = nil, ext: String? = nil, action: Action) {
        self.scheme = scheme
        self.ext = ext
        self.action = action
    }

    /// The first rule that matches, in config order.
    public static func first(matching url: URL, in rules: [LinkRule]) -> LinkRule? {
        rules.first { $0.matches(url) }
    }

    public func matches(_ url: URL) -> Bool {
        if let scheme, url.scheme?.lowercased() != scheme { return false }
        if let ext, Self.pathExtension(of: url) != ext { return false }
        return true
    }

    /// The extension of the URL's last path component, lowercased. A `:LINE[:COLUMN]`
    /// suffix (`a.md:42`, how compilers and terminals print positions) isn't part of it.
    static func pathExtension(of url: URL) -> String {
        String(url.pathExtension.lowercased().prefix { $0 != ":" })
    }

    /// Parses the value of a `linkrule` line.
    public static func parse(_ value: String) -> Result<LinkRule, ParseError> {
        let parts = value.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2 else { return .failure(ParseError("expected 'MATCH, ACTION[, ARGS]'")) }

        var rule = LinkRule(action: .web)
        let matchers = parts[0].split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard !matchers.isEmpty else { return .failure(ParseError("expected scheme:NAME or ext:EXT to match")) }
        for m in matchers {
            let pair = m.split(separator: ":", maxSplits: 1).map(String.init)
            guard pair.count == 2, !pair[1].isEmpty else {
                return .failure(ParseError("bad matcher '\(m)': expected scheme:NAME or ext:EXT"))
            }
            let v = pair[1].lowercased()
            switch pair[0].lowercased() {
            case "scheme":
                guard rule.scheme == nil else { return .failure(ParseError("scheme: given twice")) }
                rule.scheme = v.hasSuffix(":") ? String(v.dropLast()) : v
            case "ext":
                guard rule.ext == nil else { return .failure(ParseError("ext: given twice")) }
                rule.ext = v.hasPrefix(".") ? String(v.dropFirst()) : v
            default:
                return .failure(ParseError("unknown matcher '\(pair[0])': expected scheme or ext"))
            }
        }

        let args = parts.count > 2 ? parts[2] : ""
        switch parts[1].lowercased() {
        case "exec":
            guard !args.isEmpty else { return .failure(ParseError("exec: expected a command")) }
            rule.action = .exec(args)
        case "web":
            guard args.isEmpty else { return .failure(ParseError("web: takes no arguments; the link is its URL")) }
            rule.action = .web
        case "launch":
            guard !args.isEmpty else { return .failure(ParseError("launch: expected an app name or id")) }
            rule.action = .launch(args)
        default:
            return .failure(ParseError("unknown action '\(parts[1])': expected exec, web, or launch"))
        }
        return .success(rule)
    }
}
