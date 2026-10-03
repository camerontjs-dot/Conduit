import Foundation

/// Presentation identity only. Cached nominations do not establish source freshness.
public struct MindGraphQueryKey: Hashable, Sendable {
    public let question: String
    public let scope: MindGraphScope
    public let topK: Int
    public let sourceRoot: URL?
    private let questionBytes: Data
    private let rootBytes: Data?

    public init?(question: String, scope: MindGraphScope, topK: Int, sourceRoot: URL? = nil) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, (1...30).contains(topK) else { return nil }
        self.question = trimmed
        self.scope = scope
        self.topK = topK
        self.sourceRoot = sourceRoot
        self.questionBytes = Data(trimmed.utf8)
        self.rootBytes = sourceRoot.map { Data($0.absoluteString.utf8) }
    }

    public var label: String {
        "\(scope.displayName) · top \(topK) · \(question)"
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.questionBytes == rhs.questionBytes && lhs.scope == rhs.scope
            && lhs.topK == rhs.topK && lhs.rootBytes == rhs.rootBytes
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(questionBytes)
        hasher.combine(scope)
        hasher.combine(topK)
        hasher.combine(rootBytes)
    }

    public func matchesSourceRoot(_ root: URL?) -> Bool {
        rootBytes == root.map { Data($0.absoluteString.utf8) }
    }
}

public struct MindGraphQueryRequest: Equatable, Sendable {
    public let key: MindGraphQueryKey
    public let id: UUID

    fileprivate init(key: MindGraphQueryKey) {
        self.key = key
        self.id = UUID()
    }
}

public enum MindGraphQueryPhase: Equatable, Sendable {
    case loading
    case results([MindGraphHit])
    case failed(MindGraphQueryError)
}

/// Bounded, view-owned state. Each completion must belong to a retained request.
public struct MindGraphQueryCache: Sendable {
    public static let maximumEntries = 16
    public static let maximumConcurrentQueries = 2

    private struct Entry: Sendable {
        let request: MindGraphQueryRequest
        var phase: MindGraphQueryPhase
    }

    private var entries: [MindGraphQueryKey: Entry] = [:]
    private var order: [MindGraphQueryKey] = []

    public init() {}

    public var count: Int { entries.count }

    public var runningCount: Int {
        entries.values.filter { $0.phase == .loading }.count
    }

    public func phase(for key: MindGraphQueryKey) -> MindGraphQueryPhase? {
        entries[key]?.phase
    }

    public func canBegin(for key: MindGraphQueryKey) -> Bool {
        phase(for: key) != .loading
            && runningCount < Self.maximumConcurrentQueries
    }

    public func ownsPending(_ request: MindGraphQueryRequest) -> Bool {
        entries[request.key]?.request == request && phase(for: request.key) == .loading
    }

    /// Explicit refresh replaces only this key. In-flight entries are never evicted.
    public mutating func begin(for key: MindGraphQueryKey) -> MindGraphQueryRequest? {
        guard canBegin(for: key) else { return nil }
        if entries[key] == nil, entries.count == Self.maximumEntries {
            guard let victim = order.first(where: { entries[$0]?.phase != .loading }) else {
                return nil
            }
            entries.removeValue(forKey: victim)
            order.removeAll { $0 == victim }
        }
        let request = MindGraphQueryRequest(key: key)
        entries[key] = Entry(request: request, phase: .loading)
        touch(key)
        return request
    }

    /// False means stale, duplicate, evicted or invalidated; callers must not publish it.
    @discardableResult
    public mutating func complete(
        _ request: MindGraphQueryRequest,
        result: Result<[MindGraphHit], MindGraphQueryError>
    ) -> Bool {
        guard ownsPending(request), var entry = entries[request.key] else { return false }
        switch result {
        case .success(let rows):
            if rows.allSatisfy({ $0.scope == request.key.scope }) {
                entry.phase = .results(rows)
            } else {
                entry.phase = .failed(.invalidJSON("Result scope does not match the query request."))
            }
        case .failure(let error):
            entry.phase = .failed(error)
        }
        entries[request.key] = entry
        touch(request.key)
        return true
    }

    /// Root changes and unmount invalidate even requests that finish later.
    public mutating func invalidate() {
        entries.removeAll()
        order.removeAll()
    }

    /// A delayed root-change callback must not erase work for the current root.
    public mutating func retainSourceRoot(_ root: URL?) {
        let obsolete = entries.keys.filter { !$0.matchesSourceRoot(root) }
        for key in obsolete { entries.removeValue(forKey: key) }
        order.removeAll { !$0.matchesSourceRoot(root) }
    }

    private mutating func touch(_ key: MindGraphQueryKey) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
