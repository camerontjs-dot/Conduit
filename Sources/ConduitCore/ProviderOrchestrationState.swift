import Foundation

/// An explicitly known or unknown value.
///
/// Orchestration state crosses several authorities: Conduit records, provider
/// APIs, OS process observation, shell telemetry, and raw terminal output. A
/// missing value must therefore remain UNKNOWN rather than silently inheriting
/// a default from another layer.
public struct OrchestrationValue<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public enum State: String, Codable, Equatable, Sendable {
        case known
        case unknown
    }

    public let state: State
    public let value: Value?

    private init(state: State, value: Value?) {
        self.state = state
        self.value = value
    }

    public static func known(_ value: Value) -> Self {
        Self(state: .known, value: value)
    }

    public static var unknown: Self {
        Self(state: .unknown, value: nil)
    }

    public var isKnown: Bool { state == .known }

    private enum CodingKeys: String, CodingKey {
        case state
        case value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let state = try container.decode(State.self, forKey: .state)
        switch state {
        case .known:
            self = .known(try container.decode(Value.self, forKey: .value))
        case .unknown:
            if try container.decodeIfPresent(Value.self, forKey: .value) != nil {
                throw DecodingError.dataCorruptedError(
                    forKey: .value,
                    in: container,
                    debugDescription: "UNKNOWN orchestration fields cannot carry a value."
                )
            }
            self = .unknown
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(state, forKey: .state)
        if case .known = state, let value {
            try container.encode(value, forKey: .value)
        }
    }
}

public enum SupervisionObservationAuthority: String, Codable, Equatable, Sendable {
    case conduitRecorded = "conduit_recorded"
    case providerObserved = "provider_observed"
    case processObserved = "process_observed"
    case shellHookObserved = "shell_hook_observed"
    case repositoryObserved = "repository_observed"
    case derivedFromRaw = "derived_from_raw"
    case unknown
}

public enum SupervisionObservationFreshness: String, Codable, Equatable, Sendable {
    case current
    case stale
    case unknown
}

public struct SupervisionObservationStamp: Codable, Equatable, Sendable {
    public var authority: SupervisionObservationAuthority
    public var freshness: SupervisionObservationFreshness
    public var observedAt: OrchestrationValue<Date>

    public init(
        authority: SupervisionObservationAuthority,
        freshness: SupervisionObservationFreshness,
        observedAt: OrchestrationValue<Date>
    ) {
        self.authority = authority
        self.freshness = freshness
        self.observedAt = observedAt
    }
}

public enum WorkerOrigin: String, Codable, Equatable, Sendable {
    case conduit
    case shell
    case externalProviderClient = "external_provider_client"
    case unknown
}

public enum WorkerRelationship: String, Codable, Equatable, Sendable {
    case owned
    case adopted
    case discovered
    case historical
}

public struct ProviderModelIdentity: Codable, Equatable, Sendable {
    public var providerID: String
    public var modelID: String

    public init(providerID: String, modelID: String) {
        self.providerID = providerID
        self.modelID = modelID
    }
}

/// Provider-owned state that does not belong in the canonical shared fields.
///
/// The namespace identifies the provider/adapter contract. The payload retains
/// JSON value kinds and nesting so a provider-specific status, numeric counter,
/// list, or object is not flattened into string metadata merely to fit the
/// shared WorkerLineage envelope.
public indirect enum ProviderPayloadValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ProviderPayloadValue])
    case object([String: ProviderPayloadValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ProviderPayloadValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: ProviderPayloadValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported provider payload JSON value."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

public struct ProviderSpecificPayload: Codable, Equatable, Sendable {
    public var namespace: String
    public var schemaVersion: Int
    public var value: ProviderPayloadValue

    public init(
        namespace: String,
        schemaVersion: Int = 1,
        value: ProviderPayloadValue
    ) {
        self.namespace = namespace
        self.schemaVersion = schemaVersion
        self.value = value
    }
}

public enum DeliveryTransport: String, Codable, Equatable, Sendable {
    case shellStdin = "shell_stdin"
    case agentPrompt = "agent_prompt"
    case structuredMessage = "structured_message"
}

public enum ProviderTurnState: String, Codable, Equatable, Sendable {
    case queued
    case accepted
    case active
    case awaitingInput = "awaiting_input"
    case completed
    case cancelled
    case failed
    case ambiguous
}

/// Delivery evidence for one submitted input.
///
/// transport names the actual surface. A free-form PTY write is therefore
/// representable as shell_stdin without upgrading it into an agent prompt.
public struct PromptDeliveryRecord: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var eventID: OrchestrationValue<String>
    public var transport: DeliveryTransport
    public var state: ProviderTurnState
    public var contentDigest: OrchestrationValue<String>
    public var queuedBehindActiveTurn: OrchestrationValue<Bool>
    public var providerTurnID: OrchestrationValue<String>

    public init(
        schemaVersion: Int = PromptDeliveryRecord.currentSchemaVersion,
        eventID: OrchestrationValue<String>,
        transport: DeliveryTransport,
        state: ProviderTurnState,
        contentDigest: OrchestrationValue<String>,
        queuedBehindActiveTurn: OrchestrationValue<Bool>,
        providerTurnID: OrchestrationValue<String>
    ) {
        self.schemaVersion = schemaVersion
        self.eventID = eventID
        self.transport = transport
        self.state = state
        self.contentDigest = contentDigest
        self.queuedBehindActiveTurn = queuedBehindActiveTurn
        self.providerTurnID = providerTurnID
    }
}

public struct ProviderTurnLineage: Codable, Equatable, Sendable {
    public var turnID: OrchestrationValue<String>
    public var state: ProviderTurnState
    public var model: OrchestrationValue<ProviderModelIdentity>
    public var delivery: PromptDeliveryRecord?
    public var observation: SupervisionObservationStamp

    public init(
        turnID: OrchestrationValue<String>,
        state: ProviderTurnState,
        model: OrchestrationValue<ProviderModelIdentity>,
        delivery: PromptDeliveryRecord? = nil,
        observation: SupervisionObservationStamp
    ) {
        self.turnID = turnID
        self.state = state
        self.model = model
        self.delivery = delivery
        self.observation = observation
    }
}

public struct WorkerWorkspaceLineage: Codable, Equatable, Sendable {
    public var projectSlug: OrchestrationValue<String>
    public var cwd: OrchestrationValue<String>
    public var repositoryRoot: OrchestrationValue<String>
    public var worktree: OrchestrationValue<String>

    public init(
        projectSlug: OrchestrationValue<String>,
        cwd: OrchestrationValue<String>,
        repositoryRoot: OrchestrationValue<String>,
        worktree: OrchestrationValue<String>
    ) {
        self.projectSlug = projectSlug
        self.cwd = cwd
        self.repositoryRoot = repositoryRoot
        self.worktree = worktree
    }
}

public struct WorkerProcessLineage: Codable, Equatable, Sendable {
    public var launcherPID: OrchestrationValue<Int32>
    public var processGroupID: OrchestrationValue<Int32>
    public var parentPID: OrchestrationValue<Int32>

    public init(
        launcherPID: OrchestrationValue<Int32>,
        processGroupID: OrchestrationValue<Int32>,
        parentPID: OrchestrationValue<Int32>
    ) {
        self.launcherPID = launcherPID
        self.processGroupID = processGroupID
        self.parentPID = parentPID
    }
}

public enum TerminalReceiptState: String, Codable, Equatable, Sendable {
    case unknown
    case missing
    case present
}

public enum VerificationState: String, Codable, Equatable, Sendable {
    case unknown
    case notPerformed = "not_performed"
    case passed
    case failed
}

public enum ObjectiveAcceptanceState: String, Codable, Equatable, Sendable {
    case unknown
    case pending
    case accepted
    case rejected
}

public struct WorkerTerminalState: Codable, Equatable, Sendable {
    public var receipt: TerminalReceiptState
    public var verification: VerificationState
    public var objectiveAcceptance: ObjectiveAcceptanceState

    public init(
        receipt: TerminalReceiptState,
        verification: VerificationState,
        objectiveAcceptance: ObjectiveAcceptanceState
    ) {
        self.receipt = receipt
        self.verification = verification
        self.objectiveAcceptance = objectiveAcceptance
    }
}

/// Normalized interpretation of the newest provider-persisted turn/activity.
/// It does not claim that the runtime is currently executing.
public enum ProviderReportedRuntimeState: String, Codable, Equatable, Sendable {
    case active
    case inactive
    case unknown
}

/// Allowlisted provider persistence for one OpenCode tool part. Input, output,
/// command text, and other potentially sensitive payloads are deliberately
/// excluded. `messageID` is the provider turn identity when available and
/// `callID` identifies the tool invocation when OpenCode persists it.
public struct ProviderPersistedActivity: Codable, Equatable, Sendable {
    public var partID: OrchestrationValue<String>
    public var messageID: OrchestrationValue<String>
    public var callID: OrchestrationValue<String>
    public var kind: OrchestrationValue<String>
    public var toolName: OrchestrationValue<String>
    public var reportedStatus: OrchestrationValue<String>
    public var createdAt: OrchestrationValue<Date>
    public var updatedAt: OrchestrationValue<Date>

    public init(
        partID: OrchestrationValue<String>,
        messageID: OrchestrationValue<String>,
        callID: OrchestrationValue<String>,
        kind: OrchestrationValue<String>,
        toolName: OrchestrationValue<String>,
        reportedStatus: OrchestrationValue<String>,
        createdAt: OrchestrationValue<Date>,
        updatedAt: OrchestrationValue<Date>
    ) {
        self.partID = partID
        self.messageID = messageID
        self.callID = callID
        self.kind = kind
        self.toolName = toolName
        self.reportedStatus = reportedStatus
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum ProviderRuntimeReconciliationDisposition: String, Codable, Equatable, Sendable {
    case consistentActive = "consistent_active"
    case consistentInactive = "consistent_inactive"
    case providerStaleRunningProcessAbsent = "provider_stale_running_process_absent"
    case providerActiveParentAbsentOwnedResidual = "provider_active_parent_absent_owned_residual"
    case providerInactiveProcessResidual = "provider_inactive_process_residual"
    case inconsistentAuthorities = "inconsistent_authorities"
    case insufficientObservation = "insufficient_observation"
}

/// Keeps provider persistence and process-tree observation side by side.
/// Neither authority overwrites the other, and the disposition is a derived
/// read result rather than a provider-history or process mutation.
public struct ProviderRuntimeReconciliation: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var providerID: String
    public var providerSessionID: OrchestrationValue<String>
    public var conduitTaskID: OrchestrationValue<String>
    public var runtimeAttemptID: OrchestrationValue<String>
    public var latestProviderTurnID: OrchestrationValue<String>
    public var providerReportedState: ProviderReportedRuntimeState
    public var providerActivities: OrchestrationValue<[ProviderPersistedActivity]>
    public var providerSourceUpdatedAt: OrchestrationValue<Date>
    public var providerObservation: SupervisionObservationStamp
    public var processObservation: OrchestrationValue<ProcessTreeObservation>
    public var processReconciliation: OrchestrationValue<ProcessTreeReconciliation>
    public var disposition: ProviderRuntimeReconciliationDisposition
    public var diagnostics: [String]
    public var unknownFacts: [String]

    public init(
        schemaVersion: Int = ProviderRuntimeReconciliation.currentSchemaVersion,
        providerID: String,
        providerSessionID: OrchestrationValue<String>,
        conduitTaskID: OrchestrationValue<String>,
        runtimeAttemptID: OrchestrationValue<String>,
        latestProviderTurnID: OrchestrationValue<String>,
        providerReportedState: ProviderReportedRuntimeState,
        providerActivities: OrchestrationValue<[ProviderPersistedActivity]>,
        providerSourceUpdatedAt: OrchestrationValue<Date>,
        providerObservation: SupervisionObservationStamp,
        processObservation: OrchestrationValue<ProcessTreeObservation>,
        processReconciliation: OrchestrationValue<ProcessTreeReconciliation>,
        disposition: ProviderRuntimeReconciliationDisposition,
        diagnostics: [String],
        unknownFacts: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.providerID = providerID
        self.providerSessionID = providerSessionID
        self.conduitTaskID = conduitTaskID
        self.runtimeAttemptID = runtimeAttemptID
        self.latestProviderTurnID = latestProviderTurnID
        self.providerReportedState = providerReportedState
        self.providerActivities = providerActivities
        self.providerSourceUpdatedAt = providerSourceUpdatedAt
        self.providerObservation = providerObservation
        self.processObservation = processObservation
        self.processReconciliation = processReconciliation
        self.disposition = disposition
        self.diagnostics = diagnostics
        self.unknownFacts = unknownFacts
    }
}

/// Provider-neutral read model for one worker/session lineage.
///
/// Provider host, provider session, provider turn, and Conduit supervisory
/// binding are deliberately separate fields. Model identity lives on turns,
/// not on the provider session, because a durable provider session may change
/// model between turns.
public struct WorkerLineage: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var conduitTaskID: OrchestrationValue<String>
    public var runtimeAttemptID: OrchestrationValue<String>
    public var runtime: OrchestrationValue<String>
    public var adapter: OrchestrationValue<String>
    public var providerHostID: OrchestrationValue<String>
    public var providerSessionID: OrchestrationValue<String>
    public var turns: [ProviderTurnLineage]
    public var workspace: WorkerWorkspaceLineage
    public var process: WorkerProcessLineage
    public var origin: WorkerOrigin
    public var relationship: WorkerRelationship
    public var writerControllerID: OrchestrationValue<String>
    public var terminal: WorkerTerminalState
    public var observation: SupervisionObservationStamp
    public var providerSpecific: OrchestrationValue<ProviderSpecificPayload>
    public var runtimeReconciliation: ProviderRuntimeReconciliation?

    public init(
        schemaVersion: Int = WorkerLineage.currentSchemaVersion,
        conduitTaskID: OrchestrationValue<String>,
        runtimeAttemptID: OrchestrationValue<String>,
        runtime: OrchestrationValue<String>,
        adapter: OrchestrationValue<String>,
        providerHostID: OrchestrationValue<String>,
        providerSessionID: OrchestrationValue<String>,
        turns: [ProviderTurnLineage],
        workspace: WorkerWorkspaceLineage,
        process: WorkerProcessLineage,
        origin: WorkerOrigin,
        relationship: WorkerRelationship,
        writerControllerID: OrchestrationValue<String>,
        terminal: WorkerTerminalState,
        observation: SupervisionObservationStamp,
        providerSpecific: OrchestrationValue<ProviderSpecificPayload>,
        runtimeReconciliation: ProviderRuntimeReconciliation? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.conduitTaskID = conduitTaskID
        self.runtimeAttemptID = runtimeAttemptID
        self.runtime = runtime
        self.adapter = adapter
        self.providerHostID = providerHostID
        self.providerSessionID = providerSessionID
        self.turns = turns
        self.workspace = workspace
        self.process = process
        self.origin = origin
        self.relationship = relationship
        self.writerControllerID = writerControllerID
        self.terminal = terminal
        self.observation = observation
        self.providerSpecific = providerSpecific
        self.runtimeReconciliation = runtimeReconciliation
    }
}

public enum LifecycleOperation: String, Codable, Equatable, Sendable {
    case observe
    case adopt
    case startTurn = "start_turn"
    case abortTurn = "abort_turn"
    case releaseSupervision = "release_supervision"
    case stopProviderHost = "stop_provider_host"
    case archiveProviderHistory = "archive_provider_history"
}

public enum LifecycleTargetKind: String, Codable, Equatable, Sendable {
    case turn
    case session
    case providerHost = "provider_host"
    case processTree = "process_tree"
}

public struct LifecycleTarget: Codable, Equatable, Sendable {
    public var kind: LifecycleTargetKind
    public var identifier: OrchestrationValue<String>

    public init(kind: LifecycleTargetKind, identifier: OrchestrationValue<String>) {
        self.kind = kind
        self.identifier = identifier
    }
}

public enum LifecycleSupport: String, Codable, Equatable, Sendable {
    case supported
    case unsupported
    case unknown
}

public enum LifecycleProcessScope: String, Codable, Equatable, Sendable {
    case none
    case turn
    case session
    case providerHost = "provider_host"
    case processTree = "process_tree"
}

/// Pre-mutation declaration of the consequences Conduit currently knows.
///
/// This type is intentionally descriptive only. Live adapters and runtime
/// snapshots supply the facts; unknown and unsupported consequences stay
/// explicit instead of being mapped to a more convenient lifecycle verb.
public struct LifecyclePreflight: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 4

    public var schemaVersion: Int
    public var operation: LifecycleOperation
    public var target: LifecycleTarget
    public var support: LifecycleSupport
    public var willStopProvider: OrchestrationValue<Bool>
    public var willReleaseSlot: OrchestrationValue<Bool>
    /// Whether the targeted provider/session execution context is known to be
    /// resumable afterward through exactResumeHandle. This does not promise
    /// that the same live Conduit runtime/tab survives the operation.
    public var recoverableAfterward: OrchestrationValue<Bool>
    public var exactResumeHandle: OrchestrationValue<String>
    public var expectedProcessScope: OrchestrationValue<LifecycleProcessScope>
    public var knownDescendantPIDs: OrchestrationValue<[Int32]>
    public var cleanupEligibleDescendants: OrchestrationValue<[ProcessTreeCleanupTarget]>
    public var sideEffects: OrchestrationValue<[String]>
    public var unsupportedConsequences: OrchestrationValue<[String]>
    /// Consequences Conduit can name but cannot currently resolve.
    ///
    /// Keeping these separate from unsupported consequences prevents a missing
    /// observation from being upgraded into a negative capability claim.
    public var unknownConsequences: OrchestrationValue<[String]>
    public var observation: SupervisionObservationStamp

    public init(
        schemaVersion: Int = LifecyclePreflight.currentSchemaVersion,
        operation: LifecycleOperation,
        target: LifecycleTarget,
        support: LifecycleSupport,
        willStopProvider: OrchestrationValue<Bool>,
        willReleaseSlot: OrchestrationValue<Bool>,
        recoverableAfterward: OrchestrationValue<Bool>,
        exactResumeHandle: OrchestrationValue<String>,
        expectedProcessScope: OrchestrationValue<LifecycleProcessScope>,
        knownDescendantPIDs: OrchestrationValue<[Int32]>,
        cleanupEligibleDescendants: OrchestrationValue<[ProcessTreeCleanupTarget]> = .unknown,
        sideEffects: OrchestrationValue<[String]>,
        unsupportedConsequences: OrchestrationValue<[String]>,
        unknownConsequences: OrchestrationValue<[String]> = .unknown,
        observation: SupervisionObservationStamp
    ) {
        self.schemaVersion = schemaVersion
        self.operation = operation
        self.target = target
        self.support = support
        self.willStopProvider = willStopProvider
        self.willReleaseSlot = willReleaseSlot
        self.recoverableAfterward = recoverableAfterward
        self.exactResumeHandle = exactResumeHandle
        self.expectedProcessScope = expectedProcessScope
        self.knownDescendantPIDs = knownDescendantPIDs
        self.cleanupEligibleDescendants = cleanupEligibleDescendants
        self.sideEffects = sideEffects
        self.unsupportedConsequences = unsupportedConsequences
        self.unknownConsequences = unknownConsequences
        self.observation = observation
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case operation
        case target
        case support
        case willStopProvider
        case willReleaseSlot
        case recoverableAfterward
        case exactResumeHandle
        case expectedProcessScope
        case knownDescendantPIDs
        case cleanupEligibleDescendants
        case sideEffects
        case unsupportedConsequences
        case unknownConsequences
        case observation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        operation = try container.decode(LifecycleOperation.self, forKey: .operation)
        target = try container.decode(LifecycleTarget.self, forKey: .target)
        support = try container.decode(LifecycleSupport.self, forKey: .support)
        willStopProvider = try container.decode(
            OrchestrationValue<Bool>.self,
            forKey: .willStopProvider
        )
        willReleaseSlot = try container.decode(
            OrchestrationValue<Bool>.self,
            forKey: .willReleaseSlot
        )
        recoverableAfterward = try container.decode(
            OrchestrationValue<Bool>.self,
            forKey: .recoverableAfterward
        )
        exactResumeHandle = try container.decode(
            OrchestrationValue<String>.self,
            forKey: .exactResumeHandle
        )
        expectedProcessScope = try container.decode(
            OrchestrationValue<LifecycleProcessScope>.self,
            forKey: .expectedProcessScope
        )
        knownDescendantPIDs = try container.decode(
            OrchestrationValue<[Int32]>.self,
            forKey: .knownDescendantPIDs
        )
        cleanupEligibleDescendants = try container.decodeIfPresent(
            OrchestrationValue<[ProcessTreeCleanupTarget]>.self,
            forKey: .cleanupEligibleDescendants
        ) ?? .unknown
        sideEffects = try container.decode(
            OrchestrationValue<[String]>.self,
            forKey: .sideEffects
        )
        unsupportedConsequences = try container.decode(
            OrchestrationValue<[String]>.self,
            forKey: .unsupportedConsequences
        )
        unknownConsequences = try container.decodeIfPresent(
            OrchestrationValue<[String]>.self,
            forKey: .unknownConsequences
        ) ?? .unknown
        observation = try container.decode(
            SupervisionObservationStamp.self,
            forKey: .observation
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(operation, forKey: .operation)
        try container.encode(target, forKey: .target)
        try container.encode(support, forKey: .support)
        try container.encode(willStopProvider, forKey: .willStopProvider)
        try container.encode(willReleaseSlot, forKey: .willReleaseSlot)
        try container.encode(recoverableAfterward, forKey: .recoverableAfterward)
        try container.encode(exactResumeHandle, forKey: .exactResumeHandle)
        try container.encode(expectedProcessScope, forKey: .expectedProcessScope)
        try container.encode(knownDescendantPIDs, forKey: .knownDescendantPIDs)
        try container.encode(cleanupEligibleDescendants, forKey: .cleanupEligibleDescendants)
        try container.encode(sideEffects, forKey: .sideEffects)
        try container.encode(
            unsupportedConsequences,
            forKey: .unsupportedConsequences
        )
        try container.encode(unknownConsequences, forKey: .unknownConsequences)
        try container.encode(observation, forKey: .observation)
    }
}
