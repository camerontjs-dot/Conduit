import Foundation
import XCTest
@testable import ConduitCore

/// Producer/consumer contract for the durable change feed. Each test names
/// the failure the feed must not allow: a revision behind the reader's
/// position going unseen, a source state being misreported, a mismatched
/// cursor restarting silently, or an obsolete reader overwriting newer state.
final class ConversationRevisionFeedTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let taskID = TaskSessionID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    )
    private let promptID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
    private let outputID = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
    private let laterID = UUID(uuidString: "00000000-0000-0000-0000-000000000030")!

    // MARK: Late revisions

    func testRevisionOfEarlierEventBehindTimelineCursorReachesChangeFeed() throws {
        try withLog { log in
            let queued = prompt(promptID, "go", .queued)
            let live = output(outputID, "Hel", .live)
            try log.append(queued)
            try log.append(live)

            let first = changes(log, since: "")
            XCTAssertEqual(first.state, .ok)
            XCTAssertEqual(first.records.map(\.event.eventID), [promptID, outputID].map(\.uuidString))
            let cursor = try XCTUnwrap(first.nextChangeCursor)

            // A v1 reader that consumed both events sees nothing new after the
            // revisions below; that is the documented presentation contract.
            try log.append(prompt(promptID, "go", .delivered))
            try log.append(output(outputID, "Hello", .closed))
            let timeline = ConduitSessionEventExport.page(
                source: source(log), cursor: "v1:2"
            )
            XCTAssertTrue(timeline.events.isEmpty)

            let second = changes(log, since: cursor)
            XCTAssertEqual(second.state, .ok)
            XCTAssertEqual(second.records.map(\.event.eventID), [promptID, outputID].map(\.uuidString))
            XCTAssertEqual(second.records.map(\.timelineCursor), ["v1:0", "v1:1"])
            XCTAssertEqual(second.records.map(\.event.state), ["delivered", "closed"])
            XCTAssertEqual(second.records.map(\.eventRevision), [2, 2])
            XCTAssertEqual(second.records.map(\.revisionSequence), [3, 4])
            XCTAssertEqual(second.records.map(\.firstSeenInPage), [false, false])
            XCTAssertFalse(second.hasMoreChanges)

            let idle = changes(log, since: try XCTUnwrap(second.nextChangeCursor))
            XCTAssertEqual(idle.state, .ok)
            XCTAssertTrue(idle.records.isEmpty)
            XCTAssertEqual(idle.nextChangeCursor, second.nextChangeCursor)
        }
    }

    func testStreamedDeltaRevisionsCoalesceToOneRecordWithoutCorruptionLabel() throws {
        try withLog { log in
            var previous = output(outputID, "a", .live)
            try log.append(previous)
            for text in ["ab", "abc", "abcd"] {
                let next = output(outputID, text, .live)
                try log.appendBatch([
                    ConversationEventLogAppendRevision(event: next, previousEvent: previous)
                ])
                previous = next
            }
            try log.append(output(outputID, "abcd!", .closed))

            let feed = changes(log, since: "")
            XCTAssertEqual(feed.records.count, 1)
            XCTAssertEqual(feed.records.first?.event.text, "abcd!")
            XCTAssertEqual(feed.records.first?.eventRevision, 5)
            XCTAssertEqual(feed.records.first?.firstSeenInPage, true)
            XCTAssertEqual(feed.coverage, .complete)
            XCTAssertEqual(feed.rejectedRecordsInPage, 0)
            XCTAssertEqual(feed.appliedRevisionCount, 5)
        }
    }

    // MARK: Pagination, catch-up and convergence

    func testBudgetPagesCarryLatestValuesAndConvergeOnProjection() throws {
        try withLog { log in
            try log.append(prompt(promptID, "one", .queued))
            try log.append(output(outputID, "partial", .live))
            try log.append(prompt(promptID, "one", .delivered))
            try log.append(prompt(laterID, "two", .queued))
            try log.append(output(outputID, "partial done", .closed))

            var replica = ConduitSessionChangeReplica()
            let page1 = changes(log, since: replica.cursor, limit: 2)
            XCTAssertTrue(page1.hasMoreChanges)
            // Page 1 consumes revisions 1-3 and stops before the third event.
            // Its records carry each event's latest value, so the output is
            // already "partial done" (revision 5), ahead of the page cursor.
            XCTAssertEqual(page1.records.map(\.event.eventID), [promptID, outputID].map(\.uuidString))
            XCTAssertEqual(page1.records.map(\.revisionSequence), [3, 5])
            XCTAssertEqual(page1.records.last?.event.text, "partial done")
            XCTAssertEqual(replica.apply(page1), .applied(records: 2))

            // Page 2 consumes revisions 4-5 and repeats revision 5.
            let page2 = changes(log, since: replica.cursor, limit: 2)
            XCTAssertFalse(page2.hasMoreChanges)
            XCTAssertEqual(page2.records.map(\.event.eventID), [laterID, outputID].map(\.uuidString))
            XCTAssertEqual(page2.records.map(\.revisionSequence), [4, 5])
            XCTAssertEqual(replica.apply(page2), .applied(records: 2))

            let projection = log.read().events
            XCTAssertEqual(replica.timeline.map(\.event.eventID), projection.map(\.id.uuidString))
            XCTAssertEqual(replica.timeline.map(\.event.text), ["one", "partial done", "two"])
        }
    }

    func testAppendDuringCatchUpIsDeliveredAndRevisionOfDeliveredEventIsNotLost() throws {
        try withLog { log in
            try log.append(prompt(promptID, "go", .queued))
            try log.append(output(outputID, "x", .live))

            var replica = ConduitSessionChangeReplica()
            let page1 = changes(log, since: "", limit: 1)
            XCTAssertEqual(replica.apply(page1), .applied(records: 1))

            // Writer races the reader: revises the delivered prompt and adds
            // a new event before the reader asks for its next page.
            try log.append(prompt(promptID, "go", .delivered))
            try log.append(prompt(laterID, "next", .queued))

            while true {
                let page = changes(log, since: replica.cursor, limit: 1)
                XCTAssertEqual(page.state, .ok)
                guard case .applied = replica.apply(page) else {
                    return XCTFail("page not applicable")
                }
                if !page.hasMoreChanges { break }
            }
            XCTAssertEqual(
                replica.timeline.map(\.event.state),
                ["delivered", "live", "queued"]
            )
            XCTAssertEqual(replica.timeline.map(\.event.eventID), log.read().events.map(\.id.uuidString))
        }
    }

    func testLiveTimelineWithEarlierHeadCursorOverlapsInsteadOfLosingChanges() throws {
        try withLog { log in
            try log.append(prompt(promptID, "go", .delivered))
            try log.append(output(outputID, "par", .live))
            // The durable read happens before the timeline is chosen. The live
            // runtime is already ahead of what was persisted.
            let durable = log.readRevisions()
            let liveEvents = [prompt(promptID, "go", .delivered), output(outputID, "partial", .live)]
            let page = ConduitSessionEventExport.page(
                source: source(events: liveEvents, durable: durable, kind: .liveRuntime),
                options: ConduitSessionEventReadOptions(changesSince: "")
            )
            XCTAssertEqual(page.events.last?.text, "partial")
            let head = try XCTUnwrap(page.changes?.headChangeCursor)

            // The live revision persists afterwards; catching up from the head
            // returns it again rather than skipping it.
            try log.append(output(outputID, "partial", .live))
            let catchUp = changes(log, since: head)
            XCTAssertEqual(catchUp.records.map(\.event.text), ["partial"])
            XCTAssertEqual(page.timelineSource?.kind, .liveRuntime)
            XCTAssertEqual(page.timelineSource?.durableCoverage, .complete)
        }
    }

    // MARK: Obsolete and cancelled readers

    func testObsoletePageCannotOverwriteSuccessorStateOrMoveCursor() throws {
        try withLog { log in
            try log.append(output(outputID, "v1", .live))
            var replica = ConduitSessionChangeReplica()
            let stale = changes(log, since: "")
            try log.append(output(outputID, "v2", .closed))
            let fresh = changes(log, since: "")

            XCTAssertEqual(replica.apply(fresh), .applied(records: 1))
            let cursorAfterFresh = replica.cursor
            XCTAssertEqual(
                replica.apply(stale),
                .staleSince(expected: cursorAfterFresh, received: "")
            )
            XCTAssertEqual(replica.cursor, cursorAfterFresh)
            XCTAssertEqual(replica.timeline.first?.event.text, "v2")
        }
    }

    func testRefusedPageLeavesReplicaCursorWhereItWas() throws {
        try withLog { log in
            try log.append(output(outputID, "v1", .live))
            var replica = ConduitSessionChangeReplica(cursor: "r1:9:9:" + String(repeating: "0", count: 64))
            let refused = changes(log, since: replica.cursor)
            XCTAssertEqual(refused.state, .reconcileRequired)
            XCTAssertNil(refused.nextChangeCursor)
            XCTAssertEqual(replica.apply(refused), .notApplicable(.reconcileRequired))
            XCTAssertEqual(replica.cursor, "r1:9:9:" + String(repeating: "0", count: 64))
        }
    }

    // MARK: Source coverage

    func testMissingEmptyUnreadableAndPartialSourcesStayDistinct() throws {
        try withTemporaryDirectory { root in
            let missing = ConversationEventLog(
                directory: root.appendingPathComponent("absent"),
                taskSessionID: taskID
            )
            let missingRead = missing.readRevisions()
            XCTAssertEqual(missingRead.coverage, .missing)
            XCTAssertEqual(missing.read(), ConversationEventLogReadResult(events: [], diagnostics: []))
            let missingFeed = changes(missing, since: "")
            XCTAssertEqual(missingFeed.state, .ok)
            XCTAssertEqual(missingFeed.coverage, .missing)
            XCTAssertEqual(missingFeed.nextChangeCursor, ConversationRevisionCursor.origin.encoded)

            let emptyDirectory = root.appendingPathComponent("empty")
            let empty = ConversationEventLog(directory: emptyDirectory, taskSessionID: taskID)
            try FileManager.default.createDirectory(at: emptyDirectory, withIntermediateDirectories: true)
            XCTAssertTrue(FileManager.default.createFile(atPath: empty.url.path, contents: Data()))
            XCTAssertEqual(empty.readRevisions().coverage, .empty)
            XCTAssertEqual(changes(empty, since: "").coverage, .empty)

            let unreadableDirectory = root.appendingPathComponent("unreadable")
            let unreadable = ConversationEventLog(directory: unreadableDirectory, taskSessionID: taskID)
            try FileManager.default.createDirectory(at: unreadable.url, withIntermediateDirectories: true)
            XCTAssertEqual(unreadable.readRevisions().coverage, .unreadable)
            let unreadableFeed = changes(unreadable, since: "")
            XCTAssertEqual(unreadableFeed.state, .unavailable)
            XCTAssertNil(unreadableFeed.nextChangeCursor)

            let partialDirectory = root.appendingPathComponent("partial")
            let partial = ConversationEventLog(directory: partialDirectory, taskSessionID: taskID)
            try partial.append(prompt(promptID, "kept", .queued))
            try appendRaw(Data("{not json\n".utf8), to: partial.url)
            try partial.append(output(outputID, "after", .live))
            let partialRead = partial.readRevisions()
            XCTAssertEqual(partialRead.coverage, .partial)
            XCTAssertEqual(partialRead.events.count, 2)
            let partialFeed = changes(partial, since: "")
            XCTAssertEqual(partialFeed.records.count, 2)
            XCTAssertEqual(partialFeed.rejectedRecordsInPage, 1)
            XCTAssertEqual(partialFeed.rejectedKindsInPage, ["malformedLine"])
            // Reported once: the next poll covers no new bytes.
            let next = changes(partial, since: try XCTUnwrap(partialFeed.nextChangeCursor))
            XCTAssertEqual(next.rejectedRecordsInPage, 0)
            XCTAssertEqual(next.coverage, .partial)
        }
    }

    func testMissingSourceCursorFollowsLogOnceItAppears() throws {
        try withLog { log in
            let before = changes(log, since: "")
            XCTAssertEqual(before.coverage, .missing)
            try log.append(prompt(promptID, "first", .queued))
            let after = changes(log, since: try XCTUnwrap(before.nextChangeCursor))
            XCTAssertEqual(after.state, .ok)
            XCTAssertEqual(after.records.map(\.event.text), ["first"])
        }
    }

    func testUnterminatedValidTailIsProjectedButNotDeliveredUntilTerminated() throws {
        try withLog { log in
            try log.append(prompt(promptID, "first", .queued))
            let line = try rawRecordLine(output(outputID, "tail", .live))
            try appendRaw(line, to: log.url)

            let read = log.readRevisions()
            XCTAssertEqual(read.events.map(\.id), [promptID, outputID])
            let feed = changes(log, since: "")
            XCTAssertEqual(feed.records.map(\.event.eventID), [promptID.uuidString])
            XCTAssertEqual(feed.unterminatedTailBytes, line.count)

            // The next append separates the tail with a newline first.
            try log.append(prompt(laterID, "later", .queued))
            let next = changes(log, since: try XCTUnwrap(feed.nextChangeCursor))
            XCTAssertEqual(next.records.map(\.event.eventID), [outputID, laterID].map(\.uuidString))
            XCTAssertEqual(next.unterminatedTailBytes, 0)
        }
    }

    func testUnterminatedTailRevisionOfDeliveredEventIsNotInItsValue() throws {
        try withLog { log in
            try log.append(output(outputID, "kept", .live))
            try appendRaw(try rawRecordLine(output(outputID, "kept+tail", .live)), to: log.url)

            XCTAssertEqual(log.read().events.first.flatMap(text), "kept+tail")
            let feed = changes(log, since: "")
            XCTAssertEqual(feed.records.map(\.event.text), ["kept"])
            XCTAssertEqual(feed.records.map(\.revisionSequence), [1])

            try log.append(prompt(laterID, "later", .queued))
            let next = changes(log, since: try XCTUnwrap(feed.nextChangeCursor))
            XCTAssertEqual(next.records.map(\.event.text), ["kept+tail", "later"])
        }
    }

    func testCoverageOnlyReadMatchesRevisionReadCoverage() throws {
        try withTemporaryDirectory { root in
            let log = ConversationEventLog(directory: root.appendingPathComponent("h"), taskSessionID: taskID)
            XCTAssertEqual(log.readWithCoverage().coverage, .missing)
            try log.append(prompt(promptID, "a", .queued))
            XCTAssertEqual(log.readWithCoverage().coverage, .complete)
            try appendRaw(Data("torn".utf8), to: log.url)
            let light = log.readWithCoverage()
            let full = log.readRevisions()
            XCTAssertEqual(light.coverage, .partial)
            XCTAssertEqual(light.coverage, full.coverage)
            XCTAssertEqual(light.events, full.events)
            XCTAssertEqual(light.events, log.read().events)
            XCTAssertEqual(light.diagnostics, full.diagnostics)
        }
    }

    // MARK: Incompatible cursors

    func testMismatchedCursorsRequireReconciliationInsteadOfRestarting() throws {
        try withLog { log in
            try log.append(prompt(promptID, "go", .queued))
            try log.append(output(outputID, "out", .live))
            let feed = changes(log, since: "")
            let cursorText = try XCTUnwrap(feed.nextChangeCursor)
            let cursor = try XCTUnwrap(ConversationRevisionCursor.parse(cursorText))

            // Truncated source.
            let original = try Data(contentsOf: log.url)
            try original.prefix(cursor.byteOffset / 2).write(to: log.url)
            XCTAssertEqual(changes(log, since: cursorText).reconcileReason, .sourceShorterThanCursor)

            // Same length, one byte changed inside the bound prefix.
            var rewritten = original
            let index = rewritten.firstIndex(of: UInt8(ascii: "g"))!
            rewritten[index] = UInt8(ascii: "G")
            try rewritten.write(to: log.url)
            XCTAssertEqual(changes(log, since: cursorText).reconcileReason, .prefixDigestChanged)

            try original.write(to: log.url)
            XCTAssertEqual(changes(log, since: cursorText).state, .ok)

            let wrongCount = ConversationRevisionCursor(
                sequence: cursor.sequence + 1,
                byteOffset: cursor.byteOffset,
                prefixSHA256: cursor.prefixSHA256
            )
            XCTAssertEqual(changes(log, since: wrongCount.encoded).reconcileReason, .prefixRecordCountChanged)

            let read = log.readRevisions()
            let midLine = 5
            let midCursor = ConversationRevisionCursor(
                sequence: 0,
                byteOffset: midLine,
                prefixSHA256: try XCTUnwrap(read.prefixDigest(byteCount: midLine))
            )
            XCTAssertEqual(changes(log, since: midCursor.encoded).reconcileReason, .cursorNotAtRecordBoundary)
            XCTAssertNil(changes(log, since: midCursor.encoded).nextChangeCursor)
            XCTAssertNotNil(changes(log, since: midCursor.encoded).headChangeCursor)
        }
    }

    func testCursorFromAnotherTaskSourceIsRefused() throws {
        try withTemporaryDirectory { root in
            let first = ConversationEventLog(directory: root, taskSessionID: taskID)
            let other = ConversationEventLog(
                directory: root,
                taskSessionID: TaskSessionID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!)
            )
            try first.append(prompt(promptID, "a", .queued))
            try other.append(prompt(promptID, "b", .queued))
            let cursor = try XCTUnwrap(changes(first, since: "").nextChangeCursor)
            XCTAssertEqual(changes(other, since: cursor).reconcileReason, .prefixDigestChanged)
        }
    }

    func testNoncanonicalCursorsAreInvalidNotRestarted() throws {
        try withLog { log in
            try log.append(prompt(promptID, "go", .queued))
            let digest = String(repeating: "a", count: 64)
            for raw in [
                "v1:1",
                "r1:1:2",
                "r1:01:2:\(digest)",
                "r1:1:2:\(digest.uppercased())",
                "r1:-1:2:\(digest)",
                "r1:1:2:\(digest):extra",
                "r2:1:2:\(digest)",
                "r1:+1:2:\(digest)",
            ] {
                let feed = changes(log, since: raw)
                XCTAssertEqual(feed.state, .invalid, raw)
                XCTAssertTrue(feed.records.isEmpty, raw)
                XCTAssertNil(feed.nextChangeCursor, raw)
            }
        }
    }

    // MARK: Exact expansion

    func testCappedUnicodeTextExpandsExactlyAcrossSlices() throws {
        // Combining marks, ZWJ family emoji, flags and CJK: a slice boundary
        // must never split a user-perceived character.
        let unit = "e\u{301}👨‍👩‍👧‍👦🇨🇦漢字 "
        let text = String(repeating: unit, count: 900)
        let event = output(outputID, text, .closed)
        let src = source(events: [event], durable: nil, kind: .durableLog)
        let page = ConduitSessionEventExport.page(source: src)
        let record = try XCTUnwrap(page.events.first)
        XCTAssertTrue(record.textCapped)
        XCTAssertFalse(record.sourceTruncated)
        XCTAssertEqual(record.textContinuationOffset, ConduitSessionEventPage.defaultTextLimit)
        let digest = try XCTUnwrap(record.fullTextSHA256)

        var assembled = ""
        var offset: Int? = 0
        var slices = 0
        while let current = offset {
            let expansion = ConduitSessionEventExport.expand(
                source: src,
                eventID: outputID.uuidString,
                offset: current,
                limit: 777
            )
            XCTAssertEqual(expansion.state, .ok)
            let slice = try XCTUnwrap(expansion.text)
            XCTAssertEqual(expansion.totalCharacters, text.count)
            XCTAssertEqual(
                slice.count,
                (expansion.nextOffset ?? text.count) - current,
                "offsets count user-perceived characters"
            )
            // Neither side of a boundary may hold half of a character: a
            // slice cannot begin with a combining mark, a ZWJ or a lone
            // regional indicator continuing the previous slice's character.
            if let first = slice.unicodeScalars.first {
                XCTAssertNotEqual(first.properties.generalCategory, .nonspacingMark)
                XCTAssertNotEqual(first, "\u{200D}")
            }
            XCTAssertEqual(
                (assembled + slice).count,
                assembled.count + slice.count,
                "joining a slice must not merge characters across the boundary"
            )
            assembled += slice
            XCTAssertEqual(expansion.fullTextSHA256, digest)
            offset = expansion.nextOffset
            slices += 1
            if expansion.complete { XCTAssertNil(expansion.nextOffset) }
        }
        XCTAssertEqual(assembled, text)
        XCTAssertEqual(assembled.count, text.count)
        XCTAssertGreaterThan(slices, 1)
        // The page's capped text is exactly the expansion prefix.
        XCTAssertTrue(record.text?.hasPrefix(String(text.prefix(ConduitSessionEventPage.defaultTextLimit))) == true)
    }

    func testExpansionKeepsRedactionAndSeparatesCaptureTruncation() throws {
        let secret = "Bearer sk-live-secret-value-123456"
        let text = String(repeating: "x", count: 1_990) + " " + secret + " tail"
        let event = SessionPresentation.agentOutputEvent(
            promptEventID: nil,
            text: text,
            state: .settled,
            extraction: .tmuxPane,
            truncated: true,
            id: outputID,
            occurredAt: t0
        )
        let src = source(events: [event], durable: nil, kind: .cachedHistory)
        let record = try XCTUnwrap(ConduitSessionEventExport.page(source: src).events.first)
        XCTAssertTrue(record.textCapped)
        XCTAssertTrue(record.sourceTruncated)
        XCTAssertTrue(record.truncated)

        let expansion = ConduitSessionEventExport.expand(
            source: src, eventID: outputID.uuidString, offset: 0, limit: 32_000
        )
        XCTAssertTrue(expansion.complete)
        XCTAssertTrue(expansion.redacted)
        XCTAssertTrue(expansion.sourceTruncated)
        XCTAssertFalse(expansion.text?.contains("sk-live-secret") == true)
        XCTAssertEqual(expansion.fullTextSHA256, record.fullTextSHA256)
        let shown = try XCTUnwrap(record.text?.replacingOccurrences(of: "\n[truncated]", with: ""))
        XCTAssertTrue(try XCTUnwrap(expansion.text).hasPrefix(shown))
    }

    func testExpansionRejectsUnknownEventsAndOutOfRangeOffsets() {
        let src = source(events: [prompt(promptID, "short", .queued)], durable: nil, kind: .durableLog)
        XCTAssertEqual(
            ConduitSessionEventExport.expand(source: src, eventID: outputID.uuidString, offset: 0, limit: nil).state,
            .notFound
        )
        XCTAssertEqual(
            ConduitSessionEventExport.expand(source: src, eventID: "not-a-uuid", offset: 0, limit: nil).state,
            .notFound
        )
        XCTAssertEqual(
            ConduitSessionEventExport.expand(source: src, eventID: promptID.uuidString, offset: 6, limit: nil).state,
            .invalidOffset
        )
        XCTAssertEqual(
            ConduitSessionEventExport.expand(source: src, eventID: promptID.uuidString, offset: -1, limit: nil).state,
            .invalidOffset
        )
        let whole = ConduitSessionEventExport.expand(source: src, eventID: promptID.uuidString, offset: 0, limit: nil)
        XCTAssertEqual(whole.text, "short")
        XCTAssertTrue(whole.complete)
    }

    // MARK: Compatibility and read-only boundary

    func testPageWithoutOptionsKeepsV1ShapeAndReadsStayReadOnly() throws {
        let src = ConduitSessionEventSource(
            taskSessionID: taskID.rawValue.uuidString,
            backend: .pty,
            sessionLifecycle: "closed",
            runtimeState: "closed",
            live: false,
            ready: false,
            events: [prompt(promptID, "go", .delivered)]
        )
        let json = ConduitSessionEventExport.page(source: src).jsonObject()
        XCTAssertNil(json["changes"])
        XCTAssertNil(json["expansion"])
        XCTAssertNil(json["timeline_source"])
        XCTAssertEqual(json["next_cursor"] as? String, "v1:1")
        let record = try XCTUnwrap((json["events"] as? [[String: Any]])?.first)
        XCTAssertEqual(record["text_capped"] as? Bool, false)
        XCTAssertEqual(record["source_truncated"] as? Bool, false)
        XCTAssertNil(record["full_text_sha256"])

        XCTAssertFalse(
            ConduitSessionAPI.isWrite(
                .sessionEvents(
                    taskSessionID: "t",
                    cursor: nil,
                    limit: nil,
                    options: ConduitSessionEventReadOptions(changesSince: "", expandEventID: "x")
                )
            )
        )
        let tool = try XCTUnwrap(ConduitSessionToolCatalog.tool(named: "conduit_session_events"))
        XCTAssertEqual((tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true)
        let properties = try XCTUnwrap((tool["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])
        for name in ["changes_since", "change_limit", "expand_event_id", "expand_offset", "expand_limit"] {
            XCTAssertNotNil(properties[name], name)
        }
        XCTAssertEqual(
            ((tool["inputSchema"] as? [String: Any])?["required"] as? [String]),
            ["taskSessionID"]
        )
    }

    func testChangeFeedWithoutDurableReadIsUnavailableNotEmpty() {
        let src = source(events: [prompt(promptID, "go", .queued)], durable: nil, kind: .liveRuntime)
        let feed = ConduitSessionEventExport.changeFeed(source: src, since: "", limit: nil)
        XCTAssertEqual(feed.state, .unavailable)
        XCTAssertTrue(feed.records.isEmpty)
        XCTAssertNil(feed.nextChangeCursor)
    }

    // MARK: Review regressions

    func testRedactionRunsToAFixedPointAcrossExposedTokens() {
        // Replacing the first key leaves a combining mark after "]", which
        // creates a word boundary before the second key.
        for joiner in ["\u{301}", "\u{FE0F}"] {
            let text = "xai-abcdefgh\(joiner)sk-abcdefgh"
            let event = output(outputID, text, .closed)
            let src = source(events: [event], durable: nil, kind: .durableLog)
            let record = ConduitSessionEventExport.page(source: src).events.first
            XCTAssertEqual(record?.redacted, true)
            XCTAssertFalse(record?.text?.contains("sk-abcdefgh") == true, joiner)
            XCTAssertFalse(record?.text?.contains("xai-abcdefgh") == true, joiner)
            let expansion = ConduitSessionEventExport.expand(
                source: src, eventID: outputID.uuidString, offset: 0, limit: nil
            )
            XCTAssertFalse(expansion.text?.contains("sk-abcdefgh") == true, joiner)
        }
    }

    func testRedactionThatDoesNotSettleWithinItsBoundWithholdsTheText() throws {
        // Each pass replaces one key and exposes the next, so a chain of n
        // keys needs n changing passes plus one quiet pass. Past the bound the
        // remaining text is withheld on every export path instead of being
        // returned as redacted. The prefix puts the chain beyond the record
        // cap and inside one expansion slice.
        let prefix = String(repeating: "word ", count: 420)
        func chain(_ count: Int, _ joiner: String) -> String {
            prefix + Array(repeating: "xai-abcdefgh", count: count).joined(separator: joiner)
        }
        for joiner in ["\u{301}", "\u{FE0F}"] {
            let settled = ConduitSessionEventExport.redactText(chain(7, joiner))
            XCTAssertTrue(settled.redacted)
            XCTAssertTrue(settled.text.hasPrefix(prefix), "seven keys settle in eight passes")
            XCTAssertFalse(settled.text.contains("xai-"))

            for count in [8, 9] {
                let text = chain(count, joiner)
                try withLog { log in
                    try log.append(output(outputID, text, .closed))
                    let src = source(log)
                    let page = ConduitSessionEventExport.page(
                        source: src,
                        options: ConduitSessionEventReadOptions(changesSince: "")
                    )
                    let record = try XCTUnwrap(page.events.first)
                    let change = try XCTUnwrap(page.changes?.records.first?.event)
                    let expansion = ConduitSessionEventExport.expand(
                        source: src, eventID: outputID.uuidString, offset: 0, limit: 32_000
                    )
                    let sanitized = ConduitSessionEventExport.sanitizeText(text, limit: 32_000)

                    for exported in [record.text, change.text, expansion.text, sanitized.text] {
                        XCTAssertFalse(exported?.contains("xai-") == true, "\(count) keys, \(joiner.unicodeScalars.first!.value)")
                    }
                    XCTAssertTrue(record.redacted)
                    XCTAssertTrue(change.redacted)
                    XCTAssertTrue(expansion.redacted)
                    XCTAssertTrue(sanitized.redacted)
                    XCTAssertTrue(expansion.complete)
                    XCTAssertEqual(record.text, expansion.text)
                    XCTAssertEqual(change.text, expansion.text)
                    XCTAssertEqual(sanitized.text, expansion.text)
                    XCTAssertEqual(expansion.text, ConduitSessionEventExport.unsettledRedactionText)
                    XCTAssertFalse(record.textCapped)
                }
            }
        }
    }

    func testChangeRecordsOmitTheLiveTurnStatusOfOtherTurns() throws {
        try withLog { log in
            try log.append(output(outputID, "turn one", .closed))
            let durable = log.readRevisions()
            let src = ConduitSessionEventSource(
                taskSessionID: taskID.rawValue.uuidString,
                backend: .appServer,
                sessionLifecycle: "running",
                runtimeState: "ready",
                live: true,
                ready: true,
                events: durable.events,
                adapter: ConduitSessionAdapterSnapshot(lastTurnStatus: "failed", turnFailure: "boom"),
                durableRevisions: durable
            )
            let page = ConduitSessionEventExport.page(
                source: src,
                options: ConduitSessionEventReadOptions(changesSince: "")
            )
            XCTAssertNil(page.changes?.records.first?.event.turnStatus)
            XCTAssertNil(page.changes?.records.first?.jsonObject()["turn_status"])
            // The v1 record keeps its existing behaviour.
            XCTAssertEqual(page.events.first?.turnStatus, "failed")
        }
    }

    func testArgumentParsingNeverTrapsAndReportsMalformedValues() {
        func options(_ object: [String: CodexJSON]) -> ConduitSessionEventReadOptions {
            ConduitSessionEventReadOptions(arguments: .object(object))
        }
        let hostile = options([
            "change_limit": .number(1e300),
            "expand_limit": .number(.infinity),
            "expand_offset": .number(.nan),
            "changes_since": .number(0),
            "expand_event_id": .number(42),
        ])
        XCTAssertNil(hostile.changeLimit)
        XCTAssertNil(hostile.expandLimit)
        XCTAssertEqual(hostile.expandOffset, -1)
        XCTAssertEqual(hostile.changesSince, "0")
        XCTAssertEqual(hostile.expandEventID, "42")

        let fractional = options(["expand_offset": .number(2000.9), "change_limit": .number(2.0)])
        XCTAssertEqual(fractional.expandOffset, -1)
        XCTAssertEqual(fractional.changeLimit, 2)

        let text = options(["expand_offset": .string("8k"), "changes_since": .string("")])
        XCTAssertEqual(text.expandOffset, -1)
        XCTAssertEqual(text.changesSince, "")

        let nulls = options(["changes_since": .null, "expand_offset": .null, "expand_event_id": .null])
        XCTAssertEqual(nulls, .none)
        XCTAssertEqual(options([:]), .none)

        // A reported malformed value reaches validation instead of vanishing.
        let src = source(events: [prompt(promptID, "go", .queued)], durable: nil, kind: .durableLog)
        XCTAssertEqual(
            ConduitSessionEventExport.expand(
                source: src, eventID: promptID.uuidString,
                offset: text.expandOffset, limit: nil
            ).state,
            .invalidOffset
        )
        XCTAssertNil(ConversationRevisionCursor.parse(hostile.changesSince ?? ""))
    }

    // MARK: Helpers

    private func text(_ event: SessionPresentationEvent) -> String? {
        if case .agentOutput(let output) = event.kind { return output.text }
        if case .userPrompt(let prompt) = event.kind { return prompt.text }
        return nil
    }

    private func changes(
        _ log: ConversationEventLog,
        since: String,
        limit: Int? = nil
    ) -> ConduitSessionChangeFeed {
        ConduitSessionEventExport.changeFeed(
            source: source(log),
            since: since,
            limit: limit
        )
    }

    private func source(_ log: ConversationEventLog) -> ConduitSessionEventSource {
        let durable = log.readRevisions()
        return source(events: durable.events, durable: durable, kind: .durableLog)
    }

    private func source(
        events: [SessionPresentationEvent],
        durable: ConversationRevisionReadResult?,
        kind: ConduitSessionTimelineSourceKind
    ) -> ConduitSessionEventSource {
        ConduitSessionEventSource(
            taskSessionID: taskID.rawValue.uuidString,
            backend: .appServer,
            sessionLifecycle: "running",
            runtimeState: "ready",
            live: kind == .liveRuntime,
            ready: true,
            events: events,
            timelineSource: ConduitSessionTimelineSource(
                kind: kind,
                durableCoverage: durable?.coverage,
                rejectedRecordCount: durable?.diagnostics.count
            ),
            durableRevisions: durable
        )
    }

    private func prompt(
        _ id: UUID,
        _ text: String,
        _ delivery: PromptDeliveryState
    ) -> SessionPresentationEvent {
        SessionPresentationEvent(
            id: id,
            occurredAt: t0,
            authority: .conduitRecorded,
            kind: .userPrompt(
                SubmittedPrompt(
                    origin: .chatgpt,
                    text: text,
                    attachmentPaths: [],
                    renderedPayload: text,
                    delivery: delivery
                )
            )
        )
    }

    private func output(
        _ id: UUID,
        _ text: String,
        _ state: AgentOutputState
    ) -> SessionPresentationEvent {
        SessionPresentation.agentOutputEvent(
            promptEventID: promptID,
            text: text,
            state: state,
            extraction: .structuredAdapter,
            truncated: false,
            id: id,
            occurredAt: t0.addingTimeInterval(1)
        )
    }

    private struct RawRecord: Codable {
        let schemaVersion: Int
        let taskSessionID: TaskSessionID
        let recordedAt: Date
        let event: SessionPresentationEvent
    }

    private func rawRecordLine(_ event: SessionPresentationEvent) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(
            RawRecord(
                schemaVersion: ConversationEventLog.currentSchemaVersion,
                taskSessionID: taskID,
                recordedAt: t0,
                event: event
            )
        )
    }

    private func appendRaw(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func withLog(_ body: (ConversationEventLog) throws -> Void) throws {
        try withTemporaryDirectory { root in
            try body(
                ConversationEventLog(
                    directory: root.appendingPathComponent("history"),
                    taskSessionID: taskID
                )
            )
        }
    }

    private func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-revision-feed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory)
    }
}
