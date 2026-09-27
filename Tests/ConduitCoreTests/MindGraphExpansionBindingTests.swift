import Foundation
import XCTest
@testable import ConduitCore

final class MindGraphExpansionBindingTests: XCTestCase {
    // Fixed canonical exp2 vector emitted by the Python producer implementation.
    private let handle = "exp2:eyJjaHVua19pbmRleCI6MCwiY29udGVudF9oYXNoIjoic2FtZS1oYXNoIiwiZG9jX2lkIjoic2FtZS1kb2MiLCJpbmRleF9pZCI6ImluZGV4LWEiLCJuYW1lc3BhY2UiOiJub3RlcyIsInBhdGgiOiJhLm1kIiwic2NvcGUiOiJrbm93bGVkZ2UiLCJ2IjoiZXhwMiJ9"

    private func response() -> [String: Any] {
        ["expansion_handle": handle, "index_id": "index-a", "scope_index": "knowledge",
         "namespace": "notes", "path": "a.md", "doc_id": "same-doc", "chunk_index": 0,
         "content_hash": "same-hash", "content_hash_match": true,
         "chunk_text": "Exact source body.", "title": "A", "display_path": "a.md",
         "freshness": "UNKNOWN", "citation_class": "unverified", "trust_profile": "same-trust"]
    }
    private func data(_ row: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: row) }

    func testProducerVectorDecodesAndExpands() throws {
        let locator = try MindGraphExpansionBinding.validateRequest(handle, scope: "knowledge")
        XCTAssertEqual(locator.indexID, "index-a")
        XCTAssertEqual(locator.docID, "same-doc")
        try MindGraphExpansionBinding.validateResponse(data(response()), upstreamHandle: handle)
    }
    func testWrongRequestedScopeIsRejectedBeforeProducer() {
        XCTAssertThrowsError(try MindGraphExpansionBinding.validateRequest(handle, scope: "projects"))
    }
    func testCollidingIndexWithSameTrustDocChunkAndHashIsRejected() throws {
        var row = response()
        row["index_id"] = "index-b"
        XCTAssertThrowsError(try MindGraphExpansionBinding.validateResponse(data(row), upstreamHandle: handle))
    }
    func testIndependentResponseIdentityChecks() throws {
        for (key, bad): (String, Any) in [
            ("expansion_handle", "exp2:another"), ("doc_id", "other"),
            ("chunk_index", 1), ("path", "other.md"), ("namespace", "other"),
            ("scope_index", "projects"), ("content_hash", "wrong-hash"),
            ("content_hash_match", false), ("freshness", "CURRENT"), ("citation_class", "verified")
        ] {
            var row = response(); row[key] = bad
            XCTAssertThrowsError(try MindGraphExpansionBinding.validateResponse(data(row), upstreamHandle: handle), key)
        }
    }
    func testMissingBindingCannotBecomeUnknownSuccess() throws {
        for key in ["index_id", "path", "namespace", "scope_index", "content_hash", "content_hash_match"] {
            var row = response(); row.removeValue(forKey: key)
            XCTAssertThrowsError(try MindGraphExpansionBinding.validateResponse(data(row), upstreamHandle: handle), key)
        }
    }
    func testMalformedOrLegacyHandlesAreRejected() {
        for bad in ["exp1:abc", "exp2:!!!", "exp2:" + String(repeating: "a", count: 9000), ""] {
            XCTAssertThrowsError(try MindGraphExpansionBinding.locator(bad))
        }
    }
    func testBooleanChunkCannotMasqueradeAsInteger() throws {
        var row = response(); row["chunk_index"] = false
        XCTAssertThrowsError(try MindGraphExpansionBinding.validateResponse(data(row), upstreamHandle: handle))
    }
    func testOutputIsAllowlisted() throws {
        var row = response(); row["source_root"] = "host-only"; row["raw_output"] = "not forwarded"
        let out = try MindGraphExpansionBinding.agentResponse(data(row), expansionHandle: handle, scope: "knowledge")
        XCTAssertEqual(out["chunk_text"] as? String, "Exact source body.")
        XCTAssertEqual(out["expansion_handle"] as? String, handle)
        XCTAssertNil(out["source_root"]); XCTAssertNil(out["raw_output"])
    }
    func testDuplicateLocatorKeysFailCanonicalCheck() {
        let raw = #"{"chunk_index":0,"content_hash":"same-hash","doc_id":"same-doc","index_id":"index-a","namespace":"notes","path":"a.md","scope":"knowledge","scope":"knowledge","v":"exp2"}"#
        let h = "exp2:" + Data(raw.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        XCTAssertThrowsError(try MindGraphExpansionBinding.locator(h))
    }
    func testUnicodeProducerVector() throws {
        let unicode = "exp2:eyJjaHVua19pbmRleCI6MCwiY29udGVudF9oYXNoIjoic2FtZS1oYXNoIiwiZG9jX2lkIjoic2FtZS1kb2MiLCJpbmRleF9pZCI6ImluZGV4LWEiLCJuYW1lc3BhY2UiOiJub3RlcyIsInBhdGgiOiJjYWbDqS_noJTnqbYubWQiLCJzY29wZSI6Imtub3dsZWRnZSIsInYiOiJleHAyIn0="
        let locator = try MindGraphExpansionBinding.validateRequest(unicode, scope: "knowledge")
        XCTAssertEqual(locator.path, "café/研究.md")
    }
}
