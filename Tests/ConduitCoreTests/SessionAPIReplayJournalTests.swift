import XCTest
@testable import ConduitCore

final class SessionAPIReplayJournalTests: XCTestCase {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.appendingPathComponent("journal"))
    }
    private func call(_ journal: SessionAPIReplayJournal, key: String = "key",
                      fields: [String] = ["project", "prompt secret"],
                      action: () -> [String: Any]) -> [String: Any] {
        journal.perform(caller: "caller", operation: "conduit_send_prompt", key: key,
                        fields: fields, action: action)
    }
    private var result: [String: Any] {
        ["taskSessionID": UUID().uuidString, "eventID": UUID().uuidString,
         "delivered": false, "delivery": "queued"]
    }
    func testCreateReplayWithKnownPriorTaskAndRecreatedAdmissionController() throws {
        try fixture { url in
            let task = TaskSessionID()
            var journal: SessionAPIReplayJournal? = try .init(directory: url)
            var controller = MCPAdmissionController(policy: .conduitSessionAPI(writesEnabled: true))
            let now = Date()
            let resources = ConduitResourceSnapshot(
                availablePhysicalMemoryBytes: .known(value: 16_000_000_000, observedAt: now),
                ownedProcessTreeRSSBytes: .known(value: 0, observedAt: now),
                persistenceQueueCount: .known(value: 0, observedAt: now),
                persistenceQueueBytes: .known(value: 0, observedAt: now),
                promptQueueDepth: .known(value: 0, observedAt: now))
            var admissions = 0
            func create() -> [String: Any] {
                journal!.perform(caller: "caller", operation: "conduit_create_task", key: "create", fields: ["agent", "project", "/fixture/project", "objective"]) {
                    admissions += 1
                    let decision = controller.admitCreate(callerIdentity: "caller", dedupeIdentity: nil, resources: resources)
                    XCTAssertTrue(decision.shouldExecute)
                    if let id = decision.reservationID { controller.commitCreate(reservationID: id, taskSessionID: task) }
                    return ["taskSessionID": task.rawValue.uuidString, "objective_delivery_state": "queued"]
                }
            }
            XCTAssertNil(create()["error"])
            journal = nil
            controller = MCPAdmissionController(policy: .conduitSessionAPI(writesEnabled: true), initialLiveTaskSessionIDs: [task])
            journal = try .init(directory: url)
            let replay = create()
            XCTAssertEqual(replay["taskSessionID"] as? String, task.rawValue.uuidString)
            XCTAssertEqual(replay["objective_delivery_state"] as? String, "queued")
            XCTAssertEqual(replay["deduplicated"] as? Bool, true)
            XCTAssertEqual(admissions, 1)
        }
    }
    func testOutcomeSyncFailureNeverRedispatchesAfterRestart() throws {
        try fixture { url in
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            var synchronizations = 0
            var journal: SessionAPIReplayJournal? = try .init(directory: url, capacity: 2, synchronize: { fd in
                synchronizations += 1
                return synchronizations == 3 ? -1 : fsync(fd)
            })
            var effects = 0
            let original = result
            XCTAssertNotNil(call(journal!) { effects += 1; return original }["error"])
            XCTAssertEqual(effects, 1)
            journal = nil
            // A failed sync reports UNKNOWN to the first caller. If a complete
            // checksummed outcome survives reconstruction it proves the original
            // acceptance; otherwise retry must stay UNKNOWN. Neither dispatches.
            journal = try .init(directory: url)
            let replay = call(journal!) { effects += 1; return original }
            XCTAssertEqual(replay["eventID"] as? String, original["eventID"] as? String)
            XCTAssertEqual(replay["deduplicated"] as? Bool, true)
            XCTAssertEqual(effects, 1)
        }
    }
    func testPromptReplayAcrossReconstructionPreservesIdentityAndDoesNotDispatch() throws {
        try fixture { url in
            var original = result
            original["text"] = "prompt secret"
            original["credentials"] = "fixture secret token"
            var journal: SessionAPIReplayJournal? = try .init(directory: url)
            XCTAssertNil(call(journal!) { original }["error"])
            journal = nil
            journal = try .init(directory: url)
            let replay = call(journal!) { XCTFail("replay dispatched"); return [:] }
            XCTAssertEqual(replay["taskSessionID"] as? String, original["taskSessionID"] as? String)
            XCTAssertEqual(replay["eventID"] as? String, original["eventID"] as? String)
            XCTAssertEqual(replay["delivery"] as? String, "queued")
            XCTAssertEqual(replay["delivered"] as? Bool, false)
            XCTAssertEqual(replay["deduplicated"] as? Bool, true)
            for file in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                let data = try Data(contentsOf: file)
                XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("prompt secret"))
                if file.lastPathComponent != "owner" {
                    let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                    let encoded = try XCTUnwrap(envelope["bytes"] as? String)
                    let decoded = try XCTUnwrap(Data(base64Encoded: encoded))
                    let contents = String(decoding: decoded, as: UTF8.self)
                    XCTAssertFalse(contents.contains("prompt secret"))
                    XCTAssertFalse(contents.contains("fixture secret token"))
                }
            }
        }
    }
    func testChangedFieldsConflictAndCallerOperationAreSeparate() throws {
        try fixture { url in
            let journal = try SessionAPIReplayJournal(directory: url)
            _ = call(journal) { result }
            XCTAssertEqual(call(journal, fields: ["different project"]) {
                XCTFail("conflict dispatched"); return [:]
            }["replay_state"] as? String, "conflict")
            var effects = 0
            for (caller, operation) in [("other", "conduit_send_prompt"), ("caller", "conduit_create_task")] {
                _ = journal.perform(caller: caller, operation: operation, key: "key", fields: ["project"]) {
                    effects += 1; return self.result
                }
            }
            XCTAssertEqual(effects, 2)
        }
    }
    func testPendingCrashWindowAndMissingReservationBlock() throws {
        try fixture { url in
            var journal: SessionAPIReplayJournal? = try .init(directory: url)
            _ = call(journal!) { result }
            journal = nil
            let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            let outcome = try XCTUnwrap(files.first { $0.pathExtension == "outcome" })
            try FileManager.default.removeItem(at: outcome)
            journal = try .init(directory: url)
            XCTAssertEqual(call(journal!) { XCTFail("pending dispatched"); return [:] }["replay_state"] as? String, "unknown")
        }
        try fixture { url in
            var journal: SessionAPIReplayJournal? = try .init(directory: url)
            _ = call(journal!) { result }; journal = nil
            let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            try FileManager.default.removeItem(at: XCTUnwrap(files.first { $0.pathExtension == "intent" }))
            journal = try .init(directory: url)
            XCTAssertNotNil(call(journal!) { XCTFail("orphan dispatched"); return [:] }["error"])
        }
    }
    func testCorruptOversizedSymlinkAndWrongModeRecordsRefuse() throws {
        for mutation in 0..<5 {
            try fixture { url in
                let journal = try SessionAPIReplayJournal(directory: url)
                _ = call(journal) { result }
                let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                let receipt = try XCTUnwrap(files.first { $0.pathExtension == "outcome" })
                switch mutation {
                case 0: try Data("corrupt".utf8).write(to: receipt)
                case 1: try Data(repeating: 32, count: 20_000).write(to: receipt)
                case 2:
                    try FileManager.default.removeItem(at: receipt)
                    try FileManager.default.createSymbolicLink(at: receipt, withDestinationURL: url.appendingPathComponent("owner"))
                case 3: try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: receipt.path)
                default:
                    var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
                    envelope["digest"] = String(repeating: "0", count: 64)
                    try JSONSerialization.data(withJSONObject: envelope).write(to: receipt)
                }
                XCTAssertNotNil(call(journal) { XCTFail("unsafe receipt dispatched"); return [:] }["error"])
            }
        }
    }
    func testSecondOwnerDirectoryModeAndSymlinkRefused() throws {
        try fixture { url in
            let journal = try SessionAPIReplayJournal(directory: url)
            XCTAssertThrowsError(try SessionAPIReplayJournal(directory: url))
            let alias = url.deletingLastPathComponent().appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url)
            XCTAssertThrowsError(try SessionAPIReplayJournal(directory: alias))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            XCTAssertNotNil(call(journal) { XCTFail("wrong mode dispatched"); return [:] }["error"])
        }
    }
    func testCapacityNeverPrunesPendingAndDiskFailurePreventsEffects() throws {
        try fixture { url in
            let journal = try SessionAPIReplayJournal(directory: url, capacity: 1)
            _ = call(journal) { [:] } // action has no trustworthy outcome
            XCTAssertEqual(call(journal, key: "new") { XCTFail("capacity dispatched"); return [:] }["replay_state"] as? String, "capacity")
            XCTAssertEqual(call(journal) { XCTFail("pending dispatched"); return [:] }["replay_state"] as? String, "unknown")
        }
        try fixture { url in
            // Precreate so failure occurs while reserving, not creating directory.
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let journal = try SessionAPIReplayJournal(directory: url, capacity: 2, synchronize: { _ in -1 })
            XCTAssertNotNil(call(journal) { XCTFail("disk failure dispatched"); return [:] }["error"])
        }
    }
    func testConcurrentIdenticalCallsDispatchOnce() throws {
        try fixture { url in
            let journal = try SessionAPIReplayJournal(directory: url)
            let original = result
            let countLock = NSLock()
            var effects = 0
            DispatchQueue.concurrentPerform(iterations: 12) { _ in
                let payload = call(journal) {
                    countLock.lock(); effects += 1; countLock.unlock()
                    return original
                }
                XCTAssertEqual(payload["eventID"] as? String, original["eventID"] as? String)
            }
            XCTAssertEqual(effects, 1)
        }
    }
}
