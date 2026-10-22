import ConduitCore
import Foundation

func runConversationRevisionFeedChecks(_ check: (String, Bool) -> Void) {
    let taskID = TaskSessionID(
        rawValue: UUID(uuidString: "61111111-1111-1111-1111-111111111111")!
    )
    let promptID = UUID(uuidString: "62222222-2222-2222-2222-222222222222")!
    let outputID = UUID(uuidString: "63333333-3333-3333-3333-333333333333")!
    let stamp = Date(timeIntervalSince1970: 1_800_000_200)

    func prompt(_ delivery: PromptDeliveryState) -> SessionPresentationEvent {
        SessionPresentationEvent(
            id: promptID,
            occurredAt: stamp,
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

    func output(_ text: String, _ state: AgentOutputState) -> SessionPresentationEvent {
        SessionPresentation.agentOutputEvent(
            promptEventID: promptID,
            text: text,
            state: state,
            extraction: .structuredAdapter,
            truncated: false,
            id: outputID,
            occurredAt: stamp.addingTimeInterval(1)
        )
    }

    func feed(_ log: ConversationEventLog, since: String) -> ConduitSessionChangeFeed {
        let durable = log.readRevisions()
        return ConduitSessionEventExport.changeFeed(
            source: ConduitSessionEventSource(
                taskSessionID: taskID.rawValue.uuidString,
                backend: .appServer,
                sessionLifecycle: "running",
                runtimeState: "ready",
                live: false,
                ready: true,
                events: durable.events,
                durableRevisions: durable
            ),
            since: since,
            limit: nil
        )
    }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("conduit-selftest-revision-feed-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let log = ConversationEventLog(
        directory: root.appendingPathComponent("history"),
        taskSessionID: taskID
    )

    let missing = feed(log, since: "")
    check(
        "revision feed reports a missing log as missing, not empty",
        missing.state == .ok && missing.coverage == .missing
            && missing.nextChangeCursor == ConversationRevisionCursor.origin.encoded
    )

    do {
        try log.append(prompt(.queued))
        try log.append(output("Hel", .live))
    } catch {
        check("revision feed fixture appends", false)
        return
    }
    let first = feed(log, since: missing.nextChangeCursor ?? "")
    guard let cursor = first.nextChangeCursor else {
        check("revision feed issues a next cursor", false)
        return
    }

    do {
        try log.append(prompt(.delivered))
        try log.append(output("Hello", .closed))
    } catch {
        check("revision feed fixture revisions append", false)
        return
    }
    let second = feed(log, since: cursor)
    check(
        "revision feed delivers revisions of events behind the timeline cursor",
        second.records.map(\.event.state) == ["delivered", "closed"]
            && second.records.map(\.timelineCursor) == ["v1:0", "v1:1"]
            && second.records.map(\.eventRevision) == [2, 2]
    )

    let invalid = feed(log, since: "v1:2")
    check(
        "revision feed refuses a non-revision cursor without restarting",
        invalid.state == .invalid && invalid.records.isEmpty && invalid.nextChangeCursor == nil
    )

    let foreign = ConversationRevisionCursor(
        sequence: 1,
        byteOffset: 1,
        prefixSHA256: String(repeating: "0", count: 64)
    )
    check(
        "revision feed requires reconciliation for a mismatched prefix",
        feed(log, since: foreign.encoded).state == .reconcileRequired
    )

    var replica = ConduitSessionChangeReplica()
    let stale = feed(log, since: "")
    let fresh = feed(log, since: "")
    _ = replica.apply(fresh)
    let afterFresh = replica.cursor
    check(
        "revision replica rejects a page read from an older cursor and keeps its cursor",
        replica.apply(stale) == .staleSince(expected: afterFresh, received: "")
            && replica.cursor == afterFresh
            && afterFresh == fresh.nextChangeCursor
    )

    let text = String(repeating: "e\u{301}👨‍👩‍👧‍👦漢 ", count: 800)
    let long = SessionPresentation.agentOutputEvent(
        promptEventID: nil,
        text: text,
        state: .closed,
        extraction: .structuredAdapter,
        truncated: false,
        id: outputID,
        occurredAt: stamp
    )
    let source = ConduitSessionEventSource(
        taskSessionID: taskID.rawValue.uuidString,
        backend: .appServer,
        sessionLifecycle: "closed",
        runtimeState: "closed",
        live: false,
        ready: false,
        events: [long]
    )
    let record = ConduitSessionEventExport.page(source: source).events.first
    var assembled = ""
    var offset: Int? = 0
    var digestsMatch = true
    while let current = offset {
        let slice = ConduitSessionEventExport.expand(
            source: source,
            eventID: outputID.uuidString,
            offset: current,
            limit: 1_000
        )
        guard slice.state == .ok else { break }
        assembled += slice.text ?? ""
        digestsMatch = digestsMatch && slice.fullTextSHA256 == record?.fullTextSHA256
        offset = slice.nextOffset
    }
    check(
        "capped Unicode text expands exactly and matches the page digest",
        record?.textCapped == true && record?.sourceTruncated == false
            && assembled == text && digestsMatch
    )

    // Nine keys need nine changing passes; past the eight-pass bound the
    // text is withheld from every export path rather than partly redacted.
    let chained = String(repeating: "word ", count: 420)
        + Array(repeating: "xai-abcdefgh", count: 9).joined(separator: "\u{301}")
    let unsettledSource = ConduitSessionEventSource(
        taskSessionID: taskID.rawValue.uuidString,
        backend: .appServer,
        sessionLifecycle: "closed",
        runtimeState: "closed",
        live: false,
        ready: false,
        events: [
            SessionPresentation.agentOutputEvent(
                promptEventID: nil,
                text: chained,
                state: .closed,
                extraction: .structuredAdapter,
                truncated: false,
                id: outputID,
                occurredAt: stamp
            ),
        ]
    )
    let unsettledRecord = ConduitSessionEventExport.page(source: unsettledSource).events.first
    let unsettledExpansion = ConduitSessionEventExport.expand(
        source: unsettledSource,
        eventID: outputID.uuidString,
        offset: 0,
        limit: 32_000
    )
    check(
        "redaction that does not settle within its bound withholds the text",
        unsettledExpansion.text == ConduitSessionEventExport.unsettledRedactionText
            && unsettledRecord?.text == unsettledExpansion.text
            && unsettledRecord?.redacted == true && unsettledExpansion.redacted
    )
}
