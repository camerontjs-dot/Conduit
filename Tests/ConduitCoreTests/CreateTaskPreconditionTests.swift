import XCTest
@testable import ConduitCore

/// Coverage for `conduit_create_task`'s refusal contract and, more importantly,
/// its **ordering** invariant.
///
/// This is the first slice of the AppModel extraction (contract §18). The
/// ordering below previously existed only as the sequence of statements inside
/// a 5,000-line function in the app target, where XCTest cannot reach it. The
/// comment in that function stated the invariant; nothing enforced it.
final class CreateTaskPreconditionTests: XCTestCase {

    private let agents = [
        AgentProfile(name: "Shell", command: "/bin/zsh"),
        AgentProfile(name: "Codex", command: "codex"),
        AgentProfile(name: "OpenCode", command: "opencode"),
    ]
    private let slugs = ["conduit", "income-engine", "workstation"]

    private func evaluate(
        writesEnabled: Bool = true,
        agent: String = "Shell",
        project: String = "conduit"
    ) -> CreateTaskPrecondition {
        CreateTaskPrecondition.evaluate(
            writesEnabled: writesEnabled,
            requestedAgent: agent,
            among: agents,
            requestedProject: project,
            projectSlugs: slugs
        )
    }

    // MARK: - Ordering (the invariant with no prior coverage)

    func testWriteGateIsCheckedBeforeIdentityIsResolved() {
        // A refused caller must not learn which agents exist. If resolution ran
        // first, an unknown-agent refusal would leak the enabled list to a
        // caller who is not permitted to write at all.
        let decision = evaluate(writesEnabled: false, agent: "NoSuchAgent")
        XCTAssertEqual(decision, .writesDisabled)
        let payload = decision.refusalPayload ?? [:]
        XCTAssertNil(
            payload["enabled"],
            "A caller refused at the gate must not receive the agent roster."
        )
    }

    func testWriteGateIsCheckedBeforeProjectIsResolved() {
        let decision = evaluate(writesEnabled: false, project: "no-such-project")
        XCTAssertEqual(decision, .writesDisabled)
    }

    func testAnUnresolvableRequestNeverReachesAdmission() {
        // Admission consumes create-rate and capacity budget. A typo must not
        // be able to burn either, so neither refusal may report as admissible.
        for decision in [
            evaluate(agent: "NoSuchAgent"),
            evaluate(project: "no-such-project"),
            evaluate(writesEnabled: false),
        ] {
            XCTAssertFalse(
                decision.mayProceedToAdmission,
                "\(decision) must not reach admission."
            )
        }
    }

    func testAgentIsResolvedBeforeProject() {
        // Both are wrong; the agent refusal is the one the caller sees. This
        // pins the order rather than leaving it to statement sequence.
        let decision = evaluate(agent: "NoSuchAgent", project: "no-such-project")
        guard case .unknownAgent = decision else {
            return XCTFail("expected unknownAgent, got \(decision)")
        }
    }

    // MARK: - Resolution

    func testResolvesByProfileName() {
        XCTAssertEqual(evaluate(agent: "Codex"),
                       .admitted(agentName: "Codex", projectSlug: "conduit"))
    }

    func testResolvesByCommandBasename() {
        // `opencode` is the command; the profile is named "OpenCode".
        XCTAssertEqual(evaluate(agent: "opencode"),
                       .admitted(agentName: "OpenCode", projectSlug: "conduit"))
    }

    func testAgentMatchIsCaseInsensitive() {
        XCTAssertEqual(evaluate(agent: "cOdEx"),
                       .admitted(agentName: "Codex", projectSlug: "conduit"))
    }

    func testProjectMatchIsCaseInsensitiveAndReturnsTheCanonicalSlug() {
        // The canonical slug is returned, not the caller's casing — it becomes
        // the session working directory.
        XCTAssertEqual(evaluate(project: "CONDUIT"),
                       .admitted(agentName: "Shell", projectSlug: "conduit"))
    }

    func testEmptyAgentIsRefusedRatherThanMatchingAnything() {
        guard case .unknownAgent = evaluate(agent: "") else {
            return XCTFail("an empty agent name must not resolve")
        }
    }

    func testEmptyProjectIsRefused() {
        guard case .unknownProject = evaluate(project: "") else {
            return XCTFail("an empty project slug must not resolve")
        }
    }

    func testNoEnabledAgentsRefusesWithAnEmptyRoster() {
        let decision = CreateTaskPrecondition.evaluate(
            writesEnabled: true,
            requestedAgent: "Shell",
            among: [],
            requestedProject: "conduit",
            projectSlugs: slugs
        )
        XCTAssertEqual(decision, .unknownAgent(requested: "Shell", enabled: []))
    }

    // MARK: - Refusal payloads (byte-compatible with the app target)

    func testRefusalPayloadsMatchTheShippedWording() {
        XCTAssertEqual(
            CreateTaskPrecondition.writesDisabled.refusalPayload?["error"] as? String,
            "write tools are disabled"
        )
        let unknownAgent = CreateTaskPrecondition
            .unknownAgent(requested: "X", enabled: ["Shell"]).refusalPayload ?? [:]
        XCTAssertEqual(unknownAgent["error"] as? String, "unknown or disabled agent")
        XCTAssertEqual(unknownAgent["agent"] as? String, "X")
        XCTAssertEqual(unknownAgent["enabled"] as? [String], ["Shell"])

        let unknownProject = CreateTaskPrecondition
            .unknownProject(requested: "Y").refusalPayload ?? [:]
        XCTAssertEqual(unknownProject["error"] as? String, "unknown project_slug")
        XCTAssertEqual(unknownProject["project_slug"] as? String, "Y")
    }

    func testAdmittedHasNoRefusalPayload() {
        XCTAssertNil(evaluate().refusalPayload)
        XCTAssertTrue(evaluate().mayProceedToAdmission)
    }
}
