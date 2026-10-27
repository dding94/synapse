#!/bin/bash
# Synapse 설치: 소스를 이 Mac에서 빌드해 ~/Applications/Synapse.app에 둔다.
#   curl -fsSL https://raw.githubusercontent.com/dding94/synapse/main/install.sh | bash
#   (소스 폴더 안에서) ./install.sh
# 환경 변수: SYNAPSE_INSTALL_DIR(기본 ~/Applications) · SYNAPSE_BIN_DIR(기본 ~/.local/bin)
#            SYNAPSE_REF(태그·브랜치, 기본 최신 릴리스 → 없으면 main) · SYNAPSE_REPO(기본 dding94/synapse)
#            SYNAPSE_TARBALL(소스 tar.gz의 경로나 주소 — 주면 그것으로 빌드)
set -euo pipefail

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf 'synapse 설치: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail "macOS에서만 설치할 수 있어요."
OSVER="$(sw_vers -productVersion)"
[ "${OSVER%%.*}" -ge 14 ] || fail "macOS 14(Sonoma) 이상이 필요해요. 지금: $OSVER"
xcrun --find swiftc >/dev/null 2>&1 || fail "Swift 컴파일러가 없어요. 먼저 'xcode-select --install'로 Xcode Command Line Tools를 설치해 주세요."

INSTALL_DIR="${SYNAPSE_INSTALL_DIR:-$HOME/Applications}"
BIN_DIR="${SYNAPSE_BIN_DIR:-$HOME/.local/bin}"
REPO="${SYNAPSE_REPO:-dding94/synapse}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/synapse-install.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# 소스: 이 스크립트가 소스 폴더 안에 있으면 그 폴더(빌드는 사본에서), 아니면 내려받는다
SELF_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
mkdir -p "$WORK/src"
if [ -z "${SYNAPSE_TARBALL:-}" ] && [ -n "$SELF_DIR" ] && [ -f "$SELF_DIR/build.sh" ] && [ -f "$SELF_DIR/main.swift" ]; then
  say "소스: $SELF_DIR"
  (cd "$SELF_DIR" && tar --exclude ./dist --exclude ./build --exclude ./.git -cf - .) | (cd "$WORK/src" && tar -xf -)
else
  URL="${SYNAPSE_TARBALL:-}"
  if [ -z "$URL" ]; then
    REF="${SYNAPSE_REF:-}"
    if [ -z "$REF" ]; then
      REF="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
             | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || true)"
    fi
    if [ -n "$REF" ]; then URL="https://github.com/$REPO/archive/$REF.tar.gz"
    else URL="https://github.com/$REPO/archive/refs/heads/main.tar.gz"; fi
  fi
  say "소스 받는 중: $URL"
  if [ -f "$URL" ]; then cp "$URL" "$WORK/src.tar.gz"; else curl -fsSL "$URL" -o "$WORK/src.tar.gz"; fi
  tar -xzf "$WORK/src.tar.gz" -C "$WORK/src" --strip-components 1
fi
[ -f "$WORK/src/build.sh" ] || fail "받은 소스에 build.sh가 없어요."

say "빌드 중 — 5~10분 걸려요"
if ! (cd "$WORK/src" && SYNAPSE_OUTPUTS="$WORK/out" bash ./build.sh) > "$WORK/build.log" 2>&1; then
  tail -30 "$WORK/build.log" >&2
  fail "빌드하지 못했어요. 위 로그를 확인해 주세요."
fi

mkdir -p "$INSTALL_DIR" "$BIN_DIR"
rm -rf "$INSTALL_DIR/Synapse.app"
mv "$WORK/out/Synapse.app" "$INSTALL_DIR/Synapse.app"
install -m 755 "$WORK/src/build/synapse-cli" "$BIN_DIR/synapse-cli"
ln -sf "$INSTALL_DIR/Synapse.app/Contents/MacOS/synapse-mcp" "$BIN_DIR/synapse-mcp"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$INSTALL_DIR/Synapse.app/Contents/Info.plist" 2>/dev/null || echo '?')"
say "Synapse $VERSION 설치 완료: $INSTALL_DIR/Synapse.app"
cat <<EOM
- 열기: open "$INSTALL_DIR/Synapse.app"   (다음부터 단축키 ⌃⌥Space)
- 이미 켜져 있었다면 한 번 종료하고 다시 열어 주세요.
- CLI: $BIN_DIR/synapse-cli   (PATH에 $BIN_DIR이 없으면 추가해 주세요)
- Claude Code에서 Synapse 도구 쓰기(선택):
    claude mcp add --scope user synapse -- "$INSTALL_DIR/Synapse.app/Contents/MacOS/synapse-mcp"
- 지우기: rm -rf "$INSTALL_DIR/Synapse.app" "$BIN_DIR/synapse-cli" "$BIN_DIR/synapse-mcp"
EOM
