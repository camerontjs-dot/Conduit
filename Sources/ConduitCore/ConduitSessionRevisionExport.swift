import Foundation

/// Optional, additive reads on `conduit_session_events`.
///
/// Every field defaults to absent, which leaves the existing v1 timeline page
/// unchanged for clients that do not send them.
public struct ConduitSessionEventReadOptions: Equatable, Sendable {
    /// Revision cursor from a previous `changes.next_change_cursor`. An empty
    /// string starts at the beginning of the durable source.
    public var changesSince: String?
    public var changeLimit: Int?
    public var expandEventID: String?
    public var expandOffset: Int?
    public var expandLimit: Int?

    public init(
        changesSince: String? = nil,
        changeLimit: Int? = nil,
        expandEventID: String? = nil,
        expandOffset: Int? = nil,
        expandLimit: Int? = nil
    ) {
        self.changesSince = changesSince
        self.changeLimit = changeLimit
        self.expandEventID = expandEventID
        self.expandOffset = expandOffset
        self.expandLimit = expandLimit
    }

    public static let none = ConduitSessionEventReadOptions()

    /// The change feed reads the durable log; the timeline may not.
    public var needsDurableRevisions: Bool { changesSince != nil }
}

/// Which source served the timeline in this response.
public enum ConduitSessionTimelineSourceKind: String, Codable, Equatable, Sendable {
    /// In-memory events of the live runtime; may be ahead of the durable log.
    case liveRuntime = "live_runtime"
    /// Events the app loaded earlier from the durable log.
    case cachedHistory = "cached_history"
    /// The durable log, read for this request.
    case durableLog = "durable_log"
}

public struct ConduitSessionTimelineSource: Equatable, Sendable {
    public var kind: ConduitSessionTimelineSourceKind
    /// Coverage of the durable log when it was read for this request. Nil
    /// when the timeline came from memory and no durable read happened.
    public var durableCoverage: ConversationSourceCoverage?
    public var rejectedRecordCount: Int?

    public init(
        kind: ConduitSessionTimelineSourceKind,
        durableCoverage: ConversationSourceCoverage? = nil,
        rejectedRecordCount: Int? = nil
    ) {
        self.kind = kind
        self.durableCoverage = durableCoverage
        self.rejectedRecordCount = rejectedRecordCount
    }

    public func jsonObject() -> [String: Any] {
        var payload: [String: Any] = ["kind": kind.rawValue]
        if let durableCoverage {
            payload["durable_coverage"] = durableCoverage.rawValue
        }
        if let rejectedRecordCount {
            payload["rejected_record_count"] = rejectedRecordCount
        }
        return payload
    }
}

/// One changed event in a change-feed page: the event's value as of the last
/// revision the page covers, with its presentation and revision identities.
public struct ConduitSessionChangeRecord: Equatable, Sendable {
    public var event: ConduitSessionEventRecord
    /// Presentation position (`v1:` timeline cursor); fixed by first appearance.
    public var timelineCursor: String
    public var revisionSequence: Int
    public var eventRevision: Int
    /// True when the event's first valid revision lies inside this page.
    public var firstSeenInPage: Bool
    public var recordedAt: Date

    public func jsonObject() -> [String: Any] {
        var payload = event.jsonObject()
        payload["timeline_cursor"] = timelineCursor
        payload["revision_sequence"] = revisionSequence
        payload["event_revision"] = eventRevision
        payload["first_seen_in_page"] = firstSeenInPage
        payload["recorded_at"] = ConduitSessionEventExport.iso8601(recordedAt)
        return payload
    }
}

public struct ConduitSessionChangeFeed: Equatable, Sendable {
    public static let defaultLimit = 20
    public static let maxLimit = 50
    public static let authorityNote =
        "durable Conduit conversation revisions in write order; not provider history, not verification. Apply a page, then store next_change_cursor."

    public var since: String
    public var state: ConversationRevisionWindowState
    public var reconcileReason: ConversationRevisionReconcileReason?
    public var records: [ConduitSessionChangeRecord]
    public var nextChangeCursor: String?
    public var headChangeCursor: String?
    public var hasMoreChanges: Bool
    public var coverage: ConversationSourceCoverage
    public var appliedRevisionCount: Int
    public var rejectedRecordsInPage: Int
    public var rejectedKindsInPage: [String]
    public var unterminatedTailBytes: Int

    public func jsonObject() -> [String: Any] {
        var payload: [String: Any] = [
            "since": since,
            "state": state.rawValue,
            "records": records.map { $0.jsonObject() },
            "has_more_changes": hasMoreChanges,
            "source": [
                "kind": ConduitSessionTimelineSourceKind.durableLog.rawValue,
                "coverage": coverage.rawValue,
                "applied_revisions": appliedRevisionCount,
                "rejected_records_in_page": rejectedRecordsInPage,
                "rejected_kinds_in_page": rejectedKindsInPage,
                "unterminated_tail_bytes": unterminatedTailBytes,
            ] as [String: Any],
            "authority": Self.authorityNote,
        ]
        if let reconcileReason {
            payload["reconcile_reason"] = reconcileReason.rawValue
        }
        if let nextChangeCursor { payload["next_change_cursor"] = nextChangeCursor }
        if let headChangeCursor { payload["head_change_cursor"] = headChangeCursor }
        return payload
    }
}

public enum ConduitSessionTextExpansionState: String, Codable, Equatable, Sendable {
    case ok
    case notFound = "not_found"
    case invalidOffset = "invalid_offset"
}

/// A bounded slice of one event's complete redacted text.
///
/// Offsets count Characters (extended grapheme clusters) of the redacted
/// text, so a slice never splits a user-perceived character. Concatenating
/// slices from offset 0 until `complete` yields text whose SHA-256 equals
/// `full_text_sha256`; a different digest than the page record carried means
/// the event was revised in between.
public struct ConduitSessionTextExpansion: Equatable, Sendable {
    public static let defaultLimit = 8_000
    public static let maxLimit = 32_000

    public var eventID: String
    public var state: ConduitSessionTextExpansionState
    public var offset: Int
    public var nextOffset: Int?
    public var complete: Bool
    public var text: String?
    public var totalCharacters: Int?
    public var fullTextSHA256: String?
    public var sourceTruncated: Bool
    public var redacted: Bool
    public var timelineSource: ConduitSessionTimelineSourceKind?

    public func jsonObject() -> [String: Any] {
        var payload: [String: Any] = [
            "event_id": eventID,
            "state": state.rawValue,
            "offset": offset,
            "complete": complete,
            "source_truncated": sourceTruncated,
            "redacted": redacted,
        ]
        if let nextOffset { payload["next_offset"] = nextOffset }
        if let text { payload["text"] = text }
        if let totalCharacters { payload["total_characters"] = totalCharacters }
        if let fullTextSHA256 { payload["full_text_sha256"] = fullTextSHA256 }
        if let timelineSource { payload["timeline_source"] = timelineSource.rawValue }
        return payload
    }
}

extension ConduitSessionEventExport {
    public static func clampChangeLimit(_ limit: Int?) -> Int {
        guard let limit, limit >= 1 else { return ConduitSessionChangeFeed.defaultLimit }
        return min(limit, ConduitSessionChangeFeed.maxLimit)
    }

    public static func clampExpansionLimit(_ limit: Int?) -> Int {
        guard let limit, limit >= 1 else { return ConduitSessionTextExpansion.defaultLimit }
        return min(limit, ConduitSessionTextExpansion.maxLimit)
    }

    /// Change-feed page over the durable conversation log only.
    ///
    /// Revisions to earlier events appear here even though their timeline
    /// cursor is behind a reader's `next_cursor`. Several revisions of one
    /// event inside a page coalesce to its value at the last of them.
    /// Missing durable input reports `unavailable`; it never falls back to
    /// in-memory state, whose revisions carry no durable sequence.
    public static func changeFeed(
        source: ConduitSessionEventSource,
        since: String,
        limit: Int?,
        textLimit: Int = ConduitSessionEventPage.defaultTextLimit
    ) -> ConduitSessionChangeFeed {
        let trimmed = since.trimmingCharacters(in: .whitespacesAndNewlines)
        func refusal(
            _ state: ConversationRevisionWindowState,
            coverage: ConversationSourceCoverage
        ) -> ConduitSessionChangeFeed {
            ConduitSessionChangeFeed(
                since: since,
                state: state,
                reconcileReason: nil,
                records: [],
                nextChangeCursor: nil,
                headChangeCursor: nil,
                hasMoreChanges: false,
                coverage: coverage,
                appliedRevisionCount: 0,
                rejectedRecordsInPage: 0,
                rejectedKindsInPage: [],
                unterminatedTailBytes: 0
            )
        }

        guard let durable = source.durableRevisions else {
            return refusal(.unavailable, coverage: .unreadable)
        }
        let cursor: ConversationRevisionCursor
        if trimmed.isEmpty {
            cursor = .origin
        } else if let parsed = ConversationRevisionCursor.parse(trimmed) {
            cursor = parsed
        } else {
            return refusal(.invalid, coverage: durable.coverage)
        }

        let window = ConversationRevisionWindow.select(
            from: durable,
            after: cursor,
            limit: clampChangeLimit(limit)
        )

        // Coalesce: one record per event, valued at its last revision here,
        // ordered by that revision's sequence.
        var lastRevisionByEvent: [UUID: ConversationEventRevision] = [:]
        var firstSeenEvents = Set<UUID>()
        for revision in window.revisions {
            lastRevisionByEvent[revision.eventID] = revision
            if revision.eventRevision == 1 {
                firstSeenEvents.insert(revision.eventID)
            }
        }
        let records = lastRevisionByEvent.values
            .sorted { $0.sequence < $1.sequence }
            .compactMap { revision -> ConduitSessionChangeRecord? in
                guard let value = window.values[revision.eventID] else {
                    return nil
                }
                return ConduitSessionChangeRecord(
                    event: record(
                        event: value,
                        index: revision.timelineIndex,
                        source: source,
                        textLimit: textLimit
                    ),
                    timelineCursor: encodeCursor(revision.timelineIndex),
                    revisionSequence: revision.sequence,
                    eventRevision: revision.eventRevision,
                    firstSeenInPage: firstSeenEvents.contains(revision.eventID),
                    recordedAt: revision.recordedAt
                )
            }
        let rejectedKinds = Array(
            Set(window.rejectedRecordsInRange.map(\.kind.rawValue))
        ).sorted()

        return ConduitSessionChangeFeed(
            since: since,
            state: window.state,
            reconcileReason: window.reconcileReason,
            records: records,
            nextChangeCursor: window.nextCursor?.encoded,
            headChangeCursor: window.headCursor?.encoded,
            hasMoreChanges: window.hasMore,
            coverage: window.coverage,
            appliedRevisionCount: durable.deliverableRevisions.count,
            rejectedRecordsInPage: window.rejectedRecordsInRange.count,
            rejectedKindsInPage: rejectedKinds,
            unterminatedTailBytes: window.unterminatedTailBytes
        )
    }

    /// Exact bounded slice of one event's redacted text from the timeline
    /// source. Only text Conduit retained can be expanded.
    public static func expand(
        source: ConduitSessionEventSource,
        eventID rawEventID: String,
        offset rawOffset: Int?,
        limit: Int?
    ) -> ConduitSessionTextExpansion {
        let offset = rawOffset ?? 0
        let kind = source.timelineSource?.kind
        func failure(_ state: ConduitSessionTextExpansionState) -> ConduitSessionTextExpansion {
            ConduitSessionTextExpansion(
                eventID: rawEventID,
                state: state,
                offset: offset,
                nextOffset: nil,
                complete: false,
                text: nil,
                totalCharacters: nil,
                fullTextSHA256: nil,
                sourceTruncated: false,
                redacted: false,
                timelineSource: kind
            )
        }

        guard let uuid = UUID(uuidString: rawEventID),
              let index = source.events.firstIndex(where: { $0.id == uuid })
        else {
            return failure(.notFound)
        }
        // Reuse the record builder for kind-specific text so expansion and
        // the page agree on what an event's text is.
        let event = source.events[index]
        let retained: (text: String, sourceTruncated: Bool)
        switch event.kind {
        case .userPrompt(let prompt):
            retained = (prompt.text, false)
        case .agentOutput(let output):
            retained = (output.text, output.truncated)
        case .sessionOpened, .interruptRequested:
            let full = record(
                event: event,
                index: index,
                source: source,
                textLimit: Int.max
            )
            retained = (full.text ?? "", false)
        }
        let redaction = redactText(retained.text)
        let characters = Array(redaction.text)
        guard offset >= 0, offset <= characters.count else {
            return failure(.invalidOffset)
        }
        let end = min(characters.count, offset + clampExpansionLimit(limit))
        let complete = end == characters.count
        return ConduitSessionTextExpansion(
            eventID: rawEventID,
            state: .ok,
            offset: offset,
            nextOffset: complete ? nil : end,
            complete: complete,
            text: String(characters[offset..<end]),
            totalCharacters: characters.count,
            fullTextSHA256: sha256Hex(redaction.text),
            sourceTruncated: retained.sourceTruncated,
            redacted: redaction.redacted,
            timelineSource: kind
        )
    }
}

/// Reference consumer of the change feed.
///
/// It applies a page only when the page was read from the replica's current
/// cursor, and advances that cursor only after applying the page. A page from
/// a cancelled or superseded reader therefore cannot overwrite newer state or
/// move the cursor past what was applied.
public struct ConduitSessionChangeReplica: Equatable, Sendable {
    public enum ApplyResult: Equatable, Sendable {
        case applied(records: Int)
        case staleSince(expected: String, received: String)
        case notApplicable(ConversationRevisionWindowState)
    }

    public private(set) var cursor: String
    public private(set) var eventsByID: [String: ConduitSessionChangeRecord] = [:]

    public init(cursor: String = "") {
        self.cursor = cursor
    }

    /// Current values ordered by presentation position.
    public var timeline: [ConduitSessionChangeRecord] {
        eventsByID.values.sorted {
            ConduitSessionEventExport.parseCursor($0.timelineCursor).index
                < ConduitSessionEventExport.parseCursor($1.timelineCursor).index
        }
    }

    public mutating func apply(_ page: ConduitSessionChangeFeed) -> ApplyResult {
        guard page.since == cursor else {
            return .staleSince(expected: cursor, received: page.since)
        }
        guard page.state == .ok, let next = page.nextChangeCursor else {
            return .notApplicable(page.state)
        }
        for record in page.records {
            if let existing = eventsByID[record.event.eventID],
               existing.revisionSequence > record.revisionSequence {
                continue
            }
            eventsByID[record.event.eventID] = record
        }
        cursor = next
        return .applied(records: page.records.count)
    }
}
