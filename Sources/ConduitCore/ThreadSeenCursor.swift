import Foundation

/// Explicit UI observation required before a presentation read cursor may advance.
///
/// This receipt is deliberately narrower than selection, hover, task existence,
/// provider state, or output quietness. The caller must identify the exact
/// latest output revision that was actually visible in the Conversation surface.
public struct ThreadSeenObservation: Equatable, Sendable {
    public let taskSessionID: TaskSessionID
    public let surface: SessionSurface
    public let applicationIsActive: Bool
    public let windowIsKey: Bool
    public let windowIsVisible: Bool
    public let visibleLatestRevision: ThreadOutputRevisionIdentity?

    public init(
        taskSessionID: TaskSessionID,
        surface: SessionSurface,
        applicationIsActive: Bool,
        windowIsKey: Bool,
        windowIsVisible: Bool,
        visibleLatestRevision: ThreadOutputRevisionIdentity?
    ) {
        self.taskSessionID = taskSessionID
        self.surface = surface
        self.applicationIsActive = applicationIsActive
        self.windowIsKey = windowIsKey
        self.windowIsVisible = windowIsVisible
        self.visibleLatestRevision = visibleLatestRevision
    }
}

/// Pure decision over an already-projected unseen state and one UI observation.
///
/// This type does not persist a cursor. It only determines whether the caller has
/// enough bounded presentation evidence to advance one.
public enum ThreadSeenCursorDecision: Equatable, Sendable {
    /// No cursor change is authorized.
    case unchanged

    /// The cursor may advance to this exact visible output revision.
    case advance(ThreadOutputRevisionIdentity)

    /// The underlying conversation source could not support an unseen decision.
    case unavailable(ThreadRecognitionUnavailableReason)
}

public enum ThreadSeenCursor {
    public static func decide(
        taskSessionID: TaskSessionID,
        unseenState: ThreadUnseenOutputState,
        observation: ThreadSeenObservation?
    ) -> ThreadSeenCursorDecision {
        switch unseenState {
        case .none:
            return .unchanged
        case .unavailable(let reason):
            return .unavailable(reason)
        case .unseen(let identity):
            guard let observation else { return .unchanged }
            guard observation.taskSessionID == taskSessionID else {
                return .unchanged
            }
            guard observation.surface == .conversation else {
                return .unchanged
            }
            guard observation.applicationIsActive,
                  observation.windowIsKey,
                  observation.windowIsVisible
            else {
                return .unchanged
            }
            guard observation.visibleLatestRevision == identity else {
                return .unchanged
            }
            return .advance(identity)
        }
    }
}
