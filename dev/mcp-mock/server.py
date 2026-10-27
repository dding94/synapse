#!/usr/bin/env python3
"""Atlassian 원격 MCP 서버 모의 (Synapse MCP 클라이언트 시험용). 표준 라이브러리만 쓴다. 127.0.0.1에만 바인딩.

    python3 dev/mcp-mock/server.py [port]       # 기본 8790, MCP 주소 http://127.0.0.1:8790/mcp

OAuth 2.1 (MCP 인증 규격)
- GET  /.well-known/oauth-protected-resource[/mcp]   resource, authorization_servers
- GET  /.well-known/oauth-authorization-server        (설정 oidc_only면 404 → openid-configuration으로 대체)
- GET  /.well-known/openid-configuration
- POST /register    동적 등록 (redirect_uris는 http://127.0.0.1:<port>/callback만, token_endpoint_auth_method none)
- GET  /authorize   검증 뒤 곧바로 redirect_uri?code&state 로 302 (설정 deny면 error=access_denied)
- POST /token       authorization_code(PKCE S256 확인) · refresh_token(회전, 설정 fail_refresh면 invalid_grant)
MCP Streamable HTTP
- POST /mcp  토큰 없거나 만료면 401 + WWW-Authenticate(resource_metadata). initialize → Mcp-Session-Id 발급,
             이후 요청은 세션·MCP-Protocol-Version 헤더 필수. 설정 sse면 text/event-stream으로 답한다.
- DELETE /mcp 세션 종료. 도구 6개: atlassianUserInfo, getAccessibleAtlassianResources, searchConfluenceUsingCql,
  getConfluencePage, searchJiraIssuesUsingJql, (그리고 쓰지 않는 getConfluenceSpaces).
- 검색은 한 쪽에 2건씩(2쪽). 첫 searchJiraIssuesUsingJql 호출은 HTTP 429 + Retry-After: 1 (설정 throttle로 다시 무장).
시험용 (인증 없음)
- POST /__config {sse, oidc_only, deny, fail_refresh, malformed, no_confluence, short_expiry, throttle, user_fail,
                  expire_all, drop_sessions, touch:{pages:[...], issues:[...]},
                  (v0.8 Jira 쓰기) write_fail, write_delay, meta_fail, transitions_fail, issue_fail, set_status:{KEY: 상태}}
- GET  /__stats   호출 수·마지막 인자    POST /__reset  처음 상태로
v0.8 Jira 쓰기 도구 (Synapse JiraWriter 시험용)
- getJiraIssue · getTransitionsForJiraIssue · transitionJiraIssue{transition:{id(문자열)}} · addCommentToJiraIssue(contentFormat markdown)
  · getJiraProjectIssueTypesMetadata · createJiraIssue(contentFormat markdown). 바꾼 내용은 검색 결과에도 바로 나온다.
- 상태 흐름: 해야 할 일 / 진행 시작→진행 중 / Done→완료 / 보류→Blocked (지금 상태로 가는 전환은 목록에서 뺀다). 유형: 작업·버그·에픽·하위 작업.
- write_fail: "isError"(도구 오류) · "403"(권한 도구 오류) · "401"(HTTP 401) · "500"(HTTP 500, 쓰지 않음) · "drop"(답 없이 끊음, 쓰지 않음)
              · "500_after"·"drop_after"(쓴 뒤에 500·끊음 — 결과를 모르는 실패) · null. write_delay: 쓰기 도구를 그만큼(초) 늦게 처리한다.
- POST /__token  시험용 자격 증명(Synapse MCPCredential JSON)을 바로 발급한다. GET /__jira  이슈 상태·댓글·쓰기 기록.
"""
import base64, copy, hashlib, json, os, re, secrets, sys, threading, time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlencode, urlsplit

HERE = os.path.dirname(os.path.abspath(__file__))
SITE_URL = "https://payteam-mock.atlassian.net"
CLOUD_ID = "c0ffee00-0000-4000-8000-000000000142"
OTHER_SITE = {"id": "d351a000-0000-4000-8000-000000000777", "url": "https://design-mock.atlassian.net", "name": "디자인팀", "scopes": ["read:jira-work"]}
VERSIONS = ["2025-06-18", "2025-03-26", "2024-11-05"]
PAGE = 2

def load(name):
    with open(os.path.join(HERE, "fixtures", name), encoding="utf-8") as f:
        return json.load(f)

LOCK = threading.Lock()

def fresh_state():
    return {
        "cfg": {"sse": False, "oidc_only": False, "deny": False, "fail_refresh": False, "malformed": False,
                "no_confluence": False, "short_expiry": 0, "throttle": True, "user_fail": False,
                "write_fail": None, "write_delay": 0, "meta_fail": False, "transitions_fail": False, "issue_fail": False},
        "writes": [], "seq": 0,
        "clients": {}, "codes": {}, "access": {}, "refresh": {}, "sessions": {},
        "pages": load("pages.json"), "issues": load("issues.json"),
        "stats": {"calls": {}, "args": {}, "unauthorized": 0, "refreshed": 0, "registered": 0, "sessions": 0,
                  "throttled": 0, "sse": 0, "deleted": 0, "authorized": 0, "write_attempts": 0},
    }

STATE = fresh_state()

def now_iso_z():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")

def now_iso_kst():
    return datetime.now().astimezone().strftime("%Y-%m-%dT%H:%M:%S.000%z")

def parse_iso(s):
    s = re.sub(r"([+-]\d\d)(\d\d)$", r"\1:\2", s.replace("Z", "+00:00"))
    return datetime.fromisoformat(s)

def stamp_from(expr):
    m = re.search(r'(?:lastmodified|updated)\s*>=\s*"(\d{4}-\d\d-\d\d \d\d:\d\d)"', expr or "")
    if not m:
        return None
    return datetime.strptime(m.group(1), "%Y-%m-%d %H:%M").astimezone()   # 클라이언트와 같은 기기 시간대

def b64(n):
    return base64.urlsafe_b64encode(str(n).encode()).decode().rstrip("=")

def unb64(s):
    try:
        return int(base64.urlsafe_b64decode(s + "=" * (-len(s) % 4)).decode())
    except Exception:
        return None

class Handler(BaseHTTPRequestHandler):
    server_version = "AtlassianMCPMock/0.4"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):   # Authorization 헤더·토큰은 찍지 않는다
        if os.environ.get("MOCK_QUIET") != "1":
            sys.stderr.write("[mcp-mock] %s\n" % (fmt % args))

    @property
    def base(self):
        return "http://127.0.0.1:%d" % self.server.server_address[1]

    def body_bytes(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n > 0 else b""

    def send(self, code, body=b"", ctype="application/json; charset=utf-8", headers=None):
        if isinstance(body, (dict, list)):
            body = json.dumps(body, ensure_ascii=False).encode("utf-8")
        elif isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        if body or code not in (202, 204):
            self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if body:
            self.wfile.write(body)

    # ---------- OAuth ----------

    def prm(self):
        return {"resource": self.base + "/mcp", "authorization_servers": [self.base],
                "bearer_methods_supported": ["header"], "resource_name": "Atlassian MCP (mock)"}

    def as_meta(self):
        b = self.base
        return {"issuer": b, "authorization_endpoint": b + "/authorize", "token_endpoint": b + "/token",
                "registration_endpoint": b + "/register", "response_types_supported": ["code"],
                "grant_types_supported": ["authorization_code", "refresh_token"],
                "code_challenge_methods_supported": ["S256"], "token_endpoint_auth_methods_supported": ["none"]}

    def do_GET(self):
        u = urlsplit(self.path)
        p = u.path
        if p in ("/.well-known/oauth-protected-resource", "/.well-known/oauth-protected-resource/mcp"):
            return self.send(200, self.prm())
        if p == "/.well-known/oauth-authorization-server":
            if STATE["cfg"]["oidc_only"]:
                return self.send(404, {"error": "not_found"})
            return self.send(200, self.as_meta())
        if p == "/.well-known/openid-configuration":
            return self.send(200, self.as_meta())
        if p == "/authorize":
            return self.authorize(parse_qs(u.query))
        if p == "/__stats":
            with LOCK:
                return self.send(200, STATE["stats"])
        if p == "/__jira":
            with LOCK:
                return self.send(200, {"issues": [{"key": i["key"], "status": i["fields"]["status"]["name"],
                                                   "category": i["fields"]["status"].get("statusCategory", {}).get("key"),
                                                   "type": (i["fields"].get("issuetype") or {}).get("name"),
                                                   "summary": i["fields"]["summary"], "updated": i["fields"]["updated"],
                                                   "comments": [c["body"] for c in i["fields"]["comment"]["comments"]]} for i in STATE["issues"]],
                                       "writes": STATE["writes"], "calls": STATE["stats"]["calls"],
                                       "write_attempts": STATE["stats"]["write_attempts"]})
        if p == "/mcp":
            return self.send(405, {"error": "SSE stream (GET) not offered"}, headers={"Allow": "POST, DELETE"})
        return self.send(404, {"error": "not_found"})

    def authorize(self, q):
        g = lambda k: (q.get(k) or [""])[0]
        cid, ru, state = g("client_id"), g("redirect_uri"), g("state")
        with LOCK:
            client = STATE["clients"].get(cid)
            if not client or ru not in client["redirect_uris"]:
                return self.send(400, "unknown client or redirect_uri", "text/plain; charset=utf-8")
            if g("response_type") != "code" or g("code_challenge_method") != "S256" or not g("code_challenge") or not state:
                return self.send(400, "bad authorize request", "text/plain; charset=utf-8")
            if g("resource") != self.base + "/mcp":
                return self.send(400, "bad resource", "text/plain; charset=utf-8")
            if STATE["cfg"]["deny"]:
                return self.send(302, b"", headers={"Location": ru + "?" + urlencode({"error": "access_denied", "state": state})})
            code = secrets.token_urlsafe(16)
            STATE["codes"][code] = {"client_id": cid, "redirect_uri": ru, "challenge": g("code_challenge")}
            STATE["stats"]["authorized"] += 1
        return self.send(302, b"", headers={"Location": ru + "?" + urlencode({"code": code, "state": state})})

    def issue(self, cid):
        exp_in = STATE["cfg"]["short_expiry"] or 3600
        at, rt = "at-" + secrets.token_urlsafe(12), "rt-" + secrets.token_urlsafe(12)
        STATE["access"][at] = {"exp": time.time() + exp_in, "revoked": False}
        STATE["refresh"][rt] = {"client_id": cid}
        return {"access_token": at, "token_type": "Bearer", "expires_in": exp_in, "refresh_token": rt}

    def token(self):
        form = {k: v[0] for k, v in parse_qs(self.body_bytes().decode()).items()}
        gt = form.get("grant_type")
        with LOCK:
            if gt == "authorization_code":
                c = STATE["codes"].pop(form.get("code", ""), None)
                if not c or c["client_id"] != form.get("client_id") or c["redirect_uri"] != form.get("redirect_uri"):
                    return self.send(400, {"error": "invalid_grant"})
                ver = form.get("code_verifier", "")
                chal = base64.urlsafe_b64encode(hashlib.sha256(ver.encode()).digest()).decode().rstrip("=")
                if chal != c["challenge"]:
                    return self.send(400, {"error": "invalid_grant", "error_description": "PKCE mismatch"})
                if form.get("resource") != self.base + "/mcp":
                    return self.send(400, {"error": "invalid_target"})
                return self.send(200, self.issue(c["client_id"]), headers={"Cache-Control": "no-store"})
            if gt == "refresh_token":
                r = STATE["refresh"].pop(form.get("refresh_token", ""), None)    # 회전: 한 번 쓰면 끝
                if STATE["cfg"]["fail_refresh"] or not r or r["client_id"] != form.get("client_id"):
                    return self.send(400, {"error": "invalid_grant"})
                STATE["stats"]["refreshed"] += 1
                return self.send(200, self.issue(r["client_id"]), headers={"Cache-Control": "no-store"})
        return self.send(400, {"error": "unsupported_grant_type"})

    def register(self):
        try:
            req = json.loads(self.body_bytes() or b"{}")
        except Exception:
            return self.send(400, {"error": "invalid_client_metadata"})
        rus = req.get("redirect_uris") or []
        ok = rus and all(re.fullmatch(r"http://127\.0\.0\.1:\d{2,5}/callback", r or "") for r in rus)
        if not ok or req.get("token_endpoint_auth_method") != "none" or req.get("client_name") != "Synapse":
            return self.send(400, {"error": "invalid_redirect_uri"})
        cid = "client-" + secrets.token_urlsafe(8)
        with LOCK:
            STATE["clients"][cid] = {"redirect_uris": rus}
            STATE["stats"]["registered"] += 1
        return self.send(201, {"client_id": cid, "client_name": "Synapse", "redirect_uris": rus,
                               "token_endpoint_auth_method": "none", "grant_types": ["authorization_code", "refresh_token"]})

    # ---------- 시험 제어 ----------

    def control(self, path):
        global STATE
        raw = self.body_bytes()
        if path == "/__reset":
            with LOCK:
                STATE = fresh_state()
            return self.send(200, {"ok": True})
        try:
            cfg = json.loads(raw or b"{}")
        except Exception:
            return self.send(400, {"error": "bad json"})
        with LOCK:
            for k in ("sse", "oidc_only", "deny", "fail_refresh", "malformed", "no_confluence", "short_expiry", "throttle", "user_fail",
                      "write_fail", "write_delay", "meta_fail", "transitions_fail", "issue_fail"):
                if k in cfg:
                    STATE["cfg"][k] = cfg[k]
            if cfg.get("expire_all"):
                for a in STATE["access"].values():
                    a["revoked"] = True
            if cfg.get("drop_sessions"):
                STATE["sessions"].clear()
            for k, st in (cfg.get("set_status") or {}).items():     # v0.8 시험: Jira 밖에서 상태가 바뀐 상황
                i = find_issue(k)
                tr = next((t for t in TRANSITIONS if t[2] == st), None)
                if i and tr:
                    i["fields"]["status"] = {"name": tr[2], "statusCategory": {"key": tr[3]}}
                    i["fields"]["updated"] = now_iso_kst()
            t = cfg.get("touch") or {}
            for p in STATE["pages"]:
                if p["id"] in (t.get("pages") or []):
                    p["version"] += 1; p["updated"] = now_iso_z(); p["body"] += "\n\n수정됨."
            for i in STATE["issues"]:
                if i["key"] in (t.get("issues") or []):
                    i["fields"]["updated"] = now_iso_kst(); i["fields"]["summary"] += " (수정)"
        return self.send(200, {"ok": True, "cfg": STATE["cfg"]})

    def test_token(self):
        """시험용: 브라우저 로그인 없이 자격 증명(Synapse MCPCredential JSON)을 바로 발급한다. 갱신 토큰도 실제처럼 쓸 수 있다."""
        self.body_bytes()
        with LOCK:
            cid = "client-test-" + secrets.token_urlsafe(6)
            STATE["clients"][cid] = {"redirect_uris": ["http://127.0.0.1:1/callback"]}
            tok = self.issue(cid)
        return self.send(200, {"access_token": tok["access_token"], "refresh_token": tok["refresh_token"],
                               "expires_at": time.time() + tok["expires_in"], "client_id": cid,
                               "token_endpoint": self.base + "/token", "resource": self.base + "/mcp"})

    def do_POST(self):
        p = urlsplit(self.path).path
        if p in ("/__config", "/__reset"):
            return self.control(p)
        if p == "/__token":
            return self.test_token()
        if p == "/register":
            return self.register()
        if p == "/token":
            return self.token()
        if p == "/mcp":
            return self.mcp()
        return self.send(404, {"error": "not_found"})

    def do_DELETE(self):
        if urlsplit(self.path).path != "/mcp" or not self.authed():
            return self.send(404 if urlsplit(self.path).path != "/mcp" else 401, b"")
        with LOCK:
            STATE["sessions"].pop(self.headers.get("Mcp-Session-Id", ""), None)
            STATE["stats"]["deleted"] += 1
        return self.send(200, b"")

    # ---------- MCP ----------

    def authed(self):
        h = self.headers.get("Authorization", "")
        if not h.startswith("Bearer "):
            return False
        with LOCK:
            a = STATE["access"].get(h[7:])
            return bool(a and not a["revoked"] and a["exp"] > time.time())

    def mcp(self):
        raw = self.body_bytes()
        if not self.authed():
            with LOCK:
                STATE["stats"]["unauthorized"] += 1
            presented = self.headers.get("Authorization", "").startswith("Bearer ")
            chal = 'Bearer resource_metadata="%s/.well-known/oauth-protected-resource/mcp"' % self.base
            if presented:
                chal += ', error="invalid_token", error_description="The access token expired"'
            return self.send(401, {"error": "unauthorized"}, headers={"WWW-Authenticate": chal})
        acc = self.headers.get("Accept", "")
        if "application/json" not in acc or "text/event-stream" not in acc:
            return self.send(406, {"error": "Accept must list application/json and text/event-stream"})
        try:
            msg = json.loads(raw)
        except Exception:
            return self.send(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}})
        if not isinstance(msg, dict):
            return self.send(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "batch not supported"}})
        method, mid = msg.get("method"), msg.get("id")
        headers = {}
        with LOCK:
            if method == "initialize":
                want = (msg.get("params") or {}).get("protocolVersion")
                ver = want if want in VERSIONS else VERSIONS[0]
                sid = "sess-" + secrets.token_hex(8)
                STATE["sessions"][sid] = ver
                STATE["stats"]["sessions"] += 1
                headers["Mcp-Session-Id"] = sid
                result = {"protocolVersion": ver, "capabilities": {"tools": {"listChanged": False}},
                          "serverInfo": {"name": "atlassian-mcp-mock", "version": "0.4"}}
                return self.reply(mid, result, headers)
            sid = self.headers.get("Mcp-Session-Id")
            if not sid:
                return self.send(400, {"jsonrpc": "2.0", "id": mid, "error": {"code": -32600, "message": "Missing session"}})
            if sid not in STATE["sessions"]:
                return self.send(404, {"jsonrpc": "2.0", "id": mid, "error": {"code": -32001, "message": "Session not found"}})
            if self.headers.get("MCP-Protocol-Version") != STATE["sessions"][sid]:
                return self.send(400, {"jsonrpc": "2.0", "id": mid, "error": {"code": -32600, "message": "Bad MCP-Protocol-Version"}})
            if mid is None:
                return self.send(202, b"")
            if method == "tools/call":
                name = (msg.get("params") or {}).get("name")
                if name == "searchJiraIssuesUsingJql" and STATE["cfg"]["throttle"]:
                    STATE["cfg"]["throttle"] = False
                    STATE["stats"]["throttled"] += 1
                    return self.send(429, {"error": "rate limited"}, headers={"Retry-After": "1"})
        if method == "ping":
            return self.reply(mid, {})
        if method == "tools/list":
            return self.reply(mid, {"tools": TOOLS})
        if method == "tools/call":
            params = msg.get("params") or {}
            name, args = params.get("name"), params.get("arguments") or {}
            wf = None
            if name in WRITE_TOOLS:
                with LOCK:
                    STATE["stats"]["write_attempts"] += 1
                    wf = STATE["cfg"].get("write_fail")
                    delay = float(STATE["cfg"].get("write_delay") or 0)
                if delay > 0:
                    time.sleep(delay)          # 잠금 밖: 두 요청이 겹치게
                if wf == "401":
                    chal = 'Bearer resource_metadata="%s/.well-known/oauth-protected-resource/mcp", error="invalid_token"' % self.base
                    return self.send(401, {"error": "unauthorized"}, headers={"WWW-Authenticate": chal})
                if wf == "500":
                    return self.send(500, {"error": "mock: server error (simulated, nothing written)"})
                if wf == "drop":
                    self.close_connection = True   # 답 없이 끊는다(쓰지 않음)
                    return
            with LOCK:
                st = STATE["stats"]
                st["calls"][name] = st["calls"].get(name, 0) + 1
                st["args"][name] = args
                fn = TOOL_IMPL.get(name)
                result = fn(args) if fn else err_result("Unknown tool: %s" % name)
            if wf == "500_after":
                return self.send(500, {"error": "mock: server error after writing (simulated)"})
            if wf == "drop_after":
                self.close_connection = True       # 쓴 뒤 답 없이 끊는다(결과를 모르는 실패)
                return
            return self.reply(mid, result)
        return self.send(200, {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "Method not found"}})

    def reply(self, mid, result, headers=None):
        msg = {"jsonrpc": "2.0", "id": mid, "result": result}
        headers = dict(headers or {})
        if STATE["cfg"]["sse"]:
            STATE["stats"]["sse"] += 1
            note = {"jsonrpc": "2.0", "method": "notifications/message", "params": {"level": "info", "data": "처리 중"}}
            pretty = json.dumps(msg, ensure_ascii=False, indent=1).split("\n")   # 여러 data: 줄로 나눠 보낸다
            out = "event: message\r\ndata: %s\r\n\r\n: keepalive\n\n" % json.dumps(note, ensure_ascii=False)
            out += "id: 1\nevent: message\n" + "".join("data: %s\n" % l for l in pretty) + "\n"
            body = out.encode("utf-8")
            headers["Cache-Control"] = "no-cache"
            return self.send(200, body, "text/event-stream", headers)
        return self.send(200, msg, headers=headers)

# ---------- 도구 (LOCK 안에서 불린다) ----------

def text_result(obj, structured=False):
    r = {"content": [{"type": "text", "text": json.dumps(obj, ensure_ascii=False)}], "isError": False}
    if structured:
        r["structuredContent"] = obj
    return r

def err_result(msg):
    return {"content": [{"type": "text", "text": msg}], "isError": True}

def check_cloud(args):
    c = args.get("cloudId") or ""
    return c in (CLOUD_ID, SITE_URL, "payteam-mock.atlassian.net")

def page_webui(p):
    return "/spaces/%s/pages/%s/%s" % (p["spaceKey"], p["id"], p["title"].replace(" ", "+"))

def t_user(args):
    if STATE["cfg"]["user_fail"]:
        return err_result("mock: atlassianUserInfo failed")
    return text_result({"account_id": "712020:mock-cheolsu", "email": "cheolsu.kim@example.com", "name": "김철수", "nickname": "cheolsu"})

def t_resources(args):
    sites = [{"id": CLOUD_ID, "url": SITE_URL, "name": "정산팀", "scopes": ["read:jira-work", "read:confluence-content.all"]}, OTHER_SITE]
    return text_result(sites)

def t_search_cql(args):
    if not check_cloud(args):
        return err_result("Site not found for cloudId")
    if STATE["cfg"]["no_confluence"]:
        return err_result("Forbidden (403): the user does not have access to Confluence on this site")
    cql = args.get("cql") or ""
    if "type=page" not in cql.replace(" ", ""):
        return err_result("mock: expected type=page in CQL")
    limit = int(args.get("limit") or 25)
    if limit > 250:
        return err_result("limit must be <= 250")
    since = stamp_from(cql)
    rows = [p for p in STATE["pages"] if not since or parse_iso(p["updated"]) >= since]
    rows.sort(key=lambda p: p["updated"], reverse=True)
    start = unb64(args.get("cursor")) if args.get("cursor") else 0
    if start is None:
        return err_result("Invalid cursor")
    size = min(limit, PAGE)
    chunk = rows[start:start + size]
    out = {"results": [{"content": {"id": p["id"], "type": "page", "status": "current", "title": p["title"],
                                    "_links": {"webui": page_webui(p)}},
                        "title": "@@@hl@@@" + p["title"] + "@@@endhl@@@", "excerpt": p["body"][:40], "url": page_webui(p),
                        "resultGlobalContainer": {"title": "정산 팀", "displayUrl": "/spaces/" + p["spaceKey"]},
                        "lastModified": p["updated"]} for p in chunk],
           "start": start, "limit": size, "size": len(chunk), "totalSize": len(rows), "_links": {"base": SITE_URL + "/wiki"}}
    if start + size < len(rows):
        out["_links"]["next"] = "/rest/api/search?" + urlencode({"cql": cql, "limit": size, "cursor": b64(start + size)})
    return text_result(out)

def t_page(args):
    if not check_cloud(args):
        return err_result("Site not found for cloudId")
    if args.get("contentFormat") != "markdown":
        return err_result("mock: expected contentFormat markdown")
    p = next((x for x in STATE["pages"] if x["id"] == str(args.get("pageId"))), None)
    if not p:
        return err_result("404 Not Found: page")
    if STATE["cfg"]["malformed"] and p["id"] == "104":
        return {"content": [{"type": "text", "text": "이건 JSON이 아님 <페이지를 불러오지 못함>"}], "isError": False}
    page = {"id": p["id"], "status": "current", "title": p["title"], "spaceId": "98001", "parentId": p["parentId"],
            "parentType": "page" if p["parentId"] else None, "authorId": "712020:mock-cheolsu", "createdAt": p["createdAt"],
            "version": {"number": p["version"], "createdAt": p["updated"], "message": ""},
            "labels": {"results": [{"name": l, "prefix": "global"} for l in p["labels"]]},
            "body": p["body"],
            "_links": {"webui": page_webui(p), "base": SITE_URL + "/wiki", "tinyui": "/x/abc" + p["id"]}}
    return text_result(page, structured=True)

def t_search_jql(args):
    if not check_cloud(args):
        return err_result("Site not found for cloudId")
    mr = int(args.get("maxResults") or 50)
    if mr > 100:
        return err_result("maxResults must be <= 100")
    if args.get("responseContentFormat") != "markdown":
        return err_result("mock: expected responseContentFormat markdown")
    fields = args.get("fields") or []
    jql = args.get("jql") or ""
    since = stamp_from(jql)
    rows = [i for i in STATE["issues"] if not since or parse_iso(i["fields"]["updated"]) >= since]
    rows.sort(key=lambda i: parse_iso(i["fields"]["updated"]), reverse=True)
    start = unb64(args.get("nextPageToken")) if args.get("nextPageToken") else 0
    if start is None:
        return err_result("Invalid nextPageToken")
    size = min(mr, PAGE)
    chunk = copy.deepcopy(rows[start:start + size])
    for i in chunk:
        i["self"] = SITE_URL + "/rest/api/3/issue/" + i["id"]
        i["fields"] = {k: v for k, v in i["fields"].items() if k in fields}
    if STATE["cfg"]["malformed"] and start == 0:
        chunk.append({"id": "99999", "fields": {"summary": "키 없는 이상한 항목"}})
    out = {"issues": chunk, "isLast": start + size >= len(rows)}
    if not out["isLast"]:
        out["nextPageToken"] = b64(start + size)
    return text_result(out)

def t_spaces(args):
    return text_result({"results": [{"id": "98001", "key": "PAY", "name": "정산 팀"}]})

# ---------- v0.8 Jira 쓰기 (LOCK 안에서 불린다) ----------

TRANSITIONS = [("11", "해야 할 일", "해야 할 일", "new"), ("21", "진행 시작", "진행 중", "indeterminate"),
               ("31", "Done", "완료", "done"), ("41", "보류", "Blocked", "done")]
ISSUE_TYPES = [{"id": "10001", "name": "작업", "subtask": False}, {"id": "10002", "name": "버그", "subtask": False},
               {"id": "10003", "name": "에픽", "subtask": False}, {"id": "10004", "name": "하위 작업", "subtask": True}]
WRITE_TOOLS = {"transitionJiraIssue", "addCommentToJiraIssue", "createJiraIssue"}

def find_issue(k):
    k = str(k or "")
    return next((i for i in STATE["issues"] if i["key"] == k or i["id"] == k), None)

def available(issue):
    cur = issue["fields"]["status"]["name"]
    return [t for t in TRANSITIONS if t[2] != cur]

def write_gate():
    wf = STATE["cfg"].get("write_fail")
    if wf == "isError":
        return err_result("mock: the change was rejected (simulated)")
    if wf == "403":
        return err_result("Forbidden (403): You do not have permission to edit this issue.")
    return None

def record(tool, key, detail):
    STATE["writes"].append({"tool": tool, "key": key, "detail": detail, "at": time.time()})

def t_issue(args):
    if not check_cloud(args):
        return err_result("Site not found for cloudId")
    if STATE["cfg"].get("issue_fail"):
        return err_result("mock: getJiraIssue failed")
    i = find_issue(args.get("issueIdOrKey"))
    if not i:
        return err_result("Issue does not exist or you do not have permission to see it. (404)")
    fields = args.get("fields") or ["summary", "status", "issuetype", "updated"]
    return text_result({"id": i["id"], "key": i["key"], "fields": {k: v for k, v in i["fields"].items() if k in fields}})

def t_transitions(args):
    if not check_cloud(args):
        return err_result("Site not found for cloudId")
    if STATE["cfg"].get("transitions_fail"):
        return err_result("mock: transitions failed")
    i = find_issue(args.get("issueIdOrKey"))
    if not i:
        return err_result("Issue does not exist or you do not have permission to see it. (404)")
    return text_result({"expand": "transitions", "transitions": [
        {"id": t[0], "name": t[1], "to": {"name": t[2], "id": "s" + t[0], "statusCategory": {"key": t[3]}}, "hasScreen": False, "isGlobal": True}
        for t in available(i)]})

def t_transition(args):
    if not check_cloud(args):
        return err_result("Site not found for cloudId")
    g = write_gate()
    if g:
        return g
    i = find_issue(args.get("issueIdOrKey"))
    if not i:
        return err_result("Issue does not exist or you do not have permission to see it. (404)")
    tr = args.get("transition")
    tid = tr.get("id") if isinstance(tr, dict) else None
    if not isinstance(tid, str):
        return err_result("mock: transition.id must be a string")
    t = next((t for t in available(i) if t[0] == tid), None)
    if not t:
        return err_result("Transition id '%s' is not valid for this issue." % tid)
    f = i["fields"]
    f["status"] = {"name": t[2], "statusCategory": {"key": t[3]}}
    f["updated"] = now_iso_kst()
    f["statuscategorychangedate"] = now_iso_kst()
    record("transition", i["key"], t[2])
    return {"content": [{"type": "text", "text": "Issue %s transitioned to %s" % (i["key"], t[2])}], "isError": False}

def t_comment(args):
    if not check_cloud(args):
        return err_result("Site not found for cloudId")
    g = write_gate()
    if g:
        return g
    if args.get("commentId"):
        return err_result("mock: updating an existing comment is not expected")
    if args.get("contentFormat") != "markdown":
        return err_result("mock: expected contentFormat markdown")
    body = args.get("commentBody")
    if not isinstance(body, str) or not body.strip():
        return err_result("Comment body is required")
    i = find_issue(args.get("issueIdOrKey"))
    if not i:
        return err_result("Issue does not exist or you do not have permission to see it. (404)")
    STATE["seq"] += 1
    cid = str(20000 + STATE["seq"])
    c = {"id": cid, "author": {"displayName": "김철수"}, "body": body, "created": now_iso_kst()}
    i["fields"]["comment"]["comments"].append(c)
    i["fields"]["updated"] = now_iso_kst()
    record("comment", i["key"], body)
    return text_result({"id": cid, "body": body, "created": c["created"], "self": SITE_URL + "/rest/api/3/issue/%s/comment/%s" % (i["id"], cid)})

def t_issue_types(args):
    if not check_cloud(args):
        return err_result("Site not found for cloudId")
    if STATE["cfg"].get("meta_fail"):
        return err_result("mock: issue type metadata failed")
    if str(args.get("projectIdOrKey")) not in ("PAY", "10000"):
        return err_result("No project could be found with key '%s'. (404)" % args.get("projectIdOrKey"))
    return text_result({"issueTypes": ISSUE_TYPES, "maxResults": 50, "startAt": 0, "total": len(ISSUE_TYPES)})

def t_create(args):
    if not check_cloud(args):
        return err_result("Site not found for cloudId")
    g = write_gate()
    if g:
        return g
    if args.get("contentFormat") != "markdown":
        return err_result("mock: expected contentFormat markdown")
    if args.get("projectKey") != "PAY":
        return err_result("Project '%s' does not exist. (404)" % args.get("projectKey"))
    tname = args.get("issueTypeName")
    if tname not in [t["name"] for t in ISSUE_TYPES]:
        return err_result("Specify a valid issue type: '%s' is not valid." % tname)
    summary = args.get("summary")
    if not isinstance(summary, str) or not summary.strip():
        return err_result("Summary is required")
    n = max(int(i["key"].split("-")[1]) for i in STATE["issues"] if i["key"].startswith("PAY-")) + 1
    key, iid, now = "PAY-%d" % n, str(10000 + n), now_iso_kst()
    STATE["issues"].append({"id": iid, "key": key, "fields": {
        "summary": summary, "description": args.get("description"), "labels": [], "issuelinks": [],
        "project": {"key": "PAY", "name": "결제"}, "status": {"name": "해야 할 일", "statusCategory": {"key": "new"}},
        "issuetype": {"name": tname}, "priority": {"name": "Medium"}, "created": now, "updated": now,
        "statuscategorychangedate": now, "comment": {"comments": []}}})
    record("create", key, summary)
    return text_result({"id": iid, "key": key, "self": SITE_URL + "/rest/api/3/issue/" + iid})

TOOL_IMPL = {"atlassianUserInfo": t_user, "getAccessibleAtlassianResources": t_resources,
             "searchConfluenceUsingCql": t_search_cql, "getConfluencePage": t_page,
             "searchJiraIssuesUsingJql": t_search_jql, "getConfluenceSpaces": t_spaces,
             "getJiraIssue": t_issue, "getTransitionsForJiraIssue": t_transitions, "transitionJiraIssue": t_transition,
             "addCommentToJiraIssue": t_comment, "getJiraProjectIssueTypesMetadata": t_issue_types, "createJiraIssue": t_create}

def schema(props, req=()):
    return {"type": "object", "properties": props, "required": list(req)}

S = {"type": "string"}
N = {"type": "number"}
TOOLS = [
    {"name": "atlassianUserInfo", "description": "Get current user info", "inputSchema": schema({})},
    {"name": "getAccessibleAtlassianResources", "description": "Get cloudId to make tool calls", "inputSchema": schema({})},
    {"name": "searchConfluenceUsingCql", "description": "Search Confluence using CQL",
     "inputSchema": schema({"cloudId": S, "cql": S, "limit": N, "cursor": S}, ("cloudId", "cql"))},
    {"name": "getConfluencePage", "description": "Get a Confluence page by ID",
     "inputSchema": schema({"cloudId": S, "pageId": S, "contentFormat": {"type": "string", "enum": ["html", "markdown", "adf"]}}, ("cloudId", "pageId"))},
    {"name": "searchJiraIssuesUsingJql", "description": "Search issues with JQL",
     "inputSchema": schema({"cloudId": S, "jql": S, "fields": {"type": "array", "items": S}, "maxResults": N,
                            "nextPageToken": S, "responseContentFormat": {"type": "string", "enum": ["markdown", "adf"]}}, ("cloudId", "jql"))},
    {"name": "getConfluenceSpaces", "description": "List spaces", "inputSchema": schema({"cloudId": S}, ("cloudId",))},
    {"name": "getJiraIssue", "description": "Get issue details",
     "inputSchema": schema({"cloudId": S, "issueIdOrKey": S, "fields": {"type": "array", "items": S}, "responseContentFormat": S}, ("cloudId", "issueIdOrKey"))},
    {"name": "getTransitionsForJiraIssue", "description": "Get transitions", "inputSchema": schema({"cloudId": S, "issueIdOrKey": S}, ("cloudId", "issueIdOrKey"))},
    {"name": "transitionJiraIssue", "description": "Transition issue status",
     "inputSchema": schema({"cloudId": S, "issueIdOrKey": S, "transition": {"type": "object", "properties": {"id": S}, "required": ["id"]}},
                           ("cloudId", "issueIdOrKey", "transition"))},
    {"name": "addCommentToJiraIssue", "description": "Add or update a comment on a Jira issue",
     "inputSchema": schema({"cloudId": S, "issueIdOrKey": S, "commentBody": S, "commentId": S, "contentFormat": {"type": "string", "enum": ["markdown", "adf"]}},
                           ("cloudId", "issueIdOrKey", "commentBody"))},
    {"name": "getJiraProjectIssueTypesMetadata", "description": "Get issue types", "inputSchema": schema({"cloudId": S, "projectIdOrKey": S}, ("cloudId", "projectIdOrKey"))},
    {"name": "createJiraIssue", "description": "Create a Jira issue",
     "inputSchema": schema({"cloudId": S, "projectKey": S, "issueTypeName": S, "summary": S, "description": S,
                            "contentFormat": {"type": "string", "enum": ["markdown", "adf"]}}, ("cloudId", "projectKey", "issueTypeName", "summary"))},
]

def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8790
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    srv.daemon_threads = True
    sys.stderr.write("[mcp-mock] http://127.0.0.1:%d/mcp\n" % srv.server_address[1])
    sys.stderr.flush()
    srv.serve_forever()

if __name__ == "__main__":
    main()
