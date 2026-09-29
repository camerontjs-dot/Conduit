import Foundation
import XCTest
@testable import ConduitCore

final class ExecutionWorkspaceRuntimeBindingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_100_000)

    func testBindingPreservesProviderIdentityAndCarriesExactWorkspaceLease() {
        let workspace = writableWorkspace()
        let lease = activeLease(for: workspace)
        let original = worker(
            cwd: workspace.path.map(OrchestrationValue.known) ?? .unknown,
            worktree: workspace.path.map(OrchestrationValue.known) ?? .unknown
        )

        let bound = original.bindingExecutionWorkspace(
            workspace,
            activeLease: lease
        )

        XCTAssertEqual(bound.providerSessionID, original.providerSessionID)
        XCTAssertEqual(bound.workspace, original.workspace)
        XCTAssertEqual(bound.executionWorkspace?.workspaceID, workspace.id)
        XCTAssertEqual(bound.executionWorkspace?.path.value, workspace.path)
        XCTAssertEqual(bound.executionWorkspace?.leaseID.value, lease.id)
        XCTAssertEqual(bound.executionWorkspace?.leaseOwnerID.value, lease.ownerID)
    }

    func testReadyWritableWorkspaceWithMatchingLeaseIsLaunchEligible() {
        let workspace = writableWorkspace()
        let lease = activeLease(for: workspace)

        let result = ExecutionWorkspaceRuntimePreflightPlanner.preflight(
            action: .launch,
            requiredWorkspace: workspace,
            reconciliation: readyReconciliation(workspace, lease: lease)
        )

        XCTAssertEqual(result.disposition, .eligible)
        XCTAssertTrue(result.blockingIssues.isEmpty)
        XCTAssertTrue(result.unknownFacts.isEmpty)
        XCTAssertEqual(result.workspaceID, workspace.id)
        XCTAssertEqual(result.expectedLeaseID.value, lease.id)
        XCTAssertEqual(result.providerSessionID.state, .unknown)
    }

    func testReadOnlyReadyWorkspaceDoesNotRequireWriterLease() {
        let workspace = readOnlyWorkspace()

        let result = ExecutionWorkspaceRuntimePreflightPlanner.preflight(
            action: .launch,
            requiredWorkspace: workspace,
            reconciliation: readyReconciliation(workspace, lease: nil)
        )

        XCTAssertEqual(result.disposition, .eligible)
        XCTAssertTrue(result.blockingIssues.isEmpty)
        XCTAssertEqual(result.expectedLeaseID.state, .unknown)
    }

    func testWritableLaunchBlocksWhenLeaseIsMissing() {
        var workspace = writableWorkspace()
        workspace.leaseID = nil

        let result = ExecutionWorkspaceRuntimePreflightPlanner.preflight(
            action: .launch,
            requiredWorkspace: workspace,
            reconciliation: readyReconciliation(workspace, lease: nil)
        )

        XCTAssertEqual(result.disposition, .blocked)
        XCTAssertTrue(result.blockingIssues.contains {
            $0.code == .writerLeaseMissing
        })
    }

    func testExactWorkspaceCWDWorktreeAndLeaseAreReuseEligible() {
        let workspace = writableWorkspace()
        let lease = activeLease(for: workspace)
        let lineage = worker(
            cwd: .known(workspace.path!),
            worktree: .known(workspace.path!)
        ).bindingExecutionWorkspace(
            workspace,
            activeLease: lease
        )

        let result = ExecutionWorkspaceRuntimePreflightPlanner.preflight(
            action: .reuse,
            requiredWorkspace: workspace,
            reconciliation: readyReconciliation(workspace, lease: lease),
            existingWorker: lineage
        )

        XCTAssertEqual(result.disposition, .eligible)
        XCTAssertTrue(result.blockingIssues.isEmpty)
        XCTAssertTrue(result.unknownFacts.isEmpty)
        XCTAssertEqual(result.providerSessionID.value, "ses-runtime-fixture")
    }

    func testReuseBlocksDifferentExecutionWorkspaceIdentity() {
        let required = writableWorkspace(id: "workspace-required")
        let requiredLease = activeLease(for: required)

        let other = writableWorkspace(
            id: "workspace-other",
            leaseID: "lease-other"
        )
        let otherLease = activeLease(for: other)
        let lineage = worker(
            cwd: .known(required.path!),
            worktree: .known(required.path!)
        ).bindingExecutionWorkspace(
            other,
            activeLease: otherLease
        )

        let result = ExecutionWorkspaceRuntimePreflightPlanner.preflight(
            action: .reuse,
            requiredWorkspace: required,
            reconciliation: readyReconciliation(required, lease: requiredLease),
            existingWorker: lineage
        )

        XCTAssertEqual(result.disposition, .blocked)
        XCTAssertTrue(result.blockingIssues.contains {
            $0.code == .workspaceIdentityMismatch
        })
    }

    func testReuseAcceptsDifferentLexicalPathsForSamePhysicalWorkspace() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "conduit-runtime-preflight-alias-\(UUID().uuidString)",
                isDirectory: true
            )
        let real = container.appendingPathComponent("real", isDirectory: true)
        let alias = container.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(
            at: real,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: alias.path,
            withDestinationPath: real.path
        )
        defer { try? FileManager.default.removeItem(at: container) }

        let workspace = writableWorkspace(path: real.path)
        let lease = activeLease(for: workspace)
        let lineage = worker(
            cwd: .known(alias.path),
            worktree: .known(alias.path)
        ).bindingExecutionWorkspace(
            workspace,
            activeLease: lease
        )

        let result = ExecutionWorkspaceRuntimePreflightPlanner.preflight(
            action: .reuse,
            requiredWorkspace: workspace,
            reconciliation: readyReconciliation(workspace, lease: lease),
            existingWorker: lineage
        )

        XCTAssertEqual(result.disposition, .eligible)
        XCTAssertTrue(result.blockingIssues.isEmpty)
        XCTAssertTrue(result.unknownFacts.isEmpty)
    }

    func testReuseWithoutExecutionWorkspaceBindingFailsClosedAsUnknown() {
        let workspace = writableWorkspace()
        let lease = activeLease(for: workspace)
        let lineage = worker(
            cwd: .known(workspace.path!),
            worktree: .known(workspace.path!)
        )

        let result = ExecutionWorkspaceRuntimePreflightPlanner.preflight(
            action: .reuse,
            requiredWorkspace: workspace,
            reconciliation: readyReconciliation(workspace, lease: lease),
            existingWorker: lineage
        )

        XCTAssertEqual(result.disposition, .unknown)
        XCTAssertTrue(result.unknownFacts.contains {
            $0.code == .executionWorkspaceBindingMissing
        })
    }

    func testReuseBlocksWorkerLeaseMismatch() {
        let workspace = writableWorkspace()
        let lease = activeLease(for: workspace)
        var lineage = worker(
            cwd: .known(workspace.path!),
            worktree: .known(workspace.path!)
        ).bindingExecutionWorkspace(
            workspace,
            activeLease: lease
        )
        lineage.executionWorkspace?.leaseID = .known("lease-other")

        let result = ExecutionWorkspaceRuntimePreflightPlanner.preflight(
            action: .reuse,
            requiredWorkspace: workspace,
            reconciliation: readyReconciliation(workspace, lease: lease),
            existingWorker: lineage
        )

        XCTAssertEqual(result.disposition, .blocked)
        XCTAssertTrue(result.blockingIssues.contains {
            $0.code == .workerLeaseMismatch
        })
    }

    func testReuseWithUnknownObservedWorktreeFailsClosedAsUnknown() {
        let workspace = writableWorkspace()
        let lease = activeLease(for: workspace)
        let lineage = worker(
            cwd: .known(workspace.path!),
            worktree: .unknown
        ).bindingExecutionWorkspace(
            workspace,
            activeLease: lease
        )

        let result = ExecutionWorkspaceRuntimePreflightPlanner.preflight(
            action: .reuse,
            requiredWorkspace: workspace,
            reconciliation: readyReconciliation(workspace, lease: lease),
            existingWorker: lineage
        )

        XCTAssertEqual(result.disposition, .unknown)
        XCTAssertTrue(result.unknownFacts.contains {
            $0.code == .workerWorktreeUnknown
        })
    }

    func testDriftedWorkspaceBlocksLaunchEvenWithMatchingLease() {
        let workspace = writableWorkspace()
        let lease = activeLease(for: workspace)
        let reconciliation = ExecutionWorkspaceReconciliation(
            disposition: .drifted,
            worktree: worktree(for: workspace),
            activeLease: lease,
            issues: [
                .headDrift(
                    expected: workspace.expectedHeadSHA!,
                    actual: String(repeating: "b", count: 40)
                ),
            ]
        )

        let result = ExecutionWorkspaceRuntimePreflightPlanner.preflight(
            action: .launch,
            requiredWorkspace: workspace,
            reconciliation: reconciliation
        )

        XCTAssertEqual(result.disposition, .blocked)
        XCTAssertTrue(result.blockingIssues.contains {
            $0.code == .workspaceNotReady
        })
    }

    private func writableWorkspace(
        id: String = "workspace-fixture",
        path: String = "/tmp/conduit-runtime-workspace",
        leaseID: String = "lease-fixture"
    ) -> ExecutionWorkspace {
        ExecutionWorkspace(
            id: id,
            mode: .isolatedGitWorktree,
            authority: .readWrite,
            repository: GitRepositoryIdentity(
                repositoryRoot: "/tmp/conduit-runtime-repository",
                commonGitDirectory: "/tmp/conduit-runtime-repository/.git"
            ),
            path: path,
            baseRevision: "main",
            baseSHA: String(repeating: "a", count: 40),
            branchRef: "refs/heads/conduit/runtime-fixture",
            expectedHeadSHA: String(repeating: "a", count: 40),
            leaseID: leaseID,
            lifecycle: .active,
            provenance: .conduitAllocated,
            createdAt: now
        )
    }

    private func readOnlyWorkspace() -> ExecutionWorkspace {
        ExecutionWorkspace(
            id: "workspace-readonly",
            mode: .sharedReadOnly,
            authority: .readOnly,
            repository: GitRepositoryIdentity(
                repositoryRoot: "/tmp/conduit-readonly-repository",
                commonGitDirectory: "/tmp/conduit-readonly-repository/.git"
            ),
            path: "/tmp/conduit-readonly-repository",
            baseRevision: "main",
            baseSHA: String(repeating: "a", count: 40),
            branchRef: "refs/heads/main",
            expectedHeadSHA: String(repeating: "a", count: 40),
            lifecycle: .active,
            provenance: .humanCheckout,
            createdAt: now
        )
    }

    private func activeLease(for workspace: ExecutionWorkspace) -> WorkspaceLease {
        WorkspaceLease(
            id: workspace.leaseID ?? "lease-fixture",
            workspaceID: workspace.id,
            ownerID: "worker-runtime-fixture",
            acquiredAt: now
        )
    }

    private func readyReconciliation(
        _ workspace: ExecutionWorkspace,
        lease: WorkspaceLease?
    ) -> ExecutionWorkspaceReconciliation {
        ExecutionWorkspaceReconciliation(
            disposition: .ready,
            worktree: worktree(for: workspace),
            activeLease: lease,
            issues: []
        )
    }

    private func worktree(
        for workspace: ExecutionWorkspace
    ) -> GitWorktreeRecord? {
        guard let path = workspace.path,
              let head = workspace.expectedHeadSHA else {
            return nil
        }
        return GitWorktreeRecord(
            path: path,
            headSHA: head,
            branchRef: workspace.branchRef,
            isDetached: workspace.branchRef == nil,
            isBare: false,
            isLocked: false,
            isPrunable: false
        )
    }

    private func worker(
        cwd: OrchestrationValue<String>,
        worktree: OrchestrationValue<String>
    ) -> WorkerLineage {
        let observation = SupervisionObservationStamp(
            authority: .providerObserved,
            freshness: .current,
            observedAt: .known(now)
        )
        return WorkerLineage(
            conduitTaskID: .known("task-runtime-fixture"),
            runtimeAttemptID: .known("attempt-runtime-fixture"),
            runtime: .known("opencode"),
            adapter: .known("http-server"),
            providerHostID: .known("host-runtime-fixture"),
            providerSessionID: .known("ses-runtime-fixture"),
            turns: [],
            workspace: WorkerWorkspaceLineage(
                projectSlug: .known("conduit"),
                cwd: cwd,
                repositoryRoot: .known("/tmp/conduit-runtime-repository"),
                worktree: worktree
            ),
            process: WorkerProcessLineage(
                launcherPID: .unknown,
                processGroupID: .unknown,
                parentPID: .unknown
            ),
            origin: .conduit,
            relationship: .owned,
            writerControllerID: .known("controller-runtime-fixture"),
            terminal: WorkerTerminalState(
                receipt: .unknown,
                verification: .notPerformed,
                objectiveAcceptance: .pending
            ),
            observation: observation,
            providerSpecific: .unknown
        )
    }
}
