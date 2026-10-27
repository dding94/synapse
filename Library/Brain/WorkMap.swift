import Foundation

// v0.9 작업 지도 자료 (docs/V09.md §6). E2 담당.
// Brain 파사드가 사서 큐에서 부른다: work.workMap(tidy:) · work.workMapDetail(id:tidy:)
// 위쪽(지금·다음·기다림)은 열린 Jira 티켓 + 흐름, 아래쪽(영역·프로젝트·정리 안 됨·자료·보관)은 정리 비서 인벤토리 자리다.
// 저장값·캐시만 읽는다(인벤토리는 Tidy 캐시). 실제 자료에서 0.3초 안.
//
// id: 티켓 "t:PROJ-123" · 흐름 "thread:t:<12자>" · 자리 "p:<12자>" (TidyPlace.id)

/// 작업 지도의 열린 티켓 한 장.
struct WorkMapTicket {
    let doc: BrainDoc
    let key: String
    let title: String
    let status: String           // 정리된 상태 이름 ("#" 뗀 것)
    let group: String            // Views.statusGroup: doing | todo | blocked
    let mine: Bool
    let priority: String
    let rank: Int
    let due: String?
    let dueDays: Int?
    let updated: Double
    let since: Date?
    let waiting: Bool            // 상태 이름이 리뷰·QA·검수·대기·보류·hold·blocked·막힘 계열
    let stale: Bool              // 진행 중인데 7일 넘게 갱신 없음
    var url: String? { doc.location.hasPrefix("http") ? doc.location : nil }
}

enum WorkMapText {
    private static let waitingRx = try! NSRegularExpression(pattern: "리뷰|review|\\bqa\\b|검수|대기|보류|hold|block|막힘", options: [.caseInsensitive])
    static func isWaiting(_ status: String) -> Bool {
        waitingRx.firstMatch(in: status, range: NSRange(location: 0, length: (status as NSString).length)) != nil
    }

    /// 달력 날 차이로: 오늘 · 어제 · N일 전 · N달 전.
    static func daysAgo(_ ts: Double, now: Date) -> String {
        guard ts > 0 else { return "" }
        let cal = WorkTime.cal
        let d = cal.dateComponents([.day], from: cal.startOfDay(for: Date(timeIntervalSince1970: ts)), to: cal.startOfDay(for: now)).day ?? 0
        if d <= 0 { return "오늘" }
        if d == 1 { return "어제" }
        if d < 100 { return "\(d)일 전" }
        return "\(d / 30)달 전"
    }
    static func days(_ ts: Double, now: Date) -> Int {
        guard ts > 0 else { return 0 }
        let cal = WorkTime.cal
        return max(0, cal.dateComponents([.day], from: cal.startOfDay(for: Date(timeIntervalSince1970: ts)), to: cal.startOfDay(for: now)).day ?? 0)
    }
    /// "방금" · "N분 전" · "N시간 전" · 그 밖은 날 라벨.
    static func runLabel(_ ts: Double, now: Date) -> String {
        let s = now.timeIntervalSince1970 - ts
        if s < 60 { return "방금" }
        if s < 3600 { return "\(Int(s / 60))분 전" }
        if s < 86400 { return "\(Int(s / 3600))시간 전" }
        return daysAgo(ts, now: now)
    }
    /// 경로 → "1-Projects › 사이드-프로젝트" 같은 짧은 위치.
    static func label(_ rel: String) -> String {
        rel.split(separator: "/").map(String.init).joined(separator: " › ")
    }
    static let zoneLabels: [String: String] = ["loose": "데스크톱", "inbox": "받은 문서함", "vault-root": "볼트 루트", "workspace": "작업 공간",
                                               "project": "프로젝트", "area": "영역", "resource": "자료", "archive": "보관"]
}

/// 한 번 그릴 때 모으는 값.
struct WorkMapData {
    let view: WorkViewData
    let scopes: WorkScopeTable
    let tickets: [WorkMapTicket]
    let ticketByKey: [String: WorkMapTicket]
    let threadByKey: [String: WorkThreadRow]
    let places: [TidyPlace]
    let cards: [[String: Any]]
    let focus: [String: String]      // 티켓 키 → Claude 티켓 정리의 다음 행동(focus.action)
    let lines: [String: String]      // 티켓 키 → Claude 티켓 정리의 한 줄
    let mentions: [String: (docs: [String], last: Double)]   // 티켓 키 → 그 키를 언급한 로컬 문서·가장 최근 수정
}

extension WorkModel {

    // MARK: - 6.1 workMap

    func workMap(tidy: TidyAPI) -> [String: Any] {
        let nowD = now
        let m = mapData(tidy: tidy)
        let scopeSetting = ctx.db.setting(TidySetting.workmapScope) ?? "all"
        let scope = ["work", "personal"].contains(scopeSetting) ? scopeSetting : "all"
        func keep(_ row: [String: Any]) -> Bool { scope == "all" || (row["scope"] as? String) == scope }

        // 위쪽: 지금 · 다음 · 기다림
        var nowRows: [(Double, [String: Any])] = [], nowThreads: [(Double, [String: Any])] = [], next: [(Int, Double, [String: Any])] = [], waiting: [(Double, [String: Any])] = []
        var usedThreads = Set<String>()
        for t in m.tickets {
            let th = m.threadByKey[t.key]
            if let th = th { usedThreads.insert(th.id) }
            if t.waiting {
                waiting.append((t.since?.timeIntervalSince1970 ?? t.updated, ticketRow(t, m, group: "waiting")))
                continue
            }
            guard t.mine else { continue }
            if t.group == "doing" || th?.tier == .now {
                nowRows.append((Double(t.rank) * 1e10 - t.updated, ticketRow(t, m, group: t.group == "doing" ? "doing" : t.group)))
            } else if t.group == "todo" || t.group == "blocked" {
                let recent = max(t.updated, m.mentions[t.key]?.last ?? 0, th?.lastHuman ?? 0) >= nowD.timeIntervalSince1970 - 7 * 86400
                let soon = t.dueDays.map { $0 <= 14 } ?? false
                let first = (soon || recent) ? 0 : 1
                next.append((first * 200 + min(t.rank, 9) * 10 + (t.dueDays.map { min(max($0, 0), 9) } ?? 9),
                             -max(t.updated, th?.lastHuman ?? 0), ticketRow(t, m, group: t.group)))
            }
        }
        // 티켓 없는(또는 열린 티켓이 아닌) 지금·이번 주 흐름
        for th in m.view.threads where !usedThreads.contains(th.id) && (th.tier == .now || th.tier == .week) {
            if th.issueKeys.contains(where: { m.ticketByKey[$0] != nil }) { continue }
            let row = threadRow(th, m, group: th.tier == .now ? "doing" : "todo")
            if th.tier == .now { nowThreads.append((-th.score * 1e8 - (th.lastHuman ?? 0), row)) }
            else { next.append((150, -(th.lastHuman ?? th.lastTs ?? 0), row)) }
        }
        // 지금: 진행 중 티켓(우선순위 → 최근 갱신) 다음에 티켓 없는 지금 흐름(점수 순). 다음: 기한 14일·최근 7일 티켓 → 이번 주 흐름 → 나머지 할 일 티켓
        let nowItems = (nowRows.sorted { $0.0 < $1.0 } + nowThreads.sorted { $0.0 < $1.0 }).map { $0.1 }.filter(keep)
        let nextAll = next.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }.map { $0.2 }.filter(keep)
        let waitItems = waiting.sorted { $0.0 < $1.0 }.map { $0.1 }.filter(keep)

        // 아래쪽: 자리
        var zones: [String: [TidyPlace]] = [:]
        for p in m.places where !p.flags.contains(TidyFlag.vault) {
            switch p.zone {
            case .area: zones["areas", default: []].append(p)
            case .project: zones["projects", default: []].append(p)
            case .resource: zones["resources", default: []].append(p)
            case .archive: zones["archive", default: []].append(p)
            case .loose, .inbox, .vaultRoot: zones["unfiled", default: []].append(p)
            case .workspace: break      // 티켓 폴더는 위쪽 줄의 folders로 보인다
            }
        }
        func places(_ k: String) -> [[String: Any]] {
            let list = (zones[k] ?? []).sorted { k == "unfiled" ? $0.lastModified < $1.lastModified : $0.lastModified > $1.lastModified }
            return list.map { placeRow($0, m) }.filter(keep)
        }
        var nextSection: [String: Any] = ["key": "next", "title": "다음", "items": Array(nextAll.prefix(12))]
        if nextAll.count > 12 { nextSection["more"] = nextAll.count - 12 }
        let sections: [[String: Any]] = [
            ["key": "now", "title": "지금", "items": nowItems],
            nextSection,
            ["key": "waiting", "title": "기다림", "items": waitItems],
            ["key": "areas", "title": "영역", "items": places("areas")],
            ["key": "projects", "title": "프로젝트", "items": places("projects")],
            ["key": "unfiled", "title": "정리 안 됨", "items": places("unfiled")],
            ["key": "resources", "title": "자료", "collapsed": true, "items": places("resources")],
            ["key": "archive", "title": "보관", "collapsed": true, "items": places("archive")],
        ]
        let empty = sections.allSatisfy { (($0["items"] as? [Any]) ?? []).isEmpty }
        return ["ok": true, "generated": nowD.timeIntervalSince1970, "hasJira": ctx.docs.contains { $0.kind == "jira" },
                "scope": scope, "tidy": tidyHead(tidy), "sections": sections,
                "empty": empty ? "자료를 연결하면 여기에 할 일과 폴더가 정리돼요" as Any : NSNull()]
    }

    /// 머리의 정리 블록 (§6.1 tidy): counts + 리뷰 + 마지막 Claude 정리 계획 시각.
    func tidyHead(_ tidy: TidyAPI) -> [String: Any] {
        let c = tidy.counts()
        var last: Any = NSNull()
        if let o = BrainFormat.parse(ctx.db.setting(TidySetting.lastPlan)) as? [String: Any] {
            var at: Double? = (o["at"] as? NSNumber)?.doubleValue
            if at == nil, let s = o["at"] as? String { at = BrainFormat.date(s)?.timeIntervalSince1970 ?? Double(s) }
            if let a = at, a > 0 { last = WorkMapText.runLabel(a, now: now) }
        }
        let review = TidyReview.today(setting: ctx.db.setting(TidySetting.reviewDay), now: now)
        return ["pending": c["pending"] ?? 0, "autoToday": c["autoToday"] ?? 0, "lastRunLabel": last,
                "review": review.map { $0 as Any } ?? NSNull(), "counts": c]
    }

    // MARK: - 모으기

    func mapData(tidy: TidyAPI) -> WorkMapData {
        let v = loadView()
        let tickets = mapTickets()
        var byKey: [String: WorkMapTicket] = [:]
        for t in tickets { byKey[t.key] = t }
        // 키 → 흐름 (점수 높은 것, threads는 점수 순)
        var threadByKey: [String: WorkThreadRow] = [:]
        for th in v.threads {
            var keys = th.issueKeys
            for d in th.docIds { if let k = ctx.doc(id: d).flatMap({ WorkModel.jiraKey($0) }), !keys.contains(k) { keys.append(k) } }
            for k in keys where threadByKey[k] == nil { threadByKey[k] = th }
        }
        var mentions: [String: (docs: [String], last: Double)] = [:]
        for d in ctx.docs where d.isLocal {
            let keys = Set(d.issueKeys).filter { byKey[$0] != nil }
            // 티켓을 여럿(4개 넘게) 나열한 목록·현황 문서는 고친 시각을 그 티켓들의 활동으로 치지 않는다(모두 "어제"가 되지 않게)
            let specific = keys.count <= 3
            for k in keys {
                var x = mentions[k] ?? ([], 0)
                x.docs.append(d.id)
                if specific { x.last = max(x.last, d.modified.timeIntervalSince1970) }
                mentions[k] = x
            }
        }
        let digest = ticketDigest()
        return WorkMapData(view: v, scopes: scopeTable(v), tickets: tickets, ticketByKey: byKey, threadByKey: threadByKey,
                           places: tidy.inventory(force: false).places, cards: tidy.cards(paths: [], keys: []),
                           focus: digest.focus, lines: digest.lines, mentions: mentions)
    }

    /// 열린 Jira 티켓 (상태 묶음 todo·doing·blocked).
    func mapTickets() -> [WorkMapTicket] {
        let nowD = now, nowT = nowTS
        var changed: [String: Double] = [:]
        try? ctx.db.sql.query("SELECT doc_id, changed FROM remote_state WHERE changed IS NOT NULL") { changed[$0.text(0)] = $0.double(1) }
        var out: [WorkMapTicket] = []
        for d in ctx.docs where d.kind == "jira" {
            let raw = d.meta["status"] ?? "", cat = d.meta["statusCategory"] ?? ""
            if raw.isEmpty && cat.isEmpty { continue }
            let group = Views.statusGroup(name: raw, category: cat)
            guard ["todo", "doing", "blocked"].contains(group), let key = WorkModel.jiraKey(d) else { continue }
            let status = raw.trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespacesAndNewlines))
            let updated = (d.meta["updated"].flatMap { BrainFormat.isoFormatter.date(from: $0) } ?? d.modified).timeIntervalSince1970
            var since = d.meta["statusChanged"].flatMap { BrainFormat.isoFormatter.date(from: $0) }
            if since == nil, let c = changed[d.id] { since = Date(timeIntervalSince1970: c) }
            let due = d.meta["duedate"].flatMap { $0.isEmpty ? nil : $0 }
            let priority = d.meta["priority"] ?? ""
            var title = d.title
            for sep in [" · ", " - ", ": ", " "] where title.hasPrefix(key + sep) { title = String(title.dropFirst(key.count + sep.count)); break }
            out.append(WorkMapTicket(doc: d, key: key, title: title, status: status, group: group, mine: d.meta["mine"] == "1",
                                     priority: priority, rank: WorkModel.priorityRank(priority), due: due,
                                     dueDays: due.flatMap { WorkTime.daysUntil($0, now: nowD) }, updated: updated, since: since,
                                     waiting: group == "blocked" || WorkMapText.isWaiting(status),
                                     stale: group == "doing" && nowT - updated > 7 * 86400))
        }
        return out.sorted { $0.key < $1.key }
    }

    private static var digestCache: (stamp: Double, focus: [String: String], lines: [String: String])?

    /// Claude 티켓 정리(kind tickets, scope all)의 focus 다음 행동과 한 줄. ai.sqlite를 읽기 전용으로 연다(수정 시각으로 캐시).
    func ticketDigest() -> (focus: [String: String], lines: [String: String]) {
        let path = ctx.home.appendingPathComponent("ai.sqlite").path
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return ([:], [:]) }
        let stamp = [path, path + "-wal"].compactMap { (try? fm.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }
            .map { $0.timeIntervalSince1970 }.max() ?? 0
        if let c = WorkModel.digestCache, c.stamp == stamp { return (c.focus, c.lines) }
        var focus: [String: String] = [:], lines: [String: String] = [:]
        var json: String? = nil
        let sql = "SELECT json FROM digests WHERE kind='tickets' AND scope='all'"
        // WAL 파일(-shm)이 아직 없으면 읽기 전용 열기가 실패한다 — 그때는 읽기·쓰기로 열어 읽기만 한다
        do { try SQLiteDB(path: path, readonly: true).query(sql) { json = $0.text(0) } }
        catch { try? SQLiteDB(path: path).query(sql) { json = $0.text(0) } }
        if let o = BrainFormat.parse(json) as? [String: Any] {
            for f in (o["focus"] as? [[String: Any]]) ?? [] {
                guard let key = (f["ref"] as? [String: Any])?["key"] as? String else { continue }
                let action = (f["action"] as? String) ?? "", why = (f["why"] as? String) ?? ""
                let text = action.isEmpty ? why : action
                if !text.isEmpty && focus[key] == nil { focus[key] = text }
            }
            for (k, t) in (o["lines"] as? [String: Any]) ?? [:] { if let s = t as? String, !s.isEmpty { lines[k] = s } }
        }
        WorkModel.digestCache = (stamp, focus, lines)
        return (focus, lines)
    }

    // MARK: - 줄 만들기

    func ticketRow(_ t: WorkMapTicket, _ m: WorkMapData, group: String) -> [String: Any] {
        let nowD = now
        let th = m.threadByKey[t.key]
        let folders = ticketFolders(t.key, m)
        let zonesCount = Set(folders.map { $0.zone }).count
        var docs = Set(m.mentions[t.key]?.docs ?? [])
        for d in th?.docIds ?? [] where ctx.doc(id: d)?.isLocal == true { docs.insert(d) }
        var next: Any = NSNull(), nextSource: Any = NSNull()
        if let f = m.focus[t.key] { next = f; nextSource = "claude" }
        else if let h = threadStopped(th, m) { next = h; nextSource = "thread" }
        // 마지막 활동: 티켓 갱신 · 관련 로컬 문서를 사람이 고친 때 · 그 키만 다룬 문서. Synapse에서 티켓을 열어 본 것은 치지 않는다
        var localLast = 0.0
        for d in th?.docIds ?? [] where ctx.doc(id: d)?.isLocal == true { localLast = max(localLast, m.view.states[d]?.lastHuman ?? 0) }
        let last = max(t.updated, localLast, m.mentions[t.key]?.last ?? 0)
        var badges: [String] = []
        if zonesCount > 1 { badges.append("split") }
        if let n = t.dueDays, n <= 3 { badges.append("due") }
        if t.stale { badges.append("stale") }
        let paths = folders.map { $0.path }
        return ["id": "t:" + t.key, "type": "ticket", "key": t.key, "title": t.title, "status": t.status, "statusGroup": group,
                "mine": t.mine, "priority": t.priority.isEmpty ? NSNull() : t.priority as Any,
                "dueLabel": t.dueDays.map { WorkTime.dueLabel($0) as Any } ?? NSNull(),
                "next": next, "nextSource": nextSource,
                "lastLabel": WorkMapText.daysAgo(last, now: nowD), "lastTs": last,
                "folders": folders.map { ["path": $0.path, "label": $0.label, "zone": $0.zone.rawValue, "files": $0.files] as [String: Any] },
                "split": zonesCount > 1, "docs": docs.count, "sessions": th?.sessionIds.count ?? 0,
                "docId": t.doc.id, "url": t.url.map { $0 as Any } ?? NSNull(), "scope": "work",
                "proposals": matchingCards(paths: paths, keys: [t.key], m).count, "badges": badges]
    }

    func threadRow(_ th: WorkThreadRow, _ m: WorkMapData, group: String) -> [String: Any] {
        let nowD = now
        let folders = threadFolders(th, m)
        let zonesCount = Set(folders.map { $0.zone }).count
        var keys = th.issueKeys
        for d in th.docIds { if let k = ctx.doc(id: d).flatMap({ WorkModel.jiraKey($0) }), !keys.contains(k) { keys.append(k) } }
        let due = earliestDue(docIds: th.docIds, keys: keys, m.view)
        let last = th.lastHuman ?? th.lastTs ?? 0
        var badges: [String] = []
        if zonesCount > 1 { badges.append("split") }
        if let d = due, d.1 <= 3 { badges.append("due") }
        if nowD.timeIntervalSince1970 - last > 14 * 86400 { badges.append("stale") }
        let scope = th.primaryDoc.map { m.scopes.info(docId: $0).scope } ?? "personal"
        let next = threadStopped(th, m)
        return ["id": "thread:" + th.id, "type": "thread", "key": keys.first.map { $0 as Any } ?? NSNull(), "title": th.displayTitle,
                "status": NSNull(), "statusGroup": group, "mine": true, "priority": NSNull(),
                "dueLabel": due.map { WorkTime.dueLabel($0.1) as Any } ?? NSNull(),
                "next": next.map { $0 as Any } ?? NSNull(), "nextSource": next == nil ? NSNull() : "thread" as Any,
                "lastLabel": WorkMapText.daysAgo(last, now: nowD), "lastTs": last,
                "folders": folders.map { ["path": $0.path, "label": $0.label, "zone": $0.zone.rawValue, "files": $0.files] as [String: Any] },
                "split": zonesCount > 1, "docs": th.docIds.count, "sessions": th.sessionIds.count,
                "docId": th.primaryDoc.map { $0 as Any } ?? NSNull(), "url": NSNull(), "scope": scope,
                "proposals": matchingCards(paths: folders.map { $0.path }, keys: keys, m).count, "badges": badges]
    }

    func placeRow(_ p: TidyPlace, _ m: WorkMapData) -> [String: Any] {
        let nowD = now
        let h = placeHealth(p)
        return ["id": p.id, "type": "place", "name": p.name, "label": p.label, "path": p.path, "zone": p.zone.rawValue,
                "health": h.health, "healthLabel": h.label, "files": p.files, "md": p.mdFiles,
                "lastLabel": WorkMapText.daysAgo(p.lastModified, now: nowD), "lastTs": p.lastModified,
                "tickets": p.ticketKeys, "flags": p.flags.sorted(), "proposals": matchingCards(paths: [p.path], keys: [], m).count,
                "docId": p.docIds.first.map { $0 as Any } ?? NSNull(), "scope": placeScope(p, m)]
    }

    /// 건강: frozen(플래그) > messy(제외 안 된 원자료 폴더 · 정리 안 됨 구역) > fresh(7일 안) > warm(30일 안) > stale.
    func placeHealth(_ p: TidyPlace) -> (health: String, label: String) {
        let days = WorkMapText.days(p.lastModified, now: now)
        if p.flags.contains(TidyFlag.frozen) { return ("frozen", "동결 · 참조용") }
        if !p.raw.isEmpty { return ("messy", "원자료 \(p.raw.count)곳") }
        if p.zone.isUnfiled {
            let where_ = WorkMapText.zoneLabels[p.zone.rawValue] ?? "정리 안 됨"
            return ("messy", days == 0 ? "\(where_)에 오늘 놓임" : "\(where_)에 \(days)일째")
        }
        if days <= 7 { return ("fresh", days == 0 ? "오늘 고침" : "\(days)일 전 고침") }
        if days <= 30 { return ("warm", "\(days)일 전 고침") }
        return ("stale", "\(days)일 그대로")
    }

    /// 자리의 업무/개인: 티켓 키가 있으면 업무, 아니면 안쪽 문서들의 v0.7 규칙값(많은 쪽), 문서가 없으면 이름 힌트.
    func placeScope(_ p: TidyPlace, _ m: WorkMapData) -> String {
        if !p.ticketKeys.isEmpty { return "work" }
        var w = 0, n = 0
        for id in p.docIds.prefix(20) where ctx.doc(id: id) != nil { n += 1; if m.scopes.info(docId: id).scope == "work" { w += 1 } }
        if n > 0 { return w * 2 >= n ? "work" : "personal" }
        return m.scopes.nameHint(p.name) ? "work" : "personal"
    }

    /// 그 티켓 키를 가진 자리 (인벤토리 ticketKeys). 볼트 자체는 뺀다.
    func ticketFolders(_ key: String, _ m: WorkMapData) -> [TidyPlace] {
        m.places.filter { $0.ticketKeys.contains(key) && !$0.flags.contains(TidyFlag.vault) }
            .sorted { $0.zone == .workspace && $1.zone != .workspace ? true : ($0.zone != .workspace && $1.zone == .workspace ? false : $0.path < $1.path) }
    }

    /// 흐름 문서가 들어 있는 자리 (문서 많은 순, 최대 3).
    func threadFolders(_ th: WorkThreadRow, _ m: WorkMapData) -> [TidyPlace] {
        var count: [String: Int] = [:]
        let cand = m.places.filter { $0.isDir && !$0.flags.contains(TidyFlag.vault) }
        for id in th.docIds {
            guard let abs = ctx.doc(id: id)?.absPath.map(Indexer.nfc) else { continue }
            if let p = cand.first(where: { abs.hasPrefix($0.path + "/") }) { count[p.id, default: 0] += 1 }
        }
        return count.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(3).compactMap { kv in m.places.first { $0.id == kv.key } }
    }

    /// 흐름의 멈춘 곳 제목 (대표 문서의 doc_state.stopped_heading).
    func threadStopped(_ th: WorkThreadRow?, _ m: WorkMapData) -> String? {
        guard let th = th, let p = th.primaryDoc, let h = m.view.states[p]?.stoppedHeading?.trimmingCharacters(in: .whitespaces), !h.isEmpty else { return nil }
        return WorkText.plain(h)
    }

    /// 대기 중 tidy 카드 중 그 경로 안쪽(from)이거나 그 티켓 키가 이름에 든 것.
    func matchingCards(paths: [String], keys: [String], _ m: WorkMapData) -> [[String: Any]] {
        if paths.isEmpty && keys.isEmpty { return [] }
        return m.cards.filter { c in
            let froms = WorkModel.cardPaths(c)
            if froms.contains(where: { f in paths.contains { f == $0 || f.hasPrefix($0 + "/") } }) { return true }
            if !keys.isEmpty, froms.contains(where: { f in keys.contains { (f as NSString).lastPathComponent.contains($0) } }) { return true }
            return false
        }
    }

    static func cardPaths(_ c: [String: Any]) -> [String] {
        ((c["from"] as? [Any]) ?? []).compactMap { x -> String? in
            if let s = x as? String { return Indexer.nfc(s) }
            return ((x as? [String: Any])?["path"] as? String).map(Indexer.nfc)
        }
    }

    // MARK: - 6.2 workMapDetail

    func workMapDetail(id: String, tidy: TidyAPI) -> [String: Any] {
        let m = mapData(tidy: tidy)
        if id.hasPrefix("p:") {
            guard let p = m.places.first(where: { $0.id == id }) else { return ["ok": false, "error": "자리를 찾을 수 없어요. 정리 지도를 다시 열어 주세요."] }
            return placeDetail(p, m)
        }
        if id.hasPrefix("thread:") {
            let tid = String(id.dropFirst(7))
            guard let th = m.view.threads.first(where: { $0.id == tid }) else { return ["ok": false, "error": "작업 흐름을 찾을 수 없어요."] }
            return threadDetail(th, m)
        }
        if id.hasPrefix("t:") {
            let key = String(id.dropFirst(2))
            if let t = m.ticketByKey[key] { return ticketDetail(t, m) }
            // 열린 티켓이 아니면(끝났거나 색인에 없음) 흐름으로라도
            if let th = m.threadByKey[key] { return threadDetail(th, m) }
            return ["ok": false, "error": "열린 티켓에서 \(key)를 찾을 수 없어요."]
        }
        return ["ok": false, "error": "알 수 없는 항목이에요."]
    }

    private func folderJSON(_ p: TidyPlace) -> [String: Any] {
        ["path": p.path, "label": p.label, "zone": p.zone.rawValue, "files": p.files, "lastLabel": WorkMapText.daysAgo(p.lastModified, now: now)]
    }

    private func docsJSON(_ ids: [String]) -> [[String: Any]] {
        var seen = Set<String>()
        let list = ids.compactMap { id -> BrainDoc? in seen.insert(id).inserted ? ctx.doc(id: id) : nil }.filter { $0.isLocal }
        return list.sorted { $0.modified > $1.modified }.prefix(10).map { d in
            ["docId": d.id, "title": d.title, "label": WorkMapText.label((d.paraPath as NSString).deletingLastPathComponent),
             "lastLabel": WorkMapText.daysAgo(d.modified.timeIntervalSince1970, now: now)]
        }
    }

    private func sessionsJSON(_ th: WorkThreadRow?) -> [[String: Any]] {
        guard let th = th, sessionsOn, !th.sessionIds.isEmpty else { return [] }
        let list = loadSessions(since: 0, ids: Set(th.sessionIds), withWrites: false).sorted { $0.lastTs > $1.lastTs }.prefix(5)
        return list.map { s in
            ["title": s.title ?? (s.tool == "codex" ? "Codex 세션" : "Claude 세션"),
             "lastLabel": BrainFormat.whenLabel(Date(timeIntervalSince1970: s.lastTs), now: now)]
        }
    }

    /// Jira 본문(색인 평문)의 첫 문장 — 제목 줄과 빈 줄은 건너뛴다.
    private func firstLine(_ d: BrainDoc, title: String) -> String? {
        for l in ctx.text(d, maxChars: 3000).components(separatedBy: "\n") {
            let t = WorkText.plain(l.trimmingCharacters(in: CharacterSet(charactersIn: "#>*- ").union(.whitespaces)))
            if t.count < 4 || t == d.title || t == title { continue }
            return WorkUtil.prefix(t, 120)
        }
        return nil
    }

    func ticketDetail(_ t: WorkMapTicket, _ m: WorkMapData) -> [String: Any] {
        let th = m.threadByKey[t.key]
        let folders = ticketFolders(t.key, m)
        var facts: [String] = []
        if t.mine { facts.append("담당 나") } else if let n = t.doc.meta["assigneeName"], !n.isEmpty { facts.append("담당 \(n)") }
        if !t.priority.isEmpty { facts.append("우선순위 \(t.priority)") }
        if let s = t.since {
            let c = WorkTime.cal
            facts.append("\(c.component(.month, from: s))/\(c.component(.day, from: s))부터 \(t.status.isEmpty ? "이 상태" : t.status)")
        }
        facts.append("마지막 갱신 \(WorkModel.agoLabel(Date(timeIntervalSince1970: t.updated), now: now))")
        if let n = t.dueDays { facts.append("기한 \(WorkTime.dueLabel(n))") }
        var docIds = m.mentions[t.key]?.docs ?? []
        docIds += th?.docIds ?? []
        for p in folders { docIds += p.docIds }
        var next: Any = NSNull()
        if let f = m.focus[t.key] { next = f } else if let h = threadStopped(th, m) { next = h }
        let summaryText: String? = m.lines[t.key] ?? firstLine(t.doc, title: t.title)
        let summary: Any = summaryText.map { $0 as Any } ?? NSNull()
        return ["ok": true, "id": "t:" + t.key, "type": "ticket", "title": t.title, "key": t.key, "status": t.status,
                "url": t.url.map { $0 as Any } ?? NSNull(), "docId": t.doc.id, "summary": summary, "next": next, "facts": facts,
                "folders": folders.map { folderJSON($0) }, "docs": docsJSON(docIds), "sessions": sessionsJSON(th), "children": [Any](),
                "proposals": matchingCards(paths: folders.map { $0.path }, keys: [t.key], m), "graphDocId": t.doc.id]
    }

    func threadDetail(_ th: WorkThreadRow, _ m: WorkMapData) -> [String: Any] {
        let folders = threadFolders(th, m)
        var keys = th.issueKeys
        for d in th.docIds { if let k = ctx.doc(id: d).flatMap({ WorkModel.jiraKey($0) }), !keys.contains(k) { keys.append(k) } }
        var facts: [String] = ["문서 \(th.docIds.count)개"]
        if !th.sessionIds.isEmpty && sessionsOn { facts.append("세션 \(th.sessionIds.count)개") }
        if let l = th.lastHuman ?? th.lastTs { facts.append("마지막 활동 \(BrainFormat.whenLabel(Date(timeIntervalSince1970: l), now: now))") }
        switch th.tier { case .now: facts.append("지금 하는 일"); case .week: facts.append("이번 주"); case .dormant: facts.append("쉬는 중"); case .none: break }
        let summary = th.primaryDoc.flatMap { m.view.states[$0]?.summary }
        let next = threadStopped(th, m)
        return ["ok": true, "id": "thread:" + th.id, "type": "thread", "title": th.displayTitle, "key": keys.first.map { $0 as Any } ?? NSNull(),
                "status": NSNull(), "url": NSNull(), "docId": th.primaryDoc.map { $0 as Any } ?? NSNull(),
                "summary": summary.map { $0 as Any } ?? NSNull(), "next": next.map { $0 as Any } ?? NSNull(), "facts": facts,
                "folders": folders.map { folderJSON($0) }, "docs": docsJSON(th.docIds), "sessions": sessionsJSON(th), "children": [Any](),
                "proposals": matchingCards(paths: folders.map { $0.path }, keys: keys, m),
                "graphDocId": th.primaryDoc.map { $0 as Any } ?? NSNull()]
    }

    func placeDetail(_ p: TidyPlace, _ m: WorkMapData) -> [String: Any] {
        var facts: [String] = [p.isDir ? "파일 \(p.files)개 · md \(p.mdFiles)개" : "파일"]
        let kinds = p.kinds.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(3)
            .map { "\($0.key.isEmpty ? "확장자 없음" : $0.key) \($0.value)" }
        if !kinds.isEmpty && p.isDir { facts.append("형식 " + kinds.joined(separator: " · ")) }
        facts.append("마지막 수정 \(WorkMapText.daysAgo(p.lastModified, now: now))")
        if !p.ticketKeys.isEmpty { facts.append("티켓 " + p.ticketKeys.joined(separator: " · ")) }
        if !p.raw.isEmpty { facts.append("원자료 폴더 \(p.raw.count)곳") }
        let flagText: [String: String] = [TidyFlag.frozen: "동결 · 참조용", TidyFlag.git: "git 저장소", TidyFlag.code: "코드 폴더",
                                          TidyFlag.secret: "비밀 파일 있음", TidyFlag.truncated: "파일이 많아 일부만 셌어요"]
        for f in p.flags.sorted() { if let t = flagText[f] { facts.append(t) } }
        let ticket = p.ticketKeys.first.flatMap { m.ticketByKey[$0] }
        return ["ok": true, "id": p.id, "type": "place", "title": p.name, "key": p.ticketKeys.first.map { $0 as Any } ?? NSNull(),
                "status": ticket.map { $0.status as Any } ?? NSNull(), "url": ticket?.url.map { $0 as Any } ?? NSNull(),
                "docId": p.docIds.first.map { $0 as Any } ?? NSNull(), "summary": NSNull(),
                "next": NSNull(), "facts": facts, "folders": [folderJSON(p)], "docs": docsJSON(p.docIds), "sessions": [Any](),
                "children": p.isDir ? children(p.path) : [], "proposals": matchingCards(paths: [p.path], keys: [], m),
                "graphDocId": p.docIds.first.map { $0 as Any } ?? NSNull()]
    }

    /// 바로 아래 폴더 (숨김·건너뛰는 이름 제외, 최근 수정 순 최대 12). 파일 수는 폴더마다 2,000개까지 센다. 내용은 읽지 않는다.
    func children(_ dir: String) -> [[String: Any]] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var rows: [(String, Int, Double)] = []
        for n in names where !Indexer.isSkippedDirName(n) {
            let p = dir + "/" + n
            guard let a = try? fm.attributesOfItem(atPath: p), (a[.type] as? FileAttributeType) == .typeDirectory else { continue }
            var files = 0, last = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
            if let en = fm.enumerator(at: URL(fileURLWithPath: p), includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                for case let u as URL in en {
                    let v = try? u.resourceValues(forKeys: Set(keys))
                    if v?.isDirectory == true { if Indexer.isSkippedDirName(u.lastPathComponent) { en.skipDescendants() }; continue }
                    files += 1
                    if let t = v?.contentModificationDate?.timeIntervalSince1970, t > last { last = t }
                    if files >= 2000 { break }
                }
            }
            rows.append((Indexer.nfc(n), files, last))
        }
        return rows.sorted { $0.2 > $1.2 }.prefix(12).map { ["name": $0.0, "files": $0.1, "lastLabel": WorkMapText.daysAgo($0.2, now: now)] }
    }
}
