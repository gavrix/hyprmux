import CoreGraphics

/// Attached clients: terminals that belong to another tile, like a build an agent runs.
/// They aren't in the layout. Each sits on its parent as a small live preview, stacked
/// from the parent's top-right corner, and moves, hides, and slides with it. Focusing one
/// expands it over its parent; focus leaving collapses it again.
///
/// The expanded frame doubles as the preview's logical size: the preview is the same
/// terminal scaled down, so expanding never resizes it.
public struct AttachedSettings: Equatable, Sendable {
    /// Preview size relative to the expanded frame.
    public var scale: Double = 0.25
    /// Distance from the parent's outer edge to the previews.
    public var margin: Double = 12
    /// Space between previews.
    public var gap: Double = 8
    /// How far the expanded frame sits inside the parent's.
    public var expandInset: Double = 24
    public init() {}
}

/// An attached client's placement details.
public struct AttachmentInfo: Equatable, Sendable {
    public let parent: ClientID
    /// Focused: shown over the parent at `expandedFrame`.
    public let expanded: Bool
    /// False until the host reveals it (a command that ends quickly never shows).
    public let revealed: Bool
    /// The frame it has when expanded, also its logical size while it's a preview.
    public let expandedFrame: CGRect
}

struct Attachment {
    var parent: ClientID
    var revealed: Bool
}

extension WindowManager {
    /// Adds `id` attached to `parent`. An attached parent hands it to its own parent:
    /// attachments are one level deep. It never takes focus.
    public func addAttached(_ id: ClientID, to parent: ClientID, revealed: Bool = true) {
        precondition(clients[id] == nil, "\(id) already managed")
        guard let owner = clients[parent].map({ $0.attachment?.parent ?? parent }),
              let ws = clients[owner]?.workspace else { return }
        var state = ClientState(workspace: ws, floating: false)
        state.attachment = Attachment(parent: owner, revealed: revealed)
        clients[id] = state
    }

    public func setAttachedRevealed(_ id: ClientID, _ revealed: Bool) {
        guard clients[id]?.attachment != nil else { return }
        clients[id]!.attachment!.revealed = revealed
    }

    /// Whether an attached client shows (true for any other client).
    public func isAttachedRevealed(_ id: ClientID) -> Bool { clients[id]?.attachment?.revealed ?? true }

    /// The tile `id` is attached to, or nil.
    public func attachedParent(of id: ClientID) -> ClientID? { clients[id]?.attachment?.parent }

    /// Clients attached to `parent`, oldest first.
    public func attached(to parent: ClientID) -> [ClientID] {
        clients.compactMap { $0.value.attachment?.parent == parent ? $0.key : nil }.sorted()
    }

    /// Whether `id` shows as a preview now (attached, revealed, not focused).
    public func isCollapsedAttached(_ id: ClientID) -> Bool {
        guard let a = clients[id]?.attachment else { return false }
        return a.revealed && focused != id
    }

    /// The client that owns `id`'s place in the layout: its parent when attached.
    /// Moving, resizing, and dragging act on that one.
    public func layoutOwner(_ id: ClientID) -> ClientID { clients[id]?.attachment?.parent ?? id }

    /// Attached clients live on their parent's workspace.
    func syncAttachedWorkspaces() {
        for (id, st) in clients {
            guard let p = st.attachment?.parent, let ws = clients[p]?.workspace, st.workspace != ws else { continue }
            clients[id]!.workspace = ws
        }
    }

    /// Which dispatchers act on an attached client itself. The rest act on its parent's
    /// slot: an attached client has no place in the layout of its own.
    func actsOnAttached(_ d: Dispatcher) -> Bool {
        switch d {
        case .killActive, .find, .fillCredential, .webNav, .focusAttached: return true
        default: return false
        }
    }

    /// `focusattached`: from a parent, focus (and so expand) its most recent revealed
    /// attached client; from an attached client, go back to its parent.
    func focusAttached(_ subject: ClientID?) {
        guard let s = subject, clients[s] != nil else { return }
        if let parent = clients[s]?.attachment?.parent {
            focus(parent)
            return
        }
        let kids = attached(to: s).filter { clients[$0]?.attachment?.revealed == true }
        guard let pick = kids.max(by: { (recency[$0] ?? -1, $0.raw) < (recency[$1] ?? -1, $1.raw) }) else { return }
        focus(pick)
    }

    /// Placements for attached clients, from their parents' placements.
    func attachedPlacements(parents: [Placement]) -> [Placement] {
        let byID = Dictionary(parents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [Placement] = []
        var byParent: [ClientID: [ClientID]] = [:]
        for (id, st) in clients {
            if let p = st.attachment?.parent { byParent[p, default: []].append(id) }
        }
        for (parentID, kids) in byParent {
            guard let p = byID[parentID] else { continue }
            let expanded = Self.expandedFrame(p.frame, settings.attached)
            var slot = 0
            for id in kids.sorted() {
                guard let a = clients[id]?.attachment else { continue }
                let isFocused = focused == id
                let frame: CGRect
                if isFocused && a.revealed {
                    frame = expanded
                } else {
                    frame = Self.previewFrame(parent: p.frame, expanded: expanded, index: slot,
                                              border: settings.borderSize, settings.attached)
                }
                if a.revealed && !isFocused { slot += 1 }
                var placement = Placement(
                    id: id, workspace: p.workspace, frame: frame,
                    visible: p.visible && a.revealed, focused: isFocused, floating: false,
                    fullscreen: nil, z: p.z)
                placement.attachment = AttachmentInfo(parent: parentID, expanded: isFocused && a.revealed,
                                                      revealed: a.revealed, expandedFrame: expanded)
                out.append(placement)
            }
        }
        return out
    }

    static func expandedFrame(_ parent: CGRect, _ s: AttachedSettings) -> CGRect {
        let inset = min(s.expandInset, max(0, min(parent.width, parent.height) / 2 - 40))
        return parent.insetBy(dx: inset, dy: inset).integral
    }

    /// The preview's frame: the expanded content scaled, plus the border, in a grid that
    /// fills down from the parent's top-right corner, then leftward.
    static func previewFrame(parent: CGRect, expanded: CGRect, index: Int, border: Double,
                             _ s: AttachedSettings) -> CGRect {
        let b = CGFloat(border)
        let contentW = max(1, expanded.width - 2 * b), contentH = max(1, expanded.height - 2 * b)
        let w = (contentW * s.scale).rounded() + 2 * b
        let h = (contentH * s.scale).rounded() + 2 * b
        let m = CGFloat(s.margin), gap = CGFloat(s.gap)
        let rows = max(1, Int(((parent.height - 2 * m + gap) / (h + gap)).rounded(.down)))
        let col = CGFloat(index / rows), row = CGFloat(index % rows)
        return CGRect(x: parent.maxX - m - w - col * (w + gap), y: parent.minY + m + row * (h + gap),
                      width: w, height: h)
    }
}
