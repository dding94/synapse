import Foundation

// synapse-cli — 색인·조회 헤드리스 시험 (docs/CONNECT.md §3.7). 앱과 같은 Plugins 주입을 쓴다.

Plugins.extract = { try Extractors.extract(fileAt: $0) }
Plugins.supportedExtensions = Extractors.supportedExtensions
Plugins.makeRemote = { cfg, secret in
    cfg.kind == .mcp ? AtlassianMCPConnector(config: cfg, token: secret) as RemoteConnector : AtlassianConnector(config: cfg, token: secret)
}

let usage = """
사용법: synapse-cli [--home <dir>] <명령>
  add-folder <path> [--obsidian]
  add-atlassian <site> <email> <token> [--spaces A,B] [--jql …]   (추가 후 바로 동기화)
  sources | index | stats
  view global | view overview | view cluster <묶음키> | view search <질의> | view focus <id> [--depth 2] [--hide g1,g2] [--show-done]
  doc <id>
  remove <id> | enable <id> | disable <id> | reindex [<id>]
  set-kinds <id> md,pdf|-  ·  exclude <id> 폴더1,폴더2|-  ·  details <id>
  debug unresolved-stats   (v0.6 P0: 못 찾은 [[링크]]에 번호 접두·Jira 키·정규화 제목 규칙을 돌려 how별 해결 수·남은 수·견본 출력)
  raw <id>  ·  save <id> <file> <fingerprint>  ·  ro <초> <질의> (읽기 전용 열기 시험)
  watch [초]            시작 후 이벤트 출력 (FSEvents 시험)
  bench <질의> …        검색 응답 시간(ms)
  brain workmap | workmap-detail <id> | tidy-plan | tidy-context | tidy-rules | tidy-run | tidy-decide <id> approve|reject|later|dismiss|to [폴더]
        | tidy-group <묶음> [id,id…] | tidy-undo [batch] | tidy-promote <서명> yes|no | tidy-rule <서명> auto|ask|off | tidy-ingest '<json>' [--run ID]
          (v0.9 작업 지도·정리 비서. 시험은 사본 홈·사본 폴더로. SYNAPSE_USER_HOME으로 볼트 조상 찾기 끝·~/IdeaProjects 기본을 바꾼다)
  brain home | why <id> | feedback <id> <action> [scope] | week [offset] | tickets [--mine] | map | pending | decide <id> <action> [to]
        | bundle <id> | undo [batch] | log [--limit N] | settings | set <key> <value> | scope <프로젝트> work|personal|auto | policy | approve-policy | batch
        | scan-sessions | diag | track <event> <docId> | context [now|week] | suggest <title> [--type T] [--project P] [--head 글]
        | propose '<json>' [--origin 이름] | instruction <context> [id]      (사서 .cli 모드 — 읽기 전에 동기 갱신)
        | propose-jira '<json>' [--origin 이름] [--run ID] | jira-apply <id> [--body 글] [--to 상태] | proposals <runId>
          (v0.8 Jira 제안. jira-apply는 127.0.0.1 가짜 서버 시험용 — 진짜 Atlassian 연결이 있는 홈에서는 반영하지 않아요.
           MCP 출처의 가짜 자격 증명은 SYNAPSE_CLI_MCP_CREDENTIAL(메모리 비밀 저장소일 때만)로 줘요)
        | trash-info <docId…> | trash <docId…> [--reason 글] | trash-list | restore <항목id|docId…> | restore --batch <배치>
        | purge <항목id…> | move <docId…> <폴더> | apply '<json>' [--origin 이름]
          (v0.6 휴지통·직접 옮기기·MCP 바로 실행. --index를 주면 끝난 뒤 색인을 다시 해요(원격 출처 포함).
           시험은 SYNAPSE_SYSTEM_TRASH_DIR로 macOS 휴지통 대신 폴더를 쓰세요)
  ai status | set <key> <value> | test | digest <week|tickets|home|doc|tidy> [--offset N] [--doc ID] [--run auto|force|none] [--wait]
     | task "<지시>" [--preset ID] [--doc ID] [--mode 화면] [--wait] | runs [--limit N] | run <ID> | cancel <ID>
          (v0.8 Claude 연결. 기본 홈이 아니면 시험 모드라 SYNAPSE_CLAUDE_BIN(예: dev/ai-fake/claude)이 없으면 Claude가 없어요.
           --wait 없이 실행을 시작하면 응답만 찍고, CLI가 끝날 때 그 실행은 취소돼요. --wait면 끝난 뒤 결과와 받은 이벤트를 찍어요)
"""

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

func printJSON(_ v: Any) {
    guard JSONSerialization.isValidJSONObject(v),
          let d = try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
          let s = String(data: d, encoding: .utf8) else { fail("JSON으로 바꿀 수 없는 값") }
    print(s)
}

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...(i + 1)); return v
}
func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i); return true
}

let homePath = option("--home") ?? ProcessInfo.processInfo.environment["SYNAPSE_HOME"]
    ?? (NSHomeDirectory() + "/Library/Application Support/Synapse")
let home = URL(fileURLWithPath: (homePath as NSString).expandingTildeInPath, isDirectory: true)
// v0.7: 키체인은 기본 홈(~/Library/Application Support/Synapse)에서만 쓴다. 다른 --home(시험 사본)은 메모리에 둔다 —
// 시험이 설치된 앱의 Atlassian 로그인 정보를 읽으려다 키체인 비밀번호 창을 띄우지 않게. SYNAPSE_CLI_KEYCHAIN=1이면 시험 홈에서도 키체인을 쓴다.
let cliEnv = ProcessInfo.processInfo.environment
let defaultHomePath = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Synapse", isDirectory: true).standardizedFileURL.path
let keychainOK = cliEnv["SYNAPSE_CLI_KEYCHAIN"] == "1" || home.standardizedFileURL.path == defaultHomePath
Plugins.secrets = cliEnv["SYNAPSE_CLI_MEMORY_SECRETS"] == "1" || !keychainOK ? MemorySecretStore() : KeychainSecretStore()
guard let cmd = args.first else { print(usage); exit(0) }
args.removeFirst()
let lib = Library(home: home)
// 시험용: 메모리 비밀 저장소에 토큰을 미리 넣는다 (키체인을 건드리지 않고 증분 동기화 시험)
if let tok = ProcessInfo.processInfo.environment["SYNAPSE_CLI_TOKEN"], Plugins.secrets is MemorySecretStore {
    for case let src as [String: Any] in (lib.statusJSON()["sources"] as? [Any]) ?? [] where src["kind"] as? String == "atlassian" {
        if let id = src["id"] as? String { try? Plugins.secrets.setSecret(tok, for: id) }
    }
}

func waitAsync<T>(_ body: @escaping () async throws -> T) throws -> T {
    var result: Result<T, Error>!
    let sem = DispatchSemaphore(value: 0)
    Task.detached { do { result = .success(try await body()) } catch { result = .failure(error) }; sem.signal() }
    sem.wait()
    return try result.get()
}

func stats() -> [String: Any] {
    guard let db = try? SQLiteDB(path: home.appendingPathComponent("index.sqlite").path) else { fail("색인이 없어요.") }
    var out: [String: Any] = [:]
    func scalar(_ sql: String) -> Int { var n = 0; try? db.query(sql) { n = Int($0.int(0)) }; return n }
    out["docs"] = scalar("SELECT count(*) FROM docs")
    var kinds: [String: Int] = [:], links: [String: Int] = [:], related: [String: Int] = [:]
    try? db.query("SELECT kind, count(*) FROM docs GROUP BY kind") { kinds[$0.text(0)] = Int($0.int(1)) }
    try? db.query("SELECT kind, count(*) FROM links GROUP BY kind") { links[$0.text(0)] = Int($0.int(1)) }
    try? db.query("SELECT kind, count(*) FROM related GROUP BY kind") { related[$0.text(0)] = Int($0.int(1)) }
    out["docKinds"] = kinds; out["links"] = links; out["related"] = related
    out["unresolved"] = scalar("SELECT count(*) FROM unresolved")
    out["status"] = lib.statusJSON()
    return out
}

/// `brain …` — 사서를 .cli 모드로 열어 입구(BrainAPI)를 그대로 부른다. 결과는 들여쓴 JSON. ok:false면 종료 코드 1.
func runBrain(_ rest: [String]) -> Never {
    var a = rest
    func opt(_ name: String) -> String? {
        guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
        let v = a[i + 1]; a.removeSubrange(i...(i + 1)); return v
    }
    let limit = opt("--limit").flatMap { Int($0) } ?? 100
    let type = opt("--type"), project = opt("--project"), head = opt("--head"), origin = opt("--origin") ?? "cli"
    let reason = opt("--reason"), batchArg = opt("--batch")
    let runArg = opt("--run"), bodyArg = opt("--body"), toArg = opt("--to")      // v0.8 Jira 제안
    let mine: Bool = { if let i = a.firstIndex(of: "--mine") { a.remove(at: i); return true }; return false }()
    let reindex: Bool = { if let i = a.firstIndex(of: "--index") { a.remove(at: i); return true }; return false }()
    guard let sub = a.first else { print(usage); exit(2) }
    a.removeFirst()
    let brain: BrainAPI
    do { brain = try Brain(home: home, mode: .cli, sources: { lib.sourceConfigs() }) }
    catch { fail("사서를 열 수 없어요: \(error.localizedDescription)") }
    // v0.9: 정리 비서의 '색인에서 빼기'가 출처 제외 폴더를 바꾸는 길 (앱과 같다)
    brain.setSourceExcludesUpdater { id, add, remove in
        guard let src = lib.sourceConfigs().first(where: { $0.id == id }) else { return "출처를 찾을 수 없어요." }
        var list = Indexer.excludedFolders(src)
        for x in add.map({ Indexer.nfc($0).trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) }) where !x.isEmpty && !list.contains(x) { list.append(x) }
        let drop = Set(remove.map { Indexer.nfc($0).trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) })
        list.removeAll { drop.contains($0) }
        do { _ = try lib.updateSource(id: id, includeKinds: src.includeKinds, excludeFolders: list); return nil }
        catch { return (error as? LibraryError)?.message ?? error.localizedDescription }
    }
    func need(_ n: Int) { if a.count < n { fail(usage) } }
    var out: [String: Any]
    switch sub {
    case "home": out = brain.home()
    // v0.9 작업 지도 · 정리 비서 (docs/V09.md §8)
    case "workmap": out = brain.workMap()
    case "workmap-detail": need(1); out = brain.workMapDetail(id: a[0])
    case "tidy-plan": out = brain.tidyPlan()
    case "tidy-context": out = (brain as? Brain)?.tidyContext() ?? ["ok": false]
    case "tidy-rules": out = brain.tidyRules()
    case "tidy-run": out = brain.tidyRunRules()
    case "tidy-decide": need(2); out = brain.tidyDecide(id: a[0], action: a[1], to: a.count > 2 ? a[2] : nil)
    case "tidy-group": need(1); out = brain.tidyDecideGroup(group: a[0], ids: a.count > 1 ? a[1].split(separator: ",").map(String.init) : nil)
    case "tidy-undo": out = brain.tidyUndo(batchId: a.first)
    case "tidy-promote": need(2); out = brain.tidyPromote(signature: a[0], accept: a[1] == "1" || a[1] == "yes")
    case "tidy-rule": need(2); out = brain.tidySetRule(signature: a[0], state: a[1])
    case "tidy-ingest":
        need(1)
        guard let data = a[0].data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fail("JSON 객체({summary, items, questions})가 필요해요.")
        }
        out = brain.tidyIngest(result: obj, runId: runArg)
    case "why": need(1); out = brain.why(id: a[0])
    case "feedback": need(2); out = brain.feedback(id: a[0], action: a[1], scope: a.count > 2 ? a[2] : nil)
    case "tickets": out = brain.tickets(mine: mine)
    case "week": out = brain.week(offset: a.first.flatMap { Int($0) } ?? 0)
    case "map": out = brain.map()
    case "pending": out = brain.pending()
    case "decide": need(2); out = brain.decide(id: a[0], action: a[1], to: a.count > 2 ? a[2] : nil)
    case "bundle": need(1); out = brain.decideBundle(id: a[0])
    case "undo": out = brain.undo(batchId: a.first)
    case "log": out = brain.aiLog(limit: limit)
    case "settings": out = brain.settings()
    case "set": need(2); out = brain.setSetting(key: a[0], value: a[1])
    case "scope": need(2); out = brain.setProjectScope(project: a[0], scope: a[1])   // v0.7 B: brain scope <프로젝트> work|personal|auto
    case "policy": out = brain.policy()
    case "approve-policy": out = brain.approvePolicy()
    case "batch": out = brain.runBatchNow()
    case "scan-sessions": out = brain.scanSessionsNow()
    case "diag": out = brain.diagnostics()
    case "track":
        need(2)
        guard ["open", "view", "edit", "save"].contains(a[0]) else { fail("event는 open · view · edit · save 중 하나예요.") }
        brain.track(event: a[0], docId: a[1])
        out = ["ok": true]
    case "context": out = brain.workContext(period: a.first == "week" ? "week" : "now")
    case "suggest":
        need(1)
        var args: [String: Any] = ["title": a.joined(separator: " ")]
        if let t = type { args["type"] = t }
        if let p = project { args["project"] = p }
        if let h = head { args["content_head"] = String(h.prefix(2000)) }
        out = brain.suggestLocation(args)
    case "propose":
        need(1)
        guard let data = a[0].data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) else { fail("JSON을 읽을 수 없어요.") }
        let items = (obj as? [[String: Any]]) ?? ((obj as? [String: Any])?["items"] as? [[String: Any]])
        guard let list = items else { fail("제안 목록([…] 또는 {\"items\": […]})이 필요해요.") }
        out = brain.proposeChanges(items: list, origin: origin)
    case "instruction": need(1); out = brain.claudeInstruction(context: a[0], id: a.count > 1 ? a[1] : nil)
    // v0.6 T: 휴지통 · 직접 옮기기 · MCP 바로 실행
    case "trash-info": need(1); out = brain.trashInfo(ids: a)
    case "trash": need(1); out = brain.trashDocs(ids: a, reason: reason)
    case "trash-list": out = brain.listTrash()
    case "restore":
        if batchArg == nil { need(1) }
        out = brain.restoreTrash(ids: batchArg == nil ? a : nil, batch: batchArg)
    case "purge": need(1); out = brain.purgeTrash(ids: a)
    case "move": need(2); out = brain.moveDocs(ids: Array(a.dropLast()), to: a[a.count - 1])
    case "apply":
        need(1)
        guard let data = a[0].data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) else { fail("JSON을 읽을 수 없어요.") }
        let items = (obj as? [[String: Any]]) ?? ((obj as? [String: Any])?["items"] as? [[String: Any]])
        guard let list = items else { fail("항목 목록([…] 또는 {\"items\": […]})이 필요해요.") }
        out = brain.applyChanges(items: list, origin: origin)
    // v0.8 Jira 제안 (docs/V08.md §6)
    case "propose-jira":
        need(1)
        guard let data = a[0].data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) else { fail("JSON을 읽을 수 없어요.") }
        let items = (obj as? [[String: Any]]) ?? ((obj as? [String: Any])?["items"] as? [[String: Any]])
        guard let list = items else { fail("제안 목록([…] 또는 {\"items\": […]})이 필요해요.") }
        out = brain.proposeJira(items: list, origin: origin, runId: runArg)
    case "jira-apply":
        need(1)
        // 시험용 명령: 연결된 원격 출처가 모두 127.0.0.1·localhost 가짜 서버일 때만 반영한다(진짜 Jira를 바꾸지 않게).
        for s in lib.sourceConfigs() where s.kind == .mcp || s.kind == .atlassian {
            let raw = (s.mcpURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let host = s.kind == .mcp ? URL(string: raw.isEmpty ? AtlassianMCPConnector.defaultServer : raw)?.host
                                      : AtlassianConnector.normalizedSite(s.site ?? "")?.host
            if !(host.map { MCPHTTP.isLoopback($0) } ?? false) {
                fail("synapse-cli jira-apply는 가짜 서버(127.0.0.1) 시험용이에요. 진짜 Atlassian 연결(\(s.name))이 있는 홈에서는 반영하지 않아요.")
            }
        }
        // MCP 출처의 가짜 자격 증명(메모리 비밀 저장소일 때만 — 키체인은 건드리지 않는다)
        if let cred = cliEnv["SYNAPSE_CLI_MCP_CREDENTIAL"], !cred.isEmpty, Plugins.secrets is MemorySecretStore {
            for s in lib.sourceConfigs() where s.kind == .mcp { try? Plugins.secrets.setSecret(cred, for: s.id) }
        }
        var overrides: [String: Any] = [:]
        if let b = bodyArg { overrides["body"] = b }
        if let t = toArg { overrides["to"] = t }
        let id = a[0]
        out = (try? waitAsync { await JiraApply.run(brain: brain, library: lib, id: id, overrides: overrides) }) ?? ["ok": false, "error": "반영하지 못했어요."]
    case "proposals":
        need(1)
        out = ["ok": true, "run": a[0], "proposals": brain.proposals(run: a[0])]
    default: print(usage); exit(2)
    }
    if reindex { lib.indexAllAndWait() }
    printJSON(out)
    exit((out["ok"] as? Bool) == false ? 1 : 0)
}

/// `ai …` — v0.8 Claude 연결 (docs/V08.md §4). 앱과 같은 AIService(사서 .cli + SynapseDigests)를 만들어 부른다. 결과는 들여쓴 JSON,
/// ok:false면 종료 코드 1. 기본 홈이 아니면 시험 모드다 — SYNAPSE_CLAUDE_BIN이 없으면 Claude가 없는 것으로 본다.
/// synapse-mcp는 이 실행 파일 옆, 없으면 ./build/synapse-mcp를 쓴다.
func runAI(_ rest: [String]) -> Never {
    var a = rest
    func opt(_ name: String) -> String? {
        guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
        let v = a[i + 1]; a.removeSubrange(i...(i + 1)); return v
    }
    func has(_ name: String) -> Bool {
        guard let i = a.firstIndex(of: name) else { return false }
        a.remove(at: i); return true
    }
    let wait = has("--wait")
    let offset = opt("--offset").flatMap { Int($0) }
    let docId = opt("--doc"), preset = opt("--preset"), screen = opt("--mode")
    let runMode = opt("--run") ?? "auto"
    let limit = opt("--limit").flatMap { Int($0) } ?? 20
    guard let sub = a.first else { print(usage); exit(2) }
    a.removeFirst()
    let brain: Brain? = try? Brain(home: home, mode: .cli, sources: { lib.sourceConfigs() })
    let exe = Bundle.main.executableURL?.resolvingSymlinksInPath()
    let mcp = [exe?.deletingLastPathComponent().appendingPathComponent("synapse-mcp"),
               URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/synapse-mcp")]
        .compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    let ai = AIService(home: home, brain: brain, digests: SynapseDigests(brain: brain, library: lib), mcpBinary: mcp,
                       testMode: home.standardizedFileURL.path != defaultHomePath)
    var events: [[String: Any]] = []
    ai.onEvent = { e in events.append(e.json ?? ["type": "proposals"]) }   // 메인 큐 — 기다리는 동안 RunLoop로 받는다
    // v0.9: 앱처럼 Claude 정리 계획(tidy)을 정리 비서 제안으로 넣는다. 결과는 digest 출력의 ingested에.
    let ingestLock = NSLock()
    var ingested: [String: Any]? = nil
    ai.onDigestResult = { kind, _, result, runId in
        guard kind == "tidy", let b = brain else { return }
        let r = b.tidyIngest(result: result, runId: runId)
        ingestLock.lock(); ingested = r; ingestLock.unlock()
    }
    func waitFor(_ runId: String) {
        while (ai.run(id: runId)["run"] as? [String: Any])?["status"] as? String == "running" {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }
    func need(_ n: Int) { if a.count < n { fail(usage) } }
    var out: [String: Any]
    switch sub {
    case "status": out = ai.status()
    case "set": need(2); out = ai.setSetting(key: a[0], value: a[1])
    case "test":
        let sem = DispatchSemaphore(value: 0)
        var res: [String: Any] = [:]
        ai.test { res = $0; sem.signal() }
        sem.wait()
        out = res
    case "digest":
        need(1)
        out = ai.digest(kind: a[0], offset: offset, docId: docId, run: runMode)
        if wait, let runId = out["runId"] as? String {
            waitFor(runId)
            if a[0] == "tidy" {      // 저장 뒤 ingest가 끝날 때까지 (최대 5초)
                let until = Date().addingTimeInterval(5)
                while Date() < until { ingestLock.lock(); let got = ingested != nil; ingestLock.unlock(); if got { break }; RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
            }
            out = ai.digest(kind: a[0], offset: offset, docId: docId, run: "none")
            out["run"] = ai.run(id: runId)["run"] ?? NSNull()
            out["events"] = events
            ingestLock.lock(); if let g = ingested { out["ingested"] = g }; ingestLock.unlock()
        }
    case "task":
        var context: [String: Any] = [:]
        if let d = docId { context["docId"] = d; context["title"] = lib.documentJSON(id: d).flatMap { ($0["doc"] as? [String: Any])?["title"] } }
        if let m = screen { context["mode"] = m }
        if let o = offset { context["offset"] = o }
        out = ai.startTask(prompt: a.joined(separator: " "), preset: preset, context: context)
        if wait, let runId = out["runId"] as? String {
            waitFor(runId)
            var done = ai.run(id: runId)
            if let d = out["digest"] { done["digest"] = d }
            done["events"] = events
            out = done
        }
    case "runs": out = ai.runs(limit: limit)
    case "run": need(1); out = ai.run(id: a[0])
    case "cancel": need(1); out = ai.cancel(runId: a[0])
    default: print(usage); exit(2)
    }
    ai.shutdown()
    printJSON(out)
    exit((out["ok"] as? Bool) == false ? 1 : 0)
}

switch cmd {
case "ai":
    runAI(args)
case "brain":
    runBrain(args)
case "add-folder":
    let obsidian = flag("--obsidian")
    guard let path = args.first else { fail(usage) }
    do { printJSON(try lib.addFolder(path: path, obsidian: obsidian)) } catch { fail(error.localizedDescription) }
case "add-atlassian":
    let spaces = option("--spaces")?.split(separator: ",").map(String.init)
    let jql = option("--jql")
    guard args.count >= 3 else { fail(usage) }
    let (site, email, token) = (args[0], args[1], args[2])
    do {
        let entry = try waitAsync { try await lib.addAtlassian(site: site, email: email, token: token, spaces: spaces, jql: jql) }
        lib.indexAllAndWait()
        printJSON(["added": entry, "status": lib.statusJSON()])
    } catch { fail(error.localizedDescription) }
case "sources":
    printJSON(lib.statusJSON())
case "index":
    let t0 = Date()
    lib.indexAllAndWait()
    var s = stats()
    s["seconds"] = (Date().timeIntervalSince(t0) * 1000).rounded() / 1000
    printJSON(s)
case "reindex":
    lib.start()
    lib.reindex(id: args.first)
    Thread.sleep(forTimeInterval: 0.3)
    lib.indexAllAndWait()
    printJSON(stats())
case "stats":
    printJSON(stats())
case "view":
    guard let mode = args.first else { fail(usage) }
    var p: [String: Any] = ["mode": mode]
    if let d = option("--depth") { p["depth"] = Int(d) ?? 1 }
    if let h = option("--hide") { p["hiddenGroups"] = h.split(separator: ",").map(String.init) }
    if mode == "search" { p["query"] = args.dropFirst().joined(separator: " ") }
    if mode == "focus" { guard args.count > 1 else { fail(usage) }; p["focusId"] = args[1] }
    if mode == "cluster" { guard args.count > 1 else { fail(usage) }; p["cluster"] = args[1] }
    if flag("--show-done") { p["showDone"] = true }
    printJSON(lib.viewJSON(p))
case "doc":
    guard let id = args.first else { fail(usage) }
    guard let d = lib.documentJSON(id: id) else { fail("문서를 찾을 수 없어요.") }
    printJSON(d)
case "remove", "enable", "disable":
    guard let id = args.first else { fail(usage) }
    if cmd == "remove" { lib.removeSource(id: id) } else { lib.setSourceEnabled(id: id, enabled: cmd == "enable") }
    lib.indexAllAndWait()
    printJSON(lib.statusJSON())
case "watch":
    let seconds = Double(args.first ?? "30") ?? 30
    let t0 = Date()
    lib.onEvent = { e in
        let t = String(format: "%.2f", Date().timeIntervalSince(t0))
        switch e {
        case .progress(let id, let done, let total, let phase): print("[\(t)] progress \(id.prefix(8)) \(phase) \(done)/\(total)")
        case .changed(let reason): print("[\(t)] changed \(reason) docs=\(lib.statusJSON()["docCount"] ?? 0)")
        case .sourceError(let id, let msg): print("[\(t)] error \(id.prefix(8)) \(msg)")
        }
        fflush(stdout)
    }
    lib.start()
    print("watching \(seconds)s"); fflush(stdout)
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    lib.stop()
case "set-kinds", "exclude":
    guard args.count >= 1 else { fail(usage) }
    let id = args[0]
    let list: [String]? = args.count > 1 && args[1] != "-" ? args[1].split(separator: ",").map(String.init) : nil
    let cur = (lib.statusJSON()["sources"] as? [[String: Any]])?.first { $0["id"] as? String == id }
    if cur == nil { fail("자료를 찾을 수 없어요.") }
    let cfg = lib.sourceConfigForCLI(id: id)
    do {
        let entry = cmd == "set-kinds"
            ? try lib.updateSource(id: id, includeKinds: list, excludeFolders: cfg?.excludeFolders)
            : try lib.updateSource(id: id, includeKinds: cfg?.includeKinds, excludeFolders: list)
        Thread.sleep(forTimeInterval: 0.2)
        lib.indexAllAndWait()
        var out = stats(); out["updated"] = entry
        printJSON(out)
    } catch { fail(error.localizedDescription) }
case "debug":
    if args.first == "remote-md", args.count >= 2 {     // v0.7 D: 원격 문서의 표 되살리기 확인 — debug remote-md <docId>
        guard let d = lib.documentJSON(id: args[1]) else { fail("문서를 찾을 수 없어요.") }
        print((d["markdown"] as? String) ?? "(markdown 없음)")
        break
    }
    guard args.first == "unresolved-stats" else { fail(usage) }
    printJSON(lib.unresolvedStatsJSON())
case "details":
    guard let id = args.first else { fail(usage) }
    printJSON(lib.sourceDetailsJSON(id: id))
case "raw":
    guard let id = args.first else { fail(usage) }
    do { printJSON(try lib.readRawJSON(id: id)) } catch { fail(error.localizedDescription) }
case "save":
    guard args.count >= 3 else { fail(usage) }
    guard let text = try? String(contentsOfFile: args[1], encoding: .utf8) else { fail("저장할 내용을 읽을 수 없어요.") }
    do {
        let r = try lib.saveRaw(id: args[0], text: text, fingerprint: args[2])
        lib.indexAllAndWait()     // 비동기 재색인이 끝날 때까지 (CLI가 먼저 끝나지 않게)
        printJSON(r)
    } catch { fail(error.localizedDescription) }
case "ro":
    // 읽기 전용 열기 시험: ro <초> <질의> — 시작 시 한 번, 끝날 때 refreshIfChanged 뒤 다시 검색
    let secs = Double(args.first ?? "0") ?? 0
    let q = args.dropFirst().joined(separator: " ")
    do {
        let ro = try Library.openReadOnly(home: home)
        func count() -> Int { ((ro.viewJSON(["mode": "search", "query": q])["sections"] as? [[String: Any]])?.first?["items"] as? [Any])?.count ?? 0 }
        print("before: docs=\(ro.statusJSON()["docCount"] ?? 0) hits=\(count())"); fflush(stdout)
        Thread.sleep(forTimeInterval: secs)
        print("refresh: \(ro.refreshIfChanged()) docs=\(ro.statusJSON()["docCount"] ?? 0) hits=\(count())")
    } catch { fail(error.localizedDescription) }
case "bench":
    let queries = args.isEmpty ? ["회의록"] : args
    var out: [[String: Any]] = []
    for q in queries {
        _ = lib.viewJSON(["mode": "search", "query": q])
        var times: [Double] = []
        var count = 0
        for _ in 0..<20 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let v = lib.viewJSON(["mode": "search", "query": q])
            times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            count = ((v["sections"] as? [[String: Any]])?.first?["items"] as? [Any])?.count ?? 0
        }
        times.sort()
        out.append(["query": q, "results": count, "medianMs": (times[10] * 100).rounded() / 100, "maxMs": (times.last! * 100).rounded() / 100])
    }
    for mode in ["global"] {
        let t0 = DispatchTime.now().uptimeNanoseconds
        _ = lib.viewJSON(["mode": mode])
        out.append(["view": mode, "ms": (Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e4).rounded() / 100])
    }
    printJSON(out)
default:
    print(usage)
    exit(2)
}
