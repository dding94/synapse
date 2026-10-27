import Foundation

// v0.5 사서 파사드 (docs/V05.md §2.1). 조립·큐·타이머·디바운스·이벤트.
// 모든 공개 메서드는 아무 스레드에서나 불러도 된다(ctx.queue로 넘긴다). 실패는 ["ok": false, "error": …].

/// 문서 이동을 받고 싶은 모듈(WorkModel)이 따른다. WorkModule 계약에 자리가 없어 여기 둔다.
protocol BrainDocMoveObserver: AnyObject {
    func docMoved(fromID: String, toID: String)
}

final class Brain: BrainAPI {
    var onEvent: ((BrainEventKind) -> Void)?
    let homeURL: URL
    let mode: BrainMode
    private let sourcesFn: () -> [SourceConfig]
    private let env: BrainEnv
    private let db: BrainDB
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Bool>()
    private(set) var ctx: BrainContext
    private(set) var signals: Signals
    private(set) var organizer: Organizer
    private(set) var work: WorkModel
    private(set) var tidy: Tidy          // v0.9 정리 비서 (docs/V09.md §4)

    // 큐 안에서만 쓰는 상태
    private var debounce: DispatchWorkItem?
    private var pendingExtra = Set<String>()
    private var timers: [DispatchSourceTimer] = []
    private var started = false
    private var policyChecked = false
    private var lastPending = -1
    private var lastDataVersion: Int64 = -1
    private var firstBatchDone = false
    private var noonDay = ""
    private var scanning = false
    private var scanChanged = false
    private var enrichMore = false
    private var lastTidyHash = ""                  // v0.9: 마지막으로 규칙을 돌린 인벤토리 해시
    private var lastTidyCheck = Date.distantPast
    // 메인 큐에서만 쓰는 상태 (이벤트 속도 제한)
    private var lastSent: [BrainEventKind: Date] = [:]
    private var scheduled = Set<BrainEventKind>()

    init(home: URL, mode: BrainMode, sources: @escaping () -> [SourceConfig]) throws {
        self.homeURL = home
        self.mode = mode
        sourcesFn = sources
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        env = BrainEnv.current(home: home)
        db = try BrainDB(url: home.appendingPathComponent("brain.sqlite"))
        queue = DispatchQueue(label: "synapse.brain", qos: .utility)
        let index = try? Store(readOnlyAt: home.appendingPathComponent("index.sqlite"))
        (ctx, signals, organizer, work, tidy) = Brain.assemble(home: home, mode: mode, env: env, db: db, index: index, queue: queue)
        queue.setSpecific(key: queueKey, value: true)
        wire()
    }

    private static func assemble(home: URL, mode: BrainMode, env: BrainEnv, db: BrainDB, index: Store?, queue: DispatchQueue)
        -> (BrainContext, Signals, Organizer, WorkModel, Tidy) {
        let ctx = BrainContext(home: home, mode: mode, env: env, db: db, index: index, queue: queue)
        let organizer = Organizer(ctx: ctx)
        return (ctx, Signals(ctx: ctx), organizer, WorkModel(ctx: ctx), Tidy(ctx: ctx, organizer: organizer))
    }

    private func wire() {
        ctx.sources = sourcesFn
        ctx.emit = { [weak self] k in self?.emit(k) }
        ctx.onSynapseWrite = { [weak self] paths in self?.signals.noteSynapseWrite(paths) }
        ctx.onDocMoved = { [weak self] from, to, fromPath, toPath in
            guard let self = self else { return }
            self.signals.docMoved(fromID: from, toID: to, fromPath: fromPath, toPath: toPath)
            ((self.work as AnyObject) as? BrainDocMoveObserver)?.docMoved(fromID: from, toID: to)
            self.pendingExtra.insert(to)
        }
        ctx.obsidianOpenPaths = { [weak self] in self?.signals.obsidianOpenPaths() ?? [] }
        work.pendingCount = { [weak self] in self?.pendingTotal() ?? 0 }
    }

    /// 정리함 대기 수: 정리 카드(이동·규칙·점검·삭제) + v0.8 Jira 카드(대기·반영 중·실패).
    private func pendingTotal() -> Int { organizer.pendingCount() + organizer.jiraPendingCount() + tidyPendingCount() }

    /// v0.9: 승인 기다리는 정리 제안 수 (알림 note 제외).
    private func tidyPendingCount() -> Int {
        var n = 0
        try? ctx.db.sql.query("SELECT COUNT(*) FROM suggestions WHERE kind='tidy' AND state='pending' AND json_extract(payload,'$.op')<>'note'") { n = Int($0.int(0)) }
        return n
    }

    /// 색인이 처음 만들어졌으면 다시 열고 모듈을 새 문맥으로 다시 조립한다(ctx.index가 let이라서).
    private func reopenIndexIfNeeded() {
        guard ctx.index == nil,
              let index = try? Store(readOnlyAt: homeURL.appendingPathComponent("index.sqlite")) else { return }
        signals.stop()
        let updater = ctx.updateSourceExcludes
        (ctx, signals, organizer, work, tidy) = Brain.assemble(home: homeURL, mode: mode, env: env, db: db, index: index, queue: queue)
        ctx.updateSourceExcludes = updater
        wire()
        policyChecked = false
        if started { signals.start() }
    }

    private func sync<T>(_ f: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return f() }
        return queue.sync(execute: f)
    }

    /// 읽기 전 준비: 색인 다시 열기·문서 목록. CLI는 동기 갱신(1~5단계)까지.
    private func prepare() {
        reopenIndexIfNeeded()
        if mode == .cli { signals.purgeIfDue(); runPipeline(); organizer.purgeExpiredTrash() } else { ctx.reloadDocsIfChanged() }
    }

    private func call(_ f: () -> [String: Any]) -> [String: Any] {
        sync { prepare(); return f() }
    }

    private static func fail(_ msg: String) -> [String: Any] { ["ok": false, "error": msg] }

    // MARK: 갱신 (§2.1 indexChanged 1~6단계)

    private func runPipeline(extra: Set<String> = []) {
        guard mode != .mcp else { return }
        reopenIndexIfNeeded()
        ctx.reloadDocsIfChanged()
        var ids = signals.processIndexChanges()
        let initial = signals.lastRunInitial
        let policyDoc = ids.contains { ($0 as NSString).lastPathComponent == "CLAUDE.md" }
        if !policyChecked || policyDoc { organizer.refreshPolicy(); policyChecked = true }
        organizer.checkNew(docIds: initial ? [] : ids)   // 처음 실행의 조용한 등록은 "확인함"으로 세지 않는다
        for e in extra where !ids.contains(e) { ids.append(e) }
        work.refresh(changed: ids)
        emit(.home)
        if mode == .app { tidyAfterIndex() }
        let p = pendingTotal()
        if p != lastPending { lastPending = p; emit(.pending) }
    }

    /// v0.9 §4.2: 색인이 바뀐 뒤 인벤토리(자리)가 달라졌으면 정리 규칙을 돌린다. 1분에 한 번까지(나머지는 10분 tidyTick).
    private func tidyAfterIndex() {
        guard !ctx.isStopped, Date().timeIntervalSince(lastTidyCheck) >= 60 else { return }
        lastTidyCheck = Date()
        let h = tidy.inventory(force: false).hash
        guard h != lastTidyHash else { return }
        lastTidyHash = h
        let r = tidy.runRules(autoApply: true)
        if ((r["proposed"] as? Int) ?? 0) + ((r["applied"] as? Int) ?? 0) > 0 { afterTidy() }
    }

    func indexChanged() {
        guard mode != .mcp else { return }
        queue.async { [weak self] in self?.scheduleRefresh() }
    }

    private func scheduleRefresh() {
        debounce?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let extra = self.pendingExtra
            self.pendingExtra = []
            self.runPipeline(extra: extra)
        }
        debounce = item
        queue.asyncAfter(deadline: .now() + 1, execute: item)
    }

    // MARK: 수명·타이머 (앱 모드)

    func start() {
        guard mode == .app else { return }
        queue.async { [weak self] in
            guard let self = self, !self.started else { return }
            self.started = true
            self.signals.start()
            self.runPipeline()
            self.lastDataVersion = self.dataVersion()
            self.addTimer(first: 5, every: 60) { $0.sessionTick() }
            self.addTimer(first: self.env.isTest ? 1 : 60, every: 60) { $0.batchTick() }
            self.addTimer(first: 5, every: 5) { $0.engineTick() }
            self.addTimer(first: 15, every: 15) { $0.versionTick() }
            self.addTimer(first: 3, every: 3600) { $0.purgeTick() }
            self.addTimer(first: self.env.isTest ? 2 : 30, every: 600) { $0.tidyTick() }   // v0.9 정리 규칙 (§4.2)
        }
    }

    func stop() {
        sync {
            timers.forEach { $0.cancel() }
            timers = []
            debounce?.cancel()
            signals.stop()
            started = false
        }
    }

    private func addTimer(first: TimeInterval, every: TimeInterval, _ body: @escaping (Brain) -> Void) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + first, repeating: every)
        t.setEventHandler { [weak self] in if let s = self { body(s) } }
        t.resume()
        timers.append(t)
    }

    /// 세션 읽기: 200ms 조각을 끝날 때까지 다시 건다.
    private func sessionTick() {
        guard !scanning, !ctx.isStopped, ctx.db.setting(BrainSetting.sessionsEnabled) == "1" else { return }
        scanning = true
        scanChanged = false
        scanStep()
    }

    private func scanStep() {
        let more = signals.scanSessions(budget: 0.2)
        scanChanged = scanChanged || signals.lastScanChanged
        if more { queue.async { [weak self] in self?.scanStep() }; return }
        scanning = false
        if scanChanged { work.refresh(changed: []); emit(.home); emit(.settings) }
    }

    private func batchTick() {
        guard !ctx.isStopped else { return }
        let now = ctx.now()
        let day = BrainFormat.dayKey(now)
        let afterNoon = Calendar.current.component(.hour, from: now) >= 12
        if !firstBatchDone {
            firstBatchDone = true
            if afterNoon { noonDay = day }
        } else if afterNoon && noonDay != day {
            noonDay = day
        } else { return }
        if organizer.runBatch(force: false) > 0 { emit(.log); emit(.home) }
        let p = pendingTotal()
        if p != lastPending { lastPending = p; emit(.pending) }
    }

    private func engineTick() {
        guard !ctx.isStopped, work.engineState()["apple"] as? String == "ready" else { return }
        let more = work.enrichStep(budget: 0.2)
        if more || enrichMore { emit(.home) }
        enrichMore = more
    }

    private func dataVersion() -> Int64 {
        var v: Int64 = -1
        try? ctx.db.sql.query("PRAGMA data_version") { v = $0.int(0) }
        return v
    }

    /// 다른 프로세스(MCP)가 brain.sqlite에 쓴 것을 알아챈다.
    private func versionTick() {
        let v = dataVersion()
        guard v != lastDataVersion else { return }
        lastDataVersion = v
        lastPending = pendingTotal()
        emit(.pending); emit(.home); emit(.log)     // v0.6: MCP 바로 실행·제안도 AI 기록에 바로 보이게
    }

    /// v0.9: 정리 규칙을 돌리고 자동 규칙을 적용한다(§4.2·§4.4). 바뀐 게 있으면 화면에 알린다.
    private func tidyTick() {
        guard !ctx.isStopped else { return }
        prepare()
        lastTidyCheck = Date()
        lastTidyHash = tidy.inventory(force: false).hash
        let r = tidy.runRules(autoApply: true)
        if ((r["proposed"] as? Int) ?? 0) + ((r["applied"] as? Int) ?? 0) > 0 { afterTidy() }
    }

    private func purgeTick() {
        signals.purgeIfDue()
        organizer.purgeExpiredTrash()               // v0.6: 30일 지난 휴지통 항목 → macOS 휴지통 (시작 3초 뒤·한 시간마다)
    }

    // MARK: 이벤트 (메인 큐, 같은 종류는 1초에 한 번)

    private func emit(_ k: BrainEventKind) {
        guard mode == .app else { return }
        DispatchQueue.main.async { [weak self] in self?.deliver(k) }
    }

    private func deliver(_ k: BrainEventKind) {
        let now = Date()
        if let last = lastSent[k], now.timeIntervalSince(last) < 1 {
            guard !scheduled.contains(k) else { return }
            scheduled.insert(k)
            DispatchQueue.main.asyncAfter(deadline: .now() + (1 - now.timeIntervalSince(last))) { [weak self] in
                guard let self = self else { return }
                self.scheduled.remove(k)
                self.lastSent[k] = Date()
                self.onEvent?(k)
            }
            return
        }
        lastSent[k] = now
        onEvent?(k)
    }
}

// MARK: - 화면·MCP·CLI 입구 (§8.2 · §7 · §8.4)

extension Brain {
    func home() -> [String: Any] {
        call {
            var h = work.home()
            h["tidy"] = tidyBlock()       // v0.9 §7.3 홈 정리 한 줄
            return h
        }
    }
    func why(id: String) -> [String: Any] { call { work.why(id: id) } }
    func week(offset: Int) -> [String: Any] { call { work.week(offset: offset) } }
    func tickets(mine: Bool) -> [String: Any] { call { work.tickets(mine: mine) } }
    func map() -> [String: Any] { call { work.map() } }
    func pending() -> [String: Any] {
        call {
            var r = organizer.pending()
            // v0.9 §4.3: 정리함에 tidy 카드도 (organizer 카드 뒤에)
            let extra = tidy.cards(paths: [], keys: [])
            if !extra.isEmpty { r["cards"] = ((r["cards"] as? [[String: Any]]) ?? []) + extra }
            return r
        }
    }
    func policy() -> [String: Any] { call { organizer.policy() } }
    func workContext(period: String) -> [String: Any] { call { work.workContext(period: period) } }
    func vaultPolicy() -> [String: Any] { call { organizer.vaultPolicy() } }
    func listPending() -> [String: Any] { call { organizer.listPending() } }
    func suggestLocation(_ args: [String: Any]) -> [String: Any] { call { organizer.suggestLocation(args) } }

    /// v0.7 B: 프로젝트를 업무/개인으로 바꾼다(auto = 규칙으로). 홈을 다시 읽게 알린다.
    func setProjectScope(project: String, scope: String) -> [String: Any] {
        sync {
            let r = work.setProjectScope(project: project, scope: scope)
            if r["ok"] as? Bool == true { emit(.home) }
            return r
        }
    }

    func feedback(id: String, action: String, scope: String?) -> [String: Any] {
        call {
            let r = work.feedback(id: id, action: action, scope: scope)
            emit(.home)
            return r
        }
    }

    /// 이동 제안 승인(approve·edit)은 비상 정지면 거절한다. rules 카드 승인은 그대로 넘긴다.
    private func refusesApply(id: String, action: String) -> Bool {
        guard ctx.isStopped else { return false }
        if id.hasPrefix("b:") { return true }
        guard action == "approve" || action == "edit" else { return false }
        var kind = ""
        try? ctx.db.sql.query("SELECT kind FROM suggestions WHERE id=?", [.text(id)]) { kind = $0.text(0) }
        return kind == "move"
    }

    private func afterDecision() {
        lastPending = pendingTotal()
        emit(.pending); emit(.home); emit(.log)
    }

    func decide(id: String, action: String, to: String?) -> [String: Any] {
        call {
            if refusesApply(id: id, action: action) { return Brain.fail("사서가 멈춰 있어서 옮기지 않았어요. 다시 시작한 뒤 승인해 주세요.") }
            if id.hasPrefix("t:") {          // v0.9 §4.3: 정리함의 tidy 카드
                let r = tidy.decide(id: id, action: action == "edit" ? "to" : action, to: to)
                afterTidy()
                return r
            }
            let r = organizer.decide(id: id, action: action, to: to)
            afterDecision()
            return r
        }
    }

    func decideBundle(id: String) -> [String: Any] {
        call {
            if ctx.isStopped { return Brain.fail("사서가 멈춰 있어서 옮기지 않았어요. 다시 시작한 뒤 승인해 주세요.") }
            let r = organizer.decideBundle(id: id)
            afterDecision()
            return r
        }
    }

    func undo(batchId: String?) -> [String: Any] {
        call {
            if let b = batchId, Brain.isTidyBatch(b) {   // v0.9: 정리 비서 배치 ("t" + 날짜)
                let r = tidy.undo(batchId: b)
                afterTidy()
                return r
            }
            let r = organizer.undo(batchId: batchId)
            afterDecision()
            return r
        }
    }

    // MARK: v0.9 작업 지도 · 정리 비서 (docs/V09.md §6·§8)

    static func isTidyBatch(_ b: String) -> Bool { b.hasPrefix("t2") }

    func workMap() -> [String: Any] { call { work.workMap(tidy: tidy) } }
    func workMapDetail(id: String) -> [String: Any] { call { work.workMapDetail(id: id, tidy: tidy) } }
    func tidyPlan() -> [String: Any] { call { tidy.plan() } }
    func tidyContext() -> [String: Any] { call { tidy.context() } }
    func tidyRules() -> [String: Any] { call { tidy.rules() } }
    func tidyLastBatch() -> String? { sync { tidy.lastBatch() } }

    func tidyDecide(id: String, action: String, to: String?) -> [String: Any] {
        call { let r = tidy.decide(id: id, action: action, to: to); afterTidy(); return r }
    }

    func tidyDecideGroup(group: String, ids: [String]?) -> [String: Any] {
        call { let r = tidy.decideGroup(group: group, ids: ids); afterTidy(); return r }
    }

    func tidyUndo(batchId: String?) -> [String: Any] {
        call { let r = tidy.undo(batchId: batchId); afterTidy(); return r }
    }

    func tidyPromote(signature: String, accept: Bool) -> [String: Any] {
        call { let r = tidy.promote(signature: signature, accept: accept); afterTidy(); return r }
    }

    func tidySetRule(signature: String, state: String) -> [String: Any] {
        call { let r = tidy.setRule(signature: signature, state: state); afterTidy(); return r }
    }

    func tidyRunRules() -> [String: Any] {
        call {
            if ctx.isStopped { return Brain.fail("사서가 멈춰 있어요. 다시 시작하면 정리할 수 있어요.") }
            let r = tidy.runRules(autoApply: true)
            afterTidy()
            return r
        }
    }

    /// Claude 정리 계획 결과를 제안으로 (§5). 앱이 AIService.onDigestResult에서 부른다.
    func tidyIngest(result: [String: Any], runId: String?) -> [String: Any] {
        call {
            if ctx.isStopped { return Brain.fail("사서가 멈춰 있어요.") }
            let r = tidy.ingest(result: result, runId: runId)
            afterTidy()
            return r
        }
    }

    /// 출처 제외 폴더를 바꾸는 앱 콜백 (§8). 앱 시작 때 한 번.
    func setSourceExcludesUpdater(_ f: @escaping (_ sourceId: String, _ add: [String], _ remove: [String]) -> String?) {
        sync { ctx.updateSourceExcludes = f }
    }

    /// 홈·작업 지도 머리의 정리 블록 (§6.1·§7.3).
    func tidyBlock() -> [String: Any] { work.tidyHead(tidy) }   // 작업 지도 머리와 같은 값 (lastRunLabel 포함)

    private func afterTidy() {
        lastPending = pendingTotal()
        emit(.tidy); emit(.pending); emit(.home); emit(.log)
    }

    func approvePolicy() -> [String: Any] {
        call {
            let r = organizer.approvePolicy()
            emit(.policy); afterDecision()
            return r
        }
    }

    func proposeChanges(items: [[String: Any]], origin: String) -> [String: Any] {
        proposeChanges(items: items, origin: origin, runId: nil)
    }

    /// v0.8 §6.1: 실행 id(SYNAPSE_RUN_ID)가 있으면 이동·삭제 제안의 payload.run에 남긴다.
    func proposeChanges(items: [[String: Any]], origin: String, runId: String?) -> [String: Any] {
        call {
            let r = organizer.propose(items: items, origin: origin, runId: Organizer.cleanRunId(runId))
            afterDecision()
            return r
        }
    }

    // MARK: v0.8 Jira 제안 (§6.1, JiraProposals.swift) — 반영 흐름은 JiraApply가 jiraBegin → JiraWriter → jiraFinish로 부른다

    func proposeJira(items: [[String: Any]], origin: String, runId: String?) -> [String: Any] {
        call {
            let r = organizer.proposeJira(items: items, origin: origin, runId: runId)
            afterDecision()
            return r
        }
    }

    func jiraBegin(id: String) -> [String: Any] {
        call {
            let r = organizer.jiraBegin(id: id)
            if r["ok"] as? Bool == true { afterDecision() }
            return r
        }
    }

    func jiraFinish(id: String, ok: Bool, message: String, result: [String: Any]?) -> [String: Any] {
        call {
            let r = organizer.jiraFinish(id: id, ok: ok, message: message, result: result)
            afterDecision()
            return r
        }
    }

    func proposals(run: String) -> [[String: Any]] {
        sync { prepare(); return organizer.proposals(run: run) }
    }

    func claudeInstruction(context: String, id: String?) -> [String: Any] {
        call { ["ok": true, "text": work.claudeInstruction(context: context, id: id)] }
    }

    func track(event: String, docId: String) {
        switch mode {
        case .mcp: return
        case .cli:
            sync { prepare(); signals.track(event: event, docId: docId); work.refresh(changed: [docId]) }
        case .app:
            queue.async { [weak self] in
                guard let self = self else { return }
                self.signals.track(event: event, docId: docId)
                self.pendingExtra.insert(docId)
                self.scheduleRefresh()
            }
        }
    }

    func runBatchNow() -> [String: Any] {
        call {
            if ctx.isStopped { return Brain.fail("사서가 멈춰 있어요. 다시 시작하면 정리 제안을 만들 수 있어요.") }
            let n = organizer.runBatch(force: true)
            afterDecision()
            return ["ok": true, "created": n]
        }
    }

    // MARK: AI 기록 (§8.2 aiLog)

    private static func originLabel(_ o: String) -> String {
        let base = o.hasPrefix("mcp:") ? String(o.dropFirst(4)) : o
        switch base.lowercased() {
        case "rules": return "규칙"
        case "apple": return "기기 AI"
        case "claude", "claude-digest": return "Claude"
        case "codex": return "Codex"
        case "user": return "나"
        case "mcp": return "MCP"
        default: return base
        }
    }

    func aiLog(limit: Int) -> [String: Any] {
        call {
            let cal = Calendar.current
            let now = ctx.now()
            var rows: [(Int64, Double, String, String, String, String?)] = []
            try? ctx.db.sql.query("SELECT id, ts, kind, text, origin, batch_id FROM ai_log ORDER BY id DESC LIMIT ?",
                                  [.int(Int64(max(1, min(limit, 1000))))]) {
                rows.append(($0.int(0), $0.double(1), $0.text(2), $0.text(3), $0.text(4), $0.isNull(5) ? nil : $0.text(5)))
            }
            var openBatch: [String: Bool] = [:]
            let entries: [[String: Any]] = rows.map { r in
                let d = Date(timeIntervalSince1970: r.1)
                let day: String
                if cal.isDate(d, inSameDayAs: now) { day = "오늘" }
                else if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { day = "어제" }
                else { day = "\(cal.component(.month, from: d))/\(cal.component(.day, from: d))" }
                var undoable = false
                if r.2 == "apply" || r.2 == "trash", let b = r.5, now.timeIntervalSince(d) <= 30 * 86400 {
                    if openBatch[b] == nil {
                        var open = false
                        try? ctx.db.sql.query("SELECT 1 FROM ops_log WHERE batch_id=? AND undone=0 LIMIT 1", [.text(b)]) { _ in open = true }
                        openBatch[b] = open
                    }
                    undoable = openBatch[b]!
                }
                return ["id": r.0, "ts": BrainFormat.iso(d),
                        "tsLabel": String(format: "%02d:%02d", cal.component(.hour, from: d), cal.component(.minute, from: d)),
                        "day": day, "kind": r.2, "text": r.3, "origin": r.4, "originLabel": Brain.originLabel(r.4),
                        "batchId": r.5 ?? NSNull(), "undoable": undoable]
            }
            return ["entries": entries, "engine": engineJSON()]
        }
    }

    // MARK: 설정 (§8.2 brainSettings · setBrainSetting)

    private func engineJSON() -> [String: Any] {
        var e = work.engineState()
        e["noticeShown"] = ctx.db.setting(BrainSetting.appleNoticeShown) == "1"
        return e
    }

    func settings() -> [String: Any] {
        call {
            let pol = organizer.policy()
            let counts = pol["counts"] as? [String: Int] ?? [:]
            let ruleCount = (pol["rules"] as? [Any])?.count ?? counts.values.reduce(0, +)
            return ["sessions": signals.sessionsJSON(), "engine": engineJSON(), "stopped": ctx.isStopped,
                    "mcpRemoteBodies": ctx.db.setting(BrainSetting.mcpRemoteBodies) == "1",
                    "mcpDirectApply": ctx.db.setting(BrainSetting.mcpDirectApply) == "on" ? "on" : "off",
                    "trash": ["count": organizer.trashCount(), "retentionDays": Int(Organizer.trashDays)],
                    "policy": ["approved": pol["approved"] as? Bool ?? false, "stale": pol["stale"] as? Bool ?? false,
                               "ruleCount": ruleCount],
                    "tidy": tidy.rules(),                                   // v0.9 §7.5
                    "workmapScope": ctx.db.setting(TidySetting.workmapScope) ?? "all"]
        }
    }

    /// 코드 폴더로 쓸 수 없는 이유 (없으면 nil). 사서 큐에서 부른다.
    private func codeFolderProblem(_ v: String) -> String? {
        let home = Indexer.nfc(Indexer.realPath(ctx.env.userHome))
        let system: Set<String> = ["/", "/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/etc", "/private",
                                   "/var", "/Users", "/Volumes", "/tmp", "/opt", "/private/tmp", "/private/var"]
        if system.contains(v) || v == home { return "홈 폴더나 시스템 폴더는 코드 폴더로 쓸 수 없어요." }
        let roots = ctx.sources().filter { $0.enabled && ($0.kind == .folder || $0.kind == .obsidian) }
            .compactMap { $0.path.map { Indexer.nfc(Indexer.realPath($0)) } } + ctx.vaults.roots
        if roots.contains(where: { $0 == v || $0.hasPrefix(v + "/") }) { return "연결한 자료 폴더를 품은 폴더는 코드 폴더로 쓸 수 없어요." }
        if ctx.vaults.vault(forAbs: v) != nil { return "볼트 안 폴더는 코드 폴더로 쓸 수 없어요." }
        return nil
    }

    /// v0.9 §7.5 정리 설정. 값 검사 뒤 저장하고 작업 지도·홈·설정을 다시 읽게 한다.
    private func setTidySetting(_ key: String, _ value: String) -> [String: Any] {
        var v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch key {
        case TidySetting.auto:
            guard v == "1" || v == "0" else { return Brain.fail("설정 값은 1 또는 0이에요.") }
        case TidySetting.dailyCap:
            guard let n = Int(v), (0...200).contains(n) else { return Brain.fail("하루 상한은 0~200 사이 숫자예요.") }
            v = String(n)
        case TidySetting.codeFolder:
            if !v.isEmpty {
                v = (v as NSString).expandingTildeInPath
                var dir: ObjCBool = false
                guard v.hasPrefix("/"), FileManager.default.fileExists(atPath: v, isDirectory: &dir), dir.boolValue else {
                    return Brain.fail("코드 폴더를 찾을 수 없어요.")
                }
                v = Indexer.nfc(Indexer.realPath(v))
                // 리뷰 #9: 코드 폴더는 옮길 수 있는 범위를 넓히므로 홈·시스템 폴더·자료 폴더를 품은 폴더·볼트 안은 받지 않는다
                let chosen = v
                if let problem = sync({ codeFolderProblem(chosen) }) { return Brain.fail(problem) }
            }
        case TidySetting.reviewDay:
            guard v == "off" || TidyReview.days[v] != nil else { return Brain.fail("리뷰 요일은 mon~fri 또는 off예요.") }
        case TidySetting.workmapScope:
            guard ["all", "work", "personal"].contains(v) else { return Brain.fail("설정 값은 all · work · personal 중 하나예요.") }
        default: return Brain.fail("바꿀 수 없는 설정이에요.")
        }
        return sync {
            ctx.db.setSetting(key, v.isEmpty ? nil : v)
            emit(.tidy); emit(.settings); emit(.home)
            return ["ok": true]
        }
    }

    func setSetting(key: String, value: String) -> [String: Any] {
        let flags = [BrainSetting.sessionsEnabled, BrainSetting.sessionsRequestText, BrainSetting.stopped,
                     BrainSetting.mcpRemoteBodies, BrainSetting.appleNoticeShown]
        if key == BrainSetting.mcpDirectApply { return setDirectApply(value) }
        if TidySetting.appKeys.contains(key) { return setTidySetting(key, value) }   // v0.9 §7.5
        if key == BrainSetting.homeUrgentScope {   // v0.7 B: 홈 급한 것 거르기 (all | work | personal)
            guard ["all", "work", "personal"].contains(value) else { return Brain.fail("설정 값은 all · work · personal 중 하나예요.") }
            return sync {
                ctx.db.setSetting(key, value == "all" ? nil : value)
                emit(.home); emit(.settings)
                return ["ok": true]
            }
        }
        guard flags.contains(key) || key == "sessions.clear" else { return Brain.fail("바꿀 수 없는 설정이에요.") }
        guard value == "1" || value == "0" else { return Brain.fail("설정 값은 1 또는 0이에요.") }
        return sync {
            let db = ctx.db
            switch key {
            case "sessions.clear":
                guard value == "1" else { return ["ok": true] }
                signals.clearSessions()
                db.setSetting(BrainSetting.sessionsEnabled, "0")
                ctx.log("session", "세션 기록을 끄고 지웠어요")
                work.refresh(changed: [])
                emit(.home)
            case BrainSetting.sessionsEnabled:
                let was = db.setting(key)
                db.setSetting(key, value)
                if was != value { ctx.log("session", value == "1" ? "세션 기록을 켰어요" : "세션 기록을 껐어요") }
                if value == "1" && mode == .app { queue.async { [weak self] in self?.sessionTick() } }
                emit(.home)
            case BrainSetting.sessionsRequestText:
                db.setSetting(key, value)
                if value == "0" { signals.dropRequestText() }
                work.refresh(changed: [])   // 요청 문장으로 지은 흐름 제목을 바로 고친다
                emit(.home)
            case BrainSetting.stopped:
                let was = ctx.isStopped
                db.setSetting(key, value)
                if was != (value == "1") { ctx.log("stop", value == "1" ? "사서를 멈췄어요" : "다시 시작했어요") }
                emit(.home); emit(.pending)
            default:
                db.setSetting(key, value)
            }
            emit(.settings); emit(.log)
            return ["ok": true]
        }
    }

    // MARK: CLI·시험

    func scanSessionsNow() -> [String: Any] {
        call {
            guard ctx.db.setting(BrainSetting.sessionsEnabled) == "1" else { return Brain.fail("세션 기록이 꺼져 있어요.") }
            if ctx.isStopped { return Brain.fail("사서가 멈춰 있어요.") }
            let start = Date()
            var changed = false
            while true {
                let more = signals.scanSessions(budget: 0.2)
                changed = changed || signals.lastScanChanged
                if !more || Date().timeIntervalSince(start) > 120 { break }
            }
            if changed { work.refresh(changed: []); emit(.home) }
            emit(.settings)
            return ["ok": true, "sessions": signals.sessionsJSON()]
        }
    }

    func diagnostics() -> [String: Any] {
        call {
            ["ok": true, "mode": "\(mode)", "index": ctx.index != nil, "docs": ctx.docs.count,
             "signals": signals.diagnostics(), "organizer": organizer.diagnostics(), "engine": engineJSON(),
             "scopes": work.scopeDiagnostics()]
        }
    }
}

// MARK: - v0.6 T: 휴지통 · 직접 옮기기 · MCP 바로 실행 (COMMON §3 C3·C4)

extension Brain {
    private func changed() { emit(.pending); emit(.home); emit(.log) }

    func trashInfo(ids: [String]) -> [String: Any] { call { organizer.trashInfo(ids) } }

    func trashDocs(ids: [String], reason: String?) -> [String: Any] {
        call {
            let r = organizer.trashDocs(ids, origin: "user", reason: reason, mcp: false, via: "user")
            changed()
            return r
        }
    }

    func listTrash() -> [String: Any] { call { organizer.listTrash() } }

    func restoreTrash(ids: [String]?, batch: String?) -> [String: Any] {
        call {
            let r = organizer.restoreTrash(ids: ids, batch: batch)
            changed()
            return r
        }
    }

    func purgeTrash(ids: [String]) -> [String: Any] {
        call {
            let r = organizer.purgeTrash(ids: ids)
            changed()
            return r
        }
    }

    func moveDocs(ids: [String], to: String) -> [String: Any] {
        call {
            let r = organizer.directMove(ids, to: to, origin: "user", reason: nil, mcp: false)
            changed()
            return r
        }
    }

    func applyChanges(items: [[String: Any]], origin: String) -> [String: Any] {
        call {
            let r = organizer.applyChanges(items, origin: origin)
            lastPending = pendingTotal()
            changed()
            return r
        }
    }

    /// mcpDirectApply: "on" | "off" (1·0·true·false도 받는다). 바꾸면 AI 기록에 남긴다.
    fileprivate func setDirectApply(_ raw: String) -> [String: Any] {
        let v = raw.lowercased()
        let on: Bool
        switch v {
        case "on", "1", "true": on = true
        case "off", "0", "false": on = false
        default: return Brain.fail("설정 값은 on 또는 off예요.")
        }
        return sync {
            let was = ctx.db.setting(BrainSetting.mcpDirectApply) == "on"
            ctx.db.setSetting(BrainSetting.mcpDirectApply, on ? "on" : "off")
            if was != on {
                ctx.log("direct", on ? "Claude·Codex 바로 실행을 켰어요 · 승인 없이 옮기고 휴지통으로 보내요(30일 보관)" : "Claude·Codex 바로 실행을 껐어요 · 다시 정리함 승인으로 해요",
                        origin: "user")
            }
            emit(.settings); emit(.log)
            return ["ok": true, "mcpDirectApply": on ? "on" : "off"]
        }
    }
}
