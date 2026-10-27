import Foundation

// synapse-mcp — Synapse 색인·사서를 MCP(Model Context Protocol) 서버로 노출한다 (docs/V04.md §5, docs/V05.md §7).
// stdio JSON-RPC 2.0, 한 줄에 메시지 하나. 로그는 stderr만. 색인은 읽기만 한다.
// 기본은 propose_changes가 사서 제안함(brain.sqlite)에 이동·삭제 제안을 올리는 것뿐이다 — 승인·적용은 사용자가 Synapse 앱에서 한다.
// v0.6: 사용자가 Synapse 설정에서 '바로 실행'(mcpDirectApply)을 켰을 때만 apply_changes가 같은 검사·링크 고침·AI 기록·되돌리기로
// 바로 옮기고 Synapse 휴지통(30일 보관)으로 보낸다. 영구 삭제는 없다.
// 앱이 꺼져 있어도 디스크의 색인(SYNAPSE_HOME 또는 ~/Library/Application Support/Synapse)으로 동작한다.
// 세션 기록(요청 문장·세션 제목 등)은 어떤 응답에도 넣지 않는다. Confluence·Jira 본문은 설정(mcp.remoteBodies)이 켜져야 보인다.
// v0.8: get_tickets(열린 Jira 티켓)·propose_jira_changes(Jira 변경 제안 — 사용자가 Synapse에서 승인해야 반영). Jira에 직접 쓰지 않는다.
// 환경 SYNAPSE_RUN_ID(Synapse에서 띄운 Claude 실행 id)는 제안의 run으로, SYNAPSE_MCP_ORIGIN은 clientInfo.name보다 먼저 제안 출처로 쓴다.

signal(SIGPIPE, SIG_IGN)
// 프로토콜 출력용으로 원래 stdout을 복제하고, 1번 fd는 stderr로 돌려 둔다(라이브러리가 실수로 print해도 프로토콜을 깨지 않게).
let outFD = dup(1)
dup2(2, 1)
guard let outFile = fdopen(outFD, "w") else { exit(1) }

func log(_ s: String) { FileHandle.standardError.write(("[synapse-mcp] " + s + "\n").data(using: .utf8)!) }

typealias JSON = [String: Any]

func encode(_ v: Any) -> String? {
    guard JSONSerialization.isValidJSONObject(v),
          let d = try? JSONSerialization.data(withJSONObject: v, options: [.withoutEscapingSlashes]) else { return nil }
    return String(data: d, encoding: .utf8)
}

func send(_ v: Any) {
    guard let s = encode(v) else { log("직렬화 실패"); return }
    // JSONSerialization은 줄바꿈을 \n 으로 이스케이프하므로 한 줄이 보장된다.
    if fputs(s + "\n", outFile) < 0 || fflush(outFile) != 0 { exit(0) }   // 클라이언트가 떠났다
}

// MARK: - 상수

let serverVersion = "0.9.0"
let preferredProtocol = "2025-06-18"
let supportedProtocols: Set<String> = ["2025-06-18", "2025-03-26", "2024-11-05"]
let maxNoteChars = 20_000

let instructions = """
Synapse는 사용자의 개인 노트·문서(옵시디언 볼트, 폴더의 md·txt·pdf·docx·hwpx 등, Confluence·Jira)를 이 Mac 안에서 색인한 검색 도구예요. 자료는 밖으로 나가지 않고, 파일은 읽기만 해요. 사용자가 "내 노트에서", "예전에 정리한", "우리 문서에" 처럼 자기 자료를 가리키거나, 개인 메모·회의록·프로젝트 맥락이 필요할 때 쓰세요. 먼저 search_notes로 찾고(한국어 조사·초성·동의어 지원), 결과의 id로 get_note(본문)와 related_notes(연결된 문서)를 부르세요. 최근 작업은 recent_notes, 연결된 자료 현황은 list_sources예요. 결과가 없으면 다른 표현·핵심 단어로 다시 검색하세요. 사용자가 하던 일·할 일은 get_work_context, 폴더 규칙은 get_vault_policy, 자리가 정해지지 않은 문서는 list_pending, 문서를 어디에 둘지는 suggest_location으로 보세요. 문서를 옮기거나 지우고 싶으면 파일을 직접 건드리지 말고 propose_changes로 제안을 올리세요(move·delete) — 승인은 사용자가 Synapse 정리함에서 해요. 사용자가 Synapse 설정에서 '바로 실행'을 켰다면 정말 필요할 때만 apply_changes로 바로 옮기거나 Synapse 휴지통(30일 보관, 되돌리기 가능)으로 보낼 수 있어요. 열린 Jira 티켓은 get_tickets로 보고, 상태 바꾸기·댓글·새 티켓은 propose_jira_changes로 제안만 올리세요 — Jira는 사용자가 Synapse에서 승인해야 바뀌어요. Confluence·Jira 본문은 사용자가 설정에서 허용해야 보여요(결과의 origin이 confluence·jira인 문서).

Synapse is an on-device index of the user's personal notes and documents (Obsidian vaults, folders with md/txt/pdf/docx/hwpx, Confluence and Jira). Nothing leaves this Mac and files are only read. Use it when the user refers to their own notes ("in my notes", "what I wrote before", "our docs") or when personal context, meeting notes or project history would help. Start with search_notes (Korean particles, choseong and synonyms are handled), then pass a result id to get_note (full text) or related_notes (linked documents). Use recent_notes for latest activity and list_sources to see what is connected. If nothing is found, retry with different or shorter keywords. For what the user has been working on and their open tasks use get_work_context; for the vault's folder rules get_vault_policy; for documents with no settled home list_pending; for where a document belongs suggest_location. To move or delete a document never touch the file: submit a proposal with propose_changes (move or delete) and the user approves it in Synapse's queue. Only if the user turned on "direct apply" in Synapse settings, and only when really needed, apply_changes moves documents or sends them to Synapse's trash (kept 30 days, undoable) right away. For open Jira tickets use get_tickets; to change a status, comment or create a ticket submit a proposal with propose_jira_changes — Jira only changes after the user approves it in Synapse. Confluence and Jira bodies are hidden unless the user allows them in settings (documents whose origin is confluence or jira).
"""

// MARK: - 도구 정의

func prop(_ type: String, _ ko: String, _ en: String, extra: JSON = [:]) -> JSON {
    var p: JSON = ["type": type, "description": ko + "\n" + en]
    for (k, v) in extra { p[k] = v }
    return p
}

let readOnly: JSON = ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]
/// propose_changes: 파일을 바꾸지 않는다(제안함에 한 줄 올릴 뿐). 쓰기 도구지만 파괴적이지 않다.
let proposeOnly: JSON = ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false]
/// apply_changes: 설정이 켜져 있으면 파일을 옮기고 Synapse 휴지통으로 보낸다(되돌릴 수 있지만 파괴적으로 표시한다).
let directApply: JSON = ["readOnlyHint": false, "destructiveHint": true, "idempotentHint": false, "openWorldHint": false]

/// propose_changes·apply_changes 항목 스키마.
func changeItems(_ kinds: [String], _ ko: String, _ en: String) -> JSON {
    prop("array", ko, en, extra: ["minItems": 1, "maxItems": 20,
        "items": ["type": "object",
                  "properties": [
                      "kind": ["type": "string", "enum": kinds] as JSON,
                      "path": ["type": "string", "description": "move·delete: 볼트 상대 또는 절대 경로 / vault-relative or absolute path"] as JSON,
                      "doc_id": ["type": "string", "description": "move·delete: search_notes 등이 돌려준 문서 id / document id"] as JSON,
                      "to": ["type": "string", "description": "move: 목적지 폴더 (볼트 상대, 이미 있는 폴더) / existing destination folder"] as JSON,
                      "reason": ["type": "string", "description": "move·delete: 이유 한 줄 / one-line reason"] as JSON,
                      "rules": ["type": "array", "description": "rules: [{kind, pattern, target, note}]", "items": ["type": "object"] as JSON] as JSON,
                      "id": ["type": "string", "description": "withdraw: 거둘 제안 id / proposal id"] as JSON,
                  ].filter { k, _ in kinds.contains("rules") || !["rules", "id"].contains(k) } as JSON,
                  "required": ["kind"], "additionalProperties": false] as JSON])
}

/// v0.8 propose_jira_changes 항목 스키마 (docs/V08.md §6.4).
let jiraItems: JSON = prop("array", "Jira 변경 제안 목록 (10개 이하)", "Jira change proposals (at most 10)", extra: ["minItems": 1, "maxItems": 10,
    "items": ["type": "object",
              "properties": [
                  "op": ["type": "string", "enum": ["transition", "comment", "create"]] as JSON,
                  "key": ["type": "string", "description": "transition·comment: Jira 키 (get_tickets·search_notes가 돌려준 것, 예: PROJ-123) / issue key"] as JSON,
                  "doc_id": ["type": "string", "description": "transition·comment (선택): get_tickets의 docId — 같은 키가 여러 사이트에 있을 때 / docId when the same key exists on several sites"] as JSON,
                  "to": ["type": "string", "maxLength": 100, "description": "transition: 바꿀 상태 이름 (예: 진행 중, 완료) / target status name"] as JSON,
                  "body": ["type": "string", "maxLength": 4000, "description": "comment: 댓글 (마크다운, 4000자 이하) / comment text in markdown"] as JSON,
                  "project": ["type": "string", "description": "create: 프로젝트 키 (예: PROJ) / project key"] as JSON,
                  "issue_type": ["type": "string", "maxLength": 50, "description": "create: 유형 (기본 작업, 반영할 때 프로젝트 유형과 맞춰요) / issue type (default 작업/Task)"] as JSON,
                  "summary": ["type": "string", "maxLength": 200, "description": "create: 요약 한 줄 (200자 이하) / one-line summary"] as JSON,
                  "description": ["type": "string", "maxLength": 8000, "description": "create: 설명 (마크다운, 8000자 이하) / description in markdown"] as JSON,
                  "reason": ["type": "string", "maxLength": 200, "description": "이유 한 줄 (사용자가 승인할 때 봐요) / one-line reason shown to the user"] as JSON,
              ] as JSON,
              "required": ["op"], "additionalProperties": false] as JSON])

func tool(_ name: String, _ title: String, _ ko: String, _ en: String, _ props: JSON, required: [String],
          annotations: JSON? = nil) -> JSON {
    ["name": name, "title": title, "description": ko + "\n" + en,
     "inputSchema": ["type": "object", "properties": props, "required": required, "additionalProperties": false] as JSON,
     "annotations": (annotations ?? readOnly).merging(["title": title]) { a, _ in a }]
}

let toolList: [JSON] = [
    tool("search_notes", "Synapse 노트 검색",
         "사용자의 개인 노트·문서(옵시디언 볼트, 폴더, Confluence·Jira)를 한국어로 검색해요. 조사(회의록을→회의록)·초성(ㅎㅇㄹ)·동의어를 이해해요. 결과의 id를 get_note·related_notes에 넘길 수 있어요.",
         "Search the user's personal notes and documents (Obsidian vaults, folders, Confluence, Jira), Korean-aware: particles, choseong, synonyms. Returns ids usable with get_note / related_notes.",
         ["query": prop("string", "검색어 (예: 회의록을, 배포 일정, ㅎㅇㄹ)", "Search query, e.g. a keyword or phrase", extra: ["minLength": 1]),
          "limit": prop("integer", "최대 결과 수 (기본 10, 최대 30)", "Max results (default 10, max 30)", extra: ["minimum": 1, "maximum": 30, "default": 10])],
         required: ["query"]),
    tool("get_note", "노트 본문 읽기",
         "id로 문서 하나의 제목·경로·출처·본문(최대 20,000자)과 나가는/들어오는 연결, 자동 연결(이유 포함)을 가져와요.",
         "Fetch one document by id: title, path, source, full text (up to 20,000 chars) and its outgoing/incoming/automatic links with reasons.",
         ["id": prop("string", "search_notes 등이 돌려준 문서 id", "Document id returned by search_notes, related_notes or recent_notes")],
         required: ["id"]),
    tool("related_notes", "연결된 노트",
         "문서 하나를 중심으로 이어진 문서(링크·본문 언급·이슈·같은 태그·자동 연결, depth 2면 두 단계 연결)를 보여줘요.",
         "Show documents connected to one document (links, mentions, issues, shared tags, automatic relations; depth 2 adds two-hop neighbours).",
         ["id": prop("string", "중심 문서 id", "Center document id"),
          "depth": prop("integer", "연결 단계 (1 또는 2, 기본 1)", "Hops (1 or 2, default 1)", extra: ["minimum": 1, "maximum": 2, "default": 1]),
          "limit": prop("integer", "최대 결과 수 (기본 20, 최대 50)", "Max results (default 20, max 50)", extra: ["minimum": 1, "maximum": 50, "default": 20])],
         required: ["id"]),
    tool("recent_notes", "최근 수정한 노트",
         "최근에 수정된 문서를 최신순으로 보여줘요. 사용자가 요즘 무엇을 했는지 파악할 때 좋아요.",
         "List the most recently modified documents, newest first. Good for catching up on what the user worked on lately.",
         ["limit": prop("integer", "최대 결과 수 (기본 20, 최대 50)", "Max results (default 20, max 50)", extra: ["minimum": 1, "maximum": 50, "default": 20])],
         required: []),
    tool("list_sources", "연결된 자료 출처",
         "Synapse에 연결된 출처(폴더·옵시디언 볼트·Confluence·Jira)와 문서 수, 색인 상태를 보여줘요.",
         "List the sources connected to Synapse with document counts and indexing state.",
         [:], required: []),
    tool("get_work_context", "작업 맥락",
         "사용자가 지금 하던 일을 흐름(스레드)·열린 할 일·다음 할 일로 가져와요. period를 week로 주면 이번 주 활동이에요. 세션 대화 내용은 들어 있지 않아요.",
         "What the user is working on: threads, open tasks and what is next (period \"now\"), or this week's activity (period \"week\"). Contains no chat or session text.",
         ["period": prop("string", "now(기본) 또는 week", "\"now\" (default) or \"week\"", extra: ["enum": ["now", "week"], "default": "now"])],
         required: []),
    tool("get_tickets", "열린 Jira 티켓",
         "열린 Jira 티켓(막힘·진행 중·할 일)을 키·제목·상태·우선순위·담당·진행 일수·갱신·오래 멈춤·기한과 함께 보여줘요. mine=true면 내 담당만, groups로 상태 묶음을 고를 수 있어요. 결과의 key를 propose_jira_changes에 넘길 수 있어요.",
         "List open Jira tickets (blocked, in progress, to do) with key, title, status, priority, assignee, days in status, last update, stale flag and due date. mine=true limits to the user's own tickets; groups filters status groups. Pass a key to propose_jira_changes.",
         ["mine": prop("boolean", "내 담당만 (기본 false)", "Only tickets assigned to the user (default false)", extra: ["default": false]),
          "groups": prop("array", "상태 묶음 (기본 전부)", "Status groups to include (default all)",
                         extra: ["items": ["type": "string", "enum": ["blocked", "doing", "todo"]] as JSON, "uniqueItems": true]),
          "limit": prop("integer", "최대 결과 수 (기본 80, 최대 200)", "Max results (default 80, max 200)", extra: ["minimum": 1, "maximum": 200, "default": 80])],
         required: []),
    tool("get_vault_policy", "볼트 정리 규칙",
         "볼트 루트 CLAUDE.md에서 뽑은 폴더 규칙표(rules), 건드리면 안 되는 곳(frozen·exclude), 새 문서가 놓이는 곳(landing), 폴더 현황, 규칙을 어긴 곳(violations)을 보여줘요.",
         "The vault's folder policy distilled from the root CLAUDE.md: rules, frozen and excluded paths, landing folders, folder counts and violations.",
         [:], required: []),
    tool("list_pending", "자리가 정해지지 않은 문서",
         "아직 제자리를 찾지 못한 문서(unsorted)와 최근 30일의 정리 제안(proposals: 이동·삭제) 현황, Synapse 휴지통 수, 바로 실행 설정을 보여줘요.",
         "Documents with no settled home yet (unsorted, with candidate folders), the last 30 days of move/delete proposals with their state, the Synapse trash count and whether direct apply is on.",
         [:], required: []),
    tool("suggest_location", "문서 둘 곳 추천",
         "제목(과 유형·프로젝트·앞부분)으로 이 문서를 볼트의 어느 폴더에 두면 좋을지 규칙표 기준으로 추천해요. 읽기만 하고 제안함에는 남기지 않아요.",
         "Recommend which vault folder a document should live in, from its title (and optionally type, project, first lines). Read-only: nothing is queued.",
         ["title": prop("string", "문서 제목", "Document title", extra: ["minLength": 1]),
          "type": prop("string", "문서 유형 (선택)", "Document type (optional)"),
          "project": prop("string", "프로젝트 이름 (선택)", "Project name (optional)"),
          "content_head": prop("string", "본문 앞부분 (선택, 2000자까지)", "First lines of the content (optional, up to 2000 chars)", extra: ["maxLength": 2000])],
         required: ["title"]),
    tool("propose_changes", "정리 제안 올리기",
         "문서 이동·삭제나 규칙표 수정을 제안으로 올려요(최대 20개). 파일은 바뀌지 않고, 사용자가 Synapse 정리함에서 승인해야 적용돼요. 삭제를 승인하면 Synapse 휴지통에 30일 보관돼요. kind: move(path 또는 doc_id + to + reason), delete(path 또는 doc_id + reason), rules(rules 목록), withdraw(id).",
         "Submit move, delete or policy-rule proposals (max 20). Nothing changes on disk: the user must approve each one in Synapse's queue; an approved delete goes to Synapse's trash for 30 days. kind: move (path or doc_id + to + reason), delete (path or doc_id + reason), rules (rules list), withdraw (id).",
         ["items": changeItems(["move", "delete", "rules", "withdraw"], "제안 목록 (20개 이하)", "Proposals (at most 20)")],
         required: ["items"], annotations: proposeOnly),
    tool("propose_jira_changes", "Jira 변경 제안 올리기",
         "Jira 티켓 상태 바꾸기·댓글·새 티켓을 제안으로 올려요(최대 10개). Jira는 바로 바뀌지 않고, 사용자가 Synapse 정리함에서 승인해야 반영돼요. op: transition(key + to + reason), comment(key + body + reason), create(project + summary + description? + issue_type? + reason). key는 get_tickets·search_notes가 돌려준 색인의 Jira 키만 받아요. 같은 티켓의 같은 제안이 대기 중이면 새 제안으로 바꿔 끼워요.",
         "Submit Jira proposals (max 10): change a status, add a comment or create a ticket. Nothing changes in Jira until the user approves each one in Synapse's queue. op: transition (key + to + reason), comment (key + body + reason), create (project + summary + description? + issue_type? + reason). Only keys already indexed by Synapse (from get_tickets or search_notes) are accepted. A pending proposal of the same kind for the same ticket is replaced.",
         ["items": jiraItems], required: ["items"], annotations: proposeOnly),
    tool("apply_changes", "바로 옮기기·휴지통",
         "사용자가 Synapse 설정에서 'Claude·Codex가 바로 정리'를 켰을 때만, 승인 없이 바로 옮기거나 Synapse 휴지통(30일 보관)으로 보내요. 꺼져 있으면 아무것도 하지 않아요 — 그때는 propose_changes를 쓰세요. 검사·링크 고침·AI 기록은 승인할 때와 같고, 사용자가 Synapse AI 기록에서 되돌릴 수 있어요. 동결·제외 구역, CLAUDE.md·PROGRESS.md·_Templates는 건드리지 않아요. 하루 60건까지(넘으면 제안으로 올려요). 정말 필요할 때만 쓰세요. kind: move(path 또는 doc_id + to + reason), delete(path 또는 doc_id + reason).",
         "Only when the user turned on direct apply in Synapse settings: move documents or send them to Synapse's trash (kept 30 days) without approval. When it is off nothing happens - use propose_changes instead. Same checks, link fixes and activity log as an approved change, and the user can undo it from Synapse's AI log. Frozen/excluded areas and CLAUDE.md, PROGRESS.md, _Templates are refused. Up to 60 per day (the rest become proposals). Use only when really needed. kind: move (path or doc_id + to + reason), delete (path or doc_id + reason).",
         ["items": changeItems(["move", "delete"], "바꿀 목록 (20개 이하)", "Changes (at most 20)")],
         required: ["items"], annotations: directApply),
]

// MARK: - 라이브러리 접근

let homeURL: URL = {
    if let h = ProcessInfo.processInfo.environment["SYNAPSE_HOME"], !h.isEmpty {
        return URL(fileURLWithPath: (h as NSString).expandingTildeInPath, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Synapse", isDirectory: true)
}()

let notReadyMessage = "Synapse에 연결된 자료가 아직 없어요. Synapse 앱을 열어 폴더나 옵시디언 볼트를 연결하면 여기서 검색할 수 있어요.\nNo sources are indexed in Synapse yet. Open the Synapse app and connect a folder or Obsidian vault, then try again."

var library: Library?

/// 색인이 있으면 읽기 전용 Library를, 없으면 nil을 돌려준다(쓰기·생성 없음).
func currentLibrary() -> Library? {
    if library == nil {
        guard FileManager.default.fileExists(atPath: homeURL.appendingPathComponent("index.sqlite").path) else { return nil }
        do { library = try Library.openReadOnly(home: homeURL) }
        catch { log("색인을 열 수 없어요: \(error)"); return nil }
    }
    library?.refreshIfChanged()
    return library
}

// MARK: - 사서 접근 (docs/V05.md §7)

let brainMissingMessage = "Synapse 앱을 한 번 열어 주세요. 사서 저장소(brain.sqlite)가 아직 없어요.\nOpen the Synapse app once: the librarian store (brain.sqlite) does not exist yet."
let remoteBodyNotice = "본문은 Synapse 설정에서 허용하면 보여요"

var brainAPI: BrainAPI?
var brainFailed = false

/// brain.sqlite가 이미 있을 때만 사서를 연다(.mcp 모드: 앱이 계산해 둔 값을 읽고 제안만 쓴다). 없으면 만들지 않는다.
func currentBrain() -> BrainAPI? {
    if let b = brainAPI { return b }
    guard FileManager.default.fileExists(atPath: homeURL.appendingPathComponent("brain.sqlite").path),
          currentLibrary() != nil else { return nil }
    do {
        brainAPI = try Brain(home: homeURL, mode: .mcp, sources: { library?.sourceConfigs() ?? [] })
    } catch {
        if !brainFailed { log("사서를 열 수 없어요: \(error)") }
        brainFailed = true
    }
    return brainAPI
}

/// mcp.remoteBodies 설정. 사서가 없거나 읽지 못하면 숨긴다(기본 꺼짐).
func remoteBodiesAllowed() -> Bool {
    guard let b = currentBrain() else { return false }
    let v = b.settings()["mcpRemoteBodies"]
    if let n = v as? NSNumber { return n.boolValue }
    if let t = v as? String { return t == "1" || t == "true" }
    return false
}

var revealRemote = false      // 도구 호출마다 callTool이 정한다(서버는 한 번에 한 요청)

/// 문서 종류(색인 kind) → origin
func originOfKind(_ kind: String) -> String { kind == "jira" || kind == "confluence" ? kind : "local" }

/// 색인 id("<소스>:jira:KEY" | "<소스>:confluence:ID" | "<소스>:<상대 경로>") → origin
func originOfID(_ id: String) -> String {
    let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
    if parts.count == 3, parts[1] == "jira" || parts[1] == "confluence" { return String(parts[1]) }
    return "local"
}

func isRemoteOrigin(_ o: String) -> Bool { o != "local" }
func isRemoteDocOrigin(_ o: Any?) -> Bool { (o as? String) == "jira" || (o as? String) == "confluence" }

/// 세션 기록에서 온 필드는 어떤 응답에도 남기지 않는다(사서가 이미 빼지만 한 번 더 거른다).
let sessionKeys: Set<String> = ["firstAsk", "first_ask", "lastAskText", "last_ask", "requestText", "sessionTitle", "session_title",
                                "sessionTitles", "firstRequest"]

/// 원격 문서 항목에서 mcp.remoteBodies가 꺼져 있을 때 지우는 키(본문에서 파생된 문장).
let remoteBodyKeys = ["summary", "summarySource", "reason", "reasons", "chips", "snippet", "excerpt", "stopped", "stoppedHeading"]

/// 사서 결과의 문서 참조(primaryDoc/doc/docId)에 origin을 달고 세션 필드를 거른다.
func decorate(_ v: Any, key: String = "") -> Any {
    if let a = v as? [Any] { return a.map { decorate($0, key: key) } }
    guard var d = v as? JSON else { return v }
    if key == "lastAsk" { d["text"] = nil; d["title"] = nil }
    for k in sessionKeys { d[k] = nil }
    for (k, x) in d where x is JSON || x is [Any] { d[k] = decorate(x, key: k) }
    if key == "primaryDoc" || key == "doc", let id = d["id"] as? String { d["origin"] = originOfID(id) }
    else if d["origin"] == nil, let id = d["docId"] as? String { d["origin"] = originOfID(id) }
    // mcp.remoteBodies가 꺼져 있으면 Confluence·Jira 문서 항목의 본문 파생 문자열(요약·이유·칩·발췌)을 지운다(사서도 막지만 한 번 더).
    if !revealRemote, isRemoteDocOrigin(d["origin"]) || isRemoteDocOrigin((d["primaryDoc"] as? JSON)?["origin"]) {
        for k in remoteBodyKeys { d[k] = nil }
    }
    return d
}

// MARK: - 결과 만들기

func ok(_ markdown: String, _ structured: JSON) -> JSON {
    ["content": [["type": "text", "text": markdown] as JSON], "structuredContent": structured, "isError": false]
}

func fail(_ ko: String, _ en: String) -> JSON {
    ["content": [["type": "text", "text": ko + "\n" + en] as JSON], "isError": true]
}

func notReady() -> JSON {
    ["content": [["type": "text", "text": notReadyMessage] as JSON],
     "structuredContent": ["indexed": false, "message": notReadyMessage] as JSON, "isError": false]
}

func int(_ v: Any?, _ def: Int, _ lo: Int, _ hi: Int) -> Int {
    var n = def
    if let x = v as? NSNumber, CFGetTypeID(x) != CFBooleanGetTypeID() {
        let d = x.doubleValue
        if d.isNaN { n = def } else { n = Int(min(max(d.rounded(), Double(lo)), Double(hi))) }   // 무한대·아주 큰 값도 범위로 자른다
    } else if let s = v as? String, let d = Double(s.trimmingCharacters(in: .whitespaces)) {
        n = d.isNaN ? def : Int(min(max(d.rounded(), Double(lo)), Double(hi)))
    }
    return min(max(n, lo), hi)
}

func str(_ v: Any?) -> String { v as? String ?? "" }

/// DocSummary → 도구 출력용 요약
func brief(_ d: JSON) -> JSON {
    ["id": str(d["id"]), "title": str(d["title"]), "path": str(d["path"]), "source": str(d["sourceName"]),
     "sourceKind": str(d["sourceKind"]), "kind": str(d["kindLabel"]), "modified": str(d["updated"]),
     "origin": originOfKind(str(d["kind"])), "tags": d["tags"] as? [String] ?? [], "degree": d["degree"] as? Int ?? 0]
}

func entry(_ item: JSON) -> JSON {
    var e = brief(item["doc"] as? JSON ?? [:])
    e["reason"] = str(item["reason"])
    if let s = item["snippet"] as? String, !s.isEmpty {
        if isRemoteOrigin(str(e["origin"])) && !revealRemote { e["bodyNotice"] = remoteBodyNotice } else { e["snippet"] = s }
    }
    return e
}

func day(_ iso: String) -> String { String(iso.prefix(10)) }

func line(_ e: JSON, _ n: Int? = nil) -> String {
    var s = (n.map { "\($0). " } ?? "- ") + "**\(str(e["title"]))** — \(str(e["kind"])) · \(str(e["path"]))"
    if isRemoteOrigin(str(e["origin"])) { s += " · origin: \(str(e["origin"]))" }
    if !str(e["modified"]).isEmpty { s += " · \(day(str(e["modified"])))" }
    s += "\n   id: `\(str(e["id"]))`"
    if !str(e["reason"]).isEmpty { s += " · \(str(e["reason"]))" }
    if let sn = e["snippet"] as? String, !sn.isEmpty { s += "\n   > \(sn)" }
    if let nt = e["bodyNotice"] as? String { s += "\n   (\(nt))" }
    return s
}

// MARK: - 도구 구현

func searchNotes(_ lib: Library, _ args: JSON) -> JSON {
    let query = str(args["query"]).trimmingCharacters(in: .whitespacesAndNewlines)
    if query.isEmpty { return fail("query가 필요해요. 검색어를 넣어 주세요.", "`query` is required and must be a non-empty string.") }
    let limit = int(args["limit"], 10, 1, 30)
    let v = lib.viewJSON(["mode": "search", "query": query])
    let sections = v["sections"] as? [JSON] ?? []
    func items(_ key: String) -> [JSON] { (sections.first { str($0["key"]) == key }?["items"] as? [JSON]) ?? [] }
    let isSearch = str(v["mode"]) == "search"
    let all = isSearch ? items("match").map(entry) : []
    let results = Array(all.prefix(limit))
    let context = results.isEmpty ? [] : Array(items("context").prefix(5).map(entry))
    var md = "# Synapse 검색: “\(query)”\n"
    if results.isEmpty {
        md += "일치하는 문서가 없어요. 다른 표현이나 더 짧은 핵심 단어로 다시 찾아 보세요.\nNo matching documents. Try other or shorter keywords.\n"
    } else {
        md += "\(all.count)개 중 \(results.count)개 (matches: \(all.count), shown: \(results.count))\n\n"
        md += results.enumerated().map { line($0.element, $0.offset + 1) }.joined(separator: "\n") + "\n"
        if !context.isEmpty { md += "\n## 연결된 문서 (related to the matches)\n" + context.map { line($0) }.joined(separator: "\n") + "\n" }
        md += "\n다음: `get_note`(id)로 본문, `related_notes`(id)로 연결을 볼 수 있어요."
    }
    return ok(md, ["query": query, "count": results.count, "totalMatches": all.count, "results": results, "connected": context])
}

func getNote(_ lib: Library, _ args: JSON) -> JSON {
    let id = str(args["id"]).trimmingCharacters(in: .whitespacesAndNewlines)
    if id.isEmpty { return fail("id가 필요해요.", "`id` is required.") }
    guard let d = lib.documentJSON(id: id) else {
        return fail("id “\(id)” 문서를 찾지 못했어요. search_notes나 recent_notes가 돌려준 id를 그대로 넣어 주세요.",
                    "No document with id “\(id)”. Pass an id exactly as returned by search_notes / recent_notes.")
    }
    var note = brief(d["doc"] as? JSON ?? [:])
    var text = str(d["text"])
    var truncated = (d["truncated"] as? Bool) ?? false
    if text.count > maxNoteChars { text = String(text.prefix(maxNoteChars)); truncated = true }
    if isRemoteOrigin(str(note["origin"])) && !revealRemote {
        text = remoteBodyNotice; truncated = false
        note["bodyHidden"] = true
    }
    note["text"] = text
    note["truncated"] = truncated
    if let t = lib.openTarget(id: id) { note["location"] = t.location }
    var links: JSON = [:]
    let keyName = ["out": "outgoing", "in": "incoming", "related": "automatic", "tag": "sameTag"]
    var md = "# \(str(note["title"]))\n"
    md += "\(str(note["kind"])) · \(str(note["source"])) · \(str(note["path"])) · 수정 \(day(str(note["modified"])))\n"
    if let loc = note["location"] as? String { md += "원본: \(loc)\n" }
    if let tg = note["tags"] as? [String], !tg.isEmpty { md += "태그: " + tg.map { "#" + $0 }.joined(separator: " ") + "\n" }
    md += "id: `\(id)`\n\n---\n\(text)\n"
    if truncated { md += "\n…(본문이 길어 \(text.count)자에서 잘렸어요 / truncated at \(text.count) chars)\n" }
    for s in d["sections"] as? [JSON] ?? [] {
        let key = str(s["key"])
        let es = (s["items"] as? [JSON] ?? []).map(entry)
        links[keyName[key] ?? key] = es
        md += "\n## \(str(s["title"]))\n" + es.map { line($0) }.joined(separator: "\n") + "\n"
    }
    let unresolved = d["unresolved"] as? [String] ?? []
    if !unresolved.isEmpty { md += "\n## 연결 대상을 못 찾은 링크 (unresolved)\n" + unresolved.map { "- \($0)" }.joined(separator: "\n") + "\n" }
    note["links"] = links
    note["unresolved"] = unresolved
    return ok(md, note)
}

func relatedNotes(_ lib: Library, _ args: JSON) -> JSON {
    let id = str(args["id"]).trimmingCharacters(in: .whitespacesAndNewlines)
    if id.isEmpty { return fail("id가 필요해요.", "`id` is required.") }
    guard lib.openTarget(id: id) != nil else {
        return fail("id “\(id)” 문서를 찾지 못했어요.", "No document with id “\(id)”.")
    }
    let depth = int(args["depth"], 1, 1, 2), limit = int(args["limit"], 20, 1, 50)
    let v = lib.viewJSON(["mode": "focus", "focusId": id, "depth": depth])
    var remaining = limit
    var center: JSON = [:]
    var out: [JSON] = []
    var md = ""
    for s in v["sections"] as? [JSON] ?? [] {
        let key = str(s["key"])
        let raw = s["items"] as? [JSON] ?? []
        if key == "center" { if let f = raw.first { center = brief(f["doc"] as? JSON ?? [:]) }; continue }
        let es = Array(raw.map(entry).prefix(max(remaining, 0)))
        remaining -= es.count
        if es.isEmpty { continue }
        out.append(["key": key, "title": str(s["title"]), "items": es])
        md += "\n## \(str(s["title"]))\n" + es.map { line($0) }.joined(separator: "\n") + "\n"
    }
    let count = out.reduce(0) { $0 + ($1["items"] as? [JSON] ?? []).count }
    var head = "# 연결된 노트: \(str(center["title"]))\n\(str(center["path"])) · id: `\(id)` · depth \(depth)\n"
    if count == 0 { head += "\n이 문서와 이어진 문서가 아직 없어요.\nNo connected documents yet.\n" }
    return ok(head + md, ["center": center, "depth": depth, "count": count, "sections": out])
}

func recentNotes(_ lib: Library, _ args: JSON) -> JSON {
    let limit = int(args["limit"], 20, 1, 50)
    let v = lib.viewJSON(["mode": "global"])
    let raw = ((v["sections"] as? [JSON])?.first { str($0["key"]) == "recent" }?["items"] as? [JSON]) ?? []
    let es = Array(raw.prefix(limit).map(entry))
    var md = "# 최근 수정한 노트 (\(es.count)/\(raw.count))\n"
    md += es.isEmpty ? "문서가 없어요.\nNo documents.\n" : es.enumerated().map { line($0.element, $0.offset + 1) }.joined(separator: "\n") + "\n"
    return ok(md, ["count": es.count, "results": es, "summary": str(v["summary"])])
}

func listSources(_ lib: Library) -> JSON {
    let st = lib.statusJSON()
    let srcs = (st["sources"] as? [JSON] ?? []).map { s -> JSON in
        ["id": str(s["id"]), "kind": str(s["kind"]), "name": str(s["name"]), "detail": str(s["detail"]),
         "enabled": s["enabled"] as? Bool ?? true, "state": str(s["state"]), "docCount": s["docCount"] as? Int ?? 0,
         "lastIndexed": s["lastIndexed"] is NSNull ? NSNull() : str(s["lastIndexed"]),
         "error": s["error"] is NSNull ? NSNull() : str(s["error"])]
    }
    let total = st["docCount"] as? Int ?? 0
    var md = "# Synapse 출처 \(srcs.count)개 · 문서 \(total)개\(st["indexing"] as? Bool == true ? " · 색인 중" : "")\n"
    md += srcs.map { s in
        "- **\(str(s["name"]))** (\(str(s["kind"]))) — 문서 \(s["docCount"] as? Int ?? 0)개 · \(str(s["state"]))\(s["enabled"] as? Bool == false ? " · 꺼짐" : "")"
            + " · \(str(s["detail"]))" + (s["lastIndexed"] is String ? " · 마지막 색인 \(day(str(s["lastIndexed"])))" : "")
            + (s["error"] is String ? " · 오류: \(str(s["error"]))" : "")
    }.joined(separator: "\n") + "\n"
    return ok(md, ["docCount": total, "indexing": st["indexing"] as? Bool ?? false, "sources": srcs])
}

// MARK: - 사서 도구 (docs/V05.md §7)

/// MCP initialize의 clientInfo.name → 제안 출처. Claude·Codex 계열은 칩 이름에 맞춰 줄이고, 나머지는 받은 이름을 그대로 쓴다.
var clientOrigin = "mcp"

func originName(_ clientName: String) -> String {
    let raw = clientName.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = raw.lowercased()
    if raw.isEmpty { return "mcp" }
    if lower.contains("claude") { return "claude" }
    if lower.contains("codex") { return "codex" }
    return String(String(String.UnicodeScalarView(raw.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 })).prefix(40))
}

/// v0.8: Synapse가 띄운 Claude는 env로 출처(SYNAPSE_MCP_ORIGIN)와 실행 id(SYNAPSE_RUN_ID)를 준다.
/// 출처는 영문·숫자·- 40자 이내일 때만 쓰고(clientInfo.name보다 먼저), 실행 id는 영문·숫자·_·- 64자 이내일 때만 쓴다.
let envOrigin: String? = {
    guard let v = ProcessInfo.processInfo.environment["SYNAPSE_MCP_ORIGIN"]?.trimmingCharacters(in: .whitespacesAndNewlines),
          !v.isEmpty, v.count <= 40, v.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }) else { return nil }
    return originName(v)
}()
let runID: String? = Organizer.cleanRunId(ProcessInfo.processInfo.environment["SYNAPSE_RUN_ID"])

/// v0.8: Synapse가 띄운 Claude(실행 id가 있음)에는 바로 실행(apply_changes)을 내주지 않는다.
/// 실행 인자(--allowedTools·--permission-prompts none)에 더한 두 번째 막 — 제안만 올리고 사람이 승인한다.
func servedTools() -> [JSON] { runID == nil ? toolList : toolList.filter { $0["name"] as? String != "apply_changes" } }

/// 제안·바로 실행의 출처: SYNAPSE_MCP_ORIGIN → initialize의 clientInfo.name → "mcp".
func proposalOrigin() -> String { envOrigin ?? clientOrigin }

func brainNotReady() -> JSON {
    ["content": [["type": "text", "text": brainMissingMessage] as JSON],
     "structuredContent": ["ready": false, "note": "Synapse 앱을 한 번 열어 주세요"] as JSON, "isError": false]
}

func brainFail(_ r: JSON) -> JSON? {
    guard r["ok"] as? Bool == false else { return nil }
    let msg = str(r["error"]).isEmpty ? "사서가 요청을 처리하지 못했어요." : str(r["error"])
    return fail(msg, "The librarian could not handle the request: \(msg)")
}

func pretty(_ v: Any) -> String {
    guard JSONSerialization.isValidJSONObject(v),
          let d = try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "" }
    return String(data: d, encoding: .utf8) ?? ""
}

/// 비어 있지 않은 값만 " · "로 이어 붙인다.
func joinBits(_ bits: [String]) -> String {
    let b = bits.filter { !$0.isEmpty }
    return b.isEmpty ? "" : " · " + b.joined(separator: " · ")
}

/// v0.7 FIX2: 항목 종류 표시. 코드 흐름 → [코드], Jira → [티켓], 체크박스 → [할 일], 그 밖의 볼트 문서 흐름 → [노트]. 순서·정렬은 건드리지 않는다.
func kindTag(_ i: JSON) -> String {
    if (i["code"] as? Bool) == true || i["code"] is JSON { return "[코드] " }
    if str(i["kind"]) == "task" { return "[할 일] " }
    if str(i["origin"]) == "jira" { return "[티켓] " }
    if str(i["origin"]).isEmpty && i["docId"] == nil && i["threadId"] == nil { return "" }
    return "[노트] "
}

/// 홈 항목(current·urgent·next) 한 줄. 세션 요청 문장은 넣지 않는다(도구 이름·시각·산출물 수만, docs/V05.md §5.7).
func workItemLine(_ i: JSON) -> String {
    let tier = ["now": "지금", "week": "이번 주", "dormant": "잠듦"][str(i["tier"])] ?? ""
    var bits = [tier, str(i["whenLabel"]), str(i["actorLabel"]), str(i["dueLabel"])]
    if let sc = ["work": "업무", "personal": "개인"][str(i["scope"])] { bits.append(sc + (str(i["projectLabel"]).isEmpty ? "" : " · " + str(i["projectLabel"]))) }   // v0.7 B
    if let n = i["openTasks"] as? Int, n > 0 { bits.append("열린 할 일 \(n)") }
    if let s = i["stopped"] as? JSON, !str(s["heading"]).isEmpty { bits.append("멈춘 곳 '\(str(s["heading"]))'") }
    if let a = i["lastAsk"] as? JSON {
        let outputs = a["outputs"] as? Int ?? 0
        bits.append("\(str(a["tool"]) == "codex" ? "Codex" : "Claude")에게 \(str(a["atLabel"])) 요청" + (outputs > 0 ? " · 산출물 \(outputs)" : ""))
    }
    var l = "- " + kindTag(i) + "**\(str(i["title"]))**" + joinBits(bits)
    let chips = (i["chips"] as? [JSON] ?? []).map { str($0["text"]) }.filter { !$0.isEmpty }
    if !chips.isEmpty { l += "\n   근거: " + chips.joined(separator: " · ") }
    if !str(i["summary"]).isEmpty { l += "\n   " + str(i["summary"]) }
    if !str(i["docId"]).isEmpty { l += "\n   문서 id: `\(str(i["docId"]))`" }
    return l
}

/// 이번 주 목록(§5.5)을 글로 쓴다. 클라이언트가 structuredContent를 모델에 넘기지 않아도 같은 내용을 읽을 수 있게.
func weekMarkdown(_ r: JSON) -> String {
    var md = ""
    if let range = r["range"] as? JSON { md += "기간 \(str(range["label"]))\n" }
    func section(_ title: String, _ rows: [String]) {
        md += "\n## \(title) \(rows.count)\n" + (rows.isEmpty ? "(없음)\n" : rows.joined(separator: "\n") + "\n")
    }
    section("한 일", (r["done"] as? [JSON] ?? []).map {
        "- \(str($0["text"]))" + joinBits([str($0["whenLabel"]), str($0["actorLabel"]), str($0["project"]),
                                         ($0["mine"] as? Bool) == true ? "내 티켓" : "", str($0["basis"]) == "updated" ? "갱신 기준" : ""])
    })
    // v0.7 C: 이번 주에 상태가 바뀌었지만 끝나지 않은 티켓, 닫힌(취소·반려·막힌 채 닫힘) 티켓 수
    let changes = r["changes"] as? [JSON] ?? []
    section("상태 변경", changes.map {
        let from = str($0["fromLabel"]), to = str($0["toLabel"])
        return "- \(str($0["title"]))" + joinBits([from.isEmpty ? "→ \(to)" : "\(from) → \(to)", str($0["whenLabel"]), ($0["mine"] as? Bool) == true ? "내 티켓" : ""])
    })
    let closed = r["closed"] as? [JSON] ?? []
    if !closed.isEmpty {
        md += "\n(닫힘 \(closed.count)개는 한 일에서 뺐어요: " + closed.prefix(5).map { "\(str($0["key"])) \(str($0["status"]))" }.joined(separator: ", ") + (closed.count > 5 ? " 외" : "") + ")\n"
    }
    section("진행 중", (r["progress"] as? [JSON] ?? []).map { p in
        let done = p["doneThisWeek"] as? Int ?? 0, open = p["open"] as? Int ?? 0
        return "- " + kindTag(p) + "**\(str(p["title"]))**" + joinBits([done > 0 ? "이번 주 끝냄 \(done)" : "", open > 0 ? "남은 할 일 \(open)" : "", str(p["lastLabel"])])
    })
    section("다음", (r["next"] as? [JSON] ?? []).map {
        "- " + (str($0["origin"]) == "jira" ? "[티켓] " : "[할 일] ") + "\(str($0["text"]))" + joinBits([str($0["dueLabel"]), str($0["project"])])
    })
    let plan = r["lastPlan"] as? [JSON] ?? []
    if !plan.isEmpty { section("지난주 계획", plan.map { "- \(str($0["text"]))" }) }
    let missing = r["missing"] as? [JSON] ?? []
    if !missing.isEmpty {
        section("누락 의심(고친 흔적은 있는데 할 일 변화가 없음)", missing.map {
            "- \(str($0["title"]))" + joinBits([($0["lines"] as? Int).map { "\($0)줄 고침" } ?? "", str($0["whenLabel"])])
        })
    }
    if !str(r["copyText"]).isEmpty { md += "\n## 주간보고용 목록\n```\n\(str(r["copyText"]))\n```\n" }
    return md
}

func workContextTool(_ b: BrainAPI, _ args: JSON) -> JSON {
    let period = str(args["period"]) == "week" ? "week" : "now"
    var r = decorate(b.workContext(period: period)) as? JSON ?? [:]
    if let f = brainFail(r) { return f }
    if r["updatedAt"] == nil || r["updatedAt"] is NSNull {
        r = ["updatedAt": NSNull(), "note": "Synapse 앱을 한 번 열어 주세요"]
        return ok("Synapse 앱을 한 번 열어 주세요.\nOpen the Synapse app once so it can work out your current threads.", r)
    }
    var md = "# 작업 맥락 (\(period == "week" ? "이번 주" : "지금"))\n갱신 \(str(r["updatedAt"]))\n"
    if period == "week" { return ok(md + weekMarkdown(r), r) }
    if let c = r["current"] as? JSON { md += "\n## 지금 하던 일\n" + workItemLine(c) + "\n" }
    let urgent = r["urgent"] as? [JSON] ?? []
    if !urgent.isEmpty { md += "\n## 급한 것\n" + urgent.map(workItemLine).joined(separator: "\n") + "\n" }
    let next = r["next"] as? [JSON] ?? []
    if !next.isEmpty { md += "\n## 이어서\n" + next.map(workItemLine).joined(separator: "\n") + "\n" }
    if !(r["threads"] as? [JSON] ?? []).isEmpty { md += "\n## 작업 흐름" }
    for t in r["threads"] as? [JSON] ?? [] {
        md += "\n- **\(str(t["title"]))** · \(str(t["tier"])) · \(str(t["lastLabel"]))"
        if let n = t["openTasks"] as? Int, n > 0 { md += " · 열린 할 일 \(n)" }
        if let rs = t["reasons"] as? [String], !rs.isEmpty { md += "\n   " + rs.joined(separator: " · ") }
        if let p = t["primaryDoc"] as? JSON { md += "\n   대표 문서: \(str(p["title"])) (id: `\(str(p["id"]))`, origin: \(str(p["origin"])))" }
    }
    let tasks = r["openTasks"] as? [JSON] ?? []
    if !tasks.isEmpty {
        md += "\n\n## 열린 할 일\n" + tasks.map { t -> String in
            var l = "- \(str(t["text"]))"
            if !str(t["due"]).isEmpty { l += " · 기한 \(str(t["due"]))" }
            if let d = t["doc"] as? JSON { l += " · \(str(d["title"]))" }
            return l
        }.joined(separator: "\n")
    }
    return ok(md + "\n", r)
}

func vaultPolicyTool(_ b: BrainAPI) -> JSON {
    let r = decorate(b.vaultPolicy()) as? JSON ?? [:]
    if let f = brainFail(r) { return f }
    let approved = (r["approved"] as? Bool) ?? false
    var md = "# 볼트 정리 규칙\n승인: \(approved ? "예" : "아직 아니에요")\n"
    let rules = r["rules"] as? [Any] ?? []
    md += "\n규칙 \(rules.count)개 · 고정 \((r["frozen"] as? [Any] ?? []).count) · 제외 \((r["exclude"] as? [Any] ?? []).count)"
    md += " · 위반 \((r["violations"] as? [Any] ?? []).count)\n"
    // v0.6: structuredContent를 모델에 넘기지 않는 클라이언트를 위해 폴더 현황·위반 요약을 글로도 쓴다
    let folders = r["folders"] as? [JSON] ?? []
    if !folders.isEmpty {
        let top = folders.sorted { ($0["docs"] as? Int ?? 0) > ($1["docs"] as? Int ?? 0) }.prefix(8)
        md += "목적지로 쓸 수 있는 폴더 \(folders.count)개 · 문서가 많은 곳: " + top.map { "\(str($0["path"])) \($0["docs"] as? Int ?? 0)" }.joined(separator: ", ") + "\n"
    }
    let viol = r["violations"] as? [JSON] ?? []
    if !viol.isEmpty { md += "고칠 것: " + viol.prefix(3).map { str($0["text"]) }.joined(separator: " · ") + (viol.count > 3 ? " 외 \(viol.count - 3)개" : "") + "\n" }
    md += "\n```json\n" + pretty(["rules": rules, "frozen": r["frozen"] ?? [], "exclude": r["exclude"] ?? [], "landing": r["landing"] ?? []]) + "\n```\n"
    return ok(md, r)
}

func listPendingTool(_ b: BrainAPI) -> JSON {
    let r = decorate(b.listPending()) as? JSON ?? [:]
    if let f = brainFail(r) { return f }
    let unsorted = r["unsorted"] as? [JSON] ?? [], proposals = r["proposals"] as? [JSON] ?? []
    let deletes = proposals.filter { str($0["kind"]) == "delete" }
    let trashN = ((r["trash"] as? JSON)?["count"] as? Int) ?? 0
    let direct = (r["directApply"] as? Bool) ?? false
    var md = "# 정리 대기\n자리가 정해지지 않은 문서 \(unsorted.count)개 · 제안 \(proposals.count)개(삭제 제안 \(deletes.count)개) · Synapse 휴지통 \(trashN)개(30일 보관)\n"
    md += direct ? "바로 실행: 켜짐 — apply_changes로 승인 없이 옮기거나 휴지통으로 보낼 수 있어요(하루 60건).\n"
                 : "바로 실행: 꺼짐 — 옮기기·삭제는 propose_changes로 제안해 주세요.\n"
    for u in unsorted {
        md += "\n- **\(str(u["title"]))** — \(str(u["path"])) · \(str(u["modifiedLabel"])) (docId: `\(str(u["docId"]))`)"
        let c = (u["candidates"] as? [JSON] ?? []).map { "\(str($0["to"])) (\(str($0["confidence"])))" }
        if !c.isEmpty { md += "\n   후보: " + c.joined(separator: ", ") }
    }
    if !proposals.isEmpty {
        md += "\n\n## 제안\n" + proposals.map { p -> String in
            let what = str(p["kind"]) == "delete" ? "삭제(휴지통) \(str(p["from"]))" : "\(str(p["from"])) → \(str(p["to"]))"
            return "- [\(str(p["state"]))] \(what) · \(str(p["origin"])) · \(str(p["createdLabel"])) (id: `\(str(p["id"]))`)"
        }.joined(separator: "\n")
    }
    return ok(md + "\n", r)
}

func suggestLocationTool(_ b: BrainAPI, _ args: JSON) -> JSON {
    let title = str(args["title"]).trimmingCharacters(in: .whitespacesAndNewlines)
    if title.isEmpty { return fail("title이 필요해요.", "`title` is required.") }
    var a: JSON = ["title": title]
    for k in ["type", "project"] where !str(args[k]).isEmpty { a[k] = str(args[k]) }
    if !str(args["content_head"]).isEmpty { a["content_head"] = String(str(args["content_head"]).prefix(2000)) }
    let r = decorate(b.suggestLocation(a)) as? JSON ?? [:]
    if let f = brainFail(r) { return f }
    let sug = r["suggestions"] as? [JSON] ?? []
    var md = "# 둘 곳 추천: “\(title)”\n"
    md += sug.isEmpty ? "추천할 폴더가 없어요. 규칙표가 비어 있거나 맞는 규칙이 없어요.\nNo folder matched.\n"
        : sug.enumerated().map { "\($0.offset + 1). `\(str($0.element["folder"]))` — \(str($0.element["confidence"])) · \(str($0.element["reason"]))" }.joined(separator: "\n") + "\n"
    if (r["policyApproved"] as? Bool) == false { md += "\n(규칙표를 아직 사용자가 승인하지 않았어요.)\n" }
    return ok(md, r)
}

func proposeChangesTool(_ b: BrainAPI, _ args: JSON) -> JSON {
    guard let raw = args["items"] as? [Any], !raw.isEmpty else {
        return fail("items(배열)가 필요해요.", "`items` must be a non-empty array.")
    }
    if raw.count > 20 { return fail("한 번에 20개까지만 올릴 수 있어요.", "At most 20 items per call.") }
    var items: [JSON] = []
    for (i, x) in raw.enumerated() {
        guard let o = x as? JSON, ["move", "delete", "rules", "withdraw"].contains(str(o["kind"])) else {
            return fail("items[\(i)]에 kind(move·delete·rules·withdraw)가 필요해요.", "items[\(i)] needs kind: move, delete, rules or withdraw.")
        }
        items.append(o)
    }
    let r = decorate(b.proposeChanges(items: items, origin: proposalOrigin(), runId: runID)) as? JSON ?? [:]
    if let f = brainFail(r) { return f }
    let acc = r["accepted"] as? [JSON] ?? [], rej = r["rejected"] as? [JSON] ?? []
    var md = "# 제안 결과\n올린 제안 \(acc.count)개 · 받지 못한 제안 \(rej.count)개\n"
    md += acc.map { "- #\($0["index"] ?? "?") 접수 (id: `\(str($0["id"]))`)" + (($0["replaced"] as? Bool) == true ? " (이전 제안 대체)" : "") }.joined(separator: "\n")
    if !rej.isEmpty { md += "\n" + rej.map { "- #\($0["index"] ?? "?") 거절: \(str($0["reason"]))" }.joined(separator: "\n") }
    md += "\n\n" + (str(r["note"]).isEmpty ? "Synapse 정리함에서 사용자가 승인해야 적용돼요." : str(r["note"])) + "\n"
    return ok(md, r)
}

/// v0.6 apply_changes: 설정(mcpDirectApply)이 켜져 있을 때만 바로 옮기고 Synapse 휴지통으로. 결과는 항목마다 한 줄.
func applyChangesTool(_ b: BrainAPI, _ args: JSON) -> JSON {
    if runID != nil {
        return fail("Synapse에서 띄운 Claude는 바로 실행을 쓸 수 없어요. propose_changes로 제안해 주세요.",
                    "Direct apply is disabled for Claude runs started by Synapse. Use propose_changes.")
    }
    guard let raw = args["items"] as? [Any], !raw.isEmpty else {
        return fail("items(배열)가 필요해요.", "`items` must be a non-empty array.")
    }
    if raw.count > 20 { return fail("한 번에 20개까지만 바꿀 수 있어요.", "At most 20 items per call.") }
    var items: [JSON] = []
    for (i, x) in raw.enumerated() {
        guard let o = x as? JSON, ["move", "delete"].contains(str(o["kind"])) else {
            return fail("items[\(i)]에 kind(move·delete)가 필요해요.", "items[\(i)] needs kind: move or delete.")
        }
        items.append(o)
    }
    var r = b.applyChanges(items: items, origin: proposalOrigin())   // 결과에는 본문·세션 문장이 없다(경로·이유만)
    if (r["enabled"] as? Bool) == false {
        // v0.6 P0: 꺼짐 거절은 성공이 아니다 — isError와 structured ok:false로 돌려준다(안내 문구는 그대로)
        let note = str(r["note"])
        r["ok"] = false
        return ["content": [["type": "text", "text": "# 바로 실행 꺼짐\n\(note).\nNothing was changed: direct apply is off in Synapse settings. Use propose_changes so the user can approve in Synapse.\n"] as JSON],
                "structuredContent": r, "isError": true]
    }
    if let f = brainFail(r) { return f }
    let res = r["results"] as? [JSON] ?? []
    func n(_ st: String) -> Int { res.filter { str($0["status"]) == st }.count }
    var md = "# 바로 실행 결과\n옮김 \(n("moved")) · 휴지통 \(n("trashed")) · 제안으로 \(n("proposed")) · 거절 \(n("rejected"))"
    if let lim = r["limit"] as? JSON { md += " · 오늘 남은 바로 실행 \(lim["left"] as? Int ?? 0)/\(lim["perDay"] as? Int ?? 60)" }
    md += "\n"
    for x in res {
        let i = x["index"] ?? "?"
        switch str(x["status"]) {
        case "moved":
            md += "\n- #\(i) 옮김: \(str(x["from"])) → \(str(x["to"]))" + ((x["links"] as? Int ?? 0) > 0 ? " · 링크 \(x["links"] as? Int ?? 0)개 고침" : "")
                + " · 되돌리기: Synapse AI 기록 (새 id: `\(str(x["toId"]))`)"
        case "trashed":
            md += "\n- #\(i) 휴지통: \(str(x["from"])) · 30일 보관 · 되돌리기: Synapse AI 기록"
                + ((x["inbound"] as? Int ?? 0) > 0 ? " · 끊긴 링크 \(x["inbound"] as? Int ?? 0)개" : "")
        case "proposed":
            md += "\n- #\(i) 제안으로 올림 (id: `\(str(x["id"]))`): \(str(x["reason"]))"
        default:
            md += "\n- #\(i) 거절: \(str(x["reason"]))"
        }
    }
    md += "\n\n" + (str(r["note"]).isEmpty ? "되돌리기는 Synapse AI 기록에서 할 수 있어요." : str(r["note"])) + "\n"
    return ok(md, r)
}

// MARK: - v0.8 Jira 도구 (docs/V08.md §6.4)

let ticketGroupLabel = ["blocked": "막힘", "doing": "진행 중", "todo": "할 일"]

/// 열린 티켓 순서: 막힘 → 진행 중(오래 멈춘 것, 오래 갱신 안 된 것 먼저) → 할 일(기한 있는 것·임박 → 우선순위 → 최근 갱신). 사서 티켓 화면과 같은 규칙.
func ticketOrder(_ a: JSON, _ b: JSON) -> Bool {
    let rank = ["blocked": 0, "doing": 1, "todo": 2]
    let ga = rank[str(a["statusGroup"])] ?? 3, gb = rank[str(b["statusGroup"])] ?? 3
    if ga != gb { return ga < gb }
    let ua = str(a["updated"]), ub = str(b["updated"])       // ISO8601(UTC) — 글자 순서가 시간 순서다
    if ga < 2 {
        let sa = (a["stale"] as? Bool) ?? false, sb = (b["stale"] as? Bool) ?? false
        if sa != sb { return sa }
        if ua != ub { return ua < ub }
    } else {
        let da = str(a["due"]), db = str(b["due"])
        if da.isEmpty != db.isEmpty { return !da.isEmpty }
        if da != db { return da < db }
        let pa = a["priorityRank"] as? Int ?? 5, pb = b["priorityRank"] as? Int ?? 5
        if pa != pb { return pa < pb }
        if ua != ub { return ua > ub }
    }
    return str(a["key"]) < str(b["key"])
}

/// 기준 시각까지 지난 날 수 (없거나 미래면 nil).
func daysBetween(_ iso: String, _ ref: Date?) -> Int? {
    guard let d = BrainFormat.date(iso), let r = ref, r >= d else { return nil }
    return Int(r.timeIntervalSince(d) / 86400)
}

func ticketLine(_ t: JSON) -> String {
    var bits: [String] = []
    let st = str(t["status"]), g = ticketGroupLabel[str(t["statusGroup"])] ?? ""
    bits.append(st.isEmpty ? g : (g.isEmpty || st == g ? st : "\(st)(\(g))"))
    if !str(t["priority"]).isEmpty { bits.append("우선순위 " + str(t["priority"])) }
    if (t["mine"] as? Bool) == true { bits.append("내 담당") } else if !str(t["assigneeName"]).isEmpty { bits.append("담당 " + str(t["assigneeName"])) }
    if !str(t["sinceLabel"]).isEmpty { bits.append(str(t["sinceLabel"])) }
    if !str(t["updatedLabel"]).isEmpty { bits.append("갱신 " + str(t["updatedLabel"])) }
    if (t["stale"] as? Bool) == true { bits.append("오래 멈춤") }
    if !str(t["due"]).isEmpty { bits.append("기한 " + str(t["due"]) + (str(t["dueLabel"]).isEmpty ? "" : " (\(str(t["dueLabel"])))")) }
    return "- **\(str(t["key"]))** \(str(t["title"]))" + joinBits(bits) + "\n   docId: `\(str(t["docId"]))`"
}

func ticketBrief(_ t: JSON, ref: Date?) -> JSON {
    var o: JSON = ["key": str(t["key"]), "title": str(t["title"]), "status": str(t["status"]), "group": str(t["statusGroup"]),
                   "priority": str(t["priority"]), "mine": (t["mine"] as? Bool) ?? false, "stale": (t["stale"] as? Bool) ?? false,
                   "updated": str(t["updated"]), "docId": str(t["docId"]), "origin": "jira"]
    for (k, out) in [("assigneeName", "assignee"), ("issueType", "issueType"), ("since", "since"), ("sinceLabel", "sinceLabel"),
                     ("updatedLabel", "updatedLabel"), ("due", "due"), ("dueLabel", "dueLabel")] where !str(t[k]).isEmpty { o[out] = str(t[k]) }
    if let n = daysBetween(str(t["since"]), ref) { o["sinceDays"] = n }
    if let n = daysBetween(str(t["updated"]), ref) { o["updatedDaysAgo"] = n }
    return o
}

/// get_tickets: 사서 tickets(mine:)의 열린 티켓을 한 줄씩. Claude Code는 structuredContent를 모델에 넘기지 않으므로 text에도 목록을 다 쓴다.
func getTicketsTool(_ b: BrainAPI, _ args: JSON) -> JSON {
    let allGroups = ["blocked", "doing", "todo"]
    let mine: Bool = {
        if let n = args["mine"] as? NSNumber { return n.boolValue }
        return str(args["mine"]).lowercased() == "true"
    }()
    var groups = Set(allGroups)
    if let g = args["groups"] as? [Any], !g.isEmpty {
        let pick = Set(g.compactMap { ($0 as? String)?.lowercased() }).intersection(allGroups)
        if pick.isEmpty { return fail("groups는 blocked · doing · todo 중에서 골라 주세요.", "`groups` must contain blocked, doing or todo.") }
        groups = pick
    }
    let limit = int(args["limit"], 80, 1, 200)
    let r = b.tickets(mine: mine)
    if let f = brainFail(r) { return f }
    let ref = BrainFormat.date(str(r["generatedAt"]))
    let items = ((r["projects"] as? [JSON]) ?? []).flatMap { ($0["items"] as? [JSON]) ?? [] }
        .filter { groups.contains(str($0["statusGroup"])) }.sorted(by: ticketOrder)
    let shown = Array(items.prefix(limit))
    let totals = r["totals"] as? JSON ?? [:]
    func n(_ k: String) -> Int { totals[k] as? Int ?? 0 }
    let structured: JSON = ["count": shown.count, "total": items.count, "mine": mine, "groups": allGroups.filter { groups.contains($0) },
                            "totals": totals, "hasJira": (r["hasJira"] as? Bool) ?? false, "tickets": shown.map { ticketBrief($0, ref: ref) }]
    if (r["hasJira"] as? Bool) == false {
        return ok("# 열린 Jira 티켓\nSynapse에 연결된 Jira 티켓이 없어요.\nNo Jira tickets are indexed in Synapse.\n", structured)
    }
    var md = "# 열린 Jira 티켓 \(items.count)개" + (mine ? " (내 담당)" : "") + (shown.count < items.count ? " · 앞의 \(shown.count)개" : "") + "\n"
    md += "전체 열린 티켓: 막힘 \(n("blocked")) · 진행 중 \(n("doing")) · 할 일 \(n("todo")) · 오래 멈춤 \(n("stale")) · 내 담당 \(n("mine"))\n"
    md += shown.isEmpty ? "\n(해당하는 티켓이 없어요)\n" : "\n" + shown.map(ticketLine).joined(separator: "\n") + "\n"
    md += "\n상태 바꾸기·댓글·새 티켓은 propose_jira_changes로 제안해 주세요 — 사용자가 Synapse에서 승인해야 Jira에 반영돼요.\n"
    return ok(md, structured)
}

/// propose_jira_changes: 사서 제안함에 Jira 변경 제안을 올린다(최대 10). Jira는 바뀌지 않는다.
func proposeJiraTool(_ b: BrainAPI, _ args: JSON) -> JSON {
    guard let raw = args["items"] as? [Any], !raw.isEmpty else {
        return fail("items(배열)가 필요해요.", "`items` must be a non-empty array.")
    }
    if raw.count > 10 { return fail("한 번에 10개까지만 올릴 수 있어요.", "At most 10 items per call.") }
    var items: [JSON] = []
    for (i, x) in raw.enumerated() {
        let op = ((x as? JSON)?["op"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        guard var o = x as? JSON, ["transition", "comment", "create"].contains(op) else {
            return fail("items[\(i)]에 op(transition·comment·create)가 필요해요.", "items[\(i)] needs op: transition, comment or create.")
        }
        o["op"] = op
        if o["issueType"] == nil, let t = o["issue_type"] { o["issueType"] = t }
        items.append(o)
    }
    let r = b.proposeJira(items: items, origin: proposalOrigin(), runId: runID)
    if let f = brainFail(r) { return f }
    let acc = r["accepted"] as? [JSON] ?? [], rej = r["rejected"] as? [JSON] ?? []
    var md = "# Jira 제안 결과\n올린 제안 \(acc.count)개 · 받지 못한 제안 \(rej.count)개\n"
    if !acc.isEmpty {
        md += "\n" + acc.map { "- #\($0["index"] ?? "?") 접수: \(str($0["what"])) (id: `\(str($0["id"]))`)"
            + (($0["replaced"] as? Bool) == true ? " · 대기 중이던 같은 제안을 바꿔 끼웠어요" : "") }.joined(separator: "\n") + "\n"
    }
    if !rej.isEmpty { md += "\n" + rej.map { "- #\($0["index"] ?? "?") 거절: \(str($0["reason"]))" }.joined(separator: "\n") + "\n" }
    md += "\nSynapse 정리함에서 사용자가 승인해야 Jira에 반영돼요. 지금은 Jira가 바뀌지 않았어요.\n"
        + "Nothing has changed in Jira yet: the user must approve each proposal in Synapse.\n"
    return ok(md, r)
}

let brainToolNames: Set<String> = ["get_work_context", "get_vault_policy", "list_pending", "suggest_location", "propose_changes", "apply_changes",
                                   "get_tickets", "propose_jira_changes"]

func callBrainTool(_ name: String, _ args: JSON) -> JSON {
    _ = currentLibrary()      // sources.json·색인이 바뀌었으면 먼저 다시 읽는다
    revealRemote = remoteBodiesAllowed()
    guard let b = currentBrain() else {
        if name == "get_work_context" {
            return ok("Synapse 앱을 한 번 열어 주세요.\nOpen the Synapse app once so it can work out your current threads.",
                      ["updatedAt": NSNull(), "note": "Synapse 앱을 한 번 열어 주세요"])
        }
        return brainNotReady()
    }
    switch name {
    case "get_work_context": return workContextTool(b, args)
    case "get_vault_policy": return vaultPolicyTool(b)
    case "list_pending": return listPendingTool(b)
    case "suggest_location": return suggestLocationTool(b, args)
    case "apply_changes": return applyChangesTool(b, args)
    case "get_tickets": return getTicketsTool(b, args)
    case "propose_jira_changes": return proposeJiraTool(b, args)
    default: return proposeChangesTool(b, args)
    }
}

func callTool(_ name: String, _ args: JSON) -> JSON {
    if brainToolNames.contains(name) { return callBrainTool(name, args) }
    guard let lib = currentLibrary() else { return notReady() }
    revealRemote = remoteBodiesAllowed()
    let total = (lib.statusJSON()["docCount"] as? Int) ?? 0
    if total == 0 && name != "list_sources" { return notReady() }
    switch name {
    case "search_notes": return searchNotes(lib, args)
    case "get_note": return getNote(lib, args)
    case "related_notes": return relatedNotes(lib, args)
    case "recent_notes": return recentNotes(lib, args)
    default: return listSources(lib)
    }
}

// MARK: - JSON-RPC

func rpcError(_ id: Any, _ code: Int, _ message: String) -> JSON {
    ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message] as JSON]
}

/// 요청 하나 처리. 알림(id 없음)이면 nil.
func handle(_ msg: Any) -> JSON? {
    guard let m = msg as? JSON else { return rpcError(NSNull(), -32600, "Invalid Request: 객체가 아니에요") }
    let hasID = m["id"] != nil
    let id: Any = m["id"] ?? NSNull()
    if hasID && !(id is String || id is NSNumber || id is NSNull) { return rpcError(NSNull(), -32600, "Invalid Request: id 형식") }
    guard let method = m["method"] as? String else {
        // 클라이언트가 보낸 응답(result/error)은 무시한다
        if m["result"] != nil || m["error"] != nil { return nil }
        return rpcError(id, -32600, "Invalid Request: method가 없어요")
    }
    func reply(_ result: Any) -> JSON? { hasID ? ["jsonrpc": "2.0", "id": id, "result": result] : nil }
    let params = m["params"] as? JSON
    if m["params"] != nil && !(m["params"] is JSON) && !(m["params"] is NSNull) { return hasID ? rpcError(id, -32602, "Invalid params: 객체여야 해요") : nil }

    switch method {
    case "initialize":
        let asked = params?["protocolVersion"] as? String ?? ""
        let version = supportedProtocols.contains(asked) ? asked : preferredProtocol
        if let name = (params?["clientInfo"] as? JSON)?["name"] as? String { clientOrigin = originName(name) }
        return reply(["protocolVersion": version,
                      "capabilities": ["tools": ["listChanged": false] as JSON] as JSON,
                      "serverInfo": ["name": "synapse", "title": "Synapse", "version": serverVersion] as JSON,
                      "instructions": instructions])
    case "ping":
        return reply([String: Any]())
    case "tools/list":
        return reply(["tools": servedTools()])
    case "tools/call":
        guard hasID else { return nil }
        guard let name = params?["name"] as? String else { return rpcError(id, -32602, "Invalid params: name(문자열)이 필요해요") }
        guard servedTools().contains(where: { $0["name"] as? String == name }) else { return rpcError(id, -32602, "Unknown tool: \(name)") }
        let rawArgs = params?["arguments"]
        if rawArgs != nil && !(rawArgs is JSON) && !(rawArgs is NSNull) { return rpcError(id, -32602, "Invalid params: arguments는 객체여야 해요") }
        return reply(callTool(name, rawArgs as? JSON ?? [:]))
    default:
        if method.hasPrefix("notifications/") || !hasID { return nil }
        return rpcError(id, -32601, "Method not found: \(method)")
    }
}

log("시작 · 자료 폴더 \(homeURL.path)")
while let raw = readLine(strippingNewline: true) {
    let lineText = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if lineText.isEmpty { continue }
    guard let data = lineText.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
        send(rpcError(NSNull(), -32700, "Parse error: JSON이 아니에요"))
        continue
    }
    if let batch = obj as? [Any] {
        if batch.isEmpty { send(rpcError(NSNull(), -32600, "Invalid Request: 빈 배치")); continue }
        let rs = batch.compactMap { handle($0) }
        if !rs.isEmpty { send(rs) }
    } else if let r = handle(obj) {
        send(r)
    }
}
log("stdin 종료")
