#!/usr/bin/env python3
"""v0.7 H — apply_changes 하루 상한을 동시 호출에도 지키는지 보는 시험 (python3 표준 라이브러리만).

사용:
  python3 dev/mcp-test/concurrent_cap.py --server <synapse-mcp> --cli <synapse-cli> \
      --fixture-home <홈 템플릿> --fixture-vault <볼트 템플릿> --source <옵시디언 출처 id> --work <빈 시험 폴더> \
      [--procs 3] [--rounds 3] [--files 120] [--cap N] [--delay-ms N] [--expect-fail]

- 템플릿 홈·볼트를 --work 아래로 복제(cp -Rc)하고, sources.json의 출처 경로를 사본 볼트로 바꾼다.
  로컬 출처 경로가 하나라도 --work 밖이면 아무것도 띄우지 않고 멈춘다(사용자 볼트 보호).
- 사본 볼트의 _Inbox·_workspace·루트에 시험용 md(h-cap-*.md)를 만들고 색인한 뒤 mcpDirectApply를 켠다.
- synapse-mcp를 --procs개 띄워 라운드마다 동시에(barrier) apply_changes 20건씩 보낸다. 프로세스마다 맡은 파일이 반쯤 겹친다.
- 확인: 오늘 바로 실행 수(응답·DB·디스크) ≤ 상한, 같은 문서가 두 번 옮겨지지 않음, 넘친 것은 정리함 제안(문서마다 대기 1개 이하),
  옮겨진 문서에 남은 대기 제안 없음.
- --cap은 SYNAPSE_TEST_DIRECT_PER_DAY(시험 홈에서만 읽힌다, 60보다 크게는 못 한다), --delay-ms는 SYNAPSE_TEST_DIRECT_DELAY_MS(셈과 실행 사이 지연).
  v0.6 빌드는 둘 다 모르므로 상한 60으로 돈다.
- macOS 휴지통 대신 SYNAPSE_SYSTEM_TRASH_DIR(--work 아래)를 쓴다. 옵시디언 열림 검사는 SYNAPSE_OBSIDIAN_RUNNING=0으로 끈다.
"""
import argparse, datetime, json, os, sqlite3, subprocess, sys, threading, time

ap = argparse.ArgumentParser()
ap.add_argument("--server", required=True)
ap.add_argument("--cli", required=True)
ap.add_argument("--fixture-home", required=True)
ap.add_argument("--fixture-vault", required=True)
ap.add_argument("--source", required=True)
ap.add_argument("--work", required=True)
ap.add_argument("--procs", type=int, default=3)
ap.add_argument("--rounds", type=int, default=3)
ap.add_argument("--per-call", type=int, default=20)
ap.add_argument("--files", type=int, default=120)
ap.add_argument("--cap", type=int, default=None)
ap.add_argument("--delay-ms", type=int, default=None)
ap.add_argument("--delete-every", type=int, default=10, help="파일 번호가 이 수로 나눠 떨어지면 delete(0이면 move만)")
ap.add_argument("--expect-fail", action="store_true", help="잠금 없는 빌드: 상한을 넘기면 재현 성공으로 본다")
args = ap.parse_args()

WORK = os.path.realpath(args.work)
HOME, VAULT, SYSTRASH = (os.path.join(WORK, n) for n in ("home", "vault", "system-trash"))
REAL_HOME = os.path.realpath(os.path.expanduser("~/Library/Application Support/Synapse"))
if os.path.exists(WORK) and os.listdir(WORK): sys.exit("--work는 비어 있어야 해요: " + WORK)
if WORK.startswith(REAL_HOME) or WORK.startswith(os.path.realpath(os.path.expanduser("~/Desktop"))):
    sys.exit("--work가 사용자 자료 쪽이에요: " + WORK)
os.makedirs(WORK, exist_ok=True)

def sh(*a, env=None, timeout=600):
    r = subprocess.run(list(a), capture_output=True, text=True, env=env, timeout=timeout)
    if r.returncode != 0: sys.exit("실패 %s\n%s\n%s" % (a, r.stdout[-2000:], r.stderr[-2000:]))
    return r.stdout

# 1) 사본 홈·볼트
sh("cp", "-Rc", args.fixture_home, HOME)
sh("cp", "-Rc", args.fixture_vault, VAULT)
sp = os.path.join(HOME, "sources.json")
d = json.load(open(sp, encoding="utf-8"))
arr = d if isinstance(d, list) else d.get("sources", [])
hit = [s for s in arr if s.get("id") == args.source]
if not hit: sys.exit("sources.json에 출처 %s가 없어요" % args.source)
for s in hit: s["path"] = VAULT
json.dump(d, open(sp, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
for s in arr:
    p = s.get("path")
    if p and not os.path.realpath(p).startswith(WORK + "/"):
        sys.exit("사본 밖 로컬 출처가 있어요(멈춤): %s" % p)

# 2) 시험 파일·목적지
DEST = "3-Resources/h-cap-dest"
os.makedirs(os.path.join(VAULT, DEST), exist_ok=True)
old = time.time() - 86400
files = []
for i in range(args.files):
    folder = ("_Inbox", "_workspace", "")[i % 3]
    rel = (folder + "/" if folder else "") + "h-cap-%03d.md" % i
    p = os.path.join(VAULT, rel)
    with open(p, "w", encoding="utf-8") as f:
        f.write("# h-cap %03d\n\n동시 상한 시험용 문서예요.\n" % i)
    os.utime(p, (old, old))
    files.append(rel)

ENV = dict(os.environ, SYNAPSE_HOME=HOME, SYNAPSE_SYSTEM_TRASH_DIR=SYSTRASH, SYNAPSE_OBSIDIAN_RUNNING="0")
for k in list(ENV):
    if k in ("SYNAPSE_TEST_DIRECT_PER_DAY", "SYNAPSE_TEST_DIRECT_DELAY_MS", "SYNAPSE_NOW"): ENV.pop(k)
if args.cap: ENV["SYNAPSE_TEST_DIRECT_PER_DAY"] = str(args.cap)
if args.delay_ms: ENV["SYNAPSE_TEST_DIRECT_DELAY_MS"] = str(args.delay_ms)
CAP = min(args.cap, 60) if args.cap else 60

def cli(*a): return sh(args.cli, "--home", HOME, *a, env=ENV)
print("작업 폴더:", WORK)
cli("reindex", args.source)
cli("brain", "set", "mcpDirectApply", "on")
st = json.loads(cli("brain", "settings"))
print("  mcpDirectApply =", st.get("mcpDirectApply"))

# 3) 서버들
class Server:
    def __init__(self, n):
        self.err = open(os.path.join(WORK, "mcp-%d.stderr" % n), "w")
        self.p = subprocess.Popen([args.server], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.err,
                                  text=True, encoding="utf-8", env=ENV)
        self.n = 0
    def rpc(self, method, params=None):
        self.n += 1
        m = {"jsonrpc": "2.0", "id": self.n, "method": method}
        if params is not None: m["params"] = params
        self.p.stdin.write(json.dumps(m, ensure_ascii=False) + "\n"); self.p.stdin.flush()
        line = self.p.stdout.readline()
        if not line: raise RuntimeError("서버가 응답 없이 끝났어요")
        r = json.loads(line); assert r.get("id") == self.n, r
        return r
    def close(self):
        self.p.stdin.close(); self.p.wait(timeout=30); self.err.close()

servers = [Server(i) for i in range(args.procs)]
for s in servers:
    s.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "claude-code", "version": "1"}})
    s.p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n"); s.p.stdin.flush()

window = args.rounds * args.per_call
step = max(1, (args.files - window) // max(1, args.procs - 1)) if args.procs > 1 else 0
def kind_of(i): return "delete" if args.delete_every and i % args.delete_every == args.delete_every - 1 else "move"
plans = []
for k in range(args.procs):
    idx = [(k * step + j) % args.files for j in range(window)]
    plans.append(idx)

calls = []          # (proc, round, t0, t1, response summary)
lock = threading.Lock()
barrier = threading.Barrier(args.procs)

def worker(k):
    s = servers[k]
    for r in range(args.rounds):
        chunk = plans[k][r * args.per_call:(r + 1) * args.per_call]
        items = []
        for i in chunk:
            it = {"kind": kind_of(i), "path": files[i], "reason": "동시 상한 시험"}
            if it["kind"] == "move": it["to"] = DEST
            items.append(it)
        barrier.wait()
        t0 = time.time()
        resp = s.rpc("tools/call", {"name": "apply_changes", "arguments": {"items": items}})
        t1 = time.time()
        res = resp.get("result", {})
        sc = res.get("structuredContent") or {}
        rec = {"proc": k, "round": r, "t0": t0, "t1": t1, "isError": bool(res.get("isError")),
               "text": (res.get("content") or [{}])[0].get("text", "")[:300],
               "limit": sc.get("limit"), "note": sc.get("note"),
               "results": [dict(x, file=files[chunk[x["index"]]]) for x in sc.get("results", []) if isinstance(x.get("index"), int)]}
        with lock: calls.append(rec)

ths = [threading.Thread(target=worker, args=(k,)) for k in range(args.procs)]
T0 = time.time()
for t in ths: t.start()
for t in ths: t.join()
elapsed = time.time() - T0
for s in servers: s.close()

# 4) 확인
from collections import Counter
status = Counter(); per_file = Counter(); proposed_files = set(); done_files = set()
for c in calls:
    for x in c["results"]:
        status[x["status"]] += 1
        if x["status"] in ("moved", "trashed"): per_file[x["file"]] += 1; done_files.add(x["file"])
        if x["status"] == "proposed": proposed_files.add(x["file"])
busy = [c for c in calls if c["isError"]]
done_resp = status["moved"] + status["trashed"]
dup = {f: n for f, n in per_file.items() if n > 1}

# 디스크
on_dest = sum(1 for f in files if os.path.exists(os.path.join(VAULT, DEST, os.path.basename(f))))
at_orig = sum(1 for f in files if os.path.exists(os.path.join(VAULT, f)))
both = sum(1 for f in files if os.path.exists(os.path.join(VAULT, f)) and os.path.exists(os.path.join(VAULT, DEST, os.path.basename(f))))
trash_root = os.path.join(HOME, "trash")
in_trash = 0
for root, _, names in os.walk(trash_root):
    in_trash += sum(1 for n in names if n.startswith("h-cap-"))

# DB (읽기 전용)
start = datetime.datetime.now().replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
db = sqlite3.connect("file:%s?mode=ro" % os.path.join(HOME, "brain.sqlite"), uri=True)
q = lambda sql, *p: db.execute(sql, p).fetchall()
db_moves = q("SELECT count(*) FROM suggestions WHERE rule_key='direct' AND origin LIKE 'mcp:%' AND state='applied' AND decided>=?", start)[0][0]
db_trash = q("SELECT count(*) FROM trash_items WHERE via='direct' AND deleted>=? AND state<>'cancelled'", start)[0][0]
pend = q("SELECT doc_id, count(*) FROM suggestions WHERE kind IN ('move','delete') AND state='pending' AND doc_id LIKE ? GROUP BY doc_id", "%h-cap-%")
pend_multi = [r for r in pend if r[1] > 1]
src = args.source + ":"
done_ids = {src + f for f in done_files}
pend_on_done = [r for r in pend if r[0] in done_ids]
db.close()

summary = {
    "build": args.server, "procs": args.procs, "rounds": args.rounds, "cap": CAP, "delayMs": args.delay_ms, "elapsedSec": round(elapsed, 1),
    "responses": dict(status), "doneByResponses": done_resp, "busyCalls": len(busy),
    "db": {"directMoves": db_moves, "directTrash": db_trash, "total": db_moves + db_trash,
           "pendingProposals": len(pend), "docsWith2+Pending": len(pend_multi), "pendingOnDoneDocs": len(pend_on_done)},
    "disk": {"atDest": on_dest, "atOriginal": at_orig, "inBothPlaces": both, "inSynapseTrash": in_trash},
    "duplicates": dup,
    "calls": [{"proc": c["proc"], "round": c["round"], "start": round(c["t0"] - T0, 2), "sec": round(c["t1"] - c["t0"], 2),
               "isError": c["isError"], "limit": c["limit"],
               "counts": dict(Counter(x["status"] for x in c["results"])),
               "note": (c["note"] or "")[-60:] if not c["isError"] else c["text"][:120]} for c in sorted(calls, key=lambda c: c["t0"])],
}
json.dump(summary, open(os.path.join(WORK, "summary.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=2)
print(json.dumps({k: v for k, v in summary.items() if k != "calls"}, ensure_ascii=False, indent=1))
for c in summary["calls"]: print("  call", json.dumps(c, ensure_ascii=False))

checks = [
    ("응답 기준 오늘 바로 실행 ≤ 상한", done_resp <= CAP, done_resp),
    ("DB 기준 오늘 바로 실행 ≤ 상한", db_moves + db_trash <= CAP, db_moves + db_trash),
    ("디스크 기준(목적지+휴지통) ≤ 상한", on_dest + in_trash <= CAP, on_dest + in_trash),
    ("응답·DB·디스크 수가 같음", done_resp == db_moves + db_trash == on_dest + in_trash, (done_resp, db_moves + db_trash, on_dest + in_trash)),
    ("같은 문서가 두 번 옮겨지지 않음", not dup and both == 0, (dup, both)),
    ("넘친 것은 정리함 제안(문서마다 대기 1개 이하)", status["proposed"] > 0 and not pend_multi, (status["proposed"], pend_multi[:3])),
    ("옮긴·지운 문서에 남은 대기 제안 없음", not pend_on_done, pend_on_done[:3]),
    ("시험 파일 수 보존(원래+목적지+휴지통 = 전체)", at_orig + on_dest + in_trash == args.files, (at_orig, on_dest, in_trash)),
]
bad = 0
for name, ok, detail in checks:
    print(("  ok   " if ok else "  FAIL ") + name + ("" if ok else " :: " + str(detail)))
    bad += 0 if ok else 1
if args.expect_fail:
    over = done_resp > CAP or db_moves + db_trash > CAP
    print("잠금 없는 빌드: 상한 넘김 %s (응답 %d, DB %d, 상한 %d)" % ("재현됨" if over else "재현 안 됨", done_resp, db_moves + db_trash, CAP))
    sys.exit(0)
print("결과: %s (%d개 실패)" % ("통과" if bad == 0 else "실패", bad))
sys.exit(1 if bad else 0)
