import Foundation
import CryptoKit

// v0.5 정리(S2) — docs/V05.md §6. 규칙표·자리 제안·제안 수명·적용·되돌리기.
// 모든 메서드는 ctx.queue에서 불린다(파사드가 넘긴다). 볼트 쓰기는 OrganizerMover의
// "승인된 이동"과 "그 이동에 필요한 링크 수정"뿐이다(§1.4). frontmatter·태그 쓰기, 삭제, 새 폴더 만들기는 없다.

/// 정리 대상 볼트(옵시디언 출처) 하나.
struct OrgVault {
    let sourceId: String
    let root: String                 // 실제 경로(NFC, 끝 "/" 없음)
    let excludeFolders: [String]     // v0.4 제외 폴더
    func abs(_ rel: String) -> String { rel.isEmpty ? root : root + "/" + rel }
    func rel(_ abs: String) -> String? { Indexer.relativePath(path: Indexer.nfc(abs), root: root) }
    func docID(_ rel: String) -> String { sourceId + ":" + Indexer.nfc(rel) }
}

/// suggestions 한 행.
struct OrgSuggestion {
    var id: String
    var kind: String
    var docId: String?
    var path: String?
    var payload: [String: Any]
    var confidence: Double
    var reasons: [String]
    var origin: String
    var ruleKey: String?
    var state: String
    var created: Double
    var decided: Double?
    var batchId: String?
    var cooldownUntil: Double?
    var error: String?
}

final class Organizer: OrganizerModule {
    let ctx: BrainContext
    /// 시험 전용: 링크 고쳐 쓰기를 일부러 망가뜨려 사후 검사·자동 롤백을 확인한다.
    static var testBreakRewrite = false
    /// 시험 전용: 이동 뒤·링크 고쳐 쓰기 직전에 불린다(그사이 사용자가 파일을 고친 상황 재현).
    static var testBeforeRewrite: (() -> Void)? = nil

    /// 볼트 루트 → 컴파일 결과(트리 주석 등 메모리 캐시).
    var compiledCache: [String: PolicyCompile] = [:]
    var statsCache: (key: String, model: OrgStats)?
    /// 배치 조각 처리: 남은 (sourceId, docId)와 볼트별 캐시(파일 목록·링크 색인).
    var batchWork: [(String, String)] = []
    var batchCache: [String: (rules: [PolicyRule], files: VaultFiles, index: OrgLinkIndex?)] = [:]
    var batchCreated = 0

    init(ctx: BrainContext) {
        self.ctx = ctx
        if ctx.mode == .app { noteInterrupted() }
    }

    // MARK: 시각

    var now: Date { ctx.now() }
    var nowTS: Double { ctx.now().timeIntervalSince1970 }

    /// "오늘 12:00" · "어제 09:12" · "10/21 09:12"
    func clockLabel(_ t: Double?) -> String? {
        guard let t = t else { return nil }
        let d = Date(timeIntervalSince1970: t), cal = Calendar.current
        let hm = String(format: "%02d:%02d", cal.component(.hour, from: d), cal.component(.minute, from: d))
        if cal.isDate(d, inSameDayAs: now) { return "오늘 " + hm }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "어제 " + hm }
        return "\(cal.component(.month, from: d))/\(cal.component(.day, from: d)) " + hm
    }

    var startOfToday: Double { Calendar.current.startOfDay(for: now).timeIntervalSince1970 }

    // MARK: 볼트

    func vaults() -> [OrgVault] {
        ctx.sources().filter { $0.enabled && $0.kind == .obsidian && $0.path != nil }.map {
            OrgVault(sourceId: $0.id, root: Indexer.nfc(Indexer.realPath($0.path!)), excludeFolders: Indexer.excludedFolders($0))
        }
    }

    func vault(sourceId: String) -> OrgVault? { vaults().first { $0.sourceId == sourceId } }

    func vault(forAbs path: String) -> OrgVault? {
        let p = Indexer.nfc(Indexer.realPath(path))
        return vaults().first { p.hasPrefix($0.root + "/") }
    }

    /// 볼트 안 모든 파일(숨김·제외 이름 폴더 제외)의 상대 경로.
    func listFiles(_ v: OrgVault) -> VaultFiles { VaultFiles(Indexer.listFiles(root: v.root)) }

    func isDir(_ abs: String) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: abs, isDirectory: &d) && d.boolValue
    }

    /// 파일 수정 시각·크기 (없으면 nil).
    func fileStamp(_ abs: String) -> (mtime: Double, size: Int)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: abs),
              (a[.type] as? FileAttributeType) == .typeRegular else { return nil }
        return (((a[.modificationDate] as? Date) ?? .distantPast).timeIntervalSince1970, (a[.size] as? NSNumber)?.intValue ?? 0)
    }

    static func sha1(_ d: Data) -> String { Insecure.SHA1.hash(data: d).map { String(format: "%02x", $0) }.joined() }
    static func sha1(_ s: String) -> String { sha1(Data(s.utf8)) }

    func newID(_ prefix: String, _ seed: String) -> String {
        prefix + String(Organizer.sha1(seed + "\n" + UUID().uuidString).prefix(12))
    }

    static func isMarkdown(_ rel: String) -> Bool {
        let e = (rel as NSString).pathExtension.lowercased()
        return e == "md" || e == "markdown"
    }
    static func parent(_ rel: String) -> String { (rel as NSString).deletingLastPathComponent }
    static func fileName(_ rel: String) -> String { (rel as NSString).lastPathComponent }
    /// 폴더 표기: 끝에 "/" (루트는 "").
    static func folderKey(_ f: String) -> String {
        let t = f.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return t.isEmpty ? "" : t + "/"
    }

    // MARK: suggestions 저장소

    private static let sugCols = "id, kind, doc_id, path, payload, confidence, reasons, origin, rule_key, state, created, decided, batch_id, cooldown_until, error"

    func suggestions(_ whereSQL: String, _ args: [SQLValue] = []) -> [OrgSuggestion] {
        var out: [OrgSuggestion] = []
        try? ctx.db.sql.query("SELECT \(Organizer.sugCols) FROM suggestions WHERE \(whereSQL)", args) { r in
            out.append(OrgSuggestion(
                id: r.text(0), kind: r.text(1), docId: r.isNull(2) ? nil : r.text(2), path: r.isNull(3) ? nil : r.text(3),
                payload: (BrainFormat.parse(r.text(4)) as? [String: Any]) ?? [:], confidence: r.double(5),
                reasons: (BrainFormat.parse(r.text(6)) as? [String]) ?? [], origin: r.text(7),
                ruleKey: r.isNull(8) ? nil : r.text(8), state: r.text(9), created: r.double(10),
                decided: r.isNull(11) ? nil : r.double(11), batchId: r.isNull(12) ? nil : r.text(12),
                cooldownUntil: r.isNull(13) ? nil : r.double(13), error: r.isNull(14) ? nil : r.text(14)))
        }
        return out
    }

    func suggestion(_ id: String) -> OrgSuggestion? { suggestions("id=?", [.text(id)]).first }

    func save(_ s: OrgSuggestion) {
        func opt(_ v: String?) -> SQLValue { v.map { .text($0) } ?? .null }
        func optD(_ v: Double?) -> SQLValue { v.map { .double($0) } ?? .null }
        _ = try? ctx.db.sql.run("INSERT OR REPLACE INTO suggestions(\(Organizer.sugCols)) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [
            .text(s.id), .text(s.kind), opt(s.docId), opt(s.path), .text(BrainFormat.json(s.payload)), .double(s.confidence),
            .text(BrainFormat.json(s.reasons)), .text(s.origin), opt(s.ruleKey), .text(s.state), .double(s.created),
            optD(s.decided), opt(s.batchId), optD(s.cooldownUntil), opt(s.error)])
    }

    func setState(_ id: String, _ state: String, error: String? = nil, batch: String? = nil, cooldown: Double? = nil) {
        guard var s = suggestion(id) else { return }
        s.state = state; s.decided = nowTS
        if let e = error { s.error = e }
        if let b = batch { s.batchId = b }
        if let c = cooldown { s.cooldownUntil = c }
        save(s)
    }

    // MARK: 출처 표기

    /// "rules" | "mcp:claude" → 카드 origin ("rules" | "claude" | "codex" | 이름)
    static func cardOrigin(_ origin: String) -> String { origin.hasPrefix("mcp:") ? String(origin.dropFirst(4)) : origin }
    static func originLabel(_ origin: String) -> String {
        switch cardOrigin(origin) {
        case "rules": return "규칙"
        case "claude": return "Claude 제안"
        case "claude-digest": return "Claude 정리 제안"   // v0.8: 티켓 화면 Claude 브리핑에서 올린 것
        case "codex": return "Codex 제안"
        case let n: return n + " 제안"
        }
    }
    /// ai_log origin (rules · claude · codex · 그 밖 이름).
    static func logOrigin(_ origin: String) -> String { cardOrigin(origin) }

    static func grade(_ c: Double) -> String { c >= 0.985 ? "확정" : c >= 0.9 ? "추천" : "후보" }
    static func gradeRank(_ g: String) -> Int { ["확정": 0, "추천": 1, "후보": 2][g] ?? 3 }

    // MARK: OrganizerModule — 짧은 것

    func pendingCount() -> Int {
        var n = 0
        try? ctx.db.sql.query("SELECT count(*) FROM suggestions WHERE state='pending' AND kind IN ('move','rules','policy','delete')") { n = Int($0.int(0)) }
        return n
    }

    func refreshPolicy() { _ = ensurePolicy(force: false) }
}
