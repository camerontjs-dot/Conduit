#if os(macOS)
import XCTest
import ConduitCore
@testable import Conduit

/// In-process HTTP/MCP transport with injected admission/dispatch. No listener,
/// AppModel startup, providers, or installed app participate in this fixture.
@MainActor
final class SessionAPIReplayTransportTests: XCTestCase {
    private final class FakeObserver: ProviderSessionObserving {
        let providerID = "fixture"
        var listedSessionID = "ses_existing"
        var observedSessionID = "ses_existing"
        var listCalls = 0
        var observeCalls = 0

        func listSessions(
            bindingResolver: ((String) -> ProviderObservationBinding?)?
        ) throws -> [WorkerLineage] {
            listCalls += 1
            return [
                makeWorker(
                    sessionID: listedSessionID,
                    binding: bindingResolver?(listedSessionID)
                )
            ]
        }

        func observeSession(
            providerSessionID: String,
            binding: ProviderObservationBinding?
        ) throws -> WorkerLineage {
            observeCalls += 1
            return makeWorker(
                sessionID: observedSessionID,
                binding: binding
            )
        }

        private func makeWorker(
            sessionID: String,
            binding: ProviderObservationBinding?
        ) -> WorkerLineage {
            let observed = SupervisionObservationStamp(
                authority: .providerObserved,
                freshness: .unknown,
                observedAt: .known(
                    Date(timeIntervalSince1970: 1_797_000_000)
                )
            )
            return WorkerLineage(
                conduitTaskID: binding.map {
                    .known($0.conduitTaskID)
                } ?? .unknown,
                runtimeAttemptID: binding?.runtimeAttemptID.map {
                    .known($0)
                } ?? .unknown,
                runtime: .known("fixture"),
                adapter: .known("fixture_read_only"),
                providerHostID: .unknown,
                providerSessionID: .known(sessionID),
                turns: [
                    ProviderTurnLineage(
                        turnID: .known("turn-1"),
                        state: .completed,
                        model: .known(
                            ProviderModelIdentity(
                                providerID: "fixture-model-provider",
                                modelID: "fixture-model"
                            )
                        ),
                        observation: observed
                    )
                ],
                workspace: WorkerWorkspaceLineage(
                    projectSlug: .unknown,
                    cwd: .known("/tmp/fixture"),
                    repositoryRoot: .unknown,
                    worktree: .unknown
                ),
                process: WorkerProcessLineage(
                    launcherPID: .unknown,
                    processGroupID: .unknown,
                    parentPID: .unknown
                ),
                origin: .unknown,
                relationship: .discovered,
                writerControllerID: .unknown,
                terminal: WorkerTerminalState(
                    receipt: .unknown,
                    verification: .unknown,
                    objectiveAcceptance: .unknown
                ),
                observation: observed,
                providerSpecific: .unknown
            )
        }
    }

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
    private func initialize(_ server: ConduitSessionAPIServer, clientName: String = "fixture") throws {
        _ = try request(server, method: "initialize", params: ["clientInfo": ["name": clientName, "version": "1"]])
    }
    private func payload(_ response: [String: Any]) throws -> [String: Any] {
        let content = try XCTUnwrap(response["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
    func testSharedBearerBudgetSurvivesInitializeLabelChange() async throws {
        let controller = MCPAdmissionController(policy: .conduitSessionAPI(writesEnabled: true))
        var stamp = Date(timeIntervalSince1970: 1_797_000_000)
        var labels: [String?] = []
        let server = ConduitSessionAPIServer(token: "fixture", allowWrites: true) { _, caller in
            labels.append(caller.identity)
            let resources = ConduitResourceSnapshot(
                availablePhysicalMemoryBytes: .known(value: 16_000_000_000, observedAt: stamp),
                ownedProcessTreeRSSBytes: .known(value: 0, observedAt: stamp),
                persistenceQueueCount: .known(value: 0, observedAt: stamp),
                persistenceQueueBytes: .known(value: 0, observedAt: stamp),
                promptQueueDepth: .known(value: 0, observedAt: stamp))
            let decision = controller.admitWrite(callerIdentity: caller.identity, resources: resources, now: stamp)
            return ["code": decision.code.rawValue]
        }
        let params: [String: Any] = ["name": "conduit_adopt_provider_session", "arguments": [
            "provider": "opencode", "provider_session_id": "synthetic", "controller_id": "fixture"]]
        func call() throws -> String? {
            try payload(request(server, method: "tools/call", params: params))["code"] as? String
        }
        XCTAssertEqual(try call(), "caller_identity_required")
        try initialize(server, clientName: "A")
        for _ in 0..<30 { XCTAssertEqual(try call(), "admitted") }
        try initialize(server, clientName: "B")
        XCTAssertEqual(try call(), "caller_write_rate_limited")
        XCTAssertEqual(labels.first!, nil)
        XCTAssertEqual(labels[1], "A/1")
        XCTAssertEqual(labels.last!, "B/1")
        stamp = stamp.addingTimeInterval(61)
        XCTAssertEqual(try call(), "admitted")
    }

    func testAdoptionAdmissionGuardsOwnershipThroughSyntheticTransport() async throws {
        enum Denied: Error { case admission }
        for refusal in ["writes_disabled", "caller_identity_required", "resource_unknown", "caller_write_rate_limited"] {
            var policy = MCPAdmissionPolicy.conduitSessionAPI(writesEnabled: refusal != "writes_disabled")
            policy.perCallerWriteLimit = 1
            let controller = MCPAdmissionController(policy: policy)
            let registry = ProviderSessionAuthorityRegistry()
            let coordinator = ProviderSessionAuthorityCoordinator(observer: FakeObserver(), registry: registry)
            let now = Date()
            let healthy = ConduitResourceSnapshot(
                availablePhysicalMemoryBytes: .known(value: 16_000_000_000, observedAt: now),
                ownedProcessTreeRSSBytes: .known(value: 0, observedAt: now),
                persistenceQueueCount: .known(value: 0, observedAt: now),
                persistenceQueueBytes: .known(value: 0, observedAt: now),
                promptQueueDepth: .known(value: 0, observedAt: now))
            if refusal == "caller_write_rate_limited" {
                XCTAssertTrue(controller.admitWrite(callerIdentity: "A", resources: healthy, now: now).shouldExecute)
            }
            let server = ConduitSessionAPIServer(token: "fixture", allowWrites: true) { command, caller in
                guard case .adoptProviderSession(_, let session, let owner) = command else {
                    XCTFail("unexpected command"); return [:]
                }
                var code = "not_checked"
                do {
                    _ = try coordinator.adoptSession(providerSessionID: session, controllerID: owner, admitWrite: {
                        let decision = controller.admitWrite(callerIdentity: caller.identity,
                            resources: refusal == "resource_unknown" ? .unknown : healthy, now: now)
                        code = decision.code.rawValue
                        if !decision.shouldExecute { throw Denied.admission }
                    })
                    XCTFail("denied adoption executed")
                } catch { }
                return ["error": code]
            }
            if refusal != "caller_identity_required" { try initialize(server, clientName: "B") }
            let before = try registry.snapshot(providerID: "fixture", providerSessionID: "ses_existing")
            let result = try payload(request(server, method: "tools/call", params: [
                "name": "conduit_adopt_provider_session", "arguments": ["provider": "opencode",
                    "provider_session_id": "ses_existing", "controller_id": "B"]]))
            XCTAssertEqual(result["error"] as? String, refusal)
            XCTAssertEqual(try registry.snapshot(providerID: "fixture", providerSessionID: "ses_existing"), before)
            XCTAssertEqual(try coordinator.observeSession(providerSessionID: "ses_existing").authority, before)
        }
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
                return journal.perform(caller: ConduitSessionAPI.replayAuthorityScope, operation: operation, key: key, fields: fields) {
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
    func testInterveningClientInitializeCannotBypassOriginalKeyedSend() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SessionAPIReplayJournal(directory: root.appendingPathComponent("journal"))
        let taskID = UUID().uuidString
        let eventID = UUID().uuidString
        var dispatches = 0
        var seenClientLabels: [String?] = []
        let server = ConduitSessionAPIServer(token: "fixture", allowWrites: true) { command, caller in
            seenClientLabels.append(caller.identity)
            guard case .sendPrompt(let id, let text, let origin, let key) = command else {
                XCTFail("unexpected command"); return [:]
            }
            return journal.perform(caller: ConduitSessionAPI.replayAuthorityScope,
                                   operation: "conduit_send_prompt", key: key ?? "",
                                   fields: [id, text, origin.rawValue]) {
                dispatches += 1
                return ["taskSessionID": taskID, "eventID": eventID,
                        "delivered": false, "delivery": "queued"]
            }
        }
        let requestA: [String: Any] = ["name": "conduit_send_prompt",
            "arguments": ["taskSessionID": taskID, "text": "exact prompt",
                          "idempotency_key": "same-key"]]
        try initialize(server, clientName: "client-A")
        let first = try payload(request(server, method: "tools/call", params: requestA))
        XCTAssertEqual(first["eventID"] as? String, eventID)
        XCTAssertEqual(dispatches, 1)

        // Exact adversarial sequence: B overwrites clientInfo, then A retries.
        try initialize(server, clientName: "client-B")
        let replay = try payload(request(server, method: "tools/call", params: requestA))
        XCTAssertEqual(replay["deduplicated"] as? Bool, true)
        XCTAssertEqual(replay["taskSessionID"] as? String, taskID)
        XCTAssertEqual(replay["eventID"] as? String, eventID)
        XCTAssertEqual(dispatches, 1)
        XCTAssertEqual(seenClientLabels, ["client-A/1", "client-B/1"])

        // Clients with one bearer share one durable retry-key namespace.
        let changed: [String: Any] = ["name": "conduit_send_prompt",
            "arguments": ["taskSessionID": taskID, "text": "different prompt",
                          "idempotency_key": "same-key"]]
        let conflict = try payload(request(server, method: "tools/call", params: changed))
        XCTAssertEqual(conflict["replay_state"] as? String, "conflict")
        XCTAssertEqual(dispatches, 1)
    }

    func testImmediateStructuredRefusalIsAnMCPError() async throws {
        let task = UUID().uuidString, event = UUID().uuidString
        let server = ConduitSessionAPIServer(token: "fixture", allowWrites: true) { command, _ in
            guard case .sendPrompt = command else { XCTFail("unexpected command"); return [:] }
            return ConduitSessionAPI.structuredPromptResult(
                taskSessionID: task, eventID: event, delivered: false,
                backend: "fixture", origin: .chatgpt
            )
        }
        try initialize(server)
        let response = try request(server, method: "tools/call", params: [
            "name": "conduit_send_prompt",
            "arguments": ["taskSessionID": task, "text": "second concurrent prompt"]
        ])
        XCTAssertEqual(response["isError"] as? Bool, true)
        let result = try payload(response)
        XCTAssertEqual(result["eventID"] as? String, event)
        XCTAssertEqual(result["delivery"] as? String, "failed")
        XCTAssertEqual(result["delivered"] as? Bool, false)
        XCTAssertNotNil(result["error"] as? String)
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
