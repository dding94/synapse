import Foundation

// 적용·되돌리기 (§6.6·§6.8). 볼트에 쓰는 유일한 곳: 승인된 이동(renameExact)과 그 이동에 필요한 링크 수정.
// 순서: 재검증 → 링크 영향 → 백업·ops_log → 이동 → 원자적 고쳐 쓰기 → 알림 → 사후 검사(늘면 자동 롤백).

extension Organizer {

    var movesBackupRoot: URL { ctx.home.appendingPathComponent("backups/moves") }

    @discardableResult
    func opsInsert(_ batch: String, _ seq: Int, _ op: String, from: String, to: String, backup: String?, before: String, note: [String: Any]) -> Bool {
        (try? ctx.db.sql.run("""
            INSERT INTO ops_log(batch_id, seq, op, from_path, to_path, backup_path, before_hash, after_hash, ts, undone, note)
            VALUES(?,?,?,?,?,?,?,NULL,?,0,?)
            """, [.text(batch), .int(Int64(seq)), .text(op), .text(from), .text(to), backup.map { .text($0) } ?? .null,
                  .text(before), .double(nowTS), .text(BrainFormat.json(note))])) != nil
    }

    func opsUpdate(_ batch: String, _ seq: Int, afterHash: String? = nil, note: [String: Any]? = nil) {
        if let h = afterHash { _ = try? ctx.db.sql.run("UPDATE ops_log SET after_hash=? WHERE batch_id=? AND seq=?", [.text(h), .text(batch), .int(Int64(seq))]) }
        if let n = note { _ = try? ctx.db.sql.run("UPDATE ops_log SET note=? WHERE batch_id=? AND seq=?", [.text(BrainFormat.json(n)), .text(batch), .int(Int64(seq))]) }
    }

    /// 같은 폴더 임시 파일 → replaceItemAt. 원래 권한 유지, mtime을 주면 그 시각으로 되돌린다.
    func atomicWrite(_ path: String, _ data: Data, mtime: Double?) throws {
        let fm = FileManager.default
        let perms = (try? fm.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.int16Value ?? 0o644
        let url = URL(fileURLWithPath: path)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".synapse-move-\(UUID().uuidString).\(url.pathExtension)")
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: perms]) else {
            throw LibraryError("임시 파일을 만들지 못했어요.")
        }
        do { _ = try fm.replaceItemAt(url, withItemAt: tmp) } catch { try? fm.removeItem(at: tmp); throw error }
        var attrs: [FileAttributeKey: Any] = [.posixPermissions: perms]
        if let m = mtime { attrs[.modificationDate] = Date(timeIntervalSince1970: m) }
        try? fm.setAttributes(attrs, ofItemAtPath: path)
    }

    /// 폴더 항목 이름을 디스크 바이트 그대로 읽는다(Foundation 경로 변환을 거치지 않는다).
    static func rawEntries(_ dir: String) -> [String] {
        guard let d = dir.withCString({ opendir($0) }) else { return [] }
        defer { closedir(d) }
        var out: [String] = []
        while let ent = readdir(d) {
            let name = withUnsafePointer(to: &ent.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(ent.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { out.append(name) }
        }
        return out
    }

    /// NFC가 같은 실제 항목 이름(저장된 형식 그대로). 없으면 nil.
    static func rawName(dir: String, name: String) -> String? {
        let n = Array(Indexer.nfc(name).unicodeScalars)
        return rawEntries(dir).first { Array(Indexer.nfc($0).unicodeScalars) == n }
    }

    /// 이름 바이트를 바꾸지 않는 원자적 이동(덮어쓰기 금지). FileManager.moveItem은 이름을 NFD로 바꿔 저장한다.
    static func renameExact(_ src: String, _ dst: String) throws {
        let rc = src.withCString { s in dst.withCString { d in renamex_np(s, d, UInt32(RENAME_EXCL)) } }
        if rc == 0 { return }
        let err = errno
        if err == ENOTSUP || err == EINVAL {
            if FileManager.default.fileExists(atPath: dst) { throw LibraryError("같은 이름 파일이 있어요.") }
            if src.withCString({ s in dst.withCString { d in rename(s, d) } }) == 0 { return }
        }
        throw LibraryError("옮기지 못했어요 (errno \(errno)).")
    }

    private func newBatchID() -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        return "m" + f.string(from: now) + "-" + String(UUID().uuidString.prefix(4)).lowercased()
    }

    /// 승인된 move 제안들을 한 배치로 옮긴다. 결과는 decide 형식.
    /// v0.6 direct: 직접 옮기기(사용자·MCP 바로 실행). 상한은 부르는 쪽이 정한다. origin "user"는 사용자 정책
    /// (동결·제외 구역에서도 꺼낼 수 있고 목적지는 있는 폴더면 된다, 폴더 출처도 된다, 방금 고친 파일·옵시디언에서 연 파일도 옮긴다).
    func applyMoves(_ items: [OrgSuggestion], direct: Bool = false) -> [String: Any] {
        if ctx.isStopped { return ["ok": false, "error": "사서가 멈춰 있어요. 다시 시작한 뒤 옮길 수 있어요."] }
        let room = direct ? items.count : min(perApply, perDay - usedToday)
        if room <= 0 && !direct { return ["ok": false, "error": "오늘 상한(\(perDay)건)에 닿았어요. 내일 다시 옮길 수 있어요."] }
        let batch = newBatchID()
        var moved = 0, links = 0, seq = 0
        var rewrote = Set<String>()
        var skipped: [[String: Any]] = []
        var done: [OrgSuggestion] = []
        let fm = FileManager.default
        for s in items {
            let user = direct && s.origin == "user"
            let title = (s.payload["title"] as? String) ?? (s.path.map { Organizer.fileName($0) } ?? "")
            func skip(_ reason: String, fail: Bool) {
                skipped.append(["title": title, "reason": reason])
                if fail { setState(s.id, "failed", error: reason) }
            }
            if moved >= room { skip("오늘 상한이라 다음에 옮겨요", fail: false); continue }
            let sid = (s.payload["sourceId"] as? String) ?? ""
            guard s.kind == "move", let v = vault(sourceId: sid) ?? (user ? localVault(sourceId: sid) : nil),
                  let from = s.payload["from"] as? String, let to = s.payload["to"] as? String else {
                skip("볼트 밖이거나 원격 문서는 옮기지 않아요", fail: true); continue
            }
            let rules = rules(for: v)
            let toRel = Organizer.folderKey(to) + Organizer.fileName(from)
            let fromAbs = v.abs(from), toAbs = v.abs(toRel)
            // 쓰기 직전 재검증
            guard let st = fileStamp(fromAbs) else { skip("원본이 없어요", fail: true); continue }
            if abs(st.mtime - ((s.payload["fromMtime"] as? Double) ?? -1)) > 0.001 || st.size != ((s.payload["fromSize"] as? Int) ?? -1) {
                skip("제안한 뒤에 파일이 바뀌었어요", fail: true); continue
            }
            if user {
                if from.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { skip("숨김 폴더 문서는 옮기지 않아요", fail: true); continue }
            } else if isExcluded(from, rules, asSource: true) || isFrozen(from, rules) { skip("동결·제외 구역 문서예요", fail: true); continue }
            if let p = sourceProblem(v, from) { skip(p, fail: true); continue }
            if let p = user ? userDestinationProblem(v, to) : destinationProblem(v, to, rules) { skip("목적지: " + p, fail: true); continue }
            // 디스크에 저장된 그대로의 이름(NFC·NFD 바이트 보존). 목적지는 같은 바이트 이름으로 만든다.
            let srcDir = Organizer.parent(fromAbs), dstDir = Organizer.parent(toAbs)
            let raw = Organizer.rawName(dir: srcDir, name: Organizer.fileName(from)) ?? Organizer.fileName(from)
            let srcPath = srcDir + "/" + raw, dstPath = dstDir + "/" + raw
            if fm.fileExists(atPath: toAbs) || Organizer.rawName(dir: dstDir, name: raw) != nil { skip("같은 이름 파일이 있어요", fail: false); continue }
            if !user && openInObsidian(fromAbs) { skip("옵시디언에서 열려 있어요", fail: false); continue }
            if !user && nowTS - st.mtime < 120 { skip("방금 고친 파일이에요", fail: false); continue }
            let plan = planMove(v, fromRel: from, toRel: toRel, files: listFiles(v))
            if let p = plan.problem { skip(p, fail: true); continue }
            // ops_log를 먼저 남긴다: rewrite(백업) 행 → move 행(진행 중). 기록하지 못하면 옮기지 않는다.
            let dir = movesBackupRoot.appendingPathComponent(batch)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let moveSeq = seq + 1
            var editSeq: [Int] = []
            var logged = true
            for (i, e) in plan.edits.enumerated() {
                let n = moveSeq + 1 + i
                let src = v.abs(e.rel)
                let bpath = dir.appendingPathComponent("\(n)-" + Organizer.fileName(e.rel)).path
                let perms = (try? fm.attributesOfItem(atPath: src)[.posixPermissions] as? NSNumber)?.int16Value ?? 0o600
                guard fm.createFile(atPath: bpath, contents: e.original, attributes: [.posixPermissions: perms]),
                      opsInsert(batch, n, "rewrite", from: e.moved ? dstPath : src, to: e.moved ? dstPath : src, backup: bpath,
                                before: Organizer.sha1(e.original), note: ["moved": e.moved, "mtime": fileStamp(src)?.mtime ?? st.mtime])
                else { logged = false; break }
                editSeq.append(n)
            }
            let moveNote: [String: Any] = ["docId": s.docId ?? "", "toId": v.docID(toRel)]
            if logged { logged = opsInsert(batch, moveSeq, "move", from: srcPath, to: dstPath, backup: nil, before: "\(st.size)-\(st.mtime)",
                                           note: moveNote.merging(["state": "running"]) { $1 }) }
            if !logged { neutralize(batch, from: moveSeq); skip("기록을 남기지 못해 옮기지 않았어요", fail: true); continue }
            seq = moveSeq + plan.edits.count
            // 이동 (이름 바이트·수정 시각 그대로)
            do { try Organizer.renameExact(srcPath, dstPath) } catch {
                neutralize(batch, from: moveSeq); skip("옮기지 못했어요: 권한을 확인해 주세요", fail: true); continue
            }
            opsUpdate(batch, moveSeq, note: moveNote.merging(["state": "done"]) { $1 })
            // 링크 고쳐 쓰기: 쓰기 직전에 다시 읽어 계획 때와 같을 때만 쓴다(사용자가 그사이 쓴 내용 보호)
            var written = [fromAbs, toAbs]
            var failure: String? = nil
            Organizer.testBeforeRewrite?()
            for (i, e) in plan.edits.enumerated() {
                let path = e.moved ? dstPath : v.abs(e.rel)
                guard let cur = fm.contents(atPath: path), cur == e.original else {
                    failure = "링크를 고치는 사이에 \(Organizer.fileName(e.rel)) 파일이 바뀌어 되돌렸어요"; break
                }
                var text = e.newText
                if Organizer.testBreakRewrite { text = text.replacingOccurrences(of: Organizer.parent(toRel), with: "없는-폴더") }
                let data = Data(text.utf8)
                opsUpdate(batch, editSeq[i], afterHash: Organizer.sha1(data))      // 예정 해시를 먼저 적는다
                do { try atomicWrite(path, data, mtime: e.moved ? st.mtime : nil) } catch {
                    failure = "링크를 고쳐 쓰지 못해 되돌렸어요"; break
                }
                written.append(path)
            }
            ctx.onSynapseWrite(written)
            if let fromID = s.docId { ctx.onDocMoved(fromID, v.docID(toRel), fromAbs, toAbs) }
            // 사후 검사
            if failure == nil && unresolvedNow(v, plan) > plan.unresolvedBefore { failure = "링크가 깨질 뻔해서 되돌렸어요" }
            if let reason = failure {
                let rv = revert(batch, strict: false)
                let tail = rv.conflicts.isEmpty ? "" : " · 충돌 \(rv.conflicts.count)건은 그대로 두었어요"
                ctx.log("rollback", reason + ": " + title + tail, origin: Organizer.logOrigin(s.origin), ref: s.id, batch: batch)
                for d in done + [s] { setState(d.id, "failed", error: reason, batch: batch) }
                ctx.emit(.pending); ctx.emit(.log)
                let back = (done + [s]).map { ["title": ($0.payload["title"] as? String) ?? "", "reason": reason] as [String: Any] }
                let conf = rv.conflicts.map { ["title": Organizer.fileName(($0["path"] as? String) ?? ""), "reason": ($0["reason"] as? String) ?? ""] as [String: Any] }
                return ["ok": true, "applied": ["batchId": batch, "moved": 0, "rewrote": 0, "links": 0, "skipped": skipped + back + conf],
                        "undoable": false]
            }
            moved += 1; links += plan.links
            for e in plan.edits { rewrote.insert(e.moved ? toRel : e.rel) }
            setState(s.id, "applied", batch: batch)
            // 같은 문서의 다른 제안(규칙·Claude)은 정리한다
            for o in suggestions("doc_id=? AND kind='move' AND state IN ('pending','later') AND id<>?", [.text(s.docId ?? ""), .text(s.id)]) {
                setState(o.id, "withdrawn")
            }
            ctx.log("apply", (direct && !user ? "바로 실행 · " : "") + "옮겼어요: \(from) → \(Organizer.folderKey(to)) · 링크 \(plan.links)개 고침",
                    origin: Organizer.logOrigin(s.origin), ref: s.id, batch: batch)
            done.append(s)
        }
        ctx.emit(.pending); ctx.emit(.log)
        return ["ok": true, "applied": ["batchId": batch, "moved": moved, "rewrote": rewrote.count, "links": links, "skipped": skipped],
                "undoable": moved > 0]
    }
}
