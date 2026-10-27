// Synapse v0.6 — 우클릭 메뉴 · 확인 창 · 고르기 창 (window.SynapseMenu)
// open({x, y, items, onPick}) · close() · isOpen() · confirm(opts) → Promise<boolean> · pick(opts) → Promise<string|null>
// items: { id, label, shortcut?, danger?, disabled?, icon? } 또는 { sep: true }. 고르면 onPick(id).
// 키보드를 가장 먼저 받도록(app.js보다 먼저 로드) 캡처 단계에서 한 번만 걸어 둔다.
(function () {
  'use strict';
  const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const icon = n => '<svg class="icon" aria-hidden="true"><use href="#i-' + esc(n) + '"/></svg>';
  const norm = s => String(s || '').normalize('NFC').toLocaleLowerCase();

  let menu = null;        // { root, items, cur, onPick, back }
  let dlg = null;         // { root, kind, resolve, back, ... } — 확인·고르기 창은 한 번에 하나
  let lastFocus = null;

  // ---------------------------------------------------------------- 우클릭 메뉴
  function close() {
    if (!menu) return;
    const m = menu; menu = null;
    m.root.remove();
    const b = m.back;
    if (b && b.isConnected && b !== document.body && document.activeElement !== b) { try { b.focus({ preventScroll: true }); } catch (e) { /* 무시 */ } }
  }
  const isOpen = () => !!menu;
  const enabledIdx = items => items.map((it, i) => (it.sep || it.disabled ? -1 : i)).filter(i => i >= 0);
  function setCur(i) {
    if (!menu) return;
    menu.cur = i;
    if (i >= 0) menu.root.setAttribute('aria-activedescendant', 'sm-i' + i); else menu.root.removeAttribute('aria-activedescendant');
    menu.root.querySelectorAll('.sm-item').forEach(n => n.classList.toggle('is-cur', Number(n.dataset.i) === i));
    const n = menu.root.querySelector('.sm-item[data-i="' + i + '"]');
    if (n && n.scrollIntoView) n.scrollIntoView({ block: 'nearest' });
  }
  function choose(i) {
    if (!menu) return;
    const it = menu.items[i];
    if (!it || it.sep || it.disabled) return;
    const cb = menu.onPick;
    close();
    if (typeof cb === 'function') { try { cb(it.id, it); } catch (e) { console.warn('[synapse] menu:', e); } }
  }
  function open(opts) {
    close();
    if (dlg) return;
    const items = (opts && Array.isArray(opts.items) ? opts.items : []).filter(Boolean);
    if (!items.length) return;
    const root = document.createElement('div');
    root.className = 'sm-menu';
    root.setAttribute('role', 'menu');
    root.setAttribute('aria-label', (opts && opts.label) || '작업 메뉴');
    root.tabIndex = -1;
    root.innerHTML = items.map((it, i) => it.sep ? '<div class="sm-sep" role="separator"></div>'
      : '<div class="sm-item' + (it.danger ? ' is-danger' : '') + (it.disabled ? ' is-disabled' : '') + '" role="menuitem" id="sm-i' + i + '" data-i="' + i + '"' + (it.disabled ? ' aria-disabled="true"' : '') + '>' +
        '<span class="sm-ic">' + (it.icon ? icon(it.icon) : '') + '</span><span class="sm-lb">' + esc(it.label) + '</span>' +
        (it.shortcut ? '<span class="sm-sc">' + esc(it.shortcut) + '</span>' : '') + '</div>').join('');
    document.body.appendChild(root);
    const vw = window.innerWidth, vh = window.innerHeight, r = root.getBoundingClientRect();
    let x = Number(opts.x) || 0, y = Number(opts.y) || 0;
    if (x + r.width > vw - 6) x = Math.max(6, x - r.width);        // 오른쪽 가장자리 → 왼쪽으로 뒤집기
    if (y + r.height > vh - 6) y = Math.max(6, y - r.height);       // 아래쪽 가장자리 → 위로 뒤집기
    x = Math.max(6, Math.min(x, vw - r.width - 6));
    if (r.height > vh - 12) root.style.maxHeight = (vh - 12) + 'px';
    root.style.left = x + 'px'; root.style.top = Math.max(6, y) + 'px';
    menu = { root, items, cur: -1, onPick: opts.onPick, back: document.activeElement };
    root.addEventListener('mousemove', e => { const n = e.target.closest('.sm-item'); if (n && !n.classList.contains('is-disabled')) { const i = Number(n.dataset.i); if (i !== menu.cur) setCur(i); } });
    root.addEventListener('mouseleave', () => setCur(-1));
    root.addEventListener('mouseup', e => { const n = e.target.closest('.sm-item'); if (n && e.button === 0) choose(Number(n.dataset.i)); });
    root.addEventListener('contextmenu', e => e.preventDefault());
    root.addEventListener('mousedown', e => e.preventDefault());   // 클릭해도 포커스가 흔들리지 않게
    // 키보드 사용자를 위해 포커스를 메뉴로 옮기고 첫 항목을 고른 상태로 시작한다(닫으면 원래 자리로 돌아간다)
    const first = enabledIdx(items)[0];
    if (first != null) setCur(first);
    try { root.focus({ preventScroll: true }); } catch (e) { /* 무시 */ }
  }

  // ---------------------------------------------------------------- 확인 · 고르기 창
  function closeDlg(result) {
    if (!dlg) return;
    const d = dlg; dlg = null;
    d.root.classList.remove('visible');
    setTimeout(() => d.root.remove(), 150);
    const b = d.back || lastFocus;
    if (b && b.isConnected && b !== document.body) { try { b.focus({ preventScroll: true }); } catch (e) { /* 무시 */ } }
    d.resolve(result);
  }
  function mountDlg(kind, html, resolve) {
    close();
    if (dlg) closeDlg(kind === 'confirm' ? false : null);
    const root = document.createElement('div');
    root.className = 'sm-scrim';
    root.innerHTML = '<div class="sm-dlg sm-' + kind + '" role="dialog" aria-modal="true" tabindex="-1">' + html + '</div>';
    document.body.appendChild(root);
    dlg = { root, kind, resolve, back: document.activeElement };
    requestAnimationFrame(() => root.classList.add('visible'));
    root.addEventListener('mousedown', e => { if (e.target === root) { e.preventDefault(); closeDlg(kind === 'confirm' ? false : null); } });
    return dlg;
  }

  // confirm({title, path?, lines?:[…], note?, confirmLabel, cancelLabel, danger}) → Promise<boolean>
  function confirm(opts) {
    opts = opts || {};
    return new Promise(resolve => {
      const lines = (Array.isArray(opts.lines) ? opts.lines : []).filter(Boolean);
      const d = mountDlg('confirm',
        '<h2 class="sm-title">' + esc(opts.title || '확인해 주세요') + '</h2>' +
        (opts.path ? '<div class="sm-path" title="' + esc(opts.path) + '">' + icon('folder') + '<span>' + esc(opts.path) + '</span></div>' : '') +
        (lines.length ? '<ul class="sm-lines">' + lines.map(l => {
          const warn = l && typeof l === 'object' && l.warn, t = l && typeof l === 'object' ? l.text : l;
          return '<li' + (warn ? ' class="is-warn"' : '') + '>' + esc(t) + '</li>';
        }).join('') + '</ul>' : '') +
        (opts.note ? '<p class="sm-note">' + esc(opts.note) + '</p>' : '') +
        '<div class="sm-btns"><button type="button" class="sm-btn" data-r="0">' + esc(opts.cancelLabel || '취소') + '</button>' +
        '<button type="button" class="sm-btn is-primary' + (opts.danger ? ' is-danger' : '') + '" data-r="1">' + esc(opts.confirmLabel || '확인') + '</button></div>',
        resolve);
      d.root.addEventListener('click', e => { const b = e.target.closest('[data-r]'); if (b) closeDlg(b.dataset.r === '1'); });
      const primary = d.root.querySelector('[data-r="1"]'), cancel = d.root.querySelector('[data-r="0"]');
      d.btns = [cancel, primary];
      // 위험한 확인은 취소에 먼저 포커스(실수로 ↵ 눌러도 안전). 그 밖에는 확인.
      (opts.danger ? cancel : primary).focus({ preventScroll: true });
    });
  }

  // pick({title, placeholder, items:[{value, label, hint?}], emptyText}) → Promise<value|null>
  function pick(opts) {
    opts = opts || {};
    return new Promise(resolve => {
      const all = (Array.isArray(opts.items) ? opts.items : []).filter(x => x && x.value != null);
      const d = mountDlg('pick',
        '<h2 class="sm-title">' + esc(opts.title || '고르기') + '</h2>' +
        '<input class="sm-q" type="text" placeholder="' + esc(opts.placeholder || '찾기') + '" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false" aria-label="' + esc(opts.placeholder || '찾기') + '">' +
        '<div class="sm-list" role="listbox"></div>' +
        '<div class="sm-foot"><span><kbd>↑↓</kbd> 고르기 · <kbd>↵</kbd> 선택 · <kbd>esc</kbd> 닫기</span></div>', resolve);
      Object.assign(d, { all, shown: [], cur: 0, q: d.root.querySelector('.sm-q'), list: d.root.querySelector('.sm-list'), emptyText: opts.emptyText || '맞는 항목이 없어요' });
      const paint = () => {
        const q = norm(d.q.value).trim();
        d.shown = (q ? all.filter(x => norm(x.label).includes(q) || norm(x.hint).includes(q)) : all).slice(0, 300);
        if (d.cur >= d.shown.length) d.cur = Math.max(0, d.shown.length - 1);
        d.list.innerHTML = d.shown.length ? d.shown.map((x, i) =>
          '<div class="sm-opt' + (i === d.cur ? ' is-cur' : '') + '" role="option" data-i="' + i + '"><span class="sm-opt-l">' + esc(x.label) + '</span>' +
          (x.hint ? '<span class="sm-opt-h">' + esc(x.hint) + '</span>' : '') + '</div>').join('') : '<div class="sm-empty">' + esc(d.emptyText) + '</div>';
      };
      d.paint = paint;
      d.move = delta => {
        if (!d.shown.length) return;
        d.cur = Math.max(0, Math.min(d.shown.length - 1, d.cur + delta));
        d.list.querySelectorAll('.sm-opt').forEach(n => n.classList.toggle('is-cur', Number(n.dataset.i) === d.cur));
        const n = d.list.querySelector('.sm-opt.is-cur'); if (n && n.scrollIntoView) n.scrollIntoView({ block: 'nearest' });
      };
      d.q.addEventListener('input', () => { d.cur = 0; paint(); });
      d.list.addEventListener('click', e => { const n = e.target.closest('.sm-opt'); if (n) closeDlg(d.shown[Number(n.dataset.i)].value); });
      d.list.addEventListener('mousemove', e => { const n = e.target.closest('.sm-opt'); if (n && Number(n.dataset.i) !== d.cur) { d.cur = Number(n.dataset.i); d.list.querySelectorAll('.sm-opt').forEach(m => m.classList.toggle('is-cur', m === n)); } });
      paint();
      d.q.focus({ preventScroll: true });
    });
  }

  // ---------------------------------------------------------------- 공통 입력 처리 (캡처, app.js보다 먼저)
  document.addEventListener('keydown', e => {
    if (!menu && !dlg) return;
    const k = e.key;
    if (dlg) {
      if (e.isComposing || e.keyCode === 229) { e.stopPropagation(); return; }   // IME 조합은 입력창에 맡긴다
      if (k === 'Escape') { e.preventDefault(); e.stopImmediatePropagation(); closeDlg(dlg.kind === 'confirm' ? false : null); return; }
      if (dlg.kind === 'confirm') {
        if (k === 'Tab' || k === 'ArrowLeft' || k === 'ArrowRight') {
          e.preventDefault(); e.stopImmediatePropagation();
          const i = dlg.btns.indexOf(document.activeElement);
          dlg.btns[(i + 1) % 2].focus({ preventScroll: true });
        } else if (k === 'Enter') {
          e.preventDefault(); e.stopImmediatePropagation();
          const b = document.activeElement && document.activeElement.closest('[data-r]');
          closeDlg(b ? b.dataset.r === '1' : false);
        } else if (!e.metaKey && !e.ctrlKey) { e.stopImmediatePropagation(); }
        return;
      }
      if (k === 'ArrowDown' || k === 'ArrowUp') { e.preventDefault(); e.stopImmediatePropagation(); dlg.move(k === 'ArrowDown' ? 1 : -1); return; }
      if (k === 'Enter') { e.preventDefault(); e.stopImmediatePropagation(); const x = dlg.shown[dlg.cur]; if (x) closeDlg(x.value); return; }
      if (k === 'Tab') { e.preventDefault(); e.stopImmediatePropagation(); return; }
      if (!e.metaKey) e.stopPropagation();   // 입력은 입력창 기본 동작으로, 앱 단축키로는 가지 않게
      return;
    }
    // 우클릭 메뉴
    const idx = enabledIdx(menu.items);
    if (k === 'Escape') { e.preventDefault(); e.stopImmediatePropagation(); close(); return; }
    if (k === 'ArrowDown' || k === 'ArrowUp') {
      e.preventDefault(); e.stopImmediatePropagation();
      if (!idx.length) return;
      const p = idx.indexOf(menu.cur);
      setCur(idx[k === 'ArrowDown' ? (p < 0 ? 0 : (p + 1) % idx.length) : (p <= 0 ? idx.length - 1 : p - 1)]);
      return;
    }
    if (k === 'Home' || k === 'End') { e.preventDefault(); e.stopImmediatePropagation(); if (idx.length) setCur(idx[k === 'Home' ? 0 : idx.length - 1]); return; }
    if (k === 'Enter' || k === ' ') { e.preventDefault(); e.stopImmediatePropagation(); if (menu.cur >= 0) choose(menu.cur); return; }
    close();   // 다른 키는 메뉴를 닫고 평소대로 처리(단축키가 그대로 동작)
  }, true);

  // 바깥 클릭 · 스크롤 · 창 숨김 · 크기 바뀜에 닫힘
  document.addEventListener('mousedown', e => { if (menu && !menu.root.contains(e.target)) close(); }, true);
  document.addEventListener('contextmenu', e => { if (menu && !menu.root.contains(e.target)) close(); }, true);
  document.addEventListener('wheel', e => { if (menu && !menu.root.contains(e.target)) close(); }, { capture: true, passive: true });
  document.addEventListener('scroll', e => { if (menu && !menu.root.contains(e.target)) close(); }, true);
  window.addEventListener('resize', close);
  window.addEventListener('blur', close);
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'hidden') close(); });

  window.SynapseMenu = Object.freeze({ open, close, isOpen, confirm, pick, dialogOpen: () => !!dlg });
})();
