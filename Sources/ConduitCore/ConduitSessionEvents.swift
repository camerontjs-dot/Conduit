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

    public init(
        threadID: String? = nil,
        turnActive: Bool = false,
        lastTurnStatus: String? = nil,
        pendingApproval: Bool = false,
        pendingApprovalSummary: String? = nil
    ) {
        self.threadID = threadID
        self.turnActive = turnActive
        self.lastTurnStatus = lastTurnStatus
        self.pendingApproval = pendingApproval
        self.pendingApprovalSummary = pendingApprovalSummary
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

    public init(
        taskSessionID: String,
        backend: AgentSessionBackend,
        sessionLifecycle: String,
        runtimeState: String,
        live: Bool,
        ready: Bool,
        events: [SessionPresentationEvent],
        adapter: ConduitSessionAdapterSnapshot? = nil
    ) {
        self.taskSessionID = taskSessionID
        self.backend = backend
        self.sessionLifecycle = sessionLifecycle
        self.runtimeState = runtimeState
        self.live = live
        self.ready = ready
        self.events = events
        self.adapter = adapter
    }
}

public enum ConduitSessionEventCursorState: String, Equatable, Sendable {
    case ok
    case ahead
    case invalid
}

/// Turn observation for one existing task. Session lifecycle stays separate:
/// a running Codex session may still have a completed turn.
public struct ConduitSessionTurnSnapshot: Equatable, Sendable {
    public var state: String
    public var status: String?
    public var honesty: String
    public var ambiguity: String?
    public var threadID: String?
    public var pendingApproval: Bool

    public init(
        state: String,
        status: String? = nil,
        honesty: String,
        ambiguity: String? = nil,
        threadID: String? = nil,
        pendingApproval: Bool = false
    ) {
        self.state = state
        self.status = status
        self.honesty = honesty
        self.ambiguity = ambiguity
        self.threadID = threadID
        self.pendingApproval = pendingApproval
    }

    public func jsonObject() -> [String: Any] {
        var payload: [String: Any] = [
            "state": state,
            "honesty": honesty,
            "pending_approval": pendingApproval,
        ]
        if let status { payload["status"] = status }
        if let ambiguity { payload["ambiguity"] = ambiguity }
        if let threadID { payload["thread_id"] = threadID }
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
        self.authority = authority
    }

    public func jsonObject() -> [String: Any] {
        [
            "taskSessionID": taskSessionID,
            "backend": backend,
            "session": session.jsonObject(),
            "turn": turn.jsonObject(),
            "events": events.map { $0.jsonObject() },
            "next_cursor": nextCursor,
            "has_more": hasMore,
            "cursor_state": cursorState.rawValue,
            "timeline_count": timelineCount,
            "truncated": truncated,
            "authority": authority,
        ]
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

        return ConduitSessionEventPage(
            taskSessionID: source.taskSessionID,
            backend: source.backend.workSessionLabel,
            session: ConduitSessionLifecycleSnapshot(
                lifecycle: source.sessionLifecycle,
                runtimeState: source.runtimeState,
                live: source.live,
                ready: source.ready
            ),
            turn: turnSnapshot(source: source),
            events: records,
            nextCursor: encodeCursor(end),
            hasMore: end < count,
            cursorState: cursorState,
            timelineCount: count,
            truncated: records.contains(where: \.truncated)
        )
    }

    public static func turnSnapshot(
        source: ConduitSessionEventSource
    ) -> ConduitSessionTurnSnapshot {
        let adapter = source.adapter
        if source.backend == .appServer {
            if adapter?.pendingApproval == true {
                return ConduitSessionTurnSnapshot(
                    state: "awaiting_input",
                    status: adapter?.lastTurnStatus,
                    honesty: "structured adapter requested approval; operator decision stays on the Mac. Not verification.",
                    threadID: adapter?.threadID,
                    pendingApproval: true
                )
            }
            if adapter?.turnActive == true || lastStructuredOutput(in: source.events)?.state == .live {
                return ConduitSessionTurnSnapshot(
                    state: "active",
                    status: adapter?.lastTurnStatus,
                    honesty: "structured adapter turn is active. Not verification.",
                    threadID: adapter?.threadID
                )
            }
            if adapter?.lastTurnStatus != nil
                || lastStructuredOutput(in: source.events)?.state == .closed
            {
                return ConduitSessionTurnSnapshot(
                    state: "completed",
                    status: adapter?.lastTurnStatus ?? "completed",
                    honesty: "structured adapter reported turn completion. Not verified success.",
                    threadID: adapter?.threadID
                )
            }
            if hasDeliveredPrompt(in: source.events) {
                return ConduitSessionTurnSnapshot(
                    state: "active",
                    honesty: "prompt was recorded for an app-server task; turn completion has not been observed.",
                    threadID: adapter?.threadID
                )
            }
            return ConduitSessionTurnSnapshot(
                state: "idle",
                honesty: "no structured turn has been observed yet.",
                threadID: adapter?.threadID
            )
        }

        return ptyTurnSnapshot(events: source.events)
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
            if case .agentOutput(let output) = event.kind,
               output.extraction == .structuredAdapter {
                return output
            }
        }
        return nil
    }

    private static func lastOutput(
        in events: [SessionPresentationEvent]
    ) -> AgentVisibleOutput? {
        for event in events.reversed() {
            if case .agentOutput(let output) = event.kind {
                return output
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

    private static func iso8601(_ date: Date) -> String {
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
