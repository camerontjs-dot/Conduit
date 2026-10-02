import Foundation

/// Persists structured-adapter session/thread ids so Conduit can attempt the
/// adapter-specific recovery path instead of opening a PTY. Content-free:
/// backend and opaque ids only.
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
    /// Adapter labels for superseded ids that Conduit observed when it moved
    /// away from them. Legacy records have no namespace proof and stay unknown.
    public var supersededThreadBackends: [String: String]

    /// Kept small on purpose: this is a recovery hint, not an audit trail.
    public static let supersededLimit = 8

    public init(
        backend: String,
        threadID: String,
        updatedAt: Date = Date(),
        supersededThreadIDs: [String] = [],
        supersededThreadBackends: [String: String] = [:]
    ) {
        self.backend = backend
        self.threadID = threadID
        self.updatedAt = updatedAt
        let boundedSuperseded = Array(supersededThreadIDs.prefix(Self.supersededLimit))
        self.supersededThreadIDs = boundedSuperseded
        self.supersededThreadBackends = supersededThreadBackends.filter {
            boundedSuperseded.contains($0.key)
        }
    }

    // Hand-written rather than synthesised because `load()` decodes the whole
    // map with `try?`: one record that fails to decode returns an EMPTY store,
    // and the next save then writes a file containing only that save. A
    // synthesised `init(from:)` treats a missing key as an error, so adding
    // optional lineage fields must keep older pointers readable.
    private enum CodingKeys: String, CodingKey {
        case backend, threadID, updatedAt, supersededThreadIDs
        case supersededThreadBackends
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        backend = try c.decode(String.self, forKey: .backend)
        threadID = try c.decode(String.self, forKey: .threadID)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        supersededThreadIDs =
            try c.decodeIfPresent([String].self, forKey: .supersededThreadIDs) ?? []
        supersededThreadBackends =
            try c.decodeIfPresent([String: String].self, forKey: .supersededThreadBackends) ?? [:]
        supersededThreadBackends = supersededThreadBackends.filter {
            supersededThreadIDs.contains($0.key)
        }
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
        if !supersededThreadBackends.isEmpty {
            try c.encode(supersededThreadBackends, forKey: .supersededThreadBackends)
        }
    }
}

public enum AdapterThreadStoreAvailability: String, Codable, Equatable, Sendable {
    case available
    case missing
    case unavailable
}

public struct AdapterThreadStoreLoadResult: Equatable, Sendable {
    public var records: [String: AdapterThreadRecord]
    public var availability: AdapterThreadStoreAvailability
    public var diagnostic: String?

    public init(
        records: [String: AdapterThreadRecord],
        availability: AdapterThreadStoreAvailability,
        diagnostic: String? = nil
    ) {
        self.records = records
        self.availability = availability
        self.diagnostic = diagnostic
    }
}

public struct AdapterThreadStore: Sendable {
    public let url: URL

    public init(directory: URL) {
        self.url = directory.appendingPathComponent("adapter-threads.json")
    }

    public static func defaultDirectory() -> URL {
        ConduitInstanceConfiguration.current.stateDirectory
    }

    public func threadID(for taskSessionID: TaskSessionID) -> String? {
        record(for: taskSessionID)?.threadID
    }

    public func record(for taskSessionID: TaskSessionID) -> AdapterThreadRecord? {
        loadResult().records[taskSessionID.rawValue.uuidString.lowercased()]
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
        var supersededBackends = previous?.supersededThreadBackends ?? [:]
        if let prior = previous?.threadID, prior != threadID {
            superseded.removeAll { $0 == prior }
            superseded.insert(prior, at: 0)
            supersededBackends[prior] = previous?.backend
        }
        // The live id never doubles as its own history.
        superseded.removeAll { $0 == threadID }
        supersededBackends.removeValue(forKey: threadID)
        superseded = Array(superseded.prefix(AdapterThreadRecord.supersededLimit))
        supersededBackends = supersededBackends.filter { superseded.contains($0.key) }
        records[key] = AdapterThreadRecord(
            backend: backend,
            threadID: threadID,
            supersededThreadIDs: superseded,
            supersededThreadBackends: supersededBackends
        )
        persist(records)
    }

    /// Thread ids this task used to hold, most recent first. Empty for a task
    /// whose thread never changed.
    public func supersededThreadIDs(for taskSessionID: TaskSessionID) -> [String] {
        load()[taskSessionID.rawValue.uuidString.lowercased()]?.supersededThreadIDs ?? []
    }

    public func load() -> [String: AdapterThreadRecord] {
        loadResult().records
    }

    public func loadResult() -> AdapterThreadStoreLoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return AdapterThreadStoreLoadResult(
                records: [:],
                availability: .missing
            )
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return AdapterThreadStoreLoadResult(
                records: [:],
                availability: .unavailable,
                diagnostic: "Adapter thread handles could not be read."
            )
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return AdapterThreadStoreLoadResult(
                records: try decoder.decode(
                    [String: AdapterThreadRecord].self,
                    from: data
                ),
                availability: .available
            )
        } catch {
            return AdapterThreadStoreLoadResult(
                records: [:],
                availability: .unavailable,
                diagnostic: "Adapter thread handle data was malformed or unsupported."
            )
        }
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
