// The hero compositor: dwindle tiles in the page's Hyprmux window.
// Mirrors WindowManager: focus, move, swap, resize, open, and close.

import { Dwindle, neighbor, applyGaps } from "./layout.js";
import { factories } from "./tiles.js";
import { durations, reducedMotion } from "./motion.js";

// The app's default config, at the width the app's window usually has.
const REFERENCE_WIDTH = 1180;
const GAPS_IN = 5;
const GAPS_OUT = 14;
const MAX_TILES = 8;
// The demo keeps tiles big enough to read. The app only clamps split ratios.
const MIN_TILE = 64;

export class Compositor {
  /** @param {HTMLElement} root the .hm window */
  constructor(root) {
    this.root = root;
    this.area = root.querySelector(".hm__area");
    // dwindle { preserve_split = true; force_split = 2 } from config/hyprmux.conf
    this.layout = new Dwindle({ preserveSplit: true, forceSplit: 2 });
    this.tiles = new Map();
    this.focused = null;
    this.recency = new Map();
    this.tick = 0;
    this.nextId = 1;
    this.listeners = new Set();

    this.#adoptStaticTiles();
    root.classList.add("hm--live");
    this.render({ instant: true });

    new ResizeObserver(() => this.render({ instant: true })).observe(this.area);
    this.area.addEventListener("pointermove", (e) => this.#followMouse(e));
    this.area.addEventListener("pointerdown", (e) => {
      const id = this.#tileAt(e);
      if (id !== null) this.focus(id);
    });
  }

  /** Called with (event, detail) after every change. */
  onChange(fn) {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  get count() { return this.tiles.size; }
  get focusedTile() { return this.tiles.get(this.focused) ?? null; }

  // ---------- Geometry ----------

  #metrics() {
    const w = this.area.clientWidth;
    const h = this.area.clientHeight;
    const s = Math.max(0.45, w / REFERENCE_WIDTH);
    return {
      area: { x: 0, y: 0, w, h },
      scale: s,
      gapsIn: GAPS_IN * s,
      gapsOut: Math.max(6, GAPS_OUT * s),
    };
  }

  /** Each tile's frame on screen, gaps applied. */
  frames() {
    const m = this.#metrics();
    const out = new Map();
    for (const [id, box] of this.layout.layout(m.area)) out.set(id, applyGaps(box, m.area, m.gapsIn, m.gapsOut));
    return out;
  }

  #tooSmall() {
    const min = MIN_TILE * this.#metrics().scale;
    for (const r of this.frames().values()) if (r.w < min || r.h < min) return true;
    return false;
  }

  render({ instant = false } = {}) {
    if (instant) this.root.classList.add("hm--instant");
    for (const [id, r] of this.frames()) {
      const tile = this.tiles.get(id);
      if (!tile) continue;
      const s = tile.el.style;
      s.left = `${Math.round(r.x)}px`;
      s.top = `${Math.round(r.y)}px`;
      s.width = `${Math.round(r.w)}px`;
      s.height = `${Math.round(r.h)}px`;
    }
    this.root.classList.toggle("hm--empty", this.tiles.size === 0);
    if (instant) {
      void this.area.offsetWidth; // apply without transitions
      this.root.classList.remove("hm--instant");
    }
  }

  // ---------- Focus ----------

  focus(id) {
    if (!this.tiles.has(id)) return;
    this.recency.set(id, ++this.tick);
    if (this.focused === id) return;
    this.focusedTile?.el.classList.remove("tile--focused");
    this.focused = id;
    this.tiles.get(id).el.classList.add("tile--focused");
    this.#emit("focus", { id, label: this.tiles.get(id).label });
  }

  moveFocus(dir) {
    const all = this.frames();
    const from = all.get(this.focused);
    if (!from) return false;
    const candidates = [...all].filter(([id]) => id !== this.focused);
    const next = neighbor(from, dir, candidates, this.recency);
    if (next === null) return false;
    this.focus(next);
    return true;
  }

  // ---------- Layout changes ----------

  /** movewindow: takes the window out and splits the neighbor in that direction. */
  moveWindow(dir) {
    const f = this.focused;
    const { area } = this.#metrics();
    const boxes = this.layout.layout(area);
    const box = boxes.get(f);
    if (!box || boxes.size < 2) return false;
    const focal = {
      l: { x: box.x - 1, y: box.y + box.h / 2 },
      r: { x: box.x + box.w + 1, y: box.y + box.h / 2 },
      u: { x: box.x + box.w / 2, y: box.y - 1 },
      d: { x: box.x + box.w / 2, y: box.y + box.h + 1 },
    }[dir];
    if (focal.x < 0 || focal.y < 0 || focal.x >= area.w || focal.y >= area.h) return false;
    this.layout.remove(f);
    this.layout.insert(f, { focal, area, focalDecidesSide: true });
    this.render();
    return true;
  }

  swapWindow(dir) {
    const all = this.frames();
    const from = all.get(this.focused);
    if (!from) return false;
    const other = neighbor(from, dir, [...all].filter(([id]) => id !== this.focused), this.recency);
    if (other === null) return false;
    this.layout.swap(this.focused, other);
    this.render();
    return true;
  }

  /** resizeactive, in the app's points at the reference width. */
  resizeActive(dx, dy) {
    if (this.focused === null || this.tiles.size < 2) return false;
    const m = this.#metrics();
    this.layout.layout(m.area);
    this.layout.resize(this.focused, dx * m.scale, dy * m.scale);
    if (this.#tooSmall()) {
      this.layout.layout(m.area);
      this.layout.resize(this.focused, -dx * m.scale, -dy * m.scale);
      return false;
    }
    this.render();
    return true;
  }

  toggleSplit() {
    if (this.focused === null || this.tiles.size < 2) return false;
    this.layout.toggleSplit(this.focused);
    if (this.#tooSmall()) this.layout.splitRatio(this.focused, 1, true);
    if (this.#tooSmall()) {
      this.layout.toggleSplit(this.focused);
      return false;
    }
    this.render();
    return true;
  }

  // ---------- Open and close ----------

  /** Opens a tile of `kind` next to the focused one. Returns false when the workspace is full. */
  open(kind) {
    if (this.tiles.size >= MAX_TILES) return false;
    const id = this.nextId;
    const { area } = this.#metrics();
    this.layout.insert(id, { target: this.focused, area });
    if (this.#tooSmall()) {
      this.layout.remove(id);
      return false;
    }
    const made = factories[kind]({ count: () => this.tiles.size + 1 });
    const el = document.createElement("div");
    el.className = "tile is-entering";
    el.append(made.frame);
    this.#add(el, made);

    // Place the new tile at its final frame first, so only the others slide.
    this.area.append(el);
    const r = this.frames().get(id);
    Object.assign(el.style, {
      left: `${Math.round(r.x)}px`, top: `${Math.round(r.y)}px`,
      width: `${Math.round(r.w)}px`, height: `${Math.round(r.h)}px`,
      transition: "none",
    });
    void el.offsetWidth;
    el.style.transition = "";
    requestAnimationFrame(() => el.classList.remove("is-entering"));

    this.render();
    this.focus(id);
    made.mount?.();
    this.#emit("open", { id, kind, label: made.label });
    return true;
  }

  close(id = this.focused) {
    const tile = this.tiles.get(id);
    if (!tile) return false;
    this.layout.remove(id);
    this.tiles.delete(id);
    this.recency.delete(id);
    tile.el.classList.remove("tile--focused");
    tile.el.classList.add("is-leaving");
    setTimeout(() => tile.el.remove(), reducedMotion() ? 0 : durations.windowsOut + 40);

    if (this.focused === id) {
      this.focused = null;
      const next = [...this.recency].sort((a, b) => b[1] - a[1])[0]?.[0];
      if (next !== undefined) this.focus(next);
    }
    this.render();
    this.#emit("close", { id, label: tile.label });
    return true;
  }

  // ---------- Internals ----------

  #add(el, { kind, label }) {
    const id = this.nextId++;
    el.dataset.id = String(id);
    el.setAttribute("aria-label", label);
    this.tiles.set(id, { id, el, kind, label });
    return id;
  }

  /** The tiles in the page's HTML become the first clients, opened in order like the app would. */
  #adoptStaticTiles() {
    const narrow = this.root.clientWidth < 560;
    const { area } = this.#metrics();
    for (const el of this.area.querySelectorAll(".tile")) {
      // The narrow layout has no room for the editor.
      if (narrow && el.dataset.kind === "editor") {
        el.remove();
        continue;
      }
      const id = this.#add(el, { kind: el.dataset.kind, label: el.dataset.label });
      this.layout.insert(id, { target: this.focused, area });
      el.classList.remove("tile--focused");
      this.focus(id);
    }
    const first = this.layout.clients[0];
    if (first !== undefined) this.focus(first);
  }

  #tileAt(e) {
    const el = e.target.closest?.(".tile");
    if (!el || !this.area.contains(el) || el.classList.contains("is-leaving")) return null;
    return Number(el.dataset.id);
  }

  // input:follow_mouse = 1: the pointer focuses the tile it moves over.
  #followMouse(e) {
    if (e.pointerType !== "mouse") return;
    const id = this.#tileAt(e);
    if (id !== null && id !== this.focused) this.focus(id);
  }

  #emit(event, detail) {
    for (const fn of this.listeners) fn(event, detail);
  }
}
