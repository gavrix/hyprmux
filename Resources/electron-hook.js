// electron-hook.js — injected into an Electron app's main process by
// hyprmux-electron-bridge. Forces windows offscreen, streams frames, takes input,
// and proxies native UI to the bridge over a unix socket. See docs/CLIENT_PROTOCOL.md.
//
// Framing on the socket, both ways: [u32 LE json length][json][u32 LE payload length][payload].
// Frame messages carry the cropped bitmap as payload.
'use strict';

const net = require('net');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const { app, BrowserWindow, dialog, Menu } = require('electron');

const SOCK = process.env.EE_HOOK_SOCKET;
const SCALE = Number(process.env.EE_SCALE || 2);
const BRIDGE_BIN = process.env.EE_BRIDGE_BIN;
const ADAPTER = process.env.EE_APP || 'generic';

let socket = null;
let socketOpen = false;
const outbox = [];
let nextRequest = 1;
const requests = new Map();   // id -> resolve(json)
const wins = new Map();       // electron window id -> rec
let nextHookWin = 1;

function log(...a) {
  const msg = a.map(x => (typeof x === 'string' ? x : JSON.stringify(x))).join(' ');
  if (socketOpen) write({ t: 'log', msg });
  else fs.appendFileSync('/tmp/hyprmux-electron-hook.log', msg + '\n');
}

// --- socket ---------------------------------------------------------------

function connect(attempt) {
  socket = net.createConnection(SOCK);
  socket.on('drain', onDrain);
  socket.on('connect', () => {
    socketOpen = true;
    for (const b of outbox) socket.write(b);
    outbox.length = 0;
    log('hook connected to bridge; adapter', ADAPTER);
  });
  let pending = Buffer.alloc(0);
  socket.on('data', (chunk) => {
    pending = Buffer.concat([pending, chunk]);
    for (;;) {
      if (pending.length < 8) return;
      const jlen = pending.readUInt32LE(0);
      const blen = pending.readUInt32LE(4);
      if (pending.length < 8 + jlen + blen) return;
      const json = JSON.parse(pending.subarray(8, 8 + jlen).toString('utf8'));
      const payload = blen ? pending.subarray(8 + jlen, 8 + jlen + blen) : null;
      pending = pending.subarray(8 + jlen + blen);
      onMessage(json, payload);
    }
  });
  const retry = () => {
    socketOpen = false;
    if (attempt > 600) { log('giving up on bridge socket'); return; }
    setTimeout(() => connect(attempt + 1), 200);
  };
  socket.on('error', retry);
  socket.on('close', retry);
}

// Backpressure. Frames are megabytes; when the bridge falls behind, Node would queue
// every one of them and latency would grow without bound. While the socket is backed
// up, windows only remember that they're stale, and send their latest image as one
// full frame when it drains.
let backedUp = false;
// Pixels go through a per-window file that the bridge maps, not through the socket.
// A socket moves 8 KB per event-loop turn, so a 13 MB frame from a busy main process
// took hundreds of milliseconds. writeSync into the page cache takes about 2 ms, and the
// bridge's shared mapping sees the same pages. The file only grows, so the bridge's
// mapping never points past its end.
const pixFiles = new Set();
function pixFile(rec, need) {
  if (rec.pixFd == null) {
    rec.pixPath = path.join(os.tmpdir(), `hyprmux-electron-${process.pid}-${rec.id}.pix`);
    rec.pixFd = fs.openSync(rec.pixPath, 'w+', 0o600);
    rec.pixSize = 0;
    pixFiles.add(rec.pixPath);
  }
  if (need > rec.pixSize) { fs.ftruncateSync(rec.pixFd, need); rec.pixSize = need; }
  return rec.pixFd;
}
function closePixFile(rec) {
  if (rec.pixFd == null) return;
  try { fs.closeSync(rec.pixFd); fs.unlinkSync(rec.pixPath); } catch {}
  pixFiles.delete(rec.pixPath);
  rec.pixFd = null;
}
process.on('exit', () => { for (const p of pixFiles) { try { fs.unlinkSync(p); } catch {} } });

function sendFrame(rec, image, r) {
  const t0 = Date.now();
  const full = image.getSize();
  // A new size invalidates everything in the pixel file, so write the whole image.
  if (rec.fw !== full.width || rec.fh !== full.height) {
    rec.fw = full.width; rec.fh = full.height;
    r = { x: 0, y: 0, width: full.width, height: full.height };
  }
  const whole = r.x === 0 && r.y === 0 && r.width === full.width && r.height === full.height;
  const bitmap = (whole ? image : image.crop(r)).toBitmap();
  if (bitmap.length < r.width * r.height * 4) return;
  const fd = pixFile(rec, full.width * full.height * 4);
  if (whole) fs.writeSync(fd, bitmap, 0, r.width * r.height * 4, 0);
  else {
    const row = r.width * 4;
    for (let y = 0; y < r.height; y++) fs.writeSync(fd, bitmap, y * row, row, ((r.y + y) * full.width + r.x) * 4);
  }
  write({ t: 'frame', win: rec.id, x: r.x, y: r.y, w: r.width, h: r.height, fw: full.width, fh: full.height,
          file: rec.pixPath, ts: Date.now(), cost: Date.now() - t0 });
}
function onDrain() {
  backedUp = false;
  for (const rec of wins.values()) {
    if (!rec.stale || !rec.latest) continue;
    rec.stale = false;
    const full = rec.latest.getSize();
    sendFrame(rec, rec.latest, { x: 0, y: 0, width: full.width, height: full.height });
    if (backedUp) return;
  }
}

function write(obj, payload) {
  const j = Buffer.from(JSON.stringify(obj), 'utf8');
  const h = Buffer.alloc(8);
  h.writeUInt32LE(j.length, 0);
  h.writeUInt32LE(payload ? payload.length : 0, 4);
  const buf = payload ? Buffer.concat([h, j, payload]) : Buffer.concat([h, j]);
  if (socketOpen) { if (!socket.write(buf)) backedUp = true; }
  else if (outbox.length < 4000) outbox.push(buf);
}

function request(obj) {
  return new Promise((resolve) => {
    const id = nextRequest++;
    requests.set(id, (r) => resolve(r));
    write({ ...obj, req: id });
  });
}

// --- focus ------------------------------------------------------------------
// The native windows stay hidden, so Electron thinks no window has focus. Apps pick
// the target of dialogs and file opens by focus (VS Code: getFocusedWindow and its
// last-active window), so focus follows the tile that has keyboard focus instead.
let focusedRec = null;
function setFocused(rec) {
  const prev = focusedRec;
  if (prev === rec) return;
  focusedRec = rec;
  if (prev && !prev.win.isDestroyed()) {
    prev.win.blurWebView?.();
    prev.win.emit('blur');
    app.emit('browser-window-blur', {}, prev.win);
  }
  if (rec && !rec.win.isDestroyed()) {
    rec.win.webContents.focus();
    rec.win.focusOnWebView?.();
    rec.win.emit('focus');
    app.emit('browser-window-focus', {}, rec.win);
  }
}
try {
  const origFocused = BrowserWindow.getFocusedWindow.bind(BrowserWindow);
  BrowserWindow.getFocusedWindow = () =>
    (focusedRec && !focusedRec.win.isDestroyed() ? focusedRec.win : null) ?? origFocused();
} catch (e) { log('can not patch getFocusedWindow', String(e)); }

function onMessage(m, _payload) {
  if (m.reply && requests.has(m.reply)) {
    const resolve = requests.get(m.reply);
    requests.delete(m.reply);
    resolve(m);
    return;
  }
  const rec = wins.get(m.win);
  switch (m.t) {
    case 'resize':
      if (!rec) break;
      rec.win.setContentSize(Math.round(m.w), Math.round(m.h));
      // A resize can arrive as a few dirty rects only, leaving the new area blank.
      setImmediate(() => { if (!rec.win.isDestroyed()) rec.win.webContents.invalidate(); });
      break;
    case 'focus': if (rec) setFocused(rec); break;
    case 'blur': if (rec && focusedRec === rec) setFocused(null); break;
    case 'close': if (rec) rec.win.close(); break;
    case 'input': if (rec) deliverInput(rec, m.events || []); break;
    case 'ime': if (rec) applyIme(rec, m); break;
    case 'caret': if (rec) reportCaret(rec, m.req); break;
    case 'invalidate': if (rec) rec.win.webContents.invalidate(); break;
  }
}

// --- force windows offscreen ----------------------------------------------
// We can't replace BrowserWindow (its export is a non-configurable getter), so the
// options objects themselves claim offscreen rendering. Scoped to objects that look
// like webPreferences.
const WP_KEYS = ['preload', 'contextIsolation', 'nodeIntegration', 'sandbox', 'webSecurity', 'partition',
  'session', 'additionalArguments', 'v8CacheOptions', 'spellcheck', 'enableWebSQL', 'zoomFactor',
  'backgroundThrottling', 'webviewTag', 'enableBlinkFeatures', 'disableBlinkFeatures'];
Object.defineProperty(Object.prototype, 'offscreen', {
  configurable: true, enumerable: false,
  get() {
    if (this === Object.prototype) return undefined;
    if (!WP_KEYS.some(k => Object.prototype.hasOwnProperty.call(this, k))) return undefined;
    // Electron 33+ takes an options object and (43+) no longer follows the display's
    // scale by default; older versions only take a boolean.
    return Number(process.versions.electron.split('.')[0]) >= 33
      ? { useSharedTexture: false, deviceScaleFactor: SCALE }
      : true;
  },
  set(v) { Object.defineProperty(this, 'offscreen', { value: v, writable: true, configurable: true, enumerable: true }); },
});
// The hidden native window may grow past the screen, so it can match any tile.
Object.defineProperty(Object.prototype, 'enableLargerThanScreen', {
  configurable: true, enumerable: false,
  get() { return this !== Object.prototype && Object.prototype.hasOwnProperty.call(this, 'webPreferences') ? true : undefined; },
  set(v) { Object.defineProperty(this, 'enableLargerThanScreen', { value: v, writable: true, configurable: true, enumerable: true }); },
});

function track(win) {
  if (wins.has(win.id)) return;
  const wc = win.webContents;
  const rec = { id: nextHookWin++, win, latest: null, stale: false };
  wins.set(win.id, rec);
  win.isFocused = () => focusedRec === rec;
  // Never show the empty native window. Leave its position alone: OSR scale follows
  // the display under it.
  win.show = win.showInactive = () => {};
  win.focus = () => setFocused(rec);
  win.setOpacity(0);
  const hide = () => { if (win.isVisible()) win.hide(); };
  win.on('show', hide);
  setImmediate(hide);
  hide();

  const [w, h] = win.getContentSize();
  write({ t: 'window', win: rec.id, title: win.getTitle() || '', w, h });

  wc.setFrameRate(60);
  if (process.env.HYPRMUX_HOOK_DEBUG) {
    wc.on('before-input-event', (_e, i) => log('input', i.type, i.key, i.code, i.meta ? 'meta' : '', i.shift ? 'shift' : ''));
  }
  wc.on('paint', (_e, dirty, image) => {
    const full = image.getSize();
    if (!full.width || !full.height) return;
    let r = dirty && dirty.width > 0 && dirty.height > 0 ? dirty : { x: 0, y: 0, width: full.width, height: full.height };
    r = {
      x: Math.max(0, r.x), y: Math.max(0, r.y),
      width: Math.min(r.width, full.width - r.x), height: Math.min(r.height, full.height - r.y),
    };
    if (r.width <= 0 || r.height <= 0) return;
    rec.latest = image;
    if (backedUp) { rec.stale = true; return; }
    sendFrame(rec, image, r);
  });
  wc.on('cursor-changed', (_e, type) => write({ t: 'cursor', win: rec.id, cursor: type }));
  win.on('page-title-updated', (_e, title) => write({ t: 'title', win: rec.id, title }));
  win.on('closed', () => {
    wins.delete(win.id);
    if (focusedRec === rec) focusedRec = null;
    closePixFile(rec);
    write({ t: 'closed', win: rec.id });
  });
  // Offscreen rendering only paints on damage. A window tracked after its first paint
  // would stay blank until something changes, so ask for a full frame now.
  wc.invalidate();
}

app.on('browser-window-created', (_e, win) => {
  const wc = win.webContents;
  if (!wc.isOffscreen?.()) return;
  // Hide OSR from the app right away. VS Code skips offscreen windows when it
  // authorizes vscode-file:// requests, and it loads the workbench before showing.
  wc.isOffscreen = () => false;
  if (win.isVisible()) { track(win); return; }
  // Created hidden: the app shows it when it's ready. Track it then, and keep the
  // native window out of sight. On macOS, maximize, fullscreen, and focus also show a
  // hidden window, and VS Code uses those instead of show().
  for (const name of ['show', 'showInactive', 'focus', 'maximize', 'setFullScreen']) {
    if (typeof win[name] !== 'function') continue;
    win[name] = () => { log(name, 'shows window', win.id); track(win); };
  }
  // Some apps make the window visible through paths we don't wrap. A window that's
  // loaded and ready but still untracked a moment later is taken as shown.
  win.once('ready-to-show', () => setTimeout(() => {
    if (!wins.has(win.id) && !win.isDestroyed()) { log('ready-to-show fallback', win.id); track(win); }
  }, 1000));
});

// --- native UI through the bridge ------------------------------------------

function parentWindow(args) {
  return args[0] && typeof args[0] === 'object' && args[0].webContents ? args[0] : null;
}
function hookWin(win) { return win && wins.has(win.id) ? wins.get(win.id).id : 0; }

function proxyDialog(name, kind, sync) {
  const orig = dialog[name];
  if (typeof orig !== 'function') return;
  dialog[name] = function (...args) {
    const parent = parentWindow(args);
    const options = parent ? args[1] : args[0];
    if (process.env.HYPRMUX_HOOK_DEBUG) log('dialog', name, parent ? `win ${parent.id}` : 'no parent', parent ? wins.has(parent.id) : '');
    if (parent && !wins.has(parent.id)) return orig.apply(dialog, args);
    const winId = hookWin(parent);
    if (sync) {
      if (!BRIDGE_BIN) return fallbackDialogResult(kind);
      const r = spawnSync(BRIDGE_BIN, ['sync-dialog', SOCK, kind, String(winId), JSON.stringify(options ?? {})],
        { encoding: 'utf8', maxBuffer: 64 << 20 });
      try { return JSON.parse(r.stdout || '{}'); } catch { return fallbackDialogResult(kind); }
    }
    return request({ t: 'dialog', win: winId, kind, options: options ?? {} })
      .then((r) => r.result ?? fallbackDialogResult(kind));
  };
}

function fallbackDialogResult(kind) {
  return kind === 'message' ? { response: 0, checkboxChecked: false } : { canceled: true };
}

function serializeItems(items, path) {
  return items.map((item, i) => {
    const id = `${path}${i}`;
    item.__hyprmuxPath = id;
    const out = {
      id: String(item.id ?? id),
      label: item.label ?? '',
      type: item.type ?? 'normal',
      enabled: item.enabled !== false,
      checked: !!item.checked,
      accelerator: item.accelerator ?? '',
    };
    if (item.submenu) out.submenu = serializeItems(item.submenu.items ?? [], id + '.');
    return out;
  });
}

function findItem(items, id, path) {
  for (let i = 0; i < items.length; i++) {
    const item = items[i];
    const here = `${path}${i}`;
    if (String(item.id ?? item.__hyprmuxPath ?? here) === id || here === id) return item;
    if (item.submenu) {
      const found = findItem(item.submenu.items ?? [], id, here + '.');
      if (found) return found;
    }
  }
  return null;
}

// --- text input -------------------------------------------------------------
// Hyprmux runs the input method and sends results. Deletions become Backspace and
// Delete presses; commits go in with insertText, like a finished composition. Queued
// with other input, so a commit can't overtake the keys before it.
function applyIme(rec, m) {
  const events = [];
  const key = (code) => events.push({ type: 'keyDown', keyCode: code }, { type: 'keyUp', keyCode: code });
  for (let i = 0; i < (m.before | 0); i++) key('Backspace');
  for (let i = 0; i < (m.after | 0); i++) key('Delete');
  if (m.commit) events.push({ type: '__insertText', text: m.commit });
  deliverInput(rec, events);
}

// The caret of the focused element. Monaco (VS Code) keeps its hidden textarea at
// the caret for exactly this; for other fields it's the field's box.
const CARET_PROBE = `(() => {
  const e = document.activeElement;
  if (!e || e === document.body) return null;
  const r = e.getBoundingClientRect();
  return { x: r.left, y: r.top, w: Math.max(1, Math.min(r.width, 2)), h: Math.max(14, Math.min(r.height, 40)) };
})()`;
function reportCaret(rec, req) {
  const wc = rec.win.webContents;
  const zoom = wc.getZoomFactor?.() ?? 1;
  wc.executeJavaScript(CARET_PROBE, true).catch(() => null).then((r) => {
    if (!r) return;
    write({ t: 'caret', caret: req, x: r.x * zoom, y: r.y * zoom, w: r.w * zoom, h: r.h * zoom });
  });
}

// --- <select> popups ---------------------------------------------------------
// On macOS, Chromium shows a <select>'s options as a native menu owned by the real
// window, and offscreen rendering never shows it (electron#34047). So before a left
// mouse-down goes in, the hook asks the page what's under the pointer. On a <select>,
// it drops the click and shows the options as a Hyprmux menu, then applies the pick
// and fires input and change, like a real selection. Events that arrive meanwhile
// wait, so nothing reorders.
const SELECT_PROBE = `((x, y) => {
  const st = window.__hyprmuxSelect ??= { seq: 0, pending: new Map() };
  const s = document.elementFromPoint(x, y)?.closest?.('select');
  if (!s || s.multiple || s.size > 1 || s.disabled) return null;
  s.focus();
  const r = s.getBoundingClientRect();
  const id = ++st.seq;
  st.pending.set(id, s);
  return { id, x: r.left, y: r.bottom, items: [...s.options].map((o, i) => ({
    id: String(i), label: o.label || o.text, type: 'checkbox', enabled: !o.disabled, checked: i === s.selectedIndex,
  })) };
})`;
const SELECT_APPLY = `((id, index) => {
  const st = window.__hyprmuxSelect;
  const s = st?.pending.get(id);
  st?.pending.delete(id);
  if (!s) return;
  s.focus();
  if (index < 0 || index === s.selectedIndex) return;
  s.selectedIndex = index;
  s.dispatchEvent(new Event('input', { bubbles: true }));
  s.dispatchEvent(new Event('change', { bubbles: true }));
})`;

/// Feeds input to a window in order, holding everything behind a left mouse-down
/// until the <select> probe answers.
function deliverInput(rec, events) {
  // Menus opened without a position appear at the pointer, as Electron does natively.
  for (const ev of events) {
    if (ev.type?.startsWith('mouse') && ev.type !== 'mouseLeave' && typeof ev.x === 'number') rec.pointer = { x: ev.x, y: ev.y };
  }
  rec.inputQueue ??= [];
  rec.inputQueue.push(...events);
  pumpInput(rec);
}
function pumpInput(rec) {
  const wc = rec.win.webContents;
  while (!rec.inputBusy && rec.inputQueue.length) {
    const ev = rec.inputQueue.shift();
    if (rec.swallowUp && ev.type === 'mouseUp') { rec.swallowUp = false; continue; }
    if (ev.type === '__insertText') { wc.insertText(ev.text).catch?.(() => {}); continue; }
    if (ev.type !== 'mouseDown' || ev.button !== 'left') { wc.sendInputEvent(ev); continue; }
    rec.inputBusy = true;
    const zoom = wc.getZoomFactor?.() ?? 1;
    wc.executeJavaScript(`${SELECT_PROBE}(${ev.x / zoom}, ${ev.y / zoom})`, true).catch(() => null).then((sel) => {
      rec.inputBusy = false;
      if (!sel) { wc.sendInputEvent(ev); pumpInput(rec); return; }
      rec.swallowUp = true;
      if (process.env.HYPRMUX_HOOK_DEBUG) log('select popup', sel.items.length, 'items');
      request({ t: 'menu', win: rec.id, x: sel.x * zoom, y: sel.y * zoom, items: sel.items }).then((r) => {
        const index = r.item != null ? Number(r.item) : -1;
        if (process.env.HYPRMUX_HOOK_DEBUG) log('select closed', index >= 0 ? `picked ${index}` : 'nothing picked');
        wc.executeJavaScript(`${SELECT_APPLY}(${Number(sel.id)}, ${index})`, true).catch(() => {});
      });
      pumpInput(rec);
    });
  }
}

const origPopup = Menu.prototype.popup;
Menu.prototype.popup = function (opts = {}) {
  // No window means "the focused one" in Electron. Ours never has native focus.
  let win = parentWindow([opts.window]);
  if (!win && focusedRec && !focusedRec.win.isDestroyed()) win = focusedRec.win;
  if (process.env.HYPRMUX_HOOK_DEBUG) log('menu.popup', win ? `win ${win.id}` : 'no window', 'tracked', !!win && wins.has(win.id), 'items', (this.items ?? []).length);
  if (!win || !wins.has(win.id)) return origPopup.call(this, opts);
  const items = serializeItems(this.items ?? [], '');
  // Electron puts a menu without x/y at the cursor. VS Code relies on that for
  // right-clicks, so use the last pointer position in the window.
  const at = wins.get(win.id).pointer ?? { x: 0, y: 0 };
  const x = opts.x ?? at.x, y = opts.y ?? at.y;
  if (process.env.HYPRMUX_HOOK_DEBUG) log('menu at', Math.round(x), Math.round(y), opts.x == null ? '(pointer)' : '(given)');
  this.emit('menu-will-show');
  request({ t: 'menu', win: hookWin(win), x, y, items }).then((r) => {
    const item = r.item != null ? findItem(this.items ?? [], String(r.item), '') : null;
    if (process.env.HYPRMUX_HOOK_DEBUG) log('menu closed', item ? `picked ${item.label}` : 'nothing picked');
    // Electron's order: the menu closes, then the item's click runs. VS Code waits on
    // the callback to know its context menu is gone.
    this.emit('menu-will-close');
    try { opts.callback?.(); } catch (e) { log('menu callback failed', String(e)); }
    if (item && typeof item.click === 'function') {
      try { item.click(item, win, {}); } catch (e) { log('menu click failed', String(e)); }
    }
  });
};

app.on('ready', () => {
  proxyDialog('showOpenDialog', 'open', false);
  proxyDialog('showSaveDialog', 'save', false);
  proxyDialog('showMessageBox', 'message', false);
  proxyDialog('showOpenDialogSync', 'open', true);
  proxyDialog('showSaveDialogSync', 'save', true);
  proxyDialog('showMessageBoxSync', 'message', true);
  log('dialogs and menus proxied');
});

// The bridge injected us through the inspector. Close it so no debugger port stays open.
setTimeout(() => { try { require('inspector').close(); } catch {} }, 2000);

connect(0);
log('hook loaded; electron', process.versions.electron, 'adapter', ADAPTER);
