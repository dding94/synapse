// week.js — Synapse v0.5 이번 주 (docs/V05.md §9.7). window.SynapseWeek 하나만 만든다.
// mount(listEl, readerEl) · refresh(offset?) · onKey(e) → bool · unmount()  + init(api)
// v0.8 (docs/V08.md §8.2): 막대의 "Claude 정리 | 목록" 토글. Claude 정리는 window.SynapseAI(ai.js)의 aiDigest("week")를 그린다.
//   · 열 때·주를 바꿀 때 aiDigest(run:"auto") — 바뀐 게 있을 때만 백엔드가 새로 돌린다. 다시 정리 버튼은 run:"force".
//   · Claude를 쓸 수 없으면(꺼짐·없음·로그인 필요 …) 목록만 보이고 위에 한 줄 안내를 띄운다. 목록 보기·복사 실패 상자는 예전 그대로다.
(function () {
  'use strict';

  // 할 일 문구의 마크다운 기호를 화면용 글자로 정리한다: **굵게** __굵게__ `코드` [[링크|별칭]] [글자](주소) ~~취소~~
  const plain = s => String(s == null ? '' : s)
    .replace(/!?\[([^\]]*)\]\((?:[^()\s]|\([^)]*\))*(?:\s+"[^"]*")?\)/g, '$1')
    .replace(/\[\[([^\]]*)\]\]/g, (m, t) => { const i = t.indexOf('|'); return i >= 0 ? t.slice(i + 1) : t.replace(/#.*$/, ''); })
    .replace(/(\*\*|__)(.+?)\1/g, '$2').replace(/~~(.+?)~~/g, '$1').replace(/\*\*/g, '').replace(/`+([^`]*)`+/g, '$1')
    .replace(/^\s*[-*]\s+\[[ xX]\]\s+/, '').replace(/\s{2,}/g, ' ').trim();

  let api = null, listEl = null, readerEl = null, root = null, scrollEl = null;
  let offset = 0, data = null, loadError = null, loading = false, seq = 0, sel = -1;
  let opens = []; // 열 수 있는 줄·참조 칩 {docId, line}

  // v0.8 Claude 정리
  const VIEW_KEY = 'synapse.week.view.v1';
  const AI = () => window.SynapseAI || null;
  let view = loadView();              // 'claude' | 'list' — 마지막 선택(localStorage)
  let aiRes = null, aiStat = null;    // 지금 보는 주의 aiDigest 응답 · aiStatus
  let aiSeq = 0, aiOffs = [], evOpen = false;
  const aiByOff = new Map();          // offset → 마지막 응답 (탭을 다시 열 때 바로 보이게)
  function loadView() {
    try { const v = localStorage.getItem(VIEW_KEY); if (v === 'list' || v === 'claude') return v; } catch (_) { /* 저장소를 못 읽어도 기본값으로 */ }
    return 'claude';
  }
  function saveView() { try { localStorage.setItem(VIEW_KEY, view); } catch (_) { /* 저장하지 못해도 화면은 그대로 */ } }

  const E = v => api.esc(v == null ? '' : String(v));
  const ic = n => { try { return api.icon(n) || ''; } catch (_) { return ''; } };
  const SRC = { rules: '규칙', apple: '기기 AI', claude: 'Claude', codex: 'Codex' };
  const KIND_ICON = { task: 'check', issue: 'ticket', doc: 'doc' };

  function init(a) { api = a; const ai = AI(); if (ai) ai.init(a); }
  // 다시 그려도 키보드 포커스를 잃지 않게: 포커스 요소의 data-* 로 찾아 되돌린다
  function keepFocus(box, fn) {
    const a = document.activeElement; let q = '';
    if (a && box && a !== box && box.contains(a)) {
      for (const at of Array.from(a.attributes)) if (at.name.indexOf('data-') === 0) q += '[' + at.name + '="' + String(at.value).replace(/["\\]/g, '\\$&') + '"]';
    }
    fn();
    if (q) { const n = box.querySelector(q); if (n && !n.disabled) n.focus({ preventScroll: true }); }
  }
  function mount(l, r) {
    if (!api) return;
    unmount();
    listEl = l; readerEl = r || null;
    root = document.createElement('div');
    root.className = 'bw';
    root.innerHTML = '<div class="bw-bar" data-r="bar"></div><div class="bw-scroll" data-r="scroll" tabindex="0" aria-label="이번 주 정리"></div>';
    listEl.textContent = '';
    listEl.appendChild(root);
    scrollEl = root.querySelector('[data-r="scroll"]');
    root.addEventListener('click', onClick);
    root.addEventListener('toggle', e => { if (e.target && e.target.classList && e.target.classList.contains('bw-ev')) evOpen = e.target.open; }, true);
    sel = -1;
    // v0.8: 지난번에 받은 정리를 먼저 보여 주고(실행 중 표시는 뺀다), 새로 읽는다
    const ai = AI(), old = aiByOff.get(offset);
    aiStat = ai ? ai.cached() : null;
    aiRes = old && old.digest ? Object.assign({}, old, { running: false }) : null;
    if (ai) {
      ai.bindRefs(root);
      aiOffs = [ai.on('digest', onAIDigest), ai.on('status', onAIStatus), ai.on('run', onAIRun)];
    }
    renderBar();
    refresh(offset);
    aiLoad('auto');
  }
  function unmount() {
    seq++; aiSeq++;
    aiOffs.forEach(off => { try { off(); } catch (_) { /* 이미 풀렸다 */ } });
    aiOffs = [];
    if (root && root.parentNode) root.parentNode.removeChild(root);
    boxEl = boxBack = null;
    root = scrollEl = listEl = readerEl = null;
    data = null; opens = []; aiRes = null;
  }

  async function refresh(off) {
    if (!api || !root) return;
    let moved = false;
    if (typeof off === 'number') { if (off !== offset) { offset = off; sel = -1; data = null; moved = true; } }
    if (moved) { const old = aiByOff.get(offset); aiRes = old && old.digest ? Object.assign({}, old, { running: false }) : null; aiLoad('auto'); }   // 주를 바꾸면 그 주의 정리를 읽는다
    else if (typeof off !== 'number') aiLoad('none');   // 새로 고침: 정리는 읽기만 (새로 돌리는 건 열 때·주를 바꿀 때·다시 정리 버튼)
    const my = ++seq;
    loading = !data; loadError = null;
    renderBar(); if (loading) renderBody();
    let res = null, err = null;
    try { res = await api.call('week', { offset }); } catch (e) { err = (e && e.message) || '불러오지 못했어요'; }
    if (my !== seq || !root) return;
    loading = false;
    if (err || !res || res.ok === false) loadError = err || (res && res.error) || '불러오지 못했어요';
    else data = res;
    renderBar(); renderBody();
  }

  // ---------- 그리기 ----------
  function renderBar() {
    const bar = root && root.querySelector('[data-r="bar"]'); if (!bar) return;
    const label = data && data.range ? data.range.label : '';
    const plan = aiPlan(), busy = !!(aiRes && aiRes.running);
    // v0.8: Claude 정리를 보여 주는 중이면 복사 버튼은 보고 글을, 아니면 예전처럼 근거 목록을 복사한다
    const toggle = plan.toggle
      ? '<div class="bw-seg bw-view" role="group" aria-label="보기 바꾸기">' +
          '<button type="button" data-view="claude" aria-pressed="' + (view === 'claude') + '" title="Claude가 읽고 정리한 이번 주">' + ic('sparkle') + '<span>Claude 정리</span>' + (busy ? '<i class="spinner" role="img" aria-label="정리하는 중"></i>' : '') + '</button>' +
          '<button type="button" data-view="list" aria-pressed="' + (view === 'list') + '" title="사서가 모은 목록">' + ic('list') + '<span>목록</span></button></div>'
      : '';
    const copyBtn = plan.show
      ? '<button class="btn sm bw-copy-btn" type="button" data-act="copy-ai"' + (aiReport() ? '' : ' disabled') + '>' + ic('copy') + '<span>보고 글 복사</span><kbd>⌘⇧C</kbd></button>'
      : '<button class="btn sm bw-copy-btn" type="button" data-act="copy"' + (data && data.copyText ? '' : ' disabled') + '>' + ic('copy') + '<span>주간보고용 복사</span><kbd>⌘⇧C</kbd></button>';
    const html =
      '<div class="bw-seg" role="group" aria-label="주 바꾸기">' +
        '<button type="button" data-off="-1" aria-pressed="' + (offset === -1) + '" title="지난주 · ←">' + ic('back') + '<span>지난주</span></button>' +
        '<button type="button" data-off="0" aria-pressed="' + (offset === 0) + '" title="이번 주 · →"><span>이번 주</span>' + ic('next') + '</button></div>' +
      '<span class="bw-range num">' + E(label) + '</span>' + toggle + copyBtn;
    keepFocus(bar, () => { bar.innerHTML = html; });
  }
  function chipText(c) { return c && c.text ? c.text : ''; }
  function srcMark(s) { return s && s !== 'rules' && SRC[s] ? '<span class="bx-src" data-o="' + E(s === 'apple' ? 'apple' : s) + '">' + E(SRC[s]) + '</span>' : ''; }
  function rowAttrs(o) {
    if (!o.docId) return '';
    opens.push({ docId: o.docId, line: o.line || null });
    return ' data-n="' + (opens.length - 1) + '" data-doc="' + E(o.docId) + '"' + (o.line ? ' data-line="' + E(o.line) + '"' : '');
  }
  function openRow(o, inner, cls) {
    const at = rowAttrs(o);
    return at ? '<button type="button" class="bw-row ' + (cls || '') + '"' + at + '>' + inner + '</button>' : '<div class="bw-row is-static ' + (cls || '') + '">' + inner + '</div>';
  }
  function dueCls(l) { return /지남|오늘|D-[0-3]\b/.test(l || '') ? ' is-hot' : ''; }

  function heatHTML() {
    const h = data.heat || {}, rows = h.rows || [], days = h.days || ['월', '화', '수', '목', '금', '토', '일'];
    if (!rows.length) return '<section class="bw-heat is-empty"><p>' + (offset === 0 ? '이번 주' : '지난주') + ' 사람 활동이 아직 없어요</p></section>';
    const today = todayIdx();
    let g = '<div class="bw-hg" role="table" aria-label="요일별 활동"><div class="bw-hh" role="row"><span></span>' +
      days.map((d, i) => '<span class="bw-hd' + (i === today ? ' is-today' : '') + '" role="columnheader">' + E(d) + '</span>').join('') + '</div>';
    rows.forEach(r => {
      g += '<div class="bw-hr" role="row"><span class="bw-hn" title="' + E(r.title) + '" role="rowheader">' + E(r.title) + '</span>' +
        (r.counts || []).map((n, i) => {
          const lv = n >= 6 ? 3 : n >= 3 ? 2 : n >= 1 ? 1 : 0;
          return '<span class="bw-hc" data-l="' + lv + '" role="cell" title="' + E(r.title + ' · ' + (days[i] || '') + ' ' + n + '번') + '" aria-label="' + E((days[i] || '') + ' ' + n + '번') + '">' + (n > 0 ? E(n) : '') + '</span>';
        }).join('') + '</div>';
    });
    return '<section class="bw-heat"><div class="bw-sh"><h3>흐름별 활동</h3><span class="bw-legend" aria-hidden="true">적음<i data-l="0"></i><i data-l="1"></i><i data-l="2"></i><i data-l="3"></i>많음</span></div>' + g + '</div></section>';
  }
  function todayIdx() {
    const r = data && data.range; if (!r || offset !== 0) return -1;
    const p = s => { const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(s || ''); return m ? new Date(+m[1], +m[2] - 1, +m[3]) : null; };
    const s = p(r.start); if (!s) return -1;
    const n = new Date(); const t = new Date(n.getFullYear(), n.getMonth(), n.getDate());
    const d = Math.round((t - s) / 864e5);
    return d >= 0 && d < 7 ? d : -1;
  }
  function colHead(title, n, k, basis) { return '<h3 class="bw-ch">' + E(title) + (n != null ? ' <span class="num">' + E(n) + '</span>' : '') + (basis ? basisHead() : '') + '</h3>'; }
  // v0.7 C: 티켓 줄 — 키 · 제목 / 상태 칩(v0.6 cluster.js) · 시각 · 담당 · "갱신 기준"
  function chip(group, status, mine) {
    const C = window.SynapseCluster;
    return C && typeof C.chipHtml === 'function' ? C.chipHtml({ statusGroup: group, status: status, mine: !!mine }, E) : '';
  }
  function ticketTitle(x) {
    const key = x.key || '', t = plain(x.title || x.text || '');
    if (key && t.indexOf(key) === 0) return t.slice(key.length).replace(/^[\s·:\-–]+/, '') || t;
    return t;
  }
  // "갱신 기준": 상태가 바뀐 시각을 몰라 마지막 갱신 시각으로 이번 주인지 판단한 티켓. 모두 그렇다면 구역 머리에 한 번만 두고, 섞여 있을 때만 줄마다 둔다.
  const BASIS_TIP = '상태가 바뀐 시각을 몰라서 마지막으로 갱신된 시각으로 이번 주인지 판단했어요';
  const isTicket = x => x && x.kind === 'issue' && x.key;
  const allBasis = list => { const t = (list || []).filter(isTicket); return t.length > 0 && t.every(x => x.basis === 'updated'); };
  const basisHead = () => ' <span class="bw-basis" title="' + E(BASIS_TIP) + '">갱신 기준</span>';
  const basisNote = () => '<p class="bw-none bw-basisnote">티켓은 ' + E(BASIS_TIP) + '.</p>';
  const PERSON = '<svg class="bw-person" viewBox="0 0 12 12" width="11" height="11" aria-hidden="true"><circle cx="6" cy="4" r="2.2" fill="none" stroke="currentColor" stroke-width="1.3"/><path d="M1.9 10.3c.5-2 2.1-3 4.1-3s3.6 1 4.1 3" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/></svg>';
  function ticketRow(x, extra, cls, quietBasis) {
    const meta = [x.whenLabel].filter(Boolean).map(E).join('');
    const who = x.mine ? '<span class="bw-mine" title="내가 담당인 티켓">' + PERSON + '내 티켓</span>' : (x.assigneeName ? '<span>' + E(x.assigneeName) + '</span>' : '');
    return openRow(x, '<span class="bw-ico" data-k="issue">' + ic('ticket') + '</span><span class="bw-rt"><span class="bw-tx"><b class="bw-key num">' + E(x.key || '') + '</b> ' + E(ticketTitle(x)) + '</span>' +
      '<span class="bw-meta">' + (extra || '') + (meta ? '<span>' + meta + '</span>' : '') + who + (x.project ? '<span class="bw-proj">' + E(x.project) + '</span>' : '') +
      (x.basis === 'updated' && !quietBasis ? '<span class="bw-basis" title="' + E(BASIS_TIP) + '">갱신 기준</span>' : '') + '</span></span>', cls);
  }
  function stepText(x) { return E((x.fromLabel ? x.fromLabel + ' → ' : '→ ') + (x.toLabel || x.to || '')); }
  function moveHint() { return offset === 0 ? ' · 지난주 보기 <kbd>[</kbd>' : ' · 이번 주 보기 <kbd>]</kbd>'; }
  function doneHTML() {
    const a = data.done || [], cl = data.closed || [], ch = data.changes || [];
    const doneAll = allBasis(a.concat(cl)), chAll = allBasis(ch);
    let h = '<section class="bw-col" data-k="done">' + colHead('한 일', a.length, null, doneAll);
    if (doneAll) h += basisNote();
    if (!a.length) h += '<p class="bw-none">' + (offset === 0 ? '이번 주에 끝낸 일이 아직 없어요' : '지난주에 끝낸 일 기록이 없어요') + moveHint() + '</p>';
    a.forEach(x => {
      if (x.kind === 'issue' && x.key) { h += ticketRow(x, chip(x.statusGroup || 'done', x.status, x.mine), '', doneAll); return; }
      const meta = [x.whenLabel, x.actorLabel].filter(Boolean).map(E).join(' · ');
      h += openRow(x, '<span class="bw-ico" data-k="' + E(x.kind) + '">' + ic(KIND_ICON[x.kind] || 'check') + '</span><span class="bw-rt"><span class="bw-tx">' + E(plain(x.text)) + '</span>' +
        '<span class="bw-meta">' + meta + (x.project ? '<span class="bw-proj">' + E(x.project) + '</span>' : '') + srcMark(x.source) + '</span></span>');
    });
    if (cl.length) {
      h += '<h4 class="bw-sub is-dim">닫음 ' + E(cl.length) + ' <span>취소·반려·막힌 채 닫힌 티켓은 한 일에서 뺐어요</span></h4>';
      cl.slice(0, 5).forEach(x => { h += ticketRow(x, chip('dropped', x.status, false), 'is-dim', doneAll); });
      if (cl.length > 5) h += '<p class="bw-none">외 ' + E(cl.length - 5) + '개</p>';
    }
    h += '</section>';
    // 상태 변경: 그 주에 상태가 바뀌었지만 끝나지 않은 티켓
    h += '<section class="bw-col" data-k="changes">' + colHead('상태 변경', ch.length, null, chAll);
    if (chAll) h += basisNote();
    if (!ch.length) h += '<p class="bw-none">' + (offset === 0 ? '이번 주에 상태가 바뀐 티켓이 없어요' : '지난주에 상태가 바뀐 티켓이 없어요') + '</p>';
    ch.forEach(x => { h += ticketRow(x, '<span class="bw-step">' + stepText(x) + '</span>', '', chAll); });
    return h + '</section>';
  }
  function progressHTML() {
    const a = data.progress || [];
    let h = '<section class="bw-col" data-k="progress">' + colHead('진행 중', a.length);
    if (!a.length) h += '<p class="bw-none">진행 중인 흐름이 없어요</p>';
    a.forEach(x => {
      const bits = [];
      if (x.doneThisWeek > 0) bits.push((offset === 0 ? '이번 주 ' : '그 주 ') + x.doneThisWeek + '개 끝냄');
      if (x.open > 0) bits.push('남은 할 일 ' + x.open + '개');
      if (x.lastLabel) bits.push(x.lastLabel);
      const chips = (x.chips || []).slice(0, 3).filter(c => chipText(c)).map(c => '<span class="bx-chip" data-k="' + E(c.kind) + '">' + E(chipText(c)) + '</span>' + srcMark(c.source)).join('');
      h += '<div class="bw-row is-static"><span class="bw-ico" data-k="thread">' + ic('graph') + '</span><span class="bw-rt"><span class="bw-tx">' + E(x.title) + '</span>' +
        '<span class="bw-meta">' + E(bits.join(' · ')) + '</span>' + (chips ? '<span class="bw-chips">' + chips + '</span>' : '') + '</span></div>';
    });
    return h + '</section>';
  }
  function nextHTML() {
    const a = data.next || [], lp = data.lastPlan || [], ms = data.missing || [];
    let h = '<section class="bw-col" data-k="next">' + colHead('다음', a.length);
    if (!a.length) h += '<p class="bw-none">열린 할 일이 없어요</p>';
    a.forEach(x => {
      h += openRow(x, '<span class="bw-ico">' + ic('next') + '</span><span class="bw-rt"><span class="bw-tx">' + E(plain(x.text)) + '</span><span class="bw-meta">' +
        (x.dueLabel ? '<span class="bw-due' + dueCls(x.dueLabel) + '">' + E(x.dueLabel) + '</span>' : '') + (x.project ? '<span class="bw-proj">' + E(x.project) + '</span>' : '') + '</span></span>');
    });
    if (lp.length) {
      h += '<h4 class="bw-sub">지난주 계획</h4>';
      lp.forEach(x => { h += openRow(x, '<span class="bw-ico">' + ic('doc') + '</span><span class="bw-rt"><span class="bw-tx">' + E(plain(x.text)) + '</span><span class="bw-meta"><span class="bx-chip" data-k="plan">지난주 주간보고</span></span></span>'); });
    }
    if (ms.length) {
      h += '<h4 class="bw-sub is-dim">누락 의심 <span>고친 흔적은 있는데 할 일 변화가 없어요</span></h4>';
      ms.forEach(x => { h += openRow(x, '<span class="bw-ico">' + ic('alert') + '</span><span class="bw-rt"><span class="bw-tx">' + E(x.title) + '</span><span class="bw-meta">' + E((x.lines != null ? x.lines + '줄 수정' : '') + (x.whenLabel ? ' · ' + x.whenLabel : '')) + '</span></span>', 'is-dim'); });
    }
    return h + '</section>';
  }
  // ---------- v0.8 Claude 정리 ----------
  const aiReport = () => { const d = aiRes && aiRes.digest; return d && d.report ? d : null; };
  const weekWord = () => (offset === 0 ? '이번 주' : '지난주');
  // 무엇을 보여 줄지: show = Claude 보기를 그리나 · toggle = 토글을 보이나 · notice = 목록 위에 띄울 한 줄 안내
  function aiPlan() {
    const ai = AI(), plan = { show: false, toggle: false, notice: '' };
    if (!ai) return plan;
    const st = aiStat, res = aiRes;
    if ((st && st.unsupported) || (res && res.unsupported)) return plan;                       // 옛 앱·미리보기: 조용히 목록만
    if (st && st.available === false) { plan.notice = ai.noticeHTML(st, E); return plan; }       // 꺼짐·Claude 없음
    if (res && (res.blocked === 'disabled' || res.blocked === 'unavailable')) { plan.notice = ai.noticeHTML(res, E); return plan; }
    if (!res || res.digest || res.running || res.state === 'empty') {
      plan.toggle = true; plan.show = view === 'claude';
      if (res && res.digest && !res.running) plan.notice = ai.noticeHTML(res, E);                // 정리는 있는데 새로 못 읽었을 때
      return plan;
    }
    plan.notice = ai.noticeHTML(res, E);                                                         // 정리가 없고, 못 돌린 이유가 있다 → 목록 + 안내
    return plan;
  }
  async function aiLoad(run) {
    const ai = AI(); if (!ai || !root) return;
    const my = ++aiSeq, off = offset;
    const [st, res] = await Promise.all([ai.status(), ai.digest('week', { offset: off, run: run || 'none' })]);
    if (my !== aiSeq || !root || off !== offset) return;
    aiStat = st; aiRes = res; aiByOff.set(off, res);
    renderBar(); renderBody();
  }
  function onAIDigest(e) {
    if (!root || !e || e.kind !== 'week') return;
    const day = x => (x ? String(x).slice(0, 10) : null);   // "2026-10-26" (시각이 붙어 있어도 날짜만 비교)
    const cur = day((aiRes && aiRes.scope) || (data && data.range && data.range.start));
    if (e.scope && cur && day(e.scope) !== cur) { aiByOff.forEach((v, k) => { if (v && v.scope === e.scope) aiByOff.delete(k); }); return; }   // 다른 주의 정리
    aiLoad('none');
  }
  function onAIStatus(e, st) {
    if (!root) return;
    const sig = x => (x ? [x.available, x.enabled, x.auto, x.claude && x.claude.found, x.claude && x.claude.login].join() : '');
    const before = sig(aiStat);
    aiStat = st || aiStat;
    aiLoad(before !== sig(aiStat) ? 'auto' : 'none');   // 설정을 켜거나 로그인이 풀린 때만 새로 돌아도 되는지 묻는다
  }
  function onAIRun(e) {
    if (!root || !e || e.kind !== 'digest') return;
    const mine = aiRes && aiRes.running;
    if ((e.status === 'running' && !mine) || (e.status !== 'running' && mine)) aiLoad('none');
  }
  function setView(v) {
    if (v !== 'claude' && v !== 'list') return;
    view = v; saveView(); sel = -1;
    renderBar(); renderBody();
  }
  const refsOf = (list) => { const x = AI().refsHTML(list, E); return x ? '<span class="ai-refs">' + x + '</span>' : ''; };
  function itemHTML(it) {
    return '<li class="ai-item">' + AI().itemIconHTML(it.state) + '<div class="ai-item-b"><span class="ai-item-tx">' + E(it.text) + '</span>' + refsOf(it.refs) + '</div></li>';
  }
  function zoneHTML(cls, icon, title, list, withWhy) {
    if (!list || !list.length) return '';
    return '<div class="ai-zone ' + cls + '"><h3 class="ai-zone-h">' + ic(icon) + E(title) + ' <span class="num">' + list.length + '</span></h3><ul class="ai-items">' +
      list.map(it => '<li class="ai-item"><span class="ai-item-ic" aria-hidden="true">' + ic(icon) + '</span><div class="ai-item-b"><span class="ai-item-tx">' + E(it.text) + '</span>' + refsOf(it.refs) +
        (withWhy && it.why ? '<span class="ai-why">' + E(it.why) + '</span>' : '') + '</div></li>').join('') + '</ul></div>';
  }
  function digestCardHTML(res) {
    const ai = AI(), d = res.digest, busy = !!res.running;
    let h = '<section class="ai-card bw-ai' + (busy ? ' is-stale' : '') + '" aria-label="Claude가 정리한 ' + weekWord() + '"' + (busy ? ' aria-busy="true"' : '') + '>' +
      '<div class="ai-head"><span class="ai-tag">' + ic('sparkle') + 'Claude 정리</span></div>';
    if (busy) h += ai.noticeHTML(Object.assign({}, res, { what: weekWord() + '를' }), E);
    h += '<div class="ai-body">';
    if (d.headline) h += '<p class="ai-headline">' + E(d.headline) + '</p>';
    (d.sections || []).forEach(sec => {
      h += '<section class="ai-sec"><div class="ai-sec-h"><h3 class="ai-sec-t">' + E(sec.title) + '</h3>' + ai.stateChipHTML(sec.state, E) + '</div><ul class="ai-items">' + (sec.items || []).map(itemHTML).join('') + '</ul></section>';
    });
    h += zoneHTML('is-next', 'move', offset === 0 ? '다음 주' : '그다음 주', d.next, true);
    h += zoneHTML('is-risk', 'alert', '위험', d.risks, false);
    const sk = d.skipped;
    if (sk && (sk.count > 0 || sk.note)) h += '<p class="ai-skipped"><b>뺀 것 ' + E(sk.count || 0) + '개</b>' + (sk.note ? ': ' + E(sk.note) : '') + '</p>';
    h += '</div>' + ai.metaHTML(res.meta, E, { stale: res.state === 'stale' && !busy, busy }) + '</section>';
    return h;
  }
  // 보고 글 칸: 미리보기 + 복사 + 근거 목록(접어 둠)
  function reportBoxHTML() {
    const d = aiReport(); if (!d) return '';
    return '<section class="bw-rep" aria-label="보고 글"><div class="bw-rep-h"><h3>보고 글</h3>' + (d.reportHTML ? '<span>붙여 넣으면 글머리표가 그대로 살아요</span>' : '') +
      '<button class="btn sm" type="button" data-act="copy-ai">' + ic('copy') + '<span>보고 글 복사</span><kbd>⌘⇧C</kbd></button></div>' +
      '<pre class="bw-rep-pre" tabindex="0" aria-label="보고 글 미리 보기">' + E(d.report) + '</pre>' +
      (data && data.copyText ? '<details class="bw-ev"' + (evOpen ? ' open' : '') + '><summary>근거 목록</summary><pre>' + E(data.copyText) + '</pre>' +
        '<div class="bw-ev-b"><button class="btn sm" type="button" data-act="copy">' + ic('copy') + '<span>근거 목록 복사</span></button>' +
        '<span>보고 글을 쓴 근거가 되는 한 일·진행 중·다음 줄이에요. 사실과 다르면 여기서 확인하세요.</span></div></details>' : '') + '</section>';
  }
  function claudeHTML(plan) {
    const ai = AI(), res = aiRes, d = res && res.digest;
    let h = plan.notice || '';
    if (d) return h + '<div class="bw-ai-wrap">' + digestCardHTML(res) + reportBoxHTML() + '</div>';
    if (res && res.state === 'empty' && !res.running) {
      return h + '<div class="bw-ai-wrap"><section class="ai-card"><div class="ai-head"><span class="ai-tag">' + ic('sparkle') + 'Claude 정리</span></div>' +
        '<div class="ai-empty"><strong>' + weekWord() + '에는 정리할 내용이 아직 없어요</strong>문서를 고치거나 할 일을 끝내면 Claude가 읽고 정리해요.</div></section></div>';
    }
    // 처음 읽는 중(또는 응답 전): 뼈대
    return h + '<div class="bw-ai-wrap"><section class="ai-card" aria-busy="true" aria-label="Claude가 ' + weekWord() + '를 정리하는 중">' +
      '<div class="ai-head"><span class="ai-tag">' + ic('sparkle') + 'Claude 정리</span></div>' +
      '<div class="ai-notice is-run" role="status"><span class="ai-notice-ic"><i class="spinner" aria-hidden="true"></i></span><span class="ai-notice-t">Claude가 ' + weekWord() + '를 읽고 있어요…</span></div>' +
      ai.skeletonHTML(6) + '</section></div>';
  }
  // 참조 칩을 DOM 순서대로 번호 매겨 ↑↓·j·k·↵ 이동 대상(opens)으로 삼는다
  function indexChips() {
    scrollEl.querySelectorAll('.ai-ref[data-ai-doc]').forEach(c => {
      c.dataset.n = String(opens.length);
      opens.push({ docId: c.getAttribute('data-ai-doc'), line: c.getAttribute('data-ai-line') ? Number(c.getAttribute('data-ai-line')) : null });
    });
  }

  function renderBody() {
    if (!scrollEl) return;
    const top = scrollEl.scrollTop;
    opens = [];
    const plan = aiPlan();
    if (plan.show) {
      keepFocus(scrollEl, () => { scrollEl.innerHTML = claudeHTML(plan); indexChips(); });   // 칩 번호(data-n)를 매긴 뒤에 포커스를 되돌린다
      scrollEl.scrollTop = top;
      if (sel >= opens.length) sel = opens.length - 1;
      paintSel(false);
      return;
    }
    const h = (plan.notice || '') + listBodyHTML();
    keepFocus(scrollEl, () => { scrollEl.innerHTML = h; });
    scrollEl.scrollTop = top;
    paintSel(false);
  }
  // 목록 보기(v0.5~0.7 그대로)
  function listBodyHTML() {
    let h;
    if (loading && !data) h = '<div class="bw-state"><i class="spinner lg"></i><span>이번 주를 모으는 중이에요</span></div>';
    else if (!data) h = '<div class="bw-state is-error"><strong>이번 주를 열지 못했어요</strong><span>' + E(loadError || '') + '</span><button class="btn sm" type="button" data-act="retry">다시 시도</button></div>';
    else {
      const empty = !(data.done || []).length && !(data.changes || []).length && !(data.closed || []).length && !(data.progress || []).length && !(data.next || []).length && !((data.heat || {}).rows || []).length;
      if (empty) h = '<div class="bw-state"><strong>' + (offset === 0 ? '이번 주에는 아직 기록이 없어요' : '지난주 기록이 없어요') + '</strong><span>문서를 고치거나 할 일을 끝내면 여기에 모여요.</span></div>';
      else h = heatHTML() + '<div class="bw-cols"><div class="bw-stack">' + doneHTML() + '</div>' + progressHTML() + nextHTML() + '</div>' +
        (data.copyText ? '<details class="bw-prev"><summary>복사될 내용 미리 보기</summary><pre>' + E(data.copyText) + '</pre><p>문장으로 다듬는 건 Claude가 해요. 사서는 줄만 모아 줘요.</p></details>' : '');
    }
    return h;
  }
  function paintSel(scroll) {
    if (!root) return;
    root.querySelectorAll('.bw-row.is-sel, .ai-ref.is-sel').forEach(n => n.classList.remove('is-sel'));
    const n = sel >= 0 ? root.querySelector('.bw-row[data-n="' + sel + '"], .ai-ref[data-n="' + sel + '"]') : null;
    if (n) { n.classList.add('is-sel'); if (scroll && n.scrollIntoView) n.scrollIntoView({ block: 'nearest' }); }
  }

  // ---------- 동작 ----------
  // 목록 보기(그리고 근거 목록)의 복사: 사서가 모은 줄 그대로
  function copyList() {
    if (!data || !data.copyText) return api.toast('복사할 내용이 아직 없어요');
    api.copyText(data.copyText, '주간보고용으로 복사했어요 · 주간보고 문서에 붙여 넣어 주세요', showCopyBox);
  }
  // Claude 보기의 복사: 보고 글(report)과 서식(reportHTML)을 함께 — 서식이 안 되면 글자만, 그것도 안 되면 복사 실패 상자
  function copyAI() {
    const d = aiReport();
    if (!d) return api.toast('복사할 보고 글이 아직 없어요');
    AI().copyReport(d.report, d.reportHTML, {
      ok: '보고 글을 복사했어요 · 붙여 넣으면 글머리표가 그대로 살아요',
      plain: '보고 글을 복사했어요 · 글자만 복사돼서 서식은 붙지 않아요',
      onFail: showCopyBox,
    });
  }
  // ⌘⇧C: Claude 보기에 보고 글이 보이면 그것을, 아니면 목록 복사
  function copyShown() { if (aiPlan().show && aiReport()) copyAI(); else copyList(); }
  // v0.7 C: 복사가 모두 막힌 때의 대안 — 글이 모두 선택된 읽기 전용 상자. ⌘C로 복사하고 esc로 닫는다.
  let boxEl = null, boxBack = null;
  function showCopyBox(text) {
    if (!root) return;
    closeCopyBox(false);
    boxBack = document.activeElement;
    boxEl = document.createElement('div');
    boxEl.className = 'bw-copybox';
    boxEl.setAttribute('role', 'dialog'); boxEl.setAttribute('aria-label', '복사 미리보기');
    boxEl.innerHTML = '<div class="bw-cb-h"><strong>자동으로 복사하지 못했어요</strong><span>글이 모두 선택돼 있어요 · <kbd>⌘C</kbd>로 복사하세요</span>' +
      '<button class="btn sm" type="button" data-act="copybox-close">닫기 <kbd>esc</kbd></button></div>' +
      '<textarea class="bw-cb-ta" readonly spellcheck="false" aria-label="주간보고용 글"></textarea>';
    root.appendChild(boxEl);
    const ta = boxEl.querySelector('textarea');
    ta.value = String(text == null ? '' : text);
    ta.focus({ preventScroll: true }); ta.select();
  }
  function closeCopyBox(restore) {
    if (!boxEl) return false;
    if (boxEl.parentNode) boxEl.parentNode.removeChild(boxEl);
    boxEl = null;
    if (restore !== false && boxBack && boxBack.focus && document.body.contains(boxBack)) boxBack.focus({ preventScroll: true });
    boxBack = null;
    return true;
  }
  function openAt(n, orig) {
    const o = opens[n]; if (!o) return;
    sel = n; paintSel(false);
    if (orig) api.openOriginal(o.docId); else api.openDoc(o.docId, o.line || undefined);
  }
  function move(d) {
    if (!opens.length) return;
    sel = Math.max(0, Math.min(opens.length - 1, (sel < 0 ? (d > 0 ? 0 : opens.length - 1) : sel + d)));
    paintSel(true);
  }
  function onClick(e) {
    if (!root) return;   // 참조 칩이 문서를 여는 사이 화면이 내려간 경우
    const chip = e.target.closest('.ai-ref[data-n]');
    if (chip && root.contains(chip)) { sel = +chip.dataset.n; paintSel(false); return; }   // 여는 건 SynapseAI.bindRefs가 한다
    const vw = e.target.closest('[data-view]');
    if (vw && root.contains(vw)) { setView(vw.dataset.view); return; }
    const ac = e.target.closest('[data-ai-act]');
    if (ac && root.contains(ac)) { if (ac.dataset.aiAct === 'retry' || ac.dataset.aiAct === 'regen') { e.preventDefault(); aiLoad('force'); } return; }   // preventDefault: app.js가 같은 단추를 또 처리하지 않게. 설정 열기는 app.js가 맡는다
    const seg = e.target.closest('[data-off]');
    if (seg && root.contains(seg)) { refresh(+seg.dataset.off); return; }
    const b = e.target.closest('[data-act]');
    if (b && root.contains(b)) {
      const act = b.dataset.act;
      if (act === 'copybox-close') closeCopyBox(true);
      else if (act === 'copy') copyList();
      else if (act === 'copy-ai') copyAI();
      else if (act === 'retry') refresh();
      return;
    }
    const row = e.target.closest('.bw-row[data-n]');
    if (row && root.contains(row)) openAt(+row.dataset.n, false);
  }
  function onKey(e) {
    if (!root || !api || e.isComposing || e.keyCode === 229) return false;
    const k = e.key, a = document.activeElement;
    if (boxEl && k === 'Escape' && !e.metaKey && !e.ctrlKey && !e.altKey) { e.preventDefault(); closeCopyBox(true); return true; }
    if ((e.metaKey || e.ctrlKey) && e.shiftKey && !e.altKey && String(k).toLowerCase() === 'c') { e.preventDefault(); copyShown(); return true; }
    if ((e.metaKey || e.ctrlKey) && !e.altKey && !e.shiftKey && k === 'Enter' && sel >= 0) { e.preventDefault(); openAt(sel, true); return true; }
    if (e.metaKey || e.ctrlKey || e.altKey) return false;
    const typing = !!a && (a.tagName === 'INPUT' || a.tagName === 'TEXTAREA' || a.tagName === 'SELECT' || a.isContentEditable);
    const emptyInput = typing && a.value === '';
    if (typing && !emptyInput) return false;
    if (k === 'ArrowDown' || k === 'ArrowUp') { e.preventDefault(); move(k === 'ArrowDown' ? 1 : -1); return true; }
    if (k === 'ArrowLeft') { e.preventDefault(); if (offset !== -1) refresh(-1); return true; }
    if (k === 'ArrowRight') { e.preventDefault(); if (offset !== 0) refresh(0); return true; }
    if (k === 'Enter' && emptyInput && sel >= 0) { e.preventDefault(); openAt(sel, false); return true; }   // v0.8: 검색창이 비어 있으면 ↵로 고른 줄·참조 칩을 연다 (티켓 화면과 같다)
    if (typing) return false;
    if (a && a !== document.body && !(listEl && listEl.contains(a))) return false;
    if (k === '[') { if (offset !== -1) refresh(-1); return true; }
    if (k === ']') { if (offset !== 0) refresh(0); return true; }
    if (k === 'Enter' && sel >= 0 && !(a && a.tagName === 'BUTTON')) { e.preventDefault(); openAt(sel, false); return true; }
    const ch = /^[a-zA-Z]$/.test(k) ? k.toLowerCase() : (/^Key[A-Z]$/.test(e.code || '') ? e.code.slice(3).toLowerCase() : '');
    if (ch === 'j') { e.preventDefault(); move(1); return true; }
    if (ch === 'k') { e.preventDefault(); move(-1); return true; }
    return false;
  }

  window.SynapseWeek = Object.freeze({ init, mount, refresh, onKey, unmount, showCopyBox });
})();
