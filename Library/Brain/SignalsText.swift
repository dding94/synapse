import Foundation
import CryptoKit

// 본문 분석(줄 해시·제목·멈춘 곳·frontmatter status)과 유형·상태·프로젝트·보관본 규칙 (§4.3 · §4.7).

enum SignalText {
    static func sha1(_ s: String) -> String {
        Insecure.SHA1.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 줄 해시: 앞뒤 공백을 뗀 뒤 sha1 앞 8자리.
    static func lineHash(_ s: String) -> String {
        String(sha1(s.trimmingCharacters(in: .whitespaces)).prefix(8))
    }

    /// 처음 달라진 줄(1부터)과 바뀐 줄 수. 앞에서 비교하고, 앞이 다 같으면 끝의 삽입·삭제 위치.
    static func diff(old: [String], new: [String]) -> (line: Int, changed: Int) {
        let n = min(old.count, new.count)
        var p = 0
        while p < n && old[p] == new[p] { p += 1 }
        var s = 0
        while s < n - p && old[old.count - 1 - s] == new[new.count - 1 - s] { s += 1 }
        let changed = max(new.count - p - s, old.count - p - s)
        let line = new.isEmpty ? 1 : min(p, new.count - 1) + 1
        return (line, max(changed, p == old.count && p == new.count ? 0 : 1))
    }

    /// line 위(같은 줄 포함)의 가장 가까운 제목.
    static func heading(before line: Int, in headings: [(Int, Int, String)]) -> String? {
        headings.last(where: { $0.0 <= line })?.2
    }

    /// `#`~`######` 제목 줄이면 (단계, 제목).
    static func headingOf(_ line: String) -> (Int, String)? {
        guard line.hasPrefix("#") else { return nil }
        let level = line.prefix(while: { $0 == "#" }).count
        guard level <= 6 else { return nil }
        let rest = line.dropFirst(level)
        guard let c = rest.first, c == " " || c == "\t" else { return nil }
        var t = rest.trimmingCharacters(in: .whitespaces)
        while t.hasSuffix("#") { t.removeLast() }
        t = t.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : (level, t)
    }

    /// frontmatter가 끝나는 줄 번호(0부터, 닫는 `---` 줄). 없으면 nil.
    static func frontmatterEnd(_ lines: [String]) -> Int? {
        guard let f = lines.first, f.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        for i in 1..<min(lines.count, 200) {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t == "---" || t == "..." { return i }
        }
        return nil
    }

    /// 파일 앞 4KB frontmatter의 status 값 → 정해진 이름. 없거나 모르는 값이면 nil.
    static func frontmatterStatus(_ lines: [String]) -> String? {
        guard let end = frontmatterEnd(lines) else { return nil }
        var bytes = 0
        for i in 1..<end {
            bytes += lines[i].utf8.count + 1
            if bytes > 4096 { break }
            let l = lines[i]
            guard l.lowercased().hasPrefix("status:") else { continue }
            var v = l.dropFirst("status:".count).trimmingCharacters(in: .whitespaces).lowercased()
            if v.count >= 2, let q = v.first, (q == "\"" || q == "'"), v.last == q { v = String(v.dropFirst().dropLast()) }
            switch v {
            case "draft", "초안": return "초안"
            case "wip", "진행", "진행중", "진행 중", "in progress", "in-progress", "doing": return "진행"
            case "done", "완료": return "완료"
            case "superseded", "대체", "대체됨": return "대체됨"
            default: return nil
            }
        }
        return nil
    }

    static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

extension Signals {
    struct Analysis {
        var hash: String? = nil
        var lines: [String]? = nil            // 줄 해시 (md·txt)
        var headings: [(Int, Int, String)] = []
        var raw: [String] = []                // 원문 줄 (할 일 뽑기)
        var fmStatus: String? = nil
        var boxDone = 0, boxOpen = 0          // 모든 체크박스 (상태 규칙)
    }

    struct Features {
        var type: String
        var status: String?
        var project: String?
        var aiArchive: Bool
        var archived: Bool
        var excluded: Bool
    }

    /// 로컬 md·txt는 디스크 원문(2MB까지)을, 다른 형식은 색인 평문을 본다.
    func analyze(_ d: BrainDoc) -> Analysis {
        var a = Analysis()
        guard let path = d.absPath else { return a }
        guard Signals.textKinds.contains(d.kind) else {
            a.hash = SignalText.sha1(ctx.text(d))
            return a
        }
        var text: String
        if let data = FileManager.default.contents(atPath: path), data.count <= 2 * 1024 * 1024,
           let s = String(data: data, encoding: .utf8) {
            text = s
        } else {
            text = ctx.text(d)
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        if text.contains("\r") { text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") }
        a.hash = SignalText.sha1(text)
        let lines = text.components(separatedBy: "\n")
        a.raw = lines
        a.lines = lines.prefix(5000).map(SignalText.lineHash)
        let md = d.kind == "md" || d.kind == "markdown"
        if md {
            a.fmStatus = SignalText.frontmatterStatus(lines)
            var fence: Character? = nil
            let start = (SignalText.frontmatterEnd(lines) ?? -1) + 1
            for i in start..<lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if let c = t.first, c == "`" || c == "~", t.prefix(while: { $0 == c }).count >= 3 {
                    fence = fence == nil ? c : (fence == c ? nil : fence); continue
                }
                if fence != nil { continue }
                if let h = SignalText.headingOf(lines[i]) { a.headings.append((i + 1, h.0, h.1)) }
            }
        }
        for l in lines where l.contains("[") {
            if let m = Signals.checkbox(l) {
                if m.mark == "x" || m.mark == "X" { a.boxDone += 1 } else if m.mark == " " || m.mark == "/" { a.boxOpen += 1 }
            }
        }
        return a
    }

    func features(_ d: BrainDoc, analysis a: Analysis) -> Features {
        if !d.isLocal {
            let type = d.kind == "jira" ? "이슈" : (d.kind == "confluence" ? "페이지" : "기타")
            return Features(type: type, status: nil, project: d.kind == "jira" ? d.folder : nil,
                            aiArchive: false, archived: false, excluded: false)
        }
        let rel = d.paraPath          // v0.9 §3.2: 볼트 안 문서는 볼트 기준(데스크톱 출처 안의 볼트도 PARA로 읽는다)
        let comps = rel.split(separator: "/").map(String.init)
        let fileName = comps.last ?? rel
        let folders = Array(comps.dropLast())
        let name = (fileName as NSString).deletingPathExtension
        let top = folders.first ?? ""
        let excluded = folders.contains { $0 == "_Templates" || $0 == ".claude" || $0 == ".obsidian" } || fileName == "CLAUDE.md"
        let archived = top == "4-Archive" || folders.contains("_archive")
        let lowerRel = "/" + rel.lowercased()
        var aiArchive = lowerRel.contains("/archive/review/")
        if !aiArchive && top == "4-Archive" {
            aiArchive = folders.dropFirst().contains { f in
                let l = f.lowercased(); return l.contains("claude") || l.contains("context") || l.contains("review")
            }
            if !aiArchive && sessionsOn, let p = d.absPath {
                try? db.query("SELECT 1 FROM ai_writes WHERE path=? LIMIT 1", [.text(p.precomposedStringWithCanonicalMapping)]) { _ in aiArchive = true }
            }
        }
        let firstHeading = a.headings.first?.2 ?? ""
        let type: String
        if folders.contains("_Templates") { type = "템플릿" }
        else if aiArchive { type = "AI보관본" }
        else if SignalText.matches(name, "ADR-\\d+") || folders.contains("의사결정") { type = "ADR" }
        else if SignalText.matches(name, "TN-\\d+") || folders.contains("기술노트") { type = "TN" }
        else if name.uppercased() == "PROGRESS" { type = "진행현황" }
        else if rel.contains("주간보고") || SignalText.matches(name, "\\d+주차") { type = "주간보고" }
        else if SignalText.matches(name, "^\\d{4}-\\d{2}-\\d{2}$") { type = "데일리" }
        else if SignalText.matches(name + " " + firstHeading, "회의|미팅|meeting") { type = "회의록" }
        else if folders.contains("운영") { type = "운영" }
        else if top == "3-Resources" { type = "참고" }
        else if folders.contains("_workspace") || SignalText.matches(name, "설계|초안|draft") { type = "설계" }
        else { type = "기타" }

        var status = a.fmStatus
        if status == nil {
            if a.boxDone > 0 && a.boxOpen == 0 { status = "완료" }
            else if a.boxDone > 0 && a.boxOpen > 0 { status = "진행" }
            else if top == "4-Archive" { status = "완료" }
        }
        var project: String? = nil
        if ["1-Projects", "2-Areas", "4-Archive"].contains(top), comps.count >= 3 {
            project = projectAlias[aliasKey(d)]?[comps[1]] ?? comps[1]
        }
        return Features(type: type, status: status, project: project, aiArchive: aiArchive, archived: archived, excluded: excluded)
    }

    /// 같은 볼트에 `2-Areas/X`와 `1-Projects/X-…`가 있으면 X로 묶는다.
    func rebuildProjectAlias(_ docs: [BrainDoc]) {
        var names: [String: Set<String>] = [:]
        for d in docs where d.isLocal {
            let c = d.paraPath.split(separator: "/", maxSplits: 2)
            guard c.count == 3, ["1-Projects", "2-Areas", "4-Archive"].contains(String(c[0])) else { continue }
            names[aliasKey(d), default: []].insert(String(c[1]))
        }
        var out: [String: [String: String]] = [:]
        for (src, set) in names {
            for n in set {
                guard let dash = n.firstIndex(of: "-") else { continue }
                let head = String(n[..<dash])
                if !head.isEmpty && head != n && set.contains(head) { out[src, default: [:]][n] = head }
            }
        }
        projectAlias = out
    }

    /// v0.9: 별칭 묶음 키 — 볼트 안 문서는 볼트 루트(여러 출처가 한 볼트를 나눠 덮어도 같은 묶음), 밖이면 출처.
    func aliasKey(_ d: BrainDoc) -> String {
        if d.paraRel != nil, let p = d.absPath, let v = ctx.vaults.vault(forAbs: p) { return "vault:" + v }
        return d.sourceId
    }

    func apply(features f: Features, analysis a: Analysis, to s: inout DocState) {
        s.type = f.type; s.status = f.status; s.project = f.project
        s.aiArchive = f.aiArchive ? 1 : 0; s.archived = f.archived ? 1 : 0; s.excluded = f.excluded ? 1 : 0
        if let h = a.hash { s.contentHash = h }
        if let l = a.lines { s.lineHashes = BrainFormat.json(l) }
        if a.lines != nil { s.headings = BrainFormat.json(a.headings.map { [$0.0, $0.1, $0.2] as [Any] }) }
    }

    // MARK: doc_state 읽기·쓰기

    private static let stateCols = """
    doc_id, source_id, path, content_hash, line_hashes, headings, type, status, project, author, author_session,
    ai_archive, archived, excluded, first_seen, last_change, last_human, last_ai, last_open, stopped_line, stopped_heading,
    open_tasks, done_tasks, due_min, updated
    """

    func loadState(_ id: String) -> DocState? {
        var out: DocState? = nil
        try? db.query("SELECT \(Signals.stateCols) FROM doc_state WHERE doc_id=?", [.text(id)]) { r in
            func t(_ i: Int32) -> String? { r.isNull(i) ? nil : r.text(i) }
            func d(_ i: Int32) -> Double? { r.isNull(i) ? nil : r.double(i) }
            var s = DocState(docId: r.text(0), sourceId: r.text(1), path: r.text(2))
            s.contentHash = t(3); s.lineHashes = t(4); s.headings = t(5); s.type = t(6); s.status = t(7); s.project = t(8)
            s.author = t(9); s.authorSession = t(10)
            s.aiArchive = Int(r.int(11)); s.archived = Int(r.int(12)); s.excluded = Int(r.int(13))
            s.firstSeen = d(14); s.lastChange = d(15); s.lastHuman = d(16); s.lastAI = d(17); s.lastOpen = d(18)
            s.stoppedLine = r.isNull(19) ? nil : Int(r.int(19)); s.stoppedHeading = t(20)
            s.openTasks = Int(r.int(21)); s.doneTasks = Int(r.int(22)); s.dueMin = t(23); s.updated = d(24)
            out = s
        }
        return out
    }

    func writeState(_ s: DocState) {
        func t(_ v: String?) -> SQLValue { v.map { .text($0) } ?? .null }
        func d(_ v: Double?) -> SQLValue { v.map { .double($0) } ?? .null }
        let args: [SQLValue] = [
            .text(s.docId), .text(s.sourceId), .text(s.path), t(s.contentHash), t(s.lineHashes), t(s.headings),
            t(s.type), t(s.status), t(s.project), t(s.author), t(s.authorSession),
            .int(Int64(s.aiArchive)), .int(Int64(s.archived)), .int(Int64(s.excluded)),
            d(s.firstSeen), d(s.lastChange), d(s.lastHuman), d(s.lastAI), d(s.lastOpen),
            s.stoppedLine.map { .int(Int64($0)) } ?? .null, t(s.stoppedHeading),
            .int(Int64(s.openTasks)), .int(Int64(s.doneTasks)), t(s.dueMin), d(s.updated),
        ]
        let cols = Signals.stateCols.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let sets = cols.dropFirst().map { "\($0)=excluded.\($0)" }.joined(separator: ", ")
        _ = try? db.run("INSERT INTO doc_state(\(Signals.stateCols)) VALUES(\(Array(repeating: "?", count: cols.count).joined(separator: ",")))"
                        + " ON CONFLICT(doc_id) DO UPDATE SET \(sets)", args)
    }
}
