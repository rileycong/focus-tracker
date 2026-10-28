import AppKit
import XCTest
@testable import FocusTracker

@MainActor
final class MiniTimerPresentationTests: XCTestCase {
    private let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

    /// The #44 AeroSpace seam double: records the edge fires (existing
    /// window-mechanics tests inject it purely to stay hermetic — no real
    /// aerospace subprocess in unit tests; the edge tests assert on its
    /// recordings). Set `observedWindow` to turn the double into an
    /// ORDERING probe: every call also records the window frame AS THE
    /// SEAM SAW IT — on ENTRY it must still be the FULL frame (the
    /// amendment 2 order: float fires BEFORE the shrink; the compact
    /// frame applies at the seam's completion), on EXIT it must still be
    /// the compact frame (tile→completion-restore).
    ///
    /// `completesInline` (default true) answers every request with an
    /// immediate successful completion — the synchronous semantics the
    /// #37-era tests observe through. Set it to false to capture the
    /// completions and fire them manually: the completion-gating probe
    /// (issue #44 amendment 2).
    @MainActor
    private final class RecordingFloating: CompactWindowFloating {
        weak var observedWindow: NSWindow?
        var completesInline = true
        private(set) var floatedBundleIDs: [String] = []
        private(set) var tiledBundleIDs: [String] = []
        private(set) var floatedFrames: [CGRect] = []
        private(set) var tiledFrames: [CGRect] = []
        private var pendingFloats: [@MainActor @Sendable (Bool) -> Void] = []
        private var pendingTiles: [@MainActor @Sendable (Bool) -> Void] = []

        func float(
            bundleID: String,
            completion: @escaping @MainActor @Sendable (Bool) -> Void
        ) {
            floatedBundleIDs.append(bundleID)
            floatedFrames.append(observedWindow?.frame ?? .zero)
            if completesInline {
                completion(true)
            } else {
                pendingFloats.append(completion)
            }
        }

        func tile(
            bundleID: String,
            completion: @escaping @MainActor @Sendable (Bool) -> Void
        ) {
            tiledBundleIDs.append(bundleID)
            tiledFrames.append(observedWindow?.frame ?? .zero)
            if completesInline {
                completion(true)
            } else {
                pendingTiles.append(completion)
            }
        }

        var hasPendingFloat: Bool { !pendingFloats.isEmpty }
        var hasPendingTile: Bool { !pendingTiles.isEmpty }

        func completeFloat(_ succeeded: Bool) {
            precondition(!pendingFloats.isEmpty, "no pending float completion")
            pendingFloats.removeFirst()(succeeded)
        }

        func completeTile(_ succeeded: Bool) {
            precondition(!pendingTiles.isEmpty, "no pending tile completion")
            pendingTiles.removeFirst()(succeeded)
        }
    }

    /// The amendment's no-op seam (criterion 3: AeroSpace-absent → plain
    /// setFrame): fires nothing, crashes nothing, changes nothing — and
    /// completes IMMEDIATELY with `false` (the degraded path), so the
    /// frame applies without waiting: plain setFrame.
    @MainActor
    private final class NoOpCompactFloating: CompactWindowFloating {
        func float(
            bundleID: String,
            completion: @escaping @MainActor @Sendable (Bool) -> Void
        ) {
            completion(false)
        }

        func tile(
            bundleID: String,
            completion: @escaping @MainActor @Sendable (Bool) -> Void
        ) {
            completion(false)
        }
    }

    /// Manual deferral scheduler: captures the controller's transition
    /// steps WITHOUT running them, so tests drive the production timing
    /// (the next main-queue tick, `NextTickMainWindowTransitionScheduler`)
    /// deterministically — nothing moves until the test pumps.
    @MainActor
    private final class QueuedTransitionScheduler: MainWindowTransitionScheduling {
        private(set) var pending: [@MainActor () -> Void] = []

        func schedule(_ transition: @MainActor @escaping () -> Void) {
            pending.append(transition)
        }

        func runNext() {
            precondition(!pending.isEmpty, "no deferred transition step")
            let next = pending.removeFirst()
            next()
        }

        func runAll() {
            while !pending.isEmpty { runNext() }
        }
    }

    private func makeNormalState() -> MainWindowPresentationState {
        MainWindowPresentationState(
            frame: CGRect(x: 180, y: 140, width: 860, height: 620),
            level: .normal,
            contentMinSize: CGSize(width: 640, height: 420),
            contentMaxSize: CGSize(width: 1600, height: 1200),
            collectionBehavior: [.managed],
            isMovableByWindowBackground: false)
    }

    private func makeWindow(from state: MainWindowPresentationState) -> NSWindow {
        let window = NSWindow(
            contentRect: state.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.level = state.level
        window.contentMinSize = state.contentMinSize
        window.contentMaxSize = state.contentMaxSize
        window.collectionBehavior = state.collectionBehavior
        window.isMovableByWindowBackground = state.isMovableByWindowBackground
        window.setFrame(state.frame, display: false)
        return window
    }

    /// The #44 amendment's compact-frame EXPECTATION, computed exactly as
    /// the controller: the 260×112 compact default content plus the
    /// window's own chrome, placed by the documented top-right rule
    /// (`MiniTimerWindowLayout.defaultTopRightFrame`) on the SAME screen
    /// expression the controller reads (`window.screen?.visibleFrame`,
    /// then `NSScreen.main`, then the 1440×900 headless estimate). Same
    /// expression + same synchronous tick ⇒ strict equality.
    private func expectedCompactWindowFrame(for window: NSWindow) -> CGRect {
        let chromeSize = CGSize(
            width: window.frame.width - window.contentLayoutRect.width,
            height: window.frame.height - window.contentLayoutRect.height)
        let compactWindowSize = CGSize(
            width: MiniTimerWindowLayout.contentSize.width + chromeSize.width,
            height: MiniTimerWindowLayout.contentSize.height + chromeSize.height)
        let visibleFrame = window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return MiniTimerWindowLayout.defaultTopRightFrame(
            visibleFrame: visibleFrame, contentSize: compactWindowSize)
    }

    func testCollapseKeepsWindowOnScreenAndBuildsCompactPresentation() {
        let normal = makeNormalState()
        let transition = MainWindowCompactTransition.collapse(
            from: normal, visibleFrame: visibleFrame)

        XCTAssertEqual(transition.visibilityAction, .keepOnScreen)
        XCTAssertEqual(transition.normal, normal)
        XCTAssertEqual(
            transition.compact.frame,
            MiniTimerWindowLayout.defaultTopRightFrame(visibleFrame: visibleFrame))
        XCTAssertEqual(transition.compact.level, .floating)
        XCTAssertEqual(transition.compact.contentMinSize, CGSize(width: 220, height: 104))
        XCTAssertEqual(transition.compact.contentMaxSize, CGSize(width: 520, height: 240))
        XCTAssertTrue(transition.compact.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(transition.compact.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(transition.compact.isMovableByWindowBackground)
    }

    func testRestoreRecoversEveryCapturedPresentationProperty() {
        let normal = makeNormalState()
        let transition = MainWindowCompactTransition.collapse(
            from: normal, visibleFrame: visibleFrame)

        XCTAssertEqual(transition.normal, normal)
    }

    func testThreeCyclesAndDuplicateRequestsAreStableOnSameWindow() {
        let expected = makeNormalState()
        let window = makeWindow(from: expected)
        let identity = window.windowNumber
        let windowCount = NSApp.windows.count
        let styleMask = window.styleMask
        let titleVisibility = window.titleVisibility
        let titlebarAppearsTransparent = window.titlebarAppearsTransparent
        let controller = MainWindowPresentationController(floating: RecordingFloating())
        controller.attach(window)

        for cycle in 1...3 {
            controller.setCompact(true)
            controller.setCompact(true)
            XCTAssertEqual(window.windowNumber, identity, "cycle \(cycle): identity")
            XCTAssertEqual(window.level, .floating, "cycle \(cycle): floating")
            XCTAssertEqual(
                window.contentLayoutRect.size, MiniTimerWindowLayout.contentSize,
                "cycle \(cycle): default compact content size")
            XCTAssertFalse(window.isMiniaturized, "cycle \(cycle): never minimized")
            XCTAssertEqual(window.styleMask, styleMask, "cycle \(cycle): style ownership")
            XCTAssertEqual(window.titleVisibility, titleVisibility, "cycle \(cycle): title")
            XCTAssertEqual(
                window.titlebarAppearsTransparent, titlebarAppearsTransparent,
                "cycle \(cycle): titlebar ownership")

            controller.setCompact(false)
            controller.setCompact(false)
            XCTAssertEqual(
                MainWindowPresentationState.capture(window), expected,
                "cycle \(cycle): exact restore")
        }

        XCTAssertEqual(NSApp.windows.count, windowCount, "no panel or second window created")
    }

    func testCompactTransitionNeverMutatesSwiftUIWindowStyleOrTitlebar() {
        let window = makeWindow(from: makeNormalState())
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        let styleMask = window.styleMask
        let controller = MainWindowPresentationController(floating: RecordingFloating())
        controller.attach(window)

        controller.setCompact(true)
        controller.setCompact(false)

        XCTAssertEqual(window.styleMask, styleMask)
        XCTAssertEqual(window.titleVisibility, .visible)
        XCTAssertFalse(window.titlebarAppearsTransparent)
    }

    func testEndFromMiniRestoresNormalPresentation() {
        let expected = makeNormalState()
        let window = makeWindow(from: expected)
        let controller = MainWindowPresentationController(floating: RecordingFloating())
        controller.attach(window)
        controller.setCompact(true)

        // End clears the model flag; the shell delivers the same explicit
        // non-compact request as Restore.
        controller.setCompact(false)

        XCTAssertEqual(MainWindowPresentationState.capture(window), expected)
    }

    func testShellMiniFlagSelectsMiniContentWithoutChangingPhase() {
        let context = AppModel.SessionContext(
            taskID: UUID(), title: "Task", parentTaskTitle: nil,
            project: nil, categories: [])
        let phase = AppModel.AppPhase.timerView(context)

        XCTAssertEqual(
            AppShellContent.resolve(phase: phase, isMiniTimerActive: false),
            .fullTimer)
        XCTAssertEqual(
            AppShellContent.resolve(phase: phase, isMiniTimerActive: true),
            .miniTimer)
        XCTAssertEqual(
            AppShellContent.resolve(phase: .tasksView, isMiniTimerActive: true),
            .other)
    }

    // MARK: - Break variant (issue #43)

    func testShellBreakFlagSelectsMiniBreakContentWithoutChangingPhase() {
        XCTAssertEqual(
            AppShellContent.resolve(
                phase: .breakActive, isMiniTimerActive: false, isMiniBreakActive: true),
            .miniBreak)
        XCTAssertEqual(
            AppShellContent.resolve(
                phase: .breakActive, isMiniTimerActive: false, isMiniBreakActive: false),
            .other)
        // The two lifecycles' flags never cross: a (stale) session flag
        // must not compact the break screen, nor the break flag any other
        // phase.
        XCTAssertEqual(
            AppShellContent.resolve(
                phase: .breakActive, isMiniTimerActive: true, isMiniBreakActive: false),
            .other)
        XCTAssertEqual(
            AppShellContent.resolve(
                phase: .tasksView, isMiniTimerActive: false, isMiniBreakActive: true),
            .other)
    }

    func testResolvedCompactContentsDriveCompactPresentation() {
        // The ONE bit the shell keys its frame min/max and setCompact
        // request off (issue #43): either mini variant is compact, the full
        // timer and every other resolution are not.
        XCTAssertTrue(
            AppShellContent.resolve(
                phase: .breakActive, isMiniTimerActive: false, isMiniBreakActive: true)
                .isCompact)
        let context = AppModel.SessionContext(
            taskID: UUID(), title: "Task", parentTaskTitle: nil,
            project: nil, categories: [])
        XCTAssertTrue(
            AppShellContent.resolve(
                phase: .timerView(context), isMiniTimerActive: true)
                .isCompact)
        XCTAssertFalse(
            AppShellContent.resolve(
                phase: .breakActive, isMiniTimerActive: false, isMiniBreakActive: false)
                .isCompact)
        XCTAssertFalse(
            AppShellContent.resolve(
                phase: .timerView(context), isMiniTimerActive: false)
                .isCompact)
        XCTAssertFalse(
            AppShellContent.resolve(phase: .tasksView, isMiniTimerActive: false).isCompact)
    }

    func testThreeBreakCollapseCyclesOnSameWindowNeverHideOrRestyle() {
        let expected = makeNormalState()
        let window = makeWindow(from: expected)
        // The "never hidden" invariant needs a VISIBLE starting window:
        // order it front once (the controller must then never order it out,
        // miniaturize, close or hide it across the cycles).
        window.orderFrontRegardless()
        XCTAssertTrue(window.isVisible, "precondition: the window starts visible")
        let identity = window.windowNumber
        let windowCount = NSApp.windows.count
        let styleMask = window.styleMask
        let titleVisibility = window.titleVisibility
        let titlebarAppearsTransparent = window.titlebarAppearsTransparent
        let controller = MainWindowPresentationController(floating: RecordingFloating())
        controller.attach(window)

        for cycle in 1...3 {
            // The shell derives the compact request from the RESOLVED break
            // content — the same observable-driven sync FocusTrackerApp
            // runs on `isMiniBreakActive`/phase changes (issue #43).
            controller.setCompact(
                AppShellContent.resolve(
                    phase: .breakActive,
                    isMiniTimerActive: false,
                    isMiniBreakActive: true).isCompact)
            controller.setCompact(true)
            XCTAssertEqual(window.windowNumber, identity, "cycle \(cycle): identity")
            XCTAssertEqual(window.level, .floating, "cycle \(cycle): floating")
            XCTAssertEqual(
                window.contentLayoutRect.size, MiniTimerWindowLayout.contentSize,
                "cycle \(cycle): default compact content size")
            XCTAssertFalse(window.isMiniaturized, "cycle \(cycle): never minimized")
            XCTAssertTrue(window.isVisible, "cycle \(cycle): never hidden (no orderOut/close/hide)")
            XCTAssertEqual(window.styleMask, styleMask, "cycle \(cycle): style ownership")
            XCTAssertEqual(window.titleVisibility, titleVisibility, "cycle \(cycle): title")
            XCTAssertEqual(
                window.titlebarAppearsTransparent, titlebarAppearsTransparent,
                "cycle \(cycle): titlebar ownership")

            controller.setCompact(
                AppShellContent.resolve(
                    phase: .breakActive,
                    isMiniTimerActive: false,
                    isMiniBreakActive: false).isCompact)
            controller.setCompact(false)
            XCTAssertEqual(
                MainWindowPresentationState.capture(window), expected,
                "cycle \(cycle): exact restore")
            XCTAssertTrue(window.isVisible, "cycle \(cycle): still visible after restore")
        }

        XCTAssertEqual(NSApp.windows.count, windowCount, "no panel or second window created")
    }

    func testEndBreakFromCompactRestoresNormalPresentationWithoutHiding() {
        let expected = makeNormalState()
        let window = makeWindow(from: expected)
        window.orderFrontRegardless()
        XCTAssertTrue(window.isVisible, "precondition: the window starts visible")
        let identity = window.windowNumber
        let controller = MainWindowPresentationController(floating: RecordingFloating())
        controller.attach(window)
        controller.setCompact(true)

        // endBreak clears the model flag on EVERY outcome (issue #43); the
        // shell's resolve then delivers the same explicit non-compact
        // request as Restore — the session-mini precedent, mirrored.
        controller.setCompact(
            AppShellContent.resolve(
                phase: .sessionStart,
                isMiniTimerActive: false,
                isMiniBreakActive: false).isCompact)

        XCTAssertEqual(MainWindowPresentationState.capture(window), expected)
        XCTAssertEqual(window.windowNumber, identity, "same window throughout")
        XCTAssertTrue(window.isVisible, "the break end never hides the window")
    }

    // MARK: - AeroSpace seam wiring (issue #44)

    func testCompactTransitionsFireTheFloatingSeamOncePerEdge() {
        let window = makeWindow(from: makeNormalState())
        let spy = RecordingFloating()
        let controller = MainWindowPresentationController(floating: spy)
        controller.attach(window)

        // Entry edge: fired once even though reconcile runs per duplicate
        // request (fire-once-per-edge, not per reconcile).
        controller.setCompact(true)
        controller.setCompact(true)
        XCTAssertEqual(spy.floatedBundleIDs, [AeroSpaceCLI.appBundleID])
        XCTAssertTrue(spy.tiledBundleIDs.isEmpty)

        // Exit edge: same discipline on the way back to full mode.
        controller.setCompact(false)
        controller.setCompact(false)
        XCTAssertEqual(spy.floatedBundleIDs, [AeroSpaceCLI.appBundleID])
        XCTAssertEqual(spy.tiledBundleIDs, [AeroSpaceCLI.appBundleID])

        // The break variant (#43) drives the SAME phase-agnostic edges
        // through the shell's resolved compact bit — it inherits the
        // floating behavior with no wiring of its own.
        controller.setCompact(
            AppShellContent.resolve(
                phase: .breakActive, isMiniTimerActive: false, isMiniBreakActive: true)
                .isCompact)
        controller.setCompact(
            AppShellContent.resolve(
                phase: .breakActive, isMiniTimerActive: false, isMiniBreakActive: false)
                .isCompact)
        XCTAssertEqual(spy.floatedBundleIDs.count, 2, "second cycle: one more float")
        XCTAssertEqual(spy.tiledBundleIDs.count, 2, "second cycle: one more tile")
    }

    func testFloatingSeamStaysSilentWithoutActualTransitions() {
        let window = makeWindow(from: makeNormalState())
        let spy = RecordingFloating()
        let controller = MainWindowPresentationController(floating: spy)

        // Attach alone fires nothing (the window starts in normal mode)…
        controller.attach(window)
        // …and neither do non-compact reconciles: there is no edge.
        controller.setCompact(false)
        controller.setCompact(false)

        XCTAssertTrue(spy.floatedBundleIDs.isEmpty)
        XCTAssertTrue(spy.tiledBundleIDs.isEmpty)
    }

    func testReattachWhileCompactRequestedReFiresFloatForTheNewWindow() {
        let window = makeWindow(from: makeNormalState())
        let spy = RecordingFloating()
        let controller = MainWindowPresentationController(floating: spy)
        controller.attach(window)
        controller.setCompact(true)
        XCTAssertEqual(spy.floatedBundleIDs.count, 1)

        // A scene-driven window replacement re-enters the compact edge
        // (the captured normal presentation resets on attach) — correct,
        // because the new window has a NEW AeroSpace window id and must
        // be floated on its own.
        let replacement = makeWindow(from: makeNormalState())
        controller.attach(replacement)
        XCTAssertEqual(spy.floatedBundleIDs.count, 2)
        XCTAssertEqual(replacement.level, .floating, "the replacement is compacted")
        XCTAssertEqual(spy.tiledBundleIDs.count, 0)
    }

    // MARK: - #44 amendment 2: float-first shrink + completion-gated frames

    func testCompactEntryFloatsWhileFullThenShrinksAtTheSeamCompletion() {
        let expected = makeNormalState()
        let window = makeWindow(from: expected)
        let spy = RecordingFloating()
        spy.observedWindow = window
        let controller = MainWindowPresentationController(floating: spy)
        controller.attach(window)

        // ENTER (amendment 2 order — per the live diagnosis): the #44
        // float fires FIRST, while the window is still FULL — a live
        // AeroSpace re-asserts tile geometry over ANY frame set on a
        // still-TILED window (measured: AX-API overrides ~16 ms after
        // our setFrame, twice), so the shrink must wait until the window
        // is OUT of the tiling tree. The inline-completing double
        // delivers the completion synchronously, so the compact frame
        // applies within the same step here.
        controller.setCompact(true)

        XCTAssertEqual(spy.floatedBundleIDs, [AeroSpaceCLI.appBundleID])
        XCTAssertEqual(
            spy.floatedFrames, [expected.frame],
            "float fired while the window was STILL FULL (float→shrink, the amendment 2 order)")
        XCTAssertEqual(
            window.contentLayoutRect.size, MiniTimerWindowLayout.contentSize,
            "the window AUTO-SHRINKS to the 260×112 compact default at the completion — the amendment's core complaint")
        XCTAssertEqual(
            window.frame, expectedCompactWindowFrame(for: window),
            "compact frame: EXACTLY the documented default, origin + size")
        XCTAssertTrue(spy.tiledBundleIDs.isEmpty)
    }

    func testEntryAppliesTheCompactFrameOnlyAfterTheFloatCompletes() {
        // THE amendment 2 gating contract, driven manually: the float
        // fires and the window DOES NOT MOVE until the seam completes —
        // the mechanism that beats the tiling engine's 16 ms override
        // (our frame lands only once the window is floating).
        let expected = makeNormalState()
        let window = makeWindow(from: expected)
        let spy = RecordingFloating()
        spy.completesInline = false
        let controller = MainWindowPresentationController(floating: spy)
        controller.attach(window)

        controller.setCompact(true)
        XCTAssertEqual(spy.floatedBundleIDs, [AeroSpaceCLI.appBundleID])
        XCTAssertEqual(
            window.frame, expected.frame,
            "the shrink WAITS for the float completion — nothing moves yet")

        spy.completeFloat(true)
        XCTAssertEqual(
            window.frame, expectedCompactWindowFrame(for: window),
            "the compact frame applies at the completion")
        XCTAssertEqual(
            window.contentLayoutRect.size, MiniTimerWindowLayout.contentSize)
    }

    func testFailedFloatCompletionStillAppliesTheCompactFrame() {
        // The degraded seam (binary absent / server down / timeout)
        // completes with false and the frame applies anyway — the
        // AeroSpace-absent plain-setFrame behavior, through the
        // completion path.
        let window = makeWindow(from: makeNormalState())
        let spy = RecordingFloating()
        spy.completesInline = false
        let controller = MainWindowPresentationController(floating: spy)
        controller.attach(window)

        controller.setCompact(true)
        spy.completeFloat(false)
        XCTAssertEqual(
            window.frame, expectedCompactWindowFrame(for: window),
            "a degraded float (false completion) still shrinks the window")
    }

    func testStaleCompletionNeverMovesTheWindow() {
        // The generation guard: a rapid collapse→restore flutter leaves
        // the entry's float completion pending; once the exit has
        // completed, the LATE float completion must be a no-op — it can
        // never re-compact the restored window.
        let expected = makeNormalState()
        let window = makeWindow(from: expected)
        let spy = RecordingFloating()
        spy.completesInline = false
        let controller = MainWindowPresentationController(floating: spy)
        controller.attach(window)

        controller.setCompact(true)
        controller.setCompact(false)
        XCTAssertTrue(spy.hasPendingFloat, "entry float completion pending")
        XCTAssertTrue(spy.hasPendingTile, "exit tile completion pending")

        spy.completeTile(true)
        XCTAssertEqual(
            MainWindowPresentationState.capture(window), expected,
            "the exit completion restored the saved full frame")

        spy.completeFloat(true)
        XCTAssertEqual(
            MainWindowPresentationState.capture(window), expected,
            "the STALE entry completion is a no-op — the window stays restored")
    }

    func testExitTilesSeamFirstThenRestoresSavedFrameExactly() {
        let expected = makeNormalState()
        let window = makeWindow(from: expected)
        let spy = RecordingFloating()
        spy.observedWindow = window
        let controller = MainWindowPresentationController(floating: spy)
        controller.attach(window)
        controller.setCompact(true)
        let compactFrame = expectedCompactWindowFrame(for: window)

        // EXIT (amendment 2): the #44 tiling seam fires FIRST — the
        // window is STILL at the compact frame when it does — and the
        // saved FULL frame applies in the seam's completion, AFTER the
        // tiling engine has re-placed the window (the amendment 1
        // immediate restore measurably lost that race: the re-tile
        // landed after it and drifted the window across tiles).
        controller.setCompact(false)

        XCTAssertEqual(
            spy.tiledFrames, [compactFrame],
            "tile observed the STILL-COMPACT window (tile→completion-restore, pinned order)")
        XCTAssertEqual(
            MainWindowPresentationState.capture(window), expected,
            "the saved full frame (origin + size) restored EXACTLY at the completion")
        XCTAssertEqual(spy.floatedBundleIDs, [AeroSpaceCLI.appBundleID])
    }

    func testExitRestoresOnlyAfterTheTileCompletes() {
        let expected = makeNormalState()
        let window = makeWindow(from: expected)
        let spy = RecordingFloating()
        spy.completesInline = false
        let controller = MainWindowPresentationController(floating: spy)
        controller.attach(window)
        controller.setCompact(true)
        spy.completeFloat(true)
        let compactFrame = window.frame

        // The restore WAITS for the tile completion — the mirror of the
        // entry gating.
        controller.setCompact(false)
        XCTAssertEqual(spy.tiledBundleIDs, [AeroSpaceCLI.appBundleID])
        XCTAssertEqual(
            window.frame, compactFrame,
            "the window stays compact until the tile completes")

        spy.completeTile(true)
        XCTAssertEqual(
            MainWindowPresentationState.capture(window), expected,
            "the exact saved full frame applies at the tile completion")
    }

    func testSavedFrameRoundTripIsExactForThreeCyclesWithSeamOrdering() {
        let expected = makeNormalState()
        let window = makeWindow(from: expected)
        let spy = RecordingFloating()
        spy.observedWindow = window
        let controller = MainWindowPresentationController(floating: spy)
        controller.attach(window)

        for cycle in 1...3 {
            controller.setCompact(true)
            XCTAssertEqual(
                spy.floatedFrames.last, expected.frame,
                "cycle \(cycle): float fired while the window was FULL (float→shrink)")
            XCTAssertEqual(
                window.frame, expectedCompactWindowFrame(for: window),
                "cycle \(cycle): compact default at the completion — EXACT origin + size")
            XCTAssertEqual(
                window.contentLayoutRect.size, MiniTimerWindowLayout.contentSize,
                "cycle \(cycle): 260×112 content")

            controller.setCompact(false)
            XCTAssertEqual(
                spy.tiledFrames.last, expectedCompactWindowFrame(for: window),
                "cycle \(cycle): tile fired while the window was STILL COMPACT")
            XCTAssertEqual(
                MainWindowPresentationState.capture(window), expected,
                "cycle \(cycle): saved full frame (origin + size) survives the round trip EXACTLY")
        }

        XCTAssertEqual(spy.floatedBundleIDs.count, 3, "one float per ACTUAL entry edge")
        XCTAssertEqual(spy.tiledBundleIDs.count, 3, "one tile per ACTUAL exit edge")
    }

    func testAeroSpaceAbsentSeamLeavesPlainSetFrameFlutterRoundTrip() {
        // Criterion 3's AeroSpace-absent clause: the degraded seam
        // completes IMMEDIATELY with false, so the transitions are PLAIN
        // setFrame — the geometry contract is untouched. Uses the
        // flutter shape (both edges queued before either runs) with the
        // production deferral timing, 3 cycles: the saved frame still
        // comes back EXACTLY.
        let expected = makeNormalState()
        let window = makeWindow(from: expected)
        let scheduler = QueuedTransitionScheduler()
        let controller = MainWindowPresentationController(
            floating: NoOpCompactFloating(), transitionScheduler: scheduler)
        controller.attach(window)

        for cycle in 1...3 {
            controller.setCompact(true)
            controller.setCompact(false)
            scheduler.runNext()
            XCTAssertEqual(
                window.frame, expectedCompactWindowFrame(for: window),
                "cycle \(cycle): the compact setFrame held")
            XCTAssertEqual(
                window.contentLayoutRect.size, MiniTimerWindowLayout.contentSize,
                "cycle \(cycle): 260×112 content")
            scheduler.runNext()
            XCTAssertEqual(
                MainWindowPresentationState.capture(window), expected,
                "cycle \(cycle): the saved frame survived the flutter EXACTLY")
        }
    }

    func testDeferredTransitionWaitsForTheSwiftUITransactionAndKeepsOrder() {
        // The production timing (next-tick scheduler) locked with a
        // MANUAL seam double: NOTHING moves before the tick; the tick
        // fires the float (window still full); the completion applies
        // the compact frame; the exit's tile waits for its own tick and
        // its completion restores the saved frame exactly — the pinned
        // amendment 2 order survives the hop.
        let expected = makeNormalState()
        let window = makeWindow(from: expected)
        let spy = RecordingFloating()
        spy.observedWindow = window
        spy.completesInline = false
        let scheduler = QueuedTransitionScheduler()
        let controller = MainWindowPresentationController(
            floating: spy, transitionScheduler: scheduler)
        controller.attach(window)

        controller.setCompact(true)
        XCTAssertEqual(window.frame, expected.frame, "nothing moves before the tick")
        XCTAssertTrue(spy.floatedBundleIDs.isEmpty, "the seam fires inside the deferred step — not before")

        scheduler.runNext()
        XCTAssertEqual(
            spy.floatedBundleIDs, [AeroSpaceCLI.appBundleID],
            "the tick fires the float")
        XCTAssertEqual(
            spy.floatedFrames, [expected.frame],
            "the float fired while the window was STILL FULL")
        XCTAssertEqual(
            window.frame, expected.frame,
            "the shrink waits for the float completion — still nothing moved")

        spy.completeFloat(true)
        XCTAssertEqual(
            window.frame, expectedCompactWindowFrame(for: window),
            "the compact default applied at the completion")
        XCTAssertEqual(
            window.contentLayoutRect.size, MiniTimerWindowLayout.contentSize)

        controller.setCompact(false)
        XCTAssertEqual(
            window.frame, expectedCompactWindowFrame(for: window),
            "the restore waits for its own tick")
        XCTAssertTrue(spy.tiledBundleIDs.isEmpty)

        scheduler.runNext()
        XCTAssertEqual(
            spy.tiledFrames, [expectedCompactWindowFrame(for: window)],
            "tile fired FIRST (window still compact)")
        XCTAssertEqual(
            window.frame, expectedCompactWindowFrame(for: window),
            "the restore waits for the tile completion")

        spy.completeTile(true)
        XCTAssertEqual(
            MainWindowPresentationState.capture(window), expected,
            "exact saved-frame restore at the completion")
    }

    func testDeferredEdgesRunInScheduleOrderSoFlutterSelfHeals() {
        // Three setCompact flips inside ONE SwiftUI-scale window: the
        // queued steps run FIFO — compact, restore, compact — and the
        // final state + the NEXT saved-frame round trip are both exact
        // (no state leaks between a superseded edge and its successor;
        // the inline-completing double resolves every completion inside
        // its own step, so the generation guard never kicks in here).
        let expected = makeNormalState()
        let window = makeWindow(from: expected)
        let spy = RecordingFloating()
        let scheduler = QueuedTransitionScheduler()
        let controller = MainWindowPresentationController(
            floating: spy, transitionScheduler: scheduler)
        controller.attach(window)

        controller.setCompact(true)
        controller.setCompact(false)
        controller.setCompact(true)
        scheduler.runAll()

        XCTAssertEqual(spy.floatedBundleIDs.count, 2, "two ENTRY edges, two floats")
        XCTAssertEqual(spy.tiledBundleIDs.count, 1, "one EXIT edge, one tile")
        XCTAssertEqual(
            window.frame, expectedCompactWindowFrame(for: window),
            "the LAST scheduled edge wins: the window is compact")
        XCTAssertEqual(
            window.contentLayoutRect.size, MiniTimerWindowLayout.contentSize)

        // And the saved frame STILL round-trips exactly afterwards.
        controller.setCompact(false)
        scheduler.runNext()
        XCTAssertEqual(MainWindowPresentationState.capture(window), expected)
    }

    func testBreakCompactEdgesCarryTheSameFrameOrdering() {
        // Criterion 1's "focus OR break — the transition is window-level":
        // the #43 break variant drives the SAME controller edges, so it
        // inherits BOTH the completion-gated shrink AND the pinned seam
        // orderings with no wiring of its own.
        let expected = makeNormalState()
        let window = makeWindow(from: expected)
        let spy = RecordingFloating()
        spy.observedWindow = window
        let controller = MainWindowPresentationController(floating: spy)
        controller.attach(window)

        controller.setCompact(
            AppShellContent.resolve(
                phase: .breakActive, isMiniTimerActive: false, isMiniBreakActive: true)
                .isCompact)
        XCTAssertEqual(
            spy.floatedFrames.last, expected.frame,
            "break ENTRY: the float fired while the window was FULL")
        XCTAssertEqual(
            window.contentLayoutRect.size, MiniTimerWindowLayout.contentSize,
            "break compact: the window AUTO-SHRINKS to the 260×112 default at the completion")
        XCTAssertEqual(
            window.frame, expectedCompactWindowFrame(for: window))

        controller.setCompact(
            AppShellContent.resolve(
                phase: .breakActive, isMiniTimerActive: false, isMiniBreakActive: false)
                .isCompact)
        XCTAssertEqual(
            spy.tiledFrames.last, expectedCompactWindowFrame(for: window),
            "break EXIT: tile fired while STILL COMPACT, then the completion restore")
        XCTAssertEqual(
            MainWindowPresentationState.capture(window), expected,
            "break EXIT: the saved full frame restored EXACTLY")
    }
}
