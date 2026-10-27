import Foundation

// v0.9 정리 비서 인벤토리 (docs/V09.md §4.1). 디스크를 직접 걷되 파일 내용은 읽지 않는다(제목·티켓 키는 색인에서).
// 비밀 파일은 이름만 본다. 걷기 상한: 자리당 파일 5,000개·깊이 8.

/// 켜진 로컬 출처 하나 (실제 경로·NFC).
struct TidySource {
    let id: String
    let name: String
    let root: String
    let excludes: [String]
    /// 사람이 읽는 출처 이름: 데스크톱·다운로드·문서는 우리말로.
    var label: String {
        switch (root as NSString).lastPathComponent {
        case "Desktop": return "데스크톱"
        case "Downloads": return "다운로드"
        case "Documents": return "문서"
        default: return name
        }
    }
    func rel(_ abs: String) -> String? { abs == root ? "" : Indexer.relativePath(path: abs, root: root) }
    func covers(_ abs: String) -> Bool { abs == root || abs.hasPrefix(root + "/") }
    func isExcluded(_ abs: String) -> Bool {
        guard let r = rel(abs), !r.isEmpty else { return false }
        return Indexer.isExcluded(rel: r, excludes)
    }
}

/// 계약(TidyPlace) 밖에 두는 자리별 내부 정보.
struct TidyPlaceInfo {
    var nameKeys: [String] = []      // 이름에 있는 티켓 키
    var secretDeep = false           // 안쪽 어디든 비밀 파일 이름이 있다 (옮기기 금지)
    var containsRoot = false         // 자신이나 안쪽이 출처 루트·볼트 루트다 (옮기기 금지)
    var containsFrozen = false       // 자신이나 안쪽이 동결 구역이다
    var stamp = TidyStamp(path: "", isDir: false, files: 0, mtime: 0, size: 0)
}

/// 재검증용 상태 (payload.snap 한 칸).
struct TidyStamp: Equatable {
    let path: String
    let isDir: Bool
    let files: Int
    let mtime: Double
    let size: Int
    var json: [String: Any] { ["path": path, "isDir": isDir, "files": files, "mtime": mtime, "size": size] }
    init(path: String, isDir: Bool, files: Int, mtime: Double, size: Int) {
        self.path = path; self.isDir = isDir; self.files = files; self.mtime = mtime; self.size = size
    }
    init?(json o: [String: Any]) {
        guard let p = o["path"] as? String else { return nil }
        path = p; isDir = (o["isDir"] as? Bool) ?? false; files = (o["files"] as? Int) ?? 0
        mtime = (o["mtime"] as? Double) ?? 0; size = (o["size"] as? Int) ?? 0
    }
    func same(_ o: TidyStamp) -> Bool { isDir == o.isDir && files == o.files && size == o.size && Swift.abs(mtime - o.mtime) < 0.001 }
}

// MARK: - 이름 규칙

enum TidyNames {
    /// NFC (ASCII면 그대로 — 걷기에서 자주 부른다).
    @inline(__always) static func nfc(_ s: String) -> String { s.utf8.allSatisfy { $0 < 0x80 } ? s : Indexer.nfc(s) }

    static let dataExts: Set<String> = ["txt", "html", "htm", "csv", "tsv", "json", "jsonl", "ndjson", "xml", "log"]
    static let rawTokens: Set<String> = ["raw", "data", "dataset", "datasets", "result", "results", "expected", "fixture", "fixtures",
                                         "dump", "dumps", "output", "outputs", "log", "logs", "measure", "sample", "samples", "cache",
                                         "tmp", "temp", "lanes", "scrape", "scraped", "crawl", "crawled"]
    static let codeMarkers: Set<String> = ["package.json", "manifest.json", "pom.xml", "build.gradle", "build.gradle.kts", "cargo.toml", "go.mod", "pyproject.toml"]
    /// 데스크톱 맨 위에 늘 있는 시스템 숨김 파일 (자리가 아니다).
    static let systemHidden: Set<String> = [".DS_Store", ".localized", ".CFUserTextEncoding", ".com.apple.timemachine.donotpresent"]
    /// 볼트 안에서 자리가 아닌 폴더.
    static let vaultSkip: Set<String> = ["_Templates", ".obsidian", ".claude", ".gstack", ".trash"]
    static let paraZones = ["_Inbox", "_workspace", "1-Projects", "2-Areas", "3-Resources", "4-Archive"]

    static func isSecret(_ name: String) -> Bool {
        let n = name.lowercased()
        if n == ".env" || n.hasPrefix(".env.") || n.hasSuffix(".env") || n == ".envrc" || n == ".netrc" || n == ".npmrc" || n == ".pgpass" { return true }
        for e in [".pem", ".key", ".p12", ".pfx", ".jks", ".keystore", ".kdbx", ".ppk"] where n.hasSuffix(e) { return true }
        if n.hasPrefix("id_rsa") || n.hasPrefix("id_ed25519") || n.hasPrefix("id_ecdsa") || n.hasPrefix("id_dsa") || n.hasPrefix("credentials") { return true }
        if n.hasPrefix("service-account") && n.hasSuffix(".json") { return true }
        if n.hasPrefix("secrets.") { return true }
        return false
    }
    static func isCodeMarker(_ name: String) -> Bool {
        let n = name.lowercased()
        return codeMarkers.contains(n) || n.hasSuffix(".xcodeproj")
    }
    /// 원자료 이름: 이름을 - _ . 공백으로 나눈 조각 하나가 원자료 낱말이면.
    static func isRawName(_ name: String) -> Bool {
        name.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." || $0 == " " }).contains { rawTokens.contains(String($0)) }
    }
    static func isMarkdown(_ ext: String) -> Bool { ext == "md" || ext == "markdown" }

    /// 기계적인 이름 수: S06·001·p_12 같은 것 + 같은 접두 + 숫자가 5개 넘게 모인 것.
    static func mechCount(_ stems: [String]) -> Int {
        guard !stems.isEmpty else { return 0 }
        var n = 0
        var prefixes: [String: Int] = [:]
        for s in stems {
            let chars = Array(s.unicodeScalars)
            var i = chars.count
            while i > 0, chars[i - 1].properties.numericType != nil, chars[i - 1].isASCII { i -= 1 }
            let digits = chars.count - i
            guard digits > 0 else { continue }
            var head = String(String.UnicodeScalarView(chars[0..<i]))
            while let last = head.last, last == "-" || last == "_" || last == " " { head.removeLast() }
            if head.count <= 3 && head.allSatisfy({ $0.isASCII && $0.isLetter }) && digits <= 6 { n += 1; continue }
            prefixes[head, default: 0] += 1
        }
        let best = prefixes.values.max() ?? 0
        return min(stems.count, n + (best >= 5 ? best : 0))
    }

    private static let keyRx = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9])([A-Z][A-Z0-9]+-\d+)(?![0-9])"#)
    /// 이름의 티켓 키 (프로젝트 키가 알려진 것만, 나온 순서, 중복 없이).
    static func keys(in name: String, projects: Set<String>) -> [String] {
        guard name.contains("-"), !projects.isEmpty, projects.contains(where: { name.contains($0 + "-") }) else { return [] }
        let ns = name as NSString
        var out: [String] = []
        for m in keyRx.matches(in: name, range: NSRange(location: 0, length: ns.length)) {
            let k = ns.substring(with: m.range(at: 1))
            guard let p = k.split(separator: "-").first, projects.contains(String(p)), !out.contains(k) else { continue }
            out.append(k)
        }
        return out
    }
    static func isKey(_ s: String) -> Bool { s.range(of: #"^[A-Z][A-Z0-9]+-\d+$"#, options: .regularExpression) != nil }
}

// MARK: - 디렉터리 걷기

enum TidyFS {
    /// 폴더 항목 (이름 바이트 그대로, d_type).
    static func entries(_ dir: String) -> [(name: String, type: UInt8)] {
        guard let d = dir.withCString({ opendir($0) }) else { return [] }
        defer { closedir(d) }
        var out: [(String, UInt8)] = []
        while let ent = readdir(d) {
            let type = ent.pointee.d_type
            let name = withUnsafePointer(to: &ent.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(ent.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { out.append((name, type)) }
        }
        return out
    }

    struct Info { let isDir: Bool; let isFile: Bool; let isLink: Bool; let mtime: Double; let size: Int; let dev: Int32 }

    static func info(_ path: String) -> Info? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let fmt = st.st_mode & S_IFMT
        return Info(isDir: fmt == S_IFDIR, isFile: fmt == S_IFREG, isLink: fmt == S_IFLNK,
                    mtime: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9, size: Int(st.st_size), dev: st.st_dev)
    }

    static func exists(_ path: String) -> Bool { info(path) != nil }
    static func isDir(_ path: String) -> Bool { info(path)?.isDir == true }

    /// 가장 가까운 있는 조상(자신 포함)의 장치 번호.
    static func device(near path: String) -> Int32? {
        var p = path
        while !p.isEmpty && p != "/" {
            if let i = info(p) { return i.dev }
            p = (p as NSString).deletingLastPathComponent
        }
        return info("/")?.dev
    }

    /// 폴더 경로 풀이 캐시 (NFC → 디스크 이름). APFS는 정규화를 가리지 않고 찾으므로 옛 값도 같은 폴더를 가리킨다.
    private static var dirCache: [String: String] = [:]
    private static let cacheLock = NSLock()
    static func clearCache() { cacheLock.lock(); dirCache.removeAll(); cacheLock.unlock() }

    /// NFC 절대 경로 → 디스크에 저장된 이름 바이트 그대로의 경로. 없는 조각은 받은 그대로 둔다.
    static func rawPath(_ abs: String) -> String {
        let parent = (abs as NSString).deletingLastPathComponent
        let name = (abs as NSString).lastPathComponent
        if abs == "/" || abs.isEmpty { return "/" }
        let dir = rawDir(parent)
        if name.utf8.allSatisfy({ $0 < 0x80 }) { return (dir == "/" ? "" : dir) + "/" + name }
        return (dir == "/" ? "" : dir) + "/" + (Organizer.rawName(dir: dir, name: name) ?? name)
    }

    private static func rawDir(_ abs: String) -> String {
        if abs == "/" || abs.isEmpty { return "/" }
        cacheLock.lock(); let hit = dirCache[abs]; cacheLock.unlock()
        if let h = hit { return h }
        let parent = rawDir((abs as NSString).deletingLastPathComponent)
        let name = (abs as NSString).lastPathComponent
        let base = parent == "/" ? "" : parent
        var out = base + "/" + name
        if !name.utf8.allSatisfy({ $0 < 0x80 }) {
            guard let r = Organizer.rawName(dir: parent, name: name) else { return out }    // 없는 폴더는 캐시하지 않는다
            out = base + "/" + r
        }
        cacheLock.lock(); dirCache[abs] = out; cacheLock.unlock()
        return out
    }
}

/// 비밀 파일 검사 전용 걷기: 숨김 폴더·건너뛰는 폴더 안까지 이름만 본다(.git/objects만 뺀다). 상한에 닿으면 "확인하지 못함".
enum TidySecretScan {
    static let maxEntries = 200_000
    enum Result: Equatable { case clean, found(String), unknown }

    static func scan(_ raw: String) -> Result {
        var count = 0
        var hit: String? = nil
        var overflow = false
        func walk(_ dir: String, depth: Int) {
            if hit != nil || overflow { return }
            if depth > 64 { overflow = true; return }
            for (n, t) in TidyFS.entries(dir) {
                count += 1
                if count > maxEntries { overflow = true; return }
                let p = dir + "/" + n
                var isDir = t == UInt8(DT_DIR)
                if t == UInt8(DT_UNKNOWN) { isDir = TidyFS.info(p)?.isDir == true }
                if isDir {
                    if n == "objects" && (dir as NSString).lastPathComponent == ".git" { continue }
                    walk(p, depth: depth + 1)
                    if hit != nil || overflow { return }
                } else {
                    if TidyNames.isSecret(TidyNames.nfc(n)) { hit = TidyNames.nfc(n); return }
                }
            }
        }
        if TidyNames.isSecret(TidyNames.nfc((raw as NSString).lastPathComponent)) { return .found((raw as NSString).lastPathComponent) }
        guard TidyFS.isDir(raw) else { return .clean }
        walk(raw, depth: 0)
        if let h = hit { return .found(h) }
        return overflow ? .unknown : .clean
    }

    /// 옮기기를 막는 이유 (사람 말). 괜찮으면 nil.
    static func problem(_ raw: String) -> String? {
        switch scan(raw) {
        case .clean: return nil
        case .found: return "안에 비밀 값 파일이 있어 옮기지 않아요"
        case .unknown: return "안에 항목이 너무 많아 비밀 값 파일이 없는지 확인하지 못해서 옮기지 않아요"
        }
    }
}

/// 자리 하나를 걷는다. 숨김 폴더·node_modules 등은 세지 않는다(.git이 있으면 git만 표시).
final class TidyWalk {
    static let maxFiles = 5000
    static let maxDepth = 8

    struct Node {
        let path: String         // NFC 절대 경로
        let parent: Int
        let depth: Int           // 기준(출처·볼트 루트)에서의 깊이
        let nameHit: Bool        // 자신이나 조상 이름이 원자료 이름
        var files = 0, md = 0, data = 0, mech = 0
        var kinds: [String: Int] = [:]
        var sample: [String] = []
    }

    var files = 0, md = 0, size = 0
    var last = 0.0
    var kinds: [String: Int] = [:]
    var truncated = false, git = false, secretDeep = false
    var topNames: [String] = []          // 자리 바로 아래 이름 (숨김 포함)
    var fileKeys: [String: Int] = [:]    // 안쪽 파일 이름의 티켓 키 수
    var nodes: [Node] = []
    let projects: Set<String>
    let wantRaw: Bool

    init(projects: Set<String>, wantRaw: Bool) { self.projects = projects; self.wantRaw = wantRaw }

    func run(_ raw: String, nfcPath: String, baseDepth: Int, nameHit: Bool) {
        walk(raw, nfc: nfcPath, depth: 0, baseDepth: baseDepth, parent: -1, nameHit: nameHit)
        if wantRaw {
            // 자식 → 부모로 합친다 (자식이 뒤에 붙으므로 거꾸로)
            for i in stride(from: nodes.count - 1, through: 1, by: -1) {
                let p = nodes[i].parent
                guard p >= 0 else { continue }
                nodes[p].files += nodes[i].files; nodes[p].md += nodes[i].md
                nodes[p].data += nodes[i].data; nodes[p].mech += nodes[i].mech
                for (k, v) in nodes[i].kinds { nodes[p].kinds[k, default: 0] += v }
                if nodes[p].sample.count < 3 { nodes[p].sample += nodes[i].sample.prefix(3 - nodes[p].sample.count) }
            }
        }
    }

    private func walk(_ dir: String, nfc: String, depth: Int, baseDepth: Int, parent: Int, nameHit: Bool) {
        let list = TidyFS.entries(dir)
        let idx = nodes.count
        nodes.append(Node(path: nfc, parent: parent, depth: baseDepth + depth, nameHit: nameHit))
        var stems: [String] = []
        for (name, type) in list {
            if depth == 0 { topNames.append(name) }
            let p = dir + "/" + name
            var isDir = type == UInt8(DT_DIR)
            var isFile = type == UInt8(DT_REG)
            if type == UInt8(DT_UNKNOWN) {
                guard let i = TidyFS.info(p) else { continue }
                isDir = i.isDir; isFile = i.isFile
            }
            if name.hasPrefix(".") {
                if name == ".git" { git = true }
                if !isDir && TidyNames.isSecret(name) { secretDeep = true }
                continue
            }
            if isDir {
                if Indexer.skipNames.contains(name) { continue }
                if depth + 1 > TidyWalk.maxDepth { truncated = true; continue }
                if files >= TidyWalk.maxFiles { truncated = true; continue }
                let nn = TidyNames.nfc(name)
                walk(p, nfc: nfc + "/" + nn, depth: depth + 1, baseDepth: baseDepth, parent: idx,
                     nameHit: nameHit || TidyNames.isRawName(nn))
                continue
            }
            guard isFile else { continue }                       // 심볼릭 링크·특수 파일은 세지 않는다
            if files >= TidyWalk.maxFiles { truncated = true; continue }
            guard let i = TidyFS.info(p) else { continue }
            files += 1; size += i.size
            if i.mtime > last { last = i.mtime }
            let n = TidyNames.nfc(name)
            let ext = (n as NSString).pathExtension.lowercased()
            kinds[ext, default: 0] += 1
            let isMD = TidyNames.isMarkdown(ext)
            if isMD { md += 1 }
            if TidyNames.isSecret(n) { secretDeep = true }
            for k in TidyNames.keys(in: n, projects: projects) { fileKeys[k, default: 0] += 1 }
            if wantRaw {
                nodes[idx].files += 1
                if isMD { nodes[idx].md += 1 }
                if TidyNames.dataExts.contains(ext) { nodes[idx].data += 1 }
                nodes[idx].kinds[ext, default: 0] += 1
                if nodes[idx].sample.count < 3 { nodes[idx].sample.append(n) }
                stems.append((n as NSString).deletingPathExtension)
            }
        }
        if wantRaw { nodes[idx].mech = TidyNames.mechCount(stems) }
    }

    /// 원자료 폴더 후보: 조건을 모두 만족하는 가장 위 폴더들 (§4.1).
    /// certain(원자료 이름 + md 5% 이하)을 먼저 고르고, 그 위·아래와 겹치지 않는 likely를 더한다
    /// (기계적인 이름이 많은 상위 폴더가 안쪽의 확실한 원자료 폴더를 가리지 않게).
    func rawNodes(maxDepth: Int = 6) -> [(node: Node, certain: Bool)] {
        guard wantRaw, !nodes.isEmpty else { return [] }
        var children: [Int: [Int]] = [:]
        for (i, n) in nodes.enumerated() where n.parent >= 0 { children[n.parent, default: []].append(i) }
        func qualifies(_ n: Node) -> Bool {
            n.depth <= maxDepth && n.files > 0 && n.data >= 20 && n.md * 10 <= n.files && (n.nameHit || n.mech * 5 >= n.files * 4)
        }
        func certain(_ n: Node) -> Bool { n.nameHit && n.md * 20 <= n.files }
        var out: [(Node, Bool)] = []
        var certainIdx = Set<Int>()
        func visitCertain(_ i: Int) {
            if qualifies(nodes[i]) && certain(nodes[i]) { out.append((nodes[i], true)); certainIdx.insert(i); return }
            for c in children[i] ?? [] { visitCertain(c) }
        }
        visitCertain(0)
        func hasCertainBelow(_ i: Int) -> Bool {
            if certainIdx.contains(i) { return true }
            return (children[i] ?? []).contains { hasCertainBelow($0) }
        }
        func visitLikely(_ i: Int) {
            if certainIdx.contains(i) { return }
            if qualifies(nodes[i]) && !hasCertainBelow(i) { out.append((nodes[i], false)); return }
            for c in children[i] ?? [] { visitLikely(c) }
        }
        visitLikely(0)
        return out
    }
}

// MARK: - 인벤토리 만들기

extension Tidy {

    /// 켜진 로컬 출처 (긴 루트 먼저 — 안쪽 출처 우선).
    func localSources() -> [TidySource] {
        ctx.sources().filter { $0.enabled && ($0.kind == .folder || $0.kind == .obsidian) && !($0.path ?? "").isEmpty }
            .map { TidySource(id: $0.id, name: $0.name, root: Indexer.nfc(Indexer.realPath($0.path!)), excludes: Indexer.excludedFolders($0)) }
            .sorted { $0.root.count != $1.root.count ? $0.root.count > $1.root.count : $0.id < $1.id }
    }

    func vaultMap() -> VaultMap { VaultMap.detect(sources: ctx.sources(), home: ctx.env.userHome) }

    /// 이 경로를 색인하는 가장 안쪽 출처.
    func source(covering abs: String, _ sources: [TidySource]) -> TidySource? { sources.first { $0.covers(abs) } }

    /// 알려진 Jira 프로젝트 키: 색인의 Jira 문서·remote_state·볼트 _workspace 폴더 이름.
    func projectKeys(vaults: [String]) -> Set<String> {
        var out = Set<String>()
        for d in ctx.docs where d.kind == "jira" {
            if let r = d.id.range(of: ":jira:") {
                let key = String(d.id[r.upperBound...])
                if let p = key.split(separator: "-").first { out.insert(String(p)) }
            }
        }
        try? ctx.db.sql.query("SELECT key FROM remote_state WHERE key IS NOT NULL") {
            if let p = $0.text(0).split(separator: "-").first, !p.isEmpty { out.insert(String(p)) }
        }
        for v in vaults {
            for (n, _) in TidyFS.entries(v + "/_workspace") {
                let name = Indexer.nfc(n)
                if TidyNames.isKey(name), let p = name.split(separator: "-").first { out.insert(String(p)) }
            }
        }
        return out
    }

    /// Jira 상태: 키 → (상태, 범주, 요약).
    func jiraStates() -> [String: (status: String, category: String, summary: String)] {
        var out: [String: (String, String, String)] = [:]
        try? ctx.db.sql.query("SELECT key, status, status_cat, title FROM remote_state WHERE key IS NOT NULL") { r in
            out[r.text(0)] = (r.text(1).trimmingCharacters(in: CharacterSet(charactersIn: "# ")), r.text(2), r.text(3))
        }
        for d in ctx.docs where d.kind == "jira" {
            guard let r = d.id.range(of: ":jira:") else { continue }
            let key = String(d.id[r.upperBound...])
            if out[key] == nil {
                let st = d.meta["status"] ?? ""
                let cat = d.meta["statusCategory"] ?? d.meta["status_cat"] ?? ""
                let title = d.title.components(separatedBy: " · ").dropFirst().joined(separator: " · ")
                out[key] = (st, cat, title.isEmpty ? d.title : title)
            }
        }
        return out
    }

    /// 볼트 규칙표 (기본 + CLAUDE.md). CLAUDE.md 수정 시각이 같으면 캐시.
    func policy(vault: String) -> [PolicyRule] {
        let v = OrgVault(sourceId: "", root: vault, excludeFolders: [])
        let stamp = organizer.policyFiles(v).map { "\($0.rel)@\($0.mtime)" }.joined(separator: ",")
        if let c = policyCache[vault], c.stamp == stamp { return c.rules }
        let rules = organizer.compilePolicy(v).rules
        policyCache[vault] = (stamp, rules)
        return rules
    }

    func frozenPatterns(vault: String) -> [String] { policy(vault: vault).filter { $0.kind == "frozen" }.map { $0.pattern } }

    /// 볼트 상대 경로가 동결 구역 안인가.
    static func isFrozen(_ rel: String, _ patterns: [String]) -> Bool {
        let r = rel.hasSuffix("/") ? rel : rel + "/"
        return patterns.contains { Organizer.folderMatches($0, r) }
    }
    /// 볼트 상대 경로 안쪽에 동결 구역이 있는가 (자신 포함).
    static func containsFrozen(_ rel: String, _ patterns: [String]) -> Bool {
        let r = (rel.hasSuffix("/") ? rel : rel + "/").lowercased()
        return isFrozen(rel, patterns) || patterns.contains { !$0.contains("{") && $0.lowercased().hasPrefix(r) }
    }

    /// 사람이 읽는 위치 라벨.
    func label(for abs: String, vm: VaultMap, sources: [TidySource], codeFolder: String?) -> String {
        if let v = vm.vault(forAbs: abs) {
            let rel = vm.paraRel(forAbs: abs) ?? ""
            let vname = (v as NSString).lastPathComponent
            if rel.isEmpty { return vname }
            var comps = rel.split(separator: "/").map(String.init)
            if comps.count == 1 { return vname + " › " + comps[0] }
            if comps[0] == "_Inbox" { comps[0] = "받은 문서함" }
            return comps.joined(separator: " › ")
        }
        if let c = codeFolder, abs == c || abs.hasPrefix(c + "/") {
            let rest = abs == c ? [] : String(abs.dropFirst(c.count + 1)).split(separator: "/").map(String.init)
            return (["코드 폴더"] + rest).joined(separator: " › ")
        }
        if let s = source(covering: abs, sources), let rel = s.rel(abs) {
            return ([s.label] + rel.split(separator: "/").map(String.init)).joined(separator: " › ")
        }
        return (abs as NSString).lastPathComponent
    }

    /// 경로 하나의 지금 상태 (파일: 수정 시각·크기, 폴더: 파일 수·최근 수정·크기 — 인벤토리와 같은 셈).
    func stamp(_ abs: String) -> TidyStamp? {
        let raw = TidyFS.rawPath(abs)
        guard let i = TidyFS.info(raw) else { return nil }
        if !i.isDir { return TidyStamp(path: abs, isDir: false, files: 1, mtime: i.mtime, size: i.size) }
        let w = TidyWalk(projects: [], wantRaw: false)
        w.run(raw, nfcPath: abs, baseDepth: 0, nameHit: false)
        return TidyStamp(path: abs, isDir: true, files: w.files, mtime: w.files == 0 ? i.mtime : w.last, size: w.size)
    }

    func buildInventory() -> TidyInventory {
        let t0 = Date()
        let sources = localSources()
        let vm = vaultMap()
        let vaults = vm.roots
        let projects = projectKeys(vaults: vaults)
        let code = codeFolderResolved()
        var frozenBy: [String: [String]] = [:]
        for v in vaults { frozenBy[v] = frozenPatterns(vault: v) }
        let allRoots = Set(sources.map { $0.root } + vaults)

        struct Cand {
            let raw: String; let path: String; let name: String; let isDir: Bool; let zone: TidyZone
            let vault: String?; let paraRel: String?; let baseDepth: Int; var vaultFlag: Bool
        }
        var cands: [Cand] = []
        var seen = Set<String>()
        func add(_ c: Cand) { if seen.insert(c.path).inserted { cands.append(c) } }

        // 볼트 안 자리
        for v in vaults {
            let vraw = TidyFS.rawPath(v)
            for (n, t) in TidyFS.entries(vraw) {
                let name = Indexer.nfc(n)
                if name.hasPrefix(".") || TidyNames.vaultSkip.contains(name) { continue }
                let p = vraw + "/" + n
                let isDir = t == UInt8(DT_DIR) || (t == UInt8(DT_UNKNOWN) && TidyFS.isDir(p))
                if isDir {
                    guard TidyNames.paraZones.contains(name), let zone = TidyZone.of(paraTop: name) else { continue }
                    for (cn, ct) in TidyFS.entries(p) {
                        let cname = Indexer.nfc(cn)
                        if cname.hasPrefix(".") || TidyNames.vaultSkip.contains(cname) { continue }
                        let cp = p + "/" + cn
                        let cDir = ct == UInt8(DT_DIR) || (ct == UInt8(DT_UNKNOWN) && TidyFS.isDir(cp))
                        guard cDir || ct == UInt8(DT_REG) || ct == UInt8(DT_UNKNOWN) else { continue }
                        add(Cand(raw: cp, path: v + "/" + name + "/" + cname, name: cname, isDir: cDir, zone: zone, vault: v,
                                 paraRel: name + "/" + cname, baseDepth: 2, vaultFlag: false))
                    }
                } else if t == UInt8(DT_REG) || t == UInt8(DT_UNKNOWN) {
                    if name == "CLAUDE.md" { continue }
                    add(Cand(raw: p, path: v + "/" + name, name: name, isDir: false, zone: .vaultRoot, vault: v, paraRel: name,
                             baseDepth: 1, vaultFlag: false))
                }
            }
        }
        // 볼트 밖 출처 루트의 맨 위 항목
        for s in sources where vm.vault(forAbs: s.root) == nil {
            let sraw = TidyFS.rawPath(s.root)
            for (n, t) in TidyFS.entries(sraw) {
                let name = Indexer.nfc(n)
                let p = sraw + "/" + n
                let isDir = t == UInt8(DT_DIR) || (t == UInt8(DT_UNKNOWN) && TidyFS.isDir(p))
                if name.hasPrefix(".") && (isDir || TidyNames.systemHidden.contains(name)) { continue }
                if isDir && Indexer.skipNames.contains(name) { continue }
                guard isDir || t == UInt8(DT_REG) || t == UInt8(DT_UNKNOWN) else { continue }
                let path = s.root + "/" + name
                let hasVault = vaults.contains { $0 == path || $0.hasPrefix(path + "/") }
                add(Cand(raw: p, path: path, name: name, isDir: isDir, zone: .loose, vault: nil, paraRel: nil, baseDepth: 1, vaultFlag: hasVault))
            }
        }

        // 걷기
        var places: [TidyPlace] = []
        var infos: [String: TidyPlaceInfo] = [:]
        // 문서 → 자리
        let candPaths = Set(cands.map { $0.path })
        var docsBy: [String: [BrainDoc]] = [:]
        for d in ctx.docs where d.isLocal {
            guard let a = d.absPath else { continue }
            var p = TidyNames.nfc(a)
            while p.count > 1 {
                if candPaths.contains(p) { docsBy[p, default: []].append(d); break }
                p = (p as NSString).deletingLastPathComponent
            }
        }
        for c in cands {
            var flags = Set<String>()
            var info = TidyPlaceInfo()
            info.nameKeys = TidyNames.keys(in: c.name, projects: projects)
            if c.name.hasPrefix(".") { flags.insert(TidyFlag.hidden) }
            let src = source(covering: c.path, sources)
            if let s = src, s.isExcluded(c.path) { flags.insert(TidyFlag.excluded) }
            info.containsRoot = allRoots.contains { $0 == c.path || $0.hasPrefix(c.path + "/") }
            if let v = c.vault, let rel = c.paraRel, let fz = frozenBy[v] {
                if Tidy.isFrozen(rel, fz) { flags.insert(TidyFlag.frozen) }
                info.containsFrozen = Tidy.containsFrozen(rel, fz)
            }
            if c.vaultFlag {
                flags.insert(TidyFlag.vault)
                let mt = TidyFS.info(c.raw)?.mtime ?? 0
                info.stamp = TidyStamp(path: c.path, isDir: true, files: 0, mtime: mt, size: 0)
                places.append(TidyPlace(id: TidyPlace.makeID(c.path), path: c.path, name: c.name, isDir: true, zone: c.zone, vaultRoot: nil,
                                        paraRel: nil, sourceId: src?.id, label: label(for: c.path, vm: vm, sources: sources, codeFolder: code),
                                        files: 0, mdFiles: 0, kinds: [:], size: 0, lastModified: mt, ticketKeys: [], flags: flags,
                                        titles: [], raw: [], docIds: []))
                infos[c.path] = info
                continue
            }
            var files = 1, md = 0, size = 0, last = 0.0
            var kinds: [String: Int] = [:]
            var raws: [TidyRaw] = []
            var fileKeys: [String: Int] = [:]
            if c.isDir {
                let nameHit = (c.paraRel ?? c.name).split(separator: "/").contains { TidyNames.isRawName(String($0)) }
                let w = TidyWalk(projects: projects, wantRaw: true)
                w.run(c.raw, nfcPath: c.path, baseDepth: c.baseDepth, nameHit: nameHit)
                files = w.files; md = w.md; size = w.size; kinds = w.kinds; fileKeys = w.fileKeys
                last = w.files == 0 ? (TidyFS.info(c.raw)?.mtime ?? 0) : w.last
                if w.files == 0 { flags.insert(TidyFlag.empty) }
                if w.truncated { flags.insert(TidyFlag.truncated) }
                if w.git { flags.insert(TidyFlag.git) }
                if w.topNames.contains(where: { TidyNames.isCodeMarker(Indexer.nfc($0)) }) { flags.insert(TidyFlag.code) }
                if w.topNames.contains(where: { TidyNames.isSecret(Indexer.nfc($0)) }) { flags.insert(TidyFlag.secret) }
                info.secretDeep = w.secretDeep
                for (n, certain) in w.rawNodes() {
                    guard let rs = source(covering: n.path, sources), let rel = rs.rel(n.path), !rel.isEmpty, !rs.isExcluded(n.path) else { continue }
                    if let v = c.vault, let fz = frozenBy[v], let prel = vm.paraRel(forAbs: n.path), Tidy.isFrozen(prel, fz) { continue }
                    let top = n.kinds.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(6)
                    raws.append(TidyRaw(path: n.path, sourceId: rs.id, rel: rel, files: n.files, kinds: Dictionary(uniqueKeysWithValues: top.map { ($0.key, $0.value) }),
                                        certain: certain, sample: n.sample))
                    if n.path == c.path { flags.insert(TidyFlag.rawData) }
                }
                info.stamp = TidyStamp(path: c.path, isDir: true, files: files, mtime: last, size: size)
            } else {
                guard let i = TidyFS.info(c.raw), i.isFile else { continue }
                size = i.size; last = i.mtime
                let ext = (c.name as NSString).pathExtension.lowercased()
                kinds = [ext: 1]
                if TidyNames.isMarkdown(ext) { md = 1 }
                if size <= 3 { flags.insert(TidyFlag.empty) }
                if TidyNames.isSecret(c.name) { flags.insert(TidyFlag.secret); info.secretDeep = true }
                info.stamp = TidyStamp(path: c.path, isDir: false, files: 1, mtime: last, size: size)
            }
            // 티켓 키: 이름 → 안쪽 문서 issueKeys(절반 이상) → 안쪽 파일 이름(절반 이상)
            let docs = (docsBy[c.path] ?? []).sorted { $0.modified > $1.modified }
            var score: [String: Int] = [:]
            for k in info.nameKeys { score[k, default: 0] += 100_000 }
            if !docs.isEmpty {
                var cnt: [String: Int] = [:]
                var uniq = Set<String>()
                for d in docs where uniq.insert(Indexer.nfc(d.absPath ?? d.id)).inserted {
                    for k in Set(d.issueKeys) where k.split(separator: "-").first.map({ projects.contains(String($0)) }) == true { cnt[k, default: 0] += 1 }
                }
                for (k, n) in cnt where n * 2 >= uniq.count { score[k, default: 0] += n }
            }
            if c.isDir && files > 0 { for (k, n) in fileKeys where n * 2 >= files { score[k, default: 0] += n } }
            let keys = score.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(3).map { $0.key }
            var titles: [String] = [], tseen = Set<String>()
            for d in docs where titles.count < 8 && tseen.insert(d.title).inserted { titles.append(d.title) }
            var docIds: [String] = [], dseen = Set<String>()
            for d in docs where docIds.count < 20 && dseen.insert(Indexer.nfc(d.absPath ?? d.id)).inserted { docIds.append(d.id) }
            let topKinds = kinds.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(6)
            places.append(TidyPlace(id: TidyPlace.makeID(c.path), path: c.path, name: c.name, isDir: c.isDir, zone: c.zone, vaultRoot: c.vault,
                                    paraRel: c.paraRel, sourceId: src?.id, label: label(for: c.path, vm: vm, sources: sources, codeFolder: code),
                                    files: files, mdFiles: md, kinds: Dictionary(uniqueKeysWithValues: topKinds.map { ($0.key, $0.value) }),
                                    size: size, lastModified: last, ticketKeys: keys, flags: flags, titles: titles, raw: raws, docIds: docIds))
            infos[c.path] = info
        }
        // 볼트 자체 자리: 안쪽 자리 합
        for (i, p) in places.enumerated() where p.flags.contains(TidyFlag.vault) {
            let inner = places.filter { $0.path.hasPrefix(p.path + "/") && !$0.flags.contains(TidyFlag.vault) }
            let last = inner.map { $0.lastModified }.max() ?? p.lastModified
            places[i] = TidyPlace(id: p.id, path: p.path, name: p.name, isDir: true, zone: p.zone, vaultRoot: nil, paraRel: nil, sourceId: p.sourceId,
                                  label: p.label, files: inner.reduce(0) { $0 + $1.files }, mdFiles: inner.reduce(0) { $0 + $1.mdFiles }, kinds: [:],
                                  size: inner.reduce(0) { $0 + $1.size }, lastModified: last, ticketKeys: [], flags: p.flags, titles: [], raw: [], docIds: [])
        }
        placeInfo = infos
        let dests = destinations(vaults: vaults, frozenBy: frozenBy, code: code)
        let hashSrc = places.map { p in
            "\(p.path)|\(p.files)|\(p.mdFiles)|\(Int(p.lastModified / 86400))|\(p.flags.sorted().joined(separator: ","))|\(p.raw.map { $0.path }.joined(separator: ","))"
        }.sorted().joined(separator: "\n") + "\n" + vaults.joined(separator: ",")
        lastInventoryMs = Date().timeIntervalSince(t0) * 1000
        return TidyInventory(generated: nowTS, places: places, vaults: vaults, destinations: dests, hash: Organizer.sha1(hashSrc))
    }

    /// 옮길 수 있는 기존 폴더: 볼트 PARA 구역 폴더와 그 아래 3단계까지 + 코드 폴더.
    func destinations(vaults: [String], frozenBy: [String: [String]], code: String?) -> [TidyDestination] {
        var out: [TidyDestination] = []
        for v in vaults {
            let vraw = TidyFS.rawPath(v)
            let fz = frozenBy[v] ?? []
            for top in TidyNames.paraZones {
                guard let rn = Organizer.rawName(dir: vraw, name: top), TidyFS.isDir(vraw + "/" + rn) else { continue }
                let zone = TidyZone.of(paraTop: top)
                func visit(_ raw: String, _ rel: String, _ depth: Int) {
                    out.append(TidyDestination(path: v + "/" + rel, label: rel.split(separator: "/").joined(separator: " › "), zone: zone, isCode: false))
                    guard depth < 3 else { return }
                    for (n, t) in TidyFS.entries(raw).sorted(by: { $0.name < $1.name }) {
                        let name = Indexer.nfc(n)
                        if name.hasPrefix(".") || TidyNames.vaultSkip.contains(name) || Indexer.skipNames.contains(name) || TidyNames.isRawName(name) { continue }
                        let p = raw + "/" + n
                        guard t == UInt8(DT_DIR) || (t == UInt8(DT_UNKNOWN) && TidyFS.isDir(p)) else { continue }
                        let r = rel + "/" + name
                        if Tidy.isFrozen(r, fz) { continue }
                        visit(p, r, depth + 1)
                    }
                }
                visit(vraw + "/" + rn, top, 0)
            }
        }
        if let c = code {
            out.append(TidyDestination(path: c, label: "코드 폴더 › " + (c as NSString).lastPathComponent, zone: nil, isCode: true))
        }
        return out
    }
}
