// The config playground: a hyprmux.conf you can edit, and a small Hyprmux window
// that restyles as you type, the way the app reloads the file when you save.

import { Compositor } from "./compositor/view.js";
import { read, highlight } from "./hyprlang.js";
import { reducedMotion } from "./compositor/motion.js";

const config = (p) => `# Edit a value. The preview reloads as you type.
general {
    gaps_in = ${p.gapsIn}
    gaps_out = ${p.gapsOut}
    border_size = ${p.border}
    col.active_border = ${p.active}
    col.inactive_border = ${p.inactive}
}

decoration {
    rounding = ${p.rounding}
    rounding_power = ${p.power}
    inactive_opacity = ${p.inactiveOpacity}
    dim_inactive = ${p.dim}
    dim_strength = ${p.dimStrength}
}

animations {
    bezier = ${p.bezier}
    animation = windows, 1, ${p.windows}, ${p.bezier.split(",")[0]}
    animation = border, 1, ${p.borderSpeed}, ${p.bezier.split(",")[0]}
}`;

const DEFAULTS = {
  gapsIn: 5, gapsOut: 14, border: 2,
  active: "rgba(33ccffee) rgba(00ff99ee) 45deg", inactive: "rgba(595959aa)",
  rounding: 10, power: "2.0", inactiveOpacity: "1.0", dim: "false", dimStrength: "0.25",
  bezier: "easeOutQuint, 0.23, 1, 0.32, 1", windows: 4.79, borderSpeed: 5.39,
};

const PRESETS = [
  ["Default", {}],
  ["Squircle", { gapsIn: 8, gapsOut: 24, border: 3, rounding: 22, power: "4.0" }],
  ["No gaps", { gapsIn: 0, gapsOut: 0, border: 1, rounding: 0, active: "rgba(33ccffee)" }],
  ["Catppuccin", { active: "rgba(cba6f7ee) rgba(f5c2e7ee) 45deg", inactive: "rgba(45475aaa)", rounding: 12, gapsIn: 6, gapsOut: 16 }],
  ["Dim inactive", { inactiveOpacity: "0.8", dim: "true", dimStrength: "0.35" }],
  ["Bouncy", { bezier: "overshot, 0.05, 0.9, 0.1, 1.15", windows: 7, borderSpeed: 6 }],
];

const supportsCornerShape = CSS.supports?.("corner-shape", "superellipse(2)");

/** Puts a read config on the window: CSS variables, plus gaps through the compositor. */
function apply(wm, root, c) {
  const s = root.style;
  const scale = wm.scale;
  s.setProperty("--rounding", `${Math.round(c.rounding * scale * 10) / 10}px`);
  s.setProperty("--border-size", `${c.borderSize ? Math.max(1, Math.round(c.borderSize * Math.min(1, scale + 0.25))) : 0}px`);
  s.setProperty("--active-border", c.activeBorder.css);
  s.setProperty("--inactive", c.inactiveBorder.css);
  s.setProperty("--active-opacity", String(c.activeOpacity));
  s.setProperty("--inactive-opacity", String(c.inactiveOpacity));
  s.setProperty("--dim-brightness", c.dimInactive ? String(1 - c.dimStrength) : "1");
  s.setProperty("--t-windows", `${c.windows.ms}ms`);
  s.setProperty("--ease-windows", c.windows.curve);
  s.setProperty("--t-border", `${c.border.ms}ms`);
  s.setProperty("--ease-border", c.border.curve);
  // rounding_power p draws |x|^p + |y|^p = 1; CSS superellipse(k) draws exponent 2^k.
  if (supportsCornerShape) s.setProperty("--corner-shape", `superellipse(${Math.log2(c.roundingPower).toFixed(3)})`);
  root.classList.toggle("hm--no-shadow", !c.shadow);
  wm.setGaps(c.gapsIn, c.gapsOut);
}

export function startPlayground(section) {
  const root = section.querySelector("#config-window");
  const input = section.querySelector(".cfg__input");
  const hl = section.querySelector(".cfg__hl");
  const gutter = section.querySelector(".cfg__gutter");
  const errorsEl = root.querySelector(".hm__errors");
  const presetsEl = section.querySelector(".presets");
  const actions = section.querySelector(".playground__actions");
  if (!root || !input) return;

  const wm = new Compositor(root, { referenceWidth: 760, minGapsOut: 0 });
  section.classList.add("playground--live");
  presetsEl.hidden = false;
  actions.hidden = false;

  let lastMotion = "";
  const update = ({ fromPreset = false } = {}) => {
    const text = input.value;
    hl.innerHTML = highlight(text) + "\n";
    gutter.textContent = text.split("\n").map((_, i) => i + 1).join("\n");
    const c = read(text);
    apply(wm, root, c);
    // The app's red bar: each mistake with its line; everything else still applies.
    errorsEl.innerHTML = c.errors
      .slice(0, 3)
      .map((e) => `<p>hyprmux.conf:${e.line}: ${e.message.replace(/</g, "&lt;")}</p>`)
      .join("");
    errorsEl.classList.toggle("is-shown", c.errors.length > 0);
    // New motion settings: show them off.
    const motion = JSON.stringify([c.windows, c.border]);
    if (motion !== lastMotion && lastMotion && !reducedMotion()) setTimeout(() => wm.rotate(), fromPreset ? 120 : 400);
    lastMotion = motion;
    for (const b of presetsEl.querySelectorAll(".preset")) b.setAttribute("aria-pressed", String(b.dataset.text === text));
  };

  let timer = 0;
  input.addEventListener("input", () => {
    clearTimeout(timer);
    timer = setTimeout(update, 120);
  });
  input.addEventListener("scroll", () => {
    hl.scrollTop = input.scrollTop;
    hl.scrollLeft = input.scrollLeft;
    gutter.scrollTop = input.scrollTop;
  });

  presetsEl.innerHTML = '<span class="presets__label">Presets</span>';
  for (const [name, overrides] of PRESETS) {
    const b = document.createElement("button");
    b.type = "button";
    b.className = "preset";
    b.textContent = name;
    b.dataset.text = config({ ...DEFAULTS, ...overrides });
    b.addEventListener("click", () => {
      input.value = b.dataset.text;
      update({ fromPreset: true });
    });
    presetsEl.append(b);
  }

  section.querySelector(".playground__replay").addEventListener("click", () => wm.rotate());
  new ResizeObserver(() => apply(wm, root, read(input.value))).observe(root);
  update();
}
