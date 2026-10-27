import Foundation

// v0.9 정리 비서 공용 계약 (docs/V09.md §1·§2·§4). E1(정리 실행·규칙)·E2(작업 지도·Claude 정리 계획)·E3(화면)·앱 브리지가 함께 쓴다.
// 여러 담당이 함께 쓰므로 합의 없이 바꾸지 않는다.

/// 자리(place)가 있는 구역. rawValue가 JSON 값이다.
enum TidyZone: String {
    case loose = "loose"            // 볼트가 아닌 출처 루트의 맨 위 항목 (예: ~/Desktop/보고서)
    case inbox = "inbox"            // <볼트>/_Inbox/*
    case vaultRoot = "vault-root"   // <볼트> 루트의 낱개 파일
    case workspace = "workspace"    // <볼트>/_workspace/*
    case project = "project"        // <볼트>/1-Projects/*
    case area = "area"              // <볼트>/2-Areas/*
    case resource = "resource"      // <볼트>/3-Resources/*
    case archive = "archive"        // <볼트>/4-Archive/*

    /// 볼트 기준 첫 조각 → 구역 (자리의 부모 폴더 이름).
    static func of(paraTop: String) -> TidyZone? {
        switch paraTop {
        case "_Inbox": return .inbox
        case "_workspace": return .workspace
        case "1-Projects": return .project
        case "2-Areas": return .area
        case "3-Resources": return .resource
        case "4-Archive": return .archive
        default: return nil
        }
    }
    /// 정리 안 됨으로 보는 구역.
    var isUnfiled: Bool { self == .loose || self == .inbox || self == .vaultRoot }
}

/// 자리 플래그 (TidyPlace.flags 값).
enum TidyFlag {
    static let git = "git"             // .git 이 있다 (코드 저장소)
    static let code = "code"           // package.json·manifest.json·pom.xml·build.gradle(.kts)·Cargo.toml·go.mod·pyproject.toml·*.xcodeproj
    static let secret = "secret"       // .env·.env.*·*.pem·*.key·*.p12·id_rsa*·id_ed25519*·credentials* (내용은 절대 읽지 않는다)
    static let hidden = "hidden"       // 이름이 . 으로 시작
    static let vault = "vault"         // .obsidian 이 있다 (볼트 자체 — 옮기기 대상 아님)
    static let frozen = "frozen"       // 볼트 CLAUDE.md 규칙표가 동결·참조용으로 적은 곳
    static let empty = "empty"         // 파일이면 3바이트 이하, 폴더면 안에 파일이 없다
    static let excluded = "excluded"   // 출처 제외 폴더 안
    static let rawData = "raw"         // 스스로가 원자료 폴더
    static let truncated = "truncated" // 걷기 상한(파일 5,000·깊이 8)에 닿아 수가 덜 셌다
}

/// 원자료 폴더 (색인 제외 후보, §4.1).
struct TidyRaw {
    let path: String             // 절대 경로(NFC)
    let sourceId: String         // 제외를 적을 출처 (이 경로를 색인하는 가장 안쪽 출처)
    let rel: String              // 그 출처 기준 상대 경로 (excludeFolders에 넣을 값)
    let files: Int
    let kinds: [String: Int]
    let certain: Bool            // 이름이 원자료 이름이고 md 5% 이하 → 자동 제외 가능
    let sample: [String]         // 파일 이름 예 최대 3개

    var json: [String: Any] {
        ["path": path, "sourceId": sourceId, "rel": rel, "files": files, "kinds": kinds, "certain": certain, "sample": sample]
    }
}

/// 자리 하나 — 파일이나 폴더 (§4.1). 인벤토리가 만든다(E1). 작업 지도·Claude 입력(E2)이 읽는다.
struct TidyPlace {
    let id: String               // "p:" + 절대 경로 sha1 앞 12자 (같은 경로 → 같은 id). TidyPlace.makeID
    let path: String             // 절대 경로(NFC, 끝 "/" 없음)
    let name: String             // 마지막 경로 조각
    let isDir: Bool
    let zone: TidyZone
    let vaultRoot: String?       // 볼트 안이면 볼트 루트 절대 경로
    let paraRel: String?         // 볼트 기준 상대 경로 ("1-Projects/앱-리서치")
    let sourceId: String?        // 이 경로를 색인하는 가장 안쪽 출처 (없으면 nil — 예: 출처 조상의 볼트 자리)
    let label: String            // 사람이 읽는 위치: "데스크톱 › 보고서", "1-Projects › 사이드-프로젝트"
    let files: Int               // 숨김 제외 파일 수 (하위 포함, 상한 5000). 파일 자리는 1
    let mdFiles: Int
    let kinds: [String: Int]     // 확장자별 개수(소문자, 상위 6개). 확장자 없음은 ""
    let size: Int                // 바이트 합 (상한까지)
    let lastModified: Double     // 숨김 제외 가장 최근 수정 시각(epoch). 빈 폴더는 폴더 자신의 수정 시각
    let ticketKeys: [String]     // 이름·안쪽 문서 issueKeys에서 (많이 나온 순, 최대 3)
    let flags: Set<String>       // TidyFlag 값
    let titles: [String]         // 안쪽 색인 문서 제목 (최근 순, 최대 8) — Claude 입력용
    let raw: [TidyRaw]           // 안쪽 원자료 폴더 (이미 색인에서 뺀 곳은 제외). 자리 자신이 원자료면 자기 자신도 들어간다
    let docIds: [String]         // 안쪽 색인 문서 id (최근 순, 최대 20)

    static func makeID(_ path: String) -> String { "p:" + TidyHash.short(Indexer.nfc(path)) }

    var json: [String: Any] {
        ["id": id, "path": path, "name": name, "isDir": isDir, "zone": zone.rawValue,
         "vaultRoot": vaultRoot.map { $0 as Any } ?? NSNull(), "paraRel": paraRel.map { $0 as Any } ?? NSNull(),
         "sourceId": sourceId.map { $0 as Any } ?? NSNull(), "label": label,
         "files": files, "md": mdFiles, "kinds": kinds, "size": size, "lastModified": lastModified,
         "tickets": ticketKeys, "flags": flags.sorted(), "titles": titles, "raw": raw.map { $0.json }, "docIds": docIds]
    }
}

/// 옮길 수 있는 기존 폴더 (§4.1 destinations).
struct TidyDestination {
    let path: String             // 절대 경로
    let label: String            // "2-Areas › 프로젝트 › 운영"
    let zone: TidyZone?          // 볼트 안이면 그 구역, 코드 폴더면 nil
    let isCode: Bool

    var json: [String: Any] {
        ["path": path, "label": label, "zone": zone.map { $0.rawValue as Any } ?? NSNull(), "isCode": isCode]
    }
}

struct TidyInventory {
    let generated: Double
    let places: [TidyPlace]
    let vaults: [String]                 // 감지한 볼트 루트
    let destinations: [TidyDestination]
    let hash: String                     // 시간이 흘러도 안 바뀌는 해시 (경로·개수·수정 일·플래그)

    static let empty = TidyInventory(generated: 0, places: [], vaults: [], destinations: [], hash: "")

    func place(id: String) -> TidyPlace? { places.first { $0.id == id } }
    func place(path: String) -> TidyPlace? { let p = Indexer.nfc(path); return places.first { $0.path == p } }
}

/// 정리 제안의 동작 (TidyItem.op).
enum TidyOp {
    static let move = "move"         // from 항목들을 to 폴더 안으로 (to가 없으면 만든다)
    static let merge = "merge"       // from 폴더 하나의 내용을 to 폴더 안으로 합치고, 빈 from 폴더를 지운다(rmdir)
    static let archive = "archive"   // from을 <볼트>/4-Archive/ 아래로 (to는 Synapse가 정한다)
    static let exclude = "exclude"   // 원자료 폴더를 색인에서 뺀다 (파일은 그대로)
    static let trash = "trash"       // Synapse 휴지통으로 (항상 승인, 자동 없음)
    static let note = "note"         // 알림만 (예: 데스크톱의 비밀 파일). 확인하면 닫힌다
    static let all: Set<String> = [move, merge, archive, exclude, trash, note]
    /// 자동 적용이 될 수 있는 동작.
    static let autoable: Set<String> = [move, merge, archive, exclude]
}

/// 정리 계획의 묶음 (TidyItem.group).
enum TidyGroup {
    static let desktop = "desktop"
    static let tickets = "tickets"
    static let archive = "archive"
    static let index = "index"
    static let check = "check"
    static let order = [desktop, tickets, archive, index, check]
    static let titles: [String: String] = [desktop: "데스크톱 정리", tickets: "티켓 폴더", archive: "보관", index: "색인", check: "확인 필요"]
    static func valid(_ g: String) -> String { order.contains(g) ? g : check }
}

/// 확실성 (TidyItem.certainty).
enum TidyCertainty {
    static let certain = "certain"
    static let likely = "likely"
    static let unsure = "unsure"
    static let all: Set<String> = [certain, likely, unsure]
    static func confidence(_ c: String) -> Double { c == certain ? 0.95 : c == likely ? 0.75 : 0.5 }
    static let labels: [String: String] = [certain: "확실", likely: "아마", unsure: "확인 필요"]
}

/// 정리 제안 하나의 내용 (suggestions.kind = "tidy", payload). 규칙(E1)과 Claude 정리 계획(E2 → ingest)이 만든다.
struct TidyItem {
    var op: String               // TidyOp
    var from: [String]           // 절대 경로들. exclude는 원자료 폴더 하나. note는 대상 자리
    var to: String?              // move·merge: 목적지 폴더 절대 경로(없으면 만든다). archive는 nil 가능(Synapse가 정함). exclude·trash·note: nil
    var title: String            // "PROJ-123 가이드를 티켓 폴더로" (40자)
    var reason: String           // 한 문장 (120자)
    var evidence: [String]       // 짧은 근거 (최대 4개, 각 40자)
    var certainty: String        // TidyCertainty
    var origin: String           // "rule" | "claude"
    var group: String            // TidyGroup
    var signature: String        // 배우기 키 (규칙 id 또는 TidySignature.of). Claude 출력에는 없고 Tidy가 채운다

    var json: [String: Any] {
        ["op": op, "from": from, "to": to.map { $0 as Any } ?? NSNull(), "title": title, "reason": reason,
         "evidence": evidence, "certainty": certainty, "origin": origin, "group": group, "signature": signature]
    }

    /// JSON → TidyItem. 모르는 op·빈 from이면 nil. 글은 길이를 자르고, 확실성·묶음은 모르면 unsure·check.
    init?(json o: [String: Any]) {
        guard let op = o["op"] as? String, TidyOp.all.contains(op) else { return nil }
        let from = ((o["from"] as? [Any]) ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }.map { Indexer.nfc($0) }
        guard !from.isEmpty else { return nil }
        self.op = op
        self.from = from
        self.to = (o["to"] as? String).flatMap { $0.isEmpty ? nil : Indexer.nfc($0) }
        self.title = TidyText.clip(o["title"] as? String ?? "", 40)
        self.reason = TidyText.clip(o["reason"] as? String ?? "", 120)
        self.evidence = ((o["evidence"] as? [Any]) ?? []).compactMap { $0 as? String }.map { TidyText.clip($0, 40) }.filter { !$0.isEmpty }.prefix(4).map { $0 }
        let c = o["certainty"] as? String ?? ""
        self.certainty = TidyCertainty.all.contains(c) ? c : TidyCertainty.unsure
        let origin = o["origin"] as? String ?? "claude"
        self.origin = origin == "rule" ? "rule" : "claude"
        self.group = TidyGroup.valid(o["group"] as? String ?? "")
        self.signature = o["signature"] as? String ?? ""
    }

    init(op: String, from: [String], to: String?, title: String, reason: String, evidence: [String],
         certainty: String, origin: String, group: String, signature: String) {
        self.op = op; self.from = from; self.to = to; self.title = title; self.reason = reason; self.evidence = evidence
        self.certainty = certainty; self.origin = origin; self.group = group; self.signature = signature
    }
}

/// 기본 규칙 id = 배우기 키 (§4.2).
enum TidyRule {
    static let ticketFile = "move:ticket-file"           // 자동(기본 켬)
    static let raw = "exclude:raw"                       // 자동(기본 켬) — certain만
    static let ticketNew = "move:ticket-new"
    static let split = "merge:split"
    static let staleProject = "archive:stale-project"
    static let doneWorkspace = "archive:done-workspace"
    static let empty = "trash:empty"                     // 자동 불가
    static let code = "move:code"
    static let secret = "note:secret"                    // 알림
    static let builtinAuto: Set<String> = [ticketFile, raw]
    static let all = [ticketFile, raw, ticketNew, split, staleProject, doneWorkspace, empty, code, secret]
    static let labels: [String: String] = [
        ticketFile: "티켓 번호 파일을 티켓 폴더로",
        raw: "원자료 폴더를 색인에서 빼기",
        ticketNew: "티켓 산출물을 새 티켓 폴더로",
        split: "갈라진 티켓 산출물 합치기",
        staleProject: "30일 넘은 프로젝트 보관",
        doneWorkspace: "끝난 티켓 폴더 보관",
        empty: "빈 파일 휴지통으로",
        code: "코드 폴더를 코드 폴더로",
        secret: "비밀 파일 알림",
    ]
}

/// 배우기 키 계산 (§1·§5). Claude 항목은 Synapse가 계산한다.
enum TidySignature {
    /// op:구역>목적지키. 목적지키 = 볼트 기준 앞 두 조각(2-Areas/프로젝트, 3-Resources/데이터베이스),
    /// _workspace·1-Projects·4-Archive는 첫 조각만, 코드 폴더는 "code", 모르면 "other". exclude·trash·note는 op:구역.
    static func of(op: String, fromZone: TidyZone?, toParaRel: String?, toCode: Bool) -> String {
        let z = fromZone?.rawValue ?? "other"
        if op == TidyOp.exclude || op == TidyOp.trash || op == TidyOp.note { return "\(op):\(z)" }
        if op == TidyOp.archive { return "\(op):\(z)>4-Archive" }
        var key = "other"
        if toCode { key = "code" }
        else if let rel = toParaRel, !rel.isEmpty {
            let parts = rel.split(separator: "/").map(String.init)
            if let first = parts.first {
                if first == "2-Areas" || first == "3-Resources" { key = parts.count > 1 ? first + "/" + parts[1] : first }
                else { key = first }
            }
        }
        return "\(op):\(z)>\(key)"
    }

    /// 사람이 읽는 라벨. 기본 규칙은 TidyRule.labels.
    static func label(_ sig: String) -> String {
        if let l = TidyRule.labels[sig] { return l }
        let zoneLabel: [String: String] = ["loose": "데스크톱", "inbox": "받은 문서함", "vault-root": "볼트 루트", "workspace": "작업 공간",
                                           "project": "프로젝트", "area": "영역", "resource": "자료", "archive": "보관", "other": "기타"]
        let opLabel: [String: String] = ["move": "옮기기", "merge": "합치기", "archive": "보관", "exclude": "색인에서 빼기", "trash": "휴지통", "note": "알림"]
        let parts = sig.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return sig }
        let op = opLabel[parts[0]] ?? parts[0]
        let rest = parts[1].split(separator: ">", maxSplits: 1).map(String.init)
        let from = zoneLabel[rest[0]] ?? rest[0]
        if rest.count == 2 {
            let to = rest[1] == "code" ? "코드 폴더" : rest[1].replacingOccurrences(of: "/", with: " › ")
            return "\(from)에서 \(to)로 \(op)"
        }
        return "\(from) \(op)"
    }
}

/// 정리 설정 키 (brain.sqlite settings, 값은 문자열). 앱 setBrainSetting 허용 목록에 들어간다.
enum TidySetting {
    static let auto = "tidy.auto"               // "1"(기본) | "0" — 자동 정리 전체
    static let dailyCap = "tidy.dailyCap"       // 기본 "20"
    static let codeFolder = "tidy.codeFolder"   // "" = ~/IdeaProjects (있으면)
    static let reviewDay = "tidy.reviewDay"     // "mon"…"fri" | "off" (기본 "fri")
    static let workmapScope = "workmap.scope"   // "all"(기본) | "work" | "personal"
    static let rulePrefix = "tidy.rule."        // + 서명 → "auto" | "ask" | "off". 없으면 기본 규칙은 builtinAuto면 auto, 아니면 미정
    static let lastPlan = "tidy.lastPlan"       // JSON {summary, questions, at, runId} — 마지막 Claude 정리 계획
    static let appKeys: Set<String> = [auto, dailyCap, codeFolder, reviewDay, workmapScope]
    static let defaultDailyCap = 20
}

/// 정리 비서 입구. E1의 Tidy가 구현한다. 모두 사서 큐(ctx.queue)에서 부른다(Brain 파사드가 call로 감싼다).
protocol TidyAPI: AnyObject {
    /// 인벤토리 (캐시: 색인 변화·10분). force면 새로 만든다.
    func inventory(force: Bool) -> TidyInventory
    /// 결정적 규칙으로 제안을 만들고, autoApply면 자동 규칙을 적용한다. {ok, proposed, applied}
    func runRules(autoApply: Bool) -> [String: Any]
    /// Claude 정리 계획 결과(E2 normalize 출력 {summary, items, questions})를 제안으로 넣는다. {ok, proposed, applied}
    func ingest(result: [String: Any], runId: String?) -> [String: Any]
    /// 정리 계획 화면 (§4.9)
    func plan() -> [String: Any]
    /// approve | reject | later | dismiss | to (§4.11)
    func decide(id: String, action: String, to: String?) -> [String: Any]
    /// 묶음 승인. ids가 있으면 그중 아직 대기 중인 것만(화면이 확인 창에서 보여 준 카드), 없으면 그 묶음의 대기 전부 (리뷰 #4)
    func decideGroup(group: String, ids: [String]?) -> [String: Any]
    func undo(batchId: String?) -> [String: Any]
    func promote(signature: String, accept: Bool) -> [String: Any]
    func rules() -> [String: Any]
    func setRule(signature: String, state: String) -> [String: Any]
    /// §4.10
    func counts() -> [String: Any]
    /// 대기 중 tidy 카드 (§4.9 카드 모양). paths·keys가 비면 전부, 아니면 그 경로 안쪽이나 그 티켓 키 자리에 걸린 것만.
    func cards(paths: [String], keys: [String]) -> [[String: Any]]
    /// Claude 입력용 (§4.8)
    func context() -> [String: Any]
    /// 가장 최근 tidy 배치 id (⌥⌘Z가 고를 때). 없으면 nil
    func lastBatch() -> String?
}

/// 주간 정리 리뷰 (§5·§7.3). 리뷰 요일이면 {due: true, day, label}, 아니면 nil.
enum TidyReview {
    static let days: [String: (weekday: Int, label: String)] = [
        "mon": (2, "월요일"), "tue": (3, "화요일"), "wed": (4, "수요일"), "thu": (5, "목요일"), "fri": (6, "금요일"),
    ]
    static func today(setting: String?, now: Date) -> [String: Any]? {
        let key = (setting ?? "").isEmpty ? "fri" : setting!
        guard let d = days[key], Calendar.current.component(.weekday, from: now) == d.weekday else { return nil }
        return ["due": true, "day": d.label, "label": "\(d.label) 정리 리뷰"]
    }
}

// MARK: - 작은 도우미 (공용)

enum TidyHash {
    /// sha1 앞 12자 (16진).
    static func short(_ s: String) -> String { String(Organizer.sha1(Data(s.utf8)).prefix(12)) }
}

enum TidyText {
    static func clip(_ s: String, _ n: Int) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= n ? t : String(t.prefix(n - 1)) + "…"
    }
}
