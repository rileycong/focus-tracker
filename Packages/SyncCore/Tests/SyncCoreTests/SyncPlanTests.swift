import XCTest
@testable import SyncCore

/// The ONE pure decision function's矩阵 (issue #49, the [Push] criterion):
/// the decision depends only on each count's zero-vs-positive class, so the
/// (unborn × remoteBranchExists × ahead==0/>0 × behind==0/>0) enumeration —
/// 16 classes — IS the whole input space. Exhausted here.
final class SyncPlanTests: XCTestCase {

    private func decide(
        _ unborn: Bool, _ remote: Bool, _ ahead: Int, _ behind: Int
    ) -> SyncPlanAction {
        SyncPlan.decide(SyncGraphState(
            headUnborn: unborn, remoteBranchExists: remote,
            ahead: ahead, behind: behind))
    }

    func testUnbornHeadWithoutRemoteBranchAlwaysProceeds() {
        // The pinned unborn-legal case: the first commit + `push -u` creates
        // the branch — counts are 0 by construction here.
        XCTAssertEqual(decide(true, false, 0, 0), .proceed)
    }

    func testUnbornHeadWithRemoteBranch() {
        // A populated remote facing an unborn HEAD: a fast-forward cannot
        // target nothing — histories need a manual resolve. behind == 0
        // (an empty remote branch — unreachable in practice) proceeds.
        XCTAssertEqual(decide(true, true, 0, 0), .proceed)
        XCTAssertEqual(decide(true, true, 0, 1), .divergenceStop)
    }

    func testNoRemoteBranchWithBornHeadAlwaysProceeds() {
        // Local-only history: nothing to fetch; the push (-u) creates the
        // remote branch.
        XCTAssertEqual(decide(false, false, 0, 0), .proceed)
        XCTAssertEqual(decide(false, false, 1, 0), .proceed)
    }

    func testBornHeadWithRemoteBranchExhaustedMatrix() {
        XCTAssertEqual(decide(false, true, 0, 0), .proceed)
        XCTAssertEqual(decide(false, true, 0, 1), .fastForward)
        XCTAssertEqual(decide(false, true, 1, 0), .proceed)
        XCTAssertEqual(decide(false, true, 1, 1), .divergenceStop)
    }

    func testPositiveCountsBehaveAsTheirClass() {
        // Sanity: the decision keys off zero-vs-positive, not the value.
        XCTAssertEqual(decide(false, true, 5, 0), .proceed)
        XCTAssertEqual(decide(false, true, 0, 7), .fastForward)
        XCTAssertEqual(decide(false, true, 3, 9), .divergenceStop)
        XCTAssertEqual(decide(true, true, 0, 4), .divergenceStop)
    }

    func testDivergenceErrorCarriesCountsAndThePinnedSentence() {
        let error = SyncCycleError.diverged(ahead: 2, behind: 3)
        XCTAssertEqual(error.step, .diverged)
        XCTAssertEqual(
            error.detail,
            "The vault and the origin have diverged (ahead 2, behind 3) "
                + "— resolve the histories manually (no auto-merge).")
        XCTAssertEqual(
            error.displayReason,
            "The vault and the origin have diverged (ahead 2, behind 3) "
                + "— resolve the histories manually (no auto-merge).")
    }

    func testStepFailureDisplayReasonCarriesStepAndTail() {
        let error = SyncCycleError(step: .push, detail: "failed to push some refs")
        XCTAssertEqual(error.displayReason, "push failed: failed to push some refs")
    }

    func testDetailTailPrefersStderrAndBoundsLength() {
        let stderr = SyncCycleError.detailTail(
            from: GitOutcome(exitStatus: 1, stdout: "ignored", stderr: "  boom \n"))
        XCTAssertEqual(stderr, "boom")

        let long = String(repeating: "x", count: 500)
        let bounded = SyncCycleError.detailTail(
            from: GitOutcome(exitStatus: 1, stdout: long, stderr: ""))
        XCTAssertEqual(bounded.count, SyncCycleError.detailTailLimit)
    }
}
