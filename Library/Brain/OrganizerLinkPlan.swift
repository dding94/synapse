import Foundation

// 이동 영향 분석과 고쳐 쓸 내용 만들기 (§6.7 이동 영향). 디스크는 읽기만 한다. 쓰기는 Mover가 한다.

struct FileEdit {
    let rel: String          // 이동 전 상대 경로(옮길 파일이면 이동 전 경로)
    let moved: Bool
    let canvas: Bool
    let original: Data
    let newText: String
    let count: Int
    var changes: [(before: String, after: String)] = []
}

struct MovePlan {
    let fromRel: String
    let toRel: String
    var edits: [FileEdit] = []
    var problem: String? = nil
    var checked: [(beforeRel: String, afterRel: String, canvas: Bool)] = []
    var unresolvedBefore = 0
    var links: Int { edits.reduce(0) { $0 + $1.count } }
    var files: Int { edits.count }
    var canvasFiles: Int { edits.filter { $0.canvas }.count }
}

/// 이름 열쇠(링크 대상의 마지막 조각, 소문자) → 그 이름으로 링크하는 파일들.
final class OrgLinkIndex {
    let files: VaultFiles
    var byKey: [String: Set<String>] = [:]
    init(files: VaultFiles) { self.files = files }
    func add(_ key: String, _ rel: String) { if !key.isEmpty { byKey[key, default: []].insert(rel) } }
}

extension Organizer {

    /// 이 파일 이름으로 이어질 수 있는 링크인가(마지막 조각이 옮길 파일 이름과 같은가).
    private func nameMatches(_ raw: String, keys: Set<String>) -> Bool {
        var t = raw
        if let h = t.firstIndex(where: { $0 == "#" || $0 == "|" }) { t = String(t[..<h]) }
        t = Indexer.nfc(t.removingPercentEncoding ?? t).trimmingCharacters(in: .whitespaces)
        return keys.contains((t as NSString).lastPathComponent.lowercased())
    }

    /// 링크를 새 대상(exp)으로 고친 문자열. 정확히 만들 수 없으면 nil.
    private func rewrite(_ l: LinkRef, exp: String, fromAfter: String, via: LinkResolve.Via) -> String? {
        switch l.kind {
        case .canvas:
            return LinkScan.jsonEscape(exp)
        case .wiki:
            let t = l.target.trimmingCharacters(in: .whitespaces)
            var path = exp
            if Organizer.isMarkdown(exp) && !Organizer.isMarkdown(t) { path = (exp as NSString).deletingPathExtension }
            if !path.contains("/") { return nil }                       // 루트 파일은 이름과 구별할 수 없다
            var alias = l.alias
            if alias == nil && !l.embed && !t.contains("/") { alias = t }   // 원래 표시를 남긴다
            return path + l.sub + (alias.map { l.pipe + $0 } ?? "")
        case .markdown:
            let dec = Indexer.nfc(l.target.removingPercentEncoding ?? l.target)
            var p: String
            switch via {
            case .absolute: p = "/" + exp
            case .root: p = exp
            default:
                p = LinkResolve.relative(from: Organizer.parent(fromAfter), to: exp)
                if dec.hasPrefix("./") && !p.hasPrefix("../") { p = "./" + p }
            }
            if Organizer.isMarkdown(exp) && !Organizer.isMarkdown(dec) { p = (p as NSString).deletingPathExtension }
            if p.contains("(") || p.contains(")") || p.contains("\n") { return nil }
            if l.angle {
                if p.contains(">") || p.contains("<") { return nil }
                return l.lead + "<" + p + l.sub + ">" + l.tail
            }
            let raw = l.target
            let full = raw.range(of: #"%[89A-Fa-f][0-9A-Fa-f]"#, options: .regularExpression) != nil
            if full {
                var allowed = CharacterSet.urlPathAllowed
                allowed.remove(charactersIn: "#?%")
                p = p.addingPercentEncoding(withAllowedCharacters: allowed) ?? p
            } else if raw.contains("%") || p.contains(" ") {
                p = p.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: " ", with: "%20")
            }
            return l.lead + p + l.sub + l.tail
        }
    }

    /// 한 파일의 링크를 이동 전후로 비교해 고친 내용을 만든다. (고친 내용, 고친 수) 또는 문제.
    private func fixFile(text: String, canvas: Bool, fromBefore: String, fromAfter: String, plan: MovePlan,
                         before: VaultFiles, after: VaultFiles) -> (String, Int, String?, [(before: String, after: String)]) {
        let links = LinkScan.scan(text, canvas: canvas)
        let ns = NSMutableString(string: text)
        var count = 0
        var changes: [(before: String, after: String)] = []
        let src = text as NSString
        var expected: [String?] = []
        for l in links.reversed() {
            let (b, via) = LinkResolve.resolve(l, from: fromBefore, files: before)
            let exp = b == plan.fromRel ? plan.toRel : b
            expected.insert(exp, at: 0)
            guard let e = exp else { continue }
            if LinkResolve.target(l, from: fromAfter, files: after) == e { continue }
            if l.inFrontmatter { return (text, 0, "속성(frontmatter) 안 링크는 고치지 않아요", []) }
            guard let rep = rewrite(l, exp: e, fromAfter: fromAfter, via: via) else {
                return (text, 0, "링크를 정확히 고칠 수 없어요: " + (l.kind == .wiki ? "[[\(l.target)]]" : l.target), [])
            }
            let whole = src.substring(with: l.outer)
            let inner = NSRange(location: l.range.location - l.outer.location, length: l.range.length)
            changes.insert((whole, (whole as NSString).replacingCharacters(in: inner, with: rep)), at: 0)
            ns.replaceCharacters(in: l.range, with: rep)
            count += 1
        }
        let out = ns as String
        if count == 0 { return (text, 0, nil, []) }
        // 검증: 고친 뒤 모든 링크가 기대한 대상으로 풀려야 한다
        let check = LinkScan.scan(out, canvas: canvas)
        if check.count != links.count { return (text, 0, "링크를 고친 뒤 개수가 달라져요", []) }
        for (i, l) in check.enumerated() where expected[i] != nil {
            if LinkResolve.target(l, from: fromAfter, files: after) != expected[i] { return (text, 0, "링크를 고친 뒤 대상이 달라져요", []) }
        }
        if canvas, (try? JSONSerialization.jsonObject(with: Data(out.utf8))) == nil { return (text, 0, "캔버스 형식이 깨져요", []) }
        return (out, count, nil, changes)
    }

    /// 볼트 한 번 훑기: 이름 열쇠 → 그 이름으로 링크하는 파일. 배치 안에서 다시 쓴다(§6.7 후보 거르기).
    /// 색인 문서는 outLinks + frontmatter(앞 8KB)를 보고, 색인에 없거나 색인 뒤 바뀐 md와 캔버스는 직접 읽는다.
    func buildLinkIndex(_ v: OrgVault, files: VaultFiles) -> OrgLinkIndex {
        let idx = OrgLinkIndex(files: files)
        var docs: [String: BrainDoc] = [:]
        for d in ctx.docs where d.sourceId == v.sourceId && d.isLocal { docs[d.relPath] = d }
        func key(_ raw: String) -> String {
            var t = raw
            if let h = t.firstIndex(where: { $0 == "#" || $0 == "|" }) { t = String(t[..<h]) }
            t = Indexer.nfc(t.removingPercentEncoding ?? t).trimmingCharacters(in: .whitespaces)
            return (t as NSString).lastPathComponent.lowercased()
        }
        for rel in files.rels {
            let canvas = (rel as NSString).pathExtension.lowercased() == "canvas"
            guard canvas || Organizer.isMarkdown(rel) else { continue }
            let abs = v.abs(rel)
            if !canvas, let d = docs[rel], let st = fileStamp(abs), Swift.abs(st.mtime - d.modified.timeIntervalSince1970) < 0.002, st.size == d.size {
                for l in d.outLinks { idx.add(key(l), rel) }
                for k in frontmatterKeys(abs) { idx.add(k, rel) }
                continue
            }
            guard let data = FileManager.default.contents(atPath: abs), let t = String(data: data, encoding: .utf8) else { continue }
            for l in LinkScan.scan(t, canvas: canvas) { idx.add(key(l.target), rel) }
        }
        return idx
    }

    /// frontmatter(앞 8KB) 안 위키 링크의 이름 열쇠. outLinks에는 frontmatter 링크가 없다.
    private func frontmatterKeys(_ abs: String) -> [String] {
        guard let h = FileHandle(forReadingAtPath: abs) else { return [] }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: 8192), let t = String(data: d, encoding: .utf8) ?? String(data: d.dropLast(3), encoding: .utf8),
              t.hasPrefix("---"), t.contains("[[") else { return [] }
        return LinkScan.markdown(t).filter { $0.inFrontmatter }.map {
            (Indexer.nfc($0.target).trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent.lowercased()
        }
    }

    /// 고쳐 쓸 수 없는 파일인가(심볼릭 링크·읽기 전용·볼트 밖).
    func writeProblem(_ v: OrgVault, _ rel: String) -> String? {
        let abs = v.abs(rel)
        if let t = (try? FileManager.default.attributesOfItem(atPath: abs))?[.type] as? FileAttributeType, t == .typeSymbolicLink {
            return "고칠 파일이 심볼릭 링크예요"
        }
        if !Indexer.nfc(Indexer.realPath(abs)).hasPrefix(v.root + "/") { return "고칠 파일이 볼트 밖에 있어요" }
        if !FileManager.default.isWritableFile(atPath: abs) { return "읽기 전용 파일이라 링크를 고칠 수 없어요" }
        return nil
    }

    /// fromRel → toRel 이동에 필요한 링크 수정 계획. files = 이동 전 볼트 파일 목록, index = 같은 상태의 링크 색인.
    func planMove(_ v: OrgVault, fromRel: String, toRel: String, files: VaultFiles, index: OrgLinkIndex? = nil) -> MovePlan {
        var plan = MovePlan(fromRel: fromRel, toRel: toRel)
        let after = files.moving(fromRel, to: toRel)
        let keys = Set(VaultFiles.nameKeys(fromRel))
        let li = index ?? buildLinkIndex(v, files: files)
        var cands = Set<String>()
        for k in keys { cands.formUnion(li.byKey[k] ?? []) }
        cands.remove(fromRel)
        for rel in cands.sorted() + [fromRel] {
            let moved = rel == fromRel
            let canvas = (rel as NSString).pathExtension.lowercased() == "canvas"
            if moved && !canvas && !Organizer.isMarkdown(rel) { continue }   // v0.6: 옮길 파일이 PDF·그림 등이면 그 파일 안은 고칠 링크가 없다
            guard let data = FileManager.default.contents(atPath: v.abs(rel)) else {
                if moved { plan.problem = "파일을 읽을 수 없어요" }
                continue
            }
            guard let text = String(data: data, encoding: .utf8) else {
                if moved { plan.problem = "UTF-8이 아닌 파일은 옮기지 않아요" }
                continue
            }
            let links = LinkScan.scan(text, canvas: canvas)
            if !moved && !links.contains(where: { l in
                let t = LinkResolve.target(l, from: rel, files: files)
                return t == fromRel || nameMatches(l.target, keys: keys)
            }) { continue }
            plan.unresolvedBefore += LinkResolve.unresolved(links, from: rel, files: files)
            plan.checked.append((rel, moved ? toRel : rel, canvas))
            let (out, n, problem, changes) = fixFile(text: text, canvas: canvas, fromBefore: rel, fromAfter: moved ? toRel : rel,
                                            plan: plan, before: files, after: after)
            if let p = problem { plan.problem = p + " (" + Organizer.fileName(rel) + ")"; return plan }
            if n > 0 {
                if let p = writeProblem(v, rel) { plan.problem = p + " (" + Organizer.fileName(rel) + ")"; return plan }
                plan.edits.append(FileEdit(rel: rel, moved: moved, canvas: canvas, original: data, newText: out, count: n, changes: changes))
            }
        }
        return plan
    }

    /// 사후 검사: 영향 받은 파일들의 지금 미해결 링크 수(디스크 기준).
    func unresolvedNow(_ v: OrgVault, _ plan: MovePlan) -> Int {
        let files = listFiles(v)
        var n = 0
        for c in plan.checked {
            guard let d = FileManager.default.contents(atPath: v.abs(c.afterRel)), let t = String(data: d, encoding: .utf8) else { n += 1000; continue }
            n += LinkResolve.unresolved(LinkScan.scan(t, canvas: c.canvas), from: c.afterRel, files: files)
        }
        return n
    }
}
