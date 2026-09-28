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
        }
    }
}

private struct WorkspaceLeaseLedger: Codable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = WorkspaceLeaseLedger.currentSchemaVersion
    var activeByWorkspace: [String: WorkspaceLease] = [:]
    var history: [WorkspaceLease] = []
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

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }

        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

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
            #if canImport(Darwin)
            _ = Darwin.flock(descriptor, LOCK_UN)
            _ = Darwin.close(descriptor)
            #elseif canImport(Glibc)
            _ = Glibc.flock(descriptor, LOCK_UN)
            _ = Glibc.close(descriptor)
            #endif
        }

        #if canImport(Darwin)
        let lockStatus = Darwin.flock(descriptor, LOCK_EX)
        #elseif canImport(Glibc)
        let lockStatus = Glibc.flock(descriptor, LOCK_EX)
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
        }
    }
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
        let args = ["worktree", "list", "--porcelain"]
        let result = try successful(run(in: root, arguments: args), arguments: args)
        return GitWorktreeRecord.parsePorcelain(result.stdout)
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
        return ExecutionWorkspaceAllocationReceipt(
            workspace: workspace,
            worktree: record,
            warnings: warnings
        )
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
        var stdout: String { String(decoding: stdoutData, as: UTF8.self) }
        var stderr: String { String(decoding: stderrData, as: UTF8.self) }
    }

    private final class BoundedDataBox: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var value = Data()

        init(limit: Int) { self.limit = max(0, limit) }

        func append(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }
            let remaining = max(0, limit - value.count)
            if remaining > 0 {
                value.append(contentsOf: data.prefix(remaining))
            }
        }

        func snapshot() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return value
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
                stdoutData: stdoutBox.snapshot(),
                stderrData: Data("timed out".utf8)
            )
        }
        process.waitUntilExit()
        group.wait()
        return CommandResult(
            status: process.terminationStatus,
            stdoutData: stdoutBox.snapshot(),
            stderrData: stderrBox.snapshot()
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
