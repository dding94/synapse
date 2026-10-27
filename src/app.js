// Synapse v0.5 앱 — 데이터 출처 추상화(예시·네이티브)·상태·검색·목록·리더·자료 연결·키보드·네이티브 브리지
// docs/DESIGN.md §4·§5·§8 (v0.2 화면·조작) + docs/CONNECT.md §4 브리지 계약 · §8 화면
// v0.5 (docs/V05.md §9): 모드 home·map·week·queue, 왜? 팝오버, 사서 이벤트, U2 모듈(SynapseQueue·SynapseWeek·SynapseBrainPanel) 연결
// v0.8 (docs/V08.md §8): Claude 연결 — SynapseAI(src/ai.js) 연결, 시키기 패널 ⌘J(src/aipanel.js), 홈 브리핑, 리더 문서 요약, 설정의 Claude 구역
(function () {
  'use strict';

  const $ = id => document.getElementById(id);
  const ESC_MAP = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
  const esc = v => String(v == null ? '' : v).replace(/[&<>"']/g, c => ESC_MAP[c]);
  const icon = (name, cls = 'icon') => '<svg class="' + cls + '" aria-hidden="true"><use href="#i-' + name + '"/></svg>';
  const handlers = () => (window.webkit && window.webkit.messageHandlers) || null;
  const bridge = () => { const h = handlers(); return (h && h.synapse) || null; };
  const apiHandler = () => { const h = handlers(); return (h && h.synapseAPI) || null; };
  const post = msg => { const b = bridge(); if (!b) return false; try { b.postMessage(msg); return true; } catch (e) { return false; } };
  const NF = new Intl.NumberFormat('ko-KR');
  const num = n => NF.format(Math.max(0, Math.round(Number(n) || 0)));
  // 네이티브 응답은 JSON 호환 값. 혹시 문자열로 오면 풀어서 쓴다.
  const parse = v => { if (typeof v === 'string') { try { return JSON.parse(v); } catch (e) { return v; } } return v; };
  const errMsg = e => String((e && (e.message || e.error)) || e || '알 수 없는 오류가 났어요.').replace(/^Error:\s*/, '');

  // ---------------------------------------------------------------------------
  // 네이티브 → JS 전역은 스크립트 로드 즉시 정의한다(초기화 전에 불려도 값을 보관).
  const pending = { hotkey: null, pinned: null, visible: null, focus: false };
  let ready = false, pendingData = null;
  const pendingEvents = [];
  const pendingBrain = []; // 초기화 전에 온 사서 이벤트 종류
  window.synapseFocus = function () {
    composing = false;
    if (!ready) { pending.focus = true; return; }
    if (modalOpen()) return;
    if (editVisible()) focusEditor(); else focusSearch(true); // 숨겼다 다시 열어도 편집하던 자리로
  };
  window.synapseHotkeyStatus = function (text) { pending.hotkey = String(text || ''); if (ready) applyHotkey(); };
  window.synapseSetPinned = function (value) { pending.pinned = !!value; if (ready) applyPinned(!!value, false); };
  window.synapseVisibility = function (visible) { pending.visible = !!visible; if (ready) applyVisibility(!!visible); };
  // v0.6 N: 네이티브(마우스 옆 버튼·스와이프)가 부르는 뒤로/앞으로. 준비 전에는 히스토리가 없으니 무시한다.
  window.synapseNav = function (dir) { if (ready) navStep(dir); };
  window.synapseSetData = function (data) { if (!data || !Array.isArray(data.docs)) return; if (ready) useDemoData(data); else pendingData = data; };
  // 엔진 이벤트 (CONNECT §4): progress | changed | error
  window.synapseLibraryEvent = function (evt) {
    evt = parse(evt);
    if (!evt || typeof evt !== 'object') return;
    if (!booted) { if (pendingEvents.length < 400) pendingEvents.push(evt); return; }
    onLibraryEvent(evt);
  };
  // 사서 이벤트 (V05 §8.3): { type: 'home' | 'pending' | 'log' | 'settings' | 'policy' } — 화면은 해당 데이터를 다시 요청한다
  window.synapseBrainEvent = function (evt) {
    evt = parse(evt);
    const type = evt && typeof evt === 'object' ? String(evt.type || '') : String(evt || '');
    if (!type) return;
    if (!booted) { if (pendingBrain.length < 20 && !pendingBrain.includes(type)) pendingBrain.push(type); return; }
    onBrainEvent(type);
  };

  // v0.8: Claude 연결 이벤트(status | run | digest)는 src/ai.js가 받는다. 그 파일이 없을 때만 최소한으로 직접 받는다.
  if (typeof window.synapseAIEvent !== 'function') {
    window.synapseAIEvent = function (evt) {
      evt = parse(evt);
      if (!evt || typeof evt !== 'object' || !ready || !booted) return;
      if (evt.type === 'status') loadAIStatus();
      else if (evt.type === 'digest') onAIDigest(evt);
      else if (evt.type === 'run') onAIRun(evt);
    };
  }

  // ---------------------------------------------------------------------------
  // 글자 처리: 정규화 · 초성 · 조사 · 하이라이트 단어
  const CHO = 'ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ';
  function normalize(v) { return String(v || '').toLocaleLowerCase().normalize('NFC').trim(); }

  // 초성 문자열 + 원문 인덱스 — 하이라이트 범위 계산용. 공백은 남겨 단어 경계를 넘는 일치를 막는다.
  function choIndex(text) {
    let s = ''; const at = [];
    for (let i = 0; i < text.length; i++) {
      const c = text.charCodeAt(i);
      if (c >= 0xAC00 && c <= 0xD7A3) { s += CHO[Math.floor((c - 0xAC00) / 588)]; at.push(i); }
      else { s += /\s/.test(text[i]) ? ' ' : text[i].toLocaleLowerCase(); at.push(i); }
    }
    return { s, at };
  }
  const isChoQuery = q => /^[ㄱ-ㅎ\s]+$/.test(q) && /[ㄱ-ㅎ]/.test(q);

  // 조사 떼기 (CONNECT §3.3과 같은 목록): 남는 어간이 2음절 이상일 때만
  const JOSA = ['에서는', '으로는', '에게서', '까지는', '부터는', '이라는', '에서', '으로', '에게', '까지', '부터', '이나', '처럼', '보다', '라는',
    '은', '는', '이', '가', '을', '를', '에', '의', '도', '만', '와', '과', '로'];
  function stemOf(word) {
    if (!/^[가-힣]+$/.test(word)) return word;
    for (const j of JOSA) if (word.endsWith(j) && word.length - j.length >= 2) return word.slice(0, -j.length);
    return word;
  }

  // 하이라이트용 단어: 검색어 + 조사 뗀 어간(exact) · 동의어(expanded) · 초성
  function termsFor(query, synonyms) {
    const words = [...new Set(normalize(query).split(/\s+/).filter(Boolean))];
    const exact = [...words];
    words.forEach(w => { const s = stemOf(w); if (s !== w && !exact.includes(s)) exact.push(s); });
    const expanded = new Set();
    (synonyms || []).forEach(group => {
      const g = group.map(normalize);
      if (exact.some(t => g.includes(t))) g.forEach(x => { if (!exact.includes(x)) expanded.add(x); });
    });
    return { exact, expanded: [...expanded], cho: isChoQuery(query) ? words : null };
  }

  // 하이라이트: 검색어(+동의어)를 <mark>로. 대소문자 무시, 긴 단어 우선.
  function markText(text, terms) {
    text = String(text || '');
    const list = terms ? [...terms.exact, ...terms.expanded].filter(Boolean).sort((a, b) => b.length - a.length) : [];
    if (!list.length) return esc(text);
    const lower = text.toLocaleLowerCase();
    if (!list.some(t => lower.includes(t))) return esc(text);
    let out = '', i = 0, plain = '';
    while (i < text.length) {
      const found = list.find(t => lower.startsWith(t, i));
      if (found) { out += esc(plain) + '<mark>' + esc(text.slice(i, i + found.length)) + '</mark>'; plain = ''; i += found.length; }
      else { plain += text[i]; i++; }
    }
    return out + esc(plain);
  }
  // 초성 일치 범위 하이라이트
  function markCho(text, terms) {
    if (!terms || !terms.cho) return null;
    const ci = choIndex(text);
    for (const t of terms.cho) {
      const key = t.replace(/\s+/g, '');
      const k = ci.s.indexOf(key);
      if (k < 0) continue;
      const a = ci.at[k], b = ci.at[k + key.length - 1] + 1;
      return esc(text.slice(0, a)) + '<mark>' + esc(text.slice(a, b)) + '</mark>' + esc(text.slice(b));
    }
    return null;
  }
  function markTitle(text, terms) { return (terms && terms.cho ? markCho(text, terms) : null) || markText(text, terms); }

  // 날짜: 'YYYY-MM-DD'(예시)와 ISO 8601(엔진) 모두 받는다
  function toDate(iso) {
    if (!iso) return null;
    const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso);
    if (m) return new Date(+m[1], +m[2] - 1, +m[3]);
    const d = new Date(iso);
    return isNaN(d.getTime()) ? null : d;
  }
  // 상대 날짜: 오늘 / 어제 / N일 전 / M월 D일 / YYYY. M. D.
  function relDate(iso) {
    const t = toDate(iso);
    if (!t) return '';
    const then = new Date(t.getFullYear(), t.getMonth(), t.getDate()), now = new Date();
    const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    const days = Math.round((today - then) / 86400000);
    if (days <= 0) return '오늘';
    if (days === 1) return '어제';
    if (days < 7) return days + '일 전';
    if (t.getFullYear() === now.getFullYear()) return (t.getMonth() + 1) + '월 ' + t.getDate() + '일';
    return t.getFullYear() + '. ' + (t.getMonth() + 1) + '. ' + t.getDate() + '.';
  }
  // 갱신 시각: 방금 / N분 전 / N시간 전 / 상대 날짜
  function relTime(iso) {
    const t = toDate(iso);
    if (!t) return '';
    const min = (Date.now() - t.getTime()) / 60000;
    if (min < 1) return '방금';
    if (min < 60) return Math.floor(min) + '분 전';
    if (min < 1440) return Math.floor(min / 60) + '시간 전';
    return relDate(iso);
  }

  // 받침 유무로 조사 고르기 (과/와)
  function josa(word, withBatchim, without) {
    const c = String(word).charCodeAt(String(word).length - 1);
    if (c >= 0xAC00 && c <= 0xD7A3) return word + ((c - 0xAC00) % 28 ? withBatchim : without);
    return word + without;
  }
  const short = doc => (doc && (doc.short || doc.title)) || '';

  // 묶음 색 (CONNECT §8): group 해시 % 8 → --topic-g0…g7
  function hashStr(s) {
    let h = 0x811c9dc5;
    for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193); }
    return h >>> 0;
  }
  const groupKey = g => 'g' + (hashStr(String(g == null ? '' : g)) % 8);
  // 충돌 없는 묶음 색: 라이브러리 묶음 집합을 이름순으로 돌며 hash % 8에서 시작해 빈 칸까지 선형 탐사.
  // 8개 이하면 서로 다른 색, 집합이 그대로면 색도 그대로. 9번째부터는 흐린 '기타' 색(--topic-other).
  function createPalette() {
    let groups = new Set(), map = new Map();
    const build = () => {
      map = new Map();
      const used = new Set();
      [...groups].sort((a, b) => a < b ? -1 : a > b ? 1 : 0).forEach(g => {
        if (used.size >= 8) { map.set(g, 'other'); return; }
        let slot = hashStr(g) % 8;
        while (used.has(slot)) slot = (slot + 1) % 8;
        used.add(slot); map.set(g, 'g' + slot);
      });
    };
    const norm = g => String(g == null ? '' : g);
    return {
      key: g => map.get(norm(g)) || groupKey(g),
      // exact: 전체 그래프의 범례(거르기 전 전체 묶음) → 집합 교체. 아니면 처음 보는 묶음만 더한다.
      update(list, exact) {
        const next = exact ? new Set(list.map(norm)) : new Set([...groups, ...list.map(norm)]);
        if (next.size === groups.size && [...next].every(g => groups.has(g))) return false;
        groups = next; build(); return true;
      },
    };
  }
  const DEMO_TOPICS = new Set(['finance', 'search', 'product', 'idea']);

  // 출처 아이콘: 문서 → 종류별 작은 아이콘, 출처 → 종류 아이콘
  function docIcon(doc) {
    if (!doc) return 'doc';
    if (doc.kind === 'jira') return 'ticket';
    if (doc.kind === 'confluence' || doc.sourceKind === 'atlassian' || doc.sourceKind === 'mcp') return 'cloud';
    if (doc.sourceKind === 'obsidian') return 'obsidian';
    return 'doc';
  }
  const isRemoteKind = kind => kind === 'atlassian' || kind === 'mcp';
  const sourceIcon = kind => kind === 'obsidian' ? 'obsidian' : isRemoteKind(kind) ? 'cloud' : 'folder';

  // ===========================================================================
  // DemoSource — v0.2 로직 그대로, CONNECT §4 형식(ViewModel·DocumentModel·Status)으로 돌려준다.
  // 예시 자료(SYNAPSE_DATA)와 개발용 모의 라이브러리(dev/ui)가 함께 쓴다.
  function createDemoSource(data, opts = {}) {
    const docs = (data.docs || []).map(d => Object.assign({}, d, {
      tags: Array.isArray(d.tags) ? d.tags : [], links: Array.isArray(d.links) ? d.links : [],
      body: Array.isArray(d.body) ? d.body : [String(d.body || '')],
    }));
    const byId = new Map(docs.map(d => [d.id, d]));
    const topics = Object.assign({}, data.topics || {});
    const topicKeys = Object.keys(topics);
    docs.forEach(d => { if (!topics[d.topic]) { topics[d.topic] = { label: d.topic }; topicKeys.push(d.topic); } });
    const out = new Map(), inc = new Map(), nb = new Map();
    docs.forEach(d => { out.set(d.id, new Set()); inc.set(d.id, new Set()); nb.set(d.id, new Set()); });
    const pairs = new Set();
    docs.forEach(d => d.links.forEach(t => {
      if (!byId.has(t) || t === d.id) return;
      out.get(d.id).add(t); inc.get(t).add(d.id);
      nb.get(d.id).add(t); nb.get(t).add(d.id);
      pairs.add(d.id < t ? d.id + '|' + t : t + '|' + d.id);
    }));
    const degree = new Map(docs.map(d => [d.id, nb.get(d.id).size]));
    const tagCount = new Map();
    docs.forEach(d => d.tags.forEach(t => tagCount.set(t, (tagCount.get(t) || 0) + 1)));
    const idx = new Map(docs.map(d => [d.id, {
      title: normalize(d.title), tags: d.tags.map(normalize), body: normalize(d.body.join(' ')),
      choTitle: choIndex(d.title), choTags: d.tags.map(t => choIndex(t).s),
    }]));
    const synonymsRaw = data.synonyms || [];
    const synonyms = synonymsRaw.map(g => g.map(normalize));

    // 검색 (DESIGN §5.2): OR + 점수 합, 제목 50 / 태그 32 / 본문 12, 동의어 ×0.28, 초성 40
    function searchTerms(query) {
      const exact = [...new Set(normalize(query).split(/\s+/).filter(Boolean))];
      const expanded = new Set();
      exact.forEach(t => synonyms.forEach(group => {
        if (group.includes(t)) group.forEach(x => { if (!exact.includes(x)) expanded.add(x); });
      }));
      return { exact, expanded: [...expanded], cho: isChoQuery(query) ? exact : null };
    }
    function rankDoc(doc, terms) {
      const ix = idx.get(doc.id);
      let score = 0, reason = '', best = -1;
      if (terms.cho) {
        terms.cho.forEach(t => {
          const key = t.replace(/\s+/g, '');
          if (ix.choTitle.s.includes(key) || ix.choTags.some(c => c.includes(key))) { score += 40; if (40 > best) { best = 40; reason = '초성'; } }
        });
        return { doc, score, reason };
      }
      const hit = (term, syn) => {
        let s = 0, f = '';
        if (ix.title.includes(term)) { s = 50; f = 'title'; }
        else if (ix.tags.some(t => t.includes(term))) { s = 32; f = 'tag'; }
        else if (ix.body.includes(term)) { s = 12; f = 'body'; }
        if (!s) return;
        const w = syn ? s * 0.28 : s;
        score += w;
        if (w > best) { best = w; reason = syn ? '연관어 ‘' + term + '’' : ({ title: '제목', tag: '태그', body: '본문' })[f]; }
      };
      terms.exact.forEach(t => hit(t, false));
      terms.expanded.forEach(t => hit(t, true));
      return { doc, score, reason };
    }
    const byUpdated = (a, b) => (b.updated || '').localeCompare(a.updated || '');
    function firstSentence(doc) {
      const p = doc.body[0] || '';
      const m = p.match(/^.*?[.?!。](\s|$)/);
      return (m ? m[0] : p).trim();
    }
    // 스니펫(평문): 일치 문장 주변 발췌(한 줄 말줄임이므로 일치부가 앞쪽에 오게). 강조는 화면이 한다.
    function snippetFor(doc, terms) {
      if (!terms || terms.cho) return firstSentence(doc);
      for (const group of [terms.exact, terms.expanded]) {
        for (const p of doc.body) {
          const lower = p.toLocaleLowerCase();
          let at = -1;
          group.forEach(t => { const k = lower.indexOf(t); if (k >= 0 && (at < 0 || k < at)) at = k; });
          if (at < 0) continue;
          let start = 0;
          if (at > 16) {
            const before = p.lastIndexOf(' ', at - 10);
            start = before > 0 && at - before < 28 ? before + 1 : Math.max(0, at - 14);
          }
          return (start > 0 ? '…' : '') + p.slice(start, start + 140);
        }
      }
      return firstSentence(doc);
    }
    const summary = d => ({
      id: d.id, title: d.title, short: d.short || d.title, group: d.topic,
      kind: d.fileKind || 'md', kindLabel: d.kindLabel || d.kind || '',
      source: d.source || 'demo', sourceKind: d.sourceKind || 'demo', sourceName: d.sourceName || '',
      path: d.path || '', updated: d.updated || '', tags: d.tags.slice(), degree: degree.get(d.id) || 0,
    });
    const docNode = (d, emphasis) => ({ id: d.id, label: short(d), fullLabel: d.title, kind: 'doc', group: d.topic, degree: degree.get(d.id) || 0, emphasis });

    // 모드별 보기 (DESIGN §4.3 목록 · §5.3 그래프) → ViewModel
    function view(params) {
      const p = params || {};
      const hidden = new Set(p.hiddenGroups || []);
      const on = d => !hidden.has(d.topic);
      const legend = new Map();
      const count = d => legend.set(d.topic, (legend.get(d.topic) || 0) + 1);
      const v = { mode: p.mode || 'global', sections: [], nodes: [], links: [], centerId: null, chips: [], chipLabel: '', summary: '', legend: [], hidden: 0, total: 0, empty: null };
      const section = (key, title) => { const s = { key, title, items: [] }; v.sections.push(s); return s; };
      const add = (sec, d, reason, snippet, cls) => { const it = { doc: summary(d), reason, snippet }; if (cls) it.cls = cls; sec.items.push(it); };
      const query = String(p.query || '').trim();

      if (v.mode === 'search' && query) {
        const terms = searchTerms(query);
        const ranked = docs.map(d => rankDoc(d, terms)).filter(r => r.score > 0);
        ranked.sort((a, b) => b.score - a.score || byUpdated(a.doc, b.doc));
        ranked.forEach(r => count(r.doc));
        const matches = ranked.filter(r => on(r.doc));
        v.hidden = ranked.length - matches.length;
        v.total = matches.length;
        const matchIds = new Set(ranked.map(r => r.doc.id));
        const maxScore = matches.reduce((m, r) => Math.max(m, r.score), 0) || 1;
        const ctx = new Map();
        matches.forEach(r => nb.get(r.doc.id).forEach(n => {
          if (matchIds.has(n)) return;
          const e = ctx.get(n) || { n: 0, via: r.doc };
          e.n++; ctx.set(n, e);
        }));
        const ctxDocs = [...ctx.entries()].map(([id, e]) => ({ doc: byId.get(id), e }));
        ctxDocs.forEach(c => count(c.doc));
        const ctxShown = ctxDocs.filter(c => on(c.doc)).sort((a, b) => b.e.n - a.e.n || byUpdated(a.doc, b.doc)).slice(0, 8);
        const s1 = section('match', '검색 결과');
        matches.forEach(r => add(s1, r.doc, r.reason, snippetFor(r.doc, terms)));
        if (ctxShown.length) {
          const s2 = section('context', '연결된 문서');
          ctxShown.forEach(c => add(s2, c.doc, josa(short(c.e.via), '과', '와') + ' 연결', firstSentence(c.doc), 'is-context'));
        }
        if (matches.length) {
          const hub = 'q:' + query;
          v.centerId = hub;
          v.nodes.push({ id: hub, label: query, fullLabel: query, kind: 'keyword', emphasis: 'center' });
          matches.forEach(r => {
            v.nodes.push(docNode(r.doc, 'match'));
            v.links.push({ source: hub, target: r.doc.id, kind: 'query', strength: Math.round(r.score / maxScore * 100) / 100 });
          });
          ctxShown.forEach(c => v.nodes.push(docNode(c.doc, 'context')));
        } else v.empty = { query, hidden: v.hidden };
        v.summary = '문서 ' + matches.length + ' · 연결된 문서 ' + ctxShown.length;
        v.chipLabel = '연관 키워드';
        const tc = new Map();
        matches.forEach(r => r.doc.tags.forEach(t => { if (!terms.exact.includes(normalize(t))) tc.set(t, (tc.get(t) || 0) + 1); }));
        v.chips = [...tc.entries()].sort((a, b) => b[1] - a[1] || (tagCount.get(b[0]) - tagCount.get(a[0]))).slice(0, 8);
      } else if (v.mode === 'focus' && byId.has(p.focusId)) {
        const center = byId.get(p.focusId), depth = p.depth === 2 ? 2 : 1;
        v.centerId = center.id;
        count(center);
        const o = out.get(center.id), i = inc.get(center.id);
        const direct = [...nb.get(center.id)].map(id => byId.get(id));
        direct.forEach(count);
        const rank = d => (o.has(d.id) ? 2 : 0) + (i.has(d.id) ? 1 : 0);
        const dirShown = direct.filter(on).sort((a, b) => rank(b) - rank(a) || byUpdated(a, b));
        const taken = new Set([center.id, ...direct.map(d => d.id)]);
        const same = docs.filter(d => !taken.has(d.id)).map(d => ({ doc: d, shared: d.tags.filter(t => center.tags.includes(t)) }))
          .filter(x => x.shared.length).sort((a, b) => b.shared.length - a.shared.length || byUpdated(a.doc, b.doc));
        same.slice(0, 5).forEach(x => count(x.doc));
        const sameShown = same.filter(x => on(x.doc)).slice(0, 5);
        sameShown.forEach(x => taken.add(x.doc.id));
        add(section('center', '중심 문서'), center, center.kindLabel || center.kind || '', firstSentence(center), 'is-center');
        const sd = section('direct', '직접 연결');
        dirShown.forEach(d => add(sd, d, o.has(d.id) && i.has(d.id) ? '양방향 링크' : o.has(d.id) ? '나가는 링크' : '들어오는 링크', firstSentence(d)));
        if (sameShown.length) {
          const st = section('tag', '같은 태그');
          sameShown.forEach(x => add(st, x.doc, '같은 태그 #' + x.shared[0], firstSentence(x.doc)));
        }
        let two = [];
        if (depth === 2) {
          const via = new Map();
          dirShown.forEach(d => nb.get(d.id).forEach(n => {
            if (taken.has(n)) return;
            const e = via.get(n) || { n: 0, via: d }; e.n++; via.set(n, e);
          }));
          const all = [...via.entries()].map(([id, e]) => ({ doc: byId.get(id), e }));
          all.forEach(x => count(x.doc));
          two = all.filter(x => on(x.doc)).sort((a, b) => b.e.n - a.e.n || byUpdated(a.doc, b.doc));
          if (two.length) {
            const s2 = section('two', '두 단계 연결');
            two.forEach(x => add(s2, x.doc, short(x.e.via) + ' 경유', firstSentence(x.doc), 'is-context'));
          }
        }
        v.nodes.push(docNode(center, 'center'));
        dirShown.forEach(d => v.nodes.push(docNode(d, 'normal')));
        sameShown.forEach(x => { v.nodes.push(docNode(x.doc, 'normal')); v.links.push({ source: center.id, target: x.doc.id, kind: 'tag' }); });
        two.forEach(x => v.nodes.push(docNode(x.doc, 'context')));
        v.summary = '직접 연결 ' + dirShown.length + ' · 같은 태그 ' + sameShown.length + (depth === 2 ? ' · 두 단계 ' + two.length : '');
        v.chipLabel = '이 문서의 키워드';
        const tc = new Map();
        center.tags.forEach(t => tc.set(t, 100));
        [...dirShown, ...sameShown.map(x => x.doc)].forEach(d => d.tags.forEach(t => tc.set(t, (tc.get(t) || 0) + 1)));
        v.chips = [...tc.entries()].sort((a, b) => b[1] - a[1]).slice(0, 8)
          .map(([t, n]) => [t, center.tags.includes(t) ? n - 99 : n, center.tags.includes(t)]);
      } else {
        v.mode = 'global';
        docs.forEach(count);
        const list = docs.filter(on).sort(byUpdated);
        const s = section('recent', '최근 문서');
        list.forEach(d => add(s, d, relDate(d.updated), firstSentence(d)));
        list.forEach(d => v.nodes.push(docNode(d, 'normal')));
        v.total = list.length;
        v.chipLabel = '자주 쓰는 태그';
        v.chips = [...tagCount.entries()].sort((a, b) => b[1] - a[1]).slice(0, 8);
      }
      // 보이는 문서 사이 link (무방향 중복 제거)
      const vis = new Set(v.nodes.filter(n => n.kind === 'doc').map(n => n.id));
      let linkCount = 0;
      pairs.forEach(pr => {
        const [a, b] = pr.split('|');
        if (vis.has(a) && vis.has(b)) { v.links.push({ source: a, target: b, kind: 'link' }); linkCount++; }
      });
      if (v.mode === 'global') v.summary = '문서 ' + vis.size + ' · 연결 ' + linkCount;
      v.legend = topicKeys.map(t => [t, legend.get(t) || 0]);
      return v;
    }

    // 문서 하나 → DocumentModel (나가는·들어오는 연결은 비어 있어도 섹션을 둔다: v0.2 리더와 같게)
    function documentModel(id) {
      const d = byId.get(id);
      if (!d) throw new Error('문서를 찾을 수 없어요.');
      const outs = [...out.get(d.id)], ins = [...inc.get(d.id)];
      const linked = new Set([d.id, ...outs, ...ins]);
      const same = docs.filter(x => !linked.has(x.id))
        .map(x => ({ x, n: x.tags.filter(t => d.tags.includes(t)) })).filter(e => e.n.length)
        .sort((a, b) => b.n.length - a.n.length || byUpdated(a.x, b.x)).slice(0, 5);
      const sections = [
        { key: 'out', title: '나가는 연결', items: outs.map(t => ({ doc: summary(byId.get(t)), reason: '나가는 링크' })) },
        { key: 'in', title: '들어오는 연결', items: ins.map(t => ({ doc: summary(byId.get(t)), reason: '들어오는 링크' })) },
      ];
      if (same.length) sections.push({ key: 'tag', title: '같은 태그', items: same.map(e => ({ doc: summary(e.x), reason: '#' + e.n[0] })) });
      let text = d.body.join('\n\n'), truncated = false;
      if (text.length > 60000) { text = text.slice(0, 60000); truncated = true; }
      return { doc: summary(d), text, truncated, sections, unresolved: Array.isArray(d.unresolved) ? d.unresolved : [], open: d.open || null };
    }

    const statusText = data.status ? String(data.status) : '예시 문서 ' + docs.length + '개 · 실제 파일 미연결';
    // v0.5 예시 사서(data.js SynapseDemoBrain): 브리지가 없어도 홈·지도·정리함·이번 주를 볼 수 있게. 바뀌면 네이티브처럼 이벤트를 보낸다.
    const demoBrain = opts.brain !== false && window.SynapseDemoBrain ? window.SynapseDemoBrain.create(docs, {
      scenario: opts.brainScenario || data.brainScenario || window.__SYNAPSE_DEMO_BRAIN || 'full',
      emit: type => setTimeout(() => { if (window.synapseBrainEvent) window.synapseBrainEvent({ type }); }, 30),
    }) : null;
    return {
      kind: opts.kind || 'demo',
      synonyms: synonymsRaw,
      statusText,
      tagCounts: () => new Map(tagCount),
      colorKey: g => DEMO_TOPICS.has(g) ? g : groupKey(g),
      groupLabel: g => String((topics[g] && topics[g].label) || g).replace(/\s*·\s*/g, '·'),
      status: () => Promise.resolve({ sources: [], docCount: docs.length, indexing: false }),
      view: params => new Promise(resolve => resolve(view(params))),
      document: id => new Promise(resolve => resolve(documentModel(id))),
      open: () => Promise.resolve({ ok: false }),
      brain: (method, params) => demoBrain ? demoBrain.call(method, params) : Promise.resolve({ ok: false, error: '사서를 열지 못했어요' }),
    };
  }
  // 개발용 모의 라이브러리(dev/ui/mock-native.js)가 같은 계산을 쓰도록 공개한다.
  window.SynapseDemoSource = Object.freeze({ create: (data, opts) => createDemoSource(data, Object.assign({ brain: false }, opts || {})) });

  // ===========================================================================
  // NativeSource — CONNECT §4: await window.webkit.messageHandlers.synapseAPI.postMessage({ method, params })
  function createNativeSource(h) {
    const call = (method, params) => {
      try { return Promise.resolve(h.postMessage({ method, params: params || {} })).then(parse); }
      catch (e) { return Promise.reject(e); }
    };
    const shared = (window.SYNAPSE_DATA && window.SYNAPSE_DATA.synonyms) || []; // 엔진도 같은 기본 동의어를 쓴다(§3.3)
    const palette = createPalette();
    return {
      kind: 'native',
      synonyms: shared,
      palette,
      colorKey: g => palette.key(g),
      groupLabel: g => String(g == null || g === '' ? '기타' : g),
      status: () => call('status'),
      view: params => call('view', params),
      document: id => call('document', { id }),
      open: (id, target) => call('open', { id, target }),
      addSource: kind => call('addSource', { kind }),
      addAtlassian: form => call('addAtlassian', form),
      removeSource: id => call('removeSource', { id }),
      reindex: id => call('reindex', id ? { id } : {}),
      setSourceEnabled: (id, enabled) => call('setSourceEnabled', { id, enabled: !!enabled }),
      openHelp: topic => call('openHelp', { topic }),
      // v0.4 (docs/V04.md): 설정 · 출처별 형식/제외 폴더 · 원문 편집 · MCP 등록 · MCP 로그인
      getPreferences: () => call('getPreferences'),
      setPreference: (key, value) => call('setPreference', { key, value }),
      sourceDetails: id => call('sourceDetails', { id }),
      updateSource: (id, includeKinds, excludeFolders) => call('updateSource', { id, includeKinds, excludeFolders }),
      readRaw: id => call('readRaw', { id }),
      saveRaw: (id, text, fingerprint) => call('saveRaw', { id, text, fingerprint }),
      mcpStatus: () => call('mcpStatus'),
      mcpRegister: client => call('mcpRegister', { client }),
      addMCP: params => call('addMCP', params),
      cancelMCP: () => call('cancelMCP', {}),
      // v0.5 사서 (V05 §8.2): home·why·feedback·week·map·pending·decide·… 모두 같은 synapseAPI로 간다
      brain: (method, params) => call(method, params),
    };
  }

  // ===========================================================================
  // 상태 (DESIGN §5.1). v0.3: 주제 필터는 숨긴 묶음(hidden) 집합으로 들고 hiddenGroups로 보낸다.
  const state = {
    mode: 'global', query: '', focusId: null, depth: 1, selectedId: null,
    hidden: new Set(), showTags: false, readerOpen: true, reading: false,
    back: [], forward: [], pinned: false, autoHide: false,
    prevMode: null, // v0.5: 검색·포커스로 들어가기 전의 사서 화면(home·map·week·queue) — esc로 돌아갈 곳
    cluster: null,    // v0.6 묶음 지도: 펼친 묶음 키 (mode 'cluster')
    selCluster: null, // v0.6: 선택한 묶음 노드 id 'c:<키>' — 리더에 묶음 요약을 보인다
    showDone: false,  // v0.6: 끝난 티켓(완료·취소 계열)을 그래프에 보일지
  };
  let source = null;        // 지금 화면을 그리는 데이터 출처 (DemoSource | NativeSource)
  let nativeSrc = null;     // 브리지가 있으면 늘 만들어 둔다(예시로 둘러보는 중에도 자료 추가 가능)
  let sourceReason = 'init';
  let libStatus = null;     // 마지막 Status (네이티브)
  let onboarding = false, booted = false;
  let view = null;          // adaptView(ViewModel)
  let wideReaderPref = true, narrow = false;
  const titles = new Map(); // 문서 id → 짧은 제목 (경로 라벨·토스트)
  let knownTags = new Map(); // 태그 → 문서 수 (빈 상태 제안·태그 노드)
  const clusterNames = new Map(); // v0.6 묶음 키 → 이름 (경로 라벨)

  // v0.6 N: 스냅샷에 묶음(cluster)·돌아갈 사서 화면(prevMode)도 담는다(C5). 선택만 달라도 다른 상태로 본다.
  const sumSel = () => (state.selCluster && state.selCluster.startsWith('s:') && !state.selectedId ? state.selCluster : null);   // v0.7 E: 끝난 티켓 목록을 보던 중이면 ⌘[ 로 돌아와도 그 목록
  const snapshot = () => ({ mode: state.mode, query: state.query, focusId: state.focusId, depth: state.depth, selectedId: state.selectedId, cluster: state.cluster, prevMode: state.prevMode, selCluster: sumSel() });
  const navKey = s => [s.mode, s.query, s.focusId, s.depth, s.cluster].join('\u0001');   // 선택을 뺀 "어디"
  const sameSnap = (a, b) => a && b && navKey(a) === navKey(b) && a.selectedId === b.selectedId && (a.selCluster || null) === (b.selCluster || null);
  function pushBack() {
    const s = snapshot();
    if (!sameSnap(state.back[state.back.length - 1], s)) state.back.push(s);
    if (state.back.length > 100) state.back.shift();
    state.forward = [];
  }
  // 사용자가 직접 문서를 고를 때(클릭·링크)만 히스토리에 남긴다. ↑↓ 이동은 select()를 바로 부른다.
  function selectUser(id, opts) {
    if (!id || !selectable(id)) return;
    if (id !== state.selectedId) pushBack();
    select(id, opts);
  }

  // ---------------------------------------------------------------------------
  // ViewModel → 화면 모델: 목록 항목 맵·순서, 그래프 노드(group → topic 색 키), 하이라이트 단어
  const EMPTY_VM = { mode: 'global', sections: [], nodes: [], links: [], centerId: null, chips: [], chipLabel: '', summary: '', legend: [], hidden: 0, total: 0, empty: null };
  function adaptView(vm, query) {
    vm = vm && typeof vm === 'object' ? vm : EMPTY_VM;
    const v = {
      mode: vm.mode === 'search' || vm.mode === 'focus' || vm.mode === 'cluster' ? vm.mode : 'global',   // 'overview'(묶음 지도)도 화면에서는 global
      overview: vm.mode === 'overview',
      hiddenDone: Number(vm.hiddenDone) || 0, doneCount: Number(vm.doneCount) || 0, graphCapped: !!vm.graphCapped,
      doneShown: Number(vm.doneShown) || 0, doneSummarized: Number(vm.doneSummarized) || 0,   // v0.7 E: 문서로 보인 끝난 티켓 · 요약 노드로 접은 수
      truncated: vm.truncated && typeof vm.truncated === 'object' ? { shown: Number(vm.truncated.shown) || 0, total: vm.truncated.total == null ? null : Number(vm.truncated.total) } : null,
      docCluster: vm.docCluster && typeof vm.docCluster === 'object' ? vm.docCluster : null,
      cluster: vm.cluster && typeof vm.cluster === 'object' ? vm.cluster : null,
      sections: [], items: new Map(), order: [], docs: new Map(),
      chips: Array.isArray(vm.chips) ? vm.chips.filter(c => Array.isArray(c) && c[0] != null) : [],
      chipLabel: vm.chipLabel || '', summary: vm.summary || '',
      legend: Array.isArray(vm.legend) ? vm.legend.filter(e => Array.isArray(e) && e[0] != null) : [],
      hidden: Number(vm.hidden) || 0, total: Number(vm.total) || 0, empty: vm.empty || null,
      centerId: vm.centerId != null ? String(vm.centerId) : null, terms: null,
    };
    (Array.isArray(vm.sections) ? vm.sections : []).forEach(s => {
      if (!s || !Array.isArray(s.items)) return;
      const sec = { key: String(s.key || 'sec' + v.sections.length), title: s.title || '', items: [] };
      s.items.forEach(it => {
        const d = it && it.doc;
        if (!d || d.id == null) return;
        const id = String(d.id);
        if (v.items.has(id)) return; // 같은 문서는 한 번만 (DOM id 중복 방지)
        const snippet = String(it.snippet || '').replace(/^\s*(#{1,6}|[-*>])\s+/, '').replace(/\s+/g, ' ');
        const item = { doc: Object.assign({}, d, { id, tags: Array.isArray(d.tags) ? d.tags : [] }), reason: it.reason || '', snippet, cls: it.cls || '' };
        sec.items.push(item); v.items.set(id, item); v.order.push(id); v.docs.set(id, item.doc);
        titles.set(id, short(item.doc));
      });
      v.sections.push(sec);
    });
    v.terms = v.mode === 'search' ? termsFor(query, source && source.synonyms) : null;
    const nodes = [], ids = new Set();
    (Array.isArray(vm.nodes) ? vm.nodes : []).forEach(n => {
      if (!n || n.id == null) return;
      const id = String(n.id);
      if (ids.has(id)) return;
      ids.add(id);
      if (n.kind === 'keyword') nodes.push({ id, label: String(n.label || ''), fullLabel: n.fullLabel || n.label, kind: 'keyword', emphasis: n.emphasis || 'center' });
      else if (n.kind === 'cluster') {   // v0.6 묶음 노드 (요약 필드는 그대로 그래프·리더로 넘긴다)
        const label = String(n.label || n.key || id);
        nodes.push(Object.assign({}, n, { id, label, fullLabel: n.fullLabel || label, kind: 'cluster', topic: source ? source.colorKey(n.group) : null, emphasis: n.emphasis || 'normal' }));
        if (n.key != null) clusterNames.set(String(n.key), label);
      } else if (n.kind === 'summary') {   // v0.7 E: 끝난 티켓 요약 노드 ("완료 120") — 목록(items)은 리더가 쓴다
        const label = String(n.label || id);
        nodes.push(Object.assign({}, n, { id, label, fullLabel: n.fullLabel || label, kind: 'summary', topic: null, emphasis: n.emphasis || 'normal' }));
      } else {
        const label = n.label || short(v.docs.get(id)) || id;
        nodes.push({ id, label, fullLabel: n.fullLabel || label, kind: 'doc', topic: source ? source.colorKey(n.group) : null, group: n.group, degree: Number(n.degree) || 0, emphasis: n.emphasis || 'normal',
          docKind: n.docKind || null, status: n.status || null, statusGroup: n.statusGroup || null, mine: !!n.mine });
        if (!titles.has(id)) titles.set(id, label);
      }
    });
    v.baseNodes = nodes;
    v.baseLinks = (Array.isArray(vm.links) ? vm.links : []).filter(l => l && ids.has(String(l.source)) && ids.has(String(l.target))).map(l => {
      const o = { source: String(l.source), target: String(l.target), kind: l.kind || 'link' };
      if (typeof l.strength === 'number') o.strength = l.strength;
      if (typeof l.weight === 'number') o.weight = l.weight;
      return o;
    });
    v.visible = new Set(nodes.filter(n => n.kind === 'doc').map(n => n.id));
    if (v.cluster && v.cluster.key != null) clusterNames.set(String(v.cluster.key), String(v.cluster.label || v.cluster.key));
    if (v.centerId && !ids.has(v.centerId)) v.centerId = null;
    return v;
  }

  // 그래프 데이터: 기본 노드 + (태그 보기) 보이는 문서의 태그 노드
  function graphData() {
    if (!view) return { nodes: [], links: [] };
    let baseNodes = view.baseNodes, baseLinks = view.baseLinks;
    if (brainOn && state.mode === 'map' && mapData) {   // AI 보관본 숨김 (지도 · "숨긴 보관본 n · 보기")
      const hide = archiveSet();
      if (hide.size) { baseNodes = baseNodes.filter(n => !hide.has(n.id)); baseLinks = baseLinks.filter(l => !hide.has(l.source) && !hide.has(l.target)); }
    }
    if (!state.showTags || !view.visible.size) return { nodes: baseNodes, links: baseLinks };
    const nodes = baseNodes.slice(), links = baseLinks.slice(), tags = new Map();
    view.visible.forEach(id => { const d = view.docs.get(id); if (d) d.tags.forEach(t => { if (!tags.has(t)) tags.set(t, []); tags.get(t).push(id); }); });
    tags.forEach((ids, t) => {
      nodes.push({ id: 't:' + t, label: '#' + t, fullLabel: '#' + t, kind: 'tag', degree: knownTags.get(t) || ids.length, emphasis: 'normal' });
      ids.forEach(id => links.push({ source: id, target: 't:' + t, kind: 'tagged' }));
    });
    return { nodes, links };
  }

  // ---------------------------------------------------------------------------
  // 비동기 그리기: 요청 번호로 늦게 온 응답을 버린다. 검색 입력은 60ms 디바운스.
  let reqSeq = 0, appliedSeq = 0, queryTimer = 0, inflight = null, lastViewError = 0;
  function paramsNow() {
    // 지도·전체 그래프 = 묶음 지도(overview) + 흐름 색칠. 예시 자료(브라우저)는 묶음을 몰라서 예전 global.
    const overview = !!source && source.kind === 'native';
    const p = { mode: state.mode === 'map' || state.mode === 'global' ? (overview ? 'overview' : 'global') : state.mode, showDone: !!state.showDone };
    if (state.mode === 'cluster') p.cluster = state.cluster;
    if (state.mode === 'search') p.query = state.query.trim();
    if (state.mode === 'focus') { p.focusId = state.focusId; p.depth = state.depth; }
    if (state.hidden.size && state.mode !== 'map') p.hiddenGroups = [...state.hidden];
    return p;
  }
  function refresh(opts = {}) {
    if (mounted && mounted.mode !== state.mode) unmountModule();
    if (brainOn && source && isBrainMode(state.mode) && state.mode !== 'map') return refreshBrain(opts);
    clearTimeout(queryTimer); queryTimer = 0;
    const src = source;
    if (!src) return Promise.resolve();
    const seq = ++reqSeq, params = paramsNow(), query = state.query, withMap = brainOn && state.mode === 'map';
    const p = Promise.resolve().then(() => src.view(params)).then(parse).then(vm => (withMap ? loadMap().then(() => vm) : vm)).then(vm => {
      if (seq !== reqSeq || src !== source) return; // 늦게 온 응답
      appliedSeq = seq;
      applyView(vm, opts, query);
    }, err => {
      if (seq !== reqSeq || src !== source) return;
      appliedSeq = seq;
      console.warn('[synapse] view:', errMsg(err));
      // 이전 보기(다른 출처·다른 검색어)를 남기지 않고 오류 상태 + 다시 시도
      view = adaptView(EMPTY_VM, query);
      view.mode = state.mode;
      view.error = errMsg(err);
      state.selectedId = null; state.reading = false;
      renderAll(opts);
    });
    inflight = p;
    return p;
  }
  // 입력 대기 중인 검색까지 반영된 뒤 (⇥·↵·↑↓가 새 결과 기준으로 동작하도록)
  function settled() {
    if (queryTimer) return refresh({ typing: true });
    return inflight || Promise.resolve();
  }
  const isPending = () => !!queryTimer || reqSeq !== appliedSeq;
  // 네이티브가 답하지 않아도 키가 죽지 않게 5초 뒤에는 지금 보기로 실행
  const whenSettled = fn => {
    if (!isPending()) { fn(); return; }
    let done = false;
    const run = () => { if (done) return; done = true; clearTimeout(t); fn(); };
    const t = setTimeout(run, 5000);
    settled().then(run, run);
  };

  function applyView(vm, opts, query) {
    if (source && source.palette && vm && typeof vm === 'object') {
      const groups = (Array.isArray(vm.legend) ? vm.legend : []).filter(Array.isArray).map(e => e[0]);
      (Array.isArray(vm.nodes) ? vm.nodes : []).forEach(n => { if (n && n.kind !== 'keyword' && n.group != null) groups.push(n.group); });
      if (source.palette.update(groups, (vm.mode === 'global' || vm.mode === 'overview') && !state.hidden.size) && opts) graphKey = '';
    }
    view = adaptView(vm, query);
    const want = state.mode === 'map' ? 'global' : state.mode;
    if (view.mode !== want) { state.mode = view.mode === 'global' && brainOn ? 'map' : view.mode; if (state.mode !== 'focus') state.focusId = null; if (state.mode !== 'cluster') state.cluster = null; renderModes(); }
    if (view.mode === 'global' && source && source.kind !== 'demo') {
      view.chips.forEach(([t, n]) => knownTags.set(t, Number(n) || 1));
      view.docs.forEach(d => d.tags.forEach(t => { if (!knownTags.has(t)) knownTags.set(t, 1); }));
    }
    const sel = state.selectedId;
    // 묶음 요약을 보고 있으면(선택 문서 없음) 새로 그려도 그대로 둔다
    const keepCluster = !!state.selCluster && !sel && view.baseNodes.some(n => n.id === state.selCluster);
    if (!keepCluster) state.selCluster = null;
    if (!keepCluster && (!sel || !selectable(sel))) {
      state.selectedId = view.overview ? null : (view.order[0] || null);   // 묶음 지도는 첫 문서를 자동으로 열지 않고 지도 안내를 보인다
      // 조용한 새로 고침 중 읽던 문서가 사라짐 → 다른 문서를 읽는 것처럼 보이지 않게
      if (opts && opts.silent && sel) { if (state.reading) state.reading = false; if (!(undoPending && Date.now() < undoPending.until)) toast('읽던 문서가 목록에서 사라졌어요'); }   // 되돌리기 토스트가 떠 있으면 덮지 않는다
    }
    renderAll(opts);
  }

  function renderAll(opts = {}) {
    const keep = opts.resetScroll === false || opts.silent, prev = el.results.scrollTop;
    renderSearchBox();
    renderKeyrow();
    renderList();
    const node = syncSelectionDom();
    el.results.scrollTop = keep ? prev : 0;
    if (!opts.silent) scrollItemIntoView(node);
    renderReader();
    renderLayout();
    renderNav();
    pushGraph();
  }

  // ===========================================================================
  // 렌더링
  const el = {};
  const topicVar = g => '--topic:var(--topic-' + esc(source ? source.colorKey(g) : 'g0') + ')';
  const groupLabel = g => source ? source.groupLabel(g) : String(g);
  const isNativeView = () => !!source && source.kind === 'native';
  const stChip = d => (window.SynapseCluster ? window.SynapseCluster.chipHtml(d, esc) : '');   // v0.6 티켓 상태 칩

  function renderSearchBox() {
    if (el.search.value !== state.query && !composing) el.search.value = state.query;
    const has = !!state.query.trim();
    el.searchBox.classList.toggle('has-query', has);
    const first = view.sections[0];
    const n = first && first.key === 'match' ? first.items.length : 0;
    const more = !!(view.truncated && view.truncated.shown);   // 잘렸으면 "60개+"
    el.count.textContent = has && !view.error && !view.loading ? n + (more ? '개+' : '개') : '';
    el.count.title = more ? n + '개까지 보여요 · 더 있어요' : '';
  }

  function renderKeyrow() {
    if (brainOn && WIDE_MODES.has(state.mode)) {
      el.kwLabel.textContent = state.mode === 'home' ? todayLabel() : '';
      el.kwSummary.textContent = ''; el.kwChips.innerHTML = '';
      return;
    }
    el.kwLabel.textContent = view.chips.length ? view.chipLabel : '';
    el.kwSummary.textContent = view.summary;
    el.kwChips.innerHTML = view.chips.map(([t, n, cur]) =>
      '<button class="chip' + (cur ? ' is-current' : '') + '" type="button" data-tag="' + esc(t) + '" title="‘' + esc(t) + '’ 태그로 검색">' +
      '<span class="hash">#</span>' + esc(t) + (n != null ? '<span class="cnt">' + esc(n) + '</span>' : '') + '</button>').join('');
  }

  function libraryBusy() {
    const st = libStatus;
    return !!st && (!!st.indexing || (st.sources || []).some(s => s.state === 'indexing' || s.state === 'syncing'));
  }

  function renderList() {
    if (onboarding || view.loading) { el.results.innerHTML = ''; return; }
    el.results.setAttribute('aria-label', brainOn && state.mode === 'home' ? '홈' : brainOn && state.mode === 'map' && mapData ? '작업 흐름' : '검색 결과');
    if (brainOn && state.mode === 'home') { renderHomeList(); return; }
    if (brainOn && (state.mode === 'week' || state.mode === 'queue' || state.mode === 'tickets' || state.mode === 'workmap')) return;   // U2 모듈이 #mod-list에 그린다
    if (brainOn && state.mode === 'map' && mapData && !view.error && kit()) { renderMapList(); return; }
    if (view.error) {
      el.results.innerHTML = '<div class="list-empty is-error"><strong>목록을 불러오지 못했어요</strong><p>' + esc(view.error) + '</p>' +
        '<button class="link-btn" type="button" data-act="retry">다시 시도</button></div>';
      return;
    }
    if (!view.order.length) {
      let html;
      if (state.mode === 'search' && view.hidden) {
        html = '<div class="list-empty"><strong>주제 필터에 가려진 문서가 ' + view.hidden + '개 있어요</strong>' +
          '<p>그래프 왼쪽 아래 주제를 다시 켜면 보여요.</p><button class="link-btn" type="button" data-act="all-topics">주제 모두 켜기</button></div>';
      } else if (state.mode === 'search') {
        html = '<div class="list-empty"><strong>일치하는 문서가 없어요</strong><p>다른 단어나 초성(예: ㅈㅅ)으로 찾아보세요.</p></div>';
      } else if (view.hiddenDone && !state.showDone) {
        html = '<div class="list-empty"><strong>끝난 티켓 ' + view.hiddenDone + '개가 숨겨져 있어요</strong><p>완료·취소된 티켓은 기본으로 가려 둬요.</p><button class="link-btn" type="button" data-act="show-done">끝난 티켓 보기</button></div>';
      } else if (state.hidden.size) {
        html = '<div class="list-empty"><strong>보이는 문서가 없어요</strong><p>주제 필터가 모두 꺼져 있어요.</p><button class="link-btn" type="button" data-act="all-topics">주제 모두 켜기</button></div>';
      } else if (isNativeView() && libraryBusy()) {
        html = '<div class="list-empty"><strong>자료를 읽는 중이에요</strong><p>색인이 끝나는 대로 여기에 문서가 보여요.</p></div>';
      } else if (isNativeView()) {
        html = '<div class="list-empty"><strong>아직 색인된 문서가 없어요</strong><p>연결한 폴더에 읽을 수 있는 문서가 없거나 출처가 꺼져 있어요.</p><button class="link-btn" type="button" data-act="sources">자료 연결 열기</button></div>';
      } else {
        html = '<div class="list-empty"><strong>보이는 문서가 없어요</strong><p>예시 자료가 비어 있어요.</p></div>';
      }
      el.results.innerHTML = html;
      return;
    }
    const sel = state.selectedId;
    const marking = state.mode === 'search' ? view.terms : null;
    el.results.innerHTML = view.sections.map(s =>
      '<div class="sec-group" role="group" aria-labelledby="sec-' + esc(s.key) + '">' +
      '<div class="sec-head" id="sec-' + esc(s.key) + '">' + esc(s.title) + (s.key === 'center' ? '' : ' <span class="cnt">' + s.items.length + '</span>') + '</div>' +
      s.items.map(it => {
        const d = it.doc, match = marking && s.key === 'match';
        const src = d.sourceName ? '<span class="item-src" title="' + esc(d.sourceName + (d.kindLabel ? ' · ' + d.kindLabel : '')) + '">' + icon(docIcon(d)) + '</span>' : '';
        return '<div class="item ' + esc(it.cls) + '" role="option" id="result-' + esc(d.id) + '" data-id="' + esc(d.id) + '" aria-selected="' + (d.id === sel) + '" style="' + topicVar(d.group) + '">' +
          '<div class="item-l1"><span class="dot" aria-hidden="true"></span><span class="item-title">' +
          (match ? markTitle(d.title, view.terms) : esc(d.title)) + '</span>' + stChip(d) + src +
          '<span class="item-badge">' + esc(it.reason) + '</span></div>' +
          '<div class="item-snip">' + (match ? markText(it.snippet, view.terms) : esc(it.snippet)) + '</div>' +
        '</div>';
      }).join('') +
      '</div>').join('') + (view.truncated && window.SynapseCluster ? window.SynapseCluster.truncNoteHtml(view.truncated, state.mode === 'search') : '');
  }

  function syncSelectionDom() {
    if (brainOn && state.mode === 'home') return syncKeyed('data-hkey', homeUI.sel);
    if (brainOn && state.mode === 'map' && mapData && !view.error) return syncKeyed('data-fkey', mapSel);
    el.results.querySelectorAll('.item[aria-selected="true"]').forEach(n => n.setAttribute('aria-selected', 'false'));
    const node = state.selectedId ? document.getElementById('result-' + state.selectedId) : null;
    if (node) node.setAttribute('aria-selected', 'true');
    if (node) el.search.setAttribute('aria-activedescendant', node.id); else el.search.removeAttribute('aria-activedescendant');
    return node;
  }

  function scrollItemIntoView(node) {
    if (!node) return;
    const box = el.results.getBoundingClientRect(), r = node.getBoundingClientRect();
    const group = node.parentElement, first = group && group.querySelector('.item') === node;
    const topPad = first ? 34 : 6;
    if (r.top < box.top + topPad) el.results.scrollTop -= (box.top + topPad - r.top);
    else if (r.bottom > box.bottom - 6) el.results.scrollTop += (r.bottom - box.bottom + 6);
  }

  // ---------------------------------------------------------------------------
  // 리더 (DESIGN §4.5 · CONNECT §8): 본문은 document()로 받아 id별로 보관
  const docCache = new Map();
  let docSeq = 0, docGen = 0;
  function clearDocs() { docGen++; docCache.clear(); }
  function loadDoc(id) {
    if (docCache.has(id)) return Promise.resolve(docCache.get(id));
    const src = source, gen = docGen;
    return Promise.resolve().then(() => src.document(id)).then(parse).then(dm => {
      if (!dm || !dm.doc) throw new Error('문서를 불러오지 못했어요.');
      if (src === source && gen === docGen) { // 비운 뒤에 도착한 옛 응답은 저장하지 않는다
        docCache.set(id, dm);
        if (docCache.size > 80) docCache.delete(docCache.keys().next().value);
        if (dm.doc.title) titles.set(id, short(dm.doc));
      }
      return dm;
    });
  }

  // 가벼운 본문 렌더: 빈 줄 = 문단, # 제목, -·*·1. 목록. PDF는 줄바꿈을 이어 붙인다.
  function renderBody(text, terms, kind) {
    const join = kind === 'pdf' ? ' ' : '<br>';
    // 빈 줄로 나눈 덩어리 + 원문 줄 번호(1부터). 요소마다 data-line을 달아 멈춘 곳으로 스크롤할 수 있게 한다(v0.5).
    const blocks = [];
    let cur = null;
    String(text || '').replace(/\r\n?/g, '\n').split('\n').forEach((ln, i) => {
      if (!ln.trim()) { cur = null; return; }
      if (!cur) { cur = []; blocks.push(cur); }
      cur.push([ln, i + 1]);
    });
    let html = '', count = 0;
    blocks.forEach(b => {
      let para = [], paraAt = 0, list = null;
      const flushPara = () => { if (para.length) { html += '<p data-line="' + paraAt + '">' + para.map(l => markText(l, terms)).join(join) + '</p>'; para = []; count++; } };
      const flushList = () => { if (list) { html += '<' + list.tag + '>' + list.items.join('') + '</' + list.tag + '>'; list = null; count++; } };
      const addPara = (t, at) => { if (!para.length) paraAt = at; para.push(t); };
      b.forEach(([raw, at]) => {
        const line = raw.replace(/\s+$/, '');
        if (!line.trim()) return;
        let m;
        if ((m = /^\s{0,3}(#{1,6})\s+(.+)$/.exec(line))) {
          flushPara(); flushList();
          html += '<h3 class="rb-h rb-h' + Math.min(m[1].length, 3) + '" data-line="' + at + '">' + markText(m[2].replace(/\s+#+\s*$/, ''), terms) + '</h3>'; count++;
        } else if ((m = /^\s*([-*+•·]|\d{1,3}[.)])\s+(.+)$/.exec(line))) {
          flushPara();
          const tag = /\d/.test(m[1]) ? 'ol' : 'ul';
          if (!list || list.tag !== tag) { flushList(); list = { tag, items: [] }; }
          list.items.push('<li data-line="' + at + '">' + markText(m[2], terms) + '</li>');
        } else if ((m = /^\s*>\s?(.*)$/.exec(line))) {
          flushList(); addPara(m[1], at);
        } else { flushList(); addPara(line.trim(), at); }
      });
      flushPara(); flushList();
    });
    return count ? html : '<p class="rb-none">본문이 비어 있어요.</p>';
  }

  const LINK_REASONS = new Set(['나가는 링크', '들어오는 링크', '양방향 링크', '링크', '']);
  function relRows(items, showWhy) {
    return items.map(it => {
      const d = it.doc || {}, why = it.reason && (showWhy || !LINK_REASONS.has(it.reason)) ? it.reason : '';
      return '<button class="rel-row" type="button" data-rel="' + esc(d.id) + '" title="클릭: 선택 · 더블클릭: 중심으로" style="' + topicVar(d.group) + '">' +
        '<span class="dot" aria-hidden="true"></span><span class="t">' + esc(d.title || d.id) + '</span>' +
        (why ? '<span class="why">' + esc(why) + '</span>' : '') + icon('next') + '</button>';
    }).join('');
  }
  const REL_NONE = { out: '이 문서가 연결한 문서가 없어요', in: '이 문서를 연결한 문서가 없어요' };
  const fullDate = iso => { const t = toDate(iso); return t ? t.getFullYear() + '. ' + (t.getMonth() + 1) + '. ' + t.getDate() + '.' : ''; };

  function renderReader() {
    syncModReader();
    if (moduleOwnsReader()) return;                 // 정리함·이번 주: U2가 #mod-reader에 그린다
    const flow = homeFlowItem();                    // 홈의 코드 흐름(문서 없음): 흐름 상세
    if (flow && !(edit && edit.pinned) && kit()) {
      el.reader.classList.remove('is-empty', 'is-editing'); el.reader.classList.add('is-flow');
      el.lastReaderId = null; docSeq++;
      el.readerInner.innerHTML = editAwayHtml() + kit().flowDetail(flow);
      el.readerScroll.scrollTop = 0;
      return;
    }
    el.reader.classList.remove('is-flow', 'is-cluster');
    const id = state.selectedId;
    el.reader.classList.toggle('is-empty', !id);
    // 편집 중인 문서면 편집기를 그대로 둔다(입력·커서·실행 취소 기록 유지). 바뀐 게 없는 편집은 다른 문서로 가면 닫는다.
    if (edit && ((id && edit.id === id) || edit.pinned)) { el.reader.classList.remove('is-empty'); paintEditor(); return; }
    if (edit && !edit.dirty && !edit.saving) { edit = null; el.reader.classList.remove('edit-dirty'); }
    el.reader.classList.remove('is-editing');
    const cn = !id && state.selCluster ? clusterNodeById(state.selCluster) : null;
    if (cn && window.SynapseCluster) {   // v0.6 묶음 요약
      el.reader.classList.remove('is-empty'); el.reader.classList.add('is-cluster');
      const fresh = el.lastReaderId !== 'cluster:' + cn.id;
      docSeq++; el.lastReaderId = 'cluster:' + cn.id;
      const kc = window.SynapseCluster, rctx = { esc, icon: name => icon(name), relDate, topicVar, groupLabel };
      el.readerInner.innerHTML = editAwayHtml() + (cn.kind === 'summary' ? kc.doneListHtml(cn, rctx) : kc.summaryHtml(cn, rctx));
      if (fresh) el.readerScroll.scrollTop = 0;
      renderFoot(null);
      return;
    }
    if (!id && view.overview && window.SynapseCluster && !view.loading && !view.error) {   // 지도 안내 (처음 들어왔거나 선택을 비웠을 때)
      el.reader.classList.remove('is-empty'); el.reader.classList.add('is-cluster');
      const fresh = el.lastReaderId !== 'map-intro';
      docSeq++; el.lastReaderId = 'map-intro';
      el.readerInner.innerHTML = editAwayHtml() + window.SynapseCluster.introHtml(view.baseNodes, view.total, { esc, icon: name => icon(name), topicVar });
      if (fresh) el.readerScroll.scrollTop = 0;
      renderFoot(null);
      return;
    }
    if (!id) {
      el.lastReaderId = null; docSeq++;
      el.readerInner.innerHTML = editAwayHtml() + '<div class="reader-empty">' + icon('doc') + '<span>' +
        (view.error || view.loading ? '문서를 고르면 여기에서 바로 읽을 수 있어요' : state.mode === 'search' && !view.order.length ? '검색과 일치하는 문서가 없어요' : '문서를 고르면 여기에서 바로 읽을 수 있어요') + '</span></div>';
      renderFoot(null);
      return;
    }
    const cached = docCache.get(id);
    if (cached) { docSeq++; paintReader(cached); return; }
    const stub = () => ({ doc: (view && view.docs.get(id)) || { id, title: titles.get(id) || '' } });
    // 같은 문서를 조용히 새로 고칠 때는 받은 뒤에 바꾼다(스크롤 유지)
    if (el.lastReaderId !== id) paintReader(Object.assign(stub(), { loading: true }));
    else renderFoot(docCache.get(id) || null);
    const seq = ++docSeq;
    loadDoc(id).then(dm => { if (seq === docSeq && state.selectedId === id) paintReader(dm); },
      err => { if (seq === docSeq && state.selectedId === id) paintReader(Object.assign(stub(), { error: errMsg(err) })); });
  }

  function paintReader(dm) {
    const doc = dm.doc || {};
    const terms = state.mode === 'search' && view.terms && !view.terms.cho ? view.terms : null;
    const reading = state.reading;
    const bits = [];
    if (doc.sourceName) bits.push('<span class="meta-src">' + icon(sourceIcon(doc.sourceKind)) + '<span>' + esc(doc.sourceName) + '</span></span>');
    if (doc.kindLabel) bits.push('<span>' + esc(doc.kindLabel) + '</span>');
    if (doc.statusGroup) bits.push(stChip(doc));   // v0.6 티켓 상태
    if (doc.updated) bits.push('<span title="' + esc(fullDate(doc.updated)) + '">' + esc(relDate(doc.updated)) + '</span>');
    let body;
    if (dm.loading) body = '<div class="rb-skel" aria-label="불러오는 중"><i></i><i></i><i></i><i></i></div>';
    else if (dm.error) body = '<p class="rb-error">' + icon('alert') + '<span>본문을 불러오지 못했어요 · ' + esc(dm.error) + '</span></p>';
    else {
      const md = mdReady(dm);   // v0.6: 로컬 마크다운은 원문을 새 렌더러로 (PDF·txt는 평문 그대로). v0.7: 원격도 표를 되살려 읽기 전용으로
      body = md ? window.SynapseMarkdown.render(dm.markdown, { mark: t => markText(t, terms), resolve: linkResolver(dm), readOnly: dm.markdownSource === 'remote' }) : renderBody(dm.text, terms, doc.kind);
      if (md ? dm.markdownTruncated : dm.truncated) body += '<div class="reader-more">본문이 길어 앞부분만 보여요.' + (dm.open ? ' <button class="link-btn" type="button" data-act="open-default">원본에서 이어 보기</button>' : '') + '</div>';
    }
    const secs = Array.isArray(dm.sections) ? dm.sections : [];
    const unresolved = Array.isArray(dm.unresolved) && dm.markdownSource !== 'remote' ? dm.unresolved : [];   // v0.7: 원격은 새 노트 제안 없음
    el.readerInner.innerHTML = editAwayHtml() +
      '<div class="reader-head">' +
        '<div class="meta">' + (doc.group != null ? '<span class="topic-chip" style="' + topicVar(doc.group) + '"><span class="dot"></span>' + esc(groupLabel(doc.group)) + '</span>' : '') +
          bits.join('<span class="meta-sep">·</span>') + '</div>' +
        '<div class="reader-actions">' + editBtnHtml(doc, dm) + aiSumWrapHtml(doc, dm) +
          '<button class="icon-btn sm" type="button" data-act="doc-menu" title="더 보기 · 우클릭 메뉴" aria-label="더 보기" aria-haspopup="menu">' + icon('more') + '</button>' +
          '<button class="icon-btn sm" type="button" data-act="reading" aria-pressed="' + reading + '" title="' + (reading ? '읽기 모드 끝내기 · esc' : '읽기 모드 · ↵') + '" aria-label="읽기 모드">' + icon(reading ? 'collapse' : 'expand') + '</button>' +
          '<button class="icon-btn sm" type="button" data-act="close-reader" title="' + (reading ? '닫기 · esc' : '리더 닫기 · ⌘\\') + '" aria-label="닫기">' + icon('x') + '</button>' +
        '</div>' +
      '</div>' +
      '<h1 class="reader-title">' + (doc.title ? markTitle(doc.title, state.mode === 'search' ? view.terms : null) : '&nbsp;') + '</h1>' +
      (doc.path ? '<div class="reader-path">' + icon('folder') + '<span title="' + esc(doc.path) + '">' + esc(doc.path) + '</span></div>' : '') +
      (doc.tags && doc.tags.length ? '<div class="reader-tags">' + doc.tags.map(t => '<button class="chip" type="button" data-tag="' + esc(t) + '" title="‘' + esc(t) + '’ 태그로 검색"><span class="hash">#</span>' + esc(t) + '</button>').join('') + '</div>' : '') +
      aiDocSlotHtml(doc, dm) +
      '<div class="reader-body' + (!dm.loading && !dm.error && mdReady(dm) ? ' is-md' : '') + '">' + body + '</div>' +
      secs.filter(s => s && Array.isArray(s.items) && (s.items.length || REL_NONE[s.key])).map(s =>
        '<section class="rel"><h2 class="rel-head">' + esc(s.title) + ' <span class="cnt">' + s.items.length + '</span></h2>' +
        (s.items.length ? relRows(s.items, s.key === 'tag' || s.key === 'related') : '<div class="rel-none">' + REL_NONE[s.key] + '</div>') + '</section>').join('') +
      (unresolved.length ? '<section class="rel"><h2 class="rel-head">찾지 못한 링크 <span class="cnt">' + unresolved.length + '</span></h2><div class="unres">' +
        unresolved.slice(0, 16).map(u => '<button class="unres-chip" type="button" data-md-new="' + esc(u) + '" title="이 이름의 문서를 찾지 못했어요 · 누르면 새 노트로 만들어요">' + esc(u) + '</button>').join('') + '</div></section>' : '');
    if (el.lastReaderId !== doc.id) { el.readerScroll.scrollTop = 0; el.lastReaderId = doc.id; }
    if (!dm.loading && !dm.error && stopMark && stopMark.id === String(doc.id)) scrollToStop(!!stopMark.done);
    renderFoot(dm.loading || dm.error ? null : dm);
    if (!dm.loading && !dm.error) { prefetchRaw(doc); afterPaintMarkdown(dm); aiDocEnsure(String(doc.id)); }
  }

  function renderFoot(dm) {
    const id = state.selectedId;
    const isCenter = state.mode === 'focus' && state.focusId === id;
    el.followBtn.disabled = isCenter || (!id && !state.selCluster && !!view.overview);
    el.followBtn.hidden = !id && !!state.selCluster && state.selCluster.startsWith('s:');   // v0.7 E: 끝난 티켓 목록에는 펼치기 버튼이 없다
    el.followLabel.textContent = isCenter ? '지금 중심 문서예요' : !id && state.selCluster ? '묶음 펼치기' : '연결 따라가기';
    const open = dm && dm.open && dm.open.label ? dm.open : null;
    el.openRow.hidden = !open;
    el.readerFoot.classList.toggle('has-open', !!open);
    if (open) {
      el.openLabel.textContent = open.label;
      el.openBtn.title = open.label + ' · ⌘↵';
      el.revealBtn.hidden = !open.canReveal;
      // v0.6: 편집할 수 있는 로컬 문서는 "편집 ⌘E"가 크게, 열기·Finder·⋯는 작게. 원격·PDF는 지금처럼 열기가 크게.
      const local = !!open.canReveal, info = local && dm && dm.doc ? editInfo(dm.doc) : null;
      const showEdit = !!info && !info.hide && info.editable !== false;
      el.editBig.hidden = !showEdit;
      el.editBig.classList.toggle('is-busy', showEdit && editLoading === String(dm.doc.id));
      el.openRow.classList.toggle('has-edit', showEdit);
    }
  }

  // 원본 열기 (CONNECT §4 open): ⌘↵·⌘O = default, ⌥⌘R = reveal
  function openSelected(target) {
    const id = state.selectedId;
    if (!id || !source) return;
    if (source.kind === 'demo') { toast('원본 파일이 없는 예시 문서예요'); return; }
    const src = source;
    loadDoc(id).then(dm => {
      if (!dm.open || !dm.open.label) { toast('이 문서는 원본을 열 수 없어요'); return; }
      if (target === 'reveal' && !dm.open.canReveal) { toast('Finder에서 볼 수 없는 문서예요'); return; }
      if (target === 'obsidian' && !dm.open.canObsidian) { toast('옵시디언이 설치돼 있지 않거나 옵시디언 볼트의 노트가 아니에요'); return; }
      return src.open(id, target).then(r => {
        r = parse(r);
        if (r && r.ok === false) toast(r.error || '원본을 열지 못했어요');
      });
    }).catch(e => toast('원본을 열지 못했어요 · ' + errMsg(e)));
  }

  // ---------------------------------------------------------------------------
  // v0.6 옵시디언 없이 쓰기: 마크다운 본문 · [[링크]] 이동 · 체크박스 · 새 노트 (렌더러 src/markdown.js, 새 노트·자동완성 src/notes.js)
  const mdReady = dm => !!(dm && typeof dm.markdown === 'string' && window.SynapseMarkdown);
  // document 응답의 links → 렌더러가 묻는 resolve(대상). 목록에 없는 대상은 "못 찾음"(null)으로 그린다.
  function linkResolver(dm) {
    if (!Array.isArray(dm.links)) return null;
    const map = new Map();
    dm.links.forEach(l => { if (l && l.target != null) map.set(String(l.target), l); });
    return t => {
      const l = map.get(String(t));
      return l ? (l.id != null ? { id: String(l.id) } : l.asset ? { id: null, asset: true } : null) : null;
    };
  }
  function initNotes() {
    if (!window.SynapseNotes) return;
    window.SynapseNotes.init({ src: () => nativeSrc, toast, insertText, created: onNoteCreated });
  }
  // 링크로 옮겨 갈 때도 선택까지 기억한다 — pushBack이 선택까지 비교하므로 그대로 쓴다(v0.6 N·O 병합)
  function pushNav() { pushBack(); }
  let pendingAnchor = null;   // { id, anchor } — [[노트#제목]]으로 열린 문서에서 그 제목으로 스크롤
  function scrollToAnchor(anchor) {
    const body = el.readerInner.querySelector('.reader-body');
    if (!body || !anchor) return false;
    const want = normalize(String(anchor).replace(/^\^.*/, ''));
    const h = want ? [...body.querySelectorAll('.rb-h')].find(n => normalize(n.textContent) === want) : null;
    if (!h) return false;
    const box = el.readerScroll.getBoundingClientRect(), r = h.getBoundingClientRect();
    el.readerScroll.scrollTop += r.top - box.top - 24;
    return true;
  }
  // 본문을 그린 뒤: 그림 자리 채우기, 링크로 열렸다면 제목으로 스크롤
  function afterPaintMarkdown(dm) {
    if (!mdReady(dm) || !dm.doc) return;
    const id = String(dm.doc.id);
    if (window.SynapseNotes) window.SynapseNotes.hydrate(el.readerInner.querySelector('.reader-body'), id, () => state.selectedId === id && el.lastReaderId === id);
    if (pendingAnchor && pendingAnchor.id === id) { scrollToAnchor(pendingAnchor.anchor); pendingAnchor = null; }
  }
  // 본문 링크가 가리키는 문서로 이동 (목록·그래프에 없으면 그 문서를 중심으로)
  function openLinkedDoc(id, anchor) {
    if (!id || !source || onboarding) return;
    if (id === state.selectedId) { if (anchor) scrollToAnchor(anchor); return; }
    pendingAnchor = anchor ? { id, anchor } : null;
    pushNav();
    if (brainOn && (state.mode === 'home' || state.mode === 'week' || state.mode === 'queue' || state.mode === 'tickets' || state.mode === 'workmap')) openDocAt(id, null, null, true);
    else if (selectable(id)) { select(id, { reveal: true }); track('view', id); }
    else follow(id);
    if (!state.readerOpen && !state.reading && !isWide()) setReaderOpen(true);
  }
  function openMdLink(btn) {
    if (btn.dataset.mdId) { openLinkedDoc(btn.dataset.mdId, btn.dataset.mdAnchor || ''); return; }
    if (btn.dataset.mdFile) { toast('문서가 아닌 첨부 파일이라 Synapse에서는 열 수 없어요'); return; }
    const target = btn.dataset.mdTarget || '';
    newNote({ title: target.replace(/^.*\//, '').replace(/\.md$/i, ''), notice: '‘' + target + '’ 문서를 찾지 못했어요. 새 노트로 만들까요?' });
  }
  function openExternal(url) {
    if (!nativeSrc) { toast('예시 자료에서는 쓸 수 없어요'); return; }
    nativeSrc.brain('openURL', { url }).then(r => { if (r && r.ok === false) toast(r.error || '주소를 열지 못했어요', 'error'); })
      .catch(e => toast('주소를 열지 못했어요 · ' + errMsg(e), 'error'));
  }
  // 체크박스: 그 줄이 그대로일 때만 [ ]↔[x]로 저장 (충돌이면 알리고 다시 불러온다)
  function toggleTask(box) {
    const id = state.selectedId, dm = id ? docCache.get(id) : null;
    if (!id || !mdReady(dm) || !window.SynapseNotes) return;
    if (edit && edit.id === id) { toast('편집 중에는 체크박스를 바꿀 수 없어요'); return; }
    if (!nativeSrc) { toast('예시 자료에서는 바꿀 수 없어요'); return; }
    if (box.classList.contains('is-busy')) return;
    const line = Number(box.dataset.mdCheck);
    box.classList.add('is-busy');
    window.SynapseNotes.toggleCheck(id, line, dm.markdown, { truncated: !!dm.markdownTruncated }).then(r => {
      box.classList.remove('is-busy');
      if (r.ok) {
        const on = /\[[xX]\]/.test(r.line);
        box.checked = on;
        const li = box.closest('li'); if (li) li.classList.toggle('is-done', on);
        const lines = String(dm.markdown).replace(/\r\n?/g, '\n').split('\n');   // 다음 클릭의 비교 기준도 같이 바꿔 둔다
        lines[line - 1] = r.line; dm.markdown = lines.join('\n');
        rawInfo.delete(id);
        toast(on ? '체크했어요' : '체크를 풀었어요', '', 1600);
      } else if (r.stale || r.conflict) {
        toast(r.changed ? r.reason : r.reason + ' · 다시 불러왔어요');
        docCache.delete(id); rawInfo.delete(id);
        if (state.selectedId === id) renderReader();
      } else toast(r.reason || '저장하지 못했어요', 'error');
    });
  }
  // 리더 본문 클릭. 처리했으면 true.
  function readerMdClick(e) {
    const t = e.target;
    if (!t || !t.closest) return false;
    const box = t.closest('.md-check');
    if (box) { e.preventDefault(); toggleTask(box); return true; }
    const wiki = t.closest('.md-wiki');
    if (wiki) { e.preventDefault(); openMdLink(wiki); return true; }
    const ext = t.closest('.md-ext');
    if (ext) { e.preventDefault(); openExternal(ext.dataset.mdUrl); return true; }
    const nw = t.closest('[data-md-new]');
    if (nw) {
      const name = nw.dataset.mdNew || '';
      newNote({ title: name.replace(/^.*\//, '').replace(/\.md$/i, ''), notice: '‘' + name + '’ 문서를 찾지 못했어요. 새 노트로 만들까요?' });
      return true;
    }
    return false;
  }
  // ⌘N: 새 노트 창. 편집 중인 글에 저장하지 않은 변경이 있으면 먼저 정리하게 한다.
  function newNote(opts) {
    if (!window.SynapseNotes || onboarding || sheetOpen) return;
    if (!nativeSrc || !source || source.kind !== 'native') { toast('예시 자료에서는 새 노트를 만들 수 없어요'); return; }
    if (edit && edit.dirty) { toast('‘' + edit.title + '’에 저장하지 않은 변경이 있어요 · 먼저 저장하거나 버려 주세요'); return; }
    window.SynapseNotes.openNew(opts || {});
  }
  // 새 노트를 만들었어요 → 그 문서를 열고 바로 편집
  function onNoteCreated(res, title) {
    const id = String(res.id);
    clearDocs(); rawInfo.clear();
    toast('새 노트를 만들었어요 · ' + (res.path || title));
    pendingAnchor = null;
    refresh({ resetScroll: false }).then(() => {
      pushNav();
      if (brainOn && (state.mode === 'home' || state.mode === 'week' || state.mode === 'queue' || state.mode === 'tickets' || state.mode === 'workmap')) openDocAt(id, null, null, true);
      else if (selectable(id)) select(id, { reveal: true });
      else follow(id);
      if (!state.readerOpen && !state.reading && !isWide()) setReaderOpen(true);
      whenSettled(() => {
        if (state.selectedId === id) loadDoc(id).then(() => { if (state.selectedId === id) enterEdit(); }, () => enterEdit());   // 문서 정보(형식)를 받은 뒤 편집
        else toast('노트는 만들었지만 색인에서 제외된 폴더라 목록에 나오지 않아요');
      });
    });
  }

  // ---------------------------------------------------------------------------
  // 원문 편집 (docs/V04.md §4): 리더 자리에 textarea 편집기. 편집 가능 여부는 엔진(readRaw)이 정한다.
  // 원문은 늘 textarea.value로만 다룬다(HTML로 넣지 않는다). 창이 숨겨져도 편집 내용은 메모리에 남는다.
  const EDIT_KINDS = new Set(['md', 'markdown', 'txt', 'text']);
  const rawInfo = new Map(); // 문서 id → { editable, reason } — 엔진 답. 변경 이벤트마다 비운다.
  let rawTimer = 0, editLoading = null;
  let edit = null; // { id, title, path, doc, original, fingerprint, ta, dirty, saving, conflict, error, confirm }
  // edit.pinned: 편집 문서가 목록·색인에서 빠져도(형식 변경·출처 끔·이름 바뀜) 리더가 그 초안을 계속 보여 준다
  const editShown = () => !!edit && (edit.id === state.selectedId || edit.pinned);
  const editVisible = () => editShown() && (state.reading || state.readerOpen) && !onboarding;
  const focusEditor = () => { if (edit && edit.ta && edit.ta.isConnected) edit.ta.focus({ preventScroll: true }); };

  // 원격·PDF·다른 형식은 묻지 않아도 안다. 마크다운·텍스트(폴더·옵시디언)는 엔진에 묻는다(UTF-8·크기).
  function localEditability(doc) {
    if (!doc || !source || source.kind !== 'native') return { editable: false, hide: true, reason: '예시 문서는 편집할 수 없어요' };
    const kind = String(doc.kind || '').toLowerCase();
    if (isRemoteKind(doc.sourceKind) || kind === 'confluence' || kind === 'jira') return { editable: false, reason: '원격 문서는 원본에서 고쳐 주세요' };
    if (kind === 'pdf') return { editable: false, reason: 'PDF는 편집할 수 없어요' };
    if (!EDIT_KINDS.has(kind)) return { editable: false, reason: '이 형식은 편집할 수 없어요 · 마크다운·텍스트 파일만 고칠 수 있어요' };
    return null;
  }
  function editInfo(doc) {
    const local = localEditability(doc);
    if (local) return local;
    const known = rawInfo.get(String(doc.id));
    return known || { editable: true, pending: true };
  }
  function editBtnHtml(doc, dm) {
    return '';   // v0.6: 편집 단추는 리더 아래 열기 줄(#edit-big)로 옮겼다
    // eslint-disable-next-line no-unreachable
    if (!doc || doc.id == null || (dm && (dm.loading || dm.error))) return '';
    const info = editInfo(doc);
    if (info.hide) return '';
    const off = !info.editable, busy = editLoading === String(doc.id);
    const title = off ? info.reason || '이 문서는 편집할 수 없어요' : '원문 편집 · ⌘E';
    return '<button class="edit-btn' + (off ? ' is-off' : '') + (busy ? ' is-busy' : '') + '" type="button" data-act="edit" aria-disabled="' + off + '" title="' + esc(title) + '" aria-label="' + esc(off ? '편집할 수 없음 · ' + title : '편집') + '">' +
      icon('edit') + '<span>편집</span></button>';
  }
  function updateEditBtn() {
    const dm = docCache.get(state.selectedId);
    if (dm && dm.doc && !editShown()) renderFoot(dm);   // v0.6: 아래 열기 줄의 편집 단추 상태를 다시 맞춘다
  }
  // 선택이 머문 문서만(250ms) 미리 물어 편집 버튼을 켜고 끈다
  function prefetchRaw(doc) {
    clearTimeout(rawTimer);
    const id = String(doc.id);
    if (localEditability(doc) || rawInfo.has(id) || !nativeSrc) return;
    const src = source;
    rawTimer = setTimeout(() => {
      if (state.selectedId !== id || src !== source || rawInfo.has(id)) return;
      nativeSrc.readRaw(id).then(parse).then(r => {
        r = r || {};
        rawInfo.set(id, { editable: !!r.editable, reason: r.reason ? String(r.reason) : '' });
      }, e => { console.warn('[synapse] readRaw:', errMsg(e)); })
        .then(() => {
          if (rawInfo.size > 300) rawInfo.delete(rawInfo.keys().next().value);
          if (src === source && state.selectedId === id && !(edit && edit.id === id)) updateEditBtn();
        });
    }, 250);
  }

  function enterEdit() {
    const id = state.selectedId;
    if (!id || !source || onboarding) return;
    if (edit && edit.id === id) { if (!state.readerOpen && !state.reading) setReaderOpen(true); focusEditor(); return; }
    if (edit && edit.dirty) { toast('‘' + edit.title + '’에 저장하지 않은 변경이 있어요 · 먼저 저장하거나 버려 주세요'); returnToEdit(); return; }
    const dm = docCache.get(id);
    const doc = (dm && dm.doc) || (view && view.docs.get(id)) || { id };
    const local = localEditability(doc);
    if (local) { toast(local.reason); return; }
    const known = rawInfo.get(id);
    if (known && !known.editable) { toast(known.reason || '이 문서는 편집할 수 없어요'); return; }
    if (editLoading) return;
    editLoading = id; updateEditBtn();
    const src = source;
    nativeSrc.readRaw(id).then(parse).then(r => {
      r = r || {};
      rawInfo.set(id, { editable: !!r.editable, reason: r.reason ? String(r.reason) : '' });
      if (src !== source || state.selectedId !== id) return;
      if (!r.editable) { toast(r.reason ? String(r.reason) : '이 문서는 편집할 수 없어요'); return; }
      if (edit && edit.dirty) return;
      startEdit(id, doc, String(r.text == null ? '' : r.text), String(r.fingerprint == null ? '' : r.fingerprint));
    }).catch(e => toast('원문을 불러오지 못했어요 · ' + errMsg(e), 'error'))
      .then(() => { editLoading = null; if (!(edit && edit.id === id)) updateEditBtn(); });
  }

  function startEdit(id, doc, text, fingerprint) {
    const ta = document.createElement('textarea');
    ta.className = 'editor';
    ta.spellcheck = false;
    ta.setAttribute('autocapitalize', 'off'); ta.setAttribute('autocorrect', 'off'); ta.setAttribute('autocomplete', 'off');
    ta.setAttribute('aria-label', '원문 편집');
    const norm = text.replace(/\r\n?/g, '\n'); // textarea는 줄바꿈을 \n으로 바꾼다 — 비교 기준도 같게(엔진이 원래 형식으로 저장)
    ta.value = norm;
    edit = { id, title: short(doc) || doc.title || '문서', path: doc.path || '', doc, original: norm, fingerprint, ta,
      dirty: false, saving: false, conflict: false, error: '', confirm: false, pinned: false, awayConfirm: false };
    if (window.SynapseNotes) window.SynapseNotes.attachComplete(ta);   // v0.6: [[ 자동완성
    ta.addEventListener('compositionstart', () => { editComposing = true; });
    ta.addEventListener('compositionend', () => { editComposing = false; if (editPend) setTimeout(runEditPend, 0); });
    ta.addEventListener('blur', () => { if (!editPend) editComposing = false; });
    ta.addEventListener('input', () => {
      if (!edit || edit.ta !== ta) return;
      const dirty = ta.value !== edit.original;
      if (edit.error) edit.error = '';
      if (dirty !== edit.dirty || edit.confirm) { edit.dirty = dirty; edit.confirm = false; renderEditBar(); }
    });
    if (!state.readerOpen && !state.reading) state.readerOpen = true;
    renderLayout();
    renderReader();
    renderNav();
    ta.setSelectionRange(0, 0);
    focusEditor();
    track('edit', id);   // v0.5 §4.5: 편집 시작
  }
  // 편집기 화면: 머리줄(출처·종류·읽기 모드) · 제목 · 편집 막대 · textarea. 이미 붙어 있으면 막대만 고친다.
  function paintEditor() {
    el.reader.classList.add('is-editing');
    if (edit.ta.isConnected && el.readerInner.contains(edit.ta)) {
      const rb = el.readerInner.querySelector('.reader-head [data-act="reading"]');
      if (rb && rb.getAttribute('aria-pressed') !== String(state.reading)) {
        rb.setAttribute('aria-pressed', String(state.reading));
        rb.title = state.reading ? '넓게 편집 끝내기' : '넓게 편집';
        rb.innerHTML = icon(state.reading ? 'collapse' : 'expand');
      }
      renderEditBar(); return;
    }
    const doc = edit.doc || {}, reading = state.reading;
    const bits = [];
    if (doc.sourceName) bits.push('<span class="meta-src">' + icon(sourceIcon(doc.sourceKind)) + '<span>' + esc(doc.sourceName) + '</span></span>');
    if (doc.kindLabel) bits.push('<span>' + esc(doc.kindLabel) + '</span>');
    el.readerInner.innerHTML =
      '<div class="reader-head">' +
        '<div class="meta">' + bits.join('<span class="meta-sep">·</span>') + '</div>' +
        '<div class="reader-actions">' +
          '<button class="icon-btn sm" type="button" data-act="reading" aria-pressed="' + reading + '" title="' + (reading ? '넓게 편집 끝내기' : '넓게 편집') + '" aria-label="넓게 편집">' + icon(reading ? 'collapse' : 'expand') + '</button>' +
        '</div>' +
      '</div>' +
      '<h1 class="reader-title edit-title">' + esc(doc.title || edit.title) + '</h1>' +
      (edit.path ? '<div class="reader-path">' + icon('folder') + '<span title="' + esc(edit.path) + '">' + esc(edit.path) + '</span></div>' : '') +
      '<div class="edit-bar" role="toolbar" aria-label="편집"></div>' +
      '<div class="editor-host"></div>';
    el.readerInner.querySelector('.editor-host').appendChild(edit.ta);
    el.readerScroll.scrollTop = 0;
    el.lastReaderId = null; // 편집을 마치면 리더를 처음부터 다시 그린다
    renderEditBar();
    renderFoot(null);
  }

  function renderEditBar() {
    const bar = edit && el.readerInner.querySelector('.edit-bar');
    if (!bar) return;
    const e = edit, had = document.activeElement && bar.contains(document.activeElement) ? document.activeElement.dataset.act : null;
    let html = '<div class="edit-main">' +
      '<span class="edit-state' + (e.dirty ? ' is-dirty' : '') + '">' +
        '<span class="edit-dot" aria-hidden="true">●</span>' +
        '<span>' + (e.saving ? '저장하는 중…' : e.dirty ? '저장하지 않은 변경' : '원문 편집 중') + '</span></span>' +
      '<span class="edit-actions">' +
        '<button class="btn sm" type="button" data-act="edit-cancel" title="편집 취소 · esc"' + (e.saving ? ' disabled' : '') + '>취소</button>' +
        '<button class="btn sm primary" type="button" data-act="edit-save" title="저장 · ⌘S"' + (e.saving ? ' disabled' : '') + '>저장<kbd>⌘S</kbd></button>' +
      '</span></div>';
    // 확인(닫기·다시 불러오기)이 떠 있으면 그것만, 아니면 충돌 안내. 저장 오류는 그 아래에 늘 보인다(초안 복사 가능).
    if (e.confirm) {
      const reload = e.confirm === 'reload';
      const q = reload ? '지금 편집한 내용을 버리고 다시 불러올까요?' : '저장하지 않고 닫을까요?';
      html += '<div class="edit-alert is-confirm" role="alertdialog" aria-label="' + q + '">' + icon('alert') + '<div class="edit-alert-t"><strong>' + q + '</strong>' +
        '<p>' + (reload ? '디스크의 최신 내용으로 바뀌어요. 바로 뒤에 ⌘Z로 되돌릴 수 있어요.' : '바꾼 내용은 사라져요. 원본 파일은 그대로예요.') + '</p>' +
        '<div class="edit-alert-b"><button class="btn sm" type="button" data-act="edit-keep">계속 편집</button>' +
        (reload ? '<button class="btn sm danger" type="button" data-act="edit-reload-confirm">버리고 다시 불러오기</button>'
          : '<button class="btn sm danger" type="button" data-act="edit-discard">저장하지 않고 닫기</button>') + '</div></div></div>';
    } else if (e.conflict) {
      html += '<div class="edit-alert is-conflict" role="alert">' + icon('alert') + '<div class="edit-alert-t"><strong>다른 곳에서 먼저 바뀌었어요</strong>' +
        '<p>편집하는 동안 이 파일이 Synapse 밖에서 수정됐어요. 디스크의 내용을 다시 불러오거나, 지금 내용으로 덮어쓸 수 있어요.</p>' +
        '<div class="edit-alert-b"><button class="btn sm" type="button" data-act="edit-reload"' + (e.saving ? ' disabled' : '') + '>다시 불러오기</button>' +
        '<button class="btn sm danger" type="button" data-act="edit-overwrite"' + (e.saving ? ' disabled' : '') + '>덮어쓰기</button></div></div></div>';
    }
    if (e.error && !e.confirm) {
      html += '<div class="edit-alert is-error" role="alert">' + icon('alert') + '<div class="edit-alert-t"><strong>저장하지 못했어요</strong><p>' + esc(e.error) + '</p>' +
        '<div class="edit-alert-b"><button class="btn sm" type="button" data-act="edit-copy">' + icon('copy') + '내용 복사</button></div></div></div>';
    }
    bar.innerHTML = html;
    e.ta.readOnly = e.saving;
    el.reader.classList.toggle('edit-dirty', e.dirty);
    if (had) { const b = bar.querySelector('[data-act="' + had + '"]'); if (b && !b.disabled) b.focus({ preventScroll: true }); }
    renderNav();
  }

  // 편집기 안 키: ⌘S 저장 · esc 취소 · ⇥/⇧⇥ 들여쓰기. 나머지(↑↓·↵·⌘[ …)는 textarea 기본 동작.
  // 한글 조합 중 ⌘S·⇥: 막고 글자가 확정된 뒤 실행(compositionend, 120ms 뒤엔 blur→focus로 확정). esc·↵는 IME 몫.
  let editPend = null, editPendTimer = 0, editComposing = false, lastEditPend = { kind: null, at: 0 };
  function deferEditKey(kind) {
    editPend = kind;
    clearTimeout(editPendTimer);
    editPendTimer = setTimeout(() => {
      if (!editPend) return;
      if (edit && editComposing && document.activeElement === edit.ta) { const ta = edit.ta; ta.blur(); ta.focus({ preventScroll: true }); }
      runEditPend();
    }, 120);
  }
  function runEditPend() {
    clearTimeout(editPendTimer);
    const kind = editPend; editPend = null; editComposing = false;
    if (!kind || !edit) return;
    lastEditPend = { kind, at: performance.now() };
    if (kind === 'save') saveEdit();
    else if (!edit.ta.readOnly) indentLines(edit.ta, kind === 'outdent');
  }
  function onEditorKey(e, inText) {
    const meta = e.metaKey, ctrl = e.ctrlKey, alt = e.altKey;
    const stop = () => { e.preventDefault(); e.stopPropagation(); };
    const isSave = meta && !ctrl && !alt && !e.shiftKey && keyIs(e, ['s', 'S'], 'KeyS');
    const isTab = inText && (e.code === 'Tab' || e.key === 'Tab') && !meta && !ctrl && !alt;
    const kind = isSave ? 'save' : isTab ? (e.shiftKey ? 'outdent' : 'indent') : null;
    if (e.isComposing || e.keyCode === 229) { if (kind) { stop(); deferEditKey(kind); } return; }
    if (kind) {
      stop();
      if (editPend) { runEditPend(); return; }
      if (lastEditPend.kind === kind && performance.now() - lastEditPend.at < 250) return; // 확정 직후 같은 키가 한 번 더 오는 경우
      if (isSave) saveEdit(); else if (!edit.ta.readOnly) indentLines(edit.ta, e.shiftKey);
      return;
    }
    if (e.key === 'Escape' && !meta && !ctrl && !alt) {
      stop();
      if (editPend) { editPend = null; clearTimeout(editPendTimer); return; } // 확정을 기다리던 ⌘S·⇥는 esc로 취소
      editEscape();
    }
  }
  // ⇥: 커서 자리에 탭 / 여러 줄 선택이면 줄마다 들여쓰기. ⇧⇥: 줄 앞 탭 하나(또는 공백 2칸) 빼기. 실행 취소 기록이 남게 insertText로.
  function indentLines(ta, out) {
    const v = ta.value, a = ta.selectionStart, b = ta.selectionEnd;
    const multi = v.slice(a, b).includes('\n');
    if (!out && !multi) { insertText(ta, '\t'); return; }
    const start = v.lastIndexOf('\n', a - 1) + 1;
    const endNl = v.indexOf('\n', b > a && v[b - 1] === '\n' ? b - 1 : b);
    const end = endNl < 0 ? v.length : endNl;
    const lines = v.slice(start, end).split('\n');
    let firstDelta = 0, total = 0;
    const next = lines.map((ln, i) => {
      let r;
      if (out) { const m = /^(\t| {1,2})/.exec(ln); r = m ? ln.slice(m[0].length) : ln; }
      else r = '\t' + ln;
      if (i === 0) firstDelta = r.length - ln.length;
      total += r.length - ln.length;
      return r;
    }).join('\n');
    if (next === v.slice(start, end)) return;
    ta.setSelectionRange(start, end);
    insertText(ta, next);
    ta.setSelectionRange(Math.max(start, a + firstDelta), Math.max(start, b + total));
  }
  function insertText(ta, text) {
    let ok = false;
    try { ok = document.execCommand('insertText', false, text); } catch (e) { ok = false; }
    if (!ok) { ta.setRangeText(text, ta.selectionStart, ta.selectionEnd, 'end'); ta.dispatchEvent(new Event('input', { bubbles: true })); }
  }

  // esc: 확인 중이면 확인 닫기 → 바뀐 게 있으면 확인 묻기 → 없으면 편집 닫기
  function editEscape() {
    if (!edit) return;
    if (edit.confirm) { edit.confirm = false; renderEditBar(); focusEditor(); return; }
    if (edit.saving) return;
    if (edit.dirty) { askEdit('close'); return; }
    dropEdit(true);
  }
  function askEdit(kind) {
    edit.confirm = kind; renderEditBar();
    const keep = el.readerInner.querySelector('[data-act="edit-keep"]');
    if (keep) keep.focus({ preventScroll: true });
  }
  // 편집을 끝낸다(초안 버림 — 늘 사용자가 고른 뒤에만). focus: 검색창으로 포커스를 돌린다.
  function dropEdit(focus) {
    if (!edit) return;
    edit = null; editPend = null; clearTimeout(editPendTimer);
    el.reader.classList.remove('is-editing', 'edit-dirty');
    el.lastReaderId = null;
    renderReader();
    renderNav(); renderOnboardDraft();
    if (focus) focusSearch(false);
  }
  // 초안 복사(파일이 사라졌거나 저장할 수 없을 때 내용을 살리는 길)
  function copyDraft() {
    if (!edit) return;
    copyText(edit.ta.value, '편집한 내용을 복사했어요');
  }
  // 저장: saveRaw → { ok:true, fingerprint } | { ok:false, conflict:true }. 그 밖의 답·오류는 모두 실패(초안 유지).
  // 성공하면 편집을 닫고 리더를 새로 읽는다(엔진도 changed("saved")를 보내 목록·연결을 조용히 새로 고친다).
  function saveEdit() {
    const e0 = edit;
    if (!e0 || e0.saving) return;
    if (!nativeSrc) { e0.error = '브라우저 미리보기에서는 저장할 수 없어요.'; renderEditBar(); return; }
    if (!e0.dirty) { dropEdit(document.activeElement === e0.ta); toast('바뀐 내용이 없어 그대로 닫았어요'); return; }
    e0.saving = true; e0.error = ''; e0.confirm = false; // ⌘S는 떠 있는 확인(닫기·다시 불러오기)보다 앞선다
    renderEditBar();
    nativeSrc.saveRaw(e0.id, e0.ta.value, e0.fingerprint).then(parse).then(r => {
      if (edit !== e0) return;
      e0.saving = false;
      if (r && typeof r === 'object' && r.conflict) { e0.conflict = true; renderEditBar(); return; }
      if (!r || typeof r !== 'object' || r.ok !== true) throw new Error((r && typeof r === 'object' && r.error) || '저장했는지 확인하지 못했어요. 다시 저장해 주세요.');
      if (r.fingerprint != null) e0.fingerprint = String(r.fingerprint);
      docCache.delete(e0.id); rawInfo.delete(e0.id);
      dropEdit(document.activeElement === e0.ta || e0.ta.contains(document.activeElement));
      toast('저장했어요 · ' + e0.title);
    }).catch(err => {
      if (edit !== e0) return;
      e0.saving = false; e0.error = errMsg(err);
      renderEditBar();
      focusEditor();
    });
  }
  // 덮어쓰기: 디스크의 최신 fingerprint를 받아 지금 내용으로 다시 저장. 실패하면 충돌 안내 아래에 오류를 보인다.
  function overwriteEdit() {
    const e0 = edit;
    if (!e0 || e0.saving) return;
    e0.saving = true; e0.error = ''; renderEditBar();
    nativeSrc.readRaw(e0.id).then(parse).then(r => {
      r = r || {};
      if (edit !== e0) return;
      if (!r.editable) throw new Error(r.reason || '이제 이 문서는 편집할 수 없어요.');
      e0.fingerprint = String(r.fingerprint == null ? '' : r.fingerprint);
      e0.saving = false; e0.conflict = false; e0.dirty = true;
      saveEdit();
    }).catch(err => { if (edit !== e0) return; e0.saving = false; e0.error = errMsg(err); renderEditBar(); });
  }
  // 다시 불러오기: 바꾼 게 있으면 먼저 묻는다. 바꿀 때는 insertText로 넣어 ⌘Z로 되돌릴 수 있게.
  function reloadEdit(confirmed) {
    const e0 = edit;
    if (!e0 || e0.saving) return;
    if (e0.dirty && !confirmed) { askEdit('reload'); return; }
    e0.confirm = false; e0.saving = true; e0.error = ''; renderEditBar();
    nativeSrc.readRaw(e0.id).then(parse).then(r => {
      r = r || {};
      if (edit !== e0) return;
      e0.saving = false;
      if (!r.editable) throw new Error(r.reason || '이제 이 문서는 편집할 수 없어요.');
      const norm = String(r.text == null ? '' : r.text).replace(/\r\n?/g, '\n');
      e0.original = norm;
      e0.fingerprint = String(r.fingerprint == null ? '' : r.fingerprint);
      e0.conflict = false;
      e0.ta.readOnly = false;
      e0.ta.focus({ preventScroll: true });
      e0.ta.select();
      if (e0.ta.value !== norm) insertText(e0.ta, norm);
      e0.dirty = e0.ta.value !== e0.original;
      renderEditBar();
      e0.ta.setSelectionRange(0, 0); e0.ta.scrollTop = 0;
      toast('디스크의 최신 내용을 불러왔어요 · ⌘Z로 되돌릴 수 있어요');
    }).catch(err => { if (edit !== e0) return; e0.saving = false; e0.error = errMsg(err); renderEditBar(); });
  }
  // 다른 문서를 보는 동안 저장하지 않은 편집이 있으면 리더 위에 알려 준다(이어서 편집 · 버리기 — 버리기는 한 번 더 확인)
  function editAwayHtml() {
    if (!edit || editShown()) return '';
    const t = '<b>‘' + esc(edit.title) + '’</b>';
    if (edit.awayConfirm) return '<div class="edit-away is-confirm" role="alertdialog">' + icon('alert') + '<span>' + t + '의 변경을 버릴까요?</span>' +
      '<button class="btn sm" type="button" data-act="edit-away-keep">취소</button><button class="btn sm danger" type="button" data-act="edit-away-discard">버리기</button></div>';
    return '<div class="edit-away" role="status">' + icon('edit') + '<span>' + t + '에 저장하지 않은 변경이 있어요</span>' +
      '<button class="link-btn" type="button" data-act="edit-return">이어서 편집</button>' +
      '<button class="link-btn is-quiet" type="button" data-act="edit-away-ask">버리기</button></div>';
  }
  function setAwayConfirm(on) {
    if (!edit) return;
    edit.awayConfirm = !!on;
    const cur = el.readerInner.querySelector('.edit-away') || el.modAway.querySelector('.edit-away'); // 본문을 불러오는 중이어도 배너만 바로 바꾼다
    if (cur) { const tmp = document.createElement('div'); tmp.innerHTML = editAwayHtml(); if (tmp.firstChild) cur.replaceWith(tmp.firstChild); else cur.remove(); }
    if (el.modAway) el.modAway.dataset.html = el.modAway.innerHTML;
    renderOnboardDraft();
    const scope = onboarding ? el.onboardDraft : moduleOwnsReader() ? el.modAway : el.readerInner;
    const b = scope.querySelector(on ? '[data-act="edit-away-keep"]' : '[data-act="edit-away-ask"]');
    if (b) b.focus({ preventScroll: true });
  }
  // 편집 문서로 돌아가기: 목록에 있으면 고르고, 없으면(색인에서 빠짐) 리더가 초안을 붙들고 보여 준다
  function returnToEdit() {
    if (!edit) return;
    const id = edit.id;
    edit.awayConfirm = false;
    if (mounted) {   // 정리함·이번 주: 읽기 모드로 편집기를 연다(모듈 리더는 그대로)
      edit.pinned = false; state.selectedId = id;
      if (!state.reading) setReading(true); else renderReader();
      renderNav(); focusEditor(); return;
    }
    if (selectable(id)) { edit.pinned = false; select(id, { reveal: true }); }
    else edit.pinned = true;
    if (!state.readerOpen && !state.reading) setReaderOpen(true);
    renderReader(); renderNav();
    focusEditor();
  }

  // ---------------------------------------------------------------------------
  // 그래프 오버레이: 경로·도움말·도구·범례 (DESIGN §4.4)
  function labelFor(s) {
    if (s.mode === 'search') return '“' + s.query.trim() + '”';
    if (s.mode === 'focus') return titles.get(s.focusId) || '문서';
    if (s.mode === 'home' || s.mode === 'week' || s.mode === 'queue' || s.mode === 'tickets' || s.mode === 'workmap') return MODE_LABEL[s.mode];
    if (s.mode === 'cluster') return clusterNames.get(s.cluster) || '묶음';
    return '전체 그래프';
  }
  // 범례 = 보이는 묶음 상위 6개 + 기타 (7개 이하면 모두). 숨긴 묶음은 늘 남겨 다시 켤 수 있게.
  let legendCache = [];
  function legendEntries(top) {
    const seen = new Set(), all = [];
    view.legend.forEach(([g, n]) => { const k = String(g); if (seen.has(k)) return; seen.add(k); all.push({ g: k, n: Number(n) || 0 }); });
    state.hidden.forEach(g => { if (!seen.has(g)) { seen.add(g); all.push({ g, n: 0 }); } });
    const one = e => ({ keys: [e.g], label: groupLabel(e.g), n: e.n, group: e.g });
    if (all.length <= top + 1) return all.map(one);
    const sorted = all.slice().sort((a, b) => b.n - a.n || a.g.localeCompare(b.g, 'ko'));
    const rest = sorted.slice(top);
    return [...sorted.slice(0, top).map(one), { keys: rest.map(e => e.g), label: '기타', n: rest.reduce((s, e) => s + e.n, 0), other: true }];
  }
  function renderNav() {
    const trail = [...state.back, snapshot()];
    let start = 0;
    for (let i = trail.length - 1; i >= 0; i--) if (trail[i].mode !== 'focus') { start = i; break; }
    let items = trail.slice(start).map((s, i) => ({ s, steps: trail.length - 1 - (start + i) }));
    items = items.filter((x, i) => i === items.length - 1 || navKey(x.s) !== navKey(items[i + 1].s));   // 선택만 다른 기록은 경로에서 하나로
    if (!isGlobalish(items[0].s.mode)) items.unshift({ s: { mode: brainOn ? 'map' : 'global' }, steps: -1 });
    let shown = items, ell = false;
    if (items.length > 3) { shown = items.slice(-3); ell = true; }
    const sep = '<span class="crumb-sep" aria-hidden="true">›</span>';
    el.crumbs.innerHTML = (ell ? '<span class="crumb is-ellipsis">…</span>' + sep : '') + shown.map((x, i) => {
      const last = i === shown.length - 1;
      return last ? '<span class="crumb is-current" aria-current="location" title="' + esc(labelFor(x.s)) + '">' + esc(labelFor(x.s)) + '</span>'
        : '<button class="crumb" type="button" data-steps="' + x.steps + '" title="' + esc(labelFor(x.s)) + '(으)로 돌아가기">' + esc(labelFor(x.s)) + '</button>' + sep;
    }).join('');
    el.backBtn.disabled = !state.back.length;
    if (el.navBack) { el.navBack.disabled = !state.back.length; el.navFwd.disabled = !state.forward.length; }
    el.help.innerHTML = state.mode === 'search' ? '키워드와 이어진 문서 · 더블클릭으로 중심 이동'
      : state.mode === 'focus' ? '연결 따라가기 <kbd>⇥</kbd> · 뒤로 <kbd>⌘[</kbd> · 더블클릭으로 중심 이동'
      : state.mode === 'cluster' ? '문서를 클릭해 미리보고 더블클릭해 중심으로 · 흐릿한 묶음을 더블클릭하면 그쪽으로 · 뒤로 <kbd>⌘[</kbd>'
      : brainOn && state.mode === 'map' && mapData ? '묶음 클릭: 요약 · 더블클릭 <kbd>↵</kbd>: 펼치기'
      : view && view.overview ? '묶음을 클릭해 요약을 보고, 더블클릭·<kbd>↵</kbd>로 펼쳐요'
      : '노드를 클릭해 미리보고, 더블클릭해 중심으로';
    el.tagsBtn.setAttribute('aria-pressed', String(state.showTags));
    el.depthSeg.hidden = state.mode !== 'focus';
    el.depthSeg.querySelectorAll('button').forEach(b => b.setAttribute('aria-pressed', String(Number(b.dataset.depth) === state.depth)));
    el.readerBtn.setAttribute('aria-pressed', String(readerVisible()));
    // 상위 6개 + 기타. 그래프가 좁아 범례가 한 줄을 넘으면 칩을 기타로 접어 한 줄에 맞춘다(최소 3개).
    if (brainOn && state.mode === 'map' && mapData && kit()) {   // 지도: 흐름 범례(최대 8) + 흐름 없음
      legendCache = [];
      const html = kit().legend(mapData, mapSel);
      if (el.legend.dataset.html !== html) { el.legend.innerHTML = html; el.legend.dataset.html = html; }
      el.legend.hidden = !html;
    } else {
      el.legend.dataset.html = '';
      for (let top = 6; top >= 3; top--) {
        renderLegend(legendEntries(top));
        if (el.legend.hidden || el.legend.offsetHeight <= 36) break;
      }
    }
    renderArchiveToggle();
    renderGraphExtras();
    renderHints();
    renderModes();
    renderGraphEmpty();
    const editing = editVisible();
    el.hints.hidden = editing; el.hintsEdit.hidden = !editing;
    el.escHint.textContent = sheetOpen ? '패널 닫기' : whyState ? '팝오버 닫기' : state.reading ? '읽기 닫기' : drawerCovering() ? '서랍 닫기'
      : !brainOn ? (state.mode !== 'global' ? '처음으로' : '닫기')
      : state.mode === 'search' || state.mode === 'focus' || state.mode === 'cluster' ? (restMode() === 'home' ? '홈으로' : MODE_LABEL[restMode()] + '(으)로')
      : state.mode !== 'home' ? '홈으로' : '닫기';
  }
  function renderLegend(entries) {
    legendCache = entries;
    el.legend.hidden = !legendCache.length;
    el.legend.innerHTML = legendCache.map((e, i) => {
      const on = e.keys.some(k => !state.hidden.has(k));
      return '<button class="legend-chip' + (e.n ? '' : ' is-zero') + (e.other ? ' is-other' : '') + '" type="button" data-legend="' + i + '" aria-pressed="' + on + '"' +
        (e.other ? ' style="--topic:var(--text-3)"' : ' style="' + topicVar(e.group) + '"') +
        ' title="' + esc(e.other ? e.keys.length + '개 묶음: ' + e.keys.slice(0, 12).map(groupLabel).join(', ') + (e.keys.length > 12 ? ' …' : '') + '\n' : '') +
        '클릭: ' + (on ? '숨기기' : '보이기') + ' · ⌥클릭: 이 주제만">' +
        '<span class="dot" aria-hidden="true"></span><span class="lbl">' + esc(e.label) + '</span><span class="cnt">' + num(e.n) + '</span></button>';
    }).join('');
  }

  function renderGraphEmpty() {
    const ic = el.graphEmpty.querySelector('.graph-empty-icon');
    if (view.loading || view.error) { el.graphEmpty.hidden = true; return; }
    if (view.empty) {
      el.graphEmpty.hidden = false;
      el.graphEmpty.classList.remove('is-library');
      ic.innerHTML = icon('search');
      el.emptyText.textContent = view.empty.hidden ? '주제 필터에 가려진 문서가 ' + view.empty.hidden + '개 있어요' : '‘' + view.empty.query + '’와 이어진 문서가 없어요';
      el.emptySub.textContent = view.empty.hidden ? '꺼 둔 주제를 다시 켜 보세요' : '이런 키워드는 어때요?';
      el.emptyChips.innerHTML = view.empty.hidden ? '<button class="chip" type="button" data-act="all-topics">주제 모두 켜기</button>'
        : suggestions(view.empty.query).map(t => '<button class="chip" type="button" data-tag="' + esc(t) + '"><span class="hash">#</span>' + esc(t) + '</button>').join('');
    } else if (isNativeView() && isGlobalish(state.mode) && !view.order.length && !view.visible.size && !state.hidden.size && !view.doneCount) {
      const busy = libraryBusy(), p = progressInfo();
      el.graphEmpty.hidden = false;
      el.graphEmpty.classList.add('is-library');
      ic.innerHTML = icon(busy ? 'refresh' : 'stack');
      ic.classList.toggle('is-busy', busy);
      el.emptyText.textContent = busy ? '자료를 읽고 있어요' : '아직 색인된 문서가 없어요';
      el.emptySub.textContent = busy ? (p.total ? p.label + ' · 끝나면 여기에 연결이 그려져요' : '파일을 찾는 중이에요 · 끝나면 여기에 연결이 그려져요')
        : '연결한 자료에 읽을 수 있는 문서가 없거나 출처가 꺼져 있어요';
      el.emptyChips.innerHTML = '<button class="chip" type="button" data-act="sources">' + icon('stack') + '자료 연결 열기</button>';
    } else el.graphEmpty.hidden = true;
  }

  function suggestions(q) {
    const nq = normalize(q), out = [];
    const tags = knownTags;
    (source && source.synonyms || []).forEach(group => {
      const g = group.map(normalize);
      if (g.some(w => w.includes(nq) || (nq.length > 1 && nq.includes(w)))) g.forEach(w => { if (w !== nq && tags.has(w)) out.push(w); });
    });
    const chars = [...nq].filter(c => /[가-힣]/.test(c));
    [...tags.keys()].forEach(t => { if (chars.some(c => t.includes(c))) out.push(t); });
    [...tags.entries()].sort((a, b) => b[1] - a[1]).forEach(([t]) => out.push(t));
    return [...new Set(out)].slice(0, 3);
  }

  // ---------------------------------------------------------------------------
  // 레이아웃 상태: 리더 열 / 서랍 / 읽기 모드
  const readerVisible = () => isWide() ? wideReader : state.readerOpen;
  const drawerCovering = () => narrow && state.readerOpen && !state.reading && !isWide();
  const GRAPH_PAD = { top: 84, right: 24, bottom: 60, left: 24 }; // 위: 경로+도움말 두 줄, 아래: 범례·확대 도구
  let lastPadRight = null;
  function renderLayout() {
    const wide = isWide();   // v0.5 홈·이번 주·정리함: 그래프 칸을 숨기고 목록을 넓힌다. 좁은 창에서도 리더는 서랍이 아니라 칸.
    el.main.classList.toggle('narrow', narrow);
    el.main.classList.toggle('reader-closed', wide ? !wideReader : narrow || !state.readerOpen);
    el.main.classList.toggle('drawer-open', !wide && narrow && state.readerOpen);
    el.main.classList.toggle('reading', state.reading);
    el.main.classList.toggle('mode-wide', wide);
    ['home', 'map', 'workmap', 'week', 'queue', 'tickets'].forEach(m => el.main.classList.toggle('mode-' + m, brainOn && state.mode === m));
    const right = drawerCovering() ? 340 + 16 : GRAPH_PAD.right;
    if (graph && right !== lastPadRight) { lastPadRight = right; safe(() => graph.setPadding(Object.assign({}, GRAPH_PAD, { right }))); }
  }

  // ---------------------------------------------------------------------------
  // 그래프 연결 (DESIGN §6)
  let graph = null, graphKey = '', graphHoverFromGraph = null, hoverId = null;
  function clearHover() {
    hoverId = null; graphHoverFromGraph = null;
    document.querySelectorAll('.is-ghover').forEach(n => n.classList.remove('is-ghover'));
    if (graph) safe(() => graph.setHover(null));
  }
  function safe(fn) { try { return fn(); } catch (e) { console.warn('[synapse] graph:', e && e.message); return undefined; } }

  function pushGraph() {
    if (!graph || !view || isWide()) return;    // 넓은 화면(홈 등)에서는 그래프가 숨어 있다 — 배치·기억은 그대로 둔다
    const data = graphData();
    const key = view.mode + '|' + view.centerId + '|' + data.nodes.map(n => n.id + ':' + n.emphasis + ':' + (n.topic || '') + (n.kind === 'cluster' ? ':' + n.count + ':' + n.openTickets : n.kind === 'summary' ? ':' + n.count : '')).join(',') + '|' + data.links.length;
    if (key !== graphKey) {
      graphKey = key;
      safe(() => graph.setGraph({ nodes: data.nodes, links: data.links }, { layoutKey: view.mode, centerId: view.centerId }));
    }
    safe(() => graph.setSelection(graphSelection()));
    applyMapStyles();
  }

  // 선택만 바뀔 때(가벼운 경로). 그래프에만 있는 문서(엔진의 전체 그래프 ⊃ 목록)도 고를 수 있다.
  // 묶음 지도에서는 문서 노드가 없다 — 문서 → 묶음 번호(docCluster)로도 고를 수 있다(흐름의 문서 등)
  const selectable = id => !!id && !!view && (view.items.has(id) || view.visible.has(id) || !!(view.docCluster && view.docCluster[id]));
  // 그래프에서 강조할 노드: 선택 문서(없으면 그 문서가 속한 묶음) 또는 선택한 묶음
  const graphSelection = () => {
    const id = state.selectedId;
    if (id) return view.visible.has(id) ? id : (view.docCluster && view.docCluster[id]) || null;
    return state.selCluster || null;
  };
  const clusterNodeById = id => (view && id ? view.baseNodes.find(n => n.id === id && (n.kind === 'cluster' || n.kind === 'summary')) : null) || null;   // v0.7 E: 요약 노드('s:…')도 같은 통로로 고른다
  function selectCluster(id) {
    const cn = clusterNodeById(id);
    if (!cn) return;
    if (edit && edit.pinned) edit.pinned = false;
    state.selCluster = id; state.selectedId = null;
    syncSelectionDom();
    renderReader();
    if (graph) safe(() => graph.setSelection(id));
    renderNav();
  }
  // 묶음 펼치기 = 기존 navigate (히스토리에 남아 ⌘[ 로 돌아온다)
  function expandCluster(id) {
    const cn = clusterNodeById(id || state.selCluster);
    if (cn && cn.kind === 'summary') { selectCluster(cn.id); return; }   // ↵·더블클릭 = 끝난 티켓 목록 보기
    if (!cn || !cn.key) return;
    if (state.mode === 'cluster' && state.cluster === cn.key) return;
    navigate({ mode: 'cluster', cluster: String(cn.key), query: '', focusId: null, selectedId: null });
  }
  function toggleShowDone(on) {
    const next = typeof on === 'boolean' ? on : !state.showDone;
    state.showDone = next;
    if (nativeSrc) Promise.resolve().then(() => nativeSrc.setPreference('showDone', next)).catch(e => console.warn('[synapse] showDone:', errMsg(e)));
    refresh({ resetScroll: false });
  }
  let padRaf = 0;
  function syncGraphPad(tickets) {
    const top = tickets ? 106 : 84, bottom = Math.min(150, Math.max(60, el.legend.hidden ? 0 : el.legend.offsetHeight + 22));
    if (top === GRAPH_PAD.top && bottom === GRAPH_PAD.bottom) return;
    GRAPH_PAD.top = top; GRAPH_PAD.bottom = bottom;
    if (graph) safe(() => graph.setPadding({ top, bottom }));
  }
  // 끝난 티켓 토글 · 티켓 상태 범례 (그래프 위 보조 요소)
  function renderGraphExtras() {
    const kitC = window.SynapseCluster;
    const graphShown = !!view && !view.loading && !view.error && !isWide();
    const tickets = graphShown && kitC && view.baseNodes.some(x => (x.kind === 'doc' && x.statusGroup) || (x.kind === 'cluster' && x.docKind === 'jira'));
    // 끝난 티켓 토글: 이 화면에 Jira 티켓이 있고 "이 화면의 끝난 티켓 수"가 있을 때만. 숫자는 늘 그 수(숨겼든 보이든).
    const n = tickets ? view.doneCount : 0;
    el.gDone.hidden = !n;
    if (n) el.gDone.innerHTML = icon(state.showDone ? 'x' : 'check') + '<span>' + esc(kitC.doneToggleText(n, state.showDone)) + '</span>';
    el.gStatus.hidden = !tickets;
    if (tickets) { const html = kitC.legendHtml(state.showDone && view.doneSummarized > 0 ? '끝난 티켓은 최근 순 ' + view.doneShown + '개만 그리고, 나머지는 알약으로 묶었어요' : state.showDone && view.graphCapped ? '끝난 티켓은 최근 순 200개까지만 그려요' : ''); if (el.gStatus.dataset.html !== html) { el.gStatus.innerHTML = html; el.gStatus.dataset.html = html; } }
    // 상태 범례가 보이면 위 여백을 늘리고, 아래 범례가 여러 줄이면 아래 여백도 늘려 노드·이름이 가리지 않게 한다
    syncGraphPad(tickets);
    if (!padRaf) padRaf = requestAnimationFrame(() => { padRaf = 0; syncGraphPad(tickets); });   // 레이아웃이 자리 잡은 뒤 한 번 더 잰다
  }
  function select(id, opts = {}) {
    if (!selectable(id)) return;
    state.selCluster = null;
    if (edit && edit.pinned && id !== edit.id) edit.pinned = false; // 다른 문서를 고르면 붙들어 둔 초안은 배너로
    state.selectedId = id;
    if (brainOn && state.mode === 'map' && mapData) { const t = (mapData.docThread || {})[id]; mapSel = t != null ? String(t) : null; if (whyState) closeWhy(false); }
    const node = syncSelectionDom();
    if (opts.scroll !== false) scrollItemIntoView(node);
    renderReader();
    if (brainOn && state.mode === 'map') applyMapStyles();
    if (graph) {
      safe(() => graph.setSelection(graphSelection()));
      if (opts.reveal && view.visible.has(id)) safe(() => graph.reveal(id));
    }
    renderNav();
  }
  function moveSelection(delta) {
    if (brainOn && state.mode === 'home') { homeMove(delta); return; }
    if (brainOn && state.mode === 'map' && mapData) { mapMove(delta); return; }
    if (!view || !view.order.length) return;
    const i = view.order.indexOf(state.selectedId);
    const next = i < 0 ? 0 : Math.max(0, Math.min(view.order.length - 1, i + delta));
    if (view.order[next] !== state.selectedId || i < 0) select(view.order[next], { reveal: true });
  }

  // ---------------------------------------------------------------------------
  // 탐색 이동 (DESIGN §5.1) — 현재 상태를 back에 넣고 forward를 비운다
  function navigate(patch) {
    pushBack();
    state.selCluster = null;
    Object.assign(state, patch);
    return refresh();
  }
  function follow(id) {
    if (!id || /^[qtc]:/.test(id)) return;
    if (state.mode === 'focus' && state.focusId === id) { toast('이미 이 문서를 중심으로 보고 있어요'); return; }
    navigate({ mode: 'focus', focusId: id, query: '', selectedId: id });
  }
  function searchTag(tag) {
    if (state.mode === 'search' && normalize(state.query) === normalize(tag)) return;
    navigate({ mode: 'search', query: tag, focusId: null, selectedId: null, reading: false });
  }
  function resetAll() {
    if (brainOn) { pushBack(); setMode('map', { force: true }); return Promise.resolve(); }   // 경로의 '전체 그래프' = 지도
    return navigate({ mode: 'global', query: '', focusId: null, selectedId: null });
  }

  // 복원: 사서 화면(홈·정리함·이번 주)이면 setMode 경로로, 선택만 다르면 다시 그리지 않고 선택만 옮긴다.
  function restore(s, from) {
    Object.assign(state, { mode: s.mode, query: s.query, focusId: s.focusId, depth: s.depth, selectedId: s.selectedId, cluster: s.cluster || null, selCluster: s.selCluster && String(s.selCluster).startsWith('s:') ? s.selCluster : null });
    if (s.prevMode !== undefined) state.prevMode = s.prevMode;
    if (brainOn && source && isBrainMode(s.mode) && s.mode !== 'map') { setMode(s.mode, { force: true, noHistory: true }); return Promise.resolve(); }
    if (from && navKey(from) === navKey(s) && view && selectable(s.selectedId) && !mounted) { select(s.selectedId, { reveal: true }); return Promise.resolve(); }
    return refresh();
  }
  function goBack(steps = 1) {
    if (!state.back.length) return false;
    const from = snapshot();
    steps = Math.min(steps, state.back.length);
    let target = null;
    for (let i = 0; i < steps; i++) { state.forward.push(snapshot()); target = state.back.pop(); Object.assign(state, target); }
    restore(target, from);
    return true;
  }
  function goForward(steps = 1) {
    if (!state.forward.length) return false;
    const from = snapshot();
    steps = Math.min(steps, state.forward.length);
    let target = null;
    for (let i = 0; i < steps; i++) { state.back.push(snapshot()); target = state.forward.pop(); Object.assign(state, target); }
    restore(target, from);
    return true;
  }
  // 검색 입력 (DESIGN §5.1·§5.2): 타이핑마다 히스토리를 쌓지 않는다. focus → search 순간에만. 60ms 디바운스.
  let composing = false;
  function onQueryInput(value) {
    const has = !!value.trim();
    if (state.mode === 'focus' && has) pushBack();
    else if (has && brainOn && isBrainMode(state.mode) && !state.query.trim()) pushBack();   // v0.6 N: 홈·지도에서 검색으로 들어갈 때
    if (has && brainOn && isBrainMode(state.mode)) { state.prevMode = state.mode; closeWhy(false); }  // esc로 돌아갈 화면
    const prevMode = state.mode;
    state.query = value;
    state.mode = has ? 'search' : brainOn ? restMode() : 'global';
    if (!has && brainOn) renderModes();
    if (!has || prevMode === 'focus') state.focusId = null;
    state.selectedId = null;
    el.searchBox.classList.toggle('has-query', has);
    clearTimeout(queryTimer);
    queryTimer = setTimeout(() => refresh({ typing: true }), 60);
  }

  // 리더 / 읽기 모드
  function setReaderOpen(open) {
    if (isWide()) { wideReader = !!open; renderLayout(); renderNav(); return; }
    state.readerOpen = !!open;
    if (!narrow) wideReaderPref = state.readerOpen;
    renderLayout(); renderNav();
  }
  function setReading(on) {
    on = !!on && !!state.selectedId;
    if (state.reading === on) return;
    state.reading = on;
    renderLayout(); renderReader(); renderNav();
    if (on) { el.readerScroll.scrollTop = 0; scrollToStop(); track('view', state.selectedId); }
  }

  // 주제(묶음) 필터: 클릭 토글, ⌥클릭 = 그것만. 마지막 하나를 끄면 모두 켠다(v0.2와 같게).
  function toggleGroups(keys, solo) {
    const all = legendCache.flatMap(e => e.keys);
    const isOn = k => !state.hidden.has(k);
    if (solo) {
      const onlyThese = all.every(g => keys.includes(g) ? isOn(g) : !isOn(g));
      state.hidden = onlyThese ? new Set() : new Set(all.filter(g => !keys.includes(g)));
    } else if (keys.some(isOn)) {
      keys.forEach(k => state.hidden.add(k));
      if (all.every(g => state.hidden.has(g))) state.hidden = new Set();
    } else keys.forEach(k => state.hidden.delete(k));
    refresh({ resetScroll: false });
  }

  // 창 숨기기 · 토스트
  let toastTimer = 0;
  function toast(msg, tone, ms) {
    el.toast.textContent = msg;
    el.toast.classList.toggle('is-error', tone === 'error');
    el.toast.classList.remove('has-action'); undoPending = null;
    el.toast.classList.add('visible');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => el.toast.classList.remove('visible'), ms || (tone === 'error' ? 4200 : 2600));
  }
  // 화면 전환 때 토스트 닫기(되돌리기도 함께 끝난다)
  function hideToast() { clearTimeout(toastTimer); el.toast.classList.remove('visible', 'has-action'); undoPending = null; }
  function hideWindow() {
    if (!post({ action: 'hide' })) toast('앱에서는 창이 숨겨지고 ' + (el.hotkey.textContent || '⌃⌥Space') + '로 다시 열려요');
  }

  // esc 사다리 (DESIGN §5.4 + 자료 패널): 패널 → 읽기 모드 → 서랍 → 전체로 초기화 → 창 숨기기
  function escapeLadder() {
    if (whyState) { closeWhy(true); return; }
    if (sheetOpen) { closeSheet(); return; }
    if (aiPanelOpen()) { closeAIPanel(); return; }   // v0.8: 시키기 패널 먼저
    if (onboarding) { hideWindow(); return; }
    if (editVisible()) { editEscape(); return; }
    if (state.reading) { setReading(false); return; }
    if (drawerCovering()) { setReaderOpen(false); return; }
    if (brainOn) {   // v0.5: 검색·포커스 → (지도·이번 주·정리함) → 홈 → 창 숨기기
      if (state.mode === 'search' || state.mode === 'focus' || state.mode === 'cluster' || state.query) { clearTimeout(queryTimer); queryTimer = 0; pushBack(); setMode(restMode(), { force: true }); focusSearch(false); return; }
      if (state.mode !== 'home') { setMode('home'); return; }
      hideWindow(); return;
    }
    if (state.mode !== 'global' || state.query) { clearTimeout(queryTimer); queryTimer = 0; resetAll(); focusSearch(false); return; }
    hideWindow();
  }

  function focusSearch(selectAll) {
    if (el.search.disabled) return;
    el.search.focus({ preventScroll: true });
    if (selectAll) el.search.select();
  }

  // ===========================================================================
  // 키보드 (DESIGN §5.4) — 검색창에 포커스가 있어도 동작. 조합 중이면 아무것도 가로채지 않는다.
  // 한글 조합 중 ⇥·↵: 글자가 확정된 뒤 실행한다(compositionend, 120ms 대비 타이머).
  let deferred = null, deferTimer = 0, lastDeferred = { kind: null, at: 0 };
  function deferUntilCommitted(kind) {
    deferred = kind;
    clearTimeout(deferTimer);
    deferTimer = setTimeout(() => {
      if (!deferred) return;
      if (composing && document.activeElement === el.search) { el.search.blur(); focusSearch(false); } // 조합 강제 확정
      runDeferred();
    }, 120);
  }
  function runDeferred() {
    clearTimeout(deferTimer);
    const kind = deferred; deferred = null;
    if (!kind) return;
    composing = false;
    if (el.search.value !== state.query) onQueryInput(el.search.value);
    lastDeferred = { kind, at: performance.now() };
    whenSettled(() => {
      if (kind === 'follow') { if (state.selectedId) follow(state.selectedId); }
      else if (kind === 'back') goBack();
      else if (kind === 'read') { if (state.selectedId) setReading(true); }
    });
  }

  // 키 이름 대신 물리 키(e.code)도 본다: 한글 자판에서는 e.key가 자모(ㄹ·ㅣ·ㅜ·ㅔ)로 온다.
  const keyIs = (e, keys, code) => keys.includes(e.key) || e.code === code;
  const modalOpen = () => sheetOpen || onboarding;

  function onKeyDown(e) {
    const isTab = e.code === 'Tab' || e.key === 'Tab';
    const isEnter = e.code === 'Enter' || e.code === 'NumpadEnter' || e.key === 'Enter';
    if (!['Meta', 'Shift', 'Control', 'Alt', 'CapsLock'].includes(e.key)) lastKeyAt = Date.now();   // 홈 3초 순서 고정
    // AI 기록 시트(U2): 열려 있으면 그 시트가 키를 받는다(↵·⇥는 시트 버튼의 기본 동작)
    if (panelOpen()) {
      if (e.isComposing || e.keyCode === 229) return;
      const p = window.SynapseBrainPanel;
      if (safeMod(() => p.onKey(e)) === true) { e.preventDefault(); e.stopPropagation(); return; }
      if (e.key === 'Escape' || (e.metaKey && keyIs(e, ['y', 'Y'], 'KeyY'))) { e.preventDefault(); e.stopPropagation(); safeMod(() => p.closeLog()); }
      return;
    }
    // v0.6: 새 노트 창이 열려 있으면 그 창이 키를 받는다 · ⌘N = 새 노트 (입력칸 안팎·편집기 안 모두)
    if (window.SynapseNotes && window.SynapseNotes.isOpen()) { window.SynapseNotes.onKey(e); return; }
    if (e.metaKey && !e.ctrlKey && !e.altKey && !e.shiftKey && !e.isComposing && e.keyCode !== 229 && keyIs(e, ['n', 'N'], 'KeyN')) { e.preventDefault(); e.stopPropagation(); newNote(); return; }
    // v0.8: ⌘J = Claude에게 시키기 패널. 패널 안에서는 패널이 키를 받고 앱 단축키는 쓰지 않는다.
    if (aiPanelKey(e)) return;
    // 정리함·이번 주 모듈 안의 입력칸(목적지 고르기 등): 모듈에만 넘기고, 처리하지 않으면 입력칸 기본 동작
    if (mounted && e.target && e.target.closest && e.target.closest('#mod-list, #mod-reader') && e.target.closest('input, textarea, select, [contenteditable]')) {
      if (!(e.isComposing || e.keyCode === 229)) moduleKey(e);
      return;
    }
    // 자료 패널·첫 실행 안내: esc만 받고 나머지는 기본 동작(⇥ 포커스 이동, 입력)
    if (modalOpen()) {
      if (e.isComposing || e.keyCode === 229) return;
      if (e.key === 'Escape' && !e.metaKey && !e.ctrlKey && !e.altKey) {
        e.preventDefault(); e.stopPropagation();
        if (sheetOpen && cancelConfirm()) return;
        if (sheetOpen && fmt.id) { closeFmt(true); return; }
        escapeLadder();
      } else if (sheetOpen && isTab) trapFocus(e);
      return;
    }
    // 왜? 팝오버: 단일 문자 키(p·d·w·r·1·2)와 ↑↓·↵·esc는 팝오버가 받는다
    if (whyState && onWhyKey(e)) return;
    // 원문 편집기·편집 막대: 편집에 필요한 키는 가로채지 않는다(↑↓·↵·⌘[ 등은 글 편집). ⌘S 저장, esc 취소, ⇥ 들여쓰기만.
    if (edit && e.target === edit.ta && window.SynapseNotes && window.SynapseNotes.completeKey(e)) return;   // v0.6: [[ 자동완성 목록이 떠 있으면 ↑↓ ↵ ⇥ esc는 목록 몫
    if (edit && e.target && (e.target === edit.ta || (e.target.closest && e.target.closest('.edit-bar')))) { onEditorKey(e, e.target === edit.ta); return; }
    if (e.isComposing || e.keyCode === 229) {
      if (e.target !== el.search || e.metaKey || e.ctrlKey || e.altKey) return;
      if (isTab) { e.preventDefault(); deferUntilCommitted(e.shiftKey ? 'back' : 'follow'); }
      else if (isEnter) deferUntilCommitted('read'); // ↵는 IME가 확정에 써야 하므로 막지 않는다
      return;
    }
    const meta = e.metaKey, ctrl = e.ctrlKey, alt = e.altKey, shift = e.shiftKey;
    const k = e.key;
    // 조합 확정 직후 같은 키가 한 번 더 오는 경우(일부 엔진) 중복 실행 방지
    if ((isTab || isEnter) && !meta && !ctrl && !alt) {
      if (deferred) { e.preventDefault(); runDeferred(); return; }
      const kind = isEnter ? 'read' : shift ? 'back' : 'follow';
      if (lastDeferred.kind === kind && performance.now() - lastDeferred.at < 250) { e.preventDefault(); return; }
    }
    const inInput = e.target === el.search;
    const onButton = !inInput && e.target && e.target.closest && e.target.closest('button');
    const stop = () => { e.preventDefault(); e.stopPropagation(); };
    // v0.5 사서 키: ⌘1~⌘4 · ⌘Y · ⌘/ · ⌘↑/⌘↓ · ⌘⇧K · ⌥⌘Z · ⌘⇧C · 홈(↑↓ ↵ ⇥ →) · 지도(↑↓) · 정리함·이번 주 모듈
    if (brainKey(e, { meta, ctrl, alt, shift, isEnter, isTab, inInput, onButton, stop })) return;

    // 원본 열기: ⌘↵ · ⌘O (기본 앱/옵시디언/브라우저), ⌥⌘R (Finder에서 보기)
    if (meta && alt && !ctrl && keyIs(e, ['r', 'R'], 'KeyR')) { stop(); whenSettled(() => openSelected('reveal')); return; }
    if (meta && !ctrl && !alt && (isEnter || keyIs(e, ['o', 'O'], 'KeyO'))) { stop(); whenSettled(() => openSelected('default')); return; }
    if (meta && !ctrl && !alt) {
      if (keyIs(e, ['e', 'E'], 'KeyE') && !shift) { stop(); whenSettled(enterEdit); return; }
      if (keyIs(e, ['s', 'S'], 'KeyS') && !shift) { stop(); if (editVisible()) saveEdit(); return; }
      if (keyIs(e, ['['], 'BracketLeft')) { stop(); goBack(); return; }
      if (keyIs(e, [']'], 'BracketRight')) { stop(); goForward(); return; }
      // v0.6 N: ⌘←/⌘→ = 뒤로/앞으로 (검색창에 글이 있으면 커서 이동이니 건드리지 않는다)
      if (!shift && (k === 'ArrowLeft' || k === 'ArrowRight') && !(inInput && el.search.value)) { stop(); navStep(k === 'ArrowLeft' ? 'back' : 'forward'); return; }
      // ⌘⌫ = 선택한 문서를 휴지통으로 (검색창에 글이 있으면 글 지우기)
      if (!shift && k === 'Backspace' && !(inInput && el.search.value)) { stop(); if (state.selectedId) trashDoc(state.selectedId); return; }
      if (!shift && keyIs(e, ['z', 'Z'], 'KeyZ') && undoPending && Date.now() < undoPending.until && !(inInput && el.search.value)) { stop(); runUndoPending(); return; }
      if (keyIs(e, ['f', 'F'], 'KeyF') || keyIs(e, ['l', 'L'], 'KeyL')) { stop(); focusSearch(true); return; }
      if (keyIs(e, ['\\'], 'Backslash')) { stop(); setReaderOpen(!readerVisible()); return; }
      if (keyIs(e, ['=', '+'], 'Equal') || e.code === 'NumpadAdd') { stop(); if (graph) safe(() => graph.zoomBy(1.2)); return; }
      if (keyIs(e, ['-', '_'], 'Minus') || e.code === 'NumpadSubtract') { stop(); if (graph) safe(() => graph.zoomBy(1 / 1.2)); return; }
      if (keyIs(e, ['0'], 'Digit0') || e.code === 'Numpad0') { stop(); if (graph) safe(() => graph.fit({ animate: true })); return; }
      return; // ⌘C·⌘V·⌘A·⌘Z 등은 그대로
    }
    if (ctrl && !meta && !alt && !shift) {
      if (keyIs(e, ['n', 'N'], 'KeyN')) { stop(); whenSettled(() => moveSelection(1)); return; }
      if (keyIs(e, ['p', 'P'], 'KeyP')) { stop(); whenSettled(() => moveSelection(-1)); return; }
      return;
    }
    if (meta || ctrl || alt) return;
    if (isEnter) { if (onButton) return; stop(); whenSettled(() => { if (state.selectedId) setReading(true); else if (state.selCluster) expandCluster(state.selCluster); }); return; }
    if (isTab) { stop(); whenSettled(() => { if (shift) goBack(); else if (state.selectedId) follow(state.selectedId); else if (state.selCluster) expandCluster(state.selCluster); }); return; }
    switch (k) {
      case 'ArrowDown': stop(); whenSettled(() => moveSelection(1)); return;
      case 'ArrowUp': stop(); whenSettled(() => moveSelection(-1)); return;
      case 'Escape': stop(); escapeLadder(); return;
    }
    // 입력창 밖에서 글자를 치면 검색창으로 (Spotlight처럼)
    if (!inInput && k.length === 1 && k !== ' ' && !(e.target && e.target.closest && e.target.closest('input, textarea'))) focusSearch(false);
  }

  // ---------------------------------------------------------------------------
  // 마우스
  function bindEvents() {
    document.addEventListener('keydown', onKeyDown, true);

    el.search.addEventListener('compositionstart', () => { composing = true; });
    el.search.addEventListener('compositionend', () => {
      composing = false;
      if (el.search.value !== state.query) onQueryInput(el.search.value);
      if (deferred) setTimeout(runDeferred, 0); // 확정 뒤 마지막 input 이벤트까지 반영한 다음 실행
    });
    // compositionend 없이 조합이 끝나는 경우(창 숨김·포커스 이동)에도 플래그가 남지 않게
    el.search.addEventListener('blur', () => { composing = false; });
    // 조합 중에도 input마다 검색한다(입력창 값에 조합 중 글자 포함)
    el.search.addEventListener('input', () => onQueryInput(el.search.value));
    el.clear.addEventListener('mousedown', e => e.preventDefault());
    el.clear.addEventListener('click', () => { el.search.value = ''; onQueryInput(''); refresh(); focusSearch(false); });

    // 목록: 클릭 = 선택, 더블클릭 = 읽기, hover = 그래프 강조. 포커스는 검색창에 둔다.
    el.results.addEventListener('mousedown', e => { if (e.target.closest('.item, .h-row, .h-card') && !e.target.closest('button')) e.preventDefault(); });
    el.results.addEventListener('click', e => {
      if (e.target.closest('[data-hact]')) return;   // 홈 버튼은 아래 위임 처리기가 맡는다
      const hr = e.target.closest('[data-hkey]');
      if (hr && state.mode === 'home') {
        homeSelect(hr.dataset.hkey, { scroll: false });
        const it = homeItem();
        if (it && it.docId != null) track('view', it.docId);
        return;
      }
      const fr = e.target.closest('[data-fkey]');
      if (fr && state.mode === 'map') { mapSelect(fr.dataset.fkey, { reveal: true, scroll: false }); return; }
      const it = e.target.closest('.item');
      if (it) { selectUser(it.dataset.id, { reveal: true, scroll: false }); track('view', it.dataset.id); return; }
      const act = e.target.closest('[data-act]');
      if (act) doAct(act.dataset.act, act);
    });
    el.results.addEventListener('dblclick', e => {
      if (e.target.closest('button')) return;
      const hr = e.target.closest('[data-hkey]');
      if (hr && state.mode === 'home') { homeSelect(hr.dataset.hkey, { scroll: false }); homeEnter(); return; }
      const fr = e.target.closest('[data-fkey]');
      if (fr && state.mode === 'map') { mapSelect(fr.dataset.fkey, { scroll: false }); if (state.selectedId) setReading(true); return; }
      const it = e.target.closest('.item'); if (it) { select(it.dataset.id, { scroll: false }); setReading(true); }
    });
    el.results.addEventListener('mouseover', e => {
      const it = e.target.closest('.item'), id = it ? it.dataset.id : null;
      if (id === hoverId) return;
      hoverId = id;
      if (graph) safe(() => graph.setHover(id));
    });
    el.results.addEventListener('mouseleave', () => { hoverId = null; if (graph) safe(() => graph.setHover(null)); });

    // 키워드 칩 · 리더 태그 · 빈 상태 제안 · 모든 data-act 버튼
    // v0.5: 홈·흐름 상세·왜? 팝오버의 data-hact 버튼, 헤더 모드 전환, 지도 범례·보관본, U2 모듈 영역은 앱 위임에서 뺀다
    document.addEventListener('click', e => {
      const h = e.target.closest('[data-hact]');
      if (h && !h.disabled) onHomeAct(h.dataset.hact, h);
    });
    el.modes.addEventListener('click', e => { const b = e.target.closest('[data-mode]'); if (b) setMode(b.dataset.mode); });
    el.gArchive.addEventListener('click', () => { archiveShown = !archiveShown; pushGraph(); renderNav(); });
    el.gDone.addEventListener('click', () => toggleShowDone());
    if (window.ResizeObserver) new ResizeObserver(() => { if (view) syncGraphPad(!el.gStatus.hidden); }).observe(el.legend);   // 범례 높이가 바뀌면 그래프 아래 여백도
    // 묶음 요약의 문서 줄: 클릭 = 그 문서 선택
    el.readerInner.addEventListener('click', e => {
      const row = e.target.closest('[data-cdoc]');
      if (row && selectable(row.dataset.cdoc)) select(row.dataset.cdoc, { reveal: true, scroll: false });
      const cr = e.target.closest('[data-ccluster]');
      if (cr) selectCluster(cr.dataset.ccluster);
      const sr = e.target.closest('[data-sdoc]');   // v0.7 E: 끝난 티켓 목록의 줄 = 그 티켓 열기 (⌘[ 로 목록으로 돌아온다)
      if (sr) follow(sr.dataset.sdoc);
    });
    el.whyPop.addEventListener('submit', e => { e.preventDefault(); submitRename(); });
    document.addEventListener('mousedown', e => { if (whyState && !el.whyPop.contains(e.target) && !e.target.closest('[data-hkey], [data-fkey]')) closeWhy(false); }, true);
    const inModule = n => !!(n && n.closest && (n.closest('#mod-list') || n.closest('#mod-reader') || n.closest('#brain-settings') || n.closest('#ai-settings') || n.closest('.ap')));
    // v0.8: Claude 연결 단추(data-ai-act)는 여기서 한 번에 받는다 — ai.js 안내 띠의 설정 열기·다시 시도, 홈 브리핑, 리더 요약
    document.addEventListener('click', e => {
      const b = e.target.closest && e.target.closest('[data-ai-act]');
      if (b && !b.disabled && !e.defaultPrevented) aiAct(b.dataset.aiAct, b, e);   // 이번 주·티켓의 retry·regen은 그 모듈이 preventDefault로 처리한다
    });
    if (el.aiBtn) el.aiBtn.addEventListener('click', () => toggleAIPanel());
    document.addEventListener('click', e => {
      if (inModule(e.target)) return;
      const chip = e.target.closest('[data-tag]');
      if (chip) { searchTag(chip.dataset.tag); return; }
      const act = e.target.closest('[data-act]');
      if (act && !el.results.contains(act)) doAct(act.dataset.act, act);
    });

    // 리더 연결 행: 클릭 = 선택(그래프에 없으면 그 문서로 중심 이동), 더블클릭 = 중심 이동
    el.readerInner.addEventListener('click', e => {
      if (readerMdClick(e)) return;   // v0.6: 본문 [[링크]]·바깥 링크·체크박스·새 노트 제안
      const row = e.target.closest('[data-rel]');
      if (!row) return;
      const id = row.dataset.rel;
      if (view.items.has(id)) selectUser(id, { reveal: true }); else follow(id);
    });
    el.readerInner.addEventListener('dblclick', e => {
      const row = e.target.closest('[data-rel]');
      if (row && !(state.mode === 'focus' && state.focusId === row.dataset.rel)) follow(row.dataset.rel);
    });
    el.followBtn.addEventListener('click', () => (state.selCluster && !state.selectedId ? expandCluster(state.selCluster) : follow(state.selectedId)));
    el.openBtn.addEventListener('click', () => openSelected('default'));
    el.revealBtn.addEventListener('click', () => openSelected('reveal'));

    // 그래프 오버레이
    el.backBtn.addEventListener('click', () => goBack());
    el.crumbs.addEventListener('click', e => {
      const b = e.target.closest('[data-steps]');
      if (!b) return;
      const n = Number(b.dataset.steps);
      if (n < 0) resetAll(); else goBack(n);
    });
    el.tagsBtn.addEventListener('click', () => { state.showTags = !state.showTags; renderNav(); pushGraph(); });
    el.depthSeg.addEventListener('click', e => {
      const b = e.target.closest('[data-depth]');
      if (!b) return;
      const d = Number(b.dataset.depth);
      if (d !== state.depth) { state.depth = d; refresh({ resetScroll: false }); }
    });
    el.readerBtn.addEventListener('click', () => setReaderOpen(!readerVisible()));
    el.legend.addEventListener('click', e => {
      const f = e.target.closest('[data-fkey]');
      if (f) { mapSelect(mapSel === f.dataset.fkey ? null : f.dataset.fkey, { reveal: true }); return; }
      const b = e.target.closest('[data-legend]');
      const entry = b && legendCache[Number(b.dataset.legend)];
      if (entry) toggleGroups(entry.keys, e.altKey);
    });
    el.zoomIn.addEventListener('click', () => graph && safe(() => graph.zoomBy(1.2)));
    el.zoomOut.addEventListener('click', () => graph && safe(() => graph.zoomBy(1 / 1.2)));
    el.zoomFit.addEventListener('click', () => graph && safe(() => graph.fit({ animate: true })));
    el.zoomPct.addEventListener('click', () => { if (graph) { const k = safe(() => graph.getZoom()) || 1; safe(() => graph.zoomBy(1 / k)); } });

    // 헤더 버튼 · 푸터 상태
    el.pin.addEventListener('click', () => applyPinned(!state.pinned, true));
    el.hide.addEventListener('click', hideWindow);
    el.srcBtn.addEventListener('click', () => sheetOpen ? closeSheet() : openSheet());
    el.status.addEventListener('click', () => openSheet());
    // 버튼 클릭 후 포커스가 버튼에 남아 ↵·⇥를 가로채지 않게 검색창으로 돌려준다(패널·안내·리더 안은 예외)
    document.addEventListener('mouseup', e => {
      const b = e.target.closest && e.target.closest('button');
      if (!b || el.readerInner.contains(b) || el.scrim.contains(b) || el.onboard.contains(b) || inModule(b) || el.whyPop.contains(b) || b.closest('.bp-scrim')) return;
      setTimeout(() => { if (document.activeElement === b && !modalOpen()) focusSearch(false); }, 0);
    });

    // 자료 패널: 바깥(어두운 막) 클릭 = 닫기, Atlassian 양식 제출
    el.scrim.addEventListener('mousedown', e => { if (e.target === el.scrim) { e.preventDefault(); closeSheet(); } });
    el.atlForm.addEventListener('submit', e => { e.preventDefault(); submitAtlassian(); });
    el.atlForm.addEventListener('input', () => { if (atl.error) { atl.error = ''; renderAtlForm(); } });
    el.srcList.addEventListener('change', onFmtChange);
    el.mcpPanel.addEventListener('change', e => { if (e.target.name === 'mcp-site') mcp.pick = Number(e.target.value) || 0; });
    el.mcpPanel.addEventListener('dblclick', e => { if (e.target.closest('.site')) pickSite(); });

    // 창 끌기 (DESIGN §8): [data-drag-region]의 비대화형 빈 곳에서 왼쪽 버튼 mousedown
    document.addEventListener('mousedown', e => {
      if (e.button !== 0) return;
      const region = e.target.closest && e.target.closest('[data-drag-region]');
      if (!region) return;
      if (e.target.closest('input, textarea, button, a, select, [role="option"], [contenteditable], .search')) return;
      e.preventDefault();
      if (e.detail >= 2) post({ action: 'resetWindowFrame' });
      else post({ action: 'startDrag' });
    });

    // 기본 컨텍스트 메뉴 금지 (입력창·리더 본문 텍스트는 예외). v0.6 N: 문서 줄 위에서는 Synapse 메뉴를 연다.
    document.addEventListener('contextmenu', e => {
      if (e.target.closest && e.target.closest('input, textarea, .reader-body, .reader-title, .src-detail, .cmd-c')) return;
      e.preventDefault();
      safe(() => onDocContext(e));
    });
    bindNavEvents();

    window.addEventListener('resize', onResize);
    window.addEventListener('resize', () => { if (whyState) positionWhy(); });
    // 라이트/다크 전환 → 그래프 색 다시 읽기
    const mq = window.matchMedia('(prefers-color-scheme: dark)');
    const onScheme = () => { if (graph) requestAnimationFrame(() => safe(() => graph.refreshTheme())); };
    if (mq.addEventListener) mq.addEventListener('change', onScheme); else if (mq.addListener) mq.addListener(onScheme);
    // 상대 시각(‘3분 전 갱신’)을 가끔 새로 쓴다
    setInterval(() => { if (sheetOpen) renderSourceList(); }, 30000);
  }

  function doAct(act, node) {
    const rowId = node && node.closest('[data-src]') ? node.closest('[data-src]').dataset.src : null;
    switch (act) {
      case 'all-topics': state.hidden = new Set(); refresh(); break;
      case 'cluster-expand': expandCluster(state.selCluster); break;
      case 'show-done': toggleShowDone(true); break;
      case 'retry': refresh(); break;
      case 'reading': setReading(!state.reading); break;
      case 'close-reader': if (state.reading) setReading(false); else setReaderOpen(false); break;
      case 'open-default': openSelected('default'); break;
      case 'doc-menu': { const r = node.getBoundingClientRect(); if (state.selectedId) openDocMenu(state.selectedId, r.right, r.bottom + 4, 'reader'); break; }
      case 'open-obsidian': openSelected('obsidian'); break;   // v0.6: 옵시디언에서 열기 (메뉴에서만)
      case 'new-note': newNote(); break;
      case 'sources': openSheet(); break;
      case 'close-sheet': closeSheet(); break;
      case 'add-folder': addSource('folder'); break;
      case 'add-obsidian': addSource('obsidian'); break;
      case 'add-atlassian': openSheet({ atlassian: true }); break;
      case 'add-mcp': startMcpLogin(); break;
      case 'mcp-cancel': cancelMcp(); break;
      case 'mcp-retry': startMcpLogin(true); break;
      case 'mcp-site': pickSite(); break;
      case 'mcp-register': mcpRegister(node.closest('[data-client]') && node.closest('[data-client]').dataset.client); break;
      case 'mcp-copy': copyCommand(node); break;
      case 'pref-autohide': toggleAutoHide(); break;
      case 'notice-dismiss': dismissNotice(rowId); break;
      case 'fmt-open': openFmt(rowId, node.closest('.notice') ? 'notice' : 'row'); break;
      case 'fmt-cancel': closeFmt(true); break;
      case 'fmt-retry': fmt.id = null; openFmt(rowId); break;
      case 'fmt-apply': applyFmt(); break;
      case 'edit': enterEdit(); break;
      case 'edit-save': saveEdit(); break;
      case 'edit-cancel': editEscape(); break;
      case 'edit-keep': if (edit) { edit.confirm = false; renderEditBar(); focusEditor(); } break;
      case 'edit-discard': dropEdit(true); break;
      case 'edit-reload': reloadEdit(false); break;
      case 'edit-reload-confirm': reloadEdit(true); break;
      case 'edit-copy': copyDraft(); break;
      case 'edit-away-ask': setAwayConfirm(true); break;
      case 'edit-away-keep': setAwayConfirm(false); break;
      case 'edit-away-discard': dropEdit(false); toast('편집한 내용을 버렸어요'); break;
      case 'edit-overwrite': overwriteEdit(); break;
      case 'edit-return': returnToEdit(); break;
      case 'demo': startDemo(); break;
      case 'atl-help': openHelp(); break;
      case 'atl-cancel': closeAtlForm(); break;
      case 'src-reindex': reindexSource(rowId); break;
      case 'src-toggle': toggleSource(rowId); break;
      case 'src-remove': if (fmt.id === rowId) closeFmt(false); confirmId = rowId; renderSourceList(); focusConfirm(); break;
      case 'src-remove-cancel': cancelConfirm(); break;
      case 'src-remove-confirm': removeSource(rowId); break;
      case 'reindex-all': reindexSource(null); break;
    }
  }

  let resizeFrame = 0;
  function onResize() {
    cancelAnimationFrame(resizeFrame);
    resizeFrame = requestAnimationFrame(() => { if (view) renderNav(); });
    const n = window.innerWidth < 1040;
    if (n === narrow) return;
    narrow = n;
    state.readerOpen = narrow ? false : wideReaderPref;
    renderLayout(); renderNav();
  }

  // ===========================================================================
  // 상태 표시 · 엔진 이벤트 (CONNECT §8 진행 표시)
  function normStatus(st) {
    st = parse(st) || {};
    const sources = (Array.isArray(st.sources) ? st.sources : []).filter(s => s && s.id != null).map(s => Object.assign({}, s, { id: String(s.id) }));
    return { sources, docCount: Number(st.docCount) || 0, indexing: !!st.indexing };
  }
  const findSrc = id => ((libStatus && libStatus.sources) || []).find(s => s.id === String(id)) || null;
  const busyState = s => s.enabled !== false && (s.state === 'indexing' || s.state === 'syncing');
  function progressInfo() {
    let done = 0, total = 0;
    ((libStatus && libStatus.sources) || []).forEach(s => {
      const p = s.progress;
      if (busyState(s) && p && Number(p.total) > 0) { done += Math.min(Number(p.done) || 0, Number(p.total)); total += Number(p.total); }
    });
    return { done, total, pct: total ? Math.min(100, Math.floor(done / total * 100)) : 0, label: total ? '색인 중 ' + num(done) + ' / ' + num(total) : '' };
  }

  function renderStatus() {
    let text, tone = '', bar = null, title = '자료 연결 보기';
    const st = libStatus || { sources: [], docCount: 0 };
    if (source && source.kind === 'demo') text = source.statusText;
    else if (onboarding) text = '연결한 자료 없음';
    else if (!source) text = '불러오는 중…';
    else if (libraryBusy()) {
      const p = progressInfo();
      const syncing = st.sources.some(s => busyState(s) && s.state === 'syncing');
      text = p.total ? '색인 중 ' + p.pct + '%' : syncing ? '동기화 중…' : '색인 준비 중…';
      bar = p.total ? p.pct : -1; title = p.label || '색인 준비 중'; tone = 'busy';
    } else text = '문서 ' + num(st.docCount) + '개 · 출처 ' + st.sources.length;
    const bad = source && source.kind === 'native' ? st.sources.find(s => s.state === 'error') : null;
    if (bad) { tone = tone || 'error'; title = bad.name + ' · ' + (bad.error || '오류가 났어요'); }
    el.statusText.textContent = text;
    el.status.dataset.tone = tone;
    el.status.title = title;
    el.statusBar.hidden = bar == null;
    el.statusBar.classList.toggle('is-indeterminate', bar === -1);
    if (bar != null && bar >= 0) el.statusBarFill.style.width = bar + '%';
    el.srcBtn.dataset.tone = bad ? 'error' : tone || (nativeSrc && liveNotices().length ? 'notice' : '');
  }

  let statusTimer = 0, statusSeq = 0, uiFrame = 0;
  function refreshStatus() {
    if (!nativeSrc) return Promise.resolve(null);
    const seq = ++statusSeq;
    return nativeSrc.status().then(st => {
      if (seq !== statusSeq) return libStatus;
      libStatus = normStatus(st);
      renderStatus(); renderSourceList();
      if (view && isNativeView() && !view.order.length) { renderGraphEmpty(); renderList(); }
      return libStatus;
    }, e => { console.warn('[synapse] status:', errMsg(e)); return null; });
  }
  function scheduleStatus(ms) { clearTimeout(statusTimer); statusTimer = setTimeout(refreshStatus, ms == null ? 150 : ms); }
  // 진행 이벤트는 자주 오므로 한 프레임에 한 번만 그린다
  function scheduleStatusUI() {
    if (uiFrame) return;
    const run = () => { uiFrame = 0; renderStatus(); renderSourceList(); if (view && isNativeView() && !view.order.length) renderGraphEmpty(); };
    uiFrame = document.hidden ? setTimeout(run, 100) : requestAnimationFrame(run);
  }

  function onLibraryEvent(evt) {
    if (!nativeSrc) return;
    if (probe.pending) { runProbe(); return; }
    if (evt.type === 'progress') {
      const s = findSrc(evt.sourceId);
      if (!s) { scheduleStatus(); return; }
      s.progress = { done: Number(evt.done) || 0, total: Number(evt.total) || 0, phase: evt.phase || '' };
      if (s.state !== 'syncing') s.state = /sync|remote|fetch/i.test(String(evt.phase || '')) || isRemoteKind(s.kind) ? 'syncing' : 'indexing';
      s.error = null;
      libStatus.indexing = true;
      scheduleStatusUI();
    } else if (evt.type === 'changed') {
      rawInfo.clear();
      refreshStatus().then(st => {
        afterStatus(st, 'changed');
        // 시작할 때 폴더 → 볼트로 바뀐 출처: 패널이 닫혀 있으면 한 번 알려 준다(자세한 안내는 자료와 설정에)
        if (evt.reason === 'source-migrated' && st && !sheetOpen) {
          const s = liveNotices()[0];
          if (s) toast('‘' + s.name + '’' + pp(s.name, '을', '를') + ' 옵시디언 볼트로 인식했어요 · 자료와 설정에서 형식을 바꿀 수 있어요', '', 6000);
        }
      });
    } else if (evt.type === 'error') {
      const s = findSrc(evt.sourceId), msg = String(evt.message || '자료를 읽다가 문제가 생겼어요.');
      if (s) { s.state = 'error'; s.error = msg; s.progress = null; }
      toast((s ? s.name + ' · ' : '') + msg, 'error');
      scheduleStatusUI(); scheduleStatus(600);
    }
  }

  // 출처 수에 따라 화면 출처를 고른다: 1개 이상 → 네이티브, 0개 → 첫 실행 안내
  let silentTimer = 0;
  function afterStatus(st, why) {
    if (!st) return;
    const n = st.sources.length;
    if (probe.pending) { probe.pending = false; clearTimeout(probe.timer); } // 다른 경로로 status가 되살아남
    if (n && source !== nativeSrc) { activate(nativeSrc, 'native'); return; }
    if (!n && sourceReason === 'native-pending') { showOnboarding(); return; }
    if (!n && source === nativeSrc) { showOnboarding(); return; }
    if (source === nativeSrc && why === 'changed') {
      // 현재 보기를 조용히 새로 고침(선택·스크롤·읽기 모드 유지)
      clearTimeout(silentTimer);
      silentTimer = setTimeout(() => { clearDocs(); rawInfo.clear(); refresh({ silent: true }); }, 60);
    }
  }

  function resetStateForSource() {
    clearTimeout(queryTimer); queryTimer = 0;
    reqSeq++; appliedSeq = reqSeq; docSeq++;
    clearDocs(); titles.clear(); graphKey = ''; el.lastReaderId = null;
    rawInfo.clear();
    // 바뀐 게 없는 편집만 닫는다. 저장하지 않은 초안은 남겨 배너(또는 첫 실행 안내)에서 이어 쓰거나 복사·버리게 한다.
    if (edit && !edit.dirty && !edit.saving) { edit = null; el.reader.classList.remove('is-editing', 'edit-dirty'); }
    else if (edit) { edit.pinned = false; el.reader.classList.remove('is-editing'); }
    Object.assign(state, { mode: 'global', query: '', focusId: null, selectedId: null, reading: false, back: [], forward: [], prevMode: null });
    state.hidden = new Set();
    resetBrainUI();
    el.search.value = '';
  }
  function activate(src, reason) {
    source = src; sourceReason = reason; onboarding = false;
    resetStateForSource();
    knownTags = src.tagCounts ? src.tagCounts() : new Map();
    view = adaptView(EMPTY_VM, '');
    view.loading = true; // 첫 응답 전: 이전 출처의 목록을 남기지 않되 '비어 있음' 문구도 띄우지 않는다
    renderOnboarding(); renderStatus();
    brainOn = false; renderModes();
    renderAll();
    // v0.5: 사서가 답하면 홈이 기본 화면, 아니면(사서 없음·실패) 예전처럼 전체 그래프
    const gen = ++activateGen;
    return probeBrain(src).then(h => {
      if (gen !== activateGen || src !== source) return;
      brainOn = !!h; homeData = h || null;
      if (brainOn) { state.mode = 'home'; state.prevMode = 'home'; }
      renderModes();
      if (brainOn) initAI(); else { aiStat = null; renderAIButton(); }   // v0.8: Claude 연결 상태 읽기
      return refresh();
    });
  }
  function showOnboarding() {
    source = null; sourceReason = 'onboarding'; onboarding = true;
    activateGen++; brainOn = false;
    resetStateForSource();
    knownTags = new Map();
    view = adaptView(EMPTY_VM, '');
    renderAll();
    renderOnboarding(); renderStatus();
  }
  function renderOnboarding() {
    renderOnboardDraft();
    el.onboard.hidden = !onboarding;
    el.app.classList.toggle('is-onboarding', onboarding);
    renderModes();
    el.search.disabled = onboarding;
    el.search.placeholder = onboarding ? '자료를 연결하면 여기에서 검색해요' : '키워드, 제목, 태그로 검색';
    if (onboarding && document.activeElement === el.search) el.search.blur();
  }
  // 첫 실행 안내로 돌아왔는데 저장하지 않은 초안이 있으면: 내용 복사 · 버리기(한 번 더 확인)
  function renderOnboardDraft() {
    const box = el.onboardDraft;
    if (!box) return;
    const show = onboarding && !!edit && edit.dirty;
    box.hidden = !show;
    if (!show) { box.innerHTML = ''; return; }
    const t = '<b>‘' + esc(edit.title) + '’</b>';
    box.innerHTML = icon('edit') + '<span>' + t + (edit.awayConfirm ? '의 변경을 버릴까요?' : '에 저장하지 않은 변경이 있어요') + '</span>' +
      (edit.awayConfirm ? '<button class="btn sm" type="button" data-act="edit-away-keep">취소</button><button class="btn sm danger" type="button" data-act="edit-away-discard">버리기</button>'
        : '<button class="btn sm" type="button" data-act="edit-copy">' + icon('copy') + '내용 복사</button><button class="btn sm" type="button" data-act="edit-away-ask">버리기</button>');
  }
  function startDemo() {
    activate(createDemoSource(window.SYNAPSE_DATA || { topics: {}, docs: [] }), nativeSrc ? 'demo-chosen' : 'browser');
    focusSearch(true);
  }
  function useDemoData(data) {
    if (source && source.kind !== 'demo') return; // 실제 자료를 보는 중이면 무시
    activate(createDemoSource(data), 'data');
  }

  // ===========================================================================
  // 자료 연결 패널 (CONNECT §8): 출처 목록 · 행 동작 · 추가 · Atlassian 양식
  let sheetOpen = false, confirmId = null, busyAdd = null, lastFocus = null;
  const atl = { open: false, busy: false, error: '' };
  // 진행 중인 addAtlassian: 양식을 닫았다 다시 열어도 지우지 않는다(토큰 이중 전송 방지). gen = 양식을 연 차례
  let atlFlight = null, atlGen = 0;
  const KIND_LABEL = { folder: '폴더', obsidian: '옵시디언 볼트', atlassian: 'Confluence·Jira', mcp: 'Confluence·Jira (MCP)' };

  function openSheet(opts = {}) {
    if (!sheetOpen) {
      sheetOpen = true;
      lastFocus = document.activeElement;
      el.scrim.hidden = false;
      el.app.classList.add('sheet-on');
      void el.scrim.offsetWidth;
      el.scrim.classList.add('visible');
      el.srcBtn.setAttribute('aria-expanded', 'true');
    }
    if (opts.atlassian) { if (mcp.phase && mcp.phase !== 'login' && mcp.phase !== 'connecting') cancelMcp(); openAtlForm(); } else renderAtlForm();
    renderSheet();
    renderMcp();
    renderBrainSettings();
    renderAISettings();   // v0.8: 사서 구역 아래 Claude 구역
    if (!opts.atlassian) el.sheet.focus({ preventScroll: true });
    if (nativeSrc) refreshStatus();
    loadPrefs(); loadMcpStatus();
    renderNav();
  }
  function closeSheet() {
    if (!sheetOpen) return;
    sheetOpen = false; confirmId = null;
    closeAtlForm();
    closeFmt(false);
    if (mcp.phase === 'error') { mcp.phase = null; renderMcp(); } // 기다리는 로그인·사이트 고르기는 다시 열면 이어서
    el.scrim.classList.remove('visible');
    el.app.classList.remove('sheet-on');
    el.srcBtn.setAttribute('aria-expanded', 'false');
    el.scrim.hidden = true;
    if (!onboarding) { if (editVisible()) focusEditor(); else focusSearch(false); } else if (lastFocus && lastFocus.focus && el.onboard.contains(lastFocus)) lastFocus.focus({ preventScroll: true });
    renderNav();
  }
  function cancelConfirm() {
    if (!confirmId) return false;
    const id = confirmId; confirmId = null; renderSourceList();
    const b = el.srcList.querySelector('[data-src="' + cssEsc(id) + '"] [data-act="src-remove"]');
    if (b) b.focus({ preventScroll: true });
    return true;
  }
  const cssEsc = s => (window.CSS && CSS.escape) ? CSS.escape(s) : String(s).replace(/["\\]/g, '\\$&');
  function focusConfirm() {
    const b = el.srcList.querySelector('.src-confirm [data-act="src-remove-cancel"]');
    if (b) b.focus({ preventScroll: true });
  }
  function trapFocus(e) {
    const list = [...el.sheet.querySelectorAll('button, input, textarea, summary, [tabindex="0"]')].filter(n => !n.disabled && n.offsetParent !== null);
    if (!list.length) return;
    const i = list.indexOf(document.activeElement);
    const next = e.shiftKey ? (i <= 0 ? list.length - 1 : i - 1) : (i < 0 || i === list.length - 1 ? 0 : i + 1);
    e.preventDefault();
    list[next].focus({ preventScroll: false });
  }

  function renderSheet() {
    if (!sheetOpen) return;
    renderSourceList();
    renderMcpServer();
    el.sheetAdd.querySelectorAll('[data-act^="add-"]').forEach(b => {
      const kind = b.dataset.act.slice(4);
      b.disabled = !!busyAdd;
      b.classList.toggle('is-busy', busyAdd === kind);
    });
  }

  function sourceStatusLine(s) {
    if (s.enabled === false) return { text: '꺼 둠 · 검색에 나오지 않아요', tone: 'off' };
    if (s.state === 'error') return { text: s.error || '자료를 읽지 못했어요', tone: 'error' };
    if (busyState(s)) {
      const p = s.progress || {}, phase = String(p.phase || '');
      const label = /scan|list|walk|discover/i.test(phase) ? '파일 찾는 중' : /relat|link/i.test(phase) ? '연결 계산 중'
        : s.state === 'syncing' || /sync|remote|fetch/i.test(phase) ? '가져오는 중' : '색인 중';
      const total = Number(p.total) || 0, done = Math.min(Number(p.done) || 0, total || Infinity);
      // 원격은 전체 수를 모를 수 있다(total 0) → 막대는 흐르게, 받은 건수만
      const text = total ? label + ' ' + num(done) + ' / ' + num(total) : done ? label + ' · ' + num(done) + '건' : label + '…';
      return { text, tone: 'busy', pct: total ? Math.floor(done / total * 100) : -1 };
    }
    const failed = Number(s.failed) > 0 ? ' · 읽지 못한 파일 ' + num(s.failed) : '';
    if (s.lastIndexed) return { text: relTime(s.lastIndexed) + ' 갱신' + failed, tone: '' };
    return { text: '색인 대기 중' + failed, tone: '' };
  }

  // 이 출처를 끊으면 저장할 곳이 사라지는 초안이 있나(그 출처의 문서이거나 마지막 출처)
  const draftAt = s => !!edit && edit.dirty && ((edit.doc && edit.doc.source === s.id) || (((libStatus && libStatus.sources) || []).length <= 1));
  // v0.9 겹친 출처 (docs/V09.md §3.1): 안쪽 출처가 이긴다 — 바깥 출처는 그 경로를 색인하지 않는다
  const nestNote = s => {
    const inner = Array.isArray(s.nests) ? s.nests.filter(Boolean).map(String) : [];
    let h = '';
    if (s.nestedIn) h += '<div class="src-nest" title="이 폴더는 ‘' + esc(s.nestedIn) + '’ 출처 안에 있어요. ‘' + esc(s.nestedIn) + '’은 이 경로를 색인하지 않고, 여기서만 색인해요">' + icon('info') + '<span>' + esc(s.nestedIn) + ' 안에 있어요 · 여기서 색인해요</span></div>';
    if (inner.length) h += '<div class="src-nest" title="' + esc(inner.join(', ')) + '">' + icon('info') + '<span>안쪽 출처 ' + inner.length + '개는 그 출처에서 색인해요</span></div>';
    return h;
  };
  function sourceRow(s) {
    const line = sourceStatusLine(s), confirm = confirmId === s.id;
    const what = s.kind === 'atlassian' ? '연결을 끊고 토큰도 키체인에서 지울까요?' : s.kind === 'mcp' ? '연결을 끊고 로그인 정보도 키체인에서 지울까요?' : '연결을 끊을까요?';
    return '<div class="src-row' + (s.enabled === false ? ' is-off' : '') + (confirm ? ' is-confirm' : '') + '" role="listitem" data-src="' + esc(s.id) + '" data-tone="' + line.tone + '">' +
      '<div class="src-ic" data-kind="' + esc(s.kind) + '">' + icon(sourceIcon(s.kind)) + '</div>' +
      '<div class="src-main">' +
        '<div class="src-name"><span class="src-title">' + esc(s.name || KIND_LABEL[s.kind] || '자료') + '</span><span class="src-kind">' + esc(KIND_LABEL[s.kind] || '') + '</span>' +
          '<span class="src-count" title="색인한 문서">문서 <b>' + num(s.docCount) + '</b>개</span></div>' +
        '<div class="src-detail" title="' + esc(s.detail || '') + '">' + esc(s.detail || '') + '</div>' +
        nestNote(s) +
        '<div class="src-status">' + (line.tone === 'error' ? icon('alert') : '') + '<span class="src-status-t">' + esc(line.text) + '</span></div>' +
        (line.tone === 'busy' ? '<div class="src-bar' + (line.pct < 0 ? ' is-indeterminate' : '') + '"><i style="width:' + Math.max(0, line.pct) + '%"></i></div>' : '') +
      '</div>' +
      (confirm
        ? '<div class="src-confirm" role="group" aria-label="연결 끊기 확인"><p><strong>‘' + esc(s.name) + '’ ' + what + '</strong> 색인만 지워지고 원본 ' + (isRemoteKind(s.kind) ? '페이지·이슈' : '파일') + '은 그대로예요.' +
          (draftAt(s) ? '<em class="src-confirm-draft">' + icon('edit') + '편집 중인 ‘' + esc(edit.title) + '’에 저장하지 않은 변경이 있어요. 연결을 끊으면 저장할 수 없으니 먼저 저장하세요(내용은 복사할 수 있어요).</em>' : '') + '</p>' +
          '<div class="src-confirm-b"><button class="btn" type="button" data-act="src-remove-cancel">취소</button><button class="btn danger" type="button" data-act="src-remove-confirm">연결 끊기</button></div></div>'
        : '<div class="src-actions">' +
          (canTune(s) ? '<button class="icon-btn sm" type="button" data-act="fmt-open" title="형식·폴더 · 색인할 형식과 뺄 폴더" aria-label="형식·폴더 설정" aria-expanded="' + (fmt.id === s.id) + '"' + (fmt.id === s.id ? ' aria-pressed="true"' : '') + (s.enabled === false ? ' disabled' : '') + '>' + icon('sliders') + '</button>' : '') +
          '<button class="icon-btn sm" type="button" data-act="src-reindex" title="처음부터 다시 색인" aria-label="다시 색인"' + (busyState(s) || s.enabled === false ? ' disabled' : '') + '>' + icon('refresh') + '</button>' +
          '<button class="switch" type="button" role="switch" data-act="src-toggle" aria-checked="' + (s.enabled !== false) + '" title="' + (s.enabled !== false ? '끄면 검색·그래프에서 빠져요' : '다시 켜기') + '" aria-label="검색에 포함"><i></i></button>' +
          '<button class="icon-btn sm is-danger" type="button" data-act="src-remove" title="연결 끊기" aria-label="연결 끊기">' + icon('trash') + '</button>' +
        '</div>') +
      (fmt.id === s.id && !confirm ? fmtPanelHtml(s) : '') +
    '</div>';
  }
  // 진행 이벤트가 잦으므로 구조가 같은 행은 글자·막대만 고친다(호버·포커스 유지)
  function rowKey(s) {
    const line = sourceStatusLine(s);
    const f = fmt.id === s.id ? ['fmt', fmt.loading, !!fmt.details, fmt.applying, fmt.applyError, fmt.error].join(':') : '';
    return [s.name, s.detail, s.kind, s.enabled !== false, line.tone, line.pct < 0, confirmId === s.id, busyState(s), f, confirmId === s.id && draftAt(s), s.nestedIn || '', (s.nests || []).join(',')].join('|');
  }
  function renderSourceList() {
    if (!sheetOpen) return;
    const st = libStatus || { sources: [], docCount: 0 };
    const srcs = nativeSrc ? st.sources : [];
    el.sheetSub.textContent = !nativeSrc ? '브라우저 미리보기' : srcs.length ? '문서 ' + num(st.docCount) + '개 · 출처 ' + srcs.length : '아직 연결한 자료가 없어요';
    if (!nativeSrc || !srcs.length) {
      renderNotices();
      el.srcList.innerHTML = '<div class="src-empty">' + icon('stack') + '<div><strong>' + (nativeSrc ? '연결한 자료가 없어요' : '앱에서 자료를 연결할 수 있어요') + '</strong><p>' +
        (nativeSrc ? '폴더·옵시디언 볼트·Confluence·Jira를 추가하면 원래 자리에서 읽어 한 그래프로 이어요.' : '브라우저 미리보기는 예시 자료만 보여 줘요. Synapse 앱에서 열면 폴더·옵시디언·Confluence·Jira를 연결할 수 있어요.') +
        '</p></div></div>';
      el.srcList.dataset.mode = 'empty';
      return;
    }
    if (el.srcList.dataset.mode !== 'list') { el.srcList.innerHTML = ''; el.srcList.dataset.mode = 'list'; }
    const existing = new Map([...el.srcList.children].map(n => [n.dataset.src, n]));
    let prev = null;
    srcs.forEach(s => {
      let row = existing.get(s.id);
      const key = rowKey(s);
      if (row && row.dataset.key === key) {
        const line = sourceStatusLine(s);
        const t = row.querySelector('.src-status-t'); if (t.textContent !== line.text) t.textContent = line.text;
        const c = row.querySelector('.src-count b'); if (c) c.textContent = num(s.docCount);
        const bar = row.querySelector('.src-bar i'); if (bar && line.pct >= 0) bar.style.width = line.pct + '%';
      } else {
        const had = row && row.contains(document.activeElement) ? document.activeElement.dataset.act : null;
        const tmp = document.createElement('div');
        tmp.innerHTML = sourceRow(s);
        const fresh = tmp.firstChild;
        fresh.dataset.key = key;
        if (row) row.replaceWith(fresh);
        row = fresh;
        if (had) { const f = row.querySelector('[data-act="' + had + '"]'); if (f && !f.disabled) f.focus({ preventScroll: true }); }
      }
      existing.delete(s.id);
      const want = prev ? prev.nextSibling : el.srcList.firstChild;
      if (want !== row) el.srcList.insertBefore(row, want);
      prev = row;
    });
    existing.forEach(n => n.remove());
    if (fmt.id && !findSrc(fmt.id)) { fmt.id = null; fmt.seq++; }
    syncFmtDom();
    renderNotices();
  }

  // 출처 동작 — 결과는 status()로 다시 확인한다
  const noBridge = () => toast('Synapse 앱에서 자료를 연결할 수 있어요 · 브라우저 미리보기는 예시 자료만 보여요');
  const okOrThrow = r => { r = parse(r); if (r && r.ok === false) throw new Error(r.error || '요청을 처리하지 못했어요.'); return r; };
  async function addSource(kind) {
    if (!nativeSrc) { noBridge(); return; }
    if (busyAdd) return;
    busyAdd = kind; renderSheet();
    try {
      const r = parse(await nativeSrc.addSource(kind));
      if (!r || r.cancelled) return;
      if (r.ok === false) { toast(r.error || '자료를 추가하지 못했어요.', 'error'); return; }
      const name = r.source && r.source.name;
      if (r.notice) toast(String(r.notice), '', 6000);
      else toast(r.warning ? String(r.warning) : (name ? '‘' + name + '’' + josa(name, '을', '를').slice(name.length) : '자료를') + ' 연결했어요 · 색인을 시작해요');
      afterStatus(await refreshStatus(), 'added');
    } catch (e) { toast(errMsg(e), 'error'); }
    finally { busyAdd = null; renderSheet(); }
  }
  function reindexSource(id) {
    if (!nativeSrc) return;
    const s = id ? findSrc(id) : null;
    if (s) { s.state = isRemoteKind(s.kind) ? 'syncing' : 'indexing'; s.progress = null; s.error = null; libStatus.indexing = true; renderSourceList(); renderStatus(); }
    nativeSrc.reindex(id).then(okOrThrow).then(() => scheduleStatus(300), e => { toast(errMsg(e), 'error'); scheduleStatus(0); });
  }
  function toggleSource(id) {
    const s = findSrc(id);
    if (!s || !nativeSrc) return;
    s.enabled = s.enabled === false;
    renderSourceList();
    nativeSrc.setSourceEnabled(id, s.enabled).then(okOrThrow)
      .then(() => refreshStatus().then(st => afterStatus(st, 'changed')), e => { toast(errMsg(e), 'error'); refreshStatus(); });
  }
  function removeSource(id) {
    const s = findSrc(id);
    if (!s || !nativeSrc) return;
    confirmId = null;
    libStatus.sources = libStatus.sources.filter(x => x.id !== s.id);
    renderSourceList(); renderStatus();
    nativeSrc.removeSource(id).then(okOrThrow)
      .then(() => { toast('‘' + s.name + '’ 연결을 끊었어요'); return refreshStatus().then(st => afterStatus(st, 'changed')); },
        e => { toast(errMsg(e), 'error'); refreshStatus(); });
  }
  function openHelp() {
    if (!nativeSrc) { toast('앱에서는 Atlassian 계정의 API 토큰 페이지가 열려요'); return; }
    nativeSrc.openHelp('atlassian-token').catch(e => toast(errMsg(e), 'error'));
  }

  // Atlassian 양식: 토큰은 비밀번호 칸, 기록하지 않고 닫을 때 지운다
  function openAtlForm() {
    atlGen++;
    atl.open = true; atl.error = ''; atl.busy = !!atlFlight;
    renderAtlForm();
    setTimeout(() => { if (!atl.open) return; el.atlSite.focus({ preventScroll: true }); el.atlForm.scrollIntoView({ block: 'nearest' }); }, 30);
  }
  function closeAtlForm() {
    const was = atl.open;
    atlGen++;
    atl.open = false; atl.busy = !!atlFlight; atl.error = '';
    el.atlForm.reset();
    renderAtlForm();
    if (was && sheetOpen) { const b = el.sheetAdd.querySelector('[data-act="add-atlassian"]'); if (b) b.focus({ preventScroll: true }); }
  }
  function renderAtlForm() {
    el.atlForm.hidden = !atl.open;
    syncAddArea();
    el.atlError.hidden = !atl.error;
    el.atlError.innerHTML = atl.error ? icon('alert') + '<span>' + esc(atl.error) + '</span>' : '';
    el.atlSubmit.disabled = atl.busy;
    el.atlSubmit.textContent = atl.busy ? '확인하는 중…' : '연결하기';
    el.atlForm.classList.toggle('is-busy', atl.busy);
    el.atlForm.querySelectorAll('input').forEach(i => { i.readOnly = atl.busy; });
    if (atl.error) requestAnimationFrame(() => el.atlError.scrollIntoView({ block: 'nearest' }));
  }
  function normSite(v) {
    v = String(v || '').trim().replace(/\/+$/, '');
    if (!v) return '';
    return /^https?:\/\//i.test(v) ? v : 'https://' + v;
  }
  async function submitAtlassian() {
    if (atl.busy || atlFlight) return;
    const site = normSite(el.atlSite.value), email = el.atlEmail.value.trim(), token = el.atlToken.value.trim();
    const bad = !site ? [el.atlSite, '사이트 주소를 적어 주세요.'] : !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) ? [el.atlEmail, '이메일 주소를 확인해 주세요.']
      : !token ? [el.atlToken, 'API 토큰을 붙여 넣어 주세요.'] : null;
    if (bad) { atl.error = bad[1]; renderAtlForm(); bad[0].focus(); return; }
    if (!nativeSrc) { atl.error = '브라우저 미리보기에서는 연결할 수 없어요. Synapse 앱에서 다시 시도해 주세요.'; renderAtlForm(); return; }
    const form = { site, email, token };
    const spaces = el.atlSpaces.value.split(/[,\s]+/).map(x => x.trim()).filter(Boolean);
    if (spaces.length) form.spaces = spaces;
    const jql = el.atlJql.value.trim();
    if (jql) form.jql = jql;
    const gen = atlGen, flight = {};
    atlFlight = flight;
    atl.busy = true; atl.error = ''; renderAtlForm();
    let r = null, err = null;
    try {
      r = parse(await nativeSrc.addAtlassian(form));
      if (!r || r.ok === false) throw new Error((r && r.error) || '연결하지 못했어요. 사이트 주소와 토큰을 확인해 주세요.');
    } catch (e) { err = errMsg(e); }
    if (atlFlight === flight) atlFlight = null;
    const same = gen === atlGen && atl.open; // 보낸 그 양식이 아직 열려 있나
    atl.busy = false;
    if (err) {
      if (same) { atl.error = err; renderAtlForm(); el.atlToken.focus(); }
      else { renderAtlForm(); toast(err, 'error'); }
      return;
    }
    if (same) closeAtlForm(); else renderAtlForm();
    const name = (r.source && r.source.name) || site.replace(/^https?:\/\//, '');
    toast('‘' + name + '’ 연결했어요 · 페이지와 이슈를 가져오는 중이에요');
    afterStatus(await refreshStatus(), 'added');
  }

  // ===========================================================================
  // v0.4 자료와 설정 (docs/V04.md §1·§2): 안내 배너 · 출처별 형식·제외 폴더 · 일반(자동 숨김)
  const KIND_NAMES = { md: '마크다운', markdown: '마크다운', txt: '텍스트', text: '텍스트', pdf: 'PDF', docx: '워드', doc: '워드', rtf: 'RTF',
    odt: 'ODT', html: '웹 문서', htm: '웹 문서', hwpx: '한글', hwp: '한글' };
  const pp = (w, a, b) => josa(w, a, b).slice(String(w).length); // 조사만
  const canTune = s => !!s && (s.kind === 'folder' || s.kind === 'obsidian');

  // 안내(notice): 엔진이 출처에 붙여 보낸다(예: 볼트 자동 인식). 닫은 안내는 이 Mac에서 다시 띄우지 않는다.
  const NOTICE_KEY = 'synapse.dismissedNotices';
  const dismissedNotices = (() => { try { return new Set(JSON.parse(localStorage.getItem(NOTICE_KEY) || '[]')); } catch (e) { return new Set(); } })();
  const noticeKey = s => s.id + '|' + String(s.notice);
  const liveNotices = () => ((nativeSrc && libStatus && libStatus.sources) || []).filter(s => s.notice && !dismissedNotices.has(noticeKey(s)));
  function renderNotices() {
    if (!sheetOpen) return;
    const html = liveNotices().map(s =>
      '<div class="notice" role="status" data-src="' + esc(s.id) + '">' + icon('info') +
        '<p><strong>' + esc(s.name || KIND_LABEL[s.kind] || '자료') + '</strong>' + esc(s.notice) + '</p>' +
        '<div class="notice-b">' + (canTune(s) ? '<button class="link-btn" type="button" data-act="fmt-open">형식·폴더 보기</button>' : '') +
        '<button class="icon-btn sm" type="button" data-act="notice-dismiss" title="안내 닫기" aria-label="안내 닫기">' + icon('x') + '</button></div>' +
      '</div>').join('');
    if (el.notices.dataset.html !== html) { el.notices.innerHTML = html; el.notices.dataset.html = html; }
    el.notices.hidden = !html;
  }
  function dismissNotice(id) {
    const s = findSrc(id);
    if (!s || !s.notice) return;
    dismissedNotices.add(noticeKey(s));
    try { localStorage.setItem(NOTICE_KEY, JSON.stringify([...dismissedNotices].slice(-50))); } catch (e) { /* 저장 못 해도 이번 실행 동안은 숨김 */ }
    renderNotices();
    el.sheet.focus({ preventScroll: true });
  }

  // 형식·폴더 패널: sourceDetails → { kinds: [[ext, count, included]], folders: [[relFolder, count, excluded]] }
  // 고른 값은 이 객체에 있고 행을 다시 그려도 그대로 남는다. 적용 → updateSource → 그 출처를 다시 훑는다(진행은 status).
  const fmt = { id: null, seq: 0, loading: false, error: '', applyError: '', details: null, kinds: new Set(), folders: new Set(), nested: new Set(), base: '', applying: false };   // nested: v0.9 안쪽 출처가 색인하는 폴더(제외로 보이고 바꿀 수 없다 · 저장하지 않는다)
  const fmtSig = () => [...fmt.kinds].sort().join(',') + '|' + [...fmt.folders].sort().join(',');
  function openFmt(id, from) {
    const s = findSrc(id);
    if (!s || !nativeSrc || !canTune(s)) return;
    if (fmt.id === id && from !== 'notice') { closeFmt(true); return; }
    if (fmt.id === id) { scrollFmt(); return; }
    confirmId = null;
    const seq = ++fmt.seq;
    Object.assign(fmt, { id, loading: true, error: '', applyError: '', details: null, kinds: new Set(), folders: new Set(), nested: new Set(), base: '', applying: false });
    renderSourceList(); scrollFmt();
    nativeSrc.sourceDetails(id).then(okOrThrow).then(r => {
      if (seq !== fmt.seq) return;
      r = r || {};
      const kinds = (Array.isArray(r.kinds) ? r.kinds : []).filter(Array.isArray).map(k => ({ ext: String(k[0]).replace(/^\./, ''), n: Number(k[1]) || 0, on: k[2] !== false }));
      const folders = (Array.isArray(r.folders) ? r.folders : []).filter(Array.isArray).map(f => ({ path: String(f[0]).replace(/^\/+|\/+$/g, ''), n: Number(f[1]) || 0, off: !!f[2], nested: f[3] === 'nested' }))
        .filter(f => f.path).sort((a, b) => a.path.localeCompare(b.path, 'ko'));
      fmt.details = { kinds, folders };
      fmt.kinds = new Set(kinds.filter(k => k.on).map(k => k.ext));
      fmt.folders = new Set(folders.filter(f => f.off && !f.nested).map(f => f.path));
      fmt.nested = new Set(folders.filter(f => f.nested).map(f => f.path));
      fmt.base = fmtSig(); fmt.loading = false;
      renderSourceList(); scrollFmt();
    }, e => { if (seq !== fmt.seq) return; fmt.loading = false; fmt.error = errMsg(e); renderSourceList(); });
  }
  function closeFmt(focusRow) {
    if (!fmt.id) return;
    const id = fmt.id;
    fmt.id = null; fmt.seq++;
    renderSourceList();
    if (focusRow) { const b = el.srcList.querySelector('[data-src="' + cssEsc(id) + '"] [data-act="fmt-open"]'); if (b) b.focus({ preventScroll: true }); }
  }
  function scrollFmt() {
    requestAnimationFrame(() => { const p = el.srcList.querySelector('.fmt'); if (p) p.scrollIntoView({ block: 'nearest' }); });
  }
  // 위 폴더를 빼면 아래 폴더도 빠진다 → 체크된 채 흐리게
  const impliedBy = path => [...fmt.folders, ...fmt.nested].find(f => f !== path && path.startsWith(f + '/')) || null;
  const impliedMsg = path => { const by = impliedBy(path); return !by ? '' : fmt.nested.has(by) ? '안쪽 출처가 색인하는 폴더 ‘' + by + '’ 안이라 여기서는 색인하지 않아요' : '위 폴더 ‘' + by + '’' + pp(by, '을', '를') + ' 빼서 함께 빠져요'; };
  function fmtPanelHtml(s) {
    let body;
    if (fmt.loading) body = '<div class="fmt-loading"><span class="spinner" aria-hidden="true"></span>파일 목록을 세는 중…</div>';
    else if (!fmt.details) body = '<div class="form-error">' + icon('alert') + '<span>형식·폴더 정보를 불러오지 못했어요 · ' + esc(fmt.error) + '</span></div>' +
      '<div class="fmt-foot"><span></span><div class="fmt-b"><button class="btn sm" type="button" data-act="fmt-cancel">닫기</button><button class="btn sm primary" type="button" data-act="fmt-retry">다시 시도</button></div></div>';
    else {
      const { kinds, folders } = fmt.details;
      body = '<div class="fmt-sec"><div class="fmt-h">색인할 형식</div>' +
        (kinds.length ? '<div class="fmt-kinds">' + kinds.map(k =>
          '<label class="fmt-kind"><input type="checkbox" data-fmt-kind="' + esc(k.ext) + '"' + (fmt.kinds.has(k.ext) ? ' checked' : '') + (fmt.applying ? ' disabled' : '') + '>' +
          '<span class="fmt-kind-t">' + esc(KIND_NAMES[k.ext.toLowerCase()] || k.ext.toUpperCase()) + '<span class="fmt-ext">.' + esc(k.ext) + '</span></span>' +
          '<span class="fmt-n">' + num(k.n) + '</span></label>').join('') + '</div>'
          : '<p class="fmt-none">읽을 수 있는 형식의 파일이 없어요.</p>') + '</div>' +
        '<div class="fmt-sec"><div class="fmt-h">제외할 폴더 <em>체크한 폴더와 그 아래는 색인하지 않아요</em></div>' +
        (folders.length ? '<div class="fmt-folders">' + folders.map(f => {
          const cut = f.path.lastIndexOf('/'), parent = cut > 0 ? f.path.slice(0, cut + 1) : '', leaf = cut > 0 ? f.path.slice(cut + 1) : f.path;
          const implied = impliedBy(f.path), nested = fmt.nested.has(f.path), lock = implied || nested;
          return '<label class="fmt-folder' + (parent ? ' is-sub' : '') + (lock ? ' is-implied' : '') + (nested ? ' is-nested' : '') + '"' +
            (nested ? ' title="안쪽 출처가 따로 색인하는 폴더예요. 여기서는 바꿀 수 없어요"' : implied ? ' title="' + esc(impliedMsg(f.path)) + '"' : '') + '>' +
            '<input type="checkbox" data-fmt-folder="' + esc(f.path) + '"' + (fmt.folders.has(f.path) || lock ? ' checked' : '') + (lock || fmt.applying ? ' disabled' : '') + '>' +
            icon('folder') + '<span class="fmt-path">' + (parent ? '<span class="fmt-parent">' + esc(parent) + '</span>' : '') + esc(leaf) + '</span>' +
            (nested ? '<span class="fmt-nest">다른 출처에서 색인</span>' : '') +
            '<span class="fmt-n">' + num(f.n) + '</span></label>';
        }).join('') + '</div>' : '<p class="fmt-none">하위 폴더가 없어요.</p>') + '</div>' +
        (fmt.applyError ? '<div class="form-error" role="alert">' + icon('alert') + '<span>' + esc(fmt.applyError) + '</span></div>' : '') +
        '<div class="fmt-foot"><p class="fmt-hint" data-fmt-hint></p><div class="fmt-b">' +
          '<button class="btn sm" type="button" data-act="fmt-cancel">닫기</button>' +
          '<button class="btn sm primary" type="button" data-act="fmt-apply">' + (fmt.applying ? '적용하는 중…' : '적용') + '</button></div></div>';
    }
    return '<div class="fmt" role="group" aria-label="‘' + esc(s.name || '자료') + '’ 형식·폴더 설정">' + body + '</div>';
  }
  // 체크할 때마다 행 전체를 다시 그리지 않고 상태만 고친다(포커스 유지)
  function syncFmtDom() {
    const p = el.srcList.querySelector('.fmt');
    if (!p || !fmt.details) return;
    p.querySelectorAll('[data-fmt-folder]').forEach(i => {
      const path = i.dataset.fmtFolder, implied = impliedBy(path), nested = fmt.nested.has(path), lock = !!implied || nested, lab = i.closest('.fmt-folder');
      i.checked = fmt.folders.has(path) || lock;
      i.disabled = lock || fmt.applying;
      lab.classList.toggle('is-implied', lock);
      if (nested) lab.title = '안쪽 출처가 따로 색인하는 폴더예요. 여기서는 바꿀 수 없어요'; else if (implied) lab.title = impliedMsg(path); else lab.removeAttribute('title');
    });
    const changed = fmtSig() !== fmt.base, none = !fmt.kinds.size && fmt.details.kinds.length > 0;
    const apply = p.querySelector('[data-act="fmt-apply"]'), hint = p.querySelector('[data-fmt-hint]');
    if (apply) apply.disabled = fmt.applying || !changed || none;
    if (hint) {
      hint.classList.toggle('is-warn', none);
      hint.textContent = none ? '형식을 하나 이상 골라 주세요.' : changed ? '적용하면 이 자료를 다시 훑어요. 빠진 문서는 색인에서만 지워지고 파일은 그대로예요.' : '바꾼 뒤 적용을 누르세요.';
    }
  }
  function onFmtChange(e) {
    const t = e.target;
    if (!fmt.details || fmt.applying) return;
    if (t.dataset.fmtKind != null) { if (t.checked) fmt.kinds.add(t.dataset.fmtKind); else fmt.kinds.delete(t.dataset.fmtKind); }
    else if (t.dataset.fmtFolder != null) {
      const path = t.dataset.fmtFolder;
      if (t.checked) { fmt.folders.add(path); [...fmt.folders].forEach(f => { if (f.startsWith(path + '/')) fmt.folders.delete(f); }); }
      else fmt.folders.delete(path);
    } else return;
    fmt.applyError = '';
    const err = el.srcList.querySelector('.fmt > .form-error'); if (err) err.remove();
    syncFmtDom();
  }
  function applyFmt() {
    const s = findSrc(fmt.id);
    if (!s || !fmt.details || fmt.applying || (fmt.details.kinds.length && !fmt.kinds.size) || fmtSig() === fmt.base) return;
    const id = s.id, seq = fmt.seq;
    fmt.applying = true; fmt.applyError = '';
    renderSourceList();
    nativeSrc.updateSource(id, [...fmt.kinds], [...fmt.folders]).then(okOrThrow).then(() => {
      if (seq === fmt.seq) closeFmt(true);
      const cur = findSrc(id);
      if (cur) { cur.state = 'indexing'; cur.progress = null; cur.error = null; libStatus.indexing = true; }
      renderSourceList(); renderStatus();
      toast('‘' + (s.name || '자료') + '’ 설정을 바꿨어요 · 다시 훑는 중이에요');
      return refreshStatus().then(st => afterStatus(st, 'changed'));
    }, e => {
      if (seq !== fmt.seq) { toast(errMsg(e), 'error'); return; }
      fmt.applying = false; fmt.applyError = errMsg(e);
      renderSourceList();
    });
  }
  // 일반: 다른 앱으로 전환하면 창 숨기기 (UserDefaults synapse.autoHide, 기본 꺼짐)
  let prefBusy = false, prefSeq = 0;
  function loadPrefs() {
    renderPrefs();
    if (!nativeSrc) return;
    const seq = ++prefSeq;
    nativeSrc.getPreferences().then(parse).then(r => {
      if (seq !== prefSeq || prefBusy) return; // 그 사이 사용자가 바꿈 → 늦은 답으로 되돌리지 않는다
      if (r && typeof r.autoHide === 'boolean') state.autoHide = r.autoHide;
      renderPrefs();
    }, e => console.warn('[synapse] getPreferences:', errMsg(e)));
  }
  function renderPrefs() {
    el.prefAutoHide.setAttribute('aria-checked', String(!!state.autoHide));
    el.prefAutoHide.setAttribute('aria-disabled', String(!nativeSrc));
    el.prefAutoHide.classList.toggle('is-busy', prefBusy);
    el.prefAutoHideD.textContent = !nativeSrc ? 'Synapse 앱에서 바꿀 수 있어요.'
      : state.autoHide ? '다른 앱을 누르면 창이 숨겨져요. 고정(항상 위에 표시)해 두면 숨기지 않아요.'
      : '꺼 두면 다른 앱을 써도 창이 그대로 남아요. 항상 위에 두려면 헤더의 고정 버튼을 누르세요.';
  }
  function toggleAutoHide() {
    if (!nativeSrc) { toast('Synapse 앱에서 바꿀 수 있어요'); return; }
    if (prefBusy) return;
    const next = !state.autoHide;
    prefSeq++;
    state.autoHide = next; prefBusy = true; renderPrefs();
    nativeSrc.setPreference('autoHide', next).then(okOrThrow).then(r => {
      if (r && typeof r.autoHide === 'boolean') state.autoHide = r.autoHide;
      toast(state.autoHide ? '다른 앱으로 전환하면 창을 숨겨요' + (state.pinned ? ' · 지금은 고정돼 있어 숨기지 않아요' : '') : '다른 앱으로 전환해도 창이 그대로 남아요');
    }, e => { state.autoHide = !next; toast('설정을 바꾸지 못했어요 · ' + errMsg(e), 'error'); })
      .then(() => { prefBusy = false; renderPrefs(); });
  }

  // ===========================================================================
  // Claude·Codex에서 Synapse 쓰기 (docs/V04.md §5.3): mcpStatus → { serverPath, clients: { claudeCode, codex, claudeDesktop } }
  const MCP_CLIENTS = [
    { key: 'claudeCode', name: 'Claude Code', where: '사용자 범위로 등록 · claude mcp add', na: 'claude 명령을 찾지 못했어요 · 아래 명령을 터미널에 붙여 넣으세요' },
    { key: 'codex', name: 'Codex', where: '~/.codex/config.toml', na: 'Codex 설정 폴더를 찾지 못했어요' },
    { key: 'claudeDesktop', name: 'Claude 데스크톱 앱', where: 'claude_desktop_config.json', na: 'Claude 데스크톱 앱을 찾지 못했어요' },
  ];
  const mcpSrv = { seq: 0, loading: false, loaded: false, error: '', serverPath: '', clients: {}, busy: null };
  function loadMcpStatus() {
    if (!nativeSrc) { renderMcpServer(); return; }
    const seq = ++mcpSrv.seq;
    mcpSrv.loading = true; renderMcpServer();
    nativeSrc.mcpStatus().then(parse).then(r => {
      if (seq !== mcpSrv.seq) return;
      r = r || {};
      mcpSrv.serverPath = r.serverPath ? String(r.serverPath) : '';
      mcpSrv.clients = r.clients && typeof r.clients === 'object' ? r.clients : {};
      mcpSrv.error = ''; mcpSrv.loaded = true;
    }, e => { if (seq === mcpSrv.seq) mcpSrv.error = errMsg(e); })
      .then(() => { if (seq === mcpSrv.seq) { mcpSrv.loading = false; renderMcpServer(); } });
  }
  const shq = p => /^[\w@%+=:,./-]+$/.test(p) ? p : "'" + p.replace(/'/g, "'\\''") + "'";
  const tomlq = p => '"' + p.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
  function mcpCommands() {
    const p = mcpSrv.serverPath;
    if (!p) return [];
    return [
      { label: 'Claude Code · 터미널', text: 'claude mcp add --scope user synapse -- ' + shq(p) },
      { label: 'Codex · ~/.codex/config.toml에 추가', text: '[mcp_servers.synapse]\ncommand = ' + tomlq(p) },
      { label: 'Claude 데스크톱 · claude_desktop_config.json의 mcpServers', text: '"synapse": { "command": ' + JSON.stringify(p) + ' }' },
    ];
  }
  function renderMcpServer() {
    if (!sheetOpen) return;
    let rows;
    if (!nativeSrc) rows = '<p class="set-note">Synapse 앱에서 등록할 수 있어요. 브라우저 미리보기에는 MCP 서버가 없어요.</p>';
    else if (!mcpSrv.loaded && mcpSrv.loading) rows = '<p class="set-note"><span class="spinner" aria-hidden="true"></span>등록 상태를 확인하는 중…</p>';
    else if (!mcpSrv.loaded) rows = '<div class="form-error">' + icon('alert') + '<span>등록 상태를 확인하지 못했어요 · ' + esc(mcpSrv.error) + '</span></div>';
    else rows = MCP_CLIENTS.map(c => {
      const st = String(mcpSrv.clients[c.key] || 'unavailable'), busy = mcpSrv.busy === c.key;
      const pill = st === 'registered' ? '<span class="pill is-ok">' + icon('check') + '등록됨</span>'
        : st === 'absent' ? '<span class="pill">등록 안 됨</span>' : '<span class="pill is-na">찾지 못함</span>';
      let btn = '';
      if (!mcpSrv.serverPath) btn = '';
      else if (st === 'absent') btn = '<button class="btn sm primary" type="button" data-act="mcp-register"' + (mcpSrv.busy ? ' disabled' : '') + '>' + (busy ? '등록하는 중…' : '등록') + '</button>';
      else if (st === 'registered') btn = '<button class="btn sm" type="button" data-act="mcp-register" title="지금 앱의 synapse-mcp 경로로 다시 써요"' + (mcpSrv.busy ? ' disabled' : '') + '>' + (busy ? '등록하는 중…' : '다시 등록') + '</button>';
      else if (c.key === 'claudeCode') btn = '<button class="btn sm" type="button" data-act="mcp-copy" data-copy="0">' + icon('copy') + '명령 복사</button>';
      return '<div class="mcp-client" role="listitem" data-client="' + c.key + '" data-state="' + esc(st) + '">' +
        '<div class="mcp-client-t"><b>' + c.name + '</b><span>' + esc(st === 'unavailable' ? c.na : c.where) + '</span></div>' + pill + btn + '</div>';
    }).join('');
    if (nativeSrc && mcpSrv.loaded && !mcpSrv.serverPath) rows += '<div class="form-error">' + icon('alert') + '<span>synapse-mcp 실행 파일을 찾지 못했어요. 앱을 다시 설치하거나 빌드해 주세요.</span></div>';
    if (el.mcpClients.dataset.html !== rows) { el.mcpClients.innerHTML = rows; el.mcpClients.dataset.html = rows; }
    const cmds = mcpCommands();
    el.mcpManual.hidden = !cmds.length;
    const manual = cmds.map((c, i) => '<div class="cmd"><div class="cmd-h"><span>' + esc(c.label) + '</span>' +
      '<button class="icon-btn sm" type="button" data-act="mcp-copy" data-copy="' + i + '" title="복사" aria-label="' + esc(c.label) + ' 복사">' + icon('copy') + '</button></div>' +
      '<pre class="cmd-c">' + esc(c.text) + '</pre></div>').join('') +
      (cmds.length ? '<p class="set-note">등록한 뒤 Claude·Codex를 다시 시작하면 synapse 도구(search_notes 등)가 보여요.</p>' : '');
    if (el.mcpManualB.dataset.html !== manual) { el.mcpManualB.innerHTML = manual; el.mcpManualB.dataset.html = manual; }
  }
  function mcpRegister(client) {
    if (!nativeSrc || !client || mcpSrv.busy) return;
    mcpSrv.busy = client; renderMcpServer();
    nativeSrc.mcpRegister(client).then(okOrThrow).then(r => {
      const name = (MCP_CLIENTS.find(c => c.key === client) || {}).name || client;
      toast(r && r.restartHint ? String(r.restartHint) : name + '에 등록했어요 · 다시 시작하면 synapse 도구가 보여요', '', 5200);
    }, e => toast('등록하지 못했어요 · ' + errMsg(e), 'error'))
      .then(() => { mcpSrv.busy = null; loadMcpStatus(); });
  }
  function copyCommand(node) {
    const c = mcpCommands()[Number(node.dataset.copy) || 0];
    if (c) copyText(c.text, '복사했어요 · ' + c.label.split(' · ')[0]);
  }
  // 복사: 네이티브 클립보드(v0.7) → navigator.clipboard → 숨긴 textarea + execCommand('copy') 순서로 시도한다. 포커스는 제자리로.
  // 모두 실패하면 onFail(text)을 부른다(없으면 알림만). 이번 주 화면은 onFail로 복사 미리보기 상자를 연다.
  function copyText(text, okMsg, onFail) {
    const back = document.activeElement;
    const done = () => toast(okMsg || '복사했어요');
    const failed = () => {
      if (typeof onFail === 'function') { try { onFail(text); return; } catch (e) { /* 아래 알림 */ } }
      toast('복사하지 못했어요 · 직접 선택해 복사해 주세요', 'error');
    };
    const fallback = () => {
      const ta = document.createElement('textarea');
      ta.value = text; ta.setAttribute('readonly', '');
      ta.style.cssText = 'position:fixed;left:-9999px;top:0;opacity:0';
      document.body.appendChild(ta); ta.select();
      let ok = false;
      try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
      ta.remove();
      if (back && back.focus) back.focus({ preventScroll: true });
      if (ok) done(); else failed();
    };
    const web = () => {
      try {
        if (navigator.clipboard && window.isSecureContext) { navigator.clipboard.writeText(text).then(done, fallback); return; }
      } catch (e) { /* 아래로 */ }
      fallback();
    };
    if (window.__synapseCopyFail === true) { failed(); return; }   // 시험용: 복사 실패 경로를 흉내 낸다
    // v0.7 C: 네이티브 복사 먼저 (예시 자료·브라우저 미리보기에는 없으니 건너뛴다)
    if (source && source.kind === 'native' && typeof source.brain === 'function') {
      Promise.resolve().then(() => source.brain('copyText', { text })).then(parse).then(r => { if (r && r.ok === true) done(); else web(); }, web);
      return;
    }
    web();
  }

  // ===========================================================================
  // Atlassian MCP 로그인 (docs/V04.md §6.4): addMCP({ server }) → 브라우저 로그인(창은 그대로) →
  //   { ok, source } | { ok:false, needSite, sites:[{name,url}] } → addMCP({ server, url, site }) | { ok:false, cancelled } | { ok:false, error }
  // 로그인 대기 중 취소는 네이티브 로그인 작업도 멈춘다(cancelMCP). 사이트 연결 단계는 멈추지 않고 기다리기만 그만둔다.
  const mcp = { phase: null, gen: 0, sites: [], pick: 0, url: undefined, error: '', note: '', site: '' };
  function syncAddArea() { el.sheetAdd.hidden = atl.open || !!mcp.phase; }
  function startMcpLogin(retry) {
    if (!sheetOpen) openSheet();
    if (!nativeSrc) { mcp.phase = 'error'; mcp.error = '브라우저 미리보기에서는 연결할 수 없어요. Synapse 앱에서 다시 시도해 주세요.'; mcp.note = ''; renderMcp(); return; }
    if (mcp.phase === 'login' || mcp.phase === 'connecting') { renderMcp(); return; }
    if (atl.open) closeAtlForm();
    if (!retry && mcp.phase === 'site') { renderMcp(); return; }
    runAddMCP({ server: 'atlassian' }, 'login');
  }
  async function runAddMCP(params, phase) {
    const gen = ++mcp.gen;
    Object.assign(mcp, { phase, error: '', note: '', site: params.site ? siteName(params.site) : '' });
    renderMcp(true);
    let r = null, err = null;
    try { r = parse(await nativeSrc.addMCP(params)); } catch (e) { err = errMsg(e); }
    if (gen !== mcp.gen) { if (r && r.ok !== false) refreshStatus().then(st => afterStatus(st, 'added')); return; }
    r = r || {};
    if (err || r.cancelled || (r.ok === false && !r.needSite)) {
      mcp.phase = 'error';
      mcp.error = err || (r.cancelled ? '' : r.error || '연결하지 못했어요. 잠시 뒤 다시 시도해 주세요.');
      mcp.note = r.cancelled ? '로그인을 마치지 못했어요 · 브라우저에서 취소했거나 시간이 지났어요.' : '';
      renderMcp(true); return;
    }
    if (r.needSite) {
      const sites = (Array.isArray(r.sites) ? r.sites : []).filter(x => x && (x.url || x.name)).map(x => ({ name: String(x.name || x.url), url: String(x.url || x.name) }));
      if (!sites.length) { mcp.phase = 'error'; mcp.error = '이 계정으로 들어갈 수 있는 Atlassian 사이트가 없어요.'; renderMcp(true); return; }
      Object.assign(mcp, { phase: 'site', sites, pick: 0, url: r.url || params.url });
      renderMcp(true); return;
    }
    mcp.phase = null; renderMcp(true);
    const name = (r.source && r.source.name) || mcp.site || 'Atlassian';
    toast('‘' + name + '’ 연결했어요 · 페이지와 이슈를 가져오는 중이에요');
    afterStatus(await refreshStatus(), 'added');
  }
  const siteName = url => { const s = mcp.sites.find(x => x.url === url); return s ? s.name : String(url).replace(/^https?:\/\//, '').replace(/\/.*$/, ''); };
  const siteHost = url => String(url).replace(/^https?:\/\//, '').replace(/\/+$/, '');
  function pickSite() {
    const site = mcp.sites[mcp.pick];
    if (mcp.phase !== 'site' || !site) return;
    const p = { server: 'atlassian', site: site.url };
    if (mcp.url) p.url = mcp.url;
    runAddMCP(p, 'connecting');
  }
  function cancelMcp() {
    const was = mcp.phase;
    if (!was) return;
    mcp.gen++; mcp.phase = null;
    renderMcp();
    if (was === 'login') {
      if (nativeSrc && nativeSrc.cancelMCP) nativeSrc.cancelMCP().catch(() => {});
      toast('로그인을 취소했어요 · 열린 브라우저 창은 닫아도 돼요');
    }
    const b = el.sheetAdd.querySelector('[data-act="add-mcp"]');
    if (b && sheetOpen) b.focus({ preventScroll: true });
  }
  function renderMcp(focus) {
    syncAddArea();
    el.mcpPanel.hidden = !mcp.phase;
    if (!mcp.phase) { el.mcpPanel.innerHTML = ''; return; }
    const head = '<h3 class="sheet-sec">Confluence·Jira 연결 · Atlassian 로그인</h3>';
    let html;
    if (mcp.phase === 'login' || mcp.phase === 'connecting') {
      const login = mcp.phase === 'login';
      html = '<div class="mcp-wait"><span class="spinner lg" aria-hidden="true"></span><div>' +
        '<h4>' + (login ? '브라우저에서 Atlassian 로그인을 마쳐 주세요' : '‘' + esc(mcp.site) + '’ 연결하는 중…') + '</h4>' +
        '<p>' + (login ? '기본 브라우저에 로그인 페이지가 열렸어요. 로그인하고 Synapse의 접근을 허용하면 여기서 자동으로 이어져요. 5분 안에 마치지 않으면 취소돼요.'
          : '연결을 확인하고 있어요. 끝나면 목록에 나타나고 페이지와 이슈를 가져오기 시작해요.') + '</p></div></div>' +
        '<div class="form-actions"><button class="btn" type="button" data-act="mcp-cancel">취소</button></div>';
    } else if (mcp.phase === 'site') {
      html = '<p class="mcp-p"><b>어느 사이트를 연결할까요?</b> 이 계정으로 들어갈 수 있는 사이트가 여러 개예요. 고른 사이트의 Confluence 페이지와 Jira 이슈를 가져와요.</p>' +
        '<div class="site-list" role="radiogroup" aria-label="Atlassian 사이트">' + mcp.sites.map((x, i) =>
          '<label class="site"><input type="radio" name="mcp-site" value="' + i + '"' + (i === mcp.pick ? ' checked' : '') + '>' +
          '<span class="site-t"><b>' + esc(x.name) + '</b><span>' + esc(siteHost(x.url)) + '</span></span></label>').join('') + '</div>' +
        '<div class="form-actions"><button class="btn" type="button" data-act="mcp-cancel">취소</button><button class="btn primary" type="button" data-act="mcp-site">연결하기</button></div>';
    } else {
      html = (mcp.note ? '<p class="mcp-p">' + icon('info') + esc(mcp.note) + '</p>' : '') +
        (mcp.error ? '<div class="form-error" role="alert">' + icon('alert') + '<span>' + esc(mcp.error) + '</span></div>' : '') +
        '<div class="form-actions"><button class="btn" type="button" data-act="mcp-cancel">닫기</button>' +
        (nativeSrc ? '<button class="btn primary" type="button" data-act="mcp-retry">다시 로그인</button>' : '') + '</div>';
    }
    el.mcpPanel.innerHTML = head + html;
    if (focus && sheetOpen) {
      const f = el.mcpPanel.querySelector('input[type="radio"]:checked') || el.mcpPanel.querySelector('.btn.primary') || el.mcpPanel.querySelector('.btn');
      if (f) f.focus({ preventScroll: true });
      requestAnimationFrame(() => el.mcpPanel.scrollIntoView({ block: 'nearest' }));
    }
  }

  // ===========================================================================
  // 네이티브 창 브리지 (DESIGN §8)
  function applyHotkey() {
    if (pending.hotkey == null) return;
    const text = pending.hotkey || '⌃⌥Space';
    el.hotkey.textContent = text;
    el.hotkey.title = /^[⌃⌥⇧⌘]/.test(text) ? '어디서든 이 단축키로 Synapse를 부릅니다' : text;
  }
  function applyPinned(value, fromUser) {
    state.pinned = !!value;
    el.pin.setAttribute('aria-pressed', String(state.pinned));
    el.pin.title = '항상 위에 표시';
    if (fromUser) {
      post({ action: 'setPinned', value: state.pinned });
      toast(state.pinned ? '항상 위에 표시해요 · 다른 앱 창에 가려지지 않아요'
        : '항상 위에 표시하지 않아요' + (state.autoHide ? ' · 다른 앱으로 전환하면 창이 숨겨져요' : ''));
    }
  }
  function applyVisibility(visible) {
    if (!visible) { composing = false; clearHover(); }
    if (graph) safe(() => graph.setPaused(!visible));
    if (visible && nativeSrc) { if (probe.pending) runProbe(); else scheduleStatus(0); } // 숨어 있던 동안의 진행을 따라잡는다
  }

  function createGraph() {
    if (!window.SynapseGraph || typeof window.SynapseGraph.create !== 'function') { console.warn('[synapse] SynapseGraph 없음'); return; }
    graph = safe(() => window.SynapseGraph.create(el.graphHost, {
      onSelect(id) {
        if (!id) return;
        if (id.startsWith('c:') || (id.startsWith('s:') && clusterNodeById(id))) { selectCluster(id); return; }
        if (id.startsWith('t:')) { searchTag(id.slice(2)); return; }
        if (id.startsWith('q:')) return;
        if (selectable(id)) selectUser(id, { reveal: false });
      },
      // v0.6 G가 graph.js에 onContext를 더하면 연결된다(없으면 쓰이지 않는다)
      onContext(id, x, y) {
        if (!id) return;
        if (id.startsWith('s:') && clusterNodeById(id)) return;   // v0.7 E: 요약 노드는 문서 메뉴를 열지 않는다
        if (id.startsWith('t:') || id.startsWith('q:') || id.startsWith('c:')) return;
        if (selectable(id)) select(id, { reveal: false });
        openDocMenu(id, x, y, 'graph');
      },
      onActivate(id) {
        if (!id) return;
        if (id.startsWith('c:') || (id.startsWith('s:') && clusterNodeById(id))) { expandCluster(id); return; }
        if (id.startsWith('t:')) { searchTag(id.slice(2)); return; }
        if (id.startsWith('q:')) return;
        follow(id);
      },
      onHover(id) {
        if (graphHoverFromGraph === id) return;
        if (graphHoverFromGraph) { const n = document.getElementById('result-' + graphHoverFromGraph); if (n) n.classList.remove('is-ghover'); }
        graphHoverFromGraph = id || null;
        if (id) { const n = document.getElementById('result-' + id); if (n) n.classList.add('is-ghover'); }
      },
      onBackgroundClick() {   // 묶음 지도: 빈 곳을 누르면 선택을 풀고 지도 안내로
        if (!view || !view.overview || !(state.selCluster || state.selectedId)) return;
        state.selCluster = null; state.selectedId = null;
        if (brainOn && state.mode === 'map') mapSel = null;
        syncSelectionDom(); renderReader(); renderNav();
        if (graph) safe(() => graph.setSelection(null));
        applyMapStyles();
      },
      onZoom(k) { el.zoomPct.textContent = Math.round((Number(k) || 1) * 100) + '%'; },
    })) || null;
    if (graph) {
      lastPadRight = null;
      const k = safe(() => graph.getZoom());
      if (k) el.zoomPct.textContent = Math.round(k * 100) + '%';
    }
  }

  // ===========================================================================
  // v0.5 사서 화면 (docs/V05.md §9.1~§9.4·§9.9): 모드 home · map · week · queue, 왜? 팝오버, U2 모듈, 사서 이벤트
  const BRAIN_MODES = new Set(['home', 'map', 'workmap', 'week', 'queue', 'tickets']);
  const WIDE_MODES = new Set(['home', 'workmap', 'week', 'queue', 'tickets']);   // 그래프 칸을 숨기고 목록을 넓히는 화면
  const MOD_NAMES = { queue: 'SynapseQueue', week: 'SynapseWeek', tickets: 'SynapseTickets', workmap: 'SynapseWorkMap' };
  const MODE_LABEL = { home: '홈', map: '그래프', workmap: '작업 지도', queue: '정리함', week: '이번 주', tickets: '티켓' };
  const FOCUS_MODS = new Set(['queue', 'workmap']);   // 붙이면 모듈이 포커스를 가져가는 화면(글자 키를 모듈이 받는다)
  const isBrainMode = m => BRAIN_MODES.has(m);
  const isGlobalish = m => m === 'global' || m === 'map';
  let brainOn = false;             // 사서를 쓸 수 있나(home 호출 성공). 아니면 예전처럼 global
  let homeData = null, homeOrder = [], homeKit = null;
  const homeUI = { sel: null, dormantOpen: false, cardDone: false };
  let mapData = null, mapOrder = [], mapSel = null, mapStyled = false, archiveShown = false;
  let wideReader = true;           // 넓은 화면(home·week·queue)의 리더 칸
  let lastKeyAt = 0, homeTimer = 0, queueCount = 0, activateGen = 0;
  let stopMark = null;             // { id, line, heading } — 리더에서 이 줄로 스크롤하고 표시
  let readerPin = null;            // 홈에서 흐름 상세 대신 잠깐 보여 줄 문서(산출물·이유 클릭)
  let mounted = null;              // { mode, mod } — 지금 붙어 있는 U2 모듈
  const modInited = new Set();
  const isWide = () => brainOn && !onboarding && WIDE_MODES.has(state.mode);
  // 홈 갱신이 리더를 바꾸면 안 되는 때: 이유·산출물로 연 문서(readerPin), 읽기 모드, 원문 편집(v0.4 편집 보호)
  const readerLocked = () => !!readerPin || state.reading || !!edit;
  let homeAfterWhy = false, undoBusy = false, lastAppliedBatch = null;
  const restMode = () => brainOn ? (isBrainMode(state.prevMode) ? state.prevMode : 'home') : 'global';
  const kit = () => {
    if (!homeKit && window.SynapseHome) homeKit = window.SynapseHome.create({ esc, icon: name => icon(name) });
    return homeKit;
  };
  const safeMod = fn => { try { return fn(); } catch (e) { console.warn('[synapse] module:', e && e.message); return undefined; } };
  const panel = () => { const p = window.SynapseBrainPanel; if (p) ensureInit(p); return p || null; };
  const panelOpen = () => { const p = window.SynapseBrainPanel; return !!(p && typeof p.isOpen === 'function' && safeMod(() => p.isOpen())); };
  function ensureInit(mod) {
    if (!mod || modInited.has(mod)) return;
    modInited.add(mod);
    if (typeof mod.init === 'function') safeMod(() => mod.init(brainApi));
  }

  // 사서 호출: NativeSource·DemoSource 공통 진입. 실패도 {ok:false,error}로 돌려준다(예외를 던지지 않음).
  function brainCall(method, params) {
    const src = source;
    params = params || {};
    if (!src) return Promise.resolve({ ok: false, error: '사서를 열지 못했어요' });
    if (method === 'document' && src.kind !== 'native') return Promise.resolve().then(() => src.document(params.id)).then(parse).catch(e => ({ ok: false, error: errMsg(e) }));
    if (typeof src.brain !== 'function') return Promise.resolve({ ok: false, error: '사서를 열지 못했어요' });
    return Promise.resolve().then(() => src.brain(method, params)).then(parse).catch(e => ({ ok: false, error: errMsg(e) }));
  }
  const brainFailed = r => !r || typeof r !== 'object' || r.ok === false;
  const validHome = r => !brainFailed(r) && (Array.isArray(r.next) || Array.isArray(r.urgent) || 'current' in r || r.empty != null);
  // QA idle이 모듈 요청도 기다리게 하는 진행 중 집계
  let modInflight = 0;
  const trackMod = p => { modInflight++; const done = () => { modInflight--; }; p.then(done, done); return p; };
  // U2 모듈 계약 (§9.9)
  const brainApi = Object.freeze({
    call: (method, params) => trackMod(brainCall(method, params).then(r => {
      // ⌥⌘Z가 되돌릴 대상: 이번 실행에서 마지막으로 적용한 배치
      if ((method === 'decide' || method === 'decideBundle' || method === 'tidyDecide') && r && r.applied && r.applied.batchId) lastAppliedBatch = String(r.applied.batchId);
      if (method === 'tidyDecideGroup' && r && r.ok !== false && Array.isArray(r.batches) && r.batches.length) lastAppliedBatch = r.batches.map(String);   // v0.9 묶음 승인: 배치 전체가 하나의 '마지막 동작' (⌥⌘Z가 역순으로 모두 되돌린다)
      if ((method === 'undo' || method === 'tidyUndo') && r && r.ok !== false && (!params || !params.batchId || params.batchId === lastAppliedBatch)) lastAppliedBatch = null;
      else if (method === 'tidyUndo' && Array.isArray(lastAppliedBatch) && params && lastAppliedBatch.indexOf(params.batchId) >= 0 && r && r.ok !== false) { lastAppliedBatch = lastAppliedBatch.filter(b => b !== params.batchId); if (!lastAppliedBatch.length) lastAppliedBatch = null; }
      return r;
    })),
    editingDocId: () => (edit ? String(edit.id) : null),
    esc: v => esc(v),
    toast: (msg, tone, ms) => toast(String(msg == null ? '' : msg), tone, ms),
    openDoc: (docId, line) => {
      // v0.7 fix1: 티켓 화면에서 연 문서는 히스토리에 남겨 ‹·⌘[가 같은 티켓 목록(칩·선택)으로 돌아오게 한다
      if (state.mode === 'tickets' && !state.reading) pushBack();
      openDocAt(docId, line, null, true);
    },
    openOriginal: docId => openOriginalById(docId, 'default'),
    copyText: (text, okMsg, onFail) => copyText(String(text == null ? '' : text), okMsg, onFail),
    setMode: mode => setMode(mode),
    follow: id => follow(String(id)),                        // v0.9 작업 지도: 연결 보기(focus 모드)
    icon: name => icon(String(name || '')),
    // v0.8 Claude 연결: 시키기 패널·정리함이 쓴다
    context: () => aiContext(),                              // { mode, docId, docTitle } — 지금 화면과 열려 있는 문서
    aiAvailable: () => aiOn(),                               // Claude를 쓸 수 있나(켜져 있고 찾았다)
    openAI: opts => openAIPanel(opts),                       // 시키기 패널 열기 ({preset?, prompt?})
    openSettings: () => openAISettings(),                    // 설정 시트의 Claude 구역 열기
    copyInstruction: () => copyClaudeInstruction(),          // 예전 "지시문 복사"
    showDigest: (kind, scope) => aiShowDigest(kind, scope),  // 정리를 돌린 빠른 작업 → 그 화면으로 이동
    refreshAI: () => loadAIStatus(),
  });
  function track(event, docId) { if (brainOn && docId != null) brainCall('track', { event, docId: String(docId) }); }

  // 출처가 바뀔 때: 사서가 답하면 홈, 아니면 예전 global
  function probeBrain(src) {
    if (!src || typeof src.brain !== 'function' || !window.SynapseHome) return Promise.resolve(null);
    return Promise.resolve().then(() => src.brain('home', {})).then(parse).then(r => (validHome(r) ? r : null), () => null);
  }
  function resetBrainUI() {
    clearTimeout(homeTimer);
    closeWhy(false);
    unmountModule();
    homeData = null; homeOrder = []; mapData = null; mapOrder = []; mapSel = null; stopMark = null; readerPin = null;
    homeBriefRes = null; homeBriefLoading = false; homeBriefSig = ''; homeBriefSeq++; docSums.clear(); closeAIPanel(true);   // v0.8
    Object.assign(homeUI, { sel: null, dormantOpen: false, cardDone: false, urgentProject: null, urgentMore: false });
    if (graph && mapStyled) { safe(() => graph.setNodeStyles(null)); safe(() => graph.setFocusSet(null)); }
    mapStyled = false;
  }

  // 모드 바꾸기 (헤더 · ⌘1~⌘4 · 사서 줄 · U2 setMode)
  function setMode(mode, opts = {}) {
    if (!isBrainMode(mode) || onboarding || !source) return;
    if (!brainOn) { toast('사서를 열지 못해서 이 화면은 쓸 수 없어요'); return; }
    closeWhy(false);
    if (panelOpen()) safeMod(() => window.SynapseBrainPanel.closeLog());
    if (state.mode === mode && !state.query && !state.reading && !opts.force) {
      if (FOCUS_MODS.has(mode) && mounted && mounted.mod && typeof mounted.mod.focus === 'function') safeMod(() => mounted.mod.focus());   // ⌘3 한 번 더 = 카드로 · ⌘2 한 번 더 = 작업 지도 목록으로
      else if (!FOCUS_MODS.has(mode)) focusSearch(false);
      return;
    }
    clearTimeout(queryTimer); queryTimer = 0;
    if (!opts.noHistory) pushBack();   // v0.6 N: ⌘1~⌘4 화면 이동도 뒤로/앞으로에 남는다
    state.query = ''; el.search.value = ''; state.focusId = null; state.reading = false;
    state.mode = mode; state.prevMode = mode; state.selectedId = null; state.cluster = null; state.selCluster = null;
    readerPin = null; stopMark = null;
    if (mode !== 'map') mapSel = null;
    renderModes();
    refresh();
    if (!FOCUS_MODS.has(mode)) focusSearch(false);
  }
  function renderModes() {
    if (!el.modes) return;
    el.modes.hidden = !brainOn || onboarding;
    el.modes.querySelectorAll('[data-mode]').forEach(b => b.setAttribute('aria-pressed', String(brainOn && (state.mode === b.dataset.mode || (b.dataset.mode === 'workmap' && state.mode === 'map')))));   // 그래프(map)도 작업 지도 탭 아래
    el.queueDot.hidden = !(queueCount > 0);
    const qb = el.modes.querySelector('[data-mode="queue"]');
    if (qb) qb.title = '정리함 · ⌘3' + (queueCount > 0 ? ' · 정리할 것이 있어요' : '');
    renderAIButton();   // v0.8: 헤더 Claude 버튼도 화면 상태에 맞춘다
  }

  // home · week · queue 새로 고침 (map은 기존 view 경로 + loadMap)
  function refreshBrain(opts = {}) {
    clearTimeout(queryTimer); queryTimer = 0;
    const seq = ++reqSeq, src = source, mode = state.mode;
    if (mode === 'home') {
      const p = brainCall('home').then(h => {
        if (seq !== reqSeq || src !== source || state.mode !== 'home') return;
        appliedSeq = seq;
        if (!validHome(h)) {
          if (!homeData) { brainOn = false; state.mode = 'global'; state.prevMode = null; renderModes(); return refresh(opts); } // 사서 없이 예전 화면
          if (!opts.silent) toast('홈을 새로 고치지 못했어요' + (h && h.error ? ' · ' + h.error : ''), 'error');
        } else homeData = h;
        applyHome(opts);
      });
      inflight = p;
      return p;
    }
    appliedSeq = seq;
    view = adaptView(EMPTY_VM, '');
    view.mode = mode;
    renderAll(opts);
    mountModule(mode);
    inflight = Promise.resolve();
    return inflight;
  }
  function loadMap() {
    return brainCall('map').then(r => {
      mapData = !brainFailed(r) && Array.isArray(r.threads) ? r : null;
      if (mapData && mapSel && !mapData.threads.some(t => String(t.id) === mapSel)) mapSel = null;
    });
  }
  function reloadMap() {
    if (state.mode !== 'map') return;
    loadMap().then(() => { if (state.mode !== 'map') return; renderList(); syncSelectionDom(); renderNav(); pushGraph(); });
  }

  // ---------------------------------------------------------------------------
  // 홈 (§9.2): 선택 = homeUI.sel(줄 key). 리더 문서 = 그 줄의 docId(state.selectedId), 멈춘 곳으로 스크롤.
  const homeRow = () => homeOrder.find(r => r.key === homeUI.sel) || null;
  const homeItem = () => { const r = homeRow(); return r && r.item ? r.item : null; };
  function defaultHomeSel(order) {
    const cur = order.find(r => r.kind === 'current');
    if (cur) return cur.key;
    const first = order.find(r => r.kind !== 'card' && r.kind !== 'toggle' && r.kind !== 'chip' && r.kind !== 'tickets' && r.kind !== 'tidy' && r.kind !== 'review' && r.kind !== 'ai');
    return first ? first.key : order[0] ? order[0].key : null;
  }
  function applyHome(opts = {}) {
    view = adaptView(EMPTY_VM, '');
    view.mode = 'home';
    const k = kit();
    homeOrder = k ? buildHome().order : [];
    if (!homeOrder.some(r => r.key === homeUI.sel)) homeUI.sel = defaultHomeSel(homeOrder);
    const lib = homeData && homeData.librarian;
    if (lib && lib.pending != null) { queueCount = Number(lib.pending) || 0; renderModes(); }
    if (!readerLocked()) pointReaderAtHome(false);   // 잠겨 있으면 목록만 새로 그리고 리더는 그대로
    renderAll(opts);
    if (!opts.silent) aiHomeEnter();   // v0.8: 홈을 열 때 오늘 브리핑을 읽는다
  }
  // 선택한 홈 줄의 문서를 리더에. 줄이 카드·잠듦 토글이면 리더는 그대로 둔다.
  function pointReaderAtHome(force) {
    const row = homeRow();
    if (!row || row.kind === 'card' || row.kind === 'toggle' || row.kind === 'chip' || row.kind === 'tickets' || row.kind === 'tidy' || row.kind === 'review') return;
    const it = row.item || {};
    if (it.docId != null) {
      const id = String(it.docId);
      if (force || state.selectedId !== id || !stopMark || stopMark.id !== id) stopMark = { id, line: it.line != null ? Number(it.line) : (it.stopped && it.stopped.line) || null, heading: (it.stopped && it.stopped.heading) || null };
      state.selectedId = id;
      if (!titles.has(id) && it.kind !== 'thread') titles.set(id, it.title);
    } else { state.selectedId = null; stopMark = null; }
  }
  // v0.8: 홈 목록 = 홈 줄들 + (Claude를 쓸 수 있고 브리핑이 있으면) 맨 위 "오늘" 카드. 카드의 참조가 있는 줄은 홈 줄(kind 'ai')로 맨 앞에 끼워 ↑↓·↵로 고른다.
  let homeBriefRes = null, homeBriefLoading = false, homeBriefSeq = 0, homeBriefSig = '', homeAiRows = 0;
  function buildHome() {
    const k = kit();
    const b = k.build(homeData || {}, homeUI);
    homeAiRows = 0;
    const P = aiPanel();
    if (!aiOn() || !P || typeof P.homeBrief !== 'function') { homeBriefSig = briefSig(); return b; }
    const br = safeMod(() => P.homeBrief(homeBriefRes, { sel: homeUI.sel, loading: homeBriefLoading }));
    if (!br) { homeBriefSig = briefSig(); return b; }
    homeAiRows = br.rows.length;
    homeBriefSig = briefSig();
    return { html: b.html.replace('<div class="home">', m => m + br.html), order: br.rows.concat(b.order) };
  }
  function renderHomeList() {
    const k = kit();
    if (!k) { el.results.innerHTML = ''; return; }
    const b = buildHome();
    homeOrder = b.order;
    el.results.innerHTML = b.html;
    bindBrief();
  }
  // 카드의 참조 칩: 누르면 그 문서 열기. 칩을 눌러도 줄 선택(홈 목록 위임)으로 새지 않게 한다.
  function bindBrief() {
    const box = el.results.querySelector('.ap-brief');
    if (!box) return;
    const A = window.SynapseAI;
    if (A && typeof A.bindRefs === 'function') safeMod(() => A.bindRefs(box));
    box.addEventListener('click', e => {
      const chip = e.target.closest && e.target.closest('[data-ai-doc]');
      if (!chip) return;
      e.stopPropagation();
      if (!(A && typeof A.bindRefs === 'function')) openDocAt(chip.dataset.aiDoc, chip.dataset.aiLine, null, true);
    });
  }
  const briefSig = () => JSON.stringify([homeBriefRes && [homeBriefRes.digest, homeBriefRes.running, homeBriefRes.meta], homeBriefLoading, aiOn()]);
  // 브리핑이 바뀌었을 때만 목록을 다시 그린다(깜빡이지 않게). 스크롤·선택은 그대로.
  function redrawHome() {
    if (state.mode !== 'home' || !brainOn || !kit()) return;
    const sig = briefSig();
    if (sig === homeBriefSig) return;
    homeBriefSig = sig;
    const top = el.results.scrollTop;
    renderHomeList();
    if (!homeOrder.some(r => r.key === homeUI.sel)) homeUI.sel = defaultHomeSel(homeOrder);
    syncSelectionDom();
    el.results.scrollTop = top;
    renderNav();
  }
  function homeSelect(key, opts = {}) {
    const row = homeOrder.find(r => r.key === key);
    if (!row) return;
    if (whyState) closeWhy(false);
    homeUI.sel = key; readerPin = null;
    pointReaderAtHome(true);
    const node = syncSelectionDom();
    if (opts.scroll !== false) scrollItemIntoView(node);
    if (row.kind !== 'card' && row.kind !== 'toggle' && row.kind !== 'chip' && row.kind !== 'tickets' && row.kind !== 'tidy' && row.kind !== 'review') renderReader();
    renderNav();
  }
  function homeMove(delta) {
    if (!homeOrder.length) return;
    const i = homeOrder.findIndex(r => r.key === homeUI.sel);
    const next = i < 0 ? 0 : Math.max(0, Math.min(homeOrder.length - 1, i + delta));
    if (homeOrder[next].key !== homeUI.sel || i < 0) homeSelect(homeOrder[next].key);
  }
  function toggleDormant() {
    const d = homeData && homeData.dormant;
    if (!d || !d.count) return;
    homeUI.dormantOpen = !homeUI.dormantOpen;
    const row = homeRow();
    if (!homeUI.dormantOpen && row && row.kind === 'dormant') homeUI.sel = 'dormant';
    renderHomeList();
    const node = syncSelectionDom();
    scrollItemIntoView(node);
    renderNav();
  }
  // ↵: 문서면 읽기 모드로 멈춘 곳, 코드 흐름이면 리더에 흐름 상세, 카드면 켜기, 토글이면 펼치기
  function homeEnter() {
    const row = homeRow();
    if (!row) return;
    if (row.kind === 'card') { sessionsChoice(true); return; }
    if (row.kind === 'toggle') { toggleDormant(); return; }
    if (row.kind === 'chip') { urgentRun(row); return; }   // v0.7 B: 급한 것 칩
    if (row.kind === 'tickets') { setMode('tickets'); return; }   // v0.7 A: 홈 맨 위 티켓 한 줄
    if (row.kind === 'tidy' || row.kind === 'review') { openWorkMapPlan(); return; }   // v0.9: 정리 한 줄·리뷰 카드 → 작업 지도의 정리 계획
    const it = row.item || {};
    readerPin = null;
    if (it.docId != null) {
      if (!state.reading) pushBack();   // v0.6 N: 홈에서 문서를 여는 것도 뒤로 갈 수 있게
      pointReaderAtHome(true);
      track('view', it.docId);
      if (state.reading) { renderReader(); scrollToStop(); } else setReading(true);
    } else {
      if (!wideReader) { wideReader = true; renderLayout(); }
      renderReader(); renderNav();
    }
  }
  function sessionsChoice(on) {
    homeUI.cardDone = true;
    brainCall('setBrainSetting', { key: 'sessions.enabled', value: on ? '1' : '0' }).then(r => {
      if (brainFailed(r)) { homeUI.cardDone = false; toast((r && r.error) || '설정을 바꾸지 못했어요', 'error'); renderHomeList(); syncSelectionDom(); return; }
      toast(on ? 'Claude·Codex 기록을 읽을게요 · 다음 읽기부터 반영돼요' : '설정 › 사서에서 언제든 켤 수 있어요', '', 4200);
      if (state.mode === 'home') refresh({ silent: true });
    });
    if (state.mode === 'home') { homeUI.sel = defaultHomeSel(homeOrder.filter(r => r.kind !== 'card')); renderHomeList(); pointReaderAtHome(true); syncSelectionDom(); renderReader(); }
  }

  // ---------------------------------------------------------------------------
  // 지도 (§9.4): 흐름 목록 · 흐름 색칠 · 밝기 · 잠듦 흐리게 · 보관본 숨김 · 범례
  const mapThread = key => (mapData && key ? mapData.threads.find(t => String(t.id) === String(key)) : null) || null;
  function renderMapList() {
    const b = kit().flows(mapData, { sel: mapSel });
    mapOrder = b.order;
    el.results.innerHTML = b.html;
  }
  function mapSelect(key, opts = {}) {
    if (whyState) closeWhy(false);
    const th = mapThread(key);
    mapSel = th ? String(th.id) : null;
    if (th) {
      const ids = (th.docIds || []).map(String);
      const doc = th.primaryDocId != null && selectable(String(th.primaryDocId)) ? String(th.primaryDocId) : ids.find(id => selectable(id)) || null;
      if (doc) {
        state.selectedId = doc; state.selCluster = null;
        renderReader();
        if (graph) { safe(() => graph.setSelection(graphSelection())); if (opts.reveal && view.visible.has(doc)) safe(() => graph.reveal(doc)); }
      }
    }
    const node = syncSelectionDom();
    if (opts.scroll !== false) scrollItemIntoView(node);
    applyMapStyles();
    renderNav();
  }
  function mapMove(delta) {
    if (!mapOrder.length) return;
    const i = mapOrder.findIndex(r => r.key === mapSel);
    const next = i < 0 ? 0 : Math.max(0, Math.min(mapOrder.length - 1, i + delta));
    if (mapOrder[next].key !== mapSel || i < 0) mapSelect(mapOrder[next].key, { reveal: true });
  }
  const archiveSet = () => new Set(mapData && Array.isArray(mapData.archive) && !archiveShown ? mapData.archive.map(String) : []);
  function applyMapStyles() {
    if (!graph) return;
    if (!brainOn || state.mode !== 'map' || !mapData || !view) {
      if (mapStyled) { safe(() => graph.setNodeStyles(null)); safe(() => graph.setFocusSet(null)); mapStyled = false; }
      return;
    }
    const styles = {}, dim = new Set((mapData.dim || []).map(String)), dt = mapData.docThread || {};
    view.visible.forEach(id => {
      const th = mapThread(dt[id]);
      if (!th) { styles[id] = { topic: 'other', alpha: 0.5 }; return; }
      const b = Math.max(0, Math.min(1, Number(th.brightness) || 0)), dimmed = dim.has(id);
      styles[id] = { topic: th.colorIndex >= 0 && th.colorIndex < 8 ? 'g' + th.colorIndex : 'other', alpha: (0.35 + 0.65 * b) * (dimmed ? 0.55 : 1), glow: b >= 0.95 && !dimmed };
    });
    safe(() => graph.setNodeStyles(styles));
    const th = mapThread(mapSel);
    // 묶음 지도에서는 흐름의 문서가 속한 묶음을 강조한다
    const dc = view.docCluster, ids = th ? (th.docIds || []).map(String) : null;
    safe(() => graph.setFocusSet(ids && dc ? [...new Set(ids.map(i => dc[i]).filter(Boolean))] : ids));
    mapStyled = true;
  }
  function renderArchiveToggle() {
    const n = brainOn && state.mode === 'map' && mapData ? Number(mapData.hiddenArchive) || 0 : 0;
    el.gArchive.hidden = !n;
    if (n) el.gArchive.innerHTML = icon(archiveShown ? 'x' : 'stack') + '<span>' + (archiveShown ? 'AI 보관본 ' + num(n) + ' 숨기기' : '숨긴 보관본 ' + num(n) + ' · 보기') + '</span>';
  }

  // ---------------------------------------------------------------------------
  // 리더: 멈춘 곳으로 스크롤 · 문서 열기(U2 openDoc) · 원본 열기
  // quiet: 표시만 다시 붙이고 스크롤하지 않는다(같은 문서를 다시 그릴 때 사용자가 옮긴 스크롤을 지킨다)
  function scrollToStop(quiet) {
    if (!stopMark || String(state.selectedId) !== stopMark.id) return false;
    const body = el.readerInner.querySelector('.reader-body');
    if (!body) return false;
    body.querySelectorAll('.rb-stop').forEach(n => n.classList.remove('rb-stop'));
    let target = null;
    if (stopMark.heading) {
      const want = normalize(stopMark.heading);
      target = [...body.querySelectorAll('.rb-h')].find(h => normalize(h.textContent) === want) || null;
    }
    if (!target && stopMark.line) {
      body.querySelectorAll('[data-line]').forEach(n => { const l = Number(n.dataset.line); if (l <= stopMark.line && (!target || l >= Number(target.dataset.line))) target = n; });
    }
    if (!target) return false;
    target.classList.add('rb-stop');
    target.title = '멈춘 곳';
    if (quiet) return true;
    stopMark.done = true;
    const box = el.readerScroll.getBoundingClientRect(), r = target.getBoundingClientRect();
    el.readerScroll.scrollTop += r.top - box.top - Math.min(96, box.height * 0.22);
    return true;
  }
  const readerShown = () => isWide() ? wideReader : state.readerOpen;
  function openDocAt(docId, line, heading, intended) {
    if (docId == null || !source || onboarding) return;
    const id = String(docId);
    if (whyState) closeWhy(false);
    readerPin = state.mode === 'home' ? id : null;
    state.selectedId = id;
    stopMark = { id, line: line != null && line !== '' ? Number(line) : null, heading: heading || null };
    if (intended) track('view', id);
    if (state.mode === 'map' && graph && view && view.visible.has(id)) { safe(() => graph.setSelection(id)); safe(() => graph.reveal(id)); }
    if (mounted || !readerShown()) { if (state.reading) { renderReader(); scrollToStop(); } else setReading(true); }
    else { renderReader(); renderNav(); }
  }
  function openOriginalById(docId, target) {
    if (docId == null || !source) return;
    if (source.kind === 'demo') { toast('원본 파일이 없는 예시 문서예요'); return; }
    const id = String(docId), src = source;
    loadDoc(id).then(dm => {
      if (!dm.open || !dm.open.label) { toast('이 문서는 원본을 열 수 없어요'); return; }
      if (target === 'reveal' && !dm.open.canReveal) { toast('Finder에서 볼 수 없는 문서예요'); return; }
      return src.open(id, target).then(r => { r = parse(r); if (r && r.ok === false) toast(r.error || '원본을 열지 못했어요'); });
    }).catch(e => toast('원본을 열지 못했어요 · ' + errMsg(e)));
  }
  // 홈에서 문서 없는 줄(코드 흐름)이 골라져 있으면 그 항목
  function homeFlowItem() {
    if (!brainOn || state.mode !== 'home' || readerPin || state.reading) return null;
    const row = homeRow();
    return row && row.item && row.item.docId == null ? row.item : null;
  }

  // ---------------------------------------------------------------------------
  // 왜? 팝오버 (§9.3): 열려 있는 동안 단일 문자 키(p·d·w·r·1·2)는 팝오버가 받는다
  let whyState = null; // { id, data, phase: 'list'|'demote'|'rename', sel, busy, anchor }
  function whyTarget() {
    if (!brainOn) return null;
    if (state.mode === 'home') {
      const row = homeRow();
      if (!row || !row.item || row.kind === 'card' || row.kind === 'toggle' || row.kind === 'chip' || row.kind === 'ai') return null;
      return { id: String(row.item.id), anchor: kit().rowId(homeOrder.indexOf(row) - homeAiRows) };
    }
    if (state.mode === 'map' && mapSel) return { id: 'thread:' + mapSel, anchor: 'frow-' + mapOrder.findIndex(r => r.key === mapSel) };
    return null;
  }
  function openWhy() {
    const t = whyTarget();
    if (!t) { toast(brainOn && (state.mode === 'home' || state.mode === 'map') ? '먼저 항목을 골라 주세요' : '왜?는 홈이나 지도에서 볼 수 있어요'); return; }
    if (whyState && whyState.id === t.id) { closeWhy(true); return; }
    whyState = { id: t.id, data: { loading: true }, phase: 'list', sel: -1, busy: false, anchor: t.anchor };
    paintWhy();
    brainCall('why', { id: t.id }).then(r => {
      if (!whyState || whyState.id !== t.id) return;
      whyState.data = brainFailed(r) || !Array.isArray(r.reasons) ? { error: (r && r.error) || '이유를 불러오지 못했어요' } : r;
      paintWhy();
    });
  }
  function closeWhy(focus) {
    if (!whyState) return;
    whyState = null;
    if (el.whyPop) { el.whyPop.hidden = true; el.whyPop.innerHTML = ''; }
    if (homeAfterWhy) { homeAfterWhy = false; scheduleHome(); }
    if (focus) focusSearch(false);
    if (el.escHint) renderNav();
  }
  function paintWhy() {
    if (!whyState) { closeWhy(false); return; }
    el.whyPop.innerHTML = kit().why(whyState.data, whyState);
    el.whyPop.hidden = false;
    positionWhy();
    if (whyState.phase === 'rename') { const inp = el.whyPop.querySelector('.why-input'); if (inp && document.activeElement !== inp) { inp.focus({ preventScroll: true }); inp.select(); } }
    renderNav();
  }
  function positionWhy() {
    if (!whyState) return;
    const pop = el.whyPop, W = window.innerWidth, H = window.innerHeight;
    const pw = Math.min(380, W - 24);
    pop.style.width = pw + 'px';
    const a = whyState.anchor ? document.getElementById(whyState.anchor) : null;
    const ph = pop.offsetHeight;
    let x = (W - pw) / 2, y = 96;
    if (a) {
      const r = a.getBoundingClientRect();
      x = Math.max(12, Math.min(W - pw - 12, r.right - pw - 8));
      y = r.bottom + 4;
      if (y + ph > H - 36) y = r.top - ph - 4;
    }
    pop.style.left = Math.round(x) + 'px';
    pop.style.top = Math.round(Math.max(12, Math.min(y, H - ph - 12))) + 'px';
  }
  const whyReasons = () => [...el.whyPop.querySelectorAll('button.why-r')];
  function whyAction(act) {
    if (!whyState || whyState.busy || !whyState.data || !Array.isArray(whyState.data.actions)) return;
    if (!whyState.data.actions.some(a => a.id === act)) return;
    if (act === 'demote' || act === 'rename') { whyState.phase = act; paintWhy(); return; }
    runFeedback(whyState.id, act);
  }
  function runFeedback(id, action, scope) {
    if (whyState) { if (whyState.busy) return Promise.resolve(false); whyState.busy = true; }
    return sendFeedback(id, action, scope).then(ok => { if (ok) closeWhy(true); else if (whyState) { whyState.busy = false; paintWhy(); } });
  }
  function submitRename() {
    if (!whyState || whyState.phase !== 'rename') return;
    const inp = el.whyPop.querySelector('.why-input');
    const v = inp ? inp.value.trim() : '';
    if (!v) { toast('새 이름을 적어 주세요'); return; }
    runFeedback(whyState.id, 'rename', v);
  }
  function sendFeedback(id, action, scope) {
    const p = { id, action };
    if (scope != null) p.scope = scope;
    return brainCall('feedback', p).then(r => {
      if (brainFailed(r)) { toast((r && r.error) || '기억하지 못했어요', 'error'); return false; }
      toast(action === 'rename' ? '이름을 바꿨어요' : '기억할게요');
      if (state.mode === 'home') refresh({ silent: true }); else if (state.mode === 'map') reloadMap();
      return true;
    });
  }
  // 팝오버 키. true = 앱의 다른 키 처리를 건너뛴다(입력칸 글자는 기본 동작에 맡김)
  function onWhyKey(e) {
    if (e.isComposing || e.keyCode === 229) return true;
    const meta = e.metaKey, ctrl = e.ctrlKey, alt = e.altKey;
    const stop = () => { e.preventDefault(); e.stopPropagation(); };
    const isEnter = e.key === 'Enter' || e.code === 'Enter' || e.code === 'NumpadEnter';
    if (e.key === 'Escape') { stop(); if (whyState.phase !== 'list') { whyState.phase = 'list'; paintWhy(); } else closeWhy(true); return true; }
    if (meta && !ctrl && !alt && keyIs(e, ['/', '?'], 'Slash')) { stop(); closeWhy(true); return true; }
    if (whyState.phase === 'rename') { if (isEnter && !meta && !ctrl && !alt) { stop(); submitRename(); } return true; }  // ⌘A·⌘V 등은 입력칸 몫
    if (meta || ctrl || alt) { closeWhy(false); return false; }   // ⌘1 같은 키는 닫고 앱이 처리
    if (whyState.phase === 'demote') {
      if (whyState.busy || e.repeat) { stop(); return true; }
      if (keyIs(e, ['1'], 'Digit1')) { stop(); runFeedback(whyState.id, 'demote', 'week'); }
      else if (keyIs(e, ['2'], 'Digit2')) { stop(); runFeedback(whyState.id, 'demote', 'always'); }
      else if (e.key.length === 1 || isEnter || e.key === 'Tab') stop();
      return true;
    }
    const rs = whyReasons();
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      stop();
      if (rs.length) { whyState.sel = whyState.sel < 0 ? (e.key === 'ArrowDown' ? 0 : rs.length - 1) : Math.max(0, Math.min(rs.length - 1, whyState.sel + (e.key === 'ArrowDown' ? 1 : -1))); rs.forEach((b, i) => b.setAttribute('aria-selected', String(i === whyState.sel))); }
      return true;
    }
    if (isEnter) { stop(); const b = rs[whyState.sel]; if (b) openDocAt(b.dataset.doc, b.dataset.line, null, true); return true; }
    const KEYS = { KeyP: 'p', KeyD: 'd', KeyW: 'w', KeyR: 'r' };
    const ch = KEYS[e.code] || String(e.key || '').toLowerCase();
    const acts = (whyState.data && whyState.data.actions || []).map(a => a.id);
    if (ch === 'p') { stop(); whyAction(acts.includes('unpin') ? 'unpin' : 'pin'); return true; }
    if (ch === 'd') { stop(); whyAction('demote'); return true; }
    if (ch === 'w') { stop(); whyAction('wake'); return true; }
    if (ch === 'r') { stop(); whyAction('rename'); return true; }
    if (e.key.length === 1 || e.key === 'Tab') stop();
    return true;
  }

  // ---------------------------------------------------------------------------
  // 사서 동작: ⌘↑/⌘↓ 고정·덜 중요 · ⌘⇧K Claude에게 맡기기 · ⌥⌘Z 되돌리기 · ⌘⇧C 주간보고 복사 · ⌘Y AI 기록
  function feedbackTarget() {
    if (state.mode === 'home') {
      const row = homeRow();
      if (!row || !row.item || row.kind === 'card' || row.kind === 'toggle' || row.kind === 'chip' || row.kind === 'ai') return null;
      return { id: String(row.item.id), pinned: !!row.item.pinned };
    }
    if (state.mode === 'map' && mapSel) {
      const id = 'thread:' + mapSel, h = homeData || {};
      const it = [h.current, ...(h.next || []), ...(h.urgent || []), ...((h.dormant && h.dormant.items) || [])].find(x => x && String(x.id) === id);
      return { id, pinned: !!(it && it.pinned) };
    }
    return null;
  }
  function pinOrDemote(up) {
    if (state.mode === 'home') { const row = homeRow(); if (row && row.kind === 'card') { if (!up) sessionsChoice(false); return; } }
    const t = feedbackTarget();
    if (!t) { toast('먼저 항목을 골라 주세요'); return; }
    if (up) sendFeedback(t.id, t.pinned ? 'unpin' : 'pin');
    else sendFeedback(t.id, 'demote', 'week');
  }
  // ---------------------------------------------------------------------------
  // v0.8 Claude 연결 (docs/V08.md §8.4·§8.5)
  // aiStat = 마지막 aiStatus. 이 앱이 Claude 연결을 지원하지 않거나(미리보기) 읽지 못하면 null → 관련 단추·카드는 모두 숨긴다.
  let aiStat = null, aiStatSeq = 0, aiInited = false;
  const aiOn = () => !!(aiStat && aiStat.available);         // 켜져 있고 Claude도 찾았다 = 쓸 수 있다
  const aiPanel = () => window.SynapseAIPanel || null;
  const aiPanelOpen = () => { const p = aiPanel(); return !!(p && typeof p.isOpen === 'function' && safeMod(() => p.isOpen())); };
  function openAIPanel(opts) {
    const p = aiPanel();
    if (!p || !brainOn || onboarding || !source) { toast('Claude에게 시키기는 자료를 연결한 뒤에 쓸 수 있어요'); return false; }
    ensureInit(p);
    closeWhy(false);
    return safeMod(() => p.open(opts || {})) !== false;
  }
  function closeAIPanel(keepFocus) { const p = aiPanel(); if (p && aiPanelOpen()) safeMod(() => p.close(keepFocus)); }
  function toggleAIPanel() { if (aiPanelOpen()) closeAIPanel(); else openAIPanel(); }
  // ⌘J와 패널 안의 키. true = 이 키는 여기서 끝(앱의 다른 처리를 건너뛴다)
  function aiPanelKey(e) {
    const p = aiPanel();
    if (!p) return false;
    const composing = e.isComposing || e.keyCode === 229;
    if (e.metaKey && !e.ctrlKey && !e.altKey && !e.shiftKey && !composing && keyIs(e, ['j', 'J'], 'KeyJ')) {
      if (modalOpen()) return false;                       // 자료 패널·첫 실행 안내가 떠 있으면 쓰지 않는다
      e.preventDefault(); e.stopPropagation(); toggleAIPanel();
      return true;
    }
    if (!aiPanelOpen()) return false;
    const inside = !!(e.target && e.target.closest && e.target.closest('.ap'));
    if (!inside) return false;
    if (composing) return true;                            // 한글 조합 중에는 아무것도 가로채지 않는다(입력칸 몫)
    if (safeMod(() => p.onKey(e)) === true) { e.preventDefault(); e.stopPropagation(); }
    return true;                                           // 패널 안에서는 앱 단축키를 쓰지 않는다
  }
  // 지금 열려 있는 문서(리더에 보이는 문서). 정리함·이번 주·티켓의 리더 칸은 모듈이 쓰니 문서가 아니다.
  function aiOpenDocId() {
    if (!source || onboarding) return null;
    if (edit && editVisible()) return String(edit.id);
    if (moduleOwnsReader()) return null;
    const id = state.selectedId;
    if (!id || !(state.reading || readerVisible())) return null;
    return String(id);
  }
  function aiContext() {
    const id = aiOpenDocId(), dm = id ? docCache.get(id) : null;
    return { mode: state.reading ? 'reader' : state.mode, docId: id, docTitle: id ? ((dm && dm.doc && dm.doc.title) || titles.get(id) || '') : '' };
  }
  function digestFetch(kind, o) {
    o = o || {};
    const A = window.SynapseAI;
    if (A && typeof A.digest === 'function') return Promise.resolve().then(() => A.digest(kind, o)).catch(e => ({ ok: false, error: { code: 'failed', message: errMsg(e) } }));
    const p = { kind, run: o.run || 'none' };
    if (o.offset != null) p.offset = o.offset;
    if (o.docId != null) p.docId = o.docId;
    return brainCall('aiDigest', p);
  }
  function loadAIStatus() {
    if (!brainOn || !source) { aiStat = null; onAIStatus(); return Promise.resolve(null); }
    const seq = ++aiStatSeq;
    return brainCall('aiStatus').then(r => {
      if (seq !== aiStatSeq) return aiStat;
      aiStat = !brainFailed(r) ? r : null;
      onAIStatus();
      return aiStat;
    });
  }
  // 사서가 열린 뒤 한 번: SynapseAI에 브리지를 알리고, 이벤트를 구독하고, 상태를 읽는다
  function initAI() {
    const A = window.SynapseAI, P = aiPanel();
    if (A && typeof A.init === 'function') safeMod(() => A.init(brainApi));
    if (P) ensureInit(P);
    if (!aiInited) {
      aiInited = true;
      if (P && typeof P.onChange === 'function') safeMod(() => P.onChange(() => renderAIButton()));
      if (A && typeof A.on === 'function') {
        safeMod(() => A.on('status', (e, st) => { if (st && typeof st === 'object') { aiStat = st.ok === false ? null : st; onAIStatus(); } else loadAIStatus(); }));
        safeMod(() => A.on('digest', onAIDigest));
        safeMod(() => A.on('run', onAIRun));
      }
    }
    return loadAIStatus();
  }
  function renderAIButton() {
    const b = el.aiBtn;
    if (!b) return;
    const P = aiPanel();
    b.hidden = !(brainOn && !onboarding && !!aiStat && !!P);
    b.setAttribute('aria-expanded', String(aiPanelOpen()));
    const busy = !!(P && typeof P.busy === 'function' && safeMod(() => P.busy()));
    b.dataset.tone = busy ? 'busy' : aiOn() ? '' : 'off';
    b.title = 'Claude에게 시키기 · ⌘J' + (busy ? ' · 일하는 중이에요' : !aiOn() ? ' · 지금은 쓸 수 없어요' : '');
  }
  // 상태가 바뀌면: 버튼·힌트·설정·홈 브리핑·리더 요약을 맞춘다
  let aiWasOn = false;
  function onAIStatus() {
    const was = aiWasOn;
    aiWasOn = aiOn();
    renderAIButton();
    if (el.hintsMain) renderHints();
    if (sheetOpen) renderAISettings();
    if (!aiOn()) { homeBriefRes = null; homeBriefLoading = false; docSums.forEach(e => { e.fetched = false; }); }
    if (state.mode === 'home' && brainOn) { if (aiOn()) homeBriefLoad(was && homeBriefRes ? 'none' : 'auto'); else redrawHome(); }
    syncReaderAI();
  }
  function onAIRun(ev) {
    renderAIButton();
    if (!ev || ev.kind !== 'task' || !ev.status || ev.status === 'running' || aiPanelOpen()) return;
    toast(ev.status === 'done' ? 'Claude가 일을 마쳤어요 · ⌘J로 보기' : ev.status === 'error' ? 'Claude 실행이 실패했어요 · ⌘J로 보기' : 'Claude를 멈췄어요', ev.status === 'error' ? 'error' : '', 5200);
  }
  function onAIDigest(ev) {
    if (!ev) return;
    if (ev.kind === 'home') { if (state.mode === 'home') homeBriefLoad('none'); }
    else if (ev.kind === 'doc' && ev.scope != null) { const id = String(ev.scope); if (docSums.has(id) || state.selectedId === id) aiDocLoad(id, 'none'); }
  }
  // 설정 시트의 Claude 구역
  function renderAISettings() {
    if (!el.aiSettings) return;
    const on = brainOn && !!source && !onboarding && !!aiPanel();
    el.aiSecH.hidden = !on; el.aiSettings.hidden = !on;
    if (!on) { el.aiSettings.innerHTML = ''; return; }
    const p = aiPanel();
    if (typeof p.renderSettings === 'function') safeMod(() => p.renderSettings(el.aiSettings));
  }
  function openAISettings() {
    openSheet();
    requestAnimationFrame(() => { if (el.aiSecH && !el.aiSecH.hidden) el.aiSecH.scrollIntoView({ block: 'start' }); });
  }

  // 홈 브리핑: 홈을 열 때 'auto'(바뀐 게 있을 때만 새로) · 이벤트가 오면 'none'(읽기만) · "다시 정리"는 'force'
  function aiHomeEnter() { if (aiOn() && brainOn) homeBriefLoad('auto'); }
  function homeBriefLoad(run) {
    if (!aiOn() || !brainOn || !source) return Promise.resolve();
    const seq = ++homeBriefSeq;
    if (run === 'force') { homeBriefLoading = true; redrawHome(); }
    return digestFetch('home', { run }).then(res => {
      if (seq !== homeBriefSeq) return;
      homeBriefLoading = false;
      homeBriefRes = res && res.ok !== false ? res : null;
      redrawHome();
    });
  }

  // 리더 문서 요약: 문서를 열면 저장된 요약(run:'none')을 먼저 보이고, "요약" 버튼은 새로 정리(run:'force')
  const docSums = new Map();                 // 문서 id → { res, loading, asked, fetched, seq }
  let docSumCollapsed = false;
  try { docSumCollapsed = localStorage.getItem('synapse.ai.docsum.collapsed') === '1'; } catch (e) { docSumCollapsed = false; }
  function docSumHtml(id) {
    const P = aiPanel();
    if (!aiOn() || !P || typeof P.docSummary !== 'function') return '';
    return safeMod(() => P.docSummary(docSums.get(id), id, { collapsed: docSumCollapsed })) || '';
  }
  function aiDocSlotHtml(doc, dm) {
    if (!doc || doc.id == null || (dm && (dm.loading || dm.error))) return '';
    return '<div class="ap-ds-slot" data-doc="' + esc(doc.id) + '">' + docSumHtml(String(doc.id)) + '</div>';
  }
  function aiSumBtnHtml(doc, dm) {
    if (!aiOn() || !doc || doc.id == null || (dm && (dm.loading || dm.error))) return '';
    const e = docSums.get(String(doc.id)), has = !!(e && e.res && e.res.digest), busy = !!(e && (e.loading || (e.res && e.res.running)));
    return '<button class="btn sm ap-sumbtn" type="button" data-ai-act="doc-summary" data-doc="' + esc(doc.id) + '"' + (busy ? ' disabled' : '') + ' title="' + (has ? 'Claude가 이 문서를 다시 요약해요' : 'Claude가 이 문서를 요약해요') + ' · ⌘⇧K">' +
      icon('sparkle') + '<span>' + (busy ? '요약 중' : '요약') + '</span></button>';
  }
  const aiSumWrapHtml = (doc, dm) => '<span class="ap-sumwrap">' + aiSumBtnHtml(doc, dm) + '</span>';
  function paintDocSum(id) {
    if (edit || moduleOwnsReader() || String(state.selectedId) !== String(id)) return;
    const slot = el.readerInner.querySelector('.ap-ds-slot[data-doc="' + cssEsc(String(id)) + '"]');
    if (slot) { const h = docSumHtml(String(id)); if (slot.__h !== h) { slot.__h = h; slot.innerHTML = h; } }
    const wrap = el.readerInner.querySelector('.ap-sumwrap'), dm = docCache.get(String(id));
    if (wrap && dm && dm.doc) { const h = aiSumBtnHtml(dm.doc, dm); if (wrap.__h !== h) { wrap.__h = h; wrap.innerHTML = h; } }
  }
  function aiDocLoad(id, run, asked) {
    if (!aiOn() || !source || id == null) return Promise.resolve();
    id = String(id);
    let e = docSums.get(id);
    if (!e) { e = {}; docSums.set(id, e); if (docSums.size > 40) docSums.delete(docSums.keys().next().value); }
    const seq = e.seq = (e.seq || 0) + 1;
    e.fetched = true;
    if (asked) e.asked = true;
    if (run === 'force') e.loading = true;
    paintDocSum(id);
    return digestFetch('doc', { docId: id, run }).then(res => {
      if (docSums.get(id) !== e || e.seq !== seq) return;
      e.loading = false;
      e.res = res || null;
      paintDocSum(id);
    });
  }
  function aiDocEnsure(id) {
    if (!aiOn()) return;
    const e = docSums.get(id);
    if (e && e.fetched) { paintDocSum(id); return; }
    aiDocLoad(id, 'none');
  }
  // 상태가 바뀌었을 때 지금 보이는 리더의 요약 단추·상자만 맞춘다(리더를 다시 그리지 않는다)
  function syncReaderAI() {
    if (edit || moduleOwnsReader() || !state.selectedId) return;
    const id = String(state.selectedId);
    if (!docCache.has(id)) return;
    if (aiOn()) aiDocEnsure(id); else paintDocSum(id);
  }
  // 정리를 돌린 빠른 작업(시키기 패널) → 그 화면으로
  function aiShowDigest(kind, scope) {
    if (kind === 'doc' && scope != null) {
      const id = String(scope);
      if (String(state.selectedId) !== id || moduleOwnsReader()) openDocAt(id, null, null, true);
      aiDocLoad(id, 'none', true);
      return;
    }
    if (kind === 'home') { setMode('home'); homeBriefLoad('none'); return; }
    if (kind === 'week' || kind === 'tickets') setMode(kind);
    if (kind === 'tidy') openWorkMapPlan();   // v0.9: 정리 계획 다시 만들기 → 작업 지도의 정리 계획
  }
  // data-ai-act 단추
  function aiAct(act, node, e) {
    switch (act) {
      case 'settings': if (e) e.preventDefault(); openAISettings(); break;
      case 'doc-summary': { const id = node.dataset.doc || state.selectedId; if (id != null) aiDocLoad(id, 'force', true); break; }
      case 'docsum-redo': if (state.selectedId != null) aiDocLoad(state.selectedId, 'force', true); break;
      case 'docsum-toggle':
        docSumCollapsed = !docSumCollapsed;
        try { localStorage.setItem('synapse.ai.docsum.collapsed', docSumCollapsed ? '1' : '0'); } catch (err) { /* 기억하지 못해도 괜찮다 */ }
        if (state.selectedId != null) paintDocSum(state.selectedId);
        break;
      case 'home-redo': homeBriefLoad('force'); break;
      case 'retry': {   // 내 구역(리더 요약 상자·홈 브리핑)의 다시 시도만. 이번 주·티켓은 그 모듈이 직접 처리한다.
        const ds = node.closest && node.closest('.ap-ds-slot'), br = node.closest && node.closest('.ap-brief');
        if (ds) aiDocLoad(ds.dataset.doc, 'force', true);
        else if (br) homeBriefLoad('force');
        break;
      }
    }
  }

  // v0.8: ⌘⇧K — Claude를 쓸 수 있으면 지금 화면에 맞는 빠른 작업으로 시키기 패널을 연다. 쓸 수 없으면 예전처럼 지시문을 복사한다.
  function askClaude() {
    if (aiOn() && brainOn && aiPanel()) {
      // 문서가 열려 있으면 그 문서 요약, 아니면 화면에 맞는 빠른 작업(정리함 → 자리 찾기 · 티켓 → 멈춘 티켓 정리 · 이번 주 → 다시 정리). 패널이 미리 골라 두고 ↵로 시킨다.
      const preset = aiOpenDocId() ? 'doc-summary' : { queue: 'organize', tickets: 'ticket-cleanup', week: 'week', workmap: 'tidy' }[state.mode] || null;
      openAIPanel(preset ? { preset } : {});
      return;
    }
    copyClaudeInstruction();
  }
  function copyClaudeInstruction() {
    let p = { context: state.mode === 'week' ? 'week' : 'queue' };
    const t = state.mode === 'home' || state.mode === 'map' ? feedbackTarget() : null;
    if (t && /^thread:/.test(t.id)) p = { context: 'thread', id: t.id };
    brainCall('claudeInstruction', p).then(r => {
      if (brainFailed(r) || !r.text) { toast((r && r.error) || '지시문을 만들지 못했어요', 'error'); return; }
      copyText(String(r.text), 'Claude에게 줄 지시문을 복사했어요 · Claude Code에 붙여 넣으세요');
    });
  }
  // v0.9 묶음 승인 뒤 ⌥⌘Z: 그 배치들을 역순으로 모두 되돌린다. 일부만 되돌려지면 사실대로 알린다.
  async function undoGroup() {
    const ids = lastAppliedBatch.slice();
    undoBusy = true;
    let n = 0, ok = 0, conf = 0, err = '';
    for (let i = ids.length - 1; i >= 0; i--) {
      const r = await brainCall('tidyUndo', { batchId: ids[i] });
      if (brainFailed(r)) { err = (r && r.error) || '되돌리지 못했어요'; continue; }
      ok++; n += Number(r.undone != null ? r.undone : r.restored) || 0; conf += Array.isArray(r.conflicts) ? r.conflicts.length : 0;
    }
    undoBusy = false;
    lastAppliedBatch = ok === ids.length ? null : ids.filter((b, i) => i < ids.length - ok);
    if (lastAppliedBatch && !lastAppliedBatch.length) lastAppliedBatch = null;
    onBrainEvent('pending'); onBrainEvent('tidy');
    if (!ok) toast(err || '되돌리지 못했어요', 'error');
    else if (ok < ids.length || conf) toast('일부만 되돌렸어요 · 배치 ' + ok + '/' + ids.length + '개, ' + num(n) + '개' + (conf ? ' · 이미 바뀐 것 ' + conf + '개는 그대로 뒀어요' : '') + (err ? ' · ' + err : ''), 'error', 7000);
    else toast('되돌렸어요 · ' + num(n) + '개');
    if (state.mode === 'home') scheduleHome();
  }
  function undoLast() {
    if (undoBusy) return;
    if (!lastAppliedBatch) { toast('되돌릴 최근 정리가 없어요 · ⌘Y에서 고를 수 있어요'); return; }
    if (Array.isArray(lastAppliedBatch)) { undoGroup(); return; }
    undoBusy = true;
    const batchId = lastAppliedBatch, tidy = /^t2/.test(String(batchId));   // v0.9: 정리 비서 배치는 tidyUndo ({ok, undone, conflicts})
    brainCall(tidy ? 'tidyUndo' : 'undo', { batchId }).then(r => {
      undoBusy = false;
      if (brainFailed(r)) { toast((r && r.error) || '되돌리지 못했어요', 'error'); return; }
      if (lastAppliedBatch === batchId) lastAppliedBatch = null;
      onBrainEvent('pending');   // 정리함 알림·카드를 새로 그린다
      if (tidy) onBrainEvent('tidy');
      const conf = Array.isArray(r.conflicts) ? r.conflicts : [], n = tidy ? (r.undone != null ? r.undone : r.restored) : r.restored;
      if (conf.length) toast('되돌렸어요 · ' + num(n) + '개 · 이미 바뀐 파일 ' + conf.length + '개는 그대로 뒀어요: ' + conf.slice(0, 3).map(c => c.path).join(', '), 'error', 7000);
      else toast('되돌렸어요 · ' + num(n) + '개');
      if (state.mode === 'home') scheduleHome();
    }, () => { undoBusy = false; });
  }
  function copyWeek() {
    brainCall('week', { offset: 0 }).then(r => {
      if (brainFailed(r) || typeof r.copyText !== 'string') { toast((r && r.error) || '이번 주 내용을 가져오지 못했어요', 'error'); return; }
      copyText(r.copyText, '주간보고용으로 복사했어요', t => { if (window.SynapseWeek && typeof window.SynapseWeek.showCopyBox === 'function') window.SynapseWeek.showCopyBox(t); else toast('복사하지 못했어요 · 직접 선택해 복사해 주세요', 'error'); });
    });
  }
  function openAiLog() {
    const p = panel();
    if (!p || typeof p.openLog !== 'function') { toast('AI 기록 화면은 준비 중이에요'); return; }
    closeWhy(false);
    if (panelOpen()) safeMod(() => p.closeLog()); else safeMod(() => p.openLog());
  }
  function refreshQueueCount() {
    if (!brainOn) return;
    brainCall('pending').then(r => {
      if (brainFailed(r) || !Array.isArray(r.cards)) return;
      queueCount = r.cards.length + (Number(r.more) || 0);
      renderModes();
    });
  }

  // ---------------------------------------------------------------------------
  // U2 모듈 붙이기 (§9.9): 목록 칸 = #mod-list, 리더 칸 = #mod-reader (편집기·리더 본문과 따로)
  function modFor(mode) { const m = window[MOD_NAMES[mode]]; return m && typeof m.mount === 'function' ? m : null; }
  function mountModule(mode) {
    const mod = modFor(mode);
    el.results.hidden = true; el.modList.hidden = false;
    if (mounted && mounted.mode === mode && mounted.mod === mod) { if (mod && mod.refresh) safeMod(() => mod.refresh()); syncModReader(); return; }
    unmountModule();
    el.results.hidden = true; el.modList.hidden = false;
    mounted = { mode, mod };
    if (!mod) {
      el.modList.innerHTML = '<div class="list-empty mod-wait">' + icon(mode === 'queue' ? 'inbox' : mode === 'workmap' ? 'workmap' : 'calendar') + '<strong>' + esc(MODE_LABEL[mode]) + ' 화면은 준비 중이에요</strong>' +
        '<p>이 화면을 그리는 부분이 아직 들어오지 않았어요. 홈(⌘1)이나 그래프(⌥⌘2)를 써 주세요.</p></div>';
      syncModReader();
      return;
    }
    ensureInit(mod);
    el.modList.textContent = ''; el.modReader.textContent = '';
    safeMod(() => mod.mount(el.modList, el.modReader));
    if (FOCUS_MODS.has(mode) && typeof mod.focus === 'function') safeMod(() => mod.focus());
    syncModReader();
  }
  function unmountModule() {
    if (!mounted) return;
    const m = mounted;
    mounted = null;
    if (m.mod && typeof m.mod.unmount === 'function') safeMod(() => m.mod.unmount());
    el.modList.textContent = ''; el.modReader.textContent = '';
    el.modList.hidden = true; el.results.hidden = false;
    el.reader.classList.remove('is-module'); el.modReader.hidden = true;
    el.lastReaderId = null; // 정리함이 리더 칸을 비웠으니 다시 그린다
  }
  const moduleOwnsReader = () => !!mounted && !state.reading;
  function syncModReader() {
    const own = moduleOwnsReader();
    el.reader.classList.toggle('is-module', own);
    el.modReader.hidden = !own;
    if (own) { el.reader.classList.remove('is-empty'); const old = el.readerInner.querySelector('.edit-away'); if (old) old.remove(); el.lastReaderId = null; }
    // 정리함·이번 주에서도 저장하지 않은 편집 안내를 리더 칸 위에 둔다
    const away = own ? editAwayHtml() : '';
    if (el.modAway.dataset.html !== away) { el.modAway.innerHTML = away; el.modAway.dataset.html = away; }
    el.modAway.hidden = !away;
    el.reader.classList.toggle('has-away', !!away);
  }

  // ---------------------------------------------------------------------------
  // 사서 이벤트: 홈은 마지막 키 입력 3초 뒤에 반영한다(보는 중 순서가 바뀌지 않게)
  // 같은 종류는 약 150ms 모아 한 번만 처리한다
  const brainQueue = new Set();
  let brainQueueTimer = 0;
  function onBrainEvent(type) {
    brainQueue.add(String(type));
    if (!brainQueueTimer) brainQueueTimer = setTimeout(() => { brainQueueTimer = 0; const list = [...brainQueue]; brainQueue.clear(); list.forEach(handleBrainEvent); }, 150);
  }
  function handleBrainEvent(type) {
    if (!brainOn || !source || onboarding) return;
    const p = window.SynapseBrainPanel;
    if (type === 'home') { scheduleHome(); refreshWorkMap(); }
    else if (type === 'pending') {
      refreshQueueCount();
      if (mounted && mounted.mode === 'queue' && mounted.mod && mounted.mod.refresh) safeMod(() => mounted.mod.refresh());
      refreshWorkMap();
    } else if (type === 'tidy') {   // v0.9 정리 비서: 작업 지도·정리함(tidy 카드)·설정을 다시 읽는다
      refreshWorkMap();
      refreshQueueCount();
      if (mounted && mounted.mode === 'queue' && mounted.mod && mounted.mod.refresh) safeMod(() => mounted.mod.refresh());
      if (p && typeof p.refresh === 'function') safeMod(() => p.refresh());
      if (state.mode === 'home') scheduleHome();
    } else if (type === 'log' || type === 'settings' || type === 'policy') {
      if (p && typeof p.refresh === 'function') safeMod(() => p.refresh());
      else if (type === 'log' && panelOpen()) safeMod(() => p.openLog());
      else if (sheetOpen && type !== 'log') renderBrainSettings();
      if (type === 'policy' && mounted && mounted.mode === 'queue' && mounted.mod && mounted.mod.refresh) safeMod(() => mounted.mod.refresh());
    }
  }
  // 작업 지도가 붙어 있으면 다시 읽게 한다 (모듈이 1초씩 묶는다)
  function refreshWorkMap() {
    if (mounted && mounted.mode === 'workmap' && mounted.mod && mounted.mod.refresh) safeMod(() => mounted.mod.refresh());
  }
  // 정리 계획 판을 연 작업 지도로 (홈 정리 한 줄·리뷰 카드·빠른 작업 "정리 계획 다시 만들기")
  function openWorkMapPlan(group) {
    const m = window.SynapseWorkMap;
    if (m && typeof m.openPlan === 'function') safeMod(() => m.openPlan(group));
    setMode('workmap');
  }
  function scheduleHome() {
    clearTimeout(homeTimer);
    const wait = Math.max(0, lastKeyAt + 3000 - Date.now());
    homeTimer = setTimeout(() => {
      homeTimer = 0;
      if (whyState) { homeAfterWhy = true; return; }   // 팝오버를 닫을 때 다시 예약
      if (Date.now() - lastKeyAt < 3000) { scheduleHome(); return; }
      if (state.mode === 'home') { if (!isPending()) refresh({ silent: true }); else scheduleHome(); }
      else if (state.mode === 'map') reloadMap();
      else if (mounted && (mounted.mode === 'week' || mounted.mode === 'tickets') && mounted.mod && mounted.mod.refresh) safeMod(() => mounted.mod.refresh());
    }, wait + 20);
  }

  // ---------------------------------------------------------------------------
  // 키 (§9.1). 검색창에 포커스가 있어도 동작한다. 홈·지도에서는 단일 문자 키를 쓰지 않는다.
  function moduleKey(e) {
    if (!mounted || !mounted.mod || typeof mounted.mod.onKey !== 'function') return false;
    if (safeMod(() => mounted.mod.onKey(e)) !== true) return false;
    e.preventDefault(); e.stopPropagation();
    return true;
  }
  function brainKey(e, c) {
    if (!brainOn || onboarding || !source) return false;
    const { meta, ctrl, alt, shift, stop } = c, k = e.key;
    if (meta && !ctrl && !alt && !shift) {
      const m = { Digit1: 'home', Digit2: 'workmap', Digit3: 'queue', Digit4: 'week', Digit5: 'tickets' }[e.code] || { 1: 'home', 2: 'workmap', 3: 'queue', 4: 'week', 5: 'tickets' }[k];
      if (m) { stop(); hideToast(); setMode(m); return true; }
      if (keyIs(e, ['y', 'Y'], 'KeyY')) { stop(); openAiLog(); return true; }
      if (keyIs(e, ['/', '?'], 'Slash')) { stop(); whenSettled(openWhy); return true; }
      if ((k === 'ArrowUp' || k === 'ArrowDown') && !state.query.trim() && (state.mode === 'home' || state.mode === 'map') && !state.reading && !readerPin) {
        stop(); if (!e.repeat) whenSettled(() => pinOrDemote(k === 'ArrowUp')); return true;
      }
    }
    if (meta && shift && !ctrl && !alt) {
      if (keyIs(e, ['k', 'K'], 'KeyK')) { if (moduleKey(e)) return true; stop(); askClaude(); return true; }
      if (keyIs(e, ['c', 'C'], 'KeyC') && state.mode === 'week') { if (moduleKey(e)) return true; stop(); copyWeek(); return true; }
    }
    if (meta && alt && !ctrl && !shift && e.code === 'Digit2') { stop(); if (!e.repeat) { hideToast(); setMode('map'); } return true; }   // v0.9: ⌥⌘2 = 그래프(예전 지도)
    if (meta && alt && !ctrl && !shift && e.code === 'KeyZ') {
      if (e.repeat) { stop(); return true; }
      if (mounted && !state.reading && moduleKey(e)) return true;   // 정리함이 자기 알림의 배치로 처리
      stop(); undoLast(); return true;
    }
    if (mounted && !state.reading && moduleKey(e)) return true;   // 정리함·이번 주: 모듈이 먼저
    if (mounted && !state.reading && (c.isTab || c.isEnter) && !meta && !ctrl && !alt) return true;   // ⇥·↵: 모듈이 안 받으면 기본 동작(포커스 이동·버튼)
    if (meta || ctrl || alt || state.query.trim() || state.reading) return false;
    if (state.mode === 'home') return homeKey(e, c);
    if (state.mode === 'map' && mapData && (k === 'ArrowDown' || k === 'ArrowUp')) { stop(); whenSettled(() => mapMove(k === 'ArrowDown' ? 1 : -1)); return true; }
    return false;
  }
  function homeKey(e, c) {
    const k = e.key;
    const cr = homeRow();
    if (cr && cr.kind === 'chip') {   // v0.7 B: 급한 것 칩 — ←/→/⇥ 칩 사이 이동, 스페이스·↵ 누르기
      const i = homeOrder.indexOf(cr), nb = d => (homeOrder[i + d] && homeOrder[i + d].kind === 'chip' ? homeOrder[i + d] : null);
      if ((k === 'ArrowRight' || (c.isTab && !c.shift)) && !el.search.value) { c.stop(); const n = nb(1) || (c.isTab ? homeOrder[i + 1] : null); if (n) whenSettled(() => homeSelect(n.key)); return true; }
      if ((k === 'ArrowLeft' || (c.isTab && c.shift)) && !el.search.value) { c.stop(); const n = nb(-1) || (c.isTab ? homeOrder[i - 1] : null); if (n) whenSettled(() => homeSelect(n.key)); return true; }
      if (k === ' ' && !el.search.value) { c.stop(); whenSettled(homeEnter); return true; }
    }
    if (k === 'ArrowDown' || k === 'ArrowUp') { c.stop(); whenSettled(() => homeMove(k === 'ArrowDown' ? 1 : -1)); return true; }
    if (k === 'ArrowRight' && !el.search.value) { c.stop(); toggleDormant(); return true; }
    if (c.isEnter && !c.onButton) { c.stop(); whenSettled(homeEnter); return true; }
    if (c.isTab && !c.shift) { c.stop(); whenSettled(() => { const it = homeItem(); if (it && it.docId != null) follow(String(it.docId)); else toast('이 줄에는 연결 따라갈 문서가 없어요'); }); return true; }
    return false;
  }
  // v0.7 B: 급한 것 칩이 쓰는 앱 쪽 도구. redraw(key)는 목록만 다시 그리고 key 칩에 선택을 둔다.
  const urgentHost = {
    ui: homeUI,
    data: () => homeData,
    call: (m, p) => brainCall(m, p),
    toast: (msg, tone) => toast(msg, tone),
    undoToast: (msg, fn) => undoToast(msg, fn),
    refresh: () => { if (state.mode === 'home') refresh({ silent: true }); },
    redraw(key) {
      if (state.mode !== 'home') return;
      renderHomeList();
      if (key && homeOrder.some(r => r.key === key)) homeUI.sel = key;
      else if (!homeOrder.some(r => r.key === homeUI.sel)) homeUI.sel = defaultHomeSel(homeOrder);
      syncSelectionDom(); renderNav(); focusSearch(false);
    },
  };
  function urgentRun(row) {
    if (window.SynapseHomeUrgent && row.act) window.SynapseHomeUrgent.act(row.act, { dataset: row.data || {} }, urgentHost);
  }
  // 홈·지도·흐름 상세의 data-hact 버튼
  function onHomeAct(act, node) {
    switch (act) {
      case 'sessions-on': sessionsChoice(true); break;
      case 'sessions-later': sessionsChoice(false); break;
      case 'mode': setMode(node.dataset.mode); break;
      case 'tidy-plan': openWorkMapPlan(); break;   // v0.9
      case 'review-dismiss': {   // v0.9: 리뷰 카드는 한 번 닫으면 그날은 숨는다
        const H = window.SynapseHome;
        if (H && typeof H.dismissReview === 'function') H.dismissReview();
        if (state.mode === 'home') { renderHomeList(); if (!homeOrder.some(r => r.key === homeUI.sel)) homeUI.sel = defaultHomeSel(homeOrder); syncSelectionDom(); renderNav(); }
        break;
      }
      case 'settings': openSheet(); requestAnimationFrame(() => { if (!el.brainSettings.hidden) el.brainSettings.scrollIntoView({ block: 'start' }); }); break;
      case 'restart':
        brainCall('setBrainSetting', { key: 'brain.stopped', value: '0' }).then(r => {
          if (brainFailed(r)) { toast((r && r.error) || '다시 시작하지 못했어요', 'error'); return; }
          toast('사서를 다시 시작했어요'); if (state.mode === 'home') refresh({ silent: true });
        });
        break;
      case 'open-doc': openDocAt(node.dataset.doc, node.dataset.line, null, true); break;
      case 'urgent-scope': case 'urgent-project': case 'urgent-more': case 'urgent-flip':   // v0.7 B: 급한 것 거르기 (src/homeurgent.js)
        if (window.SynapseHomeUrgent) window.SynapseHomeUrgent.act(act, node, urgentHost); break;
      case 'why-close': closeWhy(true); break;
      case 'why-reason': openDocAt(node.dataset.doc, node.dataset.line, null, true); break;
      case 'why-act': whyAction(node.dataset.wact); break;
      case 'why-scope': if (whyState && !whyState.busy) runFeedback(whyState.id, 'demote', node.dataset.scope === 'always' ? 'always' : 'week'); break;
    }
  }
  // 설정 시트의 "사서" 섹션 — 안은 SynapseBrainPanel.renderSettings가 그린다
  function renderBrainSettings() {
    const on = brainOn && !!source && !onboarding;
    el.brainSecH.hidden = !on; el.brainSettings.hidden = !on;
    if (!on) { el.brainSettings.innerHTML = ''; return; }
    const p = panel();
    if (p && typeof p.renderSettings === 'function') { el.brainSecH.hidden = true; safeMod(() => p.renderSettings(el.brainSettings)); return; }   // 제목은 패널이 그린다
    el.brainSettings.innerHTML = '<div class="set-group"><p class="set-note">' + icon('info') + '사서 설정은 준비 중이에요. 세션 기록·기기 AI·정리·MCP 설정이 여기에 생겨요.</p></div>';
  }
  // 푸터 단축키 힌트 (모드별)
  const HINTS = {
    home: [['↑↓', '이동'], ['↵', '열기'], ['⌘/', '왜?'], ['⌘↑', '항상 위'], ['⌘↓', '덜 중요'], ['→', '잠듦']],
    map: [['↑↓', '흐름'], ['↵', '읽기'], ['⇥', '연결 따라가기'], ['⌘/', '왜?']],
    workmap: [['↑↓', '이동'], ['←→', '접기·펼치기'], ['↵', '열기'], ['⇥', '제안 카드'], ['p', '정리 계획'], ['g', '연결 보기'], ['⌥⌘2', '그래프']],
    queue: [['y', '승인'], ['n', '거절'], ['e', '목적지'], ['s', '나중에'], ['⌥⌘Z', '되돌리기']],
    week: [['⌘⇧C', '주간보고용 복사'], ['⌘⇧K', 'Claude에게 맡기기']],
    tickets: [['↑↓', '이동'], ['↵', '열기'], ['⌘↵', '브라우저에서'], ['⇥', '칩·내 담당']],
    base: [['↑↓', '이동'], ['↵', '읽기'], ['⇥', '연결 따라가기'], ['⌘[', '뒤로']],
  };
  // v0.8: 이번 주가 Claude 보기면(막대의 복사 단추가 data-act="copy-ai") ⌘⇧C는 "보고 글 복사"다
  const weekReportView = () => state.mode === 'week' && !!(el.modList && el.modList.querySelector('.bw-bar [data-act="copy-ai"]'));
  function renderHints() {
    const key = brainOn && isBrainMode(state.mode) && !state.reading ? (state.mode === 'map' && !mapData ? 'base' : state.mode) : 'base';
    const ai = brainOn && !!aiStat && key !== 'base';   // v0.8: Claude를 지원하는 사서 화면에는 ⌘J 안내를 더한다
    const rep = key === 'week' && weekReportView();
    const sig = key + (rep ? '+rep' : '') + (ai ? '+ai' : '');
    if (el.hintsMain.dataset.key === sig) return;
    el.hintsMain.dataset.key = sig;
    el.hintsMain.innerHTML = HINTS[key].map(([k, t]) => (rep && k === '⌘⇧C' ? [k, '보고 글 복사'] : [k, t])).concat(ai ? [['⌘J', 'Claude']] : [])
      .map(([k, t]) => '<span class="hint"><kbd>' + esc(k) + '</kbd>' + esc(t) + '</span>').join('');
  }
  // 이번 주 화면이 Claude 보기·목록 보기를 오갈 때(앱이 모르게 일어난다) 푸터 힌트를 맞춘다
  let hintObs = null, hintRaf = 0;
  function watchWeekHint() {
    if (hintObs || !window.MutationObserver || !el.modList) return;
    hintObs = new MutationObserver(() => {
      if (state.mode !== 'week' || hintRaf) return;
      hintRaf = requestAnimationFrame(() => { hintRaf = 0; renderHints(); });
    });
    hintObs.observe(el.modList, { childList: true, subtree: true });
  }
  function syncKeyed(attr, key) {
    el.results.querySelectorAll('[aria-selected="true"]').forEach(n => n.setAttribute('aria-selected', 'false'));
    let node = null;
    if (key != null) el.results.querySelectorAll('[' + attr + ']').forEach(n => { if (!node && n.getAttribute(attr) === String(key)) node = n; });
    if (node) { node.setAttribute('aria-selected', 'true'); el.search.setAttribute('aria-activedescendant', node.id); } else el.search.removeAttribute('aria-activedescendant');
    return node;
  }
  function todayLabel() { const d = new Date(); return (d.getMonth() + 1) + '월 ' + d.getDate() + '일 ' + '일월화수목금토'[d.getDay()] + '요일'; }

  // QA 핸들 (읽기 전용 + 대기용 idle())
  Object.defineProperty(window, '__synapseDebug', {
    configurable: true,
    value: Object.freeze({
      get state() {
        return { mode: state.mode, query: state.query, focusId: state.focusId, depth: state.depth, selectedId: state.selectedId,
          cluster: state.cluster, selCluster: state.selCluster, showDone: state.showDone,
          reading: state.reading, readerOpen: state.readerOpen, showTags: state.showTags, pinned: state.pinned, narrow,
          hiddenGroups: [...state.hidden], back: state.back.length, forward: state.forward.length,
          visible: view ? view.order.slice() : [] };
      },
      get source() {
        return { active: onboarding ? 'onboarding' : source ? source.kind : 'none', reason: sourceReason, nativeAvailable: !!nativeSrc,
          onboarding, sheetOpen, pending: isPending(), docCache: docCache.size, statusRetry: probe.pending,
          lastStatus: libStatus ? JSON.parse(JSON.stringify(libStatus)) : null };
      },
      get graph() { return graph; },
      get brain() {
        return { on: brainOn, mode: state.mode, prevMode: state.prevMode, homeSel: homeUI.sel, homeOrder: homeOrder.map(r => r.key), dormantOpen: homeUI.dormantOpen,
          mapSel, mapThreads: mapData ? mapData.threads.length : null, archiveShown, mounted: mounted ? mounted.mode : null, moduleReady: !!(mounted && mounted.mod),
          why: whyState ? { id: whyState.id, phase: whyState.phase, loading: !!(whyState.data && whyState.data.loading) } : null, queueCount, wideReader,
          stopMark: stopMark ? Object.assign({}, stopMark) : null, readerPin, panelOpen: panelOpen(),
          ai: { on: aiOn(), stat: !!aiStat, panelOpen: aiPanelOpen(), brief: !!homeBriefRes, briefRows: homeAiRows, docSums: docSums.size } };
      },
      get graphData() { return view ? Object.assign(graphData(), { centerId: view.centerId }) : null; },
      get view() { return view ? { mode: view.mode, sections: view.sections.map(s => ({ key: s.key, title: s.title, ids: s.items.map(i => i.doc.id) })), legend: legendCache.map(e => [e.label, e.n, e.keys.length]), summary: view.summary, chips: view.chips, hiddenDone: view.hiddenDone, doneCount: view.doneCount, doneShown: view.doneShown, doneSummarized: view.doneSummarized, truncated: view.truncated, cluster: view.cluster ? view.cluster.key : null, overview: !!view.overview } : null; },
      // 대기 중인 보기·본문 요청이 끝난 뒤 resolve
      idle() {
        const wait = () => settled().then(() => (state.selectedId && source ? loadDoc(state.selectedId).catch(() => null) : null))
          .then(() => new Promise(r => setTimeout(r, 0))).then(() => (isPending() || modInflight > 0 ? wait() : true));
        return wait();
      },
    }),
  });

  // ===========================================================================
  // v0.6 N — 뒤로/앞으로 버튼 · 마우스 옆 버튼 · 우클릭 메뉴 · 휴지통/옮기기 (C5·C6·C3 호출)
  const menuApi = () => window.SynapseMenu || null;
  let navPress = 0, navHeld = false;      // 길게 누르기 타이머 · 길게 눌러 메뉴가 떴으면 뒤따르는 click 무시
  let undoPending = null;                  // { fn, until } — 토스트 "되돌리기"와 ⌘Z가 부르는 것

  const screenName = s => s.mode === 'search' ? '검색' : s.mode === 'focus' ? '문서 중심' : MODE_LABEL[s.mode] || '전체 그래프';
  function histLabel(s) {
    if (s.mode === 'focus') return titles.get(s.focusId) || '문서';
    return (s.selectedId && titles.get(s.selectedId)) || labelFor(s);
  }
  // 최근 12개 기록 목록 (가장 가까운 것부터). 고르면 그만큼 한 번에 이동.
  function openHistoryMenu(dir, btn) {
    const m = menuApi();
    if (!m) return;
    const list = dir === 'back' ? state.back.slice().reverse() : state.forward.slice().reverse();
    if (!list.length) return;
    const items = list.slice(0, 12).map((s, i) => ({ id: String(i + 1), label: histLabel(s), shortcut: screenName(s) }));
    const r = btn.getBoundingClientRect();
    m.open({ x: r.left, y: r.bottom + 4, items, onPick: k => { if (dir === 'back') goBack(Number(k)); else goForward(Number(k)); } });
  }
  function navStep(dir) {
    const m = menuApi();
    if (modalOpen() || (m && m.dialogOpen())) return;
    if (edit && edit.dirty) { toast('편집 중인 내용이 있어요 · 먼저 저장하거나 버려 주세요'); return; }
    if (dir === 'forward') { if (!goForward()) toast('앞으로 갈 곳이 없어요'); }
    else if (!goBack()) toast('돌아갈 곳이 없어요');
  }
  function bindNavEvents() {
    [[el.navBack, 'back'], [el.navFwd, 'forward']].forEach(([btn, dir]) => {
      if (!btn) return;
      btn.addEventListener('click', () => { if (navHeld) { navHeld = false; return; } navStep(dir); });
      btn.addEventListener('mousedown', e => {
        if (e.button !== 0) return;
        clearTimeout(navPress); navHeld = false;
        navPress = setTimeout(() => { navHeld = true; openHistoryMenu(dir, btn); }, 480);   // 길게 누르면 기록 목록
      });
      ['mouseup', 'mouseleave'].forEach(t => btn.addEventListener(t, () => clearTimeout(navPress)));
    });
    // 브라우저(모의 화면)에서의 마우스 옆 버튼. 앱에서는 네이티브가 먼저 받아 synapseNav로 부른다.
    window.addEventListener('mouseup', e => {
      if (e.button !== 3 && e.button !== 4) return;
      e.preventDefault(); navStep(e.button === 3 ? 'back' : 'forward');
    });
    window.addEventListener('auxclick', e => { if (e.button === 3 || e.button === 4) e.preventDefault(); });
  }

  // 되돌리기 토스트: 8초 안에 버튼이나 ⌘Z
  function undoToast(msg, fn) {
    const ms = 8000;
    el.toast.textContent = '';
    const sp = document.createElement('span'); sp.textContent = msg;
    const b = document.createElement('button'); b.type = 'button'; b.className = 'toast-act'; b.textContent = '되돌리기 ⌘Z';
    b.addEventListener('click', runUndoPending);
    el.toast.append(sp, b);
    el.toast.classList.remove('is-error'); el.toast.classList.add('visible', 'has-action');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { el.toast.classList.remove('visible', 'has-action'); undoPending = null; }, ms);
    undoPending = { fn, until: Date.now() + ms };
  }
  function runUndoPending() {
    const u = undoPending;
    if (!u || Date.now() > u.until) return;
    undoPending = null;
    clearTimeout(toastTimer);
    el.toast.classList.remove('visible', 'has-action');
    u.fn();
  }

  // 파일이 바뀐 뒤 화면을 조용히 새로 그린다(엔진 이벤트도 따로 온다)
  function afterFileChange(goneId) {
    if (goneId != null && state.selectedId === goneId) { state.selectedId = null; state.reading = false; }
    clearDocs(); rawInfo.clear();
    refresh({ silent: true });
  }
  const bridgeErr = (r, fallback) => (r && r.error) || fallback;

  // 휴지통으로 (C3 trashInfo → 확인 → trashDocs → 되돌리기 토스트)
  async function trashDoc(id) {
    id = String(id);
    const m = menuApi();
    if (!source || onboarding || !m) return;
    if (source.kind === 'demo') { toast('예시 자료에서는 쓸 수 없어요'); return; }
    if (edit && edit.id === id && edit.dirty) { toast('저장하지 않은 편집이 있어요 · 먼저 저장하거나 버려 주세요'); return; }
    const info = await brainCall('trashInfo', { ids: [id] });
    if (brainFailed(info)) { toast(bridgeErr(info, '휴지통 정보를 불러오지 못했어요'), 'error'); return; }
    const it = (Array.isArray(info.items) ? info.items : [])[0];
    if (!it) { toast('문서를 찾을 수 없어요', 'error'); return; }
    if (it.canTrash === false) { toast(it.reason || '이 문서는 휴지통으로 옮길 수 없어요'); return; }
    const title = it.title || titles.get(id) || '이 문서';
    const lines = [];
    const inb = Number(it.inbound) || 0;
    if (inb > 0) lines.push({ text: '이 문서를 가리키는 링크 ' + num(inb) + '개가 끊겨요', warn: true });
    lines.push('Synapse 휴지통에 30일 보관 · 정리함에서 되살릴 수 있어요');
    const ok = await m.confirm({ title: '‘' + title + '’' + pp(title, '을', '를') + ' 휴지통으로 옮길까요?', path: it.path, lines, confirmLabel: '휴지통으로 옮기기', danger: true });
    if (!ok) return;
    const r = await brainCall('trashDocs', { ids: [id] });
    if (brainFailed(r)) { toast(bridgeErr(r, '휴지통으로 옮기지 못했어요'), 'error'); return; }
    const moved = Array.isArray(r.moved) ? r.moved : [];
    if (!moved.length) { const sk = (Array.isArray(r.skipped) ? r.skipped : [])[0]; toast((sk && sk.reason) || '휴지통으로 옮기지 못했어요', 'error'); return; }
    const batch = r.batch;
    afterFileChange(id);
    undoToast('휴지통으로 옮겼어요', () => {
      brainCall('restoreTrash', { batch }).then(rr => {
        if (brainFailed(rr)) { toast(bridgeErr(rr, '되살리지 못했어요'), 'error'); return; }
        toast('되살렸어요'); afterFileChange();
      });
    });
  }

  // 폴더 옮기기 (기존 folders → 고르기 → C3 moveDocs → 되돌리기 토스트)
  async function moveDoc(id) {
    id = String(id);
    const m = menuApi();
    if (!source || onboarding || !m) return;
    if (source.kind === 'demo') { toast('예시 자료에서는 쓸 수 없어요'); return; }
    if (edit && edit.id === id && edit.dirty) { toast('저장하지 않은 편집이 있어요 · 먼저 저장하거나 버려 주세요'); return; }
    const f = await brainCall('folders');
    if (brainFailed(f)) { toast(bridgeErr(f, '폴더 목록을 불러오지 못했어요'), 'error'); return; }
    const folders = (Array.isArray(f.folders) ? f.folders : []).map(String).filter(Boolean);
    if (!folders.length) { toast('옮길 수 있는 폴더를 찾지 못했어요'); return; }
    const title = titles.get(id) || '문서';
    const to = await m.pick({
      title: '‘' + title + '’' + pp(title, '을', '를') + ' 어느 폴더로 옮길까요?', placeholder: '폴더 이름으로 찾기', emptyText: '맞는 폴더가 없어요',
      items: folders.map(p => { const parts = p.replace(/\/+$/, '').split('/'); return { value: p, label: parts[parts.length - 1] || p, hint: parts.length > 1 ? parts.slice(0, -1).join('/') : '' }; }),
    });
    if (!to) return;
    const r = await brainCall('moveDocs', { ids: [id], to });
    if (brainFailed(r)) { toast(bridgeErr(r, '옮기지 못했어요'), 'error'); return; }
    const moved = Array.isArray(r.moved) ? r.moved : [];
    if (!moved.length) { const sk = (Array.isArray(r.skipped) ? r.skipped : [])[0]; toast((sk && sk.reason) || '옮기지 못했어요', 'error'); return; }
    afterFileChange();
    const batch = r.batch;
    undoToast('옮겼어요 · ' + to, () => {
      brainCall('undo', { batchId: batch }).then(rr => {
        if (brainFailed(rr)) { toast(bridgeErr(rr, '되돌리지 못했어요'), 'error'); return; }
        toast('되돌렸어요'); afterFileChange();
      });
    });
  }

  // 문서 우클릭 메뉴 (C6)
  function readDoc(id) {
    track('view', id);
    if (selectable(id)) { selectUser(id, { reveal: true }); setReading(true); } else openDocAt(id, null, null, true);
  }
  function docMenuItems(id, dm) {
    const doc = (dm && dm.doc) || (view && view.docs.get(id)) || { id };
    const kind = String(doc.kind || '').toLowerCase();
    const demo = !source || source.kind === 'demo';
    const remote = isRemoteKind(doc.sourceKind) || kind === 'confluence' || kind === 'jira';
    const open = dm && dm.open && dm.open.label ? dm.open : null;
    const items = [{ id: 'read', label: '읽기', shortcut: '↵', icon: 'doc' }];
    if (!demo && !remote && !localEditability(doc)) items.push({ id: 'edit', label: '편집', shortcut: '⌘E', icon: 'edit' });
    items.push({ id: 'focus', label: '이 문서 중심으로', shortcut: '⇥', icon: 'follow' });
    if (!demo && open) {
      items.push({ sep: true });
      if (remote) items.push({ id: 'open', label: '브라우저에서 열기', shortcut: '⌘O', icon: 'external' });
      else {
        items.push({ id: 'open', label: '기본 앱으로 열기', shortcut: '⌘O', icon: 'external' });
        if (open.canObsidian) items.push({ id: 'obsidian', label: '옵시디언에서 열기', icon: 'obsidian' });
        if (open.canReveal) items.push({ id: 'reveal', label: 'Finder에서 보기', shortcut: '⌥⌘R', icon: 'reveal' });
      }
    }
    const copies = [];
    if (remote) {
      if (doc.url || (dm && dm.open && dm.open.url)) copies.push({ id: 'copy-url', label: '링크 복사', icon: 'link' });
      if (kind === 'jira' && ticketKey(doc)) copies.push({ id: 'copy-key', label: '티켓 키 복사', icon: 'copy' });
    } else {
      if (doc.path) copies.push({ id: 'copy-path', label: '경로 복사', icon: 'copy' });
      if (EDIT_KINDS.has(kind) && (doc.title || doc.path)) copies.push({ id: 'copy-wiki', label: '위키링크 복사', icon: 'link' });
    }
    if (copies.length) { items.push({ sep: true }); items.push(...copies); }
    if (!demo && !remote) {
      items.push({ sep: true });
      items.push({ id: 'move', label: '옮기기…', icon: 'move' });
      items.push({ id: 'trash', label: '휴지통으로 옮기기', shortcut: '⌘⌫', icon: 'trash', danger: true });
    }
    return items;
  }
  const ticketKey = doc => { const m = /\b[A-Z][A-Z0-9]+-\d+\b/.exec(String(doc.title || '') + ' ' + String(doc.path || '')); return m ? m[0] : ''; };
  function docMenuPick(key, id, dm) {
    const doc = (dm && dm.doc) || (view && view.docs.get(id)) || { id };
    switch (key) {
      case 'read': readDoc(id); break;
      case 'edit':
        if (state.selectedId !== id) { if (selectable(id)) selectUser(id, { reveal: true }); else openDocAt(id, null, null, true); }
        whenSettled(enterEdit); break;
      case 'focus': follow(id); break;
      case 'open': openOriginalById(id, 'default'); break;
      case 'obsidian': openOriginalById(id, 'obsidian'); break;
      case 'reveal': openOriginalById(id, 'reveal'); break;
      case 'copy-path': copyText(String(doc.filePath || doc.path || ''), '경로를 복사했어요'); break;
      case 'copy-wiki': {
        const base = String(doc.path || '').split('/').pop().replace(/\.(md|markdown|txt|text)$/i, '') || String(doc.title || '');
        copyText('[[' + base + ']]', '위키링크를 복사했어요'); break;
      }
      case 'copy-key': copyText(ticketKey(doc), '티켓 키를 복사했어요'); break;
      case 'copy-url': copyText(String(doc.url || (dm && dm.open && dm.open.url) || ''), '링크를 복사했어요'); break;
      case 'move': moveDoc(id); break;
      case 'trash': trashDoc(id); break;
    }
  }
  function openDocMenu(id, x, y, from) {
    const m = menuApi();
    if (id == null || !m || !source || onboarding || modalOpen()) return;
    id = String(id);
    const go = dm => { const items = docMenuItems(id, dm); if (items.length) m.open({ x, y, items, onPick: key => docMenuPick(key, id, dm) }); };
    const cached = docCache.get(id);
    if (cached) go(cached); else loadDoc(id).then(go, () => go(null));
  }
  // 오른쪽 클릭: 헤더 ‹ › = 기록 목록, 결과 행·홈 줄·지도 줄·관련 문서 줄 = 문서 메뉴
  function onDocContext(e) {
    if (modalOpen()) return;
    const t = e.target;
    if (!t || !t.closest) return;
    const nb = t.closest('#nav-back, #nav-fwd');
    if (nb) { openHistoryMenu(nb === el.navBack ? 'back' : 'forward', nb); return; }
    let id = null;
    const it = t.closest('.item[data-id]');
    if (it) { id = it.dataset.id; if (selectable(id)) select(id, { scroll: false }); }
    else if (t.closest('[data-hkey]') && state.mode === 'home') {
      const key = t.closest('[data-hkey]').dataset.hkey;
      homeSelect(key, { scroll: false });
      const row = homeOrder.find(r => r.key === key), d = row && row.item && row.item.docId;
      if (d != null) id = String(d);
    } else if (t.closest('[data-fkey]') && state.mode === 'map') {
      const th = mapThread(t.closest('[data-fkey]').dataset.fkey);
      mapSelect(th ? String(th.id) : null, { scroll: false });
      if (th && th.primaryDocId != null) id = String(th.primaryDocId);
    } else if (t.closest('[data-rel]')) id = t.closest('[data-rel]').dataset.rel;
    else if (t.closest('[data-tkdoc]')) id = t.closest('[data-tkdoc]').dataset.tkdoc;   // v0.7 A: 티켓 화면 줄
    if (id) openDocMenu(id, e.clientX, e.clientY, 'row');
  }

  // ---------------------------------------------------------------------------
  function init() {
    Object.assign(el, {
      app: $('app'), main: $('main'), search: $('search'), searchBox: $('search-box'), count: $('search-count'), clear: $('clear-search'),
      hotkey: $('hotkey-badge'), pin: $('pin-btn'), hide: $('hide-btn'), srcBtn: $('src-btn'),
      kwLabel: $('kw-label'), kwChips: $('kw-chips'), kwSummary: $('kw-summary'),
      results: $('results'), graphHost: $('graph-host'), graphPanel: $('graph-panel'), graphEmpty: $('graph-empty'),
      emptyText: $('graph-empty-text'), emptySub: $('graph-empty-sub'), emptyChips: $('graph-empty-chips'),
      navBack: $('nav-back'), navFwd: $('nav-fwd'),
      backBtn: $('back-btn'), crumbs: $('crumbs'), help: $('g-help'), tagsBtn: $('tags-btn'), depthSeg: $('depth-seg'),
      readerBtn: $('reader-btn'), legend: $('legend'), zoomIn: $('zoom-in'), zoomOut: $('zoom-out'), zoomFit: $('zoom-fit'), zoomPct: $('zoom-pct'),
      reader: $('reader'), readerScroll: $('reader-scroll'), readerInner: $('reader-inner'), readerFoot: $('reader-foot'),
      followBtn: $('follow-btn'), followLabel: $('follow-label'),
      openRow: $('open-row'), openBtn: $('open-btn'), openLabel: $('open-label'), revealBtn: $('reveal-btn'), editBig: $('edit-big'),
      escHint: $('esc-hint'), status: $('status'), statusText: $('status-text'), statusBar: $('status-bar'), statusBarFill: $('status-bar-fill'),
      toast: $('toast'), onboard: $('onboard'),
      scrim: $('sheet-scrim'), sheet: $('sheet'), sheetSub: $('sheet-sub'), srcList: $('src-list'), sheetAdd: $('sheet-add'),
      atlForm: $('atl-form'), atlSite: $('atl-site'), atlEmail: $('atl-email'), atlToken: $('atl-token'), atlSpaces: $('atl-spaces'), atlJql: $('atl-jql'),
      atlError: $('atl-error'), atlSubmit: $('atl-submit'),
      hints: $('hints'), hintsEdit: $('hints-edit'), notices: $('notices'), mcpPanel: $('mcp-panel'),
      onboardDraft: $('onboard-draft'), prefAutoHide: $('pref-autohide'), prefAutoHideD: $('pref-autohide-d'),
      mcpClients: $('mcp-clients'), mcpManual: $('mcp-manual'), mcpManualB: $('mcp-manual-b'),
      modes: $('modes'), queueDot: $('queue-dot'), modList: $('mod-list'), modReader: $('mod-reader'), whyPop: $('why-pop'),
      gArchive: $('g-archive'), gDone: $('g-done'), gStatus: $('g-status'), modAway: $('mod-away'), brainSecH: $('brain-sec-h'), brainSettings: $('brain-settings'), hintsMain: $('hints-main'),
    });
    el.sheet.tabIndex = -1;
    // v0.8: 헤더의 Claude 버튼(자료 버튼 왼쪽)과 설정 시트의 Claude 구역 자리(사서 구역 아래)를 만든다
    const aiBtn = document.createElement('button');
    aiBtn.className = 'src-btn ai-btn'; aiBtn.id = 'ai-btn'; aiBtn.type = 'button'; aiBtn.hidden = true;
    aiBtn.setAttribute('aria-label', 'Claude에게 시키기'); aiBtn.setAttribute('aria-haspopup', 'dialog'); aiBtn.setAttribute('aria-expanded', 'false');
    aiBtn.title = 'Claude에게 시키기 · ⌘J';
    aiBtn.innerHTML = icon('sparkle') + '<span class="ai-btn-t">Claude</span><span class="src-btn-dot" aria-hidden="true"></span>';
    el.srcBtn.before(aiBtn);
    el.aiBtn = aiBtn;
    const aiH = document.createElement('h3');
    aiH.className = 'sheet-sec'; aiH.id = 'ai-sec-h'; aiH.textContent = 'Claude'; aiH.hidden = true;
    const aiS = document.createElement('div');
    aiS.className = 'brain-settings'; aiS.id = 'ai-settings'; aiS.hidden = true;
    el.brainSettings.after(aiH, aiS);
    el.aiSecH = aiH; el.aiSettings = aiS;
    watchWeekHint();
    const pageVis = () => {
      document.documentElement.classList.toggle('page-hidden', document.visibilityState === 'hidden');
      if (document.visibilityState === 'visible' && probe.pending) runProbe();
    };
    pageVis();
    document.addEventListener('visibilitychange', pageVis);
    narrow = window.innerWidth < 1040;
    state.readerOpen = !narrow;
    const nat = window.__SYNAPSE_NATIVE__;
    if (nat && typeof nat.pinned === 'boolean') state.pinned = nat.pinned;
    if (nat && typeof nat.autoHide === 'boolean') state.autoHide = nat.autoHide;
    if (nat && typeof nat.showDone === 'boolean') state.showDone = nat.showDone;
    if (pending.pinned != null) state.pinned = pending.pinned;
    applyPinned(state.pinned, false);
    view = adaptView(EMPTY_VM, '');
    renderLayout();      // 그래프를 만들기 전에 열 너비를 확정
    createGraph();
    bindEvents();
    ready = true;
    applyHotkey();
    if (pending.visible != null) applyVisibility(pending.visible);
    const h = apiHandler();
    nativeSrc = h ? createNativeSource(h) : null;
    initNotes();
    chooseSource().then(() => {
      booted = true;
      pendingEvents.splice(0).forEach(onLibraryEvent);
      pendingBrain.splice(0).forEach(onBrainEvent);
      if (!onboarding) focusSearch(true);
      post({ action: 'ready' });
    });
  }

  // 출처 고르기 (CONNECT §8): 브리지 + 출처 ≥1 → 네이티브 / 브리지 + 출처 0 → 첫 실행 안내 / 브라우저 → 예시
  function chooseSource() {
    const data = pendingData; pendingData = null;
    if (data || !nativeSrc) return activate(createDemoSource(data || window.SYNAPSE_DATA || { topics: {}, docs: [] }), data ? 'data' : 'browser');
    renderStatus();
    return nativeSrc.status().then(st => {
      libStatus = normStatus(st);
      if (libStatus.sources.length) return activate(nativeSrc, 'native');
      showOnboarding();
    }, e => {
      // 브리지는 있는데 엔진이 아직 답하지 않음: 브리지는 유지하고, 그동안 예시를 보여 주며 간격을 늘려 다시 묻는다
      console.warn('[synapse] status 실패, 다시 시도해요:', errMsg(e));
      probe.pending = true; probe.delay = 500;
      scheduleProbe();
      return activate(createDemoSource(window.SYNAPSE_DATA || { topics: {}, docs: [] }), 'native-pending');
    });
  }
  // status 재시도: 0.5s → 1s → 2s … 최대 30s. 엔진 이벤트나 창이 다시 보일 때는 바로.
  const probe = { pending: false, delay: 500, timer: 0, busy: false };
  function scheduleProbe() {
    clearTimeout(probe.timer);
    probe.timer = setTimeout(runProbe, probe.delay);
    probe.delay = Math.min(probe.delay * 2, 30000);
  }
  function runProbe() {
    if (!probe.pending || probe.busy || !nativeSrc) return;
    clearTimeout(probe.timer);
    probe.busy = true;
    refreshStatus().then(st => {
      probe.busy = false;
      if (!probe.pending) return;
      if (st) { probe.pending = false; afterStatus(st, 'probe'); } else scheduleProbe();
    });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init, { once: true });
  else init();
})();
