// Synapse v0.5 — 홈(§9.2) · 왜? 팝오버(§9.3) · 지도 흐름 목록(§9.4)의 HTML 조각. docs/V05.md §5.3~§5.6
// 상태(선택·펼침·팝오버 단계)와 키·브리지 호출은 app.js가 들고, 여기서는 받은 JSON을 그리기만 한다.
// window.SynapseHome.create({ esc, icon }) → { build, flowDetail, why, flows, legend, rowId }
// 버튼·줄은 data-hact(동작)·data-hkey(홈 줄)·data-fkey(흐름 줄)로 표시하고, app.js가 위임 처리한다.
(function () {
  'use strict';

  const SRC_LABEL = { apple: '기기 AI', claude: 'Claude', codex: 'Codex' };
  const TOOL = { claude: 'Claude', codex: 'Codex' };
  const TIER_LABEL = { now: '지금', week: '이번 주', dormant: '잠듦', none: '' };
  const SESSION_TEXT = 'Claude·Codex 기록으로 ‘하던 일’을 더 정확히 보여 드릴까요?';
  const SESSION_DETAIL = '읽는 것: 세션 제목·작업 폴더·브랜치·AI가 쓴 파일 경로·시각·내 요청 첫 줄(80자, 키·토큰은 가림, 30일 보관). ' +
    'AI 답변·도구 결과·파일 내용은 읽지 않고, 이 Mac 밖으로 보내지 않아요.';

  // 할 일 문구의 마크다운 기호를 화면용 글자로 정리한다: **굵게** __굵게__ `코드` [[링크|별칭]] [글자](주소) ~~취소~~
  const plain = s => String(s == null ? '' : s)
    .replace(/!?\[([^\]]*)\]\((?:[^()\s]|\([^)]*\))*(?:\s+"[^"]*")?\)/g, '$1')
    .replace(/\[\[([^\]]*)\]\]/g, (m, t) => { const i = t.indexOf('|'); return i >= 0 ? t.slice(i + 1) : t.replace(/#.*$/, ''); })
    .replace(/(\*\*|__)(.+?)\1/g, '$2').replace(/~~(.+?)~~/g, '$1').replace(/\*\*/g, '').replace(/`+([^`]*)`+/g, '$1')
    .replace(/^\s*[-*]\s+\[[ xX]\]\s+/, '').replace(/\s{2,}/g, ' ').trim();

  // v0.9 리뷰 카드는 한 번 닫으면 그날은 숨는다 (localStorage — 못 쓰면 이번 실행 동안만)
  const REVIEW_KEY = 'synapse.home.reviewDismissed.v1';
  let reviewMem = '';
  const dayKey = () => { const d = new Date(); return d.getFullYear() + '-' + (d.getMonth() + 1) + '-' + d.getDate(); };
  function reviewDismissed() {
    if (reviewMem === dayKey()) return true;
    try { return localStorage.getItem(REVIEW_KEY) === dayKey(); } catch (_) { return false; }
  }
  function dismissReview() {
    reviewMem = dayKey();
    try { localStorage.setItem(REVIEW_KEY, dayKey()); } catch (_) { /* 저장하지 못해도 이번 실행 동안은 숨는다 */ }
  }

  function create(h) {
    const esc = h.esc, icon = h.icon;
    const cut = (s, n) => { s = String(s || ''); return s.length > n ? s.slice(0, n - 1) + '…' : s; };
    const rowId = i => 'hrow-' + i;
    const srcBadge = s => SRC_LABEL[s] ? '<span class="h-src" data-src="' + esc(s) + '">' + esc(SRC_LABEL[s]) + '</span>' : '';

    // 근거 칩: 최대 3개. 규칙이 아닌 출처는 작은 표식을 붙인다(§1.2 정직하게 표시).
    function chipsHtml(list) {
      const cs = (Array.isArray(list) ? list : []).filter(c => c && c.text).slice(0, 3);
      if (!cs.length) return '';
      return '<div class="h-chips">' + cs.map(c => '<span class="h-chip" data-kind="' + esc(c.kind || '') + '"><i aria-hidden="true"></i>' +
        esc(plain(c.text)) + srcBadge(c.source) + '</span>').join('') + '</div>';
    }
    const hasChips = it => !!it && Array.isArray(it.chips) && it.chips.some(c => c && c.text);

    // v0.7 A: 맨 위 한 줄 "막힘 0 · 진행 중 8 · 7일 넘게 그대로 2 ›". 열린 티켓이 없으면(Jira 없음 포함) null. 누르면 ⌘5 티켓 화면.
    function ticketsLine(t, i, sel) {
      if (!t || typeof t !== 'object') return '';
      const n = k => Number(t[k]) || 0;
      if (n('blocked') + n('doing') + n('todo') <= 0) return '';
      const sep = '<span class="tk-sep" aria-hidden="true">·</span>';
      const parts = ['<span class="tk-lc' + (n('blocked') ? ' is-hot' : ' is-zero') + '">막힘 <b class="num">' + n('blocked') + '</b></span>',
        '<span class="tk-lc">진행 중 <b class="num">' + n('doing') + '</b></span>'];
      if (n('stale') > 0) parts.push('<span class="tk-lc is-warn">7일 넘게 그대로 <b class="num">' + n('stale') + '</b></span>');
      return '<div class="tk-line" role="option" id="' + rowId(i) + '" data-hkey="tickets" data-hact="mode" data-mode="tickets" aria-selected="' + (sel === 'tickets') + '" title="티켓 · ⌘5">' +
        '<span class="tk-lk">' + icon('ticket') + '티켓</span>' + parts.join(sep) + '<span class="tk-go" aria-hidden="true">›</span></div>';
    }

    // v0.9: 정리 한 줄 "오늘 Synapse가 정리한 것 2 · 승인 기다리는 것 12 ›". 둘 다 0이면 숨김. 누르면 작업 지도의 정리 계획.
    function tidyLine(t, i, sel) {
      if (!t || typeof t !== 'object') return '';
      const a = Number(t.autoToday) || 0, p = Number(t.pending) || 0;
      if (a + p <= 0) return '';
      const sep = '<span class="tk-sep" aria-hidden="true">·</span>';
      return '<div class="tk-line td-line" role="option" id="' + rowId(i) + '" data-hkey="tidy" data-hact="tidy-plan" aria-selected="' + (sel === 'tidy') + '" title="작업 지도 · 정리 계획">' +
        '<span class="tk-lk">' + icon('workmap') + '정리</span>' +
        '<span class="tk-lc' + (a ? '' : ' is-zero') + '">오늘 Synapse가 정리한 것 <b class="num">' + a + '</b></span>' + sep +
        '<span class="tk-lc' + (p ? ' is-warn' : ' is-zero') + '">승인 기다리는 것 <b class="num">' + p + '</b></span>' +
        '<span class="td-to">작업 지도</span><span class="tk-go" aria-hidden="true">›</span></div>';
    }
    // v0.9: 리뷰 요일 카드 "금요일 정리 리뷰 — 정리 안 됨 N · 보관 후보 M · 이번 주 정리 보기"
    function reviewCard(t, i, sel) {
      const rv = t && t.review;
      if (!rv || !rv.due || reviewDismissed()) return '';
      const c = t.counts || {}, loose = (Number(c.loose) || 0) + (Number(c.inbox) || 0), stale = Number(c.stale) || 0;
      return '<div class="h-card td-review" role="option" id="' + rowId(i) + '" data-hkey="review" aria-selected="' + (sel === 'review') + '">' +
        '<div class="h-card-t">' + icon('calendar') + '<strong>' + esc(rv.label || '정리 리뷰') + '</strong></div>' +
        '<p>정리 안 됨 <b class="num">' + loose + '</b> · 보관 후보 <b class="num">' + stale + '</b> · 이번 주 정리 보기</p>' +
        '<div class="h-card-b"><button class="btn sm primary" type="button" data-hact="tidy-plan">이번 주 정리 보기<kbd>↵</kbd></button>' +
        '<button class="btn sm" type="button" data-hact="review-dismiss" title="오늘은 다시 보이지 않아요">오늘은 닫기</button></div></div>';
    }

    // 둘째 줄: 멈춘 곳 · 열린 할 일 · 기한 · Claude 16:20 “요청…” · 산출물 n
    function subParts(it) {
      const parts = [], chipText = new Set((it.chips || []).map(c => c && c.text));
      if (it.code && it.sessionTitle) parts.push('세션 ‘' + esc(cut(it.sessionTitle, 24)) + '’');
      if (it.stopped) parts.push(it.stopped.heading ? '멈춘 곳 ‘' + esc(cut(it.stopped.heading, 22)) + '’' : it.stopped.line ? '멈춘 곳 ' + esc(it.stopped.line) + '행' : '');
      if (it.openTasks > 0 && !chipText.has('할 일 ' + it.openTasks)) parts.push('열린 할 일 ' + esc(it.openTasks));
      if (it.dueLabel && !chipText.has(it.dueLabel)) parts.push('<span class="h-due">' + esc(it.dueLabel) + '</span>');
      const a = it.lastAsk;
      if (a) parts.push(esc(TOOL[a.tool] || 'AI') + ' ' + esc(a.atLabel || '') + (a.text ? ' <q>' + esc(cut(a.text, 26)) + '</q>' : ' 요청'));
      const outs = Math.max(Number(a && a.outputs) || 0, Array.isArray(it.outputs) ? it.outputs.length : 0);
      if (outs) parts.push('산출물 ' + outs);
      return parts.filter(Boolean);
    }
    function markIcon(it, kind) {
      if (it.pinned) return icon('pin');
      if (kind === 'urgent') return icon('flag');
      if (it.code) return icon('code');
      if (it.tier === 'dormant') return icon('moon');
      return '';
    }
    function row(it, i, sel, kind) {
      const meta = [it.whenLabel, it.actorLabel].filter(Boolean).map(esc).join(' · ');
      const sub = subParts(it);
      const mk = markIcon(it, kind);
      const cur = kind === 'current';
      return '<div class="h-row is-' + kind + (it.pinned ? ' is-pinned' : '') + '" role="option" id="' + rowId(i) + '" data-hkey="' + esc(it.id) + '" aria-selected="' + (sel === it.id) + '">' +
        '<div class="h-l1">' + (mk ? '<span class="h-mark">' + mk + '</span>' : '') +
          '<span class="h-title">' + esc(plain(it.title) || '제목 없음') + '</span>' +
          (kind === 'urgent' && window.SynapseHomeUrgent ? window.SynapseHomeUrgent.mark(it, esc) : '') +   // v0.7 B: 업무/개인 표시
          (meta ? '<span class="h-meta">' + meta + '</span>' : '') + '</div>' +
        (sub.length ? '<div class="h-sub">' + sub.map(x => '<span>' + x + '</span>').join('<span class="h-sep">·</span>') + '</div>' : '') +
        (cur && it.summary ? '<div class="h-sum">' + esc(it.summary) + (it.summarySource === 'apple' ? srcBadge('apple') : '') + '</div>' : '') +
        chipsHtml(it.chips) +
        (cur ? '<div class="h-go"><kbd>↵</kbd>' + (it.docId ? (it.stopped ? '멈춘 곳 열기' : '열기') : '흐름 보기') + '<kbd>⌘/</kbd>왜?</div>' : '') +
      '</div>';
    }
    function sessionsCard(i, sel) {
      return '<div class="h-card" role="option" id="' + rowId(i) + '" data-hkey="card:sessions" aria-selected="' + (sel === 'card:sessions') + '">' +
        '<div class="h-card-t">' + icon('sparkle') + '<strong>' + esc(SESSION_TEXT) + '</strong></div>' +
        '<p>' + esc(SESSION_DETAIL) + '</p>' +
        '<div class="h-card-b"><button class="btn sm primary" type="button" data-hact="sessions-on">켜기<kbd>↵</kbd></button>' +
        '<button class="btn sm" type="button" data-hact="sessions-later">나중에<kbd>⌘↓</kbd></button></div></div>';
    }
    // 사서 줄: 사서 · 새 문서 5 확인 · 제자리 3 · 정리 2 ⌘3 · 이번 주 ⌘4 · 규칙 (· 오래된 할 일 n)
    function librarian(lib, oldTasks) {
      lib = lib || {};
      const sep = '<span class="h-sep">·</span>';
      const parts = [];
      if (lib.stopped) {
        parts.push('<span class="h-lib-name is-stopped">' + icon('pause') + '사서 멈춤</span>');
        parts.push('<button class="link-btn" type="button" data-hact="restart">다시 시작</button>');
      } else {
        parts.push('<span class="h-lib-name">' + icon('brand') + '사서</span>');
        if (lib.newDocs) parts.push('새 문서 ' + esc(lib.newDocs) + ' 확인');
        if (lib.inPlace) parts.push('제자리 ' + esc(lib.inPlace));
      }
      if (lib.pending) parts.push('<button class="h-lib-btn" type="button" data-hact="mode" data-mode="queue" title="정리함 · ⌘3">정리 ' + esc(lib.pending) + '<kbd>⌘3</kbd></button>');
      parts.push('<button class="h-lib-btn" type="button" data-hact="mode" data-mode="week" title="이번 주 · ⌘4">이번 주<kbd>⌘4</kbd></button>');
      if (!lib.stopped && lib.engineLabel) parts.push('<button class="h-engine" type="button" data-hact="settings" title="' + (lib.engine === 'apple' ? '기기 AI가 요약·이유 문장을 보태요' : '규칙과 통계로 동작 중이에요 · 설정 보기') + '">' + esc(lib.engineLabel) + '</button>');
      if (oldTasks > 0) parts.push('<span class="h-old" title="60일 넘게 안 바뀐 문서의 열린 할 일">오래된 할 일 ' + esc(oldTasks) + '</span>');
      return '<div class="h-lib" role="group" aria-label="사서">' + parts.join(sep) + '</div>';
    }
    function emptyHtml() {
      return '<div class="h-empty">' + icon('doc') + '<div><strong>아직 하던 일 기록이 없어요.</strong>' +
        '<p>문서를 열거나 고치면 여기에 이어서 할 일이 생겨요.</p>' +
        '<p class="h-empty-keys"><span><kbd>글자 입력</kbd>문서 검색</span><span><kbd>⌘2</kbd>작업 지도에서 둘러보기</span></p></div></div>';
    }

    // 홈 전체: 급한 것 → 세션 카드 → 지금 하던 일 → 이어서(+잠듦 N ▸) → 사서 줄. order = 키보드로 고를 수 있는 줄(위→아래)
    function build(data, ui) {
      data = data || {};
      ui = ui || {};
      const sel = ui.sel, order = [];
      let html = '', i = 0;
      const push = (key, item, kind) => { order.push({ key, item: item || null, kind }); return i++; };
      const sec = (title, extra) => '<div class="sec-head h-head">' + title + (extra || '') + '</div>';
      const tkLine = ticketsLine(data.tickets, i, sel);
      if (tkLine) { push('tickets', null, 'tickets'); html += tkLine; }
      const tdLine = tidyLine(data.tidy, i, sel);
      if (tdLine) { push('tidy', null, 'tidy'); html += tdLine; }
      const rvCard = reviewCard(data.tidy, i, sel);
      if (rvCard) { push('review', null, 'review'); html += rvCard; }
      const urgent = (data.urgent || []).filter(hasChips);
      if (urgent.length && window.SynapseHomeUrgent) {   // v0.7 B: 거르기 칩 · 프로젝트 칩 · 3줄 + 더 보기 (src/homeurgent.js)
        html += window.SynapseHomeUrgent.build(data, ui, { esc, icon, row, push, order, sel, rowId, hasChips });
      } else if (urgent.length) {
        html += '<div class="h-group is-urgent" role="group" aria-label="급한 것">' + sec('급한 것', ' <span class="cnt">' + urgent.length + '</span>') +
          urgent.map(it => row(it, push(it.id, it, 'urgent'), sel, 'urgent')).join('') + '</div>';
      }
      if (data.sessions && data.sessions.askCard && !ui.cardDone) html += sessionsCard(push('card:sessions', null, 'card'), sel);
      const cur = hasChips(data.current) ? data.current : null;
      if (cur) html += '<div class="h-group" role="group" aria-label="지금 하던 일">' + sec('지금 하던 일') + row(cur, push(cur.id, cur, 'current'), sel, 'current') + '</div>';
      const next = (data.next || []).filter(hasChips).slice(0, 3);
      const dorm = data.dormant || { count: 0, items: [] };
      if (next.length || dorm.count) {
        html += '<div class="h-group" role="group" aria-label="이어서">' + (next.length ? sec('이어서', ' <span class="cnt">' + next.length + '</span>') : '') +
          next.map(it => row(it, push(it.id, it, 'next'), sel, 'next')).join('');
        if (dorm.count) {
          const open = !!ui.dormantOpen;
          const k = push('dormant', null, 'toggle');
          html += '<div class="h-row h-toggle" role="option" id="' + rowId(k) + '" data-hkey="dormant" aria-expanded="' + open + '" aria-selected="' + (sel === 'dormant') + '">' +
            icon('moon') + '<span>잠듦 ' + esc(dorm.count) + '</span><span class="h-caret" aria-hidden="true">' + (open ? '▾' : '▸') + '</span>' +
            '<span class="h-toggle-k"><kbd>→</kbd>' + (open ? '접기' : '펼치기') + '</span></div>';
          if (open) html += (dorm.items || []).filter(hasChips).map(it => row(it, push(it.id, it, 'dormant'), sel, 'dormant')).join('');
        }
        html += '</div>';
      }
      if (data.empty || (!urgent.length && !cur && !next.length && !dorm.count)) html += emptyHtml();
      html += librarian(data.librarian, Number(data.oldTasks) || 0);
      return { html: '<div class="home">' + html + '</div>', order };
    }

    // 코드 흐름(docId 없음)을 ↵로 열면 리더에 그리는 상세: 저장소·브랜치·마지막 요청·AI가 쓴 파일(누르면 열림)
    function flowDetail(it) {
      it = it || {};
      const c = it.code || {}, a = it.lastAsk;
      const rows = [['저장소', c.repo], ['브랜치', c.branch], ['세션', it.sessionTitle], ['마지막 활동', [it.whenLabel, it.actorLabel].filter(Boolean).join(' · ')]]
        .filter(r => r[1]).map(r => '<dt>' + esc(r[0]) + '</dt><dd>' + esc(r[1]) + '</dd>').join('');
      const outs = Array.isArray(it.outputs) ? it.outputs.filter(o => o && o.docId) : [];
      return '<div class="flow-detail">' +
        '<div class="reader-head"><div class="meta"><span class="topic-chip">' + icon('code') + '코드 작업</span>' + (it.tier && TIER_LABEL[it.tier] ? '<span class="meta-sep">·</span><span>' + esc(TIER_LABEL[it.tier]) + '</span>' : '') + '</div></div>' +
        '<h1 class="reader-title">' + esc(plain(it.title)) + '</h1>' +
        (c.cwd ? '<div class="reader-path">' + icon('folder') + '<span title="' + esc(c.cwd) + '">' + esc(c.cwd) + '</span></div>' : '') +
        chipsHtml(it.chips) +
        (rows ? '<dl class="fd-grid">' + rows + '</dl>' : '') +
        (a ? '<section class="rel"><h2 class="rel-head">마지막 요청</h2><p class="fd-ask"><b>' + esc(TOOL[a.tool] || 'AI') + ' · ' + esc(a.atLabel || '') + '</b>' +
          (a.text ? '<q>' + esc(a.text) + '</q>' : '<span>요청 문장은 설정에서 끄셨어요</span>') + '</p></section>' : '') +
        '<section class="rel"><h2 class="rel-head">AI가 쓴 문서 <span class="cnt">' + outs.length + '</span></h2>' +
        (outs.length ? outs.map(o => '<button class="rel-row" type="button" data-hact="open-doc" data-doc="' + esc(o.docId) + '" title="리더에서 열기">' +
          icon('doc') + '<span class="t">' + esc(o.title || o.docId) + '</span>' + icon('next') + '</button>').join('')
          : '<div class="rel-none">이 흐름에서 볼트에 쓴 문서가 없어요</div>') + '</section></div>';
    }

    // 왜? 팝오버 (§9.3). ui = { phase: 'list'|'demote'|'rename', sel: 이유 번호, busy }
    function why(w, ui) {
      ui = ui || {};
      if (!w || w.loading) return '<div class="why-h"><span class="why-t">왜 여기 있나요?</span></div><div class="why-wait"><span class="spinner" aria-hidden="true"></span>이유를 모으는 중…</div>';
      if (w.error) return '<div class="why-h"><span class="why-t">왜 여기 있나요?</span></div><p class="why-err">' + icon('alert') + esc(w.error) + '</p>';
      const reasons = (w.reasons || []).filter(r => r && r.text);
      const acts = (w.actions || []).filter(a => a && a.id);
      const KEY = { pin: 'p', unpin: 'p', demote: 'd', wake: 'w', rename: 'r' };
      let foot;
      if (ui.phase === 'demote') {
        foot = '<div class="why-sub" role="group" aria-label="덜 중요"><span>얼마나 덜 중요하게 볼까요?</span>' +
          '<button class="btn sm" type="button" data-hact="why-scope" data-scope="week"><kbd>1</kbd>이번 주만</button>' +
          '<button class="btn sm" type="button" data-hact="why-scope" data-scope="always"><kbd>2</kbd>계속</button></div>';
      } else if (ui.phase === 'rename') {
        foot = '<form class="why-sub why-rename" data-hact="why-rename-form"><input class="input why-input" type="text" maxlength="60" value="' + esc(w.title || '') + '" aria-label="새 이름" spellcheck="false" autocomplete="off">' +
          '<button class="btn sm primary" type="submit">바꾸기<kbd>↵</kbd></button></form>';
      } else {
        foot = '<div class="why-acts">' + acts.map(a => '<button class="why-act" type="button" data-hact="why-act" data-wact="' + esc(a.id) + '"' + (ui.busy ? ' disabled' : '') + '>' +
          (KEY[a.id] ? '<kbd>' + KEY[a.id] + '</kbd>' : '') + esc(a.label || a.id) + '</button>').join('') + '</div>';
      }
      return '<div class="why-h"><span class="why-t">왜 여기 있나요?</span>' + (w.tierLabel ? '<span class="why-tier" data-tier="' + esc(w.tier || '') + '">' + esc(w.tierLabel) + '</span>' : '') +
          '<button class="icon-btn sm" type="button" data-hact="why-close" title="닫기 · esc" aria-label="닫기">' + icon('x') + '</button></div>' +
        '<div class="why-title">' + esc(w.title || '') + '</div>' +
        (reasons.length ? '<ul class="why-list" role="listbox" aria-label="이유">' + reasons.map((r, i) => {
          const can = r.docId != null;
          return '<li><' + (can ? 'button type="button" data-hact="why-reason" data-doc="' + esc(r.docId) + '"' + (r.line != null ? ' data-line="' + esc(r.line) + '"' : '') : 'div') +
            ' class="why-r' + (can ? '' : ' is-static') + '" role="option" aria-selected="' + (ui.sel === i) + '">' +
            '<span class="why-r-t">' + esc(r.text) + srcBadge(r.source) + '</span>' + (r.detail ? '<span class="why-r-d">' + esc(r.detail) + '</span>' : '') +
            (can ? icon('next') : '') + '</' + (can ? 'button' : 'div') + '></li>';
        }).join('') + '</ul>' : '<p class="why-none">근거를 찾지 못했어요.</p>') + foot;
    }

    // 지도 목록 칸: 흐름 목록 (제목 · 단계 · 마지막 활동 · 열린 할 일)
    const colorVar = th => th && th.colorIndex >= 0 && th.colorIndex < 8 ? 'var(--topic-g' + th.colorIndex + ')' : 'var(--topic-other)';
    function flows(map, ui) {
      ui = ui || {};
      const list = (map && Array.isArray(map.threads) ? map.threads : []).filter(th => th && th.id != null);
      const order = list.map(th => ({ key: String(th.id), item: th }));
      if (!list.length) return { html: '<div class="list-empty"><strong>아직 작업 흐름이 없어요</strong><p>문서를 고치거나 열면 흐름이 생겨요. 그래프는 지금도 둘러볼 수 있어요.</p></div>', order };
      const html = '<div class="sec-group" role="group" aria-labelledby="sec-flows"><div class="sec-head" id="sec-flows">작업 흐름 <span class="cnt">' + list.length + '</span></div>' +
        list.map((th, i) => {
          const sub = [];
          if (th.lastLabel) sub.push('마지막 활동 ' + esc(th.lastLabel));
          if (th.openTasks > 0) sub.push('열린 할 일 ' + esc(th.openTasks));
          sub.push('문서 ' + esc((th.docIds || []).length));
          return '<div class="h-row f-row' + (th.tier === 'dormant' ? ' is-dormant' : '') + '" role="option" id="frow-' + i + '" data-fkey="' + esc(th.id) + '" aria-selected="' + (ui.sel === String(th.id)) + '" style="--topic:' + colorVar(th) + '">' +
            '<div class="h-l1"><span class="dot" aria-hidden="true"></span><span class="h-title">' + esc(plain(th.title) || '흐름') + '</span>' +
            (TIER_LABEL[th.tier] ? '<span class="h-meta f-tier" data-tier="' + esc(th.tier) + '">' + esc(TIER_LABEL[th.tier]) + '</span>' : '') + '</div>' +
            '<div class="h-sub">' + sub.map(x => '<span>' + x + '</span>').join('<span class="h-sep">·</span>') + '</div></div>';
        }).join('') + '</div>';
      return { html, order };
    }
    // 지도 범례: 흐름 이름(최대 8) + 흐름 없음. 누르면 그 흐름을 고른다.
    function legend(map, sel) {
      const list = (map && Array.isArray(map.threads) ? map.threads : []).filter(th => th && th.colorIndex >= 0 && th.colorIndex < 8).slice(0, 8);
      if (!list.length) return '';
      return list.map(th => '<button class="legend-chip is-flow' + (sel && sel !== String(th.id) ? ' is-faded' : '') + '" type="button" data-fkey="' + esc(th.id) + '" aria-pressed="' + (sel === String(th.id)) + '" style="--topic:' + colorVar(th) + '" title="‘' + esc(plain(th.title)) + '’ 흐름만 강조">' +
        '<span class="dot" aria-hidden="true"></span><span class="lbl">' + esc(plain(th.title)) + '</span></button>').join('') +
        '<span class="legend-chip is-none" style="--topic:var(--topic-other)"><span class="dot" aria-hidden="true"></span><span class="lbl">흐름 없음</span></span>';
    }

    return { build, flowDetail, why, flows, legend, rowId, chipsHtml, colorVar, TIER_LABEL };
  }

  window.SynapseHome = Object.freeze({ create, dismissReview, reviewDismissed });
})();
