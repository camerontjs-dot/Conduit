import Foundation

/// What `conduit_close_session` actually costs, which is not the same on every
/// backend.
///
/// A durable tmux runtime is *detached*: the work keeps running, and
/// `conduit_reconcile_task` can adopt it again. A structured adapter is
/// *stopped*: the host process ends and the task reports `recoverable: false`
/// from then on. Both were reported to the caller as `closed: true` with the
/// same authority line, so a remote orchestrator could not tell an
/// interruption it could undo from one it could not.
///
/// This matters most before the call, not after. An orchestrator deciding
/// whether to free a slot needs to know that on a structured backend the
/// decision is final, while it still has the option not to make it.
public enum SessionCloseSemantics {
    public enum Outcome: String, Equatable, Sendable {
        /// The runtime is left running and can be adopted again.
        case detached
        /// The host is stopped and the task cannot be reconnected.
        case stopped

        /// Whether closing ends the task for good.
        public var isTerminal: Bool { self == .stopped }
    }

    public static func outcome(usesStructuredHost: Bool) -> Outcome {
        usesStructuredHost ? .stopped : .detached
    }

    /// What the caller is told, in terms it can branch on.
    public static func authority(for outcome: Outcome) -> String {
        switch outcome {
        case .detached:
            return "leave requested; the runtime was detached and keeps "
                + "running. conduit_reconcile_task can adopt it again. "
                + "Not verification."
        case .stopped:
            return "leave requested; the structured host was STOPPED and this "
                + "task is not recoverable. conduit_reconcile_task cannot "
                + "reconnect it and history is preserved read-only. "
                + "Not verification."
        }
    }
}
