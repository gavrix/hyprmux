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
            webView.observe(\.url, options: [.new]) { [weak self] wv, _ in self?.engineURLChanged(wv.url?.absoluteString ?? "") },
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
        return c
    }

    // MARK: Engine

    override var engineName: String { "webkit" }
    override var engineFocusView: NSView { webView }
    override var currentURL: String { webView.url?.absoluteString ?? "" }

    override func engineLoad(_ url: URL) {
        if url.isFileURL {
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

    override func engineDestroy() {
        observations = []
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
           !["http", "https", "file", "about", "data", "blob", "javascript"].contains(scheme) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
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
