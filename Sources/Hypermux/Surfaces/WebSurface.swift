import AppKit
import HypermuxCore
import WebKit

protocol WebSurfaceHost: AnyObject {
    func webSurfaceDidRequestFocus(_ s: WebSurface)
    func webSurfaceTitleDidChange(_ s: WebSurface)
    func webSurfaceDidClose(_ s: WebSurface)
    /// A page opened a new window (target=_blank, window.open). Return the new web view.
    func webSurface(_ s: WebSurface, createWith configuration: WKWebViewConfiguration, for action: WKNavigationAction) -> WKWebView?
}

/// A web page in a tile: a slim address bar over a WKWebView.
///
/// Engine-specific code stays in this class, so a Chromium (CEF) backend can
/// sit next to it behind the same `Surface` protocol.
final class WebSurface: FlippedView, Surface, WKNavigationDelegate, WKUIDelegate, NSTextFieldDelegate {
    let clientID: ClientID
    let webView: WKWebView
    weak var host: WebSurfaceHost?

    private let bar = NSView()
    private let address = AddressField()
    private let progress = NSView()
    private var observations: [NSKeyValueObservation] = []
    private let search: String
    private let home: String
    private var showBar: Bool
    private let barHeight: CGFloat = 30

    private(set) var title = ""

    /// Pass `configuration` for pages the web content opened itself (it must be used as-is).
    init(id: ClientID, configuration: WKWebViewConfiguration? = nil, home: String, search: String, showAddressBar: Bool) {
        self.clientID = id
        self.home = home
        self.search = search
        self.showBar = showAddressBar
        let cfg = configuration ?? Self.makeConfiguration()
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true  // right-click → Inspect Element
        addSubview(webView)

        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.92).cgColor
        addSubview(bar)
        address.delegate = self
        address.onCancel = { [weak self] in self?.focusPage() }
        address.placeholderString = "Search or enter address"
        address.font = .systemFont(ofSize: 12)
        address.focusRingType = .none
        address.bezelStyle = .roundedBezel
        address.textColor = NSColor(white: 0.9, alpha: 1)
        address.drawsBackground = true
        address.backgroundColor = NSColor(white: 0.18, alpha: 1)
        bar.addSubview(address)
        progress.wantsLayer = true
        progress.layer?.backgroundColor = NSColor(srgbRed: 0.2, green: 0.8, blue: 1, alpha: 1).cgColor
        progress.isHidden = true
        bar.addSubview(progress)

        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
                guard let self else { return }
                self.title = wv.title ?? ""
                self.host?.webSurfaceTitleDidChange(self)
            },
            webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
                guard let self, !self.isEditingAddress else { return }
                let u = wv.url?.absoluteString ?? ""
                self.address.stringValue = u == "about:blank" ? "" : u
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in self?.layoutProgress() },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in self?.layoutProgress() },
        ]
        layoutContent()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private static func makeConfiguration() -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        // The default data store persists cookies and logins across surfaces and launches.
        c.websiteDataStore = .default()
        c.preferences.isElementFullscreenEnabled = true
        c.preferences.javaScriptCanOpenWindowsAutomatically = true
        return c
    }

    // MARK: Surface

    var view: NSView { self }
    var focusTarget: NSView { webView }
    var kind: String { "web" }
    var backdropColor: NSColor { NSColor(white: 0.1, alpha: 1) }
    var info: [String: Any] {
        ["url": webView.url?.absoluteString ?? "", "address": address.currentEditor()?.string ?? address.stringValue,
         "editingAddress": isEditingAddress]
    }

    func setOccluded(_ occluded: Bool) {
        // WebKit throttles hidden views itself.
    }

    func requestClose() {
        host?.webSurfaceDidClose(self)
    }

    func destroy() {
        observations = []
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
    }

    // MARK: Navigation

    /// New-tab page: local, no autofocus (a page that autofocuses would steal the address bar).
    func openStartPage() {
        let html = """
        <html><head><meta name="color-scheme" content="dark"></head>
        <body style="margin:0;height:100vh;display:flex;align-items:center;justify-content:center;
                     background:#141418;color:#666;font:15px -apple-system">
        Type an address or search terms</body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
        address.stringValue = ""
        focusAddress()
    }

    /// Loads address-bar style input: a URL, host, or search terms. Empty = home.
    func open(_ input: String) {
        let text = input.isEmpty ? home : input
        guard let url = WebAddress.resolve(text, search: search) else { return }
        load(url)
    }

    func load(_ url: URL) {
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
        address.stringValue = url.absoluteString
    }

    func perform(_ nav: WebNav) {
        switch nav {
        case .back: webView.goBack()
        case .forward: webView.goForward()
        case .reload: webView.reload()
        case .stop: webView.stopLoading()
        case .home: open("")
        case .focusurl: focusAddress()
        case .inspect: showInspector()
        }
    }

    func focusAddress() {
        if !showBar { setAddressBarVisible(true) }
        window?.makeFirstResponder(address)
        address.currentEditor()?.selectAll(nil)
    }

    func focusPage() {
        window?.makeFirstResponder(webView)
        address.stringValue = webView.url?.absoluteString ?? address.stringValue
    }

    func setAddressBarVisible(_ v: Bool) {
        showBar = v
        layoutContent()
    }

    private var isEditingAddress: Bool { address.currentEditor() != nil }

    private func showInspector() {
        // No public API to open Web Inspector programmatically; the private
        // selector is stable across macOS releases. Falls back to the context menu.
        let inspector = webView.perform(NSSelectorFromString("_inspector"))?.takeUnretainedValue() as AnyObject?
        _ = inspector?.perform(NSSelectorFromString("show"))
    }

    // MARK: Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutContent()
    }

    private func layoutContent() {
        let h = showBar ? barHeight : 0
        bar.isHidden = !showBar
        bar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: h)
        address.frame = CGRect(x: 8, y: 5, width: max(0, bounds.width - 16), height: h - 10)
        webView.frame = CGRect(x: 0, y: h, width: bounds.width, height: max(0, bounds.height - h))
        layoutProgress()
    }

    private func layoutProgress() {
        let p = webView.estimatedProgress
        progress.isHidden = !webView.isLoading || !showBar
        progress.frame = CGRect(x: 0, y: barHeight - 2, width: bounds.width * p, height: 2)
    }

    // MARK: NSTextFieldDelegate

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            open(address.stringValue)
            focusPage()
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            focusPage()
            return true
        }
        return false
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
        // Cmd+click: open in a new tile instead of navigating.
        if action.modifierFlags.contains(.command), action.navigationType == .linkActivated, let url = action.request.url {
            _ = host?.webSurface(self, createWith: webView.configuration, for: action).map { $0.load(URLRequest(url: url)) }
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
        let html = """
        <html><body style="background:#1a1a1a;color:#bbb;font:14px -apple-system;padding:40px">
        <h2 style="color:#eee">Can't open this page</h2><p>\(e.localizedDescription)</p></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        host?.webSurface(self, createWith: configuration, for: navigationAction)
    }

    func webViewDidClose(_ webView: WKWebView) { requestClose() }

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

/// Text field that reports Escape even when empty.
final class AddressField: NSTextField {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
