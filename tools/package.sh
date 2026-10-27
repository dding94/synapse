#!/bin/bash
# 배포 묶음 만들기: git에 커밋된 내용 그대로(git archive) dist/synapse-<버전>.tar.gz를 만들고 sha256을 찍는다.
# 공개 점검(tools/check-public.sh)을 통과해야 만든다. 사용법: tools/package.sh [커밋, 기본 HEAD]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "package: git 저장소에서만 만들 수 있어요." >&2; exit 1; }
REV="${1:-HEAD}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"
NAME="synapse-$VERSION"
mkdir -p dist
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
git archive --format=tar --prefix="$NAME/" "$REV" | tar -xf - -C "$TMP"
bash tools/check-public.sh "$TMP/$NAME"
(cd "$TMP" && tar -cf - "$NAME" | gzip -n > "$ROOT/dist/$NAME.tar.gz")
echo "package: dist/$NAME.tar.gz"
shasum -a 256 "dist/$NAME.tar.gz"
