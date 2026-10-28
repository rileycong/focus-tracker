import Foundation
@preconcurrency import Dispatch

/// The outcome of ONE git invocation (issue #49): the exit status plus the
/// captured stdout/stderr. The runner captures; the coordinator interprets
/// (typed errors, unborn checks, the staged-contents probe).
public struct GitOutcome: Equatable, Sendable {
    public let exitStatus: Int32
    public let stdout: String
    public let stderr: String

    public init(exitStatus: Int32, stdout: String, stderr: String) {
        self.exitStatus = exitStatus
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// The Process seam (issue #49, the [Sync OFF] criterion): every git
/// invocation sits behind this protocol, so tests count spawns (zero with
/// the toggle off) and inject hermetic identities. Production runs
/// `ProcessGitRunner` — one `Process` per invocation, the inherited
/// environment, NO `GIT_*`/`SSH_*`/`ASKPASS` vars, no credential helpers,
/// no `-c` overrides (tests inject those via `extraArguments` — the ONLY
/// sanctioned override).
public protocol GitRunner: Sendable {
    /// Runs the git binary with `arguments`. Throws ONLY spawn failures
    /// (`GitRunnerError.spawnFailed`); non-zero exits come back as ordinary
    /// outcomes for the caller to interpret.
    func run(arguments: [String]) async throws -> GitOutcome
}

public enum GitRunnerError: Error, Equatable, Sendable {
    case spawnFailed(String)
}

/// Thread-safe byte accumulator for the pipe readers (the 64K-pipe deadlock
/// defense: the readers drain concurrently with the wait, so a large
/// transfer can never block the child on a full pipe).
final class PipeAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(newData)
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

/// The production runner (issue #49): one `Process` per invocation,严格
/// sequential USE is the coordinator's job — this type is stateless per
/// call. The watchdog (`timeoutSeconds`) bounds EVERY invocation:
/// termination is never deferred beyond it. The process inherits the
/// environment verbatim (no `GIT_*`/`SSH_*`/`ASKPASS` vars, no credential
/// machinery — the [Credentials] criterion) and reads `/dev/null` so no
/// prompt can ever block it.
public final class ProcessGitRunner: GitRunner, Sendable {

    /// The default on this machine (present: 2.54.0, Apple Git-157).
    public static let defaultGitBinary = "/usr/bin/git"

    /// The watchdog bound, seconds. Every invocation — the launch-pull's
    /// honest first-render delay included — never exceeds it.
    public static let defaultTimeoutSeconds: TimeInterval = 30

    private let gitBinary: String
    private let extraArguments: [String]
    private let timeoutSeconds: TimeInterval

    public init(
        gitBinary: String = ProcessGitRunner.defaultGitBinary,
        extraArguments: [String] = [],
        timeoutSeconds: TimeInterval = ProcessGitRunner.defaultTimeoutSeconds
    ) {
        self.gitBinary = gitBinary
        self.extraArguments = extraArguments
        self.timeoutSeconds = timeoutSeconds
    }

    /// The bounded collection of the (already-drained) pipe readers.
    /// Synchronous on purpose — `DispatchSemaphore.wait` is unavailable
    /// from asynchronous contexts, so the waits live here.
    private func collectPipeReads(_ stdoutDone: DispatchSemaphore, _ stderrDone: DispatchSemaphore) {
        _ = stdoutDone.wait(timeout: .now() + 5)
        _ = stderrDone.wait(timeout: .now() + 5)
    }

    public func run(arguments: [String]) async throws -> GitOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitBinary)
        // The hermetic `-c` overrides ride FIRST (tests only); production
        // passes none. `environment` stays nil → the process environment
        // inherited (the [Credentials] criterion).
        process.arguments = extraArguments + arguments
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw GitRunnerError.spawnFailed(String(describing: error))
        }

        // Drain BOTH pipes concurrently with the wait — a child blocked on
        // a full 64K pipe could otherwise never reach exit (the deadlock
        // this avoids), and reading after termination alone would race the
        // unread remainder. Each reader finishes at EOF, which follows
        // termination.
        let stdoutBox = PipeAccumulator()
        let stderrBox = PipeAccumulator()
        let stdoutDone = DispatchSemaphore(value: 0)
        let stderrDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            stdoutBox.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            stdoutDone.signal()
        }
        DispatchQueue.global().async {
            stderrBox.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            stderrDone.signal()
        }

        // The watchdog: ONE bounded terminate attempt when the deadline
        // passes. If the process already exited, `isRunning` is false —
        // the attempt is a no-op. (A signaled git closes its pipes, so the
        // readers above unblock and everything below proceeds honestly.)
        if timeoutSeconds > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                if process.isRunning { process.terminate() }
            }
        }

        let exitStatus: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { terminatedProcess in
                continuation.resume(returning: terminatedProcess.terminationStatus)
            }
        }

        // Both readers are done-or-seconds-from-done at this point (EOF
        // follows termination); the semaphore wait merely collects them.
        collectPipeReads(stdoutDone, stderrDone)

        return GitOutcome(
            exitStatus: exitStatus,
            stdout: String(decoding: stdoutBox.value, as: UTF8.self),
            stderr: String(decoding: stderrBox.value, as: UTF8.self))
    }
}
