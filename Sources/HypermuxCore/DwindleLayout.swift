import CoreGraphics

public struct DwindleSettings: Equatable, Sendable {
    /// A node splits side by side when `width * multiplier > height`.
    public var splitWidthMultiplier: Double = 1.0
    /// 1.0 = even split. Clamped to 0.1...1.9, like Hyprland.
    public var defaultSplitRatio: Double = 1.0
    /// Keep each split's orientation once set, instead of recomputing it from aspect ratio.
    public var preserveSplit: Bool = false
    /// 0 = follow the focal point (mouse), 1 = new window goes left/top, 2 = right/bottom.
    public var forceSplit: Int = 0
    public init() {}
}

/// Binary space partition tree, modeled on Hyprland's dwindle layout.
public final class DwindleLayout {
    final class Node {
        weak var parent: Node?
        var client: ClientID?
        var children: [Node] = []
        /// false = children side by side (left | right); true = stacked (top / bottom).
        var splitTop = false
        var ratio: Double = 1.0
        var box: CGRect = .zero

        init(client: ClientID?) { self.client = client }
        var isLeaf: Bool { client != nil }
    }

    public var settings: DwindleSettings
    private(set) var root: Node?

    public init(settings: DwindleSettings = .init()) { self.settings = settings }

    public var isEmpty: Bool { root == nil }

    /// Clients in tree order (left/top first).
    public var clients: [ClientID] {
        var out: [ClientID] = []
        func walk(_ n: Node?) {
            guard let n else { return }
            if let c = n.client { out.append(c) } else { n.children.forEach(walk) }
        }
        walk(root)
        return out
    }

    public func contains(_ id: ClientID) -> Bool { leaf(id) != nil }

    // MARK: Mutations

    /// Inserts `id` by splitting a target leaf.
    ///
    /// The target is the leaf under `focalPoint` when given, else `target`, else
    /// the last leaf. The focal point also decides which half the new client takes,
    /// unless `forceSplit` overrides it. `focalDecidesSide` ignores `forceSplit`
    /// (used when moving a window, where the side must follow the direction).
    public func insert(
        _ id: ClientID,
        target: ClientID?,
        focalPoint: CGPoint?,
        area: CGRect,
        focalDecidesSide: Bool = false
    ) {
        precondition(!contains(id), "\(id) already in layout")
        guard let root else {
            self.root = Node(client: id)
            return
        }
        recalc(area)

        let targetNode: Node
        if let p = focalPoint, let n = leaf(at: p) {
            targetNode = n
        } else if let t = target, let n = leaf(t) {
            targetNode = n
        } else {
            targetNode = lastLeaf(root)
        }

        let box = targetNode.box
        let parent = Node(client: nil)
        parent.box = box
        parent.ratio = clampRatio(settings.defaultSplitRatio)
        let sideBySide = box.width * settings.splitWidthMultiplier > box.height
        parent.splitTop = !sideBySide

        let newNode = Node(client: id)
        let newFirst: Bool
        switch focalDecidesSide && focalPoint != nil ? 0 : settings.forceSplit {
        case 1: newFirst = true
        case 2: newFirst = false
        default:
            if let p = focalPoint {
                newFirst = sideBySide ? p.x < box.midX : p.y < box.midY
            } else {
                newFirst = false
            }
        }

        replace(targetNode, with: parent)
        parent.children = newFirst ? [newNode, targetNode] : [targetNode, newNode]
        newNode.parent = parent
        targetNode.parent = parent
    }

    public func remove(_ id: ClientID) {
        guard let node = leaf(id) else { return }
        guard let parent = node.parent else {
            root = nil
            return
        }
        let sibling = parent.children.first { $0 !== node }!
        replace(parent, with: sibling)
    }

    /// Flips the orientation of the split that contains `id`.
    public func toggleSplit(_ id: ClientID) {
        guard let p = leaf(id)?.parent else { return }
        p.splitTop.toggle()
    }

    /// Swaps the two halves of the split that contains `id`.
    public func swapSplit(_ id: ClientID) {
        guard let p = leaf(id)?.parent else { return }
        p.children.reverse()
    }

    /// Adds `delta` to (or, when `exact`, sets) the ratio of the split containing `id`.
    public func splitRatio(_ id: ClientID, _ value: Double, exact: Bool) {
        guard let p = leaf(id)?.parent else { return }
        p.ratio = clampRatio(exact ? value : p.ratio + value)
    }

    public func swap(_ a: ClientID, _ b: ClientID) {
        guard let na = leaf(a), let nb = leaf(b) else { return }
        na.client = b
        nb.client = a
    }

    /// Grows the client by `dx`/`dy` points. Moves its right/bottom edge when it
    /// can, else its left/top edge. Needs a prior `layout(in:)` for current boxes.
    public func resize(_ id: ClientID, dx: Double, dy: Double) {
        guard let node = leaf(id) else { return }
        if dx != 0 { resizeAxis(node, delta: dx, splitTop: false) }
        if dy != 0 { resizeAxis(node, delta: dy, splitTop: true) }
    }

    private func resizeAxis(_ node: Node, delta: Double, splitTop: Bool) {
        // First choice: an ancestor where we sit in the first half (our far edge moves).
        // Fallback: an ancestor where we sit in the second half (our near edge moves).
        var firstHalf: Node?
        var secondHalf: Node?
        var child = node
        var cur = node.parent
        while let p = cur {
            if p.splitTop == splitTop {
                if p.children[0] === child {
                    if firstHalf == nil { firstHalf = p }
                } else if secondHalf == nil {
                    secondHalf = p
                }
            }
            if firstHalf != nil { break }
            child = p
            cur = p.parent
        }
        if let p = firstHalf {
            let size = splitTop ? p.box.height : p.box.width
            guard size > 0 else { return }
            p.ratio = clampRatio(p.ratio + delta * 2 / size)
        } else if let p = secondHalf {
            let size = splitTop ? p.box.height : p.box.width
            guard size > 0 else { return }
            p.ratio = clampRatio(p.ratio - delta * 2 / size)
        }
    }

    // MARK: Layout

    /// Computes each client's box inside `area` (gaps not applied).
    @discardableResult
    public func layout(in area: CGRect) -> [ClientID: CGRect] {
        recalc(area)
        var out: [ClientID: CGRect] = [:]
        func walk(_ n: Node?) {
            guard let n else { return }
            if let c = n.client { out[c] = n.box } else { n.children.forEach(walk) }
        }
        walk(root)
        return out
    }

    private func recalc(_ area: CGRect) {
        func apply(_ n: Node, _ box: CGRect) {
            n.box = box
            guard !n.isLeaf else { return }
            if !settings.preserveSplit {
                n.splitTop = !(box.width * settings.splitWidthMultiplier > box.height)
            }
            let a: CGRect, b: CGRect
            if n.splitTop {
                let h = (box.height / 2 * n.ratio).rounded()
                a = CGRect(x: box.minX, y: box.minY, width: box.width, height: h)
                b = CGRect(x: box.minX, y: box.minY + h, width: box.width, height: box.height - h)
            } else {
                let w = (box.width / 2 * n.ratio).rounded()
                a = CGRect(x: box.minX, y: box.minY, width: w, height: box.height)
                b = CGRect(x: box.minX + w, y: box.minY, width: box.width - w, height: box.height)
            }
            apply(n.children[0], a)
            apply(n.children[1], b)
        }
        if let root { apply(root, area) }
    }

    // MARK: Helpers

    private func clampRatio(_ r: Double) -> Double { min(max(r, 0.1), 1.9) }

    private func leaf(_ id: ClientID) -> Node? {
        func find(_ n: Node?) -> Node? {
            guard let n else { return nil }
            if n.client == id { return n }
            for c in n.children { if let f = find(c) { return f } }
            return nil
        }
        return find(root)
    }

    private func leaf(at p: CGPoint) -> Node? {
        var leaves: [Node] = []
        func walk(_ n: Node?) {
            guard let n else { return }
            if n.isLeaf { leaves.append(n) } else { n.children.forEach(walk) }
        }
        walk(root)
        if let hit = leaves.first(where: { $0.box.contains(p) }) { return hit }
        return leaves.min { $0.box.distance(to: p) < $1.box.distance(to: p) }
    }

    private func lastLeaf(_ n: Node) -> Node {
        n.isLeaf ? n : lastLeaf(n.children[1])
    }

    private func replace(_ old: Node, with new: Node) {
        if let p = old.parent {
            let i = p.children.firstIndex { $0 === old }!
            p.children[i] = new
            new.parent = p
        } else {
            root = new
            new.parent = nil
        }
    }
}
