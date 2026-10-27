// Synapse 묶음 지도·티켓 상태 도우미 — window.SynapseCluster (v0.6 G).
// 화면 문구와 HTML 조각만 만든다. 상태·이벤트는 app.js가 맡는다(순수 함수 + 의존성은 ctx로 받는다).
(function () {
  'use strict';

  // 티켓 상태 묶음 (엔진 Views.statusGroup과 같은 다섯 가지)
  const GROUPS = ['todo', 'doing', 'blocked', 'done', 'dropped'];
  const LABEL = { todo: '할 일', doing: '진행 중', blocked: '막힘', done: '완료', dropped: '닫힘' };
  const num = n => Number(n || 0).toLocaleString('ko-KR');

  function statusLabel(group) { return LABEL[group] || ''; }

  // 목록 행·리더 머리·묶음 요약에 다는 상태 칩. Jira 문서가 아니면 빈 문자열.
  function chipHtml(doc, esc) {
    if (!doc || !doc.statusGroup || !LABEL[doc.statusGroup]) return '';
    const tip = '상태: ' + (doc.status || LABEL[doc.statusGroup]) + (doc.priority ? ' · 우선순위 ' + doc.priority : '') + (doc.mine ? ' · 내 티켓' : '');
    return '<span class="st-chip st-' + esc(doc.statusGroup) + '" title="' + esc(tip) + '">' + esc(doc.statusGroup === 'dropped' && doc.status ? doc.status : LABEL[doc.statusGroup]) + '</span>';   // 닫힘 계열은 원래 상태 이름(Won't Do·Duplicate …)을 보인다
  }

  // 상태마다 모양이 달라 색을 못 가려도 구분된다 (그래프의 티켓 노드와 같은 모양)
  const SHAPE = {
    todo: '<rect x="1.5" y="1.5" width="9" height="9" rx="2.5" fill="currentColor" fill-opacity=".14" stroke="currentColor" stroke-width="1.6"/>',
    doing: '<rect x="1" y="1" width="10" height="10" rx="2.5" fill="currentColor"/><rect x="3.4" y="3.4" width="5.2" height="5.2" rx="1" fill="none" stroke="#fff" stroke-opacity=".85" stroke-width="1.1"/>',
    blocked: '<rect x="1" y="1" width="10" height="10" rx="2.5" fill="currentColor"/><path d="M6 3v3.6" stroke="#fff" stroke-width="1.6" stroke-linecap="round"/><circle cx="6" cy="8.8" r=".9" fill="#fff"/>',
    done: '<rect x="1" y="1" width="10" height="10" rx="2.5" fill="currentColor" fill-opacity=".62"/><path d="M3.2 6.2l2 2 3.6-4.2" fill="none" stroke="#fff" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>',
    dropped: '<rect x="1.5" y="1.5" width="9" height="9" rx="2.5" fill="none" stroke="currentColor" stroke-width="1.4" stroke-dasharray="2 1.6"/><path d="M3.2 8.8L8.8 3.2" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/>',
  };
  const shapeHtml = g => '<svg viewBox="0 0 12 12" width="12" height="12" aria-hidden="true">' + (SHAPE[g] || SHAPE.todo) + '</svg>';

  // 그래프 위 티켓 상태 범례 한 줄 (티켓이 보일 때만). note: 끝에 붙일 안내(상한 등)
  function legendHtml(note) {
    return ['todo', 'doing', 'blocked', 'done', 'dropped'].map(g =>
      '<span class="st-key st-' + g + '">' + shapeHtml(g) + LABEL[g] + '</span>').join('') +
      '<span class="st-key st-mine"><i aria-hidden="true"></i>내 티켓</span>' +
      (note ? '<span class="st-note">' + note + '</span>' : '');
  }

  // "끝난 티켓 883 숨김 · 보기" / "끝난 티켓 883 보이는 중 · 숨기기"
  function doneToggleText(count, shown) {
    return shown ? '끝난 티켓 ' + num(count) + ' 보이는 중 · 숨기기' : '끝난 티켓 ' + num(count) + ' 숨김 · 보기';
  }

  const SRC_LABEL = { jira: 'Jira 프로젝트', confluence: 'Confluence 스페이스', local: '폴더' };

  // 리더에 보여 줄 "묶음 요약": 문서 수 · 열린 티켓 · 최근 7일 수정, 최근 문서 5, 열린 티켓 5, "펼치기 ↵".
  // ctx: { esc, icon, relDate(iso), topicVar(group), groupLabel(group) }
  function summaryHtml(n, ctx) {
    const esc = ctx.esc;
    const mix = n.statusMix || {};
    const total = GROUPS.reduce((s, g) => s + (mix[g] || 0), 0);
    const stat = (v, l, cls) => '<div class="cs-stat' + (cls ? ' ' + cls : '') + '"><b>' + num(v) + '</b><span>' + l + '</span></div>';
    const rows = (list, withStatus) => list.map(d =>
      '<button class="rel-row cs-row" type="button" data-cdoc="' + esc(d.id) + '" title="클릭: 선택">' +
      '<span class="t">' + esc(d.title) + '</span>' +
      (withStatus ? chipHtml(d, esc) : (d.statusGroup ? chipHtml(d, esc) : '')) +
      '<span class="why">' + esc(d.updated ? ctx.relDate(d.updated) : '') + '</span></button>').join('');
    const bar = total > 0
      ? '<div class="cs-mix" role="img" aria-label="티켓 상태 구성">' +
          GROUPS.filter(g => mix[g] > 0).map(g => '<i class="st-' + g + '" style="flex:' + mix[g] + '" title="' + LABEL[g] + ' ' + num(mix[g]) + '"></i>').join('') +
        '</div><div class="cs-mix-l">' + GROUPS.filter(g => mix[g] > 0).map(g => '<span class="st-key st-' + g + '">' + shapeHtml(g) + LABEL[g] + ' ' + num(mix[g]) + '</span>').join('') + '</div>'
      : '';
    const hidden = Number(n.hiddenDone) || 0;
    const recentDocs = Array.isArray(n.recentDocs) ? n.recentDocs : [];
    const openList = Array.isArray(n.openList) ? n.openList : [];
    return '<div class="reader-head"><div class="meta">' +
        '<span class="topic-chip" style="' + ctx.topicVar(n.group) + '"><span class="dot"></span>묶음</span>' +
        '<span class="meta-sep">·</span><span>' + esc(SRC_LABEL[n.docKind] || '폴더') + '</span></div>' +
        '<div class="reader-actions"><button class="icon-btn sm" type="button" data-act="close-reader" title="리더 닫기 · ⌘\\" aria-label="닫기">' + ctx.icon('x') + '</button></div></div>' +
      '<h1 class="reader-title">' + esc(n.label) + '</h1>' +
      (n.fullLabel && n.fullLabel !== n.label ? '<div class="reader-path">' + ctx.icon('folder') + '<span title="' + esc(n.fullLabel) + '">' + esc(n.fullLabel) + '</span></div>' : '') +
      '<div class="cs-stats">' + stat(n.count, '문서') + stat(n.openTickets, '열린 티켓', n.openTickets ? 'is-open' : '') + stat(n.recent, '최근 7일 수정') + '</div>' +
      bar +
      (hidden > 0 ? '<p class="cs-note">끝난 티켓 ' + num(hidden) + '개는 숨겨져 있어요 · 그래프 아래 버튼으로 볼 수 있어요</p>' : '') +
      '<button class="btn primary cs-expand" type="button" data-act="cluster-expand">' + ctx.icon('expand') + '<span>펼치기</span><kbd>↵</kbd></button>' +
      (recentDocs.length ? '<section class="rel"><h2 class="rel-head">최근 문서 <span class="cnt">' + recentDocs.length + '</span></h2>' + rows(recentDocs, false) + '</section>' : '') +
      (openList.length ? '<section class="rel"><h2 class="rel-head">열린 티켓 <span class="cnt">' + num(n.openTickets) + '</span></h2>' + rows(openList, true) + '</section>' : '') +
      (!recentDocs.length && !openList.length ? '<p class="cs-note">보여 줄 문서가 없어요</p>' : '');
  }

  // v0.7 E: 요약 노드("완료 120")를 누르면 리더에 보이는 "끝난 티켓 목록". 최근 순, 줄을 누르면 그 티켓을 연다.
  function doneListHtml(n, ctx) {
    const esc = ctx.esc;
    const items = Array.isArray(n.items) ? n.items : [];
    const total = Number(n.itemsTotal || n.count) || items.length;
    const rows = items.map(d =>
      '<button class="rel-row cs-row" type="button" data-sdoc="' + esc(d.id) + '" title="누르면 이 티켓을 열어요 · 돌아오기 ⌘[">' +
      '<span class="t">' + esc(d.title) + '</span>' + chipHtml(d, esc) +
      '<span class="why" title="' + esc(d.statusChanged ? '완료·상태 변경' : '갱신') + '">' + esc(ctx.relDate(d.statusChanged || d.updated)) + '</span></button>').join('');
    return '<div class="reader-head"><div class="meta">' +
        '<span class="topic-chip st-' + esc(n.statusGroup) + '">' + shapeHtml(n.statusGroup) + '끝난 티켓</span></div>' +
        '<div class="reader-actions"><button class="icon-btn sm" type="button" data-act="close-reader" title="리더 닫기 · ⌘\\" aria-label="닫기">' + ctx.icon('x') + '</button></div></div>' +
      '<h1 class="reader-title">' + esc(statusLabel(n.statusGroup) || '끝난') + ' ' + num(total) + '개</h1>' +
      '<p class="cs-note">그래프에는 가장 최근에 바뀐 끝난 티켓만 그려요. 나머지 ' + num(total) + '개를 최근 순으로 모았어요.</p>' +
      '<section class="rel done-list">' + rows + '</section>' +
      (total > items.length ? '<p class="list-trunc">' + num(total) + '개 중 ' + num(items.length) + '개까지 보여요 · 더 오래된 티켓은 검색으로 찾아 보세요</p>' : '');
  }

  // v0.7 E: 목록이 잘렸을 때 결과 목록 끝 안내 한 줄. t = {shown, total|null}
  function truncNoteHtml(t, isSearch) {
    if (!t || !t.shown) return '';
    const head = t.total ? num(t.total) + '개 중 ' + num(t.shown) + '개까지 보여요' : num(t.shown) + '개까지 보여요 · 더 있어요';
    const tail = isSearch ? ' · 검색어를 더 좁혀 보세요' : ' · 최근 순이에요';
    return '<div class="list-trunc" role="note">' + head + tail + '</div>';
  }

  // 지도 첫 진입 리더: 읽는 법 + 최근 7일 가장 활발한 묶음 3개. nodes = 화면의 묶음 노드들.
  function introHtml(nodes, total, ctx) {
    const esc = ctx.esc;
    const active = (nodes || []).filter(n => n.kind === 'cluster' && n.recent > 0 && n.emphasis !== 'context')
      .sort((a, b) => b.recent - a.recent || b.count - a.count).slice(0, 3);
    const rows = active.map(n =>
      '<button class="rel-row cs-row" type="button" data-ccluster="' + esc(n.id) + '" title="클릭: 묶음 요약">' +
      '<span class="dot" aria-hidden="true" style="' + ctx.topicVar(n.group) + '"></span><span class="t">' + esc(n.label) + '</span>' +
      '<span class="why">최근 7일 ' + num(n.recent) + '개 수정</span></button>').join('');
    return '<div class="reader-head"><div class="meta"><span class="topic-chip"><span class="dot"></span>지도 안내</span></div>' +
        '<div class="reader-actions"><button class="icon-btn sm" type="button" data-act="close-reader" title="리더 닫기 · ⌘\\" aria-label="닫기">' + ctx.icon('x') + '</button></div></div>' +
      '<h1 class="reader-title">묶음 지도</h1>' +
      '<p class="cs-note">' + (total ? '문서 ' + num(total) + '개를 폴더·프로젝트·스페이스 단위의 묶음으로 모았어요.' : '문서를 폴더·프로젝트·스페이스 단위의 묶음으로 모았어요.') + '</p>' +
      '<ul class="cs-guide">' +
        '<li><b class="cs-g-num">104</b><span>버블 안 숫자 = 묶음의 문서 수</span></li>' +
        '<li><b class="cs-g-badge">3</b><span>파란 배지 = 열린 티켓 수</span></li>' +
        '<li><b class="cs-g-glow"></b><span>버블의 빛 = 최근 7일 안에 고친 문서가 있어요</span></li>' +
        '<li><b class="cs-g-pill">' + shapeHtml('done') + '완료 120</b><span>알약 = 접어 둔 끝난 티켓 · 누르면 최근 순 목록</span></li>' +
        '<li><b class="cs-g-key">클릭</b><span>요약을 봐요</span></li>' +
        '<li><b class="cs-g-key">더블클릭</b><span>묶음을 펼쳐요 (<kbd>↵</kbd>)</span></li>' +
      '</ul>' +
      '<p class="cs-note">왼쪽 흐름을 고르면 그 흐름의 묶음이 또렷해져요.</p>' +
      (rows ? '<section class="rel"><h2 class="rel-head">최근 7일 가장 활발한 묶음</h2>' + rows + '</section>' : '');
  }

  window.SynapseCluster = { GROUPS, statusLabel, chipHtml, legendHtml, doneToggleText, summaryHtml, introHtml, shapeHtml, doneListHtml, truncNoteHtml };
})();
