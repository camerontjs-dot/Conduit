import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Description only. Decoding this value never grants execution.
public struct ConduitPortableOfflineProfile: Codable, Equatable, Sendable {
    public static let v1 = ConduitPortableOfflineProfile()
    public private(set) var profileID = "conduit-portable-offline-check/v1"
    public private(set) var checkID = "bash-grep-fixture/v1"
    public private(set) var argv = ["/bin/bash", "/work/project/scripts/test.sh", "--jobs", "2"]
    public private(set) var environment = ["PATH": "/usr/bin:/bin", "LANG": "C", "HOME": "/work/scratch", "TMPDIR": "/work/scratch"]
    public private(set) var hostEnvironment = ["PATH": "/usr/bin:/bin", "LANG": "C"]
    public private(set) var cpuCount = 1
    public private(set) var memoryBytes = 134_217_728
    public private(set) var jobMemoryBytes = 33_554_432
    public private(set) var maximumTasks = 16
    public private(set) var cpuQuota = "20000 100000"
    public private(set) var projectBytes = 1_048_576
    public private(set) var scratchBytes = 1_048_576
    public private(set) var jobDeadlineMS = 1_500
    public private(set) var hostDeadlineMS = 5_000
    public private(set) var maximumStreamBytes = 4_096
    public private(set) var maximumNativeCaptureBytes = 262_144
    public private(set) var scriptSHA256 = "4dd35505ff40e03a07f3320c95a97c1034558d49122e0b75384d4e8883b728c4"
    private init() {}
}

/// An observed host directory identity, not ownership recovered from a receipt.
internal struct ConduitPortableDirectory: Codable, Equatable {
    let path: String
    let identity: String

    static func observe(_ path: String, privateDirectory: Bool) throws -> Self {
        let fd = try ConduitOfflineFS.openAbsolute(path, directory: true)
        defer { close(fd) }
        let info = try ConduitOfflineFS.info(fd)
        guard info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFDIR,
              !privateDirectory || info.st_mode & 0o077 == 0 else {
            throw ConduitOfflineFailure("portable_directory_not_owned_private")
        }
        return Self(path: path, identity: try ConduitOfflineFS.identity(fd))
    }
}

/// All execution inputs are immutable after the trusted fixture owner issues a grant.
/// Guest scratch is the fixed tmpfs in the profile; fixtureRoot is host capture storage.
internal struct ConduitPortableOfflineBinding: Codable, Equatable {
    let profile: ConduitPortableOfflineProfile
    let operationID: String
    let nonce: String
    let fixtureRoot: ConduitPortableDirectory
    let projectRoot: ConduitPortableDirectory
    let manifestSHA256: String
    let nativeTicketSHA256: String
    let nativeExecutable: ConduitOfflineAsset
    let kernel: ConduitOfflineAsset
    let initramfs: ConduitOfflineAsset
    let supervisor: ConduitOfflineAsset
    let slot: ConduitPortableDirectory?
    let expectedCases: [String]
    let mode: String
    let issuedAtUnixSeconds: Double
    let expiresAtUnixSeconds: Double

    var vmDeadlineSeconds: Double { mode == "complete" ? 4 : 5.75 }

    func validate(now: Date, currentInputs: Bool = true) throws {
        guard profile == .v1, ["complete", "cooperative", "default"].contains(mode),
              operationID.utf8.count > 0, operationID.utf8.count <= 128,
              operationID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
              ConduitPortableOfflineAuthority.validHash(nonce),
              ConduitPortableOfflineAuthority.validHash(manifestSHA256),
              ConduitPortableOfflineAuthority.validHash(nativeTicketSHA256),
              !expectedCases.isEmpty, expectedCases.count <= 64, expectedCases.contains("permitted-check"),
              Set(expectedCases).count == expectedCases.count,
              expectedCases.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
              issuedAtUnixSeconds.isFinite, expiresAtUnixSeconds.isFinite,
              issuedAtUnixSeconds > 0, issuedAtUnixSeconds <= now.timeIntervalSince1970 + 1,
              expiresAtUnixSeconds > issuedAtUnixSeconds,
              expiresAtUnixSeconds - issuedAtUnixSeconds <= 300 else {
            throw ConduitOfflineFailure("portable_binding_invalid")
        }
        guard now.timeIntervalSince1970 < expiresAtUnixSeconds else {
            throw ConduitOfflineFailure("portable_grant_expired")
        }
        guard currentInputs else { return }
        guard try ConduitPortableDirectory.observe(fixtureRoot.path, privateDirectory: true) == fixtureRoot,
              try ConduitPortableDirectory.observe(projectRoot.path, privateDirectory: true) == projectRoot,
              projectRoot.path == fixtureRoot.path + "/staged-project" else {
            throw ConduitOfflineFailure("portable_root_changed")
        }
        if let slot {
            guard try ConduitPortableDirectory.observe(slot.path, privateDirectory: true) == slot,
                  slot.path == URL(fileURLWithPath: fixtureRoot.path).deletingLastPathComponent().appendingPathComponent("guest-slot").path else {
                throw ConduitOfflineFailure("portable_slot_changed")
            }
        }
        for (asset, name) in [(nativeExecutable, "VMRunner"), (kernel, "kernel"), (initramfs, "initrd.cpio.gz")] {
            guard asset.path == fixtureRoot.path + "/" + name else { throw ConduitOfflineFailure("portable_asset_scope") }
            try ConduitPortableOfflineAuthority.verify(asset)
        }
        try ConduitPortableOfflineAuthority.verify(supervisor)
        try ConduitPortableOfflineAuthority.verifyExecutable(nativeExecutable)
        try ConduitPortableOfflineAuthority.verifyExecutable(supervisor)
        guard try ConduitOfflineWorkspace.manifest(stagedRoot: URL(fileURLWithPath: projectRoot.path)).sha256 == manifestSHA256,
              try ConduitOfflineFS.asset(at: projectRoot.path + "/scripts/test.sh", maximumBytes: 65_536).sha256 == profile.scriptSHA256 else {
            throw ConduitOfflineFailure("portable_input_changed")
        }
        let ticket = try ConduitOfflineFS.readAbsolute(fixtureRoot.path + "/native-ticket.json", maximumBytes: 16_384)
        guard ConduitPortableOfflineAuthority.digest(ticket) == nativeTicketSHA256,
              let fields = try JSONSerialization.jsonObject(with: ticket) as? [String: String],
              fields["nonce"] == nonce, fields["operation"] == "linux-suite",
              fields["kernel_sha256"] == kernel.sha256, fields["initrd_sha256"] == initramfs.sha256 else {
            throw ConduitOfflineFailure("portable_native_ticket_changed")
        }
        if let slot {
            let facts = slot.identity.split(separator: ":").map(String.init)
            guard facts.count == 2, fields["slot_device"] == facts[0], fields["slot_inode"] == facts[1],
                  fields["fixture_operation_id"] == operationID else { throw ConduitOfflineFailure("portable_native_slot_mismatch") }
        } else {
            guard fields["slot_device"] == nil, fields["slot_inode"] == nil,
                  (fields["fixture_operation_id"] ?? "portable-check") == operationID else {
                throw ConduitOfflineFailure("portable_native_operation_mismatch")
            }
        }
        guard try ConduitOfflineFS.readAbsolute(fixtureRoot.path + "/launch.claim", maximumBytes: 128) == Data(nonce.utf8) else {
            throw ConduitOfflineFailure("portable_preparation_not_admitted")
        }
    }
}

/// Internal, opaque and non-Codable. Request JSON cannot construct this authority.
internal final class ConduitPortableOfflineGrant {
    fileprivate let body: ConduitPortableOfflineAuthority.GrantBody
    fileprivate let permit: Data
    var grantID: String { body.grantID }
    var binding: ConduitPortableOfflineBinding { body.binding }
    var launcher: ConduitOfflineAsset { body.launcher }
    var encodedPermit: Data { permit }
    fileprivate init(body: ConduitPortableOfflineAuthority.GrantBody, permit: Data) {
        self.body = body; self.permit = permit
    }
}

/// Development issuer only. Its per-fixture key is supplied by the trusted build
/// owner through private compiled pins, never settings, caller JSON or environment.
/// The trusted same-user host is outside the payload isolation threat model.
internal final class ConduitPortableOfflineAuthority {
    fileprivate struct GrantBody: Codable, Equatable {
        let schema: String
        let issuerID: String
        let grantID: String
        let binding: ConduitPortableOfflineBinding
        let launcher: ConduitOfflineAsset
    }
    private struct Wire: Codable { let payload: Data; let mac: Data }
    private struct GuestBody: Codable {
        let schema: String
        let grantID: String
        let permitSHA256: String
        let binding: ConduitPortableOfflineBinding
        let result: ConduitPortableGuestResult
    }
    private let key: SymmetricKey
    private let issuerID: String

    init(fixtureKey: Data) throws {
        guard fixtureKey.count == 32 else { throw ConduitOfflineFailure("portable_issuer_key_invalid") }
        key = SymmetricKey(data: fixtureKey)
        issuerID = Self.digest(fixtureKey)
    }

    func issue(binding: ConduitPortableOfflineBinding, launcher: ConduitOfflineAsset, now: Date = Date()) throws -> ConduitPortableOfflineGrant {
        try binding.validate(now: now)
        guard launcher.path == binding.fixtureRoot.path + "/native-offline-worker" else { throw ConduitOfflineFailure("portable_launcher_scope") }
        try Self.verify(launcher)
        try Self.verifyExecutable(launcher)
        let body = GrantBody(schema: "conduit-portable-grant/v1", issuerID: issuerID,
                             grantID: UUID().uuidString.lowercased(), binding: binding, launcher: launcher)
        return ConduitPortableOfflineGrant(body: body, permit: try seal(body, kind: "grant"))
    }

    /// Pure admission before store/write-hook/claim/launch effects.
    func authorize(_ binding: ConduitPortableOfflineBinding, grant: ConduitPortableOfflineGrant?, now: Date = Date()) throws -> ConduitPortableOfflineGrant {
        guard let grant else { throw ConduitOfflineFailure("portable_execution_authority_unavailable") }
        let decoded: GrantBody = try open(grant.permit, kind: "grant")
        guard decoded == grant.body, decoded.issuerID == issuerID, decoded.binding == binding else {
            throw ConduitOfflineFailure("portable_grant_mismatch")
        }
        try binding.validate(now: now)
        try Self.verify(decoded.launcher)
        try Self.verifyExecutable(decoded.launcher)
        return grant
    }

    /// Native R independently authenticates the issued permit and rechecks its
    /// compiled scope and own executable before creating its one-use claim.
    func redeem(_ encoded: Data, expected: ConduitPortableOfflineBinding, launcherPath: String, now: Date = Date()) throws -> ConduitPortableOfflineGrant {
        let body: GrantBody = try open(encoded, kind: "grant")
        guard body.schema == "conduit-portable-grant/v1", body.issuerID == issuerID,
              body.binding == expected, body.launcher.path == expected.fixtureRoot.path + "/native-offline-worker",
              body.launcher.path == launcherPath else { throw ConduitOfflineFailure("portable_grant_mismatch") }
        try expected.validate(now: now)
        try Self.verify(body.launcher)
        try Self.verifyExecutable(body.launcher)
        return ConduitPortableOfflineGrant(body: body, permit: encoded)
    }

    func encodeGuestResult(_ result: ConduitPortableGuestResult, grant: ConduitPortableOfflineGrant) throws -> Data {
        guard result.nonce == grant.binding.nonce, result.mode == grant.binding.mode else { throw ConduitOfflineFailure("portable_guest_identity_mismatch") }
        return try seal(GuestBody(schema: "conduit-portable-guest-receipt/v1", grantID: grant.grantID,
                                  permitSHA256: Self.digest(grant.permit), binding: grant.binding, result: result), kind: "guest-result")
    }

    func decodeGuestResult(_ data: Data, grant: ConduitPortableOfflineGrant) throws -> ConduitPortableGuestResult {
        let body: GuestBody = try open(data, kind: "guest-result", maximumBytes: 65_536)
        guard body.schema == "conduit-portable-guest-receipt/v1", body.grantID == grant.grantID,
              body.permitSHA256 == Self.digest(grant.permit), body.binding == grant.binding,
              body.result.nonce == grant.binding.nonce, body.result.mode == grant.binding.mode else {
            throw ConduitOfflineFailure("portable_guest_identity_mismatch")
        }
        return body.result
    }

    private func seal<T: Encodable>(_ body: T, kind: String) throws -> Data {
        let payload = try Self.encode(body)
        let message = Data((kind + "\0").utf8) + payload
        let mac = Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
        let encoded = try Self.encode(Wire(payload: payload, mac: mac))
        guard encoded.count <= (kind == "grant" ? 16_384 : 65_536) else { throw ConduitOfflineFailure("portable_record_byte_limit") }
        return encoded
    }

    private func open<T: Decodable>(_ encoded: Data, kind: String, maximumBytes: Int = 16_384) throws -> T {
        guard !encoded.isEmpty, encoded.count <= maximumBytes,
              let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              Set(object.keys) == Set(["payload", "mac"]) else { throw ConduitOfflineFailure("portable_record_invalid") }
        let wire = try JSONDecoder().decode(Wire.self, from: encoded)
        guard wire.mac.count == 32,
              HMAC<SHA256>.isValidAuthenticationCode(wire.mac, authenticating: Data((kind + "\0").utf8) + wire.payload, using: key) else {
            throw ConduitOfflineFailure("portable_record_authentication_failed")
        }
        return try JSONDecoder().decode(T.self, from: wire.payload)
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func validHash(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    static func verify(_ asset: ConduitOfflineAsset) throws {
        guard validHash(asset.sha256), asset.byteCount > 0, asset.byteCount <= 67_108_864,
              try ConduitOfflineFS.asset(at: asset.path, maximumBytes: 67_108_864) == asset else {
            throw ConduitOfflineFailure("portable_asset_changed")
        }
    }
    static func verifyExecutable(_ asset: ConduitOfflineAsset) throws {
        let fd = try ConduitOfflineFS.openAbsolute(asset.path, directory: false); defer { close(fd) }
        guard try ConduitOfflineFS.info(fd).st_mode & 0o111 != 0 else { throw ConduitOfflineFailure("portable_executable_unavailable") }
    }
    static func read(_ path: String, maximumBytes: Int) throws -> Data {
        try ConduitOfflineFS.readAbsolute(path, maximumBytes: maximumBytes)
    }
    static func persist(_ data: Data, name: String, root: ConduitPortableDirectory) throws {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { throw ConduitOfflineFailure("portable_record_name") }
        guard try ConduitPortableDirectory.observe(root.path, privateDirectory: true) == root else { throw ConduitOfflineFailure("portable_root_changed") }
        let fd = try ConduitOfflineFS.openAbsolute(root.path, directory: true); defer { close(fd) }
        try ConduitOfflineFS.writeExclusive(parent: fd, name: name, data: data, mode: 0o600)
        guard fsync(fd) == 0 else { throw ConduitOfflineFailure("portable_record_durability_unknown") }
    }
}

/// The existing command service still owns host lifecycle and idempotency.
/// This internal adapter selects exactly one issued native launcher; it does
/// not add an execution-capable public constructor or grant loader.
internal final class ConduitPortableOfflineLauncher {
    private let service: ConduitDirectCommandService
    private let authority: ConduitPortableOfflineAuthority
    init(service: ConduitDirectCommandService, authority: ConduitPortableOfflineAuthority) {
        self.service = service; self.authority = authority
    }

    func request(for grant: ConduitPortableOfflineGrant) -> ConduitDirectCommandRequest {
        ConduitDirectCommandRequest(operationID: grant.binding.operationID, projectSlug: "fixture",
                                    argv: [grant.launcher.path], timeoutMS: grant.binding.profile.hostDeadlineMS,
                                    maxOutputBytes: grant.binding.profile.maximumStreamBytes)
    }

    func submit(_ binding: ConduitPortableOfflineBinding, grant: ConduitPortableOfflineGrant?,
                now: Date = Date(), admitWrite: (() throws -> Void)? = nil) throws -> ConduitDirectCommandReceipt {
        let admitted = try authority.authorize(binding, grant: grant, now: now)
        return try service.submit(request(for: admitted), projectRoot: URL(fileURLWithPath: binding.projectRoot.path), admitWrite: admitWrite)
    }

    func bind(_ host: ConduitDirectCommandReceipt, guestData: Data, grant: ConduitPortableOfflineGrant) throws -> ConduitPortableOfflineResult {
        let guest = try authority.decodeGuestResult(guestData, grant: grant)
        guard host.request == request(for: grant), host.resolvedProjectRoot == grant.binding.projectRoot.path,
              host.projectRootIdentity == grant.binding.projectRoot.identity,
              host.supervision?.helperIdentity == grant.binding.supervisor.sha256,
              host.processGroupID == guest.nativeProcessGroupID,
              host.phase.isTerminal, host.stdout.reachedEOF, host.stderr.reachedEOF,
              !host.stdout.truncated, !host.stderr.truncated,
              host.stdout.bytes == guest.stdout, host.stderr.bytes == guest.stderr,
              host.directChildExitObserved, host.processGroupAbsentObserved, host.executionCapacityReleased else {
            throw ConduitOfflineFailure("portable_host_guest_mismatch")
        }
        if grant.binding.mode == "complete" {
            guard guest.guestStop == "observed", host.exitCode == guest.checkExitCode,
                  host.phase == (guest.checkExitCode == 0 ? .exited : .nonzero), host.terminationSignal == nil else {
                throw ConduitOfflineFailure("portable_host_completion_mismatch")
            }
        } else {
            guard host.phase == .timedOut, host.exitCode == nil, host.terminationSignal == SIGTERM,
                  host.supervision?.cleanupCause == 2 else { throw ConduitOfflineFailure("portable_host_timeout_mismatch") }
        }
        return ConduitPortableOfflineResult(schemaVersion: "conduit-portable-result/v1", profileID: grant.binding.profile.profileID,
                                            operationID: grant.binding.operationID, grantID: grant.grantID,
                                            permitSHA256: ConduitPortableOfflineAuthority.digest(grant.encodedPermit), host: host, guest: guest)
    }
}

public struct ConduitPortableOfflineResult: Codable {
    public let schemaVersion: String
    public let profileID: String
    public let operationID: String
    public let grantID: String
    public let permitSHA256: String
    public let host: ConduitDirectCommandReceipt
    public let guest: ConduitPortableGuestResult
}
