import XCTest
@testable import FocusTracker

/// Tests for the #42 break-view control labels (the hoisted constants):
/// the running-break label stays "End break early"; the post-expiry label
/// reads "Start next session" — matching where the control has routed
/// since #34 (the `.sessionStart` session-start sheet) and replacing the
/// stale "Back to tasks". Pure constant assertions; the routing itself is
/// pinned by `AppModelBreakTests` / `AppModelSessionStartRoutingTests`.
final class BreakViewTests: XCTestCase {

    func testRunningBreakLabelStaysEndBreakEarly() {
        XCTAssertEqual(
            BreakView.endEarlyLabel, "End break early",
            "the running-break control keeps its #23 wording")
    }

    func testPostExpiryLabelReadsStartNextSession() {
        XCTAssertEqual(
            BreakView.postExpiryLabel, "Start next session",
            "the post-expiry control describes the #34 `.sessionStart` routing, not the stale \"Back to tasks\"")
    }

    func testLabelsAreDistinctAndNonEmpty() {
        XCTAssertFalse(BreakView.endEarlyLabel.isEmpty)
        XCTAssertFalse(BreakView.postExpiryLabel.isEmpty)
        XCTAssertNotEqual(
            BreakView.endEarlyLabel, BreakView.postExpiryLabel,
            "the control swaps its label at expiry")
    }
}
