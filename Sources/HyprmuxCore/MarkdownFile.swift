import Foundation

/// Local markdown files, which web tiles show rendered (WebKit, `hyprmux-md` scheme).
///
/// A document is `hyprmux-md://local/ABS/PATH.md`, so relative links and images in it
/// resolve to the same scheme. The viewer's own files are `hyprmux-md://viewer/NAME`.
public enum MarkdownFile {
    public static let scheme = "hyprmux-md"
    /// Host of documents and the files they reference.
    public static let localHost = "local"
    /// Host of the viewer's bundled scripts and styles.
    public static let viewerHost = "viewer"

    public static let extensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn"]

    public static func isMarkdown(_ path: String) -> Bool {
        extensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// The viewer URL for a link to a markdown file, or nil if it isn't one.
    ///
    /// Takes `file:` URLs, scheme-less paths (what a terminal reports for a path it found
    /// on screen), and viewer URLs. A relative path resolves against `directory`. A
    /// `:LINE` or `:LINE:COLUMN` suffix, or a `#LLINE` fragment, becomes `#LLINE`. Other
    /// fragments (heading anchors) stay.
    public static func viewerURL(for url: URL, relativeTo directory: String? = nil) -> URL? {
        var path: String
        switch url.scheme?.lowercased() {
        case scheme?:
            guard url.host == localHost else { return nil }
            path = url.path
        case "file"?:
            path = url.path
        case nil:
            path = (url.path as NSString).expandingTildeInPath
            if !path.hasPrefix("/") {
                guard let directory else { return nil }
                path = ((directory as NSString).appendingPathComponent(path) as NSString).standardizingPath
            }
        default:
            return nil
        }
        var line = url.fragment.flatMap(lineNumber(fragment:))
        if let (base, suffixLine) = splitLineSuffix(path) {
            path = base
            line = line ?? suffixLine
        }
        guard path.hasPrefix("/"), isMarkdown(path) else { return nil }
        var c = URLComponents()
        c.scheme = scheme
        c.host = localHost
        c.path = path
        if let line {
            c.fragment = "L\(line)"
        } else if let f = url.fragment, !f.isEmpty {
            c.fragment = f
        }
        return c.url
    }

    /// The file a viewer URL shows, without the fragment. Nil for other URLs.
    public static func fileURL(fromViewer url: URL) -> URL? {
        guard url.scheme?.lowercased() == scheme, url.host == localHost, !url.path.isEmpty else { return nil }
        return URL(fileURLWithPath: url.path)
    }

    /// True for a viewer URL of a markdown document (not an image it references).
    public static func isDocument(_ url: URL) -> Bool {
        fileURL(fromViewer: url).map { isMarkdown($0.path) } ?? false
    }

    /// `L42` → 42.
    public static func lineNumber(fragment: String) -> Int? {
        guard fragment.hasPrefix("L"), let n = Int(fragment.dropFirst()), n > 0 else { return nil }
        return n
    }

    /// `/a/b.md:42` or `/a/b.md:42:7` → (`/a/b.md`, 42). Nil without a numeric suffix.
    static func splitLineSuffix(_ path: String) -> (String, Int)? {
        var parts = path.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }
        if parts.count >= 3, Int(parts[parts.count - 1]) != nil, Int(parts[parts.count - 2]) != nil {
            parts.removeLast()  // the column
        }
        guard let line = Int(parts[parts.count - 1]), line > 0 else { return nil }
        parts.removeLast()
        return (parts.joined(separator: ":"), line)
    }
}
