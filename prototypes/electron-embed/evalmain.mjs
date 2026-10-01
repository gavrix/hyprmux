// node --experimental-websocket evalmain.mjs <inspectPort> '<js expression>'   (E = electron module)
const [port, js] = process.argv.slice(2);
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list[0].webSocketDebuggerUrl);
await new Promise(r => ws.onopen = r);
ws.onmessage = (m) => { const d = JSON.parse(m.data); if (d.id === 1) { console.log(JSON.stringify(d.result?.result?.value ?? d.result, null, 1)); process.exit(0); } };
const expr = `(async () => { const E = process.getBuiltinModule('module').createRequire('/tmp/ee/x.js')('electron'); return ${js}; })()`;
ws.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate', params: { expression: expr, awaitPromise: true, returnByValue: true } }));
