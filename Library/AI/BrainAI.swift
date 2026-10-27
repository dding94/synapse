import Foundation

// v0.8 정리(digest) 입력용 사서 입구 (docs/V08.md §5.1). E2 담당.
// Brain.swift·BrainContract.swift는 E3 담당이라 여기에 extension으로 둔다. 모두 안전판(safe)이다:
// 세션 요청 문장·세션 제목·작업 폴더를 넣지 않는다(MCP get_work_context와 같은 규칙). 아무 스레드에서나 불러도 된다.

extension Brain {
    /// 그 주(offset 0 = 이번 주, −1 = 지난주)의 이번 주 화면 자료 — 안전판(WorkModel.week(offset:safe:true, view:)).
    /// MCP get_work_context(week)와 같은 내용에서 heat·copyText를 빼고, 정리 입력에 필요한 문서 제목·Jira 키를 붙인다.
    func aiWeek(offset: Int) -> [String: Any] {
        aiRead { b in
            let w = b.work
            var r = w.week(offset: offset, safe: true, view: w.loadView())
            r["heat"] = nil
            r["copyText"] = nil
            r["done"] = (r["done"] as? [[String: Any]] ?? []).map { b.aiDecorate($0) }
            r["next"] = (r["next"] as? [[String: Any]] ?? []).map { b.aiDecorate($0) }
            r["lastPlan"] = (r["lastPlan"] as? [[String: Any]] ?? []).map { b.aiDecorate($0) }
            return r
        }
    }

    /// 홈 브리핑 입력 (§5.4): workContext(now) + 오늘까지·지난 기한의 열린 할 일(줄 번호 포함, 최대 15) + 열린 티켓 수.
    func aiHome() -> [String: Any] {
        aiRead { b in
            let w = b.work
            var r = w.workContext(period: "now")
            let v = w.loadView()
            let nowD = w.now
            var due: [(Int, WorkTask)] = []
            for t in v.open {
                if let s = v.states[t.docId], s.excluded || s.archived || s.aiArchive { continue }
                guard let d = t.due, let n = WorkTime.daysUntil(d, now: nowD), n <= 0, n >= -60 else { continue }
                due.append((n, t))
            }
            due.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1.id < $1.1.id }
            r["dueTasks"] = due.prefix(15).map { n, t -> [String: Any] in
                let doc = b.ctx.doc(id: t.docId)
                var o: [String: Any] = ["text": WorkText.plain(t.origin == "jira" ? (doc?.title ?? t.text) : t.text),
                                        "docId": t.docId, "line": t.line.map { $0 as Any } ?? NSNull(),
                                        "due": t.due ?? NSNull(), "days": n, "origin": t.origin]
                if let d = doc {
                    o["docTitle"] = d.title
                    if let k = WorkModel.jiraKey(d) { o["key"] = k }
                }
                return o
            }
            r["tickets"] = w.ticketCounts()
            return r
        }
    }

    /// 사서의 지금 시각 (시험용 SYNAPSE_NOW를 따른다).
    func aiNow() -> Date { ctx.env.fixedNow ?? Date() }

    /// v0.9 §5 정리 계획 입력: 정리 비서의 context()(§4.8)에 켜진 로컬 출처 루트를 붙인다(출처 루트를 옮기는 항목을 거르려고).
    /// 파일 내용·세션 대화 문장은 들어 있지 않다(인벤토리는 이름·개수·색인 제목만 본다).
    func aiTidy() -> [String: Any] {
        aiRead { b in
            var r = b.tidy.context()
            r["sourceRoots"] = b.ctx.sources().filter { $0.enabled }.compactMap { Indexer.sourceRoot($0) }
            return r
        }
    }

    /// 사서 설정 하나 (예: tidy.reviewDay). 사서 큐에서 읽는다.
    func aiSetting(_ key: String) -> String? {
        aiRead { b in b.ctx.db.setting(key) }
    }

    // MARK: 내부

    /// 사서 큐에서 읽는다. 먼저 공개 입구 중 가장 가벼운 것(claudeInstruction)을 불러 공개 입구가 하는 준비
    /// (색인 다시 열기·문서 목록 다시 읽기, CLI는 동기 갱신)를 똑같이 거친다. 이미 사서 큐 안이면 바로 부른다(교착 방지).
    private func aiRead<T>(_ f: @escaping (Brain) -> T) -> T {
        _ = claudeInstruction(context: "", id: nil)
        let q = ctx.queue
        if String(cString: __dispatch_queue_get_label(nil)) == q.label { return f(self) }
        return q.sync { f(self) }
    }

    /// 문서 id가 있는 항목에 문서 제목·Jira 키·문서 유형을 붙인다(사서 큐 안에서).
    private func aiDecorate(_ item: [String: Any]) -> [String: Any] {
        guard let id = item["docId"] as? String, let d = ctx.doc(id: id) else { return item }
        var o = item
        o["docTitle"] = d.title
        if o["key"] == nil, let k = WorkModel.jiraKey(d) { o["key"] = k }
        o["docKind"] = d.kind
        return o
    }
}
