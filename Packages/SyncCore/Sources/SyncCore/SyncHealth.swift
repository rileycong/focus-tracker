import Foundation

/// The vault-sync health surface (issue #49, the [Health] criterion): the
/// EXACTLY-four-state vocabulary the Settings row renders.
///
/// - `.disabled` — sync is off (the shipped-by-default, persisted-off state).
/// - `.unavailable(reason:)` — a STATIC precondition fails: the git binary
///   absent, the vault nil/missing/not a git repo, or the remote setting
///   resolving to nothing. In these the toggle control additionally renders
///   disabled, the reason is shown, and the engine never spawns anything.
/// - `.idle` — enabled, preconditions OK, the last attempt had no error.
/// - `.error(reason)` — the last completed cycle/probe failed (unreachable,
///   auth, non-ff/divergence, timeout, commit/push failure). Sticky until a
///   later successful cycle flips it to `.idle`; in-memory only (a launch
///   starts honest: `.disabled`/`.unavailable`/`.idle` until the first
///   attempt).
public enum SyncHealth: Equatable, Sendable {
    case disabled
    case unavailable(reason: String)
    case idle
    case error(String)
}

/// The static-precondition evaluator (issue #49, the [Health] criterion).
/// Foundation-only, no I/O beyond `FileManager` existence probes — a cycle
/// or the Settings row calls it FIRST; a non-nil reason means "sync stays
/// off" and NOTHING is spawned (zero git processes by construction).
public enum SyncHealthEvaluator {

    /// The reason text for a nil/blank remote (issue #57): the app and its
    /// views compare health by VALUE against this constant — never against
    /// a duplicated literal. The text itself is unchanged from #49.
    public static let noRemoteReason = "no sync remote is configured"

    /// Returns nil when all static preconditions hold, otherwise the pinned
    /// reason clause. Check order follows the [Health] pin: the git binary →
    /// the vault configured → the vault on disk → the vault a git repo → the
    /// remote resolved. Every reason reads as a clause of the Settings row's
    /// wording function (tests assert these EXACT strings).
    public static func staticFailureReason(
        vaultPath: String?, remoteURL: String?, gitBinary: String
    ) -> String? {
        guard FileManager.default.isExecutableFile(atPath: gitBinary) else {
            return "the git binary was not found at \(gitBinary)"
        }
        guard let vaultPath,
            !vaultPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return "no vault is configured"
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: vaultPath, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return "the vault folder does not exist on disk"
        }
        guard FileManager.default.fileExists(
            atPath: (vaultPath as NSString).appendingPathComponent(".git"))
        else {
            return "the vault is not a git repository"
        }
        guard let remoteURL,
            !remoteURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return noRemoteReason
        }
        return nil
    }
}
