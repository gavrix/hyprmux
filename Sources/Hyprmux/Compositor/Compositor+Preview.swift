import AppKit
import HyprmuxCore

/// What the workspace picker's preview shows, and the tiles it brought out of hiding.
struct WorkspacePreviewState {
    let view: WorkspacePreviewView
    var workspace: WorkspaceID?
    /// Tiles of a hidden workspace made drawable for the preview, with their alpha before.
    var revealed: [ClientID: CGFloat] = [:]
}

/// The live workspace preview beside the workspace picker. Each tile shows through a
/// portal of its view (LayerPortal). A portal can't show a hidden view, so while a
/// hidden workspace is previewed its tiles are un-hidden at alpha 0 and told they're
/// visible again, so terminals keep drawing. The picker's scrim keeps clicks off them.
extension Compositor {
    func makeWorkspacePreview() -> PickerPreview? {
        // A picker replacing an open one closes it after this runs: end its preview now.
        endWorkspacePreview()
        guard config.hud.pickerPreview, LayerPortal.isAvailable else { return nil }
        let view = WorkspacePreviewView(theme: hud.theme)
        workspacePreview = WorkspacePreviewState(view: view)
        return PickerPreview(view: view, delay: config.hud.pickerPreviewDelay, onSelect: { [weak self, weak view] item in
            guard let self, let view, self.workspacePreview?.view === view else { return }
            self.workspacePreview?.workspace = item.flatMap { WorkspacePicker.workspace(forItem: $0.id) }
            self.refreshWorkspacePreview()
        }, onClose: { [weak self, weak view] in
            guard let self, self.workspacePreview?.view === view else { return }
            self.endWorkspacePreview()
        })
    }

    /// Shows the selected workspace's tiles as they are now. `apply` calls it, so the
    /// preview follows tiles that open, close, or move while the picker is open.
    func refreshWorkspacePreview() {
        guard var state = workspacePreview else { return }
        let snap = wm.snapshot()
        let tiles = state.workspace.map { snap.preview(of: $0) } ?? []
        var revealed: [ClientID: CGFloat] = [:]
        for p in tiles {
            guard let v = views[p.id] else { continue }
            if let alpha = state.revealed[p.id] {
                revealed[p.id] = alpha
            } else if !v.shown {
                revealed[p.id] = v.alphaValue
                reveal(v, at: p.frame)
            }
        }
        for (id, alpha) in state.revealed where revealed[id] == nil { conceal(id, alpha: alpha) }
        state.revealed = revealed
        workspacePreview = state
        let layers = tiles.compactMap { p in views[p.id]?.clip.layer.map { (layer: $0, frame: p.frame) } }
        state.view.show(layers, monitor: root.bounds.size)
    }

    /// The picker closed. The preview fades out with it, so its tiles hide once that's
    /// done, unless the choice showed their workspace (they're shown again then).
    func endWorkspacePreview() {
        guard let state = workspacePreview else { return }
        workspacePreview = nil
        let fade = max(config.animation("layersOut").duration, config.animation("fadeLayersOut").duration)
        DispatchQueue.main.asyncAfter(deadline: .now() + fade + 0.05) { [weak self] in
            guard let self else { return }
            for (id, alpha) in state.revealed where self.workspacePreview?.revealed[id] == nil {
                self.conceal(id, alpha: alpha)
            }
        }
    }

    private func reveal(_ v: ClientView, at frame: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        v.alphaValue = 0
        v.isHidden = false
        CATransaction.commit()
        // A slide-out leaves a hidden tile off screen until the next layout pass.
        if !v.isAnimating, v.targetFrame != frame { v.move(to: frame, duration: 0, curve: .linear) }
        v.surface.setOccluded(false)
    }

    /// Hides a revealed tile again, if its workspace still isn't showing.
    private func conceal(_ id: ClientID, alpha: CGFloat) {
        guard let v = views[id], !v.shown else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        v.isHidden = true
        v.alphaValue = alpha
        CATransaction.commit()
        v.surface.setOccluded(true)
    }
}
