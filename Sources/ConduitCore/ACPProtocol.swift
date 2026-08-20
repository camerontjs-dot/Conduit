import Foundation

/// Agent Client Protocol request builders and a Conversation mapper.
///
/// Probe (Grok 1.0.5): newline-delimited JSON-RPC, `protocolVersion: 1`,
/// `session/new` + `session/prompt` with `stopReason: end_turn` as the
/// authoritative turn barrier. `session/load` resumes after process death.
public enum ACPRequests {
    public static func initialize(id: Int) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "method": "initialize",
            "params": [
                "protocolVersion": 1,
                "clientInfo": [
                    "name": "conduit",
                    "title": "Conduit",
                    "version": "1.0",
                ],
                "clientCapabilities": [
                    "fs": [
                        "readTextFile": false,
                        "writeTextFile": false,
                    ],
                    "terminal": false,
                ],
            ],
        ]
    }

    public static func authenticate(id: Int, methodID: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "method": "authenticate",
            "params": ["methodId": methodID],
        ]
    }

    public static func initialized() -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "method": "initialized",
            "params": [String: Any](),
        ]
    }

    public static func sessionNew(id: Int, cwd: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "method": "session/new",
            "params": [
                "cwd": cwd,
                "mcpServers": [Any](),
            ],
        ]
    }

    public static func sessionLoad(id: Int, sessionID: String, cwd: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "method": "session/load",
            "params": [
                "sessionId": sessionID,
                "cwd": cwd,
                "mcpServers": [Any](),
            ],
        ]
    }

    public static func sessionPrompt(id: Int, sessionID: String, text: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "method": "session/prompt",
            "params": [
                "sessionId": sessionID,
                "prompt": [
                    ["type": "text", "text": text],
                ],
            ],
        ]
    }

    public static func sessionCancel(sessionID: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "method": "session/cancel",
            "params": ["sessionId": sessionID],
        ]
    }

    public static func permissionAllow(id: CodexJSONRPCID, optionID: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id.jsonObject,
            "result": [
                "outcome": [
                    "outcome": "selected",
                    "optionId": optionID,
                ]
            ],
        ]
    }

    public static func permissionDeny(id: CodexJSONRPCID) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id.jsonObject,
            "result": [
                "outcome": [
                    "outcome": "cancelled",
                ]
            ],
        ]
    }
}

public struct ACPPendingPermission: Equatable, Sendable {
    public var id: String
    public var rpcID: CodexJSONRPCID
    public var summary: String
    public var allowOptionID: String

    public init(
        id: String,
        rpcID: CodexJSONRPCID,
        summary: String,
        allowOptionID: String
    ) {
        self.id = id
        self.rpcID = rpcID
        self.summary = summary
        self.allowOptionID = allowOptionID
    }
}

/// Accumulates ACP notifications into Conversation-shaped effects.
public struct ACPSessionMapper: Equatable, Sendable {
    public var sessionID: String?
    public var accumulatedText = ""
    public var turnActive = false
    public var lastTurnStatus: String?

    public init() {}

    public mutating func apply(_ message: CodexJSONRPCMessage) -> [StructuredAdapterEffect] {
        switch message {
        case .error(_, let message):
            return [.failed(message)]
        case .response(_, let result):
            return applyResponse(result)
        case .notification(let method, let params):
            return applyUpdate(method: method, params: params)
        case .request(_, let method, let params):
            if method == "session/request_permission" || method.hasSuffix("/request_permission") {
                let summary = Self.permissionSummary(params)
                let requestID = "acp-\(summary.prefix(24))"
                return [
                    .requestApproval(id: requestID, summary: summary)
                ]
            }
            return []
        }
    }

    public mutating func resetTurn() {
        accumulatedText = ""
        turnActive = false
        lastTurnStatus = nil
    }

    public static func sessionID(in json: CodexJSON) -> String? {
        json["sessionId"]?.stringValue
            ?? json["_meta"]?["sessionId"]?.stringValue
            ?? json["session"]?["sessionId"]?.stringValue
            ?? json["session"]?["id"]?.stringValue
    }

    public static func permissionSummary(_ params: CodexJSON) -> String {
        if let title = params["title"]?.stringValue { return title }
        if let tool = params["toolCall"]?["title"]?.stringValue { return tool }
        if let name = params["toolCall"]?["kind"]?.stringValue { return name }
        if let reason = params["reason"]?.stringValue { return reason }
        return "session/request_permission"
    }

    public static func allowOptionID(_ params: CodexJSON) -> String {
        if case .array(let options) = params["options"] {
            for option in options {
                let kind = option["kind"]?.stringValue ?? ""
                let optionID = option["optionId"]?.stringValue ?? option["id"]?.stringValue
                if let optionID, kind != "reject" && !optionID.lowercased().contains("reject") {
                    return optionID
                }
            }
            if let first = options.first?["optionId"]?.stringValue
                ?? options.first?["id"]?.stringValue {
                return first
            }
        }
        return "allow-once"
    }

    public static func pendingPermission(
        rpcID: CodexJSONRPCID,
        params: CodexJSON
    ) -> ACPPendingPermission {
        let summary = permissionSummary(params)
        return ACPPendingPermission(
            id: "acp-\(summary.prefix(24))",
            rpcID: rpcID,
            summary: summary,
            allowOptionID: allowOptionID(params)
        )
    }

    private mutating func applyResponse(_ result: CodexJSON) -> [StructuredAdapterEffect] {
        var effects: [StructuredAdapterEffect] = []
        if let sessionID = Self.sessionID(in: result) {
            self.sessionID = sessionID
            effects.append(.sessionStarted(id: sessionID))
        }
        if let stop = result["stopReason"]?.stringValue {
            turnActive = false
            lastTurnStatus = stop
            if !accumulatedText.isEmpty {
                effects.append(.upsertOutput(text: accumulatedText, state: .closed))
            }
            effects.append(.turnCompleted(status: stop))
        }
        return effects
    }

    private mutating func applyUpdate(
        method: String,
        params: CodexJSON
    ) -> [StructuredAdapterEffect] {
        if method == "session/update" || method.hasSuffix("/session/update") {
            return applySessionUpdate(params)
        }
        return []
    }

    private mutating func applySessionUpdate(_ params: CodexJSON) -> [StructuredAdapterEffect] {
        let update = params["update"] ?? params
        let kind = update["sessionUpdate"]?.stringValue
            ?? update["kind"]?.stringValue
            ?? params["type"]?.stringValue
            ?? ""
        if kind == "agent_message_chunk" || kind == "agent_message" || kind == "message" {
            let delta = Self.text(in: update) ?? Self.text(in: params) ?? ""
            guard !delta.isEmpty else { return [] }
            accumulatedText += delta
            turnActive = true
            return [.upsertOutput(text: accumulatedText, state: .live)]
        }
        if kind == "turn_completed" || kind == "available_commands_update" {
            if kind == "turn_completed" {
                turnActive = false
                lastTurnStatus = lastTurnStatus ?? "end_turn"
            }
            return []
        }
        if let delta = Self.text(in: update),
           kind.contains("agent") || kind.contains("message") {
            guard !delta.isEmpty else { return [] }
            accumulatedText += delta
            turnActive = true
            return [.upsertOutput(text: accumulatedText, state: .live)]
        }
        return []
    }

    private static func text(in json: CodexJSON) -> String? {
        if let text = json["content"]?["text"]?.stringValue { return text }
        if let text = json["text"]?.stringValue { return text }
        if let text = json["delta"]?.stringValue { return text }
        if case .array(let parts) = json["content"] {
            let joined = parts.compactMap { $0["text"]?.stringValue }.joined()
            return joined.isEmpty ? nil : joined
        }
        return nil
    }
}
