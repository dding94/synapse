import Foundation

// v0.8 §6.2 — 사람이 승인한 Jira 변경 하나를 Atlassian에 쓴다 (E3). 부르는 곳은 JiraApply뿐이다.
// - .mcp 출처: Atlassian 원격 MCP 도구. 사이트(cloudId)는 AtlassianMCPConnector.site()로 얻고, 토큰 갱신은 커넥터의 MCPTokenBox가 맡는다.
//     transition: getJiraIssue(지금 상태) → getTransitionsForJiraIssue → transitionJiraIssue{cloudId, issueIdOrKey, transition:{id}}
//     comment:    addCommentToJiraIssue{cloudId, issueIdOrKey, commentBody, contentFormat:"markdown"}
//     create:     getJiraProjectIssueTypesMetadata(유형 이름 맞추기) → createJiraIssue{cloudId, projectKey, issueTypeName, summary, description, contentFormat:"markdown"}
// - .atlassian(API 토큰) 출처: REST v3 — GET/POST /rest/api/3/issue/{key}/transitions, POST /rest/api/3/issue/{key}/comment(문단 ADF),
//   GET /rest/api/3/issue/createmeta/{project}/issuetypes, POST /rest/api/3/issue.
// 토큰은 Authorization 헤더에만 쓰고 로그·오류 문구에는 남기지 않는다.
// 안전:
// - 쓰기 호출에서 답을 받지 못한 실패(연결 끊김·시간 초과·5xx)는 반영됐을 수도 있어 uncertain으로 알린다(화면: "Jira에서 확인해 주세요").
// - 전환은 늘 지금 상태부터 본다. 이미 그 상태면 다시 전환하지 않는다.
// - uncertain 실패 뒤 다시 반영할 때(retryUncertain)는 같은 댓글·같은 요약의 새 티켓이 이미 있는지 먼저 보고, 있으면 쓰지 않는다.
// - 쓰기 호출은 한 번만 한다(429처럼 서버가 처리하지 않았다고 분명히 알린 경우의 재시도는 연결기·여기의 HTTP 층이 맡는다).

/// Jira 반영 실패. message는 화면에 그대로 보여도 되는 한국어 한 문장. uncertain = 반영됐는지 알 수 없다.
struct JiraWriteError: Error, LocalizedError, CustomStringConvertible {
    let message: String
    var uncertain = false
    init(_ message: String, uncertain: Bool = false) { self.message = message; self.uncertain = uncertain }
    var errorDescription: String? { message }
    var description: String { message }

    static let unknownResult = "반영 결과를 확인하지 못했어요 — Jira에서 확인해 주세요"
}

/// 반영할 일 하나 (사서 제안의 payload에서 만든다). 사서가 이미 검사했지만 쓰기 직전에 모양을 한 번 더 본다.
struct JiraJob {
    let op: String              // transition | comment | create
    let key: String             // transition·comment
    let to: String              // transition: 바꿀 상태 이름
    let body: String            // comment (마크다운)
    let project: String         // create
    let issueType: String       // create (기본 "작업")
    let summary: String         // create
    let description: String     // create (마크다운, 비어도 된다)
    let retryUncertain: Bool    // 지난 반영이 uncertain으로 끝났다 → 이미 반영됐는지 먼저 본다

    init(_ p: [String: Any]) throws {
        func s(_ k: String) -> String { ((p[k] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        op = s("op")
        key = s("key").uppercased()
        to = s("to")
        body = s("body")
        project = s("project").uppercased()
        let t = s("issueType")
        issueType = t.isEmpty ? "작업" : t
        summary = s("summary")
        description = s("description")
        retryUncertain = (p["retryUncertain"] as? Bool) ?? false
        switch op {
        case "transition", "comment":
            guard JiraWriter.isIssueKey(key) else { throw JiraWriteError("Jira 키가 올바르지 않아요.") }
            if op == "transition" && (to.isEmpty || to.count > 100) { throw JiraWriteError("바꿀 상태 이름이 없어요.") }
            if op == "comment" && !(1...4000).contains(body.count) { throw JiraWriteError("댓글은 1~4,000자여야 해요.") }
        case "create":
            guard JiraWriter.isProjectKey(project) else { throw JiraWriteError("Jira 프로젝트 키가 올바르지 않아요.") }
            guard (1...200).contains(summary.count), !summary.contains("\n") else { throw JiraWriteError("새 티켓 요약은 한 줄 1~200자여야 해요.") }
            guard description.count <= 8000 else { throw JiraWriteError("새 티켓 설명은 8,000자 이하여야 해요.") }
            guard issueType.count <= 50 else { throw JiraWriteError("유형 이름이 너무 길어요.") }
        default:
            throw JiraWriteError("알 수 없는 Jira 변경이에요.")
        }
    }
}

enum JiraWriter {

    /// 반영 결과: {message, key, url?, to?(전환한 상태 이름), commentId?, issueType?(만든 유형), already?(이미 반영돼 있어 쓰지 않음)}
    /// onWrite: 쓰기 호출을 보내기 바로 전에 불린다(그 전에 멈추면 Jira는 바뀌지 않은 것이 분명하다 — JiraApply의 시간 제한이 쓴다).
    static func apply(_ p: [String: Any], source: SourceConfig, token: String, onWrite: (() -> Void)? = nil) async throws -> [String: Any] {
        let job = try JiraJob(p)
        let mark = onWrite ?? {}
        switch source.kind {
        case .mcp: return try await MCPJiraWriter(source: source, token: token, onWrite: mark).run(job)
        case .atlassian: return try await RESTJiraWriter(source: source, token: token, onWrite: mark).run(job)
        default: throw JiraWriteError("Jira에 반영할 수 있는 연결이 아니에요.")
        }
    }

    /// 실패를 화면 문구와 uncertain으로. JiraWriteError가 아닌 것은 여기 오기 전에 바꿔 두지만, 남은 것도 한국어로 돌려준다.
    static func describe(_ e: Error) -> (message: String, uncertain: Bool) {
        if let w = e as? JiraWriteError { return (w.message, w.uncertain) }
        if e is CancellationError { return (JiraWriteError.unknownResult, true) }
        if let m = e as? MCPError { return (m.message, false) }
        return (Library.message(for: e, fallback: "Jira에 반영하지 못했어요."), false)
    }

    // MARK: 이름·키

    /// 상태·유형 이름 비교용: 대소문자·앞뒤 공백·"#" 무시(가운데 공백은 하나로).
    static func statusKey(_ s: String) -> String {
        s.replacingOccurrences(of: "#", with: "").lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func isIssueKey(_ s: String) -> Bool {
        s.range(of: "^[A-Z][A-Z0-9_]*-[0-9]+$", options: .regularExpression) != nil && s.count <= 40
    }

    static func isProjectKey(_ s: String) -> Bool {
        s.range(of: "^[A-Z][A-Z0-9_]*$", options: .regularExpression) != nil && s.count <= 30
    }

    static func browseURL(_ site: String, _ key: String) -> String {
        var base = site
        while base.hasSuffix("/") { base.removeLast() }
        return base + "/browse/" + key
    }

    // MARK: 조사 (받침에 따라). 한글 음절·숫자는 읽는 소리로 고르고, 그 밖(영문 등)은 둘 다 쓴다.

    /// 마지막 글자의 종성 번호: nil = 알 수 없음, 0 = 받침 없음, 8 = ㄹ.
    private static func jong(_ word: String) -> Int? {
        let skip = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
        guard let last = word.unicodeScalars.reversed().first(where: { !skip.contains($0) }) else { return nil }
        let v = last.value
        if v >= 0xAC00 && v <= 0xD7A3 { return Int((v - 0xAC00) % 28) }
        if v >= 0x30 && v <= 0x39 { return [21, 8, 0, 16, 0, 0, 1, 8, 8, 0][Int(v - 0x30)] }   // 영 일 이 삼 사 오 육 칠 팔 구
        return nil
    }
    /// (으)로
    static func ro(_ w: String) -> String { guard let j = jong(w) else { return "(으)로" }; return j == 0 || j == 8 ? "로" : "으로" }
    /// 을/를
    static func eul(_ w: String) -> String { guard let j = jong(w) else { return "을(를)" }; return j == 0 ? "를" : "을" }
    /// 은/는
    static func eun(_ w: String) -> String { guard let j = jong(w) else { return "은(는)" }; return j == 0 ? "는" : "은" }
    /// 이/가
    static func iga(_ w: String) -> String { guard let j = jong(w) else { return "이(가)" }; return j == 0 ? "가" : "이" }

    // MARK: 결과 읽기 (MCP·REST 공용, 모양이 조금씩 달라도 읽는다)

    struct Transition { let id: String; let name: String; let toName: String }

    static func idString(_ v: Any?) -> String? {
        if let s = v as? String, !s.isEmpty { return s }
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.stringValue }
        return nil
    }

    private static func unwrap(_ v: Any?, _ keys: [String]) -> [String: Any]? {
        guard var d = v as? [String: Any] else { return nil }
        for k in ["data", "result", "issue"] where keys.allSatisfy({ d[$0] == nil }) {
            if let inner = d[k] as? [String: Any] { d = inner }
        }
        return d
    }

    /// 전환 목록. nil = 모양을 알 수 없음, [] = 바꿀 수 있는 상태가 없음.
    static func parseTransitions(_ v: Any?) -> [Transition]? {
        var list: [Any]
        if let a = v as? [Any] { list = a }
        else if let d = unwrap(v, ["transitions"]), let a = (d["transitions"] as? [Any]) ?? (d["values"] as? [Any]) { list = a }
        else { return nil }
        var out: [Transition] = []
        for case let t as [String: Any] in list {
            guard let id = idString(t["id"]) else { continue }
            let name = ((t["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let to = (((t["to"] as? [String: Any])?["name"] as? String) ?? name).trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty && to.isEmpty { continue }
            out.append(Transition(id: id, name: name, toName: to.isEmpty ? name : to))
        }
        return out
    }

    /// 바꿀 상태 이름과 맞는 전환: 도착 상태(to.name)가 먼저, 그다음 전환 이름(name).
    static func pick(_ ts: [Transition], _ target: String) -> Transition? {
        let k = statusKey(target)
        return ts.first { statusKey($0.toName) == k } ?? ts.first { statusKey($0.name) == k }
    }

    static func noTransition(_ to: String, _ ts: [Transition]) -> JiraWriteError {
        var seen = Set<String>(), names: [String] = []
        for t in ts where seen.insert(statusKey(t.toName)).inserted { names.append(t.toName) }
        let head = "‘\(to)’\(ro(to)) 바꿀 수 없어요."
        return JiraWriteError(names.isEmpty ? head + " 지금 바꿀 수 있는 상태가 없어요." : head + " 가능한 상태: " + names.joined(separator: ", "))
    }

    /// 이슈 조회 결과의 지금 상태 이름.
    static func issueStatus(_ v: Any?) -> String? {
        guard let d = unwrap(v, ["fields", "status"]) else { return nil }
        let st = ((d["fields"] as? [String: Any])?["status"] as? [String: Any]) ?? (d["status"] as? [String: Any])
        if let n = st?["name"] as? String, !n.isEmpty { return n }
        if let n = ((d["fields"] as? [String: Any])?["status"] as? String) ?? (d["status"] as? String), !n.isEmpty { return n }
        return nil
    }

    /// 이슈 조회(fields comment) 또는 댓글 목록 결과의 댓글 본문들(평문).
    static func commentBodies(_ v: Any?) -> [String] {
        var list: [Any] = []
        if let a = v as? [Any] { list = a }
        else if let d = unwrap(v, ["fields", "comments", "comment"]) {
            let f = (d["fields"] as? [String: Any]) ?? d
            if let c = f["comment"] as? [String: Any] { list = (c["comments"] as? [Any]) ?? [] }
            else if let c = f["comment"] as? [Any] { list = c }
            else if let c = f["comments"] as? [Any] { list = c }
        }
        return list.compactMap { ($0 as? [String: Any])?["body"] }.map { AtlassianText.adfToText($0) }
    }

    /// 댓글 같은지: 마크다운 기호·공백·대소문자를 빼고 비교한다(마크다운이 ADF를 거쳐 돌아오며 모양이 조금 바뀌어도 같게 본다).
    static func normalizedBody(_ s: String) -> String {
        let drop = CharacterSet(charactersIn: "*_`~#>[]()|\\-+!").union(.whitespacesAndNewlines)
        return String(String.UnicodeScalarView(s.lowercased().unicodeScalars.filter { !drop.contains($0) }))
    }

    /// 새로 만든 이슈의 키. 결과 JSON의 key, 없으면 글에서 그 프로젝트의 키를 찾는다.
    static func createdKey(_ v: Any?, text: String, project: String) -> String? {
        if let d = unwrap(v, ["key"]), let k = d["key"] as? String, isIssueKey(k) { return k }
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: project) + "-[0-9]+\\b"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range)
    }

    struct IssueType { let id: String?; let name: String; let subtask: Bool }

    /// 프로젝트 유형 메타데이터 → 유형 목록 (createmeta/{project}/issuetypes·옛 createmeta·MCP 모양 모두).
    static func parseIssueTypes(_ v: Any?) -> [IssueType] {
        var list: [Any] = []
        if let a = v as? [Any] { list = a }
        else if let d = unwrap(v, ["issueTypes", "issuetypes", "values", "projects"]) {
            if let a = (d["issueTypes"] as? [Any]) ?? (d["issuetypes"] as? [Any]) ?? (d["values"] as? [Any]) ?? (d["results"] as? [Any]) { list = a }
            else if let p = (d["projects"] as? [[String: Any]])?.first, let a = p["issuetypes"] as? [Any] { list = a }
        }
        return list.compactMap { x in
            guard let t = x as? [String: Any], let n = t["name"] as? String, !n.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return IssueType(id: idString(t["id"]), name: n, subtask: (t["subtask"] as? Bool) ?? false)
        }
    }

    private static let typeSynonyms: [Set<String>] = [["작업", "task"], ["버그", "bug"], ["스토리", "story"], ["에픽", "epic"],
                                                      ["하위 작업", "subtask", "sub-task"], ["개선", "improvement"], ["새 기능", "new feature"]]

    /// 바라는 유형 이름을 프로젝트 유형과 맞춘다(docs/V08.md §6.1): 같은 이름 → 같은 뜻(작업↔Task 등) → 없으면 Task(작업).
    /// fallback = 바라는 유형이 없어 Task로 대신했다(결과 문구에 알린다). Task도 없으면 nil.
    static func chooseIssueType(_ types: [IssueType], wanted: String) -> (type: IssueType, fallback: Bool)? {
        let w = statusKey(wanted)
        if let t = types.first(where: { statusKey($0.name) == w }) { return (t, false) }
        if let group = typeSynonyms.first(where: { $0.contains(w) }), let t = types.first(where: { group.contains(statusKey($0.name)) }) { return (t, false) }
        let normal = types.filter { !$0.subtask }
        guard let t = normal.first(where: { statusKey($0.name) == "task" }) ?? normal.first(where: { statusKey($0.name) == "작업" }) else { return nil }
        return (t, true)
    }

    static func noIssueType(_ project: String, _ wanted: String, _ types: [IssueType]) -> JiraWriteError {
        let names = types.filter { !$0.subtask }.map { $0.name }
        return JiraWriteError("\(project)에는 ‘\(wanted)’ 유형이 없어요." + (names.isEmpty ? "" : " 가능한 유형: " + names.joined(separator: ", ")))
    }

    /// 최근 이슈 목록(검색 결과)에서 요약이 같은 것의 키.
    static func sameSummaryKey(_ v: Any?, summary: String) -> String? {
        guard let page = AtlassianMCPConnector.parseIssues(v) else { return nil }
        let want = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        for i in page.issues {
            let s = (((i["fields"] as? [String: Any])?["summary"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if s == want, let k = i["key"] as? String, isIssueKey(k) { return k }
        }
        return nil
    }

    /// uncertain 뒤 새 티켓을 다시 만들기 전에 찾아볼 검색 결과 쪽 수(한 쪽 50개).
    static let recentPages = 4

    /// uncertain 뒤 새 티켓을 다시 만들기 전에 찾는 JQL: 이 프로젝트에서 내가 이틀 안에 만든 이슈.
    static func recentMineJQL(_ project: String) -> String {
        "project = \"\(project)\" AND reporter = currentUser() AND created >= -2d ORDER BY created DESC"
    }

    // MARK: 결과 문구

    static func transitioned(_ key: String, _ name: String, site: String) -> [String: Any] {
        ["message": "\(key) 상태를 ‘\(name)’\(ro(name)) 바꿨어요", "key": key, "url": browseURL(site, key), "to": name]
    }
    static func alreadyInStatus(_ key: String, _ name: String, site: String) -> [String: Any] {
        ["message": "\(key)\(eun(key)) 이미 ‘\(name)’ 상태예요 · 바꾸지 않았어요", "key": key, "url": browseURL(site, key), "to": name, "already": true]
    }
    static func commented(_ key: String, _ commentId: String?, site: String) -> [String: Any] {
        var url = browseURL(site, key)
        if let c = commentId, c.allSatisfy({ $0.isNumber }) { url += "?focusedCommentId=" + c }
        return ["message": "\(key)에 댓글을 달았어요", "key": key, "url": url, "commentId": commentId ?? NSNull()]
    }
    static func alreadyCommented(_ key: String, site: String) -> [String: Any] {
        ["message": "\(key)에 같은 댓글이 이미 있어요 · 다시 달지 않았어요", "key": key, "url": browseURL(site, key), "already": true]
    }
    /// fallbackFrom: 바라는 유형이 프로젝트에 없어 Task로 만들었을 때 그 원래 이름.
    static func created(_ project: String, _ key: String?, type: String, site: String, fallbackFrom: String? = nil) -> [String: Any] {
        let note = fallbackFrom.map { " · ‘\($0)’ 유형이 없어 ‘\(type)’\(ro(type)) 만들었어요" } ?? ""
        guard let k = key else {
            return ["message": "\(project)에 새 티켓을 만들었어요 · 새 키는 Jira에서 확인해 주세요" + note, "key": NSNull(), "project": project, "issueType": type]
        }
        return ["message": "\(project)에 새 티켓 \(k)\(eul(k)) 만들었어요" + note, "key": k, "url": browseURL(site, k), "project": project, "issueType": type]
    }
    static func alreadyCreated(_ project: String, _ key: String, site: String) -> [String: Any] {
        ["message": "\(project)에 요약이 같은 티켓 \(key)\(iga(key)) 이미 있어요 · 다시 만들지 않았어요", "key": key, "url": browseURL(site, key),
         "project": project, "already": true]
    }

    // MARK: MCP 오류 → 한국어

    /// 도구 오류(isError)를 연결기가 MCPError(.tool)로 바꿀 때 괄호 안에 붙인 서버 글을 꺼낸다.
    static func toolDetail(_ m: MCPError) -> String {
        if let open = m.message.firstIndex(of: "("), m.message.hasSuffix(")") {
            return String(m.message[m.message.index(after: open)..<m.message.index(before: m.message.endIndex)])
        }
        return MCPError.detail(m.message)
    }

    /// 읽기 단계(사이트·상태·전환 목록·유형·확인) 실패 — 쓰기 전이라 Jira는 바뀌지 않았다.
    static func readFailure(_ e: Error, key: String) -> JiraWriteError {
        if let w = e as? JiraWriteError { return JiraWriteError(w.message) }
        if e is CancellationError { return JiraWriteError("반영을 멈췄어요. Jira는 바뀌지 않았어요.") }
        if let m = e as? MCPError {
            switch m.kind {
            case .notFound where !key.isEmpty: return JiraWriteError("Jira에서 \(key)\(eul(key)) 찾지 못했어요.")
            case .permission where !key.isEmpty: return JiraWriteError("이 계정에는 \(key)\(eul(key)) 볼 권한이 없어요. Atlassian 권한을 확인해 주세요.")
            case .tool: return JiraWriteError("Jira가 요청을 거절했어요: \(toolDetail(m))")
            default: return JiraWriteError(m.message)
            }
        }
        return JiraWriteError(Library.message(for: e, fallback: "Jira에 연결하지 못했어요."))
    }

    /// 입력 검증 거절(Jira가 아무것도 바꾸지 않은 것)로 보이는 도구 오류 글. "invalid" 하나로는 보지 않는다(게이트웨이 오류 글에도 나온다).
    static func isInputRejection(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["specify a valid", "is not valid", "is required", "required field", "not allowed", "does not exist", "unknown field",
                "cannot be empty", "field '", "필수", "올바르지 않"].contains { t.contains($0) }
    }

    /// 쓰기 단계 실패. 서버가 분명히 거절한 것(권한·없음·로그인·속도 제한·400·JSON-RPC 오류)은 반영 안 됨,
    /// 답을 받지 못한 것(연결 끊김·시간 초과·5xx·응답 깨짐)과 쓰기 뒤의 도구 오류(isError — 처리한 뒤 실패를 돌려줬을 수 있다)는 uncertain.
    /// action: 권한 오류 문구에 들어갈 말 ("PROJ-1을 바꿀", "PROJ-1에 댓글을 달", "PROJ에 새 티켓을 만들").
    static func writeFailure(_ e: Error, target: String, action: String) -> JiraWriteError {
        if let w = e as? JiraWriteError { return w }
        if e is CancellationError { return JiraWriteError(JiraWriteError.unknownResult, uncertain: true) }
        if let m = e as? MCPError {
            switch m.kind {
            case .reLogin, .rateLimited, .config, .cancelled: return JiraWriteError(m.message)
            case .permission: return JiraWriteError("이 계정에는 \(action) 권한이 없어요. Atlassian 권한을 확인해 주세요.")
            case .notFound: return JiraWriteError("Jira에서 \(target)\(eul(target)) 찾지 못했어요.")
            // 쓰기 뒤 도구 오류는 Jira가 이미 처리한 뒤일 수 있다(게이트웨이 시간 초과 등) → 결과 모름으로 두고, 다시 할 때 중복을 먼저 본다.
            // 다만 입력이 틀려 거절된 것(유형·필수 값·없는 필드)은 Jira가 아무것도 바꾸지 않았으니 확실한 실패로 알린다.
            case .tool:
                let d = toolDetail(m)
                if JiraWriter.isInputRejection(d) { return JiraWriteError("Jira가 요청을 거절했어요: \(d)") }
                return JiraWriteError(JiraWriteError.unknownResult + " (\(d))", uncertain: true)
            case .protocolError where m.status == 400 || m.message.hasPrefix("MCP 서버가 요청을 처리하지 못했어요"):
                return JiraWriteError(m.message)
            default:
                return JiraWriteError(JiraWriteError.unknownResult + " (\(MCPError.detail(m.message)))", uncertain: true)
            }
        }
        return JiraWriteError(JiraWriteError.unknownResult, uncertain: true)
    }
}

// MARK: - Atlassian 원격 MCP

private struct MCPJiraWriter {
    let conn: AtlassianMCPConnector
    let onWrite: () -> Void

    init(source: SourceConfig, token: String, onWrite: @escaping () -> Void) {
        conn = AtlassianMCPConnector(config: source, token: token)
        self.onWrite = onWrite
    }

    /// 반영 하나가 끝나면(성공·실패 모두) 원격 MCP 세션을 닫는다.
    func run(_ j: JiraJob) async throws -> [String: Any] {
        do {
            let r = try await runOps(j)
            await conn.close()
            return r
        } catch {
            await conn.close()
            throw error
        }
    }

    private func runOps(_ j: JiraJob) async throws -> [String: Any] {
        let site: AtlassianMCPConnector.Site
        do { site = try await conn.site() } catch { throw JiraWriter.readFailure(error, key: "") }
        switch j.op {
        case "transition": return try await transition(j, site)
        case "comment": return try await comment(j, site)
        default: return try await create(j, site)
        }
    }

    private func transition(_ j: JiraJob, _ site: AtlassianMCPConnector.Site) async throws -> [String: Any] {
        // 지금 상태를 먼저 본다(못 읽으면 전환 목록으로 계속). 이미 그 상태면 쓰지 않는다.
        if let r = try? await conn.tool("getJiraIssue", ["cloudId": site.cloudId, "issueIdOrKey": j.key, "fields": ["status"]]),
           let cur = JiraWriter.issueStatus(r.json), JiraWriter.statusKey(cur) == JiraWriter.statusKey(j.to) {
            return JiraWriter.alreadyInStatus(j.key, cur, site: site.url)
        }
        let list: MCPToolResult
        do { list = try await conn.tool("getTransitionsForJiraIssue", ["cloudId": site.cloudId, "issueIdOrKey": j.key]) }
        catch { throw JiraWriter.readFailure(error, key: j.key) }
        guard let ts = JiraWriter.parseTransitions(list.json) else { throw JiraWriteError("\(j.key)의 상태 목록을 읽지 못했어요. 다시 시도해 주세요.") }
        guard let t = JiraWriter.pick(ts, j.to) else { throw JiraWriter.noTransition(j.to, ts) }
        onWrite()
        do { _ = try await conn.tool("transitionJiraIssue", ["cloudId": site.cloudId, "issueIdOrKey": j.key, "transition": ["id": t.id]], retry: false) }
        catch { throw JiraWriter.writeFailure(error, target: j.key, action: "\(j.key)\(JiraWriter.eul(j.key)) 바꿀") }
        return JiraWriter.transitioned(j.key, t.toName, site: site.url)
    }

    private func comment(_ j: JiraJob, _ site: AtlassianMCPConnector.Site) async throws -> [String: Any] {
        if j.retryUncertain {
            // 지난 반영의 결과를 몰랐다: 같은 댓글이 이미 있으면 다시 달지 않는다. 확인하지 못하면 달지 않고 실패로 둔다.
            let r: MCPToolResult
            do {
                r = try await conn.tool("getJiraIssue", ["cloudId": site.cloudId, "issueIdOrKey": j.key, "fields": ["comment"],
                                                         "responseContentFormat": "markdown"])
            } catch { throw JiraWriteError("지난 반영이 됐는지 확인하지 못해 다시 달지 않았어요 — Jira에서 확인해 주세요 (\(JiraWriter.readFailure(error, key: j.key).message))") }
            let want = JiraWriter.normalizedBody(j.body)
            if JiraWriter.commentBodies(r.json).contains(where: { JiraWriter.normalizedBody($0) == want }) {
                return JiraWriter.alreadyCommented(j.key, site: site.url)
            }
        }
        let r: MCPToolResult
        onWrite()
        do {
            r = try await conn.tool("addCommentToJiraIssue", ["cloudId": site.cloudId, "issueIdOrKey": j.key, "commentBody": j.body,
                                                              "contentFormat": "markdown"], retry: false)
        } catch { throw JiraWriter.writeFailure(error, target: j.key, action: "\(j.key)에 댓글을 달") }
        return JiraWriter.commented(j.key, JiraWriter.idString((r.json as? [String: Any])?["id"]), site: site.url)
    }

    private func create(_ j: JiraJob, _ site: AtlassianMCPConnector.Site) async throws -> [String: Any] {
        if j.retryUncertain {
            // 지난 반영의 결과를 몰랐다: 내가 이틀 안에 만든 이슈 중 요약이 같은 것이 있으면 다시 만들지 않는다(쪽을 넘기며 최대 4쪽).
            var token: String? = nil
            pages: for _ in 0..<JiraWriter.recentPages {
                var args: [String: Any] = ["cloudId": site.cloudId, "jql": JiraWriter.recentMineJQL(j.project), "fields": ["summary"],
                                           "maxResults": 50, "responseContentFormat": "markdown"]
                if let t = token { args["nextPageToken"] = t }
                let r: MCPToolResult
                do { r = try await conn.tool("searchJiraIssuesUsingJql", args) }
                catch { throw JiraWriteError("지난 반영이 됐는지 확인하지 못해 다시 만들지 않았어요 — Jira에서 확인해 주세요 (\(JiraWriter.readFailure(error, key: "").message))") }
                if let k = JiraWriter.sameSummaryKey(r.json, summary: j.summary) { return JiraWriter.alreadyCreated(j.project, k, site: site.url) }
                guard let page = AtlassianMCPConnector.parseIssues(r.json), !page.issues.isEmpty, !page.isLast, let n = page.next, n != token else { break pages }
                token = n
            }
        }
        // 유형 이름을 프로젝트 유형과 맞춘다. 메타데이터를 못 읽으면 바라는 이름 그대로 보낸다(틀리면 Jira가 거절한다).
        var typeName = j.issueType
        var fallbackFrom: String? = nil
        if let r = try? await conn.tool("getJiraProjectIssueTypesMetadata", ["cloudId": site.cloudId, "projectIdOrKey": j.project]) {
            let types = JiraWriter.parseIssueTypes(r.json)
            if !types.isEmpty {
                guard let c = JiraWriter.chooseIssueType(types, wanted: j.issueType) else { throw JiraWriter.noIssueType(j.project, j.issueType, types) }
                typeName = c.type.name
                if c.fallback { fallbackFrom = j.issueType }
            }
        }
        var args: [String: Any] = ["cloudId": site.cloudId, "projectKey": j.project, "issueTypeName": typeName, "summary": j.summary,
                                   "contentFormat": "markdown"]
        if !j.description.isEmpty { args["description"] = j.description }
        let r: MCPToolResult
        onWrite()
        do { r = try await conn.tool("createJiraIssue", args, retry: false) }
        catch { throw JiraWriter.writeFailure(error, target: j.project, action: "\(j.project)에 새 티켓을 만들") }
        return JiraWriter.created(j.project, JiraWriter.createdKey(r.json, text: r.text, project: j.project), type: typeName, site: site.url,
                                  fallbackFrom: fallbackFrom)
    }
}

// MARK: - Atlassian REST v3 (API 토큰)

private final class RESTJiraWriter {
    private let site: URL
    private let auth: String
    private let session: URLSession
    private let onWrite: () -> Void

    init(source: SourceConfig, token: String, onWrite: @escaping () -> Void) throws {
        guard let s = AtlassianConnector.normalizedSite(source.site ?? "") else { throw JiraWriteError("Atlassian 사이트 주소를 확인해 주세요.") }
        site = s
        self.onWrite = onWrite
        let raw = "\((source.email ?? "").trimmingCharacters(in: .whitespaces)):\(token.trimmingCharacters(in: .whitespacesAndNewlines))"
        auth = "Basic " + Data(raw.utf8).base64EncodedString()
        session = MCPHTTP.makeSession(requestTimeout: 30, guardRedirects: true)   // 쿠키·캐시 없음, 다른 호스트로 리디렉트 막음
    }

    deinit { session.invalidateAndCancel() }

    private var siteString: String { site.absoluteString }
    private func issuePath(_ key: String, _ tail: String = "") -> String { "/rest/api/3/issue/" + AtlassianConnector.enc(key) + tail }

    func run(_ j: JiraJob) async throws -> [String: Any] {
        switch j.op {
        case "transition": return try await transition(j)
        case "comment": return try await comment(j)
        default: return try await create(j)
        }
    }

    private func transition(_ j: JiraJob) async throws -> [String: Any] {
        if let v = try? await send(issuePath(j.key), query: "fields=status", write: false, target: j.key),
           let cur = JiraWriter.issueStatus(v), JiraWriter.statusKey(cur) == JiraWriter.statusKey(j.to) {
            return JiraWriter.alreadyInStatus(j.key, cur, site: siteString)
        }
        let v = try await send(issuePath(j.key, "/transitions"), write: false, target: j.key)
        guard let ts = JiraWriter.parseTransitions(v) else { throw JiraWriteError("\(j.key)의 상태 목록을 읽지 못했어요. 다시 시도해 주세요.") }
        guard let t = JiraWriter.pick(ts, j.to) else { throw JiraWriter.noTransition(j.to, ts) }
        _ = try await send(issuePath(j.key, "/transitions"), method: "POST", body: ["transition": ["id": t.id]], write: true, target: j.key,
                           action: "\(j.key)\(JiraWriter.eul(j.key)) 바꿀")
        return JiraWriter.transitioned(j.key, t.toName, site: siteString)
    }

    private func comment(_ j: JiraJob) async throws -> [String: Any] {
        if j.retryUncertain {
            let v: Any?
            do { v = try await send(issuePath(j.key, "/comment"), query: "orderBy=-created&maxResults=50", write: false, target: j.key) }
            catch { throw JiraWriteError("지난 반영이 됐는지 확인하지 못해 다시 달지 않았어요 — Jira에서 확인해 주세요 (\(JiraWriter.describe(error).message))") }
            let want = JiraWriter.normalizedBody(j.body)
            let bodies = ((v as? [String: Any])?["comments"] as? [[String: Any]] ?? []).map { AtlassianText.adfToText($0["body"]) }
            if bodies.contains(where: { JiraWriter.normalizedBody($0) == want }) { return JiraWriter.alreadyCommented(j.key, site: siteString) }
        }
        let v = try await send(issuePath(j.key, "/comment"), method: "POST", body: ["body": RESTJiraWriter.adf(j.body)], write: true,
                               target: j.key, action: "\(j.key)에 댓글을 달")
        return JiraWriter.commented(j.key, JiraWriter.idString((v as? [String: Any])?["id"]), site: siteString)
    }

    private func create(_ j: JiraJob) async throws -> [String: Any] {
        if j.retryUncertain {
            var token: String? = nil
            pages: for _ in 0..<JiraWriter.recentPages {
                var body: [String: Any] = ["jql": JiraWriter.recentMineJQL(j.project), "fields": ["summary"], "maxResults": 50]
                if let t = token { body["nextPageToken"] = t }
                let v: Any?
                do { v = try await send("/rest/api/3/search/jql", method: "POST", body: body, write: false, target: j.project) }
                catch { throw JiraWriteError("지난 반영이 됐는지 확인하지 못해 다시 만들지 않았어요 — Jira에서 확인해 주세요 (\(JiraWriter.describe(error).message))") }
                if let k = JiraWriter.sameSummaryKey(v, summary: j.summary) { return JiraWriter.alreadyCreated(j.project, k, site: siteString) }
                guard let page = AtlassianMCPConnector.parseIssues(v), !page.issues.isEmpty, !page.isLast, let n = page.next, n != token else { break pages }
                token = n
            }
        }
        var issueType: [String: Any] = ["name": j.issueType]
        var typeName = j.issueType
        var fallbackFrom: String? = nil
        if let v = try? await send("/rest/api/3/issue/createmeta/" + AtlassianConnector.enc(j.project) + "/issuetypes", write: false, target: j.project) {
            let types = JiraWriter.parseIssueTypes(v)
            if !types.isEmpty {
                guard let c = JiraWriter.chooseIssueType(types, wanted: j.issueType) else { throw JiraWriter.noIssueType(j.project, j.issueType, types) }
                typeName = c.type.name
                issueType = c.type.id.map { ["id": $0] } ?? ["name": c.type.name]
                if c.fallback { fallbackFrom = j.issueType }
            }
        }
        var fields: [String: Any] = ["project": ["key": j.project], "issuetype": issueType, "summary": j.summary]
        if !j.description.isEmpty { fields["description"] = RESTJiraWriter.adf(j.description) }
        let v = try await send("/rest/api/3/issue", method: "POST", body: ["fields": fields], write: true, target: j.project,
                               action: "\(j.project)에 새 티켓을 만들")
        return JiraWriter.created(j.project, JiraWriter.createdKey(v, text: "", project: j.project), type: typeName, site: siteString,
                                  fallbackFrom: fallbackFrom)
    }

    /// 평문(마크다운) → 문단 ADF. 빈 줄로 문단을 나누고, 문단 안 줄바꿈은 hardBreak. 빈 text 노드는 만들지 않는다.
    static func adf(_ text: String) -> [String: Any] {
        let norm = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var paragraphs: [[String: Any]] = []
        var lines: [String] = []
        func flush() {
            guard !lines.isEmpty else { return }
            var nodes: [[String: Any]] = []
            for (i, l) in lines.enumerated() {
                if i > 0 { nodes.append(["type": "hardBreak"]) }
                nodes.append(["type": "text", "text": l])
            }
            paragraphs.append(["type": "paragraph", "content": nodes])
            lines = []
        }
        for l in norm.components(separatedBy: "\n") {
            if l.trimmingCharacters(in: .whitespaces).isEmpty { flush() } else { lines.append(l) }
        }
        flush()
        return ["type": "doc", "version": 1, "content": paragraphs]
    }

    private static func detail(_ data: Data) -> String {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        var bits = (o["errorMessages"] as? [String]) ?? []
        for (k, v) in (o["errors"] as? [String: Any]) ?? [:] { bits.append("\(k): \(v)") }
        return MCPError.detail(bits.joined(separator: " · "))
    }

    private static func networkMessage(_ e: URLError) -> String {
        switch e.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: return "인터넷에 연결되어 있지 않아요."
        case .timedOut: return "응답이 너무 늦어요. 잠시 후 다시 시도해 주세요."
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return "Atlassian 사이트에 연결하지 못했어요. 주소를 확인해 주세요."
        default: return "네트워크 오류가 생겼어요. 잠시 후 다시 시도해 주세요."
        }
    }

    /// 요청 하나. 429는 Retry-After만큼 쉬고 3번까지 다시(서버가 처리하지 않았다고 알린 것이라 쓰기도 안전하다).
    /// write = 쓰기 호출: 답을 받지 못한 실패·5xx는 uncertain. 응답 JSON(없으면 [:])을 돌려준다.
    private func send(_ path: String, query: String? = nil, method: String = "GET", body: Any? = nil,
                      write: Bool, target: String, action: String? = nil) async throws -> Any? {
        var c = URLComponents(url: site, resolvingAgainstBaseURL: false)!
        c.percentEncodedPath = path
        c.percentEncodedQuery = query
        guard let url = c.url else { throw JiraWriteError("Atlassian 사이트 주소를 확인해 주세요.") }
        var attempt = 0
        while true {
            try Task.checkCancellation()
            if write { onWrite() }
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            req.httpMethod = method
            req.setValue(auth, forHTTPHeaderField: "Authorization")
            req.setValue("Synapse/0.8", forHTTPHeaderField: "User-Agent")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if let b = body {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: b)
            }
            let data: Data, resp: URLResponse
            do {
                (data, resp) = try await session.data(for: req)
            } catch let e as URLError where e.code == .cancelled {
                if write { throw JiraWriteError(JiraWriteError.unknownResult, uncertain: true) }
                throw CancellationError()
            } catch let e as URLError {
                if write { throw JiraWriteError(JiraWriteError.unknownResult + " (" + RESTJiraWriter.networkMessage(e) + ")", uncertain: true) }
                throw JiraWriteError(RESTJiraWriter.networkMessage(e))
            } catch is CancellationError {
                if write { throw JiraWriteError(JiraWriteError.unknownResult, uncertain: true) }
                throw CancellationError()
            } catch {
                if write { throw JiraWriteError(JiraWriteError.unknownResult, uncertain: true) }
                throw JiraWriteError("네트워크 오류가 생겼어요. 잠시 후 다시 시도해 주세요.")
            }
            guard let http = resp as? HTTPURLResponse else {
                throw JiraWriteError(write ? JiraWriteError.unknownResult : "Atlassian 응답을 읽지 못했어요.", uncertain: write)
            }
            let code = http.statusCode
            switch code {
            case 200..<300:
                if data.isEmpty { return [String: Any]() }
                if let o = try? JSONSerialization.jsonObject(with: data) { return o }
                if write { return [String: Any]() }      // 쓰기는 2xx면 반영된 것이다(본문이 JSON이 아니어도)
                throw JiraWriteError("Atlassian 응답을 읽지 못했어요. 사이트 주소를 확인해 주세요.")
            case 401:
                throw JiraWriteError("Atlassian 토큰이 맞지 않아요. 자료 화면에서 연결을 확인해 주세요.")
            case 403:
                throw JiraWriteError("이 계정에는 \(action ?? "\(target)\(JiraWriter.eul(target)) 볼") 권한이 없어요. Jira 권한을 확인해 주세요.")
            case 404:
                throw JiraWriteError("Jira에서 \(target)\(JiraWriter.eul(target)) 찾지 못했어요.")
            case 429:
                if attempt >= 3 { throw JiraWriteError("요청이 너무 많아 잠시 막혔어요. 몇 분 뒤 다시 시도해 주세요.") }
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(MCPHTTP.retryAfter(http) * 1_000_000_000))
            case 400, 409, 422:
                let d = RESTJiraWriter.detail(data)
                throw JiraWriteError("Jira가 요청을 거절했어요" + (d.isEmpty ? ". (\(code))" : ": " + d))
            case 500..<600:
                if write { throw JiraWriteError(JiraWriteError.unknownResult + " (Atlassian 서버 \(code))", uncertain: true) }
                throw JiraWriteError("Atlassian 서버가 응답하지 않아요. 잠시 후 다시 시도해 주세요. (\(code))")
            default:
                throw JiraWriteError("요청이 처리되지 않았어요. (\(code))")
            }
        }
    }
}
