import AppKit
import HypermuxCore

/// Content of one managed window: a terminal, a web page, and later other kinds.
/// The compositor handles layout, decoration, and focus; a surface only renders
/// and handles its own input.
protocol Surface: AnyObject {
    var clientID: ClientID { get }
    /// Placed inside the window's rounded clip, sized to the content area.
    var view: NSView { get }
    /// Made first responder when the window gets focus.
    var focusTarget: NSView { get }
    var title: String { get }
    /// "terminal", "web", ...
    var kind: String { get }
    /// Painted behind the view (visible briefly while a window resizes).
    var backdropColor: NSColor { get }
    /// Extra fields for `hypermuxctl clients`.
    var info: [String: Any] { get }

    func setOccluded(_ occluded: Bool)
    /// Ask to close. The surface calls `SurfaceHost.surfaceDidClose` when it is gone.
    func requestClose()
    /// Release resources after the close animation.
    func destroy()
}

extension Surface {
    /// True if the window's first responder sits inside this surface (e.g. its address bar).
    func ownsFirstResponder(in window: NSWindow) -> Bool {
        guard let r = window.firstResponder as? NSView else { return false }
        // Field editors live outside the view tree; use their delegate (the text field).
        if let tv = r as? NSTextView, tv.isFieldEditor, let owner = tv.delegate as? NSView {
            return owner.isDescendant(of: view)
        }
        return r.isDescendant(of: view)
    }
}

extension TerminalView: Surface {
    var view: NSView { self }
    var focusTarget: NSView { self }
    var kind: String { "terminal" }
    var backdropColor: NSColor { backdrop }
    var info: [String: Any] { ["pwd": pwd ?? ""] }
    func setOccluded(_ occluded: Bool) { setTerminalOccluded(occluded) }
}
