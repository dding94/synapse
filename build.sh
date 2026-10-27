#!/bin/bash
# Synapse 빌드: 번들(Graph.html) → swiftc(main.swift + Library/**) → <출력 폴더>/Synapse.app 조립 + 서명
#               + build/synapse-cli (tools/cli/main.swift + Library/**)
#               + build/synapse-mcp (tools/mcp/main.swift + Library/**) → Synapse.app/Contents/MacOS/synapse-mcp
# 사용법: ./build.sh [--html | --run]
# 환경변수: SKIP_BUNDLE=1 (Graph.html 재생성 생략), SYNAPSE_OUTPUTS=<dir> (Synapse.app을 놓을 폴더, 기본 ./dist)
# 개인 설정: 저장소 밖에 둘 값(예: 출력 폴더)은 build.local.sh에 적는다(git에 올리지 않는다).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[ -f "$ROOT/build.local.sh" ] && . "$ROOT/build.local.sh"
OUTPUTS="${SYNAPSE_OUTPUTS:-$ROOT/dist}"
APP="$OUTPUTS/Synapse.app"
MODE="build"
case "${1:-}" in
  "") ;;
  --html) MODE="html" ;;
  --run) MODE="run" ;;
  *) echo "usage: $0 [--html | --run]" >&2; exit 2 ;;
esac

[ "${SKIP_BUNDLE:-}" = 1 ] || bash "$ROOT/tools/bundle-html.sh" "$ROOT/Graph.html"
[ "$MODE" = "html" ] && exit 0

cd "$ROOT"
if [ ! -f Synapse.icns ]; then
  echo "build: Synapse.icns 없음 → 생성"
  swiftc -O make-icon.swift -o make-icon -framework AppKit
  ./make-icon Synapse.iconset
  iconutil -c icns Synapse.iconset -o Synapse.icns
fi

# Library/**/*.swift 전부 (macOS 기본 bash 3.2 호환: mapfile 없이)
LIB_SOURCES=()
while IFS= read -r f; do LIB_SOURCES+=("$f"); done < <(find Library -name '*.swift' -type f | LC_ALL=C sort)
[ "${#LIB_SOURCES[@]}" -gt 0 ] || { echo "build: Library/*.swift 없음" >&2; exit 1; }
FRAMEWORKS=(-framework AppKit -framework WebKit -framework Carbon -framework PDFKit -framework NaturalLanguage
            -framework Security -framework CoreServices -lsqlite3)
# FoundationModels(기기 AI)는 macOS 26 SDK부터 있다. SDK에 있으면 약하게 연결해 macOS 14에서도 실행되게 하고,
# 없으면(예전 Xcode) 연결하지 않는다 — 코드는 #if canImport로 감싸 있어 기기 AI만 빠진다.
SDK="$(xcrun --show-sdk-path 2>/dev/null || true)"
if [ -n "$SDK" ] && [ -d "$SDK/System/Library/Frameworks/FoundationModels.framework" ]; then
  FRAMEWORKS+=(-Xlinker -weak_framework -Xlinker FoundationModels)
fi
# 이 Mac의 CPU로 빌드한다(Apple Silicon: arm64, Intel: x86_64). SYNAPSE_ARCH로 바꿀 수 있다.
ARCH="${SYNAPSE_ARCH:-$(uname -m)}"
SWIFTC=(swiftc -O -swift-version 5 -target "$ARCH-apple-macos14.0")

# 서명: 키체인에 코드 서명 인증서 "Synapse Dev"(SYNAPSE_SIGN_ID로 바꿀 수 있음)가 있으면 그것으로 서명한다.
# 빌드가 바뀌어도 macOS가 같은 앱으로 알아봐서 키체인 토큰·데스크탑 폴더 접근을 다시 묻지 않는다.
# 없거나 codesign이 키를 쓰지 못하면(키체인 허용 거절 등) 예전처럼 임시(ad-hoc) 서명으로 빌드한다.
SIGN_NAME="${SYNAPSE_SIGN_ID:-Synapse Dev}"
SIGN_ID="-"
IDENTITIES="$(security find-identity -p codesigning 2>/dev/null || true)"
if [[ "$SIGN_NAME" =~ ^[0-9A-Fa-f]{40}$ ]]; then
  # 지문(SHA-1)을 직접 준 경우
  case "$IDENTITIES" in *"$SIGN_NAME"*) SIGN_ID="$SIGN_NAME" ;; esac
else
  # 이름이 같은 인증서가 여럿이면 지문이 가장 작은 것을 늘 고른다(빌드마다 같은 신원이어야 같은 앱으로 본다)
  SIGN_ID="$(printf '%s\n' "$IDENTITIES" | awk -v n="\"$SIGN_NAME\"" \
    'index($0, n) && $2 ~ /^[0-9A-F]+$/ && length($2) == 40 { if (min == "" || $2 < min) min = $2 } END { print min }' || true)"
  [ -n "$SIGN_ID" ] || SIGN_ID="-"
  SIGN_COUNT="$(printf '%s\n' "$IDENTITIES" | awk -v n="\"$SIGN_NAME\"" 'index($0, n) { seen[$2] = 1 } END { print length(seen) }' || true)"
  if [ "${SIGN_COUNT:-0}" -gt 1 ]; then
    echo "build: '$SIGN_NAME' 인증서가 ${SIGN_COUNT}개라 지문이 가장 작은 $SIGN_ID 로 서명해요 (하나만 남기면 깔끔해요)" >&2
  fi
fi
sign() {
  if [ "$SIGN_ID" != "-" ]; then
    codesign --force --sign "$SIGN_ID" "$1" >/dev/null 2>&1 && return 0
    echo "build: '$SIGN_ID' 인증서로 서명하지 못해 임시 서명으로 바꿔요 (codesign의 키 사용을 키체인에서 허용했는지 확인)" >&2
    SIGN_ID="-"
  fi
  codesign --force --sign - "$1" >/dev/null 2>&1
}
if [ "$SIGN_ID" = "-" ]; then
  echo "build: 키체인에 '$SIGN_NAME' 코드 서명 인증서가 없어 임시 서명으로 빌드해요 (새 빌드마다 키체인 허용을 다시 물을 수 있어요)" >&2
fi

"${SWIFTC[@]}" main.swift "${LIB_SOURCES[@]}" -o Synapse "${FRAMEWORKS[@]}"

if [ -f tools/cli/main.swift ]; then
  mkdir -p build
  "${SWIFTC[@]}" tools/cli/main.swift "${LIB_SOURCES[@]}" -o build/synapse-cli "${FRAMEWORKS[@]}"
  sign build/synapse-cli
  echo "build: build/synapse-cli $(wc -c < build/synapse-cli | tr -d ' ') bytes"
else
  echo "build: tools/cli/main.swift 없음 → synapse-cli 건너뜀" >&2
fi

HAVE_MCP=0
if [ -f tools/mcp/main.swift ]; then
  mkdir -p build
  "${SWIFTC[@]}" tools/mcp/main.swift "${LIB_SOURCES[@]}" -o build/synapse-mcp "${FRAMEWORKS[@]}"
  echo "build: build/synapse-mcp $(wc -c < build/synapse-mcp | tr -d ' ') bytes"
  HAVE_MCP=1
else
  echo "build: tools/mcp/main.swift 없음 → synapse-mcp 건너뜀" >&2
fi

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/synapse-build.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Synapse.app/Contents/MacOS" "$STAGE/Synapse.app/Contents/Resources"
cp Synapse "$STAGE/Synapse.app/Contents/MacOS/Synapse"
cp Graph.html Synapse.icns "$STAGE/Synapse.app/Contents/Resources/"
cp Info.plist "$STAGE/Synapse.app/Contents/Info.plist"
if [ "$HAVE_MCP" = 1 ]; then
  cp build/synapse-mcp "$STAGE/Synapse.app/Contents/MacOS/synapse-mcp"
  sign "$STAGE/Synapse.app/Contents/MacOS/synapse-mcp"
fi
sign "$STAGE/Synapse.app"

if [ "$MODE" = "run" ]; then
  pkill -x Synapse 2>/dev/null || true
  for _ in $(seq 1 20); do pgrep -x Synapse >/dev/null || break; sleep 0.2; done
fi

mkdir -p "$OUTPUTS"
rm -rf "$APP"
mv "$STAGE/Synapse.app" "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")"
echo "build: Synapse $VERSION ($BUILD) → $APP"
echo "build: Graph.html $(wc -c < Graph.html | tr -d ' ') bytes · binary $(wc -c < Synapse | tr -d ' ') bytes · $(codesign -dvv "$APP" 2>&1 | grep -m1 -E 'Authority|Signature=adhoc' || true)"

if [ "$MODE" = "run" ]; then open "$APP"; fi
