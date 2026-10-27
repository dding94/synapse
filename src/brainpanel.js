// brainpanel.js — Synapse v0.5 AI 기록 시트(⌘Y, §9.6)와 설정의 "사서" 섹션(§9.8). window.SynapseBrainPanel 하나만 만든다.
// openLog() · closeLog() · isOpen() · onKey(e) → bool · renderSettings(containerEl)  + init(api) · refresh()
(function () {
  'use strict';

  let api = null;
  // AI 기록 시트
  let scrim = null, sheet = null, lastFocus = null, isOpenFlag = false;
  let log = { entries: [], engine: null, stopped: false, loaded: false, error: null };
  let selId = null, logBusy = false, logSeq = 0, conflicts = null;
  // 설정
  let setEl = null, setSeq = 0;
  let S = { bs: null, pol: null, lim: null, error: null, loaded: false };
  let polOpen = false, clearAsk = false, setBusy = '', directAsk = false;

  const E = v => api.esc(v == null ? '' : String(v));
  const ic = n => { try { return api.icon(n) || ''; } catch (_) { return ''; } };
  const KIND_ICON = { check: 'check', inPlace: 'folder', propose: 'doc', apply: 'follow', undo: 'refresh', rollback: 'alert', reject: 'x', summary: 'edit', policy: 'sliders', session: 'plug', stop: 'lock', trash: 'trash', restore: 'undo', purge: 'trash', direct: 'plug' };
  const RULE_KIND = { place: '배치', frozen: '동결', exclude: '제외', landing: '출발지', duty: '점검' };
  const ORIGIN_CLS = o => (o === 'rules' || o === 'claude' || o === 'codex' || o === 'apple' ? o : 'other');

  function init(a) { api = a; }
  // 다시 그려도 키보드 포커스를 잃지 않게: 포커스 요소의 data-* 로 찾아 되돌린다
  function keepFocus(box, fn) {
    const a = document.activeElement; let q = '';
    if (a && box && a !== box && box.contains(a)) {
      for (const at of Array.from(a.attributes)) if (at.name.indexOf('data-') === 0) q += '[' + at.name + '="' + String(at.value).replace(/["\\]/g, '\\$&') + '"]';
    }
    fn();
    if (q) { const n = box.querySelector(q); if (n && !n.disabled) n.focus({ preventScroll: true }); }
  }
  const ROOT_LABEL = '볼트 루트 낱개 파일';
  function rulesList(rs) {
    const out = (rs || []).map(r => Object.assign({}, r, { pattern: /^\.?\/?$/.test(String(r.pattern || '').trim()) ? ROOT_LABEL : r.pattern }));
    const frozen = new Set(out.filter(r => r.kind === 'frozen').map(r => r.pattern));
    return out.filter(r => !(r.kind === 'exclude' && frozen.has(r.pattern))); // 같은 경로가 동결·제외에 둘 다 있으면 동결 한 줄
  }
  async function call(method, params) {
    try { return await api.call(method, params || {}); } catch (e) { return { ok: false, error: (e && e.message) || '처리하지 못했어요' }; }
  }
  function engineLine(en) {
    if (!en) return '';
    if (en.apple === 'ready') return '기기 AI 사용 중' + (en.pending > 0 ? ' · 요약 대기 ' + en.pending : '');
    const why = en.reason || (en.apple === 'unsupported' ? '이 Mac에서는 기기 AI를 쓸 수 없어요' : 'Apple Intelligence가 꺼져 있어요');
    return '규칙으로 동작 중 · ' + why;
  }
  function agoLabel(iso) {
    if (!iso) return '아직 없어요';
    const d = new Date(iso); if (isNaN(d)) return String(iso);
    const p = n => String(n).padStart(2, '0'), now = new Date();
    const t = p(d.getHours()) + ':' + p(d.getMinutes());
    const day = x => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
    const diff = Math.round((day(now) - day(d)) / 864e5);
    const mins = Math.round((now - d) / 6e4);
    if (mins >= 0 && mins < 1) return '방금 전';
    if (mins > 0 && mins < 60) return mins + '분 전';
    return diff === 0 ? '오늘 ' + t : diff === 1 ? '어제 ' + t : (d.getMonth() + 1) + '/' + d.getDate() + ' ' + t;
  }
  function swHTML(key, on, label, busy) {
    return '<button class="switch' + (busy ? ' is-busy' : '') + '" type="button" role="switch" data-bp="sw" data-key="' + E(key) + '" aria-checked="' + (!!on) + '" aria-label="' + E(label) + '"><i></i></button>';
  }

  // =====================================================================
  // AI 기록 시트
  // =====================================================================
  function isOpen() { return isOpenFlag; }
  function openLog() {
    if (!api) return;
    if (isOpenFlag) { loadLog(); return; }
    isOpenFlag = true;
    lastFocus = document.activeElement;
    conflicts = null; selId = null;
    scrim = document.createElement('div');
    scrim.className = 'bp-scrim';
    scrim.innerHTML = '<div class="bp-sheet" role="dialog" aria-modal="true" aria-labelledby="bp-log-t" tabindex="-1">' +
      '<div class="bp-head"><div class="bp-head-t"><h2 id="bp-log-t" class="bp-title">AI 기록</h2><p class="bp-sub">사서가 한 일을 날짜별로 보여 줘요 · 최근 100개</p></div>' +
      '<button class="icon-btn" type="button" data-bp="close" aria-label="닫기 · esc">' + ic('x') + '</button></div>' +
      '<div class="bp-engine" data-r="engine"></div><div data-r="conf"></div>' +
      '<div class="bp-body" data-r="body"></div>' +
      '<div class="bp-foot">' + ic('info') + '<span><kbd>↑</kbd><kbd>↓</kbd> 이동 · <kbd>u</kbd> 되돌리기 · <kbd>esc</kbd> 닫기 · 옮기기·휴지통은 30일 안에 되돌릴 수 있어요</span></div></div>';
    document.body.appendChild(scrim);
    sheet = scrim.firstChild;
    scrim.addEventListener('mousedown', e => { if (e.target === scrim) closeLog(); });
    scrim.addEventListener('click', onLogClick);
    renderLog();
    void scrim.offsetWidth;
    scrim.classList.add('visible');
    sheet.focus({ preventScroll: true });
    loadLog();
  }
  function closeLog() {
    if (!isOpenFlag) return;
    isOpenFlag = false; logSeq++;
    const s = scrim; scrim = sheet = null;
    if (s) { s.classList.remove('visible'); if (s.parentNode) s.parentNode.removeChild(s); }
    if (lastFocus && lastFocus.focus && document.contains(lastFocus)) { try { lastFocus.focus({ preventScroll: true }); } catch (_) { /* 포커스를 못 돌려줘도 괜찮다 */ } }
    lastFocus = null;
  }
  async function loadLog() {
    if (!isOpenFlag) return;
    const my = ++logSeq;
    const [al, bs] = await Promise.all([call('aiLog', { limit: 100 }), call('brainSettings', {})]);
    if (my !== logSeq || !isOpenFlag) return;
    if (!al || al.ok === false) log.error = (al && al.error) || '기록을 불러오지 못했어요';
    else { log.error = null; log.entries = al.entries || []; log.engine = al.engine || null; }
    if (bs && bs.ok !== false) log.stopped = !!bs.stopped;
    log.loaded = true;
    if (!log.entries.some(x => x.id === selId)) { const u = log.entries.find(x => x.undoable); selId = u ? u.id : (log.entries[0] ? log.entries[0].id : null); }
    renderLog();
  }
  function renderLog() {
    if (!sheet) return;
    keepFocus(sheet, renderLogNow);
  }
  function renderLogNow() {
    if (!sheet) return;
    const en = sheet.querySelector('[data-r="engine"]');
    en.innerHTML = '<div class="bp-eng-t"><span class="bp-eng-dot' + (log.engine && log.engine.apple === 'ready' ? ' is-ai' : '') + '"></span><span>' + E(engineLine(log.engine)) + '</span></div>' +
      '<label class="bp-stop"><span class="bp-stop-t"><b>비상 정지</b><span>켜면 제안·이동·세션 읽기·기기 AI를 모두 멈춰요</span></span>' + swHTML('brain.stopped', log.stopped, '비상 정지', logBusy) + '</label>';
    const cf = sheet.querySelector('[data-r="conf"]');
    cf.innerHTML = conflicts && conflicts.length
      ? '<div class="bp-conf" role="alert"><div class="bp-conf-h">' + ic('alert') + '<b>되돌리지 못한 파일 ' + E(conflicts.length) + '개</b><button type="button" class="icon-btn sm" data-bp="conf-x" aria-label="닫기">' + ic('x') + '</button></div>' +
        '<p>그 사이에 파일이 바뀌어서 덮어쓰지 않았어요. 직접 확인해 주세요.</p><ul>' + conflicts.map(c => '<li><code>' + E(c.path) + '</code><span>' + E(c.reason) + '</span></li>').join('') + '</ul></div>' : '';
    const body = sheet.querySelector('[data-r="body"]');
    const top = body.scrollTop;
    if (!log.loaded) body.innerHTML = '<div class="bp-state"><i class="spinner lg"></i><span>불러오는 중이에요</span></div>';
    else if (log.error) body.innerHTML = '<div class="bp-state is-error"><strong>기록을 불러오지 못했어요</strong><span>' + E(log.error) + '</span><button class="btn sm" type="button" data-bp="retry">다시 시도</button></div>';
    else if (!log.entries.length) body.innerHTML = '<div class="bp-state"><strong>아직 기록이 없어요</strong><span>사서가 문서를 확인하거나 제안하면 여기에 남아요.</span></div>';
    else {
      let h = '', day = null;
      log.entries.forEach((x, i) => {
        if (x.day !== day) { day = x.day; h += '<h3 class="bp-day">' + E(day) + '</h3>'; }
        const on = x.id === selId, firstU = on && x.undoable;
        h += '<div class="bp-row' + (on ? ' is-sel' : '') + '" data-i="' + i + '" role="listitem">' +
          '<span class="bp-time num">' + E(x.tsLabel) + '</span><span class="bp-ic" data-k="' + E(x.kind) + '">' + ic(KIND_ICON[x.kind] || 'info') + '</span>' +
          '<span class="bp-tx">' + E(x.text) + '</span>' +
          '<span class="bp-tags"><span class="bx-src" data-o="' + ORIGIN_CLS(x.origin) + '">' + E(x.originLabel || x.origin || '규칙') + '</span>' +
          (x.undoable ? '<button type="button" class="btn sm" data-bp="undo" data-i="' + i + '"' + (logBusy ? ' disabled' : '') + '>되돌리기' + (firstU ? '<kbd>u</kbd>' : '') + '</button>' : '') + '</span></div>';
      });
      body.innerHTML = h;
    }
    body.scrollTop = top;
    const on = body.querySelector('.bp-row.is-sel'); if (on && on.scrollIntoView) on.scrollIntoView({ block: 'nearest' });
  }
  async function undoEntry(x) {
    if (!x || !x.undoable || logBusy) return;
    logBusy = true; renderLog();
    const r = await call('undo', { batchId: x.batchId });
    logBusy = false;
    if (!isOpenFlag) return;
    if (!r || r.ok === false) api.toast((r && r.error) || '되돌리지 못했어요', 'error');
    else if (r.conflicts && r.conflicts.length) { conflicts = r.conflicts; api.toast('일부만 되돌렸어요 · 충돌 ' + r.conflicts.length + '개는 그대로 뒀어요', 'error'); }
    else { conflicts = null; api.toast('되돌렸어요 · 파일 ' + (r.restored || 0) + '개'); }
    await loadLog();
  }
  async function toggleSetting(key, on, okOn, okOff) {
    const r = await call('setBrainSetting', { key, value: on ? '1' : '0' });
    if (!r || r.ok === false) { api.toast((r && r.error) || '바꾸지 못했어요', 'error'); return false; }
    api.toast(on ? okOn : okOff);
    return true;
  }
  async function onLogClick(e) {
    const b = e.target.closest('[data-bp]');
    if (b) {
      const act = b.dataset.bp;
      if (act === 'close') return closeLog();
      if (act === 'retry') { log.loaded = false; renderLog(); return loadLog(); }
      if (act === 'conf-x') { conflicts = null; return renderLog(); }
      if (act === 'undo') return undoEntry(log.entries[+b.dataset.i]);
      if (act === 'sw' && b.dataset.key === 'brain.stopped') {
        const next = b.getAttribute('aria-checked') !== 'true';
        logBusy = true; renderLog();
        await toggleSetting('brain.stopped', next, '사서를 멈췄어요', '사서를 다시 시작했어요');
        logBusy = false; return loadLog();
      }
      return;
    }
    const row = e.target.closest('.bp-row');
    if (row) { const x = log.entries[+row.dataset.i]; if (x) { selId = x.id; renderLog(); } }
  }
  function moveSel(d) {
    if (!log.entries.length) return;
    let i = log.entries.findIndex(x => x.id === selId); if (i < 0) i = 0;
    i = Math.max(0, Math.min(log.entries.length - 1, i + d));
    selId = log.entries[i].id; renderLog();
  }
  function onKey(e) {
    if (!isOpenFlag || !api || e.isComposing || e.keyCode === 229) return false;
    const k = e.key;
    if (k === 'Escape') { e.preventDefault(); closeLog(); return true; }
    if (k === 'Tab' && sheet) {
      const f = Array.from(sheet.querySelectorAll('button:not([disabled])')); if (!f.length) { e.preventDefault(); return true; }
      const i = f.indexOf(document.activeElement);
      const n = e.shiftKey ? (i <= 0 ? f.length - 1 : i - 1) : (i < 0 || i === f.length - 1 ? 0 : i + 1);
      e.preventDefault(); f[n].focus({ preventScroll: true }); return true;
    }
    if (e.metaKey || e.ctrlKey || e.altKey) return false;
    if (k === 'ArrowDown' || k === 'ArrowUp') { e.preventDefault(); moveSel(k === 'ArrowDown' ? 1 : -1); return true; }
    const ch = /^[a-zA-Z]$/.test(k) ? k.toLowerCase() : (/^Key[A-Z]$/.test(e.code || '') ? e.code.slice(3).toLowerCase() : '');
    if (ch === 'j' || ch === 'k') { e.preventDefault(); moveSel(ch === 'j' ? 1 : -1); return true; }
    if (ch === 'u') {
      e.preventDefault();
      if (e.repeat || logBusy) return true; // 키를 계속 눌러도 되돌리기는 한 번만
      const x = log.entries.find(y => y.id === selId);
      if (x && x.undoable) undoEntry(x); // 고른 줄만 되돌린다. 다른 줄로 바꿔 고르지 않는다
      else api.toast('고른 줄은 되돌릴 수 없어요. 되돌리기 버튼이 있는 줄을 골라 주세요');
      return true;
    }
    return false;
  }

  // =====================================================================
  // 설정 › 사서 (§9.8)
  // =====================================================================
  let noticeMarked = false;
  function renderSettings(el) {
    if (!api || !el) return;
    if (setEl !== el) { setEl = el; S = { bs: null, pol: null, lim: null, error: null, loaded: false }; clearAsk = false; }
    if (!el.__bpBound) { el.__bpBound = true; el.addEventListener('click', onSetClick); el.addEventListener('change', onSetChange); el.addEventListener('keydown', onSetKey); }
    paintSettings();
    loadSettings();
  }
  async function loadSettings() {
    if (!setEl) return;
    const my = ++setSeq;
    const [bs, pend, pol] = await Promise.all([call('brainSettings', {}), call('pending', {}), polOpen ? call('policy', {}) : Promise.resolve(null)]);
    if (my !== setSeq || !setEl) return;
    if (!bs || bs.ok === false) { S.error = (bs && bs.error) || '사서를 열지 못했어요'; S.bs = null; }
    else { S.error = null; S.bs = bs; }
    S.lim = pend && pend.ok !== false ? pend.limits || null : S.lim;
    if (pol && pol.ok !== false) S.pol = pol;
    S.loaded = true;
    paintSettings();
    const en = S.bs && S.bs.engine;
    if (en && en.noticeShown === false && !noticeMarked) { noticeMarked = true; call('setBrainSetting', { key: 'apple.noticeShown', value: '1' }); } // 안내를 한 번 보여 줬다고 기록
  }
  function row(title, desc, right, cls) {
    return '<div class="set-row bp-row2' + (cls ? ' ' + cls : '') + '"><div class="set-t"><span class="set-l">' + title + '</span>' + (desc ? '<p class="set-d">' + desc + '</p>' : '') + '</div>' + (right || '') + '</div>';
  }
  function dirLine(name, d) {
    if (!d) return '';
    return '<li><b>' + E(name) + '</b> ' + (d.found ? '세션 ' + E(d.sessions) + '개 · 파일 ' + E(d.files) + '개' : '폴더를 찾지 못했어요') + ' <code>' + E(d.dir) + '</code></li>';
  }
  function sessionsHTML(bs) {
    const s = bs.sessions || {}, en = s.enabled;
    const pill = en === true ? '<span class="pill is-ok">켜짐</span>' : en === false ? '<span class="pill">꺼짐</span>' : '<span class="pill is-na">아직 안 정했어요</span>';
    const have = ((s.claude && s.claude.sessions) || 0) + ((s.codex && s.codex.sessions) || 0) > 0;
    let h = '<div class="bp-sub2">세션 기록</div><div class="set-group">';
    h += row('Claude·Codex 세션 기록 읽기', en === true ? '이 Mac의 세션 기록에서 아래 항목만 읽어요. 켜 두면 "하던 일"과 AI가 쓴 문서를 더 정확히 알아봐요.'
      : en === false ? '꺼져 있어요. 켜면 "하던 일"과 AI가 쓴 문서를 더 정확히 알아봐요.' : '아직 정하지 않았어요. 켜면 "하던 일"과 AI가 쓴 문서를 더 정확히 알아봐요.', pill);
    h += '<div class="bp-fields"><div class="bp-fields-l">읽는 것</div><div class="bp-fields-c">' + (s.fields || []).map(f => '<span class="bx-chip">' + E(f) + '</span>').join('') + '</div>' +
      '<p class="set-d">AI 답변·도구 결과·파일 내용은 읽지 않고, 이 Mac 밖으로 보내지 않아요. 요청 문장은 30일 뒤 지워져요.</p></div>';
    h += row('내 요청 첫 줄도 보기', '80자까지 저장하고 키·토큰·메일·주소는 가려요. 끄면 새 요청 문장은 저장하지 않아요.', swHTML('sessions.requestText', s.requestText, '내 요청 첫 줄도 보기', setBusy === 'sessions.requestText'));
    h += '<div class="bp-stats"><ul>' + dirLine('Claude Code', s.claude) + dirLine('Codex', s.codex) + '</ul>' +
      '<p>마지막 읽기 ' + E(agoLabel(s.lastScan)) + (s.writesMatched != null ? ' · AI가 쓴 파일과 맞춘 것 ' + E(s.writesMatched) + '개' : '') + '</p></div>';
    if (s.error) h += '<div class="form-error" role="alert">' + ic('alert') + '<span>' + E(s.error) + '</span></div>';
    if (clearAsk) {
      h += '<div class="bp-ask" role="alertdialog"><p>' + (en === true ? '세션 기록 읽기를 끄고, ' : '') + '지금까지 읽은 세션 기록(요청 문장·AI가 쓴 파일 목록)을 모두 지울까요? 되돌릴 수 없어요. Claude가 쓴 문서는 다시 경로로 짐작해요.</p>' +
        '<div class="bp-ask-b"><button class="btn sm danger" type="button" data-bp="clear-yes">' + (en === true ? '끄고 지우기' : '지우기') + '</button><button class="btn sm" type="button" data-bp="clear-no">취소</button></div></div>';
    } else {
      h += '<div class="bp-btns">' + (en === true ? '<button class="btn sm" type="button" data-bp="ses-off">끄기</button><button class="btn sm" type="button" data-bp="clear-ask">끄고 지우기</button>'
        : '<button class="btn sm primary" type="button" data-bp="ses-on">켜기</button>' + (have ? '<button class="btn sm" type="button" data-bp="clear-ask">기록 지우기</button>' : '')) + '</div>';
    }
    return h + '</div>';
  }
  function aiHTML(bs) {
    const en = bs.engine || {}, ready = en.apple === 'ready', emph = en.noticeShown === false && !ready;
    const pill = ready ? '<span class="pill is-ok">사용 중</span>' : en.apple === 'unsupported' ? '<span class="pill is-na">지원 안 함</span>' : '<span class="pill">꺼짐</span>';
    const d = ready ? '한 줄 요약과 이유 문장을 이 Mac 안에서 다듬어요' + (en.pending > 0 ? ' · 대기 ' + E(en.pending) + '개' : '') + '. 원문에서 확인되지 않는 문장은 쓰지 않아요.'
      : en.apple === 'unsupported' ? '이 Mac에서는 기기 AI를 쓸 수 없어요. 규칙만으로 모든 기능이 그대로 돌아가요.'
      : '시스템 설정 › Apple Intelligence 및 Siri에서 켜면 한 줄 요약과 이유 문장이 생겨요. 안 켜도 나머지는 그대로예요.' + (en.reason ? ' (' + E(en.reason) + ')' : '');
    return '<div class="bp-sub2">기기 AI</div><div class="set-group' + (emph ? ' is-emph' : '') + '">' + row('Apple Intelligence', d, pill) + '</div>';
  }
  function polHTML(p) {
    if (!polOpen) return '';
    if (!p) return '<div class="bp-pol"><i class="spinner"></i></div>';
    const c = p.counts || {};
    let h = '<div class="bp-pol"><div class="bp-pol-c">' + ['place', 'frozen', 'exclude', 'landing', 'duty'].map(k => E(RULE_KIND[k]) + ' ' + E(c[k] || 0)).join(' · ') + '</div><div class="bp-pol-list">';
    rulesList(p.rules).forEach(r => { h += '<div class="bp-pr"><span class="bx-kind" data-k="' + E(r.kind) + '">' + E(RULE_KIND[r.kind] || r.kind) + '</span><span class="bp-pp">' + E(r.pattern) + (r.target ? ' <i>→</i> ' + E(r.target) : '') + '</span>' + (r.note ? '<span class="bp-pn">' + E(r.note) + '</span>' : '') + '</div>'; });
    if (!(p.rules || []).length) h += '<p class="set-d">읽은 규칙이 없어요.</p>';
    h += '</div>';
    if ((p.violations || []).length) h += '<div class="bp-pol-v"><b>점검 결과</b><ul>' + p.violations.map(v => '<li>' + (v.docId ? '<button type="button" class="link-btn" data-bp="open-doc" data-doc="' + E(v.docId) + '">' + E(v.text) + '</button>' : E(v.text)) + '</li>').join('') + '</ul></div>';
    if ((p.sources || []).length) h += '<p class="set-d">읽은 파일 · ' + p.sources.map(x => E(x.path) + (x.mtimeLabel ? ' (' + E(x.mtimeLabel) + ')' : '')).join(' · ') + '</p>';
    return h + '</div>';
  }
  function organizeHTML(bs) {
    const p = bs.policy || {}, lim = S.lim;
    const pill = !p.approved ? '<span class="pill is-na">승인 전</span>' : p.stale ? '<span class="pill is-warn">바뀜 · 확인 필요</span>' : '<span class="pill is-ok">승인됨</span>';
    let h = '<div class="bp-sub2">정리</div><div class="set-group">';
    h += row('폴더 규칙표', '규칙 ' + E(p.ruleCount || 0) + '개 · 볼트 CLAUDE.md에서 읽어요. 사서는 규칙표를 읽기만 하고 파일을 고치지 않아요.' + (!p.approved || p.stale ? ' 정리함(⌘3)에서 확인해 주세요.' : ''),
      pill + '<button class="btn sm" type="button" data-bp="pol-toggle" aria-expanded="' + polOpen + '">' + (polOpen ? '접기' : '규칙표 보기') + '</button>');
    h += polHTML(S.pol);
    if (lim) h += row('오늘 상한', '오늘 ' + E(lim.usedToday) + '/' + E(lim.perDay) + '건 옮겼어요. 한 번에 최대 ' + E(lim.perApply) + '건까지만 옮겨요.' + (lim.firstWeeks ? ' 처음 2주는 더 적게 옮겨요.' : ''), '');
    if (bs.trash) h += row('Synapse 휴지통', '지금 ' + E(bs.trash.count || 0) + '개 · 지운 문서는 ' + E(bs.trash.retentionDays || 30) + '일 동안 보관한 뒤 macOS 휴지통으로 옮겨요. 정리함(⌘3) 아래에서 되살릴 수 있어요. 영구 삭제는 하지 않아요.', '');
    h += row('비상 정지', '켜면 제안 만들기·파일 이동·세션 읽기·기기 AI를 모두 멈춰요. 읽기 화면은 그대로예요.', swHTML('brain.stopped', bs.stopped, '비상 정지', setBusy === 'brain.stopped'));
    return h + '</div>';
  }
  // v0.9 정리 구역 (docs/V09.md §7.5): bs.tidy = tidyRules() 모양 {auto, dailyCap, codeFolder, codeFolderResolved, reviewDay, builtin, learned}
  const REVIEW_DAYS = [['mon', '월요일'], ['tue', '화요일'], ['wed', '수요일'], ['thu', '목요일'], ['fri', '금요일'], ['off', '끄기']];
  const RULE_STATES = [['auto', '자동'], ['ask', '묻기'], ['off', '끄기']];
  function ruleRow(r, learned) {
    const sub = learned ? (r.approvals != null ? '승인 ' + E(r.approvals) + '번' : '') : '기본 규칙';
    return '<div class="td-rule"><div class="td-rule-t"><b>' + E(r.label || r.signature) + '</b><span>' + E([sub, learned ? '' : '확실한 것만 자동'].filter(Boolean).join(' · ')) + '</span></div>' +
      '<div class="bw-seg" role="group" aria-label="' + E((r.label || r.signature) + ' 처리 방식') + '">' + RULE_STATES.map(([v, l]) =>
        '<button type="button" data-bp="rule" data-sig="' + E(r.signature) + '" data-state="' + v + '" aria-pressed="' + (r.state === v) + '"' + (setBusy ? ' disabled' : '') +
        ' title="' + (v === 'auto' ? '조건이 맞으면 물어보지 않고 해요' : v === 'ask' ? '제안만 만들고 승인을 기다려요' : '이 종류는 제안하지 않아요') + '">' + l + '</button>').join('') + '</div></div>';
  }
  function tidyHTML(bs) {
    const t = bs.tidy;
    if (!t || typeof t !== 'object') return '';
    const resolved = t.codeFolderResolved ? String(t.codeFolderResolved) : '';
    let h = '<div class="bp-sub2">정리 (작업 지도)</div><div class="set-group td-set">';
    h += row('자동 정리', '확실한 것만 알아서 해요: 티켓 번호가 붙은 파일은 그 티켓 폴더로, 원자료는 색인에서 빼요. 24시간 넘게 그대로인 것만, 모두 되돌릴 수 있어요. 휴지통은 언제나 승인이 필요해요.',
      swHTML('tidy.auto', t.auto !== false, '자동 정리', setBusy === 'tidy.auto'));
    h += row('하루 상한', '자동으로 하는 정리는 하루 최대 이만큼까지예요(한 번에 10건). 넘으면 다음 날 이어서 해요.',
      '<input class="input" type="number" min="0" max="200" step="1" inputmode="numeric" data-bp="cap" value="' + E(t.dailyCap != null ? t.dailyCap : 20) + '" aria-label="하루 자동 정리 상한" style="width:76px">');
    h += row('코드 폴더', '코드 저장소(.git)는 볼트 대신 이 폴더로 옮겨요. ' + (t.codeFolder ? '' : '비워 두면 ~/IdeaProjects가 있을 때 그곳을 써요. ') + (resolved ? '지금은 ' + E(resolved) : '아직 정해진 곳이 없어요'),
      '<span class="td-folder"><input class="input" type="text" data-bp="code" value="' + E(t.codeFolder || '') + '" placeholder="~/IdeaProjects" aria-label="코드 폴더" spellcheck="false" autocomplete="off">' +
      '<button class="btn sm" type="button" data-bp="code-apply"' + (setBusy ? ' disabled' : '') + '>적용</button></span>');
    h += row('리뷰 요일', '그날 첫 열기에 홈에 정리 리뷰 카드가 뜨고, Claude가 한 주를 훑어 정리 계획을 만들어요.',
      '<select class="input" data-bp="review" aria-label="리뷰 요일">' + REVIEW_DAYS.map(([v, l]) => '<option value="' + v + '"' + ((t.reviewDay || 'fri') === v ? ' selected' : '') + '>' + l + '</option>').join('') + '</select>');
    h += '</div>';
    const learned = Array.isArray(t.learned) ? t.learned : [], builtin = Array.isArray(t.builtin) ? t.builtin : [];
    h += '<div class="bp-sub2">정리 규칙</div><div class="set-group td-set">' + builtin.map(r => ruleRow(r, false)).join('');
    h += learned.length ? learned.map(r => ruleRow(r, true)).join('') : '<p class="td-note">같은 종류의 정리를 3번 승인하면 여기에 올려서 자동으로 할지 물어봐요.</p>';
    h += '<p class="td-note">비밀 파일·코드 저장소·동결 폴더·숨김 파일은 자동으로 다루지 않아요. 휴지통은 규칙이 있어도 항상 승인이에요.</p></div>';
    return h;
  }
  function mcpHTML(bs) {
    let h = '<div class="bp-sub2">MCP</div><div class="set-group">' + row('Claude·Codex에 Confluence·Jira 본문 보여 주기', '끄면 Confluence·Jira 본문은 MCP로 나가지 않아요. 세션 기록 문장은 켜도 MCP로 나가지 않아요.', swHTML('mcp.remoteBodies', bs.mcpRemoteBodies, 'Confluence·Jira 본문 보여 주기', setBusy === 'mcp.remoteBodies'));
    // v0.6 T (COMMON C4): mcpDirectApply "on"/"off" — 켜면 apply_changes가 승인 없이 옮기고 휴지통으로
    if (bs.mcpDirectApply != null) {
      const on = bs.mcpDirectApply === 'on' || bs.mcpDirectApply === true;
      h += row('Claude·Codex가 바로 정리(승인 없이 옮기기·휴지통)', '켜면 승인 없이 실행돼요. 지운 파일은 Synapse 휴지통에 30일 보관되고 AI 기록에서 되돌릴 수 있어요. 꺼 두면 지금처럼 정리함에서 승인해야 해요. 하루 60건까지예요.',
        swHTML('mcpDirectApply', on, 'Claude·Codex가 바로 정리', setBusy === 'mcpDirectApply'));
      if (directAsk) h += '<div class="bp-ask" role="alertdialog"><p>Claude·Codex가 승인 없이 문서를 옮기고 Synapse 휴지통으로 보낼 수 있게 할까요? 동결·제외 구역과 CLAUDE.md 같은 보호 파일은 건드리지 않고, 한 일은 모두 AI 기록에 남아요.</p>' +
        '<div class="bp-ask-b"><button class="btn sm danger" type="button" data-bp="direct-yes">켜기</button><button class="btn sm" type="button" data-bp="direct-no">취소</button></div></div>';
    }
    return h + '</div>';
  }
  function paintSettings() {
    if (!setEl) return;
    const ae = document.activeElement;
    if (ae && setEl.contains(ae) && ae.tagName === 'INPUT' && ae.dataset.bp && ae.type !== 'checkbox') return;   // 입력하는 중에는 다시 그리지 않는다
    let h = '<div class="bp-set"><div class="sheet-sec bp-set-h">사서</div>';
    if (!S.loaded) h += '<div class="bp-state"><i class="spinner"></i><span>불러오는 중이에요</span></div>';
    else if (S.error || !S.bs) h += '<div class="form-error" role="alert">' + ic('alert') + '<span>' + E(S.error || '사서를 열지 못했어요') + '</span></div>';
    else h += sessionsHTML(S.bs) + aiHTML(S.bs) + organizeHTML(S.bs) + tidyHTML(S.bs) + mcpHTML(S.bs);
    keepFocus(setEl, () => { setEl.innerHTML = h + '</div>'; });
  }
  async function setSetting(key, value) { const r = await call('setBrainSetting', { key, value }); if (!r || r.ok === false) { api.toast((r && r.error) || '바꾸지 못했어요', 'error'); return false; } return true; }
  async function onSetClick(e) {
    const b = e.target.closest('[data-bp]'); if (!b || !setEl || !setEl.contains(b)) return;
    const act = b.dataset.bp;
    if (act === 'open-doc') return api.openDoc(b.dataset.doc);
    if (act === 'pol-toggle') { polOpen = !polOpen; paintSettings(); if (polOpen) loadSettings(); return; }
    if (act === 'clear-ask') { clearAsk = true; return paintSettings(); }
    if (act === 'clear-no') { clearAsk = false; return paintSettings(); }
    if (act === 'direct-no') { directAsk = false; return paintSettings(); }
    if (act === 'direct-yes' || (act === 'sw' && b.dataset.key === 'mcpDirectApply')) {
      if (setBusy) return;
      const next = act === 'direct-yes' ? true : b.getAttribute('aria-checked') !== 'true';
      if (next && act !== 'direct-yes') { directAsk = true; return paintSettings(); }   // 켤 때는 한 번 더 묻는다
      directAsk = false; setBusy = 'mcpDirectApply'; paintSettings();
      if (await setSetting('mcpDirectApply', next ? 'on' : 'off')) api.toast(next ? 'Claude·Codex가 바로 정리할 수 있어요 · AI 기록에서 되돌릴 수 있어요' : '이제 정리함에서 승인해야 옮기고 지워요');
      setBusy = ''; return loadSettings();
    }
    if (act === 'sw') {
      const key = b.dataset.key; if (setBusy) return;
      const next = b.getAttribute('aria-checked') !== 'true';
      setBusy = key; paintSettings();
      const msg = { 'brain.stopped': ['사서를 멈췄어요', '사서를 다시 시작했어요'], 'mcp.remoteBodies': ['Claude·Codex가 Confluence·Jira 본문을 읽을 수 있어요', 'Confluence·Jira 본문은 MCP로 나가지 않아요'], 'sessions.requestText': ['내 요청 첫 줄도 보여 드릴게요', '새 요청 문장은 저장하지 않아요'], 'tidy.auto': ['확실한 정리는 알아서 할게요 · 오늘 한 일은 작업 지도에 남아요', '이제 모든 정리는 승인해야 해요'] }[key] || ['켰어요', '껐어요'];
      if (await setSetting(key, next ? '1' : '0')) api.toast(next ? msg[0] : msg[1]);
      setBusy = ''; return loadSettings();
    }
    if (act === 'rule') {
      if (setBusy) return;
      setBusy = 'rule'; paintSettings();
      const r = await call('tidySetRule', { signature: b.dataset.sig, state: b.dataset.state });
      setBusy = '';
      if (!r || r.ok === false) api.toast((r && r.error) || '바꾸지 못했어요', 'error');
      else api.toast(b.dataset.state === 'auto' ? '앞으로 자동으로 해요' : b.dataset.state === 'ask' ? '앞으로 물어볼게요' : '이 종류는 더 제안하지 않아요');
      return loadSettings();
    }
    if (act === 'code-apply') { const inp = setEl.querySelector('input[data-bp="code"]'); return applyTidyValue('tidy.codeFolder', inp ? inp.value.trim() : '', '코드 폴더를 바꿨어요'); }
    if (act === 'ses-on') { if (await setSetting('sessions.enabled', '1')) api.toast('세션 기록 읽기를 켰어요'); return loadSettings(); }
    if (act === 'ses-off') { if (await setSetting('sessions.enabled', '0')) api.toast('세션 기록 읽기를 껐어요 · 이미 읽은 기록은 그대로 있어요'); return loadSettings(); }
    if (act === 'clear-yes') {
      clearAsk = false;
      const was = S.bs && S.bs.sessions && S.bs.sessions.enabled === true;
      const ok = (!was || await setSetting('sessions.enabled', '0')) && await setSetting('sessions.clear', '1');
      if (ok) api.toast(was ? '세션 기록 읽기를 끄고 모두 지웠어요' : '세션 기록을 모두 지웠어요');
      return loadSettings();
    }
  }

  async function applyTidyValue(key, value, okMsg) {
    if (setBusy) return;
    setBusy = key;
    const ok = await setSetting(key, value);
    setBusy = '';
    if (ok) api.toast(okMsg);
    return loadSettings();
  }
  function onSetChange(e) {
    const t = e.target; if (!t || !t.dataset) return;
    if (t.dataset.bp === 'cap') {
      const n = Math.round(Number(t.value));
      if (!(n >= 0 && n <= 200)) { api.toast('하루 상한은 0~200 사이 숫자예요', 'error'); return loadSettings(); }
      return applyTidyValue('tidy.dailyCap', String(n), '하루 자동 정리를 ' + n + '건까지로 했어요');
    }
    if (t.dataset.bp === 'review') return applyTidyValue('tidy.reviewDay', t.value, t.value === 'off' ? '정리 리뷰를 껐어요' : '리뷰 요일을 바꿨어요');
  }
  function onSetKey(e) {
    const t = e.target; if (!t || !t.dataset || e.isComposing || e.keyCode === 229) return;
    if (t.tagName === 'INPUT' && t.dataset.bp === 'code' && e.key === 'Enter') { e.preventDefault(); e.stopPropagation(); applyTidyValue('tidy.codeFolder', t.value.trim(), '코드 폴더를 바꿨어요'); }
    else if (t.tagName === 'INPUT' && (t.dataset.bp === 'code' || t.dataset.bp === 'cap')) e.stopPropagation();   // 입력은 입력칸이 받는다(앱 단축키로 새지 않게)
  }

  // U1이 synapseBrainEvent를 받으면 부른다 (log·settings·policy 이벤트)
  // 이벤트가 몰려도 150ms 모아서 한 번만. 설정 섹션은 눈에 보일 때만 다시 불러온다.
  let refreshTimer = 0;
  function settingsVisible() { return !!setEl && document.contains(setEl) && setEl.getClientRects().length > 0; }
  function refresh() {
    if (refreshTimer) return;
    refreshTimer = setTimeout(() => {
      refreshTimer = 0;
      if (isOpenFlag) loadLog();
      if (settingsVisible()) loadSettings();
    }, 150);
  }

  window.SynapseBrainPanel = Object.freeze({ init, openLog, closeLog, isOpen, onKey, renderSettings, refresh });
})();
