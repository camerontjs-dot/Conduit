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

/// Who is on the other end of a Session API request.
///
/// The current listener has one exact bearer credential. That credential is
/// the authenticated principal for admission/rate limits; MCP `clientInfo` is
/// self-declared metadata and is retained only as an audit label.
///
/// Because MCP `2024-11-05` over this listener has no per-request session id,
/// the audit label still comes from the most recent `initialize`. It MUST NOT
/// be promoted into authorization or used to create independent rate buckets.
public struct ConduitSessionCaller: Equatable, Sendable {
    /// Authenticated admission principal. Nil until the MCP initialize
    /// handshake has established a caller on this listener.
    public let identity: String?

    /// Self-declared MCP clientInfo label. Audit/diagnostic metadata only.
    public let clientInfo: String?

    public let observedAt: Date?

    public init(
        identity: String?,
        clientInfo: String? = nil,
        observedAt: Date?
    ) {
        self.identity = identity
        self.clientInfo = clientInfo
        self.observedAt = observedAt
    }

    /// Current shared-bearer principal. All clients with this credential share
    /// one admission/rate-limit identity even if they change clientInfo.
    public static let sharedBearerPrincipal = "session-api-shared-bearer-v1"

    public static func authenticatedBySharedBearer(
        clientInfo: String?,
        observedAt: Date?
    ) -> ConduitSessionCaller {
        let label = clientInfo?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let label, !label.isEmpty else { return .unidentified }
        return ConduitSessionCaller(
            identity: sharedBearerPrincipal,
            clientInfo: label,
            observedAt: observedAt
        )
    }

    public static let unidentified = ConduitSessionCaller(
        identity: nil,
        clientInfo: nil,
        observedAt: nil
    )
}

public enum ConduitSessionCommand: Equatable, Sendable {
    case listProjects
    case listSessions(cursor: String?, limit: Int?)
    case listAdapters
    case sessionStatus(taskSessionID: String)
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
    case interrupt(taskSessionID: String)
    case closeSession(taskSessionID: String)
}

public enum ConduitSessionAPI {
    /// Loopback-only MCP listen address. Do not share with MindGraph :8000.
    public static let loopbackPort = 8750
    public static let loopbackPath = "/mcp"

    public static func isWrite(_ command: ConduitSessionCommand) -> Bool {
        switch command {
        case .listProjects, .listSessions, .listAdapters, .sessionStatus, .sessionEvents, .queryMindGraph:
            return false
        case .createTask, .reconcileTask, .sendPrompt, .interrupt, .closeSession:
            return true
        }
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
