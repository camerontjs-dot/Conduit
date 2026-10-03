import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private enum WorkGroupIdentity {
    static func isExact(_ value: String) -> Bool {
        !value.isEmpty
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.rangeOfCharacter(from: .controlCharacters) == nil
    }

    /// Delimiters, percent signs and Unicode bytes belong to the component,
    /// never to another reference. No provider identity is trimmed or folded.
    static func component(_ value: String) -> String {
        value.utf8.map { byte in
            switch byte {
            case 65...90, 97...122, 48...57, 45, 46, 95, 126:
                return String(UnicodeScalar(byte))
            default:
                return String(format: "%%%02X", byte)
            }
        }.joined()
    }

    static func path(_ value: String) -> String? {
        guard isExact(value), value.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: value).standardizedFileURL.path
    }

    static func sortKey(_ value: String) -> String {
        value.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

public struct WorkGroupID: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init() {
        self.rawValue = UUID().uuidString.lowercased()
    }

    public var isWellFormed: Bool {
        WorkGroupIdentity.isExact(rawValue)
            && rawValue.utf8.allSatisfy { $0 < 128 }
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

    public static func conduitTask(_ taskSessionID: TaskSessionID) -> Self {
        .conduitTask(taskSessionID.rawValue.uuidString.lowercased())
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
            guard providerID == nil, threadID == nil, externalReference == nil,
                  let taskSessionID = exact(taskSessionID) else { return nil }
            // TaskSessionID owns UUID identity. Opaque legacy fixture IDs stay
            // exact; a valid UUID has the same identity through either API.
            let identity = UUID(uuidString: taskSessionID)?.uuidString.lowercased() ?? taskSessionID
            return "task:\(WorkGroupIdentity.component(identity))"
        case .providerThread:
            guard taskSessionID == nil, externalReference == nil,
                  let providerID = exact(providerID),
                  let threadID = exact(threadID) else { return nil }
            return "provider:\(WorkGroupIdentity.component(providerID)):\(WorkGroupIdentity.component(threadID))"
        case .externalRegularChat:
            guard taskSessionID == nil, providerID == nil, threadID == nil,
                  let externalReference = exact(externalReference) else { return nil }
            return "regular-chat:\(WorkGroupIdentity.component(externalReference))"
        }
    }

    public var isWellFormed: Bool { canonicalID != nil }

    private func exact(_ value: String?) -> String? {
        guard let value, WorkGroupIdentity.isExact(value) else { return nil }
        return value
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

    public var isWellFormed: Bool {
        for value in [projectID, repositoryFullName] {
            if let known = value.value, !WorkGroupIdentity.isExact(known) { return false }
        }
        for value in [repositoryRoot, worktreePath] {
            if let known = value.value, WorkGroupIdentity.path(known) == nil { return false }
        }
        return true
    }
}

public enum WorkGroupOwnerReferenceKind: String, Codable, CaseIterable, Sendable {
    case executionWorkspace = "execution_workspace"
    case contextSet = "context_set"
    case contextManifest = "context_manifest"
    case routingDecision = "routing_decision"
    case orchestrationRun = "orchestration_run"
    case githubIssue = "github_issue"
    case githubPullRequest = "github_pull_request"
    case artifact
}

/// An exact nomination to another owner. This stores no source bytes, runtime
/// binding, provider entitlement, delivery, verification or acceptance truth.
/// Callers supply the owner's actual object identity; unavailable identities
/// are represented by absence of a nomination, never by a generated stand-in.
public struct WorkGroupOwnerReference: Codable, Equatable, Sendable, Identifiable {
    public var kind: WorkGroupOwnerReferenceKind
    public var objectID: String
    public var revisionIdentity: OrchestrationValue<String>
    public var sourceReference: OrchestrationValue<String>

    public init(
        kind: WorkGroupOwnerReferenceKind,
        objectID: String,
        revisionIdentity: OrchestrationValue<String> = .unknown,
        sourceReference: OrchestrationValue<String> = .unknown
    ) {
        self.kind = kind
        self.objectID = objectID
        self.revisionIdentity = revisionIdentity
        self.sourceReference = sourceReference
    }

    public static func contextSet(_ contextSet: ContextSet) -> Self {
        .init(kind: .contextSet, objectID: contextSet.id)
    }

    public var id: String { "\(kind.rawValue):\(WorkGroupIdentity.component(objectID))" }

    public var isWellFormed: Bool {
        guard WorkGroupIdentity.isExact(objectID) else { return false }
        return [revisionIdentity, sourceReference].allSatisfy {
            $0.value.map(WorkGroupIdentity.isExact) ?? true
        }
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
    /// Coordination revision, independent of any task or provider version.
    public var revision: Int
    public var ownerReferences: [WorkGroupOwnerReference]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        schemaVersion: Int = WorkGroup.currentSchemaVersion,
        id: WorkGroupID = WorkGroupID(),
        name: String,
        archived: Bool = false,
        primary: WorkGroupRepositoryReference = WorkGroupRepositoryReference(),
        members: [WorkGroupMember] = [],
        revision: Int = 0,
        ownerReferences: [WorkGroupOwnerReference] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.archived = archived
        self.primary = primary
        self.members = members
        self.revision = revision
        self.ownerReferences = ownerReferences
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, archived, primary, members, revision
        case ownerReferences, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        id = try container.decode(WorkGroupID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        archived = try container.decode(Bool.self, forKey: .archived)
        primary = try container.decode(WorkGroupRepositoryReference.self, forKey: .primary)
        members = try container.decode([WorkGroupMember].self, forKey: .members)
        // Frozen #98's v1 records did not contain these additive fields.
        revision = container.contains(.revision) ? try container.decode(Int.self, forKey: .revision) : 0
        ownerReferences = container.contains(.ownerReferences)
            ? try container.decode([WorkGroupOwnerReference].self, forKey: .ownerReferences) : []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    public var isWellFormed: Bool {
        guard schemaVersion == Self.currentSchemaVersion, id.isWellFormed,
              WorkGroupIdentity.isExact(name), primary.isWellFormed, revision >= 0,
              createdAt.timeIntervalSince1970.isFinite,
              updatedAt.timeIntervalSince1970.isFinite else { return false }
        var membersSeen = Set<String>()
        for member in members {
            guard let identity = member.reference.canonicalID,
                  member.addedAt.timeIntervalSince1970.isFinite,
                  membersSeen.insert(identity).inserted else { return false }
        }
        var referencesSeen = Set<String>()
        return ownerReferences.allSatisfy {
            $0.isWellFormed && referencesSeen.insert($0.id).inserted
        }
    }
}

public enum WorkGroupStoreError: LocalizedError, Equatable {
    case invalidName
    case invalidReference
    case invalidIdentity
    case identityCollision(WorkGroupID)
    case staleRevision(expected: Int, actual: Int)
    case storageUnavailable(String)
    case notFound(WorkGroupID)
    case malformedLedger(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Work Group name must not be empty."
        case .invalidReference:
            return "Work Group member reference is incomplete."
        case .invalidIdentity:
            return "Work Group identity or coordination record is invalid."
        case .identityCollision(let id):
            return "Work Group \(id.rawValue) already has different creation state."
        case .staleRevision(let expected, let actual):
            return "Work Group revision \(expected) is stale; current revision is \(actual)."
        case .storageUnavailable(let detail):
            return "Work Group storage is unavailable: \(detail)"
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
private final class WorkGroupProcessLocks: @unchecked Sendable {
    static let shared = WorkGroupProcessLocks()
    private let lock = NSLock()
    private var byPath: [String: NSLock] = [:]

    func forPath(_ path: String) -> NSLock {
        lock.lock()
        defer { lock.unlock() }
        if let existing = byPath[path] { return existing }
        let result = NSLock()
        byPath[path] = result
        return result
    }
}

public final class WorkGroupStore: @unchecked Sendable {
    public let directory: URL
    public let ledgerURL: URL
    public let lockURL: URL

    private let fileManager: FileManager
    private let lock: NSLock

    /// Storage is supplied by the caller. This never selects an operator home
    /// or task/provider store, and never owns the references it persists.
    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        self.ledgerURL = self.directory.appendingPathComponent("work-groups-v1.json")
        self.lockURL = self.directory.appendingPathComponent("work-groups-v1.lock")
        self.fileManager = fileManager
        self.lock = WorkGroupProcessLocks.shared.forPath(self.lockURL.path)
    }

    public func list(includeArchived: Bool = false) throws -> [WorkGroup] {
        try withReadLock {
            try load().groups
                .filter { includeArchived || !$0.archived }
                .sorted {
                    if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                    let left = WorkGroupIdentity.sortKey($0.name)
                    let right = WorkGroupIdentity.sortKey($1.name)
                    if left != right { return left < right }
                    return $0.id.rawValue < $1.id.rawValue
                }
        }
    }

    public func group(id: WorkGroupID) throws -> WorkGroup? {
        guard id.isWellFormed else { throw WorkGroupStoreError.invalidIdentity }
        return try withReadLock { try load().groups.first { $0.id == id } }
    }

    /// An explicit ID permits a caller to replay the same creation intent.
    /// A different intent for an existing ID fails without replacing its state.
    @discardableResult
    public func create(
        id: WorkGroupID = WorkGroupID(),
        name: String,
        primary: WorkGroupRepositoryReference = WorkGroupRepositoryReference(),
        ownerReferences: [WorkGroupOwnerReference] = [],
        createdAt: Date = Date()
    ) throws -> WorkGroup {
        guard id.isWellFormed else { throw WorkGroupStoreError.invalidIdentity }
        let normalized = try validName(name)
        let references = ownerReferences.sorted { $0.id < $1.id }
        let candidate = WorkGroup(
            id: id, name: normalized, primary: primary,
            ownerReferences: references, createdAt: createdAt, updatedAt: createdAt
        )
        guard candidate.isWellFormed else { throw WorkGroupStoreError.invalidReference }
        return try withWriteLock {
            var ledger = try load()
            if let existing = ledger.groups.first(where: { $0.id == id }) {
                guard existing.name == normalized, existing.primary == primary,
                      existing.ownerReferences == references else {
                    throw WorkGroupStoreError.identityCollision(id)
                }
                return existing
            }
            ledger.groups.append(candidate)
            try save(ledger)
            return candidate
        }
    }

    @discardableResult
    public func rename(
        id: WorkGroupID,
        name: String,
        expectedRevision: Int? = nil,
        updatedAt: Date = Date()
    ) throws -> WorkGroup {
        let normalized = try validName(name)
        return try mutate(id: id, expectedRevision: expectedRevision, updatedAt: updatedAt) {
            $0.name = normalized
        }
    }

    @discardableResult
    public func setArchived(
        id: WorkGroupID,
        archived: Bool,
        expectedRevision: Int? = nil,
        updatedAt: Date = Date()
    ) throws -> WorkGroup {
        try mutate(id: id, expectedRevision: expectedRevision, updatedAt: updatedAt) {
            $0.archived = archived
        }
    }

    @discardableResult
    public func setPrimary(
        id: WorkGroupID,
        primary: WorkGroupRepositoryReference,
        expectedRevision: Int? = nil,
        updatedAt: Date = Date()
    ) throws -> WorkGroup {
        guard primary.isWellFormed else { throw WorkGroupStoreError.invalidReference }
        return try mutate(id: id, expectedRevision: expectedRevision, updatedAt: updatedAt) {
            $0.primary = primary
        }
    }

    @discardableResult
    public func setOwnerReferences(
        id: WorkGroupID,
        references: [WorkGroupOwnerReference],
        expectedRevision: Int? = nil,
        updatedAt: Date = Date()
    ) throws -> WorkGroup {
        try mutate(id: id, expectedRevision: expectedRevision, updatedAt: updatedAt) {
            $0.ownerReferences = references.sorted { $0.id < $1.id }
        }
    }

    @discardableResult
    public func addMember(
        groupID: WorkGroupID,
        reference: WorkGroupMemberReference,
        role: WorkGroupMemberRole,
        expectedRevision: Int? = nil,
        addedAt: Date = Date()
    ) throws -> WorkGroup {
        guard let canonicalID = reference.canonicalID else {
            throw WorkGroupStoreError.invalidReference
        }
        return try mutate(id: groupID, expectedRevision: expectedRevision, updatedAt: addedAt) { group in
            if let index = group.members.firstIndex(where: { $0.id == canonicalID }) {
                group.members[index].role = role
            } else {
                group.members.append(.init(reference: reference, role: role, addedAt: addedAt))
            }
        }
    }

    @discardableResult
    public func removeMember(
        groupID: WorkGroupID,
        reference: WorkGroupMemberReference,
        expectedRevision: Int? = nil,
        updatedAt: Date = Date()
    ) throws -> WorkGroup {
        guard let canonicalID = reference.canonicalID else {
            throw WorkGroupStoreError.invalidReference
        }
        return try mutate(id: groupID, expectedRevision: expectedRevision, updatedAt: updatedAt) {
            $0.members.removeAll { $0.id == canonicalID }
        }
    }

    private func mutate(
        id: WorkGroupID,
        expectedRevision: Int?,
        updatedAt: Date,
        _ body: (inout WorkGroup) throws -> Void
    ) throws -> WorkGroup {
        guard id.isWellFormed, updatedAt.timeIntervalSince1970.isFinite else {
            throw WorkGroupStoreError.invalidIdentity
        }
        return try withWriteLock {
            var ledger = try load()
            guard let index = ledger.groups.firstIndex(where: { $0.id == id }) else {
                throw WorkGroupStoreError.notFound(id)
            }
            let previous = ledger.groups[index]
            if let expectedRevision, expectedRevision != previous.revision {
                throw WorkGroupStoreError.staleRevision(expected: expectedRevision, actual: previous.revision)
            }
            var result = previous
            try body(&result)
            guard result.isWellFormed else { throw WorkGroupStoreError.invalidReference }
            // Duplicate delivery must not create activity or a new revision.
            guard result != previous else { return previous }
            guard previous.revision < Int.max else { throw WorkGroupStoreError.invalidIdentity }
            result.revision = previous.revision + 1
            result.updatedAt = updatedAt
            ledger.groups[index] = result
            try save(ledger)
            return result
        }
    }

    private func validName(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard WorkGroupIdentity.isExact(normalized) else { throw WorkGroupStoreError.invalidName }
        return normalized
    }

    private func withReadLock<T>(_ body: () throws -> T) throws -> T {
        guard directory.isFileURL else { throw WorkGroupStoreError.storageUnavailable("storage must be a file URL") }
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// A shared in-process lock is required because POSIX record locks belong
    /// to the process. The stable lock file also serializes cooperating stores
    /// in different processes; the replaced ledger inode is never the lock.
    private func withWriteLock<T>(_ body: () throws -> T) throws -> T {
        try withReadLock {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
            } catch {
                throw WorkGroupStoreError.storageUnavailable(error.localizedDescription)
            }
            let descriptor = lockURL.path.withCString {
                open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
            }
            guard descriptor >= 0 else { throw storageError("open lock") }
            defer { _ = close(descriptor) }
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                  (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), status.st_nlink == 1 else {
                throw WorkGroupStoreError.storageUnavailable("lock must be a single regular file")
            }
            var lockResult: Int32
            repeat { lockResult = lockf(descriptor, F_LOCK, 0) } while lockResult != 0 && errno == EINTR
            guard lockResult == 0 else { throw storageError("lock ledger") }
            defer { _ = lockf(descriptor, F_ULOCK, 0) }
            return try body()
        }
    }

    private func load() throws -> WorkGroupLedger {
        let descriptor = ledgerURL.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else {
            if errno == ENOENT { return WorkGroupLedger() }
            throw storageError("open ledger")
        }
        defer { _ = close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), status.st_nlink == 1 else {
            throw WorkGroupStoreError.storageUnavailable("ledger must be a single regular file")
        }
        do {
            let data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readToEnd() ?? Data()
            let ledger = try JSONDecoder().decode(WorkGroupLedger.self, from: data)
            guard ledger.schemaVersion == WorkGroupLedger.currentSchemaVersion else {
                throw WorkGroupStoreError.malformedLedger("unsupported schema \(ledger.schemaVersion)")
            }
            var identities = Set<WorkGroupID>()
            for group in ledger.groups {
                guard group.isWellFormed, identities.insert(group.id).inserted else {
                    throw WorkGroupStoreError.malformedLedger("invalid or duplicate group \(group.id.rawValue)")
                }
            }
            return ledger
        } catch let error as WorkGroupStoreError {
            throw error
        } catch {
            throw WorkGroupStoreError.malformedLedger(error.localizedDescription)
        }
    }

    private func save(_ ledger: WorkGroupLedger) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(ledger)
        let temporary = directory.appendingPathComponent(".work-groups-\(UUID().uuidString.lowercased()).tmp")
        let descriptor = temporary.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        guard descriptor >= 0 else { throw storageError("create ledger successor") }
        var openDescriptor = true
        var ownsTemporary = true
        defer {
            if openDescriptor { _ = close(descriptor) }
            if ownsTemporary { temporary.path.withCString { _ = unlink($0) } }
        }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw storageError("write ledger successor") }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw storageError("flush ledger successor") }
        let closeResult = close(descriptor)
        openDescriptor = false
        guard closeResult == 0 else { throw storageError("close ledger successor") }
        let renameResult = temporary.path.withCString { source in
            ledgerURL.path.withCString { target in
                #if canImport(Darwin)
                Darwin.rename(source, target)
                #else
                Glibc.rename(source, target)
                #endif
            }
        }
        guard renameResult == 0 else { throw storageError("publish ledger successor") }
        ownsTemporary = false
    }

    private func storageError(_ operation: String) -> WorkGroupStoreError {
        .storageUnavailable("\(operation): \(String(cString: strerror(errno)))")
    }
}

public struct WorkGroupThreadObservation: Equatable, Sendable {
    public var reference: WorkGroupMemberReference
    public var displayTitle: String
    public var providerLabel: OrchestrationValue<String>
    public var configuredAgentLabel: OrchestrationValue<String>
    public var lastActivityAt: OrchestrationValue<Date>
    public var lastOperatorMessageAt: OrchestrationValue<Date>
    public var lastAgentMessageAt: OrchestrationValue<Date>
    public var unseenCount: OrchestrationValue<Int>
    public var isPinned: OrchestrationValue<Bool>
    public var manualPriority: OrchestrationValue<Int>
    public var repositoryRoot: OrchestrationValue<String>
    public var worktreePath: OrchestrationValue<String>

    public init(
        reference: WorkGroupMemberReference,
        displayTitle: String,
        providerLabel: OrchestrationValue<String> = .unknown,
        configuredAgentLabel: OrchestrationValue<String> = .unknown,
        lastActivityAt: OrchestrationValue<Date> = .unknown,
        lastOperatorMessageAt: OrchestrationValue<Date> = .unknown,
        lastAgentMessageAt: OrchestrationValue<Date> = .unknown,
        unseenCount: OrchestrationValue<Int> = .unknown,
        isPinned: OrchestrationValue<Bool> = .unknown,
        manualPriority: OrchestrationValue<Int> = .unknown,
        repositoryRoot: OrchestrationValue<String> = .unknown,
        worktreePath: OrchestrationValue<String> = .unknown
    ) {
        self.reference = reference
        self.displayTitle = displayTitle
        self.providerLabel = providerLabel
        self.configuredAgentLabel = configuredAgentLabel
        self.lastActivityAt = lastActivityAt
        self.lastOperatorMessageAt = lastOperatorMessageAt
        self.lastAgentMessageAt = lastAgentMessageAt
        self.unseenCount = unseenCount
        self.isPinned = isPinned
        self.manualPriority = manualPriority
        self.repositoryRoot = repositoryRoot
        self.worktreePath = worktreePath
    }

    /// Read the existing task projection without creating a parallel catalogue.
    /// Navigation scope and configured agent label do not prove Git execution
    /// cwd or current provider identity, and aggregate activity is not split
    /// into invented operator/agent timestamps.
    public init(task: TaskSessionSnapshot) {
        self.init(
            reference: .conduitTask(task.id),
            displayTitle: task.displayTitle,
            configuredAgentLabel: task.metadata.agentName.map(OrchestrationValue.known) ?? .unknown,
            lastActivityAt: .known(task.lastActivityAt),
            isPinned: .known(task.isPinned)
        )
    }

    public var isWellFormed: Bool {
        guard reference.isWellFormed, WorkGroupIdentity.isExact(displayTitle) else { return false }
        for value in [providerLabel, configuredAgentLabel] {
            if let known = value.value, !WorkGroupIdentity.isExact(known) { return false }
        }
        for value in [lastActivityAt, lastOperatorMessageAt, lastAgentMessageAt] {
            if let known = value.value, !known.timeIntervalSince1970.isFinite { return false }
        }
        if let known = unseenCount.value, known < 0 { return false }
        for value in [repositoryRoot, worktreePath] {
            if let known = value.value, WorkGroupIdentity.path(known) == nil { return false }
        }
        return true
    }
}

public enum WorkGroupObservationAvailability: String, Equatable, Sendable {
    case observed
    case missing
    case ambiguous
    case malformed
}

public struct WorkGroupThreadRailItem: Equatable, Sendable, Identifiable {
    public var member: WorkGroupMember
    public var observation: WorkGroupThreadObservation?
    public var availability: WorkGroupObservationAvailability

    public var id: String { member.id }
    public var displayTitle: String { observation?.displayTitle ?? member.id }

    public init(
        member: WorkGroupMember,
        observation: WorkGroupThreadObservation?,
        availability: WorkGroupObservationAvailability? = nil
    ) {
        self.member = member
        self.observation = observation
        self.availability = availability ?? (observation == nil ? .missing : .observed)
    }
}

public enum WorkGroupRailDiagnostic: Equatable, Sendable {
    case malformedGroup
    case malformedObservation(String?)
    case ambiguousObservation(String)
}

public struct WorkGroupThreadRailSnapshot: Equatable, Sendable {
    public var items: [WorkGroupThreadRailItem]
    public var diagnostics: [WorkGroupRailDiagnostic]
}

/// A transient view of existing observations, never a provider/session store.
/// Duplicate observations remain ambiguous even when their display facts agree.
public enum WorkGroupThreadRailProjection {
    public static func items(
        group: WorkGroup,
        observations: [WorkGroupThreadObservation]
    ) -> [WorkGroupThreadRailItem] {
        snapshot(group: group, observations: observations).items
    }

    public static func items(group: WorkGroup, tasks: [TaskSessionSnapshot]) -> [WorkGroupThreadRailItem] {
        items(group: group, observations: tasks.map(WorkGroupThreadObservation.init(task:)))
    }

    public static func snapshot(
        group: WorkGroup,
        observations: [WorkGroupThreadObservation]
    ) -> WorkGroupThreadRailSnapshot {
        guard group.isWellFormed else { return .init(items: [], diagnostics: [.malformedGroup]) }
        let memberIDs = Set(group.members.map(\.id))
        var byID: [String: [WorkGroupThreadObservation]] = [:]
        var diagnostics: [WorkGroupRailDiagnostic] = []
        for observation in observations {
            guard let identity = observation.reference.canonicalID else {
                diagnostics.append(.malformedObservation(nil))
                continue
            }
            guard memberIDs.contains(identity) else { continue }
            byID[identity, default: []].append(observation)
        }
        let rows = group.members.map { member -> WorkGroupThreadRailItem in
            guard let observations = byID[member.id] else {
                return .init(member: member, observation: nil, availability: .missing)
            }
            guard observations.count == 1 else {
                diagnostics.append(.ambiguousObservation(member.id))
                return .init(member: member, observation: nil, availability: .ambiguous)
            }
            guard let observation = observations.first, observation.isWellFormed else {
                diagnostics.append(.malformedObservation(member.id))
                return .init(member: member, observation: nil, availability: .malformed)
            }
            return .init(member: member, observation: observation, availability: .observed)
        }.sorted { lhs, rhs in
            switch (lhs.observation?.lastActivityAt.value, rhs.observation?.lastActivityAt.value) {
            case let (left?, right?) where left != right: return left > right
            case (nil, _?): return false
            case (_?, nil): return true
            default:
                let left = WorkGroupIdentity.sortKey(lhs.displayTitle)
                let right = WorkGroupIdentity.sortKey(rhs.displayTitle)
                if left != right { return left < right }
                return lhs.id < rhs.id
            }
        }
        return .init(items: rows, diagnostics: diagnostics)
    }
}

/// A presentation destination that grants no provider writer authority.
/// Constructing from a group captures its exact coordination revision; the
/// legacy initializer keeps an absent revision explicitly UNKNOWN.
public struct WorkGroupComposerDestination: Equatable, Sendable {
    public var groupID: WorkGroupID
    public var groupName: String
    public var groupRevision: OrchestrationValue<Int>
    public var target: WorkGroupMemberReference
    public var targetTitle: String
    public var role: OrchestrationValue<WorkGroupMemberRole>
    public var providerLabel: OrchestrationValue<String>

    public init(
        groupID: WorkGroupID,
        groupName: String,
        groupRevision: OrchestrationValue<Int> = .unknown,
        target: WorkGroupMemberReference,
        targetTitle: String,
        role: OrchestrationValue<WorkGroupMemberRole> = .unknown,
        providerLabel: OrchestrationValue<String> = .unknown
    ) {
        self.groupID = groupID
        self.groupName = groupName
        self.groupRevision = groupRevision
        self.target = target
        self.targetTitle = targetTitle
        self.role = role
        self.providerLabel = providerLabel
    }

    public init(
        group: WorkGroup,
        target: WorkGroupMemberReference,
        targetTitle: String,
        providerLabel: OrchestrationValue<String> = .unknown
    ) {
        self.init(
            groupID: group.id, groupName: group.name, groupRevision: .known(group.revision),
            target: target, targetTitle: targetTitle,
            role: group.members.first { $0.id == target.canonicalID }.map { .known($0.role) } ?? .unknown,
            providerLabel: providerLabel
        )
    }

    public var breadcrumb: String {
        let identity = target.canonicalID ?? "INVALID"
        let provider = providerLabel.value ?? (target.kind == .providerThread ? target.providerID : nil) ?? "UNKNOWN"
        return "Work Group: \(groupName) [\(groupID.rawValue)] → \(targetTitle) [\(identity)] · role: \(role.value?.rawValue ?? "UNKNOWN") · provider: \(provider)"
    }
}

public enum WorkGroupTargetWarning: Equatable, Sendable {
    case malformedGroup
    case archivedGroup
    case wrongGroup(expected: WorkGroupID, actual: WorkGroupID)
    case unknownDestinationRevision
    case staleDestination(expected: Int, actual: Int)
    case staleGroupName
    case invalidTarget
    case nonMemberTarget
    case observationTargetMismatch(expected: String, actual: String?)
    case malformedObservation
    case repositoryMismatch(expected: String, actual: String)
    case worktreeMismatch(expected: String, actual: String)

    public var message: String {
        switch self {
        case .malformedGroup: return "Work Group coordination state is malformed."
        case .archivedGroup: return "Work Group is archived."
        case .wrongGroup(let expected, let actual):
            return "Composer group \(actual.rawValue) does not match Work Group \(expected.rawValue)."
        case .unknownDestinationRevision: return "Composer Work Group revision is UNKNOWN."
        case .staleDestination(let expected, let actual):
            return "Composer Work Group revision \(expected) differs from current revision \(actual)."
        case .staleGroupName: return "Composer Work Group name is stale."
        case .invalidTarget: return "Composer target identity is malformed."
        case .nonMemberTarget: return "Target is not a member of this Work Group."
        case .observationTargetMismatch(let expected, let actual):
            return "Observation target \(actual ?? "UNKNOWN") does not match composer target \(expected)."
        case .malformedObservation: return "Target observation is malformed."
        case .repositoryMismatch(let expected, let actual):
            return "Target repository \(actual) does not match Work Group repository \(expected)."
        case .worktreeMismatch(let expected, let actual):
            return "Target worktree \(actual) does not match Work Group worktree \(expected)."
        }
    }
}

/// Deterministic presentation warnings only. The canonical provider send path
/// must still establish its own exact target and writer authority at delivery.
public enum WorkGroupTargetValidator {
    public static func warnings(
        group: WorkGroup,
        destination: WorkGroupComposerDestination,
        observation: WorkGroupThreadObservation?
    ) -> [WorkGroupTargetWarning] {
        guard group.isWellFormed else { return [.malformedGroup] }
        guard destination.groupID == group.id else {
            return [.wrongGroup(expected: group.id, actual: destination.groupID)]
        }
        var result: [WorkGroupTargetWarning] = []
        if let revision = destination.groupRevision.value {
            if revision != group.revision { result.append(.staleDestination(expected: revision, actual: group.revision)) }
        } else {
            result.append(.unknownDestinationRevision)
        }
        if destination.groupName != group.name { result.append(.staleGroupName) }
        return result + warnings(group: group, target: destination.target, observation: observation)
    }

    public static func warnings(
        group: WorkGroup,
        target: WorkGroupMemberReference,
        observation: WorkGroupThreadObservation?
    ) -> [WorkGroupTargetWarning] {
        guard group.isWellFormed else { return [.malformedGroup] }
        var result: [WorkGroupTargetWarning] = group.archived ? [.archivedGroup] : []
        guard let targetID = target.canonicalID else { return result + [.invalidTarget] }
        if !group.members.contains(where: { $0.id == targetID }) { result.append(.nonMemberTarget) }
        guard let observation else { return result }
        guard observation.reference.canonicalID == targetID else {
            return result + [.observationTargetMismatch(expected: targetID, actual: observation.reference.canonicalID)]
        }
        guard observation.isWellFormed else { return result + [.malformedObservation] }
        if let expected = group.primary.repositoryRoot.value,
           let actual = observation.repositoryRoot.value,
           WorkGroupIdentity.path(expected) != WorkGroupIdentity.path(actual) {
            result.append(.repositoryMismatch(expected: expected, actual: actual))
        }
        if let expected = group.primary.worktreePath.value,
           let actual = observation.worktreePath.value,
           WorkGroupIdentity.path(expected) != WorkGroupIdentity.path(actual) {
            result.append(.worktreeMismatch(expected: expected, actual: actual))
        }
        return result
    }
}
