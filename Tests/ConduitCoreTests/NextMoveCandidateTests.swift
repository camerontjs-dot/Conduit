import XCTest
@testable import ConduitCore

final class NextMoveCandidateTests: XCTestCase {
    private let generatedAt = Date(timeIntervalSince1970: 1_800_000_000.25)

    private func state(
        project: String = "fixture-project",
        task: String = "task-1",
        snapshot: String? = "events-1",
        manifest: String? = "manifest-1",
        repository: ContextRepositoryIdentity? = nil
    ) -> NextMoveInputStateIdentity {
        NextMoveInputStateIdentity(
            projectID: project, taskIdentity: task, snapshotIdentity: snapshot,
            contextManifestIdentity: manifest, repositoryIdentity: repository
        )
    }

    private func basis(
        authority: AgentContextAuthority = .issue,
        revision: String? = "issue-revision-1",
        freshness: AgentContextFreshness = .current
    ) -> NextMoveBasis {
        NextMoveBasis(
            source: AgentContextItem(
                id: "acceptance", title: "Acceptance obligation", kind: .issue,
                authority: authority, sourceReference: "issue:fixture-56",
                revisionIdentity: revision, freshness: freshness
            ),
            inclusionReasons: [ContextInclusionReason(.requiredContract, detail: "Evidence is required before acceptance.")]
        )
    }

    private func proposal(project: String = "fixture-project", scope: [String] = ["Sources/"]) -> OrchestrationProposal {
        OrchestrationProposal(
            objective: "Prepare independent verification.", projectID: project,
            suggestedAgent: "fixture-worker", scopeAllowlist: scope,
            deliverables: ["Verification receipt"], verificationSteps: ["Freeze an independent oracle."],
            risks: ["Independence may be unavailable."], nonGoals: ["Do not launch from this fixture."]
        )
    }

    private func candidate(
        version: Int = 1, kind: NextMoveKind = .prompt, text: String = "Inspect the exact receipt before continuing.",
        reason: String = "The acceptance obligation needs evidence.",
        sources: [NextMoveBasis]? = nil, support: NextMoveSupport = .supported,
        obligations: [NextMoveObligation] = [], input: NextMoveInputStateIdentity? = nil,
        staged: OrchestrationProposal? = nil, date: Date? = nil
    ) -> NextMoveCandidate {
        NextMoveCandidate(
            schemaVersion: version, kind: kind, proposedText: text, reason: reason,
            basis: sources ?? [basis()], support: support, obligations: obligations,
            generatedAt: date ?? generatedAt, inputState: input ?? state(), stagedProposal: staged
        )
    }

    func testCanonicalRoundTripRetainsExplanationAndEveryIdentity() throws {
        let value = candidate(input: state(repository: ContextRepositoryIdentity(
            repository: "example/repository", scopePath: "Sources", branch: "fixture", commitSHA: "base-1"
        )))
        let bytes = try value.canonicalData()
        let replay = try NextMoveCandidate.decodeCanonicalData(bytes)
        XCTAssertEqual(replay, value)
        XCTAssertEqual(try replay.canonicalData(), bytes)
        XCTAssertEqual(replay.revisionIdentity, value.revisionIdentity)
        XCTAssertEqual(value.assess(currentInputState: value.inputState).disposition, .reviewable)
    }

    func testRepeatedConstructionHasNoImplicitClockOrRandomIdentity() throws {
        let first = candidate()
        for _ in 0..<100 {
            XCTAssertEqual(try candidate().canonicalData(), try first.canonicalData())
        }
    }

    func testEditableTextCreatesRevisionWithoutRefreshingEvidence() {
        let original = candidate(support: .unknown)
        let edited = original.editingProposedText("Ask for the missing receipt.")
        XCTAssertNotEqual(edited.revisionIdentity, original.revisionIdentity)
        XCTAssertEqual(edited.generatedAt, original.generatedAt)
        XCTAssertEqual(edited.inputState, original.inputState)
        XCTAssertEqual(edited.basis, original.basis)
        XCTAssertEqual(edited.support, .unknown)
        XCTAssertEqual(edited.assess(currentInputState: edited.inputState).disposition, .unknown)
        XCTAssertEqual(original.proposedText, "Inspect the exact receipt before continuing.")
    }

    func testSeparateIdentityFieldsCannotCollideThroughDelimiters() throws {
        let first = candidate(input: state(task: "a|b", snapshot: "c"))
        let second = candidate(input: state(task: "a", snapshot: "b|c"))
        XCTAssertNotEqual(try first.canonicalData(), try second.canonicalData())
        XCTAssertNotEqual(first.revisionIdentity, second.revisionIdentity)
        XCTAssertEqual(first.assess(currentInputState: second.inputState).disposition, .stale)
    }

    func testEachChangedInputAxisInvalidatesTheCandidate() {
        let value = candidate()
        for current in [
            state(project: "other-project"), state(task: "other-task"), state(snapshot: "events-2"),
            state(manifest: "manifest-2"), state(manifest: nil),
            state(repository: ContextRepositoryIdentity(repository: "other/repository", commitSHA: "base-2"))
        ] {
            XCTAssertEqual(value.assess(currentInputState: current).disposition, .stale)
        }
    }

    func testOldGenerationTimeDoesNotInventStalenessAndNewTimeCannotEraseIt() {
        let old = candidate(date: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(old.assess(currentInputState: old.inputState).disposition, .reviewable)
        let recent = candidate(date: Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertEqual(recent.assess(currentInputState: state(snapshot: "events-2")).disposition, .stale)
    }

    func testMissingCurrentOrSnapshotIdentityRemainsUnknown() {
        let value = candidate()
        XCTAssertEqual(value.assess(currentInputState: nil).disposition, .unknown)
        let missing = candidate(input: state(snapshot: nil))
        XCTAssertEqual(missing.assess(currentInputState: missing.inputState).disposition, .unknown)
        let blank = candidate(input: state(snapshot: "  "))
        XCTAssertEqual(blank.assess(currentInputState: blank.inputState).disposition, .unknown)
    }

    func testUnknownSupportCannotBecomeReviewableFromOtherwiseCurrentState() {
        let value = candidate(support: .unknown)
        let result = value.assess(currentInputState: value.inputState)
        XCTAssertEqual(result.disposition, .unknown)
        XCTAssertEqual(result.support, .unknown)
        XCTAssertFalse(result.reasons.isEmpty)
    }

    func testHardBlockPreservesIndependentUnknownObligations() throws {
        let obligations = [
            NextMoveObligation(id: "receipt", description: "Receipt missing", state: .missing),
            NextMoveObligation(id: "oracle", description: "Independence unavailable", state: .blocked),
            NextMoveObligation(id: "entitlement", description: "Entitlement unknown", state: .unknown)
        ]
        let value = candidate(support: .unknown, obligations: obligations)
        let result = value.assess(currentInputState: value.inputState)
        XCTAssertEqual(result.disposition, .blocked)
        XCTAssertEqual(result.obligations, obligations)
        XCTAssertEqual(result.support, .unknown)
        XCTAssertTrue(result.reasons.contains(where: { $0.contains("UNKNOWN") }))
        XCTAssertEqual(try NextMoveCandidate.decodeCanonicalData(value.canonicalData()).obligations, obligations)
    }

    func testUnknownObligationAndExplicitUnsupportedSupportRemainDistinct() {
        let unknown = candidate(obligations: [NextMoveObligation(id: "evidence", description: "Not observed", state: .unknown)])
        XCTAssertEqual(unknown.assess(currentInputState: unknown.inputState).disposition, .unknown)
        let unsupported = candidate(support: .unsupported)
        let result = unsupported.assess(currentInputState: unsupported.inputState)
        XCTAssertEqual(result.disposition, .blocked)
        XCTAssertEqual(result.support, .unsupported)
    }

    func testConsultedNominationStaysNominationWithoutSourceTruthClaim() throws {
        let value = candidate(kind: .inspect, sources: [basis(authority: .mindGraphNomination)])
        let decoded = try NextMoveCandidate.decodeCanonicalData(value.canonicalData())
        XCTAssertEqual(decoded.basis.first?.source.authority.authorityClass, .nomination)
        XCTAssertEqual(decoded.basis.first?.source.authority.isSourceBacked, false)
        XCTAssertEqual(decoded.reviewSurface, .inspection)
    }

    func testSourceFreshnessAndMissingRevisionFailClosed() {
        for source in [basis(revision: nil), basis(freshness: .unknown)] {
            let value = candidate(sources: [source])
            XCTAssertEqual(value.assess(currentInputState: value.inputState).disposition, .unknown)
        }
        let stale = candidate(sources: [basis(freshness: .stale(reason: "Source changed"))])
        XCTAssertEqual(stale.assess(currentInputState: stale.inputState).disposition, .stale)
    }

    func testNontrivialSuggestionRequiresReasonAndConsultedIdentity() {
        for value in [candidate(reason: " "), candidate(sources: []), candidate(text: "\n")] {
            XCTAssertEqual(value.assess(currentInputState: value.inputState).disposition, .invalid)
        }
    }

    func testDuplicateSourceOrObligationIdentityIsRejectedWithoutTrap() {
        let duplicateSource = candidate(sources: [basis(), basis(revision: "other-revision")])
        let duplicateObligation = candidate(obligations: [
            NextMoveObligation(id: "x", description: "Missing", state: .missing),
            NextMoveObligation(id: "x", description: "Claimed satisfied", state: .satisfied)
        ])
        for value in [duplicateSource, duplicateObligation] {
            XCTAssertEqual(value.assess(currentInputState: value.inputState).disposition, .invalid)
        }
    }

    func testNewWorkNeedsExistingProposalAndPreservesPolicyBoundary() {
        for kind in [NextMoveKind.handoff, .orchestrate] {
            let absent = candidate(kind: kind)
            XCTAssertEqual(absent.assess(currentInputState: absent.inputState).disposition, .invalid)
            let staged = candidate(kind: kind, staged: proposal(scope: ["*"]))
            XCTAssertEqual(staged.reviewSurface, .orchestrationProposal)
            XCTAssertTrue(staged.requiresOrchestrationPolicy)
            XCTAssertEqual(staged.assess(currentInputState: staged.inputState).disposition, .reviewable)
            let packet = OrchestrationContextPacket(projectID: staged.inputState.projectID, entries: [])
            let policy = OrchestrationProposalPolicy(allowedAgentNames: ["fixture-worker"])
            guard case .refused = policy.validate(
                proposal: staged.stagedProposal!, selectedProjectID: staged.inputState.projectID,
                contextPacket: packet, workerAlreadyActive: false
            ) else { return XCTFail("Reviewable suggestion must not bypass existing broad-scope refusal.") }
        }
    }

    func testCrossProjectProposalAndSameThreadNewWorkMismatchAreInvalid() {
        for value in [
            candidate(kind: .handoff, staged: proposal(project: "wrong-project")),
            candidate(kind: .prompt, staged: proposal()), candidate(kind: .wait, staged: proposal())
        ] {
            XCTAssertEqual(value.assess(currentInputState: value.inputState).disposition, .invalid)
        }
    }

    func testEveryKindHasExplicitReviewSurfaceWithoutDispatch() {
        XCTAssertEqual(candidate().reviewSurface, .composerDraft)
        XCTAssertEqual(candidate(kind: .verify).reviewSurface, .composerDraft)
        XCTAssertEqual(candidate(kind: .verify, staged: proposal()).reviewSurface, .orchestrationProposal)
        XCTAssertEqual(candidate(kind: .wait, sources: []).reviewSurface, .wait)
        XCTAssertEqual(NextMoveKind.allCases.count, 6)
    }

    func testUnsupportedSchemaAndMalformedTargetAreInvalid() {
        for value in [candidate(version: 2), candidate(input: state(project: " ")), candidate(input: state(task: ""))] {
            XCTAssertEqual(value.assess(currentInputState: value.inputState).disposition, .invalid)
        }
        XCTAssertEqual(candidate().assess(currentInputState: state(task: " ")).disposition, .invalid)
    }

    func testNonfiniteDateHasNoSharedFallbackRevisionIdentity() {
        let value = candidate(date: Date(timeIntervalSince1970: .infinity))
        XCTAssertEqual(value.assess(currentInputState: value.inputState).disposition, .invalid)
        XCTAssertNil(value.revisionIdentity)
        XCTAssertThrowsError(try value.canonicalData())
    }

    func testProvidedBlankOptionalIdentityCannotBecomeReviewable() {
        for input in [
            state(manifest: "  "),
            state(repository: ContextRepositoryIdentity(repository: " ")),
            state(repository: ContextRepositoryIdentity(scopePath: " ")),
            state(repository: ContextRepositoryIdentity(branch: " ")),
            state(repository: ContextRepositoryIdentity(commitSHA: " "))
        ] {
            let value = candidate(input: input)
            XCTAssertEqual(value.assess(currentInputState: input).disposition, .invalid)
        }
    }

    func testDecoderRejectsMissingFieldsUnknownEnumsAndAuthorityGrantFields() throws {
        let bytes = try candidate().canonicalData()
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var absent = original; absent.removeValue(forKey: "support")
        var wrongKind = original; wrongKind["kind"] = "autoLaunch"
        var wrongSupport = original; wrongSupport["support"] = "assumedFree"
        for object in [absent, wrongKind, wrongSupport] {
            XCTAssertThrowsError(try NextMoveCandidate.decodeCanonicalData(JSONSerialization.data(withJSONObject: object)))
        }
        for key in ["autoSend", "approvalToken", "routeDecision", "launchGrant"] {
            var object = original; object[key] = true
            XCTAssertThrowsError(try NextMoveCandidate.decodeCanonicalData(JSONSerialization.data(withJSONObject: object)))
        }
    }
}
