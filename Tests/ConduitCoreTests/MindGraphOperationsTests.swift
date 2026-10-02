import Foundation
import XCTest
@testable import ConduitCore

final class MindGraphOperationsTests: XCTestCase {
    private func envelope(_ rows: [[String: Any]], changes: [String: Any] = [:]) throws -> Data {
        var identity: [String: Any] = [
            "schema_version": "mindgraph-index-identity/v1", "index_id": "mainframe-operations",
            "trust_profile": "operations_status", "retrieval_scope": "operations",
            "lifecycle_root": "40_operations", "producer": "mainframe-live", "document_count": 1,
            "manifest_sha256": String(repeating: "a", count: 64),
            "source_document_map_sha256": String(repeating: "b", count: 64),
            "database_document_map_sha256": String(repeating: "c", count: 64),
        ]
        identity.merge(changes) { _, new in new }
        return try JSONSerialization.data(withJSONObject: [
            "schema_version": "mindgraph-query-identity/v1", "database_identity": identity, "results": rows,
        ], options: [.sortedKeys])
    }

    func testOperationsAuthorityWithHitsAndNoHits() throws {
        let row: [String: Any] = ["index_id": "mainframe-operations", "trust_profile": "operations_status",
                                  "path": "40_operations/example/README.md", "chunk_text": "nomination"]
        for rows in [[row], []] {
            XCTAssertEqual(try MindGraphQuerySupport.decodeHits(from: envelope(rows), scope: .operations).count, rows.count)
        }
    }

    func testProjectsAndWrongMetadataFailEvenWithNoHits() throws {
        let row: [String: Any] = ["index_id": "mainframe-operations", "trust_profile": "operations_status",
                                  "path": "40_operations/example/README.md", "chunk_text": "must not escape"]
        let cases: [[String: Any]] = [
            ["index_id": "mainframe-projects"], ["trust_profile": "project_status"],
            ["retrieval_scope": "projects"], ["lifecycle_root": "30_projects"],
            ["producer": "unknown"], ["schema_version": "unknown"],
            ["database_document_map_sha256": ""], ["manifest_sha256": NSNull()],
            ["document_count": true], ["document_count": -1],
        ]
        for changes in cases {
            for rows in [[row], []] {
                XCTAssertThrowsError(try MindGraphQuerySupport.decodeHits(from: envelope(rows, changes: changes), scope: .operations))
            }
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let data = try envelope([row], changes: ["index_id": "mainframe-projects"])
        let payload = MindGraphQuerySupport.sessionQuery(question: "compass", scope: .operations, binary: file, database: file,
                                                        run: { _, args, _ in
            XCTAssertTrue(args.contains("--identity-envelope"))
            return (0, String(decoding: data, as: UTF8.self))
        })
        XCTAssertNotNil(payload["error"])
        XCTAssertNil(payload["results"])
        XCTAssertNil(payload["database_identity"])
        XCTAssertFalse(String(describing: payload).contains("must not escape"))
    }

    func testUnidentifiedEmptyArrayIsRejectedForOperations() throws {
        let data = Data("[]".utf8)
        XCTAssertThrowsError(try MindGraphQuerySupport.decodeHits(from: data, scope: .operations))
        XCTAssertTrue(try MindGraphQuerySupport.decodeHits(from: data, scope: .projects).isEmpty)
        XCTAssertTrue(try MindGraphQuerySupport.decodeHits(from: data, scope: .knowledge).isEmpty)
    }

    func testDatabaseIdentityDoesNotRedeemWrongReturnedRows() throws {
        for changes in [["index_id": "mainframe-projects"], ["trust_profile": "project_status"], ["path": "30_projects/example/README.md"]] {
            var row = ["index_id": "mainframe-operations", "trust_profile": "operations_status", "path": "40_operations/example/README.md"]
            row.merge(changes) { _, new in new }
            XCTAssertThrowsError(try MindGraphQuerySupport.decodeHits(from: envelope([row]), scope: .operations))
        }
    }
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
        let data = try envelope([row])
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
                let identity = try XCTUnwrap(payload["database_identity"] as? [String: Any])
                XCTAssertEqual(identity["index_id"] as? String, "mainframe-operations")
                XCTAssertEqual(identity["producer"] as? String, "mainframe-live")
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
        // A lexical no-hit profile is explicit: default semantic retrieval can
        // nominate nearest neighbors for arbitrary strings.
        let lexical: (String, [String], TimeInterval) -> (status: Int32, output: String) = { executable, args, timeout in
            run(executable, args + ["--lexical-only"], timeout)
        }
        let noHit = MindGraphQuerySupport.sessionQuery(question: "zzqualificationnomatch01a0f26e", scope: .operations,
            binary: binary, database: MindGraphQuerySupport.databaseURL(for: .operations, home: home), run: lexical)
        XCTAssertNil(noHit["error"], String(describing: noHit))
        XCTAssertEqual((noHit["results"] as? [[String: Any]])?.count, 0)
        XCTAssertNotNil(noHit["database_identity"])
        receipts.append(noHit)
        let wrongNoHit = MindGraphQuerySupport.sessionQuery(question: "zzqualificationnomatch01a0f26e", scope: .operations,
            binary: binary, database: MindGraphQuerySupport.databaseURL(for: .projects, home: home), run: lexical)
        XCTAssertNotNil(wrongNoHit["error"])
        XCTAssertNil(wrongNoHit["results"])
        receipts.append(wrongNoHit)
        let empty = home.appendingPathComponent("unidentified-empty-\(UUID().uuidString).sqlite")
        XCTAssertEqual(run(binary.path, ["init", "--db", empty.path], 45).status, 0)
        defer { try? FileManager.default.removeItem(at: empty) }
        let unidentified = MindGraphQuerySupport.sessionQuery(question: "MindGraph", scope: .operations,
            binary: binary, database: empty, run: run)
        XCTAssertNotNil(unidentified["error"])
        XCTAssertNil(unidentified["results"])
        receipts.append(unidentified)
        let missing = MindGraphQuerySupport.sessionQuery(
            question: "MindGraph", scope: .operations, binary: binary,
            database: home.appendingPathComponent("absent-operations.sqlite"), run: run
        )
        XCTAssertNotNil(missing["error"])
        receipts.append(missing)
        let data = try JSONSerialization.data(withJSONObject: receipts, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: receiptPath), options: .withoutOverwriting)
    }

    func testRealWrongSourceMapRejectedBeforeNominationAdmission() throws {
        let env = ProcessInfo.processInfo.environment
        guard let binary = env["CONDUIT_MINDGRAPH_QUALIFICATION_BINARY"],
              let database = env["CONDUIT_MINDGRAPH_QUALIFICATION_WRONG_SOURCE_MAP_DB"],
              let receiptPath = env["CONDUIT_MINDGRAPH_QUALIFICATION_WRONG_SOURCE_MAP_RECEIPT"] else {
            throw XCTSkip("real source-map rejection requires an explicit engine, mutated owned DB and receipt")
        }
        var receipts: [[String: Any]] = []
        for budget in [8, 0] {
            let payload = MindGraphQuerySupport.sessionQuery(
                question: "zzwrongsourceidentitynomatch", scope: .operations,
                binary: URL(fileURLWithPath: binary), database: URL(fileURLWithPath: database),
                run: { executable, arguments, _ in
                    let process = Process()
                    let output = Pipe()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments + ["--lexical-only", "--top-k", String(budget)]
                    process.standardOutput = output
                    process.standardError = output
                    do {
                        try process.run()
                        let data = output.fileHandleForReading.readDataToEndOfFile()
                        process.waitUntilExit()
                        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
                    } catch { return (127, error.localizedDescription) }
                }
            )
            XCTAssertNotNil(payload["error"])
            XCTAssertNil(payload["results"])
            XCTAssertNil(payload["database_identity"])
            XCTAssertTrue((payload["diagnostic"] as? String)?.contains("source document map differs") == true,
                          String(describing: payload))
            receipts.append(payload)
        }
        let data = try JSONSerialization.data(withJSONObject: receipts, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: receiptPath), options: .withoutOverwriting)
    }
}
