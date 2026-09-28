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
        for n in workspaces {
            let isActive = n == active
            let label = "\(n)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: isActive ? NSColor.black : NSColor(white: 0.85, alpha: 1),
            ]
            let size = label.size(withAttributes: attrs)
            let w = max(pillH + (isActive ? 10 : 0), size.width + 12)
            let r = CGRect(x: x, y: (h - pillH) / 2, width: w, height: pillH)
            let path = NSBezierPath(roundedRect: r, xRadius: pillH / 2, yRadius: pillH / 2)
            (isActive ? accent : NSColor(white: 1, alpha: 0.08)).setFill()
            path.fill()
            label.draw(at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: attrs)
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

/// Hyprland-style red bar listing config errors.
final class BannerView: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.75, green: 0.15, blue: 0.2, alpha: 0.95).cgColor
        layer?.cornerRadius = 8
        label.textColor = .white
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.maximumNumberOfLines = 6
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }
    override var isFlipped: Bool { true }

    func show(_ errors: [String], width: CGFloat) -> CGFloat {
        let shown = errors.prefix(5) + (errors.count > 5 ? ["…and \(errors.count - 5) more"] : [])
        label.stringValue = "Config errors:\n" + shown.joined(separator: "\n")
        let size = label.sizeThatFits(CGSize(width: width - 24, height: 1000))
        label.frame = CGRect(x: 12, y: 8, width: width - 24, height: size.height)
        return size.height + 16
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
