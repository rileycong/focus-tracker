import SwiftUI

/// The break countdown screen (issue #23, PRD §14.2–§14.4, §21): shown
/// exactly while `AppPhase.breakActive` is up — swapped in by the app
/// shell's ONE phase-driven path. Dark, minimal, calm, the session timer's
/// single-priority layout without any of the session context.
///
/// **Presentation (engineer's choice, documented):** the circular ring with
/// the big monospaced countdown inside it — the same calm shape the session
/// timer uses (PRD §21), so the two countdowns read as one visual language.
///
/// **Deliberately NOT shown (pinned do-not-show list, §14.4):** task
/// title/project/categories, "Session N today", ratings, notes, overrun
/// time (the timer stops at expiry; time past expiry is never counted,
/// displayed or logged). A break links to no task and collects no ratings —
/// ratings are collected only after work sessions.
///
/// # Ticking (issue #23 criterion 13, the #20/#21 pattern)
/// A `TimelineView(.periodic)` re-renders about once per second and derives
/// every displayed value from the engine's pure functions through the
/// `AppModel` passthroughs (`breakRemainingSeconds`, `breakProgressFraction`,
/// `isBreakExpired`) — nothing mutates the engine.
///
/// # Expiry (pinned semantics, §14.3)
/// When the countdown hits 0 the ring completes (full "done" color) and an
/// IN-APP notification banner appears — keyed off the model's observable
/// `isBreakExpired` state, re-read on every tick. NOT a system notification
/// (no `UNUserNotificationCenter`). Engineer's choice (documented): a
/// persistent banner under the ring with no sound and NO auto-dismiss. Issue
/// #38 preserves that path when focused. When unfocused, the view's ~1 s
/// watcher asks the model to start the shared #33 controller; the same subtle
/// shake as the focus timer accompanies its beeps until focus-back, when the
/// model ends/logs at the expiry instant and routes to `.sessionStart`.
///
/// # Controls (issue #23 criteria 14/16; post-expiry label amended by #42;
/// collapse added by #43)
/// While the break runs: **End break early** (`endEarlyLabel`) — ends the
/// break now and logs the actual timed duration (§14.4). After expiry the
/// same control becomes **Start next session** (`postExpiryLabel`) — the
/// break ends and logs at that acknowledgment and the flow routes to the
/// `.sessionStart` phase, so the session-start sheet opens directly with
/// the last session's target pre-selected (#34; the label used to read
/// "Back to tasks", which only described #23's pre-#34 `.tasksView`
/// exit — the routing had already changed, the label hadn't). One model
/// API (`AppModel.endBreak()`), two labels — the control shape is the
/// engineer's choice, the behavior is pinned.
///
/// # Compact collapse (issue #43)
/// A **Mini** control (the focus timer's placement language — bordered,
/// in the controls row, next to the end control) flips the model's
/// `isMiniBreakActive` via `collapseToMiniBreak()`: the app shell swaps
/// this screen for the countdown-only `MiniBreakView` and the SAME #37
/// presentation controller compacts the main window. `BreakView` only
/// exists while a break runs, so the control can never appear otherwise;
/// `collapseToMiniBreak()` still guards break-active (the
/// `collapseToMiniTimer` precedent).
struct BreakView: View {
    /// The composition root — the break passthroughs and the pinned
    /// `endBreak()` path.
    let model: AppModel

    @State private var shakeOffset: CGFloat = 0
    private static let shakeAmplitude: CGFloat = 4

    /// The end-control's label while the break is still running (issue
    /// #42: hoisted from the inline literal to a testable constant; the
    /// wording is unchanged — ends now, logs the actual timed duration).
    static let endEarlyLabel = "End break early"

    /// The end-control's label after expiry (issue #42): "Start next
    /// session" — matching where the control has actually routed since
    /// #34 (the `.sessionStart` sheet, with the last session's target
    /// pre-selected), replacing the stale "Back to tasks" that described
    /// the pre-#34 `.tasksView` exit. Routing is unchanged.
    static let postExpiryLabel = "Start next session"

    var body: some View {
        GeometryReader { geometry in
            // Same pinned sizing shape as TimerView: diameter ≈ min(w, h) * 0.6.
            let diameter = min(geometry.size.width, geometry.size.height) * 0.6
            VStack(spacing: DesignTokens.spacingL) {
                Text("Break")
                    .font(DesignTokens.titleFont)
                    .foregroundStyle(.secondary)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    // Ring + banner + control all re-derive on every ~1 s
                    // tick: the control's label swaps at expiry and the
                    // banner appears exactly when the observable
                    // `isBreakExpired` flips true.
                    VStack(spacing: DesignTokens.spacingL) {
                        ringBlock(diameter: diameter)
                        if model.isBreakExpired {
                            expiryBanner
                                .transition(.opacity.animation(DesignTokens.stateAnimation))
                        }
                        controls
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .offset(x: shakeOffset)
            .onChange(of: model.isExpiryAlarmActive) { _, alarming in
                if alarming {
                    withAnimation(
                        .easeInOut(duration: 0.09).repeatForever(autoreverses: true)
                    ) {
                        shakeOffset = Self.shakeAmplitude
                    }
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) { shakeOffset = 0 }
                }
            }
        }
        .background(DesignTokens.background)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                model.evaluateBreakExpiry()
            }
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private func ringBlock(diameter: CGFloat) -> some View {
        let remaining = model.breakRemainingSeconds ?? 0
        let progress = model.breakProgressFraction
        let expired = model.isBreakExpired
        let arc = TimerDisplay.ringArc(progressFraction: progress)
        ZStack {
            // Track.
            Circle()
                .stroke(DesignTokens.divider, lineWidth: DesignTokens.ringLineWidth)
            // Remaining arc: from the clamped progress offset to 1 — the
            // ring shrinks as time passes. At expiry the geometry swaps to
            // the FULL circle (0→1) via the pure, regression-tested
            // `TimerDisplay.ringArc`, completing into the subtle "done"
            // color.
            Circle()
                .trim(from: arc.from, to: arc.to)
                .stroke(
                    expired
                        ? DesignTokens.statusColor(.done)
                        : DesignTokens.statusColor(.inProgress),
                    style: StrokeStyle(
                        lineWidth: DesignTokens.ringLineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(DesignTokens.ringTickAnimation, value: arc)
            Text(TimerDisplay.countdownText(remainingSeconds: remaining))
                .font(.system(
                    size: diameter * 0.18, weight: .thin, design: .monospaced))
                .monospacedDigit()
        }
        .frame(width: diameter, height: diameter)
    }

    /// The in-app break-finished notification (criterion 15): a persistent
    /// banner for focused expiry — no sound or auto-dismiss on that path.
    private var expiryBanner: some View {
        Text("Break finished — head back when you're ready.")
            .font(DesignTokens.statusGroupFont)
            .foregroundStyle(DesignTokens.statusColor(.done))
            .padding(.horizontal, DesignTokens.spacingM)
            .padding(.vertical, DesignTokens.spacingS)
            .background(DesignTokens.chipBackground)
            .cornerRadius(DesignTokens.cornerRadius)
    }

    /// The controls row (issue #43): the collapse control — the focus
    /// timer's "Mini" placement language (bordered, `pip.enter`, next to
    /// the end control) — plus the one end control with its two #42 labels.
    /// Both re-derive on every ~1 s tick inside the enclosing
    /// `TimelineView`, so the end control's label swaps at expiry.
    private var controls: some View {
        HStack(spacing: DesignTokens.spacingM) {
            // Collapse-to-mini (issue #43): flips the model's mini-break
            // flag; `FocusTrackerApp` swaps this shell to `MiniBreakView`
            // and compacts the same on-screen window through the #37
            // controller. `BreakView` only exists while a break runs, so
            // the control can never appear otherwise;
            // `collapseToMiniBreak()` still guards break-active.
            Button {
                model.collapseToMiniBreak()
            } label: {
                Label("Mini", systemImage: "pip.enter")
            }
            .buttonStyle(.bordered)
            .help("Collapse to the always-on-top mini break timer")
            endControl
        }
    }

    /// One control, two labels (criteria 14/16; #42 hoists them to the
    /// testable constants above): `endEarlyLabel` while the break runs —
    /// ends now and logs the ACTUAL timed duration; `postExpiryLabel`
    /// after expiry — starts the next session: the break ends and logs at
    /// that acknowledgment (the post-expiry duration is the configured
    /// one, the engine clamps) and the flow routes to the `.sessionStart`
    /// sheet (#34; routing unchanged by the #42 rename). In compact mode
    /// the SAME control and labels render in `MiniBreakView` (issue #43).
    private var endControl: some View {
        Button {
            Task { await model.endBreak() }
        } label: {
            Text(model.isBreakExpired ? Self.postExpiryLabel : Self.endEarlyLabel)
        }
        .buttonStyle(.bordered)
    }
}
