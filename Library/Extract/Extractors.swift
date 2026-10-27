import Foundation
import AppKit
import PDFKit

// 형식별 본문 추출 (docs/CONNECT.md §5). 모든 함수는 상태가 없고 백그라운드 스레드에서 불러도 된다.

enum Extractors {
    static let supportedExtensions: Set<String> = [
        "md", "markdown", "txt", "text", "pdf", "docx", "doc", "rtf", "odt", "html", "htm", "hwpx",
    ]

    static let maxFileBytes = 50 * 1024 * 1024
    static let maxChars = 400_000
    static let maxPDFPages = 300

    static func extract(fileAt url: URL) throws -> ExtractedFile {
        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else { throw ExtractError.unsupported }

        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]) else {
            throw ExtractError.unreadable("파일을 열 수 없어요")
        }
        if values.isDirectory == true { throw ExtractError.unsupported }
        if let size = values.fileSize, size > maxFileBytes { throw ExtractError.tooLarge }

        var file: ExtractedFile
        switch ext {
        case "md", "markdown":
            file = ObsidianParser.parse(try readText(url), fileName: url.lastPathComponent)
        case "txt", "text":
            file = ExtractedFile(title: nil, text: try readText(url))
        case "pdf":
            file = try extractPDF(url)
        case "docx", "doc", "rtf", "odt":
            file = try extractRichText(url, ext: ext)
        case "html", "htm":
            file = extractHTML(try readText(url))
        case "hwpx":
            file = try extractHWPX(url)
        default:
            throw ExtractError.unsupported
        }
        file.text = cap(file.text)
        if let t = file.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { file.title = t } else { file.title = nil }
        return file
    }

    // MARK: - 공통

    static func cap(_ s: String) -> String {
        let cleaned = s.contains("\u{0}") ? s.replacingOccurrences(of: "\u{0}", with: " ") : s
        if cleaned.utf8.count <= maxChars { return cleaned }       // 글자 수 ≤ 바이트 수
        return String(cleaned.prefix(maxChars))
    }

    static func readData(_ url: URL) throws -> Data {
        do { return try Data(contentsOf: url) }   // 메모리 매핑 금지: 읽는 중 다른 프로그램이 파일을 잘라내도 SIGBUS가 나지 않게
        catch { throw ExtractError.unreadable("파일을 읽을 수 없어요") }
    }

    static func readText(_ url: URL) throws -> String { decodeText(try readData(url)) }

    /// UTF-8 → BOM 있는 UTF-16 → BOM 없는 UTF-16(널 바이트가 많을 때) → CP949 → EUC-KR → Latin-1
    static func decodeText(_ data: Data) -> String {
        if data.isEmpty { return "" }
        let b = [UInt8](data.prefix(4))
        if b.starts(with: [0xEF, 0xBB, 0xBF]), let s = String(data: data.dropFirst(3), encoding: .utf8) { return s }
        if b.starts(with: [0xFF, 0xFE]), let s = String(data: data, encoding: .utf16LittleEndian) { return stripBOM(s) }
        if b.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16BigEndian) { return stripBOM(s) }
        // BOM 없는 UTF-16: 널 바이트가 주로 한쪽 자리(짝수 또는 홀수)에 나타난다(한글 U+xx00 때문에 반대쪽에 가끔 있을 수 있다). 일반 텍스트에는 널이 없다.
        // (ASCII뿐인 UTF-16은 UTF-8로도 해석되므로 UTF-8 검사보다 먼저 본다.)
        let sample = [UInt8](data.prefix(400))
        let evenNulls = stride(from: 0, to: sample.count, by: 2).filter { sample[$0] == 0 }.count
        let oddNulls = stride(from: 1, to: sample.count, by: 2).filter { sample[$0] == 0 }.count
        if oddNulls >= 2, evenNulls * 3 <= oddNulls, let s = String(data: data, encoding: .utf16LittleEndian) { return s }
        if evenNulls >= 2, oddNulls * 3 <= evenNulls, let s = String(data: data, encoding: .utf16BigEndian) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }
        for enc in [CFStringEncodings.dosKorean, CFStringEncodings.EUC_KR] {
            let cf = CFStringEncoding(enc.rawValue)
            if let s = CFStringCreateWithBytes(nil, [UInt8](data), data.count, cf, false) { return s as String }
        }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    private static func stripBOM(_ s: String) -> String { s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s }

    static let maxZipPartBytes = 50 * 1024 * 1024     // 압축 해제한 한 부분(또는 읽는 부분 합계)의 상한
    static let unzipTimeout: TimeInterval = 20

    private final class UnzipFlags { let lock = NSLock(); var overflow = false; var timedOut = false }

    /// `/usr/bin/unzip` 실행. 출력은 조각으로 읽다가 maxBytes를 넘으면 프로세스를 끊고 .tooLarge,
    /// 제한 시간을 넘으면 끊고 .unreadable을 던진다.
    static func unzip(_ args: [String], maxBytes: Int = maxZipPartBytes) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { throw ExtractError.unreadable("압축 파일을 열 수 없어요") }
        let flags = UnzipFlags()
        let timer = DispatchWorkItem {
            flags.lock.lock(); flags.timedOut = true; flags.lock.unlock()
            if p.isRunning { p.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + unzipTimeout, execute: timer)
        var data = Data()
        let fh = out.fileHandleForReading
        while true {
            let chunk = fh.readData(ofLength: 64 * 1024)
            if chunk.isEmpty { break }
            if data.count + chunk.count > maxBytes {
                flags.lock.lock(); flags.overflow = true; flags.lock.unlock()
                p.terminate()
                break
            }
            data.append(chunk)
        }
        try? fh.close()
        p.waitUntilExit()
        timer.cancel()
        flags.lock.lock(); let overflow = flags.overflow, timedOut = flags.timedOut; flags.lock.unlock()
        if overflow { throw ExtractError.tooLarge }
        if timedOut { throw ExtractError.unreadable("압축을 푸는 데 너무 오래 걸려요") }
        guard p.terminationStatus == 0 else { throw ExtractError.unreadable("압축 파일을 열 수 없어요") }
        return data
    }

    /// `unzip -l`로 항목 이름 → 압축 해제 후 크기.
    static func zipEntries(_ url: URL) throws -> [String: Int] {
        let data = try unzip(["-l", url.path], maxBytes: 8 * 1024 * 1024)
        var result: [String: Int] = [:]
        for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") {
            guard let m = zipListLine.firstMatch(in: String(line), range: NSRange(location: 0, length: (String(line) as NSString).length)) else { continue }
            let l = String(line) as NSString
            if let size = Int(l.substring(with: m.range(at: 1))) { result[l.substring(with: m.range(at: 2))] = size }
        }
        return result
    }

    /// 읽을 항목들의 압축 해제 크기 합이 상한을 넘으면 .tooLarge.
    static func requireSmall(_ entries: [String: Int], names: [String]) throws {
        if names.reduce(0, { $0 + (entries[$1] ?? 0) }) > maxZipPartBytes { throw ExtractError.tooLarge }
    }

    // MARK: - PDF

    private static func extractPDF(_ url: URL) throws -> ExtractedFile {
        guard let doc = PDFDocument(data: try readData(url)) else { throw ExtractError.unreadable("PDF를 열 수 없어요") }
        if doc.isLocked { throw ExtractError.unreadable("암호로 잠긴 PDF예요") }
        var parts: [String] = []
        var total = 0
        for i in 0..<min(doc.pageCount, maxPDFPages) {
            guard let s = doc.page(at: i)?.string, !s.isEmpty else { continue }
            parts.append(s)
            total += s.count
            if total > maxChars { break }
        }
        let attrs = doc.documentAttributes
        let title = meaningfulPDFTitle(attrs?[PDFDocumentAttribute.titleAttribute] as? String)
        var file = ExtractedFile(title: title, text: parts.joined(separator: "\n\n").replacingOccurrences(of: "\r\n", with: "\n"))
        file.created = attrs?[PDFDocumentAttribute.creationDateAttribute] as? Date
        return file
    }

    private static func meaningfulPDFTitle(_ raw: String?) -> String? {
        guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), t.count >= 2 else { return nil }
        let lower = t.lowercased()
        let junk = ["untitled", "제목 없음", "제목없음", "document", "microsoft word", "powerpoint", "slide 1"]
        if junk.contains(where: { lower == $0 || lower.hasPrefix($0 + " ") || lower.hasPrefix($0 + " -") }) { return nil }
        if lower.range(of: #"\.(docx?|pptx?|xlsx?|pdf|indd|tmp|txt|hwp|hwpx)$"#, options: .regularExpression) != nil { return nil }
        if lower.range(of: #"^[\w\-. ]*\d{6,}[\w\-. ]*$"#, options: .regularExpression) != nil { return nil }
        return t
    }

    // MARK: - 워드·RTF·ODT

    private static func extractRichText(_ url: URL, ext: String) throws -> ExtractedFile {
        let type: NSAttributedString.DocumentType
        switch ext {
        case "docx": type = .officeOpenXML
        case "doc": type = .docFormat
        case "odt": type = .openDocument
        default: type = .rtf
        }
        if ext == "docx" || ext == "odt" {   // 압축 폭탄 방지: AppKit에 맡기기 전에 본문 XML 크기를 본다
            let entries = try zipEntries(url)
            try requireSmall(entries, names: [ext == "docx" ? "word/document.xml" : "content.xml"])
        }
        var attrs: NSDictionary?
        do {
            // 문서 형식을 명시한다. HTML 가져오기와 달리 이 형식들은 백그라운드 스레드에서 안전하다.
            let a = try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: &attrs)
            var file = ExtractedFile(title: attrs?[NSAttributedString.DocumentAttributeKey.title] as? String,
                                     text: normalizeWhitespace(a.string.replacingOccurrences(of: "\u{FFFC}", with: "")))
            file.created = attrs?[NSAttributedString.DocumentAttributeKey.creationTime] as? Date
            if !file.text.isEmpty || ext == "rtf" || ext == "doc" { return file }
        } catch {
            if ext == "rtf" || ext == "doc" { throw ExtractError.unreadable("문서를 열 수 없어요") }
        }
        // docx·odt는 AppKit이 실패하거나 빈 결과를 줄 때 zip 안 XML에서 직접 읽는다.
        if let text = try zipXMLText(url, ext: ext) { return ExtractedFile(title: nil, text: text) }
        throw ExtractError.unreadable("문서를 열 수 없어요")
    }

    private static func zipXMLText(_ url: URL, ext: String) throws -> String? {
        let entry = ext == "docx" ? "word/document.xml" : "content.xml"
        guard ext == "docx" || ext == "odt",
              let xml = String(data: try unzip(["-p", url.path, entry]), encoding: .utf8) else { return nil }
        let marked: String
        if ext == "docx" {
            marked = xml.replacingOccurrences(of: "</w:p>", with: "\n").replacingOccurrences(of: "<w:tab/>", with: "\t")
                .replacingOccurrences(of: "<w:br/>", with: "\n")
        } else {
            marked = xml.replacingOccurrences(of: "</text:p>", with: "\n").replacingOccurrences(of: "</text:h>", with: "\n")
                .replacingOccurrences(of: "<text:line-break/>", with: "\n").replacingOccurrences(of: "<text:tab/>", with: "\t")
        }
        return normalizeWhitespace(decodeEntities(stripTags(marked)))
    }

    // MARK: - HTML

    private static func extractHTML(_ html: String) -> ExtractedFile {
        var title: String? = nil
        if let m = htmlTitle.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)), let r = Range(m.range(at: 1), in: html) {
            let t = decodeEntities(stripTags(String(html[r]))).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            title = t.isEmpty ? nil : t
        }
        // 전부 한 번씩만 훑는다(닫는 표지가 없는 여는 표지를 반복해서 끝까지 찾지 않는다).
        let s = decodeEntities(stripTags(removeHiddenBlocks(html), blocks: true))
        // 블록 태그마다 줄바꿈이 겹쳐 생기는 빈 줄은 없앤다.
        let lines = normalizeWhitespace(s).split(separator: "\n").filter { !$0.isEmpty }
        return ExtractedFile(title: title, text: lines.joined(separator: "\n"))
    }

    /// 주석·head·script·style·noscript·template·svg·iframe 블록을 한 번에 지운다 (선형).
    /// 닫는 표지가 없거나 `/>`로 끝나는 여는 표지는 그 표지만 버리고, 같은 이름의 닫는 표지를 다시 찾지 않는다.
    private static func removeHiddenBlocks(_ html: String) -> String {
        guard html.contains("<") else { return html }
        let ns = html as NSString
        let len = ns.length
        var out = "", pos = 0
        var noCloser = Set<String>()
        while pos < len, let m = hiddenOpener.firstMatch(in: html, range: NSRange(location: pos, length: len - pos)) {
            out += ns.substring(with: NSRange(location: pos, length: m.range.location - pos))
            let openerText = ns.substring(with: m.range)
            let isComment = openerText.hasPrefix("<!--")
            let name = isComment ? "--" : ns.substring(with: m.range(at: 1)).lowercased()
            var end = m.range.location + m.range.length
            if !openerText.hasSuffix("/>"), !noCloser.contains(name) {
                if let closeEnd = isComment ? findLiteral("-->", in: ns, from: end) : findCloser(name, in: ns, from: end) { end = closeEnd }
                else { noCloser.insert(name) }
            }
            out += " "
            pos = end
        }
        if pos < len { out += ns.substring(from: pos) }
        return out
    }

    private static func findLiteral(_ lit: String, in ns: NSString, from: Int) -> Int? {
        let r = ns.range(of: lit, options: [], range: NSRange(location: from, length: ns.length - from))
        return r.location == NSNotFound ? nil : r.location + r.length
    }

    /// `</name   >` 의 끝 위치.
    private static func findCloser(_ name: String, in ns: NSString, from: Int) -> Int? {
        var at = from
        while at < ns.length {
            let r = ns.range(of: "</" + name, options: .caseInsensitive, range: NSRange(location: at, length: ns.length - at))
            if r.location == NSNotFound { return nil }
            var j = r.location + r.length
            while j < ns.length, [0x20, 0x09, 0x0A, 0x0D].contains(ns.character(at: j)) { j += 1 }
            if j < ns.length, ns.character(at: j) == 0x3E { return j + 1 }
            at = r.location + r.length
        }
        return nil
    }

    // MARK: - HWPX

    private static func extractHWPX(_ url: URL) throws -> ExtractedFile {
        let entries = try zipEntries(url)
        let sections = entries.keys
            .filter { $0.hasPrefix("Contents/section") && $0.hasSuffix(".xml") }
            .sorted { sectionIndex($0) < sectionIndex($1) }
        guard !sections.isEmpty else { throw ExtractError.unreadable("본문을 찾을 수 없어요") }
        try requireSmall(entries, names: sections + ["Contents/content.hpf"])

        var paragraphs: [String] = []
        var collected = 0
        for name in sections {
            if collected > maxChars * 2 { break }            // 어차피 잘릴 뒷부분은 풀지 않는다
            guard let xml = String(data: try unzip(["-p", url.path, name]), encoding: .utf8) else { continue }
            var line = ""
            hwpWalk(xml,
                    text: { line += decodeEntities(stripTags($0.replacingOccurrences(of: "<hp:tab/>", with: "\t")
                                                                .replacingOccurrences(of: "<hp:lineBreak/>", with: "\n"))) },
                    lineBreak: { line += "\n" },
                    paragraphEnd: { paragraphs.append(line); collected += line.utf16.count; line = "" })
            if !line.isEmpty { paragraphs.append(line) }
        }
        var title: String? = nil
        if entries["Contents/content.hpf"] != nil, let d = try? unzip(["-p", url.path, "Contents/content.hpf"], maxBytes: 4 * 1024 * 1024),
           let hpf = String(data: d, encoding: .utf8),
           let m = hpfTitle.firstMatch(in: hpf, range: NSRange(hpf.startIndex..., in: hpf)), let r = Range(m.range(at: 1), in: hpf) {
            let t = decodeEntities(String(hpf[r])).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { title = t }
        }
        return ExtractedFile(title: title, text: normalizeWhitespace(paragraphs.joined(separator: "\n")))
    }

    /// 구역 XML을 앞에서 뒤로 한 번만 훑는다: <hp:t>…</hp:t> 글, <hp:lineBreak/>, </hp:p>.
    /// 닫는 </hp:t>가 없으면 그 뒤의 <hp:t>는 더 찾지 않는다(선형). `<hp:t/>`와 속성이 붙은 여는 표지도 처리한다.
    private static func hwpWalk(_ xml: String, text: (String) -> Void, lineBreak: () -> Void, paragraphEnd: () -> Void) {
        let ns = xml as NSString
        let len = ns.length
        var pos = 0
        var textClosable = true
        func starts(_ at: Int, _ lit: String) -> Bool {
            let n = (lit as NSString).length
            return at + n <= len && ns.substring(with: NSRange(location: at, length: n)) == lit
        }
        while pos < len {
            let r = ns.range(of: "<", options: [], range: NSRange(location: pos, length: len - pos))
            if r.location == NSNotFound { return }
            let at = r.location
            pos = at + 1
            if starts(at, "</hp:p>") { paragraphEnd(); pos = at + 7; continue }
            if starts(at, "<hp:lineBreak") {
                let gt = ns.range(of: ">", options: [], range: NSRange(location: at, length: len - at))
                if gt.location == NSNotFound { return }
                lineBreak(); pos = gt.location + 1; continue
            }
            guard textClosable, starts(at, "<hp:t"), at + 5 < len else { continue }
            let next = ns.character(at: at + 5)
            guard next == 0x3E || next == 0x2F || next == 0x20 || next == 0x09 || next == 0x0A || next == 0x0D else { continue }   // <hp:tbl> 등은 제외
            let gt = ns.range(of: ">", options: [], range: NSRange(location: at, length: len - at))
            if gt.location == NSNotFound { return }
            pos = gt.location + 1
            if ns.character(at: gt.location - 1) == 0x2F { continue }          // <hp:t/>
            let close = ns.range(of: "</hp:t>", options: [], range: NSRange(location: pos, length: len - pos))
            if close.location == NSNotFound { textClosable = false; continue }
            text(ns.substring(with: NSRange(location: pos, length: close.location - pos)))
            pos = close.location + close.length
        }
    }

    private static func sectionIndex(_ name: String) -> Int {
        Int(name.filter(\.isNumber)) ?? 0
    }

    // MARK: - 텍스트 정리

    private static let blockTagNames: Set<String> = ["p", "div", "br", "li", "ul", "ol", "tr", "table", "h1", "h2", "h3", "h4", "h5", "h6",
        "section", "article", "header", "footer", "nav", "blockquote", "pre", "hr", "dt", "dd", "dl", "form", "figure",
        "figcaption", "aside", "main", "thead", "tbody", "caption"]

    /// 태그를 지운다 (한 번 훑기). blocks == true면 블록 태그는 줄바꿈, td·th는 공백으로 바꾼다.
    /// '>'가 더 이상 없으면 남은 부분은 그대로 글로 본다.
    static func stripTags(_ s: String, blocks: Bool = false) -> String {
        guard s.utf8.contains(UInt8(ascii: "<")) else { return s }
        let u = Array(s.utf16)
        var out: [UInt16] = []
        out.reserveCapacity(u.count)
        var i = 0, noMoreGT = false
        while i < u.count {
            let c = u[i]
            if c == 0x3C, !noMoreGT, i + 1 < u.count, isTagStart(u[i + 1]) {
                var j = i + 1
                while j < u.count, u[j] != 0x3E { j += 1 }
                if j >= u.count { noMoreGT = true; out.append(c); i += 1; continue }
                if blocks {
                    var k = i + 1
                    if u[k] == 0x2F { k += 1 }
                    var name = ""
                    while k < j, let sc = Unicode.Scalar(u[k]), sc.value < 128 && CharacterSet.alphanumerics.contains(sc) {
                        name.unicodeScalars.append(sc); k += 1
                    }
                    name = name.lowercased()
                    if blockTagNames.contains(name) { out.append(0x0A) } else if name == "td" || name == "th" { out.append(0x20) }
                }
                i = j + 1
                continue
            }
            out.append(c); i += 1
        }
        return String(decoding: out, as: UTF16.self)
    }

    private static func isTagStart(_ c: UInt16) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x2F || c == 0x21 || c == 0x3F
    }

    /// 줄 안의 공백은 하나로, 빈 줄은 최대 하나만 남긴다.
    static func normalizeWhitespace(_ s: String) -> String {
        var out: [String] = []
        var blank = false
        for raw in s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\u{A0}" || $0 == "\u{3000}" }).joined(separator: " ")
            if line.isEmpty { if !blank && !out.isEmpty { out.append("") }; blank = true }
            else { out.append(line); blank = false }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "copy": "©", "reg": "®",
        "hellip": "…", "middot": "·", "ndash": "–", "mdash": "—", "lsquo": "‘", "rsquo": "’", "ldquo": "“",
        "rdquo": "”", "bull": "•", "laquo": "«", "raquo": "»", "times": "×", "trade": "™", "larr": "←",
        "rarr": "→", "deg": "°", "plusmn": "±", "euro": "€", "yen": "¥", "pound": "£", "cent": "¢",
    ]

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let ns = s as NSString
        var out = "", pos = 0
        for m in entityRegex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: pos, length: m.range.location - pos))
            let body = ns.substring(with: m.range(at: 1))
            var rep: String? = nil
            if body.hasPrefix("#") {
                let hex = body.hasPrefix("#x") || body.hasPrefix("#X")
                if let v = UInt32(body.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10), let u = Unicode.Scalar(v) { rep = String(Character(u)) }
            } else { rep = namedEntities[body] ?? namedEntities[body.lowercased()] }
            out += rep ?? ns.substring(with: m.range)
            pos = m.range.location + m.range.length
        }
        out += ns.substring(from: pos)
        return out
    }

    private static func sub(_ re: NSRegularExpression, _ s: String, _ t: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: t)
    }

    private static func rx(_ p: String, dotAll: Bool = true) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: dotAll ? [.caseInsensitive, .dotMatchesLineSeparators] : [.caseInsensitive])
    }
    private static let zipListLine = rx(#"^\s*(\d+)\s+\d{2,4}[-/]\d{2}[-/]\d{2,4}\s+\d{2}:\d{2}\s+(.+?)\s*$"#)
    private static let htmlTitle = rx(#"<title\b[^>]{0,1000}>(.{0,2000}?)</title>"#)
    private static let hiddenOpener = rx(#"<!--|<(script|style|noscript|template|svg|iframe|head)\b[^>]{0,1000}>"#)
    private static let entityRegex = rx(#"&(#[xX]?[0-9A-Fa-f]+|[A-Za-z][A-Za-z0-9]*);"#)
    private static let hpfTitle = rx(#"<(?:\w+:)?title\b[^>]*>(.*?)</(?:\w+:)?title>"#)
}
