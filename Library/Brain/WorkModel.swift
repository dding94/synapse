import Foundation

// v0.5 작업 모델 (S3) — docs/V05.md §5.
// refresh(changed:)에서 흐름·점수·단계를 계산해 threads에 저장하고, 화면 JSON(home·why·week·map·workContext)은 저장값만 읽는다.
// 모든 메서드는 ctx.queue 안에서 불린다(파사드 책임).

// MARK: - 읽은 행

struct WorkDocState {
    let id: String
    var sourceId: String = ""
    var path: String = ""
    var contentHash: String?
    var type: String?
    var status: String?
    var project: String?
    var author: String?
    var aiArchive = false, archived = false, excluded = false
    var firstSeen: Double?, lastChange: Double?, lastHuman: Double?, lastAI: Double?, lastOpen: Double?
    var stoppedLine: Int?
    var stoppedHeading: String?
    var summary: String?
    var summarySource: String?
    var openTasks = 0, doneTasks = 0
    var dueMin: String?
}

struct WorkActivity {
    let ts: Double
    let docId: String?
    let path: String?
    let kind: String
    let actor: String
    let origin: String
    let sessionId: String?
    let lines: Int
}

struct WorkTask {
    let id: String
    let docId: String
    let line: Int?
    let text: String
    let heading: String?
    let state: String
    let due: String?
    let prio: String?
    let origin: String
    let firstSeen: Double?
    let doneAt: Double?
    var isOpen: Bool { state == "open" || state == "doing" }
}

struct WorkRemote {
    let docId: String
    let key: String
    let title: String
    let status: String
    let statusCat: String
    let priority: String
    let due: String?
    let mine: Bool
    let changed: Double?
}

struct WorkSession {
    let id: String
    let tool: String
    let cwd: String
    let branch: String
    let issueKeys: [String]
    let title: String?
    let started: Double
    let lastTs: Double
    let firstAsk: String?
    let lastAsk: String?
    let lastAskTs: Double?
    var writes: [(path: String, ts: Double)] = []
}

/// 사용자 교정(feedback 표)을 시간 순으로 접은 결과.
struct WorkFeedback {
    var pinned: Set<String> = []
    var demoted: [String: Double] = [:]      // 흐름 id → 덜 중요 기한
    var wake: [String: Double] = [:]
    var rename: [String: String] = [:]
    var notThisFolder: Set<String> = []      // 문서 id
}

/// 저장된 threads 행.
struct WorkThreadRow {
    let id: String
    let key: String
    let title: String
    let userTitle: String?
    let project: String?
    let docIds: [String]
    let issueKeys: [String]
    let sessionIds: [String]
    let primaryDoc: String?
    let lastHuman: Double?
    let lastTs: Double?
    let score: Double
    let tier: Tier
    let reasons: [[String: Any]]
    let pinned: Bool
    let demotedUntil: Double?
    let updated: Double?
    var displayTitle: String { (userTitle?.isEmpty == false) ? userTitle! : title }
    var isCode: Bool { key.hasPrefix("code:") }
    var isSession: Bool { key.hasPrefix("session:") }
}

// MARK: - 작업 모델

final class WorkModel: WorkModule {
    let ctx: BrainContext
    /// 정리 대기 수. 파사드가 organizer.pendingCount로 연결한다. nil이면 suggestions 표에서 센다.
    var pendingCount: (() -> Int)?
    /// 기기 AI 엔진. 시험에서 가짜 엔진으로 바꿀 수 있다.
    var engine: EnrichEngine { didSet { stateCache = nil } }
    let rules = WorkRulesEngine()
    var enrichInFlight = false
    var enrichPending = 0
    var stateCache: (at: Date, value: (String, String?))?
    /// 시험용: 저전력·발열 판단을 덮어쓴다.
    var pauseOverride: Bool?

    static let maxThreads = 40
    static let windowDays = 30.0

    init(ctx: BrainContext) {
        self.ctx = ctx
        engine = WorkAppleEngine.make()
    }

    var now: Date { ctx.now() }
    var nowTS: Double { ctx.now().timeIntervalSince1970 }
    var sessionsOn: Bool { ctx.db.setting(BrainSetting.sessionsEnabled) == "1" }
    var requestTextOn: Bool { (ctx.db.setting(BrainSetting.sessionsRequestText) ?? "1") == "1" }

    // MARK: 읽기 도우미

    func opt(_ r: SQLiteDB.Row, _ i: Int32) -> String? { r.isNull(i) ? nil : r.text(i) }
    func optD(_ r: SQLiteDB.Row, _ i: Int32) -> Double? { r.isNull(i) ? nil : r.double(i) }

    func loadDocStates() -> [String: WorkDocState] {
        var out: [String: WorkDocState] = [:]
        try? ctx.db.sql.query("""
        SELECT doc_id, source_id, path, content_hash, type, status, project, author, ai_archive, archived, excluded,
          first_seen, last_change, last_human, last_ai, last_open, stopped_line, stopped_heading, summary, summary_source,
          open_tasks, done_tasks, due_min FROM doc_state
        """) { r in
            var s = WorkDocState(id: r.text(0))
            s.sourceId = r.text(1); s.path = r.text(2); s.contentHash = opt(r, 3)
            s.type = opt(r, 4); s.status = opt(r, 5); s.project = opt(r, 6); s.author = opt(r, 7)
            s.aiArchive = r.int(8) != 0; s.archived = r.int(9) != 0; s.excluded = r.int(10) != 0
            s.firstSeen = optD(r, 11); s.lastChange = optD(r, 12); s.lastHuman = optD(r, 13)
            s.lastAI = optD(r, 14); s.lastOpen = optD(r, 15)
            s.stoppedLine = r.isNull(16) ? nil : Int(r.int(16)); s.stoppedHeading = opt(r, 17)
            s.summary = opt(r, 18); s.summarySource = opt(r, 19)
            s.openTasks = Int(r.int(20)); s.doneTasks = Int(r.int(21)); s.dueMin = opt(r, 22)
            out[s.id] = s
        }
        return out
    }

    func loadActivity(since: Double, until: Double = .greatestFiniteMagnitude) -> [WorkActivity] {
        var out: [WorkActivity] = []
        try? ctx.db.sql.query("""
        SELECT ts, doc_id, path, kind, actor, origin, session_id, detail FROM activity WHERE ts >= ? AND ts < ? ORDER BY ts
        """, [.double(since), .double(until)]) { r in
            var lines = 0
            if let d = opt(r, 7), d.contains("lines"), let o = BrainFormat.parse(d) as? [String: Any] {
                lines = (o["lines"] as? Int) ?? Int((o["lines"] as? Double) ?? 0)
            }
            out.append(WorkActivity(ts: r.double(0), docId: opt(r, 1), path: opt(r, 2), kind: r.text(3), actor: r.text(4),
                                    origin: r.text(5), sessionId: opt(r, 6), lines: lines))
        }
        return out
    }

    /// 사라지지 않은 할 일 (open·doing·done·cancelled).
    /// v0.9 §3.3: 보기용이라 잡음 문서(AI 보관본·4-Archive·3-Resources·동결·원자료 아래)의 할 일은 거른다(지우지 않는다). includeNoise면 그대로.
    func loadTasks(openOnly: Bool = false, includeNoise: Bool = false) -> [WorkTask] {
        var out: [WorkTask] = []
        let filter = openOnly ? " AND state IN ('open','doing')" : ""
        let hidden = includeNoise ? [] : WorkNoise.hiddenDocs(ctx)
        try? ctx.db.sql.query("""
        SELECT id, doc_id, line, text, heading, state, due, prio, origin, first_seen, done_at FROM tasks WHERE gone = 0\(filter)
        """) { r in
            if !hidden.isEmpty && hidden.contains(r.text(1)) { return }
            out.append(WorkTask(id: r.text(0), docId: r.text(1), line: r.isNull(2) ? nil : Int(r.int(2)), text: r.text(3),
                                heading: opt(r, 4), state: r.text(5), due: opt(r, 6), prio: opt(r, 7), origin: r.text(8),
                                firstSeen: optD(r, 9), doneAt: optD(r, 10)))
        }
        return out
    }

    func loadRemote() -> [String: WorkRemote] {
        var out: [String: WorkRemote] = [:]
        try? ctx.db.sql.query("SELECT doc_id, key, title, status, status_cat, priority, due, mine, changed FROM remote_state") { r in
            let x = WorkRemote(docId: r.text(0), key: r.text(1), title: r.text(2), status: r.text(3), statusCat: r.text(4),
                               priority: r.text(5), due: opt(r, 6), mine: r.int(7) != 0, changed: optD(r, 8))
            if !x.key.isEmpty { out[x.key] = x }
        }
        return out
    }

    /// 세션 기록이 켜져 있을 때만 읽는다. since 이후에 움직인 세션 + 쓴 파일.
    func loadSessions(since: Double, ids: Set<String>? = nil, withWrites: Bool = true) -> [WorkSession] {
        guard sessionsOn else { return [] }
        var out: [WorkSession] = []
        var byID: [String: Int] = [:]
        try? ctx.db.sql.query("""
        SELECT id, tool, cwd, branch, issue_keys, title, started, last_ts, first_ask, last_ask, last_ask_ts
        FROM ai_sessions WHERE last_ts >= ? ORDER BY started, id
        """, [.double(since)]) { r in
            let id = r.text(0)
            if let ids = ids, !ids.contains(id) { return }
            if let first = opt(r, 8), WorkModel.isAutomatedAsk(first) { return }   // v0.8 §5.8-3: 사람 작업이 아닌 자동 세션
            let keys = (BrainFormat.parse(opt(r, 4)) as? [String]) ?? []
            byID[id] = out.count
            out.append(WorkSession(id: id, tool: r.text(1).isEmpty ? (id.hasPrefix("codex:") ? "codex" : "claude") : r.text(1),
                                   cwd: r.text(2), branch: r.text(3), issueKeys: keys,
                                   title: opt(r, 5).flatMap { $0.isEmpty ? nil : $0 },
                                   started: r.double(6), lastTs: r.double(7), firstAsk: opt(r, 8), lastAsk: opt(r, 9),
                                   lastAskTs: optD(r, 10)))
        }
        if out.isEmpty || !withWrites { return out }
        try? ctx.db.sql.query("SELECT session_id, path, ts FROM ai_writes WHERE ts >= ? ORDER BY ts", [.double(since - 86400)]) { r in
            if let i = byID[r.text(0)] { out[i].writes.append((r.text(1), r.double(2))) }
        }
        return out
    }

    func loadFeedback() -> WorkFeedback {
        var fb = WorkFeedback()
        try? ctx.db.sql.query("SELECT target, action, scope, ts FROM feedback ORDER BY id") { r in
            let t = WorkModel.threadKey(r.text(0)), scope = opt(r, 2), ts = r.double(3)
            switch r.text(1) {
            case "pin": fb.pinned.insert(t); fb.demoted[t] = nil
            case "unpin": fb.pinned.remove(t)
            case "demote":
                fb.pinned.remove(t)
                fb.demoted[t] = scope == "always" ? 1e12 : WorkTime.nextMonday(Date(timeIntervalSince1970: ts)).timeIntervalSince1970
            case "wake": fb.wake[t] = ts
            case "rename":
                if let s = scope?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { fb.rename[t] = s } else { fb.rename[t] = nil }
            case "notThisFolder":
                if t.hasPrefix("doc:") { fb.notThisFolder.insert(String(t.dropFirst(4))) }
            default: break
            }
        }
        return fb
    }

    /// 들어오는 링크 수(link·embed)와 프로젝트_요약에서 링크된 문서.
    func incomingLinks() -> (counts: [String: Int], fromSummary: Set<String>) {
        guard let index = ctx.index else { return ([:], []) }
        var counts: [String: Int] = [:]
        var fromSummary = Set<String>()
        let summaryIDs = Set(ctx.docs.filter { $0.title == "프로젝트_요약" }.map { $0.id })
        try? index.writer.query("SELECT src, dst FROM links WHERE kind IN ('link','embed')") { r in
            let dst = r.text(1)
            counts[dst, default: 0] += 1
            if summaryIDs.contains(r.text(0)) { fromSummary.insert(dst) }
        }
        return (counts, fromSummary)
    }

    func loadThreads() -> [WorkThreadRow] {
        var out: [WorkThreadRow] = []
        try? ctx.db.sql.query("""
        SELECT id, key, title, user_title, project, doc_ids, issue_keys, session_ids, primary_doc, last_human, last_ts,
          score, tier, reasons, pinned, demoted_until, updated FROM threads ORDER BY score DESC, id
        """) { r in
            out.append(WorkThreadRow(id: r.text(0), key: r.text(1), title: r.text(2), userTitle: opt(r, 3), project: opt(r, 4),
                                     docIds: (BrainFormat.parse(opt(r, 5)) as? [String]) ?? [],
                                     issueKeys: (BrainFormat.parse(opt(r, 6)) as? [String]) ?? [],
                                     sessionIds: (BrainFormat.parse(opt(r, 7)) as? [String]) ?? [],
                                     primaryDoc: opt(r, 8), lastHuman: optD(r, 9), lastTs: optD(r, 10), score: r.double(11),
                                     tier: Tier(rawValue: r.text(12)) ?? .none,
                                     reasons: (BrainFormat.parse(opt(r, 13)) as? [[String: Any]]) ?? [],
                                     pinned: r.int(14) != 0, demotedUntil: optD(r, 15), updated: optD(r, 16)))
        }
        return out
    }

    /// "thread:t:abc" · "t:abc" → "t:abc". 다른 형식(task:… · doc:…)은 그대로.
    static func threadKey(_ id: String) -> String {
        id.hasPrefix("thread:") ? String(id.dropFirst(7)) : id
    }

    /// v0.8 §5.8-3: Codex 앱이 스스로 띄우는 자동 승인 검토 세션의 첫 "요청". 사람이 쓴 요청이 아니고 파일도 쓰지 않는다.
    /// (이런 세션이 많으면 Codex 대화 폴더 이름 "d" 흐름을 만든다. 요청 문장 저장이 꺼져 있으면 알아보지 못한다.)
    static let automatedAskPrefixes = ["The following is the Codex agent history"]
    static func isAutomatedAsk(_ ask: String) -> Bool {
        let t = ask.trimmingCharacters(in: .whitespacesAndNewlines)
        return automatedAskPrefixes.contains { t.hasPrefix($0) }
    }
}

// MARK: - v0.9 §3.3 할 일 잡음

/// 할 일을 보기에서 거를 문서: AI 보관본(aiArchive) · 볼트 4-Archive·3-Resources 아래 · 동결 폴더(볼트 CLAUDE.md 규칙표의 frozen) 아래 · 원자료 폴더 아래.
/// 사서 큐에서만 부른다. 동결 규칙은 CLAUDE.md 수정 시각으로, 원자료 폴더는 문서 목록으로 캐시한다.
enum WorkNoise {
    private static var frozenCache: (stamp: String, rules: [String: [String]])?   // 볼트 루트 → 볼트 기준 동결 폴더("x/y/")
    private static var rawCache: (stamp: String, dirs: [String])?                 // 원자료 폴더 절대 경로

    static func hiddenDocs(_ ctx: BrainContext) -> Set<String> {
        var out = Set<String>()
        try? ctx.db.sql.query("SELECT doc_id FROM doc_state WHERE ai_archive=1") { out.insert($0.text(0)) }
        let frozen = frozenRules(ctx)
        let raw = rawDirs(ctx)
        for d in ctx.docs where d.isLocal {
            guard let abs = d.absPath else { continue }
            if let pr = d.paraRel {
                let top = pr.split(separator: "/").first.map(String.init) ?? ""
                if top == "4-Archive" || top == "3-Resources" { out.insert(d.id); continue }
                if let v = ctx.vaults.vault(forAbs: abs), let rules = frozen[v], rules.contains(where: { pr.hasPrefix($0) }) { out.insert(d.id); continue }
            }
            if !raw.isEmpty, raw.contains(where: { abs.hasPrefix($0 + "/") }) { out.insert(d.id) }
        }
        return out
    }

    /// 볼트마다 동결 폴더 (볼트 CLAUDE.md · 1-Projects/*/CLAUDE.md · 2-Areas/*/CLAUDE.md를 규칙표 해석기로 읽는다. 읽기만).
    static func frozenRules(_ ctx: BrainContext) -> [String: [String]] {
        let fm = FileManager.default
        var files: [(vault: String, rel: String, mtime: Double)] = []
        for v in ctx.vaults.roots {
            var rels = ["CLAUDE.md"]
            for top in ["1-Projects", "2-Areas"] {
                for d in ((try? fm.contentsOfDirectory(atPath: v + "/" + top)) ?? []).sorted() where !d.hasPrefix(".") {
                    rels.append(top + "/" + Indexer.nfc(d) + "/CLAUDE.md")
                }
            }
            for r in rels {
                if let m = (try? fm.attributesOfItem(atPath: v + "/" + r))?[.modificationDate] as? Date {
                    files.append((v, r, m.timeIntervalSince1970))
                }
            }
        }
        let stamp = files.map { "\($0.vault)/\($0.rel)@\($0.mtime)" }.joined(separator: ";") + "|" + ctx.vaults.roots.joined(separator: ";")
        if let c = frozenCache, c.stamp == stamp { return c.rules }
        var rules: [String: [String]] = [:]
        for f in files {
            guard let text = try? String(contentsOfFile: f.vault + "/" + f.rel, encoding: .utf8) else { continue }
            var notes: [String: String] = [:]
            let base = (f.rel as NSString).deletingLastPathComponent
            for r in PolicyParser.compile(text, base: base, source: f.vault + "/" + f.rel, notes: &notes) where r.kind == "frozen" {
                let pat = r.pattern.hasSuffix("/") ? r.pattern : r.pattern + "/"
                if !(rules[f.vault] ?? []).contains(pat) { rules[f.vault, default: []].append(pat) }
            }
        }
        frozenCache = (stamp, rules)
        return rules
    }

    private static let rawName = try! NSRegularExpression(
        pattern: #"^(raw|data|datasets?|results?|expected|fixtures?|dumps?|outputs?|logs?|measure|samples?|cache|tmp|temp|lanes|scraped?|crawl(ed)?)$"#,
        options: [.caseInsensitive])
    private static let mechanical = try! NSRegularExpression(pattern: #"^[A-Za-z_\-]{0,8}\d+$"#)

    static func isRawName(_ n: String) -> Bool { rawName.firstMatch(in: n, range: NSRange(location: 0, length: (n as NSString).length)) != nil }

    /// 원자료 폴더 (색인된 문서로 판단): 출처 기준 깊이 6까지, 비 md 20개 이상 · md 10% 이하 ·
    /// (이름이나 출처 안 조상 이름이 원자료 이름이거나, 파일 80% 이상이 기계적인 이름). 조건을 만족하는 가장 위 폴더.
    static func rawDirs(_ ctx: BrainContext) -> [String] {
        let stamp = "\(ctx.docs.count)|\(ctx.docs.first?.id ?? "")|\(ctx.docs.last?.id ?? "")"
        if let c = rawCache, c.stamp == stamp { return c.dirs }
        var roots: [String: String] = [:]
        for (src, root) in ctx.localRoots() { roots[src.id] = Indexer.nfc(Indexer.realPath(root.path)) }
        // 폴더마다: 안쪽 전체 파일·md 수, 바로 아래 파일·기계적 이름 수, 원자료 이름(자신 또는 출처 안 조상)
        var stats: [String: (files: Int, md: Int, direct: Int, mech: Int, named: Bool)] = [:]
        for d in ctx.docs where d.isLocal {
            guard let root = roots[d.sourceId] else { continue }
            let comps = d.relPath.split(separator: "/").map(String.init)
            guard comps.count >= 2 else { continue }
            let isMd = d.kind == "md" || d.kind == "markdown"
            let stem = ((comps.last ?? "") as NSString).deletingPathExtension
            let mech = mechanical.firstMatch(in: stem, range: NSRange(location: 0, length: (stem as NSString).length)) != nil
            var named = false
            for depth in 1..<min(comps.count, 7) {
                if isRawName(comps[depth - 1]) { named = true }
                let dir = root + "/" + comps[0..<depth].joined(separator: "/")
                var x = stats[dir] ?? (0, 0, 0, 0, false)
                x.files += 1; if isMd { x.md += 1 }; if named { x.named = true }
                if depth == comps.count - 1 { x.direct += 1; if mech { x.mech += 1 } }
                stats[dir] = x
            }
        }
        // 기계적 이름 규칙은 바로 아래 파일로만 본다 (원자료 폴더를 품은 프로젝트 폴더 전체가 원자료로 잡히지 않게)
        let ok = stats.filter { _, x in
            let nonMd = x.files - x.md
            return nonMd >= 20 && x.md * 10 <= x.files && (x.named || (x.direct >= 20 && x.mech * 10 >= x.direct * 8))
        }.keys.sorted { $0.count < $1.count }
        var dirs: [String] = []
        for d in ok where !dirs.contains(where: { d.hasPrefix($0 + "/") }) { dirs.append(d) }
        rawCache = (stamp, dirs)
        return dirs
    }
}
