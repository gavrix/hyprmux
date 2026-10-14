// Page behavior: reveal on scroll, the nav's scrolled state, and copy buttons.

const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

function revealOnScroll() {
  const items = document.querySelectorAll(".reveal");
  if (reduceMotion || !("IntersectionObserver" in window)) {
    items.forEach((el) => el.classList.add("is-in"));
    return;
  }
  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        entry.target.classList.add("is-in");
        observer.unobserve(entry.target);
      }
    },
    { rootMargin: "0px 0px -8% 0px", threshold: 0.08 },
  );
  items.forEach((el) => observer.observe(el));
}

function navState() {
  const nav = document.querySelector(".nav");
  if (!nav) return;
  const update = () => nav.classList.toggle("is-scrolled", window.scrollY > 8);
  update();
  window.addEventListener("scroll", update, { passive: true });
}

function copyButtons() {
  for (const button of document.querySelectorAll("[data-copy]")) {
    button.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(button.dataset.copy);
        button.textContent = "Copied";
      } catch {
        // No clipboard access: select the code so the user can copy it.
        const code = button.parentElement.querySelector("code");
        if (code) getSelection().selectAllChildren(code);
        button.textContent = "Selected";
      }
      setTimeout(() => (button.textContent = "Copy"), 1600);
    });
  }
}

async function heroCompositor() {
  const root = document.getElementById("hero-window");
  if (!root || !("ResizeObserver" in window)) return;
  const { start } = await import("./compositor/index.js");
  start(root);
}

/** The config playground loads when its section comes near. */
function configPlayground() {
  const section = document.getElementById("config");
  if (!section || !("ResizeObserver" in window) || !("IntersectionObserver" in window)) return;
  const io = new IntersectionObserver(async ([e]) => {
    if (!e.isIntersecting) return;
    io.disconnect();
    const { startPlayground } = await import("./playground.js");
    startPlayground(section);
  }, { rootMargin: "600px 0px" });
  io.observe(section);
}

/** The agents section's script runs when the section comes near (not with reduced motion). */
function agentsDemo() {
  const section = document.getElementById("agents");
  if (!section || reduceMotion || !("ResizeObserver" in window) || !("IntersectionObserver" in window)) return;
  const io = new IntersectionObserver(async ([e]) => {
    if (!e.isIntersecting) return;
    io.disconnect();
    const { startAgents } = await import("./agents.js");
    startAgents(section);
  }, { rootMargin: "400px 0px" });
  io.observe(section);
}

revealOnScroll();
navState();
copyButtons();
heroCompositor();
configPlayground();
agentsDemo();
