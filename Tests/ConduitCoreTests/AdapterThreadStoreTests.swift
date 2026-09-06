import XCTest
@testable import ConduitCore

final class AdapterThreadStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("adapter-threads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func store() -> AdapterThreadStore { AdapterThreadStore(directory: dir) }

    func testSaveThenRead() {
        let id = TaskSessionID(rawValue: UUID())
        store().save(taskSessionID: id, backend: "app-server", threadID: "t-1")
        XCTAssertEqual(store().threadID(for: id), "t-1")
        XCTAssertEqual(store().supersededThreadIDs(for: id), [])
    }

    /// The self-erasing half of the silent-restart defect: a replacement id
    /// used to land on top of the only pointer to the real history.
    func testAReplacementThreadDoesNotDestroyThePriorPointer() {
        let id = TaskSessionID(rawValue: UUID())
        store().save(taskSessionID: id, backend: "app-server", threadID: "t-old")
        store().save(taskSessionID: id, backend: "app-server", threadID: "t-new")

        XCTAssertEqual(store().threadID(for: id), "t-new", "live thread is the new one")
        XCTAssertEqual(
            store().supersededThreadIDs(for: id), ["t-old"],
            "the route back to real history must survive the failed recovery"
        )
    }

    func testRepeatedSaveOfTheSameThreadRecordsNoHistory() {
        let id = TaskSessionID(rawValue: UUID())
        for _ in 0..<3 {
            store().save(taskSessionID: id, backend: "app-server", threadID: "t-1")
        }
        XCTAssertEqual(store().supersededThreadIDs(for: id), [])
    }

    func testHistoryIsMostRecentFirstAndDoesNotRepeatTheLiveThread() {
        let id = TaskSessionID(rawValue: UUID())
        for t in ["t-1", "t-2", "t-3"] {
            store().save(taskSessionID: id, backend: "app-server", threadID: t)
        }
        XCTAssertEqual(store().threadID(for: id), "t-3")
        XCTAssertEqual(store().supersededThreadIDs(for: id), ["t-2", "t-1"])
    }

    func testReturningToAnEarlierThreadDoesNotListItTwice() {
        let id = TaskSessionID(rawValue: UUID())
        for t in ["t-1", "t-2", "t-1"] {
            store().save(taskSessionID: id, backend: "app-server", threadID: t)
        }
        XCTAssertEqual(store().threadID(for: id), "t-1")
        XCTAssertEqual(
            store().supersededThreadIDs(for: id), ["t-2"],
            "the live thread is never also its own history"
        )
    }

    func testHistoryIsBounded() {
        let id = TaskSessionID(rawValue: UUID())
        for i in 0...(AdapterThreadRecord.supersededLimit + 3) {
            store().save(taskSessionID: id, backend: "app-server", threadID: "t-\(i)")
        }
        XCTAssertLessThanOrEqual(
            store().supersededThreadIDs(for: id).count,
            AdapterThreadRecord.supersededLimit
        )
    }

    func testTasksDoNotShareHistory() {
        let a = TaskSessionID(rawValue: UUID())
        let b = TaskSessionID(rawValue: UUID())
        store().save(taskSessionID: a, backend: "app-server", threadID: "a-1")
        store().save(taskSessionID: a, backend: "app-server", threadID: "a-2")
        store().save(taskSessionID: b, backend: "http-server", threadID: "b-1")

        XCTAssertEqual(store().supersededThreadIDs(for: a), ["a-1"])
        XCTAssertEqual(store().supersededThreadIDs(for: b), [])
        XCTAssertEqual(store().threadID(for: b), "b-1")
    }

    /// `load()` decodes the whole map with `try?`, so one unreadable record
    /// returns an EMPTY store and the next save writes a file containing only
    /// itself. A record written before this field existed must still decode.
    func testRecordsWrittenBeforeThisFieldExistedStillDecode() throws {
        let legacy = """
        {
          "\(UUID().uuidString.lowercased())" : {
            "backend" : "app-server",
            "threadID" : "t-legacy",
            "updatedAt" : "2026-09-05T06:31:48Z"
          }
        }
        """
        try legacy.write(
            to: dir.appendingPathComponent("adapter-threads.json"),
            atomically: true,
            encoding: .utf8
        )
        let loaded = store().load()
        XCTAssertEqual(loaded.count, 1, "a legacy file must not decode as empty")
        XCTAssertEqual(loaded.values.first?.threadID, "t-legacy")
        XCTAssertEqual(loaded.values.first?.supersededThreadIDs, [])
    }

    func testALegacyFileSurvivesASaveForADifferentTask() throws {
        let keep = UUID().uuidString.lowercased()
        let legacy = """
        {
          "\(keep)" : {
            "backend" : "app-server",
            "threadID" : "t-legacy",
            "updatedAt" : "2026-09-05T06:31:48Z"
          }
        }
        """
        try legacy.write(
            to: dir.appendingPathComponent("adapter-threads.json"),
            atomically: true,
            encoding: .utf8
        )
        store().save(
            taskSessionID: TaskSessionID(rawValue: UUID()),
            backend: "http-server",
            threadID: "t-new"
        )
        XCTAssertEqual(store().load().count, 2, "the existing pointer must not be dropped")
        XCTAssertEqual(store().load()[keep]?.threadID, "t-legacy")
    }

    func testAnUntouchedRecordKeepsItsOnDiskShape() {
        let id = TaskSessionID(rawValue: UUID())
        store().save(taskSessionID: id, backend: "app-server", threadID: "t-1")
        let text = (try? String(
            contentsOf: dir.appendingPathComponent("adapter-threads.json"), encoding: .utf8
        )) ?? ""
        XCTAssertFalse(
            text.contains("supersededThreadIDs"),
            "an empty history is omitted, so existing files are unchanged"
        )
    }
}
