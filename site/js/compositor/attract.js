// The demo the hero plays until someone touches it: the app's binds, shown on the
// keycast, and a ⌘-drag with a pretend pointer. It stops for good on the first
// interaction, and pauses while the window is off screen.

import { durations } from "./motion.js";
import { makeClock } from "./clock.js";
import { Cursor } from "./cursor.js";

export function attract(wm, keycast, root) {
  const clock = makeClock(root);
  const { sleep, tween } = clock;
  const cursor = new Cursor(wm.area);

  const press = (chord, label, action) => {
    clock.check();
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

  clock.loop(script);

  return {
    get running() { return !clock.stopped; },
    stop() {
      if (clock.stopped) return;
      clock.stop();
      if (wm.drag) wm.endDrag(cursor.p, true);
      cursor.show(false);
      setTimeout(() => cursor.remove(), 400);
    },
  };
}

