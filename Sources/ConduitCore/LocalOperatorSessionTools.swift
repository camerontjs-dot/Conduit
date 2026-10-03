import Foundation

/// Strict parsing for the additive local-operation verbs. A malformed supplied
/// boundary is refused rather than dropped in favour of generic Shell input.
public enum LocalOperatorToolParser {
    public static func command(named name: String, arguments: [String: CodexJSON]) -> ConduitSessionCommand? {
        guard let task = arguments["taskSessionID"]?.stringValue, let taskUUID = fullUUID(task) else { return nil }
        if name == "conduit_local_preflight" {
            guard let paths = paths(arguments["relative_paths"], allowEmpty: false) else { return nil }
            return .localPreflight(taskSessionID: task, relativePaths: paths)
        }
        guard let operation = arguments["operation_id"]?.stringValue,
              let operationUUID = fullUUID(operation), operationUUID != taskUUID else { return nil }
        switch name {
        case "conduit_local_status", "conduit_local_receipt", "conduit_local_changes", "conduit_local_children":
            guard let section = LocalOperatorReadSection(rawValue: String(name.dropFirst("conduit_local_".count))) else { return nil }
            return .localRead(taskSessionID: task, operationID: operation, section: section)
        case "conduit_local_begin":
            guard let objective = arguments["objective"]?.stringValue,
                  let acceptance = arguments["acceptance_condition"]?.stringValue,
                  !objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, objective.utf8.count <= 2_048,
                  !acceptance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, acceptance.utf8.count <= 2_048,
                  let rawMode = arguments["mode"]?.stringValue, let mode = LocalOperatorAuthorityMode(rawValue: rawMode),
                  let selected = paths(arguments["relative_paths"], allowEmpty: false),
                  let protected = arguments["protected_relative_paths"] == nil ? [] : paths(arguments["protected_relative_paths"], allowEmpty: true),
                  Set(selected + protected).count <= 64 else { return nil }
            return .localBegin(taskSessionID: task, operationID: operation, objective: objective,
                acceptanceCondition: acceptance, mode: mode, relativePaths: selected, protectedRelativePaths: protected)
        case "conduit_local_checkpoint":
            guard case .number(let revision) = arguments["expected_revision"], revision.isFinite,
                  revision.rounded(.towardZero) == revision, revision >= 0,
                  revision < Double(LocalOperatorRecordStore.maximumRevisions),
                  arguments["terminal"] == nil || arguments["terminal"]?.boolValue != nil else { return nil }
            return .localCheckpoint(taskSessionID: task, operationID: operation,
                expectedRevision: Int(revision), terminal: arguments["terminal"]?.boolValue ?? false)
        default: return nil
        }
    }

    public static func isValidOptionalOperationID(_ value: CodexJSON?) -> Bool {
        guard let value else { return true }
        guard let raw = value.stringValue else { return false }
        return fullUUID(raw) != nil
    }

    public static func fullUUID(_ raw: String) -> UUID? {
        guard raw.utf8.count == 36, let uuid = UUID(uuidString: raw),
              uuid.uuidString.lowercased() == raw.lowercased() else { return nil }
        return uuid
    }

    private static func paths(_ value: CodexJSON?, allowEmpty: Bool) -> [String]? {
        guard case .array(let values) = value, values.count <= 64, allowEmpty || !values.isEmpty else { return nil }
        let paths = values.compactMap(\.stringValue)
        guard paths.count == values.count, Set(paths).count == paths.count,
              paths.allSatisfy(LocalOperatorBoundary.validRelativePath) else { return nil }
        return paths.sorted()
    }
}

/// Reads the already-established #70 Fleet correlation, without resolving or
/// promoting it again. One bounded page is not an exhaustive child inventory.
public enum LocalOperatorFleetLinkReader {
    public static func read(_ data: Data, taskSessionID: TaskSessionID,
                            runtimeAttemptID: RuntimeAttemptID) throws -> [ShellProviderCorrelation] {
        guard data.count <= 2_097_152,
              let fleet = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let page = fleet["provider_sessions"] as? [String: Any],
              let rows = page["items"] as? [[String: Any]], rows.count <= 200 else {
            throw LocalOperatorError.invalidRecord
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Foundation's generic conversion produces taskSessionId/processPid.
        // Preserve the canonical ID/PID spellings of the maintained types.
        decoder.keyDecodingStrategy = .custom { path in
            let raw = path.last!.stringValue
            return FleetKey(stringValue: snakeKeys[raw] ?? raw)!
        }
        var links: [ShellProviderCorrelation] = []
        for row in rows {
            guard let value = row["shell_correlation"], !(value is NSNull) else { continue }
            let correlation = try decoder.decode(ShellProviderCorrelation.self,
                from: JSONSerialization.data(withJSONObject: value))
            guard correlation.taskSessionID.value == taskSessionID.rawValue.uuidString,
                  correlation.runtimeAttemptID.value == runtimeAttemptID.rawValue.uuidString else { continue }
            links.append(correlation)
        }
        return links
    }

    private static let snakeKeys = [
        "task_session_id": "taskSessionID", "runtime_attempt_id": "runtimeAttemptID",
        "shell_execution_id": "shellExecutionID", "command_id": "commandID",
        "process_pid": "processPID", "provider_session_id": "providerSessionID",
        "candidate_session_i_ds": "candidateSessionIDs", "candidate_session_ids": "candidateSessionIDs",
        "process_observation": "processObservation", "provider_observation": "providerObservation",
        "observed_at": "observedAt",
    ]

    private struct FleetKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}
