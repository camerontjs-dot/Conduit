#if os(macOS)
import Darwin
import Foundation

/// Read-only OpenCode persistence transport.
///
/// The provider CLI itself is intentionally not used here. Current OpenCode
/// database initialization applies migrations, so even `session list` or
/// `export` can mutate provider persistence before returning a read result.
/// This transport instead copies the provider database/WAL bytes into a
/// disposable snapshot and queries only that copy.
public struct OpenCodeSQLiteObservationTransport: OpenCodeProviderObservationTransport {
    enum TransportError: Error, LocalizedError {
        case persistenceUnavailable(String)
        case ambiguousPersistence([String])
        case snapshotChangedDuringRead(String)
        case sqliteUnavailable(String)
        case queryFailed(String)
        case invalidJSON(String)
        case sessionNotFound(String)

        var errorDescription: String? {
            switch self {
            case .persistenceUnavailable(let message),
                 .snapshotChangedDuringRead(let message),
                 .sqliteUnavailable(let message),
                 .queryFailed(let message),
                 .invalidJSON(let message):
                return message
            case .ambiguousPersistence(let paths):
                return "Multiple OpenCode persistence databases are present and no exact database authority is configured: \(paths.joined(separator: ", "))."
            case .sessionNotFound(let id):
                return "OpenCode provider session not found in persistence: \(id)"
            }
        }
    }

    private struct FileFingerprint: Equatable {
        let size: UInt64
        let modifiedAt: Date?
    }

    private let fileManager: FileManager
    private let environment: [String: String]
    private let homeDirectory: URL
    private let sqliteURL: URL
    private let timeout: TimeInterval

    public init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        sqliteURL: URL = URL(fileURLWithPath: "/usr/bin/sqlite3"),
        timeout: TimeInterval = 10
    ) {
        self.fileManager = fileManager
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.sqliteURL = sqliteURL
        self.timeout = timeout
    }

    public func listSessionsJSON() throws -> CodexJSON {
        try withStablePersistenceSnapshot { databaseURL in
            let rows = try queryJSONLines(
                databaseURL: databaseURL,
                sql: """
                PRAGMA query_only=ON;
                SELECT json_object(
                  'id', id,
                  'title', title,
                  'updated', time_updated,
                  'created', time_created,
                  'projectId', project_id,
                  'directory', directory,
                  'parentId', parent_id
                )
                FROM session
                ORDER BY time_updated DESC, id DESC;
                """
            )
            return .array(rows)
        }
    }

    public func readSessionJSON(providerSessionID: String) throws -> CodexJSON {
        try withStablePersistenceSnapshot { databaseURL in
            let quotedID = Self.sqlLiteral(providerSessionID)
            let sessions = try queryJSONLines(
                databaseURL: databaseURL,
                sql: """
                PRAGMA query_only=ON;
                SELECT json_object(
                  'id', id,
                  'title', title,
                  'projectID', project_id,
                  'directory', directory,
                  'parentID', parent_id,
                  'time', json_object(
                    'created', time_created,
                    'updated', time_updated
                  )
                )
                FROM session
                WHERE id = \(quotedID)
                LIMIT 1;
                """
            )
            guard let info = sessions.first else {
                throw TransportError.sessionNotFound(providerSessionID)
            }

            let messages = try queryJSONLines(
                databaseURL: databaseURL,
                sql: """
                PRAGMA query_only=ON;
                SELECT json_object(
                  'id', id,
                  'sessionID', session_id,
                  'role', json_extract(data, '$.role'),
                  'providerID', json_extract(data, '$.providerID'),
                  'modelID', json_extract(data, '$.modelID'),
                  'time', json_object(
                    'created', time_created,
                    'completed', json_extract(data, '$.time.completed')
                  ),
                  'error', CASE
                    WHEN json_type(data, '$.error') IS NULL
                      OR json_type(data, '$.error') = 'null'
                    THEN NULL
                    ELSE 1
                  END
                )
                FROM message
                WHERE session_id = \(quotedID)
                ORDER BY time_created ASC, id ASC;
                """
            )

            // OpenCode versions before the normalized part table (or a
            // partially migrated persistence store) cannot establish that a
            // missing tool part means there was no persisted tool activity.
            // Preserve that distinction as JSON null/UNKNOWN.
            let partTables = try queryJSONLines(
                databaseURL: databaseURL,
                sql: """
                PRAGMA query_only=ON;
                SELECT json_object(
                  'present', EXISTS(
                    SELECT 1 FROM sqlite_master
                    WHERE type = 'table' AND name = 'part'
                  )
                );
                """
            )
            let parts: CodexJSON
            let hasPartsTable: Bool
            switch partTables.first?["present"] {
            case .bool(true)?:
                hasPartsTable = true
            case .number(let value)?:
                hasPartsTable = value == 1
            default:
                hasPartsTable = false
            }
            if hasPartsTable {
                parts = .array(try queryJSONLines(
                    databaseURL: databaseURL,
                    sql: """
                    PRAGMA query_only=ON;
                    SELECT json_object(
                      'id', id,
                      'messageID', message_id,
                      'kind', json_extract(data, '$.type'),
                      'tool', json_extract(data, '$.tool'),
                      'callID', json_extract(data, '$.callID'),
                      'status', json_extract(data, '$.state.status'),
                      'createdAt', time_created,
                      'updatedAt', time_updated
                    )
                    FROM part
                    WHERE session_id = \(quotedID)
                    ORDER BY time_created ASC, id ASC;
                    """
                ))
            } else {
                parts = .null
            }

            return .object([
                "info": info,
                "messages": .array(messages),
                "parts": parts,
            ])
        }
    }

    private func withStablePersistenceSnapshot<T>(
        _ body: (URL) throws -> T
    ) throws -> T {
        let source = try resolveDatabaseURL()

        for _ in 0..<3 {
            let beforeDatabase = try fingerprint(source)
            let sourceWAL = URL(fileURLWithPath: source.path + "-wal")
            let beforeWAL = try optionalFingerprint(sourceWAL)

            let directory = fileManager.temporaryDirectory.appendingPathComponent(
                "conduit-opencode-observation-\(UUID().uuidString)",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            defer { try? fileManager.removeItem(at: directory) }

            let snapshot = directory.appendingPathComponent("opencode.db")
            try fileManager.copyItem(at: source, to: snapshot)
            if beforeWAL != nil {
                try fileManager.copyItem(
                    at: sourceWAL,
                    to: URL(fileURLWithPath: snapshot.path + "-wal")
                )
            }

            let afterDatabase = try fingerprint(source)
            let afterWAL = try optionalFingerprint(sourceWAL)
            guard beforeDatabase == afterDatabase,
                  beforeWAL == afterWAL
            else {
                continue
            }

            return try body(snapshot)
        }

        throw TransportError.snapshotChangedDuringRead(
            "OpenCode persistence changed during all three snapshot attempts; observation was refused rather than returning a potentially inconsistent provider view."
        )
    }

    private func resolveDatabaseURL() throws -> URL {
        let instance = ConduitInstanceConfiguration.current
        if instance.isQualification {
            guard let path = environment["OPENCODE_DB"], path.hasPrefix("/"),
                  path.hasPrefix(instance.stateDirectory.path + "/") else {
                throw TransportError.persistenceUnavailable("Qualification discovery requires an explicit owned OPENCODE_DB; default provider inventory is disabled.")
            }
            let url = URL(fileURLWithPath: path)
            guard instance.containsOwnedURL(url),
                  (try? ConduitInstanceConfiguration.canonicalPOSIXPath(path)) == path,
                  fileManager.fileExists(atPath: path) else {
                throw TransportError.persistenceUnavailable("Qualification OpenCode persistence is not an exact owned file.")
            }
            return url
        }
        let dataDirectory = opencodeDataDirectory()

        if let configured = environment["OPENCODE_DB"],
           !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if configured == ":memory:" {
                throw TransportError.persistenceUnavailable(
                    "OPENCODE_DB is in-memory, so no durable provider-session persistence exists for read-only discovery."
                )
            }
            let configuredURL = URL(fileURLWithPath: configured)
            let resolved = configuredURL.path.hasPrefix("/")
                ? configuredURL
                : dataDirectory.appendingPathComponent(configured)
            guard fileManager.fileExists(atPath: resolved.path) else {
                throw TransportError.persistenceUnavailable(
                    "Configured OpenCode persistence does not exist at \(resolved.path)."
                )
            }
            return resolved
        }

        let stable = dataDirectory.appendingPathComponent("opencode.db")
        if fileManager.fileExists(atPath: stable.path) {
            return stable
        }

        let candidates = (try? fileManager.contentsOfDirectory(
            at: dataDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?
            .filter {
                $0.pathExtension == "db"
                    && $0.lastPathComponent.hasPrefix("opencode-")
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            ?? []

        if candidates.count == 1 {
            return candidates[0]
        }
        if candidates.count > 1 {
            throw TransportError.ambiguousPersistence(
                candidates.map(\.path)
            )
        }

        throw TransportError.persistenceUnavailable(
            "No OpenCode SQLite persistence was found under \(dataDirectory.path)."
        )
    }

    private func opencodeDataDirectory() -> URL {
        let root: URL
        if let configured = environment["XDG_DATA_HOME"],
           configured.hasPrefix("/") {
            root = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            root = homeDirectory
                .appendingPathComponent(".local", isDirectory: true)
                .appendingPathComponent("share", isDirectory: true)
        }
        return root.appendingPathComponent("opencode", isDirectory: true)
    }

    private func fingerprint(_ url: URL) throws -> FileFingerprint {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw TransportError.persistenceUnavailable(
                "Could not measure OpenCode persistence at \(url.path)."
            )
        }
        return FileFingerprint(
            size: size.uint64Value,
            modifiedAt: attributes[.modificationDate] as? Date
        )
    }

    private func optionalFingerprint(
        _ url: URL
    ) throws -> FileFingerprint? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try fingerprint(url)
    }

    private func queryJSONLines(
        databaseURL: URL,
        sql: String
    ) throws -> [CodexJSON] {
        guard fileManager.isExecutableFile(atPath: sqliteURL.path) else {
            throw TransportError.sqliteUnavailable(
                "sqlite3 is unavailable at \(sqliteURL.path); provider observation cannot read the copied persistence snapshot."
            )
        }

        // Do not use Pipe here. Inventory output can exceed the kernel pipe
        // buffer; waiting for sqlite3 to exit before draining a Pipe can then
        // deadlock the child until this method's timeout. File-backed capture
        // keeps the observation bounded without mutating provider persistence.
        let captureDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "conduit-opencode-query-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: captureDirectory,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: captureDirectory) }

        let stdoutURL = captureDirectory.appendingPathComponent("stdout.jsonl")
        let stderrURL = captureDirectory.appendingPathComponent("stderr.txt")
        guard fileManager.createFile(atPath: stdoutURL.path, contents: nil),
              fileManager.createFile(atPath: stderrURL.path, contents: nil)
        else {
            throw TransportError.queryFailed(
                "Could not create disposable sqlite3 capture files."
            )
        }

        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        let process = Process()
        process.executableURL = sqliteURL
        process.arguments = [
            "-batch",
            "-noheader",
            databaseURL.path,
            sql,
        ]
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.025)
        }
        if process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.025)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            throw TransportError.queryFailed(
                "Read-only OpenCode persistence query exceeded \(Int(timeout)) seconds."
            )
        }

        process.waitUntilExit()
        try stdoutHandle.close()
        try stderrHandle.close()

        let stdoutData = try Data(contentsOf: stdoutURL)
        let stderrData = try Data(contentsOf: stderrURL)
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: stderrData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw TransportError.queryFailed(
                detail.isEmpty
                    ? "Read-only OpenCode persistence query failed with exit \(process.terminationStatus)."
                    : "Read-only OpenCode persistence query failed with exit \(process.terminationStatus): \(String(detail.prefix(600)))"
            )
        }

        let output = String(decoding: stdoutData, as: UTF8.self)
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return []
        }

        return try output
            .split(whereSeparator: \.isNewline)
            .map { line in
                guard let value = CodexJSON.parse(Data(line.utf8)) else {
                    throw TransportError.invalidJSON(
                        "OpenCode persistence query returned malformed JSON."
                    )
                }
                return value
            }
    }

    private static func sqlLiteral(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }
}
#endif
