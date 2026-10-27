import Foundation

// v0.7 E: 끝난 티켓을 켰을 때 그래프 밀도. 최근 N개만 문서 노드로 두고 나머지는 상태별 "요약 노드"로 접는다.
// 요약 노드: {id: "s:<묶음>:<상태>", kind: "summary", label: "완료 120", statusGroup, count, cluster, items: [최근 순 최대 200]}

extension Views {
    /// 문서 노드로 남기는 끝난 티켓 수(갱신 최근 순).
    static let doneKeep = 40
    /// 요약 노드에 실어 보내는 "끝난 티켓 목록" 최대 줄 수.
    static let doneListMax = 200
    /// 목록(최근 문서 등)을 자르는 개수. 넘으면 응답에 truncated를 더한다.
    static let listCap = 200

    private static let doneLabels: [String: String] = ["done": "완료", "dropped": "닫힘"]

    /// 응답의 `truncated`: 목록이 shown개에서 잘렸을 때만. total은 알면 전체 수, 싸게 셀 수 없으면 NSNull(= shown 넘음).
    static func truncation(shown: Int, total: Int?) -> [String: Any] {
        ["shown": shown, "total": total.map { $0 as Any } ?? NSNull()]
    }

    /// 끝난 티켓 `ended`를 최근 `keep`개(문서 노드)와 나머지(상태별 요약 노드)로 나눈다.
    /// 요약 노드와 같은 상태의 가장 최근 문서 노드 사이에 링크 하나를 둔다(같은 상태가 없으면 아무 문서 노드).
    static func densifyEnded(_ ended: [Int], clusterKey: String, keep: Int = doneKeep, snap s: Snapshot)
        -> (shown: [Int], summaries: [[String: Any]], links: [[String: Any]], summarized: Int) {
        let sorted = ended.sorted { s.docs[$0].m.modified > s.docs[$1].m.modified || (s.docs[$0].m.modified == s.docs[$1].m.modified && $0 < $1) }
        let shown = Array(sorted.prefix(keep))
        let rest = Array(sorted.dropFirst(keep))
        var summaries: [[String: Any]] = [], links: [[String: Any]] = []
        for g in ["done", "dropped"] {
            let part = rest.filter { s.tickets[$0]?.group == g }
            if part.isEmpty { continue }
            let id = "s:\(clusterKey):\(g)"
            let name = doneLabels[g] ?? g
            let items = part.prefix(doneListMax).map { i -> [String: Any] in
                let m = s.docs[i].m
                var d: [String: Any] = ["id": m.id, "title": m.title, "status": s.tickets[i]?.status ?? "", "statusGroup": g,
                                        "updated": iso(m.modified), "key": m.id.components(separatedBy: ":jira:").last ?? ""]
                if let c = m.meta["statusChanged"], !c.isEmpty { d["statusChanged"] = c }   // K1: 있으면 완료 시각으로 쓴다
                return d
            }
            summaries.append(["id": id, "kind": "summary", "label": "\(name) \(part.count)", "fullLabel": "끝난 티켓 · \(name) \(part.count)개",
                              "group": "", "statusGroup": g, "count": part.count, "cluster": clusterKey, "docKind": "jira",
                              "emphasis": "normal", "items": items, "itemsTotal": part.count])
            if let a = shown.first(where: { s.tickets[$0]?.group == g }) ?? shown.first {
                links.append(["source": id, "target": s.docs[a].m.id, "kind": "summary"])
            }
        }
        return (shown, summaries, links, rest.count)
    }
}
