import AppKit
import HyprmuxCore

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
    var leadingInset: CGFloat = 0 { didSet { if leadingInset != oldValue { pillsChanged() } } }
    var workspaces: [Int] = [] { didSet { if workspaces != oldValue { pillsChanged() } } }
    /// Workspace names, shown after the number (the number always stays, for ⌘1…9).
    var names: [Int: String] = [:] { didSet { if names != oldValue { pillsChanged() } } }
    var active = 1 { didSet { if active != oldValue { pillsChanged() } } }
    var special: String? { didSet { if special != oldValue { needsDisplay = true } } }
    var title = "" { didSet { if title != oldValue { needsDisplay = true } } }
    var submap = "reset" { didSet { if submap != oldValue { needsDisplay = true } } }
    var accent = NSColor(srgbRed: 0.2, green: 0.8, blue: 1, alpha: 1)
    var onSelectWorkspace: ((Int) -> Void)?
    /// The area the workspace pills cover, in the bar's coordinates. Called when it changes.
    var onPillsFrame: ((CGRect) -> Void)?

    private struct Pill { let id: Int; let rect: CGRect; let label: NSAttributedString }
    private var pills: [Pill] = []
    private var lastPillsFrame: CGRect?

    private static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
    private static let nameFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        let heightChanged = newSize.height != frame.height
        super.setFrameSize(newSize)
        if heightChanged { pillsChanged() }
    }

    /// Union of the pills, or an empty rect at the start when there are none.
    var pillsFrame: CGRect {
        guard let first = pills.first?.rect, let last = pills.last?.rect else {
            return CGRect(x: leadingInset + 8, y: 0, width: 0, height: bounds.height)
        }
        return first.union(last)
    }

    private func pillsChanged() {
        layoutPills()
        needsDisplay = true
        let f = pillsFrame
        if f != lastPillsFrame {
            lastPillsFrame = f
            onPillsFrame?(f)
        }
    }

    private func layoutPills() {
        pills = []
        let h = bounds.height
        var x = leadingInset + 8
        let pillH: CGFloat = min(18, h - 6)
        for n in workspaces {
            let isActive = n == active
            let color = isActive ? NSColor.black : NSColor(white: 0.92, alpha: 1)
            let label = NSMutableAttributedString(string: "\(n)", attributes: [.font: Self.font, .foregroundColor: color])
            if var name = names[n] {
                if name.count > 18 { name = String(name.prefix(17)) + "…" }
                label.append(NSAttributedString(string: " " + name, attributes: [
                    .font: Self.nameFont, .foregroundColor: isActive ? color : NSColor(white: 0.92, alpha: 0.8),
                ]))
            }
            let size = label.size()
            let w = max(pillH + (isActive ? 10 : 0), size.width + (names[n] == nil ? 12 : 16))
            pills.append(Pill(id: n, rect: CGRect(x: x, y: (h - pillH) / 2, width: w, height: pillH), label: label))
            x += w + 5
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let font = Self.font
        let h = bounds.height
        for p in pills {
            let r = p.rect
            let path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
            if p.id == active {
                accent.setFill()
                path.fill()
            }
            let size = p.label.size()
            p.label.draw(at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2))
        }
        let x = (pills.last?.rect.maxX ?? leadingInset + 8) + 5
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
        if let hit = pills.first(where: { $0.rect.contains(p) }) {
            onSelectWorkspace?(hit.id)
        } else {
            window?.performDrag(with: event)
        }
    }
}

/// A frosted capsule behind the workspace pills, so they read over any wallpaper.
/// macOS 26 gets Liquid Glass; older systems get a vibrancy blur with a hairline edge.
/// Stacked below the tiles, so it never covers one.
final class BarBackdrop: NSView {
    /// Space between the capsule's edge and the pills.
    static let padding: CGFloat = 4

    private var effect: NSView?
    /// Under the glass in a transparent window: the glass may only refract the window's
    /// own content, which is clear there, so this supplies a blur of the desktop.
    private var base: NSVisualEffectView?
    private let hairline = CAShapeLayer()
    private var transparentWindow = true
    private var enabled = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        hairline.fillColor = nil
        hairline.lineWidth = 1
        hairline.strokeColor = NSColor(white: 1, alpha: 0.14).cgColor
        hairline.zPosition = 10
        layer?.addSublayer(hairline)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// `transparent`: the window shows the desktop, so the blur samples what's behind it.
    func configure(enabled: Bool, transparent: Bool) {
        self.enabled = enabled
        isHidden = !enabled || frame.isEmpty
        guard enabled, effect == nil || transparent != transparentWindow else { return }
        transparentWindow = transparent
        effect?.removeFromSuperview()
        base?.removeFromSuperview()
        base = nil
        let v: NSView
        if #available(macOS 26.0, *) {
            if transparent {
                let b = Self.blur(transparent: true)
                install(b)
                base = b
            }
            let g = NSGlassEffectView()
            g.style = .regular
            v = g
            hairline.isHidden = true  // the glass draws its own edge
        } else {
            v = Self.blur(transparent: transparent)
            hairline.isHidden = false
        }
        install(v)
        effect = v
        needsLayout = true
    }

    private func install(_ v: NSView) {
        v.appearance = NSAppearance(named: .darkAqua)
        v.autoresizingMask = [.width, .height]
        v.frame = bounds
        addSubview(v)
    }

    private static func blur(transparent: Bool) -> NSVisualEffectView {
        let e = NSVisualEffectView()
        // Behind-window blur only sees the desktop through a transparent window.
        e.blendingMode = transparent ? .behindWindow : .withinWindow
        e.material = .hudWindow
        e.state = .active
        return e
    }

    /// Places the capsule around the pills (`pills` in the superview's coordinates).
    func wrap(_ pills: CGRect) {
        let p = Self.padding
        let f = pills.isEmpty ? .zero : pills.insetBy(dx: -p, dy: -p)
        isHidden = !enabled || f.isEmpty
        frame = f
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let r = bounds.height / 2
        if #available(macOS 26.0, *), let g = effect as? NSGlassEffectView {
            g.cornerRadius = r
        }
        for case let e as NSVisualEffectView in [base, effect] {
            e.maskImage = Self.capsuleMask(height: bounds.height)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hairline.frame = bounds
        hairline.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                               cornerWidth: max(0, r - 0.5), cornerHeight: max(0, r - 0.5), transform: nil)
        CATransaction.commit()
    }

    /// A stretchable capsule: the caps stay round while the middle stretches.
    private static func capsuleMask(height: CGFloat) -> NSImage {
        let r = height / 2
        let img = NSImage(size: NSSize(width: height + 1, height: height), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
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
