#if os(macOS)
import Foundation
import XCTest
import ConduitCore
@testable import Conduit

@MainActor
final class ConduitDirectFilesystemTransportTests: XCTestCase {
    private func request(
        _ server: ConduitSessionAPIServer,
        _ method: String,
        params: [String: Any] = [:],
        authorized: Bool = true,
        id: Any = 1
    ) throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params,
        ])
        let headers = "POST /mcp HTTP/1.1\r\n"
            + (authorized ? "Authorization: Bearer fixture-token\r\n" : "")
            + "Content-Length: \(body.count)\r\n\r\n"
        let response = server.response(for: Data(headers.utf8) + body)
        let text = try XCTUnwrap(String(data: response, encoding: .utf8))
        let range = try XCTUnwrap(text.range(of: "\r\n\r\n"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text[range.upperBound...].utf8)) as? [String: Any])
    }

    func testReadOnlyCatalogAndSearchUseExactProjectWithoutSessionDispatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("source.txt")
        try Data("needle\nneedle\n".utf8).write(to: file)
        let before = try Data(contentsOf: file)
        var resolvedProjects: [String] = []
        let server = ConduitSessionAPIServer(
            token: "fixture-token",
            allowWrites: false,
            projectFilesystemRoot: { slug in
                resolvedProjects.append(slug)
                return slug == "fixture" ? root : nil
            }
        ) { _, _ in
            XCTFail("Direct file search must not enter a task/runtime handler")
            return ["error": "unexpected session dispatch"]
        }
        let catalog = try request(server, "tools/list")
        let tools = try XCTUnwrap((catalog["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let tool = try XCTUnwrap(tools.first { $0["name"] as? String == ConduitFilesystemSearchTool.name })
        XCTAssertEqual((tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true)

        let response = try request(server, "tools/call", params: [
            "name": ConduitFilesystemSearchTool.name,
            "arguments": ["project_slug": "fixture", "query": "needle", "max_results": 1],
        ])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let payload = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(payload["status"] as? String, "partial")
        XCTAssertEqual(payload["returned"] as? Int, 1)
        XCTAssertEqual(payload["project_slug"] as? String, "fixture")
        XCTAssertEqual(resolvedProjects, ["fixture"])
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testUnauthorizedSearchDoesNotResolveAProjectAndUnknownProjectIsTyped() async throws {
        var lookups = 0
        let server = ConduitSessionAPIServer(
            token: "fixture-token",
            projectFilesystemRoot: { _ in lookups += 1; return nil }
        ) { _, _ in
            XCTFail("Refusal must not enter a task/runtime handler")
            return [:]
        }
        let params: [String: Any] = [
            "name": ConduitFilesystemSearchTool.name,
            "arguments": ["project_slug": "unknown", "query": "needle"],
        ]
        let denied = try request(server, "tools/call", params: params, authorized: false)
        XCTAssertEqual(denied["error"] as? String, "unauthorized")
        XCTAssertEqual(lookups, 0)

        let response = try request(server, "tools/call", params: params)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertEqual((result["structuredContent"] as? [String: Any])?["status"] as? String, "project_unavailable")
        XCTAssertEqual(lookups, 1)
    }

    func testLargeNumericRequestIdentityIsReturnedWithoutIntegerConversionTrap() async throws {
        let server = ConduitSessionAPIServer(token: "fixture-token") { _, _ in [:] }
        let response = try request(server, "ping", id: 1e100)
        XCTAssertEqual((response["id"] as? NSNumber)?.doubleValue, 1e100)
        let fractional = try request(server, "ping", id: 1.25)
        XCTAssertEqual((fractional["id"] as? NSNumber)?.doubleValue, 1.25)
    }

    func testDirectWriteSwitchRefusesBeforeProjectResolutionOrAdmission() async throws {
        var resolutions = 0
        var admissions = 0
        let server = ConduitSessionAPIServer(
            token: "fixture-token", allowWrites: false,
            projectFilesystemRoot: { _ in resolutions += 1; return nil },
            directWriteAdmission: { _ in admissions += 1; return nil }
        ) { _, _ in XCTFail("Direct operations cannot dispatch a session command"); return [:] }
        for name in [ConduitDirectCommandTool.executeName, ConduitDirectCommandTool.cancelName,
                     ConduitFilesystemMutationService.writeToolName] {
            let response = try request(server, "tools/call", params: ["name": name, "arguments": [:]])
            let result = try XCTUnwrap(response["result"] as? [String: Any])
            XCTAssertEqual(result["isError"] as? Bool, true)
            XCTAssertEqual((result["structuredContent"] as? [String: Any])?["status"] as? String, "writes_disabled")
        }
        XCTAssertEqual(resolutions, 0)
        XCTAssertEqual(admissions, 0)
    }

    func testFileMutationUsesInitializedCallerAndExistingAdmissionButReplayAndStatusDoNot() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = base.appendingPathComponent("project")
        let store = base.appendingPathComponent("receipts")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let service = ConduitFilesystemMutationService(receiptDirectory: store)
        let controller = MCPAdmissionController(policy: .conduitSessionAPI(writesEnabled: true))
        var admissions = 0
        var identities: [String?] = []
        let server = ConduitSessionAPIServer(
            token: "fixture-token", allowWrites: true,
            filesystemRoot: { project },
            projectFilesystemRoot: { $0 == "fixture" ? project : nil },
            filesystemMutationService: service,
            directWriteAdmission: { caller in
                admissions += 1
                identities.append(caller.identity)
                let stamp = Date()
                let resources = ConduitResourceSnapshot(
                    availablePhysicalMemoryBytes: .known(value: 8_589_934_592, observedAt: stamp),
                    ownedProcessTreeRSSBytes: .known(value: 1_073_741_824, observedAt: stamp),
                    persistenceQueueCount: .unknown, persistenceQueueBytes: .unknown,
                    promptQueueDepth: .known(value: 0, observedAt: stamp)
                )
                let decision = controller.admitWrite(callerIdentity: caller.identity, resources: resources, now: stamp)
                return decision.shouldExecute ? nil : ["error": decision.detail, "code": decision.code.rawValue]
            }
        ) { _, _ in XCTFail("File operations must not create or control a task"); return [:] }
        let arguments: [String: Any] = [
            "operation_id": "one-edit", "project_slug": "fixture", "path": "note.txt",
            "text": "exact content\n", "expected_absent": true,
        ]
        func call(_ name: String, _ args: [String: Any]) throws -> [String: Any] {
            let response = try request(server, "tools/call", params: ["name": name, "arguments": args])
            let result = try XCTUnwrap(response["result"] as? [String: Any])
            let payload = try XCTUnwrap(result["structuredContent"] as? [String: Any])
            XCTAssertEqual(result["isError"] as? Bool, payload["error"] != nil)
            return payload
        }
        let missingCaller = try call(ConduitFilesystemMutationService.writeToolName, arguments)
        XCTAssertEqual(missingCaller["status"] as? String, "admission_refused")
        XCTAssertEqual(admissions, 1)
        XCTAssertNil(identities[0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("note.txt").path))

        _ = try request(server, "initialize", params: ["clientInfo": ["name": "fixture-caller", "version": "1"]])
        let written = try call(ConduitFilesystemMutationService.writeToolName, arguments)
        XCTAssertEqual(written["status"] as? String, "succeeded")
        XCTAssertEqual(admissions, 2)
        XCTAssertEqual(identities[1], "fixture-caller/1")
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("note.txt")), "exact content\n")
        let replay = try call(ConduitFilesystemMutationService.writeToolName, arguments)
        XCTAssertEqual(replay["status"] as? String, "succeeded")
        XCTAssertEqual(replay["replayed"] as? Bool, true)
        let status = try call(ConduitFilesystemMutationService.statusToolName, ["operation_id": "one-edit", "project_slug": "fixture"])
        XCTAssertEqual(status["status"] as? String, "succeeded")
        XCTAssertEqual(admissions, 2)

        let read = try call(ConduitFilesystemReadTool.name, ["operation": "read", "path": "note.txt"])
        let after = try XCTUnwrap(written["after"] as? [String: Any])
        XCTAssertEqual(read["sha256"] as? String, after["sha256"] as? String)
        var changed = arguments
        changed["text"] = "different"
        XCTAssertEqual(try call(ConduitFilesystemMutationService.writeToolName, changed)["status"] as? String, "idempotency_conflict")
        XCTAssertEqual(admissions, 2)
    }

    func testCommandContractCannotSelectExecutionAuthorityOrCreateReceiptStorage() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = base.appendingPathComponent("project")
        let store = base.appendingPathComponent("commands")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        var admissions = 0
        let server = ConduitSessionAPIServer(
            token: "fixture-token", allowWrites: true,
            projectFilesystemRoot: { $0 == "fixture" ? project : nil },
            directCommandService: ConduitDirectCommandService(storeDirectory: store),
            directWriteAdmission: { _ in admissions += 1; return nil }
        ) { _, _ in XCTFail("Direct commands cannot start agent tasks"); return [:] }
        func call(_ name: String, _ args: [String: Any]) throws -> [String: Any] {
            let response = try request(server, "tools/call", params: ["name": name, "arguments": args])
            let result = try XCTUnwrap(response["result"] as? [String: Any])
            XCTAssertEqual(result["isError"] as? Bool, true)
            return try XCTUnwrap(result["structuredContent"] as? [String: Any])
        }
        let identity: [String: Any] = ["operation_id": "never-launched", "project_slug": "fixture"]
        var execution = identity
        execution["argv"] = ["/bin/echo", "fixture"]
        XCTAssertEqual(try call(ConduitDirectCommandTool.executeName, execution)["status"] as? String, "execution_authority_unavailable")
        XCTAssertEqual(try call(ConduitDirectCommandTool.statusName, identity)["status"] as? String, "operation_not_found")
        for override in ["operation", "root", "environment", "execution_profile"] {
            var invalid = execution
            invalid[override] = "caller-cannot-enable"
            XCTAssertEqual(try call(ConduitDirectCommandTool.executeName, invalid)["status"] as? String, "invalid_arguments")
        }
        XCTAssertEqual(admissions, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: project.path), [])
    }
}
#endif
