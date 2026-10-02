import XCTest
@testable import ConduitCore

final class CodexAppServerProtocolTests: XCTestCase {
    func testJSONNumberOneIsNotBool() {
        guard case .object(let object) = CodexJSON.parseLine("{\"id\":1,\"ok\":true}") else {
            return XCTFail("expected object")
        }
        XCTAssertEqual(object["id"], .number(1))
        XCTAssertEqual(object["ok"], .bool(true))
    }

    func testParsesNotificationWithoutJsonrpcHeader() {
        let line = #"{"method":"item/agentMessage/delta","params":{"delta":"Hello"}}"#
        let message = CodexJSONRPCMessage.parseLine(line)
        guard case .notification(let method, let params) = message else {
            return XCTFail("expected notification")
        }
        XCTAssertEqual(method, "item/agentMessage/delta")
        XCTAssertEqual(params["delta"]?.stringValue, "Hello")
    }

    func testParsesServerApprovalRequest() {
        let line = #"{"method":"applyPatchApproval","id":7,"params":{"reason":"edit parser.swift"}}"#
        let message = CodexJSONRPCMessage.parseLine(line)
        guard case .request(let id, let method, let params) = message else {
            return XCTFail("expected request")
        }
        XCTAssertEqual(id, .number(7))
        XCTAssertEqual(method, "applyPatchApproval")
        XCTAssertEqual(params["reason"]?.stringValue, "edit parser.swift")
    }

    func testJSONRPCErrorRequiresValidErrorObjectAuthority() {
        let valid = CodexJSONRPCMessage.parseLine(
            #"{"id":7,"error":{"code":-32602,"message":"invalid params"}}"#
        )
        XCTAssertEqual(
            valid,
            .error(id: .number(7), message: "invalid params", code: -32602)
        )

        let malformed = [
            #"{"id":7,"error":null}"#,
            #"{"id":7,"error":"failed"}"#,
            #"{"id":7,"error":[]}"#,
            #"{"id":7,"error":1}"#,
            #"{"id":7,"error":{}}"#,
            #"{"id":7,"error":{"message":"missing code"}}"#,
            #"{"id":7,"error":{"code":"-32602","message":"string code"}}"#,
            #"{"id":7,"error":{"code":-32602}}"#,
            #"{"id":7,"error":{"code":-32602,"message":1}}"#,
            #"{"id":7,"error":{"code":-32602.5,"message":"fractional code"}}"#
        ]
        for line in malformed {
            XCTAssertNil(
                CodexJSONRPCMessage.parseLine(line),
                "Malformed JSON-RPC error must not gain rejection authority: \(line)"
            )
        }
    }

    func testMapperAccumulatesDeltasThenClosesOnTurnCompleted() {
        var mapper = CodexAppServerMapper()
        let first = mapper.apply(
            .notification(
                method: "item/agentMessage/delta",
                params: .object(["delta": .string("Hel")])
            )
        )
        let second = mapper.apply(
            .notification(
                method: "item/agentMessage/delta",
                params: .object(["delta": .string("lo")])
            )
        )
        let done = mapper.apply(
            .notification(
                method: "turn/completed",
                params: .object(["status": .string("completed")])
            )
        )
        XCTAssertEqual(first, [.upsertOutput(text: "Hel", state: .live)])
        XCTAssertEqual(second, [.upsertOutput(text: "Hello", state: .live)])
        XCTAssertEqual(
            done,
            [
                .upsertOutput(text: "Hello", state: .closed),
                .turnCompleted(status: "completed")
            ]
        )
        XCTAssertFalse(mapper.turnActive)
        XCTAssertEqual(mapper.lastTurnStatus, "completed")
    }

    func testMapperCapturesAndClearsExactActiveTurnIdentity() {
        var mapper = CodexAppServerMapper()
        let started = mapper.apply(
            .notification(
                method: "turn/started",
                params: .object([
                    "threadId": .string("thr_1"),
                    "turn": .object([
                        "id": .string("turn_1"),
                        "status": .string("inProgress"),
                    ]),
                ])
            )
        )
        XCTAssertEqual(started, [.turnStarted(id: "turn_1")])
        XCTAssertEqual(mapper.activeTurnID, "turn_1")
        XCTAssertTrue(mapper.turnActive)

        _ = mapper.apply(
            .notification(
                method: "turn/completed",
                params: .object([
                    "turn": .object([
                        "id": .string("turn_1"),
                        "status": .string("interrupted"),
                    ]),
                ])
            )
        )
        XCTAssertNil(mapper.activeTurnID)
        XCTAssertFalse(mapper.turnActive)
        XCTAssertEqual(mapper.lastTurnStatus, "interrupted")
    }

    func testTurnInterruptRequestCarriesExactThreadAndTurnIDs() {
        let request = CodexAppServerRequests.turnInterrupt(
            id: 7,
            threadID: "thr_exact",
            turnID: "turn_exact"
        )
        XCTAssertEqual(request["method"] as? String, "turn/interrupt")
        let params = request["params"] as? [String: String]
        XCTAssertEqual(params?["threadId"], "thr_exact")
        XCTAssertEqual(params?["turnId"], "turn_exact")
        XCTAssertEqual(params?.count, 2)
    }

    func testMapperThreadStartResponseAndApproval() {
        var mapper = CodexAppServerMapper()
        let started = mapper.apply(
            .response(
                id: .number(1),
                result: .object(["thread": .object(["id": .string("thr_1")])])
            )
        )
        let approval = mapper.apply(
            .request(
                id: .number(9),
                method: "item/commandExecution/requestApproval",
                params: .object(["command": .string("git status")])
            )
        )
        XCTAssertEqual(started, [.threadStarted(id: "thr_1")])
        XCTAssertEqual(mapper.threadID, "thr_1")
        guard case .requestApproval(let request) = approval.first else {
            return XCTFail("expected approval")
        }
        XCTAssertEqual(request.method, "item/commandExecution/requestApproval")
        XCTAssertEqual(request.summary, "git status")
        XCTAssertEqual(request.acceptResult["decision"] as? String, "accept")
    }

    func testCodexNativeActiveWriterErrorsMapToCollision() {
        XCTAssertTrue(
            CodexThreadWriterCollisionMapper.isActiveWriterConflict(
                "thread thr_1 already has an active writer"
            )
        )
        XCTAssertTrue(
            CodexThreadWriterCollisionMapper.isActiveWriterConflict(
                "This is open in another app"
            )
        )
        XCTAssertFalse(
            CodexThreadWriterCollisionMapper.isActiveWriterConflict(
                "thread thr_1 was not found"
            )
        )
    }

    func testCanonicalWriterCollisionFailsClosedBeforeFallback() {
        let collision = ProviderSessionAuthorityFailure.writerCollision(
            providerID: "codex",
            providerSessionID: "thr_1",
            detail: "already has an active writer"
        )

        XCTAssertTrue(
            ProviderSessionAuthorityFailure.isWriterCollision(collision)
        )
        XCTAssertEqual(
            StructuredAdapterStartFailurePolicy.disposition(
                for: collision
            ),
            .failClosedWriterCollision
        )
        XCTAssertEqual(
            StructuredAdapterStartFailurePolicy.disposition(
                for: "codex is not on PATH."
            ),
            .fallbackAllowed
        )
    }

    func testCollisionFailureKeepsExactProviderSessionIdentity() {
        let collision = ProviderSessionAuthorityFailure.writerCollision(
            providerID: "codex",
            providerSessionID: "thr_exact",
            detail: nil
        )

        XCTAssertTrue(collision.contains("thr_exact"))
        XCTAssertTrue(collision.hasPrefix("writer_collision:"))
        XCTAssertFalse(
            ProviderSessionAuthorityFailure.isWriterCollision(
                "thread thr_exact was not found"
            )
        )
    }

    func testCodexProfilePrefersAppServer() {
        XCTAssertEqual(
            AgentProfile(name: "Codex", command: "codex").preferredSessionBackend,
            .appServer
        )
        XCTAssertEqual(
            AgentProfile(name: "Claude", command: "claude").preferredSessionBackend,
            .structuredCli
        )
    }

    func testSessionAPIKeepsMindGraphScopesAndWriteBoundary() {
        XCTAssertTrue(ConduitSessionAPI.allowsMindGraphScope("knowledge"))
        XCTAssertTrue(ConduitSessionAPI.allowsMindGraphScope("projects"))
        XCTAssertFalse(ConduitSessionAPI.allowsMindGraphScope("both"))
        XCTAssertFalse(
            ConduitSessionAPI.isWrite(.listSessions(cursor: nil, limit: nil))
        )
        XCTAssertFalse(
            ConduitSessionAPI.isWrite(
                .sessionEvents(taskSessionID: "t", cursor: "v1:0", limit: 20)
            )
        )
        XCTAssertTrue(
            ConduitSessionAPI.isWrite(
                .sendPrompt(
                    taskSessionID: "t",
                    text: "hi",
                    origin: .chatgpt
                )
            )
        )
        XCTAssertTrue(
            ConduitSessionAPI.isWrite(
                .reconcileTask(taskSessionID: "task")
            )
        )
        XCTAssertEqual(ConduitSessionOrigin.chatgpt.promptOrigin, .chatgpt)
        XCTAssertTrue(
            ConduitSessionAPI.matchesAgent(
                AgentProfile(name: "Codex", command: "codex"),
                name: "codex"
            )
        )
        XCTAssertFalse(
            ConduitSessionAPI.matchesAgent(
                AgentProfile(name: "Claude", command: "claude"),
                name: "codex"
            )
        )
    }

    func testSessionAPIAcceptsAsynchronousReconcileOnlyWithSafeEvidence() {
        let attemptID = RuntimeAttemptID(
            rawValue: UUID(
                uuidString: "10000000-0000-0000-0000-000000000501"
            )!
        )

        XCTAssertTrue(
            ConduitSessionAPI.reconciliationRequestMayProceed(
                operationalState: .runtimeOpened(attemptID),
                hasCompatibleDiscoveredRuntime: true
            )
        )
        XCTAssertTrue(
            ConduitSessionAPI.reconciliationRequestMayProceed(
                operationalState: .runtimeProvisioning(
                    attemptID,
                    backend: "tmux",
                    tmuxSessionName: "conduit-canary"
                ),
                hasCompatibleDiscoveredRuntime: false
            )
        )
        XCTAssertFalse(
            ConduitSessionAPI.reconciliationRequestMayProceed(
                operationalState: .runtimeOpened(attemptID),
                hasCompatibleDiscoveredRuntime: false
            )
        )
    }

    func testPermissionDeclineUsesRPCError() {
        let approval = CodexAppServerApproval(
            id: "p",
            rpcID: .number(1),
            method: "item/permissions/requestApproval",
            summary: "fs"
        )
        XCTAssertTrue(approval.declineUsesRPCError)
        let command = CodexAppServerApproval(
            id: "c",
            rpcID: .number(2),
            method: "item/commandExecution/requestApproval",
            summary: "git status"
        )
        XCTAssertFalse(command.declineUsesRPCError)
        XCTAssertEqual(command.declineResult["decision"] as? String, "decline")
    }

    func testAdapterThreadStoreRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AdapterThreadStore(directory: directory)
        let task = TaskSessionID()
        store.save(taskSessionID: task, backend: "app-server", threadID: "thr_9")
        XCTAssertEqual(store.threadID(for: task), "thr_9")
    }

    func testMapperSkipsUserMessageChrome() {
        var mapper = CodexAppServerMapper()
        let chrome = mapper.apply(
            .notification(
                method: "item/started",
                params: .object([
                    "item": .object(["type": .string("userMessage")])
                ])
            )
        )
        let command = mapper.apply(
            .notification(
                method: "item/started",
                params: .object([
                    "item": .object([
                        "type": .string("commandExecution"),
                        "command": .string("git status"),
                    ])
                ])
            )
        )
        let delta = mapper.apply(
            .notification(
                method: "item/agentMessage/delta",
                params: .object(["delta": .string("pong")])
            )
        )
        XCTAssertTrue(chrome.isEmpty)
        XCTAssertEqual(
            command,
            [.upsertOutput(text: "[commandExecution] git status", state: .live)]
        )
        XCTAssertEqual(delta, [.upsertOutput(text: "[commandExecution] git status\npong", state: .live)])
    }

    func testStructuredAdapterEventUsesToolReportedAuthority() {
        let event = SessionPresentation.agentOutputEvent(
            promptEventID: nil,
            text: "Hello",
            state: .live,
            extraction: .structuredAdapter,
            truncated: false
        )
        XCTAssertEqual(event.authority, .toolReported)
    }
}
