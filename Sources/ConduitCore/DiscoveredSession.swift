import Foundation

/// Exact observation of the task-continuity option on a tmux session.
///
/// An absent option is a recoverable legacy state. A malformed non-empty
/// value is preserved for diagnosis and must never be treated as absence.
public enum DiscoveredTaskSessionBinding: Equatable, Sendable {
    case absent
    case valid(TaskSessionID)
    case malformed(rawValue: String)

    public init(optionValue: String?) {
        guard let optionValue, !optionValue.isEmpty else {
            self = .absent
            return
        }
        guard let uuid = UUID(uuidString: optionValue) else {
            self = .malformed(rawValue: optionValue)
            return
        }
        self = .valid(TaskSessionID(rawValue: uuid))
    }

    public var taskSessionID: TaskSessionID? {
        guard case .valid(let id) = self else { return nil }
        return id
    }
}

/// A durable tmux session Conduit found on the server, as reported by tmux.
///
/// Identity comes from tmux user options written at creation, not from parsing
/// the session name. A name is a display convenience; an option is a record.
/// Sessions created before those options existed — or by something else
/// entirely — therefore arrive with `projectPath`/`agentName` nil and must be
/// presented as unidentified rather than guessed into a project.
public struct DiscoveredSession: Equatable, Sendable {
    public let tmuxName: String
    public let projectPath: URL?
    public let agentName: String?
    public let taskSessionBinding: DiscoveredTaskSessionBinding
    public let createdAt: Date?
    /// tmux reports how many clients are attached. Non-zero means something is
    /// already looking at this session — possibly another Conduit window or a
    /// terminal elsewhere — so resuming it is a join, not a handover.
    public let attachedClients: Int

    public init(
        tmuxName: String,
        projectPath: URL? = nil,
        agentName: String? = nil,
        taskSessionBinding: DiscoveredTaskSessionBinding = .absent,
        createdAt: Date? = nil,
        attachedClients: Int = 0
    ) {
        self.tmuxName = tmuxName
        self.projectPath = projectPath
        self.agentName = agentName
        self.taskSessionBinding = taskSessionBinding
        self.createdAt = createdAt
        self.attachedClients = attachedClients
    }

    public var isIdentified: Bool {
        projectPath != nil && agentName != nil
    }
}

/// A previously-open runtime attempt that a complete tmux observation proves
/// is absent. The caller may append an interrupted event for this pair.
public struct TaskSessionInterruptionCandidate: Equatable, Sendable {
    public let taskSessionID: TaskSessionID
    public let runtimeAttemptID: RuntimeAttemptID

    public init(
        taskSessionID: TaskSessionID,
        runtimeAttemptID: RuntimeAttemptID
    ) {
        self.taskSessionID = taskSessionID
        self.runtimeAttemptID = runtimeAttemptID
    }
}

/// Pure restart-reconciliation policy for converting complete tmux discovery
/// into safe negative evidence.
public enum TaskSessionRestartReconciler {
    public static func interruptionCandidates(
        taskSessions: [TaskSessionSnapshot],
        liveTaskIDs: Set<TaskSessionID>,
        discoveredSessions: [DiscoveredSession]
    ) -> [TaskSessionInterruptionCandidate] {
        // A malformed binding could belong to any prior task. Until it is
        // reviewed, absence is not safe negative evidence for any task.
        guard !discoveredSessions.contains(where: {
            if case .malformed = $0.taskSessionBinding { return true }
            return false
        }) else { return [] }

        // A valid task binding is positive continuity evidence even when its
        // descriptive project/agent metadata conflicts. Compatibility is a
        // separate explicit-reconnect gate; it must not be rewritten as
        // evidence that the runtime disappeared.
        let discoveredTaskIDs = Set(
            discoveredSessions.compactMap(
                \.taskSessionBinding.taskSessionID
            )
        )

        return taskSessions.compactMap { task in
            guard !liveTaskIDs.contains(task.id),
                  !discoveredTaskIDs.contains(task.id),
                  case .runtimeOpened(let attemptID)? = task.operationalState
            else { return nil }
            return TaskSessionInterruptionCandidate(
                taskSessionID: task.id,
                runtimeAttemptID: attemptID
            )
        }
    }
}

/// Parses `tmux list-sessions -F` output. Pure so it can be tested against
/// real captured output instead of only against a live server.
public enum TmuxSessionListParser {
    /// A printable multi-character token, not a control character.
    ///
    /// tmux rewrites control bytes in `-F` output: both `0x1F` and a tab come
    /// back as a literal `_`, which silently collapsed every row into one
    /// unsplittable field. Verified against tmux 3.6 by hexdump. This token
    /// survives byte-for-byte and cannot plausibly occur in a session name,
    /// project path, or agent name.
    public static let fieldSeparator = "<|conduit|>"

    public static let format = [
        "#{session_name}",
        "#{session_created}",
        "#{session_attached}",
        "#{@conduit_project}",
        "#{@conduit_agent}",
        "#{@conduit_task_session}"
    ].joined(separator: fieldSeparator)

    public static func parse(_ output: String) -> [DiscoveredSession] {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> DiscoveredSession? in
                // Trailing fields are empty whenever the identity options are
                // unset, and Foundation's splitting drops trailing empties in
                // some forms — so require only the fields that must exist and
                // read the optional ones defensively.
                let fields = line.components(separatedBy: fieldSeparator)
                guard fields.count >= 3 else { return nil }
                let name = fields[0]
                guard name.hasPrefix("conduit-") else { return nil }
                func field(_ index: Int) -> String? {
                    guard index < fields.count, !fields[index].isEmpty else { return nil }
                    return fields[index]
                }
                return DiscoveredSession(
                    tmuxName: name,
                    projectPath: field(3).map { URL(fileURLWithPath: $0) },
                    agentName: field(4),
                    // Five-field rows were emitted before task continuity and
                    // intentionally decode as an absent legacy binding.
                    taskSessionBinding: DiscoveredTaskSessionBinding(
                        optionValue: field(5)
                    ),
                    createdAt: field(1).flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:)),
                    attachedClients: field(2).flatMap(Int.init) ?? 0
                )
            }
    }
}

/// How a discovered session relates to what Conduit is currently showing.
public enum DiscoveredSessionRelation: Equatable, Sendable {
    /// Already open as a tab; resuming would duplicate it.
    case alreadyOpen
    /// Belongs to the selected project and can be resumed here.
    case resumableHere
    /// Belongs to a different known project.
    case otherProject(projectTitle: String)
    /// tmux knows it but Conduit cannot say whose it is.
    case unidentified
}

public struct ResumableSession: Equatable, Sendable {
    public let session: DiscoveredSession
    public let relation: DiscoveredSessionRelation

    public init(session: DiscoveredSession, relation: DiscoveredSessionRelation) {
        self.session = session
        self.relation = relation
    }
}

public enum DiscoveredSessionCatalog {
    /// Classifies every discovered session against current state.
    ///
    /// Nothing is filtered out: a session Conduit cannot identify still appears,
    /// because hiding it would imply tmux is empty when it is not. Ordering is
    /// resumable-here first, then other projects, then unidentified, each
    /// newest-first so the session you just left is nearest the top. Sessions
    /// with no creation time sort last within their group rather than being
    /// treated as oldest or newest.
    public static func classify(
        discovered: [DiscoveredSession],
        selectedProjectPath: URL?,
        openTmuxNames: Set<String>,
        knownProjects: [URL: String]
    ) -> [ResumableSession] {
        let selected = selectedProjectPath?.standardizedFileURL
        let normalizedProjects = Dictionary(
            knownProjects.map { ($0.key.standardizedFileURL, $0.value) },
            uniquingKeysWith: { first, _ in first }
        )

        let classified = discovered.map { session -> ResumableSession in
            if openTmuxNames.contains(session.tmuxName) {
                return ResumableSession(session: session, relation: .alreadyOpen)
            }
            guard let path = session.projectPath?.standardizedFileURL, session.agentName != nil else {
                return ResumableSession(session: session, relation: .unidentified)
            }
            if let selected, path == selected {
                return ResumableSession(session: session, relation: .resumableHere)
            }
            if let title = normalizedProjects[path] {
                return ResumableSession(session: session, relation: .otherProject(projectTitle: title))
            }
            // Identified, but its project is not in the current scan — say so
            // rather than claiming it belongs somewhere it does not.
            return ResumableSession(
                session: session,
                relation: .otherProject(projectTitle: path.lastPathComponent)
            )
        }

        return classified.sorted { lhs, rhs in
            let lhsRank = rank(lhs.relation)
            let rhsRank = rank(rhs.relation)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            switch (lhs.session.createdAt, rhs.session.createdAt) {
            case let (l?, r?) where l != r: return l > r
            case (nil, _?): return false
            case (_?, nil): return true
            default: return lhs.session.tmuxName < rhs.session.tmuxName
            }
        }
    }

    private static func rank(_ relation: DiscoveredSessionRelation) -> Int {
        switch relation {
        case .resumableHere: return 0
        case .alreadyOpen: return 1
        case .otherProject: return 2
        case .unidentified: return 3
        }
    }
}
