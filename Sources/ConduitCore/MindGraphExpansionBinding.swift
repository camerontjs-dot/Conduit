import Foundation
import CoreFoundation

/// An origin-bound locator, not an authorization token. The scope identifies the
/// explicit CLI/MCP route; exp2 independently names the stored producer index.
public enum MindGraphExpansionBinding {
    public struct Locator: Equatable, Sendable {
        public let handle: String
        public let scopeAlias: String?
        public let indexID: String
        public let namespace: String?
        public let path: String
        public let docID: String
        public let chunkIndex: Int
        public let contentHash: String?
    }

    public struct BindingError: Error, LocalizedError, Equatable, Sendable {
        public let reason: String
        public var errorDescription: String? { reason }
        public init(_ reason: String) { self.reason = reason }
    }

    private static let maximumHandleBytes = 8192
    private static let upstreamKeys: Set<String> = [
        "v", "scope", "index_id", "namespace", "path", "doc_id", "chunk_index", "content_hash",
    ]

    /// Parse the canonical producer format. exp1 cannot prove independent index
    /// identity and is rejected with no attempt to reinterpret its scope field.
    public static func locator(_ handle: String) throws -> Locator {
        let row = try object(handle, prefix: "exp2:", keys: upstreamKeys)
        guard try string(row, "v") == "exp2" else { throw BindingError("Unsupported expansion version; query again.") }
        return try Locator(
            handle: handle,
            scopeAlias: optionalString(row, "scope"),
            indexID: string(row, "index_id"),
            namespace: optionalString(row, "namespace"),
            path: string(row, "path"),
            docID: string(row, "doc_id"),
            chunkIndex: integer(row, "chunk_index"),
            contentHash: optionalString(row, "content_hash")
        )
    }

    /// Require the same explicit scope that Conduit supplied at query time.
    /// This check happens before any expansion process or source-text read.
    public static func validateRequest(_ handle: String, scope: String) throws -> Locator {
        try validateScope(scope)
        let target = try locator(handle)
        guard target.scopeAlias == scope else {
            throw BindingError("Expansion handle origin does not match requested scope.")
        }
        return target
    }

    /// Validate a producer response independently, including an exact echoed
    /// handle. A defective producer cannot substitute a colliding source row.
    public static func validateResponse(_ data: Data, upstreamHandle: String) throws {
        let expected = try locator(upstreamHandle)
        guard let row = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BindingError("Invalid expansion response.")
        }
        guard try string(row, "expansion_handle") == expected.handle,
              try string(row, "index_id") == expected.indexID,
              try string(row, "doc_id") == expected.docID,
              try string(row, "path") == expected.path,
              try integer(row, "chunk_index") == expected.chunkIndex,
              try optionalString(row, "namespace") == expected.namespace,
              try optionalString(row, "scope_index") == expected.scopeAlias else {
            throw BindingError("Expansion response identity does not match requested locator.")
        }
        let observedHash = try optionalString(row, "content_hash")
        if let hash = expected.contentHash {
            guard observedHash?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == hash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  let match = row["content_hash_match"] as? NSNumber,
                  CFGetTypeID(match) == CFBooleanGetTypeID(), match.boolValue else {
                throw BindingError("Expansion response lost or contradicted the nominated content hash.")
            }
        } else if let match = row["content_hash_match"], !(match is NSNull) {
            // Unknown in the original nomination must not acquire a true match.
            throw BindingError("Expansion response invented a match for an unknown hash.")
        }
        guard row["chunk_text"] is String,
              try string(row, "freshness") == "UNKNOWN",
              ["citable", "unverified", "not_citable"].contains(try string(row, "citation_class")) else {
            throw BindingError("Expansion source text or authority metadata is invalid.")
        }
    }

    /// Only reviewed fields cross the external response. No arbitrary producer
    /// property, raw process output, source_root, or diagnostic is forwarded.
    public static func agentResponse(_ data: Data, expansionHandle: String, scope: String) throws -> [String: Any] {
        _ = try validateRequest(expansionHandle, scope: scope)
        try validateResponse(data, upstreamHandle: expansionHandle)
        guard let row = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BindingError("Invalid expansion response.")
        }
        let fields = ["doc_id", "chunk_index", "path", "display_path", "title", "chunk_text",
                      "index_id", "namespace", "content_hash", "content_hash_match", "freshness",
                      "raw_status", "citation_class", "trust_profile", "provenance_warning"]
        var result: [String: Any] = [
            "scope": scope, "expansion_handle": expansionHandle,
            "authority": "source-backed expansion; context only, not verification",
        ]
        for key in fields { if let value = row[key] { result[key] = value } }
        return result
    }

    private static func validateScope(_ scope: String) throws {
        guard ["knowledge", "projects"].contains(scope) else { throw BindingError("Unknown MindGraph scope.") }
    }

    private static func object(_ handle: String, prefix: String, keys: Set<String>) throws -> [String: Any] {
        guard handle.utf8.count <= maximumHandleBytes, handle.hasPrefix(prefix) else {
            throw BindingError("Index-bound expansion handle required; query again.")
        }
        let token = String(handle.dropFirst(prefix.count))
        let standard = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let bytes = Data(base64Encoded: standard), base64URL(bytes) == token,
              let row = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(row.keys) == keys,
              try canonical(row) == bytes else {
            throw BindingError("Malformed or noncanonical expansion handle.")
        }
        return row
    }

    private static func string(_ row: [String: Any], _ key: String) throws -> String {
        guard let value = row[key] as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BindingError("Required expansion identity is missing or malformed.")
        }
        return value
    }

    private static func optionalString(_ row: [String: Any], _ key: String) throws -> String? {
        guard let value = row[key] else { throw BindingError("Expansion binding field is missing.") }
        if value is NSNull { return nil }
        return try string(row, key)
    }

    private static func integer(_ row: [String: Any], _ key: String) throws -> Int {
        guard let number = row[key] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: number.objCType)),
              let value = Int(number.stringValue), value >= 0 else {
            throw BindingError("Expansion chunk identity must be a nonnegative integer.")
        }
        return value
    }

    private static func base64URL(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }

    // The producer uses sorted compact JSON with ensure_ascii=False. Explicit
    // escaping keeps Unicode and U+2028/U+2029 identical across Foundation builds.
    // Requiring this spelling also rejects duplicate JSON keys and number coercion.
    private static func canonical(_ object: [String: Any]) throws -> Data {
        let entries = try object.keys.sorted().map { key -> String in
            let value = object[key]!
            let encoded: String
            if value is NSNull { encoded = "null" }
            else if let text = value as? String { encoded = quote(text) }
            else { encoded = String(try integer(object, key)) }
            return quote(key) + ":" + encoded
        }
        return Data(("{" + entries.joined(separator: ",") + "}").utf8)
    }

    private static func quote(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 34: out += "\\\""
            case 92: out += "\\\\"
            case 8: out += "\\b"
            case 9: out += "\\t"
            case 10: out += "\\n"
            case 12: out += "\\f"
            case 13: out += "\\r"
            case 0..<32: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
