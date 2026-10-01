// Usage: node --experimental-websocket inject.mjs <port> <hook.cjs> [entryUrlRegex]
// Launch the Electron app with --inspect-brk=<port> first.
const [port, hook, entry = '.*'] = process.argv.slice(2);
let list;
for (let i = 0; i < 200; i++) {
  try { list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json(); if (list.length) break; } catch {}
  await new Promise(r => setTimeout(r, 50));
}
const ws = new WebSocket(list[0].webSocketDebuggerUrl);
let id = 0; const pending = new Map(); const handlers = {};
ws.onmessage = (m) => {
  const d = JSON.parse(m.data);
  if (d.id && pending.has(d.id)) { pending.get(d.id)(d); pending.delete(d.id); }
  else if (d.method && handlers[d.method]) handlers[d.method](d.params);
};
const send = (method, params = {}) => new Promise(r => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
await new Promise(r => ws.onopen = r);
let pauses = 0;
const done = new Promise(resolve => {
  handlers['Debugger.paused'] = async (p) => {
    pauses++;
    const f = p.callFrames[0]; f.url = f.url || urls.get(f.location.scriptId) || '';
    console.log('paused at', f.url, f.location.lineNumber);
    const probe = await send('Debugger.evaluateOnCallFrame', { callFrameId: f.callFrameId, expression: '(typeof require === "function" ? "req" : typeof process?.getBuiltinModule === "function" ? "gbm" : "none")' });
    console.log('  globals:', probe.result?.result?.value);
    const how = probe.result?.result?.value;
    if (pauses > 50) { await send('Debugger.removeBreakpoint', { breakpointId: bp.result.breakpointId }); await send('Debugger.resume'); console.log('gave up'); resolve(); return; }
    if (new RegExp(entry).test(f.url) && f.url && (how === 'req' || how === 'gbm')) {
      const H = JSON.stringify(hook);
      const expr = how === 'req' ? `require(${H}), "injected via require"` : `process.getBuiltinModule("module").createRequire(${H})(${H}), "injected via getBuiltinModule"`;
      const res = await send('Debugger.evaluateOnCallFrame', { callFrameId: f.callFrameId, expression: expr });
      console.log('  inject:', JSON.stringify(res.result?.result ?? res).slice(0, 400));
      await send('Debugger.removeBreakpoint', { breakpointId: bp.result.breakpointId }).catch(() => {});
      await send('Debugger.resume');
      resolve();
    } else {
      await send('Debugger.resume');
    }
  };
});
const urls = new Map();
handlers['Debugger.scriptParsed'] = (p) => urls.set(p.scriptId, p.url);
await send('Debugger.enable');
const bp = await send('Debugger.setBreakpointByUrl', { urlRegex: entry, lineNumber: 0 });
await send('Runtime.runIfWaitingForDebugger');
await Promise.race([done, new Promise(r => setTimeout(r, 15000))]);
await send('Debugger.disable');
ws.close();
