import XCTest
@testable import ConduitCore

final class AgentContextIdentityDiffTests: XCTestCase {
    private func item(
        id: String = "retained",
        title: String = "Source",
        kind: AgentContextItemKind = .file,
        authority: AgentContextAuthority = .filesystemSource,
        sourceReference: String = "a|b",
        revisionIdentity: String? = "c",
        lineRange: ClosedRange<Int>? = 1...2,
        estimatedTokens: Int? = 10,
        isPinned: Bool = false,
        freshness: AgentContextFreshness = .current
    ) -> AgentContextItem {
        AgentContextItem(
            id: id, title: title, kind: kind, authority: authority,
            sourceReference: sourceReference, revisionIdentity: revisionIdentity,
            lineRange: lineRange, estimatedTokens: estimatedTokens,
            isPinned: isPinned, freshness: freshness
        )
    }

    private func diff(_ before: AgentContextItem, _ after: AgentContextItem) -> AgentContextDiff {
        AgentContextDiffer.diff(
            previous: AgentContextBundle(taskTitle: "Before", items: [before]),
            current: AgentContextBundle(taskTitle: "After", items: [after])
        )
    }

    func testSourceAndRevisionDelimiterCollisionIsChanged() {
        let before = item()
        let after = item(sourceReference: "a", revisionIdentity: "b|c")

        // The legacy public representation is deliberately retained. It must
        // no longer decide whether source identity changed.
        XCTAssertEqual(before.identityFingerprint, after.identityFingerprint)
        let result = diff(before, after)
        XCTAssertEqual(result.changed, [AgentContextItemChange(before: before, after: after)])
        XCTAssertTrue(result.added.isEmpty)
        XCTAssertTrue(result.removed.isEmpty)
    }

    func testEveryExistingIdentityFieldStillProducesAChange() {
        let before = item()
        let cases: [(String, AgentContextItem)] = [
            ("kind", item(kind: .selection)),
            ("authority", item(authority: .agentOutput)),
            ("source", item(sourceReference: "other")),
            ("revision", item(revisionIdentity: "next")),
            ("range", item(lineRange: 2...3)),
            ("absent range", item(lineRange: nil)),
            ("freshness state", item(freshness: .unknown)),
            ("stale reason", item(freshness: .stale(reason: "source changed")))
        ]
        for (label, after) in cases {
            XCTAssertEqual(
                diff(before, after).changed,
                [AgentContextItemChange(before: before, after: after)],
                label
            )
        }
        let stale = item(freshness: .stale(reason: "old"))
        let restated = item(freshness: .stale(reason: "new|reason"))
        XCTAssertEqual(diff(stale, restated).changed.count, 1)
    }

    func testPresentationOnlyChangesRemainExcluded() {
        let before = item()
        let after = item(title: "Renamed display", estimatedTokens: 99, isPinned: true)
        XCTAssertTrue(diff(before, after).isEmpty)
    }

    func testAbsentAndEmptyRevisionKeepExistingEquivalence() {
        XCTAssertTrue(diff(item(revisionIdentity: nil), item(revisionIdentity: "")).isEmpty)
    }

    func testStableIDChangeRemainsRemovalAndAddition() {
        let before = item(id: "old")
        let after = item(id: "new")
        let result = diff(before, after)
        XCTAssertEqual(result.removed, [before])
        XCTAssertEqual(result.added, [after])
        XCTAssertTrue(result.changed.isEmpty)
    }

    func testChangedItemsKeepDeterministicIDOrdering() {
        let oldB = item(id: "b")
        let oldA = item(id: "a")
        let newB = item(id: "b", sourceReference: "a", revisionIdentity: "b|c")
        let newA = item(id: "a", revisionIdentity: "next")
        let result = AgentContextDiffer.diff(
            previous: AgentContextBundle(taskTitle: "Task", items: [oldB, oldA]),
            current: AgentContextBundle(taskTitle: "Task", items: [newB, newA])
        )
        XCTAssertEqual(result.changed.map { $0.after.id }, ["a", "b"])
        XCTAssertTrue(result.added.isEmpty)
        XCTAssertTrue(result.removed.isEmpty)
    }
}
