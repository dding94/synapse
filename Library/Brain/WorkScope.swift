import Foundation

// v0.7 B: 홈 "급한 것"의 업무/개인 구분.
// 규칙으로 시작하고, 프로젝트마다 사용자가 한 번 눌러 바꾼다(brain 설정 projectScopes = JSON {"<프로젝트>": "work"|"personal"}).
// 거르기 값(전체·업무·개인)은 brain 설정 homeUrgentScope에 둔다.

extension BrainSetting {
    static let homeUrgentScope = "homeUrgentScope"   // "all"(기본) | "work" | "personal"
    static let projectScopes = "projectScopes"       // JSON — 사용자가 바꾼 프로젝트별 값
}

/// 표시용 글자 정리. 할 일 제목의 마크다운 기호를 뺀다(화면 src/home.js·week.js의 plain과 같은 규칙).
/// 원래 문구는 할 일 대조에 쓰이므로 저장값은 그대로 두고 응답에서만 바꾼다.
enum WorkText {
    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    private static let link = re(#"!?\[([^\]]*)\]\((?:[^()\s]|\([^)]*\))*(?:\s+"[^"]*")?\)"#)
    private static let wiki = re(#"\[\[([^\]]*)\]\]"#)
    private static let bold = re(#"(\*\*|__)(.+?)\1"#)
    private static let strike = re(#"~~(.+?)~~"#)
    private static let code = re("`+([^`]*)`+")
    private static let box = re(#"^\s*[-*]\s+\[[ xX]\]\s+"#)
    private static let spaces = re(#"\s{2,}"#)

    static func plain(_ s: String) -> String {
        func sub(_ rx: NSRegularExpression, _ t: String, _ tpl: String) -> String {
            rx.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: tpl)
        }
        var t = sub(link, s, "$1")
        // [[대상#절|별칭]] → 별칭, 별칭이 없으면 # 앞 이름
        let ns = t as NSString
        var out = "", last = 0
        for m in wiki.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let inner = ns.substring(with: m.range(at: 1))
            if let bar = inner.firstIndex(of: "|") { out += String(inner[inner.index(after: bar)...]) }
            else if let hash = inner.firstIndex(of: "#") { out += String(inner[..<hash]) }
            else { out += inner }
            last = m.range.location + m.range.length
        }
        t = out + ns.substring(from: last)
        t = sub(bold, t, "$2")
        t = sub(strike, t, "$1")
        t = t.replacingOccurrences(of: "**", with: "")
        t = sub(code, t, "$1")
        t = sub(box, t, "")
        t = sub(spaces, t, " ")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Jira 우선순위 이름 → highest | high | nil. Jira가 한국어로 설정돼 있으면 한국어 우선순위 이름(긴급·높음 …)도 읽는다.
    static func jiraPrio(_ name: String?) -> String? {
        switch (name ?? "").trimmingCharacters(in: .whitespaces).lowercased() {
        case "highest", "가장 높음", "최상", "긴급", "critical", "blocker": return "highest"
        case "high", "높음": return "high"
        default: return nil
        }
    }
}

/// 업무/개인 판단 한 건.
struct WorkScopeInfo {
    let key: String          // 사용자가 누르면 바뀌는 프로젝트 이름(프로젝트가 없으면 맨 윗 폴더)
    let label: String
    let scope: String        // 지금 적용되는 값 (work | personal)
    let auto: String         // 규칙값
    let user: Bool           // 사용자가 바꾼 값인가
    var real: Bool = true    // 실제 프로젝트인가(아니면 맨 윗 폴더를 뭉뚱그린 의사 프로젝트) — 화면이 "프로젝트를"/"폴더의 할 일을"을 가려 쓴다
}

/// 규칙과 사용자 값. 문서 수천 개를 한 번 훑어 만든다(홈을 그릴 때마다 한 번).
struct WorkScopeTable {
    var projectAuto: [String: String] = [:]   // 실제 프로젝트 → 규칙값
    var users: [String: String] = [:]
    var jiraProjects: Set<String> = []
    var states: [String: WorkDocState] = [:]
    var docs: (String) -> BrainDoc? = { _ in nil }
    var docAuto: [String: String] = [:]       // 프로젝트 없는 문서(의사 프로젝트) → 문서 단위 규칙값 캐시

    static let nameHints = ["회사", "업무"]

    static func label(_ key: String) -> String {
        if key == WorkScopeTable.rootKey { return "루트" }
        var k = key
        if k.hasPrefix("_") { k.removeFirst() }
        if let dash = k.firstIndex(of: "-"), k[..<dash].allSatisfy({ $0.isNumber }), !k[..<dash].isEmpty { k = String(k[k.index(after: dash)...]) }
        return k.isEmpty ? key : k
    }
    static let rootKey = "(루트)"

    /// 문서가 색인된 Jira 프로젝트 키(PROJ-123 …)를 언급하나. TN-003·ADR-011·GPT-4처럼 Jira 프로젝트가 아닌 접두는 센다.
    func mentionsJira(_ d: BrainDoc) -> Bool {
        d.issueKeys.contains { k in k.firstIndex(of: "-").map { jiraProjects.contains(String(k[..<$0])) } ?? false }
    }

    /// 경로에 Jira 키가 있나(`_workspace/PROJ-123/…`).
    func pathHasJiraKey(_ rel: String) -> Bool {
        for comp in rel.split(separator: "/") {
            guard let dash = comp.firstIndex(of: "-"), jiraProjects.contains(String(comp[..<dash])) else { continue }
            let rest = comp[comp.index(after: dash)...]
            if let first = rest.first, first.isNumber { return true }
        }
        return false
    }

    func nameHint(_ key: String) -> Bool { WorkScopeTable.nameHints.contains { key.contains($0) } }

    /// 문서의 프로젝트 키: doc_state.project, 없으면 맨 윗 폴더(루트 문서는 "(루트)").
    func projectKey(_ d: BrainDoc) -> (key: String, real: Bool) {
        if let p = states[d.id]?.project, !p.isEmpty { return (p, true) }
        let comps = d.paraPath.split(separator: "/")   // v0.9 §3.2: 볼트 기준 맨 윗 폴더(_workspace·_Inbox …)
        return comps.count > 1 ? (String(comps[0]), false) : (WorkScopeTable.rootKey, false)
    }

    func info(docId: String) -> WorkScopeInfo {
        guard let d = docs(docId) else { return WorkScopeInfo(key: "", label: "", scope: "personal", auto: "personal", user: false) }
        // Jira·Confluence는 업무
        if WorkModel.isRemote(d) {
            let key = (states[docId]?.project).flatMap { $0.isEmpty ? nil : $0 } ?? (d.folder.isEmpty ? (d.kind == "jira" ? "Jira" : "Confluence") : d.folder)
            let u = users[key]
            return WorkScopeInfo(key: key, label: key, scope: u ?? "work", auto: "work", user: u != nil)
        }
        let (key, real) = projectKey(d)
        let auto: String
        if real { auto = projectAuto[key] ?? (nameHint(key) ? "work" : "personal") }
        else { auto = (nameHint(key) || mentionsJira(d) || pathHasJiraKey(d.paraPath)) ? "work" : "personal" }
        let u = users[key]
        return WorkScopeInfo(key: key, label: WorkScopeTable.label(key), scope: u ?? auto, auto: auto, user: u != nil, real: real)
    }
}

extension WorkModel {

    func userProjectScopes() -> [String: String] {
        guard let o = BrainFormat.parse(ctx.db.setting(BrainSetting.projectScopes)) as? [String: String] else { return [:] }
        return o.filter { $0.value == "work" || $0.value == "personal" }
    }

    /// 프로젝트별 규칙값을 계산한다. 실제 프로젝트(1-Projects·2-Areas·4-Archive 아래)는 문서 묶음으로 정하고,
    /// 프로젝트가 없는 문서(_Inbox·_workspace·3-Resources·루트)는 문서마다 정한다(info 참고).
    func scopeTable(_ v: WorkViewData) -> WorkScopeTable {
        var t = WorkScopeTable()
        t.states = v.states
        let ctx = self.ctx
        t.docs = { ctx.doc(id: $0) }
        t.users = userProjectScopes()
        for d in ctx.docs where d.kind == "jira" {
            if let k = WorkModel.jiraKey(d), let dash = k.firstIndex(of: "-") { t.jiraProjects.insert(String(k[..<dash])) }
        }
        var total: [String: Int] = [:], hit: [String: Int] = [:]
        for d in ctx.docs where d.isLocal && !WorkModel.isRemote(d) {
            guard let p = v.states[d.id]?.project, !p.isEmpty else { continue }
            total[p, default: 0] += 1
            if t.mentionsJira(d) { hit[p, default: 0] += 1 }
        }
        for (p, n) in total {
            let m = hit[p] ?? 0
            // 색인된 Jira 키를 언급한 문서가 25% 이상이거나 5개 이상이면 업무. 이름에 회사·업무가 있어도 업무.
            t.projectAuto[p] = (m >= 5 || (n > 0 && m * 4 >= n) || t.nameHint(p)) ? "work" : "personal"
        }
        return t
    }

    /// 급한 할 일 후보에서 화면에 줄 것을 고른다: 최대 12개, 업무 먼저(각 묶음 안은 기존 정렬 그대로).
    /// 개인 항목이 업무에 밀려 하나도 안 보이지 않게 개인 몫을 4개까지 남긴다.
    func pickUrgent(_ all: [(WorkTask, Int?)], _ table: WorkScopeTable, limit: Int = 12) -> [(WorkTask, Int?)] {
        var work: [(WorkTask, Int?)] = [], personal: [(WorkTask, Int?)] = []
        for x in all { if table.info(docId: x.0.docId).scope == "work" { work.append(x) } else { personal.append(x) } }
        let personalQuota = min(personal.count, 4)
        let workTake = min(work.count, limit - personalQuota)
        let personalTake = min(personal.count, limit - workTake)
        return Array(work.prefix(workTake)) + Array(personal.prefix(personalTake))
    }

    /// 급한 것 항목에 업무/개인 필드를 더한다(계약 K3 + 되돌리기용 scopeAuto).
    func scopeFields(_ docId: String, _ table: WorkScopeTable) -> [String: Any] {
        let i = table.info(docId: docId)
        return ["scope": i.scope, "scopeAuto": i.auto, "scopeUser": i.user, "scopeKey": i.key, "projectLabel": i.label, "scopeReal": i.real]
    }

    /// home().urgentFilter: 거르기 값 · 업무/개인 개수 · 급한 것 안의 프로젝트.
    func urgentFilter(_ urgent: [[String: Any]]) -> [String: Any] {
        let raw = ctx.db.setting(BrainSetting.homeUrgentScope)
        let scope = (raw == "work" || raw == "personal") ? raw! : "all"
        var work = 0, personal = 0
        var order: [String] = [], rows: [String: (label: String, scope: String, n: Int)] = [:]
        for it in urgent {
            let sc = it["scope"] as? String ?? "personal"
            if sc == "work" { work += 1 } else { personal += 1 }
            guard let key = it["scopeKey"] as? String, !key.isEmpty else { continue }
            if var r = rows[key] { r.n += 1; rows[key] = r }
            else { rows[key] = (it["projectLabel"] as? String ?? key, sc, 1); order.append(key) }
        }
        let projects: [[String: Any]] = order.sorted { rows[$0]!.n != rows[$1]!.n ? rows[$0]!.n > rows[$1]!.n : $0 < $1 }.map {
            ["key": $0, "label": rows[$0]!.label, "scope": rows[$0]!.scope, "count": rows[$0]!.n]
        }
        return ["scope": scope, "counts": ["work": work, "personal": personal], "projects": projects]
    }

    /// 사서 메서드 setProjectScope (계약 K3). scope "auto"는 사용자 값을 지우고 규칙으로 되돌린다.
    func setProjectScope(project: String, scope: String) -> [String: Any] {
        let key = project.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.count <= 200 else { return ["ok": false, "error": "프로젝트 이름이 올바르지 않아요."] }
        guard ["work", "personal", "auto"].contains(scope) else { return ["ok": false, "error": "scope는 work · personal · auto 중 하나예요."] }
        var cur = userProjectScopes()
        let previous = cur[key] ?? "auto"
        if scope == "auto" { cur[key] = nil } else { cur[key] = scope }
        ctx.db.setSetting(BrainSetting.projectScopes, cur.isEmpty ? nil : BrainFormat.json(cur))
        return ["ok": true, "project": key, "scope": scope, "previous": previous]
    }

    /// 시험·진단용: 프로젝트마다 문서 수 · Jira 키 언급 문서 수 · 규칙값 · 적용값(업무 문서 수 포함).
    func scopeDiagnostics() -> [[String: Any]] {
        let v = loadView(), t = scopeTable(v)
        var rows: [String: (n: Int, hit: Int, work: Int, real: Bool, info: WorkScopeInfo)] = [:]
        for d in ctx.docs where d.isLocal && !WorkModel.isRemote(d) {
            let i = t.info(docId: d.id), real = t.projectKey(d).real
            var r = rows[i.key] ?? (0, 0, 0, real, i)
            r.n += 1; if t.mentionsJira(d) { r.hit += 1 }; if i.scope == "work" { r.work += 1 }
            rows[i.key] = r
        }
        return rows.sorted { $0.value.n != $1.value.n ? $0.value.n > $1.value.n : $0.key < $1.key }.map { k, r in
            ["project": k, "docs": r.n, "jiraMentions": r.hit, "workDocs": r.work, "pseudo": !r.real,
             "auto": r.real ? (t.projectAuto[k] ?? "personal") : "per-doc", "scope": r.real ? r.info.scope : "per-doc", "user": r.info.user]
        }
    }
}
