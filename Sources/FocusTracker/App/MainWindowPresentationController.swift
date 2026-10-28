import AppKit
import SwiftUI

enum MiniTimerWindowLayout {
    static let contentSize = CGSize(width: 260, height: 112)
    static let contentMinSize = CGSize(width: 220, height: 104)
    static let contentMaxSize = CGSize(width: 520, height: 240)
    static let countdownMinFontSize: CGFloat = 22
    static let countdownMaxFontSize: CGFloat = 44
    static let screenMargin: CGFloat = 16

    static func clampedContentSize(_ size: CGSize) -> CGSize {
        CGSize(
            width: min(max(size.width, contentMinSize.width), contentMaxSize.width),
            height: min(max(size.height, contentMinSize.height), contentMaxSize.height))
    }

    static func countdownFontSize(forContentSize size: CGSize) -> CGFloat {
        let base = DesignTokens.miniCountdownSize
        let height = clampedContentSize(size).height
        if height <= contentSize.height {
            let span = contentSize.height - contentMinSize.height
            guard span > 0 else { return base }
            return base - (base - countdownMinFontSize)
                * ((contentSize.height - height) / span)
        }
        let span = contentMaxSize.height - contentSize.height
        guard span > 0 else { return base }
        return base + (countdownMaxFontSize - base)
            * ((height - contentSize.height) / span)
    }

    /// The compact window's placement rule (issue #44 amendment): 16pt
    /// inset from the TOP-RIGHT corner of the current screen's VISIBLE
    /// frame — `NSScreen.visibleFrame` already excludes the menu bar and
    /// the Dock, so the mini window hugs the screen's top-right corner
    /// without covering either. The screen comes from
    /// `window.screen?.visibleFrame` at the ENTRY edge (the screen the
    /// window occupied in full mode), falling back to `NSScreen.main` and
    /// finally a 1440×900 headless estimate — the composition in
    /// `MainWindowPresentationController.reconcile`.
    static func defaultTopRightFrame(
        visibleFrame: CGRect,
        contentSize: CGSize = Self.contentSize,
        margin: CGFloat = Self.screenMargin
    ) -> CGRect {
        CGRect(
            x: max(visibleFrame.minX + margin, visibleFrame.maxX - contentSize.width - margin),
            y: max(visibleFrame.minY + margin, visibleFrame.maxY - contentSize.height - margin),
            width: contentSize.width,
            height: contentSize.height)
    }
}

// MARK: - Transition deferral (issue #44 amendment)

/// Schedules the controller's transition steps (the seam firing). The
/// SwiftUI transaction that flips the compact request also runs its own
/// window-geometry pass — the TimerView→MiniTimerView content switch
/// plus the shell's `.frame(min/ideal/max)` bounds (FocusTrackerApp) —
/// so the controller stays ONE main-queue tick behind it: the step
/// fires only after the transaction's view diff and constraint sync
/// have settled, and the window-frame writes themselves happen later
/// still, at the seam's completion (see the controller's amendment 2
/// documentation for the measured AeroSpace race). Production hops one
/// tick; tests keep the #37 synchronous semantics with the inline
/// scheduler.
@MainActor
protocol MainWindowTransitionScheduling: AnyObject {
    func schedule(_ transition: @MainActor @escaping () -> Void)
}

/// Runs the transition inline. The default so every #37- and #44-era
/// reconcile stays synchronous — existing tests observe the window
/// immediately after `setCompact` (with a seam double that completes
/// inline), and the pinned orderings stay assertable without a runloop
/// pump.
@MainActor
final class ImmediateMainWindowTransitionScheduler: MainWindowTransitionScheduling {
    func schedule(_ transition: @MainActor @escaping () -> Void) { transition() }
}

/// Production: ONE hop to the next main-queue turn — the earliest point
/// where the SwiftUI transaction that flipped the compact request (its
/// view diff, its constraint sync, its window-geometry pass) has fully
/// settled. The main queue IS the main actor's queue, hence
/// `assumeIsolated`.
@MainActor
final class NextTickMainWindowTransitionScheduler: MainWindowTransitionScheduling {
    func schedule(_ transition: @MainActor @escaping () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated(transition) }
    }
}

/// Only properties safe to change on a SwiftUI-owned window at runtime.
struct MainWindowPresentationState: Equatable {
    var frame: CGRect
    var level: NSWindow.Level
    var contentMinSize: CGSize
    var contentMaxSize: CGSize
    var collectionBehavior: NSWindow.CollectionBehavior
    var isMovableByWindowBackground: Bool

    @MainActor
    static func capture(_ window: NSWindow) -> Self {
        Self(
            frame: window.frame,
            level: window.level,
            contentMinSize: window.contentMinSize,
            contentMaxSize: window.contentMaxSize,
            collectionBehavior: window.collectionBehavior,
            isMovableByWindowBackground: window.isMovableByWindowBackground)
    }
}

enum MainWindowVisibilityAction: Equatable {
    case keepOnScreen
}

struct MainWindowCompactTransition: Equatable {
    let normal: MainWindowPresentationState
    let compact: MainWindowPresentationState
    let visibilityAction: MainWindowVisibilityAction

    static func collapse(
        from normal: MainWindowPresentationState,
        visibleFrame: CGRect
    ) -> Self {
        var compact = normal
        compact.frame = MiniTimerWindowLayout.defaultTopRightFrame(visibleFrame: visibleFrame)
        compact.level = .floating
        compact.contentMinSize = MiniTimerWindowLayout.contentMinSize
        compact.contentMaxSize = MiniTimerWindowLayout.contentMaxSize
        compact.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
        compact.isMovableByWindowBackground = true
        return Self(normal: normal, compact: compact, visibilityAction: .keepOnScreen)
    }
}

/// Reconfigures the existing SwiftUI scene window in place. No `NSPanel` or
/// other `NSWindow` is created. Unlike the old swap, this path never orders
/// out, miniaturizes, closes, or hides the app window. The reliability tradeoff
/// is deliberate: because compact mode is the main window, clicking it may
/// activate the app. It never changes the scene-owned window's style mask or
/// titlebar ownership; those remain fixed for the app's lifetime.
///
/// Issue #44 adds the AeroSpace float/tile seam on the two compact
/// transition edges: normal→compact fires `CompactWindowFloating.float`
/// once, compact→normal fires `tile` once — fire-once-per-edge, never per
/// reconcile, and always best-effort (the seam never blocks or fails the
/// window transition). Because this controller is phase-agnostic, both
/// compact kinds (the session mini #37 and the break mini #43) inherit
/// the floating behavior automatically.
///
/// Issue #44 amendment (user re-test follow-up): the two compact edges
/// own the WINDOW FRAME as well. Amendment 1 pinned ENTRY =
/// setFrame→float / EXIT = tile→setFrame, each deferred one tick — and
/// the unit tests (injected scheduler, no live window manager) passed,
/// while the user's real app still never shrank.
///
/// Issue #44 amendment 2 — the LIVE diagnosis (real binary, real
/// AeroSpace 0.21.3-Beta, `-autoCollapseDemo` with a didResize callstack
/// probe) found the actual override: our deferred setFrame DID land
/// (260×144, top-right), then AeroSpace's TILING ENGINE re-asserted the
/// window's tile geometry TWICE within 40 ms — through the ACCESSIBILITY
/// API (`NSAccessibilityEntryPointSetValueForAttribute` ←
/// `_AXXMIGSetAttributeValue`, i.e. an external AX client writing our
/// window's frame) — because the window was still AeroSpace-TILED at
/// that moment; our `layout … floating` subprocess completed only
/// ~100–150 ms later and floating does not resize. SwiftUI appeared in
/// ZERO override stacks: the amendment 1 "SwiftUI re-asserts the
/// autosave" theory mis-attributed the AeroSpace tile (1147×1408, which
/// the autosave had merely recorded) to SwiftUI. The mirror race hit
/// EXIT too: the tile subprocess completed AFTER our restore setFrame,
/// and AeroSpace's re-tiling moved the window across tiles — by cycle 3
/// off-screen (3439, −1376).
///
/// The fix is therefore COMPLETION-GATED ORDER (the opposite entry order
/// from amendment 1, per the evidence): ENTRY — fire the #44 float
/// FIRST, and apply the compact presentation + frame in the seam's
/// COMPLETION, once the window is OUT of the tiling tree (a floating
/// window's geometry is never overridden); EXIT — fire the #44 tile
/// FIRST, and apply the saved-full-frame restore in its COMPLETION, so
/// our restore is the last geometry writer (a manual resize of a tiled
/// window reshapes the tree around it — respected). A degraded seam
/// (binary absent, server down, timeout — bounded by the pinned 2 s
/// deadline) completes with `false` and the frame applies anyway: plain
/// `setFrame`, the AeroSpace-absent behavior, unchanged. The full frame
/// is still captured SYNCHRONOUSLY at the ENTRY edge (before anything
/// moves) and restored exactly; a GENERATION token guards the
/// completions, so a stale edge's late completion (a rapid
/// collapse→restore→collapse flutter) can never move the window.
/// Driving the shrink through a SwiftUI fixed `.frame(260×112)` was
/// considered and rejected on the same evidence: the AX writer overrides
/// ANY frame change while the window is tiled (SwiftUI-driven included),
/// and a fixed frame would pin min=max, breaking the #37 resizable
/// compact window (220–520×104–240) the user re-tested as working.
@MainActor
final class MainWindowPresentationController {
    private weak var window: NSWindow?
    private var normalPresentation: MainWindowPresentationState?
    private var compactRequested = false
    private let floating: any CompactWindowFloating
    private let transitionScheduler: any MainWindowTransitionScheduling
    /// Increments on every scheduled edge; a completion applies geometry
    /// only while its captured token is still current — the stale-
    /// completion guard (issue #44 amendment 2).
    private var transitionGeneration = 0

    /// - Parameters:
    ///   - floating: The #44 AeroSpace seam. Defaults to the production
    ///     shell-out; tests inject a spy or no-op.
    ///   - transitionScheduler: The #44 amendment deferral. Defaults to
    ///     the inline scheduler (#37 synchronous semantics — existing
    ///     tests rely on it); production passes the next-tick scheduler
    ///     (FocusTrackerApp) so the seam fires after the SwiftUI
    ///     transaction's own geometry pass.
    init(
        floating: any CompactWindowFloating = AeroSpaceCompactWindowFloating(),
        transitionScheduler: any MainWindowTransitionScheduling =
            ImmediateMainWindowTransitionScheduler()
    ) {
        self.floating = floating
        self.transitionScheduler = transitionScheduler
    }

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        normalPresentation = nil
        reconcile()
    }

    func setCompact(_ compact: Bool) {
        compactRequested = compact
        reconcile()
    }

    private func reconcile() {
        guard let window else { return }
        if compactRequested {
            guard normalPresentation == nil else { return }
            // Saved SYNCHRONOUSLY, before anything moves: origin + size of
            // the full presentation as the user last saw it — the exact
            // round-trip target (issue #44 amendment criterion 3).
            let normal = MainWindowPresentationState.capture(window)
            normalPresentation = normal
            let visibleFrame = window.screen?.visibleFrame
                ?? NSScreen.main?.visibleFrame
                ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            let transition = MainWindowCompactTransition.collapse(
                from: normal, visibleFrame: visibleFrame)
            // The #44 amendment 2 ENTRY edge: fire the #44 float FIRST —
            // while the window is AeroSpace-tiled, ANY frame write is
            // re-asserted by the tiling engine within milliseconds (the
            // measured AX override), so the compact presentation + frame
            // apply in the seam's COMPLETION, once the window is OUT of
            // the tiling tree (or the seam has degraded — then nothing is
            // managing the window and the plain setFrame is safe). Fired
            // once per actual normal→compact transition (the guard above
            // returns early on duplicate requests).
            transitionScheduler.schedule { [weak self] in
                guard let self, let window = self.window else { return }
                let token = self.beginTransition()
                self.floating.float(
                    bundleID: AeroSpaceCLI.appBundleID
                ) { [weak self] _ in
                    guard let self, self.isCurrent(token),
                        let window = self.window
                    else { return }
                    self.applyCompact(
                        transition.compact, visibleFrame: visibleFrame, to: window)
                }
            }
        } else if let restored = normalPresentation {
            self.normalPresentation = nil
            // The #44 amendment 2 EXIT edge: the #44 tile FIRST — the
            // saved-full-frame restore applies in the seam's COMPLETION,
            // AFTER the tiling engine has re-placed the window, so our
            // restore is the last geometry writer (the amendment 1
            // immediate restore measurably lost that race: AeroSpace
            // re-tiled the window after it, drifting the position across
            // tiles and eventually off-screen). Fired once per actual
            // compact→normal transition.
            transitionScheduler.schedule { [weak self] in
                guard let self, let window = self.window else { return }
                let token = self.beginTransition()
                self.floating.tile(
                    bundleID: AeroSpaceCLI.appBundleID
                ) { [weak self] _ in
                    guard let self, self.isCurrent(token),
                        let window = self.window
                    else { return }
                    self.apply(restored, to: window)
                }
            }
        }
    }

    /// Marks a new scheduled edge: every earlier pending completion
    /// becomes stale (its captured token no longer matches).
    private func beginTransition() -> Int {
        transitionGeneration += 1
        return transitionGeneration
    }

    private func isCurrent(_ token: Int) -> Bool {
        token == transitionGeneration
    }

    private func apply(_ state: MainWindowPresentationState, to window: NSWindow) {
        applyProperties(state, to: window)
        window.setFrame(state.frame, display: true)
    }

    private func applyCompact(
        _ state: MainWindowPresentationState,
        visibleFrame: CGRect,
        to window: NSWindow
    ) {
        applyProperties(state, to: window)
        let chromeSize = CGSize(
            width: window.frame.width - window.contentLayoutRect.width,
            height: window.frame.height - window.contentLayoutRect.height)
        let compactWindowSize = CGSize(
            width: MiniTimerWindowLayout.contentSize.width + chromeSize.width,
            height: MiniTimerWindowLayout.contentSize.height + chromeSize.height)
        let frame = MiniTimerWindowLayout.defaultTopRightFrame(
            visibleFrame: visibleFrame, contentSize: compactWindowSize)
        window.setFrame(frame, display: true)
    }

    private func applyProperties(_ state: MainWindowPresentationState, to window: NSWindow) {
        window.level = state.level
        window.contentMinSize = state.contentMinSize
        window.contentMaxSize = state.contentMaxSize
        window.collectionBehavior = state.collectionBehavior
        window.isMovableByWindowBackground = state.isMovableByWindowBackground
    }
}

/// Resolves the scene-created window without owning or creating one.
struct MainWindowAccessor: NSViewRepresentable {
    let onResolve: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowObservationView {
        WindowObservationView(onResolve: onResolve)
    }

    func updateNSView(_ view: WindowObservationView, context: Context) {
        view.onResolve = onResolve
        view.resolve()
    }

    final class WindowObservationView: NSView {
        var onResolve: @MainActor (NSWindow) -> Void

        init(onResolve: @escaping @MainActor (NSWindow) -> Void) {
            self.onResolve = onResolve
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resolve()
        }

        func resolve() {
            if let window { onResolve(window) }
        }
    }
}

enum AppShellContent: Equatable {
    case miniTimer
    case miniBreak
    case fullTimer
    case other

    /// Whether the resolved content needs the compact main-window
    /// presentation (issue #43): the one bit the shell keys its frame
    /// min/max bounds and its `setCompact` request off — true for either
    /// mini variant (the session timer's and the break's), false for the
    /// full timer and every other phase.
    var isCompact: Bool {
        switch self {
        case .miniTimer, .miniBreak: true
        case .fullTimer, .other: false
        }
    }

    /// Resolves which content the shell should render for a phase plus the
    /// two mini flags — the compact-request source of truth. Issue #43 adds
    /// the break variant: `.breakActive` resolves compact exactly when
    /// `isMiniBreakActive` (the `.timerView`/`isMiniTimerActive` logic,
    /// mirrored); the session flag is deliberately ignored on the break
    /// phase and vice versa, so a stale flag from the other lifecycle can
    /// never compact the wrong screen.
    static func resolve(
        phase: AppModel.AppPhase,
        isMiniTimerActive: Bool,
        isMiniBreakActive: Bool = false
    ) -> Self {
        switch phase {
        case .timerView:
            return isMiniTimerActive ? .miniTimer : .fullTimer
        case .breakActive:
            return isMiniBreakActive ? .miniBreak : .other
        default:
            return .other
        }
    }
}
