import Foundation

// Atlassian 원격 MCP 서버로 Confluence·Jira를 가져오는 연결기 — docs/V04.md §6.2.
// token = MCPAuth.authorize가 돌려준 자격 증명 JSON. 만료되면 갱신해 Plugins.secrets(계정 = sourceId)에 다시 쓴다.
// 문서 모양(id·group·displayPath·location·tags·outLinks·fingerprint)은 v0.3 토큰 연결기(AtlassianConnector)의
// confluenceDoc·jiraDoc을 그대로 써서 만든다 — 이슈 키 연결·부모 페이지 연결이 두 방식에서 똑같이 동작한다.

final class AtlassianMCPConnector: RemoteConnector, JiraRefetching, @unchecked Sendable {
    static let defaultServer = "https://mcp.atlassian.com/v1/mcp"
    static let confluencePageSize = 100      // searchConfluenceUsingCql limit (≤250)
    static let jiraPageSize = 100            // searchJiraIssuesUsingJql maxResults (≤100)
    static let pageFetchConcurrency = 4

    struct Site { let cloudId: String; let url: String; let name: String; var host: String { URL(string: url)?.host ?? url } }

    private let config: SourceConfig
    private let serverURL: URL?
    let tokens: MCPTokenBox
    private let client: MCPClient?
    private let lock = NSLock()
    private var cachedSite: Site?

    required init(config: SourceConfig, token: String) {
        self.config = config
        let raw = (config.mcpURL?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? AtlassianMCPConnector.defaultServer
        let url = URL(string: raw).flatMap { MCPHTTP.isAllowed($0) ? $0 : nil }
        self.serverURL = url
        let box = MCPTokenBox(credential: token, account: config.id.isEmpty ? nil : config.id)
        self.tokens = box
        self.client = url.map { MCPClient(serverURL: $0, tokens: box) }
    }

    /// 갱신됐을 수 있는 현재 자격 증명 JSON (네이티브 쪽이 사이트를 고른 뒤 addRemote에 넘길 때 쓰면 안전하다).
    var currentCredential: String? { tokens.credentialJSON }

    private func locked<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }

    // MARK: - 도구 호출

    private func mcp() throws -> MCPClient {
        guard let c = client else { throw MCPError.badServer }
        guard tokens.hasCredential else { throw MCPError.reLogin }
        return c
    }

    /// v0.8: 한 번 쓰고 버리는 연결(Jira 반영)이 끝나면 원격 MCP 세션을 닫는다.
    func close() async { await client?.close() }

    /// tools/call 하나. 도구 오류(isError)는 한국어 MCPError로 바꾸고, 속도 제한 문구면 잠시 쉬었다가 최대 3번 다시 한다.
    /// retry: false — 쓰기(Jira 전환·댓글·생성)는 다시 보내지 않는다. 서버가 처리한 뒤 오류를 돌려줬을 수 있어서 두 번 쓰게 된다.
    func tool(_ name: String, _ args: [String: Any], retry: Bool = true) async throws -> MCPToolResult {
        let c = try mcp()
        var attempt = 0
        while true {
            let r = try await c.callTool(name, arguments: args)
            guard r.isError else { return r }
            let t = r.text.lowercased()
            // "429"는 낱말로만 본다(PROJ-1429·요청 id 같은 글자에 걸리지 않게)
            let limited = t.range(of: #"(?<![0-9a-z])429(?![0-9a-z])"#, options: .regularExpression) != nil
                || t.contains("rate limit") || t.contains("too many requests")
            if retry, attempt < 3, limited {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(2 * attempt) * 1_000_000_000)
                continue
            }
            throw AtlassianMCPConnector.toolError(r.text)
        }
    }

    static func toolError(_ text: String) -> MCPError {
        let t = text.lowercased()
        if t.contains("401") || t.contains("unauthorized") || t.contains("invalid_token") || t.contains("token expired") {
            return MCPError(kind: .reLogin, message: MCPError.reLoginMessage)
        }
        if t.contains("403") || t.contains("forbidden") || t.contains("permission") || t.contains("not permitted") || t.contains("access denied") {
            return MCPError.permission
        }
        if t.contains("404") || t.contains("not found") {
            return MCPError(kind: .notFound, message: "Atlassian에서 자료를 찾지 못했어요.")
        }
        return MCPError(kind: .tool, message: "Atlassian MCP 도구가 오류를 돌려줬어요. (\(MCPError.detail(text)))")
    }

    // MARK: - 사이트

    /// 이 계정으로 접근할 수 있는 사이트 (getAccessibleAtlassianResources).
    func resources() async throws -> [Site] {
        let r = try await tool("getAccessibleAtlassianResources", [:])
        var list: [Any] = []
        if let a = r.json as? [Any] { list = a }
        else if let d = r.json as? [String: Any] {
            list = (d["resources"] as? [Any]) ?? (d["sites"] as? [Any]) ?? (d["data"] as? [Any]) ?? (d["id"] != nil ? [d] : [])
        }
        var out: [Site] = []
        var seen = Set<String>()
        for case let s as [String: Any] in list {
            guard let id = (s["id"] as? String) ?? (s["cloudId"] as? String), !id.isEmpty,
                  let rawURL = s["url"] as? String, let site = AtlassianConnector.normalizedSite(rawURL) else { continue }
            let url = site.absoluteString
            if !seen.insert(url).inserted { continue }
            let name = (s["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (site.host ?? url)
            out.append(Site(cloudId: id, url: url, name: name))
        }
        return out
    }

    /// 네이티브 사이트 선택용 (D: addMCP). config.mcpSite는 보지 않는다.
    func sites() async throws -> [(name: String, url: String)] {
        return try await resources().map { (name: $0.name, url: $0.url) }
    }

    /// 로그인 직후 사이트 목록만 필요할 때 (자격 증명 갱신은 저장하지 않는다).
    static func sites(serverURL: URL, credential: String) async throws -> [(name: String, url: String)] {
        var cfg = SourceConfig(id: "", kind: .mcp, name: "", path: nil, site: nil, email: nil, confluenceSpaces: nil,
                               jiraJQL: nil, enabled: true, addedAt: Date())
        cfg.mcpURL = serverURL.absoluteString
        return try await AtlassianMCPConnector(config: cfg, token: credential).sites()
    }

    /// config.mcpSite(호스트·URL·cloudId)와 맞는 사이트. 없으면 하나뿐일 때 그것.
    func site() async throws -> Site {
        if let s = locked({ cachedSite }) { return s }
        let all = try await resources()
        let want = (config.mcpSite ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var chosen: Site?
        if !want.isEmpty {
            let wantHost = (AtlassianConnector.normalizedSite(want)?.host ?? want).lowercased()
            chosen = all.first { $0.cloudId == want || $0.host.lowercased() == wantHost }
            if chosen == nil {
                throw MCPError(kind: .permission, message: "선택한 Atlassian 사이트(\(MCPError.detail(want)))에 접근할 수 없어요. 다시 로그인하거나 사이트를 확인해 주세요.")
            }
        } else if all.count == 1 {
            chosen = all[0]
        } else if all.isEmpty {
            throw MCPError(kind: .permission, message: "이 계정으로 접근할 수 있는 Atlassian 사이트가 없어요.")
        } else {
            throw MCPError(kind: .config, message: "Atlassian 사이트가 여러 개예요. 연결할 사이트를 골라 주세요.")
        }
        let s = chosen!
        locked { cachedSite = s }
        return s
    }

    // MARK: - verify

    func verify() async throws -> String {
        let r = try await tool("atlassianUserInfo", [:])
        var d = r.json as? [String: Any] ?? [:]
        if let inner = (d["user"] ?? d["data"]) as? [String: Any] { d = inner }
        let name = [d["name"], d["displayName"], d["display_name"], d["nickname"], d["email"]]
            .compactMap { $0 as? String }.first(where: { !$0.isEmpty }) ?? "Atlassian 계정"
        let s = try await site()
        return "\(name) · \(s.host)"
    }

    /// 내 계정 id (atlassianUserInfo의 account_id). 실패해도 동기화는 계속한다 — 그러면 meta에 mine 키를 넣지 않는다(다음 동기화에서 다시 시도).
    func myAccountId() async -> String? {
        guard let r = try? await tool("atlassianUserInfo", [:]) else { return nil }
        var d = r.json as? [String: Any] ?? [:]
        if let inner = (d["user"] ?? d["data"]) as? [String: Any] { d = inner }
        return [d["account_id"], d["accountId"], d["id"]].compactMap { $0 as? String }.first { !$0.isEmpty }
    }

    /// 토큰 연결기의 문서 변환기 (사이트 주소만 넣어 만든다).
    private func mapper(_ s: Site) -> AtlassianConnector {
        var c = config
        c.site = s.url
        return AtlassianConnector(config: c, token: "")
    }

    // MARK: - Markdown → 평문 (+ 링크)

    private static func re(_ p: String, _ o: NSRegularExpression.Options = [.anchorsMatchLines]) -> NSRegularExpression {
        return try! NSRegularExpression(pattern: p, options: o)
    }
    private static func sub(_ r: NSRegularExpression, _ s: String, _ t: String) -> String {
        return r.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: t)
    }
    private static func groups(_ r: NSRegularExpression, _ s: String) -> [String] {
        let ns = s as NSString
        return r.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap {
            $0.range(at: 1).location == NSNotFound ? nil : ns.substring(with: $0.range(at: 1))
        }
    }
    private static let reFence = re("^[ \\t]*(```|~~~).*$\\n?")
    private static let reImage = re("!\\[([^\\]]*)\\]\\([^)]*\\)")
    private static let reLink = re("\\[([^\\]]*)\\]\\(\\s*<?([^)\\s>]*)>?(?:\\s+\"[^\"]*\")?\\s*\\)")
    private static let reAuto = re("<(https?://[^>\\s]+)>")
    private static let reHeading = re("^[ \\t]{0,3}#{1,6}[ \\t]+")
    private static let reQuote = re("^[ \\t]{0,3}>[ \\t]?")
    private static let reTask = re("^([ \\t]*)[-*+][ \\t]+\\[[ xX]\\][ \\t]+")
    private static let reTableSep = re("^[ \\t]*\\|?[ \\t]*:?-{3,}:?[ \\t]*(\\|[ \\t]*:?-{3,}:?[ \\t]*)*\\|?[ \\t]*$\\n?")
    private static let reRule = re("^[ \\t]*([-*_])([ \\t]*\\1){2,}[ \\t]*$")
    private static let reBold = re("(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1")
    private static let reItalic = re("(?<![\\w*])\\*(?=\\S)([^*\\n]+?)(?<=\\S)\\*(?![\\w*])")
    private static let reStrike = re("~~(.+?)~~")
    private static let reCode = re("`([^`\\n]+)`")
    private static let reBr = re("<br\\s*/?>", [.caseInsensitive])
    private static let reTag = re("</?[A-Za-z][^>]*>")
    private static let reEscape = re("\\\\([\\\\`*_{}\\[\\]()#+\\-.!|>~])")
    private static let rePageURL = re("/spaces/[^/\\s)\\]]+/pages/(\\d+)")
    private static let rePageParam = re("[?&]pageId=(\\d+)")
    private static let reBrowse = re("/browse/([A-Z][A-Z0-9_]*-\\d+)")

    /// Confluence·Jira가 돌려준 markdown → 평문, 그리고 본문 링크의 페이지 id·이슈 키.
    static func markdownToText(_ md: String) -> (text: String, pageIDs: [String], issueKeys: [String]) {
        let pageIDs = groups(rePageURL, md) + groups(rePageParam, md)
        let keys = groups(reBrowse, md)
        var s = md.replacingOccurrences(of: "\r\n", with: "\n")
        s = sub(reFence, s, "")
        s = sub(reImage, s, "$1")
        s = sub(reLink, s, "$1")
        s = sub(reAuto, s, "$1")
        s = sub(reTableSep, s, "")
        s = sub(reRule, s, "")
        s = sub(reHeading, s, "")
        s = sub(reQuote, s, "")
        s = sub(reTask, s, "$1- ")
        s = sub(reBold, s, "$2")
        s = sub(reItalic, s, "$1")
        s = sub(reStrike, s, "$1")
        s = sub(reCode, s, "$1")
        s = sub(reBr, s, "\n")
        s = sub(reTag, s, "")
        s = sub(reEscape, s, "$1")
        s = AtlassianText.decodeEntities(s)
        return (AtlassianText.adfToText(s), pageIDs, keys)   // adfToText(String) = 줄 정리
    }

    private static func escapeXML(_ s: String) -> String {
        return s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - Confluence

    struct Hit { var id: String; var title: String?; var spaceKey: String?; var webui: String?; var version: Int?; var when: String? }

    private static func str(_ v: Any?) -> String? {
        if let s = v as? String { return s.isEmpty ? nil : s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }
    private static func dict(_ v: Any?) -> [String: Any]? { v as? [String: Any] }
    private static func spaceFromPath(_ s: String?) -> String? {
        guard let s = s else { return nil }
        return groups(re("/spaces/([^/?#\\s]+)"), s).first?.removingPercentEncoding
    }
    private static func cleanTitle(_ s: String?) -> String? {
        return s?.replacingOccurrences(of: "@@@hl@@@", with: "").replacingOccurrences(of: "@@@endhl@@@", with: "")
    }

    /// searchConfluenceUsingCql 결과 → (항목, 다음 cursor). 모양을 알 수 없으면 nil.
    static func parseSearch(_ v: Any?) -> (hits: [Hit], next: String?)? {
        var results: [Any]
        var d: [String: Any] = [:]
        if let a = v as? [Any] { results = a }
        else if let o = v as? [String: Any] {
            d = o
            guard let r = (o["results"] as? [Any]) ?? (dict(o["data"])?["results"] as? [Any]) ?? (o["pages"] as? [Any]) else { return nil }
            results = r
        } else { return nil }
        var hits: [Hit] = []
        for case let r as [String: Any] in results {
            let c = dict(r["content"]) ?? r
            guard let id = str(c["id"]) else { continue }
            let type = (c["type"] as? String) ?? (r["type"] as? String) ?? "page"
            if type != "page" { continue }
            let links = dict(c["_links"])
            let webui = (links?["webui"] as? String) ?? (r["url"] as? String)
            let space = (dict(c["space"])?["key"] as? String) ?? (dict(r["space"])?["key"] as? String)
                ?? spaceFromPath(dict(r["resultGlobalContainer"])?["displayUrl"] as? String) ?? spaceFromPath(webui)
            let ver = dict(c["version"])
            hits.append(Hit(id: id, title: cleanTitle((c["title"] as? String) ?? (r["title"] as? String)), spaceKey: space,
                            webui: webui, version: (ver?["number"] as? NSNumber)?.intValue,
                            when: (ver?["when"] as? String) ?? (ver?["createdAt"] as? String) ?? (r["lastModified"] as? String)))
        }
        var next = str(d["cursor"]) ?? str(d["nextCursor"]) ?? str(d["next_cursor"])
        if next == nil, let link = dict(d["_links"])?["next"] as? String {
            let full = link.hasPrefix("http") ? link : "https://x.invalid" + (link.hasPrefix("/") ? link : "/" + link)
            next = URLComponents(string: full)?.queryItems?.first(where: { $0.name == "cursor" })?.value
        }
        return (hits, next)
    }

    /// getConfluencePage 결과에서 페이지 객체를 꺼낸다.
    static func unwrapPage(_ v: Any?) -> [String: Any]? {
        if let a = v as? [Any] { return a.first.flatMap(unwrapPage) }
        guard var d = v as? [String: Any] else { return nil }
        for k in ["page", "content", "data", "result"] where d["id"] == nil {
            if let inner = d[k] as? [String: Any] { d = inner }
        }
        return d["id"] != nil || d["title"] != nil ? d : nil
    }

    struct PageInfo {
        var id: String; var title: String; var space: String; var webui: String?
        var version: Int?; var when: String?; var created: String?
        var parentId: String?; var ancestors: [[String: Any]]?; var labels: [String]
        var storage: String; var extraPages: [String]; var extraKeys: [String]
    }

    /// getConfluencePage 결과 + 검색 항목 → PageInfo. 모양을 알 수 없으면 nil (그 쪽만 건너뛴다).
    static func pageInfo(_ raw: Any?, hit: Hit) -> PageInfo? {
        guard let p = unwrapPage(raw) else { return nil }
        let title = cleanTitle(p["title"] as? String) ?? hit.title ?? "(제목 없음)"
        let webui = (dict(p["_links"])?["webui"] as? String) ?? hit.webui
        let space = (dict(p["space"])?["key"] as? String) ?? (p["spaceKey"] as? String) ?? hit.spaceKey ?? spaceFromPath(webui) ?? "~"
        let ver = dict(p["version"])
        let ancestors = (p["ancestors"] as? [[String: Any]]).flatMap { $0.isEmpty ? nil : $0 }
        var parent = str(p["parentId"])
        if parent == nil, let a = ancestors?.last { parent = str(a["id"]) }
        var labels: [String] = []
        let labelSrc: Any? = p["labels"] ?? dict(p["metadata"])?["labels"]
        if let arr = labelSrc as? [Any] { labels = arr.compactMap { ($0 as? String) ?? (dict($0)?["name"] as? String) } }
        else if let res = dict(labelSrc)?["results"] as? [[String: Any]] { labels = res.compactMap { $0["name"] as? String } }
        var md: String?
        var storage: String?
        if let b = p["body"] as? String { md = b }
        else if let b = dict(p["body"]) {
            if let m = b["markdown"] as? String { md = m }
            else if let m = dict(b["markdown"])?["value"] as? String { md = m }
            else if let st = dict(b["storage"])?["value"] as? String { storage = st }
            else if let v = b["value"] as? String { md = v }
            else if let v = dict(b["view"])?["value"] as? String { storage = v }
        } else if let m = p["markdown"] as? String { md = m }
        var pages: [String] = [], keys: [String] = []
        if let m = md {
            let r = markdownToText(m)
            storage = escapeXML(r.text); pages = r.pageIDs; keys = r.issueKeys
        }
        return PageInfo(id: hit.id, title: title, space: space, webui: webui,
                        version: (ver?["number"] as? NSNumber)?.intValue ?? hit.version,
                        when: (ver?["createdAt"] as? String) ?? (ver?["when"] as? String) ?? (p["lastModified"] as? String) ?? hit.when,
                        created: (p["createdAt"] as? String) ?? (dict(p["history"])?["createdDate"] as? String),
                        parentId: parent, ancestors: ancestors, labels: labels, storage: storage ?? "",
                        extraPages: pages, extraKeys: keys)
    }

    /// PageInfo → DocRecord (토큰 연결기의 confluenceDoc을 거친다). 조상이 없으면 받은 페이지들의 parentId 사슬로 만든다.
    func confluenceDocs(_ infos: [PageInfo], site: Site) -> [DocRecord] {
        let m = mapper(site)
        let sid = config.id
        var byId: [String: PageInfo] = [:]
        for i in infos { byId[i.id] = i }
        var out: [DocRecord] = []
        for i in infos {
            var anc: [[String: Any]] = []
            if let a = i.ancestors {
                anc = a.map { var e: [String: Any] = ["id": AtlassianMCPConnector.str($0["id"]) ?? ""]; if let t = $0["title"] as? String { e["title"] = t }; return e }
            } else {
                var cur = i.parentId
                var seen: Set<String> = [i.id]
                while let c = cur, seen.insert(c).inserted, anc.count < 30 {
                    if let p = byId[c] { anc.insert(["id": c, "title": p.title], at: 0); cur = p.parentId }
                    else { anc.insert(["id": c], at: 0); break }
                }
            }
            var v1: [String: Any] = [
                "id": i.id, "title": i.title, "space": ["key": i.space], "ancestors": anc,
                "body": ["storage": ["value": i.storage]],
                "version": ["number": i.version ?? 0, "when": i.when ?? ""],
                "metadata": ["labels": ["results": i.labels.map { ["name": $0] }]],
            ]
            if let c = i.created { v1["history"] = ["createdDate": c] }
            if let w = i.webui, w.hasPrefix("/") { v1["_links"] = ["webui": w.hasPrefix("/wiki/") ? String(w.dropFirst(5)) : w] }
            guard var d = m.confluenceDoc(v1) else { continue }
            let extra = i.extraPages.filter { $0 != i.id }.map { "id:\(sid):confluence:\($0)" } + i.extraKeys
            var seenLinks = Set<String>()
            d.outLinks = (d.outLinks + extra).filter { !$0.isEmpty && seenLinks.insert($0).inserted }
            if i.version == nil { d.fingerprint = i.when ?? "0" }
            out.append(d)
        }
        return out
    }

    private static func recoverable(_ e: MCPError) -> Bool {
        return e.kind == .tool || e.kind == .notFound || e.kind == .permission || e.kind == .protocolError
    }

    private func fetchPage(_ h: Hit, site: Site) async throws -> PageInfo? {
        do {
            let r = try await tool("getConfluencePage", ["cloudId": site.cloudId, "pageId": h.id, "contentFormat": "markdown"])
            return AtlassianMCPConnector.pageInfo(r.json, hit: h)
        } catch let e as MCPError where AtlassianMCPConnector.recoverable(e) {
            return nil   // 그 페이지만 건너뛴다 (id는 keepIDs에 남겨 지우지 않는다)
        }
    }

    /// Confluence 문서와, 원격에 있다고 확인된 id 전체(본문을 못 읽은 페이지 포함).
    func fetchConfluence(site: Site, since: Date?, progress: (Int) -> Void) async throws -> (docs: [DocRecord], known: Set<String>) {
        let cql = AtlassianConnector.confluenceCQL(spaces: config.confluenceSpaces, since: since)
        var hits: [Hit] = []
        var seen = Set<String>()
        var cursor: String?
        while hits.count < AtlassianConnector.maxItems {
            var args: [String: Any] = ["cloudId": site.cloudId, "cql": cql, "limit": AtlassianMCPConnector.confluencePageSize]
            if let c = cursor { args["cursor"] = c }
            let r = try await tool("searchConfluenceUsingCql", args)
            guard let page = AtlassianMCPConnector.parseSearch(r.json) else {
                throw MCPError(kind: .tool, message: "Confluence 검색 결과를 읽지 못했어요.")
            }
            for h in page.hits where hits.count < AtlassianConnector.maxItems && seen.insert(h.id).inserted { hits.append(h) }
            guard !page.hits.isEmpty, let n = page.next, n != cursor else { break }
            cursor = n
        }
        var infos: [String: PageInfo] = [:]
        try await withThrowingTaskGroup(of: (String, PageInfo?).self) { g in
            var idx = 0
            while idx < hits.count && idx < AtlassianMCPConnector.pageFetchConcurrency {
                let h = hits[idx]; idx += 1
                g.addTask { (h.id, try await self.fetchPage(h, site: site)) }
            }
            while let (id, info) = try await g.next() {
                if let i = info { infos[id] = i }
                progress(infos.count)
                if idx < hits.count {
                    let h = hits[idx]; idx += 1
                    g.addTask { (h.id, try await self.fetchPage(h, site: site)) }
                }
            }
        }
        let ordered = hits.compactMap { infos[$0.id] }
        let sid = config.id
        return (confluenceDocs(ordered, site: site), Set(hits.map { "\(sid):confluence:\($0.id)" }))
    }

    // MARK: - Jira

    static func parseIssues(_ v: Any?) -> (issues: [[String: Any]], next: String?, isLast: Bool)? {
        if let a = v as? [Any] { return (a.compactMap { $0 as? [String: Any] }, nil, true) }
        guard var d = v as? [String: Any] else { return nil }
        if d["issues"] == nil, let inner = dict(d["data"]) ?? dict(d["result"]) { d = inner }
        guard let list = (d["issues"] as? [Any]) ?? (d["values"] as? [Any]) else { return nil }
        let next = str(d["nextPageToken"])
        let isLast = (d["isLast"] as? Bool) ?? (next == nil)
        return (list.compactMap { $0 as? [String: Any] }, next, isLast)
    }

    /// markdown 문자열 설명·댓글을 평문으로 바꿔 둔다 (ADF로 오면 jiraDoc이 그대로 처리한다).
    static func cleanIssue(_ issue: [String: Any]) -> [String: Any] {
        guard var f = issue["fields"] as? [String: Any] else { return issue }
        var i = issue
        if let s = f["description"] as? String { f["description"] = markdownToText(s).text }
        var comment = dict(f["comment"])
        if comment == nil, let arr = f["comment"] as? [[String: Any]] { comment = ["comments": arr] }
        if var cm = comment {
            let list = (cm["comments"] as? [[String: Any]]) ?? []
            cm["comments"] = list.map { c -> [String: Any] in
                var c = c
                if let b = c["body"] as? String { c["body"] = markdownToText(b).text }
                return c
            }
            f["comment"] = cm
        }
        i["fields"] = f
        return i
    }

    func fetchJira(site: Site, since: Date?, progress: (Int) -> Void) async throws -> [DocRecord] {
        let jql = AtlassianConnector.jiraJQL(custom: config.jiraJQL, since: since)
        let m = mapper(site)
        let me = await myAccountId()      // 동기화마다 한 번 (v0.5 meta.mine 판정용)
        var docs: [DocRecord] = []
        var seen = Set<String>()
        var token: String?
        while docs.count < AtlassianConnector.maxItems {
            var args: [String: Any] = ["cloudId": site.cloudId, "jql": jql, "fields": AtlassianConnector.jiraFields,
                                       "maxResults": AtlassianMCPConnector.jiraPageSize, "responseContentFormat": "markdown"]
            if let t = token { args["nextPageToken"] = t }
            let r = try await tool("searchJiraIssuesUsingJql", args)
            guard let page = AtlassianMCPConnector.parseIssues(r.json) else {
                throw MCPError(kind: .tool, message: "Jira 검색 결과를 읽지 못했어요.")
            }
            for i in page.issues where docs.count < AtlassianConnector.maxItems {
                if let d = m.jiraDoc(AtlassianMCPConnector.cleanIssue(i), me: me), seen.insert(d.id).inserted { docs.append(d) }
            }
            progress(docs.count)
            guard !page.issues.isEmpty, !page.isLast, let nt = page.next, nt != token else { break }
            token = nt
        }
        return docs
    }

    // MARK: - sync

    func sync(since: Date?, progress: @escaping (Int, Int?) -> Void) async throws -> RemoteSyncResult {
        let started = Date()
        do {
            let result = try await syncBody(since: since, started: started, progress: progress)
            await client?.close()
            return result
        } catch {
            await client?.close()
            throw error
        }
    }

    /// v0.7 업그레이드 뒤 한 번: Jira 이슈만 전체로 다시 받는다 (Confluence는 페이지마다 호출이 하나라 건드리지 않는다).
    func syncJiraOnly(cursor: Date, progress: @escaping (Int, Int?) -> Void) async throws -> RemoteSyncResult {
        do {
            let s = try await site()
            progress(0, nil)
            var jira: [DocRecord] = []
            do {
                jira = try await fetchJira(site: s, since: nil) { progress($0, nil) }
            } catch let e as MCPError where AtlassianMCPConnector.recoverable(e) {
                jira = []
            }
            progress(jira.count, jira.count)
            await client?.close()
            return RemoteSyncResult(upserts: jira, keepIDs: nil, cursor: cursor)
        } catch {
            await client?.close()
            throw error
        }
    }

    private func syncBody(since: Date?, started: Date, progress: @escaping (Int, Int?) -> Void) async throws -> RemoteSyncResult {
        let s = try await site()
        progress(0, nil)
        var skipped: [MCPError] = []
        var confluence: [DocRecord] = []
        var known = Set<String>()
        var jira: [DocRecord] = []
        do {
            (confluence, known) = try await fetchConfluence(site: s, since: since) { progress($0, nil) }
        } catch let e as MCPError where AtlassianMCPConnector.recoverable(e) {
            skipped.append(e)   // Confluence가 없는 사이트·권한 없음: Jira만 계속
        }
        let base = confluence.count
        do {
            jira = try await fetchJira(site: s, since: since) { progress(base + $0, nil) }
        } catch let e as MCPError where AtlassianMCPConnector.recoverable(e) {
            skipped.append(e)
        }
        if skipped.count == 2, let first = skipped.first { throw first }
        let all = confluence + jira
        progress(all.count, all.count)
        // 한쪽이라도 건너뛰었으면 무엇을 지워야 할지 모르므로 keepIDs를 주지 않는다.
        let keep: Set<String>? = (since == nil && skipped.isEmpty) ? known.union(all.map { $0.id }) : nil
        return RemoteSyncResult(upserts: all, keepIDs: keep, cursor: started)
    }
}
