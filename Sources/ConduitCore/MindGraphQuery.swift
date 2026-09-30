import Foundation
import CoreFoundation

/// MindGraph query scope. Selects one lifecycle index: never invent `both`.
public enum MindGraphScope: String, CaseIterable, Codable, Sendable, Identifiable {
    case knowledge
    case projects
    case operations

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .knowledge: return "Knowledge"
        case .projects: return "Projects"
        case .operations: return "Operations"
        }
    }

    public var trustProfile: String {
        switch self {
        case .knowledge: return "durable_knowledge"
        case .projects: return "project_status"
        case .operations: return "operations_status"
        }
    }

    public var defaultDatabaseFileName: String {
        switch self {
        case .knowledge: return "mainframe.sqlite"
        case .projects: return "mainframe-projects.sqlite"
        case .operations: return "mainframe-operations.sqlite"
        }
    }

    public var help: String {
        switch self {
        case .knowledge:
            return "Durable notes under 10_knowledge (synthesized knowledge)."
        case .projects:
            return "Active project logs, plans, and READMEs under 30_projects."
        case .operations:
            return "Standing operational coordination under 40_operations; nominations only."
        }
    }
}

/// One fused hit from `bin/mindgraph query --json`.
public struct MindGraphHit: Equatable, Identifiable, Sendable {
    public var id: String { "\(docID):\(chunkIndex):\(scope.rawValue)" }
    public let docID: String
    public let chunkIndex: Int
    public let displayPath: String
    public let title: String
    public let chunkText: String
    public let trustProfile: String
    public let scope: MindGraphScope
    public let indexID: String?
    public let warnings: [String]
    public let rrfScore: Double?
    public let signal: String?

    public init(
        docID: String,
        chunkIndex: Int,
        displayPath: String,
        title: String,
        chunkText: String,
        trustProfile: String,
        scope: MindGraphScope,
        rrfScore: Double? = nil,
        signal: String? = nil,
        indexID: String? = nil,
        warnings: [String] = []
    ) {
        self.docID = docID
        self.chunkIndex = chunkIndex
        self.displayPath = displayPath
        self.title = title
        self.chunkText = chunkText
        self.trustProfile = trustProfile
        self.scope = scope
        self.rrfScore = rrfScore
        self.signal = signal
        self.indexID = indexID
        self.warnings = warnings
    }
}

public enum MindGraphQueryError: Error, Equatable, Sendable {
    case emptyQuestion
    case binaryNotFound
    case databaseMissing(String)
    case processFailed(status: Int32, message: String)
    case timedOut
    case invalidJSON(String)
    case indexIdentityMismatch

    public var displayMessage: String {
        switch self {
        case .emptyQuestion:
            return "Enter a question to query MindGraph."
        case .binaryNotFound:
            return "Could not find bin/mindgraph under the MainFrame root."
        case .databaseMissing(let path):
            return "MindGraph index missing: \(path)"
        case .processFailed(let status, let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "MindGraph exited with status \(status)."
            }
            return "MindGraph failed (\(status)): \(trimmed.prefix(240))"
        case .timedOut:
            return "MindGraph query timed out."
        case .invalidJSON(let detail):
            return "Could not parse MindGraph JSON: \(detail)"
        case .indexIdentityMismatch:
            return "Operations index identity mismatch; no nominations admitted."
        }
    }
}

/// Pure helpers for locating indexes and decoding query JSON.
public enum MindGraphQuerySupport {
    public static func mindgraphHome(
        fileManager: FileManager = .default
    ) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".mindgraph", isDirectory: true)
    }

    public static func databaseURL(
        for scope: MindGraphScope,
        home: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL {
        let root = home ?? mindgraphHome(fileManager: fileManager)
        return root.appendingPathComponent(scope.defaultDatabaseFileName)
    }

    public static func resolveBinary(
        mainframeRoot: URL?,
        fileManager: FileManager = .default
    ) -> URL? {
        if let mainframeRoot {
            let candidate = mainframeRoot
                .appendingPathComponent("bin/mindgraph", isDirectory: false)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        // Fallbacks when root is unset or binary not marked executable yet.
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in pathEnv.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir))
                .appendingPathComponent("mindgraph")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// The real CLI boundary shared by Session API and its qualification tests.
    /// Each scope selects exactly one database; failure never selects a substitute.
    public static func sessionQuery(
        question: String,
        scope: MindGraphScope,
        binary: URL,
        database: URL,
        timeout: TimeInterval = 45,
        run: (String, [String], TimeInterval) -> (status: Int32, output: String)
    ) -> [String: Any] {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        var payload: [String: Any] = [
            "scope": scope.rawValue,
            "trust_profile": scope.trustProfile,
            "trust": "nomination only",
            "authority": "retrieval nominations; not evidence that a claim holds",
        ]
        guard !question.isEmpty else {
            payload["error"] = "question is empty"
            return payload
        }
        guard FileManager.default.fileExists(atPath: database.path) else {
            payload["error"] = "MindGraph index missing: \(database.lastPathComponent)"
            return payload
        }
        let result = run(
            binary.path,
            ["query", question, "--db", database.path, "--top-k", "8", "--json", "--no-intent"]
                + (scope == .operations ? ["--identity-envelope"] : []),
            timeout
        )
        payload["exit_code"] = result.status
        guard result.status == 0 else {
            payload["error"] = "MindGraph query failed"
            payload["diagnostic"] = String(result.output.prefix(800))
            return payload
        }
        guard let json = MindGraphOutput.jsonPayload(in: result.output),
              let data = json.data(using: .utf8) else {
            payload["error"] = "MindGraph output was not JSON"
            return payload
        }
        let decoded: (rows: [[String: Any]], identity: [String: Any]?)
        do {
            decoded = try decodeQueryRows(from: data, scope: scope)
        } catch {
            payload["error"] = scope == .operations
                ? "operations database authority missing or incompatible; no nominations admitted"
                : "MindGraph output was not a JSON array"
            return payload
        }
        let rows = decoded.rows
        if let identity = decoded.identity {
            payload["database_identity"] = identity
        }
        let split = MindGraphOutput.partitionByCitation(rows)
        payload["results"] = split.citable.map { MindGraphOutput.projectResult($0) }
        payload["result_count"] = split.citable.count
        payload["not_citable"] = split.notCitable.map { MindGraphOutput.projectResult($0) }
        payload["citation_counts"] = MindGraphOutput.citationCounts(rows)
        return payload
    }

    /// Operations requires producer-bound DB authority. Other scopes retain
    /// the legacy array contract until their separate migration is authorized.
    public static func decodeHits(
        from data: Data,
        scope: MindGraphScope
    ) throws -> [MindGraphHit] {
        let objects = try decodeQueryRows(from: data, scope: scope).rows
        return objects.compactMap { obj in
            let docID = stringValue(obj["doc_id"]) ?? UUID().uuidString
            let chunkIndex = intValue(obj["chunk_index"]) ?? 0
            let displayPath = stringValue(obj["display_path"])
                ?? stringValue(obj["path"])
                ?? "(unknown path)"
            let title = stringValue(obj["title"]) ?? displayPath
            let chunkText = stringValue(obj["chunk_text"]) ?? ""
            let trust = stringValue(obj["trust_profile"])
                ?? scope.trustProfile
            let score = doubleValue(obj["rrf_score"])
            let signal = stringValue(obj["signal"])
            var warnings: [String] = []
            if obj["weak_fit"] as? Bool == true { warnings.append("Weak fit") }
            for key in ["provenance_warning", "query_scope_warning"] {
                if let warning = obj[key] as? String, !warning.isEmpty {
                    warnings.append(warning)
                } else if let warning = obj[key] as? [String: Any], !warning.isEmpty,
                          let data = try? JSONSerialization.data(withJSONObject: warning, options: .sortedKeys) {
                    warnings.append(String(decoding: data, as: UTF8.self))
                }
            }
            return MindGraphHit(
                docID: docID,
                chunkIndex: chunkIndex,
                displayPath: displayPath,
                title: title,
                chunkText: chunkText,
                trustProfile: trust,
                scope: scope,
                rrfScore: score,
                signal: signal,
                indexID: stringValue(obj["index_id"]),
                warnings: warnings
            )
        }
    }

    private static func operationsRowsMatchIndex(_ rows: [[String: Any]]) -> Bool {
        rows.allSatisfy { row in
            row["index_id"] as? String == "mainframe-operations"
                && row["trust_profile"] as? String == "operations_status"
                && ((row["display_path"] as? String) ?? (row["path"] as? String) ?? "").hasPrefix("40_operations/")
        }
    }

    private static func decodeQueryRows(
        from data: Data, scope: MindGraphScope
    ) throws -> (rows: [[String: Any]], identity: [String: Any]?) {
        if scope == .operations {
            let output = String(decoding: data, as: UTF8.self)
            guard let text = MindGraphOutput.jsonPayload(in: output),
                  let json = text.data(using: .utf8),
                  let envelope = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
                  envelope["schema_version"] as? String == "mindgraph-query-identity/v1",
                  let identity = envelope["database_identity"] as? [String: Any],
                  operationsDatabaseIdentityMatches(identity),
                  let rows = envelope["results"] as? [[String: Any]],
                  operationsRowsMatchIndex(rows) else {
                throw MindGraphQueryError.indexIdentityMismatch
            }
            return (rows, identity)
        }
        do {
            let json = try JSONSerialization.jsonObject(with: extractJSONArray(from: data) ?? data)
            guard let rows = json as? [[String: Any]] else {
                throw MindGraphQueryError.invalidJSON("expected a JSON array")
            }
            return (rows, nil)
        } catch let error as MindGraphQueryError {
            throw error
        } catch {
            throw MindGraphQueryError.invalidJSON(error.localizedDescription)
        }
    }

    private static func operationsDatabaseIdentityMatches(_ identity: [String: Any]) -> Bool {
        let expected = [
            "schema_version": "mindgraph-index-identity/v1", "index_id": "mainframe-operations",
            "trust_profile": "operations_status", "retrieval_scope": "operations",
            "lifecycle_root": "40_operations", "producer": "mainframe-live",
        ]
        let hashFields = ["manifest_sha256", "source_document_map_sha256", "database_document_map_sha256"]
        let fields = Set(expected.keys).union(hashFields).union(["document_count"])
        guard Set(identity.keys) == fields,
              expected.allSatisfy({ identity[$0.key] as? String == $0.value }),
              let count = identity["document_count"] as? NSNumber,
              CFGetTypeID(count) != CFBooleanGetTypeID(), count.doubleValue >= 0,
              count.doubleValue.rounded(.down) == count.doubleValue else { return false }
        return hashFields.allSatisfy { field in
            guard let hash = identity[field] as? String else { return false }
            return hash.count == 64 && hash.allSatisfy { "0123456789abcdef".contains($0) }
        }
    }

    /// Strip log lines before the JSON array.
    public static func extractJSONArray(from data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        guard let start = text.firstIndex(of: "[") else { return nil }
        let slice = text[start...]
        guard let end = slice.lastIndex(of: "]") else { return nil }
        return String(slice[...end]).data(using: .utf8)
    }

    private static func stringValue(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }
}

/// Relative and budget meters for Tier A observed usage (no token/cost claims).
public enum AgentUsageMeters {
    public struct Scales: Equatable, Sendable {
        public let maxAttachedSeconds: TimeInterval
        public let maxOutputBytes: Int
        public let maxPrompts: Int

        public init(
            maxAttachedSeconds: TimeInterval,
            maxOutputBytes: Int,
            maxPrompts: Int
        ) {
            self.maxAttachedSeconds = maxAttachedSeconds
            self.maxOutputBytes = maxOutputBytes
            self.maxPrompts = maxPrompts
        }

        public static func from(_ rows: [AgentObservedUsage]) -> Scales {
            Scales(
                maxAttachedSeconds: rows.map(\.attachedSeconds).max() ?? 0,
                maxOutputBytes: rows.map(\.outputBytes).max() ?? 0,
                maxPrompts: rows.map {
                    $0.promptsDelivered + $0.promptsFailed
                }.max() ?? 0
            )
        }
    }

    /// Observed usage inside a calendar week for one agent name.
    public struct WeekWindowUsage: Equatable, Sendable {
        public let agent: String
        public let promptsDelivered: Int
        public let promptsFailed: Int
        public let attachedSeconds: TimeInterval
        public let sessions: Int
        /// Prompts delivered on currently live attaches for this agent.
        public let liveSessionPrompts: Int

        public var totalPrompts: Int { promptsDelivered + promptsFailed }

        public init(
            agent: String,
            promptsDelivered: Int = 0,
            promptsFailed: Int = 0,
            attachedSeconds: TimeInterval = 0,
            sessions: Int = 0,
            liveSessionPrompts: Int = 0
        ) {
            self.agent = agent
            self.promptsDelivered = promptsDelivered
            self.promptsFailed = promptsFailed
            self.attachedSeconds = attachedSeconds
            self.sessions = sessions
            self.liveSessionPrompts = liveSessionPrompts
        }
    }

    public static func fraction(_ value: Double, of maximum: Double) -> Double {
        guard maximum > 0, value > 0 else { return 0 }
        return min(1, value / maximum)
    }

    /// Start of the operator's current calendar week (local timezone).
    public static func startOfWeek(
        containing date: Date,
        calendar: Calendar = .current
    ) -> Date {
        let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return calendar.date(from: comps) ?? date
    }

    /// Aggregate completed records + live attaches for `agent` since week start.
    public static func weekUsage(
        agent: String,
        records: [SessionUsageRecord],
        live: [LiveSessionUsage],
        now: Date,
        calendar: Calendar = .current
    ) -> WeekWindowUsage {
        let weekStart = startOfWeek(containing: now, calendar: calendar)
        var promptsDelivered = 0
        var promptsFailed = 0
        var attached: TimeInterval = 0
        var sessions = 0

        for record in records where record.agent == agent {
            // Count a session if it ended this week or overlapped the week.
            guard record.endedAt >= weekStart || record.startedAt >= weekStart else {
                continue
            }
            sessions += 1
            promptsDelivered += record.promptsDelivered
            promptsFailed += record.promptsFailed
            let start = max(record.startedAt, weekStart)
            let end = max(start, record.endedAt)
            attached += max(0, end.timeIntervalSince(start))
        }

        var livePrompts = 0
        for session in live where session.agent == agent {
            sessions += 1
            promptsDelivered += session.promptsDelivered
            promptsFailed += session.promptsFailed
            livePrompts += session.promptsDelivered + session.promptsFailed
            let start = max(session.startedAt, weekStart)
            attached += max(0, now.timeIntervalSince(start))
        }

        return WeekWindowUsage(
            agent: agent,
            promptsDelivered: promptsDelivered,
            promptsFailed: promptsFailed,
            attachedSeconds: attached,
            sessions: sessions,
            liveSessionPrompts: livePrompts
        )
    }
}
