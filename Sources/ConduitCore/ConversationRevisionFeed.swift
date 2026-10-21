import CryptoKit
import Foundation

/// What one durable conversation source could supply at read time.
///
/// `missing` means no log exists for the task; `empty` means a log exists with
/// no records. `partial` means at least one record was rejected (torn,
/// malformed, wrong task, invalid authority or invalid revision), so the
/// projection may lack information the writer intended. `unreadable` means the
/// source could not be opened or read at all. None of these is a statement
/// about provider history outside Conduit's retained log.
public enum ConversationSourceCoverage: String, Codable, Equatable, Sendable {
    case complete
    case partial
    case empty
    case missing
    case unreadable
}

/// One applied revision record in a conversation source.
///
/// `sequence` orders applied records within this source generation and is
/// stable under append-only operation. `timelineIndex` is the event's display
/// position, fixed by its first valid appearance; later revisions keep it.
/// `recordedAt` is when Conduit wrote this revision, not when the provider
/// produced it. Revisions carry identity only: a streamed output can have
/// thousands, and holding each reconstructed value would grow quadratically.
public struct ConversationEventRevision: Equatable, Sendable {
    public let sequence: Int
    public let lineNumber: Int
    public let byteRange: Range<Int>
    public let newlineTerminated: Bool
    public let timelineIndex: Int
    public let eventRevision: Int
    public let recordedAt: Date
    public let eventID: UUID

    public init(
        sequence: Int,
        lineNumber: Int,
        byteRange: Range<Int>,
        newlineTerminated: Bool,
        timelineIndex: Int,
        eventRevision: Int,
        recordedAt: Date,
        eventID: UUID
    ) {
        self.sequence = sequence
        self.lineNumber = lineNumber
        self.byteRange = byteRange
        self.newlineTerminated = newlineTerminated
        self.timelineIndex = timelineIndex
        self.eventRevision = eventRevision
        self.recordedAt = recordedAt
        self.eventID = eventID
    }
}

public struct ConversationRevisionReadResult: Equatable, Sendable {
    public let coverage: ConversationSourceCoverage
    /// Bytes through the end of the last newline-terminated line.
    public let completePrefixBytes: Int
    public let sourceBytes: Int
    public let revisions: [ConversationEventRevision]
    /// Identical to `ConversationEventLog.read().events` for the same bytes.
    public let events: [SessionPresentationEvent]
    public let diagnostics: [ConversationEventLogDiagnostic]
    private let data: Data
    private let taskSessionID: TaskSessionID
    private let url: URL

    public init(
        taskSessionID: TaskSessionID,
        url: URL,
        coverage: ConversationSourceCoverage,
        data: Data,
        completePrefixBytes: Int,
        revisions: [ConversationEventRevision],
        events: [SessionPresentationEvent],
        diagnostics: [ConversationEventLogDiagnostic]
    ) {
        self.taskSessionID = taskSessionID
        self.url = url
        self.coverage = coverage
        self.data = data
        self.sourceBytes = data.count
        self.completePrefixBytes = min(max(0, completePrefixBytes), data.count)
        self.revisions = revisions
        self.events = events
        self.diagnostics = diagnostics
    }

    /// Applied records wholly inside the complete prefix. A trailing record
    /// without its newline is projected by `events` but is not yet part of
    /// the prefix a cursor can bind, so the change feed does not deliver it.
    public var deliverableRevisions: [ConversationEventRevision] {
        revisions.filter { $0.newlineTerminated && $0.byteRange.upperBound < completePrefixBytes }
    }

    /// Latest valid value of each event as of the first `byteCount` bytes,
    /// using the same validation as `ConversationEventLog.read()`.
    public func projection(throughByte byteCount: Int) -> [UUID: SessionPresentationEvent] {
        if byteCount >= sourceBytes {
            return Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        }
        return ConversationEventLog.replay(
            data.prefix(max(0, byteCount)),
            taskSessionID: taskSessionID,
            url: url,
            collectRevisions: false
        ).latestEvents
    }

    /// SHA-256 over the first `byteCount` source bytes, or nil when the
    /// source is shorter than that.
    public func prefixDigest(byteCount: Int) -> String? {
        guard byteCount >= 0, byteCount <= data.count else { return nil }
        let prefix = data.prefix(byteCount)
        return SHA256.hash(data: prefix)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Rejected-record diagnostics for lines that start inside
    /// `byteRange`. Diagnostics without a line (an unreadable source) are
    /// always included.
    public func diagnostics(startingIn byteRange: Range<Int>) -> [ConversationEventLogDiagnostic] {
        guard diagnostics.contains(where: { $0.lineNumber != nil }) else {
            return diagnostics
        }
        // Line k (1-based) starts after the (k-1)th newline.
        var lineStarts = [0]
        for (offset, byte) in data.enumerated() where byte == UInt8(ascii: "\n") {
            lineStarts.append(offset + 1)
        }
        return diagnostics.filter { diagnostic in
            guard let line = diagnostic.lineNumber else { return true }
            guard line >= 1, line <= lineStarts.count else { return false }
            return byteRange.contains(lineStarts[line - 1])
        }
    }

    func byte(at offset: Int) -> UInt8? {
        guard offset >= 0, offset < sourceBytes else { return nil }
        return data[data.startIndex + offset]
    }
}

/// A position in one conversation source's applied-revision sequence.
///
/// The cursor binds the exact byte prefix it covers. A reader that presents a
/// cursor whose prefix no longer matches the source (truncated, replaced or
/// rewritten) gets an explicit reconciliation result rather than a silent
/// restart. This is an untrusted query position: it proves nothing about what
/// a client applied and grants no authority.
public struct ConversationRevisionCursor: Equatable, Sendable {
    public static let prefix = "r1"

    public let sequence: Int
    public let byteOffset: Int
    public let prefixSHA256: String

    public init(sequence: Int, byteOffset: Int, prefixSHA256: String) {
        self.sequence = sequence
        self.byteOffset = byteOffset
        self.prefixSHA256 = prefixSHA256
    }

    /// The cursor for a source that has no bytes yet (missing or empty).
    public static let origin = ConversationRevisionCursor(
        sequence: 0,
        byteOffset: 0,
        prefixSHA256: SHA256.hash(data: Data())
            .map { String(format: "%02x", $0) }
            .joined()
    )

    public var encoded: String {
        "\(Self.prefix):\(sequence):\(byteOffset):\(prefixSHA256)"
    }

    /// Strict parse. Anything other than the exact canonical form is nil;
    /// callers report it as invalid instead of restarting from the beginning.
    public static func parse(_ raw: String) -> ConversationRevisionCursor? {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == Substring(prefix) else { return nil }
        guard let sequence = canonicalNonNegative(parts[1]),
              let byteOffset = canonicalNonNegative(parts[2])
        else { return nil }
        let digest = String(parts[3])
        guard digest.count == 64,
              digest.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) })
        else { return nil }
        let cursor = ConversationRevisionCursor(
            sequence: sequence,
            byteOffset: byteOffset,
            prefixSHA256: digest
        )
        guard cursor.encoded == raw else { return nil }
        return cursor
    }

    private static func canonicalNonNegative(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ ("0"..."9").contains($0) }) else {
            return nil
        }
        if text.count > 1, text.first == "0" { return nil }
        guard text.count <= 18, let value = Int(text) else { return nil }
        return value
    }
}

public enum ConversationRevisionWindowState: String, Codable, Equatable, Sendable {
    /// The cursor's prefix matches; `revisions` are the next applied records.
    case ok
    /// The cursor is not a canonical revision cursor.
    case invalid
    /// The cursor names bytes the source no longer has, or a prefix whose
    /// digest or record count differs. Recover from the origin cursor.
    case reconcileRequired = "reconcile_required"
    /// The source could not be read; the caller keeps its cursor.
    case unavailable
}

public enum ConversationRevisionReconcileReason: String, Codable, Equatable, Sendable {
    case sourceShorterThanCursor = "source_shorter_than_cursor"
    case prefixDigestChanged = "prefix_digest_changed"
    case prefixRecordCountChanged = "prefix_record_count_changed"
    case cursorNotAtRecordBoundary = "cursor_not_at_record_boundary"
}

/// Applied records after a cursor, bounded by a distinct-event budget.
///
/// `nextCursor` covers exactly the records returned, so a reader that stores
/// it only after applying them cannot skip a revision. `headCursor` covers
/// every deliverable record at read time.
public struct ConversationRevisionWindow: Equatable, Sendable {
    public let state: ConversationRevisionWindowState
    public let reconcileReason: ConversationRevisionReconcileReason?
    public let revisions: [ConversationEventRevision]
    public let nextCursor: ConversationRevisionCursor?
    public let headCursor: ConversationRevisionCursor?
    public let hasMore: Bool
    public let coverage: ConversationSourceCoverage
    public let rejectedRecordsInRange: [ConversationEventLogDiagnostic]
    public let unterminatedTailBytes: Int
    /// Values of the selected events as of the last selected revision.
    public let values: [UUID: SessionPresentationEvent]

    public static func select(
        from source: ConversationRevisionReadResult,
        after cursor: ConversationRevisionCursor,
        limit: Int
    ) -> ConversationRevisionWindow {
        let tailBytes = source.sourceBytes - source.completePrefixBytes
        guard source.coverage != .unreadable else {
            return ConversationRevisionWindow(
                state: .unavailable,
                reconcileReason: nil,
                revisions: [],
                nextCursor: nil,
                headCursor: nil,
                hasMore: false,
                coverage: source.coverage,
                rejectedRecordsInRange: source.diagnostics,
                unterminatedTailBytes: 0,
                values: [:]
            )
        }

        let deliverable = source.deliverableRevisions
        let head = ConversationRevisionCursor(
            sequence: deliverable.last?.sequence ?? 0,
            byteOffset: source.completePrefixBytes,
            prefixSHA256: source.prefixDigest(
                byteCount: source.completePrefixBytes
            ) ?? ""
        )

        func refusal(_ reason: ConversationRevisionReconcileReason) -> ConversationRevisionWindow {
            ConversationRevisionWindow(
                state: .reconcileRequired,
                reconcileReason: reason,
                revisions: [],
                nextCursor: nil,
                headCursor: head,
                hasMore: false,
                coverage: source.coverage,
                rejectedRecordsInRange: [],
                unterminatedTailBytes: tailBytes,
                values: [:]
            )
        }

        guard cursor.byteOffset <= source.completePrefixBytes else {
            return refusal(.sourceShorterThanCursor)
        }
        guard source.prefixDigest(byteCount: cursor.byteOffset) == cursor.prefixSHA256 else {
            return refusal(.prefixDigestChanged)
        }
        // Issued cursors always end just after a newline.
        if cursor.byteOffset > 0,
           source.byte(at: cursor.byteOffset - 1) != UInt8(ascii: "\n") {
            return refusal(.cursorNotAtRecordBoundary)
        }
        let consumed = deliverable.prefix { $0.byteRange.upperBound < cursor.byteOffset }
        guard consumed.count == cursor.sequence else {
            return refusal(.prefixRecordCountChanged)
        }

        // The budget counts distinct events, so a streamed output's many
        // revisions consume one slot. Selection stops before the first
        // revision that would add one event too many; nothing is skipped.
        let remaining = deliverable.dropFirst(consumed.count)
        let eventBudget = max(1, limit)
        var selectedEvents = Set<UUID>()
        var selected: [ConversationEventRevision] = []
        for revision in remaining {
            if !selectedEvents.contains(revision.eventID) {
                guard selectedEvents.count < eventBudget else { break }
                selectedEvents.insert(revision.eventID)
            }
            selected.append(revision)
        }
        let hasMore = remaining.count > selected.count
        let next: ConversationRevisionCursor
        if hasMore, let last = selected.last {
            let end = last.byteRange.upperBound + 1
            next = ConversationRevisionCursor(
                sequence: last.sequence,
                byteOffset: end,
                prefixSHA256: source.prefixDigest(byteCount: end) ?? ""
            )
        } else {
            // The final page covers through the complete prefix, including
            // rejected lines after the last applied record, so they are
            // reported once rather than on every later poll.
            next = head
        }
        return ConversationRevisionWindow(
            state: .ok,
            reconcileReason: nil,
            revisions: selected,
            nextCursor: next,
            headCursor: head,
            hasMore: hasMore,
            coverage: source.coverage,
            rejectedRecordsInRange: source.diagnostics(
                startingIn: cursor.byteOffset..<next.byteOffset
            ),
            unterminatedTailBytes: tailBytes,
            values: selected.isEmpty
                ? [:]
                : source.projection(throughByte: lastSelectedEnd(selected))
                    .filter { selectedEvents.contains($0.key) }
        )
    }

    private static func lastSelectedEnd(_ selected: [ConversationEventRevision]) -> Int {
        (selected.last?.byteRange.upperBound ?? -1) + 1
    }
}
