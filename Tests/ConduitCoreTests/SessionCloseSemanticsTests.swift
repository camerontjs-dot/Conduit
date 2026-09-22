import XCTest
@testable import ConduitCore

/// Compatibility coverage for the overloaded legacy close verb.
///
/// Explicit lifecycle callers should use LifecyclePreflight instead. These tests
/// keep the old surface honest about the narrower fact it still exposes.
final class SessionCloseSemanticsTests: XCTestCase {
    func testStructuredHostCloseStopsLiveConduitRuntime() {
        XCTAssertEqual(
            SessionCloseSemantics.outcome(
                usesStructuredHost: true,
                usesTmux: false
            ),
            .stopped
        )
    }

    func testDirectPTYCloseStopsInsteadOfPretendingToDetach() {
        XCTAssertEqual(
            SessionCloseSemantics.outcome(
                usesStructuredHost: false,
                usesTmux: false
            ),
            .stopped
        )
    }

    func testTmuxCloseIsTheOnlyDetachedCase() {
        XCTAssertEqual(
            SessionCloseSemantics.outcome(
                usesStructuredHost: false,
                usesTmux: true
            ),
            .detached
        )
        XCTAssertFalse(SessionCloseSemantics.Outcome.detached.isTerminal)
        XCTAssertTrue(SessionCloseSemantics.Outcome.stopped.isTerminal)
    }

    func testTheTwoOutcomesDoNotShareAnAuthorityLine() {
        XCTAssertNotEqual(
            SessionCloseSemantics.authority(for: .stopped),
            SessionCloseSemantics.authority(for: .detached)
        )
    }

    func testStoppedCloseDoesNotClaimProviderHistoryDeletion() {
        let authority = SessionCloseSemantics.authority(for: .stopped)
        XCTAssertTrue(authority.contains("Provider-owned session history"))
        XCTAssertTrue(authority.contains("not deleted"))
        XCTAssertTrue(authority.contains("may remain resumable"))
        XCTAssertFalse(authority.lowercased().contains("history is deleted"))
    }

    func testDetachedCloseNamesTheWayBack() {
        let authority = SessionCloseSemantics.authority(for: .detached)
        XCTAssertTrue(authority.contains("conduit_reconcile_task"))
        XCTAssertTrue(authority.contains("keeps running"))
    }

    func testNeitherOutcomeClaimsObjectiveCompletion() {
        for outcome in [SessionCloseSemantics.Outcome.stopped, .detached] {
            XCTAssertTrue(
                SessionCloseSemantics.authority(for: outcome)
                    .contains("objective completion is not established"),
                "outcome: \(outcome.rawValue)"
            )
        }
    }

    func testRawValuesRemainStableForCompatibilityCallers() {
        XCTAssertEqual(SessionCloseSemantics.Outcome.stopped.rawValue, "stopped")
        XCTAssertEqual(SessionCloseSemantics.Outcome.detached.rawValue, "detached")
    }
}
