import Foundation
import XCTest
@testable import ConduitCore

final class MindGraphOperationsTests: XCTestCase {
    func testOperationsScopeAndCatalog() throws {
        let catalog = try XCTUnwrap(ConduitSessionToolCatalog.tool(named: "conduit_query_mindgraph"))
        let schema = try XCTUnwrap(catalog["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let scope = try XCTUnwrap(properties["scope"] as? [String: Any])
        XCTAssertEqual(scope["enum"] as? [String], ["knowledge", "projects", "operations"])
        XCTAssertTrue(ConduitSessionAPI.allowsMindGraphScope("operations"))
        XCTAssertFalse(ConduitSessionAPI.allowsMindGraphScope("both"))
        XCTAssertFalse(ConduitSessionAPI.allowsMindGraphScope("20_live"))
        XCTAssertEqual(MindGraphScope.operations.trustProfile, "operations_status")
        XCTAssertEqual(MindGraphScope.operations.defaultDatabaseFileName, "mainframe-operations.sqlite")
        XCTAssertEqual(Set(MindGraphScope.allCases.map(\.rawValue)), ["knowledge", "projects", "operations"])
    }

    func testMissingOperationsDatabaseNeverRunsOrSubstitutes() {
        let payload = MindGraphQuerySupport.sessionQuery(
            question: "standing loop", scope: .operations,
            binary: URL(fileURLWithPath: "/unused"),
            database: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            run: { _, _, _ in XCTFail("a missing DB must not launch or fall back"); return (0, "[]") }
        )
        XCTAssertEqual(payload["scope"] as? String, "operations")
        XCTAssertTrue((payload["error"] as? String)?.contains("index missing") == true)
        XCTAssertNil(payload["results"])
    }

    func testWrongStoredIndexIsRejectedBeforeTextProjection() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let rows = """
        [{"index_id":"mainframe-projects","trust_profile":"operations_status","path":"40_operations/example/README.md","chunk_text":"must not escape"}]
        """
        let payload = MindGraphQuerySupport.sessionQuery(
            question: "loop", scope: .operations, binary: file, database: file,
            run: { _, args, _ in
                XCTAssertTrue(args.contains(file.path))
                return (0, rows)
            }
        )
        XCTAssertNotNil(payload["error"])
        XCTAssertNil(payload["results"])
        XCTAssertFalse(String(describing: payload).contains("must not escape"))
        XCTAssertThrowsError(try MindGraphQuerySupport.decodeHits(from: Data(rows.utf8), scope: .operations)) {
            XCTAssertEqual($0 as? MindGraphQueryError, .indexIdentityMismatch)
        }
    }

    func testWarningsAndLogicalIdentitySurviveProjection() throws {
        let row: [String: Any] = [
            "doc_id": "ops", "index_id": "mainframe-operations", "namespace": "example",
            "source_path": "README.md", "display_path": "40_operations/example/README.md", "trust_profile": "operations_status",
            "content_hash": "abc", "citation_class": "unverified", "weak_fit": true,
            "provenance_warning": "UNKNOWN", "query_scope_warning": ["wrong_scope": true],
            "source_root": "/private/source"
        ]
        let projected = MindGraphOutput.projectResult(row)
        for key in ["doc_id", "index_id", "namespace", "source_path", "display_path", "content_hash", "weak_fit", "provenance_warning", "query_scope_warning"] {
            XCTAssertNotNil(projected[key], key)
        }
        XCTAssertNil(projected["source_root"])
        let data = try JSONSerialization.data(withJSONObject: [row])
        let hit = try XCTUnwrap(MindGraphQuerySupport.decodeHits(from: data, scope: .operations).first)
        XCTAssertEqual(hit.indexID, "mainframe-operations")
        XCTAssertEqual(hit.warnings.count, 3)
        XCTAssertTrue(hit.warnings.contains("UNKNOWN"))
    }

    // Explicitly configured integration run: invoke the actual producer CLI and
    // the same consumer function that the Session API uses. No fixture CLI.
    func testRealProducerConsumerBoundary() throws {
        let env = ProcessInfo.processInfo.environment
        guard let binaryPath = env["CONDUIT_MINDGRAPH_QUALIFICATION_BINARY"],
              let homePath = env["CONDUIT_MINDGRAPH_QUALIFICATION_HOME"],
              let receiptPath = env["CONDUIT_MINDGRAPH_QUALIFICATION_RECEIPT"],
              let operationsQuestion = env["CONDUIT_MINDGRAPH_QUALIFICATION_OPERATIONS_QUESTION"],
              let operationsPath = env["CONDUIT_MINDGRAPH_QUALIFICATION_OPERATIONS_PATH"] else {
            throw XCTSkip("real producer qualification needs an explicit binary, DB home, receipt and operations fixture")
        }
        let binary = URL(fileURLWithPath: binaryPath)
        let home = URL(fileURLWithPath: homePath)
        let run: (String, [String], TimeInterval) -> (status: Int32, output: String) = { executable, arguments, _ in
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = output
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return (process.terminationStatus, String(decoding: data, as: UTF8.self))
            } catch {
                return (127, error.localizedDescription)
            }
        }
        var receipts: [[String: Any]] = []
        for scope in MindGraphScope.allCases {
            let payload = MindGraphQuerySupport.sessionQuery(
                question: scope == .operations ? operationsQuestion : "MindGraph", scope: scope,
                binary: binary, database: MindGraphQuerySupport.databaseURL(for: scope, home: home), run: run
            )
            XCTAssertNil(payload["error"], String(describing: payload))
            XCTAssertEqual(payload["exit_code"] as? Int32, 0)
            let rows = try XCTUnwrap(payload["results"] as? [[String: Any]])
            XCTAssertFalse(rows.isEmpty)
            if scope == .operations {
                XCTAssertTrue(rows.allSatisfy { $0["index_id"] as? String == "mainframe-operations" })
                XCTAssertTrue(rows.contains { $0["path"] as? String == operationsPath })
            }
            if scope == .projects {
                XCTAssertFalse(rows.contains { ($0["path"] as? String)?.hasPrefix("40_operations/") == true })
            }
            receipts.append(payload)
        }
        let wrong = MindGraphQuerySupport.sessionQuery(
            question: "MindGraph", scope: .operations, binary: binary,
            database: MindGraphQuerySupport.databaseURL(for: .projects, home: home), run: run
        )
        XCTAssertNotNil(wrong["error"])
        XCTAssertNil(wrong["results"])
        receipts.append(wrong)
        let missing = MindGraphQuerySupport.sessionQuery(
            question: "MindGraph", scope: .operations, binary: binary,
            database: home.appendingPathComponent("absent-operations.sqlite"), run: run
        )
        XCTAssertNotNil(missing["error"])
        receipts.append(missing)
        let data = try JSONSerialization.data(withJSONObject: receipts, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: receiptPath), options: .withoutOverwriting)
    }
}
