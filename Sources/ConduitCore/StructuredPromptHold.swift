import Foundation

/// What Conduit does with a prompt that arrives before a structured runtime
/// is ready to take it.
///
/// Conduit already owns asynchronous delivery on a PTY: the prompt is recorded,
/// the write is handed to the controller, and the caller is told `queued`. A
/// structured host had no equivalent. The same call refused the prompt outright
/// with "agent runtime is still starting; retry conduit_send_prompt" and left
/// the caller holding it.
///
/// The cost of that asymmetry landed on the control plane's most basic action.
/// `conduit_create_task(agent:project_slug:objective:)` reported
/// `objective_delivery_state: failed` on every structured backend, because the
/// runtime it had just started was — necessarily — still starting. Observed on
/// Codex in every canary run that recorded the field: the objective was refused
/// at create and the runtime reported ready about three seconds later. An
/// orchestrating agent could not start an agent on an objective in one call;
/// it had to create, poll `conduit_session_status` until ready, then send the
/// objective again as a separate write.
///
/// Holding the prompt is not a convenience. `queued` already carries an exact
/// meaning in `ObjectiveDeliveryReport` — Conduit owns delivery, the caller
/// must not resend, and the real outcome lands on the durable prompt event.
/// This type is what lets a structured host make that promise honestly.
///
/// The honesty constraint runs the other way too: a held prompt must never
/// disappear quietly. Every hold ends in a recorded resolution, including the
/// ones where the runtime never becomes ready at all.
public enum StructuredPromptHold {
    /// What should happen to a prompt right now.
    public enum Disposition: Equatable, Sendable {
        /// The host can take it during this call.
        case sendNow
        /// Conduit takes ownership and delivers when the host reports ready.
        /// The caller is told `queued` and must not resend.
        case hold
        /// There is nothing to deliver.
        case discard
    }

    /// How a held prompt finished. Every hold reaches one of these.
    public enum Resolution: Equatable, Sendable {
        /// The host became ready and accepted it.
        case delivered
        /// The host became ready and refused it.
        case refused(String)
        /// The host never became ready, or went away first. Conduit made a
        /// promise it could not keep, and says so rather than leaving the
        /// prompt pending forever.
        case abandoned(String)

        /// What lands on the durable prompt event.
        public var promptDeliveryState: PromptDeliveryState {
            switch self {
            case .delivered: return .delivered
            case .refused, .abandoned: return .failed
            }
        }

        /// Why, in the caller's terms. `nil` only when nothing went wrong.
        public var reason: String? {
            switch self {
            case .delivered: return nil
            case .refused(let message): return message
            case .abandoned(let message): return message
            }
        }
    }

    /// How long Conduit will hold a prompt waiting for readiness.
    ///
    /// A hold without a deadline is worse than a refusal: the caller is told
    /// Conduit owns delivery and then waits on a promise nothing will ever
    /// resolve. Two minutes is far outside observed structured startup — Codex
    /// reaches ready in roughly three seconds — while still bounding the wait
    /// for a host that is never coming up.
    public static let readinessGrace: TimeInterval = 120

    /// Decide what to do with a prompt for this runtime, right now.
    ///
    /// A PTY is `sendNow` because its controller already queues internally;
    /// routing it through a hold would duplicate a mechanism that works and
    /// re-introduce the double-delivery this vocabulary was built to prevent.
    public static func disposition(
        text: String,
        usesStructuredHost: Bool,
        isReady: Bool
    ) -> Disposition {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .discard
        }
        guard usesStructuredHost else { return .sendNow }
        return isReady ? .sendNow : .hold
    }

    /// Whether a prompt held since `heldAt` has outlived the grace period.
    public static func hasExpired(
        heldAt: Date,
        now: Date,
        grace: TimeInterval = readinessGrace
    ) -> Bool {
        now.timeIntervalSince(heldAt) >= grace
    }

    /// The resolution for a hold that ran out of time.
    public static func expiryResolution(
        agentName: String,
        grace: TimeInterval = readinessGrace
    ) -> Resolution {
        .abandoned(
            "\(agentName) did not become ready within "
                + "\(Int(grace))s; the prompt Conduit was holding was never delivered"
        )
    }

    /// The resolution for a hold whose runtime was torn down first.
    public static func teardownResolution(agentName: String) -> Resolution {
        .abandoned(
            "the \(agentName) runtime stopped before it became ready; "
                + "the prompt Conduit was holding was never delivered"
        )
    }
}
