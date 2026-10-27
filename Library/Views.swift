import Foundation
import AppKit

// 보기 모델 (docs/CONNECT.md §3.6 · §4). v0.2 app.js computeView()와 같은 의미를 실제 자료로 만든다.
// 결과는 Foundation 값(String·Int·Double·Bool·[Any]·[String: Any]·NSNull)만 쓴다.

/// 색인 한 시점의 메모리 사본 (불변). 색인 큐에서 만들고 잠금으로 바꿔 끼운다.
final class Snapshot {
    struct Doc {
        let m: DocMetaRow
        let short: String
        let normTitle: String
        let normTags: [String]
        let normAliases: [String]
        let choTitle: String
        let choOther: [String]
    }
    struct Edge { let to: Int; let kind: String }
    struct Rel { let to: Int; let score: Double; let kind: String; let reason: String }

    let docs: [Doc]
    let index: [String: Int]
    let byRowid: [Int64: Int]
    var out: [[Edge]]
    var inc: [[Edge]]
    var related: [[Rel]]       // 양방향 합친 자동 연결 (점수순)
    var nb: [Set<Int>]         // 명시 + 자동 이웃
    var explicitNb: [Set<Int>]
    var degree: [Int]
    var unresolved: [[String]]
    var terms: [[String]]
    var tagCount: [String: Int] = [:]          // 표시 태그 → 문서 수
    var tagOrder: [(String, Int)] = []
    var tagDocs: [String: [Int]] = [:]         // 소문자 태그 → 문서
    var tagDisplay: [String: String] = [:]
    var linkCount = 0
    let sources: [String: SourceConfig]
    let obsidianInstalled: Bool
    var tickets: [Views.Ticket?] = []          // v0.6: Jira 문서의 상태 묶음 (그 밖은 nil)
    var clusters: [Views.Cluster] = []         // v0.6: 묶음 지도의 묶음
    var clusterOf: [Int] = []                  // 문서 → 묶음 번호
    var clusterIndex: [String: Int] = [:]      // 묶음 키 → 묶음 번호

    static func shortTitle(_ t: String) -> String {
        let c = Array(t)
        return c.count > 14 ? String(c[0..<13]) + "…" : t
    }

    init(metas: [DocMetaRow], graph: Store.GraphRows, sources: [SourceConfig], obsidianInstalled: Bool) {
        let enabled = Set(sources.filter { $0.enabled }.map { $0.id })
        self.sources = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.obsidianInstalled = obsidianInstalled
        let ms = metas.filter { enabled.contains($0.sourceId) }
        docs = ms.map { m in
            Doc(m: m, short: Snapshot.shortTitle(m.title), normTitle: Korean.normalize(m.title),
                normTags: m.tags.map(Korean.normalize), normAliases: m.aliases.map(Korean.normalize),
                choTitle: Korean.choseong(m.title), choOther: (m.tags + m.aliases).map(Korean.choseong))
        }
        var idx: [String: Int] = [:], rid: [Int64: Int] = [:]
        for (i, d) in docs.enumerated() { idx[d.m.id] = i; rid[d.m.rowid] = i }
        index = idx; byRowid = rid
        let n = docs.count
        out = Array(repeating: [], count: n); inc = Array(repeating: [], count: n)
        related = Array(repeating: [], count: n)
        nb = Array(repeating: [], count: n); explicitNb = Array(repeating: [], count: n)
        unresolved = Array(repeating: [], count: n); terms = Array(repeating: [], count: n)
        degree = Array(repeating: 0, count: n)
        for (s, d, k) in graph.links {
            guard let a = idx[s], let b = idx[d], a != b else { continue }
            out[a].append(Edge(to: b, kind: k)); inc[b].append(Edge(to: a, kind: k))
            explicitNb[a].insert(b); explicitNb[b].insert(a)
        }
        var relSeen = Set<Int64>()
        for (s, d, score, k, r) in graph.related {
            guard let a = idx[s], let b = idx[d], a != b else { continue }
            if relSeen.insert(Int64(a) << 32 | Int64(b)).inserted { related[a].append(Rel(to: b, score: score, kind: k, reason: r)) }
            if relSeen.insert(Int64(b) << 32 | Int64(a)).inserted { related[b].append(Rel(to: a, score: score, kind: k, reason: r)) }
        }
        for i in 0..<n {
            related[i].sort { $0.score > $1.score }
            nb[i] = explicitNb[i].union(related[i].map { $0.to })
            degree[i] = nb[i].count
        }
        linkCount = nb.reduce(0) { $0 + $1.count } / 2
        for (s, t) in graph.unresolved { if let a = idx[s] { unresolved[a].append(t) } }
        for (s, t, _) in graph.terms { if let a = idx[s] { terms[a].append(t) } }
        for (i, d) in docs.enumerated() {
            for t in d.m.tags {
                let k = t.lowercased()
                if tagDisplay[k] == nil { tagDisplay[k] = t }
                tagDocs[k, default: []].append(i)
            }
        }
        for (k, ids) in tagDocs { tagCount[tagDisplay[k] ?? k] = Set(ids).count }
        tagOrder = tagCount.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
        tickets = docs.map { Views.ticket($0.m) }
        let built = Views.buildClusters(docs: docs, sources: self.sources)
        clusters = built.clusters; clusterOf = built.of
        for (i, c) in clusters.enumerated() { clusterIndex[c.key] = i }
    }

    static let empty = Snapshot(metas: [], graph: Store.GraphRows(), sources: [], obsidianInstalled: false)
}

enum Views {
    static let kindLabels: [String: String] = [
        "md": "마크다운", "markdown": "마크다운", "txt": "텍스트", "text": "텍스트", "pdf": "PDF", "docx": "워드", "doc": "워드",
        "rtf": "RTF", "odt": "ODT", "html": "웹 문서", "htm": "웹 문서", "hwpx": "한글", "confluence": "Confluence", "jira": "Jira",
    ]

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone.current
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static func iso(_ t: Double) -> String { isoFormatter.string(from: Date(timeIntervalSince1970: t)) }

    /// 상대 날짜: 오늘 / 어제 / N일 전 / M월 D일 / YYYY. M. D.
    static func relDate(_ t: Double, now: Date = Date()) -> String {
        let cal = Calendar.current
        let then = Date(timeIntervalSince1970: t)
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: then), to: cal.startOfDay(for: now)).day ?? 0
        if days <= 0 { return "오늘" }
        if days == 1 { return "어제" }
        if days < 7 { return "\(days)일 전" }
        let c = cal.dateComponents([.year, .month, .day], from: then)
        if c.year == cal.component(.year, from: now) { return "\(c.month ?? 0)월 \(c.day ?? 0)일" }
        return "\(c.year ?? 0). \(c.month ?? 0). \(c.day ?? 0)."
    }

    /// 받침 유무로 조사 고르기 (과/와)
    static func josa(_ word: String, _ withBatchim: String, _ without: String) -> String {
        if let u = word.unicodeScalars.last, Korean.isSyllable(u.value) {
            return word + ((u.value - 0xAC00) % 28 != 0 ? withBatchim : without)
        }
        return word + without
    }

    static func summary(_ i: Int, _ s: Snapshot) -> [String: Any] {
        let d = s.docs[i].m
        let src = s.sources[d.sourceId]
        var out: [String: Any] = [
            "id": d.id, "title": d.title, "short": s.docs[i].short, "group": d.group, "kind": d.kind,
            "kindLabel": kindLabels[d.kind] ?? d.kind.uppercased(), "source": d.sourceId,
            "sourceKind": src?.kind.rawValue ?? "folder", "sourceName": src?.name ?? "", "path": d.displayPath,
            "updated": iso(d.modified), "tags": d.tags, "degree": s.degree[i],
        ]
        addTicketFields(s.tickets[i], to: &out)   // v0.6 C1: status · statusGroup · mine · priority · issueType
        return out
    }

    static func node(_ i: Int, _ s: Snapshot, _ emphasis: String) -> [String: Any] {
        let d = s.docs[i]
        var out: [String: Any] = ["id": d.m.id, "label": d.short, "fullLabel": d.m.title, "kind": "doc", "group": d.m.group,
                                  "degree": s.degree[i], "emphasis": emphasis, "docKind": d.m.kind]
        addTicketFields(s.tickets[i], to: &out)
        return out
    }

    // MARK: 검색 (제목 50 / 태그·별칭 32 / 본문 12, 동의어 ×0.28, 초성 40, 최근 30일 +3)

    struct Terms { var exact: [String]; var expanded: [String]; var cho: [String]? }
    struct Ranked { let i: Int; var score: Double; var reason: String }

    static func terms(_ query: String) -> Terms {
        let exact = Korean.queryTerms(query)
        if Korean.isChoseongQuery(query) { return Terms(exact: exact, expanded: [], cho: exact) }
        return Terms(exact: exact, expanded: Korean.expand(exact), cho: nil)
    }

    static func search(_ terms: Terms, snap s: Snapshot, store: Store) -> [Ranked] {
        var ranked: [Ranked] = []
        let now = Date().timeIntervalSince1970
        if let cho = terms.cho {
            for (i, d) in s.docs.enumerated() {
                var score = 0.0
                for t in cho {
                    let key = t.replacingOccurrences(of: " ", with: "")
                    if d.choTitle.contains(key) || d.choOther.contains(where: { $0.contains(key) }) { score += 40 }
                }
                if score > 0 { ranked.append(Ranked(i: i, score: score, reason: "초성")) }
            }
        } else {
            var hits: [String: Set<Int>] = [:]
            var cands = Set<Int>()
            for t in terms.exact + terms.expanded {
                guard let expr = Korean.ftsExpression(term: t) else { continue }
                let set = Set(store.readFTS(expr, limit: 400).compactMap { s.byRowid[$0] })
                hits[t] = set
                cands.formUnion(set)
            }
            for i in cands {
                let d = s.docs[i]
                var score = 0.0, best = -1.0, reason = ""
                func hit(_ t: String, _ syn: Bool) {
                    var v = 0.0, f = ""
                    if d.normTitle.contains(t) { v = 50; f = "제목" }
                    else if d.normTags.contains(where: { $0.contains(t) }) { v = 32; f = "태그" }
                    else if d.normAliases.contains(where: { $0.contains(t) }) { v = 32; f = "별칭" }
                    else if hits[t]?.contains(i) == true { v = 12; f = "본문" }
                    if v == 0 { return }
                    let w = syn ? v * 0.28 : v
                    score += w
                    if w > best { best = w; reason = syn ? "연관어 ‘" + t + "’" : f }
                }
                terms.exact.forEach { hit($0, false) }
                terms.expanded.forEach { hit($0, true) }
                if score > 0 {
                    if now - d.m.modified < 30 * 86400 { score += 3 }
                    ranked.append(Ranked(i: i, score: score, reason: reason))
                }
            }
        }
        ranked.sort { $0.score > $1.score || ($0.score == $1.score && s.docs[$0.i].m.modified > s.docs[$1.i].m.modified) }
        return ranked
    }

    private static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// 평문 스니펫: 검색어 주변 ±60자, 없으면 첫 문장.
    static func snippet(_ i: Int, terms: Terms?, snap s: Snapshot, store: Store) -> String {
        let fallback = s.docs[i].m.summary
        guard let terms = terms, terms.cho == nil else { return fallback }
        let (raw, _) = store.readText(rowid: s.docs[i].m.rowid, maxChars: 30_000)
        // 맨 앞의 제목 줄은 건너뛴다
        var body = Substring(raw)
        let title = s.docs[i].m.title
        let lead = body.drop(while: { $0.isWhitespace })
        let firstLine = lead.prefix(while: { $0 != "\n" })
        if !title.isEmpty, Korean.normalize(firstLine.trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespaces))) == Korean.normalize(title) {
            body = lead.dropFirst(firstLine.count)
        }
        for group in [terms.exact, terms.expanded] {
            var best: Range<Substring.Index>? = nil
            for t in group {
                if let r = body.range(of: t, options: [.caseInsensitive]), best == nil || r.lowerBound < best!.lowerBound { best = r }
            }
            guard let r = best else { continue }
            // 원문에서 넉넉히 잘라 공백을 접은 뒤 ±60자로 다시 자른다
            let wStart = body.index(r.lowerBound, offsetBy: -90, limitedBy: body.startIndex) ?? body.startIndex
            let wEnd = body.index(r.upperBound, offsetBy: 90, limitedBy: body.endIndex) ?? body.endIndex
            let before = collapse(String(body[wStart..<r.lowerBound])), match = collapse(String(body[r]))
            let after = collapse(String(body[r.upperBound..<wEnd]))
            let headStart = body[body.startIndex..<r.lowerBound].allSatisfy { $0.isWhitespace }
            var pre = before.count > 60 ? String(before.suffix(60)) : before
            if before.count > 60, let sp = pre.firstIndex(of: " "), pre.distance(from: pre.startIndex, to: sp) < 15 {
                pre = String(pre[pre.index(after: sp)...])
            }
            let gap1 = !pre.isEmpty && body[wStart..<r.lowerBound].last?.isWhitespace == true ? " " : ""
            let gap2 = !after.isEmpty && body[r.upperBound..<wEnd].first?.isWhitespace == true ? " " : ""
            let post = String(after.prefix(60))
            let cutHead = !headStart && (wStart > body.startIndex || before.count > pre.count)
            let cutTail = wEnd < body.endIndex || after.count > post.count
            return (cutHead ? "…" : "") + pre + gap1 + match + gap2 + post + (cutTail ? "…" : "")
        }
        return fallback
    }

    // MARK: 보기 모델

    final class Builder {
        let s: Snapshot
        var sections: [[String: Any]] = []
        var nodes: [[String: Any]] = []
        var links: [[String: Any]] = []
        var legend: [String: Int] = [:]
        var linkPairs = Set<Int64>()
        init(_ s: Snapshot) { self.s = s }
        func count(_ i: Int) { legend[s.docs[i].m.group, default: 0] += 1 }
        func item(_ i: Int, _ reason: String, _ snippet: String, _ cls: String? = nil) -> [String: Any] {
            var it: [String: Any] = ["doc": Views.summary(i, s), "reason": reason, "snippet": snippet]
            if let c = cls { it["cls"] = c }
            return it
        }
        func section(_ key: String, _ title: String, _ items: [[String: Any]]) {
            sections.append(["key": key, "title": title, "items": items])
        }
        func pair(_ a: Int, _ b: Int) -> Int64 { a < b ? Int64(a) << 32 | Int64(b) : Int64(b) << 32 | Int64(a) }
        func addLink(_ a: Int, _ b: Int, _ kind: String) {
            guard linkPairs.insert(pair(a, b)).inserted else { return }
            links.append(["source": s.docs[a].m.id, "target": s.docs[b].m.id, "kind": kind])
        }
    }

    static func view(_ p: [String: Any], snap s: Snapshot, store: Store) -> [String: Any] {
        let hidden = Set((p["hiddenGroups"] as? [Any])?.compactMap { $0 as? String } ?? [])
        let visible: (Int) -> Bool = { !hidden.contains(s.docs[$0].m.group) }
        // v0.6 C2: 끝난 티켓(완료·취소 계열 Jira)은 기본으로 그래프에서 뺀다. 뺀 문서는 endedSeen에 모아 hiddenDone으로 알린다.
        let showDone = (p["showDone"] as? Bool) ?? ((p["showDone"] as? NSNumber)?.boolValue ?? false)
        var endedSeen = Set<Int>()
        let passDone: (Int) -> Bool = { i in
            guard s.tickets[i]?.ended == true else { return true }
            endedSeen.insert(i)
            return showDone
        }
        let shownDoc: (Int) -> Bool = { visible($0) && passDone($0) }
        var clusterKey = (p["cluster"] as? String) ?? ""
        if clusterKey.hasPrefix("c:") { clusterKey = String(clusterKey.dropFirst(2)) }
        var mode = p["mode"] as? String ?? "global"
        let query = (p["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let depth = (p["depth"] as? NSNumber)?.intValue ?? 1
        let focus = (p["focusId"] as? String).flatMap { s.index[$0] }
        if mode == "search" && Korean.queryTerms(query).isEmpty { mode = "global" }
        if mode == "focus" && focus == nil { mode = "global" }
        if mode == "cluster" && s.clusterIndex[clusterKey] == nil { mode = "overview" }
        let b = Builder(s)
        var centerId: Any = NSNull()
        var chips: [[Any]] = [], chipLabel = "", summary = "", hiddenCount = 0
        var empty: Any = NSNull()
        var clusterInfo: Any = NSNull(), docCluster: Any = NSNull()
        var graphCapped = false
        var truncated: Any = NSNull()          // v0.7 E: 목록이 잘렸으면 {shown, total}
        var doneSummarized = 0                 // v0.7 E: 요약 노드로 접은 끝난 티켓 수

        if mode == "search" {
            let t = terms(query)
            let ranked = NameMatch.apply(search(t, snap: s, store: store), query: query, snap: s)   // v0.7 F: 파일 이름이 같은 문서 먼저
            ranked.forEach { b.count($0.i) }
            let allMatches = ranked.filter { visible($0.i) }
            hiddenCount = ranked.count - allMatches.count
            let matches = Array(allMatches.prefix(60))
            if allMatches.count > 60 { truncated = truncation(shown: 60, total: allMatches.count >= 400 ? nil : allMatches.count) }   // 후보를 400개까지만 읽어 그 이상은 '넘음'
            let matchIds = Set(ranked.map { $0.i })
            let maxScore = matches.map { $0.score }.max() ?? 1
            var ctx: [Int: (n: Int, via: Int)] = [:]
            for r in matches {
                for nb in s.nb[r.i] where !matchIds.contains(nb) {
                    let e = ctx[nb] ?? (0, r.i); ctx[nb] = (e.n + 1, e.via)
                }
            }
            ctx.keys.forEach { b.count($0) }
            let ctxShown = ctx.filter { shownDoc($0.key) }.sorted {
                $0.value.n > $1.value.n || ($0.value.n == $1.value.n && s.docs[$0.key].m.modified > s.docs[$1.key].m.modified)
            }.prefix(8)
            b.section("match", "검색 결과", matches.map { b.item($0.i, $0.reason, snippet($0.i, terms: t, snap: s, store: store)) })
            if !ctxShown.isEmpty {
                b.section("context", "연결된 문서", ctxShown.map {
                    b.item($0.key, josa(s.docs[$0.value.via].short, "과", "와") + " 연결", s.docs[$0.key].m.summary, "is-context")
                })
            }
            if !matches.isEmpty {
                let hub = "q:" + query
                centerId = hub
                b.nodes.append(["id": hub, "label": query, "fullLabel": query, "kind": "keyword", "group": "", "degree": matches.count, "emphasis": "center"])
                for r in matches {
                    b.nodes.append(node(r.i, s, "match"))
                    b.links.append(["source": hub, "target": s.docs[r.i].m.id, "kind": "query",
                                    "strength": (r.score / maxScore * 100).rounded() / 100])
                }
                ctxShown.forEach { b.nodes.append(node($0.key, s, "context")) }
            } else {
                empty = ["query": query, "hidden": hiddenCount] as [String: Any]
            }
            endedSeen.removeAll()   // 검색 결과는 숨기지 않는다 — 끝난 티켓 토글은 검색에서 보이지 않게
            summary = "문서 \(allMatches.count) · 연결된 문서 \(ctxShown.count)"
            chipLabel = "연관 키워드"
            var tc: [String: Int] = [:]
            let exact = Set(t.exact)
            for r in matches { for tag in s.docs[r.i].m.tags where !exact.contains(Korean.normalize(tag)) { tc[tag, default: 0] += 1 } }
            var list = tc.sorted { $0.value > $1.value || ($0.value == $1.value && (s.tagCount[$0.key] ?? 0) > (s.tagCount[$1.key] ?? 0)) }
                .prefix(8).map { [$0.key, $0.value] as [Any] }
            if list.count < 8 {
                var kc: [String: Int] = [:]
                let have = Set(tc.keys.map { $0.lowercased() })
                for r in matches.prefix(30) { for term in s.terms[r.i].prefix(8) where !exact.contains(term) && !have.contains(term) { kc[term, default: 0] += 1 } }
                list += kc.filter { $0.value >= 2 }.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
                    .prefix(8 - list.count).map { [$0.key, $0.value] as [Any] }
            }
            chips = list
        } else if mode == "focus", let c = focus {
            centerId = s.docs[c].m.id
            b.count(c)
            let center = s.docs[c].m
            var outK: [Int: Set<String>] = [:], inK: [Int: Set<String>] = [:]
            for e in s.out[c] { outK[e.to, default: []].insert(e.kind) }
            for e in s.inc[c] { inK[e.to, default: []].insert(e.kind) }
            let direct = Array(s.explicitNb[c])
            direct.forEach { b.count($0) }
            let isLink: (Set<String>?) -> Bool = { ($0 ?? []).contains("link") || ($0 ?? []).contains("embed") }
            let rank: (Int) -> Double = { (isLink(outK[$0]) ? 2 : 0) + (isLink(inK[$0]) ? 1 : 0) + ((outK[$0] != nil || inK[$0] != nil) ? 0.5 : 0) }
            let dirShown = direct.filter(shownDoc).sorted {
                rank($0) > rank($1) || (rank($0) == rank($1) && s.docs[$0].m.modified > s.docs[$1].m.modified)
            }
            var taken = Set([c] + direct)
            // 같은 태그 (최대 5)
            var shared: [Int: [String]] = [:]
            for t in center.tags {
                for j in s.tagDocs[t.lowercased()] ?? [] where !taken.contains(j) {
                    if !(shared[j]?.contains(t) ?? false) { shared[j, default: []].append(t) }
                }
            }
            let same = shared.sorted {
                $0.value.count > $1.value.count || ($0.value.count == $1.value.count && s.docs[$0.key].m.modified > s.docs[$1.key].m.modified)
            }
            same.prefix(5).forEach { b.count($0.key) }
            let sameShown = Array(same.filter { shownDoc($0.key) }.prefix(5))
            sameShown.forEach { taken.insert($0.key) }
            // 자동 연결 (keyword·folder, 최대 8)
            let relAll = s.related[c].filter { !taken.contains($0.to) && $0.kind != "tag" }.prefix(8)
            relAll.forEach { b.count($0.to) }
            let relShown = relAll.filter { shownDoc($0.to) }
            relShown.forEach { taken.insert($0.to) }

            b.section("center", "중심 문서", [b.item(c, kindLabels[center.kind] ?? center.kind, center.summary, "is-center")])
            b.section("direct", "직접 연결", dirShown.map { j -> [String: Any] in
                let o = outK[j] ?? [], i = inK[j] ?? []
                let why: String
                if isLink(o) && isLink(i) { why = "양방향 링크" }
                else if isLink(o) { why = "나가는 링크" }
                else if isLink(i) { why = "들어오는 링크" }
                else if o.contains("issue") || i.contains("issue") { why = issueReason(c, j, s) }
                else { why = "본문에서 언급" }
                return b.item(j, why, s.docs[j].m.summary)
            })
            if !sameShown.isEmpty {
                b.section("tag", "같은 태그", sameShown.map { b.item($0.key, "같은 태그 #" + $0.value[0], s.docs[$0.key].m.summary) })
            }
            if !relShown.isEmpty {
                b.section("related", "자동 연결", relShown.map { b.item($0.to, $0.reason, s.docs[$0.to].m.summary) })
            }
            var two: [(Int, Int, Int)] = []   // (doc, n, via)
            if depth == 2 {
                var via: [Int: (Int, Int)] = [:]
                for d in dirShown { for n in s.explicitNb[d] where !taken.contains(n) { let e = via[n] ?? (0, d); via[n] = (e.0 + 1, e.1) } }
                via.keys.forEach { b.count($0) }
                two = via.filter { shownDoc($0.key) }.map { ($0.key, $0.value.0, $0.value.1) }.sorted {
                    $0.1 > $1.1 || ($0.1 == $1.1 && s.docs[$0.0].m.modified > s.docs[$1.0].m.modified)
                }
                two = Array(two.prefix(30))
                if !two.isEmpty {
                    b.section("two", "두 단계 연결", two.map { b.item($0.0, s.docs[$0.2].short + " 경유", s.docs[$0.0].m.summary, "is-context") })
                }
            }
            hiddenCount = (direct.count - dirShown.count) + (min(same.count, 5) - sameShown.count) + (relAll.count - relShown.count)
            b.nodes.append(node(c, s, "center"))
            // v0.7 E: 끝난 티켓이 많으면 최근 40개만 문서로 두고 나머지는 요약 노드로 접는다
            let dirEnded = dirShown.filter { s.tickets[$0]?.ended == true }
            if dirEnded.count > doneKeep {
                let d = densifyEnded(dirEnded, clusterKey: "focus", snap: s)
                let keepSet = Set(d.shown)
                dirShown.filter { s.tickets[$0]?.ended != true || keepSet.contains($0) }.forEach { b.nodes.append(node($0, s, "normal")) }
                b.nodes += d.summaries; b.links += d.links; doneSummarized += d.summarized
            } else {
                dirShown.forEach { b.nodes.append(node($0, s, "normal")) }
            }

            sameShown.forEach { b.nodes.append(node($0.key, s, "normal")); b.addLink(c, $0.key, "tag") }
            relShown.forEach { b.nodes.append(node($0.to, s, "normal")); b.addLink(c, $0.to, "tag") }
            two.forEach { b.nodes.append(node($0.0, s, "context")) }
            summary = "직접 연결 \(dirShown.count) · 같은 태그 \(sameShown.count) · 자동 연결 \(relShown.count)" + (depth == 2 ? " · 두 단계 \(two.count)" : "")
            chipLabel = "이 문서의 키워드"
            var tc: [String: Int] = [:]
            let centerTags = Set(center.tags)
            for t in center.tags { tc[t] = 100 }
            for d in dirShown + sameShown.map({ $0.key }) + relShown.map({ $0.to }) { for t in s.docs[d].m.tags { tc[t, default: 0] += 1 } }
            chips = tc.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.prefix(8).map {
                [$0.key, centerTags.contains($0.key) ? $0.value - 99 : $0.value, centerTags.contains($0.key)] as [Any]
            }
        } else if mode == "overview" {
            // v0.6 C2 묶음 지도: 노드 = 묶음(폴더·프로젝트·스페이스). 누르면 요약, 펼치면 cluster 모드.
            s.docs.indices.forEach { if showDone || s.tickets[$0]?.ended != true { b.count($0) } }
            let vis = s.docs.indices.filter(visible)
            hiddenCount = s.docs.count - vis.count
            let list = vis.filter(passDone)
            let recent = list.sorted { s.docs[$0].m.modified > s.docs[$1].m.modified }.prefix(200)
            if list.count > listCap { truncated = truncation(shown: listCap, total: list.count) }
            b.section("recent", list.count > listCap ? "최근 문서 · 최근 \(listCap)개 (전체 \(list.count)개)" : "최근 문서", recent.map { b.item($0, relDate(s.docs[$0].m.modified), s.docs[$0].m.summary) })
            var inGraph = Set<Int>()
            for (ci, c) in s.clusters.enumerated() {
                let all = c.docs.filter(visible)
                let shown = all.filter(passDone)
                if shown.isEmpty { continue }
                b.nodes.append(clusterNode(ci, s, shown: shown, all: all, emphasis: "normal"))
                inGraph.formUnion(shown)
            }
            b.links = clusterLinks(s, docs: Array(inGraph), keep: { inGraph.contains($0) })
            var dc: [String: String] = [:]
            for (i, d) in s.docs.enumerated() { dc[d.m.id] = "c:" + s.clusters[s.clusterOf[i]].key }
            docCluster = dc
            chipLabel = "자주 쓰는 태그"
            chips = s.tagOrder.prefix(8).map { [$0.0, $0.1] as [Any] }
            summary = "문서 \(s.docs.count) · 연결 \(s.linkCount)"
        } else if mode == "cluster", let ci = s.clusterIndex[clusterKey] {
            // v0.6 C2 묶음 펼치기: 그 묶음의 문서(최대 200) + 이웃 묶음(최대 8) + 문서↔이웃 묶음 연결
            let c = s.clusters[ci]
            let all = c.docs.filter(visible)
            let members = all.filter(passDone)
            members.forEach { b.count($0) }
            let now = Date().timeIntervalSince1970
            func weight(_ i: Int) -> Double {
                let age: Double = (now - s.docs[i].m.modified) / (30 * 86400)
                return Double(s.degree[i]) + 3 * exp(-age)
            }
            let recent = members.sorted { s.docs[$0].m.modified > s.docs[$1].m.modified }.prefix(200)
            if members.count > listCap { truncated = truncation(shown: listCap, total: members.count) }
            b.section("cluster", members.count > listCap ? c.label + " 문서 · 최근 \(listCap)개 (전체 \(members.count)개)" : c.label + " 문서", recent.map { b.item($0, relDate(s.docs[$0].m.modified), s.docs[$0].m.summary) })
            // 그래프에는 최대 200개: 끝나지 않은 문서는 연결 많은 순. v0.7 E: 끝난 티켓은 최근 40개만 문서로 두고 나머지는 상태별 요약 노드로 접는다
            var graphDocs: [Int] = members
            var summaryNodes: [[String: Any]] = []
            let endedMembers = members.filter { s.tickets[$0]?.ended == true }
            if endedMembers.count > doneKeep {
                let d = densifyEnded(endedMembers, clusterKey: c.key, snap: s)
                let live = members.filter { s.tickets[$0]?.ended != true }
                let budget = max(0, 200 - d.shown.count - d.summaries.count)
                var top: [Int] = live
                if live.count > budget {
                    let scored: [(Int, Double)] = live.map { ($0, weight($0)) }
                    let ranked = scored.sorted { $0.1 > $1.1 || ($0.1 == $1.1 && $0.0 < $1.0) }
                    top = ranked.prefix(budget).map { $0.0 }
                }
                graphDocs = top + d.shown
                summaryNodes = d.summaries; b.links += d.links
                doneSummarized += d.summarized
                graphCapped = true
            } else if members.count > 200 {
                let live: [(Int, Double)] = members.filter { s.tickets[$0]?.ended != true }.map { ($0, weight($0)) }
                let top: [Int] = live.sorted { $0.1 > $1.1 || ($0.1 == $1.1 && $0.0 < $1.0) }.prefix(200).map { $0.0 }
                let endedDocs = members.filter { s.tickets[$0]?.ended == true }.sorted { s.docs[$0].m.modified > s.docs[$1].m.modified }
                graphDocs = top + endedDocs.prefix(max(0, 200 - top.count))
                graphCapped = !endedDocs.isEmpty
            }
            // 이웃 묶음 계산에는 "끝난 티켓 N" 숫자가 섞이지 않게 숨김 집계 없이 같은 기준만 쓴다
            let quiet: (Int) -> Bool = { visible($0) && (showDone || s.tickets[$0]?.ended != true) }
            graphDocs.forEach { b.nodes.append(node($0, s, "normal")) }
            b.nodes += summaryNodes
            var neigh: [Int: Int] = [:]
            func otherCluster(_ j: Int) -> Int? {
                let cj = s.clusterOf[j]
                return cj != ci && quiet(j) ? cj : nil
            }
            for a in members {
                for e in s.out[a] { if let cj = otherCluster(e.to) { neigh[cj, default: 0] += 1 } }
                for r in s.related[a] { if let cj = otherCluster(r.to) { neigh[cj, default: 0] += 1 } }
            }
            let top = neigh.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.prefix(8).map { $0.key }
            let topSet = Set(top)
            for cj in top {
                let a2 = s.clusters[cj].docs.filter(visible)
                b.nodes.append(clusterNode(cj, s, shown: a2.filter(quiet), all: a2, emphasis: "context"))
            }
            for a in graphDocs {
                var per: [Int: Int] = [:]
                for e in s.out[a] { if let cj = otherCluster(e.to), topSet.contains(cj) { per[cj, default: 0] += 1 } }
                for r in s.related[a] { if let cj = otherCluster(r.to), topSet.contains(cj) { per[cj, default: 0] += 1 } }
                for (cj, w) in per { b.links.append(["source": s.docs[a].m.id, "target": "c:" + s.clusters[cj].key, "kind": "cluster", "weight": w]) }
            }
            clusterInfo = clusterNode(ci, s, shown: members, all: all, emphasis: "center")
            hiddenCount = c.docs.count - all.count
            chipLabel = "이 묶음의 태그"
            var tc: [String: Int] = [:]
            for i in members { for t in s.docs[i].m.tags { tc[t, default: 0] += 1 } }
            chips = tc.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.prefix(8).map { [$0.key, $0.value] as [Any] }
            let openN = members.filter { s.tickets[$0]?.open == true }.count
            summary = "\(c.label) · 문서 \(members.count)" + (openN > 0 ? " · 열린 티켓 \(openN)" : "")
        } else {
            mode = "global"
            s.docs.indices.forEach { b.count($0) }
            let vis = s.docs.indices.filter(visible)
            hiddenCount = s.docs.count - vis.count
            let list = vis.filter(passDone)
            let recent = list.sorted { s.docs[$0].m.modified > s.docs[$1].m.modified }.prefix(200)
            if list.count > listCap { truncated = truncation(shown: listCap, total: list.count) }
            b.section("recent", list.count > listCap ? "최근 문서 · 최근 \(listCap)개 (전체 \(list.count)개)" : "최근 문서", recent.map { b.item($0, relDate(s.docs[$0].m.modified), s.docs[$0].m.summary) })
            let now = Date().timeIntervalSince1970
            func weight(_ i: Int) -> Double {
                let age: Double = (now - s.docs[i].m.modified) / (30 * 86400)
                return Double(s.degree[i]) + 3 * exp(-age)
            }
            let endedList = list.filter { s.tickets[$0]?.ended == true }
            if endedList.count > doneKeep {   // v0.7 E: 끝난 티켓은 최근 40개만 문서로, 나머지는 요약 노드로
                let d = densifyEnded(endedList, clusterKey: "all", snap: s)
                let weighted: [(Int, Double)] = list.filter { s.tickets[$0]?.ended != true }.map { ($0, weight($0)) }
                let top = weighted.sorted { $0.1 > $1.1 || ($0.1 == $1.1 && $0.0 < $1.0) }.prefix(max(0, 150 - d.shown.count - d.summaries.count))
                top.forEach { b.nodes.append(node($0.0, s, "normal")) }
                d.shown.forEach { b.nodes.append(node($0, s, "normal")) }
                b.nodes += d.summaries; b.links += d.links
                doneSummarized += d.summarized
                graphCapped = true
            } else {
                let weighted: [(Int, Double)] = list.map { ($0, weight($0)) }
                let graph = weighted.sorted { $0.1 > $1.1 || ($0.1 == $1.1 && $0.0 < $1.0) }.prefix(150)
                graph.forEach { b.nodes.append(node($0.0, s, "normal")) }
            }
            chipLabel = "자주 쓰는 태그"
            chips = s.tagOrder.prefix(8).map { [$0.0, $0.1] as [Any] }
            summary = "문서 \(s.docs.count) · 연결 \(s.linkCount)"
        }

        // 보이는 문서 사이 명시(link)·자동(tag) 연결
        var vis: [Int] = []
        for n in b.nodes where (n["kind"] as? String) == "doc" { if let id = n["id"] as? String, let i = s.index[id] { vis.append(i) } }
        let visSet = Set(vis)
        for a in vis {
            for e in s.out[a] where visSet.contains(e.to) { b.addLink(a, e.to, "link") }
        }
        for a in vis {
            for r in s.related[a] where visSet.contains(r.to) { b.addLink(a, r.to, "tag") }
        }
        let legend = b.legend.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.map { [$0.key, $0.value] as [Any] }
        let doneShown = showDone ? b.nodes.filter { ($0["kind"] as? String) == "doc" && ["done", "dropped"].contains($0["statusGroup"] as? String ?? "") }.count : 0
        var out: [String: Any] = ["mode": mode, "sections": b.sections, "nodes": b.nodes, "links": b.links, "centerId": centerId,
                "chips": chips, "chipLabel": chipLabel, "summary": summary, "legend": legend, "hidden": hiddenCount,
                "total": s.docs.count, "empty": empty, "cluster": clusterInfo, "docCluster": docCluster,
                "hiddenDone": showDone ? 0 : endedSeen.count, "doneCount": endedSeen.count, "showDone": showDone, "graphCapped": graphCapped,
                "doneShown": doneShown, "doneSummarized": doneSummarized]
        if !(truncated is NSNull) { out["truncated"] = truncated }
        return out
    }

    /// "이슈 PROJ-142 언급" — 둘 중 jira 문서의 키.
    static func issueReason(_ a: Int, _ b: Int, _ s: Snapshot) -> String {
        for i in [b, a] where s.docs[i].m.kind == "jira" {
            if let k = s.docs[i].m.id.components(separatedBy: ":jira:").last { return "이슈 \(k) 언급" }
        }
        return "이슈 언급"
    }

    static func edgeReason(_ kinds: Set<String>, _ a: Int, _ b: Int, _ s: Snapshot) -> String {
        if kinds.contains("link") { return "링크" }
        if kinds.contains("embed") { return "임베드" }
        if kinds.contains("issue") { return issueReason(a, b, s) }
        return "본문에서 언급"
    }

    static func openLabel(_ i: Int, _ s: Snapshot) -> String {
        let d = s.docs[i].m
        if d.kind == "confluence" { return "Confluence에서 열기" }
        if d.kind == "jira" { return "Jira에서 열기" }
        return "기본 앱으로 열기"      // v0.6: 옵시디언 자동 열기는 없앴다 — 설치돼 있으면 open.canObsidian 메뉴로
    }

    static func document(id: String, snap s: Snapshot, store: Store) -> [String: Any]? {
        guard let c = s.index[id] else { return nil }
        let d = s.docs[c].m
        let (text, length) = store.readText(rowid: d.rowid, maxChars: 60_000)
        var sections: [[String: Any]] = []
        var taken = Set([c])
        func add(_ key: String, _ title: String, _ items: [(Int, String)]) {
            guard !items.isEmpty else { return }
            sections.append(["key": key, "title": title, "items": items.map { ["doc": summary($0.0, s), "reason": $0.1] as [String: Any] }])
        }
        let byDate: (Int, Int) -> Bool = { s.docs[$0].m.modified > s.docs[$1].m.modified }
        var outK: [Int: Set<String>] = [:], inK: [Int: Set<String>] = [:]
        for e in s.out[c] { outK[e.to, default: []].insert(e.kind) }
        for e in s.inc[c] { inK[e.to, default: []].insert(e.kind) }
        // 관계 우선순위: 명시 나가는 링크 > 명시 들어오는 링크 > 언급·이슈(나가는) > 언급·이슈(들어오는)
        let explicitKinds: Set<String> = ["link", "embed"]
        let order = s.out[c].map { $0.to } + s.inc[c].sorted { byDate($0.to, $1.to) }.map { $0.to }
        var outItems: [(Int, String)] = [], inItems: [(Int, String)] = []
        for j in order where !taken.contains(j) {
            let o = outK[j] ?? [], i = inK[j] ?? []
            if !o.isDisjoint(with: explicitKinds) { outItems.append((j, edgeReason(o, c, j, s))) }
            else if !i.isDisjoint(with: explicitKinds) { inItems.append((j, edgeReason(i, j, c, s))) }
            else if !o.isEmpty { outItems.append((j, edgeReason(o, c, j, s))) }
            else { inItems.append((j, edgeReason(i, j, c, s))) }
            taken.insert(j)
        }
        add("out", "나가는 연결", outItems)
        add("in", "들어오는 연결", inItems)
        let rel = s.related[c].filter { !taken.contains($0.to) }.prefix(8)
        add("related", "자동 연결", rel.map { ($0.to, $0.reason) })
        taken.formUnion(rel.map { $0.to })
        var shared: [Int: String] = [:], sharedN: [Int: Int] = [:]
        for t in d.tags {
            for j in s.tagDocs[t.lowercased()] ?? [] where !taken.contains(j) {
                if shared[j] == nil { shared[j] = t }
                sharedN[j, default: 0] += 1
            }
        }
        let sameTag = shared.keys.sorted { (sharedN[$0] ?? 0) > (sharedN[$1] ?? 0) || ((sharedN[$0] ?? 0) == (sharedN[$1] ?? 0) && byDate($0, $1)) }.prefix(5)
        add("tag", "같은 태그", sameTag.map { ($0, "같은 태그 #" + (shared[$0] ?? "")) })
        let isFile = !(d.location.hasPrefix("http://") || d.location.hasPrefix("https://"))
        return ["doc": summary(c, s), "text": text, "truncated": length > 60_000, "sections": sections,
                "unresolved": s.unresolved[c],
                "open": ["label": openLabel(c, s), "canReveal": isFile,
                         "canObsidian": isFile && ["md", "markdown"].contains(d.kind) && s.obsidianInstalled && s.sources[d.sourceId]?.kind == .obsidian] as [String: Any]]
    }

    static func obsidianInstalled() -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "md.obsidian") != nil
    }
}
