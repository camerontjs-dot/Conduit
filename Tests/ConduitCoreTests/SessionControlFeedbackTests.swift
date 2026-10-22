import XCTest
@testable import ConduitCore

final class SessionControlFeedbackTests: XCTestCase {
    func testInterleavedPromptsKeepTheirOwnDelayedFeedback() {
        // The API may use a caller-visible composer label. Presentation
        // ownership must still come from the actual API entry point.
        let hosted = SessionPresentation.promptEvent(
            origin: .composer, text: "hosted", attachmentPaths: [],
            renderedPayload: "hosted"
        )
        let human = SessionPresentation.promptEvent(
            text: "human", attachmentPaths: [], renderedPayload: "human"
        )
        var ledger = SessionControlFeedbackLedger()
        ledger.record(eventID: hosted.id, origin: .sessionAPI)
        ledger.record(eventID: human.id, origin: .operatorUI)

        let revisions = SessionPresentation.updatingPromptDelivery(
            in: [hosted, human], eventID: hosted.id, to: .failed
        )
        XCTAssertEqual(ledger.origin(for: revisions[0]), .sessionAPI)
        XCTAssertEqual(ledger.origin(for: revisions[1]), .operatorUI)
        // Output arriving after the other client sent a prompt follows the
        // referenced prompt, never the latest prompt or runtime creator.
        let hostedOutput = output(linkedTo: hosted.id)
        let humanOutput = output(linkedTo: human.id)
        XCTAssertEqual(ledger.origin(for: hostedOutput), .sessionAPI)
        XCTAssertEqual(ledger.origin(for: humanOutput), .operatorUI)
        XCTAssertFalse(ledger.origin(for: hostedOutput).updatesOperatorPresentation)
        XCTAssertTrue(ledger.origin(for: humanOutput).updatesOperatorPresentation)
    }

    func testOldAndUnlinkedEventsRemainUnattributed() {
        let old = SessionPresentation.promptEvent(
            text: "old history", attachmentPaths: [], renderedPayload: "old history"
        )
        let ledger = SessionControlFeedbackLedger()
        XCTAssertEqual(ledger.origin(for: old), .unattributed)
        XCTAssertEqual(ledger.origin(for: output(linkedTo: old.id)), .unattributed)
        XCTAssertEqual(ledger.origin(for: output(linkedTo: nil)), .unattributed)
        XCTAssertFalse(SessionControlOrigin.unattributed.updatesOperatorPresentation)
    }

    func testOpeningAndInterruptUseTheirOwnInitiatingAction() {
        let opening = SessionPresentation.openingEvent(
            .started(agentName: "Fixture", requestedBackend: "fixture")
        )
        let interruption = SessionPresentation.interruptRequestEvent()
        var ledger = SessionControlFeedbackLedger()
        ledger.record(eventID: opening.id, origin: .sessionAPI)
        ledger.record(eventID: interruption.id, origin: .operatorUI)
        XCTAssertEqual(ledger.origin(for: opening), .sessionAPI)
        XCTAssertEqual(ledger.origin(for: interruption), .operatorUI)
    }

    func testAnExistingEventCannotBeReassignedToAnotherFeedbackSink() {
        let prompt = SessionPresentation.promptEvent(
            origin: .phone, text: "one event", attachmentPaths: [],
            renderedPayload: "one event"
        )
        var ledger = SessionControlFeedbackLedger()
        ledger.record(eventID: prompt.id, origin: .sessionAPI)
        ledger.record(eventID: prompt.id, origin: .operatorUI)
        XCTAssertEqual(ledger.origin(for: prompt), .sessionAPI)
        XCTAssertEqual(ledger.origin(for: output(linkedTo: prompt.id)), .sessionAPI)
    }

    private func output(linkedTo promptID: UUID?) -> SessionPresentationEvent {
        SessionPresentation.agentOutputEvent(
            promptEventID: promptID, text: "observed output", state: .closed,
            extraction: .renderedBuffer, truncated: false
        )
    }
}
