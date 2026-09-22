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

/// Deterministic provider-neutral reconciliation. The caller must supply an
/// exact Conduit binding before process evidence can be paired with provider
/// persistence. No operation here mutates provider history or process state.
public enum ProviderRuntimeReconciler {
    public static func reconcile(
        providerID: String,
        providerSessionID: String,
        binding: ProviderObservationBinding?,
        latestProviderTurnID: OrchestrationValue<String>,
        providerReportedState: ProviderReportedRuntimeState,
        providerActivities: OrchestrationValue<[ProviderPersistedActivity]>,
        providerSourceUpdatedAt: OrchestrationValue<Date>,
        providerObservation: SupervisionObservationStamp,
        processObservation: ProcessTreeObservation? = nil,
        processReconciliation: ProcessTreeReconciliation? = nil,
        diagnostics initialDiagnostics: [String] = []
    ) -> ProviderRuntimeReconciliation {
        var diagnostics = initialDiagnostics
        var unknownFacts: [String] = ["objective_acceptance"]
        if providerObservation.freshness == .unknown {
            unknownFacts.append("provider_persistence_freshness_vs_live_runtime")
        }
        if !latestProviderTurnID.isKnown {
            unknownFacts.append("provider_turn_identity")
        }
        if !providerActivities.isKnown {
            unknownFacts.append("persisted_tool_part_state")
        }
        if let processObservation,
           !processObservation.providerTurnID.isKnown {
            unknownFacts.append("provider_turn_to_process_identity_correlation")
        } else if processObservation == nil {
            unknownFacts.append("provider_turn_to_process_identity_correlation")
        }

        let processValue = processObservation.map(OrchestrationValue.known)
            ?? .unknown
        let processReconciliationValue = processReconciliation.map(
            OrchestrationValue.known
        ) ?? .unknown
        let taskID = binding.map { OrchestrationValue<String>.known($0.conduitTaskID) }
            ?? .unknown
        let attemptID = binding?.runtimeAttemptID.map(OrchestrationValue.known)
            ?? .unknown

        var disposition: ProviderRuntimeReconciliationDisposition =
            .insufficientObservation

        guard providerObservation.authority == .providerObserved,
              providerObservation.observedAt.isKnown,
              let binding
        else {
            diagnostics.append(
                "Provider state or exact Conduit session binding is unavailable; no cross-authority consistency is inferred."
            )
            if binding == nil { unknownFacts.append("exact_conduit_binding") }
            return ProviderRuntimeReconciliation(
                providerID: providerID,
                providerSessionID: .known(providerSessionID),
                conduitTaskID: taskID,
                runtimeAttemptID: attemptID,
                latestProviderTurnID: latestProviderTurnID,
                providerReportedState: providerReportedState,
                providerActivities: providerActivities,
                providerSourceUpdatedAt: providerSourceUpdatedAt,
                providerObservation: providerObservation,
                processObservation: processValue,
                processReconciliation: processReconciliationValue,
                disposition: disposition,
                diagnostics: diagnostics,
                unknownFacts: Array(Set(unknownFacts)).sorted()
            )
        }

        guard let processObservation else {
            diagnostics.append(
                "No exact task-bound process observation is available."
            )
            unknownFacts.append("process_liveness_and_residuals")
            return ProviderRuntimeReconciliation(
                providerID: providerID,
                providerSessionID: .known(providerSessionID),
                conduitTaskID: taskID,
                runtimeAttemptID: attemptID,
                latestProviderTurnID: latestProviderTurnID,
                providerReportedState: providerReportedState,
                providerActivities: providerActivities,
                providerSourceUpdatedAt: providerSourceUpdatedAt,
                providerObservation: providerObservation,
                processObservation: processValue,
                processReconciliation: processReconciliationValue,
                disposition: disposition,
                diagnostics: diagnostics,
                unknownFacts: Array(Set(unknownFacts)).sorted()
            )
        }

        guard processObservation.taskSessionID == binding.conduitTaskID,
              attemptMatches(binding.runtimeAttemptID, processObservation.runtimeAttemptID)
        else {
            disposition = .inconsistentAuthorities
            diagnostics.append(
                "Process observation identity does not match the exact Conduit task/runtime-attempt binding."
            )
            unknownFacts.append("process_binding_identity")
            return ProviderRuntimeReconciliation(
                providerID: providerID,
                providerSessionID: .known(providerSessionID),
                conduitTaskID: taskID,
                runtimeAttemptID: attemptID,
                latestProviderTurnID: latestProviderTurnID,
                providerReportedState: providerReportedState,
                providerActivities: providerActivities,
                providerSourceUpdatedAt: providerSourceUpdatedAt,
                providerObservation: providerObservation,
                processObservation: processValue,
                processReconciliation: processReconciliationValue,
                disposition: disposition,
                diagnostics: diagnostics,
                unknownFacts: Array(Set(unknownFacts)).sorted()
            )
        }

        if processObservation.observation.freshness != .current {
            unknownFacts.append("current_process_liveness")
        } else if processObservation.coverage == .unavailable
                    || processObservation.coverage == .ambiguous {
            unknownFacts.append("process_liveness_and_residuals")
        } else {
            let processDisposition = processReconciliation?.disposition
            let launcherIsLive = processObservation.launcher.value?.liveness == .live

            switch providerReportedState {
            case .active:
                if launcherIsLive {
                    disposition = .consistentActive
                    diagnostics.append(
                        "Provider reports active persisted work and the exact bound runtime launcher is live; tool-part to individual process correlation remains separate."
                    )
                } else if processDisposition == .parentExitedOwnedResidual {
                    disposition = .providerActiveParentAbsentOwnedResidual
                    diagnostics.append(
                        "Provider persistence reports active work, the bound parent is absent, and Slice 6A retains a live task-created residual. No cleanup was attempted."
                    )
                } else if processDisposition == .parentExitedNoOwnedResidual {
                    disposition = .providerStaleRunningProcessAbsent
                    diagnostics.append(
                        "Provider persistence reports active work, but the bound parent exited and complete Slice 6A observation found no live owned residual. Provider history is preserved."
                    )
                } else {
                    diagnostics.append(
                        "Provider reports active persisted work, but process evidence does not establish a live launcher or a complete absent/residual postcondition."
                    )
                    unknownFacts.append("process_liveness_and_residuals")
                }
            case .inactive:
                if processDisposition == .parentExitedNoOwnedResidual {
                    disposition = .consistentInactive
                    diagnostics.append(
                        "Provider reports the latest turn inactive and complete Slice 6A observation found no live owned process. Objective acceptance remains independent."
                    )
                } else if processDisposition == .parentExitedOwnedResidual {
                    disposition = .providerInactiveProcessResidual
                    diagnostics.append(
                        "Provider reports the latest turn inactive while Slice 6A still observes a live task-created residual. No cleanup was attempted."
                    )
                } else {
                    diagnostics.append(
                        "Provider reports the latest turn inactive, but process evidence does not establish an absent runtime and residual set. A live provider host alone may be idle."
                    )
                    unknownFacts.append("process_liveness_and_residuals")
                }
            case .unknown:
                diagnostics.append(
                    "Provider persistence does not establish active or inactive state for the latest turn."
                )
                unknownFacts.append("latest_provider_runtime_state")
            }
        }

        if let processReconciliation,
           (processReconciliation.taskSessionID != binding.conduitTaskID
                || processReconciliation.runtimeAttemptID.value
                    != processObservation.runtimeAttemptID.value
                || processReconciliation.after.taskSessionID
                    != processObservation.taskSessionID
                || processReconciliation.after.runtimeAttemptID.value
                    != processObservation.runtimeAttemptID.value) {
            disposition = .inconsistentAuthorities
            diagnostics.append(
                "Slice 6A reconciliation identity does not match the process observation and exact Conduit runtime binding."
            )
            unknownFacts.append("process_reconciliation_identity")
        }

        diagnostics.append(
            "Provider persistence and OS process state are independent observations; reconciliation performs no provider-history rewrite or process cleanup."
        )

        return ProviderRuntimeReconciliation(
            providerID: providerID,
            providerSessionID: .known(providerSessionID),
            conduitTaskID: taskID,
            runtimeAttemptID: attemptID,
            latestProviderTurnID: latestProviderTurnID,
            providerReportedState: providerReportedState,
            providerActivities: providerActivities,
            providerSourceUpdatedAt: providerSourceUpdatedAt,
            providerObservation: providerObservation,
            processObservation: processValue,
            processReconciliation: processReconciliationValue,
            disposition: disposition,
            diagnostics: diagnostics,
            unknownFacts: Array(Set(unknownFacts)).sorted()
        )
    }

    private static func attemptMatches(
        _ boundAttemptID: String?,
        _ observedAttemptID: OrchestrationValue<String>
    ) -> Bool {
        guard let boundAttemptID else {
            return !observedAttemptID.isKnown
        }
        return observedAttemptID.value == boundAttemptID
    }
}

/// Read-only OpenCode persistence observer.
///
/// OpenCode persistence snapshots are provider-observation surfaces. They are
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
                "OpenCode persistence inventory was not a JSON array"
            )
        }

        let observedAt = now()
        return try rows.map { row in
            guard let sessionID = row["id"]?.stringValue, !sessionID.isEmpty else {
                throw ProviderSessionObservationError.malformedProviderResponse(
                    "OpenCode persistence inventory contained a row without an id"
                )
            }
            return try Self.lineage(
                session: row,
                messages: [],
                activities: .unknown,
                source: "persistence_inventory",
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
                "OpenCode persistence snapshot did not contain session metadata"
            )
        }
        guard let observedID = info["id"]?.stringValue, !observedID.isEmpty else {
            throw ProviderSessionObservationError.malformedProviderResponse(
                "OpenCode persistence snapshot session metadata did not contain an id"
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
                    "OpenCode persistence snapshot messages were not a JSON array"
                )
            }
            messages = rows
        } else {
            messages = []
        }

        let activities: OrchestrationValue<[ProviderPersistedActivity]>
        if case .array(let rows)? = root["parts"] {
            activities = .known(rows.compactMap(Self.activity))
        } else {
            // Missing/null parts means this transport/schema did not establish
            // that the complete tool-part table was observed.
            activities = .unknown
        }

        return try Self.lineage(
            session: info,
            messages: messages,
            activities: activities,
            source: "persistence_snapshot",
            observedAt: now(),
            binding: binding
        )
    }

    private static func lineage(
        session: CodexJSON,
        messages: [CodexJSON],
        activities: OrchestrationValue<[ProviderPersistedActivity]>,
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
            // SQLite persistence rows are already projected to message-info
            // fields. Retain compatibility with the older export-shaped
            // fixture wrapper while treating the flat persistence shape as
            // canonical for this observation path.
            let info = message["info"] ?? message
            guard info["role"]?.stringValue == "assistant" else {
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
            } else if hasNonNullValue(info["time"]?["completed"]) {
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

        let latestMessage = messages.reversed().first {
            ($0["info"] ?? $0)["role"]?.stringValue == "assistant"
        }
        let latestInfo = latestMessage.map { $0["info"] ?? $0 }
        let latestTurnID = latestInfo?["id"]?.stringValue
            .map(OrchestrationValue.known) ?? .unknown
        var activityDiagnostics: [String] = []
        let providerReportedState = Self.providerReportedState(
            latestMessage: latestMessage,
            activities: activities,
            diagnostics: &activityDiagnostics
        )
        let providerSourceUpdatedAt = Self.dateValue(
            session["time"]?["updated"] ?? session["updated"]
        ).map(OrchestrationValue.known) ?? .unknown

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
            adapter: .known("opencode_sqlite_snapshot"),
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
            providerSpecific: .known(providerSpecific),
            runtimeReconciliation: ProviderRuntimeReconciler.reconcile(
                providerID: "opencode",
                providerSessionID: sessionID,
                binding: binding,
                latestProviderTurnID: latestTurnID,
                providerReportedState: providerReportedState,
                providerActivities: activities,
                providerSourceUpdatedAt: providerSourceUpdatedAt,
                providerObservation: observation,
                diagnostics: activityDiagnostics
            )
        )
    }

    private static func providerReportedState(
        latestMessage: CodexJSON?,
        activities: OrchestrationValue<[ProviderPersistedActivity]>,
        diagnostics: inout [String]
    ) -> ProviderReportedRuntimeState {
        guard let latestMessage else { return .unknown }
        let info = latestMessage["info"] ?? latestMessage
        let messageID = info["id"]?.stringValue
        if hasNonNullValue(info["error"])
            || hasNonNullValue(info["time"]?["completed"]) {
            if let rows = activities.value {
                if rows.contains(where: {
                    $0.reportedStatus.value?.lowercased() == "running"
                        && $0.messageID.value == messageID
                }) {
                    diagnostics.append(
                        "Latest assistant message is complete while one of its persisted tool parts still says running."
                    )
                    return .unknown
                }
                if rows.contains(where: {
                    $0.reportedStatus.value?.lowercased() == "running"
                        && $0.messageID.value != messageID
                }) {
                    diagnostics.append(
                        "An older persisted tool part still says running; it is retained as historical evidence and is not promoted to the latest session state."
                    )
                }
            }
            return .inactive
        }

        guard let messageID,
              let rows = activities.value
        else {
            diagnostics.append(
                "Latest assistant message is incomplete, but persisted tool-part status is unavailable or cannot be tied to that message."
            )
            return .unknown
        }
        if rows.contains(where: {
            $0.messageID.value == messageID
                && $0.reportedStatus.value?.lowercased() == "running"
        }) {
            if rows.contains(where: {
                $0.messageID.value != messageID
                    && $0.reportedStatus.value?.lowercased() == "running"
            }) {
                diagnostics.append(
                    "An older persisted tool part still says running; it is retained as historical evidence and is not promoted to the latest session state."
                )
            }
            return .active
        }
        diagnostics.append(
            "Latest assistant message is incomplete without a persisted running tool part; persistence alone does not establish whether it is live."
        )
        return .unknown
    }

    private static func activity(_ row: CodexJSON) -> ProviderPersistedActivity? {
        // The allowlist intentionally excludes state.input/output and any
        // command or tool arguments from provider persistence.
        guard row["kind"]?.stringValue == "tool" else { return nil }
        return ProviderPersistedActivity(
            partID: row["id"]?.stringValue.map(OrchestrationValue.known) ?? .unknown,
            messageID: row["messageID"]?.stringValue.map(OrchestrationValue.known) ?? .unknown,
            callID: row["callID"]?.stringValue.map(OrchestrationValue.known) ?? .unknown,
            kind: row["kind"]?.stringValue.map(OrchestrationValue.known) ?? .unknown,
            toolName: row["tool"]?.stringValue.map(OrchestrationValue.known) ?? .unknown,
            reportedStatus: row["status"]?.stringValue.map(OrchestrationValue.known) ?? .unknown,
            createdAt: dateValue(row["createdAt"]).map(OrchestrationValue.known) ?? .unknown,
            updatedAt: dateValue(row["updatedAt"]).map(OrchestrationValue.known) ?? .unknown
        )
    }

    private static func dateValue(_ value: CodexJSON?) -> Date? {
        guard case .number(let number)? = value, number > 0 else { return nil }
        // OpenCode SQLite timestamps are Unix milliseconds.
        return Date(timeIntervalSince1970: number / 1_000)
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
