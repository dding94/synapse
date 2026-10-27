// queue.js — Synapse v0.5 정리함 (docs/V05.md §9.5). window.SynapseQueue 하나만 만든다.
// mount(listEl, readerEl) · refresh() · onKey(e) → bool · focus() · unmount()  + init(api)
// v0.8 (docs/V08.md §8.5): Jira 카드(kind "jira") — 승인(y)은 확인 뒤 jiraApply, 거절(n)은 decide reject, 고치기(e)는 댓글 글·바꿀 상태.
(function () {
  'use strict';

  let api = null, listEl = null, readerEl = null, root = null, headEl = null, noteEl = null, cardsEl = null;
  let data = null, loadError = null, loading = false;
  let sel = 0, busy = false, seq = 0, prevSeq = 0;
  let editId = null, pick = { q: '', idx: 0, rows: [] }; // e: 목적지 고르기
  let confirmId = null;                                  // 묶음 승인 확인
  let note = null;                                       // 위쪽 알림 줄 {tone, text, undo, skipped[]}
  let deferred = false, runningBatch = false;
  let folderPool = null, folderPoolTried = false;
  const docCache = new Map();
  // v0.6 휴지통 구역 (COMMON C3 listTrash·restoreTrash·purgeTrash). 브리지가 없으면(예시 자료) 구역을 숨긴다.
  let trash = null, trashOpen = false, trashBusy = '', trashAsk = null, trashEl = null;
  // v0.8 Jira 카드: 고치는 중인 카드 · 고친 값(반영할 때 jiraApply의 body·to로 보낸다) · 반영 중인 카드 · 상태 구독
  let jEdit = null, jApplyId = null, applyingTimer = 0, offAI = null;
  const jEdits = new Map();

  const E = v => api.esc(v == null ? '' : String(v));
  const ic = n => { try { return api.icon(n) || ''; } catch (_) { return ''; } };
  const KIND_ICON = { move: 'folder', bundle: 'stack', rules: 'sliders', policy: 'alert', delete: 'trash', jira: 'ticket', tidy: 'folder' };
  // v0.9 정리 비서 카드(kind "tidy", docs/V09.md §4.9) — 모양이 달라서 따로 그린다. y/n/s/e는 같은 decide(id "t:…")로 간다.
  const TIDY_OP_ICON = { move: 'move', merge: 'stack', archive: 'inbox', exclude: 'minus', trash: 'trash', note: 'alert' };
  const TIDY_OP_LABEL = { move: '옮기기', merge: '합치기', archive: '보관', exclude: '색인 제외', trash: '휴지통', note: '알림' };
  const TIDY_DONE = { move: '옮겼어요', merge: '합쳤어요', archive: '보관으로 옮겼어요', exclude: '색인에서 뺐어요', trash: '휴지통으로 보냈어요' };
  const TIDY_CERT = { certain: '확실', likely: '아마', unsure: '확인 필요' };
  const isTidy = c => !!c && c.kind === 'tidy';
  const RULE_KIND = { place: '배치', frozen: '동결', exclude: '제외', landing: '출발지', duty: '점검' };
  const cards = () => (data && data.cards) || [];
  const cur = () => cards()[sel] || null;
  const conflictOf = c => (c && c.impact && c.impact.conflict) || null;
  const originCls = o => (o === 'rules' || o === 'claude' || o === 'codex' ? o : 'other');
  const cut = (s, n) => { s = String(s == null ? '' : s).replace(/\s+/g, ' ').trim(); return s.length > n ? s.slice(0, n - 1) + '…' : s; };
  // ---------- Jira 카드 도우미 ----------
  const isJira = c => !!c && c.kind === 'jira';
  const jState = c => String(c.state || 'pending');
  const jApplying = c => jState(c) === 'applying' || (jApplyId != null && jApplyId === c.id);
  function jVals(c) {
    const ed = jEdits.get(c.id) || {};
    return { body: ed.body != null ? ed.body : c.body, to: ed.to != null ? ed.to : c.to, changed: (ed.body != null && ed.body !== c.body) || (ed.to != null && ed.to !== c.to) };
  }
  const jTitle = c => (c.op === 'create' ? (c.summary || c.title || '새 티켓') : (c.key || '') + (c.title ? ' · ' + c.title : ''));
  function jSub(c) {
    const v = jVals(c);
    if (c.op === 'transition') return '상태 바꾸기 · ' + (c.status ? c.status + ' → ' : '→ ') + (v.to || '');
    if (c.op === 'comment') return '댓글 · ' + cut(v.body, 44);
    return '새 티켓 · ' + (c.project || '');
  }
  const aiReady = () => { try { return !!(api && typeof api.aiAvailable === 'function' && api.aiAvailable()); } catch (_) { return false; } };

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

  // ---------- 자리 만들기 ----------
  function mount(l, r) {
    if (!api) return;
    unmount();
    listEl = l; readerEl = r || null;
    root = document.createElement('div');
    root.className = 'bq';
    root.innerHTML =
      '<div class="bq-head" data-r="head"></div>' +
      '<div class="bq-note-wrap" data-r="note"></div>' +
      '<div class="bq-scroll"><div class="bq-cards" data-r="cards" role="listbox" tabindex="0" aria-label="정리 제안 카드"></div>' +
      '<div class="bq-trash" data-r="trash" hidden></div></div>';
    listEl.textContent = '';
    listEl.appendChild(root);
    headEl = root.querySelector('[data-r="head"]');
    noteEl = root.querySelector('[data-r="note"]');
    cardsEl = root.querySelector('[data-r="cards"]');
    trashEl = root.querySelector('[data-r="trash"]');
    root.addEventListener('click', onClick);
    root.addEventListener('input', onInput);
    root.addEventListener('keydown', onOwnKey);
    sel = 0; editId = null; confirmId = null; note = null; folderPool = null; folderPoolTried = false;
    trash = null; trashBusy = ''; trashAsk = null; jEdit = null; jApplyId = null;
    // v0.8: Claude를 쓸 수 있는지가 바뀌면 머리의 Claude 단추를 다시 그린다
    const A = window.SynapseAI;
    if (A && typeof A.on === 'function') { try { offAI = A.on('status', () => { if (root) renderHead(); }); } catch (_) { offAI = null; } }
    renderAll();
    refresh();
  }
  function unmount() {
    seq++; prevSeq++;
    clearTimeout(applyingTimer); applyingTimer = 0;
    if (typeof offAI === 'function') { try { offAI(); } catch (_) { /* 무시 */ } }
    offAI = null; jEdit = null; jApplyId = null;
    if (root && root.parentNode) root.parentNode.removeChild(root);
    if (readerEl && readerEl.querySelector && readerEl.querySelector('.bq-prev')) readerEl.textContent = '';
    root = headEl = noteEl = cardsEl = listEl = readerEl = trashEl = null;
    data = null; busy = false; editId = null; confirmId = null; deferred = false;
  }
  function focus() { if (cardsEl) cardsEl.focus({ preventScroll: true }); }

  // ---------- 불러오기 ----------
  async function refresh() {
    if (!api || !root) return;
    if (editId || jEdit || confirmId || busy) { deferred = true; return; } // 입력 중에는 카드를 바꾸지 않는다
    return load();
  }
  async function load() {
    if (!api || !root) return;
    const my = ++seq;
    loading = !data;
    if (loading) renderAll();
    let res = null, err = null;
    let tr = null;
    try { [res, tr] = await Promise.all([api.call('pending', {}), call('listTrash', {})]); } catch (e) { err = e && e.message ? e.message : '불러오지 못했어요'; }
    if (my !== seq || !root) return;
    trash = tr && tr.ok !== false && Array.isArray(tr.items) ? tr : null;
    loading = false;
    if (err || !res || res.ok === false) { loadError = err || (res && res.error) || '불러오지 못했어요'; if (!data) data = null; }
    else {
      loadError = null;
      const keepId = cur() && cur().id;
      data = res;
      const i = keepId ? cards().findIndex(c => c.id === keepId) : -1;
      if (i >= 0) sel = i;
      else sel = Math.max(0, Math.min(sel, cards().length - 1));
    }
    if (note && note.undo) await checkUndoable();
    if (my !== seq || !root) return;
    const live = new Set(cards().map(c => c.id));
    Array.from(jEdits.keys()).forEach(k => { if (!live.has(k)) jEdits.delete(k); });
    if (jEdit && !live.has(jEdit)) jEdit = null;
    renderAll();
    watchApplying();
  }
  // 반영하는 중인 Jira 카드가 있으면(다른 곳에서 시작했거나 느릴 때) 2.5초마다 상태를 다시 읽는다
  function watchApplying() {
    clearTimeout(applyingTimer); applyingTimer = 0;
    if (!root || !cards().some(c => isJira(c) && jState(c) === 'applying') || jApplyId != null) return;
    applyingTimer = setTimeout(() => { applyingTimer = 0; refresh(); }, 2500);
  }
  // 되돌리기 버튼은 그 배치가 아직 되돌릴 수 있을 때만 둔다 (다른 곳에서 이미 되돌렸으면 없앤다)
  async function checkUndoable() {
    const id = note.undo;
    try {
      const r = await api.call('aiLog', { limit: 60 });
      if (r && r.entries && !r.entries.some(x => x.batchId === id && x.undoable)) { if (note && note.undo === id) note.undo = null; if (note && !note.undo && !(note.skipped && note.skipped.length)) note = null; }
    } catch (_) { /* 확인하지 못하면 그대로 둔다 */ }
  }

  // ---------- 그리기: 머리 ----------
  function renderHead() {
    if (!headEl) return;
    if (!data) { headEl.innerHTML = '<div class="bq-title-row"><h2 class="bq-h">정리함</h2></div>'; return; }
    const h = data.header || {}, lim = data.limits || {};
    const used = lim.usedToday != null && lim.perDay != null
      ? '<span class="bq-limit num" title="한 번에 최대 ' + E(lim.perApply) + '건 · 하루 최대 ' + E(lim.perDay) + '건' + (lim.firstWeeks ? ' · 처음 2주는 조심스럽게 적게 옮겨요' : '') + '">오늘 ' + E(lim.usedToday) + '/' + E(lim.perDay) + '</span>' : '';
    let h2 = '<div class="bq-title-row"><h2 class="bq-h">정리함</h2>' + used + '</div>';
    if (data.stopped) h2 += '<div class="bq-banner is-stop">' + ic('lock') + '<span>사서가 멈춰 있어요. 제안을 만들거나 파일을 옮기지 않아요.</span></div>';
    else if (data.policy && data.policy.stale && !cards().some(c => c.kind === 'rules')) h2 += '<div class="bq-banner">' + ic('info') + '<span>볼트 CLAUDE.md가 바뀌었어요. 규칙표를 다시 확인해 주세요.</span></div>';
    if (h.aiDid) h2 += '<p class="bq-did">' + E(h.aiDid) + '</p>';
    h2 += '<div class="bq-tools">' +
      '<button class="btn sm" type="button" data-act="claude" title="' + (aiReady() ? 'Claude가 정리 안 된 문서의 자리를 찾아 제안을 올려요 · 시키기 패널(⌘J)이 열려요' : 'Claude에게 정리를 맡길 지시문을 복사해요') + '">' + ic(aiReady() ? 'sparkle' : 'copy') + '<span>Claude에게 정리 맡기기</span><kbd>⌘⇧K</kbd></button>' +
      '<button class="btn sm' + (runningBatch ? ' is-busy' : '') + '" type="button" data-act="batch"' + (runningBatch || data.stopped ? ' disabled' : '') + ' title="새로 정리할 문서가 있는지 지금 다시 봐요">' +
      (runningBatch ? '<i class="spinner"></i>' : ic('refresh')) + '<span>지금 다시 보기</span></button></div>';
    if (data.lastBatchLabel) h2 += '<p class="bq-last">마지막으로 본 때 ' + E(data.lastBatchLabel) + '</p>';
    keepFocus(headEl, () => { headEl.innerHTML = h2; });
  }
  function renderNote() {
    if (!noteEl) return;
    if (!note) { noteEl.innerHTML = ''; return; }
    let s = '<div class="bq-note' + (note.tone === 'error' ? ' is-error' : '') + '" role="status">' +
      '<div class="bq-note-t">' + E(note.text) + '</div>';
    if (note.skipped && note.skipped.length) {
      s += '<ul class="bq-skips">' + note.skipped.map(k => '<li><b>' + E(k.title) + '</b> ' + E(k.reason) + '</li>').join('') + '</ul>';
    }
    s += '<div class="bq-note-b">' +
      (note.undo ? '<button class="btn sm" type="button" data-act="undo">' + ic('refresh') + '<span>되돌리기</span><kbd>⌥⌘Z</kbd></button>' : '') +
      (note.url ? '<button class="btn sm" type="button" data-act="open-url" data-url="' + E(note.url) + '">' + ic('external') + '<span>Jira에서 열기</span></button>' : '') +
      '<button class="icon-btn sm" type="button" data-act="note-x" aria-label="알림 닫기">' + ic('x') + '</button></div></div>';
    keepFocus(noteEl, () => { noteEl.innerHTML = s; });
  }

  // ---------- 그리기: 카드 ----------
  function chipsHTML(c) {
    return '<span class="bx-src" data-o="' + originCls(c.origin) + '">' + E(c.originLabel || c.origin || '규칙') + '</span>' +
      (c.confidence ? '<span class="bx-conf" data-c="' + E(c.confidence) + '">' + E(c.confidence) + '</span>' : '');
  }
  function impactHTML(c) {
    const im = c.impact || {};
    let s = '';
    if (c.kind === 'delete') {
      s += im.inbound > 0 ? '<div class="bq-imp is-bad">' + ic('link') + '<span>이 문서를 가리키는 링크 ' + E(im.inbound) + '개가 끊겨요</span></div>'
        : '<div class="bq-imp is-quiet">' + ic('check') + '<span>이 문서를 가리키는 링크는 없어요</span></div>';
      if (im.conflict) s += '<div class="bq-imp is-bad">' + ic('alert') + '<span>' + E(im.conflict) + '</span></div>';
      s += '<div class="bq-imp is-quiet">' + ic('trash') + '<span>Synapse 휴지통에 ' + E(im.retentionDays || 30) + '일 보관하고, AI 기록에서 되돌릴 수 있어요</span></div>';
    }
    if (c.kind === 'move' || c.kind === 'bundle') {
      if (im.links > 0) {
        s += '<div class="bq-imp">' + ic('follow') + '<span>링크 ' + E(im.links) + '개 고침' + (im.files > 0 ? ' · 파일 ' + E(im.files) + '개' : '') + (im.canvas > 0 ? ' · 캔버스 ' + E(im.canvas) + '개' : '') + '</span></div>';
      } else s += '<div class="bq-imp is-quiet">' + ic('check') + '<span>고칠 링크는 없어요</span></div>';
      if (im.conflict) s += '<div class="bq-imp is-bad">' + ic('alert') + '<span>' + E(im.conflict) + '</span></div>';
      if (im.sync) s += '<div class="bq-imp is-quiet">' + ic('info') + '<span>옵시디언 Sync로 다른 기기에도 반영돼요</span></div>';
    }
    return s ? '<div class="bq-impact">' + s + '</div>' : '';
  }
  function reasonsOf(c) {
    const r = (c.reasons || (c.reason ? [c.reason] : [])).filter(Boolean);
    if (r.length) return r;
    if (c.kind === 'jira') return [];
    if (c.kind === 'rules') return ['볼트 CLAUDE.md에서 읽은 규칙이에요'];
    if (c.kind === 'policy') return ['규칙표로 점검해서 찾았어요'];
    if (c.origin && c.origin !== 'rules') return [(c.originLabel || c.origin) + '이에요 · 승인은 Synapse에서만 해요'];
    return [c.confidence === '확정' ? '규칙표: 파일 이름·위치 규칙과 맞아요' : '규칙표: 폴더 중심과 링크 이웃으로 골랐어요'];
  }
  const ROOT_LABEL = '볼트 루트 낱개 파일';
  function rulesList(rs) {
    const out = (rs || []).map(r => Object.assign({}, r, { pattern: /^\.?\/?$/.test(String(r.pattern || '').trim()) ? ROOT_LABEL : r.pattern }));
    const frozen = new Set(out.filter(r => r.kind === 'frozen').map(r => r.pattern));
    return out.filter(r => !(r.kind === 'exclude' && frozen.has(r.pattern))); // 같은 경로가 동결·제외에 둘 다 있으면 동결 한 줄
  }
  function whyHTML(c) {
    const r = reasonsOf(c).slice(0, 3);
    return r.length ? '<ul class="bq-why">' + r.map(x => '<li>' + E(x) + '</li>').join('') + '</ul>' : '';
  }
  function dirOf(p) { const s = String(p || ''); const i = s.lastIndexOf('/'); return i >= 0 ? s.slice(0, i + 1) : ''; }
  function pathHTML(c) {
    if (c.kind === 'delete') return '<div class="bq-path is-del"><span class="bq-from" title="' + E(c.from) + '">' + E(c.from) + '</span><span class="bq-dest is-del"><i>→</i>Synapse 휴지통 (30일 보관)</span></div>';
    const to = c.to ? c.to : null;
    return '<div class="bq-path"><span class="bq-from" title="' + E(c.from) + '">' + E(c.from) + '</span>' +
      '<span class="bq-dest' + (to ? '' : ' is-none') + '" title="' + E(to || '') + '"><i>→</i>' + (to ? E(to) : '목적지를 골라 주세요 (e)') + '</span></div>';
  }
  function rulesHTML(c) {
    const rs = rulesList(c.rules);
    if (!rs.length) return '';
    return '<div class="bq-rules">' + rs.map(r => '<div class="bq-rule"><span class="bx-kind" data-k="' + E(r.kind) + '">' + E(RULE_KIND[r.kind] || r.kind) + '</span>' +
      '<span class="bq-rule-p" title="' + E(r.note || '') + '">' + E(r.pattern) + (r.target ? ' <i>→</i> ' + E(r.target) : '') + '</span></div>').join('') + '</div>';
  }
  function violationsHTML(c) {
    const vs = c.violations || [];
    return vs.length ? '<ul class="bq-viol">' + vs.map(v => '<li>' + (v.docId ? '<button type="button" class="link-btn" data-act="open-doc" data-doc="' + E(v.docId) + '">' + E(v.text) + '</button>' : E(v.text)) + '</li>').join('') + '</ul>' : '';
  }
  function itemsHTML(c) {
    const it = c.items || [];
    return it.length ? '<ul class="bq-items">' + it.map(x => '<li title="' + E(x.from) + '">' + ic('doc') + '<span>' + E(x.title) + '</span></li>').join('') + '</ul>' : '';
  }
  function actionsHTML(c) {
    const bad = !!conflictOf(c) || !!(data && data.stopped) || editingBlock(c);
    const b = (act, label, key, cls, dis) => '<button class="btn sm' + (cls ? ' ' + cls : '') + '" type="button" data-act="' + act + '"' + (dis ? ' disabled' : '') + '>' + label + (key ? '<kbd>' + key + '</kbd>' : '') + '</button>';
    if (isJira(c)) {   // v0.8: 승인 = 확인 뒤 jiraApply. 나중에(s)는 없다 — 그대로 두면 7일 뒤 사라진다
      const working = jApplying(c), failed = jState(c) === 'failed';
      return b('approve', working ? '<i class="spinner"></i>반영하는 중…' : failed ? '다시 시도' : 'Jira에 반영…', working ? '' : 'y', 'primary', working) + b('reject', '거절', 'n', '', working) +
        (c.op !== 'create' ? b('edit', c.op === 'comment' ? '댓글 고치기' : '상태 고치기', 'e', '', working) : '');
    }
    if (isTidy(c)) {
      if (c.op === 'note') return b('approve', '확인', 'y', 'primary') + b('later', '나중에', 's');
      return b('approve', c.op === 'trash' ? '휴지통으로' : c.op === 'exclude' ? '색인에서 빼기' : '승인', 'y', c.op === 'trash' ? 'danger' : 'primary', bad) + b('reject', '거절', 'n') + b('later', '나중에', 's') +
        (c.op === 'exclude' || c.op === 'trash' ? '' : b('edit', '자리 바꾸기', 'e'));
    }
    if (c.kind === 'rules') return b('approve', '규칙표 승인', 'y', 'primary') + b('later', '나중에', 's');
    if (c.kind === 'policy') return b('approve', 'Claude에게 맡기기', 'y', 'primary') + b('later', '나중에', 's') + b('reject', '닫기', 'n');
    if (c.kind === 'delete') return b('approve', '휴지통으로', 'y', 'danger', bad) + b('later', '나중에', 's') + b('reject', '거절', 'n');
    if (c.kind === 'bundle') {
      if (confirmId === c.id) {
        const n = (c.items || []).length, per = data && data.limits && data.limits.perApply;
        return '<div class="bq-confirm"><span>' + E(n) + '개를 옮길까요? <b>→ ' + E(c.to || '') + '</b>' + (per && n > per ? ' 한 번에 ' + E(per) + '개까지만 옮기고 나머지는 남겨 둬요.' : '') + ' 링크 영향은 없어요.</span>' +
          '<div class="bq-confirm-b">' + b('confirm-bundle', '옮기기', '↵', 'primary') + b('cancel-confirm', '취소', 'esc') + '</div></div>';
      }
      return b('approve', '모두 승인', '⇧Y', 'primary', bad || hasLinkImpact(c)) + b('later', '나중에', 's') + b('reject', '거절', 'n');
    }
    return b('approve', '승인', 'y', 'primary', bad || !c.to) + b('later', '나중에', 's') + b('reject', '거절', 'n') + b('edit', '목적지', 'e');
  }
  function hasLinkImpact(c) { return (c.items || []).some(x => x.impact && (x.impact.links > 0 || x.impact.conflict)) || (c.impact && c.impact.links > 0); }

  function jStateChip(c) {
    const st = jState(c);
    if (jApplying(c)) return '<span class="bq-jst is-applying"><i class="spinner"></i>반영하는 중</span>';
    return st === 'failed' ? '<span class="bq-jst is-failed">실패했어요</span>' : '';
  }
  // 무엇을 Jira에 보내는지 그대로 보여 준다: 상태 A → B / 댓글 글 / 새 티켓(프로젝트·요약)
  function jBlockHTML(c) {
    const v = jVals(c);
    let h = '<div class="bq-jira">';
    if (c.op === 'transition') h += '<div class="bq-jr"><span class="bq-jr-l">상태</span><span class="bq-jr-v"><b>' + E(c.status || '지금 상태') + '</b><i>→</i><b class="is-to">' + E(v.to || '') + '</b></span></div>';
    else if (c.op === 'comment') h += '<div class="bq-jr"><span class="bq-jr-l">댓글</span></div><blockquote class="bq-jq">' + E(v.body || '') + '</blockquote>';
    else {
      h += '<div class="bq-jr"><span class="bq-jr-l">새 티켓</span><span class="bq-jr-v"><b>' + E(c.project || '') + '</b>' + (c.issueType ? ' · ' + E(c.issueType) : '') + '</span></div>' +
        '<div class="bq-jr"><span class="bq-jr-l">요약</span><span class="bq-jr-v">' + E(c.summary || '') + '</span></div>';
      if (c.description) h += '<blockquote class="bq-jq">' + E(c.description) + '</blockquote>';
    }
    if (v.changed) h += '<span class="bq-jmark">내가 고친 내용으로 반영돼요</span>';
    return h + '</div>';
  }
  function jEditHTML(c) {
    const v = jVals(c), comment = c.op === 'comment';
    return '<div class="bq-jedit"><div class="bq-jedit-h"><b>' + (comment ? '댓글 고치기' : '바꿀 상태 고치기') + '</b><span><kbd>⌘↵</kbd> 적용 · <kbd>esc</kbd> 취소</span></div>' +
      (comment ? '<textarea class="bq-jedit-f" rows="5" maxlength="4000" aria-label="Jira에 남길 댓글" spellcheck="false">' + E(v.body || '') + '</textarea>'
        : '<input class="bq-jedit-f" type="text" value="' + E(v.to || '') + '" aria-label="바꿀 상태" spellcheck="false" autocomplete="off">') +
      (comment ? '' : '<p class="bq-hint">Jira의 상태 이름 그대로 적어 주세요. 반영할 때 이 프로젝트에서 바꿀 수 있는 상태와 맞춰 봐요.</p>') +
      '<div class="bq-actions"><button class="btn sm primary" type="button" data-act="jedit-save">고침 적용<kbd>⌘↵</kbd></button><button class="btn sm" type="button" data-act="jedit-cancel">취소<kbd>esc</kbd></button></div></div>';
  }

  function tidySub(c) {
    const f = c.from || [], head = f[0] ? f[0].label : '';
    const to = c.op === 'exclude' ? '색인에서 빼기' : c.op === 'trash' ? '휴지통' : c.op === 'note' ? (c.reason || '') : c.to ? c.to.label : c.op === 'archive' ? '4-Archive' : '';
    return (TIDY_OP_LABEL[c.op] || '') + ' · ' + (f.length > 1 ? head + ' 외 ' + (f.length - 1) : head) + (to && c.op !== 'note' ? ' → ' + to : '');
  }
  function tidyChips(c) {
    return '<span class="bx-src" data-o="' + (c.origin === 'claude' ? 'claude' : 'rules') + '">' + E(c.originLabel || (c.origin === 'claude' ? 'Claude' : '규칙')) + '</span>' +
      '<span class="bx-conf bq-tcert" data-tc="' + E(c.certainty) + '">' + E(TIDY_CERT[c.certainty] || '') + '</span><span class="bq-topl">' + E(TIDY_OP_LABEL[c.op] || '') + '</span>';
  }
  function tidyPath(c) {
    const from = (c.from || []).map(f => '<span class="bq-from" title="' + E(f.path) + '">' + E(f.label) + (f.isDir ? ' · 파일 ' + E(f.files) + '개' : '') + '</span>').join('');
    const to = c.op === 'exclude' ? '색인에서 빼기 · 파일은 그대로 둬요' : c.op === 'trash' ? 'Synapse 휴지통 (30일 보관)' : c.op === 'note' ? '' : c.to ? c.to.label + (c.to.exists ? '' : ' (새로 만들어요)') : c.op === 'archive' ? '4-Archive' : '목적지를 골라 주세요 (e)';
    return '<div class="bq-path">' + from + (to ? '<span class="bq-dest" title="' + E(c.to ? c.to.path : '') + '"><i>→</i>' + E(to) + '</span>' : '') + '</div>';
  }
  function tidyImpact(c) {
    const im = c.impact || {};
    let s = '';
    if (im.links > 0) s += '<div class="bq-imp">' + ic('follow') + '<span>링크 ' + E(im.links) + '개를 새 위치에 맞춰 고쳐요</span></div>';
    (im.warnings || []).forEach(w => { s += '<div class="bq-imp is-bad">' + ic('alert') + '<span>' + E(w) + '</span></div>'; });
    if (c.op !== 'note' && c.op !== 'trash' && !(im.links > 0)) s += '<div class="bq-imp is-quiet">' + ic('check') + '<span>고칠 링크는 없어요</span></div>';
    if (c.op === 'trash') s += '<div class="bq-imp is-quiet">' + ic('trash') + '<span>Synapse 휴지통에 30일 보관하고 되살릴 수 있어요</span></div>';
    return s ? '<div class="bq-impact">' + s + '</div>' : '';
  }
  function cardHTML(c, i) {
    const on = i === sel;
    const cls = 'bq-card k-' + c.kind + (c.kind === 'delete' ? ' is-del' : '') + (on ? ' is-sel' : '') + (on && busy ? ' is-busy' : '') + (conflictOf(c) ? ' has-conflict' : '');
    let h = '<div class="' + cls + '" role="option" id="bq-c-' + i + '" aria-selected="' + on + '" data-i="' + i + '">';
    const title = isJira(c) ? jTitle(c) : c.kind === 'bundle' && !c.title ? ((c.items || []).length + '개 문서') : c.title;
    h += '<div class="bq-c1"><span class="bq-ico">' + ic(KIND_ICON[c.kind] || 'doc') + '</span><span class="bq-ttl">' + E(title) + '</span>' +
      (on ? '' : (c.confidence ? '<span class="bx-conf" data-c="' + E(c.confidence) + '">' + E(c.confidence) + '</span>' : '')) + '</div>';
    if (!on) {
      let sub = '';
      if (c.kind === 'rules') sub = '규칙 ' + (c.rules || []).length + '개를 확인해 주세요';
      else if (c.kind === 'policy') sub = '점검 결과 ' + (c.violations || []).length + '개';
      else if (c.kind === 'bundle') sub = (c.items || []).length + '개 → ' + (c.to || '');
      else if (c.kind === 'delete') sub = '삭제 제안 · ' + (c.from || '') + ((c.impact && c.impact.inbound > 0) ? ' · 끊길 링크 ' + c.impact.inbound : '');
      else if (isJira(c)) sub = jSub(c) + (jState(c) === 'failed' ? ' · 실패했어요' : jState(c) === 'applying' ? ' · 반영하는 중' : '');
      else if (isTidy(c)) sub = tidySub(c);
      else sub = '→ ' + (c.to || '목적지를 골라 주세요');
      h += '<div class="bq-c2"><span class="bq-sub">' + E(sub) + '</span><span class="bx-src" data-o="' + originCls(c.origin) + '">' + E(c.originLabel || '규칙') + '</span></div></div>';
      return h;
    }
    if (isTidy(c)) {   // v0.9 정리 비서 카드: 무엇을 어디로 · 이유와 근거 · 링크 영향 · 동작
      h += '<div class="bq-chips">' + tidyChips(c) + (c.createdLabel ? '<span class="bq-when">' + E(c.createdLabel) + '</span>' : '') + '</div>';
      h += tidyPath(c);
      const why = [c.reason].concat(c.evidence || []).filter(Boolean).slice(0, 4);
      if (why.length) h += '<ul class="bq-why">' + why.map(x => '<li>' + E(x) + '</li>').join('') + '</ul>';
      h += tidyImpact(c);
      if (c.state === 'failed' && c.error) h += '<div class="bq-jerr" role="alert">' + ic('alert') + '<span>' + E(c.error) + '</span></div>';
      h += editId === c.id ? '' : '<div class="bq-actions">' + actionsHTML(c) + '</div>';
      return h + '</div>';
    }
    if (isJira(c)) {   // v0.8 Jira 카드: 무엇을 어떻게 바꾸는지 · 이유 · 실패 오류 · 동작
      h += '<div class="bq-chips">' + chipsHTML(c) + jStateChip(c) + (c.createdLabel ? '<span class="bq-when">' + E(c.createdLabel) + '</span>' : '') + '</div>';
      h += jBlockHTML(c) + whyHTML(c);
      if (jState(c) === 'failed' && c.error) h += '<div class="bq-jerr" role="alert">' + ic('alert') + '<span>' + E(c.error) + '</span></div>';
      h += jEdit === c.id ? jEditHTML(c) : '<div class="bq-actions">' + actionsHTML(c) + '</div>';
      h += '<p class="bq-hint">Jira에 바로 반영돼요. 팀 모두에게 보이고 되돌릴 수 없어요. 그대로 두면 7일 뒤 사라져요.</p>';
      return h + '</div>';
    }
    h += '<div class="bq-chips">' + chipsHTML(c) + (c.createdLabel ? '<span class="bq-when">' + E(c.createdLabel) + '</span>' : '') + '</div>';
    if (c.kind === 'move' || c.kind === 'delete') h += pathHTML(c);
    else if (c.kind === 'bundle') h += '<div class="bq-path"><span class="bq-dest"><i>→</i>' + E(c.to || '') + '</span></div>' + itemsHTML(c);
    h += whyHTML(c);
    if (c.kind === 'rules') h += rulesHTML(c);
    if (c.kind === 'policy') h += violationsHTML(c);
    h += impactHTML(c);
    if (editId === c.id) h += pickHTML(c);
    else h += '<div class="bq-actions">' + actionsHTML(c) + '</div>';
    if ((c.kind === 'move' || c.kind === 'bundle' || c.kind === 'delete') && editingBlock(c)) h += '<p class="bq-hint">' + E(EDIT_MSG) + '</p>';
    if (conflictOf(c) && c.kind === 'delete') h += '<p class="bq-hint">지금은 지울 수 없어요. 거절(n)하거나 나중에(s) 다시 볼 수 있어요.</p>';
    if (conflictOf(c) && c.kind === 'move') h += '<p class="bq-hint">충돌을 풀기 전에는 승인할 수 없어요. 다른 폴더로 보내거나(e) 나중에(s) 볼 수 있어요.</p>';
    return h + '</div>';
  }

  function renderCards() {
    if (!cardsEl) return;
    const had = root && root.contains(document.activeElement) && document.activeElement.tagName !== 'INPUT';
    const cs = cards();
    let h = '';
    if (loading && !data) h = '<div class="bq-state"><i class="spinner lg"></i><span>정리함을 불러오는 중이에요</span></div>';
    else if (!data) h = '<div class="bq-state is-error"><strong>정리함을 열지 못했어요</strong><span>' + E(loadError || '') + '</span><button class="btn sm" type="button" data-act="retry">다시 시도</button></div>';
    else if (!cs.length) {
      const h0 = data.header || {};
      h = '<div class="bq-state"><strong>' + (data.stopped ? '사서가 멈춰 있어요' : '정리할 문서가 없어요') + '</strong>' +
        '<span>' + (data.stopped ? '다시 시작하면 제자리 확인과 제안을 이어 가요.' : '오늘 제자리 확인 ' + E(h0.inPlace || 0) + (data.lastBatchLabel ? ' · 마지막으로 본 때 ' + E(data.lastBatchLabel) : '')) + '</span>' +
        (loadError ? '<span class="bq-err">새로 고치지 못했어요: ' + E(loadError) + '</span>' : '') + '</div>';
    } else {
      h = cs.map(cardHTML).join('');
      if (data.more > 0) h += '<p class="bq-more">더 있어요 · ' + E(data.more) + '개는 이 카드들을 처리하면 이어서 보여 드려요</p>';
      h += '<p class="bq-keys"><kbd>y</kbd> 승인 <kbd>n</kbd> 거절 <kbd>e</kbd> 목적지 <kbd>s</kbd> 나중에 <kbd>⇧Y</kbd> 묶음 <kbd>j</kbd><kbd>k</kbd> 이동</p>';
    }
    cardsEl.innerHTML = h;
    cardsEl.setAttribute('aria-activedescendant', cs.length ? 'bq-c-' + sel : '');
    if (had) cardsEl.focus({ preventScroll: true });
    if (editId) { const q = cardsEl.querySelector('.bq-pick-q'); if (q) { q.value = pick.q; q.focus({ preventScroll: true }); renderPick(); } }
    if (jEdit) { const f = cardsEl.querySelector('.bq-jedit-f'); if (f && document.activeElement !== f) { f.focus({ preventScroll: true }); try { f.setSelectionRange(f.value.length, f.value.length); } catch (_) { /* 무시 */ } } }
    const s = cardsEl.querySelector('.bq-card.is-sel');
    if (s && s.scrollIntoView) s.scrollIntoView({ block: 'nearest' });
  }
  function renderAll() { renderHead(); renderNote(); renderCards(); renderReader(); renderTrash(); }

  // ---------- 목적지 고르기 (e) ----------
  const normDir = p => { const s = String(p || '').trim().replace(/^\/+/, ''); return s ? s.replace(/\/*$/, '/') : ''; };
  function pickHTML() {
    return '<div class="bq-pick"><div class="bq-pick-h"><b>목적지 고르기</b><span><kbd>↑</kbd><kbd>↓</kbd> 이동 · <kbd>↵</kbd> 선택 · <kbd>esc</kbd> 닫기</span></div>' +
      '<input class="input bq-pick-q" type="text" autocomplete="off" spellcheck="false" placeholder="폴더 검색 (예: 운영)" aria-label="목적지 폴더 검색">' +
      '<div class="bq-pick-list" role="listbox" aria-label="목적지 후보"></div>' +
      '<p class="bq-hint">있는 폴더만 고를 수 있어요. 새 폴더는 만들지 않아요.</p></div>';
  }
  function pickRows(c) {
    const q = pick.q.normalize('NFC').trim().toLowerCase();
    const rows = [], seen = new Set();
    const add = (p, tag) => { const n = normDir(p); if (!n || seen.has(n) || n === normDir(c.to)) return; if (q && !n.toLowerCase().includes(q)) return; seen.add(n); rows.push({ path: n, tag }); };
    (c.alternatives || []).forEach(p => add(p, '후보'));
    cards().forEach(k => { if (k.kind === 'move') { add(k.to, '있는 폴더'); (k.alternatives || []).forEach(p => add(p, '있는 폴더')); } });
    (folderPool || []).forEach(p => add(p, '있는 폴더'));
    const typed = normDir(pick.q);
    if (typed && !seen.has(typed) && typed !== normDir(c.to)) rows.push({ path: typed, tag: '직접 입력', custom: true });
    return rows.slice(0, 12);
  }
  function renderPick() {
    const c = cur(); const list = cardsEl && cardsEl.querySelector('.bq-pick-list');
    if (!c || !list) return;
    pick.rows = pickRows(c);
    pick.idx = Math.max(0, Math.min(pick.idx, pick.rows.length - 1));
    list.innerHTML = pick.rows.length ? pick.rows.map((r, i) => '<button type="button" class="bq-pick-row' + (i === pick.idx ? ' is-on' : '') + '" role="option" aria-selected="' + (i === pick.idx) + '" data-act="pick" data-i="' + i + '">' +
      ic('folder') + '<span class="bq-pick-p">' + E(r.path) + '</span><span class="bq-pick-t">' + E(r.tag) + '</span></button>').join('')
      : '<p class="bq-pick-none">다른 후보가 없어요. 폴더 이름을 쳐서 찾아 보세요.</p>';
    const on = list.querySelector('.is-on'); if (on && on.scrollIntoView) on.scrollIntoView({ block: 'nearest' });
    const box = list.closest('.bq-pick'); if (box && box.scrollIntoView) box.scrollIntoView({ block: 'nearest' });
  }
  async function openPick() {
    const c = cur(); if (!c || busy) return;
    if (isJira(c)) return openJiraEdit(c);
    if (isTidy(c)) return pickTidy(c);
    if (c.kind === 'bundle') return api.toast('묶음은 목적지를 바꿀 수 없어요. 거절하면 낱개로 다시 나와요.');
    if (c.kind !== 'move') return api.toast(c.kind === 'delete' ? '삭제 제안은 목적지가 없어요 · 승인하면 Synapse 휴지통으로 가요' : '이 카드는 목적지가 없어요');
    editId = c.id; confirmId = null; pick = { q: '', idx: 0, rows: [] };
    renderCards();
    if (!folderPoolTried) {
      folderPoolTried = true;
      try { const r = await api.call('folders', {}); const a = Array.isArray(r) ? r : (r && r.folders); if (Array.isArray(a)) { folderPool = a.map(x => typeof x === 'string' ? x : (x && x.path) || '').filter(Boolean); if (editId) renderPick(); } } catch (_) { /* 폴더 목록 API가 없으면 후보와 직접 입력만 쓴다 */ }
    }
  }
  // v0.9 tidy 카드의 자리 바꾸기(e): 정리 계획의 destinations 중에서 글자로 거르며 고른다 → decide(id, "edit", 절대 경로)
  async function pickTidy(c) {
    if (c.op === 'exclude' || c.op === 'trash' || c.op === 'note') return api.toast('이 제안은 옮길 곳이 없어요');
    const M = window.SynapseMenu;
    if (!M || typeof M.pick !== 'function') return api.toast('폴더 고르기 창을 열지 못했어요', 'error');
    const r = await call('tidyPlan', {});
    if (!root) return;
    const dests = (r && r.destinations) || [];
    const items = dests.filter(d => d.path && (!c.to || d.path !== c.to.path) && !(c.from || []).some(f => d.path === f.path || d.path.indexOf(f.path + '/') === 0))
      .map(d => ({ value: d.path, label: d.label || d.path, hint: d.zone ? '' : '코드 폴더' }));
    const path = await M.pick({ title: '‘' + cut(c.title, 28) + '’ 어디로 옮길까요?', placeholder: '폴더 이름으로 찾기', items, emptyText: '맞는 폴더가 없어요' });
    if (!root) return;
    focus();
    if (path) decide(c, 'edit', path);
  }
  function closePick() { editId = null; renderCards(); focus(); if (deferred) { deferred = false; refresh(); } }
  function onInput(e) {
    if (e.target.classList && e.target.classList.contains('bq-pick-q')) { pick.q = e.target.value; pick.idx = 0; renderPick(); }
  }
  function onOwnKey(e) {
    if (e.target.classList && e.target.classList.contains('bq-jedit-f')) {   // v0.8 Jira 고치기: ⌘↵ 적용 · esc 취소 (입력칸의 Enter는 적용, 글 상자의 Enter는 줄바꿈)
      if (e.isComposing || e.keyCode === 229) return;
      const k = e.key;
      if (k === 'Escape') { e.preventDefault(); e.stopPropagation(); closeJiraEdit(); }
      else if (k === 'Enter' && (e.metaKey || e.ctrlKey || e.target.tagName === 'INPUT')) { e.preventDefault(); e.stopPropagation(); saveJiraEdit(); }
      else e.stopPropagation();
      return;
    }
    if (!e.target.classList || !e.target.classList.contains('bq-pick-q')) return;
    if (e.isComposing || e.keyCode === 229) return;
    const k = e.key;
    if (k === 'ArrowDown' || k === 'ArrowUp') { e.preventDefault(); e.stopPropagation(); pick.idx = Math.max(0, Math.min(pick.rows.length - 1, pick.idx + (k === 'ArrowDown' ? 1 : -1))); renderPick(); }
    else if (k === 'Enter') { e.preventDefault(); e.stopPropagation(); const r = pick.rows[pick.idx]; if (r) choosePick(r.path); }
    else if (k === 'Escape') { e.preventDefault(); e.stopPropagation(); closePick(); }
    else e.stopPropagation(); // 글자는 입력창이 받는다 (U1의 단축키로 새지 않게)
  }
  function choosePick(path) { const c = cur(); if (!c) return; editId = null; decide(c, 'edit', path); }

  // ---------- 리더 칸: 미리보기 ----------
  function changeHTML(x) {
    if (typeof x === 'string') return '<li>' + E(x) + '</li>';
    if (!x) return '';
    const p = x.path || x.file || '', b = x.before || x.from || '', a = x.after || x.to || '';
    return '<li><span class="bq-ch-f">' + E(p) + '</span>' + (b || a ? '<code>' + E(b) + '</code><i>→</i><code>' + E(a) + '</code>' : '') + '</li>';
  }
  function renderReader() {
    if (!readerEl) return;
    const c = cur();
    prevSeq++;
    if (!c) { readerEl.innerHTML = '<div class="bq-prev"><div class="bq-prev-empty">' + ic('folder') + '<span>카드를 고르면 문서 미리보기와<br>바뀔 링크가 여기에 보여요</span></div></div>'; return; }
    if (isTidy(c)) {   // v0.9: 옮기기 전·후 · 근거 · 영향
      const f = (c.from || []).map(x => '<li><span class="bq-ch-f">' + E(x.label) + '</span><code>' + E(x.path) + '</code></li>').join('');
      let th = '<div class="bq-prev"><div class="bq-prev-h"><h3>' + E(c.title) + '</h3></div>' + tidyPath(c) +
        '<h4 class="bq-prev-s">대상 ' + E((c.from || []).length) + '개</h4><ul class="bq-changes">' + f + '</ul>';
      if (c.reason || (c.evidence || []).length) th += '<h4 class="bq-prev-s">이유</h4><p class="bq-prev-p">' + [c.reason].concat(c.evidence || []).filter(Boolean).map(E).join('<br>') + '</p>';
      th += '<h4 class="bq-prev-s">영향</h4>' + tidyImpact(c);
      th += '<p class="bq-prev-p is-quiet">' + (c.op === 'note' ? 'Synapse는 이 파일을 열지도 옮기지도 않아요.' : '승인한 뒤에도 되돌리기(⌥⌘Z)로 원래대로 돌릴 수 있어요.') + (c.signatureLabel ? ' 같은 종류 · ' + E(c.signatureLabel) : '') + '</p>';
      readerEl.innerHTML = th + '</div>';
      return;
    }
    if (isJira(c)) {   // v0.8: Jira에 보낼 내용 · 이유 · 티켓 내용
      const why = reasonsOf(c);
      let jh = '<div class="bq-prev"><div class="bq-prev-h"><h3>' + E(jTitle(c)) + '</h3>' +
        (c.docId ? '<button type="button" class="btn sm" data-act="open-doc" data-doc="' + E(c.docId) + '">' + ic('doc') + '<span>티켓 보기</span></button>' : '') + '</div>' +
        '<h4 class="bq-prev-s">Jira에 보낼 내용</h4>' + jBlockHTML(c);
      if (why.length) jh += '<h4 class="bq-prev-s">이유</h4><p class="bq-prev-p">' + why.map(E).join('<br>') + '</p>';
      jh += '<p class="bq-prev-p is-quiet">승인(y)하면 연결된 Atlassian 계정으로 Jira에 바로 반영돼요. 팀 모두에게 보이고 되돌릴 수 없어요. 처리하지 않으면 7일 뒤 사라져요.</p>';
      const jbody = !!c.docId && c.op !== 'create';
      if (jbody) jh += '<h4 class="bq-prev-s">티켓 내용 미리보기</h4><div class="bq-prev-body" data-r="body"><i class="spinner"></i></div>';
      readerEl.innerHTML = jh + '</div>';
      if (jbody) loadBody(c.docId, prevSeq);
      return;
    }
    const im = c.impact || {};
    let h = '<div class="bq-prev"><div class="bq-prev-h"><h3>' + E(c.title) + '</h3>' +
      (c.docId ? '<button type="button" class="btn sm" data-act="open-orig" data-doc="' + E(c.docId) + '">' + ic('external') + '<span>원본 열기</span><kbd>⌘↵</kbd></button>' : '') + '</div>';
    if (c.kind === 'move' || c.kind === 'delete') h += pathHTML(c);
    if (c.kind === 'delete') {
      h += '<h4 class="bq-prev-s">지우면</h4><p class="bq-prev-p">' + (im.inbound > 0 ? '이 문서를 가리키는 링크 <b>' + E(im.inbound) + '개</b>가 끊겨요. 되살리면 다시 이어져요.' : '이 문서를 가리키는 링크는 없어요.') + '</p>' +
        '<p class="bq-prev-p is-quiet">파일은 Synapse 휴지통에 30일 보관한 뒤 macOS 휴지통으로 넘어가요. 정리함 아래 휴지통이나 AI 기록(⌘Y)에서 되돌릴 수 있어요.</p>';
      if (im.conflict) h += '<p class="bq-prev-p is-bad">' + E(im.conflict) + '</p>';
    }
    if (c.kind === 'move' || c.kind === 'bundle') {
      h += '<h4 class="bq-prev-s">바뀔 링크</h4>';
      const ch = im.changes || [];
      if (ch.length) h += '<ul class="bq-changes">' + ch.map(changeHTML).join('') + '</ul>';
      else if (im.links > 0) h += '<p class="bq-prev-p">링크 ' + E(im.links) + '개를 고쳐요 (파일 ' + E(im.files || 0) + '개' + (im.canvas > 0 ? ' · 캔버스 ' + E(im.canvas) + '개' : '') + '). 옮기면서 새 경로로 바꾸고, 고치기 전 원본은 백업해 둬요. 되돌리면 원래대로 돌아와요.</p>';
      else h += '<p class="bq-prev-p">고칠 링크가 없어요. 옮기기만 해요.</p>';
      if (im.conflict) h += '<p class="bq-prev-p is-bad">' + E(im.conflict) + '</p>';
      if (im.sync) h += '<p class="bq-prev-p is-quiet">옵시디언 Sync로 다른 기기에도 반영돼요.</p>';
    }
    if (c.kind === 'bundle') h += '<h4 class="bq-prev-s">옮길 문서 ' + E((c.items || []).length) + '개</h4>' + '<ul class="bq-changes">' + (c.items || []).map(x => '<li><span class="bq-ch-f">' + E(x.title) + '</span><code>' + E(x.from) + '</code></li>').join('') + '</ul>';
    if (c.kind === 'rules') h += '<h4 class="bq-prev-s">규칙표</h4>' + rulesHTML(c) + '<p class="bq-prev-p is-quiet">승인하기 전에는 이동 제안을 만들지 않아요. 파일은 건드리지 않아요.</p>';
    if (c.kind === 'policy') h += '<h4 class="bq-prev-s">점검 결과</h4>' + violationsHTML(c) + '<p class="bq-prev-p is-quiet">사서는 파일을 고치지 않아요. Claude에게 맡기면 바뀔 내용을 먼저 보여 줘요.</p>';
    const body = c.docId && (c.kind === 'move' || c.kind === 'delete');
    if (body) h += '<h4 class="bq-prev-s">내용 미리보기</h4><div class="bq-prev-body" data-r="body"><i class="spinner"></i></div>';
    readerEl.innerHTML = h + '</div>';
    if (body) loadBody(c.docId, prevSeq);
  }
  async function loadBody(id, my) {
    let text = docCache.get(id), err = '';
    if (text == null) {
      try { const r = await api.call('document', { id }); text = (r && r.text) || ''; docCache.set(id, text); if (docCache.size > 30) docCache.delete(docCache.keys().next().value); }
      catch (e) { text = null; err = '내용을 불러오지 못했어요'; }
    }
    if (my !== prevSeq || !readerEl) return;
    const el = readerEl.querySelector('[data-r="body"]'); if (!el) return;
    if (text == null) el.innerHTML = '<span class="bq-prev-p is-quiet">' + E(err) + '</span>';
    else { const t = text.replace(/\r\n?/g, '\n').trim(); el.textContent = t.length > 1600 ? t.slice(0, 1600) + '\n…' : (t || '(빈 문서예요)'); }
  }

  // ---------- 결정 ----------
  function setBusy(v) { busy = v; if (root) root.classList.toggle('is-busy', v); }
  async function call(method, params) {
    try { return await api.call(method, params || {}); } catch (e) { return { ok: false, error: (e && e.message) || '처리하지 못했어요' }; }
  }
  // 편집기에서 편집 중인 문서(또는 묶음에 든 문서)는 승인하지 않는다
  function editingBlock(c) {
    let id = null;
    try { id = typeof api.editingDocId === 'function' ? api.editingDocId() : null; } catch (_) { id = null; }
    return !!id && !!c && (c.docId === id || (c.items || []).some(x => x.docId === id));
  }
  const EDIT_MSG = '편집 중인 문서예요. 저장한 뒤 승인해 주세요';
  async function decide(c, action, to) {
    if (busy) return;
    if ((action === 'approve' || action === 'edit') && editingBlock(c)) return api.toast(EDIT_MSG, 'error');
    setBusy(true); renderCards();
    let res = await call('decide', to ? { id: c.id, action, to } : { id: c.id, action });
    if (c.kind === 'bundle' && (!res || res.ok === false) && (action === 'reject' || action === 'later') && (c.items || []).length) {
      for (const it of c.items) res = await call('decide', { id: it.id, action }); // 묶음 id를 못 받으면 낱개로 같은 결정을 한다
    }
    await finish(c, action, res, to);
  }
  async function decideBundle(c) {
    if (busy) return;
    if (editingBlock(c)) { confirmId = null; renderCards(); return api.toast(EDIT_MSG, 'error'); }
    confirmId = null; setBusy(true); renderCards();
    await finish(c, 'approve', await call('decideBundle', { id: c.id }));
  }
  // 결정 뒤 새 목록을 받을 때까지 busy를 풀지 않는다 (옛 카드에 키가 먹지 않게)
  async function finish(c, action, res, to) {
    if (!root) { busy = false; return; }
    if (!res || res.ok === false) {
      api.toast((res && res.error) || '처리하지 못했어요', 'error');
    } else {
      report(c, action, res, to);
      await refreshNow();
    }
    if (!root) { busy = false; return; }
    setBusy(false); renderCards(); renderReader();
    if (deferred) { deferred = false; refresh(); }
    focus();
  }
  async function refreshNow() { deferred = false; editId = null; confirmId = null; await load(); }
  function report(c, action, res, to) {
    const ap = res.applied;
    if (action === 'reject') return api.toast(c.kind === 'policy' ? '닫았어요' : c.kind === 'jira' ? '거절했어요 · Jira에는 아무것도 보내지 않았어요' : '거절했어요 · 같은 제안은 30일 동안 다시 안 보여 드려요');
    if (action === 'later') return api.toast('나중에 볼게요');
    if (action === 'dismiss') return api.toast('닫았어요');
    if (c.kind === 'rules') return api.toast('규칙표를 승인했어요 · 이제 이동 제안을 만들어요');
    if (isTidy(c)) {   // v0.9: {ok, applied:{batchId, done, skipped}, undoable, prompt}
      if (ap && ap.done > 0) {
        const verb = TIDY_DONE[c.op] || '정리했어요';
        api.toast(verb + (res.undoable ? ' · 되돌리기 ⌥⌘Z' : ''), undefined, 10000);
        note = { text: '‘' + cut(c.title, 40) + '’ ' + verb + (to && c.to ? ' → ' + to : ''), undo: res.undoable && ap.batchId ? ap.batchId : null, skipped: ap.skipped || [] };
        if (res.prompt) api.toast('같은 정리를 ' + (res.prompt.approvals || 3) + '번 승인했어요 · 작업 지도의 정리 계획(⌘2 › p)에서 자동으로 할지 정해 주세요', undefined, 8000);
      } else if (ap && ap.skipped && ap.skipped.length) {
        api.toast('정리하지 못했어요 · 이유는 위에 있어요', 'error');
        note = { tone: 'error', text: '정리하지 못한 것이 있어요', undo: null, skipped: ap.skipped };
      } else api.toast('처리했어요');
      return;
    }
    if (ap && ap.trashed > 0) {
      api.toast('휴지통으로 보냈어요 · 30일 보관' + (res.undoable ? ' · 되돌리기 ⌥⌘Z' : ''), undefined, 10000);
      note = { text: '‘' + c.title + '’ 휴지통으로 보냈어요 · 30일 보관' + (ap.inbound > 0 ? ' · 끊긴 링크 ' + ap.inbound + '개' : ''), undo: res.undoable ? ap.batchId : null, skipped: [] };
      return;
    }
    if (ap && ap.moved > 0) {
      const links = c.kind === 'move' ? ((c.impact && c.impact.links) != null ? c.impact.links : ap.rewrote) || 0 : 0;
      const what = c.kind === 'bundle' ? ap.moved + '개 옮겼어요' : '옮겼어요';
      const tail = (links > 0 ? ' · 링크 ' + links + '개 고침' : '') + (res.undoable ? ' · 되돌리기 ⌥⌘Z' : '');
      api.toast(what + tail, undefined, 10000);
      const dest = to || c.to || '';
      note = (res.undoable && ap.batchId) || (ap.skipped && ap.skipped.length)
        ? { text: (c.kind === 'bundle' ? ap.moved + '개를 옮겼어요' : '‘' + c.title + '’ 옮겼어요') + (dest ? ' → ' + dest : '') + (links > 0 ? ' · 링크 ' + links + '개 고침' : ''), undo: res.undoable ? ap.batchId : null, skipped: ap.skipped || [] }
        : null;
    } else if (ap && ap.skipped && ap.skipped.length) {
      api.toast('옮기지 못했어요 · 이유는 위에 있어요', 'error');
      note = { tone: 'error', text: '옮기지 못한 문서가 있어요', undo: null, skipped: ap.skipped };
    } else api.toast('처리했어요');
  }

  // v0.8: Jira는 팀이 같이 보는 곳이고 되돌릴 수 없다 → 보낼 내용을 보여 주고 확인을 받은 뒤 jiraApply. 고친 값만 body·to로 보낸다.
  async function jiraApprove(c) {
    if (busy) return;
    const st = jState(c);
    if (st === 'applying') return api.toast('반영하는 중이에요 · 잠시만 기다려 주세요');
    const M = window.SynapseMenu;
    if (!M || typeof M.confirm !== 'function') return api.toast('확인 창을 열지 못했어요', 'error');
    const v = jVals(c), lines = [];
    if (c.op === 'transition') lines.push(c.key + (c.title ? ' · ' + cut(c.title, 60) : ''), '상태를 ‘' + (c.status || '지금 상태') + '’에서 ‘' + (v.to || '') + '’(으)로 바꿔요');
    else if (c.op === 'comment') lines.push(c.key + (c.title ? ' · ' + cut(c.title, 60) : '') + ' 티켓에 댓글을 남겨요', '“' + cut(v.body, 220) + '”');
    else lines.push((c.project || '') + ' 프로젝트에 새 티켓을 만들어요', '요약: ' + cut(c.summary, 120));
    lines.push({ text: 'Jira에 바로 반영돼요. 팀 모두에게 보이고 되돌릴 수 없어요.', warn: true });
    const ok = await M.confirm({ title: st === 'failed' ? 'Jira에 다시 반영할까요?' : 'Jira에 반영할까요?', lines, confirmLabel: 'Jira에 반영', danger: true });
    if (!root) return;
    if (!ok) { focus(); return; }
    const body = { id: c.id };
    if (c.op === 'comment' && v.body != null && v.body !== c.body) body.body = v.body;
    if (c.op === 'transition' && v.to != null && v.to !== c.to) body.to = v.to;
    jApplyId = c.id; setBusy(true); confirmId = null; renderCards();
    const res = await call('jiraApply', body);
    jApplyId = null;
    if (!root) { busy = false; return; }
    if (!res || res.ok === false) api.toast(((res && res.error) || 'Jira에 반영하지 못했어요') + ' · 카드에서 다시 시도할 수 있어요', 'error', 6000);   // 오류는 카드에도 남는다(failed)
    else {
      jEdits.delete(c.id);
      api.toast(res.message || 'Jira에 반영했어요', undefined, 5000);
      note = { text: res.message || 'Jira에 반영했어요', undo: null, skipped: [], url: res.url || '' };
    }
    await refreshNow();
    if (!root) { busy = false; return; }
    setBusy(false); renderCards(); renderReader();
    if (deferred) { deferred = false; refresh(); }
    focus();
  }
  function openJiraEdit(c) {
    if (c.op === 'create') return api.toast('새 티켓은 여기서 고칠 수 없어요 · 거절하고 Claude에게 다시 시켜 주세요');
    if (jApplying(c)) return api.toast('반영하는 중이라 고칠 수 없어요');
    jEdit = c.id; confirmId = null; editId = null;
    renderCards();
  }
  function saveJiraEdit() {
    const c = cur(), f = cardsEl && cardsEl.querySelector('.bq-jedit-f');
    if (!c || !f || jEdit !== c.id) { jEdit = null; renderCards(); return; }
    const val = f.value.trim();
    if (!val) { api.toast(c.op === 'comment' ? '댓글 글을 비울 수 없어요' : '바꿀 상태를 적어 주세요', 'error'); return; }
    const ed = Object.assign({}, jEdits.get(c.id));
    if (c.op === 'comment') ed.body = val; else ed.to = val;
    jEdits.set(c.id, ed);
    closeJiraEdit();
    api.toast('고쳤어요 · y를 눌러 반영할 때 이 내용으로 보내요');
  }
  function closeJiraEdit() { jEdit = null; renderCards(); renderReader(); focus(); if (deferred) { deferred = false; refresh(); } }

  async function doApprove(viaShift) {
    const c = cur(); if (!c || busy) return;
    if (isJira(c)) return jiraApprove(c);
    if (isTidy(c)) {
      if (data && data.stopped) return api.toast('사서가 멈춰 있어서 옮길 수 없어요. 비상 정지를 풀어 주세요.', 'error');
      return decide(c, c.op === 'note' ? 'dismiss' : 'approve');
    }
    if (c.kind === 'rules') return decide(c, 'approve');
    if (c.kind === 'policy') return copyInstruction('violations', null, 'Claude 지시문을 복사했어요 · Claude에 붙여 넣어 주세요');
    if (data && data.stopped && (c.kind === 'move' || c.kind === 'bundle' || c.kind === 'delete')) return api.toast('사서가 멈춰 있어서 옮길 수 없어요. 비상 정지를 풀어 주세요.', 'error');
    if ((c.kind === 'move' || c.kind === 'bundle' || c.kind === 'delete') && editingBlock(c)) return api.toast(EDIT_MSG, 'error');
    if (c.kind === 'delete') return conflictOf(c) ? api.toast('지금은 지울 수 없어요 · ' + conflictOf(c), 'error') : decide(c, 'approve');
    if (c.kind === 'bundle') {
      if (confirmId === c.id) return viaShift ? decideBundle(c) : api.toast('확정하려면 ↵ 또는 ⇧Y를 눌러 주세요');
      if (conflictOf(c) || hasLinkImpact(c)) return api.toast('링크 영향이 있는 묶음은 한 번에 승인할 수 없어요. 낱개로 확인해 주세요.');
      confirmId = c.id; renderCards(); return;
    }
    if (conflictOf(c)) return api.toast('충돌이 있어서 승인할 수 없어요 · ' + conflictOf(c), 'error');
    if (!c.to) return api.toast('목적지를 먼저 골라 주세요 (e)');
    decide(c, 'approve');
  }
  function doReject() {
    const c = cur(); if (!c || busy) return;
    if (c.kind === 'rules' && c.origin === 'rules') return api.toast('규칙표는 거절하지 않고 나중에(s)로 미룰 수 있어요');
    decide(c, c.kind === 'policy' || (isTidy(c) && c.op === 'note') ? 'dismiss' : 'reject');
  }
  async function copyInstruction(context, id, okMsg) {
    const r = await call('claudeInstruction', id ? { context, id } : { context });
    if (r && r.ok && r.text) api.copyText(r.text, okMsg || 'Claude 지시문을 복사했어요');
    else api.toast((r && r.error) || '지시문을 만들지 못했어요', 'error');
  }
  async function runBatch() {
    if (runningBatch) return;
    runningBatch = true; renderHead();
    const r = await call('runBatch', {});
    runningBatch = false;
    if (!root) return;
    if (r && r.ok === false) api.toast(r.error || '다시 보지 못했어요', 'error');
    else api.toast(r && r.created > 0 ? '새 제안 ' + r.created + '개를 만들었어요' : '새로 정리할 문서는 없어요');
    deferred = false; editId = null; confirmId = null;
    await refresh();
  }
  async function undoLast() {
    if (!note || !note.undo || busy) return;
    const id = note.undo; note = null; renderNote();
    setBusy(true);
    const r = await call('undo', { batchId: id });
    if (!root) { busy = false; return; }
    if (!r || r.ok === false) api.toast((r && r.error) || '되돌리지 못했어요', 'error');
    else if (r.conflicts && r.conflicts.length) {
      api.toast('일부만 되돌렸어요 · 충돌 ' + r.conflicts.length + '개는 그대로 뒀어요', 'error');
      note = { tone: 'error', text: '되돌리지 못한 파일이 있어요. 덮어쓰지 않았어요.', undo: null, skipped: r.conflicts.map(k => ({ title: k.path, reason: k.reason })) };
    } else api.toast('되돌렸어요 · 파일 ' + ((r.restored != null ? r.restored : r.undone) || 0) + '개');
    await refreshNow();
    if (!root) { busy = false; return; }
    setBusy(false); renderCards(); renderReader();
  }

  // ---------- 휴지통 구역 (v0.6) ----------
  // 정리함 아래 "휴지통 N · 30일 보관": 접어 두고, 펼치면 목록 · 되살리기 · 지금 macOS 휴지통으로(한 번 더 확인)
  function renderTrash() {
    if (!trashEl) return;
    if (!trash) { trashEl.hidden = true; trashEl.innerHTML = ''; return; }
    const items = trash.items || [], n = items.length, days = trash.retentionDays || 30;
    trashEl.hidden = false;
    let h = '<button type="button" class="bq-trash-h" data-act="trash-toggle" aria-expanded="' + trashOpen + '">' + ic('trash') +
      '<span class="bq-trash-t">휴지통 <b class="num">' + E(n) + '</b> · ' + E(days) + '일 보관</span>' +
      '<span class="bq-trash-c">' + (trashOpen ? '접기' : n ? '펼치기' : '') + '</span></button>';
    if (trashOpen) {
      if (!n) h += '<p class="bq-trash-empty">비어 있어요. 지운 문서는 여기에 ' + E(days) + '일 동안 남아요.</p>';
      else {
        h += '<ul class="bq-trash-list">' + items.map(t => {
          const busy = trashBusy === t.id, ask = trashAsk === t.id;
          let li = '<li class="bq-trash-i' + (busy ? ' is-busy' : '') + '"><div class="bq-trash-m"><span class="bq-trash-n" title="' + E(t.path) + '">' + E(t.title) + '</span>' +
            '<span class="bq-trash-p">' + E(t.path) + '</span>' +
            '<span class="bq-trash-s">' + E(t.deletedLabel || '') + ' · ' + E(t.originLabel || '') + (t.via === 'direct' ? ' 바로 실행' : t.via === 'approved' ? ' 제안 승인' : '') +
            ' · ' + (t.daysLeft > 0 ? E(t.daysLeft) + '일 뒤 macOS 휴지통으로' : '곧 macOS 휴지통으로') + (t.reason ? ' · ' + E(t.reason) : '') + '</span></div>';
          if (ask) li += '<div class="bq-trash-ask"><span>macOS 휴지통으로 옮길까요? 그 뒤에는 Synapse에서 되살릴 수 없어요.</span>' +
            '<button class="btn sm" type="button" data-act="trash-purge-no">취소</button><button class="btn sm danger" type="button" data-act="trash-purge-yes" data-tid="' + E(t.id) + '">옮기기</button></div>';
          else li += '<div class="bq-trash-b"><button class="btn sm" type="button" data-act="trash-restore" data-tid="' + E(t.id) + '"' + (trashBusy ? ' disabled' : '') + '>' + ic('undo') + '<span>되살리기</span></button>' +
            '<button class="btn sm ghost" type="button" data-act="trash-purge" data-tid="' + E(t.id) + '"' + (trashBusy ? ' disabled' : '') + ' title="macOS 휴지통으로 지금 옮겨요">지금 macOS 휴지통으로</button></div>';
          return li + '</li>';
        }).join('') + '</ul>';
      }
    }
    keepFocus(trashEl, () => { trashEl.innerHTML = h; });
  }
  async function trashRestore(id) {
    if (!id || trashBusy) return;
    trashBusy = id; renderTrash();
    const r = await call('restoreTrash', { ids: [id] });
    trashBusy = '';
    if (!root) return;
    if (!r || r.ok === false) api.toast((r && r.error) || '되살리지 못했어요', 'error');
    else if (r.failed && r.failed.length) api.toast('되살리지 못했어요 · ' + (r.failed[0].reason || ''), 'error');
    else { const x = (r.restored || [])[0] || {}; api.toast(x.renamed ? '되살렸어요 · 같은 이름이 있어 ‘' + x.path + '’로 두었어요' : '되살렸어요 · ' + (x.path || '원래 자리')); }
    await load();
  }
  async function trashPurge(id) {
    if (!id || trashBusy) return;
    trashAsk = null; trashBusy = id; renderTrash();
    const r = await call('purgeTrash', { ids: [id] });
    trashBusy = '';
    if (!root) return;
    if (!r || r.ok === false || (r.failed && r.failed.length)) api.toast((r && (r.error || (r.failed && r.failed[0] && r.failed[0].reason))) || '옮기지 못했어요', 'error');
    else api.toast('macOS 휴지통으로 옮겼어요');
    await load();
  }

  // ---------- 선택·클릭·키 ----------
  function select(i) {
    const n = cards().length; if (!n) return;
    i = Math.max(0, Math.min(n - 1, i));
    if (i === sel) return;
    sel = i; confirmId = null; editId = null; jEdit = null;
    renderCards(); renderReader();
  }
  function onClick(e) {
    const b = e.target.closest('[data-act]');
    if (b && root.contains(b)) {
      const act = b.dataset.act;
      if (b.disabled) return;
      const card = b.closest('.bq-card');
      if (card && +card.dataset.i !== sel) select(+card.dataset.i);
      switch (act) {
        case 'approve': return doApprove();
        case 'later': { const c = cur(); return c && decide(c, 'later'); }
        case 'reject': return doReject();
        case 'edit': return openPick();
        case 'pick': { const r = pick.rows[+b.dataset.i]; return r && choosePick(r.path); }
        case 'confirm-bundle': { const c = cur(); return c && decideBundle(c); }
        case 'cancel-confirm': confirmId = null; renderCards(); return focus();
        case 'claude':   // v0.8: Claude를 쓸 수 있으면 시키기 패널(정리 안 된 문서 자리 찾기)을, 아니면 예전처럼 지시문 복사
          if (aiReady() && typeof api.openAI === 'function') return api.openAI({ preset: 'organize' });
          return copyInstruction('queue', null, 'Claude 지시문을 복사했어요 · Claude에 붙여 넣어 주세요');
        case 'jedit-save': return saveJiraEdit();
        case 'jedit-cancel': return closeJiraEdit();
        case 'open-url': return api.call('openURL', { url: b.dataset.url }).then(r => { if (r && r.ok === false) api.toast(r.error || '주소를 열지 못했어요', 'error'); });
        case 'batch': return runBatch();
        case 'undo': return undoLast();
        case 'note-x': note = null; return renderNote();
        case 'retry': return refresh();
        case 'open-doc': return api.openDoc(b.dataset.doc);
        case 'open-orig': return api.openOriginal(b.dataset.doc);
        case 'trash-toggle': trashOpen = !trashOpen; trashAsk = null; return renderTrash();
        case 'trash-restore': return trashRestore(b.dataset.tid);
        case 'trash-purge': trashAsk = b.dataset.tid; return renderTrash();
        case 'trash-purge-yes': return trashPurge(b.dataset.tid);
        case 'trash-purge-no': trashAsk = null; return renderTrash();
      }
      return;
    }
    const card = e.target.closest('.bq-card');
    if (card) { select(+card.dataset.i); focus(); }
  }
  function onKey(e) {
    if (!root || !api || e.isComposing || e.keyCode === 229) return false;
    const a = document.activeElement, k = e.key;
    const typing = !!a && (a.tagName === 'INPUT' || a.tagName === 'TEXTAREA' || a.tagName === 'SELECT' || a.isContentEditable);
    // ⌥⌘Z: 정리함 알림에 되돌릴 배치가 있으면 그 배치를 되돌린다 (없으면 U1의 기본 동작)
    if (e.metaKey && e.altKey && !e.ctrlKey && !e.shiftKey && (e.code === 'KeyZ' || String(k).toLowerCase() === 'z')) {
      if (!(note && note.undo)) return false;
      e.preventDefault(); if (!e.repeat) undoLast(); return true;
    }
    if (typing && root.contains(a)) return false; // 목적지 검색 입력은 onOwnKey가 받는다
    if (k === 'Escape') {
      if (confirmId) { confirmId = null; renderCards(); return true; }
      if (editId) { closePick(); return true; }
      return false;
    }
    const c = cur();
    if (k === 'Enter' && (e.metaKey || e.ctrlKey) && !e.altKey && c && c.docId) { e.preventDefault(); if (!e.repeat) api.openOriginal(c.docId); return true; }
    if (e.metaKey || e.ctrlKey || e.altKey) return false;
    const arrowOk = !typing || a.value === '';
    if (k === 'ArrowDown' || k === 'ArrowUp') { if (!arrowOk) return false; e.preventDefault(); select(sel + (k === 'ArrowDown' ? 1 : -1)); return true; }
    if (typing) return false;
    if (a && a !== document.body && !(listEl && listEl.contains(a))) return false; // 카드 목록에 포커스가 있을 때만 글자 키
    if (k === 'Enter') { if (confirmId && !(a && a.tagName === 'BUTTON')) { e.preventDefault(); if (c && !e.repeat && !busy) decideBundle(c); return true; } return false; }
    const ch = /^[a-zA-Z]$/.test(k) ? k.toLowerCase() : (/^Key[A-Z]$/.test(e.code || '') ? e.code.slice(3).toLowerCase() : '');
    if (!ch || 'jknyes'.indexOf(ch) < 0) return false;
    e.preventDefault();
    if (busy) return true;
    if (e.repeat && 'ynse'.indexOf(ch) >= 0) return true; // 키를 계속 눌러도 결정은 한 번만 (j·k 이동만 반복)
    if (ch === 'j') select(sel + 1);
    else if (ch === 'k') select(sel - 1);
    else if (!c) return true;
    else if (ch === 'y') {
      if (e.shiftKey) { if (c.kind === 'bundle') doApprove(true); else api.toast('⇧Y는 묶음 카드에서만 써요'); }
      else doApprove(false);
    }
    else if (ch === 'n') doReject();
    else if (ch === 's') { if (isJira(c)) api.toast('Jira 제안은 거절하거나 그대로 두세요 · 그대로 두면 7일 뒤 사라져요'); else decide(c, 'later'); }
    else if (ch === 'e') openPick();
    return true;
  }

  window.SynapseQueue = Object.freeze({ init, mount, refresh, onKey, focus, unmount });
})();
