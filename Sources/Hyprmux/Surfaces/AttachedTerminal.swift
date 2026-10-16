import AppKit
import HyprmuxCore

/// A terminal attached to another tile: a command that tile started, shown on it as a
/// small live preview (WindowManager+Attached.swift). `hyprmuxctl run` opens one.
///
/// The terminal keeps the size it has when expanded. As a preview, the view scales it
/// down with a layer transform instead of resizing it, so the program never sees a
/// narrow terminal and expanding doesn't reflow anything. A preview takes no clicks:
/// the compositor turns a click into focus, and focus expands it.
final class AttachedTerminal: NSView, Surface {
    let terminal: TerminalView
    let parent: ClientID
    private let requestedTitle: String?
    /// working while the command runs, then done (exit 0) or blocked (it failed).
    private(set) var status: String? = "working"
    private(set) var exitStatus: Int?
    var isRunning: Bool { exitStatus == nil }
    /// Closes the tile once the command has ended; Ghostty only closes a live one.
    var onCloseAfterExit: (() -> Void)?

    /// The expanded content size: the terminal's size in both states.
    private var logicalSize: CGSize = .zero
    private var collapsed = true

    init(terminal: TerminalView, parent: ClientID, title: String?) {
        self.terminal = terminal
        self.parent = parent
        requestedTitle = title.flatMap { $0.isEmpty ? nil : $0 }
        super.init(frame: terminal.frame)
        wantsLayer = true
        addSubview(terminal)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    /// From each layout: the expanded content size, and whether it shows as a preview.
    func configure(logicalSize: CGSize, collapsed: Bool) {
        guard logicalSize != self.logicalSize || collapsed != self.collapsed else { return }
        self.logicalSize = logicalSize
        self.collapsed = collapsed
        layoutTerminal()
    }

    /// The command ended.
    func exited(_ code: Int) {
        exitStatus = code
        status = code == 0 ? "done" : "blocked"
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutTerminal()
    }

    override func layout() {
        super.layout()
        layoutTerminal()
    }

    private func layoutTerminal() {
        let size = collapsed && logicalSize.width > 0 && logicalSize.height > 0 ? logicalSize : bounds.size
        let rect = CGRect(origin: .zero, size: size)
        if terminal.frame != rect { terminal.frame = rect }
        guard let layer else { return }
        let s = size.width > 0 && size.height > 0 ? min(bounds.width / size.width, bounds.height / size.height) : 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !collapsed || abs(s - 1) < 0.001 {
            layer.sublayerTransform = CATransform3DIdentity
        } else {
            // The transform applies around the anchor point A: p' = A + s(p - A) + d. Pick d so
            // the terminal layer's origin lands on the view's: its scaled size is the view's.
            // Everything here is in this layer's coordinates, flipped or not.
            let b = layer.bounds
            let f = terminal.layer?.frame ?? CGRect(origin: b.origin, size: size)
            let a = CGPoint(x: b.minX + layer.anchorPoint.x * b.width, y: b.minY + layer.anchorPoint.y * b.height)
            let d = CGPoint(x: b.minX - a.x - s * (f.minX - a.x), y: b.minY - a.y - s * (f.minY - a.y))
            layer.sublayerTransform = CATransform3DConcat(CATransform3DMakeScale(s, s, 1),
                                                          CATransform3DMakeTranslation(d.x, d.y, 0))
        }
        CATransaction.commit()
    }

    /// A preview takes no clicks, and its terminal doesn't see the pointer.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard collapsed else { return super.hitTest(point) }
        return frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}

    // MARK: Surface

    var clientID: ClientID { terminal.clientID }
    var view: NSView { self }
    var focusTarget: NSView { terminal }
    var title: String {
        let base = requestedTitle ?? terminal.title
        guard let code = exitStatus else { return base }
        return code == 0 ? "\(base) ✓" : "\(base) ✗ \(code)"
    }
    var kind: String { "terminal" }
    var backdropColor: NSColor { terminal.backdrop }
    var info: [String: Any] {
        var out: [String: Any] = ["pwd": terminal.pwd ?? ""]
        if let code = exitStatus { out["exitStatus"] = code }
        return out
    }
    var automationCapabilities: [String] { terminal.automationCapabilities }
    func setOccluded(_ occluded: Bool) { terminal.setOccluded(occluded) }
    func requestClose() {
        if !isRunning, let close = onCloseAfterExit { close() } else { terminal.requestClose() }
    }
    func destroy() { terminal.destroy() }
}
