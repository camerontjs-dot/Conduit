import Foundation

public enum ProcessTreeCleanupPlanningDisposition: String, Codable, Equatable, Sendable {
    case eligible
    case notRequired = "not_required"
    case refusedUnknownOwnership = "refused_unknown_ownership"
    case refusedUnsafeTarget = "refused_unsafe_target"
}

public struct ProcessTreeCleanupPlan: Codable, Equatable, Sendable {
    public var disposition: ProcessTreeCleanupPlanningDisposition
    public var targets: [ProcessTreeCleanupTarget]
    public var reason: String

    public init(
        disposition: ProcessTreeCleanupPlanningDisposition,
        targets: [ProcessTreeCleanupTarget],
        reason: String
    ) {
        self.disposition = disposition
        self.targets = targets
        self.reason = reason
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
        guard reconciliation.after.launcher.value?.liveness == .exited else {
            return ProcessTreeCleanupPlan(
                disposition: .notRequired,
                targets: [],
                reason: "provider/runtime parent exit has not been observed; descendant cleanup is not authorized yet"
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
        guard let declared = declaredTargets.value else {
            return ProcessTreeCleanupPlan(
                disposition: .refusedUnsafeTarget,
                targets: [],
                reason: "preflight did not declare an exact cleanup target set"
            )
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
                    && $0.ownershipBasis == residual.ownershipBasis
            }) else {
                return ProcessTreeCleanupPlan(
                    disposition: .refusedUnsafeTarget,
                    targets: [],
                    reason: "the post-stop owned residual was not present with the same exact identity in the preflight cleanup scope"
                )
            }
            targets.append(target)
        }
        return ProcessTreeCleanupPlan(
            disposition: .eligible,
            targets: targets,
            reason: "every cleanup target is a live task-created residual with an exact predeclared PID/start identity and strong ownership basis"
        )
    }

    public static func isStrongDescendantBasis(
        _ basis: ProcessOwnershipBasis
    ) -> Bool {
        basis == .descendantObservedAfterLauncher
            || basis == .preservedFromPriorIdentity
    }
}
