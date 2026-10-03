import Foundation
import Darwin

/// Declarative discovery requests retained as operator state. Storing a rule
/// does not run it, read its source, or admit any resulting item to a worker.
public enum ContextSetDynamicSource: String, Codable, CaseIterable, Sendable {
    case gitWorkingTree
    case latestReceipt
    case lexicalQuery
    case semanticQuery
    case authoredLinks
    case taskArtifacts
}

public struct ContextSetDynamicRule: Equatable, Codable, Sendable {
    public let id: String
    public let source: ContextSetDynamicSource
    public let scopeReference: String
    public let query: String?

    public init(id: String, source: ContextSetDynamicSource, scopeReference: String, query: String? = nil) {
        self.id = id
        self.source = source
        self.scopeReference = scopeReference
        self.query = query
    }
}

public enum ContextSetRecordState: String, Codable, Sendable {
    case active
    case retired
}

/// One immutable revision of an operator Context Set definition. The existing
/// ContextSet owns fixed references and their provenance. This record adds
/// persistence identity and declarative dynamic rules, not a second compiler.
public struct ContextSetRevision: Equatable, Codable, Sendable {
    public let schemaVersion: Int
    public let sequence: Int
    public let revisionID: UUID
    public let parentRevisionID: UUID?
    public let recordedAt: Date
    public let state: ContextSetRecordState
    public let contextSet: ContextSet
    public let dynamicRules: [ContextSetDynamicRule]

    fileprivate init(sequence: Int, parentRevisionID: UUID?, recordedAt: Date,
                     state: ContextSetRecordState, contextSet: ContextSet,
                     dynamicRules: [ContextSetDynamicRule]) {
        self.schemaVersion = 1
        self.sequence = sequence
        self.revisionID = UUID()
        self.parentRevisionID = parentRevisionID
        self.recordedAt = recordedAt
        self.state = state
        self.contextSet = contextSet
        self.dynamicRules = dynamicRules
    }

    /// The unchanged compiler can inspect fixed references. Each unresolved
    /// dynamic rule remains a prerequisite, rather than disappearing from the
    /// manifest or being reported as retrieved context.
    public var compilerInput: ContextSet {
        ContextSet(
            id: contextSet.id, objective: contextSet.objective,
            taskIdentity: contextSet.taskIdentity,
            repositoryIdentity: contextSet.repositoryIdentity,
            entries: contextSet.entries,
            unresolvedPrerequisites: contextSet.unresolvedPrerequisites
                + dynamicRules.map { "Unresolved dynamic context rule: \($0.id) (\($0.source.rawValue))" },
            retrieverVersions: contextSet.retrieverVersions
        )
    }
}

public struct ContextSetStoreState: Equatable, Sendable {
    public let history: [ContextSetRevision]

    public var latestRevisions: [ContextSetRevision] {
        var latest: [String: ContextSetRevision] = [:]
        for record in history { latest[record.contextSet.id] = record }
        return latest.values.sorted { $0.contextSet.id < $1.contextSet.id }
    }

    public var activeRevisions: [ContextSetRevision] {
        latestRevisions.filter { $0.state == .active }
    }

    public func latest(contextSetID: String) -> ContextSetRevision? {
        history.last { $0.contextSet.id == contextSetID }
    }
}

public enum ContextSetStoreError: LocalizedError, Equatable {
    case invalidDefinition(String)
    case invalidLedger(line: Int, detail: String)
    case unsafePath(String)
    case sizeLimit(String)
    case revisionConflict(contextSetID: String, expected: UUID?, actual: UUID?)
    case notFound(String)
    case retired(String)
    case appendOutcomeUnknown(revisionID: UUID, errorCode: Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidDefinition(let detail): return "Invalid Context Set definition: \(detail)"
        case .invalidLedger(let line, let detail): return "Context Set history is unavailable at line \(line): \(detail). Preserve the file; no prefix was adopted."
        case .unsafePath(let path): return "Context Set state path is not a private owned regular file/directory: \(path)"
        case .sizeLimit(let detail): return "Context Set state limit exceeded: \(detail)"
        case .revisionConflict(let id, let expected, let actual):
            return "Context Set \(id) revision conflict: expected \(expected?.uuidString ?? "absent"), observed \(actual?.uuidString ?? "absent")."
        case .notFound(let id): return "Context Set not found: \(id)"
        case .retired(let id): return "Context Set is retired: \(id). Its identity cannot be reused."
        case .appendOutcomeUnknown(let revision, let code): return "Context Set append/durability outcome UNKNOWN for revision \(revision.uuidString), errno \(code). Reconcile the preserved history before retrying."
        }
    }
}

/// Explicit, append-only Conduit operator state. Reads never create state.
/// Mutations check the complete history and the exact parent revision while
/// holding a POSIX file lock, then append and fsync one revision. A malformed
/// history blocks both read and write; there is no healing or prefix fallback.
/// AgentContextSnapshotStore remains the separate actual-handoff snapshot store.
public struct ContextSetStore: Sendable {
    public static let filename = "context-sets.jsonl"
    public static let maximumLedgerBytes = 16 * 1_024 * 1_024
    public static let maximumRecordBytes = 1_024 * 1_024
    public static let maximumRecords = 10_000
    public let directory: URL

    public init(directory: URL) { self.directory = directory.standardizedFileURL }

    public func read() throws -> ContextSetStoreState {
        try withDescriptor(writing: false) { descriptor in
            guard let descriptor else { return ContextSetStoreState(history: []) }
            return try replay(try readBytes(descriptor))
        }
    }

    /// A nil expected revision means create only. An existing identity is never
    /// overwritten, including when the payload happens to be identical.
    @discardableResult
    public func save(_ contextSet: ContextSet, dynamicRules: [ContextSetDynamicRule] = [],
                     expectedRevision: UUID? = nil, at date: Date = Date()) throws -> ContextSetRevision {
        try validate(contextSet, rules: dynamicRules)
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw ContextSetStoreError.invalidDefinition("record date must be finite")
        }
        return try append(allowCreation: expectedRevision == nil) { state in
            let previous = state.latest(contextSetID: contextSet.id)
            guard previous?.revisionID == expectedRevision else {
                throw ContextSetStoreError.revisionConflict(contextSetID: contextSet.id,
                    expected: expectedRevision, actual: previous?.revisionID)
            }
            if previous?.state == .retired { throw ContextSetStoreError.retired(contextSet.id) }
            return ContextSetRevision(sequence: state.history.count + 1,
                parentRevisionID: expectedRevision, recordedAt: date, state: .active,
                contextSet: contextSet, dynamicRules: dynamicRules)
        }
    }

    /// Retirement appends a tombstone retaining the exact prior definition.
    /// It does not delete context references, source files or handoff snapshots.
    @discardableResult
    public func retire(contextSetID: String, expectedRevision: UUID,
                       at date: Date = Date()) throws -> ContextSetRevision {
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw ContextSetStoreError.invalidDefinition("record date must be finite")
        }
        return try append(allowCreation: false) { state in
            guard let previous = state.latest(contextSetID: contextSetID) else {
                throw ContextSetStoreError.notFound(contextSetID)
            }
            guard previous.revisionID == expectedRevision else {
                throw ContextSetStoreError.revisionConflict(contextSetID: contextSetID,
                    expected: expectedRevision, actual: previous.revisionID)
            }
            guard previous.state == .active else { throw ContextSetStoreError.retired(contextSetID) }
            return ContextSetRevision(sequence: state.history.count + 1,
                parentRevisionID: expectedRevision, recordedAt: date, state: .retired,
                contextSet: previous.contextSet, dynamicRules: previous.dynamicRules)
        }
    }

    private func append(allowCreation: Bool, _ makeRecord: (ContextSetStoreState) throws -> ContextSetRevision) throws -> ContextSetRevision {
        var appendingRevision: UUID?
        do { return try withDescriptor(writing: true, allowCreation: allowCreation) { descriptor in
            let before = try descriptor.map { try readBytes($0) } ?? Data()
            let state = try replay(before)
            guard state.history.count < Self.maximumRecords else {
                throw ContextSetStoreError.sizeLimit("maximum \(Self.maximumRecords) retained revisions; no history pruning")
            }
            let record = try makeRecord(state)
            guard let descriptor else { throw ContextSetStoreError.unsafePath(directory.path) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var bytes = try encoder.encode(record)
            guard bytes.count <= Self.maximumRecordBytes else {
                throw ContextSetStoreError.sizeLimit("record exceeds \(Self.maximumRecordBytes) bytes")
            }
            bytes.append(0x0a)
            guard before.count + bytes.count <= Self.maximumLedgerBytes else {
                throw ContextSetStoreError.sizeLimit("history exceeds \(Self.maximumLedgerBytes) bytes")
            }
            appendingRevision = record.revisionID
            try bytes.withUnsafeBytes { buffer in
                guard let start = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(descriptor, start.advanced(by: offset), buffer.count - offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else {
                        throw ContextSetStoreError.appendOutcomeUnknown(revisionID: record.revisionID,
                            errorCode: written < 0 ? errno : EIO)
                    }
                    offset += written
                }
            }
            while Darwin.fsync(descriptor) != 0 {
                if errno == EINTR { continue }
                throw ContextSetStoreError.appendOutcomeUnknown(revisionID: record.revisionID, errorCode: errno)
            }
            return record
        } } catch let error as ContextSetStoreError {
            if case .unsafePath = error, let revision = appendingRevision {
                throw ContextSetStoreError.appendOutcomeUnknown(revisionID: revision, errorCode: EIO)
            }
            throw error
        }
    }

    private func replay(_ bytes: Data) throws -> ContextSetStoreState {
        guard !bytes.isEmpty else { return ContextSetStoreState(history: []) }
        guard bytes.last == 0x0a else {
            throw ContextSetStoreError.invalidLedger(line: bytes.filter { $0 == 0x0a }.count + 1,
                detail: "unterminated/torn record")
        }
        let lines = bytes.dropLast().split(separator: 0x0a, omittingEmptySubsequences: false)
        guard lines.count <= Self.maximumRecords else { throw ContextSetStoreError.sizeLimit("too many retained revisions") }
        var history: [ContextSetRevision] = []
        var latest: [String: ContextSetRevision] = [:]
        var revisions = Set<UUID>()
        let decoder = JSONDecoder()
        for (index, line) in lines.enumerated() {
            do {
                guard !line.isEmpty, line.count <= Self.maximumRecordBytes else {
                    throw ContextSetStoreError.invalidDefinition("empty/oversized record")
                }
                let data = Data(line)
                var scanner = ContextSetJSONKeyScanner(bytes: Array(data))
                try scanner.validate()
                _ = try JSONSerialization.jsonObject(with: data)
                let record = try decoder.decode(ContextSetRevision.self, from: data)
                guard record.schemaVersion == 1 else { throw ContextSetStoreError.invalidDefinition("unsupported schema version") }
                guard record.sequence == index + 1 else { throw ContextSetStoreError.invalidDefinition("noncontiguous global sequence") }
                guard revisions.insert(record.revisionID).inserted else { throw ContextSetStoreError.invalidDefinition("duplicate revision identity") }
                guard record.recordedAt.timeIntervalSinceReferenceDate.isFinite else { throw ContextSetStoreError.invalidDefinition("nonfinite record date") }
                try validate(record.contextSet, rules: record.dynamicRules)
                let previous = latest[record.contextSet.id]
                guard record.parentRevisionID == previous?.revisionID else { throw ContextSetStoreError.invalidDefinition("wrong parent revision") }
                if let previous {
                    guard previous.state == .active else { throw ContextSetStoreError.invalidDefinition("retired identity reused") }
                    if record.state == .retired {
                        guard record.contextSet == previous.contextSet, record.dynamicRules == previous.dynamicRules else {
                            throw ContextSetStoreError.invalidDefinition("retirement changed the prior definition")
                        }
                    }
                } else {
                    guard record.state == .active else { throw ContextSetStoreError.invalidDefinition("retirement without an active predecessor") }
                }
                latest[record.contextSet.id] = record
                history.append(record)
            } catch {
                throw ContextSetStoreError.invalidLedger(line: index + 1, detail: error.localizedDescription)
            }
        }
        return ContextSetStoreState(history: history)
    }

    private func validate(_ contextSet: ContextSet, rules: [ContextSetDynamicRule]) throws {
        func present(_ value: String) -> Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard present(contextSet.id) else { throw ContextSetStoreError.invalidDefinition("blank set identity") }
        guard contextSet.entries.count <= 10_000, rules.count <= 256 else { throw ContextSetStoreError.invalidDefinition("too many references/rules") }
        var ids = Set<String>()
        for entry in contextSet.entries {
            guard present(entry.item.id), present(entry.item.sourceReference), ids.insert(entry.item.id).inserted else {
                throw ContextSetStoreError.invalidDefinition("blank or colliding fixed reference identity")
            }
            if let tokens = entry.item.estimatedTokens, tokens < 0 { throw ContextSetStoreError.invalidDefinition("negative token estimate") }
        }
        var ruleIDs = Set<String>()
        for rule in rules {
            guard present(rule.id), present(rule.scopeReference), ruleIDs.insert(rule.id).inserted else {
                throw ContextSetStoreError.invalidDefinition("blank or colliding dynamic rule identity/scope")
            }
            if rule.source == .semanticQuery || rule.source == .lexicalQuery {
                guard let query = rule.query, present(query) else { throw ContextSetStoreError.invalidDefinition("query rule needs an explicit query") }
            }
        }
    }

    private func readBytes(_ descriptor: Int32) throws -> Data {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else { throw posixError() }
        guard metadata.st_size >= 0, metadata.st_size <= Self.maximumLedgerBytes else {
            throw ContextSetStoreError.sizeLimit("history exceeds \(Self.maximumLedgerBytes) bytes")
        }
        var bytes = Data(count: Int(metadata.st_size))
        try bytes.withUnsafeMutableBytes { buffer in
            guard let start = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.pread(descriptor, start.advanced(by: offset), buffer.count - offset, off_t(offset))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw posixError(code: count < 0 ? errno : EIO) }
                offset += count
            }
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0 else { throw posixError() }
        guard after.st_size == metadata.st_size else { throw ContextSetStoreError.invalidLedger(line: 0, detail: "file changed during read") }
        return bytes
    }

    private func withDescriptor<T>(writing: Bool, allowCreation: Bool = false, _ body: (Int32?) throws -> T) throws -> T {
        var metadata = stat()
        if directory.path.withCString({ Darwin.lstat($0, &metadata) }) != 0 {
            guard errno == ENOENT else { throw posixError() }
            guard writing && allowCreation else { return try body(nil) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        let directoryDescriptor = directory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard directoryDescriptor >= 0 else { throw ContextSetStoreError.unsafePath(directory.path) }
        defer { _ = Darwin.close(directoryDescriptor) }
        guard Darwin.fstat(directoryDescriptor, &metadata) == 0 else { throw posixError() }
        guard metadata.st_uid == geteuid(), metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_mode & 0o077 == 0 else {
            throw ContextSetStoreError.unsafePath(directory.path)
        }
        let openedDirectory = metadata
        let flags = (writing ? O_RDWR | O_APPEND : O_RDONLY)
            | (allowCreation ? O_CREAT : 0) | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        let descriptor = Self.filename.withCString { Darwin.openat(directoryDescriptor, $0, flags, mode_t(0o600)) }
        if descriptor < 0 {
            if !allowCreation, errno == ENOENT { return try body(nil) }
            throw posixError()
        }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fstat(descriptor, &metadata) == 0 else { throw posixError() }
        guard metadata.st_uid == geteuid(), metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_nlink == 1, metadata.st_mode & 0o077 == 0 else {
            throw ContextSetStoreError.unsafePath(directory.appendingPathComponent(Self.filename).path)
        }
        while flock(descriptor, writing ? LOCK_EX : LOCK_SH) != 0 {
            if errno == EINTR { continue }
            throw posixError()
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        func validateBinding() throws {
            var currentDirectory = stat()
            var openedFile = stat()
            var namedFile = stat()
            guard directory.path.withCString({ Darwin.lstat($0, &currentDirectory) }) == 0,
                  currentDirectory.st_dev == openedDirectory.st_dev,
                  currentDirectory.st_ino == openedDirectory.st_ino,
                  currentDirectory.st_mode & S_IFMT == S_IFDIR,
                  currentDirectory.st_uid == geteuid(), currentDirectory.st_mode & 0o077 == 0,
                  Darwin.fstat(descriptor, &openedFile) == 0,
                  Self.filename.withCString({ Darwin.fstatat(directoryDescriptor, $0, &namedFile, AT_SYMLINK_NOFOLLOW) }) == 0,
                  namedFile.st_dev == openedFile.st_dev, namedFile.st_ino == openedFile.st_ino,
                  openedFile.st_uid == geteuid(), openedFile.st_mode & S_IFMT == S_IFREG,
                  openedFile.st_nlink == 1, openedFile.st_mode & 0o077 == 0 else {
                throw ContextSetStoreError.unsafePath(directory.appendingPathComponent(Self.filename).path)
            }
        }
        // A writer may have waited on an inode that has since moved out of the
        // supplied state directory. A lock on that old inode grants no write
        // authority over the replacement named ledger.
        try validateBinding()
        let result = try body(descriptor)
        try validateBinding()
        return result
    }

    private func posixError(code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code),
            userInfo: [NSFilePathErrorKey: directory.appendingPathComponent(Self.filename).path])
    }
}

/// JSONDecoder/Foundation accept repeated object members. Check the original
/// bytes first, including escaped-equivalent keys inside nested definitions.
private struct ContextSetJSONKeyScanner {
    let bytes: [UInt8]
    var cursor = 0

    mutating func validate() throws {
        try value(depth: 0)
        whitespace()
        guard cursor == bytes.count else { throw invalid("trailing JSON data") }
    }

    private mutating func value(depth: Int) throws {
        guard depth <= 128 else { throw invalid("JSON nesting limit") }
        whitespace()
        guard cursor < bytes.count else { throw invalid("missing JSON value") }
        switch bytes[cursor] {
        case 0x7b:
            cursor += 1
            whitespace()
            if consume(0x7d) { return }
            var keys = Set<String>()
            while true {
                whitespace()
                let raw = try string()
                let key = try JSONDecoder().decode(String.self, from: raw)
                guard keys.insert(key).inserted else { throw invalid("duplicate JSON member: \(key)") }
                whitespace()
                guard consume(0x3a) else { throw invalid("missing member separator") }
                try value(depth: depth + 1)
                whitespace()
                if consume(0x7d) { return }
                guard consume(0x2c) else { throw invalid("missing object separator") }
            }
        case 0x5b:
            cursor += 1
            whitespace()
            if consume(0x5d) { return }
            while true {
                try value(depth: depth + 1)
                whitespace()
                if consume(0x5d) { return }
                guard consume(0x2c) else { throw invalid("missing array separator") }
            }
        case 0x22: _ = try string()
        default:
            let start = cursor
            while cursor < bytes.count, ![UInt8(0x2c), 0x5d, 0x7d, 0x20, 0x09, 0x0a, 0x0d].contains(bytes[cursor]) { cursor += 1 }
            guard cursor > start else { throw invalid("empty JSON scalar") }
        }
    }

    private mutating func string() throws -> Data {
        guard consume(0x22) else { throw invalid("object member must be a string") }
        let start = cursor - 1
        while cursor < bytes.count {
            let byte = bytes[cursor]
            cursor += 1
            if byte == 0x22 { return Data(bytes[start..<cursor]) }
            if byte == 0x5c {
                guard cursor < bytes.count else { throw invalid("incomplete JSON escape") }
                cursor += 1
            }
        }
        throw invalid("unterminated JSON string")
    }

    private mutating func whitespace() {
        while cursor < bytes.count, [UInt8(0x20), 0x09, 0x0a, 0x0d].contains(bytes[cursor]) { cursor += 1 }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard cursor < bytes.count, bytes[cursor] == byte else { return false }
        cursor += 1
        return true
    }

    private func invalid(_ detail: String) -> ContextSetStoreError { .invalidDefinition(detail) }
}
