import XCTest
@testable import ConduitCore

final class ThreadSeenCursorTests: XCTestCase {
    private let taskID = TaskSessionID(
        rawValue: UUID(uuidString: "61111111-1111-1111-1111-111111111111")!
    )
    private let otherTaskID = TaskSessionID(
        rawValue: UUID(uuidString: "62222222-2222-2222-2222-222222222222")!
    )
    private let promptID = UUID(uuidString: "63333333-3333-3333-3333-333333333333")!
    private let outputID = UUID(uuidString: "64444444-4444-4444-4444-444444444444")!

    private func identity(_ text: String = "alpha") -> ThreadOutputRevisionIdentity {
        let event = SessionPresentation.agentOutputEvent(
            promptEventID: promptID,
            text: text,
            extraction: .renderedBuffer,
            truncated: false,
            id: outputID,
            occurredAt: Date(timeIntervalSince1970: 1_800_100_000)
        )
        guard case .agentOutput(let output) = event.kind else {
            fatalError("fixture is not output")
        }
        return ThreadUnseenOutput.revisionIdentity(event: event, output: output)
    }

    private func observation(
        taskSessionID: TaskSessionID? = nil,
        surface: SessionSurface = .conversation,
        applicationIsActive: Bool = true,
        windowIsKey: Bool = true,
        windowIsVisible: Bool = true,
        windowIsOcclusionVisible: Bool = true,
        visibleLatestRevision: ThreadOutputRevisionIdentity? = nil
    ) -> ThreadSeenObservation {
        ThreadSeenObservation(
            taskSessionID: taskSessionID ?? taskID,
            surface: surface,
            applicationIsActive: applicationIsActive,
            windowIsKey: windowIsKey,
            windowIsVisible: windowIsVisible,
            windowIsOcclusionVisible: windowIsOcclusionVisible,
            visibleLatestRevision: visibleLatestRevision ?? identity()
        )
    }

    func testNoUnseenRevisionDoesNotAdvance() {
        XCTAssertEqual(
            ThreadSeenCursor.decide(
                taskSessionID: taskID,
                unseenState: .none,
                observation: observation()
            ),
            .unchanged
        )
    }

    func testUnavailableSourcePropagates() {
        XCTAssertEqual(
            ThreadSeenCursor.decide(
                taskSessionID: taskID,
                unseenState: .unavailable(.sourceHasDiagnostics),
                observation: observation()
            ),
            .unavailable(.sourceHasDiagnostics)
        )
    }

    func testMissingObservationDoesNotAdvance() {
        XCTAssertEqual(
            ThreadSeenCursor.decide(
                taskSessionID: taskID,
                unseenState: .unseen(identity()),
                observation: nil
            ),
            .unchanged
        )
    }

    func testDifferentTaskDoesNotAdvance() {
        XCTAssertEqual(
            ThreadSeenCursor.decide(
                taskSessionID: taskID,
                unseenState: .unseen(identity()),
                observation: observation(taskSessionID: otherTaskID)
            ),
            .unchanged
        )
    }

    func testRawSurfaceDoesNotAdvance() {
        XCTAssertEqual(
            ThreadSeenCursor.decide(
                taskSessionID: taskID,
                unseenState: .unseen(identity()),
                observation: observation(surface: .raw)
            ),
            .unchanged
        )
    }

    func testInactiveApplicationDoesNotAdvance() {
        XCTAssertEqual(
            ThreadSeenCursor.decide(
                taskSessionID: taskID,
                unseenState: .unseen(identity()),
                observation: observation(applicationIsActive: false)
            ),
            .unchanged
        )
    }

    func testNonKeyWindowDoesNotAdvance() {
        XCTAssertEqual(
            ThreadSeenCursor.decide(
                taskSessionID: taskID,
                unseenState: .unseen(identity()),
                observation: observation(windowIsKey: false)
            ),
            .unchanged
        )
    }

    func testHiddenWindowDoesNotAdvance() {
        XCTAssertEqual(
            ThreadSeenCursor.decide(
                taskSessionID: taskID,
                unseenState: .unseen(identity()),
                observation: observation(windowIsVisible: false)
            ),
            .unchanged
        )
    }

    func testOccludedWindowDoesNotAdvance() {
        XCTAssertEqual(
            ThreadSeenCursor.decide(
                taskSessionID: taskID,
                unseenState: .unseen(identity()),
                observation: observation(windowIsOcclusionVisible: false)
            ),
            .unchanged
        )
    }

    func testMissingLatestVisibleRevisionDoesNotAdvance() {
        let receipt = ThreadSeenObservation(
            taskSessionID: taskID,
            surface: .conversation,
            applicationIsActive: true,
            windowIsKey: true,
            windowIsVisible: true,
            windowIsOcclusionVisible: true,
            visibleLatestRevision: nil
        )
        XCTAssertEqual(
            ThreadSeenCursor.decide(
                taskSessionID: taskID,
                unseenState: .unseen(identity()),
                observation: receipt
            ),
            .unchanged
        )
    }

    func testDifferentVisibleRevisionDoesNotAdvance() {
        XCTAssertEqual(
            ThreadSeenCursor.decide(
                taskSessionID: taskID,
                unseenState: .unseen(identity("alpha beta")),
                observation: observation(visibleLatestRevision: identity("alpha"))
            ),
            .unchanged
        )
    }

    func testExactVisibleUnseenRevisionAdvances() {
        let unseen = identity("alpha beta")
        XCTAssertEqual(
            ThreadSeenCursor.decide(
                taskSessionID: taskID,
                unseenState: .unseen(unseen),
                observation: observation(visibleLatestRevision: unseen)
            ),
            .advance(unseen)
        )
    }
}
