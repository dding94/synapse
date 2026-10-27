import Foundation
import SQLite3

// SQLite 저장소 (docs/CONNECT.md §3.2). 쓰기 연결은 색인 큐에서만, 읽기 연결은 잠금으로 보호해 조회에 쓴다.

private let SQLITE_TRANSIENT_ = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLValue {
    case int(Int64), double(Double), text(String), null
}

struct SQLiteError: Error, CustomStringConvertible {
    let message: String
    var code: Int32 = 0
    var description: String { message }
    /// 파일이 손상됐거나 SQLite 파일이 아닐 때만 true (잠김·권한 문제는 false).
    var isCorruption: Bool { (code & 0xff) == SQLITE_CORRUPT || (code & 0xff) == SQLITE_NOTADB }
}

final class SQLiteDB {
    let handle: OpaquePointer
    private var cache: [String: OpaquePointer] = [:]

    init(path: String, readonly: Bool = false) throws {
        var h: OpaquePointer?
        let flags = (readonly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)) | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path, &h, flags, nil)
        guard rc == SQLITE_OK, let hh = h else {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let h = h { sqlite3_close(h) }
            throw SQLiteError(message: msg, code: rc)
        }
        handle = hh
        sqlite3_busy_timeout(handle, 5000)
    }

    deinit {
        for (_, s) in cache { sqlite3_finalize(s) }
        sqlite3_close_v2(handle)
    }

    var lastError: String { String(cString: sqlite3_errmsg(handle)) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? lastError
            sqlite3_free(err)
            throw SQLiteError(message: msg, code: rc)
        }
    }

    private func statement(_ sql: String) throws -> OpaquePointer {
        if let s = cache[sql] { sqlite3_reset(s); sqlite3_clear_bindings(s); return s }
        var s: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &s, nil)
        guard rc == SQLITE_OK, let st = s else {
            throw SQLiteError(message: lastError + " — " + sql, code: rc)
        }
        cache[sql] = st
        return st
    }

    private func bind(_ s: OpaquePointer, _ args: [SQLValue]) {
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case .int(let v): sqlite3_bind_int64(s, idx, v)
            case .double(let v): sqlite3_bind_double(s, idx, v)
            case .text(let v): sqlite3_bind_text(s, idx, v, -1, SQLITE_TRANSIENT_)
            case .null: sqlite3_bind_null(s, idx)
            }
        }
    }

    /// 결과 없는 문장 실행.
    @discardableResult
    func run(_ sql: String, _ args: [SQLValue] = []) throws -> Int {
        let s = try statement(sql)
        bind(s, args)
        defer { sqlite3_reset(s) }
        let rc = sqlite3_step(s)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw SQLiteError(message: lastError + " — " + sql, code: rc) }
        return Int(sqlite3_changes(handle))
    }

    /// 행마다 body 호출.
    func query(_ sql: String, _ args: [SQLValue] = [], _ body: (Row) throws -> Void) throws {
        let s = try statement(sql)
        bind(s, args)
        defer { sqlite3_reset(s) }
        let row = Row(s)
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_ROW { try body(row) }
            else if rc == SQLITE_DONE { break }
            else { throw SQLiteError(message: lastError + " — " + sql, code: rc) }
        }
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do { try body(); try exec("COMMIT") }
        catch { try? exec("ROLLBACK"); throw error }
    }

    struct Row {
        let s: OpaquePointer
        init(_ s: OpaquePointer) { self.s = s }
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(s, i) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(s, i) }
        func isNull(_ i: Int32) -> Bool { sqlite3_column_type(s, i) == SQLITE_NULL }
        func text(_ i: Int32) -> String {
            guard let p = sqlite3_column_text(s, i) else { return "" }
            return String(cString: p)
        }
    }
}

// MARK: - 저장소

/// 관계 계산·보기용 문서 메타(본문 제외).
struct DocMetaRow {
    var rowid: Int64
    var id: String
    var sourceId: String
    var kind: String
    var title: String
    var location: String
    var displayPath: String
    var folder: String
    var group: String
    var modified: Double
    var created: Double?
    var size: Int
    var tags: [String]
    var aliases: [String]
    var outLinks: [String]
    var summary: String
    var issueKeys: [String]
    var meta: [String: String] = [:]   // v0.5: 원격 이슈 필드 (DocRecord.meta)
}

func jsonArray(_ a: [String]) -> String {
    (try? String(data: JSONSerialization.data(withJSONObject: a), encoding: .utf8)) ?? "[]"
}
func parseJSONArray(_ s: String) -> [String] {
    guard !s.isEmpty, let d = s.data(using: .utf8), let a = try? JSONSerialization.jsonObject(with: d) as? [String] else { return [] }
    return a
}
func jsonObjectString(_ m: [String: String]) -> String {
    (try? String(data: JSONSerialization.data(withJSONObject: m, options: [.sortedKeys]), encoding: .utf8)) ?? "{}"
}
func parseJSONStringMap(_ s: String) -> [String: String] {
    guard !s.isEmpty, let d = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { return [:] }
    return o
}

final class Store {
    static let schemaVersion = "4"   // 4: NFC id·AUTOINCREMENT
    let writer: SQLiteDB
    private let reader: SQLiteDB
    private let readLock = NSLock()
    /// 이번에 색인을 새로 만들었는가 (스키마 변경·새 파일). 원격 cursor를 버려야 한다.
    private(set) var didReset = false

    let isReadOnly: Bool
    /// docs.meta 열이 있는가 (v0.5에서 열을 덧붙였다. 앱이 아직 한 번도 안 열린 옛 색인은 없다).
    private(set) var hasMetaColumn = false

    /// 읽기 전용(MCP 서버 등): 색인을 만들거나 고치지 않고, 스키마가 다르면 던진다.
    init(readOnlyAt url: URL) throws {
        isReadOnly = true
        guard FileManager.default.fileExists(atPath: url.path) else { throw SQLiteError(message: "색인이 없어요.", code: SQLITE_CANTOPEN) }
        writer = try SQLiteDB(path: url.path, readonly: true)
        try? writer.exec("PRAGMA query_only=1;")
        var version = ""
        try writer.query("SELECT value FROM meta WHERE key='schema'") { version = $0.text(0) }
        guard version == Store.schemaVersion else { throw SQLiteError(message: "색인 형식이 달라요.", code: SQLITE_MISMATCH) }
        reader = try SQLiteDB(path: url.path, readonly: true)
        try? reader.exec("PRAGMA query_only=1;")
        hasMetaColumn = Store.columnExists(writer, table: "docs", column: "meta")
    }

    private static func columnExists(_ db: SQLiteDB, table: String, column: String) -> Bool {
        var found = false
        try? db.query("PRAGMA table_info(\(table))") { if $0.text(1) == column { found = true } }
        return found
    }

    /// 다른 연결이 커밋하면 바뀌는 값 (PRAGMA data_version).
    func dataVersion() -> Int64 {
        var v: Int64 = -1
        try? writer.query("PRAGMA data_version") { v = $0.int(0) }
        return v
    }

    init(url: URL) throws {
        isReadOnly = false
        writer = try SQLiteDB(path: url.path)
        try writer.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA temp_store=MEMORY;")
        didReset = try Store.migrate(writer)
        // v0.5: 원격 이슈 필드 열. 스키마 번호를 올리지 않고 덧붙여 색인을 다시 만들지 않는다.
        if !Store.columnExists(writer, table: "docs", column: "meta") {
            try writer.exec("ALTER TABLE docs ADD COLUMN meta TEXT")
        }
        hasMetaColumn = true
        reader = try SQLiteDB(path: url.path)
        try? reader.exec("PRAGMA query_only=1;")
    }

    @discardableResult
    private static func migrate(_ db: SQLiteDB) throws -> Bool {
        try db.exec("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT)")
        var version = ""
        try db.query("SELECT value FROM meta WHERE key='schema'") { version = $0.text(0) }
        if version != schemaVersion {
            try db.exec("""
            DROP TABLE IF EXISTS docs; DROP TABLE IF EXISTS docs_fts; DROP TABLE IF EXISTS links;
            DROP TABLE IF EXISTS unresolved; DROP TABLE IF EXISTS related; DROP TABLE IF EXISTS doc_terms; DROP TABLE IF EXISTS doc_tf;
            """)
        }
        try db.exec("""
        CREATE TABLE IF NOT EXISTS docs(rid INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT UNIQUE NOT NULL, source_id TEXT NOT NULL, kind TEXT,
          title TEXT, location TEXT, display_path TEXT, folder TEXT, grp TEXT, modified REAL, created REAL, size INT,
          tags TEXT, aliases TEXT, out_links TEXT, text TEXT, fingerprint TEXT, summary TEXT, issue_keys TEXT);
        CREATE INDEX IF NOT EXISTS docs_source ON docs(source_id);
        CREATE VIRTUAL TABLE IF NOT EXISTS docs_fts USING fts5(title_t, tags_t, body_t, tokenize = 'unicode61 remove_diacritics 0');
        CREATE TABLE IF NOT EXISTS links(src TEXT, dst TEXT, kind TEXT, PRIMARY KEY(src, dst, kind)) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS links_dst ON links(dst);
        CREATE TABLE IF NOT EXISTS unresolved(src TEXT, target TEXT);
        CREATE INDEX IF NOT EXISTS unresolved_src ON unresolved(src);
        CREATE TABLE IF NOT EXISTS related(src TEXT, dst TEXT, score REAL, kind TEXT, reason TEXT);
        CREATE INDEX IF NOT EXISTS related_src ON related(src);
        CREATE TABLE IF NOT EXISTS doc_terms(doc_id TEXT, term TEXT, weight REAL);
        CREATE TABLE IF NOT EXISTS doc_tf(doc_id TEXT, term TEXT, tf REAL);
        CREATE INDEX IF NOT EXISTS doc_tf_doc ON doc_tf(doc_id);
        """)
        try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES('schema', ?)", [.text(schemaVersion)])
        return version != schemaVersion
    }

    // MARK: 쓰기 (색인 큐 전용)

    func fingerprints(source: String) throws -> [String: String] {
        var out: [String: String] = [:]
        try writer.query("SELECT id, fingerprint FROM docs WHERE source_id=?", [.text(source)]) { out[$0.text(0)] = $0.text(1) }
        return out
    }

    func ids(source: String) throws -> [String] {
        var out: [String] = []
        try writer.query("SELECT id FROM docs WHERE source_id=?", [.text(source)]) { out.append($0.text(0)) }
        return out
    }

    func count(source: String) -> Int {
        var n = 0
        try? writer.query("SELECT count(*) FROM docs WHERE source_id=?", [.text(source)]) { n = Int($0.int(0)) }
        return n
    }

    /// 문서 하나 넣기·바꾸기 (FTS·키워드 빈도 포함). 트랜잭션 안에서 부른다.
    func upsert(_ r: DocRecord, summary: String, issueKeys: [String], tf: [(String, Double)]) throws {
        let args: [SQLValue] = [
            .text(r.id), .text(r.sourceId), .text(r.kind), .text(r.title), .text(r.location), .text(r.displayPath),
            .text(r.folder), .text(r.group), .double(r.modified.timeIntervalSince1970),
            r.created.map { .double($0.timeIntervalSince1970) } ?? .null, .int(Int64(r.size)),
            .text(jsonArray(r.tags)), .text(jsonArray(r.aliases)), .text(jsonArray(r.outLinks)), .text(r.text),
            .text(r.fingerprint), .text(summary), .text(jsonArray(issueKeys)),
            r.meta.map { .text(jsonObjectString($0)) } ?? .null,
        ]
        try writer.run("""
        INSERT INTO docs(id, source_id, kind, title, location, display_path, folder, grp, modified, created, size,
          tags, aliases, out_links, text, fingerprint, summary, issue_keys, meta) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET source_id=excluded.source_id, kind=excluded.kind, title=excluded.title,
          location=excluded.location, display_path=excluded.display_path, folder=excluded.folder, grp=excluded.grp,
          modified=excluded.modified, created=excluded.created, size=excluded.size, tags=excluded.tags,
          aliases=excluded.aliases, out_links=excluded.out_links, text=excluded.text, fingerprint=excluded.fingerprint,
          summary=excluded.summary, issue_keys=excluded.issue_keys, meta=excluded.meta
        """, args)
        var rid: Int64 = 0
        try writer.query("SELECT rid FROM docs WHERE id=?", [.text(r.id)]) { rid = $0.int(0) }
        try writer.run("DELETE FROM docs_fts WHERE rowid=?", [.int(rid)])
        let tagText = (r.tags + r.aliases).joined(separator: " ")
        try writer.run("INSERT INTO docs_fts(rowid, title_t, tags_t, body_t) VALUES(?,?,?,?)",
                       [.int(rid), .text(Korean.indexString(r.title)), .text(Korean.indexString(tagText)),
                        .text(Korean.indexString(r.text))])
        try writer.run("DELETE FROM doc_tf WHERE doc_id=?", [.text(r.id)])
        for (term, n) in tf { try writer.run("INSERT INTO doc_tf(doc_id, term, tf) VALUES(?,?,?)", [.text(r.id), .text(term), .double(n)]) }
    }

    /// 문서 지우기 (연결 정보 포함). 트랜잭션 안에서 부른다.
    func delete(ids: [String]) throws {
        for id in ids {
            var rid: Int64? = nil
            try writer.query("SELECT rid FROM docs WHERE id=?", [.text(id)]) { rid = $0.int(0) }
            if let rid = rid { try writer.run("DELETE FROM docs_fts WHERE rowid=?", [.int(rid)]) }
            try writer.run("DELETE FROM docs WHERE id=?", [.text(id)])
            try writer.run("DELETE FROM doc_tf WHERE doc_id=?", [.text(id)])
        }
    }

    func metas() throws -> [DocMetaRow] {
        var out: [DocMetaRow] = []
        let metaCol = hasMetaColumn ? "meta" : "NULL"
        try writer.query("""
        SELECT rid, id, source_id, kind, title, location, display_path, folder, grp, modified, created, size,
          tags, aliases, out_links, summary, issue_keys, \(metaCol) FROM docs
        """) { r in
            out.append(DocMetaRow(rowid: r.int(0), id: r.text(1), sourceId: r.text(2), kind: r.text(3), title: r.text(4),
                                  location: r.text(5), displayPath: r.text(6), folder: r.text(7), group: r.text(8),
                                  modified: r.double(9), created: r.isNull(10) ? nil : r.double(10), size: Int(r.int(11)),
                                  tags: parseJSONArray(r.text(12)), aliases: parseJSONArray(r.text(13)),
                                  outLinks: parseJSONArray(r.text(14)), summary: r.text(15), issueKeys: parseJSONArray(r.text(16)),
                                  meta: r.isNull(17) ? [:] : parseJSONStringMap(r.text(17))))
        }
        return out
    }

    func allTF() throws -> [String: [(String, Double)]] {
        var out: [String: [(String, Double)]] = [:]
        try writer.query("SELECT doc_id, term, tf FROM doc_tf") { out[$0.text(0), default: []].append(($0.text(1), $0.double(2))) }
        return out
    }

    /// 쓰기 연결로 FTS 후보 찾기 (관계 계산용).
    func writerFTS(_ expr: String, limit: Int = 5000) -> [Int64] {
        var out: [Int64] = []
        try? writer.query("SELECT rowid FROM docs_fts WHERE docs_fts MATCH ? LIMIT ?", [.text(expr), .int(Int64(limit))]) { out.append($0.int(0)) }
        return out
    }

    func writerText(rowid: Int64) -> String {
        var t = ""
        try? writer.query("SELECT text FROM docs WHERE rid=?", [.int(rowid)]) { t = $0.text(0) }
        return t
    }

    struct GraphRows {
        var links: [(String, String, String)] = []
        var unresolved: [(String, String)] = []
        var related: [(String, String, Double, String, String)] = []
        var terms: [(String, String, Double)] = []
    }

    func replaceGraph(_ g: GraphRows) throws {
        try writer.transaction {
            try writer.exec("DELETE FROM links; DELETE FROM unresolved; DELETE FROM related; DELETE FROM doc_terms;")
            for l in g.links { try writer.run("INSERT OR IGNORE INTO links(src, dst, kind) VALUES(?,?,?)", [.text(l.0), .text(l.1), .text(l.2)]) }
            for u in g.unresolved { try writer.run("INSERT INTO unresolved(src, target) VALUES(?,?)", [.text(u.0), .text(u.1)]) }
            for r in g.related {
                try writer.run("INSERT INTO related(src, dst, score, kind, reason) VALUES(?,?,?,?,?)",
                               [.text(r.0), .text(r.1), .double(r.2), .text(r.3), .text(r.4)])
            }
            for t in g.terms { try writer.run("INSERT INTO doc_terms(doc_id, term, weight) VALUES(?,?,?)", [.text(t.0), .text(t.1), .double(t.2)]) }
        }
    }

    func loadGraph() throws -> GraphRows {
        var g = GraphRows()
        try writer.query("SELECT src, dst, kind FROM links") { g.links.append(($0.text(0), $0.text(1), $0.text(2))) }
        try writer.query("SELECT src, target FROM unresolved") { g.unresolved.append(($0.text(0), $0.text(1))) }
        try writer.query("SELECT src, dst, score, kind, reason FROM related") {
            g.related.append(($0.text(0), $0.text(1), $0.double(2), $0.text(3), $0.text(4)))
        }
        try writer.query("SELECT doc_id, term, weight FROM doc_terms") { g.terms.append(($0.text(0), $0.text(1), $0.double(2))) }
        return g
    }

    // MARK: 읽기 (아무 스레드)

    func readFTS(_ expr: String, limit: Int) -> [Int64] {
        readLock.lock(); defer { readLock.unlock() }
        var out: [Int64] = []
        try? reader.query("SELECT rowid FROM docs_fts WHERE docs_fts MATCH ? ORDER BY rank LIMIT ?",
                          [.text(expr), .int(Int64(limit))]) { out.append($0.int(0)) }
        return out
    }

    /// 본문 앞부분 (maxChars 글자까지).
    func readText(rowid: Int64, maxChars: Int) -> (String, Int) {
        readLock.lock(); defer { readLock.unlock() }
        var t = "", n = 0
        try? reader.query("SELECT substr(text, 1, ?), length(text) FROM docs WHERE rid=?", [.int(Int64(maxChars)), .int(rowid)]) {
            t = $0.text(0); n = Int($0.int(1))
        }
        return (t, n)
    }
}
