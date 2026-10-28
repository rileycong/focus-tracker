import XCTest
import SyncCore
@testable import FocusTracker

/// The #49 [SyncCore packaging] + [Health]-wording + [Settings toggle]
/// persistence floor: both settings keys' save→reload-ACROSS-INSTANCES
/// persistence (the #14 precedent), the ONE pure wording function over
/// EVERY `SyncHealth` case with EXACT strings, and the model-level
/// precondition→health derivation.


@MainActor
final class SyncSettingsTests: XCTestCase {

    // MARK: - The literal keys (issue #57: there is NO default remote)

    func testLiteralKeyStrings() {
        XCTAssertEqual(AppSettings.vaultSyncEnabledKey, "vaultSyncEnabled")
        XCTAssertEqual(AppSettings.vaultSyncRemoteKey, "vaultSyncRemote")
    }

    func testBothKeysSaveAndReloadAcrossInstances() throws {
        // The #14 precedent: a fresh wrapper over the SAME suite reads what
        // the previous instance stored — a relaunch, or a second instance.
        let suiteName = "ft49-settings-\(UUID().uuidString)"
        var first = try AppSettings(suiteName: suiteName)

        // The shipped-by-default state: disabled, remote unstored.
        XCTAssertFalse(first.vaultSyncEnabled)
        XCTAssertNil(first.vaultSyncRemote)
        // Unset resolves to "" (no remote) at USE time — never a default.
        XCTAssertEqual(first.resolvedVaultSyncRemote(), "")

        // Persist BOTH (as-typed) through the first instance…
        first.vaultSyncEnabled = true
        let asTyped = "git@github.com:example/as-typed-1.git"
        first.vaultSyncRemote = asTyped

        // …and read them back through a SECOND instance.
        var second = try AppSettings(suiteName: suiteName)
        XCTAssertTrue(second.vaultSyncEnabled)
        XCTAssertEqual(second.vaultSyncRemote, asTyped)
        // A stored non-blank value resolves AS-TYPED (never rewritten).
        XCTAssertEqual(second.resolvedVaultSyncRemote(), asTyped)

        // The storing-inst immediate-write contract, also crash-safe-shaped:
        // the value is visible to a third instance the moment it was set.
        second.vaultSyncEnabled = false
        second.vaultSyncRemote = nil
        var third = try AppSettings(suiteName: suiteName)
        XCTAssertFalse(third.vaultSyncEnabled)
        XCTAssertNil(third.vaultSyncRemote)
        XCTAssertEqual(third.resolvedVaultSyncRemote(), "")

        // Blank (not nil) also resolves to "" at USE time, while the
        // stored value stays as-typed.
        third.vaultSyncRemote = "   "
        XCTAssertEqual(third.vaultSyncRemote, "   ")
        XCTAssertEqual(third.resolvedVaultSyncRemote(), "")
    }

    // MARK: - The ONE pure wording function (every case, EXACT strings)

    func testSyncHealthLineDisabledIsExact() {
        XCTAssertEqual(
            AppModel.syncHealthLine(for: .disabled), "Sync is off.")
    }

    func testSyncHealthLineUnavailableIsExact() {
        XCTAssertEqual(
            AppModel.syncHealthLine(
                for: .unavailable(reason: "the vault is not a git repository")),
            "Sync unavailable — the vault is not a git repository.")
    }

    func testSyncHealthLineIdleIsExact() {
        // No "last synced" timestamp — the pinned do-not-shows.
        XCTAssertEqual(
            AppModel.syncHealthLine(for: .idle), "Sync is on and healthy.")
    }

    func testSyncHealthLineErrorIsExact() {
        XCTAssertEqual(
            AppModel.syncHealthLine(for: .error("push failed: some refs")),
            "Sync problem — push failed: some refs")
    }

    func testSyncHealthLineDivergenceStatesManualResolveNoAutoMerge() {
        let divergence = SyncCycleError.diverged(ahead: 2, behind: 3)
        let line = AppModel.syncHealthLine(for: .error(divergence.detail))
        XCTAssertTrue(line.contains("resolve the histories manually"))
        XCTAssertTrue(line.contains("no auto-merge"))
        XCTAssertTrue(line.contains("ahead 2, behind 3"))
    }

    // MARK: - The model-level precondition → health derivation

    /// A minimal temp vault WITHOUT `.git` — the machine fact (VS-2
    /// pending): TODAY's correct end state with the toggle ON is exactly
    /// `.unavailable("the vault is not a git repository")`.
    private func makePlainVaultDirectory() throws -> (root: URL, persistence: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft49-plain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Tasks", isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Logs", isDirectory: true),
            withIntermediateDirectories: true)
        let persistence = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft49-persist-\(UUID().uuidString)", isDirectory: true)
        return (root, persistence)
    }

    private func makeModel(
        vaultRoot: URL, persistenceDirectory: URL, syncEnabled: Bool,
        presetRemote: String? = "file:///tmp/ft49-plain-origin.git"
    ) throws -> (model: AppModel, settings: AppSettings) {
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: "ft49-model-\(UUID().uuidString)"))
        var settings = AppSettings(defaults: defaults)
        settings.vaultPath = vaultRoot.path
        settings.vaultSyncEnabled = syncEnabled
        if let presetRemote {
            settings.vaultSyncRemote = presetRemote
        }
        let model = AppModel(
            settings: settings,
            persistenceDirectory: persistenceDirectory,
            // The launch-pull is skipped instantly (unhealthy: no .git) —
            // a watchdog-bounded honest launch either way.
            syncPullInterval: 3600)
        return (model, settings)
    }

    func testToggleOnOverUninitializedVaultSurfacesThePinnedUnavailableState()
        async throws
    {
        let directories = try makePlainVaultDirectory()
        let made = try makeModel(
            vaultRoot: directories.root,
            persistenceDirectory: directories.persistence,
            syncEnabled: true)
        let model = made.model
        await model.bootstrap()

        // The [Health] machine-fact pin: no errors, no crash, and the row's
        // precondition state is EXACTLY the not-a-git-repository reason.
        XCTAssertEqual(
            model.syncHealth,
            .unavailable(reason: "the vault is not a git repository"))
        XCTAssertEqual(
            AppModel.syncHealthLine(for: model.syncHealth),
            "Sync unavailable — the vault is not a git repository.")

        // The row's display (#57): a stored NON-GitHub value (this test's
        // hermetic file:// stand-in) displays AS STORED (that is what the
        // engine uses), and the STORED value stays exactly as set.
        XCTAssertEqual(model.syncRemoteEntry, "file:///tmp/ft49-plain-origin.git")
        XCTAssertEqual(
            made.settings.vaultSyncRemote, "file:///tmp/ft49-plain-origin.git")

        // The #49 sheet plumbing: the request flag mirrors the #45 model
        // exactly (the sheet NEVER refuses — no AppPhase case involved).
        XCTAssertFalse(model.isSyncSheetRequested)
        model.requestSyncSheet()
        XCTAssertTrue(model.isSyncSheetRequested)
        model.clearSyncSheetRequest()
        XCTAssertFalse(model.isSyncSheetRequested)

        // Persisted-toggle OFF through the pinned write path: the health
        // returns to the honest `.disabled` and the setting sticks.
        await model.setSyncEnabled(false)
        XCTAssertEqual(model.syncHealth, .disabled)
        XCTAssertFalse(model.isSyncEnabled)

        // The remote-URL write path persists AS-TYPED (immediately)…
        try FileManager.default.createDirectory(
            at: directories.root.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: "ft49-remote-\(UUID().uuidString)"))
        var settings = AppSettings(defaults: defaults)
        settings.vaultPath = directories.root.path
        XCTAssertNil(settings.vaultSyncRemote)
        // …and the field is EMPTY while unset (a model over an
        // UNSET-remote suite; issue #57: nothing is pre-filled).
        let secondMade = try makeModel(
            vaultRoot: directories.root,
            persistenceDirectory: directories.persistence,
            syncEnabled: false, presetRemote: nil)
        let secondModel = secondMade.model
        XCTAssertEqual(secondModel.syncRemoteEntry, "")
        XCTAssertEqual(
            AppModel.syncRemotePlaceholder, "https://github.com/<you>/<your-vault>")
    }

    // MARK: - The 2026-09-20 amendment, Delta 2: the remote field speaks GitHub

    func testNormalizationAcceptsEveryPinnedFormToTheExactSSHRemote() {
        let expected = "git@github.com:example-user/example-vault.git"
        let acceptedForms = [
            "https://github.com/example-user/example-vault",
            "https://github.com/example-user/example-vault/",
            "https://github.com/example-user/example-vault.git",
            "git@github.com:example-user/example-vault.git",
            "git@github.com:example-user/example-vault",
            "  https://github.com/example-user/example-vault  ",
        ]
        for form in acceptedForms {
            XCTAssertEqual(
                AppModel.normalizedSyncRemote(form), .ssh(expected),
                "form: \(form)")
        }
        // Any of the user's repos, not only the example one:
        XCTAssertEqual(
            AppModel.normalizedSyncRemote("https://github.com/someone/Their-Repo_2"),
            .ssh("git@github.com:someone/Their-Repo_2.git"))
    }

    func testNormalizationRefusesEveryGarbageClass() {
        let garbageClasses = [
            "",
            "   ",
            "not a link",
            "http://github.com/example-user/example-vault",
            "ftp://github.com/example-user/example-vault",
            "https://gitlab.com/example-user/example-vault",
            "https://github.com/example-user",
            "https://github.com/example-user/example vault",
            "https://github.com/example-user/example-vault/extra/deep",
            "git@github.com:example-user",
            "git@gitlab.com:example-user/example-vault.git",
            "ssh://git@github.com/example-user/example-vault.git",
        ]
        for garbage in garbageClasses {
            XCTAssertEqual(
                AppModel.normalizedSyncRemote(garbage), .unrecognized,
                "garbage: \(garbage)")
        }
    }

    func testUnrecognizedRemoteMessageIsThePinnedExactString() {
        XCTAssertEqual(
            AppModel.unrecognizedSyncRemoteMessage,
            "That doesn't look like a GitHub link")
        XCTAssertEqual(
            SyncVaultSettingsView.unrecognizedRemoteMessage,
            "That doesn't look like a GitHub link")
    }

    func testSetSyncRemotePersistsOnlyNormalizedSSHAndKeepsLastGoodValue()
        async throws
    {
        let directories = try makePlainVaultDirectory()
        let made = try makeModel(
            vaultRoot: directories.root,
            persistenceDirectory: directories.persistence,
            syncEnabled: false)
        let model = made.model

        // The browser-page form (what the user pastes)…
        let saved = await model.setSyncRemote(
            "https://github.com/example-user/example-vault")
        // …persists the EXACT SSH remote (the #14 cross-instance witness:
        // a fresh wrapper over the SAME suite reads the stored value).
        XCTAssertEqual(
            saved, .saved("git@github.com:example-user/example-vault.git"))
        XCTAssertEqual(
            made.settings.vaultSyncRemote,
            "git@github.com:example-user/example-vault.git")
        let witness = made.settings

        // …garbage persists NOTHING: the last good value stands.
        let garbage = await model.setSyncRemote("definitely not a link")
        XCTAssertEqual(garbage, .unrecognized)
        XCTAssertEqual(
            witness.vaultSyncRemote, "git@github.com:example-user/example-vault.git")

        // The SSH form still round-trips unchanged (the existing form).
        let ssh = await model.setSyncRemote("git@github.com:example-user/example-vault.git")
        XCTAssertEqual(
            ssh, .saved("git@github.com:example-user/example-vault.git"))
        XCTAssertEqual(
            witness.vaultSyncRemote, "git@github.com:example-user/example-vault.git")

        // Issue #57 (amends #49): blank/whitespace CLEARS the stored value
        // (no default to fall back to; the empty field means "no remote").
        let blank = await model.setSyncRemote("   ")
        XCTAssertEqual(blank, .cleared)
        XCTAssertNil(witness.vaultSyncRemote)
        _ = await model.setSyncRemote("https://github.com/example-user/example-vault")
        let empty = await model.setSyncRemote("")
        XCTAssertEqual(empty, .cleared)
        XCTAssertNil(witness.vaultSyncRemote)
        XCTAssertEqual(witness.resolvedVaultSyncRemote(), "")
    }

    func testDisplayFormMapsStoredSSHToHTTPSAndIsEmptyWhenUnset() {
        XCTAssertEqual(AppModel.syncRemoteDisplayForm(nil), "")
        XCTAssertEqual(AppModel.syncRemoteDisplayForm("   "), "")
        // A stored non-blank, non-GitHub value displays AS STORED (trimmed).
        XCTAssertEqual(
            AppModel.syncRemoteDisplayForm("file:///tmp/x.git"), "file:///tmp/x.git")
        XCTAssertEqual(
            AppModel.syncRemoteDisplayForm("  file:///tmp/x.git "), "file:///tmp/x.git")
        XCTAssertEqual(
            AppModel.syncRemoteDisplayForm("git@github.com:example-user/example-vault.git"),
            "https://github.com/example-user/example-vault")
        XCTAssertEqual(
            AppModel.syncRemoteDisplayForm("git@github.com:someone/repo.git"),
            "https://github.com/someone/repo")
        XCTAssertEqual(
            AppModel.httpsDisplayForm(
                fromSSH: "git@github.com:example-user/example-vault.git"),
            "https://github.com/example-user/example-vault")
        XCTAssertNil(AppModel.httpsDisplayForm(fromSSH: "not ssh"))
    }

    func testPrefillMatrixUnsetBlankAndSet() async throws {
        // Unset: EMPTY (issue #57: nothing is pre-filled).
        let directories = try makePlainVaultDirectory()
        let unsetModel = try makeModel(
            vaultRoot: directories.root,
            persistenceDirectory: directories.persistence,
            syncEnabled: false, presetRemote: nil).model
        XCTAssertEqual(unsetModel.syncRemoteEntry, "")

        // Stored SSH: DISPLAYS as the HTTPS form (storage unchanged).
        let setModel = try makeModel(
            vaultRoot: directories.root,
            persistenceDirectory: directories.persistence,
            syncEnabled: false,
            presetRemote: "git@github.com:example-user/example-vault.git").model
        XCTAssertEqual(
            setModel.syncRemoteEntry, "https://github.com/example-user/example-vault")

        // Stored non-GitHub value (hand-set): displays AS STORED.
        let handSetModel = try makeModel(
            vaultRoot: directories.root,
            persistenceDirectory: directories.persistence,
            syncEnabled: false).model
        XCTAssertEqual(handSetModel.syncRemoteEntry, "file:///tmp/ft49-plain-origin.git")
    }

    // MARK: - Issue #57: the toggle lock rule + the blank-draft rule + placeholder

    func testToggleLockRuleExemptsOnlyTheNoRemoteReason() {
        XCTAssertFalse(AppModel.isSyncToggleControlDisabled(
            for: .unavailable(reason: SyncHealthEvaluator.noRemoteReason)))
        XCTAssertTrue(AppModel.isSyncToggleControlDisabled(
            for: .unavailable(reason: "the vault is not a git repository")))
        XCTAssertFalse(AppModel.isSyncToggleControlDisabled(for: .disabled))
        XCTAssertFalse(AppModel.isSyncToggleControlDisabled(for: .idle))
        XCTAssertFalse(AppModel.isSyncToggleControlDisabled(for: .error("x")))
    }

    func testBlankDraftIsNotGarbageButGarbageStillIs() {
        XCTAssertFalse(AppModel.isUnrecognizedSyncRemoteDraft(""))
        XCTAssertFalse(AppModel.isUnrecognizedSyncRemoteDraft("   "))
        XCTAssertTrue(AppModel.isUnrecognizedSyncRemoteDraft("not a link"))
        XCTAssertFalse(AppModel.isUnrecognizedSyncRemoteDraft(
            "https://github.com/example-user/example-vault"))
        // The pure contract is unchanged: blank stays unrecognized.
        XCTAssertEqual(AppModel.normalizedSyncRemote(""), .unrecognized)
    }

    func testNoRemoteReasonIsTheExistingTextAndRendersTheExactLine() {
        XCTAssertEqual(
            SyncHealthEvaluator.noRemoteReason, "no sync remote is configured")
        XCTAssertEqual(
            AppModel.syncHealthLine(
                for: .unavailable(reason: SyncHealthEvaluator.noRemoteReason)),
            "Sync unavailable — no sync remote is configured.")
    }

    func testFreshInstallHasAnEmptyFieldAndNoAppSettingsDefaultRemote() throws {
        let settings = try AppSettings(suiteName: "ft57-fresh-\(UUID().uuidString)")
        XCTAssertNil(settings.vaultSyncRemote)
        XCTAssertEqual(settings.resolvedVaultSyncRemote(), "")
        XCTAssertEqual(AppModel.syncRemoteDisplayForm(settings.vaultSyncRemote), "")
    }

    // MARK: - The 2026-09-20 amendment, Delta 3: the pinned instructions

    func testInstructionSentencesAreThePinnedExactStrings() {
        XCTAssertEqual(
            SyncVaultSettingsView.instructionBackup,
            "This quietly saves every change in your vault to your private "
                + "GitHub backup, about a minute after you make it.")
        XCTAssertEqual(
            SyncVaultSettingsView.instructionLink,
            "To get the link: open your repo on GitHub → click the green Code "
                + "button → copy the HTTPS link → paste it here.")
        XCTAssertEqual(
            SyncVaultSettingsView.instructionSwitchOff,
            "You can switch sync off at any time — the app keeps working "
                + "exactly as it does today.")
    }

    // MARK: - The 2026-09-20 amendment, Delta 1: the always-exitable sheet

    func testSheetRequestFlagClearsOnDismissalAndDoesNotRePresent() async throws {
        // The Done button's action IS this ONE model path (the same path
        // the shell binding's set-side uses) — present → dismiss → false,
        // and a fresh present works again (the sheet does not stick).
        let directories = try makePlainVaultDirectory()
        let model = try makeModel(
            vaultRoot: directories.root,
            persistenceDirectory: directories.persistence,
            syncEnabled: false).model
        XCTAssertFalse(model.isSyncSheetRequested)
        model.requestSyncSheet()
        XCTAssertTrue(model.isSyncSheetRequested)
        model.clearSyncSheetRequest()
        XCTAssertFalse(model.isSyncSheetRequested)
        model.requestSyncSheet()
        XCTAssertTrue(model.isSyncSheetRequested)
        model.clearSyncSheetRequest()
        XCTAssertFalse(model.isSyncSheetRequested)
    }
}
