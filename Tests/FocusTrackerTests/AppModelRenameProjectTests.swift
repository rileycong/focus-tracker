import XCTest
@testable import FocusTracker

/// Tests for issue #54: `AppModel.renameProject(from:to:)` — batch update of
/// all tasks with a given project name, persisting through `VaultStore.update`
/// (atomic per-file), mirroring the synced inventory (no reload).
@MainActor
final class AppModelRenameProjectTests: XCTestCase {

    // MARK: - Test doubles

    private final class FakeClock: FocusSessionClock, @unchecked Sendable {
        var monotonicSeconds: TimeInterval = 0
        var wallClockNow = Date(timeIntervalSinceReferenceDate: 800_000_000)
    }

    private final class ManualTickScheduler: ActiveSessionTickScheduler, @unchecked Sendable {
        func schedule(after interval: TimeInterval, _ tick: @escaping @Sendable () -> Void) {}
        func cancel() {}
    }

    // MARK: - Fixture access

    private static let fixturesVault = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Tests/FocusTrackerTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("fixtures/sample-vault", isDirectory: true)

    private var root: URL!
    private var vaultURL: URL!
    private var persistenceDirectory: URL!
    private var suiteName: String!
    private var settings: AppSettings!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("AppModelRenameProjectTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        vaultURL = root.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.copyItem(at: Self.fixturesVault, to: vaultURL)
        persistenceDirectory = root.appendingPathComponent("persistence", isDirectory: true)
        suiteName = "AppModelRenameProjectTests-\(UUID().uuidString)"
        settings = try AppSettings(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        if let suiteName {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeModel() -> AppModel {
        AppModel(
            settings: settings,
            persistenceDirectory: persistenceDirectory,
            scheduler: ManualTickScheduler(),
            sessionClock: FakeClock())
    }

    private func makeConfiguredModel() async -> AppModel {
        settings.vaultPath = vaultURL.path(percentEncoded: false)
        let model = makeModel()
        await model.bootstrap()
        return model
    }

    // MARK: - Tests

    /// Issue #54 criterion: rename updates all tasks with the old project
    /// name, leaving other fields unchanged. The observable state is
    /// refreshed from the store's synced inventory (no reload).
    func testRenameProjectUpdatesAllMatchingTasks() async throws {
        let model = await makeConfiguredModel()
        // Create three tasks: two with "TestWorkProject2024", one with "TestPersonalProject2024"
        let work1 = try TaskItem(
            title: "Task 1", categories: [Category(name: "Code")],
            project: Project(name: "TestWorkProject2024"), priority: .high, effort: .l)
        let work2 = try TaskItem(
            title: "Task 2", categories: [Category(name: "Code")],
            project: Project(name: "TestWorkProject2024"), priority: .medium, effort: .m)
        let personal = try TaskItem(
            title: "Task 3", categories: [Category(name: "Life")],
            project: Project(name: "TestPersonalProject2024"), priority: .low, effort: .s)
        _ = try await model.createTask(work1)
        _ = try await model.createTask(work2)
        _ = try await model.createTask(personal)

        // Rename "TestWorkProject2024" to "WorkRenamed"
        try await model.renameProject(from: "TestWorkProject2024", to: "WorkRenamed")

        // The two "TestWorkProject2024" tasks now have "WorkRenamed"
        let renamedTasks = model.tasks.filter { $0.project?.name == "WorkRenamed" }
        XCTAssertEqual(renamedTasks.count, 2)
        // The "TestPersonalProject2024" task is unchanged
        let personalTasks = model.tasks.filter { $0.project?.name == "TestPersonalProject2024" }
        XCTAssertEqual(personalTasks.count, 1)
        // No "TestWorkProject2024" tasks remain
        let workTasks = model.tasks.filter { $0.project?.name == "TestWorkProject2024" }
        XCTAssertEqual(workTasks.count, 0)
        // All other fields are unchanged
        for task in renamedTasks {
            if task.title == "Task 1" {
                XCTAssertEqual(task.priority, .high)
                XCTAssertEqual(task.effort, .l)
                XCTAssertEqual(task.categories, [Category(name: "Code")])
            } else if task.title == "Task 2" {
                XCTAssertEqual(task.priority, .medium)
                XCTAssertEqual(task.effort, .m)
                XCTAssertEqual(task.categories, [Category(name: "Code")])
            }
        }
    }

    /// Issue #54 criterion: tasks with no project (nil) are not affected.
    func testRenameProjectDoesNotAffectNoProjectTasks() async throws {
        let model = await makeConfiguredModel()
        // Create one task with "TestWorkProject2024", one with no project
        let work = try TaskItem(
            title: "Task with project", categories: [Category(name: "Code")],
            project: Project(name: "TestWorkProject2024"))
        let noProject = try TaskItem(
            title: "Task without project", categories: [Category(name: "Life")],
            project: nil)
        _ = try await model.createTask(work)
        _ = try await model.createTask(noProject)

        // Rename "TestWorkProject2024" to "WorkRenamed"
        try await model.renameProject(from: "TestWorkProject2024", to: "WorkRenamed")

        // One has "WorkRenamed"
        let renamedTasks = model.tasks.filter { $0.project?.name == "WorkRenamed" }
        XCTAssertEqual(renamedTasks.count, 1)
        // The "no project" task is unchanged
        let noProjectTaskAfter = model.tasks.first(where: { $0.title == "Task without project" })
        XCTAssertNotNil(noProjectTaskAfter)
        XCTAssertNil(noProjectTaskAfter?.project)
    }

    /// Issue #54 criterion: renaming to an existing project name merges the
    /// two groups (no error).
    func testRenameProjectMergesWhenRenamingToExisting() async throws {
        let model = await makeConfiguredModel()
        // Create two tasks: one "Work", one "Personal"
        let work = try TaskItem(
            title: "Work task", categories: [Category(name: "Code")],
            project: Project(name: "Work"))
        let personal = try TaskItem(
            title: "Personal task", categories: [Category(name: "Life")],
            project: Project(name: "Personal"))
        _ = try await model.createTask(work)
        _ = try await model.createTask(personal)

        // Rename "Work" to "Personal" (the existing name)
        try await model.renameProject(from: "Work", to: "Personal")

        // Both our test tasks have "Personal" (merged)
        let personalTasks = model.tasks.filter { $0.project?.name == "Personal" }
        XCTAssertGreaterThanOrEqual(personalTasks.count, 2)
        // The "Work task" is now in "Personal"
        let formerWorkTask = personalTasks.first(where: { $0.title == "Work task" })
        XCTAssertNotNil(formerWorkTask)
        XCTAssertEqual(formerWorkTask?.project?.name, "Personal")
    }

    /// Issue #54 criterion: no data loss — subtasks, categories, status,
    /// order, notes, deadlines are unchanged.
    func testRenameProjectPreservesAllOtherFields() async throws {
        let model = await makeConfiguredModel()
        let deadline = Date(timeIntervalSinceReferenceDate: 900_000_000)
        let subtask = SubtaskItem(title: "Subtask", status: .toDo)
        let task = try TaskItem(
            title: "Complex task",
            categories: [Category(name: "Code"), Category(name: "Design")],
            status: .inProgress,
            project: Project(name: "OldProject"),
            priority: .high,
            effort: .l,
            deadline: deadline,
            notes: "Important notes",
            order: 42,
            subtasks: [subtask])
        _ = try await model.createTask(task)

        // Rename "OldProject" to "NewProject"
        try await model.renameProject(from: "OldProject", to: "NewProject")

        // Find the renamed task
        let renamed = model.tasks.first(where: { $0.title == "Complex task" })
        XCTAssertNotNil(renamed)
        guard let renamed = renamed else { return }
        XCTAssertEqual(renamed.project?.name, "NewProject")
        // All other fields are unchanged
        XCTAssertEqual(renamed.title, "Complex task")
        XCTAssertEqual(renamed.categories, [Category(name: "Code"), Category(name: "Design")])
        XCTAssertEqual(renamed.status, .inProgress)
        XCTAssertEqual(renamed.priority, .high)
        XCTAssertEqual(renamed.effort, .l)
        XCTAssertEqual(renamed.deadline, deadline)
        XCTAssertEqual(renamed.notes, "Important notes")
        XCTAssertEqual(renamed.order, 42)
        XCTAssertEqual(renamed.subtasks.count, 1)
        XCTAssertEqual(renamed.subtasks[0].title, "Subtask")
    }

    /// Issue #54 typed error: `.noVaultConfigured` when no vault is set.
    func testRenameProjectThrowsWhenNoVaultConfigured() async throws {
        let model = makeModel() // No vault path set
        do {
            try await model.renameProject(from: "Old", to: "New")
            XCTFail("Expected TaskWriteError.noVaultConfigured")
        } catch AppModel.TaskWriteError.noVaultConfigured {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    /// Issue #54 criterion: no-op when no tasks match the old project name.
    func testRenameProjectNoOpWhenNoMatchingTasks() async throws {
        let model = await makeConfiguredModel()
        // Create one task with "Work"
        let work = try TaskItem(
            title: "Task", categories: [Category(name: "Code")],
            project: Project(name: "Work"))
        _ = try await model.createTask(work)

        // Rename "NonExistent" to "NewName" (no-op)
        try await model.renameProject(from: "NonExistent", to: "NewName")

        // The "Work" task is unchanged
        let workTask = model.tasks.first(where: { $0.title == "Task" })
        XCTAssertNotNil(workTask)
        XCTAssertEqual(workTask?.project?.name, "Work")
    }
}
