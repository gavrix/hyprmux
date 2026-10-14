// A small hyprlang reader for the config playground: the syntax from
// docs/CONFIGURATION.md, and the options the playground's window shows.
// Like the app, a mistake is reported with its line, and the rest still applies.

/** Splits a line at its comment. `#` starts one; `##` is a literal `#`. */
function stripComment(line) {
  let out = "";
  for (let i = 0; i < line.length; i++) {
    if (line[i] !== "#") { out += line[i]; continue; }
    if (line[i + 1] === "#") { out += "#"; i++; continue; }
    return { code: out, comment: line.slice(i) };
  }
  return { code: out, comment: "" };
}

/** Reads sections, `key = value` lines, and the flat `a:b = v` form. */
export function parse(text) {
  const values = new Map(); // "general:gaps_in" → { value, line }
  const lists = { bezier: [], animation: [] };
  const errors = [];
  const stack = [];
  text.split("\n").forEach((raw, i) => {
    const line = i + 1;
    const code = stripComment(raw).code.trim();
    if (!code) return;
    if (code === "}") {
      if (!stack.length) errors.push({ line, message: "a } with no section to close" });
      else stack.pop();
      return;
    }
    const open = /^([A-Za-z_][\w.:-]*)\s*\{$/.exec(code);
    if (open) { stack.push(open[1]); return; }
    const kv = /^([^=]+?)\s*=\s*(.*)$/.exec(code);
    if (!kv) { errors.push({ line, message: `can't read "${code}"` }); return; }
    const key = [...stack, kv[1].trim()].join(":");
    const name = key.split(":").pop();
    if (name === "bezier" || name === "animation") lists[name].push({ value: kv[2], line });
    else values.set(key, { value: kv[2].trim(), line });
  });
  if (stack.length) errors.push({ line: text.split("\n").length, message: `section ${stack.at(-1)} has no closing }` });
  return { values, lists, errors };
}

// ---------- Values ----------

const hex = (s) => parseInt(s, 16);

/** One color as [r, g, b, a] with r/g/b 0–255 and a 0–1, or null. */
export function parseColor(t) {
  let m;
  if ((m = /^rgba\(([0-9a-f]{8})\)$/i.exec(t))) {
    const h = m[1];
    return [hex(h.slice(0, 2)), hex(h.slice(2, 4)), hex(h.slice(4, 6)), hex(h.slice(6, 8)) / 255];
  }
  if ((m = /^rgb\(([0-9a-f]{6})\)$/i.exec(t))) {
    const h = m[1];
    return [hex(h.slice(0, 2)), hex(h.slice(2, 4)), hex(h.slice(4, 6)), 1];
  }
  if ((m = /^rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*(?:,\s*([\d.]+)\s*)?\)$/i.exec(t))) {
    return [+m[1], +m[2], +m[3], m[4] === undefined ? 1 : +m[4]];
  }
  if ((m = /^0x([0-9a-f]{8})$/i.exec(t))) {
    const h = m[1];
    return [hex(h.slice(2, 4)), hex(h.slice(4, 6)), hex(h.slice(6, 8)), hex(h.slice(0, 2)) / 255];
  }
  if ((m = /^#([0-9a-f]{6})$/i.exec(t))) {
    const h = m[1];
    return [hex(h.slice(0, 2)), hex(h.slice(2, 4)), hex(h.slice(4, 6)), 1];
  }
  return null;
}

export const css = ([r, g, b, a]) => `rgba(${r}, ${g}, ${b}, ${+a.toFixed(3)})`;

/** A gradient: colors, then an optional angle. Hyprland's 0deg runs left to right, clockwise. */
function parseGradient(v) {
  const tokens = v.match(/rgba?\([^)]*\)|\S+/g) ?? [];
  const colors = [];
  let angle = 0;
  for (const t of tokens) {
    const deg = /^(-?[\d.]+)deg$/.exec(t);
    if (deg) { angle = +deg[1]; continue; }
    const c = parseColor(t);
    if (!c) return null;
    colors.push(c);
  }
  if (!colors.length) return null;
  return {
    colors,
    css: colors.length === 1 ? css(colors[0]) : `linear-gradient(${90 + angle}deg, ${colors.map(css).join(", ")})`,
  };
}

const BOOLS = { true: true, yes: true, on: true, 1: true, false: false, no: false, off: false, 0: false };

// The options the playground's window shows, with the app's built-in defaults.
const OPTIONS = {
  "general:gaps_in": { kind: "number", min: 0, max: 60, def: 5 },
  "general:gaps_out": { kind: "number", min: 0, max: 80, def: 20 },
  "general:border_size": { kind: "number", min: 0, max: 12, def: 2 },
  "general:col.active_border": { kind: "gradient", def: "rgba(33ccffee) rgba(00ff99ee) 45deg" },
  "general:col.inactive_border": { kind: "gradient", def: "rgba(595959aa)" },
  "decoration:rounding": { kind: "number", min: 0, max: 60, def: 10 },
  "decoration:rounding_power": { kind: "number", min: 1, max: 10, def: 2 },
  "decoration:active_opacity": { kind: "number", min: 0, max: 1, def: 1 },
  "decoration:inactive_opacity": { kind: "number", min: 0, max: 1, def: 1 },
  "decoration:dim_inactive": { kind: "bool", def: false },
  "decoration:dim_strength": { kind: "number", min: 0, max: 1, def: 0.5 },
  "decoration:shadow:enabled": { kind: "bool", def: true },
  "animations:enabled": { kind: "bool", def: true },
};

function readOption(spec, raw) {
  if (spec.kind === "number") {
    // Gaps take one to four numbers; the window uses the first.
    const n = Number(raw.split(/\s+/)[0]);
    if (!Number.isFinite(n)) return { error: `"${raw}" isn't a number` };
    if (n < spec.min || n > spec.max) return { error: `${n} is outside ${spec.min}–${spec.max}` };
    return { value: n };
  }
  if (spec.kind === "bool") {
    if (!(raw.toLowerCase() in BOOLS)) return { error: `"${raw}" isn't true or false` };
    return { value: BOOLS[raw.toLowerCase()] };
  }
  const g = parseGradient(raw);
  return g ? { value: g } : { error: `"${raw}" isn't a color` };
}

// Hyprland's built-in curves. "default" is Hyprland's own default bezier.
const BUILTIN_CURVES = { default: [0, 0.75, 0.15, 1], linear: [0, 0, 1, 1] };
// Each animation inherits from its parent when it isn't set.
const PARENT = { windows: "global", windowsMove: "windows", border: "global" };
const DEFAULT_ANIMATION = { speed: 10, curve: "default" }; // animation = global, 1, 10, default

/**
 * Reads a config into what the playground's window needs:
 * { gapsIn, gapsOut, borderSize, activeBorder, inactiveBorder, rounding, roundingPower,
 *   activeOpacity, inactiveOpacity, dimInactive, dimStrength, shadow,
 *   windows: { ms, curve }, border: { ms, curve } } plus errors.
 */
export function read(text) {
  const { values, lists, errors } = parse(text);
  const get = (key) => {
    const spec = OPTIONS[key];
    const entry = values.get(key);
    if (!entry) return readOption(spec, String(spec.def)).value;
    const r = readOption(spec, entry.value);
    if (r.error) {
      errors.push({ line: entry.line, message: `${key.split(":").pop()}: ${r.error}` });
      return readOption(spec, String(spec.def)).value;
    }
    return r.value;
  };

  const curves = { ...BUILTIN_CURVES };
  for (const { value, line } of lists.bezier) {
    const parts = value.split(",").map((s) => s.trim());
    const nums = parts.slice(1).map(Number);
    if (parts.length !== 5 || nums.some((n) => !Number.isFinite(n))) {
      errors.push({ line, message: "bezier needs a name and four numbers" });
      continue;
    }
    curves[parts[0]] = nums;
  }
  const anims = {};
  for (const { value, line } of lists.animation) {
    const [name, on, speed, curve] = value.split(",").map((s) => s.trim());
    if (!name || !(String(on).toLowerCase() in BOOLS) || !Number.isFinite(Number(speed))) {
      errors.push({ line, message: "animation needs a name, on/off, and a speed" });
      continue;
    }
    if (curve && !(curve in curves)) {
      errors.push({ line, message: `no bezier named ${curve}` });
      continue;
    }
    anims[name] = { on: BOOLS[String(on).toLowerCase()], speed: Number(speed), curve: curve || "default" };
  }
  const enabled = get("animations:enabled");
  const resolve = (name) => {
    for (let n = name; n; n = PARENT[n]) if (anims[n]) return anims[n];
    return { on: true, ...DEFAULT_ANIMATION };
  };
  const motion = (name) => {
    const a = resolve(name);
    const on = enabled && a.on;
    return { ms: on ? a.speed * 100 : 0, curve: `cubic-bezier(${curves[a.curve].join(", ")})` };
  };

  return {
    gapsIn: get("general:gaps_in"),
    gapsOut: get("general:gaps_out"),
    borderSize: get("general:border_size"),
    activeBorder: get("general:col.active_border"),
    inactiveBorder: get("general:col.inactive_border"),
    rounding: get("decoration:rounding"),
    roundingPower: get("decoration:rounding_power"),
    activeOpacity: get("decoration:active_opacity"),
    inactiveOpacity: get("decoration:inactive_opacity"),
    dimInactive: get("decoration:dim_inactive"),
    dimStrength: get("decoration:dim_strength"),
    shadow: get("decoration:shadow:enabled"),
    windows: motion("windowsMove"),
    border: motion("border"),
    errors: errors.sort((a, b) => a.line - b.line),
  };
}

// ---------- Highlighting ----------

const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

/** Syntax colors for the editor. Colors are drawn in themselves. */
export function highlight(text) {
  return text
    .split("\n")
    .map((raw) => {
      const { code, comment } = stripComment(raw);
      let html = "";
      const open = /^(\s*)([A-Za-z_][\w.:-]*)(\s*\{\s*)$/.exec(code);
      const kv = /^(\s*)([^=]+?)(\s*=\s*)(.*)$/.exec(code);
      if (open) html = `${esc(open[1])}<span class="k">${esc(open[2])}</span>${esc(open[3])}`;
      else if (kv) {
        // Colors are whole tokens; numbers are marked only outside them.
        const value = kv[4]
          .split(/(rgba?\([^)]*\)|0x[0-9a-f]{8})/i)
          .map((part, i) => {
            if (i % 2) {
              const rgba = parseColor(part);
              const shown = rgba && css([...rgba.slice(0, 3), Math.max(0.75, rgba[3])]);
              return rgba ? `<span class="cfg-color" style="color:${shown}">${esc(part)}</span>` : esc(part);
            }
            return esc(part).replace(/(^|[\s,])(-?\d+(?:\.\d+)?(?:deg|%)?)(?=$|[\s,])/g, '$1<span class="v">$2</span>');
          })
          .join("");
        html = `${esc(kv[1])}<span class="n">${esc(kv[2])}</span>${esc(kv[3])}${value}`;
      } else html = esc(code);
      return html + (comment ? `<span class="cm">${esc(comment)}</span>` : "");
    })
    .join("\n");
}
