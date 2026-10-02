import Foundation

public enum ProcessTreeCleanupPlanningDisposition: String, Codable, Equatable, Sendable {
    case eligible
    case notAuthorizedYet = "not_authorized_yet"
    case notRequired = "not_required"
    case refusedUnknownOwnership = "refused_unknown_ownership"
    case refusedUnsafeTarget = "refused_unsafe_target"
}

public struct ProcessTreeCleanupPlan: Encodable, Equatable, Sendable {
    public let disposition: ProcessTreeCleanupPlanningDisposition
    public let targets: [ProcessTreeCleanupTarget]
    public let reason: String
    public let binding: ProcessTreeCleanupBinding?

    fileprivate init(
        disposition: ProcessTreeCleanupPlanningDisposition,
        targets: [ProcessTreeCleanupTarget],
        reason: String,
        binding: ProcessTreeCleanupBinding? = nil
    ) {
        self.disposition = disposition
        self.targets = targets
        self.reason = reason
        self.binding = binding
    }
}

public enum ProcessTreeCleanupSignalDisposition: String, Codable, Equatable, Sendable {
    case signalRequested = "signal_requested"
    case alreadyExited = "already_exited"
    case identityMismatch = "identity_mismatch"
    case identityUnverifiable = "identity_unverifiable"
    case unsafeTarget = "unsafe_target"
    case signalFailed = "signal_failed"
}

public struct ProcessTreeCleanupSignalResult: Codable, Equatable, Sendable {
    public var target: ProcessTreeCleanupTarget
    public var disposition: ProcessTreeCleanupSignalDisposition
    public var signalName: String
    public var errorCode: OrchestrationValue<Int32>

    public init(
        target: ProcessTreeCleanupTarget,
        disposition: ProcessTreeCleanupSignalDisposition,
        signalName: String = "SIGTERM",
        errorCode: OrchestrationValue<Int32> = .unknown
    ) {
        self.target = target
        self.disposition = disposition
        self.signalName = signalName
        self.errorCode = errorCode
    }
}

public enum ProcessTreeCleanupPlanner {
    public static func plan(
        declaredTargets: OrchestrationValue<[ProcessTreeCleanupTarget]>,
        reconciliation: ProcessTreeReconciliation
    ) -> ProcessTreeCleanupPlan {
        guard reconciliation.requestedOperation.value == .stopProviderHost else {
            return ProcessTreeCleanupPlan(
                disposition: .notRequired,
                targets: [],
                reason: "cleanup is only part of an explicit stop_provider_host lifecycle operation"
            )
        }
        guard reconciliation.after.coverage == .complete else {
            return ProcessTreeCleanupPlan(
                disposition: .refusedUnsafeTarget,
                targets: [],
                reason: "complete post-stop process-tree coverage is required before destructive cleanup"
            )
        }
        guard let before = reconciliation.before,
              before.coverage == .complete,
              let binding = ProcessTreeCleanupBinding.capture(before),
              ProcessTreeCleanupBinding.matches(before: before, after: reconciliation.after),
              reconciliation.taskSessionID == binding.taskSessionID,
              reconciliation.runtimeAttemptID.value == binding.runtimeAttemptID else {
            return ProcessTreeCleanupPlan(disposition: .refusedUnsafeTarget, targets: [],
                reason: "exact task/runtime/launcher binding must be established in both pre-stop and post-stop observations")
        }
        guard reconciliation.after.launcher.value?.liveness == .exited else {
            return ProcessTreeCleanupPlan(
                disposition: .notAuthorizedYet,
                targets: [],
                reason: "provider/runtime parent exit has not been observed; descendant cleanup is not authorized yet",
                binding: binding
            )
        }
        guard reconciliation.unknownOwnershipResidualDescendants.isEmpty else {
            return ProcessTreeCleanupPlan(
                disposition: .refusedUnknownOwnership,
                targets: [],
                reason: "at least one live residual has UNKNOWN ownership; fail closed without signaling descendants"
            )
        }

        let ownedResiduals = reconciliation.ownedResidualDescendants
            .filter { $0.liveness == .live }
            .sorted { $0.pid < $1.pid }
        guard !ownedResiduals.isEmpty else {
            return ProcessTreeCleanupPlan(
                disposition: .notRequired,
                targets: [],
                reason: "no live task-created residual descendant requires cleanup"
            )
        }
        guard before.launcher.value?.ownership == .taskCreated,
              reconciliation.after.launcher.value?.ownership == .taskCreated else {
            return ProcessTreeCleanupPlan(disposition: .refusedUnsafeTarget, targets: [],
                reason: "both exact launcher observations must have task-created ownership")
        }
        guard let declared = declaredTargets.value else {
            return ProcessTreeCleanupPlan(
                disposition: .refusedUnsafeTarget,
                targets: [],
                reason: "preflight did not declare an exact cleanup target set"
            )
        }

        guard Set(declared.map(\.pid)).count == declared.count,
              Set(before.descendants.map(\.pid)).count == before.descendants.count,
              Set(reconciliation.after.descendants.map(\.pid)).count == reconciliation.after.descendants.count else {
            return ProcessTreeCleanupPlan(disposition: .refusedUnsafeTarget, targets: [],
                reason: "duplicate process identities make cleanup scope ambiguous")
        }
        var targets: [ProcessTreeCleanupTarget] = []
        for residual in ownedResiduals {
            guard residual.ownership == .taskCreated,
                  isStrongDescendantBasis(residual.ownershipBasis),
                  let startIdentity = residual.startIdentity.value,
                  startIdentity.startTime.value != nil
            else {
                return ProcessTreeCleanupPlan(
                    disposition: .refusedUnsafeTarget,
                    targets: [],
                    reason: "a live owned residual lacks the exact start identity or ownership basis required for signaling"
                )
            }
            guard let target = declared.first(where: {
                $0.pid == residual.pid
                    && $0.startIdentity == startIdentity
                    && isStrongDescendantBasis($0.ownershipBasis)
                    && $0.binding == binding
            }) else {
                return ProcessTreeCleanupPlan(
                    disposition: .refusedUnsafeTarget,
                    targets: [],
                    reason: "the post-stop owned residual was not present with the same exact identity in the preflight cleanup scope"
                )
            }
            guard residual.pid > 1, residual.pid != binding.launcherPID,
                  let ancestor = before.descendants.first(where: {
                      $0.pid == residual.pid && $0.startIdentity.value == startIdentity
                  }), ancestor.ownership == .taskCreated,
                  isStrongDescendantBasis(ancestor.ownershipBasis) else {
                return ProcessTreeCleanupPlan(disposition: .refusedUnsafeTarget, targets: [],
                    reason: "the exact child must have established task-created ancestry before the stop")
            }
            targets.append(target)
        }
        return ProcessTreeCleanupPlan(
            disposition: .eligible,
            targets: targets,
            reason: "every cleanup target is an exact predeclared task/runtime/launcher-bound residual with prior task-created ancestry",
            binding: binding
        )
    }

    public static func isStrongDescendantBasis(
        _ basis: ProcessOwnershipBasis
    ) -> Bool {
        basis == .descendantObservedAfterLauncher
            || basis == .preservedFromPriorIdentity
    }
}
