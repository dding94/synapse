import Foundation

// 세션 기록 줄 해석(Claude Code·Codex jsonl)과 요청 문장 가림 (§4.6). 형식은 비공개라 바뀔 수 있어 실패는 조용히 건너뛴다.

extension Signals {
    /// 한 번의 읽기에서 세션별로 모은 값.
    struct SessionAgg {
        var tool: String
        var cwd: String? = nil
        var branch: String? = nil
        var title: String? = nil          // custom-title
        var weakTitle: String? = nil      // 옛 summary
        var started: Double? = nil
        var lastTS: Double? = nil
        var asks = 0
        var writes = 0
        var firstAsk: (Double, String)? = nil
        var lastAsk: (Double, String)? = nil
        var keys = Set<String>()
        mutating func touch(_ ts: Double?) {
            guard let ts = ts else { return }
            started = min(started ?? ts, ts); lastTS = max(lastTS ?? ts, ts)
        }
    }

    final class SessionBatch {
        var aggs: [String: SessionAgg] = [:]
        var writes: [(session: String, path: String, ts: Double, op: String)] = []
        var asks: [(session: String, ts: Double, cwd: String?)] = []
        var parsed = 0, failed = 0
        var keepText = true
        func agg(_ id: String, _ tool: String) -> SessionAgg { aggs[id] ?? SessionAgg(tool: tool) }
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    static func parseTS(_ v: Any?) -> Double? {
        guard let s = v as? String else { return nil }
        return (isoFrac.date(from: s) ?? BrainFormat.isoFormatter.date(from: s))?.timeIntervalSince1970
    }

    static func absolute(_ p: String, cwd: String?) -> String {
        var path = (p as NSString).expandingTildeInPath
        if !path.hasPrefix("/"), let c = cwd { path = (c as NSString).appendingPathComponent(path) }
        // standardizingPath는 /private를 떼어 색인 경로와 어긋나므로 URL로 . · ..만 정리한다
        return URL(fileURLWithPath: path).standardized.path.precomposedStringWithCanonicalMapping
    }

    static let keyRE = try! NSRegularExpression(pattern: #"[A-Z][A-Z0-9]+-\d+"#)
    static func issueKeys(_ s: String?) -> [String] {
        guard let s = s, !s.isEmpty else { return [] }
        let ns = s as NSString
        return keyRE.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    // MARK: 요청 문장

    private static func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    /// 영숫자 경계: 한글 바로 뒤·앞에 붙어도 잡도록 \b 대신 쓴다.
    private static let L = #"(?<![A-Za-z0-9])"#, R = #"(?![A-Za-z0-9])"#
    /// (패턴, 바꿀 글, 확인) — 위에서부터 차례로. 확인이 있으면 그 덩어리가 맞을 때만 가린다.
    private static let redactions: [(NSRegularExpression, String, ((String) -> Bool)?)] = [
        (rx(#"(?i)(?:https?|ftp|obsidian|ssh)://[^\s<>"')\]]+"#), "‹도메인›", nil),
        (rx(#"[A-Za-z0-9._%+\-]+@[\p{L}\p{N}\-]+(?:\.[\p{L}\p{N}\-]+)*\.[\p{L}]{2,}"#), "‹메일›", nil),
        (rx(L + #"(?:sk-[A-Za-z0-9_\-]{8,}|sk_(?:live|test)_[A-Za-z0-9]{8,}|[rp]k_(?:live|test)_[A-Za-z0-9]{8,}|gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{16,}|xox[a-z]?[.\-][A-Za-z0-9.\-]{6,}|AKIA[0-9A-Z]{12,}|AIza[0-9A-Za-z_\-]{20,}|npm_[A-Za-z0-9]{20,}|glpat-[A-Za-z0-9_\-]{16,}|eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+(?:\.[A-Za-z0-9_\-]+)?)"#), "‹키›", nil),
        (rx(#"(?i)(bearer|basic)\s+[A-Za-z0-9._\-+/=]{12,}"#), "$1 ‹키›", nil),
        (rx(#"(?i)(password|passwd|pwd|secret|token|api[_-]?key|비밀번호|암호)(\s*[=:]\s*)\S+"#), "$1$2‹키›", nil),
        (rx(#"(?i)(?<![\p{L}\p{N}@._\-/])(?:www\.(?:[a-z0-9\-]+\.)+[a-z]{2,24}(?:/[^\s<>"')\]]*)?|(?:[a-z0-9\-]+\.)+[a-z]{2,24}/[^\s<>"')\]]*)"#), "‹도메인›",
         { m in m.lowercased().hasPrefix("www.") || Signals.looksLikeHost(m) }),
        (rx(#"(?<!\d)\d{6}-?[1-8]\d{6}(?!\d)"#), "‹번호›", nil),
        (rx(#"(?<!\d)01[016789]-?\d{3,4}-?\d{4}(?!\d)"#), "‹번호›", nil),
        (rx(L + #"[A-Fa-f0-9]{32,}"# + R), "‹키›", nil),
        (rx(#"(?<![A-Za-z0-9+/_=\-])[A-Za-z0-9+/_\-]{20,}={0,2}(?![A-Za-z0-9+/_=\-])"#), "‹키›", { Signals.looksRandom($0) }),
    ]

    /// `도메인.tld/경로`의 앞 조각이 호스트처럼 보이는가 (파일 이름 `README.md/…` 등은 빼려고 흔한 확장자 tld를 거른다).
    static func looksLikeHost(_ m: String) -> Bool {
        let host = m.split(separator: "/", maxSplits: 1).first.map(String.init) ?? m
        guard let tld = host.split(separator: ".").last?.lowercased() else { return false }
        let fileExt: Set<String> = ["md", "ts", "js", "py", "swift", "json", "txt", "html", "css", "sh", "rs", "go", "kt", "java",
                                    "yml", "yaml", "toml", "lock", "csv", "pdf", "png", "jpg", "tsx", "jsx", "vue", "rb", "sql"]
        return !fileExt.contains(tld)
    }

    /// 무작위 덩어리(키·비밀)처럼 보이는가: 대·소문자와 숫자가 섞이고 대문자+숫자가 5개 이상.
    static func looksRandom(_ s: String) -> Bool {
        var up = 0, low = 0, dig = 0
        for c in s.unicodeScalars {
            if c.properties.isUppercase { up += 1 } else if c.properties.isLowercase { low += 1 } else if c.value >= 48 && c.value <= 57 { dig += 1 }
        }
        return (up > 0 && low > 0 && dig > 0 && up + dig >= 5) || (dig >= 4 && low >= 8 && up == 0 && s.count >= 24)
    }

    /// 키·토큰·메일·URL·주민번호·전화번호 꼴을 가린다.
    static func redact(_ s: String) -> String {
        var out = s
        for (re, rep, ok) in redactions {
            let ns = out as NSString
            let ms = re.matches(in: out, range: NSRange(location: 0, length: ns.length))
            guard !ms.isEmpty else { continue }
            let mut = NSMutableString(string: out)
            for m in ms.reversed() {
                if let ok = ok, !ok(ns.substring(with: m.range)) { continue }
                let r = re.replacementString(for: m, in: out, offset: 0, template: rep)
                mut.replaceCharacters(in: m.range, with: r)
            }
            out = mut as String
        }
        return out
    }

    /// 첫 번째 비어 있지 않은 줄 → 가림 → 80자("…").
    static func askLine(_ text: String) -> String {
        let first = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        let red = redact(first)
        return red.count > 80 ? String(red.prefix(80)) + "…" : red
    }

    // MARK: Claude Code

    static let claudeNotAsk = ["<command-", "<local-command", "Caveat:", "<system-reminder>", "[Request interrupted"]
    static let claudeWriteTools: [String: String] = ["Write": "write", "Edit": "edit", "MultiEdit": "edit", "NotebookEdit": "edit"]

    func parseClaude(_ line: String, stem: String, into b: SessionBatch) {
        guard line.contains("\"user\"") || line.contains("\"tool_use\"") || line.contains("custom-title") || line.contains("\"summary\"") else { return }
        guard let data = line.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { b.failed += 1; return }
        b.parsed += 1
        let type = o["type"] as? String ?? ""
        let sid = "claude:" + ((o["sessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? stem)
        var a = b.agg(sid, "claude")
        let ts = Signals.parseTS(o["timestamp"])
        if let c = o["cwd"] as? String, !c.isEmpty { a.cwd = c }
        if let g = o["gitBranch"] as? String, !g.isEmpty { a.branch = g }
        switch type {
        case "user":
            a.touch(ts)
            let msg = o["message"] as? [String: Any]
            if (o["isMeta"] as? Bool) != true, let text = msg?["content"] as? String, let ts = ts {
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty && !Signals.claudeNotAsk.contains(where: { t.hasPrefix($0) }) { addAsk(&a, sid, ts, text, b) }
            }
        case "assistant":
            a.touch(ts)
            guard let ts = ts, let content = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] else { break }
            for c in content where c["type"] as? String == "tool_use" {
                guard let name = c["name"] as? String, let op = Signals.claudeWriteTools[name],
                      let input = c["input"] as? [String: Any],
                      let p = (input["file_path"] as? String) ?? (input["notebook_path"] as? String), !p.isEmpty else { continue }
                b.writes.append((sid, Signals.absolute(p, cwd: a.cwd), ts, op)); a.writes += 1
            }
        case "custom-title":
            if let t = o["customTitle"] as? String, !t.isEmpty { a.title = t; a.keys.formUnion(Signals.issueKeys(t)) }
        case "summary":
            if let t = o["summary"] as? String, !t.isEmpty { a.weakTitle = t }
        default:
            a.touch(ts)
        }
        b.aggs[sid] = a
    }

    private func addAsk(_ a: inout SessionAgg, _ sid: String, _ ts: Double, _ text: String, _ b: SessionBatch) {
        a.asks += 1
        let line = Signals.askLine(text)
        if a.firstAsk == nil || ts < a.firstAsk!.0 { a.firstAsk = (ts, line) }
        if a.lastAsk == nil || ts >= a.lastAsk!.0 { a.lastAsk = (ts, line) }
        if b.keepText { a.keys.formUnion(Signals.issueKeys(text)) }
        b.asks.append((sid, ts, a.cwd))
    }

    // MARK: Codex

    // v0.8: Codex 앱의 자동 승인 검토 세션은 첫 메시지가 에이전트 기록이다 — 사람의 요청이 아니므로 세지 않는다
    static let codexNotAsk = ["<environment_context>", "<user_instructions>", "<INSTRUCTIONS>", "# AGENTS.md",
                              "The following is the Codex agent history",
                              ">>> RETAINED USER INSTRUCTIONS"]   // v0.9: Codex가 이어 붙이는 지난 지시 안내문

    static func codexMeta(fromLine line: String) -> CodexMeta? {
        guard line.contains("session_meta"), let data = line.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              o["type"] as? String == "session_meta", let p = o["payload"] as? [String: Any],
              let id = p["id"] as? String else { return nil }
        return CodexMeta(id: id, cwd: p["cwd"] as? String, branch: (p["git"] as? [String: Any])?["branch"] as? String)
    }

    func parseCodex(_ line: String, file: String, into b: SessionBatch) {
        guard line.contains("session_meta") || line.contains("\"user\"") || line.contains("apply_patch") else { return }
        guard let data = line.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { b.failed += 1; return }
        b.parsed += 1
        let ts = Signals.parseTS(o["timestamp"])
        let p = o["payload"] as? [String: Any] ?? [:]
        if o["type"] as? String == "session_meta", let id = p["id"] as? String {
            let meta = CodexMeta(id: id, cwd: p["cwd"] as? String, branch: (p["git"] as? [String: Any])?["branch"] as? String)
            codexMeta[file] = meta
            var a = b.agg("codex:" + id, "codex")
            a.cwd = meta.cwd ?? a.cwd; a.branch = meta.branch ?? a.branch
            a.touch(ts ?? Signals.parseTS(p["timestamp"]))
            a.keys.formUnion(Signals.issueKeys(meta.branch))
            b.aggs["codex:" + id] = a
            return
        }
        guard o["type"] as? String == "response_item", let meta = codexMeta[file] else { return }
        let sid = "codex:" + meta.id
        var a = b.agg(sid, "codex")
        if a.cwd == nil { a.cwd = meta.cwd }
        if a.branch == nil { a.branch = meta.branch }
        a.touch(ts)
        let ptype = p["type"] as? String ?? ""
        if ptype == "message", p["role"] as? String == "user", let ts = ts, let content = p["content"] as? [[String: Any]] {
            for c in content where c["type"] as? String == "input_text" {
                guard let text = c["text"] as? String else { continue }
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty || Signals.codexNotAsk.contains(where: { t.hasPrefix($0) }) { continue }
                addAsk(&a, sid, ts, text, b); break
            }
        } else if (ptype == "custom_tool_call" || ptype == "function_call"), let ts = ts {
            let name = p["name"] as? String ?? ""
            var texts: [String] = []
            if let i = p["input"] as? String { texts.append(i) }
            if let args = p["arguments"] as? String {
                if let d = args.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) { Signals.strings(j, into: &texts) }
                else { texts.append(args) }
            }
            guard name == "apply_patch" || texts.contains(where: { $0.contains("*** Begin Patch") }) else { b.aggs[sid] = a; return }
            for t in texts {
                for l in t.split(separator: "\n") {
                    for (mark, op) in [("*** Add File: ", "patch"), ("*** Update File: ", "patch"), ("*** Delete File: ", "delete"), ("*** Move to: ", "patch")]
                    where l.hasPrefix(mark) {
                        let path = l.dropFirst(mark.count).trimmingCharacters(in: .whitespaces)
                        if !path.isEmpty { b.writes.append((sid, Signals.absolute(path, cwd: a.cwd), ts, op)); a.writes += 1 }
                    }
                }
            }
        }
        b.aggs[sid] = a
    }

    static func strings(_ j: Any, into out: inout [String]) {
        if let s = j as? String { out.append(s) }
        else if let a = j as? [Any] { a.forEach { strings($0, into: &out) } }
        else if let d = j as? [String: Any] { d.values.forEach { strings($0, into: &out) } }
    }
}
