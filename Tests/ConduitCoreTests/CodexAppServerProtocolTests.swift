import XCTest
@testable import ConduitCore

final class CodexAppServerProtocolTests: XCTestCase {
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
        XCTAssertTrue(
            ConduitSessionAPI.isWrite(
                .sendPrompt(
                    taskSessionID: "t",
                    text: "hi",
                    origin: .chatgpt
                )
            )
        )
        XCTAssertEqual(ConduitSessionOrigin.chatgpt.promptOrigin, .chatgpt)
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
