import XCTest
@testable import ConduitCore

final class MindGraphNominationTests: XCTestCase {
    func testCompactEnvelopeDecodesMinimumSufficientNomination() throws {
        let json = """
        log preamble
        {
          "nominations": [
            {
              "nomination_id": "nom1:abc",
              "expansion_handle": "exp1:def",
              "title": "Authority routing",
              "preview": "Compact exact preview.",
              "preview_truncated": false,
              "display_path": "10_knowledge/authority.md",
              "doc_id": "doc-1",
              "chunk_index": 2,
              "content_hash": "sha256:source",
              "citation_class": "citable",
              "trust_profile": "durable_knowledge",
              "freshness": "UNKNOWN",
              "raw_status": "current",
              "retrieval_reasons": ["lexical_match", "semantic_match", "fused_rank"],
              "signal": "fused",
              "rrf_score": 0.42,
              "weak_fit": false
            }
          ]
        }
        """

        let rows = try MindGraphQuerySupport.decodeNominations(
            from: Data(json.utf8),
            scope: .knowledge
        )
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(row.nominationID, "nom1:abc")
        XCTAssertEqual(row.expansionHandle, "exp1:def")
        XCTAssertEqual(row.preview, "Compact exact preview.")
        XCTAssertEqual(row.displayPath, "10_knowledge/authority.md")
        XCTAssertEqual(row.retrievalReasons, [
            "lexical_match", "semantic_match", "fused_rank",
        ])
        XCTAssertEqual(row.scope, .knowledge)
    }

    func testCompactEnvelopeRejectsLegacyResultArrays() {
        let json = """
        {
          "results": [{"chunk_text": "must not cross compact boundary"}],
          "nominations": []
        }
        """

        XCTAssertThrowsError(
            try MindGraphQuerySupport.decodeNominations(
                from: Data(json.utf8),
                scope: .knowledge
            )
        )
    }

    func testCompactEnvelopeRejectsChunkTextInsideNomination() {
        let json = """
        {
          "nominations": [
            {
              "nomination_id": "nom1:abc",
              "expansion_handle": "exp1:def",
              "doc_id": "doc-1",
              "chunk_index": 0,
              "chunk_text": "full source must not be smuggled into compact mode"
            }
          ]
        }
        """

        XCTAssertThrowsError(
            try MindGraphQuerySupport.decodeNominations(
                from: Data(json.utf8),
                scope: .projects
            )
        )
    }

    func testExpansionMustMatchOriginalNominationIdentity() throws {
        let nomination = fixtureNomination()
        let json = """
        {
          "expansion_handle": "exp1:def",
          "doc_id": "doc-1",
          "chunk_index": 2,
          "display_path": "10_knowledge/authority.md",
          "title": "Authority routing",
          "chunk_text": "Full source-backed chunk.",
          "content_hash": "sha256:source",
          "content_hash_match": true,
          "freshness": "UNKNOWN",
          "citation_class": "citable"
        }
        """

        let expansion = try MindGraphQuerySupport.decodeExpansion(
            from: Data(json.utf8)
        )
        XCTAssertTrue(
            MindGraphQuerySupport.expansionMatchesNomination(
                expansion,
                nomination: nomination
            )
        )

        let wrongNomination = MindGraphNomination(
            nominationID: nomination.nominationID,
            expansionHandle: nomination.expansionHandle,
            title: nomination.title,
            preview: nomination.preview,
            previewTruncated: nomination.previewTruncated,
            displayPath: nomination.displayPath,
            docID: nomination.docID,
            chunkIndex: 3,
            contentHash: nomination.contentHash,
            citationClass: nomination.citationClass,
            trustProfile: nomination.trustProfile,
            freshness: nomination.freshness,
            rawStatus: nomination.rawStatus,
            retrievalReasons: nomination.retrievalReasons,
            signal: nomination.signal,
            rrfScore: nomination.rrfScore,
            weakFit: nomination.weakFit,
            scope: nomination.scope
        )
        XCTAssertFalse(
            MindGraphQuerySupport.expansionMatchesNomination(
                expansion,
                nomination: wrongNomination
            )
        )
    }

    func testAgentProjectionOmitsFullTextAndLowLevelScores() {
        let projected = MindGraphOutput.projectNomination(fixtureNomination())

        XCTAssertEqual(projected["nomination_id"] as? String, "nom1:abc")
        XCTAssertEqual(projected["preview"] as? String, "Compact exact preview.")
        XCTAssertEqual(projected["content_hash"] as? String, "sha256:source")
        XCTAssertNil(projected["chunk_text"])
        XCTAssertNil(projected["rrf_score"])
        XCTAssertNil(projected["semantic_distance"])
        XCTAssertNil(projected["lexical_rank"])
        XCTAssertNil(projected["semantic_rank"])
    }

    func testInspectionProjectionDoesNotBecomeContextAdmission() {
        let nomination = fixtureNomination()
        let expansion = MindGraphExpansion(
            expansionHandle: nomination.expansionHandle,
            docID: nomination.docID,
            chunkIndex: nomination.chunkIndex,
            displayPath: nomination.displayPath,
            title: nomination.title,
            chunkText: "Full source-backed chunk.",
            contentHash: nomination.contentHash,
            contentHashMatch: true,
            freshness: "UNKNOWN",
            rawStatus: nil,
            citationClass: "citable",
            trustProfile: nomination.trustProfile
        )
        let inspection = MindGraphInspectionItem(
            nomination: nomination,
            expansion: expansion
        )

        XCTAssertEqual(inspection.expansion?.chunkText, "Full source-backed chunk.")
        XCTAssertEqual(inspection.expandedHit?.chunkText, "Full source-backed chunk.")
        XCTAssertNil(inspection.expansionError)
    }

    private func fixtureNomination() -> MindGraphNomination {
        MindGraphNomination(
            nominationID: "nom1:abc",
            expansionHandle: "exp1:def",
            title: "Authority routing",
            preview: "Compact exact preview.",
            previewTruncated: false,
            displayPath: "10_knowledge/authority.md",
            docID: "doc-1",
            chunkIndex: 2,
            contentHash: "sha256:source",
            citationClass: "citable",
            trustProfile: "durable_knowledge",
            freshness: "UNKNOWN",
            rawStatus: "current",
            retrievalReasons: ["lexical_match", "semantic_match", "fused_rank"],
            signal: "fused",
            rrfScore: 0.42,
            weakFit: false,
            scope: .knowledge
        )
    }
}
