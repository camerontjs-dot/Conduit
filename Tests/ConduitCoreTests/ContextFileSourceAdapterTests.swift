import Darwin
import Foundation
import XCTest
@testable import ConduitCore

final class ContextFileSourceAdapterTests: XCTestCase {
    private let clock = Date(timeIntervalSince1970: 1_700_000_000)
    private let fm = FileManager.default
    private let abcDigest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    private func withRoot(_ body: (URL) throws -> Void) throws {
        let container = fm.temporaryDirectory.appendingPathComponent("conduit-source-test-\(UUID().uuidString)")
        let root = container.appendingPathComponent("root")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: container) }
        try body(root)
    }

    private func write(_ root: URL, _ path: String, _ data: Data) throws {
        let file = root.appendingPathComponent(path)
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }

    private func text(_ root: URL, _ path: String, _ text: String) throws {
        try write(root, path, Data(text.utf8))
    }

    private func request(
        _ path: String, _ origin: ContextFileSourceOrigin = .selectedFile,
        range: ClosedRange<Int>? = nil, expected: String? = nil
    ) -> ContextFileSourceRequest {
        .init(relativePath: path, origin: origin, lineRange: range, expectedContentDigest: expected)
    }

    private func observe(
        _ root: URL, _ requests: [ContextFileSourceRequest],
        limits: ContextFileSourceLimits = .init(), afterFirstRead: ((String) -> Void)? = nil
    ) -> ContextFileSourceBatch {
        ContextFileSourceAdapter(limits: limits).observe(
            root: root, requests: requests, observedAt: clock, afterFirstRead: afterFirstRead
        )
    }

    private func assertIncomplete(
        _ batch: ContextFileSourceBatch, _ code: ContextFileSourceFailureCode,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(batch.isComplete, file: file, line: line)
        XCTAssertTrue(batch.observations.contains { $0.failure?.code == code }, file: file, line: line)
        XCTAssertThrowsError(try batch.makeContextSet(id: "set", objective: "Exact source"), file: file, line: line) {
            XCTAssertEqual($0 as? ContextFileSourceHandoffError, .incompleteObservation, file: file, line: line)
        }
    }

    func testObservedBytesHaveFullSourceIdentityAndUnknownLaterFreshness() throws {
        try withRoot { root in
            try text(root, "abc.txt", "abc")
            let batch = observe(root, [request("abc.txt", .objective)])
            XCTAssertTrue(batch.isComplete)
            let observation = try XCTUnwrap(batch.observations.first)
            let snapshot = try XCTUnwrap(observation.snapshot)
            XCTAssertEqual(snapshot.sourceContentDigest, abcDigest)
            XCTAssertEqual(snapshot.representedBytes, Data("abc".utf8))
            XCTAssertEqual(snapshot.observedAt, clock)
            XCTAssertEqual(batch.sourceByteBudgetUsed, 3)
            XCTAssertEqual(observation.candidateEntry?.item.authority, .filesystemSource)
            XCTAssertEqual(observation.candidateEntry?.item.freshness, .unknown)
            XCTAssertEqual(observation.candidateEntry?.item.revisionIdentity, "sha256:\(abcDigest)")
        }
    }

    func testAllReasonsUnionAndPinSurvivesHardBudgetConflict() throws {
        try withRoot { root in
            try text(root, "abc.txt", "abc")
            let requests = ContextFileSourceOrigin.allCases.map { request("abc.txt", $0) }
            let batch = observe(root, requests)
            let set = try batch.makeContextSet(id: "set", objective: "Keep hard source")
            XCTAssertEqual(batch.sourceByteBudgetUsed, 3)
            XCTAssertEqual(set.entries.count, 1)
            XCTAssertTrue(set.entries[0].item.isPinned)
            XCTAssertEqual(Set(set.entries[0].inclusionReasons.map(\.kind)),
                           [.objective, .operatorPin, .requiredContract, .explicitExpansion, .exactIdentity])
            let manifest = ContextManifestCompiler.compile(
                contextSet: set, destination: .init(runtime: "fixture", capacityTokens: 0),
                budget: .init(reservedOutputTokens: 0, reservedToolTokens: 0)
            )
            XCTAssertEqual(manifest.budget.state, .hardContextExceedsCapacity)
            XCTAssertEqual(set.entries[0].disposition, .mandatory)
        }
    }

    func testUnresolvedObjectivePinContractAndSelectionEachRefusePartialHandoff() throws {
        try withRoot { root in
            try text(root, "available.txt", "available")
            for origin in ContextFileSourceOrigin.allCases {
                let batch = observe(root, [request("available.txt"), request("missing.md", origin)])
                assertIncomplete(batch, .missing)
                XCTAssertEqual(batch.candidateEntries.count, 1)
                XCTAssertEqual(batch.unresolvedRequests.map(\.origin), [origin])
            }
        }
    }

    func testChangedAndDeletedSourceAndStaleExpectedIdentityRemainExplicit() throws {
        try withRoot { root in
            try text(root, "source.txt", "abc")
            let old = observe(root, [request("source.txt")])
            try text(root, "source.txt", "xyz")
            let new = observe(root, [request("source.txt")])
            XCTAssertNotEqual(old.candidateEntries[0].item.id, new.candidateEntries[0].item.id)
            let stale = observe(root, [request("source.txt", .operatorPin, expected: abcDigest)])
            assertIncomplete(stale, .expectedIdentityMismatch)
            XCTAssertEqual(stale.observations[0].observedSourceContentDigest, new.observations[0].snapshot?.sourceContentDigest)
            XCTAssertNil(stale.observations[0].candidateEntry)
            try fm.removeItem(at: root.appendingPathComponent("source.txt"))
            assertIncomplete(observe(root, [request("source.txt", .requiredContract)]), .missing)
        }
    }

    func testMalformedExpectedDigestAndNominationOriginCannotBecomeReadAuthority() throws {
        try withRoot { root in
            try text(root, "abc.txt", "abc")
            for expected in ["HEAD", String(repeating: "A", count: 64), "", String(repeating: "0", count: 40)] {
                let batch = observe(root, [request("abc.txt", .objective, expected: expected)])
                assertIncomplete(batch, .invalidRequest)
                XCTAssertEqual(batch.sourceByteBudgetUsed, 0)
            }
            let nomination = Data("{\"relativePath\":\"abc.txt\",\"origin\":\"mindGraphNomination\"}".utf8)
            XCTAssertThrowsError(try JSONDecoder().decode(ContextFileSourceRequest.self, from: nomination))
        }
    }

    func testOutsideAndMalformedExactPathsAndExplorerExclusionsAreRefused() throws {
        try withRoot { root in
            for path in ["/tmp/outside", "../sibling/file", "a/../file", "a//file", ".", "", "file\0suffix", ".git/config", "dir/.DS_Store"] {
                assertIncomplete(observe(root, [request(path, .operatorPin)]), .unsafePath)
            }
        }
    }

    func testLeafParentAndDanglingSymlinksNeverBecomeSource() throws {
        try withRoot { root in
            try text(root, "inside.txt", "inside")
            let outside = root.deletingLastPathComponent().appendingPathComponent("outside")
            try fm.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data("outside".utf8).write(to: outside.appendingPathComponent("source.txt"))
            try fm.createSymbolicLink(at: root.appendingPathComponent("inside-link"), withDestinationURL: root.appendingPathComponent("inside.txt"))
            try fm.createSymbolicLink(at: root.appendingPathComponent("outside-link"), withDestinationURL: outside.appendingPathComponent("source.txt"))
            try fm.createSymbolicLink(atPath: root.appendingPathComponent("dangling").path, withDestinationPath: "missing")
            try fm.createSymbolicLink(at: root.appendingPathComponent("parent-link"), withDestinationURL: outside)
            for path in ["inside-link", "outside-link", "dangling", "parent-link/source.txt"] {
                assertIncomplete(observe(root, [request(path)]), .symbolicLink)
            }
        }
    }

    func testSymlinkAndNonFileRootsAreRefused() throws {
        try withRoot { root in
            let link = root.deletingLastPathComponent().appendingPathComponent("root-link")
            try fm.createSymbolicLink(at: link, withDestinationURL: root)
            assertIncomplete(observe(link, [request("source.txt")]), .symbolicLink)
            assertIncomplete(observe(URL(string: "https://example.invalid/root")!, [request("source.txt")]), .unsafePath)
        }
    }

    func testDirectoryFileAncestorAndFIFOAreRefusedWithoutTraversalOrBlocking() throws {
        try withRoot { root in
            try fm.createDirectory(at: root.appendingPathComponent("directory"), withIntermediateDirectories: false)
            try text(root, "file", "file")
            XCTAssertEqual(mkfifo(root.appendingPathComponent("fifo").path, 0o600), 0)
            assertIncomplete(observe(root, [request("directory")]), .notRegularFile)
            assertIncomplete(observe(root, [request("file/child")]), .notDirectory)
            assertIncomplete(observe(root, [request("fifo")]), .notRegularFile)
        }
    }

    func testNonUTF8PreservesObservedDigestButCreatesNoCandidate() throws {
        try withRoot { root in
            try write(root, "binary", Data([255, 254, 0]))
            let batch = observe(root, [request("binary")])
            assertIncomplete(batch, .nonUTF8)
            XCTAssertNotNil(batch.observations[0].observedSourceContentDigest)
            XCTAssertNil(batch.observations[0].snapshot)
            XCTAssertEqual(batch.sourceByteBudgetUsed, 3)
        }
    }

    func testByteRequestAndInvalidLimitsFailWithoutSilentPartialAdmission() throws {
        try withRoot { root in
            try text(root, "a", "abc")
            try text(root, "b", "abcd")
            assertIncomplete(observe(root, [request("a")], limits: .init(maximumFileBytes: 2)), .fileByteLimitExceeded)
            let total = observe(root, [request("a"), request("b")], limits: .init(maximumFileBytes: 8, maximumTotalBytes: 6))
            assertIncomplete(total, .totalByteLimitExceeded)
            XCTAssertEqual(total.sourceByteBudgetUsed, 3)
            XCTAssertEqual(total.candidateEntries.count, 1)
            assertIncomplete(observe(root, [request("a"), request("b")], limits: .init(maximumRequests: 1)), .requestLimitExceeded)
            assertIncomplete(observe(root, [request("a")], limits: .init(maximumFileBytes: 0)), .invalidLimits)
        }
    }

    func testLineSelectionPreservesExactUTF8CRLFAndFullSourceIdentity() throws {
        try withRoot { root in
            try text(root, "lines", "α\r\nsecond\nthird\n")
            let batch = observe(root, [request("lines", .operatorPin, range: 1...2)])
            let snapshot = try XCTUnwrap(batch.observations[0].snapshot)
            XCTAssertEqual(snapshot.representedBytes, Data("α\r\nsecond\n".utf8))
            XCTAssertNotEqual(snapshot.sourceContentDigest, snapshot.representedContentDigest)
            XCTAssertEqual(batch.candidateEntries[0].item.lineRange, 1...2)
            XCTAssertEqual(batch.candidateEntries[0].representation, .excerpt)
        }
    }

    func testAbsentLinesAreNotClippedAndEqualRangesRemainSeparate() throws {
        try withRoot { root in
            try text(root, "lines", "same\nsame\n")
            assertIncomplete(observe(root, [request("lines", .requiredContract, range: 2...4)]), .invalidLineRange)
            assertIncomplete(observe(root, [request("lines", range: 0...1)]), .invalidLineRange)
            let batch = observe(root, [request("lines", range: 1...1), request("lines", range: 2...2)])
            XCTAssertEqual(try batch.makeContextSet(id: "set", objective: "Exact ranges").entries.count, 2)
        }
    }

    func testEmptyFinalLineAndBOMAreExplicitExactBytes() throws {
        try withRoot { root in
            try write(root, "empty", Data())
            XCTAssertEqual(observe(root, [request("empty", range: 1...1)]).observations[0].snapshot?.representedBytes, Data())
            try text(root, "trailing", "abc\n")
            XCTAssertEqual(observe(root, [request("trailing", range: 2...2)]).observations[0].snapshot?.representedBytes, Data())
            let bom = Data([239, 187, 191]) + Data("abc".utf8)
            try write(root, "bom", bom)
            XCTAssertEqual(observe(root, [request("bom")]).observations[0].snapshot?.representedBytes, bom)
        }
    }

    func testDelimiterNamesCannotCollideAndIdenticalPathsKeepAliasProvenance() throws {
        try withRoot { root in
            try text(root, "a|b", "left")
            try text(root, "a", "right")
            let distinct = observe(root, [request("a|b"), request("a")])
            XCTAssertEqual(Set(distinct.candidateEntries.map { $0.item.id }).count, 2)
            XCTAssertEqual(try distinct.makeContextSet(id: "set", objective: "Distinct").entries.count, 2)
            try text(root, "copy", "left")
            let aliases = try observe(root, [request("a|b", .objective), request("copy", .operatorPin)])
                .makeContextSet(id: "aliases", objective: "Retain aliases")
            XCTAssertEqual(aliases.entries.count, 1)
            XCTAssertEqual(aliases.entries[0].duplicateSourceReferences.count, 1)
            XCTAssertTrue(aliases.entries[0].item.isPinned)
        }
    }

    func testInputPermutationsProduceSameBatchAndContextSetBytes() throws {
        try withRoot { root in
            try text(root, "file", "content")
            let requests = ContextFileSourceOrigin.allCases.map { request("file", $0) }
            let first = observe(root, requests)
            let second = observe(root, Array(requests.reversed()))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            XCTAssertEqual(try encoder.encode(first), try encoder.encode(second))
            XCTAssertEqual(try encoder.encode(first.makeContextSet(id: "set", objective: "Stable")),
                           try encoder.encode(second.makeContextSet(id: "set", objective: "Stable")))
        }
    }

    func testNominationWithSameDigestRemainsDifferentAuthority() throws {
        try withRoot { root in
            try text(root, "file", "abc")
            let source = observe(root, [request("file")])
            let item = source.candidateEntries[0].item
            let nomination = ContextSetEntry(item: .init(
                id: "nomination", title: "Nomination", kind: .semanticNomination,
                authority: .mindGraphNomination, sourceReference: item.sourceReference,
                revisionIdentity: item.revisionIdentity
            ), disposition: .nominated, representation: .full, contentDigest: abcDigest)
            let set = ContextSet(id: "set", objective: "Keep authority", entries: source.candidateEntries + [nomination]).deduplicated()
            XCTAssertEqual(set.entries.count, 2)
            XCTAssertTrue(set.entries.contains { $0.item.authority == .mindGraphNomination && $0.disposition == .nominated })
        }
    }

    func testPhysicalSameLengthMutationIsRefused() throws {
        try withRoot { root in
            try text(root, "file", "AAAA")
            let batch = observe(root, [request("file", .operatorPin)], afterFirstRead: { _ in
                try! self.text(root, "file", "BBBB")
            })
            assertIncomplete(batch, .changedDuringRead)
            XCTAssertEqual(batch.sourceByteBudgetUsed, 4)
        }
    }

    func testPhysicalAtomicReplacementDeletionAndTruncationAreRefused() throws {
        try withRoot { root in
            for action in 0..<3 {
                try text(root, "file", "AAAA")
                let batch = observe(root, [request("file")], afterFirstRead: { _ in
                    switch action {
                    case 0: try! Data("BBBB".utf8).write(to: root.appendingPathComponent("file"), options: .atomic)
                    case 1: try! self.fm.removeItem(at: root.appendingPathComponent("file"))
                    default: try! self.text(root, "file", "A")
                    }
                })
                assertIncomplete(batch, .changedDuringRead)
            }
        }
    }

    func testPhysicalAncestorAndRootReplacementAreRefused() throws {
        try withRoot { root in
            try text(root, "parent/file", "AAAA")
            let ancestor = observe(root, [request("parent/file")], afterFirstRead: { _ in
                try! self.fm.moveItem(at: root.appendingPathComponent("parent"), to: root.appendingPathComponent("old-parent"))
                try! self.text(root, "parent/file", "BBBB")
            })
            assertIncomplete(ancestor, .changedDuringRead)
            let renamed = root.deletingLastPathComponent().appendingPathComponent("old-root")
            let replacedRoot = observe(root, [request("parent/file")], afterFirstRead: { _ in
                try! self.fm.moveItem(at: root, to: renamed)
                try! self.text(root, "parent/file", "CCCC")
            })
            assertIncomplete(replacedRoot, .changedDuringRead)
        }
    }

    func testPhysicalSymlinkSubstitutionIsRefused() throws {
        try withRoot { root in
            try text(root, "file", "AAAA")
            try text(root, "target", "BBBB")
            let batch = observe(root, [request("file")], afterFirstRead: { _ in
                try! self.fm.removeItem(at: root.appendingPathComponent("file"))
                try! self.fm.createSymbolicLink(at: root.appendingPathComponent("file"), withDestinationURL: root.appendingPathComponent("target"))
            })
            assertIncomplete(batch, .changedDuringRead)
        }
    }

    func testFailedPhysicalReadStillDebitsTotalByteBudget() throws {
        try withRoot { root in
            try text(root, "a", "AA")
            try text(root, "b", "BBBB")
            let batch = observe(root, [request("a"), request("b")],
                limits: .init(maximumFileBytes: 4, maximumTotalBytes: 4), afterFirstRead: { name in
                    if name == "a" { try! self.text(root, "a", "XX") }
                })
            assertIncomplete(batch, .changedDuringRead)
            XCTAssertEqual(batch.sourceByteBudgetUsed, 2)
            XCTAssertTrue(batch.observations.contains { $0.failure?.code == .totalByteLimitExceeded })
        }
    }

    func testRepeatedObservationsReleaseDescriptorsAndCanonicalizeMacOSTempAlias() throws {
        try withRoot { root in
            try text(root, "file", "abc")
            let before = try fm.contentsOfDirectory(atPath: "/dev/fd").count
            for _ in 0..<64 { _ = observe(root, [request("file"), request("missing")]) }
            XCTAssertEqual(try fm.contentsOfDirectory(atPath: "/dev/fd").count, before)
            let canonical = root.resolvingSymlinksInPath()
            let alias = URL(fileURLWithPath: canonical.path.replacingOccurrences(of: "/private/var/", with: "/var/"))
            XCTAssertEqual(observe(canonical, [request("file")]), observe(alias, [request("file")]))
        }
    }
}
