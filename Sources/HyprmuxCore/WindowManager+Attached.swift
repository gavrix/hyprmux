import CoreGraphics

/// Attached clients: terminals that belong to another tile, like a build an agent runs.
/// They aren't in the layout. A tile with jobs gets a job bar along its bottom edge, one
/// chip per job, and its content shrinks to make room: jobs never cover it. Hovering a
/// chip peeks at its job (a scaled live preview above the chip); focusing a job expands
/// it over its tile, clear of the bar. Jobs move, hide, and slide with their tile.
///
/// The expanded frame doubles as the peek's logical size: the peek is the same terminal
/// scaled down, so expanding never resizes it.
public struct AttachedSettings: Equatable, Sendable {
    /// Peek size relative to the expanded frame.
    public var scale: Double = 0.4
    /// Space between a peek and the job bar, and between a peek and its tile's sides.
    public var margin: Double = 8
    /// How far the expanded frame sits inside the parent's (above the job bar).
    public var expandInset: Double = 24
    /// The job bar's height, inside the parent's border.
    public var barHeight: Double = 22
    public init() {}
}

/// An attached client's placement details.
public struct AttachmentInfo: Equatable, Sendable {
    public let parent: ClientID
    /// Focused: shown over the parent at `expandedFrame`.
    public let expanded: Bool
    /// False until the host reveals it (a command that ends quickly never shows).
    public let revealed: Bool
    /// The frame it has when expanded, also its logical size while it's a peek.
    public let expandedFrame: CGRect
    /// Shown as a peek above its chip.
    public var peeked: Bool = false
}

/// A tile's job bar: its revealed jobs, oldest first. On the parent's placement.
public struct JobBarInfo: Equatable, Sendable {
    public let members: [ClientID]
    /// The member that's focused, so shown expanded.
    public let expanded: ClientID?
    /// The member shown as a peek.
    public let peeked: ClientID?
    /// The bar's height, inside the tile's border.
    public let height: Double
}

struct Attachment {
    var parent: ClientID
    var revealed: Bool
}

/// The job a pointer over its chip peeks at, and the chip's center.
struct Peek: Equatable {
    var id: ClientID
    var anchorX: Double?
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

    /// Whether `id` is a revealed job that isn't expanded: a chip, maybe peeked.
    public func isCollapsedAttached(_ id: ClientID) -> Bool {
        guard let a = clients[id]?.attachment else { return false }
        return a.revealed && focused != id
    }

    /// The job shown as a peek, if any.
    public var peekedAttached: ClientID? {
        guard let p = peek, isCollapsedAttached(p.id) else { return nil }
        return p.id
    }

    /// Peeks at a job (hovering its chip), or ends the peek with nil. `anchorX` is the
    /// chip's center, in monitor coordinates: the peek centers on it. Returns whether
    /// anything changed. Focusing the job ends its peek: it expands instead.
    @discardableResult
    public func peekAttached(_ id: ClientID?, anchorX: Double? = nil) -> Bool {
        let next: Peek?
        if let id, isCollapsedAttached(id) { next = Peek(id: id, anchorX: anchorX) } else { next = nil }
        let before = (peekedAttached, peek?.anchorX)
        peek = next
        return before != (peekedAttached, peek?.anchorX)
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

    /// Adds attached clients' placements after their parents', and the job bar to each
    /// parent with revealed jobs. A collapsed job is hidden unless it's peeked.
    func addAttachedPlacements(_ out: inout [Placement]) {
        var byParent: [ClientID: [ClientID]] = [:]
        for (id, st) in clients {
            if let p = st.attachment?.parent { byParent[p, default: []].append(id) }
        }
        guard !byParent.isEmpty else { return }
        let s = settings.attached, border = settings.borderSize
        let peeked = peekedAttached
        var added: [Placement] = []
        for i in out.indices {
            let p = out[i]
            guard let kids = byParent[p.id]?.sorted() else { continue }
            let members = kids.filter { clients[$0]?.attachment?.revealed == true }
            let bar = members.isEmpty ? 0 : Self.barHeight(p.frame, border: border, s)
            if !members.isEmpty {
                out[i].jobs = JobBarInfo(members: members, expanded: members.first { $0 == focused },
                                         peeked: peeked.flatMap { members.contains($0) ? $0 : nil }, height: bar)
            }
            let expanded = Self.expandedFrame(p.frame, bar: bar, s)
            let anchor = peek.flatMap { peeked == $0.id ? $0.anchorX : nil }
            for id in kids {
                guard let a = clients[id]?.attachment else { continue }
                let isExpanded = focused == id && a.revealed
                let isPeeked = peeked == id
                let frame = isExpanded ? expanded : Self.peekFrame(
                    parent: p.frame, expanded: expanded, bar: bar, anchorX: isPeeked ? anchor : nil,
                    border: border, s)
                var placement = Placement(
                    id: id, workspace: p.workspace, frame: frame,
                    visible: p.visible && (isExpanded || isPeeked), focused: focused == id, floating: false,
                    fullscreen: nil, z: p.z)
                placement.attachment = AttachmentInfo(parent: p.id, expanded: isExpanded,
                                                      revealed: a.revealed, expandedFrame: expanded, peeked: isPeeked)
                added.append(placement)
            }
        }
        out += added
    }

    /// The job bar's height on a tile of this frame: the setting, at most half its content.
    static func barHeight(_ parent: CGRect, border: Double, _ s: AttachedSettings) -> Double {
        max(0, min(s.barHeight, (Double(parent.height) - 2 * border) / 2))
    }

    /// The job bar, in monitor coordinates: along the bottom, inside the border.
    public static func jobBarFrame(parent: CGRect, height: Double, border: Double) -> CGRect {
        let b = CGFloat(border)
        return CGRect(x: parent.minX + b, y: parent.maxY - b - CGFloat(height),
                      width: max(0, parent.width - 2 * b), height: CGFloat(height))
    }

    /// Over the parent, minus a margin, and clear of its job bar.
    static func expandedFrame(_ parent: CGRect, bar: Double, _ s: AttachedSettings) -> CGRect {
        var area = parent
        area.size.height = max(1, area.height - CGFloat(bar))
        let inset = min(s.expandInset, max(0, min(area.width, area.height) / 2 - 40))
        return area.insetBy(dx: inset, dy: inset).integral
    }

    /// A peek: the expanded content scaled, plus the border, just above the job bar.
    /// Centered on `anchorX` (its chip), kept inside the parent; at the right without one.
    static func peekFrame(parent: CGRect, expanded: CGRect, bar: Double, anchorX: Double?,
                          border: Double, _ s: AttachedSettings) -> CGRect {
        let b = CGFloat(border)
        let contentW = max(1, expanded.width - 2 * b), contentH = max(1, expanded.height - 2 * b)
        let w = (contentW * s.scale).rounded() + 2 * b
        let h = (contentH * s.scale).rounded() + 2 * b
        let m = CGFloat(s.margin)
        let minX = parent.minX + b + m, maxX = max(minX, parent.maxX - b - m - w)
        let x = anchorX.map { min(max(CGFloat($0) - w / 2, minX), maxX) } ?? maxX
        let bottom = parent.maxY - b - CGFloat(bar) - m
        return CGRect(x: x.rounded(), y: max(parent.minY + b, bottom - h), width: w, height: h)
    }
}
