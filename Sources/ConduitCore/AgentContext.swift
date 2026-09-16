import Foundation

/// Provenance classes for material admitted into an agent context bundle.
///
/// These values deliberately distinguish source facts, observations, semantic
/// nominations, operator input, and model-produced output. A UI may group them
/// visually, but it must not silently collapse them into one authority class.
public enum AgentContextAuthority: String, Codable, CaseIterable, Sendable {
    case filesystemSource
    case gitCommit
    case gitWorkingTree
    case operatorPinned
    case lifecycleRecord
    case testReceipt
    case terminalObservation
    case taskHistory
    case pullRequest
    case issue
    case mindGraphNomination
    case agentOutput

    public var authorityClass: AgentContextAuthorityClass {
        switch self {
        case .filesystemSource, .lifecycleRecord:
            return .source
        case .gitCommit:
            return .immutableIdentity
        case .gitWorkingTree, .testReceipt, .terminalObservation,
             .taskHistory, .pullRequest, .issue:
            return .observation
        case .operatorPinned:
            return .operatorInput
        case .mindGraphNomination:
            return .nomination
        case .agentOutput:
            return .agentOutput
        }
    }

    /// True only when the item itself may be presented as authored/source-backed
    /// material. Retrieval nominations and agent output remain explicitly false.
    public var isSourceBacked: Bool {
        authorityClass == .source || authorityClass == .immutableIdentity
    }
}

public enum AgentContextAuthorityClass: String, Codable, CaseIterable, Sendable {
    case source
    case immutableIdentity
    case observation
    case operatorInput
    case nomination
    case agentOutput
}

public enum AgentContextItemKind: String, Codable, CaseIterable, Sendable {
    case file
    case selection
    case gitDiff
    case commit
    case task
    case terminal
    case testReceipt
    case pullRequest
    case issue
    case semanticNomination
    case agentOutput
    case note
}

public enum AgentContextFreshness: Equatable, Codable, Sendable {
    case current
    case stale(reason: String)
    case unknown

    private enum CodingKeys: String, CodingKey {
        case state
        case reason
    }

    private enum State: String, Codable {
        case current
        case stale
        case unknown
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(State.self, forKey: .state) {
        case .current:
            self = .current
        case .stale:
            self = .stale(reason: try container.decode(String.self, forKey: .reason))
        case .unknown:
            self = .unknown
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .current:
            try container.encode(State.current, forKey: .state)
        case .stale(let reason):
            try container.encode(State.stale, forKey: .state)
            try container.encode(reason, forKey: .reason)
        case .unknown:
            try container.encode(State.unknown, forKey: .state)
        }
    }
}

/// One inspectable item in the context supplied or proposed for an agent.
/// `sourceReference` is human-readable provenance (for example a relative path,
/// PR number, or receipt path). `revisionIdentity` is the strongest exact object
/// identity available, such as a Git SHA, content digest, or receipt digest.
public struct AgentContextItem: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let title: String
    public let kind: AgentContextItemKind
    public let authority: AgentContextAuthority
    public let sourceReference: String
    public let revisionIdentity: String?
    public let lineRange: ClosedRange<Int>?
    public let estimatedTokens: Int?
    public let isPinned: Bool
    public let freshness: AgentContextFreshness

    public init(
        id: String,
        title: String,
        kind: AgentContextItemKind,
        authority: AgentContextAuthority,
        sourceReference: String,
        revisionIdentity: String? = nil,
        lineRange: ClosedRange<Int>? = nil,
        estimatedTokens: Int? = nil,
        isPinned: Bool = false,
        freshness: AgentContextFreshness = .unknown
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.authority = authority
        self.sourceReference = sourceReference
        self.revisionIdentity = revisionIdentity
        self.lineRange = lineRange
        self.estimatedTokens = estimatedTokens.map { max(0, $0) }
        self.isPinned = isPinned
        self.freshness = freshness
    }

    public var locationLabel: String {
        guard let lineRange else { return sourceReference }
        if lineRange.lowerBound == lineRange.upperBound {
            return "\(sourceReference):\(lineRange.lowerBound)"
        }
        return "\(sourceReference):\(lineRange.lowerBound)-\(lineRange.upperBound)"
    }

    /// Identity used for context-diff purposes. It intentionally excludes
    /// presentation-only title and token estimates.
    public var identityFingerprint: String {
        let range = lineRange.map { "\($0.lowerBound)-\($0.upperBound)" } ?? ""
        return [
            kind.rawValue,
            authority.rawValue,
            sourceReference,
            revisionIdentity ?? "",
            range,
            freshness.fingerprint
        ].joined(separator: "|")
    }
}

private extension AgentContextFreshness {
    var fingerprint: String {
        switch self {
        case .current:
            return "current"
        case .stale(let reason):
            return "stale:\(reason)"
        case .unknown:
            return "unknown"
        }
    }
}

/// An inspectable proposed or previously supplied context bundle.
public struct AgentContextBundle: Equatable, Codable, Sendable {
    public let taskTitle: String
    public let scopePath: String?
    public let repository: String?
    public let branch: String?
    public let commitSHA: String?
    public let items: [AgentContextItem]

    public init(
        taskTitle: String,
        scopePath: String? = nil,
        repository: String? = nil,
        branch: String? = nil,
        commitSHA: String? = nil,
        items: [AgentContextItem]
    ) {
        self.taskTitle = taskTitle
        self.scopePath = scopePath
        self.repository = repository
        self.branch = branch
        self.commitSHA = commitSHA
        self.items = items
    }

    public var estimatedTokenTotal: Int {
        items.compactMap(\.estimatedTokens).reduce(0, +)
    }

    public var pinnedItems: [AgentContextItem] {
        items.filter(\.isPinned)
    }

    public var nominationItems: [AgentContextItem] {
        items.filter { $0.authority.authorityClass == .nomination }
    }

    public var staleItems: [AgentContextItem] {
        items.filter {
            if case .stale = $0.freshness { return true }
            return false
        }
    }
}

/// Lightweight record of the context actually supplied at one handoff point.
/// Persisting a snapshot is an explicit caller decision; constructing one does
/// not itself write to MainFrame or task history.
public struct AgentContextSnapshot: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let bundle: AgentContextBundle

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        bundle: AgentContextBundle
    ) {
        self.id = id
        self.createdAt = createdAt
        self.bundle = bundle
    }
}

public struct AgentContextDiff: Equatable, Sendable {
    public let added: [AgentContextItem]
    public let removed: [AgentContextItem]
    public let changed: [AgentContextItemChange]

    public init(
        added: [AgentContextItem],
        removed: [AgentContextItem],
        changed: [AgentContextItemChange]
    ) {
        self.added = added
        self.removed = removed
        self.changed = changed
    }

    public var isEmpty: Bool {
        added.isEmpty && removed.isEmpty && changed.isEmpty
    }
}

public struct AgentContextItemChange: Equatable, Sendable {
    public let before: AgentContextItem
    public let after: AgentContextItem

    public init(before: AgentContextItem, after: AgentContextItem) {
        self.before = before
        self.after = after
    }
}

public enum AgentContextDiffer {
    /// Compares stable item IDs, then exact identity fingerprints. File names or
    /// display titles alone are never used to infer sameness.
    public static func diff(
        previous: AgentContextBundle,
        current: AgentContextBundle
    ) -> AgentContextDiff {
        let before = Dictionary(uniqueKeysWithValues: previous.items.map { ($0.id, $0) })
        let after = Dictionary(uniqueKeysWithValues: current.items.map { ($0.id, $0) })

        let added = after.keys
            .filter { before[$0] == nil }
            .compactMap { after[$0] }
            .sorted { $0.id < $1.id }

        let removed = before.keys
            .filter { after[$0] == nil }
            .compactMap { before[$0] }
            .sorted { $0.id < $1.id }

        let changed = before.keys
            .compactMap { id -> AgentContextItemChange? in
                guard let old = before[id], let new = after[id],
                      old.identityFingerprint != new.identityFingerprint else {
                    return nil
                }
                return AgentContextItemChange(before: old, after: new)
            }
            .sorted { $0.after.id < $1.after.id }

        return AgentContextDiff(added: added, removed: removed, changed: changed)
    }
}

public enum AgentContextRecipe: String, CaseIterable, Codable, Sendable {
    case reviewPullRequest
    case investigateFailure
    case implementIssue
    case researchArchitecture
    case qualificationRun
    case reproduceBug
    case agentHandoff

    /// Transparent nominations only. Recipes do not automatically admit or send
    /// material; callers must still assemble and preview the final bundle.
    public var recommendedKinds: Set<AgentContextItemKind> {
        switch self {
        case .reviewPullRequest:
            return [.pullRequest, .gitDiff, .file, .testReceipt]
        case .investigateFailure:
            return [.terminal, .testReceipt, .file, .gitDiff]
        case .implementIssue:
            return [.issue, .file, .gitDiff, .testReceipt]
        case .researchArchitecture:
            return [.file, .note, .agentOutput, .semanticNomination]
        case .qualificationRun:
            return [.commit, .testReceipt, .terminal, .file]
        case .reproduceBug:
            return [.issue, .terminal, .testReceipt, .file]
        case .agentHandoff:
            return [.task, .file, .agentOutput, .testReceipt, .gitDiff]
        }
    }
}
