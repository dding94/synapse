// dev/ui/mock-native.js — 개발 전용 모의 네이티브 브리지 (CONNECT §4 계약).
// window.webkit.messageHandlers.synapseAPI.postMessage({method, params}) → Promise, synapse(창 동작) 기록,
// window.synapseLibraryEvent로 progress/changed/error 이벤트를 흉내 낸다. 문서는 SYNAPSE_DATA를 3개 출처로 나눠 쓴다.
// 시나리오: window.__MOCK_SCENARIO = 'empty' | 'lib' | 'indexing' | 'error' | 'flaky'(처음 status 3번 실패) | 'notice'(볼트 자동 인식 안내) (기본 lib)
// v0.4: getPreferences·setPreference·sourceDetails·updateSource·readRaw·saveRaw(충돌: __mock.touch(id))·mcpStatus·mcpRegister·addMCP
//       (__mock.mcpOutcome = 'success' | 'needSite' | 'cancel' | 'error', __mock.mcpDelay ms) · cancelMCP(대기 중 addMCP → cancelled)
// v0.5: 사서 브리지(home·why·feedback·week·map·pending·decide·decideBundle·undo·aiLog·brainSettings·setBrainSetting·policy·
//       approvePolicy·claudeInstruction·track·runBatch·folders)는 data.js의 SynapseDemoBrain으로 흉내 내고, 바뀌면 synapseBrainEvent를 보낸다.
//       사서 시나리오: window.__MOCK_BRAIN = 'full'(기본) | 'empty' | 'sessions' | 'stopped' | 'queue' | 'week' | 'nobrain'
// v0.8: Claude 연결(aiStatus·aiDigest·aiTask·jiraApply … 와 티켓 예시)도 SynapseDemoBrain이 흉내 낸다. 이벤트는 window.synapseAIEvent(src/ai.js)로 간다.
//       AI 시나리오: window.__MOCK_AI = 'on'(기본: 첫 호출은 running → 1.5초 뒤 정리) | 'ready' | 'off' | 'missing' | 'login' | 'running' | 'rerun' | 'error' | 'errorOld' | 'limit' | 'manual' | 'stale' | 'empty'
//       사서 시나리오 'tickets'(티켓 예시 14개) · 'jira'(티켓 + 정리함에 Jira 카드 2장). 시작 화면: window.__MOCK_START = 'week' | 'tickets' | 'queue' | 'home' …
//       손으로 바꾸기: __mock.ai('off') → 시나리오를 바꾸고 status 이벤트를 보낸다 · window.__MOCK_JIRA_FAIL = true → 다음 jiraApply 한 번이 실패한다
(function () {
  'use strict';
  const SC = window.__MOCK_SCENARIO || (location.hash.slice(1) || 'lib');
  const log = window.__mockLog = [];
  let statusFails = SC === 'flaky' ? 3 : 0;
  const now = Date.now();
  const iso = ms => new Date(ms).toISOString();
  const SOURCES = {
    vault: { id: 'vault', kind: 'obsidian', name: '개인 볼트', detail: '~/Documents/Obsidian/개인 볼트' },
    docs: { id: 'docs', kind: 'folder', name: '업무 문서', detail: '~/Documents/업무문서' },
    atl: { id: 'atl', kind: 'atlassian', name: 'your-team', detail: 'your-team.atlassian.net · ENG, PAY' },
    mcp: { id: 'mcp', kind: 'mcp', name: 'your-team', detail: 'Atlassian MCP · your-team.atlassian.net' },
  };
  // 문서 → [출처, 묶음, 종류]
  const PLACE = {
    f1: ['vault', '1-Projects', 'md'], f2: ['vault', '1-Projects', 'md'], f3: ['docs', '회의록', 'docx'], f4: ['atl', 'ENG', 'confluence'], f5: ['atl', 'PAY', 'jira'],
    s1: ['vault', '3-Resources', 'md'], s2: ['vault', '3-Resources', 'md'], s3: ['docs', '보고서', 'pdf'], s4: ['atl', 'ENG', 'confluence'], s5: ['vault', '2-Areas', 'md'],
    p1: ['docs', '회의록', 'hwpx'], p2: ['docs', '보고서', 'pdf'], p3: ['atl', 'PAY', 'jira'], p4: ['vault', '2-Areas', 'md'], p5: ['docs', '회의록', 'txt'],
    i1: ['vault', '4-Archive', 'md'], i2: ['vault', '1-Projects', 'md'], i3: ['docs', '업무 문서', 'rtf'], i4: ['atl', 'PAY', 'jira'], i5: ['vault', '2-Areas', 'md'],
  };
  const KIND_LABEL = { md: '마크다운', pdf: 'PDF', docx: '워드', txt: '텍스트', hwpx: '한글', rtf: 'RTF', confluence: 'Confluence', jira: 'Jira' };
  const EXT = { md: '.md', pdf: '.pdf', docx: '.docx', txt: '.txt', hwpx: '.hwpx', rtf: '.rtf' };
  let jiraNo = 140;

  // ---- v0.4 (docs/V04.md) -------------------------------------------------------------
  // 설정 · 형식/제외 폴더 · 원문 편집(fingerprint·충돌) · MCP 등록 · Atlassian MCP 로그인(사이트 고르기·취소)
  const prefs = { autoHide: false };
  const DETAILS = {
    vault: { kinds: [['md', 1840], ['pdf', 120], ['txt', 949], ['html', 696], ['docx', 14]], include: ['md', 'pdf'],
      folders: [['1-Projects', 420], ['2-Areas', 380], ['3-Resources', 1290], ['3-Resources/Clippings', 696], ['3-Resources/Books', 210], ['4-Archive', 640], ['_templates', 12], ['_Inbox', 37]] },
    docs: { kinds: [['md', 12], ['pdf', 88], ['docx', 41], ['hwpx', 9], ['txt', 23], ['rtf', 2]], include: ['md', 'pdf', 'docx', 'hwpx', 'txt', 'rtf'],
      folders: [['회의록', 64], ['보고서', 71], ['보고서/2025', 40], ['업무 문서', 40]] },
  };
  const config = {}; // id → { includeKinds, excludeFolders }
  function sourceDetails(id) {
    const d = DETAILS[id];
    if (!d) throw new Error('이 자료는 형식을 고를 수 없어요.');
    const c = config[id] || {};
    const inc = new Set(c.includeKinds || d.include), exc = new Set(c.excludeFolders || []);
    return { kinds: d.kinds.map(([e, n]) => [e, n, inc.has(e)]), folders: d.folders.map(([f, n]) => [f, n, exc.has(f)]) };
  }
  // 문서 본문 덮어쓰기(저장 흉내) · fingerprint · 편집 불가 이유
  const rawText = new Map(), fps = new Map();
  let fpNo = 1;
  const fpOf = id => { if (!fps.has(id)) fps.set(id, 'fp-' + id + '-' + (fpNo++)); return fps.get(id); };
  function rawFor(id) {
    const d = docsFor().find(x => x.id === id);
    if (!d) throw new Error('문서를 찾을 수 없어요.');
    const src = SOURCES[d.source];
    if (src.kind === 'atlassian' || src.kind === 'mcp') return { text: '', fingerprint: '', editable: false, reason: '원격 문서는 원본에서 고쳐 주세요' };
    if (d.fileKind === 'pdf') return { text: '', fingerprint: '', editable: false, reason: 'PDF는 편집할 수 없어요' };
    if (id === 'p5') return { text: '', fingerprint: '', editable: false, reason: 'UTF-8이 아닌 파일은 편집할 수 없어요' };
    if (!['md', 'txt'].includes(d.fileKind)) return { text: '', fingerprint: '', editable: false, reason: '이 형식은 편집할 수 없어요' };
    const text = rawText.has(id) ? rawText.get(id)
      : (d.fileKind === 'md' ? '---\ntags: [' + d.tags.join(', ') + ']\n---\n\n' : '') + d.body.join('\n\n') + '\n';
    return { text: text.replace(/\n/g, '\r\n'), fingerprint: fpOf(id), editable: true }; // CRLF 파일 흉내(화면은 \n으로 다룬다)
  }
  function bodyFromRaw(text) {
    return text.replace(/\r\n?/g, '\n').replace(/^---\n[\s\S]*?\n---\n+/, '').split(/\n[ \t]*\n+/).map(x => x.trim()).filter(Boolean);
  }
  const mcpReg = { claudeCode: 'unavailable', codex: 'registered', claudeDesktop: 'absent' };
  const SERVER_PATH = '/Applications/Synapse.app/Contents/MacOS/synapse-mcp';
  const SITES = [{ name: 'your-team', url: 'https://your-team.atlassian.net' }, { name: 'acme-pay', url: 'https://acme-pay.atlassian.net' }];
  let mcpLogin = null; // 진행 중인 로그인 흉내

  const lib = { sources: [], busy: new Map() }; // busy: id → { done, total, timer }
  function initSources() {
    const t = (min) => iso(now - min * 60000);
    const mk = (s, extra) => Object.assign({ enabled: true, state: 'idle', docCount: 0, lastIndexed: t(3), progress: null, error: null }, s, extra || {});
    if (SC === 'empty') return [];
    const list = [mk(SOURCES.vault, { lastIndexed: t(3) }), mk(SOURCES.docs, { lastIndexed: t(52), failed: 3 }), mk(SOURCES.atl, { lastIndexed: t(60 * 26) })];
    if (SC === 'error') Object.assign(list[2], { state: 'error', error: '토큰이 맞지 않아요. 이메일과 토큰을 확인해 주세요.' });
    if (SC === 'notice') list[0].notice = '옵시디언 볼트로 인식했어요. 노트(md)와 PDF만 색인해요 — 형식은 자료 설정에서 바꿀 수 있어요.';
    return list;
  }
  lib.sources = initSources();

  function docsFor() {
    const base = (window.SYNAPSE_DATA && window.SYNAPSE_DATA.docs) || [];
    // 첫 색인이 끝나기 전(lastIndexed 없음)의 출처는 아직 문서가 없다
    const on = new Set(lib.sources.filter(s => s.enabled && s.lastIndexed).map(s => s.id));
    const out = [];
    base.forEach(d0 => {
      const pl = PLACE[d0.id];
      if (!pl) return;
      const [sid0, group, kind] = pl;
      const sid = sid0 === 'atl' && !on.has('atl') && on.has('mcp') ? 'mcp' : sid0, src = SOURCES[sid];
      if (!on.has(sid)) return;
      const cfg = config[sid];
      if (cfg && cfg.includeKinds && !cfg.includeKinds.includes(kind)) return;
      if (cfg && (cfg.excludeFolders || []).some(f => group === f || group.startsWith(f + '/'))) return;
      const d = JSON.parse(JSON.stringify(d0));
      d.topic = group; d.fileKind = kind; d.kindLabel = KIND_LABEL[kind]; d.kind = KIND_LABEL[kind];
      d.source = sid; d.sourceKind = src.kind; d.sourceName = src.name;
      d.updated = d0.updated + 'T09:' + String(10 + (d0.id.charCodeAt(1) % 40)).padStart(2, '0') + ':00+09:00';
      if (kind === 'jira') { const key = 'PAY-' + (jiraNo + (d0.id.charCodeAt(1) % 9)); d.title = key + ' · ' + d0.title; d.short = d.title.length > 14 ? d.title.slice(0, 13) + '…' : d.title; d.path = 'Jira · PAY / ' + key; }
      else if (kind === 'confluence') d.path = 'Confluence · ENG / 설계 / ' + d0.title;
      else d.path = src.name + ' / ' + (group === src.name ? '' : group + ' / ') + d0.title + EXT[kind];
      d.open = { label: src.kind === 'obsidian' ? '옵시디언에서 열기' : kind === 'jira' ? 'Jira에서 열기' : kind === 'confluence' ? 'Confluence에서 열기' : '기본 앱으로 열기', canReveal: src.kind !== 'atlassian' };
      if (d0.id === 'f1') {
        d.body = ['# 정산 흐름', d0.body[0], '## 확인할 것\n- 결제 금액과 취소 금액\n- 수수료 차감\n- 입금 시점', d0.body[1] + '\n' + d0.body[2]];
        d.unresolved = ['없는 노트', '정산 용어집'];
      }
      if (rawText.has(d0.id)) d.body = bodyFromRaw(rawText.get(d0.id));
      if (d0.id === 's3') { const long = []; for (let i = 0; i < 260; i++) long.push((i % 12 === 0 ? '# ' + (i / 12 + 1) + '장 검색 품질 보고\n' : '') + d0.body[i % d0.body.length]); d.body = long; }
      out.push(d);
    });
    return out;
  }
  let demo = null, demoKey = '';
  function engine() {
    const key = lib.sources.map(s => s.id + s.enabled + !!s.lastIndexed).join(',');
    if (!demo || key !== demoKey) {
      const docs = docsFor();
      const topics = {};
      docs.forEach(d => { topics[d.topic] = { label: d.topic }; });
      demo = window.SynapseDemoSource.create({ topics, synonyms: window.SYNAPSE_DATA.synonyms, docs });
      demoKey = key;
      lib.sources.forEach(s => { s.docCount = docs.filter(d => d.source === s.id).length; });
    }
    return demo;
  }
  function status() {
    if (window.SynapseDemoSource) engine();
    const sources = lib.sources.map(s => Object.assign({}, s, s.state !== 'idle' && s.state !== 'error' && lib.busy.has(s.id) ? { progress: { done: lib.busy.get(s.id).done, total: lib.busy.get(s.id).total, phase: lib.busy.get(s.id).phase } } : {}));
    return { sources, docCount: sources.filter(s => s.enabled).reduce((n, s) => n + s.docCount, 0), indexing: sources.some(s => s.state === 'indexing' || s.state === 'syncing') };
  }
  const emit = evt => { log.push(['event', evt.type]); if (window.synapseLibraryEvent) window.synapseLibraryEvent(evt); };
  // 색인 흉내: 200ms마다 progress, 끝나면 changed
  function runIndex(id, total, opts = {}) {
    const s = lib.sources.find(x => x.id === id);
    if (!s) return;
    const prev = lib.busy.get(id); if (prev) clearInterval(prev.timer);
    const remote = s.kind === 'atlassian' || s.kind === 'mcp';
    s.state = remote ? 'syncing' : 'indexing'; s.error = null;
    const job = { done: 0, total: 0, phase: 'scan', timer: 0 };
    lib.busy.set(id, job);
    let tick = 0;
    job.timer = setInterval(() => {
      tick++;
      if (tick === 2) { job.total = opts.unknownTotal ? 0 : total; job.phase = remote ? 'sync' : 'extract'; }
      if (job.total) job.done = Math.min(job.total, job.done + Math.ceil(total / (opts.steps || 12)));
      else if (opts.unknownTotal && tick > 1) job.done += 7;
      emit({ type: 'progress', sourceId: id, done: job.done, total: job.total, phase: job.phase });
      if (job.total && job.done >= job.total && !opts.loop) {
        clearInterval(job.timer); lib.busy.delete(id);
        s.state = 'idle'; s.lastIndexed = iso(Date.now()); s.progress = null;
        emit({ type: 'changed', reason: 'indexed' });
      } else if (opts.loop && job.done >= job.total) job.done = 0;
    }, 200);
  }
  if (SC === 'indexing') {
    lib.sources[1].state = 'indexing'; lib.sources[2].state = 'syncing';
    lib.busy.set('docs', { done: 340, total: 1200, phase: 'extract' }); lib.busy.set('atl', { done: 0, total: 0, phase: 'sync' });
    setTimeout(() => { runIndex('docs', 1200, { loop: true, steps: 40 }); runIndex('atl', 400, { loop: true, steps: 30, unknownTotal: true }); }, 600);
  }
  if (SC === 'error') setTimeout(() => emit({ type: 'error', sourceId: 'atl', message: '토큰이 맞지 않아요. 이메일과 토큰을 확인해 주세요.' }), 900);

  const wait = ms => new Promise(r => setTimeout(r, ms));
  const view = params => {
    // v0.6: 묶음 지도(overview·cluster)는 예시 자료 엔진이 모른다 → 예전 전체 그래프로
    if (params && (params.mode === 'overview' || params.mode === 'cluster')) params = Object.assign({}, params, { mode: 'global' });
    return engine().view(params).then(v => {
      const hidden = new Set(params.hiddenGroups || []);
      v.legend = v.legend.filter(([g, n]) => n > 0 || hidden.has(g));
      return v;
    });
  };
  // ---- v0.5 사서 ----------------------------------------------------------------------
  const BRAIN_SC = window.__MOCK_BRAIN || 'full';
  const BRAIN_METHODS = new Set(['home', 'why', 'feedback', 'week', 'map', 'pending', 'decide', 'decideBundle', 'undo', 'aiLog', 'brainSettings',
    'setBrainSetting', 'policy', 'approvePolicy', 'claudeInstruction', 'track', 'runBatch', 'folders',
    'tickets', 'aiStatus', 'setAISetting', 'aiTest', 'aiDigest', 'aiTask', 'aiCancel', 'aiRuns', 'aiRun', 'jiraPropose', 'jiraApply', 'copyRich']);
  let brain = null;
  const brainEmit = type => { log.push(['brainEvent', type]); setTimeout(() => { if (window.synapseBrainEvent) window.synapseBrainEvent({ type }); }, 40); };
  function brainFor() {
    if (!brain && window.SynapseDemoBrain) brain = window.SynapseDemoBrain.create(docsFor(), { scenario: BRAIN_SC, emit: brainEmit });
    return brain;
  }
  async function api(msg) {
    const { method, params = {} } = msg || {};
    log.push(['api', method, method === 'addAtlassian' ? Object.assign({}, params, { token: '•••' }) : params]);
    switch (method) {
      case 'status': await wait(10); if (statusFails > 0) { statusFails--; throw new Error('엔진을 여는 중이에요.'); } return status();
      case 'view': await wait(15); return view(params);
      case 'document': await wait(40); return engine().document(params.id);
      case 'open': return { ok: true };
      case 'openHelp': return { ok: true };
      case 'addSource': {
        await wait(400);
        const key = params.kind === 'obsidian' ? 'vault' : 'docs';
        if (lib.sources.some(s => s.id === key)) return { ok: false, error: '이미 연결된 폴더예요.' };
        const s = Object.assign({ enabled: true, state: 'indexing', docCount: 0, lastIndexed: null, progress: null, error: null }, SOURCES[key]);
        lib.sources.push(s); demo = null;
        setTimeout(() => runIndex(key, 180, { steps: 10 }), 100);
        return { ok: true, source: s };
      }
      case 'addAtlassian': {
        await wait(900);
        if (!params.token || params.token === 'bad') return { ok: false, error: '토큰이 맞지 않아요. 이메일과 토큰을 확인해 주세요.' };
        if (lib.sources.some(s => s.id === 'atl')) return { ok: false, error: '이미 연결된 사이트예요.' };
        const s = Object.assign({ enabled: true, state: 'syncing', docCount: 0, lastIndexed: null, progress: null, error: null }, SOURCES.atl, { detail: params.site.replace(/^https?:\/\//, '') });
        lib.sources.push(s); demo = null;
        setTimeout(() => runIndex('atl', 120, { steps: 8 }), 100);
        return { ok: true, source: s };
      }
      case 'removeSource': lib.sources = lib.sources.filter(s => s.id !== params.id); demo = null; setTimeout(() => emit({ type: 'changed', reason: 'removed' }), 50); return { ok: true };
      case 'setSourceEnabled': { const s = lib.sources.find(x => x.id === params.id); if (s) s.enabled = !!params.enabled; demo = null; setTimeout(() => emit({ type: 'changed', reason: 'enabled' }), 50); return { ok: true }; }
      case 'reindex': (params.id ? [params.id] : lib.sources.map(s => s.id)).forEach(id => runIndex(id, 90, { steps: 8 })); return { ok: true };
      case 'getPreferences': return Object.assign({}, prefs);
      case 'setPreference':
        if (params.key !== 'autoHide' || typeof params.value !== 'boolean') throw new Error('알 수 없는 설정이에요.');
        prefs.autoHide = params.value; return { ok: true, autoHide: prefs.autoHide };
      case 'sourceDetails': await wait(250); return sourceDetails(params.id);
      case 'updateSource': {
        await wait(300);
        const s = lib.sources.find(x => x.id === params.id);
        if (!s) throw new Error('출처를 찾을 수 없어요.');
        if (window.__mock.failUpdate) throw new Error('설정을 저장하지 못했어요. 디스크 공간을 확인해 주세요.');
        config[s.id] = { includeKinds: params.includeKinds || null, excludeFolders: params.excludeFolders || [] };
        s.notice = null; demo = null;
        setTimeout(() => runIndex(s.id, 160, { steps: 10 }), 80);
        return { ok: true, source: Object.assign({}, s) };
      }
      case 'readRaw': await wait(60); return rawFor(params.id);
      case 'saveRaw': {
        await wait(300);
        const cur = rawFor(params.id);
        if (!cur.editable) throw new Error(cur.reason);
        if (params.fingerprint !== cur.fingerprint) return { ok: false, conflict: true };
        rawText.set(params.id, String(params.text));
        fps.set(params.id, 'fp-' + params.id + '-' + (fpNo++));
        demo = null;
        setTimeout(() => emit({ type: 'changed', reason: 'saved' }), 40);
        return { ok: true, fingerprint: fps.get(params.id) };
      }
      case 'mcpStatus': await wait(120); return { serverPath: SERVER_PATH, clients: Object.assign({}, mcpReg) };
      case 'mcpRegister': {
        await wait(500);
        const c = params.client;
        if (!(c in mcpReg)) throw new Error('알 수 없는 클라이언트예요.');
        if (mcpReg[c] === 'unavailable') return { ok: false, error: 'claude 명령을 찾지 못했어요.', command: 'claude mcp add --scope user synapse -- ' + SERVER_PATH };
        mcpReg[c] = 'registered';
        return { ok: true, restartHint: (c === 'codex' ? 'Codex를' : 'Claude 데스크톱 앱을') + ' 다시 시작하면 synapse 도구가 보여요' };
      }
      case 'cancelMCP': if (mcpLogin) mcpLogin(); return { ok: true };
      case 'addMCP': {
        // __mock.mcpOutcome: 'success' | 'needSite' | 'cancel' | 'error' (기본 needSite) · __mock.mcpDelay(ms, 기본 1500)
        const outcome = window.__mock.mcpOutcome || 'needSite';
        if (!params.site) {
          // 브라우저 로그인 기다리는 흉내 — cancelMCP가 오면 { ok:false, cancelled:true }로 끝난다
          const stopped = await new Promise(res => {
            const t = setTimeout(() => { mcpLogin = null; res(false); }, window.__mock.mcpDelay || 1500);
            mcpLogin = () => { clearTimeout(t); mcpLogin = null; res(true); };
          });
          if (stopped) return { ok: false, cancelled: true };
          if (outcome === 'cancel') return { ok: false, cancelled: true };
          if (outcome === 'error') return { ok: false, error: '인증 서버에 연결하지 못했어요. 네트워크를 확인해 주세요.' };
          if (outcome === 'needSite') return { ok: false, needSite: true, sites: SITES.slice() };
        } else await wait(700);
        if (lib.sources.some(s => s.id === 'mcp')) return { ok: false, error: '이미 연결된 사이트예요.' };
        const site = params.site || SITES[0].url, host = site.replace(/^https?:\/\//, '');
        const s = Object.assign({ enabled: true, state: 'syncing', docCount: 0, lastIndexed: null, progress: null, error: null }, SOURCES.mcp,
          { name: host.split('.')[0], detail: 'Atlassian MCP · ' + host });
        lib.sources.push(s); demo = null;
        setTimeout(() => runIndex('mcp', 120, { steps: 8 }), 100);
        return { ok: true, source: s };
      }
      // v0.6 N: 휴지통·옮기기 흐름이 브라우저에서도 보이게 하는 모의 응답(C3 모양). 실제 파일은 건드리지 않는다.
      case 'trashInfo': {
        await wait(30);
        return { items: (params.ids || []).map(id => { const d = (engine().document(id) || {}).doc || {}; return { id, title: d.title || id, path: d.path || '', inbound: 3, canTrash: true }; }), totalInbound: 3 };
      }
      case 'trashDocs': await wait(60); return { ok: true, batch: 'mock-trash-' + (fpNo++), moved: (params.ids || []).map(id => ({ id, title: id, from: '' })), skipped: [] };
      case 'restoreTrash': await wait(40); return { ok: true, restored: [], failed: [] };
      case 'moveDocs': await wait(60); return { ok: true, batch: 'mock-move-' + (fpNo++), moved: (params.ids || []).map(id => ({ id, from: '', to: params.to })), skipped: [] };
      default:
        if (BRAIN_METHODS.has(method)) { const b = brainFor(); return b ? b.call(method, params) : { ok: false, error: '사서를 열지 못했어요' }; }
        throw new Error('알 수 없는 method: ' + method);
    }
  }
  const fake = {
    messageHandlers: {
      synapseAPI: { postMessage: msg => api(msg) },
      synapse: { postMessage: msg => { log.push(['window', msg && msg.action]); } },
    },
  };
  // WKWebView에는 window.webkit이 이미 있다(다른 처리기). 바꿀 수 있으면 바꾸고, 기존 처리기는 넘겨준다.
  const real = window.webkit && window.webkit.messageHandlers;
  if (real) { try { if (real.log) fake.messageHandlers.log = real.log; } catch (e) { /* 무시 */ } }
  try { Object.defineProperty(window, 'webkit', { value: fake, configurable: true, writable: true }); } catch (e) { try { window.webkit = fake; } catch (e2) { /* 무시 */ } }
  // 바깥에서 파일이 바뀐 것처럼(충돌 흉내): fingerprint만 바꾼다
  const touch = id => { fps.set(id, 'fp-' + id + '-' + (fpNo++)); return fps.get(id); };
  // v0.8: 시작 화면 — 사서가 켜져 모드 버튼이 보이면 한 번 눌러 준다 (스크린숏·시연용)
  if (window.__MOCK_START) {
    const want = String(window.__MOCK_START);
    let tries = 0;
    const timer = setInterval(() => {
      const b = document.querySelector('.modes:not([hidden]) [data-mode="' + want + '"]');
      if (b) { clearInterval(timer); b.click(); } else if (++tries > 80) clearInterval(timer);
    }, 100);
  }
  // v0.8: "설정 열기"(data-ai-act="settings")는 app.js가 처리한다. 아직 연결 전이어도 눌렀다는 기록은 남긴다.
  document.addEventListener('click', e => { const b = e.target && e.target.closest ? e.target.closest('[data-ai-act]') : null; if (b) log.push(['ai-act', b.getAttribute('data-ai-act')]); }, true);
  const aiScenario = sc => { window.__MOCK_AI = sc; if (window.synapseAIEvent) window.synapseAIEvent({ type: 'status' }); return sc; };
  window.__mock = { ai: aiScenario, brain: () => brainFor(), brainEmit, brainScenario: BRAIN_SC, lib, emit, runIndex, status, scenario: SC, prefs, config, rawText, touch, mcpReg, mcpOutcome: null, mcpDelay: 0, failUpdate: false };
})();
