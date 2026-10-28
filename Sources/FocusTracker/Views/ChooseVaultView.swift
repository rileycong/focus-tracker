import SwiftUI

/// The shared choose-existing-vault flow (issue #45, lifting #26's
/// view-local UI out of `OnboardingView`): folder picker → the pinned
/// onboarding-level `VaultStructureValidator` pre-check → `.valid` →
/// `setVaultPath(to:)` (switches immediately; `applyVaultLocation`
/// recreates both stores and reloads); structure mismatch → the explicit
/// consent UI (**Scaffold missing folders** / **Cancel** — nothing is
/// modified before consent, and a declined consent leaves disk, settings
/// and state untouched); `.nameCollision` → a typed inline error with no
/// scaffold offer. Picker cancel changes nothing. The `NSOpenPanel` stays
/// view-layer exactly as in #26 — the model's pinned APIs
/// (`setVaultPath(to:)`, `selectExistingVault(at:scaffoldMissingWithConsent:)`)
/// are the only mutation paths, and the degraded-state re-selection flow
/// elsewhere in `TasksView` keeps its current behavior (out of scope).
///
/// Used from BOTH entry points (the pinned extraction shape):
/// - `.onboardingSection` — embedded in place of `OnboardingView`'s "Use
///   an existing vault" section: #26's visuals and behavior unchanged
///   (the section header, description, button and consent card are
///   verbatim; the existing-path inline messages now render inside the
///   section — the page-level block they occupied sat directly beneath
///   it, so the placement is visually equivalent).
/// - `.switcherSheet` — the app-shell vault-switcher sheet (issue #45),
///   presented by `FocusTrackerApp` off the model's
///   `isVaultSwitcherRequested` state: adds the sheet chrome (a "Change
///   Vault" title, the current-path line, a Cancel control) and clears
///   the request state on completion/cancel so the sheet dismisses.
///
/// Refusal wording (issue #45): the shared flow surfaces the typed
/// `.refusedWhileSessionActive` outcome with the WIDER per-condition
/// remedy derivation (`AppModel.vaultSwitchRefusalMessage`) — the menu
/// item's disabled state is the primary guard; a refusal landing here is
/// the defensive backstop and is never a silent no-op. Unreachable from
/// onboarding (onboarding shows solely while unconfigured).
struct ChooseVaultView: View {

    /// Where the shared flow is presented from. The flow itself (state,
    /// picker, pre-check, consent, typed outcomes) is identical in both;
    /// only the chrome and the dismissal wiring differ.
    enum PresentationContext {
        /// Embedded in `OnboardingView` — #26's section, verbatim.
        case onboardingSection
        /// The app-shell vault-switcher sheet (issue #45).
        case switcherSheet
    }

    /// The composition root — `setVaultPath(to:)` and
    /// `selectExistingVault(at:scaffoldMissingWithConsent:)` are the
    /// pinned paths.
    let model: AppModel
    let context: PresentationContext

    // MARK: - State (lifted verbatim from OnboardingView, #26)

    /// The folder awaiting the scaffold consent (shown only when the
    /// pre-check found missing structure — a valid folder applies
    /// immediately, a collision shows the typed error).
    @State private var consentRequest: ConsentRequest?
    /// The inline typed-error surface (the #19 `inlineMessage` pattern).
    @State private var inlineError: String?
    /// The typed-cancelled confirmation (consent declined — nothing was
    /// changed).
    @State private var cancelNotice = false
    /// Guards the buttons while a model operation is in flight.
    @State private var isWorking = false

    /// The pending scaffold-consent decision (pure data — view-local; the
    /// model re-validates on apply).
    private struct ConsentRequest {
        let url: URL
        let missing: VaultStructureValidator.ValidationOutcome
    }

    // MARK: - Body

    var body: some View {
        switch context {
        case .onboardingSection:
            onboardingSection
        case .switcherSheet:
            switcherSheet
        }
    }

    // MARK: - Onboarding embedding (#26's section, verbatim)

    private var onboardingSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingM) {
            Text("Use an existing vault")
                .font(DesignTokens.sectionFont)
            Text(
                "Choose a folder that contains Tasks/ and Logs/ — or one "
                    + "where they can be scaffolded with your consent.")
                .font(DesignTokens.annotationFont)
                .foregroundStyle(.secondary)
            chooseButton
            consentIfRequested
            inlineMessages
        }
    }

    // MARK: - Switcher sheet chrome (issue #45)

    /// The sheet variant: the same flow with a "Change Vault" title, the
    /// current-path line (the secondary discoverability surface — the
    /// primary is the Vault menu's disabled line) and a Cancel control
    /// that clears the model's request state (the sheet's dismissal).
    private var switcherSheet: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingM) {
            Text("Change Vault")
                .font(DesignTokens.sectionFont)
            Text(currentVaultLine)
                .font(DesignTokens.annotationFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
            Text(
                "Choose a folder that contains Tasks/ and Logs/ — or one "
                    + "where they can be scaffolded with your consent.")
                .font(DesignTokens.annotationFont)
                .foregroundStyle(.secondary)
            chooseButton
            consentIfRequested
            inlineMessages
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    model.clearVaultSwitchRequest()
                }
                .buttonStyle(.bordered)
                .disabled(isWorking)
            }
        }
    }

    /// The current-path line (issue #45): from `model.vaultURL`, with the
    /// pinned "No vault configured" placeholder while unconfigured (the
    /// same wording as the Vault menu's disabled line).
    private var currentVaultLine: String {
        if let vaultURL = model.vaultURL {
            "Current: " + vaultURL.path(percentEncoded: false)
        } else {
            "No vault configured"
        }
    }

    // MARK: - Shared flow UI

    private var chooseButton: some View {
        Button("Choose Existing Vault…") {
            pickExistingVault()
        }
        .buttonStyle(.bordered)
        .disabled(isWorking)
    }

    @ViewBuilder
    private var consentIfRequested: some View {
        if let request = consentRequest {
            consentView(request)
        }
    }

    /// The explicit consent UI for a structure-mismatch pre-check (pinned:
    /// consent is required before ANY modification; nothing was touched by
    /// the pre-check itself).
    private func consentView(_ request: ConsentRequest) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
            Text(
                "“\(request.url.lastPathComponent)” is missing "
                    + Self.missingFoldersDescription(request.missing) + ".")
                .font(DesignTokens.bodyFont)
            Text(
                "Scaffold the missing folders in place? Existing content is "
                    + "never touched.")
                .font(DesignTokens.annotationFont)
                .foregroundStyle(.secondary)
            HStack(spacing: DesignTokens.spacingS) {
                Button("Scaffold missing folders") {
                    consentScaffold(request)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking)
                Button("Cancel", role: .cancel) {
                    consentCancel(request)
                }
                .buttonStyle(.bordered)
                .disabled(isWorking)
            }
        }
        .padding(DesignTokens.spacingM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.bannerBackground)
        .cornerRadius(DesignTokens.cornerRadius)
    }

    /// The inline error + typed-cancel surfaces (the #19 precedent).
    private var inlineMessages: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingXS) {
            if let inlineError {
                Text(inlineError)
                    .font(DesignTokens.annotationFont)
                    .foregroundStyle(DesignTokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if cancelNotice {
                Text("Cancelled — nothing was changed.")
                    .font(DesignTokens.annotationFont)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions (the #26 flow, lifted)

    /// The Choose Existing Vault picker + the pinned pre-check: the pure
    /// validator runs BEFORE any `setVaultPath` and decides the branch.
    /// The degraded-state re-selection flow elsewhere in `TasksView` keeps
    /// its current behavior (out of scope).
    private func pickExistingVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = "Choose the vault folder that contains Tasks/ and Logs/."
        panel.prompt = "Choose vault"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        inlineError = nil
        cancelNotice = false
        consentRequest = nil

        // The pinned pre-check (read-only).
        let validation = VaultStructureValidator.validate(at: url)
        switch validation {
        case .valid:
            // The frictionless case: used as-is via setVaultPath exactly as
            // today (issue #14's .changed semantics) — no consent needed.
            isWorking = true
            Task {
                let outcome = await model.setVaultPath(to: url)
                switch outcome {
                case .changed:
                    finishSwitchIfPresentedAsSheet()
                case .refusedWhileSessionActive:
                    inlineError = Self.refusalMessage(for: model)
                }
                isWorking = false
            }
        case .missingTasks, .missingLogs, .bothMissing:
            // Typed structure mismatch: explicit consent UI before ANY
            // modification.
            consentRequest = ConsentRequest(url: url, missing: validation)
        case .nameCollision:
            // Typed inline error; nothing modified; no scaffold offer.
            inlineError =
                "“\(url.lastPathComponent)” has a file where its Tasks/ or "
                + "Logs/ folder should be. Nothing was changed."
        }
    }

    /// The consent path: scaffold ONLY the missing directories (the same
    /// helper as the create path), then store the path like a normal
    /// selection.
    private func consentScaffold(_ request: ConsentRequest) {
        consentRequest = nil
        inlineError = nil
        isWorking = true
        Task {
            do {
                let outcome = try await model.selectExistingVault(
                    at: request.url, scaffoldMissingWithConsent: true)
                switch outcome {
                case .scaffolded, .selected:
                    finishSwitchIfPresentedAsSheet()
                case .cancelled:
                    cancelNotice = true
                case .nameCollision(let url):
                    inlineError =
                        "“\(url.lastPathComponent)” has a file where its "
                        + "Tasks/ or Logs/ folder should be. Nothing was "
                        + "changed."
                case .refusedWhileSessionActive:
                    inlineError = Self.refusalMessage(for: model)
                }
            } catch {
                // Non-decision I/O failure — surfaced, never swallowed; the
                // path was not stored.
                inlineError = error.localizedDescription
            }
            isWorking = false
        }
    }

    /// The typed cancelled path: nothing on disk modified, path NOT stored,
    /// the app stays as it was — confirmed by the model's outcome. The
    /// sheet stays up showing the cancelled notice (only a successful
    /// switch completes it).
    private func consentCancel(_ request: ConsentRequest) {
        consentRequest = nil
        inlineError = nil
        Task {
            if case .cancelled = (try? await model.selectExistingVault(
                at: request.url, scaffoldMissingWithConsent: false))
            {
                cancelNotice = true
            }
        }
    }

    // MARK: - Helpers

    /// The sheet-context completion (issue #45): a successful switch
    /// clears the model's request state, dismissing the app-shell sheet.
    /// In the onboarding embedding this is a no-op — the shell swaps the
    /// whole view tree to Tasks when the vault state leaves
    /// `.notConfigured`, so there is nothing to dismiss.
    private func finishSwitchIfPresentedAsSheet() {
        if context == .switcherSheet {
            model.clearVaultSwitchRequest()
        }
    }

    /// The per-condition refusal wording (issue #45): wider than #26's
    /// session-only onboarding string — names the remedy for whichever
    /// condition of the pinned chain currently holds, in the chain's
    /// check order. The pure model derivation, asserted by the model
    /// tests without AppKit.
    private static func refusalMessage(for model: AppModel) -> String {
        AppModel.vaultSwitchRefusalMessage(
            isSessionActive: model.isSessionActive, appPhase: model.appPhase)
    }

    private static func missingFoldersDescription(
        _ outcome: VaultStructureValidator.ValidationOutcome
    ) -> String {
        switch outcome {
        case .missingTasks: "its Tasks/ folder"
        case .missingLogs: "its Logs/ folder"
        case .bothMissing: "its Tasks/ and Logs/ folders"
        case .valid, .nameCollision:
            // Unreachable from the consent UI (only mismatch pre-checks
            // open it); fail toward the honest empty description.
            "anything"
        }
    }
}
