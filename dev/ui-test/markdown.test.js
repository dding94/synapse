// dev/ui-test/markdown.test.js — src/markdown.js 시험 (node dev/ui-test/markdown.test.js)
// XSS 문자열, 표, 중첩 목록, 콜아웃, 위키링크 별칭, 체크박스, 코드 블록, 프런트매터, 그림 자리를 확인한다.
'use strict';
const assert = require('assert');
const path = require('path');
const MD = require(path.join(__dirname, '../../src/markdown.js'));

let passed = 0;
function t(name, fn) {
  try { fn(); passed++; }
  catch (e) { console.error('실패 · ' + name + '\n  ' + (e && e.message || e)); process.exitCode = 1; }
}
const has = (html, s) => assert.ok(html.includes(s), '들어 있어야 해요: ' + s + '\n--- 결과 ---\n' + html);
const lacks = (html, s) => assert.ok(!html.includes(s), '없어야 해요: ' + s + '\n--- 결과 ---\n' + html);
const r = (md, o) => MD.render(md, o);

// 허용 목록 밖의 태그가 나오지 않는지 — 이 파일이 만드는 태그만 통과
const ALLOWED = new Set(['p', 'br', 'h2', 'h3', 'h4', 'h5', 'hr', 'ul', 'ol', 'li', 'blockquote', 'pre', 'code', 'span', 'button', 'input',
  'strong', 'em', 'del', 'mark', 'table', 'thead', 'tbody', 'tr', 'th', 'td', 'div', 'details', 'summary', 'dl', 'dt', 'dd']);
function tagsOf(html) { return [...html.matchAll(/<\/?([a-zA-Z][a-zA-Z0-9]*)/g)].map(m => m[1].toLowerCase()); }
function onlyAllowed(html) { tagsOf(html).forEach(tag => assert.ok(ALLOWED.has(tag), '허용되지 않은 태그: ' + tag + '\n' + html)); }
// 속성 값 밖에서 on* 핸들러·href·src 같은 것이 생기지 않는지
function noDangerousAttrs(html) {
  const attrs = [...html.matchAll(/<[a-z0-9]+\s([^>]*)>/gi)].map(m => m[1]);
  attrs.forEach(a => {
    const stripped = a.replace(/"[^"]*"/g, '""');
    assert.ok(!/\bon\w+\s*=/i.test(stripped), '이벤트 속성: ' + a);
    assert.ok(!/\b(href|src|srcdoc|style|formaction|action)\s*=/i.test(stripped), '위험한 속성: ' + a);
  });
}

t('XSS: 원본 HTML은 모두 이스케이프', () => {
  const evil = [
    '<script>alert(1)</script>',
    '<img src=x onerror=alert(1)>',
    '<a href="javascript:alert(1)">x</a>',
    '<iframe src="https://evil"></iframe>',
    '"><svg onload=alert(1)>',
    '<div onclick="x()">hi</div>',
  ];
  evil.forEach(s => {
    const h = r(s);
    lacks(h, '<script'); lacks(h, '<img'); lacks(h, '<iframe'); lacks(h, '<svg'); lacks(h, '<a '); lacks(h, '<div onclick');
    onlyAllowed(h); noDangerousAttrs(h);
    has(h, '&lt;');
  });
});

t('XSS: 링크·그림·위키링크·태그 안의 따옴표/태그', () => {
  const md = [
    '[x](javascript:alert(1))',
    '[y](JaVaScRiPt:alert(1))',
    '[z](data:text/html;base64,PHNjcmlwdD4=)',
    '[a](https://e.com/"onmouseover="alert(1))',
    '![i](javascript:alert(1))',
    '![[a"><script>alert(1)</script>.png]]',
    '[[x"><img src=x onerror=alert(1)>]]',
    '[[x|"><b onclick=1>]]',
    '#tag"><script>',
    '`<script>`',
    '<https://e.com/a"onclick="x>',
    '[[a]](javascript:1)',
  ].join('\n\n');
  const h = r(md);
  lacks(h, '<script'); lacks(h, '<img'); lacks(h, '<b ');
  onlyAllowed(h); noDangerousAttrs(h);
  // javascript: 주소는 링크가 되지 않는다
  assert.ok(!/data-md-url="javascript/i.test(h), 'javascript: 주소가 링크로 남음\n' + h);
  assert.ok(!/data-md-url="data:/i.test(h));
});

t('XSS: 프런트매터·표·콜아웃·코드 블록도 이스케이프', () => {
  const md = '---\ntitle: <script>x</script>\ntags: ["<img onerror=1>"]\n---\n\n| <b>a</b> | b |\n|---|---|\n| <i>c</i> | d |\n\n> [!note] <u>제목</u>\n> <script>1</script>\n\n```<script>\n<img src=x onerror=1>\n```';
  const h = r(md);
  lacks(h, '<script'); lacks(h, '<img'); lacks(h, '<b>'); lacks(h, '<i>'); lacks(h, '<u>');
  onlyAllowed(h); noDangerousAttrs(h);
});

t('XSS: 검색어 강조 함수가 돌려준 HTML만 쓰고 원문은 건드리지 않는다', () => {
  const mark = s => MD.esc(s).replace(/검색/g, '<mark>검색</mark>');
  const h = r('검색 <b>x</b>', { mark });
  has(h, '<mark>검색</mark>'); has(h, '&lt;b&gt;x&lt;/b&gt;');
});

t('제목·문단·줄 번호', () => {
  const h = r('# 큰 제목\n\n본문 한 줄\n둘째 줄\n\n### 작은 제목');
  has(h, '<h2 class="rb-h rb-h1" data-line="1">큰 제목</h2>');
  has(h, '<p data-line="3">본문 한 줄<br>둘째 줄</p>');
  has(h, 'class="rb-h rb-h3" data-line="6"');
});

t('인라인: 굵게·기울임·취소선·강조·코드', () => {
  const h = r('**굵게** *기울임* ~~취소~~ ==강조== `코드 <b>` ***둘다***');
  has(h, '<strong>굵게</strong>'); has(h, '<em>기울임</em>'); has(h, '<del>취소</del>');
  has(h, '<mark class="md-hl">강조</mark>'); has(h, '<code class="md-ic">코드 &lt;b&gt;</code>'); has(h, '<strong><em>둘다</em></strong>');
});

t('인라인: snake_case_name 은 기울임이 되지 않는다', () => {
  const h = r('값은 snake_case_name 이고 _진짜 기울임_ 이에요');
  has(h, 'snake_case_name'); has(h, '<em>진짜 기울임</em>');
});

t('중첩 목록·번호 목록', () => {
  const h = r('- 가\n  - 나\n    - 다\n- 라\n\n1. 하나\n2. 둘\n   - 안쪽');
  has(h, '<ul><li data-line="1">가<ul><li data-line="2">나<ul><li data-line="3">다</li></ul></li></ul></li><li data-line="4">라</li></ul>');
  has(h, '<ol><li data-line="6">하나</li><li data-line="7">둘<ul><li data-line="8">안쪽</li></ul></li></ol>');
});

t('체크박스: 줄 번호와 상태', () => {
  const h = r('- [ ] 할 일\n- [x] 끝난 일\n  - [X] 안쪽');
  has(h, '<input type="checkbox" class="md-check" data-md-check="1" aria-label="완료 표시"> 할 일');
  has(h, 'data-md-check="2" checked');
  has(h, 'data-md-check="3" checked');
  has(h, 'class="md-task is-done" data-line="2"');
});

t('인용과 콜아웃', () => {
  const q = r('> 인용 한 줄\n> 둘째');
  has(q, '<blockquote class="md-quote" data-line="1">');
  const c = r('> [!warning] 조심해요\n> 내용 **굵게**\n> - 목록');
  has(c, 'class="md-callout" data-kind="warning" data-type="warning" data-line="1"');
  has(c, '<span class="md-callout-title">조심해요</span>'); has(c, '<strong>굵게</strong>'); has(c, '<li data-line="3">목록</li>');
  const d = r('> [!tip]-\n> 접힘');
  has(d, '<details class="md-callout" data-kind="tip"'); has(d, '팁');
  assert.ok(!/ open/.test(d.split('>')[0]), '접힘은 기본 닫힘');
  const e = r('> [!faq]+ 열림\n> x');
  has(e, '<details class="md-callout" data-kind="question" data-type="faq" data-line="1" open>');
  const f = r('> [!unknown_type] 이름\n> x');
  has(f, 'data-kind="note"');
});

t('위키링크: 별칭·제목·해석', () => {
  const resolve = tg => (tg === '있는 노트' ? { id: 'S:있는 노트.md' } : tg === '없는 노트' ? null : undefined);
  const h = r('[[있는 노트]] [[있는 노트|별칭]] [[있는 노트#소제목]] [[없는 노트]] [[모르는]]', { resolve });
  has(h, 'data-md-target="있는 노트" data-md-id="S:있는 노트.md"');
  has(h, '>별칭</button>');
  has(h, 'data-md-anchor="소제목"'); has(h, '있는 노트 › 소제목');
  has(h, 'md-link md-wiki is-miss" data-md-target="없는 노트"');
  has(h, 'md-link md-wiki" data-md-target="모르는"');
  assert.ok(!/<a /.test(h));
});

t('위키링크: 대소문자·확장자 그대로 대상에 담는다 (해석은 엔진 몫)', () => {
  const h = r('[[Folder/Note.md|x]]');
  has(h, 'data-md-target="Folder/Note.md"');
});

t('바깥 링크·맨 주소·마크다운 문서 링크', () => {
  const h = r('[글](https://example.com/a?b=1) 그리고 https://example.org/path. 끝 [문서](notes/한글%20노트.md#절)');
  has(h, 'data-md-url="https://example.com/a?b=1"'); has(h, '>글</button>');
  has(h, 'data-md-url="https://example.org/path"');
  has(h, 'data-md-target="notes/한글 노트.md" data-md-anchor="절"');
  assert.ok(!/href=/.test(h));
});

t('그림 자리와 임베드', () => {
  const h = r('![[사진.png]] ![[사진.jpg|300]] ![대체](img/a%20b.png) ![[다른 노트]] ![[문서.pdf]] ![](https://e.com/x.png)');
  has(h, 'data-md-asset="사진.png"'); has(h, 'data-md-asset="사진.jpg" data-md-w="300"'); has(h, 'data-md-asset="img/a b.png"');
  has(h, 'is-embed'); has(h, 'data-md-target="다른 노트"'); has(h, '첨부 · 문서.pdf'); has(h, 'data-md-url="https://e.com/x.png"');
  lacks(h, '<img');
});

t('태그', () => {
  const h = r('#태그 중간 #두번째 a#nope # 제목아님 #123 `#코드`');
  has(h, 'data-tag="태그"'); has(h, 'data-tag="두번째"');
  lacks(h, 'data-tag="nope"'); lacks(h, 'data-tag="123"'); lacks(h, 'data-tag="코드"');
});

t('GFM 표: 정렬·이스케이프된 파이프·코드 안 파이프', () => {
  const h = r('| 이름 | 값 | 비고 |\n|:--|--:|:-:|\n| a | 1 | `x|y` |\n| b \\| c | 2 | **굵게** |\n\n뒤 문단');
  has(h, '<table class="md-table">');
  has(h, '<th>이름</th>'.replace('<th>', '<th class="al-l">'));
  has(h, '<th class="al-r">값</th>'); has(h, '<th class="al-c">비고</th>');
  has(h, '<code class="md-ic">x|y</code>'); has(h, '<td class="al-l">b | c</td>'); has(h, '<strong>굵게</strong>');
  has(h, '<p data-line="6">뒤 문단</p>');
});

t('코드 블록: 언어 표시·내용 보존·닫히지 않은 울타리', () => {
  const h = r('```js\nconst a = "<b>";\n  **그대로**\n```\n\n뒤');
  has(h, '<span class="md-lang">js</span>'); has(h, 'const a = &quot;&lt;b&gt;&quot;;\n  **그대로**'); has(h, '<p data-line="6">뒤</p>');
  const open = r('~~~\n끝까지\n# 제목 아님');
  has(open, '# 제목 아님'); lacks(open, 'rb-h');
});

t('가로줄·프런트매터', () => {
  const h = r('---\ntitle: 제목\ntags:\n  - a\n  - b\naliases: [x, y]\n---\n\n본문\n\n---\n\n끝');
  has(h, '<details class="md-props" data-line="1"><summary>속성 3개</summary>');
  has(h, 'data-tag="a"'); has(h, 'data-tag="b"'); has(h, '<dt>aliases</dt><dd>x<span class="md-sep">, </span>y</dd>');
  has(h, '<p data-line="9">본문</p>'); has(h, '<hr class="md-hr" data-line="11">');
  const nofm = r('---\n본문');   // 닫는 줄이 없으면 프런트매터가 아니다
  has(nofm, 'md-hr');
});

t('프런트매터 값의 위키링크', () => {
  const h = r('---\nrelated: [[a]], [[b]]\n---\n본문', { resolve: x => ({ id: 'S:' + x }) });
  has(h, 'data-md-target="a"'); has(h, 'data-md-target="b"');
});

t('프런트매터 뒤 줄 번호는 원문 기준', () => {
  const h = r('---\na: 1\n---\n# 제목\n- [ ] 일');
  has(h, 'rb-h1" data-line="4"'); has(h, 'data-md-check="5"');
});

t('주석·블록 ID', () => {
  const h = r('<!-- 숨김 -->\n\n문단 ^abc123\n\n%% 메모 %%');
  lacks(h, '숨김'); lacks(h, '^abc123'); lacks(h, '메모');
});

t('목록 안 코드 블록', () => {
  const h = r('- 항목\n  ```sql\n  select 1;\n  ```\n- 다음');
  has(h, '<pre class="md-code"'); has(h, 'select 1;'); has(h, '<li data-line="5">다음</li>'); lacks(h, '```');
});

t('빈 본문', () => { has(r(''), 'rb-none'); has(r('\n\n  \n'), 'rb-none'); });

t('이스케이프', () => { has(r('\\*별\\* \\[[x]]'), '*별*'); lacks(r('\\*별\\*'), '<em>'); });

t('CRLF·BOM', () => { has(r('﻿# 제목\r\n\r\n본문\r\n'), 'data-line="1">제목'); });

t('큰 입력도 빠르다 (20만 자)', () => {
  const big = ('# 제목\n\n문단 **굵게** [[링크]] `코드` https://e.com\n\n- [ ] 항목\n  - 중첩\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n').repeat(1500);
  const t0 = Date.now();
  const h = r(big);
  assert.ok(h.length > 1000);
  assert.ok(Date.now() - t0 < 2500, '너무 느려요: ' + (Date.now() - t0) + 'ms');
});

t('깊은 중첩 인용은 멈춘다', () => { const h = r('> '.repeat(40) + '끝'); has(h, '끝'); onlyAllowed(h); });

// v0.7 D: 원격(Confluence·Jira) 읽기 전용
const ro = md => r(md, { readOnly: true, resolve: () => ({ id: 'x' }) });
t('readOnly: 표는 표로, 가로 스크롤 틀 안에', () => {
  const h = ro('| 항목 | 내용 |\n| --- | --- |\n| 상태 | In Review |');
  has(h, '<table class="md-table">'); has(h, '<td>In Review</td>'); has(h, 'md-table-wrap');
});
t('표 상자는 키보드 포커스를 받는다(볼트·원격 모두)', () => {
  for (const h of [ro('| a | b |\n| --- | --- |\n| 1 | 2 |'), r('| a | b |\n| --- | --- |\n| 1 | 2 |')]) {
    has(h, 'md-table-wrap" tabindex="0" role="region"'); has(h, 'aria-label="표 · 방향키로 가로로 넘겨요"');
  }
});
t('readOnly: 체크박스는 보기만(저장 속성 없음)', () => {
  const h = ro('- [x] 끝\n- [ ] 남음');
  lacks(h, 'data-md-check'); has(h, 'disabled'); has(h, 'checked');
});
t('readOnly: [[링크]]·#태그·코드·강조는 글자 그대로, 바깥 주소는 링크', () => {
  const h = ro('[[문서]] #메모 `a` **b** _c_ https://e.com/x');
  lacks(h, 'md-wiki'); lacks(h, 'md-tag'); lacks(h, '<code'); lacks(h, '<strong'); lacks(h, '<em>');
  has(h, '[[문서]]'); has(h, '#메모'); has(h, '**b**'); has(h, 'data-md-url="https://e.com/x"');
});
t('readOnly: 프런트매터처럼 보이는 머리도 속성 표로 접지 않는다', () => { lacks(ro('---\na: 1\n---\n본문'), 'md-props'); });
t('readOnly 아님(기존): 그대로', () => { has(r('[[문서]]'), 'md-wiki'); has(r('- [ ] a'), 'data-md-check'); });

console.log(process.exitCode ? '일부 실패' : '통과 ' + passed + '개');
