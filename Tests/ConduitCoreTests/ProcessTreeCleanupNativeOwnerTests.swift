#if os(macOS)
import Darwin
import Foundation
import XCTest
@testable import ConduitCore

/// Opt-in owner controls. These start only disposable /bin/bash and /bin/sleep
/// processes; they do not launch providers or establish independent acceptance.
final class ProcessTreeCleanupNativeOwnerTests: XCTestCase {
    func testOwnedOrphanCleanupPreservesUnrelatedProcessAndRejectsWrongScope() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CONDUIT_CLEANUP78_NATIVE_OWNER"] == "1" else {
            throw XCTSkip("Opt-in disposable-process owner control; no process launched")
        }
        let evidencePath = try XCTUnwrap(environment["CONDUIT_CLEANUP78_NATIVE_EVIDENCE"])
        let temporary = try ConduitInstanceConfiguration.canonicalPOSIXPath(
            environment["CONDUIT_TEST_TMPDIR"] ?? FileManager.default.temporaryDirectory.path)
        let root = URL(fileURLWithPath: temporary).appendingPathComponent("cleanup78-native-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let childFile = root.appendingPathComponent("child.pid")
        let task = "owned-native-task-" + UUID().uuidString
        let attempt = "owned-native-runtime-" + UUID().uuidString
        var trace: [String: Any] = ["schema_version": 1, "role": "native_owner_control",
                                   "claim": "exact-owned-orphan-and-negative-controls",
                                   "provider_calls": 0, "independent_qualification": "NOT_RUN"]
        let decoy = Process()
        decoy.executableURL = URL(fileURLWithPath: "/bin/sleep")
        decoy.arguments = ["60"]
        try decoy.run()
        let decoyObservation = MacOSProcessTreeObserver.observe(rootPID: decoy.processIdentifier,
            taskSessionID: "owned-decoy", runtimeAttemptID: "owned-decoy-attempt", rootOwnership: .taskCreated)
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/bash")
        launcher.arguments = ["--noprofile", "--norc", "-c",
            "trap 'exit 0' TERM; /bin/sleep 60 & child=$!; echo \"$child\" > \"$1\"; while :; do wait \"$child\"; done",
            "cleanup78-owned-launcher", childFile.path]
        launcher.environment = ["PATH": "/usr/bin:/bin", "TMPDIR": root.path]
        launcher.standardOutput = FileHandle.nullDevice
        launcher.standardError = FileHandle.nullDevice
        var before: ProcessTreeObservation?
        var child: ProcessNodeObservation?
        defer {
            // Teardown is restricted to these created resources and a fresh
            // exact PID/start match; never a process group or name-based kill.
            if let child { tearDownOwned(child, task: task, attempt: attempt) }
            if let before, let node = before.launcher.value {
                tearDownOwned(node, task: task, attempt: attempt)
            } else if launcher.isRunning { launcher.terminate() }
            if let node = decoyObservation.launcher.value {
                tearDownOwned(node, task: "owned-decoy", attempt: "owned-decoy-attempt")
            }
            trace["launcher_running_after_teardown"] = launcher.isRunning
            trace["decoy_running_after_teardown"] = decoy.isRunning
            let data = try? JSONSerialization.data(withJSONObject: trace, options: [.prettyPrinted, .sortedKeys])
            if let data { try? data.write(to: URL(fileURLWithPath: evidencePath), options: .atomic) }
            try? FileManager.default.removeItem(at: root)
        }
        try launcher.run()
        XCTAssertTrue(waitUntil { FileManager.default.fileExists(atPath: childFile.path) })
        let childPID = try XCTUnwrap(Int32(String(contentsOf: childFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        before = MacOSProcessTreeObserver.observe(rootPID: launcher.processIdentifier,
            taskSessionID: task, runtimeAttemptID: attempt, rootOwnership: .taskCreated)
        let observed = try XCTUnwrap(before)
        child = try XCTUnwrap(observed.descendants.first { $0.pid == childPID })
        let ownedChild = try XCTUnwrap(child)
        let binding = try XCTUnwrap(ProcessTreeCleanupBinding.capture(observed))
        XCTAssertEqual(observed.coverage, .complete)
        XCTAssertEqual(ownedChild.ownership, .taskCreated)
        XCTAssertEqual(ownedChild.ownershipBasis, .descendantObservedAfterLauncher)
        let target = ProcessTreeCleanupTarget(pid: ownedChild.pid,
            startIdentity: try XCTUnwrap(ownedChild.startIdentity.value),
            ownershipBasis: ownedChild.ownershipBasis, binding: binding)
        trace["before"] = object(observed)
        trace["decoy_before"] = object(decoyObservation)
        let wrongTask = MacOSProcessTreeObserver.observe(rootPID: launcher.processIdentifier,
            taskSessionID: "wrong-task", runtimeAttemptID: attempt, rootOwnership: .taskCreated, prior: observed)
        let wrongRuntime = MacOSProcessTreeObserver.observe(rootPID: launcher.processIdentifier,
            taskSessionID: task, runtimeAttemptID: "wrong-attempt", rootOwnership: .taskCreated, prior: observed)
        let wrongLauncher = MacOSProcessTreeObserver.observe(rootPID: decoy.processIdentifier,
            taskSessionID: task, runtimeAttemptID: attempt, rootOwnership: .taskCreated, prior: observed)
        XCTAssertEqual(wrongTask.coverage, .unavailable)
        XCTAssertEqual(wrongRuntime.coverage, .unavailable)
        XCTAssertEqual(wrongLauncher.coverage, .unavailable)
        trace["wrong_task_observation"] = object(wrongTask)
        trace["wrong_runtime_observation"] = object(wrongRuntime)
        trace["wrong_launcher_observation"] = object(wrongLauncher)
        // Foundation Process.terminate did not establish an orphan in the
        // preserved first control. Use only the exact owned launcher PID.
        XCTAssertEqual(Darwin.kill(launcher.processIdentifier, SIGTERM), 0)
        XCTAssertTrue(waitUntil { !launcher.isRunning })
        let after = MacOSProcessTreeObserver.observe(rootPID: launcher.processIdentifier,
            taskSessionID: task, runtimeAttemptID: attempt, rootOwnership: .taskCreated, prior: observed)
        let reconciliation = ProcessTreeReconciler.reconcile(before: observed, after: after,
            requestedOperation: .known(.stopProviderHost))
        XCTAssertEqual(after.launcher.value?.liveness, .exited)
        XCTAssertEqual(reconciliation.ownedResidualDescendants.map(\.pid), [childPID])
        let plan = ProcessTreeCleanupPlanner.plan(declaredTargets: .known([target]), reconciliation: reconciliation)
        XCTAssertEqual(plan.disposition, .eligible)
        trace["after_parent_exit"] = object(reconciliation)
        trace["authorized_plan"] = object(plan)
        var wrong = target
        wrong.binding?.taskSessionID = "wrong-task"
        let wrongPlan = ProcessTreeCleanupPlanner.plan(declaredTargets: .known([wrong]), reconciliation: reconciliation)
        XCTAssertEqual(wrongPlan.disposition, .refusedUnsafeTarget)
        trace["wrong_declared_task_plan"] = object(wrongPlan)
        var partial = reconciliation
        partial.after.coverage = .partial
        let partialPlan = ProcessTreeCleanupPlanner.plan(declaredTargets: .known([target]), reconciliation: partial)
        XCTAssertEqual(partialPlan.disposition, .refusedUnsafeTarget)
        trace["partial_coverage_plan"] = object(partialPlan)
        let decoyNode = try XCTUnwrap(decoyObservation.launcher.value)
        let outside = ProcessTreeCleanupTarget(pid: decoyNode.pid,
            startIdentity: try XCTUnwrap(decoyNode.startIdentity.value),
            ownershipBasis: .descendantObservedAfterLauncher, binding: binding)
        let outsideResult = MacOSProcessTreeObserver.signalCleanupTarget(outside, binding: binding, authorization: plan)
        XCTAssertEqual(outsideResult.disposition, .unsafeTarget)
        XCTAssertTrue(decoy.isRunning)
        trace["unrelated_target_refusal"] = object(outsideResult)
        var staleBefore = observed
        staleBefore.descendants[0].startIdentity = .known(ProcessStartIdentity(startTime: .known(Date(timeIntervalSince1970: 1))))
        var staleAfter = after
        staleAfter.descendants[0].startIdentity = staleBefore.descendants[0].startIdentity
        var staleTarget = target
        staleTarget.startIdentity = try XCTUnwrap(staleBefore.descendants[0].startIdentity.value)
        let stalePlan = ProcessTreeCleanupPlanner.plan(declaredTargets: .known([staleTarget]),
            reconciliation: ProcessTreeReconciler.reconcile(before: staleBefore, after: staleAfter,
                requestedOperation: .known(.stopProviderHost)))
        XCTAssertEqual(stalePlan.disposition, .eligible)
        let staleResult = MacOSProcessTreeObserver.signalCleanupTarget(staleTarget, binding: binding, authorization: stalePlan)
        XCTAssertEqual(staleResult.disposition, .identityMismatch)
        trace["stale_start_refusal"] = object(staleResult)
        let result = MacOSProcessTreeObserver.signalCleanupTarget(target, binding: binding, authorization: plan)
        XCTAssertEqual(result.disposition, .signalRequested)
        trace["owned_signal"] = object(result)
        let final = MacOSProcessTreeObserver.observe(rootPID: launcher.processIdentifier,
            taskSessionID: task, runtimeAttemptID: attempt, rootOwnership: .taskCreated, prior: after)
        let finalReconciliation = ProcessTreeReconciler.reconcile(before: observed, after: final,
            requestedOperation: .known(.stopProviderHost))
        XCTAssertTrue(finalReconciliation.ownedResidualDescendants.isEmpty)
        XCTAssertTrue(decoy.isRunning)
        trace["after_owned_signal"] = object(finalReconciliation)
        trace["unrelated_decoy_preserved"] = decoy.isRunning
        trace["owner_assertions_reached_end"] = true
    }

    private func object<T: Encodable>(_ value: T) -> Any {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) else { return NSNull() }
        return object
    }

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    private func tearDownOwned(_ node: ProcessNodeObservation, task: String, attempt: String) {
        let current = MacOSProcessTreeObserver.observe(rootPID: node.pid, taskSessionID: task,
            runtimeAttemptID: attempt, rootOwnership: .taskCreated)
        guard let live = current.launcher.value, live.liveness == .live,
              live.startIdentity == node.startIdentity else { return }
        _ = Darwin.kill(node.pid, SIGTERM)
        _ = waitUntil {
            Darwin.kill(node.pid, 0) != 0 && errno == ESRCH
        }
    }
}
#endif
