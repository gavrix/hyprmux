import AppKit
import HyprmuxCore
import UniformTypeIdentifiers
import WebKit

/// Serves the `hyprmux-md` scheme to WebKit tiles (plans/markdown-viewer.md).
///
/// - `hyprmux-md://local/PATH.md`: a page that renders the file with `viewer.js`.
/// - `hyprmux-md://local/PATH`: any other file's bytes, such as an image a document shows.
/// - `hyprmux-md://viewer/NAME`: the viewer's files, from `Resources/markdown`.
///
/// The scheme reads any file the user can, so only `hyprmux-md` pages may load from it.
final class MarkdownSchemeHandler: NSObject, WKURLSchemeHandler {
    static let shared = MarkdownSchemeHandler()

    /// `Resources/markdown` in the app bundle.
    private let viewerDirectory = Bundle.main.resourceURL?.appendingPathComponent("markdown")
    /// Tasks WebKit stopped. They must not get any more calls.
    private var stopped = Set<ObjectIdentifier>()
    private let io = DispatchQueue(label: "dev.gavrix.hyprmux.markdown", qos: .userInitiated)

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return fail(task, NSURLErrorBadURL) }
        // A page from another scheme (an https site) must not reach local files.
        if let main = task.request.mainDocumentURL, main.scheme?.lowercased() != MarkdownFile.scheme {
            log.info("markdown: refused \(url.absoluteString) for \(main.absoluteString)")
            return fail(task, NSURLErrorNoPermissionsToReadFile)
        }
        let viewerDirectory = viewerDirectory
        io.async { [weak self] in
            let response: Response
            switch url.host {
            case MarkdownFile.viewerHost?:
                response = Self.viewerFile(url, in: viewerDirectory)
            case MarkdownFile.localHost?:
                response = Self.localFile(url)
            default:
                response = .failure(NSURLErrorBadURL)
            }
            DispatchQueue.main.async { self?.finish(task, url: url, with: response) }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }

    // MARK: Responses

    private enum Response {
        case data(Data, mimeType: String)
        case failure(Int)
    }

    private static func viewerFile(_ url: URL, in dir: URL?) -> Response {
        let name = url.lastPathComponent
        // Only plain names: no way out of the folder.
        guard let dir, !name.isEmpty, !name.hasPrefix("."), url.pathComponents.count == 2,
              let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else {
            return .failure(NSURLErrorFileDoesNotExist)
        }
        return .data(data, mimeType: mimeType(forExtension: url.pathExtension))
    }

    private static func localFile(_ url: URL) -> Response {
        guard let file = MarkdownFile.fileURL(fromViewer: url) else { return .failure(NSURLErrorBadURL) }
        guard MarkdownFile.isMarkdown(file.path) else {
            guard let data = try? Data(contentsOf: file) else { return .failure(NSURLErrorFileDoesNotExist) }
            return .data(data, mimeType: mimeType(forExtension: file.pathExtension))
        }
        let page: String
        do {
            page = MarkdownPage.html(name: file.lastPathComponent, text: try MarkdownPage.read(file))
        } catch {
            page = MarkdownPage.errorHTML(name: file.lastPathComponent, path: file.path, error: error)
        }
        return .data(Data(page.utf8), mimeType: "text/html")
    }

    private static func mimeType(forExtension ext: String) -> String {
        UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }

    private func finish(_ task: WKURLSchemeTask, url: URL, with response: Response) {
        guard stopped.remove(ObjectIdentifier(task)) == nil else { return }
        switch response {
        case .failure(let code):
            fail(task, code)
        case .data(let data, let mime):
            var headers = ["Content-Type": mime, "Content-Length": "\(data.count)", "Cache-Control": "no-store"]
            if mime == "text/html" { headers["Content-Security-Policy"] = MarkdownPage.contentSecurityPolicy }
            let r = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)
                ?? URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil)
            task.didReceive(r)
            task.didReceive(data)
            task.didFinish()
        }
    }

    private func fail(_ task: WKURLSchemeTask, _ code: Int) {
        guard stopped.remove(ObjectIdentifier(task)) == nil else { return }
        task.didFailWithError(NSError(domain: NSURLErrorDomain, code: code))
    }
}

/// The HTML page for one markdown file.
enum MarkdownPage {
    private static let viewer = "\(MarkdownFile.scheme)://\(MarkdownFile.viewerHost)"

    /// Scripts only from the viewer. Images from documents and the web (badges).
    static let contentSecurityPolicy = [
        "default-src 'none'",
        "script-src \(viewer)",
        "style-src \(viewer) 'unsafe-inline'",
        "img-src \(MarkdownFile.scheme): https: http: data:",
        "media-src \(MarkdownFile.scheme): https: http:",
        "font-src \(viewer)",
    ].joined(separator: "; ")

    /// The file's text as UTF-8. Bytes that aren't UTF-8 show as U+FFFD.
    static func read(_ file: URL) throws -> String {
        let data = try Data(contentsOf: file)
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    static func html(name: String, text: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
        <meta name="color-scheme" content="dark">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escapeHTML(name))</title>
        <link rel="stylesheet" href="\(viewer)/github-markdown-dark.css">
        <link rel="stylesheet" href="\(viewer)/highlight-github-dark.min.css">
        <link rel="stylesheet" href="\(viewer)/viewer.css">
        <script type="application/json" id="hm-source">\(scriptJSON(text))</script>
        </head><body>
        <article class="markdown-body" id="hm-doc"></article>
        <script src="\(viewer)/markdown-it.min.js"></script>
        <script src="\(viewer)/purify.min.js"></script>
        <script src="\(viewer)/highlight.min.js"></script>
        <script src="\(viewer)/viewer.js"></script>
        </body></html>
        """
    }

    static func errorHTML(name: String, path: String, error: Error) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="color-scheme" content="dark">
        <title>\(escapeHTML(name))</title>
        <link rel="stylesheet" href="\(viewer)/github-markdown-dark.css">
        <link rel="stylesheet" href="\(viewer)/viewer.css">
        </head><body><article class="markdown-body">
        <h2>Can't open \(escapeHTML(name))</h2>
        <p class="hm-error">\(escapeHTML(path))<br>\(escapeHTML(error.localizedDescription))</p>
        </article></body></html>
        """
    }

    /// A JSON string that is safe inside a `<script>` element: no `<` can end it early.
    static func scriptJSON(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed])) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Calls `onChange` on the main queue after a file changes. Editors often save by writing
/// a new file and renaming it over the old one, so after a delete or rename it opens the
/// path again.
final class FileWatcher {
    let path: String
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var reopenTries = 0
    private var stopped = false

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
        watch()
    }

    deinit { source?.cancel() }

    func stop() {
        stopped = true
        pending?.cancel()
        source?.cancel()
        source = nil
    }

    private func watch() {
        guard !stopped else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return reopenLater() }
        reopenTries = 0
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename],
                                                          queue: .main)
        s.setEventHandler { [weak self, weak s] in
            guard let self, let s else { return }
            if !s.data.isDisjoint(with: [.delete, .rename]) {
                s.cancel()
                self.source = nil
                self.reopenLater()
            }
            self.changed()
        }
        s.setCancelHandler { close(fd) }
        source = s
        s.resume()
    }

    /// The new file may not be in place yet. Try for about 2 seconds.
    private func reopenLater() {
        guard reopenTries < 20 else { return }
        reopenTries += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.source == nil else { return }
            self.watch()
            if self.source != nil { self.changed() }
        }
    }

    /// Several events arrive for one save. Report once.
    private func changed() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: item)
    }
}
