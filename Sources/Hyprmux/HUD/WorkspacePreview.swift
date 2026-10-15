import AppKit
import HyprmuxCore

/// Live mirrors of layers through Core Animation's private `CAPortalLayer`. The render
/// server draws the source layer's tree a second time, so a mirror copies no pixels and
/// stays current. A source must be in the same window and not hidden; at opacity 0 it
/// still mirrors (`matchesOpacity` is off).
enum LayerPortal {
    private static let portalClass: CALayer.Type? = {
        guard let c = NSClassFromString("CAPortalLayer") as? CALayer.Type else {
            log.info("CAPortalLayer unavailable: no workspace preview")
            return nil
        }
        let setters = ["setSourceLayer:", "setMatchesPosition:", "setMatchesOpacity:",
                       "setMatchesTransform:", "setHidesSourceLayer:"]
        guard setters.allSatisfy({ c.instancesRespond(to: NSSelectorFromString($0)) }) else {
            log.info("CAPortalLayer changed: no workspace preview")
            return nil
        }
        return c
    }()

    static var isAvailable: Bool { portalClass != nil }

    /// A layer that shows `source` centered on the portal's position: a portal draws
    /// its source's bounds centered on its own origin, whatever the anchor points.
    static func make(source: CALayer) -> CALayer? {
        guard let c = portalClass else { return nil }
        let p = c.init()
        p.setValue(source, forKey: "sourceLayer")
        for key in ["matchesPosition", "matchesOpacity", "matchesTransform", "hidesSourceLayer"] {
            p.setValue(false, forKey: key)
        }
        p.anchorPoint = .zero
        p.bounds = .zero
        return p
    }
}

/// The panel beside the workspace picker: the selected workspace in miniature, live.
/// Each tile is a portal of its content (the decoration's clip), placed at its frame on
/// a monitor-sized stage that is scaled down to fit, with an outline of its own. The
/// clip leaves out the tile's blur, which a portal can't draw, and the portal ignores
/// the clip's inactive opacity, so every tile shows at full strength.
final class WorkspacePreviewView: DecoratedView {
    /// Monitor-sized, scaled to the panel. Holds the portals.
    private let stage = CALayer()
    private let host = FlippedView()
    private let emptyLabel = NSTextField(labelWithString: "empty")
    private var tiles: [(source: CALayer, portal: CALayer, outline: CALayer, frame: CGRect)] = []
    private var monitor = CGSize(width: 16, height: 10)
    private var theme: HUDTheme

    init(theme: HUDTheme) {
        self.theme = theme
        super.init(decoration: theme.decoration, active: true, blurBlending: .withinWindow)
        host.wantsLayer = true
        host.layer?.masksToBounds = true
        stage.anchorPoint = .zero
        host.layer?.addSublayer(stage)
        clip.addSubview(host)
        emptyLabel.alignment = .center
        emptyLabel.isSelectable = false
        emptyLabel.drawsBackground = false
        emptyLabel.isBordered = false
        host.addSubview(emptyLabel)
        apply(theme)
        finishSetup()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(_ t: HUDTheme) {
        theme = t
        setDecoration(t.decoration, active: true, borderDuration: 0)
        clip.layer?.backgroundColor = t.background.cgColor
        emptyLabel.font = t.font
        emptyLabel.textColor = t.secondary
    }

    /// The panel's outer size for a stage of `monitor`'s shape, `width` wide.
    func size(width: CGFloat, monitor: CGSize) -> CGSize {
        let b = decoration.borderSize
        let inner = width - 2 * b
        let aspect = monitor.width > 0 ? monitor.height / monitor.width : 0.625
        return CGSize(width: width, height: round(inner * aspect) + 2 * b)
    }

    /// Shows these tiles, bottom to top: each one's content layer, centered in its outer
    /// frame in a monitor of size `monitor`. Portals are reused for layers already shown.
    func show(_ shown: [(layer: CALayer, frame: CGRect)], monitor: CGSize) {
        self.monitor = monitor
        var reusable = Dictionary(tiles.map { (ObjectIdentifier($0.source), $0) }, uniquingKeysWith: { a, _ in a })
        var next: [(source: CALayer, portal: CALayer, outline: CALayer, frame: CGRect)] = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (layer, frame) in shown {
            let id = ObjectIdentifier(layer)
            if let t = reusable.removeValue(forKey: id) {
                next.append((t.source, t.portal, t.outline, frame))
            } else if let p = LayerPortal.make(source: layer) {
                let outline = CALayer()
                outline.anchorPoint = .zero
                next.append((layer, p, outline, frame))
            }
        }
        stage.sublayers = next.flatMap { [$0.portal, $0.outline] }
        tiles = next
        CATransaction.commit()
        emptyLabel.isHidden = !shown.isEmpty
        layoutStage()
    }

    override func chromeDidLayout() {
        // The stage keeps its final size through the panel's open animation, centered in
        // the clip, so the portals never animate (like the picker's content).
        layoutStage()
    }

    override func targetFrameDidChange() { layoutStage() }

    private func layoutStage() {
        let b = decoration.borderSize
        let inner = CGSize(width: max(0, targetFrame.width - 2 * b), height: max(0, targetFrame.height - 2 * b))
        let clipBounds = clip.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.frame = CGRect(x: round((clipBounds.width - inner.width) / 2), y: round((clipBounds.height - inner.height) / 2),
                            width: inner.width, height: inner.height)
        let scale = monitor.width > 0 && monitor.height > 0
            ? min(inner.width / monitor.width, inner.height / monitor.height) : 0
        stage.bounds = CGRect(origin: .zero, size: monitor)
        stage.position = CGPoint(x: (inner.width - monitor.width * scale) / 2, y: (inner.height - monitor.height * scale) / 2)
        stage.transform = CATransform3DMakeScale(scale, scale, 1)
        // The outline keeps about a point on screen, whatever the scale.
        let d = theme.decoration
        let line = max(d.borderSize, scale > 0 ? 1 / scale : 1)
        let color = (d.inactiveBorder.colors.first ?? d.activeBorder.colors.first)?.cg ?? theme.secondary.cgColor
        for t in tiles {
            t.portal.position = CGPoint(x: t.frame.midX, y: t.frame.midY)
            t.outline.frame = t.frame
            t.outline.borderWidth = line
            t.outline.borderColor = color
            t.outline.cornerRadius = d.rounding
            t.outline.cornerCurve = d.roundingPower > 2 ? .continuous : .circular
        }
        let lineH = ceil(theme.font.ascender - theme.font.descender + theme.font.leading)
        emptyLabel.frame = CGRect(x: 0, y: (inner.height - lineH) / 2, width: inner.width, height: lineH)
        CATransaction.commit()
    }
}
