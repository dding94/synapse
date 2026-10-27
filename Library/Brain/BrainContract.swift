import Foundation
import SQLite3

// v0.5 사서(Brain) 공용 계약 — docs/V05.md §2·§3.
// 오퍼레이터 소유. 담당자(S1·S2·S3·S4)는 고치지 말고, 바꿀 일이 있으면 오퍼레이터에게 요청한다.
// 규칙: 사서 코드는 모두 ctx.queue(직렬)에서만 돈다. index(색인)는 읽기 전용, db(brain.sqlite)는 읽기·쓰기.
// 오래 걸리는 일(세션 첫 읽기, 기기 AI)은 조각(≤200ms)으로 나눠 큐를 오래 붙잡지 않는다.

// MARK: - 환경

enum BrainMode { case app, mcp, cli }

struct BrainEnv {
    var claudeDir: URL?          // Claude Code 세션 루트(…/projects). nil이면 읽지 않는다
    var codexDir: URL?           // Codex 세션 루트(…/sessions). nil이면 읽지 않는다
    var fixedNow: Date?          // SYNAPSE_NOW(ISO8601) — 시험용 시계 고정
    var obsidianRunning: Bool?   // SYNAPSE_OBSIDIAN_RUNNING=0/1 — 시험용 덮어쓰기. nil이면 실제 프로세스를 본다
    var isTest: Bool             // 시험 실행: 앱 시작 직후 일을 1초 뒤에 한다(평소 60초)
    /// v0.9: 사용자 홈 폴더. 볼트 조상 찾기의 끝·코드 폴더 기본값(~/IdeaProjects)에 쓴다. SYNAPSE_USER_HOME — 시험용 덮어쓰기
    var userHome: String = NSHomeDirectory()

    /// home이 기본 위치(~/Library/Application Support/Synapse)일 때만 실제 세션 폴더를 기본값으로 쓴다.
    /// 다른 home(시험·CLI --home)은 SYNAPSE_CLAUDE_DIR / SYNAPSE_CODEX_DIR를 줄 때만 읽는다.
    static func current(home: URL) -> BrainEnv {
        let env = ProcessInfo.processInfo.environment
        let fm = FileManager.default
        let defaultHome = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Synapse").standardizedFileURL.path
        let isDefault = home.standardizedFileURL.path == defaultHome
        let userHome = fm.homeDirectoryForCurrentUser
        func dir(_ key: String, _ fallback: String) -> URL? {
            if let v = env[key], !v.isEmpty { return URL(fileURLWithPath: (v as NSString).expandingTildeInPath) }
            return isDefault ? userHome.appendingPathComponent(fallback) : nil
        }
        var now: Date? = nil
        if let s = env["SYNAPSE_NOW"], !s.isEmpty { now = ISO8601DateFormatter().date(from: s) }
        let obs: Bool? = env["SYNAPSE_OBSIDIAN_RUNNING"].map { $0 == "1" }
        let test = !isDefault || env.keys.contains { $0.hasPrefix("SYNAPSE_TEST_") }
        // 시험 실행(기본이 아닌 홈 등)에서 SYNAPSE_USER_HOME을 주지 않으면 실제 홈 대신 없는 경로를 쓴다:
        // 볼트 조상 찾기·코드 폴더(~/IdeaProjects)가 실제 홈을 보거나 그쪽으로 옮기지 않게.
        let uh = env["SYNAPSE_USER_HOME"].flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
            ?? (test ? "/var/empty/synapse-test-home" : userHome.path)
        return BrainEnv(claudeDir: dir("SYNAPSE_CLAUDE_DIR", ".claude/projects"),
                        codexDir: dir("SYNAPSE_CODEX_DIR", ".codex/sessions"),
                        fixedNow: now, obsidianRunning: obs, isTest: test, userHome: uh)
    }
}

// MARK: - 공용 값

/// 누가 썼나 (doc_state.author, activity.actor).
enum Actor: String { case human, claude, codex, mixed, synapse, unknown }

/// 화면 단계 (§5.2). none = 단계 표시 없음.
enum Tier: String { case now, week, dormant, none }

/// 화면에 "다시 읽어라"를 알리는 종류 (§8.3 synapseBrainEvent.type).
enum BrainEventKind: String { case home, pending, log, settings, policy, tidy }   // v0.9: tidy = 정리 계획·작업 지도가 바뀜

/// 설정 키 (§3.2). 값은 문자열.
enum BrainSetting {
    static let sessionsEnabled = "sessions.enabled"       // "1" | "0" | 없음(아직 묻지 않음)
    static let sessionsRequestText = "sessions.requestText" // "1" | "0" (기본 "1" — 사용자 결정)
    static let stopped = "brain.stopped"                  // "1" = 비상 정지(모든 쓰기·제안·기기 AI 멈춤)
    static let mcpRemoteBodies = "mcp.remoteBodies"       // "1" = MCP에 Confluence·Jira 본문 노출 (기본 "0")
    static let policyApprovedHash = "policy.approvedHash" // 승인한 규칙표 해시
    static let policySourceStamp = "policy.sourceStamp"   // 규칙표를 만든 CLAUDE.md들의 수정 시각
    static let organizerFirstRun = "organizer.firstRun"   // ISO8601 — 첫 2주 상한(§6.4)
    static let organizerLastBatch = "organizer.lastBatch" // ISO8601
    static let appleNoticeShown = "apple.noticeShown"     // "1"
    static let mcpDirectApply = "mcpDirectApply"          // v0.6: "on" = MCP apply_changes가 승인 없이 옮기고 휴지통으로 (기본 "off")
}

/// 사서가 색인에서 읽는 문서 정보 (본문 제외). ctx.docs로 받는다.
struct BrainDoc {
    let id: String               // 색인 id = "<sourceId>:<상대 경로>" (원격은 "<sourceId>:jira:KEY" 등)
    let rowid: Int64
    let sourceId: String
    let sourceKind: SourceKind
    let kind: String             // 확장자 또는 confluence / jira
    let title: String
    let relPath: String          // 출처 루트 기준 상대 경로(NFC). 원격은 id에서 접두를 뺀 값
    let absPath: String?         // 로컬 파일 절대 경로. 원격은 nil
    let location: String         // 원본 열기용(파일 경로 또는 URL)
    let folder: String           // 상대 상위 폴더("" = 루트)
    let modified: Date
    let created: Date?
    let size: Int
    let tags: [String]
    let outLinks: [String]
    let issueKeys: [String]
    let meta: [String: String]   // 원격 이슈 필드 (Models.swift DocRecord.meta)
    /// v0.9 (docs/V09.md §3.2): 볼트 안 로컬 문서면 볼트 기준 상대 경로. 출처가 볼트가 아니어도 채운다(VaultMap).
    var paraRel: String? = nil
    var isLocal: Bool { absPath != nil }
    /// PARA 판단에 쓰는 경로: 볼트 기준(있으면) → 출처 기준.
    var paraPath: String { paraRel ?? relPath }
}

// MARK: - 형식 도우미

enum BrainFormat {
    static let isoFormatter: ISO8601DateFormatter = ISO8601DateFormatter()
    static func iso(_ d: Date) -> String { isoFormatter.string(from: d) }
    static func date(_ s: String?) -> Date? { s.flatMap { isoFormatter.date(from: $0) } }

    /// 현지 날짜 키 yyyy-MM-dd.
    static func dayKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static let weekdays = ["일", "월", "화", "수", "목", "금", "토"]

    /// 화면용 상대 시각: 방금 · N분 전 · 오늘 14:20 · 어제 18:40 · 월 17:40(6일 안) · 10/12 · 2025.3.4
    static func whenLabel(_ d: Date, now: Date) -> String {
        let cal = Calendar.current
        let secs = now.timeIntervalSince(d)
        if secs >= 0 && secs < 60 { return "방금" }
        if secs >= 0 && secs < 3600 { return "\(Int(secs / 60))분 전" }
        let hm = String(format: "%02d:%02d", cal.component(.hour, from: d), cal.component(.minute, from: d))
        if cal.isDate(d, inSameDayAs: now) { return "오늘 \(hm)" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "어제 \(hm)" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: now)).day ?? 99
        if days >= 0 && days < 7 { return "\(weekdays[cal.component(.weekday, from: d) - 1]) \(hm)" }
        if cal.component(.year, from: d) == cal.component(.year, from: now) {
            return "\(cal.component(.month, from: d))/\(cal.component(.day, from: d))"
        }
        return "\(cal.component(.year, from: d)).\(cal.component(.month, from: d)).\(cal.component(.day, from: d))"
    }

    static func json(_ o: Any) -> String {
        guard JSONSerialization.isValidJSONObject(o),
              let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return "null" }
        return String(data: d, encoding: .utf8) ?? "null"
    }
    static func parse(_ s: String?) -> Any? {
        guard let s = s, !s.isEmpty, let d = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])
    }
}

// MARK: - brain.sqlite

/// 사서 저장소. 색인(index.sqlite)과 따로 두어 재색인에 날아가지 않는다. 지우는 마이그레이션은 없다(덧붙이기만).
final class BrainDB {
    static let schemaVersion = 2      // v0.6: trash_items(휴지통) 추가
    let sql: SQLiteDB
    let url: URL

    init(url: URL) throws {
        self.url = url
        sql = try SQLiteDB(path: url.path)
        try sql.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=OFF;")
        try BrainDB.migrate(sql)
    }

    private static func migrate(_ db: SQLiteDB) throws {
        try db.exec("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT)")
        var version = 0
        try db.query("SELECT value FROM meta WHERE key='schema'") { version = Int($0.text(0)) ?? 0 }
        if version > schemaVersion { throw SQLiteError(message: "사서 저장소가 더 새 버전이에요.", code: SQLITE_MISMATCH) }
        try db.exec(BrainDB.schemaSQL)
        try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES('schema', ?)", [.text(String(schemaVersion))])
    }

    /// docs/V05.md §3.1 — 열 이름과 뜻은 그 표와 같다.
    static let schemaSQL = """
    CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT);

    CREATE TABLE IF NOT EXISTS doc_state(
      doc_id TEXT PRIMARY KEY, source_id TEXT, path TEXT,
      content_hash TEXT, line_hashes TEXT, headings TEXT,
      type TEXT, status TEXT, project TEXT,
      author TEXT, author_session TEXT,
      ai_archive INTEGER DEFAULT 0, archived INTEGER DEFAULT 0, excluded INTEGER DEFAULT 0,
      first_seen REAL, last_change REAL, last_human REAL, last_ai REAL, last_open REAL,
      stopped_line INTEGER, stopped_heading TEXT,
      summary TEXT, summary_source TEXT,
      open_tasks INTEGER DEFAULT 0, done_tasks INTEGER DEFAULT 0, due_min TEXT,
      updated REAL);
    CREATE INDEX IF NOT EXISTS doc_state_path ON doc_state(source_id, path);

    CREATE TABLE IF NOT EXISTS activity(
      id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, doc_id TEXT, path TEXT,
      kind TEXT NOT NULL, actor TEXT NOT NULL, origin TEXT NOT NULL,
      session_id TEXT, detail TEXT);
    CREATE INDEX IF NOT EXISTS activity_ts ON activity(ts);
    CREATE INDEX IF NOT EXISTS activity_doc ON activity(doc_id, ts);

    CREATE TABLE IF NOT EXISTS tasks(
      id TEXT PRIMARY KEY, doc_id TEXT NOT NULL, line INTEGER, text TEXT, heading TEXT,
      state TEXT, due TEXT, prio TEXT, origin TEXT,
      first_seen REAL, last_seen REAL, done_at REAL, gone INTEGER DEFAULT 0);
    CREATE INDEX IF NOT EXISTS tasks_doc ON tasks(doc_id);

    CREATE TABLE IF NOT EXISTS remote_state(
      doc_id TEXT PRIMARY KEY, key TEXT, title TEXT, status TEXT, status_cat TEXT, priority TEXT, due TEXT,
      mine INTEGER DEFAULT 0, updated REAL, changed REAL);

    CREATE TABLE IF NOT EXISTS ai_sessions(
      id TEXT PRIMARY KEY, tool TEXT, cwd TEXT, branch TEXT, issue_keys TEXT, title TEXT,
      started REAL, last_ts REAL, first_ask TEXT, last_ask TEXT, last_ask_ts REAL,
      asks INTEGER DEFAULT 0, writes INTEGER DEFAULT 0);
    CREATE TABLE IF NOT EXISTS ai_writes(session_id TEXT, path TEXT, ts REAL, op TEXT);
    CREATE INDEX IF NOT EXISTS ai_writes_path ON ai_writes(path, ts);
    CREATE INDEX IF NOT EXISTS ai_writes_session ON ai_writes(session_id);
    CREATE TABLE IF NOT EXISTS session_cursor(file TEXT PRIMARY KEY, inode INTEGER, offset INTEGER, mtime REAL, parser INTEGER);

    CREATE TABLE IF NOT EXISTS threads(
      id TEXT PRIMARY KEY, key TEXT, title TEXT, user_title TEXT, project TEXT,
      doc_ids TEXT, issue_keys TEXT, session_ids TEXT, primary_doc TEXT,
      last_human REAL, last_ts REAL, score REAL, tier TEXT, reasons TEXT,
      pinned INTEGER DEFAULT 0, demoted_until REAL, updated REAL);
    CREATE TABLE IF NOT EXISTS feedback(id INTEGER PRIMARY KEY AUTOINCREMENT, target TEXT, action TEXT, scope TEXT, ts REAL);

    CREATE TABLE IF NOT EXISTS suggestions(
      id TEXT PRIMARY KEY, kind TEXT, doc_id TEXT, path TEXT, payload TEXT, confidence REAL, reasons TEXT,
      origin TEXT, rule_key TEXT, state TEXT,
      created REAL, decided REAL, batch_id TEXT, cooldown_until REAL, error TEXT);
    CREATE INDEX IF NOT EXISTS suggestions_state ON suggestions(state);
    CREATE TABLE IF NOT EXISTS ops_log(
      id INTEGER PRIMARY KEY AUTOINCREMENT, batch_id TEXT, seq INTEGER, op TEXT,
      from_path TEXT, to_path TEXT, backup_path TEXT, before_hash TEXT, after_hash TEXT,
      ts REAL, undone INTEGER DEFAULT 0, note TEXT);
    CREATE INDEX IF NOT EXISTS ops_log_batch ON ops_log(batch_id);
    CREATE TABLE IF NOT EXISTS policy_rules(
      id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT, pattern TEXT, target TEXT, source_file TEXT, note TEXT);
    CREATE TABLE IF NOT EXISTS tag_alias(tag TEXT PRIMARY KEY, canonical TEXT, origin TEXT);

    CREATE TABLE IF NOT EXISTS enrichments(
      doc_id TEXT, task TEXT, engine TEXT, content_hash TEXT, output TEXT, ts REAL, PRIMARY KEY(doc_id, task));

    CREATE TABLE IF NOT EXISTS ai_log(
      id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, kind TEXT, text TEXT, origin TEXT, ref TEXT, batch_id TEXT);
    CREATE INDEX IF NOT EXISTS ai_log_ts ON ai_log(ts);

    CREATE TABLE IF NOT EXISTS trash_items(
      id TEXT PRIMARY KEY, batch_id TEXT, doc_id TEXT, source_id TEXT, rel_path TEXT, title TEXT,
      orig_path TEXT, trash_path TEXT, size INTEGER, hash TEXT, copied INTEGER DEFAULT 0,
      deleted REAL, expires REAL, origin TEXT, via TEXT, reason TEXT, inbound INTEGER DEFAULT 0,
      state TEXT, restored_path TEXT, done REAL, note TEXT);
    CREATE INDEX IF NOT EXISTS trash_items_state ON trash_items(state, deleted);
    CREATE INDEX IF NOT EXISTS trash_items_batch ON trash_items(batch_id);
    """

    func setting(_ key: String) -> String? {
        var v: String? = nil
        try? sql.query("SELECT value FROM settings WHERE key=?", [.text(key)]) { v = $0.isNull(0) ? nil : $0.text(0) }
        return v
    }

    func setSetting(_ key: String, _ value: String?) {
        if let value = value {
            _ = try? sql.run("INSERT OR REPLACE INTO settings(key, value) VALUES(?, ?)", [.text(key), .text(value)])
        } else {
            _ = try? sql.run("DELETE FROM settings WHERE key=?", [.text(key)])
        }
    }
}

// MARK: - 문맥

/// 모든 사서 모듈이 공유하는 문맥. 파사드(Brain)가 만들고 모듈에 넘긴다.
final class BrainContext {
    let home: URL
    let mode: BrainMode
    let env: BrainEnv
    let db: BrainDB
    let index: Store?            // index.sqlite 읽기 전용. nil이면 색인이 아직 없다
    let queue: DispatchQueue     // 직렬. 모든 사서 코드는 여기서만

    var sources: () -> [SourceConfig] = { [] }
    /// 화면 갱신 알림. 파사드가 메인 큐로 넘긴다.
    var emit: (BrainEventKind) -> Void = { _ in }
    /// Synapse(사서)가 볼트 파일을 썼다(이동·링크 수정). 절대 경로들 — 사람 활동에서 뺀다. (Mover → Signals)
    var onSynapseWrite: ([String]) -> Void = { _ in }
    /// 사서가 문서를 옮겼다. 색인 id와 절대 경로. (Mover → Signals·WorkModel)
    var onDocMoved: (_ fromID: String, _ toID: String, _ fromPath: String, _ toPath: String) -> Void = { _, _, _, _ in }
    /// 옵시디언에서 지금 열려 있다고 볼 절대 경로들(실행 중일 때 최근 연 파일 상위 3개). (Signals 제공 → Organizer)
    var obsidianOpenPaths: () -> [String] = { [] }

    /// v0.9: 앱이 넣는다. 출처 제외 폴더를 더하거나 뺀다(Library.updateSource). 실패하면 사람 말 오류, 성공하면 nil. (Tidy exclude·되돌리기)
    var updateSourceExcludes: (_ sourceId: String, _ add: [String], _ remove: [String]) -> String? = { _, _, _ in "출처 설정을 바꿀 수 없어요." }

    /// v0.9: 감지한 볼트 (문서를 다시 읽을 때 같이 갱신).
    private(set) var vaults: VaultMap = .empty
    private(set) var docs: [BrainDoc] = []
    private(set) var byID: [String: BrainDoc] = [:]
    private(set) var byPath: [String: BrainDoc] = [:]   // 절대 경로(NFC) → 문서
    private var indexVersion: Int64 = -2
    private var sourcesStamp = ""

    init(home: URL, mode: BrainMode, env: BrainEnv, db: BrainDB, index: Store?, queue: DispatchQueue) {
        self.home = home; self.mode = mode; self.env = env; self.db = db; self.index = index; self.queue = queue
    }

    func now() -> Date { env.fixedNow ?? Date() }
    var isStopped: Bool { db.setting(BrainSetting.stopped) == "1" }

    /// 색인이 바뀌었으면 문서 목록을 다시 읽는다. 바뀌었으면 true.
    @discardableResult
    func reloadDocsIfChanged() -> Bool {
        guard let index = index else { return false }
        let v = index.dataVersion()
        let srcs = sources()
        let stamp = srcs.map { "\($0.id)|\($0.path ?? "")|\($0.enabled)" }.joined(separator: ";")
        if v == indexVersion && stamp == sourcesStamp && !docs.isEmpty { return false }
        indexVersion = v; sourcesStamp = stamp
        vaults = VaultMap.detect(sources: srcs, home: env.userHome)
        let byKind = Dictionary(srcs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var list: [BrainDoc] = []
        for m in (try? index.metas()) ?? [] {
            guard let src = byKind[m.sourceId], src.enabled else { continue }
            let prefix = m.sourceId + ":"
            let rel = m.id.hasPrefix(prefix) ? String(m.id.dropFirst(prefix.count)) : m.id
            let local = !src.kind.isRemoteKind
            list.append(BrainDoc(id: m.id, rowid: m.rowid, sourceId: m.sourceId, sourceKind: src.kind, kind: m.kind,
                                 title: m.title, relPath: rel, absPath: local ? m.location : nil, location: m.location,
                                 folder: m.folder, modified: Date(timeIntervalSince1970: m.modified),
                                 created: m.created.map { Date(timeIntervalSince1970: $0) }, size: m.size,
                                 tags: m.tags, outLinks: m.outLinks, issueKeys: m.issueKeys, meta: m.meta,
                                 paraRel: local ? vaults.paraRel(forAbs: m.location) : nil))
        }
        docs = list
        byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        byPath = Dictionary(list.compactMap { d in d.absPath.map { ($0.precomposedStringWithCanonicalMapping, d) } },
                            uniquingKeysWith: { a, _ in a })
        return true
    }

    func doc(id: String) -> BrainDoc? { byID[id] }
    func doc(path: String) -> BrainDoc? { byPath[path.precomposedStringWithCanonicalMapping] }

    /// 본문 (색인에 있는 평문, maxChars까지).
    func text(_ d: BrainDoc, maxChars: Int = 400_000) -> String {
        index?.readText(rowid: d.rowid, maxChars: maxChars).0 ?? ""
    }

    /// 로컬 출처(폴더·옵시디언) 루트. 옵시디언 볼트가 앞에 온다.
    func localRoots() -> [(source: SourceConfig, root: URL)] {
        sources().filter { $0.enabled && !$0.kind.isRemoteKind && $0.path != nil }
            .sorted { ($0.kind == .obsidian ? 0 : 1) < ($1.kind == .obsidian ? 0 : 1) }
            .map { ($0, URL(fileURLWithPath: $0.path!)) }
    }

    /// AI 기록(⌘Y)에 한 줄 남긴다. kind: check | inPlace | propose | apply | undo | rollback | reject | summary | policy | session | stop
    /// v0.6: trash(휴지통으로) | restore(되살림) | purge(macOS 휴지통으로) | direct(바로 실행 설정)
    func log(_ kind: String, _ text: String, origin: String = "rules", ref: String? = nil, batch: String? = nil) {
        _ = try? db.sql.run("INSERT INTO ai_log(ts, kind, text, origin, ref, batch_id) VALUES(?,?,?,?,?,?)",
                            [.double(now().timeIntervalSince1970), .text(kind), .text(text), .text(origin),
                             ref.map { .text($0) } ?? .null, batch.map { .text($0) } ?? .null])
    }
}

extension SourceKind {
    /// Library 쪽 private isRemote와 같은 뜻 (atlassian·mcp).
    var isRemoteKind: Bool { self == .atlassian || self == .mcp }
}

// MARK: - 모듈 계약 (클래스 이름 고정: Signals · Organizer · WorkModel — 모두 init(ctx:))

/// S1 — 활동·작성 주체·멈춘 곳·옵시디언 최근 파일·세션 기록·할 일·유형/상태/프로젝트 (§4)
protocol SignalsModule: AnyObject {
    func start()                                   // 앱 모드: 옵시디언 최근 파일·세션 폴더 감시
    func stop()
    func processIndexChanges() -> [String]         // 색인 변화 반영 → 바뀐(생김·바뀜·옮김) 문서 id
    func scanSessions(budget: TimeInterval) -> Bool   // 세션 기록 증분 읽기. true = 더 남음
    func track(event: String, docId: String)       // Synapse 안 사람 활동: open | view | edit | save
    func obsidianOpenPaths() -> [String]
    func sessionsJSON() -> [String: Any]           // 설정 화면용 (§9.8)
    func purgeOld()                                // 보존 기한 정리 (요청 문장 30일 등)
}

/// S2 — 규칙표·자리 제안·제안 수명·적용·되돌리기 (§6)
protocol OrganizerModule: AnyObject {
    func refreshPolicy()                           // CLAUDE.md 변화 감지 → 규칙표 다시 만들기
    func checkNew(docIds: [String])                // 새·바뀐 문서 제자리 확인 (기록만)
    func runBatch(force: Bool) -> Int              // 제안 만들기. 만든 개수
    func pending() -> [String: Any]                // §8.2 pending
    func decide(id: String, action: String, to: String?) -> [String: Any]
    func decideBundle(id: String) -> [String: Any]
    func undo(batchId: String?) -> [String: Any]
    func policy() -> [String: Any]
    func approvePolicy() -> [String: Any]
    func suggestLocation(_ args: [String: Any]) -> [String: Any]                // MCP
    func propose(items: [[String: Any]], origin: String) -> [String: Any]       // MCP
    func listPending() -> [String: Any]            // MCP
    func vaultPolicy() -> [String: Any]            // MCP
    func pendingCount() -> Int
    func diagnostics() -> [String: Any]            // 자체 점검(한 개 빼고 맞히기) 등
}

/// S3 — 작업 흐름·점수·단계·화면 모델·기기 AI (§5)
protocol WorkModule: AnyObject {
    func refresh(changed: [String])                // 흐름·점수 다시 계산 (홈은 저장값만 읽게)
    func home() -> [String: Any]
    func why(id: String) -> [String: Any]
    func feedback(id: String, action: String, scope: String?) -> [String: Any]
    func week(offset: Int) -> [String: Any]
    func tickets(mine: Bool) -> [String: Any]                 // v0.7 A
    func map() -> [String: Any]
    func workContext(period: String) -> [String: Any]   // MCP
    func claudeInstruction(context: String, id: String?) -> String
    func engineState() -> [String: Any]            // {"apple": "ready"|"off"|"unsupported", "reason": …, "label": "기기 AI"|"규칙"}
    func enrichStep(budget: TimeInterval) -> Bool  // 기기 AI 한 조각. true = 더 남음
}

// MARK: - 파사드 계약 (S1이 Brain.swift에 구현, S4가 사용)

/// 브리지·MCP·CLI가 부르는 사서 입구. 모든 메서드는 아무 스레드에서나 불러도 되고(내부에서 ctx.queue로 넘긴다),
/// 실패는 던지지 않고 ["ok": false, "error": "사람이 읽는 한국어"]로 돌려준다.
protocol BrainAPI: AnyObject {
    var onEvent: ((BrainEventKind) -> Void)? { get set }     // 메인 큐에서 불린다
    // v0.9 — 작업 지도 · 정리 비서 (docs/V09.md §8)
    func workMap() -> [String: Any]
    func workMapDetail(id: String) -> [String: Any]
    func tidyPlan() -> [String: Any]
    func tidyDecide(id: String, action: String, to: String?) -> [String: Any]
    func tidyDecideGroup(group: String, ids: [String]?) -> [String: Any]
    func tidyUndo(batchId: String?) -> [String: Any]
    func tidyPromote(signature: String, accept: Bool) -> [String: Any]
    func tidyRules() -> [String: Any]
    func tidySetRule(signature: String, state: String) -> [String: Any]
    func tidyRunRules() -> [String: Any]
    func tidyIngest(result: [String: Any], runId: String?) -> [String: Any]
    func setSourceExcludesUpdater(_ f: @escaping (_ sourceId: String, _ add: [String], _ remove: [String]) -> String?)
    func start()
    func stop()
    func indexChanged()                                       // Library .changed 때마다 (디바운스는 사서가 1초)
    // 화면 — §8.2와 1:1
    func home() -> [String: Any]
    func why(id: String) -> [String: Any]
    func feedback(id: String, action: String, scope: String?) -> [String: Any]
    func week(offset: Int) -> [String: Any]
    func tickets(mine: Bool) -> [String: Any]                 // v0.7 A
    func map() -> [String: Any]
    func pending() -> [String: Any]
    func decide(id: String, action: String, to: String?) -> [String: Any]
    func decideBundle(id: String) -> [String: Any]
    func undo(batchId: String?) -> [String: Any]
    func aiLog(limit: Int) -> [String: Any]
    func settings() -> [String: Any]
    func setSetting(key: String, value: String) -> [String: Any]
    func policy() -> [String: Any]
    func approvePolicy() -> [String: Any]
    func claudeInstruction(context: String, id: String?) -> [String: Any]
    func setProjectScope(project: String, scope: String) -> [String: Any]   // v0.7 B: 업무/개인 바꾸기
    func track(event: String, docId: String)
    func runBatchNow() -> [String: Any]
    // MCP — §7
    func workContext(period: String) -> [String: Any]
    func vaultPolicy() -> [String: Any]
    func listPending() -> [String: Any]
    func suggestLocation(_ args: [String: Any]) -> [String: Any]
    func proposeChanges(items: [[String: Any]], origin: String) -> [String: Any]
    // v0.6 T — 휴지통·직접 옮기기·MCP 바로 실행 (COMMON §3 C3·C4)
    func trashInfo(ids: [String]) -> [String: Any]
    func trashDocs(ids: [String], reason: String?) -> [String: Any]
    func listTrash() -> [String: Any]
    func restoreTrash(ids: [String]?, batch: String?) -> [String: Any]
    func purgeTrash(ids: [String]) -> [String: Any]
    func moveDocs(ids: [String], to: String) -> [String: Any]
    func applyChanges(items: [[String: Any]], origin: String) -> [String: Any]
    // v0.8 — Jira 제안·실행 id (docs/V08.md §6.1, E3)
    /// proposeChanges(items:origin:)와 같고, 실행 id(SYNAPSE_RUN_ID)를 이동·삭제 제안의 payload.run에 남긴다. nil·형식이 틀린 값은 남기지 않는다.
    func proposeChanges(items: [[String: Any]], origin: String, runId: String?) -> [String: Any]
    /// Jira 변경 제안 받기 → {ok, accepted:[{index, id, what, replaced?}], rejected:[{index, reason}], note}. 한 번 10개, origin별 하루 30개.
    func proposeJira(items: [[String: Any]], origin: String, runId: String?) -> [String: Any]
    /// pending·failed → applying (조건부 UPDATE — 이긴 쪽만). {ok, proposal:{id, op, key, docId, sourceId, to, body, project, issueType, summary,
    /// description, run, retryUncertain}} | {ok:false, error, state?}
    func jiraBegin(id: String) -> [String: Any]
    /// applying → applied | failed, ai_log("jira"). result: JiraWriter 결과(+ edited {body?, to?}, uncertain). {ok, id, state}
    func jiraFinish(id: String, ok: Bool, message: String, result: [String: Any]?) -> [String: Any]
    /// Synapse에서 띄운 Claude 실행이 올린 제안 카드(이동·삭제·Jira, 모든 상태, 최근 순).
    func proposals(run: String) -> [[String: Any]]
    // CLI·시험
    func scanSessionsNow() -> [String: Any]
    func diagnostics() -> [String: Any]
}
