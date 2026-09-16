import XCTest
@testable import ConduitCore

final class AgentContextTests: XCTestCase {
    func testSemanticNominationNeverBecomesSourceBacked() {
        XCTAssertFalse(AgentContextAuthority.mindGraphNomination.isSourceBacked)
        XCTAssertEqual(
            AgentContextAuthority.mindGraphNomination.authorityClass,
            .nomination
        )
        XCTAssertFalse(AgentContextAuthority.agentOutput.isSourceBacked)
        XCTAssertEqual(AgentContextAuthority.agentOutput.authorityClass, .agentOutput)
        XCTAssertTrue(AgentContextAuthority.filesystemSource.isSourceBacked)
        XCTAssertTrue(AgentContextAuthority.gitCommit.isSourceBacked)
    }

    func testContextDiffUsesStableIdentityAndRevision() {
        let before = AgentContextItem(
            id: "file:Sources/Foo.swift",
            title: "Foo.swift",
            kind: .file,
            authority: .filesystemSource,
            sourceReference: "Sources/Foo.swift",
            revisionIdentity: "sha-old",
            lineRange: 10...20,
            freshness: .current
        )
        let after = AgentContextItem(
            id: "file:Sources/Foo.swift",
            title: "Foo.swift",
            kind: .file,
            authority: .filesystemSource,
            sourceReference: "Sources/Foo.swift",
            revisionIdentity: "sha-new",
            lineRange: 10...20,
            freshness: .current
        )

        let diff = AgentContextDiffer.diff(
            previous: AgentContextBundle(taskTitle: "Task", items: [before]),
            current: AgentContextBundle(taskTitle: "Task", items: [after])
        )

        XCTAssertTrue(diff.added.isEmpty)
        XCTAssertTrue(diff.removed.isEmpty)
        XCTAssertEqual(diff.changed, [AgentContextItemChange(before: before, after: after)])
    }

    func testContextDiffSeparatesAddedRemovedAndChanged() {
        let retained = AgentContextItem(
            id: "retained",
            title: "retained",
            kind: .note,
            authority: .operatorPinned,
            sourceReference: "operator",
            isPinned: true,
            freshness: .current
        )
        let removed = AgentContextItem(
            id: "removed",
            title: "removed",
            kind: .testReceipt,
            authority: .testReceipt,
            sourceReference: "receipt-a"
        )
        let added = AgentContextItem(
            id: "added",
            title: "added",
            kind: .pullRequest,
            authority: .pullRequest,
            sourceReference: "PR #33"
        )

        let diff = AgentContextDiffer.diff(
            previous: AgentContextBundle(taskTitle: "Task", items: [retained, removed]),
            current: AgentContextBundle(taskTitle: "Task", items: [retained, added])
        )

        XCTAssertEqual(diff.added, [added])
        XCTAssertEqual(diff.removed, [removed])
        XCTAssertTrue(diff.changed.isEmpty)
        XCTAssertFalse(diff.isEmpty)
    }

    func testBundleSurfacesPinnedNominationStaleAndTokenFacts() {
        let pinned = AgentContextItem(
            id: "pinned",
            title: "Spec",
            kind: .file,
            authority: .filesystemSource,
            sourceReference: "SPEC.md",
            estimatedTokens: 120,
            isPinned: true,
            freshness: .current
        )
        let nomination = AgentContextItem(
            id: "nomination",
            title: "Related note",
            kind: .semanticNomination,
            authority: .mindGraphNomination,
            sourceReference: "10_knowledge/note.md",
            estimatedTokens: 80,
            freshness: .unknown
        )
        let stale = AgentContextItem(
            id: "stale",
            title: "Old receipt",
            kind: .testReceipt,
            authority: .testReceipt,
            sourceReference: "receipt.md",
            revisionIdentity: "old-sha",
            estimatedTokens: 30,
            freshness: .stale(reason: "candidate head changed")
        )

        let bundle = AgentContextBundle(
            taskTitle: "Qualification",
            scopePath: "30_projects/conduit",
            repository: "camerontjs-dot/Conduit",
            branch: "feature",
            commitSHA: "abc123",
            items: [pinned, nomination, stale]
        )

        XCTAssertEqual(bundle.estimatedTokenTotal, 230)
        XCTAssertEqual(bundle.pinnedItems, [pinned])
        XCTAssertEqual(bundle.nominationItems, [nomination])
        XCTAssertEqual(bundle.staleItems, [stale])
        XCTAssertEqual(pinned.locationLabel, "SPEC.md")
    }

    func testLineRangeLocationLabel() {
        let single = AgentContextItem(
            id: "single",
            title: "single",
            kind: .selection,
            authority: .filesystemSource,
            sourceReference: "Foo.swift",
            lineRange: 8...8
        )
        let range = AgentContextItem(
            id: "range",
            title: "range",
            kind: .selection,
            authority: .filesystemSource,
            sourceReference: "Foo.swift",
            lineRange: 8...14
        )

        XCTAssertEqual(single.locationLabel, "Foo.swift:8")
        XCTAssertEqual(range.locationLabel, "Foo.swift:8-14")
    }

    func testRecipesOnlyNominateKinds() {
        XCTAssertTrue(AgentContextRecipe.reviewPullRequest.recommendedKinds.contains(.pullRequest))
        XCTAssertTrue(AgentContextRecipe.investigateFailure.recommendedKinds.contains(.testReceipt))
        XCTAssertTrue(AgentContextRecipe.agentHandoff.recommendedKinds.contains(.agentOutput))
    }
}
