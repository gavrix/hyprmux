// The dwindle layout: a port of Sources/HyprmuxCore/DwindleLayout.swift.
// A binary tree. Leaves hold clients; each split halves its box by `ratio`.
// Rects are { x, y, w, h } in pixels.

export const defaultSettings = {
  splitWidthMultiplier: 1.0, // a split goes side by side when width × this > height
  defaultSplitRatio: 1.0,    // 1.0 = even
  preserveSplit: false,      // recompute each split's direction from its shape
  forceSplit: 0,             // 0 = toward the focal point, 1 = left/top, 2 = right/bottom
};

const clampRatio = (r) => Math.min(Math.max(r, 0.1), 1.9);

const contains = (r, p) => p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h;

function distance(r, p) {
  const cx = Math.min(Math.max(p.x, r.x), r.x + r.w);
  const cy = Math.min(Math.max(p.y, r.y), r.y + r.h);
  return Math.hypot(cx - p.x, cy - p.y);
}

class Node {
  constructor(client = null) {
    this.client = client;
    this.parent = null;
    this.children = [];
    this.splitTop = false; // false = side by side, true = stacked
    this.ratio = 1.0;
    this.box = { x: 0, y: 0, w: 0, h: 0 };
  }
  get isLeaf() { return this.client !== null; }
}

export class Dwindle {
  constructor(settings = {}) {
    this.settings = { ...defaultSettings, ...settings };
    this.root = null;
  }

  get isEmpty() { return this.root === null; }

  /** Clients in tree order, left/top first. */
  get clients() {
    const out = [];
    const walk = (n) => {
      if (!n) return;
      if (n.isLeaf) out.push(n.client);
      else n.children.forEach(walk);
    };
    walk(this.root);
    return out;
  }

  contains(id) { return this.#leaf(id) !== null; }

  /**
   * Splits a leaf to make room for `id`. The leaf under `focal` wins, then
   * `target`, then the last leaf. The focal point also picks the half the new
   * client takes, unless forceSplit says otherwise.
   */
  insert(id, { target = null, focal = null, area, focalDecidesSide = false }) {
    if (this.contains(id)) throw new Error(`${id} is already in the layout`);
    if (!this.root) {
      this.root = new Node(id);
      return;
    }
    this.#recalc(area);

    const targetNode =
      (focal && this.#leafAt(focal)) ||
      (target !== null && this.#leaf(target)) ||
      this.#lastLeaf(this.root);

    const box = targetNode.box;
    const parent = new Node();
    parent.box = { ...box };
    parent.ratio = clampRatio(this.settings.defaultSplitRatio);
    const sideBySide = box.w * this.settings.splitWidthMultiplier > box.h;
    parent.splitTop = !sideBySide;

    const newNode = new Node(id);
    let newFirst = false;
    const mode = focalDecidesSide && focal ? 0 : this.settings.forceSplit;
    if (mode === 1) newFirst = true;
    else if (mode === 2) newFirst = false;
    else if (focal) newFirst = sideBySide ? focal.x < box.x + box.w / 2 : focal.y < box.y + box.h / 2;

    this.#replace(targetNode, parent);
    parent.children = newFirst ? [newNode, targetNode] : [targetNode, newNode];
    newNode.parent = parent;
    targetNode.parent = parent;
  }

  remove(id) {
    const node = this.#leaf(id);
    if (!node) return;
    if (!node.parent) {
      this.root = null;
      return;
    }
    const sibling = node.parent.children.find((c) => c !== node);
    this.#replace(node.parent, sibling);
  }

  /** Flips the direction of the split that holds `id` (sticks only with preserveSplit). */
  toggleSplit(id) {
    const p = this.#leaf(id)?.parent;
    if (p) p.splitTop = !p.splitTop;
  }

  /** Swaps the two halves of the split that holds `id`. */
  swapSplit(id) {
    const p = this.#leaf(id)?.parent;
    if (p) p.children.reverse();
  }

  /** Adds `value` to (or, when `exact`, sets) the ratio of the split that holds `id`. */
  splitRatio(id, value, exact = false) {
    const p = this.#leaf(id)?.parent;
    if (p) p.ratio = clampRatio(exact ? value : p.ratio + value);
  }

  /** Puts `replacement` in `old`'s leaf, same box and splits. Groups switch tabs with it. */
  replaceClient(old, replacement) {
    if (this.contains(replacement)) throw new Error(`${replacement} is already in the layout`);
    const n = this.#leaf(old);
    if (n) n.client = replacement;
  }

  swap(a, b) {
    const na = this.#leaf(a);
    const nb = this.#leaf(b);
    if (!na || !nb) return;
    na.client = b;
    nb.client = a;
  }

  /**
   * Grows `id` by dx/dy pixels. Moves its right/bottom edge when it can, else its
   * left/top edge. Call layout() first so the boxes are current.
   */
  resize(id, dx, dy) {
    const node = this.#leaf(id);
    if (!node) return;
    if (dx) this.#resizeAxis(node, dx, false);
    if (dy) this.#resizeAxis(node, dy, true);
  }

  /**
   * Moves one edge of `id` by `delta` pixels (positive = right/down), whatever
   * that does to its size. Mouse resizes use it, so the grabbed edge follows the
   * pointer. Edges on the area's border don't move. Call layout() first.
   * `edge` is "l", "r", "u", or "d".
   */
  moveEdge(id, edge, delta) {
    const node = this.#leaf(id);
    if (!delta || !node) return;
    const splitTop = edge === "u" || edge === "d";
    // Right/bottom edge: the divider of the nearest ancestor where we're the first half.
    // Left/top edge: the divider of the nearest ancestor where we're the second half.
    const wantFirst = edge === "r" || edge === "d";
    let child = node;
    for (let p = node.parent; p; child = p, p = p.parent) {
      if (p.splitTop === splitTop && (p.children[0] === child) === wantFirst) {
        const size = splitTop ? p.box.h : p.box.w;
        if (size <= 0) return;
        p.ratio = clampRatio(p.ratio + (delta * 2) / size); // moving the divider d px changes ratio by 2d/size
        return;
      }
    }
  }

  /** A deep copy, to try a change and throw it away. */
  clone() {
    const copy = new Dwindle(this.settings);
    const dup = (n, parent) => {
      if (!n) return null;
      const m = new Node(n.client);
      m.parent = parent;
      m.splitTop = n.splitTop;
      m.ratio = n.ratio;
      m.box = { ...n.box };
      m.children = n.children.map((c) => dup(c, m));
      return m;
    };
    copy.root = dup(this.root, null);
    return copy;
  }

  /** Every split's ratio and direction, to undo a change the tree's shape survived. */
  snapshot() {
    const out = [];
    const walk = (n) => {
      if (!n || n.isLeaf) return;
      out.push([n.ratio, n.splitTop]);
      n.children.forEach(walk);
    };
    walk(this.root);
    return out;
  }

  restore(snap) {
    let i = 0;
    const walk = (n) => {
      if (!n || n.isLeaf) return;
      [n.ratio, n.splitTop] = snap[i++];
      n.children.forEach(walk);
    };
    walk(this.root);
  }

  /** Each client's box inside `area`, gaps not applied. */
  layout(area) {
    this.#recalc(area);
    const out = new Map();
    const walk = (n) => {
      if (!n) return;
      if (n.isLeaf) out.set(n.client, { ...n.box });
      else n.children.forEach(walk);
    };
    walk(this.root);
    return out;
  }

  #resizeAxis(node, delta, splitTop) {
    // First choice: an ancestor where we're the first half (our far edge moves).
    // Fallback: one where we're the second half (our near edge moves).
    let firstHalf = null;
    let secondHalf = null;
    let child = node;
    for (let p = node.parent; p; child = p, p = p.parent) {
      if (p.splitTop === splitTop) {
        if (p.children[0] === child) firstHalf ??= p;
        else secondHalf ??= p;
      }
      if (firstHalf) break;
    }
    const p = firstHalf ?? secondHalf;
    if (!p) return;
    const size = splitTop ? p.box.h : p.box.w;
    if (size <= 0) return;
    const change = (delta * 2) / size;
    p.ratio = clampRatio(p.ratio + (firstHalf ? change : -change));
  }

  #recalc(area) {
    const apply = (n, box) => {
      n.box = box;
      if (n.isLeaf) return;
      if (!this.settings.preserveSplit) {
        n.splitTop = !(box.w * this.settings.splitWidthMultiplier > box.h);
      }
      let a, b;
      if (n.splitTop) {
        const h = Math.round((box.h / 2) * n.ratio);
        a = { x: box.x, y: box.y, w: box.w, h };
        b = { x: box.x, y: box.y + h, w: box.w, h: box.h - h };
      } else {
        const w = Math.round((box.w / 2) * n.ratio);
        a = { x: box.x, y: box.y, w, h: box.h };
        b = { x: box.x + w, y: box.y, w: box.w - w, h: box.h };
      }
      apply(n.children[0], a);
      apply(n.children[1], b);
    };
    if (this.root) apply(this.root, { ...area });
  }

  #leaf(id) {
    const find = (n) => {
      if (!n) return null;
      if (n.client === id) return n;
      for (const c of n.children) {
        const f = find(c);
        if (f) return f;
      }
      return null;
    };
    return find(this.root);
  }

  #leafAt(p) {
    const leaves = [];
    const walk = (n) => {
      if (!n) return;
      if (n.isLeaf) leaves.push(n);
      else n.children.forEach(walk);
    };
    walk(this.root);
    const hit = leaves.find((l) => contains(l.box, p));
    if (hit) return hit;
    return leaves.reduce((best, l) => (!best || distance(l.box, p) < distance(best.box, p) ? l : best), null);
  }

  #lastLeaf(n) { return n.isLeaf ? n : this.#lastLeaf(n.children[1]); }

  #replace(old, replacement) {
    const p = old.parent;
    if (p) {
      p.children[p.children.indexOf(old)] = replacement;
      replacement.parent = p;
    } else {
      this.root = replacement;
      replacement.parent = null;
    }
  }
}

/**
 * The best neighbor of `from` in a direction: a port of DirectionalSearch.
 * Prefers candidates that overlap on the other axis, then the closest edge,
 * then the most recently focused. `candidates` is [[id, rect], ...].
 */
export function neighbor(from, direction, candidates, recency = new Map()) {
  const eps = 2;
  let best = null;
  const better = (a, b) => {
    if (a.overlaps !== b.overlaps) return a.overlaps;
    if (Math.abs(a.dist - b.dist) > eps) return a.dist < b.dist;
    if (a.recent !== b.recent) return a.recent > b.recent;
    return a.overlap > b.overlap;
  };
  for (const [id, r] of candidates) {
    let onSide, dist, overlap;
    const ox = Math.min(r.x + r.w, from.x + from.w) - Math.max(r.x, from.x);
    const oy = Math.min(r.y + r.h, from.y + from.h) - Math.max(r.y, from.y);
    switch (direction) {
      case "l": onSide = r.x + r.w <= from.x + eps; dist = from.x - (r.x + r.w); overlap = oy; break;
      case "r": onSide = r.x >= from.x + from.w - eps; dist = r.x - (from.x + from.w); overlap = oy; break;
      case "u": onSide = r.y + r.h <= from.y + eps; dist = from.y - (r.y + r.h); overlap = ox; break;
      case "d": onSide = r.y >= from.y + from.h - eps; dist = r.y - (from.y + from.h); overlap = ox; break;
    }
    if (!onSide) continue;
    const s = { id, overlaps: overlap > 0, dist: Math.max(0, dist), overlap, recent: recency.get(id) ?? -1 };
    if (!best || better(s, best)) best = s;
  }
  return best?.id ?? null;
}

/** Gaps like WindowManager.applyGaps: gaps_out on the area's edges, gaps_in inside. */
export function applyGaps(box, area, gapsIn, gapsOut) {
  const eps = 1;
  const top = Math.abs(box.y - area.y) < eps ? gapsOut : gapsIn;
  const left = Math.abs(box.x - area.x) < eps ? gapsOut : gapsIn;
  const right = Math.abs(box.x + box.w - (area.x + area.w)) < eps ? gapsOut : gapsIn;
  const bottom = Math.abs(box.y + box.h - (area.y + area.h)) < eps ? gapsOut : gapsIn;
  return {
    x: box.x + left,
    y: box.y + top,
    w: Math.max(0, box.w - left - right),
    h: Math.max(0, box.h - top - bottom),
  };
}
