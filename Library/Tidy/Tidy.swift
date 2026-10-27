import Foundation

// v0.9 정리 비서 (docs/V09.md §4). E1 담당. 사서 큐(ctx.queue)에서만 부른다. Brain 파사드가 call로 감싼다.
// 파일 나눔: TidyInventory(자리·원자료 감지) · TidyRules(규칙·Claude 결과·자동·배우기) · TidyOps(적용·되돌리기·휴지통)
//          · TidyLinks(폴더 이동 링크 계획) · TidyStore(제안 저장·카드).

final class Tidy: TidyAPI {
    let ctx: BrainContext
    let organizer: Organizer

    // 시험 전용 고리
    static var testEXDEV = false                       // 이름 바꾸기를 "다른 디스크"로 실패시킨다
    static var testBreakRewrite = false                // 링크 고쳐 쓰기를 망가뜨려 사후 검사 롤백을 본다
    static var testBeforeRewrite: (() -> Void)? = nil  // 이동 뒤·링크 고쳐 쓰기 직전
    static var testAfterRevalidate: (() -> Void)? = nil
    static var testFailRename: ((String) -> Bool)? = nil    // 이 출발지의 이름 바꾸기를 실패시킨다

    // 캐시 (사서 큐 안에서만)
    var invCache: TidyInventory?
    var invStamp = ""
    var invAt = Date.distantPast
    var placeInfo: [String: TidyPlaceInfo] = [:]
    var policyCache: [String: (stamp: String, rules: [PolicyRule])] = [:]
    var corpusCache: [String: TidyCorpus] = [:]
    var lastInventoryMs = 0.0
    var secretMemo: [String: String] = [:]     // 비밀 검사 메모 (경로 → 이유, "" = 깨끗함)

    init(ctx: BrainContext, organizer: Organizer) {
        self.ctx = ctx
        self.organizer = organizer
    }

    // MARK: 시각·설정

    var nowTS: Double { ctx.now().timeIntervalSince1970 }
    var startOfToday: Double { Calendar.current.startOfDay(for: ctx.now()).timeIntervalSince1970 }

    var autoOn: Bool { ctx.db.setting(TidySetting.auto) != "0" }
    var dailyCap: Int { Int(ctx.db.setting(TidySetting.dailyCap) ?? "") ?? TidySetting.defaultDailyCap }
    var reviewDay: String { let v = ctx.db.setting(TidySetting.reviewDay) ?? ""; return v.isEmpty ? "fri" : v }

    /// 코드 폴더: 설정값, 비면 <홈>/IdeaProjects가 있을 때 그것. 없으면 nil.
    func codeFolderResolved() -> String? {
        let set = (ctx.db.setting(TidySetting.codeFolder) ?? "").trimmingCharacters(in: .whitespaces)
        let raw = set.isEmpty ? ctx.env.userHome + "/IdeaProjects"
            : (set.hasPrefix("~") ? ctx.env.userHome + String(set.dropFirst()) : set)
        guard TidyFS.isDir(raw) else { return nil }
        return Indexer.nfc(Indexer.realPath(raw))
    }

    /// 서명 상태: auto | ask | off. 정하지 않았으면 기본 자동 규칙은 auto, 나머지는 nil.
    func ruleState(_ sig: String) -> String? {
        if let v = ctx.db.setting(TidySetting.rulePrefix + sig), ["auto", "ask", "off"].contains(v) { return v }
        return TidyRule.builtinAuto.contains(sig) ? "auto" : nil
    }

    // MARK: 인벤토리 캐시

    /// 캐시 열쇠: 색인 버전 · 출처 설정 · 코드 폴더 · 자리가 생기고 없어지는 폴더들(출처 루트·볼트 PARA 구역)의 수정 시각.
    private func inventoryStamp() -> String {
        let srcs = ctx.sources().map { "\($0.id)|\($0.path ?? "")|\($0.enabled)|\(($0.excludeFolders ?? []).joined(separator: ","))" }.joined(separator: ";")
        var dirs: [String] = localSources().map { $0.root }
        for v in (invCache?.vaults ?? []) { dirs.append(v); for z in TidyNames.paraZones { dirs.append(v + "/" + z) } }
        let mt = dirs.map { String(TidyFS.info(TidyFS.rawPath($0))?.mtime ?? 0) }.joined(separator: ",")
        return "\(ctx.index?.dataVersion() ?? -1)|\(srcs)|\(ctx.db.setting(TidySetting.codeFolder) ?? "")|\(mt)"
    }

    /// 목적지 경로 정리: 있는 가장 가까운 조상을 실제 경로로 풀고 나머지를 붙인다 (/tmp → /private/tmp 같은 차이를 없앤다).
    func normalizeDest(_ p: String) -> String {
        var path = (p as NSString).expandingTildeInPath
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        var head = path, rest: [String] = []
        while head.count > 1 && !TidyFS.exists(head) {
            rest.insert((head as NSString).lastPathComponent, at: 0)
            head = (head as NSString).deletingLastPathComponent
        }
        let base = Indexer.nfc(Indexer.realPath(head))
        return Indexer.nfc(([base == "/" ? "" : base] + rest).joined(separator: "/"))
    }

    func inventory(force: Bool) -> TidyInventory {
        let st = inventoryStamp()
        if !force, let c = invCache, st == invStamp, Date().timeIntervalSince(invAt) < 600 { return c }
        TidyFS.clearCache()
        secretMemo = [:]
        let inv = buildInventory()
        invCache = inv; invStamp = st; invAt = Date()
        return inv
    }

    func invalidate() { invCache = nil; secretMemo = [:]; TidyFS.clearCache() }

    // MARK: 결정 (§4.11)

    func decide(id: String, action: String, to: String?) -> [String: Any] {
        guard var s = sug(id) else { return ["ok": false, "error": "제안을 찾지 못했어요."] }
        let open = s.state == "pending" || s.state == "later"
        switch action {
        case "reject":
            guard open else { return ["ok": false, "error": "이미 처리한 제안이에요."] }
            setState(id, "rejected")
            return ["ok": true, "applied": NSNull(), "undoable": false, "prompt": NSNull()]
        case "later":
            guard open else { return ["ok": false, "error": "이미 처리한 제안이에요."] }
            setState(id, "later", cooldown: nowTS + 7 * 86400)
            return ["ok": true, "applied": NSNull(), "undoable": false, "prompt": NSNull()]
        case "dismiss":
            guard open else { return ["ok": false, "error": "이미 처리한 제안이에요."] }
            setState(id, "dismissed")
            return ["ok": true, "applied": NSNull(), "undoable": false, "prompt": NSNull()]
        case "approve", "to", "edit":
            guard open else { return ["ok": false, "error": "이미 처리한 제안이에요."] }
            if s.item.op == TidyOp.note {
                setState(id, "dismissed")
                return ["ok": true, "applied": NSNull(), "undoable": false, "prompt": NSNull()]
            }
            if ctx.isStopped { return ["ok": false, "error": "사서가 멈춰 있어서 정리하지 않았어요. 다시 시작한 뒤 승인해 주세요."] }
            if action != "approve" {
                guard let t = to?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return ["ok": false, "error": "옮길 폴더를 골라 주세요."] }
                guard [TidyOp.move, TidyOp.merge, TidyOp.archive].contains(s.item.op) else { return ["ok": false, "error": "이 정리는 목적지를 바꿀 수 없어요."] }
                let dest = normalizeDest(t)
                let vm = vaultMap(), sources = localSources(), code = codeFolderResolved()
                if let p = toProblem(dest, from: s.item.from, vm: vm, sources: sources, code: code, codeOnly: codeOnly(s.item.from, vm: vm)) {
                    return ["ok": false, "error": p]
                }
                if s.item.op == TidyOp.archive { s.item.op = TidyOp.move }
                s.item.to = dest
                let zone = invCache?.place(path: s.item.from[0])?.zone ?? zoneOf(s.item.from[0], vm: vm, sources: sources)
                s.item.signature = TidySignature.of(op: s.item.op, fromZone: zone, toParaRel: vm.paraRel(forAbs: dest),
                                                    toCode: code.map { dest == $0 || dest.hasPrefix($0 + "/") } ?? false)
                s.extra["edited"] = true
                save(s)
            }
            let before = approvals(s.item.signature)
            let r = apply(id, auto: false)
            var prompt: Any = NSNull()
            if r.ok && r.done > 0 {
                let n = approvals(s.item.signature)
                if n >= 3 && before < 3 && ruleState(s.item.signature) == nil && TidyOp.autoable.contains(s.item.op) {
                    prompt = ["signature": s.item.signature, "label": TidySignature.label(s.item.signature), "approvals": n]
                }
            }
            let applied: [String: Any] = ["batchId": r.batchId.map { $0 as Any } ?? NSNull(), "done": r.done, "skipped": r.skipped]
            var out: [String: Any] = ["ok": r.ok, "applied": applied, "undoable": r.ok && r.batchId != nil, "prompt": prompt]
            if let e = r.error { out["error"] = e }
            return out
        default:
            return ["ok": false, "error": "모르는 동작이에요: \(action)"]
        }
    }

    /// ids가 있으면 그중 아직 대기이면서 이 묶음의 승인 대상인 것만 (사용자가 본 카드만), 없으면 묶음 전체.
    func decideGroup(group: String, ids: [String]?) -> [String: Any] {
        guard TidyGroup.order.contains(group) else { return ["ok": false, "error": "모르는 묶음이에요."] }
        if ctx.isStopped { return ["ok": false, "error": "사서가 멈춰 있어서 정리하지 않았어요. 다시 시작한 뒤 승인해 주세요."] }
        var done = 0
        var skipped: [[String: Any]] = []
        var batches: [String] = []
        let only = ids.map { Set($0) }
        for s in sugs("state='pending'") where s.item.group == group && (only?.contains(s.id) ?? true) {
            guard s.item.certainty != TidyCertainty.unsure, s.item.op != TidyOp.trash, s.item.op != TidyOp.note else { continue }
            let r = apply(s.id, auto: false)
            if r.ok, let b = r.batchId { done += 1; batches.append(b) }
            skipped += r.skipped
        }
        return ["ok": true, "done": done, "skipped": skipped, "batches": batches]
    }

    func promote(signature: String, accept: Bool) -> [String: Any] {
        guard !signature.isEmpty else { return ["ok": false, "error": "서명이 없어요."] }
        let op = String(signature.split(separator: ":").first ?? "")
        if accept && !TidyOp.autoable.contains(op) { return ["ok": false, "error": "휴지통·알림은 자동으로 할 수 없어요."] }
        ctx.db.setSetting(TidySetting.rulePrefix + signature, accept ? "auto" : "ask")
        ctx.log("policy", accept ? "자동 정리 규칙으로 올렸어요: \(TidySignature.label(signature))" : "계속 물어볼게요: \(TidySignature.label(signature))", origin: "user")
        if accept { _ = autoPass() }
        return ["ok": true]
    }

    func setRule(signature: String, state: String) -> [String: Any] {
        guard ["auto", "ask", "off"].contains(state) else { return ["ok": false, "error": "auto·ask·off 중 하나예요."] }
        guard !signature.isEmpty else { return ["ok": false, "error": "서명이 없어요."] }
        let op = String(signature.split(separator: ":").first ?? "")
        if state == "auto" && !TidyOp.autoable.contains(op) { return ["ok": false, "error": "휴지통·알림은 자동으로 할 수 없어요."] }
        ctx.db.setSetting(TidySetting.rulePrefix + signature, state)
        return ["ok": true]
    }

    func rules() -> [String: Any] {
        let set = (ctx.db.setting(TidySetting.codeFolder) ?? "")
        let builtin: [[String: Any]] = TidyRule.all.map { sig in
            ["signature": sig, "label": TidySignature.label(sig), "state": ruleState(sig) ?? "ask",
             "default": TidyRule.builtinAuto.contains(sig) ? "auto" : "ask", "approvals": approvals(sig),
             "canAuto": TidyOp.autoable.contains(String(sig.split(separator: ":").first ?? ""))]
        }
        var learnedSigs = Set<String>()
        try? ctx.db.sql.query("SELECT key FROM settings WHERE key LIKE ?", [.text(TidySetting.rulePrefix + "%")]) {
            learnedSigs.insert(String($0.text(0).dropFirst(TidySetting.rulePrefix.count)))
        }
        try? ctx.db.sql.query("SELECT DISTINCT rule_key FROM suggestions WHERE kind='tidy' AND state='applied' AND rule_key IS NOT NULL") { learnedSigs.insert($0.text(0)) }
        let learned: [[String: Any]] = learnedSigs.subtracting(TidyRule.all).sorted().map { sig in
            ["signature": sig, "label": TidySignature.label(sig), "state": ruleState(sig) ?? "ask", "approvals": approvals(sig)]
        }
        return ["auto": autoOn, "dailyCap": dailyCap, "codeFolder": set,
                "codeFolderResolved": codeFolderResolved().map { $0 as Any } ?? NSNull(),
                "codeFolderDefault": ctx.env.userHome + "/IdeaProjects", "reviewDay": reviewDay, "builtin": builtin, "learned": learned]
    }

    // MARK: 화면 자료

    func counts() -> [String: Any] {
        let inv = inventory(force: false)
        let jira = jiraStates()
        let now = nowTS
        var pending = 0
        try? ctx.db.sql.query("SELECT COUNT(*) FROM suggestions WHERE kind='tidy' AND state='pending' AND json_extract(payload,'$.op')<>'note'") { pending = Int($0.int(0)) }
        var autoToday = 0
        try? ctx.db.sql.query("""
            SELECT COUNT(*) FROM suggestions WHERE kind='tidy' AND state='applied' AND json_extract(payload,'$.auto')=1 AND decided>=?
            """, [.double(startOfToday)]) { autoToday = Int($0.int(0)) }
        let live = inv.places.filter { !$0.flags.contains(TidyFlag.vault) }
        let wsKeys = Set(live.filter { $0.zone == .workspace }.flatMap { p in TidyNames.isKey(p.name) ? [p.name] : p.ticketKeys })
        let looseKeys = Set(live.filter { $0.zone == .loose || $0.zone == .inbox }.flatMap { $0.ticketKeys })
        let done = live.filter { p in
            guard p.zone == .workspace, p.isDir else { return false }
            let k = TidyNames.isKey(p.name) ? p.name : (p.ticketKeys.first ?? "")
            return jira[k]?.category == "done"
        }.count
        return ["pending": pending, "autoToday": autoToday,
                "loose": live.filter { $0.zone == .loose }.count,
                "inbox": live.filter { $0.zone == .inbox }.count,
                "stale": live.filter { $0.zone == .project && now - $0.lastModified > 30 * 86400 && !$0.flags.contains(TidyFlag.frozen) }.count,
                "doneWorkspaces": done,
                "raw": live.reduce(0) { $0 + $1.raw.count },
                "split": wsKeys.intersection(looseKeys).count,
                "secret": live.filter { $0.flags.contains(TidyFlag.secret) }.count]
    }

    func cards(paths: [String], keys: [String]) -> [[String: Any]] {
        reviveLater()
        let vm = vaultMap(), sources = localSources(), code = codeFolderResolved()
        let ps = paths.map { Indexer.nfc($0) }.filter { !$0.isEmpty }
        let ks = Set(keys)
        let keyOf: [String: [String]] = Dictionary((invCache?.places ?? []).map { ($0.path, $0.ticketKeys) }, uniquingKeysWith: { a, _ in a })
        return sorted(sugs("state='pending'")).filter { s in
            if ps.isEmpty && ks.isEmpty { return true }
            let touch = s.item.from + [s.item.to].compactMap { $0 }
            if touch.contains(where: { t in ps.contains { t == $0 || t.hasPrefix($0 + "/") } }) { return true }
            if !ks.isEmpty {
                if s.item.from.contains(where: { !(Set(keyOf[$0] ?? []).isDisjoint(with: ks)) }) { return true }
                if ks.contains(where: { s.item.title.contains($0) || (s.item.to ?? "").hasSuffix("/" + $0) }) { return true }
            }
            return false
        }.map { card($0, vm: vm, sources: sources, code: code) }
    }

    /// 묶음 순서 → 확실성 → 만든 순.
    func sorted(_ list: [TidySug]) -> [TidySug] {
        let rank: [String: Int] = [TidyCertainty.certain: 0, TidyCertainty.likely: 1, TidyCertainty.unsure: 2]
        return list.sorted { a, b in
            let ga = TidyGroup.order.firstIndex(of: a.item.group) ?? 9, gb = TidyGroup.order.firstIndex(of: b.item.group) ?? 9
            if ga != gb { return ga < gb }
            let ca = rank[a.item.certainty] ?? 3, cb = rank[b.item.certainty] ?? 3
            if ca != cb { return ca < cb }
            return a.created != b.created ? a.created < b.created : a.id < b.id
        }
    }

    func plan() -> [String: Any] {
        reviveLater()
        let inv = inventory(force: false)
        let vm = VaultMap(roots: inv.vaults), sources = localSources(), code = codeFolderResolved()
        let pend = sorted(sugs("state='pending'"))
        let groups: [[String: Any]] = TidyGroup.order.compactMap { g in
            let items = pend.filter { $0.item.group == g }
            if items.isEmpty { return nil }
            return ["key": g, "title": TidyGroup.titles[g] ?? g, "items": items.map { card($0, vm: vm, sources: sources, code: code) }]
        }
        let last = (BrainFormat.parse(ctx.db.setting(TidySetting.lastPlan)) as? [String: Any]) ?? [:]
        let at = last["at"] as? Double
        let autoToday: [[String: Any]] = sugs("state IN ('applied','undone') AND json_extract(payload,'$.auto')=1 AND decided>=?",
                                             [.double(startOfToday)], order: "decided DESC").map { s in
            let dst = displayTarget(s.item)
            let toLabel: Any = dst.map { label(for: $0, vm: vm, sources: sources, codeFolder: code) as Any }
                ?? (s.item.op == TidyOp.exclude ? "색인에서 뺌" as Any : NSNull())
            return ["id": s.id, "title": s.item.title,
                    "fromLabel": s.item.from.map { label(for: $0, vm: vm, sources: sources, codeFolder: code) }.joined(separator: ", "),
                    "toLabel": toLabel,
                    "batchId": s.batchId.map { $0 as Any } ?? NSNull(), "ts": s.decided ?? s.created,
                    "label": BrainFormat.whenLabel(Date(timeIntervalSince1970: s.decided ?? s.created), now: ctx.now()), "undone": s.state == "undone"]
        }
        let questions: [[String: Any]] = ((last["questions"] as? [[String: Any]]) ?? []).map { q in
            let p = q["path"] as? String
            return ["text": q["text"] ?? "", "placeId": p.map { TidyPlace.makeID($0) as Any } ?? NSNull(), "path": p.map { $0 as Any } ?? NSNull()]
        }
        return ["ok": true, "auto": autoOn,
                "summary": (last["summary"] as? String).map { $0 as Any } ?? NSNull(),
                "lastRun": at.map { $0 as Any } ?? NSNull(), "lastRunLabel": at.map { agoLabel($0) as Any } ?? NSNull(),
                "groups": groups, "autoToday": autoToday, "autoUsed": autoUsedToday(), "autoCap": dailyCap,
                "prompts": learnPrompts(), "questions": questions,
                "review": TidyReview.today(setting: ctx.db.setting(TidySetting.reviewDay), now: ctx.now()).map { $0 as Any } ?? NSNull(),
                "counts": counts(),
                "destinations": inv.destinations.map { ["path": $0.path, "label": $0.label, "zone": $0.zone.map { $0.rawValue as Any } ?? (($0.isCode ? "code" : NSNull()) as Any), "isCode": $0.isCode] },
                "inventoryMs": Int(lastInventoryMs)]
    }

    func context() -> [String: Any] {
        let inv = inventory(force: false)
        let jira = jiraStates()
        let places: [[String: Any]] = inv.places.map { p in
            if p.zone == .archive || p.zone == .resource {
                return ["id": p.id, "path": p.path, "name": p.name, "zone": p.zone.rawValue, "label": p.label, "isDir": p.isDir,
                        "files": p.files, "lastModified": p.lastModified, "flags": p.flags.sorted()]
            }
            return p.json
        }
        var pol: [[String: Any]] = []
        var seen = Set<String>()
        for v in inv.vaults {
            for r in self.policy(vault: v) where ["place", "frozen", "landing"].contains(r.kind) && seen.insert(r.key).inserted {
                pol.append(["kind": r.kind, "pattern": r.pattern, "target": r.target.map { $0 as Any } ?? NSNull(), "note": r.note])
            }
        }
        var learnedSigs = Set<String>()
        try? ctx.db.sql.query("SELECT key FROM settings WHERE key LIKE ?", [.text(TidySetting.rulePrefix + "%")]) {
            learnedSigs.insert(String($0.text(0).dropFirst(TidySetting.rulePrefix.count)))
        }
        let learned: [[String: Any]] = (learnedSigs.union(TidyRule.builtinAuto)).sorted().map {
            ["signature": $0, "label": TidySignature.label($0), "state": ruleState($0) ?? "ask"]
        }
        let pending: [[String: Any]] = sugs("state IN ('pending','later')").map {
            ["op": $0.item.op, "from": $0.item.from, "to": $0.item.to.map { $0 as Any } ?? NSNull()]
        }
        var jiraOut: [String: Any] = [:]
        for k in Set(inv.places.flatMap { $0.ticketKeys }) {
            guard let j = jira[k] else { continue }
            jiraOut[k] = ["status": j.status, "category": j.category, "summary": j.summary]
        }
        return ["generated": inv.generated, "hash": inv.hash, "vaults": inv.vaults, "places": places,
                "destinations": inv.destinations.map { $0.json }, "policy": pol, "learned": learned, "avoid": avoidList(),
                "pending": pending, "jira": jiraOut]
    }
}
