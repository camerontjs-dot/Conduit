import Darwin
import Dispatch
import Foundation
import XCTest
@testable import ConduitCore

final class ConversationEventLogTests: XCTestCase {
    func testAppendProjectsFirstSeenOrderWithLatestValidRevision() throws {
        try withTemporaryDirectory { directory in
            let taskID = makeTaskID(
                "00000000-0000-0000-0000-000000000001"
            )
            let log = ConversationEventLog(
                directory: directory,
                taskSessionID: taskID
            )
            let prompt = promptEvent(
                id: UUID(
                    uuidString: "00000000-0000-0000-0000-000000000010"
                )!,
                text: "Review this",
                delivery: .queued
            )
            let opening = SessionPresentation.openingEvent(
                .started(agentName: "Codex", requestedBackend: "PTY"),
                id: UUID(
                    uuidString: "00000000-0000-0000-0000-000000000011"
                )!,
                occurredAt: Date(timeIntervalSince1970: 1_800_000_001)
            )
            let delivered = revisedPrompt(prompt, delivery: .delivered)

            try log.append(prompt)
            try log.append(opening)
            try log.append(delivered)

            let read = log.read()
            XCTAssertEqual(read.events, [delivered, opening])
            XCTAssertTrue(read.diagnostics.isEmpty)
        }
    }

    func testAppendMakesDirectoryAndFilePrivate() throws {
        try withTemporaryDirectory { temporaryDirectory in
            let directory = temporaryDirectory.appendingPathComponent("history")
            let log = ConversationEventLog(
                directory: directory,
                taskSessionID: TaskSessionID()
            )
            try log.append(
                SessionPresentation.openingEvent(
                    .started(agentName: "Codex", requestedBackend: "PTY")
                )
            )

            let directoryAttributes = try FileManager.default.attributesOfItem(
                atPath: directory.path
            )
            let fileAttributes = try FileManager.default.attributesOfItem(
                atPath: log.url.path
            )
            XCTAssertEqual(
                (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue,
                0o700
            )
            XCTAssertEqual(
                (fileAttributes[.posixPermissions] as? NSNumber)?.intValue,
                0o600
            )
        }
    }

    func testAppendTightensExistingDirectoryAndFilePermissions() throws {
        try withTemporaryDirectory { temporaryDirectory in
            let directory = temporaryDirectory.appendingPathComponent("history")
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let directoryChmod = directory.path.withCString {
                Darwin.chmod($0, mode_t(0o777))
            }
            XCTAssertEqual(directoryChmod, 0)

            let log = ConversationEventLog(
                directory: directory,
                taskSessionID: TaskSessionID()
            )
            try Data().write(to: log.url)
            let fileChmod = log.url.path.withCString {
                Darwin.chmod($0, mode_t(0o666))
            }
            XCTAssertEqual(fileChmod, 0)

            try log.append(
                SessionPresentation.openingEvent(
                    .started(agentName: "Codex", requestedBackend: "PTY")
                )
            )

            let directoryAttributes = try FileManager.default.attributesOfItem(
                atPath: directory.path
            )
            let fileAttributes = try FileManager.default.attributesOfItem(
                atPath: log.url.path
            )
            XCTAssertEqual(
                (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue,
                0o700
            )
            XCTAssertEqual(
                (fileAttributes[.posixPermissions] as? NSNumber)?.intValue,
                0o600
            )
        }
    }

    func testSymlinkedConversationDirectoryIsRejectedWithoutWritingTarget() throws {
        try withTemporaryDirectory { temporaryDirectory in
            let target = temporaryDirectory.appendingPathComponent("target")
            let directory = temporaryDirectory.appendingPathComponent("history")
            try FileManager.default.createDirectory(
                at: target,
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(
                at: directory,
                withDestinationURL: target
            )

            let log = ConversationEventLog(
                directory: directory,
                taskSessionID: TaskSessionID()
            )
            XCTAssertThrowsError(
                try log.append(
                    SessionPresentation.openingEvent(
                        .started(agentName: "Codex", requestedBackend: "PTY")
                    )
                )
            )
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: target.path),
                []
            )
            XCTAssertEqual(log.read().diagnostics.map(\.kind), [.unreadableLog])
        }
    }

    func testRegularFileCannotStandInForConversationDirectory() throws {
        try withTemporaryDirectory { temporaryDirectory in
            let directory = temporaryDirectory.appendingPathComponent("history")
            let original = Data("not a directory".utf8)
            try original.write(to: directory)

            let log = ConversationEventLog(
                directory: directory,
                taskSessionID: TaskSessionID()
            )
            XCTAssertThrowsError(
                try log.append(
                    SessionPresentation.openingEvent(
                        .started(agentName: "Codex", requestedBackend: "PTY")
                    )
                )
            )
            XCTAssertEqual(try Data(contentsOf: directory), original)
            XCTAssertEqual(log.read().diagnostics.map(\.kind), [.unreadableLog])
        }
    }

    func testSymlinkedConversationFileIsRejectedWithoutModifyingTarget() throws {
        try withTemporaryDirectory { temporaryDirectory in
            let directory = temporaryDirectory.appendingPathComponent("history")
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let target = temporaryDirectory.appendingPathComponent("target.txt")
            let original = Data("do not modify".utf8)
            try original.write(to: target)

            let log = ConversationEventLog(
                directory: directory,
                taskSessionID: TaskSessionID()
            )
            try FileManager.default.createSymbolicLink(
                at: log.url,
                withDestinationURL: target
            )

            XCTAssertThrowsError(
                try log.append(
                    SessionPresentation.openingEvent(
                        .started(agentName: "Codex", requestedBackend: "PTY")
                    )
                )
            )
            XCTAssertEqual(try Data(contentsOf: target), original)
            XCTAssertEqual(log.read().diagnostics.map(\.kind), [.unreadableLog])
        }
    }

    func testDirectoryCannotStandInForConversationFile() throws {
        try withTemporaryDirectory { directory in
            let log = ConversationEventLog(
                directory: directory,
                taskSessionID: TaskSessionID()
            )
            try FileManager.default.createDirectory(
                at: log.url,
                withIntermediateDirectories: false
            )

            XCTAssertThrowsError(
                try log.append(
                    SessionPresentation.openingEvent(
                        .started(agentName: "Codex", requestedBackend: "PTY")
                    )
                )
            )
            XCTAssertTrue(
                try FileManager.default.contentsOfDirectory(
                    atPath: log.url.path
                ).isEmpty
            )
            XCTAssertEqual(log.read().diagnostics.map(\.kind), [.unreadableLog])
        }
    }

    func testReadWaitsForCooperatingExclusiveAppenderLock() throws {
        try withTemporaryDirectory { directory in
            let log = ConversationEventLog(
                directory: directory,
                taskSessionID: TaskSessionID()
            )
            let event = SessionPresentation.openingEvent(
                .started(agentName: "Codex", requestedBackend: "PTY"),
                occurredAt: Date(timeIntervalSince1970: 1_800_000_123)
            )
            try log.append(event)

            let descriptor = log.url.path.withCString {
                Darwin.open($0, O_RDONLY | O_CLOEXEC)
            }
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            guard descriptor >= 0 else { return }
            defer { _ = Darwin.close(descriptor) }
            XCTAssertEqual(flock(descriptor, LOCK_EX), 0)
            var lockIsHeld = true
            defer {
                if lockIsHeld {
                    _ = flock(descriptor, LOCK_UN)
                }
            }

            let started = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)
            let result = LockedConversationReadResult()
            DispatchQueue.global(qos: .userInitiated).async {
                started.signal()
                result.record(log.read())
                finished.signal()
            }

            XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
            XCTAssertEqual(finished.wait(timeout: .now() + 0.15), .timedOut)
            XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
            lockIsHeld = false
            XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
            XCTAssertEqual(result.snapshot()?.events, [event])
            XCTAssertTrue(result.snapshot()?.diagnostics.isEmpty == true)
        }
    }

    func testAppendAfterTornTailPreservesBytesAndDiagnosesLine() throws {
        try withTemporaryDirectory { directory in
            let log = ConversationEventLog(
                directory: directory,
                taskSessionID: TaskSessionID()
            )
            let first = SessionPresentation.openingEvent(
                .started(agentName: "Codex", requestedBackend: "PTY"),
                occurredAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
            let second = promptEvent(text: "Continue", delivery: .queued)
            try log.append(first)
            try appendRaw(Data("{\"torn\"".utf8), to: log.url)
            try log.append(second)

            let bytesBeforeRead = try Data(contentsOf: log.url)
            XCTAssertTrue(
                String(decoding: bytesBeforeRead, as: UTF8.self)
                    .contains("{\"torn\"\n")
            )

            let read = log.read()
            XCTAssertEqual(read.events, [first, second])
            XCTAssertEqual(read.diagnostics.map(\.kind), [.malformedLine])
            XCTAssertEqual(read.diagnostics.first?.lineNumber, 2)
            XCTAssertEqual(try Data(contentsOf: log.url), bytesBeforeRead)
        }
    }

    func testReadDiagnosesUnsupportedMismatchedAndInvalidAuthorityRecords() throws {
        try withTemporaryDirectory { directory in
            let taskID = makeTaskID(
                "00000000-0000-0000-0000-000000000020"
            )
            let otherTaskID = makeTaskID(
                "00000000-0000-0000-0000-000000000021"
            )
            let log = ConversationEventLog(
                directory: directory,
                taskSessionID: taskID
            )
            let valid = promptEvent(text: "Keep me", delivery: .queued)
            try log.append(valid)

            let unsupported = RawRecord(
                schemaVersion: ConversationEventLog.currentSchemaVersion + 1,
                taskSessionID: taskID,
                recordedAt: Date(),
                event: SessionPresentation.openingEvent(
                    .started(agentName: "Codex", requestedBackend: "PTY")
                )
            )
            let mismatched = RawRecord(
                schemaVersion: ConversationEventLog.currentSchemaVersion,
                taskSessionID: otherTaskID,
                recordedAt: Date(),
                event: SessionPresentation.openingEvent(
                    .started(agentName: "Codex", requestedBackend: "PTY")
                )
            )
            let invalidAuthority = RawRecord(
                schemaVersion: ConversationEventLog.currentSchemaVersion,
                taskSessionID: taskID,
                recordedAt: Date(),
                event: SessionPresentationEvent(
                    authority: .derivedFromRaw,
                    kind: .sessionOpened(
                        .started(agentName: "Codex", requestedBackend: "PTY")
                    )
                )
            )
            try appendRawLines(
                [
                    try encode(unsupported),
                    try encode(mismatched),
                    try encode(invalidAuthority)
                ],
                to: log.url
            )
            let bytesBeforeRead = try Data(contentsOf: log.url)

            let read = log.read()
            XCTAssertEqual(read.events, [valid])
            XCTAssertEqual(
                read.diagnostics.map(\.kind),
                [
                    .unsupportedSchemaVersion,
                    .mismatchedTaskSessionID,
                    .invalidAuthority
                ]
            )
            XCTAssertEqual(try Data(contentsOf: log.url), bytesBeforeRead)
        }
    }

    func testInvalidRevisionCannotRewritePromptOrTerminalDelivery() throws {
        try withTemporaryDirectory { directory in
            let taskID = TaskSessionID()
            let log = ConversationEventLog(
                directory: directory,
                taskSessionID: taskID
            )
            let queued = promptEvent(text: "Original", delivery: .queued)
            let delivered = revisedPrompt(queued, delivery: .delivered)
            let rewritten = SessionPresentationEvent(
                id: queued.id,
                occurredAt: queued.occurredAt,
                authority: .conduitRecorded,
                kind: .userPrompt(
                    SubmittedPrompt(
                        text: "Rewritten",
                        attachmentPaths: [],
                        renderedPayload: "Rewritten",
                        delivery: .delivered
                    )
                )
            )
            let terminalStateChanged = revisedPrompt(
                queued,
                delivery: .failed
            )

            try log.append(queued)
            try log.append(delivered)
            try appendRawLines(
                [
                    try encode(
                        RawRecord(
                            schemaVersion: ConversationEventLog.currentSchemaVersion,
                            taskSessionID: taskID,
                            recordedAt: Date(),
                            event: rewritten
                        )
                    ),
                    try encode(
                        RawRecord(
                            schemaVersion: ConversationEventLog.currentSchemaVersion,
                            taskSessionID: taskID,
                            recordedAt: Date(),
                            event: terminalStateChanged
                        )
                    )
                ],
                to: log.url
            )

            let read = log.read()
            XCTAssertEqual(read.events, [delivered])
            XCTAssertEqual(
                read.diagnostics.map(\.kind),
                [.invalidRevision, .invalidRevision]
            )
        }
    }

    func testAppendRejectsInvalidAuthorityWithoutCreatingDirectory() throws {
        try withTemporaryDirectory { temporaryDirectory in
            let directory = temporaryDirectory.appendingPathComponent("history")
            let event = SessionPresentationEvent(
                authority: .derivedFromRaw,
                kind: .userPrompt(
                    SubmittedPrompt(
                        text: "Invalid",
                        attachmentPaths: [],
                        renderedPayload: "Invalid"
                    )
                )
            )
            let log = ConversationEventLog(
                directory: directory,
                taskSessionID: TaskSessionID()
            )

            XCTAssertThrowsError(try log.append(event)) { error in
                XCTAssertEqual(
                    error as? ConversationEventLogError,
                    .invalidAuthority(eventID: event.id)
                )
            }
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: directory.path)
            )
        }
    }

    func testConcurrentAppendersDoNotOverwriteOrInterleaveRecords() throws {
        try withTemporaryDirectory { directory in
            let log = ConversationEventLog(
                directory: directory,
                taskSessionID: TaskSessionID()
            )
            let events = (0..<64).map { index in
                SessionPresentation.openingEvent(
                    .started(
                        agentName: "Agent \(index)",
                        requestedBackend: "PTY"
                    )
                )
            }
            let errors = LockedConversationLogErrors()

            DispatchQueue.concurrentPerform(iterations: events.count) { index in
                do {
                    try log.append(events[index])
                } catch {
                    errors.record(error)
                }
            }

            XCTAssertTrue(
                errors.snapshot().isEmpty,
                errors.snapshot().joined(separator: "\n")
            )
            let read = log.read()
            XCTAssertTrue(read.diagnostics.isEmpty)
            XCTAssertEqual(Set(read.events.map(\.id)), Set(events.map(\.id)))
            XCTAssertEqual(read.events.count, events.count)
        }
    }

    func testRawDerivedOutputRevisionRetainsAuthorityAndLatestRenderedText() throws {
        try withTemporaryDirectory { directory in
            let log = ConversationEventLog(
                directory: directory,
                taskSessionID: TaskSessionID()
            )
            let promptID = UUID()
            let first = SessionPresentation.agentOutputEvent(
                promptEventID: promptID,
                text: "Inspecting the source…",
                extraction: .tmuxPane,
                truncated: false,
                occurredAt: Date(timeIntervalSince1970: 1_800_000_020)
            )
            let settled = SessionPresentation.agentOutputEvent(
                promptEventID: promptID,
                text: "Inspected the source and found the issue.",
                state: .settled,
                extraction: .tmuxPane,
                truncated: false,
                id: first.id,
                occurredAt: first.occurredAt
            )

            try log.append(first)
            try log.append(settled)

            XCTAssertEqual(log.read().events, [settled])
            XCTAssertEqual(settled.authority, .derivedFromRaw)
        }
    }

    func testMissingLogReadsAsCleanEmptyWithoutCreatingDirectory() throws {
        try withTemporaryDirectory { temporaryDirectory in
            let directory = temporaryDirectory.appendingPathComponent("missing")
            let log = ConversationEventLog(
                directory: directory,
                taskSessionID: TaskSessionID()
            )

            XCTAssertEqual(
                log.read(),
                ConversationEventLogReadResult(events: [], diagnostics: [])
            )
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: directory.path)
            )
        }
    }

    private struct RawRecord: Codable {
        let schemaVersion: Int
        let taskSessionID: TaskSessionID
        let recordedAt: Date
        let event: SessionPresentationEvent
    }

    private func makeTaskID(_ uuidString: String) -> TaskSessionID {
        TaskSessionID(rawValue: UUID(uuidString: uuidString)!)
    }

    private func promptEvent(
        id: UUID = UUID(),
        text: String,
        delivery: PromptDeliveryState
    ) -> SessionPresentationEvent {
        SessionPresentationEvent(
            id: id,
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
            authority: .conduitRecorded,
            kind: .userPrompt(
                SubmittedPrompt(
                    text: text,
                    attachmentPaths: [],
                    renderedPayload: text,
                    delivery: delivery
                )
            )
        )
    }

    private func revisedPrompt(
        _ event: SessionPresentationEvent,
        delivery: PromptDeliveryState
    ) -> SessionPresentationEvent {
        guard case .userPrompt(var prompt) = event.kind else {
            return event
        }
        prompt.delivery = delivery
        return SessionPresentationEvent(
            id: event.id,
            occurredAt: event.occurredAt,
            authority: event.authority,
            kind: .userPrompt(prompt)
        )
    }

    private func encode(_ record: RawRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(record)
    }

    private func appendRaw(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func appendRawLines(_ lines: [Data], to url: URL) throws {
        var data = Data()
        for line in lines {
            data.append(line)
            data.append(UInt8(ascii: "\n"))
        }
        try appendRaw(data, to: url)
    }

    private func withTemporaryDirectory<T>(
        _ body: (URL) throws -> T
    ) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "conduit-conversation-log-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory)
    }
}

private final class LockedConversationLogErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func record(_ error: Error) {
        lock.lock()
        messages.append(String(describing: error))
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }
}

private final class LockedConversationReadResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: ConversationEventLogReadResult?

    func record(_ result: ConversationEventLogReadResult) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func snapshot() -> ConversationEventLogReadResult? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}
