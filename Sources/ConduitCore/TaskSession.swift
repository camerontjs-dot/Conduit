import Foundation

/// Durable identity for one user-facing task history.
///
/// This is deliberately distinct from `RuntimeAttemptID`: one task can survive
/// detach/reconnect or several explicit runtime attempts without changing its
/// history identity.
public struct TaskSessionID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(UUID.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Identity for one concrete PTY/tmux attachment attempt.
public struct RuntimeAttemptID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(UUID.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct RootWorkspaceScopeSnapshot: Codable, Equatable, Hashable, Sendable {
    public let rootPath: String
    public let fallbackTitle: String
    public let fallbackSlug: String

    public init(
        rootURL: URL,
        fallbackTitle: String = "MainFrame",
        fallbackSlug: String = "mainframe"
    ) {
        self.rootPath = rootURL.standardizedFileURL.path
        self.fallbackTitle = fallbackTitle
        self.fallbackSlug = fallbackSlug
    }
}

public struct ProjectWorkspaceScopeSnapshot: Codable, Equatable, Hashable, Sendable {
    public let rootPath: String
    public let projectPath: String
    public let fallbackTitle: String
    public let fallbackSlug: String

    public init(
        rootURL: URL,
        projectURL: URL,
        fallbackTitle: String,
        fallbackSlug: String
    ) {
        self.rootPath = rootURL.standardizedFileURL.path
        self.projectPath = projectURL.standardizedFileURL.path
        self.fallbackTitle = fallbackTitle
        self.fallbackSlug = fallbackSlug
    }
}

/// Historical navigation scope only. Current project title/state must be
/// resolved from MainFrame's live file scan rather than this fallback snapshot.
public enum WorkspaceScopeSnapshot: Codable, Equatable, Hashable, Sendable {
    case root(RootWorkspaceScopeSnapshot)
    case project(ProjectWorkspaceScopeSnapshot)

    public var rootPath: String {
        switch self {
        case .root(let snapshot): return snapshot.rootPath
        case .project(let snapshot): return snapshot.rootPath
        }
    }

    public var projectPath: String? {
        switch self {
        case .root: return nil
        case .project(let snapshot): return snapshot.projectPath
        }
    }

    public var fallbackTitle: String {
        switch self {
        case .root(let snapshot): return snapshot.fallbackTitle
        case .project(let snapshot): return snapshot.fallbackTitle
        }
    }

    public var fallbackSlug: String {
        switch self {
        case .root(let snapshot): return snapshot.fallbackSlug
        case .project(let snapshot): return snapshot.fallbackSlug
        }
    }
}

/// Immutable metadata recorded when a task history is created.
///
/// No prompt, attachment, terminal byte, or agent-response content belongs in
/// this record.
public struct TaskSessionMetadata: Codable, Equatable, Sendable {
    public let workspace: WorkspaceScopeSnapshot
    /// Nil when the runtime carried no recorded agent identity. Presentation
    /// placeholders such as "Unidentified" must never be persisted here.
    public let agentName: String?
    public let defaultTitle: String

    public init(
        workspace: WorkspaceScopeSnapshot,
        agentName: String?,
        defaultTitle: String
    ) {
        self.workspace = workspace
        self.agentName = agentName
        self.defaultTitle = defaultTitle
    }
}

public enum TaskSessionEventAuthority: String, Codable, Equatable, Sendable {
    case conduitRecorded
    case processObserved
    case shellHookObserved
    case operatorAsserted
}

/// Lifecycle observation emitted by the private zsh hook attached to a
/// Conduit-owned Shell runtime. This records command boundaries and execution
/// context only; it never retains command text or terminal output.
public enum ShellTelemetryPhase: String, Codable, Equatable, Sendable {
    case executionStarted = "execution_started"
    case commandStarted = "command_started"
    case commandExited = "command_exited"
    case directoryChanged = "directory_changed"
    case shellExited = "shell_exited"
}

public struct ShellTelemetryEvent: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let shellExecutionID: String
    public let runtimeAttemptID: String
    public let phase: ShellTelemetryPhase
    public let commandID: String?
    public let commandSequence: Int?
    public let shellPID: Int32
    public let processGroupID: OrchestrationValue<Int32>
    public let workingDirectory: OrchestrationValue<String>
    public let exitStatus: OrchestrationValue<Int32>
    public let deliveryTransport: OrchestrationValue<DeliveryTransport>
    public let observation: SupervisionObservationStamp

    public init(
        schemaVersion: Int = ShellTelemetryEvent.currentSchemaVersion,
        shellExecutionID: String,
        runtimeAttemptID: String,
        phase: ShellTelemetryPhase,
        commandID: String? = nil,
        commandSequence: Int? = nil,
        shellPID: Int32,
        processGroupID: OrchestrationValue<Int32> = .unknown,
        workingDirectory: OrchestrationValue<String> = .unknown,
        exitStatus: OrchestrationValue<Int32> = .unknown,
        deliveryTransport: OrchestrationValue<DeliveryTransport> = .unknown,
        observation: SupervisionObservationStamp
    ) {
        self.schemaVersion = schemaVersion
        self.shellExecutionID = shellExecutionID
        self.runtimeAttemptID = runtimeAttemptID
        self.phase = phase
        self.commandID = commandID
        self.commandSequence = commandSequence
        self.shellPID = shellPID
        self.processGroupID = processGroupID
        self.workingDirectory = workingDirectory
        self.exitStatus = exitStatus
        self.deliveryTransport = deliveryTransport
        self.observation = observation
    }

    /// Rejects malformed hook receipts before they enter the durable task log.
    public var hasValidIdentity: Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              UUID(uuidString: shellExecutionID) != nil,
              UUID(uuidString: runtimeAttemptID) != nil,
              shellPID > 0,
              observation.authority == .shellHookObserved,
              observation.freshness == .current,
              observation.observedAt.value != nil
        else { return false }

        switch phase {
        case .commandStarted, .commandExited:
            guard let commandID,
                  let commandSequence,
                  commandSequence > 0,
                  commandID == "\(shellExecutionID):\(commandSequence)",
                  deliveryTransport.value == .shellStdin
            else { return false }
        case .executionStarted, .directoryChanged, .shellExited:
            guard commandID == nil,
                  commandSequence == nil,
                  deliveryTransport.value == nil,
                  exitStatus.value == nil
            else { return false }
        }
        if phase != .commandExited, exitStatus.value != nil { return false }
        if let path = workingDirectory.value, !path.hasPrefix("/") { return false }
        return true
    }
}

/// Operational facts only. None of these states asserts task completion,
/// correctness, success, or verification.
public enum TaskSessionOperationalState: Codable, Equatable, Sendable {
    /// A runtime attempt has been registered but the PTY/tmux or adapter host
    /// has not yet been proved usable. The target name is retained so an
    /// explicit reconciliation can retry the same safe target instead of
    /// silently allocating another task.
    case runtimeProvisioning(
        RuntimeAttemptID,
        backend: String,
        tmuxSessionName: String?
    )
    case runtimeOpened(RuntimeAttemptID)
    /// Conduit refused or failed to attach the attempted runtime. This is a
    /// task-level operational fact, not a task-content or completion claim.
    case runtimeProvisioningFailed(
        RuntimeAttemptID,
        tmuxSessionName: String?,
        reason: String,
        recoverable: Bool
    )
    case runtimeDetached(RuntimeAttemptID)
    case closed(TaskSessionCloseReason)
    case interrupted(RuntimeAttemptID?)
}

public enum TaskSessionCloseReason: String, Codable, Equatable, Sendable {
    case operatorClosed
    case operatorEndedRuntime
    case runtimeEnded
    case recoveryObserved
}

public enum TaskSessionEventKind: Codable, Equatable, Sendable {
    case created(TaskSessionMetadata)
    case titleOverridden(String)
    case titleReset
    case pinChanged(Bool)
    case archiveChanged(Bool)
    /// Content-free timestamp fact: Conduit retained prompt or visible-output
    /// activity for this task. Prompt text, output text, paths, and transcript
    /// structure remain exclusively outside the task metadata stream.
    case conversationActivityRecorded
    /// Monotonic, content-free marker that this task entered the local
    /// conversation-retention contract. It distinguishes a legacy task from a
    /// retained task whose conversation source is unexpectedly absent.
    case conversationRetentionEnabled
    case shellTelemetryRecorded(ShellTelemetryEvent)
    /// Process topology is sampled independently from shell-hook lifecycle.
    /// Keeping it in the existing task stream makes a later Fleet reader able
    /// to revalidate the same launcher identity without retaining PTY history.
    case shellProcessObservationRecorded(ProcessTreeObservation)
    /// Exact task-owned execution workspace authority. This is not provider
    /// identity and does not itself prove that a runtime honored the cwd.
    case executionWorkspaceBound(ExecutionWorkspace)
    case operationalStateChanged(TaskSessionOperationalState)
}

/// Append-first continuity metadata for one task session.
public struct TaskSessionEvent: Identifiable, Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: UUID
    public let taskSessionID: TaskSessionID
    public let occurredAt: Date
    public let recordedAt: Date
    public let authority: TaskSessionEventAuthority
    public let kind: TaskSessionEventKind

    public init(
        schemaVersion: Int = TaskSessionEvent.currentSchemaVersion,
        id: UUID = UUID(),
        taskSessionID: TaskSessionID,
        occurredAt: Date = Date(),
        recordedAt: Date = Date(),
        authority: TaskSessionEventAuthority,
        kind: TaskSessionEventKind
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.taskSessionID = taskSessionID
        self.occurredAt = occurredAt
        self.recordedAt = recordedAt
        self.authority = authority
        self.kind = kind
    }

    /// Minimal integration hook for advancing task-history recency without
    /// copying any conversation content into task metadata.
    public static func conversationActivity(
        taskSessionID: TaskSessionID,
        at date: Date = Date()
    ) -> TaskSessionEvent {
        TaskSessionEvent(
            taskSessionID: taskSessionID,
            occurredAt: date,
            recordedAt: date,
            authority: .conduitRecorded,
            kind: .conversationActivityRecorded
        )
    }

    /// Minimal integration hook for marking the retention boundary without
    /// storing any conversation content or silently updating task recency.
    public static func conversationRetentionEnabled(
        taskSessionID: TaskSessionID,
        at date: Date = Date()
    ) -> TaskSessionEvent {
        TaskSessionEvent(
            taskSessionID: taskSessionID,
            occurredAt: date,
            recordedAt: date,
            authority: .conduitRecorded,
            kind: .conversationRetentionEnabled
        )
    }

    /// Guards the epistemic boundary even if a malformed local event is read.
    public var hasValidAuthority: Bool {
        switch kind {
        case .created:
            return authority == .conduitRecorded
        case .titleOverridden, .titleReset, .pinChanged, .archiveChanged:
            return authority == .operatorAsserted
        case .conversationActivityRecorded, .conversationRetentionEnabled:
            return authority == .conduitRecorded
        case .shellTelemetryRecorded(let telemetry):
            return authority == .shellHookObserved
                && telemetry.hasValidIdentity
        case .shellProcessObservationRecorded(let observation):
            return authority == .processObserved
                && observation.taskSessionID == taskSessionID.rawValue.uuidString
                && observation.observation.authority == .processObserved
        case .executionWorkspaceBound:
            return authority == .conduitRecorded
        case .operationalStateChanged(let state):
            switch state {
            case .runtimeProvisioning, .runtimeOpened, .runtimeProvisioningFailed:
                return authority == .conduitRecorded
            case .runtimeDetached:
                return authority == .conduitRecorded
                    || authority == .processObserved
            case .closed(let reason):
                switch reason {
                case .operatorClosed, .operatorEndedRuntime:
                    return authority == .operatorAsserted
                case .runtimeEnded, .recoveryObserved:
                    return authority == .processObserved
                }
            case .interrupted:
                return authority == .processObserved
            }
        }
    }
}

/// Pure projection of one append-only task-session event stream.
public struct TaskSessionSnapshot: Identifiable, Codable, Equatable, Sendable {
    public let id: TaskSessionID
    public let metadata: TaskSessionMetadata
    public let createdAt: Date
    public let titleOverride: String?
    public let isPinned: Bool
    public let isArchived: Bool
    /// Latest exact workspace authority retained in the task event stream.
    public let executionWorkspace: ExecutionWorkspace?
    public let operationalState: TaskSessionOperationalState?
    public let operationalStateAt: Date?
    /// True only after a valid Conduit-recorded retention marker appears in the
    /// append-only task stream. Missing conversation data has different meaning
    /// when this is true than it does for a legacy task.
    public let conversationRetentionEnabled: Bool
    /// Most recent content-free conversation-activity fact Conduit retained.
    /// This timestamp carries no prompt, response, attachment, or completion
    /// semantics.
    public let lastConversationActivityAt: Date?
    public let lastActivityAt: Date

    public init(
        id: TaskSessionID,
        metadata: TaskSessionMetadata,
        createdAt: Date,
        titleOverride: String?,
        isPinned: Bool,
        isArchived: Bool,
        executionWorkspace: ExecutionWorkspace? = nil,
        operationalState: TaskSessionOperationalState?,
        operationalStateAt: Date?,
        conversationRetentionEnabled: Bool,
        lastConversationActivityAt: Date?,
        lastActivityAt: Date
    ) {
        self.id = id
        self.metadata = metadata
        self.createdAt = createdAt
        self.titleOverride = titleOverride
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.executionWorkspace = executionWorkspace
        self.operationalState = operationalState
        self.operationalStateAt = operationalStateAt
        self.conversationRetentionEnabled = conversationRetentionEnabled
        self.lastConversationActivityAt = lastConversationActivityAt
        self.lastActivityAt = lastActivityAt
    }

    public var displayTitle: String {
        if let override = Self.nonempty(titleOverride) {
            return override
        }
        if let title = Self.nonempty(metadata.defaultTitle) {
            return title
        }
        let agent = Self.nonempty(metadata.agentName)
        let workspace = Self.nonempty(metadata.workspace.fallbackTitle)
        switch (agent, workspace) {
        case let (agent?, workspace?): return "\(agent) · \(workspace)"
        case let (agent?, nil): return agent
        case let (nil, workspace?): return workspace
        case (nil, nil): return "Untitled session"
        }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum TaskSessionProjection {
    /// File order is authoritative. Duplicate event IDs, mismatched session IDs,
    /// unsupported schemas, and invalid authority/kind combinations are ignored.
    public static func project(
        taskSessionID: TaskSessionID,
        events: [TaskSessionEvent]
    ) -> TaskSessionSnapshot? {
        var seenEventIDs = Set<UUID>()
        var metadata: TaskSessionMetadata?
        var createdAt: Date?
        var titleOverride: String?
        var isPinned = false
        var isArchived = false
        var executionWorkspace: ExecutionWorkspace?
        var operationalState: TaskSessionOperationalState?
        var operationalStateAt: Date?
        var conversationRetentionEnabled = false
        var lastConversationActivityAt: Date?
        var lastActivityAt: Date?

        for event in events {
            guard event.schemaVersion == TaskSessionEvent.currentSchemaVersion,
                  event.taskSessionID == taskSessionID,
                  event.hasValidAuthority,
                  seenEventIDs.insert(event.id).inserted
            else { continue }

            if metadata == nil {
                guard case .created(let created) = event.kind else { continue }
                metadata = created
                createdAt = event.occurredAt
                lastActivityAt = event.recordedAt
                continue
            }

            // A second creation record cannot replace immutable metadata.
            if case .created = event.kind { continue }

            var advancesLastActivity = true
            switch event.kind {
            case .created:
                break
            case .titleOverridden(let title):
                let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    titleOverride = trimmed
                }
            case .titleReset:
                titleOverride = nil
            case .pinChanged(let pinned):
                isPinned = pinned
            case .archiveChanged(let archived):
                isArchived = archived
            case .conversationActivityRecorded:
                if let current = lastConversationActivityAt {
                    lastConversationActivityAt = max(
                        current,
                        event.recordedAt
                    )
                } else {
                    lastConversationActivityAt = event.recordedAt
                }
            case .conversationRetentionEnabled:
                conversationRetentionEnabled = true
                // Enabling a persistence contract is administrative metadata,
                // not user conversation activity. Do not reorder Recent rows.
                advancesLastActivity = false
            case .shellTelemetryRecorded, .shellProcessObservationRecorded:
                break
            case .executionWorkspaceBound(let workspace):
                executionWorkspace = workspace
            case .operationalStateChanged(let state):
                operationalState = state
                operationalStateAt = event.occurredAt
            }
            if advancesLastActivity {
                if let current = lastActivityAt {
                    lastActivityAt = max(current, event.recordedAt)
                } else {
                    lastActivityAt = event.recordedAt
                }
            }
        }

        guard let metadata, let createdAt else { return nil }
        return TaskSessionSnapshot(
            id: taskSessionID,
            metadata: metadata,
            createdAt: createdAt,
            titleOverride: titleOverride,
            isPinned: isPinned,
            isArchived: isArchived,
            executionWorkspace: executionWorkspace,
            operationalState: operationalState,
            operationalStateAt: operationalStateAt,
            conversationRetentionEnabled: conversationRetentionEnabled,
            lastConversationActivityAt: lastConversationActivityAt,
            lastActivityAt: lastActivityAt ?? createdAt
        )
    }
}
