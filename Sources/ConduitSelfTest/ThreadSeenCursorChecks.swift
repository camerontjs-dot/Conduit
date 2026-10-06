import ConduitCore
import Foundation

func runThreadSeenCursorChecks(_ check: (String, Bool) -> Void) {
    let taskID = TaskSessionID(
        rawValue: UUID(uuidString: "71111111-1111-1111-1111-111111111111")!
    )
    let otherTaskID = TaskSessionID(
        rawValue: UUID(uuidString: "72222222-2222-2222-2222-222222222222")!
    )
    let promptID = UUID(uuidString: "73333333-3333-3333-3333-333333333333")!
    let outputID = UUID(uuidString: "74444444-4444-4444-4444-444444444444")!

    func identity(_ text: String) -> ThreadOutputRevisionIdentity? {
        let event = SessionPresentation.agentOutputEvent(
            promptEventID: promptID,
            text: text,
            extraction: .renderedBuffer,
            truncated: false,
            id: outputID,
            occurredAt: Date(timeIntervalSince1970: 1_800_200_000)
        )
        guard case .agentOutput(let output) = event.kind else { return nil }
        return ThreadUnseenOutput.revisionIdentity(event: event, output: output)
    }

    guard let first = identity("alpha"),
          let revised = identity("alpha beta")
    else {
        check("seen cursor fixture identities", false)
        return
    }

    let visible = ThreadSeenObservation(
        taskSessionID: taskID,
        surface: .conversation,
        applicationIsActive: true,
        windowIsKey: true,
        windowIsVisible: true,
        windowIsOcclusionVisible: true,
        visibleLatestRevision: revised
    )

    check(
        "seen cursor exact visible unseen revision advances",
        ThreadSeenCursor.decide(
            taskSessionID: taskID,
            unseenState: .unseen(revised),
            observation: visible
        ) == .advance(revised)
    )

    check(
        "seen cursor stale visible revision does not advance",
        ThreadSeenCursor.decide(
            taskSessionID: taskID,
            unseenState: .unseen(revised),
            observation: ThreadSeenObservation(
                taskSessionID: taskID,
                surface: .conversation,
                applicationIsActive: true,
                windowIsKey: true,
                windowIsVisible: true,
                visibleLatestRevision: first
            )
        ) == .unchanged
    )

    check(
        "seen cursor other task does not advance",
        ThreadSeenCursor.decide(
            taskSessionID: taskID,
            unseenState: .unseen(revised),
            observation: ThreadSeenObservation(
                taskSessionID: otherTaskID,
                surface: .conversation,
                applicationIsActive: true,
                windowIsKey: true,
                windowIsVisible: true,
                visibleLatestRevision: revised
            )
        ) == .unchanged
    )

    check(
        "seen cursor raw surface does not advance",
        ThreadSeenCursor.decide(
            taskSessionID: taskID,
            unseenState: .unseen(revised),
            observation: ThreadSeenObservation(
                taskSessionID: taskID,
                surface: .raw,
                applicationIsActive: true,
                windowIsKey: true,
                windowIsVisible: true,
                visibleLatestRevision: revised
            )
        ) == .unchanged
    )

    check(
        "seen cursor occluded window does not advance",
        ThreadSeenCursor.decide(
            taskSessionID: taskID,
            unseenState: .unseen(revised),
            observation: ThreadSeenObservation(
                taskSessionID: taskID,
                surface: .conversation,
                applicationIsActive: true,
                windowIsKey: true,
                windowIsVisible: true,
                windowIsOcclusionVisible: false,
                visibleLatestRevision: revised
            )
        ) == .unchanged
    )

    check(
        "seen cursor inactive app does not advance",
        ThreadSeenCursor.decide(
            taskSessionID: taskID,
            unseenState: .unseen(revised),
            observation: ThreadSeenObservation(
                taskSessionID: taskID,
                surface: .conversation,
                applicationIsActive: false,
                windowIsKey: true,
                windowIsVisible: true,
                visibleLatestRevision: revised
            )
        ) == .unchanged
    )

    check(
        "seen cursor unavailable source remains unavailable",
        ThreadSeenCursor.decide(
            taskSessionID: taskID,
            unseenState: .unavailable(.sourceHasDiagnostics),
            observation: visible
        ) == .unavailable(.sourceHasDiagnostics)
    )
}
