// Time for scripted demos: sleeps count only while `root` is on screen and the tab
// is visible, and everything throws STOP once the demo is stopped.

export const STOP = Symbol("stop");

const ease = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2); // easeInOutCubic

export function makeClock(root, { threshold = 0.35 } = {}) {
  let stopped = false;
  let visible = false;
  const timers = new Set();
  const io = new IntersectionObserver(([e]) => { visible = e.isIntersecting && e.intersectionRatio >= threshold; }, {
    threshold: [0, threshold, 0.6],
  });
  io.observe(root);

  /** Waits `ms` of on-screen time. */
  const sleep = (ms) =>
    new Promise((resolve, reject) => {
      let left = ms;
      const step = () => {
        if (stopped) return reject(STOP);
        if (left <= 0) return resolve();
        const dt = Math.min(50, left);
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

  /** Runs `script` again and again until stopped. */
  const loop = async (script) => {
    try {
      for (;;) await script();
    } catch (e) {
      if (e !== STOP) throw e;
    }
  };

  return {
    sleep,
    tween,
    loop,
    get stopped() { return stopped; },
    get visible() { return visible; },
    check() { if (stopped) throw STOP; },
    stop() {
      stopped = true;
      for (const t of timers) clearTimeout(t);
      io.disconnect();
    },
  };
}
