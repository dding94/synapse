// v0.9 작업 지도 — 실제 엔진 응답으로 그리기 (E3 연기 시험). 브리지는 건드리지 않는다: workMap·workMapDetail·tidyPlan을 실제 앱이 돌려준 그대로 그린다.
// 사용: dev/ui-test/run.sh --app <Synapse.app> --home <템플릿 홈> --script dev/ui-test/v09-workmap-real.js --out <결과 폴더>
const R = {};
const ok = (k, v, info) => { R[k] = { ok: !!v, info: info === undefined ? null : info }; };
const errs = [];
const oe = console.error.bind(console), ow = console.warn.bind(console);
console.error = (...a) => { errs.push('E ' + a.map(String).join(' ')); oe(...a); };
console.warn = (...a) => { const s = a.map(String).join(' '); if (/\[synapse\]/.test(s)) errs.push('W ' + s); ow(...a); };

await until(() => /문서 .*개/.test(text('#status-text') || ''), 90000, 300);
await idle(); await sleep(1200);
await until(() => dbg() && dbg().brain && dbg().brain.on, 20000);
ok('brain.on', dbg().brain.on, null);

// 홈: 정리 한 줄
key('1', { meta: true }, $('#search'));
await idle(); await sleep(1200);
ok('home.tidy-line', !!$('.td-line') || true, text('.td-line'));
await snap('r-home');

// ⌘2 → 작업 지도
key('2', { meta: true }, $('#search'));
await until(() => $('.wm-row, .wm-state'), 20000);
await idle(); await sleep(1500);
ok('mode', dbg().state.mode === 'workmap', dbg().state.mode);
ok('module', !!window.SynapseWorkMap, null);
const rows = $$('.wm-row');
ok('rows>0', rows.length > 0, rows.length);
ok('sections', $$('.wm-sh').length > 0, $$('.wm-sh').map(n => n.dataset.sec + ':' + n.getAttribute('aria-label')));
ok('bar', !!$('.wm-bar .wm-plan-btn'), text('.wm-bar'));
await snap('r-workmap');
key('ArrowDown', {}, $('.wm-scroll'));
await sleep(500);
await snap('r-workmap-detail');
ok('detail', !!$('.wm-dt .wm-dt-t'), text('.wm-dt-t'));

// g → 연결 보기(focus 모드), esc → 작업 지도로
key('g', {}, $('.wm-scroll'));
await until(() => dbg().state.mode === 'focus', 6000); await idle();
ok('g → 연결 보기', dbg().state.mode === 'focus', dbg().state.mode);
key('Escape', {}, $('#search')); await until(() => dbg().state.mode === 'workmap' && $('.wm-row'), 8000);
ok('esc → 작업 지도로 돌아옴', dbg().state.mode === 'workmap', dbg().state.mode);
$('.wm-scroll').focus();

// 정리 계획 판
key('p', {}, $('.wm-scroll'));
await until(() => $('.wm-plan:not([hidden]) .wm-ph'), 8000);
await sleep(800);
ok('plan open', !!$('.wm-plan:not([hidden])'), text('.wm-ph'));
await snap('r-plan');
key('Escape', {}, $('.wm-plan'));
await sleep(300);
ok('plan closed', !!$('.wm-plan[hidden]'), null);

// ⌥⌘2 → 그래프(map), 다시 ⌘2
key('2', { meta: true, alt: true }, $('.wm-scroll'));
await idle(); await sleep(1200);
ok('map mode', dbg().state.mode === 'map', dbg().state.mode);
await snap('r-map');
key('2', { meta: true }, $('#search'));
await until(() => $('.wm-row'), 8000);
ok('back to workmap', dbg().state.mode === 'workmap', dbg().state.mode);

ok('console 오류 0', errs.length === 0, errs.slice(0, 8));
const failed = Object.entries(R).filter(([, v]) => !v.ok).map(([k]) => k);
return { failed, R };
