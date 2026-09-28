import AppKit
import HypermuxCore

/// Root view of the monitor window. Top-left origin, like the core model.
final class CompositorView: FlippedView {
    var onResize: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // Holds focus when no client is focused (e.g. empty workspace), so keys don't beep.
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {}

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onResize?()
    }
}

/// A minimal waybar-like strip: workspaces on the left, focused title in the middle.
final class BarView: NSView {
    var leadingInset: CGFloat = 0 { didSet { needsDisplay = true } }
    var workspaces: [Int] = [] { didSet { if workspaces != oldValue { needsDisplay = true } } }
    /// Workspace names, shown after the number (the number always stays, for ⌘1…9).
    var names: [Int: String] = [:] { didSet { if names != oldValue { needsDisplay = true } } }
    var active = 1 { didSet { if active != oldValue { needsDisplay = true } } }
    var special: String? { didSet { if special != oldValue { needsDisplay = true } } }
    var title = "" { didSet { if title != oldValue { needsDisplay = true } } }
    var submap = "reset" { didSet { if submap != oldValue { needsDisplay = true } } }
    var accent = NSColor(srgbRed: 0.2, green: 0.8, blue: 1, alpha: 1)
    var onSelectWorkspace: ((Int) -> Void)?

    private var pillRects: [(Int, CGRect)] = []

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        pillRects = []
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        let h = bounds.height
        var x = leadingInset + 8
        let pillH: CGFloat = min(18, h - 6)
        let nameFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        for n in workspaces {
            let isActive = n == active
            let color = isActive ? NSColor.black : NSColor(white: 0.85, alpha: 1)
            let label = NSMutableAttributedString(string: "\(n)", attributes: [.font: font, .foregroundColor: color])
            if var name = names[n] {
                if name.count > 18 { name = String(name.prefix(17)) + "…" }
                label.append(NSAttributedString(string: " " + name, attributes: [
                    .font: nameFont, .foregroundColor: isActive ? color : NSColor(white: 0.85, alpha: 0.75),
                ]))
            }
            let size = label.size()
            let w = max(pillH + (isActive ? 10 : 0), size.width + (names[n] == nil ? 12 : 16))
            let r = CGRect(x: x, y: (h - pillH) / 2, width: w, height: pillH)
            let path = NSBezierPath(roundedRect: r, xRadius: pillH / 2, yRadius: pillH / 2)
            (isActive ? accent : NSColor(white: 1, alpha: 0.08)).setFill()
            path.fill()
            label.draw(at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2))
            pillRects.append((n, r))
            x += w + 5
        }
        var right: [String] = []
        if let special { right.append("special:\(special)") }
        if submap != "reset" { right.append("submap: \(submap)") }
        let small: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: accent]
        var rx = bounds.maxX - 12
        for s in right.reversed() {
            let str = s as NSString
            let size = str.size(withAttributes: small)
            rx -= size.width
            str.draw(at: CGPoint(x: rx, y: (h - size.height) / 2), withAttributes: small)
            rx -= 14
        }
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor(white: 0.8, alpha: 1),
        ]
        let t = title as NSString
        let ts = t.size(withAttributes: titleAttrs)
        let maxW = max(0, min(rx, bounds.width) - x - 20)
        let drawW = min(ts.width, maxW)
        let tx = max(x + 10, (bounds.width - drawW) / 2)
        t.draw(with: CGRect(x: tx, y: (h - ts.height) / 2, width: drawW, height: ts.height),
               options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: titleAttrs)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let hit = pillRects.first(where: { $0.1.contains(p) }) {
            onSelectWorkspace?(hit.0)
        } else {
            window?.performDrag(with: event)
        }
    }
}

/// Centered hint shown on an empty workspace.
final class HintView: NSTextField {
    convenience init() {
        self.init(labelWithString: "")
        font = .systemFont(ofSize: 15, weight: .medium)
        textColor = NSColor(white: 1, alpha: 0.35)
        alignment = .center
    }
}
