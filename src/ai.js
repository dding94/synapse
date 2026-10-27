// ai.js — Synapse v0.8 Claude 연결 공용 도우미 (docs/V08.md §8.1). window.SynapseAI 하나만 만든다.
// 계약: init(api) · status() · cached() · on(type, fn) → off · digest(kind, {offset, docId, run}) · refsHTML(refs, E) · bindRefs(rootEl) ·
//       metaLabel(meta) · noticeHTML(res, E) · copyReport(text, html)
// 덧붙인 도우미(화면끼리 같은 모양을 쓰려고): openRef(docId, line) · metaHTML(meta, E, opts) · stateChipHTML(state, E) · itemIconHTML(state) · skeletonHTML(rows)
// window.synapseAIEvent(e)도 여기서 정의한다 — 앱이 켜지기 전(init 전)에 온 이벤트는 모아 뒀다가 init 뒤에 흘려보낸다.
// 이 파일은 화면을 직접 그리지 않는다. 이번 주·티켓·홈·리더·패널이 같은 칩·안내·시각 문구를 쓰게 HTML 조각만 만든다.
(function () {
  'use strict';

  let api = null;
  let cache = null, cacheAt = 0, inflight = null, gen = 0;
  const STATUS_TTL = 45000;          // status 이벤트를 놓쳐도 이 시간 뒤에는 새로 읽는다
  const subs = { status: new Set(), run: new Set(), digest: new Set() };
  const early = [];                  // init 전에 온 이벤트

  const ESC_MAP = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
  const escLocal = v => String(v == null ? '' : v).replace(/[&<>"']/g, c => ESC_MAP[c]);
  const escOf = E => (typeof E === 'function' ? E : (api && typeof api.esc === 'function' ? api.esc : escLocal));
  const ic = name => { try { return api && api.icon ? api.icon(name) || '' : ''; } catch (_) { return ''; } };
  const P2 = n => String(n).padStart(2, '0');

  // ---------- 브리지 ----------
  async function call(method, params) {
    if (!api) return { ok: false, error: '아직 준비되지 않았어요' };
    try {
      const r = await api.call(method, params || {});
      return r && typeof r === 'object' ? r : { ok: false, error: '응답을 읽지 못했어요' };
    } catch (e) { return { ok: false, error: (e && e.message) || '처리하지 못했어요' }; }
  }
  const NO_BRIDGE = /알 수 없는 method|unknown method|not supported|지원하지 않|준비되지 않/i;

  function init(a) {
    if (a) api = a;
    if (api && early.length) { const list = early.splice(0); setTimeout(() => list.forEach(dispatch), 0); }
    if (api && !cache && !inflight) status();   // 캐시를 미리 데워 두면 화면이 처음 열릴 때 Claude를 쓸 수 있는지 바로 안다
  }

  // ---------- 상태 ----------
  // 브리지가 없거나(옛 앱·브라우저 미리보기) 읽지 못했을 때 화면이 같은 모양으로 다룰 수 있게 채운다
  function offlineStatus(msg) {
    return { ok: false, unsupported: true, available: false, enabled: false, auto: false, error: msg || null,
      claude: { found: false, path: null, version: null, login: 'unknown', error: msg || null }, models: {}, running: [], report: null, presets: [], limits: null };
  }
  function status(force) {
    if (!force && cache && Date.now() - cacheAt < STATUS_TTL) return Promise.resolve(cache);
    if (inflight) return inflight;
    const my = gen;
    inflight = call('aiStatus').then(r => {
      const st = r.ok === false ? offlineStatus(r.error) : r;
      if (my === gen) { cache = st; cacheAt = Date.now(); }
      inflight = null;
      return st;
    });
    return inflight;
  }
  const cached = () => cache;
  function invalidate() { gen++; cacheAt = 0; inflight = null; }

  // ---------- 이벤트 ----------
  function fire(type, e, extra) {
    const set = subs[type]; if (!set) return;
    Array.from(set).forEach(fn => { try { fn(e, extra); } catch (err) { console.warn('[synapse] ai event:', err && err.message); } });
  }
  let statusTimer = 0;
  function dispatch(e) {
    if (!e || typeof e !== 'object') return;
    if (e.type === 'status') {
      // 캐시를 새로 읽은 뒤에 알린다 — 구독자가 cached()를 부르면 이미 새 값이다. 연달아 오는 알림은 한 번으로 모은다.
      invalidate();
      clearTimeout(statusTimer);
      statusTimer = setTimeout(() => { statusTimer = 0; status(true).then(st => fire('status', e, st)); }, 30);
    } else if (e.type === 'run' || e.type === 'digest') fire(e.type, e);
  }
  window.synapseAIEvent = function (e) {
    if (typeof e === 'string') { try { e = JSON.parse(e); } catch (_) { return; } }
    if (!e || typeof e !== 'object' || !e.type) return;
    if (!api) { if (early.length < 200) early.push(e); return; }
    dispatch(e);
  };
  function on(type, fn) {
    const set = subs[type];
    if (!set || typeof fn !== 'function') return () => {};
    set.add(fn);
    return () => { set.delete(fn); };
  }

  // ---------- 정리 ----------
  // aiDigest 응답을 화면이 한 모양으로 다루게 한다. 브리지가 실패하면 error 칸에 담아 돌려준다(예외를 던지지 않는다).
  async function digest(kind, o) {
    o = o || {};
    const p = { kind: String(kind), run: o.run === 'force' || o.run === 'auto' ? o.run : 'none' };
    if (o.offset != null) p.offset = Math.round(Number(o.offset) || 0);
    if (o.docId != null) p.docId = String(o.docId);
    if (o.auto === true) p.auto = true;   // v0.9 정리 계획: 화면이 열 때 자동으로 부르는 호출이라고 알린다 (run:"auto"와 같은 뜻)
    const r = await call('aiDigest', p);
    if (r.ok === false) {
      const msg = r.error || '정리를 불러오지 못했어요', nb = NO_BRIDGE.test(msg);
      return { ok: false, unsupported: nb, kind: p.kind, scope: null, digest: null, meta: null, state: 'missing', running: false, runId: null,
        blocked: nb ? 'unsupported' : null, error: { code: nb ? 'unsupported' : 'failed', message: msg, at: Date.now() / 1000 } };
    }
    return Object.assign({ kind: p.kind, scope: null, digest: null, meta: null, state: 'missing', running: false, runId: null, blocked: null, error: null }, r);
  }

  // ---------- 시각·모델 문구 ----------
  const MODEL = { sonnet: 'Sonnet', opus: 'Opus', haiku: 'Haiku' };
  function whenLabel(ms) {
    const d = new Date(ms); if (isNaN(d)) return '';
    const day = x => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
    const diff = Math.round((day(new Date()) - day(d)) / 864e5), t = P2(d.getHours()) + ':' + P2(d.getMinutes());
    return diff === 0 ? '오늘 ' + t : diff === 1 ? '어제 ' + t : (d.getMonth() + 1) + '/' + d.getDate() + ' ' + t;
  }
  function durLabel(ms) {
    const s = Math.max(1, Math.round((Number(ms) || 0) / 1000));
    return s < 60 ? s + '초' : Math.floor(s / 60) + '분' + (s % 60 ? ' ' + (s % 60) + '초' : '');
  }
  // "오늘 17:52 · Sonnet · 12초"
  function metaLabel(meta) {
    if (!meta || typeof meta !== 'object') return '';
    const when = meta.createdLabel || (meta.created ? whenLabel(Number(meta.created) * 1000) : '');
    const model = meta.model ? (MODEL[String(meta.model).toLowerCase()] || String(meta.model)) : '';
    return [when, model, meta.durationMs ? durLabel(meta.durationMs) : ''].filter(Boolean).join(' · ');
  }
  // 정리 카드 맨 아래 한 줄: 시각·모델·걸린 시간 + 다시 정리 버튼(data-ai-act="regen"). opts: {stale, busy, regen:false}
  function metaHTML(meta, E, opts) {
    opts = opts || {}; E = escOf(E);
    const label = metaLabel(meta);
    if (!label && opts.regen === false) return '';
    return '<div class="ai-meta">' + ic('sparkle') + '<span class="ai-meta-t">' + E(label || 'Claude 정리') + '</span>' +
      (opts.stale ? '<span class="ai-meta-flag" title="정리한 뒤에 자료가 바뀌었어요">그 사이 바뀐 게 있어요</span>' : '') +
      (opts.regen === false ? '' : '<button type="button" class="ai-regen" data-ai-act="regen"' + (opts.busy ? ' disabled' : '') + '>' + ic('refresh') + '<span>' + (opts.busy ? '정리하는 중' : '다시 정리') + '</span></button>') + '</div>';
  }

  // ---------- 참조 칩 ----------
  // 티켓은 키(PROJ-123), 그 밖은 제목 앞 20자. docId가 없으면 눌리지 않는 칩.
  function refLabel(r) {
    if (r.key) return String(r.key);
    const t = String(r.title || r.ref || '').replace(/\s+/g, ' ').trim(), a = Array.from(t);
    return a.length > 20 ? a.slice(0, 20).join('') + '…' : t;
  }
  const isTicketRef = r => !!r.key || r.kind === 'issue' || r.kind === 'ticket';
  // 같은 것을 가리키는 칩은 하나만: 같은 문서(docId)거나, 티켓 칩과 "PROJ-12 · …" 이름의 흐름 칩처럼 키가 같은 것
  const KEY_HEAD = /^([A-Z][A-Z0-9_]+-\d+)(?:\s|·|:|$)/;
  function uniqueRefs(list) {
    const keys = new Set(list.filter(r => r.key).map(r => String(r.key)));
    const seen = new Set();
    return list.filter(r => {
      if (!r.key && r.kind === 'thread') { const m = KEY_HEAD.exec(String(r.title || '')); if (m && keys.has(m[1])) return false; }
      const id = r.docId != null && r.docId !== '' ? 'd:' + r.docId : (r.key ? 'k:' + r.key : '');
      if (!id) return true;
      if (seen.has(id)) return false;
      seen.add(id); return true;
    });
  }
  function refsHTML(refs, E) {
    E = escOf(E);
    const list = uniqueRefs(Array.isArray(refs) ? refs.filter(r => r && typeof r === 'object') : []);
    return list.map(r => {
      const label = refLabel(r); if (!label) return '';
      const kind = isTicketRef(r) ? 'ticket' : (r.kind || 'doc');
      const tip = r.key && r.title ? r.key + ' · ' + r.title : (r.title || label);
      const base = ' data-kind="' + E(kind) + '" title="' + E(tip) + '"';
      if (r.docId == null || r.docId === '') return '<span class="ai-ref is-static"' + base + '>' + E(label) + '</span>';
      return '<button type="button" class="ai-ref"' + base + ' data-ai-doc="' + E(r.docId) + '"' + (r.line != null && r.line !== '' ? ' data-ai-line="' + E(r.line) + '"' : '') + ' aria-label="' + E(tip + ' 열기') + '">' + E(label) + '</button>';
    }).join('');
  }
  function openRef(docId, line) {
    if (!api || docId == null || docId === '') return;
    const n = line == null || line === '' ? NaN : Number(line);
    api.openDoc(String(docId), isFinite(n) ? n : undefined);
  }
  // 칩 클릭 → 문서 열기. 한 영역에 한 번만 묶는다(다시 불러도 겹치지 않는다).
  function bindRefs(root) {
    if (!root || root.__aiRefs) return;
    root.__aiRefs = true;
    root.addEventListener('click', e => {
      const b = e.target && e.target.closest ? e.target.closest('[data-ai-doc]') : null;
      if (!b || !root.contains(b) || b.disabled) return;
      e.preventDefault();
      openRef(b.getAttribute('data-ai-doc'), b.getAttribute('data-ai-line'));
    });
  }

  // ---------- 상태 칩 · 항목 아이콘 ----------
  const STATE_LABEL = { done: '완료', doing: '진행 중', hold: '보류', planned: '예정', todo: '예정', mixed: '일부 진행' };
  const STATE_GROUP = { done: 'done', doing: 'doing', hold: 'blocked', planned: 'todo', todo: 'todo', mixed: null };
  function stateChipHTML(state, E) {
    E = escOf(E);
    const s = STATE_LABEL[state] ? state : 'mixed';
    return '<span class="ai-state" data-s="' + E(s) + '">' + E(STATE_LABEL[s]) + '</span>';
  }
  // 줄 앞 모양 — 티켓 상태 모양(cluster.js)을 그대로 써서 색만으로 구분하지 않는다
  function itemIconHTML(state) {
    const g = STATE_GROUP[state] || 'todo', C = window.SynapseCluster;
    const shape = C && typeof C.shapeHtml === 'function' ? C.shapeHtml(g) : '<i class="ai-dot"></i>';
    return '<span class="ai-item-ic" data-s="' + (STATE_LABEL[state] ? state : 'todo') + '" aria-hidden="true">' + shape + '</span>';
  }
  // 뼈대 로딩: 줄 길이는 고정(깜빡이지 않게). 스크린리더에는 숨긴다.
  function skeletonHTML(rows) {
    const w = [92, 64, 78, 48, 86, 58, 70], n = Math.max(1, Math.min(7, rows || 4));
    let h = '<div class="ai-skel" aria-hidden="true"><i class="ai-skel-h"></i>';
    for (let i = 0; i < n; i++) h += '<i style="width:' + w[i % w.length] + '%"></i>';
    return h + '</div>';
  }

  // ---------- 안내 띠 ----------
  const WORD = { week: '이번 주를', tickets: '티켓을', home: '오늘 할 일을', doc: '이 문서를', tidy: '정리 계획을' };
  const MSG = {
    disabled: 'Claude 정리가 꺼져 있어요. 설정에서 켜면 이 화면을 Claude가 읽고 정리해 줘요.',
    missing: 'Claude Code를 찾지 못했어요. 설치했다면 설정에서 경로를 골라 주세요.',
    login: 'Claude Code 로그인이 필요해요. 터미널에서 claude를 실행해 /login 해 주세요.',
    limit: 'Claude 사용 한도에 닿았어요. 한도가 풀리면 다시 시도해 주세요.',
    network: '인터넷 연결을 확인해 주세요.',
    timeout: '시간이 너무 오래 걸려 멈췄어요.',
    bad_output: 'Claude 답을 읽지 못했어요. 다시 정리해 보세요.',
    failed: 'Claude 실행이 실패했어요.',
    manual: '자동 정리가 꺼져 있어요. 필요할 때 지금 정리할 수 있어요.',
    cap: '오늘 자동으로 정리할 수 있는 횟수를 다 썼어요. 지금 정리는 계속 쓸 수 있어요.',
    unsupported: '이 화면에서는 Claude 정리를 쓸 수 없어요.',
  };
  // res: aiDigest 응답(또는 aiStatus). 안내가 필요 없으면 ''.
  function noticeInfo(res) {
    if (!res || typeof res !== 'object') return null;
    const err = res.error && typeof res.error === 'object' ? res.error : null;
    const code = err ? err.code : null, b = res.blocked;
    const hasOld = !!res.digest;
    let key = null;
    if (res.unsupported || b === 'unsupported' || code === 'unsupported') key = 'unsupported';
    else if (res.running === true) key = 'running';
    else if (b === 'disabled' || res.enabled === false) key = 'disabled';
    else if (b === 'unavailable' || (res.claude && res.claude.found === false)) key = 'missing';
    else if (b === 'login' || code === 'login' || (res.claude && res.claude.login === 'needed')) key = 'login';
    else if (b === 'limit' || code === 'limit') key = 'limit';
    else if (code && MSG[code]) key = code === 'missing' ? 'missing' : code;
    else if (code) key = 'failed';
    else if (b === 'manual' && !hasOld) key = 'manual';
    else if (b === 'cap' && !hasOld) key = 'cap';
    if (!key) return null;
    const lead = hasOld && key !== 'running' && key !== 'disabled' && key !== 'missing' && key !== 'unsupported' ? ' 이전 정리를 보여 줘요.' : '';
    if (key === 'running') return { key, tone: 'run', text: 'Claude가 ' + (res.what || WORD[res.kind] || '내용을') + ' 읽고 있어요…', acts: [] };   // res.what: 화면이 "지난주를"처럼 직접 넣을 수 있다
    let text = String((err && err.message) || MSG[key] || MSG.failed).trim();
    if (lead) text = (/[.!?。]$/.test(text) ? text : text + '.') + lead;   // 이전 정리를 보여 준다는 말은 문장이 끝난 뒤에
    const tone = key === 'disabled' || key === 'unsupported' || key === 'manual' || key === 'cap' ? 'info' : key === 'bad_output' || key === 'failed' ? 'error' : 'warn';
    const acts = key === 'disabled' || key === 'missing' ? ['settings']
      : key === 'login' ? ['retry', 'settings'] : key === 'unsupported' ? []
      : key === 'manual' || key === 'cap' ? ['run'] : ['retry'];
    return { key, tone, text, acts };
  }
  const ACT = { settings: ['settings', '설정 열기'], retry: ['retry', '다시 시도'], run: ['retry', '지금 정리하기'] };
  function noticeHTML(res, E) {
    const n = noticeInfo(res); if (!n) return '';
    E = escOf(E);
    const lead = n.tone === 'run' ? '<i class="spinner" aria-hidden="true"></i>' : ic(n.tone === 'info' ? 'info' : 'alert');
    const acts = n.acts.map(a => '<button type="button" class="btn sm" data-ai-act="' + ACT[a][0] + '">' + E(ACT[a][1]) + '</button>').join('');
    return '<div class="ai-notice is-' + n.tone + '" data-ai-notice="' + E(n.key) + '" role="' + (n.tone === 'error' || n.tone === 'warn' ? 'alert' : 'status') + '">' +
      '<span class="ai-notice-ic">' + lead + '</span><span class="ai-notice-t">' + E(n.text) + '</span>' + (acts ? '<span class="ai-notice-b">' + acts + '</span>' : '') + '</div>';
  }

  // ---------- 복사 ----------
  // 서식(HTML)과 글자를 함께 복사한다(copyRich). 안 되면 글자만(api.copyText — 그것도 안 되면 onFail). 어느 쪽이든 알림은 여기서 낸다.
  // opts: {ok: 서식 복사 성공 알림, plain: 글자만 복사 알림, onFail(text): 글자 복사도 안 될 때}  → Promise<'rich'|'plain'> (plain은 글자 복사를 시도했다는 뜻)
  async function copyReport(text, html, opts) {
    opts = opts || {};
    const t = String(text == null ? '' : text);
    if (!api) return 'plain';
    if (html && window.__synapseCopyFail !== true) {   // __synapseCopyFail: 시험용 — 복사 실패 경로를 흉내 낸다 (app.js copyText와 같은 스위치)
      const r = await call('copyRich', { text: t, html: String(html) });
      if (r.ok === true) { api.toast(opts.ok || '복사했어요 · 붙여 넣으면 글머리표가 그대로 살아요'); return 'rich'; }
    }
    api.copyText(t, opts.plain || '글자만 복사했어요 · 서식은 붙지 않아요', typeof opts.onFail === 'function' ? opts.onFail : undefined);
    return 'plain';
  }

  window.SynapseAI = Object.freeze({ init, status, cached, on, digest, refsHTML, bindRefs, metaLabel, noticeHTML, copyReport,
    openRef, metaHTML, stateChipHTML, itemIconHTML, skeletonHTML });
})();
