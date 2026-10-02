import XCTest
@testable import ConduitCore

final class WorkGroupPressureTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_700_000_000)

    func testUnsupportedInnerSchemaFailsClosedAndPreservesLedger() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var group = fixtureGroup()
        group.schemaVersion = 999
        let bytes = try writeLedger([group], directory: directory, evidence: "unsupported-inner-schema")
        let store = WorkGroupStore(directory: directory)
        XCTAssertThrowsError(try store.list())
        XCTAssertThrowsError(try store.create(name: "Must not replace corruption"))
        XCTAssertEqual(try Data(contentsOf: store.ledgerURL), bytes)
    }

    func testDuplicateGroupIdentityFailsClosed() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let group = fixtureGroup()
        _ = try writeLedger([group, group], directory: directory, evidence: "duplicate-group")
        XCTAssertThrowsError(try WorkGroupStore(directory: directory).list())
    }

    func testMalformedPersistedMemberFailsClosed() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var group = fixtureGroup()
        group.members = [.init(reference: .init(kind: .providerThread), role: .reviewer, addedAt: instant)]
        _ = try writeLedger([group], directory: directory, evidence: "malformed-member")
        XCTAssertThrowsError(try WorkGroupStore(directory: directory).list())
    }

    func testContradictoryReferenceFieldsFailClosed() {
        let reference = WorkGroupMemberReference(kind: .conduitTask, taskSessionID: "task", providerID: "provider", threadID: "thread")
        XCTAssertFalse(reference.isWellFormed)
        XCTAssertNil(reference.canonicalID)
    }

    func testProviderDelimiterCannotCollapseDifferentIdentities() {
        let first = WorkGroupMemberReference.providerThread(providerID: "a:b", threadID: "c")
        let second = WorkGroupMemberReference.providerThread(providerID: "a", threadID: "b:c")
        XCTAssertTrue(first.isWellFormed)
        XCTAssertTrue(second.isWellFormed)
        XCTAssertNotEqual(first.canonicalID, second.canonicalID)
    }

    func testSurroundingWhitespaceCannotAliasCanonicalTask() {
        XCTAssertNil(WorkGroupMemberReference.conduitTask(" task ").canonicalID)
    }

    func testObservationForDifferentTaskCannotAuthorizeTargetComparison() {
        let target = WorkGroupMemberReference.conduitTask("target")
        var group = fixtureGroup()
        group.primary.repositoryRoot = .known("/fixture/repository")
        group.members = [.init(reference: target, role: .implementer, addedAt: instant)]
        let observation = WorkGroupThreadObservation(reference: .conduitTask("other"), displayTitle: "Other", repositoryRoot: .known("/fixture/repository"))
        XCTAssertFalse(WorkGroupTargetValidator.warnings(group: group, target: target, observation: observation).isEmpty)
    }

    func testArchivedGroupProducesTargetGuardWarning() {
        let target = WorkGroupMemberReference.conduitTask("target")
        var group = fixtureGroup()
        group.archived = true
        group.members = [.init(reference: target, role: .implementer, addedAt: instant)]
        XCTAssertFalse(WorkGroupTargetValidator.warnings(group: group, target: target, observation: nil).isEmpty)
    }

    func testBreadcrumbIncludesExactGroupAndProviderThreadIdentity() {
        let target = WorkGroupMemberReference.providerThread(providerID: "provider", threadID: "thread")
        let destination = WorkGroupComposerDestination(groupID: .init(rawValue: "exact-group"), groupName: "Fixture", target: target, targetTitle: "Qualification")
        XCTAssertTrue(destination.breadcrumb.contains("exact-group"))
        XCTAssertTrue(destination.breadcrumb.contains(try! XCTUnwrap(target.canonicalID)))
    }

    func testReplayedIdenticalMembershipDoesNotChangeUpdatedIdentity() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkGroupStore(directory: directory)
        let group = try store.create(name: "Fixture", createdAt: instant)
        let first = try store.addMember(groupID: group.id, reference: .conduitTask("task"), role: .reviewer, addedAt: instant.addingTimeInterval(1))
        let replay = try store.addMember(groupID: group.id, reference: .conduitTask("task"), role: .reviewer, addedAt: instant.addingTimeInterval(2))
        XCTAssertEqual(replay, first)
    }

    func testEqualNameAndDateListHasStableGroupIdentityTieBreak() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = fixtureGroup(id: "group-b")
        let second = fixtureGroup(id: "group-a")
        _ = try writeLedger([first, second], directory: directory, evidence: "list-order")
        XCTAssertEqual(try WorkGroupStore(directory: directory).list().map { $0.id.rawValue }, ["group-a", "group-b"])
    }

    func testTwoStoreInstancesDoNotLoseConcurrentGroupWrites() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = [WorkGroupStore(directory: directory), WorkGroupStore(directory: directory)]
        let resultLock = NSLock()
        var errors: [String] = []
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            do { _ = try stores[index % 2].create(name: "Fixture \(index)") }
            catch { resultLock.lock(); errors.append(String(describing: error)); resultLock.unlock() }
        }
        let groups = try WorkGroupStore(directory: directory).list()
        let bytes = try Data(contentsOf: stores[0].ledgerURL)
        try preserve(bytes, name: "two-store-final")
        XCTAssertEqual(errors, [])
        XCTAssertEqual(groups.count, 32)
        XCTAssertEqual(Set(groups.map { $0.name }).count, 32)
    }

    func testDuplicateObservationDoesNotTrapOrPickAnAuthority() {
        let target = WorkGroupMemberReference.conduitTask("target")
        var group = fixtureGroup()
        group.members = [.init(reference: target, role: .reviewer, addedAt: instant)]
        let first = WorkGroupThreadObservation(reference: target, displayTitle: "First", unseenCount: .known(1))
        let second = WorkGroupThreadObservation(reference: target, displayTitle: "Conflicting", unseenCount: .known(99))
        let rows = WorkGroupThreadRailProjection.items(group: group, observations: [first, second])
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows.first?.observation)
    }

    private func fixtureGroup(id: String = "fixture-group") -> ConduitCore.WorkGroup {
        .init(id: .init(rawValue: id), name: "Fixture", createdAt: instant, updatedAt: instant)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("work-group-pressure-\(UUID().uuidString)", isDirectory: true)
    }

    private func writeLedger(_ groups: [ConduitCore.WorkGroup], directory: URL, evidence: String) throws -> Data {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let records = try groups.map { try JSONSerialization.jsonObject(with: encoder.encode($0)) }
        let bytes = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "groups": records], options: [.sortedKeys])
        try bytes.write(to: directory.appendingPathComponent("work-groups-v1.json"))
        try preserve(bytes, name: evidence)
        return bytes
    }

    private func preserve(_ data: Data, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["CONDUIT_WORKGROUP_PRESSURE_EVIDENCE"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name + ".json"))
    }
}
