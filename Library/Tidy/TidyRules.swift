import Foundation

// v0.9 정리 규칙·Claude 결과 받기·자동 적용·배우기 (docs/V09.md §4.2·§4.4·§4.7·§5).
// 규칙은 결정적이다(Claude 없이). 같은 자리에는 규칙 제안 하나만(우선순위: 비밀 알림 > 티켓 파일 > 합치기 > 새 티켓 폴더 > 코드 > 보관 > 빈 파일 > 원자료).

/// 만들 제안 하나 (저장 전).
struct TidyCand {
    var item: TidyItem
    var stamps: [TidyStamp]?          // nil이면 저장할 때 잰다
    var flags: [String]
    var zone: String?
    var docId: String?
    var key: String { TidySug.key(item) }
}

extension Tidy {

    // MARK: 규칙

    func ruleCandidates(_ inv: TidyInventory) -> [TidyCand] {
        let jira = jiraStates()
        let code = codeFolderResolved()
        let now = nowTS
        var out: [TidyCand] = []
        var used = Set<String>()
        func off(_ sig: String) -> Bool { ruleState(sig) == "off" }
        func ws(_ v: String, _ k: String) -> String? {
            let p = v + "/_workspace/" + k
            return TidyFS.isDir(TidyFS.rawPath(p)) ? p : nil
        }
        func wsAny(_ k: String, prefer: String?) -> String? {
            if let v = prefer, let w = ws(v, k) { return w }
            for v in inv.vaults { if let w = ws(v, k) { return w } }
            return nil
        }
        func add(_ p: TidyPlace, _ op: String, _ to: String?, _ title: String, _ reason: String, _ ev: [String], _ cert: String, _ group: String, _ sig: String) {
            if [TidyOp.move, TidyOp.merge, TidyOp.archive].contains(op) {
                // 목적지가 링크를 지나거나, 다 세지 못했거나, 안에 비밀 파일이 있으면 옮기기 제안을 만들지 않는다
                if let t = to, normalizeDest(t) != t { return }
                if p.flags.contains(TidyFlag.truncated) { return }
                if p.isDir && secretProblem(p.path) != nil { return }
            }
            let info = placeInfo[p.path]
            out.append(TidyCand(item: TidyItem(op: op, from: [p.path], to: to, title: TidyText.clip(title, 40), reason: TidyText.clip(reason, 120),
                                               evidence: ev.map { TidyText.clip($0, 40) }, certainty: cert, origin: "rule", group: group, signature: sig),
                                stamps: info.map { [$0.stamp] }, flags: p.flags.sorted(), zone: p.zone.rawValue, docId: p.docIds.first))
            used.insert(p.path)
        }
        let places = inv.places.filter { !$0.flags.contains(TidyFlag.vault) && !(placeInfo[$0.path]?.containsRoot ?? false) }
        let blockMove: Set<String> = [TidyFlag.secret, TidyFlag.frozen, TidyFlag.hidden]
        func zoneLabel(_ p: TidyPlace) -> String {
            switch p.zone {
            case .loose: return p.label.components(separatedBy: " › ").first ?? "데스크톱"
            case .inbox: return "받은 문서함"
            case .vaultRoot: return "볼트 루트"
            default: return p.label.components(separatedBy: " › ").first ?? ""
            }
        }
        // 비밀 알림
        if !off(TidyRule.secret) {
            for p in places where p.flags.contains(TidyFlag.secret) {
                add(p, TidyOp.note, nil, "비밀 값 파일 확인", "비밀 값 파일이 \(zoneLabel(p))에 있어요. 필요한 프로젝트로 옮기거나 지워 주세요",
                    ["비밀 값 파일(내용은 읽지 않아요)"], TidyCertainty.certain, TidyGroup.check, TidyRule.secret)
            }
        }
        // 티켓 번호 파일 → 티켓 폴더
        if !off(TidyRule.ticketFile) {
            for p in places where !p.isDir && p.zone.isUnfiled && !used.contains(p.path) && p.flags.isDisjoint(with: blockMove) {
                for k in placeInfo[p.path]?.nameKeys ?? [] {
                    guard let w = wsAny(k, prefer: p.vaultRoot) else { continue }
                    add(p, TidyOp.move, w, "\(k) 파일을 티켓 폴더로", "파일 이름에 \(k)가 있고 그 티켓 폴더가 있어요",
                        ["파일 이름에 \(k)", "_workspace/\(k) 있음"], TidyCertainty.certain, TidyGroup.tickets, TidyRule.ticketFile)
                    break
                }
            }
        }
        // 작업 공간 티켓 폴더
        var wsPlaces: [String: TidyPlace] = [:]
        for p in inv.places where p.zone == .workspace && p.isDir {
            let k = TidyNames.isKey(p.name) ? p.name : (p.ticketKeys.first ?? "")
            if !k.isEmpty && wsPlaces[k] == nil { wsPlaces[k] = p }
        }
        let codeFlags: Set<String> = [TidyFlag.code, TidyFlag.git]
        // 갈라진 티켓 산출물 합치기
        if !off(TidyRule.split) {
            for p in places where (p.zone == .loose || p.zone == .inbox) && !used.contains(p.path) && p.flags.isDisjoint(with: blockMove.union(codeFlags)) {
                // 파일은 문서에 나온 키가 하나뿐일 때만 (여러 티켓을 언급한 문서는 애매하다)
                if !p.isDir && p.ticketKeys.count != 1 && (placeInfo[p.path]?.nameKeys ?? []).isEmpty { continue }
                for k in p.ticketKeys {
                    guard let w = wsPlaces[k] else { continue }
                    add(p, p.isDir ? TidyOp.merge : TidyOp.move, w.path, "\(k) 산출물 합치기",
                        "같은 티켓(\(k)) 산출물이 \(zoneLabel(p))와 _workspace/\(k)에 나뉘어 있어요",
                        [p.isDir ? "안쪽 문서 다수가 \(k)" : "문서에 \(k)", "_workspace/\(k) 있음"], TidyCertainty.likely, TidyGroup.tickets, TidyRule.split)
                    break
                }
            }
        }
        // 새 티켓 폴더
        if !off(TidyRule.ticketNew), let defVault = inv.vaults.first {
            for p in places where (p.zone == .loose || p.zone == .inbox) && !used.contains(p.path) && p.flags.isDisjoint(with: blockMove.union(codeFlags)) {
                let nameKeys = placeInfo[p.path]?.nameKeys ?? []
                guard let k = p.isDir ? (nameKeys.first ?? p.ticketKeys.first) : nameKeys.first, wsAny(k, prefer: p.vaultRoot) == nil else { continue }
                let v = p.vaultRoot ?? defVault
                add(p, TidyOp.move, v + "/_workspace/" + k, "\(k) 폴더 만들어 옮기기", "\(k) 산출물인데 티켓 폴더가 아직 없어요",
                    [nameKeys.contains(k) ? "이름에 \(k)" : "안쪽 문서 다수가 \(k)", "_workspace/\(k) 없음"], TidyCertainty.likely, TidyGroup.tickets, TidyRule.ticketNew)
            }
        }
        // 코드 폴더
        if !off(TidyRule.code), let c = code {
            for p in places where p.zone == .loose && p.isDir && !used.contains(p.path) && !p.flags.isDisjoint(with: codeFlags)
                && !p.flags.contains(TidyFlag.secret) && !(placeInfo[p.path]?.secretDeep ?? false) && !c.hasPrefix(p.path + "/") {
                add(p, TidyOp.move, c, "\(p.name) 코드 폴더로", "코드 저장소는 코드 폴더에 두면 찾기 쉬워요",
                    [p.flags.contains(TidyFlag.git) ? ".git 있음" : "코드 표지 파일 있음", "코드 폴더 " + (c as NSString).lastPathComponent], TidyCertainty.likely,
                    TidyGroup.desktop, TidyRule.code)
            }
        }
        // 30일 넘은 프로젝트 보관
        if !off(TidyRule.staleProject) {
            for p in places where p.zone == .project && !used.contains(p.path) && now - p.lastModified > 30 * 86400
                && p.flags.isDisjoint(with: blockMove.union(codeFlags)) && !(placeInfo[p.path]?.containsFrozen ?? false)
                && !(placeInfo[p.path]?.secretDeep ?? false) {
                guard let v = p.vaultRoot else { continue }
                let open = p.ticketKeys.filter { k in jira[k].map { $0.category != "done" } ?? false }
                guard open.isEmpty else { continue }
                let days = Int((now - p.lastModified) / 86400)
                add(p, TidyOp.archive, v + "/4-Archive", "\(p.name) 보관하기", "\(days)일 동안 손대지 않은 프로젝트예요. 1-Projects에는 지금 하는 것만 둬요",
                    ["\(days)일 그대로", "열린 티켓 없음"], TidyCertainty.likely, TidyGroup.archive, TidyRule.staleProject)
            }
        }
        // 끝난 티켓 폴더 보관
        if !off(TidyRule.doneWorkspace) {
            for p in places where p.zone == .workspace && p.isDir && !used.contains(p.path) && now - p.lastModified > 14 * 86400
                && p.flags.isDisjoint(with: blockMove.union(codeFlags)) && !(placeInfo[p.path]?.containsFrozen ?? false)
                && !(placeInfo[p.path]?.secretDeep ?? false) {
                guard let v = p.vaultRoot else { continue }
                let k = TidyNames.isKey(p.name) ? p.name : (p.ticketKeys.first ?? "")
                guard !k.isEmpty, let j = jira[k], j.category == "done" else { continue }
                add(p, TidyOp.archive, v + "/4-Archive/_workspace", "끝난 \(k) 폴더 보관", "\(k)가 끝났고 \(Int((now - p.lastModified) / 86400))일 동안 그대로예요",
                    ["\(k) 상태 \(j.status.isEmpty ? "완료" : j.status)", "\(Int((now - p.lastModified) / 86400))일 그대로"], TidyCertainty.likely, TidyGroup.archive, TidyRule.doneWorkspace)
            }
        }
        // 빈 파일 → 휴지통 (승인만)
        if !off(TidyRule.empty) {
            for p in places where !p.isDir && p.flags.contains(TidyFlag.empty) && !used.contains(p.path) && p.sourceId != nil
                && p.flags.isDisjoint(with: blockMove) {
                add(p, TidyOp.trash, nil, "빈 파일 \(p.name) 휴지통으로", "내용이 없는 파일이에요(\(p.size)바이트). Synapse 휴지통에 30일 보관해요",
                    ["\(p.size)바이트", zoneLabel(p)], TidyCertainty.likely, TidyGroup.check, TidyRule.empty)
            }
        }
        // 원자료 → 색인에서 빼기
        if !off(TidyRule.raw) {
            var seenRaw = Set<String>()
            for p in places {      // 옮기기 제안이 있는 자리여도 색인 제외는 따로 (파일을 건드리지 않는다)
                for r in p.raw where seenRaw.insert(r.path).inserted {
                    let top = r.kinds.sorted { $0.value > $1.value }.prefix(2).map { ($0.key.isEmpty ? "확장자 없음" : $0.key) + " \($0.value)" }.joined(separator: " · ")
                    out.append(TidyCand(item: TidyItem(op: TidyOp.exclude, from: [r.path], to: nil,
                                                       title: TidyText.clip("\((r.path as NSString).lastPathComponent) 색인에서 빼기", 40),
                                                       reason: TidyText.clip("원자료 파일 \(r.files)개가 모인 폴더예요. 파일은 그대로 두고 검색·지도에서만 빼요", 120),
                                                       evidence: ["\(r.files)개 · \(top)", r.certain ? "원자료 이름" : "기계적인 파일 이름"].map { TidyText.clip($0, 40) },
                                                       certainty: r.certain ? TidyCertainty.certain : TidyCertainty.likely, origin: "rule",
                                                       group: TidyGroup.index, signature: TidyRule.raw),
                                        stamps: nil, flags: r.path == p.path ? p.flags.sorted() : [], zone: p.zone.rawValue, docId: nil))
                }
            }
        }
        return out
    }

    // MARK: 저장 (겹침·30일 거절·대기 중복 제외)

    /// 같은 열쇠의 기존 행이 새로 만들기를 막는가. (막지 않지만 자동은 안 되는 경우는 noAuto)
    private func blocks(_ e: TidySug, snapHash: String?) -> (block: Bool, noAuto: Bool) {
        let recent = (e.decided ?? e.created) >= nowTS - 30 * 86400
        switch e.state {
        case "pending", "later", "applying": return (true, false)
        case "rejected", "dismissed", "applied": return (recent, false)
        case "failed": return (recent && snapHash != nil && (e.extra["snapHash"] as? String) == snapHash, false)
        case "undone": return (false, recent)
        default: return (false, false)
        }
    }

    private func snapHash(_ stamps: [TidyStamp]) -> String {
        TidyHash.short(stamps.map { "\($0.path)|\($0.files)|\($0.size)|\($0.mtime)" }.joined(separator: "\n"))
    }

    /// 후보를 저장한다. 만들었으면 id.
    @discardableResult
    func insert(_ c: TidyCand, existing: [TidySug], run: String?, vm: VaultMap) -> String? {
        var stamps = c.stamps ?? []
        if c.stamps == nil || stamps.contains(where: { $0.path.isEmpty }) { stamps = c.item.from.compactMap { stamp($0) } }
        guard stamps.count == c.item.from.count else { return nil }
        let sh = snapHash(stamps)
        var noAuto = false
        for e in existing where e.key == c.key {
            let b = blocks(e, snapHash: sh)
            if b.block { return nil }
            if b.noAuto { noAuto = true }
        }
        var extra: [String: Any] = ["snap": stamps.map { $0.json }, "snapHash": sh, "flags": c.flags, "zone": c.zone ?? NSNull(),
                                    "run": run ?? NSNull(), "auto": false]
        if noAuto { extra["noAuto"] = true }
        var impact: [String: Any] = ["files": stamps.reduce(0) { $0 + $1.files }, "links": 0, "warnings": [String]()]
        if [TidyOp.move, TidyOp.merge, TidyOp.archive].contains(c.item.op), let moves = plannedMoves(c.item) {
            let corpus = vm.vault(forAbs: moves.first?.from ?? "").flatMap { v -> TidyCorpus? in
                if let x = corpusCache[v] { return x }
                let x = TidyCorpus(root: v); corpusCache[v] = x; return x
            }
            let plan = linkPlan(moves, vm: vm, corpus: corpus)
            var warnings = plan.warnings
            if let p = plan.problem { warnings.append(p) }
            impact["links"] = plan.links
            impact["warnings"] = warnings
        }
        extra["impact"] = impact
        let id = newSugID(c.key)
        let s = TidySug(id: id, item: c.item, extra: extra, docId: c.docId, state: "pending", created: nowTS, decided: nil, batchId: nil, cooldown: nil, error: nil)
        return save(s) ? id : nil
    }

    /// 제안대로 했을 때의 (이동 전, 이동 뒤, 폴더인가) — 링크 계획·자동 판단용. 목적지에 같은 이름이 있으면 그 항목은 빠진다.
    func plannedMoves(_ i: TidyItem) -> [(from: String, to: String, isDir: Bool)]? {
        switch i.op {
        case TidyOp.move:
            guard let to = i.to else { return nil }
            return i.from.map { ($0, to + "/" + ($0 as NSString).lastPathComponent, TidyFS.isDir(TidyFS.rawPath($0))) }
        case TidyOp.archive:
            guard let f = i.from.first, let dst = displayTarget(i) else { return nil }
            return [(f, dst, TidyFS.isDir(TidyFS.rawPath(f)))]
        case TidyOp.merge:
            guard let f = i.from.first, let to = i.to else { return nil }
            let raw = TidyFS.rawPath(f)
            return TidyFS.entries(raw).filter { !$0.name.hasPrefix(".") }.map { e in
                let n = Indexer.nfc(e.name)
                return (f + "/" + n, to + "/" + n, TidyFS.isDir(raw + "/" + e.name))
            }
        default: return nil
        }
    }

    /// 나중에(later) 7일이 지난 것은 다시 대기로. 적용 중에 멈춘 것은 실패로.
    func reviveLater() {
        _ = try? ctx.db.sql.run("UPDATE suggestions SET state='pending', cooldown_until=NULL WHERE kind='tidy' AND state='later' AND cooldown_until<=?",
                                [.double(nowTS)])
        _ = try? ctx.db.sql.run("UPDATE suggestions SET state='failed', error='적용이 중간에 멈췄어요' WHERE kind='tidy' AND state='applying' AND decided<?",
                                [.double(nowTS - 600)])
    }

    func runRules(autoApply: Bool) -> [String: Any] {
        if ctx.isStopped { return ["ok": false, "error": "사서가 멈춰 있어요. 다시 시작하면 정리할 수 있어요.", "proposed": 0, "applied": 0] }
        reviveLater()
        let inv = inventory(force: false)
        let vm = VaultMap(roots: inv.vaults)
        let cands = ruleCandidates(inv)
        let keys = Set(cands.map { $0.key })
        let candFroms = Set(cands.flatMap { $0.item.from })
        var existing = sugs("state IN ('pending','later','applying') OR coalesce(decided, created)>=?", [.double(nowTS - 30 * 86400)])
        var withdrawn = 0
        for e in existing where e.state == "pending" || e.state == "later" {
            var why: String? = nil
            if e.item.origin == "rule" && !keys.contains(e.key) { why = "더는 맞지 않아요" }
            else if e.item.origin != "rule" {
                if e.item.from.contains(where: { !TidyFS.exists(TidyFS.rawPath($0)) }) { why = "자리가 없어졌어요" }
                else if e.item.from.contains(where: { candFroms.contains($0) }) { why = "같은 자리에 규칙 제안이 있어요" }
            }
            if let w = why { setState(e.id, "withdrawn", error: w); withdrawn += 1 }
        }
        if withdrawn > 0 { existing = sugs("state IN ('pending','later','applying') OR coalesce(decided, created)>=?", [.double(nowTS - 30 * 86400)]) }
        var proposed = 0
        corpusCache = [:]
        for c in cands { if insert(c, existing: existing, run: nil, vm: vm) != nil { proposed += 1 } }
        corpusCache = [:]
        let applied = autoApply ? autoPass() : 0
        if proposed + applied + withdrawn > 0 { ctx.emit(.tidy) }
        return ["ok": true, "proposed": proposed, "applied": applied, "withdrawn": withdrawn, "places": inv.places.count, "inventoryMs": Int(lastInventoryMs)]
    }

    // MARK: Claude 정리 계획 받기 (§5)

    func ingest(result: [String: Any], runId: String?) -> [String: Any] {
        if ctx.isStopped { return ["ok": false, "error": "사서가 멈춰 있어요.", "proposed": 0, "applied": 0] }
        reviveLater()
        let inv = inventory(force: false)
        let vm = VaultMap(roots: inv.vaults)
        let sources = localSources(), code = codeFolderResolved()
        let summary = (result["summary"] as? String).map { TidyText.clip($0, 200) }
        let questions: [[String: Any]] = ((result["questions"] as? [[String: Any]]) ?? []).prefix(5).compactMap { q in
            guard let t = q["text"] as? String, !t.isEmpty else { return nil }
            return ["text": TidyText.clip(t, 80), "path": (q["path"] as? String).map { Indexer.nfc($0) as Any } ?? NSNull()]
        }
        ctx.db.setSetting(TidySetting.lastPlan, BrainFormat.json(["summary": summary.map { $0 as Any } ?? NSNull(), "questions": questions,
                                                                   "at": nowTS, "runId": runId.map { $0 as Any } ?? NSNull()]))
        let existing = sugs("state IN ('pending','later','applying') OR coalesce(decided, created)>=?", [.double(nowTS - 30 * 86400)])
        let ruleFroms = Set(existing.filter { ($0.state == "pending" || $0.state == "later") && $0.item.origin == "rule" }.flatMap { $0.item.from })
        var proposed = 0
        var dropped: [[String: Any]] = []
        var ids: [String] = []
        corpusCache = [:]
        for (idx, o) in ((result["items"] as? [[String: Any]]) ?? []).prefix(30).enumerated() {
            guard var item = TidyItem(json: o) else { dropped.append(["index": idx, "reason": "형식이 맞지 않아요"]); continue }
            item.origin = "claude"
            item.from = item.from.map { normalizeDest($0) }
            item.to = item.to.map { normalizeDest($0) }
            if let p = precheck(item, vm: vm, sources: sources, code: code) { dropped.append(["index": idx, "reason": p]); continue }
            if item.from.contains(where: { ruleFroms.contains($0) }) { dropped.append(["index": idx, "reason": "같은 자리에 규칙 제안이 있어요"]); continue }
            let place = inv.place(path: item.from[0])
            let zone = place?.zone ?? zoneOf(item.from[0], vm: vm, sources: sources)
            let toRel = item.to.flatMap { vm.paraRel(forAbs: $0) }
            let toCode = item.to.map { t in code.map { t == $0 || t.hasPrefix($0 + "/") } ?? false } ?? false
            item.signature = TidySignature.of(op: item.op, fromZone: zone, toParaRel: toRel, toCode: toCode)
            if item.title.isEmpty { item.title = TidyText.clip(((item.from[0] as NSString).lastPathComponent) + " 정리", 40) }
            let flags = item.from.compactMap { inv.place(path: $0)?.flags }.reduce(Set<String>()) { $0.union($1) }
            let c = TidyCand(item: item, stamps: nil, flags: flags.sorted(), zone: zone?.rawValue, docId: place?.docIds.first)
            if let id = insert(c, existing: existing, run: runId, vm: vm) { proposed += 1; ids.append(id) }
            else { dropped.append(["index": idx, "reason": "이미 있거나 최근에 거절한 제안이에요"]) }
        }
        corpusCache = [:]
        let applied = autoPass()
        ctx.emit(.tidy)
        return ["ok": true, "proposed": proposed, "applied": applied, "dropped": dropped, "ids": ids]
    }

    /// Claude 항목의 쓰기 전 검사 (적용할 때 다시 한다).
    func precheck(_ i: TidyItem, vm: VaultMap, sources: [TidySource], code: String?) -> String? {
        for f in i.from {
            guard TidyFS.exists(TidyFS.rawPath(f)) else { return "자리가 없어요" }
            if let p = fromProblem(f, op: i.op, vm: vm, sources: sources, code: code) { return p }
        }
        switch i.op {
        case TidyOp.move, TidyOp.merge:
            guard let to = i.to else { return "목적지가 없어요" }
            return toProblem(to, from: i.from, vm: vm, sources: sources, code: code, codeOnly: codeOnly(i.from, vm: vm))
        case TidyOp.archive:
            guard let base = i.to ?? i.from.first.flatMap({ archiveBase(for: $0) }) else { return "보관할 볼트를 찾지 못했어요" }
            return toProblem(base, from: i.from, vm: vm, sources: sources, code: code, codeOnly: codeOnly(i.from, vm: vm))
        case TidyOp.exclude:
            guard let f = i.from.first, TidyFS.isDir(TidyFS.rawPath(f)) else { return "색인에서 빼기는 폴더만 해요" }
            guard let s = source(covering: f, sources), let rel = s.rel(f), !rel.isEmpty else { return "이 폴더를 색인하는 출처가 없어요" }
            if s.isExcluded(f) { return "이미 색인에서 빠져 있어요" }
            return nil
        case TidyOp.trash:
            if i.from.contains(where: { TidyFS.isDir(TidyFS.rawPath($0)) }) { return "폴더는 휴지통으로 보내지 않아요" }
            return nil
        default: return nil
        }
    }

    /// 인벤토리에 없는 경로의 구역 (볼트 안이면 첫 조각, 출처 맨 위면 loose).
    func zoneOf(_ path: String, vm: VaultMap, sources: [TidySource]) -> TidyZone? {
        if let rel = vm.paraRel(forAbs: path) {
            let comps = rel.split(separator: "/").map(String.init)
            if comps.count == 1 { return .vaultRoot }
            return comps.first.flatMap { TidyZone.of(paraTop: $0) }
        }
        if let s = source(covering: path, sources), let rel = s.rel(path), !rel.isEmpty { return .loose }
        return nil
    }

    // MARK: 자동 적용 (§4.4)

    func autoUsedToday() -> Int {
        var n = 0
        try? ctx.db.sql.query("""
            SELECT COUNT(*) FROM suggestions WHERE kind='tidy' AND state IN ('applied','undone') AND json_extract(payload,'$.auto')=1 AND decided>=?
            """, [.double(startOfToday)]) { n = Int($0.int(0)) }
        return n
    }

    /// 자동으로 해도 되는가. 아니면 이유.
    func autoBlock(_ s: TidySug, vm: VaultMap) -> String? {
        let i = s.item
        guard ruleState(i.signature) == "auto" else { return "자동 규칙이 아니에요" }
        guard TidyOp.autoable.contains(i.op) else { return "자동으로 할 수 없는 동작이에요" }
        // 기본 자동 규칙·Claude 항목은 certain만, 배운 규칙(규칙이 만든 항목)은 certain·likely
        let strict = TidyRule.builtinAuto.contains(i.signature) || i.origin != "rule"
        guard i.certainty == TidyCertainty.certain || (!strict && i.certainty == TidyCertainty.likely) else { return "확실하지 않아요" }
        if (s.extra["noAuto"] as? Bool) == true { return "최근에 되돌린 정리예요" }
        let flags = Set((s.extra["flags"] as? [String]) ?? [])
        if !flags.isDisjoint(with: [TidyFlag.hidden, TidyFlag.secret, TidyFlag.git, TidyFlag.code, TidyFlag.frozen, TidyFlag.truncated]) { return "조심할 자리예요" }
        for f in i.from {
            if f.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return "숨김 항목이에요" }
            if TidyNames.isSecret((f as NSString).lastPathComponent) { return "비밀 값 파일이에요" }
        }
        for st in s.snap where nowTS - st.mtime < 86400 { return "24시간 안에 바뀌었어요" }
        if i.op == TidyOp.exclude { return nil }
        for f in i.from where TidyFS.isDir(TidyFS.rawPath(f)) { if let p = secretProblem(f) { return p } }
        if i.from.contains(where: { isCodeLike($0) }) { return "코드 저장소예요" }
        guard let moves = plannedMoves(i), !moves.isEmpty else { return "옮길 것이 없어요" }
        for m in moves where TidyFS.exists(TidyFS.rawPath(m.to)) { return "목적지에 같은 이름이 있어요" }
        let plan = linkPlan(moves, vm: vm)
        if plan.problem != nil || plan.needsRewrite || !plan.warnings.isEmpty { return "링크를 고쳐야 해요" }
        return nil
    }

    /// 대기 중 제안 중 자동 대상만 적용한다. 하루 상한·한 번 10건. 적용한 수.
    func autoPass() -> Int {
        guard autoOn, !ctx.isStopped else { return 0 }
        var room = min(10, dailyCap - autoUsedToday())
        guard room > 0 else { return 0 }
        let vm = vaultMap()
        var n = 0
        for s in sugs("state='pending'") {
            guard room > 0 else { break }
            guard autoBlock(s, vm: vm) == nil else { continue }
            let r = apply(s.id, auto: true)
            if r.ok && r.done > 0 { n += 1; room -= 1 }
        }
        return n
    }

    // MARK: 배우기 (§4.7)

    func approvals(_ sig: String) -> Int {
        var n = 0
        try? ctx.db.sql.query("""
            SELECT COUNT(*) FROM suggestions WHERE kind='tidy' AND rule_key=? AND state='applied' AND coalesce(json_extract(payload,'$.auto'),0)=0
            """, [.text(sig)]) { n = Int($0.int(0)) }
        return n
    }

    /// 3번 승인했고 아직 상태를 정하지 않은 서명 (자동 가능한 동작만).
    func learnPrompts() -> [[String: Any]] {
        var out: [[String: Any]] = []
        var sigs: [(String, Int)] = []
        try? ctx.db.sql.query("""
            SELECT rule_key, COUNT(*) FROM suggestions WHERE kind='tidy' AND state='applied' AND coalesce(json_extract(payload,'$.auto'),0)=0
            GROUP BY rule_key HAVING COUNT(*)>=3 ORDER BY COUNT(*) DESC
            """) { sigs.append(($0.text(0), Int($0.int(1)))) }
        for (sig, n) in sigs where ruleState(sig) == nil {
            let op = String(sig.split(separator: ":").first ?? "")
            guard TidyOp.autoable.contains(op) else { continue }
            out.append(["signature": sig, "label": TidySignature.label(sig), "approvals": n])
        }
        return out
    }

    /// 두 번 연속 거절한 서명 (Claude 입력 avoid).
    func avoidList() -> [String] {
        var rows: [(String, String)] = []
        try? ctx.db.sql.query("""
            SELECT rule_key, state FROM suggestions WHERE kind='tidy' AND state IN ('rejected','applied','undone') AND decided IS NOT NULL
            ORDER BY decided DESC
            """) { rows.append(($0.text(0), $0.text(1))) }
        var seen: [String: [String]] = [:]
        for (sig, st) in rows where (seen[sig]?.count ?? 0) < 2 { seen[sig, default: []].append(st) }
        return seen.filter { $0.value.count == 2 && $0.value.allSatisfy { $0 == "rejected" } }.map { $0.key }.sorted()
    }
}
