import XCTest
@testable import ConduitCore

/// Coverage for the policy that decides whether Conduit takes ownership of a
/// prompt a structured host cannot accept yet.
///
/// The defect this replaces was observable from the outside: every canary run
/// that recorded `objective_delivery_state` on Codex reported `failed` at
/// `create_task`, because the runtime Conduit had just started was still
/// starting. The tests that matter here are the ones that pin the case which
/// used to be a refusal.
final class StructuredPromptHoldTests: XCTestCase {

    // MARK: - The defect

    func testAStructuredHostThatIsNotReadyHoldsRatherThanRefusing() {
        XCTAssertEqual(
            StructuredPromptHold.disposition(
                text: "audit the changelog",
                usesStructuredHost: true,
                isReady: false
            ),
            .hold
        )
    }

    func testANotReadyStructuredHostNeverSendsNow() {
        // Sending now is the one answer that cannot be right: the host would
        // throw notReady and the prompt would be lost after Conduit had
        // already recorded it.
        for text in ["objective", "  padded  ", "multi\nline"] {
            XCTAssertNotEqual(
                StructuredPromptHold.disposition(
                    text: text,
                    usesStructuredHost: true,
                    isReady: false
                ),
                .sendNow,
                "text: \(text)"
            )
        }
    }

    // MARK: - The paths that must not change

    func testAReadyStructuredHostSendsImmediately() {
        XCTAssertEqual(
            StructuredPromptHold.disposition(
                text: "go",
                usesStructuredHost: true,
                isReady: true
            ),
            .sendNow
        )
    }

    func testAPTYSendsNowEvenWhenNotReady() {
        // A PTY controller queues internally. Routing it through the hold
        // would give one prompt two owners and deliver it twice — the exact
        // duplication the queued vocabulary was introduced to prevent.
        XCTAssertEqual(
            StructuredPromptHold.disposition(
                text: "go",
                usesStructuredHost: false,
                isReady: false
            ),
            .sendNow
        )
    }

    func testEmptyTextIsDiscardedNotHeld() {
        XCTAssertEqual(
            StructuredPromptHold.disposition(
                text: "",
                usesStructuredHost: true,
                isReady: false
            ),
            .discard
        )
    }

    func testWhitespaceOnlyTextIsDiscardedNotHeld() {
        // Holding whitespace would promise delivery of nothing and then
        // report a delivery that carried no instruction.
        XCTAssertEqual(
            StructuredPromptHold.disposition(
                text: "   \n\t ",
                usesStructuredHost: true,
                isReady: false
            ),
            .discard
        )
    }

    // MARK: - Resolutions

    func testDeliveredResolvesToDeliveredWithNoReason() {
        let resolution = StructuredPromptHold.Resolution.delivered
        XCTAssertEqual(resolution.promptDeliveryState, .delivered)
        XCTAssertNil(resolution.reason)
    }

    func testARefusedHoldIsRecordedAsFailedNotQueued() {
        // Leaving it queued would tell a caller that had been instructed not
        // to resend that delivery was still coming.
        let resolution = StructuredPromptHold.Resolution.refused("host said no")
        XCTAssertEqual(resolution.promptDeliveryState, .failed)
        XCTAssertEqual(resolution.reason, "host said no")
    }

    func testAnAbandonedHoldIsRecordedAsFailed() {
        let resolution = StructuredPromptHold.Resolution.abandoned("went away")
        XCTAssertEqual(resolution.promptDeliveryState, .failed)
        XCTAssertEqual(resolution.reason, "went away")
    }

    func testNoResolutionLeavesAPromptQueued() {
        // Every terminal resolution must move the prompt off `queued`. A hold
        // that ends in `queued` is a promise with no outcome.
        let all: [StructuredPromptHold.Resolution] = [
            .delivered, .refused("x"), .abandoned("y"),
        ]
        for resolution in all {
            XCTAssertNotEqual(resolution.promptDeliveryState, .queued)
        }
    }

    // MARK: - The deadline

    func testAHoldInsideTheGraceHasNotExpired() {
        let held = Date()
        XCTAssertFalse(
            StructuredPromptHold.hasExpired(
                heldAt: held,
                now: held.addingTimeInterval(StructuredPromptHold.readinessGrace - 1)
            )
        )
    }

    func testAHoldAtTheGraceHasExpired() {
        let held = Date()
        XCTAssertTrue(
            StructuredPromptHold.hasExpired(
                heldAt: held,
                now: held.addingTimeInterval(StructuredPromptHold.readinessGrace)
            )
        )
    }

    func testTheGraceIsLongerThanObservedStructuredStartup() {
        // Codex reached ready in roughly three seconds in every recorded
        // canary run. A grace anywhere near that would fail live tasks.
        XCTAssertGreaterThan(StructuredPromptHold.readinessGrace, 30)
    }

    func testTheGraceIsBounded() {
        // An unbounded hold is worse than a refusal: the caller is told not to
        // resend and then waits on a promise nothing resolves.
        XCTAssertLessThanOrEqual(StructuredPromptHold.readinessGrace, 600)
    }

    // MARK: - What the caller is told

    func testExpiryReasonNamesTheAgentAndTheWait() throws {
        let resolution = StructuredPromptHold.expiryResolution(
            agentName: "Codex",
            grace: 120
        )
        let reason = try XCTUnwrap(resolution.reason)
        XCTAssertTrue(reason.contains("Codex"), "got: \(reason)")
        XCTAssertTrue(reason.contains("120s"), "got: \(reason)")
        XCTAssertEqual(resolution.promptDeliveryState, .failed)
    }

    func testTeardownReasonNamesTheAgent() {
        let resolution = StructuredPromptHold.teardownResolution(agentName: "OpenCode")
        XCTAssertTrue(resolution.reason?.contains("OpenCode") == true)
        XCTAssertEqual(resolution.promptDeliveryState, .failed)
    }

    func testEveryFailureReasonSaysTheDeliveryDidNotHappen() {
        // The caller was told Conduit owned delivery. A failure message that
        // does not say the prompt was never delivered leaves them guessing
        // whether the work started.
        let reasons = [
            StructuredPromptHold.expiryResolution(agentName: "Codex").reason,
            StructuredPromptHold.teardownResolution(agentName: "Codex").reason,
        ]
        for reason in reasons {
            XCTAssertTrue(
                reason?.contains("never delivered") == true,
                "got: \(String(describing: reason))"
            )
        }
    }

    // MARK: - Interop with the reported state

    func testAHeldPromptIsReportedAsQueuedAndNotResendRequired() {
        // The hold is only honest if the report that accompanies it tells the
        // caller Conduit owns delivery. `failed` here would send them into the
        // duplicate-delivery path.
        let report = ObjectiveDeliveryReport.from(
            delivered: false,
            delivery: "queued",
            error: nil
        )
        XCTAssertEqual(report.state, .queued)
        XCTAssertFalse(report.resendRequired)
        XCTAssertFalse(report.deliveredAtResponseTime)
    }
}
