import Foundation

// 링크 해석 + 자동 연결 계산 (docs/CONNECT.md §3.4 링크 해석, §3.5). 색인 큐에서 전체를 다시 계산한다.

/// 문서별 "이 문서를 언급한 문서" 목록 (색인 큐에서만 쓴다).
final class MentionCache {
    struct Entry { var names: [String]; var srcs: Set<String>; var tooCommon: Bool }
    var byTarget: [String: Entry] = [:]
}

enum Relate {
    static let maxRelated = 8
    static let topTerms = 15

    static let maxPosting = 300        // 키워드·태그 하나가 잇는 문서 수 상한 (O(df²) 방지)
    static let maxMentionCandidates = 400
    static let textCacheBudget = 40_000_000   // 언급 확인용 본문 캐시 (글자 수)
    static let maxMentionsPerDoc = 10
    static let maxKeywordPerDoc = 6
    static let attachmentExts: Set<String> = ["png", "jpg", "jpeg", "gif", "svg", "webp", "heic", "heif", "bmp", "tiff", "tif", "ico",
                                              "mp4", "mov", "m4v", "webm", "avi", "mkv", "mp3", "m4a", "wav", "aac", "flac", "ogg",
                                              "zip", "gz", "tar", "7z", "rar", "excalidraw", "canvas", "base", "psd", "ai", "sketch",
                                              "fig", "key", "pages", "numbers", "xlsx", "xls", "csv", "pptx", "ppt", "dmg", "pkg", "json"]
    static func isAttachment(_ t: String) -> Bool { attachmentExts.contains((t as NSString).pathExtension.lowercased()) }

    static let genericTitles: Set<String> = Set([
        "readme", "index", "untitled", "메모", "노트", "정리", "회의", "회의록", "일기", "오늘", "할 일", "할일", "todo", "to do",
        "기록", "아이디어", "참고", "목차", "개요", "요약", "문서", "자료", "기타", "임시", "새 노트", "제목 없음", "무제", "템플릿",
        "template", "templates", "inbox", "대시보드", "dashboard", "home", "홈", "daily", "daily note", "데일리", "일정", "주간",
        "주간 회의", "주간회의", "월간", "회고", "notes", "note", "memo", "draft", "초안", "test", "테스트", "temp", "tmp", "misc",
        "archive", "보관", "attachments", "첨부", "assets", "image", "images", "untitled 1", "새 문서", "빈 메모", "제목없음",
    ].map { $0.lowercased() })

    private static let dateRegexes: [NSRegularExpression] = [
        #"^\d{4}[-./]\s?\d{1,2}[-./]\s?\d{1,2}\.?"#, #"^\d{8}"#, #"^\d{4}\s*년\s*\d{1,2}\s*월(\s*\d{1,2}\s*일)?"#,
        #"^\d{1,2}\s*월\s*\d{1,2}\s*일"#, #"^\d{4}-w\d{1,2}"#, #"^\d{4}[-.]\d{1,2}$"#, #"^\d{1,2}:\d{2}"#,
        #"^\d{2}[-./]\d{1,2}[-./]\d{1,2}"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// 언급 대상이 될 수 있는 이름인가: 날짜·시각 형태, 숫자·기호만, 일반어는 제외.
    static func mentionable(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        if genericTitles.contains(n) { return false }
        if !n.unicodeScalars.contains(where: { $0.properties.isAlphabetic }) { return false }       // 숫자·기호만
        let r = NSRange(n.startIndex..., in: n)
        for re in dateRegexes {
            // 날짜로 시작하고 나머지가 짧은 꼬리(요일·"회의록" 같은 일반어)뿐이면 날짜 제목
            if let m = re.firstMatch(in: n, range: r) {
                let rest = (n as NSString).substring(from: m.range.upperBound)
                    .trimmingCharacters(in: CharacterSet(charactersIn: " -_.,()[]·").union(.whitespaces))
                if rest.isEmpty || genericTitles.contains(rest) || rest.count <= 3 { return false }
            }
        }
        // "회의록 2026-10-20", "일기 10월 23일" 처럼 일반어 + 날짜
        if let sp = n.firstIndex(of: " ") {
            let head = String(n[..<sp]), tail = String(n[n.index(after: sp)...])
            if genericTitles.contains(head) && !mentionable(tail) && tail.unicodeScalars.contains(where: { $0.properties.numericType != nil }) { return false }
        }
        return true
    }

    static let josaAfter: [String] = ["으로", "에서", "에게", "까지", "부터", "처럼", "보다", "이나", "이라",
                                      "은", "는", "이", "가", "을", "를", "에", "의", "도", "만", "와", "과", "로"]

    /// 경계 규칙: 라틴·숫자 끝은 단어 경계, 한글 앞은 한글이 아니어야, 한글 뒤는 한글이 아니거나 조사로 시작.
    static func occurs(_ name: String, in text: String) -> Bool {
        guard let first = name.unicodeScalars.first, let last = name.unicodeScalars.last else { return false }
        func isWord(_ u: Unicode.Scalar) -> Bool { u.properties.isAlphabetic || u.properties.numericType != nil }
        let firstHangul = Korean.isHangul(first.value), lastHangul = Korean.isHangul(last.value)
        var from = text.startIndex
        while let r = text.range(of: name, range: from..<text.endIndex) {
            var ok = true
            if r.lowerBound > text.startIndex, let b = text[text.index(before: r.lowerBound)].unicodeScalars.last {
                if firstHangul { ok = !Korean.isHangul(b.value) } else if isWord(first) { ok = !isWord(b) }
            }
            if ok, r.upperBound < text.endIndex, let a = text[r.upperBound].unicodeScalars.first {
                if lastHangul {
                    if Korean.isHangul(a.value) {
                        let tail = text[r.upperBound...]
                        ok = josaAfter.contains { tail.hasPrefix($0) }
                    }
                } else if isWord(last) { ok = !isWord(a) }
            }
            if ok { return true }
            from = text.index(after: r.lowerBound)
        }
        return false
    }

    /// enabled: 켜진 소스 id (nil = 전부). 꺼진 소스 문서는 연결 계산에서 뺀다.
    /// mentions: 언급 계산 결과를 다음 번에 다시 쓰기 위한 캐시. changed: 지난 계산 뒤 바뀐(추가·수정·삭제) 문서 id.
    /// changed == nil이면 언급을 전부 다시 계산한다.
    /// roots: 로컬 소스 id → 실제 루트 경로 (디스크에 있는 첨부·제외 파일을 unresolved에서 빼는 데 쓴다).
    static func compute(store: Store, enabled: Set<String>? = nil, mentions: MentionCache? = nil,
                        changed: Set<String>? = nil, roots: [String: String] = [:]) throws -> Store.GraphRows {
        let docs = try store.metas().filter { enabled?.contains($0.sourceId) ?? true }
        let tf = try store.allTF()
        var g = Store.GraphRows()
        let n = docs.count
        if n == 0 { return g }
        var byId: [String: Int] = [:]
        for (i, d) in docs.enumerated() { byId[d.id] = i }

        let debug = ProcessInfo.processInfo.environment["SYNAPSE_DEBUG_TIMING"] == "1"
        var t0 = Date()
        func lap(_ name: String) {
            if debug { FileHandle.standardError.write("relate \(name) \(Int(Date().timeIntervalSince(t0) * 1000))ms\n".data(using: .utf8)!) }
            t0 = Date()
        }
        lap("load")
        // MARK: 이름·경로 찾기표
        func relPath(_ d: DocMetaRow) -> String { String(d.id.dropFirst(d.sourceId.count + 1)) }
        var byName: [String: [String: [Int]]] = [:]     // sourceId → 소문자 이름 → 문서
        var byRel: [String: [String: Int]] = [:]        // sourceId → 소문자 상대 경로 → 문서
        var confTitle: [String: [String: [Int]]] = [:]  // sourceId → 소문자 제목 → confluence 문서
        var jira: [String: [Int]] = [:]                 // KEY → jira 문서
        for (i, d) in docs.enumerated() {
            if d.kind == "confluence" { confTitle[d.sourceId, default: [:]][d.title.lowercased(), default: []].append(i); continue }
            if d.kind == "jira" {
                if let k = d.id.components(separatedBy: ":jira:").last { jira[k, default: []].append(i) }
                continue
            }
            let rel = relPath(d)
            byRel[d.sourceId, default: [:]][rel.lowercased()] = i
            let file = (rel as NSString).lastPathComponent
            var names = Set([file.lowercased(), (file as NSString).deletingPathExtension.lowercased()])
            for a in d.aliases { names.insert(a.lowercased()) }
            for nm in names where !nm.isEmpty { byName[d.sourceId, default: [:]][nm, default: []].append(i) }
        }
        func pick(_ cands: [Int], near folder: String) -> Int? {
            cands.min { a, b in
                let fa = docs[a].folder == folder ? 0 : 1, fb = docs[b].folder == folder ? 0 : 1
                if fa != fb { return fa < fb }
                let la = docs[a].id.count, lb = docs[b].id.count
                return la != lb ? la < lb : docs[a].id < docs[b].id
            }
        }
        func normPath(_ p: String) -> String {
            var out: [Substring] = []
            for c in p.split(separator: "/") {
                if c == "." || c.isEmpty { continue }
                if c == ".." { if !out.isEmpty { out.removeLast() }; continue }
                out.append(c)
            }
            return out.joined(separator: "/")
        }
        func resolve(_ raw: String, from a: DocMetaRow) -> Int? {
            if raw.hasPrefix("id:") { return byId[String(raw.dropFirst(3))] }
            var t = raw
            if let h = t.firstIndex(where: { $0 == "#" || $0 == "^" }) { t = String(t[..<h]) }
            t = Indexer.nfc((t.removingPercentEncoding ?? t).trimmingCharacters(in: .whitespaces))
            if t.isEmpty { return nil }
            if Korean.isIssueKey(t), let c = jira[t] { return c.first(where: { docs[$0].sourceId == a.sourceId }) ?? c.first }
            if a.kind == "confluence" || a.kind == "jira" {
                if let c = confTitle[a.sourceId]?[t.lowercased()] { return c.first }
                return nil
            }
            if t.contains("/") {
                guard let rels = byRel[a.sourceId] else { return nil }
                for base in [a.folder, ""] {
                    let p = normPath(base.isEmpty ? t : base + "/" + t).lowercased()
                    if let i = rels[p] ?? rels[p + ".md"] { return i }
                }
                return nil
            }
            if let c = byName[a.sourceId]?[t.lowercased()], let i = pick(c, near: a.folder) { return i }
            return nil
        }

        // MARK: 디스크 파일 이름표 (색인하지 않는 형식·제외 폴더의 파일도 "찾은 링크"로 본다)
        var diskNames: [String: Set<String>] = [:]
        func existsOnDisk(_ raw: String, from d: DocMetaRow) -> Bool {
            guard let root = roots[d.sourceId] else { return false }
            if diskNames[d.sourceId] == nil {
                var set = Set<String>()
                for rel in Indexer.listFiles(root: root) {
                    let l = rel.lowercased()
                    let file = (l as NSString).lastPathComponent
                    set.insert(l); set.insert((l as NSString).deletingPathExtension)
                    set.insert(file); set.insert((file as NSString).deletingPathExtension)
                }
                diskNames[d.sourceId] = set
            }
            let names = diskNames[d.sourceId] ?? []
            let t = Indexer.nfc(raw.removingPercentEncoding ?? raw).lowercased()
            if t.contains("/") {
                for base in [d.folder.lowercased(), ""] {
                    let p = normPath(base.isEmpty ? t : base + "/" + t)
                    if names.contains(p) || names.contains(p + ".md") { return true }
                }
                return false
            }
            return names.contains(t) || names.contains(t + ".md")
        }

        // v0.7 F: 이름·경로로 못 찾은 로컬 링크는 번호 접두·Jira 키·정규화 제목으로 한 번 더 맞춘다 (Notes.LinkIndex와 같은 코드)
        let fallback = LinkFallback(docs: docs)

        // MARK: 명시 링크
        var explicit = Set<Int64>()          // 무방향 쌍 키 (자동 연결 제외용)
        func pairKey(_ a: Int, _ b: Int) -> Int64 { a < b ? Int64(a) << 32 | Int64(b) : Int64(b) << 32 | Int64(a) }
        var linked = Set<Int64>()            // 방향 있는 a→b (mention 생략 판단)
        func dkey(_ a: Int, _ b: Int) -> Int64 { Int64(a) << 32 | Int64(b) }
        let markdownKinds: Set<String> = ["md", "markdown", "txt", "text"]
        for (i, d) in docs.enumerated() {
            var unres = Set<String>()
            for raw in d.outLinks {
                if let j = resolve(raw, from: d) {
                    if j == i { continue }
                    let ext = (raw as NSString).pathExtension.lowercased()
                    let kind = !ext.isEmpty && ext != "md" && !markdownKinds.contains(docs[j].kind) && !raw.contains("/") ? "embed" : "link"
                    g.links.append((d.id, docs[j].id, kind))
                    explicit.insert(pairKey(i, j)); linked.insert(dkey(i, j))
                } else {
                    var t = raw
                    if let h = t.firstIndex(where: { $0 == "#" || $0 == "^" }) { t = String(t[..<h]) }
                    t = t.trimmingCharacters(in: .whitespaces)
                    if t.isEmpty || t.hasPrefix("id:") || isAttachment(t) || existsOnDisk(t, from: d) { continue }
                    if let m = fallback.resolve(raw, from: d) {
                        // 기존 위키링크와 같은 kind("link"): 그래프·관련 문서·역링크·휴지통 "끊기는 링크 수"가 그대로 따라온다
                        let j = m.doc
                        if j == i { continue }
                        g.links.append((d.id, docs[j].id, "link"))
                        explicit.insert(pairKey(i, j)); linked.insert(dkey(i, j))
                        continue
                    }
                    if unres.insert(t).inserted { g.unresolved.append((d.id, t)) }
                }
            }
            // 이슈 키 언급
            for k in d.issueKeys {
                if let c = jira[k], let j = c.first(where: { docs[$0].sourceId == d.sourceId }) ?? c.first {
                    if j == i || linked.contains(dkey(i, j)) { continue }
                    g.links.append((d.id, docs[j].id, "issue"))
                    explicit.insert(pairKey(i, j)); linked.insert(dkey(i, j))
                } else if let m = fallback.resolve(k, from: d) {
                    // v0.7 F: Jira에 없는 "TN-003" 같은 번호 언급은 번호가 같은 로컬 문서로 잇는다 ("본문에서 언급"). 문서 보기(decorate)가 이미 숨기던 항목이다
                    let j = m.doc
                    if j == i || linked.contains(dkey(i, j)) { continue }
                    g.links.append((d.id, docs[j].id, "mention"))
                    explicit.insert(pairKey(i, j)); linked.insert(dkey(i, j))
                } else if unres.insert(k).inserted {
                    g.unresolved.append((d.id, k))
                }
            }
        }

        lap("links")
        // MARK: 본문 언급 (제목 4글자 이상 / 별칭 3글자 이상, 날짜·숫자·일반어 제외, 경계 규칙)
        var textCache: [Int64: String] = [:]
        var cached = 0
        func normText(_ rowid: Int64) -> String {
            if let t = textCache[rowid] { return t }
            let t = store.writerText(rowid: rowid).precomposedStringWithCanonicalMapping.lowercased()
            if cached + t.utf16.count < textCacheBudget { textCache[rowid] = t; cached += t.utf16.count }
            return t
        }
        func mentionsAny(_ names: [String], in rowid: Int64) -> Bool {
            let text = normText(rowid)
            return names.contains { occurs($0, in: text) }
        }
        var byRowid: [Int64: Int] = [:]
        for (i, d) in docs.enumerated() { byRowid[d.rowid] = i }
        // 증분: 이전 결과(cache)가 있고 바뀐 문서 목록이 있으면, 바뀐 문서만 다시 확인한다
        let incremental = changed != nil && !(mentions?.byTarget.isEmpty ?? true)
        let changedIdx = (changed ?? []).compactMap { byId[$0] }
        let commonCap = max(15, n / 100)          // 이보다 많은 문서에서 언급되는 제목은 흔한 말로 보고 버린다
        var newCache: [String: MentionCache.Entry] = [:]
        var perSource = [[(Int, Int)]](repeating: [], count: n)   // 언급한 문서 i → [(대상 j, 이름 길이)]
        for (j, b) in docs.enumerated() {
            var nameSet = Set<String>()
            if b.kind != "jira" { let t = Korean.normalize(b.title); if t.count >= 4 && mentionable(t) { nameSet.insert(t) } }
            for a in b.aliases { let x = Korean.normalize(a); if x.count >= 3 && mentionable(x) { nameSet.insert(x) } }
            let names = nameSet.sorted()
            var srcs = Set<String>()
            var tooCommon = false
            if names.isEmpty {
                // 언급 대상이 아님
            } else if incremental, let old = mentions?.byTarget[b.id], old.names == names, !(changed ?? []).contains(b.id) {
                srcs = old.srcs.filter { byId[$0] != nil && !(changed ?? []).contains($0) }
                tooCommon = old.tooCommon
                if !tooCommon {
                    for i in changedIdx where i != j && mentionsAny(names, in: docs[i].rowid) { srcs.insert(docs[i].id) }
                }
            } else {
                for name in names {
                    // 제목의 색인 토큰 열 그대로를 구문으로 찾는다 (본문 토큰 열과 같은 규칙이라 정확하고 빠르다)
                    let toks = Korean.indexTokens(name)
                    guard !toks.isEmpty else { continue }
                    let cands = store.writerFTS("body_t : \"" + toks.joined(separator: " ") + "\"", limit: maxMentionCandidates + 1)
                    if cands.count > maxMentionCandidates { tooCommon = true; break }
                    for r in cands {
                        guard let i = byRowid[r], i != j, !srcs.contains(docs[i].id) else { continue }
                        if occurs(name, in: normText(r)) { srcs.insert(docs[i].id) }
                    }
                }
            }
            newCache[b.id] = MentionCache.Entry(names: names, srcs: srcs, tooCommon: tooCommon)
            if tooCommon || srcs.count > commonCap { continue }
            let len = names.map { $0.count }.max() ?? 0
            for sid in srcs {
                guard let i = byId[sid], i != j, !linked.contains(dkey(i, j)) else { continue }
                perSource[i].append((j, len))
            }
        }
        mentions?.byTarget = newCache
        // 문서당 최대 10개 (긴 제목 우선)
        for (i, list) in perSource.enumerated() where !list.isEmpty {
            let top = list.sorted { $0.1 > $1.1 || ($0.1 == $1.1 && docs[$0.0].id < docs[$1.0].id) }.prefix(maxMentionsPerDoc)
            for (j, _) in top {
                g.links.append((docs[i].id, docs[j].id, "mention"))
                explicit.insert(pairKey(i, j)); linked.insert(dkey(i, j))
            }
        }

        lap("mentions")
        // MARK: 키워드 벡터 (tf·idf 상위 15, df ≥ 2, df ≤ 문서 수의 30%)
        var df: [String: Int] = [:]
        for d in docs { for (t, _) in tf[d.id] ?? [] { df[t, default: 0] += 1 } }
        let maxDF = max(2, Int(Double(n) * 0.3))
        var vectors = [[(String, Double)]](repeating: [], count: n)
        for (i, d) in docs.enumerated() {
            var v: [(String, Double)] = []
            for (t, c) in tf[d.id] ?? [] {
                let f = df[t] ?? 0
                guard f >= 2, f <= maxDF else { continue }
                v.append((t, (1 + log(c)) * log(Double(n) / Double(f))))
            }
            v.sort { $0.1 > $1.1 || ($0.1 == $1.1 && $0.0 < $1.0) }
            v = Array(v.prefix(topTerms))
            if let top = v.first?.1, top > 0 { v = v.map { ($0.0, $0.1 / top) } }
            vectors[i] = v
            for (t, w) in v { g.terms.append((d.id, t, (w * 1000).rounded() / 1000)) }
        }

        struct Pair { var tag = 0.0; var tagBest = ""; var tagBestW = 0.0; var kw = 0.0; var kwTerms: [(String, Double)] = []; var folder = 0.0 }
        var pairs: [Int64: Pair] = [:]

        // 같은 태그: Σ idf(tag)
        var tagDocs: [String: [Int]] = [:], tagName: [String: String] = [:]
        for (i, d) in docs.enumerated() {
            for t in Set(d.tags.map { $0.lowercased() }) { tagDocs[t, default: []].append(i) }
            for t in d.tags where tagName[t.lowercased()] == nil { tagName[t.lowercased()] = t }
        }
        for (t, ids) in tagDocs where ids.count >= 2 && ids.count <= maxPosting {
            let idf = log(1 + Double(n) / Double(ids.count))
            for x in 0..<ids.count {
                for y in (x + 1)..<ids.count {
                    let k = pairKey(ids[x], ids[y])
                    if explicit.contains(k) { continue }
                    var p = pairs[k] ?? Pair()
                    p.tag += idf
                    if idf > p.tagBestW || (idf == p.tagBestW && (tagName[t] ?? t) < p.tagBest) { p.tagBestW = idf; p.tagBest = tagName[t] ?? t }
                    pairs[k] = p
                }
            }
        }

        // 공통 키워드: 2개 이상 공유 시 Σ min(wA, wB)
        var posting: [String: [(Int, Double)]] = [:]
        for (i, v) in vectors.enumerated() { for (t, w) in v { posting[t, default: []].append((i, w)) } }
        var shared: [Int64: [(String, Double)]] = [:]
        for (t, list) in posting where list.count >= 2 && list.count <= maxPosting {
            for x in 0..<list.count {
                for y in (x + 1)..<list.count {
                    let k = pairKey(list[x].0, list[y].0)
                    if explicit.contains(k) { continue }
                    shared[k, default: []].append((t, min(list[x].1, list[y].1)))
                }
            }
        }
        let minShared = n >= 1000 ? 3 : 2      // 큰 자료에서는 공통 키워드 3개 이상
        for (k, terms) in shared where terms.count >= minShared {
            var p = pairs[k] ?? Pair()
            p.kw = terms.reduce(0) { $0 + $1.1 }
            p.kwTerms = terms.sorted { $0.1 > $1.1 || ($0.1 == $1.1 && $0.0 < $1.0) }
            pairs[k] = p
        }

        // 같은 폴더 (문서 30개 이하): 키워드 겹침이 가장 큰 2개까지
        var folders: [String: [Int]] = [:]
        for (i, d) in docs.enumerated() { folders[d.sourceId + "\u{1}" + d.folder, default: []].append(i) }
        for (_, ids) in folders where ids.count >= 2 && ids.count <= 30 {
            for a in ids {
                let va = Dictionary(vectors[a], uniquingKeysWith: { x, _ in x })
                let ranked = ids.filter { $0 != a && !explicit.contains(pairKey(a, $0)) }.map { b -> (Int, Double) in
                    (b, vectors[b].reduce(0) { $0 + min($1.1, va[$1.0] ?? 0) })
                }.sorted { $0.1 > $1.1 || ($0.1 == $1.1 && docs[$0.0].modified > docs[$1.0].modified) }
                for (b, ov) in ranked.prefix(2) {
                    let k = pairKey(a, b)
                    var p = pairs[k] ?? Pair()
                    p.folder = max(p.folder, 0.3 + min(ov, 1.0) * 0.4)
                    pairs[k] = p
                }
            }
        }

        lap("pairs")
        // 문서당 상위 8개
        var perDoc = [[(Int, Double, String, String)]](repeating: [], count: n)
        for (k, p) in pairs {
            let a = Int(k >> 32), b = Int(k & 0xffff_ffff)
            let score = p.tag + p.kw + p.folder
            guard score > 0 else { continue }
            let kind: String, reason: String
            if p.tag >= p.kw && p.tag >= p.folder {
                kind = "tag"; reason = "같은 태그 #" + p.tagBest
            } else if p.kw >= p.folder {
                kind = "keyword"; reason = "공통 키워드 · " + p.kwTerms.prefix(2).map { $0.0 }.joined(separator: "·")
            } else {
                kind = "folder"
                reason = docs[a].kind == "jira" ? "같은 프로젝트" : docs[a].kind == "confluence" ? "같은 스페이스" : "같은 폴더"
            }
            perDoc[a].append((b, score, kind, reason))
            perDoc[b].append((a, score, kind, reason))
        }
        for (i, list) in perDoc.enumerated() {
            var kw = 0
            let top = list.sorted { $0.1 > $1.1 || ($0.1 == $1.1 && docs[$0.0].modified > docs[$1.0].modified) }.filter {
                if $0.2 != "keyword" { return true }
                kw += 1; return kw <= maxKeywordPerDoc        // 키워드 연결은 문서당 최대 6개
            }.prefix(maxRelated)
            for (j, s, kind, reason) in top {
                g.related.append((docs[i].id, docs[j].id, (s * 1000).rounded() / 1000, kind, reason))
            }
        }
        return g
    }
}
