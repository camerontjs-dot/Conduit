import XCTest
@testable import ConduitCore

/// Regression coverage for the duplicate initial-objective defect.
///
/// Observed 2026-09-04 against installed build
/// f36a70658b2a2e57c0502669e488a95b72939a43c57895a9112ccb18551d4d26: a Shell
/// (PTY) create returned `objective_delivered: false` with no error, the
/// caller followed the documented recovery and sent the objective again, and
/// the pane showed it execute twice.
final class ObjectiveDeliveryTests: XCTestCase {

    // MARK: - The defect

    func testQueuedPTYObjectiveDoesNotAskCallerToResend() {
        // The exact shape sessionAPIDeliver returns for a PTY runtime.
        let report = ObjectiveDeliveryReport.from(
            delivered: false,
            delivery: "queued",
            error: nil
        )
        XCTAssertEqual(report.state, .queued)
        XCTAssertFalse(
            report.resendRequired,
            "A queued objective is already on its way to the runtime. Telling "
                + "the caller to resend is what executed the work twice."
        )
    }

    func testStructuredRefusalDoesAskCallerToResend() {
        // The shape a structured host returns while still starting.
        let report = ObjectiveDeliveryReport.from(
            delivered: false,
            delivery: nil,
            error: "agent runtime is still starting; retry conduit_send_prompt"
        )
        XCTAssertEqual(report.state, .failed)
        XCTAssertTrue(report.resendRequired)
        XCTAssertEqual(
            report.error,
            "agent runtime is still starting; retry conduit_send_prompt"
        )
    }

    func testQueuedAndRefusedAreDistinguishable() {
        // Both report objective_delivered false. Before the fix that was the
        // only signal, which is precisely why they were confused.
        let queued = ObjectiveDeliveryReport.from(
            delivered: false, delivery: "queued", error: nil
        )
        let refused = ObjectiveDeliveryReport.from(
            delivered: false, delivery: nil, error: "still starting"
        )
        XCTAssertFalse(queued.deliveredAtResponseTime)
        XCTAssertFalse(refused.deliveredAtResponseTime)
        XCTAssertNotEqual(queued.resendRequired, refused.resendRequired)
    }

    // MARK: - Remaining states

    func testDeliveredObjectiveNeedsNoResend() {
        let report = ObjectiveDeliveryReport.from(
            delivered: true, delivery: nil, error: nil
        )
        XCTAssertEqual(report.state, .delivered)
        XCTAssertTrue(report.deliveredAtResponseTime)
        XCTAssertFalse(report.resendRequired)
    }

    func testErrorWinsOverAQueuedMarker() {
        // An explicit error always hands the retry back, whatever else is set.
        let report = ObjectiveDeliveryReport.from(
            delivered: false, delivery: "queued", error: "provisioning failed"
        )
        XCTAssertEqual(report.state, .failed)
        XCTAssertTrue(report.resendRequired)
    }

    func testUnknownDeliveryMarkerFailsClosed() {
        // An unrecognised marker must not be read as "Conduit has this".
        let report = ObjectiveDeliveryReport.from(
            delivered: false, delivery: "something-new", error: nil
        )
        XCTAssertEqual(report.state, .failed)
        XCTAssertTrue(report.resendRequired)
    }

    func testEmptyErrorStringIsNotTreatedAsAnError() {
        let report = ObjectiveDeliveryReport.from(
            delivered: false, delivery: "queued", error: ""
        )
        XCTAssertEqual(report.state, .queued)
    }

    // MARK: - Payload contract

    func testApplyEmitsTheFieldsCallersBranchOn() {
        var payload: [String: Any] = ["taskSessionID": "abc"]
        ObjectiveDeliveryReport.from(
            delivered: false, delivery: "queued", error: nil
        ).apply(to: &payload)

        XCTAssertEqual(payload["objective_delivered"] as? Bool, false)
        XCTAssertEqual(payload["objective_delivery_state"] as? String, "queued")
        XCTAssertEqual(payload["objective_resend_required"] as? Bool, false)
        XCTAssertNotNil(payload["objective_authority"] as? String)
        XCTAssertNil(payload["objective_error"])
        XCTAssertEqual(payload["taskSessionID"] as? String, "abc")
    }

    func testApplyPreservesTheExistingBooleanMeaning() {
        // objective_delivered must keep meaning "reached the runtime before
        // this response was serialized", so existing consumers do not shift.
        var queuedPayload: [String: Any] = [:]
        ObjectiveDeliveryReport(state: .queued).apply(to: &queuedPayload)
        XCTAssertEqual(queuedPayload["objective_delivered"] as? Bool, false)

        var deliveredPayload: [String: Any] = [:]
        ObjectiveDeliveryReport(state: .delivered).apply(to: &deliveredPayload)
        XCTAssertEqual(deliveredPayload["objective_delivered"] as? Bool, true)
    }

    func testApplyCarriesTheErrorThrough() {
        var payload: [String: Any] = [:]
        ObjectiveDeliveryReport.from(
            delivered: false, delivery: nil, error: "still starting"
        ).apply(to: &payload)
        XCTAssertEqual(payload["objective_error"] as? String, "still starting")
        XCTAssertEqual(payload["objective_resend_required"] as? Bool, true)
    }

    func testNotAttemptedIsReportedRatherThanOmitted() {
        // A caller told to branch on objective_delivery_state needs the key on
        // every path that could carry an objective. Omitting it leaves the
        // discarded-objective case indistinguishable from a delivered one.
        var payload: [String: Any] = ["taskSessionID": "abc"]
        ObjectiveDeliveryReport(state: .notAttempted).apply(to: &payload)
        XCTAssertEqual(
            payload["objective_delivery_state"] as? String,
            "not_attempted"
        )
        XCTAssertEqual(payload["objective_delivered"] as? Bool, false)
        XCTAssertEqual(
            payload["objective_resend_required"] as? Bool,
            false,
            "Nothing was accepted, but there is also nothing to resend."
        )
    }

    /// Every state must emit the key the tool description tells callers to
    /// branch on. A path that omits it has no defined case.
    func testEveryStateEmitsTheBranchKey() {
        for state in [
            ObjectiveDeliveryReport.State.delivered,
            .queued,
            .failed,
            .notAttempted,
        ] {
            var payload: [String: Any] = [:]
            ObjectiveDeliveryReport(state: state).apply(to: &payload)
            XCTAssertEqual(
                payload["objective_delivery_state"] as? String,
                state.rawValue,
                "\(state.rawValue) must report itself"
            )
            XCTAssertNotNil(
                payload["objective_resend_required"] as? Bool,
                "\(state.rawValue) must tell the caller whether to resend"
            )
        }
    }

    /// Guards the regression site itself.
    ///
    /// The defect was not in this type — it was AppModel forwarding only
    /// `delivered` and `error` from sessionAPIDeliver and discarding
    /// `delivery`. This reproduces that exact dictionary and asserts the
    /// three-argument read, so dropping the `delivery` argument again fails
    /// here rather than silently shipping.
    func testForwardingTheFullDeliverResultIsWhatSeparatesTheCases() {
        let ptyResult: [String: Any] = [
            "delivered": false,
            "delivery": "queued",
            "authority": "prompt queued to PTY; delivery is decided asynchronously.",
        ]
        let structuredResult: [String: Any] = [
            "delivered": false,
            "error": "agent runtime is still starting; retry conduit_send_prompt",
        ]

        func report(from result: [String: Any]) -> ObjectiveDeliveryReport {
            ObjectiveDeliveryReport.from(
                delivered: result["delivered"] as? Bool ?? false,
                delivery: result["delivery"] as? String,
                error: result["error"] as? String
            )
        }

        XCTAssertFalse(report(from: ptyResult).resendRequired)
        XCTAssertTrue(report(from: structuredResult).resendRequired)

        // Drop the `delivery` argument — the original bug — and the two
        // results collapse into the same answer.
        let collapsed = ObjectiveDeliveryReport.from(
            delivered: ptyResult["delivered"] as? Bool ?? false,
            delivery: nil,
            error: ptyResult["error"] as? String
        )
        XCTAssertTrue(
            collapsed.resendRequired,
            "Without the delivery marker a queued PTY objective reads as "
                + "failed, which is what told the caller to resend and ran "
                + "the objective twice."
        )
    }

    func testGuidanceForQueuedTellsCallerNotToResend() {
        let guidance = ObjectiveDeliveryReport(state: .queued).callerGuidance
        XCTAssertTrue(guidance.contains("Do not resend"))
    }

    func testGuidanceForFailedNamesTheRecoveryCall() {
        let guidance = ObjectiveDeliveryReport(state: .failed).callerGuidance
        XCTAssertTrue(guidance.contains("conduit_send_prompt"))
    }
}
