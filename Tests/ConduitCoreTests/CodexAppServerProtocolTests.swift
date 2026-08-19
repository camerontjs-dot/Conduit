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

    func testCodexProfilePrefersAppServer() {
        XCTAssertEqual(
            AgentProfile(name: "Codex", command: "codex").preferredSessionBackend,
            .appServer
        )
        XCTAssertEqual(
            AgentProfile(name: "Claude", command: "claude").preferredSessionBackend,
            .pty
        )
    }

    func testSessionAPIKeepsMindGraphScopesAndWriteBoundary() {
        XCTAssertTrue(ConduitSessionAPI.allowsMindGraphScope("knowledge"))
        XCTAssertTrue(ConduitSessionAPI.allowsMindGraphScope("projects"))
        XCTAssertFalse(ConduitSessionAPI.allowsMindGraphScope("both"))
        XCTAssertFalse(
            ConduitSessionAPI.isWrite(.listSessions)
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
