import Foundation

/// What `conduit_create_task` decides before anything can change (contract §18).
///
/// This is the first slice of the AppModel extraction. The whole MCP write path
/// — all sixteen `sessionAPI*` functions — lives in the app target, which
/// XCTest cannot load, so none of it has unit coverage. That is why the
/// duplicate-objective defect, the intermittent PTY observation gap, and a
/// provider error reported as a completed turn all passed the deterministic
/// suite and failed on the first live run.
///
/// The decisions here are pure: given the write gate, the enabled profiles, and
/// the known project slugs, the outcome is fully determined. Moving them to
/// Core makes the refusal contract testable without AppKit, per AGENTS.md rule
/// 8 and the §18 constraint to grow testable control-plane types in Core rather
/// than rewrite the runtime.
///
/// It deliberately does **not** decide admission. Admission consumes rate and
/// capacity budget, so it must run only after the request is known to name a
/// real agent and project — otherwise a typo burns create budget or holds a
/// reservation. That ordering was previously enforced only by the sequence of
/// statements in one 5,000-line function, with no test. `admitted` is the state
/// that says the request has earned the right to be admitted; it is not itself
/// an admission.
public enum CreateTaskPrecondition: Equatable, Sendable {
    /// The operator has not enabled Session API writes.
    case writesDisabled
    /// No enabled profile matches the requested agent.
    case unknownAgent(requested: String, enabled: [String])
    /// No known project matches the requested slug.
    case unknownProject(requested: String)
    /// The request names a real agent and project. Admission may now run.
    case admitted(agentName: String, projectSlug: String)

    /// True only when the caller's request may proceed to admission.
    public var mayProceedToAdmission: Bool {
        if case .admitted = self { return true }
        return false
    }

    /// Evaluate in the order the write path requires.
    ///
    /// Order is part of the contract, not an implementation detail: the gate
    /// precedes identity resolution so a refused caller learns nothing about
    /// which agents or projects exist, and resolution precedes admission so an
    /// unresolvable request cannot consume budget.
    public static func evaluate(
        writesEnabled: Bool,
        requestedAgent: String,
        among enabledAgents: [AgentProfile],
        requestedProject: String,
        projectSlugs: [String]
    ) -> CreateTaskPrecondition {
        guard writesEnabled else { return .writesDisabled }

        guard let agent = enabledAgents.first(where: {
            ConduitSessionAPI.matchesAgent($0, name: requestedAgent)
        }) else {
            return .unknownAgent(
                requested: requestedAgent,
                enabled: enabledAgents.map(\.name)
            )
        }

        let needle = requestedProject.lowercased()
        guard let slug = projectSlugs.first(where: { $0.lowercased() == needle })
        else {
            return .unknownProject(requested: requestedProject)
        }

        return .admitted(agentName: agent.name, projectSlug: slug)
    }

    /// The refusal payload for a precondition that stops the request.
    ///
    /// `nil` for `admitted`, which is not a refusal. Field names and wording
    /// are preserved exactly as the app target emitted them, so extracting
    /// this changes no caller-visible behavior.
    public var refusalPayload: [String: Any]? {
        switch self {
        case .writesDisabled:
            return ["error": "write tools are disabled"]
        case .unknownAgent(let requested, let enabled):
            return [
                "error": "unknown or disabled agent",
                "agent": requested,
                "enabled": enabled,
            ]
        case .unknownProject(let requested):
            return ["error": "unknown project_slug", "project_slug": requested]
        case .admitted:
            return nil
        }
    }
}
