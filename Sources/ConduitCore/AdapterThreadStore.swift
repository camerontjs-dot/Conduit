import Foundation

/// Persists Codex app-server thread ids so Reconnect can call `thread/resume`
/// instead of opening a PTY. Content-free: backend + thread id only.
public struct AdapterThreadRecord: Codable, Equatable, Sendable {
    public var backend: String
    public var threadID: String
    public var updatedAt: Date

    public init(backend: String, threadID: String, updatedAt: Date = Date()) {
        self.backend = backend
        self.threadID = threadID
        self.updatedAt = updatedAt
    }
}

public struct AdapterThreadStore: Sendable {
    public let url: URL

    public init(directory: URL) {
        self.url = directory.appendingPathComponent("adapter-threads.json")
    }

    public static func defaultDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".conduit", isDirectory: true)
    }

    public func threadID(for taskSessionID: TaskSessionID) -> String? {
        load()[taskSessionID.rawValue.uuidString.lowercased()]?.threadID
    }

    public func save(
        taskSessionID: TaskSessionID,
        backend: String,
        threadID: String
    ) {
        var records = load()
        records[taskSessionID.rawValue.uuidString.lowercased()] = AdapterThreadRecord(
            backend: backend,
            threadID: threadID
        )
        persist(records)
    }

    public func load() -> [String: AdapterThreadRecord] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: AdapterThreadRecord].self, from: data))
            ?? [:]
    }

    private func persist(_ records: [String: AdapterThreadRecord]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(records) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
