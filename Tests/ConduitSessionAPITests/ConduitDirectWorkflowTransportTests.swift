#if os(macOS)
import Foundation
import XCTest
@testable import ConduitCore
@testable import Conduit

/// Exercises the real HTTP parser and MCP dispatch with disposable native
/// execution. No listener, AppModel, window, provider or installed app is used.
@MainActor
final class ConduitDirectWorkflowTransportTests: XCTestCase {
    private func rpc(_ server: ConduitSessionAPIServer, method: String = "tools/call",
                     params: [String: Any]) throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
        let head = "POST /mcp HTTP/1.1\r\nAuthorization: Bearer fixture-token\r\nContent-Length: \(body.count)\r\n\r\n"
        let response = server.response(for: Data(head.utf8) + body)
        let separator = try XCTUnwrap(response.range(of: Data("\r\n\r\n".utf8)))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: response.suffix(from: separator.upperBound)) as? [String: Any])
    }

    private func tool(_ server: ConduitSessionAPIServer, _ name: String, _ args: [String: Any]) throws -> [String: Any] {
        let response = try rpc(server, params: ["name": name, "arguments": args])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let payload = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, payload["error"] != nil)
        return payload
    }

    func testInspectSearchConflictEditCheckAndReconnectUseExactRemoteScopeWithoutSessionDispatch() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("direct-http-\(UUID().uuidString)")
        let root = base.appendingPathComponent("remote-project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("before\n".utf8).write(to: root.appendingPathComponent("value.txt"))
        let untouched = root.appendingPathComponent("human-dirty.txt")
        let originalDirty = Data("uncommitted human edit\n".utf8)
        try originalDirty.write(to: untouched)
        let commands = ConduitDirectCommandService(storeDirectory: base.appendingPathComponent("commands"), disposableFixtureRoot: root)
        let files = ConduitFilesystemMutationService(receiptDirectory: base.appendingPathComponent("files"))
        var admissions = 0, sessionCalls = 0
        var slugs: [String] = []
        func server() -> ConduitSessionAPIServer {
            ConduitSessionAPIServer(token: "fixture-token", allowWrites: true,
                filesystemRoot: { root }, projectFilesystemRoot: { slug in
                    slugs.append(slug); return slug == "remote" ? root : nil
                }, directCommandService: commands, filesystemMutationService: files,
                directWriteAdmission: { caller in
                    guard caller.identity != nil else { return ["error": "initialize first"] }
                    admissions += 1; return nil
                }
            ) { _, _ in
                sessionCalls += 1; XCTFail("Direct work must not enter a task, provider or presentation action")
                return ["error": "unexpected dispatch"]
            }
        }
        let first = server()
        _ = try rpc(first, method: "initialize", params: ["clientInfo": ["name": "first", "version": "1"]])
        let read = try tool(first, "conduit_read_filesystem", ["operation": "read", "path": "value.txt"])
        let hash = try XCTUnwrap(read["sha256"] as? String)
        let search = try tool(first, "conduit_search_files", ["project_slug": "remote", "query": "before"])
        XCTAssertEqual(search["returned"] as? Int, 1)
        var write: [String: Any] = ["operation_id": "edit", "project_slug": "remote", "path": "value.txt",
                                   "expected_sha256": String(repeating: "0", count: 64), "text": "after\n"]
        XCTAssertNotNil(try tool(first, "conduit_write_file", write)["error"])
        XCTAssertEqual(admissions, 0)
        write["expected_sha256"] = hash
        XCTAssertEqual(try tool(first, "conduit_write_file", write)["status"] as? String, "succeeded")
        let run: [String: Any] = ["operation_id": "check", "project_slug": "remote", "timeout_ms": 180_000,
            "argv": ["/bin/sh", "-c", "printf x >> check-count; test \"$(cat value.txt)\" = after || exit 23; printf checked; printf diagnostic >&2"],
            "max_output_bytes": 16, "max_tail_bytes": 16]
        let accepted = try tool(first, "conduit_run_command", run)
        XCTAssertNil(accepted["error"])
        // The response is discarded as if transport disconnected. A new server
        // and changed display label must recover the same operation once.
        let reconnected = server()
        _ = try rpc(reconnected, method: "initialize", params: ["clientInfo": ["name": "reconnected", "version": "2"]])
        XCTAssertEqual(try tool(reconnected, "conduit_write_file", write)["replayed"] as? Bool, true)
        let retry = try tool(reconnected, "conduit_run_command", run)
        XCTAssertEqual((retry["receipt"] as? [String: Any])?["idempotent_replay"] as? Bool, true)
        var status: [String: Any] = [:]
        let deadline = Date().addingTimeInterval(5)
        repeat {
            status = try tool(reconnected, "conduit_command_status", ["operation_id": "check", "project_slug": "remote", "output_page_bytes": 4])
            if status["status"] as? String == "exited" { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline
        XCTAssertEqual(status["status"] as? String, "exited")
        let receipt = try XCTUnwrap(status["receipt"] as? [String: Any])
        XCTAssertEqual(receipt["exit_code"] as? Int, 0)
        XCTAssertEqual((receipt["stdout"] as? [String: Any])?["text"] as? String, "chec")
        XCTAssertEqual((receipt["stderr"] as? [String: Any])?["text"] as? String, "diag")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("check-count")), "x")
        XCTAssertEqual(try Data(contentsOf: untouched), originalDirty)
        XCTAssertEqual(admissions, 2, "Only the original file edit and command consume write admission")
        XCTAssertEqual(sessionCalls, 0)
        XCTAssertTrue(slugs.allSatisfy { $0 == "remote" })
    }
}
#endif
