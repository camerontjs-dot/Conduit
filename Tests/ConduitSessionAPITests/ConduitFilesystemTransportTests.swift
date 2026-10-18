#if os(macOS)
import Foundation
import XCTest
import ConduitCore
@testable import Conduit

@MainActor
final class ConduitFilesystemTransportTests: XCTestCase {
    private func request(_ server: ConduitSessionAPIServer, _ method: String, params: [String: Any] = [:], authorized: Bool = true) throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
        let headers = "POST /mcp HTTP/1.1\r\n" + (authorized ? "Authorization: Bearer fixture-token\r\n" : "") + "Content-Length: \(body.count)\r\n\r\n"
        let response = server.response(for: Data(headers.utf8) + body)
        let text = try XCTUnwrap(String(data: response, encoding: .utf8))
        let range = try XCTUnwrap(text.range(of: "\r\n\r\n"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text[range.upperBound...].utf8)) as? [String: Any])
    }

    func testAuthoritativeHTTPToolsListPublishesReadCapabilityWithWritesDisabled() async throws {
        let server = ConduitSessionAPIServer(token: "fixture-token") { _, _ in
            XCTFail("Catalog discovery called a session handler")
            return [:]
        }
        let response = try request(server, "tools/list")
        let tools = try XCTUnwrap((response["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let tool = try XCTUnwrap(tools.first { $0["name"] as? String == ConduitFilesystemReadTool.name })
        XCTAssertEqual((tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true)
        let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
        XCTAssertEqual(schema["required"] as? [String], ["operation", "path"])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertEqual((properties["operation"] as? [String: Any])?["enum"] as? [String], ["list", "read", "stat"])
    }

    func testAuthenticatedFilesystemCallsNeverReachSessionRuntimeHandler() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("source.swift")
        try "let answer = 42\n".write(to: file, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: file)
        var commands: [ConduitSessionCommand] = []
        var rootRequests = 0
        let server = ConduitSessionAPIServer(token: "fixture-token", allowWrites: false, filesystemRoot: {
            rootRequests += 1
            return root
        }) { command, _ in
            commands.append(command)
            return ["error": "unexpected session mutation"]
        }
        // No initialize, task, runtime or local write switch is required.
        for operation in ["stat", "list", "read"] {
            let response = try request(server, "tools/call", params: ["name": ConduitFilesystemReadTool.name, "arguments": ["operation": operation, "path": operation == "list" ? "" : "source.swift"]])
            let result = try XCTUnwrap(response["result"] as? [String: Any])
            XCTAssertEqual(result["isError"] as? Bool, false)
            let payload = try XCTUnwrap(result["structuredContent"] as? [String: Any])
            XCTAssertEqual(payload["status"] as? String, "ok")
            if operation == "read" { XCTAssertEqual(payload["text"] as? String, "let answer = 42\n") }
        }
        let denied = try request(server, "tools/call", params: ["name": ConduitFilesystemReadTool.name, "arguments": ["operation": "read", "path": "source.swift"]], authorized: false)
        XCTAssertEqual(denied["error"] as? String, "unauthorized")
        XCTAssertEqual(rootRequests, 3)
        let write = try request(server, "tools/call", params: ["name": "conduit_create_task", "arguments": ["agent": "Shell", "project_slug": "fixture", "objective": "should remain disabled"]])
        XCTAssertEqual((write["result"] as? [String: Any])?["isError"] as? Bool, true)
        XCTAssertTrue(commands.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testStructuredFailuresRetainStatusAndNeverDispatchSessionCommands() async throws {
        let server = ConduitSessionAPIServer(token: "fixture-token") { _, _ in
            XCTFail("Filesystem failure reached session handler")
            return [:]
        }
        for (arguments, expected) in [
            (["operation": "stat", "path": "file.txt"], "root_unavailable"),
            (["operation": "read", "path": "../outside"], "outside_root"),
            (["operation": "write", "path": "file.txt"], "invalid_arguments"),
        ] {
            let response = try request(server, "tools/call", params: ["name": ConduitFilesystemReadTool.name, "arguments": arguments])
            let result = try XCTUnwrap(response["result"] as? [String: Any])
            XCTAssertEqual(result["isError"] as? Bool, true)
            XCTAssertEqual((result["structuredContent"] as? [String: Any])?["status"] as? String, expected)
        }
    }
}
#endif
