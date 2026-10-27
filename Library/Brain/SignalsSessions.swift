import Foundation

// 세션 기록 증분 읽기·집계·보존·지우기 (§4.6).

extension Signals {
    static let sessionChunk = 8 * 1024 * 1024
    static let lastScanKey = "sessions.lastScan"

    /// (파일, 도구) — Claude: claudeDir/*/*.jsonl, Codex: codexDir/**/*.jsonl
    func sessionFiles() -> [(path: String, tool: String)] {
        let fm = FileManager.default
        var out: [(String, String)] = []
        if let root = ctx.env.claudeDir, let projects = try? fm.contentsOfDirectory(atPath: root.path) {
            for p in projects.sorted() where !p.hasPrefix(".") {
                let dir = root.appendingPathComponent(p).path
                guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for f in files.sorted() where f.hasSuffix(".jsonl") { out.append((dir + "/" + f, "claude")) }
            }
        }
        if let root = ctx.env.codexDir, let en = fm.enumerator(atPath: root.path) {
            var list: [String] = []
            while let rel = en.nextObject() as? String { if rel.hasSuffix(".jsonl") { list.append(root.path + "/" + rel) } }
            for f in list.sorted() { out.append((f, "codex")) }
        }
        return out
    }

    func scanSessions(budget: TimeInterval) -> Bool {
        lastScanChanged = false
        guard sessionsOn, !ctx.isStopped, sessionError == nil else { return false }
        let deadline = Date().addingTimeInterval(budget)
        var cursors: [String: (inode: Int64, offset: Int64)] = [:]
        try? db.query("SELECT file, inode, offset FROM session_cursor") { cursors[$0.text(0)] = ($0.int(1), $0.int(2)) }
        let batch = SessionBatch()
        batch.keepText = ctx.db.setting(BrainSetting.sessionsRequestText) != "0"
        var firstRead = false, more = false
        var cursorUpdates: [(String, Int64, Int64, Double)] = []
        for (path, tool) in sessionFiles() {
            guard let attr = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attr[.size] as? NSNumber)?.int64Value else { continue }
            let inode = (attr[.systemFileNumber] as? NSNumber)?.int64Value ?? 0
            let mtime = (attr[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            var offset = cursors[path]?.offset ?? 0
            if let c = cursors[path], c.inode != inode || size < c.offset {
                forgetSessions(file: path, tool: tool); offset = 0   // 파일이 바뀌었다: 처음부터
            }
            guard size > offset else { continue }
            if Date() > deadline { more = true; break }
            if offset == 0 { firstRead = true }
            guard let fh = FileHandle(forReadingAtPath: path) else { noteFileError(); continue }
            if tool == "codex" && offset > 0 && codexMeta[path] == nil {
                if let first = (try? fh.read(upToCount: 65536)).flatMap({ $0 }),
                   let line = String(data: first.prefix(while: { $0 != 0x0A }), encoding: .utf8) {
                    codexMeta[path] = Signals.codexMeta(fromLine: line)
                }
            }
            try? fh.seek(toOffset: UInt64(offset))
            let want = Int(min(size - offset, Int64(Signals.sessionChunk)))
            let data = (try? fh.read(upToCount: want)).flatMap { $0 } ?? Data()
            try? fh.close()
            guard let lastNL = data.lastIndex(of: 0x0A) else {
                if data.count >= Signals.sessionChunk {   // 8MB를 넘는 한 줄: 건너뛰고 나머지를 이어 읽는다
                    cursorUpdates.append((path, inode, offset + Int64(data.count), mtime)); more = true
                }
                continue   // 끝의 불완전한 줄은 다음 차례로
            }
            let body = data[data.startIndex...lastNL]
            let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            let before = (batch.parsed, batch.failed)
            for raw in body.split(separator: 0x0A, omittingEmptySubsequences: true) {
                guard let line = String(data: raw, encoding: .utf8) else { batch.failed += 1; continue }
                if tool == "claude" { parseClaude(line, stem: stem, into: batch) } else { parseCodex(line, file: path, into: batch) }
            }
            let ok = batch.parsed - before.0, bad = batch.failed - before.1
            if ok > 0 { fileErrorRun = 0 } else if bad > 0 { noteFileError() }
            cursorUpdates.append((path, inode, offset + Int64(body.count), mtime))
            if Int64(body.count) < size - offset { more = true }
            if sessionError != nil { break }
        }
        let newWrites = storeBatch(batch, cursors: cursorUpdates)
        ctx.db.setSetting(Signals.lastScanKey, BrainFormat.iso(now()))
        if !newWrites.isEmpty {
            reattribute(newWrites.map { ($0.session, $0.path, $0.ts) }, since: nowTS - (firstRead ? 30 : 1) * 86400)
            for w in newWrites {
                if let d = ctx.doc(path: w.path), d.paraPath.hasPrefix("4-Archive/") { refreshPathFeatures(d) }   // v0.9: 볼트 기준
            }
        }
        lastScanChanged = !batch.aggs.isEmpty || !newWrites.isEmpty
        return more && sessionError == nil
    }

    private func noteFileError() {
        fileErrorRun += 1
        if fileErrorRun >= 20 && sessionError == nil {
            sessionError = "세션 기록 형식이 바뀌어 읽기를 멈췄어요"
            ctx.log("session", sessionError!)
        }
    }

    /// 모은 값을 저장한다. 새로 들어간 AI 쓰기를 돌려준다.
    private func storeBatch(_ b: SessionBatch, cursors: [(String, Int64, Int64, Double)])
        -> [(session: String, path: String, ts: Double, op: String)] {
        let keepText = ctx.db.setting(BrainSetting.sessionsRequestText) != "0"
        var fresh: [(session: String, path: String, ts: Double, op: String)] = []
        var freshCount: [String: Int] = [:]
        try? db.transaction {
            for w in b.writes {
                var dup = false
                try? db.query("SELECT 1 FROM ai_writes WHERE session_id=? AND path=? AND ts=? LIMIT 1",
                              [.text(w.session), .text(w.path), .double(w.ts)]) { _ in dup = true }
                if dup { continue }
                _ = try? db.run("INSERT INTO ai_writes(session_id, path, ts, op) VALUES(?,?,?,?)",
                                [.text(w.session), .text(w.path), .double(w.ts), .text(w.op)])
                fresh.append(w); freshCount[w.session, default: 0] += 1
            }
            for (sid, a) in b.aggs { upsertSession(sid, a, newWrites: freshCount[sid] ?? 0, keepText: keepText) }
            for ask in b.asks {
                var near = false
                try? db.query("SELECT 1 FROM activity WHERE kind='ask' AND session_id=? AND ts BETWEEN ? AND ? LIMIT 1",
                              [.text(ask.session), .double(ask.ts - 60), .double(ask.ts + 60)]) { _ in near = true }
                if near { continue }   // 1분 안의 요청은 1건으로
                insertActivity(ts: ask.ts, docId: nil, path: ask.cwd, kind: "ask", actor: .human,
                               origin: ask.session.hasPrefix("codex:") ? "codex" : "claude", session: ask.session, detail: nil)
            }
            for c in cursors {
                _ = try? db.run("INSERT OR REPLACE INTO session_cursor(file, inode, offset, mtime, parser) VALUES(?,?,?,?,1)",
                                [.text(c.0), .int(c.1), .int(c.2), .double(c.3)])
            }
        }
        return fresh
    }

    private func upsertSession(_ sid: String, _ a: SessionAgg, newWrites: Int, keepText: Bool) {
        var old: (cwd: String?, branch: String?, keys: [String], title: String?, started: Double?, last: Double?,
                  first: String?, lastAsk: String?, lastAskTS: Double?, asks: Int, writes: Int)? = nil
        try? db.query("""
        SELECT cwd, branch, issue_keys, title, started, last_ts, first_ask, last_ask, last_ask_ts, asks, writes FROM ai_sessions WHERE id=?
        """, [.text(sid)]) { r in
            func t(_ i: Int32) -> String? { r.isNull(i) ? nil : r.text(i) }
            func d(_ i: Int32) -> Double? { r.isNull(i) ? nil : r.double(i) }
            old = (t(0), t(1), parseJSONArray(r.text(2)), t(3), d(4), d(5), t(6), t(7), d(8), Int(r.int(9)), Int(r.int(10)))
        }
        let title = a.title ?? old?.title ?? a.weakTitle
        let cwd = a.cwd ?? old?.cwd, branch = a.branch ?? old?.branch
        var keys = Set(old?.keys ?? []).union(a.keys)
        keys.formUnion(Signals.issueKeys(branch)); keys.formUnion(Signals.issueKeys(title))
        let started = [old?.started, a.started].compactMap { $0 }.min()
        let last = [old?.last, a.lastTS].compactMap { $0 }.max()
        var first = old?.first, lastAsk = old?.lastAsk, lastAskTS = old?.lastAskTS
        // 30일 넘은 요청 문장은 처음 읽을 때도 저장하지 않는다
        let fresh = nowTS - 30 * 86400
        if (old?.asks ?? 0) == 0, let f = a.firstAsk { first = keepText && f.0 >= fresh ? f.1 : nil }
        if let l = a.lastAsk, l.0 >= (lastAskTS ?? 0) { lastAsk = keepText && l.0 >= fresh ? l.1 : nil; lastAskTS = l.0 }
        func t(_ v: String?) -> SQLValue { v.map { .text($0) } ?? .null }
        func d(_ v: Double?) -> SQLValue { v.map { .double($0) } ?? .null }
        _ = try? db.run("""
        INSERT OR REPLACE INTO ai_sessions(id, tool, cwd, branch, issue_keys, title, started, last_ts, first_ask, last_ask,
          last_ask_ts, asks, writes) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, [.text(sid), .text(a.tool), t(cwd), t(branch), .text(jsonArray(keys.sorted())), t(title), d(started), d(last),
              t(first), t(lastAsk), d(lastAskTS), .int(Int64((old?.asks ?? 0) + a.asks)), .int(Int64((old?.writes ?? 0) + newWrites))])
    }

    /// 파일을 처음부터 다시 읽기 전에 그 파일의 세션 기록을 지운다(중복 방지).
    private func forgetSessions(file: String, tool: String) {
        var sid: String? = nil
        if tool == "claude" {
            sid = "claude:" + ((file as NSString).lastPathComponent as NSString).deletingPathExtension
        } else if let fh = FileHandle(forReadingAtPath: file) {
            if let d = (try? fh.read(upToCount: 65536)).flatMap({ $0 }),
               let line = String(data: d.prefix(while: { $0 != 0x0A }), encoding: .utf8),
               let m = Signals.codexMeta(fromLine: line) { sid = "codex:" + m.id; codexMeta[file] = m }
            try? fh.close()
        }
        guard let s = sid else { return }
        for sql in ["DELETE FROM ai_sessions WHERE id=?", "DELETE FROM ai_writes WHERE session_id=?",
                    "DELETE FROM activity WHERE kind='ask' AND session_id=?"] { _ = try? db.run(sql, [.text(s)]) }
    }

    // MARK: 보존·지우기

    func purgeOld() {
        let t = nowTS
        _ = try? db.run("UPDATE ai_sessions SET first_ask=NULL WHERE first_ask IS NOT NULL AND COALESCE(started, 0) < ?", [.double(t - 30 * 86400)])
        _ = try? db.run("UPDATE ai_sessions SET last_ask=NULL WHERE last_ask IS NOT NULL AND COALESCE(last_ask_ts, 0) < ?", [.double(t - 30 * 86400)])
        // v0.9: 예전에 요청으로 잘못 모은 Codex 안내문(codexNotAsk)을 지운다
        for p in Signals.codexNotAsk {
            for col in ["first_ask", "last_ask"] {
                _ = try? db.run("UPDATE ai_sessions SET \(col)=NULL WHERE substr(\(col), 1, ?)=?", [.int(Int64(p.count)), .text(p)])
            }
        }
        _ = try? db.run("DELETE FROM ai_writes WHERE ts < ?", [.double(t - 180 * 86400)])
        _ = try? db.run("DELETE FROM ai_sessions WHERE COALESCE(last_ts, 0) < ?", [.double(t - 180 * 86400)])
        _ = try? db.run("DELETE FROM activity WHERE kind='ask' AND ts < ?", [.double(t - 180 * 86400)])
    }

    /// requestText를 끄면 이미 모은 문장도 지우고, 이슈 키는 브랜치·세션 제목에서 나온 것만 남긴다.
    func dropRequestText() {
        var rows: [(String, String?, String?)] = []
        try? db.query("SELECT id, branch, title FROM ai_sessions") { rows.append(($0.text(0), $0.isNull(1) ? nil : $0.text(1), $0.isNull(2) ? nil : $0.text(2))) }
        for (id, branch, title) in rows {
            let keys = Set(Signals.issueKeys(branch) + Signals.issueKeys(title)).sorted()
            _ = try? db.run("UPDATE ai_sessions SET first_ask=NULL, last_ask=NULL, issue_keys=? WHERE id=?", [.text(jsonArray(keys)), .text(id)])
        }
    }

    static let lastPurgeKey = "signals.lastPurge"

    /// 하루 한 번 purgeOld (앱 타이머·CLI 동기 갱신 공용). 날짜 기준은 ctx.now().
    @discardableResult
    func purgeIfDue() -> Bool {
        let day = BrainFormat.dayKey(now())
        guard ctx.db.setting(Signals.lastPurgeKey) != day else { return false }
        purgeOld()
        ctx.db.setSetting(Signals.lastPurgeKey, day)
        return true
    }

    /// sessions.clear: 세션 표를 비우고, 세션 근거로 바뀐 작성자를 경로 추정으로 되돌린다.
    func clearSessions() {
        var docs = Set<String>()
        try? db.query("SELECT DISTINCT doc_id FROM activity WHERE session_id IS NOT NULL AND doc_id IS NOT NULL") { docs.insert($0.text(0)) }
        try? db.transaction {
            for sql in ["DELETE FROM ai_sessions", "DELETE FROM ai_writes", "DELETE FROM session_cursor",
                        "DELETE FROM activity WHERE kind='ask'"] { _ = try? db.run(sql) }
            for id in docs {
                if let d = ctx.doc(id: id) { refreshPathFeatures(d) }
                let guessAI = loadState(id)?.aiArchive == 1
                _ = try? db.run("""
                UPDATE activity SET actor=?, origin='fsevents', session_id=NULL, detail=? WHERE doc_id=? AND session_id IS NOT NULL
                """, [.text(guessAI ? "claude" : "human"), guessAI ? .text(BrainFormat.json(["guess": true])) : .null, .text(id)])
                recomputeAuthor(id)
            }
        }
        codexMeta = [:]; sessionError = nil; fileErrorRun = 0
        ctx.db.setSetting(Signals.lastScanKey, nil)
    }

    // MARK: 설정 화면 (§4.6 sessionsJSON)

    func sessionsJSON() -> [String: Any] {
        let enabled: Any = ctx.db.setting(BrainSetting.sessionsEnabled).map { $0 == "1" } ?? NSNull()
        let files = sessionFiles()
        func count(_ tool: String) -> Int {
            var n = 0
            try? db.query("SELECT count(*) FROM ai_sessions WHERE tool=?", [.text(tool)]) { n = Int($0.int(0)) }
            return n
        }
        func dirInfo(_ url: URL?, _ tool: String, _ fallback: String) -> [String: Any] {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            var shown = url?.path ?? fallback
            if shown.hasPrefix(home + "/") { shown = "~" + shown.dropFirst(home.count) }
            var isDir: ObjCBool = false
            let found = url.map { FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue } ?? false
            return ["dir": shown, "found": found, "files": files.filter { $0.tool == tool }.count, "sessions": count(tool)]
        }
        var matched = 0
        var paths: [String] = []
        try? db.query("SELECT DISTINCT path FROM ai_writes") { paths.append($0.text(0)) }
        matched = paths.filter { ctx.doc(path: $0) != nil }.count
        return [
            "enabled": enabled,
            "requestText": ctx.db.setting(BrainSetting.sessionsRequestText) != "0",
            "claude": dirInfo(ctx.env.claudeDir, "claude", "~/.claude/projects"),
            "codex": dirInfo(ctx.env.codexDir, "codex", "~/.codex/sessions"),
            "lastScan": ctx.db.setting(Signals.lastScanKey) ?? NSNull(),
            "writesMatched": matched,
            "error": sessionError ?? NSNull(),
            "fields": ["세션 제목", "작업 폴더", "브랜치", "AI가 쓴 파일 경로", "시각", "내 요청 첫 줄(80자)"],
        ]
    }

    /// 세션 폴더가 하나라도 있는가 (홈 askCard용).
    func sessionDirsExist() -> Bool {
        [ctx.env.claudeDir, ctx.env.codexDir].compactMap { $0 }.contains { FileManager.default.fileExists(atPath: $0.path) }
    }
}
