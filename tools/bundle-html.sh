#!/bin/bash
# src/index.html 의 "@inline <파일>" 표시 줄을 src/<파일> 내용으로 바꿔 한 장짜리 Graph.html 을 만든다.
# 앱은 CSP 때문에 외부 파일을 읽지 않으므로 CSS·JS 를 모두 인라인으로 넣는다.
# 사용법: tools/bundle-html.sh [출력 경로]   (기본값: 프로젝트 루트의 Graph.html)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/src"
OUT="${1:-$ROOT/Graph.html}"

awk -v src="$SRC" '
  match($0, /@inline [A-Za-z0-9._\/-]+/) {
    file = substr($0, RSTART + 8, RLENGTH - 8)
    path = src "/" file
    found = 0
    while ((status = (getline line < path)) > 0) { print line; found = 1 }
    if (status < 0 || !found) { print "bundle-html: cannot inline " path > "/dev/stderr"; exit 1 }
    close(path)
    next
  }
  { print }
' "$SRC/index.html" > "$OUT.tmp"

mv "$OUT.tmp" "$OUT"
echo "bundle-html: $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"
