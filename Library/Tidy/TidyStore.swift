import Foundation

// v0.9 정리 제안 저장 (docs/V09.md §4.3). suggestions 표의 kind "tidy" 행. id = "t:" + 12자.
// 상태: pending → applying → applied | failed · rejected · later(7일 뒤 pending) · withdrawn · dismissed(note) · undone.

struct TidySug {
    var id: String
    var item: TidyItem
    var extra: [String: Any]        // payload 중 TidyItem 밖 값: snap · run · impact · auto · noAuto · flags · zone · snapHash
    var docId: String?
    var state: String
    var created: Double
    var decided: Double?
    var batchId: String?
    var cooldown: Double?
    var error: String?

    var key: String { TidySug.key(item) }
    var signature: String { item.signature }
    var auto: Bool { (extra["auto"] as? Bool) == true }
    var snap: [TidyStamp] { ((extra["snap"] as? [[String: Any]]) ?? []).compactMap { TidyStamp(json: $0) } }
    var impact: [String: Any] { (extra["impact"] as? [String: Any]) ?? ["files": 0, "links": 0, "warnings": [String]()] }
    var payload: [String: Any] { item.json.merging(extra) { a, _ in a } }

    static func key(_ i: TidyItem) -> String { i.op + "|" + i.from.sorted().joined(separator: "\u{1}") + "|" + (i.to ?? "") }
}

extension Tidy {

    private static let cols = "id, doc_id, payload, state, created, decided, batch_id, cooldown_until, error"

    func sugs(_ whereSQL: String, _ args: [SQLValue] = [], order: String = "created, id") -> [TidySug] {
        var out: [TidySug] = []
        try? ctx.db.sql.query("SELECT \(Tidy.cols) FROM suggestions WHERE kind='tidy' AND (\(whereSQL)) ORDER BY \(order)", args) { r in
            let p = (BrainFormat.parse(r.text(2)) as? [String: Any]) ?? [:]
            guard let item = TidyItem(json: p) else { return }
            var extra = p
            for k in ["op", "from", "to", "title", "reason", "evidence", "certainty", "origin", "group", "signature"] { extra[k] = nil }
            out.append(TidySug(id: r.text(0), item: item, extra: extra, docId: r.isNull(1) ? nil : r.text(1), state: r.text(3),
                               created: r.double(4), decided: r.isNull(5) ? nil : r.double(5), batchId: r.isNull(6) ? nil : r.text(6),
                               cooldown: r.isNull(7) ? nil : r.double(7), error: r.isNull(8) ? nil : r.text(8)))
        }
        return out
    }

    func sug(_ id: String) -> TidySug? { sugs("id=?", [.text(id)]).first }

    @discardableResult
    func save(_ s: TidySug) -> Bool {
        func opt(_ v: String?) -> SQLValue { v.map { .text($0) } ?? .null }
        func optD(_ v: Double?) -> SQLValue { v.map { .double($0) } ?? .null }
        return (try? ctx.db.sql.run("""
            INSERT OR REPLACE INTO suggestions(id, kind, doc_id, path, payload, confidence, reasons, origin, rule_key, state,
              created, decided, batch_id, cooldown_until, error) VALUES(?,'tidy',?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [.text(s.id), opt(s.docId), opt(s.item.from.first), .text(BrainFormat.json(s.payload)),
                  .double(TidyCertainty.confidence(s.item.certainty)), .text(BrainFormat.json(s.item.evidence)), .text(s.item.origin),
                  .text(s.item.signature), .text(s.state), .double(s.created), optD(s.decided), opt(s.batchId), optD(s.cooldown), opt(s.error)])) != nil
    }

    func setState(_ id: String, _ state: String, error: String? = nil, batch: String? = nil, cooldown: Double? = nil, extra: [String: Any]? = nil,
                  clearBatch: Bool = false) {
        guard var s = sug(id) else { return }
        s.state = state; s.decided = nowTS
        if let e = error { s.error = e }
        if let b = batch { s.batchId = b }
        if clearBatch { s.batchId = nil }
        if let c = cooldown { s.cooldown = c }
        if let x = extra { s.extra.merge(x) { $1 } }
        save(s)
    }

    /// pending·later → applying. 이긴 쪽만 true (두 번 적용 막기).
    /// 배치 id를 미리 적어 둔다 — 적용 중에 앱이 끝나도 카드에서 되돌릴 수 있게.
    func claim(_ id: String, batch: String? = nil) -> Bool {
        let n = (try? ctx.db.sql.run("UPDATE suggestions SET state='applying', decided=?, batch_id=coalesce(?, batch_id) WHERE id=? AND kind='tidy' AND state IN ('pending','later')",
                                     [.double(nowTS), batch.map { .text($0) } ?? .null, .text(id)])) ?? 0
        return n == 1
    }

    func newSugID(_ seed: String) -> String { "t:" + TidyHash.short(seed + "\n" + UUID().uuidString) }

    // MARK: 카드 (§4.9)

    func card(_ s: TidySug, vm: VaultMap, sources: [TidySource], code: String?) -> [String: Any] {
        let i = s.item
        let snaps = Dictionary(s.snap.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let from: [[String: Any]] = i.from.map { p in
            let st = snaps[p]
            return ["path": p, "label": label(for: p, vm: vm, sources: sources, codeFolder: code),
                    "isDir": st?.isDir ?? TidyFS.isDir(TidyFS.rawPath(p)), "files": st?.files ?? 0]
        }
        var to: Any = NSNull()
        if let dst = displayTarget(s.item) {
            to = ["path": dst, "label": label(for: dst, vm: vm, sources: sources, codeFolder: code), "exists": TidyFS.exists(TidyFS.rawPath(dst))]
        }
        let created = Date(timeIntervalSince1970: s.created)
        var impact = s.impact
        if impact["files"] == nil { impact["files"] = s.snap.reduce(0) { $0 + $1.files } }
        return ["id": s.id, "kind": "tidy", "op": i.op, "title": i.title, "from": from, "to": to, "reason": i.reason, "evidence": i.evidence,
                "certainty": i.certainty, "certaintyLabel": TidyCertainty.labels[i.certainty] ?? "", "origin": i.origin,
                "originLabel": i.origin == "rule" ? "규칙" : "Claude", "signature": i.signature, "signatureLabel": TidySignature.label(i.signature),
                "group": i.group, "groupTitle": TidyGroup.titles[i.group] ?? "", "impact": impact, "state": s.state,
                "error": s.error.map { $0 as Any } ?? NSNull(), "auto": s.auto,
                "createdLabel": BrainFormat.whenLabel(created, now: ctx.now()), "canAuto": canAuto(s),
                "batchId": s.batchId.map { $0 as Any } ?? NSNull()]
    }

    /// 화면에 보일 목적지: move·merge는 to 폴더, archive는 최종 경로(<보관>/<이름>), 나머지는 없음.
    func displayTarget(_ i: TidyItem) -> String? {
        switch i.op {
        case TidyOp.move, TidyOp.merge: return i.to
        case TidyOp.archive:
            guard let f = i.from.first, let base = i.to ?? archiveBase(for: f) else { return nil }
            return base + "/" + (f as NSString).lastPathComponent
        default: return nil
        }
    }

    /// 자동 규칙이 될 수 있는 카드인가 (동작이 자동 가능하고, 막는 플래그가 없다).
    func canAuto(_ s: TidySug) -> Bool {
        guard TidyOp.autoable.contains(s.item.op), s.item.certainty != TidyCertainty.unsure else { return false }
        let flags = Set((s.extra["flags"] as? [String]) ?? [])
        return flags.isDisjoint(with: [TidyFlag.hidden, TidyFlag.secret, TidyFlag.git, TidyFlag.code, TidyFlag.frozen])
    }

    /// "방금" · "N분 전" · "N시간 전" · "N일 전"
    func agoLabel(_ t: Double) -> String {
        let d = max(0, nowTS - t)
        if d < 60 { return "방금" }
        if d < 3600 { return "\(Int(d / 60))분 전" }
        if d < 86400 { return "\(Int(d / 3600))시간 전" }
        return "\(Int(d / 86400))일 전"
    }
}
