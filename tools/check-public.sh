#!/bin/bash
# 공개 점검: 저장소에 올리거나 배포하기 전에 개인·회사 정보가 섞이지 않았는지 기계적으로 확인한다.
# 사용법: tools/check-public.sh [폴더]   (기본: git에 올라갈 파일 — git ls-files 기준. git이 아니면 폴더 전체)
#
# 금지어 목록은 저장소에 두지 않는다. 저장소 루트의 .public-deny(.gitignore 허용 목록 밖이라 올라가지 않는다)나
# SYNAPSE_PUBLIC_DENY가 가리키는 파일에 한 줄에 하나씩 적는다.
#   형식: 한 줄 = 확장 정규식(ERE). '#'으로 시작하는 줄은 주석. 'i:'로 시작하면 대소문자를 무시한다.
# 찾으면 줄을 보여 주고 종료 코드 1. 사람·검토자의 확인을 대신하지 않는다.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-}"
LIST="$(mktemp)"; trap 'rm -f "$LIST" "$LIST".*' EXIT
if [ -z "$TARGET" ] && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  BASE="$ROOT"
  (cd "$ROOT" && git ls-files -co --exclude-standard) > "$LIST"
else
  BASE="$(cd "${TARGET:-$ROOT}" && pwd)"
  (cd "$BASE" && find . -type f -not -path './.git/*' | sed 's|^\./||') > "$LIST"
fi
grep -vE '\.(png|icns|jpg|jpeg|gif|pdf|docx|hwpx|odt|zip)$' "$LIST" > "$LIST.t" && mv "$LIST.t" "$LIST"

fails=0
show() { printf '\n[%s]\n' "$1"; }
scan() {   # $1 이름, $2 grep 옵션, $3 패턴
  local out
  out="$(cd "$BASE" && tr '\n' '\0' < "$LIST" | xargs -0 grep -nH $2 -E -- "$3" 2>/dev/null | head -40)"
  if [ -n "$out" ]; then show "$1"; printf '%s\n' "$out"; fails=$((fails + 1)); fi
}

# 1) 일반 점검 — 메일 주소(example.* · noreply만 허용)
EMAILS="$(cd "$BASE" && tr '\n' '\0' < "$LIST" | xargs -0 grep -nHoE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' 2>/dev/null \
          | grep -vE '@(example\.(com|org|net|test)|users\.noreply\.github\.com)$|@[0-9]+\.[0-9]+' | head -40)"
if [ -n "$EMAILS" ]; then show "메일 주소"; printf '%s\n' "$EMAILS"; fails=$((fails + 1)); fi
# 2) 일반 점검 — Atlassian 사이트(자리 표시·가짜 이름만 허용)
SITES="$(cd "$BASE" && tr '\n' '\0' < "$LIST" | xargs -0 grep -nHoiE '[a-z0-9-]+\.atlassian\.net' 2>/dev/null \
         | grep -viE ':(your-team|example|your-site|team|mock|acme|demo|[a-z0-9-]+-mock|acme-[a-z0-9-]+)\.atlassian\.net$' | head -20)"
if [ -n "$SITES" ]; then show "Atlassian 사이트"; printf '%s\n' "$SITES"; fails=$((fails + 1)); fi
# 3) 일반 점검 — 사용자 홈 경로(/Users/me · /Users/<사용자>만 허용)
HOMES="$(cd "$BASE" && tr '\n' '\0' < "$LIST" | xargs -0 grep -nHoE '(^|[^A-Za-z0-9_$}])/(Users|home)/[A-Za-z0-9._-]+' 2>/dev/null \
         | grep -vE ':[^/]?/Users/(me|Shared)$' | head -20)"
if [ -n "$HOMES" ]; then show "사용자 홈 경로"; printf '%s\n' "$HOMES"; fails=$((fails + 1)); fi

# 4) 로컬 금지어 (저장소 밖 목록)
DENY="${SYNAPSE_PUBLIC_DENY:-$ROOT/.public-deny}"
if [ -f "$DENY" ]; then
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    n=$((n + 1))
    if [ "${line#i:}" != "$line" ]; then
      scan "금지어 #$n" "-i" "${line#i:}"
      names="$(grep -iE -- "${line#i:}" "$LIST")"
    else
      scan "금지어 #$n" "" "$line"
      names="$(grep -E -- "$line" "$LIST")"
    fi
    if [ -n "$names" ]; then show "파일 이름 (금지어 #$n)"; printf '%s\n' "$names"; fails=$((fails + 1)); fi
  done < "$DENY"
  echo "check-public: 로컬 금지어 ${n}개 적용"
else
  echo "check-public: 로컬 금지어 목록($DENY)이 없어 일반 점검만 했어요" >&2
fi

count="$(wc -l < "$LIST" | tr -d ' ')"
if [ "$fails" -gt 0 ]; then
  printf '\ncheck-public: 걸린 항목 %s종 (파일 %s개 점검). 고친 뒤 다시 실행하세요.\n' "$fails" "$count" >&2
  exit 1
fi
echo "check-public: 통과 (파일 $count개)"
