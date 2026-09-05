import XCTest
@testable import ConduitCore

/// Coverage for the asymmetry `conduit_close_session` hides.
///
/// Observed on 2026-09-04 and again on 2026-09-05: closing a Codex task
/// returned `closed: true` with the same authority line a tmux close returns,
/// and the task then reported `recoverable: false` with no way back. The
/// canary's L4.3 lane could not even attempt reconnection.
final class SessionCloseSemanticsTests: XCTestCase {

    func testAStructuredHostIsStoppedNotDetached() {
        XCTAssertEqual(
            SessionCloseSemantics.outcome(usesStructuredHost: true),
            .stopped
        )
    }

    func testAPTYIsDetached() {
        XCTAssertEqual(
            SessionCloseSemantics.outcome(usesStructuredHost: false),
            .detached
        )
    }

    func testOnlyTheStructuredCloseIsTerminal() {
        XCTAssertTrue(SessionCloseSemantics.Outcome.stopped.isTerminal)
        XCTAssertFalse(SessionCloseSemantics.Outcome.detached.isTerminal)
    }

    func testTheTwoOutcomesDoNotShareAnAuthorityLine() {
        // Reporting both as "leave requested; not verification" is what made
        // an irreversible close indistinguishable from a reversible one.
        XCTAssertNotEqual(
            SessionCloseSemantics.authority(for: .stopped),
            SessionCloseSemantics.authority(for: .detached)
        )
    }

    func testTheTerminalCloseSaysItIsNotRecoverable() throws {
        let authority = SessionCloseSemantics.authority(for: .stopped)
        XCTAssertTrue(
            authority.lowercased().contains("not recoverable"),
            "got: \(authority)"
        )
        XCTAssertTrue(
            authority.contains("STOPPED"),
            "the irreversible case should not read like the reversible one: \(authority)"
        )
    }

    func testTheDetachedCloseNamesTheWayBack() throws {
        let authority = SessionCloseSemantics.authority(for: .detached)
        XCTAssertTrue(
            authority.contains("conduit_reconcile_task"),
            "got: \(authority)"
        )
    }

    func testNeitherOutcomeClaimsVerification() {
        // Closing observes nothing about what the agent did.
        for outcome in [SessionCloseSemantics.Outcome.stopped, .detached] {
            XCTAssertTrue(
                SessionCloseSemantics.authority(for: outcome)
                    .contains("Not verification"),
                "outcome: \(outcome.rawValue)"
            )
        }
    }

    func testRawValuesAreStableForCallersBranchingOnThem() {
        // These strings are the caller-facing contract for close_outcome.
        XCTAssertEqual(SessionCloseSemantics.Outcome.stopped.rawValue, "stopped")
        XCTAssertEqual(SessionCloseSemantics.Outcome.detached.rawValue, "detached")
    }
}
