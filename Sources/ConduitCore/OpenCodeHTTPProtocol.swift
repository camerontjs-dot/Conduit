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
    public var turnActive = false
    public var lastTurnStatus: String?

    /// Text per `partID`, in first-seen order.
    ///
    /// OpenCode reports the same part twice over: `message.part.delta` carries
    /// an increment, `message.part.updated` carries the whole part as it now
    /// stands. Appending both double-counts every token, so a part's text is
    /// *replaced* by a snapshot and *extended* by a delta.
    private var partOrder: [String] = []
    private var partText: [String: String] = [:]

    /// Parts whose declared kind is not answer text, by `partID`.
    ///
    /// A `message.part.delta` carries `field: "text"` whether it is extending
    /// the answer or the model's reasoning, and never repeats the part's kind.
    /// The kind is only ever stated on the part's snapshot, which OpenCode
    /// sends before the deltas — so the id has to be remembered here or the
    /// reasoning stream is indistinguishable from the reply.
    private var nonAnswerParts: Set<String> = []

    /// `messageID` to role, learned from `message.updated`.
    ///
    /// A `message.part.updated` never carries a role, and OpenCode emits the
    /// operator's own prompt as a part exactly like the model's reply. Without
    /// this map the prompt is accumulated into agent output and handed back to
    /// the caller as if the agent had said it.
    private var roleByMessage: [String: String] = [:]

    /// Guards against re-emitting a closed turn.
    ///
    /// Completion is signalled more than once per turn — an assistant
    /// `message.updated` carrying `time.completed`, then `session.idle`, then
    /// a further `message.updated`. Each one used to append another copy of
    /// the same finished output.
    private var closedEmitted = false

    public init() {}

    /// Concatenated text of every part not known to belong to the operator.
    public var accumulatedText: String {
        partOrder.compactMap { partText[$0] }.joined()
    }

    public mutating func apply(_ json: CodexJSON) -> [StructuredAdapterEffect] {
        let type = json["type"]?.stringValue
            ?? json["event"]?.stringValue
            ?? ""
        let properties = json["properties"] ?? json
        if type == "server.connected" {
            return []
        }
        // Resolve the session from a field that actually holds a session id.
        // `info.id` is the *message* id on message events; reading it as the
        // session made every `message.updated` look like it belonged to another
        // session, so all of them were dropped — which is why roles were never
        // learned and the operator's prompt came back as agent output. Only a
        // `session.*` event may name its session in `id`.
        let eventSession = properties["sessionID"]?.stringValue
            ?? properties["info"]?["sessionID"]?.stringValue
            ?? properties["part"]?["sessionID"]?.stringValue
            ?? properties["session"]?["id"]?.stringValue
            ?? (type.hasPrefix("session") ? OpenCodeHTTPContract.sessionID(in: properties) : nil)
        if let bound = sessionID, let eventSession, eventSession != bound {
            return []
        }
        if type == "message.updated",
           let id = properties["info"]?["id"]?.stringValue,
           let role = properties["info"]?["role"]?.stringValue {
            roleByMessage[id] = role
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
        if type.contains("part"),
           let part = properties["part"],
           let declared = part["type"]?.stringValue,
           declared != "text" {
            // `reasoning`, `step-start`, `step-finish`, tool parts. Remember the
            // id so this part's deltas are recognised as non-answer too.
            if let partID = part["id"]?.stringValue {
                nonAnswerParts.insert(partID)
            }
            return []
        }
        if let fragment = Self.textFragment(in: properties, type: type) {
            if nonAnswerParts.contains(fragment.partID) { return [] }
            // A part whose message is known to be the operator's is not agent
            // output. Unknown messages are still accepted: OpenCode sends
            // `message.updated` before that message's parts, so an unknown id
            // means a shape we have not seen, and dropping it would silently
            // lose real agent output.
            let isOperator = fragment.messageID.flatMap { roleByMessage[$0] } == "user"
            if !isOperator {
                if partText[fragment.partID] == nil {
                    partOrder.append(fragment.partID)
                }
                switch fragment.kind {
                case .snapshot:
                    partText[fragment.partID] = fragment.text
                case .delta:
                    partText[fragment.partID, default: ""] += fragment.text
                }
                turnActive = true
                closedEmitted = false
                return [.upsertOutput(text: accumulatedText, state: .live)]
            }
            return []
        }
        if Self.isCompletion(type: type, json: properties) {
            // Completion is announced repeatedly; close the turn once.
            if closedEmitted { return [] }
            closedEmitted = true
            turnActive = false
            lastTurnStatus = "completed"
            var effects: [StructuredAdapterEffect] = []
            let text = accumulatedText
            if !text.isEmpty {
                effects.append(.upsertOutput(text: text, state: .closed))
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
        partOrder.removeAll()
        partText.removeAll()
        nonAnswerParts.removeAll()
        turnActive = false
        closedEmitted = false
        lastTurnStatus = nil
        // `roleByMessage` deliberately survives: it is per-session identity,
        // not per-turn state, and late parts of a closed message still need it.
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

    /// One piece of streamed text, tagged with how it combines with what came
    /// before and which message it belongs to.
    struct TextFragment {
        enum Kind { case snapshot, delta }
        let partID: String
        let messageID: String?
        let text: String
        let kind: Kind
    }

    /// Extracts streamed text and, critically, whether it replaces or extends.
    ///
    /// `message.part.updated` carries the part as it now stands (a snapshot);
    /// `message.part.delta` carries only the new characters. Treating the two
    /// alike is what produced `PONGPONG` for a one-word reply.
    static func textFragment(in json: CodexJSON, type: String) -> TextFragment? {
        if type == "message.part.delta" {
            guard json["field"]?.stringValue == "text",
                  let delta = json["delta"]?.stringValue,
                  let partID = json["partID"]?.stringValue
            else { return nil }
            return TextFragment(
                partID: partID,
                messageID: json["messageID"]?.stringValue,
                text: delta,
                kind: .delta
            )
        }
        if type.contains("part"), let part = json["part"] {
            // A part that declares a kind must declare itself textual answer
            // content. `step-start` and `step-finish` carry no text at all, but
            // a future kind that does — reasoning, for one — would otherwise be
            // merged into the answer with no separator and no label. An unknown
            // part with no declared type is still accepted so this cannot
            // silently drop real output.
            if let kind = part["type"]?.stringValue, kind != "text" { return nil }
            guard let text = part["text"]?.stringValue else { return nil }
            let partID = part["id"]?.stringValue ?? "opencode-part"
            return TextFragment(
                partID: partID,
                messageID: part["messageID"]?.stringValue,
                text: text,
                kind: .snapshot
            )
        }
        if let delta = json["delta"]?.stringValue {
            return TextFragment(
                partID: json["partID"]?.stringValue ?? "opencode-delta",
                messageID: json["messageID"]?.stringValue,
                text: delta,
                kind: .delta
            )
        }
        if let text = json["text"]?.stringValue,
           type.contains("message") || type.contains("part") {
            return TextFragment(
                partID: json["partID"]?.stringValue ?? "opencode-text",
                messageID: json["messageID"]?.stringValue,
                text: text,
                kind: .snapshot
            )
        }
        return nil
    }
}
