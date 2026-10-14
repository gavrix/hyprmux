// What new tiles show. Content is fixed HTML, with a little typing in terminals.

import { reducedMotion } from "./motion.js";

const prompt = (dir = "project") => `<span class="p">${dir}</span> <span class="g">❯</span> `;

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
  () => ({ cmd: "npm run dev", out: ['<span class="gr">VITE</span> v6.3.1  ready in 412 ms', '  ➜  Local:   <span class="p">http://localhost:5173/</span>'] }),
];
let nextScript = 0;

function el(html) {
  const t = document.createElement("template");
  t.innerHTML = html.trim();
  return t.content.firstElementChild;
}

function terminal(ctx) {
  const frame = el(`<div class="frame"><div class="term"></div></div>`);
  const term = frame.firstElementChild;
  const script = terminalScripts[nextScript++ % terminalScripts.length](ctx);
  const line = (html) => term.insertAdjacentHTML("beforeend", `<p>${html}</p>`);
  const cursor = '<span class="cursor"></span>';

  const mount = () => {
    if (reducedMotion()) {
      line(prompt() + script.cmd);
      script.out.forEach(line);
      line(prompt() + cursor);
      return;
    }
    line(prompt() + cursor);
    const current = term.lastElementChild;
    let i = 0;
    const type = () => {
      if (!current.isConnected) return;
      if (i < script.cmd.length) {
        i += 1;
        current.innerHTML = prompt() + script.cmd.slice(0, i) + cursor;
        setTimeout(type, 28 + Math.random() * 40);
        return;
      }
      current.innerHTML = prompt() + script.cmd;
      setTimeout(() => {
        if (!current.isConnected) return;
        script.out.forEach(line);
        line(prompt() + cursor);
      }, 220);
    };
    setTimeout(type, 380);
  };
  return { kind: "terminal", label: "Terminal", frame, mount };
}

function web() {
  const frame = el(`
    <div class="frame"><div class="web">
      <div class="web__bar"><span class="web__nav" aria-hidden="true">‹ › ↻</span><span class="web__url">hyprmux.app</span></div>
      <div class="web__page web__page--site">
        <div class="web__site-h">Tiles that move like <span class="grad">Hyprland</span>.</div>
        <div class="web__site-btn"></div>
        <div class="web__site-tiles"><i></i><i></i><i></i></div>
      </div>
    </div></div>`);
  return { kind: "web", label: "Web page", frame };
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
  return { kind: "mobile", label: "iPhone simulator", frame };
}

export const factories = { terminal, web, mobile };
