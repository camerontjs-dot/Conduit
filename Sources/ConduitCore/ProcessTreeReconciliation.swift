import Foundation

/// Ownership classification for one OS process observed in a task's process
/// topology. An observed descendant is not automatically task-owned: the
/// classification must be supported by a runtime-bound observation basis.
public enum ProcessOwnership: String, Codable, Equatable, Sendable {
    case taskCreated = "task_created"
    case preExisting = "pre_existing"
    case unknown
}

public enum ProcessOwnershipBasis: String, Codable, Equatable, Sendable {
    case launcherIdentity = "launcher_identity"
    case descendantObservedAfterLauncher = "descendant_observed_after_launcher"
    case preservedFromPriorIdentity = "preserved_from_prior_identity"
    case preExistingObservation = "pre_existing_observation"
    case notEstablished = "not_established"
}

public enum ProcessLiveness: String, Codable, Equatable, Sendable {
    case live
    case exited
    case unknown
}

public enum ProcessTreeObservationCoverage: String, Codable, Equatable, Sendable {
    case complete
    case partial
    case unavailable
    case ambiguous
}

public enum ProcessTreeReconciliationDisposition: String, Codable, Equatable, Sendable {
    case parentExitedNoOwnedResidual = "parent_exited_no_owned_residual"
    case parentExitedOwnedResidual = "parent_exited_owned_residual"
    case parentExitedResidualOwnershipUnknown = "parent_exited_residual_ownership_unknown"
    case parentExitedOwnedAndUnknownResidual = "parent_exited_owned_and_unknown_residual"
    case parentStillLive = "parent_still_live"
    case observationPartial = "observation_partial"
    case observationAmbiguous = "observation_ambiguous"
    case observationUnavailable = "observation_unavailable"
}

public enum ProcessTreePostcondition: String, Codable, Equatable, Sendable {
    case complete
    case incompleteResidual = "incomplete_residual"
    case incompleteUnknown = "incomplete_unknown"
    case pending
    case unavailable
}

public enum ProcessTreeCleanupDisposition: String, Codable, Equatable, Sendable {
    case notAttempted = "not_attempted"
    case notRequired = "not_required"
    case refusedUnknownOwnership = "refused_unknown_ownership"
    case refusedUnsafeTarget = "refused_unsafe_target"
    case signalFailed = "signal_failed"
    case completed
    case incompleteResidual = "incomplete_residual"
}

/// Complete process scope attached to a stop intent before any mutation.
/// A decoded legacy target without this binding grants no cleanup authority.
public struct ProcessTreeCleanupBinding: Codable, Equatable, Sendable {
    public var taskSessionID: String
    public var runtimeAttemptID: String
    public var launcherPID: Int32
    public var launcherStartIdentity: ProcessStartIdentity

    public init(taskSessionID: String, runtimeAttemptID: String, launcherPID: Int32,
                launcherStartIdentity: ProcessStartIdentity) {
        self.taskSessionID = taskSessionID
        self.runtimeAttemptID = runtimeAttemptID
        self.launcherPID = launcherPID
        self.launcherStartIdentity = launcherStartIdentity
    }

    public var isComplete: Bool {
        !taskSessionID.isEmpty && !runtimeAttemptID.isEmpty && launcherPID > 1
            && launcherStartIdentity.startTime.value != nil
    }

    public static func capture(_ observation: ProcessTreeObservation) -> Self? {
        guard let attempt = observation.runtimeAttemptID.value,
              let launcher = observation.launcher.value,
              let identity = launcher.startIdentity.value else { return nil }
        let binding = Self(taskSessionID: observation.taskSessionID,
                           runtimeAttemptID: attempt, launcherPID: launcher.pid,
                           launcherStartIdentity: identity)
        return binding.isComplete ? binding : nil
    }

    public static func matches(before: ProcessTreeObservation, after: ProcessTreeObservation) -> Bool {
        guard let first = capture(before), let last = capture(after) else { return false }
        return first == last
    }
}

public struct ProcessTreeCleanupTarget: Codable, Equatable, Sendable {
    public var pid: Int32
    public var startIdentity: ProcessStartIdentity
    public var ownershipBasis: ProcessOwnershipBasis
    public var binding: ProcessTreeCleanupBinding?

    public init(
        pid: Int32,
        startIdentity: ProcessStartIdentity,
        ownershipBasis: ProcessOwnershipBasis,
        binding: ProcessTreeCleanupBinding? = nil
    ) {
        self.pid = pid
        self.startIdentity = startIdentity
        self.ownershipBasis = ownershipBasis
        self.binding = binding
    }
}

/// The strongest practical process identity available to the macOS observer
/// in this slice. PID alone is deliberately insufficient because it can be
/// reused after a process exits.
public struct ProcessStartIdentity: Codable, Equatable, Sendable {
    public var startTime: OrchestrationValue<Date>

    public init(startTime: OrchestrationValue<Date>) {
        self.startTime = startTime
    }
}

/// One provider-neutral OS process observation. `parentPID` is the relation at
/// this observation time, not a durable ownership claim. A reparented child
/// can therefore retain task ownership only through its previously observed
/// process identity and ownership basis.
public struct ProcessNodeObservation: Codable, Equatable, Sendable {
    public var pid: Int32
    public var parentPID: OrchestrationValue<Int32>
    public var processGroupID: OrchestrationValue<Int32>
    public var startIdentity: OrchestrationValue<ProcessStartIdentity>
    public var commandName: OrchestrationValue<String>
    public var ownership: ProcessOwnership
    public var ownershipBasis: ProcessOwnershipBasis
    public var liveness: ProcessLiveness
    public var exitObservedAt: OrchestrationValue<Date>
    public var observation: SupervisionObservationStamp

    public init(
        pid: Int32,
        parentPID: OrchestrationValue<Int32>,
        processGroupID: OrchestrationValue<Int32>,
        startIdentity: OrchestrationValue<ProcessStartIdentity>,
        commandName: OrchestrationValue<String>,
        ownership: ProcessOwnership,
        ownershipBasis: ProcessOwnershipBasis,
        liveness: ProcessLiveness,
        exitObservedAt: OrchestrationValue<Date> = .unknown,
        observation: SupervisionObservationStamp
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.processGroupID = processGroupID
        self.startIdentity = startIdentity
        self.commandName = commandName
        self.ownership = ownership
        self.ownershipBasis = ownershipBasis
        self.liveness = liveness
        self.exitObservedAt = exitObservedAt
        self.observation = observation
    }
}

/// A point-in-time process topology observation. The launcher is optional in
/// the model because a post-stop sample may be unable to find the old PID; an
/// unavailable launcher is never represented as an invented process.
public struct ProcessTreeObservation: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var taskSessionID: String
    public var runtimeAttemptID: OrchestrationValue<String>
    public var providerTurnID: OrchestrationValue<String>
    public var launcher: OrchestrationValue<ProcessNodeObservation>
    public var descendants: [ProcessNodeObservation]
    public var coverage: ProcessTreeObservationCoverage
    public var observation: SupervisionObservationStamp
    public var diagnostics: OrchestrationValue<[String]>

    public init(
        schemaVersion: Int = ProcessTreeObservation.currentSchemaVersion,
        taskSessionID: String,
        runtimeAttemptID: OrchestrationValue<String>,
        providerTurnID: OrchestrationValue<String>,
        launcher: OrchestrationValue<ProcessNodeObservation>,
        descendants: [ProcessNodeObservation],
        coverage: ProcessTreeObservationCoverage,
        observation: SupervisionObservationStamp,
        diagnostics: OrchestrationValue<[String]> = .known([])
    ) {
        self.schemaVersion = schemaVersion
        self.taskSessionID = taskSessionID
        self.runtimeAttemptID = runtimeAttemptID
        self.providerTurnID = providerTurnID
        self.launcher = launcher
        self.descendants = descendants
        self.coverage = coverage
        self.observation = observation
        self.diagnostics = diagnostics
    }

    public static func unavailable(
        taskSessionID: String,
        runtimeAttemptID: OrchestrationValue<String>,
        providerTurnID: OrchestrationValue<String>,
        reason: String,
        observedAt: Date = Date()
    ) -> Self {
        Self(
            taskSessionID: taskSessionID,
            runtimeAttemptID: runtimeAttemptID,
            providerTurnID: providerTurnID,
            launcher: .unknown,
            descendants: [],
            coverage: .unavailable,
            observation: SupervisionObservationStamp(
                authority: .processObserved,
                freshness: .unknown,
                observedAt: .known(observedAt)
            ),
            diagnostics: .known([reason])
        )
    }
}

/// Explicitly records that Slice 6A did not perform destructive residual
/// cleanup. Keeping this receipt in the read model prevents a future caller
/// from treating an empty target list as proof that cleanup succeeded.
public struct ProcessTreeCleanupReceipt: Codable, Equatable, Sendable {
    public var disposition: ProcessTreeCleanupDisposition
    public var targetedPIDs: [Int32]
    public var targetingBasis: OrchestrationValue<[String]>
    /// Exact predeclared PID/start identities considered for mutation.
    /// Optional to preserve decoding compatibility with Slice 6A receipts.
    public var targets: [ProcessTreeCleanupTarget]?
    /// Per-target signal-boundary result, including identity refusal or errno.
    /// Optional to preserve decoding compatibility with Slice 6A receipts.
    public var signalResults: [ProcessTreeCleanupSignalResult]?
    public var reobservedAfterCleanup: OrchestrationValue<Bool>

    public init(
        disposition: ProcessTreeCleanupDisposition,
        targetedPIDs: [Int32],
        targetingBasis: OrchestrationValue<[String]>,
        targets: [ProcessTreeCleanupTarget]? = nil,
        signalResults: [ProcessTreeCleanupSignalResult]? = nil,
        reobservedAfterCleanup: OrchestrationValue<Bool>
    ) {
        self.disposition = disposition
        self.targetedPIDs = targetedPIDs
        self.targetingBasis = targetingBasis
        self.targets = targets
        self.signalResults = signalResults
        self.reobservedAfterCleanup = reobservedAfterCleanup
    }

    public static func deferred(reason: String) -> Self {
        Self(
            disposition: .notAttempted,
            targetedPIDs: [],
            targetingBasis: .known([reason]),
            reobservedAfterCleanup: .known(false)
        )
    }
}

/// Reconciliation of a lifecycle action against an explicit before/after
/// process observation. A parent exit is only one input; it is never enough by
/// itself to produce the `complete` postcondition.
public struct ProcessTreeReconciliation: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 3

    public var schemaVersion: Int
    public var taskSessionID: String
    public var runtimeAttemptID: OrchestrationValue<String>
    public var providerTurnID: OrchestrationValue<String>
    public var requestedOperation: OrchestrationValue<LifecycleOperation>
    public var before: ProcessTreeObservation?
    public var after: ProcessTreeObservation
    public var disposition: ProcessTreeReconciliationDisposition
    public var postcondition: ProcessTreePostcondition
    public var observedExits: [ProcessNodeObservation]
    public var residualDescendants: [ProcessNodeObservation]
    public var ownedResidualDescendants: [ProcessNodeObservation]
    public var unknownOwnershipResidualDescendants: [ProcessNodeObservation]
    public var cleanup: ProcessTreeCleanupReceipt
    public var observation: SupervisionObservationStamp

    public init(
        schemaVersion: Int = ProcessTreeReconciliation.currentSchemaVersion,
        taskSessionID: String,
        runtimeAttemptID: OrchestrationValue<String>,
        providerTurnID: OrchestrationValue<String>,
        requestedOperation: OrchestrationValue<LifecycleOperation>,
        before: ProcessTreeObservation?,
        after: ProcessTreeObservation,
        disposition: ProcessTreeReconciliationDisposition,
        postcondition: ProcessTreePostcondition,
        observedExits: [ProcessNodeObservation],
        residualDescendants: [ProcessNodeObservation],
        ownedResidualDescendants: [ProcessNodeObservation],
        unknownOwnershipResidualDescendants: [ProcessNodeObservation],
        cleanup: ProcessTreeCleanupReceipt,
        observation: SupervisionObservationStamp
    ) {
        self.schemaVersion = schemaVersion
        self.taskSessionID = taskSessionID
        self.runtimeAttemptID = runtimeAttemptID
        self.providerTurnID = providerTurnID
        self.requestedOperation = requestedOperation
        self.before = before
        self.after = after
        self.disposition = disposition
        self.postcondition = postcondition
        self.observedExits = observedExits
        self.residualDescendants = residualDescendants
        self.ownedResidualDescendants = ownedResidualDescendants
        self.unknownOwnershipResidualDescendants = unknownOwnershipResidualDescendants
        self.cleanup = cleanup
        self.observation = observation
    }
}

public enum ProcessTreeReconciler {
    public static func reconcile(
        before: ProcessTreeObservation?,
        after: ProcessTreeObservation,
        requestedOperation: OrchestrationValue<LifecycleOperation> = .unknown
    ) -> ProcessTreeReconciliation {
        var normalizedAfter = after
        if let before, !ProcessTreeCleanupBinding.matches(before: before, after: after) {
            normalizedAfter.coverage = .ambiguous
            normalizedAfter.diagnostics = .known((after.diagnostics.value ?? []) + [
                "prior snapshot task/runtime/launcher scope is absent or different; ownership cannot be borrowed"
            ])
        } else {
            normalizedAfter = preservingEstablishedOwnership(after: after, before: before)
        }
        let liveResiduals = normalizedAfter.descendants.filter {
            $0.liveness == .live
        }
        let ownedResiduals = liveResiduals.filter {
            $0.ownership == .taskCreated
        }
        let unknownResiduals = liveResiduals.filter {
            $0.ownership == .unknown
        }
        var observedExits = normalizedAfter.descendants.filter {
            $0.liveness == .exited
        }
        if let launcher = normalizedAfter.launcher.value,
           launcher.liveness == .exited
        {
            observedExits.append(launcher)
        }

        let base = ProcessTreeReconciliationBase(
            taskSessionID: normalizedAfter.taskSessionID,
            runtimeAttemptID: normalizedAfter.runtimeAttemptID,
            providerTurnID: normalizedAfter.providerTurnID,
            requestedOperation: requestedOperation,
            before: before,
            after: normalizedAfter,
            observedExits: observedExits,
            residualDescendants: liveResiduals,
            ownedResidualDescendants: ownedResiduals,
            unknownOwnershipResidualDescendants: unknownResiduals
        )

        guard normalizedAfter.coverage != .unavailable else {
            return make(base, disposition: .observationUnavailable, postcondition: .unavailable)
        }
        guard normalizedAfter.coverage != .ambiguous else {
            return make(base, disposition: .observationAmbiguous, postcondition: .incompleteUnknown)
        }
        guard let launcher = normalizedAfter.launcher.value else {
            return make(base, disposition: .observationUnavailable, postcondition: .unavailable)
        }

        switch launcher.liveness {
        case .live:
            return make(base, disposition: .parentStillLive, postcondition: .pending)
        case .unknown:
            return make(base, disposition: .observationAmbiguous, postcondition: .incompleteUnknown)
        case .exited:
            if !unknownResiduals.isEmpty, !ownedResiduals.isEmpty {
                return make(
                    base,
                    disposition: .parentExitedOwnedAndUnknownResidual,
                    postcondition: .incompleteUnknown
                )
            }
            if !unknownResiduals.isEmpty {
                return make(
                    base,
                    disposition: .parentExitedResidualOwnershipUnknown,
                    postcondition: .incompleteUnknown
                )
            }
            if !ownedResiduals.isEmpty {
                return make(
                    base,
                    disposition: .parentExitedOwnedResidual,
                    postcondition: .incompleteResidual
                )
            }
            guard before != nil else {
                return make(
                    base,
                    disposition: .observationUnavailable,
                    postcondition: .incompleteUnknown
                )
            }
            guard normalizedAfter.coverage == .complete else {
                return make(
                    base,
                    disposition: .observationPartial,
                    postcondition: .incompleteUnknown
                )
            }
            return make(
                base,
                disposition: .parentExitedNoOwnedResidual,
                postcondition: .complete
            )
        }
    }

    private struct ProcessTreeReconciliationBase {
        let taskSessionID: String
        let runtimeAttemptID: OrchestrationValue<String>
        let providerTurnID: OrchestrationValue<String>
        let requestedOperation: OrchestrationValue<LifecycleOperation>
        let before: ProcessTreeObservation?
        let after: ProcessTreeObservation
        let observedExits: [ProcessNodeObservation]
        let residualDescendants: [ProcessNodeObservation]
        let ownedResidualDescendants: [ProcessNodeObservation]
        let unknownOwnershipResidualDescendants: [ProcessNodeObservation]
    }

    private static func make(
        _ base: ProcessTreeReconciliationBase,
        disposition: ProcessTreeReconciliationDisposition,
        postcondition: ProcessTreePostcondition
    ) -> ProcessTreeReconciliation {
        ProcessTreeReconciliation(
            taskSessionID: base.taskSessionID,
            runtimeAttemptID: base.runtimeAttemptID,
            providerTurnID: base.providerTurnID,
            requestedOperation: base.requestedOperation,
            before: base.before,
            after: base.after,
            disposition: disposition,
            postcondition: postcondition,
            observedExits: base.observedExits,
            residualDescendants: base.residualDescendants,
            ownedResidualDescendants: base.ownedResidualDescendants,
            unknownOwnershipResidualDescendants: base.unknownOwnershipResidualDescendants,
            cleanup: .deferred(
                reason: "Slice 6A records residuals but does not perform destructive descendant cleanup"
            ),
            observation: base.after.observation
        )
    }

    private static func preservingEstablishedOwnership(
        after: ProcessTreeObservation,
        before: ProcessTreeObservation?
    ) -> ProcessTreeObservation {
        guard let before else { return after }
        var normalized = after
        normalized.descendants = after.descendants.map { current in
            guard current.ownership == .unknown,
                  let previous = matchingNode(
                      current,
                      in: before.descendants
                  ),
                  previous.ownership == .taskCreated,
                  sameProcessIdentity(current, previous)
            else {
                return current
            }
            var retained = current
            retained.ownership = .taskCreated
            retained.ownershipBasis = .preservedFromPriorIdentity
            return retained
        }
        return normalized
    }

    private static func matchingNode(
        _ node: ProcessNodeObservation,
        in candidates: [ProcessNodeObservation]
    ) -> ProcessNodeObservation? {
        candidates.first { sameProcessIdentity(node, $0) }
    }

    /// PID reuse is considered a non-match when either side lacks the
    /// start-time identity. A PID-only match would make reparented or reused
    /// processes eligible for false ownership preservation.
    private static func sameProcessIdentity(
        _ lhs: ProcessNodeObservation,
        _ rhs: ProcessNodeObservation
    ) -> Bool {
        guard lhs.pid == rhs.pid,
              let lhsIdentity = lhs.startIdentity.value,
              let rhsIdentity = rhs.startIdentity.value,
              lhsIdentity == rhsIdentity
        else {
            return false
        }
        return true
    }
}
