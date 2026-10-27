import Foundation

// 할 일·기한·우선 표시·데일리·PROGRESS·원격 Jira 상태 (§4.8).

extension Signals {
    enum DueSpec { case date(String), monthDay(Int, Int), weekday(Int) }

    struct TaskItem {
        var line: Int?
        var norm: String
        var state: String
        var due: DueSpec?
        var prio: String?
        var heading: String?
        var origin: String
    }

    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    static let checkboxRE = re(#"^\s*(?:[-*+]|\d+[.)])\s+\[([ xX/\-])\]\s+(.+)$"#)
    static let bulletRE = re(#"^\s*(?:[-*+]|\d+[.)])\s+(.+)$"#)
    static let dueRE: [(NSRegularExpression, Int)] = [
        (re(#"(?:📅|⏳|due:)\s*(\d{4}-\d{2}-\d{2})"#), 1),
        (re(#"(?<![\d/])(\d{1,2})/(\d{1,2})\s*(?:까지|마감|기한)|~\s*(\d{1,2})/(\d{1,2})(?![\d/])"#), 2),
        (re(#"(\d{1,2})월\s*(\d{1,2})일\s*(?:까지|마감)"#), 3),
        (re(#"(월|화|수|목|금|토|일)요일\s*까지"#), 4),
    ]
    static let prioTokens: [(String, String)] = [
        ("⏫", "highest"), ("🔺", "highest"), ("[긴급]", "highest"), ("#긴급", "highest"), ("!!", "highest"),
        ("🔼", "high"), ("[중요]", "high"), ("#중요", "high"),
    ]

    static func checkbox(_ line: String) -> (mark: Character, text: String)? {
        let ns = line as NSString
        guard let m = checkboxRE.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (ns.substring(with: m.range(at: 1)).first ?? " ", ns.substring(with: m.range(at: 2)))
    }

    static func taskID(docId: String, norm: String) -> String {
        String(SignalText.sha1(docId + "\n" + norm).prefix(16))
    }

    /// 본문에서 기한·우선 표시를 떼고 정규화한 글, 기한, 우선.
    static func parseTaskText(_ raw: String) -> (norm: String, due: DueSpec?, prio: String?) {
        var text = raw
        var due: DueSpec? = nil
        for (rx, kind) in dueRE {
            let ns = text as NSString
            guard let m = rx.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { continue }
            func g(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
            switch kind {
            case 1: due = .date(g(1)!)
            case 2:
                if let mo = g(1).flatMap(Int.init), let d = g(2).flatMap(Int.init) { due = .monthDay(mo, d) }
                else if let mo = g(3).flatMap(Int.init), let d = g(4).flatMap(Int.init) { due = .monthDay(mo, d) }
            case 3: if let mo = g(1).flatMap(Int.init), let d = g(2).flatMap(Int.init) { due = .monthDay(mo, d) }
            default: if let w = g(1), let i = ["일", "월", "화", "수", "목", "금", "토"].firstIndex(of: w) { due = .weekday(i + 1) }
            }
            text = ns.replacingCharacters(in: m.range, with: " ")
            break
        }
        var prio: String? = nil
        for (tok, p) in prioTokens where text.contains(tok) {
            if prio == nil || (prio == "high" && p == "highest") { prio = p }
            text = text.replacingOccurrences(of: tok, with: " ")
        }
        let norm = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        return (norm, due, prio)
    }

    /// 기한을 yyyy-MM-dd로. 연도가 없으면 base 기준 (180일 넘게 과거면 다음 해).
    static func resolveDue(_ spec: DueSpec?, base: Date) -> String? {
        guard let spec = spec else { return nil }
        let cal = Calendar.current
        let day = cal.startOfDay(for: base)
        switch spec {
        case .date(let s):
            return s
        case .monthDay(let m, let d):
            guard (1...12).contains(m), (1...31).contains(d) else { return nil }
            let y = cal.component(.year, from: day)
            guard var date = cal.date(from: DateComponents(year: y, month: m, day: d)) else { return nil }
            if day.timeIntervalSince(date) > 180 * 86400, let n = cal.date(byAdding: .year, value: 1, to: date) { date = n }
            return BrainFormat.dayKey(date)
        case .weekday(let w):
            let cur = cal.component(.weekday, from: day)
            let ahead = (w - cur + 7) % 7
            return cal.date(byAdding: .day, value: ahead, to: day).map(BrainFormat.dayKey)
        }
    }

    // MARK: v0.8 §5.8-4 지침 줄 (할 일이 아닌 체크박스)

    /// 에이전트 지침 파일. CLAUDE.md는 이미 제외(excluded) 대상이다.
    static func isGuideFile(_ fileName: String) -> Bool {
        ["agents.md", "claude.local.md", "agents.override.md"].contains(fileName.lowercased())
    }

    // 규칙 제목: 이 아래 줄은 모두 지침이다. 기준 제목: 완료 조건 아래에는 "…검증한다." 같은 규칙 문장과 "회의 준비" 같은 진짜 할 일이 섞인다.
    // "가이드"만으로는 보지 않는다(운영 가이드의 체크리스트는 대개 진짜 작업 단계다).
    private static let ruleHeadingRE = try! NSRegularExpression(
        pattern: #"(?:원칙|규칙|지침|가이드라인|수칙|컨벤션|(?:^|[^a-z])(?:guidelines?|principles?|rules|conventions?))$"#,
        options: [.caseInsensitive])
    private static let criteriaHeadingRE = try! NSRegularExpression(
        pattern: #"(?:기준|(?:^|[^a-z])(?:criteria|definition of done|dod))$"#, options: [.caseInsensitive])

    enum GuideHeading { case none, rules, criteria }

    /// 원칙·규칙·지침 같은 제목(rules)인가, 검증·완료 기준 같은 제목(criteria)인가.
    /// 끝말로만 본다("자료 정리 TODO"는 해당 없음). 끝의 괄호 설명·기호는 뗀다("완료 기준 (Acceptance)" → "완료 기준").
    static func guideHeading(_ heading: String) -> GuideHeading {
        var t = heading.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: #"\s*[\(（\[][^\)）\]]*[\)）\]]\s*$"#, with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: ":：.·-—–#*_`~!?").union(.whitespaces).union(.symbols))
        guard !t.isEmpty else { return .none }
        let r = NSRange(location: 0, length: (t as NSString).length)
        if ruleHeadingRE.firstMatch(in: t, range: r) != nil { return .rules }
        if criteriaHeadingRE.firstMatch(in: t, range: r) != nil { return .criteria }
        return .none
    }
    static func isGuideHeading(_ heading: String) -> Bool { guideHeading(heading) != .none }

    /// "…검증한다." "…보고하지 않는다."처럼 규칙을 적은 문장인가. "배포 일정 공유"·"디자인 시안 합의" 같은 할 일은 아니다.
    static func isRuleSentence(_ line: String) -> Bool {
        var t = line.trimmingCharacters(in: .whitespaces)
        t = t.replacingOccurrences(of: #"^(?:[-*+]|\d+[.)])\s+(?:\[[^\]]?\]\s+)?"#, with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: ".。!)」』\"'`*_~ ").union(.whitespaces))
        return t.hasSuffix("다")
    }

    /// 이 목록 줄을 지침으로 보고 할 일에서 뺄까. 가장 가까운 제목만 보고, 맨 위 # 제목(문서 이름)은 보지 않는다.
    static func skipAsGuide(nearest: (Int, String)?, line: String) -> Bool {
        guard let h = nearest, h.0 > 1 else { return false }
        switch guideHeading(h.1) {
        case .rules: return true
        case .criteria: return isRuleSentence(line)
        case .none: return false
        }
    }

    /// 로컬 md·txt 원문에서 할 일을 뽑는다.
    func extractTasks(_ d: BrainDoc, analysis a: Analysis) -> [TaskItem] {
        if Signals.isGuideFile((d.relPath as NSString).lastPathComponent) { return [] }
        let name = ((d.relPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let md = d.kind == "md" || d.kind == "markdown"
        let daily = md && SignalText.matches(name, "^\\d{4}-\\d{2}-\\d{2}$")
        let progress = name.uppercased() == "PROGRESS"
        var out: [TaskItem] = []
        var seen = Set<String>()
        var stack: [(Int, String)] = []
        var fence: Character? = nil
        let start = md ? (SignalText.frontmatterEnd(a.raw) ?? -1) + 1 : 0
        guard start < a.raw.count else { return [] }
        for i in start..<a.raw.count {
            let line = a.raw[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            if let c = t.first, c == "`" || c == "~", t.prefix(while: { $0 == c }).count >= 3 {
                fence = fence == nil ? c : (fence == c ? nil : fence); continue
            }
            if fence != nil { continue }
            if md, let h = SignalText.headingOf(line) {
                while let last = stack.last, last.0 >= h.0 { stack.removeLast() }
                stack.append(h); continue
            }
            guard t.hasPrefix("-") || t.hasPrefix("*") || t.hasPrefix("+") || t.first?.isNumber == true else { continue }
            if Signals.skipAsGuide(nearest: stack.last, line: t) { continue }   // v0.8 §5.8-4: 지침 제목·완료 기준의 규칙 문장
            // 절 분류: 안쪽 제목부터 보고 처음 맞는 것
            var progSection: Bool? = nil   // true = 다음·진행, false = 완료
            var dailySection = false
            for h in stack.reversed() {
                if progress && progSection == nil {
                    if SignalText.matches(h.1, "완료|done") { progSection = false }
                    else if SignalText.matches(h.1, "다음|진행|예정|todo|next") { progSection = true }
                }
                if daily && SignalText.matches(h.1, "내일|다음|todo|할 일") { dailySection = true }
            }
            if progSection == false { continue }
            var item: TaskItem? = nil
            if let cb = Signals.checkbox(line) {
                let p = Signals.parseTaskText(cb.text)
                let state: String
                switch cb.mark { case "x", "X": state = "done"; case "/": state = "doing"; case "-": state = "cancelled"; default: state = "open" }
                let origin = daily ? "daily" : (progSection == true ? "progress" : "checkbox")
                item = TaskItem(line: i + 1, norm: p.norm, state: state, due: p.due, prio: p.prio, heading: stack.last?.1, origin: origin)
            } else if (daily && dailySection) || progSection == true {
                let ns = line as NSString
                guard let m = Signals.bulletRE.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
                let p = Signals.parseTaskText(ns.substring(with: m.range(at: 1)))
                item = TaskItem(line: i + 1, norm: p.norm, state: "open", due: p.due, prio: p.prio, heading: stack.last?.1,
                                origin: daily ? "daily" : "progress")
            }
            if let it = item, !it.norm.isEmpty, !seen.contains(it.norm) { seen.insert(it.norm); out.append(it) }
        }
        return out
    }

    /// 문서의 할 일을 다시 뽑아 tasks와 비교하고 doc_state 집계를 고친다.
    func syncTasks(_ d: BrainDoc, analysis a: Analysis, features f: Features, initial: Bool, state s: inout DocState) {
        guard d.isLocal, Signals.textKinds.contains(d.kind), a.lines != nil else { return }
        let items = (f.excluded || f.aiArchive || f.archived) ? [] : extractTasks(d, analysis: a)
        var existing: [String: (state: String, first: Double?, doneAt: Double?)] = [:]
        try? db.query("SELECT id, state, first_seen, done_at FROM tasks WHERE doc_id=? AND origin != 'jira'", [.text(d.id)]) {
            existing[$0.text(0)] = ($0.text(1), $0.isNull(2) ? nil : $0.double(2), $0.isNull(3) ? nil : $0.double(3))
        }
        let t = nowTS
        var keep = Set<String>()
        for it in items {
            let id = Signals.taskID(docId: d.id, norm: it.norm)
            keep.insert(id)
            let old = existing[id]
            let first = old?.first ?? (initial ? d.modified.timeIntervalSince1970 : t)
            let due = Signals.resolveDue(it.due, base: Date(timeIntervalSince1970: first))
            var doneAt = old?.doneAt
            if it.state == "done" {
                if old == nil { doneAt = initial ? nil : t } else if old!.state != "done" { doneAt = t }
            } else { doneAt = nil }
            _ = try? db.run("""
            INSERT INTO tasks(id, doc_id, line, text, heading, state, due, prio, origin, first_seen, last_seen, done_at, gone)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,0)
            ON CONFLICT(id) DO UPDATE SET doc_id=excluded.doc_id, line=excluded.line, text=excluded.text, heading=excluded.heading,
              state=excluded.state, due=excluded.due, prio=excluded.prio, origin=excluded.origin, last_seen=excluded.last_seen,
              done_at=excluded.done_at, gone=0
            """, [.text(id), .text(d.id), it.line.map { .int(Int64($0)) } ?? .null, .text(it.norm),
                  it.heading.map { .text($0) } ?? .null, .text(it.state), due.map { .text($0) } ?? .null,
                  it.prio.map { .text($0) } ?? .null, .text(it.origin), .double(first), .double(t),
                  doneAt.map { .double($0) } ?? .null])
        }
        for id in existing.keys where !keep.contains(id) {
            _ = try? db.run("UPDATE tasks SET gone=1 WHERE id=?", [.text(id)])
        }
        countTasks(d.id, into: &s)
    }

    func countTasks(_ docId: String, into s: inout DocState) {
        s.openTasks = 0; s.doneTasks = 0; s.dueMin = nil
        try? db.query("""
        SELECT SUM(state IN ('open','doing')), SUM(state='done'), MIN(CASE WHEN state IN ('open','doing') THEN due END)
        FROM tasks WHERE doc_id=? AND gone=0
        """, [.text(docId)]) { r in
            s.openTasks = Int(r.int(0)); s.doneTasks = Int(r.int(1)); s.dueMin = r.isNull(2) ? nil : r.text(2)
        }
    }

    // MARK: 원격 (§4.8 원격 Jira)

    func loadRemoteStates() -> [String: String?] {
        var out: [String: String?] = [:]
        try? db.query("SELECT doc_id, status FROM remote_state") { out[$0.text(0)] = $0.isNull(1) ? nil : $0.text(1) }
        return out
    }

    /// 원격 문서: 본문 비교 없이 meta만 본다. 바뀌었으면 true.
    func processRemote(_ d: BrainDoc, existing: Bool, seen: Double, remote: [String: String?]) -> Bool {
        let mt = d.modified.timeIntervalSince1970
        let isJira = d.kind == "jira" && !d.meta.isEmpty
        let statusMoved = isJira && remote[d.id].map { $0 != d.meta["status"] } ?? isJira
        guard !existing || mt > seen + 0.001 || statusMoved else { return false }
        var s = (existing ? loadState(d.id) : nil) ?? DocState(docId: d.id, sourceId: d.sourceId, path: d.relPath)
        if s.firstSeen == nil { s.firstSeen = (d.created ?? d.modified).timeIntervalSince1970 }
        s.path = d.relPath
        apply(features: features(d, analysis: Analysis()), analysis: Analysis(), to: &s)
        s.lastChange = max(s.lastChange ?? 0, mt)
        s.updated = mt
        if isJira { remoteJira(d, hadRow: remote[d.id] != nil, oldStatus: remote[d.id] ?? nil, state: &s) }
        writeState(s)
        return existing
    }

    private func remoteJira(_ d: BrainDoc, hadRow: Bool, oldStatus: String?, state s: inout DocState) {
        let m = d.meta
        let key = d.relPath.split(separator: ":").last.map(String.init) ?? d.relPath
        let status = m["status"], cat = m["statusCategory"] ?? ""
        // mine이 없으면(내 계정 확인 실패) 이전 값을 유지한다 — 할 일이 사라지지 않게
        var mine = m["mine"] == "1"
        if m["mine"] == nil {
            try? db.query("SELECT mine FROM remote_state WHERE doc_id=?", [.text(d.id)]) { mine = $0.int(0) == 1 }
        }
        let t = nowTS
        let moved = hadRow && oldStatus != status
        if moved {
            var detail: [String: Any] = [:]
            if let o = oldStatus { detail["from"] = o }
            if let n = status { detail["to"] = n }
            insertActivity(ts: t, docId: d.id, path: d.relPath, kind: "status", actor: .unknown, origin: "jira", session: nil, detail: detail)
        }
        func v(_ x: String?) -> SQLValue { x.flatMap { $0.isEmpty ? nil : SQLValue.text($0) } ?? .null }
        _ = try? db.run("""
        INSERT INTO remote_state(doc_id, key, title, status, status_cat, priority, due, mine, updated, changed)
        VALUES(?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(doc_id) DO UPDATE SET key=excluded.key, title=excluded.title, status=excluded.status,
          status_cat=excluded.status_cat, priority=excluded.priority, due=excluded.due, mine=excluded.mine,
          updated=excluded.updated, changed=COALESCE(excluded.changed, remote_state.changed)
        """, [.text(d.id), .text(key), .text(d.title), v(status), v(cat), v(m["priority"]), v(m["duedate"]),
              .int(mine ? 1 : 0), .double(t), moved ? .double(t) : .null])
        let id = Signals.taskID(docId: d.id, norm: key)
        var old: (state: String, first: Double?)? = nil
        try? db.query("SELECT state, first_seen FROM tasks WHERE id=?", [.text(id)]) { old = ($0.text(0), $0.isNull(1) ? nil : $0.double(1)) }
        if mine && cat != "done" {
            let prio: String? = WorkText.jiraPrio(m["priority"])   // 한국어 이름(가장 높음·긴급·높음)도 읽는다
            _ = try? db.run("""
            INSERT INTO tasks(id, doc_id, line, text, heading, state, due, prio, origin, first_seen, last_seen, done_at, gone)
            VALUES(?,?,NULL,?,NULL,?,?,?,'jira',?,?,NULL,0)
            ON CONFLICT(id) DO UPDATE SET text=excluded.text, state=excluded.state, due=excluded.due, prio=excluded.prio,
              last_seen=excluded.last_seen, done_at=NULL, gone=0
            """, [.text(id), .text(d.id), .text(d.title), .text(cat == "indeterminate" ? "doing" : "open"), v(m["duedate"]),
                  prio.map { .text($0) } ?? .null, .double(old?.first ?? t), .double(t)])
        } else if cat == "done" {
            if let o = old, o.state != "done" {
                _ = try? db.run("UPDATE tasks SET state='done', done_at=?, last_seen=?, gone=0 WHERE id=?", [.double(t), .double(t), .text(id)])
            }
        } else if old != nil {
            _ = try? db.run("UPDATE tasks SET gone=1 WHERE id=?", [.text(id)])
        }
        countTasks(d.id, into: &s)
    }
}
