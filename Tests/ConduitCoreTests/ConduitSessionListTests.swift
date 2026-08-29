import XCTest
@testable import ConduitCore

/// Mirrors the deterministic cases in `Sources/ConduitSelfTest`. Keep in step.
final class ConduitSessionListTests: XCTestCase {
    func testShortInventoryReturnsWhole() {
        let w = ConduitSessionListPage.window(total: 12, cursor: nil, limit: 40)
        XCTAssertEqual(w.startIndex, 0)
        XCTAssertEqual(w.endIndex, 12)
        XCTAssertFalse(w.hasMore)
        XCTAssertEqual(w.cursorState, .ok)
    }

    func testLongInventoryPagesAndAdmitsThereIsMore() {
        let first = ConduitSessionListPage.window(total: 64, cursor: nil, limit: 40)
        XCTAssertEqual(first.count, 40)
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(first.nextCursor, "v1:40")
        XCTAssertEqual(first.total, 64)
    }

    func testPagingCoversTheInventoryWithoutGapOrOverlap() {
        let first = ConduitSessionListPage.window(total: 64, cursor: nil, limit: 40)
        let second = ConduitSessionListPage.window(
            total: 64,
            cursor: first.nextCursor,
            limit: 40
        )
        XCTAssertEqual(second.startIndex, first.endIndex)
        XCTAssertEqual(second.count, 24)
        XCTAssertFalse(second.hasMore)
        XCTAssertEqual(first.count + second.count, 64)
    }

    func testCursorPastTheEndIsStaleNotAnError() {
        let w = ConduitSessionListPage.window(total: 64, cursor: "v1:999")
        XCTAssertEqual(w.cursorState, .ahead)
        XCTAssertEqual(w.count, 0)
    }

    func testUnparseableCursorRestartsAndSaysSo() {
        let w = ConduitSessionListPage.window(total: 64, cursor: "nonsense")
        XCTAssertEqual(w.cursorState, .invalid)
        XCTAssertEqual(w.startIndex, 0)
    }

    func testEmptyInventoryIsNotAnError() {
        let w = ConduitSessionListPage.window(total: 0)
        XCTAssertEqual(w.count, 0)
        XCTAssertFalse(w.hasMore)
    }

    func testLimitsClamp() {
        XCTAssertEqual(ConduitSessionListPage.clampLimit(nil), 40)
        XCTAssertEqual(ConduitSessionListPage.clampLimit(0), 40)
        XCTAssertEqual(ConduitSessionListPage.clampLimit(-5), 40)
        XCTAssertEqual(ConduitSessionListPage.clampLimit(5), 5)
        XCTAssertEqual(ConduitSessionListPage.clampLimit(9_999), 200)
    }
}

final class MindGraphOutputTests: XCTestCase {
    private let noisy = """
    08:29:04 INFO    mindgraph | Loading embedding model (all-MiniLM-L6-v2)...
    08:29:06 INFO    mindgraph | Ready
    [
      {"doc_id": "abc", "score": 0.4}
    ]
    """

    func testResultsAreSeparatedFromTheProgressLog() {
        XCTAssertEqual(MindGraphOutput.jsonPayload(in: noisy)?.hasPrefix("["), true)
    }

    func testProgressLogIsKeptButNotGluedToResults() {
        let preamble = MindGraphOutput.logPreamble(in: noisy)
        XCTAssertTrue(preamble.contains("Loading embedding model"))
        XCTAssertFalse(preamble.contains("["))
    }

    func testBracketInsideALogMessageIsNotMistakenForThePayload() {
        let tricky = """
        08:29:04 INFO mindgraph | scanning [30_projects] now
        [{"doc_id": "x"}]
        """
        XCTAssertEqual(MindGraphOutput.jsonPayload(in: tricky)?.hasPrefix("[{"), true)
    }

    func testOutputWithNoPayloadReportsNone() {
        XCTAssertNil(MindGraphOutput.jsonPayload(in: "08:29:04 INFO mindgraph | no results"))
    }

    func testProjectionDropsHostPathsAndMechanics() {
        let row: [String: Any] = [
            "path": "30_projects/conduit/log.md",
            "title": "Conduit log",
            "chunk_text": String(repeating: "x", count: 900),
            "rrf_score": 0.031754,
            "weak_fit": false,
            "trust_profile": "project_status",
            "provenance_warning": NSNull(),
            "source_root": "/Users/someone/Desktop/MainFrame",
            "content_hash": "40e9aa82",
            "semantic_distance": 0.98747,
        ]
        let projected = MindGraphOutput.projectResult(row)
        XCTAssertNil(projected["source_root"], "absolute host path must not reach a caller")
        XCTAssertNil(projected["content_hash"])
        XCTAssertNil(projected["semantic_distance"])
        XCTAssertNil(projected["provenance_warning"], "nulls are omitted, not forwarded")
        XCTAssertNotNil(projected["path"])
        XCTAssertNotNil(projected["title"])
        XCTAssertNotNil(projected["rrf_score"])
        XCTAssertNotNil(projected["weak_fit"])
        XCTAssertNotNil(projected["trust_profile"])
        XCTAssertEqual((projected["chunk_text"] as? String)?.count, 600)
        XCTAssertEqual(projected["chunk_text_truncated"] as? Bool, true)
    }

    func testProjectionIsAnAllowlist() {
        XCTAssertTrue(
            MindGraphOutput.projectResult(["some_future_absolute_path": "/Users/someone/x"]).isEmpty
        )
    }

    func testShortTextIsNotMarkedTruncated() {
        XCTAssertNil(MindGraphOutput.projectResult(["chunk_text": "short"])["chunk_text_truncated"])
    }

    func testBarePayloadWithNoLogStillParses() {
        XCTAssertEqual(
            MindGraphOutput.jsonPayload(in: "[{\"doc_id\":\"x\"}]")?.hasPrefix("["),
            true
        )
    }
}
