import Foundation

// v0.9 정리 적용·되돌리기 (docs/V09.md §4.4·§4.6). 제안 하나 = 배치 하나 (배치 id "t" + yyyyMMdd-HHmmss + "-" + 4자).
// 순서: 비상 정지 확인 → 조건부 UPDATE(applying) → 재검증(snap) → 안전 검사 → 링크 계획 → ops_log 먼저 → 실행 → 링크 고쳐 쓰기
//       → 사후 검사(깨진 링크가 늘면 바로 되돌림) → 알림 → applied.
// 지우기는 없다: 휴지통은 Synapse 휴지통(되살리기 가능), rmdir은 merge 뒤 빈 폴더만(.DS_Store만 남았으면 그것만 치우고).
// ops_log의 op 이름은 "tidy-" 접두(tidy-mkdir·tidy-move·tidy-rmdir·tidy-rewrite·tidy-exclude·tidy-trash) —
// 기존 정리(Organizer.undo(nil)은 op IN ('move','trash')를 고른다)가 tidy 배치를 집지 않게 한다.

struct TidyApplyResult {
    var ok: Bool
    var batchId: String? = nil
    var done = 0
    var skipped: [[String: Any]] = []
    var error: String? = nil
}

private struct TidyMove {
    let srcRaw: String
    let dstRaw: String
    let from: String      // NFC
    let to: String        // NFC
    let isDir: Bool
}

extension Tidy {

    func newBatchID() -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        return "t" + f.string(from: ctx.now()) + "-" + String(UUID().uuidString.prefix(4)).lowercased()
    }

    /// 보관 폴더: <볼트>/4-Archive (작업 공간 자리는 <볼트>/4-Archive/_workspace).
    func archiveBase(for path: String) -> String? {
        let vm = vaultMap()
        guard let v = vm.vault(forAbs: path) else { return nil }
        let rel = vm.paraRel(forAbs: path) ?? ""
        return rel.hasPrefix("_workspace/") ? v + "/4-Archive/_workspace" : v + "/4-Archive"
    }

    // MARK: 안전 검사

    /// 출발지 문제 (사람 말). nil이면 괜찮다.
    func fromProblem(_ path: String, op: String, vm: VaultMap, sources: [TidySource], code: String?) -> String? {
        let raw = TidyFS.rawPath(path)
        guard let info = TidyFS.info(raw) else { return "원본이 없어요" }
        if info.isLink { return "심볼릭 링크는 옮기지 않아요" }
        // 조상 중에 링크가 있어 다른 곳을 가리키면 (실제 경로가 다르면) 건드리지 않는다
        if Indexer.nfc(Indexer.realPath(raw)).lowercased() != path.lowercased() { return "심볼릭 링크를 지나는 자리라 건드리지 않아요" }
        let roots = sources.map { $0.root } + vm.roots + [code].compactMap { $0 }
        if roots.contains(path) { return "출처·볼트 루트는 옮기지 않아요" }
        if roots.contains(where: { $0.hasPrefix(path + "/") }) { return "안에 출처나 볼트가 있어 옮기지 않아요" }
        if let v = vm.vault(forAbs: path), let rel = vm.paraRel(forAbs: path) {
            let comps = rel.split(separator: "/").map(String.init)
            if comps.contains(where: { $0.hasPrefix(".") || TidyNames.vaultSkip.contains($0) }) { return "볼트 설정·템플릿 폴더는 건드리지 않아요" }
            if comps == ["CLAUDE.md"] { return "볼트 규칙 파일은 옮기지 않아요" }
            if Tidy.containsFrozen(rel, frozenPatterns(vault: v)) { return "동결 구역이라 건드리지 않아요" }
        } else if !sources.contains(where: { $0.covers(path) }) && !(code.map { path.hasPrefix($0 + "/") } ?? false) {
            return "출처 밖이라 건드리지 않아요"
        }
        if op == TidyOp.exclude || op == TidyOp.note { return nil }
        let name = (path as NSString).lastPathComponent
        if TidyNames.isSecret(name) { return "비밀 값 파일은 옮기지 않아요" }
        if info.isDir {
            if let p = TidySecretScan.problem(raw) { return p }       // 숨김 폴더 안까지 이름만 본다
            let w = TidyWalk(projects: [], wantRaw: false)
            w.run(raw, nfcPath: path, baseDepth: 0, nameHit: false)
            if w.truncated { return "파일이 너무 많거나 깊어서 다 확인하지 못해 옮기지 않아요" }
        }
        return nil
    }

    /// 비밀 검사 결과 (규칙·자동 판단용 메모 — 인벤토리를 새로 만들면 지운다). 적용할 때는 fromProblem이 다시 본다.
    func secretProblem(_ path: String) -> String? {
        if let m = secretMemo[path] { return m.isEmpty ? nil : m }
        let p = TidySecretScan.problem(TidyFS.rawPath(path))
        secretMemo[path] = p ?? ""
        return p
    }

    /// 코드 저장소인가 (.git 또는 코드 표지 파일이 바로 아래, 또는 안쪽에 .git).
    func isCodeLike(_ path: String) -> Bool {
        let raw = TidyFS.rawPath(path)
        guard TidyFS.isDir(raw) else { return false }
        if TidyFS.entries(raw).contains(where: { $0.name == ".git" || TidyNames.isCodeMarker(Indexer.nfc($0.name)) }) { return true }
        let w = TidyWalk(projects: [], wantRaw: false)
        w.run(raw, nfcPath: path, baseDepth: 0, nameHit: false)
        return w.git
    }

    /// 볼트 밖 코드 저장소가 있으면 코드 폴더로만 옮긴다 (이미 볼트 안에 있는 것의 볼트 안 이동은 막지 않는다 — 승인만).
    func codeOnly(_ from: [String], vm: VaultMap) -> Bool {
        from.contains { vm.vault(forAbs: $0) == nil && isCodeLike($0) }
    }

    /// 목적지 폴더 문제. nil이면 괜찮다.
    func toProblem(_ to: String, from: [String], vm: VaultMap, sources: [TidySource], code: String?, codeOnly: Bool) -> String? {
        guard to.hasPrefix("/"), !to.contains("/../"), !to.contains("/./"), !to.hasSuffix("/..") else { return "목적지는 절대 경로여야 해요" }
        // 있는 가장 가까운 조상을 실제 경로로 풀어 다시 본다 (볼트 _workspace·4-Archive가 링크여도 밖으로 나가지 않게)
        if normalizeDest(to).lowercased() != to.lowercased() { return "목적지가 심볼릭 링크를 지나요. 옮기지 않았어요" }
        let inCode = code.map { to == $0 || to.hasPrefix($0 + "/") } ?? false
        let inVault = vm.vault(forAbs: to) != nil
        let inSource = sources.contains { $0.covers(to) }
        guard inVault || inSource || inCode else { return "목적지가 볼트·출처·코드 폴더 밖이에요" }
        if codeOnly && !inCode { return "코드 저장소는 볼트로 옮기지 않아요 (코드 폴더로만)" }
        if let v = vm.vault(forAbs: to), let rel = vm.paraRel(forAbs: to), !rel.isEmpty {
            let comps = rel.split(separator: "/").map(String.init)
            if comps.contains(where: { $0.hasPrefix(".") || TidyNames.vaultSkip.contains($0) }) { return "볼트 설정·템플릿 폴더로는 옮기지 않아요" }
            if Tidy.isFrozen(rel, frozenPatterns(vault: v)) { return "동결 구역으로는 옮기지 않아요" }
        }
        for f in from where to == f || to.hasPrefix(f + "/") { return "자기 안으로는 옮길 수 없어요" }
        let raw = TidyFS.rawPath(to)
        if let i = TidyFS.info(raw), !i.isDir { return "목적지가 폴더가 아니에요" }
        let dt = TidyFS.device(near: raw)
        for f in from where TidyFS.info(TidyFS.rawPath(f))?.dev != dt { return "다른 디스크라 옮기지 않았어요" }
        return nil
    }

    // MARK: 적용

    func apply(_ id: String, auto: Bool) -> TidyApplyResult {
        if ctx.isStopped { return TidyApplyResult(ok: false, error: "사서가 멈춰 있어서 정리하지 않았어요. 다시 시작한 뒤 승인해 주세요.") }
        guard let s = sug(id) else { return TidyApplyResult(ok: false, error: "제안을 찾지 못했어요") }
        if s.item.op == TidyOp.note {
            guard s.state == "pending" || s.state == "later" else { return TidyApplyResult(ok: false, error: "이미 처리한 알림이에요") }
            setState(id, "dismissed")
            return TidyApplyResult(ok: true)
        }
        let batch = newBatchID()
        guard claim(id, batch: batch) else { return TidyApplyResult(ok: false, error: "이미 처리했거나 바뀐 제안이에요") }
        // 재검증: 제안할 때와 같아야 한다
        let snap = s.snap
        if snap.isEmpty { return failed(s, "제안한 뒤에 바뀌었어요") }
        for st in snap {
            guard let cur = stamp(st.path), cur.same(st) else {
                let r = failed(s, "제안한 뒤에 바뀌었어요")
                invalidate()
                if !auto { _ = runRules(autoApply: false) }
                return r
            }
        }
        Tidy.testAfterRevalidate?()
        let vm = vaultMap(), sources = localSources(), code = codeFolderResolved()
        switch s.item.op {
        case TidyOp.exclude: return applyExclude(s, batch: batch, auto: auto, vm: vm, sources: sources, code: code)
        case TidyOp.trash: return applyTrash(s, batch: batch, auto: auto, vm: vm, sources: sources, code: code)
        case TidyOp.move, TidyOp.merge, TidyOp.archive: return applyMoves(s, batch: batch, auto: auto, vm: vm, sources: sources, code: code)
        default: return failed(s, "모르는 정리 동작이에요")
        }
    }

    @discardableResult
    func failed(_ s: TidySug, _ reason: String, batch: String? = nil, skipped: [[String: Any]] = []) -> TidyApplyResult {
        // 되돌릴 것이 남지 않았으면 미리 적은 배치 id를 지운다
        let keep = batch.map { hasOpenTidyRows($0) } ?? false
        setState(s.id, "failed", error: reason, batch: keep ? batch : nil, clearBatch: !keep)
        return TidyApplyResult(ok: false, batchId: nil, done: 0, skipped: skipped + [["title": s.item.title, "reason": reason]], error: reason)
    }

    private func logOrigin(_ s: TidySug) -> String { s.item.origin == "rule" ? "rules" : "claude-tidy" }

    // MARK: ops_log

    @discardableResult
    func opsInsert(_ batch: String, _ seq: Int, _ op: String, from: String, to: String, backup: String? = nil, before: String = "", note: [String: Any]) -> Bool {
        (try? ctx.db.sql.run("""
            INSERT INTO ops_log(batch_id, seq, op, from_path, to_path, backup_path, before_hash, after_hash, ts, undone, note)
            VALUES(?,?,?,?,?,?,?,NULL,?,0,?)
            """, [.text(batch), .int(Int64(seq)), .text(op), .text(from), .text(to), backup.map { .text($0) } ?? .null,
                  .text(before), .double(nowTS), .text(BrainFormat.json(note))])) != nil
    }

    func opsNote(_ batch: String, _ seq: Int, _ note: [String: Any]) {
        _ = try? ctx.db.sql.run("UPDATE ops_log SET note=? WHERE batch_id=? AND seq=?", [.text(BrainFormat.json(note)), .text(batch), .int(Int64(seq))])
    }
    func opsAfter(_ batch: String, _ seq: Int, _ hash: String) {
        _ = try? ctx.db.sql.run("UPDATE ops_log SET after_hash=? WHERE batch_id=? AND seq=?", [.text(hash), .text(batch), .int(Int64(seq))])
    }
    func opsDone(_ batch: String, seq: Int) {
        _ = try? ctx.db.sql.run("UPDATE ops_log SET undone=1 WHERE batch_id=? AND seq=?", [.text(batch), .int(Int64(seq))])
    }
    func opsDrop(_ batch: String) {
        _ = try? ctx.db.sql.run("UPDATE ops_log SET undone=1 WHERE batch_id=? AND undone=0", [.text(batch)])
    }

    /// 이름 바이트 보존 이동. 다른 볼륨이면 "다른 디스크" 오류.
    func renameItem(_ src: String, _ dst: String) throws {
        if Tidy.testEXDEV { throw LibraryError("다른 디스크라 옮기지 않았어요") }
        if Tidy.testFailRename?(src) == true { throw LibraryError("옮기지 못했어요: 권한을 확인해 주세요") }
        do { try Organizer.renameExact(src, dst) } catch {
            let msg = (error as? LibraryError)?.message ?? ""
            if msg.contains("errno \(EXDEV))") { throw LibraryError("다른 디스크라 옮기지 않았어요") }
            if msg.contains("errno \(EEXIST))") || msg.contains("같은 이름") { throw LibraryError("같은 이름이 있어 옮기지 않았어요") }
            throw LibraryError("옮기지 못했어요: 권한을 확인해 주세요")
        }
    }

    /// 옮긴 색인 문서 쌍 (옛 id, 새 id, 옛 경로, 새 경로). 새 경로를 덮는 출처가 없으면 뺀다.
    func movedDocs(from: String, to: String, sources: [TidySource]) -> [[String]] {
        var out: [[String]] = []
        for d in ctx.docs where d.isLocal {
            guard let a = d.absPath.map(Indexer.nfc), a == from || a.hasPrefix(from + "/") else { continue }
            let np = to + String(a.dropFirst(from.count))
            guard let s = source(covering: np, sources), let rel = s.rel(np), !rel.isEmpty else { continue }
            out.append([d.id, s.id + ":" + rel, a, np])
        }
        return out
    }

    // MARK: move · merge · archive

    private func applyMoves(_ s: TidySug, batch: String, auto: Bool, vm: VaultMap, sources: [TidySource], code: String?) -> TidyApplyResult {
        let i = s.item
        let fm = FileManager.default
        for f in i.from { if let p = fromProblem(f, op: i.op, vm: vm, sources: sources, code: code) { return failed(s, p) } }
        let codeLike = codeOnly(i.from, vm: vm)
        var moves: [TidyMove] = []
        var skipped: [[String: Any]] = []
        var targetDir: String
        var mergeFrom: (raw: String, nfc: String)? = nil
        switch i.op {
        case TidyOp.archive:
            guard i.from.count == 1, let f = i.from.first, let base = i.to ?? archiveBase(for: f) else { return failed(s, "보관할 볼트를 찾지 못했어요") }
            if let p = toProblem(base, from: i.from, vm: vm, sources: sources, code: code, codeOnly: codeLike) { return failed(s, p) }
            let srcRaw = TidyFS.rawPath(f)
            let rawName = (srcRaw as NSString).lastPathComponent, name = (f as NSString).lastPathComponent
            let baseRaw = TidyFS.rawPath(base)
            var dstName = rawName, dstNFC = base + "/" + name
            if TidyFS.exists(baseRaw + "/" + rawName) || Organizer.rawName(dir: baseRaw, name: name) != nil {
                let f2 = DateFormatter(); f2.locale = Locale(identifier: "en_US_POSIX"); f2.dateFormat = "yyyyMMdd"
                let sfx = "-" + f2.string(from: ctx.now())
                dstName = rawName + sfx; dstNFC = base + "/" + name + sfx
                if TidyFS.exists(baseRaw + "/" + dstName) || Organizer.rawName(dir: baseRaw, name: name + sfx) != nil { return failed(s, "보관 폴더에 같은 이름이 있어요") }
            }
            targetDir = base
            moves.append(TidyMove(srcRaw: srcRaw, dstRaw: baseRaw + "/" + dstName, from: f, to: dstNFC, isDir: TidyFS.isDir(srcRaw)))
        case TidyOp.merge:
            guard i.from.count == 1, let f = i.from.first, let to = i.to else { return failed(s, "합칠 곳이 없어요") }
            let fRaw = TidyFS.rawPath(f)
            guard TidyFS.isDir(fRaw) else { return failed(s, "합치기는 폴더만 해요") }
            if let p = toProblem(to, from: i.from, vm: vm, sources: sources, code: code, codeOnly: codeLike) { return failed(s, p) }
            targetDir = to
            let tRaw = TidyFS.rawPath(to)
            mergeFrom = (fRaw, f)
            for (n, _) in TidyFS.entries(fRaw).sorted(by: { $0.name < $1.name }) {
                if n.hasPrefix(".") { continue }
                let name = Indexer.nfc(n)
                if TidyFS.exists(tRaw + "/" + n) || Organizer.rawName(dir: tRaw, name: name) != nil {
                    skipped.append(["title": name, "reason": "같은 이름이 있어 건너뛰었어요"]); continue
                }
                moves.append(TidyMove(srcRaw: fRaw + "/" + n, dstRaw: tRaw + "/" + n, from: f + "/" + name, to: to + "/" + name, isDir: TidyFS.isDir(fRaw + "/" + n)))
            }
        default:   // move
            guard let to = i.to else { return failed(s, "목적지가 없어요") }
            if let p = toProblem(to, from: i.from, vm: vm, sources: sources, code: code, codeOnly: codeLike) { return failed(s, p) }
            targetDir = to
            let tRaw = TidyFS.rawPath(to)
            for f in i.from {
                let srcRaw = TidyFS.rawPath(f)
                let rawName = (srcRaw as NSString).lastPathComponent, name = (f as NSString).lastPathComponent
                if TidyFS.exists(tRaw + "/" + rawName) || Organizer.rawName(dir: tRaw, name: name) != nil {
                    skipped.append(["title": name, "reason": "목적지에 같은 이름이 있어요"]); continue
                }
                moves.append(TidyMove(srcRaw: srcRaw, dstRaw: tRaw + "/" + rawName, from: f, to: to + "/" + name, isDir: TidyFS.isDir(srcRaw)))
            }
        }
        // 옵시디언에서 열린 md는 건너뛴다
        let open = ctx.obsidianOpenPaths().map(Indexer.nfc)
        moves = moves.filter { m in
            if open.contains(where: { $0 == m.from || $0.hasPrefix(m.from + "/") }) {
                skipped.append(["title": (m.from as NSString).lastPathComponent, "reason": "옵시디언에서 열려 있어요"]); return false
            }
            return true
        }
        if moves.isEmpty { return failed(s, (skipped.first?["reason"] as? String) ?? "옮길 것이 없어요", skipped: Array(skipped.dropFirst())) }
        // 만들 폴더 (얕은 것부터)
        var mkdirs: [String] = []
        var cur = TidyFS.rawPath(targetDir)
        while !TidyFS.exists(cur) { mkdirs.insert(cur, at: 0); cur = (cur as NSString).deletingLastPathComponent }
        if !TidyFS.isDir(cur) { return failed(s, "목적지 위 폴더가 폴더가 아니에요") }
        // 링크 계획
        let plan = linkPlan(moves.map { ($0.from, $0.to, $0.isDir) }, vm: vm)
        if let p = plan.problem { return failed(s, p) }
        // 기록 먼저: mkdir → move → rmdir(merge) → rewrite(백업)
        var seq = 0
        var logged = true
        for d in mkdirs { seq += 1; logged = logged && opsInsert(batch, seq, "tidy-mkdir", from: d, to: d, note: [:]) }
        var moveSeq: [Int] = []
        var docPairs: [[[String]]] = []
        for m in moves {
            seq += 1
            let st = TidyFS.info(m.srcRaw)
            let docs = movedDocs(from: m.from, to: m.to, sources: sources)
            docPairs.append(docs)
            logged = logged && opsInsert(batch, seq, "tidy-move", from: m.srcRaw, to: m.dstRaw, before: "\(st?.size ?? 0)-\(st?.mtime ?? 0)",
                                         note: ["state": "running", "isDir": m.isDir, "from": m.from, "to": m.to, "docs": docs])
            moveSeq.append(seq)
        }
        var rmdirSeq = 0
        if let mf = mergeFrom {
            seq += 1; rmdirSeq = seq
            logged = logged && opsInsert(batch, seq, "tidy-rmdir", from: mf.raw, to: TidyFS.rawPath(targetDir), note: ["state": "planned"])
        }
        // 옮기는 폴더 안의 색인 제외 폴더는 새 위치로 따라간다 (옛 줄은 빼고 새 위치를 덮는 출처에 더한다)
        var exMoves: [(seq: Int, fromSid: String, fromRel: String, toSid: String, toRel: String)] = []
        for m in moves where m.isDir {
            for src in sources {
                for e in src.excludes {
                    let abs = src.root + "/" + e
                    guard abs == m.from || abs.hasPrefix(m.from + "/") else { continue }
                    let na = m.to + String(abs.dropFirst(m.from.count))
                    guard let t = source(covering: na, sources), let nr = t.rel(na), !nr.isEmpty else { continue }
                    seq += 1
                    logged = logged && opsInsert(batch, seq, "tidy-exclude-move", from: abs, to: na,
                                                 note: ["fromSource": src.id, "fromRel": e, "toSource": t.id, "toRel": nr, "state": "planned"])
                    exMoves.append((seq, src.id, e, t.id, nr))
                }
            }
        }
        struct Edit { let seq: Int; let path: String; let edit: TidyLinkEdit; let mtime: Double? }
        var edits: [Edit] = []
        if plan.needsRewrite, let v = plan.vault {
            let dir = organizer.movesBackupRoot.appendingPathComponent(batch)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for e in plan.edits {
                seq += 1
                let origRaw = TidyFS.rawPath(v + "/" + e.rel)
                var newRaw = origRaw
                if e.moved, let m = moves.first(where: { origRaw == $0.srcRaw || origRaw.hasPrefix($0.srcRaw + "/") }) {
                    newRaw = m.dstRaw + String(origRaw.dropFirst(m.srcRaw.count))
                }
                let bpath = dir.appendingPathComponent("\(seq)-" + Organizer.fileName(e.rel)).path
                let perms = (try? fm.attributesOfItem(atPath: origRaw)[.posixPermissions] as? NSNumber)?.int16Value ?? 0o600
                let mt = TidyFS.info(origRaw)?.mtime
                guard fm.createFile(atPath: bpath, contents: e.original, attributes: [.posixPermissions: perms]),
                      opsInsert(batch, seq, "tidy-rewrite", from: newRaw, to: newRaw, backup: bpath, before: Organizer.sha1(e.original),
                                note: ["moved": e.moved, "mtime": mt ?? 0])
                else { logged = false; break }
                edits.append(Edit(seq: seq, path: newRaw, edit: e, mtime: e.moved ? mt : nil))
            }
        }
        if !logged { opsDrop(batch); return failed(s, "기록을 남기지 못해 옮기지 않았어요") }
        // 실행
        var failure: String? = nil
        for d in mkdirs where failure == nil {
            if d.withCString({ mkdir($0, 0o755) }) != 0 && !TidyFS.isDir(d) { failure = "폴더를 만들지 못했어요: 권한을 확인해 주세요" }
        }
        var movedCount = 0
        for (k, m) in moves.enumerated() where failure == nil {
            do { try renameItem(m.srcRaw, m.dstRaw) } catch { failure = (error as? LibraryError)?.message ?? "옮기지 못했어요"; break }
            opsNote(batch, moveSeq[k], ["state": "done", "isDir": m.isDir, "from": m.from, "to": m.to, "docs": docPairs[k]])
            movedCount += 1
        }
        var leftover = false
        if failure == nil, let mf = mergeFrom {
            let rest = TidyFS.entries(mf.raw)
            if rest.allSatisfy({ $0.name == ".DS_Store" }) {
                if rest.contains(where: { $0.name == ".DS_Store" }) { _ = (mf.raw + "/.DS_Store").withCString { unlink($0) } }
                if mf.raw.withCString({ rmdir($0) }) == 0 { opsNote(batch, rmdirSeq, ["state": "done"]) } else { opsDone(batch, seq: rmdirSeq); leftover = true }
            } else { opsDone(batch, seq: rmdirSeq); leftover = true }
        }
        if failure == nil {
            for x in exMoves {
                let a = ctx.updateSourceExcludes(x.toSid, [x.toRel], [])
                let b = a == nil ? ctx.updateSourceExcludes(x.fromSid, [], [x.fromRel]) : a
                if a == nil && b == nil {
                    opsNote(batch, x.seq, ["fromSource": x.fromSid, "fromRel": x.fromRel, "toSource": x.toSid, "toRel": x.toRel, "state": "done"])
                } else { opsDone(batch, seq: x.seq) }
            }
        }
        var written: [String] = moves.flatMap { [$0.from, $0.to] }
        if failure == nil {
            Tidy.testBeforeRewrite?()
            for e in edits {
                guard let cur = fm.contents(atPath: e.path), cur == e.edit.original else {
                    failure = "링크를 고치는 사이에 \(Organizer.fileName(e.edit.rel)) 파일이 바뀌어 되돌렸어요"; break
                }
                var text = e.edit.newText
                if Tidy.testBreakRewrite { text = text.replacingOccurrences(of: Organizer.parent(e.edit.newRel), with: "없는-폴더") }
                let data = Data(text.utf8)
                opsAfter(batch, e.seq, Organizer.sha1(data))
                do { try organizer.atomicWrite(e.path, data, mtime: e.mtime) } catch { failure = "링크를 고쳐 쓰지 못해 되돌렸어요"; break }
                written.append(Indexer.nfc(e.path))
            }
        }
        if failure == nil && plan.vault != nil && unresolvedNow(plan) > plan.unresolvedBefore { failure = "링크가 깨질 뻔해서 되돌렸어요" }
        if let reason = failure {
            let rv = revertBatch(batch, strict: false)
            let tail = rv.conflicts.isEmpty ? "" : " · 충돌 \(rv.conflicts.count)건은 그대로 두었어요"
            ctx.log("rollback", reason + ": " + s.item.title + tail, origin: logOrigin(s), ref: s.id, batch: batch)
            invalidate()
            ctx.emit(.tidy); ctx.emit(.log)
            let conf = rv.conflicts.map { ["title": Organizer.fileName(($0["path"] as? String) ?? ""), "reason": ($0["reason"] as? String) ?? ""] as [String: Any] }
            return failed(s, reason, batch: batch, skipped: skipped + conf)
        }
        // 알림
        ctx.onSynapseWrite(written.map(Indexer.nfc))
        for pairs in docPairs { for p in pairs where p.count == 4 { ctx.onDocMoved(p[0], p[1], p[2], p[3]) } }
        var extra: [String: Any] = ["auto": auto, "human": !auto, "impact": ["files": s.snap.reduce(0) { $0 + $1.files }, "links": plan.links, "warnings": plan.warnings]]
        if leftover { extra["leftover"] = true }
        setState(s.id, "applied", batch: batch, extra: extra)
        withdrawOverlapping(paths: i.from, except: s.id)
        let verb = i.op == TidyOp.archive ? "보관했어요" : i.op == TidyOp.merge ? "합쳤어요" : "옮겼어요"
        let toLabel = label(for: i.op == TidyOp.archive ? (moves.first?.to ?? targetDir) : targetDir, vm: vm, sources: sources, codeFolder: code)
        let fromLabel = i.from.map { (($0 as NSString).lastPathComponent) }.joined(separator: ", ")
        var text = (auto ? "자동 정리 · " : "") + "\(verb): \(fromLabel) → \(toLabel)"
        if plan.links > 0 { text += " · 링크 \(plan.links)개 고침" }
        if !skipped.isEmpty { text += " · 건너뜀 \(skipped.count)" }
        if leftover { text += " · 숨김 파일이 남아 원래 폴더는 그대로 두었어요" }
        ctx.log("apply", text, origin: logOrigin(s), ref: s.id, batch: batch)
        invalidate()
        ctx.emit(.tidy); ctx.emit(.pending); ctx.emit(.log)
        return TidyApplyResult(ok: true, batchId: batch, done: movedCount, skipped: skipped, error: nil)
    }

    /// 옮긴 자리와 겹치는 다른 대기 제안은 더는 맞지 않는다.
    func withdrawOverlapping(paths: [String], except id: String) {
        for o in sugs("state IN ('pending','later') AND id<>?", [.text(id)]) {
            let hit = o.item.from.contains { f in paths.contains { f == $0 || f.hasPrefix($0 + "/") || $0.hasPrefix(f + "/") } }
            if hit { setState(o.id, "withdrawn", error: "자리가 바뀌었어요") }
        }
    }

    // MARK: exclude

    private func applyExclude(_ s: TidySug, batch: String, auto: Bool, vm: VaultMap, sources: [TidySource], code: String?) -> TidyApplyResult {
        guard let f = s.item.from.first else { return failed(s, "대상이 없어요") }
        if let p = fromProblem(f, op: TidyOp.exclude, vm: vm, sources: sources, code: code) { return failed(s, p) }
        guard TidyFS.isDir(TidyFS.rawPath(f)) else { return failed(s, "색인에서 빼기는 폴더만 해요") }
        guard let src = source(covering: f, sources), let rel = src.rel(f), !rel.isEmpty else { return failed(s, "이 폴더를 색인하는 출처가 없어요") }
        if src.isExcluded(f) {
            setState(s.id, "withdrawn", error: "이미 색인에서 빠져 있어요", clearBatch: true)
            return TidyApplyResult(ok: true, batchId: nil, done: 0, skipped: [["title": s.item.title, "reason": "이미 색인에서 빠져 있어요"]])
        }
        guard opsInsert(batch, 1, "tidy-exclude", from: f, to: src.id, note: ["sourceId": src.id, "rel": rel]) else {
            return failed(s, "기록을 남기지 못해 바꾸지 않았어요")
        }
        if let err = ctx.updateSourceExcludes(src.id, [rel], []) {
            opsDrop(batch)
            return failed(s, err)
        }
        setState(s.id, "applied", batch: batch, extra: ["auto": auto, "human": !auto])
        ctx.log("apply", (auto ? "자동 정리 · " : "") + "색인에서 뺐어요: \(label(for: f, vm: vm, sources: sources, codeFolder: code)) · 파일은 그대로",
                origin: logOrigin(s), ref: s.id, batch: batch)
        invalidate()
        ctx.emit(.tidy); ctx.emit(.pending); ctx.emit(.log)
        return TidyApplyResult(ok: true, batchId: batch, done: 1)
    }

    // MARK: trash (Synapse 휴지통, 파일만)

    private func applyTrash(_ s: TidySug, batch: String, auto: Bool, vm: VaultMap, sources: [TidySource], code: String?) -> TidyApplyResult {
        if auto { return failed(s, "휴지통은 자동으로 보내지 않아요") }
        struct Plan { let raw: String; let nfc: String; let src: TidySource; let rel: String; let info: TidyFS.Info; let dst: String; let tid: String; let docId: String }
        let base = organizer.trashRoot.appendingPathComponent(batch).path
        let fm = FileManager.default
        let open = ctx.obsidianOpenPaths().map(Indexer.nfc)
        // 1) 실행 전에 모든 대상을 검사한다 (출처·파일·장치·옵시디언)
        var plans: [Plan] = []
        for f in s.item.from {
            if let p = fromProblem(f, op: TidyOp.trash, vm: vm, sources: sources, code: code) { return failed(s, p) }
            let raw = TidyFS.rawPath(f)
            guard let info = TidyFS.info(raw) else { return failed(s, "원본이 없어요") }
            if info.isDir { return failed(s, "폴더는 휴지통으로 보내지 않아요 · 안의 파일을 골라 주세요") }
            guard info.isFile else { return failed(s, "파일이 아니라서 보내지 않아요") }
            guard let src = source(covering: f, sources), let rel = src.rel(f), !rel.isEmpty else { return failed(s, "출처 밖 파일은 휴지통으로 보내지 않아요") }
            if open.contains(f) { return failed(s, "옵시디언에서 열려 있어요") }
            let relDirRaw = (String(raw.dropFirst(TidyFS.rawPath(src.root).count + 1)) as NSString).deletingLastPathComponent
            let dstDir = relDirRaw.isEmpty ? base : base + "/" + relDirRaw
            let dst = dstDir + "/" + (raw as NSString).lastPathComponent
            if plans.contains(where: { $0.dst == dst }) { return failed(s, "같은 이름 파일이 겹쳐요") }
            plans.append(Plan(raw: raw, nfc: f, src: src, rel: rel, info: info, dst: dst, tid: "t:" + TidyHash.short(f + "\n" + UUID().uuidString),
                              docId: ctx.doc(path: f)?.id ?? (src.id + ":" + rel)))
        }
        for p in plans {
            let dir = (p.dst as NSString).deletingLastPathComponent
            do { try fm.createDirectory(atPath: dir, withIntermediateDirectories: true) } catch { return failed(s, "Synapse 휴지통 폴더를 만들지 못했어요") }
            if TidyFS.device(near: dir) != p.info.dev { return failed(s, "다른 디스크라 휴지통으로 보내지 않았어요") }
        }
        // 2) 기록 먼저 (모두)
        for (k, p) in plans.enumerated() {
            let note: [String: Any] = ["trashId": p.tid, "state": "running", "docId": p.docId]
            guard opsInsert(batch, k + 1, "tidy-trash", from: p.raw, to: p.dst, before: "\(p.info.size)-\(p.info.mtime)", note: note),
                  insertTrashItem(id: p.tid, batch: batch, docId: p.docId, src: p.src, rel: p.rel, orig: p.raw, trash: p.dst, size: p.info.size,
                                  origin: logOrigin(s), reason: s.item.reason)
            else {
                opsDrop(batch)
                _ = try? ctx.db.sql.run("UPDATE trash_items SET state='cancelled', done=? WHERE batch_id=? AND state='pending'", [.double(nowTS), .text(batch)])
                return failed(s, "기록을 남기지 못해 보내지 않았어요")
            }
        }
        // 3) 실행. 중간에 실패하면 앞서 보낸 것을 되돌린다
        var written: [String] = []
        for (k, p) in plans.enumerated() {
            do { try renameItem(p.raw, p.dst) } catch {
                _ = try? ctx.db.sql.run("UPDATE trash_items SET state='cancelled', done=? WHERE batch_id=? AND state='pending'", [.double(nowTS), .text(batch)])
                let rv = revertBatch(batch, strict: false)
                ctx.log("rollback", "휴지통으로 보내다 멈춰 되돌렸어요: \(s.item.title)" + (rv.conflicts.isEmpty ? "" : " · 충돌 \(rv.conflicts.count)건"),
                        origin: logOrigin(s), ref: s.id, batch: batch)
                return failed(s, (error as? LibraryError)?.message ?? "보내지 못했어요", batch: batch)
            }
            _ = try? ctx.db.sql.run("UPDATE trash_items SET state='trashed' WHERE id=?", [.text(p.tid)])
            opsNote(batch, k + 1, ["trashId": p.tid, "state": "done", "docId": p.docId])
            written.append(p.nfc)
        }
        ctx.onSynapseWrite(written)
        setState(s.id, "applied", batch: batch, extra: ["auto": false, "human": true])
        let what = plans.map { ($0.nfc as NSString).lastPathComponent }.joined(separator: ", ")
        ctx.log("trash", "정리 승인 · 휴지통으로 보냈어요: \(what) · 30일 보관", origin: logOrigin(s), ref: s.id, batch: batch)
        invalidate()
        ctx.emit(.tidy); ctx.emit(.pending); ctx.emit(.log); ctx.emit(.home)
        return TidyApplyResult(ok: true, batchId: batch, done: plans.count)
    }

    private func insertTrashItem(id: String, batch: String, docId: String, src: TidySource, rel: String, orig: String, trash: String,
                                 size: Int, origin: String, reason: String) -> Bool {
        (try? ctx.db.sql.run("""
            INSERT INTO trash_items(id, batch_id, doc_id, source_id, rel_path, title, orig_path, trash_path, size, hash, copied,
              deleted, expires, origin, via, reason, inbound, state) VALUES(?,?,?,?,?,?,?,?,?,?,0,?,?,?,'approved',?,0,'pending')
            """, [.text(id), .text(batch), .text(docId), .text(src.id), .text(rel), .text((rel as NSString).lastPathComponent),
                  .text(orig), .text(trash), .int(Int64(size)), .text(size <= 4096 ? Organizer.fileHash(orig) : ""),
                  .double(nowTS), .double(nowTS + Organizer.trashDays * 86400), .text(origin), .text(String(reason.prefix(200)))])) != nil
    }

    // MARK: 되돌리기

    private struct OpRow { let id: Int64; let seq: Int; let op: String; let from: String; let to: String; let backup: String?; let before: String; let after: String?; let note: [String: Any] }

    private func opRows(_ batch: String) -> [OpRow] {
        var out: [OpRow] = []
        try? ctx.db.sql.query("""
            SELECT id, seq, op, from_path, to_path, backup_path, before_hash, after_hash, note FROM ops_log
            WHERE batch_id=? AND undone=0 AND op LIKE 'tidy-%' ORDER BY seq DESC
            """, [.text(batch)]) { r in
            out.append(OpRow(id: r.int(0), seq: Int(r.int(1)), op: r.text(2), from: r.text(3), to: r.text(4), backup: r.isNull(5) ? nil : r.text(5),
                             before: r.text(6), after: r.isNull(7) ? nil : r.text(7), note: (BrainFormat.parse(r.text(8)) as? [String: Any]) ?? [:]))
        }
        return out
    }

    /// 배치를 거꾸로 되돌린다. strict면 먼저 모두 검사하고, 충돌이 하나라도 있으면 아무것도 하지 않는다.
    func revertBatch(_ batch: String, strict: Bool) -> (undone: Int, conflicts: [[String: Any]]) {
        let rows = opRows(batch)
        let fm = FileManager.default
        func done(_ id: Int64) { _ = try? ctx.db.sql.run("UPDATE ops_log SET undone=1 WHERE id=?", [.int(id)]) }
        enum Plan { case restore, skip, conflict }
        var plans: [Int64: Plan] = [:]
        var conflicts: [[String: Any]] = []
        var blocked: [String] = []
        for o in rows where o.op == "tidy-rewrite" {
            guard let after = o.after else { plans[o.id] = .skip; continue }
            let h = fm.contents(atPath: o.from).map { Organizer.sha1($0) }
            if h == after, o.backup.flatMap({ fm.contents(atPath: $0) }) != nil { plans[o.id] = .restore }
            else if h == o.before { plans[o.id] = .skip }
            else {
                plans[o.id] = .conflict
                conflicts.append(["path": Indexer.nfc(o.from), "reason": h == nil ? "고친 파일이 없어요" : "옮긴 뒤에 내용이 바뀌어 되돌리지 않았어요"])
                if (o.note["moved"] as? Bool) == true { blocked.append(o.from) }
            }
        }
        for o in rows where o.op == "tidy-move" {
            let st = (o.note["state"] as? String) ?? "done"
            if st != "done" && !TidyFS.exists(o.to) { plans[o.id] = .skip; continue }
            var why: String? = nil
            if blocked.contains(where: { $0 == o.to || $0.hasPrefix(o.to + "/") }) { why = "옮긴 파일이 바뀌어 제자리로 돌리지 않았어요" }
            else if TidyFS.exists(o.from) { why = "원래 자리에 같은 이름이 있어요" }
            else if !TidyFS.exists(o.to) { why = "옮긴 항목이 없어요" }
            if let w = why { plans[o.id] = .conflict; conflicts.append(["path": Indexer.nfc(o.from), "reason": w]) } else { plans[o.id] = .restore }
        }
        if strict && !conflicts.isEmpty { return (0, conflicts) }
        var undone = 0
        var written: [String] = []
        for o in rows {
            switch o.op {
            case "tidy-rewrite":
                guard case .restore? = plans[o.id] else { if case .skip? = plans[o.id] { done(o.id) }; continue }
                guard let b = o.backup, let orig = fm.contents(atPath: b) else { continue }
                let mt = (o.note["mtime"] as? Double).flatMap { $0 > 0 ? $0 : nil }
                do { try organizer.atomicWrite(o.from, orig, mtime: mt); undone += 1; done(o.id); written.append(Indexer.nfc(o.from)) }
                catch { conflicts.append(["path": Indexer.nfc(o.from), "reason": "되돌려 쓰지 못했어요"]) }
            case "tidy-rmdir":
                if (o.note["state"] as? String) == "done" && !TidyFS.exists(o.from) {
                    if o.from.withCString({ mkdir($0, 0o755) }) != 0 { conflicts.append(["path": Indexer.nfc(o.from), "reason": "원래 폴더를 다시 만들지 못했어요"]); continue }
                    undone += 1
                }
                done(o.id)
            case "tidy-move":
                guard case .restore? = plans[o.id] else { if case .skip? = plans[o.id] { done(o.id) }; continue }
                do { try Organizer.renameExact(o.to, o.from) } catch { conflicts.append(["path": Indexer.nfc(o.to), "reason": "제자리로 옮기지 못했어요"]); continue }
                undone += 1; done(o.id); written += [Indexer.nfc(o.to), Indexer.nfc(o.from)]
                for p in (o.note["docs"] as? [[String]]) ?? [] where p.count == 4 { ctx.onDocMoved(p[1], p[0], p[3], p[2]) }
            case "tidy-mkdir":
                if TidyFS.isDir(o.from) {
                    let rest = TidyFS.entries(o.from)
                    if rest.allSatisfy({ $0.name == ".DS_Store" }) {
                        if !rest.isEmpty { _ = (o.from + "/.DS_Store").withCString { unlink($0) } }
                        _ = o.from.withCString { rmdir($0) }
                    }
                }
                done(o.id)
            case "tidy-exclude-move":
                if (o.note["state"] as? String) == "done" {
                    let fs = (o.note["fromSource"] as? String) ?? "", fr = (o.note["fromRel"] as? String) ?? ""
                    let ts = (o.note["toSource"] as? String) ?? "", tr = (o.note["toRel"] as? String) ?? ""
                    if let err = ctx.updateSourceExcludes(fs, [fr], []) ?? ctx.updateSourceExcludes(ts, [], [tr]) {
                        conflicts.append(["path": Indexer.nfc(o.from), "reason": err]); continue
                    }
                    undone += 1
                }
                done(o.id)
            case "tidy-exclude":
                let sid = (o.note["sourceId"] as? String) ?? o.to, rel = (o.note["rel"] as? String) ?? ""
                if let err = ctx.updateSourceExcludes(sid, [], [rel]) { conflicts.append(["path": Indexer.nfc(o.from), "reason": err]); continue }
                undone += 1; done(o.id)
            case "tidy-trash":
                let tid = (o.note["trashId"] as? String) ?? ""
                if (o.note["state"] as? String) != "done" && !TidyFS.exists(o.to) { done(o.id); continue }
                let r = organizer.restoreTrash(ids: [tid], batch: nil, logUndo: true)
                let restored = ((r["restored"] as? [Any]) ?? []).count
                if restored > 0 { undone += 1; done(o.id); written.append(Indexer.nfc(o.from)) }
                else if let f = (r["failed"] as? [[String: Any]])?.first { conflicts.append(["path": Indexer.nfc(o.from), "reason": (f["reason"] as? String) ?? "되살리지 못했어요"]) }
                else { done(o.id) }      // 이미 되살렸다
            default:
                done(o.id)
            }
        }
        if !written.isEmpty { ctx.onSynapseWrite(written) }
        return (undone, conflicts)
    }

    func hasOpenTidyRows(_ batch: String) -> Bool {
        var hit = false
        try? ctx.db.sql.query("SELECT 1 FROM ops_log WHERE batch_id=? AND op LIKE 'tidy-%' AND undone=0 LIMIT 1", [.text(batch)]) { _ in hit = true }
        return hit
    }

    func undo(batchId: String?) -> [String: Any] {
        if ctx.isStopped { return ["ok": false, "error": "사서가 멈춰 있어서 되돌리지 않았어요. 다시 시작한 뒤 해 주세요."] }
        guard let b = batchId ?? lastBatch() else { return ["ok": false, "error": "되돌릴 정리가 없어요."] }
        if !hasOpenTidyRows(b) {
            // 기존 휴지통 배치도 "t" + 날짜라 Brain이 여기로 보낸다 — 기존 정리 되돌리기로 넘긴다
            if organizer.isTrashBatch(b) { return organizer.undo(batchId: b) }
            return ["ok": false, "error": "이미 되돌렸거나 없는 정리예요."]
        }
        var first = 0.0
        try? ctx.db.sql.query("SELECT min(ts) FROM ops_log WHERE batch_id=?", [.text(b)]) { first = $0.double(0) }
        if nowTS - first > 30 * 86400 { return ["ok": false, "error": "30일이 지나 되돌릴 수 없어요."] }
        let r = revertBatch(b, strict: true)
        let applied = sugs("batch_id=? AND state='applied'", [.text(b)])
        let what = applied.first?.item.title ?? b
        if !r.conflicts.isEmpty && r.undone == 0 {
            ctx.log("undo", "되돌리지 않았어요: \(what) · 충돌 \(r.conflicts.count)건", origin: "user", batch: b)
            ctx.emit(.log)
            return ["ok": false, "error": "되돌리면 다른 변경과 부딪혀요 (\(r.conflicts.count)건). 아무것도 바꾸지 않았어요.", "undone": 0, "conflicts": r.conflicts]
        }
        for s in applied { setState(s.id, "undone") }
        ctx.log("undo", "되돌렸어요: " + what + (r.conflicts.isEmpty ? "" : " · 충돌 \(r.conflicts.count)건"), origin: "user", batch: b)
        invalidate()
        ctx.emit(.tidy); ctx.emit(.pending); ctx.emit(.log)
        return ["ok": true, "undone": r.undone, "conflicts": r.conflicts, "batchId": b]
    }

    func lastBatch() -> String? {
        var b: String? = nil
        try? ctx.db.sql.query("SELECT batch_id FROM ops_log WHERE op LIKE 'tidy-%' AND undone=0 ORDER BY ts DESC, id DESC LIMIT 1") { b = $0.text(0) }
        return b
    }
}
