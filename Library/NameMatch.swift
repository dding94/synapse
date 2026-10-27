import Foundation

// v0.7 F: 검색에서 파일 이름(또는 제목)이 검색어와 정확히 같은 문서를 맨 위에, 그다음 파일 이름의 번호 접두가 같은 문서를 둔다.
// 점수 계산(Views.search)은 그대로 두고, 그 결과를 안정적으로 다시 묶는다(같은 묶음 안의 순서는 기존 그대로).
//  - 비교는 정규화한 값으로 한다: 대소문자·NFC·확장자·`_`·`-`·공백·기호 차이를 무시한다 (Korean.normalize 규칙 위에서).
//  - 1순위 "이름 일치": 정규화한 검색어 == 정규화한 (파일 이름 확장자 뺀 것 | 제목). Jira는 이슈 키도 이름으로 본다.
//  - 2순위 "번호 일치": 정규화한 검색어 == 정규화한 파일 이름의 번호 접두 (`ADR-011` → `ADR-011_…`).
//  - 초성 검색이나 정규화 뒤 비는 검색어에는 쓰지 않는다.

enum NameMatch {
    static let docExts: Set<String> = ["md", "markdown", "txt", "text", "pdf", "docx", "doc", "rtf", "odt", "html", "htm", "hwpx"]

    final class Index {
        var exact: [String: [Int]] = [:]     // 정규화 이름(파일 이름·제목·Jira 키) → 문서
        var prefix: [String: [Int]] = [:]    // 정규화 번호 접두 → 문서

        init(_ snap: Snapshot) {
            for (i, doc) in snap.docs.enumerated() {
                let d = doc.m
                var names: [String] = [d.title]
                var stem = ""
                if d.kind == "jira" {
                    if let k = d.id.components(separatedBy: ":jira:").last { names.append(k); stem = k }
                } else if d.kind != "confluence" {
                    let rel = String(d.id.dropFirst(d.sourceId.count + 1))
                    stem = Indexer.nfc(((rel as NSString).lastPathComponent as NSString).deletingPathExtension)
                    names.append(stem)
                } else {
                    stem = d.title
                }
                var seen = Set<String>()
                for nm in names {
                    let k = LinkFallback.normalizeTitle(nm)
                    if !k.isEmpty, seen.insert(k).inserted { exact[k, default: []].append(i) }
                }
                let base = d.kind == "jira" ? stem : Indexer.nfc(stem)
                if let pre = LinkFallback.numberPrefix(of: base), LinkFallback.endsPrefix(base, pre.count) {
                    let k = LinkFallback.normalizeTitle(pre)
                    if !k.isEmpty { prefix[k, default: []].append(i) }
                }
            }
        }
    }

    private static let lock = NSLock()
    private static var cached: (snap: Snapshot, index: Index)?
    static func index(_ snap: Snapshot) -> Index {
        lock.lock(); defer { lock.unlock() }
        if let c = cached, c.snap === snap { return c.index }
        let idx = Index(snap)
        cached = (snap, idx)
        return idx
    }

    /// 검색어 → 비교용 값. 확장자(.md 등)는 떼고, 글자·숫자 외에는 모두 뺀다. 비면 nil.
    static func key(_ query: String) -> String? {
        var q = Indexer.nfc(query).trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = (q as NSString).pathExtension.lowercased()
        if !ext.isEmpty, docExts.contains(ext) { q = (q as NSString).deletingPathExtension }
        let k = LinkFallback.normalizeTitle(q)
        return k.isEmpty ? nil : k
    }

    /// 점수순으로 정렬된 검색 결과를 "이름 일치 → 번호 일치 → 나머지"로 안정적으로 다시 묶는다.
    /// 후보(FTS 400개 상한 등)에 없던 일치 문서도 넣는다. 초성 검색이면 그대로 돌려준다.
    static func apply(_ ranked: [Views.Ranked], query: String, snap s: Snapshot) -> [Views.Ranked] {
        if Korean.isChoseongQuery(query) { return ranked }
        guard let k = key(query) else { return ranked }
        let idx = index(s)
        let exact = idx.exact[k] ?? [], pre = idx.prefix[k] ?? []
        if exact.isEmpty && pre.isEmpty { return ranked }
        let exactSet = Set(exact), preSet = Set(pre).subtracting(exactSet)
        var have = Set(ranked.map { $0.i })
        var all = ranked
        let top = ranked.first?.score ?? 50
        // 후보에 없던 문서: 최근 수정순으로 뒤에 붙인다 (묶음 안 순서는 아래에서 유지)
        for i in (exact + pre).sorted(by: { s.docs[$0].m.modified > s.docs[$1].m.modified }) where have.insert(i).inserted {
            all.append(Views.Ranked(i: i, score: top, reason: ""))
        }
        var a: [Views.Ranked] = [], b: [Views.Ranked] = [], rest: [Views.Ranked] = []
        for var r in all {
            if exactSet.contains(r.i) { r.reason = "이름 일치"; a.append(r) }
            else if preSet.contains(r.i) { r.reason = "번호 일치"; b.append(r) }
            else { rest.append(r) }
        }
        return a + b + rest
    }
}
