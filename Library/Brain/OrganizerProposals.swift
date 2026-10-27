import Foundation

// 제안 수명주기 (§6.4·§6.5 decide). 배치는 하루 두 번 + 수동. 비상 정지면 만들지 않는다.

extension Organizer {

    static let cooldownDays = 30.0
    static let expireDays = 7.0

    // MARK: 상한

    var firstRunTS: Double {
        if let t = BrainFormat.date(ctx.db.setting(BrainSetting.organizerFirstRun)) { return t.timeIntervalSince1970 }
        if ctx.mode != .mcp { ctx.db.setSetting(BrainSetting.organizerFirstRun, BrainFormat.iso(now)) }
        return nowTS
    }
    var firstWeeks: Bool { nowTS < firstRunTS + 14 * 86400 }
    var perApply: Int { firstWeeks ? 5 : 10 }
    var perDay: Int { firstWeeks ? 10 : 20 }
    var usedToday: Int {
        var n = 0
        try? ctx.db.sql.query("SELECT count(*) FROM suggestions WHERE kind='move' AND state='applied' AND decided>=? AND \(Organizer.notDirect)", [.double(startOfToday)]) { n = Int($0.int(0)) }
        return n
    }

    // MARK: 만드는 조건

    /// 제안을 막는 이유 (§6.4 시간·세션·옵시디언·30일 이동). nil = 통과.
    func blockReason(_ d: BrainDoc, _ v: OrgVault) -> String? {
        let abs = v.abs(d.relPath)
        guard let st = fileStamp(abs) else { return "파일이 없어요" }
        let age = nowTS - st.mtime
        if age < 2 * 3600 { return "2시간 안에 고쳤어요" }
        if ctx.db.setting(BrainSetting.sessionsEnabled) == "1" {
            var last = 0.0
            try? ctx.db.sql.query("""
                SELECT max(s.last_ts) FROM ai_writes w JOIN ai_sessions s ON s.id = w.session_id WHERE w.path=?
                """, [.text(Indexer.nfc(abs))]) { if !$0.isNull(0) { last = $0.double(0) } }
            if last > 0 && nowTS - last < 30 * 60 { return "이 파일을 쓴 AI 세션이 아직 조용하지 않아요" }
        } else if age < 24 * 3600 { return "24시간 안에 고쳤어요" }
        if openInObsidian(abs) { return "옵시디언에서 열려 있어요" }
        if movedRecently(abs) { return "30일 안에 옮긴 문서예요" }
        return nil
    }

    func openInObsidian(_ abs: String) -> Bool {
        let p = Indexer.nfc(abs)
        return ctx.obsidianOpenPaths().contains { Indexer.nfc($0) == p || Indexer.nfc(Indexer.realPath($0)) == p }
    }

    func movedRecently(_ abs: String) -> Bool {
        var hit = false
        try? ctx.db.sql.query("SELECT 1 FROM ops_log WHERE op='move' AND (to_path=? OR from_path=?) AND ts>=? LIMIT 1",
                              [.text(abs), .text(abs), .double(nowTS - Organizer.cooldownDays * 86400)]) { _ in hit = true }
        return hit
    }

    func inCooldown(docId: String, to: String) -> Bool {
        suggestions("doc_id=? AND state='rejected' AND cooldown_until>?", [.text(docId), .double(nowTS)])
            .contains { ($0.payload["to"] as? String) == to }
    }

    /// 같은 rule_key가 연속 3번 거절되면 쉰다. 묶음 거절은 1번으로 센다.
    func ruleResting(_ key: String) -> Bool {
        var events: [String] = [], seen = Set<String>()
        for s in suggestions("rule_key=? AND state IN ('applied','rejected') ORDER BY decided DESC", [.text(key)]) {
            let ev = (s.error?.hasPrefix("bundle:") ?? false) ? s.error! : s.id
            if seen.insert(ev).inserted { events.append(s.state) }
            if events.count == 3 { break }
        }
        return events.count == 3 && events.allSatisfy { $0 == "rejected" }
    }

    // MARK: 배치

    func runBatch(force: Bool) -> Int {
        if ctx.isStopped || ctx.mode == .mcp { return 0 }
        _ = firstRunTS
        ctx.db.setSetting(BrainSetting.organizerLastBatch, BrainFormat.iso(now))
        let rules = ensurePolicy(force: false)
        // 만료·나중에 (later는 다음 배치에서 다시 보인다)
        for s in suggestions("state='pending' AND kind IN ('move','policy','delete') AND created<?", [.double(nowTS - Organizer.expireDays * 86400)]) {
            setState(s.id, "expired")
        }
        jiraHousekeeping()      // v0.8: Jira 제안 만료(7일)·멈춘 반영 복구(조건부 UPDATE)
        for s in suggestions("state='later'") { var x = s; x.state = "pending"; save(x) }
        purgeOldBackups()
        weeklyPolicyCheck()
        guard policyApproved else {
            if suggestions("kind='rules' AND state='pending'").isEmpty && !rules.isEmpty { makeRulesCard(rules, origin: "rules") }
            return 0
        }
        // 출발지 목록을 만들고 200ms 조각으로 처리한다(앱 모드는 남은 것을 큐 뒤로 미뤄 화면 요청을 먼저 받는다)
        batchCache = [:]; batchCreated = 0
        batchWork = []
        for v in vaults() {
            let vr = rules.filter { $0.applies(to: v) }
            batchCache[v.sourceId] = (vr, listFiles(v), nil)
            for d in ctx.docs where isSource(d, v, vr) { batchWork.append((v.sourceId, d.id)) }
        }
        return drainBatch()
    }

    /// 배치 한 조각. 이번 조각에서 만든 수를 돌려준다.
    @discardableResult
    func drainBatch() -> Int {
        let start = Date()
        var created = 0
        while !batchWork.isEmpty {
            if ctx.mode == .app && Date().timeIntervalSince(start) > 0.2 {
                ctx.queue.async { [weak self] in self?.drainBatch() }
                break
            }
            let (sid, id) = batchWork.removeFirst()
            guard let v = vault(sourceId: sid), let c = batchCache[sid], let d = ctx.doc(id: id) else { continue }
            if proposeOne(d, v, c.rules) { created += 1 }
        }
        batchCreated += created
        if created > 0 { ctx.emit(.pending) }
        if batchWork.isEmpty { batchCache = [:] }
        return created
    }

    /// 출발지 문서 하나에 대해 조건을 보고 제안을 만든다.
    private func proposeOne(_ d: BrainDoc, _ v: OrgVault, _ vr: [PolicyRule]) -> Bool {
        if ctx.isStopped { return false }
        if !suggestions("doc_id=? AND kind='move' AND state IN ('pending','later') AND origin='rules'", [.text(d.id)]).isEmpty { return false }
        if blockReason(d, v) != nil { return false }
        let r = place(d, v, vr)
        guard let best = r.list.first, best.confidence >= 0.6 else { return false }
        if inCooldown(docId: d.id, to: best.to) || ruleResting(best.ruleKey) { return false }
        guard var c = batchCache[v.sourceId] else { return false }
        let toRel = best.to + Organizer.fileName(d.relPath)
        if c.files.exact(toRel) != nil { return false }          // 같은 이름 충돌은 건너뛴다
        guard let st = fileStamp(v.abs(d.relPath)) else { return false }
        if c.index == nil { c.index = buildLinkIndex(v, files: c.files); batchCache[v.sourceId] = c }
        let plan = planMove(v, fromRel: d.relPath, toRel: toRel, files: c.files, index: c.index)
        if plan.problem != nil { return false }
        let alts = best.confidence < 0.9 ? r.list.dropFirst().filter { $0.confidence >= 0.6 }.map { $0.to } : []
        let s = OrgSuggestion(id: newID("s:", d.id), kind: "move", docId: d.id, path: d.relPath,
                              payload: movePayload(v, d, to: best.to, stamp: st, plan: plan, alternatives: Array(alts)),
                              confidence: best.confidence, reasons: best.reasons, origin: "rules", ruleKey: best.ruleKey,
                              state: "pending", created: nowTS, decided: nil, batchId: nil, cooldownUntil: nil, error: nil)
        save(s)
        ctx.log("propose", "자리를 제안했어요: \(Organizer.fileName(d.relPath)) → \(best.to)", ref: s.id)
        return true
    }

    func movePayload(_ v: OrgVault, _ d: BrainDoc, to: String, stamp: (mtime: Double, size: Int), plan: MovePlan, alternatives: [String]) -> [String: Any] {
        ["sourceId": v.sourceId, "from": d.relPath, "to": to, "fromMtime": stamp.mtime, "fromSize": stamp.size,
         "title": Organizer.fileName(d.relPath), "alternatives": alternatives, "laterCount": 0, "impact": impactJSON(v, plan)]
    }

    func impactJSON(_ v: OrgVault, _ plan: MovePlan) -> [String: Any] {
        var changes: [[String: Any]] = []
        for e in plan.edits { for c in e.changes { changes.append(["path": e.rel, "before": c.before, "after": c.after]) } }
        return ["links": plan.links, "files": plan.files, "canvas": plan.canvasFiles, "changes": Array(changes.prefix(10)), "sync": syncOn(v)]
    }

    /// 옵시디언 Sync가 켜져 있는가(.obsidian/core-plugins.json).
    func syncOn(_ v: OrgVault) -> Bool {
        guard let d = FileManager.default.contents(atPath: v.abs(".obsidian/core-plugins.json")),
              let o = try? JSONSerialization.jsonObject(with: d) else { return false }
        if let m = o as? [String: Any] { return (m["sync"] as? Bool) ?? false }
        if let a = o as? [String] { return a.contains("sync") }
        return false
    }

    // MARK: 결정

    func decide(id: String, action: String, to: String?) -> [String: Any] {
        if id.hasPrefix("b:") {
            switch action {
            case "approve": return decideBundle(id: id)
            case "reject", "later":
                let items = bundleItems(id)
                if items.isEmpty { return ["ok": false, "error": "묶음을 찾지 못했어요"] }
                for (i, s) in items.enumerated() { decideOne(s, action: action, bundle: id, first: i == 0) }
                return ["ok": true, "applied": NSNull(), "undoable": false]
            default: return ["ok": false, "error": "묶음에는 그 동작을 할 수 없어요"]
            }
        }
        // v0.8: Jira 제안은 거절만 여기서 받는다(반영은 jiraApply). pending·failed를 거절할 수 있다.
        if let s = suggestion(id), s.kind == "jira" { return decideJira(s, action: action) }
        guard let s = suggestion(id), s.state == "pending" || s.state == "later" else { return ["ok": false, "error": "이미 처리된 제안이에요"] }
        switch (s.kind, action) {
        case ("rules", "approve"):
            if s.origin.hasPrefix("mcp:") { return approveProposedRules(s) }
            var r = approvePolicy(); r["applied"] = NSNull(); r["undoable"] = false; return r
        case ("policy", "dismiss"), ("policy", "reject"):
            setState(s.id, "rejected"); ctx.emit(.pending)
            return ["ok": true, "applied": NSNull(), "undoable": false]
        case ("move", "approve"):
            return applyMoves([s])
        case ("delete", "approve"):
            return approveDelete(s)       // v0.6: 승인 = Synapse 휴지통으로 (OrganizerDirect)
        case ("move", "edit"):
            guard var x = Optional(s), let t = to, let v = vault(sourceId: (s.payload["sourceId"] as? String) ?? "") else {
                return ["ok": false, "error": "옮길 폴더를 골라 주세요"]
            }
            let folder = Organizer.folderKey(t)
            if let p = destinationProblem(v, folder, rules(for: v)) { return ["ok": false, "error": "그 폴더로는 옮길 수 없어요: " + p] }
            x.payload["to"] = folder
            save(x)
            return applyMoves([x])
        case (_, "reject"), (_, "later"):
            decideOne(s, action: action, bundle: nil, first: true)
            return ["ok": true, "applied": NSNull(), "undoable": false]
        default:
            return ["ok": false, "error": "할 수 없는 동작이에요"]
        }
    }

    private func decideOne(_ s: OrgSuggestion, action: String, bundle: String?, first: Bool) {
        let others = hiddenPartners(s)
        if action == "reject" {
            var x = s
            x.state = "rejected"; x.decided = nowTS; x.cooldownUntil = nowTS + Organizer.cooldownDays * 86400
            if let b = bundle { x.error = "bundle:" + b }
            save(x)
            for o in others { setState(o.id, "withdrawn") }
            if first {
                ctx.log("reject", "거절했어요: \(s.payload["title"] as? String ?? s.kind)", origin: Organizer.logOrigin(s.origin), ref: s.id)
            }
            if let k = s.ruleKey, s.kind == "move", ruleResting(k) {
                ctx.log("reject", "이 규칙은 쉬게 할게요: \(k)", ref: k)
            }
        } else {
            var x = s
            let n = ((s.payload["laterCount"] as? Int) ?? 0) + 1
            x.payload["laterCount"] = n
            x.state = n >= 3 ? "expired" : "later"; x.decided = nowTS
            save(x)
        }
        ctx.emit(.pending)
    }

    /// 같은 문서에 MCP 제안이 있어 화면에서 숨긴 규칙 제안.
    func hiddenPartners(_ s: OrgSuggestion) -> [OrgSuggestion] {
        guard s.kind == "move", let doc = s.docId, s.origin.hasPrefix("mcp:") else { return [] }
        return suggestions("doc_id=? AND kind='move' AND state IN ('pending','later') AND origin='rules'", [.text(doc)])
    }

    /// 묶음 안의 낱개 제안 (pending, 영향 0건, 같은 rule_key·목적지).
    func bundleItems(_ id: String) -> [OrgSuggestion] {
        let body = String(id.dropFirst(2))
        guard let bar = body.lastIndex(of: "|") else { return [] }
        let key = String(body[..<bar]), to = String(body[body.index(after: bar)...])
        return suggestions("kind='move' AND state='pending' AND origin='rules' AND rule_key=? ORDER BY created, id", [.text(key)])
            .filter { ($0.payload["to"] as? String) == to && bundleEligible($0) }
            .prefix(perApply).map { $0 }
    }

    func decideBundle(id: String) -> [String: Any] {
        let items = bundleItems(id)
        if items.isEmpty { return ["ok": false, "error": "묶음을 찾지 못했어요"] }
        return applyMoves(items)
    }
}
