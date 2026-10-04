import CryptoKit
import Foundation

/// An explicit caller declaration, never a classification inferred from a
/// filename, a directory, receipt text, or a successful file read.
public enum ContextRecordSourceProvenance: String, Codable, CaseIterable, Sendable {
    case agentArtifact
    case testReceipt
    case lifecycleRecord
    case unknown

    fileprivate var authority: AgentContextAuthority? {
        switch self {
        case .agentArtifact: return .agentOutput
        case .testReceipt: return .testReceipt
        case .lifecycleRecord: return .lifecycleRecord
        case .unknown: return nil
        }
    }

    fileprivate var kind: AgentContextItemKind {
        switch self {
        case .agentArtifact: return .agentOutput
        case .testReceipt: return .testReceipt
        case .lifecycleRecord, .unknown: return .note
        }
    }
}

/// Explicit selection of one existing text record. The declaration describes
/// its provenance, not its validity. Unknown authorship must stay unknown;
/// callers must not choose lifecycleRecord merely because a file exists.
public struct ContextRecordSourceRequest: Equatable, Codable, Sendable {
    public let file: ContextFileSourceRequest
    public let provenance: ContextRecordSourceProvenance
    /// Optional caller-supplied association, not proof of the producing task.
    public let associatedTaskIdentity: String?
    /// A bounded read cannot establish current validity. Only unknown or an
    /// explicit stale declaration is accepted by this adapter.
    public let freshness: AgentContextFreshness

    public init(
        file: ContextFileSourceRequest,
        provenance: ContextRecordSourceProvenance,
        associatedTaskIdentity: String? = nil,
        freshness: AgentContextFreshness = .unknown
    ) {
        self.file = file
        self.provenance = provenance
        self.associatedTaskIdentity = associatedTaskIdentity
        self.freshness = freshness
    }
}

public enum ContextRecordSourceError: Error, Equatable {
    case invalidRoot
    case unknownProvenance
    case invalidDeclaration
    case unsupportedCurrentFreshness
    case incompleteSourceObservation
    case incompatibleDuplicateMetadata
}

public struct ContextRecordSourceObservation: Equatable, Encodable, Sendable {
    public let request: ContextRecordSourceRequest
    public let observedSourceContentDigest: String?
    public let snapshot: ContextFileSourceSnapshot?
    public let failure: ContextFileSourceFailure?
    public let candidateEntry: ContextSetEntry?

    public var isObserved: Bool {
        snapshot != nil && failure == nil && candidateEntry != nil
    }
}

public struct ContextRecordSourceBatch: Equatable, Encodable, Sendable {
    public let observations: [ContextRecordSourceObservation]
    /// Ordinary exact source requests supplied separately as hard-context or
    /// selected-file inputs. Raw file-authority versions of records are never
    /// exposed here; record observations above retain their declared class.
    public let requiredSourceObservations: [ContextFileSourceObservation]
    public let sourceByteBudgetUsed: Int
    public let batchFailure: ContextFileSourceFailure?

    public var isComplete: Bool {
        batchFailure == nil && observations.allSatisfy(\.isObserved)
            && requiredSourceObservations.allSatisfy(\.isObserved)
    }

    public var candidateEntries: [ContextSetEntry] {
        (observations.compactMap(\.candidateEntry)
            + requiredSourceObservations.compactMap(\.candidateEntry)).sorted {
            if $0.item.isPinned != $1.item.isPinned { return $0.item.isPinned }
            return ContextRecordSourceAdapter.encoded($0)
                .lexicographicallyPrecedes(ContextRecordSourceAdapter.encoded($1))
        }
    }

    public var unresolvedRequests: [ContextRecordSourceRequest] {
        observations.filter { !$0.isObserved }.map(\.request)
    }

    public var isHandoffEligible: Bool {
        isComplete && preservesRecordMetadata(in: normalizedEntries)
    }

    /// Returns references and an inspectable provenance manifest input. It does
    /// not deliver bytes, validate a receipt, grant approval, or mutate a task.
    public func makeContextSet(
        id: String, objective: String, taskIdentity: String? = nil,
        repositoryIdentity: ContextRepositoryIdentity? = nil
    ) throws -> ContextSet {
        guard isComplete else { throw ContextRecordSourceError.incompleteSourceObservation }
        let entries = normalizedEntries
        guard preservesRecordMetadata(in: entries) else {
            throw ContextRecordSourceError.incompatibleDuplicateMetadata
        }
        return ContextSet(
            id: id, objective: objective, taskIdentity: taskIdentity,
            repositoryIdentity: repositoryIdentity, entries: entries,
            retrieverVersions: [
                .init(name: "exact-file-source", version: ContextFileSourceAdapter.version),
                .init(name: "record-source", version: ContextRecordSourceAdapter.version)
            ]
        )
    }

    private var normalizedEntries: [ContextSetEntry] {
        // Use the maintained compiler's actual policy. Do not duplicate its
        // identity algorithm or salt a byte digest to bypass deduplication.
        ContextSet(id: "record-normalization", objective: "", entries: candidateEntries)
            .deduplicated().entries
    }

    private func preservesRecordMetadata(in entries: [ContextSetEntry]) -> Bool {
        observations.compactMap(\.candidateEntry).allSatisfy { original in
            guard let retained = entries.first(where: {
                $0.item.id == original.item.id || $0.duplicateItemIDs.contains(original.item.id)
            }), retained.item.authority == original.item.authority else { return false }
            if case .stale = original.item.freshness {
                return retained.item.freshness == original.item.freshness
            }
            return true
        }
    }
}

/// Additive record adapter over the unchanged exact-file reader. Every path is
/// explicitly selected; no recent/latest discovery, receipt parser, task-store
/// access, graph traversal, Git observation, provider or UI integration occurs.
public struct ContextRecordSourceAdapter: Sendable {
    public static let version = "context-record-source-v1"
    private let sourceLimits: ContextFileSourceLimits

    public init(sourceLimits: ContextFileSourceLimits = .init()) {
        self.sourceLimits = sourceLimits
    }

    public func observe(
        root: URL, requests: [ContextRecordSourceRequest],
        requiredRequests: [ContextFileSourceRequest] = [], observedAt: Date
    ) throws -> ContextRecordSourceBatch {
        try observe(root: root, requests: requests, requiredRequests: requiredRequests,
                    observedAt: observedAt, afterFirstRead: nil)
    }

    // Test-only interposition delegates physical mutation to the existing
    // reader; it cannot supply bytes, hashes, or successful observations.
    func observe(
        root: URL, requests: [ContextRecordSourceRequest],
        requiredRequests: [ContextFileSourceRequest] = [], observedAt: Date,
        afterFirstRead: ((String) -> Void)?
    ) throws -> ContextRecordSourceBatch {
        guard root.isFileURL, root.host == nil || root.host == "" || root.host?.lowercased() == "localhost",
              root.path.hasPrefix("/"), !root.path.utf8.contains(0),
              root.query == nil, root.fragment == nil else { throw ContextRecordSourceError.invalidRoot }
        // Declarations are checked before any read. In particular, unknown
        // authorship is an unresolved caller decision, never filesystemSource.
        for request in requests {
            guard request.provenance.authority != nil else { throw ContextRecordSourceError.unknownProvenance }
            if let task = request.associatedTaskIdentity, !Self.validDeclaration(task) {
                throw ContextRecordSourceError.invalidDeclaration
            }
            switch request.freshness {
            case .current: throw ContextRecordSourceError.unsupportedCurrentFreshness
            case .stale(let reason):
                guard Self.validDeclaration(reason) else { throw ContextRecordSourceError.invalidDeclaration }
            case .unknown: break
            }
        }
        let ordered = requests.sorted { Self.encoded($0).lexicographicallyPrecedes(Self.encoded($1)) }
        let sources = ContextFileSourceAdapter(limits: sourceLimits).observe(
            root: root, requests: ordered.map(\.file) + requiredRequests,
            observedAt: observedAt, afterFirstRead: afterFirstRead
        )
        // Encoded request bytes retain exact spelling. Duplicate file requests
        // have the same bounded read; the wrapper keeps each record declaration.
        var byRequest: [Data: ContextFileSourceObservation] = [:]
        for observation in sources.observations {
            byRequest[Self.encoded(observation.request)] = observation
        }
        let observations = ordered.map { request -> ContextRecordSourceObservation in
            let source = byRequest[Self.encoded(request.file)]!
            return .init(
                request: request, observedSourceContentDigest: source.observedSourceContentDigest,
                snapshot: source.snapshot, failure: source.failure,
                candidateEntry: source.candidateEntry.map { Self.recordEntry($0, request: request) }
            )
        }
        let required = requiredRequests.sorted { Self.encoded($0).lexicographicallyPrecedes(Self.encoded($1)) }
            .map { byRequest[Self.encoded($0)]! }
        return .init(observations: observations, requiredSourceObservations: required,
                     sourceByteBudgetUsed: sources.sourceByteBudgetUsed, batchFailure: sources.batchFailure)
    }

    private static func recordEntry(
        _ source: ContextSetEntry, request: ContextRecordSourceRequest
    ) -> ContextSetEntry {
        let identity = RecordIdentity(fileIdentity: source.item.id, provenance: request.provenance)
        let item = AgentContextItem(
            id: "record:\(digest(encoded(identity)))", title: source.item.title,
            kind: request.provenance.kind, authority: request.provenance.authority!,
            sourceReference: source.item.sourceReference, revisionIdentity: source.item.revisionIdentity,
            lineRange: source.item.lineRange, estimatedTokens: source.item.estimatedTokens,
            isPinned: source.item.isPinned, freshness: request.freshness
        )
        var reasons = source.inclusionReasons + [ContextInclusionReason(
            .other, detail: "Caller-declared record provenance: \(request.provenance.rawValue)"
        )]
        if request.provenance == .agentArtifact { reasons.append(.init(.taskArtifact)) }
        if let task = request.associatedTaskIdentity {
            reasons.append(.init(.other, detail: "Caller-declared task association: \(task)"))
        }
        return ContextSetEntry(
            item: item, disposition: source.disposition, representation: source.representation,
            inclusionReasons: reasons, contentDigest: source.contentDigest
        )
    }

    private struct RecordIdentity: Encodable {
        let fileIdentity: String
        let provenance: ContextRecordSourceProvenance
    }

    private static func validDeclaration(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= 4_096 && !value.utf8.contains(0)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    fileprivate static func encoded<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try! encoder.encode(value)
    }
}
