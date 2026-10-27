#!/bin/bash
# dev/ui/build-mock.sh <out-dir> — 화면 개발용: src를 번들한 Graph.html과, 모의 네이티브 브리지(mock-native.js)를
# 끼운 시나리오별 페이지 mock-<empty|lib|indexing|error|flaky|notice>.html 과 v0.5 사서 페이지
# mock-<home|home-empty|sessions-card|queue|week|stopped|nobrain>.html, v0.8 Claude 연결 페이지 mock-ai-*.html 을 만든다. 앱 빌드와는 무관하다.
#   mock-ai-week(-ready)      이번 주 · 첫 정리(running → 1.5초 뒤 정리) / 정리가 이미 있음
#   mock-ai-tickets(-ready)   티켓(예시 14개)
#   mock-ai-off · -missing · -login · -running · -rerun · -error · -error-old · -limit · -manual · -stale · -empty   안내·실행 중·오류 상태 (이번 주 / 티켓 시작)
#   mock-ai-panel · mock-ai-home · mock-ai-queue   시키기 패널(⌘J) · 홈 브리핑 · 정리함의 Jira 카드 (U2 확인용)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="${1:?usage: build-mock.sh <out-dir>}"
mkdir -p "$OUT"
"$ROOT/tools/bundle-html.sh" "$OUT/Graph.html" >/dev/null
python3 - "$OUT" "$HERE/mock-native.js" <<'PY'
import sys
out, mock = sys.argv[1], open(sys.argv[2], encoding='utf-8').read()
page = open(out + '/Graph.html', encoding='utf-8').read()
# 이름 → (자료 시나리오, 사서 시나리오). v0.5 사서 화면 확인용 페이지는 아래쪽.
PAGES = [('empty', 'empty', 'full'), ('lib', 'lib', 'full'), ('indexing', 'indexing', 'full'), ('error', 'error', 'full'),
         ('flaky', 'flaky', 'full'), ('notice', 'notice', 'full'),
         ('home', 'lib', 'full'), ('home-empty', 'lib', 'empty'), ('sessions-card', 'lib', 'sessions'), ('queue', 'lib', 'queue'),
         ('week', 'lib', 'week'), ('stopped', 'lib', 'stopped'), ('nobrain', 'lib', 'nobrain')]
# v0.8 Claude 연결: 이름 → (사서 시나리오, AI 시나리오, 시작 화면)
AI_PAGES = [('ai-week', 'week', 'on', 'week'), ('ai-week-ready', 'week', 'ready', 'week'),
            ('ai-tickets', 'tickets', 'on', 'tickets'), ('ai-tickets-ready', 'tickets', 'ready', 'tickets'),
            ('ai-off', 'tickets', 'off', 'week'), ('ai-missing', 'tickets', 'missing', 'tickets'), ('ai-login', 'tickets', 'login', 'week'),
            ('ai-running', 'tickets', 'running', 'week'), ('ai-rerun', 'tickets', 'rerun', 'week'), ('ai-error', 'tickets', 'error', 'week'),
            ('ai-error-old', 'tickets', 'errorOld', 'week'), ('ai-limit', 'tickets', 'limit', 'week'), ('ai-manual', 'tickets', 'manual', 'week'),
            ('ai-stale', 'tickets', 'stale', 'week'), ('ai-empty', 'tickets', 'empty', 'week'),
            ('ai-panel', 'jira', 'ready', 'home'), ('ai-home', 'tickets', 'ready', 'home'), ('ai-queue', 'jira', 'ready', 'queue')]
def write(name, sc, brain, extra=''):
    inject = "<body>\n<script>window.__MOCK_SCENARIO=%r;window.__MOCK_BRAIN=%r;%s</script>\n<script>\n%s\n</script>" % (sc, brain, extra, mock)
    open('%s/mock-%s.html' % (out, name), 'w', encoding='utf-8').write(page.replace('<body>', inject, 1))
for name, sc, brain in PAGES:
    write(name, sc, brain)
for name, brain, ai, start in AI_PAGES:
    write(name, 'lib', brain, 'window.__MOCK_AI=%r;window.__MOCK_START=%r;' % (ai, start))
print('build-mock:', out)
PY
