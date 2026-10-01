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

/// One immutable append request. When `previousEvent` is a compatible live
/// agent-output revision, the log may store a compact delta. Closed revisions
/// are always stored in full so a terminal state is independently recoverable.
public struct ConversationEventLogAppendRevision: Equatable, Sendable {
    public let event: SessionPresentationEvent
    public let previousEvent: SessionPresentationEvent?

    public init(
        event: SessionPresentationEvent,
        previousEvent: SessionPresentationEvent? = nil
    ) {
        self.event = event
        self.previousEvent = previousEvent
    }
}

public struct ConversationEventLogPageMetrics: Equatable, Sendable {
    public let sourceBytes: Int64
    public let bytesRead: Int64
    public let maximumBufferedBytes: Int
    public let rebuiltProjection: Bool

    public init(
        sourceBytes: Int64,
        bytesRead: Int64,
        maximumBufferedBytes: Int,
        rebuiltProjection: Bool
    ) {
        self.sourceBytes = sourceBytes
        self.bytesRead = bytesRead
        self.maximumBufferedBytes = maximumBufferedBytes
        self.rebuiltProjection = rebuiltProjection
    }
}

/// A cursor slice backed by a rebuildable projection sidecar. `events` contains
/// only the requested timeline range. `tailEvents` contains the latest prompt
/// and output needed to report turn observation without loading the full log.
public struct ConversationEventLogPageResult: Equatable, Sendable {
    public let events: [SessionPresentationEvent]
    public let tailEvents: [SessionPresentationEvent]
    public let timelineCount: Int
    public let startIndex: Int
    public let diagnostics: [ConversationEventLogDiagnostic]
    public let metrics: ConversationEventLogPageMetrics

    public init(
        events: [SessionPresentationEvent],
        tailEvents: [SessionPresentationEvent],
        timelineCount: Int,
        startIndex: Int,
        diagnostics: [ConversationEventLogDiagnostic],
        metrics: ConversationEventLogPageMetrics
    ) {
        self.events = events
        self.tailEvents = tailEvents
        self.timelineCount = timelineCount
        self.startIndex = startIndex
        self.diagnostics = diagnostics
        self.metrics = metrics
    }
}

/// One append-only conversation source for one durable task identity.
///
/// Every JSONL line is a complete immutable revision of a presentation event.
/// Projection keeps the first valid appearance of each event in timeline order
/// while using its latest valid revision. The source file is never rewritten
/// or truncated during append or recovery.
public struct ConversationEventLog: Equatable, Sendable {
    public static let currentSchemaVersion = 2
    public static let legacySchemaVersion = 1

    public let directory: URL
    public let taskSessionID: TaskSessionID
    public let url: URL

    private struct Record: Codable {
        let schemaVersion: Int
        let taskSessionID: TaskSessionID
        let recordedAt: Date
        let event: SessionPresentationEvent?
        let agentOutputDelta: AgentOutputDelta?

        init(
            schemaVersion: Int,
            taskSessionID: TaskSessionID,
            recordedAt: Date,
            event: SessionPresentationEvent? = nil,
            agentOutputDelta: AgentOutputDelta? = nil
        ) {
            self.schemaVersion = schemaVersion
            self.taskSessionID = taskSessionID
            self.recordedAt = recordedAt
            self.event = event
            self.agentOutputDelta = agentOutputDelta
        }
    }

    private struct LegacyRecord: Codable {
        let schemaVersion: Int
        let taskSessionID: TaskSessionID
        let recordedAt: Date
        let event: SessionPresentationEvent
    }

    private struct AgentOutputDelta: Codable {
        let eventID: UUID
        let occurredAt: Date
        let authority: SessionEventAuthority
        let promptEventID: UUID?
        let extraction: AgentOutputExtraction
        let prefixCharacterCount: Int
        let suffix: String
        let state: AgentOutputState
        let truncated: Bool
    }

    private struct SchemaEnvelope: Decodable {
        let schemaVersion: Int
    }

    private struct ProjectionIndex: Codable {
        let schemaVersion: Int
        let generation: UUID
        let taskSessionID: TaskSessionID
        let sourceDevice: UInt64
        let sourceInode: UInt64
        let sourceBytes: Int64
        let sourceModifiedSeconds: Int64
        let sourceModifiedNanoseconds: Int64
        let recordOffsets: [Int64]
        let recordLengths: [Int]
        let tailPromptOrdinal: Int?
        let tailOutputOrdinal: Int?
    }

    private struct ProjectionHeader: Codable {
        let schemaVersion: Int
        let generation: UUID
        let taskSessionID: TaskSessionID
    }

    private struct ProjectionRecord: Codable {
        let event: SessionPresentationEvent
    }

    private struct SourceFingerprint: Equatable {
        let device: UInt64
        let inode: UInt64
        let bytes: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
    }

    private struct ProjectionBuild {
        let index: ProjectionIndex
        let bytesRead: Int64
        let maximumBufferedBytes: Int
        let malformedRecords: Int
    }

    private static let projectionSchemaVersion = 1
    private static let maximumProjectionIndexBytes = 8 * 1_024 * 1_024
    private static let maximumProjectionEvents = 100_000
    private static let maximumProjectedPayloadBytes = 64 * 1_024 * 1_024
    private static let maximumConversationRecordBytes = 4 * 1_024 * 1_024

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
        try appendBatch([
            ConversationEventLogAppendRevision(event: event)
        ])
    }

    /// Appends a bounded batch under one file lock and one durability sync.
    /// The source remains append-only; batching changes only synchronization
    /// frequency, never record ordering or recovery behavior.
    public func appendBatch(
        _ revisions: [ConversationEventLogAppendRevision]
    ) throws {
        guard !revisions.isEmpty else { return }
        for revision in revisions where !Self.hasValidAuthority(revision.event) {
            throw ConversationEventLogError.invalidAuthority(
                eventID: revision.event.id
            )
        }

        let encoder = Self.makeEncoder()
        var encodedLines = Data()
        for revision in revisions {
            let record = Self.record(
                taskSessionID: taskSessionID,
                revision: revision
            )
            encodedLines.append(try encoder.encode(record))
            encodedLines.append(UInt8(ascii: "\n"))
        }

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
                payload.append(encodedLines)
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

    private static func record(
        taskSessionID: TaskSessionID,
        revision: ConversationEventLogAppendRevision
    ) -> Record {
        let event = revision.event
        if let previous = revision.previousEvent,
           case .agentOutput(let previousOutput) = previous.kind,
           case .agentOutput(let candidateOutput) = event.kind,
           previous.id == event.id,
           previous.occurredAt == event.occurredAt,
           previous.authority == event.authority,
           previousOutput.promptEventID == candidateOutput.promptEventID,
           previousOutput.extraction == candidateOutput.extraction,
           previousOutput.state != .closed,
           candidateOutput.state != .closed
        {
            let commonCount = commonCharacterPrefixCount(
                previousOutput.text,
                candidateOutput.text
            )
            let suffix = String(candidateOutput.text.dropFirst(commonCount))
            let delta = AgentOutputDelta(
                eventID: event.id,
                occurredAt: event.occurredAt,
                authority: event.authority,
                promptEventID: candidateOutput.promptEventID,
                extraction: candidateOutput.extraction,
                prefixCharacterCount: commonCount,
                suffix: suffix,
                state: candidateOutput.state,
                truncated: candidateOutput.truncated
            )
            return Record(
                schemaVersion: currentSchemaVersion,
                taskSessionID: taskSessionID,
                recordedAt: Date(),
                agentOutputDelta: delta
            )
        }
        return Record(
            schemaVersion: currentSchemaVersion,
            taskSessionID: taskSessionID,
            recordedAt: Date(),
            event: event
        )
    }

    private static func commonCharacterPrefixCount(
        _ lhs: String,
        _ rhs: String
    ) -> Int {
        var count = 0
        var left = lhs.makeIterator()
        var right = rhs.makeIterator()
        while let leftCharacter = left.next(),
              let rightCharacter = right.next(),
              leftCharacter == rightCharacter {
            count += 1
        }
        return count
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

            guard envelope.schemaVersion == Self.currentSchemaVersion
                    || envelope.schemaVersion == Self.legacySchemaVersion
            else {
                diagnostics.append(
                    diagnostic(
                        .unsupportedSchemaVersion,
                        lineNumber: lineNumber,
                        detail: "Schema \(envelope.schemaVersion) is not supported."
                    )
                )
                continue
            }

            let recordTaskSessionID: TaskSessionID
            let candidate: SessionPresentationEvent
            do {
                if envelope.schemaVersion == Self.legacySchemaVersion {
                    let record = try decoder.decode(LegacyRecord.self, from: line)
                    recordTaskSessionID = record.taskSessionID
                    candidate = record.event
                } else {
                    let record = try decoder.decode(Record.self, from: line)
                    recordTaskSessionID = record.taskSessionID
                    if let event = record.event,
                       record.agentOutputDelta == nil {
                        candidate = event
                    } else if let delta = record.agentOutputDelta,
                              record.event == nil,
                              let previous = latestEvents[delta.eventID],
                              let reconstructed = Self.applying(
                                delta,
                                to: previous
                              ) {
                        candidate = reconstructed
                    } else {
                        throw DecodingError.dataCorrupted(
                            DecodingError.Context(
                                codingPath: [],
                                debugDescription: "Record must contain exactly one full event or a valid output delta."
                            )
                        )
                    }
                }
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

            guard recordTaskSessionID == taskSessionID else {
                diagnostics.append(
                    diagnostic(
                        .mismatchedTaskSessionID,
                        lineNumber: lineNumber,
                        detail: "Record belongs to \(Self.stableKey(recordTaskSessionID))."
                    )
                )
                continue
            }
            guard Self.hasValidAuthority(candidate) else {
                diagnostics.append(
                    diagnostic(
                        .invalidAuthority,
                        lineNumber: lineNumber,
                        detail: "Authority does not support this conversation event kind."
                    )
                )
                continue
            }

            if let previous = latestEvents[candidate.id] {
                guard Self.isValidRevision(
                    previous: previous,
                    candidate: candidate
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
                firstSeenOrder.append(candidate.id)
            }
            latestEvents[candidate.id] = candidate
        }

        return ConversationEventLogReadResult(
            events: firstSeenOrder.compactMap { latestEvents[$0] },
            diagnostics: diagnostics
        )
    }

    private static func applying(
        _ delta: AgentOutputDelta,
        to previous: SessionPresentationEvent
    ) -> SessionPresentationEvent? {
        guard previous.id == delta.eventID,
              previous.occurredAt == delta.occurredAt,
              previous.authority == delta.authority,
              case .agentOutput(let previousOutput) = previous.kind,
              previousOutput.state != .closed,
              previousOutput.promptEventID == delta.promptEventID,
              previousOutput.extraction == delta.extraction,
              delta.prefixCharacterCount >= 0,
              delta.prefixCharacterCount <= previousOutput.text.count
        else { return nil }
        let text = String(
            previousOutput.text.prefix(delta.prefixCharacterCount)
        ) + delta.suffix
        return SessionPresentationEvent(
            id: delta.eventID,
            occurredAt: delta.occurredAt,
            authority: delta.authority,
            kind: .agentOutput(
                AgentVisibleOutput(
                    promptEventID: delta.promptEventID,
                    text: text,
                    state: delta.state,
                    extraction: delta.extraction,
                    truncated: delta.truncated
                )
            )
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
        case .sessionOpened, .userPrompt, .interruptRequested:
            return event.authority == .conduitRecorded
        case .providerTurnFailed:
            return event.authority == .toolReported
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

        case (.interruptRequested, .interruptRequested):
            return true

        case let (.providerTurnFailed(previous), .providerTurnFailed(candidate)):
            return previous == candidate

        case (.providerTurnFailed, _), (_, .providerTurnFailed):
            return false

        case (.sessionOpened, .userPrompt),
             (.sessionOpened, .agentOutput),
             (.sessionOpened, .interruptRequested),
             (.userPrompt, .sessionOpened),
             (.userPrompt, .agentOutput),
             (.userPrompt, .interruptRequested),
             (.agentOutput, .sessionOpened),
             (.agentOutput, .userPrompt),
             (.agentOutput, .interruptRequested),
             (.interruptRequested, .sessionOpened),
             (.interruptRequested, .userPrompt),
             (.interruptRequested, .agentOutput):
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
