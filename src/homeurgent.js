// Synapse v0.7 B — 홈 "급한 것" 블록: 업무/개인 거르기 칩 · 프로젝트 칩 · 3줄 + "N개 더 보기" · 줄마다 업무/개인 표시.
// home.js의 build()가 급한 것 자리에서 build(data, ui, k)를 부르고, app.js가 data-hact 동작을 act()로 넘긴다.
// 거르기 값(전체·업무·개인)은 사서 설정 homeUrgentScope에 저장하고, 프로젝트 칩·더 보기는 저장하지 않는 일시 상태(ui)다.
(function () {
  'use strict';

  const LABEL = { work: '업무', personal: '개인' };
  const SHOW = 3;          // 처음 보이는 줄 수
  const MAX_PROJECT = 5;   // 프로젝트 칩 수 (넘치면 "그 밖")
  const REST = '__rest';

  const scopeOf = it => (it && it.scope === 'work' ? 'work' : 'personal');
  const hasScope = it => !!it && (it.scope === 'work' || it.scope === 'personal');
  const projectKey = it => String((it && (it.scopeKey || it.project)) || '');
  // 바꾸는 단위: 실제 프로젝트면 "‘이름’ 프로젝트를", 맨 윗 폴더(의사 프로젝트)면 "‘_Inbox’ 폴더의 할 일을"
  const isReal = it => !it || it.scopeReal !== false;
  function unitLabel(name, real) { return real ? '‘' + name + '’ 프로젝트를' : '‘' + name + '’ 폴더의 할 일을'; }

  // 줄 안의 작은 업무/개인 표시. 누르면 그 프로젝트를 반대로 바꾼다.
  function mark(it, esc) {
    if (!hasScope(it)) return '';
    const key = projectKey(it), cur = scopeOf(it), to = cur === 'work' ? 'personal' : 'work';
    if (!key) return '<span class="hu-tag" data-scope="' + cur + '">' + LABEL[cur] + '</span>';
    const real = isReal(it), label = real ? (it.projectLabel || key) : key;
    return '<button class="hu-tag" type="button" data-scope="' + cur + '" data-hact="urgent-flip" data-project="' + esc(key) + '" data-label="' + esc(label) + '" data-real="' + (real ? '1' : '0') +
      '" data-to="' + to + '" aria-label="' + esc(LABEL[cur] + ' · 누르면 ' + (real ? '이 프로젝트' : '이 폴더') + ' 전체를 ' + LABEL[to] + '로 바꿔요') + '" title="누르면 ' + (real ? '이 프로젝트' : '이 폴더') + ' 전체를 ' + LABEL[to] + '로 바꿔요 · ' + esc(label) + '">' + LABEL[cur] + '</button>';
  }

  // k = { esc, icon, row, push, order, sel, rowId, hasChips } (home.js build 안에서 넘긴다). 줄이 없으면 ''.
  function build(data, ui, k) {
    const all = (data.urgent || []).filter(k.hasChips);
    if (!all.length) return '';
    const esc = k.esc;
    const f = data.urgentFilter;
    const canFilter = !!f && all.some(hasScope);     // 예시 자료·옛 응답은 거르기 없이 예전처럼
    const scope = canFilter && (f.scope === 'work' || f.scope === 'personal') ? f.scope : 'all';
    const cnt = { work: all.filter(it => scopeOf(it) === 'work').length, personal: all.filter(it => scopeOf(it) === 'personal').length };
    // 업무 먼저 (같은 묶음 안은 엔진이 준 순서 그대로)
    const sorted = canFilter ? all.filter(it => scopeOf(it) === 'work').concat(all.filter(it => scopeOf(it) === 'personal')) : all;
    const inScope = scope === 'all' ? sorted : sorted.filter(it => scopeOf(it) === scope);

    // 프로젝트 칩: 거르기 값 안의 프로젝트가 2개 이상일 때만
    const groups = [];
    for (const it of inScope) {
      const key = projectKey(it);
      if (!key) continue;
      let g = groups.find(x => x.key === key);
      if (!g) { g = { key, label: it.projectLabel || key, n: 0 }; groups.push(g); }
      g.n++;
    }
    groups.sort((a, b) => b.n - a.n);
    const showProjects = canFilter && groups.length >= 2;
    const top = groups.slice(0, MAX_PROJECT), restN = groups.slice(MAX_PROJECT).reduce((s, g) => s + g.n, 0);
    let proj = ui.urgentProject || null;
    if (proj && !(showProjects && (proj === REST ? restN > 0 : groups.some(g => g.key === proj)))) proj = null;
    const restKeys = new Set(groups.slice(MAX_PROJECT).map(g => g.key));
    const shown = !proj ? inScope : inScope.filter(it => (proj === REST ? restKeys.has(projectKey(it)) : projectKey(it) === proj));

    const chip = (key, act, data, text, on, extra, label) => {
      const i = k.push(key, null, 'chip');
      k.order[i].act = act; k.order[i].data = data;
      const attrs = Object.keys(data).map(n => ' data-' + n + '="' + esc(data[n]) + '"').join('');
      return '<button class="hu-chip' + (on ? ' is-on' : '') + '" type="button" role="option" id="' + k.rowId(i) + '" data-hkey="' + esc(key) + '" data-hact="' + act + '"' + attrs +
        ' aria-selected="' + (k.sel === key) + '"' + (on ? ' aria-current="true"' : '') + (label ? ' aria-label="' + esc(label + (on ? ' · 고름' : ' 보기')) + '"' : '') + '>' + text + (extra || '') + '</button>';
    };
    const num = n => ' <span class="hu-n">' + esc(n) + '</span>';

    let head = '<div class="sec-head h-head hu-head"><span class="hu-title">급한 것 <span class="cnt">' + inScope.length + '</span></span>';
    if (canFilter) {
      head += '<span class="hu-seg" role="group" aria-label="급한 것 거르기">' +
        chip('uf:all', 'urgent-scope', { scope: 'all' }, '전체' + num(all.length), scope === 'all', '', '급한 것 전체 ' + all.length + '개') +
        chip('uf:work', 'urgent-scope', { scope: 'work' }, '업무' + num(cnt.work), scope === 'work', '', '업무 ' + cnt.work + '개') +
        chip('uf:personal', 'urgent-scope', { scope: 'personal' }, '개인' + num(cnt.personal), scope === 'personal', '', '개인 ' + cnt.personal + '개') + '</span>';
    }
    head += '</div>';

    let projects = '';
    if (showProjects) {
      projects = '<div class="hu-projects" role="group" aria-label="프로젝트">' +
        top.map(g => chip('up:' + g.key, 'urgent-project', { project: g.key }, esc(g.label) + num(g.n), proj === g.key, '', g.label + ' ' + g.n + '개')).join('') +
        (restN > 0 ? chip('up:' + REST, 'urgent-project', { project: REST }, '그 밖' + num(restN), proj === REST, '', '그 밖 ' + restN + '개') : '') + '</div>';
    }

    let body = '';
    if (!shown.length) {
      const other = scope === 'work' ? 'personal' : 'work';
      body = canFilter && cnt[other] > 0 && scope !== 'all'
        ? chip('ue:other', 'urgent-scope', { scope: other }, esc(LABEL[scope] + ' 쪽 급한 것은 없어요') + ' <span class="h-sep">·</span> ' + esc(LABEL[other] + ' ' + cnt[other]), false, '<kbd>↵</kbd>').replace('class="hu-chip', 'class="hu-empty hu-chip')
        : '';
    } else {
      const open = !!ui.urgentMore;
      const rows = open ? shown : shown.slice(0, SHOW);
      body = rows.map(it => k.row(it, k.push(it.id, it, 'urgent'), k.sel, 'urgent')).join('');
      if (shown.length > SHOW) {
        body += '<div class="hu-more">' + chip('um:more', 'urgent-more', {}, open ? '접기' : esc(shown.length - SHOW) + '개 더 보기', false, '', open ? '급한 것 접기' : '급한 것 ' + (shown.length - SHOW) + '개 더 보기') + '</div>';
      }
    }
    return '<div class="h-group is-urgent" role="group" aria-label="급한 것">' + head + projects + body + '</div>';
  }

  // 칩·표시를 눌렀을 때. host = { ui, data(), call, toast, undoToast, redraw, refresh } (app.js가 넘긴다)
  function act(name, node, host) {
    const d = node.dataset || {};
    const ui = host.ui, data = host.data() || {};
    if (name === 'urgent-scope') {
      const value = d.scope === 'work' || d.scope === 'personal' ? d.scope : 'all';
      if (data.urgentFilter) data.urgentFilter.scope = value;
      ui.urgentProject = null; ui.urgentMore = false;
      host.redraw(`uf:${value}`);
      host.call('setBrainSetting', { key: 'homeUrgentScope', value }).then(r => {
        if (!r || r.ok === false) host.toast((r && r.error) || '거르기를 저장하지 못했어요', 'error');
      });
    } else if (name === 'urgent-project') {
      ui.urgentProject = ui.urgentProject === d.project ? null : d.project;
      ui.urgentMore = false;
      host.redraw(ui.urgentProject ? 'up:' + d.project : null);
    } else if (name === 'urgent-more') {
      ui.urgentMore = !ui.urgentMore;
      host.redraw('um:more');
    } else if (name === 'urgent-flip') {
      const project = d.project, to = d.to === 'work' ? 'work' : 'personal', label = d.label || project, real = d.real !== '0';
      // 영향받는 급한 것 수: 지금 홈에 있는 급한 것 중 같은 프로젝트(폴더)에 속한 것
      const hit = (data.urgent || []).filter(it => projectKey(it) === project).length || 1;
      host.call('setProjectScope', { project, scope: to }).then(r => {
        if (!r || r.ok === false) { host.toast((r && r.error) || '바꾸지 못했어요', 'error'); return; }
        const before = r.previous || 'auto';
        host.refresh();
        host.undoToast(unitLabel(label, real) + ' ' + LABEL[to] + '로 볼게요 (급한 것 ' + hit + '개)', () => {
          host.call('setProjectScope', { project, scope: before }).then(() => host.refresh());
        });
      });
    }
  }

  window.SynapseHomeUrgent = Object.freeze({ build, mark, act, SHOW });
})();
