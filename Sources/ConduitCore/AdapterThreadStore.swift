import Foundation

/// Persists Codex app-server thread ids so Reconnect can call `thread/resume`
/// instead of opening a PTY. Content-free: backend + thread ids only.
public struct AdapterThreadRecord: Codable, Equatable, Sendable {
    public var backend: String
    public var threadID: String
    public var updatedAt: Date
    /// Thread ids this task used to hold, most recent first.
    ///
    /// A refused resume starts a replacement session, and the replacement's id
    /// arrives here as an ordinary `sessionStarted`. Without this the write
    /// lands on top of the only pointer to the real history, so the failed
    /// recovery destroys the route back and a second attempt cannot even try
    /// the right thread. Ids only — same content-free boundary as `threadID`.
    public var supersededThreadIDs: [String]

    /// Kept small on purpose: this is a recovery hint, not an audit trail.
    public static let supersededLimit = 8

    public init(
        backend: String,
        threadID: String,
        updatedAt: Date = Date(),
        supersededThreadIDs: [String] = []
    ) {
        self.backend = backend
        self.threadID = threadID
        self.updatedAt = updatedAt
        self.supersededThreadIDs = Array(supersededThreadIDs.prefix(Self.supersededLimit))
    }

    // Hand-written rather than synthesised because `load()` decodes the whole
    // map with `try?`: one record that fails to decode returns an EMPTY store,
    // and the next save then writes a file containing only that save. A
    // synthesised `init(from:)` treats a missing key as an error, so shipping
    // `supersededThreadIDs` as a required field would wipe every existing
    // pointer on first run. `decodeIfPresent` is what keeps old files readable.
    private enum CodingKeys: String, CodingKey {
        case backend, threadID, updatedAt, supersededThreadIDs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        backend = try c.decode(String.self, forKey: .backend)
        threadID = try c.decode(String.self, forKey: .threadID)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        supersededThreadIDs =
            try c.decodeIfPresent([String].self, forKey: .supersededThreadIDs) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(backend, forKey: .backend)
        try c.encode(threadID, forKey: .threadID)
        try c.encode(updatedAt, forKey: .updatedAt)
        // Omitted when empty so untouched records keep their existing shape.
        if !supersededThreadIDs.isEmpty {
            try c.encode(supersededThreadIDs, forKey: .supersededThreadIDs)
        }
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

    /// Records the thread a task is now driving, without dropping the one it
    /// was driving before.
    ///
    /// The carry-forward is unconditional rather than something the caller opts
    /// into: the sites that write here (`sessionStarted` and `threadStarted`)
    /// cannot all tell a resume from a replacement, and the cost of guessing
    /// wrong in the losing direction is an unrecoverable task.
    public func save(
        taskSessionID: TaskSessionID,
        backend: String,
        threadID: String
    ) {
        var records = load()
        let key = taskSessionID.rawValue.uuidString.lowercased()
        let previous = records[key]
        var superseded = previous?.supersededThreadIDs ?? []
        if let prior = previous?.threadID, prior != threadID {
            superseded.removeAll { $0 == prior }
            superseded.insert(prior, at: 0)
        }
        // The live id never doubles as its own history.
        superseded.removeAll { $0 == threadID }
        records[key] = AdapterThreadRecord(
            backend: backend,
            threadID: threadID,
            supersededThreadIDs: superseded
        )
        persist(records)
    }

    /// Thread ids this task used to hold, most recent first. Empty for a task
    /// whose thread never changed.
    public func supersededThreadIDs(for taskSessionID: TaskSessionID) -> [String] {
        load()[taskSessionID.rawValue.uuidString.lowercased()]?.supersededThreadIDs ?? []
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
