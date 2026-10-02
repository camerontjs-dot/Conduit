import Foundation
import XCTest
#if os(macOS)
import Darwin
#endif
@testable import ConduitCore

final class ProcessTreeCleanupTests: XCTestCase {
    private let taskID = "task-cleanup-fixture"
    private let attemptID = "attempt-cleanup-fixture"
    private let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private let launcherStart = Date(timeIntervalSince1970: 1_799_999_900)
    private let childStart = Date(timeIntervalSince1970: 1_799_999_950)

    private var binding: ProcessTreeCleanupBinding {
        ProcessTreeCleanupBinding(taskSessionID: taskID, runtimeAttemptID: attemptID,
            launcherPID: 900, launcherStartIdentity: ProcessStartIdentity(startTime: .known(launcherStart)))
    }

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

    private func authorization(for target: ProcessTreeCleanupTarget) -> ProcessTreeCleanupPlan {
        let owned = node(pid: target.pid, start: target.startIdentity.startTime.value ?? childStart,
            ownership: .taskCreated, basis: .preservedFromPriorIdentity, liveness: .live, parentPID: 1)
        return ProcessTreeCleanupPlanner.plan(declaredTargets: .known([target]),
                                              reconciliation: reconciliation(descendants: [owned]))
    }

    private func reconciliation(
        descendants: [ProcessNodeObservation],
        coverage: ProcessTreeObservationCoverage = .complete,
        launcherLiveness: ProcessLiveness = .exited
    ) -> ProcessTreeReconciliation {
        let launcher = node(
            pid: 900,
            start: launcherStart,
            ownership: .taskCreated,
            basis: .preservedFromPriorIdentity,
            liveness: launcherLiveness,
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
                descendants: descendants.map { node in
                    var before = node
                    before.parentPID = .known(900)
                    if before.ownership == .taskCreated { before.ownershipBasis = .descendantObservedAfterLauncher }
                    return before
                },
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
            ownershipBasis: .descendantObservedAfterLauncher,
            binding: binding
        )
        let plan = ProcessTreeCleanupPlanner.plan(
            declaredTargets: .known([target]),
            reconciliation: reconciliation(descendants: [owned])
        )
        XCTAssertEqual(owned.ownershipBasis, .preservedFromPriorIdentity)
        XCTAssertEqual(plan.disposition, .eligible)
        XCTAssertEqual(plan.targets, [target])
    }

    func testCrossTaskRuntimeOrLauncherPriorNeverGrantsCleanup() throws {
        let owned = node(pid: 901, start: childStart, ownership: .taskCreated,
                         basis: .preservedFromPriorIdentity, liveness: .live, parentPID: 1)
        let target = ProcessTreeCleanupTarget(pid: owned.pid,
                                             startIdentity: try XCTUnwrap(owned.startIdentity.value),
                                             ownershipBasis: .descendantObservedAfterLauncher, binding: binding)
        for changedAxis in ["task", "runtime", "launcher"] {
            let original = reconciliation(descendants: [owned])
            var after = original.after
            if changedAxis == "task" { after.taskSessionID = "unrelated-task" }
            if changedAxis == "runtime" { after.runtimeAttemptID = .known("replacement-attempt") }
            if changedAxis == "launcher", var launcher = after.launcher.value {
                launcher.pid = 999
                after.launcher = .known(launcher)
            }
            let mixed = ProcessTreeReconciler.reconcile(before: original.before, after: after,
                                                       requestedOperation: .known(.stopProviderHost))
            let plan = ProcessTreeCleanupPlanner.plan(declaredTargets: .known([target]), reconciliation: mixed)
            XCTAssertNotEqual(plan.disposition, .eligible, changedAxis + " authority must not be borrowed")
            XCTAssertTrue(plan.targets.isEmpty, changedAxis + " mismatch must not signal an identity")
        }
    }

    func testLegacyTargetAndUndeclaredAncestryCannotSignal() throws {
        let owned = node(pid: 901, start: childStart, ownership: .taskCreated,
                         basis: .preservedFromPriorIdentity, liveness: .live, parentPID: 1)
        let legacy = ProcessTreeCleanupTarget(pid: owned.pid, startIdentity: try XCTUnwrap(owned.startIdentity.value),
                                              ownershipBasis: .descendantObservedAfterLauncher)
        var current = reconciliation(descendants: [owned])
        XCTAssertEqual(ProcessTreeCleanupPlanner.plan(declaredTargets: .known([legacy]), reconciliation: current).disposition, .refusedUnsafeTarget)
        var target = legacy; target.binding = binding
        current.before?.descendants = []
        XCTAssertEqual(ProcessTreeCleanupPlanner.plan(declaredTargets: .known([target]), reconciliation: current).disposition, .refusedUnsafeTarget)
    }

    func testWrongDeclaredBindingAndDuplicateIdentityAreRefused() throws {
        let owned = node(pid: 901, start: childStart, ownership: .taskCreated,
                         basis: .preservedFromPriorIdentity, liveness: .live, parentPID: 1)
        let current = reconciliation(descendants: [owned])
        let correct = ProcessTreeCleanupTarget(pid: owned.pid, startIdentity: try XCTUnwrap(owned.startIdentity.value),
                                               ownershipBasis: .descendantObservedAfterLauncher, binding: binding)
        for axis in ["task", "runtime", "launcher", "launcher-start"] {
            var wrong = correct
            if axis == "task" { wrong.binding?.taskSessionID = "other-task" }
            if axis == "runtime" { wrong.binding?.runtimeAttemptID = "other-attempt" }
            if axis == "launcher" { wrong.binding?.launcherPID = 999 }
            if axis == "launcher-start" { wrong.binding?.launcherStartIdentity.startTime = .known(launcherStart.addingTimeInterval(-10)) }
            let plan = ProcessTreeCleanupPlanner.plan(declaredTargets: .known([wrong]), reconciliation: current)
            XCTAssertEqual(plan.disposition, .refusedUnsafeTarget, axis)
            XCTAssertTrue(plan.targets.isEmpty)
        }
        XCTAssertEqual(ProcessTreeCleanupPlanner.plan(declaredTargets: .known([correct, correct]), reconciliation: current).disposition, .refusedUnsafeTarget)
    }

    func testLegacyTargetDecodePreservesAbsenceOfAuthority() throws {
        let target = ProcessTreeCleanupTarget(pid: 901, startIdentity: ProcessStartIdentity(startTime: .known(childStart)),
                                              ownershipBasis: .descendantObservedAfterLauncher)
        let encoded = try JSONEncoder().encode(target)
        let decoded = try JSONDecoder().decode(ProcessTreeCleanupTarget.self, from: encoded)
        XCTAssertNil(decoded.binding)
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
            ownershipBasis: owned.ownershipBasis,
            binding: binding
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
            ownershipBasis: owned.ownershipBasis,
            binding: binding
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
            ownershipBasis: owned.ownershipBasis,
            binding: binding
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

    func testLiveParentDoesNotAuthorizeCleanupYet() throws {
        let owned = node(
            pid: 901,
            start: childStart,
            ownership: .taskCreated,
            basis: .preservedFromPriorIdentity,
            liveness: .live,
            parentPID: 900
        )
        let target = ProcessTreeCleanupTarget(
            pid: owned.pid,
            startIdentity: try XCTUnwrap(owned.startIdentity.value),
            ownershipBasis: .descendantObservedAfterLauncher,
            binding: binding
        )
        let plan = ProcessTreeCleanupPlanner.plan(
            declaredTargets: .known([target]),
            reconciliation: reconciliation(
                descendants: [owned],
                launcherLiveness: .live
            )
        )
        XCTAssertEqual(plan.disposition, .notAuthorizedYet)
        XCTAssertTrue(plan.targets.isEmpty)
    }

    func testLiveParentCannotDeferUnsafeDeclaredScope() throws {
        let owned = node(pid: 901, start: childStart, ownership: .taskCreated,
            basis: .descendantObservedAfterLauncher, liveness: .live, parentPID: 900)
        let current = reconciliation(descendants: [owned], launcherLiveness: .live)
        let legacy = ProcessTreeCleanupTarget(pid: owned.pid,
            startIdentity: try XCTUnwrap(owned.startIdentity.value), ownershipBasis: owned.ownershipBasis)
        XCTAssertEqual(ProcessTreeCleanupPlanner.plan(declaredTargets: .known([legacy]), reconciliation: current).disposition, .refusedUnsafeTarget)
        XCTAssertEqual(ProcessTreeCleanupPlanner.plan(declaredTargets: .known([]), reconciliation: current).disposition, .refusedUnsafeTarget)
    }

    func testReadReobservationPreservesReceiptOnlyForExactScope() {
        var previous = reconciliation(descendants: [])
        previous.cleanup = ProcessTreeCleanupReceipt(disposition: .completed, targetedPIDs: [901],
            targetingBasis: .known(["exact owned child exit was observed"]), reobservedAfterCleanup: .known(true))
        let current = ProcessTreeReconciler.reobserve(previous: previous, after: previous.after)
        XCTAssertEqual(current.cleanup, previous.cleanup)
        for axis in ["task", "runtime", "launcher", "start"] {
            var wrong = previous.after
            if axis == "task" { wrong.taskSessionID = "other-task" }
            if axis == "runtime" { wrong.runtimeAttemptID = .known("other-attempt") }
            if axis == "launcher", var root = wrong.launcher.value { root.pid = 999; wrong.launcher = .known(root) }
            if axis == "start", var root = wrong.launcher.value { root.startIdentity = .known(ProcessStartIdentity(startTime: .known(childStart))); wrong.launcher = .known(root) }
            XCTAssertNotEqual(ProcessTreeReconciler.reobserve(previous: previous, after: wrong).cleanup, previous.cleanup, axis)
        }
    }

    func testReadPreservesFailedCleanupAndFreshResidualPostcondition() {
        let owned = node(pid: 901, start: childStart, ownership: .taskCreated,
            basis: .preservedFromPriorIdentity, liveness: .live, parentPID: 1)
        var previous = reconciliation(descendants: [owned])
        previous.cleanup = ProcessTreeCleanupReceipt(disposition: .signalFailed, targetedPIDs: [901],
            targetingBasis: .known(["signal request failed"]), reobservedAfterCleanup: .known(true))
        let current = ProcessTreeReconciler.reobserve(previous: previous, after: previous.after)
        XCTAssertEqual(current.cleanup.disposition, .signalFailed)
        XCTAssertEqual(current.postcondition, .incompleteResidual)
        XCTAssertEqual(current.ownedResidualDescendants.map(\.pid), [901])
    }

#if os(macOS)
    func testSignalBoundaryRefusesMismatchedCurrentPIDWithoutSignaling() {
        let target = ProcessTreeCleanupTarget(
            pid: Int32(getpid()),
            startIdentity: ProcessStartIdentity(
                startTime: .known(Date(timeIntervalSince1970: 1))
            ),
            ownershipBasis: .preservedFromPriorIdentity,
            binding: binding
        )
        let result = MacOSProcessTreeObserver.signalCleanupTarget(target, binding: binding, authorization: authorization(for: target))
        XCTAssertEqual(result.disposition, .identityMismatch)
    }

    func testSignalBoundaryRefusesWrongRuntimeScopeBeforeSignal() {
        let target = ProcessTreeCleanupTarget(pid: Int32(getpid()),
            startIdentity: ProcessStartIdentity(startTime: .known(childStart)),
            ownershipBasis: .descendantObservedAfterLauncher, binding: binding)
        var other = binding; other.runtimeAttemptID = "different-attempt"
        XCTAssertEqual(MacOSProcessTreeObserver.signalCleanupTarget(target, binding: other, authorization: authorization(for: target)).disposition, .unsafeTarget)
    }

    func testSignalBoundaryRefusesTargetOutsideAuthorizedPlan() {
        let target = ProcessTreeCleanupTarget(pid: 901, startIdentity: ProcessStartIdentity(startTime: .known(childStart)),
            ownershipBasis: .descendantObservedAfterLauncher, binding: binding)
        let permitted = authorization(for: target)
        var other = target; other.pid = Int32(getpid())
        XCTAssertEqual(MacOSProcessTreeObserver.signalCleanupTarget(other, binding: binding,
            authorization: permitted).disposition, .unsafeTarget)
    }

    func testSignalBoundaryRejectsPIDOneWithoutSignaling() {
        let target = ProcessTreeCleanupTarget(
            pid: 1,
            startIdentity: ProcessStartIdentity(
                startTime: .known(observedAt)
            ),
            ownershipBasis: .descendantObservedAfterLauncher,
            binding: binding
        )
        let result = MacOSProcessTreeObserver.signalCleanupTarget(target, binding: binding, authorization: authorization(for: target))
        XCTAssertEqual(result.disposition, .unsafeTarget)
    }
#endif

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
