import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif


public enum ExecutionWorkspaceMode: String, Codable, CaseIterable, Sendable {
    case sharedReadOnly = "shared_read_only"
    case isolatedGitWorktree = "isolated_git_worktree"
    case existingWorktree = "existing_worktree"
    case filesystemScope = "filesystem_scope"
    case none
}

public enum ExecutionWorkspaceAuthority: String, Codable, Sendable {
    case readOnly = "read_only"
    case readWrite = "read_write"
}

public enum ExecutionWorkspaceLifecycleState: String, Codable, Sendable {
    case prepared
    case allocated
    case active
    case preserved
    case released
    case missing
    case drifted
}

public enum ExecutionWorkspaceProvenance: String, Codable, Sendable {
    case humanCheckout = "human_checkout"
    case conduitAllocated = "conduit_allocated"
    case explicitlyAdopted = "explicitly_adopted"
}

public struct GitRepositoryIdentity: Codable, Equatable, Sendable {
    public var repositoryRoot: String
    public var commonGitDirectory: String

    public init(repositoryRoot: String, commonGitDirectory: String) {
        self.repositoryRoot = repositoryRoot
        self.commonGitDirectory = commonGitDirectory
    }
}

public struct ExecutionWorkspace: Identifiable, Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: String
    public var mode: ExecutionWorkspaceMode
    public var authority: ExecutionWorkspaceAuthority
    public var repository: GitRepositoryIdentity?
    public var path: String?
    public var baseRevision: String?
    public var baseSHA: String?
    public var branchRef: String?
    public var expectedHeadSHA: String?
    public var leaseID: String?
    public var lifecycle: ExecutionWorkspaceLifecycleState
    public var provenance: ExecutionWorkspaceProvenance
    public var createdAt: Date

    public init(
        schemaVersion: Int = ExecutionWorkspace.currentSchemaVersion,
        id: String = UUID().uuidString.lowercased(),
        mode: ExecutionWorkspaceMode,
        authority: ExecutionWorkspaceAuthority,
        repository: GitRepositoryIdentity?,
        path: String?,
        baseRevision: String?,
        baseSHA: String?,
        branchRef: String?,
        expectedHeadSHA: String?,
        leaseID: String? = nil,
        lifecycle: ExecutionWorkspaceLifecycleState,
        provenance: ExecutionWorkspaceProvenance,
        createdAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.mode = mode
        self.authority = authority
        self.repository = repository
        self.path = path
        self.baseRevision = baseRevision
        self.baseSHA = baseSHA
        self.branchRef = branchRef
        self.expectedHeadSHA = expectedHeadSHA
        self.leaseID = leaseID
        self.lifecycle = lifecycle
        self.provenance = provenance
        self.createdAt = createdAt
    }

    public func binding(_ lease: WorkspaceLease) -> ExecutionWorkspace {
        var copy = self
        copy.leaseID = lease.id
        copy.lifecycle = .active
        return copy
    }

    public func preservingAfterLeaseRelease() -> ExecutionWorkspace {
        var copy = self
        copy.leaseID = nil
        copy.lifecycle = .preserved
        return copy
    }
}

public enum WorkspaceLeaseStatus: String, Codable, Sendable {
    case active
    case released
}

public struct WorkspaceLease: Identifiable, Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: String
    public var workspaceID: String
    public var ownerID: String
    public var runID: String?
    public var stepID: String?
    public var workerID: String?
    public var acquiredAt: Date
    public var releasedAt: Date?
    public var status: WorkspaceLeaseStatus

    public init(
        schemaVersion: Int = WorkspaceLease.currentSchemaVersion,
        id: String = UUID().uuidString.lowercased(),
        workspaceID: String,
        ownerID: String,
        runID: String? = nil,
        stepID: String? = nil,
        workerID: String? = nil,
        acquiredAt: Date = Date(),
        releasedAt: Date? = nil,
        status: WorkspaceLeaseStatus = .active
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.workspaceID = workspaceID
        self.ownerID = ownerID
        self.runID = runID
        self.stepID = stepID
        self.workerID = workerID
        self.acquiredAt = acquiredAt
        self.releasedAt = releasedAt
        self.status = status
    }
}

public enum WorkspaceLeaseStoreError: LocalizedError, Equatable {
    case writerCollision(workspaceID: String, currentOwnerID: String)
    case ownerMismatch(workspaceID: String, currentOwnerID: String)
    case leaseMismatch(workspaceID: String, expectedLeaseID: String, actualLeaseID: String)
    case malformedLedger(String)
    case releasedLeaseUnverified(workspaceID: String)

    public var errorDescription: String? {
        switch self {
        case .writerCollision(let workspaceID, let owner):
            return "Workspace \(workspaceID) already has writer \(owner)."
        case .ownerMismatch(let workspaceID, let owner):
            return "Workspace \(workspaceID) writer is \(owner); release refused."
        case .leaseMismatch(let workspaceID, let expected, let actual):
            return "Workspace \(workspaceID) lease \(actual) does not match expected \(expected)."
        case .malformedLedger(let detail):
            return "Workspace lease ledger is malformed: \(detail)"
        case .releasedLeaseUnverified(let workspaceID):
            return "Workspace \(workspaceID) has no matching recorded lease release; cleanup refused."
        }
    }
}

private struct WorkspaceLeaseLedger: Codable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = WorkspaceLeaseLedger.currentSchemaVersion
    var activeByWorkspace: [String: WorkspaceLease] = [:]
    var history: [WorkspaceLease] = []
}

private final class WorkspaceLeaseProcessLockRegistry: @unchecked Sendable {
    static let shared = WorkspaceLeaseProcessLockRegistry()

    private let registryLock = NSLock()
    private var locksByPath: [String: NSLock] = [:]

    private init() {}

    func lock(for lockURL: URL) -> NSLock {
        let parent = lockURL.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let key = parent
            .appendingPathComponent(lockURL.lastPathComponent)
            .standardizedFileURL
            .path

        registryLock.lock()
        defer { registryLock.unlock() }

        if let existing = locksByPath[key] {
            return existing
        }

        let created = NSLock()
        locksByPath[key] = created
        return created
    }
}

public final class WorkspaceLeaseStore: @unchecked Sendable {
    public let directory: URL
    public let ledgerURL: URL

    private let fileManager: FileManager
    private let lock = NSLock()
    private let lockURL: URL

    public init(directory: URL, fileManager: FileManager = .default) {
        let normalized = directory.standardizedFileURL
        self.directory = normalized
        self.ledgerURL = normalized.appendingPathComponent("workspace-leases-v1.json")
        self.lockURL = normalized.appendingPathComponent("workspace-leases-v1.lock")
        self.fileManager = fileManager
    }

    public func activeLease(workspaceID: String) throws -> WorkspaceLease? {
        try withLock {
            try load().activeByWorkspace[workspaceID]
        }
    }

    @discardableResult
    public func acquire(
        workspaceID: String,
        ownerID: String,
        runID: String? = nil,
        stepID: String? = nil,
        workerID: String? = nil,
        acquiredAt: Date = Date()
    ) throws -> WorkspaceLease {
        try withLock {
            var ledger = try load()
            if let current = ledger.activeByWorkspace[workspaceID] {
                if current.ownerID == ownerID {
                    return current
                }
                throw WorkspaceLeaseStoreError.writerCollision(
                    workspaceID: workspaceID,
                    currentOwnerID: current.ownerID
                )
            }

            let lease = WorkspaceLease(
                workspaceID: workspaceID,
                ownerID: ownerID,
                runID: runID,
                stepID: stepID,
                workerID: workerID,
                acquiredAt: acquiredAt
            )
            ledger.activeByWorkspace[workspaceID] = lease
            try save(ledger)
            return lease
        }
    }

    @discardableResult
    public func release(
        workspaceID: String,
        ownerID: String,
        expectedLeaseID: String? = nil,
        releasedAt: Date = Date()
    ) throws -> WorkspaceLease? {
        try withLock {
            var ledger = try load()
            guard var current = ledger.activeByWorkspace[workspaceID] else {
                return nil
            }
            guard current.ownerID == ownerID else {
                throw WorkspaceLeaseStoreError.ownerMismatch(
                    workspaceID: workspaceID,
                    currentOwnerID: current.ownerID
                )
            }
            if let expectedLeaseID, current.id != expectedLeaseID {
                throw WorkspaceLeaseStoreError.leaseMismatch(
                    workspaceID: workspaceID,
                    expectedLeaseID: expectedLeaseID,
                    actualLeaseID: current.id
                )
            }

            current.status = .released
            current.releasedAt = releasedAt
            ledger.activeByWorkspace.removeValue(forKey: workspaceID)
            ledger.history.append(current)
            try save(ledger)
            return current
        }
    }

    public func history() throws -> [WorkspaceLease] {
        try withLock { try load().history }
    }

    /// Keep the same cross-process writer lock held through cleanup. A new
    /// Conduit writer cannot acquire authority between preflight and removal.
    fileprivate func withReleasedLease<T>(
        workspaceID: String,
        releasedLeaseID: String,
        ownerID: String,
        _ body: () throws -> T
    ) throws -> T {
        try withLock {
            let ledger = try load()
            if let active = ledger.activeByWorkspace[workspaceID] {
                throw WorkspaceLeaseStoreError.writerCollision(
                    workspaceID: workspaceID,
                    currentOwnerID: active.ownerID
                )
            }
            guard let last = ledger.history.last(where: { $0.workspaceID == workspaceID }),
                  last.schemaVersion == WorkspaceLease.currentSchemaVersion,
                  last.id == releasedLeaseID,
                  last.ownerID == ownerID,
                  last.status == .released,
                  last.releasedAt != nil else {
                throw WorkspaceLeaseStoreError.releasedLeaseUnverified(workspaceID: workspaceID)
            }
            return try body()
        }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }

        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        // POSIX record locks are process-scoped. Serialize all stores in this
        // process on the stable lock-file identity before taking the
        // inter-process advisory lock below.
        let processLock = WorkspaceLeaseProcessLockRegistry.shared.lock(for: lockURL)
        processLock.lock()
        defer { processLock.unlock() }

        let descriptor = lockURL.path.withCString { path -> Int32 in
            #if canImport(Darwin)
            return Darwin.open(path, O_RDWR | O_CREAT, mode_t(0o600))
            #elseif canImport(Glibc)
            return Glibc.open(path, O_RDWR | O_CREAT, mode_t(0o600))
            #else
            return -1
            #endif
        }
        guard descriptor >= 0 else {
            throw WorkspaceLeaseStoreError.malformedLedger(
                "could not open cross-process lease lock at \(lockURL.path)"
            )
        }
        defer {
            #if canImport(Darwin) || canImport(Glibc)
            _ = lockf(descriptor, F_ULOCK, 0)
            #endif
            #if canImport(Darwin)
            _ = Darwin.close(descriptor)
            #elseif canImport(Glibc)
            _ = Glibc.close(descriptor)
            #endif
        }

        #if canImport(Darwin) || canImport(Glibc)
        // flock collides with Darwin's imported struct flock in Swift.
        // lockf provides the needed blocking cross-process advisory lock on
        // this stable, dedicated lock file without changing ledger semantics.
        let lockStatus = lockf(descriptor, F_LOCK, 0)
        #else
        let lockStatus: Int32 = -1
        #endif
        guard lockStatus == 0 else {
            throw WorkspaceLeaseStoreError.malformedLedger(
                "could not acquire cross-process lease lock at \(lockURL.path)"
            )
        }

        return try body()
    }

    private func load() throws -> WorkspaceLeaseLedger {
        guard fileManager.fileExists(atPath: ledgerURL.path) else {
            return WorkspaceLeaseLedger()
        }
        do {
            let data = try Data(contentsOf: ledgerURL)
            let ledger = try JSONDecoder().decode(WorkspaceLeaseLedger.self, from: data)
            guard ledger.schemaVersion == WorkspaceLeaseLedger.currentSchemaVersion else {
                throw WorkspaceLeaseStoreError.malformedLedger(
                    "unsupported schema \(ledger.schemaVersion)"
                )
            }
            return ledger
        } catch let error as WorkspaceLeaseStoreError {
            throw error
        } catch {
            throw WorkspaceLeaseStoreError.malformedLedger(error.localizedDescription)
        }
    }

    private func save(_ ledger: WorkspaceLeaseLedger) throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(ledger)
        try data.write(to: ledgerURL, options: .atomic)
    }
}

enum ExecutionWorkspacePathIdentity {
    static func canonicalPath(
        _ url: URL,
        fileManager: FileManager = .default
    ) -> String {
        let standardized = url.standardizedFileURL
        if fileManager.fileExists(atPath: standardized.path) {
            return standardized
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
        }

        let parent = standardized.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
        return parent
            .appendingPathComponent(
                standardized.lastPathComponent,
                isDirectory: url.hasDirectoryPath
            )
            .standardizedFileURL
            .path
    }

    static func canonicalPath(
        _ path: String,
        fileManager: FileManager = .default
    ) -> String {
        canonicalPath(
            URL(fileURLWithPath: path),
            fileManager: fileManager
        )
    }
}

public struct GitWorktreeRecord: Codable, Equatable, Sendable {
    public var path: String
    public var headSHA: String
    public var branchRef: String?
    public var isDetached: Bool
    public var isBare: Bool
    public var isLocked: Bool
    public var isPrunable: Bool

    public init(
        path: String,
        headSHA: String,
        branchRef: String?,
        isDetached: Bool,
        isBare: Bool,
        isLocked: Bool,
        isPrunable: Bool
    ) {
        self.path = path
        self.headSHA = headSHA
        self.branchRef = branchRef
        self.isDetached = isDetached
        self.isBare = isBare
        self.isLocked = isLocked
        self.isPrunable = isPrunable
    }

    public var branchName: String? {
        guard let branchRef else { return nil }
        let prefix = "refs/heads/"
        return branchRef.hasPrefix(prefix)
            ? String(branchRef.dropFirst(prefix.count))
            : branchRef
    }

    static func parsePorcelain(_ text: String) -> [GitWorktreeRecord] {
        let blocks = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return blocks.compactMap { block in
            var path: String?
            var head = ""
            var branch: String?
            var detached = false
            var bare = false
            var locked = false
            var prunable = false

            for line in block.split(separator: "\n", omittingEmptySubsequences: true) {
                let value = String(line)
                if value.hasPrefix("worktree ") {
                    path = String(value.dropFirst("worktree ".count))
                } else if value.hasPrefix("HEAD ") {
                    head = String(value.dropFirst("HEAD ".count))
                } else if value.hasPrefix("branch ") {
                    branch = String(value.dropFirst("branch ".count))
                } else if value == "detached" {
                    detached = true
                } else if value == "bare" {
                    bare = true
                } else if value.hasPrefix("locked") {
                    locked = true
                } else if value.hasPrefix("prunable") {
                    prunable = true
                }
            }

            guard let path, !head.isEmpty else { return nil }
            return GitWorktreeRecord(
                path: URL(fileURLWithPath: path)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                    .path,
                headSHA: head,
                branchRef: branch,
                isDetached: detached,
                isBare: bare,
                isLocked: locked,
                isPrunable: prunable
            )
        }
    }

    static func parsePorcelainZ(_ data: Data) throws -> [GitWorktreeRecord] {
        guard let text = String(data: data, encoding: .utf8), text.hasSuffix("\0\0") else {
            throw GitExecutionWorkspaceControllerError.invalidObservation("Incomplete or non-UTF-8 worktree listing.")
        }
        return try text.components(separatedBy: "\0\0")
            .filter { !$0.isEmpty }
            .map { block in
                var path: String?
                var head: String?
                var branch: String?
                var detached = false
                var bare = false
                var locked = false
                var prunable = false
                for field in block.components(separatedBy: "\0") {
                    if field.hasPrefix("worktree ") {
                        path = String(field.dropFirst("worktree ".count))
                    } else if field.hasPrefix("HEAD ") {
                        head = String(field.dropFirst("HEAD ".count))
                    } else if field.hasPrefix("branch ") {
                        branch = String(field.dropFirst("branch ".count))
                    } else if field == "detached" { detached = true
                    } else if field == "bare" { bare = true
                    } else if field == "locked" || field.hasPrefix("locked ") { locked = true
                    } else if field == "prunable" || field.hasPrefix("prunable ") { prunable = true }
                }
                guard let path, path.hasPrefix("/"), let head,
                      [40, 64].contains(head.count), head.allSatisfy({ $0.isHexDigit }),
                      branch != nil || detached || bare else {
                    throw GitExecutionWorkspaceControllerError.invalidObservation("Missing worktree path, HEAD, or ref identity.")
                }
                return GitWorktreeRecord(
                    path: ExecutionWorkspacePathIdentity.canonicalPath(path),
                    headSHA: head, branchRef: branch, isDetached: detached,
                    isBare: bare, isLocked: locked, isPrunable: prunable
                )
            }
    }
}

public struct ExecutionWorkspaceAllocationPlan: Codable, Equatable, Sendable {
    public var workspaceID: String
    public var repository: GitRepositoryIdentity
    public var workspacePath: String
    public var baseRevision: String
    public var baseSHA: String
    public var branchName: String
    public var preparedAt: Date

    public init(
        workspaceID: String,
        repository: GitRepositoryIdentity,
        workspacePath: String,
        baseRevision: String,
        baseSHA: String,
        branchName: String,
        preparedAt: Date
    ) {
        self.workspaceID = workspaceID
        self.repository = repository
        self.workspacePath = workspacePath
        self.baseRevision = baseRevision
        self.baseSHA = baseSHA
        self.branchName = branchName
        self.preparedAt = preparedAt
    }
}

public enum WorkspaceAllocationWarning: Equatable, Sendable {
    case baseRevisionMoved(revision: String, preparedSHA: String, currentSHA: String)

    public var message: String {
        switch self {
        case .baseRevisionMoved(let revision, let prepared, let current):
            return "Base ref \(revision) moved from \(prepared) to \(current); allocated the prepared exact SHA."
        }
    }
}

public struct ExecutionWorkspaceAllocationReceipt: Equatable, Sendable {
    public var workspace: ExecutionWorkspace
    public var worktree: GitWorktreeRecord
    public var warnings: [WorkspaceAllocationWarning]

    public init(
        workspace: ExecutionWorkspace,
        worktree: GitWorktreeRecord,
        warnings: [WorkspaceAllocationWarning]
    ) {
        self.workspace = workspace
        self.worktree = worktree
        self.warnings = warnings
    }
}

public enum ExecutionWorkspaceDisposition: String, Codable, Sendable {
    case ready = "WORKSPACE_READY"
    case dirty = "WORKSPACE_DIRTY"
    case drifted = "WORKSPACE_DRIFTED"
    case writerCollision = "WRITER_COLLISION"
    case missing = "WORKTREE_MISSING"
    case preservationRequired = "WORKSPACE_PRESERVATION_REQUIRED"
    case unknown = "UNKNOWN"
}

public enum ExecutionWorkspaceReconciliationIssue: Equatable, Sendable {
    case worktreeMissing(path: String)
    case repositoryIdentityMismatch(expected: String, actual: String)
    case branchDrift(expected: String, actual: String?)
    case headDrift(expected: String, actual: String)
    case dirtyWorkspace(paths: [String])
    case writerLeaseMissing(expectedLeaseID: String)
    case writerCollision(expectedLeaseID: String, actualLeaseID: String, actualOwnerID: String)
    case cwdMismatch(expected: String, actual: String)
    case baseRevisionMoved(revision: String, preparedSHA: String, currentSHA: String)
    case inspectionFailed(String)

    public var message: String {
        switch self {
        case .worktreeMissing(let path):
            return "Registered execution worktree is missing: \(path)"
        case .repositoryIdentityMismatch(let expected, let actual):
            return "Repository identity drifted: expected \(expected), observed \(actual)."
        case .branchDrift(let expected, let actual):
            return "Branch/ref drifted: expected \(expected), observed \(actual ?? "detached/unknown")."
        case .headDrift(let expected, let actual):
            return "HEAD drifted: expected \(expected), observed \(actual)."
        case .dirtyWorkspace(let paths):
            return "Workspace has uncommitted/untracked state: \(paths.joined(separator: ", "))."
        case .writerLeaseMissing(let expected):
            return "Expected writer lease \(expected) is no longer active."
        case .writerCollision(_, let actual, let owner):
            return "Writer lease collision: active lease \(actual) belongs to \(owner)."
        case .cwdMismatch(let expected, let actual):
            return "Worker cwd mismatch: expected \(expected), observed \(actual)."
        case .baseRevisionMoved(let revision, let prepared, let current):
            return "Base ref \(revision) moved from \(prepared) to \(current); workspace remains pinned to the prepared SHA."
        case .inspectionFailed(let detail):
            return "Workspace inspection failed closed: \(detail)"
        }
    }
}

public struct ExecutionWorkspaceReconciliation: Equatable, Sendable {
    public var disposition: ExecutionWorkspaceDisposition
    public var worktree: GitWorktreeRecord?
    public var activeLease: WorkspaceLease?
    public var issues: [ExecutionWorkspaceReconciliationIssue]

    public init(
        disposition: ExecutionWorkspaceDisposition,
        worktree: GitWorktreeRecord?,
        activeLease: WorkspaceLease?,
        issues: [ExecutionWorkspaceReconciliationIssue]
    ) {
        self.disposition = disposition
        self.worktree = worktree
        self.activeLease = activeLease
        self.issues = issues
    }
}

public enum GitExecutionWorkspaceControllerError: LocalizedError, Equatable {
    case commandFailed(arguments: [String], status: Int32, stderr: String)
    case timedOut(arguments: [String])
    case invalidBranch(String)
    case branchAlreadyExists(String)
    case workspacePathExists(String)
    case workspaceAlreadyRegistered(String)
    case repositoryIdentityChanged
    case humanCheckoutChanged
    case allocationNotRegistered(String)
    case outputTruncated(arguments: [String])
    case invalidObservation(String)
    case cleanupRefused(String)
    case cleanupVerificationFailed(String)
    case allocationReceiptFailed(path: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let arguments, let status, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "git \(arguments.joined(separator: " ")) failed with status \(status)\(detail.isEmpty ? "" : ": \(detail)")"
        case .timedOut(let arguments):
            return "git \(arguments.joined(separator: " ")) exceeded the workspace timeout."
        case .invalidBranch(let branch):
            return "Invalid task branch/ref: \(branch)"
        case .branchAlreadyExists(let branch):
            return "Task branch already exists: \(branch)"
        case .workspacePathExists(let path):
            return "Workspace path already exists: \(path)"
        case .workspaceAlreadyRegistered(let path):
            return "Workspace path is already registered as a Git worktree: \(path)"
        case .repositoryIdentityChanged:
            return "Repository identity changed between workspace preparation and allocation."
        case .humanCheckoutChanged:
            return "The ordinary human checkout changed during allocation; the new worktree was preserved for inspection."
        case .allocationNotRegistered(let path):
            return "Git did not report the allocated worktree at \(path)."
        case .outputTruncated(let arguments):
            return "git \(arguments.joined(separator: " ")) exceeded the observation bound; state is UNKNOWN."
        case .invalidObservation(let detail):
            return "Git observation is UNKNOWN: \(detail)"
        case .cleanupRefused(let detail):
            return "Workspace cleanup refused: \(detail)"
        case .cleanupVerificationFailed(let detail):
            return "Cleanup outcome is UNKNOWN; inspect the exact target and preserved receipts: \(detail)"
        case .allocationReceiptFailed(let path, let detail):
            return "Allocated worktree \(path) was preserved because its ownership receipt failed: \(detail)"
        }
    }
}

public enum ExecutionWorkspaceCleanupDisposition: String, Codable, Sendable {
    case prepared
    case removed
    case unknown
}

public struct ExecutionWorkspaceCleanupReceipt: Codable, Equatable, Sendable {
    public var attemptID: String
    public var disposition: ExecutionWorkspaceCleanupDisposition
    public var workspaceID: String
    public var repository: GitRepositoryIdentity
    public var baseSHA: String
    public var removedWorktreePath: String
    public var retainedBranchRef: String
    public var retainedHeadSHA: String
    public var releasedLeaseID: String
    public var ownerID: String
    public var requestedAt: Date
    public var completedAt: Date?
    public var detail: String?
}

public struct GitExecutionWorkspaceController: @unchecked Sendable {
    private let fileManager: FileManager
    private let timeout: TimeInterval
    private let maximumOutputBytes: Int

    public init(
        fileManager: FileManager = .default,
        timeout: TimeInterval = 10,
        maximumOutputBytes: Int = 512_000
    ) {
        self.fileManager = fileManager
        self.timeout = max(0.1, timeout)
        self.maximumOutputBytes = max(4_096, maximumOutputBytes)
    }

    public func repositoryIdentity(startingAt location: URL) throws -> GitRepositoryIdentity {
        let snapshot = try GitWorkspaceInspector(
            fileManager: fileManager,
            timeout: timeout,
            maximumOutputBytes: maximumOutputBytes
        ).snapshot(startingAt: location)
        let root = URL(fileURLWithPath: snapshot.repositoryRoot, isDirectory: true)
        let args = ["rev-parse", "--git-common-dir"]
        let raw = try successful(run(in: root, arguments: args), arguments: args)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let commonURL = raw.hasPrefix("/")
            ? URL(fileURLWithPath: raw, isDirectory: true)
            : root.appendingPathComponent(raw, isDirectory: true)
        return GitRepositoryIdentity(
            repositoryRoot: ExecutionWorkspacePathIdentity.canonicalPath(
                root,
                fileManager: fileManager
            ),
            commonGitDirectory: commonURL
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
        )
    }

    public func discoverWorktrees(repositoryRoot: URL) throws -> [GitWorktreeRecord] {
        let identity = try repositoryIdentity(startingAt: repositoryRoot)
        let root = URL(fileURLWithPath: identity.repositoryRoot, isDirectory: true)
        let args = ["worktree", "list", "--porcelain", "-z"]
        let result = try successful(run(in: root, arguments: args), arguments: args)
        return try GitWorktreeRecord.parsePorcelainZ(result.stdoutData)
    }

    public func makeSharedReadOnlyWorkspace(repositoryRoot: URL) throws -> ExecutionWorkspace {
        let inspector = GitWorkspaceInspector(
            fileManager: fileManager,
            timeout: timeout,
            maximumOutputBytes: maximumOutputBytes
        )
        let snapshot = try inspector.snapshot(startingAt: repositoryRoot)
        let identity = try repositoryIdentity(startingAt: repositoryRoot)
        return ExecutionWorkspace(
            mode: .sharedReadOnly,
            authority: .readOnly,
            repository: identity,
            path: snapshot.repositoryRoot,
            baseRevision: snapshot.branch,
            baseSHA: snapshot.headSHA,
            branchRef: snapshot.branch.map { "refs/heads/\($0)" },
            expectedHeadSHA: snapshot.headSHA,
            lifecycle: .active,
            provenance: .humanCheckout
        )
    }

    public func prepareAllocation(
        repositoryRoot: URL,
        workspaceRoot: URL,
        branchName: String,
        baseRevision: String,
        preparedAt: Date = Date()
    ) throws -> ExecutionWorkspaceAllocationPlan {
        let trimmedBranch = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBase = baseRevision.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBranch.isEmpty else {
            throw GitExecutionWorkspaceControllerError.invalidBranch(branchName)
        }
        let identity = try repositoryIdentity(startingAt: repositoryRoot)
        let root = URL(fileURLWithPath: identity.repositoryRoot, isDirectory: true)

        let branchCheck = run(in: root, arguments: ["check-ref-format", "--branch", trimmedBranch])
        guard branchCheck.status == 0 else {
            throw GitExecutionWorkspaceControllerError.invalidBranch(trimmedBranch)
        }

        let baseArgs = ["rev-parse", "\(trimmedBase)^{commit}"]
        let baseSHA = try successful(run(in: root, arguments: baseArgs), arguments: baseArgs)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        let workspaceID = UUID().uuidString.lowercased()
        let repoName = root.lastPathComponent.isEmpty ? "repo" : root.lastPathComponent
        let suffix = String(workspaceID.prefix(8))
        let canonicalWorkspaceRoot = URL(
            fileURLWithPath: ExecutionWorkspacePathIdentity.canonicalPath(
                workspaceRoot,
                fileManager: fileManager
            ),
            isDirectory: true
        )
        let path = canonicalWorkspaceRoot
            .appendingPathComponent("\(repoName)-\(suffix)", isDirectory: true)
            .path

        return ExecutionWorkspaceAllocationPlan(
            workspaceID: workspaceID,
            repository: identity,
            workspacePath: path,
            baseRevision: trimmedBase,
            baseSHA: baseSHA,
            branchName: trimmedBranch,
            preparedAt: preparedAt
        )
    }

    public func allocate(
        _ plan: ExecutionWorkspaceAllocationPlan,
        allocatedAt: Date = Date()
    ) throws -> ExecutionWorkspaceAllocationReceipt {
        let root = URL(fileURLWithPath: plan.repository.repositoryRoot, isDirectory: true)
        let currentIdentity = try repositoryIdentity(startingAt: root)
        guard currentIdentity.commonGitDirectory == plan.repository.commonGitDirectory else {
            throw GitExecutionWorkspaceControllerError.repositoryIdentityChanged
        }

        let workspaceURL = URL(
            fileURLWithPath: ExecutionWorkspacePathIdentity.canonicalPath(
                plan.workspacePath,
                fileManager: fileManager
            ),
            isDirectory: true
        )
        if fileManager.fileExists(atPath: workspaceURL.path) {
            throw GitExecutionWorkspaceControllerError.workspacePathExists(workspaceURL.path)
        }
        if try discoverWorktrees(repositoryRoot: root).contains(where: {
            ExecutionWorkspacePathIdentity.canonicalPath(
                $0.path,
                fileManager: fileManager
            ) == workspaceURL.path
        }) {
            throw GitExecutionWorkspaceControllerError.workspaceAlreadyRegistered(workspaceURL.path)
        }

        let branchRef = "refs/heads/\(plan.branchName)"
        let branchResult = run(
            in: root,
            arguments: ["show-ref", "--verify", "--quiet", branchRef]
        )
        if branchResult.status == 0 {
            throw GitExecutionWorkspaceControllerError.branchAlreadyExists(plan.branchName)
        } else if branchResult.status != 1 {
            throw GitExecutionWorkspaceControllerError.commandFailed(
                arguments: ["show-ref", "--verify", "--quiet", branchRef],
                status: branchResult.status,
                stderr: branchResult.stderr
            )
        }

        let exactArgs = ["rev-parse", "\(plan.baseSHA)^{commit}"]
        let exact = try successful(run(in: root, arguments: exactArgs), arguments: exactArgs)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard exact == plan.baseSHA else {
            throw GitExecutionWorkspaceControllerError.commandFailed(
                arguments: exactArgs,
                status: 2,
                stderr: "Prepared base SHA no longer resolves to the same commit."
            )
        }

        var warnings: [WorkspaceAllocationWarning] = []
        let movingArgs = ["rev-parse", "\(plan.baseRevision)^{commit}"]
        if let currentBase = try? successful(
            run(in: root, arguments: movingArgs),
            arguments: movingArgs
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines),
           currentBase != plan.baseSHA {
            warnings.append(
                .baseRevisionMoved(
                    revision: plan.baseRevision,
                    preparedSHA: plan.baseSHA,
                    currentSHA: currentBase
                )
            )
        }

        let inspector = GitWorkspaceInspector(
            fileManager: fileManager,
            timeout: timeout,
            maximumOutputBytes: maximumOutputBytes
        )
        let humanBefore = try inspector.snapshot(startingAt: root)

        try fileManager.createDirectory(
            at: workspaceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let addArgs = [
            "worktree", "add",
            "-b", plan.branchName,
            workspaceURL.path,
            plan.baseSHA,
        ]
        _ = try successful(run(in: root, arguments: addArgs), arguments: addArgs)

        let humanAfter = try inspector.snapshot(startingAt: root)
        guard humanAfter == humanBefore else {
            throw GitExecutionWorkspaceControllerError.humanCheckoutChanged
        }

        let records = try discoverWorktrees(repositoryRoot: root)
        guard let record = records.first(where: {
            ExecutionWorkspacePathIdentity.canonicalPath(
                $0.path,
                fileManager: fileManager
            ) == workspaceURL.path
        }) else {
            throw GitExecutionWorkspaceControllerError.allocationNotRegistered(workspaceURL.path)
        }
        let allocatedIdentity = try repositoryIdentity(startingAt: workspaceURL)
        guard allocatedIdentity.commonGitDirectory == plan.repository.commonGitDirectory else {
            throw GitExecutionWorkspaceControllerError.repositoryIdentityChanged
        }

        let workspace = ExecutionWorkspace(
            id: plan.workspaceID,
            mode: .isolatedGitWorktree,
            authority: .readWrite,
            repository: plan.repository,
            path: workspaceURL.path,
            baseRevision: plan.baseRevision,
            baseSHA: plan.baseSHA,
            branchRef: record.branchRef,
            expectedHeadSHA: record.headSHA,
            lifecycle: .allocated,
            provenance: .conduitAllocated,
            createdAt: allocatedAt
        )
        do {
            let marker = try allocationMarkerURL(in: workspaceURL)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(workspace).write(to: marker, options: .atomic)
        } catch {
            throw GitExecutionWorkspaceControllerError.allocationReceiptFailed(
                path: workspaceURL.path,
                detail: error.localizedDescription
            )
        }
        return ExecutionWorkspaceAllocationReceipt(
            workspace: workspace,
            worktree: record,
            warnings: warnings
        )
    }

    /// Explicit removal of a preserved, Conduit-allocated, unchanged worktree.
    /// The branch and all commits are retained. This never forces removal or
    /// performs merge, reset, clean, branch deletion, or cleanup of an adopted
    /// worktree. Git's own non-forced remove remains the final dirty-state gate.
    public func cleanupPreservedWorkspace(
        _ workspace: ExecutionWorkspace,
        leaseStore: WorkspaceLeaseStore,
        releasedLeaseID: String,
        ownerID: String,
        requestedAt: Date = Date()
    ) throws -> ExecutionWorkspaceCleanupReceipt {
        guard workspace.schemaVersion == ExecutionWorkspace.currentSchemaVersion,
              workspace.mode == .isolatedGitWorktree,
              workspace.authority == .readWrite,
              workspace.provenance == .conduitAllocated,
              workspace.lifecycle == .preserved,
              workspace.leaseID == nil,
              let path = workspace.path, let repository = workspace.repository,
              let branch = workspace.branchRef, branch.hasPrefix("refs/heads/"),
              let expectedHead = workspace.expectedHeadSHA,
              workspace.baseSHA != nil else {
            throw GitExecutionWorkspaceControllerError.cleanupRefused("Exact preserved allocation identity is required.")
        }
        let canonicalPath = ExecutionWorkspacePathIdentity.canonicalPath(path)
        guard canonicalPath != ExecutionWorkspacePathIdentity.canonicalPath(repository.repositoryRoot) else {
            throw GitExecutionWorkspaceControllerError.cleanupRefused("The ordinary checkout is protected.")
        }
        return try leaseStore.withReleasedLease(
            workspaceID: workspace.id, releasedLeaseID: releasedLeaseID, ownerID: ownerID
        ) {
            // No nested lease-store read while holding its transaction lock.
            let reconciliation = reconcile(workspace)
            guard reconciliation.disposition == .ready,
                  let observed = reconciliation.worktree,
                  !observed.isLocked, !observed.isPrunable else {
                throw GitExecutionWorkspaceControllerError.cleanupRefused(
                    "Live workspace is \(reconciliation.disposition.rawValue), locked, or prunable."
                )
            }
            let directory = URL(fileURLWithPath: canonicalPath, isDirectory: true)
            let marker = try JSONDecoder().decode(
                ExecutionWorkspace.self,
                from: Data(contentsOf: allocationMarkerURL(in: directory))
            )
            guard marker.schemaVersion == ExecutionWorkspace.currentSchemaVersion,
                  marker.id == workspace.id,
                  marker.mode == .isolatedGitWorktree,
                  marker.authority == .readWrite,
                  marker.provenance == .conduitAllocated,
                  marker.repository == repository,
                  marker.path.map({ ExecutionWorkspacePathIdentity.canonicalPath($0) }) == canonicalPath,
                  marker.branchRef == branch,
                  marker.baseSHA == workspace.baseSHA,
                  marker.expectedHeadSHA == expectedHead else {
                throw GitExecutionWorkspaceControllerError.cleanupRefused("Recorded allocation provenance does not match.")
            }
            let statusArgs = ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored"]
            guard try successful(run(in: directory, arguments: statusArgs), arguments: statusArgs)
                .stdoutData.isEmpty else {
                throw GitExecutionWorkspaceControllerError.cleanupRefused("Tracked, untracked, or ignored files require preservation.")
            }
            let root = URL(fileURLWithPath: repository.repositoryRoot, isDirectory: true)
            let inspector = GitWorkspaceInspector(fileManager: fileManager, timeout: timeout, maximumOutputBytes: maximumOutputBytes)
            let humanBefore = try inspector.snapshot(startingAt: root)
            let journal = leaseStore.directory.appendingPathComponent("cleanup-receipts", isDirectory: true)
            var receipt = ExecutionWorkspaceCleanupReceipt(
                attemptID: UUID().uuidString.lowercased(), disposition: .prepared,
                workspaceID: workspace.id, repository: repository,
                baseSHA: workspace.baseSHA!, removedWorktreePath: canonicalPath,
                retainedBranchRef: branch, retainedHeadSHA: expectedHead,
                releasedLeaseID: releasedLeaseID, ownerID: ownerID,
                requestedAt: requestedAt, completedAt: nil, detail: nil
            )
            // A durable prepared receipt is mandatory before any removal. The
            // distinct result file preserves the prepared bytes and lineage.
            try saveCleanupReceipt(receipt, in: journal)
            let removeArgs = ["worktree", "remove", "--", canonicalPath]
            do {
                _ = try successful(run(in: root, arguments: removeArgs), arguments: removeArgs)
                let remaining = try discoverWorktrees(repositoryRoot: root)
                let branchArgs = ["rev-parse", "--verify", "\(branch)^{commit}"]
                let retainedHead = try successful(run(in: root, arguments: branchArgs), arguments: branchArgs)
                    .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !fileManager.fileExists(atPath: canonicalPath),
                      !remaining.contains(where: { $0.path == canonicalPath }),
                      retainedHead == expectedHead,
                      try inspector.snapshot(startingAt: root) == humanBefore else {
                    throw GitExecutionWorkspaceControllerError.invalidObservation("Post-removal identity or ordinary checkout changed.")
                }
                receipt.disposition = .removed
                receipt.completedAt = Date()
                try saveCleanupReceipt(receipt, in: journal)
            } catch {
                receipt.disposition = .unknown
                receipt.detail = error.localizedDescription
                // If even the result cannot be saved, the original prepared
                // receipt still records the exact unresolved attempt.
                try? saveCleanupReceipt(receipt, in: journal)
                throw GitExecutionWorkspaceControllerError.cleanupVerificationFailed(error.localizedDescription)
            }
            return receipt
        }
    }

    private func saveCleanupReceipt(_ receipt: ExecutionWorkspaceCleanupReceipt, in directory: URL) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(receipt.attemptID)-\(receipt.disposition.rawValue).json")
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw GitExecutionWorkspaceControllerError.cleanupRefused("Cleanup receipt already exists; preserved without overwrite.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(receipt).write(to: destination, options: .atomic)
    }

    private func allocationMarkerURL(in directory: URL) throws -> URL {
        let args = ["rev-parse", "--absolute-git-dir"]
        let path = try successful(run(in: directory, arguments: args), arguments: args)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else {
            throw GitExecutionWorkspaceControllerError.invalidObservation("Worktree Git directory is not absolute.")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
            .appendingPathComponent("conduit-workspace-allocation-v1.json")
    }

    public func reconcile(
        _ workspace: ExecutionWorkspace,
        leaseStore: WorkspaceLeaseStore? = nil,
        observedWorkerCWD: String? = nil
    ) -> ExecutionWorkspaceReconciliation {
        guard let path = workspace.path, let repository = workspace.repository else {
            return ExecutionWorkspaceReconciliation(
                disposition: .unknown,
                worktree: nil,
                activeLease: nil,
                issues: [.inspectionFailed("Workspace path or repository identity is UNKNOWN.")]
            )
        }

        let workspacePath = ExecutionWorkspacePathIdentity.canonicalPath(
            path,
            fileManager: fileManager
        )
        guard fileManager.fileExists(atPath: workspacePath) else {
            return ExecutionWorkspaceReconciliation(
                disposition: .missing,
                worktree: nil,
                activeLease: try? leaseStore?.activeLease(workspaceID: workspace.id),
                issues: [.worktreeMissing(path: workspacePath)]
            )
        }

        do {
            let root = URL(fileURLWithPath: repository.repositoryRoot, isDirectory: true)
            let records = try discoverWorktrees(repositoryRoot: root)
            guard let worktree = records.first(where: {
                ExecutionWorkspacePathIdentity.canonicalPath(
                    $0.path,
                    fileManager: fileManager
                ) == workspacePath
            }) else {
                return ExecutionWorkspaceReconciliation(
                    disposition: .missing,
                    worktree: nil,
                    activeLease: try? leaseStore?.activeLease(workspaceID: workspace.id),
                    issues: [.worktreeMissing(path: workspacePath)]
                )
            }

            let currentIdentity = try repositoryIdentity(
                startingAt: URL(fileURLWithPath: workspacePath, isDirectory: true)
            )
            let inspector = GitWorkspaceInspector(
                fileManager: fileManager,
                timeout: timeout,
                maximumOutputBytes: maximumOutputBytes
            )
            let snapshot = try inspector.snapshot(
                startingAt: URL(fileURLWithPath: workspacePath, isDirectory: true)
            )
            let activeLease = try leaseStore?.activeLease(workspaceID: workspace.id)
            var issues: [ExecutionWorkspaceReconciliationIssue] = []

            if currentIdentity.commonGitDirectory != repository.commonGitDirectory {
                issues.append(
                    .repositoryIdentityMismatch(
                        expected: repository.commonGitDirectory,
                        actual: currentIdentity.commonGitDirectory
                    )
                )
            }
            if let expected = workspace.branchRef,
               expected != worktree.branchRef {
                issues.append(.branchDrift(expected: expected, actual: worktree.branchRef))
            }
            if let expected = workspace.expectedHeadSHA,
               expected != snapshot.headSHA {
                issues.append(.headDrift(expected: expected, actual: snapshot.headSHA))
            }
            if snapshot.isDirty {
                let paths = snapshot.status.prefix(12).map(\.path)
                issues.append(.dirtyWorkspace(paths: Array(paths)))
            }
            if let expectedLeaseID = workspace.leaseID {
                if let activeLease {
                    if activeLease.id != expectedLeaseID {
                        issues.append(
                            .writerCollision(
                                expectedLeaseID: expectedLeaseID,
                                actualLeaseID: activeLease.id,
                                actualOwnerID: activeLease.ownerID
                            )
                        )
                    }
                } else {
                    issues.append(.writerLeaseMissing(expectedLeaseID: expectedLeaseID))
                }
            }
            if let observedWorkerCWD {
                let actual = ExecutionWorkspacePathIdentity.canonicalPath(
                    observedWorkerCWD,
                    fileManager: fileManager
                )
                if actual != workspacePath {
                    issues.append(.cwdMismatch(expected: workspacePath, actual: actual))
                }
            }
            if let revision = workspace.baseRevision,
               let prepared = workspace.baseSHA {
                let args = ["rev-parse", "\(revision)^{commit}"]
                if let current = try? successful(
                    run(in: root, arguments: args),
                    arguments: args
                ).stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                   current != prepared {
                    issues.append(
                        .baseRevisionMoved(
                            revision: revision,
                            preparedSHA: prepared,
                            currentSHA: current
                        )
                    )
                }
            }

            let disposition: ExecutionWorkspaceDisposition
            if issues.contains(where: {
                if case .writerCollision = $0 { return true }
                return false
            }) {
                disposition = .writerCollision
            } else if issues.contains(where: {
                switch $0 {
                case .repositoryIdentityMismatch, .branchDrift, .headDrift, .cwdMismatch:
                    return true
                default:
                    return false
                }
            }) {
                disposition = .drifted
            } else if issues.contains(where: {
                if case .dirtyWorkspace = $0 { return true }
                return false
            }) {
                disposition = .preservationRequired
            } else if issues.contains(where: {
                if case .writerLeaseMissing = $0 { return true }
                return false
            }) {
                disposition = .unknown
            } else {
                disposition = .ready
            }

            return ExecutionWorkspaceReconciliation(
                disposition: disposition,
                worktree: worktree,
                activeLease: activeLease,
                issues: issues
            )
        } catch {
            return ExecutionWorkspaceReconciliation(
                disposition: .unknown,
                worktree: nil,
                activeLease: try? leaseStore?.activeLease(workspaceID: workspace.id),
                issues: [.inspectionFailed(error.localizedDescription)]
            )
        }
    }

    private struct CommandResult {
        var status: Int32
        var stdoutData: Data
        var stderrData: Data
        var stdoutWasTruncated: Bool = false
        var stdout: String { String(decoding: stdoutData, as: UTF8.self) }
        var stderr: String { String(decoding: stderrData, as: UTF8.self) }
    }

    private final class BoundedDataBox: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var value = Data()
        private var wasTruncated = false

        init(limit: Int) { self.limit = max(0, limit) }

        func append(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }
            let remaining = max(0, limit - value.count)
            if remaining > 0 {
                value.append(contentsOf: data.prefix(remaining))
            }
            if data.count > remaining { wasTruncated = true }
        }

        func snapshot() -> (data: Data, wasTruncated: Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (value, wasTruncated)
        }
    }

    private static func drain(_ handle: FileHandle, into box: BoundedDataBox) {
        while true {
            let chunk = handle.readData(ofLength: 64 * 1024)
            if chunk.isEmpty { return }
            box.append(chunk)
        }
    }

    private func run(in directory: URL, arguments: [String]) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory.path] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "LC_ALL": "C",
            "LANG": "C",
            "GIT_TERMINAL_PROMPT": "0",
        ]) { _, new in new }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdoutBox = BoundedDataBox(limit: maximumOutputBytes)
        let stderrBox = BoundedDataBox(limit: min(maximumOutputBytes, 64_000))
        let group = DispatchGroup()

        do {
            try process.run()
        } catch {
            return CommandResult(
                status: 127,
                stdoutData: Data(),
                stderrData: Data(error.localizedDescription.utf8)
            )
        }

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            Self.drain(stdoutPipe.fileHandleForReading, into: stdoutBox)
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            Self.drain(stderrPipe.fileHandleForReading, into: stderrBox)
            group.leave()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            group.wait()
            return CommandResult(
                status: 124,
                stdoutData: stdoutBox.snapshot().data,
                stderrData: Data("timed out".utf8)
            )
        }
        process.waitUntilExit()
        group.wait()
        let stdout = stdoutBox.snapshot()
        return CommandResult(
            status: process.terminationStatus,
            stdoutData: stdout.data,
            stderrData: stderrBox.snapshot().data,
            stdoutWasTruncated: stdout.wasTruncated
        )
    }

    private func successful(
        _ result: CommandResult,
        arguments: [String]
    ) throws -> CommandResult {
        guard result.status != 124 else {
            throw GitExecutionWorkspaceControllerError.timedOut(arguments: arguments)
        }
        guard result.status == 0 else {
            throw GitExecutionWorkspaceControllerError.commandFailed(
                arguments: arguments,
                status: result.status,
                stderr: result.stderr
            )
        }
        guard !result.stdoutWasTruncated else {
            throw GitExecutionWorkspaceControllerError.outputTruncated(arguments: arguments)
        }
        return result
    }
}

public enum ExecutionWorkspacePresentation {
    public static func classification(
        worktree: GitWorktreeRecord,
        humanCheckoutPath: String,
        managedWorkspaceRoot: String
    ) -> String {
        let path = ExecutionWorkspacePathIdentity.canonicalPath(worktree.path)
        let human = ExecutionWorkspacePathIdentity.canonicalPath(humanCheckoutPath)
        let managed = ExecutionWorkspacePathIdentity.canonicalPath(managedWorkspaceRoot)
        if path == human { return "human checkout" }
        if path == managed || path.hasPrefix(managed + "/") { return "agent workspace" }
        return "existing worktree"
    }

    public static func humanEntryWarning(
        workspace: ExecutionWorkspace,
        lease: WorkspaceLease?
    ) -> String? {
        guard workspace.authority == .readWrite,
              let lease,
              lease.status == .active else { return nil }
        return "Active writer lease belongs to \(lease.ownerID). Human edits should release or explicitly transfer writer authority first."
    }

    public static func applyingReconciliation(
        _ reconciliation: ExecutionWorkspaceReconciliation,
        workspacePath: String?,
        to current: [GitWorktreeRecord]
    ) -> [GitWorktreeRecord] {
        guard let workspacePath else { return current }
        let target = ExecutionWorkspacePathIdentity.canonicalPath(workspacePath)
        var rows = current.filter {
            ExecutionWorkspacePathIdentity.canonicalPath($0.path) != target
        }
        if let observed = reconciliation.worktree {
            rows.append(observed)
        }
        return rows.sorted { $0.path < $1.path }
    }
}
