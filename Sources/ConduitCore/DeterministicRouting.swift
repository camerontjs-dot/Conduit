import Foundation

public enum RoutingTaskClass: String, Codable, CaseIterable, Sendable {
    case implementation
    case research
    case qualification
    case review
    case supervision
    case maintenance
}

public enum RoutingRole: String, Codable, CaseIterable, Sendable {
    case implementer
    case researcher
    case qualifier
    case reviewer
    case supervisor
}

public enum RoutingExecutionSurface: String, Codable, CaseIterable, Sendable {
    case regularChatGitHub = "regular_chat_github"
    case chatGPTWork = "chatgpt_work"
    case localAgent = "local_agent"
    case providerAPI = "provider_api"
    case shell
}

public enum RoutingRuntimeCapability: String, Codable, CaseIterable, Sendable {
    case sourceInspection = "source_inspection"
    case gitHubMutation = "github_mutation"
    case localFilesystem = "local_filesystem"
    case localShell = "local_shell"
    case installedMacOSApp = "installed_macos_app"
    case providerControl = "provider_control"
    case browser = "browser"
    case independentQualification = "independent_qualification"
}

public enum RoutingLocalityRequirement: String, Codable, Sendable {
    case any
    case localRequired = "local_required"
    case regularChatGitHubRequired = "regular_chat_github_required"
}

public enum RoutingLocality: String, Codable, Sendable {
    case externalChat = "external_chat"
    case localMachine = "local_machine"
    case hosted
    case unknown
}

public enum RoutingWorkspaceRequirement: String, Codable, Sendable {
    case none
    case sharedReadOnly = "shared_read_only"
    case isolatedWritable = "isolated_writable"
    case explicitExisting = "explicit_existing"
}

public enum RoutingWorkspaceStateKind: String, Codable, Sendable {
    case notRequired = "not_required"
    case ready
    case writerCollision = "writer_collision"
    case missing
    case unknown
}

public struct RoutingWorkspaceState: Codable, Equatable, Sendable {
    public var kind: RoutingWorkspaceStateKind
    public var workspaceID: OrchestrationValue<String>

    public init(
        kind: RoutingWorkspaceStateKind,
        workspaceID: OrchestrationValue<String> = .unknown
    ) {
        self.kind = kind
        self.workspaceID = workspaceID
    }

    public static var notRequired: Self { .init(kind: .notRequired) }
    public static func ready(_ id: String) -> Self {
        .init(kind: .ready, workspaceID: .known(id))
    }
    public static var writerCollision: Self { .init(kind: .writerCollision) }
    public static var missing: Self { .init(kind: .missing) }
    public static var unknown: Self { .init(kind: .unknown) }
}

public enum AllowanceUnit: String, Codable, Sendable {
    case tokens
    case turns
    case providerQuota = "provider_quota"
    case localCompute = "local_compute"
    case unknown
}

public struct RoutingEvidenceReference: Codable, Equatable, Sendable {
    public var reference: String
    public var observedAt: OrchestrationValue<Date>
    public var sampleSize: OrchestrationValue<Int>
    public var notes: String?

    public init(
        reference: String,
        observedAt: OrchestrationValue<Date> = .unknown,
        sampleSize: OrchestrationValue<Int> = .unknown,
        notes: String? = nil
    ) {
        self.reference = reference
        self.observedAt = observedAt
        self.sampleSize = sampleSize
        self.notes = notes
    }
}

public struct AllowancePoolMetadata: Codable, Equatable, Sendable {
    public var poolID: String
    public var unit: AllowanceUnit
    public var remaining: OrchestrationValue<Double>
    public var limit: OrchestrationValue<Double>
    public var observedAt: OrchestrationValue<Date>

    public init(
        poolID: String,
        unit: AllowanceUnit,
        remaining: OrchestrationValue<Double> = .unknown,
        limit: OrchestrationValue<Double> = .unknown,
        observedAt: OrchestrationValue<Date> = .unknown
    ) {
        self.poolID = poolID
        self.unit = unit
        self.remaining = remaining
        self.limit = limit
        self.observedAt = observedAt
    }
}

public struct ModelCapabilityProfileReference: Codable, Equatable, Sendable {
    public var profileID: String
    public var version: String
    public var evidence: [RoutingEvidenceReference]

    public init(
        profileID: String,
        version: String,
        evidence: [RoutingEvidenceReference] = []
    ) {
        self.profileID = profileID
        self.version = version
        self.evidence = evidence
    }
}

public struct ModelExecutionConfiguration: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var profile: ModelCapabilityProfileReference
    public var providerID: String
    public var modelID: String
    public var effortSetting: String?
    public var observedEffortSetting: OrchestrationValue<String>
    public var applicableRoles: Set<RoutingRole>
    public var applicableTaskClasses: Set<RoutingTaskClass>
    public var capabilities: Set<RoutingRuntimeCapability>
    public var tools: Set<String>
    public var contextWindowTokens: OrchestrationValue<Int>
    public var allowancePoolID: OrchestrationValue<String>

    public init(
        id: String,
        profile: ModelCapabilityProfileReference,
        providerID: String,
        modelID: String,
        effortSetting: String? = nil,
        observedEffortSetting: OrchestrationValue<String> = .unknown,
        applicableRoles: Set<RoutingRole>,
        applicableTaskClasses: Set<RoutingTaskClass>,
        capabilities: Set<RoutingRuntimeCapability> = [],
        tools: Set<String> = [],
        contextWindowTokens: OrchestrationValue<Int> = .unknown,
        allowancePoolID: OrchestrationValue<String> = .unknown
    ) {
        self.id = id
        self.profile = profile
        self.providerID = providerID
        self.modelID = modelID
        self.effortSetting = effortSetting
        self.observedEffortSetting = observedEffortSetting
        self.applicableRoles = applicableRoles
        self.applicableTaskClasses = applicableTaskClasses
        self.capabilities = capabilities
        self.tools = tools
        self.contextWindowTokens = contextWindowTokens
        self.allowancePoolID = allowancePoolID
    }
}

public struct RuntimeCapabilityProfile: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var surface: RoutingExecutionSurface
    public var locality: RoutingLocality
    public var capabilities: Set<RoutingRuntimeCapability>
    public var tools: Set<String>
    public var exactThreadID: OrchestrationValue<String>
    public var canContinueExisting: Bool
    public var canCreateWorker: Bool
    public var workspace: RoutingWorkspaceState
    public var configurations: [ModelExecutionConfiguration]

    public init(
        id: String,
        surface: RoutingExecutionSurface,
        locality: RoutingLocality,
        capabilities: Set<RoutingRuntimeCapability> = [],
        tools: Set<String> = [],
        exactThreadID: OrchestrationValue<String> = .unknown,
        canContinueExisting: Bool,
        canCreateWorker: Bool,
        workspace: RoutingWorkspaceState = .notRequired,
        configurations: [ModelExecutionConfiguration]
    ) {
        self.id = id
        self.surface = surface
        self.locality = locality
        self.capabilities = capabilities
        self.tools = tools
        self.exactThreadID = exactThreadID
        self.canContinueExisting = canContinueExisting
        self.canCreateWorker = canCreateWorker
        self.workspace = workspace
        self.configurations = configurations
    }
}

public struct RoutingWorkRequirements: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var packageID: String
    public var role: RoutingRole
    public var taskClass: RoutingTaskClass
    public var requiredCapabilities: Set<RoutingRuntimeCapability>
    public var requiredTools: Set<String>
    public var allowedSurfaces: Set<RoutingExecutionSurface>
    public var prohibitedSurfaces: Set<RoutingExecutionSurface>
    public var locality: RoutingLocalityRequirement
    public var workspace: RoutingWorkspaceRequirement
    public var requiredContextTokens: OrchestrationValue<Int>
    public var requiresKnownAllowance: Bool
    public var requiresIndependentVerification: Bool

    public init(
        id: String,
        packageID: String,
        role: RoutingRole,
        taskClass: RoutingTaskClass,
        requiredCapabilities: Set<RoutingRuntimeCapability> = [],
        requiredTools: Set<String> = [],
        allowedSurfaces: Set<RoutingExecutionSurface> = Set(RoutingExecutionSurface.allCases),
        prohibitedSurfaces: Set<RoutingExecutionSurface> = [],
        locality: RoutingLocalityRequirement = .any,
        workspace: RoutingWorkspaceRequirement = .none,
        requiredContextTokens: OrchestrationValue<Int> = .unknown,
        requiresKnownAllowance: Bool = false,
        requiresIndependentVerification: Bool = false
    ) {
        self.id = id
        self.packageID = packageID
        self.role = role
        self.taskClass = taskClass
        self.requiredCapabilities = requiredCapabilities
        self.requiredTools = requiredTools
        self.allowedSurfaces = allowedSurfaces
        self.prohibitedSurfaces = prohibitedSurfaces
        self.locality = locality
        self.workspace = workspace
        self.requiredContextTokens = requiredContextTokens
        self.requiresKnownAllowance = requiresKnownAllowance
        self.requiresIndependentVerification = requiresIndependentVerification
    }
}

public struct DeterministicRoutingPolicy: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var version: String
    public var surfacePreference: [RoutingExecutionSurface]
    public var configurationPreference: [String]
    public var allowWorkerCreation: Bool

    public init(
        schemaVersion: Int = DeterministicRoutingPolicy.currentSchemaVersion,
        version: String,
        surfacePreference: [RoutingExecutionSurface] = [.regularChatGitHub, .localAgent, .providerAPI, .shell],
        configurationPreference: [String] = [],
        allowWorkerCreation: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.version = version
        self.surfacePreference = surfacePreference
        self.configurationPreference = configurationPreference
        self.allowWorkerCreation = allowWorkerCreation
    }
}

public enum RouteAction: String, Codable, Sendable {
    case externalRegularChat = "external_regular_chat"
    case continueExisting = "continue_existing"
    case createWorker = "create_worker"
    case none
}

public enum RouteBlockReason: Equatable, Sendable {
    case surfaceNotAllowed(RoutingExecutionSurface)
    case surfaceProhibited(RoutingExecutionSurface)
    case roleNotApplicable(RoutingRole)
    case taskClassNotApplicable(RoutingTaskClass)
    case missingCapabilities([RoutingRuntimeCapability])
    case missingTools([String])
    case localityMismatch
    case contextCapacityUnknown
    case contextCapacityInsufficient(required: Int, available: Int)
    case allowanceUnknown(String?)
    case workspaceCollision
    case workspaceMissing
    case workspaceUnknown
    case independenceCapabilityMissing
    case missingThread
    case creationDisabled

    public var message: String {
        switch self {
        case .surfaceNotAllowed(let surface):
            return "Surface \(surface.rawValue) is not allowed."
        case .surfaceProhibited(let surface):
            return "Surface \(surface.rawValue) is explicitly prohibited."
        case .roleNotApplicable(let role):
            return "Profile is not applicable to role \(role.rawValue)."
        case .taskClassNotApplicable(let taskClass):
            return "Profile is not applicable to task class \(taskClass.rawValue)."
        case .missingCapabilities(let values):
            return "Missing capabilities: \(values.map(\.rawValue).sorted().joined(separator: ", "))."
        case .missingTools(let values):
            return "Missing tools: \(values.sorted().joined(separator: ", "))."
        case .localityMismatch:
            return "Runtime locality does not satisfy the work requirement."
        case .contextCapacityUnknown:
            return "Required context is known but the candidate context capacity is UNKNOWN."
        case .contextCapacityInsufficient(let required, let available):
            return "Required context \(required) exceeds candidate capacity \(available)."
        case .allowanceUnknown(let pool):
            return "Allowance state is UNKNOWN\(pool.map { " for \($0)" } ?? "")."
        case .workspaceCollision:
            return "Workspace writer collision blocks this route."
        case .workspaceMissing:
            return "Required workspace is missing."
        case .workspaceUnknown:
            return "Required workspace state is UNKNOWN."
        case .independenceCapabilityMissing:
            return "Independent-verification capability is required but unavailable."
        case .missingThread:
            return "No exact eligible existing thread is known."
        case .creationDisabled:
            return "Worker creation is not authorized by this routing policy."
        }
    }
}

public struct RouteCandidate: Equatable, Sendable, Identifiable {
    public var id: String
    public var runtimeID: String
    public var surface: RoutingExecutionSurface
    public var configuration: ModelExecutionConfiguration
    public var exactThreadID: OrchestrationValue<String>
    public var workspace: RoutingWorkspaceState
    public var allowance: OrchestrationValue<AllowancePoolMetadata>
    public var action: RouteAction
    public var hardBlocks: [RouteBlockReason]

    public var isConfigurationEligible: Bool { hardBlocks.isEmpty }

    public init(
        id: String,
        runtimeID: String,
        surface: RoutingExecutionSurface,
        configuration: ModelExecutionConfiguration,
        exactThreadID: OrchestrationValue<String>,
        workspace: RoutingWorkspaceState,
        allowance: OrchestrationValue<AllowancePoolMetadata>,
        action: RouteAction,
        hardBlocks: [RouteBlockReason]
    ) {
        self.id = id
        self.runtimeID = runtimeID
        self.surface = surface
        self.configuration = configuration
        self.exactThreadID = exactThreadID
        self.workspace = workspace
        self.allowance = allowance
        self.action = action
        self.hardBlocks = hardBlocks
    }
}

public enum RouteDecisionDisposition: String, Codable, Sendable {
    case selected = "SELECTED"
    case noEligibleRoute = "NO_ELIGIBLE_ROUTE"
    case threadCreationRequired = "THREAD_CREATION_REQUIRED"
    case missingThread = "MISSING_THREAD"
    case workspaceCollision = "WORKSPACE_COLLISION"
    case policyInsufficient = "POLICY_INSUFFICIENT"
}

public struct RouteDecision: Equatable, Sendable {
    public var requirementsID: String
    public var packageID: String
    public var policyVersion: String
    public var candidates: [RouteCandidate]
    public var selectedCandidateID: String?
    public var disposition: RouteDecisionDisposition
    public var reasons: [String]

    public init(
        requirementsID: String,
        packageID: String,
        policyVersion: String,
        candidates: [RouteCandidate],
        selectedCandidateID: String?,
        disposition: RouteDecisionDisposition,
        reasons: [String]
    ) {
        self.requirementsID = requirementsID
        self.packageID = packageID
        self.policyVersion = policyVersion
        self.candidates = candidates
        self.selectedCandidateID = selectedCandidateID
        self.disposition = disposition
        self.reasons = reasons
    }
}

public enum DeterministicRouteResolver {
    public static func route(
        requirements: RoutingWorkRequirements,
        runtimes: [RuntimeCapabilityProfile],
        allowances: [AllowancePoolMetadata],
        policy: DeterministicRoutingPolicy
    ) -> RouteDecision {
        let allowanceByID = Dictionary(uniqueKeysWithValues: allowances.map { ($0.poolID, $0) })
        let candidates = runtimes.flatMap { runtime in
            runtime.configurations.map { configuration in
                candidate(
                    requirements: requirements,
                    runtime: runtime,
                    configuration: configuration,
                    allowanceByID: allowanceByID
                )
            }
        }.sorted { $0.id < $1.id }

        let eligible = candidates.filter(\.isConfigurationEligible)
        guard !eligible.isEmpty else {
            let hasWorkspaceCollision = candidates.contains {
                $0.hardBlocks.contains(.workspaceCollision)
            }
            return RouteDecision(
                requirementsID: requirements.id,
                packageID: requirements.packageID,
                policyVersion: policy.version,
                candidates: candidates,
                selectedCandidateID: nil,
                disposition: hasWorkspaceCollision ? .workspaceCollision : .noEligibleRoute,
                reasons: uniqueMessages(candidates.flatMap(\.hardBlocks))
            )
        }

        let surfaceRank = Dictionary(
            uniqueKeysWithValues: policy.surfacePreference.enumerated().map { ($0.element, $0.offset) }
        )
        let bestRank = eligible.map { surfaceRank[$0.surface] ?? Int.max }.min() ?? Int.max
        var preferred = eligible.filter { (surfaceRank[$0.surface] ?? Int.max) == bestRank }

        if preferred.count > 1, !policy.configurationPreference.isEmpty {
            let configRank = Dictionary(
                uniqueKeysWithValues: policy.configurationPreference.enumerated().map { ($0.element, $0.offset) }
            )
            let ranked = preferred.filter { configRank[$0.configuration.id] != nil }
            if let best = ranked.map({ configRank[$0.configuration.id] ?? Int.max }).min() {
                preferred = ranked.filter { configRank[$0.configuration.id] == best }
            }
        }

        guard preferred.count == 1, let selected = preferred.first else {
            return RouteDecision(
                requirementsID: requirements.id,
                packageID: requirements.packageID,
                policyVersion: policy.version,
                candidates: candidates,
                selectedCandidateID: nil,
                disposition: .policyInsufficient,
                reasons: [
                    "Multiple eligible configurations share the best explicit policy rank; no model ranking was invented."
                ]
            )
        }

        switch selected.action {
        case .externalRegularChat, .continueExisting:
            return RouteDecision(
                requirementsID: requirements.id,
                packageID: requirements.packageID,
                policyVersion: policy.version,
                candidates: candidates,
                selectedCandidateID: selected.id,
                disposition: .selected,
                reasons: []
            )
        case .createWorker:
            if policy.allowWorkerCreation {
                return RouteDecision(
                    requirementsID: requirements.id,
                    packageID: requirements.packageID,
                    policyVersion: policy.version,
                    candidates: candidates,
                    selectedCandidateID: selected.id,
                    disposition: .selected,
                    reasons: []
                )
            }
            return RouteDecision(
                requirementsID: requirements.id,
                packageID: requirements.packageID,
                policyVersion: policy.version,
                candidates: candidates,
                selectedCandidateID: selected.id,
                disposition: .threadCreationRequired,
                reasons: [RouteBlockReason.creationDisabled.message]
            )
        case .none:
            return RouteDecision(
                requirementsID: requirements.id,
                packageID: requirements.packageID,
                policyVersion: policy.version,
                candidates: candidates,
                selectedCandidateID: selected.id,
                disposition: .missingThread,
                reasons: [RouteBlockReason.missingThread.message]
            )
        }
    }

    private static func candidate(
        requirements: RoutingWorkRequirements,
        runtime: RuntimeCapabilityProfile,
        configuration: ModelExecutionConfiguration,
        allowanceByID: [String: AllowancePoolMetadata]
    ) -> RouteCandidate {
        var blocks: [RouteBlockReason] = []

        if !requirements.allowedSurfaces.contains(runtime.surface) {
            blocks.append(.surfaceNotAllowed(runtime.surface))
        }
        if requirements.prohibitedSurfaces.contains(runtime.surface) {
            blocks.append(.surfaceProhibited(runtime.surface))
        }
        if !configuration.applicableRoles.contains(requirements.role) {
            blocks.append(.roleNotApplicable(requirements.role))
        }
        if !configuration.applicableTaskClasses.contains(requirements.taskClass) {
            blocks.append(.taskClassNotApplicable(requirements.taskClass))
        }

        let capabilities = runtime.capabilities.union(configuration.capabilities)
        let missingCapabilities = requirements.requiredCapabilities.subtracting(capabilities)
        if !missingCapabilities.isEmpty {
            blocks.append(.missingCapabilities(Array(missingCapabilities)))
        }
        let tools = runtime.tools.union(configuration.tools)
        let missingTools = requirements.requiredTools.subtracting(tools)
        if !missingTools.isEmpty {
            blocks.append(.missingTools(Array(missingTools)))
        }

        switch requirements.locality {
        case .any:
            break
        case .localRequired:
            if runtime.locality != .localMachine { blocks.append(.localityMismatch) }
        case .regularChatGitHubRequired:
            if runtime.surface != .regularChatGitHub { blocks.append(.localityMismatch) }
        }

        if let required = requirements.requiredContextTokens.value {
            if let available = configuration.contextWindowTokens.value {
                if available < required {
                    blocks.append(
                        .contextCapacityInsufficient(required: required, available: available)
                    )
                }
            } else {
                blocks.append(.contextCapacityUnknown)
            }
        }

        if requirements.requiresIndependentVerification,
           !capabilities.contains(.independentQualification) {
            blocks.append(.independenceCapabilityMissing)
        }

        if requirements.workspace != .none {
            switch runtime.workspace.kind {
            case .ready:
                break
            case .writerCollision:
                blocks.append(.workspaceCollision)
            case .missing:
                blocks.append(.workspaceMissing)
            case .unknown, .notRequired:
                blocks.append(.workspaceUnknown)
            }
        }

        let allowance: OrchestrationValue<AllowancePoolMetadata>
        if let poolID = configuration.allowancePoolID.value,
           let metadata = allowanceByID[poolID] {
            allowance = .known(metadata)
            if requirements.requiresKnownAllowance,
               metadata.remaining.state == .unknown {
                blocks.append(.allowanceUnknown(poolID))
            }
        } else {
            allowance = .unknown
            if requirements.requiresKnownAllowance {
                blocks.append(.allowanceUnknown(configuration.allowancePoolID.value))
            }
        }

        let action: RouteAction
        if runtime.surface == .regularChatGitHub {
            action = .externalRegularChat
        } else if runtime.canContinueExisting, runtime.exactThreadID.value != nil {
            action = .continueExisting
        } else if runtime.canCreateWorker {
            action = .createWorker
        } else {
            action = .none
        }

        return RouteCandidate(
            id: "\(runtime.id)::\(configuration.id)",
            runtimeID: runtime.id,
            surface: runtime.surface,
            configuration: configuration,
            exactThreadID: runtime.exactThreadID,
            workspace: runtime.workspace,
            allowance: allowance,
            action: action,
            hardBlocks: blocks
        )
    }

    private static func uniqueMessages(_ reasons: [RouteBlockReason]) -> [String] {
        Array(Set(reasons.map(\.message))).sorted()
    }
}
