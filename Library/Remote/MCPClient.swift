import Foundation

// MCP Streamable HTTP 클라이언트 — docs/V04.md §6.1.
// JSON-RPC를 POST로 보내고, 응답이 SSE면 `data:` 이벤트에서 같은 id의 응답을 찾는다.
// 접근 토큰은 Authorization 헤더에만 쓰고 로그·오류 문구에는 절대 남기지 않는다.

/// MCP 연결·로그인 오류. message는 사용자에게 그대로 보여 줘도 되는 한국어 한 문장.
struct MCPError: Error, LocalizedError, CustomStringConvertible {
    enum Kind { case reLogin, cancelled, timedOut, network, permission, rateLimited, server, protocolError, notFound, tool, config }
    let kind: Kind
    let message: String
    var status: Int? = nil
    var errorDescription: String? { message }
    var description: String { message }
    /// 사용자가 로그인 창을 닫았거나 시간이 지난 경우 (화면은 `{ ok:false, cancelled:true }`).
    var isCancellation: Bool { kind == .cancelled || kind == .timedOut }

    static let reLoginMessage = "다시 로그인이 필요해요. 자료 화면에서 Atlassian(MCP)에 다시 로그인해 주세요."
    static var reLogin: MCPError { MCPError(kind: .reLogin, message: reLoginMessage) }
    static var cancelled: MCPError { MCPError(kind: .cancelled, message: "로그인을 취소했어요.") }
    static var loginTimedOut: MCPError { MCPError(kind: .timedOut, message: "로그인 시간이 지났어요. 다시 시도해 주세요.") }
    static var permission: MCPError { MCPError(kind: .permission, message: "이 계정에는 해당 자료를 볼 권한이 없어요. Atlassian 권한을 확인해 주세요.") }
    static var badServer: MCPError { MCPError(kind: .config, message: "MCP 서버 주소를 확인해 주세요. (https만 쓸 수 있어요)") }

    static func network(_ e: URLError) -> MCPError {
        switch e.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return MCPError(kind: .network, message: "인터넷에 연결되어 있지 않아요.")
        case .timedOut:
            return MCPError(kind: .network, message: "응답이 너무 늦어요. 잠시 후 다시 시도해 주세요.")
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return MCPError(kind: .network, message: "MCP 서버에 연결하지 못했어요. 인터넷 연결과 서버 주소를 확인해 주세요.")
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            return MCPError(kind: .network, message: "보안 연결에 실패했어요. 서버 주소를 확인해 주세요.")
        default:
            return MCPError(kind: .network, message: "네트워크 오류가 생겼어요. 잠시 후 다시 시도해 주세요.")
        }
    }

    /// 서버가 준 영어 문구를 괄호 안에 짧게 붙인다 (토큰이 섞일 일은 없지만 길이는 자른다).
    static func detail(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return t.count > 120 ? String(t.prefix(120)) + "…" : t
    }
}

/// 접근 토큰 공급자. 연결기(AtlassianMCPConnector)가 자격 증명 JSON으로 구현한다.
protocol MCPTokenSource: AnyObject {
    /// 지금 쓸 접근 토큰. 만료가 가까우면 먼저 갱신한다. 갱신 실패는 MCPError.reLogin.
    func accessToken() async throws -> String
    /// 서버가 401을 돌려준 뒤 한 번 불린다. 새 토큰을 받아 두거나 MCPError.reLogin을 던진다.
    func refreshAfterUnauthorized(failedToken: String) async throws
}

/// tools/call 결과.
struct MCPToolResult {
    let content: [[String: Any]]
    let structured: Any?
    let isError: Bool

    /// text 조각을 이어 붙인 것.
    var text: String {
        content.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
    }

    /// structuredContent가 있으면 그것, 없으면 text 조각을 JSON으로 읽은 것. 둘 다 아니면 nil.
    var json: Any? {
        if let s = structured, !(s is NSNull) { return s }
        let texts = content.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
        for t in texts + (texts.count > 1 ? [texts.joined()] : []) {
            if let v = MCPToolResult.parseJSON(t) { return v }
        }
        return nil
    }

    /// 앞뒤 설명 문구나 ```json 울타리가 붙어 있어도 첫 JSON 값을 찾아 읽는다.
    static func parseJSON(_ raw: String) -> Any? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if let d = s.data(using: .utf8), let v = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]),
           v is [String: Any] || v is [Any] { return v }
        guard let start = s.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        let close: Character = s[start] == "{" ? "}" : "]"
        guard let end = s.lastIndex(of: close), end > start else { return nil }
        guard let d = String(s[start...end]).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d)
    }
}

/// 다른 호스트로의 리디렉션을 막는다 (Authorization 헤더가 새 나가지 않게).
final class MCPRedirectGuard: NSObject, URLSessionTaskDelegate {
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

enum MCPHTTP {
    /// https만, 단 로컬 시험(127.0.0.1·localhost·::1)은 http도 허용한다.
    static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && isLoopback(host)
    }

    static func isLoopback(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return h == "127.0.0.1" || h == "localhost" || h == "::1"
    }

    static func makeSession(requestTimeout: TimeInterval, guardRedirects: Bool) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = requestTimeout
        cfg.timeoutIntervalForResource = 600
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg, delegate: guardRedirects ? MCPRedirectGuard() : nil, delegateQueue: nil)
    }

    static func header(_ r: HTTPURLResponse, _ name: String) -> String? {
        return r.value(forHTTPHeaderField: name)
    }

    static func retryAfter(_ r: HTTPURLResponse) -> Double {
        let w = Double(r.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces) ?? "") ?? 2
        return min(max(w, 1), 60)
    }
}

/// Streamable HTTP MCP 클라이언트. 여러 요청을 동시에 보내도 된다 (같은 세션을 함께 쓴다).
final class MCPClient: @unchecked Sendable {
    static let protocolVersion = "2025-06-18"
    static let supportedVersions: Set<String> = ["2025-06-18", "2025-03-26", "2024-11-05"]

    let serverURL: URL
    var userAgent = "Synapse/0.4"
    private let tokens: MCPTokenSource?
    private let session: URLSession
    private let requestTimeout: TimeInterval
    private let lock = NSLock()
    private var sessionID: String?
    private var negotiated: String?
    private var nextID = 1
    private var initTask: Task<Void, Error>?
    private var generation = 0
    private(set) var serverInfo: [String: Any] = [:]

    init(serverURL: URL, tokens: MCPTokenSource?, requestTimeout: TimeInterval = 60) {
        self.serverURL = serverURL
        self.tokens = tokens
        self.requestTimeout = requestTimeout
        self.session = MCPHTTP.makeSession(requestTimeout: requestTimeout, guardRedirects: true)
    }

    deinit { session.invalidateAndCancel() }

    private func locked<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }

    // MARK: - 공개 API

    /// initialize → notifications/initialized. 여러 번 불러도 한 번만 한다.
    func start() async throws {
        let (task, _) = locked { () -> (Task<Void, Error>, Int) in
            if let t = initTask { return (t, generation) }
            let t = Task { try await self.handshake() }
            initTask = t
            return (t, generation)
        }
        do { try await task.value } catch {
            locked { if initTask == task { initTask = nil } }   // 다음 호출에서 다시 시도
            throw error
        }
    }

    /// JSON-RPC 요청 하나. 결과(result) 객체를 돌려준다.
    func request(_ method: String, params: [String: Any]? = nil) async throws -> [String: Any] {
        try await start()
        return try await rpc(method, params: params, allowReinit: true)
    }

    func listTools() async throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        var cursor: String?
        repeat {
            let r = try await request("tools/list", params: cursor.map { ["cursor": $0] })
            out += (r["tools"] as? [[String: Any]]) ?? []
            let next = r["nextCursor"] as? String
            cursor = (next?.isEmpty ?? true) || next == cursor ? nil : next
        } while cursor != nil && out.count < 5000
        return out
    }

    func callTool(_ name: String, arguments: [String: Any]) async throws -> MCPToolResult {
        let r = try await request("tools/call", params: ["name": name, "arguments": arguments])
        return MCPToolResult(content: (r["content"] as? [[String: Any]]) ?? [],
                             structured: r["structuredContent"],
                             isError: (r["isError"] as? Bool) ?? false)
    }

    /// 세션 종료 (DELETE). 실패해도 상관없다.
    func close() async {
        guard let sid = locked({ sessionID }) else { return }
        var req = URLRequest(url: serverURL, timeoutInterval: 5)
        req.httpMethod = "DELETE"
        req.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id")
        if let v = locked({ negotiated }) { req.setValue(v, forHTTPHeaderField: "MCP-Protocol-Version") }
        if let t = tokens, let tok = try? await t.accessToken() { req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization") }
        _ = try? await session.data(for: req)
        locked { sessionID = nil; initTask = nil }
    }

    // MARK: - 내부

    private func handshake() async throws {
        let params: [String: Any] = [
            "protocolVersion": MCPClient.protocolVersion,
            "capabilities": [String: Any](),
            "clientInfo": ["name": "Synapse", "version": "0.4"],
        ]
        let r = try await rpc("initialize", params: params, allowReinit: false)
        let v = (r["protocolVersion"] as? String) ?? MCPClient.protocolVersion
        guard MCPClient.supportedVersions.contains(v) else {
            throw MCPError(kind: .protocolError, message: "이 MCP 서버의 규격 버전(\(MCPError.detail(v)))은 아직 지원하지 않아요.")
        }
        locked { negotiated = v; serverInfo = (r["serverInfo"] as? [String: Any]) ?? [:] }
        _ = try await post(["jsonrpc": "2.0", "method": "notifications/initialized"], id: nil, allowReinit: false)
    }

    private func rpc(_ method: String, params: [String: Any]?, allowReinit: Bool) async throws -> [String: Any] {
        let id: Int = locked { defer { nextID += 1 }; return nextID }
        var body: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let p = params { body["params"] = p }
        guard let msg = try await post(body, id: id, allowReinit: allowReinit) else {
            throw MCPError(kind: .protocolError, message: "MCP 서버가 응답을 보내지 않았어요.")
        }
        if let err = msg["error"] as? [String: Any] {
            let code = (err["code"] as? Int) ?? 0
            let text = (err["message"] as? String) ?? ""
            throw MCPError(kind: .protocolError, message: "MCP 서버가 요청을 처리하지 못했어요. (\(code) \(MCPError.detail(text)))")
        }
        return (msg["result"] as? [String: Any]) ?? [:]
    }

    /// 한 번의 POST. id가 있으면 그 id의 응답 메시지를, 알림이면 nil을 돌려준다.
    private func post(_ body: [String: Any], id: Int?, allowReinit: Bool) async throws -> [String: Any]? {
        let payload = try JSONSerialization.data(withJSONObject: body)
        var limited = 0
        var refreshed = false
        var reinitialized = false
        while true {
            try Task.checkCancellation()
            var req = URLRequest(url: serverURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let (sid, ver) = locked { (sessionID, negotiated) }
            if let sid = sid { req.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id") }
            if let ver = ver { req.setValue(ver, forHTTPHeaderField: "MCP-Protocol-Version") }
            var used: String?
            if let t = tokens {
                let tok = try await t.accessToken()
                used = tok
                req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            }
            req.httpBody = payload

            let bytes: URLSession.AsyncBytes
            let resp: URLResponse
            do {
                (bytes, resp) = try await session.bytes(for: req)
            } catch let e as URLError where e.code == .cancelled {
                throw CancellationError()
            } catch let e as URLError {
                throw MCPError.network(e)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw MCPError(kind: .network, message: "네트워크 오류가 생겼어요. 잠시 후 다시 시도해 주세요.")
            }
            guard let http = resp as? HTTPURLResponse else {
                bytes.task.cancel()
                throw MCPError(kind: .server, message: "MCP 서버 응답을 읽지 못했어요.")
            }
            let code = http.statusCode
            if (200..<300).contains(code) {
                if let newSID = MCPHTTP.header(http, "Mcp-Session-Id"), !newSID.isEmpty, (body["method"] as? String) == "initialize" {
                    locked { sessionID = newSID }
                }
                guard let id = id, code != 202 else { bytes.task.cancel(); return nil }
                let type = (MCPHTTP.header(http, "Content-Type") ?? "").lowercased()
                if type.contains("text/event-stream") {
                    return try await readSSE(bytes, id: id)
                }
                return try await readJSON(bytes, id: id)
            }
            bytes.task.cancel()
            switch code {
            case 401:
                if let t = tokens, let used = used, !refreshed {
                    refreshed = true
                    try await t.refreshAfterUnauthorized(failedToken: used)
                    continue
                }
                throw MCPError(kind: .reLogin, message: MCPError.reLoginMessage, status: code)
            case 403:
                throw MCPError(kind: .permission, message: MCPError.permission.message, status: code)
            case 404 where sid != nil && allowReinit && !reinitialized:
                // 세션이 만료됨: 새 세션으로 한 번 다시 시도한다.
                reinitialized = true
                locked { if sessionID == sid { sessionID = nil; negotiated = nil; initTask = nil; generation += 1 } }
                try await start()
                continue
            case 404:
                throw MCPError(kind: .notFound, message: "MCP 서버 주소를 찾지 못했어요. 주소를 확인해 주세요.", status: code)
            case 429:
                if limited >= 3 {
                    throw MCPError(kind: .rateLimited, message: "요청이 너무 많아 잠시 막혔어요. 몇 분 뒤 다시 시도해 주세요.", status: code)
                }
                limited += 1
                try await Task.sleep(nanoseconds: UInt64(MCPHTTP.retryAfter(http) * 1_000_000_000))
            case 400:
                throw MCPError(kind: .protocolError, message: "MCP 서버가 요청을 거부했어요. (400)", status: code)
            case 500..<600:
                throw MCPError(kind: .server, message: "MCP 서버가 응답하지 않아요. 잠시 후 다시 시도해 주세요. (\(code))", status: code)
            default:
                throw MCPError(kind: .server, message: "요청이 처리되지 않았어요. (\(code))", status: code)
            }
        }
    }

    private static func matches(_ obj: Any, id: Int) -> [String: Any]? {
        if let arr = obj as? [Any] {
            for o in arr { if let m = matches(o, id: id) { return m } }
            return nil
        }
        guard let d = obj as? [String: Any], d["method"] == nil, d["result"] != nil || d["error"] != nil else { return nil }
        if let n = d["id"] as? NSNumber, n.intValue == id { return d }
        if let s = d["id"] as? String, s == String(id) { return d }
        return nil
    }

    static let maxJSONBytes = 16 * 1024 * 1024      // JSON 응답 하나 (동시 4개여도 ~64MB)
    static let maxSSEBytes = 32 * 1024 * 1024       // SSE 응답 하나 전체
    static let maxSSELine = 8 * 1024 * 1024         // SSE 한 줄·한 이벤트

    private static var tooLarge: MCPError { MCPError(kind: .protocolError, message: "MCP 서버 응답이 너무 커서 읽지 않았어요.") }
    private static var tooSlow: MCPError { MCPError(kind: .network, message: "응답이 너무 늦어요. 잠시 후 다시 시도해 주세요.") }

    /// 마감 시각이 지나면 스트림을 끊는다 (바이트가 조금씩 흘러들어 유휴 시간 제한에 안 걸리는 경우까지).
    private final class Watchdog: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        private var item: DispatchWorkItem?
        init(_ task: URLSessionDataTask, after seconds: TimeInterval) {
            let w = DispatchWorkItem { [weak self, weak task] in
                guard let self = self else { return }
                self.lock.lock(); self.fired = true; self.lock.unlock()
                task?.cancel()
            }
            item = w
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: w)
        }
        var didFire: Bool { lock.lock(); defer { lock.unlock() }; return fired }
        func stop() { item?.cancel() }
    }

    private func readJSON(_ bytes: URLSession.AsyncBytes, id: Int) async throws -> [String: Any] {
        let dog = Watchdog(bytes.task, after: max(requestTimeout * 5, 120))
        defer { dog.stop() }
        var data = Data()
        do {
            for try await b in bytes {
                data.append(b)
                if data.count > MCPClient.maxJSONBytes { bytes.task.cancel(); throw MCPClient.tooLarge }
            }
        } catch let e as URLError where e.code == .cancelled {
            if dog.didFire { throw MCPClient.tooSlow }
            throw CancellationError()
        } catch let e as URLError { throw MCPError.network(e) }
        guard let obj = try? JSONSerialization.jsonObject(with: data), let m = MCPClient.matches(obj, id: id) else {
            throw MCPError(kind: .protocolError, message: "MCP 서버 응답을 읽지 못했어요.")
        }
        return m
    }

    /// SSE 스트림에서 같은 id의 응답이 나올 때까지 읽는다. 알림·다른 메시지는 건너뛴다.
    /// 전체 32MB·한 줄(또는 한 이벤트) 8MB를 넘거나 마감 시각이 지나면 끊는다.
    private func readSSE(_ bytes: URLSession.AsyncBytes, id: Int) async throws -> [String: Any] {
        let dog = Watchdog(bytes.task, after: max(requestTimeout * 5, 120))
        defer { dog.stop() }
        var line: [UInt8] = []
        var dataLines: [String] = []
        var eventBytes = 0
        var total = 0
        func dispatch() -> [String: Any]? {
            defer { dataLines.removeAll(); eventBytes = 0 }
            guard !dataLines.isEmpty, let d = dataLines.joined(separator: "\n").data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) else { return nil }
            return MCPClient.matches(obj, id: id)
        }
        func take(_ raw: [UInt8]) throws -> [String: Any]? {
            var l = raw
            if l.last == 0x0D { l.removeLast() }
            if l.isEmpty { return dispatch() }
            if l.starts(with: [0x64, 0x61, 0x74, 0x61, 0x3A]) {   // "data:"
                var v = l.dropFirst(5)
                if v.first == 0x20 { v = v.dropFirst() }
                eventBytes += v.count + 1
                if eventBytes > MCPClient.maxSSELine { throw MCPClient.tooLarge }
                dataLines.append(String(decoding: v, as: UTF8.self))
            }
            return nil   // event:, id:, retry:, ": 주석"은 무시
        }
        do {
            for try await b in bytes {
                total += 1
                if total > MCPClient.maxSSEBytes { bytes.task.cancel(); throw MCPClient.tooLarge }
                if b == 0x0A {
                    if let m = try take(line) { bytes.task.cancel(); return m }
                    line.removeAll(keepingCapacity: true)
                } else {
                    line.append(b)
                    if line.count > MCPClient.maxSSELine { bytes.task.cancel(); throw MCPClient.tooLarge }
                }
            }
        } catch let e as URLError where e.code == .cancelled {
            if dog.didFire { throw MCPClient.tooSlow }
            throw CancellationError()
        } catch let e as URLError {
            throw MCPError.network(e)
        } catch let e as MCPError {
            bytes.task.cancel()
            throw e
        }
        if !line.isEmpty, let m = try take(line) { return m }
        if let m = dispatch() { return m }
        throw MCPError(kind: .protocolError, message: "MCP 서버 응답이 중간에 끊겼어요. 잠시 후 다시 시도해 주세요.")
    }

    // MARK: - 인증 전 탐색

    /// 토큰 없이 initialize를 보내 본다 (MCPAuth가 401의 WWW-Authenticate를 얻는 데 쓴다).
    static func probe(serverURL: URL, timeout: TimeInterval = 30) async throws -> (status: Int, wwwAuthenticate: String?) {
        let s = MCPHTTP.makeSession(requestTimeout: timeout, guardRedirects: true)
        defer { s.finishTasksAndInvalidate() }
        var req = URLRequest(url: serverURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("Synapse/0.4", forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = ["jsonrpc": "2.0", "id": 0, "method": "initialize",
                                   "params": ["protocolVersion": protocolVersion, "capabilities": [String: Any](),
                                              "clientInfo": ["name": "Synapse", "version": "0.4"]]]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        do {
            let (bytes, resp) = try await s.bytes(for: req)
            bytes.task.cancel()
            guard let http = resp as? HTTPURLResponse else {
                throw MCPError(kind: .server, message: "MCP 서버 응답을 읽지 못했어요.")
            }
            return (http.statusCode, MCPHTTP.header(http, "WWW-Authenticate"))
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch let e as URLError {
            throw MCPError.network(e)
        }
    }
}
