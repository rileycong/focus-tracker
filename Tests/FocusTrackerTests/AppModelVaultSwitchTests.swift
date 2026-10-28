import XCTest
@testable import FocusTracker

/// Tests for the issue #45 in-app vault switcher's model seams — all
/// WITHOUT AppKit (the `NSOpenPanel`, the Vault menu and the sheet are
/// view-layer; the menu action is the `requestVaultSwitch()` entry point
/// tested here):
/// - the request-state lifecycle (`isVaultSwitcherRequested` set on
///   request, cleared on completion/cancel through
///   `clearVaultSwitchRequest()` — additive only: a successful
///   `setVaultPath` does NOT implicitly clear it, the presenting view
///   owns the clear);
/// - the read-only enablement derivation (`isVaultSwitcherEnabled`)
///   matching the pinned `setVaultPath` refusal chain in EVERY phase —
///   session active (incl. the late-`.changed` retry after submission),
///   `.endingSession`, `.breakActive` refusing; `.tasksView`,
///   `.postSessionChoice`, `.sessionStart`, `.recoveryPrompt` and the
///   degraded path-retained state NOT refusing — each asserted against
///   the actual `setVaultPath` outcome so the derivation cannot drift
///   from the chain;
/// - the per-condition refusal wording (`vaultSwitchRefusalMessage`)
///   naming the remedy for each refusing condition — the wider switcher
///   wording, mirroring the existing pinned refusal tests
///   (`AppModelTests`, `AppModelEndOfSessionTests`,
///   `AppModelBreakTests`);
/// - the extraction wiring: `selectExistingVault` running from the
///   configured healthy state (the sheet's consent path — the #26 matrix
///   covered it from `.notConfigured` only). The flow outcomes themselves
///   (`.valid` → `.changed`, scaffold consent, cancel, collision) stay
///   pinned by the #26 matrix in `AppModelVaultCreationTests`.
///
/// Same seams as the other AppModel suites: injected settings suite,
/// injected persistence directory, manual scheduler, fake clock, and a
/// temp-dir copy of the repo fixture per test.
@MainActor
final class AppModelVaultSwitchTests: XCTestCase {

    // MARK: - Test doubles (the same seams the other AppModel suites use)

    private final class FakeClock: FocusSessionClock, @unchecked Sendable {
        var monotonicSeconds: TimeInterval = 0
        var wallClockNow = Date(timeIntervalSinceReferenceDate: 800_000_000)
    }

    private final class ManualTickScheduler: ActiveSessionTickScheduler,
        @unchecked Sendable {
        func schedule(after interval: TimeInterval, _ tick: @escaping @Sendable () -> Void) {}
        func cancel() {}
    }

    // MARK: - Fixture access (the repo fixture is copied to a temp dir, never touched)

    private static let fixturesVault = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Tests/FocusTrackerTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("fixtures/sample-vault", isDirectory: true)

    private var root: URL!
    private var vaultURL: URL!
    private var persistenceDirectory: URL!
    private var suiteName: String!
    private var settings: AppSettings!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(
                "AppModelVaultSwitchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        vaultURL = root.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.copyItem(at: Self.fixturesVault, to: vaultURL)
        persistenceDirectory = root.appendingPathComponent("persistence", isDirectory: true)
        suiteName = "AppModelVaultSwitchTests-\(UUID().uuidString)"
        settings = try AppSettings(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        if let suiteName {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private struct TestFailure: Error {}

    private func makeModel() -> AppModel {
        AppModel(
            settings: settings,
            persistenceDirectory: persistenceDirectory,
            scheduler: ManualTickScheduler(),
            sessionClock: FakeClock())
    }

    /// A model bootstrapped against the fixture vault (the configured,
    /// healthy startup path — the state the switcher targets).
    private func makeConfiguredModel() async -> AppModel {
        settings.vaultPath = vaultURL.path(percentEncoded: false)
        let model = makeModel()
        await model.bootstrap()
        return model
    }

    /// A second, minimal VALID vault (Tasks/ + Logs/ + one task) — the
    /// path-change target for the switching assertions.
    private func makeSecondVault(named name: String = "vault-b") throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("Tasks", isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("Logs", isDirectory: true),
            withIntermediateDirectories: true)
        try writeTaskFile("Beta task", id: UUID(), in: url)
        return url
    }

    /// Writes a minimal valid task file into the given vault's `Tasks/`.
    private func writeTaskFile(_ title: String, id: UUID, in vault: URL) throws {
        let text = """
        ---
        id: \(id.uuidString)
        title: \(title)
        status: To Do
        categories:
          - Testing
        ---

        Body of \(title).
        """
        try text.write(
            to: vault.appendingPathComponent("Tasks", isDirectory: true)
                .appendingPathComponent("\(title).md"),
            atomically: true, encoding: .utf8)
    }

    private func makeForm() -> EndOfSessionFormState {
        var form = EndOfSessionFormState()
        form.completedChoice = .no
        form.focusRating = 4
        form.energyRating = 3
        return form
    }

    /// Starts a running session on the fixture's first task (In Progress —
    /// the #19 start flow's allowed no-op path, exactly what an "active
    /// session" needs).
    private func startRunningSession(on model: AppModel) async throws {
        let taskID = try XCTUnwrap(model.tasks.first?.id)
        let outcome = try await model.startSession(taskID: taskID)
        guard case .started = outcome else {
            XCTFail("expected .started(...), got \(outcome)")
            throw TestFailure()
        }
    }

    /// Drives one full session through the #22 modal to the #23 choice
    /// phase via the `.success` path (the AppModelBreakTests helper,
    /// mirrored).
    private func runSessionToChoice(on model: AppModel) async throws {
        try await startRunningSession(on: model)
        _ = try model.endSession()
        let submission = try await model.submitEndOfSession(makeForm())
        guard submission == .success else {
            XCTFail("expected .success, got \(String(describing: submission))")
            throw TestFailure()
        }
    }

    /// The live per-condition refusal wording for the model's CURRENT
    /// state — what the shared `ChooseVaultView` surfaces on a typed
    /// `.refusedWhileSessionActive` outcome.
    private func liveRefusalMessage(of model: AppModel) -> String {
        AppModel.vaultSwitchRefusalMessage(
            isSessionActive: model.isSessionActive, appPhase: model.appPhase)
    }

    // MARK: - Request-state lifecycle (no AppKit)

    func testVaultSwitchRequestSetsAndClearsTheRequestState() async throws {
        let model = await makeConfiguredModel()

        XCTAssertFalse(
            model.isVaultSwitcherRequested, "no request before the menu action")

        model.requestVaultSwitch()
        XCTAssertTrue(
            model.isVaultSwitcherRequested,
            "the menu action's entry point sets the request state")

        // Idempotent set: a second request keeps the ONE sheet presented.
        model.requestVaultSwitch()
        XCTAssertTrue(model.isVaultSwitcherRequested)

        // The cancel/completion clear.
        model.clearVaultSwitchRequest()
        XCTAssertFalse(model.isVaultSwitcherRequested)

        // Clearing without a request is a no-op, never a trap.
        model.clearVaultSwitchRequest()
        XCTAssertFalse(model.isVaultSwitcherRequested)
    }

    func testSuccessfulSwitchDoesNotImplicitlyClearTheRequestState() async throws {
        let model = await makeConfiguredModel()
        let vaultB = try makeSecondVault()
        model.requestVaultSwitch()
        XCTAssertTrue(model.isVaultSwitcherRequested)

        // The sheet's `.valid` path: setVaultPath lands `.changed`…
        let outcome = await model.setVaultPath(to: vaultB)
        XCTAssertEqual(outcome, .changed)

        // …but does NOT touch the request state (the additive-only rule:
        // `setVaultPath`'s behavior is unchanged — the presenting view
        // owns the completion clear)…
        XCTAssertTrue(
            model.isVaultSwitcherRequested,
            "setVaultPath itself never clears the request state")

        // …which is exactly the model path the view's completion calls.
        model.clearVaultSwitchRequest()
        XCTAssertFalse(model.isVaultSwitcherRequested)
        XCTAssertEqual(model.vaultURL, vaultB, "the switch itself landed")
    }

    // MARK: - Enablement derivation vs. the refusal chain, per phase

    func testSwitcherDisabledWhileNotConfiguredThoughTheChainItselfAllows() async throws {
        let model = makeModel()
        await model.bootstrap()
        let vaultB = try makeSecondVault()

        // The documented engineer's-choice extra: onboarding owns
        // selection while unconfigured, so the menu item is disabled…
        XCTAssertNil(model.vaultURL)
        XCTAssertFalse(model.isVaultSwitcherEnabled)

        // …although the refusal CHAIN itself does not refuse there —
        // the disable is menu-level policy, not a chain condition.
        let outcome = await model.setVaultPath(to: vaultB)
        XCTAssertEqual(outcome, .changed)
    }

    func testSwitcherEnabledOnTasksViewAgreesWithSetVaultPathOutcome() async throws {
        let model = await makeConfiguredModel()
        let vaultB = try makeSecondVault()

        let enabled = model.isVaultSwitcherEnabled
        let outcome = await model.setVaultPath(to: vaultB)

        XCTAssertTrue(enabled, "the healthy loaded state is the switcher's target")
        XCTAssertEqual(outcome, .changed, "the chain agrees: not refused")
        XCTAssertEqual(model.vaultURL, vaultB)
        // Still enabled on the new vault — no stale state.
        XCTAssertTrue(model.isVaultSwitcherEnabled)
    }

    func testSwitcherDisabledWhileSessionActiveAgreesWithRefusalThenRecovers()
        async throws
    {
        let model = await makeConfiguredModel()
        let neverCreated = root.appendingPathComponent("never-created-vault")
        try await startRunningSession(on: model)
        XCTAssertTrue(model.isSessionActive)

        let enabled = model.isVaultSwitcherEnabled
        let outcome = await model.setVaultPath(to: neverCreated)

        // The derivation matches the chain (the AppModelTests:221 mirror).
        XCTAssertFalse(enabled)
        XCTAssertEqual(outcome, .refusedWhileSessionActive)
        XCTAssertEqual(model.vaultURL, vaultURL, "stores and state untouched")
        XCTAssertEqual(
            settings.vaultPath, vaultURL.path(percentEncoded: false))
        XCTAssertTrue(model.isSessionActive)

        // The refusal wording names the session remedy.
        XCTAssertEqual(
            liveRefusalMessage(of: model),
            "A session is active — finish or end it before changing the vault.")

        // The entry point itself is unguarded by design — the disabled
        // menu item is the UX guard, and a request that lands anyway
        // surfaces the typed refusal in the sheet, never a silent no-op.
        model.requestVaultSwitch()
        XCTAssertTrue(model.isVaultSwitcherRequested)
        model.clearVaultSwitchRequest()

        // The late-`.changed` retry (the AppModelTests:256 mirror): after
        // the end flow completes, the derivation flips and the switch goes
        // through.
        _ = try model.endSession()
        let submission = try await model.submitEndOfSession(makeForm())
        XCTAssertEqual(submission, .success)
        let vaultB = try makeSecondVault()
        XCTAssertTrue(model.isVaultSwitcherEnabled)
        let lateOutcome = await model.setVaultPath(to: vaultB)
        XCTAssertEqual(lateOutcome, .changed)
        XCTAssertEqual(model.vaultURL, vaultB)
    }

    func testSwitcherDisabledWhileEndingSessionAgreesWithRefusal() async throws {
        let model = await makeConfiguredModel()
        try await startRunningSession(on: model)
        _ = try model.endSession()
        guard case .endingSession = model.appPhase else {
            XCTFail("expected .endingSession, got \(model.appPhase)")
            return
        }
        XCTAssertFalse(model.isSessionActive, "the engine already ended")

        let enabled = model.isVaultSwitcherEnabled
        let neverCreated = root.appendingPathComponent("never-created-vault")
        let outcome = await model.setVaultPath(to: neverCreated)

        // The AppModelEndOfSessionTests:549 mirror.
        XCTAssertFalse(enabled)
        XCTAssertEqual(outcome, .refusedWhileSessionActive)
        XCTAssertEqual(model.vaultURL, vaultURL)
        XCTAssertEqual(
            settings.vaultPath, vaultURL.path(percentEncoded: false))

        // The refusal wording names the END-OF-SESSION-FORM remedy — the
        // wider per-condition derivation, not the session-only string.
        XCTAssertEqual(
            liveRefusalMessage(of: model),
            "The end-of-session form is still open — submit it before "
                + "changing the vault.")
    }

    func testSwitcherEnabledDuringPostSessionChoiceAndSwitches() async throws {
        let model = await makeConfiguredModel()
        try await runSessionToChoice(on: model)
        XCTAssertEqual(model.appPhase, .postSessionChoice(completionFailure: nil))

        // The pinned #14/#23 policy (the AppModelBreakTests:536 mirror):
        // the choice phase does NOT refuse — nothing is pending a write
        // until a break actually starts.
        let enabled = model.isVaultSwitcherEnabled
        let vaultB = try makeSecondVault()
        let outcome = await model.setVaultPath(to: vaultB)

        XCTAssertTrue(enabled)
        XCTAssertEqual(outcome, .changed)
        XCTAssertEqual(model.vaultURL, vaultB)
    }

    func testSwitcherDisabledWhileBreakActiveAgreesWithRefusal() async throws {
        let model = await makeConfiguredModel()
        try await runSessionToChoice(on: model)
        try model.takeBreak(duration: 300)
        XCTAssertEqual(model.appPhase, .breakActive)

        let enabled = model.isVaultSwitcherEnabled
        let neverCreated = root.appendingPathComponent("never-created-vault")
        let outcome = await model.setVaultPath(to: neverCreated)

        // The AppModelBreakTests:516 mirror.
        XCTAssertFalse(enabled)
        XCTAssertEqual(outcome, .refusedWhileSessionActive)
        XCTAssertEqual(model.vaultURL, vaultURL)
        XCTAssertEqual(
            settings.vaultPath, vaultURL.path(percentEncoded: false))

        // The refusal wording names the BREAK remedy.
        XCTAssertEqual(
            liveRefusalMessage(of: model),
            "A break is running — end it before changing the vault.")
    }

    func testSwitcherEnabledDuringSessionStartAndSwitches() async throws {
        let model = await makeConfiguredModel()
        try await runSessionToChoice(on: model)
        model.chooseStartNextSession()
        XCTAssertEqual(model.appPhase, .sessionStart)

        // The pinned policy: `.sessionStart` does not refuse (nothing is
        // pending a write — the `.postSessionChoice` policy).
        let enabled = model.isVaultSwitcherEnabled
        let vaultB = try makeSecondVault()
        let outcome = await model.setVaultPath(to: vaultB)

        XCTAssertTrue(enabled)
        XCTAssertEqual(outcome, .changed)
        XCTAssertEqual(model.vaultURL, vaultB)
    }

    func testSwitcherEnabledDuringRecoveryPromptAndSwitches() async throws {
        let taskID = UUID()
        try writeTaskFile("Switcher recovery task", id: taskID, in: vaultURL)
        let snapshot = ActiveSessionSnapshot(
            sessionID: UUID(), taskID: taskID, duration: 1500,
            startedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            accumulatedFocusedSeconds: 120, accumulatedPausedSeconds: 0,
            pauseCount: 0, isPaused: false, segmentStartMonotonic: 42)
        try FileActiveSessionPersistence(directory: persistenceDirectory)
            .save(snapshot)

        let model = await makeConfiguredModel()
        guard case .recoveryPrompt = model.appPhase else {
            XCTFail("expected .recoveryPrompt, got \(model.appPhase)")
            return
        }

        // The pinned policy: `.recoveryPrompt` does not refuse (the
        // snapshot is app-local, not vault-bound — §13's pinned scope).
        let enabled = model.isVaultSwitcherEnabled
        let vaultB = try makeSecondVault()
        let outcome = await model.setVaultPath(to: vaultB)

        XCTAssertTrue(enabled)
        XCTAssertEqual(outcome, .changed)
        XCTAssertEqual(model.vaultURL, vaultB)
    }

    func testSwitcherEnabledInDegradedStateWithPathRetained() async throws {
        let model = await makeConfiguredModel()

        try FileManager.default.removeItem(at: vaultURL)
        await model.reloadVault()
        guard case .vaultMissing = model.vaultState else {
            XCTFail("expected .vaultMissing, got \(model.vaultState)")
            return
        }
        XCTAssertEqual(model.vaultURL, vaultURL, "the path is retained")

        // Degraded states stay enabled (documented): the chain does not
        // refuse there and `setVaultPath` is the remedy — re-selection
        // works from the switcher exactly as from the degraded banner.
        let enabled = model.isVaultSwitcherEnabled
        let vaultB = try makeSecondVault()
        let outcome = await model.setVaultPath(to: vaultB)

        XCTAssertTrue(enabled)
        XCTAssertEqual(outcome, .changed)
        XCTAssertEqual(model.vaultURL, vaultB)
    }

    // MARK: - Refusal wording (the per-condition remedy derivation)

    func testRefusalMessageFallbackNamesEveryRemedyForTheDefensiveCase() {
        // The defensive unreachable branch (a refusal outcome with no live
        // refusing condition) still names every remedy — never a bare
        // "cannot change the vault".
        let fallback = AppModel.vaultSwitchRefusalMessage(
            isSessionActive: false, appPhase: .tasksView)
        XCTAssertEqual(
            fallback,
            "The vault cannot be changed right now — finish any open "
                + "session, submit the end-of-session form, or end the "
                + "running break first.")

        // Distinct from the session wording (the ending/break wordings are
        // pinned exactly by the phase tests above).
        let session = AppModel.vaultSwitchRefusalMessage(
            isSessionActive: true, appPhase: .tasksView)
        XCTAssertEqual(
            session,
            "A session is active — finish or end it before changing the vault.")
        XCTAssertNotEqual(fallback, session)
    }

    // MARK: - Extraction wiring (the shared flow from the healthy state)

    func testSelectExistingVaultRunsFromTheConfiguredHealthyState() async throws {
        let model = await makeConfiguredModel()

        // The sheet's consent path: a folder with missing structure,
        // consented — ONLY the missing directories are scaffolded, then
        // the path is stored like a normal selection. (The #26 matrix
        // pinned this from `.notConfigured`; the switcher sheet runs the
        // same API from the configured healthy state.)
        let folder = root.appendingPathComponent("missing-structure", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let scaffolded = try await model.selectExistingVault(
            at: folder, scaffoldMissingWithConsent: true)

        XCTAssertEqual(scaffolded, .scaffolded(folder))
        XCTAssertEqual(model.vaultURL, folder)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: folder.appendingPathComponent("Tasks").path(percentEncoded: false)))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: folder.appendingPathComponent("Logs").path(percentEncoded: false)))

        // The declined-consent path: typed `.cancelled`, nothing modified,
        // the previously selected vault retained.
        let declined = root.appendingPathComponent("declined", isDirectory: true)
        try FileManager.default.createDirectory(at: declined, withIntermediateDirectories: true)
        let cancelled = try await model.selectExistingVault(
            at: declined, scaffoldMissingWithConsent: false)

        XCTAssertEqual(cancelled, .cancelled(declined))
        XCTAssertEqual(
            model.vaultURL, folder, "the declined consent changed nothing")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: declined.appendingPathComponent("Tasks").path(percentEncoded: false)),
            "nothing was scaffolded without consent")
    }
}
