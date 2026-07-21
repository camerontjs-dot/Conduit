import Foundation

/// One observable fact about a work session, recorded as it happens.
/// Receipts are rendered from these events at close (or at recovery), so a
/// crash never loses the session record.
public enum WorkSessionEvent: Codable, Equatable, Sendable {
    case started(sessionID: String, projectSlug: String, projectTitle: String, projectPath: String, objective: String, at: Date)
    case agentLaunched(agent: String, backend: String, at: Date)
    case objectiveChanged(text: String, at: Date)
    case notesChanged(text: String, at: Date)
    case terminalOutcome(agent: String, title: String, exitCode: Int32?, detached: Bool, live: Bool, at: Date)
    case gitSnapshot(summary: String, at: Date)
    case closed(at: Date)

    public var at: Date {
        switch self {
        case .started(_, _, _, _, _, let at),
             .agentLaunched(_, _, let at),
             .objectiveChanged(_, let at),
             .notesChanged(_, let at),
             .terminalOutcome(_, _, _, _, _, let at),
             .gitSnapshot(_, let at),
             .closed(let at):
            return at
        }
    }

    public var isClosed: Bool {
        if case .closed = self { return true }
        return false
    }
}

/// Append-only JSONL log for one work session, stored outside the MainFrame
/// tree (volatile app state); the rendered Markdown receipt is the durable
/// record and lands under `20_live/conduit/sessions/`.
public struct WorkSessionEventLog: Sendable {
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

    public init(directory: URL, sessionID: String) {
        self.url = directory.appendingPathComponent("\(sessionID).jsonl")
    }

    public init(url: URL) {
        self.url = url
    }

    public func append(_ event: WorkSessionEvent) throws {
        let data = try Self.encoder.encode(event) + Data("\n".utf8)
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
            // Heal a torn final line (crash mid-write): without this, the
            // next event would merge into the corrupt line and be lost.
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

    /// Reads all events, skipping malformed lines (e.g. a torn final write).
    public func readEvents() -> [WorkSessionEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { try? Self.decoder.decode(WorkSessionEvent.self, from: Data($0.utf8)) }
    }

    public func delete() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Event logs in `directory` that never received a `.closed` event —
    /// sessions interrupted by a crash or force quit.
    public static func interruptedLogs(in directory: URL) -> [WorkSessionEventLog] {
        let fileManager = FileManager.default
        guard let children = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return children
            .filter { $0.pathExtension.lowercased() == "jsonl" }
            .map(WorkSessionEventLog.init(url:))
            .filter { log in
                let events = log.readEvents()
                return !events.isEmpty && !events.contains(where: \.isClosed)
            }
    }
}

public struct RenderedReceipt: Sendable {
    public let projectSlug: String
    public let endedAt: Date
    public let markdown: String
}

/// Renders the Markdown receipt from a session's event stream.
public enum WorkSessionReceiptRenderer {
    public static func render(events: [WorkSessionEvent], recovered: Bool = false) -> RenderedReceipt? {
        let ordered = events.sorted { $0.at < $1.at }
        guard case let .started(_, slug, title, _, initialObjective, startedAt)? = ordered.first(where: {
            if case .started = $0 { return true }
            return false
        }) else { return nil }

        var objective = initialObjective
        var notes = ""
        var gitSummary = ""
        var outcomes: [String] = []
        var endedAt = ordered.last?.at ?? startedAt

        for event in ordered {
            switch event {
            case .objectiveChanged(let text, _): objective = text
            case .notesChanged(let text, _): notes = text
            case .gitSnapshot(let summary, _): gitSummary = summary
            case .terminalOutcome(let agent, let terminalTitle, let exitCode, let detached, let live, _):
                let evidence: String
                if detached {
                    evidence = "detached; process continuity delegated to tmux"
                } else if live {
                    evidence = "still running when the work session closed; no exit code observed"
                } else if let code = exitCode {
                    evidence = "observed exit code \(code)"
                } else {
                    evidence = "no exit code observed"
                }
                outcomes.append("- \(agent) / \(terminalTitle): \(evidence)")
            case .closed(let at): endedAt = at
            case .started, .agentLaunched: break
            }
        }

        let outcomeBlock = outcomes.isEmpty ? "- No terminal sessions were recorded." : outcomes.joined(separator: "\n")
        let cleanObjective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanGit = gitSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let recoveryBlock = recovered ? """

        ## Recovery note

        This receipt was reconstructed from the session event log because Conduit did not close this work session cleanly.

        """ : ""

        let markdown = """
        ---
        title: "Conduit work session: \(escapeYAML(title))\(recovered ? " (recovered)" : "")"
        domain: "mainframe"
        type: "live"
        status: "active"
        source: "conduit://session/\(slug)"
        tags: ["conduit", "session-receipt"]
        project: "\(escapeYAML(slug))"
        started: "\(isoFormatter.string(from: startedAt))"
        ended: "\(isoFormatter.string(from: endedAt))"
        ---

        # Work session receipt

        ## Objective

        \(cleanObjective.isEmpty ? "No objective was recorded." : cleanObjective)

        ## Observed terminal outcomes

        \(outcomeBlock)

        ## Git snapshot

        ```text
        \(cleanGit.isEmpty ? "Git state was not available." : cleanGit)
        ```

        ## Operator notes

        \(cleanNotes.isEmpty ? "No operator notes were added." : cleanNotes)
        \(recoveryBlock)
        ## Evidence boundary

        This receipt records observable process and repository state. Terminal prose is not treated as proof that work completed successfully.
        """

        return RenderedReceipt(projectSlug: slug, endedAt: endedAt, markdown: markdown)
    }

    private static func escapeYAML(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static let isoFormatter = ISO8601DateFormatter()
}
