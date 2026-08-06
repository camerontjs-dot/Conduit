import Foundation

public enum TaskSessionAvailabilityKind: String, Codable, Equatable, Sendable {
    case running
    case reconnectable
    case recentClosed
    case interrupted
    case unavailable
    case unknown
}

/// Operational availability only. It deliberately has no completed,
/// successful, correct, or verified state.
public enum TaskSessionAvailability: Codable, Equatable, Sendable {
    case running(RuntimeAttemptID)
    case reconnectable
    case recentClosed(at: Date, reason: TaskSessionCloseReason)
    case interrupted
    case unavailable
    case unknown

    public var kind: TaskSessionAvailabilityKind {
        switch self {
        case .running: return .running
        case .reconnectable: return .reconnectable
        case .recentClosed: return .recentClosed
        case .interrupted: return .interrupted
        case .unavailable: return .unavailable
        case .unknown: return .unknown
        }
    }
}

/// Whether an external reconnectability source was successfully observed.
/// A failed or absent observation can never turn absence into unavailability.
public enum ExternalReconnectabilityObservation: Codable, Equatable, Sendable {
    case notChecked
    case succeeded(observedAt: Date)
    case failed(observedAt: Date?)
}

public struct TaskSessionAvailabilityContext: Codable, Equatable, Sendable {
    public var liveRuntimeAttempts: [TaskSessionID: RuntimeAttemptID]
    public var reconnectableTaskSessionIDs: Set<TaskSessionID>
    public var externalObservation: ExternalReconnectabilityObservation

    public init(
        liveRuntimeAttempts: [TaskSessionID: RuntimeAttemptID] = [:],
        reconnectableTaskSessionIDs: Set<TaskSessionID> = [],
        externalObservation: ExternalReconnectabilityObservation = .notChecked
    ) {
        self.liveRuntimeAttempts = liveRuntimeAttempts
        self.reconnectableTaskSessionIDs = reconnectableTaskSessionIDs
        self.externalObservation = externalObservation
    }
}

public enum TaskSessionAvailabilityResolver {
    public static func resolve(
        session: TaskSessionSnapshot,
        context: TaskSessionAvailabilityContext
    ) -> TaskSessionAvailability {
        if let attempt = context.liveRuntimeAttempts[session.id] {
            return .running(attempt)
        }
        if context.reconnectableTaskSessionIDs.contains(session.id) {
            return .reconnectable
        }

        switch session.operationalState {
        case .closed(let reason):
            return .recentClosed(
                at: session.operationalStateAt ?? session.lastActivityAt,
                reason: reason
            )
        case .interrupted:
            return .interrupted
        case .runtimeOpened:
            if case .succeeded = context.externalObservation {
                return .interrupted
            }
            return .unknown
        case .runtimeDetached:
            if case .succeeded = context.externalObservation {
                return .unavailable
            }
            return .unknown
        case nil:
            return .unknown
        }
    }
}

public enum TaskSessionCatalogSort: String, Codable, Equatable, Sendable {
    case pinnedThenRecent
    case recentFirst
    case title
}

public struct TaskSessionCatalogQuery: Codable, Equatable, Sendable {
    public var workspaceRootPath: String?
    public var projectPath: String?
    public var searchText: String
    public var includeArchived: Bool
    public var pinnedOnly: Bool
    public var availabilityKind: TaskSessionAvailabilityKind?
    public var sort: TaskSessionCatalogSort

    public init(
        workspaceRootURL: URL? = nil,
        projectURL: URL? = nil,
        searchText: String = "",
        includeArchived: Bool = false,
        pinnedOnly: Bool = false,
        availabilityKind: TaskSessionAvailabilityKind? = nil,
        sort: TaskSessionCatalogSort = .pinnedThenRecent
    ) {
        self.workspaceRootPath = workspaceRootURL?.standardizedFileURL.path
        self.projectPath = projectURL?.standardizedFileURL.path
        self.searchText = searchText
        self.includeArchived = includeArchived
        self.pinnedOnly = pinnedOnly
        self.availabilityKind = availabilityKind
        self.sort = sort
    }
}

public struct TaskSessionCatalogRow: Identifiable, Codable, Equatable, Sendable {
    public let session: TaskSessionSnapshot
    public let availability: TaskSessionAvailability

    public var id: TaskSessionID { session.id }

    public init(
        session: TaskSessionSnapshot,
        availability: TaskSessionAvailability
    ) {
        self.session = session
        self.availability = availability
    }
}

/// Pure, rebuildable index over TaskSession metadata plus current availability
/// observations. MainFrame project data is never authored here.
public enum SessionCatalog {
    public static func rows(
        sessions: [TaskSessionSnapshot],
        availabilityContext: TaskSessionAvailabilityContext,
        query: TaskSessionCatalogQuery = TaskSessionCatalogQuery()
    ) -> [TaskSessionCatalogRow] {
        let search = normalized(query.searchText)
        let filtered = sessions.compactMap { session -> TaskSessionCatalogRow? in
            let availability = TaskSessionAvailabilityResolver.resolve(
                session: session,
                context: availabilityContext
            )

            guard query.includeArchived || !session.isArchived else { return nil }
            guard !query.pinnedOnly || session.isPinned else { return nil }
            guard query.workspaceRootPath == nil
                    || session.metadata.workspace.rootPath == query.workspaceRootPath
            else { return nil }
            guard query.projectPath == nil
                    || session.metadata.workspace.projectPath == query.projectPath
            else { return nil }
            guard query.availabilityKind == nil
                    || availability.kind == query.availabilityKind
            else { return nil }
            guard search.isEmpty || searchableText(session).contains(search) else { return nil }

            return TaskSessionCatalogRow(session: session, availability: availability)
        }

        return filtered.sorted { lhs, rhs in
            switch query.sort {
            case .pinnedThenRecent:
                if lhs.session.isPinned != rhs.session.isPinned {
                    return lhs.session.isPinned && !rhs.session.isPinned
                }
                let lhsActivity = catalogActivityAt(lhs.session)
                let rhsActivity = catalogActivityAt(rhs.session)
                if lhsActivity != rhsActivity {
                    return lhsActivity > rhsActivity
                }
            case .recentFirst:
                let lhsActivity = catalogActivityAt(lhs.session)
                let rhsActivity = catalogActivityAt(rhs.session)
                if lhsActivity != rhsActivity {
                    return lhsActivity > rhsActivity
                }
            case .title:
                let lhsTitle = normalized(lhs.session.displayTitle)
                let rhsTitle = normalized(rhs.session.displayTitle)
                if lhsTitle != rhsTitle {
                    return lhsTitle < rhsTitle
                }
            }
            return stableKey(lhs.id) < stableKey(rhs.id)
        }
    }

    private static func searchableText(_ session: TaskSessionSnapshot) -> String {
        normalized([
            session.displayTitle,
            session.metadata.agentName ?? "",
            session.metadata.workspace.fallbackTitle,
            session.metadata.workspace.fallbackSlug,
            session.metadata.workspace.rootPath,
            session.metadata.workspace.projectPath ?? ""
        ].joined(separator: "\n"))
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
    }

    private static func stableKey(_ id: TaskSessionID) -> String {
        id.rawValue.uuidString.lowercased()
    }

    /// Conversation activity is deliberately content-free, but remains an
    /// explicit catalog input so Recent ordering does not regress if other
    /// task-metadata activity semantics change later.
    private static func catalogActivityAt(
        _ session: TaskSessionSnapshot
    ) -> Date {
        guard let conversation = session.lastConversationActivityAt else {
            return session.lastActivityAt
        }
        return max(session.lastActivityAt, conversation)
    }
}
