import Foundation

/// Exact Conduit binding known for a provider session.
///
/// This does not grant writer/controller authority. It only records a binding
/// that another Conduit authority can prove by exact provider-session identity.
public struct ProviderObservationBinding: Equatable, Sendable {
    public var conduitTaskID: String
    public var runtimeAttemptID: String?

    public init(conduitTaskID: String, runtimeAttemptID: String? = nil) {
        self.conduitTaskID = conduitTaskID
        self.runtimeAttemptID = runtimeAttemptID
    }
}

/// Read-only provider inventory/observation boundary.
///
/// Implementations may enumerate and read provider-native state. Adoption,
/// prompt delivery, resume, interrupt, writer leasing, and lifecycle mutation
/// deliberately do not exist on this interface.
public protocol ProviderSessionObserving {
    var providerID: String { get }

    func listSessions(
        bindingResolver: ((String) -> ProviderObservationBinding?)?
    ) throws -> [WorkerLineage]

    func observeSession(
        providerSessionID: String,
        binding: ProviderObservationBinding?
    ) throws -> WorkerLineage
}

/// Minimal provider-specific transport used by the OpenCode observer.
///
/// The protocol has only reads. Keeping mutation verbs out of this transport is
/// intentional: a discovery implementation cannot accidentally send a prompt,
/// resume a turn, abort a session, or acquire a writer lease through it.
public protocol OpenCodeProviderObservationTransport {
    func listSessionsJSON() throws -> CodexJSON
    func readSessionJSON(providerSessionID: String) throws -> CodexJSON
}

public enum ProviderSessionObservationError: Error, Equatable, LocalizedError {
    case invalidProviderSessionID(String)
    case malformedProviderResponse(String)
    case identityMismatch(expected: String, observed: String)

    public var errorDescription: String? {
        switch self {
        case .invalidProviderSessionID(let value):
            return "Invalid provider session id: \(value)"
        case .malformedProviderResponse(let reason):
            return "Malformed provider observation: \(reason)"
        case .identityMismatch(let expected, let observed):
            return "Provider session identity mismatch: expected \(expected), observed \(observed)"
        }
    }
}

/// Read-only OpenCode persistence observer.
///
/// OpenCode session-list/export are provider persistence surfaces. They are
/// useful for exact session identity, workspace metadata, and persisted message
/// lineage, but they are not OS/process authority. In particular, an
/// incomplete persisted message is represented as AMBIGUOUS, never promoted to
/// ACTIVE merely because OpenCode still stores it without a completion time.
public final class OpenCodeProviderSessionObserver: ProviderSessionObserving {
    public let providerID = "opencode"

    private let transport: any OpenCodeProviderObservationTransport
    private let now: () -> Date

    public init(
        transport: any OpenCodeProviderObservationTransport,
        now: @escaping () -> Date = Date.init
    ) {
        self.transport = transport
        self.now = now
    }

    public func listSessions(
        bindingResolver: ((String) -> ProviderObservationBinding?)? = nil
    ) throws -> [WorkerLineage] {
        let root = try transport.listSessionsJSON()
        guard case .array(let rows) = root else {
            throw ProviderSessionObservationError.malformedProviderResponse(
                "OpenCode session list was not a JSON array"
            )
        }

        let observedAt = now()
        return try rows.map { row in
            guard let sessionID = row["id"]?.stringValue, !sessionID.isEmpty else {
                throw ProviderSessionObservationError.malformedProviderResponse(
                    "OpenCode session list contained a row without an id"
                )
            }
            return try Self.lineage(
                session: row,
                messages: [],
                source: "session_list",
                observedAt: observedAt,
                binding: bindingResolver?(sessionID)
            )
        }
    }

    public func observeSession(
        providerSessionID: String,
        binding: ProviderObservationBinding? = nil
    ) throws -> WorkerLineage {
        guard Self.validProviderSessionID(providerSessionID) else {
            throw ProviderSessionObservationError.invalidProviderSessionID(
                providerSessionID
            )
        }

        let root = try transport.readSessionJSON(
            providerSessionID: providerSessionID
        )
        guard let info = root["info"] else {
            throw ProviderSessionObservationError.malformedProviderResponse(
                "OpenCode export did not contain info"
            )
        }
        guard let observedID = info["id"]?.stringValue, !observedID.isEmpty else {
            throw ProviderSessionObservationError.malformedProviderResponse(
                "OpenCode export info did not contain an id"
            )
        }
        guard observedID == providerSessionID else {
            throw ProviderSessionObservationError.identityMismatch(
                expected: providerSessionID,
                observed: observedID
            )
        }

        let messages: [CodexJSON]
        if let raw = root["messages"] {
            guard case .array(let rows) = raw else {
                throw ProviderSessionObservationError.malformedProviderResponse(
                    "OpenCode export messages was not a JSON array"
                )
            }
            messages = rows
        } else {
            messages = []
        }

        return try Self.lineage(
            session: info,
            messages: messages,
            source: "session_export",
            observedAt: now(),
            binding: binding
        )
    }

    private static func lineage(
        session: CodexJSON,
        messages: [CodexJSON],
        source: String,
        observedAt: Date,
        binding: ProviderObservationBinding?
    ) throws -> WorkerLineage {
        guard let sessionID = session["id"]?.stringValue, !sessionID.isEmpty else {
            throw ProviderSessionObservationError.malformedProviderResponse(
                "OpenCode session metadata did not contain an id"
            )
        }

        let observation = SupervisionObservationStamp(
            authority: .providerObserved,
            // Persistence was read now, but its relationship to live worker
            // state is unknown without an independent process observation.
            freshness: .unknown,
            observedAt: .known(observedAt)
        )

        let turns = messages.compactMap { message -> ProviderTurnLineage? in
            guard let info = message["info"],
                  info["role"]?.stringValue == "assistant"
            else {
                return nil
            }

            let model: OrchestrationValue<ProviderModelIdentity>
            if let providerID = info["providerID"]?.stringValue,
               let modelID = info["modelID"]?.stringValue,
               !providerID.isEmpty,
               !modelID.isEmpty {
                model = .known(
                    ProviderModelIdentity(
                        providerID: providerID,
                        modelID: modelID
                    )
                )
            } else {
                model = .unknown
            }

            let state: ProviderTurnState
            if hasNonNullValue(info["error"]) {
                state = .failed
            } else if info["time"]?["completed"] != nil {
                state = .completed
            } else {
                // Persisted absence of completion is not proof of a live turn.
                state = .ambiguous
            }

            let turnID: OrchestrationValue<String>
            if let id = info["id"]?.stringValue, !id.isEmpty {
                turnID = .known(id)
            } else {
                turnID = .unknown
            }

            return ProviderTurnLineage(
                turnID: turnID,
                state: state,
                model: model,
                observation: observation
            )
        }

        let directory = session["directory"]?.stringValue
        let workspace = WorkerWorkspaceLineage(
            projectSlug: .unknown,
            cwd: nonempty(directory).map(OrchestrationValue.known) ?? .unknown,
            repositoryRoot: .unknown,
            worktree: .unknown
        )

        let providerSpecific = ProviderSpecificPayload(
            namespace: "opencode.persistence",
            schemaVersion: 1,
            value: .object([
                "source": .string(source),
                "session": providerMetadata(from: session),
                "message_count": .number(Double(messages.count)),
                "assistant_turn_count": .number(Double(turns.count)),
            ])
        )

        return WorkerLineage(
            conduitTaskID: binding.map {
                .known($0.conduitTaskID)
            } ?? .unknown,
            runtimeAttemptID: binding?.runtimeAttemptID.map {
                .known($0)
            } ?? .unknown,
            runtime: .known("opencode"),
            adapter: .known("opencode_cli_persistence"),
            providerHostID: .unknown,
            providerSessionID: .known(sessionID),
            turns: turns,
            workspace: workspace,
            process: WorkerProcessLineage(
                launcherPID: .unknown,
                processGroupID: .unknown,
                parentPID: .unknown
            ),
            // Persisted session metadata does not establish who created it.
            origin: .unknown,
            // This API is discovery even if an exact task binding is also found.
            relationship: .discovered,
            // Task binding is not writer/controller authority.
            writerControllerID: .unknown,
            // Provider message completion is deliberately not upgraded into a
            // terminal receipt, verification, or objective acceptance.
            terminal: WorkerTerminalState(
                receipt: .unknown,
                verification: .unknown,
                objectiveAcceptance: .unknown
            ),
            observation: observation,
            providerSpecific: .known(providerSpecific)
        )
    }

    private static func providerMetadata(from session: CodexJSON) -> ProviderPayloadValue {
        var object: [String: ProviderPayloadValue] = [:]
        for key in [
            "id", "title", "projectID", "projectId", "directory",
            "parentID", "parentId", "time",
        ] {
            guard let value = session[key] else { continue }
            object[key] = payloadValue(value)
        }
        return .object(object)
    }

    private static func payloadValue(_ json: CodexJSON) -> ProviderPayloadValue {
        switch json {
        case .null:
            return .null
        case .bool(let value):
            return .bool(value)
        case .number(let value):
            return .number(value)
        case .string(let value):
            return .string(value)
        case .array(let values):
            return .array(values.map(payloadValue))
        case .object(let object):
            return .object(object.mapValues(payloadValue))
        }
    }

    private static func hasNonNullValue(_ json: CodexJSON?) -> Bool {
        guard let json else { return false }
        if case .null = json { return false }
        return true
    }

    private static func validProviderSessionID(_ value: String) -> Bool {
        guard value.hasPrefix("ses_"), value.count > 4 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || scalar == "_"
                || scalar == "-"
        }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
