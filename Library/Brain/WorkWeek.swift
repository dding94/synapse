import Foundation

// §5.5 이번 주 (week). offset 0 = 이번 주(월~일), −1 = 지난주. MCP(period week)는 safe = true로 heat를 빼고 쓴다.

extension WorkModel {

    func week(offset: Int) -> [String: Any] { week(offset: offset, safe: false, view: loadView()) }

    func week(offset: Int, safe: Bool, view v: WorkViewData) -> [String: Any] {
        let cal = WorkTime.cal
        let startD = WorkTime.weekStart(now, offset: offset)
        let endD = cal.date(byAdding: .day, value: 7, to: startD)!
        let s = startD.timeIntervalSince1970, e = endD.timeIntervalSince1970
        let nowD = now
        let allTasks = loadTasks()
        let acts = loadActivity(since: s, until: e).filter { $0.actor != "synapse" }
        func label(_ ts: Double) -> String { BrainFormat.whenLabel(Date(timeIntervalSince1970: ts), now: nowD) }
        func day(_ ts: Double) -> String { BrainFormat.dayKey(Date(timeIntervalSince1970: ts)) }   // v0.8: 정리 입력용(매분 바뀌지 않는 날짜)
        func title(_ t: WorkThreadRow) -> String { safe ? safeTitle(t, v) : t.displayTitle }

        // 한 일
        var done: [(Double, [String: Any])] = []
        var jiraTaskDone: [String: Double] = [:]   // v0.7 C: Jira 할 일이 끝난 시각(티켓 규칙의 보조 근거)
        for t in allTasks where t.state == "done" {
            guard let at = t.doneAt else { continue }
            if t.origin == "jira" { jiraTaskDone[t.docId] = max(jiraTaskDone[t.docId] ?? 0, at); continue }
            guard at >= s, at < e else { continue }
            let st = v.states[t.docId]
            done.append((at, ["text": t.origin == "jira" ? (ctx.doc(id: t.docId)?.title ?? t.text) : t.text,
                              "kind": t.origin == "jira" ? "issue" : "task", "docId": t.docId,
                              "line": t.line.map { $0 as Any } ?? NSNull(), "whenLabel": label(at), "day": day(at),
                              "project": st?.project ?? NSNull(), "actorLabel": WorkModel.actorLabel(st?.author).1, "source": "rules"]))
        }
        // v0.7 C: Jira 티켓 — 완료 시각은 statusChanged(K1) → remote_state.changed → 할 일 완료 시각 → meta updated(분류 done일 때) 순
        var closed: [(Double, [String: Any])] = []
        var changes: [String: (Double, [String: Any])] = [:]
        func statusName(_ x: String?) -> String { (x ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespacesAndNewlines)) }
        var statusRows: [String: (Double, String?, String?)] = [:]   // docId → 그 주의 마지막 status 활동 (시각, from, to)
        try? ctx.db.sql.query("SELECT ts, doc_id, detail FROM activity WHERE kind='status' AND ts >= ? AND ts < ? AND doc_id IS NOT NULL ORDER BY ts",
                              [.double(s), .double(e)]) { r in
            let o = r.isNull(2) ? nil : BrainFormat.parse(r.text(2)) as? [String: Any]
            statusRows[r.text(1)] = (r.double(0), o?["from"] as? String, o?["to"] as? String)
        }
        for r in v.remote.values {
            guard let d = ctx.doc(id: r.docId) else { continue }
            let meta = d.meta
            let group = Views.statusGroup(name: meta["status"] ?? r.status, category: meta["statusCategory"] ?? r.statusCat)
            let mine = r.mine || meta["mine"] == "1"
            let key = r.key
            var base: [String: Any] = ["text": d.title, "title": d.title, "kind": "issue", "docId": r.docId, "key": key, "line": NSNull(),
                                       "project": v.states[r.docId]?.project ?? NSNull(), "actorLabel": NSNull(), "source": "rules",
                                       "status": statusName(meta["status"] ?? r.status), "statusGroup": group, "mine": mine]
            if let n = meta["assigneeName"], !n.isEmpty { base["assigneeName"] = n }
            let changedAt = WorkWeekTime.parse(meta["statusChanged"])
            if group == "done" || group == "dropped" {
                var at: Double? = nil, basis = "changed"
                if let c = changedAt { at = c } else if let c = r.changed { at = c } else if let c = jiraTaskDone[r.docId] { at = c }
                else if let u = WorkWeekTime.parse(meta["updated"]) { at = u; basis = "updated" }
                guard let t = at, t >= s, t < e else { continue }
                base["whenLabel"] = label(t)
                base["day"] = day(t)
                if basis == "updated" { base["basis"] = "updated" }
                if group == "done" { done.append((t, base)) } else { closed.append((t, base)) }
            } else {
                // 끝나지 않은 티켓: 그 주에 상태가 바뀌었는지 (status 활동 → 분류가 바뀐 시각)
                var when: Double? = nil, from: String? = nil, to: String? = nil
                if let a = statusRows[r.docId] { when = a.0; from = a.1; to = a.2 }
                if let c = changedAt, c >= s, c < e, when == nil || c > when! { when = c; from = nil; to = nil }
                guard let t = when else { continue }
                base["whenLabel"] = label(t)
                base["day"] = day(t)
                let toName = statusName(to ?? meta["status"] ?? r.status)
                base["to"] = toName
                let gl = ["todo": "할 일", "doing": "진행 중", "blocked": "막힘", "done": "완료", "dropped": "닫힘"]
                let toG = to == nil ? group : Views.statusGroup(name: toName, category: "")
                var toLabel = gl[toG] ?? toName
                if let f = from {
                    let fromName = statusName(f), fromG = Views.statusGroup(name: fromName, category: "")
                    base["from"] = fromName
                    // 묶음이 다르면 "할 일 → 진행 중", 같은 묶음 안의 이동(Backlog → To Do)이면 원래 이름을 쓴다
                    if fromG != toG { base["fromLabel"] = gl[fromG] ?? fromName } else { base["fromLabel"] = fromName; toLabel = toName }
                }
                base["toLabel"] = toLabel
                changes[r.docId] = (t, base)
            }
        }
        for st in v.states.values where st.type == "ADR" || st.type == "TN" {
            guard let fs = st.firstSeen, fs >= s, fs < e, !st.excluded, let d = ctx.doc(id: st.id) else { continue }
            done.append((fs, ["text": d.title, "kind": "doc", "docId": st.id, "line": NSNull(), "whenLabel": label(fs), "day": day(fs),
                              "docType": st.type ?? NSNull(),
                              "project": st.project ?? NSNull(), "actorLabel": WorkModel.actorLabel(st.author).1, "source": "rules"]))
        }
        // 내 티켓을 앞에 둔다(시각순은 그 안에서)
        func order(_ l: [(Double, [String: Any])]) -> [[String: Any]] {
            l.sorted { a, b in
                let x = (a.1["mine"] as? Bool) == true, y = (b.1["mine"] as? Bool) == true
                return x != y ? x : (a.0 != b.0 ? a.0 < b.0 : (a.1["docId"] as? String ?? "") < (b.1["docId"] as? String ?? ""))
            }.map { $0.1 }
        }
        let doneList = order(done)
        let closedList = order(closed)
        let changeList = order(Array(changes.values))

        // 진행 중 · 띠
        var byDoc: [String: [WorkActivity]] = [:], bySession: [String: [WorkActivity]] = [:]
        for a in acts {
            if let d = a.docId { byDoc[d, default: []].append(a) }
            if a.kind == "ask", let sid = a.sessionId { bySession[sid, default: []].append(a) }
        }
        let doneInRange = allTasks.filter { $0.state == "done" && ($0.doneAt ?? 0) >= s && ($0.doneAt ?? 0) < e }
        var progress: [[String: Any]] = []
        var heatRows: [(Int, [String: Any])] = []
        for t in v.threads {
            let items = t.docIds.flatMap { byDoc[$0] ?? [] } + t.sessionIds.flatMap { bySession[$0] ?? [] }
            if items.isEmpty { continue }
            let docs = Set(t.docIds)
            let last = items.map { $0.ts }.max()!
            var p: [String: Any] = ["threadId": "thread:\(t.id)", "title": title(t),
                                    "doneThisWeek": doneInRange.filter { docs.contains($0.docId) }.count,
                                    "open": t.docIds.reduce(0) { $0 + (v.tasksByDoc[$1]?.count ?? 0) }, "lastLabel": label(last),
                                    "code": t.isCode, "origin": t.primaryDoc.flatMap { ctx.doc(id: $0) }.map { WorkModel.origin($0) } ?? "",   // v0.7 FIX2: MCP 글의 종류 표시용
                                    "chips": t.reasons.filter { $0["neg"] == nil }.prefix(3).map {
                                        ["text": $0["text"] ?? "", "kind": $0["kind"] ?? "", "source": $0["source"] ?? "rules"] }]
            p["lastDay"] = day(last)                       // v0.8: 정리 입력용(매분 바뀌지 않는 날짜)
            p["docId"] = t.primaryDoc ?? NSNull()          // v0.8: 정리 참조가 열 대표 문서
            progress.append(p)
            var counts = [Int](repeating: 0, count: 7)
            for a in items where WorkModel.isHuman(a.actor) && a.kind != "status" {
                let i = Int((a.ts - s) / 86400)
                if i >= 0 && i < 7 { counts[i] += 1 }
            }
            let total = counts.reduce(0, +)
            if total > 0 { heatRows.append((total, ["threadId": "thread:\(t.id)", "title": title(t), "counts": counts])) }
        }

        // 다음
        let score = Dictionary(v.threads.map { ($0.id, $0.score) }, uniquingKeysWith: { a, _ in a })
        let nextList: [[String: Any]] = v.open.filter { t in
            if let st = v.states[t.docId], st.excluded || st.archived || st.aiArchive { return false }
            return true
        }.sorted { a, b in
            let x = a.due.flatMap { WorkTime.daysUntil($0, now: nowD) } ?? 9999, y = b.due.flatMap { WorkTime.daysUntil($0, now: nowD) } ?? 9999
            if x != y { return x < y }
            let p = v.threadOfDoc[a.docId].flatMap { score[$0] } ?? -1, q = v.threadOfDoc[b.docId].flatMap { score[$0] } ?? -1
            return p != q ? p > q : a.id < b.id
        }.prefix(7).map { t in
            let n = t.due.flatMap { WorkTime.daysUntil($0, now: nowD) }
            return ["text": WorkText.plain(t.text), "docId": t.docId, "line": t.line.map { $0 as Any } ?? NSNull(), "due": t.due ?? NSNull(),
                    "dueLabel": n.map { WorkTime.dueLabel($0) as Any } ?? NSNull(), "project": v.states[t.docId]?.project ?? NSNull()]
        }

        // 누락 의심: 사람이 30줄 넘게 고쳤는데 할 일 변화가 없다
        var lines: [String: (Int, Double)] = [:]
        for a in acts where WorkModel.isHuman(a.actor) && WorkModel.editKinds.contains(a.kind) {
            guard let d = a.docId else { continue }
            let cur = lines[d] ?? (0, 0)
            lines[d] = (cur.0 + a.lines, max(cur.1, a.ts))
        }
        let taskChanged = Set(allTasks.filter { t in
            (t.firstSeen.map { $0 >= s && $0 < e } ?? false) || (t.doneAt.map { $0 >= s && $0 < e } ?? false)
        }.map { $0.docId })
        let missing: [[String: Any]] = lines.filter { $0.value.0 > 30 && !taskChanged.contains($0.key) }
            .sorted { $0.value.0 != $1.value.0 ? $0.value.0 > $1.value.0 : $0.key < $1.key }
            .compactMap { kv in
                guard let d = ctx.doc(id: kv.key), let st = v.states[kv.key], !(st.excluded || st.aiArchive) else { return nil }
                return ["docId": kv.key, "title": d.title, "lines": kv.value.0, "whenLabel": label(kv.value.1), "day": day(kv.value.1)]
            }.prefix(5).map { $0 }

        // 지난주 계획: 지난주에 바뀐 주간보고의 "다음 주" 줄
        let ps = s - 7 * 86400
        var reportDocs = Set(v.states.values.filter { $0.type == "주간보고" && ($0.lastChange.map { $0 >= ps && $0 < s } ?? false) }.map { $0.id })
        for a in loadActivity(since: ps, until: s) where WorkModel.editKinds.contains(a.kind) {
            if let d = a.docId, v.states[d]?.type == "주간보고" { reportDocs.insert(d) }
        }
        var lastPlan: [[String: Any]] = []
        for id in reportDocs.sorted() {
            guard let d = ctx.doc(id: id) else { continue }
            var underNext = false   // "다음 주" 제목 아래 글머리표도 계획으로 본다
            for l in rawText(d, maxChars: 60_000).components(separatedBy: "\n") where lastPlan.count < 5 {
                let mentions = l.contains("다음 주") || l.contains("다음주")
                if WorkRules.isHeading(l) != nil { underNext = mentions; continue }
                let isItem = l.range(of: #"^\s*(?:[-*+]|\d+[.)])\s+"#, options: .regularExpression) != nil
                guard mentions || (underNext && isItem) else { continue }
                let t = WorkRules.stripListMarker(l)
                if !t.isEmpty { lastPlan.append(["text": WorkUtil.prefix(t, 120), "docId": id]) }
            }
        }

        let heat = heatRows.sorted { $0.0 > $1.0 }.prefix(8).map { $0.1 }
        var copy = ["[한 일]"]
        func ticketLine(_ x: [String: Any], _ tail: String) -> String {
            let text = x["text"] as? String ?? ""
            guard let key = x["key"] as? String, !key.isEmpty else { return "- \(text)" }
            return "- \(WorkWeekTime.keyed(key, text))\(tail)"
        }
        copy += doneList.isEmpty ? ["- 없음"] : doneList.map { x in
            x["kind"] as? String == "issue" && x["key"] != nil ? ticketLine(x, " (완료)") : "- \(x["text"] as? String ?? "")"
        }
        if !changeList.isEmpty {
            copy.append("[상태 변경]")
            copy += changeList.map { x in
                let to = x["toLabel"] as? String ?? "", from = x["fromLabel"] as? String
                return ticketLine(x, " (" + (from.map { "\($0) → " } ?? "→ ") + to + ")")
            }
        }
        copy.append("[진행 중]")
        copy += progress.isEmpty ? ["- 없음"] : progress.map { p in
            let n = p["open"] as? Int ?? 0
            return "- \(p["title"] as? String ?? "")" + (n > 0 ? " (열린 할 일 \(n))" : "")
        }
        copy.append("[다음]")
        copy += nextList.isEmpty ? ["- 없음"] : nextList.map { n in
            "- \(n["text"] as? String ?? "")" + ((n["due"] as? String).map { " (기한 \(WorkTime.md($0)))" } ?? "")
        }
        let endDay = cal.date(byAdding: .day, value: 6, to: startD)!
        func md(_ d: Date) -> String { "\(cal.component(.month, from: d))/\(cal.component(.day, from: d))" }
        return [
            "range": ["start": BrainFormat.dayKey(startD), "end": BrainFormat.dayKey(endDay), "label": "\(md(startD))~\(md(endDay))"],
            "done": doneList, "closed": closedList, "changes": changeList, "progress": progress, "next": nextList, "missing": missing, "lastPlan": lastPlan,
            "heat": ["days": ["월", "화", "수", "목", "금", "토", "일"], "rows": heat],
            "copyText": copy.joined(separator: "\n"),
        ]
    }
}


/// v0.7 C: 주간 보고용 시각·문구 도우미.
enum WorkWeekTime {
    /// ISO8601(소수 초·시간대 표기 달라도) → epoch 초
    static func parse(_ s: String?) -> Double? {
        guard let s = s, !s.isEmpty else { return nil }
        if let d = BrainFormat.isoFormatter.date(from: s) { return d.timeIntervalSince1970 }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d.timeIntervalSince1970 }
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ"] {
            let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = fmt
            if let d = df.date(from: s) { return d.timeIntervalSince1970 }
        }
        return nil
    }
    /// "PROJ-1 · 제목"처럼 이미 키가 앞에 있으면 두 번 쓰지 않는다 → "PROJ-1 제목"
    static func keyed(_ key: String, _ title: String) -> String {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix(key) else { return "\(key) \(t)" }
        let rest = t.dropFirst(key.count).drop(while: { $0 == " " || $0 == "·" || $0 == ":" || $0 == "-" || $0 == "–" })
        return rest.isEmpty ? key : "\(key) \(rest)"
    }
}
