import AppKit

/// The window that acts as hyprmux's monitor.
///
/// "Fill" full screen makes it borderless and screen-sized on the normal desktop,
/// so a transparent background still shows the wallpaper (native full screen
/// moves the window to its own Space, where there is only black behind it).
final class MonitorWindow: NSWindow {
    static let windowedStyle: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]

    private(set) var isFilled = false
    private var windowedFrame: NSRect?

    // Borderless windows can't become key by default.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // Let the filled window cover the menu bar area.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        isFilled ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    func applyWindowedChrome() {
        styleMask = Self.windowedStyle
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
    }

    func enterFill() {
        guard !isFilled, !styleMask.contains(.fullScreen), let screen = screen ?? NSScreen.main else { return }
        windowedFrame = frame
        isFilled = true
        styleMask = [.borderless]
        setFrame(screen.frame, display: true)
        applyPresentation()
        UserDefaults.standard.set(true, forKey: "HyprmuxFill")
        UserDefaults.standard.set(NSStringFromRect(windowedFrame!), forKey: "HyprmuxWindowedFrame")
    }

    func exitFill() {
        guard isFilled else { return }
        isFilled = false
        NSApp.presentationOptions = []
        applyWindowedChrome()
        let saved = windowedFrame ?? UserDefaults.standard.string(forKey: "HyprmuxWindowedFrame").map(NSRectFromString)
        if let saved, saved.width > 100 { setFrame(saved, display: true) }
        UserDefaults.standard.set(false, forKey: "HyprmuxFill")
    }

    func toggleFill() { isFilled ? exitFill() : enterFill() }

    /// Not filled and not in macOS full screen: a window macOS lets the user move and resize.
    var isWindowed: Bool { !isFilled && styleMask.contains(.resizable) && !styleMask.contains(.fullScreen) }

    /// The corner radius macOS gives this window: 16 on macOS 26, 10 before.
    /// Read at runtime (private), with those values as the fallback.
    var systemCornerRadius: CGFloat {
        if responds(to: NSSelectorFromString("_cornerRadius")),
           let r = value(forKey: "_cornerRadius") as? CGFloat, r > 0 { return r }
        if #available(macOS 26.0, *) { return 16 }
        return 10
    }

    /// Hide the menu bar and Dock while hyprmux is in front (they reappear at the screen edge).
    /// macOS applies these only while the app is active.
    func applyPresentation() {
        guard isFilled else { return }
        NSApp.presentationOptions = [.autoHideDock, .autoHideMenuBar]
    }

    /// Keep covering the screen after display changes (resolution, arrangement).
    func refit() {
        guard isFilled, let screen = screen ?? NSScreen.main, frame != screen.frame else { return }
        setFrame(screen.frame, display: true)
    }

    /// A first launch (nothing saved yet) starts filled.
    static var wasFilledAtQuit: Bool { UserDefaults.standard.object(forKey: "HyprmuxFill") as? Bool ?? true }
}
