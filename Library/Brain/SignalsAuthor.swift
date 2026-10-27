import Foundation

// 작성 주체(§4.2) · 이동 이어 붙이기(§4.1) · Synapse 안 활동 track(§4.5).

extension Signals {
    struct Attribution { var actor: Actor; var session: String?; var origin: String; var guess: Bool }

    static let humanKinds = "'created','modified','opened','viewed','edited','saved'"

    /// 변경 하나(문서, 시각 = mtime)의 주체. windowStart = 이전 last_change (mixed 판정 창).
    func attribute(_ d: BrainDoc, mtime: Date, windowStart: Date?, origin: String, features f: Features) -> Attribution {
        let mt = mtime.timeIntervalSince1970
        let nowD = now()
        if let p = d.absPath, let w = synapseWrites[p.precomposedStringWithCanonicalMapping],
           abs(w.timeIntervalSince(mtime)) <= 120 || nowD.timeIntervalSince(w) <= 120 {
            return Attribution(actor: .synapse, session: nil, origin: "mover", guess: false)
        }
        if let s = lastSave[d.id], abs(s.timeIntervalSince(mtime)) <= 120 {
            return Attribution(actor: .human, session: nil, origin: "synapse", guess: false)
        }
        var saved = false
        try? db.query("SELECT 1 FROM activity WHERE doc_id=? AND kind='saved' AND origin='synapse' AND ts BETWEEN ? AND ? LIMIT 1",
                      [.text(d.id), .double(mt - 120), .double(mt + 120)]) { _ in saved = true }
        if saved { return Attribution(actor: .human, session: nil, origin: "synapse", guess: false) }
        if sessionsOn, let p = d.absPath, let w = nearestWrite(path: p, ts: mt) {
            let tool: Actor = w.hasPrefix("codex:") ? .codex : .claude
            let start = (windowStart ?? mtime.addingTimeInterval(-3600)).timeIntervalSince1970
            let mixed = humanSignal(docId: d.id, from: start, to: mt)
            return Attribution(actor: mixed ? .mixed : tool, session: w, origin: tool.rawValue, guess: false)
        }
        if f.aiArchive { return Attribution(actor: .claude, session: nil, origin: origin, guess: true) }
        return Attribution(actor: .human, session: nil, origin: origin, guess: false)
    }

    /// 같은 경로의 AI 쓰기 중 |ts − mtime| ≤ 120초인 가장 가까운 것의 세션 id.
    func nearestWrite(path: String, ts: Double) -> String? {
        var best: (String, Double)? = nil
        try? db.query("SELECT session_id, ts FROM ai_writes WHERE path=? AND ts BETWEEN ? AND ?",
                      [.text(path.precomposedStringWithCanonicalMapping), .double(ts - 120), .double(ts + 120)]) { r in
            let gap = abs(r.double(1) - ts)
            if best == nil || gap < best!.1 { best = (r.text(0), gap) }
        }
        return best?.0
    }

    /// 변경 창 안에 사람 신호(편집기 편집·저장, 옵시디언에서 열림)가 있었나.
    func humanSignal(docId: String, from: Double, to: Double) -> Bool {
        if let s = lastSave[docId]?.timeIntervalSince1970, s > from + 2 && s <= to + 120 { return true }
        var found = false
        try? db.query("""
        SELECT 1 FROM activity WHERE doc_id=? AND ts > ? AND ts <= ? AND
          ((origin='synapse' AND kind IN ('saved','edited')) OR (origin='obsidian' AND kind='opened')) LIMIT 1
        """, [.text(docId), .double(from + 2), .double(to + 120)]) { _ in found = true }
        return found
    }

    func applyAttribution(_ a: Attribution, mtime: Double, to s: inout DocState) {
        guard a.actor != .synapse else { return }   // 사서가 쓴 것은 사람·AI 시각과 작성자를 바꾸지 않는다
        s.author = a.actor.rawValue
        s.authorSession = a.session
        if a.actor == .human || a.actor == .mixed { s.lastHuman = max(s.lastHuman ?? 0, mtime) }
        if a.actor == .claude || a.actor == .codex || a.actor == .mixed { s.lastAI = max(s.lastAI ?? 0, mtime) }
    }

    func insertActivity(ts: Double, docId: String?, path: String?, kind: String, actor: Actor, origin: String,
                        session: String?, detail: [String: Any]?) {
        _ = try? db.run("INSERT INTO activity(ts, doc_id, path, kind, actor, origin, session_id, detail) VALUES(?,?,?,?,?,?,?,?)",
                        [.double(ts), docId.map { .text($0) } ?? .null, path.map { .text($0) } ?? .null, .text(kind),
                         .text(actor.rawValue), .text(origin), session.map { .text($0) } ?? .null,
                         detail.map { .text(BrainFormat.json($0)) } ?? .null])
    }

    // MARK: 이동

    /// 외부 이동(같은 내용 삭제+생성): 이전 행·할 일·활동을 새 id로 잇는다. restore = 이미 지운 행(메모리).
    func moveState(from oldID: String, to d: BrainDoc, analysis a: Analysis, restore: DocState?) {
        var s = restore ?? loadState(oldID) ?? DocState(docId: oldID, sourceId: d.sourceId, path: d.relPath)
        let oldPath = s.path
        if restore == nil { _ = try? db.run("DELETE FROM doc_state WHERE doc_id=?", [.text(oldID)]) }
        rekey(from: oldID, to: d.id)
        s.docId = d.id; s.path = d.relPath
        s.updated = d.modified.timeIntervalSince1970
        let f = features(d, analysis: a)
        apply(features: f, analysis: a, to: &s)
        let bySynapse = d.absPath.flatMap { synapseWrites[$0.precomposedStringWithCanonicalMapping] }
            .map { now().timeIntervalSince($0) <= 120 } ?? false
        insertActivity(ts: nowTS, docId: d.id, path: d.absPath, kind: "moved", actor: bySynapse ? .synapse : .human,
                       origin: bySynapse ? "mover" : "fsevents", session: nil, detail: ["from": oldPath, "to": d.relPath])
        syncTasks(d, analysis: a, features: f, initial: false, state: &s)
        writeState(s)
    }

    /// 할 일 id(문서 id가 들어감)와 활동의 doc_id를 새 id로 바꾼다.
    func rekey(from oldID: String, to newID: String) {
        var rows: [(String, String)] = []
        try? db.query("SELECT id, text FROM tasks WHERE doc_id=? AND origin != 'jira'", [.text(oldID)]) { rows.append(($0.text(0), $0.text(1))) }
        for (id, text) in rows {
            let nid = Signals.taskID(docId: newID, norm: text)
            _ = try? db.run("DELETE FROM tasks WHERE id=?", [.text(nid)])
            _ = try? db.run("UPDATE tasks SET id=?, doc_id=?, gone=0 WHERE id=?", [.text(nid), .text(newID), .text(id)])
        }
        _ = try? db.run("UPDATE activity SET doc_id=? WHERE doc_id=?", [.text(newID), .text(oldID)])
    }

    /// 사서(Mover)가 옮겼다 — ctx.onDocMoved에서 부른다. 색인이 따라오기 전에 행을 새 id로 옮겨 둔다.
    func docMoved(fromID: String, toID: String, fromPath: String, toPath: String) {
        let toN = toPath.precomposedStringWithCanonicalMapping
        synapseWrites[toN] = now()
        synapseWrites[fromPath.precomposedStringWithCanonicalMapping] = now()
        guard var s = loadState(fromID) else { return }
        // Mover가 트랜잭션 안에서 부를 수 있어 여기서는 트랜잭션을 열지 않는다
        let oldRel = s.path
        // v0.9: 정리 비서는 출처를 넘어 옮긴다(데스크톱 → _workspace 출처). 새 id = "<출처 id>:<상대 경로>"에서 출처를 다시 읽는다
        let colon = toID.firstIndex(of: ":")
        let newSource = colon.map { String(toID[..<$0]) } ?? s.sourceId
        let newRel = colon.map { String(toID[toID.index(after: $0)...]) } ?? toID
        let newSrc = ctx.sources().first { $0.id == newSource }
        _ = try? db.run("DELETE FROM doc_state WHERE doc_id=?", [.text(fromID)])
        rekey(from: fromID, to: toID)
        s.docId = toID
        if newSrc != nil { s.sourceId = newSource }
        // path는 옛 값으로 두면 색인이 따라올 때 경로 규칙을 다시 계산한다(아래에서 바로 하지 못한 경우)
        writeState(s)
        insertActivity(ts: nowTS, docId: toID, path: toN, kind: "moved", actor: .synapse, origin: "mover",
                       session: nil, detail: ["from": oldRel, "to": newRel])
        if let old = ctx.doc(id: fromID) {
            let moved = BrainDoc(id: toID, rowid: old.rowid, sourceId: newSrc?.id ?? old.sourceId, sourceKind: newSrc?.kind ?? old.sourceKind,
                                 kind: old.kind, title: old.title, relPath: newRel, absPath: toN, location: toN,
                                 folder: (newRel as NSString).deletingLastPathComponent, modified: old.modified,
                                 created: old.created, size: old.size, tags: old.tags, outLinks: old.outLinks,
                                 issueKeys: old.issueKeys, meta: old.meta,
                                 paraRel: ctx.vaults.paraRel(forAbs: toN))   // v0.9 §3.2: 새 자리의 볼트 기준 경로
            refreshPathFeatures(moved)   // 새 경로로 유형·프로젝트 등을 바로 다시 계산
        }
    }

    func noteSynapseWrite(_ paths: [String]) {
        let t = now()
        for p in paths { synapseWrites[p.precomposedStringWithCanonicalMapping] = t }
        synapseWrites = synapseWrites.filter { t.timeIntervalSince($0.value) < 600 }
    }

    // MARK: track (§4.5)

    func track(event: String, docId: String) {
        let kinds = ["open": "opened", "view": "viewed", "edit": "edited", "save": "saved"]
        guard let kind = kinds[event] else { return }
        let t = nowTS
        if event == "save" { lastSave[docId] = now() }
        var recent = false
        try? db.query("SELECT 1 FROM activity WHERE doc_id=? AND kind=? AND origin='synapse' AND ts > ? LIMIT 1",
                      [.text(docId), .text(kind), .double(t - 300)]) { _ in recent = true }
        let d = ctx.doc(id: docId)
        if !recent {
            insertActivity(ts: t, docId: docId, path: d?.absPath ?? d?.relPath, kind: kind, actor: .human,
                           origin: "synapse", session: nil, detail: nil)
        }
        let open = event == "open" || event == "view"
        _ = try? db.run("UPDATE doc_state SET last_human=MAX(COALESCE(last_human,0), ?)"
                        + (open ? ", last_open=MAX(COALESCE(last_open,0), ?)" : "") + " WHERE doc_id=?",
                        open ? [.double(t), .double(t), .text(docId)] : [.double(t), .text(docId)])
    }

    // MARK: 재판정 (세션 읽기가 뒤늦게 ai_writes를 더했을 때)

    /// writes: (세션, 절대 경로, 시각). since 이후 활동 중 그 쓰기와 ±120초인 변경을 AI(또는 mixed)로 고친다.
    func reattribute(_ writes: [(String, String, Double)], since: Double) {
        let byPath = Dictionary(grouping: writes, by: { $0.1 })
        for (path, ws) in byPath {
            guard let d = ctx.doc(path: path) else { continue }
            var acts: [(Int64, Double, String, String?)] = []
            try? db.query("""
            SELECT id, ts, actor, detail FROM activity WHERE doc_id=? AND kind IN ('created','modified') AND ts >= ? ORDER BY ts
            """, [.text(d.id), .double(since)]) { acts.append(($0.int(0), $0.double(1), $0.text(2), $0.isNull(3) ? nil : $0.text(3))) }
            var touched = false
            for (i, act) in acts.enumerated() where act.2 != Actor.synapse.rawValue {
                guard let w = ws.min(by: { abs($0.2 - act.1) < abs($1.2 - act.1) }), abs(w.2 - act.1) <= 120 else { continue }
                let tool: Actor = w.0.hasPrefix("codex:") ? .codex : .claude
                let prev = i > 0 ? acts[i - 1].1 : act.1 - 3600
                let actor: Actor = humanSignal(docId: d.id, from: prev, to: act.1) ? .mixed : tool
                guard actor.rawValue != act.2 else { continue }
                var detail = (BrainFormat.parse(act.3) as? [String: Any]) ?? [:]
                detail["guess"] = nil
                _ = try? db.run("UPDATE activity SET actor=?, origin=?, session_id=?, detail=? WHERE id=?",
                                [.text(actor.rawValue), .text(tool.rawValue), .text(w.0),
                                 detail.isEmpty ? .null : .text(BrainFormat.json(detail)), .int(act.0)])
                touched = true
            }
            if touched { recomputeAuthor(d.id) }
        }
    }

    /// 활동 기록으로 doc_state.author·last_human·last_ai를 다시 맞춘다.
    func recomputeAuthor(_ docId: String) {
        guard var s = loadState(docId) else { return }
        var latest: (String, String?)? = nil
        try? db.query("""
        SELECT actor, session_id FROM activity WHERE doc_id=? AND kind IN ('created','modified') AND actor != 'synapse'
        ORDER BY ts DESC LIMIT 1
        """, [.text(docId)]) { latest = ($0.text(0), $0.isNull(1) ? nil : $0.text(1)) }
        if let l = latest { s.author = l.0; s.authorSession = l.1 }
        var human: Double? = nil, ai: Double? = nil, anyChange = false
        try? db.query("SELECT MAX(ts) FROM activity WHERE doc_id=? AND actor IN ('human','mixed') AND kind IN (\(Signals.humanKinds))",
                      [.text(docId)]) { human = $0.isNull(0) ? nil : $0.double(0) }
        try? db.query("SELECT MAX(ts) FROM activity WHERE doc_id=? AND actor IN ('claude','codex','mixed') AND kind IN ('created','modified')",
                      [.text(docId)]) { ai = $0.isNull(0) ? nil : $0.double(0) }
        try? db.query("SELECT 1 FROM activity WHERE doc_id=? AND kind IN ('created','modified') LIMIT 1", [.text(docId)]) { _ in anyChange = true }
        if anyChange || human != nil {
            // 활동이 없는 옛 문서(처음 실행 때 추정한 시각)는 그대로 둔다
            if let h = human { s.lastHuman = h } else if s.lastHuman != nil && s.lastHuman == s.lastChange { s.lastHuman = nil }
        }
        if let a = ai { s.lastAI = a } else if anyChange { s.lastAI = nil }
        writeState(s)
    }
}
