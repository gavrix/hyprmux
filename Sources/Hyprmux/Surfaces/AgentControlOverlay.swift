import AppKit

/// Shows, over a web tile's page, that an agent drives it: a banner with a Stop button
/// while an agent is attached, and a cursor that glides to where the agent clicks.
///
/// The cursor is drawn here, not in the page, so the page can't see it, restyle it,
/// or remove it, and navigation doesn't reset it. Clicks pass through to the page,
/// except on the banner.
final class AgentControlOverlay: FlippedView {
    var onStop: (() -> Void)?

    private let banner = AgentControlBanner()
    /// Layer-hosting, so the cursor's layers are ours: AppKit doesn't manage them, and the
    /// root layer is flipped like the page (y grows down).
    private let cursorHost = CursorHostView()
    private let cursor = CALayer()
    private let arrow = CAShapeLayer()
    private let ring = CAShapeLayer()
    private var cursorShown = false
    /// Where the cursor is going, and who waits for it to get there.
    private var target: CGPoint?
    private var arrivals: [() -> Void] = []
    private var moveGeneration = 0
    private var hideWork: DispatchWorkItem?

    static let tint = NSColor(srgbRed: 0.2, green: 0.8, blue: 1, alpha: 1)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true

        banner.onStop = { [weak self] in self?.onStop?() }
        addSubview(banner)

        // The tip of the arrow sits at the layer's position.
        let path = CGMutablePath()
        path.addLines(between: [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 17), CGPoint(x: 4.6, y: 13),
                                CGPoint(x: 7.6, y: 20), CGPoint(x: 10.4, y: 18.8), CGPoint(x: 7.4, y: 12),
                                CGPoint(x: 13, y: 12)])
        path.closeSubpath()
        arrow.path = path
        arrow.fillColor = Self.tint.cgColor
        arrow.strokeColor = NSColor.white.cgColor
        arrow.lineWidth = 1.5
        arrow.lineJoin = .round
        arrow.shadowColor = Self.tint.cgColor
        arrow.shadowOpacity = 0.9
        arrow.shadowRadius = 6
        arrow.shadowOffset = .zero
        cursor.addSublayer(arrow)

        ring.path = CGPath(ellipseIn: CGRect(x: -14, y: -14, width: 28, height: 28), transform: nil)
        ring.fillColor = Self.tint.withAlphaComponent(0.25).cgColor
        ring.strokeColor = Self.tint.cgColor
        ring.lineWidth = 2
        ring.opacity = 0
        cursor.addSublayer(ring)

        cursor.bounds = .zero
        cursor.anchorPoint = .zero
        cursor.opacity = 0
        let root = CALayer()
        root.isGeometryFlipped = true
        root.addSublayer(cursor)
        cursorHost.layer = root
        cursorHost.wantsLayer = true
        cursorHost.frame = bounds
        cursorHost.autoresizingMask = [.width, .height]
        addSubview(cursorHost)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // Only the banner takes clicks; the page gets every other one.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override func layout() {
        super.layout()
        let size = banner.fittingSize
        banner.frame = CGRect(x: round((bounds.width - size.width) / 2), y: 8, width: size.width, height: size.height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    /// For `hyprmuxctl surfaces`: the cursor's state, in view points.
    var debugInfo: [String: Any] {
        var info: [String: Any] = ["controlled": bannerShown, "cursorShown": cursorShown, "cursorMoving": target != nil,
                                   "cursorAt": [Double(cursor.position.x), Double(cursor.position.y)]]
        // Where to click Stop in tests: window points, top-left origin (as `sendmouse` takes them).
        if bannerShown, let window, let content = window.contentView {
            let p = content.convert(banner.stopCenter, from: banner)
            info["stopAt"] = [Double(p.x), Double(content.isFlipped ? p.y : content.bounds.height - p.y)]
        }
        return info
    }

    // MARK: Banner

    var bannerShown: Bool {
        get { !banner.isHidden }
        set {
            banner.isHidden = !newValue
            if !newValue { hideCursor() }
            needsLayout = true
        }
    }

    // MARK: Cursor

    /// Glides the cursor to `point` (view coordinates). `arrived` runs when it gets there,
    /// or at once when the tile isn't on screen. A newer move releases older waiters.
    func moveCursor(to point: CGPoint, arrived: (() -> Void)? = nil) {
        keepCursor()
        let p = CGPoint(x: min(max(0, point.x), bounds.width), y: min(max(0, point.y), bounds.height))
        if let t = target, hypot(t.x - p.x, t.y - p.y) < 0.5 {
            // Already on its way there.
            if let arrived { arrivals.append(arrived) }
            return
        }
        if target == nil, cursorShown, hypot(cursor.position.x - p.x, cursor.position.y - p.y) < 0.5 {
            arrived?()
            return
        }
        let earlier = arrivals
        arrivals = arrived.map { [$0] } ?? []
        earlier.forEach { $0() }
        target = p
        moveGeneration += 1

        let onScreen = window != nil && !isHiddenOrHasHiddenAncestor
        guard onScreen, cursorShown else {
            // First appearance: fade in at the point instead of flying in from a corner.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            cursor.position = p
            CATransaction.commit()
            showCursor()
            finishMove(moveGeneration)
            return
        }
        let from = cursor.presentation()?.position ?? cursor.position
        let distance = hypot(p.x - from.x, p.y - from.y)
        let duration = min(0.45, max(0.12, 0.1 + Double(distance) / 1600))
        let generation = moveGeneration
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.finishMove(generation) }
        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: from)
        move.toValue = NSValue(point: p)
        move.duration = duration
        move.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1)
        cursor.position = p
        cursor.add(move, forKey: "move")
        CATransaction.commit()
        // Animations can stall in a window macOS stopped drawing; never hold a click for long.
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.25) { [weak self] in
            self?.finishMove(generation)
        }
    }

    private func finishMove(_ generation: Int) {
        guard generation == moveGeneration else { return }
        target = nil
        let waiting = arrivals
        arrivals = []
        waiting.forEach { $0() }
    }

    /// A click: the cursor dips and a ring spreads from its tip.
    func pressCursor() {
        keepCursor()
        let dip = CAKeyframeAnimation(keyPath: "transform.scale")
        dip.values = [1, 0.82, 1]
        dip.keyTimes = [0, 0.35, 1]
        dip.duration = 0.22
        arrow.add(dip, forKey: "dip")

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.4
        grow.toValue = 1.3
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.9, 0.6, 0]
        fade.keyTimes = [0, 0.5, 1]
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.45
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(group, forKey: "press")
    }

    /// Typing: the cursor pulses where it is.
    func typingCursor() {
        guard cursorShown else { return }
        keepCursor()
        let pulse = CAKeyframeAnimation(keyPath: "shadowRadius")
        pulse.values = [6, 12, 6]
        pulse.duration = 0.3
        arrow.add(pulse, forKey: "typing")
    }

    private func showCursor() {
        guard !cursorShown else { return }
        cursorShown = true
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = cursor.presentation()?.opacity ?? 0
        fade.toValue = 1
        fade.duration = 0.18
        cursor.opacity = 1
        cursor.add(fade, forKey: "fade")
    }

    private func hideCursor() {
        hideWork?.cancel()
        hideWork = nil
        target = nil
        let waiting = arrivals
        arrivals = []
        waiting.forEach { $0() }
        guard cursorShown else { return }
        cursorShown = false
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = cursor.presentation()?.opacity ?? 1
        fade.toValue = 0
        fade.duration = 0.3
        cursor.opacity = 0
        cursor.add(fade, forKey: "fade")
    }

    /// The cursor fades after a while without input, so it doesn't sit over the page.
    private func keepCursor() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.idleCursor() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    private func idleCursor() {
        guard target == nil else { return }
        hideCursor()
    }
}

/// Hosts the cursor's layers. Flipped, so AppKit flips the hosted layer's geometry too.
private final class CursorHostView: FlippedView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// "Agent is controlling this tile", with a Stop button.
private final class AgentControlBanner: NSView {
    var onStop: (() -> Void)?
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "Agent is controlling this tile")
    private let stop = NSButton(title: "Stop", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.88).cgColor
        layer?.cornerRadius = 13
        layer?.borderWidth = 1
        layer?.borderColor = AgentControlOverlay.tint.withAlphaComponent(0.6).cgColor

        dot.wantsLayer = true
        dot.layer?.backgroundColor = AgentControlOverlay.tint.cgColor
        dot.layer?.cornerRadius = 3.5
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.3
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dot.layer?.add(pulse, forKey: "pulse")
        addSubview(dot)

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = NSColor(white: 0.92, alpha: 1)
        addSubview(label)

        stop.bezelStyle = .inline
        stop.controlSize = .small
        stop.font = .systemFont(ofSize: 11, weight: .semibold)
        stop.refusesFirstResponder = true
        stop.target = self
        stop.action = #selector(stopClicked)
        stop.toolTip = "Disconnect the agent from this tile"
        addSubview(stop)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }
    override var fittingSize: NSSize {
        NSSize(width: 12 + 7 + 7 + label.fittingSize.width + 10 + stop.fittingSize.width + 6, height: 26)
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        dot.frame = CGRect(x: 12, y: (h - 7) / 2, width: 7, height: 7)
        let l = label.fittingSize
        label.frame = CGRect(x: dot.frame.maxX + 7, y: (h - l.height) / 2, width: l.width, height: l.height)
        let s = stop.fittingSize
        stop.frame = CGRect(x: label.frame.maxX + 10, y: (h - s.height) / 2, width: s.width, height: s.height)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var stopCenter: CGPoint { CGPoint(x: stop.frame.midX, y: stop.frame.midY) }

    @objc private func stopClicked() { onStop?() }
}
