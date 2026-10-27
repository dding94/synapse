import Foundation

// v0.8 Claude 연결 공용 계약 (docs/V08.md §2·§8). E1(실행·저장)·E2(정리 내용·프롬프트)·E3(Jira 제안)·앱 브리지가 함께 쓴다.
// 여러 담당이 함께 쓰므로 합의 없이 바꾸지 않는다.

/// Claude에게 보낼 정리(digest) 요청 하나. E2가 만들고 E1이 실행·저장한다.
struct DigestRequest {
    let kind: String                 // "week" | "tickets" | "home" | "doc"
    let scope: String                // week: 그 주 월요일 "2026-10-26" · tickets: "all" · home: "today" · doc: 문서 id
    let input: String                // Claude에게 보내는 입력(JSON 글). 세션 대화 문장은 넣지 않는다
    let hash: String                 // 입력의 안정된 해시. "11분 전"처럼 시간이 흐르면 바뀌는 값은 빼고 계산한다. 같으면 다시 돌리지 않는다
    let refs: [String: DigestRef]    // 입력에 쓴 짧은 참조("J12", "T3" …) → 원래 문서
    let schema: [String: Any]        // --json-schema로 넘길 JSON Schema (출력 모양)
    let system: String               // --system-prompt
    let prompt: String               // 표준 입력으로 보내는 글(지시 + 입력)
    let model: String?               // nil이면 설정(model.digest)을 따른다
}

/// 정리 출력의 참조가 가리키는 원래 문서. 화면은 docId(+line)로 연다.
struct DigestRef: Equatable {
    let docId: String
    let line: Int?
    let key: String?                 // Jira 키 (티켓일 때)
    let title: String
    let kind: String                 // "issue" | "task" | "doc" | "thread"

    var json: [String: Any] {
        ["docId": docId, "line": line.map { $0 as Any } ?? NSNull(), "key": key.map { $0 as Any } ?? NSNull(), "title": title, "kind": kind]
    }
}

/// '시키기' 빠른 작업 하나.
struct AgentPreset {
    let id: String
    let title: String                // 실행 기록 제목
    let prompt: String               // 사용자 지시 자리에 들어갈 글
    let digestKind: String?          // 에이전트 대신 정리(digest)로 처리하는 빠른 작업이면 그 종류(예: "week")
}

/// E2가 구현한다 (Library/AI/Digests.swift의 SynapseDigests). AIService가 주입받아 부른다. 모든 메서드는 아무 스레드에서나 불러도 된다.
protocol DigestProviding: AnyObject {
    /// 정리 범위 문자열. week는 offset(0 = 이번 주, −1 = 지난주)을 그 주 월요일 날짜로, tickets는 "all", home은 "today", doc은 docId.
    func scope(kind: String, offset: Int?, docId: String?) -> String?
    /// 정리 요청을 만든다. 정리할 것이 하나도 없으면 nil (화면은 "정리할 내용이 없어요").
    func request(kind: String, offset: Int?, docId: String?, template: String) -> DigestRequest?
    /// Claude 출력(structured_output)을 화면용으로 고친다. 입력에 없던 참조는 버리고, 참조를 {ref, docId, line, key, title, kind}로 펼치고,
    /// 글 길이를 자른다. 쓸 수 없는 출력이면 nil.
    func normalize(kind: String, output: Any, refs: [String: DigestRef]) -> [String: Any]?
    /// '시키기'(에이전트 실행)에 쓰는 시스템 프롬프트.
    var agentSystemPrompt: String { get }
    /// 빠른 작업. context: {"docId": 열려 있는 문서, "mode": 지금 화면}
    func preset(id: String, context: [String: Any]) -> AgentPreset?
    /// 화면에 보일 빠른 작업 목록 [{id, title, hint, needs}] — needs: "doc"(문서가 열려 있어야 함) 또는 NSNull
    var presets: [[String: Any]] { get }
    /// 주간보고 기본 양식 (설정 report.template이 비어 있을 때)
    var defaultReportTemplate: String { get }
}

/// Synapse에서 띄운 Claude에 허용하는 도구 (--allowedTools). apply_changes(바로 실행)는 넣지 않는다.
enum AITools {
    static let server = "synapse"
    static let read = ["search_notes", "get_note", "related_notes", "recent_notes", "list_sources", "get_work_context",
                       "get_vault_policy", "list_pending", "suggest_location", "get_tickets"]
    static let propose = ["propose_changes", "propose_jira_changes"]
    static var allowed: [String] { (read + propose).map { "mcp__\(server)__\($0)" } }
}

/// AI 설정 키 (ai.sqlite settings). 값은 모두 문자열.
enum AISetting {
    static let enabled = "enabled"                 // "1"(기본) | "0"
    static let auto = "auto"                       // "1"(기본: 화면을 열 때 바뀐 게 있으면 정리) | "0"(버튼으로만)
    static let modelDigest = "model.digest"        // "sonnet"(기본) | "opus" | "haiku"
    static let modelTask = "model.task"            // "opus"(기본) | "sonnet" | "haiku"
    static let claudePath = "claude.path"          // "" = 자동으로 찾기
    static let reportTemplate = "report.template"  // "" = 기본 양식
    static let all: Set<String> = [enabled, auto, modelDigest, modelTask, claudePath, reportTemplate]
}

/// AIService → 앱 (메인 큐에서 부른다). 앱은 window.synapseAIEvent({...})로 화면에 넘긴다.
enum AIEvent {
    case status                                                                     // {type:"status"}
    case run(id: String, kind: String, status: String, step: [String: Any]?, text: String?)   // {type:"run", runId, kind, status, step?, text?}
    case digest(kind: String, scope: String)                                        // {type:"digest", kind, scope}
    case proposals                                                                  // 실행이 제안을 올렸다 → 앱은 사서 pending 알림을 보낸다
}
