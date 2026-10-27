// src/markdown.js — 마크다운 → 안전한 HTML (v0.6 옵시디언 없이 쓰기)
// window.SynapseMarkdown.render(text, opts) — 순수 함수. DOM·네트워크를 쓰지 않는다.
//
// 안전 원칙: 원본 HTML은 절대 그대로 넣지 않는다. 모든 글자는 esc()를 거치고, 태그·속성은 이 파일이 만든 것만 나온다.
// 링크는 href를 달지 않는다(javascript: 같은 주소가 실행될 길이 없음). 클릭은 앱이 data-md-* 속성을 읽어 처리한다.
//
// opts (모두 선택):
//   mark(text) → HTML   검색어 강조(기존 markText와 같은 표시). 기본은 esc.
//   resolve(target) → {id, asset} | null | undefined   [[대상]]이 가리키는 문서. undefined = 아직 모름(중립 표시)
//   frontmatter: false  프런트매터를 속성 표로 접지 않고 건너뜀
//   readOnly: true      원격(Confluence·Jira) 본문용(v0.7) — 체크박스는 보기만(data-md-check 없음), [[링크]]·#태그·코드·강조 기호는 해석하지 않고 글자 그대로. 바깥 주소 링크만 남긴다.
// 출력 약속:
//   블록마다 data-line="원문 줄 번호(1부터)" — 멈춘 곳 스크롤이 쓴다.
//   [[대상]] → <button class="md-link md-wiki" data-md-target data-md-id? data-md-anchor?>
//   체크박스 → <input class="md-check" data-md-check="줄 번호">
//   그림 자리 → <span class="md-img" data-md-asset data-md-w?> (앱이 readAsset으로 채움)
//   #태그 → <button class="md-tag" data-tag>   (앱의 기존 태그 검색 위임을 그대로 탄다)
(function (root) {
  'use strict';

  const ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
  const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ESC[c]);
  const MAX_DEPTH = 6;

  const IMG_EXT = new Set(['png', 'jpg', 'jpeg', 'gif', 'webp', 'svg', 'bmp', 'heic', 'heif', 'avif']);
  const extOf = name => { const m = /\.([A-Za-z0-9]{1,8})$/.exec(String(name || '').trim()); return m ? m[1].toLowerCase() : ''; };
  const safeDecode = s => { try { return decodeURIComponent(s); } catch (_) { return s; } };

  // 콜아웃 종류 → 색 계열(CSS의 data-kind)과 한국어 기본 제목
  const CALLOUTS = {
    note: ['note', '노트'], abstract: ['note', '요약'], summary: ['note', '요약'], tldr: ['note', '요약'],
    info: ['info', '정보'], todo: ['info', '할 일'],
    tip: ['tip', '팁'], hint: ['tip', '팁'], important: ['tip', '중요'],
    success: ['success', '성공'], check: ['success', '확인'], done: ['success', '완료'],
    question: ['question', '질문'], help: ['question', '도움'], faq: ['question', '질문'],
    warning: ['warning', '주의'], caution: ['warning', '주의'], attention: ['warning', '주의'],
    failure: ['danger', '실패'], fail: ['danger', '실패'], missing: ['danger', '없음'],
    danger: ['danger', '위험'], error: ['danger', '오류'], bug: ['danger', '버그'],
    example: ['example', '예시'], quote: ['quote', '인용'], cite: ['quote', '인용'],
  };

  // ---------------------------------------------------------------------------
  // 인라인
  const INLINE = new RegExp([
    '(`+)(?!`)([\\s\\S]*?[^`])\\1(?!`)',                                                          // 1,2 코드
    '!\\[\\[([^\\[\\]\\n]+?)\\]\\]',                                                              // 3 임베드
    '\\[\\[([^\\[\\]\\n]+?)\\]\\]',                                                               // 4 위키링크
    '!\\[([^\\[\\]\\n]*)\\]\\(([^()\\n]*(?:\\([^()\\n]*\\)[^()\\n]*)*)\\)',                      // 5,6 그림
    '\\[((?:[^\\[\\]\\n]|\\[[^\\[\\]\\n]*\\])+)\\]\\(([^()\\n]*(?:\\([^()\\n]*\\)[^()\\n]*)*)\\)', // 7,8 링크
    '<((?:https?:\\/\\/|mailto:)[^>\\s]+)>',                                                      // 9 꺾쇠 주소
    '(https?:\\/\\/[^\\s<>"\']+)',                                                                 // 10 맨 주소
    '\\*\\*\\*(\\S(?:[\\s\\S]*?\\S)?)\\*\\*\\*',                                                   // 11
    '\\*\\*(\\S(?:[\\s\\S]*?\\S)?)\\*\\*',                                                         // 12
    '__(\\S(?:[\\s\\S]*?\\S)?)__',                                                                // 13
    '~~(\\S(?:[\\s\\S]*?\\S)?)~~',                                                                // 14
    '==(\\S(?:[\\s\\S]*?\\S)?)==',                                                                // 15
    '\\*(\\S(?:[\\s\\S]*?\\S)?)\\*',                                                               // 16
    '_(\\S(?:[\\s\\S]*?\\S)?)_',                                                                  // 17
    '#([\\p{L}\\p{N}_\\-\\/]+)',                                                                  // 18 태그
    '\\\\([\\\\`*_{}\\[\\]()#+\\-.!|~=>])',                                                       // 19 이스케이프
  ].join('|'), 'gu');
  const WORDCH = /[\p{L}\p{N}]/u;

  function plain(ctx, s) { return s ? ctx.mark(s) : ''; }

  // [[대상#제목|별칭]] 쪼개기
  function splitWiki(inner) {
    let alias = null, t = inner;
    const bar = t.indexOf('|');
    if (bar >= 0) { alias = t.slice(bar + 1).trim(); t = t.slice(0, bar); }
    let anchor = '';
    const h = t.indexOf('#');
    if (h >= 0) { anchor = t.slice(h + 1).trim(); t = t.slice(0, h); }
    return { target: t.trim(), anchor, alias };
  }
  // [글](경로) 주소 → 종류 (외부 http·mailto / 안쪽 앵커 / 문서 경로 / 막음)
  function classifyUrl(raw) {
    let u = String(raw || '').trim();
    if (u.startsWith('<')) { const e = u.indexOf('>'); u = e > 0 ? u.slice(1, e) : u.slice(1); }
    else { const sp = u.search(/[ \t]/); if (sp > 0) u = u.slice(0, sp); }   // "경로 \"제목\"" 의 제목 부분 제거
    if (!u) return { kind: 'none' };
    if (/^(https?:\/\/|mailto:)/i.test(u)) return { kind: 'ext', url: u };
    if (u.startsWith('#')) return { kind: 'anchor', anchor: safeDecode(u.slice(1)) };
    if (/^[A-Za-z][A-Za-z0-9+.\-]*:/.test(u) || u.startsWith('//')) return { kind: 'none' };   // javascript:, data:, file: …
    let path = u, anchor = '';
    const h = path.indexOf('#');
    if (h >= 0) { anchor = safeDecode(path.slice(h + 1)); path = path.slice(0, h); }
    path = safeDecode(path).trim();
    return path ? { kind: 'doc', path, anchor } : { kind: 'none' };
  }

  function docLink(ctx, target, anchor, labelHtml, extra) {
    const r = ctx.resolve ? ctx.resolve(target) : undefined;
    const cls = 'md-link md-wiki' + (r ? ' is-ok' : r === null ? ' is-miss' : '') + (extra ? ' ' + extra : '');
    return '<button type="button" class="' + cls + '" data-md-target="' + esc(target) + '"' + (r && r.id != null ? ' data-md-id="' + esc(r.id) + '"' : '') +
      (r && r.asset ? ' data-md-file="1"' : '') + (anchor ? ' data-md-anchor="' + esc(anchor) + '"' : '') +
      ' title="' + esc(r === null ? '‘' + target + '’ 문서를 찾지 못했어요 · 누르면 새 노트로 만들 수 있어요' : target + (anchor ? ' › ' + anchor : '')) + '">' + labelHtml + '</button>';
  }
  function extLink(url, labelHtml) {
    return '<button type="button" class="md-link md-ext" data-md-url="' + esc(url) + '" title="' + esc(url) + '">' + labelHtml + '</button>';
  }
  function imgSlot(target, alt, width) {
    return '<span class="md-img" data-md-asset="' + esc(target) + '"' + (width ? ' data-md-w="' + esc(width) + '"' : '') + ' data-md-alt="' + esc(alt || '') + '">' +
      '<span class="md-chip">그림 · ' + esc(alt || target) + '</span></span>';
  }

  function inline(s, ctx, noLink, depth) {
    s = String(s == null ? '' : s);
    if (!s) return '';
    depth = depth || 0;
    let out = '', last = 0;
    for (const m of s.matchAll(INLINE)) {
      const at = m.index, end = at + m[0].length;
      if (at < last) continue;
      let html = null;
      if (ctx.readOnly && (m[2] !== undefined || m[3] !== undefined || m[4] !== undefined || m[5] !== undefined || m[11] !== undefined || m[12] !== undefined || m[13] !== undefined ||
          m[14] !== undefined || m[15] !== undefined || m[16] !== undefined || m[17] !== undefined || m[18] !== undefined)) continue;   // 글자 그대로 (v0.7 원격)
      if (m[2] !== undefined) {                                  // `코드`
        let c = m[2];
        if (c.length > 2 && c.startsWith(' ') && c.endsWith(' ')) c = c.slice(1, -1);
        html = '<code class="md-ic">' + esc(c) + '</code>';
      } else if (m[3] !== undefined) {                           // ![[파일|크기]]
        const parts = m[3].split('|');
        const name = parts[0].trim(), h = name.indexOf('#'), file = (h >= 0 ? name.slice(0, h) : name).trim();
        const opt = (parts[1] || '').trim();
        if (IMG_EXT.has(extOf(file))) html = imgSlot(file, /^\d+(x\d+)?$/.test(opt) ? '' : opt, /^\d+/.test(opt) ? opt.split('x')[0] : '');
        else if (!file) html = null;
        else if (extOf(file) && extOf(file) !== 'md') html = '<span class="md-chip md-file" title="' + esc(file) + '">첨부 · ' + esc(file) + '</span>';
        else html = noLink ? plain(ctx, file) : docLink(ctx, file, h >= 0 ? name.slice(h + 1) : '', '<span class="md-embed-tag">포함</span> ' + esc(file), 'is-embed');
      } else if (m[4] !== undefined) {                           // [[대상#제목|별칭]]
        const w = splitWiki(m[4]);
        if (!w.target && w.anchor) html = '<span class="md-anchor">' + esc(w.alias || w.anchor) + '</span>';
        else if (!w.target) html = null;
        else {
          const label = w.alias || (w.anchor ? w.target + ' › ' + w.anchor : w.target);
          html = noLink ? plain(ctx, label) : docLink(ctx, w.target, w.anchor, ctx.mark(label));
        }
      } else if (m[6] !== undefined) {                           // ![대체](경로)
        const u = classifyUrl(m[6]);
        if (u.kind === 'doc' && IMG_EXT.has(extOf(u.path))) html = imgSlot(u.path, m[5], '');
        else if (u.kind === 'ext') html = noLink ? plain(ctx, m[5] || u.url) : extLink(u.url, '그림 · ' + esc(m[5] || u.url));
        else html = '<span class="md-chip">그림 · ' + esc(m[5] || '') + '</span>';
      } else if (m[8] !== undefined) {                           // [글](주소)
        const u = classifyUrl(m[8]);
        const inner = inline(m[7], ctx, true, depth + 1);
        if (noLink || u.kind === 'none' || (ctx.readOnly && u.kind !== 'ext')) html = inner;
        else if (u.kind === 'ext') html = extLink(u.url, inner);
        else if (u.kind === 'anchor') html = '<span class="md-anchor">' + inner + '</span>';
        else html = docLink(ctx, u.path, u.anchor, inner);
      } else if (m[9] !== undefined) {                           // <https://…>
        html = noLink ? plain(ctx, m[9]) : extLink(m[9], esc(m[9]));
      } else if (m[10] !== undefined) {                          // 맨 주소: 끝의 문장부호는 뺀다
        let u = m[10], tail = '';
        for (;;) {
          const c = u[u.length - 1];
          if (c && /[.,;:!?'"]/.test(c)) { tail = c + tail; u = u.slice(0, -1); continue; }
          if (c === ')' && (u.match(/\(/g) || []).length < (u.match(/\)/g) || []).length) { tail = c + tail; u = u.slice(0, -1); continue; }
          break;
        }
        html = (noLink ? plain(ctx, u) : extLink(u, esc(u))) + plain(ctx, tail);
      } else if (m[11] !== undefined) {
        html = '<strong><em>' + inline(m[11], ctx, noLink, depth + 1) + '</em></strong>';
      } else if (m[12] !== undefined) {
        html = '<strong>' + inline(m[12], ctx, noLink, depth + 1) + '</strong>';
      } else if (m[13] !== undefined) {                          // __굵게__ — 단어 안쪽 밑줄은 글자 그대로
        const pv = at > 0 ? s[at - 1] : '', nx = s[end] || '';
        if (!(pv && WORDCH.test(pv)) && !(nx && WORDCH.test(nx))) html = '<strong>' + inline(m[13], ctx, noLink, depth + 1) + '</strong>';
      } else if (m[14] !== undefined) {
        html = '<del>' + inline(m[14], ctx, noLink, depth + 1) + '</del>';
      } else if (m[15] !== undefined) {
        html = '<mark class="md-hl">' + inline(m[15], ctx, noLink, depth + 1) + '</mark>';
      } else if (m[16] !== undefined) {
        html = '<em>' + inline(m[16], ctx, noLink, depth + 1) + '</em>';
      } else if (m[17] !== undefined) {                          // _기울임_ — snake_case_name 같은 건 건드리지 않는다
        const pv = at > 0 ? s[at - 1] : '', nx = s[end] || '';
        if (!(pv && WORDCH.test(pv)) && !(nx && WORDCH.test(nx))) html = '<em>' + inline(m[17], ctx, noLink, depth + 1) + '</em>';
      } else if (m[18] !== undefined) {                          // #태그
        const pv = at > 0 ? s[at - 1] : '';
        let tag = m[18];
        while (tag && /[\/\-]$/.test(tag)) tag = tag.slice(0, -1);
        if ((!pv || /[\s(,;"'>]/.test(pv)) && tag && /\p{L}/u.test(tag) && !noLink) {
          html = '<button type="button" class="md-tag" data-tag="' + esc(tag) + '" title="‘' + esc(tag) + '’ 태그로 검색">#' + esc(tag) + '</button>' + plain(ctx, m[18].slice(tag.length));
        }
      } else if (m[19] !== undefined) {                          // \* 같은 이스케이프
        html = plain(ctx, m[19]);
      }
      if (html == null) continue;                                // 해석하지 않기로 한 것은 글자 그대로 둔다
      out += plain(ctx, s.slice(last, at)) + html;
      last = end;
    }
    return out + plain(ctx, s.slice(last));
  }

  // ---------------------------------------------------------------------------
  // 블록
  const RE_FENCE = /^( {0,3})(`{3,}|~{3,})[ \t]*([^`\s]*)[^`]*$/;
  const RE_HEAD = /^ {0,3}(#{1,6})[ \t]+(.+?)(?:[ \t]+#+)?[ \t]*$/;
  const RE_HR = /^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$/;
  const RE_LIST = /^([ \t]*)([-*+]|\d{1,9}[.)])[ \t]+(.*)$/;
  const RE_TASK = /^\[([ xX])\](?:[ \t]+(.*))?$/;
  const RE_QUOTE = /^ {0,3}>[ ]?(.*)$/;
  const RE_DELIM = /^[ \t]*\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$/;
  const RE_CALLOUT = /^\[!([A-Za-z0-9_-]+)\]([+-]?)[ \t]*(.*)$/;
  const RE_BLOCKID = /[ \t]+\^[A-Za-z0-9-]+$/;
  const RE_COMMENT = /^\s*(?:<!--.*-->|%%.*%%)\s*$/;

  const indentOf = line => { let w = 0; for (const c of line) { if (c === ' ') w++; else if (c === '\t') w += 4; else break; } return w; };

  function splitRow(line) {
    let t = line.trim();
    if (t.startsWith('|')) t = t.slice(1);
    if (t.endsWith('|') && !t.endsWith('\\|')) t = t.slice(0, -1);
    const cells = [];
    let cur = '', tick = 0;
    for (let i = 0; i < t.length; i++) {
      const c = t[i];
      if (c === '\\' && t[i + 1] === '|') { cur += '|'; i++; continue; }
      if (c === '`') { let k = i; while (t[k] === '`') k++; const run = k - i; tick = tick === 0 ? run : tick === run ? 0 : tick; cur += t.slice(i, k); i = k - 1; continue; }
      if (c === '|' && !tick) { cells.push(cur.trim()); cur = ''; continue; }
      cur += c;
    }
    cells.push(cur.trim());
    return cells;
  }

  // 코드 블록: 닫는 울타리까지(없으면 끝까지). lines[i]가 여는 줄. [html, 다음 i]
  function fenceBlock(lines, i, base, strip) {
    const m = RE_FENCE.exec(strip ? lines[i].trim() : lines[i]);
    const ch = m[2][0], len = m[2].length, lang = m[3];
    const body = [];
    let j = i + 1;
    for (; j < lines.length; j++) {
      const ln = lines[j];
      const cm = /^ {0,3}(`{3,}|~{3,})[ \t]*$/.exec(strip ? ln.trim() : ln);
      if (cm && cm[1][0] === ch && cm[1].length >= len) break;
      body.push(strip ? ln.replace(new RegExp('^[ \\t]{0,' + strip + '}'), '') : ln);
    }
    const html = '<pre class="md-code" data-line="' + (base + i) + '">' + (lang ? '<span class="md-lang">' + esc(lang) + '</span>' : '') +
      '<code>' + esc(body.join('\n')) + '</code></pre>';
    return [html, j + 1];
  }

  // 표의 시작: 머리 줄(| 포함) 다음 줄이 구분 줄(---)이고 칸 수가 같다
  const isTableStart = (line, next) => line.indexOf('|') >= 0 && next != null && next.indexOf('-') >= 0 && RE_DELIM.test(next) &&
    (line.indexOf('|') >= 0 || next.indexOf('|') >= 0) && splitRow(line).length === splitRow(next).length;
  const startsBlock = (line, next) => RE_FENCE.test(line) || RE_HEAD.test(line) || RE_HR.test(line) || RE_QUOTE.test(line) || RE_LIST.test(line) || isTableStart(line, next);

  function renderTable(lines, i, base, ctx) {
    const head = splitRow(lines[i]), aligns = splitRow(lines[i + 1]).map(c => {
      const l = c.startsWith(':'), r = c.endsWith(':');
      return l && r ? 'c' : r ? 'r' : l ? 'l' : '';
    });
    let j = i + 2;
    const rows = [];
    while (j < lines.length && lines[j].trim() && lines[j].indexOf('|') >= 0 && !RE_FENCE.test(lines[j])) { rows.push([splitRow(lines[j]), j]); j++; }
    const cell = (tag, txt, k) => '<' + tag + (aligns[k] ? ' class="al-' + aligns[k] + '"' : '') + '>' + inline(txt, ctx) + '</' + tag + '>';
    let html = '<div class="md-table-wrap" tabindex="0" role="region" aria-label="표 · 방향키로 가로로 넘겨요" data-line="' + (base + i) + '"><table class="md-table"><thead><tr>' + head.map((c, k) => cell('th', c, k)).join('') + '</tr></thead><tbody>';
    rows.forEach(([cells, at]) => {
      html += '<tr data-line="' + (base + at) + '">';
      for (let k = 0; k < head.length; k++) html += cell('td', cells[k] || '', k);
      html += '</tr>';
    });
    return [html + '</tbody></table></div>', j];
  }

  // 목록: 들여쓰기로 중첩. 이어지는 들여쓴 줄은 항목 안, 코드 울타리도 항목 안.
  function collectList(lines, i) {
    const items = [];
    let j = i;
    while (j < lines.length) {
      const ln = lines[j];
      if (!ln.trim()) {   // 빈 줄: 뒤에 목록 항목이나 들여쓴 줄이 이어지면 같은 목록
        let k = j + 1;
        while (k < lines.length && !lines[k].trim()) k++;
        if (k < lines.length && items.length && (RE_LIST.test(lines[k]) && !RE_HR.test(lines[k]) || indentOf(lines[k]) >= 2) && k - j <= 2) { j = k; continue; }
        break;
      }
      const lm = RE_LIST.exec(ln);
      if (lm && !RE_HR.test(ln)) {
        let text = lm[3], task = null;
        const tm = RE_TASK.exec(text);
        if (tm) { task = tm[1] === ' ' ? ' ' : 'x'; text = tm[2] || ''; }
        items.push({ line: j, indent: indentOf(lm[1]), ordered: /\d/.test(lm[2]), num: parseInt(lm[2], 10), task, parts: [{ t: 'text', s: text }], children: null });
        j++; continue;
      }
      if (items.length && indentOf(ln) >= 2) {
        const it = items[items.length - 1];
        if (RE_FENCE.test(ln.trim())) {
          const [html, nj] = fenceBlock(lines, j, 0, indentOf(ln));
          it.parts.push({ t: 'html', s: html, line: j });
          j = nj; continue;
        }
        it.parts.push({ t: 'text', s: ln.trim(), line: j });
        j++; continue;
      }
      break;
    }
    return { items, next: j };
  }
  function buildTree(items) {
    const roots = [];
    const stack = [];   // { indent, list, ownerItem }
    items.forEach(it => {
      while (stack.length && it.indent < stack[stack.length - 1].indent) stack.pop();
      let top = stack[stack.length - 1];
      if (top && it.indent === top.indent && top.list.ordered !== it.ordered) { stack.pop(); top = stack[stack.length - 1]; }
      if (!top || it.indent > top.indent) {
        const list = { ordered: it.ordered, start: it.num, items: [] };
        const owner = top ? top.list.items[top.list.items.length - 1] : null;
        if (owner) (owner.children || (owner.children = [])).push(list); else roots.push(list);
        top = { indent: it.indent, list };
        stack.push(top);
      }
      top.list.items.push(it);
    });
    return roots;
  }
  function renderList(list, base, ctx, depth) {
    const tag = list.ordered ? 'ol' : 'ul';
    const start = list.ordered && Number.isFinite(list.start) && list.start !== 1 && list.start < 1e6 ? ' start="' + list.start + '"' : '';
    let html = '<' + tag + start + (list.items.some(i => i.task) ? ' class="md-tasks"' : '') + '>';
    list.items.forEach(it => {
      const at = base + it.line;
      let body = '', firstText = true;
      it.parts.forEach(p => {
        if (p.t === 'html') { body += p.s; return; }
        const s = p.s.replace(RE_BLOCKID, '');
        if (!firstText) body += '<br>';
        body += inline(s, ctx);
        firstText = false;
      });
      const box = it.task ? (ctx.readOnly
        ? '<input type="checkbox" class="md-check is-ro" disabled' + (it.task === 'x' ? ' checked' : '') + ' aria-label="완료 표시"> '
        : '<input type="checkbox" class="md-check" data-md-check="' + at + '"' + (it.task === 'x' ? ' checked' : '') + ' aria-label="완료 표시"> ') : '';
      const kids = (it.children || []).map(l => renderList(l, base, ctx, depth + 1)).join('');
      html += '<li' + (it.task ? ' class="md-task' + (it.task === 'x' ? ' is-done' : '') + '"' : '') + ' data-line="' + at + '">' + box + body + kids + '</li>';
    });
    return html + '</' + tag + '>';
  }

  function blocks(lines, base, ctx, depth) {
    let html = '';
    let i = 0;
    const n = lines.length;
    while (i < n) {
      const raw = lines[i];
      if (!raw.trim() || RE_COMMENT.test(raw)) { i++; continue; }
      const at = base + i;
      let m;
      if (RE_FENCE.test(raw)) { const [h, ni] = fenceBlock(lines, i, base, 0); html += h; i = ni; continue; }
      if ((m = RE_HEAD.exec(raw))) {
        const lvl = m[1].length;
        html += '<h' + (lvl + 1 > 5 ? 5 : lvl + 1) + ' class="rb-h rb-h' + Math.min(lvl, 3) + '" data-line="' + at + '">' + inline(m[2].replace(RE_BLOCKID, ''), ctx) + '</h' + (lvl + 1 > 5 ? 5 : lvl + 1) + '>';
        i++; continue;
      }
      if (RE_HR.test(raw)) { html += '<hr class="md-hr" data-line="' + at + '">'; i++; continue; }
      if (RE_QUOTE.test(raw)) {
        const inner = [];
        let j = i;
        while (j < n && RE_QUOTE.test(lines[j])) { inner.push(RE_QUOTE.exec(lines[j])[1]); j++; }
        const cm = depth < MAX_DEPTH ? RE_CALLOUT.exec(inner[0].trim()) : null;
        if (cm) {
          const type = cm[1].toLowerCase(), def = CALLOUTS[type] || CALLOUTS.note;
          const title = cm[3].trim() ? inline(cm[3].trim(), ctx, true) : esc(def[1]);
          const body = blocks(inner.slice(1), at + 1, ctx, depth + 1);
          const fold = cm[2];
          const head = '<span class="md-callout-title">' + title + '</span>';
          if (fold) html += '<details class="md-callout" data-kind="' + def[0] + '" data-type="' + esc(type) + '" data-line="' + at + '"' + (fold === '+' ? ' open' : '') + '><summary>' + head + '</summary><div class="md-callout-body">' + body + '</div></details>';
          else html += '<div class="md-callout" data-kind="' + def[0] + '" data-type="' + esc(type) + '" data-line="' + at + '"><div class="md-callout-head">' + head + '</div>' + (body ? '<div class="md-callout-body">' + body + '</div>' : '') + '</div>';
        } else {
          html += '<blockquote class="md-quote" data-line="' + at + '">' + (depth < MAX_DEPTH ? blocks(inner, at, ctx, depth + 1) : inline(inner.join(' '), ctx)) + '</blockquote>';
        }
        i = j; continue;
      }
      if (i + 1 < n && isTableStart(raw, lines[i + 1]) && !RE_LIST.test(raw)) {
        const [h, ni] = renderTable(lines, i, base, ctx); html += h; i = ni; continue;
      }
      if (RE_LIST.test(raw)) {
        const { items, next } = collectList(lines, i);
        buildTree(items).forEach(l => { html += renderList(l, base, ctx, 0); });
        i = next; continue;
      }
      // 문단
      const para = [];
      let j = i;
      while (j < n && lines[j].trim() && !RE_COMMENT.test(lines[j]) && (j === i || !startsBlock(lines[j], lines[j + 1]))) { para.push(lines[j]); j++; }
      if (!para.length) { para.push(raw); j = i + 1; }
      html += '<p data-line="' + at + '">' + para.map(l => inline(l.trim().replace(RE_BLOCKID, ''), ctx)).join('<br>') + '</p>';
      i = j;
    }
    return html;
  }

  // ---------------------------------------------------------------------------
  // 프런트매터 → 접힌 속성 표
  function frontmatter(lines) {
    if (!lines.length || lines[0].trim() !== '---') return null;
    for (let i = 1; i < lines.length; i++) {
      const t = lines[i].trim();
      if (t === '---' || t === '...') return { end: i, body: lines.slice(1, i) };
    }
    return null;
  }
  function renderProps(body, ctx) {
    const props = [];
    let cur = null;
    body.forEach(ln => {
      const m = /^([^\s:#-][^:]*):[ \t]*(.*)$/.exec(ln);
      if (m && !/^[ \t]/.test(ln)) { cur = { key: m[1].trim(), vals: m[2].trim() ? [m[2].trim()] : [] }; props.push(cur); return; }
      const li = /^[ \t]*-[ \t]+(.*)$/.exec(ln);
      if (li && cur) cur.vals.push(li[1].trim());
      else if (ln.trim() && cur && /^[ \t]/.test(ln)) cur.vals.push(ln.trim());
    });
    if (!props.length) return '';
    const unq = v => v.replace(/^["']|["']$/g, '');
    const rows = props.map(p => {
      let vals = p.vals;
      if (vals.length === 1 && /^\[.*\]$/.test(vals[0]) && !vals[0].startsWith('[[')) vals = vals[0].slice(1, -1).split(',').map(x => x.trim()).filter(Boolean);
      const key = p.key.toLowerCase();
      const cell = (key === 'tags' || key === 'tag')
        ? vals.map(v => unq(v).replace(/^#/, '')).filter(Boolean).map(v => '<button type="button" class="md-tag" data-tag="' + esc(v) + '">#' + esc(v) + '</button>').join(' ')
        : vals.map(v => inline(unq(v), ctx)).join('<span class="md-sep">, </span>');
      return '<div class="md-prop"><dt>' + esc(p.key) + '</dt><dd>' + (cell || '<span class="md-none">—</span>') + '</dd></div>';
    }).join('');
    return '<details class="md-props" data-line="1"><summary>속성 ' + props.length + '개</summary><dl>' + rows + '</dl></details>';
  }

  function render(text, opts) {
    opts = opts || {};
    const ctx = { mark: typeof opts.mark === 'function' ? opts.mark : esc, resolve: typeof opts.resolve === 'function' ? opts.resolve : null, readOnly: opts.readOnly === true };
    let src = String(text == null ? '' : text).replace(/\r\n?/g, '\n');
    if (src.charCodeAt(0) === 0xFEFF) src = src.slice(1);
    const lines = src.split('\n');
    let html = '', from = 0;
    const fm = opts.frontmatter === false || opts.readOnly === true ? null : frontmatter(lines);
    if (fm) { html += renderProps(fm.body, ctx); from = fm.end + 1; }
    html += blocks(lines.slice(from), from + 1, ctx, 0);
    return html || '<p class="rb-none">본문이 비어 있어요.</p>';
  }

  // 본문의 링크 대상(앱이 새 노트 제안·검증에 쓴다). 코드 안은 건너뛰지 않는 가벼운 버전.
  function linkTargets(text) {
    const out = new Set();
    String(text || '').replace(/!?\[\[([^\[\]\n]+?)\]\]/g, (_, inner) => { const w = splitWiki(inner); if (w.target) out.add(w.target); return ''; });
    return [...out];
  }

  const api = Object.freeze({ render, inline: (s, o) => inline(s, { mark: (o && o.mark) || esc, resolve: (o && o.resolve) || null }, false, 0), esc, linkTargets, IMG_EXT });
  root.SynapseMarkdown = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof window !== 'undefined' ? window : globalThis);
