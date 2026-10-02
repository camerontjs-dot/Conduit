import Foundation

/// Live Codex adapter facts that can refine turn state without inventing it.
///
/// Absence means Conduit only has durable Conversation events. PTY agents
/// never populate this; their turn state stays explicitly ambiguous.
public struct ConduitSessionAdapterSnapshot: Equatable, Sendable {
    public var threadID: String?
    public var turnActive: Bool
    public var lastTurnStatus: String?
    public var pendingApproval: Bool
    public var pendingApprovalSummary: String?
    /// The provider's failure for THIS turn, from the adapter's
    /// terminal effect while the turn was still running (`turnFailed` for
    /// Codex; other adapters keep their existing provider-specific signals).
    ///
    /// Deliberately a separate field rather than something inferred from
    /// `lastTurnStatus` text, and deliberately scoped to the turn: an error
    /// that arrives after a turn completed does not un-complete it.
    /// Interrupting a finished turn makes the provider report an error, and
    /// treating that as a turn failure would erase a real completion.
    public var turnFailure: String?

    public init(
        threadID: String? = nil,
        turnActive: Bool = false,
        lastTurnStatus: String? = nil,
        pendingApproval: Bool = false,
        pendingApprovalSummary: String? = nil,
        turnFailure: String? = nil
    ) {
        self.threadID = threadID
        self.turnActive = turnActive
        self.lastTurnStatus = lastTurnStatus
        self.pendingApproval = pendingApproval
        self.pendingApprovalSummary = pendingApprovalSummary
        self.turnFailure = turnFailure
    }
}

public enum ConduitSessionProviderThreadSource: String, Codable, Equatable, Sendable {
    case live
    case persisted
    case unavailable
}

public enum ConduitSessionProviderProgress: String, Equatable, Sendable {
    case structured
    case unavailable
}

public enum ConduitSessionInputState: String, Equatable, Sendable {
    case approval
    case unknown
    case none
}

/// A bounded checkpoint derived from the current backend observation. PTY
/// values describe rendered-output capture only; they are never turn results.
public enum ConduitSessionObservationCheckpoint: String, Equatable, Sendable {
    case structuredActive = "structured_active"
    case structuredApproval = "structured_approval"
    case structuredCompleted = "structured_completed"
    /// The provider reported a failure for this turn. Distinct from
    /// `structuredCompleted`: an orchestrator that cannot tell these apart
    /// advances a plan on work that never happened.
    case structuredFailed = "structured_failed"
    case structuredIdle = "structured_idle"
    case outputLive = "output_live"
    case outputQuiet = "output_quiet"
    case outputUnobserved = "output_unobserved"
    case captureClosed = "capture_closed"
}

public struct ConduitSessionObservationSnapshot: Equatable, Sendable {
    public var observedAt: Date
    public var lastOutputAt: Date?
    public var lastOutputState: String
    public var checkpoint: ConduitSessionObservationCheckpoint
    public var providerProgress: ConduitSessionProviderProgress
    public var inputState: ConduitSessionInputState
    public var inputSummary: String?
    public var checkpointAuthority: String

    public init(
        observedAt: Date = Date(),
        lastOutputAt: Date? = nil,
        lastOutputState: String = "none",
        checkpoint: ConduitSessionObservationCheckpoint = .outputUnobserved,
        providerProgress: ConduitSessionProviderProgress = .unavailable,
        inputState: ConduitSessionInputState = .unknown,
        inputSummary: String? = nil,
        checkpointAuthority: String = "conduitRecorded"
    ) {
        self.observedAt = observedAt
        self.lastOutputAt = lastOutputAt
        self.lastOutputState = lastOutputState
        self.checkpoint = checkpoint
        self.providerProgress = providerProgress
        self.inputState = inputState
        self.inputSummary = inputSummary
        self.checkpointAuthority = checkpointAuthority
    }

    public func jsonObject() -> [String: Any] {
        var payload: [String: Any] = [
            "observed_at": ConduitSessionEventExport.iso8601(observedAt),
            "last_output_state": lastOutputState,
            "checkpoint": checkpoint.rawValue,
            "provider_progress": providerProgress.rawValue,
            "input_state": inputState.rawValue,
            "checkpoint_authority": checkpointAuthority,
        ]
        if let lastOutputAt {
            payload["last_output_at"] = ConduitSessionEventExport.iso8601(lastOutputAt)
        }
        if let inputSummary {
            payload["input_summary"] = inputSummary
        }
        return payload
    }
}

/// Observed session fields copied into an events page. These are the same
/// lifecycle facts `conduit_session_status` already exposes.
public struct ConduitSessionEventSource: Equatable, Sendable {
    public var taskSessionID: String
    public var backend: AgentSessionBackend
    public var sessionLifecycle: String
    public var runtimeState: String
    public var live: Bool
    public var ready: Bool
    public var events: [SessionPresentationEvent]
    public var adapter: ConduitSessionAdapterSnapshot?
    public var runtimeAttemptID: RuntimeAttemptID?
    public var persistedThreadID: String?
    public var observedAt: Date

    public init(
        taskSessionID: String,
        backend: AgentSessionBackend,
        sessionLifecycle: String,
        runtimeState: String,
        live: Bool,
        ready: Bool,
        events: [SessionPresentationEvent],
        adapter: ConduitSessionAdapterSnapshot? = nil,
        runtimeAttemptID: RuntimeAttemptID? = nil,
        persistedThreadID: String? = nil,
        observedAt: Date = Date()
    ) {
        self.taskSessionID = taskSessionID
        self.backend = backend
        self.sessionLifecycle = sessionLifecycle
        self.runtimeState = runtimeState
        self.live = live
        self.ready = ready
        self.events = events
        self.adapter = adapter
        self.runtimeAttemptID = runtimeAttemptID
        self.persistedThreadID = persistedThreadID
        self.observedAt = observedAt
    }
}

public enum ConduitSessionEventCursorState: String, Codable, Equatable, Sendable {
    case ok
    case ahead
    case invalid
}

/// Turn observation for one existing task. Session lifecycle stays separate:
/// a running Codex session may still have a completed turn.
public struct ConduitSessionTurnSnapshot: Codable, Equatable, Sendable {
    public var state: String
    public var status: String?
    public var honesty: String
    public var ambiguity: String?
    public var threadID: String?
    public var threadIDSource: ConduitSessionProviderThreadSource
    public var pendingApproval: Bool
    public var failure: ProviderTurnFailureReceipt?

    public init(
        state: String,
        status: String? = nil,
        honesty: String,
        ambiguity: String? = nil,
        threadID: String? = nil,
        threadIDSource: ConduitSessionProviderThreadSource = .unavailable,
        pendingApproval: Bool = false,
        failure: ProviderTurnFailureReceipt? = nil
    ) {
        self.state = state
        self.status = status
        self.honesty = honesty
        self.ambiguity = ambiguity
        self.threadID = threadID
        self.threadIDSource = threadIDSource
        self.pendingApproval = pendingApproval
        self.failure = failure
    }

    public func jsonObject() -> [String: Any] {
        var payload: [String: Any] = [
            "state": state,
            "honesty": honesty,
            "thread_id_source": threadIDSource.rawValue,
            "pending_approval": pendingApproval,
        ]
        if let status { payload["status"] = status }
        if let ambiguity { payload["ambiguity"] = ambiguity }
        if let threadID { payload["thread_id"] = threadID }
        if let failure { payload["failure"] = failure.jsonObject() }
        return payload
    }
}

public struct ConduitSessionArtifactRef: Equatable, Sendable {
    public var kind: String
    public var path: String

    public init(kind: String, path: String) {
        self.kind = kind
        self.path = path
    }

    public func jsonObject() -> [String: Any] {
        ["kind": kind, "path": path]
    }
}

public struct ConduitSessionEventRecord: Equatable, Sendable {
    public var cursor: String
    public var eventID: String
    public var occurredAt: String
    public var kind: String
    public var authority: String
    public var source: String
    public var text: String?
    public var state: String?
    public var truncated: Bool
    public var redacted: Bool
    public var promptEventID: String?
    public var artifactRefs: [ConduitSessionArtifactRef]
    public var turnStatus: String?
    public var providerFailure: ProviderTurnFailureReceipt?
    public var contentDigest: String

    public init(
        cursor: String,
        eventID: String,
        occurredAt: String,
        kind: String,
        authority: String,
        source: String,
        text: String? = nil,
        state: String? = nil,
        truncated: Bool,
        redacted: Bool,
        promptEventID: String? = nil,
        artifactRefs: [ConduitSessionArtifactRef] = [],
        turnStatus: String? = nil,
        providerFailure: ProviderTurnFailureReceipt? = nil,
        contentDigest: String
    ) {
        self.cursor = cursor
        self.eventID = eventID
        self.occurredAt = occurredAt
        self.kind = kind
        self.authority = authority
        self.source = source
        self.text = text
        self.state = state
        self.truncated = truncated
        self.redacted = redacted
        self.promptEventID = promptEventID
        self.artifactRefs = artifactRefs
        self.turnStatus = turnStatus
        self.providerFailure = providerFailure
        self.contentDigest = contentDigest
    }

    public func jsonObject() -> [String: Any] {
        var payload: [String: Any] = [
            "cursor": cursor,
            "event_id": eventID,
            "occurred_at": occurredAt,
            "kind": kind,
            "authority": authority,
            "source": source,
            "truncated": truncated,
            "redacted": redacted,
            "artifact_refs": artifactRefs.map { $0.jsonObject() },
            "content_digest": contentDigest,
        ]
        if let text { payload["text"] = text }
        if let state { payload["state"] = state }
        if let promptEventID { payload["prompt_event_id"] = promptEventID }
        if let turnStatus { payload["turn_status"] = turnStatus }
        if let providerFailure { payload["provider_failure"] = providerFailure.jsonObject() }
        return payload
    }
}

public struct ConduitSessionLifecycleSnapshot: Equatable, Sendable {
    public var lifecycle: String
    public var runtimeState: String
    public var live: Bool
    public var ready: Bool

    public init(
        lifecycle: String,
        runtimeState: String,
        live: Bool,
        ready: Bool
    ) {
        self.lifecycle = lifecycle
        self.runtimeState = runtimeState
        self.live = live
        self.ready = ready
    }

    public func jsonObject() -> [String: Any] {
        [
            "lifecycle": lifecycle,
            "runtime_state": runtimeState,
            "live": live,
            "ready": ready,
        ]
    }
}

public struct ConduitSessionEventPage: Equatable, Sendable {
    public static let defaultLimit = 20
    public static let maxLimit = 50
    public static let defaultTextLimit = 2_000
    public static let authorityNote =
        "observed events; not verification. PTY output is observation; structured adapter events are separately labelled; MindGraph is nomination only."

    public var taskSessionID: String
    public var backend: String
    public var session: ConduitSessionLifecycleSnapshot
    public var turn: ConduitSessionTurnSnapshot
    public var events: [ConduitSessionEventRecord]
    public var nextCursor: String
    public var hasMore: Bool
    public var cursorState: ConduitSessionEventCursorState
    public var timelineCount: Int
    public var truncated: Bool
    public var runtimeAttemptID: RuntimeAttemptID?
    public var observation: ConduitSessionObservationSnapshot
    public var authority: String

    public init(
        taskSessionID: String,
        backend: String,
        session: ConduitSessionLifecycleSnapshot,
        turn: ConduitSessionTurnSnapshot,
        events: [ConduitSessionEventRecord],
        nextCursor: String,
        hasMore: Bool,
        cursorState: ConduitSessionEventCursorState,
        timelineCount: Int,
        truncated: Bool,
        runtimeAttemptID: RuntimeAttemptID? = nil,
        observation: ConduitSessionObservationSnapshot = ConduitSessionObservationSnapshot(),
        authority: String = ConduitSessionEventPage.authorityNote
    ) {
        self.taskSessionID = taskSessionID
        self.backend = backend
        self.session = session
        self.turn = turn
        self.events = events
        self.nextCursor = nextCursor
        self.hasMore = hasMore
        self.cursorState = cursorState
        self.timelineCount = timelineCount
        self.truncated = truncated
        self.runtimeAttemptID = runtimeAttemptID
        self.observation = observation
        self.authority = authority
    }

    public func jsonObject() -> [String: Any] {
        var payload: [String: Any] = [
            "taskSessionID": taskSessionID,
            "backend": backend,
            "session": session.jsonObject(),
            "turn": turn.jsonObject(),
            "observation": observation.jsonObject(),
            "events": events.map { $0.jsonObject() },
            "next_cursor": nextCursor,
            "has_more": hasMore,
            "cursor_state": cursorState.rawValue,
            "timeline_count": timelineCount,
            "truncated": truncated,
            "authority": authority,
        ]
        if let runtimeAttemptID {
            payload["runtime_attempt_id"] = runtimeAttemptID.rawValue.uuidString
        }
        return payload
    }
}

/// Incremental, cursor-bounded export of Conversation events for MCP clients.
///
/// Ordering is the projected presentation timeline. Revisions of an earlier
/// event stay at their original index; they are not appended as new events.
/// A cursor past the current count is stale (`ahead`), not an error.
public enum ConduitSessionEventExport {
    public static func encodeCursor(_ index: Int) -> String {
        "v1:\(max(0, index))"
    }

    public static func parseCursor(_ raw: String?) -> (index: Int, state: ConduitSessionEventCursorState) {
        guard let raw else { return (0, .ok) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return (0, .ok) }
        if trimmed.allSatisfy(\.isNumber), let value = Int(trimmed) {
            return (max(0, value), .ok)
        }
        guard trimmed.hasPrefix("v1:") else { return (0, .invalid) }
        let digits = trimmed.dropFirst(3)
        guard let value = Int(digits), value >= 0 else { return (0, .invalid) }
        return (value, .ok)
    }

    public static func clampLimit(_ limit: Int?) -> Int {
        guard let limit else { return ConduitSessionEventPage.defaultLimit }
        if limit < 1 { return ConduitSessionEventPage.defaultLimit }
        return min(limit, ConduitSessionEventPage.maxLimit)
    }

    public static func page(
        source: ConduitSessionEventSource,
        cursor: String? = nil,
        limit: Int? = nil,
        textLimit: Int = ConduitSessionEventPage.defaultTextLimit
    ) -> ConduitSessionEventPage {
        let parsed = parseCursor(cursor)
        let pageLimit = clampLimit(limit)
        let count = source.events.count
        var cursorState = parsed.state
        var start = parsed.index
        if parsed.state == .ok, start > count {
            cursorState = .ahead
            start = count
        } else if parsed.state == .ok {
            start = min(start, count)
        } else {
            start = 0
        }

        let end = min(count, start + pageLimit)
        let slice = source.events.enumerated().filter { $0.offset >= start && $0.offset < end }
        let records = slice.map { item in
            record(
                event: item.element,
                index: item.offset,
                source: source,
                textLimit: textLimit
            )
        }

        let turn = turnSnapshot(source: source)
        return ConduitSessionEventPage(
            taskSessionID: source.taskSessionID,
            backend: source.backend.workSessionLabel,
            session: ConduitSessionLifecycleSnapshot(
                lifecycle: source.sessionLifecycle,
                runtimeState: source.runtimeState,
                live: source.live,
                ready: source.ready
            ),
            turn: turn,
            events: records,
            nextCursor: encodeCursor(end),
            hasMore: end < count,
            cursorState: cursorState,
            timelineCount: count,
            truncated: records.contains(where: \.truncated),
            runtimeAttemptID: source.runtimeAttemptID,
            observation: observationSnapshot(source: source, turn: turn)
        )
    }

    public static func turnSnapshot(
        source: ConduitSessionEventSource
    ) -> ConduitSessionTurnSnapshot {
        let adapter = source.adapter
        let thread = providerThreadSnapshot(source: source)
        if source.backend.isStructured {
            // This receipt is bound to the latest actually delivered input.
            // A later delivered input stops matching it; a stale live bit or
            // delayed approval cannot erase terminal evidence for that input.
            if let failure = durableFailure(source: source) {
                return ConduitSessionTurnSnapshot(
                    state: "failed", status: "failed",
                    honesty: "Provider reported a terminal turn failure. Not completion, verification, or objective acceptance.",
                    threadID: failure.threadID,
                    threadIDSource: adapter == nil ? .persisted : .live,
                    failure: failure
                )
            }
            if adapter?.pendingApproval == true {
                return ConduitSessionTurnSnapshot(
                    state: "awaiting_input",
                    status: adapter?.lastTurnStatus,
                    honesty: "structured adapter requested approval; operator decision stays on the Mac. Not verification.",
                    threadID: thread.id,
                    threadIDSource: thread.source,
                    pendingApproval: true
                )
            }
            if adapter?.turnActive == true {
                return ConduitSessionTurnSnapshot(
                    state: "active",
                    status: adapter?.lastTurnStatus,
                    honesty: "structured adapter turn is active. Not verification.",
                    threadID: thread.id,
                    threadIDSource: thread.source
                )
            }
            // A provider failure ends the turn, but it is not completion.
            // Checked before the completion branch because an adapter can
            // report a terminal status alongside the error, and any non-nil
            // status used to be mapped straight to "completed".
            if adapter?.lastTurnStatus == "failed"
                || (adapter?.turnFailure.map { !$0.isEmpty } ?? false) {
                return ConduitSessionTurnSnapshot(
                    state: "failed",
                    status: adapter?.lastTurnStatus ?? "failed",
                    honesty: "structured adapter reported a provider failure for this turn. Not completion or verification.",
                    threadID: thread.id,
                    threadIDSource: thread.source
                )
            }
            if lastStructuredOutput(in: source.events)?.state == .live {
                return ConduitSessionTurnSnapshot(
                    state: "active", honesty: "Structured output was observed live; no terminal result is recorded. Not verification.",
                    threadID: thread.id, threadIDSource: thread.source
                )
            }
            if adapter?.lastTurnStatus != nil
                || lastStructuredOutput(in: source.events)?.state == .closed
            {
                return ConduitSessionTurnSnapshot(
                    state: "completed",
                    status: adapter?.lastTurnStatus ?? "completed",
                    honesty: "structured adapter reported turn completion. Not verified success.",
                    threadID: thread.id,
                    threadIDSource: thread.source
                )
            }
            if hasDeliveredPrompt(in: source.events) {
                return ConduitSessionTurnSnapshot(
                    state: "active",
                    honesty: "prompt was recorded for an app-server task; turn completion has not been observed.",
                    threadID: thread.id,
                    threadIDSource: thread.source
                )
            }
            return ConduitSessionTurnSnapshot(
                state: "idle",
                honesty: "no structured turn has been observed yet.",
                threadID: thread.id,
                threadIDSource: thread.source
            )
        }

        return ptyTurnSnapshot(events: source.events)
    }

    /// Additive supervisory snapshot from the full source timeline, not the
    /// current page slice. In-place structured revisions therefore remain
    /// visible here even if a client advanced past the live cursor. Event
    /// identity, cursor advancement, truncation, interrupt acknowledgement,
    /// and create-task readiness are unchanged.
    public static func observationSnapshot(
        source: ConduitSessionEventSource,
        turn: ConduitSessionTurnSnapshot? = nil
    ) -> ConduitSessionObservationSnapshot {
        let resolvedTurn = turn ?? turnSnapshot(source: source)
        let outputEvent = lastOutputEvent(in: source.events)
        let lastOutputState: String
        let outputAt: Date?
        if let outputEvent,
           case .agentOutput(let output) = outputEvent.kind {
            lastOutputState = output.state.rawValue
            outputAt = outputEvent.occurredAt
        } else {
            lastOutputState = "none"
            outputAt = nil
        }

        if source.backend.isStructured {
            let checkpoint: ConduitSessionObservationCheckpoint
            let inputState: ConduitSessionInputState
            let inputSummary: String?
            switch resolvedTurn.state {
            case "awaiting_input":
                checkpoint = .structuredApproval
                inputState = .approval
                inputSummary = source.adapter?.pendingApprovalSummary
            case "active":
                checkpoint = .structuredActive
                inputState = .none
                inputSummary = nil
            case "completed":
                checkpoint = .structuredCompleted
                inputState = .none
                inputSummary = nil
            case "failed":
                checkpoint = .structuredFailed
                inputState = .none
                inputSummary = nil
            default:
                checkpoint = .structuredIdle
                inputState = .none
                inputSummary = nil
            }
            return ConduitSessionObservationSnapshot(
                observedAt: source.observedAt,
                lastOutputAt: outputAt,
                lastOutputState: lastOutputState,
                checkpoint: checkpoint,
                providerProgress: source.adapter == nil ? .unavailable : .structured,
                inputState: inputState,
                inputSummary: inputSummary,
                checkpointAuthority: observationAuthority(
                    source: source,
                    outputEvent: outputEvent
                )
            )
        }

        // PTY checkpoints describe captured output only. Quiet, closed, and
        // unobserved never map onto structured completion or approval.
        let checkpoint: ConduitSessionObservationCheckpoint
        switch outputState(from: outputEvent) {
        case .live:
            checkpoint = .outputLive
        case .settled:
            checkpoint = .outputQuiet
        case .closed:
            checkpoint = .captureClosed
        case nil:
            checkpoint = .outputUnobserved
        }
        return ConduitSessionObservationSnapshot(
            observedAt: source.observedAt,
            lastOutputAt: outputAt,
            lastOutputState: lastOutputState,
            checkpoint: checkpoint,
            providerProgress: .unavailable,
            inputState: .unknown,
            checkpointAuthority: observationAuthority(
                source: source,
                outputEvent: outputEvent
            )
        )
    }

    public static func sanitizeText(
        _ text: String,
        limit: Int = ConduitSessionEventPage.defaultTextLimit
    ) -> (text: String, truncated: Bool, redacted: Bool) {
        var redacted = false
        var working = text
        for pattern in secretPatterns {
            let replaced = pattern.stringByReplacingMatches(
                in: working,
                range: NSRange(working.startIndex..<working.endIndex, in: working),
                withTemplate: "[redacted]"
            )
            if replaced != working {
                redacted = true
                working = replaced
            }
        }

        var kept: [String] = []
        for line in working.split(separator: "\n", omittingEmptySubsequences: false) {
            let value = String(line)
            if reasoningLine.numberOfMatches(
                in: value,
                range: NSRange(value.startIndex..<value.endIndex, in: value)
            ) > 0 {
                redacted = true
                kept.append("[redacted-reasoning]")
            } else {
                kept.append(value)
            }
        }
        working = kept.joined(separator: "\n")

        let boundedLimit = max(32, limit)
        if working.count > boundedLimit {
            return (
                String(working.prefix(boundedLimit)) + "\n[truncated]",
                true,
                redacted
            )
        }
        return (working, false, redacted)
    }

    private static func record(
        event: SessionPresentationEvent,
        index: Int,
        source: ConduitSessionEventSource,
        textLimit: Int
    ) -> ConduitSessionEventRecord {
        switch event.kind {
        case .sessionOpened(let entry):
            let text: String
            switch entry {
            case let .started(agentName, requestedBackend):
                text = "started \(agentName) via \(requestedBackend)"
            case let .resumed(agentName, tmuxSessionName, attachedElsewhere):
                text = attachedElsewhere
                    ? "resumed \(agentName) at \(tmuxSessionName) (attached elsewhere)"
                    : "resumed \(agentName) at \(tmuxSessionName)"
            }
            return makeRecord(
                event: event,
                index: index,
                kind: "session_lifecycle",
                source: "session",
                text: text,
                state: "opened",
                sourceTruncated: false,
                textLimit: textLimit
            )

        case .userPrompt(let prompt):
            let sanitized = sanitizeText(prompt.text, limit: textLimit)
            return makeRecord(
                event: event,
                index: index,
                kind: "user_prompt",
                source: promptOriginLabel(prompt.origin),
                text: sanitized.text,
                state: prompt.delivery.rawValue,
                sourceTruncated: sanitized.truncated,
                alreadyRedacted: sanitized.redacted,
                artifactRefs: prompt.attachmentPaths.map {
                    ConduitSessionArtifactRef(kind: "attachment", path: $0)
                },
                textLimit: textLimit
            )

        case .agentOutput(let output):
            let sanitized = sanitizeText(output.text, limit: textLimit)
            let turnStatus: String?
            if output.extraction == .structuredAdapter, output.state == .closed {
                turnStatus = source.adapter?.lastTurnStatus ?? "completed"
            } else {
                turnStatus = nil
            }
            return makeRecord(
                event: event,
                index: index,
                kind: "agent_output",
                source: output.extraction.rawValue,
                text: sanitized.text,
                state: output.state.rawValue,
                sourceTruncated: output.truncated || sanitized.truncated,
                alreadyRedacted: sanitized.redacted,
                promptEventID: output.promptEventID?.uuidString,
                artifactRefs: artifactRefs(from: output),
                turnStatus: turnStatus,
                textLimit: textLimit
            )

        case .providerTurnFailed(let receipt):
            return makeRecord(
                event: event, index: index, kind: "provider_turn_failure", source: receipt.providerID,
                text: receipt.reason, state: "failed", sourceTruncated: false,
                alreadyRedacted: receipt.messageWithheld,
                promptEventID: receipt.promptEventID?.uuidString,
                turnStatus: "failed", providerFailure: receipt, textLimit: textLimit
            )

        case .interruptRequested:
            return makeRecord(
                event: event,
                index: index,
                kind: "interrupt_request",
                source: "conduit",
                text: "Conduit issued an interrupt request. Provider cancellation has not been observed.",
                state: "requested",
                sourceTruncated: false,
                textLimit: textLimit
            )
        }
    }

    private static func makeRecord(
        event: SessionPresentationEvent,
        index: Int,
        kind: String,
        source: String,
        text: String?,
        state: String?,
        sourceTruncated: Bool,
        alreadyRedacted: Bool = false,
        promptEventID: String? = nil,
        artifactRefs: [ConduitSessionArtifactRef] = [],
        turnStatus: String? = nil,
        providerFailure: ProviderTurnFailureReceipt? = nil,
        textLimit: Int
    ) -> ConduitSessionEventRecord {
        let sanitized: (text: String, truncated: Bool, redacted: Bool)
        if let text {
            sanitized = sanitizeText(text, limit: textLimit)
        } else {
            sanitized = ("", false, false)
        }
        let exportedText = text == nil ? nil : sanitized.text
        let truncated = sourceTruncated || sanitized.truncated
        let redacted = alreadyRedacted || sanitized.redacted
        let digest = contentDigest(
            eventID: event.id.uuidString,
            kind: kind,
            authority: event.authority.rawValue,
            state: state,
            text: exportedText ?? ""
        )
        return ConduitSessionEventRecord(
            cursor: encodeCursor(index),
            eventID: event.id.uuidString,
            occurredAt: iso8601(event.occurredAt),
            kind: kind,
            authority: event.authority.rawValue,
            source: source,
            text: exportedText,
            state: state,
            truncated: truncated,
            redacted: redacted,
            promptEventID: promptEventID,
            artifactRefs: artifactRefs,
            turnStatus: turnStatus,
            providerFailure: providerFailure,
            contentDigest: digest
        )
    }

    private static func ptyTurnSnapshot(
        events: [SessionPresentationEvent]
    ) -> ConduitSessionTurnSnapshot {
        switch lastOutput(in: events)?.state {
        case .live:
            return ConduitSessionTurnSnapshot(
                state: "active",
                honesty: "PTY-derived output is still changing. This is observation, not a turn protocol.",
                ambiguity: "pty_output_live"
            )
        case .settled:
            return ConduitSessionTurnSnapshot(
                state: "ambiguous",
                honesty: "PTY-derived output is quiet. Quiet is not turn completion, awaiting input, or success.",
                ambiguity: "pty_output_quiet"
            )
        case .closed:
            return ConduitSessionTurnSnapshot(
                state: "ambiguous",
                honesty: "PTY capture was closed by Conduit. Capture close is not agent completion.",
                ambiguity: "pty_capture_closed"
            )
        case nil:
            if lastPrompt(in: events)?.delivery == .queued {
                return ConduitSessionTurnSnapshot(
                    state: "active",
                    honesty: "prompt is queued to a PTY. Output and completion remain unobserved.",
                    ambiguity: "pty_prompt_queued"
                )
            }
            if hasDeliveredPrompt(in: events) {
                return ConduitSessionTurnSnapshot(
                    state: "ambiguous",
                    honesty: "A prompt was delivered to a PTY, but no bounded output block has been observed yet.",
                    ambiguity: "pty_output_unobserved"
                )
            }
            return ConduitSessionTurnSnapshot(
                state: "idle",
                honesty: "No PTY prompt or output has been observed yet.",
                ambiguity: "pty_idle"
            )
        }
    }

    private static func lastStructuredOutput(
        in events: [SessionPresentationEvent]
    ) -> AgentVisibleOutput? {
        for event in events.reversed() {
            if case .userPrompt(let prompt) = event.kind, prompt.delivery == .delivered { return nil }
            if case .agentOutput(let output) = event.kind,
               output.extraction == .structuredAdapter {
                return output
            }
        }
        return nil
    }

    private static func lastOutputEvent(
        in events: [SessionPresentationEvent]
    ) -> SessionPresentationEvent? {
        for event in events.reversed() {
            if case .agentOutput = event.kind {
                return event
            }
        }
        return nil
    }

    private static func lastOutput(
        in events: [SessionPresentationEvent]
    ) -> AgentVisibleOutput? {
        guard let event = lastOutputEvent(in: events),
              case .agentOutput(let output) = event.kind
        else { return nil }
        return output
    }

    private static func outputState(
        from event: SessionPresentationEvent?
    ) -> AgentOutputState? {
        guard let event,
              case .agentOutput(let output) = event.kind
        else { return nil }
        return output.state
    }

    private static func providerThreadSnapshot(
        source: ConduitSessionEventSource
    ) -> (id: String?, source: ConduitSessionProviderThreadSource) {
        guard source.backend.isStructured else {
            return (nil, .unavailable)
        }
        if let liveThreadID = source.adapter?.threadID,
           !liveThreadID.isEmpty {
            return (liveThreadID, .live)
        }
        if source.adapter == nil,
           let persistedThreadID = source.persistedThreadID,
           !persistedThreadID.isEmpty {
            return (persistedThreadID, .persisted)
        }
        return (nil, .unavailable)
    }

    private static func observationAuthority(
        source: ConduitSessionEventSource,
        outputEvent: SessionPresentationEvent?
    ) -> String {
        if let outputEvent {
            return outputEvent.authority.rawValue
        }
        if source.backend.isStructured, source.adapter != nil {
            return "toolReported"
        }
        if source.backend.isStructured, durableFailure(source: source) != nil { return "toolReported" }
        return "conduitRecorded"
    }

    private static func durableFailure(source: ConduitSessionEventSource) -> ProviderTurnFailureReceipt? {
        // Only Codex has this durable terminal protocol path today. A receipt
        // must not give another provider an invented error interpretation.
        guard source.backend == .appServer else { return nil }
        let promptID = source.events.last(where: {
            if case .userPrompt(let prompt) = $0.kind { return prompt.delivery == .delivered }
            return false
        })?.id
        guard let promptID else { return nil }
        let thread = source.adapter?.threadID ?? source.persistedThreadID
        for event in source.events.reversed() {
            if case .providerTurnFailed(let receipt) = event.kind,
               event.authority == .toolReported, receipt.promptEventID == promptID,
               receipt.providerID == "codex", receipt.runtime == "codex-app-server",
               thread == nil || thread == receipt.threadID {
                return receipt
            }
        }
        return nil
    }

    private static func lastPrompt(
        in events: [SessionPresentationEvent]
    ) -> SubmittedPrompt? {
        for event in events.reversed() {
            if case .userPrompt(let prompt) = event.kind {
                return prompt
            }
        }
        return nil
    }

    private static func hasDeliveredPrompt(
        in events: [SessionPresentationEvent]
    ) -> Bool {
        events.contains { event in
            if case .userPrompt(let prompt) = event.kind {
                return prompt.delivery == .delivered
            }
            return false
        }
    }

    private static func promptOriginLabel(_ origin: PromptOrigin) -> String {
        switch origin {
        case .composer: return "composer"
        case .chatgpt: return "chatgpt"
        case .phone: return "phone"
        case .forwardedTerminalOutput: return "forwarded"
        }
    }

    private static func artifactRefs(
        from output: AgentVisibleOutput
    ) -> [ConduitSessionArtifactRef] {
        guard output.extraction == .structuredAdapter else { return [] }
        var refs: [ConduitSessionArtifactRef] = []
        for line in output.text.split(separator: "\n") {
            let value = String(line)
            guard let match = structuredPathLine.firstMatch(
                in: value,
                options: [],
                range: NSRange(value.startIndex..<value.endIndex, in: value)
            ),
                  let kindRange = Range(match.range(at: 1), in: value),
                  let pathRange = Range(match.range(at: 2), in: value)
            else { continue }
            let path = String(value[pathRange])
            guard looksLikePath(path) else { continue }
            refs.append(
                ConduitSessionArtifactRef(
                    kind: String(value[kindRange]),
                    path: path
                )
            )
        }
        return refs
    }

    private static func looksLikePath(_ value: String) -> Bool {
        if value.hasPrefix("/") || value.hasPrefix("./") || value.hasPrefix("../") {
            return true
        }
        let ext = URL(fileURLWithPath: value).pathExtension.lowercased()
        return !ext.isEmpty && value.contains("/")
    }

    private static func contentDigest(
        eventID: String,
        kind: String,
        authority: String,
        state: String?,
        text: String
    ) -> String {
        let seed = [eventID, kind, authority, state ?? "", text].joined(separator: "|")
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    static func iso8601(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let secretPatterns: [NSRegularExpression] = {
        let patterns = [
            #"Bearer\s+[A-Za-z0-9._\-+=/]+"#,
            #"\bsk-[A-Za-z0-9_-]{8,}"#,
            #"\bxai-[A-Za-z0-9_-]{8,}"#,
            #"\bgsk_[A-Za-z0-9_-]{8,}"#,
            #"\bghp_[A-Za-z0-9_-]{8,}"#,
            #"(?i)(api[_-]?key|authorization)\s*[:=]\s*\S+"#,
            #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]+?-----END [A-Z ]*PRIVATE KEY-----"#,
        ]
        return patterns.compactMap {
            try? NSRegularExpression(pattern: $0)
        }
    }()

    private static let reasoningLine: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"(?i)^\s*(thought|reasoning|chain[- ]of[- ]thought)\s*:"#
        )
    }()

    private static let structuredPathLine: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"^\[([A-Za-z0-9_]+)\]\s+(\S+)$"#
        )
    }()
}
