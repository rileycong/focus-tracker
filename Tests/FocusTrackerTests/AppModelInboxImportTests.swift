import XCTest
import SyncCore
@testable import FocusTracker

/// The #50 (FocusVault FT-2) model-level floor: the exact menu-label
/// strings (the #45/#49 pure-derivation precedent), the launch trigger
/// (AFTER the #49 launch pull; with sync OFF, local drafts import with
/// ZERO git invocations), the menu action's pull-before-import, the
/// count refreshes (bootstrap, post-import, vault reload — including the
/// sync fast-forward reload that lands remote drafts), and the
/// enablement rule (disabled only while unconfigured).
///
/// Every test builds its OWN world under the temp dir: a disposable copy
/// of `fixtures/sample-vault/` (never the repo fixture, never the real
/// vault) for the non-git scenarios, and a bare `file://` remote + vault
/// (+ Lifebot clone) with hermetic `-c` identities for the git scenarios
/// (the AppModelSyncTests pattern); the app's settings domain is never
/// touched (injected suites).
@MainActor
final class AppModelInboxImportTests: XCTestCase {

    // MARK: - The label derivation (exact pinned strings)

    func testInboxImportMenuItemTitleExactStrings() {
        XCTAssertEqual(
            AppModel.inboxImportMenuItemTitle(draftCount: 3, problemCount: 0),
            "Import Inbox Drafts (3)")
        XCTAssertEqual(
            AppModel.inboxImportMenuItemTitle(draftCount: 0, problemCount: 0),
            "Import Inbox Drafts (0)")
        XCTAssertEqual(
            AppModel.inboxImportMenuItemTitle(draftCount: 2, problemCount: 5),
            "Import Inbox Drafts (2, 5 problems)")
        XCTAssertEqual(
            AppModel.inboxImportMenuItemTitle(draftCount: 0, problemCount: 1),
            "Import Inbox Drafts (0, 1 problems)")
    }

    // MARK: - The git world fixture (bare remote + vault + Lifebot clone)

    enum FixtureError: Error, CustomStringConvertible {
        case commandFailed(command: String, outcome: GitOutcome)

        var description: String {
            switch self {
            case .commandFailed(let command, let outcome):
                return "git failed: \(command) — \(outcome.stderr)"
            }
        }
    }

    final class GitWorld: @unchecked Sendable {
        static let identity = [
            "-c", "user.name=FT50 Tests", "-c", "user.email=ft50-tests@example.com",
        ]

        let rootURL: URL
        let remoteURLString: String
        let vaultURL: URL
        let lifebotURL: URL
        let persistenceDirectory: URL
        let runner = ProcessGitRunner(extraArguments: identity)

        static func make(withLifebotClone: Bool = false) async throws -> GitWorld {
            let world = GitWorld()
            try await world.build(withLifebotClone: withLifebotClone)
            return world
        }

        private init() {
            rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("ft50-model-\(UUID().uuidString)", isDirectory: true)
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
            for folder in ["Tasks", "Logs"] {
                try FileManager.default.createDirectory(
                    at: vaultURL.appendingPathComponent(folder, isDirectory: true),
                    withIntermediateDirectories: true)
            }
            try await run(["init", "-b", "main"], at: vaultURL.path)
            try await run(["remote", "add", "origin", remoteURLString], at: vaultURL.path)
            // The seed: a REAL schema-valid task file (the model parses it).
            let seed = try TaskItem(title: "Seed", categories: [Category(name: "Admin")])
            try Data(FrontmatterCodec.encode(task: seed, body: "").utf8).write(
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
            let outcome = try await runner.run(
                arguments: ["-C", directory] + arguments)
            guard outcome.exitStatus == 0 else {
                throw FixtureError.commandFailed(
                    command: "git " + arguments.joined(separator: " "), outcome: outcome)
            }
            return outcome
        }

        /// The Lifebot's draft ritual: write an `Inbox/` draft, commit,
        /// push (hermetic identity — never the machine's git config).
        func lifebotPushesDraft(_ fileName: String, text: String) async throws {
            let inbox = lifebotURL.appendingPathComponent("Inbox", isDirectory: true)
            try FileManager.default.createDirectory(
                at: inbox, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: inbox.appendingPathComponent(fileName))
            try await run(["add", "-A"], at: lifebotURL.path)
            try await run(["commit", "-m", "lifebot: draft"], at: lifebotURL.path)
            try await run(["push"], at: lifebotURL.path)
        }

        var vaultInboxDraftURL: URL {
            vaultURL.appendingPathComponent("Inbox", isDirectory: true)
                .appendingPathComponent("draft.md")
        }

        func waitUntil(
            _ description: String, timeoutSeconds: TimeInterval = 10,
            file: StaticString = #filePath, line: UInt = #line,
            _ condition: @MainActor () async -> Bool
        ) async {
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while Date() < deadline {
                if await condition() { return }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTFail("Timed out waiting: \(description)", file: file, line: line)
        }
    }

    /// Counts spawns AND forwards to the real runner (the
    /// AppModelSyncTests counting seam).
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

    /// Records EVERY invocation's arguments (in order) AND forwards to
    /// the real runner — the launch-ordering seam.
    final class RecordingPassthroughRunner: GitRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var invocations: [[String]] = []
        private let behind: any GitRunner

        init(behind: any GitRunner) {
            self.behind = behind
        }

        var recordedInvocations: [[String]] {
            lock.lock()
            defer { lock.unlock() }
            return invocations
        }

        /// Synchronous — the lock calls must not sit directly in an async
        /// function under this Foundation marking.
        private func record(_ arguments: [String]) {
            lock.lock()
            defer { lock.unlock() }
            invocations.append(arguments)
        }

        func run(arguments: [String]) async throws -> GitOutcome {
            record(arguments)
            return try await behind.run(arguments: arguments)
        }
    }

    /// A plain counting runner (fake outcomes, zero processes) — a
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

    // MARK: - Model plumbing

    private static let fixturesVault = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Tests/FocusTrackerTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("fixtures/sample-vault", isDirectory: true)

    /// A disposable copy of the sample vault (never the repo fixture).
    private func makeFixtureVault() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft50-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let vault = root.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.copyItem(at: Self.fixturesVault, to: vault)
        return vault
    }

    private func makeModel(
        vaultPath: String?,
        syncEnabled: Bool,
        remoteURL: String? = nil,
        runner: (any SyncCore.GitRunner)? = nil,
        persistenceDirectory: URL? = nil,
        debounceInterval: TimeInterval = 3600
    ) throws -> AppModel {
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: "ft50-appmodel-\(UUID().uuidString)"))
        var settings = AppSettings(defaults: defaults)
        settings.vaultPath = vaultPath
        settings.vaultSyncEnabled = syncEnabled
        if let remoteURL { settings.vaultSyncRemote = remoteURL }
        return AppModel(
            settings: settings,
            persistenceDirectory: persistenceDirectory
                ?? FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "ft50-persistence-\(UUID().uuidString)", isDirectory: true),
            syncDebounceInterval: debounceInterval,
            syncPullInterval: 3600,
            syncGitRunner: runner
                ?? ProcessGitRunner(extraArguments: GitWorld.identity))
    }

    private func writeLocalDraft(to vault: URL, fileName: String, text: String) throws {
        let inbox = vault.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(
            at: inbox, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: inbox.appendingPathComponent(fileName))
    }

    // MARK: - The launch trigger, sync OFF: local drafts, ZERO git

    func testSyncOffLaunchImportsLocalDraftsWithZeroGitInvocations() async throws {
        let vault = try makeFixtureVault()
        try writeLocalDraft(to: vault, fileName: "draft.md", text: "# Buy milk\n\nGroceries.\n")
        let counting = CountingStubRunner()
        let model = try makeModel(
            vaultPath: vault.path, syncEnabled: false, runner: counting)

        await model.bootstrap()

        XCTAssertEqual(counting.invocationCount, 0, "sync OFF = zero git, zero network")
        XCTAssertEqual(model.syncHealth, .disabled)
        XCTAssertTrue(
            model.tasks.contains { $0.title == "Buy milk" },
            "the launch import ran on the LOCAL vault with sync off")
        XCTAssertEqual(model.tasks.count, 4, "3 fixture tasks + the import")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: vault.path + "/Inbox/draft.md"),
            "the draft was moved, not copied")
        XCTAssertEqual(model.inboxDraftCount, 0)
        XCTAssertEqual(model.inboxProblemCount, 0)
        XCTAssertEqual(model.inboxImportMenuItemLabel, "Import Inbox Drafts (0)")
    }

    func testSyncOffLaunchLeavesNonConformingDraftCounted() async throws {
        let vault = try makeFixtureVault()
        let inbox = vault.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try Data([0xFF, 0xFE, 0x00]).write(to: inbox.appendingPathComponent("junk.md"))
        try writeLocalDraft(to: vault, fileName: "good.md", text: "# Good\nbody")
        let counting = CountingStubRunner()
        let model = try makeModel(
            vaultPath: vault.path, syncEnabled: false, runner: counting)

        await model.bootstrap()

        XCTAssertEqual(counting.invocationCount, 0)
        XCTAssertTrue(model.tasks.contains { $0.title == "Good" })
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: inbox.appendingPathComponent("junk.md").path),
            "the non-conforming draft stays — never discarded/overwritten")
        XCTAssertEqual(model.inboxDraftCount, 0)
        XCTAssertEqual(model.inboxProblemCount, 1, "M shows in the label")
        XCTAssertEqual(model.inboxImportMenuItemLabel, "Import Inbox Drafts (0, 1 problems)")
    }

    // MARK: - The launch trigger, sync ON: the pull precedes the import

    func testLaunchImportRunsAfterThePull() async throws {
        let world = try await GitWorld.make(withLifebotClone: true)
        // The Lifebot pushes an Inbox draft while the app is not running
        // (the §4 store-and-forward shape) — the vault knows nothing of it.
        try await world.lifebotPushesDraft("draft.md", text: "# Remote Task\n\nbody")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: world.vaultInboxDraftURL.path))

        let recording = RecordingPassthroughRunner(behind: world.runner)
        let model = try makeModel(
            vaultPath: world.vaultURL.path, syncEnabled: true,
            remoteURL: world.remoteURLString, runner: recording, debounceInterval: 0.2)

        await model.bootstrap()
        XCTAssertEqual(model.syncHealth, .idle)

        // FUNCTIONAL proof of the pinned ordering: the draft only exists
        // locally after the launch pull's fast-forward — its import means
        // the pull ran BEFORE the import.
        XCTAssertTrue(
            model.tasks.contains { $0.title == "Remote Task" },
            "the remote draft was pulled AND imported at launch")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: world.vaultInboxDraftURL.path))
        XCTAssertEqual(model.inboxDraftCount, 0)

        // MECHANICAL proof (the injected runner records invocation order):
        // the import's only git footprint is the debounced push cycle its
        // same-code-path create triggers (the #49 hook — pushes for
        // free). The first `fetch` (the launch pull) must precede the
        // first `commit` (the import's push).
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline,
            !recording.recordedInvocations.contains(where: { $0.contains("commit") })
        {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let invocations = recording.recordedInvocations
        let firstFetch = try XCTUnwrap(
            invocations.firstIndex { $0.contains("fetch") },
            "the launch pull must fetch")
        let firstCommit = try XCTUnwrap(
            invocations.firstIndex { $0.contains("commit") },
            "the import's debounced push must commit")
        XCTAssertLessThan(firstFetch, firstCommit)
    }

    // MARK: - The menu action: pull-before-import

    func testMenuActionPullsThenImports() async throws {
        let world = try await GitWorld.make(withLifebotClone: true)
        let counting = CountingPassthroughRunner(behind: world.runner)
        let model = try makeModel(
            vaultPath: world.vaultURL.path, syncEnabled: true,
            remoteURL: world.remoteURLString, runner: counting)
        await model.bootstrap()
        XCTAssertEqual(model.syncHealth, .idle)
        XCTAssertEqual(model.inboxDraftCount, 0)
        let afterBootstrap = counting.invocationCount

        // A remote draft lands while the app is running; the menu action
        // must PULL first (the #49 [Pull triggers] seam) and then import.
        try await world.lifebotPushesDraft("draft.md", text: "# Pulled Task\n\nbody")

        await model.importInboxDrafts()

        XCTAssertGreaterThan(
            counting.invocationCount, afterBootstrap,
            "the action pulled before importing")
        XCTAssertTrue(model.tasks.contains { $0.title == "Pulled Task" })
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: world.vaultInboxDraftURL.path))
        XCTAssertEqual(model.inboxDraftCount, 0)
        XCTAssertEqual(model.inboxImportMenuItemLabel, "Import Inbox Drafts (0)")
    }

    func testMenuActionWithSyncOffImportsWithoutSpawning() async throws {
        let vault = try makeFixtureVault()
        let counting = CountingStubRunner()
        let model = try makeModel(
            vaultPath: vault.path, syncEnabled: false, runner: counting)
        await model.bootstrap()
        XCTAssertEqual(counting.invocationCount, 0)

        // The menu action with sync OFF: the pull returns .disabled
        // without spawning, and the local draft still imports.
        try writeLocalDraft(to: vault, fileName: "draft.md", text: "# Offline\nbody")

        await model.importInboxDrafts()

        XCTAssertEqual(counting.invocationCount, 0)
        XCTAssertTrue(model.tasks.contains { $0.title == "Offline" })
        XCTAssertEqual(model.inboxDraftCount, 0)
    }

    // MARK: - Count refreshes

    func testCountsRefreshAfterVaultReload() async throws {
        let vault = try makeFixtureVault()
        let counting = CountingStubRunner()
        let model = try makeModel(
            vaultPath: vault.path, syncEnabled: false, runner: counting)
        await model.bootstrap()
        XCTAssertEqual(model.inboxDraftCount, 0)
        XCTAssertEqual(model.inboxImportMenuItemLabel, "Import Inbox Drafts (0)")

        // Drafts land (e.g. synced externally / written by hand); the
        // next vault reload refreshes the counts.
        try writeLocalDraft(to: vault, fileName: "a.md", text: "# A\nbody")
        try writeLocalDraft(to: vault, fileName: "b.md", text: "# B\nbody")

        await model.reloadVault()

        XCTAssertEqual(model.inboxDraftCount, 2)
        XCTAssertEqual(model.inboxProblemCount, 0)
        XCTAssertEqual(model.inboxImportMenuItemLabel, "Import Inbox Drafts (2)")
    }

    func testFastForwardReloadRefreshesInboxCounts() async throws {
        let world = try await GitWorld.make(withLifebotClone: true)
        let model = try makeModel(
            vaultPath: world.vaultURL.path, syncEnabled: true,
            remoteURL: world.remoteURLString)
        await model.bootstrap()
        XCTAssertEqual(model.inboxDraftCount, 0)

        // A remote draft lands via a fast-forward pull (e.g. the 15-min
        // tick): the post-ff reload is exactly when the counts must see
        // it — WITHOUT importing (imports happen only at the pinned
        // triggers: launch and the menu action).
        try await world.lifebotPushesDraft("draft.md", text: "# Waiting\nbody")
        let outcome = await model.pullVaultOnce()
        XCTAssertEqual(outcome, .fastForwarded)

        await world.waitUntil("the post-ff reload refreshed the Inbox counts") {
            model.inboxDraftCount == 1
        }
        XCTAssertEqual(model.inboxProblemCount, 0)
        XCTAssertEqual(model.inboxImportMenuItemLabel, "Import Inbox Drafts (1)")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: world.vaultInboxDraftURL.path),
            "the draft waits in Inbox/ — no import outside the pinned triggers")
    }

    // MARK: - Enablement (disabled only while unconfigured)

    func testInboxImportDisabledOnlyWhileUnconfigured() async throws {
        let model = try makeModel(vaultPath: nil, syncEnabled: false)
        XCTAssertFalse(model.isInboxImportEnabled)
        XCTAssertEqual(model.inboxImportMenuItemLabel, "Import Inbox Drafts (0)")

        // The defensive backstop: the action is a typed no-op while
        // unconfigured (the menu item itself is disabled there).
        await model.importInboxDrafts()
        if case .notConfigured = model.vaultState {} else {
            XCTFail("expected .notConfigured, got \(model.vaultState)")
        }
        XCTAssertNil(model.vaultStore)

        let vault = try makeFixtureVault()
        let outcome = await model.setVaultPath(to: vault)
        XCTAssertEqual(outcome, .changed)
        XCTAssertTrue(model.isInboxImportEnabled, "configured — even with N=0")
        XCTAssertEqual(model.inboxImportMenuItemLabel, "Import Inbox Drafts (0)")
    }
}
