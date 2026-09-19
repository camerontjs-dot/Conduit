import XCTest
@testable import ConduitCore

final class ConduitSessionToolCatalogTests: XCTestCase {
    func testPublishedCatalogIncludesEveryLifecycleToolExactlyOnce() {
        let names = ConduitSessionToolCatalog.tools()
            .compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ConduitSessionToolCatalog.readToolNames + ConduitSessionToolCatalog.writeToolNames)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(names.count, 11)
        XCTAssertEqual(ConduitSessionToolCatalog.writeToolNames.count, 5)
    }

    func testEveryPublishedDescriptionCarriesCatalogIdentity() throws {
        let marker = "[Conduit MCP catalog \(ConduitSessionToolCatalog.catalogIdentity)]"
        for tool in ConduitSessionToolCatalog.tools() {
            let name = try XCTUnwrap(tool["name"] as? String)
            let description = try XCTUnwrap(tool["description"] as? String)
            XCTAssertTrue(
                description.hasSuffix(marker),
                "\(name) is missing the hosted-catalog identity marker"
            )
        }
    }

    func testRuntimeContractMetadataMakesCreateRetrySemanticsExplicit() throws {
        let metadata = ConduitSessionToolCatalog.runtimeContractMetadata
        XCTAssertEqual(
            metadata["catalog_identity"] as? String,
            ConduitSessionToolCatalog.catalogIdentity
        )
        XCTAssertEqual(
            metadata["server_version"] as? String,
            ConduitSessionToolCatalog.serverVersion
        )
        XCTAssertEqual(
            metadata["create_task_objective_delivery"] as? String,
            "delivered=no-resend;queued=no-resend;failed=resend-required"
        )
    }

    func testRequiredArgumentsAndDescriptionsRemainActionable() throws {
        let create = try XCTUnwrap(ConduitSessionToolCatalog.tool(named: "conduit_create_task"))
        let createSchema = try XCTUnwrap(create["inputSchema"] as? [String: Any])
        XCTAssertEqual(createSchema["required"] as? [String], ["agent", "project_slug"])
        let createDescription = try XCTUnwrap(create["description"] as? String)
        XCTAssertTrue(createDescription.contains("no model override"))
        XCTAssertTrue(createDescription.contains("always advertised"))
        XCTAssertTrue(createDescription.contains("enables Session API writes locally"))
        XCTAssertTrue(createDescription.contains("queued means Conduit owns delivery"))
        XCTAssertTrue(createDescription.contains("resending would run the objective twice"))

        let properties = try XCTUnwrap(createSchema["properties"] as? [String: Any])
        let objective = try XCTUnwrap(properties["objective"] as? [String: Any])
        let objectiveDescription = try XCTUnwrap(objective["description"] as? String)
        XCTAssertTrue(objectiveDescription.contains("Do not resend a queued objective"))

        let interrupt = try XCTUnwrap(ConduitSessionToolCatalog.tool(named: "conduit_interrupt"))
        let description = try XCTUnwrap(interrupt["description"] as? String)
        XCTAssertTrue(description.contains("interrupt_request"))
        XCTAssertTrue(description.contains("not observed cancellation"))
        XCTAssertTrue(description.contains("truncated remains"))
    }

    func testEventsSchemaSeparatesInterruptKindFromTextTruncation() throws {
        let events = try XCTUnwrap(ConduitSessionToolCatalog.tool(named: "conduit_session_events"))
        let schema = try XCTUnwrap(events["outputSchema"] as? [String: Any])
        let required = try XCTUnwrap(schema["required"] as? [String])
        XCTAssertTrue(required.contains("events"))
        XCTAssertTrue(required.contains("truncated"))
        let observation = try XCTUnwrap(
            (schema["properties"] as? [String: Any])?["observation"] as? [String: Any]
        )
        XCTAssertTrue((observation["required"] as? [String])?.contains("checkpoint") == true)
        let eventsSchema = try XCTUnwrap(
            (schema["properties"] as? [String: Any])?["events"] as? [String: Any]
        )
        let eventProperties = try XCTUnwrap(
            ((eventsSchema["items"] as? [String: Any])?["properties"] as? [String: Any])
        )
        XCTAssertNotNil(eventProperties["artifact_refs"])
        XCTAssertTrue((events["description"] as? String)?.contains("interrupt_request") == true)
    }
}
