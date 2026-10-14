// What tiles show. Content is fixed HTML, with a little typing in terminals.

import { reducedMotion } from "./motion.js";

const prompt = (dir = "project") => `<span class="p">${dir}</span> <span class="g">❯</span> `;
const cursor = '<span class="cursor"></span>';

// Commands a new terminal types, and what they print. `ctx` gives live numbers.
const terminalScripts = [
  () => ({ cmd: "ls", out: ["docs  README.md  Sources  site  todo.md"] }),
  () => ({
    cmd: "git log --oneline -3",
    out: [
      '<span class="y">52e3dbc</span> Animation: a slid-out tile stays hidden',
      '<span class="y">95be348</span> Repo: demo recording scripts stay local',
      '<span class="y">58d6820</span> Markdown: local markdown files open rendered',
    ],
  }),
  (ctx) => ({ cmd: "hyprmuxctl surfaces | jq length", out: [String(ctx.count())] }),
  () => ({ cmd: "swift test", out: ['<span class="gr">✔</span> Test run with 412 tests passed after 3.1 seconds.'] }),
];
let nextScript = 0;

function el(html) {
  const t = document.createElement("template");
  t.innerHTML = html.trim();
  return t.content.firstElementChild;
}

/** A terminal that types `script.cmd`, then prints `script.out`. */
function typedTerminal(script, dir = "project") {
  const frame = el(`<div class="frame"><div class="term"></div></div>`);
  const term = frame.firstElementChild;
  const line = (html) => term.insertAdjacentHTML("beforeend", `<p>${html}</p>`);

  const mount = ({ instant = false } = {}) => {
    if (instant || reducedMotion()) {
      line(prompt(dir) + script.cmd);
      script.out.forEach(line);
      line(prompt(dir) + cursor);
      return;
    }
    line(prompt(dir) + cursor);
    const current = term.lastElementChild;
    let i = 0;
    const type = () => {
      if (!current.isConnected) return;
      if (i < script.cmd.length) {
        i += 1;
        current.innerHTML = prompt(dir) + script.cmd.slice(0, i) + cursor;
        setTimeout(type, 28 + Math.random() * 40);
        return;
      }
      current.innerHTML = prompt(dir) + script.cmd;
      setTimeout(() => {
        if (!current.isConnected) return;
        script.out.forEach(line);
        line(prompt(dir) + cursor);
      }, 220);
    };
    setTimeout(type, 380);
  };
  return { frame, mount };
}

function terminal(ctx) {
  const script = ctx.script ?? terminalScripts[nextScript++ % terminalScripts.length](ctx);
  const { frame, mount } = typedTerminal(script, ctx.dir);
  return { kind: "terminal", label: ctx.label ?? "Terminal", frame, mount };
}

/** A coding agent in a terminal. Its tile shows what it's doing. */
function agent({ name, task, state, lines }) {
  const frame = el(`<div class="frame"><div class="term"></div></div>`);
  frame.firstElementChild.innerHTML = [prompt("~/app") + `pi "${task}"`, ...lines].map((l) => `<p>${l}</p>`).join("");
  return { kind: "terminal", label: name, frame, activity: state };
}

function web(ctx) {
  if (ctx.page === "docs") {
    const frame = el(`
      <div class="frame"><div class="web">
        <div class="web__bar"><span class="web__nav" aria-hidden="true">‹ › ↻</span><span class="web__url">github.com/gavrix/hyprmux</span></div>
        <div class="web__page web__page--docs">
          <div class="web__docs-h">Hyprmux</div>
          <div class="web__docs-p"></div><div class="web__docs-p web__docs-p--short"></div>
          <div class="web__docs-h2">Install</div>
          <div class="web__docs-code"></div>
          <div class="web__docs-p"></div><div class="web__docs-p web__docs-p--short"></div>
        </div>
      </div></div>`);
    return { kind: "web", label: "README", frame };
  }
  const frame = el(`
    <div class="frame"><div class="web">
      <div class="web__bar"><span class="web__nav" aria-hidden="true">‹ › ↻</span><span class="web__url">hyprmux.app</span></div>
      <div class="web__page web__page--site">
        <div class="web__site-h">The <span class="grad">Hyprland-style</span> multiplexer for macOS.</div>
        <div class="web__site-btn"></div>
        <div class="web__site-tiles"><i></i><i></i><i></i></div>
      </div>
    </div></div>`);
  return { kind: "web", label: "hyprmux.app", frame };
}

const apps = [
  { title: "Inbox", rows: 4 },
  { title: "Settings", rows: 5 },
  { title: "Photos", rows: 3 },
];
let nextApp = 0;

function mobile() {
  const app = apps[nextApp++ % apps.length];
  const rows = Array.from({ length: app.rows }, () => '<div class="phone__row"></div>').join("");
  const frame = el(`
    <div class="frame"><div class="device">
      <div class="phone"><div class="phone__screen">
        <div class="phone__status"><span>9:41</span><span class="phone__island"></span><span>●●●</span></div>
        <div class="phone__title">${app.title}</div>
        ${rows}
      </div></div>
      <div class="device__buttons" aria-hidden="true"><span>Home</span><span>Lock</span></div>
    </div></div>`);
  return { kind: "mobile", label: "iPhone 17", frame };
}

export const factories = { terminal, agent, web, mobile };
