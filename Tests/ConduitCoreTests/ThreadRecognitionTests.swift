import Foundation
import XCTest
@testable import ConduitCore

final class ThreadRecognitionTests: XCTestCase {
    private let taskID = TaskSessionID(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)

    private func project(
        _ events: [SessionPresentationEvent],
        source: ThreadRecognitionSourceState = .retained(.completeRetainedTimeline),
        limit: Int = ThreadRecognition.defaultPreviewByteLimit
    ) -> ThreadRecognitionSnapshot {
        ThreadRecognition.project(
            taskSessionID: taskID, events: events, source: source, previewByteLimit: limit
        )
    }

    private func prompt(
        _ text: String = "Review the change",
        at: TimeInterval = 10,
        origin: PromptOrigin = .composer,
        delivery: PromptDeliveryState = .queued,
        attachments: [String] = []
    ) -> SessionPresentationEvent {
        SessionPresentationEvent(
            occurredAt: Date(timeIntervalSince1970: at),
            authority: .conduitRecorded,
            kind: .userPrompt(SubmittedPrompt(
                origin: origin, text: text, attachmentPaths: attachments,
                renderedPayload: text + " rendered attachment payload", delivery: delivery
            ))
        )
    }

    private func output(
        _ text: String = "Retained output",
        at: TimeInterval = 20,
        extraction: AgentOutputExtraction = .structuredAdapter,
        state: AgentOutputState = .live,
        truncated: Bool = false
    ) -> SessionPresentationEvent {
        SessionPresentation.agentOutputEvent(
            promptEventID: nil, text: text, state: state, extraction: extraction,
            truncated: truncated, occurredAt: Date(timeIntervalSince1970: at)
        )
    }

    func testPromptRetainsSubmissionOriginDeliveryAndOnlyPromptText() {
        let event = prompt("Exact prompt", origin: .chatgpt, delivery: .failed, attachments: ["fixture.txt"])
        let result = project([event])
        guard case .observed(let value) = result.latestPrompt else { return XCTFail("Missing prompt") }
        XCTAssertEqual(result.taskSessionID, taskID)
        XCTAssertEqual(value.event.eventID, event.id)
        XCTAssertEqual(value.event.occurredAt, event.occurredAt)
        XCTAssertEqual(value.event.authority, .conduitRecorded)
        XCTAssertEqual(value.origin, .chatgpt)
        XCTAssertEqual(value.delivery, .failed)
        XCTAssertEqual(value.attachmentCount, 1)
        XCTAssertEqual(value.preview.text, "Exact prompt")
        XCTAssertFalse(value.preview.wasClipped)
    }

    func testForwardedPromptDoesNotBecomeHumanActivity() {
        let event = prompt(origin: .forwardedTerminalOutput(sourceAgentName: "Fixture agent"))
        guard case .observed(let value) = project([event]).latestPrompt else { return XCTFail("Missing prompt") }
        XCTAssertEqual(value.origin, .forwardedTerminalOutput(sourceAgentName: "Fixture agent"))
    }

    func testOutputRetainsRawExtractionAndCaptureState() {
        let event = output(extraction: .tmuxPane, state: .closed, truncated: true)
        let result = project([event])
        guard case .observed(let value) = result.latestOutputBlock else { return XCTFail("Missing output") }
        XCTAssertEqual(value.event.occurredAt, event.occurredAt)
        XCTAssertEqual(value.event.authority, .derivedFromRaw)
        XCTAssertEqual(value.extraction, .tmuxPane)
        XCTAssertEqual(value.state, .closed)
        XCTAssertTrue(value.preview.sourceWasTruncated)
        XCTAssertFalse(value.preview.wasClipped)
        XCTAssertEqual(result.lastOutputUpdateAt, .unavailable(.notRetainedByInputContract))
    }

    func testStructuredOutputRetainsToolReportedAuthorityAndPromptLink() {
        let submitted = prompt()
        let event = SessionPresentation.agentOutputEvent(
            promptEventID: submitted.id, text: "Answer", extraction: .structuredAdapter, truncated: false
        )
        guard case .observed(let value) = project([submitted, event]).latestOutputBlock else {
            return XCTFail("Missing output")
        }
        XCTAssertEqual(value.promptEventID, submitted.id)
        XCTAssertEqual(value.event.authority, .toolReported)
    }

    func testRetainedOrderWinsOverClockRegressionAndBoundaryTime() {
        let first = prompt("Earlier in log", at: 90)
        let second = prompt("Later in log", at: 30)
        let visible = output(at: 20)
        let interrupt = SessionPresentation.interruptRequestEvent(occurredAt: Date(timeIntervalSince1970: 100))
        let result = project([first, second, visible, interrupt])
        guard case .observed(let value) = result.latestPrompt,
              case .observed(let conversation) = result.latestConversationEventOrigin else {
            return XCTFail("Missing retained facts")
        }
        XCTAssertEqual(value.event.eventID, second.id)
        XCTAssertEqual(conversation.eventID, visible.id)
        XCTAssertEqual(conversation.occurredAt, Date(timeIntervalSince1970: 20))
        XCTAssertEqual(result.retainedEventCount, 4)
    }

    func testEqualTimestampsKeepRetainedOrder() {
        let first = output("First", at: 50)
        let second = output("Second", at: 50)
        guard case .observed(let value) = project([first, second]).latestOutputBlock else {
            return XCTFail("Missing output")
        }
        XCTAssertEqual(value.event.eventID, second.id)
        XCTAssertEqual(value.preview.text, "Second")
    }

    func testOpeningAndInterruptAreNotConversationActivity() {
        let opened = SessionPresentation.openingEvent(.started(agentName: "Fixture", requestedBackend: "fixture"))
        let result = project([opened, SessionPresentation.interruptRequestEvent()])
        XCTAssertEqual(result.latestPrompt, .notObserved(.completeRetainedTimeline))
        XCTAssertEqual(result.latestOutputBlock, .notObserved(.completeRetainedTimeline))
        XCTAssertEqual(result.latestConversationEventOrigin, .notObserved(.completeRetainedTimeline))
    }

    func testEmptyAndWindowedSourcesKeepTheirDistinctCoverage() {
        XCTAssertEqual(project([]).latestPrompt, .notObserved(.completeRetainedTimeline))
        let result = project([output()], source: .retained(.boundedRetainedWindow))
        XCTAssertEqual(result.latestPrompt, .notObserved(.boundedRetainedWindow))
        XCTAssertEqual(result.source, .retained(.boundedRetainedWindow))
    }

    func testUnavailableSourceCannotExposeStaleSuppliedEvents() {
        let reasons: [ThreadRecognitionUnavailableReason] = [
            .sourceNotLoaded, .sourceMissing, .sourceUnreadable, .sourceHasDiagnostics
        ]
        for reason in reasons {
            let result = project([prompt(), output()], source: .unavailable(reason))
            XCTAssertEqual(result.retainedEventCount, 0)
            XCTAssertEqual(result.latestPrompt, .unavailable(reason))
            XCTAssertEqual(result.latestOutputBlock, .unavailable(reason))
            XCTAssertEqual(result.lastOutputUpdateAt, .unavailable(reason))
        }
    }

    func testDuplicateIdentityRefusesRawRevisionInput() {
        let first = output("First")
        let revision = SessionPresentation.agentOutputEvent(
            promptEventID: nil, text: "Changed", extraction: .structuredAdapter,
            truncated: false, id: first.id, occurredAt: first.occurredAt
        )
        for events in [[first, first], [first, revision]] {
            XCTAssertEqual(project(events).source, .unavailable(.duplicateEventIdentity))
        }
    }

    func testMismatchedAuthorityRefusesWholeProjection() {
        let submitted = prompt()
        let invalidPrompt = SessionPresentationEvent(
            id: submitted.id, occurredAt: submitted.occurredAt,
            authority: .verified, kind: submitted.kind
        )
        let raw = output(extraction: .renderedBuffer)
        let invalidRaw = SessionPresentationEvent(
            id: raw.id, occurredAt: raw.occurredAt, authority: .toolReported, kind: raw.kind
        )
        for event in [invalidPrompt, invalidRaw] {
            let result = project([prompt(), event])
            XCTAssertEqual(result.source, .unavailable(.invalidEventAuthority))
            XCTAssertEqual(result.latestPrompt, .unavailable(.invalidEventAuthority))
        }
    }

    func testNonfiniteEventTimeIsUnavailable() {
        XCTAssertEqual(project([prompt(at: .infinity)]).source, .unavailable(.invalidEventTime))
        XCTAssertEqual(project([prompt(at: .nan)]).source, .unavailable(.invalidEventTime))
    }

    func testPreviewBoundsUTF8WithoutSplittingGraphemesOrNormalizing() {
        let input = "Ae\u{301}👩🏽‍💻Z"
        guard case .observed(let value) = project([output(input)], limit: 4).latestOutputBlock else {
            return XCTFail("Missing output")
        }
        XCTAssertEqual(Array(value.preview.text.utf8), Array("Ae\u{301}".utf8))
        XCTAssertEqual(value.preview.text.utf8.count, 4)
        XCTAssertTrue(value.preview.wasClipped)
        XCTAssertFalse(value.preview.sourceWasTruncated)
    }

    func testOversizedFirstGraphemeProducesEmptyExplicitlyClippedPreview() {
        guard case .observed(let value) = project([output("👩🏽‍💻Z")], limit: 4).latestOutputBlock else {
            return XCTFail("Missing output")
        }
        XCTAssertEqual(value.preview.text, "")
        XCTAssertTrue(value.preview.wasClipped)
    }

    func testZeroLimitAndEmptyAttachmentOnlyPromptAreHonest() {
        guard case .observed(let clipped) = project([prompt("Text")], limit: 0).latestPrompt,
              case .observed(let empty) = project([prompt("", attachments: ["fixture.txt"])], limit: 0).latestPrompt else {
            return XCTFail("Missing prompt")
        }
        XCTAssertEqual(clipped.preview.text, "")
        XCTAssertTrue(clipped.preview.wasClipped)
        XCTAssertEqual(empty.preview.text, "")
        XCTAssertFalse(empty.preview.wasClipped)
        XCTAssertEqual(empty.attachmentCount, 1)
    }

    func testInvalidPreviewLimitIsExplicit() {
        for limit in [-1, ThreadRecognition.maximumPreviewByteLimit + 1, Int.max] {
            XCTAssertEqual(project([prompt()], limit: limit).source, .unavailable(.invalidPreviewByteLimit))
        }
    }

    func testReplayIsDeterministicAndDoesNotMutateInput() {
        let events = [prompt(), output()]
        let original = events
        let first = project(events)
        XCTAssertEqual(first, project(events))
        XCTAssertEqual(events, original)
        XCTAssertEqual(first.lastOutputUpdateAt, .unavailable(.notRetainedByInputContract))
    }
}
