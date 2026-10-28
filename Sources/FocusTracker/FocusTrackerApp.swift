import SwiftUI

@main
struct FocusTrackerApp: App {
    @State private var model: AppModel
    @State private var windowPresentation: MainWindowPresentationController
    @NSApplicationDelegateAdaptor(FocusTrackerAppDelegate.self)
    private var appDelegate: FocusTrackerAppDelegate

    init() {
        let settings: AppSettings
        do {
            settings = try AppSettings(suiteName: AppSettings.defaultSuiteName)
        } catch {
            settings = AppSettings(defaults: .standard)
        }
        // Issue #44 amendment: when the collapse/restore harness runs, its
        // launch-lifecycle telemetry must be installed at APP-INIT — before
        // the SwiftUI scene exists — or a scene that never presents would
        // also never explain itself.
        AutoCollapseDemo.installEarlyTelemetryIfRequested()
        let model = AppModel(settings: settings)
        _model = State(initialValue: model)
        // Issue #44 amendment 2: production defers each transition step
        // one main-queue tick, so the controller's seam firing lands
        // AFTER the SwiftUI transaction's own window-geometry pass. The
        // window-frame writes themselves happen later still — at the
        // seam's completion — because a live AeroSpace re-asserts tile
        // geometry (via the accessibility API) over ANY frame set while
        // the window is still tiled (the measured reason the compact
        // window never shrank in the real app; see
        // MainWindowPresentationController). Tests default to the inline
        // scheduler.
        _windowPresentation = State(
            initialValue: MainWindowPresentationController(
                transitionScheduler: NextTickMainWindowTransitionScheduler()))
        appDelegate.snapshotSave = { [weak model] in
            model?.saveActiveSessionSnapshotForTermination()
        }
        // Issue #49: the quit flush — AFTER the #30 snapshot save (the
        // delegate orders the two), the sync coordinator pushes the
        // debounced, un-synced vault writes. Synchronous, best-effort,
        // watchdog-bounded: failure never vetoes or defers termination.
        appDelegate.terminationFlush = { [weak model] in
            model?.flushSyncForTermination()
        }
    }

    var body: some Scene {
        // A `Window`, rather than `WindowGroup`, preserves the app's
        // single-window contract. Compact mode reconfigures this same window.
        Window("Focus Tracker", id: "main") {
            Group {
                switch model.appPhase {
                case .tasksView:
                    TasksView(model: model)
                case .timerView(let context):
                    if model.isMiniTimerActive {
                        MiniTimerView(context: context, model: model)
                    } else {
                        TimerView(context: context, model: model)
                    }
                case .endingSession(let result, _, let context):
                    TimerView(context: context, model: model)
                        .sheet(isPresented: .constant(true)) {
                            EndOfSessionModalView(
                                result: result, context: context, model: model)
                                .interactiveDismissDisabled(true)
                        }
                case .postSessionChoice(let completionFailure):
                    PostSessionChoiceView(
                        model: model, completionFailure: completionFailure)
                case .breakActive:
                    // Issue #43: the #21 flag-beside-phase pattern, mirrored
                    // on the break — the compact countdown-only mini break
                    // renders in the SAME window while `isMiniBreakActive`.
                    if model.isMiniBreakActive {
                        MiniBreakView(model: model)
                    } else {
                        BreakView(model: model)
                    }
                case .sessionStart:
                    TasksView(model: model)
                        .sheet(isPresented: .constant(true)) {
                            SessionStartView(
                                tasks: model.tasks,
                                knownCategoryNames: TaskFormState
                                    .knownCategoryNames(in: model.tasks),
                                preselectedTargetID: model.lastSessionTargetID,
                                onStart: { taskID, duration in
                                    try await model.startSession(
                                        taskID: taskID, duration: duration)
                                },
                                onStartAdHoc: { title, categoryNames, duration in
                                    try await model.startAdHocSession(
                                        title: title,
                                        categoryNames: categoryNames,
                                        duration: duration)
                                },
                                onCancel: { model.cancelSessionStart() })
                        }
                case .recoveryPrompt(let snapshot, let context):
                    TasksView(model: model)
                        .sheet(isPresented: .constant(true)) {
                            RecoveryPromptView(
                                snapshot: snapshot, context: context, model: model)
                                .interactiveDismissDisabled(true)
                        }
                }
            }
            // Issue #45: the ONE app-shell vault-switcher sheet — driven by
            // the model's request state (the #34 `.sessionStart` / #36
            // `.recoveryPrompt` single-presentation precedent), attached
            // here at app-shell level rather than TasksView-local so EVERY
            // non-refusing phase can switch: `.postSessionChoice` renders
            // `PostSessionChoiceView` and `.sessionStart` /
            // `.recoveryPrompt` carry their own TasksView-local sheets —
            // a TasksView-local switcher sheet could not present over any
            // of them. It presents the shared `ChooseVaultView` (the #26
            // choose-existing flow) in its sheet variant.
            .sheet(isPresented: vaultSwitcherPresentation) {
                ChooseVaultView(model: model, context: .switcherSheet)
                    .padding(DesignTokens.spacingL)
                    .frame(maxWidth: 460)
            }
            // Issue #49: the ONE app-shell sync-settings sheet — the #45
            // precedent exactly (additive model request flag, cleared by
            // the presenting path; app-shell-level attachment;
            // ChooseVaultView-style padding/frame). ONE compact sheet: the
            // "Sync vault via git" Toggle, the remote-URL field and the
            // read-only health/error line. No second window/scene (#27
            // single-window discipline).
            .sheet(isPresented: syncSheetPresentation) {
                SyncVaultSettingsView(model: model)
                    .padding(DesignTokens.spacingL)
                    .frame(maxWidth: 460)
            }
            .overlay(alignment: .bottom) {
                if let warning = model.pendingBreakLogWarning {
                    Text(warning)
                        .font(DesignTokens.annotationFont)
                        .foregroundStyle(DesignTokens.warning)
                        .padding(.horizontal, DesignTokens.spacingM)
                        .padding(.vertical, DesignTokens.spacingS)
                        .background(DesignTokens.bannerBackground)
                        .cornerRadius(DesignTokens.cornerRadius)
                        .padding(.bottom, DesignTokens.spacingM)
                        .transition(.opacity)
                }
            }
            .frame(
                // Issue #43: the bounds key off the RESOLVED compact state
                // (either mini variant), not the session flag alone.
                minWidth: isCompactPresentation
                    ? MiniTimerWindowLayout.contentMinSize.width : 640,
                idealWidth: isCompactPresentation
                    ? MiniTimerWindowLayout.contentSize.width : nil,
                maxWidth: isCompactPresentation
                    ? MiniTimerWindowLayout.contentMaxSize.width : nil,
                minHeight: isCompactPresentation
                    ? MiniTimerWindowLayout.contentMinSize.height : 420,
                idealHeight: isCompactPresentation
                    ? MiniTimerWindowLayout.contentSize.height : nil,
                maxHeight: isCompactPresentation
                    ? MiniTimerWindowLayout.contentMaxSize.height : nil)
            .background {
                MainWindowAccessor { window in
                    windowPresentation.attach(window)
                    syncWindowPresentation()
                }
            }
            .task {
                await model.bootstrap()
                await AutoCollapseDemo.runIfNeeded(model: model)
            }
            .onChange(of: model.appPhase) { _, _ in syncWindowPresentation() }
            .onChange(of: model.isMiniTimerActive) { _, _ in syncWindowPresentation() }
            .onChange(of: model.isMiniBreakActive) { _, _ in syncWindowPresentation() }
            .preferredColorScheme(.dark)
        }
        // Issue #45: the top-level Vault menu (the pinned primary
        // placement — a `CommandMenu`, the app's first `.commands` block).
        .commands {
            CommandMenu("Vault") {
                // The disabled current-path line — the discoverability
                // primary (from `model.vaultURL`; the pinned "No vault
                // configured" placeholder while unconfigured). A disabled
                // label, not an action.
                Text(currentVaultLine)
                    .disabled(true)
                Divider()
                // Change Vault… (⌘⇧V): disabled exactly per the model's
                // read-only enablement derivation — the pinned
                // `setVaultPath` refusal chain (session active /
                // `.endingSession` / `.breakActive`), plus the documented
                // engineer's-choice extra disable while unconfigured
                // (onboarding owns selection there). The action is the
                // model entry point; the `NSOpenPanel` flow itself lives
                // in the sheet's shared `ChooseVaultView`.
                Button("Change Vault…") {
                    model.requestVaultSwitch()
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(!model.isVaultSwitcherEnabled)
                Divider()
                // Issue #49: the ONE new Vault-menu item — "Sync Vault…"
                // opens the ONE compact settings sheet (the #45 precedent).
                Button("Sync Vault…") {
                    model.requestSyncSheet()
                }
                Divider()
                // Issue #50 (FocusVault FT-2): the Inbox draft import item.
                // Label = the model's pure derivation over the live counts
                // — the EXACT pinned strings "Import Inbox Drafts (N)" /
                // "Import Inbox Drafts (N, M problems)" (the #45/#49
                // wording-derivation precedent; tests assert the strings,
                // the menu never re-implements them). The action is
                // pull-before-import (the #49 [Pull triggers] seam) then
                // the import, async OFF the interaction path (the importer
                // actor + the store actor own the I/O — the timer UI never
                // blocks). Enabled whenever a vault is configured — even
                // N=0, where the action doubles as an honest rescan;
                // disabled only while unconfigured. NO toast/banner/
                // animation (the pinned do-not-shows): the imported task
                // simply appears in the list.
                Button(model.inboxImportMenuItemLabel) {
                    Task { await model.importInboxDrafts() }
                }
                .disabled(!model.isInboxImportEnabled)
            }
        }
    }

    /// The vault-switcher sheet binding (issue #45): presented exactly
    /// while the model's request state is set; any SwiftUI-driven
    /// dismissal (the binding's `false` write) clears the request through
    /// the same ONE model path the sheet's own completion/cancel controls
    /// use, so the state can never go stale.
    private var vaultSwitcherPresentation: Binding<Bool> {
        Binding(
            get: { model.isVaultSwitcherRequested },
            set: { if !$0 { model.clearVaultSwitchRequest() } })
    }

    /// The #49 sync-settings sheet binding: presented exactly while the
    /// model's request state is set; any SwiftUI-driven dismissal clears
    /// the request through the same ONE model path the sheet uses (the
    /// #45 precedent, mirrored).
    private var syncSheetPresentation: Binding<Bool> {
        Binding(
            get: { model.isSyncSheetRequested },
            set: { if !$0 { model.clearSyncSheetRequest() } })
    }

    /// The Vault menu's disabled current-path line (issue #45): the
    /// discoverability primary — `Current: <path>` from `model.vaultURL`,
    /// or the pinned "No vault configured" placeholder while unconfigured.
    private var currentVaultLine: String {
        if let vaultURL = model.vaultURL {
            "Current: " + vaultURL.path(percentEncoded: false)
        } else {
            "No vault configured"
        }
    }

    /// Whether the main window should be in the compact #37 presentation
    /// right now: the resolved content's `isCompact` (issue #43 — either
    /// mini variant, the session timer's or the break's).
    private var isCompactPresentation: Bool {
        AppShellContent.resolve(
            phase: model.appPhase,
            isMiniTimerActive: model.isMiniTimerActive,
            isMiniBreakActive: model.isMiniBreakActive).isCompact
    }

    private func syncWindowPresentation() {
        windowPresentation.setCompact(isCompactPresentation)
    }
}
