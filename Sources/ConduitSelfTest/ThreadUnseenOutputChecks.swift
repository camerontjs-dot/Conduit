import ConduitCore
import Foundation

func runThreadUnseenOutputChecks(_ check: (String, Bool) -> Void) {
    let taskID = TaskSessionID(
        rawValue: UUID(uuidString: "51111111-1111-1111-1111-111111111111")!
    )
    let promptID = UUID(uuidString: "52222222-2222-2222-2222-222222222222")!
    let outputID = UUID(uuidString: "53333333-3333-3333-3333-333333333333")!

    func output(
        _ text: String,
        state: AgentOutputState = .live,
        truncated: Bool = false,
        id: UUID? = nil
    ) -> SessionPresentationEvent {
        SessionPresentation.agentOutputEvent(
            promptEventID: promptID,
            text: text,
            state: state,
            extraction: .renderedBuffer,
            truncated: truncated,
            id: id ?? outputID,
            occurredAt: Date(timeIntervalSince1970: 1_800_000_100)
        )
    }

    func identity(_ event: SessionPresentationEvent) -> ThreadOutputRevisionIdentity? {
        guard case .agentOutput(let visible) = event.kind else { return nil }
        return ThreadUnseenOutput.revisionIdentity(event: event, output: visible)
    }

    let first = output("alpha")
    guard let firstIdentity = identity(first) else {
        check("unseen output fixture identity", false)
        return
    }
    check(
        "unseen output first revision is unseen",
        ThreadUnseenOutput.project(
            taskSessionID: taskID,
            events: [first],
            source: .retained(.completeRetainedTimeline),
            lastSeenRevision: nil
        ) == .unseen(firstIdentity)
    )
    check(
        "unseen output exact revision is seen",
        ThreadUnseenOutput.project(
            taskSessionID: taskID,
            events: [first],
            source: .retained(.completeRetainedTimeline),
            lastSeenRevision: firstIdentity
        ) == .none
    )

    let revised = output("alpha beta")
    guard let revisedIdentity = identity(revised) else {
        check("unseen output revised fixture identity", false)
        return
    }
    check(
        "unseen output detects same-event text revision",
        revised.id == first.id
            && firstIdentity != revisedIdentity
            && ThreadUnseenOutput.project(
                taskSessionID: taskID,
                events: [revised],
                source: .retained(.boundedRetainedWindow),
                lastSeenRevision: firstIdentity
            ) == .unseen(revisedIdentity)
    )

    let closed = output("alpha", state: .closed)
    check(
        "unseen output ignores capture-state-only change",
        identity(closed) == firstIdentity
            && ThreadUnseenOutput.project(
                taskSessionID: taskID,
                events: [closed],
                source: .retained(.boundedRetainedWindow),
                lastSeenRevision: firstIdentity
            ) == .none
    )

    let truncated = output("alpha", truncated: true)
    check(
        "unseen output detects source shaping change",
        identity(truncated) != firstIdentity
    )
    check(
        "unseen output propagates unavailable source",
        ThreadUnseenOutput.project(
            taskSessionID: taskID,
            events: [],
            source: .unavailable(.sourceHasDiagnostics),
            lastSeenRevision: firstIdentity
        ) == .unavailable(.sourceHasDiagnostics)
    )
}
