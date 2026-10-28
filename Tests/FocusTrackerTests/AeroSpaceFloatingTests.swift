import XCTest
@testable import FocusTracker

/// Tests for the #44 AeroSpace floating seam: the pure pinned-contract
/// helpers (argv building, `list-windows` parsing, executable
/// resolution), the production `AeroSpaceCompactWindowFloating` flow
/// (resolve → list-windows → parse → layout, plus every silent-no-op
/// degradation path), and the real `SystemAeroSpaceProcessRunner`
/// (deadline, exit codes, stdout capture) exercised against system
/// binaries only — never aerospace itself. The command assertions run
/// against the scripted runner double, so nothing here depends on
/// AeroSpace being installed or running.
@MainActor
final class AeroSpaceFloatingTests: XCTestCase {

    // MARK: - Test doubles

    /// Records every invocation and answers from the script — the seam
    /// the command assertions run against (no aerospace involved).
    private final class ScriptedRunner: AeroSpaceProcessRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [(executable: URL, arguments: [String])] = []
        private let script: ([String]) -> AeroSpaceInvocationOutcome

        init(script: @escaping ([String]) -> AeroSpaceInvocationOutcome) {
            self.script = script
        }

        func run(_ executable: URL, _ arguments: [String]) async -> AeroSpaceInvocationOutcome {
            record(executable, arguments)
        }

        /// `NSLock` is unavailable from async contexts; this synchronous
        /// helper holds it only for the append + script call (no awaits
        /// inside the scope).
        private func record(
            _ executable: URL, _ arguments: [String]
        ) -> AeroSpaceInvocationOutcome {
            lock.lock()
            defer { lock.unlock() }
            recorded.append((executable, arguments))
            return script(arguments)
        }

        var invocations: [(executable: URL, arguments: [String])] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }
    }

    /// Captures the detached flow's action; the test runs it to
    /// completion deterministically (the `ExpiryAlarmActionScheduling`
    /// test-double precedent — no real subprocess scheduling in tests).
    @MainActor
    private final class ManualScheduler: AeroSpaceInvocationScheduling {
        private(set) var actions: [@Sendable () async -> Void] = []

        func schedule(_ action: @escaping @Sendable () async -> Void) {
            actions.append(action)
        }

        func runAll() async {
            for action in actions { await action() }
        }
    }

    // MARK: - Fixtures and helpers

    /// A realistic multi-line `list-windows` payload: other apps' lines
    /// around our single-window match (issue #44's pinned format).
    private static let listWindowsOutput = """
        3561 com.mitchellh.ghostty
        12029 com.apple.Safari
        4242 com.chauanhcong.FocusTracker
        9999 org.mozilla.firefox

        """

    private let fakeBinary = URL(fileURLWithPath: "/opt/homebrew/bin/aerospace")

    /// Captures the completion the production seam delivers on the main
    /// actor (issue #44 amendment 2): thread-safe result box, no
    /// XCTestExpectation spin.
    private final class CompletionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Bool?

        func record(_ value: Bool) {
            lock.lock()
            result = value
            lock.unlock()
        }

        var value: Bool? {
            lock.lock()
            defer { lock.unlock() }
            return result
        }
    }

    private static func scriptAnsweringListWindows(
        _ output: String
    ) -> ([String]) -> AeroSpaceInvocationOutcome {
        { arguments in
            arguments == AeroSpaceCLI.listWindowsArguments()
                ? AeroSpaceInvocationOutcome(status: .exited(code: 0), stdout: output)
                : .success
        }
    }

    private func makeFloating(
        runner: ScriptedRunner,
        scheduler: ManualScheduler,
        resolveExecutable: @escaping @Sendable () -> URL? = {
            URL(fileURLWithPath: "/opt/homebrew/bin/aerospace")
        }
    ) -> AeroSpaceCompactWindowFloating {
        AeroSpaceCompactWindowFloating(
            runner: runner, resolveExecutable: resolveExecutable,
            scheduler: scheduler)
    }

    // MARK: - Pure helpers: argv

    func testListWindowsArgumentsMatchThePinnedContract() {
        XCTAssertEqual(
            AeroSpaceCLI.listWindowsArguments(),
            ["list-windows", "--all", "--format", "%{window-id} %{app-bundle-id}"])
    }

    func testLayoutArgumentsPutTheWindowIDFlagBeforeThePositionalTarget() {
        XCTAssertEqual(
            AeroSpaceCLI.layoutArguments(windowID: 3561, floating: true),
            ["layout", "--window-id", "3561", "floating"])
        XCTAssertEqual(
            AeroSpaceCLI.layoutArguments(windowID: 77, floating: false),
            ["layout", "--window-id", "77", "tiling"])
        // No --fail-if-noop: repeating the current layout must stay a
        // no-op, never an error (issue #44).
        XCTAssertFalse(
            AeroSpaceCLI.layoutArguments(windowID: 3561, floating: true)
                .contains("--fail-if-noop"))
    }

    // MARK: - Pure helpers: list-windows parsing

    func testParseWindowIDMatchesTheSpecExampleLine() {
        XCTAssertEqual(
            AeroSpaceCLI.parseWindowID(
                "3561 com.chauanhcong.FocusTracker",
                bundleID: AeroSpaceCLI.appBundleID),
            3561)
    }

    func testParseWindowIDFindsOurLineAmongMultiLineOutput() {
        XCTAssertEqual(
            AeroSpaceCLI.parseWindowID(
                Self.listWindowsOutput, bundleID: AeroSpaceCLI.appBundleID),
            4242)
    }

    func testParseWindowIDToleratesTrailingNewlinesAndCarriageReturns() {
        XCTAssertEqual(
            AeroSpaceCLI.parseWindowID(
                "3561 com.apple.Safari\r\n4242 com.chauanhcong.FocusTracker\r\n",
                bundleID: AeroSpaceCLI.appBundleID),
            4242)
    }

    func testParseWindowIDReturnsNilWhenUnparsableOrAbsent() {
        let cases = [
            "",                                              // empty output
            "3561 com.mitchellh.ghostty\n",                  // we are not listed
            "not-a-number com.chauanhcong.FocusTracker\n",   // non-numeric id
            "com.chauanhcong.FocusTracker\n",                // single token — no id
            "3561 com.chauanhcong.FocusTrackerPlus\n",       // prefix ≠ exact match
            "\n\n   \n",                                     // blank/whitespace lines
        ]
        for output in cases {
            XCTAssertNil(
                AeroSpaceCLI.parseWindowID(output, bundleID: AeroSpaceCLI.appBundleID),
                "output: \(output.debugDescription)")
        }
    }

    func testParseWindowLineReturnsOurLineWithExtraColumnsVerbatim() {
        // The amendment 2 harness layout probe: with a format that appends
        // `%{window-layout}`, the matched line carries the layout column.
        XCTAssertEqual(
            AeroSpaceCLI.parseWindowLine(
                "3561 com.mitchellh.ghostty h_tiles\n"
                    + "4242 com.chauanhcong.FocusTracker floating\n"
                    + "9999 org.mozilla.firefox h_tiles",
                bundleID: AeroSpaceCLI.appBundleID),
            "4242 com.chauanhcong.FocusTracker floating")
        // The pinned two-column format parses identically.
        XCTAssertEqual(
            AeroSpaceCLI.parseWindowLine(
                Self.listWindowsOutput, bundleID: AeroSpaceCLI.appBundleID),
            "4242 com.chauanhcong.FocusTracker")
    }

    func testParseWindowLineToleratesCRLFAndReturnsNilWhenUnparsableOrAbsent() {
        XCTAssertEqual(
            AeroSpaceCLI.parseWindowLine(
                "3561 com.apple.Safari h_tiles\r\n"
                    + "4242 com.chauanhcong.FocusTracker floating\r\n",
                bundleID: AeroSpaceCLI.appBundleID),
            "4242 com.chauanhcong.FocusTracker floating")
        let cases = [
            "",
            "3561 com.mitchellh.ghostty h_tiles\n",
            "not-a-number com.chauanhcong.FocusTracker floating\n",
            "com.chauanhcong.FocusTracker\n",
            "3561 com.chauanhcong.FocusTrackerPlus h_tiles\n",
        ]
        for output in cases {
            XCTAssertNil(
                AeroSpaceCLI.parseWindowLine(output, bundleID: AeroSpaceCLI.appBundleID),
                "output: \(output.debugDescription)")
        }
    }

    // MARK: - Pure helpers: executable resolution

    func testResolveExecutableURLPrefersThePinnedHomebrewLocation() {
        let url = AeroSpaceCLI.resolveExecutableURL(
            isExecutable: {
                $0 == "/opt/homebrew/bin/aerospace" || $0 == "/usr/local/bin/aerospace"
            },
            environmentPATH: "/usr/local/bin:/usr/bin")
        XCTAssertEqual(url, fakeBinary)
    }

    func testResolveExecutableURLFallsBackToPATH() {
        let url = AeroSpaceCLI.resolveExecutableURL(
            isExecutable: { $0 == "/usr/local/bin/aerospace" },
            environmentPATH: "/usr/bin:/usr/local/bin:/bin")
        XCTAssertEqual(url, URL(fileURLWithPath: "/usr/local/bin/aerospace"))
    }

    func testResolveExecutableURLReturnsNilWhenAeroSpaceIsAbsent() {
        XCTAssertNil(
            AeroSpaceCLI.resolveExecutableURL(
                isExecutable: { _ in false },
                environmentPATH: "/usr/bin:/bin"))
    }

    // MARK: - Production flow: resolve → list-windows → layout

    func testFloatRunsResolutionThenFloatingLayoutWithTheParsedWindowID() async {
        let runner = ScriptedRunner(
            script: Self.scriptAnsweringListWindows(Self.listWindowsOutput))
        let scheduler = ManualScheduler()
        let floating = makeFloating(runner: runner, scheduler: scheduler)
        let completion = CompletionBox()

        floating.float(
            bundleID: AeroSpaceCLI.appBundleID, completion: { completion.record($0) })
        await scheduler.runAll()

        XCTAssertEqual(
            runner.invocations.map(\.executable), [fakeBinary, fakeBinary],
            "both invocations use the resolved binary")
        XCTAssertEqual(
            runner.invocations.map(\.arguments),
            [
                AeroSpaceCLI.listWindowsArguments(),
                ["layout", "--window-id", "4242", "floating"],
            ],
            "entering compact resolves the window id, then floats it")
        XCTAssertEqual(
            completion.value, true,
            "the completion reports the successful layout (amendment 2)")
    }

    func testTileRunsResolutionThenTilingLayout() async {
        let runner = ScriptedRunner(
            script: Self.scriptAnsweringListWindows(Self.listWindowsOutput))
        let scheduler = ManualScheduler()
        let floating = makeFloating(runner: runner, scheduler: scheduler)
        let completion = CompletionBox()

        floating.tile(
            bundleID: AeroSpaceCLI.appBundleID, completion: { completion.record($0) })
        await scheduler.runAll()

        XCTAssertEqual(
            runner.invocations.map(\.arguments),
            [
                AeroSpaceCLI.listWindowsArguments(),
                ["layout", "--window-id", "4242", "tiling"],
            ],
            "restoring full mode resolves the window id again, then tiles it")
        XCTAssertEqual(completion.value, true)
    }

    func testNonZeroListWindowsExitIsASilentNoOp() async {
        // Non-zero exit is also the "AeroSpace not running" detector: the
        // CLI exits non-zero when its server is unreachable (issue #44).
        let runner = ScriptedRunner { _ in
            AeroSpaceInvocationOutcome(status: .exited(code: 1), stdout: "")
        }
        let scheduler = ManualScheduler()
        let floating = makeFloating(runner: runner, scheduler: scheduler)
        let completion = CompletionBox()

        floating.float(
            bundleID: AeroSpaceCLI.appBundleID, completion: { completion.record($0) })
        await scheduler.runAll()

        XCTAssertEqual(
            runner.invocations.map(\.arguments),
            [AeroSpaceCLI.listWindowsArguments()],
            "no layout command after a failed resolution")
        XCTAssertEqual(
            completion.value, false,
            "the completion still fires — degraded (amendment 2)")
    }

    func testTimedOutListWindowsIsASilentNoOp() async {
        let runner = ScriptedRunner { _ in
            AeroSpaceInvocationOutcome(status: .timedOut, stdout: "")
        }
        let scheduler = ManualScheduler()
        let floating = makeFloating(runner: runner, scheduler: scheduler)
        let completion = CompletionBox()

        floating.tile(
            bundleID: AeroSpaceCLI.appBundleID, completion: { completion.record($0) })
        await scheduler.runAll()

        XCTAssertEqual(
            runner.invocations.map(\.arguments),
            [AeroSpaceCLI.listWindowsArguments()],
            "the 2 s deadline expiry stops the flow before any layout")
        XCTAssertEqual(completion.value, false)
    }

    func testLaunchFailedListWindowsIsASilentNoOp() async {
        // Launch ENOENT surfaced through the runner (binary vanished
        // between resolution and launch).
        let runner = ScriptedRunner { _ in
            AeroSpaceInvocationOutcome(status: .launchFailed, stdout: "")
        }
        let scheduler = ManualScheduler()
        let floating = makeFloating(runner: runner, scheduler: scheduler)
        let completion = CompletionBox()

        floating.float(
            bundleID: AeroSpaceCLI.appBundleID, completion: { completion.record($0) })
        await scheduler.runAll()

        XCTAssertEqual(
            runner.invocations.map(\.arguments),
            [AeroSpaceCLI.listWindowsArguments()])
        XCTAssertEqual(completion.value, false)
    }

    func testUnparsableListWindowsOutputIsASilentNoOp() async {
        // Exit 0, but no parseable line for our bundle id.
        let runner = ScriptedRunner(
            script: Self.scriptAnsweringListWindows("12029 com.apple.Safari\n"))
        let scheduler = ManualScheduler()
        let floating = makeFloating(runner: runner, scheduler: scheduler)
        let completion = CompletionBox()

        floating.float(
            bundleID: AeroSpaceCLI.appBundleID, completion: { completion.record($0) })
        await scheduler.runAll()

        XCTAssertEqual(
            runner.invocations.map(\.arguments),
            [AeroSpaceCLI.listWindowsArguments()],
            "no matching bundle-id line → no layout command")
        XCTAssertEqual(completion.value, false)
    }

    func testAbsentAeroSpaceBinaryFiresNoCommands() async {
        let runner = ScriptedRunner { _ in .success }
        let scheduler = ManualScheduler()
        let floating = makeFloating(
            runner: runner, scheduler: scheduler, resolveExecutable: { nil })
        let floatCompletion = CompletionBox()
        let tileCompletion = CompletionBox()

        floating.float(
            bundleID: AeroSpaceCLI.appBundleID,
            completion: { floatCompletion.record($0) })
        floating.tile(
            bundleID: AeroSpaceCLI.appBundleID,
            completion: { tileCompletion.record($0) })
        await scheduler.runAll()

        XCTAssertTrue(
            runner.invocations.isEmpty,
            "aerospace absent → not even the resolution command fires")
        XCTAssertEqual(
            floatCompletion.value, false,
            "absent binary → immediate false completion (plain-setFrame path)")
        XCTAssertEqual(tileCompletion.value, false)
    }

    func testFailedLayoutWasAttemptedAndNeverThrows() async {
        // "If floating failed, tiling is still attempted on restore" —
        // and a failed layout itself never propagates: both invocations
        // happen, the flow just ends there.
        let runner = ScriptedRunner { arguments in
            arguments == AeroSpaceCLI.listWindowsArguments()
                ? AeroSpaceInvocationOutcome(
                    status: .exited(code: 0), stdout: Self.listWindowsOutput)
                : AeroSpaceInvocationOutcome(status: .exited(code: 1), stdout: "")
        }
        let scheduler = ManualScheduler()
        let floating = makeFloating(runner: runner, scheduler: scheduler)
        let completion = CompletionBox()

        floating.float(
            bundleID: AeroSpaceCLI.appBundleID, completion: { completion.record($0) })
        await scheduler.runAll()

        XCTAssertEqual(runner.invocations.count, 2, "the layout WAS attempted")
        XCTAssertEqual(
            runner.invocations.last?.arguments,
            ["layout", "--window-id", "4242", "floating"])
        XCTAssertEqual(
            completion.value, false,
            "the failed layout surfaces through the completion (amendment 2)")
    }

    // MARK: - The real Process runner (system binaries only)

    func testSystemRunnerCapturesStdoutAndZeroExit() async {
        let runner = SystemAeroSpaceProcessRunner()
        let outcome = await runner.run(
            URL(fileURLWithPath: "/bin/echo"), ["focus-tracker-44"])

        XCTAssertEqual(outcome.status, .exited(code: 0))
        XCTAssertEqual(outcome.stdout, "focus-tracker-44\n")
        XCTAssertTrue(outcome.isSuccess)
    }

    func testSystemRunnerSurfacesNonZeroExit() async {
        let outcome = await SystemAeroSpaceProcessRunner().run(
            URL(fileURLWithPath: "/usr/bin/false"), [])

        XCTAssertEqual(outcome.status, .exited(code: 1))
        XCTAssertFalse(outcome.isSuccess)
    }

    func testSystemRunnerReportsLaunchFailureForAMissingBinary() async {
        let outcome = await SystemAeroSpaceProcessRunner().run(
            URL(fileURLWithPath: "/nonexistent/aerospace-44"), ["list-windows"])

        XCTAssertEqual(outcome.status, .launchFailed)
        XCTAssertFalse(outcome.isSuccess)
    }

    func testSystemRunnerEnforcesItsDeadline() async {
        // 5 s of sleep under a 0.3 s deadline: the process is killed and
        // the invocation reports .timedOut — the cheap simulation of the
        // pinned 2 s production deadline.
        let runner = SystemAeroSpaceProcessRunner(timeout: 0.3)
        let outcome = await runner.run(URL(fileURLWithPath: "/bin/sleep"), ["5"])

        XCTAssertEqual(outcome.status, .timedOut)
        XCTAssertFalse(outcome.isSuccess)
    }
}
