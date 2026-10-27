import Foundation

// v0.6 옵시디언 없이 쓰기: 본문 원문·링크 해석 · 그림 읽기 · 새 노트 · 제목 제안 (README "조작" 표 참고)
// - 리더가 마크다운을 그리려면 색인용 평문(text)이 아니라 파일 원문이 필요하다 → document 응답에 "markdown"을 더한다.
// - 본문 [[링크]]·[글](경로)를 색인과 같은 규칙(Relate.resolve)으로 풀어 "links"로 돌려준다.
// - 파일을 지우는 코드는 없다. 새 노트는 덮어쓰지 않고(있으면 " 2") 만든다.

enum Notes {
    static let viewBytes = 300_000                    // 리더에 보여 줄 원문 상한 (넘으면 truncated)
    static let assetLimit = 8 * 1024 * 1024
    static let imageMime: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
        "svg": "image/svg+xml", "bmp": "image/bmp", "heic": "image/heic", "heif": "image/heif", "avif": "image/avif",
    ]
    static let markdownKinds: Set<String> = ["md", "markdown"]

    // MARK: 링크 해석 (Relate.resolve와 같은 규칙: 이름·별칭·경로·이슈 키·Confluence 제목)

    final class LinkIndex {
        let snap: Snapshot
        private var byName: [String: [String: [Int]]] = [:]     // sourceId → 소문자 이름 → 문서
        private var byRel: [String: [String: Int]] = [:]        // sourceId → 소문자 상대 경로 → 문서
        private var confTitle: [String: [String: [Int]]] = [:]
        private var jira: [String: [Int]] = [:]
        private let fallback: LinkFallback                       // v0.7 F: 번호 접두·Jira 키·정규화 제목 (색인 Relate와 같은 코드)

        init(_ snap: Snapshot) {
            self.snap = snap
            fallback = LinkFallback(docs: snap.docs.map { $0.m })
            for (i, doc) in snap.docs.enumerated() {
                let d = doc.m
                if d.kind == "confluence" { confTitle[d.sourceId, default: [:]][d.title.lowercased(), default: []].append(i); continue }
                if d.kind == "jira" {
                    if let k = d.id.components(separatedBy: ":jira:").last { jira[k, default: []].append(i) }
                    continue
                }
                let rel = String(d.id.dropFirst(d.sourceId.count + 1))
                byRel[d.sourceId, default: [:]][rel.lowercased()] = i
                let file = (rel as NSString).lastPathComponent
                var names = Set([file.lowercased(), (file as NSString).deletingPathExtension.lowercased()])
                for a in d.aliases { names.insert(a.lowercased()) }
                for nm in names where !nm.isEmpty { byName[d.sourceId, default: [:]][nm, default: []].append(i) }
            }
        }

        private func pick(_ cands: [Int], near folder: String) -> Int? {
            cands.min { a, b in
                let fa = snap.docs[a].m.folder == folder ? 0 : 1, fb = snap.docs[b].m.folder == folder ? 0 : 1
                if fa != fb { return fa < fb }
                let la = snap.docs[a].m.id.count, lb = snap.docs[b].m.id.count
                return la != lb ? la < lb : snap.docs[a].m.id < snap.docs[b].m.id
            }
        }
        private func normPath(_ p: String) -> String {
            var out: [Substring] = []
            for c in p.split(separator: "/") {
                if c == "." || c.isEmpty { continue }
                if c == ".." { if !out.isEmpty { out.removeLast() }; continue }
                out.append(c)
            }
            return out.joined(separator: "/")
        }

        /// raw(쓰인 그대로의 대상) → 문서 번호. from은 링크가 적힌 문서.
        func resolve(_ raw: String, from a: DocMetaRow) -> Int? {
            if raw.hasPrefix("id:") { return snap.index[String(raw.dropFirst(3))] }
            var t = raw
            if let h = t.firstIndex(where: { $0 == "#" || $0 == "^" }) { t = String(t[..<h]) }
            t = Indexer.nfc((t.removingPercentEncoding ?? t).trimmingCharacters(in: .whitespaces))
            if t.isEmpty { return nil }
            if Korean.isIssueKey(t), let c = jira[t] { return c.first(where: { snap.docs[$0].m.sourceId == a.sourceId }) ?? c.first }
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

        /// 개발용 통계: 번호 접두 후보가 여럿이라 좁히지 못한 링크인가.
        func isAmbiguousPrefix(_ raw: String, from a: DocMetaRow) -> Bool { fallback.isAmbiguousPrefix(raw, from: a) }

        /// 기존 해석기(resolve)가 못 찾은 대상을 한 번 더 맞춘다: 번호 접두("id") → Jira 키("jira") → 정규화 제목("title").
        /// 같은 출처에서 하나로 정해질 때만 돌려주고, 로컬(마크다운 등)에서 건 링크에만 쓴다. (규칙은 LinkFallback — 색인과 공용)
        func resolveMore(_ raw: String, from a: DocMetaRow) -> (doc: Int, how: String)? { fallback.resolve(raw, from: a) }
    }

    // MARK: 번호 접두·정규화 제목 (못 찾은 링크 보강용)

    static func numberPrefix(of s: String) -> String? { LinkFallback.numberPrefix(of: s) }
    static func endsPrefix(_ s: String, _ n: Int) -> Bool { LinkFallback.endsPrefix(s, n) }
    static func normalizeTitle(_ s: String) -> String { LinkFallback.normalizeTitle(s) }

    private static let cacheLock = NSLock()
    private static var cached: (snap: Snapshot, index: LinkIndex)?
    static func linkIndex(_ snap: Snapshot) -> LinkIndex {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let c = cached, c.snap === snap { return c.index }
        let idx = LinkIndex(snap)
        cached = (snap, idx)
        return idx
    }

    // MARK: 원문에서 링크 대상 뽑기 (코드 블록·인라인 코드·프런트매터 제외)

    private static func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    private static let wikiLink = rx(#"(!?)\[\[([^\[\]\n]+?)\]\]"#)
    private static let mdLink = rx(#"(!?)\[((?:[^\[\]\n]|\[[^\[\]\n]*\])*)\]\(([^()\n]*(?:\([^()\n]*\)[^()\n]*)*)\)"#)
    private static let inlineCode = rx(#"(`+)(?!`)(.+?)(?<!`)\1(?!`)"#)
    private static let schemeRegex = rx(#"^[A-Za-z][A-Za-z0-9+.\-]*:"#)

    static func linkTargets(in markdown: String) -> [String] {
        // 프런트매터(속성)의 [[링크]]도 화면에 그려지므로 함께 푼다
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var seen = Set<String>(), out: [String] = []
        func add(_ t: String) { if !t.isEmpty, seen.insert(t).inserted { out.append(t) } }
        var fence: (Character, Int)? = nil
        for raw in lines {
            let trimmed = raw.drop(while: { $0 == " " || $0 == "\t" })
            if let c = trimmed.first, c == "`" || c == "~" {
                let run = trimmed.prefix(while: { $0 == c }).count
                if run >= 3 {
                    if let f = fence { if c == f.0, run >= f.1, trimmed.dropFirst(run).allSatisfy({ $0 == " " }) { fence = nil } }
                    else { fence = (c, run) }
                    continue
                }
            }
            if fence != nil || !(raw.contains("[[") || raw.contains("](")) { continue }
            var line = raw as NSString
            // 인라인 코드는 비운다
            let codes = inlineCode.matches(in: raw, range: NSRange(location: 0, length: line.length))
            if !codes.isEmpty {
                var s = raw as NSString
                for m in codes.reversed() { s = s.replacingCharacters(in: m.range, with: " ") as NSString }
                line = s
            }
            let text = line as String
            let full = NSRange(location: 0, length: line.length)
            for m in wikiLink.matches(in: text, range: full) {
                var t = line.substring(with: m.range(at: 2))
                if let bar = t.firstIndex(of: "|") { t = String(t[..<bar]) }
                if let hash = t.firstIndex(of: "#") { t = String(t[..<hash]) }
                add(t.trimmingCharacters(in: .whitespaces))
            }
            for m in mdLink.matches(in: text, range: full) {
                if line.substring(with: m.range(at: 1)) == "!" { continue }
                if let t = mdTarget(line.substring(with: m.range(at: 3))) { add(t) }
            }
        }
        return out
    }

    private static func mdTarget(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("<"), let close = t.firstIndex(of: ">") {
            t = String(t[t.index(after: t.startIndex)..<close])
        } else if let sp = t.firstIndex(where: { $0 == " " || $0 == "\t" }) {
            t = String(t[..<sp])
        }
        if t.isEmpty || t.hasPrefix("#") || t.hasPrefix("//") { return nil }
        if schemeRegex.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil { return nil }
        if let hash = t.firstIndex(of: "#") { t = String(t[..<hash]) }
        t = (t.removingPercentEncoding ?? t).trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    // MARK: document 응답 보강

    /// 로컬 마크다운이면 파일 원문("markdown")과 링크 해석("links")을 더한다. 원문을 못 읽으면 아무것도 바꾸지 않는다(리더는 평문으로).
    static func decorate(_ doc: inout [String: Any], id: String, snap: Snapshot) {
        guard let c = snap.index[id] else { return }
        let d = snap.docs[c].m
        // v0.6 P0: 색인이 못 찾은 링크 중 번호 접두·Jira 키·정규화 제목으로 이제 찾은 것은 "찾지 못한 링크"에서 뺀다 (색인·그래프는 그대로)
        if let un = doc["unresolved"] as? [String], !un.isEmpty, d.kind != "confluence", d.kind != "jira" {
            let index = linkIndex(snap)
            doc["unresolved"] = un.filter { index.resolve($0, from: d) == nil && index.resolveMore($0, from: d) == nil }
        }
        // v0.7 D: 원격(Confluence·Jira)은 저장된 평문에서 표를 되살린 마크다운을 읽기 전용으로 그린다
        if d.kind == "confluence" || d.kind == "jira" {
            if let text = doc["text"] as? String {
                doc["markdown"] = RemoteMarkdown.fromStoredText(text)
                doc["markdownTruncated"] = (doc["truncated"] as? Bool) ?? false
                doc["markdownSource"] = "remote"
            }
            return
        }
        guard markdownKinds.contains(d.kind), !(d.location.hasPrefix("http://") || d.location.hasPrefix("https://")) else { return }
        guard let fh = FileHandle(forReadingAtPath: d.location) else { return }
        defer { try? fh.close() }
        let data = (try? fh.read(upToCount: viewBytes + 1)) ?? Data()
        let truncated = data.count > viewBytes
        var bytes = truncated ? data.prefix(viewBytes) : data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        // UTF-8이 아닌 파일은 평문으로 둔다. 잘린 끝의 반쪽 글자는 버린다.
        var text = String(data: bytes, encoding: .utf8)
        if text == nil && truncated { for cut in 1...3 where bytes.count > cut { if let t = String(data: bytes.dropLast(cut), encoding: .utf8) { text = t; break } } }
        guard let markdown = text else { return }
        doc["markdown"] = markdown
        doc["markdownTruncated"] = truncated      // "truncated"는 평문(text) 기준 그대로 둔다(MCP가 쓴다)
        let index = linkIndex(snap)
        let links: [[String: Any]] = linkTargets(in: markdown).map { target in
            if let j = index.resolve(target, from: d) { return ["target": target, "id": snap.docs[j].m.id] }
            if let m = index.resolveMore(target, from: d) { return ["target": target, "id": snap.docs[m.doc].m.id, "how": m.how] }
            return ["target": target, "id": NSNull(), "asset": Relate.isAttachment(target)]
        }
        doc["links"] = links
    }

    // MARK: 그림 읽기

    private static let nameLock = NSLock()
    private static var nameCache: [String: (at: Date, files: [String])] = [:]    // sourceId → 그림 파일 상대 경로

    private static func imageFiles(source: SourceConfig, root: String) -> [String] {
        nameLock.lock()
        if let c = nameCache[source.id], Date().timeIntervalSince(c.at) < 60 { nameLock.unlock(); return c.files }
        nameLock.unlock()
        let files = Indexer.listFiles(root: root).filter { imageMime[(($0 as NSString).pathExtension).lowercased()] != nil }
        nameLock.lock(); nameCache[source.id] = (Date(), files); nameLock.unlock()
        return files
    }

    static func readAsset(id: String, target: String, snap: Snapshot, sources: [SourceConfig]) -> [String: Any] {
        func fail(_ m: String) -> [String: Any] { ["ok": false, "error": m] }
        guard let c = snap.index[id] else { return fail("문서를 찾을 수 없어요.") }
        let d = snap.docs[c].m
        guard let src = sources.first(where: { $0.id == d.sourceId }), !src.kind.isRemote, let rootPath = src.path else { return fail("로컬 문서가 아니에요.") }
        let root = Indexer.realPath(rootPath)
        var t = target.trimmingCharacters(in: .whitespacesAndNewlines)
        t = (t.removingPercentEncoding ?? t)
        if !FileManager.default.fileExists(atPath: root + "/" + t), let h = t.firstIndex(of: "#") { t = String(t[..<h]) }
        t = Indexer.nfc(t).trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let ext = (t as NSString).pathExtension.lowercased()
        guard !t.isEmpty, let mime = imageMime[ext] else { return fail("그림 형식이 아니에요.") }
        if t.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return fail("숨김 폴더의 파일은 열 수 없어요.") }   // .obsidian · .git · .trash 등
        let docDir = (Indexer.realPath((d.location as NSString).deletingLastPathComponent))
        var candidates: [String] = [docDir + "/" + t, root + "/" + t]
        let lowered = t.lowercased()
        let rels = imageFiles(source: src, root: root)
        let hits = rels.filter { $0.lowercased() == lowered || $0.lowercased().hasSuffix("/" + lowered) }
        candidates += hits.sorted { ($0.count, $0) < ($1.count, $1) }.map { root + "/" + $0 }
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"
        for cand in candidates {
            let real = Indexer.realPath(cand)
            guard real.hasPrefix(rootPrefix) else { continue }          // 출처 밖으로 나가는 경로(.. · 심볼릭 링크)는 읽지 않는다
            if real.dropFirst(rootPrefix.count).split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }   // 숨김 폴더(.obsidian · .git · .trash)는 읽지 않는다
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: real, isDirectory: &isDir), !isDir.boolValue else { continue }
            let size = ((try? FileManager.default.attributesOfItem(atPath: real)[.size]) as? NSNumber)?.intValue ?? 0
            if size > assetLimit { return fail("8MB가 넘는 그림은 보여 주지 않아요.") }
            guard let data = FileManager.default.contents(atPath: real) else { continue }
            return ["ok": true, "dataURL": "data:\(mime);base64," + data.base64EncodedString(), "mime": mime, "bytes": data.count]
        }
        return fail("그림 파일을 찾지 못했어요.")
    }

    // MARK: 제목 제안 ([[ 자동완성)

    static func suggestTitles(q: String, limit: Int, snap: Snapshot) -> [String: Any] {
        let nq = Korean.normalize(q)
        let cho: String? = Korean.isChoseongQuery(q) ? Korean.choseong(q).replacingOccurrences(of: " ", with: "") : nil
        func stem(_ d: DocMetaRow) -> String {
            let rel = String(d.id.dropFirst(d.sourceId.count + 1))
            return ((rel as NSString).lastPathComponent as NSString).deletingPathExtension
        }
        var scored: [(Int, Double, Double)] = []      // (문서, 점수, 수정 시각)
        for (i, doc) in snap.docs.enumerated() {
            let m = doc.m
            if m.kind == "confluence" || m.kind == "jira" { continue }
            var score = 0.0
            if nq.isEmpty { score = 1 }
            else {
                let names = [Korean.normalize(stem(m)), doc.normTitle] + doc.normAliases
                if names.contains(where: { $0 == nq }) { score = 5 }
                else if names.contains(where: { $0.hasPrefix(nq) }) { score = 4 }
                else if names.contains(where: { $0.contains(nq) }) { score = 3 }
                else if let c = cho, !c.isEmpty, ([doc.choTitle] + doc.choOther).contains(where: { $0.replacingOccurrences(of: " ", with: "").contains(c) }) { score = 2 }
                else { continue }
            }
            scored.append((i, score, m.modified))
        }
        scored.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 > $1.2 }
        var stemCount: [String: Int] = [:]
        for doc in snap.docs where doc.m.kind != "confluence" && doc.m.kind != "jira" { stemCount[doc.m.sourceId + "|" + stem(doc.m).lowercased(), default: 0] += 1 }
        let items: [[String: Any]] = scored.prefix(max(1, min(limit, 30))).map { (i, _, _) in
            let m = snap.docs[i].m
            let s = stem(m)
            let rel = String(m.id.dropFirst(m.sourceId.count + 1))
            let isMd = m.kind == "md" || m.kind == "markdown"
            let ambiguous = (stemCount[m.sourceId + "|" + s.lowercased()] ?? 0) > 1      // 같은 이름이 여럿이면 경로로 구분
            let name = isMd ? (ambiguous ? (rel as NSString).deletingPathExtension : s) : (ambiguous ? rel : (rel as NSString).lastPathComponent)
            return ["id": m.id, "title": m.title, "name": name, "path": m.displayPath, "kind": m.kind]
        }
        return ["items": items]
    }
}

// MARK: - 새 노트 · 바깥 주소

extension Library {
    func readAsset(id: String, target: String) -> [String: Any] {
        Notes.readAsset(id: id, target: target, snap: notesSnapshot, sources: notesSources)
    }

    func suggestTitles(q: String, limit: Int) -> [String: Any] {
        Notes.suggestTitles(q: q, limit: limit, snap: notesSnapshot)
    }

    /// 파일 이름으로 쓸 수 있게 다듬기: 경로·링크 구분자 제거, 점·공백 정리, 120자.
    static func noteFileStem(_ title: String) -> String {
        var t = Indexer.nfc(title)
        if t.lowercased().hasSuffix(".md") { t = String(t.dropLast(3)) }
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]").union(.controlCharacters).union(.newlines)
        t = t.components(separatedBy: bad).joined(separator: " ")
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        if t.count > 120 { t = String(t.prefix(120)).trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
        return t.isEmpty ? "새 노트" : t
    }

    /// 새 마크다운 노트. 덮어쓰지 않는다(있으면 " 2", " 3" …). 출처 루트 밖으로 나가지 않는다. 만든 뒤 바로 색인한다.
    func createNote(sourceId: String?, folder: String?, title: String, text: String?) throws -> [String: Any] {
        if notesReadOnly { throw LibraryError("읽기 전용으로 열려 있어요.") }
        let locals = notesSources.filter { $0.enabled && !$0.kind.isRemote && $0.path != nil }
        let src: SourceConfig
        if let sid = sourceId, let s = locals.first(where: { $0.id == sid }) { src = s }
        else if let s = locals.first(where: { $0.kind == .obsidian }) ?? locals.first { src = s }
        else { throw LibraryError("노트를 둘 폴더나 볼트가 연결돼 있지 않아요.") }
        let root = Indexer.realPath(src.path ?? "")
        try Indexer.checkRoot(root)
        let fm = FileManager.default
        // 폴더: 지정이 없으면 _Inbox(있을 때), 아니면 루트. 지정한 폴더는 출처 안의 상대 경로여야 한다.
        var comps: [String] = []
        if let f = folder {
            for c in f.split(separator: "/").map(String.init) {
                let n = Indexer.nfc(c).trimmingCharacters(in: .whitespaces)
                if n.isEmpty || n == "." { continue }
                if n == ".." || n.hasPrefix(".") { throw LibraryError("이 폴더에는 노트를 만들 수 없어요.") }
                comps.append(n)
            }
        } else {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: root + "/_Inbox", isDirectory: &isDir), isDir.boolValue { comps = ["_Inbox"] }
        }
        // 한 단계씩 만든다: 단계마다 실제 경로가 출처 안인지 먼저 보고(심볼릭 링크가 밖을 가리키면 아무것도 만들지 않는다) 만든다.
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"
        func inside(_ p: String) -> Bool { let r = Indexer.realPath(p); return r == root || r.hasPrefix(rootPrefix) }
        var dirPath = root
        for c in comps {
            let next = dirPath + "/" + c
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: next, isDirectory: &isDir) {
                guard isDir.boolValue, inside(next) else { throw LibraryError("연결한 폴더 밖에는 노트를 만들 수 없어요.") }
            } else {
                // 아직 없는 이름: 부모가 안쪽인 것은 확인했으니 만들 수 있다. 만든 뒤에도 안쪽인지 다시 본다.
                guard mkdir(next, 0o755) == 0 else { throw LibraryError("폴더를 만들지 못했어요. 파일 권한을 확인해 주세요.") }
                guard inside(next) else { throw LibraryError("연결한 폴더 밖에는 노트를 만들 수 없어요.") }
            }
            dirPath = next
        }
        let realDir = Indexer.realPath(dirPath)
        guard realDir == root || realDir.hasPrefix(rootPrefix) else { throw LibraryError("연결한 폴더 밖에는 노트를 만들 수 없어요.") }
        let stem = Library.noteFileStem(title)
        let body = Data((text ?? "").utf8)
        var n = 1
        var url: URL? = nil
        while n < 500 {
            let name = (n == 1 ? stem : "\(stem) \(n)") + ".md"
            let candidate = URL(fileURLWithPath: realDir).appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) {
                do { try body.write(to: candidate, options: [.withoutOverwriting]); url = candidate; break }
                catch let e as NSError where e.domain == NSCocoaErrorDomain && e.code == NSFileWriteFileExistsError { /* 그 사이에 생겼으면 다음 이름 */ }
                catch { throw LibraryError("노트를 만들지 못했어요. 파일 권한을 확인해 주세요.") }
            }
            n += 1
        }
        guard let made = url else { throw LibraryError("같은 이름의 노트가 너무 많아요. 다른 제목으로 만들어 주세요.") }
        notesIndexNow(src, path: made.path)
        let rel = Indexer.relativePath(path: made.path, root: root) ?? made.lastPathComponent
        return ["ok": true, "id": src.id + ":" + rel, "path": rel, "sourceId": src.id]
    }
}

/// 바깥 주소 열기 허용 범위: http · https · mailto 만.
enum NotesURL {
    static func allowed(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 4096, let url = URL(string: t), let scheme = url.scheme?.lowercased() else { return nil }
        guard scheme == "http" || scheme == "https" || scheme == "mailto" else { return nil }
        if scheme != "mailto" && (url.host ?? "").isEmpty { return nil }
        return url
    }
}
