import Foundation

// §5.9 규칙 요약 채우기 · 기기 AI 큐(enrichments 캐시) · engineState. 본문은 읽기만 한다.

struct WorkEnrichJob {
    let docId: String        // 요약: 문서 id, 이유: 흐름 id
    let task: String         // summary | reason
    let hash: String
    let maxChars: Int
}

/// 비동기 엔진 결과를 큐 쪽으로 넘기는 상자. 시간 안에 끝나면 바로, 늦으면 late로 받는다.
final class WorkEnrichBox {
    private let lock = NSLock()
    private var result: Result<String, Error>?
    private var late: ((Result<String, Error>) -> Void)?
    private let sem = DispatchSemaphore(value: 0)

    func finish(_ r: Result<String, Error>) {
        lock.lock(); result = r; let cb = late; lock.unlock()
        sem.signal()
        cb?(r)
    }
    func wait(_ seconds: TimeInterval, late cb: @escaping (Result<String, Error>) -> Void) -> Result<String, Error>? {
        if sem.wait(timeout: .now() + max(0, seconds)) == .success { lock.lock(); defer { lock.unlock() }; return result }
        lock.lock(); defer { lock.unlock() }
        if let r = result { return r }
        late = cb
        return nil
    }
}

extension WorkModel {

    // MARK: 본문

    /// 로컬 md·txt는 원본 파일(제목 표시가 남아 있다), 그 밖은 색인 평문.
    func rawText(_ d: BrainDoc, maxChars: Int) -> String {
        if let p = d.absPath, ["md", "markdown", "txt", "text"].contains(d.kind.lowercased()),
           let s = try? String(contentsOfFile: p, encoding: .utf8) {
            return s.count > maxChars ? String(s.prefix(maxChars)) : s
        }
        return ctx.text(d, maxChars: maxChars)
    }

    /// 최근 3일 안에 바뀐 데일리·PROGRESS 문서와 그 줄.
    func recentPlanDocs(states: [String: WorkDocState], nowT: Double) -> [(docId: String, file: String, daily: Bool, lines: [String])] {
        states.values.filter { ($0.type == "데일리" || $0.type == "진행현황") && !$0.excluded && ($0.lastChange ?? 0) >= nowT - 3 * 86400 }
            .sorted { $0.id < $1.id }
            .compactMap { s in
                guard let d = ctx.doc(id: s.id) else { return nil }
                return (s.id, WorkUtil.lastComponent(d.relPath), s.type == "데일리", rawText(d, maxChars: 100_000).components(separatedBy: "\n"))
            }
    }

    func mentionSignal(g: WorkGroup, primary: String?, keys: [String],
                       mentions: [(docId: String, file: String, daily: Bool, lines: [String])]) -> WorkSignal? {
        var needles = keys
        if let p = primary, !mentions.contains(where: { $0.docId == p }), let t = ctx.doc(id: p)?.title, t.count >= 2 { needles.append(t) }
        guard !needles.isEmpty else { return nil }
        for m in mentions where m.docId != primary {
            for (i, l) in m.lines.enumerated() where needles.contains(where: { l.contains($0) }) {
                return WorkSignal(points: 10, text: m.daily ? "데일리에 나옴" : "PROGRESS에 나옴", kind: "link",
                                  detail: "\(m.file) \(i + 1)행", docId: m.docId, line: i + 1)
            }
        }
        return nil
    }

    // MARK: 규칙 요약

    /// 원격 문서(Jira·Confluence): 요약·기기 AI 대상이 아니다.
    static func isRemote(_ d: BrainDoc) -> Bool { d.sourceKind.isRemoteKind || d.kind == "jira" || d.kind == "confluence" }

    func enrichmentHashes() -> [String: (hash: String, engine: String, output: String)] {
        var out: [String: (String, String, String)] = [:]
        try? ctx.db.sql.query("SELECT doc_id, task, content_hash, engine, output FROM enrichments") { r in
            out[r.text(0) + "\n" + r.text(1)] = (r.text(2), r.text(3), r.text(4))
        }
        return out
    }

    func hashKey(_ d: BrainDoc, _ s: WorkDocState?) -> String {
        s?.contentHash ?? "m:\(Int(d.modified.timeIntervalSince1970))-\(d.size)"
    }

    /// 흐름 문서 → 최근 30일 문서 순서로, 바뀐 것만 규칙 요약을 채운다. Apple 요약이 같은 내용에 있으면 그대로 둔다.
    func fillRuleSummaries(states: [String: WorkDocState], budget: TimeInterval) {
        let deadline = Date().addingTimeInterval(budget)
        let cache = enrichmentHashes()
        var order: [String] = [], seen = Set<String>()
        let threads = loadThreads()
        for t in threads { if let p = t.primaryDoc, seen.insert(p).inserted { order.append(p) } }
        for t in threads { for d in t.docIds where seen.insert(d).inserted { order.append(d) } }
        let cutoff = nowTS - 30 * 86400
        for s in states.values.sorted(by: { ($0.lastChange ?? 0) > ($1.lastChange ?? 0) }) where (s.lastChange ?? 0) >= cutoff {
            if seen.insert(s.id).inserted { order.append(s.id) }
        }
        // 원격(Jira·Confluence) 문서는 요약을 만들지 않고, 예전에 만든 것도 지운다 (회사 본문이 MCP로 새지 않게)
        for d in ctx.docs where WorkModel.isRemote(d) && states[d.id]?.summary != nil {
            _ = try? ctx.db.sql.run("UPDATE doc_state SET summary = NULL, summary_source = NULL WHERE doc_id = ?", [.text(d.id)])
            _ = try? ctx.db.sql.run("DELETE FROM enrichments WHERE doc_id = ? AND task IN ('summary','rules.summary')", [.text(d.id)])
        }
        for id in order {
            if Date() >= deadline { break }
            guard let d = ctx.doc(id: id), !WorkModel.isRemote(d), let s = states[id], !s.excluded else { continue }
            let h = hashKey(d, s)
            if cache[id + "\nrules.summary"]?.hash == h { continue }
            let found = WorkRules.summary(markdown: rawText(d, maxChars: 20_000), maxChars: 80)
            let apple = cache[id + "\nsummary"]
            let keepApple = s.summarySource == "apple" && apple?.hash == h && apple?.output.isEmpty == false
            if !keepApple {
                _ = try? ctx.db.sql.run("UPDATE doc_state SET summary = ?, summary_source = ? WHERE doc_id = ?",
                                        [found.map { .text($0.text) } ?? .null, found.map { .text($0.source) } ?? .null, .text(id)])
            }
            _ = try? ctx.db.sql.run("INSERT OR REPLACE INTO enrichments(doc_id, task, engine, content_hash, output, ts) VALUES(?,?,?,?,?,?)",
                                    [.text(id), .text("rules.summary"), .text("rules"), .text(h), .text(found?.text ?? ""), .double(nowTS)])
        }
    }

    // MARK: 기기 AI 큐

    func shouldPause() -> Bool {
        if let o = pauseOverride { return o }
        let p = ProcessInfo.processInfo
        return p.isLowPowerModeEnabled || p.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    }

    /// (state, reason) — 30초 캐시.
    func engineStatus() -> (String, String?) {
        if let c = stateCache, Date().timeIntervalSince(c.at) < 30 { return c.value }
        let v = engine.state()
        stateCache = (Date(), v)
        return v
    }

    func engineState() -> [String: Any] {
        let (st, reason) = engineStatus()
        return ["apple": st, "reason": reason ?? NSNull(), "label": st == "ready" ? "기기 AI" : "규칙",
                "pending": st == "ready" ? enrichPending : 0]
    }

    static func chipHash(_ t: WorkThreadRow) -> (String, String) {
        let text = t.reasons.filter { $0["neg"] == nil }.prefix(3).compactMap { $0["text"] as? String }.joined(separator: "\n")
        return (WorkUtil.sha1(text), text)
    }

    /// 사람이 볼 것부터: 홈·이번 주 문서 요약(section 아닌 것) → current·next 이유 문장.
    func enrichQueue(limit: Int) -> [WorkEnrichJob] {
        guard engineStatus().0 == "ready" else { return [] }
        let cache = enrichmentHashes()
        let states = loadDocStates()
        let threads = loadThreads().filter { $0.tier != .dormant }
        var jobs: [WorkEnrichJob] = [], seen = Set<String>()
        var docs = threads.compactMap { $0.primaryDoc }
        let soon = loadTasks(openOnly: true).filter { t in t.due.flatMap { WorkTime.daysUntil($0, now: now) }.map { $0 <= 7 } ?? false }
        docs += soon.map { $0.docId }
        for id in docs where seen.insert(id).inserted && jobs.count < limit {
            guard let d = ctx.doc(id: id), !WorkModel.isRemote(d), let s = states[id], !s.excluded, s.summarySource != "section" else { continue }
            let h = hashKey(d, s)
            if cache[id + "\nsummary"]?.hash == h { continue }
            jobs.append(WorkEnrichJob(docId: id, task: "summary", hash: h, maxChars: 80))
        }
        for t in threads.sorted(by: { $0.score > $1.score }).prefix(4) where jobs.count < limit {
            let (h, text) = WorkModel.chipHash(t)
            if text.isEmpty || cache[t.id + "\nreason"]?.hash == h { continue }
            jobs.append(WorkEnrichJob(docId: t.id, task: "reason", hash: h, maxChars: 60))
        }
        return jobs
    }

    /// 작업 입력과 검증용 원문.
    func enrichInput(_ job: WorkEnrichJob) -> (input: String, source: String)? {
        if job.task == "reason" {
            guard let t = loadThreads().first(where: { $0.id == job.docId }) else { return nil }
            let text = WorkModel.chipHash(t).1
            return (text, text)
        }
        guard let d = ctx.doc(id: job.docId) else { return nil }
        let raw = rawText(d, maxChars: 20_000)
        let heads = raw.components(separatedBy: "\n").compactMap { WorkRules.isHeading($0) }.prefix(20).joined(separator: " / ")
        let body = String(raw.prefix(2500))
        return ("제목: \(d.title)\n제목 목록: \(heads)\n본문:\n\(body)", d.title + "\n" + raw)
    }

    func storeEnrichment(_ job: WorkEnrichJob, source: String, _ r: Result<String, Error>) {
        var output = ""
        if case .success(let out) = r {
            output = (job.task == "summary" ? WorkValidator.summary(out, source: source, maxChars: job.maxChars)
                                             : WorkValidator.reason(out, chips: source, maxChars: job.maxChars)) ?? ""
        }
        _ = try? ctx.db.sql.run("INSERT OR REPLACE INTO enrichments(doc_id, task, engine, content_hash, output, ts) VALUES(?,?,?,?,?,?)",
                                [.text(job.docId), .text(job.task), .text(engine.id), .text(job.hash), .text(output), .double(nowTS)])
        if job.task == "summary" && !output.isEmpty {
            _ = try? ctx.db.sql.run("UPDATE doc_state SET summary = ?, summary_source = 'apple' WHERE doc_id = ?", [.text(output), .text(job.docId)])
            ctx.log("summary", "‘\(ctx.doc(id: job.docId)?.title ?? "")’ 한 줄 요약을 만들었어요", origin: "apple", ref: job.docId)
        }
    }

    /// 기기 AI 한 조각. 한 번에 1개씩, 시간 안에 끝나지 않으면 결과를 나중에 큐에서 받는다. true = 더 남음.
    func enrichStep(budget: TimeInterval) -> Bool {
        if ctx.mode == .mcp || ctx.isStopped || shouldPause() { return false }
        guard engineStatus().0 == "ready" else { enrichPending = 0; return false }
        if enrichInFlight { return true }
        let deadline = Date().addingTimeInterval(budget)
        var jobs = enrichQueue(limit: 50)
        while !jobs.isEmpty {
            let job = jobs.removeFirst()
            guard let inp = enrichInput(job) else { continue }
            let box = WorkEnrichBox()
            let eng = engine
            enrichInFlight = true
            Task.detached {
                do { box.finish(.success(try await eng.run(task: job.task, input: inp.input, maxChars: job.maxChars))) }
                catch { box.finish(.failure(error)) }
            }
            let res = box.wait(deadline.timeIntervalSinceNow) { [weak self] r in
                guard let self = self else { return }
                self.ctx.queue.async {
                    self.enrichInFlight = false
                    self.storeEnrichment(job, source: inp.source, r)
                    self.enrichPending = max(0, self.enrichPending - 1)
                }
            }
            guard let r = res else { enrichPending = jobs.count + 1; return true }
            enrichInFlight = false
            storeEnrichment(job, source: inp.source, r)
            if Date() >= deadline { break }
        }
        enrichPending = jobs.count
        return !jobs.isEmpty
    }

    /// 저장된 Apple 이유 문장 (칩이 그대로일 때만).
    func appleReason(_ t: WorkThreadRow) -> String? {
        let (h, text) = WorkModel.chipHash(t)
        guard !text.isEmpty else { return nil }
        var out: String? = nil
        try? ctx.db.sql.query("SELECT output FROM enrichments WHERE doc_id = ? AND task = 'reason' AND content_hash = ? AND engine = 'apple'",
                              [.text(t.id), .text(h)]) { r in out = r.text(0).isEmpty ? nil : r.text(0) }
        return out
    }
}
