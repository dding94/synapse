import Foundation

// 규칙표 (§6.1). 볼트 CLAUDE.md를 LLM 없이 결정적으로 읽어 policy_rules에 둔다. 파일은 읽기만 한다.

struct PolicyRule: Equatable {
    var kind: String        // place | frozen | exclude | landing | duty
    var pattern: String     // place: 이름 정규식. frozen·exclude·landing: 폴더("…/") 또는 파일 이름. duty: "ADR"
    var target: String?     // place: 폴더 템플릿("2-Areas/{프로젝트}/의사결정/"). exclude "출발지" = 출발지로만 제외
    var source: String      // CLAUDE.md 절대 경로 · "기본" · "mcp:<이름>" · "<root>/(v0.4 제외 폴더)"
    var note: String

    var key: String { kind + "\t" + pattern + "\t" + (target ?? "") }
    func applies(to v: OrgVault) -> Bool { source == "기본" || source.hasPrefix("mcp:") || source.hasPrefix(v.root + "/") }
}

/// 한 번 컴파일한 결과. folderNotes는 트리 주석(카드 근거 문장용).
struct PolicyCompile {
    var rules: [PolicyRule] = []
    var folderNotes: [String: String] = [:]
    var sources: [(path: String, mtime: Double)] = []
}

enum PolicyParser {
    static let kindOrder = ["place": 0, "frozen": 1, "exclude": 2, "landing": 3, "duty": 4]
    private static func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    private static let nameRx = rx(#"파일명\**\s*[:：]\s*\**\s*`([^`]+)`"#)
    private static let placeRx = rx(#"위치\**\s*[:：]\s*\**\s*`([^`]+)`"#)
    private static let tickRx = rx(#"`([^`\n]+)`"#)
    private static let frozenWords = ["동결", "참조용", "읽기 전용"]

    /// `{프로젝트명}`·`{프로젝트}` → `{프로젝트}`, `{주제}`·`{주제별 폴더}` → `{주제}`.
    static func normalizePlaceholders(_ s: String) -> String {
        guard s.contains("{") else { return s }
        let re = rx(#"\{([^{}]*)\}"#)
        let ns = s as NSString
        var out = "", pos = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: pos, length: m.range.location - pos))
            let inner = ns.substring(with: m.range(at: 1))
            out += inner.contains("프로젝트") ? "{프로젝트}" : inner.contains("주제") ? "{주제}" : "{" + inner + "}"
            pos = m.range.location + m.range.length
        }
        return out + ns.substring(from: pos)
    }

    /// "ADR-XXX_제목.md" → "^ADR-\d+.*\.md$". XXX·NNN이 없으면 이름 그대로.
    static func namePattern(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        guard let r = stem.range(of: "XXX") ?? stem.range(of: "NNN") else {
            return "^" + NSRegularExpression.escapedPattern(for: name) + "$"
        }
        let pre = String(stem[..<r.lowerBound]), rest = String(stem[r.upperBound...])
        return "^" + NSRegularExpression.escapedPattern(for: pre) + "\\d+" + (rest.isEmpty ? "" : ".*")
            + (ext.isEmpty ? "" : "\\." + NSRegularExpression.escapedPattern(for: ext)) + "$"
    }

    static func isFrozenNote(_ s: String) -> Bool { frozenWords.contains { s.contains($0) } }

    /// 상대 폴더 경로를 볼트 기준으로: PARA 최상위로 시작하지 않으면 CLAUDE.md 폴더(base) 아래로 본다.
    static func anchor(_ p: String, base: String) -> String {
        let t = p.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let top = t.split(separator: "/").first.map(String.init) ?? ""
        let isTop = top.range(of: #"^\d-"#, options: .regularExpression) != nil || top.hasPrefix("_")
        return (base.isEmpty || isTop) ? t : base + "/" + t
    }

    /// 코드 블록 안팎으로 줄을 나눈다.
    static func split(_ text: String) -> (fences: [[String]], prose: [String]) {
        var fences: [[String]] = [], prose: [String] = [], cur: [String]? = nil
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") || t.hasPrefix("~~~") {
                if let c = cur { fences.append(c); cur = nil } else { cur = [] }
                continue
            }
            if cur != nil { cur!.append(raw) } else { prose.append(raw) }
        }
        if let c = cur { fences.append(c) }
        return (fences, prose)
    }

    /// 트리 블록: (경로, 폴더인가, 주석). 경로는 base 기준이 아니라 트리 루트 기준.
    static func treeEntries(_ lines: [String]) -> [(path: String, folder: Bool, note: String)] {
        let branch: Set<Character> = ["├", "└"]
        let idxs = lines.compactMap { l -> Int? in l.firstIndex(where: { branch.contains($0) }).map { l.distance(from: l.startIndex, to: $0) } }
        guard !idxs.isEmpty else { return [] }
        let unit = max(1, idxs.filter { $0 > 0 }.min() ?? 4)
        var stack: [String] = [], out: [(String, Bool, String)] = []
        for l in lines {
            guard let bi = l.firstIndex(where: { branch.contains($0) }) else { continue }
            let depth = l.distance(from: l.startIndex, to: bi) / unit
            var rest = l[l.index(after: bi)...].drop(while: { $0 == "─" || $0 == "-" || $0 == " " })
            var note = ""
            if let arrow = rest.firstIndex(of: "←") {
                note = rest[rest.index(after: arrow)...].trimmingCharacters(in: .whitespaces)
                rest = rest[..<arrow]
            }
            var name = normalizePlaceholders(rest.trimmingCharacters(in: .whitespaces))
            // "검색-설계/ (동결, 참조용)" 처럼 주석이 괄호로 붙은 경우
            if let paren = name.range(of: " (") , name.hasSuffix(")") {
                if note.isEmpty { note = String(name[paren.lowerBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " ()")) }
                name = String(name[..<paren.lowerBound])
            }
            if name.isEmpty { continue }
            stack = Array(stack.prefix(depth))
            while stack.count < depth { stack.append("?") }
            let prefix = stack.isEmpty ? "" : stack.joined(separator: "/") + "/"
            if name.hasSuffix("/") {
                let n = String(name.dropLast())
                out.append((prefix + n + "/", true, note))
                stack.append(n)
            } else {
                out.append((prefix + name, false, note))
            }
        }
        return out
    }

    /// CLAUDE.md 하나 → 규칙들. base = 그 파일의 볼트 상대 폴더("" = 루트).
    static func compile(_ text: String, base: String, source: String, notes: inout [String: String]) -> [PolicyRule] {
        var rules: [PolicyRule] = [], treeRules: [PolicyRule] = []   // 트리 예시는 파일명·위치 쌍 뒤에 둔다(같은 규칙이면 쌍의 설명이 남는다)
        let (fences, prose) = split(text)
        for block in fences {
            for e in treeEntries(block) {
                let path = anchor(e.path, base: base)
                if e.folder {
                    if !e.note.isEmpty { notes[path + "/"] = e.note }
                    if isFrozenNote(e.note) { treeRules.append(PolicyRule(kind: "frozen", pattern: path + "/", target: nil, source: source, note: e.note)) }
                } else {
                    let name = Organizer.fileName(path)
                    guard name.contains("XXX") || name.contains("NNN"), path.contains("{") else { continue }
                    treeRules.append(PolicyRule(kind: "place", pattern: namePattern(name), target: Organizer.folderKey(Organizer.parent(path)),
                                            source: source, note: "트리 예시 " + name))
                }
            }
        }
        // 절(제목) 단위로 파일명·위치 쌍을 찾는다
        var sections: [[String]] = [[]]
        for l in prose {
            if l.hasPrefix("#") { sections.append([l]) } else { sections[sections.count - 1].append(l) }
        }
        for sec in sections {
            let s = sec.joined(separator: "\n"), ns = s as NSString
            let full = NSRange(location: 0, length: ns.length)
            if let n = nameRx.firstMatch(in: s, range: full), let p = placeRx.firstMatch(in: s, range: full) {
                let name = ns.substring(with: n.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let place = normalizePlaceholders(ns.substring(with: p.range(at: 1)))
                rules.append(PolicyRule(kind: "place", pattern: namePattern(name), target: Organizer.folderKey(anchor(place, base: base)),
                                        source: source, note: "파일명 " + name))
            }
        }
        for l in prose {
            let t = l.trimmingCharacters(in: .whitespaces)
            // duty: 프로젝트_요약.md + ADR + 갱신|업데이트 가 한 문장에
            if t.contains("프로젝트_요약.md") && t.contains("ADR") && (t.contains("갱신") || t.contains("업데이트")) {
                let ns = t as NSString
                var target = base.isEmpty ? "2-Areas/{프로젝트}/프로젝트_요약.md" : base + "/프로젝트_요약.md"
                for m in tickRx.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                    let v = ns.substring(with: m.range(at: 1))
                    if v.hasSuffix("프로젝트_요약.md") && v.contains("/") { target = anchor(normalizePlaceholders(v), base: base) }
                }
                rules.append(PolicyRule(kind: "duty", pattern: "ADR", target: target, source: source,
                                        note: String(t.trimmingCharacters(in: CharacterSet(charactersIn: "-*• ")).prefix(100))))
            }
            // 본문 줄의 `폴더/` + 동결·참조용·읽기 전용
            if isFrozenNote(t) {
                let ns = t as NSString
                for m in tickRx.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                    let v = ns.substring(with: m.range(at: 1))
                    if v.hasSuffix("/") && !v.contains("{") {
                        rules.append(PolicyRule(kind: "frozen", pattern: anchor(v, base: base) + "/", target: nil, source: source,
                                                note: String(t.prefix(80))))
                    }
                }
            }
        }
        return rules + treeRules
    }

    static func defaults(_ v: OrgVault) -> [PolicyRule] {
        var r: [PolicyRule] = []
        for f in ["_ref/", "_Templates/", ".obsidian/", ".claude/", ".trash/"] { r.append(PolicyRule(kind: "exclude", pattern: f, target: nil, source: "기본", note: "기본 제외 폴더")) }
        for f in ["*.canvas", "CLAUDE.md", "PROGRESS.md", "프로젝트_요약.md", "임팩트_로그.md", "_Resources-MOC.md"] {
            r.append(PolicyRule(kind: "exclude", pattern: f, target: nil, source: "기본", note: "기본 제외 파일"))
        }
        r.append(PolicyRule(kind: "exclude", pattern: "4-Archive/", target: "출발지", source: "기본", note: "출발지로만 제외"))
        for f in v.excludeFolders {
            r.append(PolicyRule(kind: "exclude", pattern: f + "/", target: nil, source: v.root + "/(v0.4 제외 폴더)", note: "색인 제외 폴더"))
        }
        r.append(PolicyRule(kind: "landing", pattern: "/", target: nil, source: "기본", note: "볼트 루트의 낱개 파일"))
        r.append(PolicyRule(kind: "landing", pattern: "_workspace/", target: nil, source: "기본", note: "최상위 작업 공간"))
        r.append(PolicyRule(kind: "landing", pattern: "_Inbox/", target: nil, source: "기본", note: "최상위 수신함"))
        for top in ["1-Projects", "2-Areas"] {
            r.append(PolicyRule(kind: "landing", pattern: top + "/{프로젝트}/_workspace/", target: nil, source: "기본", note: "place 패턴에 맞는 파일만"))
        }
        return r
    }

    static func sorted(_ rules: [PolicyRule]) -> [PolicyRule] {
        var seen = Set<String>(), out: [PolicyRule] = []
        for r in rules where seen.insert(r.key).inserted { out.append(r) }
        return out.sorted { a, b in
            let ka = kindOrder[a.kind] ?? 9, kb = kindOrder[b.kind] ?? 9
            if ka != kb { return ka < kb }
            if a.pattern != b.pattern { return a.pattern < b.pattern }
            return (a.target ?? "") < (b.target ?? "")
        }
    }

    static func hash(_ rules: [PolicyRule]) -> String {
        Organizer.sha1(sorted(rules).map { $0.key }.joined(separator: "\n"))
    }
}
