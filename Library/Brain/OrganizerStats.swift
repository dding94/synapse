import Foundation

// 자리 판단 통계 (§6.3-2) = 0.4·폴더 중심값 코사인 + 0.4·링크 이웃 다수결 + 0.2·프로젝트 이름·이슈 키 일치.
// 색인(index.sqlite)은 ctx.index!.writer로 SELECT만 한다. 자체 점검(한 개 빼고 맞히기)도 여기.

final class OrgStats {
    var vectors: [String: [String: Double]] = [:]     // docId → 단위 벡터(tf·idf)
    var sums: [String: [String: Double]] = [:]        // 폴더("…/", 깊이 3 이하) → 벡터 합
    var counts: [String: Int] = [:]
    var docFolder: [String: String] = [:]             // docId → 폴더(깊이 3에서 자름)
    var neighbors: [String: Set<String>] = [:]        // docId → 링크로 이어진 문서
    var folderKeys: [String: Set<String>] = [:]       // 폴더 → 이슈 키
}

extension Organizer {

    static func truncated(_ folder: String, depth: Int = 3) -> String {
        Organizer.folderKey(folder.split(separator: "/").prefix(depth).joined(separator: "/"))
    }

    func stats(_ v: OrgVault, _ rules: [PolicyRule]) -> OrgStats {
        let key = v.sourceId + "|" + String(ctx.index?.dataVersion() ?? -1) + "|" + String(ctx.docs.count) + "|" + PolicyParser.hash(rules)
        if let c = statsCache, c.key == key { return c.model }
        let s = OrgStats()
        let docs = ctx.docs.filter { $0.sourceId == v.sourceId && $0.isLocal && Organizer.isMarkdown($0.relPath) }
        let ids = Set(docs.map { $0.id })
        var tf: [String: [(String, Double)]] = [:]
        if let w = ctx.index?.writer {
            try? w.query("SELECT doc_id, term, tf FROM doc_tf") { r in
                let id = r.text(0)
                if ids.contains(id) { tf[id, default: []].append((r.text(1), r.double(2))) }
            }
            try? w.query("SELECT src, dst FROM links WHERE kind IN ('link','embed')") { r in
                let a = r.text(0), b = r.text(1)
                guard ids.contains(a), ids.contains(b), a != b else { return }
                s.neighbors[a, default: []].insert(b); s.neighbors[b, default: []].insert(a)
            }
        }
        var df: [String: Int] = [:]
        for (_, list) in tf { for (t, _) in list { df[t, default: 0] += 1 } }
        let n = Double(max(docs.count, 1))
        for (id, list) in tf {
            var vec: [String: Double] = [:], norm = 0.0
            for (t, c) in list {
                let w = (1 + log(max(c, 1))) * log(n / Double(df[t] ?? 1))
                if w > 0 { vec[t] = w; norm += w * w }
            }
            if norm > 0 { let r = sqrt(norm); for k in vec.keys { vec[k]! /= r } }
            s.vectors[id] = vec
        }
        for d in docs {
            let f = Organizer.truncated(d.folder)
            if f.isEmpty || landing(d.relPath) != nil || isArchived(d.relPath) || isExcluded(d.relPath, rules, asSource: false)
                || isFrozen(d.relPath, rules) || isAIArchive(d) || d.relPath.contains("/review/") { continue }
            s.docFolder[d.id] = f
            s.counts[f, default: 0] += 1
            for (t, w) in s.vectors[d.id] ?? [:] { s.sums[f, default: [:]][t, default: 0] += w }
            for k in d.issueKeys { s.folderKeys[f, default: []].insert(k) }
        }
        statsCache = (key, s)
        return s
    }

    /// 통계 후보. loo = 자체 점검(자기 벡터를 자기 폴더 중심값에서 뺀다).
    func statPlacements(_ d: BrainDoc, _ v: OrgVault, _ rules: [PolicyRule], stats s: OrgStats, proj: OrgProjects, loo: Bool = false) -> [OrgPlacement] {
        let vec = s.vectors[d.id] ?? [:]
        let own = loo ? s.docFolder[d.id] : nil
        let here = Organizer.folderKey(d.folder)
        let text = Korean.normalize(d.title + "\n" + ctx.text(d, maxChars: 20_000))
        let nbs = s.neighbors[d.id] ?? []
        var nbCount: [String: Int] = [:]
        for b in nbs { if let f = s.docFolder[b] { nbCount[f, default: 0] += 1 } }
        let notes = compiled(v).folderNotes
        var out: [OrgPlacement] = []
        for (f, cnt) in s.counts {
            let self1 = own == f ? 1 : 0
            if cnt - self1 < (loo ? 2 : 3) { continue }
            if !loo && f.lowercased() == here.lowercased() { continue }
            var dot = 0.0, norm = 0.0
            for (t, w) in s.sums[f] ?? [:] {
                let cw = w - (self1 == 1 ? (vec[t] ?? 0) : 0)
                norm += cw * cw
                if let x = vec[t] { dot += x * cw }
            }
            let a = norm > 0 ? max(0, dot / sqrt(norm)) : 0
            let b = nbs.isEmpty ? 0 : Double(nbCount[f] ?? 0) / Double(nbs.count)
            var c = 0.0, cWhy = ""
            let names = [proj.projectOf(f + "x.md"), Organizer.fileName(String(f.dropLast()))].compactMap { $0 }.filter { $0.count >= 2 }
            if let nm = names.first(where: { Relate.occurs(Korean.normalize($0), in: text) }) { c = 1; cWhy = "'\(nm)' 이름이 나와요" }
            else if let k = d.issueKeys.first(where: { s.folderKeys[f]?.contains($0) ?? false }) { c = 1; cWhy = "이슈 키 \(k)가 같아요" }
            let score = 0.4 * a + 0.4 * b + 0.2 * c
            guard score >= 0.05 else { continue }
            var why: [String] = []
            let depth = f.split(separator: "/").count
            if let note = notes.first(where: { $0.key.split(separator: "/").count == depth && Organizer.folderMatches($0.key, f) })?.value {
                why.append("볼트 CLAUDE.md: \(Organizer.fileName(String(f.dropLast())))/ = \(note)")
            }
            if a >= 0.2 { why.append("같은 폴더 문서 \(cnt - self1)개와 주제가 비슷해요") }
            if b > 0 { why.append("링크한 문서 \(nbs.count)개 중 \(nbCount[f] ?? 0)개가 이 폴더에 있어요") }
            if c > 0 { why.append(cWhy) }
            out.append(OrgPlacement(to: f, confidence: min(0.95, (score * 1000).rounded() / 1000), reasons: Array(why.prefix(3)), ruleKey: "stats:" + f))
        }
        out.sort { $0.confidence > $1.confidence || ($0.confidence == $1.confidence && $0.to < $1.to) }
        return Array(out.prefix(3))
    }

    /// 자체 점검: 1-Projects·2-Areas·3-Resources 문서로 한 개 빼고 맞히기 + 템플릿 폴더 없음 메모.
    func diagnostics() -> [String: Any] {
        var n = 0, top1 = 0, top3 = 0
        var grades: [String: (n: Int, ok: Int)] = [:]
        var notes: [String] = []
        var sources: [[String: Any]] = []
        for v in vaults() {
            let rules = rules(for: v)
            let s = stats(v, rules), proj = projects(v)
            for d in ctx.docs where d.sourceId == v.sourceId && d.isLocal && Organizer.isMarkdown(d.relPath) {
                if isSource(d, v, rules) {
                    let r = place(d, v, rules)
                    if let dg = r.diag { notes.append(d.relPath + " — " + dg) }
                    sources.append(["path": d.relPath, "inPlace": isInPlace(d, v, rules),
                                    "candidates": r.list.map { ["to": $0.to, "confidence": Organizer.grade($0.confidence), "score": $0.confidence] }])
                }
                guard let truth = s.docFolder[d.id], ["1-Projects/", "2-Areas/", "3-Resources/"].contains(where: { d.relPath.hasPrefix($0) }) else { continue }
                var list: [OrgPlacement]
                if placeRule(for: d.relPath, rules) != nil { list = place(d, v, rules, usePath: false).list }
                else { list = statPlacements(d, v, rules, stats: s, proj: proj, loo: true) }
                list = list.filter { $0.confidence >= 0.6 }
                n += 1
                let picks = list.map { Organizer.truncated($0.to) }
                if picks.first == truth { top1 += 1 }
                if picks.prefix(3).contains(truth) { top3 += 1 }
                if let f = list.first {
                    let g = Organizer.grade(f.confidence)
                    grades[g, default: (0, 0)].n += 1
                    if picks.first == truth { grades[g]!.ok += 1 }
                }
            }
        }
        func ratio(_ a: Int, _ b: Int) -> Double { b == 0 ? 0 : (Double(a) / Double(b) * 1000).rounded() / 1000 }
        var g: [String: Any] = [:]
        for (k, x) in grades { g[k] = ["n": x.n, "correct": x.ok, "precision": ratio(x.ok, x.n)] }
        return ["loo": ["docs": n, "top1": ratio(top1, n), "top3": ratio(top3, n), "grades": g],
                "missingFolders": notes, "sources": sources,
                "policy": ["approved": policyApproved, "rules": storedRules().count], "pending": pendingCount()]
    }
}
