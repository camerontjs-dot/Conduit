import Foundation

/// The app-level workspace selector. `sessions` keeps the existing task rail
/// and terminal presentation intact; `orchestrate` is not a session surface.
public enum ConduitWorkspace: String, CaseIterable, Codable, Sendable {
    case sessions
    case orchestrate

    public var displayName: String {
        switch self {
        case .sessions: return "Sessions"
        case .orchestrate: return "Orchestrate"
        }
    }

    public var symbolName: String {
        switch self {
        case .sessions: return "rectangle.3.group"
        case .orchestrate: return "point.3.connected.trianglepath.dotted"
        }
    }
}

/// Selection rules for the proposal workspace. They remain independent from
/// worker creation: choosing the root labels a proposal's scope but never
/// grants a planner access to that directory.
public enum OrchestrationScopeSelection {
    public static func selectableProjects(
        from projects: [MainframeProject]
    ) -> [MainframeProject] {
        projects
    }

    public static func selectedProject(
        explicitID: String?,
        currentSelection: MainframeProject?,
        from projects: [MainframeProject]
    ) -> MainframeProject? {
        if let explicitID,
           let project = projects.first(where: { $0.id == explicitID })
        {
            return project
        }
        return currentSelection ?? projects.first
    }
}

public enum OrchestrationProposalValidation: Equatable, Sendable {
    case valid
    case needsOperatorRevision(reasons: [String])
    case refused(reasons: [String])

    public var reasons: [String] {
        switch self {
        case .valid: return []
        case .needsOperatorRevision(let reasons), .refused(let reasons): return reasons
        }
    }
}

public struct OrchestrationProposalPolicy: Sendable {
    public let allowedAgentNames: Set<String>
    public let maximumContextTokens: Int

    public init(allowedAgentNames: Set<String>, maximumContextTokens: Int = 1_200) {
        self.allowedAgentNames = allowedAgentNames
        self.maximumContextTokens = maximumContextTokens
    }

    public func validate(
        proposal: OrchestrationProposal,
        selectedProjectID: String,
        contextPacket: OrchestrationContextPacket,
        workerAlreadyActive: Bool
    ) -> OrchestrationProposalValidation {
        var refusalReasons: [String] = []
        var revisionReasons = contextPacket.validationReasons(maximumTokens: maximumContextTokens)

        if proposal.schemaVersion != OrchestrationProposal.currentSchemaVersion {
            refusalReasons.append("Unsupported proposal schema version.")
        }
        if proposal.projectID != selectedProjectID || proposal.projectID != contextPacket.projectID {
            refusalReasons.append("Proposal project does not match the selected context project.")
        }
        if workerAlreadyActive || proposal.workerCount != 1 {
            refusalReasons.append("This workspace permits exactly one approved worker at a time.")
        }
        if !allowedAgentNames.contains(proposal.suggestedAgent) {
            refusalReasons.append("Suggested agent is not in the operator-approved allowlist.")
        }

        if proposal.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            revisionReasons.append("Proposal objective is required.")
        }
        if proposal.scopeAllowlist.isEmpty {
            revisionReasons.append("Proposal needs a bounded scope allowlist.")
        }
        if proposal.deliverables.isEmpty {
            revisionReasons.append("Proposal needs at least one expected deliverable.")
        }
        if proposal.verificationSteps.isEmpty {
            revisionReasons.append("Proposal needs independent verification steps.")
        }
        if proposal.nonGoals.isEmpty {
            revisionReasons.append("Proposal needs explicit non-goals.")
        }

        let freeText = [proposal.objective]
            + proposal.scopeAllowlist
            + proposal.deliverables
            + proposal.verificationSteps
            + proposal.risks
            + proposal.nonGoals
        if freeText.contains(where: Self.containsForbiddenExecutionIntent) {
            refusalReasons.append("Proposal contains a prohibited execution, remote, or approval instruction.")
        }
        if proposal.scopeAllowlist.contains(where: Self.isBroadScope) {
            refusalReasons.append("Proposal scope must name bounded project-relative paths.")
        }

        if !refusalReasons.isEmpty { return .refused(reasons: refusalReasons) }
        if !revisionReasons.isEmpty { return .needsOperatorRevision(reasons: revisionReasons) }
        return .valid
    }

    private static func isBroadScope(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            || trimmed == "*"
            || trimmed == "."
            || trimmed == "/"
            || trimmed.hasPrefix("/")
            || trimmed.hasPrefix("~")
            || trimmed.hasPrefix("../")
            || trimmed.split(separator: "/").contains("..")
            || trimmed.contains("\\")
            || trimmed.contains("**")
    }

    private static func containsForbiddenExecutionIntent(_ value: String) -> Bool {
        let lower = value.lowercased()
        let forbiddenFragments = [
            "rm -rf", "sudo ", "curl ", "wget ", "http://", "https://",
            "network access", "remote execution", "approve permission",
            "auto-approve", "spawn subagent", "create subagent", "background task"
        ]
        return forbiddenFragments.contains(where: lower.contains)
    }
}

public enum OrchestrationRunState: Equatable, Sendable {
    case idle
    case preparingContext
    case awaitingPlanner
    case proposalReady(OrchestrationProposal)
    case approvalRequired(OrchestrationProposal, OrchestrationApprovalToken)
    case launching(OrchestrationProposal, OrchestrationApprovalToken)
    case launched(taskSessionID: String)
    case failed(reason: String)
}

public enum OrchestrationRunEvent: Equatable, Sendable {
    case beginContext
    case requestPlanner
    case receiveProposal(OrchestrationProposal)
    case requestApproval
    case beginLaunch(OrchestrationApprovalToken, selectedProjectID: String)
    case recordLaunch(taskSessionID: String)
    case fail(String)
    case reset
}

public enum OrchestrationRunReducer {
    public static func reduce(_ state: OrchestrationRunState, event: OrchestrationRunEvent) -> OrchestrationRunState {
        switch (state, event) {
        case (_, .reset):
            return .idle
        case (.idle, .beginContext):
            return .preparingContext
        case (.preparingContext, .requestPlanner):
            return .awaitingPlanner
        case (.awaitingPlanner, .receiveProposal(let proposal)):
            return .proposalReady(proposal)
        case (.proposalReady(let proposal), .requestApproval):
            return .approvalRequired(proposal, OrchestrationApprovalToken(proposal: proposal))
        case (.approvalRequired(let proposal, let expected), .beginLaunch(let supplied, let selectedProjectID)):
            guard supplied == expected, supplied.matches(proposal, selectedProjectID: selectedProjectID) else {
                return .failed(reason: "Approval is stale or does not match the reviewed proposal.")
            }
            return .launching(proposal, expected)
        case (.launching, .recordLaunch(let taskSessionID)):
            guard !taskSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failed(reason: "Conduit did not return a task session identifier.")
            }
            return .launched(taskSessionID: taskSessionID)
        case (_, .fail(let reason)):
            return .failed(reason: reason)
        default:
            return state
        }
    }
}
