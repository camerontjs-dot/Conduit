import Foundation

/// MindGraph query scope. Matches the dual-index contract: never invent `both`.
public enum MindGraphScope: String, CaseIterable, Codable, Sendable, Identifiable {
    case knowledge
    case projects

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .knowledge: return "Knowledge"
        case .projects: return "Projects"
        }
    }

    public var trustProfile: String {
        switch self {
        case .knowledge: return "durable_knowledge"
        case .projects: return "project_status"
        }
    }

    public var defaultDatabaseFileName: String {
        switch self {
        case .knowledge: return "mainframe.sqlite"
        case .projects: return "mainframe-projects.sqlite"
        }
    }

    public var help: String {
        switch self {
        case .knowledge:
            return "Durable notes under 10_knowledge (synthesized knowledge)."
        case .projects:
            return "Active project logs, plans, and READMEs under 30_projects."
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
        signal: String? = nil
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
    }
}


/// Compact Stage 1A nomination returned by MindGraph's explicit nomination mode.
///
/// This is the normal machine/agent aperture: enough source identity, authority,
/// reason, exact preview, and expansion information to decide whether spending
/// more context is worthwhile. It intentionally carries no full chunk text.
public struct MindGraphNomination: Equatable, Identifiable, Sendable {
    public var id: String { nominationID }

    public let nominationID: String
    public let expansionHandle: String
    public let title: String
    public let preview: String
    public let previewTruncated: Bool
    public let displayPath: String
    public let docID: String
    public let chunkIndex: Int
    public let contentHash: String?
    public let citationClass: String
    public let trustProfile: String
    public let freshness: String
    public let rawStatus: String?
    public let retrievalReasons: [String]
    public let signal: String?
    public let rrfScore: Double?
    public let weakFit: Bool
    public let scope: MindGraphScope

    public init(
        nominationID: String,
        expansionHandle: String,
        title: String,
        preview: String,
        previewTruncated: Bool,
        displayPath: String,
        docID: String,
        chunkIndex: Int,
        contentHash: String?,
        citationClass: String,
        trustProfile: String,
        freshness: String,
        rawStatus: String?,
        retrievalReasons: [String],
        signal: String?,
        rrfScore: Double?,
        weakFit: Bool,
        scope: MindGraphScope
    ) {
        self.nominationID = nominationID
        self.expansionHandle = expansionHandle
        self.title = title
        self.preview = preview
        self.previewTruncated = previewTruncated
        self.displayPath = displayPath
        self.docID = docID
        self.chunkIndex = chunkIndex
        self.contentHash = contentHash
        self.citationClass = citationClass
        self.trustProfile = trustProfile
        self.freshness = freshness
        self.rawStatus = rawStatus
        self.retrievalReasons = retrievalReasons
        self.signal = signal
        self.rrfScore = rrfScore
        self.weakFit = weakFit
        self.scope = scope
    }
}

/// Exact source-backed expansion of one nomination handle.
///
/// Expansion increases visible context only. It does not strengthen the
/// nomination's epistemic authority or admit the text to an agent context.
public struct MindGraphExpansion: Equatable, Sendable {
    public let expansionHandle: String
    public let docID: String
    public let chunkIndex: Int
    public let displayPath: String
    public let title: String
    public let chunkText: String
    public let contentHash: String?
    public let contentHashMatch: Bool?
    public let freshness: String
    public let rawStatus: String?
    public let citationClass: String
    public let trustProfile: String?

    public init(
        expansionHandle: String,
        docID: String,
        chunkIndex: Int,
        displayPath: String,
        title: String,
        chunkText: String,
        contentHash: String?,
        contentHashMatch: Bool?,
        freshness: String,
        rawStatus: String?,
        citationClass: String,
        trustProfile: String?
    ) {
        self.expansionHandle = expansionHandle
        self.docID = docID
        self.chunkIndex = chunkIndex
        self.displayPath = displayPath
        self.title = title
        self.chunkText = chunkText
        self.contentHash = contentHash
        self.contentHashMatch = contentHashMatch
        self.freshness = freshness
        self.rawStatus = rawStatus
        self.citationClass = citationClass
        self.trustProfile = trustProfile
    }
}

/// Operator inspection state for one canonical nomination.
///
/// A failed expansion remains visible beside the nomination instead of being
/// dropped or replaced. expandedHit exists only as a compatibility projection
/// for older presentation hooks; it is not an agent-context admission.
public struct MindGraphInspectionItem: Equatable, Identifiable, Sendable {
    public var id: String { nomination.nominationID }

    public let nomination: MindGraphNomination
    public let expansion: MindGraphExpansion?
    public let expansionError: String?

    public init(
        nomination: MindGraphNomination,
        expansion: MindGraphExpansion? = nil,
        expansionError: String? = nil
    ) {
        self.nomination = nomination
        self.expansion = expansion
        self.expansionError = expansionError
    }

    public var expandedHit: MindGraphHit? {
        guard let expansion else { return nil }
        return MindGraphHit(
            docID: nomination.docID,
            chunkIndex: nomination.chunkIndex,
            displayPath: nomination.displayPath,
            title: nomination.title,
            chunkText: expansion.chunkText,
            trustProfile: nomination.trustProfile,
            scope: nomination.scope,
            rrfScore: nomination.rrfScore,
            signal: nomination.signal
        )
    }
}

public enum MindGraphQueryError: Error, Equatable, Sendable {
    case emptyQuestion
    case binaryNotFound
    case databaseMissing(String)
    case processFailed(status: Int32, message: String)
    case timedOut
    case invalidJSON(String)

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

    /// Decode the compact Stage 1A nomination envelope.
    ///
    /// Fail closed if a supposedly compact response also contains legacy full
    /// result arrays or embeds chunk text in a nomination.
    public static func decodeNominations(
        from data: Data,
        scope: MindGraphScope
    ) throws -> [MindGraphNomination] {
        let payload = extractJSONValue(from: data) ?? data
        let root: [String: Any]
        do {
            let json = try JSONSerialization.jsonObject(with: payload)
            guard let object = json as? [String: Any] else {
                throw MindGraphQueryError.invalidJSON("expected a JSON object nomination envelope")
            }
            root = object
        } catch let error as MindGraphQueryError {
            throw error
        } catch {
            throw MindGraphQueryError.invalidJSON(error.localizedDescription)
        }

        guard root["results"] == nil, root["not_citable"] == nil else {
            throw MindGraphQueryError.invalidJSON(
                "compact nomination envelope unexpectedly contained text-bearing result arrays"
            )
        }
        guard let rows = root["nominations"] as? [[String: Any]] else {
            throw MindGraphQueryError.invalidJSON("nomination envelope missing nominations array")
        }

        return try rows.map { obj in
            if obj["chunk_text"] != nil {
                throw MindGraphQueryError.invalidJSON(
                    "compact nomination unexpectedly contained chunk_text"
                )
            }
            guard let nominationID = stringValue(obj["nomination_id"]), !nominationID.isEmpty,
                  let expansionHandle = stringValue(obj["expansion_handle"]), !expansionHandle.isEmpty,
                  let docID = stringValue(obj["doc_id"]), !docID.isEmpty,
                  let chunkIndex = intValue(obj["chunk_index"]) else {
                throw MindGraphQueryError.invalidJSON(
                    "nomination missing stable identity or expansion handle"
                )
            }

            let displayPath = stringValue(obj["display_path"])
                ?? stringValue(obj["path"])
                ?? "(unknown path)"
            let reasons = (obj["retrieval_reasons"] as? [Any])?
                .compactMap { stringValue($0) } ?? []

            return MindGraphNomination(
                nominationID: nominationID,
                expansionHandle: expansionHandle,
                title: stringValue(obj["title"]) ?? displayPath,
                preview: stringValue(obj["preview"]) ?? "",
                previewTruncated: boolValue(obj["preview_truncated"]) ?? false,
                displayPath: displayPath,
                docID: docID,
                chunkIndex: chunkIndex,
                contentHash: stringValue(obj["content_hash"]),
                citationClass: stringValue(obj["citation_class"]) ?? "citable",
                trustProfile: stringValue(obj["trust_profile"]) ?? scope.trustProfile,
                freshness: stringValue(obj["freshness"]) ?? "UNKNOWN",
                rawStatus: stringValue(obj["raw_status"]),
                retrievalReasons: reasons,
                signal: stringValue(obj["signal"]),
                rrfScore: doubleValue(obj["rrf_score"]),
                weakFit: boolValue(obj["weak_fit"]) ?? false,
                scope: scope
            )
        }
    }

    /// Decode one explicit expansion response.
    public static func decodeExpansion(from data: Data) throws -> MindGraphExpansion {
        let payload = extractJSONValue(from: data) ?? data
        let obj: [String: Any]
        do {
            let json = try JSONSerialization.jsonObject(with: payload)
            guard let object = json as? [String: Any] else {
                throw MindGraphQueryError.invalidJSON("expected a JSON object expansion")
            }
            obj = object
        } catch let error as MindGraphQueryError {
            throw error
        } catch {
            throw MindGraphQueryError.invalidJSON(error.localizedDescription)
        }

        guard let expansionHandle = stringValue(obj["expansion_handle"]), !expansionHandle.isEmpty,
              let docID = stringValue(obj["doc_id"]), !docID.isEmpty,
              let chunkIndex = intValue(obj["chunk_index"]),
              let chunkText = stringValue(obj["chunk_text"]) else {
            throw MindGraphQueryError.invalidJSON(
                "expansion missing stable identity or chunk_text"
            )
        }

        let displayPath = stringValue(obj["display_path"])
            ?? stringValue(obj["path"])
            ?? "(unknown path)"
        return MindGraphExpansion(
            expansionHandle: expansionHandle,
            docID: docID,
            chunkIndex: chunkIndex,
            displayPath: displayPath,
            title: stringValue(obj["title"]) ?? displayPath,
            chunkText: chunkText,
            contentHash: stringValue(obj["content_hash"]),
            contentHashMatch: boolValue(obj["content_hash_match"]),
            freshness: stringValue(obj["freshness"]) ?? "UNKNOWN",
            rawStatus: stringValue(obj["raw_status"]),
            citationClass: stringValue(obj["citation_class"]) ?? "citable",
            trustProfile: stringValue(obj["trust_profile"])
        )
    }

    /// Verify that an expanded chunk is the exact object nominated by the
    /// original retrieval event. Missing hashes remain unknown rather than being
    /// invented; contradictory known hashes fail the match.
    public static func expansionMatchesNomination(
        _ expansion: MindGraphExpansion,
        nomination: MindGraphNomination
    ) -> Bool {
        guard expansion.expansionHandle == nomination.expansionHandle,
              expansion.docID == nomination.docID,
              expansion.chunkIndex == nomination.chunkIndex else {
            return false
        }
        if let expected = nomination.contentHash,
           let observed = expansion.contentHash,
           expected != observed {
            return false
        }
        if let expansionTrust = expansion.trustProfile,
           expansionTrust != nomination.trustProfile {
            return false
        }
        if expansion.contentHashMatch == false {
            return false
        }
        return true
    }

    /// Extract an object or array JSON payload after any line-oriented logs.
    public static func extractJSONValue(from data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
        }) else { return nil }
        let payload = lines[start...]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return payload.data(using: .utf8)
    }

    /// Decode the legacy `--json` array contract from mindgraph query.
    public static func decodeHits(
        from data: Data,
        scope: MindGraphScope
    ) throws -> [MindGraphHit] {
        // mindgraph logs may precede JSON; take the first array payload.
        let payload = extractJSONArray(from: data) ?? data
        let objects: [[String: Any]]
        do {
            let json = try JSONSerialization.jsonObject(with: payload)
            guard let array = json as? [[String: Any]] else {
                throw MindGraphQueryError.invalidJSON("expected a JSON array")
            }
            objects = array
        } catch let error as MindGraphQueryError {
            throw error
        } catch {
            throw MindGraphQueryError.invalidJSON(error.localizedDescription)
        }

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
            return MindGraphHit(
                docID: docID,
                chunkIndex: chunkIndex,
                displayPath: displayPath,
                title: title,
                chunkText: chunkText,
                trustProfile: trust,
                scope: scope,
                rrfScore: score,
                signal: signal
            )
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

    private static func boolValue(_ any: Any?) -> Bool? {
        if let b = any as? Bool { return b }
        if let n = any as? NSNumber { return n.boolValue }
        if let s = any as? String {
            switch s.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
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
