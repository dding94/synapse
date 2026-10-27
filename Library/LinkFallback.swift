import Foundation

// v0.7 F: 번호형·제목형 [[링크]]를 색인·그래프·문서 보기가 같은 규칙으로 푼다.
// v0.6 P0에서는 문서를 열 때(Notes.LinkIndex.resolveMore)만 맞췄고, 색인(links 표)·그래프에는 없었다.
// 규칙은 여기 한 곳에 두고 Relate(색인)와 Notes(문서 보기)가 같은 코드를 쓴다.
//  - 기존 해석기(이름·별칭·경로·이슈 키)가 못 찾은 로컬 링크에만 쓴다. 원격 문서가 건 링크·id: 링크는 대상이 아니다.
//  - 번호 접두("ADR-011: 제목" → ADR-011) → Jira 키 → 정규화 제목 순. 같은 출처에서 하나로 정해질 때만 돌려준다.
//  - 사전(접두 → 문서들, 정규화 이름 → 문서들)을 미리 만들어 링크 하나를 O(1)에 가깝게 푼다.

final class LinkFallback {
    private let docs: [DocMetaRow]
    private var byPrefix: [String: [String: [Int]]] = [:]    // sourceId → 소문자 번호 접두("adr-011") → 문서
    private var byNorm: [String: [String: Set<Int>]] = [:]   // sourceId → 정규화 이름(파일 이름·제목·별칭) → 문서
    private var jira: [String: [Int]] = [:]                  // KEY → jira 문서

    init(docs: [DocMetaRow]) {
        self.docs = docs
        for (i, d) in docs.enumerated() {
            if d.kind == "confluence" { continue }
            if d.kind == "jira" {
                if let k = d.id.components(separatedBy: ":jira:").last { jira[k, default: []].append(i) }
                continue
            }
            let rel = String(d.id.dropFirst(d.sourceId.count + 1))
            let file = (rel as NSString).lastPathComponent
            let stem = Indexer.nfc((file as NSString).deletingPathExtension)
            if let pre = LinkFallback.numberPrefix(of: stem), LinkFallback.endsPrefix(stem, pre.count) {
                byPrefix[d.sourceId, default: [:]][pre.lowercased(), default: []].append(i)
            }
            for nm in [stem, d.title] + d.aliases {
                let k = LinkFallback.normalizeTitle(nm)
                if !k.isEmpty { byNorm[d.sourceId, default: [:]][k, default: Set()].insert(i) }
            }
        }
    }

    // MARK: 번호 접두·정규화 제목

    private static let numberRegex = try! NSRegularExpression(pattern: #"^[A-Za-z][A-Za-z0-9]*-\d+"#)
    /// "ADR-011: 제목" → "ADR-011". 번호로 시작하지 않으면 nil.
    static func numberPrefix(of s: String) -> String? {
        guard let m = numberRegex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range, in: s) else { return nil }
        return String(s[r])
    }
    /// 번호 접두 바로 뒤가 끝·_·공백·-·. 인지 (ADR-011 과 ADR-0110을 구분하는 건 정규식이 숫자를 끝까지 먹는 덕분).
    static func endsPrefix(_ s: String, _ n: Int) -> Bool {
        let rest = s.dropFirst(n)
        guard let c = rest.first else { return true }
        return c == "_" || c == " " || c == "-" || c == "."
    }
    /// 소문자·NFC, 글자·숫자(한글 포함) 외에는 모두 뺀다.
    static func normalizeTitle(_ s: String) -> String {
        String(String.UnicodeScalarView(Indexer.nfc(s).lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    // MARK: 해석

    /// 후보가 여럿이면 링크를 건 문서와 같은 폴더 → 같은 최상위 폴더 순으로 좁힌다. 그래도 여럿이면 nil.
    private func narrow(_ cands: [Int], near a: DocMetaRow) -> Int? {
        let uniq = Array(Set(cands)).sorted()
        if uniq.count == 1 { return uniq[0] }
        let same = uniq.filter { docs[$0].folder == a.folder }
        if same.count == 1 { return same[0] }
        if same.count > 1 { return nil }
        func top(_ f: String) -> String { f.split(separator: "/").first.map(String.init) ?? "" }
        let sameTop = uniq.filter { top(docs[$0].folder) == top(a.folder) }
        return sameTop.count == 1 ? sameTop[0] : nil
    }

    /// 개발용 통계: 번호 접두 후보가 여럿이라 좁히지 못한 링크인가.
    func isAmbiguousPrefix(_ raw: String, from a: DocMetaRow) -> Bool {
        let t = Indexer.nfc(raw)
        guard let pre = LinkFallback.numberPrefix(of: t), let c = byPrefix[a.sourceId]?[pre.lowercased()] else { return false }
        return Set(c).count > 1
    }

    /// 기존 해석기가 못 찾은 대상을 한 번 더 맞춘다: 번호 접두("id") → Jira 키("jira") → 정규화 제목("title").
    /// 같은 출처에서 하나로 정해질 때만 돌려주고, 로컬(마크다운 등)에서 건 링크에만 쓴다.
    func resolve(_ raw: String, from a: DocMetaRow) -> (doc: Int, how: String)? {
        if a.kind == "confluence" || a.kind == "jira" || raw.hasPrefix("id:") { return nil }
        var t = raw
        if let h = t.firstIndex(where: { $0 == "#" || $0 == "^" }) { t = String(t[..<h]) }
        if let bar = t.firstIndex(of: "|") { t = String(t[..<bar]) }
        t = Indexer.nfc((t.removingPercentEncoding ?? t).trimmingCharacters(in: .whitespaces))
        if t.isEmpty || t.contains("/") { return nil }
        if let pre = LinkFallback.numberPrefix(of: t) {
            if let c = byPrefix[a.sourceId]?[pre.lowercased()], let i = narrow(c, near: a) { return (i, "id") }
            if let c = jira[pre.uppercased()] {
                let i = c.first(where: { docs[$0].sourceId == a.sourceId }) ?? c.first
                if let i = i { return (i, "jira") }
            }
        }
        let k = LinkFallback.normalizeTitle(t)
        if !k.isEmpty, let c = byNorm[a.sourceId]?[k], let i = narrow(Array(c), near: a) { return (i, "title") }
        return nil
    }
}

// MARK: - 링크 규칙 판 번호 (색인 meta)

extension Store {
    /// 링크 해석 규칙의 판. 올리면 다음 연결 계산 때 다시 쓰였다고 기록된다.
    /// 1 = v0.6까지(이름·별칭·경로·이슈 키), 2 = v0.7 F(번호 접두·Jira 키·정규화 제목 보강)
    static let linkRulesVersion = "2"

    func metaValue(_ key: String) -> String? {
        var v: String? = nil
        try? writer.query("SELECT value FROM meta WHERE key=?", [.text(key)]) { v = $0.text(0) }
        return v
    }

    func setMetaValue(_ key: String, _ value: String) {
        _ = try? writer.run("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)", [.text(key), .text(value)])
    }

    /// 지금 저장된 links 표가 현재 규칙으로 만든 것인가 (없으면 v0.6 이하).
    var linksUpToDate: Bool { (metaValue("link_rules") ?? "1") == Store.linkRulesVersion }
}
