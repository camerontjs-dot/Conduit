import XCTest
@testable import ConduitCore

final class ConversationRetentionTests: XCTestCase {
    private let eventID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000001"
    )!

    func testLiveStructuredRevisionsStayPendingUntilOutputBoundary() {
        let live = SessionPresentation.agentOutputEvent(
            promptEventID: nil,
            text: "partial answer",
            state: .live,
            extraction: .structuredAdapter,
            truncated: false,
            id: eventID
        )
        let laterLive = SessionPresentation.agentOutputEvent(
            promptEventID: nil,
            text: "partial answer with another fragment",
            state: .live,
            extraction: .structuredAdapter,
            truncated: false,
            id: eventID
        )
        let closed = SessionPresentation.agentOutputEvent(
            promptEventID: nil,
            text: "partial answer with another fragment",
            state: .closed,
            extraction: .structuredAdapter,
            truncated: false,
            id: eventID
        )

        XCTAssertEqual(
            ConversationRetentionPolicy.stateAfterAppend(live),
            .pending
        )
        XCTAssertEqual(
            ConversationRetentionPolicy.stateAfterAppend(laterLive),
            .pending
        )
        XCTAssertEqual(
            ConversationRetentionPolicy.stateAfterAppend(closed),
            .persisted
        )
    }

    func testNonLivePresentationEventsPublishPersistedAndErrorsRemainVisible() {
        let prompt = SessionPresentation.promptEvent(
            text: "hello",
            attachmentPaths: [],
            renderedPayload: "hello"
        )

        XCTAssertEqual(
            ConversationRetentionPolicy.stateAfterAppend(prompt),
            .persisted
        )
        XCTAssertEqual(
            ConversationRetentionPolicy.stateAfterAppend(
                prompt,
                errorDescription: "disk full"
            ),
            .failed("disk full")
        )
    }

    func testEveryLiveRevisionRemainsInTheAppendOnlyConversationSource() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-retention-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let taskID = TaskSessionID()
        let log = ConversationEventLog(
            directory: directory,
            taskSessionID: taskID
        )
        let occurredAt = Date(timeIntervalSince1970: 1_800_000_000)
        let revisions = (0..<3).map { index in
            SessionPresentation.agentOutputEvent(
                promptEventID: nil,
                text: "fragment \(index)",
                state: .live,
                extraction: .structuredAdapter,
                truncated: false,
                id: eventID,
                occurredAt: occurredAt
            )
        }

        for revision in revisions {
            try log.append(revision)
        }

        let rawLines = try String(contentsOf: log.url, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
        XCTAssertEqual(rawLines.count, revisions.count)
        XCTAssertEqual(log.read().events.first?.id, eventID)
        XCTAssertEqual(log.read().events.first?.kind, revisions.last?.kind)
    }
}
