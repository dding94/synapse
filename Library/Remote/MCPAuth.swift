import Foundation
import CryptoKit
import Security

// MCP 인증(OAuth 2.1, MCP authorization 규격) — docs/V04.md §6.1.
// 401 WWW-Authenticate(resource_metadata) → protected resource metadata → authorization server metadata
// → 동적 클라이언트 등록 → PKCE(S256)+state 인가 → 루프백(127.0.0.1) 콜백 → 토큰 교환 → 자격 증명 JSON.
// 토큰·코드·verifier는 로그·오류 문구·파일에 남기지 않는다. 저장은 호출한 쪽이 Plugins.secrets로 한다.

/// SecretStore에 문자열(JSON)로 저장하는 자격 증명.
struct MCPCredential: Codable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Double?          // 유닉스 초. nil = 서버가 만료를 알려 주지 않음
    var clientID: String
    var clientSecret: String?       // token_endpoint_auth_method none이면 없음
    var tokenEndpoint: String
    var resource: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token", expiresAt = "expires_at"
        case clientID = "client_id", clientSecret = "client_secret", tokenEndpoint = "token_endpoint", resource
    }

    static func decode(_ s: String) -> MCPCredential? {
        guard let d = s.data(using: .utf8), let c = try? JSONDecoder().decode(MCPCredential.self, from: d),
              !c.accessToken.isEmpty else { return nil }
        return c
    }

    func encoded() -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return (try? e.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// 만료까지 margin초 안 남았으면 true. 만료 정보가 없으면 false (401을 받으면 그때 갱신).
    func expiresSoon(margin: TimeInterval = 120, now: Date = Date()) -> Bool {
        guard let e = expiresAt else { return false }
        return now.timeIntervalSince1970 + margin >= e
    }
}

enum MCPAuth {
    static let clientName = "Synapse"

    // MARK: - 공개 API

    /// 브라우저 로그인 한 번으로 자격 증명 JSON(String)을 돌려준다. 오류는 모두 MCPAuthError:
    /// 사용자가 거부·취소(또는 Task 취소) → .cancelled, timeout 안에 콜백이 없으면 → .timedOut.
    static func authorize(serverURL: URL, openURL: @escaping (URL) -> Void, timeout: TimeInterval = 300) async throws -> String {
        do {
            return try await authorizeFlow(serverURL: serverURL, openURL: openURL, timeout: timeout)
        } catch let e as MCPAuthError {
            throw e
        } catch is CancellationError {
            throw MCPAuthError.cancelled
        } catch let e as MCPError {
            switch e.kind {
            case .cancelled: throw MCPAuthError.cancelled
            case .timedOut: throw MCPAuthError.timedOut
            case .network, .rateLimited, .server, .notFound: throw MCPAuthError.network(e.message)
            default: throw MCPAuthError.discoveryFailed(e.message)
            }
        } catch {
            throw MCPAuthError.network("네트워크 오류가 생겼어요. 잠시 후 다시 시도해 주세요.")
        }
    }

    private static func authorizeFlow(serverURL: URL, openURL: @escaping (URL) -> Void, timeout: TimeInterval) async throws -> String {
        guard MCPHTTP.isAllowed(serverURL) else { throw MCPAuthError.unsupportedServer(MCPError.badServer.message) }
        let deadline = Date().addingTimeInterval(timeout)
        let http = MCPHTTP.makeSession(requestTimeout: 30, guardRedirects: false)
        defer { http.finishTasksAndInvalidate() }

        // 1) 서버 탐색: 401의 WWW-Authenticate
        let probe = try await MCPClient.probe(serverURL: serverURL)
        let challenge = probe.status == 401 ? parseChallenge(probe.wwwAuthenticate ?? "") : [:]

        // 2) protected resource metadata (없으면 2025-03-26 규격처럼 서버 출처를 인가 서버로 본다)
        let prm = try await protectedResourceMetadata(serverURL: serverURL, hint: challenge["resource_metadata"], http: http)
        var resource = canonicalResource(serverURL)
        if let r = prm?["resource"] as? String, let ru = URL(string: r) {
            guard ru.host?.lowercased() == serverURL.host?.lowercased() else {
                throw MCPError(kind: .config, message: "MCP 서버의 인증 정보가 서버 주소와 맞지 않아요.")
            }
            resource = r
        }
        let issuers = (prm?["authorization_servers"] as? [String]) ?? []
        let issuer = issuers.compactMap { URL(string: $0) }.first(where: MCPHTTP.isAllowed) ?? origin(serverURL)

        // 3) authorization server metadata
        let meta = try await authorizationServerMetadata(issuer: issuer, legacyDefaults: prm == nil, http: http)
        guard let authEP = (meta["authorization_endpoint"] as? String).flatMap(URL.init(string:)), MCPHTTP.isAllowed(authEP),
              let tokenEP = (meta["token_endpoint"] as? String).flatMap(URL.init(string:)), MCPHTTP.isAllowed(tokenEP) else {
            throw MCPError(kind: .config, message: "MCP 서버의 로그인 정보를 읽지 못했어요.")
        }
        if let methods = meta["code_challenge_methods_supported"] as? [String], !methods.contains("S256") {
            throw MCPAuthError.unsupportedServer("이 MCP 서버는 안전한 로그인(PKCE S256)을 지원하지 않아요.")
        }
        guard let regEP = (meta["registration_endpoint"] as? String).flatMap(URL.init(string:)), MCPHTTP.isAllowed(regEP) else {
            throw MCPAuthError.unsupportedServer("이 MCP 서버는 앱 자동 등록을 지원하지 않아요.")
        }

        // 4) 루프백 수신기 → 5) 동적 클라이언트 등록
        let receiver = try LoopbackReceiver()
        defer { receiver.close() }
        let redirectURI = "http://127.0.0.1:\(receiver.port)/callback"
        let client = try await register(endpoint: regEP, redirectURI: redirectURI, http: http)

        // 6) PKCE + state → 브라우저
        let verifier = randomToken(32)
        let state = randomToken(24)
        var c = URLComponents(url: authEP, resolvingAgainstBaseURL: false)!
        var items = c.queryItems ?? []
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: client.id),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: codeChallenge(verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "resource", value: resource),
        ]
        let scope = challenge["scope"] ?? (prm?["scopes_supported"] as? [String])?.joined(separator: " ")
        if let s = scope, !s.isEmpty { items.append(URLQueryItem(name: "scope", value: s)) }
        // 값은 엄격하게 퍼센트 인코딩한다 (redirect_uri·resource의 ":/"와 "+"까지)
        var strict = CharacterSet.alphanumerics
        strict.insert(charactersIn: "-._~")
        let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: strict) ?? s }
        c.percentEncodedQuery = items.map { "\(enc($0.name))=\(enc($0.value ?? ""))" }.joined(separator: "&")
        guard let authorizeURL = c.url else { throw MCPError(kind: .config, message: "로그인 주소를 만들지 못했어요.") }
        await MainActor.run { openURL(authorizeURL) }

        // 7) 콜백 → 8) 토큰 교환
        let code = try await receiver.wait(state: state, deadline: deadline)
        var form = ["grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI,
                    "client_id": client.id, "code_verifier": verifier, "resource": resource]
        if let s = client.secret { form["client_secret"] = s }
        let tok = try await tokenRequest(endpoint: tokenEP, form: form, http: http, refreshing: false)
        guard let access = tok["access_token"] as? String, !access.isEmpty else {
            throw MCPAuthError.tokenFailed("로그인을 마치지 못했어요. 다시 시도해 주세요.")
        }
        let cred = MCPCredential(accessToken: access, refreshToken: tok["refresh_token"] as? String,
                                 expiresAt: expiry(tok["expires_in"]), clientID: client.id, clientSecret: client.secret,
                                 tokenEndpoint: tokenEP.absoluteString, resource: resource)
        return cred.encoded()
    }

    /// 갱신 토큰으로 새 접근 토큰을 받는다. 갱신 토큰이 없거나 거절되면 MCPError.reLogin, 통신 실패는 네트워크 오류.
    static func refresh(_ cred: MCPCredential) async throws -> MCPCredential {
        guard let rt = cred.refreshToken, !rt.isEmpty, let ep = URL(string: cred.tokenEndpoint), MCPHTTP.isAllowed(ep) else {
            throw MCPError.reLogin
        }
        let http = MCPHTTP.makeSession(requestTimeout: 30, guardRedirects: true)
        defer { http.finishTasksAndInvalidate() }
        var form = ["grant_type": "refresh_token", "refresh_token": rt, "client_id": cred.clientID]
        if let r = cred.resource { form["resource"] = r }
        if let s = cred.clientSecret { form["client_secret"] = s }
        let tok = try await tokenRequest(endpoint: ep, form: form, http: http, refreshing: true)
        guard let access = tok["access_token"] as? String, !access.isEmpty else { throw MCPError.reLogin }
        var out = cred
        out.accessToken = access
        if let nr = tok["refresh_token"] as? String, !nr.isEmpty { out.refreshToken = nr }   // 회전되면 새 것
        out.expiresAt = expiry(tok["expires_in"])
        return out
    }

    /// 자격 증명 JSON 문자열을 받아 갱신한 JSON 문자열을 돌려준다.
    static func refresh(credential: String) async throws -> String {
        guard let c = MCPCredential.decode(credential) else { throw MCPError.reLogin }
        return try await refresh(c).encoded()
    }

    // MARK: - 탐색

    /// `Bearer realm="x", resource_metadata="https://…", scope="a b"` → 소문자 키 사전.
    static func parseChallenge(_ header: String) -> [String: String] {
        var out: [String: String] = [:]
        let re = try! NSRegularExpression(pattern: "([A-Za-z0-9_\\-]+)\\s*=\\s*(?:\"((?:[^\"\\\\]|\\\\.)*)\"|([^\\s,]+))")
        let ns = header as NSString
        for m in re.matches(in: header, range: NSRange(location: 0, length: ns.length)) {
            let k = ns.substring(with: m.range(at: 1)).lowercased()
            let v = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)).replacingOccurrences(of: "\\\"", with: "\"")
                                                          : ns.substring(with: m.range(at: 3))
            if out[k] == nil { out[k] = v }
        }
        return out
    }

    /// RFC 8707 resource: 스킴·호스트 소문자, 조각·쿼리 없음, 끝의 "/" 없음.
    static func canonicalResource(_ url: URL) -> String {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents()
        c.scheme = c.scheme?.lowercased(); c.host = c.host?.lowercased(); c.fragment = nil; c.query = nil
        var s = c.url?.absoluteString ?? url.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func origin(_ url: URL) -> URL {
        var c = URLComponents()
        c.scheme = url.scheme; c.host = url.host; c.port = url.port
        return c.url ?? url
    }

    private static func wellKnown(_ base: URL, _ name: String, path: String) -> URL? {
        let p = path == "/" ? "" : (path.hasSuffix("/") ? String(path.dropLast()) : path)
        return URL(string: origin(base).absoluteString + "/.well-known/" + name + p)
    }

    /// 2xx JSON 객체만 돌려준다. 404 등은 nil, 통신 실패는 오류.
    private static func getJSON(_ url: URL, http: URLSession) async throws -> [String: Any]? {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Synapse/0.4", forHTTPHeaderField: "User-Agent")
        req.setValue(MCPClient.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await http.data(for: req) }
        catch let e as URLError where e.code == .cancelled { throw CancellationError() }
        catch let e as URLError { throw MCPError.network(e) }
        guard let code = (resp as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func protectedResourceMetadata(serverURL: URL, hint: String?, http: URLSession) async throws -> [String: Any]? {
        var candidates: [URL] = []
        if let h = hint, let u = URL(string: h), MCPHTTP.isAllowed(u) { candidates.append(u) }
        let path = serverURL.path
        if !path.isEmpty && path != "/", let u = wellKnown(serverURL, "oauth-protected-resource", path: path) { candidates.append(u) }
        if let u = wellKnown(serverURL, "oauth-protected-resource", path: "") { candidates.append(u) }
        for u in candidates {
            if let m = try await getJSON(u, http: http), m["authorization_servers"] != nil || m["resource"] != nil { return m }
        }
        return nil
    }

    static func authorizationServerMetadata(issuer: URL, legacyDefaults: Bool, http: URLSession) async throws -> [String: Any] {
        let path = issuer.path
        var candidates: [URL] = []
        if !path.isEmpty && path != "/" {
            candidates += [wellKnown(issuer, "oauth-authorization-server", path: path),
                           wellKnown(issuer, "openid-configuration", path: path),
                           URL(string: canonicalResource(issuer) + "/.well-known/openid-configuration")].compactMap { $0 }
        } else {
            candidates += [wellKnown(issuer, "oauth-authorization-server", path: ""),
                           wellKnown(issuer, "openid-configuration", path: "")].compactMap { $0 }
        }
        for u in candidates {
            if let m = try await getJSON(u, http: http), m["authorization_endpoint"] != nil, m["token_endpoint"] != nil { return m }
        }
        if legacyDefaults {   // 2025-03-26 규격: 메타데이터가 없으면 기본 경로
            let o = origin(issuer).absoluteString
            return ["authorization_endpoint": o + "/authorize", "token_endpoint": o + "/token", "registration_endpoint": o + "/register"]
        }
        throw MCPAuthError.discoveryFailed("MCP 서버의 로그인 정보를 찾지 못했어요.")
    }

    // MARK: - 등록·토큰

    static func register(endpoint: URL, redirectURI: String, http: URLSession) async throws -> (id: String, secret: String?) {
        let body: [String: Any] = [
            "client_name": clientName,
            "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ]
        var req = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Synapse/0.4", forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await http.data(for: req) }
        catch let e as URLError where e.code == .cancelled { throw CancellationError() }
        catch let e as URLError { throw MCPError.network(e) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(code), let id = obj["client_id"] as? String, !id.isEmpty else {
            let why = (obj["error"] as? String).map { " (\(MCPError.detail($0)))" } ?? " (\(code))"
            throw MCPAuthError.registrationFailed("Synapse를 MCP 서버에 등록하지 못했어요." + why)
        }
        let secret = (obj["client_secret"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (id, secret)
    }

    static func formEncode(_ form: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let s = form.keys.sorted().map { k in
            "\(k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k)=\(form[k]!.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
        return Data(s.utf8)
    }

    /// 토큰 엔드포인트 호출. 갱신(refreshing) 중 거절(400·401)은 MCPError.reLogin.
    static func tokenRequest(endpoint: URL, form: [String: String], http: URLSession, refreshing: Bool) async throws -> [String: Any] {
        var req = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Synapse/0.4", forHTTPHeaderField: "User-Agent")
        req.httpBody = formEncode(form)
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await http.data(for: req) }
        catch let e as URLError where e.code == .cancelled { throw CancellationError() }
        catch let e as URLError { throw MCPError.network(e) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if (200..<300).contains(code) { return obj }
        if refreshing {
            if (400..<500).contains(code) { throw MCPError(kind: .reLogin, message: MCPError.reLoginMessage, status: code) }
            throw MCPError(kind: .server, message: "로그인 서버가 응답하지 않아요. 잠시 후 다시 시도해 주세요. (\(code))", status: code)
        }
        let why = (obj["error"] as? String).map { MCPError.detail($0) } ?? String(code)
        throw MCPAuthError.tokenFailed("로그인을 마치지 못했어요. 다시 시도해 주세요. (\(why))")
    }

    static func expiry(_ v: Any?) -> Double? {
        let secs = (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init)
        guard let s = secs, s > 0 else { return nil }
        return Date().timeIntervalSince1970 + s
    }

    // MARK: - PKCE

    static func randomToken(_ bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        if SecRandomCopyBytes(kSecRandomDefault, bytes, &b) != errSecSuccess {
            var g = SystemRandomNumberGenerator()
            b = (0..<bytes).map { _ in UInt8.random(in: 0...255, using: &g) }
        }
        return base64url(Data(b))
    }

    static func codeChallenge(_ verifier: String) -> String {
        return base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64url(_ d: Data) -> String {
        return d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// MCPAuth.authorize가 던지는 오류. 화면은 cancelled·timedOut을 `{ ok:false, cancelled:true }`로 바꾼다.
enum MCPAuthError: Error, LocalizedError, Equatable {
    case cancelled                      // 사용자가 거부(access_denied)·창 닫기, 또는 Task 취소
    case timedOut                       // timeout 안에 콜백이 오지 않음
    case unsupportedServer(String)      // https가 아님, 자동 등록·S256 미지원
    case discoveryFailed(String)        // 인증 메타데이터를 찾지 못함
    case registrationFailed(String)     // 동적 클라이언트 등록 실패
    case authorizationFailed(String)    // 콜백에 access_denied 외의 오류
    case tokenFailed(String)            // 코드 → 토큰 교환 실패
    case network(String)                // 통신 실패

    var errorDescription: String? {
        switch self {
        case .cancelled: return "로그인을 취소했어요."
        case .timedOut: return "로그인 시간이 지났어요. 다시 시도해 주세요."
        case .unsupportedServer(let m), .discoveryFailed(let m), .registrationFailed(let m),
             .authorizationFailed(let m), .tokenFailed(let m), .network(let m):
            return m
        }
    }
}

/// 127.0.0.1의 임의 포트에서 OAuth 콜백 한 번을 받는 아주 작은 HTTP 서버 (BSD 소켓).
/// state가 맞는 `/callback` 요청 하나만 받아들이고, 나머지(파비콘·잘못된 state)는 거절한 채 계속 기다린다.
final class LoopbackReceiver: @unchecked Sendable {
    let port: UInt16
    private var fd: Int32
    private let lock = NSLock()
    private var cancelled = false
    private var stopping = false
    private var looping = false

    init() throws {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { throw MCPAuthError.network("로그인 응답을 받을 준비를 하지 못했어요.") }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, len) } }
        guard ok == 0, listen(s, 16) == 0 else {
            Darwin.close(s)
            throw MCPAuthError.network("로그인 응답을 받을 준비를 하지 못했어요.")
        }
        var bound = sockaddr_in()
        var blen = len
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &blen) } }
        port = UInt16(bigEndian: bound.sin_port)
        fd = s
    }

    deinit { close() }

    /// 기다리는 중이면 루프가 스스로 정리하고, 아니면 바로 소켓을 닫는다.
    func close() {
        lock.lock(); stopping = true; let s = fd; let running = looping; if !running { fd = -1 }; lock.unlock()
        if !running && s >= 0 { Darwin.close(s) }
    }

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }

    private func locked<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }

    /// 올바른 콜백의 code를 돌려준다. 취소 → .cancelled, 시간 초과 → .timedOut.
    func wait(state: String, deadline: Date) async throws -> String {
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                Thread.detachNewThread { cont.resume(with: self.loop(state: state, deadline: deadline)) }
            }
        } onCancel: { self.cancel() }
    }

    static let maxConnections = 16              // 동시에 붙들고 있는 연결 수 (넘으면 가장 오래된 것을 끊는다)
    static let connectionDeadline: TimeInterval = 3
    static let maxRequestBytes = 16384

    private struct Conn { let fd: Int32; var buf: [UInt8]; let deadline: Date }

    private static func setNonBlocking(_ s: Int32) {
        let flags = fcntl(s, F_GETFL, 0)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// 스레드 하나에서 poll로 모든 연결을 처리한다 (느린 연결이 진짜 콜백을 막거나 스레드를 붙잡지 못하게).
    private func loop(state: String, deadline: Date) -> Result<String, Error> {
        let started: Int32? = locked {
            if fd < 0 || stopping { return nil }
            looping = true
            return fd
        }
        guard let lfd = started else { return .failure(MCPAuthError.cancelled) }
        LoopbackReceiver.setNonBlocking(lfd)
        var conns: [Conn] = []
        defer {
            for c in conns { Darwin.close(c.fd) }
            locked { looping = false; if fd >= 0 { Darwin.close(fd); fd = -1 } }
        }
        var tmp = [UInt8](repeating: 0, count: 4096)
        while true {
            let (stop, canc) = locked { (stopping, cancelled) }
            if stop || canc { return .failure(MCPAuthError.cancelled) }
            let now = Date()
            if now > deadline { return .failure(MCPAuthError.timedOut) }
            conns.removeAll { c in
                if now > c.deadline { Darwin.close(c.fd); return true }
                return false
            }
            var pfds = [pollfd(fd: lfd, events: Int16(POLLIN), revents: 0)]
            pfds += conns.map { pollfd(fd: $0.fd, events: Int16(POLLIN), revents: 0) }
            if poll(&pfds, nfds_t(pfds.count), 100) <= 0 { continue }

            var finished: [Int] = []
            for i in conns.indices where pfds[i + 1].revents != 0 {
                var eof = false
                while conns[i].buf.count <= LoopbackReceiver.maxRequestBytes {
                    let k = recv(conns[i].fd, &tmp, tmp.count, 0)
                    if k > 0 { conns[i].buf += tmp[0..<k]; continue }
                    if k == 0 || (errno != EAGAIN && errno != EWOULDBLOCK) { eof = true }
                    break
                }
                let buf = conns[i].buf
                let complete = buf.count >= 4 && buf.indices.dropLast(3).contains { buf[$0] == 13 && buf[$0 + 1] == 10 && buf[$0 + 2] == 13 && buf[$0 + 3] == 10 }
                if complete || eof || buf.count > LoopbackReceiver.maxRequestBytes {
                    finished.append(i)
                    if let r = process(conns[i].fd, buf, state: state, complete: complete) { return r }
                }
            }
            for i in finished.reversed() { Darwin.close(conns[i].fd); conns.remove(at: i) }

            if pfds[0].revents != 0 {
                while true {
                    let c = accept(lfd, nil, nil)
                    if c < 0 { break }
                    LoopbackReceiver.setNonBlocking(c)
                    if conns.count >= LoopbackReceiver.maxConnections {
                        Darwin.close(conns[0].fd); conns.removeFirst()
                    }
                    conns.append(Conn(fd: c, buf: [], deadline: Date().addingTimeInterval(LoopbackReceiver.connectionDeadline)))
                }
            }
        }
    }

    /// 요청 하나에 답한다. 올바른 콜백이면 결과를, 아니면 nil(계속 기다림).
    private func process(_ c: Int32, _ data: [UInt8], state: String, complete: Bool) -> Result<String, Error>? {
        guard complete else { respond(c, 400, "잘못된 요청이에요."); return nil }
        let head = String(decoding: data, as: UTF8.self)
        let first = head.components(separatedBy: "\r\n").first ?? ""
        let parts = first.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", let comps = URLComponents(string: "http://127.0.0.1" + parts[1]),
              comps.path == "/callback" else {
            respond(c, 404, "찾을 수 없어요.")
            return nil
        }
        var q: [String: String] = [:]
        for i in comps.queryItems ?? [] where q[i.name] == nil { q[i.name] = i.value ?? "" }
        guard let st = q["state"], st == state else {
            respond(c, 400, "잘못된 로그인 응답이에요. Synapse에서 다시 시도해 주세요.")
            return nil
        }
        if let err = q["error"] {
            respond(c, 200, "로그인을 마치지 못했어요. Synapse로 돌아가 다시 시도해 주세요.")
            return .failure(err == "access_denied" ? MCPAuthError.cancelled
                            : MCPAuthError.authorizationFailed("로그인을 마치지 못했어요. (\(MCPError.detail(err)))"))
        }
        guard let code = q["code"], !code.isEmpty else {
            respond(c, 400, "잘못된 로그인 응답이에요. Synapse에서 다시 시도해 주세요.")
            return nil
        }
        respond(c, 200, "로그인했어요. 이 창을 닫고 Synapse로 돌아가세요.")
        return .success(code)
    }

    private func respond(_ c: Int32, _ status: Int, _ line: String) {
        let reason = status == 200 ? "OK" : status == 404 ? "Not Found" : "Bad Request"
        let html = "<!doctype html><html lang=\"ko\"><meta charset=\"utf-8\"><title>Synapse</title>"
            + "<body style=\"font:16px -apple-system,sans-serif;margin:48px\"><p>\(line)</p></body></html>"
        let body = Array(html.utf8)
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        let all = Array(head.utf8) + body
        _ = all.withUnsafeBytes { send(c, $0.baseAddress, all.count, 0) }
    }
}

/// 자격 증명 JSON을 들고 있는 토큰 공급자. 만료 2분 전이면 갱신하고, 동시에 여러 요청이 와도 갱신은 한 번만 한다.
/// account(= sourceId)가 있고 그 계정에 이미 비밀이 저장돼 있으면 갱신된 JSON을 Plugins.secrets에 다시 쓴다.
final class MCPTokenBox: MCPTokenSource, @unchecked Sendable {
    private let lock = NSLock()
    private var cred: MCPCredential?
    private var refreshing: Task<MCPCredential, Error>?
    let account: String?
    /// 시험용: 갱신 함수 바꿔 끼우기
    var refresher: (MCPCredential) async throws -> MCPCredential = { try await MCPAuth.refresh($0) }

    init(credential: String, account: String?) {
        self.cred = MCPCredential.decode(credential)
        self.account = account
    }

    /// 지금 들고 있는 자격 증명 JSON (갱신됐을 수 있다).
    var credentialJSON: String? { locked { cred?.encoded() } }
    var hasCredential: Bool { locked { cred != nil } }
    private func locked<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }

    func accessToken() async throws -> String {
        let c = locked { cred }
        guard let cur = c else { throw MCPError.reLogin }
        if !cur.expiresSoon() { return cur.accessToken }
        return try await refresh(from: cur).accessToken
    }

    func refreshAfterUnauthorized(failedToken: String) async throws {
        let c = locked { cred }
        guard let cur = c else { throw MCPError.reLogin }
        if cur.accessToken != failedToken { return }   // 다른 요청이 이미 갱신했다
        _ = try await refresh(from: cur)
    }

    private func refresh(from cur: MCPCredential) async throws -> MCPCredential {
        let task: Task<MCPCredential, Error> = locked {
            if let t = refreshing { return t }
            let fn = refresher
            let acct = account
            let t = Task { () throws -> MCPCredential in
                // 다른 연결기(동기화·확인)가 먼저 갱신해 저장해 뒀으면 그걸 쓴다 (회전된 갱신 토큰 보호)
                if let a = acct, let s = Plugins.secrets.secret(for: a), let stored = MCPCredential.decode(s),
                   stored.accessToken != cur.accessToken, !stored.expiresSoon() {
                    return stored
                }
                return try await fn(cur)
            }
            refreshing = t
            return t
        }
        do {
            let fresh = try await task.value
            let changed: Bool = locked {
                let ch = cred != fresh
                cred = fresh
                if refreshing == task { refreshing = nil }
                return ch
            }
            if changed, let a = account, Plugins.secrets.secret(for: a) != nil {
                try? Plugins.secrets.setSecret(fresh.encoded(), for: a)
            }
            return fresh
        } catch {
            locked { if refreshing == task { refreshing = nil } }
            throw error
        }
    }
}
