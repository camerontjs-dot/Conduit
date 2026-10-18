import Foundation

/// The local presentation owner of a control operation. This is feedback
/// routing only; it grants no task, process, filesystem or client authority.
public enum SessionControlOrigin: Equatable, Sendable {
    case operatorUI
    case sessionAPI
    case unattributed

    public var updatesOperatorPresentation: Bool { self == .operatorUI }
}

/// Remembers the trusted entry point for this runtime's own event IDs, rather
/// than inferring it from the runtime creator or a caller-supplied display
/// label. Delayed delivery and output revisions follow the exact prompt they
/// reference, even when operator and hosted prompts interleave.
///
/// This ledger is intentionally ephemeral. Old or unlinked events have no
/// established presentation owner; their persistence diagnostics still belong
/// to the shared task, but do not raise an unrelated operator modal.
public struct SessionControlFeedbackLedger: Sendable {
    private var origins: [UUID: SessionControlOrigin] = [:]

    public init() {}

    public mutating func record(eventID: UUID, origin: SessionControlOrigin) {
        // An immutable event cannot silently move to another client's sink.
        guard origins[eventID] == nil else { return }
        origins[eventID] = origin
    }

    public func origin(for event: SessionPresentationEvent) -> SessionControlOrigin {
        switch event.kind {
        case .agentOutput(let output):
            guard let promptID = output.promptEventID else { return .unattributed }
            return origins[promptID] ?? .unattributed
        case .sessionOpened, .userPrompt, .interruptRequested:
            return origins[event.id] ?? .unattributed
        }
    }
}
