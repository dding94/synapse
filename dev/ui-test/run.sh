#!/bin/bash
# dev/ui-test/run.sh — 실제 앱(Synapse.app)을 화면 밖에서 띄워 시나리오 JS를 돌리고, 중간·마지막 화면을 PNG로 남긴다.
# 시험 실행은 단축키·메뉴 막대·키체인·사용자 설정을 쓰지 않고, 다른 앱·Finder·브라우저도 열지 않는다(stdout의 TEST_OPEN으로만 남김).
#
# 사용법: dev/ui-test/run.sh --app <Synapse.app> --home <템플릿 홈> --script <시나리오.js> --out <결과 폴더>
#                            [--vault <볼트 사본> --source <그 볼트의 출처 id>] [--size 1280x820] [--timeout 180]
# - 템플릿 홈(index.sqlite·brain.sqlite·sources.json …)과 볼트는 결과 폴더로 복제해서 쓴다. 시나리오가 파일을 옮기거나 지워도 템플릿은 그대로다.
# - 결과 폴더: home/ vault/ scenario.js stdout.txt result.json final.png, 그리고 시나리오가 snap()으로 찍은 <이름>.png
# - 시나리오 도우미는 prelude.js 참고(snap·sleep·until·key·click·dblclick·contextClick·type·text·log·dbg·resize). return 값은 result.json에 남는다.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="" HOME_T="" SCRIPT="" OUT="" VAULT="" SRC_ID="" SIZE="1280x820" TIMEOUT="180"
while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --home) HOME_T="$2"; shift 2 ;;
    --script) SCRIPT="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --vault) VAULT="$2"; shift 2 ;;
    --source) SRC_ID="$2"; shift 2 ;;
    --size) SIZE="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    *) echo "run.sh: 알 수 없는 인자 $1" >&2; exit 2 ;;
  esac
done
if [ -z "$APP" ] || [ -z "$HOME_T" ] || [ -z "$SCRIPT" ] || [ -z "$OUT" ]; then sed -n '5,6p' "$0" >&2; exit 2; fi
BIN="$APP/Contents/MacOS/Synapse"
[ -x "$BIN" ] || { echo "run.sh: 앱 실행 파일이 없어요: $BIN" >&2; exit 1; }
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
rm -rf "$OUT/home" "$OUT/vault" "$OUT/config"; rm -f "$OUT"/*.png
cp -Rc "$HOME_T" "$OUT/home" 2>/dev/null || cp -R "$HOME_T" "$OUT/home"
if [ -n "$VAULT" ]; then
  [ -n "$SRC_ID" ] || { echo "run.sh: --vault에는 --source(출처 id)가 필요해요" >&2; exit 2; }
  cp -Rc "$VAULT" "$OUT/vault" 2>/dev/null || cp -R "$VAULT" "$OUT/vault"
  python3 - "$OUT/home/sources.json" "$SRC_ID" "$OUT/vault" <<'PY'
import json, sys
p, sid, vault = sys.argv[1:]
d = json.load(open(p, encoding='utf-8'))
arr = d if isinstance(d, list) else d.get('sources', [])
hit = [s for s in arr if s.get('id') == sid]
if not hit:
    sys.exit('run.sh: sources.json에 출처 %s가 없어요' % sid)
for s in hit:
    s['path'] = vault
json.dump(d, open(p, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
PY
fi
W="${SIZE%x*}"; H="${SIZE#*x}"
python3 - "$HERE/prelude.js" "$SCRIPT" "$OUT" "$W" "$H" > "$OUT/scenario.js" <<'PY'
import json, sys
prelude, script, out, w, h = sys.argv[1:]
src = open(prelude, encoding='utf-8').read()
body = open(script, encoding='utf-8').read()
src = src.replace('__OUT_JSON__', json.dumps(out)).replace('__SIZE_JSON__', json.dumps([int(w), int(h)]))
print(src.replace('/*__SCENARIO__*/', body))
PY
mkdir -p "$OUT/config"
set +e
SYNAPSE_HOME="$OUT/home" SYNAPSE_TEST_OFFSCREEN=1 SYNAPSE_TEST_SCRIPT="$OUT/scenario.js" SYNAPSE_TEST_SNAPSHOT="$OUT/final.png" \
SYNAPSE_TEST_EXIT=1 SYNAPSE_TEST_TIMEOUT="$TIMEOUT" SYNAPSE_TEST_CONFIG_HOME="$OUT/config" SYNAPSE_OBSIDIAN_RUNNING=0 \
  timeout $((TIMEOUT + 60)) "$BIN" > "$OUT/stdout.txt" 2>&1
CODE=$?
set -e
python3 - "$OUT" <<'PY'
import json, os, sys
out = sys.argv[1]
res = None
for line in open(os.path.join(out, 'stdout.txt'), encoding='utf-8', errors='replace'):
    if line.startswith('TEST_RESULT '):
        try:
            res = json.loads(line[len('TEST_RESULT '):])
        except Exception as e:
            res = {'error': 'TEST_RESULT를 읽지 못했어요: %s' % e}
json.dump(res, open(os.path.join(out, 'result.json'), 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
PY
grep -E "^TEST_(ERROR|OPEN)" "$OUT/stdout.txt" || true
echo "run.sh: 종료 코드 $CODE · 결과 $OUT"
ls "$OUT"/*.png 2>/dev/null | sed 's/^/  /' || true
