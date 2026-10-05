import XCTest
@testable import ConduitCore

final class ThreadUnseenOutputTests: XCTestCase {
    private let taskID = TaskSessionID(
        rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    )
    private let promptID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let outputID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    private func outputEvent(
        text: String,
        state: AgentOutputState = .live,
        extraction: AgentOutputExtraction = .renderedBuffer,
        truncated: Bool = false,
        id: UUID? = nil,
        promptEventID: UUID? = nil
    ) -> SessionPresentationEvent {
        SessionPresentation.agentOutputEvent(
            promptEventID: promptEventID ?? promptID,
            text: text,
            state: state,
            extraction: extraction,
            truncated: truncated,
            id: id ?? outputID,
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private func identity(_ event: SessionPresentationEvent) -> ThreadOutputRevisionIdentity {
        guard case .agentOutput(let output) = event.kind else {
            fatalError("fixture is not output")
        }
        return ThreadUnseenOutput.revisionIdentity(event: event, output: output)
    }

    func testNoOutputIsNotUnseen() {
        let prompt = SessionPresentation.promptEvent(
            text: "hello",
            attachmentPaths: [],
            renderedPayload: "hello",
            id: promptID
        )
        XCTAssertEqual(
            ThreadUnseenOutput.project(
                taskSessionID: taskID,
                events: [prompt],
                source: .retained(.completeRetainedTimeline),
                lastSeenRevision: nil
            ),
            .none
        )
    }

    func testFirstVisibleOutputIsUnseenWithoutCursor() {
        let event = outputEvent(text: "alpha")
        XCTAssertEqual(
            ThreadUnseenOutput.project(
                taskSessionID: taskID,
                events: [event],
                source: .retained(.completeRetainedTimeline),
                lastSeenRevision: nil
            ),
            .unseen(identity(event))
        )
    }

    func testExactLatestRevisionIsSeen() {
        let event = outputEvent(text: "alpha")
        let seen = identity(event)
        XCTAssertEqual(
            ThreadUnseenOutput.project(
                taskSessionID: taskID,
                events: [event],
                source: .retained(.completeRetainedTimeline),
                lastSeenRevision: seen
            ),
            .none
        )
    }

    func testTextRevisionUnderSameEventIDBecomesUnseen() {
        let before = outputEvent(text: "alpha")
        let after = outputEvent(text: "alpha beta")
        XCTAssertEqual(before.id, after.id)

        let result = ThreadUnseenOutput.project(
            taskSessionID: taskID,
            events: [after],
            source: .retained(.boundedRetainedWindow),
            lastSeenRevision: identity(before)
        )
        XCTAssertEqual(result, .unseen(identity(after)))
        XCTAssertNotEqual(identity(before).visibleTextSHA256, identity(after).visibleTextSHA256)
    }

    func testCaptureStateOnlyChangeDoesNotBecomeUnseen() {
        let live = outputEvent(text: "same text", state: .live)
        let closed = outputEvent(text: "same text", state: .closed)

        XCTAssertEqual(identity(live), identity(closed))
        XCTAssertEqual(
            ThreadUnseenOutput.project(
                taskSessionID: taskID,
                events: [closed],
                source: .retained(.boundedRetainedWindow),
                lastSeenRevision: identity(live)
            ),
            .none
        )
    }

    func testSourceShapingChangeBecomesUnseen() {
        let before = outputEvent(text: "same", truncated: false)
        let after = outputEvent(text: "same", truncated: true)

        XCTAssertNotEqual(identity(before), identity(after))
        XCTAssertEqual(
            ThreadUnseenOutput.project(
                taskSessionID: taskID,
                events: [after],
                source: .retained(.completeRetainedTimeline),
                lastSeenRevision: identity(before)
            ),
            .unseen(identity(after))
        )
    }

    func testNewOutputEventIDBecomesUnseen() {
        let first = outputEvent(text: "first")
        let second = outputEvent(
            text: "second",
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        )

        XCTAssertEqual(
            ThreadUnseenOutput.project(
                taskSessionID: taskID,
                events: [first, second],
                source: .retained(.completeRetainedTimeline),
                lastSeenRevision: identity(first)
            ),
            .unseen(identity(second))
        )
    }

    func testUnicodeDigestUsesExactUTF8Bytes() {
        let event = outputEvent(text: "é 👩🏽‍💻")
        let value = identity(event)
        XCTAssertEqual(value.visibleUTF8ByteCount, "é 👩🏽‍💻".utf8.count)
        XCTAssertEqual(value.visibleTextSHA256.count, 64)

        let same = outputEvent(text: "é 👩🏽‍💻", state: .settled)
        XCTAssertEqual(value, identity(same))
    }

    func testUnavailableSourcePropagates() {
        XCTAssertEqual(
            ThreadUnseenOutput.project(
                taskSessionID: taskID,
                events: [],
                source: .unavailable(.sourceHasDiagnostics),
                lastSeenRevision: nil
            ),
            .unavailable(.sourceHasDiagnostics)
        )
    }

    func testInvalidAuthorityFailsClosedThroughRecognitionValidation() {
        let bad = SessionPresentationEvent(
            id: outputID,
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
            authority: .conduitRecorded,
            kind: .agentOutput(
                AgentVisibleOutput(
                    promptEventID: promptID,
                    text: "bad authority",
                    state: .live,
                    extraction: .renderedBuffer,
                    truncated: false
                )
            )
        )
        XCTAssertEqual(
            ThreadUnseenOutput.project(
                taskSessionID: taskID,
                events: [bad],
                source: .retained(.completeRetainedTimeline),
                lastSeenRevision: nil
            ),
            .unavailable(.invalidEventAuthority)
        )
    }
}
