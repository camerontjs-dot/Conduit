import Foundation

public enum AgentContextSnapshotStoreError: LocalizedError {
    case invalidDirectory(URL)

    public var errorDescription: String? {
        switch self {
        case .invalidDirectory(let url):
            return "Context snapshot directory is not usable: \(url.path)"
        }
    }
}

/// Explicit, local snapshot persistence for reconstructing agent handoffs.
///
/// Merely building or previewing a context bundle does not write anything. A
/// caller must explicitly invoke `record`. Snapshots live in Conduit state, not
/// MainFrame project files, so they never become project authority by location.
public struct AgentContextSnapshotStore: @unchecked Sendable {
    private let directory: URL
    private let fileManager: FileManager

    public init(
        directory: URL,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.fileManager = fileManager
    }

    public static func defaultDirectory(
        home: URL? = nil
    ) -> URL {
        if let home {
            return home.appendingPathComponent(".conduit/context-snapshots", isDirectory: true)
        }
        return ConduitInstanceConfiguration.current.stateURL("context-snapshots", isDirectory: true)
    }

    @discardableResult
    public func record(_ bundle: AgentContextBundle, at date: Date = Date()) throws -> AgentContextSnapshot {
        try ensureDirectory()
        let snapshot = AgentContextSnapshot(createdAt: date, bundle: bundle)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        let filename = "\(Self.timestamp(date))-\(snapshot.id.uuidString.lowercased()).json"
        let target = directory.appendingPathComponent(filename)
        try data.write(to: target, options: [.atomic])
        return snapshot
    }

    public func loadAll(limit: Int = 200) throws -> [AgentContextSnapshot] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            throw AgentContextSnapshotStoreError.invalidDirectory(directory)
        }

        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "json" }
        .sorted { $0.lastPathComponent > $1.lastPathComponent }
        .prefix(max(1, min(limit, 2_000)))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(AgentContextSnapshot.self, from: data)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    public func latest(matching bundle: AgentContextBundle) throws -> AgentContextSnapshot? {
        let scope = bundle.scopePath
        let repository = bundle.repository
        return try loadAll().first { snapshot in
            snapshot.bundle.scopePath == scope && snapshot.bundle.repository == repository
        }
    }

    public func diffFromLatest(to bundle: AgentContextBundle) throws -> AgentContextDiff? {
        guard let previous = try latest(matching: bundle) else { return nil }
        return AgentContextDiffer.diff(previous: previous.bundle, current: bundle)
    }

    private func ensureDirectory() throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw AgentContextSnapshotStoreError.invalidDirectory(directory)
            }
            return
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
            .replacingOccurrences(of: ":", with: "-")
    }
}
