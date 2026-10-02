import XCTest
@testable import ConduitCore

/// Sanitized 2026-09-30 incident shape. This tests protocol/state behavior,
/// never a permanent eligibility claim about a model or an account class.
final class CodexTerminalRejectionTests: XCTestCase {
    private func startedMapper() -> CodexAppServerMapper {
        var mapper = CodexAppServerMapper()
        mapper.threadID = "fixture-thread"
        _ = mapper.apply(.notification(method: "turn/started", params: .object([
            "threadId": .string("fixture-thread"),
            "turn": .object(["id": .string("fixture-turn")])
        ])))
        return mapper
    }

    private func rejection(willRetry: Bool) -> CodexJSONRPCMessage {
        .notification(method: "error", params: .object([
            "threadId": .string("fixture-thread"),
            "turnId": .string("fixture-turn"),
            "willRetry": .bool(willRetry),
            "error": .object([
                "message": .string("The 'gpt-6.1-sol' model is not supported when using Codex with a ChatGPT account."),
                "codexErrorInfo": .object([
                    "httpConnectionFailed": .object(["httpStatusCode": .number(400)])
                ]),
                "additionalDetails": .null
            ])
        ]))
    }

    func testNestedTerminalRejectionEndsMatchingTurnWithoutOutput() {
        var mapper = startedMapper()
        _ = mapper.apply(rejection(willRetry: false))
        XCTAssertFalse(mapper.turnActive)
        XCTAssertEqual(mapper.lastTurnStatus, "failed")
        XCTAssertTrue(mapper.accumulatedText.isEmpty)
    }

    func testRetryNotificationDoesNotEmitTerminalFailure() {
        var mapper = startedMapper()
        let effects = mapper.apply(rejection(willRetry: true))
        XCTAssertTrue(mapper.turnActive)
        XCTAssertNil(mapper.lastTurnStatus)
        XCTAssertFalse(effects.contains { if case .turnFailed = $0 { return true }; return false })
    }

    func testFailedTurnStatusIsNotCompletionWithoutOutput() {
        let source = ConduitSessionEventSource(
            taskSessionID: "fixture-task", backend: .appServer,
            sessionLifecycle: "running", runtimeState: "running", live: true, ready: true,
            events: [], adapter: .init(turnActive: false, lastTurnStatus: "failed")
        )
        XCTAssertEqual(ConduitSessionEventExport.turnSnapshot(source: source).state, "failed")
    }

    func testRuntimeCloseWithoutProviderFailureStaysUnresolved() {
        let prompt = SessionPresentation.promptEvent(text: "fixture", attachmentPaths: [], renderedPayload: "fixture")
        let events = SessionPresentation.updatingPromptDelivery(in: [prompt], eventID: prompt.id, to: .delivered)
        let source = ConduitSessionEventSource(
            taskSessionID: "fixture-task", backend: .appServer,
            sessionLifecycle: "closed", runtimeState: "closed", live: false, ready: false,
            events: events
        )
        XCTAssertNotEqual(ConduitSessionEventExport.turnSnapshot(source: source).state, "failed")
    }

    private func failure() -> ProviderTurnFailureReceipt {
        var mapper = startedMapper()
        guard case .turnFailed(let receipt) = mapper.apply(rejection(willRetry: false)).first else {
            XCTFail("Expected a typed terminal receipt")
            return .codex(threadID: "fixture-thread", turnID: "fixture-turn", source: "fixture")
        }
        return receipt
    }

    private func deliveredPrompt(_ text: String = "fixture") -> SessionPresentationEvent {
        let event = SessionPresentation.promptEvent(text: text, attachmentPaths: [], renderedPayload: text)
        return SessionPresentation.updatingPromptDelivery(in: [event], eventID: event.id, to: .delivered)[0]
    }

    private func closedSource(_ events: [SessionPresentationEvent]) -> ConduitSessionEventSource {
        .init(taskSessionID: "fixture-task", backend: .appServer,
              sessionLifecycle: "closed", runtimeState: "closed", live: false, ready: false,
              events: events, persistedThreadID: "fixture-thread")
    }

    func testDurableReplayAfterProviderCloseAgreesWithEventPageWithoutAssistantOutput() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let taskID = TaskSessionID()
        let log = ConversationEventLog(directory: directory, taskSessionID: taskID)
        let prompt = deliveredPrompt()
        var receipt = failure()
        receipt.promptEventID = prompt.id
        receipt.modelID = "gpt-6.1-sol"
        try log.append(prompt)
        try log.append(SessionPresentation.providerFailureEvent(receipt))
        // Reopen from disk: no adapter or provider process remains.
        let read = ConversationEventLog(directory: directory, taskSessionID: taskID).read()
        XCTAssertTrue(read.diagnostics.isEmpty)
        XCTAssertEqual(read.events.count, 2)
        let source = closedSource(read.events)
        let status = ConduitSessionEventExport.turnSnapshot(source: source)
        let page = ConduitSessionEventExport.page(source: source, limit: 100)
        XCTAssertEqual(status, page.turn)
        XCTAssertEqual(status.state, "failed")
        XCTAssertEqual(status.failure, receipt)
        XCTAssertEqual(status.threadIDSource, .persisted)
        XCTAssertEqual(page.session.lifecycle, "closed")
        XCTAssertEqual(page.session.runtimeState, "closed")
        XCTAssertEqual(page.observation.checkpoint, .structuredFailed)
        XCTAssertEqual(page.events.last?.kind, "provider_turn_failure")
        XCTAssertEqual(page.events.last?.providerFailure?.httpStatusCode, 400)
        XCTAssertEqual(page.events.last?.providerFailure?.errorType, "httpConnectionFailed")
        XCTAssertFalse(read.events.contains { if case .agentOutput = $0.kind { return true }; return false })
        let payload = try JSONSerialization.data(withJSONObject: page.jsonObject())
        let text = String(decoding: payload, as: UTF8.self)
        XCTAssertFalse(text.contains("objective_accepted"))
        XCTAssertFalse(text.contains("INCONCLUSIVE"))
    }

    func testLaterDeliveredPromptDoesNotInheritFailedTurn() {
        let prompt = deliveredPrompt()
        var receipt = failure()
        receipt.promptEventID = prompt.id
        let failureEvent = SessionPresentation.providerFailureEvent(receipt)
        let source = closedSource([prompt, failureEvent, deliveredPrompt("next turn")])
        XCTAssertEqual(ConduitSessionEventExport.turnSnapshot(source: source).state, "active")
        XCTAssertNil(ConduitSessionEventExport.turnSnapshot(source: source).failure)
    }

    func testQueuedPromptDoesNotHidePriorFailedProviderTurn() {
        let prompt = deliveredPrompt()
        var receipt = failure()
        receipt.promptEventID = prompt.id
        let queued = SessionPresentation.promptEvent(text: "next", attachmentPaths: [], renderedPayload: "next")
        let source = closedSource([prompt, SessionPresentation.providerFailureEvent(receipt), queued])
        XCTAssertEqual(ConduitSessionEventExport.turnSnapshot(source: source).state, "failed")
    }

    func testUnrelatedThreadOrProviderDoesNotBorrowFailureReceipt() {
        let prompt = deliveredPrompt()
        var receipt = failure()
        receipt.promptEventID = prompt.id
        var source = closedSource([prompt, SessionPresentation.providerFailureEvent(receipt)])
        source.persistedThreadID = "another-thread"
        XCTAssertNotEqual(ConduitSessionEventExport.turnSnapshot(source: source).state, "failed")
        source.persistedThreadID = nil
        source.backend = .httpServer
        XCTAssertNotEqual(ConduitSessionEventExport.turnSnapshot(source: source).state, "failed")
        source.backend = .pty
        XCTAssertEqual(ConduitSessionEventExport.turnSnapshot(source: source).state, "ambiguous")
    }

    func testActiveNewTurnOutranksHistoricalFailure() {
        let prompt = deliveredPrompt()
        var receipt = failure()
        receipt.promptEventID = prompt.id
        var source = closedSource([prompt, SessionPresentation.providerFailureEvent(receipt), deliveredPrompt("new input")])
        source.adapter = .init(threadID: "fixture-thread", turnActive: true)
        XCTAssertEqual(ConduitSessionEventExport.turnSnapshot(source: source).state, "active")
    }

    func testFailureEventRequiresToolAuthorityAndCannotBeRewritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ConversationEventLog(directory: directory, taskSessionID: TaskSessionID())
        let event = SessionPresentation.providerFailureEvent(failure(), occurredAt: Date(timeIntervalSince1970: 1_800_000_000))
        let wrongAuthority = SessionPresentationEvent(id: event.id, occurredAt: event.occurredAt,
                                                     authority: .derivedFromRaw, kind: event.kind)
        XCTAssertThrowsError(try log.append(wrongAuthority))
        try log.append(event)
        let changed = SessionPresentationEvent(id: event.id, occurredAt: event.occurredAt,
            authority: event.authority,
            kind: .providerTurnFailed(.codex(threadID: "other", turnID: nil, source: "fixture")))
        try log.append(changed)
        let read = log.read()
        XCTAssertEqual(read.events, [event])
        XCTAssertEqual(read.diagnostics.map(\.kind), [.invalidRevision])
    }

    func testFreeFormErrorPayloadIsWithheldWhileSafeTypeAndCodeSurvive() throws {
        let receipt = ProviderTurnFailureReceipt.codex(
            threadID: "fixture-thread", turnID: "fixture-turn", source: "turn/completed.failed",
            error: .object([
                "message": .string("token=secret-fixture-token user=person@example.invalid"),
                "additionalDetails": .string("Authorization: Bearer secret-fixture-token"),
                "codexErrorInfo": .object(["httpConnectionFailed": .object(["httpStatusCode": .number(403)])])
            ])
        )
        let json = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
        XCTAssertTrue(receipt.messageWithheld)
        XCTAssertEqual(receipt.errorType, "httpConnectionFailed")
        XCTAssertEqual(receipt.httpStatusCode, 403)
        XCTAssertFalse(json.contains("secret-fixture-token"))
        XCTAssertFalse(json.contains("example.invalid"))
        XCTAssertFalse(json.contains("additionalDetails"))
    }

    func testIncidentReasonIsScopedReceiptNotModelEligibilityRule() {
        let receipt = failure()
        XCTAssertEqual(receipt.providerID, "codex")
        XCTAssertEqual(receipt.runtime, "codex-app-server")
        XCTAssertFalse(receipt.messageWithheld)
        XCTAssertTrue(receipt.reason.contains("gpt-6.1-sol"))
        // The same prose without authoritative terminality must stay active.
        var mapper = startedMapper()
        _ = mapper.apply(rejection(willRetry: true))
        XCTAssertTrue(mapper.turnActive)
    }

    func testUnrelatedAndMissingCorrelationErrorsStayActive() {
        for params in [
            ["threadId": CodexJSON.string("other"), "turnId": .string("fixture-turn"), "willRetry": .bool(false), "error": .object([:])],
            ["threadId": .string("fixture-thread"), "turnId": .string("other"), "willRetry": .bool(false), "error": .object([:])],
            ["threadId": .string("fixture-thread"), "turnId": .string("fixture-turn"), "error": .object([:])]
        ] {
            var mapper = startedMapper()
            XCTAssertTrue(mapper.apply(.notification(method: "error", params: .object(params))).isEmpty)
            XCTAssertTrue(mapper.turnActive)
        }
    }

    func testGenericRPCErrorRetainsCodeButDoesNotTerminateMapperTurn() {
        let message = CodexJSONRPCMessage.parseLine(#"{"id":7,"error":{"code":-32602,"message":"invalid interrupt"}}"#)
        XCTAssertEqual(message, .error(id: .number(7), message: "invalid interrupt", code: -32602))
        var mapper = startedMapper()
        _ = mapper.apply(message!)
        XCTAssertTrue(mapper.turnActive)
        XCTAssertNil(mapper.lastTurnStatus)
    }

    func testMalformedErrorNotificationCannotManufactureTerminalFailure() {
        for error in [CodexJSON.null, .string("failed"), .object(["message": .number(1)])] {
            var mapper = startedMapper()
            XCTAssertTrue(mapper.apply(.notification(method: "error", params: .object([
                "threadId": .string("fixture-thread"), "turnId": .string("fixture-turn"),
                "willRetry": .bool(false), "error": error
            ]))).isEmpty)
            XCTAssertTrue(mapper.turnActive)
        }
    }

    func testFailedCompletionRetainsTerminalReceiptAndLateOutputCannotReactivateIt() {
        var mapper = startedMapper()
        let effects = mapper.apply(.notification(method: "turn/completed", params: .object([
            "threadId": .string("fixture-thread"),
            "turn": .object(["id": .string("fixture-turn"), "status": .string("failed"),
                             "error": .object(["codexErrorInfo": .string("unauthorized")])])
        ])))
        guard case .turnFailed(let receipt) = effects.first else { return XCTFail("Missing failure") }
        XCTAssertEqual(receipt.errorType, "unauthorized")
        XCTAssertFalse(mapper.turnActive)
        XCTAssertTrue(mapper.apply(.notification(method: "item/agentMessage/delta", params: .object(["delta": .string("late")]))).isEmpty)
        XCTAssertFalse(mapper.turnActive)
        XCTAssertEqual(mapper.lastTurnStatus, "failed")
    }

    func testLateUnrelatedFailedCompletionDoesNotEraseSuccessfulTurn() {
        var mapper = startedMapper()
        _ = mapper.apply(.notification(method: "turn/completed", params: .object([
            "threadId": .string("fixture-thread"), "turn": .object(["id": .string("fixture-turn"), "status": .string("completed")])
        ])))
        XCTAssertTrue(mapper.apply(.notification(method: "turn/completed", params: .object([
            "threadId": .string("fixture-thread"), "turn": .object(["id": .string("old-turn"), "status": .string("failed")])
        ]))).isEmpty)
        XCTAssertEqual(mapper.lastTurnStatus, "completed")
    }
}
