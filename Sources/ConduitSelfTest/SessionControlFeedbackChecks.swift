import ConduitCore
import Foundation

func runSessionControlFeedbackChecks(_ check: (String, Bool) -> Void) {
    let hosted = SessionPresentation.promptEvent(
        origin: .composer, text: "hosted fixture", attachmentPaths: [],
        renderedPayload: "hosted fixture"
    )
    let human = SessionPresentation.promptEvent(
        text: "operator fixture", attachmentPaths: [], renderedPayload: "operator fixture"
    )
    var ledger = SessionControlFeedbackLedger()
    ledger.record(eventID: hosted.id, origin: .sessionAPI)
    ledger.record(eventID: human.id, origin: .operatorUI)
    let revised = SessionPresentation.updatingPromptDelivery(
        in: [hosted, human], eventID: hosted.id, to: .failed
    )
    check("late prompt feedback follows its actual client despite a composer label",
          ledger.origin(for: revised[0]) == .sessionAPI
            && ledger.origin(for: revised[1]) == .operatorUI)

    func output(_ promptID: UUID?) -> SessionPresentationEvent {
        SessionPresentation.agentOutputEvent(
            promptEventID: promptID, text: "fixture output", state: .closed,
            extraction: .renderedBuffer, truncated: false
        )
    }
    check("interleaved output feedback follows exact prompt IDs",
          ledger.origin(for: output(hosted.id)) == .sessionAPI
            && ledger.origin(for: output(human.id)) == .operatorUI)
    check("unlinked and historical output has no inferred operator presentation owner",
          ledger.origin(for: output(nil)) == .unattributed
            && ledger.origin(for: output(UUID())) == .unattributed
            && !SessionControlOrigin.unattributed.updatesOperatorPresentation)
    ledger.record(eventID: hosted.id, origin: .operatorUI)
    check("an existing hosted event cannot move to the operator feedback sink",
          ledger.origin(for: hosted) == .sessionAPI)

    let interruption = SessionPresentation.interruptRequestEvent()
    ledger.record(eventID: interruption.id, origin: .operatorUI)
    check("operator interrupt feedback remains operator owned in a shared runtime",
          ledger.origin(for: interruption).updatesOperatorPresentation
            && !ledger.origin(for: hosted).updatesOperatorPresentation)
}
