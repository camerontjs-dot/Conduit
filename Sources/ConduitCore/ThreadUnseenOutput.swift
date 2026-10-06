import CryptoKit
import Foundation

/// Stable identity for the latest visible agent-output revision used by local
/// presentation cursors.
///
/// The provider/output event ID alone is insufficient because one retained
/// output block can receive many text revisions under the same event ID.
/// Conversely, capture-state changes such as live → settled/closed do not make
/// already-seen text unread again. This identity therefore binds visible text
/// and source-shaping facts, but deliberately excludes AgentOutputState.
public struct ThreadOutputRevisionIdentity: Codable, Equatable, Sendable {
    public let eventID: UUID
    public let promptEventID: UUID?
    public let extraction: AgentOutputExtraction
    public let sourceWasTruncated: Bool
    public let visibleUTF8ByteCount: Int
    public let visibleTextSHA256: String

    public init(
        eventID: UUID,
        promptEventID: UUID?,
        extraction: AgentOutputExtraction,
        sourceWasTruncated: Bool,
        visibleUTF8ByteCount: Int,
        visibleTextSHA256: String
    ) {
        self.eventID = eventID
        self.promptEventID = promptEventID
        self.extraction = extraction
        self.sourceWasTruncated = sourceWasTruncated
        self.visibleUTF8ByteCount = visibleUTF8ByteCount
        self.visibleTextSHA256 = visibleTextSHA256
    }
}

public enum ThreadUnseenOutputState: Equatable, Sendable {
    /// No retained output exists, or the latest visible revision matches the
    /// caller's presentation cursor.
    case none

    /// The latest visible output revision differs from the caller's cursor.
    /// This is presentation state only. It says nothing about provider turn
    /// completion, task acceptance, or whether the operator owes a response.
    case unseen(ThreadOutputRevisionIdentity)

    /// Source validity/coverage could not support an unseen decision.
    case unavailable(ThreadRecognitionUnavailableReason)
}

public enum ThreadUnseenOutput {
    /// Projects binary unseen state from one already-bound conversation source.
    ///
    /// This function does not persist or advance a read cursor. It also does not
    /// count unread turns. A later presentation layer may store the returned
    /// revision identity only after it has evidence that the operator actually
    /// viewed the relevant Conversation surface.
    public static func project(
        taskSessionID: TaskSessionID,
        events: [SessionPresentationEvent],
        source: ThreadRecognitionSourceState,
        lastSeenRevision: ThreadOutputRevisionIdentity?
    ) -> ThreadUnseenOutputState {
        let recognition = ThreadRecognition.project(
            taskSessionID: taskSessionID,
            events: events,
            source: source,
            previewByteLimit: 0
        )

        switch recognition.latestOutputBlock {
        case .unavailable(let reason):
            return .unavailable(reason)
        case .notObserved:
            return .none
        case .observed:
            break
        }

        guard let latest = events.last(where: {
            if case .agentOutput = $0.kind { return true }
            return false
        }),
        case .agentOutput(let output) = latest.kind
        else {
            return .none
        }

        let identity = revisionIdentity(event: latest, output: output)
        return lastSeenRevision == identity ? .none : .unseen(identity)
    }

    public static func revisionIdentity(
        event: SessionPresentationEvent,
        output: AgentVisibleOutput
    ) -> ThreadOutputRevisionIdentity {
        let bytes = Data(output.text.utf8)
        let digest = SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }
            .joined()
        return ThreadOutputRevisionIdentity(
            eventID: event.id,
            promptEventID: output.promptEventID,
            extraction: output.extraction,
            sourceWasTruncated: output.truncated,
            visibleUTF8ByteCount: bytes.count,
            visibleTextSHA256: digest
        )
    }
}
