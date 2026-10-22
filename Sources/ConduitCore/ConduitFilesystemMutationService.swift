import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Exact, bounded UTF-8 creates/replacements in an already-authorized project.
/// Authentication, project resolution, and the existing write/resource gate
/// belong to the caller. Receipt lookup never creates storage or writes a file.
public final class ConduitFilesystemMutationService: @unchecked Sendable {
    public static let writeToolName = "conduit_write_file"
    public static let statusToolName = "conduit_file_operation_status"
    public static let maximumBytes = 512_000
    public static let maximumReceiptBytes = 32_768
    public static let maximumStoredBytes = 32_000_000

    // Serializes instances in this process. A nonblocking flock also protects
    // a store shared by distinct app processes. It is not a filesystem sandbox.
    private static let processLock = NSLock()
    private let receiptDirectory: URL
    private let maximumReceipts: Int
    private let synchronizeReceiptParent: (Int32) -> Int32

    public init(receiptDirectory: URL, maximumReceipts: Int = 1_000) {
        self.receiptDirectory = receiptDirectory
        self.maximumReceipts = min(max(1, maximumReceipts), 1_000)
        self.synchronizeReceiptParent = { fsync($0) }
    }

    // A module-internal fault seam for proving that failed parent durability
    // prevents intent/target work. The production initializer always uses fsync.
    init(receiptDirectory: URL, maximumReceipts: Int = 1_000,
         synchronizeReceiptParent: @escaping (Int32) -> Int32) {
        self.receiptDirectory = receiptDirectory
        self.maximumReceipts = min(max(1, maximumReceipts), 1_000)
        self.synchronizeReceiptParent = synchronizeReceiptParent
    }

    public func call(
        arguments: CodexJSON, root: URL?, admitWrite: () -> [String: Any]?
    ) -> [String: Any] {
        Self.toolResult(mutate(arguments: arguments, root: root, admitWrite: admitWrite))
    }

    public func status(arguments: CodexJSON, root: URL?) -> [String: Any] {
        Self.toolResult(lookup(arguments: arguments, root: root))
    }

    public func lookup(arguments: CodexJSON, root: URL?) -> [String: Any] {
        var requestedOperationID: String?
        do {
            guard case .object(let fields) = arguments,
                  Set(fields.keys) == ["operation_id", "project_slug"],
                  let operationID = fields["operation_id"]?.stringValue,
                  Self.validID(operationID),
                  let project = fields["project_slug"]?.stringValue,
                  Self.validProject(project) else {
                throw Failure("invalid_arguments", "Require operation_id and exact project_slug, without extra fields.")
            }
            requestedOperationID = operationID
            let scope = try Scope(root: root)
            let location = try Store.Location(receiptDirectory)
            try scope.requireExternalReceiptDirectory(location)
            guard let store = try Store.openExisting(location) else {
                return Self.failure("not_found", "No retained operation with this ID.", operationID: operationID)
            }
            defer { close(store) }
            guard let receipt = try Self.readReceipt(store: store, operationID: operationID) else {
                return Self.failure("not_found", "No retained operation with this ID.", operationID: operationID)
            }
            guard receipt.project == project, receipt.rootIdentity == scope.identity else {
                throw Failure("operation_scope_conflict", "The operation belongs to another project or resolved root identity.")
            }
            return receipt.payload(replayed: true)
        } catch let error as Failure {
            return Self.failure(error.code, error.message, operationID: requestedOperationID)
        } catch {
            return Self.failure("receipt_store_unavailable", "The operation receipt could not be read safely.", operationID: requestedOperationID)
        }
    }

    public func mutate(
        arguments: CodexJSON, root: URL?, admitWrite: () -> [String: Any]?
    ) -> [String: Any] {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        var admittedReceipt: Receipt?
        var operationID: String?
        var store: Int32 = -1
        var mutationCommitted = false
        defer { if store >= 0 { close(store) } }

        do {
            let request = try Request(arguments)
            operationID = request.operationID
            let scope = try Scope(root: root)
            let location = try Store.Location(receiptDirectory)
            try scope.requireExternalReceiptDirectory(location)
            let fingerprint = request.fingerprint(rootIdentity: scope.identity)
            if let existingStore = try Store.openExisting(location) {
                defer { close(existingStore) }
                if let existing = try Self.readReceipt(store: existingStore, operationID: request.operationID) {
                    return try Self.replay(existing, fingerprint: fingerprint)
                }
            }

            let target = try Target(scope: scope, components: request.components)
            let before = try target.preflight(request: request)
            // Invalid/stale requests and exact replays do not consume the
            // caller's write budget. This closure must use the existing gate.
            if let refusal = admitWrite() {
                var result = Self.failure("admission_refused", "The existing Session API write/resource gate refused this operation.", operationID: request.operationID)
                result["admission"] = refusal
                return result
            }

            // Creation is deliberately deferred until admission. The second
            // receipt check closes the initial-creation race across processes.
            store = try Store.openForAdmittedWrite(location, synchronizeParent: synchronizeReceiptParent)
            guard flock(store, LOCK_EX | LOCK_NB) == 0 else {
                throw Failure("receipt_store_busy", "Another process owns the receipt store; no target write was attempted.")
            }
            defer { flock(store, LOCK_UN) }
            if let existing = try Self.readReceipt(store: store, operationID: request.operationID) {
                return try Self.replay(existing, fingerprint: fingerprint)
            }
            try location.requireCurrent()
            try Store.checkCapacity(store, maximumReceipts: maximumReceipts, reserveBytes: (before?.data.count ?? 0) + Self.maximumReceiptBytes * 2)
            try target.checkUnchanged(request: request, before: before)

            let stagedName = ".conduit-write-" + UUID().uuidString + ".tmp"
            var receipt = Receipt(
                operationID: request.operationID, project: request.project,
                path: request.path, rootIdentity: scope.identity,
                fingerprint: fingerprint, expectedSHA256: request.expectedSHA256,
                beforeSHA256: before.map { Self.sha($0.data) },
                beforeBytes: before?.data.count,
                requestedSHA256: Self.sha(request.bytes), requestedBytes: request.bytes.count,
                stagingPath: (Array(request.components.dropLast()) + [stagedName]).joined(separator: "/")
            )
            try Store.writeExclusive(store, name: Self.key(request.operationID) + ".reserved", data: Data(fingerprint.utf8))
            // A durable intent is established before any target-directory
            // staging. An interrupted intent is UNKNOWN and never re-executes.
            try Self.persist(receipt, store: store)
            admittedReceipt = receipt
            if let before {
                try Store.writeExclusive(store, name: Self.key(request.operationID) + ".before", data: before.data)
                receipt.beforeBytesPreserved = true
                try Self.persist(receipt, store: store)
                admittedReceipt = receipt
            }

            let stage = openat(target.parent, stagedName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard stage >= 0 else { throw Failure("stage_failed", "Could not create an exclusive staging file in the checked directory.") }
            defer {
                close(stage)
                unlinkat(target.parent, stagedName, 0)
            }
            try Self.writeAll(stage, request.bytes)
            if let before {
                guard fchown(stage, before.info.st_uid, before.info.st_gid) == 0 else {
                    throw Failure("unsupported_metadata", "The prior owner/group could not be preserved on the staged file.")
                }
            }
            // Only ordinary owner-held files are eligible. Preserve POSIX
            // permission bits; reject special modes/flags during preflight.
            guard fchmod(stage, before.map { $0.info.st_mode & mode_t(0o777) } ?? mode_t(0o600)) == 0 else {
                throw Failure("stage_failed", "The staged permissions could not be preserved.")
            }
            _ = try Self.requireOrdinaryMetadata(stage)
            if let provenance = before?.provenance {
                try Self.preserveProvenance(provenance, on: stage)
            }
            // An absent source attribute does not authorize stripping an
            // attribute supplied by the OS on the new inode.
            let stagedProvenance = try Self.requireOrdinaryMetadata(stage)
            if let provenance = before?.provenance, stagedProvenance != provenance {
                throw Failure("unsupported_metadata", "The prior opaque provenance could not be preserved exactly on the staged file.")
            }
            guard fsync(stage) == 0 else {
                throw Failure("stage_failed", "The staged bytes, permissions and supported metadata could not be flushed.")
            }
            try target.checkUnchanged(request: request, before: before)
            guard try Self.requireOrdinaryMetadata(stage) == stagedProvenance else {
                throw Failure("unsupported_metadata", "The staged provenance changed before commit.")
            }
            if request.expectedSHA256 == nil {
                // linkat provides atomic exclusive creation: a concurrent
                // creator is never overwritten by a rename-with-replacement.
                guard linkat(target.parent, stagedName, target.parent, target.name, 0) == 0 else {
                    throw Failure(errno == EEXIST ? "precondition_failed" : "commit_failed", "Exclusive creation failed; an existing destination was not overwritten.")
                }
                mutationCommitted = true
                guard unlinkat(target.parent, stagedName, 0) == 0 else {
                    throw Failure("stage_cleanup_failed", "Creation occurred but its temporary link could not be removed; inspect the receipt before another edit.")
                }
            } else {
                guard renameat(target.parent, stagedName, target.parent, target.name) == 0 else {
                    throw Failure("commit_failed", "The checked file could not be replaced.")
                }
            }
            mutationCommitted = true
            guard fsync(target.parent) == 0 else {
                throw Failure("commit_durability_unknown", "The namespace change occurred but directory durability could not be confirmed.")
            }
            let observed = try target.readCurrent()
            var stageInfo = stat()
            guard fstat(stage, &stageInfo) == 0,
                  observed.info.st_dev == stageInfo.st_dev,
                  observed.info.st_ino == stageInfo.st_ino,
                  Self.sha(observed.data) == receipt.requestedSHA256,
                  observed.provenance == stagedProvenance else {
                throw Failure("postcondition_changed", "The target changed during the post-write observation; do not retry under a new ID without inspection.")
            }
            receipt.state = "succeeded"
            receipt.finishedAt = Self.timestamp()
            receipt.afterSHA256 = Self.sha(observed.data)
            receipt.afterBytes = observed.data.count
            receipt.mutationObserved = true
            try Self.persist(receipt, store: store)
            return receipt.payload(replayed: false)
        } catch {
            let failure = (error as? Failure) ?? Failure("io_error", "The bounded file operation encountered an I/O failure.")
            if var receipt = admittedReceipt, store >= 0 {
                receipt.state = mutationCommitted ? "unknown" : "refused"
                receipt.errorCode = failure.code
                receipt.errorMessage = failure.message
                receipt.finishedAt = Self.timestamp()
                receipt.mutationObserved = mutationCommitted
                do {
                    try Self.persist(receipt, store: store)
                } catch {
                    receipt.state = "unknown"
                    receipt.errorCode = "receipt_persistence_failed"
                    receipt.errorMessage = "A durable intent exists, but the outcome receipt could not be saved. Inspect this operation; never automatically retry with a new ID."
                }
                return receipt.payload(replayed: false)
            }
            return Self.failure(failure.code, failure.message, operationID: operationID)
        }
    }

    private struct Failure: Error {
        let code: String
        let message: String
        init(_ code: String, _ message: String) { self.code = code; self.message = message }
    }

    private struct Request {
        let operationID: String
        let project: String
        let path: String
        let components: [String]
        let bytes: Data
        let expectedSHA256: String?

        init(_ arguments: CodexJSON) throws {
            guard case .object(let fields) = arguments,
                  Set(fields.keys).isSubset(of: ["operation_id", "project_slug", "path", "text", "expected_absent", "expected_sha256"]),
                  let operationID = fields["operation_id"]?.stringValue, Self.valid(operationID),
                  let project = fields["project_slug"]?.stringValue, ConduitFilesystemMutationService.validProject(project),
                  let path = fields["path"]?.stringValue,
                  !path.isEmpty, path.utf8.count <= 4096, !path.utf8.contains(0),
                  let text = fields["text"]?.stringValue else {
                throw Failure("invalid_arguments", "Require operation_id, project_slug, literal path, UTF-8 text, and exactly one expected precondition.")
            }
            let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !path.hasPrefix("/"), !components.contains("..") else {
                throw Failure("outside_root", "Only a literal project-relative file path is accepted.")
            }
            guard !components.contains(where: { $0.isEmpty || $0 == "." }), components.count <= 64 else {
                throw Failure("invalid_arguments", "Use a bounded literal path without empty, dot, or parent components.")
            }
            // Deliberately narrow initial edit policy, additional to descriptor
            // containment. It is not a classifier for every credential file.
            let instructionNames: Set<String> = ["agents.md", "claude.md", "harness.md"]
            guard !components.contains(where: { $0.hasPrefix(".") || instructionNames.contains($0.lowercased()) }) else {
                throw Failure("protected_path", "Hidden paths and operator instruction files require a separate authority surface.")
            }
            guard !MainframeExplorerVisualClassifier.isKnownNonText(fileName: components.last ?? "") else {
                throw Failure("unsupported", "Known binary/media formats are not eligible for a text write.")
            }
            let bytes = Data(text.utf8)
            guard bytes.count <= ConduitFilesystemMutationService.maximumBytes else {
                throw Failure("oversized", "Replacement UTF-8 bytes exceed the 512000-byte limit.")
            }
            guard !bytes.contains(where: { $0 == 0 || ($0 < 32 && $0 != 9 && $0 != 10 && $0 != 13) }) else {
                throw Failure("unsupported", "Text contains binary/control bytes outside the ordinary UTF-8 policy.")
            }
            let expectedSHA256: String?
            if case .bool(true)? = fields["expected_absent"], fields["expected_sha256"] == nil {
                expectedSHA256 = nil
            } else if fields["expected_absent"] == nil,
                      let hash = fields["expected_sha256"]?.stringValue,
                      hash.utf8.count == 64,
                      hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) {
                expectedSHA256 = hash
            } else {
                throw Failure("invalid_arguments", "Use expected_absent:true for create, or one lowercase 64-digit expected_sha256 for replace.")
            }
            self.operationID = operationID; self.project = project; self.path = path
            self.components = components; self.bytes = bytes; self.expectedSHA256 = expectedSHA256
        }

        private static func valid(_ value: String) -> Bool { ConduitFilesystemMutationService.validID(value) }

        func fingerprint(rootIdentity: String) -> String {
            let fields: [String: String] = [
                "project": project, "path": path, "root_identity": rootIdentity,
                "expected": expectedSHA256 ?? "absent",
                "requested_sha256": ConduitFilesystemMutationService.sha(bytes),
                "requested_bytes": String(bytes.count),
            ]
            return ConduitFilesystemMutationService.sha((try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data())
        }
    }

    private final class Scope {
        let fd: Int32
        let identity: String
        let canonicalPath: String
        init(root: URL?) throws {
            guard let root else { throw Failure("project_unavailable", "The exact project root is unavailable or not authorized.") }
            // Reuse Explorer's root/symlink policy before anchoring descriptors.
            do { _ = try MainframeExplorerScanner().fileFacts(root: root, item: root) }
            catch { throw Failure("project_unavailable", "The resolved project root failed Explorer's filesystem boundary.") }
            guard let canonical = realpath(root.path, nil) else {
                throw Failure("project_unavailable", "The resolved project root does not exist.")
            }
            defer { free(canonical) }
            let path = String(cString: canonical)
            guard path != "/" else { throw Failure("project_unavailable", "The filesystem root is not an eligible project.") }
            let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw Failure("project_unavailable", "The resolved project root could not be opened safely.") }
            var info = stat()
            guard fstat(fd, &info) == 0 else { close(fd); throw Failure("project_unavailable", "The root identity could not be observed.") }
            self.fd = fd
            self.canonicalPath = path
            self.identity = ConduitFilesystemMutationService.sha(Data("\(path)\u{0}\(info.st_dev)\u{0}\(info.st_ino)".utf8))
        }
        deinit { close(fd) }

        func requireCurrent() throws {
            // A held descriptor remains valid if the whole project is moved.
            // Reopen the configured canonical path as well: an old descriptor
            // alone is not evidence that it remains the authorized project.
            guard let resolved = realpath(canonicalPath, nil) else {
                throw Failure("project_changed", "The authorized project root disappeared or moved during the operation.")
            }
            defer { free(resolved) }
            guard String(cString: resolved) == canonicalPath else {
                throw Failure("project_changed", "The project root or one of its ancestors was remapped through a symbolic link.")
            }
            let current = open(canonicalPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard current >= 0 else { throw Failure("project_changed", "The configured project root can no longer be opened without following a link.") }
            defer { close(current) }
            var info = stat()
            guard fstat(current, &info) == 0,
                  identity == ConduitFilesystemMutationService.sha(Data("\(canonicalPath)\u{0}\(info.st_dev)\u{0}\(info.st_ino)".utf8)) else {
                throw Failure("project_changed", "The configured project path now identifies a different directory; no target write was attempted by this check.")
            }
        }

        func requireExternalReceiptDirectory(_ directory: Store.Location) throws {
            let path = directory.canonicalPath
            guard path != canonicalPath, !path.hasPrefix(canonicalPath + "/") else {
                throw Failure("receipt_store_unavailable", "Receipt storage must be outside the authorized project.")
            }
        }
    }

    private struct FileObservation {
        let data: Data
        let info: stat
        let provenance: Data?
    }

    /// The parent is held open throughout preflight, staging, and commit. Every
    /// relative directory is opened with O_NOFOLLOW and rechecked before commit.
    private final class Target {
        let scope: Scope
        let parent: Int32
        let name: String
        let components: [String]
        let parentIdentity: stat

        init(scope: Scope, components: [String]) throws {
            self.scope = scope; self.components = components; self.name = components.last!
            let parent = try Self.openParent(scope: scope, components: components)
            var info = stat()
            guard fstat(parent, &info) == 0 else { close(parent); throw Failure("inaccessible", "The containing directory could not be observed.") }
            self.parent = parent; self.parentIdentity = info
        }
        deinit { close(parent) }

        static func openParent(scope: Scope, components: [String]) throws -> Int32 {
            try scope.requireCurrent()
            var fd = fcntl(scope.fd, F_DUPFD_CLOEXEC, 0)
            guard fd >= 0 else { throw Failure("inaccessible", "The project descriptor could not be duplicated.") }
            do {
                for component in components.dropLast() {
                    var info = stat()
                    guard fstatat(fd, component, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                        throw Failure("missing_parent", "An existing ordinary containing directory is required; directories are not created implicitly.")
                    }
                    guard info.st_mode & S_IFMT != S_IFLNK else { throw Failure("symlink_traversal", "Symbolic-link path components are never followed.") }
                    guard info.st_mode & S_IFMT == S_IFDIR else { throw Failure("not_directory", "A containing path component is not an ordinary directory.") }
                    let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard next >= 0 else { throw Failure("inaccessible", "A containing directory could not be opened without following links.") }
                    var opened = stat()
                    guard fstat(next, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else {
                        close(next); throw Failure("precondition_failed", "A containing directory changed during resolution.")
                    }
                    close(fd); fd = next
                }
                return fd
            } catch { close(fd); throw error }
        }

        func preflight(request: Request) throws -> FileObservation? {
            var info = stat()
            if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                guard errno == ENOENT else { throw Failure("inaccessible", "The exact destination could not be inspected.") }
                guard request.expectedSHA256 == nil else { throw Failure("precondition_failed", "The expected existing file is missing.") }
                return nil
            }
            guard info.st_mode & S_IFMT != S_IFLNK else { throw Failure("symlink_traversal", "A symbolic-link destination is not writable through this tool.") }
            guard request.expectedSHA256 != nil else { throw Failure("precondition_failed", "The destination already exists; expected_absent was not satisfied.") }
            let observed = try readCurrent()
            guard ConduitFilesystemMutationService.sha(observed.data) == request.expectedSHA256 else {
                throw Failure("precondition_failed", "The current raw bytes differ from expected_sha256; read the current file before deciding on another edit.")
            }
            return observed
        }

        func checkUnchanged(request: Request, before: FileObservation?) throws {
            let currentParent = try Self.openParent(scope: scope, components: components)
            defer { close(currentParent) }
            var info = stat()
            guard fstat(currentParent, &info) == 0,
                  info.st_dev == parentIdentity.st_dev, info.st_ino == parentIdentity.st_ino else {
                throw Failure("precondition_failed", "The containing directory changed; no target replacement was attempted.")
            }
            let current = try preflight(request: request)
            if let before, let current {
                guard ConduitFilesystemMutationService.sameObservation(before.info, current.info),
                      before.data == current.data, before.provenance == current.provenance else {
                    throw Failure("precondition_failed", "The target identity, bytes or supported metadata changed during preflight.")
                }
            }
        }

        func readCurrent() throws -> FileObservation {
            try scope.requireCurrent()
            var named = stat()
            guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure("precondition_failed", "The target disappeared during observation.") }
            guard named.st_mode & S_IFMT != S_IFLNK else { throw Failure("symlink_traversal", "Symbolic-link destinations are not followed.") }
            guard named.st_mode & S_IFMT == S_IFREG else { throw Failure("unsupported", "Only ordinary regular files are eligible.") }
            let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw Failure("inaccessible", "The exact file could not be opened safely.") }
            defer { close(fd) }
            var before = stat()
            guard fstat(fd, &before) == 0, before.st_dev == named.st_dev, before.st_ino == named.st_ino else {
                throw Failure("precondition_failed", "The target identity changed while opening it.")
            }
            guard before.st_mode & S_IFMT == S_IFREG,
                  before.st_nlink == 1, before.st_uid == geteuid(),
                  before.st_mode & mode_t(0o6000) == 0,
                  before.st_mode & mode_t(0o200) != 0 else {
                throw Failure("protected_file", "Replacement requires one writable, owner-held regular file without hard links or privileged mode bits.")
            }
            let provenance = try ConduitFilesystemMutationService.requireOrdinaryMetadata(fd)
            let data = try ConduitFilesystemMutationService.readBounded(fd, maximum: ConduitFilesystemMutationService.maximumBytes)
            let afterProvenance = try ConduitFilesystemMutationService.requireOrdinaryMetadata(fd)
            var after = stat()
            guard fstat(fd, &after) == 0,
                  ConduitFilesystemMutationService.sameObservation(before, after),
                  provenance == afterProvenance else {
                throw Failure("precondition_failed", "The file or its supported metadata changed while its bytes were read.")
            }
            guard String(data: data, encoding: .utf8) != nil,
                  !data.contains(where: { $0 == 0 || ($0 < 32 && $0 != 9 && $0 != 10 && $0 != 13) }) else {
                throw Failure("unsupported", "The existing file is not ordinary UTF-8 text.")
            }
            return FileObservation(data: data, info: after, provenance: afterProvenance)
        }
    }

    private struct Receipt: Codable {
        var schema = "conduit-file-operation/v1"
        let operationID: String
        let project: String
        let path: String
        let rootIdentity: String
        let fingerprint: String
        let expectedSHA256: String?
        let beforeSHA256: String?
        let beforeBytes: Int?
        let requestedSHA256: String
        let requestedBytes: Int
        let stagingPath: String
        var state = "intent_recorded"
        var createdAt = ConduitFilesystemMutationService.timestamp()
        var finishedAt: String?
        var afterSHA256: String?
        var afterBytes: Int?
        var beforeBytesPreserved = false
        var mutationObserved = false
        var errorCode: String?
        var errorMessage: String?

        /// Codable establishes shape, not the operation-state invariants. A
        /// valid JSON object with a fabricated outcome remains corrupt state.
        var isValidRetainedState: Bool {
            guard schema == "conduit-file-operation/v1",
                  ConduitFilesystemMutationService.validID(operationID),
                  ConduitFilesystemMutationService.validProject(project),
                  !path.isEmpty, path.utf8.count <= 4096, !path.utf8.contains(0),
                  Self.validHash(rootIdentity), Self.validHash(fingerprint),
                  Self.validHash(requestedSHA256), Self.validBytes(requestedBytes),
                  Self.validTimestamp(createdAt) else { return false }
            if let finishedAt, !Self.validTimestamp(finishedAt) { return false }

            if let expectedSHA256 {
                guard Self.validHash(expectedSHA256), beforeSHA256 == expectedSHA256,
                      let beforeBytes, Self.validBytes(beforeBytes) else { return false }
                if mutationObserved && !beforeBytesPreserved { return false }
            } else if beforeSHA256 != nil || beforeBytes != nil || beforeBytesPreserved {
                return false
            }
            if let afterSHA256 {
                guard Self.validHash(afterSHA256), let afterBytes,
                      Self.validBytes(afterBytes) else { return false }
            } else if afterBytes != nil { return false }

            // Keep the decoded request fields bound to the retained reservation,
            // even if all of their individual JSON types were still valid.
            let fields: [String: String] = [
                "project": project, "path": path, "root_identity": rootIdentity,
                "expected": expectedSHA256 ?? "absent",
                "requested_sha256": requestedSHA256,
                "requested_bytes": String(requestedBytes),
            ]
            guard let encoded = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
                  ConduitFilesystemMutationService.sha(encoded) == fingerprint else { return false }

            let hasNoError = errorCode == nil && errorMessage == nil
            let hasError: Bool
            if let errorCode, let errorMessage {
                hasError = ConduitFilesystemMutationService.validID(errorCode)
                    && !errorMessage.isEmpty && errorMessage.utf8.count <= 2048
                    && !errorMessage.utf8.contains(0)
            } else { hasError = false }
            switch state {
            case "intent_recorded":
                return finishedAt == nil && afterSHA256 == nil
                    && !mutationObserved && hasNoError
            case "succeeded":
                return finishedAt != nil && mutationObserved && hasNoError
                    && afterSHA256 == requestedSHA256 && afterBytes == requestedBytes
            case "refused":
                return finishedAt != nil && !mutationObserved && hasError
                    && afterSHA256 == nil
            case "unknown":
                return finishedAt != nil && hasError
                    && (afterSHA256 == nil || mutationObserved)
            default:
                return false
            }
        }

        private static func validHash(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
        }

        private static func validBytes(_ value: Int) -> Bool {
            value >= 0 && value <= ConduitFilesystemMutationService.maximumBytes
        }

        private static func validTimestamp(_ value: String) -> Bool {
            guard !value.isEmpty, value.utf8.count <= 64 else { return false }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: value) != nil
        }

        func payload(replayed: Bool) -> [String: Any] {
            let unresolved = state == "intent_recorded"
            var result: [String: Any] = [
                "schema_version": schema, "operation_id": operationID,
                "project_slug": project, "path": path,
                "operation": expectedSHA256 == nil ? "create" : "replace",
                "status": unresolved ? "unknown" : state,
                "replayed": replayed, "created_at": createdAt,
                "requested_sha256": requestedSHA256, "requested_bytes": requestedBytes,
                "before": beforeSHA256.map { ["sha256": $0, "size_bytes": beforeBytes ?? 0] as [String: Any] } ?? ["absent": true],
                "mutation_observed": unresolved ? NSNull() : mutationObserved as Any,
                "mutation_possible": unresolved || mutationObserved,
                "current_call_mutation_observed": replayed ? false : mutationObserved,
                "before_bytes_preserved": beforeBytesPreserved,
                "receipt_currentness": "historical operation outcome; not a fresh file observation",
                "staging_path": stagingPath,
                "consistency": "optimistic hash/identity checks; no atomic compare-and-swap against external writers",
                "authority": "existing_session_write_gate_and_resolved_project",
                "verification": "bounded_filesystem_receipt_not_artifact_verification",
            ]
            if let finishedAt { result["finished_at"] = finishedAt }
            if let afterSHA256 { result["after"] = ["sha256": afterSHA256, "size_bytes": afterBytes ?? 0] }
            if unresolved {
                result["error_code"] = "interrupted_operation"
                result["error"] = "A durable intent exists without a completed outcome. The file may have changed; inspect it and do not automatically resubmit under a new ID."
            } else if let errorCode {
                result["error_code"] = errorCode
                result["error"] = errorMessage ?? errorCode
            }
            return result
        }
    }

    private enum Store {
        /// Pin the state parent before admission, then resolve the receipt
        /// directory relative to it. An absolute open with O_NOFOLLOW protects
        /// only the last component and would still follow a swapped parent.
        final class Location {
            let parent: Int32
            let name: String
            let canonicalPath: String
            private let configuredParentPath: String
            private let canonicalParentPath: String
            private let parentIdentity: stat
            private var storeIdentity: stat?
            private var pinnedStore: Int32 = -1

            init(_ url: URL) throws {
                let name = url.lastPathComponent
                guard url.isFileURL, !url.path.utf8.contains(0), !name.isEmpty, name != ".", name != "..",
                      !name.contains("/"), !name.utf8.contains(0) else {
                    throw Failure("receipt_store_unavailable", "Receipt storage requires one literal application-state directory name.")
                }
                let configuredParentPath = url.deletingLastPathComponent().path
                guard let resolved = realpath(configuredParentPath, nil) else {
                    throw Failure("receipt_store_unavailable", "An existing application-state parent is required for receipt storage.")
                }
                defer { free(resolved) }
                let canonicalParentPath = String(cString: resolved)
                let parent = open(canonicalParentPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard parent >= 0 else {
                    throw Failure("receipt_store_unavailable", "The application-state parent could not be opened safely.")
                }
                var info = stat()
                guard fstat(parent, &info) == 0 else {
                    close(parent)
                    throw Failure("receipt_store_unavailable", "The application-state parent identity could not be observed.")
                }
                self.parent = parent
                self.name = name
                self.configuredParentPath = configuredParentPath
                self.canonicalParentPath = canonicalParentPath
                self.canonicalPath = canonicalParentPath == "/" ? "/" + name : canonicalParentPath + "/" + name
                self.parentIdentity = info
                // All fields are initialized; deinit owns the descriptor even
                // if this final identity check throws.
                try requireCurrent()
            }

            deinit {
                if pinnedStore >= 0 { close(pinnedStore) }
                close(parent)
            }

            func requireCurrent() throws {
                guard let resolved = realpath(configuredParentPath, nil) else {
                    throw Failure("receipt_store_unavailable", "The application-state parent disappeared or moved during the operation.")
                }
                defer { free(resolved) }
                guard String(cString: resolved) == canonicalParentPath else {
                    throw Failure("receipt_store_unavailable", "The application-state parent was redirected during the operation.")
                }
                let current = open(canonicalParentPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard current >= 0 else {
                    throw Failure("receipt_store_unavailable", "The configured application-state parent is no longer available without following a link.")
                }
                defer { close(current) }
                var info = stat()
                guard fstat(current, &info) == 0,
                      info.st_dev == parentIdentity.st_dev, info.st_ino == parentIdentity.st_ino else {
                    throw Failure("receipt_store_unavailable", "The configured application-state parent now identifies another directory.")
                }
                if let storeIdentity {
                    var named = stat()
                    guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                          named.st_mode & S_IFMT == S_IFDIR,
                          named.st_dev == storeIdentity.st_dev, named.st_ino == storeIdentity.st_ino,
                          named.st_uid == geteuid(), named.st_mode & mode_t(0o077) == 0 else {
                        throw Failure("receipt_store_unavailable", "The retained receipt directory identity or private ownership changed during the operation.")
                    }
                }
            }

            func observeStore(_ info: stat, descriptor: Int32) throws {
                if let storeIdentity {
                    guard info.st_dev == storeIdentity.st_dev, info.st_ino == storeIdentity.st_ino else {
                        throw Failure("receipt_store_unavailable", "The receipt directory changed during the operation; a different ledger will not be used.")
                    }
                } else {
                    let pinned = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
                    guard pinned >= 0 else {
                        throw Failure("receipt_store_unavailable", "The observed receipt directory could not be retained safely.")
                    }
                    pinnedStore = pinned
                    storeIdentity = info
                }
                try requireCurrent()
            }
        }

        static func openExisting(_ location: Location) throws -> Int32? {
            try location.requireCurrent()
            let fd = openat(location.parent, location.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0, errno == ENOENT { return nil }
            guard fd >= 0 else { throw Failure("receipt_store_unavailable", "Receipt storage could not be opened without following a link.") }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & mode_t(0o077) == 0 else {
                close(fd); throw Failure("receipt_store_unavailable", "Receipt storage must be private and owned by the application user.")
            }
            do { try location.observeStore(info, descriptor: fd) }
            catch { close(fd); throw error }
            return fd
        }

        static func openForAdmittedWrite(_ location: Location, synchronizeParent: (Int32) -> Int32) throws -> Int32 {
            var opened = try openExisting(location)
            // The caller nominates application state, never a request path.
            // Its pinned parent must remain the same; this does not create
            // directories recursively or chmod an existing directory.
            if opened == nil {
                try location.requireCurrent()
                guard mkdirat(location.parent, location.name, mode_t(0o700)) == 0 || errno == EEXIST else {
                    throw Failure("receipt_store_unavailable", "The private receipt directory could not be created.")
                }
                opened = try openExisting(location)
            }
            guard let fd = opened else {
                throw Failure("receipt_store_unavailable", "The private receipt directory could not be created.")
            }
            do {
                try location.requireCurrent()
                // Flushing the child cannot establish durability of mkdir's
                // entry in this parent. Flush on admitted opens also to close
                // a race with another process creating the first directory.
                guard synchronizeParent(location.parent) == 0 else {
                    throw Failure("receipt_store_unavailable", "Receipt-directory durability in the application-state parent could not be established; no intent or target write was attempted.")
                }
                try location.requireCurrent()
                return fd
            } catch { close(fd); throw error }
        }

        static func checkCapacity(_ fd: Int32, maximumReceipts: Int, reserveBytes: Int) throws {
            let copy = fcntl(fd, F_DUPFD_CLOEXEC, 0)
            guard copy >= 0 else { throw Failure("receipt_store_unavailable", "Receipt capacity could not be inspected.") }
            guard let directory = fdopendir(copy) else { close(copy); throw Failure("receipt_store_unavailable", "Receipt capacity could not be inspected.") }
            defer { closedir(directory) }
            var entries = 0
            var records = 0
            var bytes = 0
            while let entry = readdir(directory) {
                let nameCapacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
                let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: nameCapacity) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                entries += 1
                guard entries <= maximumReceipts * 4 + 10 else { throw Failure("receipt_capacity", "Receipt storage reached its bounded entry limit; retained IDs were not pruned.") }
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                      info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0,
                      info.st_size <= ConduitFilesystemMutationService.maximumStoredBytes else {
                    throw Failure("receipt_store_unavailable", "Receipt storage contains an unexpected or unbounded object.")
                }
                bytes += Int(info.st_size)
                if name.hasSuffix(".reserved") { records += 1 }
                guard records < maximumReceipts, bytes + reserveBytes <= ConduitFilesystemMutationService.maximumStoredBytes else {
                    throw Failure("receipt_capacity", "Receipt retention is full; no IDs or preserved bytes were silently pruned.")
                }
            }
        }

        static func writeExclusive(_ fd: Int32, name: String, data: Data) throws {
            let output = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard output >= 0 else { throw Failure("receipt_persistence_failed", "An exclusive receipt/preimage file could not be created.") }
            defer { close(output) }
            try ConduitFilesystemMutationService.writeAll(output, data)
            guard fsync(output) == 0, fsync(fd) == 0 else { throw Failure("receipt_persistence_failed", "Receipt/preimage durability could not be established.") }
        }
    }

    private static func readReceipt(store: Int32, operationID: String) throws -> Receipt? {
        let fd = openat(store, key(operationID) + ".json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT {
            var reserved = stat()
            if fstatat(store, key(operationID) + ".reserved", &reserved, AT_SYMLINK_NOFOLLOW) == 0 {
                throw Failure("receipt_missing", "This ID was reserved but its receipt is missing. The operation will not be executed again.")
            }
            guard errno == ENOENT else { throw Failure("receipt_store_unavailable", "Operation reservation state could not be read.") }
            return nil
        }
        guard fd >= 0 else { throw Failure("receipt_corrupt", "The retained ID exists but its receipt cannot be read safely; it will not be reused.") }
        defer { close(fd) }
        let bytes: Data
        do {
            bytes = try readBounded(fd, maximum: maximumReceiptBytes)
        } catch {
            // This is retained operation state, not a new request's target.
            // A wrong type, size or failed read cannot prove that the earlier
            // operation never changed its file.
            throw Failure("receipt_corrupt", "The retained receipt is not a safely readable bounded regular file; this operation ID will not be reused.")
        }
        guard let receipt = try? JSONDecoder().decode(Receipt.self, from: bytes),
              receipt.operationID == operationID, receipt.isValidRetainedState else {
            throw Failure("receipt_corrupt", "The retained receipt is invalid; this operation ID will not be reused.")
        }
        let reservation = openat(store, key(operationID) + ".reserved", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard reservation >= 0 else { throw Failure("receipt_corrupt", "The receipt has no valid durable ID reservation; it will not be reused.") }
        defer { close(reservation) }
        let reservationBytes: Data
        do {
            reservationBytes = try readBounded(reservation, maximum: 64)
        } catch {
            throw Failure("receipt_corrupt", "The durable ID reservation is not a safely readable bounded regular file; this operation ID will not be reused.")
        }
        guard reservationBytes == Data(receipt.fingerprint.utf8) else {
            throw Failure("receipt_corrupt", "The receipt and durable ID reservation disagree; this ID will not be reused.")
        }
        return receipt
    }

    private static func requireOrdinaryMetadata(_ fd: Int32) throws -> Data? {
        #if canImport(Darwin)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_flags == 0 else {
            throw Failure("protected_file", "Files carrying filesystem flags require a separate mutation surface.")
        }
        // Preserve the one OS-supplied opaque attribute supported by this
        // writer. Every other attribute and all extended ACLs remain refused.
        let provenance = try readProvenance(fd)
        errno = 0
        if let acl = acl_get_fd(fd) {
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            var entry: acl_entry_t?
            // Darwin returns zero for an entry and -1/EINVAL at the end of a
            // valid ACL (Apple Libc posix1e/acl_entry.c).
            let entryResult = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
            guard entryResult == -1, errno == EINVAL else {
                throw Failure("unsupported_metadata", "An extended ACL requires a metadata-preserving writer.")
            }
            var flags: acl_flagset_t?
            guard acl_get_flagset_np(UnsafeMutableRawPointer(acl), &flags) == 0,
                  let flags,
                  acl_get_flag_np(flags, ACL_FLAG_DEFER_INHERIT) == 0,
                  acl_get_flag_np(flags, ACL_FLAG_NO_INHERIT) == 0 else {
                throw Failure("unsupported_metadata", "ACL inheritance flags require a metadata-preserving writer.")
            }
        } else if errno != 0 && errno != ENOENT {
            throw Failure("unsupported_metadata", "Extended ACL state could not be inspected.")
        }
        return provenance
        #else
        return nil
        #endif
    }

    private static let maximumMetadataBytes = 4096
    private static let provenanceName = "com.apple.provenance"

    private static func readProvenance(_ fd: Int32) throws -> Data? {
        #if canImport(Darwin)
        let present = try provenanceAttributePresent(fd)
        var value: Data?
        if present {
            var buffer = [UInt8](repeating: 0, count: maximumMetadataBytes)
            let count = buffer.withUnsafeMutableBytes {
                fgetxattr(fd, provenanceName, $0.baseAddress, maximumMetadataBytes, 0, 0)
            }
            // ENOATTR, ERANGE and all other errors are a failed observation,
            // never an absent or truncated attribute.
            guard count >= 0, count <= maximumMetadataBytes else {
                throw Failure("unsupported_metadata", "The opaque provenance could not be read completely within its 4096-byte bound.")
            }
            value = Data(buffer.prefix(count))
        }
        guard try provenanceAttributePresent(fd) == present else {
            throw Failure("unsupported_metadata", "The complete extended-attribute list changed while provenance was observed.")
        }
        return value
        #else
        return nil
        #endif
    }

    private static func provenanceAttributePresent(_ fd: Int32) throws -> Bool {
        #if canImport(Darwin)
        var buffer = [UInt8](repeating: 0, count: maximumMetadataBytes)
        let count = buffer.withUnsafeMutableBytes {
            flistxattr(fd, $0.baseAddress?.assumingMemoryBound(to: CChar.self), maximumMetadataBytes, 0)
        }
        guard count >= 0, count <= maximumMetadataBytes else {
            throw Failure("unsupported_metadata", "The complete extended-attribute list could not be read within its 4096-byte bound.")
        }
        if count == 0 { return false }
        // This validates the whole returned NUL-terminated list. A first-name
        // String(cString:) check could silently miss another attribute.
        guard Data(buffer.prefix(count)) == Data((provenanceName + "\u{0}").utf8) else {
            throw Failure("unsupported_metadata", "Only the exact opaque com.apple.provenance attribute is supported; all other or malformed extended-attribute lists are refused.")
        }
        return true
        #else
        return false
        #endif
    }

    private static func preserveProvenance(_ value: Data, on fd: Int32) throws {
        #if canImport(Darwin)
        guard value.count <= maximumMetadataBytes else {
            throw Failure("unsupported_metadata", "The prior opaque provenance exceeded its preservation bound.")
        }
        let result = value.withUnsafeBytes {
            fsetxattr(fd, provenanceName, $0.baseAddress, value.count, 0, 0)
        }
        guard result == 0, try readProvenance(fd) == value else {
            throw Failure("unsupported_metadata", "The prior opaque provenance could not be written and verified exactly on the staging inode.")
        }
        #else
        throw Failure("unsupported_metadata", "Opaque provenance preservation is unavailable on this filesystem platform.")
        #endif
    }

    private static func persist(_ receipt: Receipt, store: Int32) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(receipt)
        guard bytes.count <= maximumReceiptBytes else { throw Failure("receipt_persistence_failed", "The receipt exceeded its serialization bound.") }
        let staging = ".receipt-" + UUID().uuidString + ".tmp"
        defer { unlinkat(store, staging, 0) }
        try Store.writeExclusive(store, name: staging, data: bytes)
        guard renameat(store, staging, store, key(receipt.operationID) + ".json") == 0, fsync(store) == 0 else {
            throw Failure("receipt_persistence_failed", "The durable receipt could not be published.")
        }
    }

    private static func replay(_ receipt: Receipt, fingerprint: String) throws -> [String: Any] {
        guard receipt.fingerprint == fingerprint else {
            throw Failure("idempotency_conflict", "This operation ID already names a different request or project root; no file was changed.")
        }
        return receipt.payload(replayed: true)
    }

    private static func readBounded(_ fd: Int32, maximum: Int) throws -> Data {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw Failure("unsupported", "Only bounded regular files may be read.") }
        guard info.st_size >= 0, info.st_size <= maximum else { throw Failure("oversized", "The file exceeded the bounded byte limit.") }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while result.count <= maximum {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, min(8192, maximum + 1 - result.count)) }
            if count < 0 {
                if errno == EINTR { continue }
                throw Failure("io_error", "A bounded descriptor read failed.")
            }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        guard result.count <= maximum else { throw Failure("oversized", "The file grew beyond its bounded byte limit.") }
        return result
    }

    private static func writeAll(_ fd: Int32, _ bytes: Data) throws {
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure("io_error", "A bounded descriptor write failed.") }
                offset += count
            }
        }
    }

    private static func sameObservation(_ lhs: stat, _ rhs: stat) -> Bool {
        #if canImport(Darwin)
        let timesEqual = lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
        #else
        let timesEqual = lhs.st_mtim.tv_sec == rhs.st_mtim.tv_sec && lhs.st_mtim.tv_nsec == rhs.st_mtim.tv_nsec && lhs.st_ctim.tv_sec == rhs.st_ctim.tv_sec && lhs.st_ctim.tv_nsec == rhs.st_ctim.tv_nsec
        #endif
        return lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size && lhs.st_mode == rhs.st_mode && lhs.st_uid == rhs.st_uid && lhs.st_gid == rhs.st_gid && lhs.st_nlink == rhs.st_nlink && timesEqual
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
    private static func validProject(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && !value.utf8.contains(0)
    }
    private static func sha(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private static func key(_ operationID: String) -> String { sha(Data(operationID.utf8)) }
    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
    private static func failure(_ status: String, _ message: String, operationID: String? = nil) -> [String: Any] {
        // Failing to retrieve a receipt does not prove that the historical
        // operation did nothing. Report the current call's no-write separately.
        let historicalOutcomeUnknown: Set<String> = [
            "receipt_missing", "receipt_corrupt", "receipt_store_unavailable",
            "receipt_store_busy", "not_found", "idempotency_conflict",
            "operation_scope_conflict", "project_unavailable",
        ]
        let unknown = historicalOutcomeUnknown.contains(status)
        var payload: [String: Any] = [
            "schema_version": "conduit-file-operation/v1", "status": status, "error": message,
            "mutation_observed": unknown ? NSNull() : false as Any,
            "mutation_possible": unknown,
            "current_call_mutation_observed": false,
            "operation_outcome": unknown ? "unknown" : "not_started",
        ]
        if let operationID { payload["operation_id"] = operationID }
        return payload
    }
    private static func toolResult(_ payload: [String: Any]) -> [String: Any] {
        let bytes = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return ["isError": payload["error"] != nil, "structuredContent": payload,
                "content": [["type": "text", "text": bytes.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"]]]
    }
}
