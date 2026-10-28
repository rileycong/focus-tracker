import XCTest
@testable import FocusTracker

/// The #49 write seam (the [Push] criterion, the code-verified Pin):
/// `VaultStore.performWriterOperation` and `DailyLogStore.write` each fire
/// `onVaultWrite` EXACTLY ONCE per successful operation — a cross-slug
/// rename legitimately fires twice (move + write; the coordinator
/// coalesces) — and a failed operation fires NOTHING. `AtomicFileWriter`
/// itself is untouched; the hook rides ONE layer above it.
final class VaultStoreSyncHookTests: XCTestCase {

    final class WriteCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func bump() {
            lock.lock()
            defer { lock.unlock() }
            count += 1
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    private func makeVaultDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft49-hook-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Tasks", isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Logs", isDirectory: true),
            withIntermediateDirectories: true)
        return root
    }

    private func makeTask(title: String) throws -> TaskItem {
        try TaskItem(title: title, categories: [Category(name: "Admin")])
    }

    func testCreateFiresHookExactlyOnce() async throws {
        let vault = try makeVaultDirectory()
        let counter = WriteCounter()
        let store = VaultStore(
            vaultURL: vault, onVaultWrite: { counter.bump() })

        let created = try await store.create(try makeTask(title: "Hooked"))

        XCTAssertEqual(counter.value, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: vault.appendingPathComponent("Tasks", isDirectory: true)
                .appendingPathComponent("hooked.md").path))
    }

    func testFailedCreateFiresNothing() async throws {
        let vault = try makeVaultDirectory()
        let counter = WriteCounter()
        let store = VaultStore(
            vaultURL: vault, onVaultWrite: { counter.bump() })
        let task = try makeTask(title: "Duplicate")
        _ = try await store.create(task)

        // The second create with the SAME ID fails typed BEFORE any write.
        do {
            _ = try await store.create(task)
            XCTFail("expected the duplicateTaskIDOnCreate failure")
        } catch let error as VaultStoreError {
            XCTAssertEqual(error, .duplicateTaskIDOnCreate(task.id))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(counter.value, 1)
    }

    func testUpdateFiresHookExactlyOnce() async throws {
        let vault = try makeVaultDirectory()
        let counter = WriteCounter()
        let store = VaultStore(
            vaultURL: vault, onVaultWrite: { counter.bump() })
        _ = try await store.create(try makeTask(title: "Original"))
        XCTAssertEqual(counter.value, 1)

        try await store.load()
        let loadedList = await store.tasks
        var loaded = try XCTUnwrap(loadedList.first)
        loaded.title = "Original (edited)"
        _ = try await store.update(loaded)

        XCTAssertEqual(counter.value, 2)
    }

    func testCrossSlugRenameFiresHookTwice() async throws {
        let vault = try makeVaultDirectory()
        let counter = WriteCounter()
        let store = VaultStore(
            vaultURL: vault, onVaultWrite: { counter.bump() })
        _ = try await store.create(try makeTask(title: "First titular"))
        try await store.load()
        XCTAssertEqual(counter.value, 1)

        // A cross-slug rename: ONE move + ONE write = the documented,
        // coalesced DOUBLE fire.
        let loadedList = await store.tasks
        var loaded = try XCTUnwrap(loadedList.first)
        loaded.title = "Second completely"
        _ = try await store.rename(loaded, to: "Second completely")

        XCTAssertEqual(counter.value, 3)
    }

    func testSameSlugRenameFiresHookOnce() async throws {
        let vault = try makeVaultDirectory()
        let counter = WriteCounter()
        let store = VaultStore(
            vaultURL: vault, onVaultWrite: { counter.bump() })
        _ = try await store.create(try makeTask(title: "Stable"))
        try await store.load()
        XCTAssertEqual(counter.value, 1)

        // A same-slug rename: no move, the persistence write only — and
        // still a SUCCESS, never an error.
        let loadedList = await store.tasks
        var loaded = try XCTUnwrap(loadedList.first)
        loaded.title = "Stable"
        _ = try await store.rename(loaded, to: "Stable")

        XCTAssertEqual(counter.value, 2)
    }

    func testDeleteFiresHookExactlyOnce() async throws {
        let vault = try makeVaultDirectory()
        let counter = WriteCounter()
        let store = VaultStore(
            vaultURL: vault, onVaultWrite: { counter.bump() })
        let task = try makeTask(title: "Doomed")
        _ = try await store.create(task)
        try await store.load()
        XCTAssertEqual(counter.value, 1)

        try await store.delete(task)
        XCTAssertEqual(counter.value, 2)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: vault.appendingPathComponent("Tasks", isDirectory: true)
                .appendingPathComponent("doomed.md").path))
    }

    /// Issue #51: a staleness-refused delete writes nothing, so the hook
    /// fires NOTHING either — the deletion trigger never opens the sync
    /// debounce window on a failed operation.
    func testStalenessRefusedDeleteFiresNothing() async throws {
        let vault = try makeVaultDirectory()
        let counter = WriteCounter()
        let store = VaultStore(
            vaultURL: vault, onVaultWrite: { counter.bump() })
        let task = try makeTask(title: "Conflicted")
        _ = try await store.create(task)
        try await store.load()
        XCTAssertEqual(counter.value, 1)

        // An external rewrite makes the store's recorded bytes stale.
        // (The slug is case-preserving: "Conflicted" → "Conflicted.md".)
        let fileURL = vault.appendingPathComponent("Tasks", isDirectory: true)
            .appendingPathComponent("Conflicted.md")
        var mutated = task
        mutated.status = .done
        try Data(FrontmatterCodec.encode(task: mutated, body: "").utf8)
            .write(to: fileURL)

        do {
            try await store.delete(task)
            XCTFail("expected the staleness refusal")
        } catch let error as VaultStoreError {
            XCTAssertEqual(
                error, .vaultChangedExternally(id: task.id, fileName: "Conflicted.md"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(counter.value, 1, "a refused delete fires no hook")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fileURL.path),
            "the externally changed file survives untouched")
    }

    /// Issue #51: a subtask delete rewrites the parent file through the
    /// shared `update` path — ONE physical write → the hook fires EXACTLY
    /// ONCE (the deletion rides the existing seam unchanged).
    func testDeleteSubtaskFiresHookExactlyOnce() async throws {
        let vault = try makeVaultDirectory()
        let counter = WriteCounter()
        let store = VaultStore(
            vaultURL: vault, onVaultWrite: { counter.bump() })
        let parent = try makeTask(title: "Parent")
        _ = try await store.create(parent)
        try await store.load()
        XCTAssertEqual(counter.value, 1)
        let loadedList = await store.tasks
        let loaded = try XCTUnwrap(loadedList.first)

        // A nested subtree (depth 2) under the parent.
        let child = SubtaskItem(
            title: "Child", children: [SubtaskItem(title: "Grandchild")])
        _ = try await store.addSubtask(
            parentID: loaded.id, subtask: child, toParentSubtaskID: nil)
        XCTAssertEqual(counter.value, 2)

        try await store.deleteSubtask(parentID: loaded.id, subtaskID: child.id)
        XCTAssertEqual(counter.value, 3, "the parent rewrite fires the hook exactly once")

        let afterList = await store.tasks
        let after = try XCTUnwrap(afterList.first)
        XCTAssertEqual(after.subtasks, [], "the whole subtree is gone")
    }

    func testDailyLogStoreAppendsFireHookOncePerSuccessfulWrite() async throws {
        let vault = try makeVaultDirectory()
        let counter = WriteCounter()
        let store = DailyLogStore(
            vaultURL: vault, onVaultWrite: { counter.bump() })
        let day = Date(timeIntervalSince1970: 1_789_000_000)

        let session = FocusSessionLog(
            sessionID: UUID(), taskID: UUID(),
            startedAt: day,
            endedAt: day.addingTimeInterval(30 * 60),
            focusedDuration: 25, pauseCount: 1, pausedDuration: 5,
            focusRating: 4, energyRating: 3, taskCompleted: false, notes: nil)
        try await store.appendSession(session, to: day)
        XCTAssertEqual(counter.value, 1)

        let breakLog = BreakLog(
            breakID: UUID(), startedAt: day.addingTimeInterval(3600),
            endedAt: day.addingTimeInterval(3900), duration: 5)
        try await store.appendBreak(breakLog, to: day)
        XCTAssertEqual(counter.value, 2)

        // The append-time arithmetic validation runs BEFORE any I/O: a
        // failed append writes nothing and fires NOTHING.
        let inconsistent = FocusSessionLog(
            sessionID: UUID(), taskID: UUID(),
            startedAt: day.addingTimeInterval(7200),
            endedAt: day.addingTimeInterval(7200 + 10 * 60),
            focusedDuration: 25, pauseCount: 0, pausedDuration: 5,
            focusRating: 4, energyRating: 3, taskCompleted: false, notes: nil)
        do {
            _ = try await store.appendSession(inconsistent, to: day)
            XCTFail("expected the arithmetic validation failure")
        } catch {
            // (The CODEC's own tests pin the exact typed case; here the
            // invariant under test is the silent hook.)
        }
        XCTAssertEqual(counter.value, 2)
    }

    func testDefaultedHookParameterKeepsExistingCallSitesWorking() async throws {
        // The defaulted parameter: ZERO existing call-site or test changes.
        let vault = try makeVaultDirectory()
        let store = VaultStore(vaultURL: vault)
        _ = try await store.create(try makeTask(title: "Vanilla"))
        // (No crash, no hook — the invariant is the construction compiles
        // and the write succeeds; the previous tests pin the firing.)
        let taskCount = await store.taskCount
        XCTAssertEqual(taskCount, 1)
    }
}
