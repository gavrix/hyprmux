// Turns the static hero window into a live compositor.

import { Compositor, SPECIAL } from "./view.js";
import { Keycast, bindFor, appChord, createHint } from "./keys.js";
import { attract } from "./attract.js";
import { reducedMotion } from "./motion.js";

/** What the other workspaces and the scratchpad hold when the page loads. */
function seed(wm) {
  wm.seed(2, "web", { page: "docs" });
  wm.seed(2, "terminal", {
    label: "dev server",
    script: {
      cmd: "npm run dev",
      out: ['<span class="gr">VITE</span> v6.3.1  ready in 412 ms', '  ➜  Local:   <span class="p">http://localhost:5173/</span>'],
    },
  });
  const tests = wm.seed(3, "agent", {
    name: "tests",
    task: "fix the flaky login test",
    state: "working",
    lines: ['<span class="g">●</span> Reading tests/login.spec.ts', '<span class="d">  12 of 18 passed…</span>'],
  });
  wm.seed(3, "agent", {
    name: "darkmode",
    task: "add a dark mode switch",
    state: "blocked",
    lines: ['Allow <span class="y">rm -rf build</span>?', '<span class="d">  1. Yes   2. No</span>'],
  });
  wm.seed(3, "agent", {
    name: "docs",
    task: "document the orders API",
    state: "done",
    lines: ['<span class="gr">✓</span> Documented the orders API.', '<span class="d">  4 files changed</span>'],
  });
  // Arriving on workspace 3 lands on the working agent, so "done" stays until you look.
  wm.workspaces.get(3).lastFocused = tests;
  wm.seed(SPECIAL, "terminal", {
    label: "scratch",
    dir: "~",
    script: { cmd: "cat todo.md", out: ["- [x] tile terminals, web pages, simulators", "- [x] name workspaces", "- [ ] ship it"] },
  });
}

/** Buttons for touch screens, where there are no keys to press. */
function touchBar(wm, keycast, interact) {
  const actions = [
    ["⌘↩", "New terminal", "Terminal", () => wm.open("terminal")],
    ["⌘B", "New web tile", "Web", () => wm.open("web")],
    ["⌘L", "Next window", "Next", () => wm.cycleNext()],
    ["⌘", "Workspace", "Workspace", () => wm.workspace((wm.active % 3) + 1)],
    ["⌘S", "Scratchpad", "Scratchpad", () => wm.toggleScratchpad()],
    ["⌘W", "Close window", "Close", () => wm.close()],
  ];
  const bar = document.createElement("div");
  bar.className = "hm-touch";
  bar.setAttribute("role", "toolbar");
  bar.setAttribute("aria-label", "Try the binds");
  for (const [chord, label, text, action] of actions) {
    const b = document.createElement("button");
    b.type = "button";
    b.textContent = text;
    b.addEventListener("click", () => {
      interact();
      action();
      const shown = label === "Workspace" ? `Workspace ${wm.active}` : label;
      keycast.press(label === "Workspace" ? `⌘${wm.active}` : chord, shown);
    });
    bar.append(b);
  }
  return bar;
}

export function start(root) {
  const wm = new Compositor(root);
  seed(wm);
  wm.render({ instant: true });
  const keycast = new Keycast(root.querySelector(".keycast"));

  // The window takes the keys while it has focus. Tab reaches it, Esc lets go.
  root.tabIndex = 0;
  root.setAttribute("role", "application");
  root.setAttribute("aria-roledescription", "tiling window demo");
  root.setAttribute("aria-label", "Hyprmux demo window. Use H, J, K, and L to move focus between tiles, and 1 to 3 for workspaces.");
  const hint = createHint("hm-hint");
  root.after(hint);
  root.setAttribute("aria-describedby", hint.id);

  const live = document.createElement("p");
  live.className = "sr-only";
  live.setAttribute("aria-live", "polite");
  hint.append(live);
  const say = (text) => { live.textContent = text; };

  // The demo plays until the first interaction.
  const demo = reducedMotion() ? null : attract(wm, keycast, root);
  const interact = () => demo?.stop();
  root.addEventListener("pointerenter", (e) => { if (e.pointerType === "mouse") interact(); });
  root.addEventListener("pointerdown", interact);
  hint.querySelector(".hm-keys")?.addEventListener("toggle", interact);

  const touch = touchBar(wm, keycast, interact);
  hint.querySelector(".hm-hint__mouse").after(touch);

  const engaged = (on) => {
    root.classList.toggle("hm--engaged", on);
    hint.classList.toggle("is-live", on);
  };
  root.addEventListener("focus", () => { interact(); engaged(true); });
  root.addEventListener("blur", () => engaged(false));
  root.addEventListener("pointerdown", () => {
    if (document.activeElement !== root) root.focus({ preventScroll: true });
  });

  root.addEventListener("keydown", (e) => {
    if (e.code === "Escape") {
      root.blur();
      return;
    }
    const bind = bindFor(e, wm);
    if (!bind) return;
    e.preventDefault();
    interact();
    const [label, action, chord] = bind;
    const done = action();
    const full = done === false && /^(New|Open)/.test(label);
    keycast.press(chord ?? appChord(e), full ? "No room for a tile" : label);
  });

  wm.onChange((event, d) => {
    if (event === "mousebind") {
      if (document.activeElement !== root) root.focus({ preventScroll: true });
      keycast.press(d.chord, d.label);
      return;
    }
    if (demo?.running) return; // the demo doesn't narrate itself
    if (event === "focus") say(`${d.label} focused.`);
    else if (event === "open") say(`Opened ${d.label}.`);
    else if (event === "close") say(`Closed ${d.label}.`);
    else if (event === "workspace") say(`Workspace ${d.n}.`);
  });

  return wm;
}
