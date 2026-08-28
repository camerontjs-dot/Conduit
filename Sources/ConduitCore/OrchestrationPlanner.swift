import Foundation

/// App-side code supplies a planner implementation. This Core seam has no
/// process, network, or task-lifecycle capability.
public protocol OrchestrationPlanner: Sendable {
    func propose(
        request: String,
        context: OrchestrationContextPacket
    ) async throws -> OrchestrationPlannerResponse
}

public struct OrchestrationPlannerResponse: Equatable, Sendable {
    public let text: String
    public let proposal: OrchestrationProposal?
    public let backendLabel: String

    public init(text: String, proposal: OrchestrationProposal?, backendLabel: String) {
        self.text = text
        self.proposal = proposal
        self.backendLabel = backendLabel
    }

    /// A visible planner reply is retained even when it does not contain the
    /// declared proposal envelope. Prose must never be scraped into a proposal.
    public static func fromVisibleText(
        _ text: String,
        backendLabel: String
    ) -> OrchestrationPlannerResponse {
        let proposal = try? OrchestrationProposalDecoder.decode(from: text).get()
        return OrchestrationPlannerResponse(
            text: text,
            proposal: proposal,
            backendLabel: backendLabel
        )
    }
}

public enum OrchestrationPlannerError: LocalizedError, Equatable, Sendable {
    case unavailable(String)
    case malformedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return "Planner unavailable: \(reason)"
        case .malformedResponse(let reason): return "Planner response malformed: \(reason)"
        }
    }
}

/// Deterministic fixture used to exercise proposal UI and policy without
/// starting OpenCode, Ollama, a network client, or a worker task.
public struct FixtureOrchestrationPlanner: OrchestrationPlanner {
    public let response: OrchestrationPlannerResponse

    public init(response: OrchestrationPlannerResponse) {
        self.response = response
    }

    public func propose(
        request: String,
        context: OrchestrationContextPacket
    ) async throws -> OrchestrationPlannerResponse {
        guard !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OrchestrationPlannerError.malformedResponse("A planning request is required.")
        }
        return response
    }
}
