// node --experimental-websocket grab.mjs <out.jpg> [keys-json]
import fs from 'fs';
const [out, keys] = process.argv.slice(2);
const ws = new WebSocket('ws://127.0.0.1:' + (process.env.P || 9400) + '/ws?w=' + (process.env.W || 1)); ws.binaryType = 'arraybuffer';
let ready = false;
ws.onopen = async () => {
  if (keys) { for (const k of JSON.parse(keys)) { ws.send(JSON.stringify(k)); await new Promise(r => setTimeout(r, 120)); } await new Promise(r => setTimeout(r, 800)); }
  ready = true; ws.send(JSON.stringify({ t: 'invalidate' }));
};
ws.onmessage = (m) => { if (typeof m.data === 'string') { console.log('msg', m.data); return; } const h = new Int32Array(m.data, 0, 6); if (ready && h[2] === h[4] && h[3] === h[5]) { fs.writeFileSync(out, Buffer.from(m.data, 24)); console.log('full frame', [...h]); ws.close(); process.exit(0); } };
setTimeout(() => { console.log('timeout'); process.exit(1); }, 8000);
