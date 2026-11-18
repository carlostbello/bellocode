// G7: tiny CDP client run with the image's node (inside the container, against Chromium's loopback-only
// --remote-debugging-port). `node cdp.mjs eval <urlSubstring> <expression>` or
// `node cdp.mjs screencast <urlSubstring> <flips> [quality] [maxWidth]`: flips the page colour N times through
// Runtime.evaluate and reports change → first screencast frame latency, frame sizes and rate.
const [mode, match, arg, quality = '60', maxWidth = '1280'] = process.argv.slice(2);
const targets = await (await fetch('http://127.0.0.1:9222/json/list')).json();
const target = targets.find(t => t.type === 'page' && t.url.includes(match));
if (!target) { console.log(JSON.stringify({ error: 'no target', urls: targets.map(t => t.url) })); process.exit(1); }
const ws = new WebSocket(target.webSocketDebuggerUrl);
let id = 0; const waiting = new Map(); const frames = [];
ws.onmessage = e => {
  const m = JSON.parse(e.data);
  if (m.id && waiting.has(m.id)) { waiting.get(m.id)(m); waiting.delete(m.id); }
  if (m.method === 'Page.screencastFrame') {
    frames.push({ at: performance.now(), bytes: m.params.data.length * 3 / 4 });
    send('Page.screencastFrameAck', { sessionId: m.params.sessionId });
  }
};
const send = (method, params = {}) => new Promise(r => { const i = ++id; waiting.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
await new Promise(r => ws.onopen = r);
const sleep = ms => new Promise(r => setTimeout(r, ms));
if (mode === 'eval') {
  const r = await send('Runtime.evaluate', { expression: arg, returnByValue: true });
  console.log(JSON.stringify(r.result?.result?.value ?? r));
} else {
  await send('Page.startScreencast', { format: 'jpeg', quality: Number(quality), maxWidth: Number(maxWidth), everyNthFrame: 1 });
  await sleep(800); frames.length = 0;
  const lat = [];
  for (let i = 0; i < Number(arg); i++) {
    const n = frames.length, t0 = performance.now();
    await send('Runtime.evaluate', { expression: 'flip()' });
    while (frames.length === n && performance.now() - t0 < 3000) await sleep(1);
    lat.push(frames.length > n ? Math.round((frames[n].at - t0) * 10) / 10 : -1);
    await sleep(150);
  }
  frames.length = 0; const t1 = performance.now();
  await send('Runtime.evaluate', { expression: "location.href = location.href.replace('toggle.html','anim.html')" });
  await sleep(5000);
  const secs = (performance.now() - t1) / 1000, kb = frames.reduce((a, f) => a + f.bytes, 0) / 1024;
  await send('Page.stopScreencast');
  await send('Runtime.evaluate', { expression: "location.href = location.href.replace('anim.html','toggle.html')" });
  const s = [...lat].filter(x => x >= 0).sort((a, b) => a - b);
  console.log(JSON.stringify({ change_to_frame_ms: { p50: s[s.length >> 1], p90: s[Math.floor(s.length * 0.9)], min: s[0], max: s[s.length - 1], raw: lat },
    animation: { fps: Math.round(frames.length / secs * 10) / 10, kib_per_s: Math.round(kb / secs), quality: Number(quality), maxWidth: Number(maxWidth) } }));
}
ws.close();
