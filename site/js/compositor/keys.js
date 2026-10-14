// Keys for the hero window, the keycast, and the hint under it.
// The page can't use ⌘ (the browser owns ⌘W, ⌘N, ⌘1…), so each bind is the app's
// default without ⌘. Keys are physical positions (KeyboardEvent.code), like the app's.

const DIRS = {
  KeyH: "l", KeyJ: "d", KeyK: "u", KeyL: "r",
  ArrowLeft: "l", ArrowDown: "d", ArrowUp: "u", ArrowRight: "r",
};
const DIR_NAMES = { l: "left", r: "right", u: "up", d: "down" };
const KEY_NAMES = {
  Enter: "↩", ArrowLeft: "←", ArrowRight: "→", ArrowUp: "↑", ArrowDown: "↓", Space: "Space",
};
const keyName = (code) => KEY_NAMES[code] ?? code.replace(/^Key|^Digit/, "");

/** The app's chord for a key: ⌃⌥⇧ in Apple's order, then ⌘, then the key. */
export function appChord(e, code = e.code) {
  return (e.ctrlKey ? "⌃" : "") + (e.altKey ? "⌥" : "") + (e.shiftKey ? "⇧" : "") + "⌘" + keyName(code);
}

// resizeactive steps from config/hyprmux.conf (binde = $mod CTRL, H, resizeactive, -40 0).
const RESIZE = { l: [-40, 0], r: [40, 0], u: [0, -40], d: [0, 40] };

/** Maps a key event to [label, action] or null. Labels match the app's keycast. */
export function bindFor(e, wm) {
  if (e.metaKey) return null;
  const dir = DIRS[e.code];
  if (dir) {
    const name = DIR_NAMES[dir];
    if (e.ctrlKey && !e.altKey && !e.shiftKey) return ["Resize", () => wm.resizeActive(...RESIZE[dir])];
    if (e.altKey && !e.ctrlKey && !e.shiftKey) return [`Swap ${name}`, () => wm.swapWindow(dir)];
    if (e.shiftKey && !e.ctrlKey && !e.altKey) return [`Move window ${name}`, () => wm.moveWindow(dir)];
    if (!e.ctrlKey && !e.altKey && !e.shiftKey) return [`Focus ${name}`, () => wm.moveFocus(dir)];
    return null;
  }
  if (e.ctrlKey || e.altKey || e.shiftKey) return null;
  switch (e.code) {
    case "Enter": case "NumpadEnter": return ["New terminal", () => wm.open("terminal")];
    case "KeyB": return ["New web tile", () => wm.open("web")];
    case "KeyI": return ["Open Mobile", () => wm.open("mobile")];
    case "KeyW": return ["Close window", () => wm.close()];
    case "KeyE": return ["Flip split", () => wm.toggleSplit()];
    default: return null;
  }
}

/** The keycast HUD: the last chord, what it did, and a repeat count. */
export class Keycast {
  static linger = 1600;       // ms the panel stays after the last key (Keycast.swift)
  static repeatWindow = 1200; // a repeat within this counts up

  constructor(el) {
    this.el = el;
    this.el.innerHTML = '<span class="keycast__chord"></span><span class="keycast__label"></span><span class="keycast__count"></span>';
    this.chordEl = el.children[0];
    this.labelEl = el.children[1];
    this.countEl = el.children[2];
    this.el.classList.add("is-hidden");
    this.state = { chord: "", label: "", count: 0, last: -Infinity };
    this.timer = 0;
  }

  press(chord, label) {
    const now = performance.now();
    const s = this.state;
    if (chord === s.chord && label === s.label && now - s.last <= Keycast.repeatWindow) s.count += 1;
    else Object.assign(s, { chord, label, count: 1 });
    s.last = now;
    this.chordEl.textContent = s.chord;
    this.labelEl.textContent = s.label;
    this.countEl.textContent = s.count > 1 ? `×${s.count}` : "";
    this.el.classList.remove("is-hidden");
    clearTimeout(this.timer);
    this.timer = setTimeout(() => this.el.classList.add("is-hidden"), Keycast.linger);
  }
}

const LEGEND = [
  [["H", "J", "K", "L"], "Focus"],
  [["⇧", "HJKL"], "Move"],
  [["⌥", "HJKL"], "Swap"],
  [["⌃", "HJKL"], "Resize"],
  [["↩"], "New terminal"],
  [["B"], "New web tile"],
  [["I"], "New iPhone"],
  [["E"], "Flip split"],
  [["W"], "Close"],
];

export const isMac = /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent);
// $mod is ⌘. Off a Mac the OS often keeps the Windows key, so ⌥ works too.
export const isMod = (e) => e.metaKey || (!isMac && e.altKey);

const MOUSE_ICON = `<svg viewBox="0 0 16 22" width="13" height="18" aria-hidden="true"><rect x="1" y="1" width="14" height="20" rx="7" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M8 1v7" stroke="currentColor" stroke-width="1.5"/><rect x="6.6" y="4" width="2.8" height="4.5" rx="1.4" fill="currentColor"/></svg>`;

const KEYBOARD_ICON = `<svg class="hm-keys__icon" viewBox="0 0 20 14" width="18" height="13" aria-hidden="true"><rect x="0.75" y="0.75" width="18.5" height="12.5" rx="2.5" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M4 4.5h1.5M8 4.5h1.5M12 4.5h1.5M15.5 4.5h.5M4 7.5h1M7 7.5h1M10 7.5h1M13 7.5h1M16 7.5h.5M6 10h8" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>`;
const CHEVRON = `<svg class="hm-keys__chevron" viewBox="0 0 12 12" width="12" height="12" aria-hidden="true"><path d="M3 4.5l3 3 3-3" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>`;

/**
 * The line under the window. The mouse binds are the one obvious thing to try;
 * the keyboard binds wait behind a toggle so the page stays calm.
 */
export function createHint(id) {
  const mod = isMac ? "⌘" : "⌥";
  const hint = document.createElement("div");
  hint.className = "hm-hint";
  hint.id = id;
  const rows = LEGEND.map(
    ([keys, what]) => `<div><dt>${keys.map((k) => `<kbd>${k}</kbd>`).join("")}</dt><dd>${what}</dd></div>`,
  ).join("");
  hint.innerHTML = `
    <p class="hm-hint__mouse">
      <span class="hm-hint__icon">${MOUSE_ICON}</span>
      <span class="hm-hint__pointer">Hold <kbd>${mod}</kbd> and drag a tile to move it. Right-drag to resize.</span>
      <span class="hm-hint__touch">Tap a tile to focus it. Try it with a mouse to move tiles around.</span>
    </p>
    <details class="hm-keys">
      <summary>
        <span class="hm-keys__dot" aria-hidden="true"></span>${KEYBOARD_ICON}<span>Keyboard controls</span>${CHEVRON}
      </summary>
      <div class="hm-keys__panel">
        <p class="hm-keys__intro">Click the window, then use the app's binds without <kbd>⌘</kbd>. <kbd>Esc</kbd> lets go.</p>
        <dl class="hm-keys__grid">${rows}</dl>
      </div>
    </details>`;
  return hint;
}
