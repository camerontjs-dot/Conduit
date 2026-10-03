import CryptoKit
import Dispatch
import Foundation

/// Bounded, content-free diagnostics for one OpenCode client. Supplied SSE
/// snapshots are reports without sequence/freshness authority. In particular,
/// a busy report does not establish a current turn or execution-slot occupancy.
public struct OpenCodeBoundaryTrace: Sendable {
    public enum Knowledge: String, Codable, Sendable { case known, unknown }
    public struct Binding: Equatable, Codable, Sendable {
        public let taskSessionID: UUID?
        public let runtimeID: UUID
        public let runtimeAttemptID: UUID
        public let taskSessionKnowledge: Knowledge

        public init(taskSessionID: UUID?, runtimeID: UUID, runtimeAttemptID: UUID) {
            self.taskSessionID = taskSessionID
            self.runtimeID = runtimeID
            self.runtimeAttemptID = runtimeAttemptID
            self.taskSessionKnowledge = taskSessionID == nil ? .unknown : .known
        }
    }
    public enum Kind: String, Codable, Sendable {
        case clientCreated, sessionBound, sessionBindingRefused, clientStopped
        case localDelivery, deliveryRefused, taskScheduled, taskEntered
        case httpRequestStarted, httpResponse, transportFailure, callbackRefused
        case sessionBusyReported, sessionIdleReported, messageSnapshotObserved
        case messageCompletionReported, toolPartReported, eventRefused
    }
    public enum Reason: String, Codable, Sendable {
        case none, notReady, unboundSession, invalidIdentity, conflictingIdentity
        case foreignSession, staleEpoch, unknownRequest, invalidOrder, duplicateCallback
        case capacity, malformedEvent, unsupportedEvent, missingIdentity, invalidStatus
    }
    public enum ProviderState: String, Codable, Sendable {
        case unknown, busy, idle, pending, running, completed, failed
    }
    public enum Role: String, Codable, Sendable { case unknown, user, assistant }
    public struct ProviderIdentifier: Equatable, Hashable, Codable, Sendable {
        public enum Kind: String, Codable, Sendable { case session, message, part }
        public let kind: Kind
        /// SHA-256 of a kind-tagged exact UTF-8 identifier; no raw provider
        /// string is exported. This is a discriminator, not authentication.
        public let digest: String

        public static func observing(_ raw: String, kind: Kind) -> Self? {
            let bytes = raw.utf8
            let prefix = kind == .session ? "ses_" : kind == .message ? "msg_" : "prt_"
            guard bytes.count > prefix.utf8.count, bytes.count <= OpenCodeBoundaryTrace.maximumIdentifierBytes,
                  raw.hasPrefix(prefix), bytes.allSatisfy({
                      (48...57).contains($0) || (65...90).contains($0)
                          || (97...122).contains($0) || $0 == 95 || $0 == 45
                  }) else { return nil }
            let tagged = Data((kind.rawValue + "\u{0}" + raw).utf8)
            return Self(kind: kind, digest: SHA256.hash(data: tagged)
                .map { String(format: "%02x", $0) }.joined())
        }
    }
    public struct Record: Equatable, Codable, Sendable {
        public let sequence: UInt64
        public let observedUptimeNanoseconds: UInt64
        public let streamEpoch: UUID
        public let kind: Kind
        public let reason: Reason
        public let localDeliveryID: UUID?
        public let boundProviderSession: ProviderIdentifier?
        public let observedProviderSession: ProviderIdentifier?
        public let providerMessage: ProviderIdentifier?
        public let providerPart: ProviderIdentifier?
        public let providerState: ProviderState
        public let role: Role
        public let httpStatusCode: Int?
        public let httpStatusKnowledge: Knowledge
        public let localRequestCorrelation: Knowledge
        public let providerTurnIdentity: Knowledge
        public let providerObservationFreshness: Knowledge
    }
    public struct Snapshot: Equatable, Codable, Sendable {
        public let schemaVersion: Int
        public let traceID: UUID
        public let processClockID: UUID
        public let binding: Binding
        public let records: [Record]
        public let droppedRecordCount: UInt64
        public let untrackedDeliveryCount: UInt64
        public let refusedClockCount: UInt64
        public let recordLimit: Int
        public let requestLimit: Int
        public var completeRetention: Bool {
            droppedRecordCount == 0 && untrackedDeliveryCount == 0 && refusedClockCount == 0
        }
    }
    /// Created by this recorder only. It is local callback custody and has no
    /// provider-turn meaning or deserializable authority.
    public struct Ticket: Equatable, Sendable {
        public let localDeliveryID: UUID
        fileprivate let traceID: UUID
        fileprivate let epoch: UUID
    }
    public static let maximumRecords = 256
    public static let maximumRequests = 32
    public static let maximumIdentifierBytes = 128
    private static let currentProcessClockID = UUID()
    public private(set) var streamEpoch = UUID()
    public let binding: Binding
    private let traceID: UUID
    private let processClockID: UUID
    private let recordLimit: Int
    private let requestLimit: Int
    private var records: [Record] = []
    private var boundSession: ProviderIdentifier?
    private var boundSessionBytes: Data?
    private var lastTime: UInt64
    private var nextSequence: UInt64 = 0
    private var droppedRecordCount: UInt64 = 0
    private var untrackedDeliveryCount: UInt64 = 0
    private var refusedClockCount: UInt64 = 0
    private enum Stage: Int, Sendable { case delivered, scheduled, entered, started, responded, failed }
    private var requests: [UUID: Stage] = [:]
    private var requestOrder: [UUID] = []

    public init(
        binding: Binding, traceID: UUID = UUID(), processClockID: UUID? = nil,
        recordLimit: Int = maximumRecords, requestLimit: Int = maximumRequests,
        now: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        self.binding = binding
        self.traceID = traceID
        self.processClockID = processClockID ?? Self.currentProcessClockID
        self.recordLimit = min(max(recordLimit, 1), Self.maximumRecords)
        self.requestLimit = min(max(requestLimit, 1), Self.maximumRequests)
        self.lastTime = now
        append(.clientCreated, now: now)
    }
    public var snapshot: Snapshot {
        Snapshot(schemaVersion: 1, traceID: traceID, processClockID: processClockID,
                 binding: binding, records: records, droppedRecordCount: droppedRecordCount,
                 untrackedDeliveryCount: untrackedDeliveryCount, refusedClockCount: refusedClockCount,
                 recordLimit: recordLimit, requestLimit: requestLimit)
    }
    public mutating func bindSession(_ raw: String, now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        invalidateSession()
        guard acceptTime(now) else { return }
        guard let identity = ProviderIdentifier.observing(raw, kind: .session) else {
            append(.sessionBindingRefused, reason: .invalidIdentity, now: now); return
        }
        boundSession = identity
        boundSessionBytes = Data(raw.utf8)
        append(.sessionBound, session: identity, now: now)
    }
    public mutating func stop(now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        invalidateSession()
        if acceptTime(now) { append(.clientStopped, now: now) }
    }
    public mutating func beginDelivery(
        sessionID: String?, ready: Bool, now: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Ticket? {
        guard acceptTime(now) else { return nil }
        guard ready else { append(.deliveryRefused, reason: .notReady, now: now); return nil }
        guard let boundSessionBytes, let sessionID else {
            append(.deliveryRefused, reason: .unboundSession, now: now); return nil
        }
        guard sessionID.utf8.count <= Self.maximumIdentifierBytes,
              Data(sessionID.utf8) == boundSessionBytes else {
            append(.deliveryRefused, reason: .foreignSession, now: now); return nil
        }
        if requests.count == requestLimit {
            if let retired = requestOrder.first(where: { requests[$0] == .responded || requests[$0] == .failed }) {
                requests.removeValue(forKey: retired)
                requestOrder.removeAll { $0 == retired }
            } else {
                Self.increment(&untrackedDeliveryCount)
                append(.deliveryRefused, reason: .capacity, now: now); return nil
            }
        }
        let ticket = Ticket(localDeliveryID: UUID(), traceID: traceID, epoch: streamEpoch)
        requests[ticket.localDeliveryID] = .delivered
        requestOrder.append(ticket.localDeliveryID)
        append(.localDelivery, ticket: ticket, now: now)
        return ticket
    }
    public mutating func scheduled(_ ticket: Ticket, now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        advance(ticket, from: .delivered, to: .scheduled, kind: .taskScheduled, now: now)
    }
    public mutating func entered(_ ticket: Ticket, now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        advance(ticket, from: .scheduled, to: .entered, kind: .taskEntered, now: now)
    }
    public mutating func requestStarted(_ ticket: Ticket, now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        advance(ticket, from: .entered, to: .started, kind: .httpRequestStarted, now: now)
    }
    public mutating func response(
        _ ticket: Ticket, statusCode: Int?, now: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        guard acceptTime(now), validate(ticket, expecting: .started, now: now) else { return }
        requests[ticket.localDeliveryID] = .responded
        let validStatus = statusCode.flatMap { (100...599).contains($0) ? $0 : nil }
        append(.httpResponse, reason: statusCode != nil && validStatus == nil ? .invalidStatus : .none,
               ticket: ticket, httpStatus: validStatus, now: now)
    }
    public mutating func transportFailed(_ ticket: Ticket, now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        advance(ticket, from: .started, to: .failed, kind: .transportFailure, now: now)
    }

    /// Projects only finite metadata from the event's actual identity fields.
    /// No request is nominated from temporal proximity or latest-send state.
    public mutating func observe(
        _ json: CodexJSON, streamEpoch: UUID,
        now: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        guard acceptTime(now) else { return }
        guard streamEpoch == self.streamEpoch else {
            append(.eventRefused, reason: .staleEpoch, now: now); return
        }
        guard let boundSessionBytes else { append(.eventRefused, reason: .unboundSession, now: now); return }
        guard case .object = json else { append(.eventRefused, reason: .malformedEvent, now: now); return }
        let types = [json["type"], json["event"]].compactMap { $0 }
        guard let firstType = types.first?.stringValue,
              types.allSatisfy({ $0.stringValue == firstType }) else {
            append(.eventRefused, reason: .malformedEvent, now: now); return
        }
        let p = json["properties"] ?? json
        guard case .object = p else { append(.eventRefused, reason: .malformedEvent, now: now); return }
        for key in ["info", "part", "session"] {
            if let value = p[key], case .object = value { continue }
            if p[key] != nil { append(.eventRefused, reason: .malformedEvent, now: now); return }
        }
        guard ["session.status", "session.idle", "message.updated", "message.part.updated"].contains(firstType) else {
            append(.eventRefused, reason: .unsupportedEvent, now: now); return
        }
        var sessions = [p["sessionID"], p["info"]?["sessionID"], p["part"]?["sessionID"], p["session"]?["id"]]
        if json["properties"] != nil { sessions.append(json["sessionID"]) }
        if firstType.hasPrefix("session.") { sessions.append(p["id"]) }
        let resolvedSession = resolve(sessions, kind: .session)
        guard let session = resolvedSession.identity, let bytes = resolvedSession.bytes else {
            append(.eventRefused, reason: resolvedSession.reason, now: now); return
        }
        guard bytes == boundSessionBytes else { append(.eventRefused, reason: .foreignSession, now: now); return }
        if firstType == "session.idle" {
            append(.sessionIdleReported, session: session, state: .idle, now: now); return
        }
        if firstType == "session.status" {
            let status = p["status"]?["type"]?.stringValue
            guard status == "busy" || status == "idle" else {
                append(.eventRefused, reason: .invalidStatus, now: now); return
            }
            append(status == "busy" ? .sessionBusyReported : .sessionIdleReported,
                   session: session, state: status == "busy" ? .busy : .idle, now: now); return
        }
        if firstType == "message.updated" {
            let message = resolve([p["info"]?["id"], p["messageID"], p["part"]?["messageID"],
                                   json["properties"] == nil ? nil : json["messageID"]], kind: .message)
            guard let identity = message.identity else { append(.eventRefused, reason: message.reason, now: now); return }
            let role = p["info"]?["role"]?.stringValue
            guard role == "user" || role == "assistant" else {
                append(.eventRefused, reason: .malformedEvent, now: now); return
            }
            append(.messageSnapshotObserved, session: session, message: identity,
                   role: role == "assistant" ? .assistant : .user, now: now)
            if role == "assistant", let completed = p["info"]?["time"]?["completed"] {
                if case .number(let number) = completed, number.isFinite, number >= 0 {
                    append(.messageCompletionReported, session: session, message: identity,
                           state: .completed, role: .assistant, now: now)
                } else { append(.eventRefused, reason: .malformedEvent, now: now) }
            }
            return
        }
        let part = p["part"]
        guard part?["type"]?.stringValue == "tool" else {
            append(.eventRefused, reason: .unsupportedEvent, now: now); return
        }
        let message = resolve([part?["messageID"], p["messageID"], p["info"]?["id"],
                               json["properties"] == nil ? nil : json["messageID"]], kind: .message)
        let partID = resolve([part?["id"], p["partID"]], kind: .part)
        guard let messageIdentity = message.identity, let partIdentity = partID.identity else {
            append(.eventRefused, reason: message.identity == nil ? message.reason : partID.reason, now: now); return
        }
        let state: ProviderState
        switch part?["state"]?["status"]?.stringValue {
        case "pending": state = .pending
        case "running": state = .running
        case "completed": state = .completed
        case "error": state = .failed
        default: append(.eventRefused, reason: .invalidStatus, now: now); return
        }
        append(.toolPartReported, session: session, message: messageIdentity,
               part: partIdentity, state: state, now: now)
    }
    private func resolve(
        _ values: [CodexJSON?], kind: ProviderIdentifier.Kind
    ) -> (identity: ProviderIdentifier?, bytes: Data?, reason: Reason) {
        let present = values.compactMap { $0 }
        guard let first = present.first else { return (nil, nil, .missingIdentity) }
        guard let raw = first.stringValue, let identity = ProviderIdentifier.observing(raw, kind: kind) else {
            return (nil, nil, .invalidIdentity)
        }
        let bytes = Data(raw.utf8)
        for value in present {
            guard let raw = value.stringValue, ProviderIdentifier.observing(raw, kind: kind) != nil else {
                return (nil, nil, .invalidIdentity)
            }
            guard Data(raw.utf8) == bytes else { return (nil, nil, .conflictingIdentity) }
        }
        return (identity, bytes, .none)
    }
    private mutating func advance(_ ticket: Ticket, from: Stage, to: Stage, kind: Kind, now: UInt64) {
        guard acceptTime(now), validate(ticket, expecting: from, now: now) else { return }
        requests[ticket.localDeliveryID] = to
        append(kind, ticket: ticket, now: now)
    }
    private mutating func validate(_ ticket: Ticket, expecting stage: Stage, now: UInt64) -> Bool {
        let reason: Reason
        if ticket.traceID != traceID { reason = .unknownRequest }
        else if ticket.epoch != streamEpoch || boundSession == nil { reason = .staleEpoch }
        else if let observed = requests[ticket.localDeliveryID] {
            if observed == stage { return true }
            reason = observed == .responded || observed == .failed ? .duplicateCallback : .invalidOrder
        } else { reason = .unknownRequest }
        append(.callbackRefused, reason: reason, now: now)
        return false
    }
    private mutating func invalidateSession() {
        streamEpoch = UUID(); boundSession = nil; boundSessionBytes = nil
        requests.removeAll(keepingCapacity: true); requestOrder.removeAll(keepingCapacity: true)
    }
    private mutating func acceptTime(_ now: UInt64) -> Bool {
        guard now >= lastTime else { Self.increment(&refusedClockCount); return false }
        lastTime = now; return true
    }
    private static func increment(_ value: inout UInt64) { if value < .max { value += 1 } }
    private mutating func append(
        _ kind: Kind, reason: Reason = .none, ticket: Ticket? = nil,
        session: ProviderIdentifier? = nil, message: ProviderIdentifier? = nil,
        part: ProviderIdentifier? = nil, state: ProviderState = .unknown,
        role: Role = .unknown, httpStatus: Int? = nil, now: UInt64
    ) {
        guard nextSequence < .max else { Self.increment(&droppedRecordCount); return }
        nextSequence += 1
        if records.count == recordLimit { records.removeFirst(); Self.increment(&droppedRecordCount) }
        records.append(Record(sequence: nextSequence, observedUptimeNanoseconds: now,
                              streamEpoch: streamEpoch, kind: kind, reason: reason,
                              localDeliveryID: ticket?.localDeliveryID, boundProviderSession: boundSession,
                              observedProviderSession: session, providerMessage: message, providerPart: part,
                              providerState: state, role: role, httpStatusCode: httpStatus,
                              httpStatusKnowledge: httpStatus == nil ? .unknown : .known,
                              localRequestCorrelation: ticket == nil ? .unknown : .known,
                              providerTurnIdentity: .unknown, providerObservationFreshness: .unknown))
    }
}
