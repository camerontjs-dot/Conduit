import CryptoKit
import Foundation

public struct ContextLexicalSourceLimits: Equatable, Codable, Sendable {
    public let maximumRecords: Int
    public let maximumIndexBytes: Int
    public let maximumNominations: Int
    public let maximumQueryBytes: Int

    public init(
        maximumRecords: Int = 20_000, maximumIndexBytes: Int = 64_000_000,
        maximumNominations: Int = 128, maximumQueryBytes: Int = 4_096
    ) {
        self.maximumRecords = maximumRecords
        self.maximumIndexBytes = maximumIndexBytes
        self.maximumNominations = maximumNominations
        self.maximumQueryBytes = maximumQueryBytes
    }
}

public enum ContextLexicalSourceError: Error, Equatable {
    case invalidLimits
    case invalidRoot
    case invalidQuery
    case invalidIndex
    case duplicateSelection
    case nominationNotFound
    case foreignSelection
    case wrongRootOrQuery
    case partialDiscovery
    case incompleteSourceObservation
}

/// Coverage of the supplied cached text, never an exhaustive filesystem claim.
/// Explorer exclusions and Find's three-content-hit-per-file bound are explicit.
/// Skipped records and observed clipping prevent a complete handoff below.
public struct ContextLexicalCoverage: Equatable, Encodable, Sendable {
    public let filesystemIndexTruncated: Bool
    public let contentTruncated: Bool
    public let skippedNonText: Int
    public let skippedTooLarge: Int
    public let resultClipped: Bool
    public let filesWithClippedContentHits: Int
    public let indexedRecordCount: Int
    public let indexedByteCount: Int
    public let maximumNominations: Int
    public let contentHitsPerFileLimit: Int
    public let excludedComponentNames: [String]

    public var mayBeIncomplete: Bool {
        filesystemIndexTruncated || contentTruncated || skippedNonText > 0
            || skippedTooLarge > 0 || resultClipped || filesWithClippedContentHits > 0
    }
}

/// A preview of cached Find input. It has no AgentContext source authority and
/// contains no exact source snapshot. The cached digest is only a discriminator
/// required at a later physical read, not current freshness or a Git identity.
public struct ContextLexicalNomination: Equatable, Encodable, Sendable {
    public let id: String
    public let relativePath: String
    public let line: Int
    public let preview: String
    public let kind: String
    public let score: Int
    public let cachedTextDigest: String

    fileprivate init(id: String, hit: MainframeSearchHit, digest: String) {
        self.id = id
        relativePath = hit.path
        line = hit.line
        preview = hit.excerpt
        kind = hit.kind.rawValue
        score = hit.score
        cachedTextDigest = digest
    }
}

public struct ContextLexicalSelectionItem: Equatable, Encodable, Sendable {
    public let nominationID: String
    public let lineRange: ClosedRange<Int>?
    public let isPinned: Bool

    public init(nominationID: String, lineRange: ClosedRange<Int>? = nil, isPinned: Bool = false) {
        self.nominationID = nominationID
        self.lineRange = lineRange
        self.isPinned = isPinned
    }
}

/// An explicit selection from one active batch. Encoded receipts cannot be
/// decoded into active selection authority. Reusing this ticket with another
/// discovery generation is refused; repeated reads of its own batch are allowed
/// and do not imply duplicate-delivery protection or provider delivery.
public struct ContextLexicalSourceSelection: Encodable, Sendable {
    public let generationID: UUID
    public let snapshotIdentity: String
    public let items: [ContextLexicalSelectionItem]

    fileprivate init(batch: ContextLexicalNominationBatch, items: [ContextLexicalSelectionItem]) {
        generationID = batch.generationID
        snapshotIdentity = batch.snapshotIdentity
        self.items = items
    }
}

public struct ContextLexicalNominationBatch: Encodable, Sendable {
    public let generationID: UUID
    public let snapshotIdentity: String
    public let declaredRoot: String
    public let query: String
    public let nominations: [ContextLexicalNomination]
    public let coverage: ContextLexicalCoverage

    fileprivate init(
        snapshotIdentity: String, root: String, query: String,
        nominations: [ContextLexicalNomination], coverage: ContextLexicalCoverage
    ) {
        generationID = UUID()
        self.snapshotIdentity = snapshotIdentity
        declaredRoot = root
        self.query = query
        self.nominations = nominations
        self.coverage = coverage
    }

    /// No candidate is selected implicitly. Stable nomination IDs alone are
    /// references; this method records a new explicit choice in this generation.
    public func select(_ items: [ContextLexicalSelectionItem]) throws -> ContextLexicalSourceSelection {
        var selected: Set<Data> = []
        let available = Set(nominations.map { Data($0.id.utf8) })
        for item in items {
            let id = Data(item.nominationID.utf8)
            guard selected.insert(id).inserted else { throw ContextLexicalSourceError.duplicateSelection }
            guard available.contains(id) else { throw ContextLexicalSourceError.nominationNotFound }
        }
        return .init(batch: self, items: items)
    }
}

/// Selected physical observations and partial-discovery evidence remain
/// inspectable independently. A successful read does not erase partial search
/// coverage or an unresolved objective, pin, contract, or selected source.
public struct ContextLexicalSourceExpansionBatch: Encodable, Sendable {
    public let snapshotIdentity: String
    public let sourceBatch: ContextFileSourceBatch
    public let coverage: ContextLexicalCoverage
    public let candidateEntries: [ContextSetEntry]

    public var isHandoffEligible: Bool { sourceBatch.isComplete && !coverage.mayBeIncomplete }

    fileprivate init(
        snapshotIdentity: String, sourceBatch: ContextFileSourceBatch,
        coverage: ContextLexicalCoverage, candidateEntries: [ContextSetEntry]
    ) {
        self.snapshotIdentity = snapshotIdentity
        self.sourceBatch = sourceBatch
        self.coverage = coverage
        self.candidateEntries = candidateEntries
    }

    /// Compose the existing #108 Context Set. This admits observed metadata;
    /// it does not deliver snapshot bytes, qualify budget, or send worker input.
    public func makeContextSet(
        id: String, objective: String, taskIdentity: String? = nil,
        repositoryIdentity: ContextRepositoryIdentity? = nil
    ) throws -> ContextSet {
        guard sourceBatch.isComplete else { throw ContextLexicalSourceError.incompleteSourceObservation }
        guard !coverage.mayBeIncomplete else { throw ContextLexicalSourceError.partialDiscovery }
        return ContextSet(
            id: id, objective: objective, taskIdentity: taskIdentity,
            repositoryIdentity: repositoryIdentity, entries: candidateEntries,
            retrieverVersions: [
                .init(name: "exact-file-source", version: ContextFileSourceAdapter.version),
                .init(name: "lexical-source", version: ContextLexicalSourceAdapter.version)
            ]
        ).deduplicated()
    }
}

/// Additive adapter around existing Find and the exact-file source reader.
/// Discovery operates only on an explicitly supplied bounded cached index;
/// no index build, adjacent scan, semantic retrieval or source read occurs.
/// Explicit selection then observes current files under the declared root.
/// Neither supplied index metadata nor later digest equality proves authorship,
/// relevance, corpus completeness, perpetual freshness, or provider delivery.
public struct ContextLexicalSourceAdapter: Sendable {
    public static let version = "context-lexical-source-v1"
    private let limits: ContextLexicalSourceLimits
    private let sourceLimits: ContextFileSourceLimits

    public init(
        limits: ContextLexicalSourceLimits = .init(), sourceLimits: ContextFileSourceLimits = .init()
    ) {
        self.limits = limits
        self.sourceLimits = sourceLimits
    }

    public func discover(
        index: MainframeContentIndex, root: URL, query: String
    ) throws -> ContextLexicalNominationBatch {
        guard (1...20_000).contains(limits.maximumRecords),
              (1...64_000_000).contains(limits.maximumIndexBytes),
              (1...1_024).contains(limits.maximumNominations),
              (1...4_096).contains(limits.maximumQueryBytes) else {
            throw ContextLexicalSourceError.invalidLimits
        }
        guard root.isFileURL, root.host == nil || root.host == "" || root.host?.lowercased() == "localhost",
              root.path.hasPrefix("/"), !root.path.utf8.contains(0),
              root.query == nil, root.fragment == nil else { throw ContextLexicalSourceError.invalidRoot }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !query.utf8.contains(0), query.utf8.count <= limits.maximumQueryBytes else {
            throw ContextLexicalSourceError.invalidQuery
        }
        guard index.records.count <= limits.maximumRecords,
              index.filesystemEntries.count <= limits.maximumRecords,
              index.bytesIndexed >= 0, index.bytesIndexed <= limits.maximumIndexBytes,
              (0...limits.maximumRecords).contains(index.skippedNonText),
              (0...limits.maximumRecords).contains(index.skippedTooLarge) else {
            throw ContextLexicalSourceError.invalidIndex
        }

        var records: [MainframeDocumentRecord] = []
        var identities: [RecordIdentity] = []
        var digests: [Data: String] = [:]
        var bytes = 0
        var clippedFiles = 0
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        for record in index.records.sorted(by: { Data($0.path.utf8).lexicographicallyPrecedes(Data($1.path.utf8)) }) {
            let path = Data(record.path.utf8)
            let count = record.text.utf8.count
            guard Self.validPath(record.path),
                  Data(record.name.utf8) == Data(record.path.split(separator: "/").last!.utf8),
                  record.byteCount == count, count <= limits.maximumIndexBytes - bytes,
                  digests[path] == nil else { throw ContextLexicalSourceError.invalidIndex }
            bytes += count
            let digest = Self.digest(Data(record.text.utf8))
            digests[path] = digest
            identities.append(.init(path: record.path, cachedTextDigest: digest, byteCount: count))
            let ext = (record.path as NSString).pathExtension.lowercased()
            // Reparse cached source bytes. Caller-supplied headings/frontmatter
            // and lifecycle projections cannot manufacture Find candidates.
            records.append(.init(
                path: record.path, name: record.name,
                zone: .classify(relativePath: record.path),
                recordScope: .derive(relativePath: record.path), text: record.text,
                byteCount: count,
                markdown: ["md", "markdown", "mdown", "mkd"].contains(ext)
                    ? MainframeMarkdownParser.parse(record.text) : nil
            ))
            // Measure an existing Find bound, without supplying search hits.
            if record.text.split(separator: "\n", omittingEmptySubsequences: false)
                .lazy.filter({ String($0).localizedCaseInsensitiveContains(needle) }).prefix(4).count > 3 {
                clippedFiles += 1
            }
        }
        guard bytes == index.bytesIndexed else { throw ContextLexicalSourceError.invalidIndex }
        let validated = MainframeContentIndex(
            records: records, filesystemEntries: [],
            filesystemIndexTruncated: index.filesystemIndexTruncated,
            contentTruncated: index.contentTruncated, bytesIndexed: bytes,
            skippedNonText: index.skippedNonText, skippedTooLarge: index.skippedTooLarge
        )
        let found = MainframeTextSearch.search(validated, query: query, limit: limits.maximumNominations + 1)
        let coverage = ContextLexicalCoverage(
            filesystemIndexTruncated: index.filesystemIndexTruncated,
            contentTruncated: index.contentTruncated, skippedNonText: index.skippedNonText,
            skippedTooLarge: index.skippedTooLarge, resultClipped: found.hits.count > limits.maximumNominations,
            filesWithClippedContentHits: clippedFiles, indexedRecordCount: records.count,
            indexedByteCount: bytes, maximumNominations: limits.maximumNominations,
            contentHitsPerFileLimit: 3,
            excludedComponentNames: MainframeExplorerScanner.defaultIgnoredNames.sorted()
        )
        let snapshot = Self.digest(Self.encoded(DiscoveryIdentity(
            version: Self.version, root: root.absoluteString, query: query,
            records: identities, coverage: coverage
        )))
        var nominations: [ContextLexicalNomination] = []
        var seen: Set<Data> = []
        for hit in found.hits.prefix(limits.maximumNominations).sorted(by: Self.hitSortsBefore) {
            guard let digest = digests[Data(hit.path.utf8)] else { throw ContextLexicalSourceError.invalidIndex }
            let identity = NominationIdentity(
                snapshotIdentity: snapshot, path: hit.path, line: hit.line,
                preview: hit.excerpt, kind: hit.kind.rawValue, score: hit.score, cachedTextDigest: digest
            )
            let id = "lexical:\(Self.digest(Self.encoded(identity)))"
            guard seen.insert(Data(id.utf8)).inserted else { throw ContextLexicalSourceError.invalidIndex }
            nominations.append(.init(id: id, hit: hit, digest: digest))
        }
        return .init(snapshotIdentity: snapshot, root: root.absoluteString, query: query,
                     nominations: nominations, coverage: coverage)
    }

    public func expand(
        batch: ContextLexicalNominationBatch, selection: ContextLexicalSourceSelection,
        root: URL, query: String, requiredRequests: [ContextFileSourceRequest] = [], observedAt: Date
    ) throws -> ContextLexicalSourceExpansionBatch {
        try expand(batch: batch, selection: selection, root: root, query: query,
                   requiredRequests: requiredRequests, observedAt: observedAt, afterFirstRead: nil)
    }

    // Owned fixture interposition forwards only to the unchanged reader's real
    // second-pass check. It does not inject bytes, identities, or observations.
    func expand(
        batch: ContextLexicalNominationBatch, selection: ContextLexicalSourceSelection,
        root: URL, query: String, requiredRequests: [ContextFileSourceRequest] = [], observedAt: Date,
        afterFirstRead: ((String) -> Void)?
    ) throws -> ContextLexicalSourceExpansionBatch {
        guard selection.generationID == batch.generationID,
              Data(selection.snapshotIdentity.utf8) == Data(batch.snapshotIdentity.utf8) else {
            throw ContextLexicalSourceError.foreignSelection
        }
        guard Data(root.absoluteString.utf8) == Data(batch.declaredRoot.utf8),
              Data(query.utf8) == Data(batch.query.utf8) else { throw ContextLexicalSourceError.wrongRootOrQuery }
        let byID = Dictionary(uniqueKeysWithValues: batch.nominations.map { (Data($0.id.utf8), $0) })
        var requests = requiredRequests
        var reasons: [Data: [ContextInclusionReason]] = [:]
        for item in selection.items {
            guard let nomination = byID[Data(item.nominationID.utf8)] else {
                throw ContextLexicalSourceError.nominationNotFound
            }
            let request = ContextFileSourceRequest(
                relativePath: nomination.relativePath, origin: item.isPinned ? .operatorPin : .selectedFile,
                lineRange: item.lineRange, expectedContentDigest: nomination.cachedTextDigest
            )
            requests.append(request)
            reasons[Self.encoded(request), default: []].append(.init(.lexicalMatch, detail: nomination.id))
        }
        let observed = ContextFileSourceAdapter(limits: sourceLimits).observe(
            root: root, requests: requests, observedAt: observedAt, afterFirstRead: afterFirstRead
        )
        let entries = observed.observations.compactMap { observation -> ContextSetEntry? in
            guard let entry = observation.candidateEntry else { return nil }
            return ContextSetEntry(
                item: entry.item, disposition: entry.disposition, representation: entry.representation,
                inclusionReasons: entry.inclusionReasons + (reasons[Self.encoded(observation.request)] ?? []),
                contentDigest: entry.contentDigest, truncationReason: entry.truncationReason,
                dispositionReason: entry.dispositionReason, duplicateItemIDs: entry.duplicateItemIDs,
                duplicateSourceReferences: entry.duplicateSourceReferences, supersedes: entry.supersedes
            )
        }.sorted {
            if $0.item.isPinned != $1.item.isPinned { return $0.item.isPinned }
            return Self.encoded($0).lexicographicallyPrecedes(Self.encoded($1))
        }
        return .init(snapshotIdentity: batch.snapshotIdentity, sourceBatch: observed,
                     coverage: batch.coverage, candidateEntries: entries)
    }

    private struct RecordIdentity: Encodable {
        let path: String
        let cachedTextDigest: String
        let byteCount: Int
    }
    private struct DiscoveryIdentity: Encodable {
        let version: String
        let root: String
        let query: String
        let records: [RecordIdentity]
        let coverage: ContextLexicalCoverage
    }
    private struct NominationIdentity: Encodable {
        let snapshotIdentity: String
        let path: String
        let line: Int
        let preview: String
        let kind: String
        let score: Int
        let cachedTextDigest: String
    }

    private static func validPath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && path.utf8.count < 4_096 && !path.hasPrefix("/") && !path.utf8.contains(0)
            && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".."
                && !MainframeExplorerScanner.defaultIgnoredNames.contains(String($0)) }
    }

    private static func hitSortsBefore(_ left: MainframeSearchHit, _ right: MainframeSearchHit) -> Bool {
        if left.score != right.score { return left.score < right.score }
        let leftPath = Data(left.path.utf8), rightPath = Data(right.path.utf8)
        if leftPath != rightPath { return leftPath.lexicographicallyPrecedes(rightPath) }
        if left.line != right.line { return left.line < right.line }
        let leftKind = Data(left.kind.rawValue.utf8), rightKind = Data(right.kind.rawValue.utf8)
        if leftKind != rightKind { return leftKind.lexicographicallyPrecedes(rightKind) }
        return Data(left.excerpt.utf8).lexicographicallyPrecedes(Data(right.excerpt.utf8))
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func encoded<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try! encoder.encode(value)
    }
}
