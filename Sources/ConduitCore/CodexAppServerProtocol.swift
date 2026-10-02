import Foundation

/// Minimal JSON value for Codex app-server envelopes. The vendor schema moves
/// with the CLI; Conduit extracts a few known fields and ignores the rest.
public enum CodexJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([CodexJSON])
    case object([String: CodexJSON])

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public subscript(key: String) -> CodexJSON? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public static func parse(_ data: Data) -> CodexJSON? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return fromJSONObject(raw)
    }

    public static func parseLine(_ line: String) -> CodexJSON? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            return nil
        }
        return parse(data)
    }

    public func jsonObject() -> Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let values): return values.map { $0.jsonObject() }
        case .object(let object):
            return object.mapValues { $0.jsonObject() }
        }
    }

    private static func fromJSONObject(_ raw: Any) -> CodexJSON {
        switch raw {
        case is NSNull:
            return .null
        case let value as NSNumber:
            // JSONSerialization uses NSNumber for both bool and number.
            // Check CFBoolean first; a Swift `as Bool` cast would also eat 0/1.
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            return .number(value.doubleValue)
        case let value as Bool:
            return .bool(value)
        case let value as String:
            return .string(value)
        case let value as [Any]:
            return .array(value.map(fromJSONObject))
        case let value as [String: Any]:
            return .object(value.mapValues(fromJSONObject))
        default:
            return .null
        }
    }
}

public enum CodexJSONRPCID: Equatable, Sendable {
    case number(Int)
    case string(String)

    public static func parse(_ json: CodexJSON?) -> CodexJSONRPCID? {
        guard let json else { return nil }
        switch json {
        case .string(let value):
            return .string(value)
        case .number(let value):
            // Conduit's outbound request ids are integers. Never truncate a
            // fractional or out-of-range provider value into another request.
            guard let integer = Int(exactly: value) else { return nil }
            return .number(integer)
        default:
            return nil
        }
    }

    public var jsonObject: Any {
        switch self {
        case .number(let value): return value
        case .string(let value): return value
        }
    }
}

public enum CodexJSONRPCMessage: Equatable, Sendable {
    case notification(method: String, params: CodexJSON)
    case request(id: CodexJSONRPCID, method: String, params: CodexJSON)
    case response(id: CodexJSONRPCID, result: CodexJSON)
    case error(id: CodexJSONRPCID?, message: String, code: Int? = nil)

    public static func parseLine(_ line: String) -> CodexJSONRPCMessage? {
        guard let json = CodexJSON.parseLine(line) else { return nil }
        return parse(json)
    }

    public static func parse(_ json: CodexJSON) -> CodexJSONRPCMessage? {
        guard case .object = json else { return nil }
        let id = CodexJSONRPCID.parse(json["id"])
        if let rawID = json["id"], rawID != .null, id == nil { return nil }
        let method = json["method"]?.stringValue
        if let error = json["error"] {
            // JSON-RPC rejection authority requires a valid Error object, not
            // merely a matching request id. Preserve malformed envelopes as a
            // stream/protocol failure instead of manufacturing provider-turn
            // failure semantics from correlation alone.
            guard json["result"] == nil, json["method"] == nil,
                  case .object(let object) = error,
                  let message = object["message"]?.stringValue,
                  case .number(let rawCode)? = object["code"],
                  rawCode.isFinite,
                  rawCode.rounded() == rawCode,
                  (Double(Int32.min)...Double(Int32.max)).contains(rawCode)
            else { return nil }
            return .error(id: id, message: message, code: Int(rawCode))
        }
        if json["method"] != nil {
            guard let method, !method.isEmpty, json["result"] == nil else { return nil }
            let params = json["params"] ?? .object([:])
            if let id {
                return .request(id: id, method: method, params: params)
            }
            return .notification(method: method, params: params)
        }
        if let id, json["result"] != nil {
            return .response(id: id, result: json["result"] ?? .null)
        }
        return nil
    }
}

public struct CodexAppServerApproval: Equatable, Identifiable, Sendable {
    public var id: String
    public var rpcID: CodexJSONRPCID
    public var method: String
    public var summary: String

    public init(
        id: String,
        rpcID: CodexJSONRPCID,
        method: String,
        summary: String
    ) {
        self.id = id
        self.rpcID = rpcID
        self.method = method
        self.summary = summary
    }

    public var acceptResult: [String: Any] {
        switch method {
        case "item/commandExecution/requestApproval", "execCommandApproval":
            return ["decision": "accept"]
        case "item/permissions/requestApproval":
            return ["permissions": [String: Any](), "scope": "turn"]
        default:
            return ["decision": "approved"]
        }
    }

    public var declineResult: [String: Any] {
        switch method {
        case "item/commandExecution/requestApproval", "execCommandApproval":
            return ["decision": "decline"]
        default:
            return [
                "decision": [
                    "denied": ["rejection": "operator declined"]
                ]
            ]
        }
    }

    /// `item/permissions/requestApproval` has no deny payload — an empty
    /// `permissions` object would grant the request. Decline that method with
    /// a JSON-RPC error instead.
    public var declineUsesRPCError: Bool {
        method == "item/permissions/requestApproval"
    }
}

public enum CodexAppServerEffect: Equatable, Sendable {
    case threadStarted(id: String)
    case turnStarted(id: String)
    case upsertOutput(text: String, state: AgentOutputState)
    case requestApproval(CodexAppServerApproval)
    case turnCompleted(status: String)
    case turnFailed(ProviderTurnFailureReceipt)
    case failed(String)
}

/// Accumulates app-server notifications into Conversation-shaped effects.
public struct CodexAppServerMapper: Equatable, Sendable {
    public var threadID: String?
    public var activeTurnID: String?
    public var accumulatedText = ""
    public var turnActive = false
    public var lastTurnStatus: String?
    public var lastAppendWasNote = false
    private var lastFailedTurnID: String?
    private var lastTerminalTurnID: String?
    private var expectedThreadResponseID: CodexJSONRPCID?
    // A new input resets its presentation, not the identity of retired turns.
    // Keep tombstones for this host/thread so delayed notifications cannot
    // become authority for a later input.
    private var retiredTurnIDs: Set<String> = []

    public init() {}

    /// The client registers its own outstanding thread/start or thread/resume
    /// request before sending it. A response's shape alone is not identity
    /// authority, and this expectation is consumed exactly once.
    public mutating func expectThreadResponse(_ id: CodexJSONRPCID) {
        expectedThreadResponseID = id
    }

    public mutating func cancelThreadResponseExpectation() {
        expectedThreadResponseID = nil
    }

    public mutating func apply(
        _ message: CodexJSONRPCMessage
    ) -> [CodexAppServerEffect] {
        switch message {
        case .error(let id, let message, _):
            if id == expectedThreadResponseID {
                expectedThreadResponseID = nil
            }
            return [.failed(message)]
        case .response(let id, let result):
            guard id == expectedThreadResponseID else { return [] }
            expectedThreadResponseID = nil
            if let threadID = Self.threadID(in: result), !threadID.isEmpty {
                self.threadID = threadID
                return [.threadStarted(id: threadID)]
            }
            return []
        case .notification(let method, let params):
            return applyNotification(method: method, params: params)
        case .request(let id, let method, let params):
            if Self.isApprovalMethod(method) {
                guard acceptsNonterminal(params) else { return [] }
                let summary = Self.approvalSummary(method: method, params: params)
                return [
                    .requestApproval(
                        CodexAppServerApproval(
                            id: "\(method)-\(summary.prefix(24))",
                            rpcID: id,
                            method: method,
                            summary: summary
                        )
                    )
                ]
            }
            return []
        }
    }

    public mutating func resetTurn() {
        activeTurnID = nil
        accumulatedText = ""
        turnActive = false
        lastTurnStatus = nil
        lastAppendWasNote = false
        lastFailedTurnID = nil
        lastTerminalTurnID = nil
    }

    private mutating func applyNotification(
        method: String,
        params: CodexJSON
    ) -> [CodexAppServerEffect] {
        switch method {
        case "thread/started":
            if let threadID = Self.threadID(in: params) {
                guard self.threadID == nil || self.threadID == threadID else { return [] }
                self.threadID = threadID
                return [.threadStarted(id: threadID)]
            }
            return []
        case "turn/started":
            let incomingTurn = params["turn"]?["id"]?.stringValue
                ?? params["turnId"]?.stringValue
            guard let incomingTurn, !incomingTurn.isEmpty,
                  !retiredTurnIDs.contains(incomingTurn),
                  lastTurnStatus == nil,
                  activeTurnID == nil || activeTurnID == incomingTurn
            else { return [] }
            if let incoming = params["threadId"]?.stringValue {
                guard threadID == nil || threadID == incoming else { return [] }
                threadID = incoming
            }
            turnActive = true
            lastTurnStatus = nil
            lastFailedTurnID = nil
            lastTerminalTurnID = nil
            activeTurnID = incomingTurn
            return [.turnStarted(id: incomingTurn)]
        case "item/agentMessage/delta":
            guard acceptsNonterminal(params) else { return [] }
            let delta = Self.deltaText(in: params)
            guard !delta.isEmpty else { return [] }
            if lastAppendWasNote, !accumulatedText.hasSuffix("\n"), !delta.hasPrefix("\n") {
                accumulatedText += "\n"
            }
            accumulatedText += delta
            lastAppendWasNote = false
            turnActive = true
            return [.upsertOutput(text: accumulatedText, state: .live)]
        case "item/started", "item/completed":
            guard acceptsNonterminal(params) else { return [] }
            // Skip chat-chrome items (userMessage, agentMessage, …). Those
            // already have Conversation events; dumping `[userMessage]` into
            // the assistant card makes the turn look like a protocol dump.
            if let note = Self.itemNote(in: params) {
                if !accumulatedText.isEmpty { accumulatedText += "\n" }
                accumulatedText += note
                lastAppendWasNote = true
                return [.upsertOutput(text: accumulatedText, state: .live)]
            }
            return []
        case "turn/completed":
            let incomingThread = params["threadId"]?.stringValue
            let incomingTurn = params["turn"]?["id"]?.stringValue ?? params["turnId"]?.stringValue
            if let incomingTurn, retiredTurnIDs.contains(incomingTurn) { return [] }
            guard incomingThread == nil || threadID == nil || incomingThread == threadID,
                  incomingTurn == nil || activeTurnID == nil || incomingTurn == activeTurnID
            else { return [] }
            if !turnActive, let lastFailedTurnID, incomingTurn != lastFailedTurnID { return [] }
            if !turnActive, let lastTerminalTurnID, incomingTurn != lastTerminalTurnID { return [] }
            let status = params["turn"]?["status"]?.stringValue
                ?? params["status"]?.stringValue ?? "completed"
            if status == "failed" {
                guard let thread = incomingThread, thread == threadID,
                      let turn = incomingTurn,
                      turn == activeTurnID || (!turnActive && turn == lastFailedTurnID)
                else { return [] }
                let receipt = ProviderTurnFailureReceipt.codex(
                    threadID: thread, turnID: turn,
                    source: "turn/completed.failed", error: params["turn"]?["error"] ?? .null
                )
                turnActive = false
                activeTurnID = nil
                lastTurnStatus = "failed"
                lastFailedTurnID = receipt.turnID
                lastTerminalTurnID = receipt.turnID
                retiredTurnIDs.insert(turn)
                return [.turnFailed(receipt)]
            }
            if lastTurnStatus == "failed", incomingTurn == lastFailedTurnID { return [] }
            if let terminalTurn = incomingTurn ?? activeTurnID {
                retiredTurnIDs.insert(terminalTurn)
            }
            turnActive = false
            activeTurnID = nil
            lastTurnStatus = status
            lastTerminalTurnID = incomingTurn
            var effects: [CodexAppServerEffect] = []
            if !accumulatedText.isEmpty {
                effects.append(.upsertOutput(text: accumulatedText, state: .closed))
            }
            effects.append(.turnCompleted(status: status))
            return effects
        case "error":
            // Retryable and uncorrelated errors are diagnostics, not turn results.
            guard params["willRetry"]?.boolValue == false,
                  let thread = params["threadId"]?.stringValue, thread == threadID,
                  let turn = params["turnId"]?.stringValue, turn == activeTurnID,
                  turnActive, case .object = params["error"],
                  params["error"]?["message"]?.stringValue != nil else { return [] }
            let receipt = ProviderTurnFailureReceipt.codex(
                threadID: thread, turnID: turn,
                source: "error.willRetry=false", error: params["error"] ?? .null
            )
            turnActive = false
            activeTurnID = nil
            lastTurnStatus = "failed"
            lastFailedTurnID = turn
            lastTerminalTurnID = turn
            retiredTurnIDs.insert(turn)
            return [.turnFailed(receipt)]
        default:
            return []
        }
    }

    private func acceptsNonterminal(_ params: CodexJSON) -> Bool {
        guard lastTurnStatus == nil else { return false }
        if let incomingThread = params["threadId"]?.stringValue,
           let threadID, incomingThread != threadID { return false }
        if let incomingTurn = params["turnId"]?.stringValue
            ?? params["turn"]?["id"]?.stringValue {
            if retiredTurnIDs.contains(incomingTurn) { return false }
            if let activeTurnID, incomingTurn != activeTurnID { return false }
        }
        return true
    }

    private static func isApprovalMethod(_ method: String) -> Bool {
        method.contains("Approval") || method.hasSuffix("/requestApproval")
    }

    private static func threadID(in json: CodexJSON) -> String? {
        json["thread"]?["id"]?.stringValue
            ?? json["threadId"]?.stringValue
    }

    private static func deltaText(in params: CodexJSON) -> String {
        params["delta"]?.stringValue
            ?? params["text"]?.stringValue
            ?? params["item"]?["text"]?.stringValue
            ?? ""
    }

    private static let conversationChromeTypes: Set<String> = [
        "userMessage",
        "agentMessage",
        "reasoning",
        "thought",
        "plan",
        "contextCompacted",
        "compaction",
        "tokenUsage",
    ]

    private static func itemNote(in params: CodexJSON) -> String? {
        let item = params["item"] ?? params
        let type = item["type"]?.stringValue ?? item["itemType"]?.stringValue
        guard let type, !conversationChromeTypes.contains(type) else { return nil }
        if let command = item["command"]?.stringValue, !command.isEmpty {
            return "[\(type)] \(command)"
        }
        if let path = item["path"]?.stringValue ?? item["changes"]?.stringValue,
           !path.isEmpty {
            return "[\(type)] \(path)"
        }
        return nil
    }

    private static func approvalSummary(method: String, params: CodexJSON) -> String {
        if let command = params["command"]?.stringValue { return command }
        if let reason = params["reason"]?.stringValue { return reason }
        if let item = params["item"]?["command"]?.stringValue { return item }
        return method
    }
}

public enum CodexThreadWriterCollisionMapper {
    /// Translate current Codex-native single-writer errors into the canonical
    /// provider-session authority failure. Matching stays adapter-specific;
    /// orchestration policy consumes only the canonical writer_collision code.
    public static func isActiveWriterConflict(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("already has an active writer")
            || normalized.contains("open in another app")
    }
}

public enum CodexAppServerRequests {
    public static func initialize(id: Int) -> [String: Any] {
        [
            "method": "initialize",
            "id": id,
            "params": [
                "clientInfo": [
                    "name": "conduit",
                    "title": "Conduit",
                    "version": "1.0",
                ]
            ]
        ]
    }

    public static func initialized() -> [String: Any] {
        ["method": "initialized", "params": [String: Any]()]
    }

    public static func threadStart(
        id: Int,
        cwd: String,
        model: String?
    ) -> [String: Any] {
        var params: [String: Any] = [
            "cwd": cwd,
            "serviceName": "conduit",
        ]
        if let model, !model.isEmpty {
            params["model"] = model
        }
        return ["method": "thread/start", "id": id, "params": params]
    }

    public static func turnStart(
        id: Int,
        threadID: String,
        text: String
    ) -> [String: Any] {
        [
            "method": "turn/start",
            "id": id,
            "params": [
                "threadId": threadID,
                "input": [
                    ["type": "text", "text": text]
                ]
            ]
        ]
    }

    public static func turnSteer(
        id: Int,
        threadID: String,
        text: String
    ) -> [String: Any] {
        [
            "method": "turn/steer",
            "id": id,
            "params": [
                "threadId": threadID,
                "input": [
                    ["type": "text", "text": text]
                ]
            ]
        ]
    }

    public static func turnInterrupt(
        id: Int,
        threadID: String,
        turnID: String
    ) -> [String: Any] {
        [
            "method": "turn/interrupt",
            "id": id,
            "params": ["threadId": threadID, "turnId": turnID]
        ]
    }

    public static func threadResume(id: Int, threadID: String) -> [String: Any] {
        [
            "method": "thread/resume",
            "id": id,
            "params": ["threadId": threadID]
        ]
    }

    public static func rateLimitsRead(id: Int) -> [String: Any] {
        [
            "method": "account/rateLimits/read",
            "id": id,
            "params": [String: Any]()
        ]
    }
}
