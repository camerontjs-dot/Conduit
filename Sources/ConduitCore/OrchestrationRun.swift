import CryptoKit
import Foundation

/// Logical work identity. It is never a task, runtime attempt or provider ID.
public struct OrchestrationRunID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct OrchestrationStepID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// An immutable plan entry, not a scheduler or an instruction to launch.
public struct OrchestrationStep: Codable, Equatable, Sendable {
    public let id: OrchestrationStepID
    public let runID: OrchestrationRunID
    public let objective: String
    public let dependencies: [OrchestrationStepID]

    public init(id: OrchestrationStepID, runID: OrchestrationRunID, objective: String,
                dependencies: [OrchestrationStepID]) {
        self.id = id; self.runID = runID; self.objective = objective
        self.dependencies = dependencies
    }
}

/// A staged logical run. Storing a proposal does not approve its scope or route.
/// The existing OrchestrationRunState/Reducer remains the proposal UI seam.
public struct OrchestrationRun: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let id: OrchestrationRunID
    public let proposal: OrchestrationProposal
    public let planVersion: String
    public let policyVersion: String
    public let steps: [OrchestrationStep]

    public init(schemaVersion: Int = currentSchemaVersion, id: OrchestrationRunID,
                proposal: OrchestrationProposal, planVersion: String,
                policyVersion: String, steps: [OrchestrationStep]) {
        self.schemaVersion = schemaVersion; self.id = id; self.proposal = proposal
        self.planVersion = planVersion; self.policyVersion = policyVersion; self.steps = steps
    }

    public var proposalFingerprint: String { proposal.fingerprint }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion,
              proposal.schemaVersion == OrchestrationProposal.currentSchemaVersion,
              Self.nonblank(proposal.projectID), Self.nonblank(proposal.objective),
              Self.nonblank(planVersion), Self.nonblank(policyVersion),
              (1...64).contains(steps.count) else {
            throw OrchestrationJournalError.invalidCommand("Invalid run schema, identity, version or step count.")
        }
        var previous = Set<OrchestrationStepID>()
        for step in steps {
            guard step.runID == id, Self.nonblank(step.objective),
                  previous.insert(step.id).inserted,
                  Set(step.dependencies).count == step.dependencies.count,
                  !step.dependencies.contains(step.id),
                  step.dependencies.allSatisfy({ previous.contains($0) }) else {
                throw OrchestrationJournalError.invalidCommand("Steps require unique IDs and earlier, exact-run dependencies.")
            }
        }
    }

    static func nonblank(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A reference to an external receipt. Neither location nor a declared stamp
/// authenticates it. No source content, token or raw transcript is retained.
public struct OrchestrationEvidenceReference: Codable, Equatable, Sendable {
    public let sourceID: String
    public let revision: String
    public let observation: SupervisionObservationStamp
    public init(sourceID: String, revision: String, observation: SupervisionObservationStamp) {
        self.sourceID = sourceID; self.revision = revision; self.observation = observation
    }
    func validate() throws {
        guard OrchestrationRun.nonblank(sourceID), OrchestrationRun.nonblank(revision) else {
            throw OrchestrationJournalError.invalidCommand("Evidence needs an exact nonblank reference and revision.")
        }
        if let date = observation.observedAt.value, !date.timeIntervalSince1970.isFinite {
            throw OrchestrationJournalError.invalidCommand("Nonfinite observation time.")
        }
    }
    var supportsProgressObservation: Bool {
        [.conduitRecorded, .providerObserved, .processObserved, .shellHookObserved].contains(observation.authority)
            && observation.freshness == .current && observation.observedAt.isKnown
    }
    var supportsExternalDecision: Bool {
        observation.authority == .conduitRecorded && supportsProgressObservation
    }
}

/// Historical correlation only. #4/#53 still own every task/runtime/provider
/// lifecycle fact. Recording this does not acquire a worker or writer lease.
public struct OrchestrationWorkerReference: Codable, Equatable, Sendable {
    public let taskSessionID: TaskSessionID
    public let runtimeAttemptID: RuntimeAttemptID
    public let providerID: OrchestrationValue<String>
    public let providerSessionID: OrchestrationValue<String>
    public let providerTurnID: OrchestrationValue<String>
    public let workspaceID: OrchestrationValue<String>
    public let evidence: OrchestrationEvidenceReference

    public init(taskSessionID: TaskSessionID, runtimeAttemptID: RuntimeAttemptID,
                providerID: OrchestrationValue<String>, providerSessionID: OrchestrationValue<String>,
                providerTurnID: OrchestrationValue<String>, workspaceID: OrchestrationValue<String>,
                evidence: OrchestrationEvidenceReference) {
        self.taskSessionID = taskSessionID; self.runtimeAttemptID = runtimeAttemptID
        self.providerID = providerID; self.providerSessionID = providerSessionID
        self.providerTurnID = providerTurnID; self.workspaceID = workspaceID; self.evidence = evidence
    }
    func validate() throws {
        try evidence.validate()
        for value in [providerID, providerSessionID, providerTurnID, workspaceID] {
            if let known = value.value, !OrchestrationRun.nonblank(known) {
                throw OrchestrationJournalError.invalidCommand("A known worker identity cannot be blank.")
            }
        }
    }
}

public enum OrchestrationConditionKind: String, Codable, Equatable, Sendable {
    case routeReady, workerBound, inputRequired, verificationPending
    case capacityBlocked, writerCollision, workspaceMismatch
}

public struct OrchestrationCondition: Codable, Equatable, Sendable {
    public let stepID: OrchestrationStepID?
    public let kind: OrchestrationConditionKind
    public let value: OrchestrationValue<Bool>
    public let evidence: OrchestrationEvidenceReference
    public init(stepID: OrchestrationStepID?, kind: OrchestrationConditionKind,
                value: OrchestrationValue<Bool>, evidence: OrchestrationEvidenceReference) {
        self.stepID = stepID; self.kind = kind; self.value = value; self.evidence = evidence
    }
}

/// Progress is an explicitly recorded orchestration observation. A completion
/// report does not change verification or external acceptance.
public enum OrchestrationStepProgress: String, Codable, Equatable, Sendable {
    case pending, queued, running, blocked, completionReported, unknown
}
public enum OrchestrationRunDisposition: String, Codable, Equatable, Sendable {
    case completed, failed, cancelled, superseded
}

public enum OrchestrationJournalAction: Codable, Equatable, Sendable {
    case create(OrchestrationRun)
    case condition(OrchestrationCondition)
    case linkWorker(stepID: OrchestrationStepID, worker: OrchestrationWorkerReference)
    case releaseWorker(stepID: OrchestrationStepID, expected: OrchestrationWorkerReference)
    case progress(stepID: OrchestrationStepID, value: OrchestrationStepProgress, evidence: OrchestrationEvidenceReference)
    case artifact(stepID: OrchestrationStepID, artifactID: String, evidence: OrchestrationEvidenceReference)
    case verification(stepID: OrchestrationStepID?, value: VerificationState, evidence: OrchestrationEvidenceReference)
    case acceptance(stepID: OrchestrationStepID?, value: ObjectiveAcceptanceState, evidence: OrchestrationEvidenceReference)
    case terminal(value: OrchestrationRunDisposition, supersededBy: OrchestrationRunID?, evidence: OrchestrationEvidenceReference)
}

/// Retry identity is separate from the immutable recorded event identity.
/// A lost-response retry must repeat this entire command, including its revision.
public struct OrchestrationJournalCommand: Codable, Equatable, Sendable {
    public let id: UUID
    public let runID: OrchestrationRunID
    public let expectedRevision: Int
    public let action: OrchestrationJournalAction
    public init(id: UUID, runID: OrchestrationRunID, expectedRevision: Int, action: OrchestrationJournalAction) {
        self.id = id; self.runID = runID; self.expectedRevision = expectedRevision; self.action = action
    }
}

public struct OrchestrationJournalEvent: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let id: UUID
    public let runID: OrchestrationRunID
    public let sequence: Int
    public let previousDigest: String
    public let recordedAt: Date
    public let command: OrchestrationJournalCommand
    public init(schemaVersion: Int = currentSchemaVersion, id: UUID, runID: OrchestrationRunID,
                sequence: Int, previousDigest: String, recordedAt: Date, command: OrchestrationJournalCommand) {
        self.schemaVersion = schemaVersion; self.id = id; self.runID = runID; self.sequence = sequence
        self.previousDigest = previousDigest; self.recordedAt = recordedAt; self.command = command
    }
}

public struct OrchestrationStepSnapshot: Codable, Equatable, Sendable {
    public let step: OrchestrationStep
    public internal(set) var progress: OrchestrationStepProgress = .pending
    /// Remains true through later UNKNOWN/blocked observations. Replacing a
    /// worker or losing observations must not erase the recorded completion.
    public internal(set) var hasCompletionReport = false
    public internal(set) var worker: OrchestrationWorkerReference?
    public internal(set) var verification: VerificationState = .unknown
    public internal(set) var acceptance: ObjectiveAcceptanceState = .unknown
    public internal(set) var artifacts: [String: OrchestrationEvidenceReference] = [:]
    public var accepted: Bool {
        progress == .completionReported && verification == .passed && acceptance == .accepted
    }
}

/// This projection only replays logical records. It never reconciles, starts,
/// interrupts, approves, resumes or declares a provider currently alive.
public struct OrchestrationRunSnapshot: Codable, Equatable, Sendable {
    public let run: OrchestrationRun
    public internal(set) var revision: Int
    public internal(set) var lastEventID: UUID
    public internal(set) var steps: [OrchestrationStepSnapshot]
    public internal(set) var conditions: [OrchestrationCondition] = []
    public internal(set) var verification: VerificationState = .unknown
    public internal(set) var acceptance: ObjectiveAcceptanceState = .unknown
    public internal(set) var disposition: OrchestrationRunDisposition?
    public internal(set) var supersededBy: OrchestrationRunID?

    static func apply(_ event: OrchestrationJournalEvent, to prior: Self?) throws -> Self {
        guard event.schemaVersion == OrchestrationJournalEvent.currentSchemaVersion,
              event.runID == event.command.runID, event.recordedAt.timeIntervalSince1970.isFinite,
              event.command.expectedRevision == (prior?.revision ?? 0),
              event.sequence == (prior?.revision ?? 0) + 1 else {
            throw OrchestrationJournalError.invalidCommand("Unsupported, mismatched or stale event envelope.")
        }
        if case .create(let run) = event.command.action {
            guard prior == nil, run.id == event.runID else {
                throw OrchestrationJournalError.identityCollision("A run is already recorded or has another identity.")
            }
            try run.validate()
            return Self(run: run, revision: event.sequence, lastEventID: event.id,
                        steps: run.steps.map { OrchestrationStepSnapshot(step: $0) })
        }
        guard var next = prior, next.run.id == event.runID, next.disposition == nil else {
            throw OrchestrationJournalError.invalidCommand("A matching nonterminal run is required.")
        }
        func index(_ id: OrchestrationStepID) throws -> Int {
            guard let i = next.steps.firstIndex(where: { $0.step.id == id }) else {
                throw OrchestrationJournalError.invalidCommand("Unknown step identity.")
            }
            return i
        }
        switch event.command.action {
        case .create: break
        case .condition(let condition):
            try condition.evidence.validate()
            if let id = condition.stepID { _ = try index(id) }
            if let i = next.conditions.firstIndex(where: { $0.kind == condition.kind && $0.stepID == condition.stepID }) {
                next.conditions[i] = condition
            } else { next.conditions.append(condition) }
        case .linkWorker(let id, let worker):
            let i = try index(id); try worker.validate()
            guard next.steps[i].worker == nil else {
                throw OrchestrationJournalError.identityCollision("Release the exact existing worker before replacement.")
            }
            next.steps[i].worker = worker
        case .releaseWorker(let id, let expected):
            let i = try index(id)
            guard next.steps[i].worker == expected else {
                throw OrchestrationJournalError.identityCollision("Worker release does not match all recorded identities.")
            }
            next.steps[i].worker = nil
        case .progress(let id, let value, let evidence):
            let i = try index(id); try evidence.validate()
            let priorProgress = next.steps[i].progress
            if value == .queued || value == .running {
                guard next.steps[i].step.dependencies.allSatisfy({ dependency in
                    next.steps.contains { $0.step.id == dependency && $0.accepted }
                }), !next.steps[i].hasCompletionReport else {
                    throw OrchestrationJournalError.invalidCommand("Dependencies are not accepted or completion would be resurrected.")
                }
            }
            if value == .running || value == .completionReported {
                guard next.steps[i].worker != nil,
                      evidence.supportsProgressObservation,
                      (value != .completionReported || priorProgress == .running) else {
                    throw OrchestrationJournalError.invalidCommand("Progress needs a linked worker and current explicit evidence.")
                }
            }
            guard value != .pending else {
                throw OrchestrationJournalError.invalidCommand("A recorded step cannot be reset to pending.")
            }
            next.steps[i].progress = value
            if value == .completionReported { next.steps[i].hasCompletionReport = true }
        case .artifact(let id, let artifactID, let evidence):
            let i = try index(id); try evidence.validate()
            guard OrchestrationRun.nonblank(artifactID), !next.steps.contains(where: {
                $0.artifacts[artifactID] != nil && ($0.step.id != id || $0.artifacts[artifactID] != evidence)
            }) else { throw OrchestrationJournalError.identityCollision("Conflicting artifact identity.") }
            next.steps[i].artifacts[artifactID] = evidence
        case .verification(let id, let value, let evidence):
            try evidence.validate()
            if value == .passed || value == .failed {
                guard evidence.supportsExternalDecision else {
                    throw OrchestrationJournalError.invalidCommand("Verification requires current explicit evidence.")
                }
            }
            if let id { next.steps[try index(id)].verification = value } else { next.verification = value }
        case .acceptance(let id, let value, let evidence):
            try evidence.validate()
            if value == .accepted || value == .rejected {
                guard evidence.supportsExternalDecision else {
                    throw OrchestrationJournalError.invalidCommand("Acceptance requires current explicit evidence.")
                }
            }
            if let id { next.steps[try index(id)].acceptance = value } else { next.acceptance = value }
        case .terminal(let value, let replacement, let evidence):
            try evidence.validate()
            guard evidence.supportsExternalDecision,
                  (value == .superseded) == (replacement != nil), replacement != next.run.id else {
                throw OrchestrationJournalError.invalidCommand("Terminal receipt or supersession lineage is invalid.")
            }
            if value == .completed {
                guard next.steps.allSatisfy(\.accepted), next.verification == .passed,
                      next.acceptance == .accepted else {
                    throw OrchestrationJournalError.invalidCommand("Completion report is not verification and acceptance.")
                }
            }
            next.disposition = value; next.supersededBy = replacement
        }
        next.revision = event.sequence; next.lastEventID = event.id
        return next
    }
}

public enum OrchestrationJournalError: Error, Equatable, Sendable {
    case missing
    case busy
    case stale(expected: Int, actual: Int)
    case invalidCommand(String)
    case identityCollision(String)
    case corruptHistory(String)
    case invalidCheckpoint(String)
    case unsafeStorage(String)
    case unavailable(Int32)
    case boundExceeded
}

/// Canonical bytes identify content; they are not signatures or authority.
enum OrchestrationJournalCodec {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(value)
    }
    static func decode<T: Codable>(_ type: T.Type, data: Data) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let value = try decoder.decode(type, from: data)
        guard try encode(value) == data else {
            throw OrchestrationJournalError.corruptHistory("Unknown fields or noncanonical record bytes.")
        }
        return value
    }
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
