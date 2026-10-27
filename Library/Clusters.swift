import Foundation

// v0.6 그래프: 티켓 상태 묶기(C1)와 묶음 지도(C2). 문서 수천 개를 한눈에 보도록 폴더·프로젝트·스페이스 단위의 "묶음"을 만든다.
// 묶음 배정은 스냅샷을 만들 때 한 번만 계산한다(문서 전체 기준 — 주제 필터·끝난 티켓 숨김과 무관하게 안정적).

extension Views {
    // MARK: 티켓 상태 (C1)

    struct Ticket {
        let status: String       // "Done", "To Do", "In Review" … (앞의 # · 공백을 뺀 원래 이름)
        let group: String        // todo | doing | blocked | done | dropped
        let mine: Bool
        let priority: String
        let issueType: String
        var ended: Bool { group == "done" || group == "dropped" }
        var open: Bool { group == "todo" || group == "doing" || group == "blocked" }
    }

    /// 티켓 상태 묶음:
    /// - 분류(statusCategory)가 done이면 결과는 done 또는 dropped뿐이다. 이름이 block·hold·보류·reject·cancel·취소·반려·아님·archived·drop 계열이면
    ///   dropped("닫힘" — 막히거나 버려진 채 닫힌 티켓), 나머지는 done.
    /// - 분류가 done이 아닐 때만 이름 우선 규칙(blocked → dropped → done → todo → doing), 그 밖은 indeterminate → doing, 나머지 → todo.
    static func statusGroup(name: String, category: String) -> String {
        let n = name.trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespacesAndNewlines)).lowercased()
        let words = Set(n.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        func has(_ keys: [String]) -> Bool { keys.contains { n.contains($0) } }
        func word(_ keys: [String]) -> Bool { keys.contains { words.contains($0) } }
        if category.lowercased() == "done" {
            return has(["block", "hold", "보류", "reject", "canc", "취소", "반려", "아님", "won't", "wont", "archived", "drop"]) ? "dropped" : "done"
        }
        if !n.isEmpty {
            if has(["block", "hold", "보류", "막힘", "대기"]) { return "blocked" }
            if has(["reject", "canc", "취소", "반려", "아님", "won't", "wont", "archived", "drop"]) { return "dropped" }
            if has(["done", "완료", "complete", "closed", "resolved", "release"]) { return "done" }
            if has(["to do", "to-do", "todo", "backlog", "오픈", "proposed", "할 일"]) || word(["new", "open"]) { return "todo" }
            if has(["progress", "implement", "진행", "review", "리뷰", "개발 중", "개발중"]) || word(["qa", "test"]) { return "doing" }
        }
        switch category.lowercased() {
        case "done": return "done"
        case "indeterminate": return "doing"
        default: return "todo"
        }
    }

    static func ticket(_ m: DocMetaRow) -> Ticket? {
        guard m.kind == "jira" else { return nil }
        let raw = m.meta["status"] ?? "", cat = m.meta["statusCategory"] ?? ""
        if raw.isEmpty && cat.isEmpty { return nil }
        let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespacesAndNewlines))
        return Ticket(status: name, group: statusGroup(name: raw, category: cat), mine: m.meta["mine"] == "1",
                      priority: m.meta["priority"] ?? "", issueType: m.meta["issuetype"] ?? "")
    }

    static func addTicketFields(_ t: Ticket?, to d: inout [String: Any]) {
        guard let t = t else { return }
        d["status"] = t.status; d["statusGroup"] = t.group; d["mine"] = t.mine
        d["priority"] = t.priority; d["issueType"] = t.issueType
    }

    // MARK: 묶음 배정 (C2)

    struct Cluster {
        let key: String
        let label: String
        let fullLabel: String
        let group: String          // 문서 대부분의 주제(색)
        let sourceKind: String     // folder | obsidian | mcp
        let docKind: String        // local | jira | confluence
        var docs: [Int]
    }

    static let maxClusters = 40
    static let otherSuffix = " · 기타"

    /// 묶음 키: 로컬은 원본 루트 기준 폴더 2단계(문서가 적은 최상위 폴더는 1단계, 3개 미만 2단계 묶음은 "<최상위> · 기타"),
    /// Jira는 jira:<프로젝트>, Confluence는 conf:<스페이스>. 최대 40개(작은 것부터 합친다).
    static func buildClusters(docs: [Snapshot.Doc], sources: [String: SourceConfig]) -> (clusters: [Cluster], of: [Int]) {
        if docs.isEmpty { return ([], []) }
        let isRemote: (DocMetaRow) -> Bool = { $0.kind == "jira" || $0.kind == "confluence" }
        let localSources = Set(docs.filter { !isRemote($0.m) }.map { $0.m.sourceId })
        let multi = localSources.count > 1
        func comps(_ m: DocMetaRow) -> [String] {
            var c = m.folder.split(separator: "/").map(String.init).filter { !$0.isEmpty }
            if multi { c.insert(sources[m.sourceId]?.name ?? "자료", at: 0) }
            return c
        }
        var topCount: [String: Int] = [:]
        for d in docs where !isRemote(d.m) { if let t = comps(d.m).first { topCount[t, default: 0] += 1 } }
        var keys = [String](repeating: "", count: docs.count)
        var subCount: [String: Int] = [:]
        for (i, d) in docs.enumerated() {
            let m = d.m
            if m.kind == "jira" { keys[i] = "jira:" + (m.group.isEmpty ? "기타" : m.group); continue }
            if m.kind == "confluence" { keys[i] = "conf:" + (m.group.isEmpty ? "기타" : m.group); continue }
            let c = comps(m)
            guard let top = c.first else { keys[i] = "(루트)"; continue }
            if (topCount[top] ?? 0) <= 12 { keys[i] = top }
            else if c.count >= 2 { keys[i] = top + "/" + c[1]; subCount[keys[i], default: 0] += 1 }
            else { keys[i] = top + otherSuffix }
        }
        for (i, k) in keys.enumerated() where k.contains("/") && (subCount[k] ?? 0) < 3 {
            keys[i] = String(k[k.startIndex..<k.firstIndex(of: "/")!]) + otherSuffix
        }
        // 문서가 3개 미만인 원격 묶음(작은 프로젝트·스페이스)은 "기타"로 합친다
        var remoteCount: [String: Int] = [:]
        for k in keys where k.hasPrefix("jira:") || k.hasPrefix("conf:") { remoteCount[k, default: 0] += 1 }
        for (i, k) in keys.enumerated() where (remoteCount[k] ?? 0) < 3 && (k.hasPrefix("jira:") || k.hasPrefix("conf:")) {
            keys[i] = k.hasPrefix("jira:") ? "jira:기타" : "conf:기타"
        }
        // 40개를 넘으면 가장 작은 묶음부터 같은 계열의 "기타"로 합친다
        func bucket(_ k: String) -> String {
            if k.hasPrefix("jira:") { return "jira:기타" }
            if k.hasPrefix("conf:") { return "conf:기타" }
            if k.hasSuffix(otherSuffix) || !k.contains("/") { return "(기타 폴더)" }
            return String(k[k.startIndex..<k.firstIndex(of: "/")!]) + otherSuffix
        }
        var counts: [String: Int] = [:]
        keys.forEach { counts[$0, default: 0] += 1 }
        var guardN = 0
        while counts.count > maxClusters && guardN < 400 {
            guardN += 1
            let order = counts.sorted { $0.value < $1.value || ($0.value == $1.value && $0.key < $1.key) }
            guard let pick = order.first(where: { bucket($0.key) != $0.key }) else { break }
            let to = bucket(pick.key)
            counts[to, default: 0] += pick.value; counts[pick.key] = nil
            for i in keys.indices where keys[i] == pick.key { keys[i] = to }
        }
        var members: [String: [Int]] = [:]
        for (i, k) in keys.enumerated() { members[k, default: []].append(i) }
        var out: [Cluster] = []
        for (k, ids) in members {
            var gc: [String: Int] = [:]
            for i in ids { gc[docs[i].m.group, default: 0] += 1 }
            let group = gc.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.first?.key ?? ""
            let first = docs[ids[0]].m
            let label: String, full: String
            if k.hasPrefix("jira:") { label = "Jira · " + k.dropFirst(5); full = "Jira 프로젝트 " + k.dropFirst(5) }
            else if k.hasPrefix("conf:") { label = "Confluence · " + k.dropFirst(5); full = "Confluence 스페이스 " + k.dropFirst(5) }
            else if let slash = k.firstIndex(of: "/") { label = String(k[k.index(after: slash)...]); full = k }
            else { label = k; full = k }
            let docKind = first.kind == "jira" ? "jira" : first.kind == "confluence" ? "confluence" : "local"
            out.append(Cluster(key: k, label: label, fullLabel: full, group: group,
                               sourceKind: sources[first.sourceId]?.kind.rawValue ?? "folder", docKind: docKind, docs: ids))
        }
        out.sort { $0.docs.count > $1.docs.count || ($0.docs.count == $1.docs.count && $0.key < $1.key) }
        var of = [Int](repeating: 0, count: docs.count)
        for (ci, c) in out.enumerated() { for i in c.docs { of[i] = ci } }
        return (out, of)
    }

    // MARK: 묶음 노드

    /// 한 묶음의 그래프 노드. `shown`은 그래프에 낼 문서(주제 필터·끝난 티켓 숨김 적용), `all`은 주제 필터만 적용한 문서.
    static func clusterNode(_ ci: Int, _ s: Snapshot, shown: [Int], all: [Int], emphasis: String) -> [String: Any] {
        let c = s.clusters[ci]
        let now = Date().timeIntervalSince1970
        var mix: [String: Int] = ["todo": 0, "doing": 0, "blocked": 0, "done": 0, "dropped": 0]
        for i in all { if let t = s.tickets[i] { mix[t.group, default: 0] += 1 } }
        let opens = shown.filter { s.tickets[$0]?.open == true }
        let rank: (Int) -> Int = { i in
            switch s.tickets[i]?.group ?? "" { case "doing": return 0; case "blocked": return 1; default: return 2 }
        }
        let openList = opens.sorted {
            rank($0) < rank($1) || (rank($0) == rank($1) && s.docs[$0].m.modified > s.docs[$1].m.modified)
        }.prefix(5).map { i -> [String: Any] in
            ["id": s.docs[i].m.id, "title": s.docs[i].m.title, "status": s.tickets[i]?.status ?? "",
             "statusGroup": s.tickets[i]?.group ?? "todo", "updated": iso(s.docs[i].m.modified)]
        }
        let recentDocs = shown.sorted { s.docs[$0].m.modified > s.docs[$1].m.modified }.prefix(5).map { i -> [String: Any] in
            var d: [String: Any] = ["id": s.docs[i].m.id, "title": s.docs[i].m.title, "updated": iso(s.docs[i].m.modified)]
            if let t = s.tickets[i] { d["status"] = t.status; d["statusGroup"] = t.group }
            return d
        }
        let latest = shown.map { s.docs[$0].m.modified }.max() ?? 0
        return ["id": "c:" + c.key, "key": c.key, "kind": "cluster", "label": c.label, "fullLabel": c.fullLabel, "group": c.group,
                "count": shown.count, "totalCount": all.count, "hiddenDone": all.count - shown.count,
                "openTickets": opens.count, "recent": shown.filter { now - s.docs[$0].m.modified < 7 * 86400 }.count,
                "latest": latest > 0 ? iso(latest) : "", "statusMix": mix,
                "sourceKind": c.sourceKind, "docKind": c.docKind, "emphasis": emphasis,
                "recentDocs": recentDocs, "openList": openList]
    }

    /// 두 묶음 사이 연결 세기: 문서 사이 명시 링크와 자동 연결 수의 합.
    static func clusterLinks(_ s: Snapshot, docs: [Int], keep: (Int) -> Bool) -> [[String: Any]] {
        var w: [Int64: Int] = [:]
        func add(_ a: Int, _ b: Int) {
            let x = s.clusterOf[a], y = s.clusterOf[b]
            if x == y { return }
            w[x < y ? Int64(x) << 32 | Int64(y) : Int64(y) << 32 | Int64(x), default: 0] += 1
        }
        for a in docs {
            for e in s.out[a] where keep(e.to) { add(a, e.to) }
            for r in s.related[a] where r.to > a && keep(r.to) { add(a, r.to) }
        }
        var per: [Int: [(Int, Int)]] = [:]
        for (k, v) in w {
            let x = Int(k >> 32), y = Int(k & 0xffff_ffff)
            per[x, default: []].append((y, v)); per[y, default: []].append((x, v))
        }
        var picked = Set<Int64>()
        for (x, list) in per {
            for (y, _) in list.sorted(by: { $0.1 > $1.1 || ($0.1 == $1.1 && $0.0 < $1.0) }).prefix(4) {
                picked.insert(x < y ? Int64(x) << 32 | Int64(y) : Int64(y) << 32 | Int64(x))
            }
        }
        let top = picked.sorted { (w[$0] ?? 0) > (w[$1] ?? 0) || ((w[$0] ?? 0) == (w[$1] ?? 0) && $0 < $1) }.prefix(120)
        return top.map { k in
            ["source": "c:" + s.clusters[Int(k >> 32)].key, "target": "c:" + s.clusters[Int(k & 0xffff_ffff)].key,
             "kind": "cluster", "weight": w[k] ?? 1]
        }
    }
}
