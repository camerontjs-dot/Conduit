import XCTest
@testable import ConduitCore

final class ConduitSessionEventsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_787_000_000)

    func testPaginationIsMonotonicAndStable() {
        let events = (0..<5).map { index in
            promptEvent("p\(index)", at: t0.addingTimeInterval(Double(index)))
        }
        let source = source(events: events, backend: .pty)
        let first = ConduitSessionEventExport.page(source: source, limit: 2)
        let second = ConduitSessionEventExport.page(
            source: source,
            cursor: first.nextCursor,
            limit: 2
        )
        let third = ConduitSessionEventExport.page(
            source: source,
            cursor: second.nextCursor,
            limit: 2
        )

        XCTAssertEqual(first.events.map(\.text), ["p0", "p1"])
        XCTAssertEqual(first.nextCursor, "v1:2")
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(first.cursorState, .ok)
        XCTAssertEqual(second.events.map(\.text), ["p2", "p3"])
        XCTAssertEqual(second.nextCursor, "v1:4")
        XCTAssertEqual(third.events.map(\.text), ["p4"])
        XCTAssertEqual(third.nextCursor, "v1:5")
        XCTAssertFalse(third.hasMore)
        XCTAssertEqual(
            first.events.map(\.cursor),
            ["v1:0", "v1:1"]
        )
        XCTAssertEqual(ConduitSessionEventExport.clampLimit(999), 50)
        XCTAssertFalse(
            ConduitSessionAPI.isWrite(
                .sessionEvents(taskSessionID: "t", cursor: nil, limit: 2)
            )
        )
    }

    func testRedactionAndTruncation() {
        let secret = SessionPresentation.promptEvent(
            origin: .chatgpt,
            text: "Use Bearer sk-live-secret-value-123456 and api_key=supersecret then continue.",
            attachmentPaths: ["/tmp/notes.md"],
            renderedPayload: "hidden",
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            occurredAt: t0
        )
        let long = SessionPresentation.agentOutputEvent(
            promptEventID: secret.id,
            text: String(repeating: "x", count: 80) + "\nThought: I should hide this chain of thought.\n",
            state: .settled,
            extraction: .tmuxPane,
            truncated: true,
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            occurredAt: t0.addingTimeInterval(1)
        )
        let page = ConduitSessionEventExport.page(
            source: source(events: [secret, long], backend: .pty),
            textLimit: 40
        )

        XCTAssertEqual(page.events.count, 2)
        XCTAssertTrue(page.events[0].redacted)
        XCTAssertFalse(page.events[0].text?.contains("sk-live-secret") == true)
        XCTAssertFalse(page.events[0].text?.contains("supersecret") == true)
        XCTAssertTrue(page.events[0].text?.contains("[redacted]") == true)
        XCTAssertEqual(page.events[0].artifactRefs.map(\.path), ["/tmp/notes.md"])
        XCTAssertTrue(page.events[1].truncated)
        XCTAssertTrue(page.events[1].redacted)
        XCTAssertFalse(page.events[1].text?.contains("chain of thought") == true)
        XCTAssertTrue(page.truncated)
        XCTAssertEqual(page.events[0].authority, "conduitRecorded")
        XCTAssertEqual(page.events[1].authority, "derivedFromRaw")
    }

    func testCodexTurnCompletedWhileSessionStillRunning() {
        let prompt = deliveredPrompt("Reply pong", at: t0)
        let output = SessionPresentation.agentOutputEvent(
            promptEventID: prompt.id,
            text: "[fileChange] /tmp/hello.swift\nPong.",
            state: .closed,
            extraction: .structuredAdapter,
            truncated: false,
            id: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
            occurredAt: t0.addingTimeInterval(2)
        )
        let page = ConduitSessionEventExport.page(
            source: source(
                events: [opened(), prompt, output],
                backend: .appServer,
                lifecycle: "running",
                runtimeState: "running",
                live: true,
                ready: true,
                adapter: ConduitSessionAdapterSnapshot(
                    threadID: "thr_1",
                    turnActive: false,
                    lastTurnStatus: "completed"
                )
            )
        )

        XCTAssertEqual(page.session.lifecycle, "running")
        XCTAssertEqual(page.session.runtimeState, "running")
        XCTAssertEqual(page.session.live, true)
        XCTAssertEqual(page.turn.state, "completed")
        XCTAssertEqual(page.turn.status, "completed")
        XCTAssertEqual(page.turn.threadID, "thr_1")
        XCTAssertTrue(page.turn.honesty.contains("Not verified success"))
        XCTAssertNil(page.turn.ambiguity)
        XCTAssertEqual(page.events.last?.authority, "toolReported")
        XCTAssertEqual(page.events.last?.source, "structuredAdapter")
        XCTAssertEqual(page.events.last?.state, "closed")
        XCTAssertEqual(page.events.last?.turnStatus, "completed")
        XCTAssertEqual(page.events.last?.text, "[fileChange] /tmp/hello.swift\nPong.")
        XCTAssertEqual(
            page.events.last?.artifactRefs.map(\.path),
            ["/tmp/hello.swift"]
        )
    }

    func testPTYQuietIsAmbiguousAndNotCompleted() {
        let prompt = deliveredPrompt("hello", at: t0)
        let output = SessionPresentation.agentOutputEvent(
            promptEventID: prompt.id,
            text: "looks done",
            state: .settled,
            extraction: .tmuxPane,
            truncated: false,
            occurredAt: t0.addingTimeInterval(1)
        )
        let page = ConduitSessionEventExport.page(
            source: source(
                events: [prompt, output],
                backend: .pty,
                lifecycle: "running",
                runtimeState: "running",
                live: true,
                ready: true
            )
        )

        XCTAssertEqual(page.session.lifecycle, "running")
        XCTAssertEqual(page.turn.state, "ambiguous")
        XCTAssertEqual(page.turn.ambiguity, "pty_output_quiet")
        XCTAssertTrue(page.turn.honesty.contains("not turn completion"))
        XCTAssertEqual(page.events.last?.authority, "derivedFromRaw")
        XCTAssertNil(page.events.last?.turnStatus)
    }

    func testStaleCursorAheadOfTimeline() {
        let source = source(events: [promptEvent("one", at: t0)], backend: .pty)
        let page = ConduitSessionEventExport.page(
            source: source,
            cursor: "v1:9",
            limit: 10
        )
        XCTAssertEqual(page.cursorState, .ahead)
        XCTAssertTrue(page.events.isEmpty)
        XCTAssertEqual(page.nextCursor, "v1:1")
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(page.timelineCount, 1)
    }

    func testInvalidCursorResetsToStart() {
        let source = source(events: [promptEvent("one", at: t0)], backend: .pty)
        let page = ConduitSessionEventExport.page(
            source: source,
            cursor: "not-a-cursor"
        )
        XCTAssertEqual(page.cursorState, .invalid)
        XCTAssertEqual(page.events.map(\.text), ["one"])
        XCTAssertEqual(page.nextCursor, "v1:1")
    }

    func testLateEventsAppearAfterPreviousCursor() {
        let firstEvents = [
            promptEvent("one", at: t0),
            promptEvent("two", at: t0.addingTimeInterval(1)),
        ]
        let first = ConduitSessionEventExport.page(
            source: source(events: firstEvents, backend: .pty),
            limit: 2
        )
        XCTAssertEqual(first.nextCursor, "v1:2")
        XCTAssertFalse(first.hasMore)

        let later = firstEvents + [
            promptEvent("three", at: t0.addingTimeInterval(2)),
            SessionPresentation.agentOutputEvent(
                promptEventID: firstEvents[1].id,
                text: "late output",
                state: .live,
                extraction: .renderedBuffer,
                truncated: false,
                occurredAt: t0.addingTimeInterval(3)
            ),
        ]
        let second = ConduitSessionEventExport.page(
            source: source(events: later, backend: .pty),
            cursor: first.nextCursor,
            limit: 10
        )
        XCTAssertEqual(second.cursorState, .ok)
        XCTAssertEqual(second.events.map(\.text), ["three", "late output"])
        XCTAssertEqual(second.events.map(\.kind), ["user_prompt", "agent_output"])
        XCTAssertEqual(second.nextCursor, "v1:4")
    }

    func testLateRevisionStaysAtOriginalIndex() {
        let promptID = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
        let outputID = UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!
        let prompt = deliveredPrompt("go", id: promptID, at: t0)
        let live = SessionPresentation.agentOutputEvent(
            promptEventID: promptID,
            text: "Hel",
            state: .live,
            extraction: .structuredAdapter,
            truncated: false,
            id: outputID,
            occurredAt: t0.addingTimeInterval(1)
        )
        let first = ConduitSessionEventExport.page(
            source: source(
                events: [prompt, live],
                backend: .appServer,
                adapter: ConduitSessionAdapterSnapshot(turnActive: true)
            ),
            cursor: "v1:1",
            limit: 1
        )
        XCTAssertEqual(first.events.first?.text, "Hel")
        XCTAssertEqual(first.events.first?.eventID, outputID.uuidString)
        XCTAssertEqual(first.turn.state, "active")

        let closed = SessionPresentation.agentOutputEvent(
            promptEventID: promptID,
            text: "Hello",
            state: .closed,
            extraction: .structuredAdapter,
            truncated: false,
            id: outputID,
            occurredAt: t0.addingTimeInterval(1)
        )
        let second = ConduitSessionEventExport.page(
            source: source(
                events: [prompt, closed],
                backend: .appServer,
                adapter: ConduitSessionAdapterSnapshot(
                    turnActive: false,
                    lastTurnStatus: "completed"
                )
            ),
            cursor: "v1:1",
            limit: 1
        )
        XCTAssertEqual(second.events.first?.eventID, outputID.uuidString)
        XCTAssertEqual(second.events.first?.cursor, "v1:1")
        XCTAssertEqual(second.events.first?.text, "Hello")
        XCTAssertEqual(second.events.first?.state, "closed")
        XCTAssertEqual(second.events.first?.turnStatus, "completed")
        XCTAssertEqual(second.turn.state, "completed")
        XCTAssertNotEqual(
            first.events.first?.contentDigest,
            second.events.first?.contentDigest
        )
    }

    func testAwaitingInputUsesStructuredApproval() {
        let page = ConduitSessionEventExport.page(
            source: source(
                events: [deliveredPrompt("edit", at: t0)],
                backend: .appServer,
                adapter: ConduitSessionAdapterSnapshot(
                    threadID: "thr_2",
                    turnActive: true,
                    pendingApproval: true,
                    pendingApprovalSummary: "git status"
                )
            )
        )
        XCTAssertEqual(page.turn.state, "awaiting_input")
        XCTAssertTrue(page.turn.pendingApproval)
        XCTAssertTrue(page.turn.honesty.contains("approval"))
    }

    func testMapperRetainsTurnCompletionStatus() {
        var mapper = CodexAppServerMapper()
        _ = mapper.apply(
            .notification(
                method: "item/agentMessage/delta",
                params: .object(["delta": .string("Hi")])
            )
        )
        _ = mapper.apply(
            .notification(
                method: "turn/completed",
                params: .object(["status": .string("completed")])
            )
        )
        XCTAssertFalse(mapper.turnActive)
        XCTAssertEqual(mapper.lastTurnStatus, "completed")
        mapper.resetTurn()
        XCTAssertNil(mapper.lastTurnStatus)
    }

    private func source(
        events: [SessionPresentationEvent],
        backend: AgentSessionBackend,
        lifecycle: String = "running",
        runtimeState: String = "running",
        live: Bool = true,
        ready: Bool = true,
        adapter: ConduitSessionAdapterSnapshot? = nil
    ) -> ConduitSessionEventSource {
        ConduitSessionEventSource(
            taskSessionID: "11111111-1111-1111-1111-111111111111",
            backend: backend,
            sessionLifecycle: lifecycle,
            runtimeState: runtimeState,
            live: live,
            ready: ready,
            events: events,
            adapter: adapter
        )
    }

    private func opened() -> SessionPresentationEvent {
        SessionPresentation.openingEvent(
            .started(agentName: "Codex", requestedBackend: "app-server"),
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            occurredAt: t0.addingTimeInterval(-1)
        )
    }

    private func promptEvent(_ text: String, at date: Date) -> SessionPresentationEvent {
        SessionPresentation.promptEvent(
            origin: .chatgpt,
            text: text,
            attachmentPaths: [],
            renderedPayload: text,
            occurredAt: date
        )
    }

    private func deliveredPrompt(
        _ text: String,
        id: UUID = UUID(),
        at date: Date
    ) -> SessionPresentationEvent {
        let queued = SessionPresentation.promptEvent(
            origin: .chatgpt,
            text: text,
            attachmentPaths: [],
            renderedPayload: text,
            id: id,
            occurredAt: date
        )
        return SessionPresentation.updatingPromptDelivery(
            in: [queued],
            eventID: id,
            to: .delivered
        )[0]
    }
}
