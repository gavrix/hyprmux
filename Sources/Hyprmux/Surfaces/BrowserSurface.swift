import AppKit
import HyprmuxCore

protocol BrowserSurfaceHost: AnyObject {
    func browserSurfaceDidRequestFocus(_ s: BrowserSurface)
    /// A page load wants keyboard focus. False for a tile that doesn't have focus,
    /// so a background tile (opened with `new-surface`, or reloading) can't take it.
    func browserSurfaceShouldTakeNavigationFocus(_ s: BrowserSurface) -> Bool
    func browserSurfaceTitleDidChange(_ s: BrowserSurface)
    func browserSurfaceDidClose(_ s: BrowserSurface)
    /// The engine view became ready (Chromium creates it asynchronously).
    func browserSurfaceDidBecomeReady(_ s: BrowserSurface)
    /// Open a URL in a new tile (cmd+click).
    func browserSurface(_ s: BrowserSurface, openInNewTile url: String)
    /// Allocate an ID for a popup tile the page is opening.
    func browserSurfaceNextClientID(_ s: BrowserSurface) -> ClientID
    /// Start managing a popup tile the surface created.
    func browserSurface(_ s: BrowserSurface, adoptPopup popup: BrowserSurface)
}

struct BrowserOptions {
    var home: String
    var newTab: String
    var search: String
    var showAddressBar: Bool

    init(_ c: HyprmuxConfig) {
        home = c.webHome
        newTab = c.webNewTab
        search = c.webSearch
        showAddressBar = c.webShowAddressBar
    }
}

/// A web page in a tile: a slim address bar over an engine view.
/// Subclasses (WebKit, Chromium) supply the engine; everything else is shared.
class BrowserSurface: FlippedView, Surface, NSTextFieldDelegate {
    let clientID: ClientID
    weak var host: BrowserSurfaceHost?
    let options: BrowserOptions

    /// Holds the engine's view. Laid out below the address bar.
    let content = FlippedView()
    private let bar = NSView()
    private let backButton = BarButton(symbol: "chevron.left", label: "Back")
    private let forwardButton = BarButton(symbol: "chevron.right", label: "Forward")
    private let reloadButton = BarButton(symbol: "arrow.clockwise", label: "Reload")
    private let address = AddressField()
    private let progressLine = NSView()
    private var showBar: Bool
    private let barHeight: CGFloat = 30

    private(set) var title = ""
    /// Extra horizontal inset for the address bar so it clears rounded top corners.
    var topCornerInset: CGFloat = 0 { didSet { if topCornerInset != oldValue { layoutContent() } } }
    private(set) var loading = false
    private var progress: Double = 0
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// The link under the pointer, if any. Lets $mod+click on a link open it instead of moving the tile.
    private(set) var hoveredLink: String?

    init(id: ClientID, options: BrowserOptions) {
        clientID = id
        self.options = options
        showBar = options.showAddressBar
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        addSubview(content)
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.92).cgColor
        addSubview(bar)
        for (button, action) in [(backButton, #selector(goBackClicked)), (forwardButton, #selector(goForwardClicked)),
                                 (reloadButton, #selector(reloadClicked))] {
            button.target = self
            button.action = action
            bar.addSubview(button)
        }
        updateNavButtons()
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
        progressLine.wantsLayer = true
        progressLine.layer?.backgroundColor = NSColor(srgbRed: 0.2, green: 0.8, blue: 1, alpha: 1).cgColor
        progressLine.isHidden = true
        bar.addSubview(progressLine)
        layoutContent()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: Engine hooks (override)

    var engineName: String { "" }
    var engineFocusView: NSView { content }
    var currentURL: String { "" }
    /// The last address loaded, for a page that hasn't committed a URL yet.
    private(set) var requestedURL: String?
    /// What a saved session keeps: the page's URL, or what it was asked to load.
    var restorableURL: String? {
        let u = currentURL
        return u.isEmpty ? requestedURL : u
    }
    func engineLoad(_ url: URL) {}
    func engineLoadHTML(_ html: String) {}
    func engineGoBack() {}
    func engineGoForward() {}
    func engineReload() {}
    func engineStop() {}
    func engineInspect() {}
    func engineClose() { host?.browserSurfaceDidClose(self) }
    func engineDestroy() {}
    func engineTakeFocus(in window: NSWindow) { window.makeFirstResponder(engineFocusView) }

    // MARK: Engine events (call from subclasses)

    func engineTitleChanged(_ t: String) {
        title = t
        host?.browserSurfaceTitleDidChange(self)
    }

    func engineURLChanged(_ u: String) {
        guard !isEditingAddress else { return }
        address.stringValue = displayAddress(u)
    }

    /// What the address bar shows for a URL: nothing for blank and new-tab pages.
    private func displayAddress(_ u: String) -> String {
        if u == "about:blank" || u.hasPrefix("data:") { return "" }
        if let tab = newTabURL, u == tab.absoluteString { return "" }
        return u
    }

    /// The configured new-tab page (`web:new_tab`), if any.
    private var newTabURL: URL? {
        options.newTab.isEmpty ? nil : WebAddress.resolve(options.newTab, search: options.search)
    }

    func engineLoadingChanged(_ l: Bool) {
        loading = l
        layoutProgress()
        updateNavButtons()
    }

    func engineHistoryChanged(canGoBack back: Bool, canGoForward forward: Bool) {
        canGoBack = back
        canGoForward = forward
        updateNavButtons()
    }

    func engineHoveredLinkChanged(_ link: String?) {
        hoveredLink = (link?.isEmpty ?? true) ? nil : link
    }

    func engineProgressChanged(_ p: Double) {
        progress = p
        layoutProgress()
    }

    // MARK: Surface

    var view: NSView { self }
    var focusTarget: NSView { engineFocusView }
    var kind: String { "web" }
    var backdropColor: NSColor { NSColor(white: 0.1, alpha: 1) }
    var info: [String: Any] {
        ["url": currentURL, "engine": engineName,
         "address": address.currentEditor()?.string ?? address.stringValue, "editingAddress": isEditingAddress,
         "canGoBack": canGoBack, "canGoForward": canGoForward, "loading": loading, "hoveredLink": hoveredLink ?? ""]
    }
    func setOccluded(_ occluded: Bool) {}
    func requestClose() { engineClose() }
    func destroy() { engineDestroy() }
    func takeFocus(in window: NSWindow) { engineTakeFocus(in: window) }

    // MARK: Navigation

    /// Loads address-bar style input: a URL, host, or search terms. Empty = home.
    func open(_ input: String) {
        let text = input.isEmpty ? options.home : input
        guard let url = WebAddress.resolve(text, search: options.search) else { return }
        engineLoad(url)
        requestedURL = url.absoluteString
        address.stringValue = url.absoluteString
    }

    /// New-tab page: local, no autofocus (a page that autofocuses would steal the address bar).
    /// `focusAddress` false opens it in the background, leaving keyboard focus where it is.
    func openStartPage(focusAddress takeFocus: Bool = true) {
        if let url = newTabURL {
            engineLoad(url)
            requestedURL = url.absoluteString
            address.stringValue = ""
            if takeFocus { focusAddress() }
            return
        }
        engineLoadHTML("""
        <html><head><meta name="color-scheme" content="dark"><title>New tab</title></head>
        <body style="margin:0;height:100vh;display:flex;align-items:center;justify-content:center;
                     background:#141418;color:#666;font:15px -apple-system">
        Type an address or search terms</body></html>
        """)
        address.stringValue = ""
        if takeFocus { focusAddress() }
    }

    func perform(_ nav: WebNav) {
        switch nav {
        case .back: engineGoBack()
        case .forward: engineGoForward()
        case .reload: engineReload()
        case .stop: engineStop()
        case .home: open("")
        case .focusurl: focusAddress()
        case .inspect: engineInspect()
        }
    }

    func focusAddress() {
        if !showBar { setAddressBarVisible(true) }
        window?.makeFirstResponder(address)
        address.currentEditor()?.selectAll(nil)
    }

    func focusPage() {
        if let w = window { engineTakeFocus(in: w) }
        address.stringValue = displayAddress(currentURL)
    }

    func setAddressBarVisible(_ v: Bool) {
        showBar = v
        layoutContent()
    }

    private var isEditingAddress: Bool { address.currentEditor() != nil }

    @objc private func goBackClicked() { engineGoBack() }
    @objc private func goForwardClicked() { engineGoForward() }
    @objc private func reloadClicked() { loading ? engineStop() : engineReload() }

    private func updateNavButtons() {
        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward
        reloadButton.setSymbol(loading ? "xmark" : "arrow.clockwise", label: loading ? "Stop" : "Reload")
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
        let side = max(8, topCornerInset)
        let button: CGFloat = 22, gap: CGFloat = 2
        var x = side - 4  // the symbols have their own padding
        for b in [backButton, forwardButton, reloadButton] {
            b.frame = CGRect(x: x, y: (h - button) / 2, width: button, height: button)
            x += button + gap
        }
        x += 4
        address.frame = CGRect(x: x, y: 5, width: max(0, bounds.width - x - side), height: h - 10)
        content.frame = CGRect(x: 0, y: h, width: bounds.width, height: max(0, bounds.height - h))
        layoutProgress()
    }

    private func layoutProgress() {
        progressLine.isHidden = !loading || !showBar
        progressLine.frame = CGRect(x: 0, y: barHeight - 2, width: bounds.width * progress, height: 2)
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
}

/// Borderless icon button in the address bar. Never takes keyboard focus.
final class BarButton: NSButton {
    init(symbol: String, label: String) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        refusesFirstResponder = true
        setSymbol(symbol, label: label)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func setSymbol(_ symbol: String, label: String) {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(config)
        toolTip = label
        setAccessibilityLabel(label)
    }

    override var isEnabled: Bool { didSet { updateTint() } }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateTint() }
    private func updateTint() { contentTintColor = NSColor(white: isEnabled ? 0.85 : 0.35, alpha: 1) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Text field that reports Escape even when empty.
final class AddressField: NSTextField {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
