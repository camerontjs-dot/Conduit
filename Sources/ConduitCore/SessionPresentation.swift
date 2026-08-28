import Foundation

/// The two primary views over one live CLI session.
///
/// Conversation is the product default. Raw is the unchanged PTY-backed
/// terminal and remains the live authority for everything still represented
/// in the agent's terminal UI.
public enum SessionSurface: String, CaseIterable, Codable, Sendable {
    case conversation
    case raw

    public static let productDefault: SessionSurface = .conversation

    public var displayName: String {
        switch self {
        case .conversation: return "Conversation"
        case .raw: return "Raw"
        }
    }
}

/// Where a presentation event came from. Native actions, rendered-Raw
/// projections, future adapter events, and verified evidence remain visibly
/// distinct rather than inheriting authority from their prose.
public enum SessionEventAuthority: String, Codable, Equatable, Sendable {
    case conduitRecorded
    case processObserved
    case toolReported
    case derivedFromRaw
    case operatorAsserted
    case verified

    public var displayName: String {
        switch self {
        case .conduitRecorded: return "Conduit recorded"
        case .processObserved: return "Process observed"
        case .toolReported: return "Tool reported"
        case .derivedFromRaw: return "Derived from Raw"
        case .operatorAsserted: return "Operator asserted"
        case .verified: return "Verified"
        }
    }
}

/// How the currently-visible session was entered.
public enum SessionEntry: Codable, Equatable, Sendable {
    case started(agentName: String, requestedBackend: String)
    case resumed(
        agentName: String,
        tmuxSessionName: String,
        attachedElsewhere: Bool
    )
}

/// Delivery state for a prompt Conduit itself accepted from the native
/// composer. Queued is intentionally distinct from delivered.
public enum PromptDeliveryState: String, Codable, Equatable, Sendable {
    case queued
    case delivered
    case failed

    public var displayName: String {
        switch self {
        case .queued: return "Queued"
        case .delivered: return "Sent to terminal"
        case .failed: return "Delivery failed"
        }
    }
}

public enum PromptOrigin: Codable, Equatable, Sendable {
    case composer
    case chatgpt
    case phone
    case forwardedTerminalOutput(sourceAgentName: String)

    public var displayName: String {
        switch self {
        case .composer: return "Composer"
        case .chatgpt: return "ChatGPT"
        case .phone: return "Phone"
        case .forwardedTerminalOutput(let source):
            return "Forwarded from \(source)"
        }
    }
}

/// Whether a raw-derived output block is actively changing, has gone quiet,
/// or was closed by a deterministic Conduit boundary.
///
/// Settled means only that no newer rendered snapshot has arrived during the
/// local quiet window. It never means the agent finished, succeeded, or is
/// waiting for input.
public enum AgentOutputState: String, Codable, Equatable, Sendable {
    case live
    case settled
    case closed

    public var displayName: String {
        switch self {
        case .live: return "Updating"
        case .settled: return "Output quiet"
        case .closed: return "Capture closed"
        }
    }
}

/// The rendered surface used to create an agent-visible output block.
public enum AgentOutputExtraction: String, Codable, Equatable, Sendable {
    case renderedBuffer
    case tmuxPane
    case structuredAdapter

    public var displayName: String {
        switch self {
        case .renderedBuffer: return "Rendered terminal buffer"
        case .tmuxPane: return "Rendered tmux pane"
        case .structuredAdapter: return "Structured adapter"
        }
    }
}

/// Best-effort agent-visible output associated with one native prompt.
///
/// Raw-derived blocks can contain prompt echo, status chrome, tool logs, or
/// prose. Their authority label is therefore part of the value, not cosmetic
/// UI: this is a convenient view over Raw, not a provider transcript.
public struct AgentVisibleOutput: Codable, Equatable, Sendable {
    public let promptEventID: UUID?
    public let text: String
    public let state: AgentOutputState
    public let extraction: AgentOutputExtraction
    public let truncated: Bool

    public init(
        promptEventID: UUID?,
        text: String,
        state: AgentOutputState,
        extraction: AgentOutputExtraction,
        truncated: Bool
    ) {
        self.promptEventID = promptEventID
        self.text = text
        self.state = state
        self.extraction = extraction
        self.truncated = truncated
    }

    public func withState(_ state: AgentOutputState) -> AgentVisibleOutput {
        AgentVisibleOutput(
            promptEventID: promptEventID,
            text: text,
            state: state,
            extraction: extraction,
            truncated: truncated
        )
    }
}

/// Exact native-composer submission. `renderedPayload` is the payload handed
/// to the terminal controller after attachment paths are assembled; `text`
/// and `attachmentPaths` retain the human-readable ingredients separately.
public struct SubmittedPrompt: Codable, Equatable, Sendable {
    public let origin: PromptOrigin
    public let text: String
    public let attachmentPaths: [String]
    public let renderedPayload: String
    public var delivery: PromptDeliveryState

    public init(
        origin: PromptOrigin = .composer,
        text: String,
        attachmentPaths: [String],
        renderedPayload: String,
        delivery: PromptDeliveryState = .queued
    ) {
        self.origin = origin
        self.text = text
        self.attachmentPaths = attachmentPaths
        self.renderedPayload = renderedPayload
        self.delivery = delivery
    }
}

public enum SessionPresentationEventKind: Codable, Equatable, Sendable {
    case sessionOpened(SessionEntry)
    case userPrompt(SubmittedPrompt)
    case agentOutput(AgentVisibleOutput)
    /// Conduit issued an interrupt request to a live runtime. This is not an
    /// assertion that the provider received it or that its turn stopped.
    case interruptRequested
}

/// One append-first item in Conduit's derived session view.
///
/// This is presentation state, not a completion ledger and not a replacement
/// for the live terminal view.
public struct SessionPresentationEvent: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let occurredAt: Date
    public let authority: SessionEventAuthority
    public let kind: SessionPresentationEventKind

    public init(
        id: UUID = UUID(),
        occurredAt: Date = Date(),
        authority: SessionEventAuthority,
        kind: SessionPresentationEventKind
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.authority = authority
        self.kind = kind
    }
}

/// Pure constructors and reducers used by both the app and dependency-free
/// verification.
public enum SessionPresentation {
    public static func openingEvent(
        _ entry: SessionEntry,
        id: UUID = UUID(),
        occurredAt: Date = Date()
    ) -> SessionPresentationEvent {
        SessionPresentationEvent(
            id: id,
            occurredAt: occurredAt,
            authority: .conduitRecorded,
            kind: .sessionOpened(entry)
        )
    }

    public static func promptEvent(
        origin: PromptOrigin = .composer,
        text: String,
        attachmentPaths: [String],
        renderedPayload: String,
        id: UUID = UUID(),
        occurredAt: Date = Date()
    ) -> SessionPresentationEvent {
        SessionPresentationEvent(
            id: id,
            occurredAt: occurredAt,
            authority: .conduitRecorded,
            kind: .userPrompt(
                SubmittedPrompt(
                    origin: origin,
                    text: text,
                    attachmentPaths: attachmentPaths,
                    renderedPayload: renderedPayload
                )
            )
        )
    }

    public static func agentOutputEvent(
        promptEventID: UUID?,
        text: String,
        state: AgentOutputState = .live,
        extraction: AgentOutputExtraction,
        truncated: Bool,
        id: UUID = UUID(),
        occurredAt: Date = Date()
    ) -> SessionPresentationEvent {
        SessionPresentationEvent(
            id: id,
            occurredAt: occurredAt,
            authority: extraction == .structuredAdapter
                ? .toolReported
                : .derivedFromRaw,
            kind: .agentOutput(
                AgentVisibleOutput(
                    promptEventID: promptEventID,
                    text: text,
                    state: state,
                    extraction: extraction,
                    truncated: truncated
                )
            )
        )
    }

    /// Records the local, durable boundary between requesting an interrupt and
    /// later observing a provider turn state. It intentionally carries no
    /// output text and cannot be confused with text-cap truncation.
    public static func interruptRequestEvent(
        id: UUID = UUID(),
        occurredAt: Date = Date()
    ) -> SessionPresentationEvent {
        SessionPresentationEvent(
            id: id,
            occurredAt: occurredAt,
            authority: .conduitRecorded,
            kind: .interruptRequested
        )
    }

    /// Updates only the matching prompt event. Opening and unrelated prompt
    /// events retain their identity and contents.
    public static func updatingPromptDelivery(
        in events: [SessionPresentationEvent],
        eventID: UUID,
        to delivery: PromptDeliveryState
    ) -> [SessionPresentationEvent] {
        events.map { event in
            guard event.id == eventID,
                  case .userPrompt(var prompt) = event.kind,
                  prompt.delivery == .queued
            else { return event }
            prompt.delivery = delivery
            return SessionPresentationEvent(
                id: event.id,
                occurredAt: event.occurredAt,
                authority: event.authority,
                kind: .userPrompt(prompt)
            )
        }
    }

    /// Inserts or replaces one agent-output projection while preserving its
    /// original timeline position. The append-only history stores each
    /// replacement as a new immutable revision of the same event identifier.
    public static func upsertingAgentOutput(
        in events: [SessionPresentationEvent],
        event: SessionPresentationEvent
    ) -> [SessionPresentationEvent] {
        guard case .agentOutput = event.kind else { return events }
        guard let index = events.firstIndex(where: { $0.id == event.id }) else {
            return events + [event]
        }
        guard case .agentOutput = events[index].kind else { return events }
        var updated = events
        updated[index] = event
        return updated
    }

    /// Groups timeline events into operator-facing turns for document layout.
    ///
    /// Session boundaries stand alone. Each user prompt opens a turn; consecutive
    /// agent-output events attach to that turn (typically one growing projection).
    /// Orphan agent outputs (no preceding prompt in this window) form assistant-only
    /// turns. This is presentation structure only — not a claim of structured ACP turns.
    public static func conversationTurns(
        from events: [SessionPresentationEvent]
    ) -> [ConversationTurn] {
        var turns: [ConversationTurn] = []
        var openUser: SessionPresentationEvent?
        var openOutputs: [SessionPresentationEvent] = []

        func flushOpen() {
            if openUser != nil || !openOutputs.isEmpty {
                turns.append(
                    ConversationTurn(
                        id: openUser?.id ?? openOutputs.first?.id ?? UUID(),
                        kind: .exchange(user: openUser, outputs: openOutputs)
                    )
                )
            }
            openUser = nil
            openOutputs = []
        }

        for event in events {
            switch event.kind {
            case .sessionOpened, .interruptRequested:
                flushOpen()
                turns.append(ConversationTurn(id: event.id, kind: .boundary(event)))
            case .userPrompt:
                flushOpen()
                openUser = event
            case .agentOutput:
                openOutputs.append(event)
            }
        }
        flushOpen()
        return turns
    }
}

/// One visual unit in the Conversation document stream.
public struct ConversationTurn: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let kind: Kind

    public enum Kind: Equatable, Sendable {
        case boundary(SessionPresentationEvent)
        /// Operator prompt plus zero or more growing Derived/structured outputs.
        case exchange(
            user: SessionPresentationEvent?,
            outputs: [SessionPresentationEvent]
        )
    }

    public init(id: UUID, kind: Kind) {
        self.id = id
        self.kind = kind
    }
}
