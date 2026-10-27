// Synapse graph engine — window.SynapseGraph (docs/DESIGN.md §6, §7).
// Canvas 2D, hand-written force simulation, no dependencies. Idle = zero work (rAF stops when settled).
(function () {
  'use strict';

  // ---------------------------------------------------------------- constants (§7)
  const SIM = {
    alphaMin: 0.001, alphaDecay: 0.0228, velocityDecay: 0.4, reheat: 0.6,
    chargeDoc: -240, chargeSmall: -120, chargeCluster: -650, distanceMax: 900,
    linkStrength: 0.5, center: 0.045, collidePad: 8, collideStrength: 0.7,
  };
  const LINK_DIST = { link: 80, tag: 95, tagged: 50, cluster: 170, summary: 62 };
  const K_MIN = 0.35, K_MAX = 2.6, FIT_K_MAX = 1.6;
  const TAU = 50;                 // tween time constant (ms) → ~150ms to settle
  const FOLLOW_MS = 900;          // camera follow-fit window after setGraph
  const FIT_MS = 380;
  const LABEL_MARGIN = 24;        // fit margin for labels (screen px)
  const DIM = 0.24;               // alpha factor for nodes outside the hover neighbourhood
  const EDGE_DIM = 0.35;
  const DEFAULT_PAD = { top: 64, right: 24, bottom: 56, left: 24 };

  // ---------------------------------------------------------------- helpers
  const clamp = (v, a, b) => (v < a ? a : v > b ? b : v);
  const lerp = (a, b, t) => a + (b - a) * t;
  const easeOutCubic = t => 1 - Math.pow(1 - t, 3);
  const easeInOutCubic = t => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);
  const now = () => performance.now();
  let reducedMQ = null;
  try { reducedMQ = window.matchMedia ? window.matchMedia('(prefers-reduced-motion: reduce)') : null; } catch (_) { reducedMQ = null; }
  const prefersReduced = () => !!(reducedMQ && reducedMQ.matches);
  function fnv1a(str) {
    let h = 0x811c9dc5;
    for (let i = 0; i < str.length; i++) { h ^= str.charCodeAt(i); h = Math.imul(h, 0x01000193); }
    return h >>> 0;
  }
  function mulberry32(a) {
    return function () {
      a |= 0; a = (a + 0x6D2B79F5) | 0;
      let t = Math.imul(a ^ (a >>> 15), 1 | a);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }
  const jiggleRng = mulberry32(0x5eed);
  const jiggle = () => (jiggleRng() - 0.5) * 1e-6;
  function docRadius(degree) { return clamp(4.5 + 1.7 * Math.sqrt(degree || 0), 5, 12); }
  function linkDistance(kind, strength) {
    if (kind === 'query') return 58 + (1 - clamp(strength == null ? 1 : strength, 0, 1)) * 70;
    if (kind === 'cluster') return 250 - 120 * clamp(strength == null ? 0 : strength, 0, 1);   // 묶음 사이: 세게 이어질수록 가깝게
    return LINK_DIST[kind] || 80;
  }
  function linkKey(a, b, kind) { return a < b ? a + '\u0001' + b + '\u0001' + kind : b + '\u0001' + a + '\u0001' + kind; }
  // Deterministic seeded spot on a disc (same id → same place, independent of input order).
  function seededSpot(id, spread) {
    const rnd = mulberry32(fnv1a(id));
    const ang = rnd() * Math.PI * 2;
    const rad = spread * (0.25 + 0.75 * Math.sqrt(rnd()));
    return { x: Math.cos(ang) * rad, y: Math.sin(ang) * rad };
  }
  function seededJitter(id, amount) {
    const rnd = mulberry32(fnv1a(id) ^ 0x9e3779b9);
    return { x: (rnd() - 0.5) * 2 * amount, y: (rnd() - 0.5) * 2 * amount };
  }

  // ---------------------------------------------------------------- force simulation (d3-force-like)
  // Sim node: { x, y, vx, vy, fx, fy, charge, cr }   Sim link: { s, t, dist, bias }
  function prepareLinks(simLinks) {
    const count = new Map();
    for (const l of simLinks) {
      count.set(l.s, (count.get(l.s) || 0) + 1);
      count.set(l.t, (count.get(l.t) || 0) + 1);
    }
    for (const l of simLinks) {
      const cs = count.get(l.s), ct = count.get(l.t);
      l.bias = cs / (cs + ct);
    }
  }

  function simTick(ns, ls, alpha) {
    const n = ns.length;
    // link springs
    const ks = SIM.linkStrength * alpha;
    for (let i = 0; i < ls.length; i++) {
      const l = ls[i], s = l.s, t = l.t;
      let x = t.x + t.vx - s.x - s.vx || jiggle();
      let y = t.y + t.vy - s.y - s.vy || jiggle();
      let d = Math.sqrt(x * x + y * y);
      d = (d - l.dist) / d * ks;
      x *= d; y *= d;
      t.vx -= x * l.bias; t.vy -= y * l.bias;
      s.vx += x * (1 - l.bias); s.vy += y * (1 - l.bias);
    }
    // charge (O(n²), distanceMax) + collision, one pass over pairs
    const dmax2 = SIM.distanceMax * SIM.distanceMax;
    const cs = SIM.collideStrength;
    for (let i = 0; i < n; i++) {
      const a = ns[i];
      const ax = a.x, ay = a.y, ca = a.charge * alpha, ra = a.cr;
      for (let j = i + 1; j < n; j++) {
        const b = ns[j];
        let x = b.x - ax, y = b.y - ay;
        let l = x * x + y * y;
        if (l < dmax2) {
          if (x === 0) { x = jiggle(); l += x * x; }
          if (y === 0) { y = jiggle(); l += y * y; }
          if (l < 1) l = Math.sqrt(l);
          const wb = b.charge * alpha / l, wa = ca / l;
          a.vx += x * wb; a.vy += y * wb;
          b.vx -= x * wa; b.vy -= y * wa;
        }
        // collision on predicted positions
        const rr = ra + b.cr;
        let cx = (ax + a.vx) - (b.x + b.vx), cy = (ay + a.vy) - (b.y + b.vy);
        let cl = cx * cx + cy * cy;
        if (cl < rr * rr) {
          if (cx === 0) { cx = jiggle(); cl += cx * cx; }
          if (cy === 0) { cy = jiggle(); cl += cy * cy; }
          cl = Math.sqrt(cl);
          const m = (rr - cl) / cl * cs;
          const ra2 = ra * ra, rb2 = b.cr * b.cr, w = rb2 / (ra2 + rb2);
          cx *= m; cy *= m;
          a.vx += cx * w; a.vy += cy * w;
          b.vx -= cx * (1 - w); b.vy -= cy * (1 - w);
        }
      }
    }
    // centering + integration
    const kc = SIM.center * alpha, keep = 1 - SIM.velocityDecay;
    for (let i = 0; i < n; i++) {
      const a = ns[i];
      const kg = kc * (a.grav || 1);                 // 묶음 노드는 중심으로 더 세게 (연결 없는 묶음이 멀리 달아나지 않게)
      if (a.fx != null) { a.x = a.fx; a.vx = 0; }
      else { a.vx += -a.x * kg; a.vx *= keep; a.x += a.vx; }
      if (a.fy != null) { a.y = a.fy; a.vy = 0; }
      else { a.vy += -a.y * kg; a.vy *= keep; a.y += a.vy; }
    }
  }

  // Runs ticks synchronously. Returns the final alpha.
  function runTicks(ns, ls, alpha, alphaTarget, maxTicks) {
    for (let i = 0; i < maxTicks && alpha >= SIM.alphaMin; i++) {
      alpha += (alphaTarget - alpha) * SIM.alphaDecay;
      simTick(ns, ls, alpha);
    }
    return alpha;
  }

  // ---------------------------------------------------------------- engine
  function create(host, callbacks) {
    const cb = callbacks || {};
    const call = (name, ...args) => { try { if (typeof cb[name] === 'function') cb[name](...args); } catch (e) { console.error(e); } };

    // ---------------------------------------------------------------- state
    if (getComputedStyle(host).position === 'static') host.style.position = 'relative';
    const canvas = document.createElement('canvas');
    canvas.className = 'synapse-graph-canvas';
    canvas.setAttribute('aria-hidden', 'true');
    canvas.style.cssText = 'position:absolute;left:0;top:0;width:100%;height:100%;display:block;' +
      'touch-action:none;user-select:none;-webkit-user-select:none;-webkit-touch-callout:none;outline:none;cursor:grab';
    host.appendChild(canvas);
    const ctx = canvas.getContext('2d');

    let kMin = K_MIN;               // 묶음 지도는 좁은 창에서도 전체가 들어오도록 더 작게 줄어든다
    let W = 0, H = 0, dpr = 1;
    let nodes = [];                 // drawn nodes (live + fading out)
    const byId = new Map();
    let links = [];                 // drawn links (live + fading out)
    let simNodes = [], simLinks = [];
    let adj = new Map();            // id → Set(neighbour id), live links only
    let alpha = 0, alphaTarget = 0;
    let layoutKey = null, centerId = null;
    const globalMemory = new Map(); // id → {x,y}: settled global layout (spatial memory)
    const cam = { x: 0, y: 0, k: 1 };
    let camAnim = null;             // { from, to, t0, dur }
    let followUntil = 0;
    let posTween = null;            // { t0, dur }
    let needFit = false;
    const pad = Object.assign({}, DEFAULT_PAD), padTarget = Object.assign({}, DEFAULT_PAD);
    let selectedId = null, pointerHover = null, externalHover = null;
    let pulses = [];
    // v0.5 지도(§9.4): 노드별 색·불투명도·빛(styles)과 강조 집합(focusSet). 물리·배치에는 영향이 없다.
    let styles = null;              // Map id → { topic?: '--topic-<topic>' 키, alpha?: 0..1, glow?: bool }
    let focusSet = null;            // Set(id) | null — 있으면 그 밖의 노드·선을 흐리게
    const FOCUS_DIM = 0.16;
    let paused = false, destroyed = false;
    let raf = 0, lastT = 0, frames = 0;
    let lastZoomReported = NaN;
    let theme = null;
    const perf = { n: 0, ms: 0, last: 0 };
    const textWidths = new Map();

    // ---------------------------------------------------------------- theme
    function readVar(cs, name, fb) { const v = cs.getPropertyValue(name).trim(); return v || fb; }
    function refreshThemeNow() {
      const cs = getComputedStyle(host);
      theme = {
        cs,
        font: readVar(cs, '--font-ui', '-apple-system, BlinkMacSystemFont, "Apple SD Gothic Neo", sans-serif'),
        accent: readVar(cs, '--accent', '#4fd1b0'),
        accentSoft: readVar(cs, '--accent-soft', 'rgba(79,209,176,.16)'),
        text1: readVar(cs, '--text-1', 'rgba(255,255,255,.92)'),
        edge: readVar(cs, '--graph-edge', 'rgba(255,255,255,.16)'),
        edgeTag: readVar(cs, '--graph-edge-tag', 'rgba(255,255,255,.10)'),
        label: readVar(cs, '--graph-label', 'rgba(255,255,255,.80)'),
        labelMuted: readVar(cs, '--graph-label-muted', 'rgba(255,255,255,.46)'),
        halo: readVar(cs, '--graph-label-halo', 'rgba(21,23,28,.92)'),
        ring: readVar(cs, '--graph-node-ring', 'rgba(12,14,18,.85)'),
        grid: readVar(cs, '--graph-grid', 'rgba(255,255,255,.035)'),
        topics: new Map(),
        // v0.6 티켓 상태 색 (styles.css가 아니라 cluster.css가 라이트·다크 모두 정의)
        status: {
          todo: readVar(cs, '--st-todo', '#9aa0aa'), doing: readVar(cs, '--st-doing', '#5aa6f2'), blocked: readVar(cs, '--st-blocked', '#f0a04b'),
          done: readVar(cs, '--st-done', '#6fc47a'), dropped: readVar(cs, '--st-dropped', '#8a8f98'),
        },
      };
      theme.fLabel = '500 12px ' + theme.font;
      theme.fLabelStrong = '600 12px ' + theme.font;
      theme.fTag = '400 11px ' + theme.font;
      theme.fHub = '600 13px ' + theme.font;
      theme.fCluster = '600 13px ' + theme.font;
      theme.fBadge = '700 10px ' + theme.font;
      textWidths.clear();
    }
    function topicColor(topic) {
      const key = topic || '';
      let c = theme.topics.get(key);
      if (!c) { c = (topic && readVar(theme.cs, '--topic-' + topic, '')) || theme.labelMuted; theme.topics.set(key, c); }
      return c;
    }
    function measureText(text, font) {
      const key = font + '\u0001' + text;
      let w = textWidths.get(key);
      if (w == null) { ctx.font = font; w = ctx.measureText(text).width; textWidths.set(key, w); }
      return w;
    }
    refreshThemeNow();

    // ---------------------------------------------------------------- size
    function measure() {
      const w = host.clientWidth, h = host.clientHeight, d = window.devicePixelRatio || 1;
      if (w === W && h === H && d === dpr) return false;
      W = w; H = h; dpr = d;
      canvas.width = Math.max(1, Math.round(W * dpr));
      canvas.height = Math.max(1, Math.round(H * dpr));
      return true;
    }
    const ro = new ResizeObserver(() => {
      if (destroyed || !measure()) return;
      if (W > 0 && H > 0 && (needFit || (camAuto && !followUntil && nodes.some(isLive)))) { needFit = false; fitNow(false); }
      draw(null, true);             // resizing clears the canvas: repaint synchronously (one frame, no loop)
      kick();
    });
    ro.observe(host);

    // ---------------------------------------------------------------- graph data
    function makeNode(id) {
      return { id, x: 0, y: 0, vx: 0, vy: 0, fx: null, fy: null, charge: SIM.chargeDoc, cr: 13,
        r: 0, a: 0, la: 0, h: 0, dying: false, isNew: true, placed: false };
    }
    const isLive = n => !!n && !n.dying;

    function shiftWorld(dx, dy) {
      for (const n of nodes) {
        n.x += dx; n.y += dy;
        if (n.fx != null) n.fx += dx;
        if (n.fy != null) n.fy += dy;
        if (n.tx != null) { n.tx += dx; n.ty += dy; n.px += dx; n.py += dy; }
      }
      cam.x += dx; cam.y += dy;
      if (camAnim) { camAnim.from.x += dx; camAnim.from.y += dy; camAnim.to.x += dx; camAnim.to.y += dy; }
    }

    function placeNewNodes(liveCount) {
      const pending = nodes.filter(n => n.isNew && !n.dying && !n.placed);
      let progress = true;
      while (pending.length && progress) {
        progress = false;
        for (let i = pending.length - 1; i >= 0; i--) {
          const n = pending[i];
          let sx = 0, sy = 0, c = 0;
          for (const m of adj.get(n.id) || []) {
            const o = byId.get(m);
            if (o && !o.dying && (!o.isNew || o.placed)) { sx += o.x; sy += o.y; c++; }
          }
          if (!c) continue;
          const j = seededJitter(n.id, 22);
          n.x = sx / c + j.x; n.y = sy / c + j.y;
          n.placed = true; pending.splice(i, 1); progress = true;
        }
      }
      const spread = 70 + 26 * Math.sqrt(liveCount);
      for (const n of pending) {
        const p = globalMemory.get(n.id) || seededSpot(n.id, spread);
        n.x = p.x; n.y = p.y; n.placed = true;
      }
    }

    function rebuildSim() {
      simNodes = nodes.filter(isLive);
      for (const n of simNodes) {
        if (n.kind === 'keyword' || n.kind === 'summary') {
          n.pillW = measureText(n.label, theme.fHub) + (n.kind === 'summary' ? 40 : 24);   // 요약 노드: 앞에 상태 모양 자리
          n.cr = n.pillW * 0.45 + SIM.collidePad;
        } else if (n.kind === 'cluster') {
          n.cr = Math.max(n.baseR + 30, Math.min(80, measureText(n.label, theme.fCluster) * 0.5 + 12));   // 이름 라벨이 들어갈 자리
        } else if (simNodes.length <= 150) {
          // leave room for the label: collision radius grows with the label width (small graphs only)
          n.cr = Math.max(n.baseR + SIM.collidePad, measureText(labelText(n, false), n.kind === 'tag' ? theme.fTag : theme.fLabel) * 0.35);
        } else n.cr = n.baseR + SIM.collidePad;
      }
      simLinks = [];
      for (const l of links) if (!l.dying) simLinks.push({ s: l.source, t: l.target, dist: l.dist, bias: 0.5 });
      prepareLinks(simLinks);
    }

    // Global layout: deterministic (seeded) + spatial memory. Computes settled targets in a scratch sim.
    function layoutGlobal(snap, fromGlobal) {
      const sc = simNodes.map(n => {
        const known = fromGlobal && !n.isNew ? { x: n.x, y: n.y } : globalMemory.get(n.id);
        return { ref: n, id: n.id, x: known ? known.x : 0, y: known ? known.y : 0, known: !!known,
          vx: 0, vy: 0, fx: null, fy: null, charge: n.charge, cr: n.cr, grav: n.grav };
      });
      const scById = new Map(sc.map(s => [s.id, s]));
      let unknown = sc.filter(s => !s.known), progress = true;
      while (unknown.length && progress) {
        progress = false;
        unknown = unknown.filter(s => {
          let sx = 0, sy = 0, c = 0;
          for (const m of adj.get(s.id) || []) { const o = scById.get(m); if (o && o.known) { sx += o.x; sy += o.y; c++; } }
          if (!c) return true;
          const j = seededJitter(s.id, 22);
          s.x = sx / c + j.x; s.y = sy / c + j.y; s.known = true; progress = true;
          return false;
        });
      }
      const spread = 70 + 26 * Math.sqrt(sc.length);
      for (const s of unknown) { const p = seededSpot(s.id, spread); s.x = p.x; s.y = p.y; }
      const sl = simLinks.map(l => ({ s: scById.get(l.s.id), t: scById.get(l.t.id), dist: l.dist, bias: l.bias }));
      const fresh = unknown.length > 0 || sc.some(s => !globalMemory.has(s.id));
      runTicks(sc, sl, fresh ? 1 : 0.3, 0, 300);
      for (const s of sc) globalMemory.set(s.id, { x: s.x, y: s.y });
      for (const s of sc) {
        const n = s.ref;
        n.vx = n.vy = 0;
        if (snap || n.isNew) { n.x = s.x; n.y = s.y; n.tx = n.ty = null; }
        else { n.px = n.x; n.py = n.y; n.tx = s.x; n.ty = s.y; }
      }
      posTween = snap ? null : { t0: now(), dur: 560 };
      alpha = 0;
    }

    const LINK_KINDS = { link: 1, tag: 1, query: 1, tagged: 1, cluster: 1, summary: 1 };
    function setGraph(data, opts) {
      opts = opts || {};
      const inNodes = (data && Array.isArray(data.nodes)) ? data.nodes : [];
      const inLinks = (data && Array.isArray(data.links)) ? data.links : [];
      const key = opts.layoutKey || 'global';
      kMin = inNodes.some(d => d && d.kind === 'cluster') ? 0.15 : K_MIN;
      let docsMany = false;
      const reduced = prefersReduced();
      const firstShow = !nodes.some(isLive);
      const prevKey = layoutKey;
      const ids = new Set();
      for (const d of inNodes) if (d && d.id != null) ids.add(String(d.id));
      const newCenter = opts.centerId != null && ids.has(String(opts.centerId)) ? String(opts.centerId) : null;
      const endpoint = v => String(v && typeof v === 'object' ? v.id : v);

      // degree fallback (unique neighbours in the given set) when the caller does not pass one
      const degSets = new Map();
      for (const d of inLinks) {
        const s = endpoint(d.source), t = endpoint(d.target);
        if (!degSets.has(s)) degSets.set(s, new Set());
        if (!degSets.has(t)) degSets.set(t, new Set());
        degSets.get(s).add(t); degSets.get(t).add(s);
      }

      // 1) a new center: shift the world (and camera) so it sits at the origin — nothing jumps on screen
      if (newCenter && newCenter !== centerId && !firstShow) {
        const ex = byId.get(newCenter);
        let ox = 0, oy = 0;
        if (isLive(ex)) { ox = ex.x; oy = ex.y; }
        else {
          let c = 0;
          for (const t of degSets.get(newCenter) || []) { const o = byId.get(t); if (isLive(o)) { ox += o.x; oy += o.y; c++; } }
          if (c) { ox /= c; oy /= c; }
        }
        if (ox || oy) shiftWorld(-ox, -oy);
      }

      // 2) merge nodes (existing keep position + velocity)
      const seen = new Set();
      let changed = 0;
      for (const d of inNodes) {
        if (!d || d.id == null) continue;
        const id = String(d.id);
        if (seen.has(id)) continue;
        seen.add(id);
        let n = byId.get(id);
        if (!n) { n = makeNode(id); byId.set(id, n); nodes.push(n); changed++; }
        else if (n.dying) { n.dying = false; changed++; }
        n.label = String(d.label != null ? d.label : id);
        n.fullLabel = d.fullLabel ? String(d.fullLabel) : n.label;
        n.kind = d.kind === 'keyword' || d.kind === 'tag' || d.kind === 'cluster' || d.kind === 'summary' ? d.kind : 'doc';
        n.topic = d.topic || null;
        n.degree = d.degree != null ? +d.degree : (degSets.get(id) ? degSets.get(id).size : 0);
        n.emphasis = d.emphasis || 'normal';
        // v0.6: 묶음 노드(count·openTickets·recent·statusMix)와 티켓 노드(docKind·statusGroup·mine)
        n.count = +d.count || 0; n.openTickets = +d.openTickets || 0; n.recent = +d.recent || 0; n.statusMix = d.statusMix || null;
        n.docKind = d.docKind || null; n.statusGroup = d.statusGroup || null; n.mine = !!d.mine;
        if (n.kind === 'cluster') n.degree = n.count;
        n.baseR = n.kind === 'doc' ? docRadius(n.degree) + (n.emphasis === 'center' ? 3 : 0) : n.kind === 'tag' ? 3.5 : 6;
        n.charge = n.kind === 'doc' ? SIM.chargeDoc : n.kind === 'cluster' ? SIM.chargeCluster : SIM.chargeSmall;
        n.grav = n.kind === 'cluster' && n.emphasis !== 'context' ? 6 : 1;
        if (n.isNew) n.r = n.baseR;
      }
      // 묶음 크기: 문서 수의 제곱근에 비례 (가장 큰 묶음 기준). 이웃(context) 묶음은 조금 작게.
      let maxCount = 1;
      for (const d of inNodes) if (d && d.kind === 'cluster' && d.emphasis !== 'context') maxCount = Math.max(maxCount, +d.count || 0);
      for (const d of inNodes) {
        const n = d && d.id != null ? byId.get(String(d.id)) : null;
        if (!n || n.kind !== 'cluster') continue;
        const ref = n.emphasis === 'context' ? Math.max(maxCount, 30) : maxCount;
        n.baseR = (n.emphasis === 'context' ? 11 : 14) + (n.emphasis === 'context' ? 18 : 34) * Math.sqrt(clamp(n.count / ref, 0, 1));
        if (n.isNew) n.r = n.baseR;
      }
      // 문서 노드가 60개를 넘으면 확대가 작을 때는 연결 많은 상위 25개만 라벨 (v0.6 가독성)
      const docNodes = nodes.filter(n => n.kind === 'doc' && seen.has(n.id));
      docsMany = docNodes.length > 60;
      for (const n of nodes) n.top = false;
      if (docsMany) docNodes.slice().sort((p, q) => (q.degree || 0) - (p.degree || 0)).slice(0, 25).forEach(n => { n.top = true; });
      for (const n of nodes) if (!seen.has(n.id) && !n.dying) { n.dying = true; n.fx = n.fy = null; n.tx = null; changed++; }

      // 3) links (deduplicated, undirected)
      const old = new Map(links.map(l => [l.key, l]));
      const next = [], lseen = new Set();
      let queryCount = 0;
      for (const d of inLinks) {
        const s = endpoint(d.source), t = endpoint(d.target);
        if (s === t || !seen.has(s) || !seen.has(t)) continue;
        const kind = LINK_KINDS[d.kind] ? d.kind : 'link';
        const k = linkKey(s, t, kind);
        if (lseen.has(k)) continue;
        lseen.add(k);
        let l = old.get(k);
        if (l) { old.delete(k); if (l.dying) changed++; l.dying = false; }
        else { l = { key: k, a: (firstShow || reduced) ? 1 : 0, h: 0 }; changed++; }
        l.source = byId.get(s); l.target = byId.get(t); l.kind = kind;
        l.strength = d.strength == null ? 1 : clamp(+d.strength || 0, 0, 1);
        l.weight = +d.weight || 0;
        l.dist = linkDistance(kind, l.strength);
        if (kind === 'query') queryCount++;
        next.push(l);
      }
      for (const l of old.values()) { if (!l.dying) changed++; l.dying = true; next.push(l); }
      // 묶음 사이 연결: 가장 센 연결 대비 비율(strength)로 굵기·거리를 정한다 (제곱근으로 완만하게)
      let maxW = 1;
      for (const l of next) if (l.kind === 'cluster' && !l.dying) maxW = Math.max(maxW, l.weight || 0);
      for (const l of next) {
        if (l.kind !== 'cluster' || l.dying) continue;
        l.strength = clamp(Math.sqrt((l.weight || 0) / maxW), 0, 1);
        // 묶음 사이: 두 원이 겹치지 않을 만큼 + 세게 이어질수록 가깝게. 문서↔이웃 묶음은 문서 구름 바깥에 둔다.
        l.dist = l.source.kind === 'doc' || l.target.kind === 'doc' ? 240 : l.source.baseR + l.target.baseR + 50 + 90 * (1 - l.strength);
      }
      // many matches around one hub: lengthen query springs so labels get room; rank matches for always-on labels
      const qScale = 1 + clamp(queryCount - 5, 0, 12) * 0.07;
      const ranked = [];
      for (const n of nodes) { n.qs = 0; n.topMatch = false; }
      for (const l of next) {
        if (l.dying || l.kind !== 'query') continue;
        l.dist = linkDistance('query', l.strength) * qScale;
        const m = l.source.kind === 'keyword' ? l.target : l.source;
        if (l.strength > m.qs) m.qs = l.strength;
        if (!ranked.includes(m)) ranked.push(m);
      }
      ranked.sort((p, q) => (q.qs - p.qs) || ((q.degree || 0) - (p.degree || 0)));
      for (let i = 0; i < ranked.length && i < 6; i++) ranked[i].topMatch = true;
      links = next;
      adj = new Map();
      for (const l of links) {
        if (l.dying) continue;
        const a = l.source.id, b = l.target.id;
        if (!adj.has(a)) adj.set(a, new Set());
        if (!adj.has(b)) adj.set(b, new Set());
        adj.get(a).add(b); adj.get(b).add(a);
      }

      // 4) center pin
      const centerChanged = newCenter !== centerId;
      if (centerId && centerChanged) { const c = byId.get(centerId); if (c) c.fx = c.fy = null; }
      centerId = newCenter;
      layoutKey = key;
      if (centerId) {
        const c = byId.get(centerId);
        if (c.isNew) { c.x = 0; c.y = 0; c.placed = true; }
        c.fx = 0; c.fy = 0;
      }

      // same structure (e.g. the app re-sent the graph after a selection change): update in place, no reheat/refit
      if (!changed && !centerChanged && key === prevKey && !firstShow) {
        rebuildSim();
        kick();
        return;
      }
      // 5) positions for new nodes, simulation arrays, layout strategy
      placeNewNodes(seen.size);
      rebuildSim();
      posTween = null;
      if (key === 'global' && !centerId) {
        layoutGlobal(firstShow || reduced, prevKey === 'global');
      } else if (firstShow || reduced) {
        alpha = runTicks(simNodes, simLinks, firstShow ? 1 : SIM.reheat, 0, 400);
        for (const n of simNodes) { n.vx = n.vy = 0; }
        if (alpha < SIM.alphaMin) alpha = 0;
      } else {
        alpha = Math.max(alpha, SIM.reheat);
      }
      for (const n of nodes) {
        if (!n.isNew) continue;
        n.a = (firstShow || reduced) ? targetAlpha(n) : 0;
        n.isNew = false; n.placed = false;
      }
      if (reduced) {
        nodes = nodes.filter(n => { if (n.dying) byId.delete(n.id); return !n.dying; });
        links = links.filter(l => !l.dying);
      }

      // 6) camera: first show / reduced motion = instant fit, otherwise follow-fit while settling
      if (firstShow || reduced || W <= 0 || H <= 0) {
        camAnim = null; followUntil = 0;
        if (W > 0 && H > 0) fitNow(false); else needFit = true;
      } else {
        camAnim = null; followUntil = now() + FOLLOW_MS; camAuto = true;
      }
      if (pointerHover && !isLive(byId.get(pointerHover))) { pointerHover = null; call('onHover', null); }
      if (centerChanged && centerId) pulse(centerId);
      if (W > 0 && H > 0) draw(null, firstShow || reduced);   // paint now; rAF (if running) continues the animation
      kick();
    }

    // ---------------------------------------------------------------- frame loop (idle = no rAF)
    let watchdog = 0;
    function kick() {
      if (destroyed || paused || W <= 0 || H <= 0) return;
      if (!raf) { lastT = now(); raf = requestAnimationFrame(frame); }
      // rAF is suspended in hidden / off-screen web views: if no frame ran shortly after a kick,
      // jump every animation to its end state and paint once, so the canvas is never stale or blank.
      if (!watchdog) {
        const f0 = frames;
        watchdog = setTimeout(() => {
          watchdog = 0;
          if (!destroyed && !paused && raf && frames === f0) { catchUp(); draw(null, true); }
        }, 180);
      }
    }
    function catchUp() {
      finishPosTween();
      if (!drag && (alpha >= SIM.alphaMin || alphaTarget > 0)) {
        alpha = runTicks(simNodes, simLinks, alpha, alphaTarget, 400);
        for (const n of simNodes) { n.vx = n.vy = 0; }
        if (alpha < SIM.alphaMin) { alpha = 0; onSettled(); }
      }
      if (followUntil) { followUntil = 0; const t = fitTarget(); cam.x = t.x; cam.y = t.y; cam.k = t.k; }
      if (camAnim) { cam.x = camAnim.to.x; cam.y = camAnim.to.y; cam.k = camAnim.to.k; camAnim = null; }
      Object.assign(pad, padTarget);
      stepTweens(1e6);
      pulses = [];
      reportZoom();
    }
    function frame(t) {
      raf = 0;
      if (destroyed || paused) return;
      const t0 = now();
      const dt = clamp(t - lastT, 0, 64);
      lastT = t;
      frames++;
      let busy = false;
      if (posTween) busy = stepPosTween(t0);
      else if (alpha >= SIM.alphaMin || alphaTarget > 0) {
        alpha += (alphaTarget - alpha) * SIM.alphaDecay;
        simTick(simNodes, simLinks, alpha);
        busy = true;
        if (alpha < SIM.alphaMin && alphaTarget === 0) { alpha = 0; onSettled(); }
      }
      if (stepCamera(t0, dt)) busy = true;
      if (stepTweens(dt)) busy = true;
      if (draw(dt)) busy = true;
      if (pulses.length) busy = true;
      if (drag) busy = true;
      const spent = now() - t0;
      perf.n++; perf.ms += spent; perf.last = spent;
      if (busy) raf = requestAnimationFrame(frame);
    }
    function onSettled() {
      if (layoutKey === 'global' && !centerId) for (const n of simNodes) globalMemory.set(n.id, { x: n.x, y: n.y });
    }
    function stepPosTween(t) {
      const p = clamp((t - posTween.t0) / posTween.dur, 0, 1), e = easeOutCubic(p);
      for (const n of nodes) {
        if (n.tx == null) continue;
        n.x = lerp(n.px, n.tx, e); n.y = lerp(n.py, n.ty, e);
        if (p >= 1) n.tx = n.ty = null;
      }
      if (p >= 1) { posTween = null; alpha = 0; }
      return true;
    }

    // ---------------------------------------------------------------- tweens (alpha / radius / highlight / padding)
    function hoverId() { const h = pointerHover || externalHover; return isLive(byId.get(h)) ? h : null; }
    function neighbourhood() {
      const h = hoverId();
      if (!h) return null;
      const s = new Set([h]);
      for (const m of adj.get(h) || []) s.add(m);
      return s;
    }
    function targetAlpha(n, hood) {
      if (n.dying) return 0;
      const focused = n.id === selectedId || n.id === hoverId();
      let a = n.emphasis === 'context' ? (focused ? 1 : hood && hood.has(n.id) ? 0.72 : n.kind === 'cluster' ? 0.66 : 0.38) : 1;
      if (hood && !hood.has(n.id) && n.id !== selectedId) a *= DIM;
      const st = styles && styles.get(n.id);
      if (st && st.alpha != null && !focused) a *= clamp(+st.alpha || 0, 0, 1);
      if (focusSet && !focusSet.has(n.id) && !focused && !(hood && hood.has(n.id))) a *= FOCUS_DIM;
      return a;
    }
    function stepTweens(dt) {
      const f = prefersReduced() ? 1 : 1 - Math.exp(-dt / TAU);
      const hood = neighbourhood(), h = hoverId();
      let busy = false, removed = false;
      for (const k of ['top', 'right', 'bottom', 'left']) {
        const d = padTarget[k] - pad[k];
        if (Math.abs(d) > 0.25) { pad[k] += d * f; busy = true; } else pad[k] = padTarget[k];
      }
      for (const n of nodes) {
        const ta = targetAlpha(n, hood);
        const tr = n.baseR + (n.id === h ? 1.5 : 0);
        if (Math.abs(ta - n.a) > 0.004) { n.a += (ta - n.a) * f; busy = true; } else n.a = ta;
        if (Math.abs(tr - n.r) > 0.02) { n.r += (tr - n.r) * f; busy = true; } else n.r = tr;
        if (n.dying && n.a <= 0.01) removed = true;
      }
      for (const l of links) {
        const touch = !!(h && (l.source.id === h || l.target.id === h)) ||
          !!(selectedId && (l.source.id === selectedId || l.target.id === selectedId));
        const out = focusSet && !touch && !(focusSet.has(l.source.id) && focusSet.has(l.target.id));
        const ta = l.dying || l.source.dying || l.target.dying ? 0 : (hood && !touch ? EDGE_DIM : 1) * (out ? FOCUS_DIM : 1);
        const th = touch && !l.dying ? 1 : 0;
        if (Math.abs(ta - l.a) > 0.004) { l.a += (ta - l.a) * f; busy = true; } else l.a = ta;
        if (Math.abs(th - l.h) > 0.004) { l.h += (th - l.h) * f; busy = true; } else l.h = th;
        if (l.dying && l.a <= 0.01) removed = true;
      }
      if (removed) {
        nodes = nodes.filter(n => { const gone = n.dying && n.a <= 0.01; if (gone) byId.delete(n.id); return !gone; });
        links = links.filter(l => !(l.dying && l.a <= 0.01) && byId.has(l.source.id) && byId.has(l.target.id));
      }
      return busy;
    }

    // ---------------------------------------------------------------- camera
    const nodeScale = k => clamp(Math.sqrt(k), kMin < K_MIN ? 0.38 : 0.6, 1.4);   // 묶음 지도(작게 줄어드는 화면)에서는 문서 점도 더 작아질 수 있다
    // 묶음 버블은 거의 배율에 비례해 줄인다(간격은 배율에 비례하므로 줄여도 겹치지 않는다)
    const clusterScale = k => clamp(Math.pow(k, 0.85), 0.12, 1.3);
    const scaleOf = (n, k, sc) => (n.kind === 'cluster' ? clusterScale(k) : sc);
    const HUB_H = 28;
    function viewCenter() {
      return { x: pad.left + (W - pad.left - pad.right) / 2, y: pad.top + (H - pad.top - pad.bottom) / 2 };
    }
    function toWorld(sx, sy) {
      const vc = viewCenter();
      return { x: (sx - vc.x) / cam.k + cam.x, y: (sy - vc.y) / cam.k + cam.y };
    }
    function reportZoom() {
      if (!(Math.abs(cam.k - lastZoomReported) < 1e-4)) { lastZoomReported = cam.k; call('onZoom', cam.k); }
    }
    let camAuto = true;           // no user pan/zoom/drag since the last setGraph/fit → resize re-fits
    function stopCamera() { followUntil = 0; camAnim = null; camAuto = false; }
    function fitTarget() {
      let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
      for (const n of nodes) {
        if (n.dying) continue;
        const x = n.tx != null ? n.tx : n.x, y = n.ty != null ? n.ty : n.y;
        const r = n.kind === 'keyword' || n.kind === 'summary' ? 20 : n.baseR;
        if (x - r < minX) minX = x - r;
        if (x + r > maxX) maxX = x + r;
        if (y - r < minY) minY = y - r;
        if (y + r > maxY) maxY = y + r;
      }
      if (minX === Infinity) return { x: 0, y: 0, k: cam.k };
      const aw = Math.max(60, W - padTarget.left - padTarget.right - 2 * (LABEL_MARGIN + 18));
      const ah = Math.max(60, H - padTarget.top - padTarget.bottom - 2 * LABEL_MARGIN - 18);
      const k = clamp(Math.min(aw / Math.max(1, maxX - minX), ah / Math.max(1, maxY - minY)), kMin, FIT_K_MAX);
      return { x: (minX + maxX) / 2, y: (minY + maxY) / 2 + 8 / k, k };
    }
    function animateCam(to, dur) {
      followUntil = 0;
      to.k = clamp(to.k, kMin, K_MAX);
      if (prefersReduced() || dur <= 0) { camAnim = null; cam.x = to.x; cam.y = to.y; cam.k = to.k; reportZoom(); }
      else camAnim = { from: { x: cam.x, y: cam.y, k: cam.k }, to, t0: now(), dur };
      kick();
    }
    function fitNow(animate) { animateCam(fitTarget(), animate ? FIT_MS : 0); camAuto = true; }
    function stepCamera(t, dt) {
      if (camAnim) {
        const p = clamp((t - camAnim.t0) / camAnim.dur, 0, 1), e = easeOutCubic(p);
        const a = camAnim.from, b = camAnim.to;
        cam.x = lerp(a.x, b.x, e); cam.y = lerp(a.y, b.y, e);
        cam.k = Math.exp(lerp(Math.log(a.k), Math.log(b.k), e));
        if (p >= 1) camAnim = null;
        reportZoom();
        return true;
      }
      if (followUntil) {
        if (t >= followUntil) { followUntil = 0; return false; }
        const to = fitTarget(), f = 1 - Math.exp(-dt / 140);
        cam.x += (to.x - cam.x) * f; cam.y += (to.y - cam.y) * f;
        cam.k = Math.exp(lerp(Math.log(cam.k), Math.log(to.k), f));
        reportZoom();
        return true;
      }
      return false;
    }
    function zoomAt(sx, sy, k) {
      stopCamera();
      const vc = viewCenter(), nk = clamp(k, kMin, K_MAX);
      const wx = (sx - vc.x) / cam.k + cam.x, wy = (sy - vc.y) / cam.k + cam.y;
      cam.k = nk; cam.x = wx - (sx - vc.x) / nk; cam.y = wy - (sy - vc.y) / nk;
      reportZoom(); kick();
    }
    function panBy(dx, dy) { stopCamera(); cam.x -= dx / cam.k; cam.y -= dy / cam.k; kick(); }

    // ---------------------------------------------------------------- drawing
    const snap = v => Math.round(v * dpr) / dpr;
    function draw(dt, snapLabels) {
      if ((window.devicePixelRatio || 1) !== dpr) measure();
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.clearRect(0, 0, canvas.width, canvas.height);
      if (W <= 0 || H <= 0) return false;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      const k = cam.k, vc = viewCenter(), ox = vc.x - cam.x * k, oy = vc.y - cam.y * k, sc = nodeScale(k);
      for (const n of nodes) { n.sx = n.x * k + ox; n.sy = n.y * k + oy; n.sr = n.r * scaleOf(n, k, sc); }
      drawGrid(k, ox, oy);
      drawLinks();
      drawPulses();
      drawNodes();
      const f = snapLabels || prefersReduced() ? 1 : dt == null ? 0 : 1 - Math.exp(-dt / TAU);
      const busy = drawLabels(f);
      ctx.globalAlpha = 1;
      return busy;
    }
    function drawGrid(k, ox, oy) {
      if (k < 0.6) return;
      const step = 28 * k, s = 1.25;
      const x0 = ((ox % step) + step) % step, y0 = ((oy % step) + step) % step;
      ctx.globalAlpha = clamp((k - 0.6) / 0.15, 0, 1);
      ctx.fillStyle = theme.grid;
      ctx.beginPath();
      for (let x = x0; x < W; x += step) {
        const px = snap(x - s / 2);
        for (let y = y0; y < H; y += step) ctx.rect(px, snap(y - s / 2), s, s);
      }
      ctx.fill();
      ctx.globalAlpha = 1;
    }
    function drawLinks() {
      ctx.lineCap = 'round';
      for (const l of links) {
        const a = l.source, b = l.target;
        const presence = Math.min(1, 0.35 + 0.65 * Math.min(a.a, b.a) / (a.emphasis === 'context' || b.emphasis === 'context' ? 0.55 : 1));
        const base = l.a * presence;
        if (base <= 0.01) continue;
        const hi = l.h;
        if (hi < 0.99) {
          let col = theme.edge, w = 1, al = 1, dash = null;
          if (l.kind === 'tag') { col = theme.edgeTag; dash = [3, 4]; }
          else if (l.kind === 'tagged') col = theme.edgeTag;
          else if (l.kind === 'query') { col = theme.accent; w = 1.25; al = 0.18 + 0.32 * l.strength; }
          else if (l.kind === 'cluster') {
            if (a.kind === 'doc' || b.kind === 'doc') { w = 1; al = 0.7; dash = [2, 5]; }
            else { w = 1 + 4.5 * l.strength; al = 0.5 + 0.5 * l.strength; }
          }
          if (l.kind === 'tag') al = 0.6;                   // 자동 연결은 더 옅게
          ctx.globalAlpha = base * al * (1 - hi);
          ctx.strokeStyle = col; ctx.lineWidth = w;
          ctx.setLineDash(dash || []);
          ctx.beginPath(); ctx.moveTo(a.sx, a.sy); ctx.lineTo(b.sx, b.sy); ctx.stroke();
        }
        if (hi > 0.01) {
          ctx.globalAlpha = 0.85 * hi * l.a;
          ctx.strokeStyle = theme.accent; ctx.lineWidth = l.kind === 'cluster' && a.kind !== 'doc' && b.kind !== 'doc' ? 1.6 + 3 * l.strength : 1.6;
          ctx.setLineDash(l.kind === 'tag' ? [3, 4] : []);
          ctx.beginPath(); ctx.moveTo(a.sx, a.sy); ctx.lineTo(b.sx, b.sy); ctx.stroke();
        }
      }
      ctx.setLineDash([]);
      ctx.globalAlpha = 1;
    }
    function layer(n) {
      if (n.id === hoverId()) return 7;
      if (n.id === selectedId) return 6;
      if (n.kind === 'keyword') return 5;
      if (n.kind === 'summary') return 3;
      if (n.emphasis === 'center') return 4;
      if (n.emphasis === 'match') return 3;
      if (n.kind === 'tag') return 1;
      return n.emphasis === 'context' ? 0 : 2;
    }
    function drawNodes() {
      const order = nodes.slice().sort((p, q) => layer(p) - layer(q));
      for (const n of order) {
        if (n.a <= 0.01) continue;
        if (n.kind === 'keyword') drawHub(n);
        else if (n.kind === 'summary') drawSummary(n);
        else if (n.kind === 'tag') drawTag(n);
        else if (n.kind === 'cluster') drawCluster(n);
        else if (n.docKind === 'jira' && n.statusGroup) drawTicket(n);
        else drawDoc(n);
      }
      ctx.globalAlpha = 1;
    }
    function circle(x, y, r) { ctx.beginPath(); ctx.arc(x, y, Math.max(0.1, r), 0, Math.PI * 2); }
    function drawDoc(n) {
      const x = n.sx, y = n.sy, r = n.sr, sel = n.id === selectedId;
      const st = styles && styles.get(n.id);
      const fill = topicColor(st && st.topic ? st.topic : n.topic);
      if (st && st.glow && !sel) {          // 최근 활동: 노드 색의 옅은 빛
        const g = ctx.createRadialGradient(x, y, r * 0.6, x, y, r + 11);
        g.addColorStop(0, fill); g.addColorStop(1, 'rgba(0,0,0,0)');
        ctx.globalAlpha = 0.3 * n.a; ctx.fillStyle = g; circle(x, y, r + 11); ctx.fill();
      }
      if (sel) {
        const g = ctx.createRadialGradient(x, y, r, x, y, r + 16);
        g.addColorStop(0, theme.accent); g.addColorStop(1, 'rgba(0,0,0,0)');
        ctx.globalAlpha = 0.35 * n.a; ctx.fillStyle = g; circle(x, y, r + 16); ctx.fill();
      }
      ctx.globalAlpha = n.a;
      ctx.fillStyle = theme.ring; circle(x, y, r + 1.5); ctx.fill();
      ctx.globalAlpha = n.a * 0.92;
      ctx.fillStyle = fill; circle(x, y, r); ctx.fill();
      if (sel || n.emphasis === 'center') {
        ctx.globalAlpha = n.a; ctx.strokeStyle = theme.accent; ctx.lineWidth = 2;
        circle(x, y, r + 4); ctx.stroke();
      }
    }
    // v0.6 티켓: 둥근 사각형. 상태 색 — 할 일 회색 · 진행 파랑 · 막힘 주황 · 완료 초록(흐리게+체크) · 취소 회색(더 흐리게+점선). 내 티켓은 작은 점.
    function drawTicket(n) {
      const x = n.sx, y = n.sy, half = n.sr * 0.92, sel = n.id === selectedId, g = n.statusGroup;
      const col = theme.status[g] || theme.status.todo;
      // 모양으로도 구분(색각 보완): 할 일 = 속 빈 네모 · 진행 중 = 채운 네모 + 안쪽 테두리 · 막힘 = 네모 안 ! · 완료 = 체크 · 닫힘 = 점선 속 빈 네모 + 대각선
      const hollow = g === 'todo' || g === 'dropped';
      const body = g === 'done' ? 0.62 : hollow ? 0.14 : 0.95;
      if (sel) {
        const gr = ctx.createRadialGradient(x, y, half, x, y, half + 16);
        gr.addColorStop(0, theme.accent); gr.addColorStop(1, 'rgba(0,0,0,0)');
        ctx.globalAlpha = 0.35 * n.a; ctx.fillStyle = gr; circle(x, y, half + 16); ctx.fill();
      }
      ctx.globalAlpha = n.a;
      roundRectPath(x - half - 1.5, y - half - 1.5, 2 * half + 3, 2 * half + 3, half * 0.42 + 1.5);
      ctx.fillStyle = theme.ring; ctx.fill();
      roundRectPath(x - half, y - half, 2 * half, 2 * half, half * 0.42);
      ctx.globalAlpha = n.a * body; ctx.fillStyle = col; ctx.fill();
      if (g === 'todo') {
        ctx.globalAlpha = n.a * 0.95; ctx.strokeStyle = col; ctx.lineWidth = Math.max(1.5, half * 0.22); ctx.stroke();
      } else if (g === 'doing') {
        roundRectPath(x - half * 0.62, y - half * 0.62, half * 1.24, half * 1.24, half * 0.2);
        ctx.globalAlpha = n.a * 0.9; ctx.strokeStyle = theme.text1; ctx.lineWidth = Math.max(1.2, half * 0.16); ctx.stroke();
      } else if (g === 'blocked') {
        ctx.globalAlpha = n.a; ctx.strokeStyle = theme.ring; ctx.lineWidth = Math.max(1.6, half * 0.24); ctx.lineCap = 'round';
        ctx.beginPath(); ctx.moveTo(x, y - half * 0.52); ctx.lineTo(x, y + half * 0.08); ctx.stroke();
        circle(x, y + half * 0.5, Math.max(1, half * 0.15)); ctx.fillStyle = theme.ring; ctx.fill();
      } else if (g === 'dropped') {
        ctx.globalAlpha = n.a * 0.85; ctx.strokeStyle = col; ctx.lineWidth = Math.max(1.3, half * 0.2); ctx.setLineDash([2.5, 2.5]); ctx.stroke(); ctx.setLineDash([]);
        ctx.lineCap = 'round'; ctx.beginPath(); ctx.moveTo(x - half * 0.55, y + half * 0.55); ctx.lineTo(x + half * 0.55, y - half * 0.55); ctx.stroke();
      } else if (g === 'done') {
        ctx.globalAlpha = n.a * 0.95; ctx.strokeStyle = theme.ring; ctx.lineWidth = Math.max(1.4, half * 0.2); ctx.lineCap = 'round'; ctx.lineJoin = 'round';
        ctx.beginPath(); ctx.moveTo(x - half * 0.42, y + half * 0.02); ctx.lineTo(x - half * 0.1, y + half * 0.36); ctx.lineTo(x + half * 0.46, y - half * 0.3); ctx.stroke();
      }
      if (n.mine) {
        ctx.globalAlpha = n.a; ctx.fillStyle = theme.ring; circle(x + half, y - half, Math.max(3.2, half * 0.42) + 1.2); ctx.fill();
        ctx.fillStyle = theme.accent; circle(x + half, y - half, Math.max(3.2, half * 0.42)); ctx.fill();
      }
      if (sel || n.emphasis === 'center') {
        ctx.globalAlpha = n.a; ctx.strokeStyle = theme.accent; ctx.lineWidth = 2;
        roundRectPath(x - half - 4, y - half - 4, 2 * half + 8, 2 * half + 8, half * 0.42 + 4); ctx.stroke();
      }
    }
    // v0.6 묶음: 큰 원 + 문서 수 + (Jira) 상태 구성 고리 + 열린 티켓 배지 + 최근 활동 빛
    function drawCluster(n) {
      const x = n.sx, y = n.sy, r = n.sr, sel = n.id === selectedId, hov = n.id === hoverId();
      const fill = topicColor(n.topic);
      if (n.recent > 0 && !sel) {
        const glowR = r + 10 + Math.min(14, n.recent * 0.6);
        const g = ctx.createRadialGradient(x, y, r * 0.7, x, y, glowR);
        g.addColorStop(0, fill); g.addColorStop(1, 'rgba(0,0,0,0)');
        ctx.globalAlpha = (0.16 + 0.22 * Math.min(1, n.recent / 12)) * n.a; ctx.fillStyle = g; circle(x, y, glowR); ctx.fill();
      }
      if (sel) {
        const g = ctx.createRadialGradient(x, y, r, x, y, r + 20);
        g.addColorStop(0, theme.accent); g.addColorStop(1, 'rgba(0,0,0,0)');
        ctx.globalAlpha = 0.4 * n.a; ctx.fillStyle = g; circle(x, y, r + 20); ctx.fill();
      }
      ctx.globalAlpha = n.a;
      ctx.fillStyle = theme.ring; circle(x, y, r + 2); ctx.fill();
      ctx.globalAlpha = n.a * (hov || sel ? 0.5 : 0.36);
      ctx.fillStyle = fill; circle(x, y, r); ctx.fill();
      ctx.globalAlpha = n.a * 0.95;
      const mix = n.statusMix;
      let total = 0;
      if (mix) for (const g of ['todo', 'doing', 'blocked', 'done', 'dropped']) total += mix[g] || 0;
      if (total > 0) {                                   // Jira 묶음: 상태 구성 고리 (끝난 티켓이 얼마나 많은지 한눈에)
        let a0 = -Math.PI / 2;
        ctx.lineWidth = Math.max(3, r * 0.14); ctx.lineCap = 'butt';
        for (const g of ['todo', 'doing', 'blocked', 'done', 'dropped']) {
          const c = mix[g] || 0;
          if (!c) continue;
          const a1 = a0 + (c / total) * Math.PI * 2;
          ctx.strokeStyle = theme.status[g]; ctx.globalAlpha = n.a * (g === 'done' ? 0.55 : g === 'dropped' ? 0.35 : 0.95);
          ctx.beginPath(); ctx.arc(x, y, r - ctx.lineWidth / 2, a0, a1 - (c === total ? 0 : 0.03)); ctx.stroke();
          a0 = a1;
        }
      } else {
        ctx.strokeStyle = fill; ctx.lineWidth = 2; circle(x, y, r - 1); ctx.stroke();
      }
      if (sel || hov) { ctx.globalAlpha = n.a; ctx.strokeStyle = theme.accent; ctx.lineWidth = 2; circle(x, y, r + 5); ctx.stroke(); }
      // 문서 수 (원 안). 버블이 충분히 크면 이름도 숫자 아래에 넣는다(작은 버블은 아래 라벨 파이프라인이 그린다).
      const inside = r >= 23;
      n.nameInside = inside;
      ctx.globalAlpha = n.a; ctx.fillStyle = theme.text1; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
      ctx.font = '700 ' + Math.round(inside ? clamp(r * 0.36, 14, 19) : clamp(r * 0.5, 11, 19)) + 'px ' + theme.font;
      let lines = null;
      if (inside) {                                      // 이름: 한 줄에 안 들어가면 ' · ' ' ' '-' '_' 근처에서 두 줄로
        const f = '600 11px ' + theme.font, maxW = r * 1.7;
        lines = nameLines(n.label, f, maxW);
      }
      const cy = snap(y + (inside ? (lines.length > 1 ? -15 : -8) : 0.5));
      ctx.lineJoin = 'round'; ctx.strokeStyle = theme.halo; ctx.lineWidth = 3; ctx.strokeText(String(n.count), snap(x), cy);   // 겹쳐도 숫자가 읽히게 테두리
      ctx.fillText(String(n.count), snap(x), cy);
      if (inside) {
        const f = '600 11px ' + theme.font;
        ctx.font = f; ctx.globalAlpha = n.a * 0.92;
        lines.forEach((ln, i) => ctx.fillText(ln, snap(x), snap(y + (lines.length > 1 ? 1 + i * 13 : 10))));
        ctx.globalAlpha = n.a;
      }
      if (n.openTickets > 0) {                            // 열린 티켓 배지 (작은 버블은 숫자를 덮지 않게 바깥 오른쪽 위로)
        const txt = String(n.openTickets);
        ctx.font = theme.fBadge;
        const bw = Math.max(16, measureText(txt, theme.fBadge) + 9);
        const bx = r >= 22 ? x + r * 0.74 : x + r + bw / 2 - 3, by = y - r * 0.74;
        roundRectPath(snap(bx - bw / 2) - 1.5, snap(by - 8) - 1.5, bw + 3, 19, 9.5); ctx.fillStyle = theme.ring; ctx.fill();
        roundRectPath(snap(bx - bw / 2), snap(by - 8), bw, 16, 8); ctx.fillStyle = theme.status.doing; ctx.fill();
        ctx.fillStyle = '#fff'; ctx.fillText(txt, snap(bx), snap(by + 0.5));
      }
    }
    function drawTag(n) {
      const r = n.sr;
      ctx.globalAlpha = n.a;
      ctx.fillStyle = theme.halo; circle(n.sx, n.sy, r); ctx.fill();
      ctx.strokeStyle = n.id === selectedId || n.id === hoverId() ? theme.accent : theme.labelMuted;
      ctx.lineWidth = 1.5; ctx.stroke();
    }
    function roundRectPath(x, y, w, h, r) {
      ctx.beginPath();
      ctx.moveTo(x + r, y); ctx.lineTo(x + w - r, y); ctx.arc(x + w - r, y + r, r, -Math.PI / 2, 0);
      ctx.lineTo(x + w, y + h - r); ctx.arc(x + w - r, y + h - r, r, 0, Math.PI / 2);
      ctx.lineTo(x + r, y + h); ctx.arc(x + r, y + h - r, r, Math.PI / 2, Math.PI);
      ctx.lineTo(x, y + r); ctx.arc(x + r, y + r, r, Math.PI, Math.PI * 1.5); ctx.closePath();
    }
    function drawHub(n) {
      const w = n.pillW || 60, h = HUB_H, x = snap(n.sx - w / 2), y = snap(n.sy - h / 2);
      ctx.globalAlpha = n.a;
      roundRectPath(x, y, w, h, h / 2);
      ctx.fillStyle = theme.halo; ctx.fill();
      ctx.fillStyle = theme.accentSoft; ctx.fill();
      ctx.strokeStyle = theme.accent; ctx.lineWidth = n.id === hoverId() || n.id === selectedId ? 2 : 1.5; ctx.stroke();
      ctx.font = theme.fHub; ctx.fillStyle = theme.text1;
      ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
      ctx.fillText(n.label, snap(n.sx), snap(n.sy + 0.5));
    }

    // v0.7 E: 요약 노드 — 상태 모양(범례와 같은 모양) + "완료 120" 알약. 눌러서 끝난 티켓 목록을 본다.
    function drawSummary(n) {
      const w = n.pillW || 80, h = HUB_H, x = snap(n.sx - w / 2), y = snap(n.sy - h / 2), g = n.statusGroup || 'done';
      const col = theme.status[g] || theme.status.done, hot = n.id === hoverId() || n.id === selectedId;
      ctx.globalAlpha = n.a;
      roundRectPath(x, y, w, h, h / 2);
      ctx.fillStyle = theme.halo; ctx.fill();
      ctx.globalAlpha = n.a * 0.16; ctx.fillStyle = col; ctx.fill();
      ctx.globalAlpha = n.a; ctx.strokeStyle = hot ? theme.accent : col; ctx.lineWidth = hot ? 2 : 1.4;
      if (g === 'dropped') ctx.setLineDash([3, 3]);
      ctx.stroke(); ctx.setLineDash([]);
      // 상태 모양 (작은 둥근 네모: 완료 = 체크 · 닫힘 = 점선 + 대각선)
      const hs = 7, cx = x + 17, cy = n.sy;
      roundRectPath(cx - hs, cy - hs, 2 * hs, 2 * hs, 3.2);
      ctx.globalAlpha = n.a * (g === 'dropped' ? 0.14 : 0.62); ctx.fillStyle = col; ctx.fill();
      ctx.globalAlpha = n.a; ctx.lineCap = 'round'; ctx.lineJoin = 'round';
      if (g === 'dropped') {
        ctx.strokeStyle = col; ctx.lineWidth = 1.3; ctx.setLineDash([2.2, 2.2]); ctx.stroke(); ctx.setLineDash([]);
        ctx.beginPath(); ctx.moveTo(cx - 3.8, cy + 3.8); ctx.lineTo(cx + 3.8, cy - 3.8); ctx.stroke();
      } else {
        ctx.strokeStyle = theme.ring; ctx.lineWidth = 1.6;
        ctx.beginPath(); ctx.moveTo(cx - 3.2, cy + 0.2); ctx.lineTo(cx - 0.8, cy + 2.8); ctx.lineTo(cx + 3.6, cy - 2.6); ctx.stroke();
      }
      ctx.font = theme.fHub; ctx.fillStyle = theme.text1;
      ctx.textAlign = 'left'; ctx.textBaseline = 'middle';
      ctx.fillText(n.label, snap(x + 30), snap(n.sy + 0.5));
    }

    // ---------------------------------------------------------------- labels (screen space, culled by priority)
    const boxes = [], disks = [];
    // mode: 0 = 라벨·모든 점과 겹침 검사, 1 = 라벨·묶음 버블만, 2 = 라벨끼리만
    function collides(b, self, mode) {
      mode = mode === true ? 2 : mode || 0;
      for (let i = 0; i < boxes.length; i++) {
        const o = boxes[i];
        if (o.x0 < b.x1 && o.x1 > b.x0 && o.y0 < b.y1 && o.y1 > b.y0) return true;
      }
      if (mode === 2) return false;
      for (let i = 0; i < disks.length; i++) {
        const d = disks[i];
        if (d.n === self) continue;
        if (mode === 1 && d.n.kind !== 'cluster') continue;
        const cx = clamp(d.x, b.x0, b.x1) - d.x, cy = clamp(d.y, b.y0, b.y1) - d.y;
        if (cx * cx + cy * cy < d.r * d.r) return true;
      }
      return false;
    }
    // 글자를 maxW 안으로 말줄임
    function fitText(text, font, maxW) {
      if (measureText(text, font) <= maxW) return text;
      let t = text;
      while (t.length > 2 && measureText(t + '…', font) > maxW) t = t.slice(0, -1);
      return t + '…';
    }
    // 버블 안 이름: 한 줄이 넘치면 가운데에 가장 가까운 구분(' · ', ' ', '-', '_')에서 두 줄로, 줄마다 말줄임
    function nameLines(text, font, maxW) {
      if (measureText(text, font) <= maxW) return [text];
      let best = -1;
      for (const sep of [' · ', ' ', '-', '_']) {
        for (let i = text.indexOf(sep); i >= 0; i = text.indexOf(sep, i + 1)) {
          if (best < 0 || Math.abs(i - text.length / 2) < Math.abs(best - text.length / 2)) best = i;
        }
        if (best >= 0) { const len = sep.length; return [fitText(text.slice(0, best).trim() || text, font, maxW), fitText(text.slice(best + len).trim(), font, maxW)]; }
      }
      return [fitText(text, font, maxW)];
    }
    function labelText(n, full) {
      const t = full ? n.fullLabel : n.label;
      return n.kind === 'tag' && t.charAt(0) !== '#' ? '#' + t : t;
    }
    function drawLabels(f) {
      const h = hoverId(), hood = neighbourhood(), k = cam.k, search = layoutKey === 'search';
      let docsManyNow = false;
      { let c = 0; for (const n of nodes) if (n.kind === 'doc' && !n.dying && ++c > 60) { docsManyNow = true; break; } }
      const cands = [];
      boxes.length = 0; disks.length = 0;
      for (const n of nodes) {
        if (n.kind === 'keyword' || n.kind === 'summary') {
          if (!n.dying && n.a > 0.05) {
            const w = (n.pillW || 60) / 2 + 2;
            boxes.push({ x0: n.sx - w, x1: n.sx + w, y0: n.sy - HUB_H / 2 - 2, y1: n.sy + HUB_H / 2 + 2 });
          }
          continue;
        }
        if (!n.dying && n.a > 0.3) disks.push({ n, x: n.sx, y: n.sy, r: n.sr + 1.5 });
        const isH = n.id === h, isS = n.id === selectedId;
        let want = 0, pri = n.degree || 0;
        n.force = false;
        if (n.dying) want = 0;
        else if (n.kind === 'cluster') {                 // 묶음 이름은 늘 보인다 (강조 집합 밖이면 옅게)
          want = focusSet && !focusSet.has(n.id) && !isH && !isS ? 0.4 : 1; pri = 9.5e6 + (isH || isS ? 1e6 : 0) + n.count + n.openTickets * 6;
          if (n.nameInside && !isH && !isS) want = 0;     // 이름을 버블 안에 이미 그렸다
        }
        else if (isH) { want = 1; pri = 1e7; }
        else if (isS) { want = 1; pri = 9e6; }
        else if (hood && hood.has(n.id)) { want = 1; pri = 8e6 + pri; }
        else if (n.emphasis === 'center') { want = 1; pri = 7e6; }
        else if (focusSet && focusSet.has(n.id)) { want = 1; pri = 6.5e6 + pri; }
        else if (focusSet) want = 0;
        else if (n.emphasis === 'context') want = 0;
        else if (n.top && k < 1.2) want = 1;
        else if (docsManyNow && k < 1.2 && n.kind === 'doc' && !(search && n.emphasis === 'match')) want = 0;
        else if (search && n.emphasis === 'match' && n.topMatch) { want = 1; pri = 6e6 + n.qs * 1000 + pri; }
        else if (search && n.emphasis === 'match') { want = 1; pri = 5e6 + n.qs * 1000 + pri; }
        else {
          const thr = (n.degree || 0) >= 3 ? 0.85 : 1.25;
          want = clamp((k - thr + 0.12) / 0.12, 0, 1);
          if (n.kind === 'tag') pri -= 0.5;
        }
        if (hood && !hood.has(n.id) && !isS) want *= 0.22;
        n.lw = want; n.lp = pri; n.lf = isH || isS;
        if (want > 0 || n.la > 0.01) cands.push(n);
      }
      cands.sort((p, q) => q.lp - p.lp);
      let busy = false;
      ctx.textAlign = 'center'; ctx.textBaseline = 'middle'; ctx.lineJoin = 'round';
      for (const n of cands) {
        const strong = n.lf;
        let text = labelText(n, strong);
        if (n.kind === 'cluster' && !strong) text = fitText(text, theme.fCluster, 150);   // 긴 이름은 말줄임 (전체 이름은 호버에서)
        const font = n.kind === 'tag' ? theme.fTag : n.kind === 'cluster' ? theme.fCluster : strong ? theme.fLabelStrong : theme.fLabel;
        let w = measureText(text, font);
        if (w > W - 28 && W > 120) {                      // 화면보다 긴 제목(선택·호버)은 줄여서 보인다
          let t = text;
          while (t.length > 4 && measureText(t + '…', font) > W - 28) t = t.slice(0, -2);
          text = t + '…'; w = measureText(text, font);
        }
        const lh = n.kind === 'tag' ? 13 : 14;
        const ringed = n.id === selectedId || n.emphasis === 'center' ? 4 : 0;
        let x = n.sx, y, b = null, target = n.lw, onScreen = false;
        const below = n.sy + n.sr + (n.kind === 'cluster' ? 15 : 13) + ringed, above = n.sy - n.sr - (n.kind === 'cluster' ? 14 : 11) - ringed;
        if (n.kind === 'cluster') {
          // 묶음 이름: 아래 → 위 → 오른쪽 → 왼쪽. 먼저 모든 점을 피하고, 안 되면 문서 점만 무시한다(묶음 숫자는 절대 덮지 않는다).
          const spots = [{ x: n.sx, y: below }, { x: n.sx, y: above }, { x: n.sx + n.sr + 8 + w / 2, y: n.sy }, { x: n.sx - n.sr - 8 - w / 2, y: n.sy }];
          const tryOrder = n.lspot > 0 ? [n.lspot, 0, 1, 2, 3].filter((v, i, a2) => a2.indexOf(v) === i) : [0, 1, 2, 3];
          const boxAt = (sp, sx) => ({ x0: sx - w / 2 - 2, x1: sx + w / 2 + 2, y0: sp.y - lh / 2, y1: sp.y + lh / 2 });
          const fitX = sp => (W > w + 12 ? clamp(sp.x, w / 2 + 6, W - w / 2 - 6) : sp.x);
          let pick = -1;
          if (n.lf) { pick = 0; x = fitX(spots[0]); y = spots[0].y; b = boxAt(spots[0], x); }   // 호버·선택한 묶음은 늘 아래에 전체 이름
          for (let pass = 0; pass < 2 && pick < 0; pass++) {
            for (const i of tryOrder) {
              const sx = fitX(spots[i]), bb = boxAt(spots[i], sx);
              if (i >= 2 && sx !== spots[i].x) continue;   // 옆자리는 화면 안에 그대로 들어갈 때만 (밀려 들어오면 버블을 덮는다)
              if (!(bb.x1 > 0 && bb.x0 < W && bb.y1 > 0 && bb.y0 < H)) continue;
              if (!collides(bb, n, pass === 0 ? 0 : 1)) { pick = i; x = sx; y = spots[i].y; b = bb; break; }
            }
          }
          if (pick >= 0) { target = n.lw; boxes.push(b); n.lspot = pick; n.lcx = x; n.lcy = y; }
          else { target = 0; x = n.lcx != null ? n.lcx : n.sx; y = n.lcy != null ? n.lcy : below; }
        } else {
          // try below the node first, then above; keep the previous side while it still fits (no flip-flop)
          const order = n.lside === 1 ? [above, below] : [below, above];
          if (W > w + 12) x = clamp(x, w / 2 + 6, W - w / 2 - 6);
          y = order[0];
          for (let attempt = 0; attempt < 2; attempt++) {
            y = order[attempt];
            b = { x0: x - w / 2 - 2, x1: x + w / 2 + 2, y0: y - lh / 2, y1: y + lh / 2 };
            onScreen = b.x1 > 0 && b.x0 < W && b.y1 > 0 && b.y0 < H;
            target = onScreen ? n.lw : 0;
            if (target <= 0 || n.lf || !collides(b, n, (n.top && k < 1.2) ? 2 : 0)) break;
            target = 0;
          }
          if (target > 0) { boxes.push(b); n.lside = y === above ? 1 : 0; }
          else if (n.la > 0.01) y = n.lside === 1 ? above : below;
        }
        if (Math.abs(target - n.la) > 0.004) { n.la += (target - n.la) * f; busy = true; } else n.la = target;
        if (n.la <= 0.01) continue;
        const dimmed = (hood && !hood.has(n.id) && n.id !== selectedId) || (n.emphasis === 'context' && n.kind !== 'cluster');
        const tx = snap(x), ty = snap(y);
        ctx.font = font;
        ctx.globalAlpha = n.la;
        ctx.strokeStyle = theme.halo; ctx.lineWidth = 4;
        ctx.strokeText(text, tx, ty);
        ctx.fillStyle = strong ? theme.text1 : n.kind === 'tag' || dimmed ? theme.labelMuted : theme.label;
        ctx.fillText(text, tx, ty);
      }
      ctx.globalAlpha = 1;
      return busy;
    }

    // ---------------------------------------------------------------- signature pulse "synapse firing" (§7.5)
    function pulse(id) {
      if (prefersReduced()) return;
      const n = byId.get(String(id));
      if (!isLive(n)) return;
      const nbs = Array.from(adj.get(n.id) || []).map(m => byId.get(m)).filter(isLive);
      nbs.sort((p, q) => Math.atan2(p.y - n.y, p.x - n.x) - Math.atan2(q.y - n.y, q.x - n.x));
      pulses = pulses.filter(p => p.node !== n);
      pulses.push({ node: n, nbs, t0: now() + 60 });
      kick();
    }
    function drawPulses() {
      if (!pulses.length) return;
      const t = now();
      pulses = pulses.filter(p => {
        const e = t - p.t0, n = p.node;
        if (e < 0) return true;
        const lastDelay = Math.min(Math.max(0, p.nbs.length - 1) * 40, 480);
        if (e > Math.max(600, lastDelay + 500) || !byId.has(n.id)) return false;
        if (e < 600) {
          const q = e / 600;
          ctx.globalAlpha = 0.5 * (1 - q);
          ctx.strokeStyle = theme.accent; ctx.lineWidth = 1.5;
          circle(n.sx, n.sy, (n.kind === 'keyword' ? 14 : n.sr) + 60 * easeOutCubic(q)); ctx.stroke();
        }
        ctx.fillStyle = theme.accent;
        for (let i = 0; i < p.nbs.length; i++) {
          const m = p.nbs[i], q = (e - Math.min(i * 40, 480)) / 500;
          if (q <= 0 || q >= 1 || !byId.has(m.id)) continue;
          const pe = easeInOutCubic(q), x = lerp(n.sx, m.sx, pe), y = lerp(n.sy, m.sy, pe);
          const fade = Math.sin(Math.PI * q);
          ctx.globalAlpha = 0.22 * fade; circle(x, y, 6); ctx.fill();
          ctx.globalAlpha = 0.95 * fade; circle(x, y, 2.5); ctx.fill();
        }
        return true;
      });
      ctx.globalAlpha = 1;
    }

    // ---------------------------------------------------------------- input (pointer / wheel / WebKit gesture)
    function hitTest(sx, sy) {
      const k = cam.k, vc = viewCenter(), sc = nodeScale(k);
      let best = null, bestD = Infinity;
      for (const n of nodes) {
        if (n.dying || n.a < 0.05) continue;
        const x = (n.x - cam.x) * k + vc.x, y = (n.y - cam.y) * k + vc.y;
        if (n.kind === 'keyword' || n.kind === 'summary') {
          if (Math.abs(sx - x) <= (n.pillW || 60) / 2 + 3 && Math.abs(sy - y) <= HUB_H / 2 + 3) return n;
          continue;
        }
        const r = n.r * scaleOf(n, k, sc) + 6, dx = sx - x, dy = sy - y, d = dx * dx + dy * dy;
        if (d <= r * r && d < bestD) { best = n; bestD = d; }
      }
      return best;
    }
    let drag = null, gesture = null, trackpadUntil = 0;
    function localXY(e) { const r = canvas.getBoundingClientRect(); return { x: e.clientX - r.left, y: e.clientY - r.top }; }
    function setCursor(c) { if (canvas.style.cursor !== c) canvas.style.cursor = c; }
    function setPointerHover(id) { if (id === pointerHover) return; pointerHover = id; call('onHover', id); kick(); }
    function finishPosTween() {
      if (!posTween) return;
      for (const n of nodes) if (n.tx != null) { n.x = n.tx; n.y = n.ty; n.tx = n.ty = null; }
      posTween = null;
    }
    const on = (type, fn, opt) => canvas.addEventListener(type, fn, opt);
    on('mousedown', e => e.preventDefault());          // keep focus in the search field, no text selection
    // v0.6: 오른쪽 클릭 — 노드 위면 그 id, 빈 곳이면 null (메뉴는 앱이 그린다)
    on('contextmenu', e => {
      e.preventDefault();
      const p = localXY(e), n = hitTest(p.x, p.y);
      call('onContext', n ? n.id : null, e.clientX, e.clientY);
    });
    // Ends a drag without a pointerup (window hidden mid-press, capture lost, buttons released elsewhere).
    function cancelDrag() {
      if (!drag) return;
      const d = drag;
      drag = null;
      try { if (!canvas.hasPointerCapture || canvas.hasPointerCapture(d.id)) canvas.releasePointerCapture(d.id); } catch (_) { /* ignore */ }
      if (d.node && d.node.id !== centerId) d.node.fx = d.node.fy = null;
      alphaTarget = 0;
      setCursor('grab');
      kick();
    }
    on('pointerdown', e => {
      if (e.button !== 0) return;
      if (drag) cancelDrag();
      const p = localXY(e), n = hitTest(p.x, p.y);
      drag = { node: n && n.id !== centerId ? n : null, onCenter: !!(n && n.id === centerId), hit: n,
        x0: p.x, y0: p.y, lx: p.x, ly: p.y, moved: false, id: e.pointerId };
      try { canvas.setPointerCapture(e.pointerId); } catch (_) { /* ignore */ }
    });
    on('pointermove', e => {
      if (drag && e.buttons === 0) cancelDrag();      // the release happened where we could not see it
      const p = localXY(e);
      if (drag && e.pointerId === drag.id) {
        if (!drag.moved) {
          if (Math.hypot(p.x - drag.x0, p.y - drag.y0) < 3) return;
          drag.moved = true;
          stopCamera();
          if (drag.node) { finishPosTween(); alphaTarget = 0.3; }
        }
        if (drag.node) {
          const w = toWorld(p.x, p.y);
          drag.node.fx = w.x; drag.node.fy = w.y;
        } else panBy(p.x - drag.lx, p.y - drag.ly);
        drag.lx = p.x; drag.ly = p.y;
        setCursor('grabbing');
        kick();
        return;
      }
      if (gesture) return;
      const n = hitTest(p.x, p.y);
      setPointerHover(n ? n.id : null);
      setCursor(n ? 'pointer' : 'grab');
    });
    function endDrag(e, cancelled) {
      if (!drag || e.pointerId !== drag.id) return;
      const d = drag;
      drag = null;
      try { canvas.releasePointerCapture(e.pointerId); } catch (_) { /* ignore */ }
      if (d.moved) {
        if (d.node) { alphaTarget = 0; d.node.fx = d.node.fy = null; }
      } else if (!cancelled) {
        if (d.hit) call('onSelect', d.hit.id); else call('onBackgroundClick');
      }
      const p = localXY(e), n = hitTest(p.x, p.y);
      setCursor(n ? 'pointer' : 'grab');
      kick();
    }
    on('pointerup', e => endDrag(e, false));
    on('pointercancel', e => endDrag(e, true));
    on('pointerleave', () => { if (!drag) setPointerHover(null); });
    on('lostpointercapture', e => { if (drag && e.pointerId === drag.id) cancelDrag(); });
    on('dblclick', e => {
      e.preventDefault();
      const p = localXY(e), n = hitTest(p.x, p.y);
      if (n) call('onActivate', n.id); else fitNow(true);
    });
    on('wheel', e => {
      e.preventDefault();
      if (gesture) return;
      const p = localXY(e), t = now();
      let dx = e.deltaX, dy = e.deltaY;
      if (e.deltaMode === 1) { dx *= 16; dy *= 16; } else if (e.deltaMode === 2) { dx *= H; dy *= H; }
      const wdy = e.wheelDeltaY;
      const notch = typeof wdy === 'number' && wdy !== 0 && wdy % 120 === 0 && e.deltaX === 0;
      if (typeof wdy === 'number' && !notch && !e.ctrlKey) trackpadUntil = t + 400;  // fine-grained stream = trackpad
      if (e.ctrlKey) zoomAt(p.x, p.y, cam.k * Math.exp(clamp(-dy * 0.01, -0.5, 0.5)));
      else if (e.metaKey || e.altKey || e.deltaMode === 1 || (notch && t > trackpadUntil)) zoomAt(p.x, p.y, cam.k * Math.exp(clamp(-dy * 0.002, -0.5, 0.5)));
      else panBy(-dx, -dy);
    }, { passive: false });
    function onGesture(e) {
      e.preventDefault();
      const p = localXY(e);
      if (e.type === 'gesturestart') gesture = { k0: cam.k };
      else if (e.type === 'gesturechange' && gesture) zoomAt(p.x, p.y, gesture.k0 * (e.scale || 1));
      else if (e.type === 'gestureend') gesture = null;
    }
    on('gesturestart', onGesture, { passive: false });
    on('gesturechange', onGesture, { passive: false });
    on('gestureend', onGesture, { passive: false });

    // ---------------------------------------------------------------- theme changes (light/dark follow the system)
    let schemeMQ = null;
    const onScheme = () => { refreshThemeNow(); rebuildSim(); draw(); kick(); };
    try {
      schemeMQ = window.matchMedia('(prefers-color-scheme: dark)');
      if (schemeMQ.addEventListener) schemeMQ.addEventListener('change', onScheme);
      else if (schemeMQ.addListener) schemeMQ.addListener(onScheme);
    } catch (_) { schemeMQ = null; }

    measure();

    // display scale changes (Retina <-> 1x) fire no resize: watch the current resolution and re-arm on change
    let dprMQ = null;
    function onDpr() { armDpr(); if (!destroyed && measure()) { draw(null, true); kick(); } }
    function armDpr() {
      if (dprMQ) { if (dprMQ.removeEventListener) dprMQ.removeEventListener('change', onDpr); else if (dprMQ.removeListener) dprMQ.removeListener(onDpr); }
      dprMQ = null;
      if (destroyed) return;
      try {
        dprMQ = window.matchMedia('(resolution: ' + (window.devicePixelRatio || 1) + 'dppx)');
        if (dprMQ.addEventListener) dprMQ.addEventListener('change', onDpr); else if (dprMQ.addListener) dprMQ.addListener(onDpr);
      } catch (_) { dprMQ = null; }
    }
    armDpr();

    // ---------------------------------------------------------------- public API (§6)
    return {
      setGraph(data, opts) { if (!destroyed) setGraph(data, opts); },
      setSelection(id) { selectedId = id == null ? null : String(id); draw(); kick(); },
      setHover(id) { externalHover = id == null ? null : String(id); draw(); kick(); },
      reveal(id) {
        const n = byId.get(String(id));
        if (!isLive(n) || W <= 0) return;
        const x = n.tx != null ? n.tx : n.x, y = n.ty != null ? n.ty : n.y;
        const base = camAnim ? camAnim.to : cam, vc = viewCenter(), m = 72;
        const sx = (x - base.x) * base.k + vc.x, sy = (y - base.y) * base.k + vc.y;
        const l = pad.left + m, r = W - pad.right - m, t = pad.top + m, b = H - pad.bottom - m;
        let dx = 0, dy = 0;
        if (r <= l) dx = sx - vc.x; else if (sx < l) dx = sx - l; else if (sx > r) dx = sx - r;
        if (b <= t) dy = sy - vc.y; else if (sy < t) dy = sy - t; else if (sy > b) dy = sy - b;
        if (!dx && !dy) return;
        animateCam({ x: base.x + dx / base.k, y: base.y + dy / base.k, k: base.k }, FIT_MS);
      },
      zoomBy(factor) {
        camAuto = false;
        const base = camAnim ? camAnim.to : cam;
        animateCam({ x: base.x, y: base.y, k: base.k * (+factor || 1) }, 220);
      },
      fit(opts) { fitNow(!(opts && opts.animate === false)); },
      getZoom() { return cam.k; },
      setPadding(p) {
        if (!p) return;
        for (const k of ['top', 'right', 'bottom', 'left']) if (Number.isFinite(+p[k]) && p[k] != null) padTarget[k] = +p[k];
        if (!nodes.length || prefersReduced() || W <= 0) Object.assign(pad, padTarget);
        if (camAuto && !followUntil && nodes.some(isLive) && W > 0) fitNow(true);
        kick();
      },
      refreshTheme() { refreshThemeNow(); rebuildSim(); draw(null, true); kick(); },
      setPaused(v) {
        paused = !!v;
        if (paused) {
          if (raf) cancelAnimationFrame(raf);
          raf = 0;
          cancelDrag();
          setPointerHover(null);       // no pointerleave arrives while hidden; external hover is the app's
        } else {
          // the window may have been resized/moved while hidden: re-fit if the camera is still automatic
          const resized = measure();
          if (W > 0 && H > 0 && (needFit || (resized && camAuto && !followUntil && nodes.some(isLive)))) { needFit = false; fitNow(false); }
          draw(null, true);
          kick();
        }
      },
      pulse(id) { pulse(id); },
      // v0.5 (§9.4) 노드별 꾸밈: { id: { topic, alpha, glow } } | null. topic은 --topic-<topic> 색 키(예: 'g3', 'other').
      setNodeStyles(map) {
        styles = null;
        if (map && typeof map === 'object') {
          styles = new Map();
          const entries = map instanceof Map ? [...map.entries()] : Object.entries(map);
          for (const [id, v] of entries) if (v && typeof v === 'object') styles.set(String(id), v);
          if (!styles.size) styles = null;
        }
        draw(null, true); kick();
      },
      // v0.5 강조 집합: 이 id들만 또렷하게(라벨 우선), 나머지는 흐리게. null이면 해제.
      setFocusSet(ids) {
        focusSet = ids && typeof ids[Symbol.iterator] === 'function' ? new Set(Array.from(ids, String)) : null;
        if (focusSet && !focusSet.size) focusSet = null;
        draw(); kick();
      },
      // QA helper (not part of §6): canvas-local screen position of a node
      debugNode(id) {
        const n = byId.get(String(id));
        if (!n) return null;
        const vc = viewCenter();
        return { id: n.id, x: n.x, y: n.y, sx: (n.x - cam.x) * cam.k + vc.x, sy: (n.y - cam.y) * cam.k + vc.y,
          a: n.a, la: n.la, fx: n.fx, fy: n.fy, live: !n.dying, kind: n.kind, r: n.sr };
      },
      debugStats() {
        return { nodes: nodes.filter(isLive).length, clusters: nodes.filter(n => isLive(n) && n.kind === 'cluster').length, running: raf !== 0, frames, alpha,
          k: cam.k, pad: Object.assign({}, padTarget), camAuto, following: followUntil > 0, avgFrameMs: perf.n ? perf.ms / perf.n : 0, lastFrameMs: perf.last };
      },
      destroy() {
        destroyed = true;
        if (raf) cancelAnimationFrame(raf);
        raf = 0;
        ro.disconnect();
        armDpr();                      // destroyed → only removes the listener
        if (watchdog) { clearTimeout(watchdog); watchdog = 0; }
        if (schemeMQ) {
          if (schemeMQ.removeEventListener) schemeMQ.removeEventListener('change', onScheme);
          else if (schemeMQ.removeListener) schemeMQ.removeListener(onScheme);
        }
        canvas.remove();
        nodes = []; links = []; simNodes = []; simLinks = []; byId.clear(); pulses = [];
      },
    };
  }

  window.SynapseGraph = { create };
})();
