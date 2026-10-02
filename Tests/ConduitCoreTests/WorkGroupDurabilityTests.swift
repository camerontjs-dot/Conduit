import XCTest
@testable import ConduitCore

final class WorkGroupDurabilityTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_700_000_000)

    func testExplicitCreationReplayAndCollisionPreserveExactLedger() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkGroupStore(directory: directory)
        let identity = WorkGroupID(rawValue: "exact-group")
        let first = try store.create(id: identity, name: "Fixture", createdAt: instant)
        let bytes = try Data(contentsOf: store.ledgerURL)
        let replay = try store.create(id: identity, name: "Fixture", createdAt: instant.addingTimeInterval(99))
        XCTAssertEqual(replay, first)
        XCTAssertEqual(try Data(contentsOf: store.ledgerURL), bytes)
        XCTAssertThrowsError(try store.create(id: identity, name: "Different intent")) {
            XCTAssertEqual($0 as? WorkGroupStoreError, .identityCollision(identity))
        }
        XCTAssertEqual(try Data(contentsOf: store.ledgerURL), bytes)
        XCTAssertEqual(try WorkGroupStore(directory: directory).list(), [first])
    }

    func testStaleEditsCannotOverwriteRestartedGroup() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstStore = WorkGroupStore(directory: directory)
        let group = try firstStore.create(name: "Fixture", createdAt: instant)
        let renamed = try firstStore.rename(id: group.id, name: "Current", expectedRevision: 0,
                                           updatedAt: instant.addingTimeInterval(1))
        let restarted = WorkGroupStore(directory: directory)
        let bytes = try Data(contentsOf: firstStore.ledgerURL)
        XCTAssertEqual(renamed.revision, 1)
        XCTAssertThrowsError(try restarted.addMember(groupID: group.id, reference: .conduitTask("task"),
                                                    role: .reviewer, expectedRevision: 0)) {
            XCTAssertEqual($0 as? WorkGroupStoreError, .staleRevision(expected: 0, actual: 1))
        }
        XCTAssertEqual(try Data(contentsOf: firstStore.ledgerURL), bytes)
        let replay = try restarted.rename(id: group.id, name: "Current", expectedRevision: 1)
        XCTAssertEqual(replay, renamed)
        XCTAssertEqual(try Data(contentsOf: firstStore.ledgerURL), bytes)
    }

    func testFrozenV1RecordWithoutAdditiveFieldsReopensWithoutRewrite() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let group = fixtureGroup()
        var record = try JSONSerialization.jsonObject(with: JSONEncoder().encode(group)) as! [String: Any]
        record.removeValue(forKey: "revision")
        record.removeValue(forKey: "ownerReferences")
        let bytes = try writeLedgerRecords([record], directory: directory)
        let reopened = WorkGroupStore(directory: directory)
        XCTAssertEqual(try reopened.group(id: group.id), group)
        XCTAssertEqual(try Data(contentsOf: reopened.ledgerURL), bytes)
    }

    func testTruncatedOuterFutureAndDuplicateMemberLedgersFailWithoutRewrite() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = WorkGroupStore(directory: directory)
        let duplicate = WorkGroupMember(reference: .conduitTask("task"), role: .reviewer, addedAt: instant)
        var group = fixtureGroup()
        group.members = [duplicate, duplicate]
        let record = try JSONSerialization.jsonObject(with: JSONEncoder().encode(group))
        let cases = [Data("{\"schemaVersion\":1,\"groups\":[".utf8),
                     try JSONSerialization.data(withJSONObject: ["schemaVersion": 999, "groups": []]),
                     try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "groups": [record]])]
        for bytes in cases {
            try bytes.write(to: store.ledgerURL)
            XCTAssertThrowsError(try store.list(includeArchived: true))
            XCTAssertThrowsError(try store.create(name: "Cannot replace invalid state"))
            XCTAssertEqual(try Data(contentsOf: store.ledgerURL), bytes)
        }
    }

    func testExplicitNullAdditiveFieldsCannotResetCoordinationState() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var group = fixtureGroup()
        group.revision = 9
        group.ownerReferences = [.init(kind: .contextSet, objectID: "exact-context-set")]
        let record = try JSONSerialization.jsonObject(with: JSONEncoder().encode(group)) as! [String: Any]
        let store = WorkGroupStore(directory: directory)
        for field in ["revision", "ownerReferences"] {
            var nullRecord = record
            nullRecord[field] = NSNull()
            let bytes = try writeLedgerRecords([nullRecord], directory: directory)
            if let path = ProcessInfo.processInfo.environment["CONDUIT_WORKGROUP_PRESSURE_EVIDENCE"] {
                let evidence = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
                try bytes.write(to: evidence.appendingPathComponent("explicit-null-" + field + ".json"))
            }
            XCTAssertThrowsError(try store.list())
            XCTAssertThrowsError(try store.rename(id: group.id, name: "Must not replace partial state"))
            XCTAssertEqual(try Data(contentsOf: store.ledgerURL), bytes)
        }
    }

    func testTypedTaskIdentityAndUUIDCaseShareOneCanonicalMember() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkGroupStore(directory: directory)
        let group = try store.create(name: "Fixture")
        let taskID = TaskSessionID(rawValue: UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!)
        let first = try store.addMember(groupID: group.id, reference: .conduitTask(taskID), role: .reviewer)
        let replay = try store.addMember(groupID: group.id, reference: .conduitTask(taskID.rawValue.uuidString), role: .reviewer)
        XCTAssertEqual(replay, first)
        XCTAssertEqual(replay.members.count, 1)
        var invalid = first
        invalid.members.append(.init(reference: .conduitTask(taskID.rawValue.uuidString), role: .observer))
        XCTAssertFalse(invalid.isWellFormed)
    }

    func testPercentColonAndUnicodeBytesCannotAliasProviderIdentities() {
        let pairs: [(String, String)] = [("a:b", "a%3Ab"), ("e\u{301}", "\u{e9}"), ("thread", "Thread")]
        for (first, second) in pairs {
            XCTAssertNotEqual(WorkGroupMemberReference.providerThread(providerID: first, threadID: "t").canonicalID,
                              WorkGroupMemberReference.providerThread(providerID: second, threadID: "t").canonicalID)
        }
        XCTAssertNil(WorkGroupMemberReference.providerThread(providerID: "p", threadID: "t\n").canonicalID)
        XCTAssertFalse(WorkGroupID(rawValue: " group").isWellFormed)
    }

    func testTypedOwnerNominationsReopenWithoutCopyingContextOrRuntimeTruth() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let contextSet = ContextSet(id: "fixture-context-set", objective: "Source objective is owned by context",
                                    entries: [], unresolvedPrerequisites: ["fixture prerequisite"])
        let references: [WorkGroupOwnerReference] = [
            .contextSet(contextSet),
            .init(kind: .executionWorkspace, objectID: "fixture-workspace", revisionIdentity: .known("exact-revision")),
            .init(kind: .routingDecision, objectID: "fixture-decision")
        ]
        let store = WorkGroupStore(directory: directory)
        let group = try store.create(name: "Fixture", ownerReferences: references)
        let reopened = try XCTUnwrap(WorkGroupStore(directory: directory).group(id: group.id))
        XCTAssertEqual(reopened.ownerReferences, references.sorted { $0.id < $1.id })
        XCTAssertEqual(reopened.ownerReferences.first { $0.kind == .contextSet }?.revisionIdentity, .unknown)
        let text = String(decoding: try Data(contentsOf: store.ledgerURL), as: UTF8.self)
        XCTAssertFalse(text.contains("Source objective is owned by context"))
        XCTAssertFalse(text.contains("fixture prerequisite"))
        XCTAssertFalse(text.contains("entries"))
        XCTAssertFalse(text.contains("provider_entitlement"))
    }

    func testInvalidKnownPathsAndDuplicateNominationsCannotPartiallyMutateStore() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkGroupStore(directory: directory)
        let group = try store.create(name: "Fixture")
        let bytes = try Data(contentsOf: store.ledgerURL)
        XCTAssertThrowsError(try store.setPrimary(id: group.id,
            primary: .init(repositoryRoot: .known("relative/repository"))))
        let reference = WorkGroupOwnerReference(kind: .contextSet, objectID: "context")
        XCTAssertThrowsError(try store.setOwnerReferences(id: group.id, references: [reference, reference]))
        XCTAssertThrowsError(try store.setOwnerReferences(id: group.id,
            references: [.init(kind: .routingDecision, objectID: " unknown ")]))
        XCTAssertEqual(try Data(contentsOf: store.ledgerURL), bytes)
    }

    func testRevisionOverflowFailsWithoutTrapOrLedgerRewrite() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var group = fixtureGroup()
        group.revision = Int.max
        let record = try JSONSerialization.jsonObject(with: JSONEncoder().encode(group))
        let bytes = try writeLedgerRecords([record], directory: directory)
        let store = WorkGroupStore(directory: directory)
        XCTAssertThrowsError(try store.rename(id: group.id, name: "Changed"))
        XCTAssertEqual(try Data(contentsOf: store.ledgerURL), bytes)
    }

    func testLedgerAndLockSymlinksRejectWithoutWritingReferencedFixture() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let external = directory.appendingPathComponent("referenced-owner")
        let bytes = Data("protected fixture".utf8)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: external)
        for filename in ["work-groups-v1.json", "work-groups-v1.lock"] {
            let root = directory.appendingPathComponent(filename + "-store")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(filename), withDestinationURL: external)
            let store = WorkGroupStore(directory: root)
            XCTAssertThrowsError(try store.create(name: "Must not follow link"))
            if filename.hasSuffix("json") { XCTAssertThrowsError(try store.list()) }
            XCTAssertEqual(try Data(contentsOf: external), bytes)
        }
    }

    func testDirectoryAliasesShareOneStoreSerializationBoundary() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let real = directory.appendingPathComponent("real")
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let stores = [WorkGroupStore(directory: real), WorkGroupStore(directory: alias)]
        XCTAssertEqual(stores[0].lockURL, stores[1].lockURL)
        let resultLock = NSLock()
        var errors: [String] = []
        DispatchQueue.concurrentPerform(iterations: 24) { index in
            do {
                _ = try stores[index % 2].create(id: .init(rawValue: "group-\(index)"), name: "Fixture")
            } catch {
                resultLock.lock()
                errors.append(String(describing: error))
                resultLock.unlock()
            }
        }
        XCTAssertEqual(errors, [])
        XCTAssertEqual(try stores[0].list().count, 24)
    }

    func testFreshWrongAndReplayedComposerDescriptorsNameTheirActualGroupAndTarget() {
        let target = WorkGroupMemberReference.providerThread(providerID: "provider", threadID: "thread")
        var group = fixtureGroup()
        group.members = [.init(reference: target, role: .qualifier, addedAt: instant)]
        let destination = WorkGroupComposerDestination(group: group, target: target, targetTitle: "Qualifier")
        XCTAssertTrue(destination.breadcrumb.contains(group.id.rawValue))
        XCTAssertTrue(destination.breadcrumb.contains("provider:provider:thread"))
        XCTAssertTrue(destination.breadcrumb.contains("role: qualifier"))
        XCTAssertEqual(WorkGroupTargetValidator.warnings(group: group, destination: destination, observation: nil), [])
        var different = group
        different.id = .init(rawValue: "another-group")
        XCTAssertEqual(WorkGroupTargetValidator.warnings(group: different, destination: destination, observation: nil),
                       [.wrongGroup(expected: different.id, actual: group.id)])
        group.revision += 1
        group.name = "Renamed"
        XCTAssertEqual(WorkGroupTargetValidator.warnings(group: group, destination: destination, observation: nil),
                       [.staleDestination(expected: 0, actual: 1), .staleGroupName])
        let unknown = WorkGroupComposerDestination(groupID: group.id, groupName: group.name, target: target, targetTitle: "Qualifier")
        XCTAssertEqual(WorkGroupTargetValidator.warnings(group: group, destination: unknown, observation: nil),
                       [.unknownDestinationRevision])
    }

    func testWrongObservationNeverContributesAnotherTasksRepositoryFacts() {
        let target = WorkGroupMemberReference.conduitTask("target")
        var group = fixtureGroup()
        group.members = [.init(reference: target, role: .reviewer, addedAt: instant)]
        group.primary.repositoryRoot = .known("/fixture/expected")
        let wrong = WorkGroupThreadObservation(reference: .conduitTask("other"), displayTitle: "Other",
                                               repositoryRoot: .known("/fixture/different"))
        XCTAssertEqual(WorkGroupTargetValidator.warnings(group: group, target: target, observation: wrong),
                       [.observationTargetMismatch(expected: "task:target", actual: "task:other")])
        let malformed = WorkGroupThreadObservation(reference: target, displayTitle: "Target", unseenCount: .known(-1))
        XCTAssertEqual(WorkGroupTargetValidator.warnings(group: group, target: target, observation: malformed), [.malformedObservation])
        let snapshot = WorkGroupThreadRailProjection.snapshot(group: group, observations: [malformed])
        XCTAssertEqual(snapshot.items.first?.availability, .malformed)
        XCTAssertNil(snapshot.items.first?.observation)
        XCTAssertEqual(snapshot.diagnostics, [.malformedObservation("task:target")])
    }

    func testProjectionDuplicateAndMalformedGroupRemainExplicitWithoutTrap() {
        let target = WorkGroupMemberReference.conduitTask("target")
        var group = fixtureGroup()
        group.members = [.init(reference: target, role: .observer, addedAt: instant)]
        let observation = WorkGroupThreadObservation(reference: target, displayTitle: "Target")
        let duplicate = WorkGroupThreadRailProjection.snapshot(group: group, observations: [observation, observation])
        XCTAssertEqual(duplicate.items.first?.availability, .ambiguous)
        XCTAssertNil(duplicate.items.first?.observation)
        XCTAssertEqual(duplicate.diagnostics, [.ambiguousObservation("task:target")])
        group.schemaVersion = 999
        XCTAssertEqual(WorkGroupThreadRailProjection.snapshot(group: group, observations: [observation]).diagnostics,
                       [.malformedGroup])
        XCTAssertEqual(WorkGroupThreadRailProjection.items(group: group, observations: [observation]), [])
        XCTAssertEqual(WorkGroupTargetValidator.warnings(group: group, target: target, observation: observation), [.malformedGroup])
    }

    func testCanonicalTaskProjectionAndGroupMutationsPreserveTaskLogAndGlobalInventory() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let taskDirectory = directory.appendingPathComponent("canonical-tasks")
        let taskID = TaskSessionID(rawValue: UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!)
        let log = TaskSessionEventLog(directory: taskDirectory, taskSessionID: taskID)
        let metadata = TaskSessionMetadata(workspace: .root(.init(rootURL: URL(fileURLWithPath: "/fixture/navigation"))),
                                           agentName: "Configured profile", defaultTitle: "Fixture task")
        try log.append(.init(taskSessionID: taskID, occurredAt: instant, recordedAt: instant,
                             authority: .conduitRecorded, kind: .created(metadata)))
        try log.append(.init(taskSessionID: taskID, occurredAt: instant, recordedAt: instant,
                             authority: .operatorAsserted, kind: .pinChanged(true)))
        let taskStore = TaskSessionEventStore(directory: taskDirectory)
        let global = taskStore.load()
        let bytes = try Data(contentsOf: log.url)
        let task = try XCTUnwrap(global.snapshots.first)
        let store = WorkGroupStore(directory: directory.appendingPathComponent("groups"))
        let group = try store.create(name: "Fixture")
        let attached = try store.addMember(groupID: group.id, reference: .conduitTask(taskID), role: .implementer)
        let row = try XCTUnwrap(WorkGroupThreadRailProjection.items(group: attached, tasks: global.snapshots).first)
        XCTAssertEqual(row.observation?.isPinned.value, true)
        XCTAssertEqual(row.observation?.configuredAgentLabel.value, "Configured profile")
        XCTAssertEqual(row.observation?.providerLabel, .unknown)
        XCTAssertEqual(row.observation?.repositoryRoot, .unknown)
        XCTAssertEqual(row.observation?.worktreePath, .unknown)
        XCTAssertEqual(row.observation?.unseenCount, .unknown)
        XCTAssertEqual(row.observation?.lastOperatorMessageAt, .unknown)
        XCTAssertEqual(row.observation?.lastAgentMessageAt, .unknown)
        XCTAssertEqual(row.observation?.lastActivityAt.value, task.lastActivityAt)
        _ = try store.removeMember(groupID: group.id, reference: .conduitTask(taskID))
        _ = try store.setArchived(id: group.id, archived: true)
        _ = try store.setArchived(id: group.id, archived: false)
        XCTAssertEqual(taskStore.load(), global)
        XCTAssertEqual(try Data(contentsOf: log.url), bytes)
        XCTAssertEqual(try store.list().map(\.id), [group.id])
    }

    private func fixtureGroup() -> ConduitCore.WorkGroup {
        .init(id: .init(rawValue: "fixture-group"), name: "Fixture", createdAt: instant, updatedAt: instant)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("work-group-durable-\(UUID().uuidString)", isDirectory: true)
    }

    private func writeLedgerRecords(_ records: [Any], directory: URL) throws -> Data {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bytes = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "groups": records], options: [.sortedKeys])
        try bytes.write(to: directory.appendingPathComponent("work-groups-v1.json"))
        return bytes
    }
}
