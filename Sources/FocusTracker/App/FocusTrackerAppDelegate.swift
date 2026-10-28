import AppKit

/// AppKit's clean-termination callback. It performs one best-effort snapshot
/// save and implements no termination-decision method, so Cmd+Q is never
/// vetoed or left waiting even if persistence fails.
///
/// Issue #49 adds the ONE additive #49 termination hook: `terminationFlush`
/// runs AFTER `snapshotSave` (so the freshest #13 recovery state ships with
/// the final vault writes' push). It is synchronous, best-effort and
/// watchdog-bounded — failure never vetoes or defers termination.
/// SIGKILL/force-quit skips it (the documented honest-loss posture, #27).
@MainActor
final class FocusTrackerAppDelegate: NSObject, NSApplicationDelegate {
    var snapshotSave: () -> Void = {}

    /// The #49 quit flush (the sync coordinator's debounced writes pushed
    /// before termination); wired by the app shell like `snapshotSave`.
    var terminationFlush: () -> Void = {}

    func applicationWillTerminate(_ notification: Notification) {
        snapshotSave()
        terminationFlush()
    }
}
