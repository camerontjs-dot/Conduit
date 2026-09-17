import Foundation

/// Provider-reported OpenCode activity suitable for progressive disclosure in
/// Conversation. This is deliberately separate from assistant prose and from
/// Conduit's own Git/filesystem observations.
///
/// The type only represents structured events OpenCode actually emitted. It
/// does not infer a tool call from natural-language output and it does not turn
/// a tool completion into an independent verification claim.
public struct OpenCodeConversationActivity: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case tool
        case patch
    }

    public enum State: String, Codable, Equatable, Sendable {
        case pending
        case running
        case completed
        case failed
        case observed
    }

    public let id: String
    public let sessionID: String
    public let messageID: String?
    public let kind: Kind
    public let state: State
    public let title: String
    public let toolName: String?
    public let paths: [String]
    public let detail: String?

    public init(
        id: String,
        sessionID: String,
        messageID: String? = nil,
        kind: Kind,
        state: State,
        title: String,
        toolName: String? = nil,
        paths: [String] = [],
        detail: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.messageID = messageID
        self.kind = kind
        self.state = state
        self.title = title
        self.toolName = toolName
        self.paths = paths
        self.detail = detail
    }
}

/// Fail-closed projection from OpenCode's structured SSE payloads into compact
/// Conversation activity. Events without a provable matching session are
/// ignored so a shared `opencode serve` cannot leak another task's activity
/// into the selected thread.
public enum OpenCodeConversationActivityExtractor {
    public static func activity(
        from json: CodexJSON,
        boundSessionID: String
    ) -> OpenCodeConversationActivity? {
        guard !boundSessionID.isEmpty else { return nil }
        let type = json["type"]?.stringValue
            ?? json["event"]?.stringValue
            ?? ""
        guard type == "message.part.updated" else { return nil }

        let properties = json["properties"] ?? json
        guard let part = properties["part"] else { return nil }
        let observedSessionID = part["sessionID"]?.stringValue
            ?? properties["sessionID"]?.stringValue
        guard let sessionID = observedSessionID,
              sessionID == boundSessionID
        else { return nil }

        let partType = part["type"]?.stringValue ?? ""
        switch partType {
        case "tool":
            return toolActivity(part: part, sessionID: sessionID)
        case "patch":
            return patchActivity(part: part, sessionID: sessionID)
        default:
            return nil
        }
    }

    private static func toolActivity(
        part: CodexJSON,
        sessionID: String
    ) -> OpenCodeConversationActivity? {
        let partID = part["id"]?.stringValue
            ?? part["callID"]?.stringValue
        guard let partID, !partID.isEmpty else { return nil }

        let toolName = part["tool"]?.stringValue
        let stateJSON = part["state"]
        let rawState = stateJSON?["status"]?.stringValue?.lowercased()
        let state: OpenCodeConversationActivity.State
        switch rawState {
        case "pending": state = .pending
        case "running": state = .running
        case "completed": state = .completed
        case "error", "failed": state = .failed
        default: state = .observed
        }

        let explicitTitle = stateJSON?["title"]?.stringValue
            ?? part["title"]?.stringValue
        let fallbackTool = toolName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = nonEmpty(explicitTitle)
            ?? nonEmpty(fallbackTool).map { "Tool · \($0)" }
            ?? "Tool activity"

        let input = stateJSON?["input"] ?? part["input"]
        let paths = candidatePaths(in: input)
        let detail: String?
        if state == .failed {
            detail = bounded(
                stateJSON?["error"]?.stringValue
                    ?? part["error"]?.stringValue,
                maximumCharacters: 240
            )
        } else {
            // Tool output can contain arbitrary source contents or secrets.
            // The default activity card therefore records identity/status only.
            detail = nil
        }

        return OpenCodeConversationActivity(
            id: "opencode-tool:\(partID)",
            sessionID: sessionID,
            messageID: part["messageID"]?.stringValue,
            kind: .tool,
            state: state,
            title: title,
            toolName: toolName,
            paths: paths,
            detail: detail
        )
    }

    private static func patchActivity(
        part: CodexJSON,
        sessionID: String
    ) -> OpenCodeConversationActivity? {
        let partID = part["id"]?.stringValue
            ?? part["hash"]?.stringValue
        guard let partID, !partID.isEmpty else { return nil }
        let paths = stringArray(part["files"])
        let title: String
        if paths.isEmpty {
            title = "Patch reported"
        } else if paths.count == 1 {
            title = "Changed \(paths[0])"
        } else {
            title = "Changed \(paths.count) files"
        }
        return OpenCodeConversationActivity(
            id: "opencode-patch:\(partID)",
            sessionID: sessionID,
            messageID: part["messageID"]?.stringValue,
            kind: .patch,
            state: .observed,
            title: title,
            paths: paths
        )
    }

    private static func candidatePaths(in input: CodexJSON?) -> [String] {
        guard let input else { return [] }
        let keys = [
            "path",
            "file",
            "filePath",
            "file_path",
            "filename",
            "target",
        ]
        var values: [String] = []
        for key in keys {
            if let value = nonEmpty(input[key]?.stringValue) {
                values.append(value)
            }
        }
        return deduplicated(values)
    }

    private static func stringArray(_ json: CodexJSON?) -> [String] {
        guard case .array(let values)? = json else { return [] }
        return deduplicated(values.compactMap { nonEmpty($0.stringValue) })
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func bounded(
        _ value: String?,
        maximumCharacters: Int
    ) -> String? {
        guard let value = nonEmpty(value) else { return nil }
        guard value.count > maximumCharacters else { return value }
        return String(value.prefix(maximumCharacters)) + "…"
    }
}
