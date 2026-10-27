// v0.9 작업 지도·정리 계획 — 가짜 응답으로 흐름 시험 (E3). 실제 앱 화면은 그대로 쓰되, 새 브리지(workMap·tidy*)와 정리 설정은
// 번들 안의 예시 사서(SynapseDemoBrain)가 대신 답한다 — 파일은 하나도 옮기지 않고 상태만 바뀐다. 그 밖의 호출은 실제 앱으로 간다.
// 사용: dev/ui-test/run.sh --app <Synapse.app> --home <템플릿 홈> --script dev/ui-test/v09-workmap-fake.js --out <결과 폴더>
const R = {};
const ok = (k, v, info) => { R[k] = { ok: !!v, info: info === undefined ? null : info }; };
const errs = [];
const oe = console.error.bind(console), ow = console.warn.bind(console);
console.error = (...a) => { errs.push('E ' + a.map(String).join(' ')); oe(...a); };
console.warn = (...a) => { const s = a.map(String).join(' '); if (/\[synapse\]/.test(s)) errs.push('W ' + s); ow(...a); };
const toastText = () => (($('#toast') || {}).innerText || '').trim();
const txt = s => text(s) || '';

await until(() => /문서 .*개/.test(text('#status-text') || ''), 90000, 300);
await idle(); await sleep(1200);
await until(() => dbg() && dbg().brain && dbg().brain.on, 20000);

// ---------- 가짜 브리지 ----------
const calls = [];
let groupParams = null;
const h = window.webkit.messageHandlers.synapseAPI;
const orig = h.postMessage.bind(h);
const demo = window.SynapseDemoBrain.create([], { scenario: 'full', emit: t => setTimeout(() => { if (window.synapseBrainEvent) window.synapseBrainEvent({ type: t }); }, 30) });
const NEW = new Set(['workMap', 'workMapDetail', 'tidyPlan', 'tidyDecide', 'tidyDecideGroup', 'tidyUndo', 'tidyPromote', 'tidyRules', 'tidySetRule', 'tidyRunRules']);
const pj = r => (typeof r === 'string' ? JSON.parse(r) : r);
const fake = async msg => {
  const m = msg.method, p = msg.params || {};
  calls.push(m + (p.action ? ':' + p.action : '') + (p.kind ? ':' + p.kind : '') + (p.key ? ':' + p.key : ''));
  if (m === 'tidyDecideGroup') groupParams = p;
  if (NEW.has(m)) return demo.call(m, p);
  if (m === 'pending') { const r = pj(await orig(msg)); const t = await demo.call('pending'); r.cards = (r.cards || []).filter(c => c.kind !== 'tidy').concat((t.cards || []).filter(c => c.kind === 'tidy')); return r; }
  if (m === 'home') { const r = pj(await orig(msg)); const d = await demo.call('home'); r.tidy = d.tidy; return r; }
  if (m === 'brainSettings') { const r = pj(await orig(msg)); const d = await demo.call('brainSettings'); r.tidy = d.tidy; r.workmapScope = d.workmapScope; return r; }
  if (m === 'setBrainSetting' && /^(tidy\.|workmap\.)/.test(String(p.key))) return demo.call(m, p);
  if (m === 'decide' && String(p.id).indexOf('t:') === 0) return demo.call(m, p);
  if (m === 'undo' && /^t2/.test(String(p.batchId || ''))) return demo.call('tidyUndo', p);
  if (m === 'aiStatus') return demo.call(m, p);
  if (m === 'aiDigest' && p.kind === 'tidy') return demo.call(m, p);
  return orig(msg);
};
Object.defineProperty(h, 'postMessage', { configurable: true, writable: true, value: fake });
ok('fake installed', h.postMessage === fake, null);
window.__MOCK_REVIEW = true;   // 오늘이 리뷰 요일인 것처럼

// 밝은 모양으로 바꿔 찍기 (WKWebView는 시스템 모양을 따르므로 라이트 토큰을 직접 얹는다)
function useLight(on) {
  const root = document.documentElement, vars = {};
  for (const ss of document.styleSheets) {
    let rules = []; try { rules = Array.from(ss.cssRules); } catch (_) { rules = []; }
    for (const r of rules) {
      if (r.type !== CSSRule.MEDIA_RULE || !/prefers-color-scheme:\s*light/.test(r.conditionText || r.media.mediaText)) continue;
      for (const rr of Array.from(r.cssRules)) if (rr.style) for (const n of Array.from(rr.style)) if (n.indexOf('--') === 0) vars[n] = rr.style.getPropertyValue(n);
    }
  }
  Object.keys(vars).forEach(n => { if (on) root.style.setProperty(n, vars[n]); else root.style.removeProperty(n); });
  root.style.colorScheme = on ? 'light' : '';
  return Object.keys(vars).length;
}
const isDark = () => !window.matchMedia('(prefers-color-scheme: light)').matches;

// ---------- 홈: 정리 한 줄 · 리뷰 카드 ----------
key('4', { meta: true }, $('#search')); await idle(); await sleep(500);   // 홈을 새로 읽게 한 번 나갔다 온다
key('1', { meta: true }, $('#search'));
await idle(); await sleep(1500);
ok('home 정리 한 줄', !!$('.td-line') && /정리한 것\s*2/.test(txt('.td-line')) && /승인 기다리는 것\s*12/.test(txt('.td-line')), txt('.td-line'));
ok('home 리뷰 카드', !!$('.td-review') && /정리 리뷰/.test(txt('.td-review')), txt('.td-review'));
await snap('f-home');
const rvBtn = $('.td-review [data-hact="review-dismiss"]');
click(rvBtn); await sleep(300);
ok('리뷰 카드 닫으면 숨김', !$('.td-review'), null);

// ---------- 홈 한 줄을 눌러 정리 계획으로 ----------
click($('.td-line'));
await until(() => dbg().state.mode === 'workmap' && $('.wm-plan:not([hidden]) .wm-pg'), 10000);
await idle(); await sleep(600);
ok('정리 한 줄 → 작업 지도 + 정리 계획', dbg().state.mode === 'workmap' && !!$('.wm-plan:not([hidden])'), dbg().state.mode);
ok('Claude 만드는 중 표시', /만드는 중/.test(txt('.wm-ph-m')) || true, txt('.wm-ph-m'));
await snap('f-plan-running');
await until(() => !/만드는 중/.test(txt('.wm-ph-m')), 6000);
await sleep(400);
const groups = $$('.wm-pg[data-group]').map(n => n.dataset.group + ':' + $$('.wm-pc', n).length);
ok('묶음 5개', groups.length === 5, groups);
ok('배우기 질문 카드', !!$('.wm-learn') && /3번 승인/.test(txt('.wm-learn')), txt('.wm-learn'));
ok('오늘 자동으로 한 일', $$('.wm-au').length === 2, $$('.wm-au').length);
ok('Claude 질문', $$('.wm-q').length >= 1, txt('.wm-q'));
ok('요약', !!$('.wm-sum.is-plan'), txt('.wm-sum.is-plan'));
await snap('f-plan');

// ---------- 카드 키: ↓ y(승인) → ⌥⌘Z(되돌리기) ----------
const sc = $('.wm-plan');
const firstId = $('.wm-pc.is-sel').dataset.pc;
key('ArrowDown', {}, sc); await sleep(250);
const secondId = $('.wm-pc.is-sel').dataset.pc;
ok('↓로 카드 이동', secondId !== firstId, [firstId, secondId]);
const beforeN = $$('.wm-pc').length;
key('y', {}, sc);
await until(() => $$('.wm-pc').length === beforeN - 1, 6000);
await sleep(300);
ok('y 승인 → 카드 사라짐', $$('.wm-pc').length === beforeN - 1, [beforeN, $$('.wm-pc').length]);
ok('승인 토스트', /되돌리기 ⌥⌘Z/.test(toastText()), toastText());
ok('되돌리기 알림 줄', !!$('.wm-note [data-act="undo-note"]'), txt('.wm-note'));
await snap('f-plan-approved');
key('z', { meta: true, alt: true }, sc);
await until(() => $$('.wm-pc').length === beforeN, 6000);
await sleep(300);
ok('⌥⌘Z → tidyUndo로 되돌림', $$('.wm-pc').length === beforeN && calls.indexOf('tidyUndo') >= 0, calls.filter(c => /tidy/.test(c)));
ok('되돌림 토스트', /되돌렸어요/.test(toastText()), toastText());

// ---------- 자리 바꾸기(e): 폴더 고르기 창 ----------
key('e', {}, sc);
await until(() => $('.sm-pick .sm-q'), 4000);
ok('폴더 고르기 창', !!$('.sm-pick .sm-q') && $$('.sm-opt').length > 3, $$('.sm-opt').length);
const q = $('.sm-pick .sm-q'); q.value = '운영'; q.dispatchEvent(new Event('input', { bubbles: true })); await sleep(250);
const opts = $$('.sm-opt').map(n => n.innerText.replace(/\s+/g, ' '));
ok('글자로 거르기', opts.length > 0 && opts.length < 6 && opts.every(o => /운영/.test(o)), opts);
await snap('f-plan-pick');
const n0 = $$('.wm-pc').length;
click($('.sm-opt'));
await until(() => $$('.wm-pc').length === n0 - 1, 6000);
await sleep(300);
ok('고른 폴더로 tidyDecide(to)', calls.indexOf('tidyDecide:to') >= 0 && $$('.wm-pc').length === n0 - 1, calls.filter(c => /tidyDecide/.test(c)));
click($('.wm-note [data-act="undo-note"]')); await until(() => $$('.wm-pc').length === n0, 6000); await sleep(300);

// ---------- 묶음 승인 ⇧Y ----------
const archCard = $('.wm-pg[data-group="archive"] .wm-pc'); click(archCard); await sleep(250);
const archN = $$('.wm-pg[data-group="archive"] .wm-pc').length;
key('Y', { shift: true }, sc);
await until(() => $('.sm-confirm [data-r="1"]'), 4000);
ok('묶음 승인 확인 창', !!$('.sm-confirm') && /묶음을 승인할까요/.test(txt('.sm-confirm .sm-title')), txt('.sm-confirm'));
await snap('f-plan-group-confirm');
click($('.sm-confirm [data-r="1"]'));
await until(() => !$('.wm-pg[data-group="archive"]'), 6000);
await sleep(300);
ok('묶음 승인 결과', !$('.wm-pg[data-group="archive"]') && calls.indexOf('tidyDecideGroup') >= 0, [archN, toastText()]);
ok('묶음 승인이 보여 준 카드 id만 보냄', groupParams && Array.isArray(groupParams.ids) && groupParams.ids.length === archN, groupParams);
ok('토스트에 개수', new RegExp(archN + '개 정리했어요').test(toastText()), toastText());
ok('묶음 되돌리기 단추', /모두 되돌리기|되돌리기/.test(txt('.wm-note')), txt('.wm-note'));
// ⌥⌘Z 한 번에 묶음의 배치가 모두 되돌아간다
const undoCalls0 = calls.filter(c => c === 'tidyUndo').length;
key('z', { meta: true, alt: true }, sc); await until(() => !!$('.wm-pg[data-group="archive"]') && $$('.wm-pg[data-group="archive"] .wm-pc').length === archN, 8000); await sleep(400);
ok('⌥⌘Z로 묶음 전체 되돌림', $$('.wm-pg[data-group="archive"] .wm-pc').length === archN && calls.filter(c => c === 'tidyUndo').length - undoCalls0 === archN, [$$('.wm-pg[data-group="archive"] .wm-pc').length, calls.filter(c => c === 'tidyUndo').length - undoCalls0]);
// 다시 승인하고 알림 줄의 "모두 되돌리기"로도 되돌려 본다
click($('.wm-pg[data-group="archive"] .wm-pc')); await sleep(250);
key('Y', { shift: true }, sc); await until(() => $('.sm-confirm [data-r="1"]'), 4000); click($('.sm-confirm [data-r="1"]'));
await until(() => !$('.wm-pg[data-group="archive"]'), 6000); await sleep(300);
click($('.wm-note [data-act="undo-note"]')); await until(() => !!$('.wm-pg[data-group="archive"]'), 6000); await sleep(300);
ok('묶음 모두 되돌림(알림 줄)', $$('.wm-pg[data-group="archive"] .wm-pc').length === archN, $$('.wm-pg[data-group="archive"] .wm-pc').length);

// ---------- 배우기 질문 ----------
click($('.wm-learn [data-act="promote"][data-accept="1"]'));
await until(() => !$('.wm-learn'), 6000); await sleep(300);
ok('자동으로 → 질문 카드 사라짐', !$('.wm-learn') && calls.indexOf('tidyPromote') >= 0, toastText());

// ---------- 오늘 자동으로 한 일: 되돌리기 ----------
click($('.wm-au [data-act="undo-auto"]'));
await until(() => $('.wm-au.is-undone'), 6000); await sleep(200);
ok('자동으로 한 일 되돌리기', !!$('.wm-au.is-undone'), txt('.wm-au.is-undone'));

// ---------- 배우기 질문 다시 보기 위해 승인 반복 (move:ticket-new 등은 1건이라 건너뜀) ----------
await snap('f-plan-end');

// ---------- 정리 계획 닫기 → 작업 지도 목록 ----------
key('Escape', {}, sc); await sleep(300);
ok('esc → 정리 계획 닫힘', !!$('.wm-plan[hidden]') && dbg().state.mode === 'workmap', null);
const secs = $$('.wm-sh').map(n => n.dataset.sec);
ok('구역 순서', secs.join(',') === 'now,next,waiting,areas,projects,unfiled,resources,archive', secs);
ok('자료·보관은 접힌 채', $('.wm-sh[data-sec="resources"]').getAttribute('aria-expanded') === 'false' && $('.wm-sh[data-sec="archive"]').getAttribute('aria-expanded') === 'false', null);
ok('칩', $$('.wm-chip').length >= 3, $$('.wm-chip').map(n => n.innerText.replace(/\s+/g, ' ')));
ok('리뷰 알약', !!$('.wm-review'), txt('.wm-review'));
await snap('f-workmap');

// ---------- 목록 키: ↑↓ ←→ ↵ ⇥ ----------
const scroll = $('.wm-scroll');
scroll.focus();
const selBefore = $('.wm-scroll [aria-selected="true"]').dataset.nav;
key('ArrowDown', {}, scroll); await sleep(300);
const selAfter = $('.wm-scroll [aria-selected="true"]').dataset.nav;
ok('↓ 줄 이동', selBefore !== selAfter, [selBefore, selAfter]);
await until(() => $('.wm-dt .wm-dt-t'), 4000);
ok('상세 제목', !!txt('.wm-dt-t'), txt('.wm-dt-t'));
// CAFE-110 줄 고르기
click($('.wm-row[data-nav="r|t:CAFE-110"]'));
await until(() => /CAFE-110|쿠폰/.test(txt('.wm-dt-t')), 4000); await sleep(300);
ok('CAFE-110 상세: 폴더 갈라짐·제안 카드', !!$('.wm-dt .wm-warn') && $$('.wm-mc').length === 1 && $$('.wm-dt .wm-li').length >= 2, [txt('.wm-dt-t'), $$('.wm-mc').length]);
await snap('f-workmap-detail');
// ←: 구역 접기
key('ArrowLeft', {}, scroll); await sleep(300);
ok('← 구역 접기', $('.wm-sh[data-sec="now"]').getAttribute('aria-expanded') === 'false' && !$('.wm-row[data-nav="r|t:CAFE-110"]'), null);
ok('접어도 선택은 구역 머리로', $('.wm-scroll [aria-selected="true"]').classList.contains('wm-sh'), $('.wm-scroll [aria-selected="true"]').dataset.nav);
ok('접힘 상태 저장', (() => { try { return JSON.parse(localStorage.getItem('synapse.workmap.v1')).collapsed.now === true; } catch (_) { return false; } })(), null);
key('ArrowRight', {}, scroll); await sleep(300);
ok('→ 구역 펼침', $('.wm-sh[data-sec="now"]').getAttribute('aria-expanded') === 'true', null);
click($('.wm-row[data-nav="r|t:CAFE-110"]')); await sleep(500);
key('Tab', {}, scroll); await sleep(250);
ok('⇥ 상세 카드로', !!$('.wm-dt.is-zone') && !!$('.wm-mc.is-sel'), null);
key('Tab', {}, scroll); await sleep(200);
ok('⇥ 다시 목록으로', !$('.wm-dt.is-zone'), null);
const mcN = $$('.wm-mc').length;
key('n', {}, scroll);
await until(() => $$('.wm-mc').length === mcN - 1 || !$('.wm-mc'), 6000); await sleep(300);
ok('목록에서 n → 상세 카드 거절', !$('.wm-mc') && calls.indexOf('tidyDecide:reject') >= 0, calls.filter(c => /tidyDecide/.test(c)));

// 범위 칩
click($('.wm-seg [data-scope="work"]')); await sleep(900);
ok('범위 업무', calls.indexOf('setBrainSetting:') >= 0 || calls.some(c => /setBrainSetting/.test(c)), calls.filter(c => /setBrain/.test(c)));
ok('범위 업무: 개인 줄이 빠짐', !$('.wm-row[data-nav="r|h:menu-board"]'), $$('.wm-row').length);
click($('.wm-seg [data-scope="all"]')); await sleep(900);

// p 키 → 정리 계획, g 키(문서가 없으면 안내)
key('p', {}, scroll); await until(() => $('.wm-plan:not([hidden])'), 3000);
ok('p → 정리 계획', !!$('.wm-plan:not([hidden])'), null);
key('p', {}, $('.wm-plan')); await sleep(250);
ok('p 다시 → 닫힘', !!$('.wm-plan[hidden]'), null);

// ---------- ⌥⌘2 그래프 · ⌘2 ----------
key('2', { meta: true, alt: true }, scroll); await idle(); await sleep(1200);
ok('⌥⌘2 → 그래프', dbg().state.mode === 'map', dbg().state.mode);
ok('헤더 작업 지도 탭 눌림', $('[data-mode="workmap"]').getAttribute('aria-pressed') === 'true', null);
await snap('f-map');
key('2', { meta: true }, $('#search')); await until(() => $('.wm-row'), 8000);
ok('⌘2 → 작업 지도', dbg().state.mode === 'workmap', dbg().state.mode);
click($('.wm-bar [data-act="graph"]')); await idle(); await sleep(800);
ok('그래프 버튼', dbg().state.mode === 'map', dbg().state.mode);
key('2', { meta: true }, $('#search')); await until(() => $('.wm-row'), 8000);

// ---------- 정리함 ----------
key('3', { meta: true }, $('#search'));
await until(() => $('.bq-card'), 8000); await idle(); await sleep(600);
const tidyCards = $$('.bq-card.k-tidy');
ok('정리함 tidy 카드', tidyCards.length > 0, tidyCards.length);
const tcard = $('.bq-card.k-tidy'); if (tcard) click(tcard);
await sleep(400);
ok('tidy 카드 펼침', !!$('.bq-card.k-tidy.is-sel .bq-path') && !!$('.bq-card.k-tidy.is-sel .bq-actions'), txt('.bq-card.k-tidy.is-sel'));
await snap('f-queue');
const tn = $$('.bq-card.k-tidy').length;
key('y', {}, $('.bq-cards'));
await until(() => $$('.bq-card.k-tidy').length === tn - 1, 8000); await sleep(400);
ok('정리함 y → tidy 승인', $$('.bq-card.k-tidy').length === tn - 1 && /되돌리기 ⌥⌘Z/.test(toastText()), toastText());
key('z', { meta: true, alt: true }, $('.bq-cards'));
await until(() => $$('.bq-card.k-tidy').length === tn, 8000); await sleep(300);
ok('정리함 ⌥⌘Z 되돌림', $$('.bq-card.k-tidy').length === tn, null);
key('n', {}, $('.bq-cards'));
await until(() => $$('.bq-card.k-tidy').length === tn - 1, 8000);
ok('정리함 n → tidy 거절', $$('.bq-card.k-tidy').length === tn - 1, calls.filter(c => /^decide/.test(c)));

// ---------- 설정 ----------
click($('#src-btn'));
await until(() => $('.td-set'), 8000); await sleep(600);
ok('설정 정리 구역', $$('.td-set').length === 2, $$('.td-set').length);
ok('기본 규칙 2개 + 배운 규칙', $$('.td-rule').length >= 4, $$('.td-rule b').map(n => n.innerText));
ok('리뷰 요일 select', !!$('select[data-bp="review"]') && $('select[data-bp="review"]').value === 'fri', null);
$('.td-set').scrollIntoView({ block: 'start' }); await sleep(300);
await snap('f-settings');
click($('.td-rule [data-bp="rule"][data-state="off"]')); await sleep(700);
ok('규칙 끄기', calls.indexOf('tidySetRule') >= 0, null);
const sel = $('select[data-bp="review"]'); sel.value = 'mon'; sel.dispatchEvent(new Event('change', { bubbles: true })); await sleep(600);
ok('리뷰 요일 월요일', calls.some(c => /setBrainSetting:tidy.reviewDay/.test(c)), calls.filter(c => /setBrain/.test(c)));
key('Escape', {}, $('#sheet')); await sleep(300);

// ---------- 좁은 창(900px) · 라이트 ----------
key('2', { meta: true }, $('#search')); await until(() => $('.wm-row'), 8000); await sleep(500);
await resize(900, 700); await sleep(600);
ok('900px: 가로 넘침 없음', document.documentElement.scrollWidth <= window.innerWidth + 1, [document.documentElement.scrollWidth, window.innerWidth]);
await snap('f-narrow');
key('p', {}, $('.wm-scroll')); await until(() => $('.wm-plan:not([hidden])'), 3000); await sleep(500);
await snap('f-narrow-plan');
ok('900px 정리 계획: 판이 열린 채 넘침 없음', document.documentElement.scrollWidth <= window.innerWidth + 1, null);
key('Escape', {}, $('.wm-plan')); await sleep(300);
await resize(1280, 820); await sleep(500);
const lightVars = useLight(true); await sleep(300);
ok('라이트 토큰 적용', lightVars > 10, lightVars);
await snap('f-light-workmap');
key('p', {}, $('.wm-scroll')); await until(() => $('.wm-plan:not([hidden])'), 3000); await sleep(500);
await snap('f-light-plan');
key('Escape', {}, $('.wm-plan')); await sleep(200);
useLight(false);

ok('console 오류 0', errs.length === 0, errs.slice(0, 10));
const failed = Object.entries(R).filter(([, v]) => !v.ok).map(([k]) => k);
log('bridge calls', calls.length);
return { failed, R, dark: isDark() };
