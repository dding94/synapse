// aipanel.js — Synapse v0.8 "Claude에게 시키기" 패널 ⌘J (docs/V08.md §8.4)와 U2 화면 조각(§8.5): 홈 브리핑 · 리더 문서 요약 · 설정의 Claude 구역.
// window.SynapseAIPanel 하나만 만든다.
//   패널: init(api) · open({preset?, prompt?}) · close() · toggle() · isOpen() · onKey(e) → bool · onChange(fn) · busy()
//   조각: homeBrief(res, ui) → {html, rows} | null · docSummary(entry, docId, ui) → html · renderSettings(el) · refreshSettings()
// api = app.js의 brainApi (call · esc · toast · openDoc · setMode · copyText · editingDocId · icon)
//       + v0.8: context() · copyInstruction() · openSettings() · showDigest(kind, scope) · refreshAI()
// SynapseAI(src/ai.js)가 없거나 메서드가 빠져 있어도 깨지지 않는다: 상태·정리·실행은 브리지를 직접 부르고, 이벤트가 없으면 가끔 다시 읽는다.
(function () {
  'use strict';

  // ===========================================================================
  // 공용
  const ESC_MAP = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
  const E = v => String(v == null ? '' : v).replace(/[&<>"']/g, c => ESC_MAP[c]);
  const ic = n => '<svg class="icon" aria-hidden="true"><use href="#i-' + n + '"/></svg>';
  const P2 = n => String(n).padStart(2, '0');
  const A = () => window.SynapseAI || null;
  let api = null;
  const toast = (m, tone, ms) => { try { api.toast(m, tone, ms); } catch (_) { /* 알림을 못 띄워도 괜찮다 */ } };
  // 브리지 호출: 실패도 {ok:false, error}로 돌려준다
  async function call(method, params) {
    try { const r = await api.call(method, params || {}); return r && typeof r === 'object' ? r : { ok: false, error: '응답을 읽지 못했어요' }; }
    catch (e) { return { ok: false, error: (e && e.message) || '처리하지 못했어요' }; }
  }
  // 시각(초 또는 밀리초) → "오늘 17:52" · "어제 17:52" · "10/24 17:52"
  function whenLabel(t) {
    t = Number(t);
    if (!t) return '';
    const d = new Date(t > 1e12 ? t : t * 1000), n = new Date();
    const day = x => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
    const diff = Math.round((day(n) - day(d)) / 864e5), hm = P2(d.getHours()) + ':' + P2(d.getMinutes());
    return diff === 0 ? '오늘 ' + hm : diff === 1 ? '어제 ' + hm : (d.getMonth() + 1) + '/' + d.getDate() + ' ' + hm;
  }
  function durLabel(ms) {
    const s = Math.round((Number(ms) || 0) / 1000);
    if (s < 1) return '1초 미만';
    if (s < 60) return s + '초';
    return Math.floor(s / 60) + '분' + (s % 60 ? ' ' + (s % 60) + '초' : '');
  }
  const modelLabel = m => { const k = String(m || '').toLowerCase(); return k.includes('sonnet') ? 'Sonnet' : k.includes('opus') ? 'Opus' : k.includes('haiku') ? 'Haiku' : String(m || ''); };
  const cut = (s, n) => { s = String(s == null ? '' : s).replace(/\s+/g, ' ').trim(); return s.length > n ? s.slice(0, n - 1) + '…' : s; };
  // innerHTML을 바꿔야 할 때만 바꾼다(포커스·선택·스크롤을 덜 흔든다)
  function setHTML(node, html) { if (node && node.__h !== html) { node.__h = html; node.innerHTML = html; return true; } return false; }
  // 다시 그려도 키보드 포커스를 잃지 않게: 포커스 요소의 data-* 로 찾아 되돌린다 (입력칸은 건드리지 않는다)
  function withFocus(box, fn) {
    const a = document.activeElement; let q = '';
    if (a && box && a !== box && box.contains(a) && a.tagName !== 'TEXTAREA' && a.tagName !== 'INPUT') {
      for (const at of Array.from(a.attributes)) if (at.name.indexOf('data-') === 0) q += '[' + at.name + '="' + String(at.value).replace(/["\\]/g, '\\$&') + '"]';
      if (q) q = a.tagName.toLowerCase() + q;
    }
    fn();
    if (q) { const n = box.querySelector(q); if (n && !n.disabled) n.focus({ preventScroll: true }); }
  }
  // 스프라이트에 없는 아이콘 한 개 (멈추기)
  function injectSymbols() {
    const defs = document.querySelector('svg.sprite defs');
    if (!defs || defs.querySelector('#i-stop')) return;
    defs.insertAdjacentHTML('beforeend', '<symbol id="i-stop" viewBox="0 0 24 24"><rect x="7.25" y="7.25" width="9.5" height="9.5" rx="2.2"/></symbol>');
  }

  // ===========================================================================
  // Claude 상태 (aiStatus). SynapseAI 캐시에 기대지 않고 브리지를 직접 읽는다.
  let status = null, statusErr = '', statusLoaded = false, statusSeq = 0;
  // "알 수 없는 method" 같은 옛 앱의 답은 사람이 읽을 글이 아니다 → 비워 두고 안내 글을 쓴다
  const NO_BRIDGE = /알 수 없는 method|unknown method|not supported|지원하지 않|준비되지 않/i;
  const bridgeErr = e => (NO_BRIDGE.test(String(e || '')) ? '' : String(e || ''));
  function loadStatus() {
    const my = ++statusSeq;
    return call('aiStatus').then(r => {
      if (my !== statusSeq) return status;
      statusLoaded = true;
      if (r && r.ok !== false) { status = r; statusErr = ''; } else { status = null; statusErr = bridgeErr(r && r.error); }
      return status;
    });
  }
  const usable = () => !!(status && status.available);
  const taskRunning = () => (status && Array.isArray(status.running) ? status.running.find(x => x && x.kind === 'task') : null) || null;
  // 쓸 수 없는 까닭 → 안내 글
  function whyNot() {
    if (!statusLoaded) return { t: 'Claude 연결을 확인하는 중이에요', d: '' };
    if (!status) return { t: 'Claude 연결을 쓸 수 없어요', d: statusErr || '이 Synapse에는 Claude 연결이 없어요. 새 버전 앱에서 쓸 수 있어요(브라우저 미리보기에서는 쓸 수 없어요).', settings: false };
    if (!status.enabled) return { t: 'Claude 연결이 꺼져 있어요', d: '설정에서 “Claude로 정리하기”를 켜면 쓸 수 있어요.', settings: true };
    const c = status.claude || {};
    if (!c.found) return { t: 'Claude Code를 찾지 못했어요', d: '설치했다면 설정에서 경로를 골라 주세요. 아직 없다면 설치한 뒤 터미널에서 claude를 한 번 실행해 로그인해 주세요.', settings: true };
    if (c.login === 'needed') return { t: 'Claude Code 로그인이 필요해요', d: '터미널에서 claude를 실행해 /login 해 주세요.', settings: true };
    return { t: 'Claude를 쓸 수 없어요', d: c.error ? String(c.error) : '설정에서 연결 시험을 해 보세요.', settings: true };
  }

  // 정리(digest) 읽기: SynapseAI.digest가 있으면 그것을, 없으면 브리지를 직접 부른다
  function digestCall(kind, o) {
    o = o || {};
    const a = A();
    if (a && typeof a.digest === 'function') return Promise.resolve().then(() => a.digest(kind, o)).then(r => r, e => ({ ok: false, error: (e && e.message) || '' }));
    const p = { kind, run: o.run || 'none' };
    if (o.offset != null) p.offset = o.offset;
    if (o.docId != null) p.docId = o.docId;
    return call('aiDigest', p);
  }
  // 참조 칩: SynapseAI가 그리고, 없으면 같은 모양을 직접 그린다
  function refsHTML(refs) {
    const a = A();
    if (a && typeof a.refsHTML === 'function') { try { return a.refsHTML(refs, E) || ''; } catch (_) { /* 아래 대체 */ } }
    const list = (Array.isArray(refs) ? refs : []).filter(r => r && r.docId != null).slice(0, 4);
    return list.map(r => '<button type="button" class="ai-ref" data-ai-doc="' + E(r.docId) + '"' + (r.line != null ? ' data-ai-line="' + E(r.line) + '"' : '') + ' title="' + E(r.title || '') + '">' + E(r.key || cut(r.title, 18) || '문서') + '</button>').join('');
  }
  function bindRefs(rootEl) {
    if (!rootEl) return;
    const a = A();
    if (a && typeof a.bindRefs === 'function') { try { a.bindRefs(rootEl); return; } catch (_) { /* 아래 대체 */ } }
    if (rootEl.__apRefs) return;
    rootEl.__apRefs = true;
    rootEl.addEventListener('click', e => {
      const b = e.target.closest && e.target.closest('[data-ai-doc]');
      if (b && rootEl.contains(b)) { e.preventDefault(); try { api.openDoc(b.dataset.aiDoc, b.dataset.aiLine); } catch (_) { /* 무시 */ } }
    });
  }
  function metaLabel(meta) {
    const a = A();
    if (a && typeof a.metaLabel === 'function') { try { const s = a.metaLabel(meta); if (s) return String(s); } catch (_) { /* 아래 대체 */ } }
    if (!meta) return '';
    return [whenLabel(meta.created), modelLabel(meta.model), meta.durationMs ? durLabel(meta.durationMs) : ''].filter(Boolean).join(' · ');
  }
  // 정리 응답이 못 돌았거나 실패했을 때의 안내 띠 (SynapseAI.noticeHTML이 우선)
  const BLOCKED = { disabled: 'Claude 연결이 꺼져 있어요', unavailable: 'Claude Code를 찾지 못했어요', login: 'Claude Code 로그인이 필요해요', limit: 'Claude 사용 한도에 닿았어요', cooldown: '조금 있다가 다시 정리해요', cap: '오늘 자동 정리 횟수를 다 썼어요', manual: '버튼을 눌러야 정리해요' };
  function noticeHTML(res) {
    const a = A();
    if (a && typeof a.noticeHTML === 'function') { try { const h = a.noticeHTML(res, E); if (h) return h; } catch (_) { /* 아래 대체 */ } }
    if (!res) return '';
    const msg = res.error && res.error.message ? res.error.message : res.blocked ? BLOCKED[res.blocked] || '' : '';
    if (!msg) return '';
    const settings = res.blocked === 'disabled' || res.blocked === 'unavailable' || res.blocked === 'login' || (res.error && /^(login|missing)$/.test(res.error.code || ''));
    return '<div class="ap-note" role="status">' + ic('info') + '<span>' + E(msg) + '</span>' +
      (settings ? '<button type="button" class="link-btn" data-ai-act="settings">설정 열기</button>' : '') +
      (res.error ? '<button type="button" class="link-btn" data-ai-act="retry">다시 시도</button>' : '') + '</div>';
  }

  // ===========================================================================
  // 시키기 패널
  const S = {
    open: false, view: 'new',      // view: 'new' = 입력 + 빠른 작업 + 기록 · 'run' = 한 실행(실행 중·끝남)
    run: null,                     // 보고 있는 실행 { runId, status, title, prompt, preset, steps[], answer, proposals[], model, turns, durationMs, started, error }
    runs: null, runsErr: '',       // 최근 실행 목록
    starting: false, preset: null, // preset: ⌘⇧K 등으로 미리 골라 둔 빠른 작업
    useDoc: true, ctx: { mode: '', docId: null, docTitle: '' },
    busy: Object.create(null),     // 제안 카드 id → 처리 중
    decided: Object.create(null),  // 제안 카드 id → { state, srv } 내가 방금 정한 상태(applied·rejected)와 그때 서버가 알려 준 상태. 서버 기록이 바뀌면(따라오면) 버리고 서버 것을 쓴다
    edits: Object.create(null),    // 제안 카드 id → { body?, to? } (고친 값)
    editing: null, stepsOpen: null,
  };
  let root = null, ta = null, X = {}, lastFocus = null, scrollKeep = 0;
  let stick = true, renderTimer = 0, refreshTimer = 0, pollTimer = 0, cardsDirty = false;
  const changeFns = [];
  let offFns = [];

  const isRunning = () => !!(S.run && S.run.status === 'running');
  const presets = () => (status && Array.isArray(status.presets) ? status.presets : []).filter(p => p && p.id && p.title && (p.needs !== 'doc' || !!S.ctx.docId));
  const PRESET_ICON = { organize: 'inbox', 'ticket-cleanup': 'ticket', week: 'calendar', tickets: 'ticket', 'doc-summary': 'doc', home: 'home' };
  const TOOL_ICON = { search_notes: 'search', get_note: 'doc', related_notes: 'follow', recent_notes: 'clock', list_sources: 'stack', get_work_context: 'calendar', get_vault_policy: 'sliders', list_pending: 'inbox', suggest_location: 'folder', get_tickets: 'ticket', propose_changes: 'move', propose_jira_changes: 'ticket' };
  const STATUS_LABEL = { loading: '불러오는 중', running: '일하는 중', done: '끝났어요', error: '실패했어요', cancelled: '멈췄어요' };
  const fireChange = () => changeFns.slice().forEach(fn => { try { fn(S.open); } catch (_) { /* 무시 */ } });

  function syncCtx() {
    let c = null;
    try { c = api && typeof api.context === 'function' ? api.context() : null; } catch (_) { c = null; }
    S.ctx = { mode: (c && c.mode) || '', docId: c && c.docId != null ? String(c.docId) : null, docTitle: (c && c.docTitle) || '' };
  }

  function ensureBuilt() {
    if (root) return;
    injectSymbols();
    root = document.createElement('aside');
    root.className = 'ap';
    root.id = 'ap-root';
    root.setAttribute('role', 'dialog');
    root.setAttribute('aria-modal', 'false');
    root.setAttribute('aria-labelledby', 'ap-title');
    root.hidden = true;
    root.tabIndex = -1;   // 빈 곳을 눌러도 포커스가 패널 안에 남게(키가 패널로 간다)
    root.innerHTML =
      '<header class="ap-head"><div class="ap-head-t"><h2 class="ap-title" id="ap-title">Claude에게 시키기</h2><p class="ap-sub" data-r="sub"></p></div>' +
        '<button class="icon-btn sm" type="button" data-ap="close" title="닫기 · esc" aria-label="닫기">' + ic('x') + '</button></header>' +
      '<div class="ap-compose" data-r="compose">' +
        '<textarea class="ap-input" id="ap-input" rows="3" aria-label="Claude에게 시킬 일" placeholder="시킬 일을 적어 주세요 · 예: 쿠폰 정책 관련 결정만 모아서 요약해 줘" spellcheck="false" autocomplete="off" autocapitalize="off" autocorrect="off"></textarea>' +
        '<div class="ap-compose-row"><div class="ap-ctx" data-r="ctx"></div><button class="btn sm primary ap-run-btn" type="button" data-ap="run" data-r="runbtn"></button></div></div>' +
      '<div class="ap-scroll" data-r="scroll">' +
        '<div data-r="notice"></div><div data-r="result"></div><div data-r="quick"></div><div data-r="hist"></div></div>' +
      '<footer class="ap-foot">' + ic('info') + '<span>사용량은 내 Claude 요금제에서 나가요. 파일 이동·삭제와 Jira 변경은 제안만 하고, 여기서 승인해야 적용돼요.</span></footer>';
    document.body.appendChild(root);
    ta = root.querySelector('.ap-input');
    root.querySelectorAll('[data-r]').forEach(n => { X[n.dataset.r] = n; });
    root.addEventListener('click', onClick);
    // 단추를 눌러도 WKWebView는 단추에 포커스를 주지 않는다 → 패널 안에 포커스를 붙들어 ⌘↵·⌘.·esc가 패널로 가게 한다
    root.addEventListener('click', () => setTimeout(keepFocusInside, 0));
    root.addEventListener('focusin', () => { if (S.open) { const was = S.ctx.docId; syncCtx(); if (was !== S.ctx.docId) { renderCtx(); renderQuick(); } } });
    ta.addEventListener('input', () => { autosize(); if (S.preset) { S.preset = null; renderQuick(); } });   // 직접 쓰기 시작하면 미리 골라 둔 빠른 작업은 푼다
    // 한글 조합 중 ⌘↵: 글자가 확정된 뒤에 시킨다(조합 중에는 키를 가로채지 않는다)
    let pendRun = false;
    ta.addEventListener('keydown', e => { if ((e.isComposing || e.keyCode === 229) && e.metaKey && !e.ctrlKey && !e.altKey && !e.shiftKey && (e.key === 'Enter' || e.code === 'Enter')) pendRun = true; });
    ta.addEventListener('compositionend', () => { if (pendRun) { pendRun = false; setTimeout(primaryAction, 0); } });
    ta.addEventListener('blur', () => { pendRun = false; });
    X.scroll.addEventListener('scroll', () => { stick = X.scroll.scrollTop + X.scroll.clientHeight >= X.scroll.scrollHeight - 28; }, { passive: true });
    subscribe();
  }
  function keepFocusInside() {
    if (!S.open || !root) return;
    const a = document.activeElement;
    if (!a || a === document.body || a === document.documentElement || (root.contains(a) && (a.disabled || !a.isConnected))) root.focus({ preventScroll: true });
  }
  function autosize() { if (!ta) return; ta.style.height = 'auto'; ta.style.height = Math.min(Math.max(ta.scrollHeight, 66), 168) + 'px'; }

  // 실행·상태 이벤트: SynapseAI가 있으면 그것으로, 없으면 아래 poll로 따라간다
  function subscribe() {
    const a = A();
    if (!a || typeof a.on !== 'function') return;
    const after = () => { if (S.open) { attachRunning(); renderAll(); } if (settingsVisible()) paintSettings(); fireChange(); };
    try {
      offFns.push(a.on('run', onRunEvent));
      // ai.js는 상태를 새로 읽은 뒤 두 번째 인자로 넘겨 준다. 없으면 직접 읽는다.
      offFns.push(a.on('status', (e, st) => {
        if (st && typeof st === 'object') { statusSeq++; statusLoaded = true; if (st.ok === false) { status = null; statusErr = bridgeErr(st.error); } else { status = st; statusErr = ''; } after(); }
        else loadStatus().then(after);
      }));
    } catch (_) { offFns = []; }
  }
  const hasEvents = () => offFns.length > 0;

  function init(a) {
    api = a;
    ensureBuilt();
  }

  // ---------- 열기 · 닫기 ----------
  function open(opts) {
    if (!api) return false;
    opts = opts || {};
    ensureBuilt();
    if (!S.open) {
      lastFocus = document.activeElement;
      S.open = true;
      root.hidden = false;
      void root.offsetWidth;
      root.classList.add('visible');
      if (scrollKeep) X.scroll.scrollTop = scrollKeep;
    }
    syncCtx();
    if (typeof opts.prompt === 'string') { ta.value = opts.prompt; autosize(); }
    S.preset = opts.preset ? String(opts.preset) : null;
    if (S.preset && !isRunning()) S.view = 'new';
    const first = !statusLoaded;
    renderAll();
    if (!first) focusInitial();
    fireChange();
    loadStatus().then(() => {
      if (!S.open) return;
      attachRunning();
      renderAll();
      if (first || !root.contains(document.activeElement)) focusInitial();
    });
    loadRuns();
    return true;
  }
  function close(keepFocus) {
    if (!S.open || !root) return;
    S.open = false;
    scrollKeep = X.scroll.scrollTop;
    root.classList.remove('visible');
    const r = root;
    setTimeout(() => { if (!S.open) r.hidden = true; }, 170);
    const back = lastFocus; lastFocus = null;
    if (!keepFocus && back && back.isConnected && back !== document.body && back.focus) { try { back.focus({ preventScroll: true }); } catch (_) { /* 무시 */ } }
    fireChange();
  }
  const toggle = () => { if (S.open) close(); else open(); return S.open; };
  const isOpen = () => S.open;
  const busy = () => isRunning() || !!taskRunning();
  function onChange(fn) { if (typeof fn === 'function') changeFns.push(fn); }

  function focusInitial() {
    if (!S.open || !root) return;
    let t = null;
    if (!usable()) t = root.querySelector('.ap-notice [data-ap], [data-ap="close"]');
    else if (S.preset) t = root.querySelector('.ap-q[data-id="' + String(S.preset).replace(/["\\]/g, '\\$&') + '"]');
    if (!t && usable() && !ta.disabled && S.view === 'new') t = ta;
    if (!t && usable() && !isRunning() && !ta.disabled) t = ta;
    if (!t) t = X.runbtn && !X.runbtn.disabled ? X.runbtn : root.querySelector('[data-ap="close"]');
    if (t && t.focus) t.focus({ preventScroll: true });
  }

  // ---------- 그리기 ----------
  function renderAll() {
    if (!root) return;
    renderSub(); renderCompose(); renderNotice(); renderResult(); renderQuick(); renderHist();
  }
  function renderSub() {
    const m = status && status.models ? modelLabel(status.models.task) : '';
    setHTML(X.sub, usable() ? E((m ? m + '로 ' : '') + '일해요 · 파일과 Jira는 제안만 해요') : E(statusLoaded ? '지금은 쓸 수 없어요' : '연결을 확인하는 중…'));
  }
  function renderCompose() {
    const ok = usable(), running = isRunning();
    X.compose.hidden = !ok;
    if (ta) ta.disabled = running || S.starting;
    const html = running ? ic('stop') + '<span>멈추기</span><kbd>⌘.</kbd>' : S.starting ? '<i class="spinner"></i><span>시작하는 중…</span>' : ic('sparkle') + '<span>시키기</span><kbd>⌘↵</kbd>';
    setHTML(X.runbtn, html);
    X.runbtn.classList.toggle('danger', running);
    X.runbtn.classList.toggle('primary', !running);
    X.runbtn.setAttribute('aria-busy', String(S.starting));
    X.runbtn.title = running ? '멈추기 · ⌘.' : '시키기 · ⌘↵';
    renderCtx();
  }
  function renderCtx() {
    const d = S.ctx.docId;
    setHTML(X.ctx, d ? '<button type="button" class="ap-ctx-chip" data-ap="ctxdoc" aria-pressed="' + S.useDoc + '" title="켜 두면 Claude가 열려 있는 문서를 알고 시작해요">' + ic('doc') +
      '<span class="ap-ctx-t">' + E(S.ctx.docTitle || '열려 있는 문서') + '</span><i>' + (S.useDoc ? '함께 알려요' : '알리지 않아요') + '</i></button>' : '');
  }
  function renderNotice() {
    if (usable() || !statusLoaded) { setHTML(X.notice, statusLoaded ? '' : '<div class="ap-state"><i class="spinner"></i><span>Claude 연결을 확인하는 중이에요</span></div>'); return; }
    const w = whyNot();
    setHTML(X.notice, '<div class="ap-notice" role="status">' + ic('info') + '<div class="ap-notice-t"><b>' + E(w.t) + '</b><p>' + E(w.d) + '</p>' +
      '<div class="ap-notice-b">' + (w.settings ? '<button class="btn sm primary" type="button" data-ap="settings">설정 열기</button>' : '') +
      '<button class="btn sm" type="button" data-ap="copy-instr" title="Claude Code에 붙여 넣을 지시문을 복사해요">' + ic('copy') + '<span>지시문 복사</span></button></div>' +
      '<p class="ap-notice-h">Claude를 못 쓰는 동안에도 지시문을 복사해 Claude Code나 Codex에 붙여 넣을 수 있어요.</p></div></div>');
  }
  function renderQuick() {
    const node = X.quick;
    const list = S.view === 'new' && usable() ? presets() : [];
    const html = list.length ? '<section class="ap-sec" aria-labelledby="ap-qh"><h3 class="ap-h" id="ap-qh">빠른 작업</h3><div class="ap-quick" role="group" aria-label="빠른 작업">' + list.map(p =>
      '<button type="button" class="ap-q' + (S.preset === p.id ? ' is-rec' : '') + '" data-ap="preset" data-id="' + E(p.id) + '"' + (S.starting ? ' disabled' : '') + '>' +
      '<span class="ap-q-ic">' + ic(PRESET_ICON[p.id] || 'sparkle') + '</span><span class="ap-q-t"><b>' + E(p.title) + '</b>' + (p.hint ? '<small>' + E(p.hint) + '</small>' : '') + '</span>' +
      (S.preset === p.id ? '<span class="ap-q-go"><kbd>↵</kbd>시키기</span>' : '') + '</button>').join('') + '</div></section>' : '';
    withFocus(node, () => setHTML(node, html));
  }
  function renderHist() {
    const node = X.hist;
    let html = '';
    if (S.view === 'new') {
      const runs = S.runs || [];
      if (runs.length) {
        html = '<section class="ap-sec" aria-labelledby="ap-hh"><h3 class="ap-h" id="ap-hh">최근 실행 <span class="cnt">' + runs.length + '</span></h3><div class="ap-hist" role="group" aria-label="최근 실행">' + runs.map(r => {
          const st = String(r.status || '');
          const meta = [whenLabel(r.started), modelLabel(r.model), r.durationMs ? durLabel(r.durationMs) : (st === 'running' ? '일하는 중' : '')].filter(Boolean).join(' · ');
          return '<button type="button" class="ap-hr" data-ap="open-run" data-id="' + E(r.runId) + '"><span class="ap-hr-st is-' + E(st) + '" aria-label="' + E(STATUS_LABEL[st] || st) + '">' +
            (st === 'done' ? ic('check') : st === 'error' ? ic('alert') : st === 'cancelled' ? ic('pause') : '<i class="spinner"></i>') + '</span>' +
            '<span class="ap-hr-t">' + E(r.title || '제목 없음') + (r.kind === 'digest' ? '<i class="ap-hr-k">정리</i>' : '') + '</span><span class="ap-hr-m">' + E(meta) + '</span></button>';
        }).join('') + '</div></section>';
      } else if (S.runsErr) html = '<p class="ap-quiet">기록을 불러오지 못했어요 · ' + E(S.runsErr) + '</p>';
    }
    withFocus(node, () => setHTML(node, html));
  }

  // ----- 실행 화면 -----
  function ensureRunBox() {
    if (X.runbox && X.runbox.isConnected) return;
    X.result.innerHTML = '<div class="ap-run" data-r="runbox"><div class="ap-run-bar" data-r="bar"></div><div class="ap-ask" data-r="ask"></div><div class="ap-steps" data-r="steps"></div>' +
      '<div class="ap-ans-wrap" data-r="answ"><div class="ap-ans reader-body is-md" data-r="ans" tabindex="0" aria-label="Claude의 답"></div></div><div data-r="err"></div><div class="ap-props" data-r="props"></div><div class="ap-meta" data-r="meta"></div></div>';
    ['runbox', 'bar', 'ask', 'steps', 'answ', 'ans', 'err', 'props', 'meta'].forEach(k => { X[k] = X.result.querySelector('[data-r="' + k + '"]'); });
    X.ans.addEventListener('click', onAnswerClick);
    X.result.__h = null;
  }
  function renderResult() {
    if (!root) return;
    const run = S.run;
    if (S.view !== 'run' || !run) { if (X.runbox) { X.result.innerHTML = ''; X.runbox = null; X.result.__h = null; } return; }
    ensureRunBox();
    const running = run.status === 'running';
    setHTML(X.bar, '<button type="button" class="link-btn" data-ap="back">← 처음으로</button><span class="ap-pill is-' + E(run.status) + '" role="status">' +
      (running ? '<i class="spinner"></i>' : '') + E(STATUS_LABEL[run.status] || run.status) + '</span>');
    setHTML(X.ask, '<span class="ap-ask-l">시킨 일</span><p class="ap-ask-t">' + E(run.prompt || run.title || '') + '</p>');
    renderSteps();
    renderAnswer();
    const em = typeof run.error === 'string' ? run.error : run.error && run.error.message ? run.error.message : '';
    const err = run.status === 'error' || run.status === 'cancelled' ? em || (run.status === 'cancelled' ? '취소했어요.' : '실패했어요.') : '';
    setHTML(X.err, err ? '<div class="ap-err' + (run.status === 'cancelled' ? ' is-quiet' : '') + '" role="alert">' + ic(run.status === 'cancelled' ? 'pause' : 'alert') + '<span>' + E(err) + '</span></div>' : '');
    renderCards();
    const parts = [modelLabel(run.model), run.durationMs ? durLabel(run.durationMs) : '', run.turns ? run.turns + '턴' : '', run.started ? whenLabel(run.started) + ' 시작' : ''].filter(Boolean);
    const bs = [];
    if (!running && run.answer) bs.push('<button type="button" class="btn sm" data-ap="copy-answer">' + ic('copy') + '<span>답 복사</span></button>');
    if (!running && run.status !== 'loading') bs.push('<button type="button" class="btn sm" data-ap="again">' + ic('refresh') + '<span>다시 시키기</span></button>');
    setHTML(X.meta, (parts.length ? '<span class="ap-meta-t">' + E(parts.join(' · ')) + '</span>' : '') + (bs.length ? '<span class="ap-meta-b">' + bs.join('') + '</span>' : ''));
    stickBottom();
  }
  const stepsExpanded = () => (S.stepsOpen != null ? S.stepsOpen : isRunning());
  function renderSteps() {
    const run = S.run;
    const list = (run && Array.isArray(run.steps) ? run.steps : []).filter(s => s && s.kind !== 'text' && s.text);
    if (!list.length) { setHTML(X.steps, run && run.status === 'running' ? '<div class="ap-wait"><i class="spinner"></i><span>Claude가 시작하는 중이에요…</span></div>' : ''); return; }
    const open = stepsExpanded(), running = run.status === 'running';
    const li = list.map((s, i) => {
      const last = i === list.length - 1;
      const bad = s.kind === 'error' || s.ok === false, pend = running && last && s.kind === 'tool' && s.ok == null;
      const icon = bad ? ic('alert') : pend ? '<i class="spinner"></i>' : s.kind === 'info' ? ic('info') : ic(TOOL_ICON[s.tool] || 'check');
      return '<li class="ap-step' + (bad ? ' is-bad' : pend ? ' is-run' : '') + '"><span class="ap-step-ic">' + icon + '</span><span class="ap-step-t">' + E(s.text) + '</span></li>';
    }).join('');
    const lastT = list[list.length - 1].text;
    setHTML(X.steps, '<button type="button" class="ap-steps-h" data-ap="steps" aria-expanded="' + open + '"><span class="ap-caret" aria-hidden="true">' + ic(open ? 'hide' : 'next') + '</span><span>단계 ' + list.length + '개</span>' +
      (!open ? '<span class="ap-steps-last">' + E(lastT) + '</span>' : '') + '</button>' + (open ? '<ol class="ap-step-list" aria-label="진행 단계">' + li + '</ol>' : ''));
  }
  // 답: Claude가 단 [제목](synapse:doc/<id>) 링크는 문서 열기로 바꿔 그린다
  const DOC_LINK = /\[((?:[^\[\]\n]|\[[^\[\]\n]*\])+)\]\(\s*synapse:doc\/([^)\s#]+)(?:#L?(\d+))?\s*\)/g;
  function answerHTML(md) {
    md = String(md || '');
    const refs = [];
    const src = md.replace(DOC_LINK, (m, title, id, line) => {
      refs.push({ id, line: line ? Number(line) : null });
      return '[[syn' + (refs.length - 1) + '|' + (String(title).replace(/[\[\]|#]/g, ' ').replace(/\s+/g, ' ').trim() || id) + ']]';
    });
    const M = window.SynapseMarkdown;
    if (!M) return { html: '<p>' + E(md).replace(/\n/g, '<br>') + '</p>', refs };
    return { html: M.render(src, { resolve: t => { const m = /^syn(\d+)$/.exec(t); return m && refs[+m[1]] ? { id: refs[+m[1]].id } : undefined; } }), refs };
  }
  function renderAnswer() {
    const run = S.run, text = run ? String(run.answer || '') : '';
    X.answ.hidden = !text;
    if (!text) { X.ans.innerHTML = ''; X.ans.__src = ''; X.ans.__h = null; return; }
    if (X.ans.__src === text) return;
    X.ans.__src = text;
    const r = answerHTML(text);
    X.ans.innerHTML = r.html;
    X.ans.__h = null;
    X.ans.querySelectorAll('input.md-check').forEach(i => { i.disabled = true; });
    X.ans.querySelectorAll('.md-wiki[data-md-target^="syn"]').forEach(b => {
      const n = /^syn(\d+)$/.exec(b.dataset.mdTarget || '');
      if (n && r.refs[+n[1]] && r.refs[+n[1]].line != null) b.dataset.apLine = String(r.refs[+n[1]].line);
      b.title = '문서 열기';
    });
  }
  function stickBottom() { if (stick && isRunning() && X.scroll) X.scroll.scrollTop = X.scroll.scrollHeight; }
  function onAnswerClick(e) {
    const w = e.target.closest('.md-wiki');
    if (w) { e.preventDefault(); if (w.dataset.mdId) openDoc(w.dataset.mdId, w.dataset.apLine); else toast('문서를 찾지 못했어요'); return; }
    const x = e.target.closest('.md-ext');
    if (x) { e.preventDefault(); call('openURL', { url: x.dataset.mdUrl }).then(r => { if (r && r.ok === false) toast(r.error || '주소를 열지 못했어요', 'error'); }); }
  }
  // 문서를 열면 패널은 비켜 준다(오른쪽 리더를 가리지 않게). ⌘J로 답을 다시 볼 수 있다.
  function openDoc(id, line) {
    close(true);
    try { api.openDoc(id, line); } catch (_) { /* 무시 */ }
    toast('문서를 열었어요 · ⌘J로 Claude의 답을 다시 볼 수 있어요', '', 3200);
  }

  // ----- 제안 카드 (이 실행이 올린 것) -----
  const cardById = id => (S.run && Array.isArray(S.run.proposals) ? S.run.proposals : []).find(c => c && String(c.id) === String(id)) || null;
  const stOf = c => String(S.decided[c.id] ? S.decided[c.id].state : c.state || 'pending');
  const decide1 = (c, state) => { S.decided[c.id] = { state, srv: String(c.state || 'pending') }; };
  const ST_LABEL = { applying: '반영하는 중', applied: '적용했어요', rejected: '거절했어요', expired: '기한이 지났어요', failed: '실패했어요', later: '나중에 볼게요', withdrawn: '거두었어요' };
  function stChip(c) {
    const st = stOf(c);
    if (st === 'pending') return '';
    const label = st === 'applied' && c.kind === 'jira' ? '반영했어요' : ST_LABEL[st] || st;
    return '<span class="ap-card-st is-' + E(st) + '">' + (st === 'applying' ? '<i class="spinner"></i>' : '') + E(label) + '</span>';
  }
  const reasonsOf = c => (Array.isArray(c.reasons) ? c.reasons : c.reason ? [c.reason] : []).filter(Boolean).slice(0, 3);
  function editingBlock(c) {
    let id = null;
    try { id = typeof api.editingDocId === 'function' ? api.editingDocId() : null; } catch (_) { id = null; }
    return !!id && !!c && String(c.docId) === String(id);
  }
  function fileCardHTML(c) {
    const st = stOf(c), im = c.impact || {}, del = c.kind === 'delete', pend = st === 'pending', b = !!S.busy[c.id];
    const dest = del ? 'Synapse 휴지통 (30일 보관)' : c.to || '';
    const bad = !!im.conflict, lock = editingBlock(c), noTo = !del && !c.to;
    let h = '<div class="ap-card k-' + E(c.kind) + '" data-id="' + E(c.id) + '" data-state="' + E(st) + '">' +
      '<div class="ap-card-h">' + ic(del ? 'trash' : 'folder') + '<b class="ap-card-t" title="' + E(c.title) + '">' + E(c.title || c.docId || '문서') + '</b>' + stChip(c) + '</div>' +
      '<div class="ap-card-path"><span class="ap-from" title="' + E(c.from) + '">' + E(c.from || '') + '</span><span class="ap-to' + (dest ? '' : ' is-none') + '"><i>→</i>' + (dest ? E(dest) : '목적지는 정리함에서 골라요') + '</span></div>';
    const why = pend ? reasonsOf(c) : [];
    if (why.length) h += '<ul class="ap-card-why">' + why.map(x => '<li>' + E(x) + '</li>').join('') + '</ul>';
    if (!pend) return h + '</div>';
    if (del && im.inbound > 0) h += '<p class="ap-card-imp is-bad">이 문서를 가리키는 링크 ' + E(im.inbound) + '개가 끊겨요</p>';
    else if (!del && im.links > 0) h += '<p class="ap-card-imp">링크 ' + E(im.links) + '개를 고쳐요</p>';
    if (bad) h += '<p class="ap-card-imp is-bad">' + E(im.conflict) + '</p>';
    if (pend) {
      h += '<div class="ap-card-b">' +
        '<button type="button" class="btn sm ' + (del ? 'danger' : 'primary') + '" data-ap="approve" data-id="' + E(c.id) + '"' + (b || bad || lock || noTo ? ' disabled' : '') + '>' + (b ? '<i class="spinner"></i>' : '') + (del ? '휴지통으로' : '승인') + '</button>' +
        '<button type="button" class="btn sm" data-ap="reject" data-id="' + E(c.id) + '"' + (b ? ' disabled' : '') + '>거절</button>' +
        (c.docId ? '<button type="button" class="link-btn" data-ap="open-doc" data-doc="' + E(c.docId) + '">문서 보기</button>' : '') + '</div>';
      if (lock) h += '<p class="ap-card-imp">편집 중인 문서예요. 저장한 뒤 승인해 주세요</p>';
      else if (noTo) h += '<p class="ap-card-imp">목적지가 정해지지 않았어요. 정리함(⌘3)에서 골라 주세요</p>';
    }
    return h + '</div>';
  }
  // Jira 카드: 무엇을 어떻게 바꾸는지 그대로 보여 준다
  function jiraEdited(c) { const ed = S.edits[c.id] || {}; return { body: ed.body != null ? ed.body : c.body, to: ed.to != null ? ed.to : c.to, changed: ed.body != null && ed.body !== c.body || ed.to != null && ed.to !== c.to }; }
  function jiraBodyHTML(c, v) {
    if (c.op === 'transition') return '<div class="ap-jr"><span class="ap-jr-l">상태</span><span class="ap-jr-v"><b>' + E(c.status || '지금 상태') + '</b><i>→</i><b class="is-to">' + E(v.to || '') + '</b></span></div>';
    if (c.op === 'comment') return '<blockquote class="ap-jr-q">' + E(v.body || '') + '</blockquote>';
    return '<div class="ap-jr"><span class="ap-jr-l">새 티켓</span><span class="ap-jr-v"><b>' + E(c.project || '') + '</b>' + (c.issueType ? ' · ' + E(c.issueType) : '') + '</span></div>' +
      '<div class="ap-jr"><span class="ap-jr-l">요약</span><span class="ap-jr-v">' + E(c.summary || '') + '</span></div>' +
      (c.description ? '<blockquote class="ap-jr-q">' + E(cut(c.description, 280)) + '</blockquote>' : '');
  }
  function jiraCardHTML(c) {
    const st = stOf(c), pend = st === 'pending' || st === 'failed', b = !!S.busy[c.id] || st === 'applying', v = jiraEdited(c);
    const kindL = c.op === 'transition' ? '상태 바꾸기' : c.op === 'comment' ? '댓글 남기기' : '새 티켓';
    const title = c.op === 'create' ? (c.summary || c.title || '새 티켓') : (c.key || '') + (c.title ? ' · ' + c.title : '');
    let h = '<div class="ap-card k-jira" data-id="' + E(c.id) + '" data-state="' + E(st) + '">' +
      '<div class="ap-card-h">' + ic('ticket') + '<b class="ap-card-t" title="' + E(title) + '">' + E(title) + '</b>' + stChip(c) + '</div>' +
      '<div class="ap-card-kind">' + E(kindL) + (v.changed ? ' · <em>내가 고쳤어요</em>' : '') + '</div>';
    if (S.editing === c.id) {
      h += '<div class="ap-edit">' + (c.op === 'comment'
        ? '<label class="ap-edit-l" for="ap-edit-ta">댓글 글</label><textarea class="ap-edit-ta" id="ap-edit-ta" rows="5" maxlength="4000" spellcheck="false">' + E(v.body || '') + '</textarea>'
        : '<label class="ap-edit-l" for="ap-edit-ta">바꿀 상태</label><input class="input ap-edit-ta" id="ap-edit-ta" type="text" value="' + E(v.to || '') + '" spellcheck="false" autocomplete="off">') +
        '<div class="ap-card-b"><button type="button" class="btn sm primary" data-ap="edit-save" data-id="' + E(c.id) + '">고침 적용<kbd>⌘↵</kbd></button><button type="button" class="btn sm" data-ap="edit-cancel" data-id="' + E(c.id) + '">취소<kbd>esc</kbd></button></div></div>';
      return h + '</div>';
    }
    h += jiraBodyHTML(c, v);
    const why = pend ? reasonsOf(c) : [];
    if (why.length) h += '<ul class="ap-card-why">' + why.map(x => '<li>' + E(x) + '</li>').join('') + '</ul>';
    if (st === 'failed' && c.error) h += '<p class="ap-card-imp is-bad" role="alert">' + E(c.error) + '</p>';
    if (pend) {
      h += '<div class="ap-card-b">' +
        '<button type="button" class="btn sm primary" data-ap="jira-apply" data-id="' + E(c.id) + '"' + (b ? ' disabled' : '') + '>' + (b ? '<i class="spinner"></i>반영하는 중…' : st === 'failed' ? '다시 시도…' : '반영하기…') + '</button>' +
        '<button type="button" class="btn sm" data-ap="reject" data-id="' + E(c.id) + '"' + (b ? ' disabled' : '') + '>거절</button>' +
        (c.op !== 'create' ? '<button type="button" class="link-btn" data-ap="edit-card" data-id="' + E(c.id) + '"' + (b ? ' disabled' : '') + '>고치기</button>' : '') + '</div>';
    }
    return h + '</div>';
  }
  function otherCardHTML(c) {
    return '<div class="ap-card k-other" data-id="' + E(c.id) + '" data-state="' + E(stOf(c)) + '"><div class="ap-card-h">' + ic('inbox') + '<b class="ap-card-t">' + E(c.title || '제안') + '</b>' + stChip(c) + '</div>' +
      (stOf(c) === 'pending' ? '<div class="ap-card-b"><button type="button" class="btn sm" data-ap="go-queue">정리함에서 보기</button></div>' : '') + '</div>';
  }
  function renderCards(force) {
    if (!X.props) return;
    if (S.editing && !force) { cardsDirty = true; return; }   // 고치는 중에는 카드를 다시 그리지 않는다(입력이 날아가지 않게)
    cardsDirty = false;
    const list = S.run && Array.isArray(S.run.proposals) ? S.run.proposals.filter(c => c && c.id) : [];
    const pend = list.filter(c => stOf(c) === 'pending' || stOf(c) === 'failed' || stOf(c) === 'applying').length;
    const html = list.length ? '<h3 class="ap-h">이 실행이 올린 제안 <span class="cnt">' + list.length + '</span>' + (pend ? '<span class="ap-h-s">' + pend + '개 기다리는 중</span>' : '') + '</h3>' +
      list.map(c => c.kind === 'jira' ? jiraCardHTML(c) : c.kind === 'move' || c.kind === 'delete' ? fileCardHTML(c) : otherCardHTML(c)).join('') : '';
    withFocus(X.props, () => setHTML(X.props, html));
  }

  // ---------- 실행: 시작 · 따라가기 · 멈추기 ----------
  async function start(o) {
    if (!usable()) { toast('지금은 Claude를 쓸 수 없어요'); return; }
    if (S.starting) return;
    if (isRunning()) { toast('Claude가 일하는 중이에요 · 끝나면 다시 시켜 주세요'); return; }
    syncCtx();
    const context = {};
    if (S.ctx.mode) context.mode = S.ctx.mode;
    // 열려 있는 문서는 문서가 필요한 빠른 작업이거나(이 문서 요약) 내가 "함께 알려요"를 켜 둔 자유 지시에만 알린다
    const pre = o.preset ? presets().find(x => x.id === o.preset) : null;
    if (S.ctx.docId && (pre ? pre.needs === 'doc' : S.useDoc)) { context.docId = S.ctx.docId; if (S.ctx.docTitle) context.title = S.ctx.docTitle; }
    const params = { prompt: o.prompt || '', context };
    if (o.preset) params.preset = o.preset;
    S.starting = true; renderCompose(); renderQuick();
    if (X.runbtn && (!document.activeElement || document.activeElement === document.body || ta.disabled)) X.runbtn.focus({ preventScroll: true });   // 글 상자가 잠기면 포커스가 사라진다 → 멈추기(⌘.)가 닿게 단추로
    const r = await call('aiTask', params);
    S.starting = false;
    if (!r || r.ok === false) {
      toast((r && r.error) || '시작하지 못했어요', 'error');
      await loadStatus(); attachRunning(); renderAll();
      return;
    }
    if (r.digest && r.digest.kind) { gotoDigest(r.digest, o); return; }
    if (!o.preset && ta) { ta.value = ''; autosize(); }
    S.preset = null;
    S.run = { runId: r.runId, kind: 'task', status: 'running', title: o.title || '', prompt: o.prompt || o.title || '', preset: o.preset || null, steps: [], answer: '', proposals: [], started: Date.now() / 1000, model: '', turns: 0, durationMs: 0, error: null };
    S.view = 'run'; S.stepsOpen = null; stick = true;
    renderAll();
    keepFocusInside();
    if (document.activeElement === root && X.runbtn) X.runbtn.focus({ preventScroll: true });
    startPoll();
    refreshRun();
    loadStatus().then(() => { fireChange(); });
  }
  // 정리(digest)를 돌리는 빠른 작업: 그 화면으로 보내 준다
  const DIGEST_TOAST = { week: '이번 주를 정리하고 있어요', tickets: '티켓을 정리하고 있어요', home: '홈 브리핑을 정리하고 있어요', doc: '문서를 요약하고 있어요' };
  function gotoDigest(d, o) {
    if (ta && !(o && o.preset)) { ta.value = ''; autosize(); }
    S.preset = null;
    close();
    try {
      if (typeof api.showDigest === 'function') api.showDigest(d.kind, d.scope);
      else { const m = { week: 'week', tickets: 'tickets', home: 'home' }[d.kind]; if (m) api.setMode(m); }
    } catch (_) { /* 무시 */ }
    toast(DIGEST_TOAST[d.kind] || 'Claude가 정리하고 있어요', '', 3200);
  }
  function primaryAction() {
    if (isRunning()) { stopRun(); return; }
    const text = ta ? ta.value.trim() : '';
    if (S.preset) { runPreset(S.preset); return; }
    if (text) { start({ prompt: text, title: cut(text, 40) }); return; }
    toast('시킬 일을 적어 주세요');
    if (ta && !ta.disabled) ta.focus({ preventScroll: true });
  }
  function runPreset(id) {
    const p = presets().find(x => x.id === id);
    if (!p) return;
    start({ prompt: '', preset: p.id, title: p.title });
  }
  async function stopRun() {
    const run = S.run;
    if (!run || run.status !== 'running') return;
    const r = await call('aiCancel', { runId: run.runId });
    if (!r || r.ok === false) { toast((r && r.error) || '멈추지 못했어요', 'error'); return; }
    toast('멈추고 있어요…');
    refreshRun();
  }
  // 저장된 실행 하나를 서버에서 다시 읽어 합친다
  async function refreshRun() {
    const run = S.run;
    if (!run || !run.runId) return;
    const id = run.runId;
    const r = await call('aiRun', { runId: id });
    if (!S.run || S.run.runId !== id) return;
    if (!r || r.ok === false || !r.run) {
      if (run.status === 'loading') { run.status = 'error'; run.error = { message: (r && r.error) || '기록을 불러오지 못했어요' }; renderResult(); }
      return;
    }
    const n = r.run, was = run.status;
    run.status = n.status || run.status;
    ['title', 'model', 'turns', 'durationMs', 'started', 'ended', 'error'].forEach(k => { if (n[k] != null && n[k] !== '') run[k] = n[k]; });
    if (n.prompt) run.prompt = n.prompt;
    if (Array.isArray(n.steps)) run.steps = n.steps;
    if (typeof n.answer === 'string' && (n.answer || !run.answer || run.status !== 'running')) run.answer = n.answer;
    if (Array.isArray(n.proposals)) {
      run.proposals = n.proposals;
      n.proposals.forEach(c => { const d = c && S.decided[c.id]; if (d && String(c.state || 'pending') !== d.srv) delete S.decided[c.id]; });   // 서버가 따라왔다 → 서버 것을 쓴다
    }
    if (S.open && S.view === 'run') renderResult();
    if (was === 'running' && run.status !== 'running') { stopPoll(); loadRuns(); loadStatus().then(() => { if (S.open) { renderAll(); } fireChange(); }); }
    else if (run.status === 'running') startPoll();
  }
  function scheduleRefresh() { if (refreshTimer) return; refreshTimer = setTimeout(() => { refreshTimer = 0; refreshRun(); }, 700); }
  function scheduleRender() { if (renderTimer) return; renderTimer = setTimeout(() => { renderTimer = 0; if (S.open && S.view === 'run') renderResult(); }, 250); }
  // 이벤트를 놓쳐도 따라가도록 가끔 다시 읽는다(이벤트가 없으면 1초마다)
  function startPoll() { if (pollTimer) return; pollTimer = setInterval(() => { if (isRunning()) refreshRun(); else stopPoll(); }, hasEvents() ? 3000 : 1000); }
  function stopPoll() { clearInterval(pollTimer); pollTimer = 0; }
  // 단계는 index로 맞춘다: 도구 단계는 결과(ok)가 오면 같은 index로 다시 온다. index가 없으면 ts·도구·글로 맞춘다.
  function upsertStep(run, st) {
    if (!st || typeof st !== 'object') return;
    const i = run.steps.findIndex(x => x && (st.index != null ? x.index === st.index : x.ts === st.ts && x.tool === st.tool && x.text === st.text));
    if (i >= 0) run.steps[i] = Object.assign({}, run.steps[i], st); else run.steps.push(st);
  }
  function onRunEvent(ev) {
    if (!ev || ev.kind === 'digest') return;
    const run = S.run;
    if (!run || run.runId !== ev.runId) {
      // 다른 곳(예: CLI)에서 시작한 시키기 실행이 보이면 붙는다
      if (S.open && ev.kind === 'task' && ev.status === 'running' && !isRunning()) loadStatus().then(() => { attachRunning(); renderAll(); });
      return;
    }
    if (ev.step) upsertStep(run, ev.step);
    if (typeof ev.text === 'string') run.answer = ev.text;
    if (ev.status && ev.status !== run.status) run.status = ev.status;
    scheduleRender();
    if (ev.status && ev.status !== 'running') { refreshRun(); }
    else scheduleRefresh();
  }
  // 패널을 열었을 때 이미 일하는 시키기 실행이 있으면 그 화면을 보여 준다
  function attachRunning() {
    if (isRunning()) return;
    const r = taskRunning();
    if (!r) return;
    S.run = { runId: r.runId, kind: 'task', status: 'running', title: r.title || '', prompt: r.title || '', preset: null, steps: [], answer: '', proposals: [], started: r.started, model: '', turns: 0, durationMs: 0, error: null };
    S.view = 'run'; S.stepsOpen = null; stick = true;
    refreshRun(); startPoll();
  }
  async function loadRuns() {
    const r = await call('aiRuns', { limit: 60 });
    if (!r || r.ok === false) { S.runsErr = (r && r.error) || ''; if (!S.runs) S.runs = []; }
    else { S.runsErr = ''; S.runs = (Array.isArray(r.runs) ? r.runs : []).slice(0, 20); }
    if (S.open) renderHist();
  }
  function openRun(id) {
    if (!id) return;
    const known = (S.runs || []).find(x => x.runId === id) || {};
    S.run = { runId: id, kind: known.kind || 'task', status: 'loading', title: known.title || '', prompt: known.title || '', preset: null, steps: [], answer: '', proposals: [], started: known.started, model: known.model || '', turns: 0, durationMs: known.durationMs || 0, error: null };
    S.view = 'run'; S.stepsOpen = null; stick = false;
    renderAll();
    if (X.scroll) X.scroll.scrollTop = 0;
    refreshRun();
  }
  function again() {
    const run = S.run;
    if (!run) return;
    const p = run.preset ? presets().find(x => x.id === run.preset) : (presets().find(x => x.title === run.prompt || x.title === run.title) || null);
    if (p) start({ prompt: '', preset: p.id, title: p.title });
    else if (run.prompt) start({ prompt: run.prompt, title: cut(run.prompt, 40) });
  }

  // ---------- 제안 카드 처리 ----------
  async function afterCard() { await refreshRun(); }
  async function decideCard(id, action) {
    const c = cardById(id);
    if (!c || S.busy[id]) return;
    if (action === 'approve' && editingBlock(c)) { toast('편집 중인 문서예요. 저장한 뒤 승인해 주세요', 'error'); return; }
    S.busy[id] = true; renderCards();
    const r = await call('decide', { id: c.id, action });
    delete S.busy[id];
    if (!r || r.ok === false) toast((r && r.error) || '처리하지 못했어요', 'error');
    else if (action === 'reject') { decide1(c, 'rejected'); toast(c.kind === 'jira' ? '거절했어요 · Jira에는 아무것도 보내지 않았어요' : '거절했어요 · 같은 제안은 30일 동안 다시 안 보여 드려요'); }
    else {
      const ap = r.applied || {};
      if (ap.trashed > 0) { decide1(c, 'applied'); toast('휴지통으로 보냈어요 · 30일 보관' + (r.undoable ? ' · 되돌리기 ⌥⌘Z' : ''), '', 8000); }
      else if (ap.moved > 0) { decide1(c, 'applied'); toast('옮겼어요' + (ap.rewrote > 0 ? ' · 링크 ' + ap.rewrote + '개 고침' : '') + (r.undoable ? ' · 되돌리기 ⌥⌘Z' : ''), '', 8000); }
      else if (ap.skipped && ap.skipped.length) toast('옮기지 못했어요 · ' + (ap.skipped[0].reason || ''), 'error');
      else { decide1(c, 'applied'); toast('처리했어요'); }
    }
    await afterCard();
  }
  // Jira에 쓰는 건 되돌릴 수 없다 → 보낼 내용을 보여 주고 한 번 더 묻는다
  function jiraLines(c, v) {
    const lines = [];
    if (c.op === 'transition') lines.push(c.key + (c.title ? ' · ' + cut(c.title, 60) : ''), '상태를 ‘' + (c.status || '지금 상태') + '’에서 ‘' + (v.to || '') + '’(으)로 바꿔요');
    else if (c.op === 'comment') lines.push(c.key + (c.title ? ' · ' + cut(c.title, 60) : '') + ' 티켓에 댓글을 남겨요', '“' + cut(v.body, 220) + '”');
    else lines.push((c.project || '') + ' 프로젝트에 새 티켓을 만들어요', '요약: ' + cut(c.summary, 120));
    lines.push({ text: 'Jira에 바로 반영돼요. 팀 모두에게 보이고 되돌릴 수 없어요.', warn: true });
    return lines;
  }
  async function applyJira(id) {
    const c = cardById(id);
    if (!c || S.busy[id]) return;
    const M = window.SynapseMenu;
    if (!M || typeof M.confirm !== 'function') { toast('확인 창을 열지 못했어요', 'error'); return; }
    const v = jiraEdited(c);
    const ok = await M.confirm({ title: 'Jira에 반영할까요?', lines: jiraLines(c, v), confirmLabel: 'Jira에 반영', danger: true });
    if (!ok) return;
    S.busy[id] = true; renderCards();
    const p = { id: c.id };
    if (v.body != null && v.body !== c.body && c.op === 'comment') p.body = v.body;
    if (v.to != null && v.to !== c.to && c.op === 'transition') p.to = v.to;
    const r = await call('jiraApply', p);
    delete S.busy[id];
    if (!r || r.ok === false) toast((r && r.error) || 'Jira에 반영하지 못했어요', 'error', 6000);
    else { toast(r.message || 'Jira에 반영했어요', '', 5000); delete S.edits[id]; decide1(c, 'applied'); }
    await afterCard();
  }
  function startEdit(id) {
    const c = cardById(id);
    if (!c || c.op === 'create') return;
    S.editing = id;
    renderCards(true);
    const t = root.querySelector('#ap-edit-ta');
    if (t) { t.focus({ preventScroll: true }); try { t.setSelectionRange(t.value.length, t.value.length); } catch (_) { /* input은 무시 */ } }
  }
  function endEdit(save) {
    const id = S.editing;
    if (!id) return;
    const c = cardById(id), t = root.querySelector('#ap-edit-ta');
    if (save && c && t) {
      const val = t.value.trim();
      if (c.op === 'comment') { if (!val) { toast('댓글 글을 비울 수 없어요', 'error'); return; } S.edits[id] = Object.assign({}, S.edits[id], { body: val }); }
      else if (c.op === 'transition') { if (!val) { toast('바꿀 상태를 적어 주세요', 'error'); return; } S.edits[id] = Object.assign({}, S.edits[id], { to: val }); }
    }
    S.editing = null;
    renderCards(true);
    const b = root.querySelector('[data-ap="jira-apply"][data-id="' + String(id).replace(/["\\]/g, '\\$&') + '"]');
    if (b) b.focus({ preventScroll: true });
  }

  // ---------- 클릭 · 키 ----------
  function onClick(e) {
    const b = e.target.closest('[data-ap]');
    if (!b || !root.contains(b) || b.disabled || b.getAttribute('aria-disabled') === 'true') return;
    const act = b.dataset.ap, id = b.dataset.id;
    switch (act) {
      case 'close': close(); break;
      case 'run': if (isRunning()) stopRun(); else primaryAction(); break;
      case 'preset': runPreset(id); break;
      case 'ctxdoc': S.useDoc = !S.useDoc; renderCtx(); break;
      case 'back': S.view = 'new'; renderAll(); if (X.scroll) X.scroll.scrollTop = 0; break;
      case 'open-run': openRun(id); break;
      case 'steps': S.stepsOpen = !stepsExpanded(); renderSteps(); break;
      case 'copy-answer': if (S.run && S.run.answer) { try { api.copyText(S.run.answer, '답을 복사했어요'); } catch (_) { /* 무시 */ } } break;
      case 'again': again(); break;
      case 'approve': decideCard(id, 'approve'); break;
      case 'reject': decideCard(id, 'reject'); break;
      case 'jira-apply': applyJira(id); break;
      case 'edit-card': startEdit(id); break;
      case 'edit-save': endEdit(true); break;
      case 'edit-cancel': endEdit(false); break;
      case 'open-doc': openDoc(b.dataset.doc); break;
      case 'go-queue': close(); try { api.setMode('queue'); } catch (_) { /* 무시 */ } break;
      case 'settings': close(true); try { api.openSettings(); } catch (_) { /* 무시 */ } break;
      case 'copy-instr': try { api.copyInstruction(); } catch (_) { toast('지시문을 만들지 못했어요', 'error'); } break;
    }
  }
  // app.js가 패널 안의 키를 모두 넘겨 준다. true = 처리함(앱은 기본 동작을 막는다)
  function onKey(e) {
    if (!S.open || !api || !root) return false;
    if (e.isComposing || e.keyCode === 229) return false;
    const k = e.key, meta = e.metaKey, ctrl = e.ctrlKey, alt = e.altKey, shift = e.shiftKey;
    const inside = root.contains(e.target) || root.contains(document.activeElement);
    if (k === 'Escape' && !meta && !ctrl && !alt) {
      if (S.editing) { endEdit(false); return true; }
      close();
      return true;
    }
    if (!inside) return false;
    const isEnter = k === 'Enter' || e.code === 'Enter' || e.code === 'NumpadEnter';
    if (S.editing && isEnter && !meta && !ctrl && !alt && !shift && e.target && e.target.tagName === 'INPUT') { endEdit(true); return true; }
    if (meta && !ctrl && !alt && !shift && isEnter) {
      if (S.editing) { endEdit(true); return true; }
      if (!e.repeat) primaryAction();
      return true;
    }
    if (meta && !ctrl && !alt && !shift && (k === '.' || e.code === 'Period')) { if (!e.repeat) stopRun(); return true; }
    if (k === 'Tab' && !meta && !ctrl && !alt) {
      const f = Array.from(root.querySelectorAll('button:not([disabled]), textarea:not([disabled]), input:not([disabled]), [tabindex="0"]')).filter(n => n.offsetParent !== null);
      if (!f.length) return true;
      const i = f.indexOf(document.activeElement);
      const n = shift ? (i <= 0 ? f.length - 1 : i - 1) : (i < 0 || i === f.length - 1 ? 0 : i + 1);
      f[n].focus({ preventScroll: false });
      return true;
    }
    if ((k === 'ArrowDown' || k === 'ArrowUp') && !meta && !ctrl && !alt && !shift) {
      const a = document.activeElement;
      if (a && a.matches && a.matches('.ap-q, .ap-hr')) {
        const rows = Array.from(root.querySelectorAll('.ap-q:not([disabled]), .ap-hr'));
        const i = rows.indexOf(a), n = rows[Math.max(0, Math.min(rows.length - 1, i + (k === 'ArrowDown' ? 1 : -1)))];
        if (n) n.focus({ preventScroll: false });
        return true;
      }
      if (a === ta && k === 'ArrowDown' && ta.selectionStart === ta.value.length) {
        const first = root.querySelector('.ap-q:not([disabled]), .ap-hr');
        if (first) { first.focus({ preventScroll: false }); return true; }
      }
    }
    return false;
  }

  // ===========================================================================
  // 홈 브리핑 "오늘" 카드 (§8.5). res = aiDigest(kind:"home") 응답. 쓸 수 없거나 비었으면 null(카드를 숨긴다).
  // 참조가 있는 줄은 키보드로 고를 수 있는 홈 줄(kind 'ai')이 된다: rows → app.js의 homeOrder 맨 앞에 끼운다.
  function homeBrief(res, ui) {
    ui = ui || {};
    if (!res || res.ok === false) return null;
    const d = res.digest && typeof res.digest === 'object' ? res.digest : null;
    const lines = d && Array.isArray(d.today) ? d.today.filter(x => x && x.text).slice(0, 3) : [];
    const headline = d && d.headline ? String(d.headline) : '';
    const running = !!res.running || !!ui.loading;
    if (!headline && !lines.length) {
      // 자동 정리를 꺼 둔 채 저장된 정리가 없을 때만, 한 줄로 "지금 정리"를 내민다(카드를 숨기면 홈 브리핑을 만들 길이 없다)
      if (!running && res.blocked === 'manual' && res.state !== 'empty') {
        return { html: '<div class="ap-brief is-manual h-group" role="group" aria-label="오늘 브리핑"><div class="ap-bf"><span class="ap-bk">' + ic('sparkle') + '오늘</span><span class="ap-bm">자동 정리가 꺼져 있어요</span>' +
          '<button type="button" class="link-btn" data-ai-act="home-redo" title="Claude에게 오늘 할 일을 정리시켜요">지금 정리</button></div></div>', rows: [] };
      }
      if (!running) return null;
      return { html: '<div class="ap-brief is-loading h-group" role="group" aria-label="오늘 브리핑" aria-busy="true"><div class="ap-bh"><span class="ap-bk">' + ic('sparkle') + '오늘</span><span class="ap-bm">Claude가 읽고 있어요…</span></div>' +
        '<i class="ap-sk"></i><i class="ap-sk is-short"></i></div>', rows: [] };
    }
    const rows = [];
    const sel = ui.sel;
    const lh = lines.map((x, i) => {
      const refs = Array.isArray(x.refs) ? x.refs.filter(r => r && r.docId != null) : [];
      const first = refs.find(r => r.docId) || null, key = 'ai:' + i;   // 코드 흐름(docId "")은 열 문서가 없다
      if (first) rows.push({ key, item: { id: key, docId: String(first.docId), line: first.line != null ? first.line : null, title: first.title || x.text, kind: 'ai' }, kind: 'ai' });
      const body = '<span class="ap-bl-n" aria-hidden="true">' + (i + 1) + '</span><div class="ap-bl-b"><span class="ap-bl-t">' + E(x.text) + '</span>' + (x.why ? '<span class="ap-bl-w">' + E(x.why) + '</span>' : '') +
        (refs.length ? '<span class="ap-bl-refs">' + refsHTML(refs) + '</span>' : '') + '</div>' + (first ? '<span class="ap-bl-go"><kbd>↵</kbd>열기</span>' : '');
      return first ? '<div class="ap-bl" role="option" id="hrow-ai-' + i + '" data-hkey="' + key + '" aria-selected="' + (sel === key) + '">' + body + '</div>'
        : '<div class="ap-bl is-plain" role="presentation">' + body + '</div>';
    }).join('');
    const meta = metaLabel(res.meta);
    const html = '<div class="ap-brief h-group' + (running ? ' is-busy' : '') + '" role="group" aria-label="오늘 브리핑 (Claude)"' + (running ? ' aria-busy="true"' : '') + '>' +
      '<div class="ap-bh"><span class="ap-bk">' + ic('sparkle') + '오늘</span>' + (headline ? '<span class="ap-bhl">' + E(headline) + '</span>' : '') + '</div>' + lh +
      '<div class="ap-bf"><span class="ap-bm">' + (running ? '<i class="spinner"></i>다시 정리하는 중…' : E(meta)) + '</span>' +
      (running ? '' : '<button type="button" class="link-btn" data-ai-act="home-redo" title="Claude에게 홈 브리핑을 다시 정리시켜요">다시 정리</button>') + '</div></div>';
    return { html, rows };
  }

  // ===========================================================================
  // 리더 문서 요약 상자 (§8.5). entry = { res, loading, asked } · ui = { collapsed }
  function docSummary(entry, docId, ui) {
    ui = ui || {};
    if (!entry) return '';
    const res = entry.res;
    const d = res && res.digest && typeof res.digest === 'object' ? res.digest : null;
    const has = d && (d.summary || (Array.isArray(d.points) && d.points.length) || (Array.isArray(d.todos) && d.todos.length));
    const running = !!entry.loading || !!(res && res.running);
    if (!has) {
      if (running) return '<section class="ap-ds is-loading" aria-busy="true" aria-label="Claude 요약"><div class="ap-ds-h is-static"><span class="ap-ds-k">' + ic('sparkle') + 'Claude 요약</span><span class="ap-ds-m">읽고 있어요…</span></div><div class="ap-ds-b"><i class="ap-sk"></i><i class="ap-sk"></i><i class="ap-sk is-short"></i></div></section>';
      if (!entry.asked) return '';
      if (res && res.state === 'empty') return '<section class="ap-ds" aria-label="Claude 요약"><div class="ap-ds-h is-static"><span class="ap-ds-k">' + ic('sparkle') + 'Claude 요약</span></div><div class="ap-ds-b"><p class="ap-ds-s is-quiet">요약할 내용이 없어요.</p></div></section>';
      const n = noticeHTML(res);
      return n ? '<section class="ap-ds is-note" aria-label="Claude 요약">' + n + '</section>' : '';
    }
    const open = !ui.collapsed, meta = metaLabel(res && res.meta);
    const stale = res && res.state === 'stale';
    const points = Array.isArray(d.points) ? d.points.filter(Boolean).slice(0, 5) : [], todos = Array.isArray(d.todos) ? d.todos.filter(Boolean).slice(0, 5) : [];
    return '<section class="ap-ds' + (open ? '' : ' is-collapsed') + (stale ? ' is-stale' : '') + (running ? ' is-busy' : '') + '" aria-label="Claude 요약">' +
      '<button type="button" class="ap-ds-h" data-ai-act="docsum-toggle" aria-expanded="' + open + '" title="' + (open ? '접기' : '펼치기') + '"><span class="ap-ds-k">' + ic('sparkle') + 'Claude 요약</span>' +
      '<span class="ap-ds-m">' + E(meta) + '</span><span class="ap-caret" aria-hidden="true">' + ic(open ? 'hide' : 'next') + '</span></button>' +
      (open ? '<div class="ap-ds-b">' + (d.summary ? '<p class="ap-ds-s">' + E(d.summary) + '</p>' : '') +
        (points.length ? '<ul class="ap-ds-p">' + points.map(p => '<li>' + E(p) + '</li>').join('') + '</ul>' : '') +
        (todos.length ? '<div class="ap-ds-t"><b>할 일</b><ul>' + todos.map(p => '<li>' + E(p) + '</li>').join('') + '</ul></div>' : '') +
        '<div class="ap-ds-f"><span>' + (running ? '<i class="spinner"></i>다시 요약하는 중…' : stale ? '문서가 바뀌어서 요약이 오래됐을 수 있어요' : 'Claude가 쓴 요약이에요. 틀릴 수 있으니 본문과 함께 봐 주세요') + '</span>' +
        (running ? '' : '<button type="button" class="link-btn" data-ai-act="docsum-redo">다시 요약</button>') + '</div></div>' : '') + '</section>';
  }

  // ===========================================================================
  // 설정 › Claude (§8.5): 상태 · 연결 시험 · 켜기 · 자동 · 모델 · 경로 · 주간보고 양식
  const SET = { el: null, test: null, testing: false, busy: '', tplDraft: null, pathDraft: null, tplAsk: false };
  function settingsVisible() { const el = SET.el; return !!el && document.contains(el) && el.getClientRects().length > 0; }
  function renderSettings(el) {
    if (!api || !el) return;
    if (SET.el !== el) { SET.el = el; SET.tplAsk = false; }
    if (!el.__apBound) {
      el.__apBound = true;
      el.addEventListener('click', onSetClick);
      el.addEventListener('input', onSetInput);
    }
    paintSettings();
    loadStatus().then(() => paintSettings());
  }
  const refreshSettings = () => { if (settingsVisible()) loadStatus().then(() => paintSettings()); };
  const swHTML = (key, on, label, dis) => '<button class="switch' + (SET.busy === key ? ' is-busy' : '') + '" type="button" role="switch" data-as="sw" data-key="' + key + '" aria-checked="' + (!!on) + '" aria-label="' + E(label) + '"' + (dis ? ' aria-disabled="true"' : '') + '><i></i></button>';
  const rowHTML = (title, desc, right, cls) => '<div class="set-row' + (cls ? ' ' + cls : '') + '"><div class="set-t"><span class="set-l">' + title + '</span>' + (desc ? '<p class="set-d">' + desc + '</p>' : '') + '</div>' + (right || '') + '</div>';
  const MODELS = [['sonnet', 'Sonnet'], ['opus', 'Opus'], ['haiku', 'Haiku']];
  const MODEL_HINT = { sonnet: '빠르고 균형이 좋아요', opus: '가장 꼼꼼하지만 느리고 사용량이 많아요', haiku: '가장 빠르고 가벼워요' };
  function segHTML(key, cur, label) {
    return '<div class="ap-seg" role="group" aria-label="' + E(label) + '">' + MODELS.map(([v, t]) =>
      '<button type="button" class="ap-seg-b" data-as="model" data-key="' + key + '" data-v="' + v + '" aria-pressed="' + (cur === v) + '" title="' + E(MODEL_HINT[v]) + '"' + (SET.busy === key ? ' disabled' : '') + '>' + t + '</button>').join('') + '</div>';
  }
  function settingsHTML(st) {
    const c = st.claude || {}, models = st.models || {}, lim = st.limits || {}, rep = st.report || {};
    const pill = !c.found ? '<span class="pill is-warn">찾지 못했어요</span>' : c.login === 'ok' ? '<span class="pill is-ok">' + ic('check') + '로그인됨</span>' : c.login === 'needed' ? '<span class="pill is-warn">로그인 필요</span>' : '<span class="pill is-na">로그인 확인 전</span>';
    const where = c.found ? '<code>' + E(c.path || '') + '</code>' + (c.version ? ' · 버전 ' + E(c.version) : '') : '설치했다면 아래에서 경로를 골라 주세요.' + (c.error ? ' (' + E(c.error) + ')' : '');
    let h = '<div class="set-group">';
    h += rowHTML('Claude Code', where, pill + '<button class="btn sm" type="button" data-as="test"' + (SET.testing ? ' disabled' : '') + '>' + (SET.testing ? '<i class="spinner"></i>시험 중…' : '연결 시험') + '</button>', 'ap-set-stat');
    if (SET.test) {
      const t = SET.test, ok = t.ok !== false && !t.error;
      h += '<p class="ap-set-test ' + (ok ? 'is-ok' : 'is-bad') + '" role="status">' + ic(ok ? 'check' : 'alert') + '<span>' + (ok ? '연결됐어요' + (t.model ? ' · ' + E(modelLabel(t.model)) : '') + (t.ms ? ' · ' + E(durLabel(t.ms)) : '') + (t.login === 'needed' ? ' · 로그인이 필요해요' : '')
        : E(t.error || '연결하지 못했어요')) + '</span></p>';
    }
    h += rowHTML('Claude로 정리하기', '이번 주·티켓·홈·문서 요약을 Claude가 읽고 정리해 줘요. 사용량은 내 Claude 요금제에서 나가요.', swHTML('enabled', st.enabled, 'Claude로 정리하기'));
    h += rowHTML('화면을 열 때 자동으로 정리', '바뀐 게 있을 때만 다시 정리해요. 오늘 자동으로 ' + E(lim.autoUsedToday != null ? lim.autoUsedToday : 0) + '번 돌았어요' + (lim.autoPerDay ? ' (하루 최대 ' + E(lim.autoPerDay) + '번)' : '') + '. 끄면 “다시 정리” 버튼으로만 돌아요.',
      swHTML('auto', st.auto, '화면을 열 때 자동으로 정리', !st.enabled));
    h += '</div><div class="bp-sub2 ap-sub2">모델</div><div class="set-group">';
    h += rowHTML('정리용', '이번 주·티켓·홈·문서 요약에 써요. ' + E(MODEL_HINT[models.digest] || ''), segHTML('model.digest', models.digest, '정리용 모델'));
    h += rowHTML('시키기용', '⌘J로 시키는 일에 써요. ' + E(MODEL_HINT[models.task] || ''), segHTML('model.task', models.task, '시키기용 모델'));
    h += '</div><div class="bp-sub2 ap-sub2">Claude 찾기</div><div class="set-group"><div class="set-row ap-set-col"><div class="set-t"><label class="set-l" for="ap-path">경로 직접 지정</label>' +
      '<p class="set-d">비워 두면 자동으로 찾아요. 터미널의 <code>claude</code>가 다른 곳에 있을 때만 적어 주세요.</p></div>' +
      '<div class="ap-inline"><input class="input mono" id="ap-path" type="text" data-as="path" value="' + E(SET.pathDraft != null ? SET.pathDraft : (c.custom || '')) + '" placeholder="자동으로 찾기" spellcheck="false" autocomplete="off" autocapitalize="off">' +
      '<button class="btn sm" type="button" data-as="path-save"' + (SET.pathDraft == null || SET.busy === 'claude.path' ? ' disabled' : '') + '>저장</button></div></div></div>';
    const tpl = SET.tplDraft != null ? SET.tplDraft : String(rep.template || ''), changed = SET.tplDraft != null && SET.tplDraft !== String(rep.template || '');
    h += '<div class="bp-sub2 ap-sub2">주간보고 양식</div><div class="set-group"><div class="set-row ap-set-col"><div class="set-t"><span class="set-l">보고 글 양식 ' +
      (rep.isDefault ? '<span class="pill">기본 양식</span>' : '<span class="pill is-ok">내가 고친 양식</span>') + '</span>' +
      '<p class="set-d">이번 주 화면의 “보고 글”을 이 양식대로 써 줘요. 말투·묶는 법·마지막 줄을 글로 적으면 돼요.</p></div>' +
      '<textarea class="input ap-tpl" id="ap-tpl" data-as="tpl" rows="9" spellcheck="false" aria-label="주간보고 양식">' + E(tpl) + '</textarea>' +
      (SET.tplAsk ? '<div class="bp-ask" role="alertdialog"><p>내가 쓴 양식을 지우고 기본 양식으로 돌아갈까요?</p><div class="bp-ask-b"><button class="btn sm danger" type="button" data-as="tpl-reset-yes">기본값으로 되돌리기</button><button class="btn sm" type="button" data-as="tpl-reset-no">취소</button></div></div>'
        : '<div class="ap-inline-b"><button class="btn sm primary" type="button" data-as="tpl-save"' + (!changed || SET.busy === 'report.template' ? ' disabled' : '') + '>저장</button>' +
          '<button class="btn sm" type="button" data-as="tpl-reset"' + (rep.isDefault && !changed ? ' disabled' : '') + '>기본값으로 되돌리기</button></div>') + '</div></div>';
    h += '<p class="set-note">' + ic('info') + '<span>Claude는 이 Mac의 Claude Code로 실행돼요. 사용량은 내 Claude 요금제에서 나가고, API 키는 쓰지 않아요.</span></p>';
    return h;
  }
  // force: 사용자가 누른 단추의 결과를 그릴 때(입력칸에 포커스가 있어도 그린다). 밖에서 온 갱신(상태 이벤트)은 글을 쓰는 중이면 미룬다.
  function paintSettings(force) {
    const el = SET.el;
    if (!el) return;
    const act = document.activeElement;
    if (!force && act && el.contains(act) && (act.id === 'ap-tpl' || act.id === 'ap-path')) return;   // 글을 쓰는 중에는 입력칸을 다시 만들지 않는다
    let h = '<div class="ap-set">';
    if (!statusLoaded) h += '<div class="bp-state"><i class="spinner"></i><span>불러오는 중이에요</span></div>';
    else if (!status) h += '<div class="set-group"><p class="set-note">' + ic('info') + '<span>' + E(statusErr || '이 Synapse에는 Claude 연결이 없어요. 새 버전 앱에서 설정할 수 있어요(브라우저 미리보기에서는 쓸 수 없어요).') + '</span></p></div>';
    else h += settingsHTML(status);
    withFocus(el, () => { el.innerHTML = h + '</div>'; });
  }
  async function setSetting(key, value, okMsg) {
    SET.busy = key; paintSettings(true);
    const r = await call('setAISetting', { key, value: String(value) });
    SET.busy = '';
    if (!r || r.ok === false) { toast((r && r.error) || '바꾸지 못했어요', 'error'); paintSettings(true); return false; }
    if (r.status && typeof r.status === 'object') { status = Object.assign({}, r.status, { ok: true }); statusLoaded = true; statusErr = ''; } else await loadStatus();
    if (okMsg) toast(okMsg);
    paintSettings(true);
    if (S.open) renderAll();
    try { if (typeof api.refreshAI === 'function') api.refreshAI(); } catch (_) { /* 무시 */ }
    fireChange();
    return true;
  }
  async function runTest() {
    if (SET.testing) return;
    SET.testing = true; SET.test = null; paintSettings(true);
    const r = await call('aiTest');
    SET.testing = false;
    SET.test = r && r.ok !== false ? r : { ok: false, error: (r && r.error) || '연결하지 못했어요' };
    await loadStatus();
    paintSettings(true);
    try { if (typeof api.refreshAI === 'function') api.refreshAI(); } catch (_) { /* 무시 */ }
    fireChange();
  }
  function onSetInput(e) {
    const t = e.target;
    if (!t || !t.dataset) return;
    if (t.dataset.as === 'tpl') {
      SET.tplDraft = t.value;
      const rep = (status && status.report) || {}, changed = t.value !== String(rep.template || '');
      const sv = SET.el.querySelector('[data-as="tpl-save"]'); if (sv) sv.disabled = !changed || SET.busy === 'report.template';
    } else if (t.dataset.as === 'path') {
      SET.pathDraft = t.value;
      const sv = SET.el.querySelector('[data-as="path-save"]'); if (sv) sv.disabled = false;
    }
  }
  async function onSetClick(e) {
    const b = e.target.closest('[data-as]');
    if (!b || !SET.el.contains(b) || b.disabled) return;
    const act = b.dataset.as;
    if (act === 'test') return runTest();
    if (act === 'sw') {
      const key = b.dataset.key;
      if (SET.busy) return;
      if (b.getAttribute('aria-disabled') === 'true') { toast('먼저 “Claude로 정리하기”를 켜 주세요'); return; }
      const next = b.getAttribute('aria-checked') !== 'true';
      const okMsg = key === 'enabled' ? (next ? 'Claude로 정리해요' : 'Claude로 정리하지 않아요') : (next ? '화면을 열 때 바뀐 게 있으면 정리해요' : '“다시 정리” 버튼으로만 정리해요');
      return setSetting(key, next ? '1' : '0', okMsg);
    }
    if (act === 'model') {
      if (SET.busy) return;
      const key = b.dataset.key, v = b.dataset.v;
      const cur = status && status.models ? status.models[key === 'model.digest' ? 'digest' : 'task'] : '';
      if (cur === v) return;
      return setSetting(key, v, (key === 'model.digest' ? '정리용' : '시키기용') + ' 모델을 ' + modelLabel(v) + '(으)로 바꿨어요');
    }
    if (act === 'path-save') {
      const v = (SET.pathDraft == null ? '' : SET.pathDraft).trim();
      const ok = await setSetting('claude.path', v, v ? '경로를 저장했어요 · 연결 시험으로 확인해 보세요' : '자동으로 찾아요');
      if (ok) SET.pathDraft = null;
      paintSettings(true);
      return;
    }
    if (act === 'tpl-save') {
      const ok = await setSetting('report.template', SET.tplDraft == null ? '' : SET.tplDraft, '양식을 저장했어요 · 다음 정리부터 이 양식으로 써요');
      if (ok) SET.tplDraft = null;
      paintSettings(true);
      return;
    }
    if (act === 'tpl-reset') { SET.tplAsk = true; return paintSettings(true); }
    if (act === 'tpl-reset-no') { SET.tplAsk = false; return paintSettings(true); }
    if (act === 'tpl-reset-yes') {
      SET.tplAsk = false;
      const ok = await setSetting('report.template', '', '기본 양식으로 되돌렸어요');
      if (ok) SET.tplDraft = null;
      paintSettings(true);
    }
  }

  window.SynapseAIPanel = Object.freeze({ init, open, close, toggle, isOpen, onKey, onChange, busy, homeBrief, docSummary, renderSettings, refreshSettings });
})();
