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
}

/// Relative meters for Tier A observed usage (no token/cost claims).
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

    public static func fraction(_ value: Double, of maximum: Double) -> Double {
        guard maximum > 0, value > 0 else { return 0 }
        return min(1, value / maximum)
    }
}
