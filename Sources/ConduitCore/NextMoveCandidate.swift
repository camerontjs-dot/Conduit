import CryptoKit
import Foundation

public enum NextMoveKind: String, Codable, CaseIterable, Sendable {
    case prompt
    case inspect
    case verify
    case handoff
    case orchestrate
    case wait
}

/// Support for this suggestion, not capability, entitlement or task acceptance.
public enum NextMoveSupport: String, Codable, CaseIterable, Sendable {
    case supported
    case unsupported
    case unknown
}

public enum NextMoveObligationState: String, Codable, CaseIterable, Sendable {
    case satisfied
    case missing
    case blocked
    case unknown
}

public struct NextMoveObligation: Codable, Equatable, Sendable {
    public let id: String
    public let description: String
    public let state: NextMoveObligationState

    public init(id: String, description: String, state: NextMoveObligationState) {
        self.id = id
        self.description = description
        self.state = state
    }
}

/// Existing context provenance remains labelled; consulting a nomination never
/// converts it into source authority. No source bytes are fetched by this type.
public struct NextMoveBasis: Codable, Equatable, Sendable {
    public let source: AgentContextItem
    public let inclusionReasons: [ContextInclusionReason]

    public init(source: AgentContextItem, inclusionReasons: [ContextInclusionReason]) {
        self.source = source
        self.inclusionReasons = inclusionReasons
    }
}

/// A caller-supplied version of the state used to derive a suggestion. An opaque
/// snapshot identity is not evidence that supervisory state is authoritative.
/// Missing snapshot identity is UNKNOWN. Context and repository identities stay
/// separate from task identity, and all supplied fields take part in comparison.
public struct NextMoveInputStateIdentity: Codable, Equatable, Sendable {
    public let projectID: String
    public let taskIdentity: String
    public let snapshotIdentity: String?
    public let contextManifestIdentity: String?
    public let repositoryIdentity: ContextRepositoryIdentity?

    public init(
        projectID: String,
        taskIdentity: String,
        snapshotIdentity: String?,
        contextManifestIdentity: String? = nil,
        repositoryIdentity: ContextRepositoryIdentity? = nil
    ) {
        self.projectID = projectID
        self.taskIdentity = taskIdentity
        self.snapshotIdentity = snapshotIdentity
        self.contextManifestIdentity = contextManifestIdentity
        self.repositoryIdentity = repositoryIdentity
    }
}

public enum NextMoveReviewSurface: String, Codable, Sendable {
    case composerDraft
    case inspection
    case orchestrationProposal
    case wait
}

public enum NextMoveAssessmentDisposition: String, Codable, Sendable {
    case reviewable
    case unknown
    case blocked
    case stale
    case invalid
}

/// A review assessment has no approval token, route, delivery or launch grant.
/// UNKNOWN obligations are retained even when a separate hard blocker wins.
public struct NextMoveAssessment: Codable, Equatable, Sendable {
    public let disposition: NextMoveAssessmentDisposition
    public let reasons: [String]
    public let support: NextMoveSupport
    public let obligations: [NextMoveObligation]
}

/// An editable derived proposal. This pure value never sends a message, reads a
/// live feed, creates a task, chooses a route or grants authority. New work uses
/// the existing OrchestrationProposal seam and still needs normal policy review.
public struct NextMoveCandidate: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let kind: NextMoveKind
    public let proposedText: String
    public let reason: String
    public let basis: [NextMoveBasis]
    public let support: NextMoveSupport
    public let obligations: [NextMoveObligation]
    public let generatedAt: Date
    public let inputState: NextMoveInputStateIdentity
    public let stagedProposal: OrchestrationProposal?

    public init(
        schemaVersion: Int = NextMoveCandidate.currentSchemaVersion,
        kind: NextMoveKind,
        proposedText: String,
        reason: String,
        basis: [NextMoveBasis],
        support: NextMoveSupport,
        obligations: [NextMoveObligation],
        generatedAt: Date,
        inputState: NextMoveInputStateIdentity,
        stagedProposal: OrchestrationProposal? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.proposedText = proposedText
        self.reason = reason
        self.basis = basis
        self.support = support
        self.obligations = obligations
        self.generatedAt = generatedAt
        self.inputState = inputState
        self.stagedProposal = stagedProposal
    }

    public var requiresOrchestrationPolicy: Bool {
        stagedProposal != nil || kind == .handoff || kind == .orchestrate
    }

    /// Describes where an operator would review a valid candidate. It does not
    /// perform the action, and must not bypass `assess(currentInputState:)`.
    public var reviewSurface: NextMoveReviewSurface {
        if requiresOrchestrationPolicy { return .orchestrationProposal }
        switch kind {
        case .inspect: return .inspection
        case .wait: return .wait
        default: return .composerDraft
        }
    }

    /// Editing preserves the original derivation evidence and timestamp. It
    /// changes the revision identity without manufacturing approval or freshness.
    public func editingProposedText(_ text: String) -> NextMoveCandidate {
        NextMoveCandidate(
            schemaVersion: schemaVersion,
            kind: kind,
            proposedText: text,
            reason: reason,
            basis: basis,
            support: support,
            obligations: obligations,
            generatedAt: generatedAt,
            inputState: inputState,
            stagedProposal: stagedProposal
        )
    }

    /// Exact ordered value bytes, reproducible with a supplied generation time.
    /// Array order is retained; fields are encoded structurally, not joined by a
    /// delimiter. Encoding failure never produces a shared fallback identity.
    public func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(self)
    }

    public var revisionIdentity: String? {
        guard let data = try? canonicalData() else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func decodeCanonicalData(_ data: Data) throws -> NextMoveCandidate {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(Self.self, from: data)
    }

    /// The result only governs whether a proposal is ready for operator review.
    /// The caller must supply a current state identity. Equality does not prove
    /// that identity's authority, and generation time is never a freshness oracle.
    public func assess(currentInputState: NextMoveInputStateIdentity?) -> NextMoveAssessment {
        var invalid: [String] = []
        var stale: [String] = []
        var blocked: [String] = []
        var unknown: [String] = []

        if schemaVersion != Self.currentSchemaVersion {
            invalid.append("Unsupported Next Move schema version.")
        }
        if Self.isBlank(proposedText) { invalid.append("Proposed editable text is required.") }
        if Self.isBlank(reason) { invalid.append("A derivation reason is required.") }
        if !generatedAt.timeIntervalSince1970.isFinite {
            invalid.append("Generation time must be finite.")
        }
        if Self.isBlank(inputState.projectID) || Self.isBlank(inputState.taskIdentity) {
            invalid.append("Separate project and task identities are required.")
        }
        invalid += Self.declaredIdentityReasons(inputState, label: "Derivation")
        if inputState.snapshotIdentity.map(Self.isBlank) ?? true {
            unknown.append("Derivation state snapshot identity is UNKNOWN.")
        }
        if let currentInputState {
            if Self.isBlank(currentInputState.projectID) || Self.isBlank(currentInputState.taskIdentity) {
                invalid.append("Current project and task identities are required.")
            }
            invalid += Self.declaredIdentityReasons(currentInputState, label: "Current")
            if currentInputState.snapshotIdentity.map(Self.isBlank) ?? true {
                unknown.append("Current state snapshot identity is UNKNOWN.")
            }
            if inputState != currentInputState {
                stale.append("Input state changed; this suggestion must be rederived or visibly marked stale.")
            }
        } else {
            unknown.append("Current input state was not supplied.")
        }

        if basis.isEmpty && kind != .wait {
            invalid.append("Nontrivial suggestions require consulted source/rule identities.")
        }
        var sourceIDs: Set<String> = []
        for item in basis {
            let source = item.source
            if Self.isBlank(source.id) || Self.isBlank(source.sourceReference) || item.inclusionReasons.isEmpty {
                invalid.append("Every consulted source needs an identity, locator and inclusion reason.")
            }
            if !sourceIDs.insert(source.id).inserted {
                invalid.append("Duplicate consulted source identity: \(source.id)")
            }
            if source.revisionIdentity.map(Self.isBlank) ?? true {
                unknown.append("Consulted source revision is UNKNOWN: \(source.id)")
            }
            switch source.freshness {
            case .current: break
            case .stale(let reason): stale.append("Consulted source is stale: \(source.id): \(reason)")
            case .unknown: unknown.append("Consulted source freshness is UNKNOWN: \(source.id)")
            }
        }

        var obligationIDs: Set<String> = []
        for obligation in obligations {
            if Self.isBlank(obligation.id) || Self.isBlank(obligation.description) {
                invalid.append("Every obligation needs an identity and description.")
            }
            if !obligationIDs.insert(obligation.id).inserted {
                invalid.append("Duplicate obligation identity: \(obligation.id)")
            }
            switch obligation.state {
            case .satisfied: break
            case .missing, .blocked: blocked.append("Unmet obligation: \(obligation.id): \(obligation.description)")
            case .unknown: unknown.append("Obligation is UNKNOWN: \(obligation.id): \(obligation.description)")
            }
        }
        switch support {
        case .supported: break
        case .unsupported: blocked.append("This suggestion is explicitly unsupported.")
        case .unknown: unknown.append("Suggestion support is UNKNOWN.")
        }

        if (kind == .handoff || kind == .orchestrate) && stagedProposal == nil {
            invalid.append("New work requires a staged OrchestrationProposal for normal policy/routing.")
        }
        if (kind == .prompt || kind == .wait) && stagedProposal != nil {
            invalid.append("Same-thread prompt/wait cannot carry a new-work proposal.")
        }
        if let stagedProposal {
            if stagedProposal.projectID != inputState.projectID {
                invalid.append("Staged proposal project must match the derivation project.")
            }
            if stagedProposal.schemaVersion != OrchestrationProposal.currentSchemaVersion {
                invalid.append("Unsupported staged OrchestrationProposal schema version.")
            }
        }

        let disposition: NextMoveAssessmentDisposition
        if !invalid.isEmpty { disposition = .invalid }
        else if !stale.isEmpty { disposition = .stale }
        else if !blocked.isEmpty { disposition = .blocked }
        else if !unknown.isEmpty { disposition = .unknown }
        else { disposition = .reviewable }
        return NextMoveAssessment(
            disposition: disposition,
            reasons: invalid + stale + blocked + unknown,
            support: support,
            obligations: obligations
        )
    }

    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func declaredIdentityReasons(
        _ state: NextMoveInputStateIdentity,
        label: String
    ) -> [String] {
        var reasons: [String] = []
        if let manifest = state.contextManifestIdentity, isBlank(manifest) {
            reasons.append("\(label) Context Manifest identity must not be blank when supplied.")
        }
        if let repository = state.repositoryIdentity {
            let declaredFields = [repository.repository, repository.scopePath, repository.branch, repository.commitSHA]
            if declaredFields.compactMap({ $0 }).contains(where: isBlank) {
                reasons.append("\(label) repository identity must not contain a blank declared field.")
            }
        }
        return reasons
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, kind, proposedText, reason, basis, support, obligations
        case generatedAt, inputState, stagedProposal
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    /// Unknown candidate fields are rejected, including attempts to smuggle an
    /// auto-send, approval or route grant into a proposal-shaped envelope.
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: AnyKey.self)
        let known = Set(CodingKeys.allCases.map(\.rawValue))
        let unexpected = fields.allKeys.map(\.stringValue).filter { !known.contains($0) }.sorted()
        if !unexpected.isEmpty {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unsupported Next Move fields: \(unexpected.joined(separator: ", "))"
            ))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try values.decode(Int.self, forKey: .schemaVersion),
            kind: try values.decode(NextMoveKind.self, forKey: .kind),
            proposedText: try values.decode(String.self, forKey: .proposedText),
            reason: try values.decode(String.self, forKey: .reason),
            basis: try values.decode([NextMoveBasis].self, forKey: .basis),
            support: try values.decode(NextMoveSupport.self, forKey: .support),
            obligations: try values.decode([NextMoveObligation].self, forKey: .obligations),
            generatedAt: try values.decode(Date.self, forKey: .generatedAt),
            inputState: try values.decode(NextMoveInputStateIdentity.self, forKey: .inputState),
            stagedProposal: try values.decodeIfPresent(OrchestrationProposal.self, forKey: .stagedProposal)
        )
    }
}
