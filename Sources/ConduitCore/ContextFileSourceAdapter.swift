import CryptoKit
import Foundation

/// An explicit reason to inspect one exact file. This is not a retrieval
/// nomination, an objective parser, or permission to discover adjacent files.
public enum ContextFileSourceOrigin: String, Codable, CaseIterable, Sendable {
    case objective
    case selectedFile
    case operatorPin
    case requiredContract

    public var isRequired: Bool { self != .selectedFile }
}

public struct ContextFileSourceRequest: Equatable, Codable, Sendable {
    public let relativePath: String
    public let origin: ContextFileSourceOrigin
    public let lineRange: ClosedRange<Int>?
    /// SHA-256 of the entire source file, not a Git blob or excerpt digest.
    public let expectedContentDigest: String?

    public init(
        relativePath: String,
        origin: ContextFileSourceOrigin,
        lineRange: ClosedRange<Int>? = nil,
        expectedContentDigest: String? = nil
    ) {
        self.relativePath = relativePath
        self.origin = origin
        self.lineRange = lineRange
        self.expectedContentDigest = expectedContentDigest
    }
}

public struct ContextFileSourceLimits: Equatable, Codable, Sendable {
    public let maximumRequests: Int
    public let maximumFileBytes: Int
    public let maximumTotalBytes: Int

    public init(
        maximumRequests: Int = 128,
        maximumFileBytes: Int = 1_000_000,
        maximumTotalBytes: Int = 8_000_000
    ) {
        self.maximumRequests = maximumRequests
        self.maximumFileBytes = maximumFileBytes
        self.maximumTotalBytes = maximumTotalBytes
    }
}

public enum ContextFileSourceFailureCode: String, Codable, Sendable {
    case invalidLimits
    case requestLimitExceeded
    case invalidRequest
    case missing
    case unsafePath
    case symbolicLink
    case notDirectory
    case notRegularFile
    case fileByteLimitExceeded
    case totalByteLimitExceeded
    case nonUTF8
    case invalidLineRange
    case expectedIdentityMismatch
    case changedDuringRead
    case readFailed
}

public struct ContextFileSourceFailure: Error, Equatable, Codable, Sendable {
    public let code: ContextFileSourceFailureCode
    public let detail: String

    public init(_ code: ContextFileSourceFailureCode, detail: String) {
        self.code = code
        self.detail = detail
    }
}

/// Ephemeral bytes observed during a bounded read. The full source digest and
/// selected representation digest are separate. Neither is a Git identity or
/// a guarantee that the path will still contain these bytes at a later handoff.
public struct ContextFileSourceSnapshot: Equatable, Encodable, Sendable {
    public let sourceReference: String
    public let sourceContentDigest: String
    public let sourceByteCount: Int
    public let representedBytes: Data
    public let representedContentDigest: String
    public let observedAt: Date

    public var text: String { String(decoding: representedBytes, as: UTF8.self) }
}

public struct ContextFileSourceObservation: Equatable, Encodable, Sendable {
    public let request: ContextFileSourceRequest
    /// Present after a completed bounded read, even when the bytes fail UTF-8,
    /// expected-identity or line-range admission. A failed read supplies no hash.
    public let observedSourceContentDigest: String?
    public let snapshot: ContextFileSourceSnapshot?
    public let failure: ContextFileSourceFailure?
    public let candidateEntry: ContextSetEntry?

    public var isObserved: Bool { snapshot != nil && failure == nil && candidateEntry != nil }
}

public enum ContextFileSourceHandoffError: Error, Equatable {
    case incompleteObservation
}

public struct ContextFileSourceBatch: Equatable, Encodable, Sendable {
    public let observations: [ContextFileSourceObservation]
    /// Full-file byte budget reserved before each distinct bounded read,
    /// including a read that later fails mutation or content checks. Physical
    /// I/O uses two passes and EOF probes; this is not an I/O counter.
    public let sourceByteBudgetUsed: Int
    public let batchFailure: ContextFileSourceFailure?

    public var isComplete: Bool {
        batchFailure == nil && observations.allSatisfy(\.isObserved)
    }

    public var candidateEntries: [ContextSetEntry] {
        observations.compactMap(\.candidateEntry).sorted { left, right in
            // #108 keeps the preferred item while unioning duplicate reasons.
            // Prefer an explicit pin so its flag survives equal-strength merges.
            if left.item.isPinned != right.item.isPinned { return left.item.isPinned }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return (try! encoder.encode(left)).lexicographicallyPrecedes(try! encoder.encode(right))
        }
    }
    public var unresolvedRequests: [ContextFileSourceRequest] {
        observations.filter { !$0.isObserved }.map(\.request)
    }

    /// A complete handoff is refused if any requested source is unresolved,
    /// including objective references, pins and contracts. Callers can inspect
    /// partial observations, but cannot silently convert them into success here.
    /// This composes with the existing Context Set; it does not send worker input.
    public func makeContextSet(
        id: String,
        objective: String,
        taskIdentity: String? = nil,
        repositoryIdentity: ContextRepositoryIdentity? = nil
    ) throws -> ContextSet {
        guard isComplete else { throw ContextFileSourceHandoffError.incompleteObservation }
        return ContextSet(
            id: id,
            objective: objective,
            taskIdentity: taskIdentity,
            repositoryIdentity: repositoryIdentity,
            entries: candidateEntries,
            retrieverVersions: [ContextComponentVersion(
                name: "exact-file-source", version: ContextFileSourceAdapter.version
            )]
        ).deduplicated()
    }
}

/// Read-only deterministic adapter for explicit exact-file requests under one
/// selected root. No recursive scan, semantic retrieval, provider delivery or
/// source mutation occurs. Descendant links and Explorer's ignored names are
/// refused. Ancestor aliases of the selected root (such as macOS /tmp) are
/// canonicalized; a symbolic-link root itself is refused.
public struct ContextFileSourceAdapter: Sendable {
    public static let version = "context-exact-file-source-v1"
    private let limits: ContextFileSourceLimits

    public init(limits: ContextFileSourceLimits = ContextFileSourceLimits()) {
        self.limits = limits
    }

    public func observe(
        root: URL,
        requests: [ContextFileSourceRequest],
        observedAt: Date
    ) -> ContextFileSourceBatch {
        observe(root: root, requests: requests, observedAt: observedAt, afterFirstRead: nil)
    }

    // The internal interposition point lets repository tests physically mutate
    // an owned file between read passes. It supplies no bytes or identities and
    // is absent from the public adapter API.
    func observe(
        root: URL,
        requests: [ContextFileSourceRequest],
        observedAt: Date,
        afterFirstRead: ((String) -> Void)?
    ) -> ContextFileSourceBatch {
        guard limits.maximumRequests > 0, limits.maximumRequests <= 1_024,
              limits.maximumFileBytes > 0, limits.maximumFileBytes <= 16_000_000,
              limits.maximumTotalBytes > 0, limits.maximumTotalBytes <= 64_000_000 else {
            return Self.failedBatch(requests, .init(.invalidLimits, detail: "Read limits are outside supported bounds."))
        }
        guard requests.count <= limits.maximumRequests else {
            return Self.failedBatch(requests, .init(.requestLimitExceeded, detail: "Requested source count exceeds the batch limit."))
        }
        let ordered = requests.sorted {
            Self.encoded($0).lexicographicallyPrecedes(Self.encoded($1))
        }

        let reader: ContextFileSourceReader
        do { reader = try ContextFileSourceReader(root: root) }
        catch let failure as ContextFileSourceFailure { return Self.failedBatch(ordered, failure) }
        catch { return Self.failedBatch(ordered, .init(.readFailed, detail: "Cannot open selected root.")) }

        // UTF-8 bytes are used as dictionary keys so canonically equivalent
        // Swift Strings cannot silently collapse distinct request spellings.
        var reads: [Data: Result<Data, ContextFileSourceFailure>] = [:]
        var consumed = 0
        var observations: [ContextFileSourceObservation] = []
        for request in ordered {
            if let invalid = Self.invalidRequest(request) {
                observations.append(Self.failed(request, invalid))
                continue
            }
            let key = Data(request.relativePath.utf8)
            let read: Result<Data, ContextFileSourceFailure>
            if let existing = reads[key] {
                read = existing
            } else {
                do {
                    let remaining = limits.maximumTotalBytes - consumed
                    guard remaining > 0 else {
                        throw ContextFileSourceFailure(.totalByteLimitExceeded, detail: "Batch source byte budget is exhausted.")
                    }
                    let bytes = try reader.read(
                        relativePath: request.relativePath,
                        maximumBytes: min(limits.maximumFileBytes, remaining),
                        reserveBytes: { consumed += $0 },
                        afterFirstRead: afterFirstRead
                    )
                    read = .success(bytes)
                } catch let failure as ContextFileSourceFailure {
                    let boundedFailure = failure.code == .fileByteLimitExceeded
                        && limits.maximumTotalBytes - consumed < limits.maximumFileBytes
                        ? ContextFileSourceFailure(.totalByteLimitExceeded, detail: "Source exceeds the remaining batch byte budget.")
                        : failure
                    read = .failure(boundedFailure)
                } catch {
                    read = .failure(.init(.readFailed, detail: "Source read failed."))
                }
                reads[key] = read
            }
            switch read {
            case .failure(let failure): observations.append(Self.failed(request, failure))
            case .success(let bytes):
                observations.append(Self.observation(
                    request, bytes: bytes, rootPath: reader.canonicalRootPath, observedAt: observedAt
                ))
            }
        }
        return ContextFileSourceBatch(observations: observations, sourceByteBudgetUsed: consumed, batchFailure: nil)
    }

    private static func invalidRequest(_ request: ContextFileSourceRequest) -> ContextFileSourceFailure? {
        let path = request.relativePath
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path.utf8.count < 4_096,
              !path.hasPrefix("/"), !path.utf8.contains(0),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return .init(.unsafePath, detail: "Source must name one exact relative descendant path.")
        }
        guard !components.contains(where: { MainframeExplorerScanner.defaultIgnoredNames.contains(String($0)) }) else {
            return .init(.unsafePath, detail: "Source names an Explorer-excluded component.")
        }
        if let range = request.lineRange, range.lowerBound < 1 {
            return .init(.invalidLineRange, detail: "Source lines are one-based.")
        }
        if let expected = request.expectedContentDigest,
           expected.utf8.count != 64 || !expected.utf8.allSatisfy({
               (48...57).contains($0) || (97...102).contains($0)
           }) {
            return .init(.invalidRequest, detail: "Expected identity must be a lowercase full-source SHA-256 digest.")
        }
        return nil
    }

    private static func observation(
        _ request: ContextFileSourceRequest, bytes: Data, rootPath: String, observedAt: Date
    ) -> ContextFileSourceObservation {
        let sourceDigest = digest(bytes)
        guard String(data: bytes, encoding: .utf8) != nil else {
            return failed(request, .init(.nonUTF8, detail: "Source is not valid UTF-8 text."), observedDigest: sourceDigest)
        }
        guard request.expectedContentDigest == nil || request.expectedContentDigest == sourceDigest else {
            return failed(request, .init(.expectedIdentityMismatch, detail: "Observed source identity differs from the required identity."), observedDigest: sourceDigest)
        }
        let represented: Data
        if let range = request.lineRange {
            // LF delimits one-based lines; CR bytes and line terminators are
            // preserved. An empty file has line 1; a trailing LF adds an empty
            // final line. No selection is silently clipped to available lines.
            var starts = [0]
            for (index, byte) in bytes.enumerated() where byte == 10 { starts.append(index + 1) }
            guard range.upperBound <= starts.count else {
                return failed(request, .init(.invalidLineRange, detail: "Requested source lines do not all exist."), observedDigest: sourceDigest)
            }
            let lower = starts[range.lowerBound - 1]
            let upper = range.upperBound < starts.count ? starts[range.upperBound] : bytes.count
            represented = bytes.subdata(in: lower..<upper)
        } else {
            represented = bytes
        }
        let path = URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent(request.relativePath).path
        let revision = "sha256:\(sourceDigest)"
        let identity = FileCandidateIdentity(
            sourceReference: path, revisionIdentity: revision,
            lowerLine: request.lineRange?.lowerBound, upperLine: request.lineRange?.upperBound
        )
        let item = AgentContextItem(
            id: "exact-file:\(digest(encoded(identity)))",
            title: request.relativePath,
            kind: request.lineRange == nil ? .file : .selection,
            authority: .filesystemSource,
            sourceReference: path,
            revisionIdentity: revision,
            lineRange: request.lineRange,
            // A byte-derived estimate, not tokenizer or budget-acceptance truth.
            estimatedTokens: max(1, (represented.count + 3) / 4),
            isPinned: request.origin == .operatorPin,
            // A persisted candidate cannot promise that its path remains fresh.
            freshness: .unknown
        )
        let reason: ContextInclusionReason
        switch request.origin {
        case .objective: reason = .init(.objective, detail: request.relativePath)
        case .selectedFile: reason = .init(.explicitExpansion, detail: request.relativePath)
        case .operatorPin: reason = .init(.operatorPin, detail: request.relativePath)
        case .requiredContract: reason = .init(.requiredContract, detail: request.relativePath)
        }
        let entry = ContextSetEntry(
            item: item,
            disposition: request.origin.isRequired ? .mandatory : .expanded,
            representation: request.lineRange == nil ? .full : .excerpt,
            inclusionReasons: [reason, .init(.exactIdentity, detail: revision)],
            // Keep exact line selections separate under #108's structural
            // source/revision/range key, even when two ranges have equal bytes.
            contentDigest: request.lineRange == nil ? sourceDigest : nil
        )
        return ContextFileSourceObservation(
            request: request,
            observedSourceContentDigest: sourceDigest,
            snapshot: ContextFileSourceSnapshot(
                sourceReference: path, sourceContentDigest: sourceDigest,
                sourceByteCount: bytes.count, representedBytes: represented,
                representedContentDigest: digest(represented), observedAt: observedAt
            ),
            failure: nil,
            candidateEntry: entry
        )
    }

    private struct FileCandidateIdentity: Encodable {
        let sourceReference: String
        let revisionIdentity: String
        let lowerLine: Int?
        let upperLine: Int?
    }

    private static func failed(
        _ request: ContextFileSourceRequest, _ failure: ContextFileSourceFailure,
        observedDigest: String? = nil
    ) -> ContextFileSourceObservation {
        .init(request: request, observedSourceContentDigest: observedDigest, snapshot: nil, failure: failure, candidateEntry: nil)
    }

    private static func failedBatch(
        _ requests: [ContextFileSourceRequest], _ failure: ContextFileSourceFailure
    ) -> ContextFileSourceBatch {
        .init(observations: requests.map { failed($0, failure) }, sourceByteBudgetUsed: 0, batchFailure: failure)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func encoded<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // These internal values contain only strings, integers and a valid
        // ClosedRange. Encoding cannot fail; no caller bytes are interpreted.
        return try! encoder.encode(value)
    }
}
