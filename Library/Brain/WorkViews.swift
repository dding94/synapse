import Foundation

// §5.3 홈 JSON과 Item. 저장된 threads·doc_state·tasks·ai_sessions만 읽는다(계산 없음, 100ms 목표).

/// 화면 하나를 그릴 때 한 번 읽는 값.
struct WorkViewData {
    let threads: [WorkThreadRow]
    let states: [String: WorkDocState]
    let open: [WorkTask]
    let tasksByDoc: [String: [WorkTask]]
    let remote: [String: WorkRemote]
    let sessions: [String: WorkSession]
    let outputs: [String: Int]               // 세션 id → AI가 쓴 파일 수
    let threadOfDoc: [String: String]        // 문서 id → 흐름 id
}

extension WorkModel {

    func loadView() -> WorkViewData {
        let threads = loadThreads()
        let open = loadTasks(openOnly: true)
        var sessions: [String: WorkSession] = [:]
        var outputs: [String: Int] = [:]
        let ids = Set(threads.flatMap { $0.sessionIds })
        if sessionsOn && !ids.isEmpty {
            for s in loadSessions(since: 0, ids: ids, withWrites: false) { sessions[s.id] = s }
            try? ctx.db.sql.query("SELECT session_id, count(DISTINCT path) FROM ai_writes GROUP BY session_id") { r in
                if ids.contains(r.text(0)) { outputs[r.text(0)] = Int(r.int(1)) }
            }
        }
        var threadOfDoc: [String: String] = [:]
        for t in threads { for d in t.docIds where threadOfDoc[d] == nil { threadOfDoc[d] = t.id } }
        return WorkViewData(threads: threads, states: loadDocStates(), open: open,
                            tasksByDoc: Dictionary(grouping: open, by: { $0.docId }), remote: loadRemote(),
                            sessions: sessions, outputs: outputs, threadOfDoc: threadOfDoc)
    }

    static func actorLabel(_ a: String?) -> (Any, Any) {
        switch a {
        case "human": return ("human", "내가 수정")
        case "claude": return ("claude", "Claude가 작성")
        case "codex": return ("codex", "Codex가 작성")
        case "mixed": return ("mixed", "함께 작성")
        default: return (NSNull(), NSNull())
        }
    }

    static func origin(_ d: BrainDoc?) -> String {
        switch d?.kind { case "jira": return "jira"; case "confluence": return "confluence"; default: return "local" }
    }

    func docRef(_ id: String?) -> Any {
        guard let id = id, let d = ctx.doc(id: id) else { return NSNull() }
        return ["id": id, "title": d.title, "path": d.relPath, "origin": WorkModel.origin(d)]
    }

    /// MCP·지시문용 이름: 세션 제목·요청 문장에서 온 이름은 쓰지 않는다.
    func safeTitle(_ t: WorkThreadRow, _ v: WorkViewData) -> String {
        if let u = t.userTitle, !u.isEmpty { return u }
        if t.isCode {
            let body = t.key.dropFirst(5)
            let parts = body.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let repo = parts.first ?? "", branch = parts.count > 1 ? parts[1] : ""
            return branch.isEmpty ? repo : "\(repo) · \(branch)"
        }
        if t.isSession {
            return t.project ?? t.primaryDoc.flatMap { ctx.doc(id: $0)?.title } ?? "작업"
        }
        return t.title
    }

    /// 흐름 안 가장 이른 열린 기한(지난 지 30일 넘은 것은 뺀다).
    func earliestDue(docIds: [String], keys: [String], _ v: WorkViewData) -> (String, Int)? {
        var best: (String, Int)? = nil
        func consider(_ due: String?) {
            guard let due = due, let n = WorkTime.daysUntil(due, now: now), n >= -30 else { return }
            if best == nil || n < best!.1 { best = (due, n) }
        }
        for d in docIds { for t in v.tasksByDoc[d] ?? [] { consider(t.due) } }
        for k in keys { if let r = v.remote[k], r.mine, r.statusCat != "done" { consider(r.due) } }
        return best
    }

    func threadItem(_ t: WorkThreadRow, _ v: WorkViewData, safe: Bool) -> [String: Any]? {
        let chipsRaw = t.reasons.filter { $0["neg"] == nil }.prefix(3)
        if chipsRaw.isEmpty { return nil }
        let chips: [[String: Any]] = chipsRaw.map { ["text": $0["text"] ?? "", "kind": $0["kind"] ?? "", "source": $0["source"] ?? "rules"] }
        let p = t.primaryDoc.flatMap { v.states[$0] }
        let (actor, actorLabel) = WorkModel.actorLabel(p?.author)
        let nowD = now
        var keys = t.issueKeys
        for d in t.docIds { if let k = ctx.doc(id: d).flatMap({ WorkModel.jiraKey($0) }), !keys.contains(k) { keys.append(k) } }
        let due = earliestDue(docIds: t.docIds, keys: keys, v)
        let openN = t.docIds.reduce(0) { $0 + (v.tasksByDoc[$1]?.count ?? 0) }
        let doneN = t.docIds.reduce(0) { $0 + (v.states[$1]?.doneTasks ?? 0) }
        let sess = t.sessionIds.compactMap { v.sessions[$0] }
        var lastAsk: Any = NSNull()
        if let s = sess.filter({ $0.lastAskTs != nil }).max(by: { $0.lastAskTs! < $1.lastAskTs! }), let at = s.lastAskTs {
            let outs = v.outputs[s.id] ?? 0
            if safe {
                lastAsk = ["tool": s.tool, "atLabel": WorkTime.atLabel(at, now: nowD), "outputs": outs]
            } else {
                lastAsk = ["tool": s.tool, "text": requestTextOn ? (s.lastAsk ?? s.firstAsk).map { $0 as Any } ?? NSNull() : NSNull(),
                           "at": BrainFormat.iso(Date(timeIntervalSince1970: at)), "atLabel": WorkTime.atLabel(at, now: nowD), "outputs": outs]
            }
        }
        var code: Any = NSNull()
        if t.isCode {
            let parts = t.key.dropFirst(5).split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let latest = sess.max { $0.lastTs < $1.lastTs }
            var c: [String: Any] = ["repo": parts.first ?? "", "branch": parts.count > 1 ? parts[1] : ""]
            if !safe { c["cwd"] = latest?.cwd ?? "" }
            code = c
        }
        let outputs: [[String: Any]] = t.docIds.compactMap { id -> (Double, [String: Any])? in
            guard let s = v.states[id], s.author == "claude" || s.author == "codex", let d = ctx.doc(id: id) else { return nil }
            return (s.lastAI ?? s.lastChange ?? 0, ["docId": id, "title": d.title])
        }.sorted { $0.0 > $1.0 }.prefix(5).map { $0.1 }
        let usesApple = p?.summarySource == "apple" || chips.contains { ($0["source"] as? String) == "apple" }
        var item: [String: Any] = [
            "id": "thread:\(t.id)", "kind": "thread",
            "title": safe ? safeTitle(t, v) : t.displayTitle,
            "docId": t.primaryDoc ?? NSNull(), "line": p?.stoppedLine.map { $0 as Any } ?? NSNull(),
            "tier": t.tier.rawValue,
            "when": t.lastHuman.map { BrainFormat.iso(Date(timeIntervalSince1970: $0)) as Any } ?? NSNull(),
            "whenLabel": t.lastHuman.map { BrainFormat.whenLabel(Date(timeIntervalSince1970: $0), now: nowD) as Any } ?? NSNull(),
            "actor": actor, "actorLabel": actorLabel,
            "stopped": p?.stoppedLine.map { ["heading": p?.stoppedHeading.map { $0 as Any } ?? NSNull(), "line": $0] as Any } ?? NSNull(),
            "openTasks": openN, "doneTasks": doneN,
            "due": due.map { $0.0 as Any } ?? NSNull(), "dueLabel": due.map { WorkTime.dueLabel($0.1) as Any } ?? NSNull(),
            "lastAsk": lastAsk,
            "project": t.project ?? NSNull(), "type": p?.type ?? NSNull(),
            "chips": chips, "source": usesApple ? "apple" : "rules", "pinned": t.pinned,
            "summary": p?.summary ?? NSNull(), "summarySource": p?.summarySource ?? NSNull(),
            "code": code, "outputs": outputs,
        ]
        if safe {
            let pd = t.primaryDoc.flatMap { ctx.doc(id: $0) }
            item["origin"] = WorkModel.origin(pd)
            if pd.map({ WorkModel.isRemote($0) }) ?? false { item["summary"] = NSNull(); item["summarySource"] = NSNull() }   // 이중 방어
        } else {
            item["sessionTitle"] = sess.sorted { $0.lastTs > $1.lastTs }.first { $0.title != nil }?.title ?? NSNull()
            if let r = appleReason(t) { item["reason"] = r }
        }
        return item
    }

    /// 급한 할 일 후보 (기한 3일 안·지남, 내 Jira Highest). 덜 중요 흐름의 할 일은 뺀다.
    func urgentTasks(_ v: WorkViewData) -> [(WorkTask, Int?)] {
        let nowT = nowTS
        let demoted = Set(v.threads.filter { ($0.demotedUntil ?? 0) > nowT }.map { $0.id })
        var out: [(WorkTask, Int?)] = []
        for t in v.open {
            if let s = v.states[t.docId], s.excluded || s.archived || s.aiArchive { continue }
            if let tid = v.threadOfDoc[t.docId], demoted.contains(tid) { continue }
            let n = t.due.flatMap { WorkTime.daysUntil($0, now: now) }
            let dueHit = n.map { $0 <= 3 && $0 >= -30 } ?? false
            let highest = t.origin == "jira" && effectivePrio(t, v) == "highest"
            if dueHit || highest { out.append((t, dueHit ? n : nil)) }
        }
        return out.sorted {
            let a = $0.1 ?? 99, b = $1.1 ?? 99
            if a != b { return a < b }
            let pa = effectivePrio($0.0, v) == "highest" ? 0 : 1, pb = effectivePrio($1.0, v) == "highest" ? 0 : 1
            return pa != pb ? pa < pb : $0.0.id < $1.0.id
        }
    }

    /// Jira 할 일의 우선순위: 저장값이 없으면(예전 색인) 원격 상태의 한국어·영어 우선순위 이름에서 읽는다.
    func effectivePrio(_ t: WorkTask, _ v: WorkViewData) -> String? {
        if t.origin != "jira" { return t.prio }
        if let p = t.prio { return p }
        return ctx.doc(id: t.docId).flatMap { WorkModel.jiraKey($0) }.flatMap { v.remote[$0] }.flatMap { WorkText.jiraPrio($0.priority) }
    }

    func taskItem(_ t: WorkTask, days: Int?, _ v: WorkViewData, safe: Bool, scope: WorkScopeTable? = nil) -> [String: Any] {
        let d = ctx.doc(id: t.docId), s = v.states[t.docId]
        let jira = t.origin == "jira"
        let prio = effectivePrio(t, v)
        let (actor, actorLabel) = WorkModel.actorLabel(s?.author)
        var chips: [[String: Any]] = []
        if let n = days { chips.append(["text": WorkTime.dueLabel(n), "kind": "due", "source": "rules"]) }
        if jira {
            if prio == "highest" { chips.append(["text": "Highest", "kind": "jira", "source": "rules"]) }
            else if prio == "high" { chips.append(["text": "High", "kind": "jira", "source": "rules"]) }
            chips.append(["text": "내 담당", "kind": "jira", "source": "rules"])
        } else {
            if t.prio == "highest" { chips.append(["text": "긴급", "kind": "task", "source": "rules"]) }
            chips.append(["text": d.map { "\($0.title)의 할 일" } ?? "할 일", "kind": "task", "source": "rules"])
        }
        let title = WorkText.plain(jira ? (d?.title ?? t.text) : t.text)   // 표시용: 마크다운 기호를 뺀다
        var item: [String: Any] = [
            "id": "task:\(t.id)", "kind": jira ? "issue" : "task", "title": title,
            "docId": d != nil ? t.docId : NSNull(), "line": t.line.map { $0 as Any } ?? NSNull(), "tier": "now",
            "when": s?.lastHuman.map { BrainFormat.iso(Date(timeIntervalSince1970: $0)) as Any } ?? NSNull(),
            "whenLabel": s?.lastHuman.map { BrainFormat.whenLabel(Date(timeIntervalSince1970: $0), now: now) as Any } ?? NSNull(),
            "actor": actor, "actorLabel": actorLabel, "stopped": NSNull(),
            "openTasks": v.tasksByDoc[t.docId]?.count ?? 0, "doneTasks": s?.doneTasks ?? 0,
            "due": t.due ?? NSNull(), "dueLabel": days.map { WorkTime.dueLabel($0) as Any } ?? NSNull(),
            "lastAsk": NSNull(), "project": s?.project ?? NSNull(), "type": s?.type ?? NSNull(),
            "chips": Array(chips.prefix(3)), "source": "rules", "pinned": false,
            "summary": s?.summary ?? NSNull(), "summarySource": s?.summarySource ?? NSNull(),
            "code": NSNull(), "outputs": [] as [Any],
        ]
        if safe {
            item["origin"] = WorkModel.origin(d)
            if d.map({ WorkModel.isRemote($0) }) ?? true { item["summary"] = NSNull(); item["summarySource"] = NSNull() }
        } else { item["sessionTitle"] = NSNull() }
        if let sc = scope { item.merge(scopeFields(t.docId, sc)) { _, new in new } }
        return item
    }

    /// home·workContext(now) 공통: urgent · current · next · dormant.
    func homeParts(_ v: WorkViewData, safe: Bool) -> (urgent: [[String: Any]], current: [String: Any]?, next: [[String: Any]],
                                                       dormant: [[String: Any]], dormantCount: Int) {
        let scopes = scopeTable(v)
        let urgentT = pickUrgent(urgentTasks(v), scopes)   // v0.7: 최대 12개, 업무 먼저. 화면이 3줄까지만 먼저 보인다
        let urgent = urgentT.map { taskItem($0.0, days: $0.1, v, safe: safe, scope: scopes) }
        // 같은 문서·같은 줄이 urgent와 겹치고 더 줄 정보(요청·산출물)가 없는 흐름 줄만 뺀다
        let urgentSpots = Set(urgent.map { "\($0["docId"] ?? "")|\($0["line"] ?? "")" })
        func duplicate(_ it: [String: Any]) -> Bool {
            guard urgentSpots.contains("\(it["docId"] ?? "")|\(it["line"] ?? "")") else { return false }
            return it["lastAsk"] is NSNull && ((it["outputs"] as? [Any])?.isEmpty ?? true)
        }
        let nowT = nowTS
        let live = v.threads.filter { $0.tier != .dormant }
        var current: [String: Any]? = nil, currentID: String? = nil
        let recent = live.filter { ($0.lastHuman ?? 0) >= nowT - 12 * 3600 }.sorted { ($0.lastHuman ?? 0) > ($1.lastHuman ?? 0) }
        let ranked = live.filter { $0.tier == .now || $0.tier == .week }.sorted { $0.score > $1.score }
        for t in recent + ranked { if let it = threadItem(t, v, safe: safe) { current = it; currentID = t.id; break } }
        var next: [[String: Any]] = []
        let order = live.filter { $0.id != currentID }
            .sorted { $0.pinned != $1.pinned ? $0.pinned : ($0.score != $1.score ? $0.score > $1.score : $0.id < $1.id) }
        for t in order where next.count < 3 { if let it = threadItem(t, v, safe: safe), !duplicate(it) { next.append(it) } }
        let sleeping = v.threads.filter { $0.tier == .dormant }.sorted { ($0.lastHuman ?? 0) > ($1.lastHuman ?? 0) }
        let dormant = sleeping.compactMap { threadItem($0, v, safe: safe) }
        return (urgent, current, next, Array(dormant.prefix(5)), dormant.count)
    }

    func home() -> [String: Any] {
        let v = loadView()
        let parts = homeParts(v, safe: false)
        let nowT = nowTS
        let old = v.open.filter { t in t.origin != "jira" && (v.states[t.docId]?.lastChange ?? nowT) < nowT - 60 * 86400 }.count
        var newDocs = 0, inPlace = 0
        let today = WorkTime.cal.startOfDay(for: now).timeIntervalSince1970
        try? ctx.db.sql.query("SELECT kind, count(*) FROM ai_log WHERE ts >= ? AND kind IN ('check','inPlace') GROUP BY kind",
                              [.double(today)]) { r in
            if r.text(0) == "check" { newDocs = Int(r.int(1)) } else { inPlace = Int(r.int(1)) }
        }
        let st = engineStatus()
        let batch = BrainFormat.date(ctx.db.setting(BrainSetting.organizerLastBatch))
        let enabledRaw = ctx.db.setting(BrainSetting.sessionsEnabled)
        let enabled: Any = enabledRaw == nil ? NSNull() : (enabledRaw == "1")
        let fm = FileManager.default
        let hasDirs = [ctx.env.claudeDir, ctx.env.codexDir].contains { $0.map { fm.fileExists(atPath: $0.path) } ?? false }
        return [
            "generatedAt": BrainFormat.iso(now),
            "urgent": parts.urgent,
            "urgentFilter": urgentFilter(parts.urgent),
            "current": parts.current ?? NSNull(),
            "next": parts.next,
            "dormant": ["count": parts.dormantCount, "items": parts.dormant],
            "oldTasks": old,
            "librarian": ["newDocs": newDocs, "inPlace": inPlace, "pending": pendingTotal(),
                          "engine": st.0 == "ready" ? "apple" : "rules", "engineLabel": st.0 == "ready" ? "기기 AI" : "규칙",
                          "stopped": ctx.isStopped,
                          "lastBatchLabel": batch.map { WorkTime.dayTime($0.timeIntervalSince1970, now: now) as Any } ?? NSNull()],
            "sessions": ["enabled": enabled, "askCard": enabledRaw == nil && hasDirs],
            "tickets": ticketCounts(),
            "empty": parts.urgent.isEmpty && parts.current == nil && parts.next.isEmpty && parts.dormantCount == 0,
        ]
    }

    func pendingTotal() -> Int {
        if let f = pendingCount { return f() }
        var n = 0
        try? ctx.db.sql.query("SELECT count(*) FROM suggestions WHERE state='pending'") { n = Int($0.int(0)) }
        return n
    }
}
