import XCTest
@testable import ConduitCore

/// Coverage for the admission boundary wired in D-041.
///
/// Mirrors the deterministic cases in `Sources/ConduitSelfTest`, which is the
/// suite that runs on Command Line Tools only. Keep the two in step.
final class MCPAdmissionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_787_100_000)

    private var sampledMetrics: Set<ConduitResourceMetric> {
        [.availablePhysicalMemoryBytes, .ownedProcessTreeRSSBytes, .promptQueueDepth]
    }

    /// Healthy readings for the three metrics Conduit samples. Persistence
    /// queue depth stays `.unknown` because there is no queue to measure.
    private func sampledResources(
        availableBytes: UInt64 = 8_589_934_592,
        ownedRSSBytes: UInt64 = 1_073_741_824,
        promptDepth: UInt64 = 0,
        observedAt: Date? = nil
    ) -> ConduitResourceSnapshot {
        let stamp = observedAt ?? now
        return ConduitResourceSnapshot(
            availablePhysicalMemoryBytes: .known(value: availableBytes, observedAt: stamp),
            ownedProcessTreeRSSBytes: .known(value: ownedRSSBytes, observedAt: stamp),
            persistenceQueueCount: .unknown,
            persistenceQueueBytes: .unknown,
            promptQueueDepth: .known(value: promptDepth, observedAt: stamp)
        )
    }

    private func policy(
        writesEnabled: Bool = true,
        requireCallerIdentity: Bool = true,
        requireCreateIdempotency: Bool = false,
        globalLiveTaskLimit: Int = 4,
        maximumPendingCreateReservations: Int = 2,
        maximumGlobalPromptQueueDepth: Int = 16,
        maximumPromptQueueDepthPerTask: Int = 4,
        perCallerCreateLimit: Int = 64,
        perCallerWriteLimit: Int = 256,
        requiredMetrics: Set<ConduitResourceMetric>? = nil
    ) -> MCPAdmissionPolicy {
        MCPAdmissionPolicy(
            writesEnabled: writesEnabled,
            requireCallerIdentity: requireCallerIdentity,
            requireCreateIdempotency: requireCreateIdempotency,
            globalLiveTaskLimit: globalLiveTaskLimit,
            maximumPendingCreateReservations: maximumPendingCreateReservations,
            maximumGlobalPromptQueueDepth: maximumGlobalPromptQueueDepth,
            maximumPromptQueueDepthPerTask: maximumPromptQueueDepthPerTask,
            perCallerCreateLimit: perCallerCreateLimit,
            perCallerWriteLimit: perCallerWriteLimit,
            resourcePolicy: ConduitResourceCircuitPolicy(
                requiredMetrics: requiredMetrics ?? sampledMetrics
            )
        )
    }

    private func create(
        _ controller: MCPAdmissionController,
        caller: String? = "chatgpt-developer-mode/1.0",
        dedupe: MCPCreateDedupeIdentity? = nil,
        resources: ConduitResourceSnapshot? = nil,
        at instant: Date? = nil
    ) -> MCPAdmissionDecision {
        let stamp = instant ?? now
        return controller.admitCreate(
            callerIdentity: caller,
            dedupeIdentity: dedupe,
            resources: resources ?? sampledResources(observedAt: stamp),
            now: stamp
        )
    }

    // MARK: - Fail-closed gates

    func testWritesDisabledRefusesEverything() {
        XCTAssertEqual(
            create(MCPAdmissionController(policy: policy(writesEnabled: false))).code,
            .writesDisabled
        )
    }

    func testCallerIdentityIsRequired() {
        XCTAssertEqual(
            create(MCPAdmissionController(policy: policy()), caller: nil).code,
            .callerIdentityRequired
        )
        XCTAssertEqual(
            create(MCPAdmissionController(policy: policy()), caller: "   ").code,
            .callerIdentityRequired
        )
        XCTAssertEqual(
            create(
                MCPAdmissionController(policy: policy()),
                caller: String(repeating: "c", count: 257)
            ).code,
            .callerIdentityTooLarge
        )
    }

    func testPolicyWithNoRequiredMetricIsInvalid() {
        XCTAssertEqual(
            create(MCPAdmissionController(policy: policy(requiredMetrics: []))).code,
            .configurationInvalid
        )
    }

    // MARK: - Resource circuit

    func testUnknownRequiredMetricRefusesWrite() {
        XCTAssertEqual(
            create(MCPAdmissionController(policy: policy()), resources: .unknown).code,
            .resourceUnknown
        )
    }

    func testUnsampledMetricIsIgnored() {
        XCTAssertEqual(
            create(MCPAdmissionController(policy: policy())).outcome,
            .admitted
        )
    }

    func testStaleSampleRefusesWrite() {
        XCTAssertEqual(
            create(
                MCPAdmissionController(policy: policy()),
                resources: sampledResources(observedAt: now.addingTimeInterval(-45))
            ).code,
            .resourceStale
        )
    }

    func testThresholdsRefuseWriteAndNameTheMetric() {
        let lowMemory = create(
            MCPAdmissionController(policy: policy()),
            resources: sampledResources(availableBytes: 536_870_912)
        )
        XCTAssertEqual(lowMemory.code, .resourceLimitExceeded)
        XCTAssertTrue(
            lowMemory.resourceViolations.contains {
                $0.metric == .availablePhysicalMemoryBytes
                    && $0.code == .thresholdExceeded
            }
        )
        XCTAssertEqual(
            create(
                MCPAdmissionController(policy: policy()),
                resources: sampledResources(ownedRSSBytes: 8_589_934_592)
            ).code,
            .resourceLimitExceeded
        )
    }

    // MARK: - Capacity

    func testPendingCreateReservesCapacity() {
        let controller = MCPAdmissionController(policy: policy(globalLiveTaskLimit: 1))
        XCTAssertEqual(create(controller).outcome, .admitted)
        XCTAssertEqual(create(controller).code, .globalLiveTaskLimitReached)
    }

    func testPendingCreateQueueIsBounded() {
        let controller = MCPAdmissionController(
            policy: policy(globalLiveTaskLimit: 8, maximumPendingCreateReservations: 1)
        )
        _ = create(controller)
        XCTAssertEqual(create(controller).code, .createReservationQueueFull)
    }

    func testCancellingACreateReturnsTheSlot() throws {
        let controller = MCPAdmissionController(policy: policy(globalLiveTaskLimit: 1))
        let first = create(controller)
        let reservation = try XCTUnwrap(first.reservationID)
        XCTAssertTrue(controller.cancelCreate(reservationID: reservation))
        XCTAssertEqual(create(controller).outcome, .admitted)
    }

    func testCapacityIsHeldUntilTaskIsExplicitlyEnded() throws {
        let controller = MCPAdmissionController(policy: policy(globalLiveTaskLimit: 1))
        let task = TaskSessionID()
        let first = create(controller)
        controller.commitCreate(
            reservationID: try XCTUnwrap(first.reservationID),
            taskSessionID: task
        )
        XCTAssertEqual(create(controller).code, .globalLiveTaskLimitReached)
        controller.markTaskEnded(task)
        XCTAssertEqual(create(controller).outcome, .admitted)
    }

    func testRestartReconciliationRestoresOccupiedCapacity() {
        let controller = MCPAdmissionController(policy: policy(globalLiveTaskLimit: 2))
        controller.reconcileLiveTasks(additive: [TaskSessionID(), TaskSessionID()])
        XCTAssertEqual(create(controller).code, .globalLiveTaskLimitReached)
    }

    // MARK: - Rate

    func testCreateRateIsBoundedPerCallerAndDrains() {
        let controller = MCPAdmissionController(
            policy: policy(
                globalLiveTaskLimit: 32,
                maximumPendingCreateReservations: 32,
                perCallerCreateLimit: 2
            )
        )
        _ = create(controller)
        _ = create(controller)
        let refused = create(controller)
        XCTAssertEqual(refused.code, .callerCreateRateLimited)
        XCTAssertGreaterThan(refused.retryAfterSeconds ?? 0, 0)
        XCTAssertEqual(
            create(controller, at: now.addingTimeInterval(61)).outcome,
            .admitted
        )
    }

    func testWriteRateIsBounded() {
        let controller = MCPAdmissionController(policy: policy(perCallerWriteLimit: 1))
        _ = controller.admitWrite(
            callerIdentity: "chatgpt-developer-mode/1.0",
            resources: sampledResources(),
            now: now
        )
        XCTAssertEqual(
            controller.admitWrite(
                callerIdentity: "chatgpt-developer-mode/1.0",
                resources: sampledResources(),
                now: now
            ).code,
            .callerWriteRateLimited
        )
    }

    func testRateBudgetIsPerCaller() {
        let controller = MCPAdmissionController(policy: policy(perCallerCreateLimit: 1))
        _ = create(controller, caller: "chatgpt-developer-mode/1.0")
        XCTAssertEqual(
            create(controller, caller: "conduit-preflight/1.0").outcome,
            .admitted
        )
    }

    func testSharedBearerClientInfoRotationDoesNotRefillCreateBudget() throws {
        let controller = MCPAdmissionController(policy: policy(perCallerCreateLimit: 1))
        let first = ConduitSessionCaller.authenticatedBySharedBearer(
            clientInfo: "fixture-a/1", observedAt: now
        )
        let rotated = ConduitSessionCaller.authenticatedBySharedBearer(
            clientInfo: "fixture-b/2", observedAt: now.addingTimeInterval(1)
        )
        let reservation = try XCTUnwrap(create(controller, caller: first.identity).reservationID)
        XCTAssertTrue(controller.cancelCreate(reservationID: reservation))
        XCTAssertEqual(create(controller, caller: rotated.identity).code, .callerCreateRateLimited)
        XCTAssertEqual(controller.stateSnapshot().pendingCreateReservationCount, 0)
    }

    func testSharedBearerClientInfoAndAuditTimeDoNotRefillWriteBudget() {
        let controller = MCPAdmissionController(policy: policy(perCallerWriteLimit: 1))
        let first = ConduitSessionCaller.authenticatedBySharedBearer(
            clientInfo: "fixture-a/1", observedAt: now
        )
        let rotated = ConduitSessionCaller.authenticatedBySharedBearer(
            clientInfo: "fixture-b/2", observedAt: now.addingTimeInterval(3_600)
        )
        XCTAssertEqual(controller.admitWrite(
            callerIdentity: first.identity, resources: sampledResources(), now: now
        ).code, .admitted)
        XCTAssertEqual(controller.admitWrite(
            callerIdentity: rotated.identity, resources: sampledResources(), now: now
        ).code, .callerWriteRateLimited)
        let uninitialized = ConduitSessionCaller.authenticatedBySharedBearer(
            clientInfo: nil, observedAt: now
        )
        XCTAssertEqual(controller.admitWrite(
            callerIdentity: uninitialized.identity, resources: sampledResources(), now: now
        ).code, .callerIdentityRequired)
        let drainedAt = now.addingTimeInterval(61)
        XCTAssertEqual(controller.admitWrite(
            callerIdentity: rotated.identity,
            resources: sampledResources(observedAt: drainedAt), now: drainedAt
        ).code, .admitted)
    }

    func testSharedBearerCreateStillConsumesTheSameWriteBudget() throws {
        let controller = MCPAdmissionController(policy: policy(perCallerWriteLimit: 1))
        let first = ConduitSessionCaller.authenticatedBySharedBearer(clientInfo: "fixture-a/1", observedAt: now)
        let rotated = ConduitSessionCaller.authenticatedBySharedBearer(clientInfo: "fixture-b/2", observedAt: now)
        let reservation = try XCTUnwrap(create(controller, caller: first.identity).reservationID)
        XCTAssertTrue(controller.cancelCreate(reservationID: reservation))
        XCTAssertEqual(controller.admitWrite(
            callerIdentity: rotated.identity, resources: sampledResources(), now: now
        ).code, .callerWriteRateLimited)
    }

    func testSharedBearerRotationPreservesSaturatedIdempotencyAndConflict() throws {
        let controller = MCPAdmissionController(policy: policy(perCallerCreateLimit: 1, perCallerWriteLimit: 1))
        let firstCaller = ConduitSessionCaller.authenticatedBySharedBearer(clientInfo: "fixture-a/1", observedAt: now)
        let rotated = ConduitSessionCaller.authenticatedBySharedBearer(clientInfo: "fixture-b/2", observedAt: now)
        let identity = MCPCreateDedupeIdentity(
            idempotencyKey: "fixture-retry",
            requestFingerprint: MCPCreateDedupeIdentity.fingerprint(
                canonicalComponents: ["conduit_create_task", "Shell", "fixture", "objective-digest"]
            )
        )
        let first = create(controller, caller: firstCaller.identity, dedupe: identity)
        let reservation = try XCTUnwrap(first.reservationID)
        let pending = create(controller, caller: rotated.identity, dedupe: identity)
        XCTAssertEqual(pending.code, .duplicatePending)
        XCTAssertFalse(pending.shouldExecute)
        let task = TaskSessionID()
        controller.commitCreate(reservationID: reservation, taskSessionID: task)
        let completed = create(controller, caller: rotated.identity, dedupe: identity)
        XCTAssertEqual(completed.code, .duplicateCompleted)
        XCTAssertEqual(completed.taskSessionID, task)
        XCTAssertTrue(completed.isRequestSatisfied)
        XCTAssertFalse(completed.shouldExecute)
        let conflicting = MCPCreateDedupeIdentity(
            idempotencyKey: "fixture-retry",
            requestFingerprint: MCPCreateDedupeIdentity.fingerprint(canonicalComponents: ["changed-request"])
        )
        XCTAssertEqual(create(controller, caller: rotated.identity, dedupe: conflicting).code, .idempotencyConflict)
        XCTAssertEqual(create(controller, caller: rotated.identity).code, .callerCreateRateLimited)
        XCTAssertEqual(controller.stateSnapshot().pendingCreateReservationCount, 0)
        XCTAssertEqual(controller.stateSnapshot().liveTaskSessionIDs, [task])
    }

    // MARK: - Idempotency

    func testIdempotentCreateDeduplicatesAndDetectsConflict() throws {
        let fingerprint = MCPCreateDedupeIdentity.fingerprint(
            canonicalComponents: ["conduit_create_task", "Shell", "conduit", "digest"]
        )
        let identity = MCPCreateDedupeIdentity(
            idempotencyKey: "retry-1",
            requestFingerprint: fingerprint
        )
        let controller = MCPAdmissionController(policy: policy())
        let first = create(controller, dedupe: identity)

        let pending = create(controller, dedupe: identity)
        XCTAssertEqual(pending.outcome, .deduplicated)
        XCTAssertEqual(pending.code, .duplicatePending)

        let task = TaskSessionID()
        controller.commitCreate(
            reservationID: try XCTUnwrap(first.reservationID),
            taskSessionID: task
        )
        let completed = create(controller, dedupe: identity)
        XCTAssertEqual(completed.code, .duplicateCompleted)
        XCTAssertEqual(completed.taskSessionID, task)
        XCTAssertTrue(completed.isRequestSatisfied)
        XCTAssertFalse(completed.shouldExecute)

        let conflicting = MCPCreateDedupeIdentity(
            idempotencyKey: "retry-1",
            requestFingerprint: MCPCreateDedupeIdentity.fingerprint(
                canonicalComponents: ["conduit_create_task", "Codex", "conduit", "digest"]
            )
        )
        XCTAssertEqual(
            create(controller, dedupe: conflicting).code,
            .idempotencyConflict
        )
    }

    func testFingerprintSeparatesComponentBoundaries() {
        XCTAssertNotEqual(
            MCPCreateDedupeIdentity.fingerprint(canonicalComponents: ["ab", "c"]),
            MCPCreateDedupeIdentity.fingerprint(canonicalComponents: ["a", "bc"])
        )
    }

    func testObjectiveDigestIsStable() {
        XCTAssertEqual(
            ConduitSafetyHash.digest(namespace: "mcp-create-objective", text: "reply pong"),
            ConduitSafetyHash.digest(namespace: "mcp-create-objective", text: "reply pong")
        )
    }

    func testCreateCanRequireAnIdempotencyKey() {
        XCTAssertEqual(
            create(
                MCPAdmissionController(policy: policy(requireCreateIdempotency: true))
            ).code,
            .invalidIdempotency
        )
    }

    // MARK: - Prompt queue

    func testPerTaskPromptQueueIsBounded() {
        let controller = MCPAdmissionController(
            policy: policy(maximumPromptQueueDepthPerTask: 2)
        )
        let task = TaskSessionID()
        for _ in 0..<2 {
            _ = controller.admitPrompt(
                callerIdentity: "chatgpt-developer-mode/1.0",
                taskSessionID: task,
                resources: sampledResources(),
                now: now
            )
        }
        XCTAssertEqual(
            controller.admitPrompt(
                callerIdentity: "chatgpt-developer-mode/1.0",
                taskSessionID: task,
                resources: sampledResources(),
                now: now
            ).code,
            .taskPromptQueueFull
        )
        XCTAssertEqual(
            controller.admitPrompt(
                callerIdentity: "chatgpt-developer-mode/1.0",
                taskSessionID: TaskSessionID(),
                resources: sampledResources(),
                now: now
            ).outcome,
            .admitted
        )
    }

    func testObservedQueueDepthCanRefuseAPrompt() {
        XCTAssertEqual(
            MCPAdmissionController(policy: policy(maximumGlobalPromptQueueDepth: 2))
                .admitPrompt(
                    callerIdentity: "chatgpt-developer-mode/1.0",
                    taskSessionID: TaskSessionID(),
                    resources: sampledResources(promptDepth: 2),
                    now: now
                ).code,
            .globalPromptQueueFull
        )
        XCTAssertEqual(
            MCPAdmissionController(policy: policy(maximumPromptQueueDepthPerTask: 1))
                .admitPrompt(
                    callerIdentity: "chatgpt-developer-mode/1.0",
                    taskSessionID: TaskSessionID(),
                    observedTaskQueueDepth: 1,
                    resources: sampledResources(),
                    now: now
                ).code,
            .taskPromptQueueFull
        )
    }

    func testFinishingAPromptReturnsItsSlot() throws {
        let controller = MCPAdmissionController(
            policy: policy(maximumPromptQueueDepthPerTask: 1)
        )
        let task = TaskSessionID()
        let admitted = controller.admitPrompt(
            callerIdentity: "chatgpt-developer-mode/1.0",
            taskSessionID: task,
            resources: sampledResources(),
            now: now
        )
        XCTAssertTrue(
            controller.markPromptFinished(
                reservationID: try XCTUnwrap(admitted.reservationID)
            )
        )
        XCTAssertEqual(
            controller.admitPrompt(
                callerIdentity: "chatgpt-developer-mode/1.0",
                taskSessionID: task,
                resources: sampledResources(),
                now: now
            ).outcome,
            .admitted
        )
    }

    // MARK: - Shipped policy

    /// Pinned so that loosening a limit is a deliberate edit with a failing
    /// test, not a quiet drift.
    func testShippedSessionAPIPolicy() {
        let shipped = MCPAdmissionPolicy.conduitSessionAPI(writesEnabled: true)
        XCTAssertEqual(shipped.globalLiveTaskLimit, 4)
        XCTAssertGreaterThanOrEqual(
            shipped.perCallerCreateLimit,
            shipped.globalLiveTaskLimit,
            "one caller should be able to fill the fleet in a single burst"
        )
        XCTAssertGreaterThan(
            shipped.perCallerWriteLimit,
            shipped.perCallerCreateLimit,
            "writes must leave headroom beyond the creates they include"
        )
        XCTAssertTrue(shipped.requireCallerIdentity)
        XCTAssertFalse(shipped.requireCreateIdempotency)
        XCTAssertEqual(
            shipped.resourcePolicy.requiredMetrics,
            [.availablePhysicalMemoryBytes, .ownedProcessTreeRSSBytes, .promptQueueDepth]
        )
        XCTAssertFalse(
            shipped.resourcePolicy.requiredMetrics.contains(.persistenceQueueCount)
        )
        XCTAssertFalse(
            shipped.resourcePolicy.requiredMetrics.contains(.persistenceQueueBytes)
        )
        XCTAssertTrue(shipped.isValid)
        XCTAssertFalse(
            MCPAdmissionPolicy.conduitSessionAPI(writesEnabled: false).writesEnabled
        )
    }

    // MARK: - Observability

    func testSnapshotReportsCommittedCapacity() throws {
        let controller = MCPAdmissionController(policy: policy())
        let task = TaskSessionID()
        let decision = create(controller)
        controller.commitCreate(
            reservationID: try XCTUnwrap(decision.reservationID),
            taskSessionID: task
        )
        let snapshot = controller.stateSnapshot()
        XCTAssertEqual(snapshot.liveTaskSessionIDs, [task])
        XCTAssertEqual(snapshot.pendingCreateReservationCount, 0)
    }
}
