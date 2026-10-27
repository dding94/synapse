import Foundation

// v0.9 폴더 이동 링크 계획 (docs/V09.md §4.5). 기존 링크 읽기·해석(LinkScan·LinkResolve·VaultFiles)을 쓰고,
// 안쪽 파일이 함께 움직이는 폴더 단위 계획을 새로 만든다. 디스크는 읽기만 한다(쓰기는 TidyOps).
// 고칠 곳: (a) 옮기는 것 밖 md의 경로형 링크가 안쪽을 가리키면 새 경로로, (b) 안쪽 md의 링크가 바깥을 가리키면 새 위치 기준으로.
// 이름만 쓴 [[노트]]는 그대로 둔다. 링크 모양(위키·마크다운, 볼트 기준·상대, 확장자, |별칭, #제목)은 원래대로.

struct TidyLinkEdit {
    let rel: String           // 이동 전 볼트 상대 경로
    let newRel: String        // 이동 뒤 볼트 상대 경로 (안 옮기면 rel과 같다)
    let canvas: Bool
    let original: Data
    let newText: String
    let count: Int
    var moved: Bool { rel != newRel }
}

struct TidyLinkPlan {
    var vault: String? = nil
    var edits: [TidyLinkEdit] = []
    var problem: String? = nil
    var warnings: [String] = []
    var checked: [(rel: String, canvas: Bool)] = []    // 사후 검사할 파일 (이동 뒤 상대 경로)
    var unresolvedBefore = 0
    var links: Int { edits.reduce(0) { $0 + $1.count } }
    var needsRewrite: Bool { !edits.isEmpty }
}

/// 한 볼트의 파일 목록과 md·캔버스 본문 (한 번 읽어 여러 계획에 쓴다).
final class TidyCorpus {
    let root: String
    let files: VaultFiles
    private var texts: [String: (Data, String)?] = [:]
    init(root: String) {
        self.root = root
        files = VaultFiles(Indexer.listFiles(root: root))
    }
    func text(_ rel: String) -> (Data, String)? {
        if let t = texts[rel] { return t }
        var v: (Data, String)? = nil
        if let d = FileManager.default.contents(atPath: root + "/" + rel), let s = String(data: d, encoding: .utf8) { v = (d, s) }
        texts[rel] = v
        return v
    }
    static func linkable(_ rel: String) -> Bool {
        let e = (rel as NSString).pathExtension.lowercased()
        return e == "md" || e == "markdown" || e == "canvas"
    }
}

extension Tidy {

    /// 옮기기 목록(이동 전·뒤 NFC 절대 경로)의 링크 계획.
    /// 같은 볼트 안 이동이면 고칠 곳을 만들고, 볼트 밖 → 볼트면 바깥을 가리키는 상대 링크 경고만, 볼트 → 밖이면 들어오는 링크 경고만.
    func linkPlan(_ moves: [(from: String, to: String, isDir: Bool)], vm: VaultMap, corpus: TidyCorpus? = nil) -> TidyLinkPlan {
        var plan = TidyLinkPlan()
        guard let first = moves.first else { return plan }
        let vf = vm.vault(forAbs: first.from), vt = vm.vault(forAbs: first.to)
        if let v = vf, v == vt, moves.allSatisfy({ vm.vault(forAbs: $0.from) == v && vm.vault(forAbs: $0.to) == v }) {
            let c = (corpus?.root == v ? corpus : nil) ?? TidyCorpus(root: v)
            return planInVault(moves, vault: v, corpus: c)
        }
        if vt != nil && vf == nil {
            let n = outboundRelativeLinks(moves)
            if n > 0 { plan.warnings.append("링크 \(n)개가 바깥 파일을 가리켜요") }
            return plan
        }
        if let v = vf {
            let c = (corpus?.root == v ? corpus : nil) ?? TidyCorpus(root: v)
            let n = inboundLinks(moves, vault: v, corpus: c)
            if n > 0 { plan.warnings.append("볼트 안 링크 \(n)개가 이 자리를 가리켜요") }
        }
        return plan
    }

    // MARK: 같은 볼트 안

    private func planInVault(_ moves: [(from: String, to: String, isDir: Bool)], vault v: String, corpus: TidyCorpus) -> TidyLinkPlan {
        var plan = TidyLinkPlan()
        plan.vault = v
        let before = corpus.files
        // 이동 전 상대 경로 → 이동 뒤 상대 경로
        var map: [String: String] = [:]
        var names: [String] = []
        for m in moves {
            guard let fr = Indexer.relativePath(path: m.from, root: v), let tr = Indexer.relativePath(path: m.to, root: v) else { continue }
            if m.isDir {
                let pre = fr + "/"
                for r in before.rels where r.hasPrefix(pre) { map[r] = tr + "/" + String(r.dropFirst(pre.count)) }
            } else if before.rels.contains(fr) {
                map[fr] = tr
            }
            let name = (fr as NSString).lastPathComponent
            names.append(name)
            if !m.isDir { names.append((name as NSString).deletingPathExtension) }
        }
        if map.isEmpty { return plan }
        var after = VaultFiles([])
        for r in before.rels { after.insert(map[r] ?? r) }
        // 바깥 후보는 옮기는 이름이 본문에 나오는 md·캔버스만 (경로형 링크는 이름을 담는다)
        // 대소문자 무시 (해석기 LinkResolve도 대소문자를 가리지 않는다)
        var needles = Set<String>()
        for n in names where !n.isEmpty {
            needles.insert(n.lowercased())
            needles.insert(n.decomposedStringWithCanonicalMapping.lowercased())
            if let e = n.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) { needles.insert(e.lowercased()) }
        }
        var cands: [String] = []
        for r in before.rels.sorted() where TidyCorpus.linkable(r) {
            if map[r] != nil { cands.append(r); continue }
            guard let (_, t) = corpus.text(r) else { continue }
            let lt = t.lowercased()
            if needles.contains(where: { lt.contains($0) }) { cands.append(r) }
        }
        for rel in cands {
            let newRel = map[rel] ?? rel
            let canvas = (rel as NSString).pathExtension.lowercased() == "canvas"
            guard let (data, text) = corpus.text(rel) else {
                if map[rel] != nil && !canvas { plan.problem = "UTF-8이 아닌 파일이 있어요 (\(Organizer.fileName(rel)))"; return plan }
                continue
            }
            let links = LinkScan.scan(text, canvas: canvas)
            if links.isEmpty { continue }
            plan.unresolvedBefore += LinkResolve.unresolved(links, from: rel, files: before)
            plan.checked.append((newRel, canvas))
            let r = fixLinks(text: text, links: links, canvas: canvas, fromBefore: rel, fromAfter: newRel, map: map, before: before, after: after)
            if let p = r.problem { plan.problem = p + " (" + Organizer.fileName(rel) + ")"; return plan }
            if r.count > 0 {
                let abs = v + "/" + rel
                if let t = (try? FileManager.default.attributesOfItem(atPath: abs))?[.type] as? FileAttributeType, t == .typeSymbolicLink {
                    plan.problem = "고칠 파일이 심볼릭 링크예요 (\(Organizer.fileName(rel)))"; return plan
                }
                if !FileManager.default.isWritableFile(atPath: abs) { plan.problem = "읽기 전용 파일이라 링크를 고칠 수 없어요 (\(Organizer.fileName(rel)))"; return plan }
                plan.edits.append(TidyLinkEdit(rel: rel, newRel: newRel, canvas: canvas, original: data, newText: r.text, count: r.count))
            }
        }
        return plan
    }

    private func isNameOnly(_ l: LinkRef) -> Bool { l.kind == .wiki && !l.target.contains("/") }

    /// 한 파일의 링크를 이동 전후로 비교해 고친 본문을 만든다.
    private func fixLinks(text: String, links: [LinkRef], canvas: Bool, fromBefore: String, fromAfter: String, map: [String: String],
                          before: VaultFiles, after: VaultFiles) -> (text: String, count: Int, problem: String?) {
        let ns = NSMutableString(string: text)
        var count = 0
        var expected: [String?] = Array(repeating: nil, count: links.count)
        for (idx, l) in links.enumerated().reversed() {
            let (b, via) = LinkResolve.resolve(l, from: fromBefore, files: before)
            guard let bt = b else { continue }
            let exp = map[bt] ?? bt
            expected[idx] = exp
            if isNameOnly(l) { continue }                                     // 이름만 쓴 링크는 그대로
            if LinkResolve.target(l, from: fromAfter, files: after) == exp { continue }
            if l.inFrontmatter { return (text, 0, "속성(frontmatter) 안 링크는 고치지 않아요") }
            guard let rep = Tidy.rewriteLink(l, exp: exp, fromAfter: fromAfter, via: via) else {
                return (text, 0, "링크를 정확히 고칠 수 없어요: " + (l.kind == .wiki ? "[[\(l.target)]]" : l.target))
            }
            ns.replaceCharacters(in: l.range, with: rep)
            count += 1
        }
        let out = ns as String
        if count == 0 { return (text, 0, nil) }
        let check = LinkScan.scan(out, canvas: canvas)
        if check.count != links.count { return (text, 0, "링크를 고친 뒤 개수가 달라져요") }
        for (i, l) in check.enumerated() {
            guard let e = expected[i] else { continue }
            let got = LinkResolve.target(l, from: fromAfter, files: after)
            if isNameOnly(l) ? got == nil : got != e { return (text, 0, "링크를 고친 뒤 대상이 달라져요") }
        }
        if canvas, (try? JSONSerialization.jsonObject(with: Data(out.utf8))) == nil { return (text, 0, "캔버스 형식이 깨져요") }
        return (out, count, nil)
    }

    /// 링크를 새 대상(exp, 볼트 상대)으로 고친 문자열. 정확히 만들 수 없으면 nil. (OrganizerLinkPlan의 같은 규칙)
    static func rewriteLink(_ l: LinkRef, exp: String, fromAfter: String, via: LinkResolve.Via) -> String? {
        switch l.kind {
        case .canvas:
            return LinkScan.jsonEscape(exp)
        case .wiki:
            let t = l.target.trimmingCharacters(in: .whitespaces)
            let rel = t.hasPrefix("./") || t.hasPrefix("../")
            var path = exp
            if Organizer.isMarkdown(exp) && !Organizer.isMarkdown(t) { path = (exp as NSString).deletingPathExtension }
            if rel {
                var p = LinkResolve.relative(from: Organizer.parent(fromAfter), to: path)
                if t.hasPrefix("./") && !p.hasPrefix("../") { p = "./" + p }
                if !p.hasPrefix("./") && !p.hasPrefix("../") { p = "./" + p }
                path = p
            } else if !path.contains("/") { return nil }                       // 루트 파일은 이름과 구별할 수 없다
            return path + l.sub + (l.alias.map { l.pipe + $0 } ?? "")
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
            if raw.range(of: #"%[89A-Fa-f][0-9A-Fa-f]"#, options: .regularExpression) != nil {
                var allowed = CharacterSet.urlPathAllowed
                allowed.remove(charactersIn: "#?%")
                p = p.addingPercentEncoding(withAllowedCharacters: allowed) ?? p
            } else if raw.contains("%") || p.contains(" ") {
                p = p.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: " ", with: "%20")
            }
            return l.lead + p + l.sub + l.tail
        }
    }

    /// 사후 검사: 확인한 파일들의 지금 미해결 링크 수 (디스크 기준).
    func unresolvedNow(_ plan: TidyLinkPlan) -> Int {
        guard let v = plan.vault else { return 0 }
        let files = VaultFiles(Indexer.listFiles(root: v))
        var n = 0
        for c in plan.checked {
            guard let d = FileManager.default.contents(atPath: v + "/" + c.rel), let t = String(data: d, encoding: .utf8) else { n += 1000; continue }
            n += LinkResolve.unresolved(LinkScan.scan(t, canvas: c.canvas), from: c.rel, files: files)
        }
        return n
    }

    // MARK: 경고만

    /// 볼트 밖에서 들어오는 md의 상대 링크 중 옮기는 것 바깥의 실제 파일을 가리키는 수.
    func outboundRelativeLinks(_ moves: [(from: String, to: String, isDir: Bool)]) -> Int {
        var n = 0
        let roots = moves.map { $0.from }
        func inside(_ p: String) -> Bool { roots.contains { p == $0 || p.hasPrefix($0 + "/") } }
        for m in moves {
            let mdFiles: [String] = m.isDir
                ? Indexer.listFiles(root: TidyFS.rawPath(m.from)).filter { Organizer.isMarkdown($0) }.map { m.from + "/" + $0 }
                : (Organizer.isMarkdown(m.from) ? [m.from] : [])
            for f in mdFiles.prefix(2000) {
                guard let d = FileManager.default.contents(atPath: TidyFS.rawPath(f)), let t = String(data: d, encoding: .utf8) else { continue }
                let dir = (f as NSString).deletingLastPathComponent
                for l in LinkScan.markdown(t) {
                    var target: String
                    switch l.kind {
                    case .markdown:
                        target = Indexer.nfc(l.target.removingPercentEncoding ?? l.target)
                        if target.hasPrefix("/") { continue }
                    case .wiki:
                        target = Indexer.nfc(l.target.trimmingCharacters(in: .whitespaces))
                        guard target.hasPrefix("./") || target.hasPrefix("../") else { continue }
                    case .canvas: continue
                    }
                    guard let norm = LinkResolve.normPath(String(dir.dropFirst()) + "/" + target) else { continue }
                    let abs = "/" + norm
                    if inside(abs) { continue }
                    if TidyFS.exists(abs) || TidyFS.exists(abs + ".md") { n += 1 }
                }
            }
        }
        return n
    }

    /// 볼트 안에서 옮기는 것(볼트 밖으로 나감)을 가리키는 링크 수.
    func inboundLinks(_ moves: [(from: String, to: String, isDir: Bool)], vault v: String, corpus: TidyCorpus) -> Int {
        var moved = Set<String>()
        for m in moves {
            guard let fr = Indexer.relativePath(path: m.from, root: v) else { continue }
            if m.isDir { for r in corpus.files.rels where r.hasPrefix(fr + "/") { moved.insert(r) } } else { moved.insert(fr) }
        }
        var n = 0
        for r in corpus.files.rels where TidyCorpus.linkable(r) && !moved.contains(r) {
            guard let (_, t) = corpus.text(r) else { continue }
            let canvas = (r as NSString).pathExtension.lowercased() == "canvas"
            for l in LinkScan.scan(t, canvas: canvas) {
                if let target = LinkResolve.target(l, from: r, files: corpus.files), moved.contains(target) { n += 1 }
            }
        }
        return n
    }
}
