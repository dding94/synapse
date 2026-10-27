import Foundation

// 링크 찾기·해석 (§6.7). 옵시디언과 같게, 단순하게. 코드 블록·인라인 코드 안은 무시한다.
// 위치는 NSString(UTF-16) 범위라서 그 범위만 바꾸면 나머지 바이트(BOM·줄바꿈·공백)는 그대로 남는다.

/// 볼트 파일 목록(NFC 상대 경로). 이동 전후를 따로 만들어 해석을 비교한다.
struct VaultFiles {
    private(set) var rels: Set<String> = []
    private var lower: [String: String] = [:]
    private var byName: [String: [String]] = [:]

    init(_ list: [String]) { for r in list { insert(r) } }

    mutating func insert(_ r: String) {
        guard rels.insert(r).inserted else { return }
        lower[r.lowercased()] = r
        for k in VaultFiles.nameKeys(r) { byName[k, default: []].append(r) }
    }
    mutating func remove(_ r: String) {
        guard rels.remove(r) != nil else { return }
        lower[r.lowercased()] = nil
        for k in VaultFiles.nameKeys(r) { byName[k]?.removeAll { $0 == r } }
    }
    func moving(_ from: String, to: String) -> VaultFiles { var c = self; c.remove(from); c.insert(to); return c }

    /// 이름 열쇠: 파일 이름(소문자), md면 확장자 뺀 이름도.
    static func nameKeys(_ r: String) -> [String] {
        let file = (r as NSString).lastPathComponent.lowercased()
        return Organizer.isMarkdown(file) ? [file, (file as NSString).deletingPathExtension] : [file]
    }
    func exact(_ p: String) -> String? { lower[p.lowercased()] }
    func named(_ n: String) -> [String] { byName[n.lowercased()] ?? [] }
    func suffixed(_ p: String) -> [String] { let s = "/" + p.lowercased(); return rels.filter { $0.lowercased().hasSuffix(s) }.sorted() }
}

struct LinkRef {
    enum Kind { case wiki, markdown, canvas }
    var kind: Kind
    var range: NSRange            // 바꿀 범위: 위키 [[ ]] 안쪽, 마크다운 ( ) 안쪽, 캔버스 따옴표 안쪽
    var embed = false
    var target = ""               // 위키: #·| 앞 원문. 마크다운: 경로 원문(인코딩 그대로). 캔버스: 풀린 경로
    var sub = ""                  // "#제목" · "#^블록" · 마크다운 "#조각"
    var alias: String? = nil
    var pipe = "|"                // 표 안이면 "\|"
    var angle = false
    var lead = ""                 // 마크다운 ( 뒤 공백
    var tail = ""                 // 마크다운 ' "제목"'
    var inFrontmatter = false
    var outer = NSRange(location: 0, length: 0)   // 링크 전체(화면의 "옛 링크" 표시용)
}

enum LinkScan {
    private static func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    static let wiki = rx(#"(!?)\[\[([^\[\]\n]+?)\]\]"#)
    static let md = rx(#"(!?)\[([^\[\]\n]*)\]\(([^()\n]*)\)"#)
    static let inlineCode = rx(#"(`+)(?!`)(.+?)(?<!`)\1(?!`)"#)
    static let scheme = rx(#"^[A-Za-z][A-Za-z0-9+.\-]*:"#)
    static let canvasFile = rx(#""file"\s*:\s*"((?:[^"\\]|\\.)*)""#)

    static func scan(_ text: String, canvas: Bool) -> [LinkRef] { canvas ? canvasLinks(text) : markdown(text) }

    static func markdown(_ text: String) -> [LinkRef] {
        let ns = text as NSString
        var out: [LinkRef] = []
        var pos = 0, lineNo = 0, fence: Character? = nil, fenceLen = 0, inFM = false
        while pos < ns.length {
            let lr = ns.lineRange(for: NSRange(location: pos, length: 0))
            var end = lr.location + lr.length
            while end > lr.location, let u = UnicodeScalar(ns.character(at: end - 1)), u == "\n" || u == "\r" { end -= 1 }
            let start = lr.location
            pos = lr.location + lr.length
            let line = ns.substring(with: NSRange(location: start, length: end - start))
            defer { lineNo += 1 }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if lineNo == 0 && trimmed == "---" { inFM = true; continue }
            if inFM {
                if trimmed == "---" || trimmed == "..." { inFM = false; continue }
                out += wikiLinks(line, offset: start, skip: []).map { var l = $0; l.inFrontmatter = true; return l }
                continue
            }
            let body = line.drop(while: { $0 == " " })
            if line.count - body.count <= 3, let c = body.first, c == "`" || c == "~" {
                let run = body.prefix(while: { $0 == c }).count
                if run >= 3 {
                    if let open = fence {
                        if c == open, run >= fenceLen, body.dropFirst(run).allSatisfy({ $0 == " " }) { fence = nil }
                    } else { fence = c; fenceLen = run }
                    continue
                }
            }
            if fence != nil { continue }
            let lns = line as NSString
            let code = inlineCode.matches(in: line, range: NSRange(location: 0, length: lns.length)).map { $0.range }
            let wikis = wikiLinks(line, offset: start, skip: code)
            out += wikis
            let taken = code + wikis.map { NSRange(location: $0.range.location - start - 2, length: $0.range.length + 4) }
            out += mdLinks(line, offset: start, skip: taken)
        }
        return out
    }

    private static func overlaps(_ r: NSRange, _ list: [NSRange]) -> Bool { list.contains { NSIntersectionRange($0, r).length > 0 } }

    static func wikiLinks(_ line: String, offset: Int, skip: [NSRange]) -> [LinkRef] {
        guard line.contains("[[") else { return [] }
        let ns = line as NSString
        var out: [LinkRef] = []
        for m in wiki.matches(in: line, range: NSRange(location: 0, length: ns.length)) where !overlaps(m.range, skip) {
            let inner = ns.substring(with: m.range(at: 2))
            var l = LinkRef(kind: .wiki, range: NSRange(location: offset + m.range(at: 2).location, length: m.range(at: 2).length))
            l.embed = m.range(at: 1).length > 0
            l.outer = NSRange(location: offset + m.range.location, length: m.range.length)
            var head = inner
            if let r = inner.range(of: "\\|") { l.pipe = "\\|"; head = String(inner[..<r.lowerBound]); l.alias = String(inner[r.upperBound...]) }
            else if let r = inner.firstIndex(of: "|") { head = String(inner[..<r]); l.alias = String(inner[inner.index(after: r)...]) }
            if let h = head.firstIndex(of: "#") { l.target = String(head[..<h]); l.sub = String(head[h...]) } else { l.target = head }
            out.append(l)
        }
        return out
    }

    static func mdLinks(_ line: String, offset: Int, skip: [NSRange]) -> [LinkRef] {
        guard line.contains("](") else { return [] }
        let ns = line as NSString
        var out: [LinkRef] = []
        for m in md.matches(in: line, range: NSRange(location: 0, length: ns.length)) where !overlaps(m.range, skip) {
            let raw = ns.substring(with: m.range(at: 3))
            var l = LinkRef(kind: .markdown, range: NSRange(location: offset + m.range(at: 3).location, length: m.range(at: 3).length))
            l.embed = m.range(at: 1).length > 0
            l.outer = NSRange(location: offset + m.range.location, length: m.range.length)
            l.lead = String(raw.prefix(while: { $0 == " " || $0 == "\t" }))
            let rest = raw.dropFirst(l.lead.count)
            var path: String
            if rest.hasPrefix("<") {
                guard let close = rest.firstIndex(of: ">") else { continue }
                l.angle = true
                path = String(rest[rest.index(after: rest.startIndex)..<close])
                l.tail = String(rest[rest.index(after: close)...])
            } else if let sp = rest.firstIndex(where: { $0 == " " || $0 == "\t" }) {
                path = String(rest[..<sp]); l.tail = String(rest[sp...])
            } else { path = String(rest) }
            if path.isEmpty || path.hasPrefix("#") { continue }
            if scheme.firstMatch(in: path, range: NSRange(location: 0, length: (path as NSString).length)) != nil { continue }
            if let h = path.firstIndex(of: "#") { l.sub = String(path[h...]); path = String(path[..<h]) }
            l.target = path
            out.append(l)
        }
        return out
    }

    static func canvasLinks(_ text: String) -> [LinkRef] {
        let ns = text as NSString
        return canvasFile.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let enc = ns.substring(with: m.range(at: 1))
            guard let d = ("\"" + enc + "\"").data(using: .utf8),
                  let v = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) as? String else { return nil }
            var l = LinkRef(kind: .canvas, range: m.range(at: 1))
            l.outer = m.range
            l.target = Indexer.nfc(v)
            return l
        }
    }

    static func jsonEscape(_ s: String) -> String {
        var o = ""
        for u in s.unicodeScalars {
            switch u {
            case "\"": o += "\\\""
            case "\\": o += "\\\\"
            case "\n": o += "\\n"
            case "\t": o += "\\t"
            default: if u.value < 0x20 { o += String(format: "\\u%04x", u.value) } else { o.unicodeScalars.append(u) }
            }
        }
        return o
    }
}

/// 해석기 (§6.7). 결과는 볼트 상대 경로, 못 찾으면 nil. via: 마크다운 링크가 어느 기준으로 풀렸나.
enum LinkResolve {
    enum Via { case relative, root, absolute, name, path, none }

    static func normPath(_ p: String) -> String? {
        var out: [Substring] = []
        for c in p.split(separator: "/") {
            if c == "." || c.isEmpty { continue }
            if c == ".." { if out.isEmpty { return nil }; out.removeLast(); continue }
            out.append(c)
        }
        return out.joined(separator: "/")
    }

    static func pick(_ cands: [String], near folder: String) -> String? {
        cands.min { a, b in
            let fa = Organizer.parent(a) == folder ? 0 : 1, fb = Organizer.parent(b) == folder ? 0 : 1
            if fa != fb { return fa < fb }
            let ca = a.split(separator: "/").count, cb = b.split(separator: "/").count
            return ca != cb ? ca < cb : a < b
        }
    }

    static func exactOrMD(_ p: String, _ files: VaultFiles) -> String? { files.exact(p) ?? files.exact(p + ".md") }

    static func resolve(_ l: LinkRef, from: String, files: VaultFiles) -> (String?, Via) {
        let folder = Organizer.parent(from)
        switch l.kind {
        case .canvas:
            return (files.exact(l.target), .path)
        case .wiki:
            let t = Indexer.nfc(l.target.trimmingCharacters(in: .whitespaces))
            if t.isEmpty { return (from, .none) }                       // [[#제목]] = 자기 자신
            if t.contains("/") {
                let rel = t.hasPrefix("./") || t.hasPrefix("../")
                guard let p = normPath(rel ? folder + "/" + t : t) else { return (nil, .path) }
                if let hit = exactOrMD(p, files) { return (hit, .path) }
                let suf = files.suffixed(p) + files.suffixed(p + ".md")
                return (suf.count == 1 ? suf[0] : nil, .path)
            }
            return (pick(files.named(t), near: folder), .name)
        case .markdown:
            let dec = Indexer.nfc(l.target.removingPercentEncoding ?? l.target)
            if dec.hasPrefix("/") { return (normPath(dec).flatMap { exactOrMD($0, files) }, .absolute) }
            if let p = normPath(folder.isEmpty ? dec : folder + "/" + dec), let hit = exactOrMD(p, files) { return (hit, .relative) }
            if !dec.hasPrefix("./") && !dec.hasPrefix("../"), let p = normPath(dec), let hit = exactOrMD(p, files) { return (hit, .root) }
            return (nil, .relative)
        }
    }

    static func target(_ l: LinkRef, from: String, files: VaultFiles) -> String? { resolve(l, from: from, files: files).0 }

    static func unresolved(_ links: [LinkRef], from: String, files: VaultFiles) -> Int {
        links.filter { target($0, from: from, files: files) == nil }.count
    }

    static func relative(from folder: String, to rel: String) -> String {
        let a = folder.split(separator: "/").map(String.init), b = rel.split(separator: "/").map(String.init)
        var i = 0
        while i < a.count && i < b.count - 1 && a[i] == b[i] { i += 1 }
        return (Array(repeating: "..", count: a.count - i) + b[i...]).joined(separator: "/")
    }
}
