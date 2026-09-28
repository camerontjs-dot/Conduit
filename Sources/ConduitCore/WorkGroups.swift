import Foundation

public struct WorkGroupID: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init() {
        self.rawValue = UUID().uuidString.lowercased()
    }
}

public enum WorkGroupMemberRole: String, Codable, CaseIterable, Sendable {
    case supervisor
    case implementer
    case researcher
    case reviewer
    case qualifier
    case observer
}

public enum WorkGroupMemberReferenceKind: String, Codable, CaseIterable, Sendable {
    case conduitTask = "conduit_task"
    case providerThread = "provider_thread"
    case externalRegularChat = "external_regular_chat"
}

public struct WorkGroupMemberReference: Codable, Equatable, Hashable, Sendable {
    public var kind: WorkGroupMemberReferenceKind
    public var taskSessionID: String?
    public var providerID: String?
    public var threadID: String?
    public var externalReference: String?

    public init(
        kind: WorkGroupMemberReferenceKind,
        taskSessionID: String? = nil,
        providerID: String? = nil,
        threadID: String? = nil,
        externalReference: String? = nil
    ) {
        self.kind = kind
        self.taskSessionID = taskSessionID
        self.providerID = providerID
        self.threadID = threadID
        self.externalReference = externalReference
    }

    public static func conduitTask(_ taskSessionID: String) -> Self {
        Self(kind: .conduitTask, taskSessionID: taskSessionID)
    }

    public static func providerThread(providerID: String, threadID: String) -> Self {
        Self(
            kind: .providerThread,
            providerID: providerID,
            threadID: threadID
        )
    }

    public static func externalRegularChat(_ reference: String) -> Self {
        Self(kind: .externalRegularChat, externalReference: reference)
    }

    public var canonicalID: String? {
        switch kind {
        case .conduitTask:
            guard let taskSessionID = normalized(taskSessionID) else { return nil }
            return "task:\(taskSessionID)"
        case .providerThread:
            guard let providerID = normalized(providerID),
                  let threadID = normalized(threadID) else { return nil }
            return "provider:\(providerID):\(threadID)"
        case .externalRegularChat:
            guard let externalReference = normalized(externalReference) else { return nil }
            return "regular-chat:\(externalReference)"
        }
    }

    public var isWellFormed: Bool { canonicalID != nil }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct WorkGroupRepositoryReference: Codable, Equatable, Sendable {
    public var projectID: OrchestrationValue<String>
    public var repositoryRoot: OrchestrationValue<String>
    public var repositoryFullName: OrchestrationValue<String>
    public var worktreePath: OrchestrationValue<String>

    public init(
        projectID: OrchestrationValue<String> = .unknown,
        repositoryRoot: OrchestrationValue<String> = .unknown,
        repositoryFullName: OrchestrationValue<String> = .unknown,
        worktreePath: OrchestrationValue<String> = .unknown
    ) {
        self.projectID = projectID
        self.repositoryRoot = repositoryRoot
        self.repositoryFullName = repositoryFullName
        self.worktreePath = worktreePath
    }
}

public struct WorkGroupMember: Codable, Equatable, Sendable, Identifiable {
    public var reference: WorkGroupMemberReference
    public var role: WorkGroupMemberRole
    public var addedAt: Date

    public var id: String {
        reference.canonicalID ?? "invalid:\(reference.kind.rawValue)"
    }

    public init(
        reference: WorkGroupMemberReference,
        role: WorkGroupMemberRole,
        addedAt: Date = Date()
    ) {
        self.reference = reference
        self.role = role
        self.addedAt = addedAt
    }
}

public struct WorkGroup: Codable, Equatable, Sendable, Identifiable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: WorkGroupID
    public var name: String
    public var archived: Bool
    public var primary: WorkGroupRepositoryReference
    public var members: [WorkGroupMember]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        schemaVersion: Int = WorkGroup.currentSchemaVersion,
        id: WorkGroupID = WorkGroupID(),
        name: String,
        archived: Bool = false,
        primary: WorkGroupRepositoryReference = WorkGroupRepositoryReference(),
        members: [WorkGroupMember] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.archived = archived
        self.primary = primary
        self.members = members
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum WorkGroupStoreError: LocalizedError, Equatable {
    case invalidName
    case invalidReference
    case notFound(WorkGroupID)
    case malformedLedger(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Work Group name must not be empty."
        case .invalidReference:
            return "Work Group member reference is incomplete."
        case .notFound(let id):
            return "Work Group \(id.rawValue) was not found."
        case .malformedLedger(let detail):
            return "Work Group ledger is malformed: \(detail)"
        }
    }
}

private struct WorkGroupLedger: Codable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = WorkGroupLedger.currentSchemaVersion
    var groups: [WorkGroup] = []
}

/// Durable coordination state for Work Groups.
///
/// Work Groups contain references to canonical task/thread authorities. They do
/// not own provider sessions, launch workers, acquire writer authority, or
/// duplicate conversation/provider persistence.
public final class WorkGroupStore: @unchecked Sendable {
    public let directory: URL
    public let ledgerURL: URL

    private let fileManager: FileManager
    private let lock = NSLock()

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory.standardizedFileURL
        self.ledgerURL = directory.appendingPathComponent("work-groups-v1.json")
        self.fileManager = fileManager
    }

    public func list(includeArchived: Bool = false) throws -> [WorkGroup] {
        try withLock {
            let groups = try load().groups
            return groups
                .filter { includeArchived || !$0.archived }
                .sorted {
                    if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
        }
    }

    public func group(id: WorkGroupID) throws -> WorkGroup? {
        try withLock {
            try load().groups.first { $0.id == id }
        }
    }

    @discardableResult
    public func create(
        name: String,
        primary: WorkGroupRepositoryReference = WorkGroupRepositoryReference(),
        createdAt: Date = Date()
    ) throws -> WorkGroup {
        try withLock {
            let normalized = try validName(name)
            var ledger = try load()
            let group = WorkGroup(
                name: normalized,
                primary: primary,
                createdAt: createdAt,
                updatedAt: createdAt
            )
            ledger.groups.append(group)
            try save(ledger)
            return group
        }
    }

    @discardableResult
    public func rename(
        id: WorkGroupID,
        name: String,
        updatedAt: Date = Date()
    ) throws -> WorkGroup {
        try mutate(id: id, updatedAt: updatedAt) { group in
            group.name = try validName(name)
        }
    }

    @discardableResult
    public func setArchived(
        id: WorkGroupID,
        archived: Bool,
        updatedAt: Date = Date()
    ) throws -> WorkGroup {
        try mutate(id: id, updatedAt: updatedAt) { group in
            group.archived = archived
        }
    }

    @discardableResult
    public func setPrimary(
        id: WorkGroupID,
        primary: WorkGroupRepositoryReference,
        updatedAt: Date = Date()
    ) throws -> WorkGroup {
        try mutate(id: id, updatedAt: updatedAt) { group in
            group.primary = primary
        }
    }

    @discardableResult
    public func addMember(
        groupID: WorkGroupID,
        reference: WorkGroupMemberReference,
        role: WorkGroupMemberRole,
        addedAt: Date = Date()
    ) throws -> WorkGroup {
        guard reference.isWellFormed else {
            throw WorkGroupStoreError.invalidReference
        }
        return try mutate(id: groupID, updatedAt: addedAt) { group in
            let canonicalID = reference.canonicalID
            if let index = group.members.firstIndex(where: {
                $0.reference.canonicalID == canonicalID
            }) {
                group.members[index].role = role
            } else {
                group.members.append(
                    WorkGroupMember(
                        reference: reference,
                        role: role,
                        addedAt: addedAt
                    )
                )
            }
        }
    }

    @discardableResult
    public func removeMember(
        groupID: WorkGroupID,
        reference: WorkGroupMemberReference,
        updatedAt: Date = Date()
    ) throws -> WorkGroup {
        guard let canonicalID = reference.canonicalID else {
            throw WorkGroupStoreError.invalidReference
        }
        return try mutate(id: groupID, updatedAt: updatedAt) { group in
            group.members.removeAll {
                $0.reference.canonicalID == canonicalID
            }
        }
    }

    private func mutate(
        id: WorkGroupID,
        updatedAt: Date,
        _ body: (inout WorkGroup) throws -> Void
    ) throws -> WorkGroup {
        try withLock {
            var ledger = try load()
            guard let index = ledger.groups.firstIndex(where: { $0.id == id }) else {
                throw WorkGroupStoreError.notFound(id)
            }
            try body(&ledger.groups[index])
            ledger.groups[index].updatedAt = updatedAt
            let result = ledger.groups[index]
            try save(ledger)
            return result
        }
    }

    private func validName(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw WorkGroupStoreError.invalidName }
        return normalized
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func load() throws -> WorkGroupLedger {
        guard fileManager.fileExists(atPath: ledgerURL.path) else {
            return WorkGroupLedger()
        }
        do {
            let data = try Data(contentsOf: ledgerURL)
            let ledger = try JSONDecoder().decode(WorkGroupLedger.self, from: data)
            guard ledger.schemaVersion == WorkGroupLedger.currentSchemaVersion else {
                throw WorkGroupStoreError.malformedLedger(
                    "unsupported schema \(ledger.schemaVersion)"
                )
            }
            return ledger
        } catch let error as WorkGroupStoreError {
            throw error
        } catch {
            throw WorkGroupStoreError.malformedLedger(error.localizedDescription)
        }
    }

    private func save(_ ledger: WorkGroupLedger) throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(ledger).write(to: ledgerURL, options: .atomic)
    }
}

public struct WorkGroupThreadObservation: Equatable, Sendable {
    public var reference: WorkGroupMemberReference
    public var displayTitle: String
    public var providerLabel: OrchestrationValue<String>
    public var lastActivityAt: OrchestrationValue<Date>
    public var unseenCount: OrchestrationValue<Int>
    public var repositoryRoot: OrchestrationValue<String>
    public var worktreePath: OrchestrationValue<String>

    public init(
        reference: WorkGroupMemberReference,
        displayTitle: String,
        providerLabel: OrchestrationValue<String> = .unknown,
        lastActivityAt: OrchestrationValue<Date> = .unknown,
        unseenCount: OrchestrationValue<Int> = .unknown,
        repositoryRoot: OrchestrationValue<String> = .unknown,
        worktreePath: OrchestrationValue<String> = .unknown
    ) {
        self.reference = reference
        self.displayTitle = displayTitle
        self.providerLabel = providerLabel
        self.lastActivityAt = lastActivityAt
        self.unseenCount = unseenCount
        self.repositoryRoot = repositoryRoot
        self.worktreePath = worktreePath
    }
}

public struct WorkGroupThreadRailItem: Equatable, Sendable, Identifiable {
    public var member: WorkGroupMember
    public var observation: WorkGroupThreadObservation?

    public var id: String { member.id }

    public var displayTitle: String {
        observation?.displayTitle ?? member.id
    }

    public init(
        member: WorkGroupMember,
        observation: WorkGroupThreadObservation?
    ) {
        self.member = member
        self.observation = observation
    }
}

/// Derived projection over existing task/provider observations.
///
/// No provider/session inventory is persisted here. Missing observations stay
/// missing rather than being replaced with duplicate runtime truth.
public enum WorkGroupThreadRailProjection {
    public static func items(
        group: WorkGroup,
        observations: [WorkGroupThreadObservation]
    ) -> [WorkGroupThreadRailItem] {
        let observationByID = Dictionary(
            uniqueKeysWithValues: observations.compactMap { observation in
                guard let id = observation.reference.canonicalID else { return nil }
                return (id, observation)
            }
        )

        return group.members
            .map { member in
                WorkGroupThreadRailItem(
                    member: member,
                    observation: observationByID[member.id]
                )
            }
            .sorted { lhs, rhs in
                let left = lhs.observation?.lastActivityAt.value
                let right = rhs.observation?.lastActivityAt.value
                switch (left, right) {
                case let (l?, r?) where l != r:
                    return l > r
                case (nil, _?):
                    return false
                case (_?, nil):
                    return true
                default:
                    return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle)
                        == .orderedAscending
                }
            }
    }
}

public struct WorkGroupComposerDestination: Equatable, Sendable {
    public var groupID: WorkGroupID
    public var groupName: String
    public var target: WorkGroupMemberReference
    public var targetTitle: String

    public init(
        groupID: WorkGroupID,
        groupName: String,
        target: WorkGroupMemberReference,
        targetTitle: String
    ) {
        self.groupID = groupID
        self.groupName = groupName
        self.target = target
        self.targetTitle = targetTitle
    }

    public var breadcrumb: String {
        "Work Group: \(groupName) → \(targetTitle)"
    }
}

public enum WorkGroupTargetWarning: Equatable, Sendable {
    case nonMemberTarget
    case repositoryMismatch(expected: String, actual: String)
    case worktreeMismatch(expected: String, actual: String)

    public var message: String {
        switch self {
        case .nonMemberTarget:
            return "Target is not a member of this Work Group."
        case .repositoryMismatch(let expected, let actual):
            return "Target repository \(actual) does not match Work Group repository \(expected)."
        case .worktreeMismatch(let expected, let actual):
            return "Target worktree \(actual) does not match Work Group worktree \(expected)."
        }
    }
}

public enum WorkGroupTargetValidator {
    public static func warnings(
        group: WorkGroup,
        target: WorkGroupMemberReference,
        observation: WorkGroupThreadObservation?
    ) -> [WorkGroupTargetWarning] {
        guard let targetID = target.canonicalID else {
            return [.nonMemberTarget]
        }

        var result: [WorkGroupTargetWarning] = []
        if !group.members.contains(where: { $0.id == targetID }) {
            result.append(.nonMemberTarget)
        }

        if let expected = group.primary.repositoryRoot.value,
           let actual = observation?.repositoryRoot.value,
           standardizedPath(expected) != standardizedPath(actual) {
            result.append(.repositoryMismatch(expected: expected, actual: actual))
        }

        if let expected = group.primary.worktreePath.value,
           let actual = observation?.worktreePath.value,
           standardizedPath(expected) != standardizedPath(actual) {
            result.append(.worktreeMismatch(expected: expected, actual: actual))
        }

        return result
    }

    private static func standardizedPath(_ value: String) -> String {
        URL(fileURLWithPath: value).standardizedFileURL.path
    }
}
