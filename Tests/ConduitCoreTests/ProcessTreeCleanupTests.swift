import Foundation
import XCTest
@testable import ConduitCore

final class ProcessTreeCleanupTests: XCTestCase {
    private let taskID = "task-cleanup-fixture"
    private let attemptID = "attempt-cleanup-fixture"
    private let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private let launcherStart = Date(timeIntervalSince1970: 1_799_999_900)
    private let childStart = Date(timeIntervalSince1970: 1_799_999_950)

    private var stamp: SupervisionObservationStamp {
        SupervisionObservationStamp(
            authority: .processObserved,
            freshness: .current,
            observedAt: .known(observedAt)
        )
    }

    private func node(
        pid: Int32,
        start: Date,
        ownership: ProcessOwnership,
        basis: ProcessOwnershipBasis,
        liveness: ProcessLiveness,
        parentPID: Int32
    ) -> ProcessNodeObservation {
        ProcessNodeObservation(
            pid: pid,
            parentPID: .known(parentPID),
            processGroupID: .known(900),
            startIdentity: .known(
                ProcessStartIdentity(startTime: .known(start))
            ),
            commandName: .known("fixture"),
            ownership: ownership,
            ownershipBasis: basis,
            liveness: liveness,
            exitObservedAt: liveness == .exited ? .known(observedAt) : .unknown,
            observation: stamp
        )
    }

    private func reconciliation(
        descendants: [ProcessNodeObservation],
        coverage: ProcessTreeObservationCoverage = .complete
    ) -> ProcessTreeReconciliation {
        let launcher = node(
            pid: 900,
            start: launcherStart,
            ownership: .taskCreated,
            basis: .preservedFromPriorIdentity,
            liveness: .exited,
            parentPID: 1
        )
        let after = ProcessTreeObservation(
            taskSessionID: taskID,
            runtimeAttemptID: .known(attemptID),
            providerTurnID: .unknown,
            launcher: .known(launcher),
            descendants: descendants,
            coverage: coverage,
            observation: stamp
        )
        return ProcessTreeReconciler.reconcile(
            before: ProcessTreeObservation(
                taskSessionID: taskID,
                runtimeAttemptID: .known(attemptID),
                providerTurnID: .unknown,
                launcher: .known(
                    node(
                        pid: 900,
                        start: launcherStart,
                        ownership: .taskCreated,
                        basis: .launcherIdentity,
                        liveness: .live,
                        parentPID: 1
                    )
                ),
                descendants: [],
                coverage: .complete,
                observation: stamp
            ),
            after: after,
            requestedOperation: .known(.stopProviderHost)
        )
    }

    func testExactPredeclaredOwnedResidualIsEligible() throws {
        let owned = node(
            pid: 901,
            start: childStart,
            ownership: .taskCreated,
            basis: .preservedFromPriorIdentity,
            liveness: .live,
            parentPID: 1
        )
        let target = ProcessTreeCleanupTarget(
            pid: owned.pid,
            startIdentity: try XCTUnwrap(owned.startIdentity.value),
            ownershipBasis: .descendantObservedAfterLauncher
        )
        let plan = ProcessTreeCleanupPlanner.plan(
            declaredTargets: .known([target]),
            reconciliation: reconciliation(descendants: [owned])
        )
        XCTAssertEqual(owned.ownershipBasis, .preservedFromPriorIdentity)
        XCTAssertEqual(plan.disposition, .eligible)
        XCTAssertEqual(plan.targets, [target])
    }

    func testUnknownResidualRefusesAllCleanup() throws {
        let owned = node(
            pid: 901,
            start: childStart,
            ownership: .taskCreated,
            basis: .preservedFromPriorIdentity,
            liveness: .live,
            parentPID: 1
        )
        let unknown = node(
            pid: 902,
            start: childStart.addingTimeInterval(1),
            ownership: .unknown,
            basis: .notEstablished,
            liveness: .live,
            parentPID: 1
        )
        let target = ProcessTreeCleanupTarget(
            pid: owned.pid,
            startIdentity: try XCTUnwrap(owned.startIdentity.value),
            ownershipBasis: owned.ownershipBasis
        )
        let plan = ProcessTreeCleanupPlanner.plan(
            declaredTargets: .known([target]),
            reconciliation: reconciliation(descendants: [owned, unknown])
        )
        XCTAssertEqual(plan.disposition, .refusedUnknownOwnership)
        XCTAssertTrue(plan.targets.isEmpty)
    }

    func testChangedStartIdentityRefusesCleanup() {
        let owned = node(
            pid: 901,
            start: childStart,
            ownership: .taskCreated,
            basis: .preservedFromPriorIdentity,
            liveness: .live,
            parentPID: 1
        )
        let staleTarget = ProcessTreeCleanupTarget(
            pid: owned.pid,
            startIdentity: ProcessStartIdentity(
                startTime: .known(childStart.addingTimeInterval(-20))
            ),
            ownershipBasis: owned.ownershipBasis
        )
        let plan = ProcessTreeCleanupPlanner.plan(
            declaredTargets: .known([staleTarget]),
            reconciliation: reconciliation(descendants: [owned])
        )
        XCTAssertEqual(plan.disposition, .refusedUnsafeTarget)
        XCTAssertTrue(plan.targets.isEmpty)
    }

    func testPartialCoverageRefusesCleanup() throws {
        let owned = node(
            pid: 901,
            start: childStart,
            ownership: .taskCreated,
            basis: .preservedFromPriorIdentity,
            liveness: .live,
            parentPID: 1
        )
        let target = ProcessTreeCleanupTarget(
            pid: owned.pid,
            startIdentity: try XCTUnwrap(owned.startIdentity.value),
            ownershipBasis: owned.ownershipBasis
        )
        let plan = ProcessTreeCleanupPlanner.plan(
            declaredTargets: .known([target]),
            reconciliation: reconciliation(
                descendants: [owned],
                coverage: .partial
            )
        )
        XCTAssertEqual(plan.disposition, .refusedUnsafeTarget)
        XCTAssertTrue(plan.targets.isEmpty)
    }

    func testNoOwnedResidualNeedsNoCleanup() {
        let preExisting = node(
            pid: 903,
            start: childStart,
            ownership: .preExisting,
            basis: .preExistingObservation,
            liveness: .live,
            parentPID: 1
        )
        let plan = ProcessTreeCleanupPlanner.plan(
            declaredTargets: .known([]),
            reconciliation: reconciliation(descendants: [preExisting])
        )
        XCTAssertEqual(plan.disposition, .notRequired)
        XCTAssertTrue(plan.targets.isEmpty)
    }
}
