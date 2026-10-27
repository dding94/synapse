import Foundation

// v0.6 T — 직접 옮기기(moveDocs) · MCP 바로 실행(apply_changes) · 삭제 제안(propose_changes kind "delete") (COMMON §3 C3·C4).
// 옮기기는 기존 적용 경로(OrganizerMover.applyMoves: 재검증·링크 고침·백업·사후 검사·자동 롤백·되돌리기)를 그대로 쓴다.
// 직접 옮기기는 suggestions에 state "direct"·rule_key "direct" 행을 남긴다(정리함 카드·승인 상한·제안 수에는 들어가지 않는다).
// 지우기는 OrganizerTrash.trashDocs(Synapse 휴지통 30일)뿐이다. 영구 삭제는 없다.

extension Organizer {

    /// 직접 옮기기 행을 빼는 SQL 조건.
    static let notDirect = "(rule_key IS NULL OR rule_key<>'direct')"
    /// MCP 바로 실행 하루 상한(옮기기+휴지통). 넘으면 제안으로 돌린다.
    static let directPerDay = 60
    static let directOffNote = "Synapse 자료와 설정에서 '바로 실행'을 켜야 해요. 지금은 propose_changes로 제안해 주세요"

    // MARK: 검사

    /// 사용자 직접 옮기기의 목적지: 출처 안에 이미 있는 폴더(숨김·심볼릭 링크·출처 밖 아님). 동결·제외 폴더도 사용자는 고를 수 있다.
    func userDestinationProblem(_ v: OrgVault, _ folder: String) -> String? {
        let f = Organizer.folderKey(folder)
        if f.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return "숨김 폴더로는 옮기지 않아요" }
        if f.isEmpty { return nil }
        let abs = v.abs(String(f.dropLast()))
        if !isDir(abs) { return "없는 폴더예요" }
        let real = Indexer.nfc(Indexer.realPath(abs))
        if !real.hasPrefix(v.root + "/") { return "출처 밖 폴더예요" }
        if real.lowercased() != Indexer.nfc(abs).lowercased() { return "심볼릭 링크 폴더예요" }
        return nil
    }

    private func sameSpot(_ d: BrainDoc, _ v: OrgVault, _ to: String) -> String? {
        if to.lowercased() == Organizer.folderKey(Organizer.parent(d.relPath)).lowercased() { return "이미 그 폴더에 있어요" }
        let toRel = to + Organizer.fileName(d.relPath)
        let dir = to.isEmpty ? v.root : v.abs(String(to.dropLast()))
        if FileManager.default.fileExists(atPath: v.abs(toRel)) || Organizer.rawName(dir: dir, name: Organizer.fileName(d.relPath)) != nil {
            return "목적지에 같은 이름 파일이 있어요"
        }
        return nil
    }

    /// 사용자 정책: 로컬 출처(옵시디언·폴더) 파일이면 된다.
    private func userMoveCheck(_ d: BrainDoc, _ to: String) -> (OrgVault?, String?) {
        guard d.isLocal, let v = vault(sourceId: d.sourceId) ?? localVault(sourceId: d.sourceId) else { return (nil, "Confluence·Jira 문서는 옮길 수 없어요") }
        if d.relPath.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return (nil, "숨김 폴더 문서는 옮기지 않아요") }
        if let p = sourceProblem(v, d.relPath) { return (nil, p) }
        if let p = userDestinationProblem(v, to) { return (nil, "목적지가 " + p) }
        if let p = sameSpot(d, v, to) { return (nil, p) }
        return (v, nil)
    }

    /// MCP 정책: propose_changes move와 같다(옵시디언 볼트 마크다운, 동결·제외 금지, 목적지는 규칙표가 허용하는 기존 폴더).
    private func mcpMoveCheck(_ d: BrainDoc, _ to: String) -> (OrgVault?, String?) {
        guard d.isLocal, let v = vault(sourceId: d.sourceId) else { return (nil, "옵시디언 볼트 문서만 옮길 수 있어요") }
        guard Organizer.isMarkdown(d.relPath) else { return (nil, "마크다운 문서만 옮길 수 있어요") }
        let rules = rules(for: v)
        if isFrozen(d.relPath, rules) { return (nil, "동결 폴더 문서는 옮기지 않아요") }
        if isExcluded(d.relPath, rules, asSource: true) { return (nil, "제외 구역 문서는 옮기지 않아요") }
        if let p = sourceProblem(v, d.relPath) { return (nil, p) }
        if to.isEmpty { return (nil, "볼트 루트로는 옮기지 않아요") }
        if let p = destinationProblem(v, to, rules) { return (nil, "목적지가 " + p) }
        if openInObsidian(v.abs(d.relPath)) { return (nil, "옵시디언에서 열려 있어요") }
        if let p = sameSpot(d, v, to) { return (nil, p) }
        return (v, nil)
    }

    /// MCP 항목(path 또는 doc_id) → 문서. propose_changes move와 같은 규칙.
    func mcpDoc(_ item: [String: Any]) -> BrainDoc? {
        if let id = item["doc_id"] as? String, !id.isEmpty { return ctx.doc(id: id) }
        guard let p = item["path"] as? String, !p.isEmpty else { return nil }
        if p.hasPrefix("/") { return ctx.doc(path: p) ?? ctx.doc(path: Indexer.realPath(p)) }
        let rel = Indexer.nfc(p.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        let vs = Set(vaults().map { $0.sourceId })
        return ctx.docs.first { vs.contains($0.sourceId) && $0.relPath == rel }
    }

    // MARK: 직접 옮기기

    /// 문서들을 기존 폴더 to로 옮긴다(한 배치 · 링크 고침 · 되돌리기). 결과는 C3 moveDocs 형식.
    func directMove(_ ids: [String], to rawTo: String, origin: String, reason: String?, mcp: Bool) -> [String: Any] {
        if ctx.isStopped { return ["ok": false, "error": "사서가 멈춰 있어서 옮기지 않았어요. 다시 시작한 뒤 해 주세요."] }
        let to = Organizer.folderKey(Indexer.nfc(rawTo.trimmingCharacters(in: .whitespacesAndNewlines)))
        var items: [OrgSuggestion] = [], skipped: [[String: Any]] = [], moved: [[String: Any]] = []
        let why = (reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        for id in Organizer.unique(ids) {
            guard let d = ctx.doc(id: id) else { skipped.append(["id": id, "reason": "문서를 찾지 못했어요"]); continue }
            let (vault, problem) = mcp ? mcpMoveCheck(d, to) : userMoveCheck(d, to)
            guard let v = vault, problem == nil else { skipped.append(["id": id, "reason": problem ?? "옮길 수 없어요"]); continue }
            guard let st = fileStamp(v.abs(d.relPath)) else { skipped.append(["id": id, "reason": "파일이 없어요"]); continue }
            let s = OrgSuggestion(id: newID("d:", d.id + origin), kind: "move", docId: d.id, path: d.relPath,
                                  payload: ["sourceId": v.sourceId, "from": d.relPath, "to": to, "fromMtime": st.mtime, "fromSize": st.size,
                                            "title": Organizer.fileName(d.relPath), "alternatives": [], "laterCount": 0,
                                            "impact": ["links": 0, "files": 0, "canvas": 0, "changes": [], "sync": false]],
                                  confidence: 1, reasons: [why.isEmpty ? (origin == "user" ? "직접 옮겼어요" : "바로 실행") : String(why.prefix(120))],
                                  origin: origin, ruleKey: "direct", state: "direct", created: nowTS, decided: nil, batchId: nil,
                                  cooldownUntil: nil, error: nil)
            save(s)
            items.append(s)
        }
        var batch: Any = NSNull(), links = 0, undoable = false
        if !items.isEmpty {
            let r = applyMoves(items, direct: true)
            if (r["ok"] as? Bool) == false {
                let err = (r["error"] as? String) ?? "옮기지 못했어요"
                for s in items { setState(s.id, "failed", error: err); skipped.append(["id": s.docId ?? "", "reason": err]) }
                return ["ok": false, "error": err, "batch": NSNull(), "moved": [], "skipped": skipped]
            }
            let ap = (r["applied"] as? [String: Any]) ?? [:]
            let apSkipped = (ap["skipped"] as? [[String: Any]]) ?? []
            for s in items {
                let cur = suggestion(s.id)
                let from = (s.payload["from"] as? String) ?? ""
                let title = (s.payload["title"] as? String) ?? ""
                if cur?.state == "applied" {
                    let toRel = to + Organizer.fileName(from)
                    moved.append(["id": s.docId ?? "", "from": from, "to": toRel, "toId": ((s.payload["sourceId"] as? String) ?? "") + ":" + toRel, "title": title])
                } else {
                    let reason = cur?.error ?? (apSkipped.first { ($0["title"] as? String) == title }?["reason"] as? String) ?? "옮기지 못했어요"
                    if cur?.state == "direct" { setState(s.id, "failed", error: reason) }
                    skipped.append(["id": s.docId ?? "", "reason": reason])
                }
            }
            if !moved.isEmpty { batch = ap["batchId"] ?? NSNull(); links = (ap["links"] as? Int) ?? 0; undoable = (r["undoable"] as? Bool) ?? false }
        }
        if !moved.isEmpty { ctx.emit(.home) }
        return ["ok": true, "batch": batch, "moved": moved, "skipped": skipped, "links": links, "undoable": undoable]
    }

    // MARK: MCP 바로 실행 (apply_changes)

    /// 오늘 MCP가 바로 실행한 건수(옮김 + 휴지통).
    /// v0.7 H: 실행 결과와 같은 근거를 센다. 되돌린 것(옮김 error "undone", 휴지통 restored)도 오늘 쓴 수에 든다.
    /// 끝나지 않은 행(옮김 state "direct", 휴지통 "pending")은 잠금 안에서는 죽은 프로세스가 남긴 것뿐이라 파일이 옮겨졌을 수 있어 넉넉히 센다.
    /// 실패(failed)·취소(cancelled)는 파일을 옮기지 않았거나 되돌린 것이라 세지 않는다.
    func directUsedToday() -> Int {
        var a = 0, b = 0
        try? ctx.db.sql.query("SELECT count(*) FROM suggestions WHERE rule_key='direct' AND origin LIKE 'mcp:%' AND ((state='applied' AND decided>=?) OR (state='direct' AND created>=?))",
                              [.double(startOfToday), .double(startOfToday)]) { a = Int($0.int(0)) }
        try? ctx.db.sql.query("SELECT count(*) FROM trash_items WHERE via='direct' AND deleted>=? AND state<>'cancelled'",
                              [.double(startOfToday)]) { b = Int($0.int(0)) }
        return a + b
    }

    func applyChanges(_ items: [[String: Any]], origin raw: String) -> [String: Any] {
        let o = Organizer.mcpOrigin(raw)
        guard ctx.db.setting(BrainSetting.mcpDirectApply) == "on" else {
            return ["ok": false, "enabled": false, "results": [], "note": Organizer.directOffNote, "error": Organizer.directOffNote]   // v0.6 P0: 꺼짐은 성공이 아니다
        }
        if ctx.isStopped { return ["ok": false, "error": "사서가 멈춰 있어서 아무것도 바꾸지 않았어요. 사용자가 Synapse에서 다시 시작해야 해요."] }
        if items.count > 20 { return ["ok": false, "error": "한 번에 20건까지만 받아요"] }
        // v0.7 H: 셈 → 실행 → 넘친 것 제안을 프로세스 사이 잠금 안에서 한다(다른 synapse-mcp가 같은 셈을 보고 상한을 넘기지 않게).
        let lock: ProcessLock, waited: Double
        switch ProcessLock.acquire(path: directLockPath, timeout: Organizer.directLockWait) {
        case .locked(let l, let w): lock = l; waited = w
        case .busy: return ["ok": false, "error": Organizer.directBusyNote]
        case .unavailable(let why): return ["ok": false, "error": "바로 실행 잠금을 열지 못해 아무것도 바꾸지 않았어요 (\(why))"]
        }
        defer { lock.release() }
        // 기다리는 사이 꺼지거나 멈췄을 수 있어 잠근 뒤에 다시 본다.
        guard ctx.db.setting(BrainSetting.mcpDirectApply) == "on" else {
            return ["ok": false, "enabled": false, "results": [], "note": Organizer.directOffNote, "error": Organizer.directOffNote]
        }
        if ctx.isStopped { return ["ok": false, "error": "사서가 멈춰 있어서 아무것도 바꾸지 않았어요. 사용자가 Synapse에서 다시 시작해야 해요."] }
        let cap = directCap
        let used = directUsedToday()
        if ctx.env.isTest, let ms = Int(ProcessInfo.processInfo.environment["SYNAPSE_TEST_DIRECT_DELAY_MS"] ?? ""), ms > 0 {
            usleep(useconds_t(min(ms, 5000) * 1000))   // 시험: 셈과 실행 사이를 벌려 경합을 쉽게 만든다
        }
        var room = cap - used
        var results: [[String: Any]] = []
        var overflow: [(Int, [String: Any])] = []
        for (i, item) in items.enumerated() {
            let kind = (item["kind"] as? String) ?? ""
            func reject(_ why: String) { results.append(["index": i, "kind": kind, "status": "rejected", "reason": why]) }
            guard kind == "move" || kind == "delete" else { reject("kind는 move · delete 중 하나여야 해요"); continue }
            guard let d = mcpDoc(item) else { reject("문서를 찾지 못했어요"); continue }
            let to = ((item["to"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if kind == "move" && to.isEmpty { reject("to(목적지 폴더)가 필요해요"); continue }
            if room <= 0 { overflow.append((i, item)); continue }
            let reason = item["reason"] as? String
            if kind == "move" {
                let r = directMove([d.id], to: to, origin: o, reason: reason, mcp: true)
                if let m = (r["moved"] as? [[String: Any]])?.first {
                    room -= 1
                    results.append(["index": i, "kind": kind, "status": "moved", "docId": d.id, "from": m["from"] ?? "", "to": m["to"] ?? "",
                                    "toId": m["toId"] ?? "", "batch": r["batch"] ?? NSNull(), "links": r["links"] ?? 0])
                } else {
                    reject(((r["skipped"] as? [[String: Any]])?.first?["reason"] as? String) ?? (r["error"] as? String) ?? "옮기지 못했어요")
                }
            } else {
                let r = trashDocs([d.id], origin: o, reason: reason, mcp: true, via: "direct")
                if let m = (r["moved"] as? [[String: Any]])?.first {
                    room -= 1
                    results.append(["index": i, "kind": kind, "status": "trashed", "docId": d.id, "from": m["from"] ?? "", "trashId": m["trashId"] ?? "",
                                    "batch": r["batch"] ?? NSNull(), "inbound": m["inbound"] ?? 0, "retentionDays": Int(Organizer.trashDays)])
                } else {
                    reject(((r["skipped"] as? [[String: Any]])?.first?["reason"] as? String) ?? (r["error"] as? String) ?? "지우지 못했어요")
                }
            }
        }
        if !overflow.isEmpty {
            let p = propose(items: overflow.map { $0.1 }, origin: raw)
            let acc = (p["accepted"] as? [[String: Any]]) ?? [], rej = (p["rejected"] as? [[String: Any]]) ?? []
            for a in acc { if let j = a["index"] as? Int, j < overflow.count { results.append(["index": overflow[j].0, "kind": overflow[j].1["kind"] ?? "", "status": "proposed", "id": a["id"] ?? "", "reason": "오늘 바로 실행 상한(\(cap)건)을 넘어 정리함 제안으로 올렸어요"]) } }
            for x in rej { if let j = x["index"] as? Int, j < overflow.count { results.append(["index": overflow[j].0, "kind": overflow[j].1["kind"] ?? "", "status": "rejected", "reason": x["reason"] ?? "받을 수 없어요"]) } }
            if !acc.isEmpty {
                ctx.log("direct", "\(Organizer.trashOriginLabel(o)) 바로 실행이 오늘 상한(\(cap)건)을 넘어 \(acc.count)건은 정리함 제안으로 올렸어요",
                        origin: Organizer.logOrigin(o))
                ctx.emit(.log); ctx.emit(.pending)
            }
        }
        results.sort { (($0["index"] as? Int) ?? 0) < (($1["index"] as? Int) ?? 0) }
        let done = results.filter { ["moved", "trashed"].contains(($0["status"] as? String) ?? "") }.count
        let waitNote = waited >= 1 ? " 다른 Claude·Codex의 바로 실행이 끝나기를 \(Int(waited.rounded()))초 기다렸어요." : ""
        return ["ok": true, "enabled": true, "results": results,
                "limit": ["perDay": cap, "usedToday": used + done, "left": max(0, cap - used - done)],
                "note": "되돌리기는 Synapse AI 기록(⌘Y)에서 할 수 있어요. 휴지통은 30일 보관해요." + waitNote]
    }

    // MARK: 삭제 제안 (propose_changes kind "delete")

    func proposeDelete(_ item: [String: Any], origin o: String) -> (String?, String?) {
        guard let d = mcpDoc(item) else { return (nil, "문서를 찾지 못했어요") }
        let (check, problem) = trashCheck(d.id, mcp: true)
        guard let c = check else { return (nil, problem) }
        guard let st = fileStamp(c.abs) else { return (nil, "파일이 없어요") }
        for old in suggestions("doc_id=? AND kind='delete' AND origin=? AND state IN ('pending','later')", [.text(d.id), .text(o)]) { setState(old.id, "withdrawn") }
        var reasons: [String] = []
        if let why = item["reason"] as? String, !why.trimmingCharacters(in: .whitespaces).isEmpty { reasons.append(String(why.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))) }
        else { reasons.append(Organizer.originLabel(o) + "이에요") }
        let s = OrgSuggestion(id: newID("s:", d.id + o + "delete"), kind: "delete", docId: d.id, path: d.relPath,
                              payload: ["sourceId": d.sourceId, "from": d.relPath, "title": Organizer.fileName(d.relPath),
                                        "fromMtime": st.mtime, "fromSize": st.size, "inbound": inboundCount(d.id)],
                              confidence: 0.9, reasons: reasons, origin: o, ruleKey: o, state: "pending", created: nowTS,
                              decided: nil, batchId: nil, cooldownUntil: nil, error: nil)
        save(s)
        ctx.log("propose", "\(Organizer.originLabel(o)): \(Organizer.fileName(d.relPath)) 삭제(휴지통) 제안", origin: Organizer.logOrigin(o), ref: s.id)
        return (s.id, nil)
    }

    /// 정리함 "삭제 제안" 카드. impact.inbound = 끊길 링크 수, impact.conflict = 승인할 수 없는 이유.
    func deleteCard(_ s: OrgSuggestion) -> [String: Any] {
        let from = (s.payload["from"] as? String) ?? (s.path ?? "")
        var conflict: Any = NSNull()
        let (check, problem) = trashCheck(s.docId ?? "", mcp: true)
        if let c = check {
            if let st = fileStamp(c.abs), abs(st.mtime - ((s.payload["fromMtime"] as? Double) ?? -1)) > 0.001 || st.size != ((s.payload["fromSize"] as? Int) ?? -1) {
                conflict = "제안한 뒤에 파일이 바뀌었어요"
            }
        } else { conflict = problem ?? "지울 수 없어요" }
        let inbound = s.docId.map { inboundCount($0) } ?? 0
        return ["id": s.id, "kind": "delete", "origin": Organizer.cardOrigin(s.origin), "originLabel": Organizer.originLabel(s.origin),
                "title": (s.payload["title"] as? String) ?? Organizer.fileName(from), "docId": s.docId ?? NSNull(),
                "from": from, "to": NSNull(), "alternatives": [], "confidence": "", "reasons": s.reasons,
                "impact": ["links": 0, "files": 0, "canvas": 0, "changes": [], "sync": false, "inbound": inbound, "conflict": conflict,
                           "retentionDays": Int(Organizer.trashDays)],
                "items": [], "rules": [], "violations": [], "createdLabel": clockLabel(s.created) ?? ""]
    }

    /// 삭제 제안 승인 = Synapse 휴지통으로(제안한 쪽의 정책으로 다시 검사). 결과는 decide 형식 + applied.trashed.
    func approveDelete(_ s: OrgSuggestion) -> [String: Any] {
        let title = (s.payload["title"] as? String) ?? ""
        guard let id = s.docId else { return ["ok": false, "error": "문서를 찾지 못했어요"] }
        let (check, problem) = trashCheck(id, mcp: s.origin.hasPrefix("mcp:"))
        guard let c = check else { setState(s.id, "failed", error: problem); return ["ok": false, "error": problem ?? "지울 수 없어요"] }
        if let st = fileStamp(c.abs), abs(st.mtime - ((s.payload["fromMtime"] as? Double) ?? -1)) > 0.001 || st.size != ((s.payload["fromSize"] as? Int) ?? -1) {
            setState(s.id, "failed", error: "제안한 뒤에 파일이 바뀌었어요")
            return ["ok": false, "error": "제안한 뒤에 파일이 바뀌어서 지우지 않았어요"]
        }
        let r = trashDocs([id], origin: s.origin, reason: s.reasons.first, mcp: s.origin.hasPrefix("mcp:"), via: "approved")
        if (r["ok"] as? Bool) == false { return r }
        if let m = (r["moved"] as? [[String: Any]])?.first, let b = r["batch"] as? String {
            setState(s.id, "applied", batch: b)
            return ["ok": true, "applied": ["batchId": b, "moved": 0, "trashed": 1, "rewrote": 0, "links": 0, "skipped": [],
                                            "inbound": m["inbound"] ?? 0, "retentionDays": Int(Organizer.trashDays)],
                    "undoable": true]
        }
        let why = ((r["skipped"] as? [[String: Any]])?.first?["reason"] as? String) ?? "지우지 못했어요"
        setState(s.id, "failed", error: why)
        return ["ok": true, "applied": ["batchId": NSNull(), "moved": 0, "trashed": 0, "rewrote": 0, "links": 0, "skipped": [["title": title, "reason": why]]],
                "undoable": false]
    }
}
