// The demo the hero plays until someone touches it: the app's binds, shown on the
// keycast, and a ⌘-drag with a pretend pointer. It stops for good on the first
// interaction, and pauses while the window is off screen.

import { durations } from "./motion.js";

const STOP = Symbol("stop");

const CURSOR_SVG = `<svg viewBox="0 0 20 24" width="20" height="24" aria-hidden="true"><path d="M2 1.5v18.2l4.6-4.3 3 6.9 3.2-1.4-3-6.8h6.4z" fill="#fff" stroke="#0b0c11" stroke-width="1.4" stroke-linejoin="round"/></svg>`;

/** The pretend pointer, with a ⌘ badge while the "key" is down. */
class Cursor {
  constructor(area) {
    this.el = document.createElement("div");
    this.el.className = "hm-cursor";
    this.el.innerHTML = `${CURSOR_SVG}<span class="hm-cursor__mod">⌘</span>`;
    area.append(this.el);
    this.p = { x: 0, y: 0 };
  }
  set(p) {
    this.p = p;
    this.el.style.transform = `translate(${p.x}px, ${p.y}px)`;
  }
  show(on) { this.el.classList.toggle("is-shown", on); }
  hold(on) { this.el.classList.toggle("is-holding", on); }
  remove() { this.el.remove(); }
}

const ease = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2); // easeInOutCubic

export function attract(wm, keycast, root) {
  let stopped = false;
  let visible = false;
  const timers = new Set();
  const cursor = new Cursor(wm.area);

  const io = new IntersectionObserver(([e]) => { visible = e.isIntersecting && e.intersectionRatio > 0.35; }, {
    threshold: [0, 0.35, 0.6],
  });
  io.observe(root);

  /** Waits `ms` of on-screen time. Throws STOP once the demo is over. */
  const sleep = (ms) =>
    new Promise((resolve, reject) => {
      let left = ms;
      const step = () => {
        if (stopped) return reject(STOP);
        if (left <= 0) return resolve();
        const dt = 100;
        const t = setTimeout(() => {
          timers.delete(t);
          if (visible && !document.hidden) left -= dt;
          step();
        }, dt);
        timers.add(t);
      };
      step();
    });

  /** Runs `fn(t)` for t in 0…1 over `ms`, eased. */
  const tween = (ms, fn) =>
    new Promise((resolve, reject) => {
      const start = performance.now();
      const frame = (now) => {
        if (stopped) return reject(STOP);
        const t = Math.min(1, (now - start) / ms);
        fn(ease(t));
        if (t < 1) requestAnimationFrame(frame);
        else resolve();
      };
      requestAnimationFrame(frame);
    });

  const press = (chord, label, action) => {
    if (stopped) throw STOP;
    action();
    keycast.press(chord, label);
  };

  const byKind = (kind) => [...wm.tiles.values()].find((t) => t.ws === 1 && t.kind === kind)?.id ?? null;
  const lerp = (a, b, t) => ({ x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t });

  /** ⌘-drags tile `id` so the pointer ends at `to`. */
  async function drag(id, to) {
    const f = wm.frameOf(id);
    if (!f) return;
    const from = { x: f.x + f.w * 0.5, y: f.y + f.h * 0.45 };
    const enter = { x: from.x + 90, y: from.y + 70 };
    cursor.set(enter);
    cursor.show(true);
    await sleep(300);
    await tween(650, (t) => cursor.set(lerp(enter, from, t)));
    cursor.hold(true);
    await sleep(250);
    wm.focus(id);
    wm.beginDrag(id, from, false);
    keycast.press("⌘click", "Move window");
    await tween(1000, (t) => {
      const p = lerp(from, to, t);
      cursor.set(p);
      wm.dragTo(p);
    });
    await sleep(150);
    wm.endDrag(to);
    cursor.hold(false);
    await sleep(500);
    cursor.show(false);
  }

  async function script() {
    const start = wm.checkpoint();
    await sleep(1800);

    // A new terminal splits the focused one, moves right, and closes.
    press("⌘↩", "New terminal", () => wm.open("terminal"));
    await sleep(2000);
    press("⇧⌘L", "Move window right", () => wm.moveWindow("r"));
    await sleep(1600);
    press("⌘W", "Close window", () => wm.close());
    await sleep(1300);

    // ⌘-drag the phone over the top of the terminal.
    const phone = byKind("mobile");
    const term = byKind("terminal");
    const tf = term !== null ? wm.frameOf(term) : null;
    if (phone !== null && tf) {
      await drag(phone, { x: tf.x + tf.w * 0.5, y: tf.y + tf.h * 0.18 });
      await sleep(1500);
    }

    // The agents on workspace 3, then back.
    press("⌘3", "Workspace 3", () => wm.workspace(3));
    await sleep(2800);
    press("⌘1", "Workspace 1", () => wm.workspace(1));
    await sleep(1300);

    // The scratchpad slides down over the workspace, and away.
    press("⌘S", "Scratchpad", () => wm.toggleScratchpad());
    await sleep(2000);
    press("⌘S", "Scratchpad", () => wm.toggleScratchpad());
    await sleep(1200);

    // Settle back into the starting layout, and go again.
    wm.restore(start);
    await sleep(durations.windows + 2600);
  }

  const run = async () => {
    try {
      for (;;) await script();
    } catch (e) {
      if (e !== STOP) throw e;
    }
  };
  run();

  return {
    get running() { return !stopped; },
    stop() {
      if (stopped) return;
      stopped = true;
      for (const t of timers) clearTimeout(t);
      io.disconnect();
      if (wm.drag) wm.endDrag(cursor.p, true);
      cursor.show(false);
      setTimeout(() => cursor.remove(), 400);
    },
  };
}

