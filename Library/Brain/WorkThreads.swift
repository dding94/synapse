import Foundation
import CryptoKit

// §5.1 작업 흐름 묶기 — 이슈 → 세션(코드) → 폴더 순서, 결정적. 문서는 먼저 잡은 묶음에 남는다.

final class WorkGroup {
    var key: String
    var kind: String            // issue · session · code · folder · doc
    var title: String
    var project: String?
    var docIds: [String] = []
    private(set) var docSet: Set<String> = []
    var sessionIds: [String] = []
    var issueKeys: [String] = []

    init(key: String, kind: String, title: String) { self.key = key; self.kind = kind; self.title = title }
    func add(_ id: String) { if docSet.insert(id).inserted { docIds.append(id) } }
    func addSession(_ id: String) { if !sessionIds.contains(id) { sessionIds.append(id) } }
    var id: String { "t:" + WorkUtil.sha1(key).prefix(12) }
}

enum WorkUtil {
    static func sha1(_ s: String) -> String {
        Insecure.SHA1.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func lastComponent(_ p: String) -> String {
        let c = (p as NSString).lastPathComponent
        return c.isEmpty ? p : c
    }
    static func prefix(_ s: String, _ n: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= n ? t : String(t.prefix(n)) + "…"
    }
    /// 흐름 이름에 쓸 폴더 이름: 착지 폴더는 사람이 읽는 말로.
    static func folderLabel(_ name: String) -> String {
        switch name.lowercased() {
        case "_workspace": return "작업 공간"
        case "_inbox": return "받은 문서함"
        default: return name
        }
    }
    /// 1-Projects/<P>/<sub>/… 꼴에서 프로젝트 폴더 다음 한 단계. 파일이 바로 아래면 "".
    /// v0.9 §3.2: 부르는 쪽은 BrainDoc.paraPath(볼트 기준 → 출처 기준)를 넘긴다.
    static func subFolder(relPath: String) -> (projectFolder: String, sub: String)? {
        let comps = relPath.split(separator: "/").map(String.init)
        guard comps.count >= 3, ["1-Projects", "2-Areas", "4-Archive"].contains(comps[0]) else { return nil }
        return (comps[1], comps.count >= 4 ? comps[2] : "")
    }
}

/// 묶기에 필요한 입력.
struct WorkGroupInput {
    var active: [String]                          // 범위 안 문서 id (정렬됨)
    var states: [String: WorkDocState]
    var sessions: [WorkSession]
    var humanEdits: [(docId: String, ts: Double)] // 세션 시간대 판정용 사람 편집
    var notThisFolder: Set<String>
    var vaultRoots: [String]                      // 로컬 출처 루트 절대 경로 (표준 경로와 실제 경로 둘 다). v0.9: 감지한 볼트 루트가 앞에 온다
    var knownIssueKeys: [String] = []             // remote_state의 이슈 키
}

extension WorkModel {

    func eligible(_ id: String, _ states: [String: WorkDocState]) -> Bool {
        guard ctx.doc(id: id) != nil else { return false }
        if let s = states[id], s.excluded || s.aiArchive { return false }
        return true
    }

    static let notIssuePrefixes: Set<String> = ["ADR", "TN", "RFC", "UTF", "ISO", "SHA", "MD", "PR", "TODO", "HTTP", "TLS", "ES"]
    static func issueProject(_ key: String) -> String { key.split(separator: "-").first.map(String.init) ?? key }

    static func jiraKey(_ d: BrainDoc) -> String? {
        guard d.kind == "jira" else { return nil }
        return d.relPath.hasPrefix("jira:") ? String(d.relPath.dropFirst(5)) : d.relPath
    }

    func buildGroups(_ inp: WorkGroupInput) -> [WorkGroup] {
        var groups: [WorkGroup] = []
        var claimed: [String: Int] = [:]          // 문서 id → 묶음 번호
        var sessionGroup: [String: Int] = [:]
        let activeSet = Set(inp.active)
        let sessionsByID = Dictionary(inp.sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func claim(_ d: String, _ gi: Int) {
            guard claimed[d] == nil, eligible(d, inp.states) else { return }
            claimed[d] = gi; groups[gi].add(d)
        }
        func writtenDocs(_ s: WorkSession) -> [String] {
            var seen = Set<String>(), out: [String] = []
            for w in s.writes { if let d = ctx.doc(path: w.path), seen.insert(d.id).inserted { out.append(d.id) } }
            return out
        }

        // 1. 이슈 묶음
        var jiraDocByKey: [String: BrainDoc] = [:]
        for d in ctx.docs { if let k = WorkModel.jiraKey(d) { jiraDocByKey[k] = d } }
        var members: [String: (docs: Set<String>, sessions: Set<String>, jira: Bool)] = [:]
        var docKeys: [String: [String]] = [:]
        for id in inp.active {
            guard let d = ctx.doc(id: id) else { continue }
            var keys = d.issueKeys
            if let k = WorkModel.jiraKey(d) { keys.insert(k, at: 0); members[k, default: ([], [], false)].jira = true }
            docKeys[id] = keys
            for k in keys { members[k, default: ([], [], false)].docs.insert(id) }
        }
        for s in inp.sessions { for k in s.issueKeys { members[k, default: ([], [], false)].sessions.insert(s.id) } }
        func weight(_ k: String) -> Int {
            guard let m = members[k] else { return 0 }
            return (m.jira ? 100 : 0) + m.docs.count + m.sessions.count
        }
        // ADR-003·TN-001·UTF-8 같은 문서 번호는 이슈 키가 아니다. Jira가 연결돼 있으면 아는 프로젝트 키만 받는다.
        let jiraProjects = Set(jiraDocByKey.keys.map { WorkModel.issueProject($0) } + inp.knownIssueKeys.map { WorkModel.issueProject($0) })
        func isIssueKey(_ k: String) -> Bool {
            let p = WorkModel.issueProject(k)
            return jiraProjects.isEmpty ? !WorkModel.notIssuePrefixes.contains(p) : jiraProjects.contains(p)
        }
        let valid = Set(members.filter { isIssueKey($0.key) && ($0.value.jira || $0.value.docs.count + $0.value.sessions.count >= 2) }.map { $0.key })
        func choose(_ keys: [String]) -> String? {
            keys.filter { valid.contains($0) }.sorted { weight($0) != weight($1) ? weight($0) > weight($1) : $0 < $1 }.first
        }
        var issueIndex: [String: Int] = [:]
        func issueGroup(_ k: String) -> Int {
            if let i = issueIndex[k] { return i }
            let g = WorkGroup(key: "issue:\(k)", kind: "issue", title: jiraDocByKey[k]?.title ?? k)
            g.issueKeys = [k]
            groups.append(g); issueIndex[k] = groups.count - 1
            return groups.count - 1
        }
        for id in inp.active {
            let own = ctx.doc(id: id).flatMap { WorkModel.jiraKey($0) }
            guard let k = own ?? choose(docKeys[id] ?? []) else { continue }
            claim(id, issueGroup(k))
        }
        for s in inp.sessions {
            guard let k = choose(s.issueKeys) else { continue }
            let gi = issueGroup(k)
            groups[gi].addSession(s.id); sessionGroup[s.id] = gi
            for d in writtenDocs(s) { claim(d, gi) }
        }

        // 2. 세션 묶음 (세션 기록이 켜져 있을 때만 inp.sessions가 있다)
        var clusters: [(key: String, code: Bool, sessions: [WorkSession])] = []
        var clusterIndex: [String: Int] = [:]
        for s in inp.sessions where sessionGroup[s.id] == nil {
            let inVault = inp.vaultRoots.contains { s.cwd == $0 || s.cwd.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
            let key: String
            if inVault {
                let basis = s.title ?? s.firstAsk ?? s.id
                key = "session:\(s.cwd)|\(WorkUtil.sha1(basis).prefix(12))"
            } else {
                key = "code:\(WorkModel.codeRepoName(s.cwd))|\(s.branch)"
            }
            if let i = clusterIndex[key] { clusters[i].sessions.append(s) }
            else { clusterIndex[key] = clusters.count; clusters.append((key, !inVault, [s])) }
        }
        for c in clusters {
            var docs: [String] = []
            var seen = Set<String>()
            for s in c.sessions { for d in writtenDocs(s) where eligible(d, inp.states) && seen.insert(d).inserted { docs.append(d) } }
            if !c.code {
                var projects = Set(docs.compactMap { inp.states[$0]?.project })
                if let p = projectOf(cwd: c.sessions[0].cwd, roots: inp.vaultRoots, states: inp.states) { projects.insert(p) }
                for s in c.sessions where !projects.isEmpty {
                    let lo = s.started - 1800, hi = s.lastTs + 1800
                    for e in inp.humanEdits where e.ts >= lo && e.ts <= hi && activeSet.contains(e.docId) {
                        if let p = inp.states[e.docId]?.project, projects.contains(p), seen.insert(e.docId).inserted { docs.append(e.docId) }
                    }
                }
            }
            // 이슈 묶음과 문서를 공유하면 이슈 묶음으로 합친다
            var shared: [Int: Int] = [:]
            for d in docs { if let gi = claimed[d], groups[gi].kind == "issue" { shared[gi, default: 0] += 1 } }
            let gi: Int
            if let best = shared.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }).first {
                gi = best.key
            } else {
                let latest = c.sessions.max { $0.lastTs < $1.lastTs }!
                let titled = c.sessions.sorted { $0.lastTs > $1.lastTs }.first { $0.title != nil }?.title
                let title: String
                if c.code {
                    let repo = WorkModel.codeRepoName(latest.cwd)
                    title = titled ?? (latest.branch.isEmpty ? repo : "\(repo) · \(latest.branch)")
                } else {
                    let ask = requestTextOn ? c.sessions.first(where: { $0.firstAsk != nil })?.firstAsk.map { WorkUtil.prefix($0, 40) } : nil
                    let proj = docs.compactMap { inp.states[$0]?.project }.first ?? projectOf(cwd: latest.cwd, roots: inp.vaultRoots, states: inp.states)
                    title = titled ?? ask ?? proj ?? docs.first.flatMap { ctx.doc(id: $0)?.title } ?? WorkUtil.lastComponent(latest.cwd)
                }
                groups.append(WorkGroup(key: c.key, kind: c.code ? "code" : "session", title: title))
                gi = groups.count - 1
            }
            for s in c.sessions { groups[gi].addSession(s.id); sessionGroup[s.id] = gi }
            for d in docs { claim(d, gi) }
        }

        // 3. 폴더 묶음 (남은 문서)
        var folderIndex: [String: Int] = [:]
        let sourceByID = Dictionary(ctx.sources().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for id in inp.active where claimed[id] == nil {
            guard let d = ctx.doc(id: id), eligible(id, inp.states) else { continue }
            let key: String, title: String
            if inp.notThisFolder.contains(id) {
                key = "doc:\(id)"; title = d.title
            } else if let p = inp.states[id]?.project, !p.isEmpty {
                let sub = WorkUtil.subFolder(relPath: d.paraPath)?.sub ?? ""
                key = "folder:\(p)/\(sub)"; title = sub.isEmpty ? p : "\(p) · \(WorkUtil.folderLabel(sub))"
            } else if d.paraRel != nil, let abs = d.absPath, let vault = ctx.vaults.vault(forAbs: abs) {
                // v0.9 §3.2: 볼트 안 문서는 볼트 기준 앞 두 칸으로 묶는다(출처가 데스크톱이어도 "받은 문서함"). 키에 볼트 루트를 넣어 다른 볼트와 섞지 않는다
                let comps = (d.paraPath as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
                if comps.isEmpty {
                    key = "folder:\(vault):/"
                    title = "\((vault as NSString).lastPathComponent) · 루트 문서"
                } else {
                    let sub = comps.count > 1 ? comps[1] : ""
                    let top = WorkUtil.folderLabel(comps[0])
                    key = "folder:\(vault):\(comps[0])/\(sub)"
                    title = sub.isEmpty ? top : "\(top) · \(WorkUtil.folderLabel(sub))"
                }
            } else {
                let comps = d.folder.split(separator: "/").map(String.init)
                if comps.isEmpty {
                    key = "folder:\(d.sourceId)/"
                    title = sourceByID[d.sourceId].map { "\($0.name) · 루트 문서" } ?? "루트 문서"
                } else {
                    let sub = comps.count > 1 ? comps[1] : ""
                    let top = WorkUtil.folderLabel(comps[0])
                    let plain = sub.isEmpty ? top : "\(top) · \(WorkUtil.folderLabel(sub))"
                    if let label = WorkModel.folderSourceLabel(d, sourceByID[d.sourceId], top: comps[0]) {
                        // v0.8 §5.8-3: 볼트가 아닌 출처(프로젝트 폴더를 바로 연결·Confluence 공간)는 폴더 이름만으로 맥락이 없다
                        // ("시각화" → "서비스 · 시각화"). 출처마다 따로 묶는다(다른 출처의 같은 이름 폴더가 섞이지 않게).
                        key = "folder:\(d.sourceId):\(comps[0])/\(sub)"; title = "\(label) · \(plain)"
                    } else {
                        key = "folder:\(comps[0])/\(sub)"; title = plain
                    }
                }
            }
            let gi: Int
            if let i = folderIndex[key] { gi = i } else {
                groups.append(WorkGroup(key: key, kind: key.hasPrefix("doc:") ? "doc" : "folder", title: title))
                gi = groups.count - 1; folderIndex[key] = gi
            }
            claim(id, gi)
        }

        // 프로젝트·이슈 키 정리
        for g in groups {
            var count: [String: Int] = [:]
            for d in g.docIds { if let p = inp.states[d]?.project, !p.isEmpty { count[p, default: 0] += 1 } }
            g.project = count.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.first?.key
            if g.kind == "code" { g.project = nil }
            var keys = g.issueKeys
            for sid in g.sessionIds { for k in sessionsByID[sid]?.issueKeys ?? [] where !keys.contains(k) { keys.append(k) } }
            g.issueKeys = keys
            // v0.8 §5.8-3: 색인에 Jira 문서가 없어 이름이 키뿐인 이슈 흐름 — 세션 브랜치·작업 폴더·문서 제목에서 설명을 붙인다
            if g.kind == "issue", let k = g.key.hasPrefix("issue:") ? String(g.key.dropFirst(6)) : nil, g.title == k {
                let sess = g.sessionIds.compactMap { sessionsByID[$0] }.sorted { $0.lastTs > $1.lastTs }
                let docTitles = g.docIds.compactMap { ctx.doc(id: $0) }.filter { $0.isLocal }.map { $0.title }
                if let hint = WorkModel.issueHint(key: k, branches: sess.map { $0.branch }, cwds: sess.map { $0.cwd }, titles: docTitles) {
                    g.title = "\(k) · \(hint)"
                }
            }
            // v0.9: 폴더로 묶었는데 문서가 하나뿐이면 폴더 이름("받은 문서함")보다 그 문서 제목이 낫다
            if g.kind == "folder", g.sessionIds.isEmpty, g.docIds.count == 1, let d = ctx.doc(id: g.docIds[0]), !d.title.isEmpty {
                g.title = d.title
            }
        }
        return groups
    }

    /// v0.8 §5.8-3: 볼트 밖 작업 폴더의 이름. Codex 앱 대화 폴더(…/Codex/<날짜>/d)는 마지막 폴더 이름만으로는
    /// 뜻이 없고(대화마다 "d" 같은 이름) 날짜가 다른 대화가 한 흐름으로 섞이므로 "Codex 10/26 · d"로 쓴다. 그 밖은 마지막 폴더 이름.
    static func codeRepoName(_ cwd: String) -> String {
        let comps = cwd.split(separator: "/").map(String.init)
        if comps.count >= 3, comps[comps.count - 3] == "Codex" {
            let day = comps[comps.count - 2].split(separator: "-").compactMap { Int($0) }
            if day.count == 3, comps[comps.count - 2].count == 10 { return "Codex \(day[1])/\(day[2]) · \(comps[comps.count - 1])" }
        }
        return WorkUtil.lastComponent(cwd)
    }

    /// 폴더 묶음 이름 앞에 붙일 출처 이름. 볼트(옵시디언) 출처는 맨 윗 폴더가 PARA라 그대로 둔다(nil).
    static func folderSourceLabel(_ d: BrainDoc, _ src: SourceConfig?, top: String) -> String? {
        if !d.isLocal { return d.kind == "confluence" ? "Confluence" : (d.kind == "jira" ? "Jira" : nil) }
        guard let s = src, s.kind == .folder else { return nil }
        let name = WorkUtil.folderLabel(s.name.trimmingCharacters(in: .whitespaces))
        return name.isEmpty || name == WorkUtil.folderLabel(top) ? nil : name
    }

    /// 키뿐인 이슈 흐름의 설명. 브랜치 "feat/PROJ-12/login-page" · 작업 폴더 "proj-34-search-filter"
    /// → 키 뒤의 이름("login page"), 가장 자주 나온 것(같으면 최근 세션). 없으면 키가 든 문서 제목에서 키를 뗀 나머지.
    static func issueHint(key: String, branches: [String], cwds: [String], titles: [String]) -> String? {
        let esc = NSRegularExpression.escapedPattern(for: key)
        guard let rx = try? NSRegularExpression(pattern: "(?<![A-Za-z0-9])\(esc)(?![0-9])[-_/ ·:]*(.*)$", options: [.caseInsensitive]) else { return nil }
        func after(_ s: String) -> String? {
            let ns = s as NSString
            guard let m = rx.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)), m.range(at: 1).location != NSNotFound else { return nil }
            let rest = ns.substring(with: m.range(at: 1))
                .replacingOccurrences(of: #"[-_/]+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            return rest.count >= 2 ? WorkUtil.prefix(rest, 40) : nil
        }
        var count: [String: Int] = [:], order: [String] = []
        for s in branches + cwds.map({ WorkUtil.lastComponent($0) }) {
            guard let h = after(s) else { continue }
            if count[h] == nil { order.append(h) }
            count[h, default: 0] += 1
        }
        if let best = order.max(by: { (count[$0] ?? 0, -(order.firstIndex(of: $0) ?? 0)) < (count[$1] ?? 0, -(order.firstIndex(of: $1) ?? 0)) }) {
            return best
        }
        for t in titles { if let h = after(t) { return h } }
        return nil
    }

    /// 볼트 안 cwd의 프로젝트 (1-Projects/<P> 등). 그 폴더 문서의 doc_state.project(정규화된 이름)를 먼저 쓴다.
    /// v0.9 §3.2: roots에 볼트 루트가 들어온다(긴 것 먼저 본다). PARA 모양이 아닌 루트(데스크톱 출처)는 건너뛰고 다음 루트를 본다.
    func projectOf(cwd: String, roots: [String], states: [String: WorkDocState] = [:]) -> String? {
        let c = cwd.precomposedStringWithCanonicalMapping
        for r in roots.sorted(by: { $0.count > $1.count }) {
            let rn = r.precomposedStringWithCanonicalMapping
            let base = rn.hasSuffix("/") ? rn : rn + "/"
            guard c.hasPrefix(base) else { continue }
            let comps = String(c.dropFirst(base.count)).split(separator: "/").map(String.init)
            guard comps.count >= 2, ["1-Projects", "2-Areas", "4-Archive"].contains(comps[0]) else { continue }
            let prefix = comps[0] + "/" + comps[1] + "/"
            for (id, st) in states where st.project != nil {
                if let d = ctx.doc(id: id), d.paraPath.hasPrefix(prefix) { return st.project }
            }
            return comps[1]
        }
        return nil
    }
}
