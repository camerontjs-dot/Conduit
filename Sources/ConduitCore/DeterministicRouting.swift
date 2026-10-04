import Foundation
import CryptoKit

/// Pure, caller-supplied routing facts. This module authenticates no provider,
/// grants no authority and launches nothing. A live consumer must separately
/// qualify the source, freshness, scope and entitlement of its input facts.

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

public enum RoutingCapabilitySupport: String, Codable, Sendable {
    case supported
    case unsupported
    case unknown
}

/// An explicit override of a fixture capability declaration. Evidence references
/// are preserved as input claims; carrying a reference does not qualify it.
public struct RoutingCapabilityClaim: Codable, Equatable, Sendable {
    public var capability: RoutingRuntimeCapability
    public var support: RoutingCapabilitySupport
    public var evidence: [RoutingEvidenceReference]
    public var freshness: SupervisionObservationFreshness

    public init(
        capability: RoutingRuntimeCapability,
        support: RoutingCapabilitySupport,
        evidence: [RoutingEvidenceReference] = [],
        freshness: SupervisionObservationFreshness = .unknown
    ) {
        self.capability = capability
        self.support = support
        self.evidence = evidence
        self.freshness = freshness
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
    public var capabilityClaims: [RoutingCapabilityClaim]
    public var evidence: [RoutingEvidenceReference]

    /// Missing facts remain UNKNOWN. Model metadata cannot supply this fact.
    public func support(for capability: RoutingRuntimeCapability) -> RoutingCapabilitySupport {
        if let claim = capabilityClaims.first(where: { $0.capability == capability }) {
            return claim.freshness == .stale ? .unknown : claim.support
        }
        return capabilities.contains(capability) ? .supported : .unknown
    }

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
        configurations: [ModelExecutionConfiguration],
        capabilityClaims: [RoutingCapabilityClaim] = [],
        evidence: [RoutingEvidenceReference] = []
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
        self.capabilityClaims = capabilityClaims
        self.evidence = evidence
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
        prohibitedSurfaces: Set<RoutingExecutionSurface> = [.chatGPTWork],
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
    public var prohibitedSurfaces: Set<RoutingExecutionSurface>

    public init(
        schemaVersion: Int = DeterministicRoutingPolicy.currentSchemaVersion,
        version: String,
        surfacePreference: [RoutingExecutionSurface] = [.regularChatGitHub, .localAgent, .providerAPI, .shell],
        configurationPreference: [String] = [],
        allowWorkerCreation: Bool = false,
        prohibitedSurfaces: Set<RoutingExecutionSurface> = [.chatGPTWork]
    ) {
        self.schemaVersion = schemaVersion
        self.version = version
        self.surfacePreference = surfacePreference
        self.configurationPreference = configurationPreference
        self.allowWorkerCreation = allowWorkerCreation
        self.prohibitedSurfaces = prohibitedSurfaces
    }
}

public enum RouteAction: String, Codable, Sendable {
    case externalRegularChat = "external_regular_chat"
    case continueExisting = "continue_existing"
    case createWorker = "create_worker"
    case none
}

public enum RouteBlockReason: Codable, Equatable, Sendable {
    case surfaceNotAllowed(RoutingExecutionSurface)
    case surfaceProhibited(RoutingExecutionSurface)
    case roleNotApplicable(RoutingRole)
    case taskClassNotApplicable(RoutingTaskClass)
    case missingCapabilities([RoutingRuntimeCapability])
    case unknownCapabilities([RoutingRuntimeCapability])
    case missingTools([String])
    case localityMismatch
    case contextCapacityUnknown
    case contextCapacityInsufficient(required: Int, available: Int)
    case allowanceUnknown(String?)
    case allowanceExhausted(String)
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
        case .unknownCapabilities(let values):
            return "UNKNOWN runtime capabilities: \(values.map(\.rawValue).sorted().joined(separator: ", "))."
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
        case .allowanceExhausted(let pool):
            return "Required allowance is exhausted for \(pool)."
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

public struct RouteCandidate: Codable, Equatable, Sendable, Identifiable {
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
    case invalidInput = "INVALID_INPUT"
    case noEligibleRoute = "NO_ELIGIBLE_ROUTE"
    case threadCreationRequired = "THREAD_CREATION_REQUIRED"
    case missingThread = "MISSING_THREAD"
    case workspaceCollision = "WORKSPACE_COLLISION"
    case policyInsufficient = "POLICY_INSUFFICIENT"
}

/// Complete caller-supplied inputs, kept with each decision for inspection and
/// replay. A serialized input is not authenticated runtime or account authority.
public struct RoutingDecisionInputs: Codable, Equatable, Sendable {
    public var requirements: RoutingWorkRequirements
    public var runtimes: [RuntimeCapabilityProfile]
    public var allowances: [AllowancePoolMetadata]
    public var policy: DeterministicRoutingPolicy
}

public struct RouteDecision: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var requirementsID: String
    public var packageID: String
    public var policyVersion: String
    public var inputs: RoutingDecisionInputs
    public var candidates: [RouteCandidate]
    public var selectedCandidateID: String?
    public var disposition: RouteDecisionDisposition
    public var reasons: [String]
    public var preferenceRulesApplied: [String]

    /// Stable bytes for a valid snapshot. Unencodable malformed facts throw;
    /// they are never replaced with fabricated data or a success fingerprint.
    public func receiptData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let object = try JSONSerialization.jsonObject(with: encoder.encode(self))
        return try JSONSerialization.data(withJSONObject: Self.canonicalSets(object), options: [.sortedKeys])
    }

    // Codable preserves Set meaning but does not promise its iteration order.
    // Sort only declared set fields; policy preference and evidence order remain
    // semantic inputs and must not be rewritten into an invented preference.
    private static func canonicalSets(_ value: Any, key: String? = nil) -> Any {
        if let fields = value as? [String: Any] {
            return Dictionary(uniqueKeysWithValues: fields.map { ($0.key, canonicalSets($0.value, key: $0.key)) })
        }
        if let array = value as? [Any] {
            let setFields: Set<String> = [
                "requiredCapabilities", "requiredTools", "allowedSurfaces", "prohibitedSurfaces",
                "applicableRoles", "applicableTaskClasses", "capabilities", "tools"
            ]
            if let key, setFields.contains(key), let strings = array as? [String] {
                return strings.sorted()
            }
            return array.map { canonicalSets($0) }
        }
        return value
    }

    /// Content identity only; this is neither approval nor a signature.
    public func fingerprint() throws -> String {
        SHA256.hash(data: try receiptData()).map { String(format: "%02x", $0) }.joined()
    }
}

public enum DeterministicRouteResolver {
    public static func route(
        requirements: RoutingWorkRequirements,
        runtimes: [RuntimeCapabilityProfile],
        allowances: [AllowancePoolMetadata],
        policy: DeterministicRoutingPolicy
    ) -> RouteDecision {
        let inputs = RoutingDecisionInputs(
            requirements: requirements,
            runtimes: runtimes.map {
                var runtime = $0
                runtime.configurations.sort { $0.id < $1.id }
                runtime.capabilityClaims.sort { $0.capability.rawValue < $1.capability.rawValue }
                return runtime
            }.sorted { $0.id < $1.id },
            allowances: allowances.sorted { $0.poolID < $1.poolID },
            policy: policy
        )
        func decision(
            _ disposition: RouteDecisionDisposition,
            candidates: [RouteCandidate] = [],
            selected: String? = nil,
            reasons: [String],
            rules: [String] = []
        ) -> RouteDecision {
            RouteDecision(
                schemaVersion: RouteDecision.currentSchemaVersion,
                requirementsID: requirements.id,
                packageID: requirements.packageID,
                policyVersion: policy.version,
                inputs: inputs,
                candidates: candidates,
                selectedCandidateID: selected,
                disposition: disposition,
                reasons: reasons,
                preferenceRulesApplied: rules
            )
        }

        let invalid = validationReasons(inputs)
        guard invalid.isEmpty else {
            return decision(.invalidInput, reasons: invalid)
        }

        // Identity validation precedes every dictionary construction.
        let allowanceByID = Dictionary(uniqueKeysWithValues: inputs.allowances.map { ($0.poolID, $0) })
        let candidates = inputs.runtimes.flatMap { runtime in
            runtime.configurations.map { configuration in
                candidate(
                    requirements: requirements,
                    runtime: runtime,
                    configuration: configuration,
                    allowanceByID: allowanceByID,
                    policy: policy
                )
            }
        }.sorted { $0.id < $1.id }
        let eligible = candidates.filter(\.isConfigurationEligible)
        guard !eligible.isEmpty else {
            let hasWorkspaceCollision = candidates.contains {
                $0.hardBlocks.contains(.workspaceCollision)
            }
            let reasons = candidates.isEmpty
                ? ["No runtime/model configurations were supplied."]
                : uniqueMessages(candidates.flatMap(\.hardBlocks))
            return decision(
                hasWorkspaceCollision ? .workspaceCollision : .noEligibleRoute,
                candidates: candidates,
                reasons: reasons,
                rules: ["hard_constraints"]
            )
        }

        // An exact usable continuation or external route cannot be displaced by
        // a missing thread or creation that the current policy disables.
        let usable = eligible.filter {
            $0.action == .externalRegularChat || $0.action == .continueExisting
                || ($0.action == .createWorker && policy.allowWorkerCreation)
        }
        let creatable = eligible.filter { $0.action == .createWorker }
        let pool = !usable.isEmpty ? usable : (!creatable.isEmpty ? creatable : eligible)
        let surfaceRank = Dictionary(uniqueKeysWithValues: policy.surfacePreference.enumerated().map { ($0.element, $0.offset) })
        let bestRank = pool.map { surfaceRank[$0.surface] ?? Int.max }.min() ?? Int.max
        var preferred = pool.filter { (surfaceRank[$0.surface] ?? Int.max) == bestRank }
        var rules = ["hard_constraints", "usable_route_before_missing_or_disabled_creation", "explicit_surface_preference"]
        if preferred.count > 1, !policy.configurationPreference.isEmpty {
            let configRank = Dictionary(uniqueKeysWithValues: policy.configurationPreference.enumerated().map { ($0.element, $0.offset) })
            let ranked = preferred.filter { configRank[$0.configuration.id] != nil }
            if let best = ranked.map({ configRank[$0.configuration.id] ?? Int.max }).min() {
                preferred = ranked.filter { configRank[$0.configuration.id] == best }
                rules.append("explicit_configuration_preference")
            }
        }
        guard preferred.count == 1, let selected = preferred.first else {
            return decision(
                .policyInsufficient,
                candidates: candidates,
                reasons: ["Multiple eligible configurations share the best explicit policy rank; no model ranking was invented."],
                rules: rules
            )
        }
        switch selected.action {
        case .externalRegularChat, .continueExisting:
            return decision(
                .selected,
                candidates: candidates,
                selected: selected.id,
                reasons: ["Selected \(selected.id) using the recorded hard constraints and explicit policy."],
                rules: rules
            )
        case .createWorker:
            return decision(
                policy.allowWorkerCreation ? .selected : .threadCreationRequired,
                candidates: candidates,
                selected: selected.id,
                reasons: policy.allowWorkerCreation
                    ? ["Policy permits configuration selection for worker creation; no worker was created."]
                    : [RouteBlockReason.creationDisabled.message],
                rules: rules
            )
        case .none:
            return decision(
                .missingThread,
                candidates: candidates,
                reasons: [RouteBlockReason.missingThread.message],
                rules: rules
            )
        }
    }

    private static func candidate(
        requirements: RoutingWorkRequirements,
        runtime: RuntimeCapabilityProfile,
        configuration: ModelExecutionConfiguration,
        allowanceByID: [String: AllowancePoolMetadata],
        policy: DeterministicRoutingPolicy
    ) -> RouteCandidate {
        var blocks: [RouteBlockReason] = []
        if !requirements.allowedSurfaces.contains(runtime.surface) {
            blocks.append(.surfaceNotAllowed(runtime.surface))
        }
        if requirements.prohibitedSurfaces.contains(runtime.surface)
            || policy.prohibitedSurfaces.contains(runtime.surface) {
            blocks.append(.surfaceProhibited(runtime.surface))
        }
        if !configuration.applicableRoles.contains(requirements.role) {
            blocks.append(.roleNotApplicable(requirements.role))
        }
        if !configuration.applicableTaskClasses.contains(requirements.taskClass) {
            blocks.append(.taskClassNotApplicable(requirements.taskClass))
        }
        // Runtime capability/tool authority never comes from model metadata.
        let unsupported = requirements.requiredCapabilities.filter { runtime.support(for: $0) == .unsupported }
        let unknown = requirements.requiredCapabilities.filter { runtime.support(for: $0) == .unknown }
        if !unsupported.isEmpty {
            blocks.append(.missingCapabilities(unsupported.sorted { $0.rawValue < $1.rawValue }))
        }
        if !unknown.isEmpty {
            blocks.append(.unknownCapabilities(unknown.sorted { $0.rawValue < $1.rawValue }))
        }
        let missingTools = requirements.requiredTools.subtracting(runtime.tools)
        if !missingTools.isEmpty { blocks.append(.missingTools(missingTools.sorted())) }
        switch requirements.locality {
        case .any: break
        case .localRequired:
            if runtime.locality != .localMachine { blocks.append(.localityMismatch) }
        case .regularChatGitHubRequired:
            if runtime.surface != .regularChatGitHub { blocks.append(.localityMismatch) }
        }
        if let required = requirements.requiredContextTokens.value {
            if let available = configuration.contextWindowTokens.value {
                if available < required {
                    blocks.append(.contextCapacityInsufficient(required: required, available: available))
                }
            } else { blocks.append(.contextCapacityUnknown) }
        }
        if requirements.requiresIndependentVerification,
            runtime.support(for: .independentQualification) != .supported {
            blocks.append(.independenceCapabilityMissing)
        }
        // A known writer collision is an authority blocker for reuse even when
        // the proposal did not demand a particular workspace shape.
        if runtime.workspace.kind == .writerCollision {
            blocks.append(.workspaceCollision)
        } else if requirements.workspace != .none {
            switch runtime.workspace.kind {
            case .ready:
                if runtime.workspace.workspaceID.value == nil { blocks.append(.workspaceUnknown) }
            case .writerCollision: break // handled independently above
            case .missing: blocks.append(.workspaceMissing)
            case .unknown, .notRequired: blocks.append(.workspaceUnknown)
            }
        }
        let allowance: OrchestrationValue<AllowancePoolMetadata>
        if let poolID = configuration.allowancePoolID.value, let metadata = allowanceByID[poolID] {
            allowance = .known(metadata)
            if requirements.requiresKnownAllowance {
                if metadata.remaining.state == .unknown || metadata.unit == .unknown {
                    blocks.append(.allowanceUnknown(poolID))
                } else if let remaining = metadata.remaining.value, remaining <= 0 {
                    blocks.append(.allowanceExhausted(poolID))
                }
            }
        } else {
            allowance = .unknown
            if requirements.requiresKnownAllowance {
                blocks.append(.allowanceUnknown(configuration.allowancePoolID.value))
            }
        }
        let action: RouteAction
        if runtime.surface == .regularChatGitHub { action = .externalRegularChat }
        else if runtime.canContinueExisting, runtime.exactThreadID.value != nil { action = .continueExisting }
        else if runtime.canCreateWorker { action = .createWorker }
        else { action = .none }
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

    private static func validationReasons(_ inputs: RoutingDecisionInputs) -> [String] {
        var reasons: [String] = []
        func identity(_ value: String, _ field: String, component: Bool = false) {
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || (component && value.contains("::")) {
                reasons.append("Invalid \(field) identity.")
            }
        }
        func unique(_ values: [String], _ field: String) {
            if Set(values).count != values.count { reasons.append("Duplicate \(field) identities.") }
        }
        identity(inputs.requirements.id, "requirements")
        identity(inputs.requirements.packageID, "package")
        identity(inputs.policy.version, "policy version")
        if inputs.policy.schemaVersion != DeterministicRoutingPolicy.currentSchemaVersion {
            reasons.append("Unsupported routing policy schema version \(inputs.policy.schemaVersion).")
        }
        if let required = inputs.requirements.requiredContextTokens.value, required < 0 {
            reasons.append("Required context cannot be negative.")
        }
        for tool in inputs.requirements.requiredTools { identity(tool, "required tool") }
        unique(inputs.policy.surfacePreference.map(\.rawValue), "surface preference")
        unique(inputs.policy.configurationPreference, "configuration preference")
        for id in inputs.policy.configurationPreference { identity(id, "configuration preference", component: true) }
        unique(inputs.runtimes.map(\.id), "runtime")
        unique(inputs.allowances.map(\.poolID), "allowance pool")
        for runtime in inputs.runtimes {
            identity(runtime.id, "runtime", component: true)
            if let thread = runtime.exactThreadID.value { identity(thread, "exact thread") }
            if let workspace = runtime.workspace.workspaceID.value { identity(workspace, "workspace") }
            unique(runtime.configurations.map(\.id), "configuration in \(runtime.id)")
            unique(runtime.capabilityClaims.map { $0.capability.rawValue }, "capability claim in \(runtime.id)")
            for tool in runtime.tools { identity(tool, "runtime tool") }
            for configuration in runtime.configurations {
                identity(configuration.id, "configuration", component: true)
                identity(configuration.profile.profileID, "model profile")
                identity(configuration.profile.version, "model profile version")
                identity(configuration.providerID, "provider")
                identity(configuration.modelID, "model")
                if let pool = configuration.allowancePoolID.value { identity(pool, "allowance pool") }
                if let effort = configuration.effortSetting { identity(effort, "effort setting") }
                if let effort = configuration.observedEffortSetting.value { identity(effort, "observed effort") }
                if let context = configuration.contextWindowTokens.value, context < 0 {
                    reasons.append("Model context capacity cannot be negative.")
                }
            }
        }
        for allowance in inputs.allowances {
            identity(allowance.poolID, "allowance pool")
            for value in [allowance.remaining.value, allowance.limit.value].compactMap({ $0 }) {
                if !value.isFinite || value < 0 { reasons.append("Allowance values must be finite and nonnegative.") }
            }
            if let remaining = allowance.remaining.value, let limit = allowance.limit.value, remaining > limit {
                reasons.append("Allowance remaining exceeds its recorded limit.")
            }
        }
        return Array(Set(reasons)).sorted()
    }

    private static func uniqueMessages(_ reasons: [RouteBlockReason]) -> [String] {
        Array(Set(reasons.map(\.message))).sorted()
    }
}
