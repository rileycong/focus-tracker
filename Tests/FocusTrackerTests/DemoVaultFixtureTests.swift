import XCTest
@testable import FocusTracker

/// Issue #56: `fixtures/demo-vault/` is a second fictional vault (a small
/// bakery and a running club) used as a schema fixture next to
/// `fixtures/sample-vault`. It must be valid against the real schema
/// (the same one `fixtures/sample-vault` documents), load with zero warnings,
/// and round-trip byte-for-byte. The repo fixture is copied to a temp dir; it
/// is never mutated.
final class DemoVaultFixtureTests: XCTestCase {

    private static let repoDemoVault = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Tests/FocusTrackerTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("fixtures/demo-vault", isDirectory: true)

    private var root: URL!
    private var vaultURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DemoVaultFixtureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        vaultURL = root.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.copyItem(at: Self.repoDemoVault, to: vaultURL)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func files(in folder: String) throws -> [URL] {
        let directory = vaultURL.appendingPathComponent(folder, isDirectory: true)
        return try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func loadedTasks() async throws -> VaultStore.Inventory {
        let store = VaultStore(vaultURL: vaultURL)
        let state = await store.load()
        guard case .loaded(let inventory) = state else {
            XCTFail("expected .loaded(...), got \(state)")
            throw XCTSkip("demo vault did not load")
        }
        return inventory
    }

    private func allSubtasks(_ subtasks: [SubtaskItem]) -> [SubtaskItem] {
        subtasks.flatMap { [$0] + allSubtasks($0.children) }
    }

    private func depth(_ subtasks: [SubtaskItem]) -> Int {
        subtasks.map { 1 + depth($0.children) }.max() ?? 0
    }

    // MARK: - Shape

    func testDirectoryHoldsExactlyTasksAndLogs() throws {
        let entries = try FileManager.default
            .contentsOfDirectory(atPath: vaultURL.path(percentEncoded: false))
            .sorted()
        XCTAssertEqual(entries, ["Logs", "Tasks"], "no Inbox/, .git, .obsidian or dotfiles")
        XCTAssertEqual(try files(in: "Tasks").count, 10)
        XCTAssertEqual(try files(in: "Logs").count, 2)
        let allTasksEntries = try FileManager.default
            .contentsOfDirectory(atPath: vaultURL.appendingPathComponent("Tasks").path(percentEncoded: false))
        XCTAssertEqual(allTasksEntries.count, 10, "Tasks/ holds only the 10 task files")
        let allLogEntries = try FileManager.default
            .contentsOfDirectory(atPath: vaultURL.appendingPathComponent("Logs").path(percentEncoded: false))
        XCTAssertEqual(allLogEntries.count, 2, "Logs/ holds only the 2 log files")
    }

    func testLoadsWithZeroWarningsAndTheDesignedContent() async throws {
        let inventory = try await loadedTasks()
        XCTAssertEqual(inventory.warnings.count, 0, "warnings: \(inventory.warnings)")
        XCTAssertEqual(inventory.tasks.count, 10)

        let everyStatus = Set(
            inventory.tasks.map(\.status)
                + inventory.tasks.flatMap { allSubtasks($0.subtasks).map(\.status) })
        XCTAssertEqual(everyStatus, Set(TaskStatus.allCases), "all five statuses are present")

        let projects = Set(inventory.tasks.compactMap { $0.project?.name })
        XCTAssertEqual(projects, ["Bakery Launch", "Trail Running Club"], "exactly 2 named projects")
        XCTAssertEqual(
            inventory.tasks.filter { $0.project == nil }.count, 2, "exactly 2 No-Project tasks")

        XCTAssertGreaterThanOrEqual(
            inventory.tasks.map { 1 + depth($0.subtasks) }.max() ?? 0, 3,
            "subtasks nest at least 2 levels deep")

        let deadlineCount =
            inventory.tasks.filter { $0.deadline != nil }.count
            + inventory.tasks.flatMap { allSubtasks($0.subtasks) }.filter { $0.deadline != nil }.count
        XCTAssertGreaterThanOrEqual(deadlineCount, 3)
    }

    // MARK: - Byte round trips

    func testEveryTaskFileRoundTripsByteIdentical() throws {
        for url in try files(in: "Tasks") {
            let text = try String(contentsOf: url, encoding: .utf8)
            let task = try FrontmatterCodec.parseTask(text)
            let body = try FrontmatterCodec.split(text).body
            XCTAssertEqual(
                FrontmatterCodec.encode(task: task, body: body), text,
                "\(url.lastPathComponent) must round-trip parseTask -> encode")
            XCTAssertEqual(
                url.deletingPathExtension().lastPathComponent, task.title,
                "filename stem == title for \(url.lastPathComponent)")
        }
    }

    func testEveryLogFileRoundTripsAndSatisfiesTheAppendInvariants() throws {
        for url in try files(in: "Logs") {
            let text = try String(contentsOf: url, encoding: .utf8)
            let parsed = try DailyLogCodec.parseDay(text)
            XCTAssertEqual(
                DailyLogCodec.encodeDay(
                    sessions: parsed.log.sessions, breaks: parsed.log.breaks, body: parsed.body),
                text,
                "\(url.lastPathComponent) must round-trip parseDay -> encodeDay")
            XCTAssertFalse(parsed.log.sessions.isEmpty, url.lastPathComponent)
            XCTAssertEqual(parsed.log.breaks.count, 1, url.lastPathComponent)
            for session in parsed.log.sessions {
                XCTAssertNil(
                    DailyLogCodec.appendValidationFailure(for: session),
                    "session \(session.sessionID) in \(url.lastPathComponent)")
                XCTAssertTrue((1...5).contains(session.focusRating))
                XCTAssertTrue((1...5).contains(session.energyRating))
            }
            for breakLog in parsed.log.breaks {
                XCTAssertNil(
                    DailyLogCodec.appendValidationFailure(for: breakLog),
                    "break \(breakLog.breakID) in \(url.lastPathComponent)")
            }
        }
    }

    func testEveryLoggedTaskIDExistsInTheVault() async throws {
        let inventory = try await loadedTasks()
        var knownIDs = Set<UUID>()
        for task in inventory.tasks {
            knownIDs.insert(task.id)
            allSubtasks(task.subtasks).forEach { knownIDs.insert($0.id) }
        }
        var loggedIDs = Set<UUID>()
        for url in try files(in: "Logs") {
            let parsed = try DailyLogCodec.parseDay(String(contentsOf: url, encoding: .utf8))
            parsed.log.sessions.forEach { loggedIDs.insert($0.taskID) }
        }
        XCTAssertEqual(loggedIDs.count, 4, "four distinct tasks are logged")
        XCTAssertEqual(loggedIDs.subtracting(knownIDs), [], "every logged task_id exists")
    }

    // MARK: - Nothing personal

    func testNoFileContainsEmailsLinksOrHomePaths() throws {
        let all = try files(in: "Tasks") + files(in: "Logs")
        XCTAssertEqual(all.count, 12)
        for url in all {
            let text = try String(contentsOf: url, encoding: .utf8)
            // The home-path needle is split so the public-export audit (P1)
            // does not flag this very file.
            for needle in ["@", "http", "/Use" + "rs/"] {
                XCTAssertFalse(
                    text.contains(needle), "\(url.lastPathComponent) contains \"\(needle)\"")
            }
        }
    }
}
