import Foundation

// 한국어 처리 (docs/CONNECT.md §3.3): 정규화·조사 떼기·초성·색인 토큰·FTS 질의·키워드 토큰·동의어.
enum Korean {
    // MARK: 정규화

    /// NFC + 소문자 + 앞뒤 공백 제거.
    static func normalize(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 글자 분류

    @inline(__always) static func isSyllable(_ v: UInt32) -> Bool { v >= 0xAC00 && v <= 0xD7A3 }
    @inline(__always) static func isJamo(_ v: UInt32) -> Bool { v >= 0x3131 && v <= 0x318E }
    @inline(__always) static func isHangul(_ v: UInt32) -> Bool { isSyllable(v) || isJamo(v) }
    @inline(__always) static func isConsonantJamo(_ v: UInt32) -> Bool { v >= 0x3131 && v <= 0x314E }

    enum WordClass { case hangul, latin }
    struct Word { let text: String; let cls: WordClass; let scalars: [Unicode.Scalar] }

    /// 정규화된 텍스트를 한글 덩어리·라틴/숫자 덩어리로 나눈다. 그 밖의 글자는 구분자.
    static func words(_ raw: String, normalized: Bool = false) -> [Word] {
        let text = normalized ? raw : raw.precomposedStringWithCanonicalMapping.lowercased()
        var out: [Word] = []
        var cur: [Unicode.Scalar] = []
        var curCls: WordClass? = nil
        func flush() {
            if let c = curCls, !cur.isEmpty {
                var s = String.UnicodeScalarView(); s.append(contentsOf: cur)
                out.append(Word(text: String(s), cls: c, scalars: cur))
            }
            cur.removeAll(keepingCapacity: true); curCls = nil
        }
        for u in text.unicodeScalars {
            let cls: WordClass?
            if isHangul(u.value) { cls = .hangul }
            else if u.properties.isAlphabetic || u.properties.numericType != nil { cls = .latin }
            else { cls = nil }
            if cls == nil { flush(); continue }
            if cls != curCls { flush(); curCls = cls }
            cur.append(u)
        }
        flush()
        return out
    }

    // MARK: 조사

    static let josa: [String] = ["에서는", "으로는", "에게서", "까지는", "부터는", "이라는",
                                 "에서", "으로", "에게", "까지", "부터", "이나", "처럼", "보다", "라는",
                                 "은", "는", "이", "가", "을", "를", "에", "의", "도", "만", "와", "과", "로"]
    private static let josaScalars: [[Unicode.Scalar]] = josa.map { Array($0.unicodeScalars) }

    /// 끝의 조사를 한 번 뗀다. 남는 어간이 2음절 이상일 때만.
    static func stripJosa(_ word: String) -> String {
        let s = Array(word.unicodeScalars)
        return String(String.UnicodeScalarView(stripJosa(scalars: s)))
    }

    static func stripJosa(scalars s: [Unicode.Scalar]) -> [Unicode.Scalar] {
        guard s.count >= 3 else { return s }
        for j in josaScalars where s.count - j.count >= 2 {
            if s.count >= j.count && Array(s[(s.count - j.count)...]) == j {
                return Array(s[..<(s.count - j.count)])
            }
        }
        return s
    }

    // MARK: 색인 토큰

    /// FTS에 넣을 공백 구분 토큰: 라틴은 단어 그대로, 한글은 (조사 뗀 어간) + 2글자 조각들. 1글자 한글은 그대로.
    static func indexTokens(_ text: String) -> [String] {
        var out: [String] = []
        out.reserveCapacity(text.utf16.count / 2)
        for w in words(text) {
            switch w.cls {
            case .latin: out.append(w.text)
            case .hangul:
                let s = w.scalars
                if s.count == 1 { out.append(w.text); continue }
                let stem = stripJosa(scalars: s)
                if s.count > 2 || stem.count != s.count { out.append(String(String.UnicodeScalarView(stem))) }
                for i in 0..<(s.count - 1) {
                    var v = String.UnicodeScalarView(); v.append(s[i]); v.append(s[i + 1])
                    out.append(String(v))
                }
            }
        }
        return out
    }

    static func indexString(_ text: String) -> String { indexTokens(text).joined(separator: " ") }

    // MARK: 검색 질의

    /// 검색어 → 정규화된 단어(조사 뗀 형태) 목록. 중복 제거, 순서 유지.
    static func queryTerms(_ query: String) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for part in normalize(query).split(whereSeparator: { $0.isWhitespace }) {
            var t = String(part)
            if let last = t.unicodeScalars.last, isSyllable(last.value) { t = stripJosa(t) }
            if !t.isEmpty && seen.insert(t).inserted { out.append(t) }
        }
        return out
    }

    /// 한 검색어 → FTS5 식. 한글 2글자 이상은 2글자 조각 구문, 1글자는 접두, 라틴은 접두. 덩어리끼리는 AND.
    static func ftsExpression(term: String) -> String? {
        var parts: [String] = []
        var latinRun: [String] = []
        func flushLatin() {
            if !latinRun.isEmpty { parts.append("\"" + latinRun.joined(separator: " ") + "\"*"); latinRun = [] }
        }
        for w in words(term, normalized: true) {
            switch w.cls {
            case .latin: latinRun.append(w.text)
            case .hangul:
                flushLatin()
                let s = w.scalars
                if s.count == 1 { parts.append("\"" + w.text + "\"*"); continue }
                var grams: [String] = []
                for i in 0..<(s.count - 1) {
                    var v = String.UnicodeScalarView(); v.append(s[i]); v.append(s[i + 1]); grams.append(String(v))
                }
                parts.append("\"" + grams.joined(separator: " ") + "\"")
            }
        }
        flushLatin()
        if parts.isEmpty { return nil }
        return parts.count == 1 ? parts[0] : "(" + parts.joined(separator: " AND ") + ")"
    }

    /// 여러 검색어를 OR로 묶은 FTS5 식.
    static func ftsQuery(_ terms: [String]) -> String? {
        let ex = terms.compactMap { ftsExpression(term: $0) }
        return ex.isEmpty ? nil : ex.joined(separator: " OR ")
    }

    // MARK: 초성

    private static let choTable: [Unicode.Scalar] = "ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ".unicodeScalars.map { $0 }

    /// 한글 음절은 초성으로, 공백은 공백으로, 나머지는 소문자 그대로.
    static func choseong(_ text: String) -> String {
        var v = String.UnicodeScalarView()
        for u in text.precomposedStringWithCanonicalMapping.lowercased().unicodeScalars {
            if isSyllable(u.value) { v.append(choTable[Int((u.value - 0xAC00) / 588)]) }
            else if u.properties.isWhitespace { v.append(" ") }
            else { v.append(u) }
        }
        return String(v)
    }

    /// 질의가 자음(ㄱ–ㅎ)과 공백만으로 이루어졌는가.
    static func isChoseongQuery(_ q: String) -> Bool {
        var any = false
        for u in q.unicodeScalars {
            if isConsonantJamo(u.value) { any = true }
            else if !u.properties.isWhitespace { return false }
        }
        return any
    }

    // MARK: 동의어 (v0.2 data.js 10묶음)

    static let synonyms: [[String]] = [
        ["검색", "찾기", "찾아", "search"],
        ["아이디어", "발상", "생각", "idea"],
        ["정산", "입금", "settlement"],
        ["환불", "취소", "refund"],
        ["결제", "지불", "payment"],
        ["고객", "사용자", "customer"],
        ["해지", "이탈"],
        ["인덱스", "색인", "index"],
        ["연결", "그래프", "시냅스", "synapse"],
        ["단축키", "런처", "shortcut"],
    ]

    /// 정확한 검색어에 대한 동의어 확장(정확한 검색어 제외).
    static func expand(_ exact: [String]) -> [String] {
        var out: [String] = [], seen = Set(exact)
        for t in exact {
            for g in synonyms where g.contains(t) {
                for x in g where seen.insert(x).inserted { out.append(x) }
            }
        }
        return out
    }

    // MARK: 키워드 토큰

    static let stopwords: Set<String> = [
        "그리고", "하지만", "그러나", "그래서", "또는", "있다", "없다", "하는", "위해", "위한", "대한", "대해", "통해",
        "것", "수", "등", "및", "이번", "다음", "정리", "메모", "이런", "그런", "저런", "어떤", "같은", "있는", "없는",
        "없이", "같이", "함께", "아직", "이미", "다시", "모두", "바로", "너무", "매우", "정말", "그냥", "계속", "전까지",
        "이후", "이전", "보여", "해야", "하면", "되면", "어서", "에서", "부터", "까지", "지금", "오늘", "어제", "내일", "예정", "필요", "확인", "진행", "관련", "사용", "내용", "방법",
        "우리", "그것", "이것", "저것", "여기", "거기", "때문", "경우", "정도", "부분", "가장", "먼저", "모든", "각각",
        "the", "and", "for", "with", "that", "this", "from", "are", "was", "were", "not", "but", "you", "your",
        "has", "have", "had", "will", "can", "all", "any", "into", "its", "our", "out", "about", "http", "https", "www", "com",
    ]
    static let verbEndings: [String] = ["하다", "했다", "한다", "된다", "있다", "없다", "이다", "합니다", "습니다", "해요",
                                        "하고", "하며", "했던", "하는", "하여", "해서", "되어", "되는", "하게", "했고",
                                        "하지", "하면", "되면", "었다", "았다", "겠다", "니다", "세요", "해야", "하기", "되기",
                                        "는데", "있고", "없고", "있어", "없어", "였다", "끝난", "되지"]

    /// 키워드 후보: 조사 뗀 한글 2–8음절 + 라틴 3글자 이상, 불용어·용언 어미 제외.
    static func keywordTokens(_ text: String) -> [String] {
        var out: [String] = []
        for w in words(text) {
            switch w.cls {
            case .latin:
                guard w.scalars.count >= 3, w.scalars.count <= 30 else { continue }
                if w.scalars.allSatisfy({ $0.properties.numericType != nil }) { continue }
                if stopwords.contains(w.text) { continue }
                out.append(w.text)
            case .hangul:
                if w.scalars.contains(where: { isJamo($0.value) }) { continue }
                let stem = stripJosa(scalars: w.scalars)
                guard stem.count >= 2, stem.count <= 8 else { continue }
                let s = String(String.UnicodeScalarView(stem))
                if stopwords.contains(s) { continue }
                if verbEndings.contains(where: { s.hasSuffix($0) }) { continue }
                if stem.count >= 3 && s.hasSuffix("다") { continue }   // 알린다·보낸다 같은 용언
                // 2음절인데 끝이 조사(은·는·을·를·에)면 1음절 명사+조사로 보고 버린다 (건은, 일을 …)
                if stem.count == 2, let l = stem.last, ["은", "는", "을", "를", "에"].contains(Character(l)) { continue }
                out.append(s)
            }
        }
        return out
    }

    // MARK: 이슈 키

    private static let issueRegex = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_-])[A-Z][A-Z0-9]+-[0-9]+(?![A-Za-z0-9_])")
    /// 흔한 비이슈 접두어 (UTF-8, ISO-8601 …)
    static let nonIssuePrefixes: Set<String> = ["UTF", "ISO", "SHA", "RFC", "UTC", "GMT", "CP", "EUC", "KS", "MD", "AES",
                                                "RSA", "TLS", "SSL", "HTTP", "IPV", "COVID", "ES", "ECMA", "IEEE", "PEP", "CVE", "KST", "X"]

    static func isIssueKey(_ s: String) -> Bool {
        let r = NSRange(s.startIndex..., in: s)
        guard let m = issueRegex.firstMatch(in: s, range: r) else { return false }
        return m.range == r
    }

    /// 본문에 나온 Jira 키(중복 제거, 순서 유지).
    static func issueKeys(in text: String) -> [String] {
        var seen = Set<String>(), out: [String] = []
        let ns = text as NSString
        issueRegex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, stop in
            guard let m = m else { return }
            let k = ns.substring(with: m.range)
            let prefix = String(k[..<(k.firstIndex(of: "-") ?? k.endIndex)])
            if !nonIssuePrefixes.contains(prefix), seen.insert(k).inserted { out.append(k) }
            if out.count >= 200 { stop.pointee = true }
        }
        return out
    }
}
