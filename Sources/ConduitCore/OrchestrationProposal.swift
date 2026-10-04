import CryptoKit
import Foundation

/// A bounded packet selected by the operator before a planner is asked for a
/// proposal. It preserves MindGraph's scope and citation boundaries instead of
/// turning a search result into unlabelled prompt context.
public struct OrchestrationContextPacket: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let projectID: String
    public let generatedAt: Date
    public let entries: [OrchestrationContextEntry]

    public init(
        schemaVersion: Int = OrchestrationContextPacket.currentSchemaVersion,
        projectID: String,
        generatedAt: Date = Date(),
        entries: [OrchestrationContextEntry]
    ) {
        self.schemaVersion = schemaVersion
        self.projectID = projectID
        self.generatedAt = generatedAt
        self.entries = entries
    }

    /// Presentation estimate. An unrepresentable total uses the largest
    /// displayable value; validation still rejects it even with that budget.
    /// Callers must use validationReasons, not this value, to admit a packet.
    public var tokenEstimate: Int {
        checkedTokenEstimate ?? Int.max
    }

    private var checkedTokenEstimate: Int? {
        var total = 0
        for entry in entries {
            let next = total.addingReportingOverflow(entry.tokenEstimate)
            guard !next.overflow else { return nil }
            total = next.partialValue
        }
        return total
    }

    public func validationReasons(maximumTokens: Int) -> [String] {
        var reasons: [String] = []
        if schemaVersion != Self.currentSchemaVersion {
            reasons.append("Unsupported context packet schema version.")
        }
        if projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reasons.append("A selected project is required.")
        }
        if entries.contains(where: { !$0.isLabelled }) {
            reasons.append("Every context entry must retain scope and citation labels.")
        }
        let total = checkedTokenEstimate
        if total == nil {
            reasons.append("Context token estimates exceed the supported integer range.")
        }
        if let total, total > maximumTokens {
            reasons.append("Selected context exceeds the planner budget.")
        }
        return reasons
    }
}

public struct OrchestrationContextEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let scope: OrchestrationContextScope
    public let displayPath: String
    public let citationClass: OrchestrationCitationClass
    public let excerpt: String
    public let tokenEstimate: Int
    public let selectedByOperator: Bool

    public init(
        id: String,
        scope: OrchestrationContextScope,
        displayPath: String,
        citationClass: OrchestrationCitationClass,
        excerpt: String,
        tokenEstimate: Int,
        selectedByOperator: Bool
    ) {
        self.id = id
        self.scope = scope
        self.displayPath = displayPath
        self.citationClass = citationClass
        self.excerpt = excerpt
        self.tokenEstimate = tokenEstimate
        self.selectedByOperator = selectedByOperator
    }

    public var isLabelled: Bool {
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !displayPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && tokenEstimate >= 0
    }
}

public enum OrchestrationContextScope: String, Codable, CaseIterable, Sendable {
    case knowledge
    case projects

    public var displayName: String {
        switch self {
        case .knowledge: return "Knowledge"
        case .projects: return "Project status"
        }
    }
}

public enum OrchestrationCitationClass: String, Codable, CaseIterable, Sendable {
    case citable
    case notCitable
    case unknown

    public var displayName: String {
        switch self {
        case .citable: return "Citable nomination"
        case .notCitable: return "Not citable"
        case .unknown: return "Citation status unknown"
        }
    }
}

/// A planner suggestion. This is deliberately not a launch request: execution
/// stays behind an operator approval in the app layer.
public struct OrchestrationProposal: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let objective: String
    public let projectID: String
    public let suggestedAgent: String
    public let workerCount: Int
    public let scopeAllowlist: [String]
    public let deliverables: [String]
    public let verificationSteps: [String]
    public let risks: [String]
    public let nonGoals: [String]

    public init(
        schemaVersion: Int = OrchestrationProposal.currentSchemaVersion,
        objective: String,
        projectID: String,
        suggestedAgent: String,
        workerCount: Int = 1,
        scopeAllowlist: [String],
        deliverables: [String],
        verificationSteps: [String],
        risks: [String],
        nonGoals: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.objective = objective
        self.projectID = projectID
        self.suggestedAgent = suggestedAgent
        self.workerCount = workerCount
        self.scopeAllowlist = scopeAllowlist
        self.deliverables = deliverables
        self.verificationSteps = verificationSteps
        self.risks = risks
        self.nonGoals = nonGoals
    }

    /// Stable across process launches for an approval token. This identifies a
    /// proposal revision; it is not a signature or a source-of-truth record.
    public var fingerprint: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "unencodable" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum OrchestrationProposalDecodeError: LocalizedError, Equatable, Sendable {
    case missingDeclaredEnvelope
    case malformedJSON(String)

    public var errorDescription: String? {
        switch self {
        case .missingDeclaredEnvelope:
            return "Planner response did not contain a declared proposal envelope."
        case .malformedJSON(let reason):
            return "Planner proposal JSON could not be decoded: \(reason)"
        }
    }
}

public enum OrchestrationProposalDecoder {
    /// Decode only an all-JSON response or a single fenced `json` block. Do
    /// not scrape arbitrary prose into an executable-looking proposal.
    public static func decode(from response: String) -> Result<OrchestrationProposal, OrchestrationProposalDecodeError> {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String
        if trimmed.hasPrefix("```json") && trimmed.hasSuffix("```") {
            candidate = String(trimmed.dropFirst(7).dropLast(3))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") {
            candidate = trimmed
        } else {
            return .failure(.missingDeclaredEnvelope)
        }

        do {
            return .success(try JSONDecoder().decode(OrchestrationProposal.self, from: Data(candidate.utf8)))
        } catch {
            return .failure(.malformedJSON(error.localizedDescription))
        }
    }
}

public struct OrchestrationApprovalToken: Codable, Equatable, Sendable {
    public let proposalFingerprint: String
    public let projectID: String

    public init(proposal: OrchestrationProposal) {
        proposalFingerprint = proposal.fingerprint
        projectID = proposal.projectID
    }

    public func matches(_ proposal: OrchestrationProposal, selectedProjectID: String) -> Bool {
        proposalFingerprint == proposal.fingerprint
            && projectID == proposal.projectID
            && projectID == selectedProjectID
    }
}
