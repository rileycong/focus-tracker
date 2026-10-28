import SwiftUI

/// The #19 session-start sheet presentation request, wired by `TasksView`
/// like the #16/#17 sheet requests. Fresh identity per presentation (the
/// `let id = UUID()` pattern of `TaskFormRequest`), plus the optional
/// preselected target for the row context-menu entry points.
///
/// Issue #34 generalizes the pre-selection: with no row hand-off (the
/// toolbar entry passes nil), `TasksView` composes the model's #34
/// last-session target (`lastSessionTargetID`) — every entry point
/// pre-selects the previous session's task when it is still planning-
/// eligible; the eligibility filter lives in
/// `SessionStartPicker.preselectedTargetID(requesting:in:)`, applied by
/// the sheet at construction as its initial selection state (issue #42:
/// seeded, not onAppear-driven).
struct SessionStartRequest: Identifiable {
    let id = UUID()
    /// The task/subtask ID pre-selected in the picker (issue #19
    /// nice-to-have): a row's context menu hands over that row's ID; the
    /// toolbar entry passes nil. An ID that is not planning-eligible (the
    /// context menus only offer the action on eligible rows anyway, but an
    /// inventory may change in between) simply leaves the picker without a
    /// selection — never a crash.
    let preselectedTargetID: UUID?
}

/// The session-start sheet (issue #19, PRD §8.6, §9.1, §9.2): from here the
/// user either (a) **picks an eligible existing task/subtask** — the pure
/// `SessionStartPicker` grouping over the plain inventory, searchable — or
/// (b) **creates an ad-hoc task inline** (title + at least one category,
/// PRD §8.6, reusing #16's `TaskFormState` category token logic verbatim),
/// then starts a focus session with a configurable duration (default 25
/// minutes, PRD §9.2).
///
/// # Wiring
/// The view performs **no model work itself**: the `onStart`/`onStartAdHoc`
/// closures are wired by `TasksView` to `AppModel.startSession` /
/// `AppModel.startAdHocSession`. Every typed refusal (`SessionStartOutcome
/// .refused`) surfaces **inline in the sheet** — the sheet stays open and
/// shows the reason — while a thrown I/O error (not a user decision) is
/// shown inline through its localized description for the same reason.
/// `.started` dismisses the sheet; the app phase swap to the timer screen
/// is the model's job.
///
/// # Pre-selection (issues #34 + #42)
/// The caller's `preselectedTargetID` (a row hand-off, else the last
/// session's target) seeds the picker's selection as INITIAL `@State` at
/// construction, eligibility-filtered through the pure
/// `SessionStartPicker.preselectedTargetID(requesting:in:)` (#34's
/// composition over the unchanged #9/#41 rule). Construction-time seeding
/// is the #42 fix — see the init's root-cause note.
///
/// # Duration field (documented engineer's choice)
/// A plain minutes text field defaulting to "25". Invalid input (empty,
/// non-numeric, zero, negative, fractional — `parseDurationMinutes`) both
/// disables Start **and** shows an inline hint: the issue pins
/// "prevented or typed-refused", and prevention needs no extra refusal case
/// in the model's pinned refusal order. No fixed preset buttons (PRD §9.2).
struct SessionStartView: View {

    /// The sheet's two modes: pick an existing eligible target, or create
    /// the ad-hoc task inline (PRD §8.6's two paths).
    enum Mode: Hashable {
        case pick
        case create
    }

    /// The inventory snapshot to pick from (`AppModel.tasks` at presentation
    /// time — the sheet is short-lived; no live sync needed).
    let tasks: [TaskItem]
    /// The category combobox's suggestion list (#16 pattern:
    /// `TaskFormState.knownCategoryNames(in:)`, gathered by `TasksView`).
    let knownCategoryNames: [String]
    /// The preselected target ID: a row's context-menu hand-off (#19), or
    /// the caller's #34 composition (row hand-off, else the last session's
    /// target) — eligibility-filtered at construction into the sheet's
    /// initial selection state (see the init).
    let preselectedTargetID: UUID?
    /// The start handler over an existing target (→ `AppModel.startSession`).
    let onStart: (UUID, TimeInterval) async throws -> AppModel.SessionStartOutcome
    /// The ad-hoc start handler (→ `AppModel.startAdHocSession`).
    let onStartAdHoc: (String, [String], TimeInterval) async throws
        -> AppModel.SessionStartOutcome

    /// Cancel behavior (issue #34): the phase-driven session-start
    /// presentation is not a dismissal context, so the app shell hands
    /// over `AppModel.cancelSessionStart()`; the #19 Tasks-presented
    /// sheet passes nothing and keeps the `dismiss()` fallback.
    var onCancel: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .pick
    @State private var query = ""
    /// The picker's selection (issue #42): SEEDED at construction through
    /// `initialSelectedTargetID(requesting:in:)` — the eligibility-filtered
    /// pre-selection — so every fresh presentation derives it from the
    /// inputs the caller passes; the row buttons are the only later
    /// writers.
    @State private var selectedTargetID: UUID?
    /// The ad-hoc form state — #16's `TaskFormState` reused wholesale: only
    /// the title and category fields are exposed (PRD §8.6: "no other
    /// fields — optional metadata is added later via the normal forms"), and
    /// the status is pinned to In Progress by the model's ad-hoc path.
    @State private var adHoc = TaskFormState()
    @State private var durationText = "25"
    @State private var inlineMessage: String?
    @State private var isStarting = false

    // MARK: - Init

    /// Issue #42: the pre-selection is the picker's INITIAL `@State`, seeded
    /// here at construction from the caller's request and the presented
    /// inventory snapshot through the pure
    /// `initialSelectedTargetID(requesting:in:)` — NOT assigned in
    /// `onAppear`.
    ///
    /// **Root cause this fixes (user report, #42):** the sheet used to
    /// assign `selectedTargetID` in an `onAppear` guarded by
    /// `if selectedTargetID == nil`, which silently assumed every
    /// presentation delivers `onAppear` with fresh, nil state. On the
    /// phase-driven presentation (`.breakActive → .sessionStart`) that
    /// assumption broke for a RE-presented sheet — post-break, after an
    /// earlier session-start presentation in the same app run: the
    /// re-presented sheet could start with retained `@State` (a stale
    /// non-nil `selectedTargetID` makes the guard skip the assignment) or,
    /// on the unfocused-alarm focus-back path, skip `onAppear` entirely
    /// (the phase swap lands inside the `didBecomeActive` transaction, so
    /// the sheet presents mid-activation) — either way the still-eligible
    /// previous task never pre-selected. Seeding the initial state here
    /// makes every fresh presentation derive the selection from the
    /// CURRENT model state at construction, which always runs for a new
    /// presentation, independent of appear timing or retained state. The
    /// eligibility rule itself is unchanged (#34/#41 as-is), so the
    /// no-preselection cases (Done/Blocked/Dropped, hidden ancestor,
    /// absent ID, no request) keep leaving the picker unselected by
    /// design.
    init(
        tasks: [TaskItem],
        knownCategoryNames: [String],
        preselectedTargetID: UUID?,
        onStart: @escaping (UUID, TimeInterval) async throws
            -> AppModel.SessionStartOutcome,
        onStartAdHoc: @escaping (String, [String], TimeInterval) async throws
            -> AppModel.SessionStartOutcome,
        onCancel: (() -> Void)? = nil
    ) {
        self.tasks = tasks
        self.knownCategoryNames = knownCategoryNames
        self.preselectedTargetID = preselectedTargetID
        self.onStart = onStart
        self.onStartAdHoc = onStartAdHoc
        self.onCancel = onCancel
        _selectedTargetID = State(
            initialValue: Self.initialSelectedTargetID(
                requesting: preselectedTargetID, in: tasks))
    }

    // MARK: - Derived state

    private var eligibleTargets: [SessionStartTarget] {
        SessionStartPicker.eligibleTargets(in: tasks)
    }

    private var sections: [SessionStartSection] {
        SessionStartPicker.sections(
            from: eligibleTargets.filter { SessionStartPicker.matches($0, query: query) })
    }

    private var selectedTarget: SessionStartTarget? {
        eligibleTargets.first { $0.id == selectedTargetID }
    }

    /// The parsed duration in minutes (nil = invalid — Start disabled).
    private var durationMinutes: Int? {
        Self.parseDurationMinutes(durationText)
    }

    private var canStart: Bool {
        guard !isStarting, durationMinutes != nil else { return false }
        switch mode {
        case .pick: return selectedTarget != nil
        case .create: return adHoc.isValid
        }
    }

    /// The category combobox's suggestions: the inventory's known names the
    /// form has not committed yet (#16 combobox pattern).
    private var categorySuggestions: [String] {
        knownCategoryNames.filter { !adHoc.containsCategory(named: $0) }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Start mode", selection: $mode) {
                Text("Pick a task").tag(Mode.pick)
                Text("New ad-hoc task").tag(Mode.create)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(DesignTokens.spacingM)

            switch mode {
            case .pick:
                pickerSection
            case .create:
                adHocSection
            }

            Divider()
            footer
        }
        .frame(width: 460, height: 500)
        .background(DesignTokens.background)
    }

    // MARK: - Mode (a): the eligible picker

    private var pickerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search tasks…", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, DesignTokens.spacingM)
                .padding(.bottom, DesignTokens.spacingS)
            if sections.isEmpty {
                ContentUnavailableView(
                    "No eligible tasks",
                    systemImage: "tray",
                    description: Text(
                        "To Do or In Progress tasks and subtasks can be started. "
                            + "Subtasks under a Done, Dropped or Blocked parent are "
                            + "hidden — reveal the parent in the Tasks view with "
                            + "“Show completed/dropped”. Or create an ad-hoc task "
                            + "instead."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(sections) { section in
                            sectionHeader(section)
                            ForEach(section.groups) { group in
                                groupHeader(group)
                                ForEach(group.targets) { target in
                                    targetRow(target)
                                }
                            }
                            if section.id != sections.last?.id {
                                Rectangle()
                                    .fill(DesignTokens.divider)
                                    .frame(height: 1)
                                    .padding(.vertical, DesignTokens.spacingS)
                            }
                        }
                    }
                    .padding(.horizontal, DesignTokens.spacingM)
                    .padding(.bottom, DesignTokens.spacingM)
                }
            }
        }
    }

    private func sectionHeader(_ section: SessionStartSection) -> some View {
        HStack {
            Text(section.displayName)
                .font(DesignTokens.selectorProjectTitleFont)
            Spacer()
            Text("\(section.totalCount)")
                .font(DesignTokens.tasksMetadataFont)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, DesignTokens.spacingS)
    }

    private func groupHeader(_ group: SessionStartGroup) -> some View {
        HStack(spacing: DesignTokens.spacingS) {
            Circle()
                .fill(DesignTokens.statusColor(group.status))
                .frame(
                    width: DesignTokens.tasksStatusDotSize,
                    height: DesignTokens.tasksStatusDotSize)
            Text(group.status.rawValue)
                .font(DesignTokens.selectorStatusTitleFont)
            Spacer()
            Text("\(group.targets.count)")
                .font(DesignTokens.tasksMetadataFont)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, DesignTokens.spacingXS)
        .padding(.leading, DesignTokens.pickerStatusIndent)
    }

    private func targetRow(_ target: SessionStartTarget) -> some View {
        Button {
            selectedTargetID = target.id
        } label: {
            HStack(spacing: DesignTokens.spacingS) {
                Circle()
                    .fill(DesignTokens.statusColor(target.status))
                    .frame(
                        width: DesignTokens.tasksStatusDotSize,
                        height: DesignTokens.tasksStatusDotSize)
                    .accessibilityLabel(Text(target.status.rawValue))
                // #40 amendment 2: picker rows are title-only — the indent
                // ladder carries the hierarchy in the narrow sheet. (The
                // subtask parent-task subtitle was removed here ONLY; the
                // model's `parentTaskTitle` stays, e.g. for search.)
                Text(target.title)
                    .font(
                        target.isTask
                            ? DesignTokens.selectorParentTaskTitleFont
                            : DesignTokens.selectorSubtaskTitleFont)
                    .foregroundStyle(target.isTask ? Color.primary : Color.secondary)
                    .lineLimit(1)
                Spacer(minLength: DesignTokens.spacingM)
            }
            .padding(.vertical, DesignTokens.tasksRowVerticalPadding)
            .padding(.horizontal, DesignTokens.spacingS)
            .background(
                selectedTargetID == target.id
                    ? DesignTokens.selectionBackground : Color.clear)
            .cornerRadius(DesignTokens.cornerRadius)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, DesignTokens.pickerTaskIndent(depth: target.depth))
        .accessibilityAddTraits(
            selectedTargetID == target.id ? AccessibilityTraits.isSelected : [])
    }

    // MARK: - Mode (b): the ad-hoc task

    /// Mode (b)'s form (#40 amendments 3 + 4): the entry fields sit right
    /// under the segmented picker — separated by the dedicated
    /// `adHocPickerToFieldsSpacing` break (amendment 4, on top of the
    /// picker's own padding) — and the leftover height of the fixed
    /// 460×500 sheet distributes as two equal flexible gaps around the
    /// explanatory footnote, so the footnote/duration territory fills the
    /// lower half instead of pooling as dead space under the fields.
    ///
    /// Mechanism: a plain VStack inside a ScrollView whose content declares
    /// a `minHeight:` of the measured height — the standard SwiftUI pattern
    /// that lets flexible `Spacer`s expand to exactly the leftover height
    /// while keeping the amendment-2 no-clipping guarantee: the gaps
    /// collapse to their `adHocFormSectionSpacing` floor first, and only a
    /// genuinely overflowing chip count scrolls (the amendment-2 Form
    /// sections backed the same scroll behavior). The field row paddings of
    /// amendment 2 are superseded by this distribution — the fields keep
    /// their approved `.controlSize(.large)` plus the amendment-4
    /// `adHocFieldFont` (one step above body), the 8 pt category↔chips hug,
    /// the 20 pt side inset, and chips scaled to stay coherent
    /// (`adHocChipFont`/`adHocChipRemoveIconSize`); the footnote's 8 pt
    /// vertical padding grows into the surrounding flexible gaps. Styling
    /// only: `categoryField`'s keyboard/commit logic is untouched.
    private var adHocSection: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(
                        alignment: .leading,
                        spacing: DesignTokens.adHocFormFieldSpacing
                    ) {
                        TextField("Title", text: $adHoc.title)
                            .font(DesignTokens.adHocFieldFont)
                            .controlSize(.large)
                        VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
                            categoryField
                            if !adHoc.categoryNames.isEmpty {
                                categoryChips
                            }
                        }
                    }
                    .padding(.top, DesignTokens.adHocPickerToFieldsSpacing)
                    .padding(.horizontal, DesignTokens.spacingL)
                    Spacer(minLength: DesignTokens.adHocFormSectionSpacing)
                    Text(
                        "Title and at least one category (PRD §8.6). The task is "
                            + "created In Progress in the vault; add the optional "
                            + "details later through the task's Edit form.")
                        .font(DesignTokens.annotationFont)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, DesignTokens.spacingL)
                    Spacer(minLength: DesignTokens.adHocFormSectionSpacing)
                }
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
        }
    }

    /// The #16 category combobox pattern, compact: Enter commits the whole
    /// draft, commas commit complete segments, and the menu offers the
    /// inventory's known names not yet committed. The field and its
    /// suggestion-menu chevron share the amendment-4 `adHocFieldFont` so
    /// the row reads as one scaled control.
    private var categoryField: some View {
        HStack(spacing: DesignTokens.spacingS) {
            TextField("Category (Enter or comma to add)", text: $adHoc.categoryDraft)
                .font(DesignTokens.adHocFieldFont)
                .controlSize(.large)
                .onSubmit { adHoc.commitWholeDraft() }
                .onChange(of: adHoc.categoryDraft) { _, _ in
                    adHoc.commitCompletedCategorySegments()
                }
            if !categorySuggestions.isEmpty {
                Menu {
                    ForEach(categorySuggestions, id: \.self) { name in
                        Button(name) { adHoc.commitCategory(name) }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(DesignTokens.adHocFieldFont)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Suggested categories from the vault")
            }
        }
    }

    private var categoryChips: some View {
        FlowChips(names: adHoc.categoryNames) { name in
            adHoc.removeCategory(name)
        }
    }

    // MARK: - Footer (duration + refusal surface + actions)

    private var footer: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingXS) {
            if let message = inlineMessage {
                Text(message)
                    .font(DesignTokens.annotationFont)
                    .foregroundStyle(DesignTokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                HStack(spacing: DesignTokens.spacingXS) {
                    Text("Duration (min):")
                        .font(DesignTokens.annotationFont)
                        .foregroundStyle(.secondary)
                    TextField("25", text: $durationText)
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                }
                Spacer()
                Button("Cancel") {
                    // Issue #34: the phase-driven presentation routes
                    // through the caller's onCancel (the phase owns the
                    // presentation); the Tasks-presented sheet keeps the
                    // plain dismiss.
                    if let onCancel { onCancel() } else { dismiss() }
                }
                    .keyboardShortcut(.cancelAction)
                Button {
                    start()
                } label: {
                    if isStarting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Start", systemImage: "play.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStart)
            }
        }
        .padding(.horizontal, DesignTokens.spacingL)
        .padding(.vertical, DesignTokens.spacingM)
    }

    // MARK: - Actions

    private func start() {
        guard let minutes = durationMinutes, !isStarting else { return }
        let seconds = TimeInterval(minutes) * 60
        isStarting = true
        inlineMessage = nil
        let adHocTitle = adHoc.title
        let adHocCategories = adHoc.categoryNames
        Task {
            do {
                let outcome: AppModel.SessionStartOutcome
                switch mode {
                case .pick:
                    guard let target = selectedTarget else {
                        isStarting = false
                        return
                    }
                    outcome = try await onStart(target.id, seconds)
                case .create:
                    outcome = try await onStartAdHoc(adHocTitle, adHocCategories, seconds)
                }
                finish(outcome)
            } catch {
                // A thrown I/O failure (not a user decision) surfaces inline
                // for the same reason the typed refusals do.
                isStarting = false
                inlineMessage = error.localizedDescription
            }
        }
    }

    private func finish(_ outcome: AppModel.SessionStartOutcome) {
        isStarting = false
        switch outcome {
        case .started:
            dismiss()
        case .refused(let refusal):
            inlineMessage = Self.refusalMessage(refusal)
        }
    }

    // MARK: - Pure helpers (unit-tested)

    /// The sheet's initial picker selection (issue #42): the caller's
    /// requested target — the #34 last-session target for the phase-driven
    /// and manual entries, a row's ID for the context-menu entry — when it
    /// is planning-eligible in the presented inventory, else nil (no
    /// selection). A pure delegation to
    /// `SessionStartPicker.preselectedTargetID(requesting:in:)` — the #34
    /// composition over the UNCHANGED #9/#41 eligibility rule — so the
    /// construction-time seed (see the init) is unit-testable like the
    /// sheet's other pure helpers: Done/Blocked/Dropped, a hidden
    /// ancestor (#41), an absent ID and no request all resolve to nil by
    /// pinned design, while an eligible To Do/In Progress task or subtask
    /// (any depth, all-active ancestors) resolves to itself.
    static func initialSelectedTargetID(
        requesting requestedID: UUID?, in tasks: [TaskItem]
    ) -> UUID? {
        SessionStartPicker.preselectedTargetID(requesting: requestedID, in: tasks)
    }

    /// The duration field's parse rule (issue #19): a positive whole number
    /// of minutes; nil for anything else (empty, non-numeric, zero,
    /// negative, fractional). Documented choice: invalid input *prevents*
    /// starting (Start disabled + inline hint) rather than adding a refusal
    /// case to the model's pinned order.
    static func parseDurationMinutes(_ raw: String) -> Int? {
        guard
            let value = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
            value >= 1
        else { return nil }
        return value
    }

    /// The user-facing inline copy for each typed refusal (the sheet stays
    /// open and shows the reason — never an alert storm, #19).
    static func refusalMessage(_ refusal: AppModel.SessionStartRefusal) -> String {
        switch refusal {
        case .sessionAlreadyActive:
            return "A session is already running."
        case .sessionEndingUnresolved:
            return
                "A session just ended — finish the wrap-up form before starting a new one."
        case .breakActive:
            return
                "A break is running — finish or end the break before starting a session."
        case .postSessionChoiceActive:
            return
                "Choose what's next (start a session or take a break) before starting one here."
        case .vaultNotConfigured:
            return "No vault is configured. Choose a vault folder first."
        case .pendingRecoveryUnresolved:
            return
                "A recovered session is waiting to be resumed or ended. Resolve it before starting a new one."
        case .unknownTarget:
            return "That task is no longer in the inventory. Close this sheet and try again."
        case .targetRefused(_, .blocked):
            return "This item is Blocked — unblock it before starting a session."
        case .targetRefused(_, .dropped):
            return "This item is Dropped — restore it before starting a session."
        case .targetRefused(_, .alreadyDone):
            return "This item is already Done — nothing to work on."
        case .adHocTaskInvalid:
            return "An ad-hoc task needs a title and at least one category."
        case .adHocCreationFailed(let error):
            return "Could not save the ad-hoc task: \(error)"
        }
    }
}

/// A minimal wrapping chip row (the #16 form's category chip language,
/// compact enough for the sheet): each committed name as a capsule with a
/// remove button. #40 amendment 4: the chips render at the ad-hoc form's
/// own `adHocChipFont`/`adHocChipRemoveIconSize` scale so they stay
/// coherent with the one-step-up entry fields (the #16 forms keep the
/// shared `chipFont`/`chipRemoveIconSize`).
private struct FlowChips: View {
    let names: [String]
    let onRemove: (String) -> Void

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 90), alignment: .leading)],
            alignment: .leading,
            spacing: DesignTokens.spacingS
        ) {
            ForEach(names, id: \.self) { name in
                HStack(spacing: DesignTokens.spacingXS) {
                    Text(name)
                        .font(DesignTokens.adHocChipFont)
                        .lineLimit(1)
                    Button {
                        onRemove(name)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: DesignTokens.adHocChipRemoveIconSize))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Remove \(name)"))
                }
                .padding(.horizontal, DesignTokens.spacingS)
                .padding(.vertical, DesignTokens.spacingS)
                .background(DesignTokens.chipBackground)
                .cornerRadius(DesignTokens.cornerRadius)
            }
        }
    }
}
