import AppKit
import HypermuxCore

protocol BrowserSurfaceHost: AnyObject {
    func browserSurfaceDidRequestFocus(_ s: BrowserSurface)
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
    var search: String
    var showAddressBar: Bool

    init(_ c: HypermuxConfig) {
        home = c.webHome
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
    private let address = AddressField()
    private let progressLine = NSView()
    private var showBar: Bool
    private let barHeight: CGFloat = 30

    private(set) var title = ""
    /// Extra horizontal inset for the address bar so it clears rounded top corners.
    var topCornerInset: CGFloat = 0 { didSet { if topCornerInset != oldValue { layoutContent() } } }
    private(set) var loading = false
    private var progress: Double = 0

    init(id: ClientID, options: BrowserOptions) {
        clientID = id
        self.options = options
        showBar = options.showAddressBar
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        addSubview(content)
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
        address.stringValue = (u == "about:blank" || u.hasPrefix("data:")) ? "" : u
    }

    func engineLoadingChanged(_ l: Bool) {
        loading = l
        layoutProgress()
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
         "address": address.currentEditor()?.string ?? address.stringValue, "editingAddress": isEditingAddress]
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
        address.stringValue = url.absoluteString
    }

    /// New-tab page: local, no autofocus (a page that autofocuses would steal the address bar).
    func openStartPage() {
        engineLoadHTML("""
        <html><head><meta name="color-scheme" content="dark"><title>New tab</title></head>
        <body style="margin:0;height:100vh;display:flex;align-items:center;justify-content:center;
                     background:#141418;color:#666;font:15px -apple-system">
        Type an address or search terms</body></html>
        """)
        address.stringValue = ""
        focusAddress()
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
        let u = currentURL
        address.stringValue = (u == "about:blank" || u.hasPrefix("data:")) ? "" : u
    }

    func setAddressBarVisible(_ v: Bool) {
        showBar = v
        layoutContent()
    }

    private var isEditingAddress: Bool { address.currentEditor() != nil }

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
        address.frame = CGRect(x: side, y: 5, width: max(0, bounds.width - 2 * side), height: h - 10)
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

/// Text field that reports Escape even when empty.
final class AddressField: NSTextField {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
