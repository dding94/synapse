import Foundation

// 출발지·목적지·자리 판단 (§6.2·§6.3). 통계는 색인 doc_tf·links를 읽기 전용으로 SELECT한다.

/// 볼트의 프로젝트 폴더와 묶은 이름 (§4.7 정규화: 2-Areas/X 와 1-Projects/X-… → X).
struct OrgProjects {
    var folders: [String: [String]] = [:]     // 이름 → ["2-Areas/검색", "1-Projects/검색-설계"]
    var nameOf: [String: String] = [:]        // "1-Projects/검색-설계" → "검색"

    func projectOf(_ rel: String) -> String? {
        let c = rel.split(separator: "/").map(String.init)
        guard c.count >= 3, ["1-Projects", "2-Areas", "4-Archive"].contains(c[0]) else { return nil }
        return nameOf[c[0] + "/" + c[1]] ?? c[1]
    }
}

/// 자리 후보 하나.
struct OrgPlacement {
    var to: String                 // 폴더 상대 경로, 끝에 "/"
    var confidence: Double
    var reasons: [String]
    var ruleKey: String
}

extension Organizer {

    func projects(_ v: OrgVault) -> OrgProjects {
        var raw: [(top: String, name: String)] = []
        let fm = FileManager.default
        for top in ["1-Projects", "2-Areas", "4-Archive"] {
            for d in ((try? fm.contentsOfDirectory(atPath: v.abs(top))) ?? []).sorted() where !d.hasPrefix(".") && isDir(v.abs(top + "/" + d)) {
                raw.append((top, Indexer.nfc(d)))
            }
        }
        let names = Set(raw.map { $0.name })
        var p = OrgProjects()
        for r in raw {
            var n = r.name
            if let dash = n.firstIndex(of: "-") {
                let head = String(n[..<dash])
                if !head.isEmpty && names.contains(head) { n = head }
            }
            p.nameOf[r.top + "/" + r.name] = n
            p.folders[n, default: []].append(r.top + "/" + r.name)
        }
        return p
    }

    // MARK: 구역 판정

    func isArchived(_ rel: String) -> Bool { rel.hasPrefix("4-Archive/") || rel.contains("/_archive/") || rel.hasPrefix("_archive/") }

    func isAIArchive(_ d: BrainDoc) -> Bool {
        let rel = d.relPath
        if rel.contains("/archive/review/") { return true }
        if rel.hasPrefix("4-Archive/") {
            let parts = rel.lowercased().split(separator: "/").dropLast()
            if parts.contains(where: { $0.contains("claude") || $0.contains("context") || $0.contains("review") }) { return true }
        }
        var flag = false
        try? ctx.db.sql.query("SELECT ai_archive FROM doc_state WHERE doc_id=?", [.text(d.id)]) { flag = $0.int(0) == 1 }
        return flag
    }

    /// 템플릿 폴더 패턴("2-Areas/{프로젝트}/_workspace/")이 rel의 앞부분과 맞는가.
    static func folderMatches(_ pattern: String, _ rel: String) -> Bool {
        if !pattern.contains("{") { return rel.lowercased().hasPrefix(pattern.lowercased()) }
        var re = "^"
        for part in pattern.components(separatedBy: "/") where !part.isEmpty {
            re += part.hasPrefix("{") ? "[^/]+/" : NSRegularExpression.escapedPattern(for: part) + "/"
        }
        return rel.range(of: re, options: [.regularExpression, .caseInsensitive]) != nil
    }

    func isFrozen(_ rel: String, _ rules: [PolicyRule]) -> Bool {
        let r = rel.hasSuffix("/") ? rel : rel + "/"
        return rules.contains { $0.kind == "frozen" && Organizer.folderMatches($0.pattern, r) }
    }

    /// exclude 규칙. asSource면 "출발지로만 제외"(4-Archive)도 본다.
    func isExcluded(_ rel: String, _ rules: [PolicyRule], asSource: Bool) -> Bool {
        let comps = rel.split(separator: "/").map(String.init)
        if comps.contains(where: { $0.hasPrefix(".") }) { return true }
        let name = comps.last ?? rel
        for r in rules where r.kind == "exclude" {
            if r.target == "출발지" && !asSource { continue }
            if r.pattern.hasSuffix("/") {
                let f = String(r.pattern.dropLast())
                if !f.contains("/") { if comps.dropLast().contains(where: { $0.lowercased() == f.lowercased() }) { return true } }
                else if Organizer.folderMatches(r.pattern, rel) { return true }
            } else if r.pattern.hasPrefix("*.") {
                if name.lowercased().hasSuffix(String(r.pattern.dropFirst()).lowercased()) { return true }
            } else if name == r.pattern { return true }
        }
        return false
    }

    enum Landing { case root, top, projectWorkspace }

    func landing(_ rel: String) -> Landing? {
        if !rel.contains("/") { return .root }
        if rel.hasPrefix("_workspace/") || rel.hasPrefix("_Inbox/") { return .top }
        if rel.range(of: #"^(1-Projects|2-Areas)/[^/]+/_workspace/"#, options: .regularExpression) != nil { return .projectWorkspace }
        return nil
    }

    func placeRule(for rel: String, _ rules: [PolicyRule]) -> PolicyRule? {
        let name = Organizer.fileName(rel)
        return rules.first { r in
            r.kind == "place" && r.target != nil &&
                name.range(of: r.pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// 출발지(§6.2): landing의 md 중 excluded·frozen·ai_archive가 아닌 것. 프로젝트 _workspace는 place 패턴에 맞는 것만.
    func isSource(_ d: BrainDoc, _ v: OrgVault, _ rules: [PolicyRule]) -> Bool {
        guard d.isLocal, d.sourceId == v.sourceId, Organizer.isMarkdown(d.relPath), let l = landing(d.relPath) else { return false }
        if isExcluded(d.relPath, rules, asSource: true) || isFrozen(d.relPath, rules) || isAIArchive(d) { return false }
        if l == .projectWorkspace && placeRule(for: d.relPath, rules) == nil { return false }
        return sourceProblem(v, d.relPath) == nil
    }

    /// 옮길 파일 자체의 문제: 심볼릭 링크이거나 실제 위치가 볼트 밖.
    func sourceProblem(_ v: OrgVault, _ rel: String) -> String? {
        let abs = v.abs(rel)
        if let t = (try? FileManager.default.attributesOfItem(atPath: abs))?[.type] as? FileAttributeType, t == .typeSymbolicLink {
            return "심볼릭 링크 문서는 옮기지 않아요"
        }
        let real = Indexer.nfc(Indexer.realPath(abs))
        if !real.hasPrefix(v.root + "/") || real.lowercased() != Indexer.nfc(abs).lowercased() { return "볼트 밖을 가리키는 문서는 옮기지 않아요" }
        return nil
    }

    /// 목적지로 쓸 수 있는 폴더인가: 이미 있고, frozen·exclude가 아니다.
    func destinationProblem(_ v: OrgVault, _ folder: String, _ rules: [PolicyRule]) -> String? {
        let f = Organizer.folderKey(folder)
        if f.isEmpty { return nil }
        let abs = v.abs(String(f.dropLast()))
        if !isDir(abs) { return "없는 폴더예요" }
        let real = Indexer.nfc(Indexer.realPath(abs))
        if !real.hasPrefix(v.root + "/") { return "볼트 밖 폴더예요" }
        if real.lowercased() != Indexer.nfc(abs).lowercased() { return "심볼릭 링크 폴더예요" }
        if isFrozen(f, rules) { return "동결 폴더예요" }
        if isExcluded(f + "x.md", rules, asSource: false) { return "제외 폴더예요" }
        return nil
    }

    /// 템플릿 목적지를 프로젝트 이름으로 푼다. 있는 폴더만.
    func resolveTarget(_ v: OrgVault, _ template: String, project: String, _ proj: OrgProjects) -> (String?, String) {
        guard template.contains("{프로젝트}") else { return (isDir(v.abs(template)) ? template : nil, template) }
        let top = template.split(separator: "/").first.map(String.init) ?? ""
        var names = [project]
        for f in proj.folders[project] ?? [] where f.hasPrefix(top + "/") { names.append(String(f.dropFirst(top.count + 1))) }
        var first = ""
        for n in names {
            let t = template.replacingOccurrences(of: "{프로젝트}", with: n)
            if first.isEmpty { first = t }
            if isDir(v.abs(String(t.dropLast()))) { return (t, t) }
        }
        return (nil, first)
    }

    // MARK: 프로젝트 추정 (경로 → 본문 이름 → 링크 이웃 다수결)

    func projectSignals(_ d: BrainDoc, _ v: OrgVault, _ proj: OrgProjects, stats: OrgStats, usePath: Bool) -> (String?, String, [String: Double]) {
        if usePath, let p = proj.projectOf(d.relPath) { return (p, "경로", [p: 1]) }
        let text = Korean.normalize(d.title + "\n" + ctx.text(d, maxChars: 20_000))
        var score: [String: Double] = [:]
        for (name, folders) in proj.folders {
            let variants = Set([name] + folders.map { Organizer.fileName($0) }).filter { $0.count >= 2 }
            if variants.contains(where: { Relate.occurs(Korean.normalize($0), in: text) }) { score[name, default: 0] += 1 }
        }
        if score.count == 1 { return (score.keys.first, "본문에 나온 이름", score) }
        var nb: [String: Double] = [:]
        for n in stats.neighbors[d.id] ?? [] {
            if let doc = ctx.doc(id: n), doc.sourceId == v.sourceId, let p = proj.projectOf(doc.relPath) { nb[p, default: 0] += 1 }
        }
        let ranked = nb.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
        if let top = ranked.first, top.value > (ranked.dropFirst().first?.value ?? 0), score.isEmpty || score[top.key] != nil {
            return (top.key, "링크 이웃", score.merging(nb) { $0 + $1 })
        }
        return (nil, "", score.merging(nb) { $0 + $1 })
    }

    /// 문서 하나의 자리 후보 (신뢰도 내림차순). diag는 템플릿 폴더가 없을 때의 메모.
    func place(_ d: BrainDoc, _ v: OrgVault, _ rules: [PolicyRule], usePath: Bool = true) -> (list: [OrgPlacement], diag: String?) {
        let proj = projects(v)
        let stats = self.stats(v, rules)
        if let rule = placeRule(for: d.relPath, rules), let tpl = rule.target {
            let ruleKey = "place:" + rule.pattern + "→" + tpl
            let why = "볼트 CLAUDE.md: " + rule.note.replacingOccurrences(of: "파일명 ", with: "").replacingOccurrences(of: "트리 예시 ", with: "") + " → " + tpl
            let (p, how, sig) = projectSignals(d, v, proj, stats: stats, usePath: usePath)
            if let p = p {
                let (t, want) = resolveTarget(v, tpl, project: p, proj)
                guard let to = t else { return ([], "폴더가 없어 제안하지 않아요: " + want) }
                if destinationProblem(v, to, rules) != nil { return ([], "목적지가 동결·제외 폴더예요: " + to) }
                return ([OrgPlacement(to: to, confidence: 0.99, reasons: [why, "프로젝트 \(p) (\(how))"], ruleKey: ruleKey)], nil)
            }
            var out: [OrgPlacement] = []
            let order = proj.folders.keys.sorted { (sig[$0] ?? 0, $1) > (sig[$1] ?? 0, $0) }
            for p in order {
                if let to = resolveTarget(v, tpl, project: p, proj).0, destinationProblem(v, to, rules) == nil {
                    out.append(OrgPlacement(to: to, confidence: 0.6, reasons: [why, "프로젝트를 몰라 후보로 보여요"], ruleKey: ruleKey))
                }
                if out.count == 3 { break }
            }
            return (out, out.isEmpty ? "규칙에 맞는 프로젝트 폴더가 없어요" : nil)
        }
        return (statPlacements(d, v, rules, stats: stats, proj: proj), nil)
    }

    /// 제자리 판정 (§6.3-4).
    func isInPlace(_ d: BrainDoc, _ v: OrgVault, _ rules: [PolicyRule]) -> Bool {
        let rel = d.relPath
        switch landing(rel) {
        case .none:
            guard let rule = placeRule(for: rel, rules), let tpl = rule.target else { return true }
            let proj = projects(v)
            guard let p = proj.projectOf(rel), let to = resolveTarget(v, tpl, project: p, proj).0 else { return true }
            return Organizer.folderKey(Organizer.parent(rel)).lowercased() == to.lowercased()
        case .projectWorkspace?: return placeRule(for: rel, rules) == nil
        default: return false
        }
    }
}
