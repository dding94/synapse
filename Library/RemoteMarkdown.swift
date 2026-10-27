import Foundation

// v0.7 D: 저장된 Confluence·Jira 평문 → 마크다운(표만 되살림).
// 연결기는 마크다운을 평문으로 줄여 저장한다 — 표 구분 줄·줄 끝 `|`가 빠지고 `| 항목 | 내용`만 남는다.
// 이 함수는 연이은 표 줄(2줄 이상)을 GFM 표로 바꾸고, 나머지는 렌더러가 마크다운으로 오해하지 않게만 손본다. 줄 수에 선형이다.
enum RemoteMarkdown {
    /// 표 줄의 칸 나누기. `|`로 시작하면 앞 `|`를 떼고 `|`로, 아니면 " | "로 나눈다. 표 줄이 아니면 nil.
    private static func cells(_ line: Substring) -> (cells: [String], lead: Bool)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") {
            var body = Substring(t.dropFirst())
            if body.hasSuffix("|") { body = body.dropLast() }
            return (body.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }, true)
        }
        guard t.contains(" | "), !isListLine(t) else { return nil }
        let parts = t.components(separatedBy: " | ").map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.count >= 2 ? (parts, false) : nil
    }

    private static func isListLine(_ t: String) -> Bool {
        guard let f = t.first else { return false }
        if "-*+•·".contains(f) { return t.dropFirst().first == " " }
        return false
    }

    private static func cellText(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "|", with: "\\|")
    }

    /// 마크다운 블록으로 해석되면 곤란한 줄 머리(인용·코드 울타리·가로줄)에 이스케이프를 붙인다.
    private static func guardLine(_ line: Substring) -> String {
        let t = line.drop(while: { $0 == " " })
        guard let f = t.first else { return String(line) }
        let lead = String(line.prefix(line.count - t.count))
        if f == ">" { return lead + "\\" + t }
        if t.hasPrefix("```") || t.hasPrefix("~~~") { return lead + "\\" + t }
        if "-*_".contains(f) {
            let s = t.filter { $0 != " " && $0 != "\t" }
            if s.count >= 3, Set(s).count == 1, Set(s).first == f { return lead + "\\" + t }
        }
        return String(line)
    }

    static func fromStoredText(_ text: String) -> String {
        let src = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = src.split(separator: "\n", omittingEmptySubsequences: false)
        var out: [String] = []
        out.reserveCapacity(lines.count + 16)
        var i = 0
        while i < lines.count {
            // 이 줄에서 시작하는 표 묶음을 찾는다: `|` 머리 줄끼리, 또는 칸 수가 같은 " | " 줄끼리
            if let first = cells(lines[i]) {
                var rows = [first.cells]
                var j = i + 1
                while j < lines.count, let c = cells(lines[j]), c.lead == first.lead, first.lead || c.cells.count == first.cells.count {
                    rows.append(c.cells); j += 1
                }
                if rows.count >= 2 {
                    let width = rows.map { $0.count }.max() ?? 1
                    func row(_ r: [String]) -> String {
                        "| " + (0..<width).map { $0 < r.count ? cellText(r[$0]) : "" }.joined(separator: " | ") + " |"
                    }
                    out.append(row(rows[0]))
                    out.append("|" + String(repeating: " --- |", count: width))
                    for r in rows.dropFirst() { out.append(row(r)) }
                    i = j; continue
                }
            }
            out.append(guardLine(lines[i]))
            i += 1
        }
        return out.joined(separator: "\n")
    }
}
