import CryptoKit
import Foundation

/// Declared decoded input, not an authenticated source or a new event writer.
public struct TaskSupervisorySourceSnapshot: Equatable, Sendable {
    public let taskSessionID: TaskSessionID
    public let events: [TaskSessionEvent]
    /// A sorted set of kinds, not diagnostic occurrence counts or source positions.
    public let readDiagnosticKinds: [TaskSessionEventLogDiagnosticKind]

    public init(taskSessionID: TaskSessionID, readResult: TaskSessionEventLogReadResult) {
        self.taskSessionID = taskSessionID
        self.events = readResult.events
        self.readDiagnosticKinds = readResult.diagnostics.reduce(into: Set<TaskSessionEventLogDiagnosticKind>()) { kinds, diagnostic in
            kinds.insert(diagnostic.kind)
        }.sorted { $0.rawValue < $1.rawValue }
    }
}

public struct TaskSupervisoryStoreSnapshot: Equatable, Sendable {
    /// Caller-configured logical namespace. This UUID does not authenticate a directory.
    public let storeID: UUID
    public let sources: [TaskSupervisorySourceSnapshot]

    public init(storeID: UUID, sources: [TaskSupervisorySourceSnapshot]) {
        self.storeID = storeID
        self.sources = sources
    }
}

/// Event UUIDs are per-task identities, so the global reference is compound.
public struct TaskSupervisoryEventID: Codable, Equatable, Hashable, Sendable {
    public let taskSessionID: TaskSessionID
    public let sourceEventID: UUID
}

public enum TaskSupervisoryEventKind: Codable, Equatable, Sendable {
    case taskCreated
    case runtimeProvisioning
    case runtimeOpened
    case runtimeProvisioningFailed(recoverable: Bool)
    case runtimeDetached
    case taskClosed(TaskSessionCloseReason)
    case interruptObserved
    case conversationActivityRecorded
    case conversationRetentionEnabled
    case shellTelemetryRecorded(ShellTelemetryPhase)
    case shellProcessObservationRecorded
}

public struct TaskSupervisoryEvent: Identifiable, Codable, Equatable, Sendable {
    public let id: TaskSupervisoryEventID
    /// Position in the supplied decoded source, before duplicate or metadata filtering.
    public let sourceOrdinal: Int
    /// Internally computed identity of all typed decoded fields, not raw file bytes.
    public let decodedSourceDigest: String
    public let occurredAt: Date
    public let recordedAt: Date
    public let sourceAuthority: TaskSessionEventAuthority
    public let runtimeAttemptID: OrchestrationValue<RuntimeAttemptID>
    public let kind: TaskSupervisoryEventKind
}

public enum TaskSupervisoryUnsupportedFact: String, Codable, Equatable, Sendable, CaseIterable {
    case sourceAuthenticity
    case providerSessionIdentity
    case providerTurnIdentity
    case providerProgress
    case workspaceIdentity
    case approvalAuthority
    case verification
    case acceptance
    case currentNativeState
    case globalAppendTime
    case totalChronologicalOrder
}

public struct TaskSupervisoryPage: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let policyVersion: String
    public let storeID: UUID
    public let events: [TaskSupervisoryEvent]
    public let nextCursor: String
    public let hasMore: Bool
    public let unsupportedFacts: [TaskSupervisoryUnsupportedFact]
}

public enum TaskSupervisoryPageStatus: String, Codable, Equatable, Sendable {
    case ready
    case invalidInput
    case invalidCursor
    case reconciliationRequired
    case limitExceeded
}

public enum TaskSupervisoryRejectionReason: String, Codable, Equatable, Sendable {
    case sourceCount
    case sourceEventCount
    case totalEventCount
    case sourceRecordBytes
    case totalSourceBytes
    case cursorBytes
    case duplicateTaskSource
    case readDiagnostics
    case mismatchedTaskSessionID
    case unsupportedEventSchema
    case invalidAuthority
    case nonfiniteDate
    case unencodableSource
    case missingCreation
    case duplicateCreation
    case conflictingEventID
    case malformedCursor
    case cursorVersion
    case cursorStore
    case duplicateCursorSource
    case cursorPosition
    case cursorAnchor
    case sourceRemoved
    case sourcePrefixChanged
}

public struct TaskSupervisoryIssue: Codable, Equatable, Sendable {
    public let reason: TaskSupervisoryRejectionReason
    public let taskSessionID: TaskSessionID?
    /// Distinct sorted kinds only: source counts, details and paths never enter the export.
    public let readDiagnosticKinds: [TaskSessionEventLogDiagnosticKind]
}

public struct TaskSupervisoryPageResult: Codable, Equatable, Sendable {
    public let status: TaskSupervisoryPageStatus
    public let page: TaskSupervisoryPage?
    public let issues: [TaskSupervisoryIssue]
}

/// Pure, reconciliation-safe global projection over the existing per-task authority.
///
/// This API never reads, appends, heals or authenticates a source. Inputs are
/// already allocated decoded snapshots. The cursor is an untrusted query
/// position, not proof that a client consumed a page and not execution authority.
public enum TaskSupervisoryHistory {
    public static let schemaVersion = 1
    public static let policyVersion = "task-metadata-supervisory-v1"
    public static let maximumSources = 128
    public static let maximumEventsPerSource = 4_096
    public static let maximumTotalEvents = 8_192
    public static let maximumSourceRecordBytes = 65_536
    public static let maximumTotalSourceBytes = 8_388_608
    public static let maximumCursorBytes = 65_536
    public static let defaultLimit = 20
    public static let maximumLimit = 50

    private struct CursorEntry: Codable, Equatable {
        let taskSessionID: TaskSessionID
        let consumedCount: Int
        let observedSourceCount: Int
        let observedPrefixDigest: String
    }

    private struct Cursor: Codable, Equatable {
        let schemaVersion: Int
        let policyVersion: String
        let storeID: UUID
        let sources: [CursorEntry]
        let lastEmittedTask: TaskSessionID?
    }

    private struct PreparedSource {
        let taskSessionID: TaskSessionID
        let count: Int
        let prefixDigests: [String]
        let records: [TaskSupervisoryEvent]
    }

    private struct Rejection: Error {
        let status: TaskSupervisoryPageStatus
        let issue: TaskSupervisoryIssue
    }

    public static func page(
        snapshot: TaskSupervisoryStoreSnapshot,
        cursor rawCursor: String? = nil,
        limit: Int? = nil
    ) -> TaskSupervisoryPageResult {
        do {
            let sources = try prepare(snapshot.sources)
            let cursor = try rawCursor.map(decodeCursor)
            var consumed: [TaskSessionID: Int] = [:]
            var lastEmittedTask: TaskSessionID?
            if let cursor {
                try validate(cursor, snapshot: snapshot, sources: sources)
                consumed = Dictionary(uniqueKeysWithValues: cursor.sources.map {
                    ($0.taskSessionID, $0.consumedCount)
                })
                lastEmittedTask = cursor.lastEmittedTask
            }
            for source in sources where consumed[source.taskSessionID] == nil {
                consumed[source.taskSessionID] = 0
            }

            let pageLimit = limit.map { $0 < 1 ? defaultLimit : min($0, maximumLimit) }
                ?? defaultLimit
            let order: [PreparedSource]
            if let lastEmittedTask,
               let index = sources.firstIndex(where: { $0.taskSessionID == lastEmittedTask }) {
                order = Array(sources.dropFirst(index + 1)) + Array(sources.prefix(index + 1))
            } else {
                order = sources
            }
            var events: [TaskSupervisoryEvent] = []
            while events.count < pageLimit {
                var advanced = false
                for source in order {
                    guard events.count < pageLimit else { break }
                    let next = source.records.first {
                        $0.sourceOrdinal >= consumed[source.taskSessionID, default: 0]
                    }
                    if let next {
                        events.append(next)
                        consumed[source.taskSessionID] = next.sourceOrdinal + 1
                        lastEmittedTask = source.taskSessionID
                        advanced = true
                    } else {
                        consumed[source.taskSessionID] = source.count
                    }
                }
                if !advanced { break }
            }
            let hasMore = sources.contains { source in
                source.records.contains {
                    $0.sourceOrdinal >= consumed[source.taskSessionID, default: 0]
                }
            }
            // Non-exported metadata and exact duplicate tails are consumed too.
            for source in sources where !source.records.contains(where: {
                $0.sourceOrdinal >= consumed[source.taskSessionID, default: 0]
            }) {
                consumed[source.taskSessionID] = source.count
            }
            let next = Cursor(
                schemaVersion: schemaVersion,
                policyVersion: policyVersion,
                storeID: snapshot.storeID,
                sources: sources.map {
                    CursorEntry(
                        taskSessionID: $0.taskSessionID,
                        consumedCount: consumed[$0.taskSessionID, default: 0],
                        observedSourceCount: $0.count,
                        observedPrefixDigest: $0.prefixDigests[$0.count]
                    )
                },
                lastEmittedTask: lastEmittedTask
            )
            let encoded = try encodeCursor(next)
            return TaskSupervisoryPageResult(
                status: .ready,
                page: TaskSupervisoryPage(
                    schemaVersion: schemaVersion,
                    policyVersion: policyVersion,
                    storeID: snapshot.storeID,
                    events: events,
                    nextCursor: encoded,
                    hasMore: hasMore,
                    unsupportedFacts: TaskSupervisoryUnsupportedFact.allCases
                ),
                issues: []
            )
        } catch let error as Rejection {
            return TaskSupervisoryPageResult(status: error.status, page: nil, issues: [error.issue])
        } catch {
            return failure(.invalidInput, .unencodableSource)
        }
    }

    /// Deterministic native bytes. Dates use exact finite reference-time bits;
    /// this is a Core identity encoding, not a human date-display format.
    public static func canonicalData(_ result: TaskSupervisoryPageResult) throws -> Data {
        try makeEncoder().encode(result)
    }

    public static func decodeCanonicalData(_ data: Data) throws -> TaskSupervisoryPageResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard raw.hasPrefix("f64:"), raw.utf8.count == 20,
                  let bits = UInt64(raw.dropFirst(4), radix: 16),
                  Double(bitPattern: bits).isFinite else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid finite date identity.")
            }
            return Date(timeIntervalSinceReferenceDate: Double(bitPattern: bits))
        }
        let value = try decoder.decode(TaskSupervisoryPageResult.self, from: data)
        guard try canonicalData(value) == data else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Noncanonical supervisory result."))
        }
        return value
    }

    private static func prepare(_ snapshots: [TaskSupervisorySourceSnapshot]) throws -> [PreparedSource] {
        guard snapshots.count <= maximumSources else { throw reject(.limitExceeded, .sourceCount) }
        var totalCount = 0
        var totalBytes = 0
        var seenTasks = Set<TaskSessionID>()
        var prepared: [PreparedSource] = []
        for snapshot in snapshots.sorted(by: { key($0.taskSessionID) < key($1.taskSessionID) }) {
            let task = snapshot.taskSessionID
            guard seenTasks.insert(task).inserted else { throw reject(.invalidInput, .duplicateTaskSource, task) }
            guard snapshot.readDiagnosticKinds.isEmpty else {
                throw Rejection(
                    status: .reconciliationRequired,
                    issue: TaskSupervisoryIssue(reason: .readDiagnostics, taskSessionID: task,
                        readDiagnosticKinds: snapshot.readDiagnosticKinds)
                )
            }
            guard snapshot.events.count <= maximumEventsPerSource else { throw reject(.limitExceeded, .sourceEventCount, task) }
            totalCount += snapshot.events.count
            guard totalCount <= maximumTotalEvents else { throw reject(.limitExceeded, .totalEventCount) }
            var seenEvents: [UUID: String] = [:]
            var creationSeen = false
            var records: [TaskSupervisoryEvent] = []
            var prefix = SHA256()
            prefix.update(data: Data("conduit-task-supervisory-prefix-v1:\(key(task))\n".utf8))
            var prefixDigests = [hex(prefix.finalize())]
            for (ordinal, event) in snapshot.events.enumerated() {
                guard event.taskSessionID == task else { throw reject(.invalidInput, .mismatchedTaskSessionID, task) }
                guard event.schemaVersion == TaskSessionEvent.currentSchemaVersion else { throw reject(.invalidInput, .unsupportedEventSchema, task) }
                guard event.hasValidAuthority else { throw reject(.invalidInput, .invalidAuthority, task) }
                guard event.occurredAt.timeIntervalSinceReferenceDate.isFinite,
                      event.recordedAt.timeIntervalSinceReferenceDate.isFinite else { throw reject(.invalidInput, .nonfiniteDate, task) }
                let data = try makeEncoder().encode(event)
                guard data.count <= maximumSourceRecordBytes else { throw reject(.limitExceeded, .sourceRecordBytes, task) }
                totalBytes += data.count
                guard totalBytes <= maximumTotalSourceBytes else { throw reject(.limitExceeded, .totalSourceBytes) }
                let digest = hex(SHA256.hash(data: data))
                prefix.update(data: data)
                prefix.update(data: Data([10]))
                prefixDigests.append(hex(prefix.finalize()))
                if let original = seenEvents[event.id] {
                    guard original == digest else { throw reject(.reconciliationRequired, .conflictingEventID, task) }
                    continue
                }
                seenEvents[event.id] = digest
                if !creationSeen {
                    guard case .created = event.kind else { throw reject(.invalidInput, .missingCreation, task) }
                    creationSeen = true
                } else if case .created = event.kind {
                    throw reject(.reconciliationRequired, .duplicateCreation, task)
                }
                if let projection = project(event) {
                    records.append(TaskSupervisoryEvent(
                        id: TaskSupervisoryEventID(taskSessionID: task, sourceEventID: event.id),
                        sourceOrdinal: ordinal,
                        decodedSourceDigest: digest,
                        occurredAt: event.occurredAt,
                        recordedAt: event.recordedAt,
                        sourceAuthority: event.authority,
                        runtimeAttemptID: projection.attempt,
                        kind: projection.kind
                    ))
                }
            }
            guard creationSeen else { throw reject(.invalidInput, .missingCreation, task) }
            prepared.append(PreparedSource(taskSessionID: task, count: snapshot.events.count,
                prefixDigests: prefixDigests, records: records))
        }
        return prepared
    }

    private static func project(_ event: TaskSessionEvent) -> (kind: TaskSupervisoryEventKind, attempt: OrchestrationValue<RuntimeAttemptID>)? {
        switch event.kind {
        case .created: return (.taskCreated, .unknown)
        case .titleOverridden, .titleReset, .pinChanged, .archiveChanged: return nil
        case .conversationActivityRecorded: return (.conversationActivityRecorded, .unknown)
        case .conversationRetentionEnabled: return (.conversationRetentionEnabled, .unknown)
        case .shellTelemetryRecorded(let telemetry):
            let attempt = UUID(uuidString: telemetry.runtimeAttemptID).map { RuntimeAttemptID(rawValue: $0) }
            return (.shellTelemetryRecorded(telemetry.phase), attempt.map(OrchestrationValue.known) ?? .unknown)
        case .shellProcessObservationRecorded(let observation):
            let attempt = observation.runtimeAttemptID.value.flatMap(UUID.init(uuidString:)).map { RuntimeAttemptID(rawValue: $0) }
            return (.shellProcessObservationRecorded, attempt.map(OrchestrationValue.known) ?? .unknown)
        case .operationalStateChanged(let state):
            switch state {
            case .runtimeProvisioning(let attempt, _, _): return (.runtimeProvisioning, .known(attempt))
            case .runtimeOpened(let attempt): return (.runtimeOpened, .known(attempt))
            case .runtimeProvisioningFailed(let attempt, _, _, let recoverable): return (.runtimeProvisioningFailed(recoverable: recoverable), .known(attempt))
            case .runtimeDetached(let attempt): return (.runtimeDetached, .known(attempt))
            case .closed(let reason): return (.taskClosed(reason), .unknown)
            case .interrupted(let attempt): return (.interruptObserved, attempt.map(OrchestrationValue.known) ?? .unknown)
            }
        }
    }

    private static func validate(_ cursor: Cursor, snapshot: TaskSupervisoryStoreSnapshot, sources: [PreparedSource]) throws {
        guard cursor.schemaVersion == schemaVersion, cursor.policyVersion == policyVersion else { throw reject(.invalidCursor, .cursorVersion) }
        guard cursor.storeID == snapshot.storeID else { throw reject(.invalidCursor, .cursorStore) }
        guard cursor.sources.count <= maximumSources else { throw reject(.limitExceeded, .sourceCount) }
        let available = Dictionary(uniqueKeysWithValues: sources.map { ($0.taskSessionID, $0) })
        var seen = Set<TaskSessionID>()
        var priorKey: String?
        for entry in cursor.sources {
            guard seen.insert(entry.taskSessionID).inserted else { throw reject(.invalidCursor, .duplicateCursorSource, entry.taskSessionID) }
            let currentKey = key(entry.taskSessionID)
            guard priorKey.map({ $0 < currentKey }) ?? true else { throw reject(.invalidCursor, .malformedCursor) }
            priorKey = currentKey
            guard entry.consumedCount >= 0, entry.consumedCount <= entry.observedSourceCount,
                  entry.observedSourceCount >= 0, entry.observedSourceCount <= maximumEventsPerSource,
                  entry.observedPrefixDigest.count == 64,
                  entry.observedPrefixDigest.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw reject(.invalidCursor, .cursorPosition, entry.taskSessionID) }
            guard let source = available[entry.taskSessionID] else { throw reject(.reconciliationRequired, .sourceRemoved, entry.taskSessionID) }
            guard source.count >= entry.observedSourceCount,
                  source.prefixDigests[entry.observedSourceCount] == entry.observedPrefixDigest else { throw reject(.reconciliationRequired, .sourcePrefixChanged, entry.taskSessionID) }
        }
        if let anchor = cursor.lastEmittedTask, !seen.contains(anchor) { throw reject(.invalidCursor, .cursorAnchor, anchor) }
    }

    private static func decodeCursor(_ raw: String) throws -> Cursor {
        guard raw.utf8.count <= maximumCursorBytes else { throw reject(.limitExceeded, .cursorBytes) }
        guard raw.hasPrefix("gsv1:") else { throw reject(.invalidCursor, .malformedCursor) }
        let encoded = String(raw.dropFirst(5))
        guard !encoded.isEmpty, encoded.allSatisfy({ $0.isASCII && ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".contains($0)) }) else { throw reject(.invalidCursor, .malformedCursor) }
        var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let cursor = try? JSONDecoder().decode(Cursor.self, from: data),
              let canonical = try? encodeCursor(cursor), canonical == raw else { throw reject(.invalidCursor, .malformedCursor) }
        return cursor
    }

    private static func encodeCursor(_ cursor: Cursor) throws -> String {
        let data = try makeEncoder().encode(cursor)
        let raw = "gsv1:" + data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        guard raw.utf8.count <= maximumCursorBytes else { throw reject(.limitExceeded, .cursorBytes) }
        return raw
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            guard date.timeIntervalSinceReferenceDate.isFinite else {
                throw EncodingError.invalidValue(date, .init(codingPath: encoder.codingPath, debugDescription: "Nonfinite date identity."))
            }
            var container = encoder.singleValueContainer()
            let digits = String(date.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
            try container.encode("f64:" + String(repeating: "0", count: 16 - digits.count) + digits)
        }
        return encoder
    }

    private static func key(_ id: TaskSessionID) -> String { id.rawValue.uuidString.lowercased() }
    private static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
    private static func reject(_ status: TaskSupervisoryPageStatus, _ reason: TaskSupervisoryRejectionReason, _ task: TaskSessionID? = nil) -> Rejection {
        Rejection(status: status, issue: TaskSupervisoryIssue(reason: reason, taskSessionID: task, readDiagnosticKinds: []))
    }
    private static func failure(_ status: TaskSupervisoryPageStatus, _ reason: TaskSupervisoryRejectionReason) -> TaskSupervisoryPageResult {
        let rejection = reject(status, reason)
        return TaskSupervisoryPageResult(status: status, page: nil, issues: [rejection.issue])
    }
}
