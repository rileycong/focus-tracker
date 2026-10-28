import XCTest
@testable import SyncCore

/// The #49 integration floor, against REAL temp-dir remotes: every test
/// builds its OWN bare remote + work vault (+ a "Lifebot" second clone where
/// the scenario needs an external writer); remote URLs are `file://…` (zero
/// network, zero ssh); hermetic identities ride the runner's `-c` flags
/// (NEVER the global git config); the repo's fixtures/ and the real vault
/// are never touched.
final class SyncCoordinatorTests: XCTestCase {

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

    /// One disposable world: a bare remote, the vault, a Lifebot clone.
    /// `file://` remotes, hermetic `-c` identities, temp-dir copies only.
    final class SyncFixture {
        static let identity = [
            "-c", "user.name=FT Tests", "-c", "user.email=ft-tests@example.com",
        ]

        let rootURL: URL
        let remotePath: String
        let remoteURLString: String
        let vaultURL: URL
        let lifebotURL: URL
        let runner = ProcessGitRunner(extraArguments: identity)

        enum FixtureError: Error, CustomStringConvertible {
            case commandFailed(command: String, outcome: GitOutcome)

            var description: String {
                switch self {
                case .commandFailed(let command, let outcome):
                    return "git failed: \(command) — \(outcome.stderr)"
                }
            }
        }

        /// Builds the world. (An async factory: the Process runner's
        /// `run` is async and initializers cannot await.)
        static func make(withInitialCommit: Bool = true) async throws -> SyncFixture {
            let fixture = SyncFixture(withInitialCommit: withInitialCommit)
            try await fixture.build(withInitialCommit: withInitialCommit)
            return fixture
        }

        private init(withInitialCommit: Bool) {
            rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("ft49-\(UUID().uuidString)", isDirectory: true)
            remotePath = rootURL.appendingPathComponent("origin.git").path
            remoteURLString = rootURL.appendingPathComponent("origin.git").absoluteString
            vaultURL = rootURL.appendingPathComponent("vault", isDirectory: true)
            lifebotURL = rootURL.appendingPathComponent("lifebot", isDirectory: true)
        }

        private func build(withInitialCommit: Bool) async throws {
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
            if withInitialCommit {
                // The C0 seed: RAW Markdown — the engine never parses (the
                // model's tests prove the parsing side).
                try Data("# seed\n".utf8).write(
                    to: vaultURL.appendingPathComponent("Tasks/seed.md"))
                try await run(
                    ["add", "--", "Tasks", "Logs"], at: vaultURL.path)
                try await run(["commit", "-m", "seed"], at: vaultURL.path)
                try await run(["push", "-u", "origin", "main"], at: vaultURL.path)
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

        /// An invocation whose non-zero exit is EXPECTED data (existence
        /// probes) — only spawn failures throw.
        func tryRun(_ arguments: [String], at directory: String) async throws -> GitOutcome {
            try await runner.run(arguments: ["-C", directory] + arguments)
        }

        func cloneLifebot() async throws {
            try await run(
                ["clone", "--quiet", remoteURLString, lifebotURL.path], at: rootURL.path)
        }

        func writeVaultFile(_ fileName: String, contents: String = "# note\n") throws {
            let url = vaultURL
                .appendingPathComponent("Tasks", isDirectory: true)
                .appendingPathComponent(fileName)
            try Data(contents.utf8).write(to: url)
        }

        func writeLifebotFile(_ fileName: String, contents: String = "# draft\n") throws {
            let url = lifebotURL
                .appendingPathComponent("Tasks", isDirectory: true)
                .appendingPathComponent(fileName)
            try Data(contents.utf8).write(to: url)
        }

        /// The Lifebot's write ritual: pull (fast-forward), add, commit,
        /// push. Hermetic identity via the runner's `-c` flags.
        func lifebotCommitAndPush(pullFirst: Bool = true) async throws {
            if pullFirst {
                try await run(
                    ["pull", "--ff-only", "origin", "main"], at: lifebotURL.path)
            }
            try await run(["add", "-A"], at: lifebotURL.path)
            try await run(["commit", "-m", "lifebot change"], at: lifebotURL.path)
            try await run(["push"], at: lifebotURL.path)
        }

        /// The "manual resolve" actor committing INSIDE the vault (the
        /// divergence test's histories-reconcile step; the engine itself
        /// never resolves — it STOPS).
        func commitInVault(message: String) async throws {
            try await run(["add", "--", "Tasks", "Logs"], at: vaultURL.path)
            try await run(["commit", "-m", message], at: vaultURL.path)
        }

        /// Whether the bare remote's CURRENT head carries the path.
        func remoteHas(_ target: String) async -> Bool {
            do {
                let outcome = try await tryRun(
                    ["show", "HEAD:\(target)"], at: remotePath)
                return outcome.exitStatus == 0
            } catch {
                return false
            }
        }
    }

    // MARK: - observation seams

    final class SyncEventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [SyncHealth] = []

        func record(_ health: SyncHealth) {
            lock.lock()
            defer { lock.unlock() }
            items.append(health)
        }

        var all: [SyncHealth] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }

        func count(of health: SyncHealth) -> Int {
            all.filter { $0 == health }.count
        }

        var errorCount: Int {
            all.reduce(0) { produced, health in
                if case .error = health { return produced + 1 }
                return produced
            }
        }

        var errorReasons: [String] {
            all.compactMap {
                if case .error(let reason) = $0 { return reason }
                return nil
            }
        }
    }

    final class SyncEventCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func bump() {
            lock.lock()
            defer { lock.unlock() }
            count += 1
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    /// Wraps the real runner; delays the FIRST invocation once — the
    /// deterministic widow used to prove that concurrent entries land INSIDE
    /// the leased cycle instead of spawning a second one.
    final class OnceDelayingRunner: GitRunner, @unchecked Sendable {
        private let behind: any GitRunner
        private let delayNanoseconds: UInt64
        private let lock = NSLock()
        private var armed = true

        init(behind: any GitRunner, delaySeconds: TimeInterval) {
            self.behind = behind
            self.delayNanoseconds = UInt64(delaySeconds * 1_000_000_000)
        }

        func run(arguments: [String]) async throws -> GitOutcome {
            if takeDelayIfArmed() {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            return try await behind.run(arguments: arguments)
        }

        /// Synchronous (the lock calls must not sit directly in an async
        /// function under this Foundation marking).
        private func takeDelayIfArmed() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            let shouldDelay = armed
            armed = false
            return shouldDelay
        }
    }

    final class CountingRunner: GitRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var invocationCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func run(arguments: [String]) async throws -> GitOutcome {
            bump()
            return GitOutcome(exitStatus: 0, stdout: "", stderr: "")
        }

        /// Synchronous — see `takeDelayIfArmed`.
        private func bump() {
            lock.lock()
            defer { lock.unlock() }
            count += 1
        }
    }

    private func makeCoordinator(
        fixture: SyncFixture,
        debounceInterval: TimeInterval = 0.2,
        healthLog: SyncEventLog? = nil,
        ffCounter: SyncEventCounter? = nil,
        runner: (any GitRunner)? = nil
    ) -> SyncCoordinator {
        let healthChange: (@Sendable (SyncCoordinator, SyncHealth) -> Void)?
        if let healthLog {
            healthChange = { _, health in healthLog.record(health) }
        } else {
            healthChange = nil
        }
        let ffNotify: (@Sendable (SyncCoordinator) -> Void)?
        if let ffCounter {
            ffNotify = { _ in ffCounter.bump() }
        } else {
            ffNotify = nil
        }
        return SyncCoordinator(
            configuration: .init(
                vaultURL: fixture.vaultURL,
                remoteURL: fixture.remoteURLString,
                extraArguments: SyncFixture.identity,
                debounceIntervalSeconds: debounceInterval,
                pullIntervalSeconds: 3600,
                watchdogTimeoutSeconds: 10),
            runner: runner,
            onHealthChange: healthChange,
            onFastForwarded: ffNotify)
    }

    private func waitUntil(
        _ description: String, timeoutSeconds: TimeInterval = 10,
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting: \(description)", file: file, line: line)
    }

    // MARK: - Tests

    func testFullPushCycleCommitsAndPushesAndLifebotSeesIt() async throws {
        let fixture = try await SyncFixture.make()
        try await fixture.cloneLifebot()
        let healthLog = SyncEventLog()
        let coordinator = makeCoordinator(fixture: fixture, healthLog: healthLog)
        await coordinator.applyEnabled(true)

        try fixture.writeVaultFile("a.md")
        await coordinator.noteVaultWrite()

        // The write is committed + pushed within the injected interval
        // (the 0.2 s debounce; the waitUntil deadline is the honest upper
        // witness) — the bare remote's head carries the file.
        try await waitUntil("the remote head carries Tasks/a.md") {
            await fixture.remoteHas("Tasks/a.md")
        }
        let health = await coordinator.health
        XCTAssertEqual(health, .idle)
        XCTAssertEqual(healthLog.errorCount, 0)

        // The Lifebot clone sees it: pull → its remote-tracking head.
        try await fixture.run(["fetch", "origin"], at: fixture.lifebotURL.path)
        let lifebotOutcome = try await fixture.tryRun(
            ["show", "origin/main:Tasks/a.md"], at: fixture.lifebotURL.path)
        XCTAssertEqual(lifebotOutcome.exitStatus, 0)
    }

    func testCoalescingBurstWritesProduceExactlyOneCycle() async throws {
        let fixture = try await SyncFixture.make()
        let healthLog = SyncEventLog()
        let coordinator = makeCoordinator(fixture: fixture, healthLog: healthLog)
        await coordinator.applyEnabled(true)
        XCTAssertEqual(healthLog.count(of: .idle), 1)  // the enabling report

        // The burst: the FIRST noteVaultWrite opens the (max-wait) window;
        // the rest coalesce without extending it.
        for index in 0...4 {
            try fixture.writeVaultFile("b\(index).md")
            await coordinator.noteVaultWrite()
        }

        try await waitUntil("the remote head carries the whole burst") {
            let fourth = await fixture.remoteHas("Tasks/b4.md")
            let first = await fixture.remoteHas("Tasks/b0.md")
            return fourth && first
        }
        // Any SECOND (buggy, trailing-reset) cycle would surface as one more
        // .idle report within its debounce + duration; the honest quiescent
        // wait proves it does not come.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(healthLog.count(of: .idle), 2)
        XCTAssertEqual(healthLog.errorCount, 0)
    }

    func testSingleFlightConcurrentEntriesDischargeExactlyOneFollowUp() async throws {
        let fixture = try await SyncFixture.make()
        let healthLog = SyncEventLog()
        let delaying = OnceDelayingRunner(
            behind: ProcessGitRunner(extraArguments: SyncFixture.identity),
            delaySeconds: 0.3)
        let coordinator = makeCoordinator(
            fixture: fixture, healthLog: healthLog, runner: delaying)
        await coordinator.applyEnabled(true)
        XCTAssertEqual(healthLog.count(of: .idle), 1)

        // #1 leases the (delayed) cycle; #2/#3/#4 (the vault-write interest)
        // all arrive MID-CYCLE and record ONE follow-up interest, never an
        // unbounded queue.
        let leased = Task { await coordinator.pullOnce() }
        try await Task.sleep(nanoseconds: 50_000_000)
        async let secondOutcome = coordinator.pullOnce()
        async let thirdOutcome = coordinator.pullOnce()
        await await coordinator.noteVaultWrite()


        let firstOutcome = await leased.value
        let second = await secondOutcome
        let third = await thirdOutcome
        XCTAssertEqual(firstOutcome, .upToDate)
        XCTAssertEqual(second, .upToDate)
        XCTAssertEqual(third, .upToDate)

        // The discharge: EXACTLY ONE extra cycle (a push — writes pending),
        // after which the coordinator is quiescent: 1 enabling + 2 cycles.
        try await waitUntil("the discharge cycle completed") {
            await coordinator.health == .idle
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(healthLog.count(of: .idle), 3)
        XCTAssertEqual(healthLog.errorCount, 0)
    }

    func testFastForwardNotifyDivergenceStopAndRecoveryWithoutRestart()
        async throws
    {
        let fixture = try await SyncFixture.make()
        try await fixture.cloneLifebot()  // the Lifebot sits at C0
        let healthLog = SyncEventLog()
        let ffCounter = SyncEventCounter()
        let coordinator = makeCoordinator(
            fixture: fixture, healthLog: healthLog, ffCounter: ffCounter)
        await coordinator.applyEnabled(true)

        // (b) A vault write → the FIRST full cycle: nothing remote-new, so
        // no fast-forward; C1 (seed + a.md) pushed.
        try fixture.writeVaultFile("a.md")
        await coordinator.noteVaultWrite()
        try await waitUntil("the remote head carries Tasks/a.md") {
            await fixture.remoteHas("Tasks/a.md")
        }
        XCTAssertEqual(ffCounter.value, 0)

        // (c) The Lifebot advances the origin: ff-pull to C1, then its own
        // commit+push → C2 (= C1 + Tasks/x.md).
        try fixture.writeLifebotFile("x.md")
        try await fixture.lifebotCommitAndPush()

        // (d) The next vault write → the cycle pulls FIRST: strictly behind
        // → fast-forward (the WORKING TREE changed: Tasks/x.md landed) →
        // then add/commit/push → C3. The ff-notify fired exactly once.
        try fixture.writeVaultFile("b.md")
        await coordinator.noteVaultWrite()
        try await waitUntil("the remote head carries Tasks/b.md") {
            await fixture.remoteHas("Tasks/b.md")
        }
        // The notify fires INSIDE the debounce-run cycle (not awaited by
        // this test), so wait for it — never read it on a race.
        try await waitUntil("the fast-forward fired its notify") {
            ffCounter.value == 1
        }
        try await waitUntil("the forwarded x.md sits in the vault") {
            FileManager.default.fileExists(
                atPath: fixture.vaultURL.appendingPathComponent("Tasks/x.md").path)
        }

        // (e) Two competing writers WITHOUT the engine looking: the vault
        // gets a manual (ahead, unpushed) commit; the Lifebot advances the
        // origin again.
        try fixture.writeVaultFile("manual.md")
        try await fixture.commitInVault(message: "manual resolve step")
        try fixture.writeLifebotFile("y.md")
        try await fixture.lifebotCommitAndPush()

        // (f) The next vault write → the cycle's compare: BOTH sides moved
        // → the pinned divergence-STOP: `.error` with the EXACT sentence,
        // nothing on disk changed (the crash-leftover c.md stays), no
        // auto-merge, no force.
        try fixture.writeVaultFile("c.md")
        await coordinator.noteVaultWrite()
        try await waitUntil("the divergence surfaced") {
            !healthLog.errorReasons.isEmpty
        }
        XCTAssertEqual(
            healthLog.errorReasons.first,
            SyncCycleError.diverged(ahead: 1, behind: 1).detail)
        let lastHealth = await coordinator.health
        XCTAssertEqual(
            lastHealth, .error(SyncCycleError.diverged(ahead: 1, behind: 1).detail))

        // (g) The histories reconcile (the HUMAN's manual resolve — the
        // test plays that role, the ENGINE never merges) and the very next
        // cycle recovers to `.idle` — WITHOUT an app restart.
        try await fixture.run(
            ["pull", "--no-rebase", "--no-edit"], at: fixture.vaultURL.path)
        await coordinator.noteVaultWrite()
        try await waitUntil("the remote head carries Tasks/c.md") {
            await fixture.remoteHas("Tasks/c.md")
        }
        let recovered = await coordinator.health
        XCTAssertEqual(recovered, .idle)
        XCTAssertEqual(ffCounter.value, 1)  // the recovery: no ff needed
    }

    func testUnbornHeadFirstPushCreatesRemoteBranch() async throws {
        // The VS-2 window BEFORE its first commit: the vault repo exists
        // (git init, origin added) but has NO commits and the bare remote
        // is EMPTY — the unborn-HEAD-legal case.
        let fixture = try await SyncFixture.make(withInitialCommit: false)
        let healthLog = SyncEventLog()
        let coordinator = makeCoordinator(fixture: fixture, healthLog: healthLog)
        await coordinator.applyEnabled(true)
        XCTAssertEqual(healthLog.errorCount, 0)

        try fixture.writeVaultFile("first.md")
        await coordinator.noteVaultWrite()

        try await waitUntil("the bare remote's main was created with the first push") {
            await fixture.remoteHas("Tasks/first.md")
        }
        // `-u origin <branch>` ran: the branch now tracks its upstream.
        let upstream = try await fixture.run(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
            at: fixture.vaultURL.path)
        XCTAssertTrue(upstream.stdout.contains("origin/main"))
        let head = try await fixture.run(
            ["rev-parse", "HEAD"], at: fixture.vaultURL.path)
        let remoteHead = try await fixture.run(
            ["rev-parse", "refs/heads/main"], at: fixture.remotePath)
        XCTAssertEqual(
            head.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            remoteHead.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        let health = await coordinator.health
        XCTAssertEqual(health, .idle)
    }

    func testPullOnlyCycleFastForwardsNeverPushesAndKeepsCrashLeftovers()
        async throws
    {
        let fixture = try await SyncFixture.make()
        try await fixture.cloneLifebot()
        let healthLog = SyncEventLog()
        let ffCounter = SyncEventCounter()
        let coordinator = makeCoordinator(
            fixture: fixture, healthLog: healthLog, ffCounter: ffCounter)
        await coordinator.applyEnabled(true)

        // The Lifebot advances the origin BEHIND the vault's back.
        try fixture.writeLifebotFile("remote-only.md")
        try await fixture.lifebotCommitAndPush()

        // A crash-leftover: an UNCOMMITTED vault write (the honest-loss
        // posture) — the pull-ONLY cycle must not touch it.
        try fixture.writeVaultFile("crashLeftover.md")

        let outcome = await coordinator.pullOnce()
        XCTAssertEqual(outcome, .fastForwarded)
        // The fetched change landed in the WORKING TREE…
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.vaultURL.appendingPathComponent("Tasks/remote-only.md").path))
        // …the ff-notify fired…
        XCTAssertEqual(ffCounter.value, 1)
        // …the crash-leftover rides: still uncommitted, and the bare
        // remote (whose head the Lifebot's push advanced) does NOT know it.
        let status = try await fixture.run(
            ["status", "--porcelain"], at: fixture.vaultURL.path)
        XCTAssertTrue(status.stdout.contains("crashLeftover.md"))
        let leftoverPushed = await fixture.remoteHas("Tasks/crashLeftover.md")
        XCTAssertFalse(leftoverPushed)
        // And a second pull: nothing to do — the recorded outcome.
        let second = await coordinator.pullOnce()
        XCTAssertEqual(second, .upToDate)
    }

    func testDisabledCoordinatorSpawnsNothing() async throws {
        // The shipped-by-default state, inert BY CONSTRUCTION: constructed
        // (never enabled) — every entry returns without spawning.
        let fixture = try await SyncFixture.make()
        let counting = CountingRunner()
        let coordinator = makeCoordinator(fixture: fixture, runner: counting)

        await coordinator.noteVaultWrite()
        let pulled = await coordinator.pullOnce()
        let flushed = await coordinator.flush()
        await coordinator.probeReachability()

        XCTAssertEqual(counting.invocationCount, 0)
        XCTAssertEqual(pulled, .disabled)
        XCTAssertEqual(flushed, .disabled)
        let health = await coordinator.health
        XCTAssertEqual(health, .disabled)

        // And an explicitly-disabled coordinator stays inert after enabling
        // and disabling again (the loops are cancelled, the entries refuse).
        await coordinator.applyEnabled(true)
        await coordinator.applyEnabled(false)
        await coordinator.noteVaultWrite()
        _ = await coordinator.pullOnce()
        _ = await coordinator.flush()
        XCTAssertEqual(counting.invocationCount, 0)
    }
}
