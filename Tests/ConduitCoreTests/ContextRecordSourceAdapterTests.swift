import Foundation
import XCTest
@testable import ConduitCore

final class ContextRecordSourceAdapterTests: XCTestCase {
    private let clock = Date(timeIntervalSince1970: 1_700_000_000)
    private let fm = FileManager.default
    private let adapter = ContextRecordSourceAdapter()

    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = fm.temporaryDirectory.appendingPathComponent("conduit-record-test-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try body(root)
    }

    private func write(_ root: URL, _ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func request(
        _ path: String, _ provenance: ContextRecordSourceProvenance = .testReceipt,
        origin: ContextFileSourceOrigin = .selectedFile, range: ClosedRange<Int>? = nil,
        expected: String? = nil, task: String? = nil, freshness: AgentContextFreshness = .unknown
    ) -> ContextRecordSourceRequest {
        .init(file: .init(relativePath: path, origin: origin, lineRange: range,
                         expectedContentDigest: expected), provenance: provenance,
              associatedTaskIdentity: task, freshness: freshness)
    }

    private func observe(
        _ root: URL, _ requests: [ContextRecordSourceRequest],
        required: [ContextFileSourceRequest] = [], using adapter: ContextRecordSourceAdapter? = nil
    ) throws -> ContextRecordSourceBatch {
        try (adapter ?? self.adapter).observe(root: root, requests: requests,
                                             requiredRequests: required, observedAt: clock)
    }

    private func assertError(
        _ expected: ContextRecordSourceError, _ action: () throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try action(), file: file, line: line) {
            XCTAssertEqual($0 as? ContextRecordSourceError, expected, file: file, line: line)
        }
    }

    func testSelectedRecordClassesRetainIdenticalBytesWithoutAuthorityPromotion() throws {
        try withRoot { root in
            let text = "{\"status\":\"PASS\",\"verified\":true,\"freshness\":\"current\"}\n"
            try write(root, "record.json", text)
            let batch = try observe(root, [.agentArtifact, .testReceipt, .lifecycleRecord].map {
                request("record.json", $0, task: "fixture-task")
            })
            XCTAssertTrue(batch.isHandoffEligible)
            XCTAssertEqual(batch.sourceByteBudgetUsed, text.utf8.count)
            XCTAssertTrue(batch.requiredSourceObservations.isEmpty)
            XCTAssertEqual(Set(batch.candidateEntries.map { $0.item.authority }),
                           Set([AgentContextAuthority.agentOutput, .testReceipt, .lifecycleRecord]))
            XCTAssertTrue(batch.candidateEntries.allSatisfy { $0.item.freshness == .unknown })
            XCTAssertTrue(batch.observations.allSatisfy { $0.snapshot?.representedBytes == Data(text.utf8) })
            let manifest = ContextManifestCompiler.compile(
                contextSet: try batch.makeContextSet(id: "set", objective: "Inspect records"),
                destination: .init(), budget: .init()
            )
            XCTAssertEqual(manifest.deliveredEntries.count, 3)
            XCTAssertEqual(Set(manifest.deliveredEntries.map(\.authorityClass)),
                           Set([AgentContextAuthorityClass.agentOutput, .observation, .source]))
            XCTAssertFalse(batch.candidateEntries.contains { $0.item.authority == .filesystemSource })
            XCTAssertEqual(Set(batch.candidateEntries.map { $0.item.id }).count, 3)
        }
    }

    func testNoSelectionDoesNotDiscoverNearbyReceiptsOrArtifacts() throws {
        try withRoot { root in
            try write(root, "latest-receipt.json", "PASS")
            let batch = try observe(root, [])
            XCTAssertTrue(batch.isHandoffEligible)
            XCTAssertTrue(batch.observations.isEmpty)
            XCTAssertEqual(batch.sourceByteBudgetUsed, 0)
            XCTAssertTrue(try batch.makeContextSet(id: "empty", objective: "Inspect").entries.isEmpty)
        }
    }

    func testUnknownProvenanceAndCurrentFreshnessAreRefusedBeforeReading() throws {
        try withRoot { root in
            assertError(.unknownProvenance) { _ = try observe(root, [request("missing", .unknown)]) }
            assertError(.unsupportedCurrentFreshness) {
                _ = try observe(root, [request("missing", freshness: .current)])
            }
            for invalid in ["", " \n", "task\0id", String(repeating: "a", count: 4_097)] {
                assertError(.invalidDeclaration) { _ = try observe(root, [request("missing", task: invalid)]) }
                assertError(.invalidDeclaration) {
                    _ = try observe(root, [request("missing", freshness: .stale(reason: invalid))])
                }
            }
        }
    }

    func testExplicitStalenessSurvivesSuccessfulReadAndPinBudgetPressure() throws {
        try withRoot { root in
            try write(root, "receipt.txt", "PASS")
            let stale = AgentContextFreshness.stale(reason: "Run belongs to a superseded candidate")
            let batch = try observe(root, [request("receipt.txt", origin: .operatorPin, freshness: stale)])
            XCTAssertTrue(batch.isHandoffEligible)
            XCTAssertEqual(batch.candidateEntries[0].item.freshness, stale)
            let set = try batch.makeContextSet(id: "set", objective: "Review failure")
            let manifest = ContextManifestCompiler.compile(
                contextSet: set, destination: .init(capacityTokens: 0),
                budget: .init(reservedOutputTokens: 0, reservedToolTokens: 0)
            )
            XCTAssertTrue(set.entries[0].item.isPinned)
            XCTAssertEqual(set.entries[0].disposition, .mandatory)
            XCTAssertEqual(set.entries[0].item.authority, .testReceipt)
            XCTAssertEqual(manifest.budget.state, .hardContextExceedsCapacity)
        }
    }

    func testMissingOptionalAndHardRecordRequestsRefuseCompleteHandoff() throws {
        try withRoot { root in
            try write(root, "available.txt", "observed")
            for origin in ContextFileSourceOrigin.allCases {
                let batch = try observe(root, [request("available.txt"), request("missing", origin: origin)])
                XCTAssertFalse(batch.isHandoffEligible)
                XCTAssertEqual(batch.candidateEntries.count, 1)
                XCTAssertEqual(batch.unresolvedRequests.map(\.file.origin), [origin])
                XCTAssertEqual(batch.observations.first { !$0.isObserved }?.failure?.code, .missing)
                assertError(.incompleteSourceObservation) {
                    _ = try batch.makeContextSet(id: "set", objective: "Inspect")
                }
            }
        }
    }

    func testSeparateMissingRequiredSourceCannotBeDroppedByValidReceipt() throws {
        try withRoot { root in
            try write(root, "receipt.txt", "PASS")
            let batch = try observe(root, [request("receipt.txt")],
                                    required: [.init(relativePath: "missing-contract", origin: .requiredContract)])
            XCTAssertTrue(batch.observations[0].isObserved)
            XCTAssertEqual(batch.requiredSourceObservations[0].failure?.code, .missing)
            XCTAssertFalse(batch.isComplete)
            assertError(.incompleteSourceObservation) { _ = try batch.makeContextSet(id: "set", objective: "Inspect") }
        }
    }

    func testStaleDigestAndChangedDuringReadCannotBecomeReceiptAuthority() throws {
        try withRoot { root in
            try write(root, "receipt.txt", "abc")
            let first = try observe(root, [request("receipt.txt")])
            let digest = try XCTUnwrap(first.observations[0].snapshot?.sourceContentDigest)
            XCTAssertEqual(digest, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
            try write(root, "receipt.txt", "xyz")
            let stale = try observe(root, [request("receipt.txt", origin: .operatorPin, expected: digest)])
            XCTAssertEqual(stale.observations[0].failure?.code, .expectedIdentityMismatch)
            XCTAssertNotNil(stale.observations[0].observedSourceContentDigest)
            XCTAssertNil(stale.observations[0].candidateEntry)
            let changed = try adapter.observe(
                root: root, requests: [request("receipt.txt")], observedAt: clock,
                afterFirstRead: { _ in try! self.write(root, "receipt.txt", "longer replacement") }
            )
            XCTAssertEqual(changed.observations[0].failure?.code, .changedDuringRead)
            XCTAssertNil(changed.observations[0].observedSourceContentDigest)
            XCTAssertFalse(changed.isHandoffEligible)
        }
    }

    func testUnsafeLinksWrongRootAndMalformedBytesRetainReaderFailures() throws {
        try withRoot { root in
            try write(root, "receipt.txt", "PASS")
            try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("receipt.txt"))
            XCTAssertEqual(try observe(root, [request("link")]).observations[0].failure?.code, .symbolicLink)
            for path in ["../outside", "/outside", "a//b", "a\0b", ".git/config"] {
                XCTAssertEqual(try observe(root, [request(path)]).observations[0].failure?.code, .unsafePath)
            }
            try Data([255, 254]).write(to: root.appendingPathComponent("binary"))
            let binary = try observe(root, [request("binary")])
            XCTAssertEqual(binary.observations[0].failure?.code, .nonUTF8)
            XCTAssertNotNil(binary.observations[0].observedSourceContentDigest)
            for url in ["https://example.invalid/root", "file://example.invalid/root"] {
                assertError(.invalidRoot) { _ = try observe(URL(string: url)!, [request("receipt.txt")]) }
            }
        }
    }

    func testLineSelectionPreservesExactBytesAndRangeIdentity() throws {
        try withRoot { root in
            try write(root, "record.txt", "α\r\nsame\nsame\n")
            let batch = try observe(root, [request("record.txt", range: 1...1)])
            XCTAssertEqual(batch.observations[0].snapshot?.representedBytes, Data("α\r\n".utf8))
            XCTAssertEqual(batch.candidateEntries[0].representation, .excerpt)
            XCTAssertEqual(batch.candidateEntries[0].item.kind, .testReceipt)
            XCTAssertNil(batch.candidateEntries[0].contentDigest)
            let ranges = try observe(root, [request("record.txt", range: 2...2), request("record.txt", range: 3...3)])
            XCTAssertEqual(try ranges.makeContextSet(id: "ranges", objective: "Inspect").entries.count, 2)
            let invalid = try observe(root, [request("record.txt", range: 1...9)])
            XCTAssertEqual(invalid.observations[0].failure?.code, .invalidLineRange)
            XCTAssertFalse(invalid.isHandoffEligible)
        }
    }

    func testWholeBatchAndByteLimitsAreSharedWithRequiredSources() throws {
        try withRoot { root in
            try write(root, "a.txt", "abc")
            try write(root, "b.txt", "def")
            let capped = try observe(root, [request("a.txt")],
                                     required: [.init(relativePath: "b.txt", origin: .requiredContract)],
                                     using: .init(sourceLimits: .init(maximumRequests: 1)))
            XCTAssertEqual(capped.batchFailure?.code, .requestLimitExceeded)
            XCTAssertEqual(capped.observations.count, 1)
            XCTAssertEqual(capped.requiredSourceObservations.count, 1)
            XCTAssertEqual(capped.sourceByteBudgetUsed, 0)
            XCTAssertFalse(capped.isHandoffEligible)
            let bytes = try observe(root, [request("a.txt"), request("b.txt")],
                                    using: .init(sourceLimits: .init(maximumFileBytes: 4, maximumTotalBytes: 4)))
            XCTAssertEqual(bytes.observations.filter { $0.failure?.code == .totalByteLimitExceeded }.count, 1)
            XCTAssertFalse(bytes.isHandoffEligible)
        }
    }

    func testDuplicateReasonsAndPinnedAliasesSurviveRealCompiler() throws {
        try withRoot { root in
            try write(root, "a.txt", "receipt")
            try write(root, "b.txt", "receipt")
            let batch = try observe(root, [request("a.txt", task: "task:a"),
                                          request("b.txt", origin: .operatorPin, task: "task:b")])
            let set = try batch.makeContextSet(id: "set", objective: "Inspect")
            XCTAssertEqual(set.entries.count, 1)
            XCTAssertTrue(set.entries[0].item.isPinned)
            XCTAssertEqual(set.entries[0].item.authority, .testReceipt)
            XCTAssertEqual(set.entries[0].duplicateSourceReferences.count, 1)
            XCTAssertTrue(set.entries[0].inclusionReasons.contains { $0.detail == "Caller-declared task association: task:a" })
            XCTAssertTrue(set.entries[0].inclusionReasons.contains { $0.detail == "Caller-declared task association: task:b" })
            XCTAssertEqual(set.retrieverVersions.map(\.name), ["exact-file-source", "record-source"])
        }
    }

    func testDuplicateMetadataLossRefusesHandoffWithoutChangingCompiler() throws {
        try withRoot { root in
            try write(root, "record.txt", "same bytes")
            let stale = try observe(root, [
                request("record.txt", freshness: .stale(reason: "Superseded run")),
                request("record.txt", origin: .operatorPin)
            ])
            XCTAssertTrue(stale.isComplete)
            XCTAssertFalse(stale.isHandoffEligible)
            assertError(.incompatibleDuplicateMetadata) { _ = try stale.makeContextSet(id: "set", objective: "Inspect") }
            let role = try observe(root, [request("record.txt", .lifecycleRecord)],
                                   required: [.init(relativePath: "record.txt", origin: .operatorPin)])
            XCTAssertTrue(role.isComplete)
            XCTAssertFalse(role.isHandoffEligible)
            assertError(.incompatibleDuplicateMetadata) { _ = try role.makeContextSet(id: "set", objective: "Inspect") }
        }
    }

    func testDuplicateStalenessPolicyIsConservativeInBothDirections() throws {
        try withRoot { root in
            try write(root, "record.txt", "same bytes")
            let stale = AgentContextFreshness.stale(reason: "Superseded run")
            let retained = [request("record.txt", origin: .operatorPin, freshness: stale),
                            request("record.txt")]
            for ordered in [retained, Array(retained.reversed())] {
                let batch = try observe(root, ordered)
                XCTAssertTrue(batch.isHandoffEligible)
                XCTAssertEqual(try batch.makeContextSet(id: "set", objective: "Inspect").entries[0].item.freshness, stale)
            }
            let conflicting = [request("record.txt", freshness: stale),
                               request("record.txt", freshness: .stale(reason: "Replaced source"))]
            for ordered in [conflicting, Array(conflicting.reversed())] {
                let batch = try observe(root, ordered)
                XCTAssertTrue(batch.isComplete)
                XCTAssertFalse(batch.isHandoffEligible)
                assertError(.incompatibleDuplicateMetadata) { _ = try batch.makeContextSet(id: "set", objective: "Inspect") }
            }
        }
    }

    func testReorderedRequestsProduceIdenticalBatchAndManifest() throws {
        try withRoot { root in
            try write(root, "a|b.txt", "alpha")
            try write(root, "a.txt", "beta")
            let requests = [request("a|b.txt", .agentArtifact, task: "a:b"),
                            request("a.txt", .testReceipt, task: "a|b")]
            let first = try observe(root, requests)
            let second = try observe(root, Array(requests.reversed()))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            XCTAssertEqual(try encoder.encode(first), try encoder.encode(second))
            XCTAssertEqual(Set(first.candidateEntries.map { $0.item.id }).count, 2)
            let left = ContextManifestCompiler.compile(
                contextSet: try first.makeContextSet(id: "set", objective: "Inspect"), destination: .init(), budget: .init())
            let right = ContextManifestCompiler.compile(
                contextSet: try second.makeContextSet(id: "set", objective: "Inspect"), destination: .init(), budget: .init())
            XCTAssertEqual(try encoder.encode(left), try encoder.encode(right))
        }
    }
}
