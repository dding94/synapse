import Foundation

// §5.4 왜? · 교정(feedback) · §5.6 지도 · §5.7 작업 맥락(MCP) · §5.8 Claude 지시문 · 문서 이동 반영.

extension WorkModel {

    static let tierLabels: [Tier: String] = [.now: "지금", .week: "이번 주", .dormant: "잠듦", .none: ""]
    static let actionLabels = ["pin": "항상 위", "unpin": "고정 풀기", "demote": "덜 중요", "wake": "깨우기", "rename": "이름 바꾸기"]

    static func action(_ id: String) -> [String: Any] { ["id": id, "label": actionLabels[id] ?? id] }

    func why(id: String) -> [String: Any] {
        let v = loadView()
        if id.hasPrefix("task:") {
            let tid = String(id.dropFirst(5))
            guard let t = v.open.first(where: { $0.id == tid }) ?? loadTasks().first(where: { $0.id == tid }) else {
                return ["ok": false, "error": "항목을 찾지 못했어요"]
            }
            let d = ctx.doc(id: t.docId)
            var reasons: [[String: Any]] = []
            if let due = t.due, let n = WorkTime.daysUntil(due, now: now) {
                reasons.append(["text": WorkTime.dueLabel(n), "detail": t.origin == "jira" ? "Jira 기한 \(WorkTime.md(due))" : "기한 \(WorkTime.md(due))",
                                "docId": t.docId, "line": t.line.map { $0 as Any } ?? NSNull(), "source": "rules"])
            }
            if t.prio == "highest" || t.prio == "high" {
                reasons.append(["text": t.origin == "jira" ? (t.prio == "highest" ? "Highest" : "High") : (t.prio == "highest" ? "긴급" : "중요"),
                                "detail": t.origin == "jira" ? "내 담당 Jira 우선순위" : "할 일 우선 표시",
                                "docId": t.docId, "line": t.line.map { $0 as Any } ?? NSNull(), "source": "rules"])
            }
            reasons.append(["text": "할 일", "detail": "\(d?.title ?? "") \(t.line.map { "\($0)행" } ?? "")".trimmingCharacters(in: .whitespaces),
                            "docId": t.docId, "line": t.line.map { $0 as Any } ?? NSNull(), "source": "rules"])
            let thread = v.threadOfDoc[t.docId].flatMap { tid in v.threads.first { $0.id == tid } }
            var actions = [WorkModel.action(thread?.pinned == true ? "unpin" : "pin"), WorkModel.action("demote")]
            if thread != nil { actions.append(WorkModel.action("rename")) }
            return ["id": id, "title": t.origin == "jira" ? (d?.title ?? t.text) : t.text, "tier": "now", "tierLabel": "지금",
                    "reasons": reasons, "actions": actions]
        }
        let key: String
        if id.hasPrefix("doc:") {
            guard let t = v.threadOfDoc[String(id.dropFirst(4))] else { return ["ok": false, "error": "항목을 찾지 못했어요"] }
            key = t
        } else { key = WorkModel.threadKey(id) }
        guard let t = v.threads.first(where: { $0.id == key }) else { return ["ok": false, "error": "항목을 찾지 못했어요"] }
        let reasons: [[String: Any]] = t.reasons.prefix(8).map {
            ["text": $0["text"] ?? "", "detail": $0["detail"] ?? "", "docId": $0["docId"] ?? NSNull(),
             "line": $0["line"] ?? NSNull(), "source": $0["source"] ?? "rules"]
        }
        var actions = [WorkModel.action(t.pinned ? "unpin" : "pin"), WorkModel.action("demote")]
        if t.tier == .dormant { actions.append(WorkModel.action("wake")) }
        actions.append(WorkModel.action("rename"))
        return ["id": id, "title": t.displayTitle, "tier": t.tier.rawValue, "tierLabel": WorkModel.tierLabels[t.tier] ?? "",
                "reasons": reasons, "actions": actions]
    }

    /// 사용자 교정. 흐름 대상은 "t:…"로 저장한다. 앱·CLI에서는 바로 다시 계산한다.
    func feedback(id: String, action: String, scope: String?) -> [String: Any] {
        let allowed: Set<String> = ["pin", "unpin", "demote", "wake", "rename", "notThisFolder"]
        guard allowed.contains(action) else { return ["ok": false, "error": "알 수 없는 동작이에요"] }
        let threads = loadThreads()
        func threadOf(doc: String) -> String? { threads.first { $0.docIds.contains(doc) }?.id }
        var target = WorkModel.threadKey(id)
        var sc = scope
        if action == "notThisFolder" {
            if target.hasPrefix("t:"), let s = scope, !s.isEmpty { target = "doc:" + (s.hasPrefix("doc:") ? String(s.dropFirst(4)) : s) }
            guard target.hasPrefix("doc:") else { return ["ok": false, "error": "문서를 골라 주세요"] }
        } else if target.hasPrefix("task:") {
            let tid = String(target.dropFirst(5))
            if let t = loadTasks().first(where: { $0.id == tid }), let th = threadOf(doc: t.docId) { target = th }
        } else if target.hasPrefix("doc:") {
            if let th = threadOf(doc: String(target.dropFirst(4))) { target = th }
        }
        var act = action
        if action == "pin", threads.first(where: { $0.id == target })?.pinned == true { act = "unpin" }   // 다시 누르면 해제
        if act == "demote" { sc = scope == "always" ? "always" : "week" }
        if act == "rename" { sc = (scope ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        do {
            try ctx.db.sql.run("INSERT INTO feedback(target, action, scope, ts) VALUES(?,?,?,?)",
                               [.text(target), .text(act), sc.map { .text($0) } ?? .null, .double(nowTS)])
        } catch { return ["ok": false, "error": "기억하지 못했어요"] }
        if ctx.mode != .mcp { refresh(changed: []) }
        return ["ok": true]
    }

    func map() -> [String: Any] {
        let threads = loadThreads()
        let open = loadTasks(openOnly: true)
        let openByDoc = Dictionary(grouping: open, by: { $0.docId }).mapValues { $0.count }
        let nowT = nowTS, nowD = now
        var docThread: [String: String] = [:]
        var dim: [String] = []
        var list: [[String: Any]] = []
        for (i, t) in threads.enumerated() {
            let days = t.lastHuman.map { (nowT - $0) / 86400 } ?? 99
            let b = days <= 3 ? 1.0 : (days >= 14 ? 0.15 : 1.0 - (days - 3) / 11 * 0.85)
            list.append(["id": "thread:\(t.id)", "title": t.displayTitle, "tier": t.tier.rawValue, "colorIndex": i < 8 ? i : -1,
                         "brightness": (b * 100).rounded() / 100, "docIds": t.docIds,
                         "lastLabel": t.lastHuman.map { BrainFormat.whenLabel(Date(timeIntervalSince1970: $0), now: nowD) as Any } ?? NSNull(),
                         "openTasks": t.docIds.reduce(0) { $0 + (openByDoc[$1] ?? 0) },
                         "primaryDocId": t.primaryDoc ?? NSNull()])
            for d in t.docIds where docThread[d] == nil { docThread[d] = "thread:\(t.id)" }
            if t.tier == .dormant { dim.append(contentsOf: t.docIds) }
        }
        var archive: [String] = []
        try? ctx.db.sql.query("SELECT doc_id FROM doc_state WHERE ai_archive = 1 ORDER BY doc_id") { archive.append($0.text(0)) }
        return ["threads": list, "docThread": docThread, "hiddenArchive": archive.count, "archive": archive, "dim": dim]
    }

    /// MCP get_work_context. 세션 요청 문장·세션 제목·작업 폴더는 넣지 않는다.
    func workContext(period: String) -> [String: Any] {
        let v = loadView()
        guard !v.threads.isEmpty else { return ["updatedAt": NSNull(), "note": "Synapse 앱을 한 번 열어 주세요"] }
        let updated = v.threads.compactMap { $0.updated }.max().map { BrainFormat.iso(Date(timeIntervalSince1970: $0)) as Any } ?? NSNull()
        if period == "week" {
            var w = week(offset: 0, safe: true, view: v)
            w["heat"] = nil
            w["updatedAt"] = updated
            return w
        }
        let parts = homeParts(v, safe: true)
        let nowD = now
        let threads: [[String: Any]] = v.threads.prefix(10).map { t in
            let last = t.lastHuman ?? t.lastTs
            return ["id": "thread:\(t.id)", "title": safeTitle(t, v), "tier": t.tier.rawValue, "project": t.project ?? NSNull(),
                    "lastLabel": last.map { BrainFormat.whenLabel(Date(timeIntervalSince1970: $0), now: nowD) as Any } ?? NSNull(),
                    "openTasks": t.docIds.reduce(0) { $0 + (v.tasksByDoc[$1]?.count ?? 0) },
                    "reasons": t.reasons.filter { $0["neg"] == nil }.prefix(3).map { ["text": $0["text"] ?? "", "kind": $0["kind"] ?? "",
                                                                                        "source": $0["source"] ?? "rules"] },
                    "primaryDoc": docRef(t.primaryDoc)]
        }
        let score = Dictionary(v.threads.map { ($0.id, $0.score) }, uniquingKeysWith: { a, _ in a })
        let tasks = v.open.filter { t in
            guard let s = v.states[t.docId] else { return ctx.doc(id: t.docId) != nil }
            return !(s.excluded || s.archived || s.aiArchive)
        }.sorted { a, b in
            let x = a.due.flatMap { WorkTime.daysUntil($0, now: nowD) } ?? 9999, y = b.due.flatMap { WorkTime.daysUntil($0, now: nowD) } ?? 9999
            if x != y { return x < y }
            let p = v.threadOfDoc[a.docId].flatMap { score[$0] } ?? -1, q = v.threadOfDoc[b.docId].flatMap { score[$0] } ?? -1
            return p != q ? p > q : a.id < b.id
        }.prefix(30).map { t -> [String: Any] in
            ["text": WorkText.plain(t.text), "doc": docRef(t.docId), "due": t.due ?? NSNull(), "prio": t.prio ?? NSNull(), "origin": t.origin]
        }
        return ["updatedAt": updated, "current": parts.current ?? NSNull(), "urgent": parts.urgent, "next": parts.next,
                "threads": threads, "openTasks": tasks]
    }

    func claudeInstruction(context: String, id: String?) -> String {
        switch context {
        case "queue":
            return "Synapse MCP의 list_pending으로 자리가 정해지지 않은 문서를 확인하고, get_vault_policy 규칙에 맞게 propose_changes로 이동 제안을 올려 줘. 파일을 직접 옮기지 말고 제안만 해 줘. 승인은 내가 Synapse 정리함에서 할게."
        case "thread":
            let v = loadView()
            let key = id.map { WorkModel.threadKey($0) } ?? ""
            let t = v.threads.first { $0.id == key }
                ?? (key.hasPrefix("doc:") ? v.threadOfDoc[String(key.dropFirst(4))].flatMap { tid in v.threads.first { $0.id == tid } } : nil)
            let title = t.map { safeTitle($0, v) } ?? "지금 하던 일"
            return "Synapse MCP의 get_work_context로 '\(title)' 작업 맥락을 보고, 내가 하던 일과 다음에 할 일을 정리해 줘."
        case "policy":
            return "볼트 루트 CLAUDE.md를 읽고 Synapse get_vault_policy 결과와 다른 점을 찾아서, 규칙표 수정안을 propose_changes(kind: rules)로 올려 줘."
        case "violations":
            return "Synapse get_vault_policy의 violations 목록을 보고 프로젝트_요약.md 등에 빠진 항목을 채워 줘. 바꾸기 전에 바뀔 내용을 먼저 보여 줘."
        case "week":
            return "Synapse MCP의 get_work_context(period: week)로 이번 주 활동을 가져와서 주간보고 형식으로 정리해 줘."
        default:
            return ""
        }
    }

    /// 사서가 문서를 옮겼다(ctx.onDocMoved). threads.doc_ids·primary_doc, 기기 AI 캐시, 문서 교정의 id를 바꾼다.
    func docMoved(from: String, to: String) {
        guard from != to else { return }
        try? ctx.db.sql.transaction {
            var rows: [(String, String, String?)] = []
            try ctx.db.sql.query("SELECT id, doc_ids, primary_doc FROM threads") { r in   // 최대 40행
                rows.append((r.text(0), r.text(1), r.isNull(2) ? nil : r.text(2)))
            }
            for (id, docsJSON, primary) in rows {
                let old = (BrainFormat.parse(docsJSON) as? [String]) ?? []
                guard old.contains(from) || primary == from else { continue }
                let docs = old.map { $0 == from ? to : $0 }
                var seen = Set<String>()
                let uniq = docs.filter { seen.insert($0).inserted }
                try ctx.db.sql.run("UPDATE threads SET doc_ids = ?, primary_doc = ? WHERE id = ?",
                                   [.text(BrainFormat.json(uniq)), (primary == from ? to : primary).map { .text($0) } ?? .null, .text(id)])
            }
            try ctx.db.sql.run("DELETE FROM enrichments WHERE doc_id = ?", [.text(to)])
            try ctx.db.sql.run("UPDATE enrichments SET doc_id = ? WHERE doc_id = ?", [.text(to), .text(from)])
            try ctx.db.sql.run("UPDATE feedback SET target = ? WHERE target = ?", [.text("doc:" + to), .text("doc:" + from)])
        }
    }
}

/// 파사드(Brain.swift)가 ctx.onDocMoved에서 부른다.
extension WorkModel: BrainDocMoveObserver {
    func docMoved(fromID: String, toID: String) { docMoved(from: fromID, to: toID) }
}
