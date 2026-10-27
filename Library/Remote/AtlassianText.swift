import Foundation

/// Confluence storage XHTML / Jira ADF JSON → 평문. 네트워크·상태 없음.
enum AtlassianText {

    // MARK: - 공용

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
                                       "nbsp": " ", "ndash": "–", "mdash": "—", "hellip": "…",
                                       "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
                                       "middot": "·", "bull": "•", "rarr": "→", "larr": "←"]
        while i < s.endIndex {
            let c = s[i]
            if c == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let name = String(s[s.index(after: i)..<semi])
                var rep: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    if let v = UInt32(name.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) { rep = String(Character(u)) }
                } else if name.hasPrefix("#") {
                    if let v = UInt32(name.dropFirst(1)), let u = Unicode.Scalar(v) { rep = String(Character(u)) }
                } else {
                    rep = named[name]
                }
                if let r = rep { out += r; i = s.index(after: semi); continue }
            }
            out.append(c)
            i = s.index(after: i)
        }
        return out
    }

    private static func regex(_ p: String, _ opts: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators]) -> NSRegularExpression {
        return try! NSRegularExpression(pattern: p, options: opts)
    }

    private static func replace(_ re: NSRegularExpression, in s: String, with t: String) -> String {
        return re.stringByReplacingMatches(in: s, options: [], range: NSRange(s.startIndex..., in: s), withTemplate: t)
    }

    private static func tidy(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\r", with: "")
        t = t.replacingOccurrences(of: "\u{00A0}", with: " ")
        let lines = t.components(separatedBy: "\n").map { line -> String in
            var l = line.trimmingCharacters(in: .whitespaces)
            while l.hasSuffix("|") { l = String(l.dropLast()).trimmingCharacters(in: .whitespaces) }
            while l.contains("  ") { l = l.replacingOccurrences(of: "  ", with: " ") }
            return l
        }
        var out: [String] = []
        var blank = 0
        for l in lines {
            if l.isEmpty { blank += 1; if blank <= 1 && !out.isEmpty { out.append("") } }
            else { blank = 0; out.append(l) }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Confluence storage format

    private static let reCData = regex("<!\\[CDATA\\[(.*?)\\]\\]>")
    private static let rePageTitle = regex("<ri:page\\b[^>]*?ri:content-title\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')")
    private static let reAcLinkPage = regex("<ac:link\\b[^>]*>\\s*<ri:page\\b[^>]*?ri:content-title\\s*=\\s*\"([^\"]*)\"[^>]*/?>\\s*</ac:link>")
    private static let reParams = regex("<ac:parameter\\b[^>]*>.*?</ac:parameter>")
    private static let reBlockClose = regex("</(p|div|h[1-6]|tr|ul|ol|table|blockquote|pre|ac:task|ac:rich-text-body|ac:structured-macro)>|<br\\s*/?>|<hr\\s*/?>")
    private static let reLiOpen = regex("<li\\b[^>]*>")
    private static let reCellClose = regex("</t[dh]>")
    private static let reTag = regex("<[^>]+>")

    /// storage XHTML → (평문, 페이지 링크 제목들[중복 제거, 순서 유지]).
    static func storageToText(_ xhtml: String) -> (text: String, links: [String]) {
        var links: [String] = []
        var seen = Set<String>()
        let ns = xhtml as NSString
        for m in rePageTitle.matches(in: xhtml, options: [], range: NSRange(location: 0, length: ns.length)) {
            for g in 1...2 where m.range(at: g).location != NSNotFound {
                let t = decodeEntities(ns.substring(with: m.range(at: g))).trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty && seen.insert(t).inserted { links.append(t) }
            }
        }
        var s = xhtml
        // 코드 등 CDATA: 태그 제거에서 살리려고 이스케이프해서 남긴다.
        let cs = s as NSString
        var rebuilt = ""
        var last = 0
        for m in reCData.matches(in: s, options: [], range: NSRange(location: 0, length: cs.length)) {
            rebuilt += cs.substring(with: NSRange(location: last, length: m.range.location - last))
            let body = cs.substring(with: m.range(at: 1))
            rebuilt += body.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            last = m.range.location + m.range.length
        }
        rebuilt += cs.substring(from: last)
        s = rebuilt
        s = replace(reAcLinkPage, in: s, with: "$1")        // 본문 없는 페이지 링크는 제목을 글자로
        s = replace(reParams, in: s, with: "")              // 매크로 설정값은 본문이 아님
        s = replace(reLiOpen, in: s, with: "\n- ")
        s = replace(reCellClose, in: s, with: " | ")
        s = replace(reBlockClose, in: s, with: "\n")
        s = replace(reTag, in: s, with: "")
        s = decodeEntities(s)
        return (tidy(s), links)
    }

    // MARK: - Jira ADF

    /// ADF(JSON) 또는 v2 문자열 → 평문.
    static func adfToText(_ node: Any?) -> String {
        if let str = node as? String { return tidy(str) }
        guard let n = node as? [String: Any] else { return "" }
        var out = ""
        adf(n, &out)
        return tidy(out)
    }

    private static func adf(_ node: [String: Any], _ out: inout String) {
        let type = node["type"] as? String ?? ""
        let attrs = node["attrs"] as? [String: Any] ?? [:]
        let kids = node["content"] as? [[String: Any]] ?? []
        switch type {
        case "text":
            out += node["text"] as? String ?? ""
        case "hardBreak":
            out += "\n"
        case "mention":
            out += (attrs["text"] as? String) ?? ""
        case "emoji":
            out += (attrs["text"] as? String) ?? (attrs["shortName"] as? String) ?? ""
        case "inlineCard":
            out += (attrs["url"] as? String) ?? ""
        case "status":
            out += (attrs["text"] as? String) ?? ""
        case "date":
            if let ts = attrs["timestamp"] as? String, let ms = Double(ts) {
                let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
                out += f.string(from: Date(timeIntervalSince1970: ms / 1000))
            }
        case "listItem":
            if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
            out += "- "
            for k in kids { adf(k, &out) }
            if !out.hasSuffix("\n") { out += "\n" }
        case "tableCell", "tableHeader":
            for k in kids { adf(k, &out) }
            out += " | "
        case "paragraph", "heading", "blockquote", "codeBlock", "tableRow", "panel", "rule", "bulletList", "orderedList", "table", "expand", "taskItem", "decisionItem":
            for k in kids { adf(k, &out) }
            out += "\n"
        default:
            for k in kids { adf(k, &out) }   // doc, mediaSingle 등
        }
    }
}
