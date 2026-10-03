import Foundation

/// A reply namespace reserved for metadata observation, never lifecycle effects.
/// Unmatched and expired replies retain this classification without tombstones.
public enum CodexObservationRPC {
    public static let prefix = "conduit.observation.v1/"
    public static let pageLimit = 64
    public static let maximumPages = 4
    public static let maximumPendingRequests = 8
    public static let requestTimeout: TimeInterval = 2
    public static let inventoryTimeout: TimeInterval = 12

    public static func identifier(hostGeneration: UUID, request: UUID = UUID()) -> String {
        prefix + hostGeneration.uuidString.lowercased() + "/" + request.uuidString.lowercased()
    }

    public static func isObservationReply(_ id: CodexJSONRPCID?) -> Bool {
        guard case .string(let value)? = id else { return false }
        return value.hasPrefix(prefix)
    }

    public static func list(id: String, cursor: String?) -> CodexJSON {
        var params: [String: CodexJSON] = [
            "limit": .number(Double(pageLimit)),
            "archived": .bool(false),
            // The ordinary list scans rollouts to repair metadata. Observation
            // must opt out of that write and name all installed source kinds.
            "useStateDbOnly": .bool(true),
            "modelProviders": .array([]),
            "sourceKinds": .array([
                "cli", "vscode", "exec", "appServer", "subAgent",
                "subAgentReview", "subAgentCompact", "subAgentThreadSpawn",
                "subAgentOther", "unknown",
            ].map(CodexJSON.string)),
        ]
        if let cursor { params["cursor"] = .string(cursor) }
        return request(id: id, method: "thread/list", params: params)
    }

    public static func loadedList(id: String, cursor: String?) -> CodexJSON {
        var params: [String: CodexJSON] = ["limit": .number(Double(pageLimit))]
        if let cursor { params["cursor"] = .string(cursor) }
        return request(id: id, method: "thread/loaded/list", params: params)
    }

    public static func read(id: String, threadID: String) -> CodexJSON {
        request(id: id, method: "thread/read", params: [
            "threadId": .string(threadID),
            "includeTurns": .bool(false),
        ])
    }

    private static func request(id: String, method: String, params: [String: CodexJSON]) -> CodexJSON {
        .object(["id": .string(id), "method": .string(method), "params": .object(params)])
    }
}

/// Fixed diagnostics: provider error payloads and rejected metadata are not echoed.
public enum CodexObservationError: Error, Equatable, LocalizedError, Sendable {
    case notReady, hostChanged, tooManyRequests, cancelled, timedOut
    case providerRejected, invalidMetadata, incompleteInventory, unknownSession
    case staleMetadata, ambiguousHost

    public var errorDescription: String? {
        switch self {
        case .notReady: return "Codex metadata observation requires an existing ready Conduit host; no host was started."
        case .hostChanged: return "The exact Codex observation host changed; no observation is returned."
        case .tooManyRequests: return "The bounded Codex metadata request capacity is occupied."
        case .cancelled: return "Codex metadata observation was cancelled."
        case .timedOut: return "Codex metadata observation timed out; driving requests were not cancelled."
        case .providerRejected: return "The Codex host rejected the metadata request; its error payload was withheld."
        case .invalidMetadata: return "Codex metadata had an invalid identity, shape or content boundary; no partial observation is returned."
        case .incompleteInventory: return "Codex metadata pagination exceeded its bound, repeated a cursor or duplicated an identity; no partial inventory is returned."
        case .unknownSession: return "The exact provider session identity is absent from the bounded nonarchived Codex inventory."
        case .staleMetadata: return "Codex thread metadata regressed between inventory and read."
        case .ambiguousHost: return "Codex metadata read requires one ready host; multiple host scopes are available."
        }
    }
}
