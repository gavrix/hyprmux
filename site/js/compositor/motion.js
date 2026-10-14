// Motion values from the default config/hyprmux.conf. Hyprland speed is in
// tenths of a second, so `speed 4.79` is 479 ms. CSS mirrors these in site.css.

export const curves = {
  easeOutQuint: "cubic-bezier(0.23, 1, 0.32, 1)",
  easeInOutCubic: "cubic-bezier(0.65, 0.05, 0.36, 1)",
  linear: "linear",
  almostLinear: "cubic-bezier(0.5, 0.5, 0.75, 1)",
  quick: "cubic-bezier(0.15, 0, 0.1, 1)",
};

export const durations = {
  windows: 479,    // move and resize
  windowsIn: 410,  // popin 87%
  windowsOut: 149, // popin 87%, linear
  fadeIn: 173,
  fadeOut: 146,
  border: 539,
  workspaces: 350,
  specialWorkspace: 300,
  fade: 303,
};

export const popin = 0.87;

const query = window.matchMedia("(prefers-reduced-motion: reduce)");
export const reducedMotion = () => query.matches;

/** Resolves after `ms`, or at once when motion is reduced. */
export const wait = (ms) => new Promise((r) => setTimeout(r, reducedMotion() ? 0 : ms));
