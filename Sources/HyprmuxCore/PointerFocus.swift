import CoreGraphics

/// How focus and the pointer affect each other, both ways.
///
/// - Pointer to focus (`input:mouse_refocus`): with focus-follows-mouse, should moving
///   inside a tile refocus it? Off by default: only crossing into another tile moves
///   focus. A tile that moves under a resting pointer (a layout change) is not a
///   crossing. Without this, a keyboard focus change was undone by the next mouse bump.
/// - Focus to pointer (`cursor:no_warps`): when focus moves without the pointer
///   (keyboard, `hyprmuxctl`), should the pointer jump to the middle of the new tile?
///   Hyprland warps by default. Hyprmux doesn't: macOS apps don't move the pointer on
///   their own, so a jump would look like a bug.
public struct PointerFocus: Sendable {
    public var mouseRefocus = false
    public var warps = false
    /// The tile under the pointer at its last move or layout.
    public private(set) var hovered: ClientID?
    /// The focused tile at the last layout.
    public private(set) var focused: ClientID?

    public init(mouseRefocus: Bool = false, warps: Bool = false) {
        self.mouseRefocus = mouseRefocus
        self.warps = warps
    }

    /// The pointer moved over `tile` (nil over a gap, a HUD panel, or nothing).
    /// Returns the tile focus-follows-mouse should focus, if any.
    public mutating func pointerMoved(over tile: ClientID?, focused: ClientID?) -> ClientID? {
        let crossed = tile != hovered
        hovered = tile
        guard let tile, tile != focused, crossed || mouseRefocus else { return nil }
        return tile
    }

    /// A layout was applied. Returns the point (monitor coordinates) to warp the pointer
    /// to, if any.
    /// - focus: the focused tile now, and its frame.
    /// - pointer: where the pointer is now; nil when unknown.
    /// - under: the tile under the pointer now.
    /// - mayWarp: false when the pointer itself caused this change (a hover, click, or
    ///   drag), or Hyprmux isn't the active app. The change is still taken in, so it
    ///   doesn't warp later.
    public mutating func layoutApplied(focus: ClientID?, frame: CGRect?, pointer: CGPoint?,
                                       under: ClientID?, mayWarp: Bool) -> CGPoint? {
        let changed = focus != focused
        focused = focus
        hovered = under
        guard warps, mayWarp, changed, let focus, let frame, !frame.isEmpty else { return nil }
        if let pointer, frame.contains(pointer) { return nil }
        hovered = focus
        return CGPoint(x: frame.midX, y: frame.midY)
    }
}
