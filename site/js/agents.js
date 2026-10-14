// The agents section: a script in a terminal drives a small Hyprmux workspace with
// hyprmuxctl, and the workspace answers. Every printed line comes from the live
// board: `surfaces` lists its tiles, `read-screen` reads a tile's text, and `events`
// prints the agent states as they change.

import { Compositor } from "./compositor/view.js";
import { makeClock } from "./compositor/clock.js";
import { Cursor } from "./compositor/cursor.js";

const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const PROMPT = '<span class="g">❯</span> ';
const MAX_TILE_LINES = 7;

export function startAgents(section) {
  const root = section.querySelector("#agents-window");
  const code = section.querySelector(".codecard--term code");
  if (!root || !code) return;

  const wm = new Compositor(root, { referenceWidth: 760, minGapsOut: 0, titles: true });
  const clock = makeClock(section, { threshold: 0.3 });
  const { sleep, tween } = clock;
  const cursor = new Cursor(wm.area, { mod: null });
  code.parentElement.classList.add("code--live");

  const tile = (id) => wm.tiles.get(id);
  const termOf = (id) => tile(id)?.el.querySelector(".term");
  const initial = new Map([...wm.tiles.keys()].map((id) => [id, termOf(id)?.innerHTML ?? null]));
  const start = wm.checkpoint();
  const web = [...wm.tiles.values()].find((t) => t.kind === "web").id;

  /** Adds lines to a tile's terminal, keeping the last few, like a scrolling screen. */
  const appendTo = (id, ...lines) => {
    const term = termOf(id);
    if (!term) return;
    for (const l of lines) term.insertAdjacentHTML("beforeend", `<p>${l}</p>`);
    while (term.children.length > MAX_TILE_LINES) term.firstElementChild.remove();
  };

  // ---------- The script's terminal ----------

  const print = (html, cls = "") => {
    const line = document.createElement("div");
    line.className = `code__line ${cls}`;
    line.innerHTML = html || "&nbsp;";
    code.append(line);
    while (code.children.length > 16) code.firstElementChild.remove();
    return line;
  };

  /** Types a command at the prompt, a key at a time. */
  const type = async (cmd) => {
    const line = print(PROMPT + '<span class="cursor"></span>');
    for (let i = 1; i <= cmd.length; i++) {
      line.innerHTML = PROMPT + esc(cmd.slice(0, i)) + '<span class="cursor"></span>';
      await sleep(cmd[i - 1] === " " ? 45 : 22 + Math.random() * 26);
    }
    await sleep(260);
    line.innerHTML = PROMPT + esc(cmd);
  };

  // `hyprmuxctl events`: one line per shown agent state change, while it runs.
  let streaming = false;
  wm.onChange((event, d) => {
    if (event === "agent" && streaming) print(`agent&gt;&gt;${d.id},pi,${d.state ?? "idle"}`, "d");
  });

  const reset = () => {
    streaming = false;
    code.textContent = "";
    for (const id of [...wm.tiles.keys()]) if (!initial.has(id)) wm.close(id);
    for (const [id, html] of initial) {
      const term = termOf(id);
      if (term && html !== null) term.innerHTML = html;
    }
    for (const id of initial.keys()) if (tile(id).kind === "terminal") wm.agentState(id, "working");
    setDark(false);
    showBanner(false);
    wm.restore(start);
    wm.focus(web);
  };

  // ---------- The web tile ----------

  const page = () => tile(web).el.querySelector(".web__page--app");
  const setDark = (on) => page()?.classList.toggle("is-dark", on);
  const showBanner = (on) => {
    const frame = tile(web).el.querySelector(".web");
    let banner = frame.querySelector(".agent-banner");
    if (on && !banner) {
      banner = document.createElement("div");
      banner.className = "agent-banner";
      banner.innerHTML = "<span>Agent is controlling this tile</span><b>Stop</b>";
      frame.querySelector(".web__bar").after(banner);
    } else if (!on) banner?.remove();
  };

  /** agent-browser click: the pointer travels to the switch, then clicks it. */
  const clickSwitch = async () => {
    const sw = tile(web).el.querySelector(".web__switch");
    const a = wm.area.getBoundingClientRect();
    const r = sw.getBoundingClientRect();
    const to = { x: r.left - a.left + r.width * 0.6, y: r.top - a.top + r.height * 0.5 };
    const from = { x: to.x - 70, y: to.y + 60 };
    cursor.set(from);
    cursor.show(true);
    await tween(700, (t) => cursor.set({ x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t }));
    cursor.hold(true);
    await sleep(160);
    setDark(true);
    cursor.hold(false);
    await sleep(600);
    cursor.show(false);
  };

  // ---------- The script ----------

  async function script() {
    reset();
    await sleep(1200);

    await type(`hyprmuxctl surfaces | jq -r '.[] | "\\(.ref) \\(.agent.state)"'`);
    for (const t of [...wm.tiles.values()].filter((t) => t.ws === 1)) print(`surface:${t.id} ${t.activity ?? "null"}`);
    await sleep(1500);

    // A new agent in the background: the board gains a tile, focus stays put.
    await type(`hyprmuxctl new-surface --input 'pi "document the orders API"\\n' | jq -r .ref`);
    const docs = wm.seed(1, "agent", {
      name: "docs",
      task: "document the orders API",
      state: "working",
      lines: ['<span class="g">●</span> Reading src/api/orders.ts'],
    }, { animate: true });
    print(`surface:${docs}`);
    await sleep(1600);

    // Agent 2 asks before it runs a command: its tile turns red.
    appendTo(2, 'Allow <span class="y">rm -rf build</span>?', '<span class="d">  1. Yes   2. No</span>');
    wm.agentState(2, "blocked");
    await sleep(1700);

    await type("hyprmuxctl read-screen --surface 2 --lines 2");
    const screen = [...termOf(2).children].slice(-2).map((p) => esc(p.textContent));
    screen.forEach((l) => print(l));
    await sleep(1300);

    await type("hyprmuxctl send --surface 2 'y\\n'");
    appendTo(2, `${PROMPT}y`);
    await sleep(500);
    appendTo(2, '<span class="g">●</span> Rebuilding with the new theme');
    wm.agentState(2, "working");
    await sleep(1500);

    // Chromium tiles over CDP: a banner says an agent is driving, and its pointer shows.
    await type('agent-browser connect "$(hyprmuxctl cdp-url)" && agent-browser click @e2');
    showBanner(true);
    await sleep(400);
    await clickSwitch();
    print('<span class="gr">✓</span> clicked @e2');
    await sleep(900);
    showBanner(false);
    await sleep(900);

    // The event stream: agents finish while nobody looks, and their tiles turn green.
    await type("hyprmuxctl events");
    streaming = true;
    await sleep(1300);
    appendTo(docs, '<span class="gr">✓</span> Documented the orders API.');
    wm.agentState(docs, "done");
    await sleep(1500);
    appendTo(1, '<span class="gr">✓</span> 18 of 18 passed.');
    wm.agentState(1, "done");
    await sleep(1500);
    appendTo(2, '<span class="gr">✓</span> Dark mode is in Settings.');
    wm.agentState(2, "done");
    await sleep(4200);
  }

  clock.loop(script);
  return wm;
}
