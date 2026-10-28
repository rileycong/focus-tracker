import SwiftUI

/// The ONE compact sync-settings sheet (issue #49, the [Settings toggle]
/// criterion): "Sync Vault…" opens it from the Vault menu — the #45
/// vault-switcher-sheet precedent exactly (additive model request flag,
/// cleared by the presenting path; `.sheet(isPresented:)` attached at
/// app-shell level; `ChooseVaultView`-style padding/frame). Inside: THE
/// settings row — the "Sync vault via git" Toggle, the remote-URL
/// TextField (the amendment, 2026-09-20: it speaks GITHUB — the friendly
/// HTTPS display, garbage refused with the pinned reason — while
/// storage and the engine stay on the SSH form; issue #57: it starts EMPTY
/// with a generic placeholder — there is no default remote) and the read-only
/// health/error line (plain `Text`, single line, middle-truncated; the
/// ONLY sync surface in the entire app — no banners, no "last synced", no
/// badges; sync failures NEVER alert/interrupt). The amendment adds the
/// three word-for-word instruction sentences and the always-exitable Done
/// affordance (the ChooseVaultView cancel-button pattern).
///
/// The sheet NEVER refuses (no `AppPhase` case): toggling mid-session/
/// break is safe — the next cycle re-reads. It introduces NO new sync
/// trigger: the appear context, the toggle flip and the input change run
/// the STATIC health evaluation and the ONE settings-UI reachability
/// probe, and nothing more (pulls happen ONLY at the [Pull triggers]
/// triggers; pushes ONLY at the [Push]/[Quit flush] triggers). Esc
/// dismisses (the Cancel-role Done is the Esc responder, the #45
/// semantics); Cmd+Q with the sheet open terminates normally (#27: the
/// one app delegate answers no termination-decision method).
struct SyncVaultSettingsView: View {

    /// The composition root — the pinned paths are `setSyncEnabled(_:)`,
    /// `setSyncRemote(_:)` and `syncSettingsSheetAppeared()`.
    let model: AppModel

    /// The draft remote URL. Initialized ONCE from the model's DISPLAY
    /// form (friendly HTTPS; EMPTY while nothing is stored) so the appear
    /// context doesn't re-persist an untouched field — the stored value
    /// stays untouched until the user actually types.
    @State private var draftRemote: String

    // MARK: - Pinned copy (the 2026-09-20 amendment, Delta 3 — EXACT)

    static let instructionBackup =
        "This quietly saves every change in your vault to your private "
            + "GitHub backup, about a minute after you make it."
    static let instructionLink =
        "To get the link: open your repo on GitHub → click the green Code "
            + "button → copy the HTTPS link → paste it here."
    static let instructionSwitchOff =
        "You can switch sync off at any time — the app keeps working "
            + "exactly as it does today."

    init(model: AppModel) {
        self.model = model
        _draftRemote = State(initialValue: model.syncRemoteEntry)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingM) {
            Text("Sync Vault")
                .font(DesignTokens.sheetHeaderFont)
            Toggle("Sync vault via git", isOn: syncToggleBinding)
                .disabled(AppModel.isSyncToggleControlDisabled(for: model.syncHealth))
            TextField(
                "Remote URL", text: $draftRemote,
                prompt: Text(AppModel.syncRemotePlaceholder)
            )
            .textFieldStyle(.roundedBorder)
                .font(DesignTokens.bodyFont)
                .onChange(of: draftRemote) { _, newValue in
                    Task { await model.setSyncRemote(newValue) }
                }
            // Delta 2: garbage input is refused BEFORE persistence (the
            // model keeps the last good stored value) — the row surfaces
            // the pinned reason in the warning style (the annotation/
            // warning precedent; no new tokens).
            if AppModel.isUnrecognizedSyncRemoteDraft(draftRemote) {
                Text(Self.unrecognizedRemoteMessage)
                    .font(DesignTokens.annotationFont)
                    .foregroundStyle(DesignTokens.warning)
            }
            // The read-only health/error line — the row's ONE sync surface:
            // wording derives from `SyncHealth` through the ONE pure
            // function (tests assert the exact strings).
            Text(AppModel.syncHealthLine(for: model.syncHealth))
                .font(DesignTokens.annotationFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            // Delta 3: the pinned instructions, word-for-word.
            VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
                Text(Self.instructionBackup)
                Text(Self.instructionLink)
                Text(Self.instructionSwitchOff)
            }
            .font(DesignTokens.annotationFont)
            .foregroundStyle(.secondary)
            // Delta 1: the sheet is ALWAYS exitable — the ChooseVaultView
            // cancel-button pattern; the action is the ONE model path the
            // shell's binding set-side also uses, so every dismissal
            // (button, Esc, the interactive-dismiss swipe) clears the
            // request flag through the same code.
            HStack {
                Spacer()
                Button("Done", role: .cancel) {
                    model.clearSyncSheetRequest()
                }
                .buttonStyle(.bordered)
            }
        }
        .task {
            // The pinned settings-UI "sheet-appear" context: the STATIC
            // health refresh + the ONE reachability probe — nothing more.
            await model.syncSettingsSheetAppeared()
        }
    }

    /// Delta 2's pinned garbage message (the amendment's exact string).
    static let unrecognizedRemoteMessage = AppModel.unrecognizedSyncRemoteMessage

    /// The Toggle's binding: get = the PERSISTED setting; set = the #49
    /// write path (persists immediately, applies the coordinator, runs the
    /// pinned flip context). A SwiftUI dismissal of the mid-flip Task is
    /// harmless: the next cycle re-reads.
    private var syncToggleBinding: Binding<Bool> {
        Binding(
            get: { model.isSyncEnabled },
            set: { newValue in
                Task { await model.setSyncEnabled(newValue) }
            })
    }
}
