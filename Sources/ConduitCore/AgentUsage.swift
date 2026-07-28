import Foundation

/// Tier A usage: **only what Conduit observes itself.**
///
/// Every value here is derived from Conduit's own PTY and lifecycle machinery —
/// bytes it saw, prompts it delivered, wall-clock it attached, exit codes it
/// decoded. Nothing is read from an agent's own records and nothing is
/// inferred about tokens, cost, or quota.
///
/// Tier B (tokens/cost reported by each CLI) is deliberately absent. When it
/// lands it must stay in separate fields labelled as reported-by-the-tool, so
/// an observation is never presented as a vendor's claim or the reverse.
public struct SessionUsageRecord: Codable, Equatable, Sendable {
    /// How a session stopped. `detached` is not an ending: a tmux session keeps
    /// running, so its wall-clock is time Conduit was attached, not time the
    /// agent worked.
    public enum Outcome: String, Codable, Sendable {
        case exitedClean
        case exitedFailed
        case detached
    }

    public let agent: String
    public let projectSlug: String
    public let startedAt: Date
    public let endedAt: Date
    public let outcome: Outcome
    /// Bytes Conduit received from the PTY. This is rendered output volume,
    /// not a token count and not a proxy for one.
    public let outputBytes: Int
    public let promptsDelivered: Int
    public let promptsFailed: Int

    public init(
        agent: String,
        projectSlug: String,
        startedAt: Date,
        endedAt: Date,
        outcome: Outcome,
        outputBytes: Int,
        promptsDelivered: Int,
        promptsFailed: Int
    ) {
        self.agent = agent
        self.projectSlug = projectSlug
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.outcome = outcome
        self.outputBytes = outputBytes
        self.promptsDelivered = promptsDelivered
        self.promptsFailed = promptsFailed
    }

    /// Never negative: a clock adjustment between start and end must not
    /// produce a negative duration that then subtracts from an agent's total.
    public var attachedSeconds: TimeInterval {
        max(0, endedAt.timeIntervalSince(startedAt))
    }
}

/// One agent's observed totals. `liveSessions` is carried separately from
/// `sessions` so the UI can say "2 running" without implying those sessions
/// have finished.
public struct AgentObservedUsage: Equatable, Sendable {
    public let agent: String
    public let sessions: Int
    public let liveSessions: Int
    public let attachedSeconds: TimeInterval
    public let outputBytes: Int
    public let promptsDelivered: Int
    public let promptsFailed: Int
    public let cleanExits: Int
    public let failedExits: Int
    public let detaches: Int

    public init(
        agent: String,
        sessions: Int = 0,
        liveSessions: Int = 0,
        attachedSeconds: TimeInterval = 0,
        outputBytes: Int = 0,
        promptsDelivered: Int = 0,
        promptsFailed: Int = 0,
        cleanExits: Int = 0,
        failedExits: Int = 0,
        detaches: Int = 0
    ) {
        self.agent = agent
        self.sessions = sessions
        self.liveSessions = liveSessions
        self.attachedSeconds = attachedSeconds
        self.outputBytes = outputBytes
        self.promptsDelivered = promptsDelivered
        self.promptsFailed = promptsFailed
        self.cleanExits = cleanExits
        self.failedExits = failedExits
        self.detaches = detaches
    }
}

/// A session Conduit is attached to right now. Kept distinct from a completed
/// record because its duration is still moving and it has no outcome yet.
public struct LiveSessionUsage: Equatable, Sendable {
    public let agent: String
    public let startedAt: Date
    public let outputBytes: Int
    public let promptsDelivered: Int
    public let promptsFailed: Int

    public init(
        agent: String,
        startedAt: Date,
        outputBytes: Int,
        promptsDelivered: Int,
        promptsFailed: Int
    ) {
        self.agent = agent
        self.startedAt = startedAt
        self.outputBytes = outputBytes
        self.promptsDelivered = promptsDelivered
        self.promptsFailed = promptsFailed
    }
}

public enum AgentUsageLedger {
    /// Aggregates completed records and live sessions into one row per agent.
    ///
    /// `roster` is the full set of configured agents so an agent with no
    /// activity still gets a row reading zero *observed sessions* — which is a
    /// true statement about what Conduit saw, unlike a blank or a hidden row.
    ///
    /// Rows are returned in roster order, with any agent that appears only in
    /// history (renamed or removed from the roster) appended in stable
    /// alphabetical order so its past activity is never silently dropped.
    public static func aggregate(
        records: [SessionUsageRecord],
        live: [LiveSessionUsage] = [],
        roster: [String] = [],
        now: Date
    ) -> [AgentObservedUsage] {
        var totals: [String: AgentObservedUsage] = [:]

        func mutate(_ agent: String, _ body: (inout AgentObservedUsage) -> Void) {
            var row = totals[agent] ?? AgentObservedUsage(agent: agent)
            body(&row)
            totals[agent] = row
        }

        for record in records {
            mutate(record.agent) { row in
                row = AgentObservedUsage(
                    agent: row.agent,
                    sessions: row.sessions + 1,
                    liveSessions: row.liveSessions,
                    attachedSeconds: row.attachedSeconds + record.attachedSeconds,
                    outputBytes: row.outputBytes + record.outputBytes,
                    promptsDelivered: row.promptsDelivered + record.promptsDelivered,
                    promptsFailed: row.promptsFailed + record.promptsFailed,
                    cleanExits: row.cleanExits + (record.outcome == .exitedClean ? 1 : 0),
                    failedExits: row.failedExits + (record.outcome == .exitedFailed ? 1 : 0),
                    detaches: row.detaches + (record.outcome == .detached ? 1 : 0)
                )
            }
        }

        for session in live {
            mutate(session.agent) { row in
                row = AgentObservedUsage(
                    agent: row.agent,
                    sessions: row.sessions + 1,
                    liveSessions: row.liveSessions + 1,
                    attachedSeconds: row.attachedSeconds + max(0, now.timeIntervalSince(session.startedAt)),
                    outputBytes: row.outputBytes + session.outputBytes,
                    promptsDelivered: row.promptsDelivered + session.promptsDelivered,
                    promptsFailed: row.promptsFailed + session.promptsFailed,
                    cleanExits: row.cleanExits,
                    failedExits: row.failedExits,
                    detaches: row.detaches
                )
            }
        }

        var rows: [AgentObservedUsage] = []
        var emitted = Set<String>()
        for agent in roster {
            guard !emitted.contains(agent) else { continue }
            emitted.insert(agent)
            rows.append(totals[agent] ?? AgentObservedUsage(agent: agent))
        }
        for agent in totals.keys.sorted() where !emitted.contains(agent) {
            rows.append(totals[agent]!)
        }
        return rows
    }
}

/// Append-only observed-usage log. Mirrors `WorkSessionEventLog`: one JSON
/// object per line, torn final lines healed on append and skipped on read.
public struct AgentUsageLog: Sendable {
    public let url: URL

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public init(url: URL) {
        self.url = url
    }

    /// Same root guard as the receipt writer: refuse to write anywhere that is
    /// not a MainFrame live tree, so a mis-selected root cannot scatter logs.
    public init?(mainframeRoot: URL) {
        guard mainframeRoot.pathComponents.contains("20_live")
                || FileManager.default.fileExists(
                    atPath: mainframeRoot.appendingPathComponent("20_live").path
                )
        else { return nil }
        self.url = mainframeRoot
            .appendingPathComponent("20_live")
            .appendingPathComponent("conduit")
            .appendingPathComponent("usage")
            .appendingPathComponent("observed-usage.jsonl")
    }

    public func append(_ record: SessionUsageRecord) throws {
        let data = try Self.encoder.encode(record) + Data("\n".utf8)
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !fileManager.fileExists(atPath: url.path) {
            try data.write(to: url, options: .withoutOverwriting)
            return
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            let lastByte = try handle.read(upToCount: 1)
            try handle.seekToEnd()
            if lastByte?.first != UInt8(ascii: "\n") {
                try handle.write(contentsOf: Data("\n".utf8))
            }
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    public func readRecords() -> [SessionUsageRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { try? Self.decoder.decode(SessionUsageRecord.self, from: Data($0.utf8)) }
    }
}
