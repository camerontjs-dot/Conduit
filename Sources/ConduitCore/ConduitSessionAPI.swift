import Foundation

/// Capability-scoped verbs for external orchestrator clients (D-039).
///
/// ChatGPT Developer Mode and the later phone bridge share this contract.
/// Conduit itself stays deterministic; every write is one explicit call.
public enum ConduitSessionOrigin: String, Codable, Equatable, Sendable {
    case composer
    case chatgpt
    case phone

    public var promptOrigin: PromptOrigin {
        switch self {
        case .composer: return .composer
        case .chatgpt: return .chatgpt
        case .phone: return .phone
        }
    }
}

public struct ConduitSessionSnapshot: Equatable, Sendable {
    public var taskSessionID: String
    public var agentName: String
    public var projectSlug: String
    public var backend: AgentSessionBackend
    public var lifecycle: String
    public var originLastPrompt: ConduitSessionOrigin?

    public init(
        taskSessionID: String,
        agentName: String,
        projectSlug: String,
        backend: AgentSessionBackend,
        lifecycle: String,
        originLastPrompt: ConduitSessionOrigin? = nil
    ) {
        self.taskSessionID = taskSessionID
        self.agentName = agentName
        self.projectSlug = projectSlug
        self.backend = backend
        self.lifecycle = lifecycle
        self.originLastPrompt = originLastPrompt
    }
}

/// Admission principal and separately observed audit metadata for a request.
///
/// The current listener authenticates one shared bearer credential. Its latest
/// valid initialize.clientInfo is an audit label, never a separately authenticated
/// caller or a fresh rate bucket. This does not provide per-client isolation.
public struct ConduitSessionCaller: Equatable, Sendable {
    public let identity: String?
    public let observedAt: Date?
    public let clientInfo: String?

    public init(identity: String?, observedAt: Date?, clientInfo: String? = nil) {
        self.identity = identity
        self.observedAt = observedAt
        self.clientInfo = clientInfo
    }

    /// Use only after the existing exact bearer authentication succeeds.
    /// A missing audit label preserves the listener's fail-closed initialize
    /// prerequisite; supplying a label does not authenticate a new principal.
    public static func authenticatedBySharedBearer(
        clientInfo: String?,
        observedAt: Date?
    ) -> ConduitSessionCaller {
        guard let label = clientInfo?.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty
        else { return .unidentified }
        return ConduitSessionCaller(
            identity: "session-api-shared-bearer-v1",
            observedAt: observedAt,
            clientInfo: label
        )
    }

    public static let unidentified = ConduitSessionCaller(
        identity: nil,
        observedAt: nil
    )
}

public enum ConduitSessionCommand: Equatable, Sendable {
    case listProjects
    case listSessions(cursor: String?, limit: Int?)
    case listAdapters
    case listProviderSessions(provider: String)
    case fleetSnapshot(
        taskCursor: String?,
        providerCursor: String?,
        limit: Int?
    )
    case observeWorker(provider: String, providerSessionID: String)
    case adoptProviderSession(
        provider: String,
        providerSessionID: String,
        controllerID: String
    )
    case sessionStatus(taskSessionID: String)
    case processTree(taskSessionID: String)
    case sessionEvents(taskSessionID: String, cursor: String?, limit: Int?)
    case queryMindGraph(question: String, scope: String)
    case createTask(
        agent: String,
        projectSlug: String,
        objective: String,
        idempotencyKey: String?
    )
    case reconcileTask(taskSessionID: String)
    case sendPrompt(taskSessionID: String, text: String, origin: ConduitSessionOrigin)
    case lifecyclePreflight(
        taskSessionID: String,
        operation: LifecycleOperation
    )
    case lifecycleOperation(
        taskSessionID: String,
        operation: LifecycleOperation
    )
    case interrupt(taskSessionID: String)
    case closeSession(taskSessionID: String)
}

public enum ConduitSessionAPIReadiness: String, Codable, CaseIterable, Equatable, Sendable {
    case bootstrapping
    case mainframeNotConfigured = "mainframe_not_configured"
    case mainframeAuthorizationRequired = "mainframe_authorization_required"
    case mainframeScanFailed = "mainframe_scan_failed"
    case ready

    public var isReady: Bool { self == .ready }

    public var httpStatusCode: Int {
        isReady ? 200 : 503
    }
}

public enum ConduitSessionAPI {
    /// Loopback-only MCP listen address. Do not share with MindGraph :8000.
    public static let loopbackPort = 8750
    public static let loopbackPath = "/mcp"

    public static func isWrite(_ command: ConduitSessionCommand) -> Bool {
        switch command {
        case .listProjects, .listSessions, .listAdapters, .listProviderSessions,
             .fleetSnapshot, .observeWorker, .sessionStatus, .processTree, .sessionEvents, .queryMindGraph,
             .lifecyclePreflight:
            return false
        case .adoptProviderSession, .createTask, .reconcileTask, .sendPrompt,
             .lifecycleOperation, .interrupt, .closeSession:
            return true
        }
    }

    /// Only the listener's initialization prerequisite. Bearer authentication,
    /// the local write gate, admission budgets and target authority are separate.
    public static func callerContextAllows(
        _ command: ConduitSessionCommand,
        caller: ConduitSessionCaller
    ) -> Bool {
        !isWrite(command)
            || caller.identity?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    public static func allowsCommand(
        _ command: ConduitSessionCommand,
        readiness: ConduitSessionAPIReadiness
    ) -> Bool {
        !isWrite(command) || readiness.isReady
    }

    public static func allowsMindGraphScope(_ scope: String) -> Bool {
        scope == "knowledge" || scope == "projects"
    }

    public static func matchesAgent(_ profile: AgentProfile, name: String) -> Bool {
        let needle = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return false }
        if profile.name.lowercased() == needle { return true }
        return URL(fileURLWithPath: profile.command).lastPathComponent.lowercased() == needle
    }

    /// Whether an explicit reconcile call has a deterministic path that may
    /// complete after the synchronous MCP response. A compatible discovered
    /// runtime is safe positive evidence for every unfinished operational
    /// state; otherwise only the provisioning retry states have enough target
    /// information to accept the request.
    public static func reconciliationRequestMayProceed(
        operationalState: TaskSessionOperationalState?,
        hasCompatibleDiscoveredRuntime: Bool
    ) -> Bool {
        if hasCompatibleDiscoveredRuntime { return true }
        switch operationalState {
        case .runtimeProvisioning?, .runtimeProvisioningFailed?:
            return true
        default:
            return false
        }
    }
}
