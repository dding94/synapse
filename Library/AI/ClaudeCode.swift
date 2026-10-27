import Foundation

// v0.8 Claude Code 실행기 (docs/V08.md §3). 이 맥의 `claude -p`를 헤드리스로 띄워 정리(JSON)·시키기(stream-json)를 돌린다.
// Foundation Process만 쓴다(AppKit 없음 — 앱·CLI·MCP 대상에 함께 컴파일된다). 사용자 셸의 별칭(alias claude=…)을 타지 않도록
// 늘 절대 경로로 실행하고, 환경은 새로 만든다. --dangerously-skip-permissions 류는 절대 쓰지 않는다(§9).

/// 찾은 Claude Code (§3.1).
struct ClaudeInstall: Equatable {
    let path: String
    let version: String
}

/// 실행 실패 (§3.6). code는 화면이 안내를 고르는 열쇠, message는 그대로 보이는 해요체 문구.
struct ClaudeFailure: Error {
    let code: String         // missing | login | limit | network | timeout | bad_output | cancelled | failed
    let message: String

    static let messages: [String: String] = [
        "missing": "Claude Code를 찾지 못했어요. 설치했다면 설정에서 경로를 골라 주세요.",
        "login": "Claude Code 로그인이 필요해요. 터미널에서 claude를 실행해 /login 해 주세요.",
        "limit": "Claude 사용 한도에 닿았어요.",
        "network": "인터넷 연결을 확인해 주세요.",
        "timeout": "시간이 너무 오래 걸려 멈췄어요.",
        "bad_output": "Claude 답을 읽지 못했어요. 다시 정리해 보세요.",
        "cancelled": "취소했어요.",
        "failed": "Claude 실행이 실패했어요.",
    ]

    static func make(_ code: String) -> ClaudeFailure {
        ClaudeFailure(code: code, message: messages[code] ?? messages["failed"]!)
    }
}

// MARK: - 프로세스

/// claude 프로세스 하나 (§3.2). run()은 끝날 때까지 막는다. cancel()은 아무 스레드에서나 부를 수 있다 — SIGTERM, 3초 뒤에도
/// 살아 있으면 SIGKILL. 표준 입력에 프롬프트를 쓰고 닫는다. 표준 출력은 줄 콜백(stream-json) 또는 통째로(json) 받고,
/// 표준 오류는 끝 64KB만 남긴다.
final class ClaudeProcess {
    struct Output {
        var status: Int32 = -1
        var stdout = Data()          // 줄 콜백이 없을 때만 모은다(32MB까지)
        var stderr = ""
        var timedOut = false
        var cancelled = false
        var launchError: String?
    }

    static let killDelay: TimeInterval = 3
    static let maxLineBytes = 8 * 1024 * 1024      // stream-json 한 줄 상한. 넘는 줄은 버린다
    static let maxStdoutBytes = 32 * 1024 * 1024
    static let maxStderrBytes = 64 * 1024

    let executable: String
    let arguments: [String]
    let environment: [String: String]
    let cwd: URL
    let input: Data
    let timeout: TimeInterval

    private let lock = NSLock()
    private var process: Process?
    private var cancelRequested = false
    private var expired = false
    private var exitedAt: Date?

    init(executable: String, arguments: [String], environment: [String: String], cwd: URL, input: Data, timeout: TimeInterval) {
        self.executable = executable; self.arguments = arguments; self.environment = environment
        self.cwd = cwd; self.input = input; self.timeout = timeout
    }

    /// 사용자 취소: SIGTERM → 3초 → SIGKILL. 아직 띄우기 전이면 띄우지 않는다.
    func cancel() {
        lock.lock(); cancelRequested = true; let p = process; lock.unlock()
        if let p = p { stop(p) }
    }

    /// 앱 종료: 기다리지 않고 바로 끝낸다.
    func kill() {
        lock.lock(); cancelRequested = true; let p = process; lock.unlock()
        if let p = p, p.isRunning { Darwin.kill(p.processIdentifier, SIGKILL) }
    }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return process?.isRunning ?? false }

    private func stop(_ p: Process) {
        guard p.isRunning else { return }
        p.terminate()
        let pid = p.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + ClaudeProcess.killDelay) {
            if p.isRunning { Darwin.kill(pid, SIGKILL) }
        }
    }

    private func expire() {
        lock.lock(); expired = true; let p = process; lock.unlock()
        if let p = p { stop(p) }
    }

    private func exitTime() -> Date? { lock.lock(); defer { lock.unlock() }; return exitedAt }

    func run(onLine: ((Data) -> Void)? = nil) -> Output {
        var out = Output()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.environment = environment
        p.currentDirectoryURL = cwd
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { [weak self] _ in
            if let self = self { self.lock.lock(); self.exitedAt = Date(); self.lock.unlock() }
            exited.signal()
        }
        lock.lock()
        if cancelRequested { lock.unlock(); out.cancelled = true; return out }
        do { try p.run() } catch {
            lock.unlock()
            out.launchError = error.localizedDescription
            return out
        }
        process = p
        lock.unlock()

        // 표준 입력은 따로 쓰고 닫는다(파이프가 차도 읽기와 엇갈려 멈추지 않게). 자식이 먼저 끝나도 SIGPIPE로 죽지 않게 한다.
        let inHandle = inPipe.fileHandleForWriting
        let data = input
        DispatchQueue.global(qos: .utility).async {
            let fd = inHandle.fileDescriptor
            _ = fcntl(fd, F_SETNOSIGPIPE, 1)
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                var off = 0
                while off < raw.count {
                    let n = Darwin.write(fd, base + off, raw.count - off)
                    if n > 0 { off += n } else if n < 0 && errno == EINTR { continue } else { break }
                }
            }
            try? inHandle.close()
        }

        let timer = DispatchWorkItem { [weak self] in self?.expire() }
        if timeout > 0 { DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer) }

        // 표준 출력·오류를 poll 하나로 읽는다. 프로세스가 끝나고 2초가 지나도 파이프가 안 닫히면(손자 프로세스가 물고 있으면) 그만 읽는다.
        var fds = [pollfd(fd: outPipe.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0),
                   pollfd(fd: errPipe.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)]
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var line = Data(), discarding = false
        var errData = Data()
        func feed(_ chunk: Data) {
            guard let onLine = onLine else {
                if out.stdout.count < ClaudeProcess.maxStdoutBytes { out.stdout.append(chunk) }
                return
            }
            var start = chunk.startIndex
            while let nl = chunk[start...].firstIndex(of: 0x0A) {
                if discarding { discarding = false } else {
                    line.append(chunk[start..<nl])
                    if !line.isEmpty { onLine(line) }
                }
                line.removeAll(keepingCapacity: true)
                start = chunk.index(after: nl)
            }
            guard !discarding else { return }
            line.append(chunk[start...])
            if line.count > ClaudeProcess.maxLineBytes { discarding = true; line.removeAll() }
        }
        while fds[0].fd >= 0 || fds[1].fd >= 0 {
            let r = poll(&fds, 2, 250)
            if r < 0 { if errno == EINTR { continue }; break }
            if r > 0 {
                for i in 0..<2 where fds[i].fd >= 0 && fds[i].revents != 0 {
                    let n = buffer.withUnsafeMutableBytes { Darwin.read(fds[i].fd, $0.baseAddress, $0.count) }
                    if n > 0 {
                        let chunk = Data(buffer[0..<n])
                        if i == 0 { feed(chunk) } else {
                            errData.append(chunk)
                            if errData.count > ClaudeProcess.maxStderrBytes * 2 { errData = Data(errData.suffix(ClaudeProcess.maxStderrBytes)) }
                        }
                    } else if n == 0 || (errno != EINTR && errno != EAGAIN) {
                        fds[i].fd = -1
                    }
                }
            }
            if let t = exitTime(), Date().timeIntervalSince(t) > 2 { break }
        }
        if let onLine = onLine, !discarding, !line.isEmpty { onLine(line) }
        if exited.wait(timeout: .now() + 5) == .timedOut {
            Darwin.kill(p.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + 2)
        }
        timer.cancel()
        try? outPipe.fileHandleForReading.close()
        try? errPipe.fileHandleForReading.close()
        lock.lock(); out.cancelled = cancelRequested; out.timedOut = expired && !cancelRequested; lock.unlock()
        out.status = p.isRunning ? -1 : p.terminationStatus
        out.stderr = String(decoding: errData.suffix(ClaudeProcess.maxStderrBytes), as: UTF8.self)
        return out
    }
}

// MARK: - 찾기

/// Claude Code 찾기 (§3.1). 결과(경로·버전)는 캐시한다. invalidate()(설정 바뀜·aiTest·"없음" 실패) 뒤에 다시 찾고,
/// 못 찾은 결과는 5분이 지나면 다시 찾는다(그사이 설치했을 수 있다). 동시에 여러 번 찾지 않는다.
final class ClaudeFinder {
    let testMode: Bool
    private let lock = NSLock()
    private let searching = NSLock()
    private var cache: (configured: String, result: Result<ClaudeInstall, ClaudeFailure>, at: Date)?

    init(testMode: Bool) { self.testMode = testMode }

    func invalidate() { lock.lock(); cache = nil; lock.unlock() }

    func find(configured: String) -> Result<ClaudeInstall, ClaudeFailure> {
        searching.lock(); defer { searching.unlock() }
        lock.lock()
        if let c = cache, c.configured == configured {
            switch c.result {
            case .success(let i) where FileManager.default.isExecutableFile(atPath: i.path):
                lock.unlock(); return c.result
            case .failure where Date().timeIntervalSince(c.at) < 300:
                lock.unlock(); return c.result
            default: break
            }
        }
        lock.unlock()
        let result = locate(configured: configured)
        lock.lock(); cache = (configured, result, Date()); lock.unlock()
        return result
    }

    /// 순서: 설정 claude.path → SYNAPSE_CLAUDE_BIN(시험용) → ~/.local/bin → ~/.claude/local → /opt/homebrew/bin → /usr/local/bin →
    /// zsh 로그인 셸의 `whence -p claude`(별칭을 보지 않는다. `command -v`는 별칭이 먼저 나와 쓰지 않는다).
    /// 시험 모드에서는 SYNAPSE_CLAUDE_BIN이 없으면 Claude가 없는 것으로 본다 — 시험이 진짜 Claude를 부르지 않게.
    private func locate(configured: String) -> Result<ClaudeInstall, ClaudeFailure> {
        let bin = ProcessInfo.processInfo.environment["SYNAPSE_CLAUDE_BIN"] ?? ""
        if testMode && bin.isEmpty { return .failure(.make("missing")) }
        var candidates: [String] = []
        let c = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        if testMode {
            // 시험은 SYNAPSE_CLAUDE_BIN만 쓴다 — 실제 홈을 복사한 시험 홈의 claude.path가 진짜 claude를 가리켜도 부르지 않게
            candidates = [ClaudeCode.expand(bin)]
        } else {
            if !c.isEmpty { candidates.append(ClaudeCode.expand(c)) }
            if !bin.isEmpty { candidates.append(ClaudeCode.expand(bin)) }
        }
        if !testMode {
            let home = NSHomeDirectory()
            candidates += [home + "/.local/bin/claude", home + "/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        }
        var seen = Set<String>()
        for path in candidates where seen.insert(path).inserted {
            if let v = ClaudeCode.version(of: path, testMode: testMode) { return .success(ClaudeInstall(path: path, version: v)) }
        }
        if !testMode, let path = ClaudeCode.shellLookup(), seen.insert(path).inserted,
           let v = ClaudeCode.version(of: path, testMode: testMode) {
            return .success(ClaudeInstall(path: path, version: v))
        }
        return .failure(.make("missing"))
    }
}

// MARK: - 인자·환경·해석

enum ClaudeCode {
    /// 시간 제한 (§3.2). 시험 모드에서는 SYNAPSE_TEST_AI_TIMEOUT(초)으로 낮출 수만 있다.
    static let digestTimeout: TimeInterval = 180
    static let taskTimeout: TimeInterval = 900
    static let testTimeout: TimeInterval = 60
    static let models: Set<String> = ["sonnet", "opus", "haiku"]
    static let toolPrefix = "mcp__\(AITools.server)__"
    /// 시험 모드에서만 claude에 넘기는 환경 변수 접두(dev/ai-fake/claude의 FAKE_CLAUDE_MODE 등). 평소에는 아무것도 넘기지 않는다.
    static let fakeEnvPrefix = "FAKE_CLAUDE_"

    static func timeout(_ base: TimeInterval, testMode: Bool) -> TimeInterval {
        guard testMode, let s = ProcessInfo.processInfo.environment["SYNAPSE_TEST_AI_TIMEOUT"], let v = Double(s), v > 0 else { return base }
        return min(base, v)
    }

    static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }

    /// 화면용 경로: 홈은 ~로 줄인다.
    static func tilde(_ text: String) -> String {
        let home = NSHomeDirectory()
        guard !home.isEmpty, home != "/" else { return text }
        return text.replacingOccurrences(of: home, with: "~")
    }

    /// 새로 만든 환경 (§3.2): HOME USER LOGNAME SHELL TMPDIR LANG PATH만. 앱 환경의 다른 변수는 넘기지 않는다.
    static func environment(claudePath: String, testMode: Bool) -> [String: String] {
        let src = ProcessInfo.processInfo.environment
        func pick(_ key: String, _ fallback: String) -> String { src[key].flatMap { $0.isEmpty ? nil : $0 } ?? fallback }
        var env: [String: String] = [
            "HOME": pick("HOME", NSHomeDirectory()),
            "USER": pick("USER", NSUserName()),
            "LOGNAME": pick("LOGNAME", NSUserName()),
            "SHELL": pick("SHELL", "/bin/zsh"),
            "TMPDIR": pick("TMPDIR", NSTemporaryDirectory()),
            "LANG": pick("LANG", "ko_KR.UTF-8"),
        ]
        var seen = Set<String>()
        let dir = (claudePath as NSString).deletingLastPathComponent
        env["PATH"] = ([dir, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"])
            .filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
        if testMode { for (k, v) in src where k.hasPrefix(fakeEnvPrefix) { env[k] = v } }
        return env
    }

    /// 실행 폴더 <home>/claude-runs/ (비어 있는 전용 폴더. 없으면 만든다).
    static func runsDirectory(home: URL) -> URL {
        let dir = home.appendingPathComponent("claude-runs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }

    /// 공통 인자 (§3.2·§9). 프롬프트는 인자가 아니라 표준 입력으로 보낸다.
    static func commonArguments(model: String, effort: String) -> [String] {
        ["-p", "--no-session-persistence", "--restricted", "--strict-mcp-config", "--permission-prompts", "none",
         "--model", model, "--effort", effort]
    }

    /// 정리 모드 (§3.3): 도구 없음, MCP 없음(--strict-mcp-config만 주므로 아무것도 붙지 않는다), JSON 스키마로 받는다.
    static func digestArguments(schema: String, system: String) -> [String] {
        ["--output-format", "json", "--tools", "", "--json-schema", schema, "--system-prompt", system]
    }

    /// 시키기 모드 (§3.4): 내장 도구 없음, Synapse MCP만, 허용 목록 밖은 --permission-prompts none으로 자동 거절.
    static func taskArguments(mcpConfig: URL, system: String) -> [String] {
        ["--output-format", "stream-json", "--verbose", "--tools", "", "--mcp-config", mcpConfig.path,
         "--allowedTools", AITools.allowed.joined(separator: ","), "--system-prompt", system]
    }

    /// 연결 시험 (aiTest): 가장 짧은 한 번.
    static func testArguments() -> [String] {
        commonArguments(model: "haiku", effort: "low") + ["--output-format", "json", "--tools", "",
                                                          "--system-prompt", "연결 확인용 호출이에요. OK라고만 답해요."]
    }

    /// <home>/claude-runs/<runId>.mcp.json 내용 (§3.4). 시험용 SYNAPSE_*는 여기(MCP 서버 env)로만 넘긴다.
    static func mcpConfig(binary: URL, home: URL, runId: String) -> [String: Any] {
        var env: [String: String] = ["SYNAPSE_HOME": home.path, "SYNAPSE_RUN_ID": runId, "SYNAPSE_MCP_ORIGIN": "claude"]
        let app = ProcessInfo.processInfo.environment
        for key in ["SYNAPSE_CLAUDE_DIR", "SYNAPSE_CODEX_DIR", "SYNAPSE_OBSIDIAN_RUNNING", "SYNAPSE_NOW", "SYNAPSE_CLI_MEMORY_SECRETS"] {
            if let v = app[key], !v.isEmpty { env[key] = v }
        }
        return ["mcpServers": [AITools.server: ["command": binary.path, "args": [String](), "env": env] as [String: Any]]]
    }

    /// `<path> --version` 출력에 "Claude Code"가 있으면 버전("2.1.310")을 돌려준다.
    static func version(of path: String, testMode: Bool) -> String? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue,
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let p = ClaudeProcess(executable: path, arguments: ["--version"], environment: environment(claudePath: path, testMode: testMode),
                              cwd: FileManager.default.temporaryDirectory, input: Data(), timeout: 10)
        let out = p.run()
        guard out.status == 0, out.launchError == nil, !out.timedOut else { return nil }
        let text = String(decoding: out.stdout, as: UTF8.self)
        guard let line = text.split(separator: "\n").first(where: { $0.contains("Claude Code") }) else { return nil }
        return line.split(separator: " ").first.map(String.init)
    }

    /// `/bin/zsh -lc 'whence -p claude'` (3초 제한). 별칭·함수는 보지 않는다.
    static func shellLookup() -> String? {
        let p = ClaudeProcess(executable: "/bin/zsh", arguments: ["-lc", "whence -p claude"],
                              environment: environment(claudePath: "/usr/bin/true", testMode: false),
                              cwd: URL(fileURLWithPath: NSHomeDirectory()), input: Data(), timeout: 3)
        let out = p.run()
        guard !out.timedOut else { return nil }
        return String(decoding: out.stdout, as: UTF8.self).split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.last { $0.hasPrefix("/") }
    }

    // MARK: 해석

    /// json 출력에서 마지막 result 객체(없으면 마지막 JSON 객체).
    static func lastJSONObject(_ data: Data) -> [String: Any]? {
        let lines = data.split(separator: 0x0A)
        var fallback: [String: Any]?
        for raw in lines.reversed() {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(raw))) as? [String: Any] else { continue }
            if obj["type"] as? String == "result" { return obj }
            if fallback == nil { fallback = obj }
        }
        if fallback == nil, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { return obj }
        return fallback
    }

    /// 글에서 JSON 값 하나를 느슨하게 읽는다(```json 울타리·앞뒤 말 허용).
    static func looseJSON(_ text: String) -> Any? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = t.data(using: .utf8), let v = try? JSONSerialization.jsonObject(with: d) { return v }
        guard let a = t.firstIndex(of: "{"), let b = t.lastIndex(of: "}"), a < b,
              let d = String(t[a...b]).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d)
    }

    static func succeeded(_ result: [String: Any]?) -> Bool {
        guard let r = result else { return false }
        return (r["is_error"] as? Bool) != true && (r["subtype"] as? String ?? "success") == "success"
    }

    static func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }

    /// 정리 결과 (§3.3): structured_output, 없으면 result를 JSON으로 읽어 본다.
    static func parseDigest(_ out: ClaudeProcess.Output) -> Result<(output: Any, turns: Int?, apiMs: Int?), ClaudeFailure> {
        let result = lastJSONObject(out.stdout)
        if out.cancelled || out.timedOut || out.launchError != nil {
            return .failure(classify(out, result: result, rateLimit: nil))
        }
        guard succeeded(result), let r = result else { return .failure(classify(out, result: result, rateLimit: nil)) }
        if let so = r["structured_output"], !(so is NSNull) { return .success((so, int(r["num_turns"]), int(r["duration_ms"]))) }
        if let text = r["result"] as? String, let v = looseJSON(text) { return .success((v, int(r["num_turns"]), int(r["duration_ms"]))) }
        return .failure(.make("bad_output"))
    }

    /// 연결 시험 결과: 성공한 result면 그 글.
    static func parseTest(_ out: ClaudeProcess.Output) -> Result<String, ClaudeFailure> {
        let result = lastJSONObject(out.stdout)
        guard !out.cancelled, !out.timedOut, out.launchError == nil, succeeded(result) else {
            return .failure(classify(out, result: result, rateLimit: nil))
        }
        return .success((result?["result"] as? String) ?? "")
    }

    private static let loginWords = ["not logged in", "/login", "authenticat", "oauth", "invalid api key"]
    private static let limitWords = ["usage limit", "limit reached", "rate limit", "overloaded"]
    /// 숫자 상태 코드는 낱말로만 본다 — 요청 id(req_…4019…)나 풀리는 시각(…|1793401200)에 섞인 숫자에 걸리지 않게.
    private static func hasCode(_ hay: String, _ code: String) -> Bool {
        hay.range(of: "(?<![0-9a-z])\(code)(?![0-9a-z])", options: .regularExpression) != nil
    }
    private static let networkWords = ["enotfound", "econnrefused", "econnreset", "etimedout", "network", "getaddrinfo",
                                       "timed out", "socket hang up", "unable to connect"]

    /// 실패 분류 (§3.6). stderr·result 글(대소문자 무시)과 api_error_status로 고른다.
    static func classify(_ out: ClaudeProcess.Output, result: [String: Any]?, rateLimit: [String: Any]?) -> ClaudeFailure {
        if out.cancelled { return .make("cancelled") }
        if out.timedOut { return .make("timeout") }
        if out.launchError != nil || out.status == 126 || out.status == 127 { return .make("missing") }
        let resultText = (result?["result"] as? String) ?? ""
        var hay = (out.stderr + "\n" + resultText).lowercased()
        if result == nil { hay += "\n" + String(decoding: out.stdout.suffix(4000), as: UTF8.self).lowercased() }
        let api = int(result?["api_error_status"]) ?? Int((result?["api_error_status"] as? String) ?? "")
        // api_error_status가 있으면 그것을 먼저 믿는다
        if api == 401 || api == 403 { return .make("login") }
        if api == 429 || api == 529 { return limitFailure(hay, rateLimit: rateLimit) }
        // 글로 고를 때는 한도를 로그인보다 먼저 본다(한도 글에 섞인 숫자·단어로 로그인 문제로 잘못 멈추지 않게)
        if limitWords.contains(where: hay.contains) || hasCode(hay, "429") || hasCode(hay, "529") || (rateLimit?["status"] as? String) == "rejected" {
            return limitFailure(hay, rateLimit: rateLimit)
        }
        if loginWords.contains(where: hay.contains) || hasCode(hay, "401") { return .make("login") }
        if networkWords.contains(where: hay.contains) { return .make("network") }
        if result == nil && out.status == 0 { return .make("bad_output") }
        var detail = tail(out.stderr.isEmpty ? resultText : out.stderr)
        if detail.isEmpty { detail = (result?["subtype"] as? String).map { "결과 \($0)" } ?? "종료 코드 \(out.status)" }
        return ClaudeFailure(code: "failed", message: "Claude 실행이 실패했어요: \(detail)")
    }

    /// 한도 문구. 풀리는 시각이 rate_limit_event나 글("…|1761465000", "resets 3pm")에 있으면 붙인다.
    static func limitFailure(_ hay: String, rateLimit: [String: Any]?) -> ClaudeFailure {
        var when: String?
        if let s = rateLimit?["status"] as? String, s != "allowed", let t = int(rateLimit?["resetsAt"]), t > 0 {
            when = resetLabel(Date(timeIntervalSince1970: TimeInterval(t)))
        } else if let m = hay.range(of: #"\|(\d{10})"#, options: .regularExpression), let t = Double(hay[m].dropFirst()) {
            when = resetLabel(Date(timeIntervalSince1970: t))
        } else if let m = hay.range(of: #"resets?\s+(at\s+)?\d{1,2}(:\d{2})?\s*(am|pm)?"#, options: .regularExpression) {
            let s = String(hay[m]).replacingOccurrences(of: #"^resets?\s+(at\s+)?"#, with: "", options: .regularExpression)
            when = s.trimmingCharacters(in: .whitespaces)
        }
        let base = ClaudeFailure.messages["limit"]!
        guard let w = when, !w.isEmpty else { return ClaudeFailure(code: "limit", message: base) }
        return ClaudeFailure(code: "limit", message: "\(base) \(w)에 풀려요.")
    }

    /// "오늘 15:00" · "내일 09:00" · "10/28 15:00"
    static func resetLabel(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let hm = String(format: "%02d:%02d", cal.component(.hour, from: d), cal.component(.minute, from: d))
        if cal.isDate(d, inSameDayAs: now) { return "오늘 \(hm)" }
        if let t = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(d, inSameDayAs: t) { return "내일 \(hm)" }
        return "\(cal.component(.month, from: d))/\(cal.component(.day, from: d)) \(hm)"
    }

    /// stderr 마지막 200자(홈 경로는 ~로 줄이고 줄바꿈은 한 칸으로).
    static func tail(_ text: String, _ n: Int = 200) -> String {
        let flat = tilde(text).split(whereSeparator: { $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return flat.count > n ? "…" + String(flat.suffix(n)) : flat
    }

    static func short(_ text: String, _ n: Int) -> String {
        let t = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return t.count > n ? String(t.prefix(n)) + "…" : t
    }

    /// 단계 문구 (§3.4). 모르는 도구는 이름 그대로 쓴다.
    static func stepLabel(tool: String, input: [String: Any]) -> String {
        func s(_ key: String) -> String { short((input[key] as? String) ?? "", 40) }
        let n = (input["items"] as? [Any])?.count ?? 0
        switch tool {
        case "search_notes": return "노트 검색: \(s("query"))"
        case "get_note": return "문서 읽기"
        case "related_notes": return "연결 문서 보기"
        case "recent_notes": return "최근 문서 보기"
        case "list_sources": return "연결된 자료 보기"
        case "get_work_context": return "작업 맥락 보기"
        case "get_vault_policy": return "정리 규칙 확인"
        case "list_pending": return "정리 안 된 문서 보기"
        case "suggest_location": return "둘 곳 추천: \(s("title"))"
        case "get_tickets": return "티켓 보기"
        case "propose_changes": return "정리 제안 올리기(\(n)개)"
        case "propose_jira_changes": return "Jira 제안 올리기(\(n)개)"
        default: return tool
        }
    }
}

// MARK: - stream-json 해석 (§3.4)

/// 시키기 출력 한 줄씩. 사건은 onEvent로(실행 스레드), 끝 결과·한도 정보는 속성으로 남긴다.
final class ClaudeStreamParser {
    enum Event {
        case started(model: String)
        case text(messageId: String, text: String)
        case toolUse(id: String, name: String, input: [String: Any])
        case toolResult(id: String, ok: Bool)
        case denied(id: String, name: String)
    }
    var onEvent: ((Event) -> Void)?
    private(set) var result: [String: Any]?
    private(set) var rateLimit: [String: Any]?
    private(set) var model: String?
    private(set) var badLines = 0

    func feed(_ line: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let type = obj["type"] as? String else {
            badLines += 1
            return
        }
        switch type {
        case "system":
            switch obj["subtype"] as? String {
            case "init":
                model = obj["model"] as? String
                onEvent?(.started(model: model ?? ""))
            case "permission_denied":
                if let id = obj["tool_use_id"] as? String { onEvent?(.denied(id: id, name: obj["tool_name"] as? String ?? "")) }
            default: break
            }
        case "assistant":
            let msg = obj["message"] as? [String: Any] ?? [:]
            let mid = msg["id"] as? String ?? ""
            for block in msg["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "text":
                    if let t = block["text"] as? String, !t.isEmpty { onEvent?(.text(messageId: mid, text: t)) }
                case "tool_use":
                    onEvent?(.toolUse(id: block["id"] as? String ?? "", name: block["name"] as? String ?? "",
                                      input: block["input"] as? [String: Any] ?? [:]))
                default: break
                }
            }
        case "user":
            let msg = obj["message"] as? [String: Any] ?? [:]
            for block in msg["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_result" {
                onEvent?(.toolResult(id: block["tool_use_id"] as? String ?? "", ok: (block["is_error"] as? Bool) != true))
            }
        case "rate_limit_event":
            rateLimit = obj["rate_limit_info"] as? [String: Any]
        case "result":
            result = obj
        default: break
        }
    }
}

/// 시키기 진행 기록 (§3.4·§7.3). 파서 사건을 사람이 읽는 단계·답으로 바꾼다. snapshot()은 아무 스레드에서나 읽는다.
/// 단계: {index, ts(시작부터 초), kind: tool|text|info|error, text, tool?, ok?}. 도구 단계는 결과가 오면 같은 index로 다시 알린다.
final class ClaudeTaskRecorder {
    static let maxSteps = 200
    private let lock = NSLock()
    private let started = Date()
    private var steps: [[String: Any]] = []
    private var toolIndex: [String: Int] = [:]
    private var answer = ""
    private var textMessage = ""
    private var pendingText = ""        // 도구를 부르기 전에 쓴 글(중간 설명). 다음 도구가 오면 text 단계로 남긴다
    private(set) var proposed = false
    var onStep: ((Int, [String: Any]) -> Void)?
    var onText: ((String) -> Void)?
    var onProposed: (() -> Void)?

    func snapshot() -> (steps: [[String: Any]], answer: String) {
        lock.lock(); defer { lock.unlock() }
        return (steps, answer)
    }

    private func ts() -> Double { (Date().timeIntervalSince(started) * 10).rounded() / 10 }

    /// 잠근 채로 단계를 붙인다. 붙였으면 (index, step).
    private func appendLocked(kind: String, text: String, tool: String? = nil, ok: Bool? = nil) -> (Int, [String: Any])? {
        guard steps.count < ClaudeTaskRecorder.maxSteps else { return nil }
        var step: [String: Any] = ["index": steps.count, "ts": ts(), "kind": kind, "text": text]
        if let tool = tool { step["tool"] = tool }
        step["ok"] = ok.map { $0 as Any } ?? NSNull()
        steps.append(step)
        return (steps.count - 1, step)
    }

    /// AIService가 끝에 붙이는 안내·오류 단계.
    func add(kind: String, text: String, ok: Bool? = nil) {
        lock.lock(); let s = appendLocked(kind: kind, text: text, ok: ok); lock.unlock()
        if let s = s { onStep?(s.0, s.1) }
    }

    func handle(_ e: ClaudeStreamParser.Event) {
        var stepEvents: [(Int, [String: Any])] = []
        var text: String?
        var proposedNow = false
        lock.lock()
        switch e {
        case .started:
            break
        case .text(let mid, let t):
            if !mid.isEmpty && mid == textMessage && !answer.isEmpty { answer += "\n\n" + t } else { answer = t }
            textMessage = mid
            pendingText = answer
            text = answer
        case .toolUse(let id, let name, let input):
            if !pendingText.isEmpty, let s = appendLocked(kind: "text", text: ClaudeCode.short(pendingText, 200)) { stepEvents.append(s) }
            pendingText = ""
            let tool = name.hasPrefix(ClaudeCode.toolPrefix) ? String(name.dropFirst(ClaudeCode.toolPrefix.count)) : name
            if let s = appendLocked(kind: "tool", text: ClaudeCode.stepLabel(tool: tool, input: input), tool: tool) {
                toolIndex[id] = s.0
                stepEvents.append(s)
            }
        case .toolResult(let id, let ok):
            if let i = toolIndex[id] {
                steps[i]["ok"] = ok
                stepEvents.append((i, steps[i]))
                if ok, let tool = steps[i]["tool"] as? String, AITools.propose.contains(tool) { proposed = true; proposedNow = true }
            }
        case .denied(let id, _):
            if let i = toolIndex[id] {
                steps[i]["text"] = ((steps[i]["text"] as? String) ?? "") + " — 허용되지 않아 거절됐어요"
                steps[i]["ok"] = false
                stepEvents.append((i, steps[i]))
            }
        }
        lock.unlock()
        for (i, s) in stepEvents { onStep?(i, s) }
        if let t = text { onText?(t) }
        if proposedNow { onProposed?() }
    }
}
