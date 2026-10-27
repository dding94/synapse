import Foundation
import CoreServices

// 폴더 스캔·증분 색인·FSEvents·원격 결과 반영 (docs/CONNECT.md §3.4). 모든 쓰기는 Library의 색인 큐에서 부른다.

struct ScanEntry {
    let rel: String
    let path: String
    let mtime: Double
    let size: Int
    var fingerprint: String { "\(Int64((mtime * 1000).rounded()))-\(size)" }
}

enum Indexer {
    static let skipNames: Set<String> = ["node_modules", "Library", "build", "dist", "__pycache__"]
    static let maxBytes = 50 * 1024 * 1024
    static let batchSize = 48

    /// 경로의 실제 경로(심볼릭 링크·/private 해석).
    static func realPath(_ p: String) -> String {
        guard let r = realpath(p, nil) else { return (p as NSString).standardizingPath }
        defer { free(r) }
        return String(cString: r)
    }

    static func isSkippedDirName(_ name: String) -> Bool { name.hasPrefix(".") || skipNames.contains(name) }

    /// NFC 정규화 (파일 이름이 NFD로 저장돼 있어도 id는 항상 NFC).
    static func nfc(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }

    struct ScanResult { var entries: [ScanEntry] = []; var failedDirs: [String] = [] }

    /// 루트를 읽을 수 있는지 확인. 못 읽으면 사용자용 한 문장 오류.
    static func checkRoot(_ root: String) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir) else {
            throw LibraryError("폴더를 찾을 수 없어요. 외장 디스크라면 연결되어 있는지 확인해 주세요.")
        }
        guard isDir.boolValue else { throw LibraryError("폴더가 아니에요.") }
        do { _ = try FileManager.default.contentsOfDirectory(atPath: root) }
        catch { throw LibraryError("폴더를 읽을 수 없어요. 시스템 설정 › 개인정보 보호에서 접근을 허용해 주세요.") }
    }

    /// 재귀 순회: 숨김·제외 폴더·패키지 번들 건너뛰기, 지원 확장자·50MB 이하만.
    /// 읽지 못한 하위 폴더는 failedDirs(NFC 상대 경로)에 모은다 — 그 아래 문서는 지우지 않는다.
    /// 소스가 색인하는 확장자: includeKinds가 있으면 그것, 없으면 obsidian = md·markdown·pdf, folder = 지원 형식 전부.
    static func includedKinds(_ src: SourceConfig) -> Set<String> {
        let supported = Plugins.supportedExtensions
        if let k = src.includeKinds { return Set(k.map { $0.lowercased() }).intersection(supported) }
        if src.kind == .obsidian { return Set(["md", "markdown", "pdf"]).intersection(supported) }
        return supported
    }

    /// 제외 폴더(NFC 상대 경로, 앞뒤 "/" 없이).
    static func excludedFolders(_ src: SourceConfig) -> [String] {
        (src.excludeFolders ?? []).map { nfc($0).trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) }.filter { !$0.isEmpty }
    }

    static func isExcluded(rel: String, _ excluded: [String]) -> Bool {
        excluded.contains { rel == $0 || rel.hasPrefix($0 + "/") }
    }

    static func scan(root: String, kinds: Set<String>? = nil, exclude: [String] = []) throws -> ScanResult {
        try checkRoot(root)
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        var res = ScanResult()
        let rootN = nfc(root.hasSuffix("/") ? root : root + "/")
        let rel: (String) -> String? = { p in
            let n = nfc(p)
            return n.hasPrefix(rootN) ? String(n.dropFirst(rootN.count)) : nil
        }
        var failed: [String] = []
        guard let en = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants],
                                                      errorHandler: { url, _ in
                                                          failed.append(rel(url.path) ?? ""); return true
                                                      }) else {
            throw LibraryError("폴더를 읽을 수 없어요. 시스템 설정 › 개인정보 보호에서 접근을 허용해 주세요.")
        }
        let exts = kinds ?? Plugins.supportedExtensions
        for case let url as URL in en {
            let name = url.lastPathComponent
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isDirectory == true {
                if isSkippedDirName(name) || v.isPackage == true { en.skipDescendants() }
                else if !exclude.isEmpty, let r = rel(url.path), isExcluded(rel: r, exclude) { en.skipDescendants() }
                continue
            }
            if name.hasPrefix(".") || v.isRegularFile != true { continue }
            guard exts.contains(url.pathExtension.lowercased()) else { continue }
            let size = v.fileSize ?? 0
            if size > maxBytes { continue }
            guard let r = rel(url.path) else { continue }
            res.entries.append(ScanEntry(rel: r, path: url.path, mtime: v.contentModificationDate?.timeIntervalSince1970 ?? 0, size: size))
        }
        res.failedDirs = failed
        return res
    }

    /// 루트와 파일 사이 폴더 중 패키지 번들(.app 등)이나 제외 폴더가 있는가 (scan과 같은 규칙).
    static func isExcludedAncestor(path: String, root: String) -> Bool {
        var dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        let rootN = nfc(root.hasSuffix("/") ? String(root.dropLast()) : root)
        while nfc(dir.path).count > rootN.count {
            if isSkippedDirName(dir.lastPathComponent) { return true }
            if (try? dir.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true { return true }
            dir = dir.deletingLastPathComponent()
        }
        return false
    }

    /// 단일 경로의 현재 상태 (없거나 대상 아니면 nil).
    static func entry(path: String, root: String, kinds: Set<String>? = nil, exclude: [String] = []) -> ScanEntry? {
        guard let rel = relativePath(path: path, root: root), !isExcluded(rel: rel, exclude) else { return nil }
        guard let name = rel.split(separator: "/").last.map(String.init), !name.hasPrefix("."),
              (kinds ?? Plugins.supportedExtensions).contains((name as NSString).pathExtension.lowercased()) else { return nil }
        if isExcludedAncestor(path: path, root: root) { return nil }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              (attrs[.type] as? FileAttributeType) == .typeRegular else { return nil }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        if size > maxBytes { return nil }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return ScanEntry(rel: rel, path: path, mtime: mtime, size: size)
    }

    /// NFC 상대 경로 (루트 밖이면 nil).
    static func relativePath(path: String, root: String) -> String? {
        let prefix = nfc(root.hasSuffix("/") ? root : root + "/")
        let p = nfc(path)
        return p.hasPrefix(prefix) ? String(p.dropFirst(prefix.count)) : nil
    }

    /// 추출 결과 → DocRecord.
    static func record(_ e: ScanEntry, source: SourceConfig, file: ExtractedFile) -> DocRecord {
        let comps = e.rel.split(separator: "/").map(String.init)
        let fileName = comps.last ?? e.rel
        let stem = (fileName as NSString).deletingPathExtension
        let folder = comps.dropLast().joined(separator: "/")
        let group = comps.count > 1 ? comps[0] : source.name
        var title = file.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if title.isEmpty { title = stem }
        return DocRecord(id: source.id + ":" + e.rel, sourceId: source.id, kind: (fileName as NSString).pathExtension.lowercased(),
                         title: title, location: e.path, displayPath: ([source.name] + comps).joined(separator: " / "),
                         folder: folder, group: group, modified: Date(timeIntervalSince1970: e.mtime), created: file.created,
                         size: e.size, tags: file.tags, aliases: file.aliases, outLinks: file.outLinks,
                         text: String(file.text.prefix(400_000)), fingerprint: e.fingerprint)
    }

    /// 첫 문장 (최대 120자). 제목과 같은 첫 줄은 건너뛴다.
    static func summary(_ text: String, title: String) -> String {
        let nt = Korean.normalize(title)
        var line = "", firstLine = ""
        var seen = 0
        // 제목과 같은 첫 줄은 건너뛰고, 12자 이상인 첫 줄(소제목 같은 짧은 줄 건너뛰기)을 고른다
        text.enumerateLines { l, stop in
            let t = l.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return }
            seen += 1
            if seen == 1 && Korean.normalize(t.trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespaces))) == nt { return }
            if firstLine.isEmpty { firstLine = t }
            if t.count >= 12 { line = t; stop = true }
            if seen > 12 { stop = true }
        }
        if line.isEmpty { line = firstLine }
        if line.isEmpty { return "" }
        let chars = Array(line)
        var end = chars.count
        for i in 0..<chars.count where ".?!。".contains(chars[i]) && (i + 1 == chars.count || chars[i + 1] == " ") {
            end = i + 1; break
        }
        if end > 120 { return String(chars[0..<119]) + "…" }
        return String(chars[0..<end])
    }

    /// 키워드 후보 빈도 상위 60 (제목 단어 ×3).
    static func termFrequencies(_ r: DocRecord) -> [(String, Double)] {
        var tf: [String: Double] = [:]
        for t in Korean.keywordTokens(String(r.text.prefix(120_000))) { tf[t, default: 0] += 1 }
        for t in Korean.keywordTokens(r.title) { tf[t, default: 0] += 3 }
        return tf.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.prefix(60).map { ($0.key, $0.value) }
    }

    static func write(_ r: DocRecord, store: Store) throws {
        var keys = Korean.issueKeys(in: r.text)
        if r.kind == "jira", let own = r.id.components(separatedBy: ":jira:").last { keys.removeAll { $0 == own } }
        try store.upsert(r, summary: summary(r.text, title: r.title), issueKeys: keys, tf: termFrequencies(r))
    }

    struct Outcome { var changed = 0; var removed = 0; var failed = 0; var ids = Set<String>() }   // ids: 바뀐·지운 문서

    /// 폴더·볼트 색인. full이면 fingerprint와 상관없이 다시 읽는다.
    /// nested: 이 출처 안의 다른 출처 루트(상대 경로, §3.1). 색인할 때만 제외에 더한다. "" = 같은 경로의 먼저 추가된 출처가 있어 아무것도 색인하지 않는다.
    static func indexLocal(_ src: SourceConfig, store: Store, full: Bool, nested: [String] = [],
                           progress: (Int, Int, String) -> Void) throws -> Outcome {
        var o = Outcome()
        guard let path = src.path else { return o }
        let root = realPath(path)
        progress(0, 0, "scan")
        var scanned = try scan(root: root, kinds: includedKinds(src), exclude: excludedFolders(src) + nested.filter { !$0.isEmpty })   // 루트를 못 읽으면 여기서 던지고, 아무것도 지우지 않는다
        if nested.contains("") { scanned = ScanResult() }
        let entries = scanned.entries
        let known = try store.fingerprints(source: src.id)
        let present = Set(entries.map { src.id + ":" + $0.rel })
        let todo = entries.filter { full || known[src.id + ":" + $0.rel] != $0.fingerprint }
        // 읽지 못한 하위 폴더 아래 문서는 사라진 것으로 보지 않는다
        let shielded = scanned.failedDirs.map { src.id + ":" + ($0.isEmpty ? "" : $0 + "/") }
        let gone = known.keys.filter { id in !present.contains(id) && !shielded.contains(where: { id.hasPrefix($0) }) }
        o.failed += scanned.failedDirs.count
        if !gone.isEmpty { try store.writer.transaction { try store.delete(ids: gone) }; o.removed = gone.count; o.ids.formUnion(gone) }
        var done = 0
        progress(0, todo.count, "read")
        var i = 0
        while i < todo.count {
            let chunk = Array(todo[i..<min(i + batchSize, todo.count)])
            var results = [DocRecord?](repeating: nil, count: chunk.count)
            let lock = NSLock()
            // unzip을 부르는 형식(hwpx·docx·odt·doc)이 섞이면 동시 읽기를 4개로 제한
            let heavy = chunk.contains { ["hwpx", "docx", "odt", "doc"].contains(($0.rel as NSString).pathExtension.lowercased()) }
            let workers = min(chunk.count, heavy ? 4 : max(2, ProcessInfo.processInfo.activeProcessorCount))
            var next = 0
            DispatchQueue.concurrentPerform(iterations: workers) { _ in
              while true {
                lock.lock(); let k = next; next += 1; lock.unlock()
                if k >= chunk.count { break }
                let e = chunk[k]
                let rec = autoreleasepool { () -> DocRecord? in
                    guard let f = try? Plugins.extract(URL(fileURLWithPath: e.path)) else { return nil }
                    return record(e, source: src, file: f)
                }
                lock.lock(); results[k] = rec; lock.unlock()
              }
            }
            try store.writer.transaction {
                for r in results {
                    if let r = r { try write(r, store: store); o.changed += 1; o.ids.insert(r.id) }
                    else { o.failed += 1 }   // 읽지 못한 파일은 건너뛴다 (예전 내용이 있으면 그대로 둔다)
                }
            }
            i += chunk.count; done += chunk.count
            progress(done, todo.count, "read")
        }
        return o
    }

    /// 바뀐 경로들만 다시 읽기. 폴더 단위 변화면 증분 스캔으로 넘긴다.
    static func indexPaths(_ src: SourceConfig, paths: [String], rescan: Bool, store: Store, nested: [String] = []) throws -> Outcome {
        guard let p = src.path else { return Outcome() }
        let root = realPath(p)
        try checkRoot(root)          // 볼트가 빠졌거나 권한이 없으면 아무것도 지우지 않는다
        if nested.contains("") || rescan { return try indexLocal(src, store: store, full: false, nested: nested) { _, _, _ in } }
        // §3.1: 안쪽 출처 경로의 변화는 그 출처가 맡는다 — 여기서는 남은 옛 문서만 지우고, 전체 스캔으로 넘기지 않는다
        let exclude = excludedFolders(src) + nested
        let known = try store.fingerprints(source: src.id)
        var deletes: [String] = []
        var mine: [String] = []
        for path in Set(paths) {
            guard let rel = relativePath(path: path, root: root) else { continue }
            if !nested.isEmpty && isExcluded(rel: rel, nested) {
                if known[src.id + ":" + rel] != nil { deletes.append(src.id + ":" + rel) }
                continue
            }
            mine.append(path)
        }
        if mine.count > 200 { return try indexLocal(src, store: store, full: false, nested: nested) { _, _, _ in } }
        var o = Outcome()
        var upserts: [DocRecord] = []
        var needScan = false
        for path in mine {
            guard let rel = relativePath(path: path, root: root) else { continue }
            let id = src.id + ":" + rel
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            if exists && isDir.boolValue { needScan = true; continue }
            if !exists {
                if known[id] != nil { deletes.append(id) }
                else if known.keys.contains(where: { $0.hasPrefix(id + "/") }) { needScan = true }
                continue
            }
            guard let e = entry(path: path, root: root, kinds: includedKinds(src), exclude: exclude) else { if known[id] != nil { deletes.append(id) }; continue }
            if known[id] == e.fingerprint { continue }
            if let f = try? Plugins.extract(URL(fileURLWithPath: e.path)) { upserts.append(record(e, source: src, file: f)) }
            else { o.failed += 1 }
        }
        if needScan { return try indexLocal(src, store: store, full: false, nested: nested) { _, _, _ in } }
        if upserts.isEmpty && deletes.isEmpty { return o }
        try store.writer.transaction {
            try store.delete(ids: deletes)
            for r in upserts { try write(r, store: store) }
        }
        o.changed = upserts.count; o.removed = deletes.count
        o.ids.formUnion(deletes); o.ids.formUnion(upserts.map { $0.id })
        return o
    }

    /// 원격 동기화 결과 반영. keepIDs가 있으면 나머지는 지운다.
    static func applyRemote(_ src: SourceConfig, result: RemoteSyncResult, store: Store) throws -> Outcome {
        var o = Outcome()
        try store.writer.transaction {
            for var r in result.upserts {
                r.sourceId = src.id
                if !r.id.hasPrefix(src.id + ":") { r.id = src.id + ":" + r.id }
                try write(r, store: store); o.changed += 1
            }
            if let keep = result.keepIDs {
                let upIDs = Set(result.upserts.map { $0.id.hasPrefix(src.id + ":") ? $0.id : src.id + ":" + $0.id })
                let gone = try store.ids(source: src.id).filter { !keep.contains($0) && !upIDs.contains($0) }
                try store.delete(ids: gone); o.removed = gone.count
            }
        }
        return o
    }
}

// MARK: - v0.9 겹친 출처 (docs/V09.md §3.1) — 안쪽 출처가 이긴다

extension Indexer {
    /// 출처 루트(실제 경로·NFC, 끝 "/" 없음). 로컬 출처가 아니면 nil.
    static func sourceRoot(_ s: SourceConfig) -> String? {
        guard s.kind == .folder || s.kind == .obsidian, let p = s.path, !p.isEmpty else { return nil }
        var r = nfc(realPath(p))
        while r.count > 1 && r.hasSuffix("/") { r.removeLast() }
        return r
    }

    /// a가 b보다 먼저 추가됐나 (같은 경로 출처에서 이긴 쪽). 추가 시각 → 목록 순서.
    private static func earlier(_ a: SourceConfig, _ b: SourceConfig, _ all: [SourceConfig]) -> Bool {
        if a.addedAt != b.addedAt { return a.addedAt < b.addedAt }
        return (all.firstIndex { $0.id == a.id } ?? 0) < (all.firstIndex { $0.id == b.id } ?? 0)
    }

    /// src 안에 루트가 있는 다른 켜진 로컬 출처 → src 기준 상대 경로(NFC, 정렬). 색인할 때만 제외에 더한다(저장된 excludeFolders는 그대로).
    /// 같은 경로의 출처가 먼저 추가됐으면 [""] (이 출처는 아무것도 색인하지 않는다).
    static func nestedRels(_ src: SourceConfig, among all: [SourceConfig]) -> [String] {
        guard let root = sourceRoot(src) else { return [] }
        var out = Set<String>()
        for o in all where o.id != src.id && o.enabled {
            guard let r = sourceRoot(o) else { continue }
            if r == root {
                if earlier(o, src, all) { return [""] }
                continue
            }
            if r.hasPrefix(root + "/") { out.insert(String(r.dropFirst(root.count + 1))) }
        }
        // 안쪽의 안쪽은 바깥쪽 제외에 이미 들어간다
        let list = out.sorted()
        return list.filter { rel in !list.contains { $0 != rel && rel.hasPrefix($0 + "/") } }
    }

    /// src를 덮는 가장 가까운 켜진 로컬 출처 (같은 경로면 먼저 추가된 쪽). 없으면 nil.
    static func outerSource(_ src: SourceConfig, among all: [SourceConfig]) -> SourceConfig? {
        guard let root = sourceRoot(src) else { return nil }
        var best: (SourceConfig, Int)? = nil
        for o in all where o.id != src.id && o.enabled {
            guard let r = sourceRoot(o) else { continue }
            let covers = (r == root && earlier(o, src, all)) || root.hasPrefix(r + "/")
            if covers && r.count > (best?.1 ?? -1) { best = (o, r.count) }
        }
        return best?.0
    }

    /// src 안의 켜진 로컬 출처들 (안쪽의 안쪽 포함, 같은 경로의 나중 출처 포함).
    static func innerSources(_ src: SourceConfig, among all: [SourceConfig]) -> [SourceConfig] {
        guard let root = sourceRoot(src) else { return [] }
        return all.filter { o in
            guard o.id != src.id, o.enabled, let r = sourceRoot(o) else { return false }
            return r.hasPrefix(root + "/") || (r == root && earlier(src, o, all))
        }
    }
}

// MARK: - 파일 목록 (본문 추출 없이)

extension Indexer {
    /// 숨김·제외 이름 폴더·패키지를 뺀 모든 파일의 NFC 상대 경로 (형식·제외 폴더 설정과 무관).
    static func listFiles(root: String, limit: Int = 200_000) -> [String] {
        let rootN = nfc(root.hasSuffix("/") ? root : root + "/")
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let en = FileManager.default.enumerator(at: URL(fileURLWithPath: root, isDirectory: true), includingPropertiesForKeys: keys,
                                                      options: [.skipsPackageDescendants], errorHandler: { _, _ in true }) else { return [] }
        var out: [String] = []
        for case let url as URL in en {
            let name = url.lastPathComponent
            let v = try? url.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true {
                if isSkippedDirName(name) || v?.isPackage == true { en.skipDescendants() }
                continue
            }
            if name.hasPrefix(".") { continue }
            let p = nfc(url.path)
            if p.hasPrefix(rootN) { out.append(String(p.dropFirst(rootN.count))) }
            if out.count >= limit { break }
        }
        return out
    }
}

// MARK: - FSEvents

/// 소스 폴더 하나를 감시한다 (파일 단위 이벤트, 지연 1초). handler(paths, rescan)는 감시 큐에서 불린다.
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let handler: ([String], Bool) -> Void
    let root: String

    /// exclude: 감시하지 않을 절대 경로(안쪽 출처 루트, §3.1). FSEvents 한도로 앞 8개만.
    init?(root: String, queue: DispatchQueue, exclude: [String] = [], handler: @escaping ([String], Bool) -> Void) {
        self.root = root
        self.handler = handler
        var ctx = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        ctx.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, count, pathsPtr, flagsPtr, _ in
            guard let info = info else { return }
            let me = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let arr = unsafeBitCast(pathsPtr, to: NSArray.self)
            var paths: [String] = []
            var rescan = false
            for i in 0..<count {
                let f = flagsPtr[i]
                if f & UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped |
                              kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged) != 0 { rescan = true }
                if let p = arr[i] as? String { paths.append(p) }
            }
            me.handler(paths, rescan)
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes |
                           kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &ctx, [root] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else { return nil }
        stream = s
        if !exclude.isEmpty { _ = FSEventStreamSetExclusionPaths(s, Array(exclude.prefix(8)) as CFArray) }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }
}
