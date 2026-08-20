import Foundation

/// OpenCode 1.18 HTTP/OpenAPI contract used by the Conduit adapter.
///
/// One leased `opencode serve` hosts many sessions. Session identity is the
/// `ses_…` id, not the process. SSE `GET /event` is the live observation
/// channel; `POST /session/:id/message` starts a turn.
public enum OpenCodeHTTPContract {
    public static let defaultPort = 18751
    public static let portRange = 18751...18759
    public static let leaseFileName = "opencode-lease.json"

    public static func healthURL(base: URL) -> URL {
        base.appendingPathComponent("global").appendingPathComponent("health")
    }

    public static func sessionCollectionURL(base: URL) -> URL {
        base.appendingPathComponent("session")
    }

    public static func sessionURL(base: URL, id: String) -> URL {
        sessionCollectionURL(base: base).appendingPathComponent(id)
    }

    public static func messageURL(base: URL, sessionID: String) -> URL {
        sessionURL(base: base, id: sessionID).appendingPathComponent("message")
    }

    public static func promptAsyncURL(base: URL, sessionID: String) -> URL {
        sessionURL(base: base, id: sessionID).appendingPathComponent("prompt_async")
    }

    public static func abortURL(base: URL, sessionID: String) -> URL {
        sessionURL(base: base, id: sessionID).appendingPathComponent("abort")
    }

    public static func permissionURL(
        base: URL,
        sessionID: String,
        permissionID: String
    ) -> URL {
        sessionURL(base: base, id: sessionID)
            .appendingPathComponent("permissions")
            .appendingPathComponent(permissionID)
    }

    public static func eventURL(base: URL) -> URL {
        base.appendingPathComponent("event")
    }

    public static func providerURL(base: URL) -> URL {
        base.appendingPathComponent("provider")
    }

    public static func sessionCreateBody(directory: String, title: String) -> [String: Any] {
        [
            "directory": directory,
            "title": title,
        ]
    }

    public static func promptBody(
        text: String,
        providerID: String?,
        modelID: String?
    ) -> [String: Any] {
        var body: [String: Any] = [
            "parts": [
                ["type": "text", "text": text],
            ]
        ]
        if let providerID, let modelID, !providerID.isEmpty, !modelID.isEmpty {
            body["model"] = [
                "providerID": providerID,
                "modelID": modelID,
            ]
        }
        return body
    }

    public static func permissionReplyBody(accept: Bool) -> [String: Any] {
        [
            "reply": accept ? "once" : "reject",
        ]
    }

    /// Split `google/gemini-2.5-flash` into provider + model.
    public static func splitModel(_ raw: String?) -> (providerID: String, modelID: String)? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let slash = trimmed.firstIndex(of: "/") {
            let provider = String(trimmed[..<slash])
            let model = String(trimmed[trimmed.index(after: slash)...])
            guard !provider.isEmpty, !model.isEmpty else { return nil }
            return (provider, model)
        }
        return nil
    }

    public static func sessionID(in json: CodexJSON) -> String? {
        json["id"]?.stringValue
            ?? json["sessionID"]?.stringValue
            ?? json["session"]?["id"]?.stringValue
    }

    public static func isHealthy(_ json: CodexJSON) -> Bool {
        json["healthy"]?.boolValue == true
    }
}

public struct OpenCodeServeLeaseRecord: Equatable, Sendable, Codable {
    public var pid: Int32
    public var url: String
    public var password: String
    public var version: String?
    public var ownedByConduit: Bool
    public var updatedAt: Date

    public init(
        pid: Int32,
        url: String,
        password: String,
        version: String? = nil,
        ownedByConduit: Bool = true,
        updatedAt: Date = Date()
    ) {
        self.pid = pid
        self.url = url
        self.password = password
        self.version = version
        self.ownedByConduit = ownedByConduit
        self.updatedAt = updatedAt
    }

    public var baseURL: URL? {
        URL(string: url)
    }
}

/// Maps OpenCode SSE / JSON events into Conversation effects.
public struct OpenCodeEventMapper: Equatable, Sendable {
    public var sessionID: String?
    public var accumulatedText = ""
    public var turnActive = false
    public var lastTurnStatus: String?

    public init() {}

    public mutating func apply(_ json: CodexJSON) -> [StructuredAdapterEffect] {
        let type = json["type"]?.stringValue
            ?? json["event"]?.stringValue
            ?? ""
        let properties = json["properties"] ?? json
        if type == "server.connected" {
            return []
        }
        let eventSession = OpenCodeHTTPContract.sessionID(in: properties)
            ?? properties["sessionID"]?.stringValue
            ?? properties["info"]?["id"]?.stringValue
        if let bound = sessionID, let eventSession, eventSession != bound {
            return []
        }
        if sessionID == nil, let eventSession {
            sessionID = eventSession
            return [.sessionStarted(id: eventSession)]
        }
        if type.contains("permission") {
            let id = properties["id"]?.stringValue
                ?? properties["permissionID"]?.stringValue
                ?? "opencode-permission"
            let summary = properties["permission"]?.stringValue
                ?? properties["title"]?.stringValue
                ?? properties["message"]?.stringValue
                ?? "OpenCode permission request"
            return [.requestApproval(id: id, summary: summary)]
        }
        if let delta = Self.textDelta(in: properties, type: type) {
            accumulatedText += delta
            turnActive = true
            return [.upsertOutput(text: accumulatedText, state: .live)]
        }
        if Self.isCompletion(type: type, json: properties) {
            turnActive = false
            lastTurnStatus = "completed"
            var effects: [StructuredAdapterEffect] = []
            if !accumulatedText.isEmpty {
                effects.append(.upsertOutput(text: accumulatedText, state: .closed))
            }
            effects.append(.turnCompleted(status: "completed"))
            return effects
        }
        if type.contains("error") {
            let message = properties["message"]?.stringValue ?? "opencode error"
            return [.failed(message)]
        }
        return []
    }

    public mutating func resetTurn() {
        accumulatedText = ""
        turnActive = false
        lastTurnStatus = nil
    }

    public static func parseSSELine(_ line: String) -> CodexJSON? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        return CodexJSON.parseLine(payload)
    }

    private static func isCompletion(type: String, json: CodexJSON) -> Bool {
        if type == "session.idle" || type == "session.complete" { return true }
        if type == "message.updated",
           json["info"]?["status"]?["complete"]?.boolValue == true {
            return true
        }
        if json["info"]?["time"]?["completed"] != nil,
           type.hasPrefix("session") || type.hasPrefix("message") {
            return json["info"]?["time"]?["completed"] != nil
                && json["info"]?["role"]?.stringValue != "user"
        }
        return false
    }

    private static func textDelta(in json: CodexJSON, type: String) -> String? {
        if let text = json["part"]?["text"]?.stringValue, type.contains("part") {
            return text
        }
        if let text = json["delta"]?.stringValue { return text }
        if let text = json["text"]?.stringValue,
           type.contains("message") || type.contains("part") {
            return text
        }
        return nil
    }
}
