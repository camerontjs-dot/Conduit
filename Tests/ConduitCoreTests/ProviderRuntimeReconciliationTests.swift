import Foundation
import XCTest
@testable import ConduitCore

final class ProviderRuntimeReconciliationTests: XCTestCase {
    private let providerStamp = SupervisionObservationStamp(
        authority: .providerObserved,
        freshness: .unknown,
        observedAt: .known(Date(timeIntervalSince1970: 1_800_000_000))
    )

    private func activity(
        messageID: String = "msg-running",
        status: String = "running"
    ) -> ProviderPersistedActivity {
        ProviderPersistedActivity(
            partID: .known("prt-tool-1"),
            messageID: .known(messageID),
            callID: .known("call-1"),
            kind: .known("tool"),
            toolName: .known("bash"),
            reportedStatus: .known(status),
            createdAt: .known(Date(timeIntervalSince1970: 1_799_999_900)),
            updatedAt: .known(Date(timeIntervalSince1970: 1_799_999_950))
        )
    }

    private func processNode(
        pid: Int32,
        parentPID: Int32?,
        ownership: ProcessOwnership,
        liveness: ProcessLiveness,
        start: TimeInterval = 1_700_000_000
    ) -> ProcessNodeObservation {
        ProcessNodeObservation(
            pid: pid,
            parentPID: parentPID.map(OrchestrationValue.known) ?? .unknown,
            processGroupID: .known(100),
            startIdentity: .known(
                ProcessStartIdentity(startTime: .known(Date(timeIntervalSince1970: start)))
            ),
            commandName: .known(pid == 100 ? "opencode" : "sleep"),
            ownership: ownership,
            ownershipBasis: ownership == .taskCreated
                ? .descendantObservedAfterLauncher
                : .launcherIdentity,
            liveness: liveness,
            observation: SupervisionObservationStamp(
                authority: .processObserved,
                freshness: .current,
                observedAt: .known(Date(timeIntervalSince1970: 1_800_000_001))
            )
        )
    }

    private func processTree(
        parent: ProcessLiveness,
        descendants: [ProcessNodeObservation] = [],
        taskID: String = "task-1",
        attemptID: String = "attempt-1"
    ) -> ProcessTreeObservation {
        ProcessTreeObservation(
            taskSessionID: taskID,
            runtimeAttemptID: .known(attemptID),
            providerTurnID: .unknown,
            launcher: .known(
                processNode(
                    pid: 100,
                    parentPID: 1,
                    ownership: .taskCreated,
                    liveness: parent
                )
            ),
            descendants: descendants,
            coverage: .complete,
            observation: SupervisionObservationStamp(
                authority: .processObserved,
                freshness: .current,
                observedAt: .known(Date(timeIntervalSince1970: 1_800_000_001))
            )
        )
    }

    private func bind(
        state: ProviderReportedRuntimeState = .active,
        activities: OrchestrationValue<[ProviderPersistedActivity]>? = nil,
        process: ProcessTreeObservation?,
        processReconciliation: ProcessTreeReconciliation?
    ) -> ProviderRuntimeReconciliation {
        ProviderRuntimeReconciler.reconcile(
            providerID: "opencode",
            providerSessionID: "ses_qualification_fixture",
            binding: ProviderObservationBinding(
                conduitTaskID: "task-1",
                runtimeAttemptID: "attempt-1"
            ),
            latestProviderTurnID: .known("msg-running"),
            providerReportedState: state,
            providerActivities: activities ?? .known([activity()]),
            providerSourceUpdatedAt: .known(
                Date(timeIntervalSince1970: 1_799_999_950)
            ),
            providerObservation: providerStamp,
            processObservation: process,
            processReconciliation: processReconciliation
        )
    }

    func testProviderRunningWithCompleteAbsentProcessTreeIsExplicitlyStale() {
        let before = processTree(parent: .live)
        let after = processTree(parent: .exited)
        let processReceipt = ProcessTreeReconciler.reconcile(
            before: before,
            after: after
        )

        let result = bind(
            process: after,
            processReconciliation: processReceipt
        )

        XCTAssertEqual(processReceipt.disposition, .parentExitedNoOwnedResidual)
        XCTAssertEqual(
            result.disposition,
            .providerStaleRunningProcessAbsent
        )
        XCTAssertEqual(result.providerReportedState, .active)
        XCTAssertEqual(result.providerActivities.value, [activity()])
        XCTAssertEqual(
            result.processReconciliation.value?.cleanup.disposition,
            .notAttempted
        )
        XCTAssertTrue(result.unknownFacts.contains("objective_acceptance"))
    }

    func testProviderRunningWithExitedParentAndOwnedResidualRemainsDistinct() {
        let childBefore = processNode(
            pid: 120,
            parentPID: 100,
            ownership: .taskCreated,
            liveness: .live,
            start: 1_700_000_120
        )
        let before = processTree(parent: .live, descendants: [childBefore])
        let reparentedChild = processNode(
            pid: 120,
            parentPID: 1,
            ownership: .unknown,
            liveness: .live,
            start: 1_700_000_120
        )
        let after = processTree(parent: .exited, descendants: [reparentedChild])
        let processReceipt = ProcessTreeReconciler.reconcile(
            before: before,
            after: after
        )

        let result = bind(
            process: processReceipt.after,
            processReconciliation: processReceipt
        )

        XCTAssertEqual(processReceipt.disposition, .parentExitedOwnedResidual)
        XCTAssertEqual(
            result.disposition,
            .providerActiveParentAbsentOwnedResidual
        )
        XCTAssertEqual(result.processReconciliation.value?.ownedResidualDescendants.map(\.pid), [120])
        XCTAssertEqual(result.processReconciliation.value?.cleanup.disposition, .notAttempted)
    }

    func testProviderAndBoundLiveLauncherAreConsistentActive() {
        let live = processTree(parent: .live)
        let processReceipt = ProcessTreeReconciler.reconcile(
            before: nil,
            after: live
        )

        let result = bind(
            process: live,
            processReconciliation: processReceipt
        )

        XCTAssertEqual(result.disposition, .consistentActive)
        XCTAssertEqual(result.providerObservation.authority, .providerObserved)
        XCTAssertEqual(result.providerObservation.freshness, .unknown)
        XCTAssertEqual(result.processObservation.value?.observation.authority, .processObserved)
        XCTAssertEqual(result.processObservation.value?.observation.freshness, .current)
        XCTAssertTrue(result.unknownFacts.contains("provider_turn_to_process_identity_correlation"))
    }

    func testProviderCompletedAndCompleteAbsentTreeAreConsistentInactiveOnly() {
        let before = processTree(parent: .live)
        let after = processTree(parent: .exited)
        let processReceipt = ProcessTreeReconciler.reconcile(before: before, after: after)

        let result = bind(
            state: .inactive,
            activities: .known([activity(messageID: "msg-old", status: "running")]),
            process: after,
            processReconciliation: processReceipt
        )

        XCTAssertEqual(result.disposition, .consistentInactive)
        XCTAssertEqual(result.providerActivities.value?.first?.reportedStatus.value, "running")
        XCTAssertTrue(result.unknownFacts.contains("objective_acceptance"))
    }

    func testProviderInactiveWithLiveOwnedResidualIsNotCollapsedToStopped() {
        let child = processNode(
            pid: 120,
            parentPID: 1,
            ownership: .taskCreated,
            liveness: .live,
            start: 1_700_000_120
        )
        let before = processTree(parent: .live, descendants: [child])
        let after = processTree(parent: .exited, descendants: [child])
        let processReceipt = ProcessTreeReconciler.reconcile(before: before, after: after)

        let result = bind(
            state: .inactive,
            process: processReceipt.after,
            processReconciliation: processReceipt
        )

        XCTAssertEqual(result.disposition, .providerInactiveProcessResidual)
    }

    func testMissingAuthoritiesAndUnknownProviderStateStayInsufficient() {
        let missingProvider = ProviderRuntimeReconciler.reconcile(
            providerID: "opencode",
            providerSessionID: "ses_qualification_fixture",
            binding: nil,
            latestProviderTurnID: .unknown,
            providerReportedState: .unknown,
            providerActivities: .unknown,
            providerSourceUpdatedAt: .unknown,
            providerObservation: SupervisionObservationStamp(
                authority: .unknown,
                freshness: .unknown,
                observedAt: .unknown
            ),
            processObservation: processTree(parent: .live)
        )
        XCTAssertEqual(missingProvider.disposition, .insufficientObservation)
        XCTAssertTrue(missingProvider.unknownFacts.contains("exact_conduit_binding"))
        XCTAssertTrue(missingProvider.unknownFacts.contains("persisted_tool_part_state"))

        let live = processTree(parent: .live)
        let unknownState = bind(
            state: .unknown,
            activities: .unknown,
            process: live,
            processReconciliation: ProcessTreeReconciler.reconcile(
                before: nil,
                after: live
            )
        )
        XCTAssertEqual(unknownState.disposition, .insufficientObservation)
        XCTAssertTrue(unknownState.unknownFacts.contains("latest_provider_runtime_state"))

        let noProcess = bind(
            process: nil,
            processReconciliation: nil
        )
        XCTAssertEqual(noProcess.disposition, .insufficientObservation)
        XCTAssertTrue(noProcess.unknownFacts.contains("process_liveness_and_residuals"))
    }

    func testProcessTaskMismatchIsNotAcceptedAsCorrespondingRuntimeEvidence() {
        let wrongTask = processTree(parent: .live, taskID: "other-task")
        let result = bind(
            process: wrongTask,
            processReconciliation: ProcessTreeReconciler.reconcile(
                before: nil,
                after: wrongTask
            )
        )

        XCTAssertEqual(result.disposition, .inconsistentAuthorities)
        XCTAssertTrue(result.unknownFacts.contains("process_binding_identity"))
    }

    func testUnknownAuthorityAndHistorySurviveCodableRoundTrip() throws {
        let unknown = ProviderRuntimeReconciler.reconcile(
            providerID: "opencode",
            providerSessionID: "ses_qualification_fixture",
            binding: nil,
            latestProviderTurnID: .unknown,
            providerReportedState: .unknown,
            providerActivities: .unknown,
            providerSourceUpdatedAt: .unknown,
            providerObservation: SupervisionObservationStamp(
                authority: .providerObserved,
                freshness: .unknown,
                observedAt: .known(Date(timeIntervalSince1970: 1_800_000_000))
            )
        )
        let data = try JSONEncoder().encode(unknown)
        let decoded = try JSONDecoder().decode(
            ProviderRuntimeReconciliation.self,
            from: data
        )

        XCTAssertEqual(decoded, unknown)
        XCTAssertEqual(decoded.providerActivities.state, .unknown)
        XCTAssertEqual(decoded.providerReportedState, .unknown)
        XCTAssertEqual(decoded.providerObservation.freshness, .unknown)
        XCTAssertEqual(decoded.disposition, .insufficientObservation)
    }
}
