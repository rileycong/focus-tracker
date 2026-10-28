/// The pure history-comparison inputs (issue #49, the [Push] criterion):
/// what the vault's HEAD looks like relative to `origin/<branch>` after a
/// fetch. Produced by the coordinator's read step; consumed by the ONE
/// decision function below — the thin Process executor never decides.
public struct SyncGraphState: Equatable, Sendable {
    /// The vault repo's HEAD is unborn (no commits yet — `rev-parse --verify
    /// HEAD` failed while `symbolic-ref` named a branch). The FIRST
    /// commit + `push -u` creates the branch, so this is a legal, recoverable
    /// shape, not an error.
    public let headUnborn: Bool
    /// Whether the fetched `origin/<branch>` ref exists.
    public let remoteBranchExists: Bool
    /// Commits the vault's HEAD has that the remote's branch does not
    /// (left count). Always 0 when the HEAD is unborn or the remote branch
    /// is missing — there is nothing comparable.
    public let ahead: Int
    /// Commits the remote's branch has that the vault's HEAD does not
    /// (right count). When the HEAD is unborn this is the remote branch's
    /// whole count.
    public let behind: Int

    public init(headUnborn: Bool, remoteBranchExists: Bool, ahead: Int, behind: Int) {
        self.headUnborn = headUnborn
        self.remoteBranchExists = remoteBranchExists
        self.ahead = ahead
        self.behind = behind
    }
}

/// The ONE decision output (issue #49): what the cycle does with the
/// compared histories. `.proceed` — no fast-forward is needed, the cycle
/// continues (a push cycle then stages/commits/pushes; a pull cycle records
/// "up to date"). `.fastForward` — strictly behind: `merge --ff-only`.
/// `.divergenceStop` — BOTH sides moved (or an unborn HEAD faces a
/// non-empty remote): STOP, surface in the Settings row, never auto-merge,
/// never force (contract §7.4).
public enum SyncPlanAction: Equatable, Sendable {
    case proceed
    case fastForward
    case divergenceStop
}

public enum SyncPlan {

    /// The pure decision. Exhausted by tests over the whole
    /// (unborn × remoteExists × ahead==0/1 × behind==0/1) matrix — the
    /// decision depends only on each count's zero-vs-positive class, so
    /// that enumeration IS the whole input space.
    public static func decide(_ state: SyncGraphState) -> SyncPlanAction {
        if state.headUnborn {
            // No remote branch yet: the first commit + `push -u` creates it
            // (the pinned unborn-legal case).
            if !state.remoteBranchExists { return .proceed }
            // Unborn HEAD facing a populated remote: a fast-forward cannot
            // target nothing — histories need a manual resolve.
            return state.behind > 0 ? .divergenceStop : .proceed
        }
        if !state.remoteBranchExists { return .proceed }
        if state.ahead > 0 && state.behind > 0 { return .divergenceStop }
        if state.behind > 0 { return .fastForward }
        return .proceed
    }
}
