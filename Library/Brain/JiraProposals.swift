import Foundation

// v0.8 §6.1 — Jira 변경 제안 (E3). suggestions 표를 그대로 쓴다:
//   kind='jira', doc_id = 티켓 문서 id(create는 NULL), path = 키(create는 프로젝트 키), rule_key = 'jira', reasons = [reason], origin = "mcp:<이름>",
//   payload = {op, key, docId, sourceId, to, body, project, issueType, summary, description, run, title, status,
//              (반영 뒤) result, uncertain, edited}
// 상태: pending → applying → applied | failed (failed → applying 다시 가능) · rejected · expired(7일) · withdrawn(같은 제안으로 바꿔 끼움).
// 사서는 Jira를 직접 부르지 않는다. 반영은 JiraApply가 jiraBegin → JiraWriter → jiraFinish 순서로 한다.
// 안전:
// - 반영 시작(applying)은 조건부 UPDATE(… WHERE state IN ('pending','failed'))로 한 제안에 한 번만 이긴다(같은 프로세스·다른 프로세스 모두).
//   jira 행의 상태는 늘 조건부 UPDATE로만 바꾼다(읽고 통째로 다시 쓰는 setState를 쓰지 않는다 — 다른 프로세스의 전환을 덮지 않게).
// - applying으로 10분 넘게 남은 것(반영하던 프로세스가 죽음)은 failed("반영 결과를 확인하지 못했어요 — Jira에서 확인해 주세요")로 바꾸고
//   uncertain을 표시한다. 다시 반영할 때 JiraWriter가 같은 댓글·같은 새 티켓이 이미 있는지 먼저 본다.
// - 바로 실행(apply_changes)과 섞이지 않는다: 이동·휴지통 경로는 kind='jira' 행을 건드리지 않고, decide(approve)는 jira 카드를 받지 않는다.

extension Organizer {

    static let jiraOps: Set<String> = ["transition", "comment", "create"]
    static let jiraPerCall = 10
    static let jiraPerDay = 30
    static let jiraStaleApplying: Double = 600                 // 10분
    static let jiraNote = "Synapse 정리함에서 사용자가 승인해야 Jira에 반영돼요."

    // MARK: 값 다듬기

    private static func text(_ v: Any?) -> String { ((v as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 실행 id(SYNAPSE_RUN_ID 등): 영문·숫자·_·- 64자 이내만 받는다. 아니면 nil.
    static func cleanRunId(_ raw: String?) -> String? {
        guard let r = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty, r.count <= 64,
              r.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-") }) else { return nil }
        return r
    }

    /// 제목 앞의 "KEY · "를 뗀다.
    static func jiraBareTitle(_ title: String, key: String) -> String {
        for sep in [" · ", " - ", ": ", " "] where title.hasPrefix(key + sep) { return String(title.dropFirst(key.count + sep.count)) }
        return title
    }

    // MARK: 색인

    /// 키가 같은 Jira 문서들(켜진 출처만 — ctx.docs가 이미 거른다).
    func jiraDocs(key: String) -> [BrainDoc] {
        ctx.docs.filter { $0.kind == "jira" && WorkModel.jiraKey($0)?.uppercased() == key }
    }

    /// 색인에 있는 Jira 프로젝트 키 → 그 프로젝트 문서가 있는 출처 id들.
    func jiraProjectSources() -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for d in ctx.docs where d.kind == "jira" {
            guard let k = WorkModel.jiraKey(d) else { continue }
            out[WorkModel.issueProject(k).uppercased(), default: []].insert(d.sourceId)
        }
        return out
    }

    /// Jira에 쓸 수 있는 출처(켜진 Atlassian API 토큰·MCP 연결).
    func jiraWritableSource(_ id: String) -> SourceConfig? {
        ctx.sources().first { $0.id == id && $0.enabled && ($0.kind == .atlassian || $0.kind == .mcp) }
    }

    // MARK: 같은 제안

    /// 바꿔 끼우기 기준: transition = 키·상태, comment = 키, create = 프로젝트·요약.
    static func jiraReplaceKey(_ p: [String: Any]) -> String {
        let key = (p["key"] as? String) ?? ""
        switch p["op"] as? String {
        case "transition": return "transition|\(key)|" + JiraWriter.statusKey((p["to"] as? String) ?? "")
        case "comment": return "comment|\(key)"
        default: return "create|\((p["project"] as? String) ?? "")|" + JiraWriter.statusKey((p["summary"] as? String) ?? "")
        }
    }

    /// 이미 반영한 것과 같은지(24시간 안 중복 막기): comment = 키·본문, create = 프로젝트·요약. transition은 지금 상태로 막으므로 nil.
    static func jiraSameKey(_ p: [String: Any]) -> String? {
        switch p["op"] as? String {
        case "comment": return "comment|\((p["key"] as? String) ?? "")|" + JiraWriter.normalizedBody((p["body"] as? String) ?? "")
        case "create": return jiraReplaceKey(p)
        default: return nil
        }
    }

    /// 사람이 읽는 한 줄: "PROJ-1 상태를 ‘완료’로 바꾸기" · "PROJ-1에 댓글 달기" · "PROJ에 새 티켓 만들기: 요약"
    static func jiraWhat(_ p: [String: Any]) -> String {
        let key = (p["key"] as? String) ?? ""
        switch p["op"] as? String {
        case "transition":
            let to = (p["to"] as? String) ?? ""
            return "\(key) 상태를 ‘\(to)’\(JiraWriter.ro(to)) 바꾸기"
        case "comment": return "\(key)에 댓글 달기"
        default: return "\((p["project"] as? String) ?? "")에 새 티켓 만들기: \((p["summary"] as? String) ?? "")"
        }
    }

    static func jiraStateMessage(_ state: String) -> String {
        switch state {
        case "applying": return "이미 반영하고 있어요"
        case "applied": return "이미 반영한 제안이에요"
        case "rejected": return "거절한 제안이에요"
        case "expired": return "7일이 지나 만료된 제안이에요. 다시 제안해 주세요"
        case "withdrawn": return "새 제안으로 바뀐 제안이에요. 정리함을 다시 열어 주세요"
        case "": return "Jira 제안을 찾지 못했어요"
        default: return "반영할 수 없는 제안이에요"
        }
    }

    // MARK: 제안 받기 (MCP propose_jira_changes · 브리지 jiraPropose · CLI)

    /// 결과: {ok, accepted:[{index, id, what, replaced?}], rejected:[{index, reason}], note}
    func proposeJira(items: [[String: Any]], origin: String, runId: String?) -> [String: Any] {
        let o = Organizer.mcpOrigin(origin)
        let note = Organizer.jiraNote
        if ctx.isStopped { return ["ok": false, "error": "사서가 멈춰 있어서 Jira 제안을 받지 않았어요. 사용자가 Synapse에서 다시 시작해야 해요."] }
        if items.isEmpty { return ["ok": false, "error": "제안 목록이 비어 있어요"] }
        if items.count > Organizer.jiraPerCall {
            return ["ok": true, "accepted": [], "rejected": items.indices.map { ["index": $0, "reason": "한 번에 \(Organizer.jiraPerCall)개까지만 받아요"] },
                    "note": note]
        }
        jiraHousekeeping()
        let run = Organizer.cleanRunId(runId)
        var used = jiraUsedToday(origin: o)
        var accepted: [[String: Any]] = [], rejected: [[String: Any]] = []
        for (i, item) in items.enumerated() {
            let v = jiraValidate(item, origin: o)
            guard var p = v.payload else { rejected.append(["index": i, "reason": v.error ?? "받을 수 없어요"]); continue }
            if let why = jiraDuplicateOfApplied(p) { rejected.append(["index": i, "reason": why]); continue }
            if used >= Organizer.jiraPerDay {
                rejected.append(["index": i, "reason": "오늘은 이 출처에서 Jira 제안을 \(Organizer.jiraPerDay)개까지만 받아요. 내일 다시 올려 주세요"])
                continue
            }
            if let r = run { p["run"] = r }
            // 같은 key·op(·to)가 대기 중이면 바꿔 끼운다 — 출처와 상관없이 가장 새 제안 하나만 남긴다
            let rk = Organizer.jiraReplaceKey(p)
            var replaced = false
            for old in suggestions("kind='jira' AND state='pending'") where Organizer.jiraReplaceKey(old.payload) == rk {
                let n = (try? ctx.db.sql.run("UPDATE suggestions SET state='withdrawn', decided=? WHERE id=? AND kind='jira' AND state='pending'",
                                             [.double(nowTS), .text(old.id)])) ?? 0
                if n > 0 { replaced = true }
            }
            let key = (p["key"] as? String) ?? (p["project"] as? String) ?? ""
            let s = OrgSuggestion(id: newID("j:", key + "\n" + o + "\n" + rk), kind: "jira", docId: p["docId"] as? String, path: key, payload: p,
                                  confidence: 0.9, reasons: [v.reason], origin: o, ruleKey: "jira", state: "pending", created: nowTS,
                                  decided: nil, batchId: nil, cooldownUntil: nil, error: nil)
            save(s)
            used += 1
            let what = Organizer.jiraWhat(p)
            ctx.log("propose", "\(Organizer.originLabel(o)): Jira \(what)", origin: Organizer.logOrigin(o), ref: s.id)
            var a: [String: Any] = ["index": i, "id": s.id, "what": what]
            if replaced { a["replaced"] = true }
            accepted.append(a)
        }
        if !accepted.isEmpty { ctx.emit(.pending) }
        return ["ok": true, "accepted": accepted, "rejected": rejected, "note": note]
    }

    /// 오늘(자정 기준) 이 출처가 올린 Jira 제안 수. 바꿔 끼워진 것·거절된 것도 센다(하루 한도는 올린 횟수다).
    func jiraUsedToday(origin o: String) -> Int {
        var n = 0
        try? ctx.db.sql.query("SELECT count(*) FROM suggestions WHERE kind='jira' AND origin=? AND created>=?",
                              [.text(o), .double(startOfToday)]) { n = Int($0.int(0)) }
        return n
    }

    /// 같은 댓글·같은 새 티켓을 24시간 안에 이미 반영했으면 그 이유.
    private func jiraDuplicateOfApplied(_ p: [String: Any]) -> String? {
        guard let k = Organizer.jiraSameKey(p) else { return nil }
        for s in suggestions("kind='jira' AND state='applied' AND decided>=?", [.double(nowTS - 86400)]) where Organizer.jiraSameKey(s.payload) == k {
            return (p["op"] as? String) == "comment" ? "같은 댓글을 24시간 안에 이미 달았어요" : "같은 티켓을 24시간 안에 이미 만들었어요"
        }
        return nil
    }

    /// 항목 하나 검사 → payload(실행 id 없이)와 이유. 틀리면 error.
    private func jiraValidate(_ item: [String: Any], origin o: String) -> (payload: [String: Any]?, reason: String, error: String?) {
        let op = Organizer.text(item["op"]).lowercased()
        var reason = String(Organizer.text(item["reason"]).replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ").prefix(200))
        if reason.isEmpty { reason = Organizer.originLabel(o) + "이에요" }
        func bad(_ m: String) -> ([String: Any]?, String, String?) { (nil, reason, m) }
        guard Organizer.jiraOps.contains(op) else { return bad("op는 transition · comment · create 중 하나여야 해요") }
        var p: [String: Any] = ["op": op]
        if op == "create" {
            let project = Organizer.text(item["project"]).uppercased()
            guard JiraWriter.isProjectKey(project) else { return bad("create에는 project(예: PROJ)가 필요해요") }
            let srcs = jiraProjectSources()[project] ?? []
            guard !srcs.isEmpty else { return bad("색인에 없는 Jira 프로젝트예요: \(project)") }
            guard srcs.count == 1, let sid = srcs.first else { return bad("같은 프로젝트가 여러 Atlassian 연결에 있어요: \(project)") }
            guard jiraWritableSource(sid) != nil else { return bad("이 프로젝트의 Atlassian 연결을 쓸 수 없어요") }
            let summary = Organizer.text(item["summary"]).replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
            guard (1...200).contains(summary.count) else { return bad("create의 summary는 1~200자여야 해요") }
            let description = Organizer.text(item["description"])
            guard description.count <= 8000 else { return bad("create의 description은 8,000자 이하여야 해요") }
            var type = Organizer.text(item["issueType"] ?? item["issue_type"])
            if type.isEmpty { type = "작업" }
            guard type.count <= 50, !type.contains("\n") else { return bad("issue_type이 너무 길어요") }
            p["project"] = project; p["sourceId"] = sid; p["summary"] = summary; p["issueType"] = type; p["title"] = summary
            if !description.isEmpty { p["description"] = description }
            return (p, reason, nil)
        }
        let key = Organizer.text(item["key"]).uppercased()
        guard JiraWriter.isIssueKey(key) else { return bad("\(op)에는 key(예: PROJ-123)가 필요해요") }
        var docs = jiraDocs(key: key)
        let docArg = Organizer.text(item["doc_id"] ?? item["docId"])
        if !docArg.isEmpty {
            docs = docs.filter { $0.id == docArg }
            if docs.isEmpty { return bad("doc_id가 \(key) 티켓 문서가 아니에요") }
        }
        guard let doc = docs.first else { return bad("색인에 없는 Jira 키예요: \(key) — get_tickets·search_notes가 돌려준 키만 받아요") }
        if Set(docs.map { $0.sourceId }).count > 1 { return bad("같은 키가 여러 Atlassian 연결에 있어요. doc_id를 함께 주세요: \(key)") }
        guard jiraWritableSource(doc.sourceId) != nil else { return bad("이 티켓의 Atlassian 연결을 쓸 수 없어요") }
        p["key"] = key; p["docId"] = doc.id; p["sourceId"] = doc.sourceId; p["project"] = WorkModel.issueProject(key)
        p["title"] = Organizer.jiraBareTitle(doc.title, key: key)
        let status = (doc.meta["status"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !status.isEmpty { p["status"] = status }
        if op == "transition" {
            let to = Organizer.text(item["to"])
            guard !to.isEmpty else { return bad("transition에는 to(바꿀 상태 이름)가 필요해요") }
            guard to.count <= 100, !to.contains("\n") else { return bad("to는 한 줄 100자 이하여야 해요") }
            if !status.isEmpty && JiraWriter.statusKey(status) == JiraWriter.statusKey(to) {
                return bad("\(key)\(JiraWriter.eun(key)) 이미 ‘\(status)’ 상태예요")
            }
            p["to"] = to
        } else {
            let body = Organizer.text(item["body"])
            guard (1...4000).contains(body.count) else { return bad("comment의 body는 1~4,000자여야 해요") }
            p["body"] = body
        }
        return (p, reason, nil)
    }

    // MARK: 수명 — 만료·멈춘 반영 복구 (읽기 전에 부른다. 바꿀 것이 없으면 쓰지 않는다)

    func jiraHousekeeping() {
        recoverStaleJira()
        expireJira()
    }

    /// applying으로 10분 넘게 남은 제안 → failed + uncertain (반영하던 프로세스가 죽었다).
    func recoverStaleJira() {
        let cut = nowTS - Organizer.jiraStaleApplying
        for s in suggestions("kind='jira' AND state='applying' AND decided<?", [.double(cut)]) {
            var p = s.payload
            p["uncertain"] = true
            let n = (try? ctx.db.sql.run("UPDATE suggestions SET state='failed', error=?, decided=?, payload=? WHERE id=? AND kind='jira' AND state='applying' AND decided<?",
                                         [.text(JiraWriteError.unknownResult), .double(nowTS), .text(BrainFormat.json(p)), .text(s.id), .double(cut)])) ?? 0
            if n > 0 {
                ctx.log("jira", "Jira 반영이 중간에 멈췄어요: \(Organizer.jiraWhat(s.payload)) — 반영됐는지 Jira에서 확인해 주세요",
                        origin: Organizer.logOrigin(s.origin), ref: s.id)
            }
        }
    }

    /// 7일 지난 대기 제안, 마지막 시도 뒤 7일 지난 실패 제안 → expired.
    func expireJira() {
        let cut = nowTS - Organizer.expireDays * 86400
        let cond = "kind='jira' AND ((state='pending' AND created<?) OR (state='failed' AND decided<?))"
        var n = 0
        try? ctx.db.sql.query("SELECT count(*) FROM suggestions WHERE \(cond)", [.double(cut), .double(cut)]) { n = Int($0.int(0)) }
        guard n > 0 else { return }
        _ = try? ctx.db.sql.run("UPDATE suggestions SET state='expired', decided=? WHERE \(cond)", [.double(nowTS), .double(cut), .double(cut)])
    }

    // MARK: 반영 시작·끝 (JiraApply가 부른다)

    /// pending·failed → applying. 이긴 쪽만 {ok, proposal}. 진 쪽·이미 처리된 것은 {ok:false, error, state}.
    func jiraBegin(id: String) -> [String: Any] {
        jiraHousekeeping()
        guard let s = suggestion(id), s.kind == "jira" else { return ["ok": false, "error": "Jira 제안을 찾지 못했어요"] }
        if ctx.isStopped { return ["ok": false, "error": "사서가 멈춰 있어서 Jira에 반영하지 않았어요. 다시 시작한 뒤 반영해 주세요.", "state": s.state] }
        // 한 제안에 한 번만: pending·failed인 행만 applying으로 바꾼다. 같은 때 두 번 불러도(다른 프로세스 포함) 이긴 쪽만 진행한다.
        let n = (try? ctx.db.sql.run("UPDATE suggestions SET state='applying', decided=?, error=NULL WHERE id=? AND kind='jira' AND state IN ('pending','failed')",
                                     [.double(nowTS), .text(id)])) ?? 0
        guard n == 1, let cur = suggestion(id), cur.state == "applying" else {
            let state = suggestion(id)?.state ?? ""
            return ["ok": false, "error": Organizer.jiraStateMessage(state), "state": state]
        }
        let p = cur.payload
        func v(_ k: String) -> Any { (p[k] as? String).map { $0 as Any } ?? NSNull() }
        return ["ok": true, "proposal": [
            "id": id, "op": v("op"), "key": v("key"), "docId": v("docId"), "sourceId": v("sourceId"), "to": v("to"), "body": v("body"),
            "project": v("project"), "issueType": v("issueType"), "summary": v("summary"), "description": v("description"), "run": v("run"),
            "retryUncertain": ((p["uncertain"] as? Bool) ?? false) || s.state == "failed",   // 실패한 것을 다시 할 때도 이미 반영됐는지 먼저 본다
        ] as [String: Any]]
    }

    /// applying → applied | failed, ai_log "jira". result: JiraWriter 결과(+ edited: 사용자가 고친 {body?, to?}, uncertain: 결과 모름).
    /// 성공은 실패·만료·거절로 바뀐 뒤에 와도 applied로 남긴다(실제로 Jira가 바뀌었다). 실패는 applying·failed일 때만 적는다.
    func jiraFinish(id: String, ok: Bool, message: String, result: [String: Any]?) -> [String: Any] {
        guard let s = suggestion(id), s.kind == "jira" else { return ["ok": false, "error": "Jira 제안을 찾지 못했어요"] }
        var p = s.payload
        let r = result ?? [:]
        let op = (p["op"] as? String) ?? ""
        // 사용자가 고친 글·상태는 성공·실패 모두 남긴다 — 다시 시도할 때 고친 내용이 그대로 보이게
        if let ed = r["edited"] as? [String: Any] {
            if op == "comment", let b = (ed["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), (1...4000).contains(b.count) {
                p["body"] = b; p["edited"] = true
            }
            if op == "transition", let t = (ed["to"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, t.count <= 100 {
                p["to"] = t; p["edited"] = true
            }
        }
        let msg = String(message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        let what = Organizer.jiraWhat(p)
        let n: Int
        if ok {
            var res: [String: Any] = [:]
            for k in ["key", "url", "to", "commentId", "issueType", "already", "project"] { if let v = r[k], !(v is NSNull) { res[k] = v } }
            res["message"] = msg.isEmpty ? what : msg
            p["result"] = res
            p["uncertain"] = nil
            n = (try? ctx.db.sql.run("UPDATE suggestions SET state='applied', decided=?, error=NULL, payload=? WHERE id=? AND kind='jira' AND state<>'applied'",
                                     [.double(nowTS), .text(BrainFormat.json(p)), .text(id)])) ?? 0
        } else {
            // 결과를 모르는 실패는 표시해 두고, 성공할 때까지 지우지 않는다(다시 반영할 때 먼저 확인한다)
            if (r["uncertain"] as? Bool) == true { p["uncertain"] = true }
            n = (try? ctx.db.sql.run("UPDATE suggestions SET state='failed', decided=?, error=?, payload=? WHERE id=? AND kind='jira' AND state IN ('applying','failed')",
                                     [.double(nowTS), .text(msg.isEmpty ? "반영하지 못했어요" : msg), .text(BrainFormat.json(p)), .text(id)])) ?? 0
        }
        guard n > 0 else { return ["ok": false, "error": "반영 중인 제안이 아니에요", "state": s.state] }
        if ok {
            ctx.log("jira", "Jira 반영: " + (msg.isEmpty ? what : msg), origin: Organizer.logOrigin(s.origin), ref: id)
        } else {
            ctx.log("jira", "Jira 반영 실패: \(what) — \(msg.isEmpty ? "반영하지 못했어요" : msg)", origin: Organizer.logOrigin(s.origin), ref: id)
        }
        ctx.emit(.pending); ctx.emit(.log)
        return ["ok": true, "id": id, "state": ok ? "applied" : "failed"]
    }

    // MARK: 거절 (decide)

    /// jira 카드의 decide: reject만 받는다(pending·failed → rejected). approve는 jiraApply로 안내한다.
    func decideJira(_ s: OrgSuggestion, action: String) -> [String: Any] {
        switch action {
        case "approve", "edit":
            return ["ok": false, "error": "Jira 변경은 jiraApply로 반영해요"]
        case "reject":
            let n = (try? ctx.db.sql.run("UPDATE suggestions SET state='rejected', decided=? WHERE id=? AND kind='jira' AND state IN ('pending','failed')",
                                         [.double(nowTS), .text(s.id)])) ?? 0
            guard n > 0 else { return ["ok": false, "error": Organizer.jiraStateMessage(suggestion(s.id)?.state ?? "")] }
            ctx.log("reject", "거절했어요: Jira \(Organizer.jiraWhat(s.payload))", origin: Organizer.logOrigin(s.origin), ref: s.id)
            ctx.emit(.pending)
            return ["ok": true, "applied": NSNull(), "undoable": false]
        default:
            return ["ok": false, "error": "Jira 제안은 반영하거나 거절할 수 있어요"]
        }
    }

    // MARK: 카드

    /// docs/V08.md §6.1 jira 카드. 아직 jira를 모르는 화면도 깨지지 않게 정리함 공용 카드 키(reasons·impact 등)도 넣는다.
    func jiraCard(_ s: OrgSuggestion) -> [String: Any] {
        let p = s.payload
        let key = p["key"] as? String
        let doc = (p["docId"] as? String).flatMap { ctx.doc(id: $0) }
        var title = (p["title"] as? String) ?? ""
        if let d = doc, let k = key { title = Organizer.jiraBareTitle(d.title, key: k) }
        if title.isEmpty { title = (p["summary"] as? String) ?? key ?? "" }
        var status: Any = NSNull()
        if let st = doc?.meta["status"], !st.isEmpty { status = st } else if let st = p["status"] as? String, !st.isEmpty { status = st }
        let result = p["result"] as? [String: Any]
        var url: Any = NSNull()
        if let u = result?["url"] as? String { url = u } else if let d = doc, d.location.hasPrefix("http") { url = d.location }
        func v(_ k: String) -> Any { (p[k] as? String).map { $0 as Any } ?? NSNull() }
        return ["id": s.id, "kind": "jira", "op": v("op"), "key": key ?? NSNull(), "docId": v("docId"), "title": title, "status": status,
                "to": v("to"), "body": v("body"), "project": v("project"), "issueType": v("issueType"), "summary": v("summary"),
                "description": v("description"), "reason": s.reasons.first ?? "", "origin": Organizer.cardOrigin(s.origin),
                "originLabel": Organizer.originLabel(s.origin), "run": v("run"), "state": s.state, "error": s.error ?? NSNull(),
                "created": BrainFormat.iso(Date(timeIntervalSince1970: s.created)), "createdLabel": clockLabel(s.created) ?? "",
                "url": url, "result": result ?? NSNull(), "edited": (p["edited"] as? Bool) ?? false, "uncertain": (p["uncertain"] as? Bool) ?? false,
                "reasons": s.reasons, "from": NSNull(), "alternatives": [], "confidence": "", "impact": NSNull(),
                "items": [], "rules": [], "violations": []]
    }

    /// 반영 중·실패한 Jira 제안 (정리함에 계속 보인다).
    func jiraInFlight() -> [OrgSuggestion] {
        suggestions("kind='jira' AND state IN ('applying','failed') ORDER BY created, id")
    }

    /// 정리함에 보이는 Jira 카드 수(대기·반영 중·실패).
    func jiraPendingCount() -> Int {
        var n = 0
        try? ctx.db.sql.query("SELECT count(*) FROM suggestions WHERE kind='jira' AND state IN ('pending','applying','failed')") { n = Int($0.int(0)) }
        return n
    }

    /// 그 실행(run)이 올린 제안 카드 — 이동·삭제·Jira, 모든 상태(바꿔 끼워진 것 빼고), 최근 순, 100개까지.
    /// 처리가 끝난 이동·삭제 카드는 충돌 검사를 하지 않는다(옮긴 뒤에는 목적지에 파일이 있는 게 맞으므로).
    func proposals(run: String) -> [[String: Any]] {
        guard let r = Organizer.cleanRunId(run) else { return [] }
        jiraHousekeeping()
        let rows = suggestions("payload LIKE ? AND state<>'withdrawn' ORDER BY created DESC, id DESC LIMIT 400", [.text("%\"run\":\"" + r + "\"%")])
            .filter { ($0.payload["run"] as? String) == r }
        var out: [[String: Any]] = []
        for s in rows.prefix(100) {
            switch s.kind {
            case "jira":
                out.append(jiraCard(s))
            case "move", "delete":
                var c = s.kind == "move" ? moveCard(s) : deleteCard(s)
                c["run"] = r
                c["state"] = s.state
                c["error"] = s.error ?? NSNull()
                c["created"] = BrainFormat.iso(Date(timeIntervalSince1970: s.created))
                if s.state != "pending", var imp = c["impact"] as? [String: Any] { imp["conflict"] = NSNull(); c["impact"] = imp }
                out.append(c)
            default:
                continue
            }
        }
        return out
    }
}
