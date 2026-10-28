import XCTest
@testable import FocusTracker

/// The #50 (FocusVault FT-2) engine-level floor: the pure draft parser
/// (title/body derivation, conformance boundaries), the import run
/// (move semantics, idempotence, failures keep the draft), the per-run
/// snapshot seam, the same-code-path `create(_:body:)` seam, the
/// #49-hook push-for-free invariant, and the ownership table (only
/// `Inbox/` reads + `Tasks/` creation + draft removal).
///
/// Every test builds its own TEMP-DIR COPY of `fixtures/sample-vault/`
/// (the VaultStoreTests helper pattern) plus an `Inbox/` inside that
/// copy — the repo fixture itself and the real vault are never touched,
/// and no `Inbox/` fixture is added to the repo (its own amendment only).
final class InboxImportTests: XCTestCase {

    // MARK: - Fixture (a temp-dir copy of the repo's sample vault)

    private static let fixturesVault = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Tests/FocusTrackerTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("fixtures/sample-vault", isDirectory: true)

    private var root: URL!
    private var vaultURL: URL!
    private var inboxURL: URL!
    /// Drafts whose permissions were changed — restored before teardown
    /// so the temp dir can be cleaned up.
    private var pathsToRestore: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("InboxImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        vaultURL = root.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.copyItem(at: Self.fixturesVault, to: vaultURL)
        inboxURL = vaultURL.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for path in pathsToRestore {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private var tasksDirectory: URL {
        vaultURL.appendingPathComponent("Tasks", isDirectory: true)
    }

    private func writeDraft(_ fileName: String, text: String) throws {
        try Data(text.utf8).write(to: inboxURL.appendingPathComponent(fileName))
    }

    private func writeDraft(_ fileName: String, bytes: Data) throws {
        try bytes.write(to: inboxURL.appendingPathComponent(fileName))
    }

    private func draftURL(_ fileName: String) -> URL {
        inboxURL.appendingPathComponent(fileName)
    }

    private func draftData(_ fileName: String) -> Data? {
        try? Data(contentsOf: draftURL(fileName))
    }

    /// A snapshot of every file under the vault, keyed by path relative
    /// to the vault root — the ownership assertion's before/after record.
    /// Keys are built from `lastPathComponent`s ONLY (no absolute-path
    /// prefix math): the temp dir is reachable as both "/var/…" and
    /// "/private/var/…" depending on which API produced a URL, and only
    /// the components are guaranteed consistent.
    private func snapshotVaultFiles() throws -> [String: Data] {
        var files: [String: Data] = [:]
        try collectVaultFiles(
            under: vaultURL, relativePrefix: "", into: &files)
        return files
    }

    private func collectVaultFiles(
        under directory: URL, relativePrefix: String, into files: inout [String: Data]
    ) throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey])
        for entry in entries {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(
                atPath: entry.path(percentEncoded: false), isDirectory: &isDirectory)
            let key = relativePrefix.isEmpty
                ? entry.lastPathComponent
                : relativePrefix + "/" + entry.lastPathComponent
            if isDirectory.boolValue {
                try collectVaultFiles(under: entry, relativePrefix: key, into: &files)
            } else if entry.lastPathComponent != ".DS_Store" {
                files[key] = try Data(contentsOf: entry)
            }
        }
    }

    /// The #49-hook fire counter (the VaultStoreSyncHookTests pattern,
    /// self-contained here).
    final class HookCounter: @unchecked Sendable {
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

    // MARK: - The pure parser: title derivation

    func testTitleComesFromFirstLevelOneHeading() throws {
        let result = InboxDraftParser.content(
            fileName: "20260920-101500-buy-milk.md",
            bytes: Data("# Buy milk\n\nGroceries for the week.\n".utf8))
        guard case .success(let content) = result else {
            return XCTFail("expected a conforming draft, got \(result)")
        }
        XCTAssertEqual(content.title, "Buy milk")
        XCTAssertEqual(content.body, "\nGroceries for the week.\n")
    }

    func testDeeperHeadingsDoNotSupplyTheTitle() throws {
        let text = "## not level one\n### also not\n# Real Title\nrest of draft"
        let result = InboxDraftParser.content(fileName: "d.md", bytes: Data(text.utf8))
        guard case .success(let content) = result else {
            return XCTFail("expected a conforming draft, got \(result)")
        }
        XCTAssertEqual(content.title, "Real Title")
        XCTAssertEqual(content.body, "rest of draft")
    }

    func testHeadingTextIsTrimmedAndWhitespaceTolerated() throws {
        // Leading spaces on the line, trailing spaces, and a CRLF tail are
        // tolerated for detection; the title text is trimmed.
        let text = "  #   Spaced Title   \r\nbody line"
        let result = InboxDraftParser.content(fileName: "d.md", bytes: Data(text.utf8))
        guard case .success(let content) = result else {
            return XCTFail("expected a conforming draft, got \(result)")
        }
        XCTAssertEqual(content.title, "Spaced Title")
        XCTAssertEqual(content.body, "body line")
    }

    func testEmptyHeadingTextFallsBackToFileName() throws {
        // "#" alone and "# " with empty text contribute no title — the
        // filename fallback applies, and the body is then the ENTIRE
        // content (the pinned no-heading rule).
        for text in ["#\nbody", "# \nbody"] {
            let result = InboxDraftParser.content(
                fileName: "fallback.md", bytes: Data(text.utf8))
            guard case .success(let content) = result else {
                return XCTFail("expected a conforming draft for \(text), got \(result)")
            }
            XCTAssertEqual(content.title, "fallback", "for draft \(text)")
            XCTAssertEqual(content.body, text, "for draft \(text)")
        }
    }

    func testTitleFallsBackToFileNameSansExtensionWithEntireBody() throws {
        let result = InboxDraftParser.content(
            fileName: "20260920-101500-buy-milk.md",
            bytes: Data("Just some plain text, no heading.\n".utf8))
        guard case .success(let content) = result else {
            return XCTFail("expected a conforming draft, got \(result)")
        }
        XCTAssertEqual(content.title, "20260920-101500-buy-milk")
        // The ENTIRE file content when the title came from the filename.
        XCTAssertEqual(content.body, "Just some plain text, no heading.\n")
    }

    func testCRLFDraftIsCRLFSafe() throws {
        let text = "# Title\r\n\r\nLine one.\r\nLine two.\r\n"
        let result = InboxDraftParser.content(fileName: "crlf.md", bytes: Data(text.utf8))
        guard case .success(let content) = result else {
            return XCTFail("expected a conforming draft, got \(result)")
        }
        XCTAssertEqual(content.title, "Title")
        // The body keeps every byte after the heading line — CRLFs intact.
        XCTAssertEqual(content.body, "\r\nLine one.\r\nLine two.\r\n")
    }

    func testHeadingOnlyDraftYieldsEmptyBody() throws {
        let result = InboxDraftParser.content(
            fileName: "only.md", bytes: Data("# Only Heading".utf8))
        guard case .success(let content) = result else {
            return XCTFail("expected a conforming draft, got \(result)")
        }
        XCTAssertEqual(content.title, "Only Heading")
        XCTAssertEqual(content.body, "")
    }

    func testBodyIsTheRemainderAfterTheHeadingLine() throws {
        // The pinned positional reading: the body starts after the heading
        // line's newline — pre-heading content is not carried (the
        // contract's draft model is heading-first title + body, §2.3).
        let text = "intro text\n\n# Title\nbody"
        let result = InboxDraftParser.content(fileName: "d.md", bytes: Data(text.utf8))
        guard case .success(let content) = result else {
            return XCTFail("expected a conforming draft, got \(result)")
        }
        XCTAssertEqual(content.title, "Title")
        XCTAssertEqual(content.body, "body")
    }

    // MARK: - The pure parser: conformance boundaries

    func testBinaryJunkFailsDecode() throws {
        let result = InboxDraftParser.content(
            fileName: "junk.md", bytes: Data([0xFF, 0xFE, 0x28, 0x00, 0xC0]))
        XCTAssertEqual(result, .failure(.binaryJunk(fileName: "junk.md")))
    }

    func testOverOneMiBFailsConformanceWithExactByteCount() throws {
        let bytes = Data(repeating: 0x61, count: InboxDraftParser.maximumByteCount + 1)
        let result = InboxDraftParser.content(fileName: "big.md", bytes: bytes)
        XCTAssertEqual(
            result,
            .failure(.tooLarge(
                fileName: "big.md", byteCount: InboxDraftParser.maximumByteCount + 1)))
    }

    func testExactlyOneMiBIsConforming() throws {
        // The boundary itself imports (size ≤ 1 MiB is conforming).
        var text = "# Boundary\n"
        let filler = InboxDraftParser.maximumByteCount - text.utf8.count
        text += String(repeating: "a", count: filler)
        XCTAssertEqual(Data(text.utf8).count, InboxDraftParser.maximumByteCount)
        let result = InboxDraftParser.content(fileName: "boundary.md", bytes: Data(text.utf8))
        guard case .success(let content) = result else {
            return XCTFail("expected a conforming draft, got \(result)")
        }
        XCTAssertEqual(content.title, "Boundary")
    }

    // MARK: - The import run: green drafts

    func testImportCreatesSchemaCompleteTaskAndRemovesDraft() async throws {
        try writeDraft("draft.md", text: "# Buy milk\n\nGroceries.\n")
        let store = VaultStore(vaultURL: vaultURL)

        let summary = await InboxImporter().run(in: inboxURL, through: store)

        XCTAssertEqual(summary.importedCount, 1)
        XCTAssertTrue(summary.problems.isEmpty)

        // The task: schema-complete via the SAME create path — fresh UUID,
        // the pinned default category, status .toDo, everything else
        // nil/empty (no priority/deadline/project from drafts).
        _ = await store.load()
        let tasks = await store.tasks
        let imported = try XCTUnwrap(tasks.first { $0.title == "Buy milk" })
        XCTAssertEqual(imported.categories.map(\.name), [InboxImporter.defaultCategoryName])
        XCTAssertEqual(imported.status, .toDo)
        XCTAssertNil(imported.project)
        XCTAssertNil(imported.priority)
        XCTAssertNil(imported.effort)
        XCTAssertNil(imported.deadline)
        XCTAssertNil(imported.notes)
        XCTAssertNil(imported.order)
        XCTAssertTrue(imported.subtasks.isEmpty)
        let taskCount = await store.taskCount
        XCTAssertEqual(taskCount, 4, "3 fixture tasks + the import")

        // The file: fixture-style body (leading blank line + the verbatim
        // remainder) after the closing ---, at the pinned slug filename.
        let fileText = try String(
            contentsOfFile: tasksDirectory.appendingPathComponent("Buy milk.md").path,
            encoding: .utf8)
        XCTAssertEqual(
            fileText,
            FrontmatterCodec.encode(
                task: imported, body: "\n\nGroceries.\n"),
            "the import writes the draft body verbatim after the fixture-style separator")

        // The move: the draft is REMOVED from Inbox/.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: draftURL("draft.md").path))
    }

    func testTitleFromFileNameImportUsesEntireContentAsBody() async throws {
        try writeDraft("20260920-101500-buy-milk.md", text: "Plain body only.\n")
        let store = VaultStore(vaultURL: vaultURL)

        let summary = await InboxImporter().run(in: inboxURL, through: store)

        XCTAssertEqual(summary.importedCount, 1)
        _ = await store.load()
        let tasks = await store.tasks
        let imported = try XCTUnwrap(
            tasks.first { $0.title == "20260920-101500-buy-milk" })
        let fileText = try String(
            contentsOfFile: tasksDirectory.appendingPathComponent("20260920-101500-buy-milk.md").path,
            encoding: .utf8)
        XCTAssertEqual(
            fileText,
            FrontmatterCodec.encode(
                task: imported, body: "\nPlain body only.\n"),
            "filename-titled drafts carry the ENTIRE content as the body")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: draftURL("20260920-101500-buy-milk.md").path))
    }

    func testCRLFDraftImportsAndRoundTrips() async throws {
        try writeDraft("crlf.md", text: "# CRLF Task\r\n\r\nLine one.\r\n")
        let store = VaultStore(vaultURL: vaultURL)

        let summary = await InboxImporter().run(in: inboxURL, through: store)

        XCTAssertEqual(summary.importedCount, 1)
        _ = await store.load()
        let tasks = await store.tasks
        let imported = try XCTUnwrap(tasks.first { $0.title == "CRLF Task" })
        // The task file carries the draft's CRLF body bytes verbatim, and
        // a load→update cycle keeps them byte-for-byte.
        let url = tasksDirectory.appendingPathComponent("CRLF Task.md")
        let bytesBefore = try Data(contentsOf: url)
        let (frontmatter, body) = try FrontmatterCodec.split(
            String(decoding: bytesBefore, as: UTF8.self))
        XCTAssertEqual(frontmatter.contains("title: CRLF Task"), true)
        XCTAssertEqual(body, "\n\r\nLine one.\r\n")

        var edited = imported
        edited.title = "CRLF Task (edited)"
        _ = try await store.update(edited)
        // Re-encode must use the ORIGINAL filename (title changes never
        // re-derive filenames); read it back and split again.
        let bytesAfter = try Data(contentsOf: url)
        let (_, bodyAfter) = try FrontmatterCodec.split(
            String(decoding: bytesAfter, as: UTF8.self))
        XCTAssertEqual(bodyAfter, "\n\r\nLine one.\r\n")
    }

    func testHeadingOnlyDraftCreatesTaskWithNoBody() async throws {
        try writeDraft("only.md", text: "# Only Heading")
        let store = VaultStore(vaultURL: vaultURL)

        let summary = await InboxImporter().run(in: inboxURL, through: store)

        XCTAssertEqual(summary.importedCount, 1)
        _ = await store.load()
        let tasks = await store.tasks
        let imported = try XCTUnwrap(tasks.first { $0.title == "Only Heading" })
        let fileText = try String(
            contentsOfFile: tasksDirectory.appendingPathComponent("Only Heading.md").path,
            encoding: .utf8)
        XCTAssertEqual(
            fileText,
            FrontmatterCodec.encode(task: imported, body: ""),
            "an empty remainder keeps today's no-body create shape")
    }

    // MARK: - The import run: non-conforming drafts stay, counted

    func testBinaryJunkDraftStaysByteIdenticalAndIsCounted() async throws {
        let junk = Data([0xFF, 0xFE, 0x00, 0x28, 0xFF])
        try writeDraft("junk.md", bytes: junk)
        let store = VaultStore(vaultURL: vaultURL)

        let summary = await InboxImporter().run(in: inboxURL, through: store)

        XCTAssertEqual(summary.importedCount, 0)
        XCTAssertEqual(
            summary.problems, [.binaryJunk(fileName: "junk.md")])
        XCTAssertEqual(draftData("junk.md"), junk, "never discarded or overwritten")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: inboxURL.path).count, 1)

        // The scan summary counts it as M.
        let scan = await InboxImporter().scanSummary(in: inboxURL)
        XCTAssertEqual(scan, InboxScanSummary(importableDraftCount: 0, problemCount: 1))
    }

    func testTooLargeDraftStaysByteIdenticalAndIsCounted() async throws {
        let big = Data(repeating: 0x61, count: InboxDraftParser.maximumByteCount + 1)
        try writeDraft("big.md", bytes: big)
        let store = VaultStore(vaultURL: vaultURL)

        let summary = await InboxImporter().run(in: inboxURL, through: store)

        XCTAssertEqual(summary.importedCount, 0)
        XCTAssertEqual(
            summary.problems,
            [.tooLarge(
                fileName: "big.md", byteCount: InboxDraftParser.maximumByteCount + 1)])
        XCTAssertEqual(draftData("big.md"), big)
        let taskCount = await store.taskCount
        XCTAssertEqual(taskCount, 0, "no Tasks/ file is written for a non-conforming draft")
    }

    func testUnreadableDraftStaysAndIsCounted() async throws {
        try writeDraft("locked.md", text: "# Unreadable\nbody")
        // Permission-denied: mode 000 denies the read to the owner too.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: draftURL("locked.md").path)
        pathsToRestore.append(draftURL("locked.md"))
        let store = VaultStore(vaultURL: vaultURL)

        let summary = await InboxImporter().run(in: inboxURL, through: store)

        XCTAssertEqual(summary.importedCount, 0)
        XCTAssertEqual(summary.problems, [.unreadable(fileName: "locked.md")])
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: draftURL("locked.md").path, isDirectory: &isDirectory))
        let taskCount = await store.taskCount
        XCTAssertEqual(taskCount, 0)
    }

    // MARK: - Idempotence + later-arriving same-name drafts

    func testImportTwiceYieldsOneTask() async throws {
        try writeDraft("draft.md", text: "# Buy milk\n\nGroceries.\n")
        let importer = InboxImporter()
        let store = VaultStore(vaultURL: vaultURL)

        _ = await importer.run(in: inboxURL, through: store)
        let second = await importer.run(in: inboxURL, through: store)

        XCTAssertEqual(second.importedCount, 0, "the draft is gone — nothing to re-import")
        XCTAssertTrue(second.problems.isEmpty)
        _ = await store.load()
        let taskCount = await store.taskCount
        XCTAssertEqual(taskCount, 4, "one import, one task — import→import = 1 task")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: inboxURL.path).count, 0)
    }

    func testLaterSameNameDraftIsANewDraftWithANewTask() async throws {
        try writeDraft("note.md", text: "# Same Title\nfirst body")
        let importer = InboxImporter()
        let store = VaultStore(vaultURL: vaultURL)

        _ = await importer.run(in: inboxURL, through: store)

        // A LATER-arriving same-name draft is a NEW draft: same heading,
        // fresh UUID, the store's slug-collision suffix handles the file.
        try writeDraft("note.md", text: "# Same Title\nsecond body")
        let second = await importer.run(in: inboxURL, through: store)
        XCTAssertEqual(second.importedCount, 1)

        _ = await store.load()
        let tasks = await store.tasks
        let titled = tasks.filter { $0.title == "Same Title" }
        XCTAssertEqual(titled.count, 2)
        XCTAssertEqual(Set(titled.map(\.id)).count, 2, "fresh UUID per draft")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: inboxURL.path).count, 0)
        let names = try FileManager.default.contentsOfDirectory(atPath: tasksDirectory.path)
            .filter { $0.hasPrefix("Same Title") }
            .sorted()
        XCTAssertEqual(names, ["Same Title-2.md", "Same Title.md"])
    }

    // MARK: - The per-run snapshot (concurrency seam)

    func testDraftArrivingMidImportStaysForTheNextRun() async throws {
        try writeDraft("first.md", text: "# First\nbody")
        let importer = InboxImporter()
        let store = VaultStore(vaultURL: vaultURL)

        // The documented seam: the scan/import split. A draft arriving
        // after the snapshot is simply NOT in it.
        let snapshot = await importer.scanDrafts(in: inboxURL)
        XCTAssertEqual(snapshot, [InboxDraftFile(fileName: "first.md")])
        try writeDraft("late.md", text: "# Late\nbody")

        let first = await importer.importDrafts(
            snapshot, in: inboxURL, through: store)
        XCTAssertEqual(first.importedCount, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: draftURL("late.md").path),
            "the late draft stays — no crash, no duplicate")

        // The next run picks it up.
        let second = await importer.run(in: inboxURL, through: store)
        XCTAssertEqual(second.importedCount, 1)
        _ = await store.load()
        let tasks = await store.tasks
        XCTAssertEqual(tasks.filter { $0.title == "First" }.count, 1)
        XCTAssertEqual(tasks.filter { $0.title == "Late" }.count, 1)
    }

    // MARK: - Missing / empty Inbox

    func testMissingInboxDirectoryIsZeroDraftsWithNoErrors() async throws {
        try FileManager.default.removeItem(at: inboxURL)
        let store = VaultStore(vaultURL: vaultURL)

        let summary = await InboxImporter().run(in: inboxURL, through: store)

        XCTAssertEqual(summary, InboxImportSummary(importedCount: 0, problems: []))
        let scan = await InboxImporter().scanSummary(in: inboxURL)
        XCTAssertEqual(scan, InboxScanSummary(importableDraftCount: 0, problemCount: 0))
    }

    func testEmptyInboxDirectoryIsZeroDraftsWithNoErrors() async throws {
        let store = VaultStore(vaultURL: vaultURL)

        let summary = await InboxImporter().run(in: inboxURL, through: store)

        XCTAssertEqual(summary, InboxImportSummary(importedCount: 0, problems: []))
    }

    // MARK: - Failure paths keep the draft (anti-data-loss)

    func testCreateFailureLeavesDraftUntouched() async throws {
        try writeDraft("draft.md", text: "# Buy milk\n\nGroceries.\n")
        let importer = InboxImporter()
        let store = VaultStore(vaultURL: vaultURL)

        // The seam again: Tasks/ disappears after the scan → the create
        // fails typed — the draft stays byte-identical.
        let snapshot = await importer.scanDrafts(in: inboxURL)
        try FileManager.default.removeItem(at: tasksDirectory)
        let summary = await importer.importDrafts(
            snapshot, in: inboxURL, through: store)

        XCTAssertEqual(summary.importedCount, 0)
        guard case .taskCreationFailed(
            fileName: "draft.md", underlying: .writeFailed(.directoryMissing))
        = summary.problems.first
        else {
            return XCTFail(
                "expected .taskCreationFailed(.writeFailed(.directoryMissing)), got \(summary.problems)")
        }
        XCTAssertEqual(
            draftData("draft.md"), Data("# Buy milk\n\nGroceries.\n".utf8))

        // Recovery: with Tasks/ back, a retry imports cleanly.
        try FileManager.default.createDirectory(
            at: tasksDirectory, withIntermediateDirectories: true)
        let retry = await importer.run(in: inboxURL, through: store)
        XCTAssertEqual(retry.importedCount, 1)
    }

    func testRemovalFailureKeepsDraftAndCountsItAsAProblem() async throws {
        try writeDraft("draft.md", text: "# Buy milk\n\nGroceries.\n")
        let importer = InboxImporter()
        let store = VaultStore(vaultURL: vaultURL)

        // Inbox/ loses write permission AFTER the scan: the task write
        // (Tasks/) succeeds, the draft removal fails — the draft STAYS.
        let snapshot = await importer.scanDrafts(in: inboxURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: inboxURL.path)
        pathsToRestore.append(inboxURL)
        let summary = await importer.importDrafts(
            snapshot, in: inboxURL, through: store)

        XCTAssertEqual(summary.importedCount, 1, "the task WAS created")
        XCTAssertEqual(
            summary.problems, [.draftRemovalFailed(fileName: "draft.md")])
        XCTAssertEqual(
            draftData("draft.md"), Data("# Buy milk\n\nGroceries.\n".utf8))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tasksDirectory.appendingPathComponent("Buy milk.md").path))

        // The counts: the draft still exists and still parses, so the
        // scan counts it importable again (a duplicate re-import would
        // follow — user-recoverable, the documented posture); the
        // REMOVAL problem itself is only known to the import run.
        let scan = await importer.scanSummary(in: inboxURL)
        XCTAssertEqual(scan.importableDraftCount, 1)
    }

    // MARK: - Push-for-free: the #49 hook fires per imported draft

    func testImportFiresOnVaultWriteHookOncePerDraft() async throws {
        try writeDraft("one.md", text: "# One\nbody")
        try writeDraft("two.md", text: "# Two\nbody")
        try writeDraft("junk.md", bytes: Data([0xFF, 0xFE]))
        let counter = HookCounter()
        let store = VaultStore(vaultURL: vaultURL, onVaultWrite: { counter.bump() })

        let summary = await InboxImporter().run(in: inboxURL, through: store)

        XCTAssertEqual(summary.importedCount, 2)
        XCTAssertEqual(
            counter.value, 2,
            "one #49 hook fire per successful create — pushes ride for free; a non-conforming draft fires nothing")
    }

    // MARK: - The same-code-path create(body:) seam

    func testCreateWithBodyWritesBodyAfterTheClosingDelimiter() async throws {
        let store = VaultStore(vaultURL: vaultURL)
        let task = try TaskItem(
            title: "Seam Body", categories: [Category(name: "Admin")])

        _ = try await store.create(task, body: "\nSome body.")

        let fileText = try String(
            contentsOfFile: tasksDirectory.appendingPathComponent("Seam Body.md").path,
            encoding: .utf8)
        XCTAssertEqual(
            fileText,
            FrontmatterCodec.encode(task: task, body: "\nSome body."))
        XCTAssertTrue(
            fileText.hasSuffix("---\n\nSome body."),
            "the fixture-style blank line then the body, verbatim, after ---")
    }

    func testLoadUpdateCyclePreservesCreateBodyByteForByte() async throws {
        let store = VaultStore(vaultURL: vaultURL)
        let task = try TaskItem(
            title: "Seam Cycle", categories: [Category(name: "Admin")])
        _ = try await store.create(task, body: "\nOriginal body.")

        try await store.load()
        let tasks = await store.tasks
        var loaded = try XCTUnwrap(tasks.first { $0.id == task.id })
        loaded.title = "Seam Cycle (edited)"
        _ = try await store.update(loaded)

        // The file keeps its name (title changes never re-derive
        // filenames) and the body survives the whole round trip.
        let fileText = try String(
            contentsOfFile: tasksDirectory.appendingPathComponent("Seam Cycle.md").path,
            encoding: .utf8)
        let (_, body) = try FrontmatterCodec.split(fileText)
        XCTAssertEqual(body, "\nOriginal body.", "byte-for-byte through load→update")
        XCTAssertTrue(
            fileText.contains("title: Seam Cycle (edited)"))
    }

    func testCreateWithDefaultBodyKeepsEmptyBodyBehavior() async throws {
        let store = VaultStore(vaultURL: vaultURL)
        let task = try TaskItem(
            title: "Seam Default", categories: [Category(name: "Admin")])

        _ = try await store.create(task)

        let fileText = try String(
            contentsOfFile: tasksDirectory.appendingPathComponent("Seam Default.md").path,
            encoding: .utf8)
        XCTAssertEqual(
            fileText,
            FrontmatterCodec.encode(task: task, body: ""),
            "the defaulted parameter keeps the pinned #7 empty-body create unchanged")
    }

    // MARK: - Ownership: only Inbox/ reads + Tasks/ creation + removal

    func testImportTouchesOnlyInboxAndTasks() async throws {
        // Lifebot/ content the import must never read or write.
        let lifebot = vaultURL.appendingPathComponent("Lifebot", isDirectory: true)
        try FileManager.default.createDirectory(
            at: lifebot, withIntermediateDirectories: true)
        try Data("recommendation".utf8).write(
            to: lifebot.appendingPathComponent("notes.md"))
        // A stray root file must survive untouched.
        try Data("root".utf8).write(to: vaultURL.appendingPathComponent("README.md"))

        try writeDraft("draft.md", text: "# Buy milk\n\nGroceries.\n")
        let store = VaultStore(vaultURL: vaultURL)
        let before = try snapshotVaultFiles()

        let summary = await InboxImporter().run(in: inboxURL, through: store)

        XCTAssertEqual(summary.importedCount, 1)
        let after = try snapshotVaultFiles()
        // The EXACT diff: the draft removed, the task file added — nothing
        // else (existing tasks, Logs, Lifebot/, root files byte-identical).
        let removed = Set(before.keys).subtracting(after.keys)
        let added = Set(after.keys).subtracting(before.keys)
        XCTAssertEqual(removed, ["Inbox/draft.md"])
        XCTAssertEqual(added, ["Tasks/Buy milk.md"])
        for (key, data) in before where after[key] != nil {
            XCTAssertEqual(
                after[key], data, "\(key) must stay byte-identical (no sessions, no logs, Lifebot untouched)")
        }
    }
}
