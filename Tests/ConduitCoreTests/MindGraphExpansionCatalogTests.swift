import XCTest
@testable import ConduitCore

final class MindGraphExpansionCatalogTests: XCTestCase {
    func testPublishedCatalogExposesExpansionExactlyOnceAsReadOnly() throws {
        let name = "conduit_expand_mindgraph_nomination"
        let rows = ConduitSessionToolCatalog.tools().filter { $0["name"] as? String == name }
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(ConduitSessionToolCatalog.readToolNames.contains(name))
        XCTAssertFalse(ConduitSessionToolCatalog.writeToolNames.contains(name))
        let row = try XCTUnwrap(rows.first)
        let schema = try XCTUnwrap(row["inputSchema"] as? [String: Any])
        XCTAssertEqual(Set(schema["required"] as? [String] ?? []), Set(["expansion_handle", "scope"]))
        let annotations = try XCTUnwrap(row["annotations"] as? [String: Any])
        XCTAssertEqual(annotations["readOnlyHint"] as? Bool, true)
        XCTAssertFalse(ConduitSessionAPI.isWrite(.expandMindGraphNomination(expansionHandle: "exp2:fixture", scope: "knowledge")))
    }
    func testPublishedQueryDescriptionMatchesCompactContract() throws {
        let row = try XCTUnwrap(ConduitSessionToolCatalog.tool(named: "conduit_query_mindgraph"))
        let description = try XCTUnwrap(row["description"] as? String)
        XCTAssertTrue(description.contains("compact nominations"))
        XCTAssertTrue(description.contains("conduit_expand_mindgraph_nomination"))
        XCTAssertFalse(description.contains("not_citable documents remain separate"))
    }
}
