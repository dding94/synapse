// workmap.js — Synapse v0.9 작업 지도(⌘2) + 정리 계획 판 (docs/V09.md §6·§7.1·§7.2). window.SynapseWorkMap 하나만 만든다.
// U2 모듈 계약(tickets.js·queue.js와 같다): init(api) · mount(listEl, readerEl) · refresh() · onKey(e) → bool · focus() · unmount()  + openPlan()
// 위쪽은 티켓을 지금·다음·기다림으로, 아래쪽은 PARA 폴더를 건강 상태로 보여 준다. 오른쪽 상세는 workMapDetail.
// 정리 계획은 목록 칸을 덮는 판으로 열고(오른쪽에는 고른 카드의 미리보기), 승인·거절·나중에·자리 바꾸기·묶음 승인·되돌리기·배우기 질문을 모두 여기서 한다.
// 쓰는 브리지: workMap · workMapDetail · tidyPlan · tidyDecide · tidyDecideGroup · tidyUndo · tidyPromote · tidyRunRules · setBrainSetting(workmap.scope) · aiDigest(tidy)
(function () {
  'use strict';

  const STORE_KEY = 'synapse.workmap.v1';
  const CERT = { certain: '확실', likely: '아마', unsure: '확인 필요' };
  const OP_ICON = { move: 'move', merge: 'stack', archive: 'inbox', exclude: 'minus', trash: 'trash', note: 'alert' };
  const OP_LABEL = { move: '옮기기', merge: '합치기', archive: '보관', exclude: '색인 제외', trash: '휴지통', note: '알림' };
  const OP_DONE = { move: '옮겼어요', merge: '합쳤어요', archive: '보관으로 옮겼어요', exclude: '색인에서 뺐어요', trash: '휴지통으로 보냈어요' };
  const ZONE_LABEL = { loose: '데스크톱', inbox: '받은 문서함', 'vault-root': '볼트 루트', workspace: '작업 공간', project: '프로젝트', area: '영역', resource: '자료', archive: '보관' };
  const HEALTH_LABEL = { fresh: '7일 안에 바뀜', warm: '30일 안에 바뀜', stale: '30일 넘게 그대로', messy: '정리가 필요해요', frozen: '동결, 참조용' };
  const GROUP_TITLE = { desktop: '데스크톱 정리', tickets: '티켓 폴더', archive: '보관', index: '색인', check: '확인 필요' };
  const SCOPES = [['all', '전체'], ['work', '업무'], ['personal', '개인']];

  let api = null, listEl = null, readerEl = null, root = null, barEl = null, noteEl = null, mainEl = null, scrollEl = null, planEl = null, dtEl = null;
  let data = null, loadError = null, loading = false, seq = 0;
  let pref = loadPref();                 // {collapsed:{구역키: true|false}} — 사용자가 직접 접거나 편 것만
  let nav = [];                          // 보이는 순서대로 {nav:'s|구역'|'r|id', kind:'head'|'row', sec, item}
  let sel = null, zone = 'list';         // 고른 줄 · 키보드가 가는 곳('list' | 'detail')
  let detail = null, detailId = null, detailLoading = false, detailErr = '', dseq = 0, dtimer = 0, cardSel = 0;
  const dcache = new Map();              // id → workMapDetail 응답 (새로 읽는 동안 먼저 보여 준다)
  let plan = null, planOpen = false, planErr = '', planLoading = false, pseq = 0, planSelId = null, planFocusGroup = '', planCards = [];
  let busy = false, note = null, wantPlan = false, refreshTimer = 0;
  // Claude 정리 계획(aiDigest tidy)
  const AI = () => window.SynapseAI || null;
  let aiRes = null, aiStat = null, aiOffs = [], aiSeq = 0;

  const E = v => api.esc(v == null ? '' : String(v));
  const ic = n => { try { return api.icon(n) || ''; } catch (_) { return ''; } };
  const num = n => Number(n || 0).toLocaleString('ko-KR');
  const cut = (s, n) => { s = String(s == null ? '' : s).replace(/\s+/g, ' ').trim(); return s.length > n ? s.slice(0, n - 1) + '…' : s; };

  function loadPref() {
    const d = { collapsed: {} };
    try {
      const v = JSON.parse(localStorage.getItem(STORE_KEY) || 'null');
      if (v && v.collapsed && typeof v.collapsed === 'object') Object.keys(v.collapsed).forEach(k => { if (typeof v.collapsed[k] === 'boolean') d.collapsed[k] = v.collapsed[k]; });
    } catch (_) { /* 저장소를 못 읽어도 기본값으로 */ }
    return d;
  }
  function savePref() { try { localStorage.setItem(STORE_KEY, JSON.stringify(pref)); } catch (_) { /* 저장하지 못해도 화면은 그대로 */ } }

  async function call(method, params) {
    try { return await api.call(method, params || {}); } catch (e) { return { ok: false, error: (e && e.message) || '처리하지 못했어요' }; }
  }
  const failed = r => !r || typeof r !== 'object' || r.ok === false;
  // 다시 그려도 키보드 포커스를 잃지 않게: 포커스 요소의 data-* 로 찾아 되돌린다
  function keepFocus(box, fn) {
    const a = document.activeElement; let q = '';
    if (a && box && a !== box && box.contains(a)) {
      for (const at of Array.from(a.attributes)) if (at.name.indexOf('data-') === 0) q += '[' + at.name + '="' + String(at.value).replace(/["\\]/g, '\\$&') + '"]';
    }
    fn();
    if (q) { const n = box.querySelector(q); if (n && !n.disabled) n.focus({ preventScroll: true }); }
  }

  function init(a) { api = a; const ai = AI(); if (ai) ai.init(a); }

  // =====================================================================
  // 붙이기 · 떼기
  // =====================================================================
  function mount(l, r) {
    if (!api) return;
    unmount();
    listEl = l; readerEl = r || null;
    root = document.createElement('div');
    root.className = 'wm';
    root.innerHTML = '<div class="wm-bar" data-r="bar" role="group" aria-label="작업 지도 도구"></div><div class="wm-note-wrap" data-r="note"></div>' +
      '<div class="wm-main" data-r="main"><div class="wm-scroll" data-r="scroll" tabindex="0" role="tree" aria-label="작업 지도"></div>' +
      '<section class="wm-plan" data-r="plan" tabindex="-1" role="region" aria-label="정리 계획" hidden></section></div>';
    listEl.textContent = '';
    listEl.appendChild(root);
    barEl = root.querySelector('[data-r="bar"]'); noteEl = root.querySelector('[data-r="note"]');
    mainEl = root.querySelector('[data-r="main"]'); scrollEl = root.querySelector('[data-r="scroll"]'); planEl = root.querySelector('[data-r="plan"]');
    if (readerEl) {
      readerEl.textContent = '';
      dtEl = document.createElement('div'); dtEl.className = 'wm-dt'; dtEl.setAttribute('role', 'region'); dtEl.setAttribute('aria-label', '상세');
      readerEl.appendChild(dtEl);
      dtEl.addEventListener('click', onClick);
    }
    root.addEventListener('click', onClick);
    root.addEventListener('dblclick', onDblClick);
    planOpen = wantPlan; wantPlan = false;
    zone = 'list'; busy = false;
    const ai = AI();
    aiStat = ai ? ai.cached() : null; aiRes = null;
    if (ai) {
      ai.bindRefs(root);
      aiOffs = [ai.on('digest', onAIDigest), ai.on('status', onAIStatus)];
    }
    renderAll();
    load();
    aiLoad('auto');
    if (planOpen) loadPlan();
  }
  function unmount() {
    seq++; pseq++; dseq++; aiSeq++; clearTimeout(dtimer); clearTimeout(refreshTimer); refreshTimer = 0;
    aiOffs.forEach(off => { try { off(); } catch (_) { /* 이미 풀렸다 */ } });
    aiOffs = [];
    if (root && root.parentNode) root.parentNode.removeChild(root);
    if (dtEl && dtEl.parentNode) dtEl.parentNode.removeChild(dtEl);
    root = barEl = noteEl = mainEl = scrollEl = planEl = listEl = readerEl = dtEl = null;
    data = null; plan = null; detail = null; detailId = null; busy = false; nav = [];
  }
  function focus() { const f = planOpen ? planEl : scrollEl; if (f) f.focus({ preventScroll: true }); }
  // 홈 한 줄·리뷰 카드에서 "정리 계획"으로 들어올 때: 아직 안 붙었으면 붙을 때 열고, 붙어 있으면 바로 연다
  function openPlan(group) {
    if (!root) { wantPlan = true; planFocusGroup = group || ''; return; }
    openPlanPanel(group);
  }

  // 사서 이벤트(tidy·pending·home)가 몰려 와도 1초에 한 번만 다시 읽는다
  function refresh() {
    if (!api || !root || refreshTimer) return;
    refreshTimer = setTimeout(() => { refreshTimer = 0; if (!root) return; dcache.clear(); load(); if (planOpen) loadPlan(); if (sel) loadDetail(0); }, 1000);
  }

  // =====================================================================
  // 불러오기
  // =====================================================================
  async function load() {
    if (!api || !root) return;
    const my = ++seq;
    loading = !data;
    if (loading) renderList();
    const r = await call('workMap', {});
    if (my !== seq || !root) return;
    loading = false;
    if (failed(r) || !Array.isArray(r.sections)) { loadError = (r && r.error) || '불러오지 못했어요'; if (!data) data = null; }
    else { loadError = null; data = r; }
    buildNav();
    renderBar(); renderList(); renderDetail();
    if (sel && !detailId) loadDetail(0);
  }
  async function loadPlan() {
    if (!api || !root) return;
    const my = ++pseq;
    planLoading = !plan;
    if (planLoading) renderPlan();
    const r = await call('tidyPlan', {});
    if (my !== pseq || !root) return;
    planLoading = false;
    if (failed(r)) { planErr = (r && r.error) || '정리 계획을 불러오지 못했어요'; }
    else { planErr = ''; plan = r; }
    renderPlan(); renderDetail();
  }

  // ---------- Claude 정리 계획 ----------
  async function aiLoad(run) {
    const ai = AI(); if (!ai || !root) return;
    const my = ++aiSeq;
    const r = await ai.digest('tidy', { run, auto: run === 'auto' });
    if (my !== aiSeq || !root) return;
    aiRes = r; aiStat = ai.cached();
    renderBar(); if (planOpen) renderPlan();
  }
  function aiRunning() {
    if (aiRes && aiRes.running) return true;
    const st = aiStat;
    return !!(st && Array.isArray(st.running) && st.running.some(r => r && r.digestKind === 'tidy'));
  }
  const aiReady = () => { try { return !!(api && typeof api.aiAvailable === 'function' && api.aiAvailable()); } catch (_) { return false; } };
  function onAIDigest(e) {
    if (!root || !e || e.kind !== 'tidy') return;
    aiLoad('none');
    dcache.clear(); load(); loadPlan();
  }
  function onAIStatus(e, st) {
    if (!root) return;
    aiStat = st || (AI() && AI().cached());
    renderBar(); if (planOpen) renderPlan();
  }
  function regen() {
    if (aiRunning()) return;
    if (!aiReady()) { api.toast('Claude를 쓸 수 없어요 · 설정에서 확인해 주세요', 'error'); return; }
    aiLoad('force');
    api.toast('Claude에게 정리 계획을 만들어 달라고 했어요');
  }

  // =====================================================================
  // 목록 모양 만들기
  // =====================================================================
  function secCollapsed(sec) {
    const k = sec.key;
    return Object.prototype.hasOwnProperty.call(pref.collapsed, k) ? !!pref.collapsed[k] : sec.collapsed === true;
  }
  function buildNav() {
    const out = [];
    if (data && Array.isArray(data.sections)) data.sections.forEach(sec => {
      const items = Array.isArray(sec.items) ? sec.items : [];
      if (!items.length && !sec.more) return;
      out.push({ nav: 's|' + sec.key, kind: 'head', sec });
      if (!secCollapsed(sec)) items.forEach(it => out.push({ nav: 'r|' + it.id, kind: 'row', sec, item: it }));
    });
    nav = out;
    if (!nav.some(n => n.nav === sel)) {
      // 줄이 접힌 구역 안으로 들어갔으면 그 구역 머리로, 아니면 첫 줄
      let to = null;
      if (sel && sel.indexOf('r|') === 0 && data) {
        const id = sel.slice(2);
        const sec = (data.sections || []).find(s => (s.items || []).some(i => i.id === id));
        if (sec && nav.some(n => n.nav === 's|' + sec.key)) to = 's|' + sec.key;
      }
      if (!to) { const r = nav.find(n => n.kind === 'row'); to = r ? r.nav : nav[0] ? nav[0].nav : null; }
      sel = to;
    }
  }
  const curNav = () => nav.find(n => n.nav === sel) || null;
  const curRow = () => { const n = curNav(); return n && n.kind === 'row' ? n.item : null; };

  // 건강 점: ● fresh · ◐ warm · ○ stale · ⚠ messy · ❄ frozen (모양이 다르다 — 색에만 기대지 않는다)
  function healthIcon(h) {
    const a = '<svg viewBox="0 0 12 12" width="12" height="12" aria-hidden="true">';
    if (h === 'fresh') return a + '<circle cx="6" cy="6" r="4.2" fill="currentColor"/></svg>';
    if (h === 'warm') return a + '<circle cx="6" cy="6" r="4.2" fill="none" stroke="currentColor" stroke-width="1.4"/><path d="M6 1.8a4.2 4.2 0 0 1 0 8.4z" fill="currentColor"/></svg>';
    if (h === 'stale') return a + '<circle cx="6" cy="6" r="4.2" fill="none" stroke="currentColor" stroke-width="1.4"/></svg>';
    if (h === 'frozen') return a + '<path d="M6 1.5v9M2.1 3.75l7.8 4.5M2.1 8.25l7.8-4.5" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/></svg>';
    return a + '<path d="M6 1.7 11 10.3H1z" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round"/><path d="M6 5v2.4M6 8.7v.1" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/></svg>';
  }
  function statusShape(g) {
    if (g === 'waiting') return '<svg viewBox="0 0 12 12" width="12" height="12" aria-hidden="true"><circle cx="6" cy="6" r="4.4" fill="none" stroke="currentColor" stroke-width="1.4"/><path d="M6 3.5V6l1.7 1" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/></svg>';
    const c = window.SynapseCluster;
    return c && typeof c.shapeHtml === 'function' ? c.shapeHtml(g) : '<i class="wm-dot"></i>';
  }
  const lastTxt = it => it.lastLabel || '';

  function workRowHtml(n, i) {
    const it = n.item, on = n.nav === sel;
    const sg = it.statusGroup || 'doing';
    const folders = (it.folders || []).slice(0, 3);
    const pills = (it.split ? '<span class="wm-fp is-warn" title="같은 일의 폴더가 여러 곳에 갈라져 있어요">⚠ 갈라짐</span>' : '') +
      folders.map(f => '<span class="wm-fp" title="' + E(f.path) + '">' + ic('folder') + '<span>' + E(cut(f.label, 26)) + '</span></span>').join('') +
      ((it.folders || []).length > 3 ? '<span class="wm-fp">+' + ((it.folders || []).length - 3) + '</span>' : '');
    const aria = [it.key, it.title, it.status, it.next ? '다음 행동 ' + it.next : '', it.split ? '폴더가 갈라졌어요' : '', it.proposals ? '정리 제안 ' + it.proposals : ''].filter(Boolean).join(', ');
    return '<div class="wm-row wm-work st-' + E(sg) + (on ? ' is-sel' : '') + '" role="treeitem" aria-level="2" id="wm-n' + i + '" data-nav="' + E(n.nav) + '" aria-selected="' + on + '" aria-label="' + E(aria) + '">' +
      '<span class="wm-ico" aria-hidden="true">' + (it.type === 'thread' ? ic('list') : statusShape(sg)) + '</span>' +
      '<span class="wm-main2">' +
        '<span class="wm-l1">' + (it.key ? '<span class="wm-key">' + E(it.key) + '</span>' : '') + '<span class="wm-title">' + E(it.title) + '</span></span>' +
        (it.next ? '<span class="wm-l2" title="' + (it.nextSource === 'claude' ? 'Claude가 짚은 다음 행동' : '멈춘 곳') + '">' + (it.nextSource === 'claude' ? ic('sparkle') : '<i class="wm-arrow" aria-hidden="true">›</i>') + '<span>' + E(it.next) + '</span></span>' : '') +
        (pills ? '<span class="wm-l3">' + pills + '</span>' : '') +
      '</span>' +
      '<span class="wm-side">' +
        (it.proposals ? '<span class="wm-prop" title="정리 제안 ' + it.proposals + '개">' + ic('sparkle') + it.proposals + '</span>' : '') +
        (it.status ? '<span class="wm-st st-' + E(sg) + '">' + E(it.status) + '</span>' : '') +
        (it.dueLabel ? '<span class="wm-due' + (/지남|오늘|D-[0-3]\b|^[1-3]일/.test(it.dueLabel) ? ' is-hot' : '') + '">' + E(it.dueLabel) + '</span>' : '') +
        '<span class="wm-when">' + E(lastTxt(it)) + '</span>' +
      '</span></div>';
  }
  function placeRowHtml(n, i) {
    const it = n.item, on = n.nav === sel;
    const sub = [it.label, it.healthLabel].filter(Boolean);
    const meta = (it.files ? '파일 ' + num(it.files) : '') + (it.lastLabel ? (it.files ? ' · ' : '') + it.lastLabel : '');
    const aria = [it.name, HEALTH_LABEL[it.health] || '', it.healthLabel, it.proposals ? '정리 제안 ' + it.proposals : ''].filter(Boolean).join(', ');
    return '<div class="wm-row wm-place h-' + E(it.health || 'fresh') + (on ? ' is-sel' : '') + '" role="treeitem" aria-level="2" id="wm-n' + i + '" data-nav="' + E(n.nav) + '" aria-selected="' + on + '" aria-label="' + E(aria) + '">' +
      '<span class="wm-ico wm-hi" aria-hidden="true" title="' + E(HEALTH_LABEL[it.health] || '') + '">' + healthIcon(it.health) + '</span>' +
      '<span class="wm-main2"><span class="wm-l1"><span class="wm-title">' + E(it.name) + '</span>' +
        ((it.tickets || []).length ? (it.tickets || []).slice(0, 2).map(k => '<span class="wm-key is-quiet">' + E(k) + '</span>').join('') : '') + '</span>' +
        '<span class="wm-l2 is-plain"><span>' + E(sub.join(' · ')) + '</span></span></span>' +
      '<span class="wm-side">' + (it.proposals ? '<span class="wm-prop" title="정리 제안 ' + it.proposals + '개">' + ic('sparkle') + it.proposals + '</span>' : '') +
        '<span class="wm-when">' + E(meta) + '</span></span></div>';
  }
  function headHtml(n, i) {
    const sec = n.sec, open = !secCollapsed(sec), on = n.nav === sel, cnt = (sec.items || []).length;
    return '<div class="wm-sh' + (on ? ' is-sel' : '') + (open ? '' : ' is-closed') + '" role="treeitem" aria-level="1" aria-expanded="' + open + '" id="wm-n' + i + '" data-nav="' + E(n.nav) + '" data-sec="' + E(sec.key) + '" aria-selected="' + on + '" aria-label="' + E(sec.title + ' ' + cnt + '개 ' + (open ? '펼쳐짐' : '접힘')) + '">' +
      '<span class="wm-caret" aria-hidden="true">' + ic('hide') + '</span><span class="wm-sh-t">' + E(sec.title) + '</span><b class="num">' + cnt + '</b>' +
      (sec.more ? '<span class="wm-sh-more">+' + num(sec.more) + '</span>' : '') +
      '<span class="wm-sh-k" aria-hidden="true">' + (open ? '←' : '→') + '</span></div>';
  }
  function renderList() {
    if (!scrollEl) return;
    const top = scrollEl.scrollTop;
    let h = '';
    if (loading && !data) h = '<div class="wm-state"><i class="spinner lg"></i><span>작업 지도를 그리는 중이에요</span></div>';
    else if (!data) h = '<div class="wm-state is-error"><strong>작업 지도를 열지 못했어요</strong><span>' + E(loadError || '') + '</span><button class="btn sm" type="button" data-act="retry">다시 시도</button></div>';
    else if (!nav.length) {
      const msg = data.empty || '보여 줄 항목이 없어요';
      h = '<div class="wm-state"><strong>' + E(msg) + '</strong>' + (data.scope && data.scope !== 'all' ? '<span>범위를 \'전체\'로 바꾸면 더 보여요.</span>' : '') + '</div>';
    } else {
      nav.forEach((n, i) => {
        if (n.kind === 'head') {
          h += (i ? '</div>' : '') + '<div class="wm-sec">' + headHtml(n, i);
          const sec = n.sec;
          if (sec.more && secCollapsed(sec) === false && !(sec.items || []).length) h += '';
        } else h += n.item.type === 'place' ? placeRowHtml(n, i) : workRowHtml(n, i);
        const next = nav[i + 1];
        if ((!next || next.kind === 'head') && n.sec.more > 0 && !secCollapsed(n.sec)) h += '<button type="button" class="wm-more" data-act="more-tickets">' + ic('ticket') + '<span>' + num(n.sec.more) + '개 더 있어요 · 티켓 화면에서 보기</span></button>';
      });
      h += '</div>';
    }
    keepFocus(scrollEl, () => { scrollEl.innerHTML = h; });
    scrollEl.scrollTop = top;
    paintSel(false);
  }
  function paintSel(scroll) {
    if (!scrollEl) return;
    const idx = nav.findIndex(n => n.nav === sel);
    scrollEl.querySelectorAll('[data-nav]').forEach(n => {
      const on = n.dataset.nav === sel;
      n.classList.toggle('is-sel', on); n.setAttribute('aria-selected', String(on));
      if (on) { scrollEl.setAttribute('aria-activedescendant', n.id); if (scroll && n.scrollIntoView) n.scrollIntoView({ block: 'nearest' }); }
    });
    if (idx < 0) scrollEl.removeAttribute('aria-activedescendant');
    scrollEl.classList.toggle('is-zone', zone === 'list');
  }

  // =====================================================================
  // 머리 (정리 상태 칩 · 정리 계획 · 범위 · 그래프)
  // =====================================================================
  function renderBar() {
    if (!barEl) return;
    const t = (data && data.tidy) || {}, c = t.counts || {}, pend = Number(t.pending) || 0;
    const chip = (k, label, n, tip) => n > 0 ? '<button type="button" class="wm-chip" data-act="chip" data-chip="' + k + '" title="' + E(tip) + '"><span>' + E(label) + '</span><b class="num">' + num(n) + '</b></button>' : '';
    const chips = chip('loose', '정리 안 됨', (Number(c.loose) || 0) + (Number(c.inbox) || 0), '데스크톱·받은 문서함에 흩어진 것 · 누르면 그 구역으로 가요') +
      chip('stale', '오래된 프로젝트', Number(c.stale) || 0, '30일 넘게 손대지 않은 프로젝트') +
      chip('raw', '원자료', Number(c.raw) || 0, '색인에서 뺄 수 있는 원자료 폴더 · 누르면 정리 계획이 열려요') +
      chip('split', '갈라진 티켓', Number(c.split) || 0, '같은 티켓의 폴더가 여러 곳에 있어요 · 누르면 정리 계획이 열려요');
    const review = t.review && t.review.label
      ? '<button type="button" class="wm-review" data-act="plan" title="한 주를 정리하는 리뷰예요 · 누르면 정리 계획이 열려요">' + ic('calendar') + '<span>' + E(t.review.label) + '</span></button>' : '';
    const running = aiRunning();
    const scope = (data && data.scope) || 'all';
    const seg = '<div class="bw-seg wm-seg" role="group" aria-label="범위">' + SCOPES.map(([v, l]) =>
      '<button type="button" data-act="scope" data-scope="' + v + '" aria-pressed="' + (scope === v) + '"' + (v === 'all' ? ' title="업무와 개인 모두"' : v === 'work' ? ' title="업무(Jira·회사 폴더)만"' : ' title="개인 폴더만"') + '>' + l + '</button>').join('') + '</div>';
    const planBtn = '<button type="button" class="btn sm wm-plan-btn' + (planOpen ? ' is-on' : '') + '" data-act="plan" aria-pressed="' + planOpen + '" title="정리 계획 · p">' +
      (running ? '<i class="spinner" role="img" aria-label="Claude가 계획을 만드는 중"></i>' : ic('sparkle')) + '<span>정리 계획' + (pend > 0 ? ' <b class="num">' + num(pend) + '</b>' : '') + '</span><kbd>p</kbd></button>';
    const graphBtn = '<button type="button" class="btn sm" data-act="graph" title="그래프로 보기 · ⌥⌘2">' + ic('graph') + '<span>그래프</span></button>';
    const quiet = !chips && !review ? '<span class="wm-calm">' + ic('check') + '<span>정리할 것이 없어요</span></span>' : '';
    const html = '<div class="wm-bar-l">' + review + chips + quiet + '</div><div class="wm-bar-r">' + seg + planBtn + graphBtn + '</div>';
    keepFocus(barEl, () => { barEl.innerHTML = html; });
  }
  function renderNote() {
    if (!noteEl) return;
    if (!note) { noteEl.innerHTML = ''; return; }
    const undo = note.undo && note.undo.length;
    const s = '<div class="wm-note' + (note.tone === 'error' ? ' is-error' : '') + '" role="status"><div class="wm-note-t">' + E(note.text) + '</div>' +
      (note.skipped && note.skipped.length ? '<ul class="wm-skips">' + note.skipped.map(k => '<li><b>' + E(k.title) + '</b> ' + E(k.reason) + '</li>').join('') + '</ul>' : '') +
      '<div class="wm-note-b">' + (undo ? '<button class="btn sm" type="button" data-act="undo-note">' + ic('undo') + '<span>' + (note.undo.length > 1 ? '모두 되돌리기' : '되돌리기') + '</span><kbd>⌥⌘Z</kbd></button>' : '') +
      '<button class="icon-btn sm" type="button" data-act="note-x" aria-label="알림 닫기">' + ic('x') + '</button></div></div>';
    keepFocus(noteEl, () => { noteEl.innerHTML = s; });
  }
  function renderAll() { renderBar(); renderNote(); renderList(); renderPlan(); renderDetail(); }

  // =====================================================================
  // 오른쪽 상세
  // =====================================================================
  function selectNav(id, o) {
    o = o || {};
    if (!nav.some(n => n.nav === id)) return;
    const changed = id !== sel;
    sel = id;
    if (changed) { cardSel = 0; zone = 'list'; }
    paintSel(o.scroll !== false);
    if (!changed && !o.force) return;
    const r = curRow();
    if (!r) { detail = null; detailId = null; dseq++; clearTimeout(dtimer); renderDetail(); return; }
    // 이미 읽어 둔 상세가 있으면 먼저 보여 주고, 새로 읽는다
    const c = dcache.get(r.id);
    detail = c || null; detailId = c ? r.id : null; detailErr = '';
    renderDetail();
    loadDetail(o.now ? 0 : 90);
  }
  function loadDetail(wait) {
    clearTimeout(dtimer);
    const r = curRow();
    if (!r) return;
    const id = r.id, my = ++dseq;
    dtimer = setTimeout(async () => {
      detailLoading = !detail || detailId !== id; if (detailLoading) renderDetail();
      const d = await call('workMapDetail', { id });
      if (my !== dseq || !root) return;
      detailLoading = false;
      if (failed(d)) { detailErr = (d && d.error) || '상세를 불러오지 못했어요'; detail = null; detailId = null; }
      else { detailErr = ''; detail = d; detailId = id; dcache.set(id, d); if (dcache.size > 40) dcache.delete(dcache.keys().next().value); if (cardSel >= (d.proposals || []).length) cardSel = Math.max(0, (d.proposals || []).length - 1); }
      renderDetail();
    }, wait || 0);
  }
  const cardsOf = () => (detail && detailId && curRow() && curRow().id === detailId && Array.isArray(detail.proposals)) ? detail.proposals : [];
  const curCard = () => cardsOf()[cardSel] || null;

  function pathLine(c) {
    const from = (c.from || []);
    const f = from.length <= 1 ? E(cut(from[0] ? from[0].label : '', 60)) : E(cut(from[0].label, 40)) + ' 외 ' + (from.length - 1);
    const to = c.op === 'exclude' ? '색인에서 빼기' : c.op === 'trash' ? 'Synapse 휴지통' : c.op === 'note' ? '' : c.to ? E(cut(c.to.label, 44)) : c.op === 'archive' ? '4-Archive' : '';
    return '<span class="wm-pf" title="' + E(from.map(x => x.path).join('\n')) + '">' + f + '</span>' + (to ? '<i class="wm-pa" aria-hidden="true">→</i><span class="wm-pt" title="' + E(c.to ? c.to.path : '') + '">' + to + '</span>' : '');
  }
  function certChip(c) { return '<span class="wm-cert" data-c="' + E(c.certainty) + '">' + E(CERT[c.certainty] || '') + '</span>'; }
  function originChip(c) { return '<span class="bx-src" data-o="' + (c.origin === 'claude' ? 'claude' : 'rules') + '">' + E(c.originLabel || (c.origin === 'claude' ? 'Claude' : '규칙')) + '</span>'; }
  function warnHtml(c) {
    const im = c.impact || {}, w = (im.warnings || []).map(x => '<div class="wm-warn">' + ic('alert') + '<span>' + E(x) + '</span></div>').join('');
    return (im.links > 0 ? '<div class="wm-imp">' + ic('follow') + '<span>링크 ' + E(im.links) + '개를 새 위치에 맞춰 고쳐요</span></div>' : '') + w;
  }
  function actionsHtml(c, i, compact) {
    const dis = busy ? ' disabled' : '';
    const kb = k => compact ? '' : '<kbd>' + k + '</kbd>';
    if (c.op === 'note') return '<button class="btn sm primary" type="button" data-act="card" data-do="dismiss" data-i="' + i + '"' + dis + '>확인' + kb('y') + '</button>' +
      '<button class="btn sm" type="button" data-act="card" data-do="later" data-i="' + i + '"' + dis + '>나중에' + kb('s') + '</button>';
    const label = c.op === 'trash' ? '휴지통으로' : c.op === 'exclude' ? '색인에서 빼기' : '승인';
    return '<button class="btn sm primary' + (c.op === 'trash' ? ' danger' : '') + '" type="button" data-act="card" data-do="approve" data-i="' + i + '"' + dis + '>' + label + kb('y') + '</button>' +
      '<button class="btn sm" type="button" data-act="card" data-do="reject" data-i="' + i + '"' + dis + '>거절' + kb('n') + '</button>' +
      '<button class="btn sm" type="button" data-act="card" data-do="later" data-i="' + i + '"' + dis + '>나중에' + kb('s') + '</button>' +
      (c.op === 'exclude' || c.op === 'trash' ? '' : '<button class="btn sm" type="button" data-act="card" data-do="edit" data-i="' + i + '"' + dis + '>자리 바꾸기' + kb('e') + '</button>');
  }
  function miniCardHtml(c, i) {
    const on = i === cardSel;
    return '<article class="wm-mc' + (on ? ' is-sel' : '') + '" data-i="' + i + '" data-act="card-sel" aria-label="' + E(c.title) + '">' +
      '<div class="wm-c1"><span class="wm-oi" aria-hidden="true">' + ic(OP_ICON[c.op] || 'doc') + '</span><b class="wm-ct">' + E(c.title) + '</b></div>' +
      '<div class="wm-path">' + pathLine(c) + '</div>' +
      '<div class="wm-chips">' + certChip(c) + originChip(c) + '</div>' +
      (c.reason ? '<p class="wm-why">' + E(c.reason) + '</p>' : '') + warnHtml(c) +
      '<div class="wm-acts">' + actionsHtml(c, i, false) + '</div></article>';
  }
  function sectionHtml(title, body, cnt, cls) {
    return body ? '<section class="wm-ds' + (cls ? ' ' + cls : '') + '"><h3 class="wm-dh">' + E(title) + (cnt != null ? ' <b class="num">' + num(cnt) + '</b>' : '') + '</h3>' + body + '</section>' : '';
  }
  function renderDetail() {
    if (!dtEl) return;
    const n = curNav();
    let h = '';
    if (planOpen) { dtEl.innerHTML = planPreviewHtml(); dtEl.classList.remove('is-zone'); return; }
    if (!n) h = '<div class="wm-dt-empty">' + ic('workmap') + '<span>줄을 고르면 요약·폴더·문서·정리 제안이 여기에 보여요</span></div>';
    else if (n.kind === 'head') {
      const sec = n.sec, cnt = (sec.items || []).length;
      h = '<div class="wm-dt-empty">' + ic('list') + '<strong>' + E(sec.title) + ' ' + cnt + '개</strong><span>' + (secCollapsed(sec) ? '→ 키로 펼쳐요' : '← 키로 접어요') + ' · ↑↓로 줄을 골라요</span></div>';
    } else if (detailLoading && (!detail || detailId !== n.item.id)) h = '<div class="wm-dt-empty"><i class="spinner lg"></i><span>불러오는 중이에요</span></div>';
    else if (detailErr) h = '<div class="wm-dt-empty is-error"><strong>상세를 열지 못했어요</strong><span>' + E(detailErr) + '</span><button class="btn sm" type="button" data-act="detail-retry">다시 시도</button></div>';
    else if (!detail || detailId !== n.item.id) h = '<div class="wm-dt-empty"><i class="spinner lg"></i><span>불러오는 중이에요</span></div>';
    else h = detailHtml(detail, n.item);
    keepFocus(dtEl, () => { dtEl.innerHTML = h; });
    dtEl.classList.toggle('is-zone', zone === 'detail');
    const mc = dtEl.querySelector('.wm-mc.is-sel'); if (mc && zone === 'detail' && mc.scrollIntoView) mc.scrollIntoView({ block: 'nearest' });
  }
  function detailHtml(d, row) {
    const isPlace = d.type === 'place';
    const st = d.status ? '<span class="wm-st st-' + E(row.statusGroup || 'doing') + '">' + E(d.status) + '</span>' : '';
    const head = '<div class="wm-dt-h"><div class="wm-dt-k">' + (d.key ? '<span class="wm-key">' + E(d.key) + '</span>' : '<span class="wm-dt-kind">' + E(isPlace ? (ZONE_LABEL[row.zone] || '폴더') : '흐름') + '</span>') + st +
      (isPlace && row.health ? '<span class="wm-hp h-' + E(row.health) + '">' + healthIcon(row.health) + '<span>' + E(row.healthLabel || HEALTH_LABEL[row.health] || '') + '</span></span>' : '') + '</div>' +
      '<h2 class="wm-dt-t">' + E(d.title) + '</h2></div>';
    const summary = d.summary ? '<p class="wm-sum">' + (d.type !== 'place' ? ic('sparkle') : '') + '<span>' + E(d.summary) + '</span></p>' : '';
    const next = d.next ? '<div class="wm-next"><span class="wm-next-l">다음 행동</span><span class="wm-next-t">' + E(d.next) + '</span></div>' : '';
    const facts = (d.facts || []).length ? '<ul class="wm-facts">' + d.facts.map(f => '<li>' + E(f) + '</li>').join('') + '</ul>' : '';
    const fl = d.folders || [];
    const split = fl.length > 1 && (row.split || fl.filter(f => f.zone === 'loose').length);
    const folders = fl.length ? sectionHtml('폴더', (split ? '<div class="wm-warn">' + ic('alert') + '<span>같은 일의 폴더가 ' + fl.length + '곳에 갈라져 있어요</span></div>' : '') +
      fl.map((f, i) => '<button type="button" class="wm-li" data-act="reveal" data-i="' + i + '" title="Finder에서 보기 · ' + E(f.path) + '">' + ic('folder') + '<span class="wm-li-t">' + E(f.label) + '</span><span class="wm-li-m">' + (f.files != null ? '파일 ' + num(f.files) : '') + (f.lastLabel ? ' · ' + E(f.lastLabel) : '') + '</span>' + ic('reveal') + '</button>').join(''), fl.length) : '';
    const docs = (d.docs || []).length ? sectionHtml('문서', d.docs.map(x => '<button type="button" class="wm-li" data-act="open-doc" data-doc="' + E(x.docId) + '" title="리더에서 열기">' + ic('doc') + '<span class="wm-li-t">' + E(x.title) + '</span><span class="wm-li-m">' + E([x.label, x.lastLabel].filter(Boolean).join(' · ')) + '</span></button>').join(''), d.docs.length) : '';
    const ses = (d.sessions || []).length ? sectionHtml('세션', d.sessions.map(x => '<div class="wm-li is-static">' + ic('code') + '<span class="wm-li-t">' + E(x.title) + '</span><span class="wm-li-m">' + E(x.lastLabel || '') + '</span></div>').join(''), d.sessions.length) : '';
    const kids = (d.children || []).length ? sectionHtml('하위 폴더', d.children.map(x => '<div class="wm-li is-static">' + ic('folder') + '<span class="wm-li-t">' + E(x.name) + '</span><span class="wm-li-m">파일 ' + num(x.files) + (x.lastLabel ? ' · ' + E(x.lastLabel) : '') + '</span></div>').join(''), d.children.length) : '';
    const cards = cardsOf();
    const props = cards.length ? sectionHtml('정리 제안', cards.map(miniCardHtml).join('') + '<p class="wm-keys"><kbd>y</kbd> 승인 <kbd>n</kbd> 거절 <kbd>e</kbd> 자리 바꾸기 <kbd>⇥</kbd> 카드 이동</p>', cards.length, 'is-props') : '';
    const foot = '<div class="wm-dt-foot">' +
      (d.docId ? '<button class="btn sm primary" type="button" data-act="open-primary">' + ic('doc') + '<span>리더에서 열기</span><kbd>↵</kbd></button>' : '') +
      (d.url ? '<button class="btn sm" type="button" data-act="jira">' + ic('external') + '<span>Jira</span><kbd>⌘↵</kbd></button>' : (fl.length ? '<button class="btn sm" type="button" data-act="reveal" data-i="0">' + ic('reveal') + '<span>Finder</span><kbd>⌘↵</kbd></button>' : '')) +
      (d.graphDocId ? '<button class="btn sm" type="button" data-act="focus-graph">' + ic('graph') + '<span>연결 보기</span><kbd>g</kbd></button>' : '') + '</div>';
    const empty = !summary && !folders && !docs && !ses && !kids && !props ? '<p class="wm-none">보여 줄 내용이 아직 없어요</p>' : '';
    return head + foot + summary + next + facts + props + folders + docs + ses + kids + empty;
  }

  // ---------- 상세 동작 ----------
  function openPrimary() {
    const d = detail && detailId && curRow() && curRow().id === detailId ? detail : null;
    if (d && d.docId) { api.openDoc(String(d.docId)); return; }
    const r = curRow();
    if (r && r.docId) { api.openDoc(String(r.docId)); return; }
    api.toast('이 줄에는 열 문서가 없어요');
  }
  function openJiraOrFinder() {
    const d = detail && curRow() && detailId === curRow().id ? detail : null;
    if (d && d.url) { call('openURL', { url: d.url }).then(r => { if (failed(r)) api.toast((r && r.error) || '주소를 열지 못했어요', 'error'); }); return; }
    if (d && (d.folders || []).length) { reveal(d.folders[0]); return; }
    api.toast('열 수 있는 Jira나 폴더가 없어요');
  }
  async function reveal(f) {
    if (!f || !f.path) return;
    const r = await call('revealPath', { path: f.path });
    if (failed(r)) {   // 앱이 아직 revealPath를 모르면 경로를 복사해 준다
      if (typeof api.copyText === 'function') api.copyText(f.path, '경로를 복사했어요 · Finder에서 ⌘⇧G로 붙여 넣으면 열려요');
      else api.toast('Finder에서 열지 못했어요', 'error');
    }
  }
  function focusGraph() {
    const d = detail && curRow() && detailId === curRow().id ? detail : null;
    if (d && d.graphDocId && typeof api.follow === 'function') { api.follow(String(d.graphDocId)); return; }
    api.toast('연결 보기로 열 문서가 없어요');
  }

  // =====================================================================
  // 정리 계획 판
  // =====================================================================
  function openPlanPanel(group) {
    planFocusGroup = group || '';
    if (planOpen) { renderPlan(); scrollToGroup(); return; }
    planOpen = true; zone = 'list';
    renderBar(); renderPlan(); renderDetail();
    focus();
    loadPlan();
    aiLoad('none');
  }
  function closePlan() {
    if (!planOpen) return;
    planOpen = false;
    renderBar(); renderPlan(); renderDetail();
    focus();
  }
  function scrollToGroup() {
    if (!planEl || !planFocusGroup) return;
    const g = planEl.querySelector('[data-group="' + planFocusGroup + '"]');
    if (g && g.scrollIntoView) g.scrollIntoView({ block: 'start' });
    planFocusGroup = '';
  }
  const eligible = g => (g.items || []).filter(c => c.certainty !== 'unsure' && c.op !== 'trash' && c.op !== 'note');
  function planCardHtml(c, k) {
    const on = c.id === planSelId;
    const aria = [c.title, CERT[c.certainty], c.originLabel].filter(Boolean).join(', ');
    if (!on) {
      return '<article class="wm-pc" role="listitem" id="wm-pc' + k + '" data-pc="' + E(c.id) + '" data-act="pc-sel" aria-label="' + E(aria) + '">' +
        '<div class="wm-c1"><span class="wm-oi" aria-hidden="true">' + ic(OP_ICON[c.op] || 'doc') + '</span><b class="wm-ct">' + E(c.title) + '</b>' + certChip(c) + '</div>' +
        '<div class="wm-path is-sub">' + pathLine(c) + '</div></article>';
    }
    const ev = (c.evidence || []).length ? '<div class="wm-ev">' + c.evidence.map(x => '<span class="bx-chip">' + E(x) + '</span>').join('') + '</div>' : '';
    return '<article class="wm-pc is-sel" role="listitem" id="wm-pc' + k + '" data-pc="' + E(c.id) + '" aria-current="true" aria-label="' + E(aria) + '">' +
      '<div class="wm-c1"><span class="wm-oi" aria-hidden="true">' + ic(OP_ICON[c.op] || 'doc') + '</span><b class="wm-ct">' + E(c.title) + '</b></div>' +
      '<div class="wm-chips">' + certChip(c) + originChip(c) + '<span class="wm-opl">' + E(OP_LABEL[c.op] || '') + '</span></div>' +
      '<div class="wm-path">' + pathLine(c) + '</div>' +
      (c.reason ? '<p class="wm-why">' + E(c.reason) + '</p>' : '') + ev + warnHtml(c) +
      '<div class="wm-acts" data-pc="' + E(c.id) + '">' + planActions(c) + '</div></article>';
  }
  function planActions(c) {
    const dis = busy ? ' disabled' : '';
    const b = (d, label, key, cls) => '<button class="btn sm' + (cls ? ' ' + cls : '') + '" type="button" data-act="pc" data-do="' + d + '" data-id="' + E(c.id) + '"' + dis + '>' + label + '<kbd>' + key + '</kbd></button>';
    if (c.op === 'note') return b('dismiss', '확인', 'y', 'primary') + b('later', '나중에', 's');
    return b('approve', c.op === 'trash' ? '휴지통으로' : c.op === 'exclude' ? '색인에서 빼기' : '승인', 'y', 'primary' + (c.op === 'trash' ? ' danger' : '')) + b('reject', '거절', 'n') + b('later', '나중에', 's') +
      (c.op === 'exclude' || c.op === 'trash' ? '' : b('edit', '자리 바꾸기', 'e'));
  }
  function aiNoticeHtml() {
    const ai = AI(); if (!ai || !aiRes) return '';
    const r = Object.assign({}, aiRes, { what: '정리 계획을' });
    if (r.running) return '';
    if (r.blocked === 'manual' || r.blocked === 'cap') return '';   // 정리 계획이 있으면 굳이 알리지 않는다
    return ai.noticeHTML(r, api.esc) || '';
  }
  function renderPlan() {
    if (!planEl) return;
    planEl.hidden = !planOpen;
    scrollEl.hidden = planOpen;
    if (!planOpen) { planEl.innerHTML = ''; return; }
    const running = aiRunning();
    let h = '';
    const head = '<div class="wm-ph"><button class="btn sm" type="button" data-act="plan-close">' + ic('back') + '<span>작업 지도</span><kbd>esc</kbd></button>' +
      '<h2 class="wm-ph-t">정리 계획</h2><span class="wm-ph-m" aria-live="polite">' + (running ? '<i class="spinner" aria-hidden="true"></i>Claude가 계획을 만드는 중…'
        : plan && plan.lastRunLabel ? '마지막으로 만든 때 ' + E(plan.lastRunLabel) : '') + '</span>' +
      '<button class="btn sm wm-regen" type="button" data-act="regen"' + (running || !aiReady() ? ' disabled' : '') + ' title="' + (aiReady() ? 'Claude가 폴더를 다시 훑어 계획을 만들어요' : 'Claude를 쓸 수 없어요 · 설정에서 확인해 주세요') + '">' + ic('refresh') + '<span>다시 만들기</span></button></div>';
    if (planLoading && !plan) h = head + '<div class="wm-state"><i class="spinner lg"></i><span>정리 계획을 불러오는 중이에요</span></div>';
    else if (!plan) h = head + '<div class="wm-state is-error"><strong>정리 계획을 열지 못했어요</strong><span>' + E(planErr) + '</span><button class="btn sm" type="button" data-act="plan-retry">다시 시도</button></div>';
    else {
      planCards = [];
      (plan.groups || []).forEach(g => (g.items || []).forEach(c => planCards.push(c)));
      if (!planCards.some(c => c.id === planSelId)) planSelId = planCards[0] ? planCards[0].id : null;
      const auto = plan.auto === false ? '<div class="wm-banner">' + ic('info') + '<span>자동 정리가 꺼져 있어요. 모든 정리는 승인해야 해요.</span><button type="button" class="link-btn" data-act="settings">설정 열기</button></div>' : '';
      const sum = plan.summary ? '<p class="wm-sum is-plan">' + ic('sparkle') + '<span>' + E(plan.summary) + '</span></p>' : '';
      const notice = aiNoticeHtml();
      const prompts = (plan.prompts || []).map(p => '<div class="wm-learn" role="group" aria-label="자동으로 할지 정하기">' + ic('sparkle') +
        '<div class="wm-learn-t"><b>이런 정리를 ' + E(p.approvals || 3) + '번 승인했어요</b><span>' + E(p.label) + ' — 앞으로 자동으로 할까요?</span></div>' +
        '<div class="wm-learn-b"><button class="btn sm primary" type="button" data-act="promote" data-sig="' + E(p.signature) + '" data-accept="1">자동으로</button>' +
        '<button class="btn sm" type="button" data-act="promote" data-sig="' + E(p.signature) + '" data-accept="0">계속 물어봐</button></div></div>').join('');
      let k = 0;
      const groups = (plan.groups || []).map(g => {
        const el = eligible(g);
        return '<section class="wm-pg" data-group="' + E(g.key) + '" role="group" aria-label="' + E((g.title || GROUP_TITLE[g.key] || g.key) + ' ' + (g.items || []).length + '개') + '">' +
          '<div class="wm-pg-h"><h3>' + E(g.title || GROUP_TITLE[g.key] || g.key) + ' <b class="num">' + (g.items || []).length + '</b></h3>' +
          '<button class="btn sm" type="button" data-act="group" data-group="' + E(g.key) + '"' + (el.length && !busy ? '' : ' disabled') + ' title="확실하거나 아마 맞는 ' + el.length + '개를 차례로 승인해요 · 되돌릴 수 있어요">이 묶음 승인' + (el.length ? ' <b class="num">' + el.length + '</b>' : '') + '<kbd>⇧Y</kbd></button></div>' +
          '<div class="wm-pg-b" role="list">' + (g.items || []).map(c => planCardHtml(c, k++)).join('') + '</div></section>';
      }).join('');
      const none = !planCards.length ? '<div class="wm-state"><strong>지금 정리할 것이 없어요</strong><span>새 폴더나 파일이 생기면 규칙이 찾아서 여기에 올려요.</span>' +
        '<button class="btn sm" type="button" data-act="run-rules">' + ic('refresh') + '<span>지금 다시 보기</span></button></div>' : '';
      const autoList = (plan.autoToday || []);
      const used = plan.autoUsed != null ? plan.autoUsed : autoList.filter(a => !a.undone).length;
      const autos = autoList.length ? '<section class="wm-pg wm-auto" role="group" aria-label="오늘 자동으로 한 일"><div class="wm-pg-h"><h3>오늘 자동으로 한 일 <b class="num">' + used + (plan.autoCap ? '/' + plan.autoCap : '') + '</b></h3>' +
        (autoList.filter(a => !a.undone).length > 1 ? '<button class="btn sm" type="button" data-act="undo-all-auto"' + (busy ? ' disabled' : '') + '>' + ic('undo') + '<span>모두 되돌리기</span></button>' : '') + '</div><div class="wm-pg-b" role="list">' +
        autoList.map(a => '<div class="wm-au' + (a.undone ? ' is-undone' : '') + '" role="listitem"><div class="wm-au-t"><b>' + E(a.title) + '</b><span title="' + E(a.fromLabel) + '">' + E(cut(a.fromLabel, 40)) + '<i aria-hidden="true">→</i>' + E(cut(a.toLabel, 30)) + '</span></div>' +
          '<span class="wm-au-m">' + E(a.label || '') + '</span>' + (a.undone ? '<span class="wm-au-d">되돌렸어요</span>' : '<button class="btn sm" type="button" data-act="undo-auto" data-batch="' + E(a.batchId) + '"' + (busy ? ' disabled' : '') + '>되돌리기</button>') + '</div>').join('') + '</div></section>' : '';
      const qs = (plan.questions || []);
      const questions = qs.length ? '<section class="wm-pg wm-qs" role="group" aria-label="Claude 질문"><div class="wm-pg-h"><h3>Claude가 물어봐요 <b class="num">' + qs.length + '</b></h3></div><div class="wm-pg-b" role="list">' +
        qs.map((q, i) => '<div class="wm-q" role="listitem">' + ic('help') + '<span class="wm-q-t">' + E(q.text) + '</span><button class="btn sm" type="button" data-act="q-open" data-i="' + i + '">자리 열기</button></div>').join('') + '</div></section>' : '';
      h = head + '<div class="wm-pbody" data-r="pbody">' + auto + sum + notice + prompts + groups + none + autos + questions +
        '<p class="wm-keys"><kbd>↑</kbd><kbd>↓</kbd> 카드 이동 <kbd>y</kbd> 승인 <kbd>n</kbd> 거절 <kbd>s</kbd> 나중에 <kbd>e</kbd> 자리 바꾸기 <kbd>⇧Y</kbd> 묶음 승인 <kbd>esc</kbd> 닫기</p></div>';
    }
    const body = planEl.querySelector('[data-r="pbody"]'), top = body ? body.scrollTop : 0;
    keepFocus(planEl, () => { planEl.innerHTML = h; });
    const nb = planEl.querySelector('[data-r="pbody"]'); if (nb) nb.scrollTop = top;
    const s = planEl.querySelector('.wm-pc.is-sel'); if (s && s.scrollIntoView && planSelFresh) { s.scrollIntoView({ block: 'nearest' }); planSelFresh = false; }
    if (planFocusGroup) scrollToGroup();
  }
  let planSelFresh = false;
  function planPreviewHtml() {
    const c = planCards.find(x => x.id === planSelId);
    if (!c) return '<div class="wm-dt-empty">' + ic('sparkle') + '<span>정리 계획에서 카드를 고르면 영향받는 파일이 여기에 보여요</span></div>';
    const im = c.impact || {};
    const froms = (c.from || []).map(f => '<div class="wm-li is-static" title="' + E(f.path) + '">' + ic(f.isDir ? 'folder' : 'doc') + '<span class="wm-li-t">' + E(f.label) + '</span><span class="wm-li-m">' + (f.isDir ? '파일 ' + num(f.files) : '파일') + '</span></div>').join('');
    const to = c.op === 'exclude' ? '<p class="wm-pp">파일은 그대로 두고 검색과 지도에서만 빠져요. 설정의 형식·폴더에서 다시 켤 수 있어요.</p>'
      : c.op === 'trash' ? '<p class="wm-pp">Synapse 휴지통에 30일 보관해요. 정리 계획이나 AI 기록(⌘Y)에서 되살릴 수 있어요.</p>'
      : c.op === 'note' ? '<p class="wm-pp">Synapse는 이 파일을 열지도 옮기지도 않아요.</p>'
      : c.to ? '<div class="wm-li is-static" title="' + E(c.to.path) + '">' + ic('folder') + '<span class="wm-li-t">' + E(c.to.label) + '</span><span class="wm-li-m">' + (c.to.exists ? '있는 폴더' : '새로 만들어요') + '</span></div>' : '';
    return '<div class="wm-dt-h"><div class="wm-dt-k"><span class="wm-dt-kind">' + E(OP_LABEL[c.op] || '') + '</span>' + certChip(c) + originChip(c) + '</div><h2 class="wm-dt-t">' + E(c.title) + '</h2></div>' +
      sectionHtml('옮기기 전', froms, (c.from || []).length) + (to ? sectionHtml(c.op === 'archive' ? '보관할 곳' : '옮긴 뒤', to) : '') +
      '<section class="wm-ds"><h3 class="wm-dh">영향</h3><div class="wm-imp">' + ic('check') + '<span>파일 ' + num(im.files || 0) + '개' + (im.links > 0 ? ' · 링크 ' + num(im.links) + '개 고침' : ' · 고칠 링크는 없어요') + '</span></div>' + warnHtml(Object.assign({}, c, { impact: { warnings: im.warnings || [], links: 0 } })) +
      '<div class="wm-imp is-quiet">' + ic('undo') + '<span>' + (c.op === 'exclude' ? '되돌리면 색인에 다시 들어와요' : '승인한 뒤 되돌리기(⌥⌘Z)로 원래대로 돌릴 수 있어요') + '</span></div></section>' +
      (c.signatureLabel ? '<p class="wm-sigl">같은 종류 · ' + E(c.signatureLabel) + (c.canAuto ? '' : ' · 자동으로는 하지 않아요') + '</p>' : '');
  }

  // ---------- 결정 ----------
  function setBusy(v) { busy = v; if (root) root.classList.toggle('is-busy', v); }
  const findCard = id => { for (const g of ((plan && plan.groups) || [])) for (const c of (g.items || [])) if (c.id === id) return c; const d = cardsOf().find(c => c.id === id); return d || null; };
  async function pickDest(c) {
    if (c.op === 'exclude' || c.op === 'trash' || c.op === 'note') { api.toast('이 제안은 옮길 곳이 없어요'); return null; }
    const M = window.SynapseMenu;
    if (!M || typeof M.pick !== 'function') { api.toast('폴더 고르기 창을 열지 못했어요', 'error'); return null; }
    if (!plan || !plan.destinations) { const r = await call('tidyPlan', {}); if (!failed(r)) plan = r; }
    const dests = (plan && plan.destinations) || [];
    const items = dests.filter(d => d.path && (!c.to || d.path !== c.to.path) && !(c.from || []).some(f => d.path === f.path || d.path.indexOf(f.path + '/') === 0))
      .map(d => ({ value: d.path, label: d.label || d.path, hint: d.zone ? (ZONE_LABEL[d.zone] || '') : '코드 폴더' }));
    return M.pick({ title: '‘' + cut(c.title, 28) + '’ 어디로 옮길까요?', placeholder: '폴더 이름으로 찾기 (예: 운영, PROJ-123)', items, emptyText: '맞는 폴더가 없어요. 새 폴더는 Claude가 제안할 때만 만들어요' });
  }
  async function decideCard(c, action, to) {
    if (!c || busy) return;
    if (action === 'edit') { const p = await pickDest(c); if (!root) return; focus(); if (!p) return; return decideCard(c, 'to', p); }
    setBusy(true);
    renderPlan(); if (!planOpen) renderDetail();
    const r = await call('tidyDecide', to ? { id: c.id, action, to } : { id: c.id, action });
    if (!root) { busy = false; return; }
    report(c, action, r);
    setBusy(false);
    dcache.clear();
    await Promise.all([load(), planOpen || plan ? loadPlan() : Promise.resolve()]);
    if (sel && curRow()) loadDetail(0);
    focus();
  }
  function report(c, action, r) {
    if (failed(r)) { api.toast((r && r.error) || '처리하지 못했어요', 'error'); return; }
    const ap = r.applied;
    if (action === 'reject') { api.toast('거절했어요 · 같은 제안은 30일 동안 다시 안 보여 드려요'); return; }
    if (action === 'later') { api.toast('나중에 볼게요 · 7일 뒤 다시 나와요'); return; }
    if (action === 'dismiss') { api.toast('확인했어요'); return; }
    if (ap && ap.done > 0) {
      const verb = OP_DONE[c.op] || '정리했어요';
      api.toast(verb + (r.undoable ? ' · 되돌리기 ⌥⌘Z' : ''), undefined, 9000);
      note = { text: '‘' + cut(c.title, 40) + '’ ' + verb, undo: r.undoable && ap.batchId ? [ap.batchId] : [], skipped: ap.skipped || [] };
      if (r.prompt) api.toast('같은 정리를 ' + (r.prompt.approvals || 3) + '번 승인했어요 · 정리 계획에서 자동으로 할지 정해 주세요', undefined, 7000);
    } else if (ap && ap.skipped && ap.skipped.length) {
      api.toast('정리하지 못했어요 · 이유는 위에 있어요', 'error');
      note = { tone: 'error', text: '정리하지 못한 것이 있어요', undo: [], skipped: ap.skipped };
    } else api.toast('처리했어요');
    renderNote();
  }
  async function decideGroup(key) {
    if (busy || !plan) return;
    const g = (plan.groups || []).find(x => x.key === key); if (!g) return;
    const el = eligible(g), M = window.SynapseMenu;
    if (!el.length) { api.toast('승인할 수 있는 제안이 없어요 · 확인이 필요한 것은 하나씩 봐 주세요'); return; }
    const lines = ['확실하거나 아마 맞는 ' + el.length + '개를 차례로 승인해요', { text: '확인이 필요한 것·휴지통·알림은 빼고 남겨 둬요', warn: false }, '승인한 것은 모두 되돌릴 수 있어요 (⌥⌘Z, 정리 계획의 되돌리기)'];
    if (M && typeof M.confirm === 'function') {
      const ok = await M.confirm({ title: '‘' + (g.title || GROUP_TITLE[g.key]) + '’ 묶음을 승인할까요?', lines, confirmLabel: '승인하기', cancelLabel: '취소' });
      if (!root) return;
      if (!ok) { focus(); return; }
    }
    setBusy(true); renderPlan();
    const ids = el.map(c => c.id);   // 확인 창에서 보여 준 카드만 보낸다 — 그 사이 새로 생긴 제안은 승인하지 않는다
    const r = await call('tidyDecideGroup', { group: key, ids });
    if (!root) { busy = false; return; }
    setBusy(false);
    if (failed(r)) api.toast((r && r.error) || '묶음을 승인하지 못했어요', 'error');
    else {
      const batches = Array.isArray(r.batches) ? r.batches : [];
      const done = r.done || 0, skippedN = Math.max(0, ids.length - done);
      api.toast(done + '개 정리했어요' + (skippedN ? ' · ' + skippedN + '개는 건너뜀' : '') + (batches.length ? ' · 되돌리기 ⌥⌘Z' : ''), undefined, 9000);
      note = { text: (g.title || '묶음') + ' ' + done + '개를 정리했어요' + (skippedN ? ' · ' + skippedN + '개는 건너뛰었어요' : ''), undo: batches, skipped: r.skipped || [], tone: (r.done || 0) === 0 && (r.skipped || []).length ? 'error' : '' };
      renderNote();
    }
    dcache.clear();
    await Promise.all([load(), loadPlan()]);
    focus();
  }
  async function undoBatches(ids) {
    ids = (ids || []).filter(Boolean);
    if (!ids.length || busy) return;
    setBusy(true); renderPlan();
    let undone = 0; const conf = [];
    for (let i = ids.length - 1; i >= 0; i--) {
      const r = await call('tidyUndo', { batchId: ids[i] });
      if (!root) { busy = false; return; }
      if (failed(r)) { api.toast((r && r.error) || '되돌리지 못했어요', 'error'); continue; }
      undone += Number(r.undone) || 0;
      (r.conflicts || []).forEach(x => conf.push({ title: x.path, reason: x.reason }));
    }
    setBusy(false);
    if (conf.length) { api.toast('일부만 되돌렸어요 · 이미 바뀐 것 ' + conf.length + '개는 그대로 뒀어요', 'error'); note = { tone: 'error', text: '되돌리지 못한 것이 있어요. 덮어쓰지 않았어요.', undo: [], skipped: conf }; }
    else { api.toast('되돌렸어요 · ' + undone + '개'); note = null; }
    renderNote();
    dcache.clear();
    await Promise.all([load(), loadPlan()]);
    focus();
  }
  async function undoAllAuto() {
    const ids = [...new Set(((plan && plan.autoToday) || []).filter(a => !a.undone).map(a => a.batchId))];
    if (!ids.length) return;
    const M = window.SynapseMenu;
    if (M && typeof M.confirm === 'function') {
      const ok = await M.confirm({ title: '오늘 자동으로 한 ' + ids.length + '건을 모두 되돌릴까요?', lines: ['옮긴 파일을 원래 자리로 돌려놓고, 뺀 색인은 다시 넣어요', '같은 제안은 30일 동안 자동으로 다시 하지 않아요'], confirmLabel: '모두 되돌리기', cancelLabel: '취소' });
      if (!root) return;
      if (!ok) { focus(); return; }
    }
    undoBatches(ids);
  }
  async function promote(sig, accept) {
    if (busy) return;
    setBusy(true);
    const r = await call('tidyPromote', { signature: sig, accept });
    if (!root) { busy = false; return; }
    setBusy(false);
    const p = ((plan && plan.prompts) || []).find(x => x.signature === sig);
    if (failed(r)) api.toast((r && r.error) || '바꾸지 못했어요', 'error');
    else api.toast(accept ? '앞으로 ‘' + cut(p ? p.label : sig, 28) + '’은 자동으로 해요 · 설정에서 바꿀 수 있어요' : '계속 물어볼게요 · 다시 묻지 않아요', undefined, 6000);
    await loadPlan();
  }
  async function runRules() {
    if (busy) return;
    setBusy(true);
    const r = await call('tidyRunRules', {});
    if (!root) { busy = false; return; }
    setBusy(false);
    if (failed(r)) api.toast((r && r.error) || '다시 보지 못했어요', 'error');
    else api.toast((r.proposed || 0) > 0 ? '새 제안 ' + r.proposed + '개를 만들었어요' + (r.applied ? ' · 자동으로 ' + r.applied + '개 정리했어요' : '') : '새로 정리할 것은 없어요');
    dcache.clear();
    await Promise.all([load(), loadPlan()]);
  }
  function openQuestion(q) {
    if (!q) return;
    // 같은 자리가 작업 지도에 있으면 그 줄을 고르고, 없으면 Finder로
    const row = q.placeId && data ? (data.sections || []).reduce((a, s) => a || (s.items || []).find(i => i.id === q.placeId), null) : null;
    if (row) {
      const sec = (data.sections || []).find(s => (s.items || []).some(i => i.id === row.id));
      if (sec && secCollapsed(sec)) { pref.collapsed[sec.key] = false; savePref(); buildNav(); renderList(); }
      closePlan(); selectNav('r|' + row.id, { now: true });
      return;
    }
    if (q.path) reveal({ path: q.path });
  }

  // =====================================================================
  // 구역 접기 · 칩 · 클릭
  // =====================================================================
  function toggleSec(key, want) {
    const sec = (data && data.sections || []).find(s => s.key === key); if (!sec) return;
    const now = secCollapsed(sec), next = typeof want === 'boolean' ? want : !now;
    if (next === now) return;
    pref.collapsed[key] = next; savePref();
    buildNav(); renderList(); renderDetail();
  }
  function jumpSection(key) {
    const sec = (data && data.sections || []).find(s => s.key === key); if (!sec) return;
    if (secCollapsed(sec)) { pref.collapsed[key] = false; savePref(); buildNav(); renderList(); }
    const first = nav.find(n => n.kind === 'row' && n.sec.key === key) || nav.find(n => n.nav === 's|' + key);
    if (first) { if (planOpen) closePlan(); selectNav(first.nav, { now: true }); focus(); }
  }
  function onChip(k) {
    if (k === 'loose') jumpSection('unfiled');
    else if (k === 'stale') jumpSection('projects');
    else if (k === 'raw') openPlanPanel('index');
    else if (k === 'split') openPlanPanel('tickets');
  }
  async function setScope(v) {
    if (!data || data.scope === v) return;
    data.scope = v; renderBar();
    const r = await call('setBrainSetting', { key: 'workmap.scope', value: v });
    if (failed(r)) api.toast((r && r.error) || '범위를 바꾸지 못했어요', 'error');
    dcache.clear(); load();
  }
  function onClick(e) {
    if (!root) return;
    const t = e.target;
    if (t.closest('.ai-ref') && root.contains(t.closest('.ai-ref'))) return;
    const ac = t.closest('[data-ai-act]');
    if (ac && root.contains(ac)) { if (ac.dataset.aiAct === 'retry' || ac.dataset.aiAct === 'regen') { e.preventDefault(); aiLoad('force'); } return; }   // 설정 열기는 app.js가 맡는다
    const b = t.closest('[data-act]');
    if (b && !b.disabled) {
      const act = b.dataset.act;
      switch (act) {
        case 'scope': return setScope(b.dataset.scope);
        case 'plan': return planOpen ? closePlan() : openPlanPanel();
        case 'plan-close': return closePlan();
        case 'plan-retry': return loadPlan();
        case 'graph': return api.setMode('map');
        case 'chip': return onChip(b.dataset.chip);
        case 'retry': return load();
        case 'detail-retry': return loadDetail(0);
        case 'more-tickets': return api.setMode('tickets');
        case 'regen': return regen();
        case 'settings': return typeof api.openSettings === 'function' ? api.openSettings() : undefined;
        case 'open-doc': return api.openDoc(b.dataset.doc);
        case 'open-primary': return openPrimary();
        case 'jira': return openJiraOrFinder();
        case 'focus-graph': return focusGraph();
        case 'reveal': { const f = detail && (detail.folders || [])[+b.dataset.i]; return reveal(f); }
        case 'note-x': note = null; return renderNote();
        case 'undo-note': { const ids = note && note.undo; note = null; renderNote(); return undoBatches(ids); }
        case 'undo-auto': return undoBatches([b.dataset.batch]);
        case 'undo-all-auto': return undoAllAuto();
        case 'promote': return promote(b.dataset.sig, b.dataset.accept === '1');
        case 'run-rules': return runRules();
        case 'q-open': return openQuestion(((plan && plan.questions) || [])[+b.dataset.i]);
        case 'group': return decideGroup(b.dataset.group);
        case 'pc': { const c = findCard(b.dataset.id); planSelId = b.dataset.id; return decideCard(c, b.dataset.do); }
        case 'card': { const i = +b.dataset.i; cardSel = i; zone = 'detail'; return decideCard(cardsOf()[i], b.dataset.do); }
        case 'card-sel': break;   // 아래에서 처리
      }
    }
    const pc = t.closest('[data-pc]');
    if (pc && planEl && planEl.contains(pc) && !t.closest('button')) { if (planSelId !== pc.dataset.pc) { planSelId = pc.dataset.pc; planSelFresh = false; renderPlan(); renderDetail(); } return; }
    const mc = t.closest('.wm-mc');
    if (mc && dtEl && dtEl.contains(mc) && !t.closest('button')) { cardSel = +mc.dataset.i; zone = 'detail'; renderDetail(); return; }
    const hd = t.closest('.wm-sh');
    if (hd && scrollEl && scrollEl.contains(hd)) { selectNav(hd.dataset.nav, { now: true, scroll: false }); toggleSec(hd.dataset.sec); focus(); return; }
    const row = t.closest('.wm-row');
    if (row && scrollEl && scrollEl.contains(row)) { selectNav(row.dataset.nav, { now: true, scroll: false }); focus(); }
  }
  function onDblClick(e) {
    const row = e.target.closest && e.target.closest('.wm-row');
    if (row && scrollEl && scrollEl.contains(row)) { selectNav(row.dataset.nav, { now: true, scroll: false }); openPrimary(); }
  }

  // =====================================================================
  // 키
  // =====================================================================
  function move(d) {
    if (!nav.length) return;
    let i = nav.findIndex(n => n.nav === sel);
    i = Math.max(0, Math.min(nav.length - 1, (i < 0 ? (d > 0 ? 0 : nav.length - 1) : i + d)));
    selectNav(nav[i].nav);
  }
  function moveCard(d) {
    const n = cardsOf().length; if (!n) return;
    cardSel = Math.max(0, Math.min(n - 1, cardSel + d));
    renderDetail();
  }
  function movePlan(d) {
    if (!planCards.length) return;
    let i = planCards.findIndex(c => c.id === planSelId);
    i = Math.max(0, Math.min(planCards.length - 1, (i < 0 ? 0 : i + d)));
    planSelId = planCards[i].id; planSelFresh = true;
    renderPlan(); renderDetail();
  }
  function planKey(e) {
    const k = e.key;
    if (k === 'Escape') { e.preventDefault(); closePlan(); return true; }
    if (k === 'ArrowDown' || k === 'ArrowUp') { e.preventDefault(); movePlan(k === 'ArrowDown' ? 1 : -1); return true; }
    const ch = letter(e);
    if (!ch) return false;
    if (ch === 'p') { e.preventDefault(); if (!e.repeat) closePlan(); return true; }
    if (ch === 'j' || ch === 'k') { e.preventDefault(); movePlan(ch === 'j' ? 1 : -1); return true; }
    if ('ynse'.indexOf(ch) < 0) return false;
    e.preventDefault();
    if (e.repeat || busy) return true;
    const c = planCards.find(x => x.id === planSelId);
    if (!c) return true;
    if (ch === 'y' && e.shiftKey) {
      const g = ((plan && plan.groups) || []).find(x => (x.items || []).some(i => i.id === c.id));
      if (g) decideGroup(g.key);
      return true;
    }
    if (ch === 'y') decideCard(c, c.op === 'note' ? 'dismiss' : 'approve');
    else if (ch === 'n') decideCard(c, c.op === 'note' ? 'dismiss' : 'reject');
    else if (ch === 's') decideCard(c, 'later');
    else if (ch === 'e') decideCard(c, 'edit');
    return true;
  }
  function letter(e) {
    const k = e.key;
    return /^[a-zA-Z]$/.test(k) ? k.toLowerCase() : (/^Key[A-Z]$/.test(e.code || '') ? e.code.slice(3).toLowerCase() : '');
  }
  function onKey(e) {
    if (!root || !api || e.isComposing || e.keyCode === 229) return false;
    const k = e.key, a = document.activeElement;
    // ⌥⌘Z는 app.js가 맡는다(마지막 정리 배치가 tidy면 tidyUndo)
    if (e.metaKey && e.altKey) return false;
    if (e.metaKey && !e.ctrlKey && !e.shiftKey && k === 'Enter') { e.preventDefault(); if (!e.repeat) openJiraOrFinder(); return true; }
    if (e.metaKey || e.ctrlKey || e.altKey) return false;
    const typing = !!a && (a.tagName === 'INPUT' || a.tagName === 'TEXTAREA' || a.tagName === 'SELECT' || a.isContentEditable);
    if (typing) return false;
    // 목록·상세 안이나 바깥(body)에 포커스가 있을 때만 쓴다. 검색창 등 다른 곳이면 글자 키는 검색으로 간다.
    if (a && a !== document.body && !(root && root.contains(a)) && !(readerEl && readerEl.contains(a))) return false;
    // 버튼에 포커스가 있으면 ↵·Space는 그 버튼이 받는다
    if ((k === 'Enter' || k === ' ') && a && a.tagName === 'BUTTON') return false;
    if (planOpen) return planKey(e);
    if (k === 'Escape') {
      if (zone === 'detail') { zone = 'list'; renderDetail(); paintSel(false); return true; }
      return false;   // 목록에서는 app.js가 홈으로 보낸다
    }
    if (k === 'ArrowDown' || k === 'ArrowUp') { e.preventDefault(); if (zone === 'detail') moveCard(k === 'ArrowDown' ? 1 : -1); else move(k === 'ArrowDown' ? 1 : -1); return true; }
    if (k === 'ArrowLeft' || k === 'ArrowRight') {
      const n = curNav(); if (!n) return false;
      e.preventDefault();
      if (zone === 'detail') return true;
      toggleSec(n.sec.key, k === 'ArrowLeft');
      return true;
    }
    if (k === 'Tab') {
      e.preventDefault();
      if (zone === 'detail') { zone = 'list'; renderDetail(); paintSel(false); return true; }
      if (!cardsOf().length) { api.toast('이 줄에는 정리 제안이 없어요'); return true; }
      zone = 'detail'; cardSel = Math.min(cardSel, cardsOf().length - 1); renderDetail(); paintSel(false);
      return true;
    }
    if (k === 'Enter') {
      const n = curNav(); if (!n) return false;
      e.preventDefault();
      if (e.repeat) return true;
      if (n.kind === 'head') { toggleSec(n.sec.key); return true; }
      openPrimary(); return true;
    }
    const ch = letter(e);
    if (!ch) return false;
    if (ch === 'j' || ch === 'k') { e.preventDefault(); if (zone === 'detail') moveCard(ch === 'j' ? 1 : -1); else move(ch === 'j' ? 1 : -1); return true; }
    if (ch === 'p') { e.preventDefault(); if (!e.repeat) openPlanPanel(); return true; }
    if (ch === 'g') { e.preventDefault(); if (!e.repeat) focusGraph(); return true; }
    if ('yne'.indexOf(ch) >= 0) {
      e.preventDefault();
      if (e.repeat || busy) return true;
      const c = curCard();
      if (!c) { api.toast('이 줄에는 정리 제안이 없어요'); return true; }
      if (ch === 'y') decideCard(c, c.op === 'note' ? 'dismiss' : 'approve');
      else if (ch === 'n') decideCard(c, c.op === 'note' ? 'dismiss' : 'reject');
      else decideCard(c, 'edit');
      return true;
    }
    return false;
  }

  window.SynapseWorkMap = Object.freeze({ init, mount, refresh, onKey, focus, unmount, openPlan });
})();
