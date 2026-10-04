import ConduitCore
import Foundation

func runThreadRecognitionSelfChecks(_ report: (String, Bool) -> Void) {
    let taskID = TaskSessionID(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    let submitted = SessionPresentation.promptEvent(
        origin: .chatgpt, text: "Prompt", attachmentPaths: ["fixture.txt"],
        renderedPayload: "Prompt plus attachment", occurredAt: Date(timeIntervalSince1970: 50)
    )
    let output = SessionPresentation.agentOutputEvent(
        promptEventID: submitted.id, text: "Ae\u{301}👩🏽‍💻Z", state: .closed,
        extraction: .tmuxPane, truncated: true, occurredAt: Date(timeIntervalSince1970: 20)
    )
    let boundary = SessionPresentation.interruptRequestEvent(occurredAt: Date(timeIntervalSince1970: 90))
    let events = [submitted, output, boundary]
    let result = ThreadRecognition.project(
        taskSessionID: taskID, events: events,
        source: .retained(.completeRetainedTimeline), previewByteLimit: 4
    )
    report("thread recognition preserves caller task identity", result.taskSessionID == taskID)
    if case .observed(let prompt) = result.latestPrompt {
        report("thread recognition retains prompt origin and attachments", prompt.origin == .chatgpt && prompt.attachmentCount == 1)
        report("thread recognition previews prompt text only", prompt.preview.text == "Prom" && prompt.preview.wasClipped)
    } else {
        report("thread recognition retains prompt origin and attachments", false)
        report("thread recognition previews prompt text only", false)
    }
    if case .observed(let visible) = result.latestOutputBlock {
        report("thread recognition retains raw authority and capture state", visible.event.authority == .derivedFromRaw && visible.state == .closed)
        report("thread recognition clips exact UTF8 at a grapheme boundary", Array(visible.preview.text.utf8) == Array("Ae\u{301}".utf8) && visible.preview.wasClipped && visible.preview.sourceWasTruncated)
    } else {
        report("thread recognition retains raw authority and capture state", false)
        report("thread recognition clips exact UTF8 at a grapheme boundary", false)
    }
    if case .observed(let latest) = result.latestConversationEventOrigin {
        report("thread recognition uses retained order and excludes boundaries", latest.eventID == output.id && latest.occurredAt == output.occurredAt)
    } else {
        report("thread recognition uses retained order and excludes boundaries", false)
    }
    report("thread recognition does not invent output update time", result.lastOutputUpdateAt == .unavailable(.notRetainedByInputContract))
    let empty = ThreadRecognition.project(
        taskSessionID: taskID, events: [], source: .retained(.boundedRetainedWindow)
    )
    report("thread recognition preserves bounded absence", empty.latestPrompt == .notObserved(.boundedRetainedWindow))
    let unavailable = ThreadRecognition.project(
        taskSessionID: taskID, events: events, source: .unavailable(.sourceHasDiagnostics)
    )
    report("thread recognition refuses stale data from unavailable source", unavailable.retainedEventCount == 0 && unavailable.latestPrompt == .unavailable(.sourceHasDiagnostics))
    let duplicate = ThreadRecognition.project(
        taskSessionID: taskID, events: [submitted, submitted], source: .retained(.completeRetainedTimeline)
    )
    report("thread recognition refuses raw duplicate revisions", duplicate.source == .unavailable(.duplicateEventIdentity))
    let forged = SessionPresentationEvent(
        id: output.id, occurredAt: output.occurredAt, authority: .verified, kind: output.kind
    )
    let invalid = ThreadRecognition.project(
        taskSessionID: taskID, events: [forged], source: .retained(.completeRetainedTimeline)
    )
    report("thread recognition refuses invalid authority", invalid.source == .unavailable(.invalidEventAuthority))
    let replay = ThreadRecognition.project(
        taskSessionID: taskID, events: events,
        source: .retained(.completeRetainedTimeline), previewByteLimit: 4
    )
    report("thread recognition projection replays deterministically", result == replay)
}
