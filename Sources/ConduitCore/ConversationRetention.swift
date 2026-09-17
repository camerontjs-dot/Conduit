import Foundation

/// The state Conduit can publish after one conversation-log append completes.
///
/// A live output revision is durable even while the provider may produce a
/// newer revision immediately afterwards. Keeping the visible state pending at
/// that boundary avoids turning every successful append into an application-
/// wide publication without weakening the append-only log.
public enum ConversationRetentionState: Equatable, Sendable {
    case legacyPreRetention
    case loading
    case pending
    case persisted
    case missingExpected
    case failed(String)
}

public enum ConversationRetentionPolicy {
    /// Returns the user-visible retention state for one append result.
    ///
    /// The append itself is never skipped. Live structured output remains
    /// `.pending` until a later non-live boundary is retained.
    public static func stateAfterAppend(
        _ event: SessionPresentationEvent,
        errorDescription: String? = nil
    ) -> ConversationRetentionState {
        if let errorDescription {
            return .failed(errorDescription)
        }
        if case .agentOutput(let output) = event.kind,
           output.state == .live {
            return .pending
        }
        return .persisted
    }
}
