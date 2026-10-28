import Foundation

/// The vault-sync coordinator (issue #49): owns BOTH loops (the 60 s
/// write-debounce, the 15-min pull tick — its own Tasks, no `Timer.publish`,
/// no SwiftUI clocks) and enforces single-flight. Entries arrive from the
/// two store actors, the main actor (settings UI, launch, termination) and
/// its own loops; the actor isolation plus the `cycleTask` lease keep
/// exactly ONE cycle in flight and discharge misses as EXACTLY ONE
/// follow-up (never an unbounded queue).
///
/// # Pinned cycle shape ([Push] criterion — ORDER matters, pull-FIRST so a
/// fast-forwardable remote never becomes divergence)
/// 1. ensure the vault's `origin` exists and points at the configured URL
///    (`git remote add`/`set-url` — the SETTING is the single source of
///    truth; a Settings-side change takes effect on the next cycle);
/// 2. `git -C <vault> fetch origin`;
/// 3. compare HEAD vs `origin/<branch>` (`rev-list --left-right --count`)
///    and decide through the ONE pure `SyncPlan.decide` — strictly behind →
///    `merge --ff-only`; divergence → STOP (typed, surfaced, no auto-merge,
///    no force);
/// 4. `git add -- Tasks Logs` — ONLY those two pathspecs (§3 ownership; the
///    engine never creates `.gitignore` — VS-2 owns it);
/// 5. `git commit` only when something is staged;
/// 6. `git push` (`-u origin <branch>` when the branch has no upstream).
/// Every invocation: `git -C <vault> …`, one Process each, strictly
/// sequential, stdout+stderr captured, watchdog-bounded. Any step failure =
/// the ONE typed `SyncCycleError` carrying the step + stderr tail. The
/// unborn HEAD is legal: `.proceed` + `push -u` creates the branch.
///
/// # Health
/// Reported ONLY through `onHealthChange` (the model mirrors it; here the
/// value is also kept for direct actor reads). Static preconditions are
/// re-evaluated at every cycle start WITHOUT spawning — when VS-2 later
/// initializes the vault's repo, the next cycle proceeds with NO app
/// change. `.error` is sticky until a later successful cycle reports
/// `.idle`; `.unavailable` wins whenever the statics fail (sync stays off).
public actor SyncCoordinator {

    // MARK: - Configuration

    public struct Configuration: Sendable {
        public let vaultURL: URL
        public let remoteURL: String
        public let gitBinary: String
        /// The ONLY sanctioned override — the tests' hermetic `-c
        /// user.name=… -c user.email=…` identities. Production: empty.
        public let extraArguments: [String]
        /// The write-debounce window (production 60 s): a pending sync
        /// fires this long after the OLDEST un-synced write; writes arriving
        /// while pending coalesce and do NOT extend the window.
        public let debounceIntervalSeconds: TimeInterval
        /// The pull-tick interval (production 15 min).
        public let pullIntervalSeconds: TimeInterval
        /// The per-invocation watchdog (seconds).
        public let watchdogTimeoutSeconds: TimeInterval

        public init(
            vaultURL: URL,
            remoteURL: String,
            gitBinary: String = ProcessGitRunner.defaultGitBinary,
            extraArguments: [String] = [],
            debounceIntervalSeconds: TimeInterval = 60,
            pullIntervalSeconds: TimeInterval = 900,
            watchdogTimeoutSeconds: TimeInterval = ProcessGitRunner.defaultTimeoutSeconds
        ) {
            self.vaultURL = vaultURL
            self.remoteURL = remoteURL
            self.gitBinary = gitBinary
            self.extraArguments = extraArguments
            self.debounceIntervalSeconds = debounceIntervalSeconds
            self.pullIntervalSeconds = pullIntervalSeconds
            self.watchdogTimeoutSeconds = watchdogTimeoutSeconds
        }
    }

    // MARK: - State

    public let configuration: Configuration
    private let runner: any GitRunner

    /// The last reported health; also handed to `onHealthChange`. Starts
    /// `.disabled` (a launch starts honest until the first attempt/apply).
    public private(set) var health: SyncHealth = .disabled

    /// The configured remote — the single source of truth for the next
    /// cycle's ensure-origin. Updated by the model when the setting changes
    /// (no loops restart; the SETTING governs, the next cycle takes it).
    public private(set) var remoteURL: String

    /// Whether sync is currently on. A disabled coordinator is inert BY
    /// CONSTRUCTION: no loops, every entry returns without spawning.
    public private(set) var isEnabled = false

    /// Fired with (reportingCoordinator, health) — the model mirrors the
    /// CURRENT coordinator's health only (identity-guarded there), so a
    /// discarded coordinator's late reports are ignored.
    public let onHealthChange: (@Sendable (SyncCoordinator, SyncHealth) -> Void)?

    /// Fired after a cycle's fast-forward actually landed (working tree
    /// changed under `Tasks/`/`Logs/`) — the model MUST reload, else the #7
    /// staleness guard throws `.vaultChangedExternally` on the very next
    /// write. A divergence-STOP changes nothing on disk → never fired there.
    public let onFastForwarded: (@Sendable (SyncCoordinator) -> Void)?

    /// The in-flight cycle lease (single-flight). Non-nil ⟺ a cycle (or the
    /// follow-up discharge loop) owns the coordinator.
    private var cycleTask: Task<SyncPullOutcome, Never>?

    /// Exactly ONE interest in a follow-up, whatever missed (a mid-cycle
    /// write, a tick while a cycle ran, a queued pullOnce) — never an
    /// unbounded queue.
    private var followUpPending = false

    /// The 60 s debounce Task (max-wait, not trailing-reset): nil when no
    /// window is pending; a write arriving while it is pending coalesces.
    private var debounceTask: Task<Void, Never>?

    /// The 15-min pull-loop Task; cancelled by `applyEnabled(false)`.
    private var periodicTask: Task<Void, Never>?

    /// Whether a write-triggered sync still owes a push (cleared only after
    /// a successful push step — a failed/diverged cycle keeps it, so the
    /// quit flush still runs).
    private var hasUnSyncedWrites = false

    /// Single-flight flag of the settings-UI reachability probe (ONE
    /// bounded `ls-remote`, never looping; a probe during a cycle is
    /// skipped — the cycle's own fetch failure IS the verdict).
    private var probeInFlight = false

    /// The fixed commit message (a coalescing engine needs no wit).
    private static let commitMessage = "FocusTracker vault sync"

    // MARK: - Init

    public init(
        configuration: Configuration,
        runner: (any GitRunner)? = nil,
        onHealthChange: (@Sendable (SyncCoordinator, SyncHealth) -> Void)? = nil,
        onFastForwarded: (@Sendable (SyncCoordinator) -> Void)? = nil
    ) {
        self.configuration = configuration
        self.runner = runner ?? ProcessGitRunner(
            gitBinary: configuration.gitBinary,
            extraArguments: configuration.extraArguments,
            timeoutSeconds: configuration.watchdogTimeoutSeconds)
        self.remoteURL = configuration.remoteURL
        self.onHealthChange = onHealthChange
        self.onFastForwarded = onFastForwarded
    }

    // MARK: - Enabling (the shipped-by-default state is inert BY CONSTRUCTION)

    /// Applies the persisted toggle. Disabling: cancels BOTH loops (the
    /// debounce and the 15-min tick) and reports `.disabled` — every later
    /// entry (`noteVaultWrite`/`pullOnce`/`flush`/`probeReachability`)
    /// returns WITHOUT spawning. Enabling: reports the honest STATIC health
    /// (`.unavailable` + reason, or `.idle`) and starts the 15-min pull
    /// loop — NO pull, NO push, NO probe (those stay at their pinned
    /// triggers; the settings-UI flip adds its own probe, which the sheet's
    /// flow performs through `probeReachability()`).
    public func applyEnabled(_ enabled: Bool) async {
        isEnabled = enabled
        if enabled {
            reportHealth(evaluateStaticHealth())
            startPeriodicLoopIfPossible()
        } else {
            periodicTask?.cancel()
            periodicTask = nil
            debounceTask?.cancel()
            debounceTask = nil
            reportHealth(.disabled)
        }
    }

    /// Re-points the configured remote (the model calls this when the
    /// setting changes). No loops restart — the SETTING is the source of
    /// truth and the next cycle's ensure-origin adopts it.
    public func setRemote(_ newRemote: String) {
        remoteURL = newRemote
    }

    /// Stops everything (the model's re-point / disable path): loops
    /// cancelled best-effort, entries inert. In-flight cycles complete
    /// (best-effort cancellation — the documented posture); their reports
    /// are identity-guarded away by the model once it swaps coordinators.
    public func stop() {
        isEnabled = false
        periodicTask?.cancel()
        periodicTask = nil
        debounceTask?.cancel()
        debounceTask = nil
    }

    // MARK: - Entries (the pinned triggers)

    /// The [Push] trigger: every successful vault write lands here. With
    /// sync ON it opens the debounce window — firing 60 s (the configured
    /// interval) after the OLDEST un-synced write; later writes coalesce
    /// and do NOT extend the window. A write landing MID-CYCLE enqueues
    /// exactly ONE follow-up. Disabled: returns immediately, zero spawns.
    public func noteVaultWrite() {
        guard isEnabled else { return }
        hasUnSyncedWrites = true
        if cycleTask != nil {
            followUpPending = true
            return
        }
        guard debounceTask == nil else { return }
        let interval = configuration.debounceIntervalSeconds
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            await self.fireDebounce()
        }
    }


    /// The [Pull triggers] seam (launch; #50's before-import call): the
    /// pull-ONLY cycle — ensure-origin → fetch → fast-forward-if-strictly-
    /// behind → (divergence-STOP) — NO add/commit/push (a pull trigger
    /// never pushes; crash-leftover uncommitted changes ride the next
    /// WRITE-triggered cycle). Single-flight: a cycle already in flight
    /// makes this record ONE follow-up interest and await THAT cycle's
    /// outcome (its pull-half is this call's honest verdict).
    public func pullOnce() async -> SyncPullOutcome {
        guard isEnabled else { return .disabled }
        return await runCycle(kind: .pull)
    }

    /// The [Quit flush] trigger: the full push cycle ONLY when un-synced
    /// work exists; failure never vetoes or defers termination (the
    /// semaphore-bounded caller ignores the outcome). If a cycle is in
    /// flight, it is awaited first, then this flush runs its OWN full push
    /// cycle — the freshest state ships.
    public func flush() async -> SyncPullOutcome {
        guard isEnabled else { return .disabled }
        guard hasUnSyncedWrites else { return .upToDate }
        if let existing = cycleTask {
            _ = await existing.value
        }
        return await runCycle(kind: .push)
    }

    /// The settings-UI reachability probe ([Health]): ONE bounded
    /// `git ls-remote` against the CONFIGURED remote, single-flight,
    /// invoked ONLY from the settings-UI context (sheet-appear + input
    /// change + the pinned toggle flip) — never looping. Within sync cycles
    /// the cycle's own `fetch` failure IS the reachability verdict, so a
    /// probe during a cycle is skipped. Failure surfaces `.error` (sticky);
    /// success changes nothing (the row's error stays until the next
    /// successful CYCLE — the pinned stickiness).
    public func probeReachability() async {
        guard isEnabled else { return }
        if cycleTask != nil || probeInFlight { return }
        if let reason = SyncHealthEvaluator.staticFailureReason(
            vaultPath: configuration.vaultURL.path,
            remoteURL: remoteURL,
            gitBinary: configuration.gitBinary)
        {
            reportHealth(.unavailable(reason: reason))
            return
        }
        probeInFlight = true
        defer { probeInFlight = false }
        let arguments = ["-C", configuration.vaultURL.path, "ls-remote", remoteURL]
        do {
            _ = try await runner.run(arguments: arguments)
        } catch {
            reportHealth(.error("the remote was not reachable — \(spawnTail(error))"))
        }
    }

    // MARK: - Loop plumbing

    private func fireDebounce() async {
        debounceTask = nil
        _ = await runCycle(kind: .push)
    }

    private func startPeriodicLoopIfPossible() {
        periodicTask?.cancel()
        let interval = configuration.pullIntervalSeconds
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                _ = await self.runCycle(kind: .pull)
            }
        }
    }

    /// Single-flight entry: the FIRST caller leases `cycleTask` and (after
    /// its own cycle) discharges `followUpPending` as EXACTLY ONE follow-up
    /// — a push when writes are pending (the superset: it also performs the
    /// missed pull), otherwise a pull. Every other caller during a cycle
    /// records the SAME single interest and awaits the in-flight outcome.
    private func runCycle(kind: SyncCycleKind) async -> SyncPullOutcome {
        if let existing = cycleTask {
            followUpPending = true
            return await existing.value
        }
        let leased = Task { [weak self] () -> SyncPullOutcome in
            guard let self else { return .disabled }
            return await self.performCycle(kind: kind)
        }
        cycleTask = leased
        var outcome = await leased.value
        cycleTask = nil
        while followUpPending, isEnabled, !Task.isCancelled {
            followUpPending = false
            let followKind: SyncCycleKind = hasUnSyncedWrites ? .push : .pull
            let followTask = Task { [weak self] () -> SyncPullOutcome in
                guard let self else { return .disabled }
                return await self.performCycle(kind: followKind)
            }
            cycleTask = followTask
            outcome = await followTask.value
            cycleTask = nil
        }
        return outcome
    }

    // MARK: - The cycle

    private func performCycle(kind: SyncCycleKind) async -> SyncPullOutcome {
        // Static preconditions FIRST — a FileManager probe, never a spawn:
        // while unavailable the engine stays silent ("sync stays off" +
        // reason), and VS-2's later `git init` inside the vault heals the
        // very next cycle with NO app change.
        if let reason = SyncHealthEvaluator.staticFailureReason(
            vaultPath: configuration.vaultURL.path,
            remoteURL: remoteURL,
            gitBinary: configuration.gitBinary)
        {
            reportHealth(.unavailable(reason: reason))
            return .unavailable(reason)
        }
        do {
            try await ensureOrigin()
            try await runChecked(.fetch, ["fetch", "origin"])

            let graph = try await readGraphState()
            var fastForwarded = false
            switch SyncPlan.decide(graph) {
            case .proceed:
                break
            case .fastForward:
                _ = try await runChecked(
                    .fastForward, ["merge", "--ff-only", "origin/\(graphBranchName)"])
                fastForwarded = true
            case .divergenceStop:
                // STOP: nothing on disk changed, no reload, `.error` sticky
                // until the histories are reconciled and a later cycle
                // succeeds — the app continues FULLY meanwhile (§7.4: the
                // contract's answer, "auto-merge of ANY kind" a non-goal).
                let failure = SyncCycleError.diverged(
                    ahead: graph.ahead, behind: graph.behind)
                reportHealth(.error(failure.displayReason))
                return .diverged
            }

            if kind == .push {
                try await runChecked(.stageChanges, ["add", "--", "Tasks", "Logs"])
                // Expected-nonzero probes run UNchecked: exit 1 = something
                // staged (or no upstream); any other exit still reaches the
                // typed step failure through the FOLLOWING invocation.
                let diffOutcome = try await runUnchecked(["diff", "--cached", "--quiet"])
                if diffOutcome.exitStatus != 0 {
                    try await runChecked(.commit, ["commit", "-m", Self.commitMessage])
                }
                // `-u origin <branch>` when the branch has no upstream —
                // the unborn-HEAD first push also creates the remote branch.
                let upstreamOutcome = try? await runUnchecked(
                    ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"])
                if let upstreamOutcome, upstreamOutcome.exitStatus == 0 {
                    try await runChecked(.push, ["push"])
                } else {
                    try await runChecked(
                        .push, ["push", "-u", "origin", graphBranchName])
                }
                hasUnSyncedWrites = false
            }

            if fastForwarded {
                onFastForwarded?(self)
            }
            reportHealth(.idle)
            return fastForwarded ? .fastForwarded : .upToDate
        } catch let error as SyncCycleError {
            reportHealth(.error(error.displayReason))
            return .failed(error)
        } catch {
            reportHealth(.error("sync failed — \(error)"))
            return .failed(SyncCycleError(step: .fetch, detail: String(describing: error)))
        }
    }

    /// The comparison's working branch name — read during `readGraphState`
    /// and reused by the fast-forward/push steps. Empty only before the
    /// first read; the steps that use it always run after.
    private var graphBranchName = ""

    /// ensure-origin (cycle step 1): the vault's `origin` must exist AND
    /// point at the CONFIGURED remote — the SETTING is the single source of
    /// truth, so a Settings-side change takes effect on the next cycle.
    private func ensureOrigin() async throws {
        let list = try await runChecked(.ensureOrigin, ["remote"])
        let names = list.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if names.contains("origin") {
            _ = try await runChecked(
                .ensureOrigin, ["remote", "set-url", "origin", remoteURL])
        } else {
            _ = try await runChecked(.ensureOrigin, ["remote", "add", "origin", remoteURL])
        }
    }

    /// History comparison (cycle step 3's INPUT): branch → unborn? →
    /// remote-branch? → counts. Detached HEAD is a typed failure (honest,
    /// never a silent masquerade).
    private func readGraphState() async throws -> SyncGraphState {
        let branchOutcome = try await runChecked(
            .compareHistory, ["symbolic-ref", "--short", "HEAD"])
        let branch = branchOutcome.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else {
            throw SyncCycleError(step: .compareHistory, detail: "empty branch name")
        }
        graphBranchName = branch
        let headOutcome = try await runUnchecked(
            ["rev-parse", "--verify", "--quiet", "HEAD"])
        let headUnborn = headOutcome.exitStatus != 0
        let remoteOutcome = try await runUnchecked(
            ["rev-parse", "--verify", "--quiet", "origin/\(branch)"])
        let remoteBranchExists = remoteOutcome.exitStatus == 0

        if headUnborn {
            var behind = 0
            if remoteBranchExists {
                let countOutcome = try await runChecked(
                    .compareHistory, ["rev-list", "--count", "origin/\(branch)"])
                behind = try parseCount(countOutcome.stdout)
            }
            return SyncGraphState(
                headUnborn: true, remoteBranchExists: remoteBranchExists,
                ahead: 0, behind: behind)
        }
        var ahead = 0
        var behind = 0
        if remoteBranchExists {
            let countOutcome = try await runChecked(
                .compareHistory,
                ["rev-list", "--left-right", "--count", "HEAD...origin/\(branch)"])
            let counts = try parseLeftRight(countOutcome.stdout)
            ahead = counts.0
            behind = counts.1
        }
        return SyncGraphState(
            headUnborn: false, remoteBranchExists: remoteBranchExists,
            ahead: ahead, behind: behind)
    }

    // MARK: - Invocation helpers

    /// One `git -C <vault> …` invocation; non-zero exit = the typed
    /// step failure carrying the stderr tail.
    @discardableResult
    private func runChecked(
        _ step: SyncCycleStep, _ arguments: [String]
    ) async throws -> GitOutcome {
        let outcome = try await runUnchecked(arguments)
        guard outcome.exitStatus == 0 else {
            throw SyncCycleError(step: step, detail: SyncCycleError.detailTail(from: outcome))
        }
        return outcome
    }

    /// One invocation whose non-zero exit is EXPECTED data (the unborn /
    /// no-remote-branch / no-upstream probes) — spawn failures still throw.
    @discardableResult
    private func runUnchecked(_ arguments: [String]) async throws -> GitOutcome {
        do {
            return try await runner.run(
                arguments: ["-C", configuration.vaultURL.path] + arguments)
        } catch {
            throw SyncCycleError(
                step: .fetch, detail: spawnTail(error))
        }
    }

    private func spawnTail(_ error: Error) -> String {
        if let runnerError = error as? GitRunnerError, case .spawnFailed(let reason) = runnerError {
            return reason
        }
        return String(describing: error)
    }

    private func parseCount(_ text: String) throws -> Int {
        guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw SyncCycleError(
                step: .compareHistory,
                detail: "unparsable rev-list count: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return value
    }

    private func parseLeftRight(_ text: String) throws -> (Int, Int) {
        let parts = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t")
            .compactMap { Int($0) }
        guard parts.count == 2 else {
            throw SyncCycleError(
                step: .compareHistory,
                detail: "unparsable rev-list --left-right --count output: "
                    + "\(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return (parts[0], parts[1])
    }

    // MARK: - Health

    private func evaluateStaticHealth() -> SyncHealth {
        if let reason = SyncHealthEvaluator.staticFailureReason(
            vaultPath: configuration.vaultURL.path,
            remoteURL: remoteURL,
            gitBinary: configuration.gitBinary)
        {
            return .unavailable(reason: reason)
        }
        return .idle
    }

    private func reportHealth(_ newHealth: SyncHealth) {
        health = newHealth
        onHealthChange?(self, newHealth)
    }
}
