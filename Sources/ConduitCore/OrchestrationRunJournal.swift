import Darwin
import Foundation

public struct OrchestrationJournalAppendReceipt: Equatable, Sendable {
    public let event: OrchestrationJournalEvent
    public let appended: Bool
}

public struct OrchestrationRunRecovery: Equatable, Sendable {
    public let snapshot: OrchestrationRunSnapshot
    public let events: [OrchestrationJournalEvent]
    public let journalDigest: String
    public let validatedCheckpointID: UUID?
}

public struct OrchestrationRunCheckpoint: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let id: UUID
    public let runID: OrchestrationRunID
    public let journalDigest: String
    public let snapshot: OrchestrationRunSnapshot
    public init(schemaVersion: Int = currentSchemaVersion, id: UUID, runID: OrchestrationRunID,
                journalDigest: String, snapshot: OrchestrationRunSnapshot) {
        self.schemaVersion = schemaVersion; self.id = id; self.runID = runID
        self.journalDigest = journalDigest; self.snapshot = snapshot
    }
}

/// One explicitly chosen, private local directory. There is no operator-home
/// default, runtime launch, implicit recovery repair, truncation or deletion API.
/// Cooperating readers/writers use nonblocking locks on the same named inode.
/// Same-user hostile mutation, power loss and provider persistence are excluded.
public struct OrchestrationRunJournal: Sendable {
    public static let maximumBytes = 8 * 1_024 * 1_024
    public static let maximumEvents = 1_024
    public static let maximumRecordBytes = 256 * 1_024
    public let directory: URL
    public let runID: OrchestrationRunID
    public var journalURL: URL { directory.appendingPathComponent(journalName) }
    private var journalName: String { runID.rawValue.uuidString.lowercased() + ".run.jsonl" }

    public init(directory: URL, runID: OrchestrationRunID) {
        self.directory = directory.standardizedFileURL; self.runID = runID
    }
    public func checkpointURL(id: UUID) -> URL {
        directory.appendingPathComponent(checkpointName(id))
    }
    private func checkpointName(_ id: UUID) -> String {
        runID.rawValue.uuidString.lowercased() + ".checkpoint-" + id.uuidString.lowercased() + ".json"
    }

    /// A retry of the exact command returns its original event, even if later
    /// commands advanced the journal. Another command with that ID is refused.
    @discardableResult
    public func append(_ command: OrchestrationJournalCommand, eventID: UUID,
                       recordedAt: Date) throws -> OrchestrationJournalAppendReceipt {
        guard command.runID == runID, command.expectedRevision >= 0,
              command.expectedRevision < Self.maximumEvents,
              recordedAt.timeIntervalSince1970.isFinite else {
            throw OrchestrationJournalError.invalidCommand("Invalid command identity, revision or time.")
        }
        // Validate a first command before creating any file. A stale create is
        // still checked again under the exact journal's lock below.
        if case .create = command.action {
            let first = OrchestrationJournalEvent(id: eventID, runID: runID, sequence: 1,
                previousDigest: "", recordedAt: recordedAt, command: command)
            _ = try OrchestrationRunSnapshot.apply(first, to: nil)
            guard try OrchestrationJournalCodec.encode(first).count + 1 <= Self.maximumRecordBytes else {
                throw OrchestrationJournalError.boundExceeded
            }
        }
        return try withDirectory { directoryFD in
            let canCreate: Bool
            if case .create = command.action { canCreate = true } else { canCreate = false }
            return try withFile(directoryFD: directoryFD, name: journalName,
                                writable: true, create: canCreate) { descriptor, created in
                let data = try readAll(descriptor)
                let recovered: OrchestrationRunRecovery?
                if created {
                    guard data.isEmpty else { throw OrchestrationJournalError.corruptHistory("New journal is not empty.") }
                    recovered = nil
                } else { recovered = try replay(data) }
                let events = recovered?.events ?? []
                if let recorded = events.first(where: { $0.command.id == command.id }) {
                    guard recorded.command == command,
                          !events.contains(where: { $0.id == eventID && $0.command.id != command.id }) else {
                        throw OrchestrationJournalError.identityCollision("Conflicting retry or event identity.")
                    }
                    return OrchestrationJournalAppendReceipt(event: recorded, appended: false)
                }
                guard !events.contains(where: { $0.id == eventID }) else {
                    throw OrchestrationJournalError.identityCollision("Event identity already belongs to another command.")
                }
                let current = recovered?.snapshot.revision ?? 0
                guard command.expectedRevision == current else {
                    throw OrchestrationJournalError.stale(expected: command.expectedRevision, actual: current)
                }
                guard events.count < Self.maximumEvents else { throw OrchestrationJournalError.boundExceeded }
                let previous = try events.last.map { OrchestrationJournalCodec.digest(try OrchestrationJournalCodec.encode($0)) } ?? ""
                let event = OrchestrationJournalEvent(id: eventID, runID: runID, sequence: current + 1,
                    previousDigest: previous, recordedAt: recordedAt, command: command)
                _ = try OrchestrationRunSnapshot.apply(event, to: recovered?.snapshot)
                let line = try OrchestrationJournalCodec.encode(event) + Data([10])
                guard line.count <= Self.maximumRecordBytes, data.count + line.count <= Self.maximumBytes else {
                    throw OrchestrationJournalError.boundExceeded
                }
                try validateNamedFile(directoryFD: directoryFD, name: journalName, descriptor: descriptor)
                try writeAll(line, descriptor: descriptor)
                try synchronize(descriptor)
                try synchronize(directoryFD)
                return OrchestrationJournalAppendReceipt(event: event, appended: true)
            }
        }
    }

    /// Missing, partial, malformed, conflicting or gapped history is unavailable.
    /// A selected checkpoint must match the complete replayed prefix exactly.
    public func recover(checkpointID: UUID? = nil) throws -> OrchestrationRunRecovery {
        try withDirectory { directoryFD in
            try withFile(directoryFD: directoryFD, name: journalName, writable: false, create: false) { descriptor, _ in
                let data = try readAll(descriptor)
                let recovery = try replay(data)
                guard let checkpointID else { return recovery }
                let checkpoint: OrchestrationRunCheckpoint = try withFile(
                    directoryFD: directoryFD, name: checkpointName(checkpointID), writable: false, create: false
                ) { checkpointFD, _ in
                    do { return try OrchestrationJournalCodec.decode(OrchestrationRunCheckpoint.self, data: readAll(checkpointFD)) }
                    catch { throw OrchestrationJournalError.invalidCheckpoint("Malformed checkpoint.") }
                }
                guard checkpoint.schemaVersion == OrchestrationRunCheckpoint.currentSchemaVersion,
                      checkpoint.id == checkpointID, checkpoint.runID == runID,
                      (1...recovery.snapshot.revision).contains(checkpoint.snapshot.revision) else {
                    throw OrchestrationJournalError.invalidCheckpoint("Wrong checkpoint schema, identity or revision.")
                }
                let lines = data.split(separator: 10, omittingEmptySubsequences: false)
                let prefix = lines.prefix(checkpoint.snapshot.revision).reduce(into: Data()) { result, line in
                    result.append(contentsOf: line); result.append(10)
                }
                let expected = try replay(prefix)
                guard checkpoint.journalDigest == expected.journalDigest,
                      checkpoint.snapshot == expected.snapshot else {
                    throw OrchestrationJournalError.invalidCheckpoint("Checkpoint cannot replace or alter source history.")
                }
                return OrchestrationRunRecovery(snapshot: recovery.snapshot, events: recovery.events,
                    journalDigest: recovery.journalDigest, validatedCheckpointID: checkpointID)
            }
        }
    }

    /// Checkpoints are immutable, exclusive-created records. An existing exact
    /// record is idempotent; changed history needs a new checkpoint identity.
    @discardableResult
    public func checkpoint(id: UUID, expectedRevision: Int) throws -> OrchestrationRunCheckpoint {
        try withDirectory { directoryFD in
            try withFile(directoryFD: directoryFD, name: journalName, writable: false, create: false) { descriptor, _ in
                let recovery = try replay(readAll(descriptor))
                guard recovery.snapshot.revision == expectedRevision else {
                    throw OrchestrationJournalError.stale(expected: expectedRevision, actual: recovery.snapshot.revision)
                }
                let checkpoint = OrchestrationRunCheckpoint(id: id, runID: runID,
                    journalDigest: recovery.journalDigest, snapshot: recovery.snapshot)
                let data = try OrchestrationJournalCodec.encode(checkpoint)
                guard data.count <= Self.maximumRecordBytes else { throw OrchestrationJournalError.boundExceeded }
                try withFile(directoryFD: directoryFD, name: checkpointName(id), writable: true, create: true) { checkpointFD, created in
                    if created {
                        try writeAll(data, descriptor: checkpointFD); try synchronize(checkpointFD)
                        try synchronize(directoryFD)
                    } else {
                        let existing = try readAll(checkpointFD)
                        guard existing == data else {
                            throw OrchestrationJournalError.identityCollision("Checkpoint identity already has other bytes.")
                        }
                    }
                }
                return checkpoint
            }
        }
    }

    private func replay(_ data: Data) throws -> OrchestrationRunRecovery {
        guard !data.isEmpty, data.last == 10 else {
            throw OrchestrationJournalError.corruptHistory("Empty or partial journal; no bytes were repaired.")
        }
        guard data.count <= Self.maximumBytes else { throw OrchestrationJournalError.boundExceeded }
        let lines = data.split(separator: 10, omittingEmptySubsequences: false).dropLast()
        guard lines.count <= Self.maximumEvents else { throw OrchestrationJournalError.boundExceeded }
        var events: [OrchestrationJournalEvent] = []
        var snapshot: OrchestrationRunSnapshot?
        var eventIDs = Set<UUID>(), commandIDs = Set<UUID>()
        var previous = ""
        for rawLine in lines {
            guard !rawLine.isEmpty, rawLine.count < Self.maximumRecordBytes else {
                throw OrchestrationJournalError.corruptHistory("Empty or oversized journal record.")
            }
            let line = Data(rawLine)
            let event: OrchestrationJournalEvent
            do { event = try OrchestrationJournalCodec.decode(OrchestrationJournalEvent.self, data: line) }
            catch { throw OrchestrationJournalError.corruptHistory("Malformed or noncanonical event.") }
            guard event.runID == runID, event.previousDigest == previous,
                  eventIDs.insert(event.id).inserted, commandIDs.insert(event.command.id).inserted else {
                throw OrchestrationJournalError.corruptHistory("Wrong identity, predecessor or duplicate record.")
            }
            do { snapshot = try OrchestrationRunSnapshot.apply(event, to: snapshot) }
            catch { throw OrchestrationJournalError.corruptHistory("Unprojectable event: \(error)") }
            events.append(event); previous = OrchestrationJournalCodec.digest(line)
        }
        guard let snapshot else { throw OrchestrationJournalError.corruptHistory("Missing run creation.") }
        return OrchestrationRunRecovery(snapshot: snapshot, events: events,
            journalDigest: OrchestrationJournalCodec.digest(data), validatedCheckpointID: nil)
    }

    private func withDirectory<T>(_ body: (Int32) throws -> T) throws -> T {
        let descriptor = directory.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
        guard descriptor >= 0 else { throw errorFromErrno() }
        defer { _ = Darwin.close(descriptor) }
        func validate() throws {
            var opened = stat(), named = stat()
            guard Darwin.fstat(descriptor, &opened) == 0,
                  directory.path.withCString({ Darwin.lstat($0, &named) }) == 0,
                  opened.st_dev == named.st_dev, opened.st_ino == named.st_ino,
                  opened.st_uid == getuid(), opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  opened.st_mode & 0o777 == 0o700 else {
                throw OrchestrationJournalError.unsafeStorage("Directory identity, owner or private mode is unavailable.")
            }
        }
        try validate(); let result = try body(descriptor); try validate(); return result
    }

    private func withFile<T>(directoryFD: Int32, name: String, writable: Bool, create: Bool,
                             _ body: (Int32, Bool) throws -> T) throws -> T {
        let flags = (writable ? O_RDWR | O_APPEND : O_RDONLY) | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        var created = false
        var descriptor: Int32 = -1
        if create {
            descriptor = name.withCString { Darwin.openat(directoryFD, $0, flags | O_CREAT | O_EXCL, 0o600) }
            if descriptor >= 0 { created = true }
            else if errno != EEXIST { throw errorFromErrno() }
        }
        if descriptor < 0 { descriptor = name.withCString { Darwin.openat(directoryFD, $0, flags) } }
        guard descriptor >= 0 else { throw errorFromErrno() }
        defer { _ = Darwin.close(descriptor) }
        try validateNamedFile(directoryFD: directoryFD, name: name, descriptor: descriptor)
        guard flock(descriptor, (writable ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN { throw OrchestrationJournalError.busy }
            throw errorFromErrno()
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        try validateNamedFile(directoryFD: directoryFD, name: name, descriptor: descriptor)
        let result = try body(descriptor, created)
        try validateNamedFile(directoryFD: directoryFD, name: name, descriptor: descriptor)
        return result
    }

    private func validateNamedFile(directoryFD: Int32, name: String, descriptor: Int32) throws {
        var opened = stat(), named = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              name.withCString({ Darwin.fstatat(directoryFD, $0, &named, AT_SYMLINK_NOFOLLOW) }) == 0,
              opened.st_dev == named.st_dev, opened.st_ino == named.st_ino,
              opened.st_uid == getuid(), opened.st_nlink == 1,
              opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), opened.st_mode & 0o777 == 0o600 else {
            throw OrchestrationJournalError.unsafeStorage("Journal/checkpoint identity, regular-file owner or private mode is unavailable.")
        }
    }
    private func readAll(_ descriptor: Int32) throws -> Data {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else { throw errorFromErrno() }
        guard status.st_size <= Self.maximumBytes else { throw OrchestrationJournalError.boundExceeded }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        var offset: off_t = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.pread(descriptor, $0.baseAddress, $0.count, offset) }
            if count == 0 { return result }
            if count < 0 { if errno == EINTR { continue }; throw errorFromErrno() }
            result.append(contentsOf: buffer.prefix(count)); offset += off_t(count)
            guard result.count <= Self.maximumBytes else { throw OrchestrationJournalError.boundExceeded }
        }
    }
    private func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw errorFromErrno() }
                guard count > 0 else { throw OrchestrationJournalError.unavailable(EIO) }
                offset += count
            }
        }
    }
    private func synchronize(_ descriptor: Int32) throws {
        while Darwin.fsync(descriptor) != 0 {
            if errno != EINTR { throw errorFromErrno() }
        }
    }
    private func errorFromErrno() -> OrchestrationJournalError {
        errno == ENOENT ? .missing : .unavailable(errno)
    }
}
