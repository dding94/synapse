// tickets.js — Synapse v0.7 티켓 화면(⌘5). window.SynapseTickets 하나만 만든다.
// U2 모듈 계약(week.js·queue.js와 같다): init(api) · mount(listEl, readerEl) · refresh() · onKey(e) → bool · unmount()
// 열린 Jira 티켓(막힘·진행 중·할 일)을 프로젝트별로 보여 준다. 상태 칩으로 거르고 "내 담당만"으로 좁힌다.
// 데이터: api.call('tickets') — {hasJira, projects:[{key, counts, items}], totals}. 거르기는 이 파일에서 한다(한 번 받아 둔 항목으로).
// v0.8 (docs/V08.md §8.3): 맨 위 Claude 브리핑 카드(지금 볼 것·정리 제안), 정리 제안의 "반영하기…" 확인 창(Jira는 되돌릴 수 없다),
//   거르기 막대의 "주제별" 묶기, 티켓 줄 아래 한 줄 설명. 정리는 window.SynapseAI(ai.js)의 aiDigest("tickets").
//   Jira에 쓰는 길은 이 확인 창 하나뿐이다: jiraPropose → jiraApply (정리함에 올리기는 jiraPropose만).
(function () {
  'use strict';

  const GROUPS = ['blocked', 'doing', 'todo'];
  const LABEL = { blocked: '막힘', doing: '진행 중', todo: '할 일' };
  const STORE_KEY = 'synapse.tickets.v1';
  const DEFAULT_GROUPS = ['blocked', 'doing'];

  let api = null, listEl = null, root = null, scrollEl = null;
  let data = null, loadError = null, loading = false, seq = 0;
  let sel = -1, lastSelDoc = null;
  let opens = [];                      // 줄 순서대로 {docId}
  let pref = loadPref();               // {groups:[…], mine:bool, stale:bool, theme:bool(주제별), brief:bool(브리핑 펼침)}
  let flashTimer = 0;

  // v0.8 Claude 브리핑
  const AI = () => window.SynapseAI || null;
  let aiRes = null, aiStat = null, aiSeq = 0, aiOffs = [];
  let aiLast = null;                   // 마지막 aiDigest 응답 (탭을 다시 열 때 바로 보이게)
  let D = null;                        // 지금 그리는 정리(digest) — renderBody가 정한다. 줄 아래 설명·주제 묶기가 쓴다
  const acted = new Map();             // 정리 제안 → 'applied' | 'proposed' (화면을 떠났다 와도 남는다. 키에 정리를 만든 시각이 들어 있다)
  let dlg = null, dlgEl = null;        // 반영 확인 창 {item, ref, op, body, to, phase:'edit'|'busy', error, pid, back}
  const unfold = { focus: false, clean: false };   // 카드가 너무 길어지지 않게 3줄만 보이고 "더 보기"로 펼친다
  const CAP = 3;

  const E = v => api.esc(v == null ? '' : String(v));
  const num = n => Number(n || 0).toLocaleString('ko-KR');
  const ic = n => { try { return api.icon(n) || ''; } catch (_) { return ''; } };

  function loadPref() {
    const d = { groups: DEFAULT_GROUPS.slice(), mine: false, stale: false, theme: false, brief: true };
    try {
      const v = JSON.parse(localStorage.getItem(STORE_KEY) || 'null');
      if (v && Array.isArray(v.groups)) d.groups = v.groups.filter(g => GROUPS.indexOf(g) >= 0);
      if (v && typeof v.mine === 'boolean') d.mine = v.mine;
      if (v && typeof v.stale === 'boolean') d.stale = v.stale;
      if (v && typeof v.theme === 'boolean') d.theme = v.theme;
      if (v && typeof v.brief === 'boolean') d.brief = v.brief;
    } catch (_) { /* 저장소를 못 읽어도 기본값으로 */ }
    return d;
  }
  function savePref() { try { localStorage.setItem(STORE_KEY, JSON.stringify(pref)); } catch (_) { /* 저장하지 못해도 화면은 그대로 */ } }

  function init(a) { api = a; const ai = AI(); if (ai) ai.init(a); }

  function mount(l) {
    if (!api) return;
    unmount();
    listEl = l;
    root = document.createElement('div');
    root.className = 'tk';
    root.innerHTML = '<div class="tk-bar" data-r="bar" role="group" aria-label="티켓 거르기"></div>' +
      '<div class="tk-note" data-r="note" id="tk-rule" hidden></div>' +
      '<div class="tk-scroll" data-r="scroll" role="listbox" aria-label="열린 티켓"></div>';
    listEl.textContent = '';
    listEl.appendChild(root);
    scrollEl = root.querySelector('[data-r="scroll"]');
    root.addEventListener('click', onClick);
    sel = -1;
    // v0.8: 지난번에 받은 브리핑을 먼저 보여 주고(실행 중 표시는 뺀다), 새로 읽는다
    const ai = AI();
    aiStat = ai ? ai.cached() : null;
    aiRes = aiLast && aiLast.digest ? Object.assign({}, aiLast, { running: false }) : null;
    if (ai) {
      ai.bindRefs(root);
      aiOffs = [ai.on('digest', onAIDigest), ai.on('status', onAIStatus), ai.on('run', onAIRun)];
    }
    renderBar();
    refresh(true);
    aiLoad('auto');
  }
  function unmount() {
    seq++; aiSeq++; clearTimeout(flashTimer);
    aiOffs.forEach(off => { try { off(); } catch (_) { /* 이미 풀렸다 */ } });
    aiOffs = [];
    if (dlg) closeDlg(false);
    if (root && root.parentNode) root.parentNode.removeChild(root);
    root = scrollEl = listEl = null;
    data = null; opens = []; aiRes = null; D = null;
  }

  async function refresh(skipAI) {
    if (!api || !root) return;
    if (skipAI !== true) aiLoad('none');   // 새로 고침: 브리핑은 읽기만 (새로 돌리는 건 열 때·다시 정리 버튼)
    const my = ++seq;
    loading = !data; loadError = null;
    renderBar(); if (loading) renderBody();
    let res = null, err = null;
    try { res = await api.call('tickets', {}); } catch (e) { err = (e && e.message) || '불러오지 못했어요'; }
    if (my !== seq || !root) return;
    loading = false;
    if (err || !res || res.ok === false) {
      // 예시 자료(demo)에는 티켓이 없다 — 조용히 빈 상태로 끝낸다
      loadError = err || (res && res.error) || '불러오지 못했어요';
      data = null;
    } else data = res;
    renderBar(); renderBody();
  }

  // ---------- 거르기 ----------
  const allItems = () => (data ? data.projects || [] : []).reduce((a, p) => a.concat(p.items || []), []);
  const inScope = it => !pref.mine || it.mine;
  function countsOf(items) {
    const c = { blocked: 0, doing: 0, todo: 0, stale: 0 };
    items.forEach(it => { if (c[it.statusGroup] != null) c[it.statusGroup]++; if (it.stale) c.stale++; });
    return c;
  }

  // ---------- 그리기 ----------
  function shape(g) {
    const c = window.SynapseCluster;
    return c && typeof c.shapeHtml === 'function' ? c.shapeHtml(g) : '<i class="tk-dot"></i>';
  }
  const RULE_BASE = "막힘은 아직 끝나지 않은 티켓 중 '막힘·보류' 상태만 세요.";
  const closedLike = () => {
    const r = data && data.blockedRule && data.blockedRule.closedLike;
    return Array.isArray(r) ? r.filter(x => typeof x === 'string' && x) : [];
  };
  // 막힘 0 설명 한 줄. 이름은 실제 자료에서 모은 것이고, 비면 뒤 문장은 뺀다.
  function ruleText() {
    const names = closedLike();
    return RULE_BASE + (names.length ? ' ' + names.join('·') + '은 이 팀 Jira에서 완료 분류라 닫힘으로 봐요.' : '');
  }
  const ruleShort = () => {
    const names = closedLike();
    return "막힘·보류 상태의 열린 티켓만 세요." + (names.length ? ' ' + names.join('·') + '은 닫힘으로 봐요.' : '');
  };
  const staleDays = it => {
    const g = data && data.generatedAt ? Date.parse(data.generatedAt) : Date.now(), u = Date.parse(it.updated);
    return isNaN(u) ? 0 : Math.max(0, Math.floor((g - u) / 86400000));
  };
  function renderBar() {
    const bar = root && root.querySelector('[data-r="bar"]'); if (!bar) return;
    const c = countsOf(allItems().filter(inScope));
    const mineN = data && data.totals ? data.totals.mine : 0;
    const chips = GROUPS.map(g => {
      const on = pref.groups.indexOf(g) >= 0, zeroB = g === 'blocked' && c[g] === 0 && !!data;
      const tip = zeroB ? '막힘 0개 · ' + ruleShort() : LABEL[g] + ' 티켓 ' + (on ? '숨기기' : '보기');
      return '<button type="button" class="tk-chip st-' + g + (c[g] === 0 ? ' is-zero' : '') + '" data-g="' + g + '" aria-pressed="' + on + '" aria-label="' + LABEL[g] + ' ' + num(c[g]) + '개 보기"' +
        (zeroB ? ' aria-describedby="tk-rule" aria-description="' + E(ruleShort()) + '"' : '') + ' title="' + E(tip) + '">' +
        '<span class="tk-ci">' + shape(g) + '</span><span class="tk-cl">' + LABEL[g] + '</span><b class="num">' + num(c[g]) + '</b></button>';
    }).join('');
    const staleOff = c.stale === 0 && !pref.stale;
    const staleChip = '<button type="button" class="tk-chip tk-schip' + (c.stale === 0 ? ' is-zero' : '') + '" data-act="stale" aria-pressed="' + pref.stale + '" aria-label="7일 넘게 그대로 ' + num(c.stale) + '개만 보기"' +
      (staleOff ? ' aria-disabled="true"' : '') + ' title="' + (staleOff ? '7일 넘게 그대로인 진행 중 티켓이 없어요' : '진행 중인데 7일 넘게 갱신이 없는 티켓만 ' + (pref.stale ? '그만 보기' : '보기')) + '">' +
      '<span class="tk-ci"><svg viewBox="0 0 12 12" width="12" height="12" aria-hidden="true"><circle cx="6" cy="6" r="4.6" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M6 3.4V6l1.8 1.1" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/></svg></span>' +
      '<span class="tk-cl">7일 넘게 그대로</span><b class="num">' + num(c.stale) + '</b></button>';
    // v0.8: Claude가 묶은 주제가 있을 때만 "주제별" 토글을 둔다 (끄면 예전처럼 프로젝트별)
    const themeBtn = aiPlan().themes && data && data.hasJira && (data.projects || []).length
      ? '<button type="button" class="tk-mine tk-theme" data-act="theme" aria-pressed="' + pref.theme + '" title="Claude가 묶은 주제로 보기 · 끄면 프로젝트별로 봐요">' +
        '<span class="tk-sw" aria-hidden="true"></span>' + ic('sparkle') + '<span>주제별</span></button>' : '';
    const html = chips + '<span class="tk-vsep" aria-hidden="true"></span>' + staleChip + '<span class="tk-gap"></span>' + themeBtn +
      '<button type="button" class="tk-mine" data-act="mine" aria-pressed="' + pref.mine + '" title="내가 담당인 티켓만 보기">' +
        '<span class="tk-sw" aria-hidden="true"></span><span>내 담당만</span>' + (data ? '<b class="num">' + num(mineN) + '</b>' : '') + '</button>';
    keepFocus(bar, () => { bar.innerHTML = html; });
    renderNote(c);
  }
  // 칩 막대 아래 흐린 한 줄: 막힘이 0일 때만
  function renderNote(c) {
    const n = root && root.querySelector('[data-r="note"]'); if (!n) return;
    const show = !!data && data.hasJira && (data.projects || []).length > 0 && c.blocked === 0;
    n.hidden = !show;
    if (show) n.textContent = ruleText();
  }
  function flashNote() {
    const n = root && root.querySelector('[data-r="note"]'); if (!n || n.hidden) return;
    n.classList.add('is-flash');
    clearTimeout(flashTimer);
    flashTimer = setTimeout(() => { n.classList.remove('is-flash'); }, 2600);
    if (api && api.toast) api.toast('막힘 0 · ' + ruleShort(), '', 3200);
  }
  // 다시 그려도 키보드 포커스를 잃지 않게: 포커스 요소의 data-* 로 찾아 되돌린다
  function keepFocus(box, fn) {
    const a = document.activeElement; let q = '';
    if (a && box && a !== box && box.contains(a)) {
      for (const at of Array.from(a.attributes)) if (at.name.indexOf('data-') === 0) q += '[' + at.name + '="' + String(at.value).replace(/["\\]/g, '\\$&') + '"]';
    }
    fn();
    if (q) { const n = box.querySelector(q); if (n && !n.disabled) n.focus({ preventScroll: true }); }
  }

  function headHtml(key, c, shown) {
    const bits = [
      '<span class="tk-hb' + (c.blocked === 0 ? ' is-zero' : ' is-hot') + '">막힘 <b class="num">' + num(c.blocked) + '</b></span>',
      '<span class="tk-hb">진행 중 <b class="num">' + num(c.doing) + '</b></span>',
      '<span class="tk-hb">할 일 <b class="num">' + num(c.todo) + '</b></span>',
    ];
    if (c.stale > 0) bits.push('<button type="button" class="tk-hb tk-hbtn is-warn" data-act="stale" aria-pressed="' + pref.stale + '" aria-label="' + E(key) + ' 7일 넘게 그대로 ' + num(c.stale) + '개만 보기" title="진행 중인데 7일 넘게 갱신이 없는 티켓만 ' + (pref.stale ? '그만 보기' : '보기') + '">7일 넘게 그대로 <b class="num">' + num(c.stale) + '</b></button>');
    return '<h3 class="tk-ph' + (shown ? '' : ' is-quiet') + '"><span class="tk-pk">' + E(key) + '</span>' + bits.join('<span class="tk-sep" aria-hidden="true">·</span>') + '</h3>';
  }
  // 거르기 때문에 숨은 줄 안내: 꺼 둔 상태 칩의 티켓 수, 7일 넘게 그대로 거르기에 걸러진 수
  function hiddenHtml(scoped, want) {
    const out = [];
    GROUPS.forEach(g => {
      if (want.has(g)) return;
      const n = scoped.filter(it => it.statusGroup === g).length;
      if (n > 0) out.push('<button type="button" class="tk-more" data-show="' + g + '"><span>' + LABEL[g] + ' ' + num(n) + '개는 숨겼어요</span><span class="tk-more-go">· 보기</span></button>');
    });
    if (pref.stale) {
      const n = scoped.filter(it => want.has(it.statusGroup) && !it.stale).length;
      if (n > 0) out.push('<button type="button" class="tk-more" data-show="stale"><span>7일 넘게 그대로가 아닌 ' + num(n) + '개는 숨겼어요</span><span class="tk-more-go">· 보기</span></button>');
    }
    return out.length ? '<div class="tk-hide">' + out.join('') + '</div>' : '';
  }
  const PERSON = '<svg class="tk-person" viewBox="0 0 12 12" width="11" height="11" aria-hidden="true"><circle cx="6" cy="4" r="2.2" fill="none" stroke="currentColor" stroke-width="1.3"/><path d="M1.9 10.3c.5-2 2.1-3 4.1-3s3.6 1 4.1 3" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/></svg>';
  // v0.8: Claude가 쉬운 말로 쓴 한 줄 (정리에 lines가 있을 때만)
  function lineHtml(it) {
    const t = D && D.lines && typeof D.lines === 'object' ? D.lines[it.key] : '';
    return t ? '<span class="tk-ln" title="' + E(t) + '">' + ic('sparkle') + '<span>' + E(t) + '</span></span>' : '';
  }
  function rowHtml(it) {
    opens.push({ docId: it.docId });
    const n = opens.length - 1;
    const who = it.mine ? '<span class="tk-who is-me" title="내가 담당인 티켓">' + PERSON + '나</span>' : it.assigneeName ? '<span class="tk-who">' + E(it.assigneeName) + '</span>' : '';
    const prio = it.priorityRank <= 1 && it.priority ? '<span class="tk-prio' + (it.priorityRank === 0 ? ' is-top' : '') + '">' + E(it.priority) + '</span>' : '';
    const due = it.dueLabel ? '<span class="tk-due' + (/지남|오늘|D-[0-3]\b/.test(it.dueLabel) ? ' is-hot' : '') + '">' + E(it.dueLabel) + '</span>' : '';
    // 7일 넘게 그대로인 줄은 "34일째 그대로" 한 번만 보인다(갱신 경과와 같은 뜻이라 갱신 문구는 뺀다)
    const timeText = it.sinceLabel || (it.stale ? '' : '갱신 ' + it.updatedLabel);
    const time = timeText ? '<span class="tk-time">' + E(timeText) + '</span>' : '';
    const stale = it.stale ? '<span class="tk-stale" title="진행 중인데 7일 넘게 갱신이 없어요">' + staleDays(it) + '일째 그대로</span>' : '';
    const tip = it.status + (it.issueType ? ' · ' + it.issueType : '') + ' · 갱신 ' + it.updatedLabel;
    return '<button type="button" role="option" aria-selected="false" tabindex="-1" class="tk-row st-' + E(it.statusGroup) + (it.stale ? ' is-stale' : '') + '" data-n="' + n + '" data-doc="' + E(it.docId) + '" data-tkdoc="' + E(it.docId) + '" title="' + E(tip) + '">' +
      '<span class="tk-ico st-key st-' + E(it.statusGroup) + '">' + shape(it.statusGroup) + '</span>' +
      '<span class="tk-key">' + E(it.key) + '</span>' +
      '<span class="tk-tl"><span class="tk-title">' + E(it.title) + '</span>' + lineHtml(it) + '</span>' +
      '<span class="tk-meta">' + stale + who + prio + due + time + '</span></button>';
  }
  // 프로젝트 안 상태 소제목(막힘 → 진행 중 → 할 일): 모양 아이콘 + 글자 + 수. 줄은 이 묶음 안에 둔다.
  function groupsHtml(key, rows) {
    let h = '';
    GROUPS.forEach(g => {
      const rs = rows.filter(it => it.statusGroup === g);
      if (!rs.length) return;
      h += '<div class="tk-grp" role="group" aria-label="' + E(key + ' ' + LABEL[g] + ' ' + rs.length + '개') + '">' +
        '<div class="tk-gh st-' + g + '" aria-hidden="true"><span class="tk-ico st-key st-' + g + '">' + shape(g) + '</span><span>' + LABEL[g] + '</span><b class="num">' + num(rs.length) + '</b></div>' +
        rs.map(rowHtml).join('') + '</div>';
    });
    return h;
  }
  function stateHtml(title, msg) {
    return '<div class="tk-state"><strong>' + E(title) + '</strong>' + (msg ? '<span>' + E(msg) + '</span>' : '') + '</div>';
  }
  function renderBody() {
    if (!scrollEl) return;
    const top = scrollEl.scrollTop;
    opens = []; D = null;
    let h;
    if (loading && !data) h = '<div class="tk-state"><i class="spinner lg"></i><span>티켓을 모으는 중이에요</span></div>';
    else if (!data) {
      h = /예시|사용할 수 없|열지 못|알 수 없는/.test(loadError || '')
        ? stateHtml('이 자료에서는 티켓을 볼 수 없어요', '예시 자료에는 Jira 티켓이 없어요. 자료에서 Atlassian을 연결하면 여기에 모여요.')
        : '<div class="tk-state is-error"><strong>티켓을 열지 못했어요</strong><span>' + E(loadError || '') + '</span><button class="btn sm" type="button" data-act="retry">다시 시도</button></div>';
    } else if (!data.hasJira) {
      h = stateHtml('연결된 Jira가 없어요', '자료 버튼에서 Atlassian을 연결하면 열린 티켓이 프로젝트별로 여기에 모여요.');
    } else if (!(data.projects || []).length) {
      h = stateHtml('열린 티켓이 없어요', '막힘·진행 중·할 일 상태의 티켓이 하나도 없어요. 모두 끝났거나 닫혔어요.');
    } else {
      const want = new Set(pref.groups);
      const plan = aiPlan();
      D = plan.card && aiRes ? aiRes.digest : null;   // 줄 아래 설명·주제 묶기가 쓴다
      const themed = pref.theme && plan.themes && !!D;
      let shownAny = false, parts = '';
      if (themed) {
        // v0.8 주제별: 프로젝트 대신 Claude 주제로 묶는다. 어느 주제에도 없는 티켓은 "기타"
        const scopedAll = allItems().filter(inScope), at = new Map();
        D.themes.forEach((th, i) => (th.refs || []).forEach(r => { if (r && r.key && !at.has(r.key)) at.set(r.key, i); }));
        const buckets = D.themes.map(th => ({ title: th.title, summary: th.summary, items: [] })), other = { title: '기타', summary: '어느 주제에도 들어가지 않은 티켓이에요', items: [] };
        scopedAll.forEach(it => { const i = at.get(it.key); (i == null ? other : buckets[i]).items.push(it); });
        parts += hiddenHtml(scopedAll, want);
        buckets.concat([other]).forEach((b, bi) => {
          if (!b.items.length) return;
          const rows = [].concat.apply([], GROUPS.map(g => b.items.filter(it => it.statusGroup === g && want.has(g) && (!pref.stale || it.stale))));
          shownAny = shownAny || rows.length > 0;
          parts += '<section class="tk-proj tk-theme-sec" data-th="' + bi + '">' + headHtml(b.title, countsOf(b.items), rows.length > 0) +
            (b.summary ? '<p class="tk-ts">' + E(b.summary) + '</p>' : '') + '<div class="tk-grp" role="group" aria-label="' + E(b.title + ' ' + rows.length + '개') + '">' + rows.map(rowHtml).join('') + '</div></section>';
        });
      } else {
        (data.projects || []).forEach(p => {
          const scoped = (p.items || []).filter(inScope);
          if (!scoped.length) return;
          const rows = scoped.filter(it => want.has(it.statusGroup) && (!pref.stale || it.stale));
          shownAny = shownAny || rows.length > 0;
          const label = p.label || p.key;
          parts += '<section class="tk-proj" data-p="' + E(p.key) + '">' + headHtml(label, countsOf(scoped), rows.length > 0) + hiddenHtml(scoped, want) + groupsHtml(label, rows) + '</section>';
        });
      }
      const lead = leadHtml(plan);
      if (!parts) h = lead + stateHtml('내 담당 열린 티켓이 없어요', '위의 "내 담당만"을 끄면 팀 전체의 열린 티켓을 볼 수 있어요.');
      else if (!pref.groups.length) h = lead + stateHtml('보고 싶은 상태를 켜 주세요', '위의 막힘·진행 중·할 일 칩을 눌러 켤 수 있어요.') + parts;
      else if (!shownAny) h = lead + stateHtml(pref.stale ? '7일 넘게 그대로인 티켓이 없어요' : '고른 상태의 티켓이 없어요', pref.stale ? '위의 "7일 넘게 그대로"를 끄면 다른 티켓도 볼 수 있어요.' : '숫자가 있는 다른 상태 칩을 켜 보세요.') + parts;
      else h = lead + parts;
    }
    keepFocus(scrollEl, () => { scrollEl.innerHTML = h; });
    scrollEl.scrollTop = top;
    // 선택 되살리기: 같은 문서가 아직 있으면 그 줄, 아니면 처음
    if (lastSelDoc) { const i = opens.findIndex(o => o.docId === lastSelDoc); sel = i; } else sel = Math.min(sel, opens.length - 1);
    paintSel(false);
  }
  // roving tabindex: 고른 줄만 tabindex 0(고른 줄이 없으면 첫 줄), 나머지는 -1. 포커스가 줄에 있으면 따라 옮긴다.
  function paintSel(scroll) {
    if (!root) return;
    const rows = root.querySelectorAll('.tk-row');
    const a = document.activeElement, onRow = !!a && a.classList && a.classList.contains('tk-row') && root.contains(a);
    let picked = null;
    rows.forEach(n => {
      const on = sel >= 0 && +n.dataset.n === sel;
      n.classList.toggle('is-sel', on);
      n.setAttribute('aria-selected', String(on));
      n.tabIndex = on || (sel < 0 && n === rows[0]) ? 0 : -1;
      if (on) picked = n;
    });
    if (picked) {
      if (scroll && picked.scrollIntoView) picked.scrollIntoView({ block: 'nearest' });
      if (onRow && a !== picked) picked.focus({ preventScroll: true });
    }
  }

  // ---------- v0.8 Claude 브리핑 ----------
  // 무엇을 보여 줄지: card = 브리핑 카드 · skel = 처음 읽는 중(뼈대) · notice = 위에 띄울 한 줄 안내 · themes = "주제별" 토글을 보이나
  function aiPlan() {
    const ai = AI(), p = { card: false, skel: false, notice: '', themes: false };
    if (!ai) return p;
    const st = aiStat, res = aiRes;
    if ((st && st.unsupported) || (res && res.unsupported)) return p;                    // 옛 앱·미리보기: 조용히 예전 화면
    if (st && st.available === false) { p.notice = ai.noticeHTML(st, E); return p; }      // 꺼짐·Claude 없음
    if (res && (res.blocked === 'disabled' || res.blocked === 'unavailable')) { p.notice = ai.noticeHTML(res, E); return p; }
    if (res && res.digest) {
      p.card = true;
      p.themes = Array.isArray(res.digest.themes) && res.digest.themes.length > 0;
      if (!res.running) p.notice = ai.noticeHTML(res, E);                                 // 정리는 있는데 새로 못 읽었을 때
      return p;
    }
    if (res && res.running) { p.skel = true; return p; }
    if (!res) { p.skel = !!(st && st.available); return p; }
    if (res.state === 'empty') return p;
    p.notice = ai.noticeHTML(res, E);                                                     // 정리가 없고, 못 돌린 이유가 있다
    return p;
  }
  async function aiLoad(run) {
    const ai = AI(); if (!ai || !root) return;
    const my = ++aiSeq;
    const [st, res] = await Promise.all([ai.status(), ai.digest('tickets', { run: run || 'none' })]);
    if (my !== aiSeq || !root) return;
    aiStat = st; aiRes = res; aiLast = res;
    renderBar(); renderBody();
  }
  function onAIDigest(e) { if (root && e && e.kind === 'tickets') aiLoad('none'); }
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
  const clip = (t, n) => { const a = Array.from(String(t == null ? '' : t).replace(/\s+/g, ' ').trim()); return a.length > n ? a.slice(0, n).join('') + '…' : a.join(''); };
  // 정리 속 티켓 참조 → 지금 목록의 티켓 (제목·상태는 목록 것이 정확하다)
  function ticketOf(ref) {
    if (!ref || !data) return null;
    return allItems().find(it => (ref.key && it.key === ref.key) || (ref.docId && it.docId === ref.docId)) || null;
  }
  function titleOf(ref) {
    const t = ticketOf(ref); if (t) return t.title;
    const raw = String(ref.title || ''), k = ref.key ? String(ref.key) : '';
    return k && raw.indexOf(k) === 0 ? (raw.slice(k.length).replace(/^[\s·:\-–]+/, '') || raw) : raw;
  }
  const stamp = () => String((aiRes && aiRes.meta && aiRes.meta.created) || (aiRes && aiRes.scope) || '');
  const cleanKey = c => [stamp(), c.ref && c.ref.key, c.op, c.op === 'transition' ? c.to : ''].join('|');
  const validClean = c => !!(c && c.ref && c.ref.key && (c.op === 'comment' || c.op === 'transition'));
  function cleanRow(c, i) {
    const ai = AI(), t = ticketOf(c.ref), st = acted.get(cleanKey(c));
    const what = c.op === 'comment' ? '댓글 남기기' : '상태 바꾸기';
    const detail = c.op === 'comment' ? '“' + clip(c.body, 64) + '”' : (t && t.status ? E(t.status) + ' → ' : '→ ') + '<b>' + E(c.to) + '</b>';
    const tail = st === 'applied' ? '<span class="tk-ok">' + ic('check') + '반영됨</span>'
      : st === 'proposed' ? '<span class="tk-ok is-queue">정리함에 올림</span><button type="button" class="link-btn" data-act="to-queue">정리함 열기</button>'
      : '<button type="button" class="btn sm" data-act="apply-open" data-i="' + i + '" aria-label="' + E(c.ref.key + ' ' + what + ' 반영하기') + '">반영하기…</button>';
    return '<li class="tk-cr' + (st ? ' is-done' : '') + '"><span class="tk-fk">' + ai.refsHTML([c.ref], E) + '</span><div class="tk-fb">' +
      '<span class="tk-ft"><b class="tk-op">' + what + '</b> ' + E(titleOf(c.ref)) + '</span>' +
      '<span class="ai-why">' + (c.op === 'comment' ? E(detail) : detail) + (c.why ? ' · ' + E(c.why) : '') + '</span></div><span class="tk-ca">' + tail + '</span></li>';
  }
  function briefHtml(plan) {
    const ai = AI(); if (!ai) return '';
    const res = aiRes, d = plan.card && res ? res.digest : null, busy = !!(res && res.running), open = pref.brief;
    if (!d) {
      if (!plan.skel) return '';
      return '<section class="ai-card tk-brief" aria-busy="true" aria-label="Claude 브리핑을 만드는 중"><div class="ai-head"><span class="ai-tag">' + ic('sparkle') + 'Claude 브리핑</span></div>' +
        '<div class="ai-notice is-run" role="status"><span class="ai-notice-ic"><i class="spinner" aria-hidden="true"></i></span><span class="ai-notice-t">Claude가 티켓을 읽고 있어요…</span></div>' + ai.skeletonHTML(4) + '</section>';
    }
    const focus = (d.focus || []).filter(f => f && f.ref);
    const clean = (d.cleanup || []).map((c, i) => (validClean(c) ? cleanRow(c, i) : '')).filter(Boolean);
    let h = '<section class="ai-card tk-brief' + (busy ? ' is-stale' : '') + '" aria-label="Claude 브리핑"' + (busy ? ' aria-busy="true"' : '') + '>' +
      '<div class="ai-head"><span class="ai-tag">' + ic('sparkle') + 'Claude 브리핑</span><span class="ai-head-r"><button type="button" class="tk-fold" data-act="brief" aria-expanded="' + open + '">' + (open ? '접기' : '펼치기') + '</button></span></div>';
    if (busy) h += ai.noticeHTML(Object.assign({}, res, { what: '티켓을' }), E);
    h += '<div class="ai-body">';
    if (d.headline) h += '<p class="ai-headline">' + E(d.headline) + '</p>';
    if (open) {
      if (focus.length) {
        h += '<section class="ai-sec"><div class="ai-sec-h"><h3 class="ai-sec-t">지금 볼 것</h3><span class="tk-n num">' + focus.length + '</span></div><ul class="ai-items">' +
          (unfold.focus ? focus : focus.slice(0, CAP)).map(f => '<li class="tk-fr"><span class="tk-fk">' + ai.refsHTML([f.ref], E) + '</span><div class="tk-fb"><span class="tk-ft">' + E(titleOf(f.ref)) + '</span>' +
            (f.why || f.action ? '<span class="ai-why">' + (f.why ? E(f.why) : '') + (f.why && f.action ? ' · ' : '') + (f.action ? '<b>' + E(f.action) + '</b>' : '') + '</span>' : '') + '</div></li>').join('') +
          (focus.length > CAP ? '<li class="tk-more-li"><button type="button" class="link-btn" data-act="more-focus">' + (unfold.focus ? '접기' : (focus.length - CAP) + '개 더 보기') + '</button></li>' : '') + '</ul></section>';
      }
      if (clean.length) {
        h += '<section class="ai-sec"><div class="ai-sec-h"><h3 class="ai-sec-t">정리 제안</h3><span class="tk-n num">' + clean.length + '</span></div>' +
          '<p class="ai-why tk-cnote">Jira는 아직 바뀌지 않았어요. 반영하기…를 눌러 내용을 확인한 뒤에만 바뀌어요.</p><ul class="ai-items">' + (unfold.clean ? clean : clean.slice(0, CAP)).join('') +
          (clean.length > CAP ? '<li class="tk-more-li"><button type="button" class="link-btn" data-act="more-clean">' + (unfold.clean ? '접기' : (clean.length - CAP) + '개 더 보기') + '</button></li>' : '') + '</ul></section>';
      }
    } else if (focus.length || clean.length) h += '<p class="ai-lead">지금 볼 것 ' + focus.length + '개 · 정리 제안 ' + clean.length + '개</p>';
    h += '</div>' + ai.metaHTML(res.meta, E, { stale: res.state === 'stale' && !busy, busy }) + '</section>';
    return h;
  }
  function leadHtml(plan) {
    const brief = briefHtml(plan);
    return (plan.notice ? '<div class="tk-lead">' + plan.notice + '</div>' : '') + brief;
  }

  // ---------- 반영 확인 창 (Jira에 쓰는 유일한 길) ----------
  const callAPI = async (m, p) => { try { const r = await api.call(m, p || {}); return r && typeof r === 'object' ? r : { ok: false, error: '응답을 읽지 못했어요' }; } catch (e) { return { ok: false, error: (e && e.message) || '처리하지 못했어요' }; } };
  function openDlg(i) {
    const d = aiRes && aiRes.digest, c = d && d.cleanup ? d.cleanup[i] : null;
    if (!root || !validClean(c) || acted.get(cleanKey(c))) return;
    if (dlg) closeDlg(false);
    dlg = { item: c, ref: c.ref, op: c.op, key: cleanKey(c), body: String(c.body || ''), to: String(c.to || ''), phase: 'edit', error: '', pid: null, applied: false, idx: i, back: document.activeElement };
    dlgEl = document.createElement('div');
    dlgEl.className = 'tk-dlg-wrap';
    const t = ticketOf(c.ref), isC = c.op === 'comment';
    dlgEl.innerHTML = '<div class="tk-dlg" role="dialog" aria-modal="true" aria-labelledby="tk-dlg-t" aria-describedby="tk-dlg-w" tabindex="-1">' +
      '<div class="tk-dlg-h"><h2 id="tk-dlg-t">' + (isC ? 'Jira에 댓글 남기기' : 'Jira 상태 바꾸기') + '</h2><button class="icon-btn sm" type="button" data-act="dlg-close" aria-label="닫기 · esc">' + ic('x') + '</button></div>' +
      '<div class="tk-dlg-tk"><span class="ai-ref is-static" data-kind="ticket">' + E(c.ref.key) + '</span><span class="tk-dlg-tt">' + E(titleOf(c.ref)) + '</span>' + (t && t.status ? '<span class="tk-dlg-st">지금 ' + E(t.status) + '</span>' : '') + '</div>' +
      (isC
        ? '<label class="tk-dlg-f"><span class="tk-dlg-l">댓글 <em>고칠 수 있어요</em><i class="num" data-r="dlg-count"></i></span><textarea class="input tk-dlg-ta" data-r="dlg-body" rows="6" maxlength="4000" spellcheck="false"></textarea></label>'
        : '<label class="tk-dlg-f"><span class="tk-dlg-l">바꿀 상태 <em>고칠 수 있어요 · Jira의 상태 이름과 같아야 해요</em></span><input class="input tk-dlg-in" data-r="dlg-to" type="text" spellcheck="false"></label>') +
      (c.why ? '<p class="tk-dlg-why">Claude의 이유 · ' + E(c.why) + '</p>' : '') +
      '<div class="tk-dlg-warn" id="tk-dlg-w" role="note">' + ic('alert') + '<div><strong>Jira에 바로 반영돼요 · 되돌릴 수 없어요</strong><span>팀원 모두에게 보여요. 한 번 더 확인하고 싶으면 먼저 정리함에 올릴 수 있어요.</span></div></div>' +
      '<div class="tk-dlg-err form-error" data-r="dlg-err" role="alert" hidden></div>' +
      '<div class="tk-dlg-b"><button class="btn" type="button" data-act="dlg-close">취소</button><span class="tk-gap"></span>' +
        '<button class="btn" type="button" data-act="dlg-queue">정리함에 올리기</button><button class="btn primary" type="button" data-act="dlg-apply">Jira에 반영</button></div></div>';
    root.appendChild(dlgEl);
    const f = dlgEl.querySelector('[data-r="dlg-body"], [data-r="dlg-to"]');
    f.value = isC ? dlg.body : dlg.to;                    // 값은 DOM에 직접 넣는다(따옴표·줄바꿈 그대로)
    if (isC) { updateCount(); f.addEventListener('input', updateCount); }
    f.focus({ preventScroll: true });                    // 버튼이 아니라 입력칸에 포커스: ↵ 한 번에 반영되지 않는다
  }
  function updateCount() {
    const f = dlgEl && dlgEl.querySelector('[data-r="dlg-body"]'), n = dlgEl && dlgEl.querySelector('[data-r="dlg-count"]');
    if (f && n) n.textContent = num(f.value.length) + ' / 4,000';
  }
  function paintDlg() {
    if (!dlgEl || !dlg) return;
    const busy = dlg.phase === 'busy', err = dlgEl.querySelector('[data-r="dlg-err"]');
    dlgEl.querySelectorAll('textarea, input, button').forEach(n => { n.disabled = busy; });
    dlgEl.querySelector('.tk-dlg').setAttribute('aria-busy', String(busy));
    err.hidden = !dlg.error; err.textContent = dlg.error;
    const q = dlgEl.querySelector('[data-act="dlg-queue"]'), a = dlgEl.querySelector('[data-act="dlg-apply"]');
    q.hidden = !!dlg.pid;                                  // 이미 정리함에 올라갔으면 다시 올리지 않는다
    a.textContent = busy ? '반영하는 중…' : dlg.pid ? '다시 시도' : 'Jira에 반영';
    // 막혔던 버튼이 풀리면 포커스가 body로 빠진다 — 입력칸으로 돌린다(버튼이 아니라서 ↵로 반영되지 않는다)
    if (!busy && !dlgEl.contains(document.activeElement)) { const f = dlgEl.querySelector('[data-r="dlg-body"], [data-r="dlg-to"]'); if (f) f.focus({ preventScroll: true }); }
  }
  function closeDlg(restore) {
    const d = dlg, el = dlgEl;
    dlg = null; dlgEl = null;
    if (el && el.parentNode) el.parentNode.removeChild(el);
    if (!d) return;
    if (d.pid && !d.applied) acted.set(d.key, 'proposed');   // 정리함에는 올라가 있다
    if (restore && root) {
      const back = scrollEl && scrollEl.querySelector('[data-act="apply-open"][data-i="' + d.idx + '"]');
      if (back) back.focus({ preventScroll: true }); else if (d.back && d.back.focus && document.body.contains(d.back)) d.back.focus({ preventScroll: true });
    }
  }
  function dlgFail(d, msg) {
    if (d.pid) msg += ' · 정리함에 올려 둔 상태예요. 다시 시도하거나 정리함에서 반영할 수 있어요.';
    if (dlg === d) { d.phase = 'edit'; d.error = msg; paintDlg(); } else api.toast(msg, 'error', 5200);
  }
  const rejectReason = r => (r && r.rejected && r.rejected[0] && r.rejected[0].reason) || (r && r.error) || '제안을 올리지 못했어요';
  // apply=true: jiraPropose → jiraApply(바로 반영) · false: jiraPropose만(정리함에 올리기)
  async function dlgSubmit(apply) {
    const d = dlg; if (!d || d.phase === 'busy' || !dlgEl) return;
    const f = dlgEl.querySelector('[data-r="dlg-body"], [data-r="dlg-to"]');
    const v = f.value.trim();
    if (d.op === 'comment') { if (!v) { d.error = '댓글 글을 써 주세요'; paintDlg(); return; } if (v.length > 4000) { d.error = '댓글은 4,000자까지예요'; paintDlg(); return; } d.body = v; }
    else { if (!v) { d.error = '바꿀 상태 이름을 써 주세요'; paintDlg(); return; } d.to = v; }
    d.phase = 'busy'; d.error = ''; paintDlg();
    const key = d.ref.key;
    if (!d.pid) {
      const it = { op: d.op, key, reason: d.item.why || 'Claude가 제안했어요' };
      if (d.op === 'transition') it.to = d.to; else it.body = d.body;
      const r = await callAPI('jiraPropose', { items: [it] });
      const acc = r.ok !== false && Array.isArray(r.accepted) ? r.accepted[0] : null;
      if (!acc || !acc.id) { dlgFail(d, rejectReason(r)); return; }
      d.pid = acc.id;
      if (!apply) {
        acted.set(d.key, 'proposed');
        if (dlg === d) closeDlg(true);
        api.toast(key + ' 제안을 정리함에 올렸어요 · 정리함(⌘3)에서 반영할 수 있어요', '', 4600);
        if (root) renderBody();
        return;
      }
    }
    const p = { id: d.pid };
    if (d.op === 'comment') p.body = d.body; else p.to = d.to;
    const r2 = await callAPI('jiraApply', p);
    if (r2.ok === false) { dlgFail(d, r2.error || 'Jira에 반영하지 못했어요'); return; }
    d.applied = true;
    acted.set(d.key, 'applied');
    if (dlg === d) closeDlg(true);
    api.toast(r2.message || (key + '에 반영했어요'), '', 4600);
    if (root) { renderBody(); setTimeout(() => { if (root) refresh(true); }, 2500); }   // 동기화가 빨리 끝났다면 목록에도 바로 보인다
  }
  function dlgKey(e) {
    const k = e.key, a = document.activeElement, field = !!a && (a.tagName === 'TEXTAREA' || a.tagName === 'INPUT');
    if (k === 'Escape' && !e.metaKey && !e.ctrlKey && !e.altKey) { e.preventDefault(); if (dlg.phase !== 'busy') closeDlg(true); return true; }
    if (k === 'Tab' && !e.metaKey && !e.ctrlKey && !e.altKey) {           // 창 안에서만 돈다
      const f = Array.from(dlgEl.querySelectorAll('textarea, input, button')).filter(n => !n.disabled && !n.hidden);
      e.preventDefault();
      if (f.length) { const i = f.indexOf(a); f[e.shiftKey ? (i <= 0 ? f.length - 1 : i - 1) : (i < 0 || i === f.length - 1 ? 0 : i + 1)].focus({ preventScroll: true }); }
      return true;
    }
    if (field) { if (k === 'Enter' && a.tagName === 'INPUT') { e.preventDefault(); return true; } return false; }   // 입력칸: 글자·방향키는 그대로
    if (e.metaKey || e.ctrlKey || e.altKey) return false;
    if (k === 'Enter' || k === ' ') return false;                           // 포커스가 있는 버튼의 기본 동작
    return k.length === 1 || k.indexOf('Arrow') === 0;                      // 창 뒤의 목록·검색으로 새지 않게 삼킨다
  }

  // ---------- 동작 ----------
  function toggleGroup(g) {
    const i = pref.groups.indexOf(g);
    if (i >= 0) pref.groups.splice(i, 1); else pref.groups.push(g);
    savePref(); sel = -1; lastSelDoc = null;
    renderBar(); renderBody();
  }
  // 7일 넘게 그대로: 켜면 그 티켓만(진행 중 칩도 같이 켠다). 같은 토글을 칩과 프로젝트 머리가 함께 쓴다.
  function toggleStale() {
    pref.stale = !pref.stale;
    if (pref.stale && pref.groups.indexOf('doing') < 0) pref.groups.push('doing');
    savePref(); sel = -1; lastSelDoc = null;
    renderBar(); renderBody();
  }
  function showHidden(what) {
    if (what === 'stale') pref.stale = false;
    else if (GROUPS.indexOf(what) >= 0 && pref.groups.indexOf(what) < 0) pref.groups.push(what);
    savePref(); sel = -1; lastSelDoc = null;
    renderBar(); renderBody();
  }
  function toggleMine() {
    pref.mine = !pref.mine; savePref(); sel = -1; lastSelDoc = null;
    renderBar(); renderBody();
  }
  function toggleTheme() {
    pref.theme = !pref.theme; savePref(); sel = -1; lastSelDoc = null;
    renderBar(); renderBody();
  }
  function toggleBrief() { pref.brief = !pref.brief; savePref(); renderBody(); }
  function openAt(n, orig) {
    const o = opens[n]; if (!o) return;
    sel = n; lastSelDoc = o.docId; paintSel(false);
    if (orig) api.openOriginal(o.docId); else api.openDoc(o.docId);
  }
  function move(d) {
    if (!opens.length) return;
    sel = Math.max(0, Math.min(opens.length - 1, (sel < 0 ? (d > 0 ? 0 : opens.length - 1) : sel + d)));
    lastSelDoc = opens[sel].docId;
    paintSel(true);
  }
  function onClick(e) {
    if (!root) return;   // 참조 칩이 문서를 여는 사이 화면이 내려간 경우
    const dl = e.target.closest('[data-act^="dlg-"]');
    if (dl && dlgEl && dlgEl.contains(dl)) {
      if (dl.dataset.act === 'dlg-close') { if (dlg && dlg.phase !== 'busy') closeDlg(true); }
      else if (dl.dataset.act === 'dlg-queue') dlgSubmit(false);
      else if (dl.dataset.act === 'dlg-apply') dlgSubmit(true);
      return;
    }
    if (dlgEl && dlgEl.contains(e.target)) return;
    const ac = e.target.closest('[data-ai-act]');
    if (ac && root.contains(ac)) { if (ac.dataset.aiAct === 'retry' || ac.dataset.aiAct === 'regen') { e.preventDefault(); aiLoad('force'); } return; }   // preventDefault: app.js가 같은 단추를 또 처리하지 않게. 설정 열기는 app.js가 맡는다
    if (e.target.closest('.ai-ref') && root.contains(e.target.closest('.ai-ref'))) return;   // 칩이 문서를 여는 건 SynapseAI.bindRefs
    const chip = e.target.closest('[data-g]');
    if (chip && root.contains(chip)) {
      // 막힘이 0인 칩은 흐려지기만 하지 않고 왜 0인지 안내를 보인다
      if (chip.dataset.g === 'blocked' && data && countsOf(allItems().filter(inScope)).blocked === 0) { flashNote(); return; }
      toggleGroup(chip.dataset.g); return;
    }
    const more = e.target.closest('[data-show]');
    if (more && root.contains(more)) { showHidden(more.dataset.show); return; }
    const b = e.target.closest('[data-act]');
    if (b && root.contains(b)) {
      if (b.dataset.act === 'mine') toggleMine();
      else if (b.dataset.act === 'theme') toggleTheme();
      else if (b.dataset.act === 'brief') toggleBrief();
      else if (b.dataset.act === 'more-focus') { unfold.focus = !unfold.focus; renderBody(); }
      else if (b.dataset.act === 'more-clean') { unfold.clean = !unfold.clean; renderBody(); }
      else if (b.dataset.act === 'apply-open') openDlg(+b.dataset.i);
      else if (b.dataset.act === 'to-queue') { if (api.setMode) api.setMode('queue'); }
      else if (b.dataset.act === 'stale') { if (b.getAttribute('aria-disabled') !== 'true') toggleStale(); }
      else if (b.dataset.act === 'retry') refresh();
      return;
    }
    const row = e.target.closest('.tk-row[data-n]');
    if (row && root.contains(row)) openAt(+row.dataset.n, false);
  }
  // 줄 우클릭은 app.js의 문서 메뉴가 data-tkdoc를 보고 연다.
  function onKey(e) {
    if (!root || !api || e.isComposing || e.keyCode === 229) return false;
    if (dlg && dlgEl) return dlgKey(e);   // 반영 확인 창이 떠 있으면 키는 창이 받는다
    const k = e.key, a = document.activeElement;
    if ((e.metaKey || e.ctrlKey) && !e.altKey && !e.shiftKey && k === 'Enter' && sel >= 0) { e.preventDefault(); openAt(sel, true); return true; }
    if (e.metaKey || e.ctrlKey || e.altKey) return false;
    const typing = !!a && (a.tagName === 'INPUT' || a.tagName === 'TEXTAREA' || a.tagName === 'SELECT' || a.isContentEditable);
    const emptyInput = typing && a.value === '';
    if (typing && !emptyInput) return false;
    if (k === 'ArrowDown' || k === 'ArrowUp') { e.preventDefault(); move(k === 'ArrowDown' ? 1 : -1); return true; }
    if (k === 'Enter' && emptyInput && sel >= 0) { e.preventDefault(); openAt(sel, false); return true; }   // 검색창이 비어 있으면 ↵로 고른 줄을 연다
    if (typing) return false;
    if (a && a !== document.body && !(listEl && listEl.contains(a))) return false;
    // 칩·토글에 포커스가 있으면 ↵·Space는 그 버튼이 받는다(기본 동작)
    if (a && a.tagName === 'BUTTON' && !a.classList.contains('tk-row')) return false;
    if (k === 'Enter' && sel >= 0 && !(a && a.classList.contains('tk-row'))) { e.preventDefault(); openAt(sel, false); return true; }
    const ch = /^[a-zA-Z]$/.test(k) ? k.toLowerCase() : (/^Key[A-Z]$/.test(e.code || '') ? e.code.slice(3).toLowerCase() : '');
    if (ch === 'j') { e.preventDefault(); move(1); return true; }
    if (ch === 'k') { e.preventDefault(); move(-1); return true; }
    return false;
  }

  window.SynapseTickets = Object.freeze({ init, mount, refresh, onKey, unmount });
})();
