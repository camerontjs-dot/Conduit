import XCTest
@testable import ConduitCore

final class ContextCompilerTests: XCTestCase {
    func testExternalBootstrapProtectsMandatoryAndOperatorPinnedItems() {
        let mandatory = item(
            id: "contract",
            source: "CONTRACT.md",
            authority: .filesystemSource,
            tokens: 120
        )
        let pinned = item(
            id: "pin",
            source: "PIN.md",
            authority: .operatorPinned,
            tokens: 40,
            pinned: true
        )
        let nomination = item(
            id: "nomination",
            source: "research.md",
            authority: .mindGraphNomination,
            tokens: 20
        )

        let set = ContextExternalBootstrap(
            objective: "Review the candidate",
            taskIdentity: "task-1",
            repositoryIdentity: ContextRepositoryIdentity(
                repository: "camerontjs-dot/Conduit",
                branch: "feature",
                commitSHA: "abc123"
            ),
            mandatoryItems: [mandatory],
            discoverableItems: [pinned, nomination],
            unresolvedPrerequisites: ["runtime capacity unknown"],
            producerVersions: [
                ContextComponentVersion(name: "bootstrap", version: "v1")
            ]
        ).makeContextSet(id: "set-1")

        XCTAssertEqual(set.entries.count, 3)
        XCTAssertEqual(set.entries[0].disposition, .mandatory)
        XCTAssertEqual(set.entries[0].representation, .reference)
        XCTAssertEqual(set.entries[1].disposition, .mandatory)
        XCTAssertEqual(set.entries[2].disposition, .nominated)
        XCTAssertEqual(set.entries[2].representation, .compactNomination)
        XCTAssertEqual(set.unresolvedPrerequisites, ["runtime capacity unknown"])
        XCTAssertEqual(set.retrieverVersions.first?.name, "bootstrap")
    }

    func testExplicitExpansionChangesOnlySelectedNomination() throws {
        let first = ContextSetEntry(
            item: item(
                id: "n1",
                source: "one.md",
                authority: .mindGraphNomination,
                tokens: 20
            ),
            disposition: .nominated,
            representation: .compactNomination,
            inclusionReasons: [
                ContextInclusionReason(.semanticNomination, detail: "related")
            ]
        )
        let second = ContextSetEntry(
            item: item(
                id: "n2",
                source: "two.md",
                authority: .mindGraphNomination,
                tokens: 30
            ),
            disposition: .nominated,
            representation: .compactNomination
        )
        let set = contextSet(entries: [first, second])

        let expanded = try set.expanding(
            itemID: "n2",
            representation: .full,
            reasonDetail: "operator selected"
        )

        XCTAssertEqual(expanded.entries[0].disposition, .nominated)
        XCTAssertEqual(expanded.entries[1].disposition, .expanded)
        XCTAssertEqual(expanded.entries[1].representation, .full)
        XCTAssertTrue(
            expanded.entries[1].inclusionReasons.contains(
                ContextInclusionReason(.explicitExpansion, detail: "operator selected")
            )
        )
    }

    func testExpansionFailsClosedForMissingOrOmittedItems() {
        let omitted = ContextSetEntry(
            item: item(
                id: "old",
                source: "old.md",
                authority: .filesystemSource,
                tokens: 20
            ),
            disposition: .omitted,
            dispositionReason: "not selected"
        )
        let set = contextSet(entries: [omitted])

        XCTAssertThrowsError(try set.expanding(itemID: "missing")) { error in
            XCTAssertEqual(error as? ContextCompilerError, .itemNotFound("missing"))
        }
        XCTAssertThrowsError(try set.expanding(itemID: "old")) { error in
            XCTAssertEqual(
                error as? ContextCompilerError,
                .itemNotExpandable("old", .omitted)
            )
        }
    }

    func testDeduplicationPreservesMultipleReasonsForSameExactSource() {
        let shared = item(
            id: "same",
            source: "docs/design.md",
            authority: .filesystemSource,
            revision: "blob-1",
            tokens: 50
        )
        let lexical = ContextSetEntry(
            item: shared,
            disposition: .nominated,
            representation: .excerpt,
            inclusionReasons: [ContextInclusionReason(.lexicalMatch, detail: "Context Set")]
        )
        let graph = ContextSetEntry(
            item: shared,
            disposition: .nominated,
            representation: .excerpt,
            inclusionReasons: [ContextInclusionReason(.graphRelationship, detail: "authored link")]
        )

        let normalized = contextSet(entries: [lexical, graph]).deduplicated()

        XCTAssertEqual(normalized.entries.count, 1)
        XCTAssertEqual(normalized.entries[0].inclusionReasons.count, 2)
        XCTAssertTrue(
            normalized.entries[0].inclusionReasons.contains(
                ContextInclusionReason(.lexicalMatch, detail: "Context Set")
            )
        )
        XCTAssertTrue(
            normalized.entries[0].inclusionReasons.contains(
                ContextInclusionReason(.graphRelationship, detail: "authored link")
            )
        )
    }

    func testByteIdenticalDigestDeduplicatesAcrossPathsWithoutLosingAliases() {
        let first = ContextSetEntry(
            item: item(
                id: "a",
                source: "a.md",
                authority: .filesystemSource,
                revision: "rev-a",
                tokens: 10
            ),
            disposition: .nominated,
            representation: .full,
            inclusionReasons: [ContextInclusionReason(.lexicalMatch)],
            contentDigest: "sha256:identical"
        )
        let second = ContextSetEntry(
            item: item(
                id: "b",
                source: "b.md",
                authority: .filesystemSource,
                revision: "rev-b",
                tokens: 10
            ),
            disposition: .nominated,
            representation: .full,
            inclusionReasons: [ContextInclusionReason(.semanticNomination)],
            contentDigest: "sha256:identical"
        )

        let normalized = contextSet(entries: [first, second]).deduplicated()

        XCTAssertEqual(normalized.entries.count, 1)
        XCTAssertEqual(normalized.entries[0].item.id, "a")
        XCTAssertEqual(normalized.entries[0].duplicateItemIDs, ["b"])
        XCTAssertEqual(normalized.entries[0].duplicateSourceReferences, ["b.md"])
        XCTAssertEqual(normalized.entries[0].inclusionReasons.count, 2)
    }

    func testSameDigestDoesNotCollapseDifferentAuthorityClasses() {
        let source = ContextSetEntry(
            item: item(
                id: "source",
                source: "same.md",
                authority: .filesystemSource,
                tokens: 10
            ),
            disposition: .nominated,
            representation: .full,
            contentDigest: "sha256:same"
        )
        let observation = ContextSetEntry(
            item: item(
                id: "observation",
                source: "same.md",
                authority: .testReceipt,
                tokens: 10
            ),
            disposition: .nominated,
            representation: .full,
            contentDigest: "sha256:same"
        )

        XCTAssertEqual(
            contextSet(entries: [source, observation]).deduplicated().entries.count,
            2
        )
    }

    func testSupersessionRequiresExactIdentityAndCannotEvictHardContext() {
        let old = ContextSetEntry(
            item: item(
                id: "old",
                source: "spec.md",
                authority: .filesystemSource,
                revision: "old-rev",
                tokens: 10
            ),
            disposition: .nominated
        )
        let newer = ContextSetEntry(
            item: item(
                id: "new",
                source: "spec.md",
                authority: .filesystemSource,
                revision: "new-rev",
                tokens: 10
            ),
            disposition: .expanded,
            supersedes: [
                ContextSupersession(
                    targetItemID: "old",
                    targetSourceReference: "spec.md",
                    targetRevisionIdentity: "old-rev"
                )
            ]
        )

        let applied = contextSet(entries: [old, newer]).applyingExplicitSupersession()
        XCTAssertEqual(applied.entries[0].disposition, .omitted)
        XCTAssertEqual(applied.entries[0].dispositionReason, "explicitly superseded by new")

        let mismatched = ContextSetEntry(
            item: newer.item,
            disposition: .expanded,
            supersedes: [
                ContextSupersession(
                    targetItemID: "old",
                    targetSourceReference: "spec.md",
                    targetRevisionIdentity: "different-rev"
                )
            ]
        )
        XCTAssertEqual(
            contextSet(entries: [old, mismatched])
                .applyingExplicitSupersession()
                .entries[0]
                .disposition,
            .nominated
        )

        var hardOld = old
        hardOld.disposition = .mandatory
        XCTAssertEqual(
            contextSet(entries: [hardOld, newer])
                .applyingExplicitSupersession()
                .entries[0]
                .disposition,
            .mandatory
        )
    }

    func testManifestDistinguishesDeliveredNominationOmittedAndDeferred() {
        let mandatory = ContextSetEntry(
            item: item(
                id: "hard",
                source: "TASK.md",
                authority: .operatorPinned,
                revision: "task-rev",
                tokens: 100,
                pinned: true
            ),
            disposition: .mandatory,
            representation: .full,
            inclusionReasons: [ContextInclusionReason(.operatorPin)]
        )
        let nomination = ContextSetEntry(
            item: item(
                id: "nom",
                source: "related.md",
                authority: .mindGraphNomination,
                tokens: 20
            ),
            disposition: .nominated,
            representation: .compactNomination,
            inclusionReasons: [ContextInclusionReason(.semanticNomination)]
        )
        let expanded = ContextSetEntry(
            item: item(
                id: "expanded",
                source: "source.md",
                authority: .filesystemSource,
                revision: "source-rev",
                tokens: 80
            ),
            disposition: .expanded,
            representation: .excerpt,
            inclusionReasons: [ContextInclusionReason(.explicitExpansion)],
            truncationReason: "selected excerpt"
        )
        let omitted = ContextSetEntry(
            item: item(
                id: "omitted",
                source: "old.md",
                authority: .filesystemSource,
                revision: "old-rev",
                tokens: 30
            ),
            disposition: .omitted,
            dispositionReason: "superseded"
        )
        let deferred = ContextSetEntry(
            item: item(
                id: "deferred",
                source: "later.md",
                authority: .issue,
                tokens: 15
            ),
            disposition: .deferred,
            dispositionReason: "not needed for this handoff"
        )

        let manifest = ContextManifestCompiler.compile(
            contextSet: contextSet(
                entries: [mandatory, nomination, expanded, omitted, deferred]
            ),
            destination: ContextDestination(
                runtime: "test-runtime",
                model: "test-model",
                capacityTokens: 1_000
            ),
            budget: ContextBudget(
                reservedOutputTokens: 200,
                reservedToolTokens: 100
            )
        )

        XCTAssertEqual(
            manifest.entries.map(\.deliveryState),
            [.delivered, .nominationOnly, .delivered, .omitted, .deferred]
        )
        XCTAssertEqual(manifest.deliveredEntries.map(\.contextItemID), ["hard", "expanded"])
        XCTAssertEqual(manifest.entries[1].authorityClass, .nomination)
        XCTAssertEqual(manifest.entries[1].representation, .compactNomination)
        XCTAssertEqual(manifest.entries[2].truncationReason, "selected excerpt")
        XCTAssertEqual(manifest.entries[3].dispositionReason, "superseded")
        XCTAssertEqual(manifest.compilerVersion, ContextManifestCompiler.version)
    }

    func testUnknownDestinationCapacityDoesNotEvictHardContext() {
        let hard = ContextSetEntry(
            item: item(
                id: "hard",
                source: "TASK.md",
                authority: .operatorPinned,
                tokens: 500,
                pinned: true
            ),
            disposition: .mandatory,
            representation: .full
        )
        let expanded = ContextSetEntry(
            item: item(
                id: "expanded",
                source: "source.md",
                authority: .filesystemSource,
                tokens: 400
            ),
            disposition: .expanded,
            representation: .full
        )

        let manifest = ContextManifestCompiler.compile(
            contextSet: contextSet(entries: [hard, expanded]),
            destination: ContextDestination(model: "unknown-capacity-model"),
            budget: ContextBudget(
                reservedOutputTokens: 100,
                reservedToolTokens: 100
            )
        )

        XCTAssertEqual(manifest.budget.state, .unknownDestinationCapacity)
        XCTAssertEqual(manifest.deliveredEntries.map(\.contextItemID), ["hard", "expanded"])
    }

    func testBudgetReportsHardContextOverflowWithoutEviction() {
        let hard = ContextSetEntry(
            item: item(
                id: "hard",
                source: "TASK.md",
                authority: .operatorPinned,
                tokens: 900,
                pinned: true
            ),
            disposition: .mandatory,
            representation: .full
        )
        let nomination = ContextSetEntry(
            item: item(
                id: "optional",
                source: "optional.md",
                authority: .mindGraphNomination,
                tokens: 100
            ),
            disposition: .nominated,
            representation: .compactNomination
        )

        let manifest = ContextManifestCompiler.compile(
            contextSet: contextSet(entries: [hard, nomination]),
            destination: ContextDestination(capacityTokens: 1_000),
            budget: ContextBudget(
                reservedOutputTokens: 150,
                reservedToolTokens: 50
            )
        )

        XCTAssertEqual(manifest.budget.availableInputTokens, 800)
        XCTAssertEqual(manifest.budget.state, .hardContextExceedsCapacity)
        XCTAssertEqual(manifest.deliveredEntries.map(\.contextItemID), ["hard"])
        XCTAssertEqual(manifest.entries[1].deliveryState, .nominationOnly)
    }

    func testBudgetPreservesUnknownSelectedCost() {
        let hard = ContextSetEntry(
            item: item(
                id: "hard",
                source: "TASK.md",
                authority: .operatorPinned,
                tokens: 100,
                pinned: true
            ),
            disposition: .mandatory
        )
        let expandedUnknown = ContextSetEntry(
            item: item(
                id: "expanded",
                source: "source.md",
                authority: .filesystemSource,
                tokens: nil
            ),
            disposition: .expanded
        )

        let summary = ContextBudgetEvaluator.assess(
            entries: [hard, expandedUnknown],
            destination: ContextDestination(capacityTokens: 2_000),
            budget: ContextBudget(
                reservedOutputTokens: 200,
                reservedToolTokens: 100
            )
        )

        XCTAssertEqual(summary.state, .unknownSelectedCost)
        XCTAssertEqual(summary.expandedUnknownItemCount, 1)
        XCTAssertEqual(summary.deliveredKnownEstimatedTokenSubtotal, 100)
    }

    func testManifestEncodingIsDeterministicForSameInput() throws {
        let entry = ContextSetEntry(
            item: item(
                id: "a",
                source: "a.md",
                authority: .filesystemSource,
                revision: "rev",
                tokens: 12
            ),
            disposition: .mandatory,
            inclusionReasons: [
                ContextInclusionReason(.requiredContract),
                ContextInclusionReason(.exactIdentity, detail: "rev")
            ]
        )
        let manifest = ContextManifestCompiler.compile(
            contextSet: contextSet(entries: [entry]),
            destination: ContextDestination(
                runtime: "runtime",
                model: "model",
                capacityTokens: 500,
                tokenizer: nil
            ),
            budget: ContextBudget(
                reservedOutputTokens: 50,
                reservedToolTokens: 50
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        XCTAssertEqual(try encoder.encode(manifest), try encoder.encode(manifest))
    }

    private func contextSet(entries: [ContextSetEntry]) -> ContextSet {
        ContextSet(
            id: "set",
            objective: "Test objective",
            taskIdentity: "task",
            repositoryIdentity: ContextRepositoryIdentity(
                repository: "camerontjs-dot/Conduit",
                scopePath: ".",
                branch: "feature",
                commitSHA: "abc123"
            ),
            entries: entries,
            unresolvedPrerequisites: [],
            retrieverVersions: [
                ContextComponentVersion(name: "test-retriever", version: "1")
            ]
        )
    }

    private func item(
        id: String,
        source: String,
        authority: AgentContextAuthority,
        revision: String? = nil,
        tokens: Int?,
        pinned: Bool = false
    ) -> AgentContextItem {
        AgentContextItem(
            id: id,
            title: id,
            kind: authority == .mindGraphNomination ? .semanticNomination : .file,
            authority: authority,
            sourceReference: source,
            revisionIdentity: revision,
            estimatedTokens: tokens,
            isPinned: pinned,
            freshness: .unknown
        )
    }
}
