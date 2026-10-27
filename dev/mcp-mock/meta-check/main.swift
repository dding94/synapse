import Foundation

// Atlassian MCP 연결기의 Jira meta(docs/V05.md §4.8) 시험: 모의 서버(dev/mcp-mock/server.py)에 로그인해 동기화하고
// DocRecord.meta가 채워졌는지, mine 판정이 맞는지, atlassianUserInfo를 동기화당 한 번만 부르는지 확인한다.
//   python3 dev/mcp-mock/server.py 8790 &
//   (Library/** 와 이 파일을 함께 swiftc로 빌드해 실행. 자세한 건 dev/mcp-mock/README.md)
// 환경변수 MOCK_PORT(기본 8790). 네트워크는 127.0.0.1뿐.

Plugins.secrets = MemorySecretStore()
let port = ProcessInfo.processInfo.environment["MOCK_PORT"] ?? "8790"
let serverURL = URL(string: "http://127.0.0.1:\(port)/mcp")!
var failed = 0
func check(_ ok: Bool, _ name: String, _ detail: Any = "") {
    print((ok ? "  ok   " : "  FAIL ") + name + (ok ? "" : " :: \(detail)"))
    if !ok { failed += 1 }
}

Task.detached {
    do {
        // 브라우저 대신 인가 주소를 직접 요청한다(모의 서버가 바로 loopback으로 리디렉트).
        let cred = try await MCPAuth.authorize(serverURL: serverURL, openURL: { u in Task.detached { _ = try? await URLSession.shared.data(from: u) } })
        let cfg = SourceConfig(id: "meta-check", kind: .mcp, name: "A", path: nil, site: nil, email: nil, confluenceSpaces: nil, jiraJQL: nil,
                               enabled: true, addedAt: Date(), mcpURL: serverURL.absoluteString, mcpSite: "payteam-mock.atlassian.net")
        let result = try await AtlassianMCPConnector(config: cfg, token: cred).sync(since: nil) { _, _ in }
        var meta: [String: [String: String]] = [:]
        for d in result.upserts where d.kind == "jira" { meta[String(d.id.split(separator: ":").last ?? "")] = d.meta ?? [:] }
        print("[Jira meta]")
        check(Set(meta.keys) == ["PAY-100", "PAY-120", "PAY-142", "PAY-150"], "이슈 4개", meta.keys)
        let me = "712020:mock-cheolsu"
        check(meta["PAY-150"]?["mine"] == "1" && meta["PAY-150"]?["assignee"] == me, "PAY-150 내 이슈", meta["PAY-150"] ?? [:])
        check(meta["PAY-150"]?["priority"] == "High" && meta["PAY-150"]?["duedate"] == "2026-10-28"
              && meta["PAY-150"]?["statusCategory"] == "indeterminate" && meta["PAY-150"]?["status"] == "진행 중"
              && meta["PAY-150"]?["issuetype"] == "작업", "PAY-150 필드", meta["PAY-150"] ?? [:])
        check(meta["PAY-150"]?["updated"] == "2026-10-19T07:30:00Z", "updated는 ISO8601(UTC)", meta["PAY-150"]?["updated"] ?? "")
        check(meta["PAY-142"]?["mine"] == "0" && meta["PAY-142"]?["statusCategory"] == "done" && meta["PAY-142"]?["duedate"] == nil, "PAY-142 남의 이슈·완료·기한 없음", meta["PAY-142"] ?? [:])
        check(meta["PAY-120"]?["mine"] == "1" && meta["PAY-120"]?["priority"] == "Highest" && meta["PAY-120"]?["statusCategory"] == "new", "PAY-120 내 이슈·Highest", meta["PAY-120"] ?? [:])
        check(meta["PAY-100"]?["mine"] == "0" && meta["PAY-100"]?["assignee"] == nil && meta["PAY-100"]?["priority"] == "Medium", "PAY-100 담당자 없음", meta["PAY-100"] ?? [:])
        // v0.7 A: 담당자 이름·상태가 바뀐 시각, 그리고 Jira만 다시 받기(업그레이드 뒤 한 번)
        check(meta["PAY-150"]?["assigneeName"] == "김철수" && meta["PAY-150"]?["statusChanged"] == "2026-10-15T00:00:00Z", "PAY-150 assigneeName·statusChanged", meta["PAY-150"] ?? [:])
        check(meta["PAY-100"]?["statusChanged"] == nil && meta["PAY-100"]?["assigneeName"] == nil, "PAY-100은 새 키 없음", meta["PAY-100"] ?? [:])
        let stats = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(string: "http://127.0.0.1:\(port)/__stats")!)) as? [String: Any]
        let calls = stats?["calls"] as? [String: Int] ?? [:]
        check(calls["atlassianUserInfo"] == 1, "atlassianUserInfo는 동기화당 한 번", calls)
        let args = (stats?["args"] as? [String: Any])?["searchJiraIssuesUsingJql"] as? [String: Any]
        let fields = args?["fields"] as? [String] ?? []
        check(["priority", "duedate", "assignee", "status"].allSatisfy(fields.contains), "jiraFields에 priority·duedate·assignee", fields)
        let only = try await AtlassianMCPConnector(config: cfg, token: cred).syncJiraOnly(cursor: Date(timeIntervalSince1970: 1_700_000_000)) { _, _ in }
        check(only.upserts.allSatisfy { $0.kind == "jira" } && only.upserts.count == 4 && only.keepIDs == nil
              && only.cursor.timeIntervalSince1970 == 1_700_000_000, "syncJiraOnly: Jira 4개만·keepIDs 없음·cursor 유지", only.upserts.map { $0.id })
        // atlassianUserInfo가 실패하면 내 id를 모르므로 mine 키를 넣지 않는다(0으로 두지 않는다). 나머지 필드는 그대로.
        print("[내 계정 조회 실패]")
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/__config")!)
        req.httpMethod = "POST"; req.httpBody = Data("{\"user_fail\": true}".utf8)
        _ = try await URLSession.shared.data(for: req)
        let cred2 = try await MCPAuth.authorize(serverURL: serverURL, openURL: { u in Task.detached { _ = try? await URLSession.shared.data(from: u) } })
        let again = try await AtlassianMCPConnector(config: cfg, token: cred2).sync(since: nil) { _, _ in }
        let jira2 = again.upserts.filter { $0.kind == "jira" }
        check(jira2.count == 4 && jira2.allSatisfy { $0.meta?["mine"] == nil }, "mine 키 없음", jira2.map { $0.meta?["mine"] ?? "-" })
        check(jira2.allSatisfy { $0.meta?["status"] != nil && $0.meta?["priority"] != nil }, "나머지 meta는 그대로")
        req.httpBody = Data("{\"user_fail\": false}".utf8)
        _ = try await URLSession.shared.data(for: req)
    } catch {
        check(false, "동기화", error)
    }
    print(failed == 0 ? "\n통과" : "\n실패 \(failed)")
    exit(failed == 0 ? 0 : 1)
}
dispatchMain()
