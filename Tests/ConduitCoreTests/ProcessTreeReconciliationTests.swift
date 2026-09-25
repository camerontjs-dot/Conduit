import Foundation
import XCTest
@testable import ConduitCore

final class ProcessTreeReconciliationTests: XCTestCase {
    private let taskID = "task-process-tree-fixture"
    private let attemptID = "attempt-process-tree-fixture"
    private let launcherPID: Int32 = 900
    private let childPID: Int32 = 901
    private let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private let launcherStarted = Date(timeIntervalSince1970: 1_799_999_900)
    private let childStarted = Date(timeIntervalSince1970: 1_799_999_950)

    private var stamp: SupervisionObservationStamp {
        SupervisionObservationStamp(
            authority: .processObserved,
            freshness: .current,
            observedAt: .known(observedAt)
        )
    }

    private func node(
        pid: Int32,
        parentPID: Int32?,
        start: Date,
        ownership: ProcessOwnership,
        basis: ProcessOwnershipBasis,
        liveness: ProcessLiveness,
        command: String = "fixture"
    ) -> ProcessNodeObservation {
        ProcessNodeObservation(
            pid: pid,
            parentPID: parentPID.map(OrchestrationValue<Int32>.known) ?? .unknown,
            processGroupID: .known(900),
            startIdentity: .known(
                ProcessStartIdentity(startTime: .known(start))
            ),
            commandName: .known(command),
            ownership: ownership,
            ownershipBasis: basis,
            liveness: liveness,
            exitObservedAt: liveness == .exited ? .known(observedAt) : .unknown,
            observation: stamp
        )
    }

    private func observation(
        launcher: ProcessNodeObservation,
        descendants: [ProcessNodeObservation],
        coverage: ProcessTreeObservationCoverage = .complete
    ) -> ProcessTreeObservation {
        ProcessTreeObservation(
            taskSessionID: taskID,
            runtimeAttemptID: .known(attemptID),
            providerTurnID: .unknown,
            launcher: .known(launcher),
            descendants: descendants,
            coverage: coverage,
            observation: stamp
        )
    }

    func testParentExitWithReparentedOwnedChildIsIncompleteResidual() {
        let before = observation(
            launcher: node(
                pid: launcherPID,
                parentPID: 1,
                start: launcherStarted,
                ownership: .taskCreated,
                basis: .launcherIdentity,
                liveness: .live,
                command: "qualification-shell"
            ),
            descendants: [
                node(
                    pid: childPID,
                    parentPID: launcherPID,
                    start: childStarted,
                    ownership: .taskCreated,
                    basis: .descendantObservedAfterLauncher,
                    liveness: .live,
                    command: "sleep"
                ),
            ]
        )
        let after = observation(
            launcher: node(
                pid: launcherPID,
                parentPID: 1,
                start: launcherStarted,
                ownership: .taskCreated,
                basis: .preservedFromPriorIdentity,
                liveness: .exited,
                command: "qualification-shell"
            ),
            descendants: [
                node(
                    pid: childPID,
                    parentPID: 1,
                    start: childStarted,
                    ownership: .taskCreated,
                    basis: .preservedFromPriorIdentity,
                    liveness: .live,
                    command: "sleep"
                ),
            ]
        )

        let result = ProcessTreeReconciler.reconcile(
            before: before,
            after: after,
            requestedOperation: .known(.stopProviderHost)
        )

        XCTAssertEqual(result.disposition, .parentExitedOwnedResidual)
        XCTAssertEqual(result.postcondition, .incompleteResidual)
        XCTAssertEqual(result.ownedResidualDescendants.map(\.pid), [childPID])
        XCTAssertEqual(result.residualDescendants.first?.parentPID.value, 1)
        XCTAssertEqual(result.residualDescendants.first?.ownership, .taskCreated)
        XCTAssertEqual(result.cleanup.disposition, .notAttempted)
        XCTAssertTrue(result.cleanup.targetedPIDs.isEmpty)
    }

    func testNormalCleanExitCanOnlyBecomeCompleteWithCompleteBeforeAndAfterEvidence() {
        let before = observation(
            launcher: node(
                pid: launcherPID,
                parentPID: 1,
                start: launcherStarted,
                ownership: .taskCreated,
                basis: .launcherIdentity,
                liveness: .live
            ),
            descendants: [
                node(
                    pid: childPID,
                    parentPID: launcherPID,
                    start: childStarted,
                    ownership: .taskCreated,
                    basis: .descendantObservedAfterLauncher,
                    liveness: .live
                ),
            ]
        )
        let after = observation(
            launcher: node(
                pid: launcherPID,
                parentPID: 1,
                start: launcherStarted,
                ownership: .taskCreated,
                basis: .preservedFromPriorIdentity,
                liveness: .exited
            ),
            descendants: [
                node(
                    pid: childPID,
                    parentPID: launcherPID,
                    start: childStarted,
                    ownership: .taskCreated,
                    basis: .preservedFromPriorIdentity,
                    liveness: .exited
                ),
            ]
        )

        let result = ProcessTreeReconciler.reconcile(before: before, after: after)

        XCTAssertEqual(result.disposition, .parentExitedNoOwnedResidual)
        XCTAssertEqual(result.postcondition, .complete)
        XCTAssertEqual(result.observedExits.map(\.pid), [childPID, launcherPID])
    }

    func testPreExistingResidualIsReportedButNeverCountedAsOwnedCleanupTarget() {
        let before = observation(
            launcher: node(
                pid: launcherPID,
                parentPID: 1,
                start: launcherStarted,
                ownership: .taskCreated,
                basis: .launcherIdentity,
                liveness: .live
            ),
            descendants: [
                node(
                    pid: childPID,
                    parentPID: launcherPID,
                    start: Date(timeIntervalSince1970: 1_799_999_000),
                    ownership: .preExisting,
                    basis: .preExistingObservation,
                    liveness: .live,
                    command: "unrelated-fixture"
                ),
            ]
        )
        let after = observation(
            launcher: node(
                pid: launcherPID,
                parentPID: 1,
                start: launcherStarted,
                ownership: .taskCreated,
                basis: .preservedFromPriorIdentity,
                liveness: .exited
            ),
            descendants: [
                node(
                    pid: childPID,
                    parentPID: 1,
                    start: Date(timeIntervalSince1970: 1_799_999_000),
                    ownership: .preExisting,
                    basis: .preservedFromPriorIdentity,
                    liveness: .live,
                    command: "unrelated-fixture"
                ),
            ]
        )

        let result = ProcessTreeReconciler.reconcile(before: before, after: after)

        XCTAssertEqual(result.disposition, .parentExitedNoOwnedResidual)
        XCTAssertEqual(result.postcondition, .complete)
        XCTAssertEqual(result.residualDescendants.map(\.pid), [childPID])
        XCTAssertTrue(result.ownedResidualDescendants.isEmpty)
        XCTAssertTrue(result.cleanup.targetedPIDs.isEmpty)
    }

    func testUnknownOwnershipRefusesCompletePostconditionAndCleanup() {
        let before = observation(
            launcher: node(
                pid: launcherPID,
                parentPID: 1,
                start: launcherStarted,
                ownership: .taskCreated,
                basis: .launcherIdentity,
                liveness: .live
            ),
            descendants: []
        )
        let after = observation(
            launcher: node(
                pid: launcherPID,
                parentPID: 1,
                start: launcherStarted,
                ownership: .taskCreated,
                basis: .preservedFromPriorIdentity,
                liveness: .exited
            ),
            descendants: [
                node(
                    pid: childPID,
                    parentPID: 1,
                    start: childStarted,
                    ownership: .unknown,
                    basis: .notEstablished,
                    liveness: .live
                ),
            ]
        )

        let result = ProcessTreeReconciler.reconcile(before: before, after: after)

        XCTAssertEqual(result.disposition, .parentExitedResidualOwnershipUnknown)
        XCTAssertEqual(result.postcondition, .incompleteUnknown)
        XCTAssertEqual(result.unknownOwnershipResidualDescendants.map(\.pid), [childPID])
        XCTAssertEqual(result.cleanup.disposition, .notAttempted)
        XCTAssertTrue(result.cleanup.targetedPIDs.isEmpty)
    }

    func testPIDReuseDoesNotPreserveTaskOwnership() {
        let before = observation(
            launcher: node(
                pid: launcherPID,
                parentPID: 1,
                start: launcherStarted,
                ownership: .taskCreated,
                basis: .launcherIdentity,
                liveness: .live
            ),
            descendants: [
                node(
                    pid: childPID,
                    parentPID: launcherPID,
                    start: childStarted,
                    ownership: .taskCreated,
                    basis: .descendantObservedAfterLauncher,
                    liveness: .live
                ),
            ]
        )
        let after = observation(
            launcher: node(
                pid: launcherPID,
                parentPID: 1,
                start: launcherStarted,
                ownership: .taskCreated,
                basis: .preservedFromPriorIdentity,
                liveness: .exited
            ),
            descendants: [
                node(
                    pid: childPID,
                    parentPID: 1,
                    start: Date(timeIntervalSince1970: 1_800_000_001),
                    ownership: .unknown,
                    basis: .notEstablished,
                    liveness: .live
                ),
            ]
        )

        let result = ProcessTreeReconciler.reconcile(before: before, after: after)

        XCTAssertEqual(result.postcondition, .incompleteUnknown)
        XCTAssertEqual(result.disposition, .parentExitedResidualOwnershipUnknown)
        XCTAssertTrue(result.ownedResidualDescendants.isEmpty)
    }

    func testPartialObservationNeverClaimsComplete() {
        let before = observation(
            launcher: node(
                pid: launcherPID,
                parentPID: 1,
                start: launcherStarted,
                ownership: .taskCreated,
                basis: .launcherIdentity,
                liveness: .live
            ),
            descendants: []
        )
        let after = observation(
            launcher: node(
                pid: launcherPID,
                parentPID: 1,
                start: launcherStarted,
                ownership: .taskCreated,
                basis: .preservedFromPriorIdentity,
                liveness: .exited
            ),
            descendants: [],
            coverage: .partial
        )

        let result = ProcessTreeReconciler.reconcile(before: before, after: after)

        XCTAssertEqual(result.disposition, .observationPartial)
        XCTAssertEqual(result.postcondition, .incompleteUnknown)
    }

    func testLiveParentRemainsPendingEvenWhenNoChildIsObserved() {
        let current = observation(
            launcher: node(
                pid: launcherPID,
                parentPID: 1,
                start: launcherStarted,
                ownership: .taskCreated,
                basis: .launcherIdentity,
                liveness: .live
            ),
            descendants: []
        )

        let result = ProcessTreeReconciler.reconcile(
            before: current,
            after: current
        )

        XCTAssertEqual(result.disposition, .parentStillLive)
        XCTAssertEqual(result.postcondition, .pending)
    }

#if os(macOS)
    func testSharedObservationRootDoesNotAcquireTaskOwnership() {
        let root = MacOSProcessTreeObserver.initialRootClassification(
            requestedOwnership: .unknown
        )
        XCTAssertEqual(root.0, .unknown)
        XCTAssertEqual(root.1, .notEstablished)

        let descendant = MacOSProcessTreeObserver.classifyNewDescendantOwnership(
            descendantStartTime: childStarted,
            launcherStartTime: launcherStarted,
            rootOwnership: .unknown
        )
        XCTAssertEqual(descendant.0, .unknown)
        XCTAssertEqual(descendant.1, .notEstablished)

        let preExistingRootDescendant = MacOSProcessTreeObserver.classifyNewDescendantOwnership(
            descendantStartTime: childStarted,
            launcherStartTime: launcherStarted,
            rootOwnership: .preExisting
        )
        XCTAssertEqual(preExistingRootDescendant.0, .unknown)
        XCTAssertEqual(preExistingRootDescendant.1, .notEstablished)
    }

    func testTaskCreatedLauncherStillAuthorizesLaterDescendantOwnership() {
        let root = MacOSProcessTreeObserver.initialRootClassification(
            requestedOwnership: .taskCreated
        )
        XCTAssertEqual(root.0, .taskCreated)
        XCTAssertEqual(root.1, .launcherIdentity)

        let descendant = MacOSProcessTreeObserver.classifyNewDescendantOwnership(
            descendantStartTime: childStarted,
            launcherStartTime: launcherStarted,
            rootOwnership: .taskCreated
        )
        XCTAssertEqual(descendant.0, .taskCreated)
        XCTAssertEqual(descendant.1, .descendantObservedAfterLauncher)
    }
#endif

}
