import Foundation

// 되돌리기·자동 롤백 (§6.8). 충돌은 덮어쓰지 않는다.
// undo(사용자)는 엄격: 충돌이 하나라도 있으면 아무것도 바꾸지 않고 충돌만 알린다(일부만 되돌리면 링크가 깨진다).
// 자동 롤백은 되돌릴 수 있는 것을 되돌리고, 남은 충돌을 결과·ai_log에 알린다.

extension Organizer {

    /// 쓰지 못한 항목의 ops_log 행을 무효로(되돌릴 것 없음).
    func neutralize(_ batch: String, from seq: Int) {
        _ = try? ctx.db.sql.run("UPDATE ops_log SET undone=1 WHERE batch_id=? AND seq>=?", [.text(batch), .int(Int64(seq))])
    }

    private struct Op { let id: Int64; let op: String; let from: String; let to: String; let backup: String?; let before: String; let after: String?; let note: [String: Any] }

    private func ops(_ batch: String) -> [Op] {
        var out: [Op] = []
        try? ctx.db.sql.query("SELECT id, op, from_path, to_path, backup_path, before_hash, after_hash, note FROM ops_log WHERE batch_id=? AND undone=0 ORDER BY seq DESC",
                              [.text(batch)]) { r in
            out.append(Op(id: r.int(0), op: r.text(1), from: r.text(2), to: r.text(3), backup: r.isNull(4) ? nil : r.text(4), before: r.text(5),
                          after: r.isNull(6) ? nil : r.text(6), note: (BrainFormat.parse(r.text(7)) as? [String: Any]) ?? [:]))
        }
        return out
    }

    /// 배치를 거꾸로 되돌린다. strict면 먼저 모두 검사하고 충돌이 있으면 아무것도 하지 않는다.
    func revert(_ batch: String, strict: Bool) -> (restored: Int, conflicts: [[String: Any]]) {
        let list = ops(batch)
        let fm = FileManager.default
        func done(_ id: Int64) { _ = try? ctx.db.sql.run("UPDATE ops_log SET undone=1 WHERE id=?", [.int(id)]) }
        // 검사: rewrite는 지금 내용이 우리가 쓴 것(after)이면 되돌릴 것, 원래(before)면 쓴 적 없음, 그 밖은 충돌
        enum Plan { case restore, skip, conflict(String) }
        var plans: [Int64: Plan] = [:]
        var conflicts: [[String: Any]] = [], blocked = Set<String>()
        for o in list where o.op == "rewrite" {
            guard let after = o.after else { plans[o.id] = .skip; continue }
            let h = fm.contents(atPath: o.from).map { Organizer.sha1($0) }
            if h == after, o.backup.flatMap({ fm.contents(atPath: $0) }) != nil { plans[o.id] = .restore }
            else if h == o.before { plans[o.id] = .skip }
            else {
                let why = h == nil ? "고친 파일이 없어요" : "옮긴 뒤에 내용이 바뀌어 되돌리지 않았어요"
                plans[o.id] = .conflict(why); conflicts.append(["path": o.from, "reason": why])
                if (o.note["moved"] as? Bool) == true { blocked.insert(o.to) }
            }
        }
        for o in list where o.op == "move" {
            var why: String? = nil
            let st = (o.note["state"] as? String) ?? "done"
            if st != "done" && !fm.fileExists(atPath: o.to) { plans[o.id] = .skip; continue }   // 옮기기 전에 멈춤
            if blocked.contains(o.to) { why = "옮긴 파일이 바뀌어 제자리로 돌리지 않았어요" }
            else if fm.fileExists(atPath: o.from) { why = "원래 자리에 같은 이름 파일이 있어요" }
            else if !fm.fileExists(atPath: o.to) { why = "옮긴 파일이 없어요" }
            if let w = why { plans[o.id] = .conflict(w); if !blocked.contains(o.to) { conflicts.append(["path": o.from, "reason": w]) } }
            else { plans[o.id] = .restore }
        }
        if strict && !conflicts.isEmpty { return (0, conflicts) }
        var restored = 0, written: [String] = []
        for o in list {
            switch plans[o.id] ?? .skip {
            case .skip: done(o.id)
            case .conflict: continue
            case .restore:
                if o.op == "rewrite" {
                    guard let b = o.backup, let orig = fm.contents(atPath: b) else { continue }
                    do { try atomicWrite(o.from, orig, mtime: o.note["mtime"] as? Double); restored += 1; done(o.id); written.append(o.from) }
                    catch { conflicts.append(["path": o.from, "reason": "되돌려 쓰지 못했어요"]) }
                } else if o.op == "move" {
                    do { try Organizer.renameExact(o.to, o.from) } catch {
                        conflicts.append(["path": o.to, "reason": "제자리로 옮기지 못했어요"]); continue
                    }
                    restored += 1; done(o.id); written += [o.to, o.from]
                    if let fromID = o.note["toId"] as? String, let toID = o.note["docId"] as? String, !toID.isEmpty {
                        ctx.onDocMoved(fromID, toID, Indexer.nfc(o.to), Indexer.nfc(o.from))
                    }
                }
            }
        }
        if !written.isEmpty { ctx.onSynapseWrite(written.map { Indexer.nfc($0) }) }
        return (restored, conflicts)
    }

    func undo(batchId: String?) -> [String: Any] {
        var bid = batchId, ts = 0.0, any = false
        if bid == nil {
            try? ctx.db.sql.query("SELECT batch_id FROM ops_log WHERE op IN ('move','trash') AND undone=0 ORDER BY ts DESC, id DESC LIMIT 1") { bid = $0.text(0) }
        }
        guard let b = bid else { return ["ok": false, "error": "되돌릴 적용이 없어요"] }
        if isTrashBatch(b) { return undoTrash(b) }      // v0.6: 휴지통 보내기는 되살리기로 되돌린다 (OrganizerTrash)
        try? ctx.db.sql.query("SELECT min(ts), sum(undone=0), sum(undone=2) FROM ops_log WHERE batch_id=?", [.text(b)]) { r in
            ts = r.double(0); any = r.int(1) > 0 && r.int(2) == 0
        }
        if !any { return ["ok": false, "error": "이미 되돌렸거나 없는 적용이에요"] }
        if nowTS - ts > Organizer.cooldownDays * 86400 { return ["ok": false, "error": "30일이 지나 되돌릴 수 없어요"] }
        let r = revert(b, strict: true)
        let applied = suggestions("batch_id=? AND state='applied'", [.text(b)])
        let titles = applied.map { ($0.payload["title"] as? String) ?? "" }
        let what = titles.first.map { $0 + (titles.count > 1 ? " 외 \(titles.count - 1)건" : "") } ?? b
        if !r.conflicts.isEmpty {
            ctx.log("undo", "되돌리지 않았어요: \(what) · 충돌 \(r.conflicts.count)건", batch: b)
            ctx.emit(.log)
            return ["ok": true, "restored": 0, "conflicts": r.conflicts]
        }
        for s in applied { var x = s; x.error = "undone"; save(x) }
        ctx.log("undo", "되돌렸어요: " + what, batch: b)
        ctx.emit(.pending); ctx.emit(.log)
        return ["ok": true, "restored": r.restored, "conflicts": []]
    }

    /// 30일 지난 배치 백업을 지우고 되돌리기 불가(undone=2)로 표시한다. (Synapse 홈 안의 백업만)
    func purgeOldBackups() {
        var old: [String] = []
        try? ctx.db.sql.query("SELECT DISTINCT batch_id FROM ops_log WHERE ts<? AND undone=0", [.double(nowTS - Organizer.cooldownDays * 86400)]) { old.append($0.text(0)) }
        for b in old {
            try? FileManager.default.removeItem(at: movesBackupRoot.appendingPathComponent(b))
            _ = try? ctx.db.sql.run("UPDATE ops_log SET undone=2 WHERE batch_id=? AND undone=0", [.text(b)])
        }
    }

    /// 앱이 이동 도중 끝났으면(move 행이 "진행 중") AI 기록에 한 번 알린다.
    func noteInterrupted() {
        var rows: [(Int64, String, String)] = []
        try? ctx.db.sql.query("SELECT id, batch_id, to_path FROM ops_log WHERE op='move' AND undone=0 AND note LIKE '%\"state\":\"running\"%'") {
            rows.append(($0.int(0), $0.text(1), $0.text(2)))
        }
        for (id, b, to) in rows {
            ctx.log("rollback", "이동이 중간에 멈췄어요: \(Organizer.fileName(to)) · AI 기록에서 되돌릴 수 있어요", batch: b)
            _ = try? ctx.db.sql.run("UPDATE ops_log SET note=replace(note, '\"state\":\"running\"', '\"state\":\"interrupted\"') WHERE id=?", [.int(id)])
        }
    }
}
