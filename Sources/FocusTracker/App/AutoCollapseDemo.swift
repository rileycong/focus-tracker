import AppKit
import Foundation

/// Real-app compact-mode lifecycle harness. Inert unless launched with
/// `-autoCollapseDemo`; defaults to three collapse/restore cycles.
@MainActor
enum AutoCollapseDemo {
    static let launchArgument = "-autoCollapseDemo"
    static let cyclesArgument = "-autoCollapseDemoCycles"
    static let logFileArgument = "-autoCollapseDemoLog"
    static let traceArgument = "-autoCollapseDemoTrace"

    private static var logFile: FileHandle?
    private static var hasStarted = false
    private static var telemetryInstalled = false
    private static var traceInstalled = false
    private static var traceStart = Date()

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// Installs the launch-lifecycle telemetry (and the log file) at
    /// APP-INIT, i.e. BEFORE the SwiftUI scene exists: the resize trace,
    /// a 1s launch-progress heartbeat (window count / active / finishing-
    /// launch flags), and the didFinishLaunching / didBecomeActive
    /// milestones. When the scene never presents, this pinpoints the last
    /// lifecycle milestone reached — the frequent-launches state where the
    /// window never appears is otherwise undiagnosable from the outside
    /// (issue #44 amendment diagnosis).
    static func installEarlyTelemetryIfRequested() {
        guard isEnabled, !telemetryInstalled else { return }
        telemetryInstalled = true
        openLogIfRequested()
        startTraceIfRequested()
        let launched = Date()
        let center = NotificationCenter.default
        center.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: nil,
            queue: .main
        ) { _ in
            log("TELEMETRY didFinishLaunching")
        }
        center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil,
            queue: .main
        ) { _ in
            log("TELEMETRY didBecomeActive")
        }
        center.addObserver(
            forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main
        ) { note in
            let number = (note.object as? NSWindow)?.windowNumber ?? -1
            log("TELEMETRY window#\(number) didBecomeMain")
        }
        center.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { note in
            let number = (note.object as? NSWindow)?.windowNumber ?? -1
            log("TELEMETRY window#\(number) willClose")
        }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            let elapsed = Date().timeIntervalSince(launched)
            guard elapsed < 30, let app = NSApplication.shared as NSApplication? else { return }
            log(
                "TELEMETRY +\(Int(elapsed))s windows=\(app.windows.count) isActive=\(app.isActive) "
                    + "hidden=\(app.isHidden) finishLaunching=\(app.isRunning)")
        }
    }

    /// Logs every live resize of every window with a timestamp, so the
    /// collapse/restore GEOMETRY sequence becomes attributable: the
    /// controller's own compact/restore `setFrame`, SwiftUI's
    /// transaction-geometry pass, and any AeroSpace re-tile each produce
    /// their own jumps (issue #44 amendment diagnosis).
    ///
    /// Amendment 2 upgrades the trace with two attribution probes (both
    /// still inert without `-autoCollapseDemoTrace`):
    /// - For the app's MAIN window, every didResize also logs the observer's
    ///   CALL STACK. NotificationCenter delivers didResize SYNCHRONOUSLY
    ///   inside the resizer's stack, so the stack names the geometry writer
    ///   (our controller's `setFrame`, SwiftUI's hosting-view layout pass,
    ///   or a window-server/AppKit event-driven resize — the shape an
    ///   external tiler's snap-back takes).
    /// - A background task polls `aerospace list-windows` (~10 Hz) and logs
    ///   every flip of OUR window's AeroSpace layout (floating/tiling), so
    ///   the layout flips sequence against the frame trace.
    private static func startTraceIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains(traceArgument),
            !traceInstalled
        else { return }
        traceInstalled = true
        traceStart = Date()
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: nil, queue: .main
        ) { note in
            guard let window = note.object as? NSWindow else { return }
            let frame = window.frame
            log(String(
                format: "TRACE +%.3fs #%d frame=(%.1f, %.1f, %.1f, %.1f) layout=(%.1f, %.1f) level=%d",
                Date().timeIntervalSince(traceStart),
                window.windowNumber,
                frame.minX, frame.minY, frame.width, frame.height,
                window.contentLayoutRect.width, window.contentLayoutRect.height,
                window.level.rawValue))
            // Main-window resizes get the stack probe (the 64×64 SwiftUI
            // sidecar and internal system windows are noise).
            if window.frame.width > 200, window.frame.height > 100 {
                let stack = Thread.callStackSymbols
                    .dropFirst(2)
                    .prefix(28)
                    .map { line in
                        let parts = line.split(separator: " ", maxSplits: 3)
                        guard parts.count >= 4 else { return String(line) }
                        return String(parts[3])
                    }
                    .joined(separator: " <- ")
                log("STACK #\(window.windowNumber) \(stack)")
            }
        }
        Task.detached(priority: .userInitiated) {
            await pollAeroSpaceLayout()
        }
    }

    /// ~10 Hz background poll of OUR window's AeroSpace layout state,
    /// timestamped into the demo log. Best-effort: the CLI may be absent
    /// (then this logs one line and stops).
    private static func pollAeroSpaceLayout() async {
        guard let aerospace = AeroSpaceCLI.resolveExecutableURL() else {
            log("AERO aerospace binary absent — layout polling disabled")
            return
        }
        let runner = SystemAeroSpaceProcessRunner()
        let pollArguments = [
            "list-windows", "--all", "--format",
            "%{window-id} %{app-bundle-id} %{window-layout}"
        ]
        var last: String?
        while !Task.isCancelled {
            let outcome = await runner.run(aerospace, pollArguments)
            guard outcome.isSuccess else {
                try? await Task.sleep(for: .milliseconds(200))
                continue
            }
            let line = AeroSpaceCLI.parseWindowLine(
                outcome.stdout, bundleID: AeroSpaceCLI.appBundleID)
            if line != last {
                log(String(
                    format: "AERO +%.3fs %@",
                    Date().timeIntervalSince(traceStart), line ?? "absent"))
                last = line
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    static var cycleCount: Int {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: cyclesArgument),
            index + 1 < arguments.count,
            let count = Int(arguments[index + 1]), count >= 1
        else { return 3 }
        return count
    }

    static func runIfNeeded(model: AppModel) async {
        guard isEnabled, !hasStarted else { return }
        hasStarted = true
        openLogIfRequested()
        startTraceIfRequested()
        let identity = ObjectIdentifier(model)
        let initializations = AppModel.initializationCount
        let bootstraps = AppModel.bootstrapCount
        log("START model=\(identity) initializations=\(initializations) bootstraps=\(bootstraps)")

        await waitForVaultLoad(model)
        await ensureSessionStarted(model)
        try? await Task.sleep(for: .milliseconds(500))

        for cycle in 1...cycleCount {
            logState("cycle \(cycle) before collapse", model: model, identity: identity)
            model.collapseToMiniTimer()
            try? await Task.sleep(for: .seconds(1))
            logState("cycle \(cycle) compact", model: model, identity: identity)
            model.restoreFromMiniTimer()
            try? await Task.sleep(for: .seconds(1))
            logState("cycle \(cycle) restored", model: model, identity: identity)
        }

        let stable = ObjectIdentifier(model) == identity
            && AppModel.initializationCount == initializations
            && AppModel.bootstrapCount == bootstraps
            && !isRecoveryPrompt(model.appPhase)
        log("RESULT stable=\(stable) model=\(ObjectIdentifier(model)) initializations=\(AppModel.initializationCount) bootstraps=\(AppModel.bootstrapCount) recoveryPrompt=\(isRecoveryPrompt(model.appPhase))")
        finishSession(model)
        try? await Task.sleep(for: .milliseconds(300))
        NSApp.terminate(nil)
    }

    private static func waitForVaultLoad(_ model: AppModel) async {
        for _ in 0..<25 {
            if case .loaded = model.vaultState { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private static func ensureSessionStarted(_ model: AppModel) async {
        if model.pendingSessionRecovery != nil { model.discardPendingSession() }
        guard !model.isSessionActive else { return }
        if let task = model.tasks.first {
            _ = try? await model.startSession(taskID: task.id, duration: 3600)
        } else {
            _ = try? await model.startAdHocSession(
                title: "Compact lifecycle diagnostic",
                categoryNames: ["Diagnostic"], duration: 3600)
        }
    }

    private static func finishSession(_ model: AppModel) {
        guard case .timerView = model.appPhase, model.isSessionActive else { return }
        _ = try? model.endSession()
        model.discardEndOfSession()
    }

    private static func logState(
        _ label: String, model: AppModel, identity: ObjectIdentifier
    ) {
        let windows = NSApp.windows.map {
            "#\($0.windowNumber):style=\($0.styleMask.rawValue):frame=\($0.frame)"
                + ":layout=\($0.contentLayoutRect.size)"
                + ":level=\($0.level.rawValue)"
        }.joined(separator: ",")
        log("\(label) modelStable=\(ObjectIdentifier(model) == identity) initializations=\(AppModel.initializationCount) bootstraps=\(AppModel.bootstrapCount) recoveryPrompt=\(isRecoveryPrompt(model.appPhase)) windows=[\(windows)]")
    }

    private static func isRecoveryPrompt(_ phase: AppModel.AppPhase) -> Bool {
        if case .recoveryPrompt = phase { return true }
        return false
    }

    private static func openLogIfRequested() {
        guard logFile == nil else { return }
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: logFileArgument),
            index + 1 < arguments.count
        else { return }
        let path = arguments[index + 1]
        FileManager.default.createFile(atPath: path, contents: nil)
        logFile = FileHandle(forWritingAtPath: path)
    }

    private static func log(_ message: String) {
        let data = Data("[auto-collapse-demo] \(message)\n".utf8)
        FileHandle.standardOutput.write(data)
        try? logFile?.write(contentsOf: data)
    }
}
