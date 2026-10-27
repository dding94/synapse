import Foundation
import Darwin

// v0.7 H — MCP 바로 실행(apply_changes) 하루 상한을 동시 호출에도 지킨다.
// synapse-mcp는 Claude Code·Codex 세션마다 하나씩 뜬다. 둘이 같은 때 "오늘 쓴 수"를 읽으면 둘 다 같은 값을 보고 상한을 넘길 수 있다.
// 그래서 applyChanges 전체(셈 → 실행 → 넘친 것 제안)를 <SYNAPSE_HOME>/direct-apply.lock 파일의 flock(LOCK_EX)로 감싼다.
// - 앱·CLI·MCP 어느 프로세스든 같은 홈이면 같은 잠금 파일을 쓴다.
// - SQLite 쓰기 잠금(BEGIN IMMEDIATE)은 쓰지 않는다. 파일 이동이 길어지면 앱·다른 MCP의 사서 쓰기가 busy timeout에 걸리기 때문이다.
// - 프로세스가 죽으면 flock은 커널이 저절로 푼다. 잠금 파일은 지우지 않는다(지우면 다른 프로세스가 다른 inode를 잠글 수 있다).

/// 프로세스 사이 배타 잠금(flock). 같은 프로세스 안에서도 open을 따로 하면 서로 막는다.
final class ProcessLock {
    private var fd: Int32

    private init(fd: Int32) { self.fd = fd }

    enum Outcome {
        case locked(ProcessLock, waited: Double)
        case busy(waited: Double)        // 시간 안에 못 얻었다
        case unavailable(String)         // 잠금 파일을 열지 못했다
    }

    /// LOCK_NB로 짧게 다시 해 보며 최대 timeout초 기다린다.
    static func acquire(path: String, timeout: Double, poll: Double = 0.1) -> Outcome {
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        if fd < 0 { return .unavailable(String(cString: strerror(errno))) }
        let start = Date()
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return .locked(ProcessLock(fd: fd), waited: Date().timeIntervalSince(start)) }
            let e = errno
            if e != EWOULDBLOCK && e != EINTR { close(fd); return .unavailable(String(cString: strerror(e))) }
            let waited = Date().timeIntervalSince(start)
            if waited >= timeout { close(fd); return .busy(waited: waited) }
            usleep(useconds_t(min(poll, max(0.01, timeout - waited)) * 1_000_000))
        }
    }

    func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}

extension Organizer {
    /// 잠금 파일 이름(SYNAPSE_HOME 아래).
    static let directLockName = "direct-apply.lock"
    /// 잠금을 기다리는 최대 시간(초).
    static let directLockWait: Double = 15
    static let directBusyNote = "다른 Claude·Codex가 바로 정리 중이에요. 잠시 뒤 다시 해 주세요"

    /// 오늘 바로 실행 상한. 시험 환경(기본이 아닌 홈 등)에서만 SYNAPSE_TEST_DIRECT_PER_DAY로 낮출 수 있다(올릴 수는 없다).
    var directCap: Int {
        guard ctx.env.isTest, let s = ProcessInfo.processInfo.environment["SYNAPSE_TEST_DIRECT_PER_DAY"],
              let n = Int(s.trimmingCharacters(in: .whitespaces)), n >= 1 else { return Organizer.directPerDay }
        return min(n, Organizer.directPerDay)
    }

    var directLockPath: String { ctx.home.appendingPathComponent(Organizer.directLockName).path }
}
