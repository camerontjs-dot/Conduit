import XCTest
@testable import ConduitCore

final class ConduitSessionToolCatalogTests: XCTestCase {
    func testEveryToolCarriesExactlyOneCurrentCatalogueMarker() {
        let marker = "[Conduit MCP catalog \(ConduitSessionToolCatalog.catalogIdentity)]"
        for tool in ConduitSessionToolCatalog.tools() {
            let description = tool["description"] as? String ?? ""
            XCTAssertTrue(description.hasSuffix(marker))
            XCTAssertEqual(description.components(separatedBy: "[Conduit MCP catalog ").count, 2)
        }
    }

    func testRuntimeMetadataUsesTheSameCatalogueAndPreservesHandlerEvidence() {
        let metadata = ConduitSessionToolCatalog.runtimeContractMetadata
        XCTAssertEqual(metadata["catalog_identity"] as? String, ConduitSessionToolCatalog.catalogIdentity)
        XCTAssertEqual(metadata["server_version"] as? String, ConduitSessionToolCatalog.serverVersion)
        XCTAssertEqual(metadata["tool_names"] as? [String],
                       ConduitSessionToolCatalog.readToolNames + ConduitSessionToolCatalog.writeToolNames)
        XCTAssertEqual(metadata["write_tool_names"] as? [String], ConduitSessionToolCatalog.writeToolNames)
        XCTAssertEqual(metadata["create_task_objective_delivery"] as? String,
                       "delivered=no-resend;queued=no-resend;failed=resend-required")
        let payload = ConduitSessionToolCatalog.annotatingRuntimeResult([
            "error": "fixture_refusal", "objective_delivery": "queued", "accepted": false,
            "mcp_contract": ["catalog_identity": "stale"],
        ])
        XCTAssertEqual(payload["error"] as? String, "fixture_refusal")
        XCTAssertEqual(payload["objective_delivery"] as? String, "queued")
        XCTAssertEqual(payload["accepted"] as? Bool, false)
        XCTAssertEqual((payload["mcp_contract"] as? [String: Any])?["catalog_identity"] as? String,
                       ConduitSessionToolCatalog.catalogIdentity)
    }

    func testPublishedCatalogIncludesEveryLifecycleToolExactlyOnce() {
        let names = ConduitSessionToolCatalog.tools()
            .compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ConduitSessionToolCatalog.readToolNames + ConduitSessionToolCatalog.writeToolNames)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(names.count, 18)
        XCTAssertEqual(ConduitSessionToolCatalog.writeToolNames.count, 7)
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

        let fleet = try XCTUnwrap(
            ConduitSessionToolCatalog.tool(named: "conduit_fleet_snapshot")
        )
        let fleetAnnotations = try XCTUnwrap(
            fleet["annotations"] as? [String: Any]
        )
        XCTAssertEqual(fleetAnnotations["readOnlyHint"] as? Bool, true)
        let fleetProperties = try XCTUnwrap(
            (fleet["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
        )
        XCTAssertNotNil(fleetProperties["task_cursor"])
        XCTAssertNotNil(fleetProperties["provider_cursor"])
        XCTAssertTrue((fleet["description"] as? String)?.contains("UNKNOWN") == true)
        XCTAssertTrue((fleet["description"] as? String)?.contains("reserves no execution slot") == true)

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

        let preflight = try XCTUnwrap(
            ConduitSessionToolCatalog.tool(named: "conduit_lifecycle_preflight")
        )
        let preflightSchema = try XCTUnwrap(
            preflight["inputSchema"] as? [String: Any]
        )
        XCTAssertEqual(
            preflightSchema["required"] as? [String],
            ["taskSessionID", "operation"]
        )
        XCTAssertTrue(
            (preflight["description"] as? String)?.contains(
                "unsupported, or unknown"
            ) == true
        )

        let processTree = try XCTUnwrap(
            ConduitSessionToolCatalog.tool(named: "conduit_process_tree")
        )
        let processTreeSchema = try XCTUnwrap(
            processTree["inputSchema"] as? [String: Any]
        )
        XCTAssertEqual(
            processTreeSchema["required"] as? [String],
            ["taskSessionID"]
        )
        XCTAssertTrue(
            (processTree["description"] as? String)?.contains(
                "Parent exit alone never becomes complete"
            ) == true
        )

        let lifecycle = try XCTUnwrap(
            ConduitSessionToolCatalog.tool(named: "conduit_lifecycle_operation")
        )
        XCTAssertTrue(
            (lifecycle["description"] as? String)?.contains("fail closed") == true
        )

        let interrupt = try XCTUnwrap(
            ConduitSessionToolCatalog.tool(named: "conduit_interrupt")
        )
        let description = try XCTUnwrap(interrupt["description"] as? String)
        XCTAssertTrue(description.contains("interrupt_request"))
        XCTAssertTrue(description.contains("not observed cancellation"))
        XCTAssertTrue(description.contains("raw Ctrl-C"))
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
