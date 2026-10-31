import XCTest
@testable import SyncCore

final class GitToolResolverTests: XCTestCase {
    private let clt = "/Library/Developer/CommandLineTools/usr/bin/git"
    private let xcode = "/Applications/Xcode.app/Contents/Developer/usr/bin/git"

    private func resolver(
        env: [String: String] = [:], selection: String? = nil,
        executables: Set<String> = [], aliases: [String: String] = [:]
    ) -> GitToolResolver {
        GitToolResolver(environment: { env }, fileSystem: .init(
            canonicalPath: { aliases[$0] ?? URL(fileURLWithPath: $0).standardized.path },
            symbolicLinkTarget: { _ in selection },
            isRegularExecutable: { executables.contains($0) }))
    }

    func testCLTOnlyAndFallbackOrder() {
        XCTAssertEqual(resolver(executables: [clt]).resolve(), .available(path: clt))
        XCTAssertEqual(resolver(executables: [clt, xcode]).resolve(), .available(path: clt))
        XCTAssertEqual(resolver(executables: [xcode]).resolve(), .available(path: xcode))
        XCTAssertEqual(resolver().resolve(), .unavailable)
    }

    func testSelectedXcodeWithSpacesAndRelativeSelection() {
        let developer = "/Tools/Developer Tools/Xcode.app/Contents/Developer"
        let path = developer + "/usr/bin/git"
        XCTAssertEqual(resolver(selection: developer, executables: [path, clt]).resolve(), .available(path: path))
        XCTAssertEqual(resolver(selection: "../../Library/Developer/CommandLineTools", executables: [clt]).resolve(), .available(path: clt))
    }

    func testDeveloperDirAppAndDirectoryOverrideSelection() {
        let app = "/Tools/Selected Xcode.app"
        let developer = app + "/Contents/Developer"
        for override in [app, developer] {
            let path = developer + "/usr/bin/git"
            XCTAssertEqual(resolver(env: ["DEVELOPER_DIR": override], selection: "/invalid", executables: [path, clt]).resolve(), .available(path: path))
        }
    }

    func testInvalidAndRelativeOverrideFailClosed() {
        for value in ["relative", "/absent", " /invalid ", "/Tools/Bad.app"] {
            XCTAssertEqual(resolver(env: ["DEVELOPER_DIR": value], executables: [clt, xcode]).resolve(), .unavailable, value)
        }
        XCTAssertEqual(resolver(env: ["DEVELOPER_DIR": " \n"], executables: [clt]).resolve(), .available(path: clt))
    }

    func testDanglingUnreadableSelectionDoesNotFallback() {
        for value in ["/dangling", "", "relative-missing"] {
            XCTAssertEqual(resolver(selection: value, executables: [clt, xcode]).resolve(), .unavailable)
        }
    }

    func testCanonicalAliasToRealAndShimCandidate() {
        XCTAssertEqual(resolver(executables: ["/real/git"], aliases: [clt: "/real/git"]).resolve(), .available(path: "/real/git"))
        XCTAssertEqual(resolver(executables: ["/usr/bin/git"], aliases: [clt: "/usr/bin/git"]).resolve(), .unavailable)
    }

    func testExplicitBinaryAndAliasToShimCannotBypassPolicy() {
        let policy = resolver(executables: ["/real/git", "/usr/bin/git", clt], aliases: ["/alias/git": "/usr/bin/git"])
        XCTAssertEqual(policy.resolve(gitBinary: "/real/git"), .available(path: "/real/git"))
        XCTAssertEqual(policy.resolve(gitBinary: "relative/git"), .unavailable)
        XCTAssertEqual(policy.resolve(gitBinary: "/missing/git"), .unavailable)
        XCTAssertEqual(policy.resolve(gitBinary: "/alias/git"), .available(path: clt))
        XCTAssertEqual(SyncHealthEvaluator.staticFailureReason(vaultPath: nil, remoteURL: nil, gitBinary: "/missing/git", resolver: policy), "the git binary was not found at /missing/git")
    }

    func testLiveFilesystemRejectsMissingNonExecutableDirectoryAndResolvesSymlink() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let tool = root.appendingPathComponent("real git")
        let alias = root.appendingPathComponent("alias")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: tool)
        XCTAssertEqual(GitToolResolver().resolve(gitBinary: tool.path), .unavailable)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        try fm.createSymbolicLink(at: alias, withDestinationURL: tool)
        XCTAssertEqual(GitToolResolver().resolve(gitBinary: alias.path), .available(path: tool.resolvingSymlinksInPath().path))
        XCTAssertEqual(GitToolResolver().resolve(gitBinary: root.path), .unavailable)
        try fm.removeItem(at: tool)
        XCTAssertEqual(GitToolResolver().resolve(gitBinary: alias.path), .unavailable)
        let shimAlias = root.appendingPathComponent("shim alias")
        try fm.createSymbolicLink(atPath: shimAlias.path, withDestinationPath: "/usr/bin/git")
        let noTools = GitToolResolver(environment: { ["DEVELOPER_DIR": "/missing-tools"] })
        XCTAssertEqual(noTools.resolve(gitBinary: shimAlias.path), .unavailable)
    }

    final class LaunchLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        func record(_ process: Process) {
            lock.lock(); defer { lock.unlock() }
            entries.append(process.executableURL?.path ?? "")
        }
        var paths: [String] { lock.lock(); defer { lock.unlock() }; return entries }
    }

    func testRunnerMissingToolsRefusesBeforeLaunchIncludingShimAlias() async throws {
        let log = LaunchLog()
        for requested in ["/usr/bin/git", "/alias/git"] {
            let runner = ProcessGitRunner(gitBinary: requested, resolver: resolver(aliases: ["/alias/git": "/usr/bin/git"]), willLaunch: { log.record($0) })
            do {
                _ = try await runner.run(arguments: ["--version"])
                XCTFail("expected toolsUnavailable")
            } catch { XCTAssertEqual(error as? GitRunnerError, .toolsUnavailable) }
        }
        XCTAssertEqual(log.paths, [])
    }

    func testRunnerLaunchesCanonicalRealPathWithUnchangedProcessContract() async throws {
        let log = LaunchLog()
        let runner = ProcessGitRunner(gitBinary: "/bin/echo", extraArguments: ["prefix"], timeoutSeconds: 1, willLaunch: { process in
            log.record(process)
            XCTAssertEqual(process.arguments, ["prefix", "hello world"])
            XCTAssertNil(process.environment)
            XCTAssertTrue((process.standardInput as? FileHandle) === FileHandle.nullDevice)
        })
        let outcome = try await runner.run(arguments: ["hello world"])
        XCTAssertEqual(outcome, GitOutcome(exitStatus: 0, stdout: "prefix hello world\n", stderr: ""))
        XCTAssertEqual(log.paths, [URL(fileURLWithPath: "/bin/echo").resolvingSymlinksInPath().path])
    }

    func testRunnerWatchdogAndMissingExplicitBinaryRemainOperationFailures() async throws {
        let runner = ProcessGitRunner(gitBinary: "/bin/sleep", timeoutSeconds: 0.05)
        let outcome = try await runner.run(arguments: ["5"])
        XCTAssertNotEqual(outcome.exitStatus, 0)
        do {
            _ = try await ProcessGitRunner(gitBinary: "/missing/git").run(arguments: [])
            XCTFail("expected missing explicit binary")
        } catch { XCTAssertEqual(error as? GitRunnerError, .spawnFailed("the git binary was not found at /missing/git")) }
    }

    func testToolsFirstBeforeVaultAndRemote() {
        XCTAssertEqual(SyncHealthEvaluator.staticFailureReason(vaultPath: nil, remoteURL: nil, gitBinary: "/usr/bin/git", resolver: resolver()), SyncHealthEvaluator.toolsUnavailableReason)
    }

    actor CountingRunner: GitRunner {
        var calls = 0
        func run(arguments: [String]) async throws -> GitOutcome { calls += 1; return .init(exitStatus: 0, stdout: "", stderr: "") }
    }

    func testEveryUnavailableEntryAndDisabledEntriesWithPresentAndMissingTools() async throws {
        let fixture = try await SyncCoordinatorTests.SyncFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        for enabled in [true, false] {
            for toolsPresent in [false, true] where !enabled || !toolsPresent {
                let runner = CountingRunner()
                let policy = resolver(executables: toolsPresent ? [clt] : [])
                let coordinator = SyncCoordinator(configuration: .init(vaultURL: fixture.vaultURL, remoteURL: fixture.remoteURLString, debounceIntervalSeconds: 0.01, pullIntervalSeconds: 0.01), runner: runner, resolver: policy)
                await coordinator.applyEnabled(enabled) // enable toggle
                let expected: SyncPullOutcome = enabled ? .unavailable(SyncHealthEvaluator.toolsUnavailableReason) : .disabled
                let launch = await coordinator.pullOnce()
                XCTAssertEqual(launch, expected)
                let preImport = await coordinator.pullOnce()
                XCTAssertEqual(preImport, expected)
                await coordinator.probeReachability() // settings appear
                await coordinator.setRemote(fixture.remoteURLString)
                await coordinator.probeReachability() // remote change
                await coordinator.noteVaultWrite() // debounce/quit flush
                let flush = await coordinator.flush()
                XCTAssertEqual(flush, expected)
                async let first = coordinator.pullOnce()
                async let followUp = coordinator.pullOnce()
                let outcomes = await [first, followUp]
                XCTAssertEqual(outcomes, [expected, expected])
                try await Task.sleep(nanoseconds: 60_000_000) // several short periodic ticks
                let health = await coordinator.health
                XCTAssertEqual(health, enabled ? .unavailable(reason: SyncHealthEvaluator.toolsUnavailableReason) : .disabled)
                let calls = await runner.calls
                XCTAssertEqual(calls, 0)
                await coordinator.stop()
            }
        }
    }

    final class DisappearingTools: @unchecked Sendable {
        private let lock = NSLock()
        private var checks = 0
        func exists() -> Bool { lock.lock(); defer { lock.unlock() }; checks += 1; return checks <= 2 }
    }

    func testProbeToolsDisappearAtRunnerBoundaryReportsUnavailable() async throws {
        let fixture = try await SyncCoordinatorTests.SyncFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let state = DisappearingTools()
        let log = LaunchLog()
        let policy = GitToolResolver(environment: { ["DEVELOPER_DIR": "/selected"] }, fileSystem: .init(canonicalPath: { $0 }, symbolicLinkTarget: { _ in nil }, isRegularExecutable: { _ in state.exists() }))
        let runner = ProcessGitRunner(resolver: policy, willLaunch: { log.record($0) })
        let coordinator = SyncCoordinator(configuration: .init(vaultURL: fixture.vaultURL, remoteURL: fixture.remoteURLString), runner: runner, resolver: policy)
        await coordinator.applyEnabled(true)
        await coordinator.probeReachability()
        let health = await coordinator.health
        XCTAssertEqual(health, .unavailable(reason: SyncHealthEvaluator.toolsUnavailableReason))
        XCTAssertEqual(log.paths, [])
        await coordinator.stop()
    }

    final class ToolSwitch: @unchecked Sendable {
        private let lock = NSLock()
        private var present = true
        func remove() { lock.lock(); defer { lock.unlock() }; present = false }
        func exists() -> Bool { lock.lock(); defer { lock.unlock() }; return present }
    }

    actor ParkedRunner: GitRunner {
        var calls = 0
        private var started: CheckedContinuation<Void, Never>?
        private var parked: CheckedContinuation<Void, Never>?
        func waitUntilStarted() async {
            if calls > 0 { return }
            await withCheckedContinuation { started = $0 }
        }
        func release() { parked?.resume(); parked = nil }
        func run(arguments: [String]) async throws -> GitOutcome {
            calls += 1
            await withCheckedContinuation { continuation in
                parked = continuation
                started?.resume(); started = nil
            }
            throw GitRunnerError.toolsUnavailable
        }
    }

    func testSingleFlightFollowUpRechecksToolsAfterAnInFlightLoss() async throws {
        let fixture = try await SyncCoordinatorTests.SyncFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let state = ToolSwitch()
        let policy = GitToolResolver(environment: { ["DEVELOPER_DIR": "/selected"] }, fileSystem: .init(canonicalPath: { $0 }, symbolicLinkTarget: { _ in nil }, isRegularExecutable: { _ in state.exists() }))
        let runner = ParkedRunner()
        let events = SyncCoordinatorTests.SyncEventLog()
        let coordinator = SyncCoordinator(configuration: .init(vaultURL: fixture.vaultURL, remoteURL: fixture.remoteURLString), runner: runner, resolver: policy, onHealthChange: { _, health in events.record(health) })
        await coordinator.applyEnabled(true)
        let first = Task { await coordinator.pullOnce() }
        await runner.waitUntilStarted()
        state.remove()
        await coordinator.noteVaultWrite() // deterministic pending follow-up while leased
        await runner.release()
        let outcome = await first.value
        XCTAssertEqual(outcome, .unavailable(SyncHealthEvaluator.toolsUnavailableReason))
        let calls = await runner.calls
        XCTAssertEqual(calls, 1) // only the invocation begun BEFORE tools vanished
        XCTAssertEqual(events.count(of: .unavailable(reason: SyncHealthEvaluator.toolsUnavailableReason)), 2)
        await coordinator.stop()
    }

    func testToolsDisappearBetweenStaticAndRunnerMapsUnavailableWithoutSpawn() async throws {
        let fixture = try await SyncCoordinatorTests.SyncFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let state = DisappearingTools()
        let log = LaunchLog()
        let policy = GitToolResolver(environment: { ["DEVELOPER_DIR": "/selected"] }, fileSystem: .init(canonicalPath: { $0 }, symbolicLinkTarget: { _ in nil }, isRegularExecutable: { _ in state.exists() }))
        let runner = ProcessGitRunner(resolver: policy, willLaunch: { log.record($0) })
        let coordinator = SyncCoordinator(configuration: .init(vaultURL: fixture.vaultURL, remoteURL: fixture.remoteURLString), runner: runner, resolver: policy)
        await coordinator.applyEnabled(true) // check 1
        let outcome = await coordinator.pullOnce() // check 2 static; check 3 runner
        XCTAssertEqual(outcome, .unavailable(SyncHealthEvaluator.toolsUnavailableReason))
        let health = await coordinator.health
        XCTAssertEqual(health, .unavailable(reason: SyncHealthEvaluator.toolsUnavailableReason))
        XCTAssertEqual(log.paths, [])
        await coordinator.stop()
    }
}
