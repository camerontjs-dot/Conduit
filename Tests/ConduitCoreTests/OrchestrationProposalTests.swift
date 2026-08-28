import XCTest
@testable import ConduitCore

final class OrchestrationProposalTests: XCTestCase {
    private let projectID = "conduit"

    private func packet(entries: [OrchestrationContextEntry]? = nil) -> OrchestrationContextPacket {
        OrchestrationContextPacket(
            projectID: projectID,
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            entries: entries ?? [
                OrchestrationContextEntry(
                    id: "knowledge-1",
                    scope: .knowledge,
                    displayPath: "10_knowledge/agents/planner.md",
                    citationClass: .citable,
                    excerpt: "Planning context is a nomination, not proof.",
                    tokenEstimate: 40,
                    selectedByOperator: true
                ),
                OrchestrationContextEntry(
                    id: "project-1",
                    scope: .projects,
                    displayPath: "30_projects/conduit/README.md",
                    citationClass: .citable,
                    excerpt: "Conduit owns execution observation.",
                    tokenEstimate: 30,
                    selectedByOperator: true
                )
            ]
        )
    }

    private func proposal(
        projectID: String? = nil,
        workerCount: Int = 1,
        scopeAllowlist: [String] = ["Sources/ConduitCore/"],
        verificationSteps: [String] = ["Run focused XCTest."],
        nonGoals: [String] = ["Do not start another worker."],
        objective: String = "Add a bounded planner proposal contract."
    ) -> OrchestrationProposal {
        OrchestrationProposal(
            objective: objective,
            projectID: projectID ?? self.projectID,
            suggestedAgent: "OpenCode Local Planner",
            workerCount: workerCount,
            scopeAllowlist: scopeAllowlist,
            deliverables: ["Core contract and tests"],
            verificationSteps: verificationSteps,
            risks: ["Planner output is not verification."],
            nonGoals: nonGoals
        )
    }

    private var policy: OrchestrationProposalPolicy {
        OrchestrationProposalPolicy(allowedAgentNames: ["OpenCode Local Planner"])
    }

    func testScopeSelectionMakesMainframeRootAnExplicitProposalTarget() {
        let root = MainframeProject(
            slug: "mainframe",
            path: URL(fileURLWithPath: "/tmp/MainFrame"),
            readmePath: nil,
            metadata: ProjectMetadata(title: "MainFrame"),
            isMainframeRoot: true
        )
        let project = MainframeProject(
            slug: "conduit",
            path: URL(fileURLWithPath: "/tmp/MainFrame/30_projects/conduit"),
            readmePath: nil,
            metadata: ProjectMetadata(title: "Conduit")
        )
        let choices = OrchestrationScopeSelection.selectableProjects(from: [root, project])

        XCTAssertEqual(choices, [root, project])
        XCTAssertEqual(
            OrchestrationScopeSelection.selectedProject(
                explicitID: root.id,
                currentSelection: project,
                from: choices
            ),
            root
        )
        XCTAssertEqual(
            OrchestrationScopeSelection.selectedProject(
                explicitID: nil,
                currentSelection: root,
                from: choices
            ),
            root
        )
    }

    func testPacketPreservesScopeAndCitationLabels() throws {
        let value = packet()
        let decoded = try JSONDecoder().decode(
            OrchestrationContextPacket.self,
            from: JSONEncoder().encode(value)
        )

        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.entries.map(\.scope), [.knowledge, .projects])
        XCTAssertEqual(decoded.entries.map(\.citationClass), [.citable, .citable])
        XCTAssertEqual(value.validationReasons(maximumTokens: 100), [])
    }

    func testPacketRejectsUnlabelledOrOverBudgetContext() {
        let invalid = OrchestrationContextEntry(
            id: "",
            scope: .knowledge,
            displayPath: "",
            citationClass: .unknown,
            excerpt: "Unlabelled",
            tokenEstimate: 99,
            selectedByOperator: false
        )

        let reasons = packet(entries: [invalid]).validationReasons(maximumTokens: 10)
        XCTAssertTrue(reasons.contains("Every context entry must retain scope and citation labels."))
        XCTAssertTrue(reasons.contains("Selected context exceeds the planner budget."))
    }

    func testDecoderAcceptsOnlyDeclaredJSONEnvelope() {
        let value = proposal()
        let data = try! JSONEncoder().encode(value)
        let json = String(decoding: data, as: UTF8.self)

        XCTAssertEqual(
            try? OrchestrationProposalDecoder.decode(from: "```json\n\(json)\n```").get(),
            value
        )

        switch OrchestrationProposalDecoder.decode(from: "Here is a plan: \(json)") {
        case .success:
            XCTFail("Prose must not be scraped into a proposal.")
        case .failure:
            break
        }
    }

    func testPolicyRefusesProjectMismatchBroadScopeAndExecutionIntent() {
        let value = proposal(
            projectID: "different-project",
            scopeAllowlist: ["*"],
            objective: "Use curl https://example.test then make a plan."
        )

        let result = policy.validate(
            proposal: value,
            selectedProjectID: projectID,
            contextPacket: packet(),
            workerAlreadyActive: false
        )

        guard case .refused(let reasons) = result else {
            return XCTFail("Expected explicit refusal.")
        }
        XCTAssertEqual(reasons.count, 3)
        XCTAssertTrue(reasons.contains(where: { $0.contains("does not match") }))
        XCTAssertTrue(reasons.contains(where: { $0.contains("prohibited execution") }))
        XCTAssertTrue(reasons.contains(where: { $0.contains("bounded project-relative") }))
    }

    func testPolicyRefusesAbsoluteScopeReturnedByPlanner() {
        let result = policy.validate(
            proposal: proposal(scopeAllowlist: ["/policies/local_planner.yaml"]),
            selectedProjectID: projectID,
            contextPacket: packet(),
            workerAlreadyActive: false
        )

        guard case .refused(let reasons) = result else {
            return XCTFail("Absolute scope must not become launchable.")
        }
        XCTAssertTrue(reasons.contains(where: { $0.contains("bounded project-relative") }))
    }

    func testPolicyRequiresOneWorkerVerificationAndNonGoals() {
        let value = proposal(
            workerCount: 2,
            verificationSteps: [],
            nonGoals: []
        )

        let result = policy.validate(
            proposal: value,
            selectedProjectID: projectID,
            contextPacket: packet(),
            workerAlreadyActive: false
        )

        guard case .refused(let refusalReasons) = result else {
            return XCTFail("Multiple workers must be refused before revision advice.")
        }
        XCTAssertTrue(refusalReasons.contains(where: { $0.contains("exactly one") }))
    }

    func testApprovalTokenInvalidatesAfterProposalRevision() {
        let original = proposal()
        let revised = proposal(objective: "A changed objective requires a fresh approval.")
        let token = OrchestrationApprovalToken(proposal: original)

        XCTAssertTrue(token.matches(original, selectedProjectID: projectID))
        XCTAssertFalse(token.matches(revised, selectedProjectID: projectID))
    }

    func testReducerCannotLaunchBeforeMatchingApprovalAndLaunchedIsNotCompletion() {
        let value = proposal()
        let token = OrchestrationApprovalToken(proposal: value)

        let noOp = OrchestrationRunReducer.reduce(
            .proposalReady(value),
            event: .recordLaunch(taskSessionID: "task-1")
        )
        XCTAssertEqual(noOp, .proposalReady(value))

        let approvalRequired = OrchestrationRunReducer.reduce(
            .proposalReady(value),
            event: .requestApproval
        )
        let launching = OrchestrationRunReducer.reduce(
            approvalRequired,
            event: .beginLaunch(token, selectedProjectID: projectID)
        )
        let launched = OrchestrationRunReducer.reduce(
            launching,
            event: .recordLaunch(taskSessionID: "task-1")
        )

        XCTAssertEqual(launched, .launched(taskSessionID: "task-1"))
    }

    func testReducerRefusesStaleApproval() {
        let value = proposal()
        let stale = OrchestrationApprovalToken(proposal: proposal(objective: "Old proposal"))
        let state = OrchestrationRunState.approvalRequired(value, OrchestrationApprovalToken(proposal: value))

        let result = OrchestrationRunReducer.reduce(
            state,
            event: .beginLaunch(stale, selectedProjectID: projectID)
        )

        guard case .failed(let reason) = result else {
            return XCTFail("Expected stale approval failure.")
        }
        XCTAssertTrue(reason.contains("stale"))
    }

    func testFixturePlannerProducesResponseWithoutProvider() async throws {
        let value = proposal()
        let fixture = FixtureOrchestrationPlanner(
            response: OrchestrationPlannerResponse(
                text: "Fixture proposal only.",
                proposal: value,
                backendLabel: "Fixture — no local model"
            )
        )

        let response = try await fixture.propose(
            request: "Propose a bounded task.",
            context: packet()
        )
        XCTAssertEqual(response.proposal, value)
        XCTAssertEqual(response.backendLabel, "Fixture — no local model")
    }

    func testVisiblePlannerTextOnlyBecomesProposalWhenEnvelopeIsDeclared() throws {
        let value = proposal()
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)

        let declared = OrchestrationPlannerResponse.fromVisibleText(
            json,
            backendLabel: "Local planner"
        )
        XCTAssertEqual(declared.proposal, value)

        let prose = OrchestrationPlannerResponse.fromVisibleText(
            "I suggest changing the core contract.",
            backendLabel: "Local planner"
        )
        XCTAssertNil(prose.proposal)
        XCTAssertEqual(prose.text, "I suggest changing the core contract.")
    }
}
