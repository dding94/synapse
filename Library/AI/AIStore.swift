import Foundation

// v0.8 AI 저장소 <home>/ai.sqlite (docs/V08.md §4.1). brain.sqlite와 따로 둔다 — 사서 스키마 판을 바꾸지 않고, 지우기도 쉽다.
// SQLiteDB는 스레드 안전하지 않으므로 모든 접근을 잠금 하나로 묶는다. 실패는 던지지 않는다(AI 기능이 앱을 멈추게 하지 않게).
// 열지 못하면 메모리 DB로 대신한다(그 실행 동안만 기억한다).

/// runs 표 한 줄. prompt에는 사용자가 쓴 지시만(정리 실행은 "이번 주 정리" 같은 제목만) 넣는다. 입력 자료는 저장하지 않는다.
struct AIRunRow {
    var id: String
    var kind: String                 // "digest" | "task"
    var digestKind: String?
    var scope: String?
    var title: String
    var prompt: String
    var model: String
    var status: String               // running | done | error | cancelled
    var started: Double
    var ended: Double?
    var turns: Int?
    var durationMs: Int?
    var steps: [[String: Any]] = []
    var answer: String?
    var errorCode: String?
    var error: String?
    var auto: Bool = false
}

/// digests 표 한 줄 (kind·scope마다 마지막 정리 하나).
struct AIDigestRow {
    var kind: String
    var scope: String
    var inputHash: String
    var model: String
    var created: Double
    var durationMs: Int
    var runId: String
    var json: [String: Any]
}

/// digest_fail 표 한 줄 (kind·scope의 마지막 실패. 성공하면 지운다).
struct AIDigestFailure {
    var code: String
    var message: String
    var at: Double
}

final class AIStore {
    static let keepRuns = 200
    static let keepDays: Double = 30

    private let db: SQLiteDB
    private let lock = NSLock()
    let url: URL?

    static let schemaSQL = """
    CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT);
    CREATE TABLE IF NOT EXISTS runs(id TEXT PRIMARY KEY, kind TEXT, digest_kind TEXT, scope TEXT, title TEXT, prompt TEXT, model TEXT,
      status TEXT, started REAL, ended REAL, turns INTEGER, duration_ms INTEGER, steps TEXT, answer TEXT,
      error_code TEXT, error TEXT, auto INTEGER DEFAULT 0);
    CREATE INDEX IF NOT EXISTS runs_started ON runs(started);
    CREATE TABLE IF NOT EXISTS digests(kind TEXT, scope TEXT, input_hash TEXT, model TEXT, created REAL, duration_ms INTEGER, run_id TEXT,
      json TEXT, PRIMARY KEY(kind, scope));
    CREATE TABLE IF NOT EXISTS digest_fail(kind TEXT, scope TEXT, code TEXT, message TEXT, at REAL, PRIMARY KEY(kind, scope));
    """

    init(home: URL) {
        let file = home.appendingPathComponent("ai.sqlite")
        if let opened = try? AIStore.open(path: file.path) {
            db = opened; url = file
        } else {
            FileHandle.standardError.write(Data("AI_STORE_UNAVAILABLE \(file.path)\n".utf8))   // CLI의 stdout(JSON)을 깨지 않게
            db = (try? AIStore.open(path: ":memory:")) ?? (try! SQLiteDB(path: ":memory:"))
            url = nil
        }
    }

    private static func open(path: String) throws -> SQLiteDB {
        let d = try SQLiteDB(path: path)
        try d.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        try d.exec(schemaSQL)
        try d.exec("PRAGMA user_version=1")
        return d
    }

    private func locked<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }

    private static func text(_ s: String?) -> SQLValue { s.map { .text($0) } ?? .null }
    private static func int(_ i: Int?) -> SQLValue { i.map { .int(Int64($0)) } ?? .null }
    private static func real(_ d: Double?) -> SQLValue { d.map { .double($0) } ?? .null }
    private static func json(_ o: Any) -> String {
        guard JSONSerialization.isValidJSONObject(o), let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return "null" }
        return String(data: d, encoding: .utf8) ?? "null"
    }
    private static func parse(_ s: String) -> Any? {
        guard !s.isEmpty, let d = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])
    }

    // MARK: 설정

    func setting(_ key: String) -> String? {
        locked {
            var v: String?
            try? db.query("SELECT value FROM settings WHERE key=?", [.text(key)]) { v = $0.isNull(0) ? nil : $0.text(0) }
            return v
        }
    }

    func setSetting(_ key: String, _ value: String?) {
        locked {
            if let value = value { _ = try? db.run("INSERT OR REPLACE INTO settings(key, value) VALUES(?, ?)", [.text(key), .text(value)]) }
            else { _ = try? db.run("DELETE FROM settings WHERE key=?", [.text(key)]) }
        }
    }

    // MARK: 실행 기록

    private static let runColumns = "id, kind, digest_kind, scope, title, prompt, model, status, started, ended, turns, duration_ms, steps, answer, error_code, error, auto"

    func saveRun(_ r: AIRunRow) {
        locked {
            _ = try? db.run("INSERT OR REPLACE INTO runs(\(AIStore.runColumns)) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [
                .text(r.id), .text(r.kind), AIStore.text(r.digestKind), AIStore.text(r.scope), .text(r.title), .text(r.prompt), .text(r.model),
                .text(r.status), .double(r.started), AIStore.real(r.ended), AIStore.int(r.turns), AIStore.int(r.durationMs),
                .text(AIStore.json(r.steps)), AIStore.text(r.answer), AIStore.text(r.errorCode), AIStore.text(r.error), .int(r.auto ? 1 : 0)])
        }
    }

    private static func row(_ q: SQLiteDB.Row) -> AIRunRow {
        func s(_ i: Int32) -> String? { q.isNull(i) ? nil : q.text(i) }
        return AIRunRow(id: q.text(0), kind: q.text(1), digestKind: s(2), scope: s(3), title: q.text(4), prompt: q.text(5), model: q.text(6),
                        status: q.text(7), started: q.double(8), ended: q.isNull(9) ? nil : q.double(9),
                        turns: q.isNull(10) ? nil : Int(q.int(10)), durationMs: q.isNull(11) ? nil : Int(q.int(11)),
                        steps: (parse(q.text(12)) as? [[String: Any]]) ?? [], answer: s(13), errorCode: s(14), error: s(15), auto: q.int(16) != 0)
    }

    func run(id: String) -> AIRunRow? {
        locked {
            var r: AIRunRow?
            try? db.query("SELECT \(AIStore.runColumns) FROM runs WHERE id=?", [.text(id)]) { r = AIStore.row($0) }
            return r
        }
    }

    func runs(limit: Int) -> [AIRunRow] {
        locked {
            var list: [AIRunRow] = []
            try? db.query("SELECT \(AIStore.runColumns) FROM runs ORDER BY started DESC LIMIT ?", [.int(Int64(limit))]) { list.append(AIStore.row($0)) }
            return list
        }
    }

    /// 그 kind·scope 정리의 마지막 실행 시작 시각 (쉬는 시간 §4.3-4).
    func lastDigestStart(kind: String, scope: String) -> Double? {
        locked {
            var t: Double?
            try? db.query("SELECT max(started) FROM runs WHERE kind='digest' AND digest_kind=? AND scope=?", [.text(kind), .text(scope)]) {
                t = $0.isNull(0) ? nil : $0.double(0)
            }
            return t
        }
    }

    /// since 뒤에 시작한 자동 실행 수 (하루 상한 §4.3-5).
    func autoRuns(since: Double) -> Int {
        locked {
            var n = 0
            try? db.query("SELECT count(*) FROM runs WHERE auto=1 AND started>=?", [.double(since)]) { n = Int($0.int(0)) }
            return n
        }
    }

    /// 앱이 닫혀 끝나지 못한 실행(시작한 지 오래된 running)을 cancelled로 바꾼다. 다른 프로세스가 지금 돌리는 것은 건드리지 않게 오래된 것만.
    func closeStale(before: Double, now: Double) {
        locked {
            _ = try? db.run("UPDATE runs SET status='cancelled', ended=?, error_code='cancelled', error='앱이 닫혀 멈췄어요.' WHERE status='running' AND started<?",
                            [.double(now), .double(before)])
        }
    }

    /// 보존 (§4.1·§9.5): 실행 기록은 최근 200개·30일, 정리 결과·실패는 30일.
    func prune(now: Double) {
        let cutoff = now - AIStore.keepDays * 86400
        locked {
            _ = try? db.run("DELETE FROM runs WHERE status!='running' AND (started<? OR id NOT IN (SELECT id FROM runs ORDER BY started DESC LIMIT ?))",
                            [.double(cutoff), .int(Int64(AIStore.keepRuns))])
            _ = try? db.run("DELETE FROM digests WHERE created<?", [.double(cutoff)])
            _ = try? db.run("DELETE FROM digest_fail WHERE at<?", [.double(cutoff)])
        }
    }

    // MARK: 정리 결과

    func digest(kind: String, scope: String) -> AIDigestRow? {
        locked {
            var r: AIDigestRow?
            try? db.query("SELECT input_hash, model, created, duration_ms, run_id, json FROM digests WHERE kind=? AND scope=?", [.text(kind), .text(scope)]) {
                guard let obj = AIStore.parse($0.text(5)) as? [String: Any] else { return }
                r = AIDigestRow(kind: kind, scope: scope, inputHash: $0.text(0), model: $0.text(1), created: $0.double(2),
                                durationMs: Int($0.int(3)), runId: $0.text(4), json: obj)
            }
            return r
        }
    }

    func saveDigest(_ d: AIDigestRow) {
        locked {
            _ = try? db.run("INSERT OR REPLACE INTO digests(kind, scope, input_hash, model, created, duration_ms, run_id, json) VALUES(?,?,?,?,?,?,?,?)",
                            [.text(d.kind), .text(d.scope), .text(d.inputHash), .text(d.model), .double(d.created), .int(Int64(d.durationMs)),
                             .text(d.runId), .text(AIStore.json(d.json))])
        }
    }

    func failure(kind: String, scope: String) -> AIDigestFailure? {
        locked {
            var f: AIDigestFailure?
            try? db.query("SELECT code, message, at FROM digest_fail WHERE kind=? AND scope=?", [.text(kind), .text(scope)]) {
                f = AIDigestFailure(code: $0.text(0), message: $0.text(1), at: $0.double(2))
            }
            return f
        }
    }

    func saveFailure(kind: String, scope: String, _ f: AIDigestFailure) {
        locked {
            _ = try? db.run("INSERT OR REPLACE INTO digest_fail(kind, scope, code, message, at) VALUES(?,?,?,?,?)",
                            [.text(kind), .text(scope), .text(f.code), .text(f.message), .double(f.at)])
        }
    }

    func clearFailure(kind: String, scope: String) {
        locked { _ = try? db.run("DELETE FROM digest_fail WHERE kind=? AND scope=?", [.text(kind), .text(scope)]) }
    }
}
