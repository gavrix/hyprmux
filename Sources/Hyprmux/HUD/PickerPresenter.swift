import AppKit
import HyprmuxCore

/// A live workspace preview to the right of a picker, and what to do as the selection
/// moves and when the picker closes.
struct PickerPreview {
    let view: WorkspacePreviewView
    /// Seconds the selection must rest before the preview appears. A quick choice never
    /// shows it. Zero: it opens with the picker.
    let delay: TimeInterval
    /// The selected row changed; nil when nothing matches.
    let onSelect: (PickerItem?) -> Void
    /// Runs as the picker closes, before its completion.
    let onClose: () -> Void
}

/// Shows one picker at a time and holds the keyboard while it's open, like a
/// Hyprland layer with exclusive keyboard focus: binds are off, keys go to the
/// picker, and Escape or a click outside closes it.
final class PickerPresenter {
    private unowned let hud: HUD
    private var view: PickerView?
    private var preview: PickerPreview?
    /// Whether the preview is on screen.
    private var previewShown = false
    /// Shows the preview once the selection has rested; restarted by every move.
    private var previewTimer: DispatchWorkItem?
    private let scrim = PickerScrim()
    private var anchor: HUDAnchor = .monitor(.center)
    private var completion: ((PickerResult?) -> Void)?
    private var requestID: UUID?
    /// Pickers pop in unless the config sets a layers style.
    private let defaultStyle = LayerAnimationStyle.popin(0.9)

    /// Runs after the picker closes and before its completion, so the host can put
    /// keyboard focus back on a tile.
    var onClose: (() -> Void)?

    /// Set just before opening a picker from a parent picker (the menu). The next
    /// `present` takes it: Escape in that picker then reopens the parent. Choosing,
    /// clicking outside, ⌃C, and being replaced still close it for good.
    var nextBack: (() -> Void)?
    private var back: (() -> Void)?

    init(hud: HUD) {
        self.hud = hud
        scrim.onClick = { [weak self] in self?.finish(nil) }
    }

    var isOpen: Bool { view != nil }
    var current: Picker? { view?.picker }

    /// Opens `picker`, replacing (cancelling) one that's already open. `completion` gets
    /// the choice, or nil when cancelled.
    func present(_ picker: Picker, anchor: HUDAnchor = .monitor(.center), icons: [String: NSImage] = [:],
                 requestID: UUID? = nil, preview: PickerPreview? = nil,
                 completion: @escaping (PickerResult?) -> Void) {
        if isOpen { finish(nil) }
        self.anchor = anchor
        self.completion = completion
        self.requestID = requestID
        back = nextBack
        nextBack = nil
        let v = PickerView(picker: picker, theme: hud.theme, icons: icons)
        v.onPick = { [weak self, weak v] row in
            guard let self, let v else { return }
            v.select(row)
            self.accept()
        }
        view = v
        self.preview = preview
        // Above the scrim, below any notification.
        scrim.frame = hud.layer.bounds
        hud.layer.addSubview(scrim, positioned: .below, relativeTo: nil)
        hud.layer.addSubview(v, positioned: .above, relativeTo: scrim)
        previewShown = preview.map { $0.delay <= 0 } ?? false
        let frames = frames(for: v)
        hud.animateIn(v, to: frames.picker, position: anchor.position, defaultStyle: defaultStyle)
        if let preview {
            hud.layer.addSubview(preview.view, positioned: .above, relativeTo: scrim)
            if previewShown, let f = frames.preview {
                hud.animateIn(preview.view, to: f, position: anchor.position, defaultStyle: defaultStyle)
            } else {
                preview.view.isHidden = true
            }
            v.onSelectionChange = { [weak self] item in self?.selectionChanged(item) }
            v.onChange = { [weak self] in self?.restartPreviewTimer() }
        }
        if let w = hud.layer.window { focus(in: w) }
        log.debug("picker open title=\(picker.title, privacy: .public) items=\(picker.items.count)")
    }

    func cancel() { if isOpen { finish(nil) } }

    // MARK: Preview

    private func selectionChanged(_ item: PickerItem?) {
        if previewShown {
            preview?.onSelect(item)
        } else {
            restartPreviewTimer()
        }
    }

    /// The selection or query moved before the preview appeared: wait again.
    private func restartPreviewTimer() {
        guard let preview, !previewShown else { return }
        previewTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.showPreview() }
        previewTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + preview.delay, execute: work)
    }

    /// The selection rested: the picker moves over and the preview comes in beside it,
    /// the two centered together.
    private func showPreview() {
        previewTimer = nil
        guard let v = view, let preview, !previewShown else { return }
        previewShown = true
        let frames = frames(for: v)
        guard let f = frames.preview else {
            previewShown = false
            return
        }
        preview.onSelect(v.picker.selectedItem)
        preview.view.isHidden = false
        hud.animateMove(v, to: frames.picker, animated: true)
        hud.animateIn(preview.view, to: f, position: anchor.position, defaultStyle: defaultStyle)
    }

    /// Closes the picker only if it's still the one opened with `requestID`.
    func cancel(requestID: UUID) {
        guard isOpen, self.requestID == requestID else { return }
        finish(nil)
    }

    /// Replaces rows in the current picker and resizes it. A request id prevents late
    /// asynchronous results from changing a newer picker.
    @discardableResult
    func update(items: [PickerItem], status: String?, icons: [String: NSImage], requestID: UUID) -> Bool {
        guard let v = view, self.requestID == requestID else { return false }
        v.update(items: items, status: status, icons: icons)
        relayout()
        return true
    }

    /// Keeps the keyboard on the query field.
    func focus(in window: NSWindow) {
        guard let v = view else { return }
        if let editor = window.firstResponder as? NSTextView, editor.delegate === v.field { return }
        window.makeFirstResponder(v.field)
    }

    /// Handles a key-down while open. Returns true if the picker used it; other keys go to
    /// the query field (typing, deleting, ⌘V, moving the cursor).
    func handleKey(_ e: NSEvent) -> Bool {
        guard let v = view else { return false }
        // Composing text (an IME): Return and the arrows belong to the input method.
        if let editor = v.field.currentEditor() as? NSTextView, editor.hasMarkedText() { return false }
        let f = e.modifierFlags.intersection([.command, .control, .option, .shift])
        // ⌘ and ⌥ combos go to the query field (⌘V, ⌥⌫); only the plain keys and the
        // fzf-style ⌃ keys drive the picker.
        guard f.isDisjoint(with: [.command, .option]) else { return false }
        let ctrl = f.contains(.control)
        switch e.keyCode {
        case 0x35: finish(nil, goBack: true)                             // escape
        case 0x08 where ctrl, 0x05 where ctrl: finish(nil)               // ⌃C, ⌃G (fzf)
        case 0x24, 0x4C: accept()                                        // return, keypad enter
        case 0x7E: v.move(-1)                                            // up
        case 0x7D: v.move(1)                                             // down
        case 0x23 where ctrl: v.move(-1)                                 // ⌃P
        case 0x2D where ctrl: v.move(1)                                  // ⌃N
        case 0x30: v.move(f.contains(.shift) ? -1 : 1)                   // tab, ⇧tab
        case 0x74: v.page(-1)                                            // page up
        case 0x79: v.page(1)                                             // page down
        default: return false
        }
        return true
    }

    /// The window resized: re-center.
    func relayout() {
        guard let v = view else { return }
        scrim.frame = hud.layer.bounds
        let frames = frames(for: v)
        hud.animateMove(v, to: frames.picker, animated: false)
        if let p = preview?.view, previewShown {
            p.isHidden = frames.preview == nil
            if let f = frames.preview { hud.animateMove(p, to: f, animated: false) }
        }
    }

    /// Config reloaded: restyle in place, keeping the query and selection.
    func reload() {
        guard let v = view else { return }
        v.apply(hud.theme)
        preview?.view.apply(hud.theme)
        relayout()
    }

    /// The picker's frame, and its preview's to the right while it shows and fits. The
    /// two are placed as one group, each centered on the group's middle line.
    private func frames(for v: PickerView) -> (picker: CGRect, preview: CGRect?) {
        let area = hud.area(for: anchor) ?? hud.monitor
        let room = area.width - 2 * hud.margin
        let width = min(CGFloat(hud.config.hud.pickerWidth), room)
        let height = v.layout(width: width)
        let size = CGSize(width: width, height: height)
        let alone = HUDLayout.place(size, at: anchor.position, in: area, margin: hud.margin)
        guard let p = preview?.view, previewShown else { return (alone, nil) }
        let gap = max(hud.spacing, 12)
        let minWidth: CGFloat = 160
        let tallest = area.height - 2 * hud.margin
        func previewSize(width w: CGFloat) -> CGSize {
            let s = p.size(width: w, monitor: hud.monitor.size)
            return s.height > tallest ? p.size(width: s.width * tallest / s.height, monitor: hud.monitor.size) : s
        }
        let s = previewSize(width: min(width, room - width - gap))
        guard s.width >= minWidth else { return (alone, nil) }
        let group = HUDLayout.place(CGSize(width: width + gap + s.width, height: max(height, s.height)),
                                    at: anchor.position, in: area, margin: hud.margin)
        let picker = CGRect(x: group.minX, y: round(group.midY - height / 2), width: width, height: height)
        let side = CGRect(x: group.minX + width + gap, y: round(group.midY - s.height / 2),
                          width: s.width, height: s.height)
        return (picker, side)
    }

    private func accept() {
        guard let picker = view?.picker else { return }
        guard let r = picker.result else {
            if picker.status == nil || !picker.items.isEmpty { NSSound.beep() }
            return
        }
        finish(r)
    }

    private func finish(_ result: PickerResult?, goBack: Bool = false) {
        guard let v = view else { return }
        view = nil
        let parent = goBack ? back : nil
        back = nil
        scrim.removeFromSuperview()
        // Give up the keyboard before the panel animates away.
        if let w = v.window, let editor = w.firstResponder as? NSTextView, editor.delegate === v.field {
            w.makeFirstResponder(nil)
        }
        hud.animateOut(v, position: anchor.position, defaultStyle: defaultStyle)
        let shownPreview = preview
        preview = nil
        previewShown = false
        previewTimer?.cancel()
        previewTimer = nil
        if let shownPreview {
            v.onSelectionChange = nil
            v.onChange = nil
            if shownPreview.view.isHidden {
                shownPreview.view.removeFromSuperview()
            } else {
                hud.animateOut(shownPreview.view, position: anchor.position, defaultStyle: defaultStyle)
            }
            shownPreview.onClose()
        }
        let done = completion
        completion = nil
        requestID = nil
        onClose?()
        done?(result)
        parent?()
    }
}
