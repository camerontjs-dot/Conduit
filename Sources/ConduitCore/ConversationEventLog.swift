import Darwin
import Foundation

public enum ConversationEventLogError: Error, Equatable, Sendable {
    case invalidAuthority(eventID: UUID)
}

public enum ConversationEventLogDiagnosticKind: String, Codable, Equatable, Sendable {
    case malformedLine
    case unsupportedSchemaVersion
    case mismatchedTaskSessionID
    case invalidAuthority
    case invalidRevision
    case unreadableLog
}

public struct ConversationEventLogDiagnostic: Equatable, Sendable {
    public let kind: ConversationEventLogDiagnosticKind
    public let fileURL: URL
    public let lineNumber: Int?
    public let detail: String

    public init(
        kind: ConversationEventLogDiagnosticKind,
        fileURL: URL,
        lineNumber: Int? = nil,
        detail: String
    ) {
        self.kind = kind
        self.fileURL = fileURL
        self.lineNumber = lineNumber
        self.detail = detail
    }
}

public struct ConversationEventLogReadResult: Equatable, Sendable {
    public let events: [SessionPresentationEvent]
    public let diagnostics: [ConversationEventLogDiagnostic]

    public init(
        events: [SessionPresentationEvent],
        diagnostics: [ConversationEventLogDiagnostic]
    ) {
        self.events = events
        self.diagnostics = diagnostics
    }
}

/// One append-only conversation source for one durable task identity.
///
/// Every JSONL line is a complete immutable revision of a presentation event.
/// Projection keeps the first valid appearance of each event in timeline order
/// while using its latest valid revision. The source file is never rewritten
/// or truncated during append or recovery.
public struct ConversationEventLog: Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let directory: URL
    public let taskSessionID: TaskSessionID
    public let url: URL

    private struct Record: Codable {
        let schemaVersion: Int
        let taskSessionID: TaskSessionID
        let recordedAt: Date
        let event: SessionPresentationEvent
    }

    private struct SchemaEnvelope: Decodable {
        let schemaVersion: Int
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public init(directory: URL, taskSessionID: TaskSessionID) {
        self.directory = directory.standardizedFileURL
        self.taskSessionID = taskSessionID
        self.url = self.directory.appendingPathComponent(
            "\(Self.stableKey(taskSessionID)).jsonl"
        )
    }

    /// Appends one complete event revision and synchronizes it to disk.
    ///
    /// If an earlier writer stopped mid-line, append inserts a separating
    /// newline. The torn bytes remain in the file and are diagnosed on read.
    public func append(_ event: SessionPresentationEvent) throws {
        guard Self.hasValidAuthority(event) else {
            throw ConversationEventLogError.invalidAuthority(eventID: event.id)
        }

        let record = Record(
            schemaVersion: Self.currentSchemaVersion,
            taskSessionID: taskSessionID,
            recordedAt: Date(),
            event: event
        )
        let line = try Self.makeEncoder().encode(record) + Data("\n".utf8)

        try Self.withPrivateDirectoryDescriptor(
            directory,
            createIfMissing: true
        ) { directoryDescriptor, directoryWasCreated in
            try Self.withExclusiveAppendDescriptor(
                directoryDescriptor: directoryDescriptor,
                fileName: url.lastPathComponent,
                url: url
            ) { descriptor, fileWasCreated in
                let end = Darwin.lseek(descriptor, 0, SEEK_END)
                guard end >= 0 else {
                    throw Self.posixError(
                        operation: "Inspect conversation log",
                        url: url
                    )
                }

                var payload = Data()
                if end > 0 {
                    let lastByte = try Self.byte(
                        at: end - 1,
                        descriptor: descriptor,
                        url: url
                    )
                    if lastByte != UInt8(ascii: "\n") {
                        payload.append(UInt8(ascii: "\n"))
                    }
                }
                payload.append(line)
                try Self.writeAll(payload, descriptor: descriptor, url: url)
                try Self.synchronize(descriptor: descriptor, url: url)

                // fsync on the file does not itself make a newly-created
                // directory entry durable. Synchronize the containing
                // directory before reporting a successful first append.
                if fileWasCreated {
                    try Self.synchronize(
                        descriptor: directoryDescriptor,
                        url: directory
                    )
                }
            }

            if directoryWasCreated {
                try Self.synchronizeParentDirectory(of: directory)
            }
        }
    }

    /// Reads valid records without mutating the source.
    ///
    /// File order establishes presentation order. A later valid full revision
    /// replaces the projected value for its event ID without moving that event.
    /// Invalid later revisions leave the last valid value intact.
    public func read() -> ConversationEventLogReadResult {
        let data: Data
        do {
            guard let lockedData = try Self.readLockedData(
                directory: directory,
                fileName: url.lastPathComponent,
                url: url
            ) else {
                return ConversationEventLogReadResult(
                    events: [],
                    diagnostics: []
                )
            }
            data = lockedData
        } catch {
            return ConversationEventLogReadResult(
                events: [],
                diagnostics: [
                    ConversationEventLogDiagnostic(
                        kind: .unreadableLog,
                        fileURL: url,
                        detail: error.localizedDescription
                    )
                ]
            )
        }

        let decoder = Self.makeDecoder()
        let lines = data.split(
            separator: UInt8(ascii: "\n"),
            omittingEmptySubsequences: false
        )
        var firstSeenOrder: [UUID] = []
        var latestEvents: [UUID: SessionPresentationEvent] = [:]
        var diagnostics: [ConversationEventLogDiagnostic] = []

        for (index, rawLine) in lines.enumerated() {
            if index == lines.count - 1, rawLine.isEmpty {
                continue
            }

            var line = Data(rawLine)
            if line.last == UInt8(ascii: "\r") {
                line.removeLast()
            }
            let lineNumber = index + 1
            guard !line.isEmpty else {
                diagnostics.append(
                    diagnostic(
                        .malformedLine,
                        lineNumber: lineNumber,
                        detail: "Empty JSONL record."
                    )
                )
                continue
            }

            let envelope: SchemaEnvelope
            do {
                envelope = try decoder.decode(SchemaEnvelope.self, from: line)
            } catch {
                diagnostics.append(
                    diagnostic(
                        .malformedLine,
                        lineNumber: lineNumber,
                        detail: error.localizedDescription
                    )
                )
                continue
            }

            guard envelope.schemaVersion == Self.currentSchemaVersion else {
                diagnostics.append(
                    diagnostic(
                        .unsupportedSchemaVersion,
                        lineNumber: lineNumber,
                        detail: "Schema \(envelope.schemaVersion) is not supported."
                    )
                )
                continue
            }

            let record: Record
            do {
                record = try decoder.decode(Record.self, from: line)
            } catch {
                diagnostics.append(
                    diagnostic(
                        .malformedLine,
                        lineNumber: lineNumber,
                        detail: error.localizedDescription
                    )
                )
                continue
            }

            guard record.taskSessionID == taskSessionID else {
                diagnostics.append(
                    diagnostic(
                        .mismatchedTaskSessionID,
                        lineNumber: lineNumber,
                        detail: "Record belongs to \(Self.stableKey(record.taskSessionID))."
                    )
                )
                continue
            }
            guard Self.hasValidAuthority(record.event) else {
                diagnostics.append(
                    diagnostic(
                        .invalidAuthority,
                        lineNumber: lineNumber,
                        detail: "Authority does not support this conversation event kind."
                    )
                )
                continue
            }

            if let previous = latestEvents[record.event.id] {
                guard Self.isValidRevision(
                    previous: previous,
                    candidate: record.event
                ) else {
                    diagnostics.append(
                        diagnostic(
                            .invalidRevision,
                            lineNumber: lineNumber,
                            detail: "Revision changed immutable event content or a terminal delivery state."
                        )
                    )
                    continue
                }
            } else {
                firstSeenOrder.append(record.event.id)
            }
            latestEvents[record.event.id] = record.event
        }

        return ConversationEventLogReadResult(
            events: firstSeenOrder.compactMap { latestEvents[$0] },
            diagnostics: diagnostics
        )
    }

    private func diagnostic(
        _ kind: ConversationEventLogDiagnosticKind,
        lineNumber: Int,
        detail: String
    ) -> ConversationEventLogDiagnostic {
        ConversationEventLogDiagnostic(
            kind: kind,
            fileURL: url,
            lineNumber: lineNumber,
            detail: detail
        )
    }

    private static func hasValidAuthority(
        _ event: SessionPresentationEvent
    ) -> Bool {
        switch event.kind {
        case .sessionOpened, .userPrompt:
            return event.authority == .conduitRecorded
        case .agentOutput(let output):
            switch output.extraction {
            case .renderedBuffer, .tmuxPane:
                return event.authority == .derivedFromRaw
            case .structuredAdapter:
                return event.authority == .toolReported
            }
        }
    }

    /// Current presentation events permit one narrow revision: a queued prompt
    /// may become delivered or failed. Identity, time, prompt ingredients, and
    /// terminal delivery states cannot be rewritten by a later record.
    private static func isValidRevision(
        previous: SessionPresentationEvent,
        candidate: SessionPresentationEvent
    ) -> Bool {
        guard previous.id == candidate.id,
              previous.occurredAt == candidate.occurredAt,
              previous.authority == candidate.authority
        else { return false }

        switch (previous.kind, candidate.kind) {
        case let (.sessionOpened(previousEntry), .sessionOpened(candidateEntry)):
            return previousEntry == candidateEntry

        case let (.userPrompt(previousPrompt), .userPrompt(candidatePrompt)):
            guard previousPrompt.origin == candidatePrompt.origin,
                  previousPrompt.text == candidatePrompt.text,
                  previousPrompt.attachmentPaths == candidatePrompt.attachmentPaths,
                  previousPrompt.renderedPayload == candidatePrompt.renderedPayload
            else { return false }

            switch previousPrompt.delivery {
            case .queued:
                return true
            case .delivered:
                return candidatePrompt.delivery == .delivered
            case .failed:
                return candidatePrompt.delivery == .failed
            }

        case let (.agentOutput(previousOutput), .agentOutput(candidateOutput)):
            guard previousOutput.promptEventID == candidateOutput.promptEventID,
                  previousOutput.extraction == candidateOutput.extraction
            else { return false }
            if previousOutput.state == .closed {
                return candidateOutput == previousOutput
            }
            return true

        case (.sessionOpened, .userPrompt),
             (.sessionOpened, .agentOutput),
             (.userPrompt, .sessionOpened),
             (.userPrompt, .agentOutput),
             (.agentOutput, .sessionOpened),
             (.agentOutput, .userPrompt):
            return false
        }
    }

    private static func withPrivateDirectoryDescriptor<T>(
        _ directory: URL,
        createIfMissing: Bool,
        _ body: (Int32, Bool) throws -> T
    ) throws -> T {
        let directoryWasCreated: Bool
        var status = stat()
        let inspection = directory.path.withCString {
            Darwin.lstat($0, &status)
        }
        if inspection == 0 {
            guard fileType(status.st_mode) == mode_t(S_IFDIR) else {
                throw unsafePathError(
                    operation: "Conversation history path is not a directory",
                    url: directory
                )
            }
            directoryWasCreated = false
        } else {
            let code = errno
            guard code == ENOENT, createIfMissing else {
                throw posixError(
                    code: code,
                    operation: "Inspect conversation log directory",
                    url: directory
                )
            }
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            directoryWasCreated = true
        }

        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        let descriptor = directory.path.withCString {
            Darwin.open($0, flags)
        }
        guard descriptor >= 0 else {
            throw posixError(
                operation: "Open conversation log directory",
                url: directory
            )
        }
        defer { _ = Darwin.close(descriptor) }

        var openedStatus = stat()
        guard Darwin.fstat(descriptor, &openedStatus) == 0 else {
            throw posixError(
                operation: "Inspect opened conversation log directory",
                url: directory
            )
        }
        guard fileType(openedStatus.st_mode) == mode_t(S_IFDIR) else {
            throw unsafePathError(
                operation: "Opened conversation history path is not a directory",
                url: directory
            )
        }
        guard Darwin.fchmod(descriptor, mode_t(S_IRWXU)) == 0 else {
            throw posixError(
                operation: "Protect conversation log directory",
                url: directory
            )
        }

        return try body(descriptor, directoryWasCreated)
    }

    private static func readLockedData(
        directory: URL,
        fileName: String,
        url: URL
    ) throws -> Data? {
        var directoryStatus = stat()
        let inspection = directory.path.withCString {
            Darwin.lstat($0, &directoryStatus)
        }
        if inspection != 0 {
            let code = errno
            if code == ENOENT { return nil }
            throw posixError(
                code: code,
                operation: "Inspect conversation log directory",
                url: directory
            )
        }
        guard fileType(directoryStatus.st_mode) == mode_t(S_IFDIR) else {
            throw unsafePathError(
                operation: "Conversation history path is not a directory",
                url: directory
            )
        }

        let directoryFlags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        let directoryDescriptor = directory.path.withCString {
            Darwin.open($0, directoryFlags)
        }
        guard directoryDescriptor >= 0 else {
            throw posixError(
                operation: "Open conversation log directory",
                url: directory
            )
        }
        defer { _ = Darwin.close(directoryDescriptor) }

        if try entryIsMissing(
            directoryDescriptor: directoryDescriptor,
            fileName: fileName,
            url: url
        ) {
            return nil
        }

        let fileFlags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        let descriptor = fileName.withCString {
            Darwin.openat(directoryDescriptor, $0, fileFlags)
        }
        if descriptor < 0 {
            let code = errno
            if code == ENOENT { return nil }
            throw posixError(
                code: code,
                operation: "Open conversation log for reading",
                url: url
            )
        }
        defer { _ = Darwin.close(descriptor) }

        try validateRegularFile(descriptor: descriptor, url: url)
        while flock(descriptor, LOCK_SH) != 0 {
            let code = errno
            if code == EINTR { continue }
            throw posixError(
                code: code,
                operation: "Lock conversation log for reading",
                url: url
            )
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try readAll(descriptor: descriptor, url: url)
    }

    private static func entryIsMissing(
        directoryDescriptor: Int32,
        fileName: String,
        url: URL
    ) throws -> Bool {
        var status = stat()
        let result = fileName.withCString {
            Darwin.fstatat(
                directoryDescriptor,
                $0,
                &status,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if result == 0 {
            guard fileType(status.st_mode) == mode_t(S_IFREG) else {
                throw unsafePathError(
                    operation: "Conversation history target is not a regular file",
                    url: url
                )
            }
            return false
        }
        let code = errno
        if code == ENOENT { return true }
        throw posixError(
            code: code,
            operation: "Inspect conversation log target",
            url: url
        )
    }

    private static func validateRegularFile(
        descriptor: Int32,
        url: URL
    ) throws {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw posixError(
                operation: "Inspect opened conversation log",
                url: url
            )
        }
        guard fileType(status.st_mode) == mode_t(S_IFREG) else {
            throw unsafePathError(
                operation: "Opened conversation history target is not a regular file",
                url: url
            )
        }
    }

    private static func fileType(_ mode: mode_t) -> mode_t {
        mode & mode_t(S_IFMT)
    }

    private static func withExclusiveAppendDescriptor<T>(
        directoryDescriptor: Int32,
        fileName: String,
        url: URL,
        _ body: (Int32, Bool) throws -> T
    ) throws -> T {
        let opened = try openAppendDescriptor(
            directoryDescriptor: directoryDescriptor,
            fileName: fileName,
            url: url
        )
        let descriptor = opened.descriptor
        defer { _ = Darwin.close(descriptor) }

        try validateRegularFile(descriptor: descriptor, url: url)
        guard Darwin.fchmod(
            descriptor,
            mode_t(S_IRUSR | S_IWUSR)
        ) == 0 else {
            throw posixError(
                operation: "Protect conversation log",
                url: url
            )
        }

        while flock(descriptor, LOCK_EX) != 0 {
            let code = errno
            if code == EINTR { continue }
            throw posixError(
                code: code,
                operation: "Lock conversation log",
                url: url
            )
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body(descriptor, opened.created)
    }

    /// Opens an append target without allowing competing first writers to race
    /// through `O_CREAT`. Exactly one writer wins `O_EXCL`; later writers
    /// validate the now-existing entry before opening it without create flags.
    /// A bounded retry handles an external unlink between validation and open
    /// without ever following a replacement symlink or non-regular target.
    private static func openAppendDescriptor(
        directoryDescriptor: Int32,
        fileName: String,
        url: URL
    ) throws -> (descriptor: Int32, created: Bool) {
        let commonFlags = O_RDWR | O_APPEND | O_CLOEXEC
            | O_NOFOLLOW | O_NONBLOCK
        let createFlags = commonFlags | O_CREAT | O_EXCL
        let mode = mode_t(S_IRUSR | S_IWUSR)
        let maximumAttempts = 4
        var attempts = 0

        while attempts < maximumAttempts {
            attempts += 1
            let createdDescriptor = fileName.withCString {
                Darwin.openat(
                    directoryDescriptor,
                    $0,
                    createFlags,
                    mode
                )
            }
            if createdDescriptor >= 0 {
                return (createdDescriptor, true)
            }

            let createCode = errno
            if createCode == EINTR {
                attempts -= 1
                continue
            }
            guard createCode == EEXIST else {
                throw posixError(
                    code: createCode,
                    operation: "Create conversation log",
                    url: url
                )
            }

            if try entryIsMissing(
                directoryDescriptor: directoryDescriptor,
                fileName: fileName,
                url: url
            ) {
                continue
            }

            var existingDescriptor: Int32
            repeat {
                existingDescriptor = fileName.withCString {
                    Darwin.openat(directoryDescriptor, $0, commonFlags)
                }
            } while existingDescriptor < 0 && errno == EINTR

            if existingDescriptor >= 0 {
                return (existingDescriptor, false)
            }
            let existingCode = errno
            if existingCode == ENOENT {
                continue
            }
            throw posixError(
                code: existingCode,
                operation: "Open conversation log",
                url: url
            )
        }

        throw posixError(
            code: EAGAIN,
            operation: "Open conversation log after concurrent creation",
            url: url
        )
    }

    private static func readAll(
        descriptor: Int32,
        url: URL
    ) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count == 0 { return data }
            let code = errno
            if code == EINTR { continue }
            throw posixError(
                code: code,
                operation: "Read conversation log",
                url: url
            )
        }
    }

    private static func byte(
        at offset: off_t,
        descriptor: Int32,
        url: URL
    ) throws -> UInt8 {
        var value: UInt8 = 0
        while true {
            let count = Darwin.pread(descriptor, &value, 1, offset)
            if count == 1 { return value }
            let code = count < 0 ? errno : EIO
            if count < 0, code == EINTR { continue }
            throw posixError(
                code: code,
                operation: "Inspect conversation log tail",
                url: url
            )
        }
    }

    private static func writeAll(
        _ data: Data,
        descriptor: Int32,
        url: URL
    ) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if count > 0 {
                    offset += count
                    continue
                }
                let code = count < 0 ? errno : EIO
                if count < 0, code == EINTR { continue }
                throw posixError(
                    code: code,
                    operation: "Append conversation event",
                    url: url
                )
            }
        }
    }

    private static func synchronize(
        descriptor: Int32,
        url: URL
    ) throws {
        while Darwin.fsync(descriptor) != 0 {
            let code = errno
            if code == EINTR { continue }
            throw posixError(
                code: code,
                operation: "Synchronize conversation log",
                url: url
            )
        }
    }

    private static func synchronizeParentDirectory(of directory: URL) throws {
        let parent = directory.deletingLastPathComponent()
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC
        let descriptor = parent.path.withCString {
            Darwin.open($0, flags)
        }
        guard descriptor >= 0 else {
            throw posixError(
                operation: "Open parent of conversation log directory",
                url: parent
            )
        }
        defer { _ = Darwin.close(descriptor) }
        try synchronize(descriptor: descriptor, url: parent)
    }

    private static func unsafePathError(
        operation: String,
        url: URL
    ) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(EPERM),
            userInfo: [
                NSFilePathErrorKey: url.path,
                NSLocalizedFailureReasonErrorKey: operation
            ]
        )
    }

    private static func posixError(
        code: Int32 = errno,
        operation: String,
        url: URL
    ) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSFilePathErrorKey: url.path,
                NSLocalizedFailureReasonErrorKey: operation
            ]
        )
    }

    private static func stableKey(_ taskSessionID: TaskSessionID) -> String {
        taskSessionID.rawValue.uuidString.lowercased()
    }
}
