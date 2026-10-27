import Foundation

// 정리함 JSON (§6.5 pending)과 새 문서 확인(checkNew).

extension Organizer {

    /// 새 문서 제자리 확인 (§6.3-4). 카드는 만들지 않고 ai_log에 check / inPlace만 남긴다.
    func checkNew(docIds: [String]) {
        for id in docIds {
            guard let d = ctx.doc(id: id), d.isLocal, Organizer.isMarkdown(d.relPath), let v = vault(sourceId: d.sourceId) else { continue }
            let rules = rules(for: v)
            if isExcluded(d.relPath, rules, asSource: false) || isAIArchive(d) { continue }
            var first = d.modified.timeIntervalSince1970
            try? ctx.db.sql.query("SELECT first_seen FROM doc_state WHERE doc_id=?", [.text(id)]) { if !$0.isNull(0) { first = $0.double(0) } }
            if nowTS - first > 86400 { continue }
            var seen = false
            try? ctx.db.sql.query("SELECT 1 FROM ai_log WHERE kind='check' AND ref=? LIMIT 1", [.text(id)]) { _ in seen = true }
            if seen { continue }
            let name = Organizer.fileName(d.relPath)
            ctx.log("check", "새 문서를 확인했어요: \(name)", ref: id)
            if isInPlace(d, v, rules) { ctx.log("inPlace", "제자리예요: \(name)", ref: id) }
        }
    }

    // MARK: 카드

    func moveCard(_ s: OrgSuggestion, extraAlternatives: [String] = []) -> [String: Any] {
        let v = vault(sourceId: (s.payload["sourceId"] as? String) ?? "")
        let from = (s.payload["from"] as? String) ?? (s.path ?? "")
        let to = (s.payload["to"] as? String) ?? ""
        var impact = (s.payload["impact"] as? [String: Any]) ?? ["links": 0, "files": 0, "canvas": 0, "changes": [], "sync": false]
        var conflict: Any = NSNull()
        if let v = v {
            if FileManager.default.fileExists(atPath: v.abs(Organizer.folderKey(to) + Organizer.fileName(from))) { conflict = "같은 이름 파일이 있어요" }
            else if openInObsidian(v.abs(from)) { conflict = "옵시디언에서 열려 있어요" }
        }
        impact["conflict"] = conflict
        var alts = (s.payload["alternatives"] as? [String]) ?? []
        for a in extraAlternatives where a != to && !alts.contains(a) { alts.append(a) }
        return ["id": s.id, "kind": "move", "origin": Organizer.cardOrigin(s.origin), "originLabel": Organizer.originLabel(s.origin),
                "title": (s.payload["title"] as? String) ?? Organizer.fileName(from), "docId": s.docId ?? NSNull(),
                "from": from, "to": to, "alternatives": alts, "confidence": Organizer.grade(s.confidence), "reasons": s.reasons,
                "impact": impact, "items": [], "rules": [], "violations": [], "createdLabel": clockLabel(s.created) ?? "",
                "run": Organizer.runOf(s)]
    }

    /// v0.8: 제안을 올린 Synapse Claude 실행 id(payload.run). 없으면 null.
    static func runOf(_ s: OrgSuggestion) -> Any { (s.payload["run"] as? String).map { $0 as Any } ?? NSNull() }

    private func plainCard(_ s: OrgSuggestion) -> [String: Any] {
        var c: [String: Any] = ["id": s.id, "kind": s.kind, "origin": Organizer.cardOrigin(s.origin), "originLabel": Organizer.originLabel(s.origin),
                                "docId": NSNull(), "from": NSNull(), "to": NSNull(), "alternatives": [], "confidence": "확정",
                                "reasons": s.reasons, "impact": NSNull(), "items": [], "rules": [], "violations": [],
                                "createdLabel": clockLabel(s.created) ?? "", "run": NSNull()]
        if s.kind == "rules" {
            let list = (s.payload["rules"] as? [[String: Any]]) ?? []
            c["title"] = "폴더 규칙표 \(list.count)개를 확인해 주세요"
            c["rules"] = list
        } else {
            let list = (s.payload["violations"] as? [[String: Any]]) ?? []
            c["title"] = "정책 점검: 고칠 것 \(list.count)개"
            c["violations"] = list
        }
        return c
    }

    /// 묶음에 넣을 수 있는 제안: 규칙 출처, 영향 0건, 충돌 없음, 같은 문서에 MCP 제안이 없음(화면과 같은 기준).
    func bundleEligible(_ s: OrgSuggestion) -> Bool {
        guard s.kind == "move", s.state == "pending", !s.origin.hasPrefix("mcp:"), s.ruleKey != nil, let doc = s.docId else { return false }
        if (((s.payload["impact"] as? [String: Any])?["links"] as? Int) ?? 0) != 0 { return false }
        if !suggestions("doc_id=? AND kind='move' AND state='pending' AND origin LIKE 'mcp:%'", [.text(doc)]).isEmpty { return false }
        return moveCard(s)["impact"].flatMap { ($0 as? [String: Any])?["conflict"] } is NSNull
    }

    /// 화면용 카드 전부(순서대로). 같은 문서에 MCP 제안이 있으면 규칙 제안은 숨기고 alternatives로.
    func allCards() -> [[String: Any]] {
        let all = suggestions("state='pending' ORDER BY created, id")
        var ranked: [(rank: Int, created: Double, card: [String: Any])] = []
        var ruleTos: [String: [String]] = [:]
        for s in all where s.kind == "move" && !s.origin.hasPrefix("mcp:") { if let d = s.docId { ruleTos[d, default: []].append((s.payload["to"] as? String) ?? "") } }
        var hiddenDocs = Set<String>()
        for s in all where s.kind == "move" && s.origin.hasPrefix("mcp:") { if let d = s.docId, ruleTos[d] != nil { hiddenDocs.insert(d) } }
        var groups: [String: [OrgSuggestion]] = [:]
        for s in all {
            switch s.kind {
            case "rules": ranked.append((0, s.created, plainCard(s)))
            case "policy": ranked.append((1, s.created, plainCard(s)))
            case "delete":   // v0.6 (v0.8: run — 올린 Claude 실행)
                var c = deleteCard(s)
                c["run"] = Organizer.runOf(s)
                ranked.append((2 + Organizer.gradeRank(Organizer.grade(s.confidence)), s.created, c))
            case "jira": ranked.append((3, s.created, jiraCard(s)))   // v0.8: Jira 제안 대기 (추천 이동과 같은 자리)
            case "move":
                if let d = s.docId, hiddenDocs.contains(d) {
                    if s.origin.hasPrefix("mcp:") { ranked.append((2 + Organizer.gradeRank(Organizer.grade(s.confidence)), s.created, moveCard(s, extraAlternatives: ruleTos[d] ?? []))) }
                    continue
                }
                let card = moveCard(s)
                if let k = s.ruleKey, bundleEligible(s) {
                    groups["b:" + k + "|" + ((s.payload["to"] as? String) ?? ""), default: []].append(s)
                } else {
                    ranked.append((2 + Organizer.gradeRank(Organizer.grade(s.confidence)), s.created, card))
                }
            default: continue
            }
        }
        // v0.8: 반영 중·실패한 Jira 제안도 카드로 둔다. 결과를 모르는 실패는 사용자가 Jira를 확인해야 하므로 규칙·점검 카드 바로 뒤에.
        for s in jiraInFlight() { ranked.append((1, s.created, jiraCard(s))) }
        for (bid, list) in groups {
            if list.count < 2 {
                for s in list { ranked.append((2 + Organizer.gradeRank(Organizer.grade(s.confidence)), s.created, moveCard(s))) }
                continue
            }
            let inBundle = Array(list.prefix(perApply))
            let items = inBundle.map { moveCard($0) }
            let best = inBundle.map { $0.confidence }.max() ?? 0
            let first = inBundle[0]
            let to = (first.payload["to"] as? String) ?? ""
            ranked.append((2 + Organizer.gradeRank(Organizer.grade(best)), first.created, [
                "id": bid, "kind": "bundle", "origin": "rules", "originLabel": "규칙",
                "title": "\(to)로 \(items.count)개 옮기기", "docId": NSNull(), "from": NSNull(), "to": to, "alternatives": [],
                "confidence": Organizer.grade(best), "reasons": first.reasons,
                "impact": ["links": 0, "files": 0, "canvas": 0, "conflict": NSNull(), "sync": (items.first?["impact"] as? [String: Any])?["sync"] ?? false, "changes": []],
                "items": items, "rules": [], "violations": [], "createdLabel": clockLabel(first.created) ?? "", "run": NSNull()]))
            for s in list.dropFirst(perApply) { ranked.append((2 + Organizer.gradeRank(Organizer.grade(s.confidence)), s.created, moveCard(s))) }
        }
        ranked.sort { $0.rank != $1.rank ? $0.rank < $1.rank : $0.created != $1.created ? $0.created < $1.created : ($0.card["id"] as? String ?? "") < ($1.card["id"] as? String ?? "") }
        return ranked.map { $0.card }
    }

    func pending() -> [String: Any] {
        jiraHousekeeping()      // v0.8: 7일 지난 Jira 제안 만료, 10분 넘게 '반영 중'인 것은 실패로
        let cards = allCards()
        let since = startOfToday - 86400
        func logCount(_ kind: String) -> Int {
            var n = 0
            try? ctx.db.sql.query("SELECT count(*) FROM ai_log WHERE kind=? AND ts>=?", [.text(kind), .double(since)]) { n = Int($0.int(0)) }
            return n
        }
        let checked = logCount("check"), inPlace = logCount("inPlace")
        let proposed = suggestions("kind IN ('move','delete') AND state<>'withdrawn' AND created>=? AND \(Organizer.notDirect)", [.double(since)])   // 대체된(철회된) 제안은 세지 않는다
        var byOrigin: [String: Int] = [:]
        for s in proposed { byOrigin[Organizer.cardOrigin(s.origin), default: 0] += 1 }
        let applied = suggestions("kind IN ('move','delete') AND state='applied' AND decided>=? AND \(Organizer.notDirect)", [.double(since)]).count
        let parts = byOrigin.sorted { ($0.key == "rules" ? "" : $0.key) < ($1.key == "rules" ? "" : $1.key) }
            .map { ($0.key == "rules" ? "규칙" : Organizer.originLabel($0.key).replacingOccurrences(of: " 제안", with: "")) + " \($0.value)" }
        let aiDid = "어제 이후 사서가 한 일: 새 문서 \(checked) 확인 · 제자리 \(inPlace) · 제안 \(proposed.count)"
            + (parts.isEmpty ? "" : "(" + parts.joined(separator: " · ") + ")") + " · 적용 \(applied)"
        let last = BrainFormat.date(ctx.db.setting(BrainSetting.organizerLastBatch))?.timeIntervalSince1970
        return ["header": ["aiDid": aiDid, "checked": checked, "inPlace": inPlace, "proposed": proposed.count, "applied": applied],
                "cards": Array(cards.prefix(5)), "more": max(0, cards.count - 5),
                "limits": ["perApply": perApply, "perDay": perDay, "usedToday": usedToday, "firstWeeks": firstWeeks],
                "policy": ["approved": policyApproved, "stale": policyStale],
                "stopped": ctx.isStopped, "lastBatchLabel": clockLabel(last) ?? NSNull(),
                "trash": ["count": trashCount(), "retentionDays": Int(Organizer.trashDays)]]
    }

    /// 목적지로 고를 수 있는 기존 폴더(깊이 3 이하, frozen·exclude·landing 제외).
    func folders() -> [[String: Any]] {
        var out: [[String: Any]] = []
        for v in vaults() {
            let rules = rules(for: v)
            var direct: [String: Int] = [:]
            for d in ctx.docs where d.sourceId == v.sourceId && d.isLocal { direct[Organizer.folderKey(d.folder), default: 0] += 1 }
            var stack: [(String, Int)] = [("", 0)]
            var found: [String] = []
            while let (rel, depth) = stack.popLast() {
                guard depth < 3 else { continue }
                let names = ((try? FileManager.default.contentsOfDirectory(atPath: v.abs(rel))) ?? []).sorted()
                for n in names where !n.hasPrefix(".") && !Indexer.skipNames.contains(n) {
                    let r = rel.isEmpty ? Indexer.nfc(n) : rel + "/" + Indexer.nfc(n)
                    guard isDir(v.abs(r)) else { continue }
                    stack.append((r, depth + 1))
                    let key = r + "/"
                    if landing(key + "x.md") != nil || destinationProblem(v, key, rules) != nil { continue }
                    found.append(key)
                }
            }
            for f in found.sorted() { out.append(["path": f, "docs": direct[f] ?? 0]) }
        }
        return out
    }
}
