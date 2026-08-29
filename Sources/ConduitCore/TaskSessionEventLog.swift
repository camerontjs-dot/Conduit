import Darwin
import Foundation

/// Write-time validation failures for a task-session event log.
public enum TaskSessionEventLogError: Error, Equatable, Sendable {
    case mismatchedTaskSessionID(
        expected: TaskSessionID,
        actual: TaskSessionID
    )
    case unsupportedSchemaVersion(Int)
    case invalidAuthority(eventID: UUID)
}

/// A recoverable problem found while discovering or reading task-session logs.
///
/// Diagnostics describe the append-only source as observed. Reading never
/// deletes, truncates, or rewrites a line in response to one of these values.
public enum TaskSessionEventLogDiagnosticKind: String, Codable, Equatable, Hashable, Sendable {
    case malformedLine
    case unsupportedSchemaVersion
    case invalidAuthority
    case mismatchedTaskSessionID
    case invalidFilename
    case duplicateTaskSessionLog
    case unreadableLog
    case unprojectableLog
    case directoryReadFailed
}

public struct TaskSessionEventLogDiagnostic: Equatable, Sendable {
    public let kind: TaskSessionEventLogDiagnosticKind
    public let fileURL: URL
    public let lineNumber: Int?
    public let detail: String

    public init(
        kind: TaskSessionEventLogDiagnosticKind,
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

public struct TaskSessionEventLogReadResult: Equatable, Sendable {
    public let events: [TaskSessionEvent]
    public let diagnostics: [TaskSessionEventLogDiagnostic]

    public init(
        events: [TaskSessionEvent],
        diagnostics: [TaskSessionEventLogDiagnostic]
    ) {
        self.events = events
        self.diagnostics = diagnostics
    }
}

public struct TaskSessionEventLogDiscoveryResult: Equatable, Sendable {
    public let logs: [TaskSessionEventLog]
    public let diagnostics: [TaskSessionEventLogDiagnostic]

    public init(
        logs: [TaskSessionEventLog],
        diagnostics: [TaskSessionEventLogDiagnostic]
    ) {
        self.logs = logs
        self.diagnostics = diagnostics
    }
}

public struct TaskSessionEventStoreLoadResult: Equatable, Sendable {
    public let snapshots: [TaskSessionSnapshot]
    public let diagnostics: [TaskSessionEventLogDiagnostic]

    public init(
        snapshots: [TaskSessionSnapshot],
        diagnostics: [TaskSessionEventLogDiagnostic]
    ) {
        self.snapshots = snapshots
        self.diagnostics = diagnostics
    }
}

/// One append-only JSONL source for one durable task identity.
///
/// The filename is derived from the task identity, so the stream cannot drift
/// into a second task by accident. Raw files remain the authority; snapshots
/// returned by `TaskSessionEventStore` are deterministic projections.
public struct TaskSessionEventLog: Equatable, Sendable {
    public let directory: URL
    public let taskSessionID: TaskSessionID
    public let url: URL

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
            Self.filename(for: taskSessionID)
        )
    }

    private init(
        directory: URL,
        taskSessionID: TaskSessionID,
        discoveredURL: URL
    ) {
        self.directory = directory.standardizedFileURL
        self.taskSessionID = taskSessionID
        self.url = discoveredURL.standardizedFileURL
    }

    /// Appends one validated event and synchronizes it to the backing file.
    ///
    /// If a prior write ended mid-line, a newline is inserted before the new
    /// event. The torn bytes remain present for diagnosis and provenance.
    public func append(_ event: TaskSessionEvent) throws {
        guard event.taskSessionID == taskSessionID else {
            throw TaskSessionEventLogError.mismatchedTaskSessionID(
                expected: taskSessionID,
                actual: event.taskSessionID
            )
        }
        guard event.schemaVersion == TaskSessionEvent.currentSchemaVersion else {
            throw TaskSessionEventLogError.unsupportedSchemaVersion(
                event.schemaVersion
            )
        }
        guard event.hasValidAuthority else {
            throw TaskSessionEventLogError.invalidAuthority(eventID: event.id)
        }

        let line = try Self.makeEncoder().encode(event) + Data("\n".utf8)
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Self.withExclusiveAppendDescriptor(for: url) { descriptor in
            let end = Darwin.lseek(descriptor, 0, SEEK_END)
            guard end >= 0 else {
                throw Self.posixError(
                    operation: "Inspect task-session log",
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
            try Self.writeAll(
                payload,
                descriptor: descriptor,
                url: url
            )
            try Self.synchronize(descriptor: descriptor, url: url)
        }
    }

    /// Reads valid events in exact file order and reports rejected lines.
    ///
    /// Duplicate event IDs are retained here; idempotence belongs to
    /// `TaskSessionProjection`, where the first valid occurrence wins.
    public func read() -> TaskSessionEventLogReadResult {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return TaskSessionEventLogReadResult(events: [], diagnostics: [])
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return TaskSessionEventLogReadResult(
                events: [],
                diagnostics: [
                    TaskSessionEventLogDiagnostic(
                        kind: .unreadableLog,
                        fileURL: url,
                        detail: error.localizedDescription
                    )
                ]
            )
        }

        var events: [TaskSessionEvent] = []
        var diagnostics: [TaskSessionEventLogDiagnostic] = []
        let decoder = Self.makeDecoder()
        let lines = data.split(
            separator: UInt8(ascii: "\n"),
            omittingEmptySubsequences: false
        )

        for (index, rawLine) in lines.enumerated() {
            // A normal JSONL file ends in a newline, which produces one final
            // empty subsequence. Interior blank lines remain diagnosable.
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
                envelope = try decoder.decode(
                    SchemaEnvelope.self,
                    from: line
                )
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

            guard envelope.schemaVersion == TaskSessionEvent.currentSchemaVersion else {
                diagnostics.append(
                    diagnostic(
                        .unsupportedSchemaVersion,
                        lineNumber: lineNumber,
                        detail: "Schema \(envelope.schemaVersion) is not supported."
                    )
                )
                continue
            }

            let event: TaskSessionEvent
            do {
                event = try decoder.decode(TaskSessionEvent.self, from: line)
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

            guard event.taskSessionID == taskSessionID else {
                diagnostics.append(
                    diagnostic(
                        .mismatchedTaskSessionID,
                        lineNumber: lineNumber,
                        detail: "Event belongs to \(Self.stableKey(event.taskSessionID))."
                    )
                )
                continue
            }
            guard event.hasValidAuthority else {
                diagnostics.append(
                    diagnostic(
                        .invalidAuthority,
                        lineNumber: lineNumber,
                        detail: "Authority does not support this event kind."
                    )
                )
                continue
            }

            events.append(event)
        }

        return TaskSessionEventLogReadResult(
            events: events,
            diagnostics: diagnostics
        )
    }

    /// Discovers one deterministic log per valid UUID filename.
    ///
    /// A missing directory is a clean empty store. Other directory failures
    /// are retained as diagnostics rather than treated as negative evidence.
    public static func logs(
        in directory: URL
    ) -> TaskSessionEventLogDiscoveryResult {
        let normalizedDirectory = directory.standardizedFileURL
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: normalizedDirectory.path,
            isDirectory: &isDirectory
        ) else {
            return TaskSessionEventLogDiscoveryResult(
                logs: [],
                diagnostics: []
            )
        }
        guard isDirectory.boolValue else {
            return TaskSessionEventLogDiscoveryResult(
                logs: [],
                diagnostics: [
                    TaskSessionEventLogDiagnostic(
                        kind: .directoryReadFailed,
                        fileURL: normalizedDirectory,
                        detail: "Task-session store path is not a directory."
                    )
                ]
            )
        }

        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: normalizedDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return TaskSessionEventLogDiscoveryResult(
                logs: [],
                diagnostics: [
                    TaskSessionEventLogDiagnostic(
                        kind: .directoryReadFailed,
                        fileURL: normalizedDirectory,
                        detail: error.localizedDescription
                    )
                ]
            )
        }

        var candidates: [(url: URL, id: TaskSessionID, isCanonical: Bool)] = []
        var diagnostics: [TaskSessionEventLogDiagnostic] = []
        for child in children where child.pathExtension.lowercased() == "jsonl" {
            let stem = child.deletingPathExtension().lastPathComponent
            guard let uuid = UUID(uuidString: stem),
                  uuid.uuidString.lowercased() == stem.lowercased()
            else {
                diagnostics.append(
                    TaskSessionEventLogDiagnostic(
                        kind: .invalidFilename,
                        fileURL: child,
                        detail: "Expected a canonical UUID.jsonl filename."
                    )
                )
                continue
            }
            let id = TaskSessionID(rawValue: uuid)
            candidates.append(
                (
                    url: child,
                    id: id,
                    isCanonical: child.lastPathComponent == filename(for: id)
                )
            )
        }

        candidates.sort { lhs, rhs in
            let lhsKey = stableKey(lhs.id)
            let rhsKey = stableKey(rhs.id)
            if lhsKey != rhsKey {
                return lhsKey < rhsKey
            }
            if lhs.isCanonical != rhs.isCanonical {
                return lhs.isCanonical && !rhs.isCanonical
            }
            return lhs.url.lastPathComponent < rhs.url.lastPathComponent
        }

        var seen = Set<TaskSessionID>()
        var logs: [TaskSessionEventLog] = []
        for candidate in candidates {
            guard seen.insert(candidate.id).inserted else {
                diagnostics.append(
                    TaskSessionEventLogDiagnostic(
                        kind: .duplicateTaskSessionLog,
                        fileURL: candidate.url,
                        detail: "Another log already represents \(stableKey(candidate.id))."
                    )
                )
                continue
            }
            logs.append(
                TaskSessionEventLog(
                    directory: normalizedDirectory,
                    taskSessionID: candidate.id,
                    discoveredURL: candidate.url
                )
            )
        }

        diagnostics.sort(by: diagnosticOrder)
        return TaskSessionEventLogDiscoveryResult(
            logs: logs,
            diagnostics: diagnostics
        )
    }

    private func diagnostic(
        _ kind: TaskSessionEventLogDiagnosticKind,
        lineNumber: Int,
        detail: String
    ) -> TaskSessionEventLogDiagnostic {
        TaskSessionEventLogDiagnostic(
            kind: kind,
            fileURL: url,
            lineNumber: lineNumber,
            detail: detail
        )
    }

    /// `flock` is advisory, so every Conduit writer uses this same critical
    /// section. The lock covers both torn-tail inspection/healing and the
    /// append itself; `O_APPEND` additionally prevents a stale file offset from
    /// overwriting bytes if another non-cooperating writer extends the file.
    private static func withExclusiveAppendDescriptor<T>(
        for url: URL,
        _ body: (Int32) throws -> T
    ) throws -> T {
        let flags = O_RDWR | O_CREAT | O_APPEND | O_CLOEXEC
        let mode = mode_t(S_IRUSR | S_IWUSR)
        let descriptor = url.path.withCString {
            Darwin.open($0, flags, mode)
        }
        guard descriptor >= 0 else {
            throw posixError(
                operation: "Open task-session log",
                url: url
            )
        }
        defer { _ = Darwin.close(descriptor) }

        while flock(descriptor, LOCK_EX) != 0 {
            let code = errno
            if code == EINTR { continue }
            throw posixError(
                code: code,
                operation: "Lock task-session log",
                url: url
            )
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body(descriptor)
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
                operation: "Inspect task-session log tail",
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
                    operation: "Append task-session event",
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
                operation: "Synchronize task-session log",
                url: url
            )
        }
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

    private static func filename(for taskSessionID: TaskSessionID) -> String {
        "\(stableKey(taskSessionID)).jsonl"
    }

    private static func stableKey(_ taskSessionID: TaskSessionID) -> String {
        taskSessionID.rawValue.uuidString.lowercased()
    }

    private static func diagnosticOrder(
        _ lhs: TaskSessionEventLogDiagnostic,
        _ rhs: TaskSessionEventLogDiagnostic
    ) -> Bool {
        let lhsName = lhs.fileURL.lastPathComponent
        let rhsName = rhs.fileURL.lastPathComponent
        if lhsName != rhsName {
            return lhsName < rhsName
        }
        if lhs.lineNumber != rhs.lineNumber {
            return (lhs.lineNumber ?? 0) < (rhs.lineNumber ?? 0)
        }
        return lhs.kind.rawValue < rhs.kind.rawValue
    }
}

/// Rebuildable projection store over task-session JSONL sources.
public struct TaskSessionEventStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory.standardizedFileURL
    }

    public func logs() -> TaskSessionEventLogDiscoveryResult {
        TaskSessionEventLog.logs(in: directory)
    }

    public func load() -> TaskSessionEventStoreLoadResult {
        let discovery = logs()
        var snapshots: [TaskSessionSnapshot] = []
        var diagnostics = discovery.diagnostics

        for log in discovery.logs {
            let readResult = log.read()
            diagnostics.append(contentsOf: readResult.diagnostics)
            guard let snapshot = TaskSessionProjection.project(
                taskSessionID: log.taskSessionID,
                events: readResult.events
            ) else {
                diagnostics.append(
                    TaskSessionEventLogDiagnostic(
                        kind: .unprojectableLog,
                        fileURL: log.url,
                        detail: "No valid creation event could project this task."
                    )
                )
                continue
            }
            snapshots.append(snapshot)
        }

        snapshots.sort {
            $0.id.rawValue.uuidString.lowercased()
                < $1.id.rawValue.uuidString.lowercased()
        }
        return TaskSessionEventStoreLoadResult(
            snapshots: snapshots,
            diagnostics: diagnostics
        )
    }
}
