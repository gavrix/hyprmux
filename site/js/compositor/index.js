// Turns the static hero window into a live compositor.

import { Compositor } from "./view.js";
import { Keycast, bindFor, appChord, createHint } from "./keys.js";

export function start(root) {
  const wm = new Compositor(root);
  const keycast = new Keycast(root.querySelector(".keycast"));

  // The window takes the keys while it has focus. Tab reaches it, Esc lets go.
  root.tabIndex = 0;
  root.setAttribute("role", "application");
  root.setAttribute("aria-roledescription", "tiling window demo");
  root.setAttribute("aria-label", "Hyprmux demo window. Use H, J, K, and L to move focus between tiles.");
  const hint = createHint("hm-hint");
  root.after(hint);
  root.setAttribute("aria-describedby", hint.id);

  const live = document.createElement("p");
  live.className = "sr-only";
  live.setAttribute("aria-live", "polite");
  hint.append(live);
  const say = (text) => { live.textContent = text; };

  const engaged = (on) => {
    root.classList.toggle("hm--engaged", on);
    hint.classList.toggle("is-live", on);
  };
  root.addEventListener("focus", () => engaged(true));
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
    const [label, action] = bind;
    const done = action();
    const full = done === false && /^(New|Open)/.test(label);
    keycast.press(appChord(e), full ? "No room for a tile" : label);
  });

  wm.onChange((event, d) => {
    if (event === "focus") say(`${d.label} focused.`);
    else if (event === "open") say(`Opened ${d.label}.`);
    else if (event === "close") say(`Closed ${d.label}. ${wm.count} tiles left.`);
  });

  return wm;
}
