import XCTest
@testable import ConduitCore

final class CodexTerminalReplayTests: XCTestCase {
    func testUnsolicitedForeignThreadResponseCannotHideOwnedTerminalFailure() {
        var mapper = CodexAppServerMapper()
        mapper.threadID = "replay-thread"
        _ = mapper.apply(notification("turn/started", turn: "current"))
        let unrelated = mapper.apply(.response(id: .number(776655), result: .object([
            "thread": .object(["id": .string("foreign-thread")])
        ])))
        XCTAssertTrue(unrelated.isEmpty)
        XCTAssertEqual(mapper.threadID, "replay-thread")
        let effects = mapper.apply(notification("turn/completed", turn: "current", status: "failed"))
        guard case .turnFailed(let receipt) = effects.first else {
            return XCTFail("matching owned terminal failure must remain observable")
        }
        XCTAssertEqual(receipt.threadID, "replay-thread")
        XCTAssertEqual(receipt.turnID, "current")
        XCTAssertFalse(mapper.turnActive)
    }

    func testResponseShapeAloneCannotEstablishThreadAuthority() {
        var mapper = CodexAppServerMapper()
        XCTAssertTrue(mapper.apply(.response(id: .number(91), result: .object([
            "thread": .object(["id": .string("unrequested-thread")])
        ]))).isEmpty)
        XCTAssertNil(mapper.threadID)
    }

    func testOnlyExactOutstandingThreadRequestCanEstablishIdentityOnce() {
        var mapper = CodexAppServerMapper()
        mapper.expectThreadResponse(.number(17))
        let result = CodexJSON.object(["thread": .object(["id": .string("owned-thread")])])
        for id in [CodexJSONRPCID.number(18), .string("17")] {
            XCTAssertTrue(mapper.apply(.response(id: id, result: result)).isEmpty)
            XCTAssertNil(mapper.threadID)
        }
        XCTAssertEqual(mapper.apply(.response(id: .number(17), result: result)), [.threadStarted(id: "owned-thread")])
        XCTAssertTrue(mapper.apply(.response(id: .number(17), result: .object([
            "thread": .object(["id": .string("duplicate-foreign-thread")])
        ]))).isEmpty)
        XCTAssertEqual(mapper.threadID, "owned-thread")
    }

    func testCanceledOrRejectedThreadRequestCannotAdmitLateResponse() {
        for rejection in [false, true] {
            var mapper = CodexAppServerMapper()
            mapper.threadID = "owned-thread"
            mapper.expectThreadResponse(.number(17))
            if rejection {
                _ = mapper.apply(.error(id: .number(17), message: "request refused", code: -32602))
            } else {
                mapper.cancelThreadResponseExpectation()
            }
            XCTAssertTrue(mapper.apply(.response(id: .number(17), result: .object([
                "thread": .object(["id": .string("late-thread")])
            ]))).isEmpty)
            XCTAssertEqual(mapper.threadID, "owned-thread")
        }
    }

    func testEmptyThreadResponseConsumesExpectationWithoutIdentity() {
        var mapper = CodexAppServerMapper()
        mapper.expectThreadResponse(.number(17))
        XCTAssertTrue(mapper.apply(.response(id: .number(17), result: .object([
            "thread": .object(["id": .string("")])
        ]))).isEmpty)
        XCTAssertNil(mapper.threadID)
        XCTAssertTrue(mapper.apply(.response(id: .number(17), result: .object([
            "thread": .object(["id": .string("late-thread")])
        ]))).isEmpty)
        XCTAssertNil(mapper.threadID)
    }

    func testFractionalReplyIdentityCannotBecomeIntegerRequestAuthority() {
        XCTAssertNil(CodexJSONRPCID.parse(.number(3.5)))
        let reply = CodexJSONRPCMessage.parseLine(#"{"id":3.5,"error":{"code":400,"message":"rejected"}}"#)
        if case .error(let id, _, _) = reply {
            XCTAssertNotEqual(id, .number(3))
        }
    }

    func testContradictoryReplyShapesCannotCarryRejectionAuthority() {
        for value in [
            #"{"id":3,"result":{},"error":{"code":400,"message":"rejected"}}"#,
            #"{"id":3,"method":"turn/started","error":{"code":400,"message":"rejected"}}"#,
            #"{"id":3,"method":"turn/started","result":{}}"#
        ] {
            XCTAssertNil(CodexJSONRPCMessage.parseLine(value))
        }
    }

    func testOutOfRangeRequestIdentityFailsClosedWithoutIntegerTrap() {
        for value in [Double.greatestFiniteMagnitude, Double(Int.max), Double.infinity, Double.nan] {
            XCTAssertNil(CodexJSONRPCID.parse(.number(value)))
        }
        XCTAssertEqual(CodexJSONRPCID.parse(.number(3)), .number(3))
        XCTAssertEqual(CodexJSONRPCID.parse(.string("3")), .string("3"))
        XCTAssertNotEqual(CodexJSONRPCID.parse(.string("3")), .number(3))
    }

    private func notification(_ method: String, turn: String, thread: String = "replay-thread", status: String? = nil) -> CodexJSONRPCMessage {
        var value: [String: CodexJSON] = ["id": .string(turn)]
        if let status { value["status"] = .string(status) }
        return .notification(method: method, params: .object([
            "threadId": .string(thread), "turn": .object(value)
        ]))
    }

    func testDuplicateStartCannotResurrectTerminalTurn() {
        for status in ["failed", "completed", "interrupted"] {
            var mapper = CodexAppServerMapper()
            mapper.threadID = "replay-thread"
            _ = mapper.apply(notification("turn/started", turn: "one"))
            _ = mapper.apply(notification("turn/completed", turn: "one", status: status))
            XCTAssertTrue(mapper.apply(notification("turn/started", turn: "one")).isEmpty)
            XCTAssertFalse(mapper.turnActive)
            XCTAssertNil(mapper.activeTurnID)
            XCTAssertEqual(mapper.lastTurnStatus, status)
        }
    }

    func testRetiredTurnIdentitySurvivesNewInputReset() {
        var mapper = CodexAppServerMapper()
        mapper.threadID = "replay-thread"
        for turn in ["one", "two"] {
            mapper.resetTurn()
            _ = mapper.apply(notification("turn/started", turn: turn))
            _ = mapper.apply(notification("turn/completed", turn: turn, status: "failed"))
        }
        mapper.resetTurn()
        XCTAssertTrue(mapper.apply(notification("turn/started", turn: "one")).isEmpty)
        XCTAssertTrue(mapper.apply(notification("turn/started", turn: "two")).isEmpty)
        XCTAssertFalse(mapper.turnActive)
        XCTAssertNil(mapper.lastTurnStatus)
        XCTAssertEqual(mapper.apply(notification("turn/started", turn: "three")), [.turnStarted(id: "three")])
        XCTAssertTrue(mapper.turnActive)
    }

    func testInvalidStartCannotMutateExistingTurn() {
        var mapper = CodexAppServerMapper()
        mapper.threadID = "replay-thread"
        XCTAssertTrue(mapper.apply(.notification(method: "turn/started", params: .object(["threadId": .string("replay-thread")]))).isEmpty)
        XCTAssertFalse(mapper.turnActive)
        _ = mapper.apply(notification("turn/started", turn: "current"))
        XCTAssertTrue(mapper.apply(notification("turn/started", turn: "wrong", thread: "other-thread")).isEmpty)
        XCTAssertTrue(mapper.apply(notification("turn/started", turn: "wrong")).isEmpty)
        XCTAssertEqual(mapper.activeTurnID, "current")
    }

    func testKnownWrongOutputIdentityCannotOverwriteCurrentInput() {
        var mapper = CodexAppServerMapper()
        mapper.threadID = "replay-thread"
        _ = mapper.apply(notification("turn/started", turn: "current"))
        for (thread, turn) in [("other-thread", "current"), ("replay-thread", "old")] {
            XCTAssertTrue(mapper.apply(.notification(method: "item/agentMessage/delta", params: .object([
                "threadId": .string(thread), "turnId": .string(turn), "delta": .string("wrong-input")
            ]))).isEmpty)
        }
        XCTAssertTrue(mapper.accumulatedText.isEmpty)
        XCTAssertEqual(mapper.apply(.notification(method: "item/agentMessage/delta", params: .object([
            "threadId": .string("replay-thread"), "turnId": .string("current"), "delta": .string("right-input")
        ]))), [.upsertOutput(text: "right-input", state: .live)])
    }

    func testDurableFailedInputOutranksStaleLiveFlags() {
        let queued = SessionPresentation.promptEvent(text: "one", attachmentPaths: [], renderedPayload: "one")
        let prompt = SessionPresentation.updatingPromptDelivery(in: [queued], eventID: queued.id, to: .delivered)[0]
        var receipt = ProviderTurnFailureReceipt.codex(threadID: "replay-thread", turnID: "one", source: "turn/completed.failed")
        receipt.promptEventID = prompt.id
        for approval in [false, true] {
            let source = ConduitSessionEventSource(taskSessionID: "replay-task", backend: .appServer,
                sessionLifecycle: "running", runtimeState: "hosted", live: true, ready: true,
                events: [prompt, SessionPresentation.providerFailureEvent(receipt)],
                adapter: .init(threadID: "replay-thread", turnActive: true, lastTurnStatus: "failed", pendingApproval: approval))
            let status = ConduitSessionEventExport.turnSnapshot(source: source)
            let page = ConduitSessionEventExport.page(source: source)
            XCTAssertEqual(status.state, "failed")
            XCTAssertEqual(status.failure, receipt)
            XCTAssertEqual(page.turn, status)
            XCTAssertEqual(page.observation.checkpoint, .structuredFailed)
            XCTAssertEqual(page.session.lifecycle, "running")
        }
    }
}
