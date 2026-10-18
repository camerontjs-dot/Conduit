import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct ConduitDirectCommandError: Error, LocalizedError {
    public let code: String
    public let detail: String
    public init(code: String, detail: String) { self.code = code; self.detail = detail }
    public var errorDescription: String? { detail }
}

public struct ConduitDirectCommandRequest: Codable, Equatable {
    public let operationID: String
    public let projectSlug: String
    public let argv: [String]
    public let cwd: String
    public let timeoutMS: Int
    public let maxOutputBytes: Int

    public init(operationID: String, projectSlug: String, argv: [String], cwd: String = ".",
                timeoutMS: Int = 10_000, maxOutputBytes: Int = 128_000) {
        self.operationID = operationID; self.projectSlug = projectSlug; self.argv = argv
        self.cwd = cwd; self.timeoutMS = timeoutMS; self.maxOutputBytes = maxOutputBytes
    }
}

public enum ConduitDirectCommandPhase: String, Codable {
    case accepted, queued, started, running, exited, nonzero, unknown
    case timedOut = "timed_out"
    case cancelRequested = "cancel_requested"
    case observedCancelled = "observed_cancelled"
    case launchFailed = "launch_failed"

    public var isTerminal: Bool {
        switch self {
        case .exited, .nonzero, .timedOut, .observedCancelled, .launchFailed, .unknown: return true
        default: return false
        }
    }
}

public struct ConduitDirectCommandTransition: Codable, Equatable {
    public let phase: ConduitDirectCommandPhase
    public let at: Date
}

/// The retained bytes are exact, including invalid UTF-8 and a truncated UTF-8
/// suffix. `utf8Text` is absent when the retained bytes are not ordinary text.
public struct ConduitDirectCommandOutput: Codable, Equatable {
    public internal(set) var bytes = Data()
    public internal(set) var totalBytesObserved: Int64 = 0
    public internal(set) var reachedEOF = false
    public var truncated: Bool { totalBytesObserved > Int64(bytes.count) }
    public var utf8Text: String? {
        bytes.contains(0) ? nil : String(data: bytes, encoding: .utf8)
    }
    public init() {}
    mutating func append(_ data: Data, limit: Int) {
        totalBytesObserved += Int64(data.count)
        bytes.append(data.prefix(max(0, limit - bytes.count)))
    }
}

public struct ConduitDirectCommandReceipt: Codable {
    public let schemaVersion: String
    public let request: ConduitDirectCommandRequest
    public let resolvedProjectRoot: String
    public let resolvedCwd: String
    public let projectRootIdentity: String
    public let cwdIdentity: String
    public let ownerInstanceID: String
    public internal(set) var phase: ConduitDirectCommandPhase
    public internal(set) var transitions: [ConduitDirectCommandTransition]
    public let acceptedAt: Date
    public internal(set) var startedAt: Date?
    public internal(set) var endedAt: Date?
    public internal(set) var pid: Int32?
    public internal(set) var processGroupID: Int32?
    public internal(set) var exitCode: Int32?
    public internal(set) var terminationSignal: Int32?
    public internal(set) var stdout = ConduitDirectCommandOutput()
    public internal(set) var stderr = ConduitDirectCommandOutput()
    public internal(set) var directChildExitObserved = false
    public internal(set) var processGroupAbsentObserved = false
    public internal(set) var executionCapacityReleased = false
    public internal(set) var note: String?
    public internal(set) var idempotentReplay = false

    mutating func transition(_ phase: ConduitDirectCommandPhase, at: Date = Date()) {
        guard self.phase != phase else { return }
        self.phase = phase
        transitions.append(.init(phase: phase, at: at))
    }
}

/// Native one-shot command machinery. The public initializer deliberately has
/// no execution authority: a session write switch is not an OS confinement
/// policy. Only the internal disposable-fixture initializer can launch today.
/// The service never adopts or signals a PID recovered from an old receipt.
public final class ConduitDirectCommandService {
    public static let maximumTimeoutMS = 120_000
    public static let maximumTimeoutMilliseconds = maximumTimeoutMS
    public static let maximumOutputBytes = 524_288
    public static let maximumRetainedOperations = 1_000
    public static let maximumRetainedBytes = 64 * 1_024 * 1_024
    public static let maximumReceiptBytes = 2_000_000
    private let directory: URL
    private let fixtureRoot: URL?
    private let capacity: Int
    private let instanceID = UUID().uuidString
    private let lock = NSLock()
    private var ownerFD: Int32 = -1
    private var storeFD: Int32 = -1
    private var storeParentFD: Int32 = -1
    private var storeParentPath: String?
    private var receipts: [String: ConduitDirectCommandReceipt] = [:]
    private var active = Set<String>()
    private var cancellations = Set<String>()

    /// No filesystem or process side effects occur during initialization.
    public init(storeDirectory: URL, maximumConcurrentOperations: Int = 2) {
        directory = storeDirectory
        fixtureRoot = nil
        capacity = min(4, max(1, maximumConcurrentOperations))
    }

    /// Development-test admission only; unavailable to the application target
    /// and never selected by caller JSON, environment variables, or settings.
    internal init(storeDirectory: URL, disposableFixtureRoot: URL, maximumConcurrentOperations: Int = 2) {
        directory = storeDirectory
        fixtureRoot = disposableFixtureRoot
        capacity = min(4, max(1, maximumConcurrentOperations))
    }

    deinit {
        if ownerFD >= 0 { _ = flock(ownerFD, LOCK_UN); _ = close(ownerFD) }
        if storeFD >= 0 { _ = close(storeFD) }
        if storeParentFD >= 0 { _ = close(storeParentFD) }
    }

    public func submit(_ request: ConduitDirectCommandRequest, projectRoot: URL,
                       admitWrite: (() throws -> Void)? = nil) throws -> ConduitDirectCommandReceipt {
        try Self.validate(request)
        // Preserve POSIX canonical spelling: Foundation standardization can
        // turn /private/var back into the /var symlink on macOS. A missing
        // nominated root must still reach the production-authority refusal.
        let root = (try? Self.canonicalExistingDirectory(projectRoot)) ?? projectRoot.standardizedFileURL
        lock.lock(); defer { lock.unlock() }
        if let existing = try readReceipt(request.operationID) {
            guard existing.request == request, existing.resolvedProjectRoot == root.path else {
                throw failure("operation_id_conflict", "This operation ID is already bound to a different exact request or project root; no command was launched.")
            }
            try verifyReplayTarget(existing, root: root)
            var replay = observed(existing); replay.idempotentReplay = true
            return replay
        }
        // Do not spend the session write budget, create the receipt directory,
        // or inspect executable bytes when production authority is unavailable.
        guard let fixtureRoot else {
            throw failure("execution_authority_unavailable", "Direct command execution is not enabled: Conduit has no operator-granted, enforceable execution profile. The session write switch alone cannot grant arbitrary OS command authority.")
        }
        guard root.path == (try Self.canonicalExistingDirectory(fixtureRoot)).path else {
            throw failure("project_not_authorized", "This development executor is restricted to its nominated disposable fixture root.")
        }
        try requireExternalStore(root: root)
        let cwd = try Self.resolveCwd(request.cwd, root: root)
        guard active.count < capacity else {
            throw failure("command_capacity_exhausted", "The separate direct-command capacity is occupied; no operation was accepted.")
        }
        try admitWrite?()
        try acquireOwnership()
        // Another service may have written before ownership was acquired.
        if let existing = try readReceipt(request.operationID) {
            guard existing.request == request, existing.resolvedProjectRoot == root.path else {
                throw failure("operation_id_conflict", "The operation ID was claimed by a different request; no command was launched.")
            }
            try verifyReplayTarget(existing, root: root)
            var replay = observed(existing); replay.idempotentReplay = true
            return replay
        }
        try reserveReceiptCapacity()
        let now = Date()
        var receipt = ConduitDirectCommandReceipt(
            schemaVersion: "conduit-direct-command/v1", request: request,
            resolvedProjectRoot: root.path, resolvedCwd: cwd.path,
            projectRootIdentity: try Self.directoryIdentity(root), cwdIdentity: try Self.directoryIdentity(cwd),
            ownerInstanceID: instanceID,
            phase: .accepted, transitions: [.init(phase: .accepted, at: now)], acceptedAt: now
        )
        receipt.transition(.queued, at: now)
        try reserveID(request.operationID)
        try persist(receipt) // The durable claim precedes every possible spawn.
        receipts[request.operationID] = receipt
        active.insert(request.operationID)
        DispatchQueue.global(qos: .utility).async { [self] in run(request.operationID) }
        return receipt
    }

    /// A read has no directory-creation, recovery-write, or process side effect.
    public func lookup(operationID: String, projectSlug: String, projectRoot: URL) throws -> ConduitDirectCommandReceipt {
        try Self.validateIdentity(operationID, projectSlug)
        lock.lock(); defer { lock.unlock() }
        return observed(try requiredReceipt(operationID, projectSlug, projectRoot: projectRoot))
    }

    public func cancel(operationID: String, projectSlug: String, projectRoot: URL,
                       admitWrite: (() throws -> Void)? = nil) throws -> ConduitDirectCommandReceipt {
        try Self.validateIdentity(operationID, projectSlug)
        lock.lock(); defer { lock.unlock() }
        var receipt = try requiredReceipt(operationID, projectSlug, projectRoot: projectRoot)
        if receipt.phase.isTerminal { return observed(receipt) }
        guard active.contains(operationID), receipt.ownerInstanceID == instanceID else {
            throw failure("process_ownership_unavailable", "This instance does not own the original child. Recovered PIDs are never cancellation targets; inspect the unknown receipt.")
        }
        if cancellations.contains(operationID) { return receipt }
        try admitWrite?()
        receipt.transition(.cancelRequested)
        try persist(receipt)
        receipts[operationID] = receipt
        cancellations.insert(operationID)
        return receipt
    }

    private static func validateIdentity(_ id: String, _ project: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard !id.isEmpty, id.utf8.count <= 128,
              id.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              !project.isEmpty, project.utf8.count <= 128, !project.utf8.contains(0) else {
            throw ConduitDirectCommandError(code: "invalid_arguments", detail: "Require an operation ID of 1...128 ASCII letters, digits, underscores or hyphens and an exact project slug.")
        }
    }

    private static func validate(_ request: ConduitDirectCommandRequest) throws {
        try validateIdentity(request.operationID, request.projectSlug)
        guard !request.argv.isEmpty, request.argv.count <= 128,
              request.argv[0].hasPrefix("/"), request.argv[0].utf8.count <= 4096,
              request.argv.allSatisfy({ !$0.utf8.contains(0) }),
              request.argv.reduce(0, { $0 + $1.utf8.count + 1 }) <= 65_536,
              (10...maximumTimeoutMS).contains(request.timeoutMS),
              (1...maximumOutputBytes).contains(request.maxOutputBytes) else {
            throw ConduitDirectCommandError(code: "invalid_arguments", detail: "Require literal argv (absolute executable, at most 128 elements/65536 UTF-8 bytes), timeout_ms 10...120000 and max_output_bytes 1...524288 per stream.")
        }
        let parts = request.cwd.split(separator: "/", omittingEmptySubsequences: false)
        guard !request.cwd.isEmpty, request.cwd.utf8.count <= 4096, !request.cwd.utf8.contains(0),
              !request.cwd.hasPrefix("/"), !parts.contains(".."),
              request.cwd == "." || !parts.contains(where: { $0.isEmpty || $0 == "." }),
              !parts.contains(where: { MainframeExplorerScanner.defaultIgnoredNames.contains(String($0)) }) else {
            throw ConduitDirectCommandError(code: "invalid_arguments", detail: "cwd must be an ordinary project-relative directory, or '.', with no parent, empty, symlink or excluded components.")
        }
    }

    private static func resolveCwd(_ relative: String, root: URL) throws -> URL {
        let cwd = relative == "." ? root : root.appendingPathComponent(relative)
        let facts = try MainframeExplorerScanner().fileFacts(root: root, item: cwd)
        guard facts.kind == .directory else {
            throw ConduitDirectCommandError(code: "cwd_unavailable", detail: "The nominated cwd is not an ordinary project directory.")
        }
        let canonical = try canonicalExistingDirectory(cwd)
        guard canonical.path == cwd.path else {
            throw ConduitDirectCommandError(code: "cwd_unavailable", detail: "The working directory changed to an alternate path during validation.")
        }
        return canonical
    }

    private func failure(_ code: String, _ detail: String) -> ConduitDirectCommandError {
        .init(code: code, detail: detail)
    }

    private static func directoryIdentity(_ directory: URL) throws -> String {
        var metadata = stat()
        guard lstat(directory.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else {
            throw ConduitDirectCommandError(code: "cwd_unavailable", detail: "The command's directory identity is unavailable or is no longer an ordinary directory.")
        }
        return "\(metadata.st_dev):\(metadata.st_ino)"
    }

    /// Keep realpath's physical spelling for descriptor walks and identity.
    /// Calling standardizedFileURL afterward may reintroduce macOS aliases.
    private static func canonicalExistingDirectory(_ directory: URL) throws -> URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let succeeded = buffer.withUnsafeMutableBufferPointer { output in
            directory.path.withCString { input in realpath(input, output.baseAddress) != nil }
        }
        guard succeeded else {
            throw ConduitDirectCommandError(code: "cwd_unavailable", detail: "The nominated directory cannot be resolved to an existing filesystem identity.")
        }
        let terminator = buffer.firstIndex(of: 0) ?? buffer.endIndex
        let path = String(decoding: buffer[..<terminator].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let canonical = URL(fileURLWithPath: path)
        _ = try directoryIdentity(canonical)
        return canonical
    }

    private func verifyReplayTarget(_ receipt: ConduitDirectCommandReceipt, root: URL) throws {
        do {
            let cwd = try Self.resolveCwd(receipt.request.cwd, root: root)
            guard cwd.path == receipt.resolvedCwd,
                  try Self.directoryIdentity(root) == receipt.projectRootIdentity,
                  try Self.directoryIdentity(cwd) == receipt.cwdIdentity else {
                throw failure("operation_target_changed", "The project or working directory identity changed after this operation was accepted. Inspect its existing receipt; it will not execute again.")
            }
        } catch {
            throw failure("operation_target_changed", "The original project or working directory can no longer be established. The existing operation is preserved and will not execute again.")
        }
    }

    private func requiredReceipt(_ id: String, _ project: String, projectRoot: URL) throws -> ConduitDirectCommandReceipt {
        guard let receipt = try readReceipt(id), receipt.request.projectSlug == project else {
            throw failure("operation_not_found", "No receipt exists for this operation ID and exact project.")
        }
        guard let root = try? Self.canonicalExistingDirectory(projectRoot),
              root.path == receipt.resolvedProjectRoot,
              (try? Self.directoryIdentity(root)) == receipt.projectRootIdentity else {
            throw failure("operation_project_changed", "The current project root is not the exact directory that owns this receipt; observation and cancellation are refused.")
        }
        return receipt
    }

    private func observed(_ receipt: ConduitDirectCommandReceipt) -> ConduitDirectCommandReceipt {
        guard !receipt.phase.isTerminal, !active.contains(receipt.request.operationID) else { return receipt }
        var copy = receipt
        // This is a derived observation, never a rewritten historical event.
        copy.phase = .unknown
        copy.note = "The durable request exists, but this instance does not own its execution. Completion and residual processes are unknown. The command will not be replayed and its recorded PID will not be signalled."
        return copy
    }

    private func acquireOwnership() throws {
        guard ownerFD < 0 else { return }
        // Only create the leaf in an existing, descriptor-pinned application
        // parent. Recursive mkdir would create unsynchronized ancestor entries
        // and could follow a redirected parent into a project.
        let parent = try openPinnedParent()
        var transferredParent = false
        defer { if !transferredParent { _ = close(parent.fd) } }
        if let fixtureRoot { try requireExternalStore(root: Self.canonicalExistingDirectory(fixtureRoot), parent: parent.url) }
        let name = directory.lastPathComponent
        if mkdirat(parent.fd, name, 0o700) < 0 && errno != EEXIST {
            throw failure("receipt_store_unavailable", "The receipt leaf could not be created in its existing application parent.")
        }
        guard fsync(parent.fd) == 0 else {
            throw failure("receipt_persistence_failed", "The receipt directory entry could not be synchronized in its parent; no operation was accepted.")
        }
        let directoryFD = openat(parent.fd, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw failure("receipt_store_unavailable", "Cannot pin the ordinary receipt directory.") }
        var acquired = false
        defer { if !acquired { _ = close(directoryFD) } }
        var opened = stat(), named = stat()
        guard fstat(directoryFD, &opened) == 0,
              fstatat(parent.fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_mode & S_IFMT == S_IFDIR, opened.st_dev == named.st_dev, opened.st_ino == named.st_ino,
              opened.st_uid == geteuid(), opened.st_mode & mode_t(0o077) == 0 else {
            throw failure("receipt_store_unavailable", "The receipt directory must be private, application-user owned and bound to the nominated parent.")
        }
        let fd = openat(directoryFD, ".command-owner.lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw failure("receipt_store_unavailable", "Cannot open the receipt ownership lock.") }
        var lockFacts = stat()
        guard fstat(fd, &lockFacts) == 0, lockFacts.st_mode & S_IFMT == S_IFREG else {
            _ = close(fd)
            throw failure("receipt_store_unavailable", "The receipt ownership lock is not an ordinary file.")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            _ = close(fd)
            throw failure("receipt_store_busy", "Another command manager owns this receipt store; no process was launched.")
        }
        ownerFD = fd
        storeFD = directoryFD
        storeParentFD = parent.fd
        storeParentPath = parent.url.path
        transferredParent = true
        acquired = true
    }

    private func requireExternalStore(root: URL, parent: URL? = nil) throws {
        let nominatedParent = directory.deletingLastPathComponent()
        let resolvedParent = parent ?? (try? Self.canonicalExistingDirectory(nominatedParent)) ?? nominatedParent.standardizedFileURL
        let target = resolvedParent.appendingPathComponent(directory.lastPathComponent).path
        guard target != root.path, !target.hasPrefix(root.path + "/") else {
            throw failure("receipt_store_scope_conflict", "Command receipts must live in separately nominated application state outside the command project.")
        }
    }

    private func openPinnedParent() throws -> (fd: Int32, url: URL) {
        let name = directory.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.utf8.contains(0) else {
            throw failure("receipt_store_unavailable", "The application receipt directory nomination is invalid.")
        }
        guard let parent = try? Self.canonicalExistingDirectory(directory.deletingLastPathComponent()) else {
            throw failure("receipt_store_unavailable", "The existing application parent is missing or inaccessible; no ancestor directories were created.")
        }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw failure("receipt_store_unavailable", "The receipt parent could not be opened.") }
        for component in parent.path.split(separator: "/") {
            let next = openat(current, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            _ = close(current)
            guard next >= 0 else {
                throw failure("receipt_store_unavailable", "The existing application parent is missing, inaccessible or changed to a symbolic link; no ancestor directories were created.")
            }
            current = next
        }
        return (current, parent)
    }

    private func validateStoreBinding() throws {
        guard storeFD >= 0 else { return }
        let currentParent = try openPinnedParent()
        defer { _ = close(currentParent.fd) }
        var originalParent = stat(), current = stat(), originalStore = stat(), namedStore = stat()
        guard currentParent.url.path == storeParentPath,
              fstat(storeParentFD, &originalParent) == 0, fstat(currentParent.fd, &current) == 0,
              originalParent.st_dev == current.st_dev, originalParent.st_ino == current.st_ino,
              fstat(storeFD, &originalStore) == 0,
              fstatat(storeParentFD, directory.lastPathComponent, &namedStore, AT_SYMLINK_NOFOLLOW) == 0,
              namedStore.st_mode & S_IFMT == S_IFDIR,
              namedStore.st_dev == originalStore.st_dev, namedStore.st_ino == originalStore.st_ino else {
            throw failure("receipt_store_changed", "The configured receipt path no longer identifies this manager's pinned application parent and store; no new command was admitted.")
        }
    }

    private func readReceipt(_ id: String) throws -> ConduitDirectCommandReceipt? {
        try validateStoreBinding()
        if let receipt = receipts[id] { return receipt }
        let directoryFD: Int32
        if storeFD >= 0 { directoryFD = storeFD }
        else {
            let parentPath = directory.deletingLastPathComponent()
            var parentFacts = stat()
            if lstat(parentPath.path, &parentFacts) < 0, errno == ENOENT { return nil }
            let parent = try openPinnedParent()
            directoryFD = openat(parent.fd, directory.lastPathComponent, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            let openError = errno
            _ = close(parent.fd)
            if directoryFD < 0, openError == ENOENT { return nil }
        }
        guard directoryFD >= 0 else { throw failure("receipt_store_unavailable", "The receipt directory cannot be opened without following its leaf as a link.") }
        defer { if storeFD < 0 { _ = close(directoryFD) } }
        var directoryFacts = stat()
        guard fstat(directoryFD, &directoryFacts) == 0, directoryFacts.st_uid == geteuid(),
              directoryFacts.st_mode & mode_t(0o077) == 0 else {
            throw failure("receipt_store_unavailable", "Receipt storage must remain private and owned by the application user.")
        }
        let fd = openat(directoryFD, id + ".json", O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0, errno == ENOENT {
            var reserved = stat()
            if fstatat(directoryFD, id + ".reserved", &reserved, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT {
                throw failure("operation_receipt_missing", "This operation ID was durably reserved but its outcome receipt is missing or inaccessible. Execution is unknown and will not be replayed.")
            }
            return nil
        }
        guard fd >= 0 else { throw failure("receipt_unavailable", "The existing receipt cannot be safely opened; execution is refused.") }
        defer { _ = close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size <= Self.maximumReceiptBytes else {
            throw failure("receipt_unavailable", "The receipt is not an ordinary bounded record; execution is refused.")
        }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0, errno == EINTR { continue }
            guard count > 0, data.count + count <= Self.maximumReceiptBytes else {
                throw failure("receipt_unavailable", "The receipt could not be read within its bound; execution is refused.")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        do {
            let receipt = try JSONDecoder().decode(ConduitDirectCommandReceipt.self, from: data)
            guard receipt.schemaVersion == "conduit-direct-command/v1", receipt.request.operationID == id else {
                throw failure("receipt_corrupt", "The receipt identity or schema does not match; execution is refused.")
            }
            return receipt
        } catch {
            throw failure("receipt_corrupt", "The existing receipt is invalid; it is preserved and the operation ID will not be reused.")
        }
    }

    private func persist(_ receipt: ConduitDirectCommandReceipt) throws {
        let data = try JSONEncoder().encode(receipt)
        guard storeFD >= 0, data.count <= Self.maximumReceiptBytes else {
            throw failure("receipt_persistence_failed", "Receipt ownership or its bounded size could not be established.")
        }
        let destination = receipt.request.operationID + ".json"
        let temporary = ".command-\(UUID().uuidString).tmp"
        let fd = openat(storeFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw failure("receipt_persistence_failed", "Cannot create the durable command receipt; inspect the operation ID before retrying.") }
        defer { _ = close(fd); _ = unlinkat(storeFD, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw failure("receipt_persistence_failed", "The receipt write failed; inspect this operation ID before retrying.") }
                offset += count
            }
        }
        guard fsync(fd) == 0, renameat(storeFD, temporary, storeFD, destination) == 0 else {
            throw failure("receipt_persistence_failed", "The receipt could not be synchronized; inspect this operation ID before retrying.")
        }
        guard fsync(storeFD) == 0 else { throw failure("receipt_persistence_failed", "The receipt directory synchronization failed; operation custody is uncertain.") }
    }

    private func reserveID(_ id: String) throws {
        let fd = openat(storeFD, id + ".reserved", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw failure("operation_id_reserved", "The operation ID is already reserved or could not be durably reserved; no command was launched.") }
        defer { _ = close(fd) }
        // Even an empty marker is a permanent claim. It is never removed when
        // a later receipt write fails, because absence must not mean retryable.
        guard fsync(fd) == 0, fsync(storeFD) == 0 else {
            throw failure("receipt_persistence_failed", "The operation ID reservation could not be synchronized; inspect this ID before retrying.")
        }
    }

    private func reserveReceiptCapacity() throws {
        try validateStoreBinding()
        let copy = fcntl(storeFD, F_DUPFD_CLOEXEC, 0)
        guard copy >= 0 else { throw failure("receipt_store_unavailable", "Cannot inspect receipt capacity.") }
        guard let listing = fdopendir(copy) else { _ = close(copy); throw failure("receipt_store_unavailable", "Cannot inspect receipt capacity.") }
        defer { closedir(listing) }
        // dup shares the directory offset with the retained descriptor.
        // Every capacity observation must restart at the first entry.
        rewinddir(listing)
        var operations = Set<String>(), bytes: Int64 = 0
        var entries = 0
        while let entry = readdir(listing) {
            let nameCapacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: nameCapacity) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            entries += 1
            guard entries <= Self.maximumRetainedOperations * 3 + 16 else {
                throw failure("receipt_capacity_exhausted", "The receipt directory exceeds its bounded entry inventory.")
            }
            var facts = stat()
            guard fstatat(storeFD, name, &facts, AT_SYMLINK_NOFOLLOW) == 0,
                  facts.st_mode & S_IFMT == S_IFREG, facts.st_size >= 0,
                  facts.st_size <= Self.maximumRetainedBytes else {
                throw failure("receipt_store_unavailable", "The private receipt store contains a nonordinary or concurrently changed entry.")
            }
            bytes += Int64(facts.st_size)
            if name.hasSuffix(".json") { operations.insert(String(name.dropLast(5))) }
            if name.hasSuffix(".reserved") { operations.insert(String(name.dropLast(9))) }
        }
        try validateStoreBinding()
        for id in operations {
            guard let prior = try readReceipt(id) else {
                throw failure("unresolved_command_ownership", "An earlier operation has no observable outcome receipt; new execution cannot establish safe process capacity.")
            }
            guard prior.ownerInstanceID == instanceID || prior.executionCapacityReleased else {
                throw failure("unresolved_command_ownership", "An earlier command manager left an operation without confirmed capacity release. New execution is refused; old PIDs are never adopted or signalled to manufacture recovery.")
            }
        }
        guard operations.count < Self.maximumRetainedOperations,
              bytes + Int64((active.count + 1) * Self.maximumReceiptBytes) <= Self.maximumRetainedBytes else {
            throw failure("receipt_capacity_exhausted", "The store's operation or 64 MiB byte budget is exhausted, including worst-case growth for active operations. History is retained and no new command was accepted.")
        }
    }

    private func run(_ id: String) {
        lock.lock()
        guard var receipt = receipts[id] else { lock.unlock(); return }
        if cancellations.contains(id) {
            receipt.transition(.observedCancelled); receipt.endedAt = Date()
            receipt.note = "Cancellation was observed before process creation; no command was launched."
            finishLocked(receipt); lock.unlock(); return
        }
        receipt.transition(.started); receipt.startedAt = Date()
        do { try persist(receipt); receipts[id] = receipt }
        catch { receipt.phase = .unknown; receipt.note = error.localizedDescription; finishLocked(receipt); lock.unlock(); return }
        lock.unlock()

        let child: NativeCommandChild
        do { child = try NativeCommandChild.spawn(receipt.request, cwd: receipt.resolvedCwd, expectedCwdIdentity: receipt.cwdIdentity) }
        catch {
            receipt.transition(.launchFailed); receipt.endedAt = Date(); receipt.note = error.localizedDescription
            lock.lock(); finishLocked(receipt); lock.unlock(); return
        }
        let started = ProcessInfo.processInfo.systemUptime
        receipt.pid = child.pid; receipt.processGroupID = child.pid
        var persistenceFailed = false
        lock.lock()
        // Preserve cancellation accepted in the spawn window.
        if cancellations.contains(id) { preserveCancellation(&receipt) }
        else { receipt.transition(.running) }
        do { try persist(receipt); receipts[id] = receipt }
        catch { persistenceFailed = true; receipt.note = error.localizedDescription }
        lock.unlock()

        var terminationRequestedAt: TimeInterval?
        var timeoutObserved = false, cancellationObserved = false, sentKill = false
        var rootReaped = false, waitLost = false
        var rootEndedAt: TimeInterval?
        var lastSave = started
        defer { _ = close(child.stdoutFD); _ = close(child.stderrFD) }
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            child.drain(child.stdoutFD, into: &receipt.stdout, limit: receipt.request.maxOutputBytes)
            child.drain(child.stderrFD, into: &receipt.stderr, limit: receipt.request.maxOutputBytes)
            if !rootReaped && !waitLost {
                var status: Int32 = 0
                let waited = waitpid(child.pid, &status, WNOHANG)
                if waited == child.pid {
                    rootReaped = true; rootEndedAt = now
                    receipt.directChildExitObserved = true
                    let signal = status & 0x7f
                    if signal == 0 { receipt.exitCode = (status >> 8) & 0xff }
                    else { receipt.terminationSignal = signal }
                } else if waited < 0 && errno != EINTR {
                    waitLost = true; receipt.note = "The owned child's exit status became unavailable; no further signals will be sent."
                }
            }
            lock.lock(); let cancellation = cancellations.contains(id); lock.unlock()
            if !rootReaped && !waitLost {
                if terminationRequestedAt == nil {
                    timeoutObserved = (now - started) * 1000 >= Double(receipt.request.timeoutMS)
                    cancellationObserved = cancellation
                    if timeoutObserved || cancellationObserved || persistenceFailed {
                        terminationRequestedAt = now
                        // The unreaped direct child pins this dedicated process
                        // group identity. Never signal after losing that child.
                        _ = kill(-child.pid, SIGTERM)
                    }
                } else if now - terminationRequestedAt! >= 0.5 && !sentKill {
                    _ = kill(-child.pid, SIGKILL); sentKill = true
                }
            }
            if waitLost { break }
            if rootReaped, (receipt.stdout.reachedEOF && receipt.stderr.reachedEOF) || now - (rootEndedAt ?? now) >= 0.25 {
                break
            }
            if let requested = terminationRequestedAt, now - requested >= 2 {
                receipt.note = "Termination was requested but a direct-child exit was not observed within the cleanup budget."
                break
            }
            if now - lastSave >= 0.1 {
                lock.lock()
                if cancellation && receipt.phase != .cancelRequested { preserveCancellation(&receipt) }
                do { try persist(receipt); receipts[id] = receipt }
                catch { persistenceFailed = true; receipt.note = error.localizedDescription }
                lock.unlock(); lastSave = now
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        // An absent group is an observation, not proof of process containment:
        // descendants could have deliberately created another group/session.
        receipt.processGroupAbsentObserved = kill(-child.pid, 0) < 0 && errno == ESRCH
        receipt.endedAt = Date()
        if persistenceFailed || !rootReaped || !receipt.processGroupAbsentObserved {
            receipt.transition(.unknown)
            if receipt.note == nil { receipt.note = "The direct child exited, but its original process group is still observable. Descendant completion is not established." }
        } else if cancellationObserved {
            receipt.transition(.observedCancelled)
        } else if timeoutObserved {
            receipt.transition(.timedOut)
        } else if receipt.exitCode == 0 {
            receipt.transition(.exited)
        } else { receipt.transition(.nonzero) }
        lock.lock(); finishLocked(receipt); lock.unlock()
    }

    private func finishLocked(_ value: ConduitDirectCommandReceipt) {
        var receipt = value
        let finalPhase = receipt.phase
        if !receipt.transitions.contains(where: { $0.phase == .cancelRequested }),
           receipts[receipt.request.operationID]?.transitions.contains(where: { $0.phase == .cancelRequested }) == true {
            // A cancellation accepted after exit observation is still a real
            // durable request. Preserve it without relabelling the exit as
            // caused by cancellation; publish the final known phase last.
            if receipt.transitions.last?.phase == finalPhase { receipt.transitions.removeLast() }
            preserveCancellation(&receipt)
            receipt.transition(finalPhase)
        }
        receipt.executionCapacityReleased = receipt.pid == nil
            || (receipt.directChildExitObserved && receipt.processGroupAbsentObserved)
        do { try persist(receipt) }
        catch { receipt.phase = .unknown; receipt.note = "Final receipt persistence failed: \(error.localizedDescription)" }
        receipts[receipt.request.operationID] = receipt
        if receipt.executionCapacityReleased { active.remove(receipt.request.operationID) }
        cancellations.remove(receipt.request.operationID)
    }

    private func preserveCancellation(_ receipt: inout ConduitDirectCommandReceipt) {
        guard !receipt.transitions.contains(where: { $0.phase == .cancelRequested }),
              let transition = receipts[receipt.request.operationID]?.transitions.first(where: { $0.phase == .cancelRequested }) else { return }
        receipt.transitions.append(transition)
        receipt.phase = .cancelRequested
    }
}

private struct NativeCommandChild {
    let pid: Int32
    let stdoutFD: Int32
    let stderrFD: Int32

    static func spawn(_ request: ConduitDirectCommandRequest, cwd: String, expectedCwdIdentity: String) throws -> Self {
        let cwdFD = open(cwd, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard cwdFD >= 0 else { throw posixFailure("cwd open", errno) }
        defer { _ = close(cwdFD) }
        var cwdFacts = stat()
        guard fstat(cwdFD, &cwdFacts) == 0,
              "\(cwdFacts.st_dev):\(cwdFacts.st_ino)" == expectedCwdIdentity else {
            throw ConduitDirectCommandError(code: "cwd_changed", detail: "The nominated working directory identity changed before spawn; no command was launched.")
        }
        var output: [Int32] = [-1, -1], errors: [Int32] = [-1, -1]
        guard pipe(&output) == 0 else { throw posixFailure("stdout pipe", errno) }
        guard pipe(&errors) == 0 else {
            output.forEach { _ = close($0) }; throw posixFailure("stderr pipe", errno)
        }
        var transferred = false
        defer {
            _ = close(output[1]); _ = close(errors[1])
            if !transferred { _ = close(output[0]); _ = close(errors[0]) }
        }
        for fd in output + errors { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        #else
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #endif
        let actionResult = posix_spawn_file_actions_init(&actions)
        guard actionResult == 0 else { throw posixFailure("spawn actions", actionResult) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        let attributeResult = posix_spawnattr_init(&attributes)
        guard attributeResult == 0 else { throw posixFailure("spawn attributes", attributeResult) }
        defer { posix_spawnattr_destroy(&attributes) }
        var emptyMask = sigset_t(), defaults = sigset_t()
        sigemptyset(&emptyMask); sigemptyset(&defaults)
        for signal in [SIGTERM, SIGINT, SIGPIPE] { sigaddset(&defaults, signal) }
        var flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        #if canImport(Darwin)
        flags |= POSIX_SPAWN_CLOEXEC_DEFAULT
        #endif
        let preparation = [
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
            posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, errors[1], STDERR_FILENO),
            posix_spawn_file_actions_addclose(&actions, output[0]),
            posix_spawn_file_actions_addclose(&actions, errors[0]),
            posix_spawn_file_actions_addclose(&actions, output[1]),
            posix_spawn_file_actions_addclose(&actions, errors[1]),
            posix_spawn_file_actions_addfchdir_np(&actions, cwdFD),
            posix_spawn_file_actions_addclose(&actions, cwdFD),
            posix_spawnattr_setpgroup(&attributes, 0),
            posix_spawnattr_setsigmask(&attributes, &emptyMask),
            posix_spawnattr_setsigdefault(&attributes, &defaults),
            posix_spawnattr_setflags(&attributes, Int16(flags)),
        ]
        if let error = preparation.first(where: { $0 != 0 }) { throw posixFailure("spawn preparation", error) }
        var argv: [UnsafeMutablePointer<CChar>?] = request.argv.map { value in
            value.withCString { strdup($0) }
        }
        // No inherited credentials, shell initialization, provider config,
        // stdin, implicit PATH lookup, or caller-supplied environment.
        let environmentStrings: [String] = ["PATH=/usr/bin:/bin", "LANG=C"]
        var environment: [UnsafeMutablePointer<CChar>?] = environmentStrings.map { value in
            value.withCString { strdup($0) }
        }
        defer { argv.forEach { free($0) }; environment.forEach { free($0) } }
        guard argv.allSatisfy({ $0 != nil }), environment.allSatisfy({ $0 != nil }) else {
            throw posixFailure("argument allocation", ENOMEM)
        }
        argv.append(nil); environment.append(nil)
        var pid: pid_t = 0
        let result = posix_spawn(&pid, request.argv[0], &actions, &attributes, &argv, &environment)
        guard result == 0 else { throw posixFailure("spawn", result) }
        for fd in [output[0], errors[0]] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        transferred = true
        return .init(pid: pid, stdoutFD: output[0], stderrFD: errors[0])
    }

    func drain(_ fd: Int32, into output: inout ConduitDirectCommandOutput, limit: Int) {
        guard !output.reachedEOF else { return }
        var buffer = [UInt8](repeating: 0, count: 8192)
        // A continuous writer cannot starve timeout/cancellation observation.
        for _ in 0..<32 {
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { output.reachedEOF = true; return }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            output.append(Data(buffer.prefix(count)), limit: limit)
        }
    }

    private static func posixFailure(_ operation: String, _ code: Int32) -> ConduitDirectCommandError {
        .init(code: "launch_failed", detail: "Native \(operation) failed (errno \(code)); no agent or PTY was used.")
    }
}
