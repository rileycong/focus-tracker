import XCTest
import SyncCore
@testable import FocusTracker

/// The #49 model-level integration floor (FocusVault FT-1): the sync-OFF
/// zero-spawn invariant, the launch-pull-BEFORE-first-load, the post-ff
/// reload (the next write does NOT hit `.vaultChangedExternally`), and the
/// #50 seam (`pullVaultOnce` — single-flight, outcome recorded; #49
/// implements NO import wiring) — plus the #51 debounce push and the #52
/// termination-flush regression (the bounded, off-actor quit flush). Every
/// test builds its OWN bare remote + vault under the temp dir (`file://`
/// URLs, hermetic `-c` identities via the injected runner); the real vault
/// and the repo's fixtures/ are never touched, the model's persistence (the
/// #13 session state) is pointed at a disposable directory, and the app's
/// own UserDefaults suite is never used.
@MainActor
final class AppModelSyncTests: XCTestCase {

    // MARK: - Fixture

    enum FixtureError: Error, CustomStringConvertible {
        case commandFailed(command: String, outcome: GitOutcome)

        var description: String {
            switch self {
            case .commandFailed(let command, let outcome):
                return "git failed: \(command) — \(outcome.stderr)"
            }
        }
    }

    /// Counts spawns AND forwards to the real runner — the counting seam
    /// doubled as the hermetic-identity carrier.
    final class CountingPassthroughRunner: GitRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private let behind: any GitRunner

        init(behind: any GitRunner) {
            self.behind = behind
        }

        var invocationCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        /// Synchronous — the lock calls must not sit directly in an async
        /// function under this Foundation marking.
        private func bump() {
            lock.lock()
            defer { lock.unlock() }
            count += 1
        }

        func run(arguments: [String]) async throws -> GitOutcome {
            bump()
            return try await behind.run(arguments: arguments)
        }
    }

    /// A plain counting runner (fake outcomes, zero processes) — the
    /// disabled coordinator must never reach it.
    final class CountingStubRunner: GitRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var invocationCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        /// Synchronous — see `CountingPassthroughRunner.bump`.
        private func bump() {
            lock.lock()
            defer { lock.unlock() }
            count += 1
        }

        func run(arguments: [String]) async throws -> GitOutcome {
            bump()
            return GitOutcome(exitStatus: 0, stdout: "", stderr: "")
        }
    }

    /// Records every invocation's arguments (fake outcomes, zero processes)
    /// — the issue #57 heal test must never let a unit test reach the
    /// network/ssh: the reachability probe's `ls-remote` lands here.
    final class RecordingStubRunner: GitRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [[String]] = []

        var invocations: [[String]] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        /// Synchronous — see `CountingPassthroughRunner.bump`.
        private func record(_ arguments: [String]) {
            lock.lock()
            defer { lock.unlock() }
            recorded.append(arguments)
        }

        func run(arguments: [String]) async throws -> GitOutcome {
            record(arguments)
            return GitOutcome(exitStatus: 0, stdout: "", stderr: "")
        }
    }

    /// Wraps the real runner; delays the FIRST invocation after `arm()`
    /// once (the `OnceDelayingRunner` precedent,
    /// SyncCoordinatorTests.swift:216–243, with ONE deliberate adaptation:
    /// the delay starts DISARMED — bootstrap's launch-pull always spawns,
    /// so an init-armed once-delay would be consumed there and never reach
    /// the termination flush; the #52 scenario's arithmetic (delay ≥ 1 s
    /// vs the injected 0.5 s bound) requires the delay to land ON the
    /// flush's cycle so the flush genuinely outlasts the bound and
    /// completes off-actor AFTER the function has returned).
    final class OnceDelayingRunner: GitRunner, @unchecked Sendable {
        private let behind: any GitRunner
        private let delayNanoseconds: UInt64
        private let lock = NSLock()
        private var armed = false
        private var taken = false

        init(behind: any GitRunner, delaySeconds: TimeInterval) {
            self.behind = behind
            self.delayNanoseconds = UInt64(delaySeconds * 1_000_000_000)
        }

        /// Arms the one-shot delay. Synchronous (the lock-call rule below).
        func arm() {
            lock.lock()
            defer { lock.unlock() }
            armed = true
        }

        func run(arguments: [String]) async throws -> GitOutcome {
            if takeDelayIfArmed() {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            return try await behind.run(arguments: arguments)
        }

        /// Whether the armed delay was TAKEN by some invocation — i.e. a
        /// cycle actually STARTED and is (or was) sleeping in the delay.
        /// The #52 off-actor witness: the detached flush reaches the
        /// runner while the caller's main thread is still blocked in the
        /// bounded wait; an inherited-`Task {}` shape could NOT (the main
        /// actor is busy, so the body stays unscheduled until the wait
        /// times out). Synchronous (the lock-call rule above).
        var hasTakenDelay: Bool {
            lock.lock()
            defer { lock.unlock() }
            return taken
        }

        /// Synchronous (the lock calls must not sit directly in an async
        /// function under this Foundation marking).
        private func takeDelayIfArmed() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            let shouldDelay = armed
            armed = false
            if shouldDelay { taken = true }
            return shouldDelay
        }
    }

    /// Issue #53's launch-frame double: a GATE, not a clock. Modeled on
    /// `OnceDelayingRunner` but with explicit gate semantics instead of
    /// `Task.sleep`: while the gate is closed, `run(arguments:)` records
    /// itself in-flight (the NSLock idiom) and PARKS on a test-controlled
    /// continuation; once `open()`ed, parked invocations resume and later
    /// invocations pass straight through. The in-flight window is thereby
    /// observably infinite — the test releases it only AFTER asserting the
    /// intermediate `.opening` frame — with zero real-time dependence on
    /// the critical path (`OnceDelayingRunner`'s clock delay would race
    /// the observation of the intermediate state; #53 asserts one, where
    /// the #52 shape asserts final states).
    final class GatedRunner: GitRunner, @unchecked Sendable {
        private let behind: any GitRunner
        private let lock = NSLock()
        private var opened = false
        private var inFlight = 0
        private var parked: [CheckedContinuation<Void, Never>] = []

        init(behind: any GitRunner) {
            self.behind = behind
        }

        /// The number of invocations that have entered `run` and not yet
        /// returned — the in-flight witness (issue #53: while the gate is
        /// closed, this is a parked launch-pull step, deterministically).
        var inFlightCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return inFlight
        }

        /// Opens the gate (idempotent): parked invocations resume, later
        /// invocations pass through. Synchronous (the lock-call rule).
        func open() {
            for continuation in takeParkedAndOpen() {
                continuation.resume()
            }
        }

        func run(arguments: [String]) async throws -> GitOutcome {
            let shouldPark = enterAndCount()
            defer { leave() }
            if shouldPark {
                await withCheckedContinuation {
                    (continuation: CheckedContinuation<Void, Never>) in
                    if parkIfStillClosed(continuation) {
                        continuation.resume()
                    }
                }
            }
            return try await behind.run(arguments: arguments)
        }

        /// Synchronous (the lock-call rule).
        private func enterAndCount() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            inFlight += 1
            return !opened
        }

        /// Synchronous (the lock-call rule).
        private func leave() {
            lock.lock()
            defer { lock.unlock() }
            inFlight -= 1
        }

        /// Parks the continuation unless the gate opened meanwhile (then
        /// true — the caller resumes immediately; the parked array was
        /// drained by `open`). Synchronous (the lock-call rule).
        private func parkIfStillClosed(
            _ continuation: CheckedContinuation<Void, Never>
        ) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if opened { return true }
            parked.append(continuation)
            return false
        }

        /// Synchronous (the lock-call rule).
        private func takeParkedAndOpen() -> [CheckedContinuation<Void, Never>] {
            lock.lock()
            defer { lock.unlock() }
            opened = true
            let drained = parked
            parked = []
            return drained
        }
    }

    /// One disposable world: bare remote + vault (+ Lifebot clone when the
    /// scenario needs an external Tasks/ writer).
    final class SyncModelFixture: @unchecked Sendable {
        static let identity = [
            "-c", "user.name=FT Tests", "-c", "user.email=ft-tests@example.com",
        ]

        let rootURL: URL
        let remotePath: String
        let remoteURLString: String
        let vaultURL: URL
        let lifebotURL: URL
        let persistenceDirectory: URL
        let runner = ProcessGitRunner(extraArguments: identity)

        /// The C0 seed task's ID (the Lifebot's rewrite keeps it).
        private(set) var seedTaskID = UUID()

        static func make(withLifebotClone: Bool = false) async throws -> SyncModelFixture {
            let fixture = SyncModelFixture()
            try await fixture.build(withLifebotClone: withLifebotClone)
            return fixture
        }

        private init() {
            rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("ft49-model-\(UUID().uuidString)", isDirectory: true)
            remotePath = rootURL.appendingPathComponent("origin.git").path
            remoteURLString = rootURL.appendingPathComponent("origin.git").absoluteString
            vaultURL = rootURL.appendingPathComponent("vault", isDirectory: true)
            lifebotURL = rootURL.appendingPathComponent("lifebot", isDirectory: true)
            persistenceDirectory = rootURL.appendingPathComponent(
                "persistence", isDirectory: true)
        }

        private func build(withLifebotClone: Bool) async throws {
            try FileManager.default.createDirectory(
                at: rootURL, withIntermediateDirectories: true)
            try await run(["init", "--bare", "-b", "main", "origin.git"], at: rootURL.path)
            try FileManager.default.createDirectory(
                at: vaultURL.appendingPathComponent("Tasks", isDirectory: true),
                withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: vaultURL.appendingPathComponent("Logs", isDirectory: true),
                withIntermediateDirectories: true)
            try await run(["init", "-b", "main"], at: vaultURL.path)
            try await run(
                ["remote", "add", "origin", remoteURLString], at: vaultURL.path)
            // The C0 seed: a REAL, schema-valid task file (the model parses).
            let seed = try makeTask(title: "Seed")
            seedTaskID = seed.id
            try Data(markdown(for: seed).utf8).write(
                to: vaultURL.appendingPathComponent("Tasks/seed.md"))
            try await run(["add", "--", "Tasks", "Logs"], at: vaultURL.path)
            try await run(["commit", "-m", "seed"], at: vaultURL.path)
            try await run(["push", "-u", "origin", "main"], at: vaultURL.path)
            if withLifebotClone {
                try await run(
                    ["clone", "--quiet", remoteURLString, lifebotURL.path],
                    at: rootURL.path)
            }
        }

        @discardableResult
        func run(_ arguments: [String], at directory: String) async throws -> GitOutcome {
            let outcome = try await runner.run(arguments: ["-C", directory] + arguments)
            guard outcome.exitStatus == 0 else {
                throw FixtureError.commandFailed(
                    command: "git " + arguments.joined(separator: " "), outcome: outcome)
            }
            return outcome
        }

        func makeTask(title: String, id: UUID = UUID()) throws -> TaskItem {
            try TaskItem(id: id, title: title, categories: [Category(name: "Admin")])
        }

        func markdown(for task: TaskItem) -> String {
            FrontmatterCodec.encode(task: task, body: "")
        }

        /// Writes a NEW schema-valid task file into the Lifebot's Tasks/.
        func writeLifebotTask(title: String, fileName: String) throws {
            let task = try makeTask(title: title)
            try Data(markdown(for: task).utf8).write(
                to: lifebotURL.appendingPathComponent("Tasks/\(fileName)"))
        }

        /// The Lifebot's rewrite ritual: ff-pull, rewrite the SAME seed
        /// (same ID, new title), commit, push. Hermetic identity via the
        /// runner's `-c` flags — never the machine's global git config.
        func lifebotRewriteSeed(title: String) async throws {
            try await run(
                ["pull", "--ff-only", "origin", "main"], at: lifebotURL.path)
            let updated = try makeTask(title: title, id: seedTaskID)
            try Data(markdown(for: updated).utf8).write(
                to: lifebotURL.appendingPathComponent("Tasks/seed.md"))
            try await run(["add", "-A"], at: lifebotURL.path)
            try await run(["commit", "-m", "lifebot: \(title)"], at: lifebotURL.path)
            try await run(["push"], at: lifebotURL.path)
        }

        func waitUntil(
            _ description: String, timeoutSeconds: TimeInterval = 10,
            file: StaticString = #filePath, line: UInt = #line,
            _ condition: @MainActor () async throws -> Bool
        ) async throws {
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while Date() < deadline {
                if try await condition() { return }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTFail("Timed out waiting: \(description)", file: file, line: line)
        }
    }

    // MARK: - Model plumbing

    private func makeModel(
        fixture: SyncModelFixture,
        syncEnabled: Bool,
        runner: (any SyncCore.GitRunner)? = nil,
        debounceInterval: TimeInterval = 0.2,
        terminationFlushTimeout: TimeInterval = AppModel.terminationFlushTimeoutSeconds,
        // Issue #57 pass-through: `.none` (the default) = the fixture's own
        // remote, so every existing test is unchanged; `.some(nil)` = the
        // remote key left UNSET; `.some("…")` = that exact stored value.
        remoteURL: String?? = .none
    ) throws -> AppModel {
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: "ft49-appmodel-\(UUID().uuidString)"))
        var settings = AppSettings(defaults: defaults)
        settings.vaultPath = fixture.vaultURL.path
        settings.vaultSyncEnabled = syncEnabled
        switch remoteURL {
        case .none:
            settings.vaultSyncRemote = fixture.remoteURLString
        case .some(let explicit):
            settings.vaultSyncRemote = explicit
        }
        return AppModel(
            settings: settings,
            persistenceDirectory: fixture.persistenceDirectory,
            syncDebounceInterval: debounceInterval,
            syncPullInterval: 3600,
            syncTerminationFlushTimeout: terminationFlushTimeout,
            // Hermetic identities on EVERY engine invocation (the ONLY
            // sanctioned override, via the injected runner) — the machine's
            // global git config is never consulted.
            syncGitRunner: runner
                ?? ProcessGitRunner(extraArguments: SyncModelFixture.identity))
    }

    // MARK: - [Sync OFF]: zero spawns across bootstrap + writes + the flush

    func testSyncOffSpawnsNothingAcrossBootstrapWritesAndTerminationFlush()
        async throws
    {
        let fixture = try await SyncModelFixture.make()
        let counting = CountingStubRunner()
        let model = try makeModel(fixture: fixture, syncEnabled: false, runner: counting)

        // bootstrap: the launch-pull skips INSTANTLY (disabled → no spawns,
        // no watchdog delay), then the ordinary #13 flow.
        await model.bootstrap()
        XCTAssertEqual(counting.invocationCount, 0)

        // A vault write: the #49 hook exists (the cheap in-memory flag) but
        // the coordinator is inert BY CONSTRUCTION — zero spawns, and the
        // debounce window never even opens.
        _ = try await model.createTask(try fixture.makeTask(title: "Sync Off"))
        model.noteVaultWrite()
        XCTAssertEqual(counting.invocationCount, 0)
        XCTAssertEqual(model.syncHealth, .disabled)

        // The #49 termination flush: skipped instantly, zero spawns.
        model.flushSyncForTermination()
        XCTAssertEqual(counting.invocationCount, 0)
    }

    // MARK: - [Issue #57] no default remote: blank remote = zero git, origin untouched

    /// The pinned zero-git proof: a REAL repo whose vault ALREADY has an
    /// `origin`, a model with the remote key UNSET and sync ON — every
    /// entry point that could spawn git (bootstrap, the toggle flip, a
    /// vault write + the debounce window, the pull-once seam, the quit
    /// flush, the probe, a garbage `setSyncRemote`) must spawn NOTHING,
    /// and the vault's `origin` must stay byte-for-byte untouched.
    func testBlankRemoteSpawnsNoGitAndNeverTouchesAnExistingOrigin() async throws {
        let fixture = try await SyncModelFixture.make()
        let counting = CountingPassthroughRunner(
            behind: ProcessGitRunner(extraArguments: SyncModelFixture.identity))
        let model = try makeModel(
            fixture: fixture, syncEnabled: true, runner: counting,
            debounceInterval: 0.2, remoteURL: .some(nil))

        // Pre-state, read through the TEST's own uncounted runner.
        let configURL = fixture.vaultURL.appendingPathComponent(".git/config")
        let configBefore = try Data(contentsOf: configURL)
        let originBefore = try await fixture.run(
            ["remote", "get-url", "origin"], at: fixture.vaultURL.path).stdout
        XCTAssertEqual(
            originBefore.trimmingCharacters(in: .whitespacesAndNewlines),
            fixture.remoteURLString, "the fixture's vault has an origin")
        let commitsBefore = try await Self.remoteCommitCount(fixture)
        XCTAssertEqual(commitsBefore, 1)

        // bootstrap: the typed state, no spawn.
        await model.bootstrap()
        XCTAssertEqual(
            model.syncHealth,
            .unavailable(reason: SyncHealthEvaluator.noRemoteReason))
        XCTAssertEqual(
            AppModel.syncHealthLine(for: model.syncHealth),
            "Sync unavailable — no sync remote is configured.")
        XCTAssertEqual(counting.invocationCount, 0, "bootstrap")

        // The toggle flip (persists ON, applies the coordinator, probes).
        await model.setSyncEnabled(true)
        XCTAssertEqual(
            model.syncHealth,
            .unavailable(reason: SyncHealthEvaluator.noRemoteReason))
        XCTAssertEqual(counting.invocationCount, 0, "setSyncEnabled(true)")

        // A vault write + the (short, injected 0.2 s) debounce window.
        _ = try await model.createTask(try fixture.makeTask(title: "BlankRemote"))
        model.noteVaultWrite()
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(counting.invocationCount, 0, "vault write + debounce")

        // The #50 seam: a typed `.unavailable`, no spawn.
        let outcome = await model.pullVaultOnce()
        XCTAssertEqual(outcome, .unavailable("no sync remote is configured"))
        XCTAssertEqual(counting.invocationCount, 0, "pullVaultOnce")

        // The quit flush, the probe, and a garbage remote entry.
        model.flushSyncForTermination()
        XCTAssertEqual(counting.invocationCount, 0, "flushSyncForTermination")
        await model.probeSyncReachability()
        XCTAssertEqual(counting.invocationCount, 0, "probeSyncReachability")
        let garbage = await model.setSyncRemote("garbage")
        XCTAssertEqual(garbage, .unrecognized)
        XCTAssertEqual(counting.invocationCount, 0, "setSyncRemote(garbage)")

        // Origin untouched, byte-for-byte; the bare remote unchanged.
        XCTAssertEqual(counting.invocationCount, 0)
        let originAfter = try await fixture.run(
            ["remote", "get-url", "origin"], at: fixture.vaultURL.path).stdout
        XCTAssertEqual(originAfter, originBefore)
        XCTAssertEqual(try Data(contentsOf: configURL), configBefore)
        let commitsAfter = try await Self.remoteCommitCount(fixture)
        XCTAssertEqual(commitsAfter, 1, "nothing was pushed")
    }

    /// The heal path (issue #57): ON + blank remote shows the typed
    /// unavailable state; entering a valid link heals it to `.idle`
    /// WITHOUT reopening the sheet; clearing it again returns to the
    /// unavailable state. A STUB runner — the probe's `ls-remote` never
    /// touches the network; it must be the ONLY invocation.
    func testSettingAndClearingTheRemoteHealsAndRestoresTheUnavailableState()
        async throws
    {
        let fixture = try await SyncModelFixture.make()
        let stub = RecordingStubRunner()
        let model = try makeModel(
            fixture: fixture, syncEnabled: true, runner: stub, remoteURL: .some(nil))
        await model.bootstrap()
        let unavailable = SyncHealth.unavailable(
            reason: SyncHealthEvaluator.noRemoteReason)
        XCTAssertEqual(model.syncHealth, unavailable)
        XCTAssertEqual(stub.invocations, [])

        let saved = await model.setSyncRemote(
            "https://github.com/example-user/example-vault")
        let ssh = "git@github.com:example-user/example-vault.git"
        XCTAssertEqual(saved, .saved(ssh))
        XCTAssertEqual(model.syncHealth, .idle, "healed without reopening the sheet")
        XCTAssertEqual(
            stub.invocations,
            [["-C", fixture.vaultURL.path, "ls-remote", ssh]],
            "the ONLY invocation is the single reachability probe")

        let cleared = await model.setSyncRemote("  ")
        XCTAssertEqual(cleared, .cleared)
        XCTAssertEqual(model.syncHealth, unavailable)
        XCTAssertEqual(stub.invocations.count, 1, "no probe once the remote is gone")
        XCTAssertEqual(model.syncRemoteEntry, "")
    }

    // MARK: - [Pull triggers]: launch-pull BEFORE the first load

    func testLaunchPullRunsBeforeFirstLoadSoRemoteTasksAreVisible() async throws {
        let fixture = try await SyncModelFixture.make(withLifebotClone: true)
        // The Lifebot pushes a Tasks change while the app is not running
        // (the §4 store-and-forward shape); the VAULT knows nothing of it.
        try fixture.writeLifebotTask(title: "Remote Admin Task", fileName: "remote.md")
        try await fixture.run(["add", "-A"], at: fixture.lifebotURL.path)
        try await fixture.run(
            ["commit", "-m", "lifebot: remote"], at: fixture.lifebotURL.path)
        try await fixture.run(["push"], at: fixture.lifebotURL.path)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.vaultURL.appendingPathComponent("Tasks/remote.md").path))

        // ONE bootstrap: the launch-pull (awaited, watchdog-bounded,
        // failure-tolerant) runs BEFORE the first reloadVault — so the
        // pushed Tasks change is VISIBLE right after.
        let model = try makeModel(fixture: fixture, syncEnabled: true)
        await model.bootstrap()

        XCTAssertEqual(model.syncHealth, .idle)
        XCTAssertTrue(model.tasks.contains { $0.title == "Remote Admin Task" })
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.vaultURL.appendingPathComponent("Tasks/remote.md").path))
    }

    // MARK: - [Issue #53] the launch frame: `.opening` while the pull is
    // in flight, never onboarding

    /// The gated-runner launch test (pin 8c): with sync ON and the fixture
    /// remote, a configured model constructs `.opening`; `bootstrap()` is
    /// launched in a `Task {}` (the app's `.task` shape, after the first
    /// frame renders) with the gate closed BEFORE launch, so the launch
    /// pull parks inside it; while the pull is genuinely in flight the
    /// model is STILL `.opening` (the frame the user sees — never
    /// `.notConfigured`: its only writers are the two guard-else branches,
    /// both unreachable while `vaultStore != nil`); releasing the gate
    /// lets the pull complete, `reloadVault()` resolve the state in one
    /// assignment, and bootstrap end `.loaded`. No real sleeps on the
    /// critical path — the gate is clock-free; the fixture's `waitUntil`
    /// 50 ms poll is the sanctioned observation idiom.
    func testBootstrapWithSyncOnShowsOpeningWhileLaunchPullParkedThenLoads() async throws {
        let fixture = try await SyncModelFixture.make()
        let gated = GatedRunner(
            behind: ProcessGitRunner(extraArguments: SyncModelFixture.identity))
        let model = try makeModel(fixture: fixture, syncEnabled: true, runner: gated)

        // The first-frame contract, sync-ON side: a configured vault
        // constructs `.opening` — before ANY git invocation exists.
        guard case .opening = model.vaultState else {
            XCTFail("expected .opening at construction, got \(model.vaultState)")
            return
        }

        // The `.task` shape: bootstrap runs AFTER the first frame renders.
        // The gate is closed before this point (the pinned precondition).
        let bootstrapping = Task { await model.bootstrap() }

        // The launch-pull is genuinely in flight (parked at the gate) while
        // the model is STILL `.opening` — the placeholder window the user
        // would see, deterministically extended by the gate.
        try await fixture.waitUntil("the launch-pull parks at the gate") {
            gated.inFlightCount > 0
        }
        guard case .opening = model.vaultState else {
            XCTFail(
                "expected .opening while the launch-pull is parked, "
                    + "got \(model.vaultState)")
            return
        }

        // Release the gate: the pull completes, `reloadVault()` resolves
        // the opening state in one assignment, bootstrap ends.
        gated.open()
        await bootstrapping.value

        guard case .loaded = model.vaultState else {
            XCTFail("expected .loaded after bootstrap, got \(model.vaultState)")
            return
        }
        XCTAssertEqual(model.syncHealth, .idle)
        XCTAssertEqual(model.tasks.first?.title, "Seed", "the Tasks view lands with data")
    }

    // MARK: - The post-ff reload integration

    func testPostFastForwardReloadLetsTheNextWritePassTheStalenessGuard()
        async throws
    {
        let fixture = try await SyncModelFixture.make(withLifebotClone: true)
        let model = try makeModel(fixture: fixture, syncEnabled: true)
        await model.bootstrap()
        XCTAssertEqual(model.syncHealth, .idle)
        XCTAssertEqual(model.tasks.first?.title, "Seed")

        // The Lifebot rewrites the SAME task file behind the app's back:
        // the vault's recorded bytes (the #7 staleness guard's record) go
        // stale on disk.
        try await fixture.lifebotRewriteSeed(title: "Seed Updated")

        // The #50 seam's shape: ONE pull-once call — strictly behind →
        // fast-forward (the WORKING TREE changed → the model's #49
        // integration reloads), outcome recorded.
        let outcome = await model.pullVaultOnce()
        XCTAssertEqual(outcome, .fastForwarded)

        // The post-ff reload: the next read already sees the forwarded
        // change (a stale list here would mean the reload never ran).
        try await fixture.waitUntil("the model reloaded the forwarded change") {
            model.tasks.first?.title == "Seed Updated"
        }

        // The very next WRITE passes the #7 staleness guard — no
        // `.vaultChangedExternally` (the guaranteed-bug-if-forgotten).
        var edited = try XCTUnwrap(model.tasks.first)
        edited.title = "Seed Edited Locally"
        let updated = try await model.updateTask(edited)
        XCTAssertEqual(updated.title, "Seed Edited Locally")
        XCTAssertEqual(model.tasks.first?.title, "Seed Edited Locally")
    }

    // MARK: - The #50 seam (concurrent callers; outcome recorded)

    func testPullVaultOnceSeamSurvivesConcurrentCallers() async throws {
        let fixture = try await SyncModelFixture.make()
        let counting = CountingPassthroughRunner(
            behind: ProcessGitRunner(extraArguments: SyncModelFixture.identity))
        let model = try makeModel(fixture: fixture, syncEnabled: true, runner: counting)
        await model.bootstrap()
        XCTAssertEqual(model.syncHealth, .idle)
        let afterBootstrap = counting.invocationCount

        // Two concurrent seam calls: single-flight — one leases, the other
        // records ONE follow-up interest and awaits the leased outcome; no
        // error, no divergent state, no crash.
        async let firstOutcome = model.pullVaultOnce()
        async let secondOutcome = model.pullVaultOnce()
        let first = await firstOutcome
        let second = await secondOutcome

        XCTAssertEqual(first, .upToDate)
        XCTAssertEqual(second, .upToDate)
        XCTAssertEqual(model.syncHealth, .idle)
        // The seam DOES run the pinned pull-ONLY shape (the launch-pull and
        // these pulls NEVER push): strictly more invocations than the
        // bootstrap alone, all of them pull-cycle steps.
        XCTAssertGreaterThan(counting.invocationCount, afterBootstrap)
    }

    // MARK: - [Push] regression: a task deletion ships within the debounce window (issue #51)

    func testDeleteTaskPushesTheDeletionWithinOneDebounceWindow() async throws {
        let fixture = try await SyncModelFixture.make()
        let model = try makeModel(fixture: fixture, syncEnabled: true)
        await model.bootstrap()
        XCTAssertEqual(model.syncHealth, .idle)
        XCTAssertEqual(model.tasks.count, 1, "the seed task is loaded")

        // The deletion — one successful vault write (the file removal), so
        // ONE hook fire opens the debounce window.
        let seed = try XCTUnwrap(model.tasks.first { $0.id == fixture.seedTaskID })
        try await model.deleteTask(seed)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.vaultURL.appendingPathComponent("Tasks/seed.md").path))
        XCTAssertEqual(model.tasks.count, 0, "the mirrored inventory shrank")

        // Within one (short, injected) debounce window: exactly one new
        // commit is pushed whose tree LACKS the deleted file.
        try await fixture.waitUntil("the deletion was pushed to the remote") {
            guard try await Self.remoteCommitCount(fixture) == 2 else { return false }
            return try await Self.remoteTreeLacks(fixture, path: "Tasks/seed.md")
        }
        XCTAssertEqual(model.syncHealth, .idle)
    }

    // MARK: - [Quit flush] regression: the termination flush must not
    // deadlock the main actor (issue #52)

    /// The would-have-caught-#52 test — the method itself IS the
    /// blocked-main-actor scenario (`applicationWillTerminate` shape: the
    /// @MainActor test calls the synchronous flush while an injected
    /// delaying runner makes the real flush outlast the injected bound).
    /// Under the bug this was RED BY HANG — the inherited `Task {}`'s
    /// `semaphore.signal()` needed the main actor, which was blocked in
    /// the wait, so the function could not return before the full
    /// 7×30 s timeout (the PM's measured 210.112 s on the suite).
    func testTerminationFlushBoundedWhenFlushExceedsItAndStillCompletesOffActor()
        async throws
    {
        // The production default is pinned at 2 s (the #52 criterion).
        XCTAssertEqual(AppModel.terminationFlushTimeoutSeconds, 2)

        let fixture = try await SyncModelFixture.make()
        let injectedBound: TimeInterval = 0.5
        let delaying = OnceDelayingRunner(
            behind: ProcessGitRunner(extraArguments: SyncModelFixture.identity),
            delaySeconds: 1.0)
        // A LONG debounce (3600 s, the makeModel default pull interval's
        // scale): the flush is the ONLY pusher in this scenario — with the
        // ordinary short test debounce the write's own cycle would push
        // before the flush, muddying which actor shipped the change.
        let model = try makeModel(
            fixture: fixture,
            syncEnabled: true,
            runner: delaying,
            debounceInterval: 3600,
            terminationFlushTimeout: injectedBound)
        await model.bootstrap()
        XCTAssertEqual(model.syncHealth, .idle)

        // Un-synced work: a REAL vault write lands through the store (the
        // #49 write hook opens the — long — debounce window, so the write
        // is still un-synced when the flush runs), so the coordinator's
        // hasUnSyncedWrites is true and the flush runs its full push cycle.
        // The title is space-free on purpose: `VaultStore.slug(from:)`
        // sanitizes only path separators/control characters, so "Quit
        // Flush" would keep its space in the filename.
        let created = try await model.createTask(
            try fixture.makeTask(title: "QuitFlush52"))
        model.noteVaultWrite()
        XCTAssertEqual(model.tasks.count, 2, "seed + the new task")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.vaultURL
                    .appendingPathComponent("Tasks/QuitFlush52.md").path),
            "the un-synced write exists in the working tree")
        // Drain: the write notification reaches the coordinator through
        // two in-flight actor hops (the store hook's Task → the model's
        // main-actor Task → the coordinator actor). One short suspension
        // guarantees hasUnSyncedWrites is set BEFORE the flush runs —
        // without it the detached flush could race the notification and
        // legitimately see nothing to push.
        try await Task.sleep(nanoseconds: 100_000_000)

        // The one-shot delay lands on the flush's cycle: its first git
        // invocation sleeps 1 s — past the 0.5 s injected bound, so the
        // bounded wait ALWAYS times out and the flush completes off-actor
        // AFTER the function has returned.
        delaying.arm()
        let beforeFlushCommitCount = try await Self.remoteCommitCount(fixture)
        XCTAssertEqual(beforeFlushCommitCount, 1, "nothing pushed yet")

        // (1) THE BOUND: the synchronous flush returns in wall-clock
        // ≤ injected bound + scheduling slack — never 210 s.
        let start = Date()
        model.flushSyncForTermination()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThanOrEqual(
            elapsed, injectedBound + 0.5,
            "flushSyncForTermination must return within the injected bound "
                + "+ slack; under the bug it hung 210 s")

        // (1b) THE OFF-ACTOR WITNESS: the flush STARTED while the main
        // thread was blocked in the wait (the delay was taken before the
        // wait returned — a synchronous read of the runner's state right
        // after). An inherited-`Task {}` shape could NOT take it: the main
        // actor sat in the wait, so the body (and the coordinator hop)
        // stayed unscheduled. This is the deterministic discriminator for
        // a partial revert of #52 (detached executor kept, bound kept —
        // executor regressed).
        XCTAssertTrue(
            delaying.hasTakenDelay,
            "the flush must run off the main actor while the caller waits "
                + "— under the #52 bug the flush body could never start")

        // (2) NOT SILENTLY SKIPPED: the detached flush completes off-actor
        // after the function returned — the remote eventually carries the
        // change (commit count 2 and a tree that HAS the new file). With
        // the long debounce this is the flush's work alone: no other push
        // trigger can ship the write within the wait's deadline.
        try await fixture.waitUntil(
            "the abandoned-but-running flush pushed the change", timeoutSeconds: 10
        ) {
            guard try await Self.remoteCommitCount(fixture) == 2 else { return false }
            return try await Self.remoteTreeHas(fixture, path: "Tasks/QuitFlush52.md")
        }
        XCTAssertEqual(created.title, "QuitFlush52")
        XCTAssertEqual(model.syncHealth, .idle)
    }

    /// The remote's commit count on `main` (the seed starts it at 1).
    private static func remoteCommitCount(_ fixture: SyncModelFixture) async throws -> Int {
        let outcome = try await fixture.run(
            ["rev-list", "--count", "main"], at: fixture.remotePath)
        return Int(
            outcome.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Whether the remote's pushed tree lacks `path`.
    private static func remoteTreeLacks(
        _ fixture: SyncModelFixture, path: String
    ) async throws -> Bool {
        let outcome = try await fixture.run(
            ["ls-tree", "-r", "--name-only", "main"], at: fixture.remotePath)
        return !outcome.stdout.split(separator: "\n").contains(Substring(path))
    }

    /// Whether the remote's pushed tree carries `path` — the #52
    /// not-silently-skipped witness (the `remoteTreeLacks` inverse).
    private static func remoteTreeHas(
        _ fixture: SyncModelFixture, path: String
    ) async throws -> Bool {
        let outcome = try await fixture.run(
            ["ls-tree", "-r", "--name-only", "main"], at: fixture.remotePath)
        return outcome.stdout.split(separator: "\n").contains(Substring(path))
    }
}
