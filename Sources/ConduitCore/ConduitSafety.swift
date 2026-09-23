import CryptoKit
import Darwin
import Foundation

public enum ConduitSafetyHash {
    /// Namespaced digest for bounded, unbounded-length text such as an
    /// objective or prompt body. Callers pass the digest into a fingerprint
    /// instead of the raw text.
    public static func digest(namespace: String, text: String) -> String {
        digest(namespace: namespace, bytes: text.utf8)
    }

    static func digest<S: Sequence>(namespace: String, bytes: S) -> String
        where S.Element == UInt8 {
        var hasher = SHA256()
        hasher.update(data: Data(namespace.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: Data(bytes))
        return hex(hasher.finalize())
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Resource circuit breaker

public enum ConduitResourceMetric: String, Codable, CaseIterable, Sendable {
    case availablePhysicalMemoryBytes = "available_physical_memory_bytes"
    case ownedProcessTreeRSSBytes = "owned_process_tree_rss_bytes"
    case persistenceQueueCount = "persistence_queue_count"
    case persistenceQueueBytes = "persistence_queue_bytes"
    case promptQueueDepth = "prompt_queue_depth"
}

public enum ConduitResourceMeasurement: Codable, Equatable, Sendable {
    case known(value: UInt64, observedAt: Date)
    case unknown
}

public struct ConduitResourceSnapshot: Codable, Equatable, Sendable {
    public let availablePhysicalMemoryBytes: ConduitResourceMeasurement
    public let ownedProcessTreeRSSBytes: ConduitResourceMeasurement
    public let persistenceQueueCount: ConduitResourceMeasurement
    public let persistenceQueueBytes: ConduitResourceMeasurement
    public let promptQueueDepth: ConduitResourceMeasurement

    public init(
        availablePhysicalMemoryBytes: ConduitResourceMeasurement,
        ownedProcessTreeRSSBytes: ConduitResourceMeasurement,
        persistenceQueueCount: ConduitResourceMeasurement,
        persistenceQueueBytes: ConduitResourceMeasurement,
        promptQueueDepth: ConduitResourceMeasurement
    ) {
        self.availablePhysicalMemoryBytes = availablePhysicalMemoryBytes
        self.ownedProcessTreeRSSBytes = ownedProcessTreeRSSBytes
        self.persistenceQueueCount = persistenceQueueCount
        self.persistenceQueueBytes = persistenceQueueBytes
        self.promptQueueDepth = promptQueueDepth
    }

    public static func known(
        availablePhysicalMemoryBytes: UInt64,
        ownedProcessTreeRSSBytes: UInt64,
        persistenceQueueCount: UInt64,
        persistenceQueueBytes: UInt64,
        promptQueueDepth: UInt64,
        observedAt: Date
    ) -> ConduitResourceSnapshot {
        ConduitResourceSnapshot(
            availablePhysicalMemoryBytes: .known(
                value: availablePhysicalMemoryBytes,
                observedAt: observedAt
            ),
            ownedProcessTreeRSSBytes: .known(
                value: ownedProcessTreeRSSBytes,
                observedAt: observedAt
            ),
            persistenceQueueCount: .known(
                value: persistenceQueueCount,
                observedAt: observedAt
            ),
            persistenceQueueBytes: .known(
                value: persistenceQueueBytes,
                observedAt: observedAt
            ),
            promptQueueDepth: .known(
                value: promptQueueDepth,
                observedAt: observedAt
            )
        )
    }

    public static let unknown = ConduitResourceSnapshot(
        availablePhysicalMemoryBytes: .unknown,
        ownedProcessTreeRSSBytes: .unknown,
        persistenceQueueCount: .unknown,
        persistenceQueueBytes: .unknown,
        promptQueueDepth: .unknown
    )

    public func measurement(
        for metric: ConduitResourceMetric
    ) -> ConduitResourceMeasurement {
        switch metric {
        case .availablePhysicalMemoryBytes:
            return availablePhysicalMemoryBytes
        case .ownedProcessTreeRSSBytes:
            return ownedProcessTreeRSSBytes
        case .persistenceQueueCount:
            return persistenceQueueCount
        case .persistenceQueueBytes:
            return persistenceQueueBytes
        case .promptQueueDepth:
            return promptQueueDepth
        }
    }

    public func knownValue(for metric: ConduitResourceMetric) -> UInt64? {
        guard case .known(let value, _) = measurement(for: metric) else {
            return nil
        }
        return value
    }
}

public struct ConduitResourceCircuitPolicy: Equatable, Sendable {
    public var minimumAvailablePhysicalMemoryBytes: UInt64
    public var maximumOwnedProcessTreeRSSBytes: UInt64
    public var maximumPersistenceQueueCount: UInt64
    public var maximumPersistenceQueueBytes: UInt64
    public var maximumPromptQueueDepth: UInt64
    public var maximumSampleAge: TimeInterval
    public var maximumFutureClockSkew: TimeInterval

    /// Metrics this host actually samples. Only these are evaluated, and each
    /// one still fails closed when it is unknown, stale, or over its limit.
    /// A metric is omitted when Conduit has no sensor for it — omission is an
    /// explicit declaration of what is not measured, never a substitute
    /// `known(0)` reading for a quantity nobody observed.
    public var requiredMetrics: Set<ConduitResourceMetric>

    public init(
        minimumAvailablePhysicalMemoryBytes: UInt64 = 1_073_741_824,
        maximumOwnedProcessTreeRSSBytes: UInt64 = 6_442_450_944,
        maximumPersistenceQueueCount: UInt64 = 128,
        maximumPersistenceQueueBytes: UInt64 = 67_108_864,
        maximumPromptQueueDepth: UInt64 = 32,
        maximumSampleAge: TimeInterval = 10,
        maximumFutureClockSkew: TimeInterval = 1,
        requiredMetrics: Set<ConduitResourceMetric> = Set(ConduitResourceMetric.allCases)
    ) {
        self.minimumAvailablePhysicalMemoryBytes = minimumAvailablePhysicalMemoryBytes
        self.maximumOwnedProcessTreeRSSBytes = maximumOwnedProcessTreeRSSBytes
        self.maximumPersistenceQueueCount = maximumPersistenceQueueCount
        self.maximumPersistenceQueueBytes = maximumPersistenceQueueBytes
        self.maximumPromptQueueDepth = maximumPromptQueueDepth
        self.maximumSampleAge = maximumSampleAge
        self.maximumFutureClockSkew = maximumFutureClockSkew
        self.requiredMetrics = requiredMetrics
    }

    public static let conservativeDefault = ConduitResourceCircuitPolicy()

    /// Only the metrics Conduit genuinely samples on macOS.
    ///
    /// Persistence queue depth is omitted because there is no persistence
    /// queue: conversation and task logs are written synchronously. Declaring
    /// it unmeasured is the honest encoding; reporting `known(0)` would pass a
    /// check on a quantity nobody observed.
    public static let conduitSampledMetrics = ConduitResourceCircuitPolicy(
        requiredMetrics: [
            .availablePhysicalMemoryBytes,
            .ownedProcessTreeRSSBytes,
            .promptQueueDepth,
        ]
    )

    public var isValid: Bool {
        minimumAvailablePhysicalMemoryBytes > 0
            && maximumOwnedProcessTreeRSSBytes > 0
            && maximumPersistenceQueueCount > 0
            && maximumPersistenceQueueBytes > 0
            && maximumPromptQueueDepth > 0
            && maximumSampleAge > 0
            && maximumFutureClockSkew >= 0
            && !requiredMetrics.isEmpty
    }
}

public enum ConduitResourceCircuitCode: String, Codable, Sendable {
    case allow
    case configurationInvalid = "configuration_invalid"
    case measurementUnknown = "measurement_unknown"
    case measurementStale = "measurement_stale"
    case thresholdExceeded = "threshold_exceeded"
}

public struct ConduitResourceCircuitViolation: Codable, Equatable, Sendable {
    public let metric: ConduitResourceMetric
    public let code: ConduitResourceCircuitCode
    public let observedValue: UInt64?
    public let limitValue: UInt64?
    public let detail: String

    public init(
        metric: ConduitResourceMetric,
        code: ConduitResourceCircuitCode,
        observedValue: UInt64? = nil,
        limitValue: UInt64? = nil,
        detail: String
    ) {
        self.metric = metric
        self.code = code
        self.observedValue = observedValue
        self.limitValue = limitValue
        self.detail = detail
    }
}

public struct ConduitResourceCircuitDecision: Equatable, Sendable {
    public let code: ConduitResourceCircuitCode
    public let violations: [ConduitResourceCircuitViolation]

    public var allowsNewWork: Bool { code == .allow }

    public init(
        code: ConduitResourceCircuitCode,
        violations: [ConduitResourceCircuitViolation]
    ) {
        self.code = code
        self.violations = violations
    }
}

public struct ConduitResourceCircuitBreaker: Sendable {
    public let policy: ConduitResourceCircuitPolicy

    public init(policy: ConduitResourceCircuitPolicy = .conservativeDefault) {
        self.policy = policy
    }

    public func evaluate(
        _ snapshot: ConduitResourceSnapshot,
        now: Date = Date()
    ) -> ConduitResourceCircuitDecision {
        guard policy.isValid else {
            return ConduitResourceCircuitDecision(
                code: .configurationInvalid,
                violations: ConduitResourceMetric.allCases.map {
                    ConduitResourceCircuitViolation(
                        metric: $0,
                        code: .configurationInvalid,
                        detail: "Resource circuit-breaker policy is invalid; refuse new work."
                    )
                }
            )
        }

        var violations: [ConduitResourceCircuitViolation] = []
        let evaluated = ConduitResourceMetric.allCases.filter {
            policy.requiredMetrics.contains($0)
        }
        for metric in evaluated {
            switch snapshot.measurement(for: metric) {
            case .unknown:
                violations.append(
                    ConduitResourceCircuitViolation(
                        metric: metric,
                        code: .measurementUnknown,
                        detail: "Required resource measurement is unknown; refresh sensors before retrying."
                    )
                )
            case .known(let value, let observedAt):
                let age = now.timeIntervalSince(observedAt)
                if age > policy.maximumSampleAge
                    || age < -policy.maximumFutureClockSkew {
                    violations.append(
                        ConduitResourceCircuitViolation(
                            metric: metric,
                            code: .measurementStale,
                            observedValue: value,
                            detail: "Required resource measurement is stale or has an invalid timestamp; refresh sensors before retrying."
                        )
                    )
                    continue
                }

                if let limitViolation = thresholdViolation(
                    metric: metric,
                    value: value
                ) {
                    violations.append(limitViolation)
                }
            }
        }

        let code: ConduitResourceCircuitCode
        if violations.contains(where: { $0.code == .measurementUnknown }) {
            code = .measurementUnknown
        } else if violations.contains(where: { $0.code == .measurementStale }) {
            code = .measurementStale
        } else if !violations.isEmpty {
            code = .thresholdExceeded
        } else {
            code = .allow
        }
        return ConduitResourceCircuitDecision(code: code, violations: violations)
    }

    private func thresholdViolation(
        metric: ConduitResourceMetric,
        value: UInt64
    ) -> ConduitResourceCircuitViolation? {
        switch metric {
        case .availablePhysicalMemoryBytes:
            guard value >= policy.minimumAvailablePhysicalMemoryBytes else {
                return ConduitResourceCircuitViolation(
                    metric: metric,
                    code: .thresholdExceeded,
                    observedValue: value,
                    limitValue: policy.minimumAvailablePhysicalMemoryBytes,
                    detail: "Available physical memory is below the admission floor."
                )
            }
        case .ownedProcessTreeRSSBytes:
            guard value <= policy.maximumOwnedProcessTreeRSSBytes else {
                return ConduitResourceCircuitViolation(
                    metric: metric,
                    code: .thresholdExceeded,
                    observedValue: value,
                    limitValue: policy.maximumOwnedProcessTreeRSSBytes,
                    detail: "Owned process-tree RSS exceeds the admission ceiling."
                )
            }
        case .persistenceQueueCount:
            guard value <= policy.maximumPersistenceQueueCount else {
                return ConduitResourceCircuitViolation(
                    metric: metric,
                    code: .thresholdExceeded,
                    observedValue: value,
                    limitValue: policy.maximumPersistenceQueueCount,
                    detail: "Persistence queue count exceeds the admission ceiling."
                )
            }
        case .persistenceQueueBytes:
            guard value <= policy.maximumPersistenceQueueBytes else {
                return ConduitResourceCircuitViolation(
                    metric: metric,
                    code: .thresholdExceeded,
                    observedValue: value,
                    limitValue: policy.maximumPersistenceQueueBytes,
                    detail: "Persistence queue bytes exceed the admission ceiling."
                )
            }
        case .promptQueueDepth:
            guard value <= policy.maximumPromptQueueDepth else {
                return ConduitResourceCircuitViolation(
                    metric: metric,
                    code: .thresholdExceeded,
                    observedValue: value,
                    limitValue: policy.maximumPromptQueueDepth,
                    detail: "Prompt queue depth exceeds the admission ceiling."
                )
            }
        }
        return nil
    }
}

// MARK: - Atomic MCP admission

public struct MCPCreateDedupeIdentity: Equatable, Sendable {
    public let idempotencyKeyDigest: String
    public let idempotencyKeyByteCount: Int
    public let requestFingerprint: String

    public init(idempotencyKey: String, requestFingerprint: String) {
        self.idempotencyKeyDigest = ConduitSafetyHash.digest(
            namespace: "mcp-idempotency-key",
            bytes: idempotencyKey.utf8
        )
        self.idempotencyKeyByteCount = idempotencyKey.utf8.count
        self.requestFingerprint = requestFingerprint.lowercased()
    }

    /// Produces an unambiguous digest from already-bounded canonical fields.
    /// Prompt text should be represented by its own digest, not passed here.
    public static func fingerprint(
        canonicalComponents: [String]
    ) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("mcp-create-fingerprint\0".utf8))
        for component in canonicalComponents {
            let data = Data(component.utf8)
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) {
                hasher.update(data: Data($0))
            }
            hasher.update(data: data)
        }
        return ConduitSafetyHash.hex(hasher.finalize())
    }

    fileprivate var hasValidFingerprint: Bool {
        requestFingerprint.utf8.count == 64
            && requestFingerprint.utf8.allSatisfy {
                ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
            }
    }
}

public struct MCPAdmissionPolicy: Equatable, Sendable {
    public var writesEnabled: Bool
    public var requireCallerIdentity: Bool
    public var requireCreateIdempotency: Bool
    public var globalLiveTaskLimit: Int
    public var maximumPendingCreateReservations: Int
    public var maximumGlobalPromptQueueDepth: Int
    public var maximumPromptQueueDepthPerTask: Int
    public var perCallerCreateLimit: Int
    public var perCallerWriteLimit: Int
    public var rateWindow: TimeInterval
    public var maximumIdempotencyEntries: Int
    public var idempotencyRetention: TimeInterval
    public var maximumCallerIdentityBytes: Int
    public var maximumIdempotencyKeyBytes: Int
    public var resourcePolicy: ConduitResourceCircuitPolicy

    public init(
        writesEnabled: Bool = false,
        requireCallerIdentity: Bool = true,
        requireCreateIdempotency: Bool = true,
        globalLiveTaskLimit: Int = 4,
        maximumPendingCreateReservations: Int = 2,
        maximumGlobalPromptQueueDepth: Int = 16,
        maximumPromptQueueDepthPerTask: Int = 4,
        perCallerCreateLimit: Int = 2,
        perCallerWriteLimit: Int = 12,
        rateWindow: TimeInterval = 60,
        maximumIdempotencyEntries: Int = 1_024,
        idempotencyRetention: TimeInterval = 86_400,
        maximumCallerIdentityBytes: Int = 256,
        maximumIdempotencyKeyBytes: Int = 512,
        resourcePolicy: ConduitResourceCircuitPolicy = .conservativeDefault
    ) {
        self.writesEnabled = writesEnabled
        self.requireCallerIdentity = requireCallerIdentity
        self.requireCreateIdempotency = requireCreateIdempotency
        self.globalLiveTaskLimit = globalLiveTaskLimit
        self.maximumPendingCreateReservations = maximumPendingCreateReservations
        self.maximumGlobalPromptQueueDepth = maximumGlobalPromptQueueDepth
        self.maximumPromptQueueDepthPerTask = maximumPromptQueueDepthPerTask
        self.perCallerCreateLimit = perCallerCreateLimit
        self.perCallerWriteLimit = perCallerWriteLimit
        self.rateWindow = rateWindow
        self.maximumIdempotencyEntries = maximumIdempotencyEntries
        self.idempotencyRetention = idempotencyRetention
        self.maximumCallerIdentityBytes = maximumCallerIdentityBytes
        self.maximumIdempotencyKeyBytes = maximumIdempotencyKeyBytes
        self.resourcePolicy = resourcePolicy
    }

    public static let conservativeDefault = MCPAdmissionPolicy()

    /// The policy Conduit ships for its Session API (D-041).
    ///
    /// `globalLiveTaskLimit` is the protection that matters: it is a hard
    /// ceiling on how many runtimes one external orchestrator can be holding
    /// at once, and it cannot be outrun by any call rate.
    ///
    /// The rate limits defend a different failure: churn. A create that fails
    /// to provision returns its slot, so a broken loop could retry forever
    /// without ever occupying capacity. The create limit is therefore set to
    /// let a legitimate orchestrator fill the whole fleet in one planning
    /// burst and still have retries left, while capping a churn loop well
    /// below the rate that overloaded this host on 2026-08-18. Creates also
    /// consume the write budget, so the write limit leaves headroom for
    /// prompting, interrupting, and closing the tasks that were started.
    ///
    /// Prompt queue depths are depth, not rate, and stay at the conservative
    /// defaults.
    public static func conduitSessionAPI(
        writesEnabled: Bool
    ) -> MCPAdmissionPolicy {
        MCPAdmissionPolicy(
            writesEnabled: writesEnabled,
            // ChatGPT does not send an idempotency key, so requiring one would
            // refuse every call. It stays opt-in.
            requireCreateIdempotency: false,
            globalLiveTaskLimit: 4,
            perCallerCreateLimit: 6,
            perCallerWriteLimit: 30,
            resourcePolicy: .conduitSampledMetrics
        )
    }

    public var isValid: Bool {
        globalLiveTaskLimit > 0
            && maximumPendingCreateReservations > 0
            && maximumGlobalPromptQueueDepth > 0
            && maximumPromptQueueDepthPerTask > 0
            && perCallerCreateLimit > 0
            && perCallerWriteLimit > 0
            && rateWindow > 0
            && maximumIdempotencyEntries > 0
            && idempotencyRetention > 0
            && maximumCallerIdentityBytes > 0
            && maximumIdempotencyKeyBytes > 0
            && resourcePolicy.isValid
    }
}

public enum MCPAdmissionOutcome: String, Codable, Sendable {
    case admitted
    case deduplicated
    case rejected
}

public enum MCPAdmissionDecisionCode: String, Codable, Sendable {
    case admitted
    case writesDisabled = "writes_disabled"
    case configurationInvalid = "configuration_invalid"
    case callerIdentityRequired = "caller_identity_required"
    case callerIdentityTooLarge = "caller_identity_too_large"
    case invalidIdempotency = "invalid_idempotency"
    case idempotencyConflict = "idempotency_conflict"
    case idempotencyStoreFull = "idempotency_store_full"
    case duplicatePending = "duplicate_pending"
    case duplicateCompleted = "duplicate_completed"
    case resourceUnknown = "resource_unknown"
    case resourceStale = "resource_stale"
    case resourceLimitExceeded = "resource_limit_exceeded"
    case globalLiveTaskLimitReached = "global_live_task_limit_reached"
    case createReservationQueueFull = "create_reservation_queue_full"
    case callerCreateRateLimited = "caller_create_rate_limited"
    case callerWriteRateLimited = "caller_write_rate_limited"
    case globalPromptQueueFull = "global_prompt_queue_full"
    case taskPromptQueueFull = "task_prompt_queue_full"
}

public struct MCPAdmissionDecision: Equatable, Sendable {
    public let outcome: MCPAdmissionOutcome
    public let code: MCPAdmissionDecisionCode
    public let detail: String
    public let reservationID: UUID?
    public let taskSessionID: TaskSessionID?
    public let retryAfterSeconds: TimeInterval?
    public let resourceViolations: [ConduitResourceCircuitViolation]

    public var shouldExecute: Bool { outcome == .admitted }
    public var isRequestSatisfied: Bool {
        outcome == .admitted || code == .duplicateCompleted
    }

    public init(
        outcome: MCPAdmissionOutcome,
        code: MCPAdmissionDecisionCode,
        detail: String,
        reservationID: UUID? = nil,
        taskSessionID: TaskSessionID? = nil,
        retryAfterSeconds: TimeInterval? = nil,
        resourceViolations: [ConduitResourceCircuitViolation] = []
    ) {
        self.outcome = outcome
        self.code = code
        self.detail = detail
        self.reservationID = reservationID
        self.taskSessionID = taskSessionID
        self.retryAfterSeconds = retryAfterSeconds
        self.resourceViolations = resourceViolations
    }
}

public struct MCPAdmissionStateSnapshot: Equatable, Sendable {
    public let liveTaskSessionIDs: Set<TaskSessionID>
    public let pendingCreateReservationCount: Int
    public let queuedPromptCount: Int
    public let idempotencyEntryCount: Int

    public init(
        liveTaskSessionIDs: Set<TaskSessionID>,
        pendingCreateReservationCount: Int,
        queuedPromptCount: Int,
        idempotencyEntryCount: Int
    ) {
        self.liveTaskSessionIDs = liveTaskSessionIDs
        self.pendingCreateReservationCount = pendingCreateReservationCount
        self.queuedPromptCount = queuedPromptCount
        self.idempotencyEntryCount = idempotencyEntryCount
    }
}

/// A synchronous, lock-serialized admission boundary. A successful create
/// reserves capacity before returning, so simultaneous calls cannot all observe
/// the same free slot. Task-session capacity never uses runtime-attempt state.
public final class MCPAdmissionController: @unchecked Sendable {
    public let policy: MCPAdmissionPolicy

    private struct CreateReservation {
        let idempotencyKeyDigest: String?
    }

    private enum IdempotencyState {
        case pending(UUID)
        case completed(TaskSessionID)
    }

    private struct IdempotencyEntry {
        let requestFingerprint: String
        var state: IdempotencyState
        var updatedAt: Date
    }

    private struct RateBucket {
        var creates: [Date] = []
        var writes: [Date] = []
    }

    private let lock = NSLock()
    private let resourceCircuitBreaker: ConduitResourceCircuitBreaker
    private var liveTaskSessionIDs: Set<TaskSessionID>
    private var createReservations: [UUID: CreateReservation] = [:]
    private var promptWork: [UUID: TaskSessionID] = [:]
    private var idempotencyEntries: [String: IdempotencyEntry] = [:]
    private var rateBuckets: [String: RateBucket] = [:]

    public init(
        policy: MCPAdmissionPolicy = .conservativeDefault,
        initialLiveTaskSessionIDs: Set<TaskSessionID> = []
    ) {
        self.policy = policy
        self.resourceCircuitBreaker = ConduitResourceCircuitBreaker(
            policy: policy.resourcePolicy
        )
        self.liveTaskSessionIDs = initialLiveTaskSessionIDs
    }

    public func admitCreate(
        callerIdentity: String?,
        dedupeIdentity: MCPCreateDedupeIdentity?,
        resources: ConduitResourceSnapshot,
        now: Date = Date()
    ) -> MCPAdmissionDecision {
        withLock {
            if let decision = baseRejection(
                callerIdentity: callerIdentity,
                resources: resources,
                now: now
            ) {
                return decision
            }
            guard let callerDigest = callerDigest(callerIdentity) else {
                return rejection(
                    .callerIdentityRequired,
                    "A bounded caller identity is required for MCP writes."
                )
            }

            pruneIdempotencyEntries(now: now)
            if policy.requireCreateIdempotency && dedupeIdentity == nil {
                return rejection(
                    .invalidIdempotency,
                    "Create requires an idempotency key and canonical request fingerprint."
                )
            }
            if let dedupeIdentity {
                guard dedupeIdentity.idempotencyKeyByteCount > 0,
                      dedupeIdentity.idempotencyKeyByteCount
                        <= policy.maximumIdempotencyKeyBytes,
                      dedupeIdentity.hasValidFingerprint else {
                    return rejection(
                        .invalidIdempotency,
                        "Idempotency key or request fingerprint is empty, oversized, or malformed."
                    )
                }
                if let existing = idempotencyEntries[
                    dedupeIdentity.idempotencyKeyDigest
                ] {
                    guard existing.requestFingerprint
                        == dedupeIdentity.requestFingerprint else {
                        return rejection(
                            .idempotencyConflict,
                            "The idempotency key was already used for a different create request."
                        )
                    }
                    switch existing.state {
                    case .pending(let reservationID):
                        return MCPAdmissionDecision(
                            outcome: .deduplicated,
                            code: .duplicatePending,
                            detail: "An identical create request is already pending; wait for reconciliation.",
                            reservationID: reservationID
                        )
                    case .completed(let taskSessionID):
                        return MCPAdmissionDecision(
                            outcome: .deduplicated,
                            code: .duplicateCompleted,
                            detail: "An identical create request already completed; reuse the durable task session.",
                            taskSessionID: taskSessionID
                        )
                    }
                }
                guard idempotencyEntries.count
                    < policy.maximumIdempotencyEntries else {
                    return rejection(
                        .idempotencyStoreFull,
                        "The idempotency ledger is full; reconcile or wait for completed entries to expire."
                    )
                }
            }

            if let rateDecision = rateRejection(
                callerDigest: callerDigest,
                kind: .create,
                now: now
            ) {
                return rateDecision
            }
            let occupiedCapacity = liveTaskSessionIDs.count
                + createReservations.count
            guard occupiedCapacity < policy.globalLiveTaskLimit else {
                return rejection(
                    .globalLiveTaskLimitReached,
                    "Global live-task capacity is full; finish or explicitly end a task before retrying."
                )
            }
            guard createReservations.count
                < policy.maximumPendingCreateReservations else {
                return rejection(
                    .createReservationQueueFull,
                    "The bounded create-reservation queue is full; wait for pending creates to reconcile."
                )
            }

            let reservationID = UUID()
            createReservations[reservationID] = CreateReservation(
                idempotencyKeyDigest: dedupeIdentity?.idempotencyKeyDigest
            )
            if let dedupeIdentity {
                idempotencyEntries[dedupeIdentity.idempotencyKeyDigest]
                    = IdempotencyEntry(
                        requestFingerprint: dedupeIdentity.requestFingerprint,
                        state: .pending(reservationID),
                        updatedAt: now
                    )
            }
            recordRates(callerDigest: callerDigest, isCreate: true, now: now)
            return MCPAdmissionDecision(
                outcome: .admitted,
                code: .admitted,
                detail: "Create admitted with atomic capacity reservation.",
                reservationID: reservationID
            )
        }
    }

    @discardableResult
    public func commitCreate(
        reservationID: UUID,
        taskSessionID: TaskSessionID,
        now: Date = Date()
    ) -> Bool {
        withLock {
            guard let reservation = createReservations.removeValue(
                forKey: reservationID
            ) else {
                return false
            }
            liveTaskSessionIDs.insert(taskSessionID)
            if let key = reservation.idempotencyKeyDigest,
               var entry = idempotencyEntries[key] {
                entry.state = .completed(taskSessionID)
                entry.updatedAt = now
                idempotencyEntries[key] = entry
            }
            return true
        }
    }

    @discardableResult
    public func cancelCreate(reservationID: UUID) -> Bool {
        withLock {
            guard let reservation = createReservations.removeValue(
                forKey: reservationID
            ) else {
                return false
            }
            if let key = reservation.idempotencyKeyDigest,
               let entry = idempotencyEntries[key],
               case .pending(let pendingID) = entry.state,
               pendingID == reservationID {
                idempotencyEntries.removeValue(forKey: key)
            }
            return true
        }
    }

    /// Additive restart reconciliation: observed durable tasks are registered
    /// without deleting any task that needs an explicit lifecycle transition.
    public func reconcileLiveTasks(additive taskSessionIDs: Set<TaskSessionID>) {
        withLock {
            liveTaskSessionIDs.formUnion(taskSessionIDs)
        }
    }

    /// Ending a task is explicit. Runtime detach/exit must not call this method.
    public func markTaskEnded(_ taskSessionID: TaskSessionID) {
        withLock {
            liveTaskSessionIDs.remove(taskSessionID)
        }
    }

    public func admitPrompt(
        callerIdentity: String?,
        taskSessionID: TaskSessionID,
        observedTaskQueueDepth: UInt64 = 0,
        resources: ConduitResourceSnapshot,
        now: Date = Date()
    ) -> MCPAdmissionDecision {
        withLock {
            if let decision = baseRejection(
                callerIdentity: callerIdentity,
                resources: resources,
                now: now
            ) {
                return decision
            }
            guard let callerDigest = callerDigest(callerIdentity) else {
                return rejection(
                    .callerIdentityRequired,
                    "A bounded caller identity is required for MCP writes."
                )
            }
            if let rateDecision = rateRejection(
                callerDigest: callerDigest,
                kind: .write,
                now: now
            ) {
                return rateDecision
            }

            let observedGlobal = resources.knownValue(for: .promptQueueDepth) ?? 0
            let controlledGlobal = UInt64(promptWork.count)
            guard max(observedGlobal, controlledGlobal)
                < UInt64(policy.maximumGlobalPromptQueueDepth) else {
                return rejection(
                    .globalPromptQueueFull,
                    "The global prompt queue is full; wait for queued work to drain."
                )
            }
            let controlledTask = UInt64(
                promptWork.values.lazy.filter { $0 == taskSessionID }.count
            )
            guard max(observedTaskQueueDepth, controlledTask)
                < UInt64(policy.maximumPromptQueueDepthPerTask) else {
                return rejection(
                    .taskPromptQueueFull,
                    "This task's prompt queue is full; wait for its current turn or queued prompts to drain."
                )
            }

            let reservationID = UUID()
            promptWork[reservationID] = taskSessionID
            recordRates(callerDigest: callerDigest, isCreate: false, now: now)
            return MCPAdmissionDecision(
                outcome: .admitted,
                code: .admitted,
                detail: "Prompt admitted to the bounded task queue.",
                reservationID: reservationID,
                taskSessionID: taskSessionID
            )
        }
    }

    @discardableResult
    public func markPromptFinished(reservationID: UUID) -> Bool {
        withLock {
            promptWork.removeValue(forKey: reservationID) != nil
        }
    }

    @discardableResult
    public func cancelPrompt(reservationID: UUID) -> Bool {
        markPromptFinished(reservationID: reservationID)
    }

    /// Admission for non-create, non-prompt MCP mutations such as explicit
    /// reconcile/end operations. It consumes the caller's write-rate budget.
    public func admitWrite(
        callerIdentity: String?,
        resources: ConduitResourceSnapshot,
        now: Date = Date()
    ) -> MCPAdmissionDecision {
        withLock {
            if let decision = baseRejection(
                callerIdentity: callerIdentity,
                resources: resources,
                now: now
            ) {
                return decision
            }
            guard let callerDigest = callerDigest(callerIdentity) else {
                return rejection(
                    .callerIdentityRequired,
                    "A bounded caller identity is required for MCP writes."
                )
            }
            if let rateDecision = rateRejection(
                callerDigest: callerDigest,
                kind: .write,
                now: now
            ) {
                return rateDecision
            }
            recordRates(callerDigest: callerDigest, isCreate: false, now: now)
            return MCPAdmissionDecision(
                outcome: .admitted,
                code: .admitted,
                detail: "Write admitted by caller and resource policy."
            )
        }
    }

    public func stateSnapshot() -> MCPAdmissionStateSnapshot {
        withLock {
            MCPAdmissionStateSnapshot(
                liveTaskSessionIDs: liveTaskSessionIDs,
                pendingCreateReservationCount: createReservations.count,
                queuedPromptCount: promptWork.count,
                idempotencyEntryCount: idempotencyEntries.count
            )
        }
    }

    private enum RateKind {
        case create
        case write
    }

    private func baseRejection(
        callerIdentity: String?,
        resources: ConduitResourceSnapshot,
        now: Date
    ) -> MCPAdmissionDecision? {
        guard policy.isValid else {
            return rejection(
                .configurationInvalid,
                "MCP admission policy is invalid; fix configuration before enabling writes."
            )
        }
        guard policy.writesEnabled else {
            return rejection(
                .writesDisabled,
                "MCP write tools are disabled; an operator must explicitly enable them."
            )
        }
        if let callerIdentity {
            guard callerIdentity.utf8.count <= policy.maximumCallerIdentityBytes else {
                return rejection(
                    .callerIdentityTooLarge,
                    "Caller identity exceeds the bounded admission limit."
                )
            }
        } else if policy.requireCallerIdentity {
            return rejection(
                .callerIdentityRequired,
                "Caller identity is unavailable; MCP writes fail closed."
            )
        }
        if policy.requireCallerIdentity,
           callerIdentity?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            != false {
            return rejection(
                .callerIdentityRequired,
                "Caller identity is empty; MCP writes fail closed."
            )
        }

        let resourceDecision = resourceCircuitBreaker.evaluate(resources, now: now)
        guard resourceDecision.allowsNewWork else {
            let code: MCPAdmissionDecisionCode
            switch resourceDecision.code {
            case .measurementUnknown:
                code = .resourceUnknown
            case .measurementStale:
                code = .resourceStale
            case .thresholdExceeded:
                code = .resourceLimitExceeded
            case .configurationInvalid:
                code = .configurationInvalid
            case .allow:
                code = .resourceLimitExceeded
            }
            return MCPAdmissionDecision(
                outcome: .rejected,
                code: code,
                detail: "Resource circuit breaker is open; inspect bounded resource violations before retrying.",
                resourceViolations: resourceDecision.violations
            )
        }
        return nil
    }

    private func callerDigest(_ callerIdentity: String?) -> String? {
        if let callerIdentity,
           !callerIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ConduitSafetyHash.digest(
                namespace: "mcp-rate-caller",
                bytes: callerIdentity.utf8
            )
        }
        if policy.requireCallerIdentity { return nil }
        return ConduitSafetyHash.digest(
            namespace: "mcp-rate-caller",
            bytes: "anonymous".utf8
        )
    }

    private func rateRejection(
        callerDigest: String,
        kind: RateKind,
        now: Date
    ) -> MCPAdmissionDecision? {
        var bucket = rateBuckets[callerDigest] ?? RateBucket()
        let cutoff = now.addingTimeInterval(-policy.rateWindow)
        bucket.creates.removeAll { $0 <= cutoff }
        bucket.writes.removeAll { $0 <= cutoff }
        rateBuckets[callerDigest] = bucket

        if kind == .create,
           bucket.creates.count >= policy.perCallerCreateLimit {
            return rejection(
                .callerCreateRateLimited,
                "Caller create-rate limit reached; retry after the current window.",
                retryAfterSeconds: retryAfter(
                    timestamps: bucket.creates,
                    now: now
                )
            )
        }
        if bucket.writes.count >= policy.perCallerWriteLimit {
            return rejection(
                .callerWriteRateLimited,
                "Caller write-rate limit reached; retry after the current window.",
                retryAfterSeconds: retryAfter(
                    timestamps: bucket.writes,
                    now: now
                )
            )
        }
        return nil
    }

    private func recordRates(
        callerDigest: String,
        isCreate: Bool,
        now: Date
    ) {
        var bucket = rateBuckets[callerDigest] ?? RateBucket()
        if isCreate { bucket.creates.append(now) }
        bucket.writes.append(now)
        rateBuckets[callerDigest] = bucket
    }

    private func retryAfter(timestamps: [Date], now: Date) -> TimeInterval? {
        guard let oldest = timestamps.min() else { return nil }
        return max(
            0,
            oldest.addingTimeInterval(policy.rateWindow).timeIntervalSince(now)
        )
    }

    private func pruneIdempotencyEntries(now: Date) {
        let cutoff = now.addingTimeInterval(-policy.idempotencyRetention)
        idempotencyEntries = idempotencyEntries.filter { _, entry in
            switch entry.state {
            case .pending:
                return true
            case .completed:
                return entry.updatedAt > cutoff
            }
        }
    }

    private func rejection(
        _ code: MCPAdmissionDecisionCode,
        _ detail: String,
        retryAfterSeconds: TimeInterval? = nil
    ) -> MCPAdmissionDecision {
        MCPAdmissionDecision(
            outcome: .rejected,
            code: code,
            detail: detail,
            retryAfterSeconds: retryAfterSeconds
        )
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

// MARK: - Exclusive runtime-directory ownership

public struct RuntimeDirectoryOwnerIdentity: Codable, Equatable, Sendable {
    public let ownerID: UUID
    public let processID: Int32
    public let hostName: String
    public let ownerLabel: String
    public let acquiredAt: Date

    public init(
        ownerID: UUID,
        processID: Int32,
        hostName: String,
        ownerLabel: String,
        acquiredAt: Date
    ) {
        self.ownerID = ownerID
        self.processID = processID
        self.hostName = String(hostName.prefix(128))
        self.ownerLabel = String(ownerLabel.prefix(80))
        self.acquiredAt = acquiredAt
    }
}

public enum RuntimeDirectoryOwnerEvent: String, Codable, Sendable {
    case acquired
    case released
    case recoveredStaleMetadata = "recovered_stale_metadata"
    case recoveredCorruptMetadata = "recovered_corrupt_metadata"
}

public struct RuntimeDirectoryOwnerHistoryRecord: Codable, Equatable, Sendable {
    public let event: RuntimeDirectoryOwnerEvent
    public let owner: RuntimeDirectoryOwnerIdentity
    public let occurredAt: Date
    public let previousOwnerID: UUID?
    public let detail: String

    public init(
        event: RuntimeDirectoryOwnerEvent,
        owner: RuntimeDirectoryOwnerIdentity,
        occurredAt: Date,
        previousOwnerID: UUID? = nil,
        detail: String
    ) {
        self.event = event
        self.owner = owner
        self.occurredAt = occurredAt
        self.previousOwnerID = previousOwnerID
        self.detail = String(detail.prefix(240))
    }
}

public struct RuntimeDirectoryOwnerRefusal: Equatable, Sendable {
    public let runtimeDirectory: URL
    public let lockFile: URL
    public let currentOwner: RuntimeDirectoryOwnerIdentity?
    public let detail: String
    public let recoverySteps: [String]

    public init(
        runtimeDirectory: URL,
        lockFile: URL,
        currentOwner: RuntimeDirectoryOwnerIdentity?,
        detail: String,
        recoverySteps: [String]
    ) {
        self.runtimeDirectory = runtimeDirectory
        self.lockFile = lockFile
        self.currentOwner = currentOwner
        self.detail = detail
        self.recoverySteps = recoverySteps
    }
}

public enum RuntimeDirectoryOwnerLockError: Error, Equatable, Sendable {
    case alreadyOwned(RuntimeDirectoryOwnerRefusal)
    case fileSystem(operation: String, path: String, code: Int32)
}

extension RuntimeDirectoryOwnerLockError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .alreadyOwned(let refusal):
            return refusal.detail
        case .fileSystem(let operation, let path, let code):
            return "\(operation) failed for \(path): \(String(cString: strerror(code))) (errno \(code))."
        }
    }
}

/// Holds a nonblocking POSIX `flock` for one runtime directory. The lock file
/// is never deleted. Owner transitions are appended to a separate JSONL history
/// so a crashed owner's stale metadata is recoverable without rewriting it.
public final class RuntimeDirectoryOwnerLock: @unchecked Sendable {
    public static let lockFileName = ".conduit-owner.lock"
    public static let historyFileName = ".conduit-owner-history.jsonl"

    public let runtimeDirectory: URL
    public let lockFile: URL
    public let historyFile: URL
    public let owner: RuntimeDirectoryOwnerIdentity

    private let stateLock = NSLock()
    private var descriptor: Int32
    private var isReleased = false

    private init(
        runtimeDirectory: URL,
        lockFile: URL,
        historyFile: URL,
        owner: RuntimeDirectoryOwnerIdentity,
        descriptor: Int32
    ) {
        self.runtimeDirectory = runtimeDirectory
        self.lockFile = lockFile
        self.historyFile = historyFile
        self.owner = owner
        self.descriptor = descriptor
    }

    deinit {
        try? release()
    }

    public static func acquire(
        runtimeDirectory requestedDirectory: URL,
        ownerLabel: String = "Conduit",
        ownerID: UUID = UUID(),
        processID: Int32 = getpid(),
        hostName: String = ProcessInfo.processInfo.hostName,
        now: Date = Date()
    ) throws -> RuntimeDirectoryOwnerLock {
        do {
            try FileManager.default.createDirectory(
                at: requestedDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw fileSystemError(
                operation: "Create runtime directory",
                url: requestedDirectory,
                fallbackCode: EIO
            )
        }

        let runtimeDirectory = requestedDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let lockFile = runtimeDirectory.appendingPathComponent(lockFileName)
        let historyFile = runtimeDirectory.appendingPathComponent(historyFileName)
        let descriptor = lockFile.path.withCString {
            Darwin.open(
                $0,
                O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard descriptor >= 0 else {
            throw fileSystemError(operation: "Open owner lock", url: lockFile)
        }

        do {
            try validateRegularFile(descriptor: descriptor, url: lockFile)
            guard Darwin.fchmod(
                descriptor,
                mode_t(S_IRUSR | S_IWUSR)
            ) == 0 else {
                throw fileSystemError(operation: "Protect owner lock", url: lockFile)
            }

            while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                let code = errno
                if code == EINTR { continue }
                if code == EWOULDBLOCK || code == EAGAIN {
                    let inspection = recentHistoryInspection(
                        historyFile: historyFile,
                        maximumBytes: 65_536
                    )
                    let currentOwner = currentOwner(from: inspection.records)
                    _ = Darwin.close(descriptor)
                    let ownerDescription: String
                    if let currentOwner {
                        ownerDescription = "owner \(currentOwner.ownerLabel) pid \(currentOwner.processID)"
                    } else {
                        ownerDescription = "an owner whose metadata is unavailable"
                    }
                    throw RuntimeDirectoryOwnerLockError.alreadyOwned(
                        RuntimeDirectoryOwnerRefusal(
                            runtimeDirectory: runtimeDirectory,
                            lockFile: lockFile,
                            currentOwner: currentOwner,
                            detail: "Conduit refused shared-state ownership because \(ownerDescription) holds the runtime lock.",
                            recoverySteps: [
                                "Bring the existing Conduit instance forward or close it normally.",
                                "Verify the recorded PID before terminating an unresponsive owner.",
                                "Do not delete the lock or history files; retry after the OS releases the flock."
                            ]
                        )
                    )
                }
                throw fileSystemError(
                    operation: "Acquire owner lock",
                    url: lockFile,
                    code: code
                )
            }

            let owner = RuntimeDirectoryOwnerIdentity(
                ownerID: ownerID,
                processID: processID,
                hostName: hostName,
                ownerLabel: ownerLabel,
                acquiredAt: now
            )
            let acquiredLock = RuntimeDirectoryOwnerLock(
                runtimeDirectory: runtimeDirectory,
                lockFile: lockFile,
                historyFile: historyFile,
                owner: owner,
                descriptor: descriptor
            )
            do {
                try acquiredLock.appendRecoveryAndAcquisition(now: now)
            } catch {
                _ = flock(descriptor, LOCK_UN)
                _ = Darwin.close(descriptor)
                acquiredLock.isReleased = true
                throw error
            }
            return acquiredLock
        } catch {
            if case RuntimeDirectoryOwnerLockError.alreadyOwned = error {
                throw error
            }
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    public func release(now: Date = Date()) throws {
        stateLock.lock()
        guard !isReleased else {
            stateLock.unlock()
            return
        }
        isReleased = true
        let descriptorToClose = descriptor
        stateLock.unlock()

        var historyError: Error?
        do {
            try Self.appendHistoryRecord(
                RuntimeDirectoryOwnerHistoryRecord(
                    event: .released,
                    owner: owner,
                    occurredAt: now,
                    detail: "Runtime-directory ownership released."
                ),
                to: historyFile
            )
        } catch {
            historyError = error
        }
        _ = flock(descriptorToClose, LOCK_UN)
        _ = Darwin.close(descriptorToClose)
        if let historyError { throw historyError }
    }

    public static func readRecentHistory(
        runtimeDirectory: URL,
        maximumBytes: Int = 1_048_576
    ) -> [RuntimeDirectoryOwnerHistoryRecord] {
        recentHistoryInspection(
            historyFile: runtimeDirectory
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .appendingPathComponent(historyFileName),
            maximumBytes: max(1, maximumBytes)
        ).records
    }

    private func appendRecoveryAndAcquisition(now: Date) throws {
        let inspection = Self.recentHistoryInspection(
            historyFile: historyFile,
            maximumBytes: 65_536
        )
        if inspection.hasMalformedTail {
            try Self.appendHistoryRecord(
                RuntimeDirectoryOwnerHistoryRecord(
                    event: .recoveredCorruptMetadata,
                    owner: owner,
                    occurredAt: now,
                    detail: "Recovered actual flock ownership while preserving malformed trailing owner metadata."
                ),
                to: historyFile
            )
        } else if let previousOwner = Self.currentOwner(from: inspection.records),
                  previousOwner.ownerID != owner.ownerID {
            try Self.appendHistoryRecord(
                RuntimeDirectoryOwnerHistoryRecord(
                    event: .recoveredStaleMetadata,
                    owner: owner,
                    occurredAt: now,
                    previousOwnerID: previousOwner.ownerID,
                    detail: "Recovered actual flock ownership after an unclosed prior owner record."
                ),
                to: historyFile
            )
        }
        try Self.appendHistoryRecord(
            RuntimeDirectoryOwnerHistoryRecord(
                event: .acquired,
                owner: owner,
                occurredAt: now,
                detail: "Runtime-directory ownership acquired."
            ),
            to: historyFile
        )
    }

    private struct HistoryInspection {
        let records: [RuntimeDirectoryOwnerHistoryRecord]
        let hasMalformedTail: Bool
    }

    private static func currentOwner(
        from records: [RuntimeDirectoryOwnerHistoryRecord]
    ) -> RuntimeDirectoryOwnerIdentity? {
        guard let last = records.last else { return nil }
        switch last.event {
        case .acquired:
            return last.owner
        case .released:
            return nil
        case .recoveredStaleMetadata, .recoveredCorruptMetadata:
            return last.owner
        }
    }

    private static func recentHistoryInspection(
        historyFile: URL,
        maximumBytes: Int
    ) -> HistoryInspection {
        let descriptor = historyFile.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            return HistoryInspection(records: [], hasMalformedTail: false)
        }
        defer { _ = Darwin.close(descriptor) }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              status.st_size > 0 else {
            return HistoryInspection(records: [], hasMalformedTail: false)
        }

        let byteCount = min(Int(status.st_size), max(1, maximumBytes))
        let offset = max(off_t(0), status.st_size - off_t(byteCount))
        var data = Data(count: byteCount)
        let readCount: Int = data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return 0 }
            var total = 0
            while total < byteCount {
                let count = Darwin.pread(
                    descriptor,
                    base.advanced(by: total),
                    byteCount - total,
                    offset + off_t(total)
                )
                if count > 0 {
                    total += count
                    continue
                }
                if count < 0, errno == EINTR { continue }
                break
            }
            return total
        }
        data = data.prefix(readCount)
        if offset > 0, let firstNewline = data.firstIndex(of: UInt8(ascii: "\n")) {
            data = data[data.index(after: firstNewline)...]
        }

        let hasTerminatingNewline = data.last == UInt8(ascii: "\n")
        let lines = data.split(separator: UInt8(ascii: "\n"),
                               omittingEmptySubsequences: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var records: [RuntimeDirectoryOwnerHistoryRecord] = []
        var malformed = false
        for (index, line) in lines.enumerated() {
            do {
                records.append(
                    try decoder.decode(
                        RuntimeDirectoryOwnerHistoryRecord.self,
                        from: Data(line)
                    )
                )
            } catch {
                if index == lines.count - 1 { malformed = true }
            }
        }
        if !hasTerminatingNewline { malformed = true }
        return HistoryInspection(records: records, hasMalformedTail: malformed)
    }

    private static func appendHistoryRecord(
        _ record: RuntimeDirectoryOwnerHistoryRecord,
        to historyFile: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(record)
        data.append(UInt8(ascii: "\n"))

        let descriptor = historyFile.path.withCString {
            Darwin.open(
                $0,
                O_RDWR | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard descriptor >= 0 else {
            throw fileSystemError(operation: "Open owner history", url: historyFile)
        }
        defer { _ = Darwin.close(descriptor) }
        try validateRegularFile(descriptor: descriptor, url: historyFile)
        guard Darwin.fchmod(
            descriptor,
            mode_t(S_IRUSR | S_IWUSR)
        ) == 0 else {
            throw fileSystemError(operation: "Protect owner history", url: historyFile)
        }
        while flock(descriptor, LOCK_EX) != 0 {
            let code = errno
            if code == EINTR { continue }
            throw fileSystemError(
                operation: "Lock owner history",
                url: historyFile,
                code: code
            )
        }
        defer { _ = flock(descriptor, LOCK_UN) }

        let size = Darwin.lseek(descriptor, 0, SEEK_END)
        if size > 0 {
            var finalByte: UInt8 = 0
            if Darwin.pread(descriptor, &finalByte, 1, size - 1) == 1,
               finalByte != UInt8(ascii: "\n") {
                try writeAll(Data([UInt8(ascii: "\n")]),
                             descriptor: descriptor,
                             url: historyFile)
            }
        }
        try writeAll(data, descriptor: descriptor, url: historyFile)
        guard Darwin.fsync(descriptor) == 0 else {
            throw fileSystemError(operation: "Sync owner history", url: historyFile)
        }
    }

    private static func validateRegularFile(
        descriptor: Int32,
        url: URL
    ) throws {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw fileSystemError(operation: "Inspect owner file", url: url)
        }
        guard (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw RuntimeDirectoryOwnerLockError.fileSystem(
                operation: "Owner path is not a regular file",
                path: url.path,
                code: EINVAL
            )
        }
    }

    private static func fileSystemError(
        operation: String,
        url: URL,
        code: Int32? = nil,
        fallbackCode: Int32 = EIO
    ) -> RuntimeDirectoryOwnerLockError {
        RuntimeDirectoryOwnerLockError.fileSystem(
            operation: operation,
            path: url.path,
            code: code ?? (errno == 0 ? fallbackCode : errno)
        )
    }

    private static func writeAll(
        _ data: Data,
        descriptor: Int32,
        url: URL
    ) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: written),
                    buffer.count - written
                )
                if count > 0 {
                    written += count
                    continue
                }
                let code = count < 0 ? errno : EIO
                if code == EINTR { continue }
                throw fileSystemError(
                    operation: "Append owner history",
                    url: url,
                    code: code
                )
            }
        }
    }
}
