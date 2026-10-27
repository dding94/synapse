import Foundation

// 규칙표 저장·승인·정책 위반 점검 (§6.1). 사서는 위반을 알리기만 하고 파일을 고치지 않는다.

extension Organizer {

    /// 규칙표 입력 파일: <vault>/CLAUDE.md, 1-Projects/*/CLAUDE.md, 2-Areas/*/CLAUDE.md
    func policyFiles(_ v: OrgVault) -> [(rel: String, mtime: Double)] {
        var rels = ["CLAUDE.md"]
        let fm = FileManager.default
        for top in ["1-Projects", "2-Areas"] {
            for d in ((try? fm.contentsOfDirectory(atPath: v.abs(top))) ?? []).sorted() where !d.hasPrefix(".") {
                rels.append(top + "/" + Indexer.nfc(d) + "/CLAUDE.md")
            }
        }
        return rels.compactMap { r in fileStamp(v.abs(r)).map { (r, $0.mtime) } }
    }

    func policyStamp() -> String {
        vaults().map { v in v.root + "=" + policyFiles(v).map { "\($0.rel)@\($0.mtime)" }.joined(separator: ",") + "|" + v.excludeFolders.joined(separator: ",") }
            .joined(separator: ";")
    }

    func compilePolicy(_ v: OrgVault) -> PolicyCompile {
        var c = PolicyCompile()
        var rules = PolicyParser.defaults(v)
        for f in policyFiles(v) {
            guard let text = try? String(contentsOfFile: v.abs(f.rel), encoding: .utf8) else { continue }
            let base = Organizer.parent(f.rel)
            rules += PolicyParser.compile(text, base: base, source: v.abs(f.rel), notes: &c.folderNotes)
            c.sources.append((f.rel, f.mtime))
        }
        c.rules = PolicyParser.sorted(rules)
        compiledCache[v.root] = c
        return c
    }

    func compiled(_ v: OrgVault) -> PolicyCompile { compiledCache[v.root] ?? compilePolicy(v) }

    func storedRules() -> [PolicyRule] {
        var out: [PolicyRule] = []
        try? ctx.db.sql.query("SELECT kind, pattern, target, source_file, note FROM policy_rules ORDER BY id") { r in
            out.append(PolicyRule(kind: r.text(0), pattern: r.text(1), target: r.isNull(2) ? nil : r.text(2), source: r.text(3), note: r.text(4)))
        }
        return out
    }

    func replaceRules(_ rules: [PolicyRule]) {
        try? ctx.db.sql.transaction {
            try ctx.db.sql.run("DELETE FROM policy_rules")
            for r in PolicyParser.sorted(rules) {
                try ctx.db.sql.run("INSERT INTO policy_rules(kind, pattern, target, source_file, note) VALUES(?,?,?,?,?)",
                                   [.text(r.kind), .text(r.pattern), r.target.map { .text($0) } ?? .null, .text(r.source), .text(r.note)])
            }
        }
    }

    /// 지금 쓰는 규칙표. CLAUDE.md가 바뀌었으면 다시 만들고, 해시가 달라졌으면 rules 카드를 낸다.
    /// MCP 모드는 저장하지 않는다(앱이 만든 값을 읽고, 없으면 메모리에서만 만든다).
    @discardableResult
    func ensurePolicy(force: Bool) -> [PolicyRule] {
        let stored = storedRules()
        let stamp = policyStamp()
        if !force && !stored.isEmpty && stamp == ctx.db.setting(BrainSetting.policySourceStamp) { return stored }
        let rules = PolicyParser.sorted(vaults().flatMap { compilePolicy($0).rules })
        if ctx.mode == .mcp { return stored.isEmpty ? rules : stored }
        ctx.db.setSetting(BrainSetting.policySourceStamp, stamp)
        let newHash = PolicyParser.hash(rules)
        if stored.isEmpty || PolicyParser.hash(stored) != newHash {
            replaceRules(rules)
            ctx.log("policy", "폴더 규칙표를 만들었어요 · \(rules.count)개")
            if newHash != ctx.db.setting(BrainSetting.policyApprovedHash) { makeRulesCard(rules, origin: "rules") }
            ctx.emit(.policy)
        }
        return rules
    }

    func rules(for v: OrgVault) -> [PolicyRule] { ensurePolicy(force: false).filter { $0.applies(to: v) } }

    var policyApproved: Bool {
        guard let h = ctx.db.setting(BrainSetting.policyApprovedHash) else { return false }
        let stored = storedRules()
        return !stored.isEmpty && PolicyParser.hash(stored) == h
    }

    var policyStale: Bool {
        guard let h = ctx.db.setting(BrainSetting.policyApprovedHash) else { return false }
        let stored = storedRules()
        return PolicyParser.hash(stored) != h || policyStamp() != ctx.db.setting(BrainSetting.policySourceStamp)
    }

    func makeRulesCard(_ rules: [PolicyRule], origin: String) {
        for s in suggestions("kind='rules' AND state IN ('pending','later') AND origin=?", [.text(origin)]) { setState(s.id, "withdrawn") }
        let list: [[String: Any]] = rules.map { ["kind": $0.kind, "pattern": $0.pattern, "target": $0.target ?? NSNull(), "note": $0.note] }
        let s = OrgSuggestion(id: newID("s:", "rules"), kind: "rules", docId: nil, path: nil,
                              payload: ["rules": list, "hash": PolicyParser.hash(rules), "count": rules.count],
                              confidence: 1, reasons: [], origin: origin, ruleKey: "rules", state: "pending",
                              created: nowTS, decided: nil, batchId: nil, cooldownUntil: nil, error: nil)
        save(s)
        ctx.emit(.pending)
    }

    func approvePolicy() -> [String: Any] {
        let rules = ensurePolicy(force: false)
        ctx.db.setSetting(BrainSetting.policyApprovedHash, PolicyParser.hash(rules))
        for s in suggestions("kind='rules' AND state IN ('pending','later') AND origin='rules'") { setState(s.id, "applied") }
        ctx.log("policy", "폴더 규칙표를 승인했어요 · \(rules.count)개")
        ctx.emit(.policy); ctx.emit(.pending)
        return ["ok": true]
    }

    /// MCP로 받은 규칙표 수정안 승인: place·frozen·exclude를 교체한다(기본 규칙·landing·duty는 둔다).
    func approveProposedRules(_ s: OrgSuggestion) -> [String: Any] {
        let proposed = ((s.payload["rules"] as? [[String: Any]]) ?? []).compactMap { r -> PolicyRule? in
            guard let k = r["kind"] as? String, ["place", "frozen", "exclude"].contains(k), let p = r["pattern"] as? String else { return nil }
            return PolicyRule(kind: k, pattern: p, target: r["target"] as? String, source: s.origin, note: (r["note"] as? String) ?? "")
        }
        let kept = storedRules().filter { !["place", "frozen", "exclude"].contains($0.kind) || $0.source == "기본" || $0.source.contains("(v0.4") }
        let merged = PolicyParser.sorted(kept + proposed)
        replaceRules(merged)
        ctx.db.setSetting(BrainSetting.policyApprovedHash, PolicyParser.hash(merged))
        setState(s.id, "applied")
        for o in suggestions("kind='rules' AND state IN ('pending','later') AND origin='rules'") { setState(o.id, "withdrawn") }
        ctx.log("policy", "\(Organizer.originLabel(s.origin))으로 규칙표를 바꿨어요 · \(merged.count)개", origin: Organizer.logOrigin(s.origin))
        ctx.emit(.policy); ctx.emit(.pending)
        return ["ok": true, "applied": NSNull(), "undoable": false]
    }

    // MARK: 정책 위반 (ADR·TN 번호 중복, duty)

    func violations() -> [[String: Any]] {
        var out: [[String: Any]] = []
        let numRx = try! NSRegularExpression(pattern: #"^(ADR|TN)-(\d+)"#, options: [.caseInsensitive])
        for v in vaults() {
            let rules = rules(for: v)
            let hasDuty = rules.contains { $0.kind == "duty" }
            let proj = projects(v)
            var byProject: [String: [(kind: String, num: Int, doc: BrainDoc)]] = [:]
            var summaries: [String: BrainDoc] = [:]
            for d in ctx.docs where d.sourceId == v.sourceId && d.isLocal && Organizer.isMarkdown(d.relPath) {
                let rel = d.relPath
                if isArchived(rel) || isAIArchive(d) || isFrozen(rel, rules) { continue }
                guard let p = proj.projectOf(rel) else { continue }
                let name = Organizer.fileName(rel)
                if name == "프로젝트_요약.md" { if summaries[p] == nil || rel.hasPrefix("2-Areas/") { summaries[p] = d }; continue }
                let ns = name as NSString
                if let m = numRx.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)) {
                    byProject[p, default: []].append((ns.substring(with: m.range(at: 1)).uppercased(), Int(ns.substring(with: m.range(at: 2))) ?? -1, d))
                }
            }
            for p in byProject.keys.sorted() {
                let items = byProject[p]!.sorted { $0.doc.relPath < $1.doc.relPath }
                var groups: [String: [BrainDoc]] = [:]
                for it in items { groups["\(it.kind)-\(it.num)", default: []].append(it.doc) }
                for (k, docs) in groups.sorted(by: { $0.key < $1.key }) where docs.count > 1 {
                    let parts = k.split(separator: "-")
                    let label = "\(parts[0])-" + String(format: "%03d", Int(parts[1]) ?? 0)
                    out.append(["text": "\(p): \(label) 번호가 \(docs.count)개예요 (" + docs.map { Organizer.fileName($0.relPath) }.joined(separator: ", ") + ")",
                                "docId": docs[0].id])
                }
                guard hasDuty else { continue }
                let adrs = items.filter { $0.kind == "ADR" && !$0.doc.relPath.contains("/_workspace/") }
                if adrs.isEmpty { continue }
                guard let sum = summaries[p] else {
                    out.append(["text": "\(p): 프로젝트_요약.md가 없어요 (ADR \(adrs.count)개)", "docId": adrs[0].doc.id]); continue
                }
                let body = ctx.text(sum)
                for a in adrs {
                    let re = try! NSRegularExpression(pattern: "ADR-0*\(a.num)(?!\\d)", options: [.caseInsensitive])
                    if re.firstMatch(in: body, range: NSRange(location: 0, length: (body as NSString).length)) == nil {
                        out.append(["text": "\(p): 프로젝트_요약.md에 ADR-" + String(format: "%03d", a.num) + "이 없어요", "docId": a.doc.id])
                    }
                }
            }
        }
        return out
    }

    /// 주 1회(월요일 첫 배치) 위반 점검 → policy 카드 1장(최대 10항목).
    func weeklyPolicyCheck() {
        guard Calendar.current.component(.weekday, from: now) == 2 else { return }
        var done = false
        try? ctx.db.sql.query("SELECT 1 FROM ai_log WHERE kind='policy' AND ref='weekly' AND ts>=? LIMIT 1", [.double(startOfToday)]) { _ in done = true }
        if done { return }
        let list = Array(violations().prefix(10))
        for s in suggestions("kind='policy' AND state IN ('pending','later')") { setState(s.id, "withdrawn") }
        if list.isEmpty { ctx.log("policy", "정책 점검: 고칠 것이 없어요", ref: "weekly"); return }
        save(OrgSuggestion(id: newID("s:", "policy"), kind: "policy", docId: nil, path: nil, payload: ["violations": list],
                           confidence: 1, reasons: [], origin: "rules", ruleKey: "policy", state: "pending", created: nowTS,
                           decided: nil, batchId: nil, cooldownUntil: nil, error: nil))
        ctx.log("policy", "정책 점검: 고칠 것 \(list.count)개", ref: "weekly")
        ctx.emit(.pending)
    }

    func policy() -> [String: Any] {
        let rules = ensurePolicy(force: false)
        var counts: [String: Int] = ["place": 0, "frozen": 0, "exclude": 0, "landing": 0, "duty": 0]
        for r in rules { counts[r.kind, default: 0] += 1 }
        var sources: [[String: Any]] = []
        for v in vaults() {
            for f in policyFiles(v) { sources.append(["path": f.rel, "mtimeLabel": clockLabel(f.mtime) ?? ""]) }
        }
        return ["approved": policyApproved, "stale": policyStale, "sources": sources,
                "rules": rules.map { ruleJSON($0) }, "counts": counts, "violations": violations(), "folders": folders()]
    }

    func ruleJSON(_ r: PolicyRule) -> [String: Any] {
        var src = r.source
        if r.source.hasPrefix("mcp:") { src = Organizer.originLabel(r.source) }
        else if let v = vaults().first(where: { r.source.hasPrefix($0.root + "/") }) { src = String(r.source.dropFirst(v.root.count + 1)) }
        return ["kind": r.kind, "pattern": r.pattern, "target": r.target ?? NSNull(), "note": r.note, "source": src]
    }
}
