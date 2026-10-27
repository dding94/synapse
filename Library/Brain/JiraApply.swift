import Foundation

// v0.8 §6.3 — 사람이 승인한 Jira 제안 하나를 반영한다 (E3). 앱 브리지(main.swift jiraApply)와 synapse-cli(brain jira-apply, 가짜 서버 시험용)가 부른다.
// 순서: 고친 값(overrides) 검사 → jiraBegin(조건부 UPDATE — 한 제안에 한 번만) → 출처 설정·토큰 → JiraWriter.apply(전체 시간 제한)
//       → jiraFinish(applied|failed, ai_log "jira") → 성공이면 library.syncRemoteSoon(id:)로 바뀐 상태가 화면에 다시 들어오게 한다.
// 시험 홈(기본 위치가 아닌 홈이나 SYNAPSE_TEST_* 환경)에서는 127.0.0.1·localhost 가짜 서버에만 반영한다 — 시험이 진짜 Jira를 바꾸지 않게.
// 아무 스레드에서나 불러도 된다(사서 호출은 사서 큐로 넘어간다). 실패는 던지지 않고 {ok:false, error}로 돌려준다.

enum JiraApply {
    /// 반영 한 번의 전체 시간 제한(초). 사서가 '반영 중'으로 남은 제안을 실패로 돌리는 10분보다 훨씬 짧아야 한다.
    static let deadline: Double = 120

    /// 승인한 제안 하나를 반영한다. overrides: {"body": 고친 댓글, "to": 고친 상태}
    /// 결과: {ok:true, id, key, op, message, url?, already?} | {ok:false, error, id, op?, key?, state?}
    static func run(brain: BrainAPI, library: Library, id: String, overrides: [String: Any]) async -> [String: Any] {
        func fail(_ m: String, _ extra: [String: Any] = [:]) -> [String: Any] {
            var r: [String: Any] = ["ok": false, "error": m, "id": id]
            for (k, v) in extra { r[k] = v }
            return r
        }
        // 1) 고친 값 검사 — 상태를 바꾸기 전에
        var edited: [String: String] = [:]
        if let raw = overrides["body"], !(raw is NSNull) {
            guard let b = raw as? String else { return fail("댓글 글이 올바르지 않아요.") }
            let t = b.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...4000).contains(t.count) else { return fail("댓글은 1~4,000자로 써 주세요.") }
            edited["body"] = t
        }
        if let raw = overrides["to"], !(raw is NSNull) {
            guard let s = raw as? String else { return fail("바꿀 상태 이름이 올바르지 않아요.") }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, t.count <= 100, !t.contains("\n") else { return fail("바꿀 상태 이름을 확인해 주세요.") }
            edited["to"] = t
        }

        // 2) 반영 시작 — 이긴 쪽만 진행한다(두 번 눌러도, 다른 프로세스가 함께 불러도 한 번)
        let begin = brain.jiraBegin(id: id)
        guard (begin["ok"] as? Bool) == true, var p = begin["proposal"] as? [String: Any] else {
            var extra: [String: Any] = [:]
            if let st = begin["state"] as? String, !st.isEmpty { extra["state"] = st }
            return fail((begin["error"] as? String) ?? "반영할 수 없는 제안이에요.", extra)
        }
        let op = (p["op"] as? String) ?? ""
        var requested: [String: Any] = [:]      // 제안과 다르게 고친 것만 (op에 맞지 않는 고침은 쓰지 않는다)
        if op == "comment", let b = edited["body"], b != (p["body"] as? String) { p["body"] = b; requested["body"] = b }
        if op == "transition", let t = edited["to"], t != (p["to"] as? String) { p["to"] = t; requested["to"] = t }
        let keyOut: Any = p["key"] ?? NSNull()

        func finish(_ ok: Bool, _ message: String, _ result: [String: Any]) {
            var r = result
            if !requested.isEmpty { r["edited"] = requested }
            _ = brain.jiraFinish(id: id, ok: ok, message: message, result: r)
        }
        func failed(_ m: String, uncertain: Bool = false) -> [String: Any] {
            finish(false, m, uncertain ? ["uncertain": true] : [:])
            var extra: [String: Any] = ["op": op, "key": keyOut]
            if uncertain { extra["uncertain"] = true }
            return fail(m, extra)
        }

        // 3) 출처·토큰
        let sid = (p["sourceId"] as? String) ?? ""
        guard let src = library.sourceConfigs().first(where: { $0.id == sid }) else {
            return failed("이 제안의 Atlassian 연결을 찾지 못했어요. 자료 화면에서 연결을 확인해 주세요.")
        }
        guard src.enabled else { return failed("Atlassian 연결이 꺼져 있어요. 자료 화면에서 켠 뒤 다시 반영해 주세요.") }
        guard src.kind == .mcp || src.kind == .atlassian else { return failed("Jira에 반영할 수 있는 연결이 아니에요.") }
        if let why = refusal(for: src, home: library.home) { return failed(why) }
        guard let token = Plugins.secrets.secret(for: sid), !token.isEmpty else {
            return failed("로그인 정보를 찾을 수 없어요. 자료 화면에서 연결을 다시 추가해 주세요.")
        }

        // 4) 쓰기 — 전체 시간 제한. 쓰기 호출을 보내기 전에 멈췄으면 Jira는 바뀌지 않은 것이 분명하다.
        let job = p
        let mark = WriteMark()
        do {
            let r = try await withDeadline(limit(home: library.home), mark: mark) {
                try await JiraWriter.apply(job, source: src, token: token, onWrite: { mark.set() })
            }
            let msg = (r["message"] as? String) ?? "Jira에 반영했어요"
            finish(true, msg, r)
            library.syncRemoteSoon(id: sid)
            var out: [String: Any] = ["ok": true, "id": id, "key": r["key"] ?? keyOut, "op": op, "message": msg]
            if let u = r["url"] as? String { out["url"] = u }
            if (r["already"] as? Bool) == true { out["already"] = true }
            return out
        } catch {
            let d = JiraWriter.describe(error)
            return failed(d.message, uncertain: d.uncertain)
        }
    }

    // MARK: 시험 홈 보호

    static func isTestHome(_ home: URL) -> Bool { BrainEnv.current(home: home).isTest }

    /// 시험 홈이면 127.0.0.1·localhost 가짜 서버만 허용한다. 막을 때는 이유 문구.
    static func refusal(for src: SourceConfig, home: URL) -> String? {
        guard isTestHome(home) else { return nil }
        let host: String?
        switch src.kind {
        case .mcp:
            let raw = (src.mcpURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            host = URL(string: raw.isEmpty ? AtlassianMCPConnector.defaultServer : raw)?.host
        case .atlassian:
            host = AtlassianConnector.normalizedSite(src.site ?? "")?.host
        default:
            host = nil
        }
        if let h = host, MCPHTTP.isLoopback(h) { return nil }
        return "시험 홈에서는 진짜 Jira에 반영하지 않아요 (127.0.0.1 가짜 서버만 써요)"
    }

    /// 시간 제한. 시험 홈에서만 SYNAPSE_TEST_JIRA_DEADLINE(초, 1 이상)으로 줄일 수 있다(늘릴 수는 없다).
    private static func limit(home: URL) -> Double {
        guard isTestHome(home), let s = ProcessInfo.processInfo.environment["SYNAPSE_TEST_JIRA_DEADLINE"],
              let v = Double(s.trimmingCharacters(in: .whitespaces)), v >= 1 else { return deadline }
        return min(v, deadline)
    }

    // MARK: 시간 제한

    /// 쓰기 호출을 보냈는지 (시간 제한이 끝났을 때 '반영 안 됨'인지 '결과 모름'인지 가른다).
    private final class WriteMark: @unchecked Sendable {
        private let lock = NSLock()
        private var started = false
        func set() { lock.lock(); started = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return started }
    }

    private static func withDeadline(_ seconds: Double, mark: WriteMark,
                                     _ body: @escaping () async throws -> [String: Any]) async throws -> [String: Any] {
        try await withThrowingTaskGroup(of: [String: Any].self) { g in
            g.addTask { try await body() }
            g.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw mark.isSet ? JiraWriteError(JiraWriteError.unknownResult + " (응답이 너무 늦어요)", uncertain: true)
                                 : JiraWriteError("Atlassian 응답이 너무 늦어 멈췄어요. Jira는 바뀌지 않았어요. 잠시 뒤 다시 시도해 주세요.")
            }
            defer { g.cancelAll() }
            guard let first = try await g.next() else { throw JiraWriteError(JiraWriteError.unknownResult, uncertain: true) }
            return first
        }
    }
}
