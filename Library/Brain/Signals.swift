import Foundation
import SQLite3

// v0.5 사서 신호 (docs/V05.md §4). 모든 메서드는 ctx.queue에서만 부른다.
// 파일 나눔: Signals(색인 변화) · SignalsAuthor(작성 주체·이동·track) · SignalsText(본문 분석·유형)
//           · SignalsTasks(할 일·Jira) · SignalsSessions(세션 읽기) · SignalsSessionParse(줄 해석·가림) · SignalsObsidian

final class Signals: SignalsModule {
    let ctx: BrainContext
    var db: SQLiteDB { ctx.db.sql }

    /// doc_state 중 S1이 쓰는 열 (summary·summary_source는 S3).
    struct DocState {
        var docId: String
        var sourceId: String
        var path: String
        var contentHash: String? = nil
        var lineHashes: String? = nil
        var headings: String? = nil
        var type: String? = nil
        var status: String? = nil
        var project: String? = nil
        var author: String? = nil
        var authorSession: String? = nil
        var aiArchive = 0, archived = 0, excluded = 0
        var firstSeen: Double? = nil
        var lastChange: Double? = nil
        var lastHuman: Double? = nil
        var lastAI: Double? = nil
        var lastOpen: Double? = nil
        var stoppedLine: Int? = nil
        var stoppedHeading: String? = nil
        var openTasks = 0, doneTasks = 0
        var dueMin: String? = nil
        var updated: Double? = nil
    }

    /// 이동 판정용으로 잠시 들고 있는 사라진 행.
    struct GoneRow { let state: DocState; let at: Date }

    var gone: [String: GoneRow] = [:]          // content_hash → 행 (10분)
    var synapseWrites: [String: Date] = [:]    // 절대 경로(NFC) → Synapse가 쓴 시각
    var lastSave: [String: Date] = [:]         // docId → Synapse 편집기 저장 시각
    var projectAlias: [String: [String: String]] = [:]   // sourceId → 프로젝트 폴더 → 묶은 이름
    var obsidianLists: [String: [String]] = [:]          // sourceId → lastOpenFiles
    var obsidianStamps: [String: Double] = [:]           // sourceId → workspace.json 수정 시각
    var codexMeta: [String: CodexMeta] = [:]             // 파일 → Codex 세션 메타
    var sessionError: String? = nil
    var fileErrorRun = 0
    var timer: DispatchSourceTimer?
    /// 마지막 scanSessions가 새 기록을 넣었는가 (파사드가 work.refresh 여부를 정한다).
    var lastScanChanged = false
    /// 마지막 processIndexChanges가 처음 실행(조용한 등록)이었는가.
    private(set) var lastRunInitial = false

    struct CodexMeta { var id: String; var cwd: String?; var branch: String? }

    static let textKinds: Set<String> = ["md", "markdown", "txt", "text"]
    static let moveWindow: TimeInterval = 600

    init(ctx: BrainContext) { self.ctx = ctx }

    func now() -> Date { ctx.now() }
    var nowTS: Double { ctx.now().timeIntervalSince1970 }
    var sessionsOn: Bool { ctx.db.setting(BrainSetting.sessionsEnabled) == "1" }

    // MARK: 수명

    func start() {
        guard ctx.mode == .app, timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: ctx.queue)
        t.schedule(deadline: .now() + 2, repeating: 20)
        t.setEventHandler { [weak self] in self?.checkObsidian() }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil }

    // MARK: 색인 변화 (§4.1)

    func processIndexChanges() -> [String] {
        lastRunInitial = false
        let docs = ctx.docs
        guard !docs.isEmpty else { return [] }
        repairOnceV08()   // v0.8 §5.8: 예전 규칙으로 잘못 들어간 기록을 한 번만 고친다 (처음 실행이면 표시만 한다)
        var lite: [String: (hash: String?, path: String, source: String, seen: Double)] = [:]
        try? db.query("SELECT doc_id, content_hash, path, source_id, COALESCE(updated, last_change, 0) FROM doc_state") {
            lite[$0.text(0)] = ($0.isNull(1) ? nil : $0.text(1), $0.text(2), $0.text(3), $0.double(4))
        }
        let initial = lite.isEmpty
        lastRunInitial = initial
        let knownSources = Set(lite.values.map { $0.source })   // v0.8 §5.8-1: 이번 실행 전에 이미 본 출처
        let nowD = now()
        gone = gone.filter { nowD.timeIntervalSince($0.value.at) <= Signals.moveWindow }
        rebuildProjectAlias(docs)
        repairParaIfNeeded(docs)   // v0.9 §3.2: 볼트 지도가 바뀌면(처음 포함) 경로 규칙(유형·프로젝트)만 다시
        let enabledSources = Set(ctx.sources().filter { $0.enabled }.map { $0.id })
        let current = Set(docs.map { $0.id })
        var removed = Set(lite.keys.filter { !current.contains($0) })
        var removedByHash: [String: String] = [:]
        for id in removed { if let h = lite[id]?.hash, !h.isEmpty { removedByHash[h] = id } }
        var changed: [String] = []
        let remote = loadRemoteStates()

        try? db.transaction {
            for d in docs {
                if let s = lite[d.id] {
                    if !d.isLocal {
                        if processRemote(d, existing: true, seen: s.seen, remote: remote) { changed.append(d.id) }
                    } else if d.modified.timeIntervalSince1970 > s.seen + 0.001 {
                        if processModified(d) { changed.append(d.id) }
                    } else if d.relPath != s.path {
                        refreshPathFeatures(d)   // 사서가 옮긴 문서: 경로 규칙만 다시
                        changed.append(d.id)
                    }
                    continue
                }
                // 새 id
                if !d.isLocal {
                    _ = processRemote(d, existing: false, seen: 0, remote: remote)
                    if !initial { changed.append(d.id) }
                    continue
                }
                let a = analyze(d)
                if !initial, let h = a.hash {
                    if let old = removedByHash[h], lite[old]?.source == d.sourceId, removed.contains(old) {
                        removed.remove(old); removedByHash[h] = nil
                        moveState(from: old, to: d, analysis: a, restore: nil)
                        changed.append(d.id); continue
                    }
                    if let g = gone[h], g.state.sourceId == d.sourceId {
                        gone[h] = nil
                        moveState(from: g.state.docId, to: d, analysis: a, restore: g.state)
                        changed.append(d.id); continue
                    }
                }
                if initial {
                    registerQuietly(d, analysis: a)
                    if nowD.timeIntervalSince(d.modified) <= 30 * 86400 { changed.append(d.id) }
                } else if Signals.isDiscovered(d, knownSources: knownSources, now: nowD) {
                    // v0.8 §5.8-1 발견 ≠ 작성: 처음 보는 출처의 문서, 하루 넘게 묵은 파일은 "새로 만든 문서"가 아니다.
                    // 처음 본 시각은 파일의 생성·수정 시각, 처음부터 체크된 줄은 완료 시각을 비운다(처음 실행과 같다).
                    registerQuietly(d, analysis: a)
                    changed.append(d.id)
                } else {
                    registerCreated(d, analysis: a)
                    changed.append(d.id)
                }
            }
            for id in removed {
                guard let st = loadState(id) else { continue }
                _ = try? db.run("DELETE FROM doc_state WHERE doc_id=?", [.text(id)])
                _ = try? db.run("UPDATE tasks SET gone=1 WHERE doc_id=?", [.text(id)])
                guard enabledSources.contains(st.sourceId) else { continue }   // 출처를 끈 것은 조용히
                // v0.9 §3.1: 겹친 출처의 사본이 빠졌다(같은 파일을 안쪽 출처가 색인한다) — 지운 게 아니니 조용히
                if let p = absPath(for: st), ctx.doc(path: p) != nil { continue }
                insertActivity(ts: nowTS, docId: id, path: absPath(for: st), kind: "deleted", actor: .unknown,
                               origin: "fsevents", session: nil, detail: nil)
                if let h = st.contentHash, !h.isEmpty { gone[h] = GoneRow(state: st, at: nowD) }
            }
        }
        return changed
    }

    /// 처음 실행: 조용히 등록. 최근 30일 안에 바뀐 문서만 활동 1건.
    private func registerQuietly(_ d: BrainDoc, analysis a: Analysis) {
        let mt = d.modified.timeIntervalSince1970
        let f = features(d, analysis: a)
        var s = DocState(docId: d.id, sourceId: d.sourceId, path: d.relPath)
        s.firstSeen = (d.created ?? d.modified).timeIntervalSince1970
        s.lastChange = mt
        s.updated = mt
        apply(features: f, analysis: a, to: &s)
        let attr = attribute(d, mtime: d.modified, windowStart: nil, origin: "scan", features: f)
        s.author = attr.actor.rawValue; s.authorSession = attr.session
        if attr.actor == .human || attr.actor == .mixed { s.lastHuman = mt }
        if attr.actor == .claude || attr.actor == .codex || attr.actor == .mixed { s.lastAI = mt }
        if now().timeIntervalSince(d.modified) <= 30 * 86400 {
            insertActivity(ts: mt, docId: d.id, path: d.absPath, kind: "modified", actor: attr.actor,
                           origin: attr.origin, session: attr.session, detail: attr.guess ? ["guess": true] : nil)
        }
        syncTasks(d, analysis: a, features: f, initial: true, state: &s)
        writeState(s)
    }

    private func registerCreated(_ d: BrainDoc, analysis a: Analysis) {
        let mt = d.modified.timeIntervalSince1970
        let f = features(d, analysis: a)
        var s = DocState(docId: d.id, sourceId: d.sourceId, path: d.relPath)
        s.firstSeen = nowTS
        s.lastChange = mt
        s.updated = mt
        apply(features: f, analysis: a, to: &s)
        let start = d.created.map { min($0, d.modified) } ?? d.modified.addingTimeInterval(-120)
        let attr = attribute(d, mtime: d.modified, windowStart: start.addingTimeInterval(-1), origin: "fsevents", features: f)
        applyAttribution(attr, mtime: mt, to: &s)
        if attr.actor != .synapse, let lines = a.lines {
            let diff = SignalText.diff(old: [], new: lines)
            s.stoppedLine = diff.line
            s.stoppedHeading = SignalText.heading(before: diff.line, in: a.headings)
        }
        var detail: [String: Any] = ["lines": a.lines?.count ?? 0]
        if attr.guess { detail["guess"] = true }
        insertActivity(ts: mt, docId: d.id, path: d.absPath, kind: "created", actor: attr.actor,
                       origin: attr.origin, session: attr.session, detail: detail)
        syncTasks(d, analysis: a, features: f, initial: false, state: &s)
        writeState(s)
    }

    /// 있는 문서의 수정 시각이 늦어졌다. 내용이 바뀌었으면 true.
    private func processModified(_ d: BrainDoc) -> Bool {
        guard var s = loadState(d.id) else { return false }
        let mt = d.modified.timeIntervalSince1970
        let a = analyze(d)
        let f = features(d, analysis: a)
        if a.hash == s.contentHash {
            let moved = d.relPath != s.path
            s.updated = mt
            if moved { s.path = d.relPath; apply(features: f, analysis: a, to: &s) }
            writeState(s)
            return moved
        }
        let prevChange = s.lastChange
        let attr = attribute(d, mtime: d.modified, windowStart: prevChange.map { Date(timeIntervalSince1970: $0) },
                             origin: "fsevents", features: f)
        let oldLines = (BrainFormat.parse(s.lineHashes) as? [String]) ?? []
        s.path = d.relPath
        apply(features: f, analysis: a, to: &s)
        var detail: [String: Any] = [:]
        if let newLines = a.lines {
            let diff = SignalText.diff(old: oldLines, new: newLines)
            detail["lines"] = diff.changed
            detail["line"] = diff.line
            let heading = SignalText.heading(before: diff.line, in: a.headings)
            if let h = heading { detail["heading"] = h }
            let human = attr.actor == .human || attr.actor == .mixed
            if attr.actor != .synapse && (human || !hasHumanChange(d.id)) {
                s.stoppedLine = diff.line; s.stoppedHeading = heading
            }
        }
        if attr.guess { detail["guess"] = true }
        s.lastChange = mt
        s.updated = mt
        applyAttribution(attr, mtime: mt, to: &s)
        insertActivity(ts: mt, docId: d.id, path: d.absPath, kind: "modified", actor: attr.actor,
                       origin: attr.origin, session: attr.session, detail: detail.isEmpty ? nil : detail)
        syncTasks(d, analysis: a, features: f, initial: false, state: &s)
        writeState(s)
        return true
    }

    /// 사서가 옮긴 뒤 처음 보는 경로: 유형·프로젝트 등 경로 규칙만 다시 계산한다.
    func refreshPathFeatures(_ d: BrainDoc) {
        guard var s = loadState(d.id) else { return }
        let a = analyze(d)
        s.path = d.relPath
        apply(features: features(d, analysis: a), analysis: a, to: &s)
        syncTasks(d, analysis: a, features: features(d, analysis: a), initial: false, state: &s)
        writeState(s)
    }

    private func hasHumanChange(_ docId: String) -> Bool {
        var found = false
        try? db.query("""
        SELECT 1 FROM activity WHERE doc_id=? AND actor IN ('human','mixed') AND kind IN ('created','modified') LIMIT 1
        """, [.text(docId)]) { _ in found = true }
        return found
    }

    func absPath(for s: DocState) -> String? {
        guard let root = ctx.localRoots().first(where: { $0.source.id == s.sourceId })?.root else { return nil }
        return root.appendingPathComponent(s.path).path.precomposedStringWithCanonicalMapping
    }
}

extension Signals {
    static let paraStampKey = "signals.paraStamp"

    /// v0.9 §3.3: 잡음 문서(WorkNoise)를 뺀 열린 할 일 수 (진단용).
    func openTasksShown() -> Int {
        let hidden = WorkNoise.hiddenDocs(ctx)
        var n = 0
        try? db.query("SELECT doc_id FROM tasks WHERE gone=0 AND state IN ('open','doing')") { if !hidden.contains($0.text(0)) { n += 1 } }
        return n
    }

    /// v0.9 §3.2: 볼트 지도(VaultMap)가 바뀌었으면 로컬 문서의 경로 규칙(유형·프로젝트·보관·제외)을 볼트 기준으로 다시 계산한다.
    /// 본문은 다시 읽지 않는다(저장된 제목 목록을 쓴다). 할 일·상태·작성자는 그대로 둔다.
    func repairParaIfNeeded(_ docs: [BrainDoc]) {
        let stamp = "v1|" + ctx.vaults.roots.joined(separator: ";")
        guard ctx.db.setting(Signals.paraStampKey) != stamp else { return }
        var rows: [String: (type: String?, project: String?, ai: Int, arch: Int, exc: Int, headings: String?)] = [:]
        try? db.query("SELECT doc_id, type, project, ai_archive, archived, excluded, headings FROM doc_state") { r in
            rows[r.text(0)] = (r.isNull(1) ? nil : r.text(1), r.isNull(2) ? nil : r.text(2), Int(r.int(3)), Int(r.int(4)), Int(r.int(5)),
                               r.isNull(6) ? nil : r.text(6))
        }
        try? db.transaction {
            for d in docs where d.isLocal {
                guard let old = rows[d.id] else { continue }
                var a = Analysis()
                if let h = BrainFormat.parse(old.headings) as? [[Any]] {
                    a.headings = h.compactMap { x in
                        guard x.count >= 3, let t = x[2] as? String else { return nil }
                        return ((x[0] as? Int) ?? 0, (x[1] as? Int) ?? 0, t)
                    }
                }
                let f = features(d, analysis: a)
                let ai = f.aiArchive ? 1 : 0, arch = f.archived ? 1 : 0, exc = f.excluded ? 1 : 0
                if f.type == old.type && f.project == old.project && ai == old.ai && arch == old.arch && exc == old.exc { continue }
                _ = try? db.run("UPDATE doc_state SET type=?, project=?, ai_archive=?, archived=?, excluded=? WHERE doc_id=?",
                                [.text(f.type), f.project.map { .text($0) } ?? .null, .int(Int64(ai)), .int(Int64(arch)), .int(Int64(exc)), .text(d.id)])
            }
        }
        ctx.db.setSetting(Signals.paraStampKey, stamp)
    }

    /// 진단용 개수 (CLI diag).
    func diagnostics() -> [String: Any] {
        func n(_ sql: String) -> Int { var v = 0; try? db.query(sql) { v = Int($0.int(0)) }; return v }
        return ["docState": n("SELECT count(*) FROM doc_state"), "activity": n("SELECT count(*) FROM activity"),
                "openTasks": n("SELECT count(*) FROM tasks WHERE gone=0 AND state IN ('open','doing')"),
                "openTasksShown": openTasksShown(),   // v0.9 §3.3: 보기에서 거른 뒤(잡음 문서 제외)
                "sessions": n("SELECT count(*) FROM ai_sessions"), "aiWrites": n("SELECT count(*) FROM ai_writes"),
                "sessionError": sessionError ?? NSNull()]
    }
}

// MARK: - v0.8 §5.8 발견 ≠ 작성 · 한 번 보정

extension Signals {
    static let repairDiscoveredKey = "repair.v08.discovered"   // 발견 문서 보정 (값: 보정 결과 JSON — 근거)
    static let repairGuidesKey = "repair.v08.guides"           // 지침 줄 할 일 보정 (값: 보정 결과 JSON)
    static let discoveredAge: TimeInterval = 24 * 3600

    /// 첫 실행 뒤 새로 보인 로컬 문서가 "발견"인가: 그 출처를 처음 보거나(출처를 새로 연결함), 파일 수정 시각이 지금보다 24시간 넘게 이르다.
    static func isDiscovered(_ d: BrainDoc, knownSources: Set<String>, now: Date) -> Bool {
        if !knownSources.contains(d.sourceId) { return true }
        return now.timeIntervalSince(d.modified) > discoveredAge
    }

    /// brain 설정에 표시가 없을 때 한 번만 돈다. 처음 실행(doc_state가 빔)이면 고칠 것이 없으니 표시만 한다.
    func repairOnceV08() {
        let needDiscovered = ctx.db.setting(Signals.repairDiscoveredKey) == nil
        let needGuides = ctx.db.setting(Signals.repairGuidesKey) == nil
        guard needDiscovered || needGuides else { return }
        var empty = true
        try? db.query("SELECT 1 FROM doc_state LIMIT 1") { _ in empty = false }
        if empty {
            let mark = BrainFormat.json(["at": BrainFormat.iso(now()), "initial": true])
            if needDiscovered { ctx.db.setSetting(Signals.repairDiscoveredKey, mark) }
            if needGuides { ctx.db.setSetting(Signals.repairGuidesKey, mark) }
            return
        }
        if needDiscovered { repairDiscovered() }
        if needGuides { repairGuideTasks() }
    }

    /// §5.8-2: 지난 30일 안에 처음 본 로컬 문서 중 파일이 처음 본 시각보다 24시간 넘게 오래된 것(= 발견)을 조용한 등록처럼 고친다.
    /// - first_seen → (생성 ?? 수정) 시각 (등록 당시의 'created' 활동 시각 = 그때 파일 수정 시각도 근거로 본다. 가장 이른 값)
    /// - 그 문서의 할 일: 옛 first_seen과 120초 안에 찍힌 done_at → NULL(처음부터 체크돼 있던 줄), first_seen도 같이 옮긴다
    /// - 등록 때 넣은 'created' 활동: 30일 안이면 조용한 등록과 같은 'modified'(줄 수 없음, detail.repair = "v08")로, 더 오래되면 지운다
    private func repairDiscovered() {
        let nowT = nowTS
        var rows: [(id: String, first: Double)] = []
        try? db.query("SELECT doc_id, first_seen FROM doc_state WHERE first_seen IS NOT NULL AND first_seen >= ?",
                      [.double(nowT - 30 * 86400)]) { rows.append(($0.text(0), $0.double(1))) }
        var created: [String: [(id: Int64, ts: Double, detail: String?)]] = [:]
        try? db.query("SELECT id, doc_id, ts, detail FROM activity WHERE kind='created' AND doc_id IS NOT NULL") { r in
            created[r.text(1), default: []].append((r.int(0), r.double(2), r.isNull(3) ? nil : r.text(3)))
        }
        var docsFixed = 0, tasksFixed = 0, actsFixed = 0
        try? db.transaction {
            for (id, first) in rows {
                guard let d = ctx.doc(id: id), d.isLocal else { continue }
                let acts = created[id] ?? []
                var evidence = [d.modified.timeIntervalSince1970] + acts.map { $0.ts }
                if let c = d.created { evidence.append(c.timeIntervalSince1970) }
                guard let oldest = evidence.min(), first - oldest > Signals.discoveredAge else { continue }
                docsFixed += 1
                try db.run("UPDATE doc_state SET first_seen=? WHERE doc_id=?", [.double(oldest), .text(id)])
                tasksFixed += try db.run("""
                UPDATE tasks SET done_at=NULL WHERE doc_id=? AND origin != 'jira' AND done_at IS NOT NULL AND ABS(done_at - ?) <= 120
                """, [.text(id), .double(first)])
                try db.run("""
                UPDATE tasks SET first_seen=? WHERE doc_id=? AND origin != 'jira' AND first_seen IS NOT NULL AND ABS(first_seen - ?) <= 120
                """, [.double(oldest), .text(id), .double(first)])
                for a in acts {
                    if nowT - a.ts <= 30 * 86400 {
                        var detail = (BrainFormat.parse(a.detail) as? [String: Any]) ?? [:]
                        detail["lines"] = nil          // 파일 전체 줄 수라 "누락 의심"을 부풀린다
                        detail["repair"] = "v08"
                        try db.run("UPDATE activity SET kind='modified', detail=? WHERE id=?", [.text(BrainFormat.json(detail)), .int(a.id)])
                    } else {
                        try db.run("DELETE FROM activity WHERE id=?", [.int(a.id)])
                    }
                    actsFixed += 1
                }
            }
        }
        ctx.db.setSetting(Signals.repairDiscoveredKey, BrainFormat.json(["at": BrainFormat.iso(now()), "docs": docsFixed,
                                                                          "tasks": tasksFixed, "activity": actsFixed]))
        if docsFixed > 0 {
            ctx.log("repair", "이미 있던 문서 \(docsFixed)개를 '새로 만든 문서'에서 뺐어요"
                    + (tasksFixed > 0 ? " · 처음부터 체크돼 있던 줄 \(tasksFixed)개는 완료로 세지 않아요" : ""))
        }
    }

    /// §5.8-4: 지침 파일(AGENTS.md 등)과 원칙·규칙·지침·…기준 제목 바로 아래의 할 일을 사라진 것으로 둔다.
    /// 이후에는 extractTasks가 같은 규칙으로 뽑지 않는다(상위 제목까지 보는 것은 문서가 바뀔 때 적용된다).
    private func repairGuideTasks() {
        var hits: [(id: String, doc: String)] = []
        try? db.query("""
        SELECT t.id, t.doc_id, t.heading, s.path, t.text FROM tasks t LEFT JOIN doc_state s ON s.doc_id = t.doc_id
        WHERE t.gone = 0 AND t.origin != 'jira'
        """) { r in
            let heading = r.isNull(2) ? "" : r.text(2)
            let file = ((r.isNull(3) ? "" : r.text(3)) as NSString).lastPathComponent
            let text = r.isNull(4) ? "" : r.text(4)
            // extractTasks와 같은 규칙: 규칙 제목 아래는 모두, 기준 제목 아래는 규칙 문장만 (heading = 가장 가까운 제목)
            let kind = Signals.guideHeading(heading)
            if Signals.isGuideFile(file) || kind == .rules || (kind == .criteria && Signals.isRuleSentence(text)) { hits.append((r.text(0), r.text(1))) }
        }
        let docs = Set(hits.map { $0.doc })
        try? db.transaction {
            for h in hits { try db.run("UPDATE tasks SET gone=1 WHERE id=?", [.text(h.id)]) }
            for id in docs.sorted() {
                guard var s = loadState(id) else { continue }
                countTasks(id, into: &s)
                writeState(s)
            }
        }
        ctx.db.setSetting(Signals.repairGuidesKey, BrainFormat.json(["at": BrainFormat.iso(now()), "tasks": hits.count, "docs": docs.count]))
    }
}
