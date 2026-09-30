import AppKit
import ChromiumBridge
import HyprmuxCore

/// Chromium engine (CEF). Heavier than WebKit, but does passkeys from a phone
/// or a security key, which Okta and GitHub need.
final class ChromiumSurface: BrowserSurface, HMChromiumBrowserDelegate {
    private var browser: HMChromiumBrowser?
    private var pendingURL: String?
    private var pendingHTML: String?
    private var isPopup = false
    private var closed = false

    override init(id: ClientID, options: BrowserOptions) {
        super.init(id: id, options: options)
    }

    /// A popup the page opened: Chromium attaches its browser to our content view.
    init(popupWithID id: ClientID, options: BrowserOptions) {
        super.init(id: id, options: options)
        isPopup = true
        let b = HMChromiumBrowser(pendingWithParentView: content)
        b.delegate = self
        browser = b
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Chromium needs its parent view in a window, so the browser is created here.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, browser == nil, !closed else { return }
        let start = pendingURL ?? pendingHTML.map(Self.dataURL) ?? "about:blank"
        pendingURL = nil
        pendingHTML = nil
        let b = HMChromiumBrowser(parentView: content, url: start)
        b.delegate = self
        browser = b
    }

    private static func dataURL(_ html: String) -> String {
        "data:text/html;charset=utf-8," + (html.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
    }

    // MARK: Engine

    override var engineName: String { "chromium" }
    override var engineFocusView: NSView { browser?.browserView ?? content }
    override var currentURL: String { browser?.currentURL ?? pendingURL ?? "" }

    override func engineLoad(_ url: URL) {
        if let browser { browser.loadURL(url.absoluteString) } else { pendingURL = url.absoluteString }
    }

    override func engineLoadHTML(_ html: String) {
        if let browser { browser.loadURL(Self.dataURL(html)) } else { pendingHTML = html }
    }

    override func engineGoBack() { browser?.goBack() }
    override func engineGoForward() { browser?.goForward() }
    override func engineReload() { browser?.reload() }
    override func engineStop() { browser?.stopLoad() }
    override func engineInspect() { browser?.showDevTools() }

    override func engineClose() {
        guard !closed else { return }
        if let browser { browser.close() } else { finishClose() }
    }

    override func engineTakeFocus(in window: NSWindow) {
        guard let browser, let v = browser.browserView else {
            window.makeFirstResponder(content)
            return
        }
        // Chromium moves first responder to its inner view itself.
        browser.setFocused(true)
        if !(window.firstResponder as? NSView).map({ $0.isDescendant(of: v) }).isTrue {
            window.makeFirstResponder(v)
        }
    }

    private func finishClose() {
        guard !closed else { return }
        closed = true
        host?.browserSurfaceDidClose(self)
    }

    // MARK: HMChromiumBrowserDelegate

    func chromiumBrowser(_ b: HMChromiumBrowser, titleChanged title: String) { engineTitleChanged(title) }
    func chromiumBrowser(_ b: HMChromiumBrowser, addressChanged url: String) { engineURLChanged(url) }
    func chromiumBrowser(_ b: HMChromiumBrowser, progressChanged progress: Double) { engineProgressChanged(progress) }

    func chromiumBrowser(_ b: HMChromiumBrowser, loadingChanged loading: Bool, canGoBack: Bool, canGoForward: Bool) {
        engineLoadingChanged(loading)
        engineHistoryChanged(canGoBack: canGoBack, canGoForward: canGoForward)
    }

    func chromiumBrowser(_ b: HMChromiumBrowser, statusMessageChanged message: String) {
        // Chromium shows the hovered link's URL as its status message.
        engineHoveredLinkChanged(message)
    }

    func chromiumBrowser(_ b: HMChromiumBrowser, wantsPopupForURL url: String) -> HMChromiumBrowser? {
        guard let host else { return nil }
        let popup = ChromiumSurface(popupWithID: host.browserSurfaceNextClientID(self), options: options)
        host.browserSurface(self, adoptPopup: popup)
        return popup.browser
    }

    func chromiumBrowser(_ b: HMChromiumBrowser, openURLInNewTile url: String) {
        host?.browserSurface(self, openInNewTile: url)
    }

    func chromiumBrowserDidCreate(_ b: HMChromiumBrowser) {
        host?.browserSurfaceDidBecomeReady(self)
    }

    func chromiumBrowserGotFocus(_ b: HMChromiumBrowser) {
        host?.browserSurfaceDidRequestFocus(self)
    }

    func chromiumBrowserShouldTakeNavigationFocus(_ b: HMChromiumBrowser) -> Bool {
        host?.browserSurfaceShouldTakeNavigationFocus(self) ?? true
    }

    func chromiumBrowserDidClose(_ b: HMChromiumBrowser) {
        browser = nil
        finishClose()
    }
}

private extension Optional where Wrapped == Bool {
    var isTrue: Bool { self ?? false }
}
