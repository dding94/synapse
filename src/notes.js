// src/notes.js — v0.6 옵시디언 없이 쓰기: 새 노트 창(⌘N) · [[ 자동완성 · 본문 그림 채우기 · 체크박스 저장
// window.SynapseNotes. app.js가 init()으로 연결해 준 것만 쓴다(브리지 출처·토스트·되돌리기 가능한 글자 넣기).
// 사용자 글자는 항상 textContent/value로만 다룬다. HTML로 넣는 것은 이 파일이 만든 고정 문구뿐이다.
(function () {
  'use strict';

  const API = { src: () => null, toast: () => {}, insertText: null, created: null, icon: null };
  const $ = (root, sel) => root.querySelector(sel);
  const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const errText = e => (e && (e.message || e.error)) ? String(e.message || e.error) : String(e || '');
  const parse = v => { if (typeof v === 'string') { try { return JSON.parse(v); } catch (_) { return v; } } return v; };
  const isIME = e => e.isComposing || e.keyCode === 229;

  function init(opts) { Object.assign(API, opts || {}); }

  // ===========================================================================
  // 새 노트 창
  const INBOX = '_Inbox';
  let nn = null;          // DOM 참조
  const st = { open: false, busy: false, notice: '', folders: null, loadedFor: null, typed: false, list: [], sel: -1, listOpen: false, restoreFocus: null };

  // Swift의 Library.noteFileStem과 같은 규칙(미리보기용)
  function fileStem(title) {
    let t = String(title || '').normalize('NFC');
    if (/\.md$/i.test(t)) t = t.slice(0, -3);
    t = t.replace(/[\/\\:*?"<>|#^\[\]\u0000-\u001f]/g, ' ').replace(/\s{2,}/g, ' ').replace(/^[.\s]+|[.\s]+$/g, '');
    if (t.length > 120) t = t.slice(0, 120).replace(/[.\s]+$/, '');
    return t || '새 노트';
  }

  function build() {
    if (nn) return nn;
    const root = document.createElement('div');
    root.className = 'nn-scrim';
    root.hidden = true;
    root.innerHTML =
      '<div class="nn-card" role="dialog" aria-modal="true" aria-labelledby="nn-h">' +
        '<div class="nn-head"><h2 id="nn-h">새 노트</h2>' +
          '<button class="icon-btn sm" type="button" data-nn="close" title="닫기 · esc" aria-label="닫기"><svg class="icon" aria-hidden="true"><use href="#i-x"/></svg></button></div>' +
        '<p class="nn-notice" hidden></p>' +
        '<label class="nn-field"><span class="nn-lab">제목</span><input class="nn-title" type="text" spellcheck="false" autocomplete="off" maxlength="200" placeholder="노트 제목"></label>' +
        '<div class="nn-field"><label class="nn-lab" for="nn-folder">위치</label><div class="nn-loc">' +
          '<input class="nn-folder" id="nn-folder" type="text" spellcheck="false" autocomplete="off" role="combobox" aria-expanded="false" aria-controls="nn-list" placeholder="맨 위 폴더">' +
          '<div class="nn-list" id="nn-list" role="listbox" hidden></div></div></div>' +
        '<div class="nn-path" aria-live="polite"></div>' +
        '<p class="nn-error" role="alert" hidden></p>' +
        '<div class="nn-actions"><button class="btn sm" type="button" data-nn="cancel">취소</button>' +
          '<button class="btn sm primary" type="button" data-nn="make">만들기<kbd>↵</kbd></button></div>' +
      '</div>';
    document.body.appendChild(root);
    nn = {
      root, card: $(root, '.nn-card'), notice: $(root, '.nn-notice'), title: $(root, '.nn-title'), folder: $(root, '.nn-folder'),
      list: $(root, '.nn-list'), path: $(root, '.nn-path'), error: $(root, '.nn-error'), make: $(root, '[data-nn="make"]'),
    };
    root.addEventListener('mousedown', e => { if (e.target === root) { e.preventDefault(); closeNew(); } });
    root.addEventListener('click', e => {
      const b = e.target.closest('[data-nn]');
      if (b) { if (b.dataset.nn === 'make') make(); else closeNew(); return; }
      const opt = e.target.closest('[data-nn-opt]');
      if (opt) pickFolder(Number(opt.dataset.nnOpt));
    });
    nn.list.addEventListener('mousedown', e => e.preventDefault());   // 목록을 눌러도 입력칸 포커스는 그대로
    nn.title.addEventListener('input', paintPath);
    nn.folder.addEventListener('input', () => { st.typed = true; st.sel = -1; showList(true); paintPath(); });
    nn.folder.addEventListener('focus', () => { st.typed = false; nn.folder.select(); showList(true); });
    nn.folder.addEventListener('blur', () => setTimeout(() => { if (document.activeElement !== nn.folder) showList(false); }, 100));
    return nn;
  }

  const folderValue = () => nn.folder.value.trim().replace(/^\/+|\/+$/g, '');

  function paintPath() {
    const f = folderValue();
    nn.path.textContent = (f ? f + '/' : '') + fileStem(nn.title.value) + '.md';
    nn.make.disabled = st.busy || !nn.title.value.trim();
  }

  // 위치 후보: _Inbox · (사서가 아는 폴더들) · 맨 위. 입력한 글자로 거른다.
  function buildOptions() {
    const q = st.typed ? nn.folder.value.trim().toLowerCase() : '';
    const all = [{ path: INBOX, label: INBOX, note: '기본' }];
    (st.folders || []).forEach(p => { const v = String(p).replace(/\/+$/, ''); if (v && v !== INBOX) all.push({ path: v, label: v }); });
    all.push({ path: '', label: '맨 위 폴더', note: '볼트 바로 아래' });
    const seen = new Set();
    st.list = all.filter(o => !seen.has(o.path) && seen.add(o.path) && (!q || o.label.toLowerCase().includes(q))).slice(0, 40);
    const typed = nn.folder.value.trim().replace(/^\/+|\/+$/g, '');
    if (st.typed && typed && !all.some(o => o.path.toLowerCase() === typed.toLowerCase())) st.list.push({ path: typed, label: typed, note: '새 폴더로 만들어요', isNew: true });
  }
  function showList(on) {
    st.listOpen = !!on;
    if (!on) { nn.list.hidden = true; nn.folder.setAttribute('aria-expanded', 'false'); return; }
    buildOptions();
    nn.list.innerHTML = '';
    st.list.forEach((o, i) => {
      const row = document.createElement('div');
      row.className = 'nn-opt' + (i === st.sel ? ' is-sel' : '');
      row.setAttribute('role', 'option'); row.setAttribute('aria-selected', String(i === st.sel));
      row.dataset.nnOpt = String(i);
      const t = document.createElement('span'); t.className = 'nn-opt-t'; t.textContent = o.label; row.appendChild(t);
      if (o.note) { const n = document.createElement('span'); n.className = 'nn-opt-n'; n.textContent = o.note; row.appendChild(n); }
      nn.list.appendChild(row);
    });
    nn.list.hidden = !st.list.length;
    nn.folder.setAttribute('aria-expanded', String(!!st.list.length));
    const cur = nn.list.querySelector('.is-sel');
    if (cur) cur.scrollIntoView({ block: 'nearest' });
  }
  function pickFolder(i) {
    const o = st.list[i];
    if (!o) return;
    nn.folder.value = o.path;
    st.typed = false; st.sel = -1;
    showList(false); paintPath();
  }

  function setError(msg) {
    nn.error.hidden = !msg;
    nn.error.textContent = msg || '';
  }

  // opts: { title, folder, notice, restoreFocus }
  function openNew(opts) {
    opts = opts || {};
    const src = API.src();
    if (!src) { API.toast('연결된 자료가 있어야 새 노트를 만들 수 있어요'); return false; }
    build();
    st.open = true; st.busy = false; st.typed = false; st.sel = -1;
    st.restoreFocus = document.activeElement && document.activeElement !== document.body ? document.activeElement : null;
    nn.title.value = opts.title ? String(opts.title) : '';
    nn.folder.value = opts.folder != null ? String(opts.folder) : INBOX;
    st.notice = opts.notice || '';
    nn.notice.hidden = !st.notice; nn.notice.textContent = st.notice;
    setError('');
    showList(false); paintPath();
    nn.root.hidden = false;
    // 못 찾은 링크의 "새 노트로 만들까요?"는 실수로 ↵를 쳐도 만들어지지 않게 취소에 포커스
    if (st.notice) $(nn.root, '[data-nn="cancel"]').focus({ preventScroll: true });
    else { nn.title.focus({ preventScroll: true }); if (nn.title.value) nn.title.select(); }
    // 위치 후보는 한 번만 불러 둔다(없어도 _Inbox·맨 위는 고를 수 있다)
    if (!st.folders && typeof src.brain === 'function') {
      Promise.resolve(src.brain('folders', {})).then(parse).then(r => {
        st.folders = r && Array.isArray(r.folders) ? r.folders.filter(x => typeof x === 'string') : [];
        if (st.listOpen) showList(true);
      }).catch(() => { st.folders = []; });
    }
    return true;
  }
  function closeNew() {
    if (!st.open) return;
    st.open = false;
    if (nn) { nn.root.hidden = true; showList(false); }
    const f = st.restoreFocus; st.restoreFocus = null;
    if (f && f.isConnected) { try { f.focus({ preventScroll: true }); } catch (_) { /* 포커스를 못 돌려도 괜찮다 */ } }
  }

  function make() {
    if (!st.open || st.busy) return;
    const title = nn.title.value.trim();
    if (!title) { setError('제목을 입력해 주세요'); nn.title.focus(); return; }
    const src = API.src();
    if (!src) return;
    st.busy = true; setError(''); paintPath();
    nn.make.firstChild.textContent = '만드는 중…';
    const params = { title, folder: folderValue() };
    Promise.resolve(src.brain('createNote', params)).then(parse).then(res => {
      st.busy = false; nn.make.firstChild.textContent = '만들기';
      if (!res || res.ok !== true) { setError((res && res.error) || '노트를 만들지 못했어요'); paintPath(); return; }
      st.restoreFocus = null;
      closeNew();
      if (API.created) API.created(res, title);
    }).catch(e => { st.busy = false; nn.make.firstChild.textContent = '만들기'; setError('노트를 만들지 못했어요 · ' + errText(e)); paintPath(); });
  }

  // 창이 열려 있을 때의 키. 앱의 다른 단축키는 막고(true), 입력은 그대로 둔다.
  function onKey(e) {
    if (!st.open) return false;
    if (isIME(e)) return true;
    const k = e.key;
    if (e.metaKey || e.ctrlKey || e.altKey) {
      if (e.metaKey && (k === 'n' || k === 'N' || e.code === 'KeyN')) e.preventDefault();
      return true;
    }
    // 창 밖(검색창 등)에 포커스가 있으면 키가 창 밖으로 새지 않게: ↵는 아무것도 하지 않고, 글자는 제목칸으로 돌려 보낸다
    const away = !(document.activeElement && nn.card.contains(document.activeElement));
    if (away && k !== 'Escape' && k !== 'Tab') {
      e.preventDefault(); e.stopPropagation();
      nn.title.focus({ preventScroll: true });
      return true;
    }
    if (k === 'Escape') { e.preventDefault(); e.stopPropagation(); if (st.listOpen) showList(false); else closeNew(); return true; }
    if (k === 'Tab') {   // 창 안에서만 포커스가 돈다
      const f = [nn.title, nn.folder, $(nn.root, '[data-nn="close"]'), $(nn.root, '[data-nn="cancel"]'), nn.make].filter(x => x && !x.disabled);
      const i = f.indexOf(document.activeElement);
      e.preventDefault();
      const next = f[(i + (e.shiftKey ? -1 : 1) + f.length) % f.length];
      if (next) next.focus({ preventScroll: true });
      return true;
    }
    const inFolder = document.activeElement === nn.folder;
    if (inFolder && (k === 'ArrowDown' || k === 'ArrowUp')) {
      e.preventDefault();
      if (!st.listOpen) showList(true);
      const n = st.list.length;
      if (n) { st.sel = st.sel < 0 ? (k === 'ArrowDown' ? 0 : n - 1) : (st.sel + (k === 'ArrowDown' ? 1 : -1) + n) % n; showList(true); }
      return true;
    }
    if (k === 'Enter') {
      if (document.activeElement && document.activeElement.closest && document.activeElement.closest('button')) return true;   // 단추의 기본 동작
      e.preventDefault();
      if (inFolder && st.listOpen && st.sel >= 0) { pickFolder(st.sel); return true; }
      make();
      return true;
    }
    return true;
  }

  // ===========================================================================
  // [[ 자동완성 (편집기 textarea)
  const ac = { ta: null, el: null, items: [], sel: 0, start: -1, seq: 0, timer: 0, q: null };

  function acEl() {
    if (ac.el) return ac.el;
    const el = document.createElement('div');
    el.className = 'ac-pop';
    el.setAttribute('role', 'listbox');
    el.hidden = true;
    el.addEventListener('mousedown', e => {
      e.preventDefault();
      const row = e.target.closest('[data-ac]');
      if (row) acPick(Number(row.dataset.ac));
    });
    document.body.appendChild(el);
    ac.el = el;
    return el;
  }
  // 커서가 [[글자 바로 뒤에 있으면 그 글자(검색어)와 시작 위치를 돌려준다
  function acContext(ta) {
    if (ta.selectionStart !== ta.selectionEnd) return null;
    const pos = ta.selectionStart, v = ta.value;
    const ls = v.lastIndexOf('\n', pos - 1) + 1;
    const m = /\[\[([^\[\]\n|#^]*)$/.exec(v.slice(ls, pos));
    if (!m) return null;
    return { q: m[1], start: pos - m[1].length };
  }
  // 커서 위치(화면 좌표): 같은 글꼴의 숨은 div로 잰다
  function caretXY(ta, pos) {
    const cs = getComputedStyle(ta);
    const d = document.createElement('div');
    ['fontFamily', 'fontSize', 'fontWeight', 'fontStyle', 'letterSpacing', 'lineHeight', 'wordSpacing', 'textIndent', 'tabSize',
      'paddingTop', 'paddingRight', 'paddingBottom', 'paddingLeft', 'borderTopWidth', 'borderRightWidth', 'borderBottomWidth', 'borderLeftWidth', 'boxSizing'
    ].forEach(p => { d.style[p] = cs[p]; });
    d.style.cssText += ';position:fixed;left:-9999px;top:0;visibility:hidden;white-space:pre-wrap;overflow-wrap:break-word;word-break:normal;width:' + ta.clientWidth + 'px;';
    d.textContent = ta.value.slice(0, pos);
    const mark = document.createElement('span');
    mark.textContent = '​';
    d.appendChild(mark);
    document.body.appendChild(d);
    const lh = parseFloat(cs.lineHeight) || parseFloat(cs.fontSize) * 1.4 || 20;
    const r = ta.getBoundingClientRect();
    const out = {
      x: r.left + (parseFloat(cs.borderLeftWidth) || 0) + mark.offsetLeft - ta.scrollLeft,
      y: r.top + (parseFloat(cs.borderTopWidth) || 0) + mark.offsetTop - ta.scrollTop + lh,
    };
    d.remove();
    return out;
  }
  function acHide() {
    clearTimeout(ac.timer); ac.seq++;
    if (ac.el) ac.el.hidden = true;
    ac.items = []; ac.start = -1; ac.q = null;
  }
  const acShown = () => !!(ac.el && !ac.el.hidden);
  function acPaint() {
    const el = acEl();
    el.textContent = '';
    ac.items.forEach((it, i) => {
      const row = document.createElement('div');
      row.className = 'ac-row' + (i === ac.sel ? ' is-sel' : '');
      row.setAttribute('role', 'option'); row.setAttribute('aria-selected', String(i === ac.sel));
      row.dataset.ac = String(i);
      const t = document.createElement('span'); t.className = 'ac-t'; t.textContent = it.title || it.name; row.appendChild(t);
      const p = document.createElement('span'); p.className = 'ac-p'; p.textContent = it.path || ''; row.appendChild(p);
      el.appendChild(row);
    });
    if (!ac.items.length) { const none = document.createElement('div'); none.className = 'ac-none'; none.textContent = '일치하는 노트가 없어요'; el.appendChild(none); }
    el.hidden = false;
    // 커서 아래에 붙이되 화면 밖으로 나가면 위로
    const xy = caretXY(ac.ta, ac.start);
    const w = Math.min(380, window.innerWidth - 16);
    el.style.width = w + 'px';
    const h = el.offsetHeight;
    let x = Math.max(8, Math.min(xy.x, window.innerWidth - w - 8)), y = xy.y + 4;
    if (y + h > window.innerHeight - 8) y = Math.max(8, xy.y - parseFloat(getComputedStyle(ac.ta).lineHeight || 20) - h - 4);
    el.style.left = x + 'px'; el.style.top = y + 'px';
    const cur = el.querySelector('.is-sel');
    if (cur) cur.scrollIntoView({ block: 'nearest' });
  }
  function acUpdate() {
    const ta = ac.ta;
    if (!ta || !ta.isConnected || document.activeElement !== ta) { acHide(); return; }
    const c = acContext(ta);
    if (!c) { acHide(); return; }
    if (c.q === ac.q && acShown()) { ac.start = c.start; return; }
    ac.start = c.start; ac.q = c.q;
    clearTimeout(ac.timer);
    const seq = ++ac.seq;
    ac.timer = setTimeout(() => {
      const src = API.src();
      if (!src || typeof src.brain !== 'function') return;
      Promise.resolve(src.brain('suggestTitles', { q: c.q, limit: 8 })).then(parse).then(r => {
        if (seq !== ac.seq || !ac.ta) return;
        const now = acContext(ac.ta);
        if (!now || now.q !== c.q) return;
        ac.items = r && Array.isArray(r.items) ? r.items.filter(it => it && it.name) : [];
        ac.sel = 0; ac.start = now.start;
        acPaint();
      }).catch(() => { /* 제안이 없어도 글쓰기는 계속된다 */ });
    }, 60);
  }
  function acPick(i) {
    const it = ac.items[i], ta = ac.ta;
    if (!it || !ta || !API.insertText) { acHide(); return; }
    const caret = ta.selectionStart;
    const start = ac.start >= 0 ? ac.start : caret;
    const after = ta.value.slice(caret, caret + 2) === ']]' ? 2 : 0;   // 이미 닫혀 있으면 그 ]]까지 바꾼다
    acHide();
    ta.focus({ preventScroll: true });
    ta.setSelectionRange(start, caret + after);
    API.insertText(ta, it.name + ']]');
  }
  function attachComplete(ta) {
    if (!ta || ta.__acBound) return;
    ta.__acBound = true;
    const upd = () => { ac.ta = ta; acUpdate(); };
    ta.addEventListener('input', upd);
    ta.addEventListener('click', upd);
    ta.addEventListener('keyup', e => { if (['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(e.key)) upd(); });
    ta.addEventListener('blur', () => setTimeout(() => { if (document.activeElement !== ta) acHide(); }, 120));
    ta.addEventListener('scroll', () => { if (acShown()) acHide(); });
  }
  // 앱의 keydown(capture)이 편집기 키를 처리하기 전에 부른다. 목록이 떠 있을 때만 ↑↓ ↵ ⇥ esc를 가져간다.
  function completeKey(e) {
    if (!acShown() || e.target !== ac.ta) return false;
    if (isIME(e)) return false;
    if (e.metaKey || e.ctrlKey || e.altKey) return false;
    const k = e.key, n = ac.items.length;
    const eat = () => { e.preventDefault(); e.stopPropagation(); };
    if (k === 'Escape') { eat(); acHide(); return true; }
    if (!n) return false;
    if (k === 'ArrowDown' || k === 'ArrowUp') { eat(); ac.sel = (ac.sel + (k === 'ArrowDown' ? 1 : -1) + n) % n; acPaint(); return true; }
    if (k === 'Enter' || k === 'Tab') { eat(); acPick(ac.sel); return true; }
    return false;
  }

  // ===========================================================================
  // 본문 그림: 자리(.md-img)를 readAsset 결과로 채운다 (CSP가 data: 그림만 허용한다)
  const assetCache = new Map();   // "문서|대상" → dataURL 또는 null(실패)
  let hydrateSeq = 0;
  function hydrate(root, docId, stillHere) {
    if (!root) return;
    const src = API.src();
    const slots = Array.from(root.querySelectorAll('.md-img[data-md-asset]'));
    if (!slots.length || !src || typeof src.brain !== 'function') return;
    const seq = ++hydrateSeq;
    const jobs = slots.slice(0, 60);
    let next = 0;
    const fill = (slot, url) => {
      if (!slot.isConnected) return;
      if (!url) { slot.classList.add('is-miss'); slot.title = '그림 파일을 찾지 못했어요'; return; }
      const img = document.createElement('img');
      img.className = 'md-img-el';
      img.alt = slot.dataset.mdAlt || slot.dataset.mdAsset || '';
      const w = parseInt(slot.dataset.mdW || '', 10);
      if (w > 0) img.style.maxWidth = Math.min(w, 2000) + 'px';
      img.addEventListener('error', () => { slot.classList.add('is-miss'); slot.textContent = ''; const c = document.createElement('span'); c.className = 'md-chip'; c.textContent = '그림 · ' + (img.alt || '열 수 없어요'); slot.appendChild(c); });
      img.src = url;
      slot.textContent = '';
      slot.classList.add('is-loaded');
      slot.appendChild(img);
    };
    const worker = () => {
      if (next >= jobs.length) return Promise.resolve();
      const slot = jobs[next++];
      const key = docId + '|' + slot.dataset.mdAsset;
      if (assetCache.has(key)) { fill(slot, assetCache.get(key)); return worker(); }
      return Promise.resolve(src.brain('readAsset', { id: docId, target: slot.dataset.mdAsset })).then(parse).then(r => {
        const url = r && r.ok && typeof r.dataURL === 'string' && r.dataURL.startsWith('data:image/') ? r.dataURL : null;
        if (assetCache.size > 40) assetCache.delete(assetCache.keys().next().value);
        assetCache.set(key, url);
        if (seq === hydrateSeq && (!stillHere || stillHere())) fill(slot, url);
      }).catch(() => { if (seq === hydrateSeq) fill(slot, null); }).then(worker);
    };
    worker(); worker(); worker();
  }

  // ===========================================================================
  // 체크박스: 그 줄이 읽은 때와 그대로일 때만 [ ]↔[x]를 바꿔 저장한다 (지문이 다르면 충돌)
  const RE_TASKLINE = /^((?:\s*>)*\s*(?:[-*+]|\d{1,9}[.)])\s+)\[([ xX])\](.*)$/;   // 인용·콜아웃(> - [ ]) 안의 체크박스도 같은 줄 규칙
  const splitLines = t => String(t || '').replace(/\r\n?/g, '\n').split('\n');
  // seen: 화면이 그릴 때 쓴 원문(dm.markdown), line: 1부터. 돌려주는 값: { ok, text?, reason?, conflict? }
  function toggleCheck(docId, line, seen, opts) {
    const src = API.src();
    if (!src) return Promise.resolve({ ok: false, reason: '저장할 수 없어요' });
    const seenLines = splitLines(String(seen || '').replace(/^﻿/, ''));
    const want = seenLines[line - 1];
    const wm = want == null ? null : RE_TASKLINE.exec(want);
    if (!wm) return Promise.resolve({ ok: false, stale: true, reason: '체크박스를 찾지 못했어요' });
    return Promise.resolve(src.readRaw(docId)).then(parse).then(raw => {
      raw = raw || {};
      if (!raw.editable) return { ok: false, reason: raw.reason || '이 문서는 고칠 수 없어요' };
      const lines = splitLines(raw.text);
      // 그릴 때의 원문 지문(전체 원문)과 저장 직전 원문이 다르면 아무것도 바꾸지 않는다(원문이 잘려 있으면 줄 비교만)
      if (!(opts && opts.truncated) && splitLines(String(seen || '').replace(/^﻿/, '')).join('\n') !== lines.join('\n')) return { ok: false, stale: true, changed: true, reason: '문서가 바뀌었어요. 다시 열어 주세요' };
      const cur = lines[line - 1];
      if (cur == null || cur.trimEnd() !== want.trimEnd()) return { ok: false, stale: true, reason: '문서가 바뀌었어요' };
      const m = RE_TASKLINE.exec(cur);
      if (!m) return { ok: false, stale: true, reason: '문서가 바뀌었어요' };
      const checked = m[2] === ' ';
      lines[line - 1] = m[1] + '[' + (checked ? 'x' : ' ') + ']' + m[3];
      const text = lines.join('\n');
      return Promise.resolve(src.saveRaw(docId, text, String(raw.fingerprint == null ? '' : raw.fingerprint))).then(parse).then(r => {
        if (r && r.conflict) return { ok: false, conflict: true, reason: '다른 곳에서 먼저 바뀌었어요' };
        if (!r || r.ok !== true) return { ok: false, reason: (r && r.error) || '저장하지 못했어요' };
        return { ok: true, checked, line: lines[line - 1] };
      });
    }).catch(e => ({ ok: false, reason: errText(e) }));
  }

  window.SynapseNotes = Object.freeze({
    init, openNew, closeNew, isOpen: () => st.open, onKey,
    attachComplete, completeKey, completeShown: acShown, hideComplete: acHide,
    hydrate, toggleCheck, fileStem,
  });
})();
