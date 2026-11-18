// G7: noVNC's own RFB client in a headless Chromium (sibling container on the browser's network), driven over CDP by
// this node script (modes: <n> [fps|watch]). Measures input → Chromium → Xvnc → websockify → decode → visible canvas latency, the
// viewer's frame rate on a moving page, and clipboard both ways. Usage: node novnc-probe.mjs <http://host:6080> <n>
const [origin, n = '30'] = process.argv.slice(2);
const deadline = setTimeout(() => { console.log(JSON.stringify({ error: 'timed out' })); process.exit(3); }, 120000);
const sleep = ms => new Promise(r => setTimeout(r, ms));
let target;
for (let i = 0; i < 100 && !target; i++) {
  try { target = await (await fetch('http://127.0.0.1:9222/json/new?' + origin + '/g7-probe', { method: 'PUT' })).json(); } catch { await sleep(100); }
}
const ws = new WebSocket(target.webSocketDebuggerUrl);
let id = 0; const waiting = new Map();
ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id && waiting.has(m.id)) { waiting.get(m.id)(m); waiting.delete(m.id); } };
const send = (method, params = {}) => new Promise(r => { const i = ++id; waiting.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expression) => { return (await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true })).result.result.value; };
await new Promise(r => ws.onopen = r);
await sleep(1000);
const setup = await ev(`(async () => {
  document.body.innerHTML = '<div id=s style="width:1280px;height:800px"></div>';
  const { default: RFB } = await import('/core/rfb.js');
  const t0 = performance.now();
  const rfb = new RFB(document.getElementById('s'), location.origin.replace('http', 'ws') + '/websockify');
  window.g7 = { rfb, clip: null };
  rfb.addEventListener('clipboard', e => { g7.clip = e.detail.text; });
  await new Promise(r => rfb.addEventListener('connect', r));
  await new Promise(r => setTimeout(r, 1000));
  const canvas = document.querySelector('#s canvas');
  g7.bright = () => { const d = canvas.getContext('2d').getImageData(Math.floor(canvas.width * 0.3), Math.floor(canvas.height * 0.875), 1, 1).data; return d[0] + d[1] + d[2] > 384; };
  g7.measure = async (n, kind) => { const out = [];
    for (let i = 0; i < n; i++) { const before = g7.bright(), t = performance.now();
      if (kind === 'key') rfb.sendKey(0x20, 'Space'); else {
        const r = canvas.getBoundingClientRect(), at = { clientX: r.left + r.width * 0.08, clientY: r.top + r.height * 0.875, button: 0, bubbles: true };
        canvas.dispatchEvent(new MouseEvent('mousedown', { ...at, buttons: 1 })); canvas.dispatchEvent(new MouseEvent('mouseup', at)); }
      let dt = -1; while (performance.now() - t < 2000) { await new Promise(r => requestAnimationFrame(r)); if (g7.bright() !== before) { dt = performance.now() - t; break; } }
      out.push(Math.round(dt * 10) / 10); await new Promise(r => setTimeout(r, 150)); }
    return out; };
  g7.fps = async (ms) => { let frames = 0, last = null; const c = canvas.getContext('2d'); const t = performance.now();
    while (performance.now() - t < ms) { await new Promise(r => requestAnimationFrame(r));
      const d = c.getImageData(0, 0, canvas.width, canvas.height >> 1).data; let h = 0; for (let i = 0; i < d.length; i += 4097) h = (h * 31 + d[i]) | 0;
      if (h !== last) { frames++; last = h; } }
    return Math.round(frames / (ms / 1000) * 10) / 10; };
  return Math.round(performance.now() - t0);
})()`);
const stats = a => { const s = a.filter(x => x >= 0).sort((x, y) => x - y); return { n: s.length, failed: a.length - s.length, p50: s[s.length >> 1], p90: s[Math.floor(s.length * 0.9)], min: s[0], max: s[s.length - 1] }; };
const out = { connect_ms: setup };
if (process.env.G7_FRAME) { const url = await ev(`document.querySelector('#s canvas').toDataURL('image/png')`); (await import('node:fs')).writeFileSync(process.env.G7_FRAME, Buffer.from(url.split(',')[1], 'base64')); }
const key = await ev(`g7.measure(${n}, 'key')`), click = await ev(`g7.measure(${n}, 'click')`);
out.key_ms = stats(key); out.click_ms = stats(click); out.key_raw = key; out.click_raw = click;
// Clipboard: Mac (viewer) → container; then the container's page copies text → viewer event.
await ev(`g7.rfb.clipboardPasteFrom('g7-from-viewer')`);
console.log(JSON.stringify(out));
process.stdout.write('');
if (process.argv[4] === 'watch') { await sleep(Number(process.env.G7_FPS_MS || 20000)); console.log(JSON.stringify({ watched_ms: Number(process.env.G7_FPS_MS || 20000) })); process.exit(0); }
const fpsWait = process.argv[4] === 'fps';
if (fpsWait) { console.log(JSON.stringify({ viewer_fps_on_moving_page: await ev(`g7.fps(${process.env.G7_FPS_MS || 5000})`) })); }
console.log(JSON.stringify({ clip_received_from_container: (await ev(`new Promise(r => { const t = Date.now(); const f = () => g7.clip || Date.now() - t > 8000 ? r(g7.clip) : setTimeout(f, 50); f(); })`)) }));
ws.close();
clearTimeout(deadline);
