import XCTest
import AppKit
@testable import FocusTracker

/// Tests for the #43 compact mini break — the #21/#37 compact state machine
/// extended to the break lifecycle: `isMiniBreakActive` + the
/// guard-mirrored `collapseToMiniBreak()`/`restoreFromMiniBreak()` (typed
/// no-ops unless a break runs AND the phase is `.breakActive`), the #37
/// invariants carried over (collapse/restore cycles ≥3 with the AppModel
/// identity stable — same instance, no re-init, no re-bootstrap — and the
/// break engine untouched), and `endBreak()` clearing the flag on EVERY
/// outcome (the early end, the focused post-expiry acknowledgment, the
/// non-blocking log-failure path, and the unfocused-expiry focus-back
/// auto-end) before the #34 `.sessionStart` routing. The window-level
/// invariants (same-window identity, styleMask ownership, no hide) are the
/// break-variant extensions in `MiniTimerPresentationTests`. Temp-dir
/// fixture copy per the established pattern; the FakeClock drives every
/// duration so the append arithmetic invariant holds exactly.
@MainActor
final class AppModelMiniBreakTests: XCTestCase {

    // MARK: - Test doubles (same seams as the #23 break tests)

    private final class FakeClock: FocusSessionClock, @unchecked Sendable {
        var monotonicSeconds: TimeInterval = 0
        var wallClockNow = Date(timeIntervalSinceReferenceDate: 800_000_000)

        func advance(by interval: TimeInterval) {
            monotonicSeconds += interval
            wallClockNow = wallClockNow.addingTimeInterval(interval)
        }
    }

    private final class ManualTickScheduler: ActiveSessionTickScheduler, @unchecked Sendable {
        func schedule(after interval: TimeInterval, _ tick: @escaping @Sendable () -> Void) {}
        func cancel() {}
    }

    private final class ManualAlarmActionScheduler: ExpiryAlarmActionScheduling {
        private var pendingAction: (@MainActor @Sendable () async -> Void)?

        func schedule(_ action: @escaping @MainActor @Sendable () async -> Void) {
            pendingAction = action
        }

        func fire() async {
            let action = pendingAction
            pendingAction = nil
            await action?()
        }
    }

    private final class FocusProbe { var isActive = true }
    private final class BeepCounter { var count = 0 }
    private final class CountingPlayer: ExpiryAlarmPlaying {
        let counter: BeepCounter
        init(counter: BeepCounter) { self.counter = counter }
        func play() throws { counter.count += 1 }
        func stop() {}
    }

    // MARK: - Fixture access

    private static let fixturesVault = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("fixtures/sample-vault", isDirectory: true)

    private var root: URL!
    private var vaultURL: URL!
    private var persistenceDirectory: URL!
    private var suiteName: String!
    private var settings: AppSettings!
    private var clock: FakeClock!
    private var focusProbe: FocusProbe!
    private var beeps: BeepCounter!
    private var alarmActionScheduler: ManualAlarmActionScheduler!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("AppModelMiniBreakTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        vaultURL = root.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.copyItem(at: Self.fixturesVault, to: vaultURL)
        persistenceDirectory = root.appendingPathComponent("persistence", isDirectory: true)
        suiteName = "AppModelMiniBreakTests-\(UUID().uuidString)"
        settings = try AppSettings(suiteName: suiteName)
        clock = FakeClock()
        focusProbe = FocusProbe()
        beeps = BeepCounter()
        alarmActionScheduler = ManualAlarmActionScheduler()
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        if let suiteName {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private struct TestFailure: Error {}

    private func makeConfiguredModel() async -> AppModel {
        settings.vaultPath = vaultURL.path(percentEncoded: false)
        let probe = focusProbe!
        let counter = beeps!
        let alarm = ExpiryAlarmController(
            player: CountingPlayer(counter: counter),
            isAppActive: { probe.isActive })
        let model = AppModel(
            settings: settings, persistenceDirectory: persistenceDirectory,
            scheduler: ManualTickScheduler(), sessionClock: clock,
            expiryAlarm: alarm,
            expiryAlarmActionScheduler: alarmActionScheduler)
        await model.bootstrap()
        return model
    }

    private func writeTaskFile(_ title: String, id: UUID) throws {
        let lines = [
            "---",
            "id: \(id.uuidString)",
            "title: \(title)",
            "status: To Do",
            "categories:",
            "  - Testing",
            "---",
        ]
        try (lines.joined(separator: "\n") + "\n").write(
            to: vaultURL.appendingPathComponent("Tasks", isDirectory: true)
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

    /// Drives one full session through the #22 modal to the #23 choice
    /// phase via the `.success` path, so a break can start.
    private func runSessionToChoice(on model: AppModel, taskID: UUID) async throws {
        let outcome = try await model.startSession(taskID: taskID)
        guard case .started = outcome else {
            XCTFail("expected .started(...), got \(outcome)")
            throw TestFailure()
        }
        clock.advance(by: 600)
        try model.pauseSession()
        clock.advance(by: 300)
        try model.resumeSession()
        clock.advance(by: 900)
        _ = try model.endSession()
        let submission = try await model.submitEndOfSession(makeForm())
        XCTAssertEqual(submission, .success)
        XCTAssertEqual(model.appPhase, .postSessionChoice(completionFailure: nil))
    }

    /// Starts a break from the choice phase and asserts the full-screen
    /// starting state: flag off, phase `.breakActive`.
    private func startBreak(
        on model: AppModel, duration: TimeInterval = 300
    ) throws {
        try model.takeBreak(duration: duration)
        XCTAssertEqual(model.appPhase, .breakActive)
        XCTAssertFalse(model.isMiniBreakActive, "a fresh break starts full")
    }

    /// Replaces `Logs/` with a regular FILE so any append fails typed with
    /// `.directoryCreationFailed` (nothing written) — the #22/#23
    /// obstruction.
    private func obstructLogsDirectory() throws {
        let logsDirectory = vaultURL.appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.removeItem(at: logsDirectory)
        let logsPath = vaultURL.appendingPathComponent("Logs", isDirectory: false)
        try Data("not a directory".utf8).write(to: logsPath)
    }

    // MARK: - Collapse while a break runs (issue #43)

    func testCollapseWhileBreakActiveSetsFlagLeavesBreakAndPhaseUntouched() async throws {
        let taskID = UUID()
        try writeTaskFile("Mini break task", id: taskID)
        let model = await makeConfiguredModel()
        try await runSessionToChoice(on: model, taskID: taskID)
        try startBreak(on: model, duration: 300)
        let remainingBefore = model.breakRemainingSeconds
        let durationBefore = model.breakDurationSeconds

        model.collapseToMiniBreak()

        XCTAssertTrue(model.isMiniBreakActive, "mini-break flag on")
        // The phase stays `.breakActive` (the #21 flag-beside-phase choice,
        // mirrored) — no content torn down, no second lifecycle.
        XCTAssertEqual(model.appPhase, .breakActive)
        // Break untouched: same engine readings at the frozen clock.
        XCTAssertTrue(model.isBreakActive)
        XCTAssertEqual(model.breakRemainingSeconds, remainingBefore)
        XCTAssertEqual(model.breakDurationSeconds, durationBefore)
        XCTAssertEqual(model.breakProgressFraction, 0, accuracy: 1e-12)
    }

    func testCollapseRefusedWhileIdleOutsideBreakPhaseAndWhenAlreadyCollapsed() async throws {
        let taskID = UUID()
        try writeTaskFile("Guard task", id: taskID)
        let model = await makeConfiguredModel()

        // Idle (no break, tasks view): typed no-op.
        model.collapseToMiniBreak()
        XCTAssertFalse(model.isMiniBreakActive)
        XCTAssertEqual(model.appPhase, .tasksView)

        // A running SESSION is not a break: still a no-op.
        let startOutcome = try await model.startSession(taskID: taskID)
        guard case .started(let context) = startOutcome else {
            XCTFail("expected .started(...), got \(startOutcome)")
            throw TestFailure()
        }
        model.collapseToMiniBreak()
        XCTAssertFalse(model.isMiniBreakActive, "the session timer never compacts the break variant")
        XCTAssertEqual(model.appPhase, .timerView(context))

        // The choice phase is not a break either.
        _ = try model.endSession()
        _ = try await model.submitEndOfSession(makeForm())
        model.collapseToMiniBreak()
        XCTAssertFalse(model.isMiniBreakActive)
        XCTAssertEqual(model.appPhase, .postSessionChoice(completionFailure: nil))

        // While collapsed, a second collapse request is a no-op (the
        // `collapseToMiniTimer` double-request guard, mirrored).
        try startBreak(on: model)
        model.collapseToMiniBreak()
        model.collapseToMiniBreak()
        XCTAssertTrue(model.isMiniBreakActive)
    }

    func testRestoreWhenNotCollapsedIsTypedNoOp() async throws {
        let taskID = UUID()
        try writeTaskFile("Restore guard task", id: taskID)
        let model = await makeConfiguredModel()
        try await runSessionToChoice(on: model, taskID: taskID)
        try startBreak(on: model)

        model.restoreFromMiniBreak()

        XCTAssertFalse(model.isMiniBreakActive)
        XCTAssertEqual(model.appPhase, .breakActive, "break untouched")
        XCTAssertTrue(model.isBreakActive)
    }

    // MARK: - Collapse/restore cycles: the #37 invariants, break variant

    func testThreeCollapseRestoreCyclesKeepBreakAndModelIdentityStable() async throws {
        let taskID = UUID()
        try writeTaskFile("Cycle task", id: taskID)
        let model = await makeConfiguredModel()
        try await runSessionToChoice(on: model, taskID: taskID)
        try startBreak(on: model, duration: 300)
        let remainingBefore = model.breakRemainingSeconds
        let identity = ObjectIdentifier(model)
        let initializationCount = AppModel.initializationCount
        let bootstrapCount = AppModel.bootstrapCount

        for cycle in 1...3 {
            model.collapseToMiniBreak()
            XCTAssertTrue(model.isMiniBreakActive, "cycle \(cycle): compact")
            XCTAssertEqual(model.appPhase, .breakActive, "cycle \(cycle): phase stable")

            model.restoreFromMiniBreak()
            XCTAssertFalse(model.isMiniBreakActive, "cycle \(cycle): full")
            XCTAssertEqual(model.appPhase, .breakActive, "cycle \(cycle): no phase change")
            XCTAssertTrue(model.isBreakActive, "cycle \(cycle): break still running")
            XCTAssertEqual(model.breakRemainingSeconds, remainingBefore, "cycle \(cycle): engine untouched")
            XCTAssertEqual(ObjectIdentifier(model), identity, "cycle \(cycle): same AppModel instance")
            XCTAssertEqual(AppModel.initializationCount, initializationCount, "cycle \(cycle): no re-init")
            XCTAssertEqual(AppModel.bootstrapCount, bootstrapCount, "cycle \(cycle): no re-bootstrap")
        }
    }

    // MARK: - End from compact: every outcome clears the flag and routes

    func testEndBreakEarlyFromCompactClearsFlagLogsAndRoutesToSessionStart() async throws {
        let taskID = UUID()
        try writeTaskFile("Early end mini task", id: taskID)
        let model = await makeConfiguredModel()
        try await runSessionToChoice(on: model, taskID: taskID)
        try startBreak(on: model, duration: 300)
        model.collapseToMiniBreak()
        XCTAssertTrue(model.isMiniBreakActive)
        clock.advance(by: 130)

        let outcome = await model.endBreak()

        guard case .logged(let logged) = outcome else {
            XCTFail("expected .logged(...), got \(String(describing: outcome))")
            return
        }
        XCTAssertEqual(logged.duration, 2, "the actual timed duration is logged")
        // The #34 routing, reached with normal presentation restored first
        // (the flag cleared by the same end path — the `isMiniTimerActive`
        // precedent, mirrored).
        XCTAssertEqual(model.appPhase, .sessionStart)
        XCTAssertFalse(model.isBreakActive)
        XCTAssertFalse(model.isMiniBreakActive, "flag cleared on the early-end outcome")
    }

    func testFocusedExpiryWhileCompactKeepsFlagThenAcknowledgmentClearsAndRoutes() async throws {
        let taskID = UUID()
        try writeTaskFile("Focused expiry mini task", id: taskID)
        let model = await makeConfiguredModel()
        try await runSessionToChoice(on: model, taskID: taskID)
        try startBreak(on: model, duration: 120)
        model.collapseToMiniBreak()
        focusProbe.isActive = true

        // Focused expiry while compact (the documented choice): the mini's
        // own watch loop fires, no alarm — the countdown renders 0:00 in
        // the done color and the control swaps to the post-expiry label;
        // the banner/ring stay on the full view and re-surface on restore.
        clock.advance(by: 130)
        model.evaluateBreakExpiry()
        XCTAssertTrue(model.isBreakExpired)
        XCTAssertEqual(model.breakRemainingSeconds, 0, "the compact countdown's 0:00 source")
        XCTAssertFalse(model.isExpiryAlarmActive, "focused expiry never alarms")
        XCTAssertEqual(beeps.count, 0)
        XCTAssertTrue(model.isMiniBreakActive, "the compact surface stays up at expiry")
        XCTAssertEqual(model.appPhase, .breakActive)

        // The post-expiry acknowledgment from compact (the "Start next
        // session" label): ends, logs at the clamped configured duration,
        // clears the flag, routes to .sessionStart.
        let outcome = await model.endBreak()
        guard case .logged(let logged) = outcome else {
            XCTFail("expected .logged(...), got \(String(describing: outcome))")
            return
        }
        XCTAssertEqual(logged.duration, 2, "post-expiry duration is the configured one, clamped")
        XCTAssertEqual(model.appPhase, .sessionStart)
        XCTAssertFalse(model.isBreakActive)
        XCTAssertFalse(model.isMiniBreakActive, "flag cleared on the post-expiry outcome")
    }

    func testBreakLogFailureFromCompactStillClearsFlagAndRoutesToSessionStart() async throws {
        let taskID = UUID()
        try writeTaskFile("Log failure mini task", id: taskID)
        let model = await makeConfiguredModel()
        try await runSessionToChoice(on: model, taskID: taskID)
        try startBreak(on: model, duration: 300)
        model.collapseToMiniBreak()
        clock.advance(by: 300)
        try obstructLogsDirectory()

        let outcome = await model.endBreak()

        guard case .logFailed = outcome else {
            XCTFail("expected .logFailed(...), got \(String(describing: outcome))")
            return
        }
        // NON-BLOCKING by pinned design: warning surfaced, flow still
        // reaches .sessionStart — with normal presentation restored (the
        // flag cleared even on the failure outcome).
        XCTAssertEqual(model.appPhase, .sessionStart)
        XCTAssertFalse(model.isBreakActive)
        XCTAssertFalse(model.isMiniBreakActive, "flag cleared on the log-failure outcome")
        XCTAssertNotNil(model.pendingBreakLogWarning)
    }

    func testUnfocusedExpiryWhileCompactShakesThenFocusBackClearsFlagAndRoutes() async throws {
        let taskID = UUID()
        try writeTaskFile("Unfocused expiry mini task", id: taskID)
        let model = await makeConfiguredModel()
        try await runSessionToChoice(on: model, taskID: taskID)
        try startBreak(on: model, duration: 120)
        model.collapseToMiniBreak()
        focusProbe.isActive = false

        // Unfocused expiry while compact: the mini's own watch loop starts
        // the shared alarm — beep + shake (the #39 seam's input flips on)
        // while the compact surface STAYS visible and collapsed.
        clock.advance(by: 130)
        model.evaluateBreakExpiry()
        XCTAssertTrue(model.isExpiryAlarmActive, "the shake seam's input is on")
        XCTAssertEqual(beeps.count, 1, "the shared controller beeps immediately")
        XCTAssertTrue(model.isMiniBreakActive, "compact stays up while alarming")
        XCTAssertEqual(model.appPhase, .breakActive)

        // Focus-back: the alarm stops and the model ends/logs at the
        // expiry instant, clears the flag, and routes to .sessionStart.
        focusProbe.isActive = true
        NotificationCenter.default.post(
            name: NSApplication.didBecomeActiveNotification, object: nil)
        await alarmActionScheduler.fire()

        XCTAssertFalse(model.isExpiryAlarmActive)
        XCTAssertFalse(model.isBreakActive)
        XCTAssertFalse(model.isMiniBreakActive, "flag cleared on the focus-back auto-end")
        XCTAssertEqual(model.appPhase, .sessionStart)
        let store = DailyLogStore(vaultURL: vaultURL)
        let day = try await store.readDay(for: clock.wallClockNow)
        let logged = try XCTUnwrap(day.breaks.last)
        XCTAssertEqual(logged.duration, 2)
        XCTAssertEqual(
            logged.endedAt.timeIntervalSince(logged.startedAt), 120, accuracy: 1e-9,
            "focus-back delay is excluded; ended_at is the expiry instant")
    }

    // MARK: - takeBreak resets (a fresh break starts full)

    func testTakeBreakAfterACompactBreakEndedStartsFull() async throws {
        let taskID = UUID()
        try writeTaskFile("Fresh break task", id: taskID)
        let model = await makeConfiguredModel()
        try await runSessionToChoice(on: model, taskID: taskID)

        // One compact break, ended from compact.
        try startBreak(on: model, duration: 300)
        model.collapseToMiniBreak()
        XCTAssertTrue(model.isMiniBreakActive)
        _ = await model.endBreak()
        XCTAssertFalse(model.isMiniBreakActive)
        XCTAssertEqual(model.appPhase, .sessionStart)

        // The next break (through the full loop) starts FULL — the flag
        // never leaks across breaks.
        let outcome = try await model.startSession(taskID: taskID)
        guard case .started = outcome else {
            XCTFail("expected .started(...), got \(outcome)")
            throw TestFailure()
        }
        _ = try model.endSession()
        _ = try await model.submitEndOfSession(makeForm())
        try startBreak(on: model)
        XCTAssertFalse(model.isMiniBreakActive, "the fresh break is full-screen")
    }
}
