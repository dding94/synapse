import Foundation

// Synapse 자료 엔진의 공용 계약 (docs/CONNECT.md §2). 여러 담당이 함께 쓰므로 합의 없이 바꾸지 않는다.

enum SourceKind: String, Codable {
    case folder      // 일반 폴더 (형식 무관 문서)
    case obsidian    // 옵시디언 볼트
    case atlassian   // Confluence + Jira (Cloud), API 토큰
    case mcp         // 원격 MCP 서버(OAuth 로그인)로 가져오는 자료 — v0.4: Atlassian MCP
}

struct SourceConfig: Codable, Equatable {
    var id: String                    // UUID 문자열
    var kind: SourceKind
    var name: String                  // 표시 이름: 폴더 이름, 볼트 이름, 사이트 호스트
    var path: String?                 // folder·obsidian: 절대 경로
    var site: String?                 // atlassian: https://<team>.atlassian.net
    var email: String?                // atlassian: 계정 이메일 (토큰은 SecretStore에만)
    var confluenceSpaces: [String]?   // atlassian: nil = 기본 개인 범위
    var jiraJQL: String?              // atlassian: nil = 기본 개인 범위
    var enabled: Bool
    var addedAt: Date
    // v0.4 (docs/V04.md) — 모두 선택 사항이라 예전 sources.json도 그대로 읽힌다
    var includeKinds: [String]? = nil   // folder·obsidian: 색인할 확장자. nil = 소스 종류별 기본값
    var excludeFolders: [String]? = nil // folder·obsidian: 제외할 상대 폴더(NFC, 하위 포함)
    var mcpURL: String? = nil           // mcp: 서버 주소 (예: https://mcp.atlassian.com/v1/mcp)
    var mcpSite: String? = nil          // mcp: 고른 Atlassian 사이트 호스트(cloudId 대신 써도 된다)
}

struct DocRecord: Codable, Equatable {
    var id: String            // "<sourceId>:<상대 경로>" | "<sourceId>:confluence:<pageId>" | "<sourceId>:jira:<KEY>"
    var sourceId: String
    var kind: String          // 파일 확장자("md", "pdf" …) 또는 "confluence" / "jira"
    var title: String
    var location: String      // 절대 파일 경로 또는 https URL (원본 열기용)
    var displayPath: String   // 사람이 읽는 경로: "Vault / 1-Projects / 기획.md", "Confluence · ENG / 상위 / 제목"
    var folder: String        // 상대 상위 폴더("" = 루트). 원격 문서는 스페이스·프로젝트 키
    var group: String         // 색·필터 묶음: 첫 경로 조각(루트면 소스 이름), 스페이스 키, 프로젝트 키
    var modified: Date
    var created: Date?
    var size: Int
    var tags: [String]        // "#" 없이, 원래 대소문자, 중복 제거
    var aliases: [String]
    var outLinks: [String]    // 쓰인 그대로의 링크 대상: 노트 이름, 상대 경로, 페이지 제목, 이슈 키, "id:<docId>"
    var text: String          // 평문 본문, 최대 400_000자
    var fingerprint: String   // 변경 감지: 파일은 "<mtime>-<size>", 원격은 version/updated
    // v0.5 (docs/V05.md §4.8): 원격 이슈 필드. jira: status, statusCategory(new|indeterminate|done), priority,
    // duedate(yyyy-MM-dd), assignee(accountId), mine("1"|"0"), issuetype, updated(ISO8601). 로컬 문서는 nil.
    var meta: [String: String]? = nil
}

/// 로컬 파일 하나를 읽은 결과 (Extractors · ObsidianParser가 만든다).
struct ExtractedFile: Equatable {
    var title: String?        // nil이면 확장자를 뺀 파일 이름
    var text: String
    var tags: [String] = []
    var aliases: [String] = []
    var outLinks: [String] = []
    var created: Date? = nil
}

enum ExtractError: Error, Equatable {
    case unsupported
    case tooLarge
    case unreadable(String)
}

/// 원격 소스(Atlassian) 동기화 한 번의 결과. upserts는 같은 id 문서를 교체한다.
struct RemoteSyncResult {
    var upserts: [DocRecord]
    var keepIDs: Set<String>?   // 전체 동기화일 때만: 원격에 아직 있는 id (이 소스의 나머지는 삭제)
    var cursor: Date            // 다음 동기화 때 since로 돌려준다
}

protocol RemoteConnector {
    init(config: SourceConfig, token: String)
    /// since == nil이면 전체 동기화. progress(done, total?)는 아무 스레드에서나 불릴 수 있다.
    func sync(since: Date?, progress: @escaping (Int, Int?) -> Void) async throws -> RemoteSyncResult
    /// "연결" 버튼용 자격 증명 확인. 표시 이름을 돌려준다 (예: "홍길동 · team.atlassian.net").
    func verify() async throws -> String
}

/// v0.7: Jira 이슈만 전체로 다시 받을 수 있는 연결기 (Jira meta 판이 낮은 색인을 한 번 채울 때).
protocol JiraRefetching {
    /// cursor는 결과에 그대로 돌려준다(Confluence 증분 지점을 건드리지 않는다). keepIDs는 없다.
    func syncJiraOnly(cursor: Date, progress: @escaping (Int, Int?) -> Void) async throws -> RemoteSyncResult
}

protocol SecretStore {
    func secret(for account: String) -> String?
    func setSecret(_ value: String, for account: String) throws
    func removeSecret(for account: String)
}

final class MemorySecretStore: SecretStore {
    private var values: [String: String] = [:]
    private let lock = NSLock()
    func secret(for account: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func setSecret(_ value: String, for account: String) throws { lock.lock(); values[account] = value; lock.unlock() }
    func removeSecret(for account: String) { lock.lock(); values[account] = nil; lock.unlock() }
}

enum LibraryEvent {
    case progress(sourceId: String, done: Int, total: Int, phase: String)   // phase: "scan", "read", "relate", "sync"
    case changed(reason: String)
    case sourceError(sourceId: String, message: String)
}

/// 담당별 구현을 이어 붙이는 자리. 앱(main.swift)과 CLI(tools/cli/main.swift)가 시작할 때 채운다.
/// 덕분에 엔진·추출기·연결기를 서로 기다리지 않고 따로 컴파일·시험할 수 있다.
enum Plugins {
    static var extract: (URL) throws -> ExtractedFile = { _ in throw ExtractError.unsupported }
    static var supportedExtensions: Set<String> = []
    static var makeRemote: ((SourceConfig, String) -> RemoteConnector)? = nil
    static var secrets: SecretStore = MemorySecretStore()
}
