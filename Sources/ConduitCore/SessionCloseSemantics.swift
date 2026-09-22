import Foundation

/// Compatibility semantics for the legacy `conduit_close_session` verb.
///
/// New callers should use LifecyclePreflight plus explicit lifecycle operations.
/// This type remains only so the old command can report what it actually did.
///
/// `stopped` means the live Conduit runtime/adapter is ended. It does not mean
/// provider-owned session history was deleted, nor does it imply that an exact
/// provider resume handle is absent. `detached` is reserved for durable tmux.
public enum SessionCloseSemantics {
    public enum Outcome: String, Equatable, Sendable {
        /// The durable tmux runtime is left running and can be adopted again.
        case detached
        /// The live Conduit runtime/adapter is terminated.
        case stopped

        /// Whether this Conduit runtime remains reconnectable as the same live
        /// runtime. Provider history may still be separately resumable.
        public var isTerminal: Bool { self == .stopped }
    }

    public static func outcome(
        usesStructuredHost: Bool,
        usesTmux: Bool
    ) -> Outcome {
        if usesTmux { return .detached }
        // Structured adapters and direct PTYs both end their live Conduit
        // runtime on close. Their provider-history consequences differ and are
        // intentionally not encoded in this legacy two-state result.
        return .stopped
    }

    /// What the compatibility caller is told, without upgrading runtime closure
    /// into a provider-history claim.
    public static func authority(for outcome: Outcome) -> String {
        switch outcome {
        case .detached:
            return "legacy close requested; the tmux runtime was detached and "
                + "keeps running. conduit_reconcile_task can adopt it again. "
                + "Provider/objective completion is not established."
        case .stopped:
            return "legacy close requested; the live Conduit runtime/adapter "
                + "was stopped. Provider-owned session history is not deleted "
                + "by this command and may remain resumable through an exact "
                + "provider handle. Provider/objective completion is not established."
        }
    }
}
