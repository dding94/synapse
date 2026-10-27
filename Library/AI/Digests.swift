import Foundation
import CryptoKit

// v0.8 정리(digest) 입력·정규화 (docs/V08.md §5). E2 담당.
// 프롬프트·스키마·빠른 작업·주간보고 기본 양식은 DigestPrompts.swift, 사서 입구(안전판)는 BrainAI.swift.
// 입력 원칙(§5.1): 안전판만(세션 대화 문장 없음), 줄마다 짧은 참조(J 티켓 · T 할 일 · D 문서 · H 흐름),
// 매분 바뀌는 글("11분 전") 대신 날짜, 키 정렬 JSON의 SHA-256 앞 16자 해시, 입력 60,000자 제한(낮은 우선순위부터 뺌).

final class SynapseDigests: DigestProviding {
    private weak var brain: Brain?
    private let library: Library
    init(brain: Brain?, library: Library) { self.brain = brain; self.library = library }

    static let maxInputChars = 60_000
    static let docBodyChars = 20_000
    static let ticketLimit = 150
    static let templateChars = 4_000

    // MARK: DigestProviding

    func scope(kind: String, offset: Int?, docId: String?) -> String? {
        switch kind {
        case "week":
            let off = offset ?? 0
            guard off <= 0, off >= -104 else { return nil }
            return BrainFormat.dayKey(WorkTime.weekStart(now(), offset: off))
        case "tickets": return "all"
        case "home": return "today"
        case "doc":
            guard let id = docId?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
            return id
        case "tidy":
            // v0.9 §5: 평일 daily-날짜, 리뷰 요일(기본 금요일)은 weekly-날짜 — 리뷰 요일 첫 열기에 하루 한 번 새로 돈다
            let n = now()
            let review = TidyReview.today(setting: brain?.aiSetting(TidySetting.reviewDay), now: n)
            return (review != nil ? "weekly-" : "daily-") + BrainFormat.dayKey(n)
        default: return nil
        }
    }

    func request(kind: String, offset: Int?, docId: String?, template: String) -> DigestRequest? {
        guard let scope = scope(kind: kind, offset: offset, docId: docId) else { return nil }
        let built: DigestBuilt?
        switch kind {
        case "week": built = weekInput(offset: offset ?? 0, template: template)
        case "tickets": built = ticketsInput()
        case "home": built = homeInput()
        case "doc": built = docInput(docId: scope)
        case "tidy": built = tidyInput(scope: scope)
        default: built = nil
        }
        guard let b = built else { return nil }
        let text = DigestJSON.text(b.input)
        let refNames = DigestJSON.sortedRefs(Array(b.refs.keys))
        return DigestRequest(kind: kind, scope: scope, input: text, hash: DigestJSON.hash(text), refs: b.refs,
                             schema: DigestPrompts.schema(kind, refs: refNames, lines: b.lines),
                             system: DigestPrompts.system(kind), prompt: DigestPrompts.prompt(kind, input: text), model: nil)
    }

    func normalize(kind: String, output: Any, refs: [String: DigestRef]) -> [String: Any]? {
        DigestNormalizer(refs: refs).run(kind, output)
    }

    var agentSystemPrompt: String { DigestPrompts.agentSystemPrompt }

    func preset(id: String, context: [String: Any]) -> AgentPreset? {
        guard let p = DigestPrompts.presets.first(where: { $0.id == id }) else { return nil }
        var prompt = p.prompt
        if p.needsDoc {
            guard let docId = (context["docId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !docId.isEmpty else { return nil }
            prompt += "\n(열려 있는 문서 id: \(docId))"
        }
        return AgentPreset(id: p.id, title: p.title, prompt: prompt, digestKind: p.digestKind)
    }

    var presets: [[String: Any]] {
        DigestPrompts.presets.map { ["id": $0.id, "title": $0.title, "hint": $0.hint, "needs": $0.needsDoc ? "doc" : NSNull()] }
    }

    var defaultReportTemplate: String { DigestPrompts.defaultReportTemplate }

    // MARK: 시각

    private func now() -> Date { brain?.aiNow() ?? Date() }

    // MARK: week (§5.2)

    private func weekInput(offset: Int, template: String) -> DigestBuilt? {
        guard let brain = brain else { return nil }
        let w = brain.aiWeek(offset: offset)
        let nowD = brain.aiNow()
        let t = DigestRefTable()
        func list(_ k: String) -> [[String: Any]] { (w[k] as? [[String: Any]]) ?? [] }

        var done: [[String: Any]] = []
        for x in list("done") {
            let docId = DigestText.string(x["docId"]) ?? ""
            var o: [String: Any]
            switch DigestText.string(x["kind"]) {
            case "issue":
                guard let key = DigestText.string(x["key"]) ?? DigestText.keyFromDocId(docId) else { continue }
                let title = DigestText.bare(DigestText.string(x["title"]) ?? DigestText.string(x["text"]) ?? "", key: key)
                o = ["ref": t.issue(docId: docId, key: key, title: title), "kind": "티켓", "key": key, "title": DigestText.clip(title, 160)]
                DigestText.put(&o, "status", x["status"])
                DigestText.put(&o, "mine", x["mine"])
            case "doc":
                let title = DigestText.string(x["text"]) ?? ""
                o = ["ref": t.doc(docId: docId, title: title), "kind": DigestText.string(x["docType"]) ?? "문서", "title": DigestText.clip(title, 160)]
            default:
                let text = WorkText.plain(DigestText.string(x["text"]) ?? "")
                guard !text.isEmpty else { continue }
                o = ["ref": t.task(docId: docId, line: DigestText.int(x["line"]), text: text), "kind": "할 일", "text": DigestText.clip(text, 160)]
                DigestText.put(&o, "doc", DigestText.string(x["docTitle"]).map { DigestText.clip($0, 80) })
            }
            DigestText.put(&o, "day", DigestText.md(DigestText.string(x["day"])))
            done.append(o)
        }

        func ticketChange(_ x: [String: Any], status: Bool) -> [String: Any]? {
            let docId = DigestText.string(x["docId"]) ?? ""
            guard let key = DigestText.string(x["key"]) ?? DigestText.keyFromDocId(docId) else { return nil }
            let title = DigestText.bare(DigestText.string(x["title"]) ?? DigestText.string(x["text"]) ?? "", key: key)
            var o: [String: Any] = ["ref": t.issue(docId: docId, key: key, title: title), "key": key, "title": DigestText.clip(title, 160)]
            if status {
                DigestText.put(&o, "status", x["status"])
            } else {
                DigestText.put(&o, "from", x["fromLabel"] ?? x["from"])
                DigestText.put(&o, "to", x["toLabel"] ?? x["to"])
            }
            DigestText.put(&o, "day", DigestText.md(DigestText.string(x["day"])))
            DigestText.put(&o, "mine", x["mine"])
            return o
        }
        let changes = list("changes").compactMap { ticketChange($0, status: false) }
        let closed = list("closed").compactMap { ticketChange($0, status: true) }

        var progress: [[String: Any]] = []
        for x in list("progress") {
            guard let tid = DigestText.string(x["threadId"]) else { continue }
            let title = DigestText.string(x["title"]) ?? ""
            var o: [String: Any] = ["ref": t.thread(id: tid, docId: DigestText.string(x["docId"]), title: title), "title": DigestText.clip(title, 120)]
            if let key = DigestText.leadingKey(title) { o["key"] = key }   // 같은 티켓의 완료·변경 줄과 묶을 수 있게
            if let n = DigestText.int(x["doneThisWeek"]), n > 0 { o["doneThisWeek"] = n }
            if let n = DigestText.int(x["open"]), n > 0 { o["open"] = n }
            DigestText.put(&o, "lastDay", DigestText.md(DigestText.string(x["lastDay"])))
            if (x["code"] as? Bool) == true { o["code"] = true }
            let signals = DigestText.signals(x["chips"])
            if !signals.isEmpty { o["signals"] = signals }
            progress.append(o)
        }

        var next: [[String: Any]] = []
        for x in list("next") {
            let docId = DigestText.string(x["docId"]) ?? ""
            let text = WorkText.plain(DigestText.string(x["text"]) ?? "")
            guard !text.isEmpty else { continue }
            var o: [String: Any]
            if DigestText.string(x["docKind"]) == "jira", let key = DigestText.string(x["key"]) ?? DigestText.keyFromDocId(docId) {
                let title = DigestText.bare(text, key: key)
                o = ["ref": t.issue(docId: docId, key: key, title: title), "key": key, "text": DigestText.clip(title, 160)]
            } else {
                o = ["ref": t.task(docId: docId, line: DigestText.int(x["line"]), text: text), "text": DigestText.clip(text, 160)]
                DigestText.put(&o, "doc", DigestText.string(x["docTitle"]).map { DigestText.clip($0, 80) })
            }
            DigestText.put(&o, "due", x["due"])
            next.append(o)
        }

        let lastPlan: [[String: Any]] = list("lastPlan").compactMap { x in
            guard let docId = DigestText.string(x["docId"]), let text = DigestText.string(x["text"]), !text.isEmpty else { return nil }
            return ["ref": t.doc(docId: docId, title: DigestText.string(x["docTitle"]) ?? "주간보고"), "text": DigestText.clip(text, 160)]
        }
        let missing: [[String: Any]] = list("missing").compactMap { x in
            guard let docId = DigestText.string(x["docId"]) else { return nil }
            let title = DigestText.string(x["title"]) ?? ""
            var o: [String: Any] = ["ref": t.doc(docId: docId, title: title), "title": DigestText.clip(title, 120)]
            DigestText.put(&o, "lines", x["lines"])
            DigestText.put(&o, "day", DigestText.md(DigestText.string(x["day"])))
            return o
        }
        let openMine = offset == 0 ? openMineTickets(brain, t, nowD) : []

        if done.isEmpty && changes.isEmpty && closed.isEmpty && progress.isEmpty && next.isEmpty
            && lastPlan.isEmpty && missing.isEmpty && openMine.isEmpty { return nil }

        let range = (w["range"] as? [String: Any]) ?? [:]
        var tpl = template.trimmingCharacters(in: .whitespacesAndNewlines)
        if tpl.isEmpty { tpl = DigestPrompts.defaultReportTemplate }
        var input: [String: Any] = ["주": DigestText.string(range["label"]) ?? "", "보고양식": String(tpl.prefix(SynapseDigests.templateChars)),
                                    "done": done, "changes": changes, "progress": progress, "next": next,
                                    "lastPlan": lastPlan, "missing": missing]
        if !closed.isEmpty { input["closed"] = closed }
        if offset == 0 {   // 지난 주는 날마다 바뀌는 값을 넣지 않는다(입력 해시가 매일 바뀌지 않게)
            input["오늘"] = DigestText.todayLabel(nowD)
            input["openMine"] = openMine
        }
        DigestFit.week(&input, limit: SynapseDigests.maxInputChars)
        return DigestBuilt(input: input, refs: t.keep(DigestJSON.refsUsed(input)))
    }

    /// 내 열린 티켓 중 진행 중·막힘·오래 멈춤·기한 임박(7일 안·지남) 최대 15.
    private func openMineTickets(_ brain: Brain, _ t: DigestRefTable, _ nowD: Date) -> [[String: Any]] {
        let r = brain.tickets(mine: true)
        let items = ((r["projects"] as? [[String: Any]]) ?? []).flatMap { ($0["items"] as? [[String: Any]]) ?? [] }
        func dueDays(_ x: [String: Any]) -> Int? { DigestText.string(x["due"]).flatMap { WorkTime.daysUntil($0, now: nowD) } }
        let picked = items.filter { x in
            let g = DigestText.string(x["statusGroup"]) ?? ""
            return g == "doing" || g == "blocked" || (x["stale"] as? Bool) == true || (dueDays(x).map { $0 <= 7 } ?? false)
        }.sorted { a, b in
            func rank(_ x: [String: Any]) -> (Int, Int, Int, String) {
                let g = DigestText.string(x["statusGroup"]) ?? ""
                return (g == "blocked" ? 0 : (g == "doing" ? 1 : 2), (x["stale"] as? Bool) == true ? 0 : 1, dueDays(x) ?? 9999,
                        DigestText.string(x["key"]) ?? "")
            }
            return rank(a) < rank(b)
        }.prefix(15)
        return picked.compactMap { ticketJSON($0, t, nowD) }
    }

    /// 티켓 한 줄 (tickets 정리·이번 주 openMine 공통).
    private func ticketJSON(_ x: [String: Any], _ t: DigestRefTable, _ nowD: Date) -> [String: Any]? {
        guard let key = DigestText.string(x["key"]), let docId = DigestText.string(x["docId"]) else { return nil }
        let title = DigestText.bare(DigestText.string(x["title"]) ?? "", key: key)
        var o: [String: Any] = ["ref": t.issue(docId: docId, key: key, title: title), "key": key, "title": DigestText.clip(title, 160)]
        DigestText.put(&o, "status", x["status"])
        DigestText.put(&o, "group", x["statusGroup"])
        DigestText.put(&o, "priority", x["priority"])
        o["mine"] = (x["mine"] as? Bool) == true
        DigestText.put(&o, "assignee", x["assigneeName"])
        if let d = DigestText.daysSince(DigestText.string(x["since"]), now: nowD) { o["since"] = d }
        if let d = DigestText.daysSince(DigestText.string(x["updated"]), now: nowD) { o["updatedDaysAgo"] = d }
        if (x["stale"] as? Bool) == true { o["stale"] = true }
        DigestText.put(&o, "due", x["due"])
        return o
    }

    // MARK: tickets (§5.3)

    private func ticketsInput() -> DigestBuilt? {
        guard let brain = brain else { return nil }
        let r = brain.tickets(mine: false)
        let nowD = brain.aiNow()
        let all = ((r["projects"] as? [[String: Any]]) ?? []).flatMap { ($0["items"] as? [[String: Any]]) ?? [] }
        guard !all.isEmpty else { return nil }
        // 150개를 넘으면 내 것 → 진행 중 → 기한 임박 → 최근 갱신 순으로 남긴다(보여 주는 순서는 원래 순서)
        func rank(_ x: [String: Any]) -> (Int, Int, Int, Double) {
            let g = DigestText.string(x["statusGroup"]) ?? ""
            let due = DigestText.string(x["due"]).flatMap { WorkTime.daysUntil($0, now: nowD) } ?? 9999
            let upd = DigestText.string(x["updated"]).flatMap { BrainFormat.isoFormatter.date(from: $0) }?.timeIntervalSince1970 ?? 0
            return ((x["mine"] as? Bool) == true ? 0 : 1, g == "doing" || g == "blocked" ? 0 : 1, due, -upd)
        }
        let order = all.indices.sorted { rank(all[$0]) < rank(all[$1]) }
        var keep = Array(order.prefix(SynapseDigests.ticketLimit))
        func build(_ idx: [Int]) -> ([String: Any], DigestRefTable, Int) {
            let t = DigestRefTable()
            let set = Set(idx)
            let list = all.indices.filter { set.contains($0) }.compactMap { ticketJSON(all[$0], t, nowD) }
            var input: [String: Any] = ["오늘": DigestText.todayLabel(nowD), "tickets": list]
            if let totals = r["totals"] as? [String: Any] { input["totals"] = totals }
            if all.count > list.count { input["omitted"] = all.count - list.count }
            return (input, t, list.count)
        }
        var (input, t, n) = build(keep)
        while DigestJSON.text(input).count > SynapseDigests.maxInputChars && keep.count > 1 {
            keep.removeLast(max(1, keep.count / 10))
            (input, t, n) = build(keep)
        }
        return DigestBuilt(input: input, refs: t.keep(DigestJSON.refsUsed(input)), lines: n)
    }

    // MARK: home (§5.4)

    private func homeInput() -> DigestBuilt? {
        guard let brain = brain else { return nil }
        let h = brain.aiHome()
        let nowD = brain.aiNow()
        let t = DigestRefTable()

        /// 홈 항목(흐름·할 일·이슈)을 정리 입력 한 줄로.
        func item(_ x: [String: Any]) -> [String: Any]? {
            let title = WorkText.plain(DigestText.string(x["title"]) ?? "")
            guard !title.isEmpty else { return nil }
            let docId = DigestText.string(x["docId"])
            var o: [String: Any]
            switch DigestText.string(x["kind"]) {
            case "thread":
                guard let id = DigestText.string(x["id"]) else { return nil }
                o = ["ref": t.thread(id: id, docId: docId, title: title), "title": DigestText.clip(title, 120)]
            case "issue":
                guard let d = docId, let key = DigestText.keyFromDocId(d) else { return nil }
                let bare = DigestText.bare(title, key: key)
                o = ["ref": t.issue(docId: d, key: key, title: bare), "key": key, "title": DigestText.clip(bare, 120)]
            default:
                guard let d = docId else { return nil }
                o = ["ref": t.task(docId: d, line: DigestText.int(x["line"]), text: title), "title": DigestText.clip(title, 120)]
            }
            DigestText.put(&o, "project", x["project"])
            if let n = DigestText.int(x["openTasks"]), n > 0 { o["openTasks"] = n }
            DigestText.put(&o, "due", x["due"])
            DigestText.put(&o, "dueLabel", x["dueLabel"])
            DigestText.put(&o, "last", DigestText.md(DigestText.string(x["when"]).flatMap { BrainFormat.isoFormatter.date(from: $0) }.map(BrainFormat.dayKey)))
            let signals = DigestText.signals(x["chips"])
            if !signals.isEmpty { o["signals"] = signals }
            return o
        }
        let current = (h["current"] as? [String: Any]).flatMap(item)
        let urgent = ((h["urgent"] as? [[String: Any]]) ?? []).compactMap(item)
        let next = ((h["next"] as? [[String: Any]]) ?? []).compactMap(item)
        let threads: [[String: Any]] = ((h["threads"] as? [[String: Any]]) ?? []).compactMap { x in
            guard let id = DigestText.string(x["id"]) else { return nil }
            let title = DigestText.string(x["title"]) ?? ""
            let primary = (x["primaryDoc"] as? [String: Any]).flatMap { DigestText.string($0["id"]) }
            var o: [String: Any] = ["ref": t.thread(id: id, docId: primary, title: title), "title": DigestText.clip(title, 120)]
            DigestText.put(&o, "tier", x["tier"])
            DigestText.put(&o, "project", x["project"])
            if let n = DigestText.int(x["openTasks"]), n > 0 { o["openTasks"] = n }
            let signals = DigestText.signals(x["reasons"])
            if !signals.isEmpty { o["signals"] = signals }
            return o
        }
        let dueTasks: [[String: Any]] = ((h["dueTasks"] as? [[String: Any]]) ?? []).compactMap { x in
            guard let docId = DigestText.string(x["docId"]), let text = DigestText.string(x["text"]), !text.isEmpty else { return nil }
            var o: [String: Any]
            if DigestText.string(x["origin"]) == "jira", let key = DigestText.string(x["key"]) ?? DigestText.keyFromDocId(docId) {
                let bare = DigestText.bare(text, key: key)
                o = ["ref": t.issue(docId: docId, key: key, title: bare), "key": key, "text": DigestText.clip(bare, 120)]
            } else {
                o = ["ref": t.task(docId: docId, line: DigestText.int(x["line"]), text: text), "text": DigestText.clip(text, 120)]
                DigestText.put(&o, "doc", DigestText.string(x["docTitle"]).map { DigestText.clip($0, 80) })
            }
            DigestText.put(&o, "due", x["due"])
            DigestText.put(&o, "days", x["days"])
            return o
        }
        if current == nil && urgent.isEmpty && next.isEmpty && threads.isEmpty && dueTasks.isEmpty { return nil }
        var input: [String: Any] = ["오늘": DigestText.todayLabel(nowD), "urgent": urgent, "next": next, "threads": threads, "dueTasks": dueTasks]
        if let c = current { input["current"] = c }
        if let tk = h["tickets"] as? [String: Any] { input["tickets"] = tk }
        return DigestBuilt(input: input, refs: t.keep(DigestJSON.refsUsed(input)))
    }

    // MARK: doc (§5.5)

    private func docInput(docId: String) -> DigestBuilt? {
        guard let d = library.documentJSON(id: docId), let meta = d["doc"] as? [String: Any] else { return nil }
        let md = DigestText.string(d["markdown"]) ?? ""
        let body = (md.isEmpty ? (DigestText.string(d["text"]) ?? "") : md).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        let clipped = String(body.prefix(SynapseDigests.docBodyChars))
        var input: [String: Any] = ["제목": DigestText.string(meta["title"]) ?? "", "본문": clipped]
        DigestText.put(&input, "경로", meta["path"])
        DigestText.put(&input, "출처", DigestText.sourceLabel(DigestText.string(meta["sourceKind"]), kind: DigestText.string(meta["kind"])))
        DigestText.put(&input, "종류", meta["kindLabel"])
        DigestText.put(&input, "수정", DigestText.string(meta["updated"]).map { String($0.prefix(10)) })
        if body.count > clipped.count { input["잘림"] = "본문 앞 \(SynapseDigests.docBodyChars)자만 넣었어요(전체 \(body.count)자)" }
        return DigestBuilt(input: input, refs: [:])
    }
}

// MARK: - 입력 도우미

/// 만든 입력과 참조표. lines = tickets 정리의 티켓 수(스키마 lines 최대 개수).
struct DigestBuilt {
    var input: [String: Any]
    var refs: [String: DigestRef]
    var lines = 0
}

/// 짧은 참조표. 같은 대상(같은 Jira 키·같은 할 일 줄·같은 문서·같은 흐름)은 같은 참조를 받는다. 번호는 입력 순서대로라 결정적이다.
final class DigestRefTable {
    private(set) var refs: [String: DigestRef] = [:]
    private var seen: [String: String] = [:]
    private var count: [String: Int] = [:]

    private func add(_ prefix: String, _ dedupe: String, _ make: () -> DigestRef) -> String {
        if let r = seen[dedupe] { return r }
        let n = (count[prefix] ?? 0) + 1
        count[prefix] = n
        let r = prefix + String(n)
        seen[dedupe] = r
        refs[r] = make()
        return r
    }
    func issue(docId: String, key: String, title: String) -> String {
        add("J", "J|" + key) { DigestRef(docId: docId, line: nil, key: key, title: DigestText.clip(title, 120), kind: "issue") }
    }
    func task(docId: String, line: Int?, text: String) -> String {
        add("T", "T|\(docId)|" + (line.map(String.init) ?? text)) { DigestRef(docId: docId, line: line, key: nil, title: DigestText.clip(text, 120), kind: "task") }
    }
    func doc(docId: String, title: String) -> String {
        add("D", "D|" + docId) { DigestRef(docId: docId, line: nil, key: nil, title: DigestText.clip(title, 120), kind: "doc") }
    }
    /// 흐름의 docId는 대표 문서(코드 흐름은 문서가 없어 "").
    func thread(id: String, docId: String?, title: String) -> String {
        add("H", "H|" + id) { DigestRef(docId: docId ?? "", line: nil, key: nil, title: DigestText.clip(title, 120), kind: "thread") }
    }
    /// 크기 제한으로 항목을 뺀 뒤 입력에 남은 참조만.
    func keep(_ used: Set<String>) -> [String: DigestRef] { refs.filter { used.contains($0.key) } }
}

enum DigestText {
    static func string(_ v: Any?) -> String? {
        guard let s = v as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double, d.isFinite { return Int(d) }
        if let n = v as? NSNumber { return n.intValue }
        return nil
    }
    /// 값이 있을 때만 넣는다(nil·NSNull·빈 글 제외).
    static func put(_ o: inout [String: Any], _ k: String, _ v: Any?) {
        guard let v = v, !(v is NSNull) else { return }
        if let s = v as? String { if let t = string(s) { o[k] = t } ; return }
        o[k] = v
    }
    /// 한 줄로 모으고(줄바꿈·연속 공백 → 공백) n자에서 자른다("…").
    static func clip(_ s: String, _ n: Int) -> String {
        let one = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return one.count <= n ? one : String(one.prefix(max(1, n - 1))) + "…"
    }
    /// "PROJ-1 · 제목" → "제목"
    static func bare(_ title: String, key: String) -> String {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix(key) else { return t }
        let rest = t.dropFirst(key.count).drop { $0 == " " || $0 == "·" || $0 == ":" || $0 == "-" || $0 == "–" || $0 == "—" }
        return rest.isEmpty ? t : String(rest)
    }
    /// "PROJ-12 · 제목" → "PROJ-12" (흐름 이름 앞의 Jira 키)
    static func leadingKey(_ title: String) -> String? {
        guard let r = title.range(of: #"^[A-Z][A-Z0-9]+-\d+(?![0-9A-Za-z])"#, options: .regularExpression) else { return nil }
        return String(title[r])
    }
    /// "<출처>:jira:PROJ-1" → "PROJ-1"
    static func keyFromDocId(_ id: String) -> String? {
        guard let r = id.range(of: ":jira:") else { return nil }
        let k = String(id[r.upperBound...])
        return k.isEmpty ? nil : k
    }
    /// "2026-10-26" → "10-26"
    static func md(_ day: String?) -> String? {
        guard let d = day, d.count >= 10 else { return nil }
        return String(d.dropFirst(5).prefix(5))
    }
    private static let weekdays = ["일", "월", "화", "수", "목", "금", "토"]
    /// "2026-10-26(월)"
    static func todayLabel(_ now: Date) -> String {
        "\(BrainFormat.dayKey(now))(\(weekdays[WorkTime.cal.component(.weekday, from: now) - 1]))"
    }
    /// ISO 시각부터 오늘까지 지난 날 수(달력 기준).
    static func daysSince(_ iso: String?, now: Date) -> Int? {
        guard let s = iso, let d = BrainFormat.isoFormatter.date(from: s) ?? WorkWeekTime.parse(s).map({ Date(timeIntervalSince1970: $0) }) else { return nil }
        let cal = WorkTime.cal
        return max(0, cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: now)).day ?? 0)
    }
    /// 이유 칩 → 매분·매일 바뀌지 않는 짧은 신호. 기한 칩("기한 D-3")·링크 칩은 뺀다(기한은 따로 넣는다).
    static func signals(_ v: Any?) -> [String] {
        var out: [String] = []
        for c in (v as? [[String: Any]]) ?? [] {
            let text = string(c["text"]) ?? ""
            let s: String?
            switch string(c["kind"]) ?? "" {
            case "jira", "pin", "task": s = text
            case "session": s = text.hasPrefix("Codex") ? "Codex에게 요청" : "Claude에게 요청"
            case "activity":
                s = text.replacingOccurrences(of: #"^(오늘|어제|그제|\d+일 전|\d+/\d+)\s+"#, with: "", options: .regularExpression)
            case "open": s = "열람"
            default: s = nil
            }
            if let x = s.flatMap({ string($0) }), !out.contains(x) { out.append(x) }
        }
        return out
    }
    static func sourceLabel(_ sourceKind: String?, kind: String?) -> String? {
        switch kind {
        case "jira": return "Jira"
        case "confluence": return "Confluence"
        default: break
        }
        switch sourceKind {
        case "obsidian": return "옵시디언 볼트"
        case "folder": return "폴더"
        default: return sourceKind
        }
    }
}

enum DigestJSON {
    /// 키를 정렬한 한 줄 JSON (해시와 Claude 입력에 같은 글을 쓴다).
    static func text(_ o: Any) -> String {
        guard JSONSerialization.isValidJSONObject(o),
              let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(data: d, encoding: .utf8) ?? "{}"
    }
    /// 입력 JSON 글의 SHA-256 앞 16자. 프롬프트 판(DigestPrompts.version)을 앞에 섞어, 프롬프트를 바꾸면 저장된 정리가 낡은 것으로 보이게 한다.
    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data((DigestPrompts.version + "\n" + text).utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
    /// 입력 안의 "ref" 값들.
    static func refsUsed(_ o: Any) -> Set<String> {
        var out = Set<String>()
        func walk(_ v: Any) {
            if let d = v as? [String: Any] {
                for (k, x) in d { if k == "ref", let s = x as? String { out.insert(s) } else { walk(x) } }
            } else if let a = v as? [Any] { a.forEach(walk) }
        }
        walk(o)
        return out
    }
    /// J1, J2, …, J10 순(종류 → 번호).
    static func sortedRefs(_ refs: [String]) -> [String] {
        refs.sorted { a, b in
            let pa = a.prefix(1), pb = b.prefix(1)
            if pa != pb { return pa < pb }
            return (Int(a.dropFirst()) ?? 0) < (Int(b.dropFirst()) ?? 0)
        }
    }
}

/// 입력 60,000자 제한 (§5.1): 넘으면 우선순위가 낮은 줄(남의 티켓, 오래된 것)부터 뺀다. 뺀 수는 omitted에 남긴다.
enum DigestFit {
    static func week(_ input: inout [String: Any], limit: Int) {
        guard DigestJSON.text(input).count > limit else { return }
        var work = input
        defer { input = work }
        func size() -> Int { DigestJSON.text(work).count }
        var omitted: [String: Int] = [:]
        func items(_ k: String) -> [[String: Any]] { (work[k] as? [[String: Any]]) ?? [] }
        /// k 목록에서 고른 항목 하나를 뺀다. 날짜가 가장 이른(없으면 맨 뒤) 것.
        func dropOne(_ k: String, where pick: ([String: Any]) -> Bool, dayKey: String = "day") -> Bool {
            var l = items(k)
            let idx = l.indices.filter { pick(l[$0]) }
            guard !idx.isEmpty else { return false }
            let oldest = idx.min { (DigestText.string(l[$0][dayKey]) ?? "99") < (DigestText.string(l[$1][dayKey]) ?? "99") } ?? idx.last!
            l.remove(at: oldest)
            work[k] = l
            omitted[k, default: 0] += 1
            return true
        }
        func notMine(_ x: [String: Any]) -> Bool { (x["mine"] as? Bool) != true }
        func quiet(_ x: [String: Any]) -> Bool { x["doneThisWeek"] == nil && x["open"] == nil }
        let steps: [() -> Bool] = [
            { dropOne("changes", where: notMine) },
            { dropOne("closed", where: notMine) },
            { dropOne("progress", where: quiet, dayKey: "lastDay") },
            { dropOne("missing", where: { _ in true }) },
            { items("lastPlan").count > 3 && dropOne("lastPlan", where: { _ in true }) },
            { dropOne("done", where: { DigestText.string($0["kind"]) != "티켓" && DigestText.string($0["kind"]) != "할 일" }) },
            { dropOne("done", where: { DigestText.string($0["kind"]) == "할 일" }) },
            { items("openMine").count > 8 && dropOne("openMine", where: { _ in true }) },
            { items("next").count > 5 && dropOne("next", where: { _ in true }) },
            { dropOne("progress", where: { _ in true }, dayKey: "lastDay") },
            { dropOne("done", where: notMine) },
            { dropOne("changes", where: { _ in true }) },
            { dropOne("done", where: { _ in true }) },
        ]
        let target = limit - 300   // omitted 표시가 들어갈 자리
        var i = 0
        while size() > target && i < steps.count {
            if !steps[i]() { i += 1 }
        }
        if size() > target, let tpl = work["보고양식"] as? String { work["보고양식"] = String(tpl.prefix(1500)) }
        if !omitted.isEmpty { work["omitted"] = omitted }
    }
}

// MARK: - 정규화 (Claude 출력 → 화면용)

struct DigestNormalizer {
    let refs: [String: DigestRef]

    func run(_ kind: String, _ output: Any) -> [String: Any]? {
        guard let o = DigestNormalizer.object(output) else { return nil }
        switch kind {
        case "week": return week(o)
        case "tickets": return tickets(o)
        case "home": return home(o)
        case "doc": return doc(o)
        case "tidy": return tidy(o)
        default: return nil
        }
    }

    /// 출력이 사전이 아니라 JSON 글(코드 울타리 포함)·Data면 풀어 본다.
    static func object(_ output: Any) -> [String: Any]? {
        if let d = output as? [String: Any] { return d }
        var text: String? = output as? String
        if let data = output as? Data { text = String(data: data, encoding: .utf8) }
        guard var s = text?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.hasPrefix("```") {
            s = s.replacingOccurrences(of: #"^```[a-zA-Z]*\s*"#, with: "", options: .regularExpression)
            s = s.replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
        }
        if let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}"), a < b { s = String(s[a...b]) }
        guard let d = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return o
    }

    // MARK: 글·참조

    /// 한 줄 글(줄바꿈은 공백으로), n자에서 자른다.
    static func line(_ v: Any?, _ n: Int) -> String {
        guard let s = v as? String else { return "" }
        return DigestText.clip(s.replacingOccurrences(of: "\\n", with: " "), n)
    }
    /// 여러 줄 글: 줄 끝 공백·빈 줄 셋 이상을 정리하고 n자에서 자른다.
    /// 모델이 줄바꿈을 글자 그대로 "\n"(역슬래시+n)으로 쓴 경우(실제 줄바꿈보다 많으면) 진짜 줄바꿈으로 바꾼다.
    static func block(_ v: Any?, _ n: Int) -> String {
        guard var s = v as? String else { return "" }
        let literal = s.components(separatedBy: "\\n").count - 1
        if literal > 0 && literal > s.filter({ $0 == "\n" }).count {
            s = s.replacingOccurrences(of: "\\r\\n", with: "\n").replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\t", with: "  ")
        }
        s = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines = s.components(separatedBy: "\n").map { l -> String in
            var x = l
            while let c = x.last, c == " " || c == "\t" { x.removeLast() }
            return x
        }
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        s = lines.joined(separator: "\n").replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return s.count <= n ? s : String(s.prefix(max(1, n - 1))) + "…"
    }
    static func pick(_ v: Any?, _ allowed: [String]) -> String? {
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespaces).lowercased(), allowed.contains(s) else { return nil }
        return s
    }
    /// "J1" · "[J1]" · "j1" → 입력에 있던 참조면 {ref, docId, line, key, title, kind}. 모르는 참조는 nil(버린다).
    func ref(_ v: Any?) -> [String: Any]? {
        guard let raw = v as? String else { return nil }
        let r = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]() ").union(.whitespacesAndNewlines)).uppercased()
        guard let x = refs[r] else { return nil }
        var o = x.json
        o["ref"] = r
        return o
    }
    func refList(_ v: Any?) -> [[String: Any]] {
        var seen = Set<String>(), out: [[String: Any]] = []
        for x in (v as? [Any]) ?? [] {
            guard let o = ref(x), let r = o["ref"] as? String, seen.insert(r).inserted else { continue }
            out.append(o)
        }
        return out
    }
    static func dicts(_ v: Any?) -> [[String: Any]] { ((v as? [Any]) ?? []).compactMap { $0 as? [String: Any] } }

    // MARK: week (§5.2)

    func week(_ o: [String: Any]) -> [String: Any]? {
        let headline = DigestNormalizer.line(o["headline"], 80)
        var sections: [[String: Any]] = []
        for s in DigestNormalizer.dicts(o["sections"]) {
            let state = DigestNormalizer.pick(s["state"], ["done", "doing", "hold", "planned", "mixed"]) ?? "mixed"
            var items: [[String: Any]] = []
            for i in DigestNormalizer.dicts(s["items"]) {
                let text = DigestNormalizer.line(i["text"], 120)
                guard !text.isEmpty else { continue }
                let st = DigestNormalizer.pick(i["state"], ["done", "doing", "todo", "hold"])
                    ?? ["done": "done", "hold": "hold", "planned": "todo"][state] ?? "doing"
                items.append(["text": text, "state": st, "refs": refList(i["refs"])])
                if items.count == 8 { break }
            }
            guard !items.isEmpty else { continue }
            let title = DigestNormalizer.line(s["title"], 40)
            sections.append(["title": title.isEmpty ? "기타" : title, "state": state, "items": items])
            if sections.count == 7 { break }
        }
        let next: [[String: Any]] = DigestNormalizer.dicts(o["next"]).compactMap { n in
            let text = DigestNormalizer.line(n["text"], 120)
            return text.isEmpty ? nil : ["text": text, "why": DigestNormalizer.line(n["why"], 60), "refs": refList(n["refs"])]
        }.prefix(5).map { $0 }
        let risks: [[String: Any]] = DigestNormalizer.dicts(o["risks"]).compactMap { r in
            let text = DigestNormalizer.line(r["text"], 120)
            return text.isEmpty ? nil : ["text": text, "refs": refList(r["refs"])]
        }.prefix(4).map { $0 }
        let sk = o["skipped"] as? [String: Any] ?? [:]
        let skipped: [String: Any] = ["count": max(0, DigestText.int(sk["count"]) ?? 0), "note": DigestNormalizer.line(sk["note"], 80)]
        let report = DigestReport.clean(DigestNormalizer.block(o["report"], 6000))
        guard !headline.isEmpty || !sections.isEmpty || !report.isEmpty else { return nil }
        return ["headline": headline, "sections": sections, "next": next, "risks": risks, "skipped": skipped,
                "report": report, "reportHTML": DigestReport.html(report)]
    }

    // MARK: tickets (§5.3)

    func tickets(_ o: [String: Any]) -> [String: Any]? {
        let headline = DigestNormalizer.line(o["headline"], 80)
        var focus: [[String: Any]] = [], seenFocus = Set<String>()
        for f in DigestNormalizer.dicts(o["focus"]) {
            guard let r = ref(f["ref"]), let name = r["ref"] as? String, seenFocus.insert(name).inserted else { continue }
            focus.append(["ref": r, "why": DigestNormalizer.line(f["why"], 60), "action": DigestNormalizer.line(f["action"], 60)])
            if focus.count == 5 { break }
        }
        var themes: [[String: Any]] = []
        for t in DigestNormalizer.dicts(o["themes"]) {
            let title = DigestNormalizer.line(t["title"], 40), list = refList(t["refs"])
            guard !title.isEmpty, !list.isEmpty else { continue }
            themes.append(["title": title, "summary": DigestNormalizer.line(t["summary"], 80), "refs": list])
            if themes.count == 8 { break }
        }
        var lines: [String: String] = [:]
        for l in DigestNormalizer.dicts(o["lines"]) {
            guard let r = ref(l["ref"]), let key = r["key"] as? String, lines[key] == nil else { continue }
            let text = DigestNormalizer.line(l["text"], 50)
            if !text.isEmpty { lines[key] = text }
        }
        var cleanup: [[String: Any]] = [], seenClean = Set<String>()
        for c in DigestNormalizer.dicts(o["cleanup"]) {
            guard let r = ref(c["ref"]), r["key"] is String, let op = DigestNormalizer.pick(c["op"], ["comment", "transition"]) else { continue }
            var item: [String: Any] = ["ref": r, "op": op, "why": DigestNormalizer.line(c["why"], 60), "to": NSNull(), "body": NSNull()]
            if op == "transition" {
                let to = DigestNormalizer.line(c["to"], 40)
                guard !to.isEmpty else { continue }
                item["to"] = to
            } else {
                let body = DigestNormalizer.block(c["body"], 400)
                guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                item["body"] = body
            }
            guard seenClean.insert("\(r["ref"] ?? "")|\(op)").inserted else { continue }
            cleanup.append(item)
            if cleanup.count == 6 { break }
        }
        guard !headline.isEmpty || !focus.isEmpty || !themes.isEmpty || !lines.isEmpty else { return nil }
        return ["headline": headline, "focus": focus, "themes": themes, "lines": lines, "cleanup": cleanup]
    }

    // MARK: home (§5.4)

    func home(_ o: [String: Any]) -> [String: Any]? {
        let headline = DigestNormalizer.line(o["headline"], 60)
        let today: [[String: Any]] = DigestNormalizer.dicts(o["today"]).compactMap { x in
            let text = DigestNormalizer.line(x["text"], 80)
            return text.isEmpty ? nil : ["text": text, "why": DigestNormalizer.line(x["why"], 60), "refs": refList(x["refs"])]
        }.prefix(3).map { $0 }
        guard !headline.isEmpty || !today.isEmpty else { return nil }
        return ["headline": headline, "today": today]
    }

    // MARK: doc (§5.5)

    func doc(_ o: [String: Any]) -> [String: Any]? {
        let summary = DigestReport.sentences(DigestNormalizer.line(o["summary"], 400), max: 3)
        func strings(_ v: Any?) -> [String] {
            ((v as? [Any]) ?? []).compactMap { $0 as? String }.map { DigestNormalizer.line($0, 120) }.filter { !$0.isEmpty }.prefix(5).map { $0 }
        }
        let points = strings(o["points"]), todos = strings(o["todos"])
        guard !summary.isEmpty || !points.isEmpty else { return nil }
        return ["summary": summary, "points": points, "todos": todos]
    }
}

// MARK: - 보고 글

enum DigestReport {
    /// 보고 글에 섞인 참조 표시("(J1)", "[J1, T2]")와 굵게 표시를 뗀다.
    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"\s*[\[(](?:[JTDH]\d+)(?:\s*[,·/]\s*[JTDH]\d+)*[\])]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "**", with: "")
        return t
    }

    /// 앞에서부터 max문장까지(문장 끝: . ! ? 。 뒤 공백).
    static func sentences(_ s: String, max: Int) -> String {
        var count = 0
        var end = s.endIndex
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            let next = s.index(after: i)
            if ".!?。".contains(c), next == s.endIndex || s[next] == " " {
                count += 1
                if count == max { end = next; break }
            }
            i = next
        }
        return String(s[..<end]).trimmingCharacters(in: .whitespaces)
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }

    /// 들여쓴 "- " 목록 → 중첩 <ul><li> (Confluence에 붙이면 글머리표가 산다). 목록이 아닌 줄은 <p>. 글자는 HTML 이스케이프.
    /// 들여쓰기는 칸 수를 비교한다(2칸·4칸·탭 모두). 단계 사이의 어중간한 들여쓰기는 가까운 바깥 단계로 붙인다.
    static func html(_ text: String) -> String {
        var out = ""
        var stack: [(indent: Int, liOpen: Bool)] = []
        func closeAbove(_ indent: Int) {
            while let top = stack.last, top.indent > indent {
                if top.liOpen { out += "</li>" }
                out += "</ul>"
                stack.removeLast()
            }
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let indent = line.prefix { $0 == " " }.count
            var body: String? = nil
            for m in ["- ", "* ", "• ", "· "] where trimmed.hasPrefix(m) { body = String(trimmed.dropFirst(m.count)).trimmingCharacters(in: .whitespaces); break }
            if trimmed == "-" || trimmed == "*" { body = "" }
            guard let item = body else {
                closeAbove(-1)
                out += "<p>" + esc(trimmed) + "</p>"
                continue
            }
            if let top = stack.last, indent > top.indent, top.liOpen {
                out += "<ul>"
                stack.append((indent, false))
            } else if stack.isEmpty {
                out += "<ul>"
                stack.append((indent, false))
            } else {
                closeAbove(indent)
                if stack.isEmpty { out += "<ul>"; stack.append((indent, false)) }
            }
            if stack[stack.count - 1].liOpen { out += "</li>" }
            out += "<li>" + esc(item)
            stack[stack.count - 1].liOpen = true
        }
        closeAbove(-1)
        return out
    }
}

// MARK: - v0.9 정리 계획 (docs/V09.md §5)

/// 정리 계획 참조의 메타. DigestRef.key에 JSON으로 담아 정규화(안전 검사)에 쓴다. 화면에는 보이지 않는다.
struct TidyRefMeta {
    var zone: String? = nil       // 자리 구역 · 목적지 구역(코드 폴더면 nil)
    var flags: [String] = []
    var vault: String? = nil      // 볼트 루트
    var sourceRoot = false        // 자리 자신이 켜진 출처 루트
    var isDir = true
    var code = false              // 코드 폴더 목적지

    var json: String {
        var o: [String: Any] = ["f": flags, "s": sourceRoot, "d": isDir, "c": code]
        if let z = zone { o["z"] = z }
        if let v = vault { o["v"] = v }
        return DigestJSON.text(o)
    }
    init() {}
    init(_ key: String?) {
        guard let k = key, let d = k.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
        zone = o["z"] as? String; flags = (o["f"] as? [String]) ?? []; vault = o["v"] as? String
        sourceRoot = (o["s"] as? Bool) ?? false; isDir = (o["d"] as? Bool) ?? true; code = (o["c"] as? Bool) ?? false
    }
}

/// 비밀 값 파일 이름 (정리 비서 E1과 같은 목록, 대소문자 무시). Claude 입력에서 이름을 가리는 데 쓴다. 내용은 보지 않는다.
enum TidySecretName {
    private static let exact: Set<String> = [".env", ".envrc", ".netrc", ".npmrc", ".pgpass"]
    private static let suffixes = [".env", ".pem", ".key", ".p12", ".pfx", ".jks", ".keystore", ".kdbx", ".ppk"]
    private static let prefixes = [".env.", "id_rsa", "id_ed25519", "credentials", "secrets."]

    static func matches(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        if n.isEmpty { return false }
        if exact.contains(n) || suffixes.contains(where: { n.hasSuffix($0) }) || prefixes.contains(where: { n.hasPrefix($0) }) { return true }
        return n.hasPrefix("service-account") && n.hasSuffix(".json")
    }
    /// 경로 조각 중 하나라도 비밀 이름인가.
    static func inPath(_ path: String) -> Bool { path.split(separator: "/").contains { matches(String($0)) } }
    /// 색인 제목이 비밀 파일 이름처럼 보이나 ("credentials", "deploy-prod.key").
    static func title(_ t: String) -> Bool { matches(t) || matches(t + ".md") }
}

extension SynapseDigests {
    static let tidyParaTops: Set<String> = ["_workspace", "1-Projects", "2-Areas", "3-Resources", "4-Archive"]
    private static let zoneOrder: [String: Int] = ["loose": 0, "inbox": 1, "vault-root": 2, "workspace": 3, "project": 4, "area": 5, "resource": 6, "archive": 7]
    static let secretLabel = "비밀 파일(이름 가림)"

    /// 정리 비서 context()(§4.8)를 짧은 참조(P# 자리 · D# 목적지 · R# 원자료 · V# 볼트)로 바꾼다. 파일 내용·세션 대화 문장은 없다.
    /// 60,000자를 넘으면 자료·보관 자리 → 제목 → 목적지 순으로 줄인다.
    func tidyInput(scope: String) -> DigestBuilt? {
        guard let brain = brain else { return nil }
        let c = brain.aiTidy()
        let places = ((c["places"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }.filter { DigestText.string($0["path"]) != nil }
        guard !places.isEmpty else { return nil }
        let nowD = brain.aiNow()
        for level in stride(from: 3, through: 0, by: -1) {
            let b = tidyBuild(c, places: places, now: nowD, scope: scope, level: level)
            if DigestJSON.text(b.input).count <= SynapseDigests.maxInputChars || level == 0 { return b }
        }
        return nil
    }

    /// level 3: 제목 5개 · 2: 정리 안 됨만 제목 5, 나머지 2 · 1: 자료·보관 자리 빼고 정리 안 됨만 제목 2 · 0: 정리 안 됨·작업 공간·프로젝트만, 제목 없음.
    func tidyBuild(_ c: [String: Any], places all: [[String: Any]], now nowD: Date, scope: String, level: Int) -> DigestBuilt {
        var refs: [String: DigestRef] = [:]
        var count: [String: Int] = [:]
        var byPath: [String: String] = [:]
        func add(_ prefix: String, path: String, title: String, kind: String, meta: TidyRefMeta) -> String {
            if let r = byPath[prefix + "|" + path] { return r }
            let n = (count[prefix] ?? 0) + 1
            count[prefix] = n
            let r = prefix + String(n)
            byPath[prefix + "|" + path] = r
            refs[r] = DigestRef(docId: path, line: nil, key: meta.json, title: DigestText.clip(title, 120), kind: kind)
            return r
        }
        let vaults = ((c["vaults"] as? [Any]) ?? []).compactMap { $0 as? String }
        let sourceRoots = Set(((c["sourceRoots"] as? [Any]) ?? []).compactMap { $0 as? String }.map(Indexer.nfc))
        let jira = (c["jira"] as? [String: Any]) ?? [:]
        func vaultOf(_ p: String) -> String? { vaults.filter { p == $0 || p.hasPrefix($0 + "/") }.max { $0.count < $1.count } }

        var input: [String: Any] = ["today": DigestText.todayLabel(nowD), "kind": scope.hasPrefix("weekly-") ? "weekly" : "daily"]
        input["vaults"] = vaults.map { v -> [String: Any] in
            var m = TidyRefMeta(); m.vault = v
            return ["ref": add("V", path: v, title: (v as NSString).lastPathComponent, kind: "vault", meta: m), "name": (v as NSString).lastPathComponent]
        }
        let sorted = all.sorted {
            let a = SynapseDigests.zoneOrder[$0["zone"] as? String ?? ""] ?? 9, b = SynapseDigests.zoneOrder[$1["zone"] as? String ?? ""] ?? 9
            return a != b ? a < b : (DigestText.string($0["path"]) ?? "") < (DigestText.string($1["path"]) ?? "")
        }
        // 비밀 자리 경로 — 줄이기 단계에서 빠진 자리라도 이름이 대기 제안 등으로 새지 않게 (§5·§10-2)
        var secretPaths = Set<String>()
        for p in all {
            let path = Indexer.nfc(DigestText.string(p["path"]) ?? "")
            let fl = ((p["flags"] as? [Any]) ?? []).compactMap { $0 as? String }
            if (fl.contains(TidyFlag.secret) && !((p["isDir"] as? Bool) ?? true)) || TidySecretName.matches((path as NSString).lastPathComponent) { secretPaths.insert(path) }
        }
        func masked(_ label: String) -> String {
            let parts = label.components(separatedBy: " › ")
            return (parts.dropLast() + [SynapseDigests.secretLabel]).joined(separator: " › ")
        }
        var placeRows: [[String: Any]] = [], rawRows: [[String: Any]] = [], omitted = 0
        for p in sorted {
            let path = Indexer.nfc(DigestText.string(p["path"]) ?? "")
            let zone = p["zone"] as? String ?? "other"
            let low = zone == "resource" || zone == "archive"
            let unfiled = zone == "loose" || zone == "inbox" || zone == "vault-root"
            if (level <= 1 && low) || (level == 0 && !(unfiled || zone == "workspace" || zone == "project")) { omitted += 1; continue }
            let flags = ((p["flags"] as? [Any]) ?? []).compactMap { $0 as? String }
            let isDir = (p["isDir"] as? Bool) ?? true
            let secretFile = (flags.contains(TidyFlag.secret) && !isDir) || TidySecretName.matches((path as NSString).lastPathComponent)
            var label = DigestText.string(p["label"]) ?? DigestText.string(p["name"]) ?? (path as NSString).lastPathComponent
            if secretFile { label = masked(label) }   // §5: 비밀 파일은 이름을 가린다 (위치의 마지막 조각만 바꾼다)
            var meta = TidyRefMeta()
            meta.zone = zone; meta.flags = flags; meta.isDir = isDir
            meta.vault = (p["vaultRoot"] as? String).map(Indexer.nfc) ?? vaultOf(path)
            meta.sourceRoot = sourceRoots.contains(path) || vaults.contains(path)
            let ref = add("P", path: path, title: label, kind: "place", meta: meta)
            var row: [String: Any] = ["ref": ref, "zone": zone, "at": label]
            if let n = DigestText.int(p["files"]) { row["files"] = n }
            if let lm = (p["lastModified"] as? NSNumber)?.doubleValue, lm > 0 {
                let d = WorkMapText.days(lm, now: nowD)
                row["modified"] = d == 0 ? "오늘" : "\(d)일 전"
            }
            if !low {
                row["kind"] = isDir ? "폴더" : "파일"
                if let n = DigestText.int(p["md"]), isDir { row["md"] = n }
                if let kinds = p["kinds"] as? [String: Any], isDir {
                    let top = kinds.compactMap { k, v -> (String, Int)? in DigestText.int(v).map { (k.isEmpty ? "확장자 없음" : k, $0) } }
                        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.prefix(3)
                    if !top.isEmpty { row["types"] = top.map { "\($0.0) \($0.1)" }.joined(separator: " · ") }
                }
                let keys = ((p["tickets"] as? [Any]) ?? []).compactMap { $0 as? String }
                if !keys.isEmpty {
                    row["tickets"] = keys.map { k -> String in
                        let st = ((jira[k] as? [String: Any])?["status"] as? String).map { DigestText.clip($0, 20) }
                        return st.map { "\(k) \($0)" } ?? k
                    }
                }
                let shown = flags.filter { $0 != TidyFlag.truncated }
                if !shown.isEmpty { row["flags"] = shown }
                let titleCount: Int
                switch level {
                case 3: titleCount = 5
                case 2: titleCount = unfiled ? 5 : 2
                case 1: titleCount = unfiled ? 2 : 0
                default: titleCount = 0
                }
                let titles = ((p["titles"] as? [Any]) ?? []).compactMap { $0 as? String }.filter { !TidySecretName.title($0) }
                    .map { DigestText.clip($0, 80) }.prefix(titleCount)
                if !titles.isEmpty && !secretFile { row["titles"] = Array(titles) }
            }
            placeRows.append(row)
            // 원자료 폴더 (R#)
            for r in ((p["raw"] as? [Any]) ?? []).compactMap({ $0 as? [String: Any] }) {
                guard let rp = DigestText.string(r["path"]).map(Indexer.nfc) else { continue }
                var rm = TidyRefMeta(); rm.zone = zone; rm.flags = [TidyFlag.rawData]; rm.vault = meta.vault
                rm.sourceRoot = sourceRoots.contains(rp)
                let rel = vaultOf(rp).map { rp == $0 ? "" : String(rp.dropFirst($0.count + 1)) } ?? (DigestText.string(r["rel"]) ?? (rp as NSString).lastPathComponent)
                var rlabel = WorkMapText.label(rel.isEmpty ? (rp as NSString).lastPathComponent : rel)
                if TidySecretName.inPath(rp) { rlabel = masked(rlabel) }
                let rr = add("R", path: rp, title: rlabel, kind: "raw", meta: rm)
                if rawRows.contains(where: { ($0["ref"] as? String) == rr }) { continue }
                var o: [String: Any] = ["ref": rr, "at": rlabel, "in": ref, "certain": (r["certain"] as? Bool) ?? false]
                if let n = DigestText.int(r["files"]) { o["files"] = n }
                if let kinds = r["kinds"] as? [String: Any] {
                    let top = kinds.compactMap { k, v -> (String, Int)? in DigestText.int(v).map { (k.isEmpty ? "확장자 없음" : k, $0) } }
                        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.prefix(3)
                    if !top.isEmpty { o["types"] = top.map { "\($0.0) \($0.1)" }.joined(separator: " · ") }
                }
                rawRows.append(o)
            }
        }
        input["places"] = placeRows
        if !rawRows.isEmpty { input["raw"] = rawRows }
        // 목적지 (D#)
        var dests: [[String: Any]] = []
        let destLimit = level >= 2 ? 400 : 150
        for d in ((c["destinations"] as? [Any]) ?? []).compactMap({ $0 as? [String: Any] }) {
            guard let path = DigestText.string(d["path"]).map(Indexer.nfc) else { continue }
            if dests.count >= destLimit { omitted += 1; continue }
            let isCode = (d["isCode"] as? Bool) ?? false
            var m = TidyRefMeta(); m.zone = isCode ? nil : d["zone"] as? String; m.code = isCode; m.vault = isCode ? nil : vaultOf(path)
            var label = DigestText.string(d["label"]) ?? (path as NSString).lastPathComponent
            if TidySecretName.inPath(path) { label = masked(label) }
            dests.append(["ref": add("D", path: path, title: label, kind: "dest", meta: m), "at": label, "zone": isCode ? "code" : (d["zone"] as? String ?? "other")])
        }
        input["destinations"] = dests
        // 볼트 규칙표 (place·frozen·landing)
        var policy: [String] = []
        for r in ((c["policy"] as? [Any]) ?? []).compactMap({ $0 as? [String: Any] }) {
            let kind = r["kind"] as? String ?? "", pat = r["pattern"] as? String ?? ""
            guard ["place", "frozen", "landing"].contains(kind), !pat.isEmpty, policy.count < 60 else { continue }
            var line = "\(kind): \(pat)"
            if let t = DigestText.string(r["target"]) { line += " → \(t)" }
            if kind == "frozen", let n = DigestText.string(r["note"]) { line += " (\(DigestText.clip(n, 60)))" }
            policy.append(line)
        }
        if !policy.isEmpty { input["vaultPolicy"] = policy }
        let learned = ((c["learned"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }.compactMap { l -> String? in
            guard let sig = l["signature"] as? String else { return nil }
            let st = l["state"] as? String ?? ""
            return "\(st == "auto" ? "자동" : st == "off" ? "끔" : "묻기") · \(DigestText.string(l["label"]) ?? TidySignature.label(sig))"
        }
        if !learned.isEmpty { input["learned"] = learned }
        let avoid = ((c["avoid"] as? [Any]) ?? []).compactMap { $0 as? String }.map { TidySignature.label($0) }
        if !avoid.isEmpty { input["avoid"] = avoid }
        func refOrLabel(_ path: String) -> String {
            let p = Indexer.nfc(path)
            for pre in ["P", "R", "D"] { if let r = byPath[pre + "|" + p] { return r } }
            let label = WorkMapText.label(vaultOf(p).map { p == $0 ? (p as NSString).lastPathComponent : String(p.dropFirst($0.count + 1)) } ?? (p as NSString).lastPathComponent)
            // 참조가 없는(줄이기로 빠진) 자리: 비밀 자리·비밀 이름이면 가린다
            return secretPaths.contains(p) || TidySecretName.inPath(p) ? masked(label) : label
        }
        // 알림(note)은 옮기는 제안이 아니라 다시 낼 걱정이 없으니 넣지 않는다(비밀 파일 알림이 대부분)
        let pending = ((c["pending"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }.filter { ($0["op"] as? String) != TidyOp.note }
            .prefix(40).map { x -> [String: Any] in
            var o: [String: Any] = ["op": x["op"] as? String ?? ""]
            o["from"] = ((x["from"] as? [Any]) ?? []).compactMap { $0 as? String }.map(refOrLabel)
            if let to = DigestText.string(x["to"]) { o["to"] = refOrLabel(to) }
            return o
        }
        if !pending.isEmpty { input["pending"] = Array(pending) }
        if omitted > 0 { input["omitted"] = omitted }
        return DigestBuilt(input: input, refs: refs)
    }
}

extension DigestNormalizer {
    /// §5 정리 계획 출력 → {summary, items:[TidyItem.json(origin "claude", signature "")], questions:[{text, path}]}.
    /// 모르는 참조는 버린다. new: 경로는 볼트 PARA 구역 아래만(.. · 절대 경로 · 숨김 조각 금지).
    /// 비밀 파일을 옮기는 항목(note 말고 모두), git·code 자리를 볼트로 옮기는 항목, 동결 자리 항목, 볼트·출처 루트를 옮기는 항목은 버린다.
    func tidy(_ o: [String: Any]) -> [String: Any]? {
        let summary = DigestNormalizer.line(o["summary"], 200)
        let vaults = refs.filter { $0.value.kind == "vault" }.sorted { (Int($0.key.dropFirst()) ?? 0) < (Int($1.key.dropFirst()) ?? 0) }.map { $0.value.docId }
        func key(_ v: Any?) -> String? {
            guard let s = v as? String else { return nil }
            let r = s.trimmingCharacters(in: CharacterSet(charactersIn: "[]() ").union(.whitespacesAndNewlines)).uppercased()
            return refs[r] == nil ? nil : r
        }
        var items: [[String: Any]] = [], seen = Set<String>()
        for x in DigestNormalizer.dicts(o["items"]) {
            guard items.count < 30, let op = DigestNormalizer.pick(x["op"], Array(TidyOp.all)) else { continue }
            // from: P#·R#만
            var froms: [(path: String, meta: TidyRefMeta, kind: String)] = []
            for f in (x["from"] as? [Any]) ?? [x["from"] as Any] {
                guard let r = key(f), let ref = refs[r], ref.kind == "place" || ref.kind == "raw" else { continue }
                if froms.contains(where: { $0.path == ref.docId }) { continue }
                froms.append((ref.docId, TidyRefMeta(ref.key), ref.kind))
            }
            if op == TidyOp.exclude {
                froms = froms.filter { $0.kind == "raw" || $0.meta.flags.contains(TidyFlag.rawData) }
            } else if op == TidyOp.merge {
                froms = Array(froms.prefix(1))
            }
            guard !froms.isEmpty else { continue }
            // 안전: 볼트·출처 루트, 볼트 자체, 동결, 비밀(알림 말고)
            if froms.contains(where: { $0.meta.sourceRoot || $0.meta.flags.contains(TidyFlag.vault) || vaults.contains($0.path) }) { continue }
            if froms.contains(where: { $0.meta.flags.contains(TidyFlag.frozen) }) { continue }
            if op != TidyOp.note && froms.contains(where: { $0.meta.flags.contains(TidyFlag.secret) }) { continue }
            // to
            var to: String? = nil, toInVault = false
            if op == TidyOp.move || op == TidyOp.merge {
                guard let raw = (x["to"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
                if raw.lowercased().hasPrefix("new:") {
                    let rel = String(raw.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                    guard let clean = DigestNormalizer.cleanNewPath(rel),
                          let vault = froms.compactMap({ $0.meta.vault }).first ?? vaults.first else { continue }
                    to = vault + "/" + clean; toInVault = true
                } else {
                    guard let r = key(raw), let ref = refs[r], ref.kind == "dest" else { continue }
                    let m = TidyRefMeta(ref.key)
                    to = ref.docId; toInVault = !m.code
                }
            } else if op == TidyOp.archive {
                toInVault = true   // Synapse가 <볼트>/4-Archive 아래로 정한다
            }
            if op == TidyOp.move || op == TidyOp.merge || op == TidyOp.archive {
                if toInVault && froms.contains(where: { $0.meta.flags.contains(TidyFlag.git) || $0.meta.flags.contains(TidyFlag.code) }) { continue }
            }
            if let t = to {
                // 자기 안쪽으로 옮기기, 이미 그 폴더에 있는 것
                if froms.contains(where: { t == $0.path || t.hasPrefix($0.path + "/") }) { continue }
                if froms.allSatisfy({ ($0.path as NSString).deletingLastPathComponent == t }) { continue }
            }
            let finalOp = (op == TidyOp.merge && !(froms.first?.meta.isDir ?? true)) ? TidyOp.move : op
            let dedupe = finalOp + "|" + froms.map { $0.path }.joined(separator: ",") + "|" + (to ?? "")
            guard seen.insert(dedupe).inserted else { continue }
            let evidence = ((x["evidence"] as? [Any]) ?? []).compactMap { $0 as? String }.map { DigestNormalizer.line($0, 40) }.filter { !$0.isEmpty }
            var title = DigestNormalizer.line(x["title"], 40)
            if title.isEmpty { title = TidySignature.label(TidySignature.of(op: finalOp, fromZone: froms.first?.meta.zone.flatMap { TidyZone(rawValue: $0) }, toParaRel: nil, toCode: false)) }
            let item = TidyItem(op: finalOp, from: froms.map { $0.path }, to: to, title: title,
                                reason: DigestNormalizer.line(x["reason"], 120), evidence: Array(evidence.prefix(4)),
                                certainty: DigestNormalizer.pick(x["certainty"], Array(TidyCertainty.all)) ?? TidyCertainty.unsure,
                                origin: "claude", group: TidyGroup.valid(DigestNormalizer.pick(x["group"], TidyGroup.order) ?? ""), signature: "")
            items.append(item.json)
        }
        var questions: [[String: Any]] = []
        for q in DigestNormalizer.dicts(o["questions"]) {
            guard questions.count < 5, let r = key(q["place"]), let ref = refs[r], ref.kind == "place" else { continue }
            let text = DigestNormalizer.line(q["text"], 80)
            guard !text.isEmpty, !questions.contains(where: { ($0["path"] as? String) == ref.docId }) else { continue }
            questions.append(["text": text, "path": ref.docId])
        }
        guard !summary.isEmpty || !items.isEmpty || !questions.isEmpty else { return nil }
        return ["summary": summary, "items": items, "questions": questions]
    }

    /// "new:" 뒤 볼트 기준 경로 검사: PARA 구역(_workspace·1-Projects·2-Areas·3-Resources·4-Archive) 아래 한 칸 이상,
    /// 절대 경로·".."·"."·숨김 조각·빈 조각·역슬래시 금지. 통과하면 NFC로 정리한 경로.
    static func cleanNewPath(_ rel: String) -> String? {
        var r = rel
        while r.hasSuffix("/") { r.removeLast() }
        guard !r.isEmpty, !r.hasPrefix("/"), !r.hasPrefix("~"), !r.contains("\\"), !r.contains("\0") else { return nil }
        let parts = r.components(separatedBy: "/")
        guard parts.count >= 2, SynapseDigests.tidyParaTops.contains(parts[0]) else { return nil }
        for p in parts {
            let t = p.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t == "." || t == ".." || t.hasPrefix(".") || t != p || p.count > 120 { return nil }
        }
        return Indexer.nfc(parts.joined(separator: "/"))
    }
}
