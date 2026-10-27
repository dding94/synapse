import Foundation

// v0.6 T — Synapse 휴지통 (COMMON §3 C3). 사용자 파일을 영구 삭제하지 않는다.
// 보내기: 재검증(로컬 출처 안·심볼릭 링크 아님·있음) → ops_log(op "trash", 진행 중) → <home>/trash/<batch>/<상대 경로>로 이름 바꾸기
//        (볼륨이 달라 이름을 못 바꾸면 복사 → 크기·해시 확인 → 원본은 macOS 휴지통) → trash_items·AI 기록.
// 되살리기: 원래 자리로. 같은 이름이 있으면 " (복원)"을 붙이고, 원래 폴더가 없어졌으면 그 폴더만 다시 만든다(원래 있던 폴더 복원).
// 30일이 지나면 macOS 휴지통으로 넘긴다(FileManager.trashItem). SYNAPSE_SYSTEM_TRASH_DIR가 있으면(시험) 그 폴더로,
// 시험 홈(기본 위치가 아닌 홈)인데 그 값이 없으면 <home>/system-trash-test로 — 시험이 실제 macOS 휴지통을 건드리지 않게.
// 경로는 색인의 location이 아니라 지금 출처 설정(sources) 루트 + 상대 경로로 만든다(색인이 옛 위치를 가리켜도 다른 곳을 건드리지 않게).

/// trash_items 한 행.
struct TrashItem {
    var id: String
    var batch: String
    var docId: String
    var sourceId: String
    var rel: String
    var title: String
    var origPath: String
    var trashPath: String
    var size: Int
    var hash: String
    var copied: Bool
    var deleted: Double
    var expires: Double
    var origin: String
    var via: String          // user(직접) | approved(제안 승인) | direct(MCP 바로 실행)
    var reason: String
    var inbound: Int
    var state: String        // pending(보내는 중) | trashed | restored | purged | lost | cancelled
}

/// 지울 수 있는지 본 결과.
struct TrashCheck {
    let doc: BrainDoc
    let root: String          // 출처 루트 실제 경로(NFC)
    let abs: String           // 지금 파일 절대 경로(NFC)
    let zone: String?         // "frozen" | "exclude" — 사용자는 지울 수 있지만 알린다
}

extension Organizer {

    static let trashDays = 30.0
    var trashRoot: URL { ctx.home.appendingPathComponent("trash") }

    private static let trashCols = "id, batch_id, doc_id, source_id, rel_path, title, orig_path, trash_path, size, hash, copied, deleted, expires, origin, via, reason, inbound, state"

    func trashItems(_ whereSQL: String, _ args: [SQLValue] = []) -> [TrashItem] {
        var out: [TrashItem] = []
        try? ctx.db.sql.query("SELECT \(Organizer.trashCols) FROM trash_items WHERE \(whereSQL)", args) { r in
            out.append(TrashItem(id: r.text(0), batch: r.text(1), docId: r.text(2), sourceId: r.text(3), rel: r.text(4), title: r.text(5),
                                 origPath: r.text(6), trashPath: r.text(7), size: Int(r.int(8)), hash: r.text(9), copied: r.int(10) == 1,
                                 deleted: r.double(11), expires: r.double(12), origin: r.text(13), via: r.text(14), reason: r.text(15),
                                 inbound: Int(r.int(16)), state: r.text(17)))
        }
        return out
    }

    private func saveTrash(_ t: TrashItem) -> Bool {
        (try? ctx.db.sql.run("INSERT OR REPLACE INTO trash_items(\(Organizer.trashCols)) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [
            .text(t.id), .text(t.batch), .text(t.docId), .text(t.sourceId), .text(t.rel), .text(t.title), .text(t.origPath), .text(t.trashPath),
            .int(Int64(t.size)), .text(t.hash), .int(t.copied ? 1 : 0), .double(t.deleted), .double(t.expires), .text(t.origin), .text(t.via),
            .text(t.reason), .int(Int64(t.inbound)), .text(t.state)])) != nil
    }

    private func setTrashState(_ id: String, _ state: String, restored: String? = nil, note: String? = nil) {
        _ = try? ctx.db.sql.run("UPDATE trash_items SET state=?, done=?, restored_path=coalesce(?, restored_path), note=coalesce(?, note) WHERE id=?",
                                [.text(state), .double(nowTS), restored.map { .text($0) } ?? .null, note.map { .text($0) } ?? .null, .text(id)])
    }

    /// 휴지통 항목의 ops_log 행 표시: 1 = 되살림(되돌림), 2 = macOS 휴지통으로(되돌릴 수 없음).
    private func markTrashOp(_ t: TrashItem, undone: Int) {
        _ = try? ctx.db.sql.run("UPDATE ops_log SET undone=? WHERE batch_id=? AND op='trash' AND undone=0 AND note LIKE ?",
                                [.int(Int64(undone)), .text(t.batch), .text("%\"trashId\":\"\(t.id)\"%")])
    }

    // MARK: 출처·검사

    /// 로컬 출처(폴더·옵시디언)의 설정과 실제 루트 경로(NFC).
    func localSource(_ sourceId: String) -> (SourceConfig, String)? {
        guard let s = ctx.sources().first(where: { $0.id == sourceId && $0.enabled && !$0.kind.isRemoteKind }), let p = s.path else { return nil }
        return (s, Indexer.nfc(Indexer.realPath(p)))
    }

    /// 폴더 출처도 정리 볼트처럼 다룬다(사용자 직접 옮기기 전용 — 규칙표는 옵시디언 볼트에만 있다).
    func localVault(sourceId: String) -> OrgVault? {
        guard let (s, root) = localSource(sourceId) else { return nil }
        return OrgVault(sourceId: s.id, root: root, excludeFolders: Indexer.excludedFolders(s))
    }

    /// 이 색인 링크 수만큼 다른 문서가 이 문서를 가리킨다(본문 링크만. 언급·이슈 키는 세지 않는다).
    func inboundCount(_ docId: String) -> Int {
        var n = 0
        try? ctx.index?.writer.query("SELECT count(DISTINCT src) FROM links WHERE dst=? AND src<>dst AND kind='link'", [.text(docId)]) { n = Int($0.int(0)) }
        return n
    }

    /// 지울 수 있는가. mcp면 이동과 같은 정책(옵시디언 볼트 마크다운, 동결·제외·보호 파일 금지, 옵시디언에서 연 파일 금지).
    func trashCheck(_ id: String, mcp: Bool) -> (TrashCheck?, String?) {
        guard let d = ctx.doc(id: id) else { return (nil, "문서를 찾지 못했어요") }
        guard d.isLocal, let (src, root) = localSource(d.sourceId) else { return (nil, "Confluence·Jira 문서는 Synapse에서 지울 수 없어요") }
        if mcp && src.kind != .obsidian { return (nil, "옵시디언 볼트 문서만 지울 수 있어요") }
        if mcp && !Organizer.isMarkdown(d.relPath) { return (nil, "마크다운 문서만 지울 수 있어요") }
        let rel = d.relPath
        if rel.isEmpty || rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return (nil, "숨김 폴더 문서는 지우지 않아요") }
        let abs = root + "/" + rel
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: abs), let type = attrs[.type] as? FileAttributeType else {
            return (nil, "파일이 없어요")
        }
        if type == .typeSymbolicLink { return (nil, "심볼릭 링크 문서는 지우지 않아요") }
        if type != .typeRegular { return (nil, "파일이 아니라서 지우지 않아요") }
        let real = Indexer.nfc(Indexer.realPath(abs))
        if !real.hasPrefix(root + "/") || real.lowercased() != Indexer.nfc(abs).lowercased() { return (nil, "출처 밖을 가리키는 문서는 지우지 않아요") }
        var zone: String? = nil
        if src.kind == .obsidian, let v = vault(sourceId: d.sourceId) {
            let rules = rules(for: v)
            if isFrozen(rel, rules) { zone = "frozen" } else if isExcluded(rel, rules, asSource: false) { zone = "exclude" }
        }
        if mcp {
            if zone == "frozen" { return (nil, "동결 구역 문서는 지우지 않아요") }
            if zone == "exclude" { return (nil, "보호된 문서(CLAUDE.md·PROGRESS.md·_Templates 등)나 제외 구역은 지우지 않아요") }
            if openInObsidian(abs) { return (nil, "옵시디언에서 열려 있어요") }
        }
        return (TrashCheck(doc: d, root: root, abs: abs, zone: zone), nil)
    }

    static func zoneLabel(_ z: String?) -> String? {
        switch z {
        case "frozen"?: return "동결 구역 문서예요"
        case "exclude"?: return "보호된 문서예요(정리 규칙의 제외 구역)"
        default: return nil
        }
    }

    // MARK: 파일 옮기기 (이름 바꾸기 우선, 볼륨이 다르면 복사·확인)

    /// 파일 내용 해시(sha1). 못 읽으면 "".
    static func fileHash(_ path: String) -> String {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return "" }
        return sha1(d)
    }

    /// 덮어쓰지 않는 이름 바꾸기. 볼륨이 달라 못 하면 EXDEV를 알린다.
    private static func renameNoReplace(_ src: String, _ dst: String) -> Int32 {
        let rc = src.withCString { s in dst.withCString { d in renamex_np(s, d, UInt32(RENAME_EXCL)) } }
        if rc == 0 { return 0 }
        let err = errno
        if err == ENOTSUP || err == EINVAL {
            if FileManager.default.fileExists(atPath: dst) { return EEXIST }
            if src.withCString({ s in dst.withCString { d in rename(s, d) } }) == 0 { return 0 }
            return errno
        }
        return err
    }

    /// src를 dst로 옮긴다. 같은 볼륨이면 이름 바꾸기(바이트·시각 그대로). 볼륨이 다르면 복사 → 크기·해시 확인 → original(src)은 afterCopy가 처리한다.
    /// 돌려주는 값: 복사했으면 true.
    private func relocate(_ src: String, _ dst: String, afterCopy: (String) throws -> Void) throws -> Bool {
        let rc = Organizer.renameNoReplace(src, dst)
        if rc == 0 { return false }
        if rc == EEXIST { throw LibraryError("같은 이름 파일이 있어요.") }
        guard rc == EXDEV else { throw LibraryError("옮기지 못했어요 (errno \(rc)). 권한을 확인해 주세요.") }
        let fm = FileManager.default
        let dstBefore = fm.fileExists(atPath: dst)
        do { try fm.copyItem(atPath: src, toPath: dst) } catch {
            if !dstBefore { try? fm.removeItem(atPath: dst) }      // 복사 도중 실패하면 우리가 만든 부분 복사본만 지운다(원본은 그대로)
            throw error
        }
        let a = fileStamp(src), b = fileStamp(dst)
        guard let a = a, let b = b, a.size == b.size, Organizer.fileHash(src) == Organizer.fileHash(dst) else {
            try? fm.removeItem(atPath: dst)      // 확인에 실패한 우리 복사본만 지운다(원본은 그대로)
            throw LibraryError("복사한 내용이 원본과 달라서 그만뒀어요.")
        }
        do { try afterCopy(src) } catch {
            try? fm.removeItem(atPath: dst)      // 원본을 치우지 못했으면 우리 복사본을 거둔다(원본은 그대로)
            throw error
        }
        return true
    }

    /// 시험용 시스템 휴지통 폴더. nil이면 진짜 macOS 휴지통.
    var systemTrashDir: String? {
        if let v = ProcessInfo.processInfo.environment["SYNAPSE_SYSTEM_TRASH_DIR"], !v.isEmpty { return (v as NSString).expandingTildeInPath }
        return ctx.env.isTest ? ctx.home.appendingPathComponent("system-trash-test").path : nil
    }

    /// macOS 휴지통으로 보낸다(지우지 않는다). 시험이면 systemTrashDir로 이름만 바꾼다.
    func systemTrash(_ path: String) throws {
        let fm = FileManager.default
        guard let dir = systemTrashDir else {
            try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            return
        }
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let name = Organizer.fileName(path)
        var dst = dir + "/" + name, n = 2
        while fm.fileExists(atPath: dst) {
            let ext = (name as NSString).pathExtension, stem = (name as NSString).deletingPathExtension
            dst = dir + "/" + stem + " \(n)" + (ext.isEmpty ? "" : "." + ext); n += 1
        }
        let rc = Organizer.renameNoReplace(path, dst)
        if rc != 0 { throw LibraryError("시험 휴지통으로 옮기지 못했어요 (errno \(rc)).") }
    }

    private func newTrashBatchID() -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        return "t" + f.string(from: now) + "-" + String(UUID().uuidString.prefix(4)).lowercased()
    }

    // MARK: 보내기

    func trashInfo(_ ids: [String]) -> [String: Any] {
        var items: [[String: Any]] = [], total = 0
        for id in Organizer.unique(ids) {
            let (c, why) = trashCheck(id, mcp: false)
            let d = c?.doc ?? ctx.doc(id: id)
            let inbound = inboundCount(id)
            total += inbound
            var x: [String: Any] = ["id": id, "title": d?.title ?? Organizer.fileName(String(id.split(separator: ":", maxSplits: 1).last ?? Substring(id))), "path": d?.relPath ?? "", "inbound": inbound, "canTrash": c != nil]
            if let w = why { x["reason"] = w }
            if let z = c?.zone { x["zone"] = z; x["warning"] = Organizer.zoneLabel(z) ?? "" }
            items.append(x)
        }
        return ["items": items, "totalInbound": total, "retentionDays": Int(Organizer.trashDays)]
    }

    static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>(); return ids.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 문서들을 Synapse 휴지통으로. origin: "user" | "mcp:claude" … · via: user | approved | direct.
    /// mcp = 이동과 같은 정책으로 검사한다(MCP 바로 실행·MCP 제안 승인).
    func trashDocs(_ ids: [String], origin: String, reason: String?, mcp: Bool, via: String) -> [String: Any] {
        if ctx.isStopped { return ["ok": false, "error": "사서가 멈춰 있어서 지우지 않았어요. 다시 시작한 뒤 해 주세요."] }
        recoverTrash()
        let batch = newTrashBatchID()
        let fm = FileManager.default
        var moved: [[String: Any]] = [], skipped: [[String: Any]] = []
        var written: [String] = []
        var seq = 0
        let why = (reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        for id in Organizer.unique(ids) {
            let (check, problem) = trashCheck(id, mcp: mcp)
            guard let c = check else { skipped.append(["id": id, "reason": problem ?? "지울 수 없어요"]); continue }
            let d = c.doc
            // 디스크에 저장된 그대로의 이름(NFC·NFD 바이트 보존)
            let dir = Organizer.parent(c.abs)
            let raw = Organizer.rawName(dir: dir, name: Organizer.fileName(d.relPath)) ?? Organizer.fileName(d.relPath)
            let srcPath = dir + "/" + raw
            guard let st = fileStamp(srcPath) else { skipped.append(["id": id, "reason": "파일이 없어요"]); continue }
            let relDir = Organizer.parent(d.relPath)
            var base = trashRoot.appendingPathComponent(batch).path
            if fm.fileExists(atPath: base + "/" + d.relPath) { base += "/" + String(d.sourceId.prefix(8)) }   // 같은 배치에 같은 상대 경로(다른 출처)
            let dstDir = relDir.isEmpty ? base : base + "/" + relDir
            do { try fm.createDirectory(atPath: dstDir, withIntermediateDirectories: true) } catch {
                skipped.append(["id": id, "reason": "Synapse 휴지통 폴더를 만들지 못했어요"]); continue
            }
            let dstPath = dstDir + "/" + raw
            let hash = Organizer.fileHash(srcPath)
            let inbound = inboundCount(id)
            seq += 1
            let tid = newID("t:", id)
            var item = TrashItem(id: tid, batch: batch, docId: id, sourceId: d.sourceId, rel: d.relPath, title: d.title,
                                 origPath: srcPath, trashPath: dstPath, size: st.size, hash: hash, copied: false,
                                 deleted: nowTS, expires: nowTS + Organizer.trashDays * 86400, origin: origin, via: via,
                                 reason: String(why.prefix(200)), inbound: inbound, state: "pending")
            // 기록을 먼저 남긴다(진행 중). 기록하지 못하면 옮기지 않는다.
            let note: [String: Any] = ["docId": id, "trashId": tid, "state": "running"]
            guard opsInsert(batch, seq, "trash", from: srcPath, to: dstPath, backup: nil, before: "\(st.size)-\(st.mtime)", note: note),
                  saveTrash(item) else {
                neutralize(batch, from: seq)
                _ = try? ctx.db.sql.run("DELETE FROM trash_items WHERE id=?", [.text(tid)])
                skipped.append(["id": id, "reason": "기록을 남기지 못해 지우지 않았어요"]); continue
            }
            do {
                item.copied = try relocate(srcPath, dstPath) { original in try self.systemTrash(original) }
            } catch {
                _ = try? ctx.db.sql.run("UPDATE ops_log SET undone=1 WHERE batch_id=? AND seq=?", [.text(batch), .int(Int64(seq))])
                setTrashState(tid, "cancelled", note: error.localizedDescription)
                skipped.append(["id": id, "reason": (error as? LibraryError)?.message ?? "옮기지 못했어요: 권한을 확인해 주세요"]); continue
            }
            item.state = "trashed"
            _ = saveTrash(item)
            opsUpdate(batch, seq, note: note.merging(["state": "done", "copied": item.copied]) { $1 })
            written.append(Indexer.nfc(srcPath))
            var m: [String: Any] = ["id": id, "title": d.title, "from": d.relPath, "trashId": tid, "inbound": inbound]
            if let w = Organizer.zoneLabel(c.zone) { m["warning"] = w }
            moved.append(m)
        }
        if !written.isEmpty { ctx.onSynapseWrite(written) }
        if !moved.isEmpty {
            let first = (moved[0]["title"] as? String) ?? ""
            let what = first + (moved.count > 1 ? " 외 \(moved.count - 1)건" : "")
            let links = moved.reduce(0) { $0 + (($1["inbound"] as? Int) ?? 0) }
            let head = via == "direct" ? "바로 실행 · " : via == "approved" ? Organizer.originLabel(origin) + " 승인 · " : ""
            ctx.log("trash", head + "휴지통으로 보냈어요: \(what) · 30일 보관" + (links > 0 ? " · 끊긴 링크 \(links)개" : ""),
                    origin: Organizer.logOrigin(origin), ref: moved[0]["trashId"] as? String, batch: batch)
            ctx.emit(.pending); ctx.emit(.log); ctx.emit(.home)
        }
        return ["ok": true, "batch": moved.isEmpty ? NSNull() : batch, "moved": moved, "skipped": skipped,
                "retentionDays": Int(Organizer.trashDays), "undoable": !moved.isEmpty]
    }

    // MARK: 목록

    /// 앱이 보내는 도중 끝났으면(pending) 디스크를 보고 맞춘다.
    func recoverTrash() {
        let fm = FileManager.default
        for t in trashItems("state='pending'") {
            if nowTS - t.deleted < 600 { continue }      // 다른 프로세스(앱·MCP)가 막 기록한 항목일 수 있어 10분이 지난 것만 맞춘다
            if fm.fileExists(atPath: t.trashPath) {
                _ = try? ctx.db.sql.run("UPDATE trash_items SET state='trashed' WHERE id=?", [.text(t.id)])
            } else {
                setTrashState(t.id, "cancelled", note: "보내는 도중 멈췄어요")
                markTrashOp(t, undone: 1)
            }
        }
    }

    static func trashOriginLabel(_ origin: String) -> String {
        switch cardOrigin(origin) {
        case "user": return "나"
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "rules": return "규칙"
        case let n: return n
        }
    }

    func trashJSON(_ t: TrashItem) -> [String: Any] {
        let left = max(0, Int(ceil((t.expires - nowTS) / 86400)))
        return ["id": t.id, "docId": t.docId, "title": t.title, "path": t.rel, "sourceId": t.sourceId,
                "deletedAt": BrainFormat.iso(Date(timeIntervalSince1970: t.deleted)),
                "deletedLabel": BrainFormat.whenLabel(Date(timeIntervalSince1970: t.deleted), now: now),
                "expiresAt": BrainFormat.iso(Date(timeIntervalSince1970: t.expires)), "daysLeft": left,
                "origin": Organizer.cardOrigin(t.origin), "originLabel": Organizer.trashOriginLabel(t.origin), "via": t.via,
                "reason": t.reason, "batch": t.batch, "size": t.size, "inbound": t.inbound]
    }

    func listTrash() -> [String: Any] {
        recoverTrash()
        let fm = FileManager.default
        var out: [[String: Any]] = []
        for t in trashItems("state='trashed' ORDER BY deleted DESC, id") {
            if !fm.fileExists(atPath: t.trashPath) { setTrashState(t.id, "lost", note: "Synapse 휴지통에서 파일이 없어졌어요"); markTrashOp(t, undone: 2); continue }
            out.append(trashJSON(t))
        }
        return ["items": out, "count": out.count, "retentionDays": Int(Organizer.trashDays)]
    }

    func trashCount() -> Int {
        var n = 0
        try? ctx.db.sql.query("SELECT count(*) FROM trash_items WHERE state='trashed'") { n = Int($0.int(0)) }
        return n
    }

    /// id(휴지통 항목) 또는 문서 id로 찾는다. 문서 id면 그 문서의 가장 최근 항목.
    private func trashTargets(ids: [String]?, batch: String?) -> [TrashItem] {
        if let b = batch, !b.isEmpty { return trashItems("state='trashed' AND batch_id=? ORDER BY deleted, id", [.text(b)]) }
        var out: [TrashItem] = [], seen = Set<String>()
        for id in Organizer.unique(ids ?? []) {
            let hit = trashItems("state='trashed' AND id=?", [.text(id)]).first
                ?? trashItems("state='trashed' AND doc_id=? ORDER BY deleted DESC LIMIT 1", [.text(id)]).first
            if let t = hit, seen.insert(t.id).inserted { out.append(t) }
        }
        return out
    }

    // MARK: 되살리기

    /// 원래 폴더 경로(디스크 이름 그대로). 없는 폴더는 원래 이름 그대로 만든다(루트 안에서만). 만들 수 없으면 nil.
    private func ensureFolder(_ root: String, _ relDir: String) -> String? {
        guard isDir(root) else { return nil }
        if relDir.isEmpty { return root }
        var cur = root
        for comp in relDir.split(separator: "/").map(String.init) {
            if comp.hasPrefix(".") { return nil }
            let existing = Organizer.rawName(dir: cur, name: comp)
            let next = cur + "/" + (existing ?? comp)
            if existing == nil, next.withCString({ mkdir($0, 0o755) }) != 0, !isDir(next) { return nil }
            guard isDir(next), Indexer.nfc(Indexer.realPath(next)).hasPrefix(root + "/") else { return nil }   // 심볼릭 링크로 루트 밖에 나가지 않는다
            cur = next
        }
        return cur
    }

    /// 원래 이름이 차 있으면 "이름 (복원).md", 그것도 있으면 "이름 (복원 2).md" …
    private func freeName(_ dir: String, _ name: String) -> String {
        let fm = FileManager.default
        func taken(_ n: String) -> Bool { fm.fileExists(atPath: dir + "/" + n) || Organizer.rawName(dir: dir, name: n) != nil }
        if !taken(name) { return name }
        let ext = (name as NSString).pathExtension, stem = (name as NSString).deletingPathExtension
        for i in 1...99 {
            let n = stem + (i == 1 ? " (복원)" : " (복원 \(i))") + (ext.isEmpty ? "" : "." + ext)
            if !taken(n) { return n }
        }
        return stem + " (복원 \(UUID().uuidString.prefix(4)))" + (ext.isEmpty ? "" : "." + ext)
    }

    func restoreTrash(ids: [String]?, batch: String?, logUndo: Bool = false) -> [String: Any] {
        recoverTrash()
        let targets = trashTargets(ids: ids, batch: batch)
        if targets.isEmpty { return ["ok": false, "error": "되살릴 항목이 없어요. 이미 되살렸거나 macOS 휴지통으로 넘어갔어요."] }
        let fm = FileManager.default
        var restored: [[String: Any]] = [], failed: [[String: Any]] = [], written: [String] = []
        var renamed = 0
        for t in targets {
            guard fm.fileExists(atPath: t.trashPath) else {
                setTrashState(t.id, "lost", note: "Synapse 휴지통에서 파일이 없어졌어요"); markTrashOp(t, undone: 2)
                failed.append(["id": t.id, "title": t.title, "path": t.rel, "reason": "휴지통에 파일이 없어요"]); continue
            }
            guard let (_, root) = localSource(t.sourceId) else {
                failed.append(["id": t.id, "title": t.title, "path": t.rel, "reason": "원래 출처가 없거나 꺼져 있어요"]); continue
            }
            let relDir = Organizer.parent(t.rel)
            guard let dir = ensureFolder(root, relDir) else {
                failed.append(["id": t.id, "title": t.title, "path": t.rel, "reason": "원래 폴더를 다시 만들지 못했어요"]); continue
            }
            let name = freeName(dir, Organizer.fileName(t.trashPath))
            let dst = dir + "/" + name
            do {
                _ = try relocate(t.trashPath, dst) { copy in try self.systemTrash(copy) }   // 볼륨이 다르면 확인한 뒤 우리 복사본만 치운다
            } catch {
                failed.append(["id": t.id, "title": t.title, "path": t.rel, "reason": (error as? LibraryError)?.message ?? "되살리지 못했어요"]); continue
            }
            let relOut = (relDir.isEmpty ? "" : relDir + "/") + Indexer.nfc(name)
            setTrashState(t.id, "restored", restored: relOut)
            markTrashOp(t, undone: 1)
            if name != Organizer.fileName(t.trashPath) { renamed += 1 }
            written.append(Indexer.nfc(dst))
            restored.append(["id": t.id, "docId": t.sourceId + ":" + relOut, "path": relOut, "title": t.title, "renamed": name != Organizer.fileName(t.trashPath)])
            Organizer.removeEmptyDirs(Organizer.parent(t.trashPath), stop: trashRoot.path)
        }
        if !written.isEmpty { ctx.onSynapseWrite(written) }
        if !restored.isEmpty {
            let first = (restored[0]["title"] as? String) ?? ""
            let what = first + (restored.count > 1 ? " 외 \(restored.count - 1)건" : "")
            ctx.log(logUndo ? "undo" : "restore", (logUndo ? "되돌렸어요: " : "되살렸어요: ") + what + (renamed > 0 ? " · 같은 이름이 있어 \(renamed)건은 \"(복원)\"을 붙였어요" : ""),
                    origin: "user", ref: restored[0]["id"] as? String, batch: targets[0].batch)
            ctx.emit(.pending); ctx.emit(.log); ctx.emit(.home)
        }
        return ["ok": true, "restored": restored, "failed": failed]
    }

    /// Synapse 휴지통 안의 빈 폴더만 지운다(rmdir은 빈 폴더만 지운다).
    static func removeEmptyDirs(_ start: String, stop: String) {
        var cur = start
        while cur.hasPrefix(stop + "/") && cur != stop {
            if cur.withCString({ rmdir($0) }) != 0 { break }
            cur = parent(cur)
        }
    }

    // MARK: macOS 휴지통으로

    func purgeTrash(ids: [String], expired: Bool = false) -> [String: Any] {
        recoverTrash()
        let targets = trashTargets(ids: ids, batch: nil)
        return purge(targets, expired: expired)
    }

    private func purge(_ targets: [TrashItem], expired: Bool) -> [String: Any] {
        if targets.isEmpty { return ["ok": true, "purged": 0, "failed": []] }
        let fm = FileManager.default
        var n = 0, failed: [[String: Any]] = [], titles: [String] = []
        for t in targets {
            if !fm.fileExists(atPath: t.trashPath) { setTrashState(t.id, "lost", note: "Synapse 휴지통에서 파일이 없어졌어요"); markTrashOp(t, undone: 2); continue }
            do { try systemTrash(t.trashPath) } catch {
                failed.append(["id": t.id, "title": t.title, "reason": "macOS 휴지통으로 옮기지 못했어요"]); continue
            }
            setTrashState(t.id, "purged"); markTrashOp(t, undone: 2)
            Organizer.removeEmptyDirs(Organizer.parent(t.trashPath), stop: trashRoot.path)
            n += 1; titles.append(t.title)
        }
        if n > 0 {
            let what = titles[0] + (n > 1 ? " 외 \(n - 1)건" : "")
            ctx.log("purge", (expired ? "30일이 지나 macOS 휴지통으로 옮겼어요: " : "macOS 휴지통으로 옮겼어요: ") + what,
                    origin: expired ? "rules" : "user", batch: targets[0].batch)
            ctx.emit(.pending); ctx.emit(.log)
        }
        return ["ok": true, "purged": n, "failed": failed]
    }

    /// 30일 지난 항목을 macOS 휴지통으로(앱 시작·한 시간마다·CLI 읽기 전). 비상 정지면 미룬다.
    @discardableResult
    func purgeExpiredTrash() -> Int {
        guard !ctx.isStopped, ctx.mode != .mcp else { return 0 }
        recoverTrash()
        let old = trashItems("state='trashed' AND expires<=? ORDER BY deleted, id", [.double(nowTS)])
        return (purge(old, expired: true)["purged"] as? Int) ?? 0
    }

    /// undo(batch)가 휴지통 배치를 되돌린다 — 되살리기와 같다. 결과는 undo 형식.
    func undoTrash(_ batch: String) -> [String: Any] {
        if trashItems("state='trashed' AND batch_id=?", [.text(batch)]).isEmpty { return ["ok": false, "error": "이미 되돌렸거나 없는 적용이에요"] }
        let r = restoreTrash(ids: nil, batch: batch, logUndo: true)
        for s in suggestions("batch_id=? AND state='applied'", [.text(batch)]) { var x = s; x.error = "undone"; save(x) }   // 승인한 삭제 제안
        let restored = (r["restored"] as? [Any])?.count ?? 0
        let conflicts = ((r["failed"] as? [[String: Any]]) ?? []).map { ["path": ($0["path"] as? String) ?? "", "reason": ($0["reason"] as? String) ?? ""] as [String: Any] }
        return ["ok": true, "restored": restored, "conflicts": conflicts]
    }

    func isTrashBatch(_ batch: String) -> Bool {
        var hit = false
        try? ctx.db.sql.query("SELECT 1 FROM ops_log WHERE batch_id=? AND op='trash' LIMIT 1", [.text(batch)]) { _ in hit = true }
        return hit
    }
}
