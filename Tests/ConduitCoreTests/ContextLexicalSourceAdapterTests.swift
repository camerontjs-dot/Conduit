import Foundation
import XCTest
@testable import ConduitCore

final class ContextLexicalSourceAdapterTests: XCTestCase {
    private let clock = Date(timeIntervalSince1970: 1_700_000_000)
    private let fm = FileManager.default
    private let adapter = ContextLexicalSourceAdapter()

    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = fm.temporaryDirectory.appendingPathComponent("conduit-lexical-test-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try body(root)
    }

    private func write(_ root: URL, _ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func record(_ path: String, _ text: String, name: String? = nil, count: Int? = nil,
                        markdown: MainframeMarkdownDocument? = nil) -> MainframeDocumentRecord {
        .init(path: path, name: name ?? String(path.split(separator: "/").last ?? ""),
              zone: .system, recordScope: nil, text: text, byteCount: count ?? text.utf8.count,
              markdown: markdown)
    }

    private func index(_ records: [MainframeDocumentRecord], bytes: Int? = nil,
                       filesystemPartial: Bool = false, contentPartial: Bool = false,
                       nonText: Int = 0, tooLarge: Int = 0) -> MainframeContentIndex {
        .init(records: records, filesystemEntries: [], filesystemIndexTruncated: filesystemPartial,
              contentTruncated: contentPartial, bytesIndexed: bytes ?? records.reduce(0) { $0 + $1.byteCount },
              skippedNonText: nonText, skippedTooLarge: tooLarge)
    }

    private func discover(_ root: URL, _ index: MainframeContentIndex? = nil, query: String = "needle",
                          adapter: ContextLexicalSourceAdapter? = nil) throws -> ContextLexicalNominationBatch {
        try (adapter ?? self.adapter).discover(index: try index ?? MainframeContentIndexer().build(root: root),
                                              root: root, query: query)
    }

    private func expand(_ root: URL, _ batch: ContextLexicalNominationBatch,
                        ids: [String]? = nil, pins: Bool = false, range: ClosedRange<Int>? = nil,
                        required: [ContextFileSourceRequest] = [],
                        adapter: ContextLexicalSourceAdapter? = nil,
                        afterRead: ((String) -> Void)? = nil) throws -> ContextLexicalSourceExpansionBatch {
        let selected = try batch.select((ids ?? batch.nominations.map(\.id)).map {
            .init(nominationID: $0, lineRange: range, isPinned: pins)
        })
        return try (adapter ?? self.adapter).expand(
            batch: batch, selection: selected, root: root, query: batch.query,
            requiredRequests: required, observedAt: clock, afterFirstRead: afterRead
        )
    }

    private func assertError(_ expected: ContextLexicalSourceError, _ action: () throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try action(), file: file, line: line) {
            XCTAssertEqual($0 as? ContextLexicalSourceError, expected, file: file, line: line)
        }
    }

    func testActualIndexFindSelectionAndReadRemainSeparate() throws {
        try withRoot { root in
            let original = "  needle source  \r\n"
            try write(root, "10_knowledge/source.txt", original)
            let batch = try discover(root)
            XCTAssertEqual(batch.nominations.count, 1)
            XCTAssertEqual(batch.nominations[0].preview, "needle source")
            let none = try expand(root, batch, ids: [])
            XCTAssertTrue(none.sourceBatch.observations.isEmpty)
            XCTAssertTrue(none.candidateEntries.isEmpty)
            let manifest = ContextManifestCompiler.compile(
                contextSet: try none.makeContextSet(id: "empty", objective: "Inspect"),
                destination: .init(runtime: "fixture"), budget: .init()
            )
            XCTAssertTrue(manifest.deliveredEntries.isEmpty)
            let read = try expand(root, batch)
            XCTAssertTrue(read.isHandoffEligible)
            XCTAssertEqual(read.sourceBatch.observations[0].snapshot?.representedBytes, Data(original.utf8))
            XCTAssertEqual(read.candidateEntries[0].item.authority, .filesystemSource)
            XCTAssertEqual(read.candidateEntries[0].item.freshness, .unknown)
            XCTAssertEqual(read.candidateEntries[0].disposition, .expanded)
            XCTAssertEqual(Set(read.candidateEntries[0].inclusionReasons.map(\.kind)),
                           [.lexicalMatch, .explicitExpansion, .exactIdentity])
        }
    }

    func testDiscoveryDoesNotReadMissingDeclaredFiles() throws {
        try withRoot { root in
            let batch = try discover(root, index([record("missing.txt", "needle")]))
            XCTAssertEqual(batch.nominations.count, 1)
            let noSelection = try expand(root, batch, ids: [])
            XCTAssertTrue(noSelection.sourceBatch.isComplete)
            let selected = try expand(root, batch)
            XCTAssertEqual(selected.sourceBatch.observations[0].failure?.code, .missing)
            assertError(.incompleteSourceObservation) { _ = try selected.makeContextSet(id: "set", objective: "Read") }
        }
    }

    func testSourceIdentityRejectsSameLengthCachedMutationAndDeletion() throws {
        try withRoot { root in
            try write(root, "a.txt", "needle content\n")
            let batch = try discover(root)
            try write(root, "a.txt", "absent content\n")
            let stale = try expand(root, batch)
            XCTAssertEqual(stale.sourceBatch.observations[0].failure?.code, .expectedIdentityMismatch)
            XCTAssertNotNil(stale.sourceBatch.observations[0].observedSourceContentDigest)
            XCTAssertTrue(stale.candidateEntries.isEmpty)
            XCTAssertFalse(stale.isHandoffEligible)
            try fm.removeItem(at: root.appendingPathComponent("a.txt"))
            XCTAssertEqual(try expand(root, batch).sourceBatch.observations[0].failure?.code, .missing)
        }
    }

    func testChangedDuringPhysicalReadAndObjectReplacementRemainNegative() throws {
        try withRoot { root in
            for replacement in [false, true] {
                try write(root, "a.txt", "needle content\n")
                let batch = try discover(root)
                var interposed = 0
                let result = try expand(root, batch, afterRead: { _ in
                    interposed += 1
                    if replacement { try! self.fm.removeItem(at: root.appendingPathComponent("a.txt")) }
                    try! self.write(root, "a.txt", "absent content\n")
                })
                XCTAssertEqual(interposed, 1)
                XCTAssertEqual(result.sourceBatch.observations[0].failure?.code, .changedDuringRead)
                XCTAssertNil(result.sourceBatch.observations[0].snapshot)
                XCTAssertFalse(result.isHandoffEligible)
            }
        }
    }

    func testPhysicalLeafParentAndRootLinksNeverBecomeSource() throws {
        try withRoot { root in
            let outside = root.appendingPathComponent("outside")
            try write(root, "outside/a.txt", "needle")
            try fm.createSymbolicLink(at: root.appendingPathComponent("leaf"), withDestinationURL: outside.appendingPathComponent("a.txt"))
            try fm.createSymbolicLink(at: root.appendingPathComponent("parent"), withDestinationURL: outside)
            for path in ["leaf", "parent/a.txt"] {
                let batch = try discover(root, index([record(path, "needle")]))
                XCTAssertEqual(try expand(root, batch).sourceBatch.observations[0].failure?.code, .symbolicLink)
            }
            let rootLink = root.appendingPathComponent("root-link")
            try fm.createSymbolicLink(at: rootLink, withDestinationURL: outside)
            let batch = try discover(rootLink, index([record("a.txt", "needle")]))
            XCTAssertEqual(try expand(rootLink, batch).sourceBatch.batchFailure?.code, .symbolicLink)
        }
    }

    func testExplicitLinesUseExactReadBytesAndNeverSearchPreview() throws {
        try withRoot { root in
            let line = "   " + String(repeating: "x", count: 230) + " needle\r\n"
            try write(root, "a.txt", line + "second\n")
            let batch = try discover(root)
            XCTAssertNotEqual(Data(batch.nominations[0].preview.utf8), Data(line.utf8))
            let ranged = try expand(root, batch, range: 1...1)
            XCTAssertEqual(ranged.sourceBatch.observations[0].snapshot?.representedBytes, Data(line.utf8))
            XCTAssertEqual(ranged.candidateEntries[0].representation, .excerpt)
            XCTAssertNil(ranged.candidateEntries[0].contentDigest)
            for range in [0...1, 1...8] {
                XCTAssertEqual(try expand(root, batch, range: range).sourceBatch.observations[0].failure?.code, .invalidLineRange)
            }
        }
    }

    func testMultipleReasonsUnionAndMandatoryPinRetainsBudgetConflict() throws {
        try withRoot { root in
            try write(root, "a.md", "# needle\nneedle\n")
            let batch = try discover(root)
            XCTAssertGreaterThan(batch.nominations.count, 1)
            let expanded = try expand(root, batch, required: [
                .init(relativePath: "a.md", origin: .objective),
                .init(relativePath: "a.md", origin: .operatorPin),
                .init(relativePath: "a.md", origin: .requiredContract)
            ])
            let set = try expanded.makeContextSet(id: "set", objective: "Read")
            XCTAssertEqual(set.entries.count, 1)
            XCTAssertTrue(set.entries[0].item.isPinned)
            XCTAssertEqual(set.entries[0].disposition, .mandatory)
            XCTAssertEqual(set.entries[0].inclusionReasons.filter { $0.kind == .lexicalMatch }.count, batch.nominations.count)
            XCTAssertEqual(Set(set.entries[0].inclusionReasons.map(\.kind)),
                           [.lexicalMatch, .objective, .operatorPin, .requiredContract, .explicitExpansion, .exactIdentity])
            let unknown = ContextManifestCompiler.compile(contextSet: set, destination: .init(runtime: "fixture"), budget: .init())
            XCTAssertEqual(unknown.budget.state, .unknownDestinationCapacity)
            let conflict = ContextManifestCompiler.compile(
                contextSet: set, destination: .init(runtime: "fixture", capacityTokens: 0),
                budget: .init(reservedOutputTokens: 0, reservedToolTokens: 0)
            )
            XCTAssertEqual(conflict.budget.state, .hardContextExceedsCapacity)
            XCTAssertEqual(conflict.deliveredEntries.count, 1)
        }
    }

    func testExplicitSelectedPinSurvivesOrdinaryObjectiveDuplicate() throws {
        try withRoot { root in
            try write(root, "a.txt", "needle")
            let batch = try discover(root)
            let set = try expand(root, batch, pins: true, required: [.init(relativePath: "a.txt", origin: .objective)])
                .makeContextSet(id: "set", objective: "Read")
            XCTAssertTrue(set.entries[0].item.isPinned)
            XCTAssertEqual(set.entries[0].disposition, .mandatory)
            XCTAssertTrue(set.entries[0].inclusionReasons.contains { $0.kind == .lexicalMatch })
        }
    }

    func testAnyMissingHardReferenceRefusesCompleteHandoffWithValidSelection() throws {
        try withRoot { root in
            try write(root, "a.txt", "needle")
            let batch = try discover(root)
            for origin in [ContextFileSourceOrigin.objective, .operatorPin, .requiredContract] {
                let expanded = try expand(root, batch, required: [.init(relativePath: "missing", origin: origin)])
                XCTAssertEqual(expanded.candidateEntries.count, 1)
                XCTAssertEqual(expanded.sourceBatch.unresolvedRequests.map(\.origin), [origin])
                assertError(.incompleteSourceObservation) { _ = try expanded.makeContextSet(id: "set", objective: "Read") }
            }
        }
    }

    func testDuplicateMissingForeignAndStaleGenerationSelectionRefusedBeforeRead() throws {
        try withRoot { root in
            let cached = index([record("missing", "needle")])
            let batch = try discover(root, cached)
            let id = batch.nominations[0].id
            assertError(.duplicateSelection) { _ = try batch.select([.init(nominationID: id), .init(nominationID: id)]) }
            assertError(.nominationNotFound) { _ = try batch.select([.init(nominationID: "foreign")]) }
            let ticket = try batch.select([.init(nominationID: id)])
            let next = try discover(root, cached)
            XCTAssertEqual(batch.snapshotIdentity, next.snapshotIdentity)
            XCTAssertEqual(batch.nominations.map(\.id), next.nominations.map(\.id))
            XCTAssertNotEqual(batch.generationID, next.generationID)
            assertError(.foreignSelection) {
                _ = try adapter.expand(batch: next, selection: ticket, root: root, query: "needle", observedAt: clock)
            }
            // A receipt exists, but these types deliberately do not conform to
            // Decodable and have no public constructor for rehydrated authority.
            XCTAssertFalse(try JSONEncoder().encode(ticket).isEmpty)
        }
    }

    func testWrongRootAndByteDistinctQueryCannotRelabelSelectedAuthority() throws {
        try withRoot { root in
            let batch = try discover(root, index([record("a.txt", "needle")]))
            let ticket = try batch.select([.init(nominationID: batch.nominations[0].id)])
            assertError(.wrongRootOrQuery) {
                _ = try adapter.expand(batch: batch, selection: ticket, root: root.appendingPathComponent("other"), query: batch.query, observedAt: clock)
            }
            assertError(.wrongRootOrQuery) {
                _ = try adapter.expand(batch: batch, selection: ticket, root: root, query: " needle ", observedAt: clock)
            }
        }
    }

    func testActualFindResultAndPerFileClippingCannotHidePartialDiscovery() throws {
        try withRoot { root in
            try write(root, "a.txt", "needle\n")
            try write(root, "b.txt", "needle\n")
            let capped = ContextLexicalSourceAdapter(limits: .init(maximumNominations: 1))
            let batch = try discover(root, adapter: capped)
            XCTAssertEqual(batch.nominations.count, 1)
            XCTAssertTrue(batch.coverage.resultClipped)
            let selected = try expand(root, batch, adapter: capped)
            XCTAssertTrue(selected.sourceBatch.isComplete)
            assertError(.partialDiscovery) { _ = try selected.makeContextSet(id: "set", objective: "Read") }
            try fm.removeItem(at: root.appendingPathComponent("b.txt"))
            try write(root, "a.txt", "needle\nneedle\nneedle\nneedle\n")
            let perFile = try discover(root)
            XCTAssertEqual(perFile.nominations.count, 3)
            XCTAssertEqual(perFile.coverage.filesWithClippedContentHits, 1)
            XCTAssertEqual(perFile.coverage.contentHitsPerFileLimit, 3)
            assertError(.partialDiscovery) { _ = try expand(root, perFile).makeContextSet(id: "set", objective: "Read") }
        }
    }

    func testIndexPartialSkippedAndEmptyResultsAreExplicit() throws {
        try withRoot { root in
            let inputs = [index([], filesystemPartial: true), index([], contentPartial: true),
                          index([], nonText: 1), index([], tooLarge: 1)]
            for input in inputs {
                let batch = try discover(root, input)
                XCTAssertTrue(batch.nominations.isEmpty)
                XCTAssertTrue(batch.coverage.mayBeIncomplete)
                let empty = try expand(root, batch)
                XCTAssertTrue(empty.sourceBatch.isComplete)
                assertError(.partialDiscovery) { _ = try empty.makeContextSet(id: "set", objective: "Read") }
            }
            XCTAssertFalse(try discover(root, index([])).coverage.excludedComponentNames.isEmpty)
        }
    }

    func testMalformedDuplicateByteCountNameAndAggregateIndexesRefused() throws {
        try withRoot { root in
            let good = record("a.txt", "needle")
            for input in [index([good, good]), index([record("a.txt", "needle", name: "forged")]),
                          index([record("a.txt", "needle", count: 1)]), index([good], bytes: 1),
                          index([], bytes: -1), index([], nonText: -1), index([], tooLarge: Int.max)] {
                assertError(.invalidIndex) { _ = try discover(root, input) }
            }
        }
    }

    func testForgedHeadingAndFrontmatterAreReparsedFromCachedText() throws {
        try withRoot { root in
            let forged = MainframeMarkdownParser.parse("---\ntitle: needle\n---\n# needle\n")
            let input = index([record("a.md", "source without match", markdown: forged)])
            XCTAssertTrue(try discover(root, input).nominations.isEmpty)
            let real = index([record("a.md", "---\ntitle: needle\n---\n# needle\n", markdown: nil)])
            let kinds = try discover(root, real).nominations.map(\.kind)
            XCTAssertTrue(kinds.contains("heading"))
            XCTAssertTrue(kinds.contains("metadata"))
        }
    }

    func testOutsideAbsoluteDotNulAndExcludedCachedPathsRefused() throws {
        try withRoot { root in
            for path in ["/outside", "../outside", "dir/../outside", "dir//a", ".", "", "a\0b", ".git/config", "dir/.DS_Store"] {
                assertError(.invalidIndex) { _ = try discover(root, index([record(path, "needle")])) }
            }
        }
    }

    func testLimitsQueryAndNonFileRootRefused() throws {
        try withRoot { root in
            for limits in [ContextLexicalSourceLimits(maximumRecords: 0), .init(maximumIndexBytes: -1),
                           .init(maximumNominations: 0), .init(maximumNominations: 1_025), .init(maximumQueryBytes: 4_097)] {
                assertError(.invalidLimits) { _ = try discover(root, index([]), adapter: .init(limits: limits)) }
            }
            for query in ["", " \n", "needle\0", String(repeating: "x", count: 4_097)] {
                assertError(.invalidQuery) { _ = try discover(root, index([]), query: query) }
            }
            assertError(.invalidRoot) { _ = try discover(URL(string: "https://example.invalid/root")!, index([])) }
            assertError(.invalidRoot) { _ = try discover(URL(string: "file://example.invalid/root")!, index([])) }
            assertError(.invalidIndex) {
                _ = try discover(root, index([record("a", "needle")]), adapter: .init(limits: .init(maximumIndexBytes: 1)))
            }
        }
    }

    func testReadByteAndRequestLimitsAreExplicitWithoutSilentPrefixOrClip() throws {
        try withRoot { root in
            try write(root, "a.md", "# needle\nneedle\n")
            let batch = try discover(root)
            for limits in [ContextFileSourceLimits(maximumFileBytes: 1), .init(maximumTotalBytes: 1),
                           .init(maximumRequests: 1), .init(maximumFileBytes: 0)] {
                let bounded = ContextLexicalSourceAdapter(sourceLimits: limits)
                let result = try expand(root, batch, adapter: bounded)
                XCTAssertFalse(result.sourceBatch.isComplete)
                XCTAssertTrue(result.candidateEntries.isEmpty)
                assertError(.incompleteSourceObservation) { _ = try result.makeContextSet(id: "set", objective: "Read") }
            }
        }
    }

    func testExactUtf8QueryAndPathSpellingAndDelimiterIdentitiesRemainDistinct() throws {
        try withRoot { root in
            let composed = "caf\u{00e9}", decomposed = "cafe\u{0301}"
            let input = index([record(composed + ":a.md", "needle"), record(decomposed + ":a.md", "needle"),
                               record("a:content:1:b", "needle"), record("a", "b:content:1:needle")])
            let batch = try discover(root, input)
            XCTAssertEqual(batch.nominations.count, 4)
            XCTAssertEqual(Set(batch.nominations.map(\.id)).count, 4)
            XCTAssertEqual(Set(batch.nominations.map { Data($0.relativePath.utf8) }).count, 4)
            let cached = index([record("a.md", composed)])
            let a = try discover(root, cached, query: composed)
            let b = try discover(root, cached, query: decomposed)
            XCTAssertNotEqual(a.snapshotIdentity, b.snapshotIdentity)
            XCTAssertNotEqual(a.nominations.map(\.id), b.nominations.map(\.id))
            let selection = try a.select(a.nominations.map { .init(nominationID: $0.id) })
            assertError(.wrongRootOrQuery) {
                _ = try adapter.expand(batch: a, selection: selection, root: root, query: decomposed, observedAt: clock)
            }
        }
    }

    func testReorderedInputAndFreshGenerationKeepSourceManifestDeterministic() throws {
        try withRoot { root in
            try write(root, "a.txt", "needle a")
            try write(root, "A.txt", "needle b")
            // A case-insensitive filesystem can alias names, so this control
            // supplies byte-distinct cached records without claiming two files.
            let input = [record("Z.txt", "needle"), record("z.txt", "needle"), record("a.txt", "needle a")]
            let first = try discover(root, index(input))
            let reverse = try discover(root, index(Array(input.reversed())))
            XCTAssertEqual(first.snapshotIdentity, reverse.snapshotIdentity)
            XCTAssertEqual(first.nominations.map(\.id), reverse.nominations.map(\.id))
            XCTAssertNotEqual(first.generationID, reverse.generationID)
            let physical = try discover(root)
            let next = try discover(root)
            let firstSet = try expand(root, physical).makeContextSet(id: "set", objective: "Read")
            let nextSet = try expand(root, next).makeContextSet(id: "set", objective: "Read")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let destination = ContextDestination(runtime: "fixture")
            let budget = ContextBudget()
            XCTAssertEqual(try encoder.encode(ContextManifestCompiler.compile(contextSet: firstSet, destination: destination, budget: budget)),
                           try encoder.encode(ContextManifestCompiler.compile(contextSet: nextSet, destination: destination, budget: budget)))
        }
    }
}
