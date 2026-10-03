import Foundation
import XCTest
@testable import ConduitCore

final class ContextSetStoreTests: XCTestCase {
    private func temporaryStore(_ body: (URL, ContextSetStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("context-set-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root, ContextSetStore(directory: root))
    }

    private func definition(_ id: String = "set-A", objective: String = "Inspect exact context") -> ContextSet {
        ContextSet(id: id, objective: objective, taskIdentity: "task-A",
            repositoryIdentity: ContextRepositoryIdentity(repository: "repository", scopePath: "scope", branch: "main", commitSHA: "exact-commit"),
            entries: [ContextSetEntry(item: AgentContextItem(id: "source", title: "Pinned source", kind: .file,
                authority: .operatorPinned, sourceReference: "reference-only", revisionIdentity: "source-revision", isPinned: true, freshness: .unknown),
                disposition: .mandatory, inclusionReasons: [ContextInclusionReason(.operatorPin)]),
                ContextSetEntry(item: AgentContextItem(id: "nomination", title: "Related", kind: .semanticNomination,
                    authority: .mindGraphNomination, sourceReference: "never-read", freshness: .stale(reason: "identity unavailable")),
                    disposition: .nominated, inclusionReasons: [ContextInclusionReason(.semanticNomination)])],
            unresolvedPrerequisites: ["source freshness"], retrieverVersions: [ContextComponentVersion(name: "retriever", version: "fixture-v1")])
    }

    private var rules: [ContextSetDynamicRule] {
        [ContextSetDynamicRule(id: "semantic-rule", source: .semanticQuery, scopeReference: "explicit-scope", query: "objective"),
         ContextSetDynamicRule(id: "git-rule", source: .gitWorkingTree, scopeReference: "explicit-repository")]
    }

    func testReadOnlyMissingStateCreatesNothing() throws {
        try temporaryStore { root, store in
            XCTAssertEqual(try store.read().history, [])
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        }
    }

    func testExactDefinitionAndDynamicRulesSurviveRestart() throws {
        try temporaryStore { root, store in
            let original = definition()
            let first = try store.save(original, dynamicRules: rules, at: Date(timeIntervalSince1970: 42.125))
            let recovered = try ContextSetStore(directory: root).read()
            XCTAssertEqual(recovered.history, [first])
            XCTAssertEqual(recovered.latest(contextSetID: original.id)?.contextSet, original)
            XCTAssertEqual(recovered.latest(contextSetID: original.id)?.dynamicRules, rules)
            XCTAssertEqual(first.recordedAt, Date(timeIntervalSince1970: 42.125))
            XCTAssertEqual(first.contextSet.entries[1].item.authority, .mindGraphNomination)
            XCTAssertEqual(first.contextSet.entries[1].item.freshness, .stale(reason: "identity unavailable"))
        }
    }

    func testRevisePreservesTheOldPhysicalPrefixAndExactParent() throws {
        try temporaryStore { root, store in
            let first = try store.save(definition())
            let file = root.appendingPathComponent(ContextSetStore.filename)
            let before = try Data(contentsOf: file)
            let second = try store.save(definition(objective: "Changed objective"), dynamicRules: rules, expectedRevision: first.revisionID)
            XCTAssertTrue(try Data(contentsOf: file).starts(with: before))
            XCTAssertEqual(second.parentRevisionID, first.revisionID)
            XCTAssertEqual(second.sequence, 2)
            XCTAssertEqual(try store.read().history, [first, second])
        }
    }

    func testCreateCollisionAndStaleRevisionRefuseWithoutChangingBytes() throws {
        try temporaryStore { root, store in
            let first = try store.save(definition())
            let second = try store.save(definition(objective: "Second"), expectedRevision: first.revisionID)
            let file = root.appendingPathComponent(ContextSetStore.filename)
            let before = try Data(contentsOf: file)
            XCTAssertThrowsError(try store.save(definition()))
            XCTAssertThrowsError(try store.save(definition(objective: "Stale"), expectedRevision: first.revisionID))
            XCTAssertThrowsError(try store.retire(contextSetID: "set-A", expectedRevision: first.revisionID))
            XCTAssertEqual(try Data(contentsOf: file), before)
            XCTAssertEqual(try store.read().latest(contextSetID: "set-A"), second)
        }
    }

    func testWrongSetRevisionCannotAuthorizeAnotherSet() throws {
        try temporaryStore { root, store in
            let first = try store.save(definition("A"))
            _ = try store.save(definition("B"))
            let before = try Data(contentsOf: root.appendingPathComponent(ContextSetStore.filename))
            XCTAssertThrowsError(try store.save(definition("B", objective: "Wrong owner"), expectedRevision: first.revisionID))
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(ContextSetStore.filename)), before)
        }
    }

    func testMissingExpectedRevisionAndMissingRetirementCreateNothing() throws {
        try temporaryStore { root, store in
            XCTAssertThrowsError(try store.save(definition(), expectedRevision: UUID()))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
            XCTAssertThrowsError(try store.retire(contextSetID: "unknown", expectedRevision: UUID()))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        }
    }

    func testRetirementPreservesDefinitionAndPreventsIdentityReuse() throws {
        try temporaryStore { _, store in
            let first = try store.save(definition(), dynamicRules: rules)
            let retired = try store.retire(contextSetID: "set-A", expectedRevision: first.revisionID)
            XCTAssertEqual(retired.contextSet, first.contextSet)
            XCTAssertEqual(retired.dynamicRules, first.dynamicRules)
            XCTAssertEqual(retired.state, .retired)
            XCTAssertEqual(try store.read().history, [first, retired])
            XCTAssertEqual(try store.read().activeRevisions, [])
            XCTAssertThrowsError(try store.save(definition(), expectedRevision: retired.revisionID))
            XCTAssertThrowsError(try store.save(definition()))
        }
    }

    func testRulesStayUnresolvedInTheExistingCompilerInput() throws {
        try temporaryStore { _, store in
            let first = try store.save(definition(), dynamicRules: rules)
            XCTAssertEqual(first.compilerInput.entries, first.contextSet.entries)
            XCTAssertEqual(first.compilerInput.taskIdentity, first.contextSet.taskIdentity)
            XCTAssertEqual(first.compilerInput.repositoryIdentity, first.contextSet.repositoryIdentity)
            XCTAssertEqual(first.compilerInput.retrieverVersions, first.contextSet.retrieverVersions)
            XCTAssertEqual(first.compilerInput.unresolvedPrerequisites.count, 3)
            XCTAssertTrue(first.compilerInput.unresolvedPrerequisites.contains { $0.contains("semantic-rule") })
            XCTAssertTrue(first.compilerInput.unresolvedPrerequisites.contains("source freshness"))
            let manifest = ContextManifestCompiler.compile(contextSet: first.compilerInput,
                destination: ContextDestination(), budget: ContextBudget())
            XCTAssertEqual(Set(manifest.unresolvedPrerequisites), Set(first.compilerInput.unresolvedPrerequisites))
            XCTAssertEqual(manifest.entries.count, 2)
            XCTAssertEqual(manifest.entries.first { $0.contextItemID == "nomination" }?.deliveryState, .nominationOnly)
            XCTAssertEqual(manifest.entries.first { $0.contextItemID == "nomination" }?.authority, .mindGraphNomination)
            XCTAssertEqual(manifest.deliveredEntries.map(\.contextItemID), ["source"])
            XCTAssertEqual(manifest.destination, ContextDestination())
        }
    }

    private func assertMutationBlocks(_ transform: (Data) throws -> Data) throws {
        try temporaryStore { root, store in
            let first = try store.save(definition(), dynamicRules: rules)
            let file = root.appendingPathComponent(ContextSetStore.filename)
            let changed = try transform(Data(contentsOf: file))
            try changed.write(to: file)
            XCTAssertThrowsError(try store.read())
            XCTAssertThrowsError(try store.save(definition(objective: "Attempted repair"), expectedRevision: first.revisionID))
            XCTAssertEqual(try Data(contentsOf: file), changed)
        }
    }

    func testPartialTailBlocksTheWholeHistoryAndPreservesBytes() throws {
        try assertMutationBlocks { $0 + Data("{\"sequence\":2".utf8) }
    }

    func testMalformedCompleteLineBlocksRatherThanAdoptingValidPrefix() throws {
        try assertMutationBlocks { $0 + Data("{invalid}\n".utf8) }
    }

    func testEmptyRecordBlocksRatherThanSilentlySkipping() throws {
        try assertMutationBlocks { $0 + Data("\n".utf8) }
    }

    func testDuplicateEscapedEquivalentTopLevelMemberBlocks() throws {
        try assertMutationBlocks { bytes in
            Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\"sequence\":1", with: "\"sequence\":1,\"sequ\\u0065nce\":1").utf8)
        }
    }

    func testDuplicateNestedAuthorityMemberBlocks() throws {
        try assertMutationBlocks { bytes in
            Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\"authority\":\"mindGraphNomination\"", with: "\"authority\":\"mindGraphNomination\",\"authority\":\"filesystemSource\"").utf8)
        }
    }

    private func replacingRecordField(_ name: String, with value: Any) throws {
        try assertMutationBlocks { bytes in
            var json = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            json[name] = value
            return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) + Data([0x0a])
        }
    }

    func testUnsupportedSchemaVersionBlocks() throws { try replacingRecordField("schemaVersion", with: 2) }
    func testWrongSequenceBlocks() throws { try replacingRecordField("sequence", with: 2) }
    func testForeignParentRevisionBlocks() throws { try replacingRecordField("parentRevisionID", with: UUID().uuidString) }
    func testRetirementWithoutPredecessorBlocks() throws { try replacingRecordField("state", with: "retired") }

    func testDuplicateRevisionIdentityBlocks() throws {
        try assertMutationBlocks { bytes in
            var json = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            json["sequence"] = 2
            json["parentRevisionID"] = json["revisionID"]
            return bytes + (try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) + Data([0x0a])
        }
    }

    func testInvalidDefinitionsCreateNoState() throws {
        try temporaryStore { root, store in
            XCTAssertThrowsError(try store.save(definition(" ")))
            let set = definition()
            let collision = ContextSet(id: set.id, objective: set.objective, entries: [set.entries[0], set.entries[0]])
            XCTAssertThrowsError(try store.save(collision))
            XCTAssertThrowsError(try store.save(set, dynamicRules: [rules[0], rules[0]]))
            XCTAssertThrowsError(try store.save(set, dynamicRules: [ContextSetDynamicRule(id: "q", source: .semanticQuery, scopeReference: "scope")]))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        }
    }

    func testOpaqueIdentityIncludingDelimiterAndNewlineStaysExact() throws {
        try temporaryStore { _, store in
            let id = "set|scope\nλ"
            let saved = try store.save(definition(id))
            XCTAssertEqual(try store.read().latest(contextSetID: id), saved)
            XCTAssertEqual(try store.read().history.count, 1)
        }
    }

    func testSymlinkDirectoryAndLedgerAreRefusedWithoutFollowing() throws {
        try temporaryStore { root, _ in
            let target = root.appendingPathComponent("target")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
            let link = root.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            XCTAssertThrowsError(try ContextSetStore(directory: link).save(definition()))
            let sentinel = target.appendingPathComponent("sentinel")
            try Data("protected".utf8).write(to: sentinel)
            try FileManager.default.createSymbolicLink(at: target.appendingPathComponent(ContextSetStore.filename), withDestinationURL: sentinel)
            XCTAssertThrowsError(try ContextSetStore(directory: target).read())
            XCTAssertThrowsError(try ContextSetStore(directory: target).save(definition()))
            XCTAssertEqual(try String(contentsOf: sentinel), "protected")
        }
    }

    func testExistingNonprivateDirectoryRefusesWithoutChangingPermissionsOrCreatingLedger() throws {
        try temporaryStore { root, store in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: root.path)
            XCTAssertThrowsError(try store.save(definition()))
            XCTAssertThrowsError(try store.read())
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(ContextSetStore.filename).path))
            let permissions = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o777)
        }
    }
}
