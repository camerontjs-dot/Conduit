import Foundation

/// Coverage of the caller's already-projected, retained conversation source.
/// Complete means the retained timeline, not every event in a provider's life.
public enum ThreadRecognitionCoverage: Equatable, Sendable {
    case completeRetainedTimeline
    case boundedRetainedWindow
}

public enum ThreadRecognitionUnavailableReason: Equatable, Sendable {
    case sourceNotLoaded
    case sourceMissing
    case sourceUnreadable
    case sourceHasDiagnostics
    case duplicateEventIdentity
    case invalidEventAuthority
    case invalidEventTime
    case invalidPreviewByteLimit
    case notRetainedByInputContract
}

public enum ThreadRecognitionSourceState: Equatable, Sendable {
    case retained(ThreadRecognitionCoverage)
    case unavailable(ThreadRecognitionUnavailableReason)
}

/// Absence from a bounded window must not become absence from all history.
public enum ThreadRecognitionFact<Value: Equatable & Sendable>: Equatable, Sendable {
    case observed(Value)
    case notObserved(ThreadRecognitionCoverage)
    case unavailable(ThreadRecognitionUnavailableReason)
}

/// An exact leading excerpt. No summary, path expansion or normalization occurs.
/// `wasClipped` concerns this preview; `sourceWasTruncated` concerns retained text.
public struct ThreadRecognitionPreview: Equatable, Sendable {
    public let text: String
    public let wasClipped: Bool
    public let sourceWasTruncated: Bool
}

public struct ThreadRecognitionEventOrigin: Equatable, Sendable {
    public let eventID: UUID
    public let occurredAt: Date
    public let authority: SessionEventAuthority
}

public struct ThreadRecognitionPrompt: Equatable, Sendable {
    public let event: ThreadRecognitionEventOrigin
    public let origin: PromptOrigin
    public let delivery: PromptDeliveryState
    public let attachmentCount: Int
    public let preview: ThreadRecognitionPreview
}

public struct ThreadRecognitionOutput: Equatable, Sendable {
    public let event: ThreadRecognitionEventOrigin
    public let promptEventID: UUID?
    public let extraction: AgentOutputExtraction
    public let state: AgentOutputState
    public let preview: ThreadRecognitionPreview
}

/// Recognition metadata over one caller-bound retained task source.
///
/// Prompt origins remain explicit: ChatGPT, phone or forwarded output is not
/// evidence of a human action. Output time is the block's original occurredAt,
/// which retained revisions do not advance. It is not a last-update timestamp.
/// No field expresses provider completion, unseen state, priority or authority
/// to select, reconnect, launch or send. Existing task pinning remains separate.
public struct ThreadRecognitionSnapshot: Equatable, Sendable {
    public let taskSessionID: TaskSessionID
    public let source: ThreadRecognitionSourceState
    public let retainedEventCount: Int
    public let latestPrompt: ThreadRecognitionFact<ThreadRecognitionPrompt>
    public let latestOutputBlock: ThreadRecognitionFact<ThreadRecognitionOutput>
    public let latestConversationEventOrigin: ThreadRecognitionFact<ThreadRecognitionEventOrigin>

    /// The input event contract does not retain the time of the last revision.
    public var lastOutputUpdateAt: ThreadRecognitionFact<Date> {
        if case .unavailable(let reason) = source {
            return .unavailable(reason)
        }
        return .unavailable(.notRetainedByInputContract)
    }
}

public enum ThreadRecognition {
    public static let defaultPreviewByteLimit = 256
    public static let maximumPreviewByteLimit = 4_096

    /// The caller must bind the source to this exact TaskSessionID and supply
    /// coverage explicitly. Use unavailable for a missing/unreadable source or
    /// one with diagnostics. Events must be the unique latest-valid projection
    /// in retained file order, not raw append revisions or a timestamp sort.
    ///
    /// This pure function does not read files, establish source authenticity,
    /// persist read cursors or subscribe the task rail to streaming revisions.
    public static func project(
        taskSessionID: TaskSessionID,
        events: [SessionPresentationEvent],
        source: ThreadRecognitionSourceState,
        previewByteLimit: Int = ThreadRecognition.defaultPreviewByteLimit
    ) -> ThreadRecognitionSnapshot {
        func unavailable(_ reason: ThreadRecognitionUnavailableReason) -> ThreadRecognitionSnapshot {
            ThreadRecognitionSnapshot(
                taskSessionID: taskSessionID,
                source: .unavailable(reason),
                retainedEventCount: 0,
                latestPrompt: .unavailable(reason),
                latestOutputBlock: .unavailable(reason),
                latestConversationEventOrigin: .unavailable(reason)
            )
        }

        let coverage: ThreadRecognitionCoverage
        switch source {
        case .retained(let value): coverage = value
        case .unavailable(let reason): return unavailable(reason)
        }
        guard (0...maximumPreviewByteLimit).contains(previewByteLimit) else {
            return unavailable(.invalidPreviewByteLimit)
        }

        var seen = Set<UUID>()
        for event in events {
            guard seen.insert(event.id).inserted else {
                return unavailable(.duplicateEventIdentity)
            }
            guard event.occurredAt.timeIntervalSince1970.isFinite else {
                return unavailable(.invalidEventTime)
            }
            switch event.kind {
            case .sessionOpened, .userPrompt, .interruptRequested:
                guard event.authority == .conduitRecorded else {
                    return unavailable(.invalidEventAuthority)
                }
            case .agentOutput(let output):
                let expected: SessionEventAuthority = output.extraction == .structuredAdapter
                    ? .toolReported : .derivedFromRaw
                guard event.authority == expected else {
                    return unavailable(.invalidEventAuthority)
                }
            }
        }

        var prompt: ThreadRecognitionFact<ThreadRecognitionPrompt> = .notObserved(coverage)
        var output: ThreadRecognitionFact<ThreadRecognitionOutput> = .notObserved(coverage)
        var conversation: ThreadRecognitionFact<ThreadRecognitionEventOrigin> = .notObserved(coverage)
        for event in events {
            let origin = ThreadRecognitionEventOrigin(
                eventID: event.id, occurredAt: event.occurredAt, authority: event.authority
            )
            switch event.kind {
            case .userPrompt(let submitted):
                prompt = .observed(ThreadRecognitionPrompt(
                    event: origin,
                    origin: submitted.origin,
                    delivery: submitted.delivery,
                    attachmentCount: submitted.attachmentPaths.count,
                    preview: preview(submitted.text, byteLimit: previewByteLimit, sourceTruncated: false)
                ))
                conversation = .observed(origin)
            case .agentOutput(let visible):
                output = .observed(ThreadRecognitionOutput(
                    event: origin,
                    promptEventID: visible.promptEventID,
                    extraction: visible.extraction,
                    state: visible.state,
                    preview: preview(visible.text, byteLimit: previewByteLimit, sourceTruncated: visible.truncated)
                ))
                conversation = .observed(origin)
            case .sessionOpened, .interruptRequested:
                break
            }
        }
        return ThreadRecognitionSnapshot(
            taskSessionID: taskSessionID,
            source: source,
            retainedEventCount: events.count,
            latestPrompt: prompt,
            latestOutputBlock: output,
            latestConversationEventOrigin: conversation
        )
    }

    private static func preview(
        _ source: String,
        byteLimit: Int,
        sourceTruncated: Bool
    ) -> ThreadRecognitionPreview {
        var text = ""
        var usedBytes = 0
        var wasClipped = false
        for character in source {
            let count = String(character).utf8.count
            guard count <= byteLimit - usedBytes else {
                wasClipped = true
                break
            }
            text.append(character)
            usedBytes += count
        }
        return ThreadRecognitionPreview(
            text: text, wasClipped: wasClipped, sourceWasTruncated: sourceTruncated
        )
    }
}
