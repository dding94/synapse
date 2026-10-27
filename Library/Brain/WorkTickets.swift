import Foundation

// v0.7 A. 티켓 화면(⌘5)과 홈 맨 위 한 줄의 데이터. 열린 Jira 티켓(상태 묶음 todo·doing·blocked)을 프로젝트 키로 묶는다.
// 상태 묶기는 v0.6 규칙(Views.statusGroup) 그대로다 — 완료 분류인 막힘·보류 계열 상태는 닫힘이고, 여기서 바꾸지 않는다.
//
// tickets({mine?}) 응답:
//   {generatedAt, hasJira, projects:[{key, label, counts:{blocked,doing,todo,stale}, items:[…]}],
//    totals:{blocked,doing,todo,stale,mine}}
//   · projects·items는 mine이 true면 내 담당만. totals는 걸러지기 전 전체 열린 티켓 수, totals.mine은 내 담당 열린 티켓 수.
//   · blockedRule: {closedLike:[상태 이름…]} — 완료 분류(done)인데 이름에 block·hold·보류 계열이 있어 닫힘으로 센 상태 이름(중복·개수 없음).
//     "막힘 0"이 왜 0인지 화면이 설명하는 데 쓴다.
// 항목(item):
//   docId, key, title(키 접두를 뗀 제목), status(정리된 이름), statusGroup(blocked|doing|todo), priority, priorityRank(0=가장 높음, 5=없음),
//   mine, assigneeName?, issueType, updated(ISO), updatedLabel("3일 전"), since?(ISO), sinceLabel?("진행 중 12일째"),
//   stale(진행 중인데 7일 넘게 갱신 없음), due?, dueLabel?
// home().tickets: {blocked, doing, todo, stale} (열린 티켓 수, 걸러내기 없음)

extension WorkModel {

    /// 우선순위 이름 → 순위. 한국어("높음")와 영어(High)를 같은 순서로 본다. 모르는 이름은 5.
    static func priorityRank(_ name: String) -> Int {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch n {
        case "highest", "blocker", "critical", "가장 높음", "최상": return 0
        case "high", "major", "높음": return 1
        case "medium", "normal", "중간", "보통": return 2
        case "low", "minor", "낮음": return 3
        case "lowest", "trivial", "가장 낮음", "최하": return 4
        default: return 5
        }
    }

    /// "3일 전" 식 짧은 경과 표현.
    static func agoLabel(_ date: Date, now: Date) -> String {
        let secs = now.timeIntervalSince(date)
        if secs < 3600 { return "방금" }
        if secs < 86400 { return "\(Int(secs / 3600))시간 전" }
        let days = Int(secs / 86400)
        if days < 60 { return "\(days)일 전" }
        return "\(days / 30)달 전"
    }

    private static let staleSeconds: Double = 7 * 86400

    /// 제목 앞의 "PROJ-123 · "을 뗀다.
    private static func bareTitle(_ title: String, key: String) -> String {
        for sep in [" · ", " - ", ": ", " "] where title.hasPrefix(key + sep) { return String(title.dropFirst(key.count + sep.count)) }
        return title
    }

    private struct TicketRow {
        let item: [String: Any]
        let group: String
        let project: String
        let mine: Bool
        let stale: Bool
        let updated: Double
        let due: Int?          // 기한까지 남은 날(없으면 nil)
        let rank: Int
    }

    private func ticketRows() -> [TicketRow] {
        let nowD = now
        let nowT = nowTS
        let cal = WorkTime.cal
        var changedFallback: [String: Double]? = nil
        func fallbackChanged(_ docId: String) -> Double? {
            if changedFallback == nil {
                var m: [String: Double] = [:]
                try? ctx.db.sql.query("SELECT doc_id, changed FROM remote_state WHERE changed IS NOT NULL") { m[$0.text(0)] = $0.double(1) }
                changedFallback = m
            }
            return changedFallback?[docId]
        }
        var rows: [TicketRow] = []
        for d in ctx.docs where d.kind == "jira" {
            let raw = d.meta["status"] ?? "", cat = d.meta["statusCategory"] ?? ""
            if raw.isEmpty && cat.isEmpty { continue }
            let group = Views.statusGroup(name: raw, category: cat)
            guard group == "todo" || group == "doing" || group == "blocked" else { continue }
            guard let key = WorkModel.jiraKey(d) else { continue }
            let status = raw.trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespacesAndNewlines))
            let updatedD = d.meta["updated"].flatMap { BrainFormat.isoFormatter.date(from: $0) } ?? d.modified
            let stale = group == "doing" && nowT - updatedD.timeIntervalSince1970 > WorkModel.staleSeconds
            let mine = d.meta["mine"] == "1"
            let priority = d.meta["priority"] ?? ""
            let rank = WorkModel.priorityRank(priority)

            // 상태가 이 묶음이 된 시각: meta.statusChanged → 사서가 본 상태 변경 시각 → 비움
            var since: Date? = d.meta["statusChanged"].flatMap { BrainFormat.isoFormatter.date(from: $0) }
            if since == nil, let c = fallbackChanged(d.id) { since = Date(timeIntervalSince1970: c) }
            var item: [String: Any] = [
                "docId": d.id, "key": key, "title": WorkModel.bareTitle(d.title, key: key),
                "status": status, "statusGroup": group, "priority": priority, "priorityRank": rank,
                "mine": mine, "issueType": d.meta["issuetype"] ?? "",
                "updated": BrainFormat.iso(updatedD), "updatedLabel": WorkModel.agoLabel(updatedD, now: nowD), "stale": stale,
            ]
            if let n = d.meta["assigneeName"], !n.isEmpty { item["assigneeName"] = n }
            if let s = since {
                item["since"] = BrainFormat.iso(s)
                let days = max(0, cal.dateComponents([.day], from: cal.startOfDay(for: s), to: cal.startOfDay(for: nowD)).day ?? 0)
                let word = group == "doing" ? "진행 중" : (group == "blocked" ? "막힘" : "할 일")
                item["sinceLabel"] = days == 0 ? "\(word) 오늘부터" : "\(word) \(days)일째"
            }
            var dueDays: Int? = nil
            if let due = d.meta["duedate"], !due.isEmpty {
                item["due"] = due
                if let n = WorkTime.daysUntil(due, now: nowD) { dueDays = n; item["dueLabel"] = WorkTime.dueLabel(n) }
            }
            rows.append(TicketRow(item: item, group: group, project: String(key.split(separator: "-").first ?? Substring(key)),
                                  mine: mine, stale: stale, updated: updatedD.timeIntervalSince1970, due: dueDays, rank: rank))
        }
        return rows
    }

    private static func ticketCounts(_ rows: [TicketRow]) -> [String: Int] {
        ["blocked": rows.filter { $0.group == "blocked" }.count, "doing": rows.filter { $0.group == "doing" }.count,
         "todo": rows.filter { $0.group == "todo" }.count, "stale": rows.filter { $0.stale }.count]
    }

    /// 홈 맨 위 한 줄: 열린 티켓 수. Jira가 없거나 열린 티켓이 없으면 모두 0.
    func ticketCounts() -> [String: Int] { WorkModel.ticketCounts(ticketRows()) }

    /// 완료 분류인데 이름이 막힘·보류 계열이라 닫힘(dropped)으로 센 상태 이름. 원래 표기(예 "On Hold")를 그대로, 중복 없이 이름순.
    private func closedLikeStatuses() -> [String] {
        var names = Set<String>()
        for d in ctx.docs where d.kind == "jira" {
            let raw = (d.meta["status"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines), cat = d.meta["statusCategory"] ?? ""
            guard !raw.isEmpty, cat.lowercased() == "done", Views.statusGroup(name: raw, category: cat) == "dropped" else { continue }
            let n = raw.lowercased()
            if ["block", "hold", "보류"].contains(where: { n.contains($0) }) { names.insert(raw) }
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func tickets(mine: Bool) -> [String: Any] {
        let all = ticketRows()
        let rows = mine ? all.filter { $0.mine } : all
        // 막힘 → 진행 중(오래 멈춘 것 먼저, 그다음 오래된 순) → 할 일(기한 임박 → 우선순위 → 최근 갱신)
        func order(_ a: TicketRow, _ b: TicketRow) -> Bool {
            let ga = ["blocked": 0, "doing": 1, "todo": 2][a.group] ?? 3, gb = ["blocked": 0, "doing": 1, "todo": 2][b.group] ?? 3
            if ga != gb { return ga < gb }
            switch a.group {
            case "doing", "blocked":
                if a.stale != b.stale { return a.stale }
                if a.updated != b.updated { return a.updated < b.updated }
            default:
                if (a.due != nil) != (b.due != nil) { return a.due != nil }
                if let x = a.due, let y = b.due, x != y { return x < y }
                if a.rank != b.rank { return a.rank < b.rank }
                if a.updated != b.updated { return a.updated > b.updated }
            }
            return (a.item["key"] as? String ?? "") < (b.item["key"] as? String ?? "")
        }
        var byProject: [String: [TicketRow]] = [:]
        for r in rows { byProject[r.project, default: []].append(r) }
        var projects: [(key: String, rows: [TicketRow], counts: [String: Int])] = []
        for (k, rs) in byProject {
            projects.append((k, rs.sorted(by: order), WorkModel.ticketCounts(rs)))
        }
        // 프로젝트 순서: 막힘 수 → 진행 중 수 → 전체 수 → 키
        projects.sort {
            let a = $0.counts, b = $1.counts
            if a["blocked"]! != b["blocked"]! { return a["blocked"]! > b["blocked"]! }
            if a["doing"]! != b["doing"]! { return a["doing"]! > b["doing"]! }
            if $0.rows.count != $1.rows.count { return $0.rows.count > $1.rows.count }
            return $0.key < $1.key
        }
        var totals: [String: Any] = WorkModel.ticketCounts(all)
        totals["mine"] = all.filter { $0.mine }.count
        return [
            "generatedAt": BrainFormat.iso(now),
            "hasJira": ctx.docs.contains { $0.kind == "jira" },
            "projects": projects.map { ["key": $0.key, "label": $0.key, "counts": $0.counts, "items": $0.rows.map { $0.item }] as [String: Any] },
            "totals": totals,
            "blockedRule": ["closedLike": closedLikeStatuses()],
        ]
    }
}
