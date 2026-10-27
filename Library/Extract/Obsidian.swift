import Foundation

// 마크다운·옵시디언 파서 (docs/CONNECT.md §5). 상태가 없고 어느 스레드에서나 부를 수 있다.

enum ObsidianParser {

    static func parse(_ markdown: String, fileName: String) -> ExtractedFile {
        var src = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if src.hasPrefix("\u{FEFF}") { src.removeFirst() }

        var lines = src.components(separatedBy: "\n")
        var meta = Frontmatter()
        if let end = frontmatterEnd(lines) {
            meta = parseFrontmatter(Array(lines[1..<end]))
            lines = Array(lines[(end + 1)...])
        }

        var tags: [String] = meta.tags
        var links: [String] = []
        var out: [String] = []
        out.reserveCapacity(lines.count)

        var fenceChar: Character? = nil
        var fenceLen = 0
        for raw in lines {
            let trimmed = raw.drop(while: { $0 == " " })
            if raw.count - trimmed.count <= 3, let c = trimmed.first, c == "`" || c == "~" {
                let run = trimmed.prefix(while: { $0 == c }).count
                if run >= 3 {
                    if let open = fenceChar {
                        // 닫는 울타리: 같은 문자, 같거나 긴 길이, 뒤에 다른 글자 없음
                        if c == open, run >= fenceLen, trimmed.dropFirst(run).allSatisfy({ $0 == " " }) {
                            fenceChar = nil
                        } else {
                            out.append(raw)
                        }
                    } else {
                        fenceChar = c; fenceLen = run
                    }
                    continue
                }
            }
            if fenceChar != nil { out.append(raw); continue }   // 코드 블록: 본문엔 남기되 태그·링크는 찾지 않는다

            let (prefixless, isRule) = stripLinePrefix(raw)
            if isRule { out.append(""); continue }
            var cleaned = ""
            for seg in splitInlineCode(prefixless) {
                if seg.isCode { cleaned += seg.text; continue }
                collectTags(seg.text, into: &tags)
                collectLinks(seg.text, into: &links)
                cleaned += cleanSegment(seg.text)
            }
            out.append(cleaned.trimmingCharacters(in: .whitespaces))
        }

        var text = out.joined(separator: "\n")
        while text.contains("\n\n\n") { text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        return ExtractedFile(title: meta.title, text: text, tags: dedup(tags), aliases: dedup(meta.aliases),
                             outLinks: dedup(links), created: meta.created)
    }

    // MARK: - 프런트매터

    private struct Frontmatter {
        var title: String? = nil
        var tags: [String] = []
        var aliases: [String] = []
        var created: Date? = nil
    }

    /// 첫 줄이 `---`이고 뒤에 닫는 `---`(또는 `...`)가 있으면 그 줄 번호.
    private static func frontmatterEnd(_ lines: [String]) -> Int? {
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        for i in 1..<max(lines.count, 1) {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t == "---" || t == "..." { return i }
        }
        return nil
    }

    private static func parseFrontmatter(_ lines: [String]) -> Frontmatter {
        var fm = Frontmatter()
        var i = 0
        var createdRaw: String? = nil, dateRaw: String? = nil
        while i < lines.count {
            let line = lines[i]; i += 1
            guard let first = line.first, first != " ", first != "\t", first != "#", first != "-",
                  let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            var items: [String]? = nil
            if value.isEmpty || value == "|" || value == ">" {
                // 다음 들여쓴/하이픈 줄이 목록 항목
                var list: [String] = []
                while i < lines.count {
                    let n = lines[i]
                    let t = n.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("- ") || t == "-" { list.append(unquote(String(t.dropFirst(1)).trimmingCharacters(in: .whitespaces))); i += 1 }
                    else if t.isEmpty { i += 1 }
                    else if n.first == " " || n.first == "\t" { list.append(unquote(t)); i += 1 }
                    else { break }
                }
                items = list
                value = list.joined(separator: ", ")
            } else if value.hasPrefix("[") && value.hasSuffix("]") {
                items = splitCommas(String(value.dropFirst().dropLast())).map(unquote)
            }
            switch key {
            case "title":
                let t = unquote(value)
                if !t.isEmpty { fm.title = t }
            case "tags", "tag":
                var list = items ?? splitTagScalar(unquote(value))
                list = list.map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
                fm.tags += list.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            case "aliases", "alias":
                let list = items ?? splitCommas(value).map(unquote)
                fm.aliases += list.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            case "created": createdRaw = unquote(items?.first ?? value)
            case "date": dateRaw = unquote(items?.first ?? value)
            default: break
            }
        }
        fm.created = parseDate(createdRaw) ?? parseDate(dateRaw)
        return fm
    }

    private static func unquote(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, let f = t.first, let l = t.last, (f == "\"" && l == "\"") || (f == "'" && l == "'") {
            t = String(t.dropFirst().dropLast())
        }
        return t
    }

    /// 따옴표 안의 쉼표는 나누지 않는다.
    private static func splitCommas(_ s: String) -> [String] {
        var parts: [String] = [], cur = "", quote: Character? = nil
        for ch in s {
            if let q = quote { cur.append(ch); if ch == q { quote = nil }; continue }
            if ch == "\"" || ch == "'" { quote = ch; cur.append(ch) }
            else if ch == "," { parts.append(cur); cur = "" }
            else { cur.append(ch) }
        }
        parts.append(cur)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// `tags: 회의` · `tags: a, b` · `tags: a b`
    private static func splitTagScalar(_ s: String) -> [String] {
        if s.contains(",") { return splitCommas(s).map(unquote) }
        return s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard var s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        s = s.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "")
        guard let m = dateRegex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        func num(_ i: Int) -> Int? {
            let r = m.range(at: i)
            guard r.location != NSNotFound, let rr = Range(r, in: s) else { return nil }
            return Int(s[rr])
        }
        var dc = DateComponents()
        dc.year = num(1); dc.month = num(2); dc.day = num(3)
        dc.hour = num(4) ?? 0; dc.minute = num(5) ?? 0; dc.second = num(6) ?? 0
        guard let y = dc.year, y > 1900, let mo = dc.month, (1...12).contains(mo), let d = dc.day, (1...31).contains(d) else { return nil }
        return Calendar(identifier: .gregorian).date(from: dc)
    }

    // MARK: - 줄 단위 처리

    /// 제목 `#`, 목록 `-`·`*`·`+`, 체크박스, 인용 `>` 표시를 걷어 낸다. 가로선이면 isRule.
    private static func stripLinePrefix(_ line: String) -> (String, Bool) {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.count >= 3, Set(t.filter { $0 != " " }).count == 1, let c = t.first, c == "-" || c == "*" || c == "_" { return ("", true) }
        var s = line
        s = replace(prefixQuote, in: s, with: "")
        s = replace(prefixHeading, in: s, with: "")
        s = replace(prefixBullet, in: s, with: "")
        s = replace(prefixCheck, in: s, with: "")
        return (s, false)
    }

    private struct Segment { var text: String; var isCode: Bool }

    private static func splitInlineCode(_ s: String) -> [Segment] {
        guard s.contains("`") else { return [Segment(text: s, isCode: false)] }
        let ns = s as NSString
        var segs: [Segment] = [], pos = 0
        for m in inlineCode.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > pos { segs.append(Segment(text: ns.substring(with: NSRange(location: pos, length: m.range.location - pos)), isCode: false)) }
            segs.append(Segment(text: ns.substring(with: m.range(at: 2)), isCode: true))
            pos = m.range.location + m.range.length
        }
        if pos < ns.length { segs.append(Segment(text: ns.substring(from: pos), isCode: false)) }
        return segs
    }

    private static func collectTags(_ s: String, into tags: inout [String]) {
        guard s.contains("#") else { return }
        var masked = replace(wikiLink, in: s, with: " ")
        masked = replace(mdLinkTarget, in: masked, with: "]( )")
        masked = replace(urlLike, in: masked, with: " ")
        let ns = masked as NSString
        for m in tagRegex.matches(in: masked, range: NSRange(location: 0, length: ns.length)) {
            var tag = ns.substring(with: m.range(at: 1))
            while let l = tag.last, l == "/" || l == "-" { tag.removeLast() }
            if tag.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) { tags.append(tag) }
        }
    }

    private static func collectLinks(_ s: String, into links: inout [String]) {
        let ns = s as NSString
        let full = NSRange(location: 0, length: ns.length)
        if s.contains("[[") {
            for m in wikiLink.matches(in: s, range: full) {
                let inner = ns.substring(with: m.range(at: 2))
                let target = wikiTarget(inner)
                if !target.isEmpty { links.append(target) }
            }
        }
        if s.contains("](") {
            for m in mdLink.matches(in: s, range: full) {
                if ns.substring(with: m.range(at: 1)) == "!" { continue }   // 이미지는 연결로 보지 않는다
                if let t = mdTarget(ns.substring(with: m.range(at: 3))) { links.append(t) }
            }
        }
    }

    /// `대상#제목|별칭` → `대상`
    private static func wikiTarget(_ inner: String) -> String {
        var t = inner
        if let bar = t.firstIndex(of: "|") { t = String(t[..<bar]) }
        if let hash = t.firstIndex(of: "#") { t = String(t[..<hash]) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    private static func mdTarget(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("<"), let close = t.firstIndex(of: ">") {
            t = String(t[t.index(after: t.startIndex)..<close])
        } else if let sp = t.firstIndex(where: { $0 == " " || $0 == "\t" }) {
            t = String(t[..<sp])      // "경로 \"제목\"" 형태의 제목 부분 제거
        }
        if t.isEmpty || t.hasPrefix("#") { return nil }
        if schemeRegex.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil { return nil }   // http, mailto 등
        if let hash = t.firstIndex(of: "#") { t = String(t[..<hash]) }
        t = t.removingPercentEncoding ?? t
        t = t.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    private static func cleanSegment(_ s: String) -> String {
        var r = s
        if r.contains("[[") {
            r = replace(wikiLink, in: r) { m, ns in
                let inner = ns.substring(with: m.range(at: 2))
                if let bar = inner.firstIndex(of: "|") { return String(inner[inner.index(after: bar)...]).trimmingCharacters(in: .whitespaces) }
                // [[a#b]] → a, [[a#^id]] → a
                let t = wikiTarget(inner)
                return t.isEmpty ? inner.trimmingCharacters(in: CharacterSet(charactersIn: "#^ ")) : t
            }
        }
        if r.contains("](") {
            r = replace(mdLink, in: r) { m, ns in ns.substring(with: m.range(at: 2)) }
        }
        r = r.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "").replacingOccurrences(of: "~~", with: "")
        return r
    }

    private static func dedup(_ xs: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for x in xs where seen.insert(x.lowercased()).inserted { out.append(x) }
        return out
    }

    // MARK: - 정규식 (한 번만 컴파일, 매칭은 스레드 안전)

    private static func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    private static let wikiLink = rx(#"(!?)\[\[([^\[\]\n]+?)\]\]"#)
    private static let mdLink = rx(#"(!?)\[([^\[\]\n]*)\]\(([^()\n]*)\)"#)
    private static let mdLinkTarget = rx(#"\]\([^()\n]*\)"#)
    private static let urlLike = rx(#"(?:[A-Za-z][A-Za-z0-9+.\-]*://|www\.)[^\s<>)\]]+"#)
    private static let schemeRegex = rx(#"^[A-Za-z][A-Za-z0-9+.\-]*:"#)
    private static let tagRegex = rx(#"(?:^|(?<=[\s(,;"'>]))#([\p{L}\p{N}_\-/]+)"#)
    private static let inlineCode = rx(#"(`+)(?!`)(.+?)(?<!`)\1(?!`)"#)
    private static let prefixQuote = rx(#"^\s*(?:>\s?)+"#)
    private static let prefixHeading = rx(#"^\s*#{1,6}[ \t]+"#)
    private static let prefixBullet = rx(#"^\s*[-*+][ \t]+"#)
    private static let prefixCheck = rx(#"^\[[ xX]\][ \t]+"#)
    private static let dateRegex = rx(#"(\d{4})[-./](\d{1,2})[-./](\d{1,2})(?:[T ]+(\d{1,2}):(\d{2})(?::(\d{2}))?)?"#)

    private static func replace(_ re: NSRegularExpression, in s: String, with t: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length),
                                    withTemplate: NSRegularExpression.escapedTemplate(for: t))
    }

    private static func replace(_ re: NSRegularExpression, in s: String, _ f: (NSTextCheckingResult, NSString) -> String) -> String {
        let ns = s as NSString
        var out = "", pos = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: pos, length: m.range.location - pos))
            out += f(m, ns)
            pos = m.range.location + m.range.length
        }
        out += ns.substring(from: pos)
        return out
    }
}
