import Foundation

/// A provider terminal result, independent of runtime/task lifecycle and acceptance.
/// Only allowlisted protocol metadata is retained. Arbitrary provider payloads,
/// additionalDetails and free-form messages never enter durable history.
public struct ProviderTurnFailureReceipt: Codable, Equatable, Sendable {
    public let providerID: String
    public let runtime: String
    public let threadID: String
    public let turnID: String?
    public let requestID: Int?
    public var promptEventID: UUID?
    public var modelID: String?
    public let source: String
    public let errorType: String?
    public let httpStatusCode: Int?
    public let rpcErrorCode: Int?
    public let reason: String
    public let messageWithheld: Bool

    public static func codex(
        threadID: String, turnID: String?, requestID: Int? = nil,
        source: String, error: CodexJSON = .null, rpcErrorCode: Int? = nil
    ) -> Self {
        let info = error["codexErrorInfo"]
        let allowed: Set<String> = [
            "contextWindowExceeded", "sessionBudgetExceeded", "usageLimitExceeded",
            "rateLimitExceeded", "serverOverloaded", "cyberPolicy", "misalignmentPolicyViolation",
            "httpConnectionFailed", "responseStreamConnectionFailed", "internalServerError",
            "unauthorized", "badRequest", "threadRollbackFailed", "sandboxError",
            "responseStreamDisconnected", "responseTooManyFailedAttempts", "activeTurnNotSteerable", "other"
        ]
        let type: String?
        if let value = info?.stringValue, allowed.contains(value) {
            type = value
        } else if case .object(let object) = info, object.count == 1,
                  let key = object.keys.first, allowed.contains(key) {
            type = key
        } else {
            type = nil
        }
        var http: Int?
        if let type, case .number(let value) = info?[type]?["httpStatusCode"],
           value.isFinite, value.rounded() == value, (100...599).contains(value) {
            http = Int(value)
        }
        // This is a privacy allowlist, never a classifier of terminal failure.
        // The structured source/status/retry flag establishes terminality.
        let message = error["message"]?.stringValue ?? ""
        let pattern = #"^The '(gpt[a-zA-Z0-9._-]{1,120})' model is not supported when using Codex with a ChatGPT account\.$"#
        let safeMessage = message.range(of: pattern, options: .regularExpression) != nil
        let reason = safeMessage ? message : "Codex reported a terminal turn failure" + (type.map { " (\($0))" } ?? "") + "."
        return Self(
            providerID: "codex", runtime: "codex-app-server", threadID: threadID,
            turnID: turnID, requestID: requestID, promptEventID: nil, modelID: nil,
            source: source, errorType: type, httpStatusCode: http,
            rpcErrorCode: rpcErrorCode, reason: reason, messageWithheld: !safeMessage
        )
    }

    public func jsonObject() -> [String: Any] {
        var result: [String: Any] = [
            "provider_id": providerID, "runtime": runtime, "thread_id": threadID,
            "source": source, "reason": reason, "message_withheld": messageWithheld
        ]
        if let turnID { result["turn_id"] = turnID }
        if let requestID { result["request_id"] = requestID }
        if let promptEventID { result["prompt_event_id"] = promptEventID.uuidString }
        if let modelID { result["model_id"] = modelID }
        if let errorType { result["error_type"] = errorType }
        if let httpStatusCode { result["http_status_code"] = httpStatusCode }
        if let rpcErrorCode { result["rpc_error_code"] = rpcErrorCode }
        return result
    }
}
