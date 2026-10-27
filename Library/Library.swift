import Foundation
import CryptoKit

// 엔진 진입점 (docs/CONNECT.md §3.8). 네이티브 셸(D)과 CLI가 이 클래스만 부른다.

/// 사용자에게 그대로 보여도 되는 한국어 한 문장 오류.
struct LibraryError: Error, LocalizedError, CustomStringConvertible {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
    var description: String { message }
}

private struct SourceState: Codable {
    var lastIndexed: Date?
    var cursor: Date?
    var jiraMeta: Int?            // v0.7: Jira meta 판. 연결기의 jiraMetaVersion보다 낮으면 Jira 이슈만 한 번 다시 받는다
}

private struct Runtime {
    var state = "idle"            // idle | indexing | syncing | error
    var progress: (done: Int, total: Int, phase: String)? = nil
    var error: String? = nil
    var failed = 0
    var notice: String? = nil     // 한 번 알릴 안내 (예: 옵시디언 볼트로 바꿈)
}

extension SourceKind {
    /// 원격 동기화로 가져오는 소스 (API 토큰 Atlassian, MCP).
    var isRemote: Bool { self == .atlassian || self == .mcp }
}

let vaultNotice = "옵시디언 볼트로 인식했어요. 노트(md)와 PDF만 색인해요 — 형식은 자료 설정에서 바꿀 수 있어요."

final class Library {
    let home: URL
    var onEvent: ((LibraryEvent) -> Void)?     // 항상 메인 큐에서 호출

    private let store: Store?
    private let queue = DispatchQueue(label: "synapse.library.index", qos: .utility)      // 쓰기 전용 직렬 큐
    private let watchQueue = DispatchQueue(label: "synapse.library.watch", qos: .utility)
    private let lock = NSLock()
    private let saveLock = NSLock()
    private var relateGeneration = 0          // 연결 재계산 디바운스 (색인 큐에서만 읽고 쓴다)
    private var pendingFullSync = Set<String>()
    private var migratedIDs = Set<String>()
    private let readOnly: Bool
    private var dataVersion: Int64 = -1
    private var sourcesMTime: Double = 0
    private let mentionCache = MentionCache()      // 색인 큐에서만
    private var pendingChanged = Set<String>()     // 디바운스 연결 계산을 기다리는 바뀐 문서 (색인 큐에서만)
    private var sources: [SourceConfig] = []
    private var states: [String: SourceState] = [:]
    private var runtime: [String: Runtime] = [:]
    private var docCounts: [String: Int] = [:]
    private var snapshot: Snapshot = .empty
    private var watchers: [String: FileWatcher] = [:]
    private var pendingPaths: [String: (paths: Set<String>, rescan: Bool)] = [:]
    private var remoteInFlight = Set<String>()
    private var lastProgress: [String: TimeInterval] = [:]
    private var timer: DispatchSourceTimer?
    private var started = false
    private let obsidianInstalled: Bool

    private var sourcesURL: URL { home.appendingPathComponent("sources.json") }
    private var stateURL: URL { home.appendingPathComponent("state.json") }

    convenience init(home: URL) {
        self.init(home: home, readOnlyStore: nil)
    }

    /// 색인·감시 없이 디스크 색인만 읽는다 (synapse-mcp). 앱이 꺼져 있어도 동작한다.
    static func openReadOnly(home: URL) throws -> Library {
        let store: Store
        do { store = try Store(readOnlyAt: home.appendingPathComponent("index.sqlite")) }
        catch { throw LibraryError("Synapse 색인을 열 수 없어요. 앱에서 자료를 먼저 연결해 주세요.") }
        return Library(home: home, readOnlyStore: store)
    }

    /// 읽기 전용: 색인(DB)이나 sources.json이 바뀌었으면 스냅숏을 다시 읽는다. 바뀌었으면 true.
    @discardableResult
    func refreshIfChanged() -> Bool {
        guard let store = store else { return false }
        return queue.sync {
            let v = store.dataVersion()
            let m = (try? FileManager.default.attributesOfItem(atPath: sourcesURL.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            if v == dataVersion && m == sourcesMTime { return false }
            dataVersion = v; sourcesMTime = m
            loadSourcesFile()
            rebuildSnapshot()
            return true
        }
    }

    private func loadSourcesFile() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: sourcesURL), let s = try? dec.decode([SourceConfig].self, from: d) {
            lock.lock(); sources = s; lock.unlock()
        }
    }

    private init(home: URL, readOnlyStore: Store?) {
        self.home = home
        readOnly = readOnlyStore != nil
        if let ro = readOnlyStore {
            store = ro
            obsidianInstalled = Views.obsidianInstalled()
            loadSourcesFile()
            dataVersion = ro.dataVersion()
            sourcesMTime = (try? FileManager.default.attributesOfItem(atPath: sourcesURL.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            queue.sync { self.rebuildSnapshot() }
            return
        }
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let dbURL = home.appendingPathComponent("index.sqlite")
        var st: Store? = nil
        do { st = try Store(url: dbURL) }
        catch let e as SQLiteError where e.isCorruption {
            // 손상된 색인만 지우고 새로 만든다 (원본 자료는 그대로). 잠김·권한 오류일 때는 지우지 않는다.
            for ext in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbURL.path + ext) }
            st = try? Store(url: dbURL)
        } catch {}
        store = st
        obsidianInstalled = Views.obsidianInstalled()
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: sourcesURL), let s = try? dec.decode([SourceConfig].self, from: d) { sources = s }
        if let d = try? Data(contentsOf: stateURL), let s = try? dec.decode([String: SourceState].self, from: d) { states = s }
        if st?.didReset ?? false {
            // 색인을 새로 만들었으면 원격 cursor를 버려 다음 동기화가 전체가 되게 한다
            for k in states.keys { states[k]?.cursor = nil; states[k]?.jiraMeta = nil }
            saveStates()
        }
        // 한 번만: .obsidian이 있는 folder 소스는 볼트로 바꾼다 (기본 형식 md·pdf → 다음 색인 때 나머지는 빠진다)
        for k in sources.indices where sources[k].kind == .folder {
            if let p = sources[k].path, FileManager.default.fileExists(atPath: p + "/.obsidian") {
                sources[k].kind = .obsidian
                migratedIDs.insert(sources[k].id)
                var rt = runtime[sources[k].id] ?? Runtime(); rt.notice = vaultNotice; runtime[sources[k].id] = rt
            }
        }
        if !migratedIDs.isEmpty { saveSources() }
        queue.sync { self.rebuildSnapshot() }
    }

    deinit { stop() }

    // MARK: 수명

    func start() {
        if readOnly { return }
        lock.lock(); let already = started; started = true; let srcs = sources; let migrated = !migratedIDs.isEmpty; lock.unlock()
        if already { return }
        if migrated { emit(.changed(reason: "source-migrated")) }
        for s in srcs where s.enabled && !s.kind.isRemote { startWatcher(s) }
        queue.async {
            for s in srcs where s.enabled && !s.kind.isRemote { self.indexLocalOnQueue(s, full: false) }
            self.relateOnQueue()
            self.emit(.changed(reason: "indexed"))
        }
        for s in srcs where s.enabled && s.kind.isRemote { syncRemote(s, full: false, relate: true, completion: nil) }
        let t = DispatchSource.makeTimerSource(queue: watchQueue)
        t.schedule(deadline: .now() + 1800, repeating: 1800)
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            for s in self.currentSources() where s.enabled && s.kind.isRemote { self.syncRemote(s, full: false, relate: true, completion: nil) }
        }
        t.resume()
        lock.lock(); timer = t; lock.unlock()
    }

    func stop() {
        lock.lock()
        let ws = watchers; watchers = [:]
        let t = timer; timer = nil
        started = false
        lock.unlock()
        watchQueue.async { ws.values.forEach { $0.stop() } }   // 감시 큐에서 멈춰 진행 중인 콜백과 겹치지 않게
        t?.cancel()
    }

    /// CLI용: 모든 소스를 동기로 색인 (원격 포함).
    func indexAllAndWait() {
        if readOnly { return }
        let srcs = currentSources().filter { $0.enabled }
        queue.sync { for s in srcs where !s.kind.isRemote { self.indexLocalOnQueue(s, full: false) } }
        let group = DispatchGroup()
        for s in srcs where s.kind.isRemote {
            group.enter()
            syncRemote(s, full: false, relate: false) { group.leave() }
        }
        group.wait()
        queue.sync { self.relateOnQueue() }
        emit(.changed(reason: "indexed"))
    }

    // MARK: 출처

    func statusJSON() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let list = sources.map { statusEntryLocked($0) }
        let indexing = runtime.values.contains { $0.state == "indexing" || $0.state == "syncing" }
        return ["sources": list, "docCount": snapshot.docs.count, "indexing": indexing]
    }

    private func statusEntryLocked(_ s: SourceConfig) -> [String: Any] {
        let rt = runtime[s.id] ?? Runtime()
        var detail = ""
        switch s.kind {
        case .folder, .obsidian: detail = ((s.path ?? "") as NSString).abbreviatingWithTildeInPath
        case .mcp:
            detail = s.mcpSite ?? URL(string: s.mcpURL ?? "")?.host ?? (s.mcpURL ?? "")
        case .atlassian:
            let host = URL(string: s.site ?? "")?.host ?? (s.site ?? "")
            detail = [host, s.email ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        let progress: Any = rt.progress.map { ["done": $0.done, "total": $0.total, "phase": $0.phase] as [String: Any] } ?? NSNull()
        // v0.9 §3.1: 겹친 출처 — 바깥 출처 이름(여기서 색인해요)과 안쪽 출처 이름들(그 출처에서 색인해요). 켜진 로컬 출처끼리만
        let local = !s.kind.isRemote && s.enabled
        let outer = local ? Indexer.outerSource(s, among: sources) : nil
        let inner = local ? Indexer.innerSources(s, among: sources).map { $0.name } : []
        return ["id": s.id, "kind": s.kind.rawValue, "name": s.name, "detail": detail, "enabled": s.enabled,
                "state": rt.state, "docCount": docCounts[s.id] ?? 0,
                "lastIndexed": states[s.id]?.lastIndexed.map { Views.iso($0.timeIntervalSince1970) } ?? NSNull(),
                "progress": progress, "error": rt.error ?? NSNull(), "failed": rt.failed, "notice": rt.notice ?? NSNull(),
                "nestedIn": outer.map { $0.name as Any } ?? NSNull(), "nests": inner]
    }

    func addFolder(path: String, obsidian: Bool) throws -> [String: Any] {
        if readOnly { throw LibraryError("읽기 전용으로 열려 있어요.") }
        var abs = (path as NSString).expandingTildeInPath
        if !abs.hasPrefix("/") { abs = FileManager.default.currentDirectoryPath + "/" + abs }
        let p = (abs as NSString).standardizingPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else {
            throw LibraryError("폴더를 찾을 수 없어요.")
        }
        let real = Indexer.realPath(p)
        let before = nestMap()
        lock.lock()
        if sources.contains(where: { $0.path.map(Indexer.realPath) == real }) { lock.unlock(); throw LibraryError("이미 연결된 폴더예요.") }
        let name = (p as NSString).lastPathComponent
        // .obsidian 폴더가 있으면 볼트로 인식 (요청이 folder여도)
        let isVault = FileManager.default.fileExists(atPath: p + "/.obsidian")
        let src = SourceConfig(id: UUID().uuidString, kind: obsidian || isVault ? .obsidian : .folder, name: name.isEmpty ? p : name,
                               path: p, site: nil, email: nil, confluenceSpaces: nil, jiraJQL: nil, enabled: true, addedAt: Date())
        sources.append(src)
        var rt = Runtime()
        if isVault && !obsidian { rt.notice = vaultNotice }
        runtime[src.id] = rt
        let isStarted = started
        lock.unlock()
        saveSources()
        let outer = nestChanged(before)
        if isStarted {
            startWatcher(src)
            for o in outer { startWatcher(o) }
            queue.async {
                self.indexLocalOnQueue(src, full: false)
                for o in outer { self.indexLocalOnQueue(o, full: false) }   // §3.1: 바깥 출처에서 이 경로의 사본을 뺀다
                self.relateOnQueue()
                self.emit(.changed(reason: "source-added"))
            }
        } else {
            queue.sync { self.rebuildSnapshot() }
        }
        lock.lock(); defer { lock.unlock() }
        return statusEntryLocked(src)
    }

    func addAtlassian(site: String, email: String, token: String,
                      spaces: [String]?, jql: String?) async throws -> [String: Any] {
        var s = site.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s), let host = url.host, !host.isEmpty else { throw LibraryError("사이트 주소를 확인해 주세요.") }
        let mail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let tok = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mail.isEmpty, !tok.isEmpty else { throw LibraryError("이메일과 토큰을 모두 입력해 주세요.") }
        if currentSources().contains(where: { $0.kind == .atlassian && $0.site?.lowercased() == s.lowercased() && $0.email?.lowercased() == mail.lowercased() }) {
            throw LibraryError("이미 연결된 사이트예요.")
        }
        guard let make = Plugins.makeRemote else { throw LibraryError("이 빌드에서는 Atlassian 연결을 쓸 수 없어요.") }
        let cleanSpaces = spaces?.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let cleanJQL = jql?.trimmingCharacters(in: .whitespacesAndNewlines)
        let src = SourceConfig(id: UUID().uuidString, kind: .atlassian, name: host, path: nil, site: s, email: mail,
                               confluenceSpaces: (cleanSpaces?.isEmpty ?? true) ? nil : cleanSpaces,
                               jiraJQL: (cleanJQL?.isEmpty ?? true) ? nil : cleanJQL, enabled: true, addedAt: Date())
        _ = make
        return try await addRemote(config: src, secret: tok)    // v0.4: 공통 경로 (secret 저장 → verify → 실패면 삭제)
    }

    /// 소스 추가 (잠금 안). 시작된 상태인지 돌려준다.
    private func appendSource(_ src: SourceConfig) -> Bool {
        lock.lock(); defer { lock.unlock() }
        sources.append(src)
        runtime[src.id] = Runtime()
        return started
    }

    private func statusEntry(_ src: SourceConfig) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return statusEntryLocked(src)
    }

    func removeSource(id: String) {
        if readOnly { return }
        let before = nestMap()
        lock.lock()
        guard let src = sources.first(where: { $0.id == id }) else { lock.unlock(); return }
        sources.removeAll { $0.id == id }
        states[id] = nil; runtime[id] = nil
        let w = watchers.removeValue(forKey: id)
        lock.unlock()
        if let w = w { watchQueue.async { w.stop() } }
        if src.kind.isRemote { Plugins.secrets.removeSecret(for: id) }
        saveSources(); saveStates()
        let outer = isStartedNow() ? nestChanged(before) : []
        for o in outer { startWatcher(o) }
        queue.async {
            if let store = self.store, let ids = try? store.ids(source: id) {
                try? store.writer.transaction { try store.delete(ids: ids) }
            }
            for o in outer { self.indexLocalOnQueue(o, full: false) }   // §3.1: 안쪽 출처가 빠지면 바깥이 다시 읽는다
            self.relateOnQueue()
            self.emit(.changed(reason: "source-removed"))
        }
    }

    func setSourceEnabled(id: String, enabled: Bool) {
        if readOnly { return }
        let before = nestMap()
        lock.lock()
        guard let k = sources.firstIndex(where: { $0.id == id }) else { lock.unlock(); return }
        sources[k].enabled = enabled
        let src = sources[k]
        let isStarted = started
        let w = enabled ? nil : watchers.removeValue(forKey: id)
        lock.unlock()
        if let w = w { watchQueue.async { w.stop() } }
        saveSources()
        let outer = isStarted ? nestChanged(before) : []   // §3.1: 겹침이 바뀐 바깥 출처는 다시 스캔한다
        for o in outer { startWatcher(o) }
        if enabled && isStarted {
            if src.kind.isRemote { syncRemote(src, full: false, relate: true, completion: nil) }
            else {
                startWatcher(src)
                queue.async {
                    self.indexLocalOnQueue(src, full: false)
                    for o in outer { self.indexLocalOnQueue(o, full: false) }
                    self.relateOnQueue(); self.emit(.changed(reason: "source-enabled"))
                }
                return
            }
        }
        queue.async {
            for o in outer { self.indexLocalOnQueue(o, full: false) }
            self.relateOnQueue(); self.emit(.changed(reason: enabled ? "source-enabled" : "source-disabled"))
        }
    }

    /// nil = 전체. 로컬은 fingerprint와 상관없이 다시 읽고, 원격은 전체 동기화.
    func reindex(id: String?) {
        if readOnly { return }
        let srcs = currentSources().filter { $0.enabled && (id == nil || $0.id == id) }
        let locals = srcs.filter { !$0.kind.isRemote }
        if !locals.isEmpty {
            queue.async {
                for s in locals { self.indexLocalOnQueue(s, full: true) }
                self.relateOnQueue()
                self.emit(.changed(reason: "reindexed"))
            }
        }
        for s in srcs where s.kind.isRemote { syncRemote(s, full: true, relate: true, completion: nil) }
    }

    // MARK: 조회 (스레드 안전)

    private func currentSnapshot() -> Snapshot { lock.lock(); defer { lock.unlock() }; return snapshot }

    func viewJSON(_ params: [String: Any]) -> [String: Any] {
        guard let store = store else {
            return ["mode": "global", "sections": [Any](), "nodes": [Any](), "links": [Any](), "centerId": NSNull(),
                    "chips": [Any](), "chipLabel": "", "summary": "문서 0 · 연결 0", "legend": [Any](), "hidden": 0,
                    "total": 0, "empty": NSNull()]
        }
        return Views.view(params, snap: currentSnapshot(), store: store)
    }

    func documentJSON(id: String) -> [String: Any]? {
        guard let store = store else { return nil }
        let snap = currentSnapshot()
        guard var doc = Views.document(id: id, snap: snap, store: store) else { return nil }
        Notes.decorate(&doc, id: id, snap: snap)     // v0.6: 마크다운 원문·링크 해석 (Library/Notes.swift)
        // v0.6: 우클릭 메뉴용 — 로컬은 절대 경로(filePath), 원격은 https 주소(url)
        if let i = snap.index[id] {
            let loc = snap.docs[i].m.location
            var inner = (doc["doc"] as? [String: Any]) ?? [:]
            if loc.hasPrefix("http://") || loc.hasPrefix("https://") { inner["url"] = loc }
            else if loc.hasPrefix("/") { inner["filePath"] = loc }
            doc["doc"] = inner
        }
        return doc
    }

    /// v0.6 P0 개발용: 색인의 unresolved에 번호 접두·Jira 키·정규화 제목 규칙을 돌려 how별 해결 수·남은 수·견본을 센다 (CLI debug unresolved-stats).
    func unresolvedStatsJSON() -> [String: Any] {
        let snap = currentSnapshot()
        let index = Notes.linkIndex(snap)
        var total = 0, remote = 0, already = 0, remain = 0, ambiguous = 0, numberLike = 0
        var byHow: [String: Int] = [:]
        var docsAffected = Set<String>(), docsWithUnresolved = Set<String>()
        var fixedSamples: [[String: String]] = [], remainSamples: [[String: String]] = []
        for (c, doc) in snap.docs.enumerated() where !snap.unresolved[c].isEmpty {
            let d = doc.m
            docsWithUnresolved.insert(d.id)
            for t in snap.unresolved[c] {
                total += 1
                if d.kind == "confluence" || d.kind == "jira" { remote += 1; continue }
                if index.resolve(t, from: d) != nil { already += 1; continue }
                if let m = index.resolveMore(t, from: d) {
                    byHow[m.how, default: 0] += 1; docsAffected.insert(d.id)
                    if fixedSamples.count < 10 { fixedSamples.append(["from": d.title, "target": t, "how": m.how, "to": snap.docs[m.doc].m.title]) }
                } else {
                    remain += 1
                    if Notes.numberPrefix(of: t) != nil { numberLike += 1 }
                    if index.isAmbiguousPrefix(t, from: d) { ambiguous += 1 }
                    if remainSamples.count < 10 && (remain % 97 == 1 || remainSamples.count < 3) { remainSamples.append(["from": d.title, "target": t]) }
                }
            }
        }
        let fixed = byHow.values.reduce(0, +)
        return ["unresolved": total, "fixed": fixed, "byHow": byHow, "remaining": remain, "remainingNumberLike": numberLike, "remainingAmbiguous": ambiguous, "alreadyResolvable": already, "remoteSkipped": remote,
                "docsWithUnresolved": docsWithUnresolved.count, "docsAffected": docsAffected.count,
                "fixedSamples": fixedSamples, "remainingSamples": remainSamples]
    }

    func openTarget(id: String) -> (location: String, sourceKind: SourceKind, isFile: Bool)? {
        let s = currentSnapshot()
        guard let i = s.index[id] else { return nil }
        let d = s.docs[i].m
        let isFile = !(d.location.hasPrefix("http://") || d.location.hasPrefix("https://"))
        return (d.location, s.sources[d.sourceId]?.kind ?? .folder, isFile)
    }

    // MARK: 내부

    private func currentSources() -> [SourceConfig] { lock.lock(); defer { lock.unlock() }; return sources }
    /// v0.5 사서(Brain)용: 지금 출처 설정 목록.
    func sourceConfigs() -> [SourceConfig] { currentSources() }

    /// v0.8 (E3, JiraApply): 원격 출처 하나를 곧(3초 뒤) 증분 동기화한다 — Jira에 반영한 변경이 화면에 다시 들어오게.
    /// 그때 그 출처가 이미 동기화 중이면(반영 전에 시작해 변경을 못 볼 수 있다) 끝나기를 몇 번 더 기다렸다가 한다.
    /// 읽기 전용(synapse-mcp)이거나 꺼진·로컬 출처면 하지 않는다.
    func syncRemoteSoon(id: String) {
        if readOnly { return }
        func attempt(_ n: Int) {
            self.watchQueue.asyncAfter(deadline: .now() + (n == 0 ? 3 : 5)) { [weak self] in
                guard let self = self,
                      let s = self.currentSources().first(where: { $0.id == id && $0.enabled && $0.kind.isRemote }) else { return }
                self.lock.lock(); let busy = self.remoteInFlight.contains(id); self.lock.unlock()
                if busy { if n < 12 { attempt(n + 1) }; return }
                self.syncRemote(s, full: false, relate: true, completion: nil)
            }
        }
        attempt(0)
    }

    /// 저장은 saveLock 안에서 "그 순간의 최신 값"을 읽어 쓴다 — 늦게 끝난 저장이 옛 값을 덮어쓰지 않는다.
    private func saveSources() {
        saveLock.lock(); defer { saveLock.unlock() }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(currentSources()) { try? d.write(to: sourcesURL, options: .atomic) }
    }

    private func saveStates() {
        saveLock.lock(); defer { saveLock.unlock() }
        lock.lock(); let st = states; lock.unlock()
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(st) { try? d.write(to: stateURL, options: .atomic) }
    }

    private func emit(_ e: LibraryEvent) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(e) }
    }

    private func setRuntime(_ id: String, _ f: (inout Runtime) -> Void) {
        lock.lock(); var r = runtime[id] ?? Runtime(); f(&r); runtime[id] = r; lock.unlock()
    }

    /// 진행 이벤트: 200ms에 한 번 이하 (끝은 항상).
    private func progress(_ id: String, _ done: Int, _ total: Int, _ phase: String) {
        let now = Date().timeIntervalSince1970
        lock.lock()
        var r = runtime[id] ?? Runtime(); r.progress = (done, total, phase); runtime[id] = r
        let last = lastProgress[id] ?? 0
        let fire = now - last >= 0.2 || (total > 0 && done >= total)
        if fire { lastProgress[id] = now }
        lock.unlock()
        if fire { emit(.progress(sourceId: id, done: done, total: total, phase: phase)) }
    }

    static func message(for error: Error, fallback: String) -> String {
        if let e = error as? LibraryError { return e.message }
        if let d = (error as? LocalizedError)?.errorDescription, !d.isEmpty { return d }
        return fallback
    }

    private func startWatcher(_ s: SourceConfig) {
        guard let p = s.path else { return }
        let root = Indexer.realPath(p)
        let id = s.id
        // v0.9 §3.1: 안쪽 출처 루트는 그 출처가 감시한다
        let skip = Indexer.nestedRels(s, among: currentSources()).filter { !$0.isEmpty }.map { root + "/" + $0 }
        let w = FileWatcher(root: root, queue: watchQueue, exclude: skip) { [weak self] paths, rescan in self?.fileEvents(id, paths, rescan) }
        lock.lock(); let old = watchers[id]; watchers[id] = w; lock.unlock()
        if let old = old { watchQueue.async { old.stop() } }
    }

    /// 감시 큐: 바뀐 경로를 모아 두고 색인 큐에서 한 번에 처리한다.
    private func fileEvents(_ id: String, _ paths: [String], _ rescan: Bool) {
        lock.lock()
        let first = pendingPaths[id] == nil
        var e = pendingPaths[id] ?? ([], false)
        e.paths.formUnion(paths); e.rescan = e.rescan || rescan
        pendingPaths[id] = e
        lock.unlock()
        guard first else { return }
        queue.async {
            self.lock.lock()
            let job = self.pendingPaths.removeValue(forKey: id)
            let src = self.sources.first { $0.id == id && $0.enabled }
            self.lock.unlock()
            guard let job = job, let src = src, let store = self.store else { return }
            do {
                let o = try Indexer.indexPaths(src, paths: Array(job.paths), rescan: job.rescan, store: store, nested: self.nested(src))
                self.setRuntime(src.id) { if $0.state == "error" { $0.state = "idle"; $0.error = nil } }
                if o.changed + o.removed > 0 {
                    self.pendingChanged.formUnion(o.ids)
                    self.markIndexed(src.id)
                    // 본문·검색은 바로 반영하고, 연결 재계산은 조용해진 뒤 한 번만
                    self.rebuildSnapshot()
                    self.emit(.changed(reason: "files"))
                    self.scheduleRelate()
                }
            } catch {
                self.fail(src.id, Library.message(for: error, fallback: "폴더를 읽지 못했어요."))
            }
        }
    }

    // MARK: v0.9 겹친 출처 (§3.1)

    /// 이 출처가 색인하지 않을 안쪽 출처 경로 (지금 출처 목록 기준).
    private func nested(_ s: SourceConfig) -> [String] { Indexer.nestedRels(s, among: currentSources()) }

    /// 켜진 로컬 출처마다 안쪽 출처 경로.
    private func nestMap() -> [String: [String]] {
        let all = currentSources()
        var m: [String: [String]] = [:]
        for s in all where s.enabled && !s.kind.isRemote { m[s.id] = Indexer.nestedRels(s, among: all) }
        return m
    }

    /// before 뒤로 안쪽 출처가 바뀐(켜진 로컬) 출처들 — 다시 스캔·감시를 새로 할 것.
    private func nestChanged(_ before: [String: [String]]) -> [SourceConfig] {
        let now = nestMap()
        return currentSources().filter { s in
            guard let cur = now[s.id], let old = before[s.id] else { return false }   // 새로 켜지거나 추가된 출처는 따로 색인한다
            return cur != old
        }
    }

    private func isStartedNow() -> Bool { lock.lock(); defer { lock.unlock() }; return started }

    private func markIndexed(_ id: String) {
        lock.lock(); var st = states[id] ?? SourceState(); st.lastIndexed = Date(); states[id] = st; lock.unlock()
        saveStates()
    }

    private func fail(_ id: String, _ msg: String) {
        setRuntime(id) { $0.state = "error"; $0.error = msg; $0.progress = nil }
        emit(.sourceError(sourceId: id, message: msg))
    }

    /// 색인 큐에서만.
    private func indexLocalOnQueue(_ s: SourceConfig, full: Bool) {
        guard let store = store else { return }
        setRuntime(s.id) { $0.state = "indexing"; $0.error = nil }
        do {
            let o = try Indexer.indexLocal(s, store: store, full: full, nested: nested(s)) { done, total, phase in self.progress(s.id, done, total, phase) }
            setRuntime(s.id) { $0.state = "idle"; $0.progress = nil; $0.failed = o.failed }
            markIndexed(s.id)
        } catch {
            fail(s.id, Library.message(for: error, fallback: "폴더를 읽지 못했어요."))
        }
    }

    /// 원격 동기화: 네트워크는 Task에서, 반영은 색인 큐에서. cursor는 커밋 뒤에만 저장한다.
    private func syncRemote(_ s: SourceConfig, full: Bool, relate: Bool, completion: (() -> Void)?) {
        lock.lock()
        if remoteInFlight.contains(s.id) {
            if full { pendingFullSync.insert(s.id) }   // 진행 중인 증분이 끝나면 전체 동기화를 이어서 한다
            lock.unlock(); completion?(); return
        }
        remoteInFlight.insert(s.id)
        // 색인에 이 소스 문서가 하나도 없으면(색인 재생성 등) cursor를 무시하고 전체 동기화
        let since = full || (docCounts[s.id] ?? 0) == 0 ? nil : states[s.id]?.cursor
        // v0.7: 증분 동기화인데 Jira meta 판이 낮으면(업그레이드 직후) 이번에는 Jira 이슈만 전체로 다시 받는다.
        let jiraOnlyCursor: Date? = (since != nil && (states[s.id]?.jiraMeta ?? 0) < AtlassianConnector.jiraMetaVersion) ? since : nil
        lock.unlock()
        let finish = { [weak self] in
            guard let self = self else { completion?(); return }
            self.lock.lock()
            self.remoteInFlight.remove(s.id)
            let again = self.pendingFullSync.remove(s.id) != nil
            self.lock.unlock()
            completion?()
            if again, let cur = self.currentSources().first(where: { $0.id == s.id && $0.enabled }) {
                self.syncRemote(cur, full: true, relate: true, completion: nil)
            }
        }
        guard let make = Plugins.makeRemote else { fail(s.id, "이 빌드에서는 Atlassian 연결을 쓸 수 없어요."); finish(); return }
        setRuntime(s.id) { $0.state = "syncing"; $0.error = nil }
        progress(s.id, 0, 0, "sync")
        Task.detached { [weak self] in
            // 키체인 읽기는 메인 스레드가 아닌 여기서
            guard let token = Plugins.secrets.secret(for: s.id) else {
                self?.fail(s.id, "토큰을 찾을 수 없어요. 연결을 다시 추가해 주세요."); finish(); return
            }
            let connector = make(s, token)
            do {
                var jiraOnly = false
                let result: RemoteSyncResult
                if let cur = jiraOnlyCursor, let refetch = connector as? JiraRefetching {
                    jiraOnly = true
                    result = try await refetch.syncJiraOnly(cursor: cur) { done, total in self?.progress(s.id, done, total ?? 0, "sync") }
                } else {
                    result = try await connector.sync(since: since) { done, total in self?.progress(s.id, done, total ?? 0, "sync") }
                }
                guard let self = self else { finish(); return }
                self.queue.async {
                    guard self.currentSources().contains(where: { $0.id == s.id }), let store = self.store else { finish(); return }
                    do {
                        _ = try Indexer.applyRemote(s, result: result, store: store)
                        self.lock.lock()
                        var st = self.states[s.id] ?? SourceState(); st.cursor = result.cursor; st.lastIndexed = Date(); st.jiraMeta = AtlassianConnector.jiraMetaVersion; self.states[s.id] = st
                        self.lock.unlock()
                        self.saveStates()
                        self.setRuntime(s.id) { $0.state = "idle"; $0.progress = nil }
                        if relate { self.relateOnQueue(); self.emit(.changed(reason: "synced")) }
                    } catch {
                        self.fail(s.id, "받은 자료를 저장하지 못했어요.")
                        finish(); return
                    }
                    finish()
                    // Jira만 다시 받았다면 바로 이어서 일반 증분 동기화(Confluence 변경분)를 한다
                    if jiraOnly, let cur = self.currentSources().first(where: { $0.id == s.id && $0.enabled }) {
                        self.syncRemote(cur, full: false, relate: relate, completion: nil)
                    }
                }
            } catch {
                self?.fail(s.id, Library.message(for: error, fallback: "Atlassian과 동기화하지 못했어요."))
                finish()
            }
        }
    }

    /// 색인 큐에서만: 연결 다시 계산 → 스냅숏 교체. 켜진 소스만 계산한다.
    /// incremental이면 지난 계산 뒤 바뀐 문서만 다시 언급 확인한다 (그 밖에는 전체).
    private func relateOnQueue(incremental: Bool = false) {
        guard let store = store else { return }
        relateGeneration += 1     // 예약된 디바운스 계산은 취소
        let enabled = Set(currentSources().filter { $0.enabled }.map { $0.id })
        let changed: Set<String>? = incremental ? pendingChanged : nil
        pendingChanged = []
        var roots: [String: String] = [:]
        for src in currentSources() where src.enabled && !src.kind.isRemote { if let p = src.path { roots[src.id] = Indexer.realPath(p) } }
        if let g = try? Relate.compute(store: store, enabled: enabled, mentions: mentionCache, changed: changed, roots: roots) {
            try? store.replaceGraph(g)
            store.setMetaValue("link_rules", Store.linkRulesVersion)     // v0.7 F: links 표를 만든 해석 규칙의 판
        }
        rebuildSnapshot()
    }

    /// 색인 큐에서만: 1.5초 동안 변화가 없으면 연결을 다시 계산한다 (동시에 두 번 돌지 않는다 — 직렬 큐).
    private func scheduleRelate() {
        relateGeneration += 1
        let gen = relateGeneration
        queue.asyncAfter(deadline: .now() + 1.5) {
            guard gen == self.relateGeneration else { return }
            self.relateOnQueue(incremental: true)
            self.emit(.changed(reason: "related"))
        }
    }

    private func rebuildSnapshot() {
        guard let store = store else { return }
        let metas = (try? store.metas()) ?? []
        let graph = (try? store.loadGraph()) ?? Store.GraphRows()
        var counts: [String: Int] = [:]
        for m in metas { counts[m.sourceId, default: 0] += 1 }
        let snap = Snapshot(metas: metas, graph: graph, sources: currentSources(), obsidianInstalled: obsidianInstalled)
        lock.lock(); snapshot = snap; docCounts = counts; lock.unlock()
    }
}
// MARK: - v0.4: 원격 추가·형식/제외 설정

extension Library {
    /// 원격 소스(kind atlassian·mcp) 추가: secret 저장 → verify → 실패면 secret 삭제·오류, 성공이면 추가·전체 동기화.
    func addRemote(config: SourceConfig, secret: String) async throws -> [String: Any] {
        if readOnly { throw LibraryError("읽기 전용으로 열려 있어요.") }
        guard config.kind.isRemote else { throw LibraryError("원격 자료만 이 방법으로 추가할 수 있어요.") }
        var src = config
        if src.id.isEmpty { src.id = UUID().uuidString }
        let existing = currentSources()
        if existing.contains(where: { $0.id == src.id }) { throw LibraryError("이미 연결된 자료예요.") }
        if existing.contains(where: { $0.kind == src.kind && $0.site?.lowercased() == src.site?.lowercased() && $0.email?.lowercased() == src.email?.lowercased()
                                   && $0.mcpURL == src.mcpURL && $0.mcpSite?.lowercased() == src.mcpSite?.lowercased() }) {
            throw LibraryError("이미 연결된 사이트예요.")
        }
        guard let make = Plugins.makeRemote else { throw LibraryError("이 빌드에서는 원격 자료를 연결할 수 없어요.") }
        do { try Plugins.secrets.setSecret(secret, for: src.id) }
        catch { throw LibraryError("로그인 정보를 키체인에 저장하지 못했어요.") }
        do { _ = try await make(src, secret).verify() }
        catch {
            Plugins.secrets.removeSecret(for: src.id)
            throw LibraryError(Library.message(for: error, fallback: "연결하지 못했어요. 다시 로그인해 주세요."))
        }
        let isStarted = appendSource(src)
        saveSources()
        if isStarted { syncRemote(src, full: true, relate: true, completion: nil) }
        return statusEntry(src)
    }

    /// CLI·시험용: 현재 소스 설정.
    func sourceConfigForCLI(id: String) -> SourceConfig? { currentSources().first { $0.id == id } }

    /// 파일 목록만 훑어 형식별·폴더별 개수 (본문 추출 없음). folders: 최상위 + 문서 많은 2단계, 최대 40개.
    func sourceDetailsJSON(id: String) -> [String: Any] {
        guard let src = currentSources().first(where: { $0.id == id }), !src.kind.isRemote, let p = src.path else {
            return ["kinds": [Any](), "folders": [Any]()]
        }
        let files = Indexer.listFiles(root: Indexer.realPath(p))
        let supported = Plugins.supportedExtensions
        let included = Indexer.includedKinds(src)
        let excluded = Indexer.excludedFolders(src)
        // v0.9 §3.1: 안쪽 출처 경로는 그 출처가 색인한다 — 여기서는 개수에서 빼고 "nested"로 표시한다(제외로 보이고 바꿀 수 없음)
        let nestedList = Indexer.nestedRels(src, among: currentSources()).filter { !$0.isEmpty }
        var nestedCount: [String: Int] = [:]
        var kindCount: [String: Int] = [:], top: [String: Int] = [:], second: [String: Int] = [:]
        for rel in files {
            let ext = (rel as NSString).pathExtension.lowercased()
            guard supported.contains(ext) else { continue }
            if let n = nestedList.first(where: { rel.hasPrefix($0 + "/") }) { nestedCount[n, default: 0] += 1; continue }
            kindCount[ext, default: 0] += 1
            let comps = rel.split(separator: "/").map(String.init)
            if comps.count >= 2 { top[comps[0], default: 0] += 1 }
            if comps.count >= 3 { second[comps[0] + "/" + comps[1], default: 0] += 1 }
        }
        let kinds = kindCount.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .map { [$0.key, $0.value, included.contains($0.key)] as [Any] }
        var chosen = top.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.prefix(40).map { $0.key }
        let big = Set(chosen.filter { (top[$0] ?? 0) >= 50 })
        for (k, v) in second.sorted(by: { $0.value > $1.value }) where chosen.count < 40 && v >= 20 {
            if let parent = k.split(separator: "/").first, big.contains(String(parent)) { chosen.append(k) }
        }
        for e in excluded where !chosen.contains(e) { chosen.append(e) }
        chosen.removeAll { nestedList.contains($0) }
        var folders = chosen.sorted().map { f -> [Any] in
            let n = f.contains("/") ? (second[f] ?? files.filter { $0.hasPrefix(f + "/") }.count) : (top[f] ?? 0)
            return [f, n, Indexer.isExcluded(rel: f, excluded)]
        }
        folders += nestedList.map { [$0, nestedCount[$0] ?? 0, true, "nested"] as [Any] }
        folders.sort { ($0[0] as? String ?? "") < ($1[0] as? String ?? "") }
        return ["kinds": kinds, "folders": folders]
    }

    /// 형식·제외 폴더 갱신 → 그 소스 다시 스캔(빠진 문서는 색인에서 삭제). 갱신된 status 원소.
    func updateSource(id: String, includeKinds: [String]?, excludeFolders: [String]?) throws -> [String: Any] {
        if readOnly { throw LibraryError("읽기 전용으로 열려 있어요.") }
        let kinds = includeKinds.map { Array(Set($0.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ")) })
                                              .intersection(Plugins.supportedExtensions)).sorted() }
        if let k = kinds, k.isEmpty { throw LibraryError("색인할 형식을 하나 이상 골라 주세요.") }
        var folders = excludeFolders.map { $0.map { Indexer.nfc($0).trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) }.filter { !$0.isEmpty } }
        // v0.9 §3.1: 화면이 "nested" 줄을 제외 목록에 되돌려 보내도 저장하지 않는다(색인할 때만 더하는 값)
        if let cur = currentSources().first(where: { $0.id == id }) {
            let nest = Set(Indexer.nestedRels(cur, among: currentSources()))
            let saved = Set(Indexer.excludedFolders(cur))
            folders = folders?.filter { !nest.contains($0) || saved.contains($0) }
        }
        lock.lock()
        guard let k = sources.firstIndex(where: { $0.id == id }) else { lock.unlock(); throw LibraryError("자료를 찾을 수 없어요.") }
        guard !sources[k].kind.isRemote else { lock.unlock(); throw LibraryError("원격 자료는 형식을 바꿀 수 없어요.") }
        sources[k].includeKinds = kinds
        sources[k].excludeFolders = (folders?.isEmpty ?? true) ? nil : folders
        let src = sources[k]
        lock.unlock()
        saveSources()
        queue.async {
            if src.enabled { self.indexLocalOnQueue(src, full: false) }
            self.relateOnQueue()
            self.emit(.changed(reason: "source-updated"))
        }
        return statusEntry(src)
    }
}

// MARK: - v0.4: 원문 편집·저장 (docs/V04.md §4)

extension Library {
    static let rawLimit = 2 * 1024 * 1024
    static let editableKinds: Set<String> = ["md", "markdown", "txt", "text"]

    static func contentFingerprint(_ d: Data) -> String {
        SHA256.hash(data: d).prefix(12).map { String(format: "%02x", $0) }.joined() + "-\(d.count)"
    }

    /// 편집 대상 확인: (파일 URL, 소스) 또는 편집할 수 없는 이유.
    private func editTarget(_ id: String) throws -> (url: URL, src: SourceConfig, kind: String, reason: String?) {
        let snap = currentSnapshot()
        guard let i = snap.index[id] else { throw LibraryError("문서를 찾을 수 없어요.") }
        let d = snap.docs[i].m
        guard let src = currentSources().first(where: { $0.id == d.sourceId }) else { throw LibraryError("자료를 찾을 수 없어요.") }
        let url = URL(fileURLWithPath: d.location)
        if src.kind.isRemote { return (url, src, d.kind, "원격 문서는 원본에서 고쳐 주세요") }
        if !Library.editableKinds.contains(d.kind) {
            return (url, src, d.kind, d.kind == "pdf" ? "PDF는 편집할 수 없어요" : "이 형식은 편집할 수 없어요")
        }
        return (url, src, d.kind, nil)
    }

    private static func decodeUTF8(_ data: Data) -> (text: String, bom: Bool)? {
        let bom = data.starts(with: [0xEF, 0xBB, 0xBF])
        guard let t = String(data: bom ? data.dropFirst(3) : data, encoding: .utf8) else { return nil }
        return (t, bom)
    }

    /// 원문 그대로(프런트매터 포함, 줄바꿈은 \n으로). 2MB 초과·UTF-8 아님·PDF·원격이면 editable false + 이유.
    func readRawJSON(id: String) throws -> [String: Any] {
        let t = try editTarget(id)
        if let r = t.reason { return ["text": "", "fingerprint": "", "editable": false, "reason": r] }
        guard let data = try? Data(contentsOf: t.url) else { throw LibraryError("파일을 읽을 수 없어요.") }
        let fp = Library.contentFingerprint(data)
        if data.count > Library.rawLimit { return ["text": "", "fingerprint": fp, "editable": false, "reason": "2MB가 넘는 문서는 편집할 수 없어요"] }
        guard let dec = Library.decodeUTF8(data) else {
            return ["text": "", "fingerprint": fp, "editable": false, "reason": "UTF-8이 아닌 파일은 편집할 수 없어요"]
        }
        return ["text": Library.toLF(dec.text), "fingerprint": fp, "editable": true]
    }

    /// 지문이 같을 때만 저장: 백업 → 같은 폴더 임시 파일 → 원자적 교체(권한·생성일·줄바꿈·BOM 유지) → 즉시 재색인.
    func saveRaw(id: String, text: String, fingerprint: String) throws -> [String: Any] {
        if readOnly { throw LibraryError("읽기 전용으로 열려 있어요.") }
        let t = try editTarget(id)
        if let r = t.reason { throw LibraryError(r + ".") }
        guard let old = try? Data(contentsOf: t.url) else { throw LibraryError("파일을 읽을 수 없어요.") }
        if Library.contentFingerprint(old) != fingerprint { return ["ok": false, "conflict": true] }
        guard let dec = Library.decodeUTF8(old) else { throw LibraryError("UTF-8이 아닌 파일은 편집할 수 없어요.") }
        // 원래 파일이 전부 CRLF거나 전부 CR일 때만 그 형식으로 되돌린다 (섞였거나 LF면 편집한 그대로 LF)
        let style = Library.lineStyle(dec.text)
        var body = Library.toLF(text)
        if style == "crlf" { body = body.replacingOccurrences(of: "\n", with: "\r\n") }
        else if style == "cr" { body = body.replacingOccurrences(of: "\n", with: "\r") }
        var bytes = Data()
        if dec.bom { bytes.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
        bytes.append(Data(body.utf8))
        guard bytes.count <= Library.rawLimit else { throw LibraryError("2MB가 넘는 문서는 저장할 수 없어요.") }
        try backup(old, id: id, ext: t.url.pathExtension, like: t.url)
        let dir = t.url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".synapse-save-\(UUID().uuidString).\(t.url.pathExtension)")
        do {
            try bytes.write(to: tmp)
            _ = try FileManager.default.replaceItemAt(t.url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw LibraryError("저장하지 못했어요. 파일 권한을 확인해 주세요.")
        }
        // 파일은 이미 저장됐다 — 응답은 바로, 재색인은 색인 큐에서 (긴 색인 중에도 기다리지 않는다).
        // 다음 readRaw·saveRaw의 지문은 언제나 디스크 내용으로 계산한다.
        let src = t.src
        queue.async {
            if let store = self.store, let o = try? Indexer.indexPaths(src, paths: [t.url.path], rescan: false, store: store, nested: self.nested(src)) {
                self.pendingChanged.formUnion(o.ids)
                self.rebuildSnapshot()
                self.scheduleRelate()
            }
            self.emit(.changed(reason: "saved"))
        }
        return ["ok": true, "fingerprint": Library.contentFingerprint(bytes)]
    }

    /// 줄바꿈 형식: 전부 CRLF → "crlf", 전부 CR → "cr", 그 밖(LF·섞임·없음) → "lf".
    static func lineStyle(_ t: String) -> String {
        var crlf = 0, cr = 0, lf = 0
        var prevCR = false
        for u in t.utf8 {
            if u == 0x0D { if prevCR { cr += 1 }; prevCR = true; continue }
            if u == 0x0A { if prevCR { crlf += 1 } else { lf += 1 } }
            else if prevCR { cr += 1 }
            prevCR = false
        }
        if prevCR { cr += 1 }
        if crlf > 0 && cr == 0 && lf == 0 { return "crlf" }
        if cr > 0 && crlf == 0 && lf == 0 { return "cr" }
        return "lf"
    }

    static func toLF(_ t: String) -> String {
        t.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// <home>/backups/<sha1(id) 앞 12자>/<yyyyMMdd-HHmmss>.<ext> — 문서당 20개, 전체 200MB.
    private func backup(_ data: Data, id: String, ext: String, like original: URL) throws {
        let key = Insecure.SHA1.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12)
        let root = home.appendingPathComponent("backups")
        let dir = root.appendingPathComponent(String(key))
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { throw LibraryError("백업을 만들지 못해 저장하지 않았어요.") }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: Date())
        var url = dir.appendingPathComponent(stamp + "." + ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = dir.appendingPathComponent("\(stamp)-\(n).\(ext)"); n += 1 }
        do {
            // 원본 권한을 그대로 (0600 노트의 백업이 0644가 되지 않게): 먼저 빈 파일을 그 권한으로 만들고 쓴다
            let perms = (try? FileManager.default.attributesOfItem(atPath: original.path)[.posixPermissions] as? NSNumber)?.int16Value ?? 0o600
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: perms]) else { throw LibraryError("") }
            try data.write(to: url)
            try? FileManager.default.setAttributes([.posixPermissions: perms], ofItemAtPath: url.path)
        } catch { throw LibraryError("백업을 만들지 못해 저장하지 않았어요.") }
        let fm = FileManager.default
        let mine = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        for old in mine.dropLast(20) { try? fm.removeItem(at: dir.appendingPathComponent(old)) }
        // 전체 200MB를 넘으면 오래된 것부터. 사서의 이동 백업(backups/moves, 되돌리기용)은 사서가 30일 단위로 따로 정리한다.
        var all: [(URL, Date, Int)] = []
        let moves = root.appendingPathComponent("moves").standardizedFileURL.path
        let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]) ?? FileManager.DirectoryEnumerator()
        for case let u as URL in walker {
            if u.standardizedFileURL.path == moves { walker.skipDescendants(); continue }
            guard let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
            all.append((u, v.contentModificationDate ?? .distantPast, v.fileSize ?? 0))
        }
        var total = all.reduce(0) { $0 + $1.2 }
        for (u, _, size) in all.sorted(by: { $0.1 < $1.1 }) where total > 200 * 1024 * 1024 {
            if u == url { continue }
            try? fm.removeItem(at: u); total -= size
        }
    }
}

extension Library: @unchecked Sendable {}

// MARK: - v0.6 옵시디언 대체: Library/Notes.swift가 쓰는 접근자
extension Library {
    var notesSnapshot: Snapshot { currentSnapshot() }
    var notesSources: [SourceConfig] { currentSources() }
    var notesReadOnly: Bool { readOnly }

    /// 새로 만든 파일 하나를 바로 색인해 스냅샷에 넣는다(색인 큐에서 동기 실행). 연결 계산은 평소처럼 디바운스.
    func notesIndexNow(_ src: SourceConfig, path: String) {
        guard let store = store else { return }
        queue.sync {
            if let o = try? Indexer.indexPaths(src, paths: [path], rescan: false, store: store, nested: nested(src)) {
                pendingChanged.formUnion(o.ids)
                rebuildSnapshot()
                scheduleRelate()
            }
        }
        emit(.changed(reason: "created"))
    }
}
