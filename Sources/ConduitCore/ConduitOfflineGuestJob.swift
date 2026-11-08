import Foundation
import CryptoKit
import Darwin

/// Exchange data only. This record cannot grant host execution or select argv.
public struct ConduitOfflineGuestJob: Codable, Equatable {
    public let schemaVersion: String
    public let operationID: String
    public let attemptID: String
    public let profileID: String
    public let workerUID: UInt32
    public let workerSHA256: String
    public let projectManifestSHA256: String
    public let checkScriptSHA256: String
    public let toolchainInventorySHA256: String
    public let dependencyInventorySHA256: String

    public static func decode(_ data: Data) throws -> Self {
        let keys: Set<String> = ["schemaVersion", "operationID", "attemptID", "profileID", "workerUID", "workerSHA256",
                                 "projectManifestSHA256", "checkScriptSHA256", "toolchainInventorySHA256", "dependencyInventorySHA256"]
        guard data.count <= 8_192,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys) == keys else {
            throw ConduitDirectCommandError(code: "invalid_guest_request", detail: "Require the fixed bounded guest job schema, without command/environment fields")
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        let idChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard value.schemaVersion == "conduit-offline-guest-job/v1", !value.operationID.isEmpty,
              value.operationID.utf8.count <= 128, value.operationID.unicodeScalars.allSatisfy({ idChars.contains($0) }),
              UUID(uuidString: value.attemptID) != nil,
              !value.profileID.isEmpty, value.profileID.utf8.count <= 128, value.workerUID >= 501,
              [value.workerSHA256, value.projectManifestSHA256, value.checkScriptSHA256,
               value.toolchainInventorySHA256, value.dependencyInventorySHA256].allSatisfy(validDigest) else {
            throw ConduitDirectCommandError(code: "invalid_guest_request", detail: "Guest identity or content binding is invalid")
        }
        return value
    }

    public static let argv = ["/bin/bash", "/work/project/scripts/test.sh", "--jobs", "2"]
    public static let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
                                     "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
                                     "HOME": "/work/home", "TMPDIR": "/work/tmp/"]
    public static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// Exact retained prefix and observed-byte count, not a full-log claim.
public struct ConduitOfflineGuestOutput: Codable, Equatable {
    public private(set) var prefix = Data()
    public private(set) var observedBytes: UInt64 = 0
    public private(set) var reachedEOF = false
    public let limit: Int
    public init(limit: Int = 1_048_576) { self.limit = min(1_048_576, max(0, limit)) }
    public mutating func append(_ data: Data) {
        observedBytes += UInt64(data.count)
        prefix.append(data.prefix(max(0, limit - prefix.count)))
    }
    public mutating func finish() { reachedEOF = true }
    public var omittedBytes: UInt64 { observedBytes - UInt64(prefix.count) }
}

/// Durable, exclusive evidence writes; never replaces an earlier attempt.
public enum ConduitOfflineGuestEvidence {
    public static func writeOnce(_ bytes: Data, directory: URL, name: String) throws {
        guard ["attempt.claim", "result.json"].contains(name), bytes.count <= 16_777_216 else {
            throw ConduitDirectCommandError(code: "guest_evidence_invalid", detail: "Unknown evidence name or size")
        }
        let dir = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw failure() }; defer { close(dir) }
        var info = stat()
        guard fstat(dir, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw failure() }
        let stage = "." + name + "-" + UUID().uuidString + ".tmp"
        let fd = openat(dir, stage, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure() }; defer { close(fd) }
        // Failed partial files remain evidence. Never clean them to permit retry.
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw failure() }; offset += n
            }
        }
        guard fsync(fd) == 0, renameatx_np(dir, stage, dir, name, UInt32(RENAME_EXCL)) == 0,
              fsync(dir) == 0 else { throw failure() }
    }
    private static func failure() -> ConduitDirectCommandError {
        .init(code: "guest_evidence_unavailable", detail: "Evidence write/sync failed or prior attempt exists; preserve all bytes and refuse retry")
    }
}
