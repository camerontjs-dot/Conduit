import Foundation

/// How `create_task` reports the fate of an initial objective (D-041, contract §7).
///
/// The distinction this type exists to preserve is the one an external
/// orchestrator gets wrong most expensively: **"not delivered yet" is not the
/// same as "you must send it yourself."**
///
/// A structured host that is still starting refuses the objective outright, so
/// the caller genuinely owns the retry. A PTY host accepts it and writes to the
/// terminal asynchronously — the write completes after the create response has
/// already been serialized. Both cases previously reported only
/// `objective_delivered: false`, so a caller following the documented recovery
/// ("if objective_delivered is false, send it explicitly") re-sent an objective
/// the PTY had already accepted and executed it twice.
///
/// Contract §7 Candidate A requires that a duplicate must not duplicate
/// objective delivery. Reporting the queued state is what makes that
/// achievable from the caller's side.
public struct ObjectiveDeliveryReport: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        /// The runtime accepted the objective before the response was returned.
        case delivered
        /// Conduit owns delivery and will complete it without another call.
        /// The caller must NOT resend; the outcome lands on the durable prompt
        /// event and is readable through `conduit_session_events`.
        case queued
        /// Nothing was accepted. The caller owns the retry.
        case failed
        /// No objective was supplied.
        case notAttempted = "not_attempted"
    }

    public var state: State
    public var error: String?

    public init(state: State, error: String? = nil) {
        self.state = state
        self.error = error
    }

    /// True only when the caller is the one that must act.
    ///
    /// `queued` is deliberately false here. That is the whole point of the
    /// type: a queued objective is Conduit's responsibility, and resending it
    /// duplicates work that is already on its way to the runtime.
    public var resendRequired: Bool { state == .failed }

    /// Back-compatible boolean for the existing `objective_delivered` field.
    ///
    /// A queued objective has not been delivered at response time, so this
    /// stays false and no existing consumer changes meaning. The new state
    /// field is what carries the missing distinction.
    public var deliveredAtResponseTime: Bool { state == .delivered }

    /// Interpret the result of a delivery attempt.
    ///
    /// `delivery` is the asynchronous marker the PTY and slash-command paths
    /// already return; `delivered` is the synchronous result a structured host
    /// can answer immediately. An explicit error always means the caller owns
    /// the retry, whatever else is present.
    public static func from(
        delivered: Bool,
        delivery: String?,
        error: String?
    ) -> ObjectiveDeliveryReport {
        if let error, !error.isEmpty {
            return ObjectiveDeliveryReport(state: .failed, error: error)
        }
        if delivered {
            return ObjectiveDeliveryReport(state: .delivered)
        }
        if delivery == State.queued.rawValue {
            return ObjectiveDeliveryReport(state: .queued)
        }
        return ObjectiveDeliveryReport(state: .failed)
    }

    /// Guidance the caller can act on without inferring policy from a boolean.
    public var callerGuidance: String {
        switch state {
        case .delivered:
            return "Objective reached the runtime. Do not resend."
        case .queued:
            return "Conduit owns delivery of this objective and will complete "
                + "it without another call. Do not resend; poll "
                + "conduit_session_events for the recorded delivery state."
        case .failed:
            return "Objective was not accepted. Wait for conduit_session_status "
                + "to report ready, then send it with conduit_send_prompt."
        case .notAttempted:
            return "No objective was supplied."
        }
    }

    /// Merge into a `create_task` response payload.
    public func apply(to payload: inout [String: Any]) {
        guard state != .notAttempted else { return }
        payload["objective_delivered"] = deliveredAtResponseTime
        payload["objective_delivery_state"] = state.rawValue
        payload["objective_resend_required"] = resendRequired
        payload["objective_authority"] = callerGuidance
        if let error {
            payload["objective_error"] = error
        }
    }
}
