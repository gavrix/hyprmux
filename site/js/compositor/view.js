// The hero compositor: dwindle tiles in the page's Hyprmux window.
// A small model of HyprmuxCore's WindowManager: workspaces, the scratchpad, groups,
// fullscreen, and the focus, move, swap, and resize dispatchers, plus the mouse binds.

import { Dwindle, neighbor, applyGaps } from "./layout.js";
import { factories } from "./tiles.js";
import { curves, durations, reducedMotion } from "./motion.js";
import { isMod } from "./keys.js";

// The app's default config, at the width the app's window usually has.
const REFERENCE_WIDTH = 1180;
const GAPS_IN = 5;
const GAPS_OUT = 14;
const GROUPBAR_HEIGHT = 20;
const DIM_SPECIAL = 0.3;
const MAX_TILES = 8;   // per workspace
// The demo keeps tiles big enough to read. The app only clamps split ratios.
const MIN_TILE = 64;
export const SPECIAL = "special";

const newLayout = () => new Dwindle({ preserveSplit: true, forceSplit: 2 }); // config/hyprmux.conf dwindle {}

class Workspace {
  constructor(key, el) {
    this.key = key;
    this.el = el;
    this.layout = newLayout();
    this.lastFocused = null;
    this.fullscreen = null; // { id, mode: "maximize" | "fullscreen" }
  }
}

export class Compositor {
  /**
   * @param {HTMLElement} root the .hm window
   * @param {object} [options] gapsIn, gapsOut, and referenceWidth (the width at which
   *   one config point is one pixel)
   */
  constructor(root, options = {}) {
    this.root = root;
    this.options = { gapsIn: GAPS_IN, gapsOut: GAPS_OUT, minGapsOut: 6, referenceWidth: REFERENCE_WIDTH, ...options };
    this.area = root.querySelector(".hm__area");
    this.bar = root.querySelector(".hm__workspaces");
    this.keycastEl = root.querySelector(".keycast");
    this.workspaces = new Map();
    this.tiles = new Map();   // id → { id, el, kind, label, ws, group, activity }
    this.groups = new Map();  // gid → { members: [id], active: id }
    this.active = 1;
    this.specialShown = false;
    this.focused = null;
    this.recency = new Map();
    this.tick = 0;
    this.nextId = 1;
    this.nextGroup = 1;
    this.drag = null;
    this.listeners = new Set();

    this.dim = document.createElement("div");
    this.dim.className = "hm__dim";
    this.area.prepend(this.dim);

    this.#adoptStaticTiles();
    root.classList.add("hm--live");
    this.render({ instant: true });

    new ResizeObserver(() => this.render({ instant: true })).observe(this.area);
    this.area.addEventListener("pointerdown", (e) => this.#pointerDown(e));
    this.area.addEventListener("pointermove", (e) => this.#pointerMove(e));
    this.area.addEventListener("pointerup", (e) => this.#pointerUp(e));
    this.area.addEventListener("pointercancel", (e) => this.#pointerUp(e, true));
    this.area.addEventListener("lostpointercapture", (e) => this.#pointerUp(e, true));
    // ⌘-right-drag must not open the page's context menu.
    this.area.addEventListener("contextmenu", (e) => {
      if (this.drag || isMod(e)) e.preventDefault();
    });
    this.bar.addEventListener("click", (e) => {
      const pill = e.target.closest?.("[data-ws]");
      if (pill) this.workspace(Number(pill.dataset.ws));
    });
  }

  /** Called with (event, detail) after changes. */
  onChange(fn) {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  // ---------- Queries ----------

  get focusedTile() { return this.tiles.get(this.focused) ?? null; }
  get count() { return this.#visibleWs().layout.clients.length; }

  /** The tile a slot shows: a group's active member, or the tile itself. */
  slotOf(id) {
    const t = this.tiles.get(id);
    return t?.group ? this.groups.get(t.group).active : id;
  }

  groupOf(id) {
    const t = this.tiles.get(id);
    return t?.group ? this.groups.get(t.group) : null;
  }

  #ws(key) {
    let ws = this.workspaces.get(key);
    if (!ws) {
      const el = document.createElement("div");
      el.className = "hm__ws";
      el.dataset.ws = String(key);
      if (key === SPECIAL) this.dim.after(el);
      else this.dim.before(el);
      ws = new Workspace(key, el);
      this.workspaces.set(key, ws);
    }
    return ws;
  }

  #visibleWs() { return this.#ws(this.specialShown ? SPECIAL : this.active); }
  #focusedWs() { return this.focusedTile ? this.#ws(this.focusedTile.ws) : this.#visibleWs(); }

  #tilesIn(key) { return [...this.tiles.values()].filter((t) => t.ws === key); }

  #mostRecent(key) {
    let best = null;
    for (const t of this.#tilesIn(key)) {
      const r = this.recency.get(t.id) ?? -1;
      if (!best || r > best.r) best = { id: t.id, r };
    }
    return best?.id ?? null;
  }

  // ---------- Geometry ----------

  #metrics() {
    const w = this.area.clientWidth;
    const h = this.area.clientHeight;
    const o = this.options;
    const s = Math.max(0.45, w / o.referenceWidth);
    return {
      area: { x: 0, y: 0, w, h },
      scale: s,
      gapsIn: o.gapsIn * s,
      gapsOut: Math.max(Math.min(o.minGapsOut, o.gapsOut), o.gapsOut * s),
      groupbar: Math.max(14, GROUPBAR_HEIGHT * s),
    };
  }

  /** Each slot's frame on a workspace, gaps applied. Fullscreen and maximize cover the rest. */
  frames(key = this.#focusedWs().key) {
    const ws = this.#ws(key);
    const m = this.#metrics();
    const out = new Map();
    for (const [id, box] of ws.layout.layout(m.area)) out.set(id, applyGaps(box, m.area, m.gapsIn, m.gapsOut));
    const fs = ws.fullscreen;
    if (fs && out.has(fs.id)) {
      const g = fs.mode === "fullscreen" ? 0 : m.gapsOut;
      out.set(fs.id, { x: g, y: g, w: m.area.w - 2 * g, h: m.area.h - 2 * g });
    }
    return out;
  }

  #tooSmall(key = this.#focusedWs().key) {
    const min = MIN_TILE * this.#metrics().scale;
    for (const r of this.frames(key).values()) if (r.w < min || r.h < min) return true;
    return false;
  }

  // ---------- Rendering ----------

  render({ instant = false } = {}) {
    if (instant) this.root.classList.add("hm--instant");
    const m = this.#metrics();
    this.root.style.setProperty("--groupbar", `${Math.round(m.groupbar)}px`);
    for (const ws of this.workspaces.values()) {
      const frames = this.frames(ws.key);
      for (const t of this.#tilesIn(ws.key)) {
        const slot = this.slotOf(t.id);
        const shown = slot === t.id && frames.has(t.id);
        t.el.classList.toggle("is-tab-hidden", !shown);
        if (!shown) continue;
        const r = frames.get(t.id);
        const s = t.el.style;
        s.left = `${Math.round(r.x)}px`;
        s.top = `${Math.round(r.y)}px`;
        s.width = `${Math.round(r.w)}px`;
        s.height = `${Math.round(r.h)}px`;
        const fs = ws.fullscreen?.id === t.id ? ws.fullscreen.mode : null;
        t.el.classList.toggle("tile--maximized", fs === "maximize");
        t.el.classList.toggle("tile--fullscreen", fs === "fullscreen");
        this.#renderGroupBar(t);
      }
    }
    this.root.classList.toggle("hm--empty", this.#visibleWs().layout.isEmpty);
    this.#renderBar();
    if (instant) {
      void this.area.offsetWidth; // apply without transitions
      this.root.classList.remove("hm--instant");
    }
  }

  #renderGroupBar(t) {
    const g = t.group ? this.groups.get(t.group) : null;
    t.el.classList.toggle("tile--grouped", !!g);
    let bar = t.el.querySelector(":scope > .groupbar");
    if (!g) {
      bar?.remove();
      return;
    }
    if (!bar) {
      bar = document.createElement("div");
      bar.className = "groupbar";
      t.el.append(bar);
    }
    bar.innerHTML = g.members
      .map((id) => {
        const m = this.tiles.get(id);
        return `<span class="groupbar__tab${id === g.active ? " is-active" : ""}" data-tab="${id}">${m.label}</span>`;
      })
      .join("");
  }

  /** The bar's workspace pills: workspaces with tiles, and the one shown, with activity bubbles. */
  #renderBar() {
    const keys = [...this.workspaces.keys()]
      .filter((k) => k !== SPECIAL && (k === this.active || this.#tilesIn(k).length))
      .sort((a, b) => a - b);
    const html = keys
      .map((k) => {
        const counts = { blocked: 0, done: 0, working: 0 };
        for (const t of this.#tilesIn(k)) if (t.activity in counts) counts[t.activity] += 1;
        const bubbles = Object.entries(counts)
          .filter(([, n]) => n)
          .map(([state, n]) => `<b class="bub bub--${state}">${n}</b>`)
          .join("");
        const cls = k === this.active && !this.specialShown ? "ws ws--active" : "ws";
        return `<span class="${cls}" data-ws="${k}">${k}${bubbles}</span>`;
      })
      .join("");
    const special = this.specialShown ? '<span class="ws ws--special">scratchpad</span>' : "";
    if (this.bar.innerHTML !== html + special) this.bar.innerHTML = html + special;
  }

  // ---------- Focus ----------

  focus(id) {
    const t = this.tiles.get(id);
    if (!t) return;
    // Focusing a hidden tab shows it; focusing another workspace's tile goes there.
    const g = this.groupOf(id);
    if (g && g.active !== id) this.#activate(id);
    if (t.ws === SPECIAL) {
      if (!this.specialShown) this.#showSpecial(true);
    } else {
      if (t.ws !== this.active) this.#switchTo(t.ws);
      if (this.specialShown) this.#showSpecial(false);
    }
    this.recency.set(id, ++this.tick);
    this.#ws(t.ws).lastFocused = id;
    // "Done" lasts until you look at the tile.
    if (t.activity === "done") this.#setActivity(id, null);
    if (this.focused !== id) {
      this.focusedTile?.el.classList.remove("tile--focused");
      this.focused = id;
      t.el.classList.add("tile--focused");
      this.#emit("focus", { id, label: t.label });
    }
    this.render();
  }

  #focusAfterSwitch(key) {
    this.focusedTile?.el.classList.remove("tile--focused");
    this.focused = null;
    const ws = this.#ws(key);
    const next = (ws.lastFocused !== null && this.tiles.has(ws.lastFocused) ? ws.lastFocused : null) ?? this.#mostRecent(key);
    if (next !== null) this.focus(next);
    else this.render();
  }

  moveFocus(dir) {
    const ws = this.#focusedWs();
    if (ws.fullscreen) return false;
    const all = this.frames(ws.key);
    const from = all.get(this.slotOf(this.focused));
    if (!from) return false;
    const candidates = [...all].filter(([id]) => id !== this.slotOf(this.focused));
    const next = neighbor(from, dir, candidates, this.recency);
    if (next === null) return false;
    this.focus(next);
    return true;
  }

  /** New gaps (the playground's config), applied with the windows animation. */
  setGaps(gapsIn, gapsOut) {
    this.options.gapsIn = gapsIn;
    this.options.gapsOut = gapsOut;
    this.render();
  }

  /** Moves every tile one slot along the layout, and focus with it: shows off the motion. */
  rotate() {
    const ws = this.#visibleWs();
    const ids = ws.layout.clients;
    if (ids.length < 2) return false;
    for (let i = 1; i < ids.length; i++) ws.layout.swap(ids[0], ids[i]);
    this.render();
    this.cycleNext();
    return true;
  }

  /** The scale from config points to pixels right now. */
  get scale() { return this.#metrics().scale; }

  /** cyclenext: the next tile on the workspace, in layout order. */
  cycleNext() {
    const ids = this.#visibleWs().layout.clients;
    if (ids.length < 2) return false;
    const i = ids.indexOf(this.slotOf(this.focused));
    this.focus(ids[(i + 1) % ids.length]);
    return true;
  }

  // ---------- Workspaces ----------

  /** workspace N: slides to it and focuses what was focused there. */
  workspace(n) {
    if (n === this.active) {
      if (!this.specialShown) return false;
      this.#showSpecial(false);
      this.#focusAfterSwitch(this.active);
      return true;
    }
    if (this.specialShown) this.#showSpecial(false);
    this.#switchTo(n);
    this.#focusAfterSwitch(n);
    this.#emit("workspace", { n });
    return true;
  }

  #switchTo(n) {
    const from = this.#ws(this.active);
    const to = this.#ws(n);
    const dir = n > this.active ? 1 : -1;
    this.active = n;
    this.#slide(from.el, to.el, dir);
  }

  /** animation = workspaces, 1, 3.5, easeOutQuint, slide */
  #slide(fromEl, toEl, dir) {
    toEl.classList.add("is-shown");
    if (reducedMotion()) {
      fromEl.classList.remove("is-shown");
      return;
    }
    const t = `transform ${durations.workspaces}ms ${curves.easeOutQuint}`;
    for (const el of [fromEl, toEl]) el.style.transition = "none";
    toEl.style.transform = `translateX(${dir * 100}%)`;
    fromEl.style.transform = "translateX(0)";
    void toEl.offsetWidth;
    for (const el of [fromEl, toEl]) el.style.transition = t;
    toEl.style.transform = "translateX(0)";
    fromEl.style.transform = `translateX(${-dir * 100}%)`;
    clearTimeout(fromEl._hide);
    clearTimeout(toEl._hide);
    fromEl._hide = setTimeout(() => {
      if (fromEl.dataset.ws !== String(this.active)) fromEl.classList.remove("is-shown");
      fromEl.style.transform = "";
      fromEl.style.transition = "";
    }, durations.workspaces + 40);
  }

  /** togglespecialworkspace: the scratchpad slides down over the workspace, which dims. */
  toggleScratchpad() {
    if (this.specialShown) {
      this.#showSpecial(false);
      this.#focusAfterSwitch(this.active);
    } else {
      this.#showSpecial(true);
      this.#focusAfterSwitch(SPECIAL);
    }
    return true;
  }

  /** animation = specialWorkspace, 1, 3, easeOutQuint, slidevert; decoration:dim_special */
  #showSpecial(on) {
    if (this.specialShown === on) return;
    this.specialShown = on;
    const el = this.#ws(SPECIAL).el;
    this.root.classList.toggle("hm--special", on);
    this.dim.style.opacity = on ? String(DIM_SPECIAL) : "0";
    clearTimeout(el._hide);
    if (reducedMotion()) {
      el.classList.toggle("is-shown", on);
      return;
    }
    const t = `transform ${durations.specialWorkspace}ms ${curves.easeOutQuint}`;
    el.classList.add("is-shown");
    el.style.transition = "none";
    el.style.transform = on ? "translateY(-100%)" : "translateY(0)";
    void el.offsetWidth;
    el.style.transition = t;
    el.style.transform = on ? "translateY(0)" : "translateY(-100%)";
    if (!on) el._hide = setTimeout(() => el.classList.remove("is-shown"), durations.specialWorkspace + 40);
  }

  /** movetoworkspace N (or the scratchpad). A group moves as a whole, and focus follows. */
  moveToWorkspace(key) {
    const t = this.focusedTile;
    if (!t) return false;
    const id = this.slotOf(t.id);
    const from = this.#ws(t.ws);
    if (key === t.ws) return false;
    const to = this.#ws(key);
    if (to.layout.clients.length >= MAX_TILES) return false;
    from.layout.remove(id);
    if (from.fullscreen?.id === id) from.fullscreen = null;
    if (from.lastFocused === id) from.lastFocused = null;
    to.fullscreen = null;
    const { area } = this.#metrics();
    to.layout.insert(id, { target: to.lastFocused, area });
    const members = this.groupOf(id)?.members ?? [id];
    for (const m of members) {
      const mt = this.tiles.get(m);
      mt.ws = key;
      to.el.append(mt.el);
    }
    to.lastFocused = id;
    this.focus(id);
    return true;
  }

  // ---------- Layout changes ----------

  /** movewindow: takes the window out and splits the neighbor in that direction. */
  moveWindow(dir) {
    const ws = this.#focusedWs();
    const f = this.slotOf(this.focused);
    const { area } = this.#metrics();
    const boxes = ws.layout.layout(area);
    const box = boxes.get(f);
    if (!box || boxes.size < 2) return false;
    const focal = {
      l: { x: box.x - 1, y: box.y + box.h / 2 },
      r: { x: box.x + box.w + 1, y: box.y + box.h / 2 },
      u: { x: box.x + box.w / 2, y: box.y - 1 },
      d: { x: box.x + box.w / 2, y: box.y + box.h + 1 },
    }[dir];
    if (focal.x < 0 || focal.y < 0 || focal.x >= area.w || focal.y >= area.h) return false;
    const before = ws.layout.clone();
    ws.layout.remove(f);
    ws.layout.insert(f, { focal, area, focalDecidesSide: true });
    if (this.#tooSmall(ws.key)) {
      ws.layout = before;
      return false;
    }
    this.render();
    return true;
  }

  swapWindow(dir) {
    const ws = this.#focusedWs();
    const f = this.slotOf(this.focused);
    const all = this.frames(ws.key);
    const from = all.get(f);
    if (!from || ws.fullscreen) return false;
    const other = neighbor(from, dir, [...all].filter(([id]) => id !== f), this.recency);
    if (other === null) return false;
    ws.layout.swap(f, other);
    this.render();
    return true;
  }

  /** resizeactive, in the app's points at the reference width. */
  resizeActive(dx, dy) {
    const ws = this.#focusedWs();
    if (this.focused === null || ws.layout.clients.length < 2 || ws.fullscreen) return false;
    const m = this.#metrics();
    ws.layout.layout(m.area);
    const snap = ws.layout.snapshot();
    ws.layout.resize(this.slotOf(this.focused), dx * m.scale, dy * m.scale);
    if (this.#tooSmall(ws.key)) {
      ws.layout.restore(snap);
      return false;
    }
    this.render();
    return true;
  }

  toggleSplit() {
    const ws = this.#focusedWs();
    if (this.focused === null || ws.layout.clients.length < 2) return false;
    const f = this.slotOf(this.focused);
    const snap = ws.layout.snapshot();
    ws.layout.toggleSplit(f);
    if (this.#tooSmall(ws.key)) ws.layout.splitRatio(f, 1, true);
    if (this.#tooSmall(ws.key)) {
      ws.layout.restore(snap);
      return false;
    }
    this.render();
    return true;
  }

  /** fullscreen, 1 (maximize) and fullscreen, 0. The same mode again goes back. */
  fullscreen(mode) {
    const ws = this.#focusedWs();
    if (this.focused === null) return false;
    const id = this.slotOf(this.focused);
    ws.fullscreen = ws.fullscreen?.id === id && ws.fullscreen.mode === mode ? null : { id, mode };
    this.render();
    return true;
  }

  // ---------- Groups ----------

  /** togglegroup: makes the window a one-tab group, or splits its group back into windows. */
  toggleGroup() {
    const t = this.focusedTile;
    if (!t) return false;
    const ws = this.#ws(t.ws);
    if (t.group) {
      const g = this.groups.get(t.group);
      const f = g.active;
      const { area } = this.#metrics();
      this.groups.delete(t.group);
      for (const m of g.members) this.tiles.get(m).group = null;
      for (const m of g.members) if (m !== f) ws.layout.insert(m, { target: f, area });
      this.render();
      this.focus(this.focused);
      return true;
    }
    const gid = this.nextGroup++;
    this.groups.set(gid, { members: [t.id], active: t.id });
    t.group = gid;
    this.render();
    return true;
  }

  /** changegroupactive f / b */
  changeGroupActive(step) {
    const g = this.groupOf(this.focused);
    if (!g || g.members.length < 2) return false;
    const i = g.members.indexOf(g.active);
    const j = (i + step + g.members.length) % g.members.length;
    this.focus(g.members[j]);
    return true;
  }

  #activate(id) {
    const t = this.tiles.get(id);
    const g = this.groupOf(id);
    if (!g || g.active === id) return;
    const ws = this.#ws(t.ws);
    ws.layout.replaceClient(g.active, id);
    if (ws.fullscreen?.id === g.active) ws.fullscreen.id = id;
    if (ws.lastFocused === g.active) ws.lastFocused = id;
    g.active = id;
  }

  // ---------- Open and close ----------

  /**
   * Opens a tile of `kind` next to the focused one, or as a new tab when a group has
   * focus (group:auto_group). Returns false when there's no room.
   */
  open(kind, options = {}) {
    const ws = this.#visibleWs();
    const made = factories[kind]({ count: () => ws.layout.clients.length + 1, ...options });
    const id = this.nextId;
    const f = this.focusedTile?.ws === ws.key ? this.focused : null;
    const g = f !== null ? this.groupOf(f) : null;

    if (g) {
      const el = this.#makeTileEl(made);
      this.#add(el, made, ws.key);
      ws.el.append(el);
      g.members.splice(g.members.indexOf(g.active) + 1, 0, id);
      this.tiles.get(id).group = this.tiles.get(f).group;
      this.#placeAtSlot(el, g.active, ws);
      this.#activate(id);
      this.#enter(el);
      this.focus(id);
      made.mount?.();
      this.#emit("open", { id, kind, label: made.label });
      return true;
    }

    if (ws.layout.clients.length >= MAX_TILES) return false;
    const { area } = this.#metrics();
    const before = ws.layout.clone();
    ws.fullscreen = null;
    ws.layout.insert(id, { target: f, area });
    if (this.#tooSmall(ws.key)) {
      ws.layout = before;
      return false;
    }
    const el = this.#makeTileEl(made);
    this.#add(el, made, ws.key);
    ws.el.append(el);
    this.#placeAtSlot(el, id, ws);
    this.#enter(el);
    this.focus(id);
    made.mount?.();
    this.#emit("open", { id, kind, label: made.label });
    return true;
  }

  /** Builds a tile on a workspace without focusing it: the page's starting content. */
  seed(key, kind, options = {}) {
    const ws = this.#ws(key);
    const made = factories[kind]({ count: () => ws.layout.clients.length + 1, ...options });
    const el = this.#makeTileEl(made);
    const id = this.#add(el, made, key);
    ws.el.append(el);
    const { area } = this.#metrics();
    ws.layout.insert(id, { target: ws.lastFocused, area });
    ws.lastFocused = id;
    this.recency.set(id, ++this.tick);
    made.mount?.({ instant: true });
    this.render({ instant: true });
    return id;
  }

  close(id = this.focused) {
    const tile = this.tiles.get(id);
    if (!tile) return false;
    const ws = this.#ws(tile.ws);
    const g = this.groupOf(id);
    let nextTab = null;
    if (g) {
      const i = g.members.indexOf(id);
      g.members.splice(i, 1);
      if (!g.members.length) {
        this.groups.delete(tile.group);
        ws.layout.remove(id);
      } else if (g.active === id) {
        nextTab = g.members[Math.min(i, g.members.length - 1)];
        ws.layout.replaceClient(id, nextTab);
        if (ws.fullscreen?.id === id) ws.fullscreen.id = nextTab;
        g.active = nextTab;
      }
    } else {
      ws.layout.remove(id);
    }
    if (ws.fullscreen?.id === id) ws.fullscreen = null;
    this.tiles.delete(id);
    this.recency.delete(id);
    if (ws.lastFocused === id) ws.lastFocused = null;
    tile.el.classList.remove("tile--focused");
    tile.el.classList.add("is-leaving");
    setTimeout(() => tile.el.remove(), reducedMotion() ? 0 : durations.windowsOut + 40);

    if (this.focused === id) {
      this.focused = null;
      const next = nextTab ?? this.#mostRecent(tile.ws);
      if (next !== null) this.focus(next);
    }
    this.render();
    this.#emit("close", { id, label: tile.label });
    return true;
  }

  // ---------- Activity ----------

  #setActivity(id, state) {
    const t = this.tiles.get(id);
    if (!t) return;
    t.activity = state;
    for (const s of ["working", "blocked", "done"]) t.el.classList.toggle(`tile--${s}`, s === state);
    let pill = t.el.querySelector(":scope > .tile__pill");
    if (!state) {
      pill?.remove();
      return;
    }
    if (!pill) {
      pill = document.createElement("span");
      pill.className = "tile__pill";
      t.el.append(pill);
    }
    pill.textContent = { working: "working", blocked: "needs you", done: "done" }[state];
  }

  /** A terminal's agent reports its state (hyprmuxctl agent-state). */
  agentState(id, state) {
    this.#setActivity(id, state);
    this.render();
  }

  // ---------- Internals ----------

  #makeTileEl(made) {
    const el = document.createElement("div");
    el.className = "tile";
    el.append(made.frame);
    return el;
  }

  #add(el, { kind, label, activity = null }, ws) {
    const id = this.nextId++;
    el.dataset.id = String(id);
    el.setAttribute("aria-label", label);
    this.tiles.set(id, { id, el, kind, label, ws, group: null, activity: null });
    if (activity) this.#setActivity(id, activity);
    return id;
  }

  /** Puts a new tile at a slot's frame at once, so only the others slide. */
  #placeAtSlot(el, slot, ws) {
    const r = this.frames(ws.key).get(slot);
    if (!r) return;
    Object.assign(el.style, {
      left: `${Math.round(r.x)}px`, top: `${Math.round(r.y)}px`,
      width: `${Math.round(r.w)}px`, height: `${Math.round(r.h)}px`,
    });
  }

  /** animation = windowsIn, 1, 4.1, easeOutQuint, popin 87% */
  #enter(el) {
    el.classList.add("is-entering");
    void el.offsetWidth;
    requestAnimationFrame(() => el.classList.remove("is-entering"));
  }

  /** The tiles in the page's HTML become workspace 1, opened in order like the app would. */
  #adoptStaticTiles() {
    const narrow = this.root.clientWidth < 560;
    const ws = this.#ws(1);
    ws.el.classList.add("is-shown");
    const { area } = this.#metrics();
    for (const el of [...this.area.querySelectorAll(":scope > .tile")]) {
      // The narrow layout has no room for the editor.
      if (narrow && el.dataset.kind === "editor") {
        el.remove();
        continue;
      }
      const id = this.#add(el, { kind: el.dataset.kind, label: el.dataset.label }, 1);
      ws.el.append(el);
      ws.layout.insert(id, { target: ws.lastFocused, area });
      ws.lastFocused = id;
      el.classList.remove("tile--focused");
    }
    const first = ws.layout.clients[0];
    if (first !== undefined) this.focus(first);
  }

  #tileAt(e) {
    const el = e.target.closest?.(".tile");
    if (!el || !this.area.contains(el) || el.classList.contains("is-leaving")) return null;
    const id = Number(el.dataset.id);
    const t = this.tiles.get(id);
    // Under the open scratchpad, the workspace doesn't take the pointer.
    if (!t || (this.specialShown && t.ws !== SPECIAL)) return null;
    return id;
  }

  // ---------- Mouse ----------
  // bindm = $mod, mouse:272, movewindow and bindm = $mod, mouse:273, resizewindow,
  // as Compositor.handleMouseBind does them for tiled windows.

  #point(e) {
    const r = this.area.getBoundingClientRect();
    return { x: e.clientX - r.left, y: e.clientY - r.top };
  }

  #pointerDown(e) {
    const tab = e.target.closest?.(".groupbar__tab");
    if (tab) {
      this.focus(Number(tab.dataset.tab));
      return;
    }
    const id = this.#tileAt(e);
    if (id === null) {
      if (this.specialShown && !e.target.closest?.(`.hm__ws[data-ws="${SPECIAL}"] .tile`)) this.toggleScratchpad();
      return;
    }
    const button = e.button === 0 ? "click" : e.button === 2 ? "right-click" : null;
    if (!isMod(e) || !button || e.pointerType === "touch") {
      this.focus(id);
      return;
    }
    e.preventDefault();
    this.focus(id);
    this.beginDrag(id, this.#point(e), button === "right-click", e.pointerId);
    this.#emit("mousebind", { chord: `${e.metaKey ? "⌘" : "⌥"}${button}`, label: this.drag.resize ? "Resize" : "Move window" });
  }

  /** Starts a mouse-bind drag at `p` (also used by the page's own demo). */
  beginDrag(id, p, resize, pointerId = null) {
    const ws = this.#ws(this.tiles.get(id).ws);
    const slot = this.slotOf(id);
    const frame = this.frames(ws.key).get(slot);
    if (!frame) return;
    this.drag = {
      id: slot, ws: ws.key, resize, frame, start: p, last: p,
      // Resizes move the edges nearest the grab point, like Hyprland.
      hEdge: p.x < frame.x + frame.w / 2 ? "l" : "r",
      vEdge: p.y < frame.y + frame.h / 2 ? "u" : "d",
    };
    if (pointerId !== null) this.area.setPointerCapture(pointerId);
    this.tiles.get(slot).el.classList.add(resize ? "is-resizing" : "is-dragging");
    this.root.style.cursor = resize
      ? (this.drag.hEdge === "l") === (this.drag.vEdge === "u") ? "nwse-resize" : "nesw-resize"
      : "grabbing";
  }

  #pointerMove(e) {
    if (!this.drag) {
      this.#followMouse(e);
      return;
    }
    this.dragTo(this.#point(e));
  }

  dragTo(p) {
    const d = this.drag;
    const tile = d && this.tiles.get(d.id);
    if (!tile) return;
    if (!d.resize) {
      // Tiled drag: the window follows the pointer and lands on release.
      tile.el.style.transform = `translate(${p.x - d.start.x}px, ${p.y - d.start.y}px)`;
      return;
    }
    const ws = this.#ws(d.ws);
    const { area } = this.#metrics();
    ws.layout.layout(area);
    const snap = ws.layout.snapshot();
    ws.layout.moveEdge(d.id, d.hEdge, p.x - d.last.x);
    ws.layout.moveEdge(d.id, d.vEdge, p.y - d.last.y);
    if (this.#tooSmall(d.ws)) {
      ws.layout.restore(snap);
      return;
    }
    d.last = p;
    this.render({ instant: true });
  }

  #pointerUp(e, cancelled = false) {
    if (!this.drag) return;
    if (this.area.hasPointerCapture?.(e.pointerId)) this.area.releasePointerCapture(e.pointerId);
    this.endDrag(this.#point(e), cancelled);
  }

  endDrag(p, cancelled = false) {
    const d = this.drag;
    if (!d) return;
    this.drag = null;
    this.root.style.cursor = "";
    const tile = this.tiles.get(d.id);
    if (!tile) return;
    tile.el.classList.remove("is-dragging", "is-resizing");
    if (d.resize) return;

    // Bake the drag offset into the tile's position, so it lands from where it was let go.
    const s = tile.el.style;
    s.transition = "none";
    s.transform = "";
    s.left = `${Math.round(d.frame.x + p.x - d.start.x)}px`;
    s.top = `${Math.round(d.frame.y + p.y - d.start.y)}px`;
    void tile.el.offsetWidth;
    s.transition = "";

    // dropTiled: outside its old frame, it goes next to the tile under the pointer, on that side.
    const ws = this.#ws(d.ws);
    const outside = p.x < d.frame.x || p.y < d.frame.y || p.x >= d.frame.x + d.frame.w || p.y >= d.frame.y + d.frame.h;
    const { area } = this.#metrics();
    const inside = p.x >= 0 && p.y >= 0 && p.x < area.w && p.y < area.h;
    if (!cancelled && outside && inside && ws.layout.clients.length > 1) {
      const before = ws.layout.clone();
      ws.layout.remove(d.id);
      ws.layout.insert(d.id, { focal: p, area, focalDecidesSide: true });
      if (ws.fullscreen) ws.fullscreen = null;
      if (this.#tooSmall(d.ws)) ws.layout = before;
    }
    this.render();
  }

  // input:follow_mouse = 1: the pointer focuses the tile it moves over.
  #followMouse(e) {
    if (e.pointerType !== "mouse") return;
    this.root.style.cursor = isMod(e) ? "grab" : "";
    const id = this.#tileAt(e);
    if (id !== null && this.slotOf(id) !== this.slotOf(this.focused)) this.focus(this.slotOf(id));
  }

  #emit(event, detail) {
    for (const fn of this.listeners) fn(event, detail);
  }

  // ---------- The page's own demo ----------

  /** Where a tile's slot is, relative to the window's tile area. */
  frameOf(id) {
    const t = this.tiles.get(id);
    return t ? this.frames(t.ws).get(this.slotOf(id)) ?? null : null;
  }

  /** A copy of the visible layouts and focus, to come back to after a scripted demo. */
  checkpoint() {
    return {
      layouts: new Map([...this.workspaces].map(([k, ws]) => [k, ws.layout.clone()])),
      focused: this.focused,
    };
  }

  restore(cp) {
    for (const [k, layout] of cp.layouts) {
      const ws = this.workspaces.get(k);
      // Only when the same tiles are there: a layout from before the user played is stale.
      if (ws && layout.clients.slice().sort().join() === ws.layout.clients.slice().sort().join()) ws.layout = layout;
    }
    if (cp.focused !== null && this.tiles.has(cp.focused)) this.focus(cp.focused);
    this.render();
  }
}
