#!/usr/bin/env python3
"""Atlassian Cloud 모의 서버 (Synapse 연결기 시험용). 표준 라이브러리만 쓴다.

    python3 server.py [port]        # 기본 8765, 127.0.0.1에만 바인딩

- 인증: Basic, 비밀번호(토큰)가 "test-token"이 아니면 401.
- GET  /rest/api/3/myself
- GET  /wiki/rest/api/content/search   (한 쪽에 2건, 3쪽, _links.next, lastmodified 조건만 해석)
- POST /rest/api/3/search/jql          (한 쪽에 2건, nextPageToken, updated 조건만 해석)
- 첫 Jira 요청은 429 + Retry-After: 1 (서버 실행당 한 번, POST /__reset으로 되돌림)
- GET  /__stats  요청 수·429 발급 여부 (인증 없음)
- 환경변수 MOCK_NO_CONFLUENCE=1이면 Confluence 요청에 404 (Jira만 있는 사이트)
- 환경변수 MOCK_MYSELF_FAIL_AFTER=N이면 /myself가 N번 성공한 뒤부터 500 (내 accountId를 못 알아내는 동기화 흉내)
- 날짜 조건의 "yyyy-MM-dd HH:mm"은 +09:00 시각으로 해석한다.
v0.8 Jira 쓰기 (Synapse JiraWriter REST 시험용)
- GET  /rest/api/3/issue/{key}[?fields=status]   GET /rest/api/3/issue/{key}/comment
- GET/POST /rest/api/3/issue/{key}/transitions   (흐름: To Do→할 일 · In Progress→진행 중 · 완료하기→완료 · Hold→On Hold, 지금 상태로 가는 전환은 뺀다)
- POST /rest/api/3/issue/{key}/comment   (본문은 문단 ADF여야 한다 — 빈 text 노드·모르는 노드는 400)
- GET  /rest/api/3/issue/createmeta/{project}/issuetypes   (Task·Bug·Epic·Sub-task)   POST /rest/api/3/issue
- POST /__config {write_fail: "401"|"403"|"400"|"500"|"drop"|"500_after"|"drop_after"|null, write_delay: 초}
- GET  /__jira  이슈 상태·댓글·쓰기 기록.   POST /__reset은 이슈·설정도 처음으로 되돌린다.
"""
import base64, json, os, re, sys, threading, time
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit, urlencode

HERE = os.path.dirname(os.path.abspath(__file__))
KST = timezone(timedelta(hours=9))
TOKEN = "test-token"
PAGE = 2

def load(name):
    with open(os.path.join(HERE, "fixtures", name), encoding="utf-8") as f:
        return json.load(f)

MYSELF = load("myself.json")
PAGES = load("confluence_pages.json")
ISSUES = load("jira_issues.json")
STATE = {"throttled": False, "counts": {}, "cfg": {"write_fail": None, "write_delay": 0}, "writes": [], "seq": 0}
LOCK = threading.RLock()     # v0.8: 쓰기 처리 중에도 count()가 같은 잠금을 다시 잡는다

# v0.8 Jira 쓰기 흉내
TRANSITIONS = [("11", "To Do", "할 일", "new"), ("21", "In Progress", "진행 중", "indeterminate"),
               ("31", "완료하기", "완료", "done"), ("41", "Hold", "On Hold", "done")]
ISSUE_TYPES = [{"id": "10001", "name": "Task", "subtask": False}, {"id": "10002", "name": "Bug", "subtask": False},
               {"id": "10003", "name": "Epic", "subtask": False}, {"id": "10004", "name": "Sub-task", "subtask": True}]

def now_kst():
    return datetime.now(KST).strftime("%Y-%m-%dT%H:%M:%S.000+0900")

def find_issue(k):
    return next((i for i in ISSUES if i["key"] == k or i["id"] == k), None)

def available(issue):
    cur = issue["fields"]["status"]["name"]
    return [t for t in TRANSITIONS if t[2] != cur]

def valid_adf(doc):
    if not isinstance(doc, dict) or doc.get("type") != "doc" or doc.get("version") != 1:
        return False
    content = doc.get("content")
    if not isinstance(content, list) or not content:
        return False
    for para in content:
        if not isinstance(para, dict) or para.get("type") != "paragraph" or not para.get("content"):
            return False
        for k in para["content"]:
            if k.get("type") == "text":
                if not isinstance(k.get("text"), str) or k["text"] == "":
                    return False
            elif k.get("type") != "hardBreak":
                return False
    return True

def adf_text(doc):
    out = []
    for para in doc.get("content", []):
        out.append("".join(k.get("text", "") if k.get("type") == "text" else "\n" for k in para.get("content", [])))
    return "\n\n".join(out)

def parse_iso(s):
    s = re.sub(r"([+-]\d\d)(\d\d)$", r"\1:\2", s.replace("Z", "+00:00"))
    return datetime.fromisoformat(s)

def stamp_from(expr):
    m = re.search(r'(?:lastmodified|updated)\s*>=\s*"(\d{4}-\d\d-\d\d \d\d:\d\d)"', expr or "")
    if not m:
        return None
    return datetime.strptime(m.group(1), "%Y-%m-%d %H:%M").replace(tzinfo=KST)

class Handler(BaseHTTPRequestHandler):
    server_version = "AtlassianMock/0.3"

    def log_message(self, fmt, *args):  # Authorization 헤더는 절대 찍지 않는다
        sys.stderr.write("[mock] %s\n" % (fmt % args))

    def send_json(self, code, obj, headers=None):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def authorized(self):
        h = self.headers.get("Authorization", "")
        if not h.startswith("Basic "):
            return False
        try:
            user, _, pw = base64.b64decode(h[6:]).decode("utf-8").partition(":")
        except Exception:
            return False
        return pw == TOKEN

    def count(self, key):
        with LOCK:
            STATE["counts"][key] = STATE["counts"].get(key, 0) + 1

    def do_GET(self):
        u = urlsplit(self.path)
        if u.path == "/__stats":
            return self.send_json(200, {"throttled": STATE["throttled"], "counts": STATE["counts"]})
        if u.path == "/__jira":
            with LOCK:
                return self.send_json(200, {"issues": [{"key": i["key"], "status": i["fields"]["status"]["name"],
                                                        "type": (i["fields"].get("issuetype") or {}).get("name"),
                                                        "summary": i["fields"]["summary"], "updated": i["fields"]["updated"],
                                                        "comments": [c["body"] if isinstance(c["body"], str) else adf_text(c["body"])
                                                                     for c in i["fields"]["comment"]["comments"]]} for i in ISSUES],
                                            "writes": STATE["writes"], "counts": STATE["counts"]})
        if not self.authorized():
            self.count("401")
            return self.send_json(401, {"message": "Unauthorized"})
        if u.path == "/rest/api/3/myself":
            self.count("myself")
            limit = os.environ.get("MOCK_MYSELF_FAIL_AFTER")
            if limit is not None and STATE["counts"]["myself"] > int(limit):
                return self.send_json(500, {"message": "myself failed"})
            return self.send_json(200, MYSELF)
        m = re.fullmatch(r"/rest/api/3/issue/createmeta/([A-Z][A-Z0-9_]*)/issuetypes", u.path)
        if m:
            self.count("issuetypes")
            if m.group(1) != "PAY":
                return self.send_json(404, {"errorMessages": ["No project could be found with key '%s'." % m.group(1)]})
            return self.send_json(200, {"issueTypes": ISSUE_TYPES, "maxResults": 50, "startAt": 0, "total": len(ISSUE_TYPES)})
        m = re.fullmatch(r"/rest/api/3/issue/([^/]+)(/transitions|/comment)?", u.path)
        if m:
            with LOCK:
                i = find_issue(m.group(1))
                if not i:
                    return self.send_json(404, {"errorMessages": ["Issue does not exist or you do not have permission to see it."]})
                if m.group(2) == "/transitions":
                    self.count("transitions")
                    return self.send_json(200, {"expand": "transitions", "transitions": [
                        {"id": t[0], "name": t[1], "to": {"name": t[2], "statusCategory": {"key": t[3]}}} for t in available(i)]})
                if m.group(2) == "/comment":
                    self.count("comments")
                    cs = list(reversed(i["fields"]["comment"]["comments"]))
                    return self.send_json(200, {"comments": cs, "total": len(cs), "startAt": 0, "maxResults": 50})
                self.count("issue")
                want = (parse_qs(u.query).get("fields") or ["summary,status"])[0].split(",")
                return self.send_json(200, {"id": i["id"], "key": i["key"], "fields": {k: v for k, v in i["fields"].items() if k in want}})
        if u.path == "/wiki/rest/api/content/search":
            self.count("confluence")
            if os.environ.get("MOCK_NO_CONFLUENCE"):   # Jira만 있는 사이트 흉내
                return self.send_json(404, {"message": "no confluence"})
            return self.confluence(u)
        self.send_json(404, {"message": "not found"})

    def do_POST(self):
        u = urlsplit(self.path)
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        if u.path == "/__reset":
            global ISSUES
            with LOCK:
                STATE["throttled"] = False
                STATE["counts"] = {}
                STATE["cfg"] = {"write_fail": None, "write_delay": 0}
                STATE["writes"] = []
                ISSUES = load("jira_issues.json")
            return self.send_json(200, {"ok": True})
        if u.path == "/__config":
            try:
                cfg = json.loads(raw or b"{}")
            except ValueError:
                return self.send_json(400, {"error": "bad json"})
            with LOCK:
                for k in ("write_fail", "write_delay"):
                    if k in cfg:
                        STATE["cfg"][k] = cfg[k]
            return self.send_json(200, {"ok": True, "cfg": STATE["cfg"]})
        if not self.authorized():
            self.count("401")
            return self.send_json(401, {"message": "Unauthorized"})
        if u.path == "/rest/api/3/search/jql":
            self.count("jira")
            with LOCK:
                first = not STATE["throttled"]
                STATE["throttled"] = True
            if first:
                self.count("429")
                return self.send_json(429, {"message": "rate limited"}, {"Retry-After": "1"})
            try:
                body = json.loads(raw or b"{}")
            except ValueError:
                return self.send_json(400, {"errorMessages": ["bad json"]})
            return self.jira(body)
        m = re.fullmatch(r"/rest/api/3/issue(?:/([^/]+)/(transitions|comment))?", u.path)
        if m:
            return self.jira_write(m.group(1), m.group(2), raw)
        self.send_json(404, {"message": "not found"})

    def jira_write(self, key, what, raw):
        """v0.8 쓰기: transitions(204) · comment(201) · issue 생성(201). write_fail·write_delay로 실패를 흉내 낸다."""
        self.count("write_attempts")
        with LOCK:
            wf = STATE["cfg"].get("write_fail")
            delay = float(STATE["cfg"].get("write_delay") or 0)
        if delay > 0:
            time.sleep(delay)
        if wf == "401":
            return self.send_json(401, {"message": "Unauthorized"})
        if wf == "403":
            return self.send_json(403, {"errorMessages": ["You do not have permission to edit this issue."]})
        if wf == "400":
            return self.send_json(400, {"errorMessages": ["mock: rejected (simulated)"], "errors": {"field": "bad value"}})
        if wf == "500":
            return self.send_json(500, {"message": "mock: server error (nothing written)"})
        if wf == "drop":
            return   # 답 없이 끊는다(HTTP/1.0이라 연결이 닫힌다) — 쓰지 않음
        try:
            body = json.loads(raw or b"{}")
        except ValueError:
            return self.send_json(400, {"errorMessages": ["bad json"]})
        with LOCK:
            code, out = self.apply_write(key, what, body)
        if code < 300 and wf == "500_after":
            return self.send_json(500, {"message": "mock: server error after writing"})
        if code < 300 and wf == "drop_after":
            return   # 쓴 뒤 답 없이 끊는다(결과를 모르는 실패)
        if code == 204:
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        return self.send_json(code, out)

    def apply_write(self, key, what, body):
        if what is None:   # 이슈 만들기
            self.count("create")
            f = body.get("fields") or {}
            if (f.get("project") or {}).get("key") != "PAY":
                return 400, {"errorMessages": [], "errors": {"project": "valid project is required"}}
            it = f.get("issuetype") or {}
            t = next((x for x in ISSUE_TYPES if x["id"] == it.get("id") or x["name"] == it.get("name")), None)
            if not t or t["subtask"]:
                return 400, {"errorMessages": [], "errors": {"issuetype": "valid issue type is required"}}
            if not isinstance(f.get("summary"), str) or not f["summary"].strip() or "\n" in f["summary"]:
                return 400, {"errorMessages": [], "errors": {"summary": "summary is required"}}
            if "description" in f and not valid_adf(f["description"]):
                return 400, {"errorMessages": ["description is not valid ADF"]}
            n = max(int(i["key"].split("-")[1]) for i in ISSUES if i["key"].startswith("PAY-")) + 1
            nk, nid, now = "PAY-%d" % n, str(10000 + n), now_kst()
            ISSUES.append({"id": nid, "key": nk, "fields": {
                "summary": f["summary"], "description": f.get("description"), "labels": [], "issuelinks": [],
                "project": {"key": "PAY", "name": "결제"}, "status": {"name": "할 일", "statusCategory": {"key": "new"}},
                "issuetype": {"name": t["name"]}, "priority": {"name": "Medium"}, "created": now, "updated": now,
                "statuscategorychangedate": now, "comment": {"comments": []}}})
            STATE["writes"].append({"tool": "create", "key": nk, "detail": f["summary"], "type": t["name"]})
            return 201, {"id": nid, "key": nk, "self": "http://127.0.0.1/rest/api/3/issue/" + nid}
        i = find_issue(key)
        if not i:
            return 404, {"errorMessages": ["Issue does not exist or you do not have permission to see it."]}
        if what == "transitions":
            self.count("transition")
            tid = (body.get("transition") or {}).get("id")
            t = next((x for x in available(i) if x[0] == tid), None)
            if not isinstance(tid, str) or not t:
                return 400, {"errorMessages": ["Transition id '%s' is not valid for this issue." % tid]}
            i["fields"]["status"] = {"name": t[2], "statusCategory": {"key": t[3], "name": t[2]}}
            i["fields"]["updated"] = now_kst()
            i["fields"]["statuscategorychangedate"] = now_kst()
            STATE["writes"].append({"tool": "transition", "key": i["key"], "detail": t[2]})
            return 204, None
        self.count("comment")
        doc = body.get("body")
        if not valid_adf(doc):
            return 400, {"errorMessages": ["Comment body is not valid ADF"]}
        STATE["seq"] += 1
        cid = str(30000 + STATE["seq"])
        c = {"id": cid, "author": {"displayName": "홍길동 (모의)"}, "body": doc, "created": now_kst()}
        i["fields"]["comment"]["comments"].append(c)
        i["fields"]["updated"] = now_kst()
        STATE["writes"].append({"tool": "comment", "key": i["key"], "detail": adf_text(doc)})
        return 201, c

    def confluence(self, u):
        q = parse_qs(u.query)
        start = int(q.get("start", ["0"])[0])
        since = stamp_from(q.get("cql", [""])[0])
        items = [p for p in PAGES if since is None or parse_iso(p["version"]["when"]) >= since]
        chunk = items[start:start + PAGE]
        links = {"base": "http://127.0.0.1:%d/wiki" % self.server.server_port, "context": "/wiki"}
        if start + PAGE < len(items):
            nq = {k: v[0] for k, v in q.items()}
            nq["start"] = str(start + PAGE)
            links["next"] = "/rest/api/content/search?" + urlencode(nq)
        self.send_json(200, {"results": chunk, "start": start, "limit": PAGE, "size": len(chunk),
                             "totalSize": len(items), "_links": links})

    def jira(self, body):
        since = stamp_from(body.get("jql", ""))
        items = [i for i in ISSUES if since is None or parse_iso(i["fields"]["updated"]) >= since]
        items.sort(key=lambda i: parse_iso(i["fields"]["updated"]), reverse=True)
        tok = body.get("nextPageToken")
        start = int(tok[1:]) if tok and tok.startswith("p") else 0
        chunk = items[start:start + PAGE]
        out = {"issues": chunk}
        if start + PAGE < len(items):
            out["nextPageToken"] = "p%d" % (start + PAGE)
        else:
            out["isLast"] = True
        self.send_json(200, out)

def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    sys.stderr.write("[mock] listening on http://127.0.0.1:%d (token: %s)\n" % (srv.server_port, TOKEN))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass

if __name__ == "__main__":
    main()
