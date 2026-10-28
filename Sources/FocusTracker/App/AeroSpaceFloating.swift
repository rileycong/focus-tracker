import Darwin
import Foundation
import os

/// The #44 seam logger: one-line debug-level records for every silent
/// no-op path (issue #44 criterion 2).
private let aerospaceFloatingLogger = Logger(
    subsystem: "com.chauanhcong.FocusTracker", category: "AeroSpaceFloating")

// MARK: - Pure CLI helpers

/// Pure helpers for the pinned AeroSpace CLI contract (issue #44) — the
/// argv construction and `list-windows` output parsing, kept free of any
/// process I/O so tests verify them without aerospace installed.
///
/// The contract, verified against the installed AeroSpace 0.21.3-Beta:
/// - Window-id resolution —
///   `aerospace list-windows --all --format '%{window-id} %{app-bundle-id}'`
///   emits one `"<window-id> <bundle-id>"` line per window; bundle ids
///   contain no spaces, so the first token is the id and the remainder the
///   bundle id. We match the line whose bundle id equals our own (the app
///   is single-window, so at most one line can match; the first match wins
///   defensively).
/// - Enter compact — `aerospace layout --window-id <id> floating`.
/// - Restore full — `aerospace layout --window-id <id> tiling`
///   (`layout` takes its flags BEFORE the positional target on
///   0.21.3-Beta; `--fail-if-noop` is deliberately NOT passed — repeating
///   the current layout must stay a no-op, never an error).
///
/// Nothing here touches the user's `~/.aerospace.toml` or any other file:
/// the feature is CLI invocations only (issue #44 out-of-scope).
enum AeroSpaceCLI {

    /// The app's `PRODUCT_BUNDLE_IDENTIFIER` — the one `list-windows`
    /// line the resolution matches. Hardcoded (not `Bundle.main`-derived)
    /// so tests, which run inside the test runner's bundle, resolve the
    /// same pinned id production does.
    static let appBundleID = "com.chauanhcong.FocusTracker"

    /// The pinned per-invocation deadline (issue #44): on expiry the
    /// process is killed and the whole request no-ops.
    static let invocationTimeout: TimeInterval = 2

    /// The pinned first-choice install location (the brew cask symlink).
    static let homebrewBinaryPath = "/opt/homebrew/bin/aerospace"

    /// Argv for the pinned window-id resolution.
    static func listWindowsArguments() -> [String] {
        ["list-windows", "--all", "--format", "%{window-id} %{app-bundle-id}"]
    }

    /// Argv for the pinned layout switch — flags before the positional
    /// target (see the type documentation).
    static func layoutArguments(windowID: Int, floating: Bool) -> [String] {
        ["layout", "--window-id", String(windowID), floating ? "floating" : "tiling"]
    }

    /// Parses `list-windows` output in the pinned format: returns the
    /// window id of the first `"<window-id> <bundle-id>"` line whose
    /// bundle id equals `bundleID`, or nil when no line matches or every
    /// candidate is unparsable (non-numeric id, single-token line, ...).
    /// Lines are split on `isNewline` (not the "\n" character: Swift
    /// clusters CRLF into ONE character, which `split(separator:)` would
    /// never match) and trimmed, so CR/LF/CRLF endings all parse.
    static func parseWindowID(_ output: String, bundleID: String) -> Int? {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
                continue
            }
            let idToken = line[..<separator]
            let bundleToken = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let windowID = Int(idToken), bundleToken == bundleID {
                return windowID
            }
        }
        return nil
    }

    /// Parses `list-windows` output in the pinned format and returns the
    /// FIRST FULL matching line (id + bundle id + any further columns),
    /// or nil when no line matches or every candidate is unparsable. The
    /// diagnostic harness's layout-poll probe (issue #44 amendment 2):
    /// with a format that appends `%{window-layout}`, the returned line
    /// carries the window's AeroSpace layout state verbatim.
    static func parseWindowLine(_ output: String, bundleID: String) -> String? {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
                continue
            }
            let idToken = line[..<separator]
            let remainder = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let bundleToken = remainder.split(separator: " ").first,
                Int(idToken) != nil, bundleToken == bundleID
            else { continue }
            return line
        }
        return nil
    }

    /// Resolves the aerospace executable: `/opt/homebrew/bin/aerospace`
    /// first (the pinned install location), then `aerospace` on `PATH`.
    /// nil → the caller no-ops (aerospace absent).
    static func resolveExecutableURL(
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        environmentPATH: String? = ProcessInfo.processInfo.environment["PATH"]
    ) -> URL? {
        if isExecutable(homebrewBinaryPath) {
            return URL(fileURLWithPath: homebrewBinaryPath)
        }
        for directory in (environmentPATH ?? "").split(separator: ":") {
            let candidate = "\(directory)/aerospace"
            if isExecutable(candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }
}

// MARK: - Process runner seam

/// The outcome of one aerospace CLI invocation.
struct AeroSpaceInvocationOutcome: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        /// The process ran to completion (any exit code).
        case exited(code: Int32)
        /// The pinned deadline expired; the process was killed.
        case timedOut
        /// The process could not be launched (e.g. ENOENT).
        case launchFailed
    }

    let status: Status
    let stdout: String

    /// A ready-made successful invocation (exit 0, no output).
    static let success = AeroSpaceInvocationOutcome(status: .exited(code: 0), stdout: "")

    /// Exit code 0 — the only status the #44 flow treats as success. A
    /// non-zero exit is ALSO how "AeroSpace not running" surfaces: the
    /// CLI exits non-zero when its server is unreachable, so the exit
    /// code doubles as the not-running detector (documented engineer's
    /// choice — no separate process check).
    var isSuccess: Bool {
        if case .exited(let code) = status { return code == 0 }
        return false
    }

    var statusDescription: String {
        switch status {
        case .exited(let code): "exit \(code)"
        case .timedOut: "timed out"
        case .launchFailed: "launch failed"
        }
    }
}

/// Injectable process seam: runs ONE aerospace CLI invocation under the
/// pinned deadline. Production shells out through `Process`; tests script
/// outcomes, so command assertions never run aerospace itself.
protocol AeroSpaceProcessRunning: Sendable {
    func run(_ executable: URL, _ arguments: [String]) async -> AeroSpaceInvocationOutcome
}

/// The production runner: `Process` on a utility queue with a hard
/// deadline — on expiry the process gets SIGTERM, then SIGKILL after a
/// short grace, and the invocation reports `.timedOut`. Stderr is
/// discarded; only stdout is captured (all the pinned parsing needs).
struct SystemAeroSpaceProcessRunner: AeroSpaceProcessRunning {
    private let timeout: TimeInterval

    /// - Parameter timeout: The per-invocation deadline. Production uses
    ///   the pinned `AeroSpaceCLI.invocationTimeout`; tests may shorten
    ///   it to exercise the timeout path cheaply.
    init(timeout: TimeInterval = AeroSpaceCLI.invocationTimeout) {
        self.timeout = timeout
    }

    func run(_ executable: URL, _ arguments: [String]) async -> AeroSpaceInvocationOutcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [timeout] in
                continuation.resume(
                    returning: Self.runSynchronously(
                        executable, arguments, timeout: timeout))
            }
        }
    }

    private static func runSynchronously(
        _ executable: URL, _ arguments: [String], timeout: TimeInterval
    ) -> AeroSpaceInvocationOutcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return AeroSpaceInvocationOutcome(status: .launchFailed, stdout: "")
        }

        let exitGroup = DispatchGroup()
        exitGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            exitGroup.leave()
        }

        if exitGroup.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exitGroup.wait(timeout: .now() + 0.5) == .timedOut && process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = exitGroup.wait(timeout: .now() + 1)
            }
            return AeroSpaceInvocationOutcome(status: .timedOut, stdout: "")
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return AeroSpaceInvocationOutcome(
            status: .exited(code: process.terminationStatus),
            stdout: String(decoding: data, as: UTF8.self))
    }
}

// MARK: - Scheduling seam

/// Injectable launch seam for the fire-and-forget aerospace flow (the
/// `ExpiryAlarmActionScheduling` precedent, issue #44): production
/// detaches a utility-priority task so `float`/`tile` return immediately
/// and the window transition NEVER waits on aerospace; tests capture the
/// action and run it to completion deterministically.
@MainActor
protocol AeroSpaceInvocationScheduling: AnyObject {
    func schedule(_ action: @escaping @Sendable () async -> Void)
}

@MainActor
final class SystemAeroSpaceInvocationScheduler: AeroSpaceInvocationScheduling {
    func schedule(_ action: @escaping @Sendable () async -> Void) {
        Task.detached(priority: .utility, operation: action)
    }
}

// MARK: - The seam

/// The issue #44 AeroSpace seam: best-effort float/tile of OUR window in
/// the AeroSpace tiling window manager. The compact presentation
/// controller fires `float` once on the normal→compact edge and `tile`
/// once on the compact→normal edge — fire-once-per-edge, never per
/// reconcile. Because the controller is phase-agnostic, BOTH compact
/// kinds (the session mini #37 and the break mini #43) inherit the
/// behavior automatically. Implementations must never block or fail the
/// window transition.
///
/// Issue #44 amendment 2 — COMPLETION: every request reports its outcome
/// through the completion (on the main actor). The live diagnosis
/// (amendment 2) measured WHY the controller needs it: while the window
/// is AeroSpace-TILED, the tiling engine re-asserts the window's tile
/// geometry through the ACCESSIBILITY API ~16 ms after ANY setFrame —
/// twice — so a frame applied before the float subprocess lands
/// (~100–150 ms) is overridden back to the full tile. The controller
/// therefore applies its window-frame transition in the COMPLETION, once
/// the seam reports the layout switch has taken effect (or degraded —
/// the completion fires on every path, bounded by the pinned 2 s
/// deadline). The `Bool` says whether the layout command actually
/// succeeded; the controller applies its frame either way (best-effort —
/// a degraded seam means nothing is managing the window, so a plain
/// setFrame is safe).
@MainActor
protocol CompactWindowFloating: AnyObject {
    /// Floats our window out of the AeroSpace tiling tree.
    /// - Parameters:
    ///   - completion: Fired on the main actor when the request has fully
    ///     resolved (layout command exited 0 → `true`; binary absent,
    ///     non-zero exit, timeout, unparsable output, or no matching
    ///     window → `false`). Always fires, exactly once, within the
    ///     pinned per-invocation deadline.
    func float(
        bundleID: String, completion: @escaping @MainActor @Sendable (Bool) -> Void)

    /// Returns our window to the AeroSpace tiling tree.
    /// - Parameters:
    ///   - completion: Same contract as `float`.
    func tile(
        bundleID: String, completion: @escaping @MainActor @Sendable (Bool) -> Void)
}

/// The production seam (issue #44): shells out through the pinned
/// `AeroSpaceCLI` contract — resolve our window id via `list-windows`,
/// then `layout --window-id <id> floating|tiling`.
///
/// Every request is async best-effort fire-and-forget (detached at
/// utility priority): the calling edge returns immediately and the window
/// transition NEVER waits on aerospace. The window id is re-resolved on
/// EVERY transition (engineer's choice, documented: no id caching — the
/// commands are cheap, and a fresh resolve survives AeroSpace restarts
/// and window re-creation alike; the #37 same-window invariant would
/// permit caching, but nothing is gained by it).
///
/// The completion (issue #44 amendment 2) is delivered on the main actor
/// as soon as the whole flow resolves — success OR any degradation — so
/// the controller can order its window-frame writes after the layout
/// switch (see `CompactWindowFloating` for the measured why).
///
/// Degradation — each is a silent no-op with a one-line debug log
/// (criterion 2) plus a `false` completion: binary absent (unresolvable executable / launch
/// ENOENT); non-zero exit (this also detects "AeroSpace not running");
/// the pinned 2 s deadline; unparsable `list-windows` output; no matching
/// bundle-id line. If floating failed, a later tile is still attempted
/// and no-ops the same way — the window's AeroSpace state may be left
/// as-was (the documented acceptable degraded state).
@MainActor
final class AeroSpaceCompactWindowFloating: CompactWindowFloating {

    private let runner: any AeroSpaceProcessRunning
    private let resolveExecutable: @Sendable () -> URL?
    private let scheduler: any AeroSpaceInvocationScheduling

    init(
        runner: any AeroSpaceProcessRunning = SystemAeroSpaceProcessRunner(),
        resolveExecutable: @escaping @Sendable () -> URL? = {
            AeroSpaceCLI.resolveExecutableURL()
        },
        scheduler: any AeroSpaceInvocationScheduling = SystemAeroSpaceInvocationScheduler()
    ) {
        self.runner = runner
        self.resolveExecutable = resolveExecutable
        self.scheduler = scheduler
    }

    func float(
        bundleID: String, completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        scheduleRequest(floating: true, bundleID: bundleID, completion: completion)
    }

    func tile(
        bundleID: String, completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        scheduleRequest(floating: false, bundleID: bundleID, completion: completion)
    }

    private func scheduleRequest(
        floating: Bool,
        bundleID: String,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        // Only Sendable values cross into the detached flow (the runner
        // protocol, the resolver closure, and the @Sendable completion) —
        // no MainActor state.
        let runner = self.runner
        let resolveExecutable = self.resolveExecutable
        scheduler.schedule {
            let succeeded = await Self.run(
                floating: floating, bundleID: bundleID,
                runner: runner, resolveExecutable: resolveExecutable)
            await MainActor.run { completion(succeeded) }
        }
    }

    /// The whole CLI flow, off the main actor: resolve → list-windows →
    /// parse → layout. Returns whether the layout command succeeded;
    /// every failure path logs one debug line and returns false.
    private static func run(
        floating: Bool,
        bundleID: String,
        runner: any AeroSpaceProcessRunning,
        resolveExecutable: @escaping @Sendable () -> URL?
    ) async -> Bool {
        let target = floating ? "floating" : "tiling"
        guard let executable = resolveExecutable() else {
            aerospaceFloatingLogger.debug(
                "AeroSpace: binary not found — \(target, privacy: .public) request is a no-op")
            return false
        }
        let resolution = await runner.run(
            executable, AeroSpaceCLI.listWindowsArguments())
        guard resolution.isSuccess else {
            aerospaceFloatingLogger.debug(
                "AeroSpace: list-windows failed (\(resolution.statusDescription, privacy: .public)) — no-op")
            return false
        }
        guard let windowID = AeroSpaceCLI.parseWindowID(
            resolution.stdout, bundleID: bundleID)
        else {
            aerospaceFloatingLogger.debug(
                "AeroSpace: no \(bundleID, privacy: .public) window in list-windows output — no-op")
            return false
        }
        let layout = await runner.run(
            executable, AeroSpaceCLI.layoutArguments(windowID: windowID, floating: floating))
        if !layout.isSuccess {
            aerospaceFloatingLogger.debug(
                "AeroSpace: layout \(target, privacy: .public) for window \(windowID) failed (\(layout.statusDescription, privacy: .public)) — window left as-is")
            return false
        }
        return true
    }
}
