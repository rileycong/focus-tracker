import SwiftUI

/// A single task row of the Tasks view (issue #15; #17 extends it): title,
/// subtle status dot, priority/effort chips when set, deadline when set
/// (overdue rendered distinctly via `TasksGrouping.isOverdue`), category
/// labels, and the subtask tree indented beneath it.
///
/// **Subtask tree (issue #17):** when the task has subtasks, the row gains a
/// disclosure chevron and renders its subtask tree nested underneath —
/// recursively through `SubtaskRowView`, so depth is unbounded (a property
/// of `SubtaskItem.children`, not a UI limit). Disclosure uses the same
/// custom chevron + conditional children shape as `SubtaskRowView` (tap
/// stays selection per #15; see there for the documented reasoning), with
/// collapse state persisted through the shared `TasksViewModel`/
/// `CollapseStateStoring` path (`TasksGrouping.taskCollapseKey`).
///
/// Read-only other than selection and the disclosure: #16 edit / #19 start
/// attach later; subtask add/edit/delete live in the rows' context menus.
/// Issue #51 adds the trailing-edge hover delete affordance: a small trash
/// button revealed on row hover, suppressed while a drag-reorder gesture is
/// in flight (see `TasksViewModel.reorderDragActive`), which requests the
/// shared task-delete confirmation — the dialog itself lives in `TasksView`
/// (see `requestDelete`), because the row's context-menu "Delete Task…"
/// entry (TasksView) and this affordance present the SAME dialog.
struct TaskRowView: View {
    let task: TaskItem
    let viewModel: TasksViewModel
    /// The subtask entry points handed down to the tree's rows (issue #17).
    let subtaskActions: SubtaskActions
    /// Issue #51: the task-delete REQUEST (not the delete itself) — opens
    /// the shared confirmation dialog by handing the task up to `TasksView`
    /// (engineer's choice per the groom: one dialog serves both this
    /// affordance and the row's context-menu entry, which lives in
    /// `TasksView`; the dialog's confirm runs `AppModel.deleteTask`).
    let requestDelete: (_ task: TaskItem) -> Void

    @State private var isHovering = false

    private var hasSubtasks: Bool { !task.subtasks.isEmpty }

    /// The #51 affordance visibility rule: hover-only, never mid-drag.
    private var showsDeleteAffordance: Bool {
        isHovering && !viewModel.reorderDragActive
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.tasksRowSpacing) {
            row
            if hasSubtasks
                && viewModel.isExpanded(forKey: TasksGrouping.taskCollapseKey(task.id))
            {
                VStack(alignment: .leading, spacing: DesignTokens.tasksRowSpacing) {
                    ForEach(task.subtasks) { subtask in
                        SubtaskRowView(
                            taskID: task.id, subtask: subtask,
                            parentSubtaskID: nil,
                            siblingIDs: task.subtasks.map(\.id),
                            viewModel: viewModel, actions: subtaskActions)
                    }
                }
                .padding(.leading, DesignTokens.selectorSubtaskIndent)
            }
        }
    }

    private var row: some View {
        HStack(spacing: DesignTokens.spacingS) {
            if hasSubtasks {
                Button {
                    viewModel.toggleExpanded(forKey: TasksGrouping.taskCollapseKey(task.id))
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(
                            size: DesignTokens.tasksChevronIconSize, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(
                            .degrees(
                                viewModel.isExpanded(
                                    forKey: TasksGrouping.taskCollapseKey(task.id)) ? 90 : 0))
                }
                .buttonStyle(.plain)
                .help(
                    viewModel.isExpanded(forKey: TasksGrouping.taskCollapseKey(task.id))
                        ? "Collapse subtasks" : "Expand subtasks")
            }
            Circle()
                .fill(DesignTokens.statusColor(task.status))
                .frame(
                    width: DesignTokens.tasksStatusDotSize,
                    height: DesignTokens.tasksStatusDotSize)
                .accessibilityLabel(Text(task.status.rawValue))
            Text(task.title)
                .font(DesignTokens.selectorParentTaskTitleFont)
                .lineLimit(1)
            if hasSubtasks {
                Label(
                    "\(task.subtasks.count)",
                    systemImage: "list.bullet.indent")
                    .font(DesignTokens.tasksMetadataFont)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DesignTokens.spacingM)
            if let priority = task.priority {
                chip(priority.rawValue)
                    .foregroundStyle(DesignTokens.priorityColor(priority))
            }
            if let effort = task.effort {
                chip(effort.rawValue)
                    .foregroundStyle(.secondary)
            }
            if let deadline = task.deadline {
                Text(deadline.formatted(date: .abbreviated, time: .omitted))
                    .font(DesignTokens.tasksMetadataFont)
                    .foregroundStyle(
                        TasksGrouping.isOverdue(deadline: deadline, now: .now)
                            ? DesignTokens.overdue
                            : Color.secondary)
            }
            ForEach(task.categories, id: \.name) { category in
                chip(category.name)
                    .foregroundStyle(.secondary)
            }
            // The #51 trailing-edge delete affordance: layout-stable
            // (opacity-driven — the trailing slot is always reserved, so
            // chips never shift on hover), non-hittable and hidden from
            // accessibility while concealed.
            deleteAffordance
                .opacity(showsDeleteAffordance ? 1 : 0)
                .allowsHitTesting(showsDeleteAffordance)
                .accessibilityHidden(!showsDeleteAffordance)
        }
        .padding(.vertical, DesignTokens.tasksRowVerticalPadding)
        .padding(.horizontal, DesignTokens.spacingS)
        .background(
            viewModel.isSelected(task.id)
                ? DesignTokens.selectionBackground
                : Color.clear)
        .cornerRadius(DesignTokens.cornerRadius)
        .contentShape(Rectangle())
        .onTapGesture { viewModel.toggleSelection(of: task.id) }
        .onHover { hovering in
            isHovering = hovering
            // Self-healing clear (see `reorderDragActive`): a hover event
            // proves no drag session owns the pointer.
            if viewModel.reorderDragActive { viewModel.reorderDragActive = false }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(
            viewModel.isSelected(task.id) ? AccessibilityTraits.isSelected : [])
    }

    /// The #51 hover delete affordance: a small plain-style trash button on
    /// the row's trailing edge. Token-sized (`DesignTokens`), secondary
    /// foreground (the calm row language, PRD §21 — no raw literals), and
    /// individually reachable for accessibility/AX drives through its own
    /// label ("Delete task <title>").
    private var deleteAffordance: some View {
        Button {
            requestDelete(task)
        } label: {
            Image(systemName: "trash")
                .font(.system(
                    size: DesignTokens.tasksDeleteIconSize, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Delete this task and its subtasks")
        .accessibilityLabel(Text("Delete task \(task.title)"))
    }

    /// A small capsule chip (priority, effort, category).
    private func chip(_ text: String) -> some View {
        Text(text)
            .font(DesignTokens.tasksChipFont)
            .padding(.horizontal, DesignTokens.spacingS)
            .padding(.vertical, DesignTokens.spacingXS)
            .background(DesignTokens.chipBackground)
            .cornerRadius(DesignTokens.cornerRadius)
            .lineLimit(1)
    }
}
