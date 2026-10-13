import AppKit
import HyprmuxCore
import WebKit

/// WebKit engine: a WKWebView. Light, native, but no passkeys (Apple gates
/// WebAuthn in web views behind a browser entitlement).
final class WebKitSurface: BrowserSurface, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    private var observations: [NSKeyValueObservation] = []

    /// Pass `configuration` for pages the web content opened itself (it must be used as-is).
    init(id: ClientID, options: BrowserOptions, configuration: WKWebViewConfiguration? = nil) {
        webView = WKWebView(frame: .zero, configuration: configuration ?? Self.makeConfiguration())
        super.init(id: id, options: options)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true  // right-click → Inspect Element
        webView.frame = content.bounds
        webView.autoresizingMask = [.width, .height]
        content.addSubview(webView)

        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] wv, _ in self?.engineTitleChanged(wv.title ?? "") },
            webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
                self?.watchMarkdown(wv.url)
                self?.engineURLChanged(wv.url?.absoluteString ?? "")
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in self?.engineProgressChanged(wv.estimatedProgress) },
            webView.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in self?.engineLoadingChanged(wv.isLoading) },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] wv, _ in self?.historyChanged(wv) },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] wv, _ in self?.historyChanged(wv) },
        ]
        historyChanged(webView)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func historyChanged(_ wv: WKWebView) {
        engineHistoryChanged(canGoBack: wv.canGoBack, canGoForward: wv.canGoForward)
    }

    private static func makeConfiguration() -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        // The default data store persists cookies and logins across surfaces and launches.
        c.websiteDataStore = .default()
        c.preferences.isElementFullscreenEnabled = true
        c.preferences.javaScriptCanOpenWindowsAutomatically = true
        c.setURLSchemeHandler(MarkdownSchemeHandler.shared, forURLScheme: MarkdownFile.scheme)
        return c
    }

    // MARK: Markdown

    /// Watches the markdown file the page shows, so the view follows edits.
    private var markdownWatcher: FileWatcher?
    /// A markdown page Hyprmux itself asked for: the address bar, a link from a terminal,
    /// or a restored session. Pages from the web can't navigate to one.
    private var requestedMarkdown: URL?

    private func loadMarkdown(_ viewer: URL) {
        requestedMarkdown = viewer
        webView.load(URLRequest(url: viewer))
    }

    private func watchMarkdown(_ url: URL?) {
        let file = url.flatMap { MarkdownFile.isDocument($0) ? MarkdownFile.fileURL(fromViewer: $0) : nil }
        guard file?.path != markdownWatcher?.path else { return }
        markdownWatcher?.stop()
        markdownWatcher = file.map { f in FileWatcher(path: f.path) { [weak self] in self?.markdownFileChanged(f) } }
    }

    private func markdownFileChanged(_ file: URL) {
        guard let text = try? MarkdownPage.read(file) else { return }
        webView.callAsyncJavaScript("window.hyprmux && window.hyprmux.update(text)", arguments: ["text": text],
                                    in: nil, in: .page) { result in
            if case .failure(let e) = result { log.error("markdown: update failed: \(e.localizedDescription)") }
        }
    }

    /// A link in a markdown page to a local file that isn't markdown. A folder shows its
    /// README, like GitHub; anything else opens in its default app. True if handled.
    private func openLocalFile(_ url: URL) -> Bool {
        guard url.host == MarkdownFile.localHost, let file = MarkdownFile.fileURL(fromViewer: url),
              !MarkdownFile.isMarkdown(file.path) else { return false }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir), isDir.boolValue {
            let readme = ["README.md", "readme.md", "Readme.md"].map { file.appendingPathComponent($0) }
                .first { FileManager.default.fileExists(atPath: $0.path) }
            if let readme, let viewer = MarkdownFile.viewerURL(for: readme) { loadMarkdown(viewer); return true }
        }
        NSWorkspace.shared.open(file)
        return true
    }

    /// Pages that may navigate to a markdown page: other markdown pages and local ones.
    private var currentPageMayOpenMarkdown: Bool {
        guard let scheme = webView.url?.scheme?.lowercased() else { return true }
        return [MarkdownFile.scheme, "file", "about", "data"].contains(scheme)
    }

    // MARK: Engine

    override var engineName: String { "webkit" }
    override var engineFocusView: NSView { webView }
    override var currentURL: String { webView.url?.absoluteString ?? "" }

    override func engineLoad(_ url: URL) {
        if let viewer = MarkdownFile.viewerURL(for: url) {
            loadMarkdown(viewer)
        } else if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    override func engineLoadHTML(_ html: String) { webView.loadHTMLString(html, baseURL: nil) }
    override func engineGoBack() { webView.goBack() }
    override func engineGoForward() { webView.goForward() }
    override func engineReload() { webView.reload() }
    override func engineStop() { webView.stopLoading() }

    override func engineInspect() {
        // No public API to open Web Inspector programmatically; this private
        // selector has been stable for years. The context menu also works.
        let inspector = webView.perform(NSSelectorFromString("_inspector"))?.takeUnretainedValue() as AnyObject?
        _ = inspector?.perform(NSSelectorFromString("show"))
    }

    override func engineFind(_ text: String, forward: Bool, findNext: Bool) {
        let c = WKFindConfiguration()
        c.backwards = !forward
        c.caseSensitive = false
        c.wraps = true
        let find: () -> Void = { [weak self] in
            self?.webView.find(text, configuration: c) { result in
                self?.engineFindResult(found: result.matchFound)
            }
        }
        if findNext { return find() }
        // WebKit searches from the end of the selection, which is the previous match.
        // Typing "a" then "ab" would skip an "ab" at that match, so start from its beginning.
        webView.evaluateJavaScript("getSelection().collapseToStart()") { _, _ in find() }
    }

    override func engineStopFinding() {}

    override func engineDestroy() {
        observations = []
        markdownWatcher?.stop()
        markdownWatcher = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
    }

    // MARK: Credential filling

    override func engineCallCredentialFunction(_ source: String, arguments: [String: Any],
                                               completion: @escaping (Result<Any?, Error>) -> Void) {
        // The wrapper is built only from a checked-in function source. Values stay in `args`.
        let wrapper = "return await (\(source))(args)"
        Task { @MainActor [weak self] in
            guard let self else {
                completion(.failure(BrowserCredentialError.pageChanged))
                return
            }
            do {
                let value = try await webView.callAsyncJavaScript(
                    wrapper, arguments: ["args": arguments], in: nil, contentWorld: .defaultClient)
                completion(.success(value))
            } catch {
                completion(.failure(error))
            }
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Hand non-web schemes (mailto:, zoommtg:, ...) to macOS.
        if let url = action.request.url, let scheme = url.scheme?.lowercased(),
           !["http", "https", "file", "about", "data", "blob", "javascript", MarkdownFile.scheme].contains(scheme) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        if let url = action.request.url, action.targetFrame?.isMainFrame ?? true {
            // Markdown pages read local files, so a web page can't open one.
            if url.scheme?.lowercased() == MarkdownFile.scheme, url != requestedMarkdown,
               action.navigationType != .backForward, action.navigationType != .reload, !currentPageMayOpenMarkdown {
                log.info("markdown: refused navigation from \(self.currentURL)")
                decisionHandler(.cancel)
                return
            }
            if action.navigationType == .linkActivated {
                if url.scheme?.lowercased() == MarkdownFile.scheme, openLocalFile(url) {
                    decisionHandler(.cancel)
                    return
                }
                // A link from a local page to a markdown file shows it rendered.
                let newTile = action.modifierFlags.contains(.command) || action.buttonNumber == 1 << 2
                if !newTile, url.isFileURL, let viewer = MarkdownFile.viewerURL(for: url) {
                    loadMarkdown(viewer)
                    decisionHandler(.cancel)
                    return
                }
            }
        }
        // Cmd+click or middle-click: open in a new tile instead of navigating.
        // buttonNumber is a mask here (WebEventFactory::toNSButtonNumber): middle is 1 << 2.
        let newTile = action.modifierFlags.contains(.command) || action.buttonNumber == 1 << 2
        if newTile, action.navigationType == .linkActivated, let url = action.request.url {
            host?.browserSurface(self, openInNewTile: url.absoluteString)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { showError(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { showError(error) }

    private func showError(_ error: Error) {
        let e = error as NSError
        guard e.code != NSURLErrorCancelled else { return }
        webView.loadHTMLString("""
        <html><body style="background:#1a1a1a;color:#bbb;font:14px -apple-system;padding:40px">
        <h2 style="color:#eee">Can't open this page</h2><p>\(e.localizedDescription)</p></body></html>
        """, baseURL: nil)
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let host else { return nil }
        let popup = WebKitSurface(id: host.browserSurfaceNextClientID(self), options: options, configuration: configuration)
        host.browserSurface(self, adoptPopup: popup)
        return popup.webView
    }

    func webViewDidClose(_ webView: WKWebView) { requestClose() }

    /// Private WKUIDelegate callback (Safari's status bar uses it): the element under the pointer.
    /// If WebKit stops calling it, hovered links are unknown and $mod+click moves the tile as before.
    @objc(_webView:mouseDidMoveOverElement:withFlags:userInfo:)
    func webView(_ webView: WKWebView, mouseDidMoveOverElement hit: AnyObject?, withFlags flags: NSEvent.ModifierFlags, userInfo: AnyObject?) {
        let sel = NSSelectorFromString("absoluteLinkURL")
        guard let hit, hit.responds(to: sel) else { return engineHoveredLinkChanged(nil) }
        engineHoveredLinkChanged((hit.perform(sel)?.takeUnretainedValue() as? URL)?.absoluteString)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert()
        a.messageText = message
        a.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert()
        a.messageText = message
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        completionHandler(a.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = parameters.allowsMultipleSelection
        p.canChooseDirectories = parameters.allowsDirectories
        completionHandler(p.runModal() == .OK ? p.urls : nil)
    }
}
