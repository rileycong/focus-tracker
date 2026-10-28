import SwiftUI

/// The compact always-on-top mini BREAK (issue #43) — the #21/#37 compact
/// mode applied to the break screen, hosted inside the app's existing main
/// window while it uses compact always-on-top presentation. This file stays
/// pure SwiftUI. The presentation controller is reused UNCHANGED (it is
/// content-agnostic); only the shell's break-aware resolution is new.
///
/// Shows EXACTLY the pinned #43 list: the **countdown** —
/// `TimerDisplay.countdownText` of `model.breakRemainingSeconds`,
/// monospaced/thin — the **end control** with both #42 labels ("End break
/// early" while running / "Start next session" after expiry — the same
/// `BreakView` constants, one source of truth), and the two restore
/// affordances (the display area is click-to-restore, and the dedicated
/// expand button — the `MiniTimerView` placement language).
///
/// Deliberately NOT shown (pinned, #43): task title, session number, pause
/// control, ring — a break links to no task and cannot pause, and the mini
/// stays ring-less per the pinned #28/#35 no-ring design. The in-app
/// expiry banner is NOT rendered here either (it lives on the full
/// `BreakView`; see below).
///
/// # Focused expiry while compact (documented choice, #43)
/// Reconciling the draft's "completed ring" with the pinned no-ring mini:
/// the countdown renders `0:00` in the done color (`statusColor(.done)`,
/// the same semantic the completed ring carries) and the control swaps to
/// "Start next session". The completed ring and the in-app banner live on
/// the full `BreakView` and re-surface on restore — both derive from
/// `isBreakExpired` each tick, so nothing is lost, only compacted away.
///
/// # Resizable layout adaptation (#28 bounds, reused)
/// The compact main window is user-resizable (clamped to
/// `MiniTimerWindowLayout`'s min/max bounds), so the view fills it and
/// adapts: the countdown digits scale with the window height through the
/// pure `MiniTimerWindowLayout.countdownFontSize(forContentSize:)` helper
/// (22pt at the min height → the token base at the default size → 44pt at
/// the max height), measured via a container-size preference — no
/// AppKit/geometry API in this file. The countdown is single-line with a
/// `minimumScaleFactor`, so tight sizes degrade by scaling, never clipping.
///
/// # Ticking (#20/#23 pattern)
/// A `TimelineView(.periodic)` re-renders about once per second and derives
/// every displayed value from the break engine's pure functions through
/// the `AppModel` passthroughs (`breakRemainingSeconds`, `isBreakExpired`)
/// — nothing mutates the engine.
///
/// # Expiry watch (issue #43, the #33/`MiniTimerView` precedent)
/// `BreakView`'s `.task` watch loop dies with the view on collapse, so this
/// view runs its OWN ~1 s `evaluateBreakExpiry()` loop while it is the
/// visible surface — unfocused expiry starts the shared #33 controller
/// (beep + shake, the #39 seam below) until focus-back, when the model
/// ends/logs at the expiry instant and routes to `.sessionStart`; focused
/// expiry keeps the documented 0:00/label-swap path above. The model's
/// `isBreakExpiryWatching` latch keeps a brief view-transition overlap
/// double-fire-free.
struct MiniBreakView: View {
    /// The composition root — the break passthroughs, the pinned
    /// `endBreak()` path, and the mini-break flag.
    let model: AppModel

    /// The live compact-window content size (issue #28, the
    /// `MiniTimerView` pattern): captured from layout via a preference (no
    /// AppKit), driving the countdown's adaptive font. Starts at the
    /// default size so the first render is already correct.
    @State private var containerSize = MiniTimerWindowLayout.contentSize

    var body: some View {
        // One tick re-derives BOTH the countdown and the end control's
        // label/color — `isBreakExpired` is time-derived (non-reactive), so
        // the whole content stack rides the TimelineView (the `BreakView`
        // shape, not `MiniTimerView`'s display-area-only scope).
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(spacing: DesignTokens.spacingS) {
                countdownArea
                controls
            }
        }
        .padding(DesignTokens.spacingM)
        // Fill the resizable compact window (issue #28) — content centers
        // in the larger card at big sizes.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The #39 shared shake seam: the compact break visibly shakes for
        // exactly as long as the expiry alarm runs (unfocused expiry).
        .expiryAlarmShake(isActive: model.isExpiryAlarmActive)
        .background(containerSizeProbe)
        .background(miniBackground)
        .task {
            // The #43 expiry watch: the same ~1 s idempotent loop the full
            // `BreakView` runs, kept alive by THIS view while compact —
            // fully guarded, no-ops unless an unhandled expiry is pending
            // on a live break.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                model.evaluateBreakExpiry()
            }
        }
    }

    /// Invisible layout probe feeding `containerSize` (issue #28): pure
    /// SwiftUI measurement of the frame this view fills, so the countdown
    /// font can adapt through the pure `MiniTimerWindowLayout` helper
    /// without importing AppKit here. The measured size is the compact
    /// window content frame (independent of the font), so no feedback loop.
    private var containerSizeProbe: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: MiniBreakContainerSizeKey.self,
                value: proxy.size)
        }
        .onPreferenceChange(MiniBreakContainerSizeKey.self) { size in
            containerSize = size
        }
    }

    // MARK: - Countdown (the whole display)

    /// The click-to-restore display area (issue #43, the #21 criterion-3
    /// language): tapping it brings the full break screen back (the
    /// dedicated expand button below is the always-visible affordance).
    /// The control row is deliberately outside this gesture so the end
    /// control's taps never restore. Countdown ONLY — no title, no ring,
    /// no pause state (pinned #43 do-not-show list).
    private var countdownArea: some View {
        let remaining = model.breakRemainingSeconds ?? 0
        let expired = model.isBreakExpired
        return Text(TimerDisplay.countdownText(remainingSeconds: remaining))
            .font(.system(
                size: MiniTimerWindowLayout.countdownFontSize(
                    forContentSize: containerSize),
                weight: .thin,
                design: .monospaced))
            .monospacedDigit()
            .lineLimit(1)
            // #28: the pure helper picks the size for the window; the scale
            // factor is the belt-and-braces guarantee that even an
            // unexpected tight proposal degrades by scaling.
            .minimumScaleFactor(0.5)
            // Focused expiry while compact (documented choice): 0:00 in
            // the done color — the same semantic the completed ring
            // carries on the full view, which re-surfaces on restore.
            .foregroundStyle(
                expired ? DesignTokens.statusColor(.done) : .primary)
            .animation(DesignTokens.stateAnimation, value: expired)
            .contentShape(Rectangle())
            .onTapGesture(perform: restoreFullBreak)
    }

    /// The control row: the end control (both #42 labels — the SAME
    /// `BreakView` constants, no second wording source) and the dedicated
    /// restore affordance. NO pause control (a break cannot pause, #43).
    private var controls: some View {
        HStack(spacing: DesignTokens.spacingS) {
            Button {
                Task { await model.endBreak() }
            } label: {
                Text(
                    model.isBreakExpired
                        ? BreakView.postExpiryLabel : BreakView.endEarlyLabel)
            }
            // Dedicated restore affordance (issue #43) alongside the
            // click-to-restore display area — the MiniTimerView language.
            Button {
                restoreFullBreak()
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
            }
            .help("Restore the full break screen")
        }
        .controlSize(.small)
    }

    /// The visible shape of the borderless compact window: a rounded dark
    /// card matching `DesignTokens.background` — the same card the mini
    /// session timer uses, so the two compact surfaces read as one shape.
    private var miniBackground: some View {
        RoundedRectangle(cornerRadius: DesignTokens.panelCornerRadius, style: .continuous)
            .fill(DesignTokens.background)
            .overlay(
                RoundedRectangle(
                    cornerRadius: DesignTokens.panelCornerRadius, style: .continuous)
                    .strokeBorder(DesignTokens.divider, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
    }

    // MARK: - Actions

    /// One explicit, idempotent command shared by the two disjoint restore
    /// affordances. The display gesture does not cover the controls row, so
    /// one click can enter this function only once.
    private func restoreFullBreak() {
        model.restoreFromMiniBreak()
    }
}

/// Preference key carrying the mini break view's container size (issue
/// #43): the plumbing behind `MiniBreakView.containerSizeProbe` — pure
/// SwiftUI, no AppKit, no state beyond the value itself (the
/// `MiniTimerView` pattern, mirrored).
private struct MiniBreakContainerSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}
