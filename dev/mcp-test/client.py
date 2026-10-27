#!/usr/bin/env python3
"""synapse-mcp 시험 클라이언트 (python3 표준 라이브러리만).

사용:  python3 dev/mcp-test/client.py --server <synapse-mcp> --cli <synapse-cli> [--work <임시 폴더>]
- 임시 home에 dev/fixtures 두 자료와 '복사본 폴더'를 synapse-cli로 색인한 뒤 서버를 띄워 모든 도구를 확인한다.
- 사용자의 실제 Synapse 자료(~/Library/Application Support/Synapse)와 Claude·Codex 설정은 건드리지 않는다.
"""
import argparse, json, os, shutil, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ap = argparse.ArgumentParser()
ap.add_argument("--server", default=os.path.join(ROOT, "build", "synapse-mcp"))
ap.add_argument("--cli", default=os.path.join(ROOT, "build", "synapse-cli"))
ap.add_argument("--work", default=None)
args = ap.parse_args()
WORK = args.work or tempfile.mkdtemp(prefix="synapse-mcp-test-")
HOME = os.path.join(WORK, "home")
COPY = os.path.join(WORK, "복사본")
passed = failed = 0

def check(cond, name, detail=""):
    global passed, failed
    if cond: passed += 1; print("  ok   " + name)
    else: failed += 1; print("  FAIL " + name + (" :: " + str(detail)[:300] if detail else ""))

def cli(*a):
    env = dict(os.environ, SYNAPSE_CLI_MEMORY_SECRETS="1")
    r = subprocess.run([args.cli, "--home", HOME, *a], capture_output=True, text=True, env=env, timeout=180)
    if r.returncode != 0: raise SystemExit("cli 실패 %s: %s" % (a, r.stderr))
    return r.stdout

class Server:
    def __init__(self, home, env_extra=None):
        env = dict(os.environ, SYNAPSE_HOME=home); env.update(env_extra or {})
        self.p = subprocess.Popen([args.server], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  text=True, encoding="utf-8", env=env)
        self.n = 0
    def raw(self, line):
        self.p.stdin.write(line + "\n"); self.p.stdin.flush()
        return json.loads(self.p.stdout.readline())
    def send(self, obj): self.p.stdin.write(json.dumps(obj, ensure_ascii=False) + "\n"); self.p.stdin.flush()
    def rpc(self, method, params=None):
        self.n += 1
        m = {"jsonrpc": "2.0", "id": self.n, "method": method}
        if params is not None: m["params"] = params
        self.send(m)
        r = json.loads(self.p.stdout.readline())
        assert r.get("id") == self.n, r
        return r
    def call(self, name, **a): return self.rpc("tools/call", {"name": name, "arguments": a})
    def close(self):
        self.p.stdin.close(); self.p.wait(timeout=10); return self.p.stderr.read()

def result(r): return r["result"]
def sc(r): return r["result"]["structuredContent"]
def text(r): return r["result"]["content"][0]["text"]

print("작업 폴더:", WORK)
app = subprocess.run(["pgrep", "-x", "Synapse"], capture_output=True).returncode == 0
print("  (Synapse 앱 %s — 서버는 앱과 무관하게 디스크 색인만 읽는다)" % ("실행 중" if app else "꺼짐"))
shutil.rmtree(HOME, ignore_errors=True); shutil.rmtree(COPY, ignore_errors=True)
shutil.copytree(os.path.join(ROOT, "dev/fixtures/업무문서"), COPY, ignore=shutil.ignore_patterns("형식"))
cli("add-folder", os.path.join(ROOT, "dev/fixtures/테스트볼트"), "--obsidian")
cli("add-folder", os.path.join(ROOT, "dev/fixtures/업무문서"))
cli("add-folder", COPY)
cli("index")

print("[lifecycle]")
s = Server(HOME)
r = s.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "1"}})
res = result(r)
check(r["jsonrpc"] == "2.0" and res["protocolVersion"] == "2025-06-18", "initialize 2025-06-18")
check(res["serverInfo"]["name"] == "synapse" and res["serverInfo"]["version"] == "0.9.0", "serverInfo")
check(res["capabilities"] == {"tools": {"listChanged": False}}, "capabilities", res["capabilities"])
check("search_notes" in res["instructions"] and "Synapse" in res["instructions"] and "노트" in res["instructions"], "instructions ko+en")
for v in ("2025-03-26", "2024-11-05"):
    t = Server(HOME); check(result(t.rpc("initialize", {"protocolVersion": v}))["protocolVersion"] == v, "버전 협상 " + v); t.close()
t = Server(HOME); check(result(t.rpc("initialize", {"protocolVersion": "1999-01-01"}))["protocolVersion"] == "2025-06-18", "알 수 없는 버전은 2025-06-18"); t.close()
s.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
check(result(s.rpc("ping")) == {}, "ping")

print("[tools/list]")
tools = result(s.rpc("tools/list"))["tools"]
OLD5 = ["search_notes", "get_note", "related_notes", "recent_notes", "list_sources"]
NEW5 = ["get_work_context", "get_vault_policy", "list_pending", "suggest_location", "propose_changes"]
# v0.6 apply_changes, v0.8 get_tickets·propose_jira_changes
ALL = OLD5 + ["get_work_context", "get_tickets", "get_vault_policy", "list_pending", "suggest_location",
              "propose_changes", "propose_jira_changes", "apply_changes"]
check([t["name"] for t in tools] == ALL, "도구 13개(기존 5 + 사서·Jira 8)", [t["name"] for t in tools])
for t in tools:
    sch = t["inputSchema"]; ann = t["annotations"]
    write = t["name"] in ("propose_changes", "propose_jira_changes", "apply_changes")
    check(sch["type"] == "object" and "properties" in sch and ann["readOnlyHint"] is (not write)
          and ann["destructiveHint"] is (t["name"] == "apply_changes")
          and ann["openWorldHint"] is False and "\n" in t["description"], "스키마·annotations " + t["name"], ann)
req = {t["name"]: t["inputSchema"]["required"] for t in tools}
check(req["search_notes"] == ["query"] and req["get_note"] == ["id"] and req["related_notes"] == ["id"], "required", req)
check(req["suggest_location"] == ["title"] and req["propose_changes"] == ["items"] and req["get_work_context"] == [], "사서 도구 required", req)
props = {t["name"]: t["inputSchema"]["properties"] for t in tools}
check(props["propose_changes"]["items"]["maxItems"] == 20 and props["suggest_location"]["content_head"]["maxLength"] == 2000
      and props["get_work_context"]["period"]["enum"] == ["now", "week"], "사서 도구 입력 스키마", props["propose_changes"])

print("[search_notes]")
r = s.call("search_notes", query="정산을", limit=5)
check(result(r)["isError"] is False, "isError false")
d = sc(r)
check(d["count"] >= 2 and d["count"] <= 5 and d["query"] == "정산을", "결과 수", d["count"])
first = d["results"][0]
check(first["origin"] == "local" and all(x["origin"] == "local" for x in d["results"]), "결과마다 origin(local)", first.get("origin"))
check(all(k in first for k in ("id", "title", "path", "source", "modified", "reason", "snippet")), "결과 필드", first.keys())
check("정산" in " ".join(x["title"] for x in d["results"]), "정산 문서 포함")
check(first["id"] in text(r) and "정산" in text(r), "markdown에 id 포함")
check(sc(s.call("search_notes", query="ㅈㅅ"))["count"] >= 1, "초성 검색")
check(sc(s.call("search_notes", query="zzqqxx없는말"))["count"] == 0, "결과 없음")
check(len(sc(s.call("search_notes", query="정산", limit=1))["results"]) == 1, "limit=1")
check(len(sc(s.call("search_notes", query="정산", limit=999))["results"]) <= 30, "limit 상한")
for lim in (1e20, -1e20, 1e308, "10", None, "1e999", 2.5):
    r = s.call("search_notes", query="정산", limit=lim)
    check("result" in r and result(r)["isError"] is False and 1 <= sc(r)["count"] <= 30, "limit=%r 에도 서버 생존" % (lim,), r)
for raw in ('{"jsonrpc":"2.0","id":901,"method":"tools/call","params":{"name":"search_notes","arguments":{"query":"정산","limit":Infinity}}}',
            '{"jsonrpc":"2.0","id":902,"method":"tools/call","params":{"name":"search_notes","arguments":{"query":"정산","limit":NaN}}}',
            '{"jsonrpc":"2.0","id":903,"method":"tools/call","params":{"name":"related_notes","arguments":{"id":"x","depth":1e300,"limit":-1e300}}}'):
    s.p.stdin.write(raw + "\n"); s.p.stdin.flush(); json.loads(s.p.stdout.readline())
check(s.p.poll() is None and result(s.rpc("ping")) == {}, "Infinity/NaN/1e300 뒤에도 서버 정상")
check(result(s.call("search_notes", query="  "))["isError"] is True, "빈 query는 isError")
check(result(s.call("search_notes"))["isError"] is True, "query 누락은 isError")
nid = first["id"]

print("[get_note]")
r = s.call("get_note", id=nid); n = sc(r)
check(n["id"] == nid and n["title"] and n["path"] and n["source"] and len(n["text"]) > 10, "본문", n.keys())
check(isinstance(n["truncated"], bool) and "links" in n and isinstance(n["links"], dict), "links·truncated")
check(nid in text(r) and n["title"] in text(r), "markdown")
check(any(len(v) for v in n["links"].values()), "연결 있음", n["links"].keys())
check(n.get("location", "").startswith("/"), "원본 위치")

print("[related_notes]")
r1 = sc(s.call("related_notes", id=nid)); r2 = sc(s.call("related_notes", id=nid, depth=2, limit=30))
check(r1["center"]["id"] == nid and r1["depth"] == 1 and r1["count"] >= 1, "depth 1", r1["count"])
check(r2["depth"] == 2 and r2["count"] >= r1["count"], "depth 2", (r1["count"], r2["count"]))
check("two" in [x["key"] for x in r2["sections"]], "두 단계 섹션", [x["key"] for x in r2["sections"]])
check(sc(s.call("related_notes", id=nid, limit=2))["count"] <= 2, "limit=2")

print("[recent / sources]")
rc = sc(s.call("recent_notes", limit=3))
mods = [x["modified"] for x in rc["results"]]
check(rc["count"] == 3 and mods == sorted(mods, reverse=True), "recent_notes 최신순", mods)
check(sc(s.call("recent_notes"))["count"] >= 10, "recent 기본 20")
ls = sc(s.call("list_sources"))
check(len(ls["sources"]) == 3 and ls["docCount"] >= 16 and all(x["state"] for x in ls["sources"]), "list_sources", ls["docCount"])

print("[오류]")
r = s.call("get_note", id="없는:id")
check(result(r)["isError"] is True and "찾지" in text(r), "잘못된 id → isError", r)
check(result(s.call("related_notes", id="없는:id"))["isError"] is True, "related 잘못된 id")
check(result(s.call("get_note"))["isError"] is True, "id 누락 → isError")
r = s.call("no_such_tool"); check(r["error"]["code"] == -32602, "알 수 없는 도구 -32602", r)
r = s.rpc("tools/call", {"arguments": {}}); check(r["error"]["code"] == -32602, "name 누락 -32602", r)
r = s.rpc("tools/call", {"name": "get_note", "arguments": [1]}); check(r["error"]["code"] == -32602, "arguments 배열 -32602", r)
r = s.rpc("nope/method"); check(r["error"]["code"] == -32601, "알 수 없는 메서드 -32601", r)
r = s.raw("{이건 JSON이 아님"); check(r["error"]["code"] == -32700 and r["id"] is None, "깨진 JSON -32700", r)
r = s.raw("[1,2]"); check(isinstance(r, list) and r[0]["error"]["code"] == -32600, "배치 안의 잘못된 요청", r)
r = s.raw('"문자열"'); check(r["error"]["code"] == -32600, "객체가 아닌 요청 -32600", r)
check(result(s.rpc("ping")) == {}, "오류 뒤에도 서버 정상")

print("[재시작 없이 색인 변경 반영]")
check(sc(s.call("search_notes", query="유니콘고래"))["count"] == 0, "변경 전엔 없음")
with open(os.path.join(COPY, "새 메모.md"), "w", encoding="utf-8") as f:
    f.write("# 유니콘고래 프로젝트\n\n정산 대시보드와 이어지는 새 메모. 유니콘고래 일정 정리.\n")
cli("index")
d = sc(s.call("search_notes", query="유니콘고래"))
check(d["count"] >= 1 and "새 메모" in d["results"][0]["id"], "새 문서가 같은 서버에서 검색됨", d["count"])
note_id = d["results"][0]["id"]
with open(os.path.join(COPY, "새 메모.md"), "a", encoding="utf-8") as f: f.write("\n추가된 문장: 해달무지개.\n")
time.sleep(1.1); os.utime(os.path.join(COPY, "새 메모.md"), None)
cli("index")
check("해달무지개" in sc(s.call("get_note", id=note_id))["text"], "수정한 본문이 반영됨")
check(sc(s.call("list_sources"))["docCount"] >= ls["docCount"] + 1, "list_sources 문서 수 증가")
err = s.close()
check("[synapse-mcp]" in err and "{" not in err.split("\n")[0], "로그는 stderr로만")

print("[색인 없음]")
empty = os.path.join(WORK, "없는홈")
shutil.rmtree(empty, ignore_errors=True)
t = Server(empty); t.rpc("initialize", {"protocolVersion": "2025-06-18"})
for name, a in (("search_notes", {"query": "정산"}), ("get_note", {"id": "x"}), ("recent_notes", {}), ("list_sources", {})):
    r = t.call(name, **a)
    check(result(r)["isError"] is False and "연결된 자료가 아직 없어요" in text(r) and "No sources" in text(r), "friendly " + name, r)
t.close()
check(not os.path.exists(empty), "읽기 전용: 없는 home을 만들지 않음")
os.makedirs(empty)
t = Server(empty); t.rpc("initialize", {}); check("아직 없어요" in text(t.call("recent_notes")), "빈 폴더도 friendly"); t.close()
check(os.listdir(empty) == [], "읽기 전용: 빈 home에 아무것도 쓰지 않음", os.listdir(empty))


def scan_keys(o, bad, path=""):
    """응답 안에 세션 기록 필드가 남았는지 재귀로 찾는다."""
    found = []
    if isinstance(o, dict):
        for k, v in o.items():
            if k in bad or (k == "lastAsk" and isinstance(v, dict) and ("text" in v or "title" in v)): found.append(path + "/" + k)
            found += scan_keys(v, bad, path + "/" + k)
    elif isinstance(o, list):
        for i, v in enumerate(o): found += scan_keys(v, bad, path + "/%d" % i)
    return found
SESSION_KEYS = {"firstAsk", "first_ask", "lastAskText", "last_ask", "requestText", "sessionTitle", "session_title", "firstRequest"}

def init(srv, name):
    return result(srv.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": name, "version": "1"}}))

print("[사서 도구 — brain.sqlite 없음]")
check(not os.path.exists(os.path.join(HOME, "brain.sqlite")), "사전 조건: brain.sqlite 없음")
nb = Server(HOME); init(nb, "claude-code")
r = nb.call("get_work_context")
check(result(r)["isError"] is False and sc(r)["updatedAt"] is None and "Synapse 앱을 한 번 열어 주세요" in sc(r)["note"], "get_work_context: 앱을 열어 달라는 안내", r)
for name, a in (("get_vault_policy", {}), ("list_pending", {}), ("suggest_location", {"title": "x"}), ("propose_changes", {"items": [{"kind": "withdraw", "id": "s:1"}]})):
    r = nb.call(name, **a)
    check(result(r)["isError"] is False and "앱을 한 번 열어 주세요" in text(r), "brain 없음 안내 " + name, r)
nb.close()
check(not os.path.exists(os.path.join(HOME, "brain.sqlite")), "읽기 전용: MCP가 brain.sqlite를 만들지 않음")

cli("brain", "settings")     # 앱 대신 CLI가 사서 저장소를 만든다
check(os.path.exists(os.path.join(HOME, "brain.sqlite")), "cli brain settings → brain.sqlite 생성")

print("[사서 도구]")
b = Server(HOME); init(b, "claude-code")
r = b.call("get_work_context"); wc = sc(r)
check(result(r)["isError"] is False and "updatedAt" in wc, "get_work_context now", r)
if wc["updatedAt"] is None:
    check("note" in wc, "작업 맥락 비어 있으면 note")
else:
    check(all(k in wc for k in ("threads", "openTasks")) and len(wc["threads"]) <= 10 and len(wc["openTasks"]) <= 30, "get_work_context 구조")
    for t in wc["threads"]:
        if t.get("primaryDoc"): check(t["primaryDoc"].get("origin") in ("local", "confluence", "jira"), "primaryDoc origin", t["primaryDoc"])
    for t in wc["openTasks"]:
        if t.get("doc"): check(t["doc"].get("origin") in ("local", "confluence", "jira"), "openTasks doc origin", t["doc"])
wk = sc(b.call("get_work_context", period="week"))
def remote_leaks(o):
    """원격(jira/confluence) 항목에 본문 파생 키가 남았는지."""
    bad = []
    if isinstance(o, dict):
        remote = o.get("origin") in ("jira", "confluence") or (o.get("primaryDoc") or {}).get("origin") in ("jira", "confluence")
        if remote: bad += [k for k in ("summary", "summarySource", "reason", "reasons", "chips", "snippet", "excerpt") if k in o]
        for v in o.values(): bad += remote_leaks(v)
    elif isinstance(o, list):
        for v in o: bad += remote_leaks(v)
    return bad
check(remote_leaks([wc, wk]) == [], "원격 항목에 요약·이유·칩 없음 (remoteBodies 꺼짐)", remote_leaks([wc, wk]))
check("updatedAt" in wk, "get_work_context week")
vp = b.call("get_vault_policy"); vps = sc(vp)
check(result(vp)["isError"] is False and all(k in vps for k in ("approved", "rules", "frozen", "exclude", "landing", "folders", "violations")), "get_vault_policy 구조", list(vps))
lp = b.call("list_pending"); lps = sc(lp)
check(result(lp)["isError"] is False and "unsorted" in lps and "proposals" in lps and len(lps["unsorted"]) <= 50, "list_pending 구조", list(lps))
for u in lps["unsorted"]: check(u.get("origin") in ("local", "confluence", "jira"), "unsorted origin", u)
sl = b.call("suggest_location", title="결제 재시도 설계", type="가이드", project="결제", content_head="가" * 5000)
check(result(sl)["isError"] is False and "suggestions" in sc(sl) and "policyApproved" in sc(sl), "suggest_location 구조", sc(sl) if "structuredContent" in result(sl) else sl)
check(result(b.call("suggest_location"))["isError"] is True and result(b.call("suggest_location", title="  "))["isError"] is True, "title 누락·공백 → isError")
check(result(b.call("propose_changes"))["isError"] is True and result(b.call("propose_changes", items=[]))["isError"] is True, "items 누락·빈 배열 → isError")
check(result(b.call("propose_changes", items=[{"kind": "withdraw", "id": "s:%d" % i} for i in range(21)]))["isError"] is True, "21개는 isError")
check(result(b.call("propose_changes", items=[{"path": "a.md"}]))["isError"] is True and result(b.call("propose_changes", items=["x"]))["isError"] is True, "kind 없는 항목 → isError")
pc = b.call("propose_changes", items=[{"kind": "withdraw", "id": "s:없음"}])
check(result(pc)["isError"] is False and isinstance(sc(pc)["accepted"], list) and isinstance(sc(pc)["rejected"], list) and "승인" in sc(pc)["note"], "propose_changes 결과 구조", pc)
every = [wc, wk, vps, lps, sc(sl), sc(pc)]
check(scan_keys(every, SESSION_KEYS) == [], "응답에 세션 기록 필드 없음", scan_keys(every, SESSION_KEYS))
b.close()

print("[원격 문서 — origin · 본문 숨김]")
import socket, urllib.request
def free_port():
    with socket.socket() as so: so.bind(("127.0.0.1", 0)); return so.getsockname()[1]
port = free_port()
mock = subprocess.Popen([sys.executable, "-I", os.path.join(ROOT, "dev/atlassian-mock/server.py"), str(port)], stderr=subprocess.DEVNULL)
try:
    for _ in range(50):
        try: urllib.request.urlopen("http://127.0.0.1:%d/__stats" % port, timeout=1).read(); break
        except Exception: time.sleep(0.1)
    HOME2 = HOME + "-remote"
    shutil.rmtree(HOME2, ignore_errors=True)
    def cli2(*a):
        r = subprocess.run([args.cli, "--home", HOME2, *a], capture_output=True, text=True, env=dict(os.environ, SYNAPSE_CLI_MEMORY_SECRETS="1"), timeout=180)
        if r.returncode != 0: raise SystemExit("cli 실패 %s: %s" % (a, r.stderr))
        return r.stdout
    cli2("add-folder", os.path.join(ROOT, "dev/fixtures/업무문서"))
    cli2("add-atlassian", "http://127.0.0.1:%d" % port, "a@b.c", "test-token")
    import sqlite3
    con = sqlite3.connect("file:%s?mode=ro" % os.path.join(HOME2, "index.sqlite"), uri=True)
    metas = {r[0].rsplit(":", 1)[-1]: json.loads(r[1]) for r in con.execute("SELECT id, meta FROM docs WHERE id LIKE '%:jira:%'")}
    con.close()
    check(set(metas) == {"PAY-142", "PAY-150", "PAY-100", "PAY-120"}, "Jira meta가 색인에 저장됨", list(metas))
    check(metas["PAY-142"] == {"assignee": "mock-1", "assigneeName": "김철수", "duedate": "2026-10-30", "issuetype": "작업", "mine": "1", "priority": "High",
                               "status": "진행 중", "statusCategory": "indeterminate", "statusChanged": "2026-10-12T00:30:00Z",
                               "updated": "2026-10-20T00:15:42Z"}, "PAY-142 meta (내 이슈)", metas["PAY-142"])
    check(metas["PAY-150"]["mine"] == "0" and metas["PAY-150"]["priority"] == "Highest" and "duedate" not in metas["PAY-150"], "PAY-150 meta (남의 이슈)", metas["PAY-150"])
    check(metas["PAY-100"]["mine"] == "0" and "assignee" not in metas["PAY-100"], "PAY-100 meta (담당자 없음)", metas["PAY-100"])
    check(metas["PAY-120"]["statusCategory"] == "done" and metas["PAY-120"]["mine"] == "1", "PAY-120 meta (완료)", metas["PAY-120"])
    stats = json.loads(urllib.request.urlopen("http://127.0.0.1:%d/__stats" % port, timeout=5).read())
    check(stats["counts"].get("myself") == 2, "/myself는 연결 확인 1번 + 동기화 1번", stats["counts"])
    # 내 계정 조회(/myself)가 실패한 동기화: mine 키를 넣지 않는다(0으로 두지 않는다). 나머지 meta는 그대로.
    port3 = free_port()
    mock3 = subprocess.Popen([sys.executable, "-I", os.path.join(ROOT, "dev/atlassian-mock/server.py"), str(port3)],
                             stderr=subprocess.DEVNULL, env=dict(os.environ, MOCK_MYSELF_FAIL_AFTER="1"))
    try:
        for _ in range(50):
            try: urllib.request.urlopen("http://127.0.0.1:%d/__stats" % port3, timeout=1).read(); break
            except Exception: time.sleep(0.1)
        HOME3 = HOME + "-nomyself"
        shutil.rmtree(HOME3, ignore_errors=True)
        r = subprocess.run([args.cli, "--home", HOME3, "add-atlassian", "http://127.0.0.1:%d" % port3, "a@b.c", "test-token"],
                           capture_output=True, text=True, env=dict(os.environ, SYNAPSE_CLI_MEMORY_SECRETS="1"), timeout=180)
        check(r.returncode == 0, "/myself 실패 흉내에도 연결·동기화 성공", r.stderr)
        con = sqlite3.connect("file:%s?mode=ro" % os.path.join(HOME3, "index.sqlite"), uri=True)
        m3 = {r_[0].rsplit(":", 1)[-1]: json.loads(r_[1]) for r_ in con.execute("SELECT id, meta FROM docs WHERE id LIKE '%:jira:%'")}
        con.close()
        check(len(m3) == 4 and all("mine" not in m for m in m3.values()), "내 id를 모르면 mine 키 없음", {k: v.get("mine") for k, v in m3.items()})
        check(all("priority" in m and "status" in m for m in m3.values()) and m3["PAY-142"]["assignee"] == "mock-1", "나머지 meta는 그대로", m3["PAY-142"])
    finally:
        mock3.terminate(); mock3.wait(timeout=5)
    rs = Server(HOME2); init(rs, "codex-mcp-client")
    d = sc(rs.call("search_notes", query="정산", limit=30))
    kinds = {x["origin"] for x in d["results"]}
    check("jira" in kinds or "confluence" in kinds, "원격 문서 origin(jira/confluence)", kinds)
    check(all(x["origin"] == "local" for x in d["results"] if x["sourceKind"] in ("folder", "obsidian")), "로컬 문서는 origin local")
    check(all("snippet" not in x for x in d["results"] if x["origin"] != "local"), "원격 발췌(snippet) 숨김 (brain 없음 = 기본 꺼짐)")
    remote = [x for x in d["results"] if x["origin"] != "local"]
    check(all("허용하면 보여요" in x.get("bodyNotice", "") for x in remote if True) and len(remote) >= 1, "원격 결과에 안내 문구", remote[:1])
    jira_id = next(x["id"] for x in sc(rs.call("search_notes", query="PAY-142", limit=10))["results"] if x["origin"] == "jira")
    n = sc(rs.call("get_note", id=jira_id))
    check(n["origin"] == "jira" and "허용하면 보여요" in n["text"] and n.get("bodyHidden") is True and "지연 건수" not in n["text"], "get_note 원격 본문 숨김", n["text"][:80])
    check("지연 건수" not in json.dumps(sc(rs.call("recent_notes", limit=50)), ensure_ascii=False), "recent_notes에도 원격 본문 없음")
    rel = sc(rs.call("related_notes", id=jira_id, depth=2, limit=50))
    allitems = [i for sec in rel["sections"] for i in sec["items"]]
    check(all("origin" in i for i in allitems) and all("snippet" not in i for i in allitems if i["origin"] != "local"), "related_notes origin·발췌 숨김", allitems[:1])
    local_note = sc(rs.call("get_note", id=next(x["id"] for x in sc(rs.call("search_notes", query="정산 대시보드"))["results"] if x["origin"] == "local")))
    check(local_note["origin"] == "local" and len(local_note["text"]) > 10 and "허용하면" not in local_note["text"], "로컬 본문은 그대로")
    cli2("brain", "set", "mcp.remoteBodies", "1")
    n2 = sc(rs.call("get_note", id=jira_id))
    check("지연 건수" in n2["text"] and not n2.get("bodyHidden"), "mcp.remoteBodies=1 → 같은 서버에서 본문 보임", n2["text"][:80])
    d2 = sc(rs.call("search_notes", query="정산", limit=30))
    check(any("snippet" in x for x in d2["results"] if x["origin"] != "local") or all("bodyNotice" not in x for x in d2["results"]), "허용하면 발췌도 보임")
    cli2("brain", "set", "mcp.remoteBodies", "0")
    check("허용하면 보여요" in sc(rs.call("get_note", id=jira_id))["text"], "다시 끄면 즉시 숨김")
    rs.close()
finally:
    mock.terminate(); mock.wait(timeout=5)

print("\n%d 통과, %d 실패" % (passed, failed))
sys.exit(1 if failed else 0)
