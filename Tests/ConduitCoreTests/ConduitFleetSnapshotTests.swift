import XCTest
@testable import ConduitCore

final class ConduitFleetSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testExactTaskAssociationDoesNotImplyAdoptionOrLiveProcess() throws {
        let taskID = UUID()
        let attemptA = UUID().uuidString
        let identities = [
            FleetTaskIdentity(
                taskSessionID: taskID.uuidString,
                runtimeAttemptID: .known(attemptA),
                observation: stamp(.conduitRecorded, .current)
            )
        ]

        let exact = ConduitFleetSnapshotBuilder.taskAssociation(
            for: worker(
                sessionID: "ses_exact",
                taskID: taskID.uuidString,
                attemptID: attemptA,
                relationship: .discovered,
                reportedState: .inactive
            ),
            tasks: identities,
            taskInventoryObservation: stamp(.conduitRecorded, .current)
        )
        XCTAssertEqual(exact.kind, .exact)
        XCTAssertEqual(exact.taskSessionID.value, taskID.uuidString)
        XCTAssertEqual(exact.taskIdentityObservation.freshness, .current)

        let staleIdentity = [
            FleetTaskIdentity(
                taskSessionID: taskID.uuidString,
                runtimeAttemptID: .known(attemptA),
                observation: stamp(.conduitRecorded, .stale)
            )
        ]
        let staleExact = ConduitFleetSnapshotBuilder.taskAssociation(
            for: worker(
                sessionID: "ses_stale_exact",
                taskID: taskID.uuidString,
                attemptID: attemptA,
                relationship: .discovered,
                reportedState: .inactive
            ),
            tasks: staleIdentity
        )
        XCTAssertEqual(staleExact.kind, .exact)
        XCTAssertEqual(staleExact.taskIdentityObservation.freshness, .stale)

        let unavailableIndex = ConduitFleetSnapshotBuilder.taskAssociation(
            for: worker(
                sessionID: "ses_unindexed_task",
                taskID: UUID().uuidString,
                attemptID: attemptA,
                relationship: .discovered,
                reportedState: .inactive
            ),
            tasks: [],
            taskInventoryObservation: stamp(.unknown, .unknown)
        )
        XCTAssertEqual(unavailableIndex.kind, .ambiguous)
        XCTAssertEqual(unavailableIndex.taskIdentityObservation.freshness, .unknown)

        let historical = ConduitFleetSnapshotBuilder.taskAssociation(
            for: worker(
                sessionID: "ses_old_attempt",
                taskID: taskID.uuidString,
                attemptID: UUID().uuidString,
                relationship: .discovered,
                reportedState: .inactive
            ),
            tasks: identities
        )
        XCTAssertEqual(historical.kind, .historical)

        let unbound = ConduitFleetSnapshotBuilder.taskAssociation(
            for: worker(
                sessionID: "ses_external",
                taskID: nil,
                attemptID: nil,
                relationship: .discovered,
                reportedState: .unknown
            ),
            tasks: identities
        )
        XCTAssertEqual(unbound.kind, .unbound)

        let missingTask = ConduitFleetSnapshotBuilder.taskAssociation(
            for: worker(
                sessionID: "ses_orphaned_binding",
                taskID: UUID().uuidString,
                attemptID: attemptA,
                relationship: .discovered,
                reportedState: .inactive
            ),
            tasks: identities,
            taskInventoryObservation: stamp(.conduitRecorded, .current)
        )
        XCTAssertEqual(missingTask.kind, .identityMismatch)

        let unknownAttempt = ConduitFleetSnapshotBuilder.taskAssociation(
            for: worker(
                sessionID: "ses_unknown_attempt",
                taskID: taskID.uuidString,
                attemptID: nil,
                relationship: .discovered,
                reportedState: .inactive
            ),
            tasks: identities
        )
        XCTAssertEqual(unknownAttempt.kind, .ambiguous)
    }

    func testCapacityKeepsDiscoverySupervisionTurnsAndProcessesSeparate() throws {
        let taskID = UUID()
        let attempt = UUID().uuidString
        let binding = ProviderObservationBinding(
            conduitTaskID: taskID.uuidString,
            runtimeAttemptID: attempt
        )
        let liveTree = processTree(
            taskID: taskID.uuidString,
            attemptID: attempt,
            launcherLiveness: .live,
            children: [processNode(pid: 31002, parentPID: 31001, ownership: .taskCreated)]
        )
        let activeRecon = ProviderRuntimeReconciler.reconcile(
            providerID: "opencode",
            providerSessionID: "ses_owned_active",
            binding: binding,
            latestProviderTurnID: .known("turn-active"),
            providerReportedState: .active,
            providerActivities: .known([]),
            providerSourceUpdatedAt: .known(now),
            providerObservation: stamp(.providerObserved, .unknown),
            processObservation: liveTree,
            processReconciliation: ProcessTreeReconciler.reconcile(
                before: nil,
                after: liveTree
            )
        )
        XCTAssertEqual(activeRecon.disposition, .consistentActive)

        let before = processTree(
            taskID: taskID.uuidString,
            attemptID: attempt,
            launcherLiveness: .live,
            children: []
        )
        let absentAfter = processTree(
            taskID: taskID.uuidString,
            attemptID: attempt,
            launcherLiveness: .exited,
            children: []
        )
        let absentRecon = ProcessTreeReconciler.reconcile(
            before: before,
            after: absentAfter
        )
        XCTAssertEqual(absentRecon.disposition, .parentExitedNoOwnedResidual)
        let staleRunning = ProviderRuntimeReconciler.reconcile(
            providerID: "opencode",
            providerSessionID: "ses_adopted_stale",
            binding: binding,
            latestProviderTurnID: .known("turn-stale"),
            providerReportedState: .active,
            providerActivities: .known([]),
            providerSourceUpdatedAt: .known(now),
            providerObservation: stamp(.providerObserved, .unknown),
            processObservation: absentAfter,
            processReconciliation: absentRecon
        )
        XCTAssertEqual(
            staleRunning.disposition,
            .providerStaleRunningProcessAbsent
        )

        let beforeResidual = processTree(
            taskID: taskID.uuidString,
            attemptID: attempt,
            launcherLiveness: .live,
            children: []
        )
        let residualAfter = processTree(
            taskID: taskID.uuidString,
            attemptID: attempt,
            launcherLiveness: .exited,
            children: [processNode(pid: 31003, parentPID: 1, ownership: .taskCreated)]
        )
        let residualRecon = ProcessTreeReconciler.reconcile(
            before: beforeResidual,
            after: residualAfter
        )
        XCTAssertEqual(residualRecon.disposition, .parentExitedOwnedResidual)
        let activeResidual = ProviderRuntimeReconciler.reconcile(
            providerID: "opencode",
            providerSessionID: "ses_parent_residual",
            binding: binding,
            latestProviderTurnID: .known("turn-residual"),
            providerReportedState: .active,
            providerActivities: .known([]),
            providerSourceUpdatedAt: .known(now),
            providerObservation: stamp(.providerObserved, .unknown),
            processObservation: residualAfter,
            processReconciliation: residualRecon
        )
        XCTAssertEqual(
            activeResidual.disposition,
            .providerActiveParentAbsentOwnedResidual
        )

        let owned = worker(
            sessionID: "ses_owned_active",
            taskID: taskID.uuidString,
            attemptID: attempt,
            relationship: .owned,
            reportedState: .active,
            reconciliation: activeRecon
        )
        let adopted = worker(
            sessionID: "ses_adopted_stale",
            taskID: taskID.uuidString,
            attemptID: attempt,
            relationship: .adopted,
            reportedState: .active,
            reconciliation: staleRunning
        )
        let residual = worker(
            sessionID: "ses_parent_residual",
            taskID: taskID.uuidString,
            attemptID: attempt,
            relationship: .owned,
            reportedState: .active,
            reconciliation: activeResidual
        )
        let idleHistorical = worker(
            sessionID: "ses_historical_idle",
            taskID: nil,
            attemptID: nil,
            relationship: .historical,
            reportedState: .inactive,
            forcedTurnState: .completed,
            processObservation: nil
        )
        let queuedDiscovered = worker(
            sessionID: "ses_discovered_queued",
            taskID: nil,
            attemptID: nil,
            relationship: .discovered,
            reportedState: .unknown,
            forcedTurnState: .queued,
            processObservation: nil
        )
        let sourceTasks = [
            FleetTaskIdentity(
                taskSessionID: taskID.uuidString,
                runtimeAttemptID: .known(attempt),
                observation: stamp(.conduitRecorded, .current)
            )
        ]
        let inventory = [owned, adopted, residual, idleHistorical, queuedDiscovered]
            .map { wrapped($0, tasks: sourceTasks) }
        let observed = Array(inventory.prefix(4))
        let slots = ConduitTaskControlSlotSnapshot(
            used: .known(1),
            limit: .known(4),
            pendingCreateReservations: .known(0),
            queuedPromptReservations: .known(1),
            observation: stamp(.conduitRecorded, .current)
        )

        let capacity = ConduitFleetSnapshotBuilder.capacity(
            inventory: inventory,
            observedPage: observed,
            inventoryAvailable: true,
            inventoryHasMore: true,
            taskSlots: slots,
            resources: .unknown,
            observedAt: now
        )

        XCTAssertEqual(capacity.discoveredProviderSessions.total.value, 5)
        XCTAssertEqual(capacity.supervisedProviderSessions.total.value, 3)
        XCTAssertEqual(capacity.providerReportedActiveTurns.knownCount, 3)
        XCTAssertGreaterThan(capacity.providerReportedActiveTurns.unknownCount, 0)
        XCTAssertEqual(capacity.providerReportedActiveTurns.total.state, .unknown)
        XCTAssertEqual(capacity.observedChildProcesses.knownCount, 2)
        XCTAssertEqual(capacity.actualExecutionSlotOccupancy.state, .unknown)
        XCTAssertEqual(capacity.taskControlSlots.used.value, 1)

        let staleOnly = wrapped(
            worker(
                sessionID: "ses_stale_discovered_binding",
                taskID: taskID.uuidString,
                attemptID: attempt,
                relationship: .discovered,
                reportedState: .inactive
            ),
            tasks: [FleetTaskIdentity(
                taskSessionID: taskID.uuidString,
                runtimeAttemptID: .known(attempt),
                observation: stamp(.conduitRecorded, .stale)
            )]
        )
        let staleCapacity = ConduitFleetSnapshotBuilder.capacity(
            inventory: [staleOnly],
            observedPage: [staleOnly],
            inventoryAvailable: true,
            inventoryHasMore: false,
            taskSlots: slots,
            resources: .unknown,
            observedAt: now
        )
        XCTAssertEqual(staleCapacity.supervisedProviderSessions.total.value, 0)

        let adoptedRow = try XCTUnwrap(observed.first {
            $0.worker.providerSessionID.value == "ses_adopted_stale"
        })
        XCTAssertEqual(adoptedRow.worker.relationship, .adopted)
        XCTAssertEqual(
            adoptedRow.worker.runtimeReconciliation?.disposition,
            .providerStaleRunningProcessAbsent
        )
        XCTAssertEqual(adoptedRow.writerAuthority.conduitWriterState, .controlled)
        XCTAssertEqual(adoptedRow.worker.terminal.objectiveAcceptance, .unknown)

        let residualRow = try XCTUnwrap(observed.first {
            $0.worker.providerSessionID.value == "ses_parent_residual"
        })
        XCTAssertEqual(
            residualRow.worker.runtimeReconciliation?.disposition,
            .providerActiveParentAbsentOwnedResidual
        )
        XCTAssertEqual(
            idleHistorical.relationship,
            .historical,
            "a known idle historical session stays visible without becoming an active turn"
        )
        XCTAssertEqual(queuedDiscovered.turns.first?.state, .queued)
    }

    func testUnavailableProviderAndProcessFactsRemainUnknown() {
        let taskSlots = ConduitTaskControlSlotSnapshot(
            used: .unknown,
            limit: .unknown,
            pendingCreateReservations: .unknown,
            queuedPromptReservations: .unknown,
            observation: stamp(.unknown, .unknown)
        )
        let capacity = ConduitFleetSnapshotBuilder.capacity(
            inventory: [],
            observedPage: [],
            inventoryAvailable: false,
            inventoryHasMore: true,
            taskSlots: taskSlots,
            resources: .unknown,
            observedAt: now
        )
        XCTAssertEqual(capacity.discoveredProviderSessions.total.state, .unknown)
        XCTAssertEqual(capacity.providerReportedActiveTurns.total.state, .unknown)
        XCTAssertEqual(capacity.providerHosts.total.state, .unknown)
        XCTAssertEqual(capacity.observedChildProcesses.total.state, .unknown)
        XCTAssertEqual(capacity.actualExecutionSlotOccupancy.state, .unknown)
    }

    func testDetailedProviderObservationRequiresCurrentConduitAuthority() {
        let taskID = UUID()
        let attemptID = UUID().uuidString
        let currentTask = FleetTaskIdentity(
            taskSessionID: taskID.uuidString,
            runtimeAttemptID: .known(attemptID),
            observation: stamp(.conduitRecorded, .current)
        )
        let exact = wrapped(
            worker(
                sessionID: "ses_current_exact_detail",
                taskID: taskID.uuidString,
                attemptID: attemptID,
                relationship: .discovered,
                reportedState: .unknown
            ),
            tasks: [currentTask]
        )
        let controlled = wrapped(
            worker(
                sessionID: "ses_current_writer_detail",
                taskID: nil,
                attemptID: nil,
                relationship: .adopted,
                reportedState: .unknown
            ),
            tasks: []
        )
        let historical = wrapped(
            worker(
                sessionID: "ses_historical_inventory_only",
                taskID: nil,
                attemptID: nil,
                relationship: .historical,
                reportedState: .unknown
            ),
            tasks: []
        )
        let staleExact = wrapped(
            worker(
                sessionID: "ses_stale_exact_inventory_only",
                taskID: taskID.uuidString,
                attemptID: attemptID,
                relationship: .discovered,
                reportedState: .unknown
            ),
            tasks: [FleetTaskIdentity(
                taskSessionID: taskID.uuidString,
                runtimeAttemptID: .known(attemptID),
                observation: stamp(.conduitRecorded, .stale)
            )]
        )

        XCTAssertEqual(exact.taskAssociation.kind, .exact)
        XCTAssertEqual(exact.taskAssociation.taskIdentityObservation.freshness, .current)
        XCTAssertTrue(ConduitFleetSnapshotBuilder.requiresDetailedProviderObservation(exact))

        XCTAssertEqual(controlled.writerAuthority.conduitWriterState, .controlled)
        XCTAssertEqual(controlled.writerAuthorityObservation.freshness, .current)
        XCTAssertTrue(ConduitFleetSnapshotBuilder.requiresDetailedProviderObservation(controlled))

        XCTAssertEqual(historical.worker.origin, .externalProviderClient)
        XCTAssertEqual(historical.worker.relationship, .historical)
        XCTAssertFalse(ConduitFleetSnapshotBuilder.requiresDetailedProviderObservation(historical))

        XCTAssertEqual(staleExact.taskAssociation.kind, .exact)
        XCTAssertEqual(staleExact.taskAssociation.taskIdentityObservation.freshness, .stale)
        XCTAssertFalse(ConduitFleetSnapshotBuilder.requiresDetailedProviderObservation(staleExact))
        XCTAssertEqual(
            ConduitFleetSnapshotBuilder.markingProviderDetailSkipped(exact),
            exact,
            "a row that requires detail must not be relabeled as skipped"
        )
    }

    func testSkippedProviderDetailPreservesVisibleInventoryUnknownsAndAuthority() throws {
        let inventoryOnly = wrapped(
            worker(
                sessionID: "ses_inventory_only_unknown_detail",
                taskID: nil,
                attemptID: nil,
                relationship: .historical,
                reportedState: .unknown
            ),
            tasks: []
        )
        let skipped = ConduitFleetSnapshotBuilder.markingProviderDetailSkipped(
            inventoryOnly
        )
        let page = ConduitFleetSnapshotBuilder.providerPage(
            items: [skipped],
            cursor: nil,
            limit: 200,
            observedAt: now
        )

        XCTAssertEqual(page.returned, 1)
        let visible = try XCTUnwrap(page.items.first)
        XCTAssertEqual(visible.worker.providerSessionID.value, "ses_inventory_only_unknown_detail")
        XCTAssertEqual(visible.diagnostics.count, 1)
        XCTAssertTrue(visible.diagnostics[0].contains("no current exact Conduit task association"))
        XCTAssertTrue(visible.diagnostics[0].contains("inventory row remains visible"))
        XCTAssertTrue(visible.diagnostics[0].contains("detail remains UNKNOWN"))

        XCTAssertEqual(visible.worker, inventoryOnly.worker)
        XCTAssertEqual(visible.taskAssociation, inventoryOnly.taskAssociation)
        XCTAssertEqual(visible.writerAuthority, inventoryOnly.writerAuthority)
        XCTAssertEqual(visible.worker.origin, .externalProviderClient)
        XCTAssertEqual(visible.worker.relationship, .historical)
        XCTAssertEqual(visible.taskAssociation.kind, .unbound)
        XCTAssertEqual(visible.writerAuthority.conduitWriterState, .unclaimed)
        XCTAssertFalse(visible.writerAuthority.writerControllerID.isKnown)
        XCTAssertEqual(
            visible.worker.runtimeReconciliation?.providerReportedState,
            .unknown
        )
        XCTAssertEqual(
            visible.worker.runtimeReconciliation?.providerObservation.freshness,
            .unknown
        )
        XCTAssertEqual(
            visible.worker.runtimeReconciliation?.processObservation.state,
            .unknown
        )
        XCTAssertEqual(visible.worker.turns.first?.state, .ambiguous)
    }

    func testApprovalFailureAndContradictoryTurnAuthoritiesStaySeparate() throws {
        let pendingApproval = FleetTurnObservation(
            turn: .known(ConduitSessionTurnSnapshot(
                state: "awaiting_input",
                status: "approval_required",
                honesty: "structured",
                threadID: "thread-approval-fixture",
                threadIDSource: .live,
                pendingApproval: true
            )),
            lastPromptDelivery: .known(.queued),
            pendingInput: .known(.approval),
            observation: stamp(.providerObserved, .current)
        )
        let encodedApproval = try JSONEncoder().encode(pendingApproval)
        let decodedApproval = try JSONDecoder().decode(
            FleetTurnObservation.self,
            from: encodedApproval
        )
        XCTAssertEqual(decodedApproval.turn.value?.state, "awaiting_input")
        XCTAssertEqual(decodedApproval.turn.value?.pendingApproval, true)
        XCTAssertEqual(decodedApproval.lastPromptDelivery.value, .queued)
        XCTAssertEqual(decodedApproval.pendingInput.value, .approval)

        let contradictory = worker(
            sessionID: "ses_turn_authority_conflict",
            taskID: nil,
            attemptID: nil,
            relationship: .discovered,
            reportedState: .inactive,
            forcedTurnState: .failed
        )
        XCTAssertEqual(contradictory.runtimeReconciliation?.providerReportedState, .inactive)
        XCTAssertEqual(contradictory.turns.first?.state, .failed)
        XCTAssertEqual(contradictory.terminal.objectiveAcceptance, .unknown)
    }

    func testFreshStoreInstancesRebuildVersionedHandoffSnapshotWithoutMutation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleet-handoff-\(UUID().uuidString)")
        let taskDirectory = root.appendingPathComponent("tasks", isDirectory: true)
        let adapterDirectory = root.appendingPathComponent("adapters", isDirectory: true)
        try FileManager.default.createDirectory(
            at: taskDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let id = TaskSessionID(rawValue: UUID())
        let attempt = RuntimeAttemptID(rawValue: UUID())
        let metadata = TaskSessionMetadata(
            workspace: .project(
                ProjectWorkspaceScopeSnapshot(
                    rootURL: URL(fileURLWithPath: "/tmp/fixture-root"),
                    projectURL: URL(fileURLWithPath: "/tmp/fixture-root/project"),
                    fallbackTitle: "Fixture Project",
                    fallbackSlug: "fixture-project"
                )
            ),
            agentName: "OpenCode",
            defaultTitle: "Durable handoff fixture"
        )
        let log = TaskSessionEventLog(directory: taskDirectory, taskSessionID: id)
        try log.append(
            TaskSessionEvent(
                taskSessionID: id,
                occurredAt: now.addingTimeInterval(-120),
                recordedAt: now.addingTimeInterval(-120),
                authority: .conduitRecorded,
                kind: .created(metadata)
            )
        )
        try log.append(
            TaskSessionEvent(
                taskSessionID: id,
                occurredAt: now.addingTimeInterval(-60),
                recordedAt: now.addingTimeInterval(-60),
                authority: .conduitRecorded,
                kind: .operationalStateChanged(.runtimeOpened(attempt))
            )
        )
        let originalHandleStore = AdapterThreadStore(directory: adapterDirectory)
        originalHandleStore.save(
            taskSessionID: id,
            backend: "http-server",
            threadID: "ses_superseded"
        )
        originalHandleStore.save(
            taskSessionID: id,
            backend: "http-server",
            threadID: "ses_exact_handoff"
        )

        let taskBytesBefore = try Data(contentsOf: log.url)
        let handleBytesBefore = try Data(contentsOf: originalHandleStore.url)
        // New store objects model a fresh supervisor with no prior instance
        // state, provider client, runtime object, or conversation scrollback.
        let reloadedTask = try XCTUnwrap(
            TaskSessionEventStore(directory: taskDirectory).load().snapshots.first
        )
        let reloadedHandles = AdapterThreadStore(directory: adapterDirectory).loadResult()
        let record = try XCTUnwrap(
            reloadedHandles.records[id.rawValue.uuidString.lowercased()]
        )
        let taskRow = ConduitFleetSnapshotBuilder.persistedTask(
            reloadedTask,
            providerHandle: record,
            handleStoreAvailability: reloadedHandles.availability,
            observedAt: now
        )
        let page = ConduitFleetPage(
            items: [taskRow],
            total: .known(1),
            returned: 1,
            hasMore: .known(false),
            nextCursor: .known("v1:1"),
            cursorState: .ok,
            observation: stamp(.conduitRecorded, .current)
        )
        let providerPage = ConduitFleetSnapshotBuilder.unavailableProviderPage(
            cursor: nil,
            observedAt: now
        ) as ConduitFleetPage<ConduitFleetProviderWorkerSnapshot>
        let emptyCapacity = ConduitFleetSnapshotBuilder.capacity(
            inventory: [],
            observedPage: [],
            inventoryAvailable: false,
            inventoryHasMore: true,
            taskSlots: ConduitTaskControlSlotSnapshot(
                used: .unknown,
                limit: .unknown,
                pendingCreateReservations: .unknown,
                queuedPromptReservations: .unknown,
                observation: stamp(.unknown, .unknown)
            ),
            resources: .unknown,
            observedAt: now
        )
        let snapshot = ConduitFleetSnapshot(
            observedAt: now,
            tasks: page,
            providerSessions: providerPage,
            sources: [],
            capacity: emptyCapacity
        )
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ConduitFleetSnapshot.self, from: encoded)
        let recovered = try XCTUnwrap(decoded.tasks.items.first)

        XCTAssertEqual(ConduitFleetSnapshot.currentSchemaVersion, 1)
        XCTAssertEqual(recovered.task.id, id)
        XCTAssertEqual(recovered.runtimeAttemptID.value, attempt.rawValue.uuidString)
        XCTAssertEqual(recovered.providerSessionID.value, "ses_exact_handoff")
        XCTAssertEqual(recovered.providerBackend.value, "http-server")
        XCTAssertEqual(recovered.supersededThreadHandles.value?.first?.threadID.value, "ses_superseded")
        XCTAssertEqual(recovered.supersededThreadHandles.value?.first?.backend.value, "http-server")
        XCTAssertEqual(recovered.runtimeObservation.freshness, .stale)
        XCTAssertEqual(recovered.providerHandleObservation.freshness, .stale)
        XCTAssertEqual(recovered.processObservation.state, .unknown)
        XCTAssertEqual(recovered.terminal.objectiveAcceptance, .unknown)
        XCTAssertEqual(recovered.model.state, .unknown)
        XCTAssertEqual(recovered.task.metadata.workspace.projectPath, "/tmp/fixture-root/project")
        XCTAssertEqual(try Data(contentsOf: log.url), taskBytesBefore)
        XCTAssertEqual(try Data(contentsOf: originalHandleStore.url), handleBytesBefore)
        XCTAssertFalse(
            ConduitSessionAPI.isWrite(
                .fleetSnapshot(taskCursor: nil, providerCursor: nil, limit: 40)
            )
        )
    }

    func testFleetPagesUseIndependentCursorsAndReportSchemaIdentity() throws {
        let taskPages = ConduitSessionListPage.window(
            total: 4,
            cursor: "v1:2",
            limit: 1
        )
        let providerPage = ConduitFleetSnapshotBuilder.providerPage(
            items: ["a", "b", "c"],
            cursor: "v1:1",
            limit: 1,
            observedAt: now
        )
        XCTAssertEqual(taskPages.startIndex, 2)
        XCTAssertEqual(providerPage.items, ["b"])
        XCTAssertEqual(providerPage.nextCursor.value, "v1:2")
        XCTAssertTrue(providerPage.hasMore.value == true)
        XCTAssertEqual(ConduitFleetSnapshot.currentSchemaVersion, 1)
    }

    private func wrapped(
        _ worker: WorkerLineage,
        tasks: [FleetTaskIdentity]
    ) -> ConduitFleetProviderWorkerSnapshot {
        let sessionID = worker.providerSessionID.value ?? "unknown"
        let isAdopted = worker.relationship == .adopted
        let authority = ProviderSessionAuthoritySnapshot(
            providerID: "opencode",
            providerSessionID: sessionID,
            conduitWriterState: isAdopted ? .controlled : .unclaimed,
            writerControllerID: isAdopted ? .known("controller-fixture") : .unknown
        )
        return ConduitFleetProviderWorkerSnapshot(
            worker: worker,
            writerAuthority: authority,
            writerAuthorityObservation: stamp(.conduitRecorded, .current),
            taskAssociation: ConduitFleetSnapshotBuilder.taskAssociation(
                for: worker,
                tasks: tasks
            )
        )
    }

    private func worker(
        sessionID: String,
        taskID: String?,
        attemptID: String?,
        relationship: WorkerRelationship,
        reportedState: ProviderReportedRuntimeState,
        forcedTurnState: ProviderTurnState? = nil,
        reconciliation: ProviderRuntimeReconciliation? = nil,
        processObservation: ProcessTreeObservation? = nil
    ) -> WorkerLineage {
        let observation = stamp(.providerObserved, .unknown)
        let state = forcedTurnState ?? {
            switch reportedState {
            case .active: return .active
            case .inactive: return .completed
            case .unknown: return .ambiguous
            }
        }()
        let resolvedReconciliation = reconciliation ?? ProviderRuntimeReconciliation(
            providerID: "opencode",
            providerSessionID: .known(sessionID),
            conduitTaskID: taskID.map(OrchestrationValue.known) ?? .unknown,
            runtimeAttemptID: attemptID.map(OrchestrationValue.known) ?? .unknown,
            latestProviderTurnID: .known("turn-\(sessionID)"),
            providerReportedState: reportedState,
            providerActivities: .unknown,
            providerSourceUpdatedAt: .known(now),
            providerObservation: observation,
            processObservation: processObservation.map(OrchestrationValue.known) ?? .unknown,
            processReconciliation: .unknown,
            disposition: .insufficientObservation,
            diagnostics: [],
            unknownFacts: ["objective_acceptance"]
        )
        return WorkerLineage(
            conduitTaskID: taskID.map(OrchestrationValue.known) ?? .unknown,
            runtimeAttemptID: attemptID.map(OrchestrationValue.known) ?? .unknown,
            runtime: .known("opencode"),
            adapter: .known("fixture"),
            providerHostID: sessionID == "ses_historical_idle"
                ? .unknown : .known("host-fixture"),
            providerSessionID: .known(sessionID),
            turns: [
                ProviderTurnLineage(
                    turnID: .known("turn-\(sessionID)"),
                    state: state,
                    model: .known(ProviderModelIdentity(
                        providerID: "openai",
                        modelID: "fixture-model"
                    )),
                    observation: observation
                ),
            ],
            workspace: WorkerWorkspaceLineage(
                projectSlug: .unknown,
                cwd: .unknown,
                repositoryRoot: .unknown,
                worktree: .unknown
            ),
            process: WorkerProcessLineage(
                launcherPID: processObservation?.launcher.value
                    .map { .known($0.pid) } ?? .unknown,
                processGroupID: .unknown,
                parentPID: .unknown
            ),
            origin: taskID == nil ? .externalProviderClient : .conduit,
            relationship: relationship,
            writerControllerID: relationship == .adopted
                ? .known("controller-fixture") : .unknown,
            terminal: WorkerTerminalState(
                receipt: .unknown,
                verification: .unknown,
                objectiveAcceptance: .unknown
            ),
            observation: observation,
            providerSpecific: .known(
                ProviderSpecificPayload(
                    namespace: "fixture",
                    value: .object([:])
                )
            ),
            runtimeReconciliation: resolvedReconciliation
        )
    }

    private func processTree(
        taskID: String,
        attemptID: String,
        launcherLiveness: ProcessLiveness,
        children: [ProcessNodeObservation]
    ) -> ProcessTreeObservation {
        let launcher = processNode(
            pid: 31001,
            parentPID: 1,
            ownership: .taskCreated,
            liveness: launcherLiveness
        )
        return ProcessTreeObservation(
            taskSessionID: taskID,
            runtimeAttemptID: .known(attemptID),
            providerTurnID: .unknown,
            launcher: .known(launcher),
            descendants: children,
            coverage: .complete,
            observation: stamp(.processObserved, .current)
        )
    }

    private func processNode(
        pid: Int32,
        parentPID: Int32,
        ownership: ProcessOwnership,
        liveness: ProcessLiveness = .live
    ) -> ProcessNodeObservation {
        ProcessNodeObservation(
            pid: pid,
            parentPID: .known(parentPID),
            processGroupID: .known(31001),
            startIdentity: .known(ProcessStartIdentity(
                startTime: .known(now.addingTimeInterval(Double(pid)))
            )),
            commandName: .known("fixture-agent"),
            ownership: ownership,
            ownershipBasis: ownership == .taskCreated
                ? .descendantObservedAfterLauncher : .notEstablished,
            liveness: liveness,
            observation: stamp(.processObserved, .current)
        )
    }

    private func stamp(
        _ authority: SupervisionObservationAuthority,
        _ freshness: SupervisionObservationFreshness
    ) -> SupervisionObservationStamp {
        SupervisionObservationStamp(
            authority: authority,
            freshness: freshness,
            observedAt: .known(now)
        )
    }
}
