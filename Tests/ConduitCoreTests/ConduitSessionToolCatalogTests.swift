import XCTest
@testable import ConduitCore

final class ConduitSessionToolCatalogTests: XCTestCase {
    func testPublishedCatalogIncludesEveryLifecycleToolExactlyOnce() {
        let names = ConduitSessionToolCatalog.tools()
            .compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ConduitSessionToolCatalog.readToolNames + ConduitSessionToolCatalog.writeToolNames)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(names.count, 14)
        XCTAssertEqual(ConduitSessionToolCatalog.writeToolNames.count, 6)
    }

    func testRequiredArgumentsAndDescriptionsRemainActionable() throws {
        let create = try XCTUnwrap(ConduitSessionToolCatalog.tool(named: "conduit_create_task"))
        let createSchema = try XCTUnwrap(create["inputSchema"] as? [String: Any])
        XCTAssertEqual(createSchema["required"] as? [String], ["agent", "project_slug"])
        XCTAssertTrue((create["description"] as? String)?.contains("no model override") == true)
        XCTAssertTrue((create["description"] as? String)?.contains("always advertised") == true)
        XCTAssertTrue((create["description"] as? String)?.contains("enables Session API writes locally") == true)

        let listProviders = try XCTUnwrap(
            ConduitSessionToolCatalog.tool(named: "conduit_list_provider_sessions")
        )
        let listSchema = try XCTUnwrap(
            listProviders["inputSchema"] as? [String: Any]
        )
        XCTAssertEqual(listSchema["required"] as? [String], ["provider"])
        XCTAssertTrue(
            (listProviders["description"] as? String)?.contains(
                "does not send input"
            ) == true
        )
        XCTAssertTrue(
            (listProviders["description"] as? String)?.contains(
                "consume a live execution slot"
            ) == true
        )

        let observe = try XCTUnwrap(
            ConduitSessionToolCatalog.tool(named: "conduit_observe_worker")
        )
        let observeSchema = try XCTUnwrap(
            observe["inputSchema"] as? [String: Any]
        )
        XCTAssertEqual(
            observeSchema["required"] as? [String],
            ["provider", "provider_session_id"]
        )
        XCTAssertTrue(
            (observe["description"] as? String)?.contains(
                "never adopts or controls"
            ) == true
        )

        let adopt = try XCTUnwrap(
            ConduitSessionToolCatalog.tool(named: "conduit_adopt_provider_session")
        )
        let adoptSchema = try XCTUnwrap(
            adopt["inputSchema"] as? [String: Any]
        )
        XCTAssertEqual(
            adoptSchema["required"] as? [String],
            ["provider", "provider_session_id", "controller_id"]
        )
        let adoptDescription = try XCTUnwrap(adopt["description"] as? String)
        XCTAssertTrue(adoptDescription.contains("writer_collision"))
        XCTAssertTrue(adoptDescription.contains("does not create"))
        XCTAssertTrue(adoptDescription.contains("workspace/worktree writer lease"))

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
