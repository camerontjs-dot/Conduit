import Foundation

/// Durable worker-lineage projection of the exact ExecutionWorkspace resource
/// assigned to a runtime.
///
/// This is a handoff/observation record, not a second workspace authority. The
/// live ExecutionWorkspace + WorkspaceLease + reconciliation remain the
/// authorities for launch/reuse decisions.
public struct WorkerExecutionWorkspaceBinding: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var workspaceID: String
    public var mode: ExecutionWorkspaceMode
    public var authority: ExecutionWorkspaceAuthority
    public var path: OrchestrationValue<String>
    public var repositoryRoot: OrchestrationValue<String>
    public var commonGitDirectory: OrchestrationValue<String>
    public var baseSHA: OrchestrationValue<String>
    public var branchRef: OrchestrationValue<String>
    public var expectedHeadSHA: OrchestrationValue<String>
    public var leaseID: OrchestrationValue<String>
    public var leaseOwnerID: OrchestrationValue<String>
    public var lifecycle: ExecutionWorkspaceLifecycleState

    public init(
        schemaVersion: Int = WorkerExecutionWorkspaceBinding.currentSchemaVersion,
        workspaceID: String,
        mode: ExecutionWorkspaceMode,
        authority: ExecutionWorkspaceAuthority,
        path: OrchestrationValue<String>,
        repositoryRoot: OrchestrationValue<String>,
        commonGitDirectory: OrchestrationValue<String>,
        baseSHA: OrchestrationValue<String>,
        branchRef: OrchestrationValue<String>,
        expectedHeadSHA: OrchestrationValue<String>,
        leaseID: OrchestrationValue<String>,
        leaseOwnerID: OrchestrationValue<String>,
        lifecycle: ExecutionWorkspaceLifecycleState
    ) {
        self.schemaVersion = schemaVersion
        self.workspaceID = workspaceID
        self.mode = mode
        self.authority = authority
        self.path = path
        self.repositoryRoot = repositoryRoot
        self.commonGitDirectory = commonGitDirectory
        self.baseSHA = baseSHA
        self.branchRef = branchRef
        self.expectedHeadSHA = expectedHeadSHA
        self.leaseID = leaseID
        self.leaseOwnerID = leaseOwnerID
        self.lifecycle = lifecycle
    }

    public init(
        workspace: ExecutionWorkspace,
        activeLease: WorkspaceLease?
    ) {
        let matchingLease = activeLease.flatMap { lease -> WorkspaceLease? in
            guard lease.workspaceID == workspace.id,
                  lease.status == .active else {
                return nil
            }
            if let expected = workspace.leaseID, lease.id != expected {
                return nil
            }
            return lease
        }

        self.init(
            workspaceID: workspace.id,
            mode: workspace.mode,
            authority: workspace.authority,
            path: workspace.path.map(OrchestrationValue.known) ?? .unknown,
            repositoryRoot: workspace.repository
                .map { .known($0.repositoryRoot) } ?? .unknown,
            commonGitDirectory: workspace.repository
                .map { .known($0.commonGitDirectory) } ?? .unknown,
            baseSHA: workspace.baseSHA.map(OrchestrationValue.known) ?? .unknown,
            branchRef: workspace.branchRef.map(OrchestrationValue.known) ?? .unknown,
            expectedHeadSHA: workspace.expectedHeadSHA
                .map(OrchestrationValue.known) ?? .unknown,
            leaseID: workspace.leaseID.map(OrchestrationValue.known)
                ?? matchingLease.map { .known($0.id) }
                ?? .unknown,
            leaseOwnerID: matchingLease.map { .known($0.ownerID) } ?? .unknown,
            lifecycle: workspace.lifecycle
        )
    }
}

public extension WorkerLineage {
    /// Returns a lineage copy carrying the exact workspace handoff record.
    ///
    /// Existing observed cwd/worktree/provider-session fields are deliberately
    /// not rewritten here. A launch/reuse preflight must compare those
    /// observations with this required workspace rather than making the bind
    /// operation itself look like runtime evidence.
    func bindingExecutionWorkspace(
        _ workspace: ExecutionWorkspace,
        activeLease: WorkspaceLease?
    ) -> WorkerLineage {
        var copy = self
        copy.executionWorkspace = WorkerExecutionWorkspaceBinding(
            workspace: workspace,
            activeLease: activeLease
        )
        return copy
    }
}

public enum ExecutionWorkspaceRuntimeAction: String, Codable, Equatable, Sendable {
    case launch
    case reuse
}

public enum ExecutionWorkspaceRuntimeDisposition: String, Codable, Equatable, Sendable {
    case eligible = "WORKSPACE_RUNTIME_ELIGIBLE"
    case blocked = "WORKSPACE_RUNTIME_BLOCKED"
    case unknown = "WORKSPACE_RUNTIME_UNKNOWN"
}

public enum ExecutionWorkspaceRuntimeIssueCode: String, Codable, Equatable, Sendable {
    case workspaceNotReady = "workspace_not_ready"
    case workspacePathUnknown = "workspace_path_unknown"
    case writerLeaseMissing = "writer_lease_missing"
    case writerLeaseMismatch = "writer_lease_mismatch"
    case workerLineageMissing = "worker_lineage_missing"
    case executionWorkspaceBindingMissing = "execution_workspace_binding_missing"
    case workspaceIdentityMismatch = "workspace_identity_mismatch"
    case workspacePathMismatch = "workspace_path_mismatch"
    case workerCWDUnknown = "worker_cwd_unknown"
    case workerCWDMismatch = "worker_cwd_mismatch"
    case workerWorktreeUnknown = "worker_worktree_unknown"
    case workerWorktreeMismatch = "worker_worktree_mismatch"
    case workerLeaseUnknown = "worker_lease_unknown"
    case workerLeaseMismatch = "worker_lease_mismatch"
    case workerLeaseOwnerUnknown = "worker_lease_owner_unknown"
    case workerLeaseOwnerMismatch = "worker_lease_owner_mismatch"
}

public struct ExecutionWorkspaceRuntimeIssue: Codable, Equatable, Sendable {
    public var code: ExecutionWorkspaceRuntimeIssueCode
    public var detail: String

    public init(code: ExecutionWorkspaceRuntimeIssueCode, detail: String) {
        self.code = code
        self.detail = detail
    }
}

/// Pure launch/reuse decision over already-observed workspace/runtime state.
///
/// No method here allocates a worktree, acquires/releases a lease, starts a
/// provider, adopts a provider session, changes cwd, or mutates WorkerLineage.
public struct ExecutionWorkspaceRuntimePreflight: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var action: ExecutionWorkspaceRuntimeAction
    public var disposition: ExecutionWorkspaceRuntimeDisposition
    public var workspaceID: String
    public var expectedPath: OrchestrationValue<String>
    public var expectedLeaseID: OrchestrationValue<String>
    public var providerSessionID: OrchestrationValue<String>
    public var blockingIssues: [ExecutionWorkspaceRuntimeIssue]
    public var unknownFacts: [ExecutionWorkspaceRuntimeIssue]

    public init(
        schemaVersion: Int = ExecutionWorkspaceRuntimePreflight.currentSchemaVersion,
        action: ExecutionWorkspaceRuntimeAction,
        disposition: ExecutionWorkspaceRuntimeDisposition,
        workspaceID: String,
        expectedPath: OrchestrationValue<String>,
        expectedLeaseID: OrchestrationValue<String>,
        providerSessionID: OrchestrationValue<String>,
        blockingIssues: [ExecutionWorkspaceRuntimeIssue],
        unknownFacts: [ExecutionWorkspaceRuntimeIssue]
    ) {
        self.schemaVersion = schemaVersion
        self.action = action
        self.disposition = disposition
        self.workspaceID = workspaceID
        self.expectedPath = expectedPath
        self.expectedLeaseID = expectedLeaseID
        self.providerSessionID = providerSessionID
        self.blockingIssues = blockingIssues
        self.unknownFacts = unknownFacts
    }
}

public struct ExecutionWorkspaceRuntimeMount: Equatable, Sendable {
    public var preflight: ExecutionWorkspaceRuntimePreflight
    public var executionDirectory: URL?

    public init(
        preflight: ExecutionWorkspaceRuntimePreflight,
        executionDirectory: URL?
    ) {
        self.preflight = preflight
        self.executionDirectory = executionDirectory
    }

    public var isEligible: Bool {
        preflight.disposition == .eligible && executionDirectory != nil
    }
}

public enum ExecutionWorkspaceRuntimeMountPlanner {
    public static func plan(
        action: ExecutionWorkspaceRuntimeAction,
        requiredWorkspace: ExecutionWorkspace,
        reconciliation: ExecutionWorkspaceReconciliation,
        existingWorker: WorkerLineage? = nil,
        expectedLeaseOwnerID: String? = nil
    ) -> ExecutionWorkspaceRuntimeMount {
        let preflight = ExecutionWorkspaceRuntimePreflightPlanner.preflight(
            action: action,
            requiredWorkspace: requiredWorkspace,
            reconciliation: reconciliation,
            existingWorker: existingWorker,
            expectedLeaseOwnerID: expectedLeaseOwnerID
        )
        guard preflight.disposition == .eligible,
              let path = preflight.expectedPath.value else {
            return ExecutionWorkspaceRuntimeMount(
                preflight: preflight,
                executionDirectory: nil
            )
        }
        return ExecutionWorkspaceRuntimeMount(
            preflight: preflight,
            executionDirectory: URL(
                fileURLWithPath: ExecutionWorkspacePathIdentity.canonicalPath(path),
                isDirectory: true
            )
        )
    }
}

public enum ExecutionWorkspaceRuntimePreflightPlanner {
    public static func preflight(
        action: ExecutionWorkspaceRuntimeAction,
        requiredWorkspace: ExecutionWorkspace,
        reconciliation: ExecutionWorkspaceReconciliation,
        existingWorker: WorkerLineage? = nil,
        expectedLeaseOwnerID: String? = nil
    ) -> ExecutionWorkspaceRuntimePreflight {
        var blocking: [ExecutionWorkspaceRuntimeIssue] = []
        var unknown: [ExecutionWorkspaceRuntimeIssue] = []

        let expectedPath = requiredWorkspace.path
            .map(OrchestrationValue.known) ?? .unknown
        let expectedLeaseID = requiredWorkspace.leaseID
            .map(OrchestrationValue.known) ?? .unknown
        let providerSessionID = existingWorker?.providerSessionID ?? .unknown

        guard let requiredPath = requiredWorkspace.path else {
            unknown.append(
                issue(
                    .workspacePathUnknown,
                    "required execution workspace path is UNKNOWN"
                )
            )
            return result(
                action: action,
                workspace: requiredWorkspace,
                expectedPath: expectedPath,
                expectedLeaseID: expectedLeaseID,
                providerSessionID: providerSessionID,
                blocking: blocking,
                unknown: unknown
            )
        }

        switch reconciliation.disposition {
        case .ready:
            break
        case .unknown:
            unknown.append(
                issue(
                    .workspaceNotReady,
                    "workspace reconciliation is UNKNOWN"
                )
            )
        case .dirty, .drifted, .writerCollision, .missing, .preservationRequired:
            blocking.append(
                issue(
                    .workspaceNotReady,
                    "workspace reconciliation is \(reconciliation.disposition.rawValue)"
                )
            )
        }

        if requiredWorkspace.authority == .readWrite {
            guard let requiredLeaseID = requiredWorkspace.leaseID else {
                blocking.append(
                    issue(
                        .writerLeaseMissing,
                        "writable execution workspace has no bound writer lease"
                    )
                )
                return result(
                    action: action,
                    workspace: requiredWorkspace,
                    expectedPath: expectedPath,
                    expectedLeaseID: expectedLeaseID,
                    providerSessionID: providerSessionID,
                    blocking: blocking,
                    unknown: unknown
                )
            }

            guard let activeLease = reconciliation.activeLease,
                  activeLease.status == .active else {
                blocking.append(
                    issue(
                        .writerLeaseMissing,
                        "required writer lease \(requiredLeaseID) is not observed active"
                    )
                )
                return result(
                    action: action,
                    workspace: requiredWorkspace,
                    expectedPath: expectedPath,
                    expectedLeaseID: expectedLeaseID,
                    providerSessionID: providerSessionID,
                    blocking: blocking,
                    unknown: unknown
                )
            }

            if activeLease.workspaceID != requiredWorkspace.id
                || activeLease.id != requiredLeaseID {
                blocking.append(
                    issue(
                        .writerLeaseMismatch,
                        "active lease does not match required workspace/lease identity"
                    )
                )
            }
            if let expectedLeaseOwnerID, activeLease.ownerID != expectedLeaseOwnerID {
                blocking.append(issue(.workerLeaseOwnerMismatch, "active writer lease belongs to a different runtime task owner"))
            }
        }

        if action == .reuse {
            guard let worker = existingWorker else {
                unknown.append(
                    issue(
                        .workerLineageMissing,
                        "reuse requested without an observed WorkerLineage"
                    )
                )
                return result(
                    action: action,
                    workspace: requiredWorkspace,
                    expectedPath: expectedPath,
                    expectedLeaseID: expectedLeaseID,
                    providerSessionID: providerSessionID,
                    blocking: blocking,
                    unknown: unknown
                )
            }

            validateReuse(
                requiredWorkspace: requiredWorkspace,
                requiredPath: requiredPath,
                worker: worker,
                activeLease: reconciliation.activeLease,
                blocking: &blocking,
                unknown: &unknown
            )
        }

        return result(
            action: action,
            workspace: requiredWorkspace,
            expectedPath: expectedPath,
            expectedLeaseID: expectedLeaseID,
            providerSessionID: providerSessionID,
            blocking: blocking,
            unknown: unknown
        )
    }

    private static func validateReuse(
        requiredWorkspace: ExecutionWorkspace,
        requiredPath: String,
        worker: WorkerLineage,
        activeLease: WorkspaceLease?,
        blocking: inout [ExecutionWorkspaceRuntimeIssue],
        unknown: inout [ExecutionWorkspaceRuntimeIssue]
    ) {
        guard let binding = worker.executionWorkspace else {
            unknown.append(
                issue(
                    .executionWorkspaceBindingMissing,
                    "worker has no exact ExecutionWorkspace binding"
                )
            )
            return
        }

        if binding.workspaceID != requiredWorkspace.id {
            blocking.append(
                issue(
                    .workspaceIdentityMismatch,
                    "worker workspace \(binding.workspaceID) does not match required \(requiredWorkspace.id)"
                )
            )
        }

        if let boundPath = binding.path.value {
            if !pathsMatch(boundPath, requiredPath) {
                blocking.append(
                    issue(
                        .workspacePathMismatch,
                        "worker execution-workspace path does not match the required path"
                    )
                )
            }
        } else {
            unknown.append(
                issue(
                    .workspacePathUnknown,
                    "worker execution-workspace binding path is UNKNOWN"
                )
            )
        }

        if let cwd = worker.workspace.cwd.value {
            if !pathsMatch(cwd, requiredPath) {
                blocking.append(
                    issue(
                        .workerCWDMismatch,
                        "observed worker cwd does not match the required workspace"
                    )
                )
            }
        } else {
            unknown.append(
                issue(
                    .workerCWDUnknown,
                    "observed worker cwd is UNKNOWN"
                )
            )
        }

        if requiredWorkspace.mode == .isolatedGitWorktree
            || requiredWorkspace.mode == .existingWorktree {
            if let worktree = worker.workspace.worktree.value {
                if !pathsMatch(worktree, requiredPath) {
                    blocking.append(
                        issue(
                            .workerWorktreeMismatch,
                            "observed worker worktree does not match the required workspace"
                        )
                    )
                }
            } else {
                unknown.append(
                    issue(
                        .workerWorktreeUnknown,
                        "observed worker worktree is UNKNOWN"
                    )
                )
            }
        }

        if requiredWorkspace.authority == .readWrite,
           let requiredLeaseID = requiredWorkspace.leaseID {
            if let workerLeaseID = binding.leaseID.value {
                if workerLeaseID != requiredLeaseID {
                    blocking.append(
                        issue(
                            .workerLeaseMismatch,
                            "worker lineage lease does not match required writer lease"
                        )
                    )
                }
            } else {
                unknown.append(
                    issue(
                        .workerLeaseUnknown,
                        "worker lineage writer lease is UNKNOWN"
                    )
                )
            }
            if let owner = binding.leaseOwnerID.value,
               let activeLease {
                if owner != activeLease.ownerID {
                    blocking.append(issue(.workerLeaseOwnerMismatch, "worker lineage owner does not match the active workspace writer"))
                }
            } else {
                unknown.append(issue(.workerLeaseOwnerUnknown, "worker lineage writer owner is UNKNOWN"))
            }
        }
    }

    private static func pathsMatch(_ lhs: String, _ rhs: String) -> Bool {
        ExecutionWorkspacePathIdentity.canonicalPath(lhs)
            == ExecutionWorkspacePathIdentity.canonicalPath(rhs)
    }

    private static func issue(
        _ code: ExecutionWorkspaceRuntimeIssueCode,
        _ detail: String
    ) -> ExecutionWorkspaceRuntimeIssue {
        ExecutionWorkspaceRuntimeIssue(code: code, detail: detail)
    }

    private static func result(
        action: ExecutionWorkspaceRuntimeAction,
        workspace: ExecutionWorkspace,
        expectedPath: OrchestrationValue<String>,
        expectedLeaseID: OrchestrationValue<String>,
        providerSessionID: OrchestrationValue<String>,
        blocking: [ExecutionWorkspaceRuntimeIssue],
        unknown: [ExecutionWorkspaceRuntimeIssue]
    ) -> ExecutionWorkspaceRuntimePreflight {
        let disposition: ExecutionWorkspaceRuntimeDisposition
        if !blocking.isEmpty {
            disposition = .blocked
        } else if !unknown.isEmpty {
            disposition = .unknown
        } else {
            disposition = .eligible
        }

        return ExecutionWorkspaceRuntimePreflight(
            action: action,
            disposition: disposition,
            workspaceID: workspace.id,
            expectedPath: expectedPath,
            expectedLeaseID: expectedLeaseID,
            providerSessionID: providerSessionID,
            blockingIssues: blocking,
            unknownFacts: unknown
        )
    }
}
