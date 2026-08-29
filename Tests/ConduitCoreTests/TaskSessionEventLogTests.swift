import Dispatch
import Foundation
import XCTest
@testable import ConduitCore

final class TaskSessionEventLogTests: XCTestCase {
    private let rootURL = URL(fileURLWithPath: "/tmp/MainFrame")
    private let projectURL = URL(
        fileURLWithPath: "/tmp/MainFrame/30_projects/conduit"
    )

    func testAppendReadDiscoveryAndStoreLoadUseOneCanonicalFilePerTask() throws {
        try withTemporaryDirectory { temporaryDirectory in
            let logDirectory = temporaryDirectory.appendingPathComponent("tasks")
            let firstID = taskID("00000000-0000-0000-0000-000000000001")
            let secondID = taskID("00000000-0000-0000-0000-000000000002")
            let firstLog = TaskSessionEventLog(
                directory: logDirectory,
                taskSessionID: firstID
            )
            let secondLog = TaskSessionEventLog(
                directory: logDirectory,
                taskSessionID: secondID
            )
            let createdAt = Date(timeIntervalSince1970: 1_800_100_000)
            let firstEvents = [
                event(
                    firstID,
                    at: createdAt,
                    authority: .conduitRecorded,
                    kind: .created(metadata(title: "First task"))
                ),
                event(
                    firstID,
                    at: createdAt.addingTimeInterval(1),
                    authority: .operatorAsserted,
                    kind: .pinChanged(true)
                )
            ]
            let secondCreation = event(
                secondID,
                at: createdAt.addingTimeInterval(2),
                authority: .conduitRecorded,
                kind: .created(metadata(title: "Second task"))
            )

            // Append in reverse ID order to prove discovery is not directory-order
            // dependent.
            try secondLog.append(secondCreation)
            for event in firstEvents {
                try firstLog.append(event)
            }

            let filenames = try FileManager.default.contentsOfDirectory(
                atPath: logDirectory.path
            ).sorted()
            XCTAssertEqual(
                filenames,
                [
                    "00000000-0000-0000-0000-000000000001.jsonl",
                    "00000000-0000-0000-0000-000000000002.jsonl"
                ]
            )

            let read = firstLog.read()
            XCTAssertEqual(read.events, firstEvents)
            XCTAssertTrue(read.diagnostics.isEmpty)

            let store = TaskSessionEventStore(directory: logDirectory)
            let discovery = store.logs()
            XCTAssertEqual(
                discovery.logs.map(\.taskSessionID),
                [firstID, secondID]
            )
            XCTAssertTrue(discovery.diagnostics.isEmpty)

            let loaded = store.load()
            XCTAssertEqual(
                loaded.snapshots.map(\.id),
                [firstID, secondID]
            )
            XCTAssertEqual(
                loaded.snapshots.map(\.displayTitle),
                ["First task", "Second task"]
            )
            XCTAssertTrue(loaded.snapshots[0].isPinned)
            XCTAssertTrue(loaded.diagnostics.isEmpty)
        }
    }

    func testAppendRejectsMismatchedTaskWithoutCreatingAFile() throws {
        try withTemporaryDirectory { temporaryDirectory in
            let logDirectory = temporaryDirectory.appendingPathComponent("tasks")
            let expectedID = taskID("00000000-0000-0000-0000-000000000010")
            let actualID = taskID("00000000-0000-0000-0000-000000000011")
            let log = TaskSessionEventLog(
                directory: logDirectory,
                taskSessionID: expectedID
            )
            let mismatched = event(
                actualID,
                at: Date(timeIntervalSince1970: 1_800_100_100),
                authority: .conduitRecorded,
                kind: .created(metadata(title: "Wrong task"))
            )

            XCTAssertThrowsError(try log.append(mismatched)) { error in
                XCTAssertEqual(
                    error as? TaskSessionEventLogError,
                    .mismatchedTaskSessionID(
                        expected: expectedID,
                        actual: actualID
                    )
                )
            }
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: logDirectory.path)
            )
        }
    }

    func testAppendHealsTornFinalLineWithoutDeletingIt() throws {
        try withTemporaryDirectory { temporaryDirectory in
            let sessionID = taskID("00000000-0000-0000-0000-000000000020")
            let log = TaskSessionEventLog(
                directory: temporaryDirectory,
                taskSessionID: sessionID
            )
            let createdAt = Date(timeIntervalSince1970: 1_800_100_200)
            let creation = event(
                sessionID,
                at: createdAt,
                authority: .conduitRecorded,
                kind: .created(metadata(title: "Torn write"))
            )
            let pin = event(
                sessionID,
                at: createdAt.addingTimeInterval(1),
                authority: .operatorAsserted,
                kind: .pinChanged(true)
            )
            try log.append(creation)
            try appendRaw(Data("{\"broken\"".utf8), to: log.url)

            try log.append(pin)

            let bytesBeforeRead = try Data(contentsOf: log.url)
            let source = String(decoding: bytesBeforeRead, as: UTF8.self)
            XCTAssertTrue(source.contains("{\"broken\"\n"))
            let read = log.read()
            XCTAssertEqual(read.events, [creation, pin])
            XCTAssertEqual(
                read.diagnostics.map(\.kind),
                [.malformedLine]
            )
            XCTAssertEqual(read.diagnostics.first?.lineNumber, 2)
            XCTAssertEqual(try Data(contentsOf: log.url), bytesBeforeRead)
        }
    }

    func testConcurrentAppendersDoNotOverwriteOrInterleaveEvents() throws {
        try withTemporaryDirectory { temporaryDirectory in
            let sessionID = taskID(
                "00000000-0000-0000-0000-000000000025"
            )
            let log = TaskSessionEventLog(
                directory: temporaryDirectory,
                taskSessionID: sessionID
            )
            let createdAt = Date(timeIntervalSince1970: 1_800_100_250)
            let creation = event(
                sessionID,
                at: createdAt,
                authority: .conduitRecorded,
                kind: .created(metadata(title: "Concurrent task"))
            )
            try log.append(creation)

            let concurrentEvents = (0..<96).map { index in
                event(
                    sessionID,
                    at: createdAt.addingTimeInterval(Double(index + 1)),
                    authority: .operatorAsserted,
                    kind: .pinChanged(index.isMultiple(of: 2))
                )
            }
            let errors = LockedTaskLogErrorMessages()
            DispatchQueue.concurrentPerform(
                iterations: concurrentEvents.count
            ) { index in
                do {
                    try log.append(concurrentEvents[index])
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
            XCTAssertEqual(
                Set(read.events.map(\.id)),
                Set(([creation] + concurrentEvents).map(\.id))
            )
            XCTAssertEqual(read.events.count, concurrentEvents.count + 1)
        }
    }

    func testReadDiagnosesBadLinesAndPreservesRawSource() throws {
        try withTemporaryDirectory { temporaryDirectory in
            let sessionID = taskID("00000000-0000-0000-0000-000000000030")
            let otherID = taskID("00000000-0000-0000-0000-000000000031")
            let log = TaskSessionEventLog(
                directory: temporaryDirectory,
                taskSessionID: sessionID
            )
            let createdAt = Date(timeIntervalSince1970: 1_800_100_300)
            let creation = event(
                sessionID,
                at: createdAt,
                authority: .conduitRecorded,
                kind: .created(metadata(title: "Preserved source"))
            )
            try log.append(creation)

            let unsupported = TaskSessionEvent(
                schemaVersion: TaskSessionEvent.currentSchemaVersion + 1,
                taskSessionID: sessionID,
                occurredAt: createdAt.addingTimeInterval(1),
                recordedAt: createdAt.addingTimeInterval(1),
                authority: .operatorAsserted,
                kind: .pinChanged(true)
            )
            let invalidAuthority = event(
                sessionID,
                at: createdAt.addingTimeInterval(2),
                authority: .conduitRecorded,
                kind: .pinChanged(true)
            )
            let mismatched = event(
                otherID,
                at: createdAt.addingTimeInterval(3),
                authority: .operatorAsserted,
                kind: .pinChanged(true)
            )
            try appendRawLines(
                [
                    try encode(unsupported),
                    try encode(invalidAuthority),
                    try encode(mismatched),
                    Data("not-json".utf8)
                ],
                to: log.url
            )
            let originalBytes = try Data(contentsOf: log.url)

            let read = log.read()
            XCTAssertEqual(read.events, [creation])
            XCTAssertEqual(
                read.diagnostics.map(\.kind),
                [
                    .unsupportedSchemaVersion,
                    .invalidAuthority,
                    .mismatchedTaskSessionID,
                    .malformedLine
                ]
            )
            XCTAssertEqual(
                read.diagnostics.compactMap(\.lineNumber),
                [2, 3, 4, 5]
            )

            let loaded = TaskSessionEventStore(
                directory: temporaryDirectory
            ).load()
            XCTAssertEqual(loaded.snapshots.map(\.id), [sessionID])
            XCTAssertEqual(
                loaded.diagnostics.map(\.kind),
                read.diagnostics.map(\.kind)
            )
            XCTAssertEqual(try Data(contentsOf: log.url), originalBytes)
        }
    }

    func testDuplicateEventIDsProjectIdempotentlyInFileOrder() throws {
        try withTemporaryDirectory { temporaryDirectory in
            let sessionID = taskID("00000000-0000-0000-0000-000000000040")
            let log = TaskSessionEventLog(
                directory: temporaryDirectory,
                taskSessionID: sessionID
            )
            let createdAt = Date(timeIntervalSince1970: 1_800_100_400)
            let duplicateID = UUID(
                uuidString: "00000000-0000-0000-0000-000000000041"
            )!
            let events = [
                event(
                    sessionID,
                    at: createdAt,
                    authority: .conduitRecorded,
                    kind: .created(metadata(title: "Idempotent task"))
                ),
                event(
                    sessionID,
                    id: duplicateID,
                    at: createdAt.addingTimeInterval(1),
                    authority: .operatorAsserted,
                    kind: .pinChanged(true)
                ),
                event(
                    sessionID,
                    id: duplicateID,
                    at: createdAt.addingTimeInterval(2),
                    authority: .operatorAsserted,
                    kind: .pinChanged(false)
                )
            ]
            for event in events {
                try log.append(event)
            }

            XCTAssertEqual(log.read().events, events)
            let store = TaskSessionEventStore(directory: temporaryDirectory)
            let firstLoad = store.load()
            let secondLoad = store.load()
            XCTAssertEqual(firstLoad, secondLoad)
            XCTAssertEqual(firstLoad.snapshots.count, 1)
            XCTAssertTrue(firstLoad.snapshots[0].isPinned)
            XCTAssertTrue(firstLoad.diagnostics.isEmpty)
        }
    }

    func testMissingDirectoryIsCleanEmptyAndReadDoesNotCreateIt() throws {
        try withTemporaryDirectory { temporaryDirectory in
            let missing = temporaryDirectory.appendingPathComponent("missing")
            let store = TaskSessionEventStore(directory: missing)

            XCTAssertTrue(store.logs().logs.isEmpty)
            XCTAssertTrue(store.logs().diagnostics.isEmpty)
            XCTAssertTrue(store.load().snapshots.isEmpty)
            XCTAssertTrue(store.load().diagnostics.isEmpty)

            let directRead = TaskSessionEventLog(
                directory: missing,
                taskSessionID: TaskSessionID()
            ).read()
            XCTAssertTrue(directRead.events.isEmpty)
            XCTAssertTrue(directRead.diagnostics.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        }
    }

    func testInvalidFilenameAndUnprojectableLogAreDiagnosed() throws {
        try withTemporaryDirectory { temporaryDirectory in
            let sessionID = taskID("00000000-0000-0000-0000-000000000050")
            let log = TaskSessionEventLog(
                directory: temporaryDirectory,
                taskSessionID: sessionID
            )
            try log.append(
                event(
                    sessionID,
                    at: Date(timeIntervalSince1970: 1_800_100_500),
                    authority: .operatorAsserted,
                    kind: .pinChanged(true)
                )
            )
            let invalidURL = temporaryDirectory
                .appendingPathComponent("not-a-task-id.jsonl")
            let invalidBytes = Data("preserve-invalid-name\n".utf8)
            try invalidBytes.write(to: invalidURL)

            let discovery = TaskSessionEventStore(
                directory: temporaryDirectory
            ).logs()
            XCTAssertEqual(discovery.logs.map(\.taskSessionID), [sessionID])
            XCTAssertEqual(
                discovery.diagnostics.map(\.kind),
                [.invalidFilename]
            )

            let loaded = TaskSessionEventStore(
                directory: temporaryDirectory
            ).load()
            XCTAssertTrue(loaded.snapshots.isEmpty)
            XCTAssertEqual(
                Set(loaded.diagnostics.map(\.kind)),
                Set([.invalidFilename, .unprojectableLog])
            )
            XCTAssertEqual(try Data(contentsOf: invalidURL), invalidBytes)
        }
    }

    private func taskID(_ uuidString: String) -> TaskSessionID {
        TaskSessionID(rawValue: UUID(uuidString: uuidString)!)
    }

    private func metadata(title: String) -> TaskSessionMetadata {
        TaskSessionMetadata(
            workspace: .project(
                ProjectWorkspaceScopeSnapshot(
                    rootURL: rootURL,
                    projectURL: projectURL,
                    fallbackTitle: "Conduit",
                    fallbackSlug: "conduit"
                )
            ),
            agentName: "Codex",
            defaultTitle: title
        )
    }

    private func event(
        _ taskSessionID: TaskSessionID,
        id: UUID = UUID(),
        at date: Date,
        authority: TaskSessionEventAuthority,
        kind: TaskSessionEventKind
    ) -> TaskSessionEvent {
        TaskSessionEvent(
            id: id,
            taskSessionID: taskSessionID,
            occurredAt: date,
            recordedAt: date,
            authority: authority,
            kind: kind
        )
    }

    private func encode(_ event: TaskSessionEvent) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(event)
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
            .appendingPathComponent("conduit-task-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory)
    }
}

private final class LockedTaskLogErrorMessages: @unchecked Sendable {
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
