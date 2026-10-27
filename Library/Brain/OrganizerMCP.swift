import Foundation

// MCP가 부르는 정리 메서드 (§7): get_vault_policy · list_pending · suggest_location · propose_changes.
// 모두 읽기이거나 제안(suggestions)만 쓴다. 승인은 Synapse 화면에서만 한다.

extension Organizer {

    /// "claude-code" → "mcp:claude", "codex-cli" → "mcp:codex", 그 밖은 "mcp:<이름>".
    static func mcpOrigin(_ raw: String) -> String {
        let n = raw.hasPrefix("mcp:") ? String(raw.dropFirst(4)) : raw
        let l = n.lowercased()
        if l == "claude-digest" { return "mcp:claude-digest" }   // v0.8 티켓 화면 Claude 브리핑 — 시키기 실행(claude)과 한도를 따로 센다
        if l.contains("claude") { return "mcp:claude" }
        if l.contains("codex") { return "mcp:codex" }
        return "mcp:" + (n.isEmpty ? "mcp" : n)
    }

    func vaultPolicy() -> [String: Any] {
        let rules = ensurePolicy(force: false)
        func pats(_ k: String) -> [String] { rules.filter { $0.kind == k }.map { $0.pattern + ($0.target == "출발지" ? " (출발지)" : "") } }
        return ["approved": policyApproved, "rules": rules.filter { $0.kind == "place" || $0.kind == "duty" }.map { ruleJSON($0) },
                "frozen": pats("frozen"), "exclude": pats("exclude"), "landing": pats("landing"),
                "folders": folders(), "violations": violations()]
    }

    func listPending() -> [String: Any] {
        var unsorted: [[String: Any]] = []
        outer: for v in vaults() {
            let rules = rules(for: v)
            for d in ctx.docs.sorted(by: { $0.modified > $1.modified }) where isSource(d, v, rules) && !isInPlace(d, v, rules) {
                let cands = place(d, v, rules).list.filter { $0.confidence >= 0.6 }
                unsorted.append(["docId": d.id, "title": d.title, "path": d.relPath, "origin": "local",
                                 "modifiedLabel": BrainFormat.whenLabel(d.modified, now: now),
                                 "candidates": cands.map { ["to": $0.to, "confidence": Organizer.grade($0.confidence)] }])
                if unsorted.count >= 50 { break outer }
            }
        }
        let props = suggestions("kind IN ('move','delete') AND state<>'withdrawn' AND created>=? AND \(Organizer.notDirect) ORDER BY created DESC", [.double(nowTS - 30 * 86400)]).map { s -> [String: Any] in
            ["id": s.id, "kind": s.kind, "state": s.state, "from": (s.payload["from"] as? String) ?? (s.path ?? ""), "to": (s.payload["to"] as? String) ?? "",
             "origin": Organizer.cardOrigin(s.origin), "createdLabel": clockLabel(s.created) ?? ""]
        }
        return ["unsorted": unsorted, "proposals": props, "trash": ["count": trashCount(), "retentionDays": Int(Organizer.trashDays)],
                "directApply": ctx.db.setting(BrainSetting.mcpDirectApply) == "on"]
    }

    func suggestLocation(_ args: [String: Any]) -> [String: Any] {
        let title = ((args["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return ["ok": false, "error": "title이 필요해요"] }
        guard let v = vaults().first else { return ["suggestions": [], "rule": NSNull(), "policyApproved": policyApproved] }
        let rules = rules(for: v), proj = projects(v)
        let head = String(((args["content_head"] as? String) ?? "").prefix(2000))
        let text = Korean.normalize(title + "\n" + head)
        let type = ((args["type"] as? String) ?? "").uppercased()
        var name = title.hasSuffix(".md") ? title : title + ".md"
        if !type.isEmpty && !name.uppercased().hasPrefix(type) { name = type + "-000_" + name }
        var project = (args["project"] as? String).map { proj.nameOf["1-Projects/" + $0] ?? proj.nameOf["2-Areas/" + $0] ?? $0 }
        if project == nil {
            let hits = proj.folders.filter { (n, fs) in
                Set([n] + fs.map { Organizer.fileName($0) }).contains { $0.count >= 2 && Relate.occurs(Korean.normalize($0), in: text) }
            }.map { $0.key }
            if hits.count == 1 { project = hits[0] }
        }
        var out: [[String: Any]] = []
        var ruleOut: Any = NSNull()
        if let rule = placeRule(for: name, rules), let tpl = rule.target {
            ruleOut = ruleJSON(rule)
            if let p = project, let to = resolveTarget(v, tpl, project: p, proj).0 {
                out.append(["folder": to, "confidence": "확정", "reason": "볼트 CLAUDE.md 규칙 · 프로젝트 \(p)"])
            } else {
                for p in proj.folders.keys.sorted() {
                    if let to = resolveTarget(v, tpl, project: p, proj).0, destinationProblem(v, to, rules) == nil {
                        out.append(["folder": to, "confidence": "후보", "reason": "볼트 CLAUDE.md 규칙 · 프로젝트를 알려 주면 확정돼요"])
                    }
                    if out.count == 3 { break }
                }
            }
        } else {
            // 통계: 키워드 겹침(코사인) + 이름 일치. 링크가 없으니 두 신호만으로 다시 잰다.
            let s = stats(v, rules)
            var tf: [String: Double] = [:]
            for t in Korean.keywordTokens(head) { tf[t, default: 0] += 1 }
            for t in Korean.keywordTokens(title) { tf[t, default: 0] += 3 }
            let norm = sqrt(tf.values.reduce(0) { $0 + $1 * $1 })
            var scored: [(String, Double, String)] = []
            for (f, cnt) in s.counts where cnt >= 3 {
                let sum = s.sums[f] ?? [:]
                let cn = sqrt(sum.values.reduce(0) { $0 + $1 * $1 })
                var dot = 0.0
                for (t, w) in tf { dot += w * (sum[t] ?? 0) }
                let a = norm > 0 && cn > 0 ? dot / (norm * cn) : 0
                let nm = [proj.projectOf(f + "x.md"), Organizer.fileName(String(f.dropLast()))].compactMap { $0 }
                    .first { $0.count >= 2 && Relate.occurs(Korean.normalize($0), in: text) }
                let c: Double = nm != nil || (project != nil && proj.projectOf(f + "x.md") == project) ? 1 : 0
                let score = min(0.95, (0.4 * a + 0.2 * c) / 0.6)
                if score >= 0.6 { scored.append((f, score, nm.map { "'\($0)' 이름이 나와요" } ?? "같은 폴더 문서와 주제가 비슷해요")) }
            }
            scored.sort { $0.1 > $1.1 || ($0.1 == $1.1 && $0.0 < $1.0) }
            out = scored.prefix(3).map { ["folder": $0.0, "confidence": Organizer.grade($0.1), "reason": $0.2] }
        }
        return ["suggestions": out, "rule": ruleOut, "policyApproved": policyApproved]
    }

    func propose(items: [[String: Any]], origin: String) -> [String: Any] {
        propose(items: items, origin: origin, runId: nil)
    }

    /// v0.8 §6.1: runId(Synapse에서 띄운 Claude 실행 id, 이미 검사한 값)가 있으면 받은 이동·삭제 제안의 payload.run에 남긴다 — 그 실행의 제안 카드(proposals(run:))로 모인다.
    func propose(items: [[String: Any]], origin: String, runId: String?) -> [String: Any] {
        let o = Organizer.mcpOrigin(origin)
        let note = "Synapse 정리함에서 사용자가 승인해야 적용돼요."
        if items.count > 20 {
            return ["accepted": [], "rejected": items.indices.map { ["index": $0, "reason": "한 번에 20건까지만 받아요"] }, "note": note]
        }
        var accepted: [[String: Any]] = [], rejected: [[String: Any]] = []
        for (i, item) in items.enumerated() {
            let kind = (item["kind"] as? String) ?? ""
            let r: (String?, String?)
            let startedAt = nowTS
            switch kind {
            case "move": r = proposeMove(item, origin: o)
            case "rules": r = proposeRules(item, origin: o)
            case "delete": r = proposeDelete(item, origin: o)      // v0.6 (OrganizerDirect)
            case "withdraw":
                if let id = item["id"] as? String, let s = suggestion(id), s.origin == o, s.state == "pending" || s.state == "later" {
                    setState(id, "withdrawn"); r = (id, nil)
                } else { r = (nil, "직접 올린 대기 중 제안만 철회할 수 있어요") }
            default: r = (nil, "kind는 move · delete · rules · withdraw 중 하나여야 해요")
            }
            if let id = r.0 {
                if let run = runId, kind == "move" || kind == "delete", var x = suggestion(id), x.state == "pending" {
                    x.payload["run"] = run
                    save(x)
                }
                // v0.6 P0: 같은 문서·같은 출처의 이전 대기 제안을 이번 제안이 대체했는지 알려 준다
                var replaced = false
                if kind == "move" || kind == "delete", let did = suggestion(id)?.docId {
                    replaced = !suggestions("doc_id=? AND kind=? AND origin=? AND state='withdrawn' AND decided>=? AND id<>?",
                                            [.text(did), .text(kind), .text(o), .double(startedAt), .text(id)]).isEmpty
                }
                accepted.append(replaced ? ["index": i, "id": id, "replaced": true] : ["index": i, "id": id])
            } else { rejected.append(["index": i, "reason": r.1 ?? "받을 수 없어요"]) }
        }
        if !accepted.isEmpty { ctx.emit(.pending) }
        return ["accepted": accepted, "rejected": rejected, "note": note]
    }

    private func proposeMove(_ item: [String: Any], origin o: String) -> (String?, String?) {
        var doc: BrainDoc? = nil
        if let id = item["doc_id"] as? String { doc = ctx.doc(id: id) }
        else if let p = item["path"] as? String {
            if p.hasPrefix("/") { doc = ctx.doc(path: p) ?? ctx.doc(path: Indexer.realPath(p)) }
            else {
                let rel = Indexer.nfc(p.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                let vs = Set(vaults().map { $0.sourceId })
                doc = ctx.docs.first { vs.contains($0.sourceId) && $0.relPath == rel }
            }
        }
        guard let d = doc else { return (nil, "문서를 찾지 못했어요") }
        guard d.isLocal, let v = vault(sourceId: d.sourceId) else { return (nil, "옵시디언 볼트 문서만 옮길 수 있어요") }
        guard Organizer.isMarkdown(d.relPath) else { return (nil, "마크다운 문서만 옮길 수 있어요") }
        let rules = rules(for: v)
        if isFrozen(d.relPath, rules) { return (nil, "동결 폴더 문서는 옮기지 않아요") }
        if isExcluded(d.relPath, rules, asSource: true) { return (nil, "제외 구역 문서는 옮기지 않아요") }
        if let p = sourceProblem(v, d.relPath) { return (nil, p) }
        guard let rawTo = item["to"] as? String, !rawTo.isEmpty else { return (nil, "to(목적지 폴더)가 필요해요") }
        let to = Organizer.folderKey(Indexer.nfc(rawTo))
        if to.isEmpty { return (nil, "볼트 루트로는 옮기지 않아요") }
        if let p = destinationProblem(v, to, rules) { return (nil, "목적지가 " + p) }
        if to.lowercased() == Organizer.folderKey(d.folder).lowercased() { return (nil, "이미 그 폴더에 있어요") }
        let toRel = to + Organizer.fileName(d.relPath)
        let files = listFiles(v)
        if files.exact(toRel) != nil { return (nil, "목적지에 같은 이름 파일이 있어요") }
        guard let st = fileStamp(v.abs(d.relPath)) else { return (nil, "파일이 없어요") }
        let plan = planMove(v, fromRel: d.relPath, toRel: toRel, files: files)
        if let p = plan.problem { return (nil, p) }
        let ruled = place(d, v, rules).list
        let match = ruled.first { $0.to.lowercased() == to.lowercased() }
        for old in suggestions("doc_id=? AND kind='move' AND origin=? AND state IN ('pending','later')", [.text(d.id), .text(o)]) { setState(old.id, "withdrawn") }
        var reasons: [String] = []
        if let why = item["reason"] as? String, !why.trimmingCharacters(in: .whitespaces).isEmpty { reasons.append(String(why.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))) }
        else { reasons.append(Organizer.originLabel(o) + "이에요") }
        if let m = match { reasons += m.reasons.prefix(2) }
        let s = OrgSuggestion(id: newID("s:", d.id + o), kind: "move", docId: d.id, path: d.relPath,
                              payload: movePayload(v, d, to: to, stamp: st, plan: plan, alternatives: []),
                              confidence: match?.confidence ?? 0.6, reasons: reasons, origin: o, ruleKey: o,
                              state: "pending", created: nowTS, decided: nil, batchId: nil, cooldownUntil: nil, error: nil)
        save(s)
        ctx.log("propose", "\(Organizer.originLabel(o)): \(Organizer.fileName(d.relPath)) → \(to)", origin: Organizer.logOrigin(o), ref: s.id)
        return (s.id, nil)
    }

    private func proposeRules(_ item: [String: Any], origin o: String) -> (String?, String?) {
        guard let list = item["rules"] as? [[String: Any]], !list.isEmpty else { return (nil, "rules 목록이 비어 있어요") }
        var rules: [PolicyRule] = []
        for (j, r) in list.enumerated() {
            guard let k = r["kind"] as? String, ["place", "frozen", "exclude"].contains(k) else { return (nil, "\(j)번 규칙: kind는 place · frozen · exclude만 받아요") }
            guard let p = r["pattern"] as? String, !p.trimmingCharacters(in: .whitespaces).isEmpty else { return (nil, "\(j)번 규칙: pattern이 비어 있어요") }
            let target = (r["target"] as? String).map { Organizer.folderKey(PolicyParser.normalizePlaceholders($0)) }
            if k == "place" {
                if (try? NSRegularExpression(pattern: p)) == nil { return (nil, "\(j)번 규칙: pattern이 정규식이 아니에요") }
                if target == nil || target!.isEmpty { return (nil, "\(j)번 규칙: place에는 target이 필요해요") }
            }
            rules.append(PolicyRule(kind: k, pattern: p, target: k == "place" ? target : nil, source: o, note: (r["note"] as? String) ?? ""))
        }
        makeRulesCard(rules, origin: o)
        let id = suggestions("kind='rules' AND state='pending' AND origin=? ORDER BY created DESC", [.text(o)]).first?.id
        ctx.log("propose", "\(Organizer.originLabel(o)): 규칙표 수정안 \(rules.count)개", origin: Organizer.logOrigin(o), ref: id)
        return (id, id == nil ? "저장하지 못했어요" : nil)
    }
}
