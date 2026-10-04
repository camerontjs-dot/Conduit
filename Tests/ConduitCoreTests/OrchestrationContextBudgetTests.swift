import XCTest
@testable import ConduitCore

final class OrchestrationContextBudgetTests: XCTestCase {
    private let overflowReason = "Context token estimates exceed the supported integer range."
    private let labelReason = "Every context entry must retain scope and citation labels."
    private let budgetReason = "Selected context exceeds the planner budget."

    private func packet(_ estimates: [Int]) -> OrchestrationContextPacket {
        OrchestrationContextPacket(
            projectID: "context-budget-fixture",
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            entries: estimates.enumerated().map { index, estimate in
                OrchestrationContextEntry(
                    id: "entry-\(index)",
                    scope: .knowledge,
                    displayPath: "fixture/entry-\(index).md",
                    citationClass: .unknown,
                    excerpt: "Selected nomination only.",
                    tokenEstimate: estimate,
                    selectedByOperator: true
                )
            }
        )
    }

    private func validation(
        _ context: OrchestrationContextPacket,
        maximumTokens: Int = Int.max
    ) -> OrchestrationProposalValidation {
        let proposal = OrchestrationProposal(
            objective: "Review one bounded fixture.",
            projectID: context.projectID,
            suggestedAgent: "Fixture Planner",
            scopeAllowlist: ["fixture/"],
            deliverables: ["Review receipt"],
            verificationSteps: ["Inspect the retained fixture."],
            risks: [],
            nonGoals: ["No worker launch."]
        )
        return OrchestrationProposalPolicy(
            allowedAgentNames: [proposal.suggestedAgent],
            maximumContextTokens: maximumTokens
        ).validate(
            proposal: proposal,
            selectedProjectID: context.projectID,
            contextPacket: context,
            workerAlreadyActive: false
        )
    }

    func testOverflowRefusesEvenAtLargestBudget() {
        let context = packet([Int.max, 1])

        XCTAssertEqual(context.tokenEstimate, Int.max)
        XCTAssertEqual(context.entries.map(\.tokenEstimate), [Int.max, 1])
        XCTAssertEqual(context.validationReasons(maximumTokens: Int.max), [overflowReason])
        XCTAssertEqual(validation(context), .needsOperatorRevision(reasons: [overflowReason]))
    }

    func testDecodedOverflowRetainsInputAndRefusal() throws {
        let original = packet([1, Int.max])
        let bytes = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OrchestrationContextPacket.self, from: bytes)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.entries.map(\.tokenEstimate), [1, Int.max])
        XCTAssertEqual(decoded.validationReasons(maximumTokens: Int.max), [overflowReason])
        XCTAssertEqual(validation(decoded), .needsOperatorRevision(reasons: [overflowReason]))
    }

    func testExactRepresentableBoundaryRemainsValid() {
        let context = packet([Int.max - 1, 1])

        XCTAssertEqual(context.tokenEstimate, Int.max)
        XCTAssertEqual(context.validationReasons(maximumTokens: Int.max), [])
        XCTAssertEqual(validation(context), .valid)
        XCTAssertEqual(context.validationReasons(maximumTokens: Int.max - 1), [budgetReason])
    }

    func testNegativeEstimateCannotCancelPositiveBudgetUseIntoValidity() {
        let context = packet([-1, 2])

        XCTAssertEqual(context.tokenEstimate, 1)
        XCTAssertEqual(context.validationReasons(maximumTokens: 1), [labelReason])
        XCTAssertEqual(validation(context, maximumTokens: 1), .needsOperatorRevision(reasons: [labelReason]))
    }

    func testUnderflowRefusesWithoutChangingNegativeSourceEntries() {
        for estimates in [[Int.min, -1], [-1, Int.min]] {
            let context = packet(estimates)

            XCTAssertEqual(context.tokenEstimate, Int.max)
            XCTAssertEqual(context.entries.map(\.tokenEstimate), estimates)
            XCTAssertEqual(context.validationReasons(maximumTokens: Int.max), [labelReason, overflowReason])
            XCTAssertEqual(validation(context), .needsOperatorRevision(reasons: [labelReason, overflowReason]))
        }
    }

    func testLaterCorrectionCannotHideAnUnrepresentablePrefix() {
        for estimates in [[Int.max, 1, -1], [Int.min, -1, 1]] {
            let context = packet(estimates)

            XCTAssertEqual(context.entries.map(\.tokenEstimate), estimates)
            XCTAssertEqual(context.validationReasons(maximumTokens: Int.max), [labelReason, overflowReason])
        }
    }

    func testNegativeBudgetStillRejectsAnEmptyPacket() {
        let context = packet([])

        XCTAssertEqual(context.tokenEstimate, 0)
        XCTAssertEqual(context.validationReasons(maximumTokens: -1), [budgetReason])
        XCTAssertEqual(validation(context, maximumTokens: -1), .needsOperatorRevision(reasons: [budgetReason]))
    }

    func testZeroAndOrdinaryBudgetBehaviorIsPreserved() {
        XCTAssertEqual(packet([]).validationReasons(maximumTokens: 0), [])
        XCTAssertEqual(packet([0]).validationReasons(maximumTokens: 0), [])
        let context = packet([40, 30])

        XCTAssertEqual(context.tokenEstimate, 70)
        XCTAssertEqual(context.validationReasons(maximumTokens: 70), [])
        XCTAssertEqual(context.validationReasons(maximumTokens: 69), [budgetReason])
        XCTAssertEqual(validation(context, maximumTokens: 70), .valid)
    }
}
