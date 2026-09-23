import Foundation

/// Availability of one authority read used to build a Fleet response.
public enum FleetSourceAvailability: String, Codable, Equatable, Sendable {
    case available
    case partial
    case unavailable
    case unsupported
}

public struct FleetSourceSnapshot: Codable, Equatable, Sendable {
    public var source: String
    public var availability: FleetSourceAvailability
    public var recordCount: OrchestrationValue<Int>
    public var observation: SupervisionObservationStamp
    public var diagnostics: [String]

    public init(
        source: String,
        availability: FleetSourceAvailability,
        recordCount: OrchestrationValue<Int>,
        observation: SupervisionObservationStamp,
        diagnostics: [String] = []
    ) {
        self.source = source
        self.availability = availability
        self.recordCount = recordCount
        self.observation = observation
        self.diagnostics = diagnostics
    }
}

public enum FleetPendingInputState: String, Codable, Equatable, Sendable {
    case none
    case approval
    case unknown
}

/// Delivery and turn observations remain separate: queued input is not an
/// active provider turn, and a PTY output checkpoint is not a turn protocol.
public struct FleetTurnObservation: Codable, Equatable, Sendable {
    public var turn: OrchestrationValue<ConduitSessionTurnSnapshot>
    public var lastPromptDelivery: OrchestrationValue<PromptDeliveryState>
    public var pendingInput: OrchestrationValue<FleetPendingInputState>
    public var observation: SupervisionObservationStamp

    public init(
        turn: OrchestrationValue<ConduitSessionTurnSnapshot>,
        lastPromptDelivery: OrchestrationValue<PromptDeliveryState>,
        pendingInput: OrchestrationValue<FleetPendingInputState>,
        observation: SupervisionObservationStamp
    ) {
        self.turn = turn
        self.lastPromptDelivery = lastPromptDelivery
        self.pendingInput = pendingInput
        self.observation = observation
    }
}

public struct FleetThreadHandoffHandle: Codable, Equatable, Sendable {
    public var threadID: OrchestrationValue<String>
    public var backend: OrchestrationValue<String>
    public var observation: SupervisionObservationStamp

    public init(
        threadID: OrchestrationValue<String>,
        backend: OrchestrationValue<String>,
        observation: SupervisionObservationStamp
    ) {
        self.threadID = threadID
        self.backend = backend
        self.observation = observation
    }
}

/// One Conduit-owned task record. Persisted lifecycle and thread handles carry
/// stale observations until a live runtime or provider read re-establishes
/// currentness.
public struct ConduitFleetTaskSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var task: TaskSessionSnapshot
    public var relationship: WorkerRelationship
    public var runtimeAttemptID: OrchestrationValue<String>
    public var runtime: OrchestrationValue<String>
    public var lifecycle: OrchestrationValue<String>
    public var runtimeObservation: SupervisionObservationStamp
    public var providerSessionID: OrchestrationValue<String>
    public var providerBackend: OrchestrationValue<String>
    public var supersededThreadHandles: OrchestrationValue<[FleetThreadHandoffHandle]>
    public var providerHandleObservation: SupervisionObservationStamp
    public var model: OrchestrationValue<ProviderModelIdentity>
    public var modelObservation: SupervisionObservationStamp
    public var lastMeaningfulActivityAt: OrchestrationValue<Date>
    public var lastMeaningfulActivityObservation: SupervisionObservationStamp
    public var workspace: WorkerWorkspaceLineage
    public var turn: FleetTurnObservation
    public var processObservation: OrchestrationValue<ProcessTreeObservation>
    public var processReconciliation: OrchestrationValue<ProcessTreeReconciliation>
    public var heldPromptCount: OrchestrationValue<Int>
    public var terminal: WorkerTerminalState
    public var observation: SupervisionObservationStamp

    public init(
        schemaVersion: Int = ConduitFleetTaskSnapshot.currentSchemaVersion,
        task: TaskSessionSnapshot,
        relationship: WorkerRelationship,
        runtimeAttemptID: OrchestrationValue<String>,
        runtime: OrchestrationValue<String>,
        lifecycle: OrchestrationValue<String>,
        runtimeObservation: SupervisionObservationStamp,
        providerSessionID: OrchestrationValue<String>,
        providerBackend: OrchestrationValue<String> = .unknown,
        supersededThreadHandles: OrchestrationValue<[FleetThreadHandoffHandle]>,
        providerHandleObservation: SupervisionObservationStamp,
        model: OrchestrationValue<ProviderModelIdentity> = .unknown,
        modelObservation: SupervisionObservationStamp,
        lastMeaningfulActivityAt: OrchestrationValue<Date> = .unknown,
        lastMeaningfulActivityObservation: SupervisionObservationStamp,
        workspace: WorkerWorkspaceLineage,
        turn: FleetTurnObservation,
        processObservation: OrchestrationValue<ProcessTreeObservation>,
        processReconciliation: OrchestrationValue<ProcessTreeReconciliation>,
        heldPromptCount: OrchestrationValue<Int>,
        terminal: WorkerTerminalState,
        observation: SupervisionObservationStamp
    ) {
        self.schemaVersion = schemaVersion
        self.task = task
        self.relationship = relationship
        self.runtimeAttemptID = runtimeAttemptID
        self.runtime = runtime
        self.lifecycle = lifecycle
        self.runtimeObservation = runtimeObservation
        self.providerSessionID = providerSessionID
        self.providerBackend = providerBackend
        self.supersededThreadHandles = supersededThreadHandles
        self.providerHandleObservation = providerHandleObservation
        self.model = model
        self.modelObservation = modelObservation
        self.lastMeaningfulActivityAt = lastMeaningfulActivityAt
        self.lastMeaningfulActivityObservation = lastMeaningfulActivityObservation
        self.workspace = workspace
        self.turn = turn
        self.processObservation = processObservation
        self.processReconciliation = processReconciliation
        self.heldPromptCount = heldPromptCount
        self.terminal = terminal
        self.observation = observation
    }

    public static let currentSchemaVersion = 1
}

public enum FleetTaskAssociationKind: String, Codable, Equatable, Sendable {
    case unbound
    /// Exact task and runtime-attempt lineage; not a liveness or ownership claim.
    case exact
    case historical
    case ambiguous
    case identityMismatch = "identity_mismatch"
}

/// A task/session join is evidence in its own right. It does not turn provider
/// discovery into ownership or writer authority.
public struct FleetTaskAssociation: Codable, Equatable, Sendable {
    public var kind: FleetTaskAssociationKind
    public var taskSessionID: OrchestrationValue<String>
    public var runtimeAttemptID: OrchestrationValue<String>
    public var observation: SupervisionObservationStamp
    /// Freshness of the Conduit task/runtime identity used by this join.
    /// Provider observation freshness remains on `worker.observation`.
    public var taskIdentityObservation: SupervisionObservationStamp

    public init(
        kind: FleetTaskAssociationKind,
        taskSessionID: OrchestrationValue<String>,
        runtimeAttemptID: OrchestrationValue<String>,
        observation: SupervisionObservationStamp,
        taskIdentityObservation: SupervisionObservationStamp = SupervisionObservationStamp(
            authority: .unknown,
            freshness: .unknown,
            observedAt: .unknown
        )
    ) {
        self.kind = kind
        self.taskSessionID = taskSessionID
        self.runtimeAttemptID = runtimeAttemptID
        self.observation = observation
        self.taskIdentityObservation = taskIdentityObservation
    }
}

public struct FleetTaskIdentity: Codable, Equatable, Sendable {
    public var taskSessionID: String
    public var runtimeAttemptID: OrchestrationValue<String>
    public var observation: SupervisionObservationStamp

    public init(
        taskSessionID: String,
        runtimeAttemptID: OrchestrationValue<String>,
        observation: SupervisionObservationStamp = SupervisionObservationStamp(
            authority: .unknown,
            freshness: .unknown,
            observedAt: .unknown
        )
    ) {
        self.taskSessionID = taskSessionID
        self.runtimeAttemptID = runtimeAttemptID
        self.observation = observation
    }
}

/// Provider discovery and writer authority are returned separately. The
/// WorkerLineage keeps provider, process, turn, relationship, and acceptance
/// facts typed; this wrapper adds the independent Conduit writer registry and
/// exact task association.
public struct ConduitFleetProviderWorkerSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var worker: WorkerLineage
    public var writerAuthority: ProviderSessionAuthoritySnapshot
    public var writerAuthorityObservation: SupervisionObservationStamp
    public var taskAssociation: FleetTaskAssociation
    public var diagnostics: [String]

    public init(
        schemaVersion: Int = ConduitFleetProviderWorkerSnapshot.currentSchemaVersion,
        worker: WorkerLineage,
        writerAuthority: ProviderSessionAuthoritySnapshot,
        writerAuthorityObservation: SupervisionObservationStamp,
        taskAssociation: FleetTaskAssociation,
        diagnostics: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.worker = worker
        self.writerAuthority = writerAuthority
        self.writerAuthorityObservation = writerAuthorityObservation
        self.taskAssociation = taskAssociation
        self.diagnostics = diagnostics
    }

    public static let currentSchemaVersion = 1
}

/// Count evidence uses a lower bound plus an explicit unknown remainder. A
/// partial page or unsupported authority can never look like a complete zero.
public struct FleetCountObservation: Codable, Equatable, Sendable {
    public var knownCount: Int
    public var unknownCount: Int
    public var total: OrchestrationValue<Int>
    public var observation: SupervisionObservationStamp
    public var basis: String

    public init(
        knownCount: Int,
        unknownCount: Int,
        total: OrchestrationValue<Int>,
        observation: SupervisionObservationStamp,
        basis: String
    ) {
        self.knownCount = max(0, knownCount)
        self.unknownCount = max(0, unknownCount)
        self.total = total
        self.observation = observation
        self.basis = basis
    }
}

public struct ConduitTaskControlSlotSnapshot: Codable, Equatable, Sendable {
    public var used: OrchestrationValue<Int>
    public var limit: OrchestrationValue<Int>
    public var pendingCreateReservations: OrchestrationValue<Int>
    public var queuedPromptReservations: OrchestrationValue<Int>
    public var observation: SupervisionObservationStamp

    public init(
        used: OrchestrationValue<Int>,
        limit: OrchestrationValue<Int>,
        pendingCreateReservations: OrchestrationValue<Int>,
        queuedPromptReservations: OrchestrationValue<Int>,
        observation: SupervisionObservationStamp
    ) {
        self.used = used
        self.limit = limit
        self.pendingCreateReservations = pendingCreateReservations
        self.queuedPromptReservations = queuedPromptReservations
        self.observation = observation
    }
}

public struct ConduitFleetCapacitySnapshot: Codable, Equatable, Sendable {
    public var discoveredProviderSessions: FleetCountObservation
    public var supervisedProviderSessions: FleetCountObservation
    public var providerReportedActiveTurns: FleetCountObservation
    public var providerHosts: FleetCountObservation
    public var observedChildProcesses: FleetCountObservation
    public var taskControlSlots: ConduitTaskControlSlotSnapshot
    /// No provider-neutral global execution-slot authority exists in this
    /// slice. This remains UNKNOWN even when Conduit task slots are known.
    public var actualExecutionSlotOccupancy: OrchestrationValue<Int>
    public var actualExecutionSlotBasis: String
    public var resources: ConduitResourceSnapshot

    public init(
        discoveredProviderSessions: FleetCountObservation,
        supervisedProviderSessions: FleetCountObservation,
        providerReportedActiveTurns: FleetCountObservation,
        providerHosts: FleetCountObservation,
        observedChildProcesses: FleetCountObservation,
        taskControlSlots: ConduitTaskControlSlotSnapshot,
        actualExecutionSlotOccupancy: OrchestrationValue<Int> = .unknown,
        actualExecutionSlotBasis: String = "No provider-neutral execution-slot authority is available.",
        resources: ConduitResourceSnapshot
    ) {
        self.discoveredProviderSessions = discoveredProviderSessions
        self.supervisedProviderSessions = supervisedProviderSessions
        self.providerReportedActiveTurns = providerReportedActiveTurns
        self.providerHosts = providerHosts
        self.observedChildProcesses = observedChildProcesses
        self.taskControlSlots = taskControlSlots
        self.actualExecutionSlotOccupancy = actualExecutionSlotOccupancy
        self.actualExecutionSlotBasis = actualExecutionSlotBasis
        self.resources = resources
    }
}

/// One structured, bounded projection over existing Conduit and provider
/// authorities. It is rebuilt on read; it is not a parallel state database.
public struct ConduitFleetSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var observedAt: Date
    public var tasks: ConduitFleetPage<ConduitFleetTaskSnapshot>
    public var providerSessions: ConduitFleetPage<ConduitFleetProviderWorkerSnapshot>
    public var sources: [FleetSourceSnapshot]
    public var capacity: ConduitFleetCapacitySnapshot

    public init(
        schemaVersion: Int = ConduitFleetSnapshot.currentSchemaVersion,
        observedAt: Date,
        tasks: ConduitFleetPage<ConduitFleetTaskSnapshot>,
        providerSessions: ConduitFleetPage<ConduitFleetProviderWorkerSnapshot>,
        sources: [FleetSourceSnapshot],
        capacity: ConduitFleetCapacitySnapshot
    ) {
        self.schemaVersion = schemaVersion
        self.observedAt = observedAt
        self.tasks = tasks
        self.providerSessions = providerSessions
        self.sources = sources
        self.capacity = capacity
    }
}

public struct ConduitFleetPage<Item: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var items: [Item]
    public var total: OrchestrationValue<Int>
    public var returned: Int
    public var hasMore: OrchestrationValue<Bool>
    public var nextCursor: OrchestrationValue<String>
    public var cursorState: ConduitSessionEventCursorState
    public var observation: SupervisionObservationStamp

    public init(
        items: [Item],
        total: OrchestrationValue<Int>,
        returned: Int,
        hasMore: OrchestrationValue<Bool>,
        nextCursor: OrchestrationValue<String>,
        cursorState: ConduitSessionEventCursorState,
        observation: SupervisionObservationStamp
    ) {
        self.items = items
        self.total = total
        self.returned = max(0, returned)
        self.hasMore = hasMore
        self.nextCursor = nextCursor
        self.cursorState = cursorState
        self.observation = observation
    }
}

/// Pure joins and capacity accounting shared by the live projection and its
/// deterministic qualification fixtures. It does not claim writer authority,
/// infer process state, or turn provider discovery into execution occupancy.
public enum ConduitFleetSnapshotBuilder {
    /// Rebuilds the durable portion of one task row from current source reads.
    /// Persisted runtime/handle facts are deliberately stamped stale; callers
    /// may overlay exact live runtime observations without changing this base.
    public static func persistedTask(
        _ task: TaskSessionSnapshot,
        providerHandle: AdapterThreadRecord?,
        handleStoreAvailability: AdapterThreadStoreAvailability,
        observedAt: Date
    ) -> ConduitFleetTaskSnapshot {
        let taskStamp = SupervisionObservationStamp(
            authority: .conduitRecorded,
            freshness: .current,
            observedAt: .known(observedAt)
        )
        let attempt: RuntimeAttemptID?
        let lifecycle: String?
        switch task.operationalState {
        case .runtimeProvisioning(let id, _, _):
            attempt = id
            lifecycle = "provisioning"
        case .runtimeOpened(let id):
            attempt = id
            lifecycle = "runtime_opened"
        case .runtimeProvisioningFailed(let id, _, _, _):
            attempt = id
            lifecycle = "provisioning_failed"
        case .runtimeDetached(let id):
            attempt = id
            lifecycle = "detached"
        case .closed:
            attempt = nil
            lifecycle = "closed"
        case .interrupted(let id):
            attempt = id
            lifecycle = "interrupted"
        case nil:
            attempt = nil
            lifecycle = nil
        }
        let runtimeStamp = lifecycle.map { _ in
            SupervisionObservationStamp(
                authority: .conduitRecorded,
                freshness: .stale,
                observedAt: task.operationalStateAt.map(OrchestrationValue.known)
                    ?? .unknown
            )
        } ?? SupervisionObservationStamp(
            authority: .unknown,
            freshness: .unknown,
            observedAt: .unknown
        )
        let handleStamp = providerHandle.map {
            SupervisionObservationStamp(
                authority: .conduitRecorded,
                freshness: .stale,
                observedAt: .known($0.updatedAt)
            )
        } ?? SupervisionObservationStamp(
            authority: .unknown,
            freshness: .unknown,
            observedAt: .unknown
        )
        let workspace: WorkerWorkspaceLineage
        switch task.metadata.workspace {
        case .root(let scope):
            workspace = WorkerWorkspaceLineage(
                projectSlug: .known(scope.fallbackSlug),
                cwd: .known(scope.rootPath),
                repositoryRoot: .unknown,
                worktree: .unknown
            )
        case .project(let scope):
            workspace = WorkerWorkspaceLineage(
                projectSlug: .known(scope.fallbackSlug),
                cwd: .known(scope.projectPath),
                repositoryRoot: .unknown,
                worktree: .unknown
            )
        }
        let activityStamp = task.lastConversationActivityAt.map { _ in
            taskStamp
        } ?? SupervisionObservationStamp(
            authority: .unknown,
            freshness: .unknown,
            observedAt: .unknown
        )
        return ConduitFleetTaskSnapshot(
            task: task,
            relationship: .owned,
            runtimeAttemptID: attempt.map {
                .known($0.rawValue.uuidString)
            } ?? .unknown,
            runtime: .unknown,
            lifecycle: lifecycle.map(OrchestrationValue.known) ?? .unknown,
            runtimeObservation: runtimeStamp,
            providerSessionID: providerHandle.map {
                .known($0.threadID)
            } ?? .unknown,
            providerBackend: providerHandle.map {
                .known($0.backend)
            } ?? .unknown,
            supersededThreadHandles: providerHandle.map { record in
                .known(record.supersededThreadIDs.map { id in
                    FleetThreadHandoffHandle(
                        threadID: .known(id),
                        backend: record.supersededThreadBackends[id]
                            .map(OrchestrationValue.known) ?? .unknown,
                        observation: SupervisionObservationStamp(
                            authority: .conduitRecorded,
                            freshness: .stale,
                            observedAt: .known(record.updatedAt)
                        )
                    )
                })
            } ?? (handleStoreAvailability == .available ? .known([]) : .unknown),
            providerHandleObservation: handleStamp,
            model: .unknown,
            modelObservation: SupervisionObservationStamp(
                authority: .unknown,
                freshness: .unknown,
                observedAt: .unknown
            ),
            lastMeaningfulActivityAt: task.lastConversationActivityAt
                .map(OrchestrationValue.known) ?? .unknown,
            lastMeaningfulActivityObservation: activityStamp,
            workspace: workspace,
            turn: FleetTurnObservation(
                turn: .unknown,
                lastPromptDelivery: .unknown,
                pendingInput: .unknown,
                observation: SupervisionObservationStamp(
                    authority: .unknown,
                    freshness: .unknown,
                    observedAt: .unknown
                )
            ),
            processObservation: .unknown,
            processReconciliation: .unknown,
            heldPromptCount: .unknown,
            terminal: WorkerTerminalState(
                receipt: .unknown,
                verification: .unknown,
                objectiveAcceptance: .unknown
            ),
            observation: taskStamp
        )
    }

    public static func taskAssociation(
        for worker: WorkerLineage,
        tasks: [FleetTaskIdentity],
        taskInventoryObservation: SupervisionObservationStamp = SupervisionObservationStamp(
            authority: .unknown,
            freshness: .unknown,
            observedAt: .unknown
        )
    ) -> FleetTaskAssociation {
        let stamp = SupervisionObservationStamp(
            authority: worker.observation.authority,
            freshness: worker.observation.freshness,
            observedAt: worker.observation.observedAt
        )
        guard let rawTaskID = worker.conduitTaskID.value else {
            return FleetTaskAssociation(
                kind: .unbound,
                taskSessionID: .unknown,
                runtimeAttemptID: worker.runtimeAttemptID,
                observation: stamp,
                taskIdentityObservation: SupervisionObservationStamp(
                    authority: .unknown,
                    freshness: .unknown,
                    observedAt: .unknown
                )
            )
        }
        guard let uuid = UUID(uuidString: rawTaskID) else {
            return FleetTaskAssociation(
                kind: .identityMismatch,
                taskSessionID: .known(rawTaskID),
                runtimeAttemptID: worker.runtimeAttemptID,
                observation: stamp,
                taskIdentityObservation: taskInventoryObservation
            )
        }
        let matches = tasks.filter {
            UUID(uuidString: $0.taskSessionID) == uuid
        }
        guard matches.count == 1, let task = matches.first else {
            return FleetTaskAssociation(
                kind: matches.isEmpty
                    && taskInventoryObservation.freshness == .current
                    ? .identityMismatch : .ambiguous,
                taskSessionID: .known(uuid.uuidString),
                runtimeAttemptID: worker.runtimeAttemptID,
                observation: stamp,
                taskIdentityObservation: taskInventoryObservation
            )
        }
        guard let workerAttempt = worker.runtimeAttemptID.value,
              let taskAttempt = task.runtimeAttemptID.value
        else {
            return FleetTaskAssociation(
                kind: .ambiguous,
                taskSessionID: .known(uuid.uuidString),
                runtimeAttemptID: worker.runtimeAttemptID,
                observation: stamp,
                taskIdentityObservation: task.observation
            )
        }
        return FleetTaskAssociation(
            kind: workerAttempt == taskAttempt ? .exact : .historical,
            taskSessionID: .known(uuid.uuidString),
            runtimeAttemptID: .known(workerAttempt),
            observation: stamp,
            taskIdentityObservation: task.observation
        )
    }

    public static func providerPage<Item: Codable & Equatable & Sendable>(
        items: [Item],
        cursor: String?,
        limit: Int?,
        observedAt: Date
    ) -> ConduitFleetPage<Item> {
        let window = ConduitSessionListPage.window(
            total: items.count,
            cursor: cursor,
            limit: limit
        )
        return ConduitFleetPage(
            items: Array(items[window.startIndex..<window.endIndex]),
            total: .known(window.total),
            returned: window.count,
            hasMore: .known(window.hasMore),
            nextCursor: .known(window.nextCursor),
            cursorState: window.cursorState,
            observation: SupervisionObservationStamp(
                authority: .providerObserved,
                freshness: .current,
                observedAt: .known(observedAt)
            )
        )
    }

    public static func unavailableProviderPage<Item: Codable & Equatable & Sendable>(
        cursor: String?,
        observedAt: Date
    ) -> ConduitFleetPage<Item> {
        let parsed = ConduitSessionEventExport.parseCursor(cursor)
        return ConduitFleetPage(
            items: [],
            total: .unknown,
            returned: 0,
            hasMore: .unknown,
            nextCursor: .unknown,
            cursorState: parsed.state,
            observation: SupervisionObservationStamp(
                authority: .unknown,
                freshness: .unknown,
                observedAt: .known(observedAt)
            )
        )
    }

    public static func capacity(
        inventory: [ConduitFleetProviderWorkerSnapshot],
        observedPage: [ConduitFleetProviderWorkerSnapshot],
        taskRows: [ConduitFleetTaskSnapshot] = [],
        inventoryAvailable: Bool,
        inventoryHasMore: Bool,
        taskSlots: ConduitTaskControlSlotSnapshot,
        resources: ConduitResourceSnapshot,
        observedAt: Date
    ) -> ConduitFleetCapacitySnapshot {
        let inventoryStamp = SupervisionObservationStamp(
            authority: inventoryAvailable ? .providerObserved : .unknown,
            freshness: inventoryAvailable ? .current : .unknown,
            observedAt: .known(observedAt)
        )
        let discoveredTotal: OrchestrationValue<Int> = inventoryAvailable
            ? .known(inventory.count)
            : .unknown
        let supervised = inventory.filter {
            ($0.taskAssociation.kind == .exact
                && $0.taskAssociation.taskIdentityObservation.freshness == .current)
                || $0.worker.relationship == .owned
                || $0.worker.relationship == .adopted
                || $0.writerAuthority.conduitWriterState == .controlled
        }.count
        let hostIDs = Set(inventory.compactMap(\.worker.providerHostID.value))
        let knownHosts = hostIDs.count
        let unknownHosts = inventory.filter { !$0.worker.providerHostID.isKnown }.count
        let activeStates = observedPage.map {
            $0.worker.runtimeReconciliation?.providerReportedState ?? .unknown
        }
        let knownActive = activeStates.filter { $0 == .active }.count
        let unknownActive = inventoryAvailable
            ? inventory.count - observedPage.count
                + activeStates.filter { $0 == .unknown }.count
            : 1
        let activeTotal: OrchestrationValue<Int> = inventoryAvailable
                && !inventoryHasMore && unknownActive == 0
            ? .known(knownActive)
            : .unknown

        var childProcessKeys = Set<String>()
        var observedProcessActors = Set<String>()
        var unknownProcessCount = inventoryAvailable ? 0 : 1
        var processSampleCount = 0
        func recordProcessTree(
            _ process: ProcessTreeObservation?,
            actorID: String,
            missingMeansUnknown: Bool
        ) {
            let firstObservationForActor = observedProcessActors.insert(actorID).inserted
            guard let process else {
                if firstObservationForActor && missingMeansUnknown {
                    unknownProcessCount += 1
                }
                return
            }
            processSampleCount += 1
            for node in process.descendants where node.liveness == .live {
                let start = node.startIdentity.value?.startTime.value
                    .map(ConduitSessionEventExport.iso8601) ?? "unknown-start"
                childProcessKeys.insert("\(node.pid):\(start)")
            }
            if firstObservationForActor && process.coverage != .complete {
                unknownProcessCount += 1
            }
        }
        let taskIDsWithProcess = Set(taskRows.compactMap { row -> String? in
            guard row.runtime.isKnown else { return nil }
            return row.task.id.rawValue.uuidString.lowercased()
        })
        for row in taskRows {
            recordProcessTree(
                row.processObservation.value,
                actorID: "task:\(row.task.id.rawValue.uuidString.lowercased())",
                missingMeansUnknown: row.runtime.isKnown
            )
        }
        for (index, item) in observedPage.enumerated() {
            let associatedTaskID = item.taskAssociation.taskSessionID.value
            let actorID: String
            if item.taskAssociation.kind == .exact, let associatedTaskID {
                actorID = "task:\(associatedTaskID.lowercased())"
            } else {
                actorID = "provider:\(item.worker.providerSessionID.value ?? "row-\(index)")"
            }
            let reportedActive = item.worker.runtimeReconciliation?.providerReportedState == .active
            recordProcessTree(
                item.worker.runtimeReconciliation?.processObservation.value,
                actorID: actorID,
                missingMeansUnknown: reportedActive
                    || item.worker.relationship == .owned
                    || item.worker.relationship == .adopted
            )
        }
        if inventoryAvailable {
            let observedIDs = Set(observedPage.compactMap(\.worker.providerSessionID.value))
            for item in inventory where !observedIDs.contains(item.worker.providerSessionID.value ?? "") {
                let taskID = item.taskAssociation.taskSessionID.value?.lowercased()
                if let taskID, taskIDsWithProcess.contains(taskID) { continue }
                unknownProcessCount += 1
            }
        }
        let countStamp = SupervisionObservationStamp(
            authority: inventoryAvailable ? .providerObserved : .unknown,
            freshness: inventoryAvailable ? .current : .unknown,
            observedAt: .known(observedAt)
        )

        return ConduitFleetCapacitySnapshot(
            discoveredProviderSessions: FleetCountObservation(
                knownCount: inventoryAvailable ? inventory.count : 0,
                unknownCount: inventoryAvailable ? 0 : 1,
                total: discoveredTotal,
                observation: inventoryStamp,
                basis: "Exact OpenCode persistence inventory rows only; discovered rows do not consume execution slots."
            ),
            supervisedProviderSessions: FleetCountObservation(
                knownCount: inventoryAvailable ? supervised : 0,
                unknownCount: inventoryAvailable ? 0 : 1,
                total: inventoryAvailable ? .known(supervised) : .unknown,
                observation: inventoryStamp,
                basis: "OpenCode rows with a current exact task/runtime identity, an owned/adopted relationship, or an exact Conduit writer claim. A stale task join remains historical and does not count as currently supervised; this count does not mean an active turn."
            ),
            providerReportedActiveTurns: FleetCountObservation(
                knownCount: knownActive,
                unknownCount: unknownActive,
                total: activeTotal,
                observation: countStamp,
                basis: "Latest OpenCode-reported state for exactly observed sessions; other providers, unobserved rows, and unknown states remain unknown."
            ),
            providerHosts: FleetCountObservation(
                knownCount: knownHosts,
                unknownCount: unknownHosts,
                total: unknownHosts == 0 && inventoryAvailable
                    ? .known(knownHosts)
                    : .unknown,
                observation: inventoryStamp,
                basis: "Distinct exact provider host identities exposed by current provider observations."
            ),
            observedChildProcesses: FleetCountObservation(
                knownCount: childProcessKeys.count,
                unknownCount: unknownProcessCount,
                total: unknownProcessCount == 0 ? .known(childProcessKeys.count) : .unknown,
                observation: SupervisionObservationStamp(
                    authority: .processObserved,
                    freshness: processSampleCount == 0 ? .unknown : .current,
                    observedAt: .known(observedAt)
                ),
                basis: "Unique live descendant PID plus start identity in observed process trees; unavailable or unpaged trees remain unknown."
            ),
            taskControlSlots: taskSlots,
            actualExecutionSlotOccupancy: .unknown,
            actualExecutionSlotBasis: "No provider-neutral execution-slot authority is available; provider turn observations, task slots, and process counts are separate.",
            resources: resources
        )
    }
}
