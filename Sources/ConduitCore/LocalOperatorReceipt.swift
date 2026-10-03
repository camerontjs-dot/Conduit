import CryptoKit
import Darwin
import Foundation

/// A declared task boundary. This is not a sandbox or a grant to an arbitrary
/// Shell command. Consequent machine changes have no grant path in V1.
public enum LocalOperatorAuthorityMode: String, Codable, CaseIterable, Sendable {
    case observe = "OBSERVE"
    case boundedWrite = "BOUNDED_WRITE"
    case consequentLocalChange = "CONSEQUENT_LOCAL_CHANGE"
}

public enum LocalOperatorDisposition: String, Codable, Sendable {
    case continuing = "CONTINUING"
    case terminal = "TERMINAL"
    case blocked = "BLOCKED"
    case operatorDecisionRequired = "OPERATOR_DECISION_REQUIRED"
}

public enum LocalOperatorReadSection: String, Equatable, Sendable {
    case status, receipt, changes, children
}

/// Supplied by the execution owner, never decoded from a mode request. The
/// current listener's clientInfo is nominal metadata, not a scoped principal.
public struct LocalOperatorAuthorizationObservation: Codable, Equatable, Sendable {
    public let localWriteGateObserved: Bool
    public let authorizer: String
    public let nominalCallerIdentity: String?
    public let callerIdentityAuthority: String

    public init(localWriteGateObserved: Bool, nominalCallerIdentity: String? = nil) {
        self.localWriteGateObserved = localWriteGateObserved
        self.authorizer = "CONDUIT_SESSION_API_LOCAL_WRITE_GATE"
        self.nominalCallerIdentity = nominalCallerIdentity
        self.callerIdentityAuthority = "NOMINAL_INITIALIZE_CLIENT_INFO_NOT_SCOPED_PRINCIPAL"
    }

    public func effectiveAuthority(for mode: LocalOperatorAuthorityMode) -> String {
        if mode == .consequentLocalChange { return "NO_CONSEQUENT_GRANT" }
        if mode == .observe { return "OBSERVATION_ONLY_NO_ARBITRARY_SHELL_GRANT" }
        return localWriteGateObserved ? "LOCAL_API_GATE_OBSERVED_BOUNDARY_IS_NOT_OPERATOR_GRANT" : "LOCAL_API_GATE_NOT_OBSERVED"
    }
}

public enum LocalOperatorError: Error, Equatable {
    case invalidBoundary
    case invalidPath(String)
    case unavailableRoot
    case invalidRecord
    case unavailableStore
    case staleRevision
    case historyLimit
}

public struct LocalOperatorBoundary: Codable, Equatable, Sendable {
    public let taskSessionID: TaskSessionID
    public let runtimeAttemptID: RuntimeAttemptID
    public let operationID: UUID
    public let projectSlug: String
    public let workingDirectory: String
    public let objective: String
    public let acceptanceCondition: String
    public let authorityMode: LocalOperatorAuthorityMode
    public let origin: ConduitSessionOrigin
    public let relativePaths: [String]
    public let declaredProtectedRelativePaths: [String]
    public let protectedRelativePaths: [String]

    public init(
        taskSessionID: TaskSessionID, runtimeAttemptID: RuntimeAttemptID,
        operationID: UUID = UUID(), projectSlug: String, workingDirectory: URL,
        objective: String, acceptanceCondition: String,
        authorityMode: LocalOperatorAuthorityMode, origin: ConduitSessionOrigin = .chatgpt,
        relativePaths: [String], protectedRelativePaths: [String] = [],
        preexistingDirtyRelativePaths: [String] = []
    ) throws {
        self.taskSessionID = taskSessionID
        self.runtimeAttemptID = runtimeAttemptID
        self.operationID = operationID
        self.projectSlug = projectSlug
        self.workingDirectory = workingDirectory.standardizedFileURL.path
        self.objective = objective
        self.acceptanceCondition = acceptanceCondition
        self.authorityMode = authorityMode
        self.origin = origin
        self.relativePaths = relativePaths.sorted()
        self.declaredProtectedRelativePaths = protectedRelativePaths.sorted()
        self.protectedRelativePaths = Array(Set(protectedRelativePaths + preexistingDirtyRelativePaths)).sorted()
        guard isValid else { throw LocalOperatorError.invalidBoundary }
    }

    public var isValid: Bool {
        !projectSlug.isEmpty && projectSlug.utf8.count <= 256
            && operationID != taskSessionID.rawValue && operationID != runtimeAttemptID.rawValue
            && taskSessionID.rawValue != runtimeAttemptID.rawValue
            && workingDirectory.hasPrefix("/") && !workingDirectory.contains("\0")
            && !objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && objective.utf8.count <= 2_048
            && !acceptanceCondition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && acceptanceCondition.utf8.count <= 2_048
            && origin == .chatgpt
            && !relativePaths.isEmpty && relativePaths.count <= 64
            && Set(relativePaths).count == relativePaths.count
            && Set(declaredProtectedRelativePaths).count == declaredProtectedRelativePaths.count
            && Set(declaredProtectedRelativePaths).isSubset(of: Set(protectedRelativePaths))
            && Set(protectedRelativePaths).count == protectedRelativePaths.count
            && Set(relativePaths + protectedRelativePaths).count <= 64
            && (relativePaths + protectedRelativePaths).allSatisfy(Self.validRelativePath)
    }

    public static func validRelativePath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 4_096 && !path.hasPrefix("/")
            && !path.contains("\0")
            && path.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

public enum LocalOperatorFileState: String, Codable, Sendable {
    case regular, missing, unavailable
}

/// Only bounded nominated files are read. Digests are observations, never
/// proof that this operation authored a change. No file body is retained.
public struct LocalOperatorFileObservation: Codable, Equatable, Sendable {
    public let relativePath: String
    public let state: LocalOperatorFileState
    public let sha256: String?
    public let size: Int64?
    public let device: UInt64?
    public let inode: UInt64?
    public let modificationSeconds: Int64?
    public let modificationNanoseconds: Int64?
    public let diagnostic: String?

    public var isValid: Bool {
        guard LocalOperatorBoundary.validRelativePath(relativePath) else { return false }
        if state == .regular {
            return sha256?.count == 64 && sha256?.allSatisfy { $0.isHexDigit } == true
                && size.map { $0 >= 0 && $0 <= 1_048_576 } == true
                && device != nil && inode != nil && modificationSeconds != nil
                && modificationNanoseconds.map { $0 >= 0 && $0 < 1_000_000_000 } == true
        }
        return sha256 == nil && size == nil && device == nil && inode == nil
            && modificationSeconds == nil && modificationNanoseconds == nil
    }
}

public struct LocalOperatorGitPath: Codable, Equatable, Sendable {
    public let path: String
    public let originalPath: String?
    public let indexStatus: String
    public let workTreeStatus: String
}

public struct LocalOperatorRepositoryObservation: Codable, Equatable, Sendable {
    public let repositoryRoot: String?
    public let headSHA: String?
    public let branch: String?
    public let detached: Bool?
    public let paths: [LocalOperatorGitPath]
    public let complete: Bool
    public let notRepository: Bool
    public let diagnostic: String?
}

public struct LocalOperatorSnapshot: Codable, Equatable, Sendable {
    public let observedAt: Date
    public let canonicalWorkingDirectory: String
    public let rootDevice: UInt64
    public let rootInode: UInt64
    public let files: [LocalOperatorFileObservation]
    public let repository: LocalOperatorRepositoryObservation
    public let processes: ProcessTreeObservation

    public var hasCompleteFileAndRepositoryObservation: Bool {
        files.allSatisfy { $0.state != .unavailable }
            && (repository.complete || repository.notRepository)
    }
}

public enum LocalOperatorFileChangeKind: String, Codable, Sendable {
    case created, modified, deleted, unknown
}

public struct LocalOperatorFileChange: Codable, Equatable, Sendable {
    public let relativePath: String
    public let kind: LocalOperatorFileChangeKind
    public let before: LocalOperatorFileObservation
    public let after: LocalOperatorFileObservation
    public let protected: Bool
    public let attribution: String
}

public struct LocalOperatorCommandObservation: Codable, Equatable, Sendable {
    public let runtimeAttemptID: String
    public let shellExecutionID: String
    public let commandID: String
    public let phase: ShellTelemetryPhase
    public let exitStatus: OrchestrationValue<Int32>
    public let observation: SupervisionObservationStamp

    public init(_ event: ShellTelemetryEvent) {
        runtimeAttemptID = event.runtimeAttemptID
        shellExecutionID = event.shellExecutionID
        commandID = event.commandID ?? ""
        phase = event.phase
        exitStatus = event.exitStatus
        observation = event.observation
    }
}

public struct LocalOperatorReceipt: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let boundary: LocalOperatorBoundary
    public let authorization: LocalOperatorAuthorizationObservation
    public let revision: Int
    public let recordedAt: Date
    public let preflight: LocalOperatorSnapshot
    public let observation: LocalOperatorSnapshot
    public let changes: [LocalOperatorFileChange]
    public let commands: [LocalOperatorCommandObservation]
    public let childProviderLinks: [ShellProviderCorrelation]
    public let disposition: LocalOperatorDisposition
    public let diagnostics: [String]
    public let acceptance: String

    public var isValid: Bool {
        schemaVersion == Self.currentSchemaVersion && boundary.isValid
            && revision >= 0 && revision < LocalOperatorRecordStore.maximumRevisions
            && authorization.authorizer == "CONDUIT_SESSION_API_LOCAL_WRITE_GATE"
            && authorization.callerIdentityAuthority == "NOMINAL_INITIALIZE_CLIENT_INFO_NOT_SCOPED_PRINCIPAL"
            && Set(preflight.files.map(\.relativePath)) == Set(boundary.relativePaths + boundary.protectedRelativePaths)
            && Set(observation.files.map(\.relativePath)) == Set(preflight.files.map(\.relativePath))
            && preflight.files.count == Set(preflight.files.map(\.relativePath)).count
            && observation.files.count == Set(observation.files.map(\.relativePath)).count
            && preflight.files.allSatisfy(\.isValid) && observation.files.allSatisfy(\.isValid)
            && preflight.processes.taskSessionID == boundary.taskSessionID.rawValue.uuidString
            && observation.processes.taskSessionID == boundary.taskSessionID.rawValue.uuidString
            && preflight.processes.runtimeAttemptID.value == boundary.runtimeAttemptID.rawValue.uuidString
            && observation.processes.runtimeAttemptID.value == boundary.runtimeAttemptID.rawValue.uuidString
            && commands.allSatisfy { $0.runtimeAttemptID == boundary.runtimeAttemptID.rawValue.uuidString
                && $0.observation.authority == .shellHookObserved
                && $0.observation.observedAt.isKnown }
            && childProviderLinks.allSatisfy {
                $0.taskSessionID.value == boundary.taskSessionID.rawValue.uuidString
                    && $0.runtimeAttemptID.value == boundary.runtimeAttemptID.rawValue.uuidString
            }
            && changes == LocalOperatorReceiptBuilder.fileChanges(boundary: boundary, preflight: preflight, observation: observation)
            && hasValidDisposition
            && acceptance == "NOT_ESTABLISHED"
    }

    private var hasValidDisposition: Bool {
        if boundary.authorityMode == .consequentLocalChange { return disposition == .operatorDecisionRequired }
        if disposition == .operatorDecisionRequired { return false }
        return LocalOperatorReceiptBuilder.blockReason(boundary: boundary, preflight: preflight,
            observation: observation, changes: changes) == nil || disposition == .blocked
    }
}

public enum LocalOperatorReceiptBuilder {
    public static func begin(boundary: LocalOperatorBoundary, snapshot: LocalOperatorSnapshot,
                             authorization: LocalOperatorAuthorizationObservation = .init(localWriteGateObserved: false)) -> LocalOperatorReceipt {
        make(boundary: boundary, revision: 0, preflight: snapshot, observation: snapshot,
             commands: [], childProviderLinks: [], terminal: false, priorDisposition: nil, authorization: authorization)
    }

    public static func checkpoint(
        previous: LocalOperatorReceipt, snapshot: LocalOperatorSnapshot,
        commands: [LocalOperatorCommandObservation] = [],
        childProviderLinks: [ShellProviderCorrelation] = [], terminal: Bool = false
    ) -> LocalOperatorReceipt {
        guard previous.disposition == .continuing else { return previous }
        return make(boundary: previous.boundary, revision: previous.revision + 1,
             preflight: previous.preflight, observation: snapshot,
             commands: commands, childProviderLinks: childProviderLinks, terminal: terminal,
             priorDisposition: previous.disposition, authorization: previous.authorization)
    }

    private static func make(
        boundary: LocalOperatorBoundary, revision: Int, preflight: LocalOperatorSnapshot,
        observation: LocalOperatorSnapshot, commands: [LocalOperatorCommandObservation],
        childProviderLinks: [ShellProviderCorrelation], terminal: Bool,
        priorDisposition: LocalOperatorDisposition?, authorization: LocalOperatorAuthorizationObservation
    ) -> LocalOperatorReceipt {
        let changes = fileChanges(boundary: boundary, preflight: preflight, observation: observation)
        var diagnostics = ["File/repository/process changes are observations, not syscall attribution or acceptance.",
                           "Declared modes do not sandbox arbitrary Shell commands; existing generic Shell remains separately available.",
                           "Empty child links do not establish an empty provider inventory; links retain their own historical authority/freshness."]
        if commands.count > 128 || childProviderLinks.count > 64 {
            diagnostics.append("The receipt summary is bounded; remaining command evidence stays in the durable Shell/task stream.")
        }
        let disposition: LocalOperatorDisposition
        if let priorDisposition, priorDisposition != .continuing {
            disposition = priorDisposition
            diagnostics.append("A terminal, blocked or decision-required operation cannot be reopened by checkpoint replay.")
        } else if boundary.authorityMode == .consequentLocalChange {
            disposition = .operatorDecisionRequired
            diagnostics.append("V1 cannot grant machine-wide, destructive, account or credential authority.")
        } else if let reason = blockReason(boundary: boundary, preflight: preflight, observation: observation, changes: changes) {
            disposition = .blocked
            diagnostics.append(reason)
        } else {
            disposition = terminal ? .terminal : .continuing
        }
        return LocalOperatorReceipt(schemaVersion: LocalOperatorReceipt.currentSchemaVersion,
            boundary: boundary, authorization: authorization, revision: revision, recordedAt: Date(), preflight: preflight,
            observation: observation, changes: changes, commands: Array(commands.suffix(128)),
            childProviderLinks: Array(childProviderLinks.filter {
                $0.taskSessionID.value == boundary.taskSessionID.rawValue.uuidString
                    && $0.runtimeAttemptID.value == boundary.runtimeAttemptID.rawValue.uuidString
            }.prefix(64)), disposition: disposition,
            diagnostics: diagnostics, acceptance: "NOT_ESTABLISHED")
    }

    static func blockReason(boundary: LocalOperatorBoundary, preflight: LocalOperatorSnapshot,
                            observation: LocalOperatorSnapshot, changes: [LocalOperatorFileChange]) -> String? {
        if preflight.rootDevice != observation.rootDevice || preflight.rootInode != observation.rootInode
            || preflight.canonicalWorkingDirectory != observation.canonicalWorkingDirectory {
            return "The working-directory object changed after preflight."
        }
        if !preflight.hasCompleteFileAndRepositoryObservation || !observation.hasCompleteFileAndRepositoryObservation {
            return "File or repository coverage is incomplete; unavailable is not unchanged."
        }
        if changes.contains(where: \.protected) { return "Protected file state changed after preflight." }
        if boundary.authorityMode == .observe && (!changes.isEmpty || preflight.repository != observation.repository) {
            return "A mutation was observed during an OBSERVE operation; authorship remains unknown."
        }
        let before = preflight.repository; let after = observation.repository
        if before.repositoryRoot != after.repositoryRoot || before.headSHA != after.headSHA
            || before.branch != after.branch || before.detached != after.detached || before.notRepository != after.notRepository {
            return "Repository identity, branch or HEAD changed outside the bounded file operation."
        }
        if let repositoryRoot = before.repositoryRoot {
            let allowed = Set(boundary.relativePaths.map {
                URL(fileURLWithPath: preflight.canonicalWorkingDirectory).appendingPathComponent($0).standardizedFileURL.path
            })
            var old: [String: LocalOperatorGitPath] = [:]; var new: [String: LocalOperatorGitPath] = [:]
            for path in before.paths { old[path.path] = path }
            for path in after.paths { new[path.path] = path }
            for key in Set(old.keys).union(new.keys) where old[key] != new[key] {
                let paths = [key, old[key]?.originalPath, new[key]?.originalPath].compactMap { $0 }
                if paths.contains(where: { !allowed.contains(URL(fileURLWithPath: repositoryRoot).appendingPathComponent($0).standardizedFileURL.path) }) {
                    return "Repository status changed outside the nominated file scope; attribution and authority remain unknown."
                }
            }
        }
        return nil
    }

    static func fileChanges(boundary: LocalOperatorBoundary, preflight: LocalOperatorSnapshot,
                            observation: LocalOperatorSnapshot) -> [LocalOperatorFileChange] {
        var old: [String: LocalOperatorFileObservation] = [:]
        for file in preflight.files where old[file.relativePath] == nil { old[file.relativePath] = file }
        return observation.files.compactMap { current -> LocalOperatorFileChange? in
            guard let prior = old[current.relativePath], prior != current else { return nil }
            let kind: LocalOperatorFileChangeKind
            if prior.state == .unavailable || current.state == .unavailable { kind = .unknown }
            else if prior.state == .missing && current.state == .regular { kind = .created }
            else if prior.state == .regular && current.state == .missing { kind = .deleted }
            else { kind = .modified }
            return LocalOperatorFileChange(relativePath: current.relativePath, kind: kind,
                before: prior, after: current, protected: boundary.protectedRelativePaths.contains(current.relativePath),
                attribution: "OBSERVED_ONLY_AUTHOR_UNKNOWN")
        }
    }

    /// Fail closed immediately before explicit local delivery. This cannot
    /// make check + an arbitrary command atomic; that remaining race is visible.
    public static func deliveryRefusal(
        receipt: LocalOperatorReceipt, current: LocalOperatorSnapshot,
        taskSessionID: TaskSessionID, runtimeAttemptID: RuntimeAttemptID
    ) -> String? {
        guard receipt.isValid else { return "Invalid durable operation record." }
        guard receipt.boundary.taskSessionID == taskSessionID,
              receipt.boundary.runtimeAttemptID == runtimeAttemptID else { return "Task/runtime attempt changed." }
        guard receipt.disposition == .continuing else { return "Operation is not continuing." }
        guard receipt.boundary.authorityMode == .boundedWrite else {
            return "Only BOUNDED_WRITE can deliver arbitrary Shell input through this helper; OBSERVE has no arbitrary-command proof."
        }
        guard receipt.authorization.localWriteGateObserved else { return "The local write-gate authorizer was not observed for this operation." }
        guard current.hasCompleteFileAndRepositoryObservation else { return "Current preflight coverage is incomplete." }
        guard current.rootDevice == receipt.observation.rootDevice,
              current.rootInode == receipt.observation.rootInode,
              current.canonicalWorkingDirectory == receipt.observation.canonicalWorkingDirectory,
              current.files == receipt.observation.files,
              current.repository == receipt.observation.repository else {
            return "External file/repository/root change since the last durable observation; checkpoint and review before delivery."
        }
        let expected = receipt.observation.processes.launcher.value
        let actual = current.processes.launcher.value
        guard let expected, let actual,
              receipt.observation.processes.coverage == .complete, current.processes.coverage == .complete,
              current.processes.taskSessionID == taskSessionID.rawValue.uuidString,
              current.processes.runtimeAttemptID.value == runtimeAttemptID.rawValue.uuidString,
              expected.ownership == .taskCreated, actual.ownership == .taskCreated,
              expected.pid == actual.pid, expected.startIdentity.value?.startTime.value != nil,
              actual.startIdentity.value?.startTime.value != nil,
              current.processes.observation.authority == .processObserved,
              current.processes.observation.freshness == .current,
              expected.startIdentity == actual.startIdentity, actual.liveness == .live else {
            return "Exact live owned Shell launcher identity is unavailable or changed."
        }
        return nil
    }

    public static func shellWorkingDirectoryRefusal(receipt: LocalOperatorReceipt,
                                                   telemetry: ShellTelemetryEvent?) -> String? {
        guard let telemetry, telemetry.hasValidIdentity,
              telemetry.runtimeAttemptID == receipt.boundary.runtimeAttemptID.rawValue.uuidString,
              telemetry.phase != .shellExited, let cwd = telemetry.workingDirectory.value else {
            return "Current identity-bound Shell working directory is unavailable."
        }
        guard URL(fileURLWithPath: cwd, isDirectory: true).resolvingSymlinksInPath().path
                == receipt.observation.canonicalWorkingDirectory else {
            return "Shell working directory changed; the operation does not authorize delivery in another directory."
        }
        return nil
    }
}

/// Descriptor-anchored, nonrecursive inspection. Parents and files are opened
/// with O_NOFOLLOW. An absent nominated path is distinct from an unreadable,
/// oversized, nonregular, moving or symlink path.
public struct LocalOperatorInspector: Sendable {
    public let maximumFileBytes: Int
    public init(maximumFileBytes: Int = 1_048_576) { self.maximumFileBytes = min(max(1, maximumFileBytes), 1_048_576) }

    public func snapshot(boundary: LocalOperatorBoundary, processes: ProcessTreeObservation) throws -> LocalOperatorSnapshot {
        guard boundary.isValid else { throw LocalOperatorError.invalidBoundary }
        let root = URL(fileURLWithPath: boundary.workingDirectory, isDirectory: true).resolvingSymlinksInPath()
        let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw LocalOperatorError.unavailableRoot }
        defer { Darwin.close(fd) }
        var rootStat = stat()
        guard Darwin.fstat(fd, &rootStat) == 0 else { throw LocalOperatorError.unavailableRoot }
        let paths = Set(boundary.relativePaths + boundary.protectedRelativePaths).sorted()
        let files = paths.map { observeFile(rootFD: fd, relativePath: $0) }
        let repository: LocalOperatorRepositoryObservation
        do {
            let git = try GitWorkspaceInspector(timeout: 2, maximumOutputBytes: 256_000).snapshot(startingAt: root)
            repository = LocalOperatorRepositoryObservation(repositoryRoot: git.repositoryRoot, headSHA: git.headSHA,
                branch: git.branch, detached: git.isDetached,
                paths: git.status.map { LocalOperatorGitPath(path: $0.path, originalPath: $0.originalPath,
                    indexStatus: String($0.indexStatus), workTreeStatus: String($0.workTreeStatus)) },
                complete: !git.statusWasTruncated, notRepository: false,
                diagnostic: git.statusWasTruncated ? "Git path coverage was truncated." : nil)
        } catch GitWorkspaceInspectorError.notRepository {
            repository = LocalOperatorRepositoryObservation(repositoryRoot: nil, headSHA: nil, branch: nil,
                detached: nil, paths: [], complete: false, notRepository: true, diagnostic: nil)
        } catch {
            repository = LocalOperatorRepositoryObservation(repositoryRoot: nil, headSHA: nil, branch: nil,
                detached: nil, paths: [], complete: false, notRepository: false,
                diagnostic: "Git checkpoint unavailable; no clean state inferred.")
        }
        var currentRoot = stat()
        guard Darwin.lstat(root.path, &currentRoot) == 0,
              rootStat.st_dev == currentRoot.st_dev, rootStat.st_ino == currentRoot.st_ino else {
            throw LocalOperatorError.unavailableRoot
        }
        let boundProcesses: ProcessTreeObservation
        if processes.taskSessionID == boundary.taskSessionID.rawValue.uuidString,
           processes.runtimeAttemptID.value == boundary.runtimeAttemptID.rawValue.uuidString {
            boundProcesses = processes
        } else {
            boundProcesses = .unavailable(taskSessionID: boundary.taskSessionID.rawValue.uuidString,
                runtimeAttemptID: .known(boundary.runtimeAttemptID.rawValue.uuidString), providerTurnID: .unknown,
                reason: "Supplied process observation does not match the exact task/runtime attempt.")
        }
        return LocalOperatorSnapshot(observedAt: Date(), canonicalWorkingDirectory: root.path,
            rootDevice: UInt64(rootStat.st_dev), rootInode: rootStat.st_ino,
            files: files, repository: repository, processes: boundProcesses)
    }

    private func observeFile(rootFD: Int32, relativePath: String) -> LocalOperatorFileObservation {
        func result(_ state: LocalOperatorFileState, _ s: stat? = nil, _ hash: String? = nil,
                    _ diagnostic: String? = nil) -> LocalOperatorFileObservation {
            LocalOperatorFileObservation(relativePath: relativePath, state: state, sha256: hash, size: s?.st_size,
                device: s.map { UInt64($0.st_dev) }, inode: s?.st_ino,
                modificationSeconds: s.map { Int64($0.st_mtimespec.tv_sec) },
                modificationNanoseconds: s.map { Int64($0.st_mtimespec.tv_nsec) }, diagnostic: diagnostic)
        }
        let pieces = relativePath.split(separator: "/").map(String.init)
        var parent = Darwin.dup(rootFD)
        guard parent >= 0 else { return result(.unavailable, nil, nil, "Root descriptor unavailable.") }
        defer { Darwin.close(parent) }
        for piece in pieces.dropLast() {
            let next = Darwin.openat(parent, piece, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 {
                return errno == ENOENT ? result(.missing) : result(.unavailable, nil, nil, "Parent is unavailable, non-directory or a symlink.")
            }
            Darwin.close(parent)
            parent = next
        }
        guard let name = pieces.last else { return result(.unavailable) }
        let file = Darwin.openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else {
            return errno == ENOENT ? result(.missing) : result(.unavailable, nil, nil, "File is unavailable or a symlink.")
        }
        defer { Darwin.close(file) }
        var before = stat()
        guard Darwin.fstat(file, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0,
              before.st_size <= maximumFileBytes else {
            return result(.unavailable, nil, nil, "File is nonregular or exceeds the explicit byte bound.")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(file, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; return result(.unavailable, nil, nil, "File read failed.") }
            if count == 0 { break }
            guard data.count + count <= maximumFileBytes else {
                return result(.unavailable, nil, nil, "File grew beyond the explicit byte bound.")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        var named = stat()
        guard Darwin.fstat(file, &after) == 0,
              Darwin.fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, data.count == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              after.st_dev == named.st_dev, after.st_ino == named.st_ino else {
            return result(.unavailable, nil, nil, "File changed identity or metadata during observation.")
        }
        return result(.regular, after, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
}

/// Append-only whole-receipt revisions. Writer locking and expected revision
/// prevent two callers silently replacing one another. Readers never repair
/// corrupt history. This store contains only Local Operator evidence.
public struct LocalOperatorRecordStore: Sendable {
    public static let maximumRevisions = 128
    public let directory: URL
    public init(directory: URL) { self.directory = directory.standardizedFileURL }

    public func records(taskSessionID: TaskSessionID, operationID: UUID) throws -> [LocalOperatorReceipt] {
        try locked(create: false) { fd in try read(fd: fd, task: taskSessionID, operation: operationID) }
    }

    public func append(_ receipt: LocalOperatorReceipt, expectedRevision: Int?) throws {
        guard receipt.isValid else { throw LocalOperatorError.invalidRecord }
        try locked(create: true) { fd in
            let prior = try read(fd: fd, task: receipt.boundary.taskSessionID, operation: receipt.boundary.operationID)
            guard prior.last?.revision == expectedRevision, receipt.revision == (expectedRevision ?? -1) + 1 else {
                throw LocalOperatorError.staleRevision
            }
            guard prior.count < Self.maximumRevisions else { throw LocalOperatorError.historyLimit }
            if let first = prior.first {
                guard first.boundary == receipt.boundary, first.preflight == receipt.preflight,
                      first.authorization == receipt.authorization else {
                    throw LocalOperatorError.invalidRecord
                }
            }
            guard prior.last?.disposition == nil || prior.last?.disposition == .continuing else {
                throw LocalOperatorError.invalidRecord
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(receipt)
            guard data.count <= 2_000_000 else { throw LocalOperatorError.invalidRecord }
            let filename = name(task: receipt.boundary.taskSessionID, operation: receipt.boundary.operationID, revision: receipt.revision)
            let file = Darwin.openat(fd, filename, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard file >= 0 else { throw LocalOperatorError.unavailableStore }
            defer { Darwin.close(file) }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let n = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { throw LocalOperatorError.unavailableStore }
                    offset += n
                }
            }
            guard Darwin.fsync(file) == 0 else { throw LocalOperatorError.unavailableStore }
            _ = Darwin.fsync(fd)
        }
    }

    private func name(task: TaskSessionID, operation: UUID, revision: Int) -> String {
        "\(task.rawValue.uuidString).\(operation.uuidString).\(String(format: "%03d", revision)).json"
    }

    private func read(fd: Int32, task: TaskSessionID, operation: UUID) throws -> [LocalOperatorReceipt] {
        let stream = Darwin.fdopendir(Darwin.dup(fd))
        guard let stream else { throw LocalOperatorError.unavailableStore }
        defer { Darwin.closedir(stream) }
        let prefix = "\(task.rawValue.uuidString).\(operation.uuidString)."
        var names = Set<String>()
        var scanned = 0
        while true {
            errno = 0
            guard let entry = Darwin.readdir(stream) else {
                guard errno == 0 else { throw LocalOperatorError.unavailableStore }
                break
            }
            scanned += 1
            guard scanned <= 16_384 else { throw LocalOperatorError.historyLimit }
            let entryName = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if entryName.hasPrefix(prefix) { names.insert(entryName) }
            guard names.count <= Self.maximumRevisions else { throw LocalOperatorError.historyLimit }
        }
        var result: [LocalOperatorReceipt] = []
        for revision in 0..<Self.maximumRevisions {
            let file = Darwin.openat(fd, name(task: task, operation: operation, revision: revision), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            if file < 0 {
                if errno == ENOENT {
                    guard names.isEmpty else { throw LocalOperatorError.invalidRecord }
                    return result
                }
                throw LocalOperatorError.unavailableStore
            }
            defer { Darwin.close(file) }
            var s = stat()
            guard Darwin.fstat(file, &s) == 0, s.st_mode & S_IFMT == S_IFREG, s.st_size <= 2_000_000 else {
                throw LocalOperatorError.invalidRecord
            }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let n = Darwin.read(file, &buffer, buffer.count)
                if n < 0 && errno == EINTR { continue }
                guard n >= 0, data.count + n <= 2_000_000 else { throw LocalOperatorError.invalidRecord }
                if n == 0 { break }; data.append(contentsOf: buffer.prefix(n))
            }
            var after = stat(); var named = stat()
            guard Darwin.fstat(file, &after) == 0,
                  Darwin.fstatat(fd, name(task: task, operation: operation, revision: revision), &named, AT_SYMLINK_NOFOLLOW) == 0,
                  s.st_dev == after.st_dev, s.st_ino == after.st_ino, s.st_size == after.st_size,
                  s.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, s.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  s.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, s.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
                  after.st_dev == named.st_dev, after.st_ino == named.st_ino else {
                throw LocalOperatorError.invalidRecord
            }
            guard let record = try? JSONDecoder().decode(LocalOperatorReceipt.self, from: data), record.isValid,
                  record.boundary.taskSessionID == task, record.boundary.operationID == operation,
                  record.revision == revision else { throw LocalOperatorError.invalidRecord }
            if let first = result.first {
                guard record.boundary == first.boundary, record.preflight == first.preflight,
                      record.authorization == first.authorization else {
                    throw LocalOperatorError.invalidRecord
                }
            }
            guard result.last?.disposition == nil || result.last?.disposition == .continuing else {
                throw LocalOperatorError.invalidRecord
            }
            result.append(record)
            names.remove(name(task: task, operation: operation, revision: revision))
        }
        return result
    }

    private func locked<T>(create: Bool, body: (Int32) throws -> T) throws -> T {
        if create { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw LocalOperatorError.unavailableStore }
        defer { Darwin.close(fd) }
        try validateDirectoryIdentity(fd: fd)
        let lockFlags = (create ? O_RDWR | O_CREAT : O_RDONLY) | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        let lock = Darwin.openat(fd, ".writer.lock", lockFlags, 0o600)
        guard lock >= 0 else { throw LocalOperatorError.unavailableStore }
        defer { Darwin.close(lock) }
        try validateLockEnvelope(directoryFD: fd, lockFD: lock)
        guard flock(lock, (create ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else { throw LocalOperatorError.unavailableStore }
        defer { _ = flock(lock, LOCK_UN) }
        try validateLockEnvelope(directoryFD: fd, lockFD: lock)
        let result = try body(fd)
        try validateLockEnvelope(directoryFD: fd, lockFD: lock)
        return result
    }

    /// Locking an inode is useful only while it remains the private regular
    /// lock named by this receipt directory. A FIFO must never block open,
    /// and replacement/moved state must not be returned as this store.
    /// This is an availability/identity check, not same-user authenticated custody.
    func validateLockEnvelope(directoryFD: Int32, lockFD: Int32) throws {
        try validateDirectoryIdentity(fd: directoryFD)
        var lock = stat(); var namedLock = stat()
        guard Darwin.fstat(lockFD, &lock) == 0,
              Darwin.fstatat(directoryFD, ".writer.lock", &namedLock, AT_SYMLINK_NOFOLLOW) == 0,
              lock.st_mode & S_IFMT == S_IFREG,
              namedLock.st_mode & S_IFMT == S_IFREG,
              lock.st_uid == geteuid(), namedLock.st_uid == lock.st_uid,
              lock.st_nlink == 1, namedLock.st_nlink == 1,
              lock.st_mode & 0o077 == 0, namedLock.st_mode & 0o077 == 0,
              lock.st_dev == namedLock.st_dev, lock.st_ino == namedLock.st_ino
        else { throw LocalOperatorError.unavailableStore }
    }

    private func validateDirectoryIdentity(fd: Int32) throws {
        var root = stat(); var namedRoot = stat()
        guard Darwin.fstat(fd, &root) == 0,
              Darwin.lstat(directory.path, &namedRoot) == 0,
              root.st_mode & S_IFMT == S_IFDIR,
              namedRoot.st_mode & S_IFMT == S_IFDIR,
              root.st_uid == geteuid(), namedRoot.st_uid == root.st_uid,
              root.st_mode & 0o077 == 0, namedRoot.st_mode & 0o077 == 0,
              root.st_dev == namedRoot.st_dev, root.st_ino == namedRoot.st_ino
        else { throw LocalOperatorError.unavailableStore }
    }
}
