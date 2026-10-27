// dev/ui-test/prelude.js — run.sh가 시나리오 앞에 붙이는 도우미. 앱의 callAsyncJavaScript 본문으로 돈다(최상위 await 가능).
// snap(이름)        지금 화면을 <결과 폴더>/<이름>.png로 남긴다
// sleep(ms) · frames(n) · until(fn, ms)   기다리기 (until은 fn()이 참이 될 때까지, 시간이 지나면 null)
// key(키, {meta, shift, alt, ctrl}, 대상)  keydown·keyup을 보낸다 ('Enter' 'Escape' 'ArrowDown' 'Tab' '[' 'k' …)
// click(css|요소) · dblclick(…) · contextClick(css|요소|{x,y})   마우스 (contextClick = 오른쪽 클릭)
// clickAt(x, y) · dblclickAt(x, y)       창 좌표 클릭(그래프 노드 등). 노드 좌표는 nodeAt(id)
// type(css, 글자) · text(css) · $(css) · $$(css) · log(...) · resize(w, h)
// dbg() = window.__synapseDebug (앱의 읽기 전용 QA 핸들: .state .source .brain .view .graphData .graph, idle()은 대기 중인 요청이 끝날 때까지)
// idle() = 화면 요청이 모두 끝날 때까지 기다린다
const __OUT = __OUT_JSON__;
const __SIZE = __SIZE_JSON__;
const __logs = [];
const __api = (method, params) => window.webkit.messageHandlers.synapseAPI.postMessage({ method, params: params || {} });
const sleep = ms => new Promise(r => setTimeout(r, ms));
const frames = (n = 2) => new Promise(r => { const f = k => (k <= 0 ? r() : requestAnimationFrame(() => f(k - 1))); f(n); });
const $ = sel => document.querySelector(sel);
const $$ = sel => Array.from(document.querySelectorAll(sel));
const dbg = () => window.__synapseDebug || null;
const log = (...a) => { __logs.push(a.map(x => (typeof x === 'string' ? x : JSON.stringify(x))).join(' ')); };
async function until(fn, ms = 8000, step = 100) {
  const end = Date.now() + ms;
  for (;;) {
    let v = null;
    try { v = fn(); } catch (_) { v = null; }
    if (v) return v;
    if (Date.now() > end) return null;
    await sleep(step);
  }
}
async function snap(name) {
  await frames(2); await sleep(150);
  const path = __OUT + '/' + String(name).replace(/[^\w가-힣.-]+/g, '_') + '.png';
  try { const r = await __api('testSnapshot', { path }); return (r && r.path) || path; }
  catch (e) { log('snap 실패', name, String(e)); return null; }
}
async function resize(w, h) {
  try { await __api('testResize', { width: w, height: h }); } catch (e) { log('resize 실패', String(e)); }
  await sleep(300);
}
const KEY_CODES = { '[': 'BracketLeft', ']': 'BracketRight', '\\': 'Backslash', '/': 'Slash', '=': 'Equal', '-': 'Minus', ' ': 'Space', ',': 'Comma', '.': 'Period' };
function key(k, mods = {}, target) {
  const code = /^[a-z]$/i.test(k) ? 'Key' + k.toUpperCase() : /^\d$/.test(k) ? 'Digit' + k : KEY_CODES[k] || k;
  const opts = { key: k, code, bubbles: true, cancelable: true, metaKey: !!mods.meta, shiftKey: !!mods.shift, altKey: !!mods.alt, ctrlKey: !!mods.ctrl };
  const t = target || document.activeElement || document.body;
  t.dispatchEvent(new KeyboardEvent('keydown', opts));
  t.dispatchEvent(new KeyboardEvent('keyup', opts));
}
const elOf = x => (typeof x === 'string' ? $(x) : x);
function centerOf(n) { const r = n.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; }
function mouse(type, x, y, opts = {}) {
  const t = document.elementFromPoint(x, y) || document.body;
  t.dispatchEvent(new MouseEvent(type, Object.assign({ bubbles: true, cancelable: true, clientX: x, clientY: y, view: window }, opts)));
  return t;
}
function click(x) { const n = elOf(x); if (!n) { log('click: 찾지 못함', String(x)); return false; } n.click(); return true; }
function dblclick(x) {
  const n = elOf(x); if (!n) { log('dblclick: 찾지 못함', String(x)); return false; }
  const c = centerOf(n);
  n.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, clientX: c.x, clientY: c.y, detail: 1 }));
  n.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, clientX: c.x, clientY: c.y, detail: 2 }));
  n.dispatchEvent(new MouseEvent('dblclick', { bubbles: true, cancelable: true, clientX: c.x, clientY: c.y, detail: 2 }));
  return true;
}
function contextClick(x) {
  let c;
  if (x && typeof x === 'object' && 'x' in x && 'y' in x && !(x instanceof Element)) c = x;
  else { const n = elOf(x); if (!n) { log('contextClick: 찾지 못함', String(x)); return false; } c = centerOf(n); }
  mouse('mousedown', c.x, c.y, { button: 2, buttons: 2 });
  mouse('mouseup', c.x, c.y, { button: 2 });
  mouse('contextmenu', c.x, c.y, { button: 2 });
  return true;
}
// 그래프 캔버스는 pointer/mouse 이벤트를 받는다. 창 좌표(clientX/Y)로 누르고 뗀다.
function clickAt(x, y, opts = {}) {
  const base = Object.assign({ button: 0 }, opts);
  for (const type of ['pointerdown', 'mousedown']) mouse(type, x, y, Object.assign({ buttons: 1 }, base));
  for (const type of ['pointerup', 'mouseup', 'click']) mouse(type, x, y, base);
  return true;
}
function dblclickAt(x, y) { clickAt(x, y, { detail: 1 }); clickAt(x, y, { detail: 2 }); mouse('dblclick', x, y, { detail: 2 }); return true; }
// 그래프 노드의 창 좌표 (없으면 null)
function nodeAt(id) {
  const d = dbg(), g = d && d.graph; if (!g || typeof g.debugNode !== 'function') return null;
  const n = g.debugNode(id), r = document.getElementById('graph-host').getBoundingClientRect();
  return n ? { x: r.left + n.sx, y: r.top + n.sy } : null;
}
async function idle(ms = 15000) { const d = dbg(); if (!d) return false; return Promise.race([d.idle().then(() => true), sleep(ms).then(() => false)]); }
async function type(sel, value) {
  const n = elOf(sel); if (!n) { log('type: 찾지 못함', String(sel)); return false; }
  n.focus(); n.value = value; n.dispatchEvent(new Event('input', { bubbles: true }));
  return true;
}
const text = sel => { const n = elOf(sel); return n ? n.innerText.trim() : null; };
window.addEventListener('error', e => __logs.push('PAGE_ERROR ' + (e.message || e)));
let __result = null, __error = null;
await resize(__SIZE[0], __SIZE[1]);
await until(() => dbg() && dbg().source && dbg().source.active !== 'none', 30000);
try {
  __result = await (async () => {
/*__SCENARIO__*/
  })();
} catch (e) { __error = String(e) + (e && e.stack ? '\n' + e.stack : ''); }
return { result: __result, error: __error, logs: __logs };
