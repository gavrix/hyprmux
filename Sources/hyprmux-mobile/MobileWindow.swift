import AppKit
import HyprmuxClientKit

/// One toplevel of Mobile. The toplevel's own surface is the chrome: a background, and
/// whatever a subclass draws on it. It's drawn again only when the tile resizes or the
/// chrome changes, never per device frame.
class MobileWindow {
    unowned let mobile: Mobile
    let toplevel: HMToplevel
    private(set) var configuration: HMConfigure?
    private var chromeWanted = false
    private(set) var closed = false

    init(mobile: Mobile, title: String, restoreToken: String?, launch: HMLaunch?) {
        self.mobile = mobile
        toplevel = mobile.client.makeToplevel(title: title, restoreToken: restoreToken, launch: launch)
        toplevel.onConfigure = { [weak self] c in self?.configured(c) }
        toplevel.onCloseRequested = { [weak self] in self?.close() }
        toplevel.onBufferReleased = { [weak self] in
            guard let self, self.chromeWanted else { return }
            self.redrawChrome()
        }
    }

    var size: CGSize {
        guard let c = configuration else { return .zero }
        return CGSize(width: c.width, height: c.height)
    }

    var occluded: Bool { configuration?.occluded ?? false }

    func configured(_ c: HMConfigure) {
        let wasOccluded = occluded
        configuration = c
        layout()
        redrawChrome()
        if wasOccluded != c.occluded { occlusionChanged(c.occluded) }
    }

    /// Size-dependent geometry. Runs before the chrome is drawn.
    func layout() {}

    func occlusionChanged(_ occluded: Bool) {}

    /// Draws the chrome, in points with a top-left origin.
    func drawChrome(_ ctx: CGContext, size: CGSize) {
        Draw.fill(ctx, CGRect(origin: .zero, size: size), Draw.background)
    }

    /// Runs just before the chrome is committed: set subsurface rects here, so they move
    /// with it.
    func willCommitChrome() {}

    /// Draws and commits the chrome. With every buffer busy, it waits for a release.
    func redrawChrome() {
        guard !closed, let c = configuration else { return }
        guard let buffer = toplevel.acquireBuffer() else {
            chromeWanted = true
            return
        }
        chromeWanted = false
        Draw.into(buffer, scale: c.scale) { ctx in drawChrome(ctx, size: CGSize(width: c.width, height: c.height)) }
        willCommitChrome()
        toplevel.present(buffer)
    }

    /// Stops whatever the window shows. Subclasses release their device here.
    func stop() {}

    func close() {
        guard !closed else { return }
        closed = true
        stop()
        toplevel.destroy()
        mobile.windowClosed(self)
    }
}

/// A window with only a message: "No devices available", or why a device can't show.
final class MessageWindow: MobileWindow {
    let message: String
    let detail: String

    init(mobile: Mobile, message: String, detail: String, launch: HMLaunch?) {
        self.message = message
        self.detail = detail
        super.init(mobile: mobile, title: "Mobile", restoreToken: nil, launch: launch)
    }

    override func drawChrome(_ ctx: CGContext, size: CGSize) {
        super.drawChrome(ctx, size: size)
        let width = min(size.width - 40, 420)
        let x = (size.width - width) / 2
        Draw.symbol("iphone.gen3.slash", in: CGRect(x: x, y: size.height / 2 - 70, width: width, height: 40), size: 30,
                    color: Draw.note)
        Draw.text(message, in: CGRect(x: x, y: size.height / 2 - 24, width: width, height: 24), size: 15,
                  weight: .semibold)
        Draw.text(detail, in: CGRect(x: x, y: size.height / 2 + 6, width: width, height: 44), size: 12, color: Draw.note)
    }
}
