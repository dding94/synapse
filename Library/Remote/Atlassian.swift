import Foundation

// Atlassian Cloud(Confluence + Jira) 연결기 — docs/CONNECT.md §6.
// 토큰은 Authorization 헤더에만 쓰고, 로그·오류 문구·파일에는 절대 남기지 않는다.

/// 사용자에게 그대로 보여 줘도 되는 한국어 한 문장 오류.
struct AtlassianError: Error, LocalizedError, CustomStringConvertible {
    enum Kind { case auth, notFound, rateLimited, network, server, badRequest, other }
    let kind: Kind
    let message: String
    var status: Int? = nil
    var errorDescription: String? { message }
    var description: String { message }

    static let authMessage = "토큰이 맞지 않아요. 이메일과 토큰을 확인해 주세요."
    static let badSite = AtlassianError(kind: .other, message: "사이트 주소를 확인해 주세요. (https://팀이름.atlassian.net)")
}

/// 다른 호스트로의 리디렉션을 막는다 (Authorization 헤더가 새 나가지 않게).
private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let from = task.originalRequest?.url
        if let to = request.url, to.host == from?.host, to.port == from?.port, to.scheme == from?.scheme {
            completionHandler(request)
        } else {
            completionHandler(nil)
        }
    }
}

final class AtlassianConnector: RemoteConnector, JiraRefetching {
    static let maxItems = 2000
    static let maxComments = 20
    static let maxTextChars = 400_000
    /// 증분 조회 시작 시각에서 빼는 여유. Atlassian 날짜 조건은 사용자 프로필 시간대 기준이라 시간대 차이를 흡수한다.
    static let incrementalOverlap: TimeInterval = 6 * 3600
    static let defaultCQL = "type=page AND (contributor = currentUser() OR watcher = currentUser())"
    static let defaultJQL = "(assignee = currentUser() OR reporter = currentUser() OR watcher = currentUser()) AND updated >= -365d ORDER BY updated DESC"
    static let jiraFields = ["summary", "description", "labels", "issuelinks", "parent", "project", "status", "issuetype", "created", "updated", "comment",
                                  "priority", "duedate", "assignee", "statuscategorychangedate"]
    /// Jira meta 판 (v0.7): 1 = statusChanged·assigneeName 포함. 낮은 색인은 업그레이드 뒤 한 번 Jira 이슈만 전체로 다시 받는다.
    static let jiraMetaVersion = 1

    private let config: SourceConfig
    private let siteURL: URL?
    private let authHeader: String
    private let session: URLSession

    required init(config: SourceConfig, token: String) {
        self.config = config
        self.siteURL = AtlassianConnector.normalizedSite(config.site ?? "")
        let raw = "\((config.email ?? "").trimmingCharacters(in: .whitespaces)):\(token.trimmingCharacters(in: .whitespacesAndNewlines))"
        self.authHeader = "Basic " + Data(raw.utf8).base64EncodedString()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 120
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: cfg, delegate: RedirectGuard(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    /// "team.atlassian.net" → https://team.atlassian.net. http는 로컬 시험(127.0.0.1·localhost)만 허용한다.
    static func normalizedSite(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard let c = URLComponents(string: s), let host = c.host, !host.isEmpty, let scheme = c.scheme?.lowercased() else { return nil }
        let local = host == "127.0.0.1" || host == "localhost" || host == "::1"
        if scheme == "http" && !local { return nil }
        if scheme != "http" && scheme != "https" { return nil }
        var o = URLComponents()
        o.scheme = scheme
        o.host = host
        o.port = c.port
        return o.url
    }

    private func site() throws -> URL {
        guard let u = siteURL else { throw AtlassianError.badSite }
        return u
    }

    // MARK: - HTTP

    static func enc(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private func message(for e: URLError) -> String {
        switch e.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return "인터넷에 연결되어 있지 않아요."
        case .timedOut:
            return "응답이 너무 늦어요. 잠시 후 다시 시도해 주세요."
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "사이트에 연결하지 못했어요. 주소를 확인해 주세요."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            return "보안 연결에 실패했어요. 사이트 주소를 확인해 주세요."
        default:
            return "네트워크 오류가 생겼어요. 잠시 후 다시 시도해 주세요."
        }
    }

    /// 한 번의 요청. 429는 Retry-After만큼 쉬고 최대 3번 다시 시도한다. 응답 본문(JSON)을 돌려준다.
    private func send(_ url: URL, method: String = "GET", body: [String: Any]? = nil) async throws -> Any {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            req.httpMethod = method
            req.setValue(authHeader, forHTTPHeaderField: "Authorization")
            req.setValue("Synapse/0.3", forHTTPHeaderField: "User-Agent")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body = body {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let data: Data
            let resp: URLResponse
            do {
                (data, resp) = try await session.data(for: req)
            } catch let e as URLError where e.code == .cancelled {
                throw CancellationError()
            } catch let e as URLError {
                throw AtlassianError(kind: .network, message: message(for: e))
            } catch {
                throw AtlassianError(kind: .network, message: "네트워크 오류가 생겼어요. 잠시 후 다시 시도해 주세요.")
            }
            guard let http = resp as? HTTPURLResponse else {
                throw AtlassianError(kind: .server, message: "서버 응답을 읽지 못했어요.")
            }
            let code = http.statusCode
            switch code {
            case 200..<300:
                if data.isEmpty { return [String: Any]() }
                guard let obj = try? JSONSerialization.jsonObject(with: data) else {
                    throw AtlassianError(kind: .server, message: "서버 응답을 읽지 못했어요. 사이트 주소를 확인해 주세요.", status: code)
                }
                return obj
            case 401, 403:
                throw AtlassianError(kind: .auth, message: AtlassianError.authMessage, status: code)
            case 404:
                throw AtlassianError(kind: .notFound, message: "해당 주소를 찾지 못했어요. 사이트 주소를 확인해 주세요.", status: code)
            case 429:
                if attempt >= 3 {
                    throw AtlassianError(kind: .rateLimited, message: "요청이 너무 많아 잠시 막혔어요. 몇 분 뒤 다시 시도해 주세요.", status: code)
                }
                attempt += 1
                var wait = Double(http.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces) ?? "") ?? 2
                wait = min(max(wait, 1), 60)
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            case 400:
                throw AtlassianError(kind: .badRequest, message: "검색 조건(스페이스·JQL)이 올바르지 않아요. 설정을 확인해 주세요.", status: code)
            case 500..<600:
                throw AtlassianError(kind: .server, message: "Atlassian 서버가 응답하지 않아요. 잠시 후 다시 시도해 주세요. (\(code))", status: code)
            default:
                throw AtlassianError(kind: .other, message: "요청이 처리되지 않았어요. (\(code))", status: code)
            }
        }
    }

    private func endpoint(_ path: String, query: String? = nil) throws -> URL {
        var c = URLComponents(url: try site(), resolvingAgainstBaseURL: false)!
        c.percentEncodedPath = path
        c.percentEncodedQuery = query
        guard let u = c.url else { throw AtlassianError.badSite }
        return u
    }

    // MARK: - verify

    func verify() async throws -> String {
        let obj = try await send(try endpoint("/rest/api/3/myself"))
        let d = obj as? [String: Any] ?? [:]
        let name = (d["displayName"] as? String) ?? (d["emailAddress"] as? String) ?? (config.email ?? "계정")
        return "\(name) · \(try site().host ?? "")"
    }

    // MARK: - 날짜·보조

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    /// "2026-05-12T14:30:00.000+0900", "...Z", "...+09:00", 밀리초 없음 모두 처리.
    static func parseDate(_ s: String?) -> Date? {
        guard var t = s?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        if t.hasSuffix("Z") || t.hasSuffix("z") {
            t = String(t.dropLast()) + "+00:00"
        } else if let tIdx = t.firstIndex(of: "T"), t.count >= 5 {
            let signIdx = t.index(t.endIndex, offsetBy: -5)
            let tail = t[signIdx...]
            if signIdx > tIdx, tail.first == "+" || tail.first == "-", tail.dropFirst().allSatisfy({ $0.isNumber }) {
                t = String(t[..<signIdx]) + String(tail.prefix(3)) + ":" + String(tail.suffix(2))
            }
        }
        return isoFrac.date(from: t) ?? isoPlain.date(from: t)
    }

    private static let queryDate: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm"; return f
    }()

    /// 증분 조건에 쓰는 "yyyy-MM-dd HH:mm" (여유 시간을 뺀 값).
    static func queryStamp(_ since: Date) -> String {
        return queryDate.string(from: since.addingTimeInterval(-incrementalOverlap))
    }

    private static func capText(_ s: String) -> String {
        return s.count > maxTextChars ? String(s.prefix(maxTextChars)) : s
    }

    private static func dedup(_ xs: [String]) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for x in xs where !x.isEmpty && seen.insert(x).inserted { out.append(x) }
        return out
    }

    // MARK: - Confluence

    static func confluenceCQL(spaces: [String]?, since: Date?) -> String {
        let keys = (spaces ?? []).map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\\", with: "") }.filter { !$0.isEmpty }
        var cql = keys.isEmpty ? defaultCQL : "type=page AND space in (" + keys.map { "\"\($0)\"" }.joined(separator: ",") + ")"
        if let since = since { cql += " AND lastmodified >= \"\(queryStamp(since))\"" }
        return cql + " order by lastmodified desc"
    }

    private func confluenceNext(_ links: Any?) -> URL? {
        guard let path = (links as? [String: Any])?["next"] as? String, path.hasPrefix("/"), let base = siteURL else { return nil }
        let full = path.hasPrefix("/wiki/") ? path : "/wiki" + path
        return URL(string: base.absoluteString + full)   // 호스트는 항상 우리 사이트로 고정
    }

    func fetchConfluence(since: Date?, progress: (Int) -> Void) async throws -> [DocRecord] {
        let cql = AtlassianConnector.confluenceCQL(spaces: config.confluenceSpaces, since: since)
        let expand = "body.storage,version,space,ancestors,metadata.labels,history"
        var next: URL? = try endpoint("/wiki/rest/api/content/search",
                                      query: "cql=\(AtlassianConnector.enc(cql))&limit=50&start=0&expand=\(AtlassianConnector.enc(expand))")
        var docs: [DocRecord] = []
        var seen = Set<String>()
        var lastURL: URL?
        while let url = next, docs.count < AtlassianConnector.maxItems {
            let obj = try await send(url) as? [String: Any] ?? [:]
            let results = obj["results"] as? [[String: Any]] ?? []
            for r in results where docs.count < AtlassianConnector.maxItems {
                if let d = confluenceDoc(r), seen.insert(d.id).inserted { docs.append(d) }
            }
            progress(docs.count)
            lastURL = url
            next = results.isEmpty ? nil : confluenceNext(obj["_links"])
            if next == lastURL { next = nil }
        }
        return docs
    }

    func confluenceDoc(_ r: [String: Any]) -> DocRecord? {
        guard let pageId = (r["id"] as? String) ?? (r["id"] as? Int).map(String.init),
              let site = siteURL?.absoluteString else { return nil }
        let sid = config.id
        let title = (r["title"] as? String) ?? "(제목 없음)"
        let spaceKey = ((r["space"] as? [String: Any])?["key"] as? String) ?? "~"
        let ancestors = (r["ancestors"] as? [[String: Any]]) ?? []
        let storage = (((r["body"] as? [String: Any])?["storage"]) as? [String: Any])?["value"] as? String ?? ""
        let parsed = AtlassianText.storageToText(storage)
        let labels = ((((r["metadata"] as? [String: Any])?["labels"]) as? [String: Any])?["results"] as? [[String: Any]] ?? [])
            .compactMap { $0["name"] as? String }
        let ver = r["version"] as? [String: Any]
        let versionNo = (ver?["number"] as? Int).map(String.init) ?? "0"
        let modified = AtlassianConnector.parseDate(ver?["when"] as? String) ?? Date()
        let created = AtlassianConnector.parseDate(((r["history"] as? [String: Any])?["createdDate"]) as? String)
        let webui = ((r["_links"] as? [String: Any])?["webui"] as? String) ?? "/spaces/\(spaceKey)/pages/\(pageId)"
        var out = parsed.links.filter { $0 != title }
        if let parent = ancestors.last, let pid = (parent["id"] as? String) ?? (parent["id"] as? Int).map(String.init) {
            out.append("id:\(sid):confluence:\(pid)")
        }
        let path = (["Confluence · \(spaceKey)"] + ancestors.compactMap { $0["title"] as? String } + [title]).joined(separator: " / ")
        let text = AtlassianConnector.capText(parsed.text)
        return DocRecord(id: "\(sid):confluence:\(pageId)", sourceId: sid, kind: "confluence", title: title,
                         location: site + "/wiki" + webui, displayPath: path, folder: spaceKey, group: spaceKey,
                         modified: modified, created: created, size: text.utf8.count,
                         tags: AtlassianConnector.dedup(labels), aliases: [], outLinks: AtlassianConnector.dedup(out),
                         text: text, fingerprint: versionNo)
    }

    // MARK: - Jira

    static func jiraJQL(custom: String?, since: Date?) -> String {
        var base = (custom ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = defaultJQL }
        guard let since = since else { return base }
        let cond = "updated >= \"\(queryStamp(since))\""
        let re = try! NSRegularExpression(pattern: "\\border\\s+by\\b", options: [.caseInsensitive])
        let ns = base as NSString
        var whereClause = base
        var order = ""
        if let m = re.matches(in: base, options: [], range: NSRange(location: 0, length: ns.length)).last {
            whereClause = ns.substring(to: m.range.location)
            order = ns.substring(from: m.range.location)
        }
        whereClause = whereClause.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = whereClause.isEmpty ? cond : "(\(whereClause)) AND \(cond)"
        return order.isEmpty ? combined : combined + " " + order.trimmingCharacters(in: .whitespaces)
    }

    func fetchJira(since: Date?, progress: (Int) -> Void) async throws -> [DocRecord] {
        let jql = AtlassianConnector.jiraJQL(custom: config.jiraJQL, since: since)
        let url = try endpoint("/rest/api/3/search/jql")
        let me = await myAccountId()      // 동기화마다 한 번 (v0.5 meta.mine 판정용)
        var docs: [DocRecord] = []
        var seen = Set<String>()
        var token: String?
        while docs.count < AtlassianConnector.maxItems {
            var body: [String: Any] = ["jql": jql, "fields": AtlassianConnector.jiraFields, "maxResults": 100]
            if let t = token { body["nextPageToken"] = t }
            let obj = try await send(url, method: "POST", body: body) as? [String: Any] ?? [:]
            let issues = obj["issues"] as? [[String: Any]] ?? []
            for i in issues where docs.count < AtlassianConnector.maxItems {
                if let d = jiraDoc(i, me: me), seen.insert(d.id).inserted { docs.append(d) }
            }
            progress(docs.count)
            let isLast = (obj["isLast"] as? Bool) ?? false
            guard !issues.isEmpty, !isLast, let nt = obj["nextPageToken"] as? String, !nt.isEmpty, nt != token else { break }
            token = nt
        }
        return docs
    }

    /// 내 계정 id (/rest/api/3/myself). 실패해도 동기화는 계속한다 — 그러면 meta에 mine 키를 넣지 않는다(다음 동기화에서 다시 시도).
    func myAccountId() async -> String? {
        guard let obj = try? await send(try endpoint("/rest/api/3/myself")) as? [String: Any],
              let id = obj["accountId"] as? String, !id.isEmpty else { return nil }
        return id
    }

    private static let metaISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    /// docs/V05.md §4.8 — DocRecord.meta (status, statusCategory, priority, duedate, assignee, mine, issuetype, updated).
    /// 값이 없는 필드는 키를 넣지 않는다. mine은 내 id를 알 때만 "1"|"0".
    static func jiraMeta(_ f: [String: Any], me: String?) -> [String: String] {
        func name(_ key: String) -> String? {
            guard let n = (f[key] as? [String: Any])?["name"] as? String, !n.isEmpty else { return nil }
            return n
        }
        var m: [String: String] = [:]
        let status = f["status"] as? [String: Any]
        if let s = status?["name"] as? String, !s.isEmpty { m["status"] = s }
        if let c = (status?["statusCategory"] as? [String: Any])?["key"] as? String, !c.isEmpty { m["statusCategory"] = c }
        if let p = name("priority") { m["priority"] = p }
        if let d = f["duedate"] as? String, d.count >= 10 { m["duedate"] = String(d.prefix(10)) }
        let assignee = (f["assignee"] as? [String: Any])?["accountId"] as? String
        if let a = assignee, !a.isEmpty { m["assignee"] = a }
        // v0.7: 담당자 표시 이름, 상태 분류가 마지막으로 바뀐 시각 (둘 다 없을 수 있다)
        if let n = (f["assignee"] as? [String: Any])?["displayName"] as? String, !n.isEmpty { m["assigneeName"] = n }
        if let c = parseDate(f["statuscategorychangedate"] as? String) { m["statusChanged"] = metaISO.string(from: c) }
        // 내 id를 모르면(조회 실패) mine 키를 넣지 않는다 — 사서는 키가 없으면 이전 값을 유지하고, 다음 동기화에서 다시 알아본다.
        if let me = me, !me.isEmpty { m["mine"] = (assignee == me) ? "1" : "0" }
        if let t = name("issuetype") { m["issuetype"] = t }
        if let u = parseDate(f["updated"] as? String) { m["updated"] = metaISO.string(from: u) }
        return m
    }

    func jiraDoc(_ issue: [String: Any], me: String? = nil) -> DocRecord? {
        guard let key = issue["key"] as? String, let f = issue["fields"] as? [String: Any],
              let site = siteURL?.absoluteString else { return nil }
        let sid = config.id
        let summary = (f["summary"] as? String) ?? ""
        let project = ((f["project"] as? [String: Any])?["key"] as? String)
            ?? String(key.split(separator: "-").first ?? Substring(key))
        var parts: [String] = []
        let desc = AtlassianText.adfToText(f["description"])
        if !desc.isEmpty { parts.append(desc) }
        let comments = ((f["comment"] as? [String: Any])?["comments"] as? [[String: Any]]) ?? []
        for c in comments.suffix(AtlassianConnector.maxComments) {
            let body = AtlassianText.adfToText(c["body"])
            if body.isEmpty { continue }
            let who = ((c["author"] as? [String: Any])?["displayName"] as? String) ?? "누군가"
            parts.append("댓글 · \(who): \(body)")
        }
        let text = AtlassianConnector.capText(parts.joined(separator: "\n\n"))
        var out: [String] = []
        for l in (f["issuelinks"] as? [[String: Any]]) ?? [] {
            for side in ["inwardIssue", "outwardIssue"] {
                if let k = (l[side] as? [String: Any])?["key"] as? String { out.append(k) }
            }
        }
        if let pk = (f["parent"] as? [String: Any])?["key"] as? String { out.append(pk) }
        out = out.filter { $0 != key }
        let updatedStr = f["updated"] as? String
        let labels = (f["labels"] as? [String]) ?? []
        return DocRecord(id: "\(sid):jira:\(key)", sourceId: sid, kind: "jira", title: "\(key) · \(summary)",
                         location: site + "/browse/\(key)", displayPath: "Jira · \(project) / \(key)",
                         folder: project, group: project,
                         modified: AtlassianConnector.parseDate(updatedStr) ?? Date(),
                         created: AtlassianConnector.parseDate(f["created"] as? String),
                         size: text.utf8.count, tags: AtlassianConnector.dedup(labels), aliases: [],
                         outLinks: AtlassianConnector.dedup(out), text: text, fingerprint: updatedStr ?? "",
                         meta: AtlassianConnector.jiraMeta(f, me: me))
    }

    // MARK: - sync

    func sync(since: Date?, progress: @escaping (Int, Int?) -> Void) async throws -> RemoteSyncResult {
        _ = try site()
        let started = Date()
        var skipped: [AtlassianError] = []
        var confluence: [DocRecord] = []
        var jira: [DocRecord] = []
        progress(0, nil)
        do {
            confluence = try await fetchConfluence(since: since) { progress($0, nil) }
        } catch let e as AtlassianError where e.status == 403 || e.kind == .notFound {
            skipped.append(e)       // Confluence 없는 사이트·권한 없음: Jira만 계속
        }
        let base = confluence.count
        do {
            jira = try await fetchJira(since: since) { progress(base + $0, nil) }
        } catch let e as AtlassianError where e.status == 403 || e.kind == .notFound {
            skipped.append(e)
        }
        if skipped.count == 2, let first = skipped.first { throw first }
        let all = confluence + jira
        progress(all.count, all.count)
        // 한쪽을 건너뛰었다면 지워도 되는지 알 수 없으므로 keepIDs를 주지 않는다 (삭제 반영 안 함).
        let keep: Set<String>? = (since == nil && skipped.isEmpty) ? Set(all.map { $0.id }) : nil
        return RemoteSyncResult(upserts: all, keepIDs: keep, cursor: started)
    }

    /// v0.7 업그레이드 뒤 한 번: Jira 이슈만 전체로 다시 받는다. 삭제 반영(keepIDs)은 없고, cursor는 이전 값을 그대로 돌려준다
    /// (Confluence 변경분을 다음 증분 동기화가 이어서 가져오게).
    func syncJiraOnly(cursor: Date, progress: @escaping (Int, Int?) -> Void) async throws -> RemoteSyncResult {
        _ = try site()
        progress(0, nil)
        var jira: [DocRecord] = []
        do {
            jira = try await fetchJira(since: nil) { progress($0, nil) }
        } catch let e as AtlassianError where e.status == 403 || e.kind == .notFound {
            jira = []      // Jira 권한이 없으면 받을 것이 없다
        }
        progress(jira.count, jira.count)
        return RemoteSyncResult(upserts: jira, keepIDs: nil, cursor: cursor)
    }
}
