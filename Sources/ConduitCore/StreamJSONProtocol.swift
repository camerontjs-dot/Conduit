import Foundation

/// Parsers for Claude Code and Antigravity print-mode NDJSON.
public struct StreamJSONMapper: Equatable, Sendable {
    public var flavor: StreamJSONFlavor
    public var sessionID: String?
    public var accumulatedText = ""
    public var turnActive = false
    public var lastTurnStatus: String?

    public init(flavor: StreamJSONFlavor) {
        self.flavor = flavor
    }

    public mutating func applyLine(_ line: String) -> [StructuredAdapterEffect] {
        guard let json = CodexJSON.parseLine(line) else { return [] }
        switch flavor {
        case .claude:
            return applyClaude(json)
        case .antigravity:
            return applyAntigravity(json)
        }
    }

    public mutating func resetTurn() {
        accumulatedText = ""
        turnActive = false
        lastTurnStatus = nil
    }

    public static func claudeArguments(
        resumeSessionID: String?,
        prompt: String
    ) -> [String] {
        var args = [
            "-p",
            "--output-format", "stream-json",
            "--verbose",
            "--permission-mode", "plan",
        ]
        if let resumeSessionID, !resumeSessionID.isEmpty {
            args += ["-r", resumeSessionID]
        }
        args.append(prompt)
        return args
    }

    public static func antigravityArguments(
        resumeSessionID: String?,
        prompt: String
    ) -> [String] {
        var args = [
            "-p", prompt,
            "--output-format", "stream-json",
        ]
        if let resumeSessionID, !resumeSessionID.isEmpty {
            args += ["--conversation", resumeSessionID]
        }
        return args
    }

    private mutating func applyClaude(_ json: CodexJSON) -> [StructuredAdapterEffect] {
        let type = json["type"]?.stringValue ?? ""
        if let sessionID = json["session_id"]?.stringValue
            ?? json["sessionId"]?.stringValue {
            if self.sessionID != sessionID {
                self.sessionID = sessionID
                return [.sessionStarted(id: sessionID)]
                    + applyClaudeContent(json, type: type)
            }
        }
        return applyClaudeContent(json, type: type)
    }

    private mutating func applyClaudeContent(
        _ json: CodexJSON,
        type: String
    ) -> [StructuredAdapterEffect] {
        if type == "assistant" {
            let text = Self.claudeAssistantText(json)
            guard !text.isEmpty else { return [] }
            accumulatedText += text
            turnActive = true
            return [.upsertOutput(text: accumulatedText, state: .live)]
        }
        if type == "result" {
            turnActive = false
            let isError = json["is_error"]?.boolValue == true
            let status = isError ? "error" : (json["subtype"]?.stringValue ?? "success")
            lastTurnStatus = status
            if accumulatedText.isEmpty, let result = json["result"]?.stringValue {
                accumulatedText = result
            }
            var effects: [StructuredAdapterEffect] = []
            if !accumulatedText.isEmpty {
                effects.append(.upsertOutput(text: accumulatedText, state: .closed))
            }
            if isError {
                effects.append(.failed(json["result"]?.stringValue ?? "claude result error"))
            } else {
                effects.append(.turnCompleted(status: status))
            }
            return effects
        }
        return []
    }

    private mutating func applyAntigravity(_ json: CodexJSON) -> [StructuredAdapterEffect] {
        let event = json["event"]?.stringValue ?? json["type"]?.stringValue ?? ""
        if let sessionID = json["conversation_id"]?.stringValue
            ?? json["conversationId"]?.stringValue
            ?? json["result"]?["conversation_id"]?.stringValue
            ?? json["init"]?["conversation_id"]?.stringValue {
            if self.sessionID != sessionID {
                self.sessionID = sessionID
                return [.sessionStarted(id: sessionID)]
            }
        }
        if event == "init" {
            if let sessionID = json["conversation_id"]?.stringValue
                ?? json["init"]?["conversation_id"]?.stringValue {
                self.sessionID = sessionID
                return [.sessionStarted(id: sessionID)]
            }
            return []
        }
        if event == "step_update" || event == "content" {
            let text = json["text"]?.stringValue
                ?? json["delta"]?.stringValue
                ?? json["result"]?["response"]?.stringValue
                ?? ""
            guard !text.isEmpty else { return [] }
            accumulatedText += text
            turnActive = true
            return [.upsertOutput(text: accumulatedText, state: .live)]
        }
        if event == "result" {
            turnActive = false
            let result = json["result"] ?? json
            let status = result["status"]?.stringValue ?? "SUCCESS"
            lastTurnStatus = status
            if let response = result["response"]?.stringValue, accumulatedText.isEmpty {
                accumulatedText = response
            }
            if let sessionID = result["conversation_id"]?.stringValue {
                self.sessionID = sessionID
            }
            var effects: [StructuredAdapterEffect] = []
            if !accumulatedText.isEmpty {
                effects.append(.upsertOutput(text: accumulatedText, state: .closed))
            }
            if status.uppercased() == "SUCCESS" {
                effects.append(.turnCompleted(status: status))
            } else {
                effects.append(.failed(status))
            }
            return effects
        }
        return []
    }

    private static func claudeAssistantText(_ json: CodexJSON) -> String {
        let message = json["message"] ?? json
        if case .array(let parts) = message["content"] {
            return parts.compactMap { part -> String? in
                guard part["type"]?.stringValue == "text" || part["text"] != nil else {
                    return nil
                }
                return part["text"]?.stringValue
            }.joined()
        }
        return message["content"]?["text"]?.stringValue ?? json["text"]?.stringValue ?? ""
    }
}
