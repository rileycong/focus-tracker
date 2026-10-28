import SwiftUI

/// The visual language of the app (issue #15, PRD §21: "dark, minimal, calm,
/// no dashboard feel"). One place for spacing, sizing, typography and the
/// dark-first palette so the views stay consistent and the PRD's direction is
/// enforced by construction. The app root additionally forces
/// `.preferredColorScheme(.dark)`, so the fixed (non-adaptive) colors below
/// always render against dark.
enum DesignTokens {

    // MARK: - Spacing

    static let spacingXS: CGFloat = 4
    static let spacingS: CGFloat = 8
    static let spacingM: CGFloat = 14
    static let spacingL: CGFloat = 20

    // MARK: - Sizing

    /// Diameter of the subtle status dot in a task row.
    static let statusDotSize: CGFloat = 8
    /// Vertical padding inside a task row.
    static let rowVerticalPadding: CGFloat = 7
    /// Corner radius for chips and the selection highlight.
    static let cornerRadius: CGFloat = 6
    /// Corner radius of the mini panel's floating card — a window shape, one
    /// calm step above the chip radius.
    static let panelCornerRadius: CGFloat = 12
    /// Countdown ring stroke width — shared by the full timer and the break
    /// screen so the two countdowns read as one visual language.
    static let ringLineWidth: CGFloat = 10
    /// Point size of the mini panel's countdown digits (fixed — the panel has
    /// a fixed content size, unlike the full timer's diameter-derived size).
    static let miniCountdownSize: CGFloat = 30
    /// Onboarding hero icon point size.
    static let emptyStateIconSize: CGFloat = 40
    /// Minimum height of the notes editor in both forms (one editor shape).
    static let notesEditorMinHeight: CGFloat = 80
    /// Disclosure chevron glyph size in task/subtask rows.
    static let chevronIconSize: CGFloat = 9
    /// Chip remove glyph size in the forms' category tokens.
    static let chipRemoveIconSize: CGFloat = 9

    // The shared hierarchy for both task selectors. Forms, timer surfaces,
    // and unrelated sheets keep their existing scale. The type ladder is an
    // even, clearly separated run (project 20 bold → status 17 semibold →
    // parent task 15 semibold → subtask 13 regular) shared by the Tasks
    // view and the session picker (#40 revision).
    //
    // The INDENT ladders are TWO deliberately scoped runs with the same
    // strict project → status → parent task → subtask order (#40
    // amendment 2):
    // - Tasks view (`selector*`, the approved amendment-1 wide ladder):
    //   0 → 20 → 48 → +24 per subtask depth — steps wide enough that no
    //   row-internal padding or system disclosure inset can visually
    //   invert the order.
    // - Session picker (`picker*`, below): 0 → 12 → 28 → +16 per subtask
    //   depth — tightened for the narrow 460 pt sheet, with the status →
    //   parent step (16 pt) still wider than the 10 pt row padding so the
    //   order cannot invert there either.
    static let selectorProjectTitleSize: CGFloat = 20
    static let selectorStatusTitleSize: CGFloat = 17
    static let selectorParentTaskTitleSize: CGFloat = 15
    static let selectorSubtaskTitleSize: CGFloat = 13
    static let tasksMetadataSize: CGFloat = 12
    static let tasksChipSize: CGFloat = 11
    static let tasksStatusDotSize: CGFloat = 9
    static let tasksChevronIconSize: CGFloat = 10
    /// Trailing-edge trash glyph of the #51 hover delete affordance — one
    /// step above the chevron so the affordance stays clearly legible while
    /// reading as row metadata, not a toolbar control.
    static let tasksDeleteIconSize: CGFloat = 11
    static let tasksRowVerticalPadding: CGFloat = 10
    /// Vertical gap between rows within a status group and between the
    /// title/metadata stack inside a row (#40 amendment 2 tightened the
    /// intra-group/intra-row rhythm; the row padding above stays at its
    /// approved scale).
    static let tasksRowSpacing: CGFloat = 3
    /// Vertical separation BETWEEN status groups inside a project section
    /// (#40 amendment 2): together with the status header's 4 pt vertical
    /// padding it reads as a ~12 pt break against the 3 pt intra-group
    /// rhythm, so the group boundary stays clearly legible.
    static let tasksStatusGroupSpacing: CGFloat = 8
    static let selectorProjectIndent: CGFloat = 0
    static let selectorStatusIndent: CGFloat = 20
    static let selectorParentTaskIndent: CGFloat = 48
    static let selectorSubtaskIndent: CGFloat = 24

    /// Absolute leading indent for a selectable task node. Depth zero is a
    /// parent task; every recursive subtask advances by the same shared step.
    static func selectorTaskIndent(depth: Int) -> CGFloat {
        selectorParentTaskIndent + CGFloat(max(0, depth)) * selectorSubtaskIndent
    }

    // The session picker's own indent ladder (#40 amendment 2): the same
    // strict project → status → parent task → subtask order as the
    // `selector*` indents above, tightened for the narrow 460 pt sheet
    // (the Tasks view keeps its approved wider ladder — two ladders, one
    // order). Project headers sit at 0.
    static let pickerStatusIndent: CGFloat = 12
    static let pickerParentTaskIndent: CGFloat = 28
    static let pickerSubtaskIndent: CGFloat = 16

    /// Absolute leading indent for a selectable task node in the session
    /// picker. Depth zero is a parent task; every recursive subtask advances
    /// by the same shared step.
    static func pickerTaskIndent(depth: Int) -> CGFloat {
        pickerParentTaskIndent + CGFloat(max(0, depth)) * pickerSubtaskIndent
    }

    // The session-start modal's ad-hoc (mode b) form rhythm (#40 amendments
    // 3 + 4): the entry fields sit under the segmented picker — separated
    // by `adHocPickerToFieldsSpacing`, the amendment-4 dedicated break —
    // and the leftover height of the fixed 460×500 sheet distributes as
    // two equal flexible gaps around the explanatory footnote, so the
    // footnote/duration territory fills the lower half instead of pooling
    // as dead space under the fields.
    //
    // Amendment 4's loosened rhythm: `adHocPickerToFieldsSpacing` is the
    // extra breathing room below the segmented picker BEFORE the Title
    // field, applied on top of the picker's own spacingM bottom padding
    // (which both modes share — PICK mode is untouched): at the same
    // spacingM step it doubles the break, so the first field sits ~28 pt
    // under the control instead of the amendment-3 single 14 pt step.
    // `adHocFormFieldSpacing` is the within-fields gap (title ↔ the
    // category+chips cluster), bumped 20 → 28 (spacingL + 8) so the larger
    // fields breathe between themselves. `adHocFormSectionSpacing` is the
    // flexible gaps' shared floor — still exactly one calm 4 pt step above
    // the within-fields gap (deliberately off the 4/8/14/20 rhythm: it
    // only shows while the gaps collapse) — which the gaps shrink to
    // before the form's scroll view takes over, so the footer's Start
    // button stays pinned at every committed-category count.
    //
    // The entry scale (#40 amendment 4): the Title/Category fields render
    // one step above the 13 pt body default (`adHocFieldFontSize` = 15,
    // the `.title3` scale) on the approved `.controlSize(.large)`, and the
    // committed-category chips (the private `FlowChips` in
    // `SessionStartView`) scale to `adHocChipFontSize` = 12 with an
    // `adHocChipRemoveIconSize` = 11 remove glyph so the capsules stay
    // coherent with the bigger fields — the #16 task forms keep the
    // shared 10 pt `chipFont`/`chipRemoveIconSize`.
    static let adHocPickerToFieldsSpacing: CGFloat = 14
    static let adHocFormFieldSpacing: CGFloat = 28
    static let adHocFormSectionSpacing: CGFloat = 32
    static let adHocFieldFontSize: CGFloat = 15
    static let adHocChipFontSize: CGFloat = 12
    static let adHocChipRemoveIconSize: CGFloat = 11

    // MARK: - Motion (subtle per PRD §21 — timing, no effects)

    /// The ring's per-second tick — linear so the arc advances evenly.
    static let ringTickAnimation: Animation = .linear(duration: 1)
    /// Subtle state changes (pause dim in/out, expiry banner fade).
    static let stateAnimation: Animation = .easeInOut(duration: 0.35)
    /// Arc opacity while paused — dimmed but visible.
    static let pausedArcOpacity: CGFloat = 0.45
    /// Countdown text opacity while paused — slightly brighter than the arc
    /// so the frozen number stays readable.
    static let pausedTextOpacity: CGFloat = 0.55

    // MARK: - Typography

    /// Project section headers.
    static let sectionFont: Font = .headline
    /// Status sub-group headers.
    static let statusGroupFont: Font = .subheadline.weight(.semibold)
    /// Priority/effort chips and category labels.
    static let chipFont: Font = .system(size: 10, weight: .medium)
    /// Deadline and count annotations.
    static let annotationFont: Font = .caption
    /// Row and field body text (task titles, form text fields, editors).
    static let bodyFont: Font = .body
    /// The ad-hoc form's Title/Category entry fields (#40 amendment 4):
    /// one explicit step above `bodyFont` — see `adHocFieldFontSize`.
    static let adHocFieldFont: Font = .system(size: adHocFieldFontSize)
    /// The ad-hoc form's committed-category chips (the private
    /// `FlowChips`): 12 pt medium — see `adHocChipFontSize` — coherent
    /// with the 15 pt fields; the #16 task forms keep the shared
    /// `chipFont`.
    static let adHocChipFont: Font = .system(size: adHocChipFontSize, weight: .medium)
    /// Large screen/sheet titles (the timer's task title, the break screen,
    /// the post-session choice, the end-of-session modal, onboarding) — the
    /// single large step in the type scale.
    static let titleFont: Font = .title2
    /// Sheet headers (task/subtask forms) and the degraded-state banner
    /// title — the mid-weight heading between `titleFont` and the row fonts.
    static let sheetHeaderFont: Font = .headline
    /// Shared Tasks/session-picker hierarchy: project → status → parent → subtask.
    static let selectorProjectTitleFont: Font = .system(
        size: selectorProjectTitleSize, weight: .bold)
    static let selectorStatusTitleFont: Font = .system(
        size: selectorStatusTitleSize, weight: .semibold)
    static let selectorParentTaskTitleFont: Font = .system(
        size: selectorParentTaskTitleSize, weight: .semibold)
    static let selectorSubtaskTitleFont: Font = .system(size: selectorSubtaskTitleSize)
    static let tasksMetadataFont: Font = .system(size: tasksMetadataSize)
    static let tasksChipFont: Font = .system(size: tasksChipSize, weight: .medium)

    // MARK: - Colors (dark-first; the app enforces `.dark` at the root)

    /// Window background.
    static let background = Color(white: 0.12)
    /// Hairline separators between sections.
    static let divider = Color.white.opacity(0.08)
    /// Chip / label capsule background.
    static let chipBackground = Color.white.opacity(0.08)
    /// Selection highlight for a task row (soft accent wash, not a dashboard
    /// card).
    static let selectionBackground = Color(red: 0.30, green: 0.52, blue: 0.95)
        .opacity(0.22)
    /// Overdue deadline text — visually distinct from future deadlines.
    static let overdue = Color(red: 1.0, green: 0.44, blue: 0.40)
    /// Degraded-state banner background.
    static let bannerBackground = Color(red: 0.28, green: 0.19, blue: 0.08)
    /// Degraded-state banner icon color.
    static let warning = Color(red: 1.0, green: 0.72, blue: 0.32)
    /// The focus session's countdown ring (issue #35): a calm dark-theme
    /// red — the user's requested focus-ring color, tuned for the enforced
    /// dark theme (PRD §21): enough lightness that the 10pt ring reads
    /// clearly on the `background` dark gray (~5.4:1; the previous blue
    /// was ~5.9:1), muted enough to stay calm rather than alarm-red.
    /// Deliberately its own token — NOT `overdue`/`priorityColor(.high)`
    /// (those carry deadline/priority semantics; the ring carries "focus
    /// session running"). Paused dimming checked against this tone: the
    /// `pausedArcOpacity`-dimmed arc keeps ~2.3:1, parity with the blue it
    /// replaces (~2.4:1) — dimmed but visible, as before.
    static let focusRing = Color(red: 1.0, green: 0.45, blue: 0.42)
    /// The expired/completed focus ring (issue #35): the full circle the
    /// ring completes into at expiry — a lighter, settled tint of the SAME
    /// red family, so the "done" highlight stays in the user's requested
    /// red hue and stays the most legible state on the dark background.
    /// The BREAK ring deliberately keeps the green `statusColor(.done)`
    /// completion (issue #35 changes only the focus rings; the break ring
    /// stays blue — see `BreakView`).
    static let focusRingCompleted = Color(red: 1.0, green: 0.60, blue: 0.56)

    /// The subtle per-status indicator color (PRD §21: unobtrusive metadata —
    /// a small dot, never a loud badge).
    static func statusColor(_ status: TaskStatus) -> Color {
        switch status {
        case .toDo: Color(white: 0.62)
        case .inProgress: Color(red: 0.42, green: 0.66, blue: 1.0)
        case .blocked: Color(red: 1.0, green: 0.60, blue: 0.33)
        case .done: Color(red: 0.45, green: 0.81, blue: 0.56)
        case .dropped: Color(white: 0.34)
        }
    }

    /// Priority chip tint — only `high` gets a color; the rest stay neutral
    /// to keep rows calm.
    static func priorityColor(_ priority: Priority) -> Color {
        switch priority {
        case .high: Color(red: 1.0, green: 0.44, blue: 0.40)
        case .medium, .low: Color.secondary
        }
    }
}
