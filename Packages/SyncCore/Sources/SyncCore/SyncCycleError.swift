/// The failing step of a sync cycle (issue #49, the [Push] criterion). ONE
/// typed Equatable error case carries the failing step + the stderr tail —
/// never a silent no-op, never `--force`.
public enum SyncCycleStep: Equatable, Sendable, CaseIterable {
    case ensureOrigin
    case fetch
    case compareHistory
    case fastForward
    case stageChanges
    case commit
    case push
    case diverged

    public var displayName: String {
        switch self {
        case .ensureOrigin: return "remote setup"
        case .fetch: return "fetch"
        case .compareHistory: return "history comparison"
        case .fastForward: return "fast-forward"
        case .stageChanges: return "staging"
        case .commit: return "commit"
        case .push: return "push"
        case .diverged: return "divergence"
        }
    }
}

/// The ONE typed, Equatable failure of a sync cycle: the failing step plus
/// the detail (a stderr tail for step failures; the pinned divergence
/// sentence for the `.diverged` stop).
public struct SyncCycleError: Error, Equatable, Sendable {
    /// The upper bound of the stderr/detail tail carried by the error (and
    /// therefore by the Settings row's problem wording).
    public static let detailTailLimit = 400

    public let step: SyncCycleStep
    public let detail: String

    public init(step: SyncCycleStep, detail: String) {
        self.step = step
        self.detail = detail
    }

    /// The pinned divergence-STOP error: the wording states that histories
    /// need a manual resolve (no auto-merge) — the exact string the Settings
    /// row shows through the wording function (tests assert it exactly).
    public static func diverged(ahead: Int, behind: Int) -> SyncCycleError {
        SyncCycleError(
            step: .diverged,
            detail: "The vault and the origin have diverged (ahead \(ahead), behind \(behind)) "
                + "— resolve the histories manually (no auto-merge).")
    }

    /// The Settings row's problem wording: the divergence sentence verbatim;
    /// a step failure as "<step> failed: <tail>".
    public var displayReason: String {
        if step == .diverged { return detail }
        return "\(step.displayName) failed: \(detail)"
    }

    /// Extracts the stderr tail (or stdout when stderr is empty) — the ONLY
    /// sanctioned detail source; bounded to `detailTailLimit` characters.
    public static func detailTail(from outcome: GitOutcome) -> String {
        let raw = outcome.stderr.isEmpty ? outcome.stdout : outcome.stderr
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > detailTailLimit else { return trimmed }
        return String(trimmed.suffix(detailTailLimit))
    }
}

/// Which half of the pinned cycle a trigger runs (issue #49): the WRITE
/// triggers (debounced noteVaultWrite, the quit flush, a discharged
/// follow-up with pending work) run the FULL push cycle — pull-FIRST, then
/// add/commit/push. The PULL triggers (launch, the #50 seam, the 15-min
/// tick) stop after the fast-forward: NO add/commit/push (a pull trigger
/// never pushes).
public enum SyncCycleKind: Equatable, Sendable {
    case pull
    case push
}

/// The typed outcome of a pull-once request (issue #49, the #50 seam:
/// "single-flight, outcome recorded"). `.failed` carries the ONE typed
/// error; `.diverged` is the pinned STOP; `.unavailable` the static
/// precondition failure; `.disabled` the shipped-default inert state.
public enum SyncPullOutcome: Equatable, Sendable {
    case disabled
    case unavailable(String)
    case upToDate
    case fastForwarded
    case diverged
    case failed(SyncCycleError)
}
