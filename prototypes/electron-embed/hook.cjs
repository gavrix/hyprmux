// Injected into an Electron app's main process. Forces offscreen rendering for
// every BrowserWindow and streams frames + input over a WebSocket.
const fs = require('fs');
const http = require('http');
const crypto = require('crypto');
const { app, BrowserWindow } = require('electron');

const PORT = Number(process.env.EE_PORT || 9400);
const LOG = '/tmp/ee/hook.log';
const log = (...a) => fs.appendFileSync(LOG, new Date().toISOString().slice(11, 23) + ' ' + a.map(x => typeof x === 'string' ? x : JSON.stringify(x)).join(' ') + '\n');
log('hook loaded in', process.execPath, 'electron', process.versions.electron);

// 1. Make native BrowserWindow construction see webPreferences.offscreen = true.
//    Scoped to objects that look like webPreferences.
const WP_KEYS = ['preload', 'contextIsolation', 'nodeIntegration', 'sandbox', 'webSecurity', 'partition', 'session', 'additionalArguments', 'v8CacheOptions', 'spellcheck', 'enableWebSQL', 'zoomFactor', 'backgroundThrottling', 'webviewTag', 'enableBlinkFeatures', 'disableBlinkFeatures'];
Object.defineProperty(Object.prototype, 'offscreen', {
  configurable: true, enumerable: false,
  get() {
    if (this === Object.prototype) return undefined;
    const looksLikeWP = WP_KEYS.some(k => Object.prototype.hasOwnProperty.call(this, k));
    if (looksLikeWP) log('offscreen lookup -> true on', Object.keys(this).slice(0, 8));
    if (!looksLikeWP) return undefined;
    // Electron 33+ takes an options object; older versions only a boolean.
    if (Number(process.versions.electron.split('.')[0]) >= 33) {
      let scale = 2;
      try { scale = require('electron').screen.getPrimaryDisplay().scaleFactor; } catch {}
      return { useSharedTexture: false, deviceScaleFactor: scale };
    }
    return true;
  },
  set(v) { Object.defineProperty(this, 'offscreen', { value: v, writable: true, configurable: true, enumerable: true }); },
});

// Let the hidden native window grow past the screen size so it can match any tile.
Object.defineProperty(Object.prototype, 'enableLargerThanScreen', {
  configurable: true, enumerable: false,
  get() { return this !== Object.prototype && Object.prototype.hasOwnProperty.call(this, 'webPreferences') ? true : undefined; },
  set(v) { Object.defineProperty(this, 'enableLargerThanScreen', { value: v, writable: true, configurable: true, enumerable: true }); },
});

// Diagnostics: log webRequest decisions for app-internal schemes.
if (process.env.EE_DIAG) app.on('ready', () => {
  const { session } = require('electron');
  const proto = session.defaultSession.webRequest;
  const orig = proto.onBeforeRequest.bind(proto);
  proto.onBeforeRequest = function (...args) {
    const i = typeof args[0] === 'function' ? 0 : 1;
    const handler = args[i];
    if (typeof handler === 'function') args[i] = (details, cb) => handler(details, (res) => {
      if (res && res.cancel) {
        const f = details.frame;
        log('CANCEL', details.url.slice(0, 90), 'frame', f ? { pid: f.processId, rid: f.routingId, url: f.url, destroyed: f.isDestroyed() } : null,
          'wins', BrowserWindow.getAllWindows().map(w => ({ id: w.id, pid: w.webContents.mainFrame?.processId, osr: w.webContents.isOffscreen() })), 'wcId', details.webContentsId, 'type', details.resourceType);
      }
      cb(res);
    });
    return orig(...args);
  };
});

// System dialogs. A dialog parented to our hidden window becomes an invisible sheet,
// and the app is not frontmost, so the user never sees it. Detach it from the hidden
// window, bring the app forward while it is open, then hand focus back to the host.
const HOST_BUNDLE = process.env.EE_HOST_BUNDLE_ID || 'dev.gavrix.hyprmux';
const reactivateHost = () => require('child_process').spawn('open', ['-b', HOST_BUNDLE], { stdio: 'ignore', detached: true }).unref();
app.on('ready', () => {
  const { dialog } = require('electron');
  for (const name of ['showOpenDialog', 'showSaveDialog', 'showMessageBox', 'showOpenDialogSync', 'showSaveDialogSync', 'showMessageBoxSync', 'showCertificateTrustDialog']) {
    const orig = dialog[name];
    if (typeof orig !== 'function') continue;
    const wrapped = function (...args) {
      const parent = args[0] && typeof args[0] === 'object' && 'webContents' in args[0] ? args[0] : null;
      if (parent && wins.has(parent.id)) args.shift();
      log('dialog', name, 'detached', !!parent);
      app.focus({ steal: true });
      const r = orig.apply(dialog, args);
      if (r && typeof r.then === 'function') return r.finally(reactivateHost);
      reactivateHost();
      return r;
    };
    try { dialog[name] = wrapped; if (dialog[name] !== wrapped) throw new Error('not writable'); }
    catch (err) { log('dialog patch failed', name, err.message); }
  }
  log('dialogs patched');
});

// 2. Track windows.
const wins = new Map(); // id -> { win, clients:Set, last:{img} }
app.on('browser-window-created', (_e, win) => {
  const id = win.id;
  const wc = win.webContents;
  const osr = wc.isOffscreen?.();
  // Hide OSR from the app itself: VS Code, for one, skips offscreen windows when it
  // authorizes vscode-file:// requests.
  if (osr) wc.isOffscreen = () => false;
  log('window created', id, 'offscreen', osr, 'visible', win.isVisible(), 'bounds', win.getBounds());
  const rec = { win, osr, clients: new Set(), lastFull: null, frames: 0 };
  wins.set(id, rec);
  // Never show the (empty) native window. Leave its position alone: OSR takes its
  // device scale factor from the display under the window.
  if (osr) {
    win.show = win.showInactive = () => log('suppressed show', id);
    win.focus = () => wc.focus();
    // Apps may pass show:true, which Electron honours natively after this event.
    win.setOpacity(0);
    const hideNow = () => { if (win.isVisible()) { win.hide(); log('hid native window', id); } };
    win.on('show', hideNow); setImmediate(hideNow); hideNow();
  }
  if (!osr) return;
  wc.setFrameRate(60);
  wc.on('paint', (_ev, dirty, image) => {
    rec.frames++;
    rec.lastFull = image;
    if (rec.frames <= 3) {
      log('paint', id, 'dirty', dirty, 'size', image.getSize(), 'scales', image.getScaleFactors?.(), 'content', win.getContentSize(), 'bmpLen', image.toBitmap().length);
    }
    if (!rec.clients.size) return;
    sendFrame(rec, dirty, image);
  });
  wc.on('cursor-changed', (_ev, type) => broadcast(rec, JSON.stringify({ t: 'cursor', type })));
  win.on('page-title-updated', (_ev, title) => broadcast(rec, JSON.stringify({ t: 'title', title })));
  win.on('closed', () => { for (const c of rec.clients) c.close(); wins.delete(id); });
});

function sendFrame(rec, dirty, image) {
  const full = image.getSize();
  // image.getSize() is in DIP; the bitmap is at device scale. Crop in DIP.
  const rect = dirty && dirty.width ? dirty : { x: 0, y: 0, width: full.width, height: full.height };
  const part = (rect.width === full.width && rect.height === full.height) ? image : image.crop(rect);
  const jpeg = part.toJPEG(92);
  const header = Buffer.alloc(24);
  header.writeInt32LE(rect.x, 0); header.writeInt32LE(rect.y, 4);
  header.writeInt32LE(rect.width, 8); header.writeInt32LE(rect.height, 12);
  header.writeInt32LE(full.width, 16); header.writeInt32LE(full.height, 20);
  const buf = Buffer.concat([header, jpeg]);
  for (const c of rec.clients) c.sendBinary(buf);
}
function broadcast(rec, text) { for (const c of rec.clients) c.sendText(text); }

// 3. Input.
function handleInput(rec, msg) {
  const { win } = rec; const wc = win.webContents;
  switch (msg.t) {
    case 'resize': {
      const w = Math.max(200, Math.round(msg.w)), h = Math.max(150, Math.round(msg.h));
      win.setContentSize(w, h);
      log('resize', rec.win.id, w, h, '->', win.getContentSize());
      setTimeout(() => wc.invalidate(), 50);
      break;
    }
    case 'focus': wc.focus(); win.focusOnWebView?.(); break;
    case 'blur': win.blurWebView?.(); break;
    case 'mouse': wc.sendInputEvent(msg.ev); break;
    case 'key': for (const ev of msg.evs) wc.sendInputEvent(ev); break;
    case 'invalidate': wc.invalidate(); break;
    case 'eval': // debug only
      wc.executeJavaScript(msg.js).then(v => broadcast(rec, JSON.stringify({ t: 'eval', v })), e => broadcast(rec, JSON.stringify({ t: 'eval', err: String(e) })));
      break;
  }
}

// 4. Tiny HTTP + WebSocket server (no deps).
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://x');
  if (url.pathname === '/debug') {
    const { screen } = require('electron');
    res.setHeader('content-type', 'application/json');
    res.end(JSON.stringify([...wins.values()].map(r => { const b = r.win.getBounds(); return { id: r.win.id, bounds: b, visible: r.win.isVisible(), displayScale: screen.getDisplayMatching(b).scaleFactor, frameSize: r.lastFull?.getSize() }; })));
    return;
  }
  if (url.pathname === '/windows') {
    res.setHeader('content-type', 'application/json');
    res.end(JSON.stringify([...wins.values()].map(r => ({ id: r.win.id, title: r.win.getTitle(), size: r.win.getContentSize(), offscreen: r.osr }))));
    return;
  }
  res.setHeader('content-type', 'text/html'); res.end(fs.readFileSync('/tmp/ee/viewer.html'));
});
server.on('upgrade', (req, socket) => {
  const url = new URL(req.url, 'http://x');
  const rec = wins.get(Number(url.searchParams.get('w'))) || [...wins.values()][0];
  if (!rec) { socket.destroy(); return; }
  const accept = crypto.createHash('sha1').update(req.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
  socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
  socket.setNoDelay(true);
  const frame = (op, payload) => {
    const len = payload.length; let h;
    if (len < 126) { h = Buffer.from([0x80 | op, len]); }
    else if (len < 65536) { h = Buffer.alloc(4); h[0] = 0x80 | op; h[1] = 126; h.writeUInt16BE(len, 2); }
    else { h = Buffer.alloc(10); h[0] = 0x80 | op; h[1] = 127; h.writeBigUInt64BE(BigInt(len), 2); }
    socket.write(Buffer.concat([h, payload]));
  };
  const client = {
    sendBinary: (b) => frame(2, b), sendText: (s) => frame(1, Buffer.from(s)),
    close: () => { try { frame(8, Buffer.alloc(0)); socket.end(); } catch {} },
  };
  rec.clients.add(client);
  log('client connected to window', rec.win.id);
  client.sendText(JSON.stringify({ t: 'hello', id: rec.win.id, title: rec.win.getTitle() }));
  if (rec.lastFull) sendFrame(rec, null, rec.lastFull);
  let buf = Buffer.alloc(0);
  socket.on('data', (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    while (buf.length >= 2) {
      const op = buf[0] & 0x0f; let len = buf[1] & 0x7f; let off = 2;
      if (len === 126) { if (buf.length < 4) return; len = buf.readUInt16BE(2); off = 4; }
      else if (len === 127) { if (buf.length < 10) return; len = Number(buf.readBigUInt64BE(2)); off = 10; }
      const masked = buf[1] & 0x80; const mask = masked ? buf.subarray(off, off + 4) : null; if (masked) off += 4;
      if (buf.length < off + len) return;
      const data = Buffer.from(buf.subarray(off, off + len)); buf = buf.subarray(off + len);
      if (mask) for (let i = 0; i < data.length; i++) data[i] ^= mask[i & 3];
      if (op === 8) { socket.end(); return; }
      if (op === 9) { frame(10, data); continue; }
      if (op === 1) { try { handleInput(rec, JSON.parse(data.toString())); } catch (err) { log('input err', err.message); } }
    }
  });
  const drop = () => { rec.clients.delete(client); };
  socket.on('close', drop); socket.on('error', drop);
});
server.listen(PORT, '127.0.0.1', () => log('viewer on http://127.0.0.1:' + PORT));
