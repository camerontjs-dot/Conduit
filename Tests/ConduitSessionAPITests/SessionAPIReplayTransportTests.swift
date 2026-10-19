#if os(macOS)
import XCTest
import ConduitCore
@testable import Conduit

/// In-process HTTP/MCP transport with injected admission/dispatch. No listener,
/// AppModel startup, providers, or installed app participate in this fixture.
@MainActor
final class SessionAPIReplayTransportTests: XCTestCase {
    private func request(_ server: ConduitSessionAPIServer, method: String,
                         params: [String: Any]) throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1,
                                                                 "method": method, "params": params])
        let header = "POST /mcp HTTP/1.1\r\nAuthorization: Bearer fixture\r\nContent-Length: \(body.count)\r\n\r\n"
        let response = server.response(for: Data(header.utf8) + body)
        let text = try XCTUnwrap(String(data: response, encoding: .utf8))
        let range = try XCTUnwrap(text.range(of: "\r\n\r\n"))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text[range.upperBound...].utf8)) as? [String: Any])
        return try XCTUnwrap(envelope["result"] as? [String: Any])
    }
    private func initialize(_ server: ConduitSessionAPIServer) throws {
        _ = try request(server, method: "initialize", params: ["clientInfo": ["name": "fixture", "version": "1"]])
    }
    private func payload(_ response: [String: Any]) throws -> [String: Any] {
        let content = try XCTUnwrap(response["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
    func testCreateAndPromptReplayAcrossServerJournalAndControllerRecreation() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("journal")
        let task = TaskSessionID()
        let event = UUID().uuidString
        var effects = 0
        var admissions = 0
        func server() throws -> ConduitSessionAPIServer {
            let journal = try SessionAPIReplayJournal(directory: directory)
            let controller = MCPAdmissionController(policy: .conduitSessionAPI(writesEnabled: true), initialLiveTaskSessionIDs: [task])
            return ConduitSessionAPIServer(token: "fixture", allowWrites: true) { command, caller in
                let operation: String, key: String, fields: [String]
                switch command {
                case .createTask(let agent, let project, let objective, let supplied):
                    operation = "conduit_create_task"; key = supplied ?? ""; fields = [agent, project, objective]
                case .sendPrompt(let id, let text, let origin, let supplied):
                    operation = "conduit_send_prompt"; key = supplied ?? ""; fields = [id, text, origin.rawValue]
                default: XCTFail("unexpected command"); return [:]
                }
                return journal.perform(caller: caller.identity, operation: operation, key: key, fields: fields) {
                    admissions += 1
                    let now = Date()
                    let resources = ConduitResourceSnapshot(
                        availablePhysicalMemoryBytes: .known(value: 16_000_000_000, observedAt: now),
                        ownedProcessTreeRSSBytes: .known(value: 0, observedAt: now),
                        persistenceQueueCount: .known(value: 0, observedAt: now),
                        persistenceQueueBytes: .known(value: 0, observedAt: now),
                        promptQueueDepth: .known(value: 0, observedAt: now))
                    let decision = operation == "conduit_create_task"
                        ? controller.admitCreate(callerIdentity: caller.identity, dedupeIdentity: nil, resources: resources)
                        : controller.admitPrompt(callerIdentity: caller.identity, taskSessionID: task,
                            observedTaskQueueDepth: 0, resources: resources)
                    XCTAssertTrue(decision.shouldExecute)
                    if let reservation = decision.reservationID {
                        if operation == "conduit_create_task" { controller.commitCreate(reservationID: reservation, taskSessionID: task) }
                        else { controller.markPromptFinished(reservationID: reservation) }
                    }
                    effects += 1
                    return ["taskSessionID": task.rawValue.uuidString, "eventID": event,
                            "delivered": false, "delivery": "queued", "ancillary_warnings": ["fixture warning"]]
                }
            }
        }
        let create: [String: Any] = ["name": "conduit_create_task", "arguments": ["agent": "fixture", "project_slug": "project", "objective": "secret", "idempotency_key": "create-key"]]
        let prompt: [String: Any] = ["name": "conduit_send_prompt", "arguments": ["taskSessionID": task.rawValue.uuidString, "text": "secret", "idempotency_key": "prompt-key"]]
        var first: ConduitSessionAPIServer? = try server()
        try initialize(first!)
        for params in [create, prompt] {
            let response = try request(first!, method: "tools/call", params: params)
            XCTAssertEqual(response["isError"] as? Bool, false)
            XCTAssertNotNil(try payload(response)["ancillary_warnings"])
        }
        first = nil
        let second = try server()
        try initialize(second)
        for params in [create, prompt] {
            let replay = try payload(request(second, method: "tools/call", params: params))
            XCTAssertEqual(replay["deduplicated"] as? Bool, true)
            XCTAssertEqual(replay["taskSessionID"] as? String, task.rawValue.uuidString)
            XCTAssertEqual(replay["eventID"] as? String, event)
        }
        XCTAssertEqual(effects, 2)
        XCTAssertEqual(admissions, 2)
    }
    func testPromptSchemaKeepsExactOptionalKeyAndRefusesWrongType() async throws {
        var commands: [ConduitSessionCommand] = []
        let server = ConduitSessionAPIServer(token: "fixture", allowWrites: true) { command, _ in
            commands.append(command); return [:]
        }
        try initialize(server)
        for key in [nil, " exact key "] as [String?] {
            var arguments: [String: Any] = ["taskSessionID": "task", "text": "prompt"]
            if let key { arguments["idempotency_key"] = key }
            _ = try request(server, method: "tools/call", params: ["name": "conduit_send_prompt", "arguments": arguments])
            XCTAssertEqual(commands.last, .sendPrompt(taskSessionID: "task", text: "prompt", origin: .chatgpt, idempotencyKey: key))
        }
        let refused = try request(server, method: "tools/call", params: ["name": "conduit_send_prompt", "arguments": ["taskSessionID": "task", "text": "prompt", "idempotency_key": 12]])
        XCTAssertEqual(refused["isError"] as? Bool, true)
        XCTAssertEqual(commands.count, 2)
        let catalog = try request(server, method: "tools/list", params: [:])
        let tools = try XCTUnwrap(catalog["tools"] as? [[String: Any]])
        let prompt = try XCTUnwrap(tools.first { $0["name"] as? String == "conduit_send_prompt" })
        let schema = try XCTUnwrap(prompt["inputSchema"] as? [String: Any])
        XCTAssertNotNil((schema["properties"] as? [String: Any])?["idempotency_key"])
        XCTAssertFalse((schema["required"] as? [String] ?? []).contains("idempotency_key"))
    }
}
#endif
