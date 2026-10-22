import Foundation
import XCTest
@testable import ConduitCore

/// The read service runs without AppKit against a fake owner. These tests pin
/// its ordering and source selection, which previously lived only in the app
/// target and had no direct test.
final class ConduitSessionReadServiceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let task = TaskSessionID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
    )
    private let promptID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
    private let outputID = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!

    func testWriteBetweenDurableReadAndTimelineIsRedeliveredNotSkipped() throws {
        try withOwner { owner in
            try owner.log.append(prompt(.delivered))
            try owner.log.append(output("par", .live))
            // The runtime's in-memory timeline is captured, then a write lands
            // before the read finishes. Reading the log after the timeline
            // would bind a head cursor past a revision the timeline lacks.
            owner.liveEvents = [prompt(.delivered), output("par", .live)]
            owner.afterLiveTimeline = {
                try? owner.log.append(self.output("partial", .live))
            }

            let page = try read(owner, options: ConduitSessionEventReadOptions(changesSince: ""))
            XCTAssertEqual(page.timelineSource?.kind, .liveRuntime)
            XCTAssertEqual(page.events.last?.text, "par")
            let head = try XCTUnwrap(page.changes?.headChangeCursor)

            owner.afterLiveTimeline = nil
            let catchUp = try read(owner, options: ConduitSessionEventReadOptions(changesSince: head))
            XCTAssertEqual(catchUp.changes?.records.map(\.event.text), ["partial"])
        }
    }

    func testDurableLogIsReadBeforeTimelineSelection() throws {
        try withOwner { owner in
            owner.liveEvents = []
            _ = try read(owner, options: ConduitSessionEventReadOptions(changesSince: ""))
            let logIndex = try XCTUnwrap(owner.calls.firstIndex(of: "log"))
            let liveIndex = try XCTUnwrap(owner.calls.firstIndex(of: "live"))
            XCTAssertLessThan(logIndex, liveIndex)
        }
    }

    func testTimelineSourceSelectionAndCoverage() throws {
        try withOwner { owner in
            try owner.log.append(prompt(.queued))

            owner.liveEvents = [prompt(.delivered)]
            XCTAssertEqual(try read(owner).timelineSource?.kind, .liveRuntime)
            XCTAssertNil(try read(owner).timelineSource?.durableCoverage)

            owner.liveEvents = nil
            owner.cachedEvents = [prompt(.queued)]
            XCTAssertEqual(try read(owner).timelineSource?.kind, .cachedHistory)
            XCTAssertNil(try read(owner).timelineSource?.durableCoverage)

            owner.cachedEvents = []
            let durable = try read(owner)
            XCTAssertEqual(durable.timelineSource?.kind, .durableLog)
            XCTAssertEqual(durable.timelineSource?.durableCoverage, .complete)
            XCTAssertEqual(durable.events.map(\.state), ["queued"])
        }
    }

    func testStaleCachedHistoryIsNotServedWithAHeadCursor() throws {
        try withOwner { owner in
            try owner.log.append(prompt(.delivered))
            try owner.log.append(output("done", .closed))
            // The app's cached copy was loaded before the runtime wrote the
            // output, and the exited runtime is no longer reported live.
            owner.liveEvents = nil
            owner.cachedEvents = [prompt(.delivered)]

            let page = try read(owner, options: ConduitSessionEventReadOptions(changesSince: ""))
            XCTAssertEqual(page.timelineSource?.kind, .durableLog)
            XCTAssertEqual(page.events.map(\.eventID), [promptID, outputID].map(\.uuidString))
            let head = try XCTUnwrap(page.changes?.headChangeCursor)
            // Nothing written after the head; the timeline already holds it all.
            let catchUp = try read(owner, options: ConduitSessionEventReadOptions(changesSince: head))
            XCTAssertEqual(catchUp.changes?.records.count, 0)
            XCTAssertFalse(owner.calls.contains("cached"))
        }
    }

    func testMissingLogIsReportedAsMissingThroughTheService() throws {
        try withOwner { owner in
            owner.liveEvents = nil
            owner.cachedEvents = nil
            let page = try read(owner, options: ConduitSessionEventReadOptions(changesSince: ""))
            XCTAssertEqual(page.timelineSource?.kind, .durableLog)
            XCTAssertEqual(page.timelineSource?.durableCoverage, .missing)
            XCTAssertEqual(page.changes?.coverage, .missing)
            XCTAssertTrue(page.events.isEmpty)
        }
    }

    func testInMemoryTimelineWithoutChangeFeedDoesNotReadTheLog() throws {
        try withOwner { owner in
            owner.liveEvents = [prompt(.delivered)]
            _ = try read(owner)
            owner.liveEvents = nil
            owner.cachedEvents = [prompt(.delivered)]
            _ = try read(owner)
            XCTAssertFalse(owner.calls.contains("log"))
        }
    }

    func testUnknownTaskTouchesNoTaskState() throws {
        try withOwner { owner in
            owner.knownTask = false
            let missing = ConduitSessionReadService.events(
                owner: owner,
                taskSessionID: task.rawValue.uuidString,
                cursor: nil,
                limit: nil,
                options: ConduitSessionEventReadOptions(changesSince: "", expandEventID: promptID.uuidString)
            )
            XCTAssertEqual(missing.failure, .unknownTask)
            XCTAssertEqual(owner.calls, ["observe"])

            let malformed = ConduitSessionReadService.events(
                owner: owner, taskSessionID: "not-a-uuid", cursor: nil, limit: nil
            )
            XCTAssertEqual(malformed.failure, .unknownTask)
        }
    }

    func testObservationFieldsPassThroughUnchanged() throws {
        try withOwner { owner in
            let attempt = RuntimeAttemptID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!)
            owner.observationValue = ConduitSessionTaskObservation(
                backend: .appServer,
                lifecycle: "running",
                runtimeState: "ready",
                live: true,
                ready: true,
                adapter: ConduitSessionAdapterSnapshot(threadID: "thr_1", turnActive: true),
                runtimeAttemptID: attempt,
                persistedThreadID: nil
            )
            owner.liveEvents = [prompt(.delivered)]
            let page = try read(owner)
            XCTAssertEqual(page.backend, AgentSessionBackend.appServer.workSessionLabel)
            XCTAssertEqual(page.session.lifecycle, "running")
            XCTAssertEqual(page.runtimeAttemptID, attempt)
            XCTAssertEqual(page.turn.threadID, "thr_1")
            XCTAssertEqual(page.turn.threadIDSource, .live)
            XCTAssertEqual(page.taskSessionID, task.rawValue.uuidString)
        }
    }

    // MARK: Helpers

    private func read(
        _ owner: FakeOwner,
        options: ConduitSessionEventReadOptions = .none
    ) throws -> ConduitSessionEventPage {
        try ConduitSessionReadService.events(
            owner: owner,
            taskSessionID: task.rawValue.uuidString,
            cursor: nil,
            limit: nil,
            options: options,
            observedAt: t0
        ).get()
    }

    private func prompt(_ delivery: PromptDeliveryState) -> SessionPresentationEvent {
        SessionPresentationEvent(
            id: promptID,
            occurredAt: t0,
            authority: .conduitRecorded,
            kind: .userPrompt(
                SubmittedPrompt(
                    origin: .chatgpt,
                    text: "go",
                    attachmentPaths: [],
                    renderedPayload: "go",
                    delivery: delivery
                )
            )
        )
    }

    private func output(_ text: String, _ state: AgentOutputState) -> SessionPresentationEvent {
        SessionPresentation.agentOutputEvent(
            promptEventID: promptID,
            text: text,
            state: state,
            extraction: .structuredAdapter,
            truncated: false,
            id: outputID,
            occurredAt: t0.addingTimeInterval(1)
        )
    }

    private func withOwner(_ body: (FakeOwner) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-read-service-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(
            FakeOwner(
                task: task,
                log: ConversationEventLog(
                    directory: directory.appendingPathComponent("history"),
                    taskSessionID: task
                )
            )
        )
    }
}

private final class FakeOwner: ConduitSessionReadOwner {
    let task: TaskSessionID
    let log: ConversationEventLog
    var knownTask = true
    var observationValue = ConduitSessionTaskObservation(
        backend: .appServer,
        lifecycle: "running",
        runtimeState: "ready",
        live: true,
        ready: true
    )
    var liveEvents: [SessionPresentationEvent]?
    var cachedEvents: [SessionPresentationEvent]?
    var afterLiveTimeline: (() -> Void)?
    private(set) var calls: [String] = []

    init(task: TaskSessionID, log: ConversationEventLog) {
        self.task = task
        self.log = log
    }

    func observation(of task: TaskSessionID) -> ConduitSessionTaskObservation? {
        calls.append("observe")
        return knownTask && task == self.task ? observationValue : nil
    }

    func liveTimeline(of task: TaskSessionID) -> [SessionPresentationEvent]? {
        calls.append("live")
        let captured = liveEvents
        afterLiveTimeline?()
        return captured
    }

    func cachedTimeline(of task: TaskSessionID) -> [SessionPresentationEvent]? {
        calls.append("cached")
        return cachedEvents
    }

    func conversationLog(of task: TaskSessionID) -> ConversationEventLog {
        calls.append("log")
        return log
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
