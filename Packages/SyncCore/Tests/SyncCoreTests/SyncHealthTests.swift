import XCTest
@testable import SyncCore

/// The [Health] criterion's STATIC precondition mapping (issue #49): the
/// evaluator's reasons, asserted EXACTLY — these clauses surface verbatim in
/// the Settings row through the wording function. Foundation-only: the
/// mapping is XCTest-able without AppKit (the [SyncCore packaging] pin).
final class SyncHealthTests: XCTestCase {

    private func makeVaultDirectory(
        withGitDirectory: Bool, file: StaticString = #filePath, line: UInt = #line
    ) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft49-health-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        if withGitDirectory {
            try FileManager.default.createDirectory(
                at: url.appendingPathComponent(".git", isDirectory: true),
                withIntermediateDirectories: true)
        }
        return url.path
    }

    func testGitBinaryMissingIsTheFirstCheck() throws {
        // Even with everything else broken, the binary check wins.
        let reason = SyncHealthEvaluator.staticFailureReason(
            vaultPath: nil, remoteURL: nil, gitBinary: "/nonexistent/ft49/git")
        XCTAssertEqual(
            reason, "the git binary was not found at /nonexistent/ft49/git")
    }

    func testNoVaultConfigured() {
        let reason = SyncHealthEvaluator.staticFailureReason(
            vaultPath: nil, remoteURL: "file:///tmp/origin.git",
            gitBinary: ProcessGitRunner.defaultGitBinary)
        XCTAssertEqual(reason, "no vault is configured")

        let blank = SyncHealthEvaluator.staticFailureReason(
            vaultPath: "   ", remoteURL: "file:///tmp/origin.git",
            gitBinary: ProcessGitRunner.defaultGitBinary)
        XCTAssertEqual(blank, "no vault is configured")
    }

    func testVaultFolderMissingOnDisk() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft49-missing-\(UUID().uuidString)").path
        let reason = SyncHealthEvaluator.staticFailureReason(
            vaultPath: missing, remoteURL: "file:///tmp/origin.git",
            gitBinary: ProcessGitRunner.defaultGitBinary)
        XCTAssertEqual(reason, "the vault folder does not exist on disk")
    }

    func testVaultNotAGitRepositoryIsThePinnedMachineFact() throws {
        // The real vault has NO .git today (VS-2 pending) — TODAY's correct
        // end state with the toggle ON is exactly this `.unavailable` reason.
        let vault = try makeVaultDirectory(withGitDirectory: false)
        let reason = SyncHealthEvaluator.staticFailureReason(
            vaultPath: vault, remoteURL: "file:///tmp/origin.git",
            gitBinary: ProcessGitRunner.defaultGitBinary)
        XCTAssertEqual(reason, "the vault is not a git repository")
        XCTAssertTrue(reason?.contains("not a git repository") ?? false)
    }

    func testRemoteResolvingToNothingIsTheLastCheck() throws {
        let vault = try makeVaultDirectory(withGitDirectory: true)
        let reason = SyncHealthEvaluator.staticFailureReason(
            vaultPath: vault, remoteURL: nil,
            gitBinary: ProcessGitRunner.defaultGitBinary)
        XCTAssertEqual(reason, "no sync remote is configured")
        XCTAssertEqual(reason, SyncHealthEvaluator.noRemoteReason)

        let blank = SyncHealthEvaluator.staticFailureReason(
            vaultPath: vault, remoteURL: "   ",
            gitBinary: ProcessGitRunner.defaultGitBinary)
        XCTAssertEqual(blank, "no sync remote is configured")
        XCTAssertEqual(blank, SyncHealthEvaluator.noRemoteReason)
    }

    func testAllPreconditionsHoldYieldsNil() throws {
        let vault = try makeVaultDirectory(withGitDirectory: true)
        let reason = SyncHealthEvaluator.staticFailureReason(
            vaultPath: vault, remoteURL: "file:///tmp/origin.git",
            gitBinary: ProcessGitRunner.defaultGitBinary)
        XCTAssertNil(reason)
    }
}
