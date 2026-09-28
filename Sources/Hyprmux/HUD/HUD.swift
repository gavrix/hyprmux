import AppKit
import HyprmuxCore

/// The overlay above all tiles that holds Hyprmux's own UI. Like a Hyprland
/// overlay layer: it never tiles, and the gaps between its panels pass clicks
/// through to the tiles below.
final class HUDLayerView: FlippedView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        return v === self ? nil : v
    }
}

/// Hyprmux's own UI: owns the overlay layer, the theme, and the geometry HUD
/// elements are placed against, and runs their layer animations. Elements
/// (notifications now; menus and pickers later) are components on top of it.
final class HUD {
    let layer = HUDLayerView()
    private(set) var config: HyprmuxConfig
    private(set) var theme: HUDTheme
    let animator: Animator
    private(set) var monitor: CGRect = .zero
    private(set) var workArea: CGRect = .zero
    /// A tile's current frame, for `.client` anchors.
    var clientFrame: (ClientID) -> CGRect? = { _ in nil }
    /// Clicking a notice raised by a tile focuses that tile.
    var onFocusClient: ((ClientID) -> Void)?

    private(set) var notifications: NotificationStack!
    private(set) var picker: PickerPresenter!

    init(config: HyprmuxConfig, theme: HUDTheme, animator: Animator) {
        self.config = config
        self.theme = theme
        self.animator = animator
        layer.wantsLayer = true
        layer.layer?.masksToBounds = false
        notifications = NotificationStack(hud: self)
        picker = PickerPresenter(hud: self)
    }

    func reload(config: HyprmuxConfig, theme: HUDTheme) {
        self.config = config
        self.theme = theme
        notifications.reload()
        picker.reload()
    }

    /// The monitor window resized or the bar moved.
    func layout(monitor: CGRect, workArea: CGRect, animated: Bool) {
        let changed = monitor != self.monitor || workArea != self.workArea
        self.monitor = monitor
        self.workArea = workArea
        layer.frame = monitor
        if changed {
            notifications.relayout(animated: animated)
            picker.relayout()
        }
    }

    /// Whether a point (monitor coordinates) is over a HUD element, so tile clicks and
    /// focus-follows-mouse leave it alone.
    func contains(_ p: CGPoint) -> Bool {
        layer.subviews.contains { !$0.isHidden && $0.alphaValue > 0 && $0.frame.contains(p) }
    }

    /// Frames of the HUD panels on screen, for `hyprmuxctl debug`.
    var debugFrames: [CGRect] {
        layer.subviews.filter { !($0 is PickerScrim) && !$0.isHidden && $0.alphaValue > 0 }.map(\.frame)
    }

    /// The open picker, for `hyprmuxctl debug`.
    var debugPicker: Any {
        guard let p = picker.current else { return NSNull() }
        return ["title": p.title, "query": p.query, "selection": p.selection as Any? ?? NSNull(),
                "rows": p.rows.map { p.items[$0.index].title }]
    }

    func area(for anchor: HUDAnchor) -> CGRect? {
        HUDLayout.area(for: anchor, monitor: monitor, workArea: workArea, clientFrame: clientFrame)
    }

    /// Distance from the monitor window's edges, like a tile's outer gap.
    var margin: CGFloat { CGFloat(max(config.wm.gapsOut.top, config.wm.gapsOut.right)) }
    /// Space between stacked elements, like the gap between two tiles.
    var spacing: CGFloat { CGFloat(config.wm.gapsIn.top + config.wm.gapsIn.bottom) }

    // MARK: Layer animations

    /// The configured style for `layersIn` / `layersOut`, or the element's own default.
    private func style(_ name: String, default fallback: LayerAnimationStyle) -> LayerAnimationStyle {
        config.animation(name).style.map { LayerAnimationStyle($0) } ?? fallback
    }

    /// Where a slide starts or ends: just past the monitor edge, clear of the shadow.
    private func offscreen(_ frame: CGRect, style: LayerAnimationStyle, position: HUDPosition) -> CGRect {
        let extra = CGFloat(config.shadowRange) * 2 + 4
        let distance: CGFloat = switch style.slideEdge(at: position) {
        case .left: frame.maxX - monitor.minX + extra
        case .right: monitor.maxX - frame.minX + extra
        case .up: frame.maxY - monitor.minY + extra
        case .down: monitor.maxY - frame.minY + extra
        case nil: 0
        }
        return style.offscreen(frame, position: position, distance: distance)
    }

    private func duration(_ a: ResolvedAnimation) -> Double { a.enabled ? a.duration : 0 }

    /// Shows `view` at `frame` with layersIn and fadeLayersIn.
    func animateIn(_ view: DecoratedView, to frame: CGRect, position: HUDPosition, defaultStyle: LayerAnimationStyle) {
        if view.superview !== layer { layer.addSubview(view) }
        let move = config.animation("layersIn")
        let fade = config.animation("fadeLayersIn")
        let s = style("layersIn", default: defaultStyle)
        view.move(to: frame, from: duration(move) > 0 ? offscreen(frame, style: s, position: position) : frame,
                  duration: duration(move), curve: move.curve, animator: animator)
        view.fade(from: duration(fade) > 0 ? 0 : 1, to: 1, duration: duration(fade), curve: fade.curve, animator: animator)
    }

    /// Hides `view` with layersOut and fadeLayersOut, then removes it.
    func animateOut(_ view: DecoratedView, position: HUDPosition, defaultStyle: LayerAnimationStyle) {
        let move = config.animation("layersOut")
        let fade = config.animation("fadeLayersOut")
        let s = style("layersOut", default: defaultStyle)
        let longest = max(duration(move), duration(fade))
        guard longest > 0 else {
            view.removeFromSuperview()
            return
        }
        let frame = view.targetFrame
        view.move(to: duration(move) > 0 ? offscreen(frame, style: s, position: position) : frame,
                  duration: duration(move), curve: move.curve, animator: animator)
        view.fade(to: 0, duration: duration(fade), curve: fade.curve, animator: animator)
        DispatchQueue.main.asyncAfter(deadline: .now() + longest) { [weak view] in view?.removeFromSuperview() }
    }

    /// Moves a shown element to a new spot (a stack reflowing), with the `layers` animation.
    func animateMove(_ view: DecoratedView, to frame: CGRect, animated: Bool) {
        guard view.targetFrame != frame else { return }
        let a = config.animation("layers")
        view.move(to: frame, duration: animated ? duration(a) : 0, curve: a.curve, animator: animator)
    }
}
