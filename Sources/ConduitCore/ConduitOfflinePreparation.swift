import Foundation
import Darwin

/// Observed restore metadata, not a downloaded/verified image or a grant.
public struct ConduitOfflineRestoreObservation: Codable, Equatable, Sendable {
    public let version: String
    public let build: String
    public let sourceURL: String
    public let byteCount: UInt64?
    public let minimumCPUCount: Int
    public let minimumMemoryBytes: UInt64
    public let hardwareModelSHA256: String
    public let localImageSHA256: String?

    public init(version: String, build: String, sourceURL: String, byteCount: UInt64?,
                minimumCPUCount: Int, minimumMemoryBytes: UInt64, hardwareModelSHA256: String,
                localImageSHA256: String? = nil) {
        self.version = version; self.build = build; self.sourceURL = sourceURL; self.byteCount = byteCount
        self.minimumCPUCount = minimumCPUCount; self.minimumMemoryBytes = minimumMemoryBytes
        self.hardwareModelSHA256 = hardwareModelSHA256
        self.localImageSHA256 = localImageSHA256
    }
}

public struct ConduitOfflinePreparationReport: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let profileID: String
    public let storageDirectory: String
    public let storageIdentity: String
    public let availableBytes: UInt64
    public let minimumRequiredBytes: UInt64
    public let requiredBytes: UInt64?
    public let restore: ConduitOfflineRestoreObservation?
    public let capacitySufficient: Bool
    public let restoreFitsProfile: Bool
    public let blockers: [String]
    public let imageAllocationAdmitted: Bool
    public let executionAdmitted: Bool
    public let bootDiskBytes: UInt64
    public let exchangeDiskBytes: UInt64
    public let offlinePayloadBudgetBytes: UInt64
    public let hostReserveBytes: UInt64
}

/// Preparation policy only. Free space is an observation, never a reservation.
/// The proposed disk budget includes the full image ceiling, not sparse usage.
public enum ConduitOfflinePreparation {
    public static let bootDiskBytes: UInt64 = 64 * 1024 * 1024 * 1024
    public static let exchangeDiskBytes: UInt64 = 256 * 1024 * 1024
    public static let offlinePayloadBudgetBytes: UInt64 = 8 * 1024 * 1024 * 1024
    public static let hostReserveBytes: UInt64 = 8 * 1024 * 1024 * 1024
    public static let maximumRestoreBytes: UInt64 = 32 * 1024 * 1024 * 1024
    public static let minimumRequiredBytes = bootDiskBytes + exchangeDiskBytes + offlinePayloadBudgetBytes + hostReserveBytes

    public static func restoreFileIdentity(at url: URL) throws -> ConduitOfflineAsset {
        try ConduitOfflineFS.asset(at: url.path, maximumBytes: maximumRestoreBytes)
    }

    public static func readSampleInput(atPath path: String) throws -> Data {
        try ConduitOfflineFS.readAbsolute(path, maximumBytes: 262_144)
    }

    public static func validatePacketDestination(_ destination: URL) throws {
        let (parent, _) = try packetParent(destination)
        close(parent)
    }

    private static func packetParent(_ destination: URL) throws -> (Int32, String) {
        let parts = try ConduitOfflineFS.absoluteComponents(destination.path)
        guard let name = parts.last, !name.hasPrefix(".") else { throw ConduitOfflineFailure("invalid_packet_path") }
        let parent = try ConduitOfflineFS.openAbsolute("/" + parts.dropLast().joined(separator: "/"), directory: true)
        do {
            let facts = try ConduitOfflineFS.info(parent)
            guard facts.st_uid == geteuid(), facts.st_mode & 0o022 == 0 else {
                throw ConduitOfflineFailure("owned_unshared_storage_required")
            }
            var existing = stat()
            guard fstatat(parent, name, &existing, AT_SYMLINK_NOFOLLOW) == -1, errno == ENOENT else {
                throw ConduitOfflineFailure("packet_must_be_absent")
            }
            return (parent, name)
        } catch { close(parent); throw error }
    }

    public static func observe(storageDirectory: URL, restore: ConduitOfflineRestoreObservation?) throws -> ConduitOfflinePreparationReport {
        let fd = try ConduitOfflineFS.openAbsolute(storageDirectory.path, directory: true)
        defer { close(fd) }
        let facts = try ConduitOfflineFS.info(fd)
        guard facts.st_uid == geteuid(), facts.st_mode & 0o022 == 0 else {
            throw ConduitOfflineFailure("owned_unshared_storage_required")
        }
        var filesystem = statfs()
        guard fstatfs(fd, &filesystem) == 0 else { throw ConduitOfflineFailure("storage_capacity_unknown") }
        let (available, overflow) = UInt64(filesystem.f_bavail).multipliedReportingOverflow(by: UInt64(filesystem.f_bsize))
        guard !overflow else { throw ConduitOfflineFailure("storage_capacity_unknown") }
        return try evaluate(storageDirectory: storageDirectory.path,
                            storageIdentity: ConduitOfflineFS.identity(fd), availableBytes: available, restore: restore)
    }

    /// Deterministic budget logic; supplied observations do not authorize effects.
    public static func evaluate(storageDirectory: String, storageIdentity: String,
                                availableBytes: UInt64, restore: ConduitOfflineRestoreObservation?) throws -> ConduitOfflinePreparationReport {
        var blockers: [String] = []
        var required: UInt64?
        var fits = false
        if let restore {
            guard !restore.version.isEmpty, restore.version.utf8.count <= 128,
                  !restore.build.isEmpty, restore.build.utf8.count <= 128,
                  ConduitOfflinePreflight.validHash(restore.hardwareModelSHA256),
                  restore.localImageSHA256.map(ConduitOfflinePreflight.validHash) ?? true,
                  restore.minimumCPUCount > 0, restore.minimumMemoryBytes > 0,
                  let url = URL(string: restore.sourceURL), url.isFileURL || allowedAppleURL(url) else {
                throw ConduitOfflineFailure("invalid_restore_observation")
            }
            fits = restore.minimumCPUCount <= ConduitOfflineProfile.v1.cpuCount &&
                restore.minimumMemoryBytes <= ConduitOfflineProfile.v1.memoryBytes
            if !fits { blockers.append("restore_exceeds_fixed_cpu_or_memory_profile") }
            if let bytes = restore.byteCount, bytes > 0, bytes <= maximumRestoreBytes {
                required = bytes + minimumRequiredBytes
            } else { blockers.append("restore_size_unknown_or_over_budget") }
        } else { blockers.append("restore_metadata_unavailable") }
        let sufficient = required.map { availableBytes >= $0 } ?? false
        if availableBytes < (required ?? minimumRequiredBytes) { blockers.append("insufficient_storage_capacity") }
        blockers += ["storage_not_reserved", "guest_assets_not_prepared", "offline_toolchain_not_packaged",
                     "execution_authority_unavailable"]
        return .init(schemaVersion: "conduit-offline-preparation/v1", profileID: ConduitOfflineProfile.v1.profileID,
                     storageDirectory: storageDirectory, storageIdentity: storageIdentity,
                     availableBytes: availableBytes, minimumRequiredBytes: minimumRequiredBytes,
                     requiredBytes: required, restore: restore,
                     capacitySufficient: sufficient, restoreFitsProfile: fits, blockers: blockers,
                     imageAllocationAdmitted: false, executionAdmitted: false,
                     bootDiskBytes: bootDiskBytes, exchangeDiskBytes: exchangeDiskBytes,
                     offlinePayloadBudgetBytes: offlinePayloadBudgetBytes, hostReserveBytes: hostReserveBytes)
    }

    public static func allowedAppleURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              let host = url.host?.lowercased() else { return false }
        return host == "apple.com" || host.hasSuffix(".apple.com") ||
            host == "cdn-apple.com" || host.hasSuffix(".cdn-apple.com")
    }

    /// Small actual platform metadata only, including when image capacity fails.
    /// No image, auxiliary storage, ledger, grant or VM object is created here.
    public static func writePacket(report: ConduitOfflinePreparationReport, hardwareModel: Data,
                                   machineIdentifier: Data, destination: URL) throws -> [String: String] {
        guard let restore = report.restore, hardwareModel.count <= 1_048_576, !hardwareModel.isEmpty,
              !machineIdentifier.isEmpty, machineIdentifier.count <= 1_048_576,
              ConduitOfflineHash.bytes(hardwareModel) == restore.hardwareModelSHA256,
              !report.executionAdmitted, !report.imageAllocationAdmitted else {
            throw ConduitOfflineFailure("invalid_platform_packet")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let files = ["PREPARATION.json": try encoder.encode(report), "hardware-model.bin": hardwareModel,
                     "machine-identifier.bin": machineIdentifier]
        guard files.values.allSatisfy({ $0.count <= 1_048_576 }) else {
            throw ConduitOfflineFailure("packet_byte_limit")
        }
        let (parent, name) = try packetParent(destination)
        defer { close(parent) }
        guard mkdirat(parent, name, 0o700) == 0 else { throw ConduitOfflineFailure("packet_must_be_absent") }
        let output = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard output >= 0 else { throw ConduitOfflineFailure("packet_directory_unavailable") }
        defer { close(output) }
        for name in files.keys.sorted() {
            try ConduitOfflineFS.writeExclusive(parent: output, name: name, data: files[name]!, mode: 0o600)
        }
        guard fsync(output) == 0, fsync(parent) == 0 else { throw ConduitOfflineFailure("packet_durability_unknown") }
        var hashes: [String: String] = [:]
        for (name, expected) in files {
            let fd = try ConduitOfflineFS.openRelative(root: output, path: name, directory: false)
            defer { close(fd) }
            let actual = try ConduitOfflineFS.read(fd, maximumBytes: 1_048_576)
            guard actual == expected else { throw ConduitOfflineFailure("packet_readback_mismatch") }
            hashes[name] = ConduitOfflineHash.bytes(actual)
        }
        return hashes
    }
}
