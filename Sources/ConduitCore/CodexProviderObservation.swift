import Foundation

/// Allowlisted session metadata. Preview, title, rollout path, turns and nested
/// source payloads never enter this value or the canonical worker projection.
public struct CodexThreadMetadata: Equatable, Sendable {
    public let id: String
    public let sessionFamilyID: String
    public let cwd: String
    public let createdAt: Date
    public let updatedAt: Date
    public let cliVersion: String
    public let modelProvider: String
    public let configuredOrPersistedModel: String?
    public let ephemeral: Bool
    public let sourceKind: String
    public let hostReportedStatus: String

    public static func isExactIdentity(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
            && !value.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.contains($0)
                    || CharacterSet.controlCharacters.contains($0)
            })
    }

    public static func parse(_ json: CodexJSON) throws -> Self {
        guard case .object = json,
              let id = json["id"]?.stringValue, isExactIdentity(id),
              let family = json["sessionId"]?.stringValue, isExactIdentity(family),
              let cwd = json["cwd"]?.stringValue, cwd.hasPrefix("/"),
              validText(cwd, limit: 4_096),
              let created = seconds(json["createdAt"]),
              let updated = seconds(json["updatedAt"]), updated >= created,
              let version = json["cliVersion"]?.stringValue, validText(version, limit: 128),
              let provider = json["modelProvider"]?.stringValue, validText(provider, limit: 256),
              let ephemeral = json["ephemeral"]?.boolValue,
              case .array(let turns)? = json["turns"], turns.isEmpty,
              case .object? = json["status"],
              let status = json["status"]?["type"]?.stringValue,
              ["notLoaded", "idle", "active", "systemError"].contains(status)
        else { throw CodexObservationError.invalidMetadata }

        if status == "active" {
            guard case .array(let flags)? = json["status"]?["activeFlags"],
                  flags.count <= 16,
                  flags.allSatisfy({ flag in
                      guard let text = flag.stringValue else { return false }
                      return validText(text, limit: 128)
                  })
            else { throw CodexObservationError.invalidMetadata }
        }

        let model: String?
        switch json["model"] {
        case nil, .null?: model = nil
        case .string(let value)? where validText(value, limit: 256): model = value
        default: throw CodexObservationError.invalidMetadata
        }
        // Subagent source objects may contain prompts and parent descriptors.
        // Keep only the category; never retain their arbitrary nested payload.
        let source: String
        switch json["source"] {
        case .string(let kind)? where [
            "cli", "vscode", "exec", "appServer", "unknown"
        ].contains(kind): source = kind
        case .object(let object)? where object.count == 1:
            if let custom = object["custom"]?.stringValue, validText(custom, limit: 256) {
                source = "custom"
            } else if let subAgent = object["subAgent"] {
                switch subAgent {
                case .string(let kind) where ["review", "compact", "memory_consolidation"].contains(kind):
                    source = "subAgent"
                case .object(let nested) where nested.count == 1:
                    if case .object? = nested["thread_spawn"] {
                        source = "subAgent"
                    } else if let other = nested["other"]?.stringValue, validText(other, limit: 256) {
                        source = "subAgent"
                    } else { throw CodexObservationError.invalidMetadata }
                default: throw CodexObservationError.invalidMetadata
                }
            } else { throw CodexObservationError.invalidMetadata }
        default: throw CodexObservationError.invalidMetadata
        }
        return Self(
            id: id, sessionFamilyID: family, cwd: cwd,
            createdAt: Date(timeIntervalSince1970: created),
            updatedAt: Date(timeIntervalSince1970: updated),
            cliVersion: version, modelProvider: provider,
            configuredOrPersistedModel: model, ephemeral: ephemeral,
            sourceKind: source, hostReportedStatus: status
        )
    }

    public static func parseRead(_ result: CodexJSON, exactID: String) throws -> Self {
        guard isExactIdentity(exactID), let json = result["thread"] else {
            throw CodexObservationError.invalidMetadata
        }
        let metadata = try parse(json)
        guard metadata.id == exactID else { throw CodexObservationError.invalidMetadata }
        return metadata
    }

    public func worker(
        hostID: String,
        loadedOnHost: Bool,
        binding: ProviderObservationBinding?,
        observedAt: Date
    ) -> WorkerLineage {
        var metadata: [String: ProviderPayloadValue] = [
            "session_family_id": .string(sessionFamilyID),
            "created_at_seconds": .number(createdAt.timeIntervalSince1970),
            "updated_at_seconds": .number(updatedAt.timeIntervalSince1970),
            "cli_version": .string(cliVersion),
            "model_provider": .string(modelProvider),
            "ephemeral": .bool(ephemeral),
            "source_kind": .string(sourceKind),
            "loaded_on_observed_host": .bool(loadedOnHost),
            "host_reported_status": .string(hostReportedStatus),
            "status_scope": .string("Only the exact observed app-server host; not global execution or acceptance."),
            "model_authority": .string("Configured on the loaded session or latest persisted session model; per-turn model and entitlement UNKNOWN."),
            "inventory_scope": .string("Nonarchived state database metadata; no rollout scan or repair."),
            "content_scope": .string("Metadata only; preview, title, rollout path and turns withheld."),
        ]
        if let configuredOrPersistedModel {
            metadata["configured_or_persisted_model"] = .string(configuredOrPersistedModel)
        }
        return WorkerLineage(
            conduitTaskID: binding.map { .known($0.conduitTaskID) } ?? .unknown,
            runtimeAttemptID: binding?.runtimeAttemptID.map { .known($0) } ?? .unknown,
            runtime: .known("codex"), adapter: .known("codex_app_server_metadata"),
            providerHostID: .known(hostID), providerSessionID: .known(id), turns: [],
            workspace: WorkerWorkspaceLineage(
                projectSlug: .unknown, cwd: .known(cwd),
                repositoryRoot: .unknown, worktree: .unknown
            ),
            process: WorkerProcessLineage(
                launcherPID: .unknown, processGroupID: .unknown, parentPID: .unknown
            ),
            origin: .unknown, relationship: .discovered, writerControllerID: .unknown,
            terminal: WorkerTerminalState(
                receipt: .unknown, verification: .unknown, objectiveAcceptance: .unknown
            ),
            observation: SupervisionObservationStamp(
                authority: .providerObserved, freshness: .unknown, observedAt: .known(observedAt)
            ),
            providerSpecific: .known(ProviderSpecificPayload(
                namespace: "codex.app_server.metadata", schemaVersion: 1, value: .object(metadata)
            ))
        )
    }

    private static func validText(_ value: String, limit: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= limit
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func seconds(_ value: CodexJSON?) -> Double? {
        guard case .number(let number)? = value, number.isFinite,
              number.rounded(.towardZero) == number,
              number >= 0, number <= 253_402_300_799
        else { return nil }
        return number
    }
}

/// A bounded complete inventory for one exact host scope, not a global fleet.
public struct CodexMetadataInventory: Equatable, Sendable {
    public let hostID: String
    public let threads: [CodexThreadMetadata]
    public let loadedThreadIDs: Set<String>
    public let observedAt: Date

    public init(hostID: String, threads: [CodexThreadMetadata], loadedThreadIDs: Set<String>, observedAt: Date) {
        self.hostID = hostID
        self.threads = threads
        self.loadedThreadIDs = loadedThreadIDs
        self.observedAt = observedAt
    }
}

/// Accumulates pages without silently accepting duplicates, cycles or truncation.
public struct CodexMetadataPages<Element: Equatable & Sendable>: Sendable {
    public private(set) var elements: [Element] = []
    private var identities = Set<String>()
    private var cursors = Set<String>()
    private var pageCount = 0
    private var finished = false

    public init() {}

    public mutating func append(_ result: CodexJSON, parse: (CodexJSON) throws -> (String, Element)) throws -> String? {
        guard !finished, pageCount < CodexObservationRPC.maximumPages,
              case .array(let data)? = result["data"], data.count <= CodexObservationRPC.pageLimit
        else { throw CodexObservationError.incompleteInventory }
        // Build a temporary page first. A rejected page never changes the accumulator.
        var nextIdentities = identities
        var page: [Element] = []
        for json in data {
            let (id, value) = try parse(json)
            guard CodexThreadMetadata.isExactIdentity(id), nextIdentities.insert(id).inserted else {
                throw CodexObservationError.incompleteInventory
            }
            page.append(value)
        }
        let cursor: String?
        switch result["nextCursor"] {
        case nil, .null?: cursor = nil
        case .string(let value)? where !value.isEmpty && value.utf8.count <= 1_024
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains): cursor = value
        default: throw CodexObservationError.incompleteInventory
        }
        if let cursor {
            guard pageCount + 1 < CodexObservationRPC.maximumPages,
                  !cursors.contains(cursor)
            else { throw CodexObservationError.incompleteInventory }
        }
        elements.append(contentsOf: page)
        identities = nextIdentities
        pageCount += 1
        if let cursor { cursors.insert(cursor) } else { finished = true }
        return cursor
    }
}
