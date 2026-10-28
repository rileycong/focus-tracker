import SwiftUI

/// What the rename project sheet presents (issue #54): the project to rename,
/// carrying its current name. `Identifiable` for `.sheet(item:)` (a fresh ID
/// per presentation).
struct RenameProjectRequest: Identifiable {
    let id = UUID()
    let oldName: String
}

/// The rename project form (issue #54): one sheet capturing the new project
/// name, with validation (non-empty trimmed, collision check), persisting
/// through `AppModel.renameProject(from:to:)`. The form never touches the
/// filesystem directly (PRD §3.1, §18).
///
/// # Presentation (documented choice)
/// A **sheet** over the Tasks window: the dimmed inventory stays visible
/// behind the sheet for context. Enter triggers the default (rename) action
/// — it only closes the form when valid — and Esc cancels.
///
/// # Validation (pinned, issue #54)
/// - New name must be non-empty (trimmed).
/// - Case-insensitive collision with an existing project name (excluding the
///   old name itself) shows an inline error: "A project with this name
///   already exists."
/// - If the new name equals the old name (trimmed, case-sensitive), the
///   Rename button is disabled (no-op).
struct RenameProjectView: View {
    /// The original project name to rename from.
    let oldName: String
    /// Distinct project names across the current inventory (for collision
    /// detection).
    let knownProjectNames: [String]
    /// Persists the rename through `AppModel.renameProject(from:to:)`. Thrown
    /// errors surface inline.
    let onRename: (String, String) async throws -> Void

    @Environment(\.dismiss) private var dismiss

    @State var newName: String
    @State private var isRenaming = false
    @State var renameErrorMessage: String?

    init(
        oldName: String,
        knownProjectNames: [String],
        onRename: @escaping (String, String) async throws -> Void
    ) {
        self.oldName = oldName
        self.knownProjectNames = knownProjectNames
        self.onRename = onRename
        _newName = State(initialValue: oldName)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
                .overlay(DesignTokens.divider)
            VStack(alignment: .leading, spacing: DesignTokens.spacingM) {
                nameField
                if let validationError = validationError {
                    inlineError(validationError)
                }
                if let renameErrorMessage {
                    inlineError(renameErrorMessage)
                }
            }
            .padding(DesignTokens.spacingL)
            Divider()
                .overlay(DesignTokens.divider)
            footer
        }
        .background(DesignTokens.background)
        .frame(width: 400)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Rename Project"))
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Rename Project")
                .font(DesignTokens.sheetHeaderFont)
            Spacer()
        }
        .padding(DesignTokens.spacingL)
    }

    // MARK: - Fields

    private var nameField: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingXS) {
            Text("Project Name")
                .font(DesignTokens.statusGroupFont)
            TextField("Project name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { performRename() }
                .accessibilityLabel(Text("Project name"))
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Rename") {
                performRename()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canRename)
            .buttonStyle(.borderedProminent)
        }
        .padding(DesignTokens.spacingL)
    }

    // MARK: - Validation

    /// The inline validation error, if any (non-empty trimmed check,
    /// collision with existing project — case-insensitive, excluding the old
    /// name). nil = valid.
    var validationError: String? {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // Case-insensitive collision check, excluding the old name itself
        let collides = knownProjectNames.contains { candidateName in
            candidateName.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
                && candidateName.localizedCaseInsensitiveCompare(oldName) != .orderedSame
        }
        return collides ? "A project with this name already exists." : nil
    }

    /// Whether the Rename button is enabled: the trimmed name is non-empty,
    /// different from the old name (case-sensitive), and has no collision.
    var canRename: Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        guard trimmed != oldName else { return false }
        return validationError == nil
    }

    // MARK: - Actions

    func performRename() {
        guard canRename else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        isRenaming = true
        renameErrorMessage = nil
        Task {
            do {
                try await onRename(oldName, trimmed)
                dismiss()
            } catch {
                renameErrorMessage = error.localizedDescription
                isRenaming = false
            }
        }
    }

    // MARK: - Error surface

    private func inlineError(_ message: String) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.spacingXS) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DesignTokens.warning)
            Text(message)
                .font(DesignTokens.annotationFont)
                .foregroundStyle(.secondary)
        }
    }
}
