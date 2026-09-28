import AppKit
import HyprmuxCore

/// Shows one picker at a time and holds the keyboard while it's open, like a
/// Hyprland layer with exclusive keyboard focus: binds are off, keys go to the
/// picker, and Escape or a click outside closes it.
final class PickerPresenter {
    private unowned let hud: HUD
    private var view: PickerView?
    private let scrim = PickerScrim()
    private var anchor: HUDAnchor = .monitor(.center)
    private var completion: ((PickerResult?) -> Void)?
    /// Pickers pop in unless the config sets a layers style.
    private let defaultStyle = LayerAnimationStyle.popin(0.9)

    /// Runs after the picker closes and before its completion, so the host can put
    /// keyboard focus back on a tile.
    var onClose: (() -> Void)?

    init(hud: HUD) {
        self.hud = hud
        scrim.onClick = { [weak self] in self?.finish(nil) }
    }

    var isOpen: Bool { view != nil }
    var current: Picker? { view?.picker }

    /// Opens `picker`, replacing (cancelling) one that's already open. `completion` gets
    /// the choice, or nil when cancelled.
    func present(_ picker: Picker, anchor: HUDAnchor = .monitor(.center), completion: @escaping (PickerResult?) -> Void) {
        if isOpen { finish(nil) }
        self.anchor = anchor
        self.completion = completion
        let v = PickerView(picker: picker, theme: hud.theme)
        v.onPick = { [weak self, weak v] row in
            guard let self, let v else { return }
            v.select(row)
            self.accept()
        }
        view = v
        // Above the scrim, below any notification.
        scrim.frame = hud.layer.bounds
        hud.layer.addSubview(scrim, positioned: .below, relativeTo: nil)
        hud.layer.addSubview(v, positioned: .above, relativeTo: scrim)
        hud.animateIn(v, to: frame(for: v), position: anchor.position, defaultStyle: defaultStyle)
        if let w = hud.layer.window { focus(in: w) }
        log.debug("picker open title=\(picker.title, privacy: .public) items=\(picker.items.count)")
    }

    func cancel() { if isOpen { finish(nil) } }

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
        case 0x35: finish(nil)                                           // escape
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
        hud.animateMove(v, to: frame(for: v), animated: false)
    }

    /// Config reloaded: restyle in place, keeping the query and selection.
    func reload() {
        guard let v = view else { return }
        v.apply(hud.theme)
        relayout()
    }

    private func frame(for v: PickerView) -> CGRect {
        let area = hud.area(for: anchor) ?? hud.monitor
        let width = min(CGFloat(hud.config.hud.pickerWidth), area.width - 2 * hud.margin)
        let height = v.layout(width: width)
        return HUDLayout.place(CGSize(width: width, height: height), at: anchor.position, in: area, margin: hud.margin)
    }

    private func accept() {
        guard let r = view?.picker.result else { NSSound.beep(); return }
        finish(r)
    }

    private func finish(_ result: PickerResult?) {
        guard let v = view else { return }
        view = nil
        scrim.removeFromSuperview()
        // Give up the keyboard before the panel animates away.
        if let w = v.window, let editor = w.firstResponder as? NSTextView, editor.delegate === v.field {
            w.makeFirstResponder(nil)
        }
        hud.animateOut(v, position: anchor.position, defaultStyle: defaultStyle)
        let done = completion
        completion = nil
        onClose?()
        done?(result)
    }
}
