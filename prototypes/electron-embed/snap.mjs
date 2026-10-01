import fs from 'fs';
const ws = new WebSocket('ws://127.0.0.1:' + (process.env.P || 9400) + '/ws?w=' + (process.env.W || 1)); ws.binaryType = 'arraybuffer';
ws.onmessage = (m) => { if (typeof m.data === 'string') return; fs.writeFileSync(process.argv[2], Buffer.from(m.data, 24)); process.exit(0); };
setTimeout(() => process.exit(1), 5000);
