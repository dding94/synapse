import Foundation

// §5.2 점수·바닥 규칙·단계·교정·이유 칩. refresh(changed:)가 흐름을 다시 묶고 점수를 매겨 threads에 저장한다.

enum WorkTime {
    static var cal: Calendar { Calendar.current }

    static func parseDay(_ s: String) -> Date? {
        let p = s.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }
    /// 오늘부터 기한까지 남은 날 수(지남은 음수).
    static func daysUntil(_ due: String, now: Date) -> Int? {
        guard let d = parseDay(due) else { return nil }
        return cal.dateComponents([.day], from: cal.startOfDay(for: now), to: d).day
    }
    static func dueLabel(_ days: Int) -> String {
        if days < 0 { return "기한 지남" }
        if days == 0 { return "기한 오늘" }
        if days == 1 { return "기한 내일" }
        return "기한 D-\(days)"
    }
    static func hm(_ d: Date) -> String {
        String(format: "%02d:%02d", cal.component(.hour, from: d), cal.component(.minute, from: d))
    }
    /// 칩용 날: 오늘 · 어제 · N일 전 · M/D
    static func relDay(_ ts: Double, now: Date) -> String {
        let d = Date(timeIntervalSince1970: ts)
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: now)).day ?? 99
        if days <= 0 { return "오늘" }
        if days == 1 { return "어제" }
        if days < 7 { return "\(days)일 전" }
        return "\(cal.component(.month, from: d))/\(cal.component(.day, from: d))"
    }
    /// 요청 시각: 오늘이면 16:20, 아니면 whenLabel.
    static func atLabel(_ ts: Double, now: Date) -> String {
        let d = Date(timeIntervalSince1970: ts)
        return cal.isDate(d, inSameDayAs: now) ? hm(d) : BrainFormat.whenLabel(d, now: now)
    }
    /// "오늘 12:00" · "어제 12:00" · 그 밖은 whenLabel.
    static func dayTime(_ ts: Double, now: Date) -> String {
        let d = Date(timeIntervalSince1970: ts)
        if cal.isDate(d, inSameDayAs: now) { return "오늘 \(hm(d))" }
        return BrainFormat.whenLabel(d, now: now)
    }
    /// offset 주의 월요일 0시 (0 = 이번 주).
    static func weekStart(_ now: Date, offset: Int) -> Date {
        let day = cal.startOfDay(for: now)
        let wd = cal.component(.weekday, from: day)          // 1 = 일
        let back = (wd + 5) % 7                              // 월 = 0
        let monday = cal.date(byAdding: .day, value: -back, to: day)!
        return cal.date(byAdding: .day, value: 7 * offset, to: monday)!
    }
    static func nextMonday(_ d: Date) -> Date { cal.date(byAdding: .day, value: 7, to: weekStart(d, offset: 0))! }
    static func md(_ s: String) -> String {
        guard let d = parseDay(s) else { return s }
        return "\(cal.component(.month, from: d))/\(cal.component(.day, from: d))"
    }
}

struct WorkSignal {
    var points: Double
    var text: String
    var kind: String
    var source = "rules"
    var detail = ""
    var docId: String? = nil
    var line: Int? = nil
    /// 저장 형식 (threads.reasons). 숫자 점수는 넣지 않고, 깎는 신호만 "neg"로 표시한다.
    var json: [String: Any] {
        var o: [String: Any] = ["text": text, "kind": kind, "source": source, "detail": detail,
                                "docId": docId ?? NSNull(), "line": line.map { $0 as Any } ?? NSNull()]
        if points < 0 { o["neg"] = true }
        return o
    }
}

/// 문서별 30일 활동 집계.
struct WorkDocAgg {
    var lastHumanEdit: Double?
    var lastAIEdit: Double?
    var aiActor: String?
    var lastOpen: Double?
    var opens3d = 0
    var lastAny: Double?
}

struct WorkScored {
    let group: WorkGroup
    var primary: String?
    var signals: [WorkSignal]
    var score: Double
    var floorNow: Bool
    var floorWeek: Bool
    var dueDays: Int?
    var jiraProgress: Bool
    var dormant: Bool
    var pinned: Bool
    var demotedUntil: Double?
    var lastHuman: Double?
    var lastTs: Double?
    var tier: Tier = .none
}

extension WorkModel {
    static let editKinds: Set<String> = ["created", "modified", "edited", "saved"]
    static let openKinds: Set<String> = ["opened", "viewed"]

    static func isHuman(_ a: String) -> Bool { a == "human" || a == "mixed" }
    static func isAI(_ a: String) -> Bool { a == "claude" || a == "codex" || a == "mixed" }
    static func toolName(_ t: String) -> String { t == "codex" ? "Codex" : "Claude" }

    /// 흐름·점수 다시 계산 (§5.1·§5.2). MCP 모드에서는 하지 않는다.
    func refresh(changed: [String]) {
        if ctx.mode == .mcp { return }
        ctx.reloadDocsIfChanged()
        let nowD = now, nowT = nowTS
        let since = nowT - WorkModel.windowDays * 86400
        let states = loadDocStates()
        let acts = loadActivity(since: since)
        let open = loadTasks(openOnly: true)
        let remote = loadRemote()
        let sessions = loadSessions(since: since)
        let fb = loadFeedback()
        let links = incomingLinks()

        // 문서별 집계와 범위
        var agg: [String: WorkDocAgg] = [:]
        var askTS: [String: Double] = [:]
        var humanEdits: [(docId: String, ts: Double)] = []
        for a in acts where a.actor != "synapse" {
            if a.kind == "ask" { if sessionsOn, let s = a.sessionId { askTS[s] = max(askTS[s] ?? 0, a.ts) }; continue }
            guard let d = a.docId else { continue }
            var g = agg[d] ?? WorkDocAgg()
            if WorkModel.editKinds.contains(a.kind) {
                if WorkModel.isHuman(a.actor) { g.lastHumanEdit = max(g.lastHumanEdit ?? 0, a.ts); humanEdits.append((d, a.ts)) }
                if WorkModel.isAI(a.actor) && a.actor != "mixed" { g.lastAIEdit = max(g.lastAIEdit ?? 0, a.ts); g.aiActor = a.actor }
            } else if WorkModel.openKinds.contains(a.kind) && WorkModel.isHuman(a.actor) {
                g.lastOpen = max(g.lastOpen ?? 0, a.ts)
                if nowT - a.ts <= 3 * 86400 { g.opens3d += 1 }
            } else if a.kind != "status" { continue }
            g.lastAny = max(g.lastAny ?? 0, a.ts)
            agg[d] = g
        }
        var activeSet = Set(agg.keys)
        for t in open {
            if let due = t.due, let n = WorkTime.daysUntil(due, now: nowD), n <= 7, n >= -30 { activeSet.insert(t.docId) }
        }
        for r in remote.values where r.mine && r.statusCat != "done" { activeSet.insert(r.docId) }
        let active = activeSet.filter { eligible($0, states) }.sorted()

        var roots: [String] = ctx.vaults.roots   // v0.9 §3.2: 볼트 루트 먼저 (출처가 볼트가 아니어도)
        for r in ctx.localRoots() {
            for p in [r.root.standardizedFileURL.path, Indexer.realPath(r.root.path)] where !roots.contains(p) { roots.append(p) }
        }
        let groups = buildGroups(WorkGroupInput(active: active, states: states, sessions: sessions, humanEdits: humanEdits,
                                                notThisFolder: fb.notThisFolder, vaultRoots: roots, knownIssueKeys: Array(remote.keys)))
        let sessionsByID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let tasksByDoc = Dictionary(grouping: open, by: { $0.docId })
        let mentions = recentPlanDocs(states: states, nowT: nowT)

        var scored: [WorkScored] = []
        for g in groups {
            let tid = g.id
            let primary = g.docIds.max { a, b in
                let x = states[a]?.lastHuman ?? -1, y = states[b]?.lastHuman ?? -1
                if x != y { return x < y }
                let p = states[a]?.lastChange ?? 0, q = states[b]?.lastChange ?? 0
                return p != q ? p < q : a > b
            }
            var sig: [WorkSignal] = []
            // 기한
            var best: (days: Int, due: String, docId: String?, line: Int?, jira: Bool)? = nil
            for d in g.docIds { for t in tasksByDoc[d] ?? [] {
                guard let due = t.due, let n = WorkTime.daysUntil(due, now: nowD), n >= -30 else { continue }
                if best == nil || n < best!.days { best = (n, due, d, t.line, t.origin == "jira") }
            } }
            var keys = g.issueKeys
            for d in g.docIds { if let k = ctx.doc(id: d).flatMap({ WorkModel.jiraKey($0) }), !keys.contains(k) { keys.append(k) } }
            let mineRemote = keys.compactMap { remote[$0] }.filter { $0.mine && $0.statusCat != "done" }
            for r in mineRemote {
                if let due = r.due, let n = WorkTime.daysUntil(due, now: nowD), n >= -30, best == nil || n < best!.days {
                    best = (n, due, r.docId, nil, true)
                }
            }
            if let b = best, b.days <= 7 {
                let detail = b.jira ? "Jira 기한 \(WorkTime.md(b.due))"
                    : "\(ctx.doc(id: b.docId ?? "")?.title ?? "") \(b.line.map { "\($0)행" } ?? "")".trimmingCharacters(in: .whitespaces)
                sig.append(WorkSignal(points: b.days <= 3 ? 30 : 18, text: WorkTime.dueLabel(b.days), kind: "due",
                                      detail: detail, docId: b.docId, line: b.line))
            }
            let progress = mineRemote.first { $0.statusCat == "indeterminate" }
            if let p = progress {
                sig.append(WorkSignal(points: 20, text: "\(p.key) 진행 중", kind: "jira", detail: "Jira 상태 '\(p.status)'", docId: p.docId))
            }
            let highest = mineRemote.contains { $0.priority == "Highest" }
            let high = mineRemote.contains { $0.priority == "High" }
            // 최근 편집
            var hEdit: (Double, String)? = nil, aEdit: (Double, String, String)? = nil, lastOpen: Double? = nil
            var opens = 0, lastAny: Double? = nil, lastHuman: Double? = nil
            for d in g.docIds {
                let a = agg[d] ?? WorkDocAgg()
                if let t = a.lastHumanEdit, t > (hEdit?.0 ?? 0) { hEdit = (t, d) }
                if let t = a.lastAIEdit, t > (aEdit?.0 ?? 0) { aEdit = (t, d, a.aiActor ?? "claude") }
                if let t = a.lastOpen { lastOpen = max(lastOpen ?? 0, t) }
                if let t = states[d]?.lastOpen, nowT - t <= 3 * 86400, a.opens3d == 0 { opens += 1 }
                opens += a.opens3d
                lastAny = [lastAny, a.lastAny].compactMap { $0 }.max()
                lastHuman = [lastHuman, states[d]?.lastHuman, a.lastHumanEdit, a.lastOpen].compactMap { $0 }.max()
            }
            var askLast: (Double, String)? = nil
            for sid in g.sessionIds {
                guard let s = sessionsByID[sid] else { continue }
                if let t = askTS[sid] ?? s.lastAskTs, t > (askLast?.0 ?? 0) { askLast = (t, s.tool) }
                if let w = s.writes.map({ $0.ts }).max(), g.docIds.isEmpty || g.kind == "code", w > (aEdit?.0 ?? 0) {
                    aEdit = (w, "", s.tool)
                }
                lastAny = [lastAny, s.lastTs].compactMap { $0 }.max()
            }
            if let a = askLast { lastHuman = max(lastHuman ?? 0, a.0) }
            if let (t, d) = hEdit {
                let days = (nowT - t) / 86400
                sig.append(WorkSignal(points: 15 * exp(-days / 7), text: "\(WorkTime.relDay(t, now: nowD)) 내가 수정", kind: "activity",
                                      detail: ctx.doc(id: d)?.title ?? "", docId: d, line: states[d]?.stoppedLine))
            } else if let (t, d, who) = aEdit {
                let days = (nowT - t) / 86400
                let n = g.kind == "code" ? g.sessionIds.compactMap { sessionsByID[$0] }.reduce(0) { $0 + Set($1.writes.map { $0.path }).count } : 0
                let text = n > 0 ? "\(WorkModel.toolName(who))가 파일 \(n)개 수정" : "\(WorkTime.relDay(t, now: nowD)) \(WorkModel.toolName(who))가 작성"
                sig.append(WorkSignal(points: 5 * exp(-days / 7), text: text, kind: "activity",
                                      detail: d.isEmpty ? "" : (ctx.doc(id: d)?.title ?? ""), docId: d.isEmpty ? nil : d))
            }
            if let (t, tool) = askLast, nowT - t <= 3 * 86400 {
                sig.append(WorkSignal(points: 10, text: "\(WorkModel.toolName(tool))에게 \(WorkTime.atLabel(t, now: nowD)) 요청", kind: "session",
                                      detail: "\(WorkModel.toolName(tool)) 세션 \(g.sessionIds.count)개"))
            }
            if let m = mentionSignal(g: g, primary: primary, keys: keys, mentions: mentions) { sig.append(m) }
            if opens > 0 {
                let text = opens >= 2 ? "최근 \(opens)번 열람" : "\(WorkTime.relDay(lastOpen ?? nowT, now: nowD)) 열람"
                sig.append(WorkSignal(points: 10, text: text, kind: "open", detail: primary.flatMap { ctx.doc(id: $0)?.title } ?? "",
                                      docId: primary))
            }
            let tasksIn = g.docIds.flatMap { tasksByDoc[$0] ?? [] }.filter { $0.origin != "jira" }
            if !tasksIn.isEmpty {
                let n = Double(tasksIn.count), f = tasksIn[0]
                sig.append(WorkSignal(points: min(10, 3 * log2(1 + n)), text: "할 일 \(tasksIn.count)", kind: "task",
                                      detail: "\(ctx.doc(id: f.docId)?.title ?? "") \(f.line.map { "\($0)행" } ?? "")", docId: f.docId, line: f.line))
            }
            let inMax = g.docIds.map { (links.counts[$0] ?? 0, $0) }.max { $0.0 < $1.0 }
            if let fromSum = g.docIds.first(where: { links.fromSummary.contains($0) }) {
                sig.append(WorkSignal(points: 5, text: "요약에서 링크", kind: "link", detail: "프로젝트_요약에서 링크됨", docId: fromSum))
            } else if let m = inMax, m.0 >= 3 {
                sig.append(WorkSignal(points: 5, text: "링크 \(m.0)", kind: "link", detail: "들어오는 링크 \(m.0)개", docId: m.1))
            }
            let pinned = fb.pinned.contains(tid)
            let demUntil = fb.demoted[tid].flatMap { $0 > nowT ? $0 : nil }
            if pinned { sig.append(WorkSignal(points: 25, text: "항상 위", kind: "pin", detail: "직접 고정했어요")) }
            if demUntil != nil { sig.append(WorkSignal(points: -25, text: "덜 중요", kind: "pin", detail: "직접 덜 중요로 표시했어요")) }
            if let p = primary, states[p]?.archived == true {
                sig.append(WorkSignal(points: -30, text: "보관 폴더", kind: "activity", detail: states[p]?.path ?? "", docId: p))
            }
            let score = max(0, min(100, sig.reduce(0) { $0 + $1.points }))
            var floorNow = (best.map { $0.days <= 3 } ?? false) || highest
            var floorWeek = (best.map { $0.days > 3 && $0.days <= 7 } ?? false) || high
            if demUntil != nil && !(best.map { $0.days <= 0 } ?? false) { floorNow = false; floorWeek = false }
            let ref = [lastHuman, fb.wake[tid]].compactMap { $0 }.max() ?? lastAny ?? 0
            let dormant = nowT - ref > 14 * 86400 && !floorNow && !floorWeek && progress == nil && !pinned
            sig.sort { $0.points != $1.points ? $0.points > $1.points : $0.text < $1.text }
            scored.append(WorkScored(group: g, primary: primary, signals: sig, score: score, floorNow: floorNow, floorWeek: floorWeek,
                                     dueDays: best?.days, jiraProgress: progress != nil, dormant: dormant, pinned: pinned,
                                     demotedUntil: demUntil, lastHuman: lastHuman, lastTs: lastAny ?? lastHuman))
        }
        assignTiers(&scored)
        saveThreads(scored, fb: fb, nowT: nowT)
        fillRuleSummaries(states: states, budget: 0.3)
        enrichPending = enrichQueue(limit: 200).count
    }

    func assignTiers(_ list: inout [WorkScored]) {
        let order = list.indices.sorted { list[$0].score != list[$1].score ? list[$0].score > list[$1].score : list[$0].group.key < list[$1].group.key }
        var top = 0
        for i in order {
            if list[i].floorNow { list[i].tier = .now; continue }
            if list[i].dormant { list[i].tier = .dormant; continue }
            if list[i].score >= 60 {
                list[i].tier = top < 3 ? .now : .week; top += 1; continue
            }
            if list[i].score >= 30 || list[i].floorWeek || (list[i].dueDays.map { $0 <= 7 } ?? false) { list[i].tier = .week; continue }
            list[i].tier = .none
        }
    }

    func saveThreads(_ list: [WorkScored], fb: WorkFeedback, nowT: Double) {
        let kept = list.sorted {
            let a = ($0.floorNow || $0.pinned) ? 1 : 0, b = ($1.floorNow || $1.pinned) ? 1 : 0
            if a != b { return a > b }
            return $0.score != $1.score ? $0.score > $1.score : $0.group.key < $1.group.key
        }.prefix(WorkModel.maxThreads)
        try? ctx.db.sql.transaction {
            try ctx.db.sql.run("DELETE FROM threads")
            for s in kept {
                let g = s.group
                try ctx.db.sql.run("""
                INSERT OR REPLACE INTO threads(id, key, title, user_title, project, doc_ids, issue_keys, session_ids, primary_doc,
                  last_human, last_ts, score, tier, reasons, pinned, demoted_until, updated) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, [.text(g.id), .text(g.key), .text(g.title), fb.rename[g.id].map { .text($0) } ?? .null,
                      g.project.map { .text($0) } ?? .null, .text(BrainFormat.json(g.docIds)), .text(BrainFormat.json(g.issueKeys)),
                      .text(BrainFormat.json(g.sessionIds)), s.primary.map { .text($0) } ?? .null,
                      s.lastHuman.map { .double($0) } ?? .null, s.lastTs.map { .double($0) } ?? .null, .double(s.score),
                      .text(s.tier.rawValue), .text(BrainFormat.json(s.signals.prefix(8).map { $0.json })),
                      .int(s.pinned ? 1 : 0), s.demotedUntil.map { .double($0) } ?? .null, .double(nowT)])
            }
        }
    }
}
