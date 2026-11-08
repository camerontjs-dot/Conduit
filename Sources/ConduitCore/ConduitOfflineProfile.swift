import Foundation
import CryptoKit

/// A source-only preparation profile. This value cannot grant execution.
public struct ConduitOfflineProfile: Equatable, Sendable {
    public static let v1 = ConduitOfflineProfile()
    public let profileID = "conduit-offline-project/v1"
    public let checkID = "conduit-test-v1"
    public let argv = ["/bin/bash", "/work/project/scripts/test.sh", "--jobs", "2"]
    public let cpuCount = 2
    public let memoryBytes: UInt64 = 4 * 1024 * 1024 * 1024
    public let deadlineSeconds = 600
    public let maximumStreamBytes = 1_048_576
    public let maximumArtifactBytes = 8_388_608
    private init() {}
}

public struct ConduitOfflineFailure: Error, LocalizedError, Equatable {
    public let code: String
    public init(_ code: String) { self.code = code }
    public var errorDescription: String? { code }
}

public struct ConduitOfflineAsset: Codable, Equatable, Sendable {
    public let path: String
    public let sha256: String
    public let byteCount: UInt64
    public init(path: String, sha256: String, byteCount: UInt64) {
        self.path = path; self.sha256 = sha256; self.byteCount = byteCount
    }
}

/// These fields describe supplied assets, not attestation or a local grant.
public struct ConduitOfflineAssets: Codable, Equatable, Sendable {
    public var bootDisk: ConduitOfflineAsset?
    public var auxiliaryStorage: ConduitOfflineAsset?
    public var hardwareModel: ConduitOfflineAsset?
    public var machineIdentifier: ConduitOfflineAsset?
    public var exchangeDisk: ConduitOfflineAsset?
    public var toolchainInventory: ConduitOfflineAsset?
    public var dependencyInventory: ConduitOfflineAsset?
    public var guestWorker: ConduitOfflineAsset?
    public var preparedGuestIdentity: String?
    public var standardWorkerUID: UInt32?
    public var exchangeDetached: Bool
    public var ownerKnown: Bool
    public var previousOperationClaim: String?

    public init(bootDisk: ConduitOfflineAsset? = nil, auxiliaryStorage: ConduitOfflineAsset? = nil,
                hardwareModel: ConduitOfflineAsset? = nil, machineIdentifier: ConduitOfflineAsset? = nil,
                exchangeDisk: ConduitOfflineAsset? = nil, toolchainInventory: ConduitOfflineAsset? = nil,
                dependencyInventory: ConduitOfflineAsset? = nil, guestWorker: ConduitOfflineAsset? = nil,
                preparedGuestIdentity: String? = nil, standardWorkerUID: UInt32? = nil,
                exchangeDetached: Bool = false, ownerKnown: Bool = false,
                previousOperationClaim: String? = nil) {
        self.bootDisk = bootDisk; self.auxiliaryStorage = auxiliaryStorage
        self.hardwareModel = hardwareModel; self.machineIdentifier = machineIdentifier
        self.exchangeDisk = exchangeDisk; self.toolchainInventory = toolchainInventory
        self.dependencyInventory = dependencyInventory; self.guestWorker = guestWorker
        self.preparedGuestIdentity = preparedGuestIdentity; self.standardWorkerUID = standardWorkerUID
        self.exchangeDetached = exchangeDetached; self.ownerKnown = ownerKnown
        self.previousOperationClaim = previousOperationClaim
    }

    var named: [(String, ConduitOfflineAsset?)] {
        [("boot_disk", bootDisk), ("auxiliary_storage", auxiliaryStorage),
         ("hardware_model", hardwareModel), ("machine_identifier", machineIdentifier),
         ("exchange_disk", exchangeDisk), ("toolchain_inventory", toolchainInventory),
         ("dependency_inventory", dependencyInventory), ("guest_worker", guestWorker)]
    }
}

public struct ConduitOfflineRequest: Codable, Equatable, Sendable {
    public let operationID: String
    public let profileID: String
    public let stagedRoot: String
    public let expectedManifestSHA256: String
    public let assets: ConduitOfflineAssets

    public init(operationID: String, stagedRoot: String, expectedManifestSHA256: String,
                assets: ConduitOfflineAssets = ConduitOfflineAssets(),
                profileID: String = ConduitOfflineProfile.v1.profileID) {
        self.operationID = operationID; self.profileID = profileID; self.stagedRoot = stagedRoot
        self.expectedManifestSHA256 = expectedManifestSHA256; self.assets = assets
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case operationID, profileID, stagedRoot, expectedManifestSHA256, assets
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: ConduitOfflineJSONKey.self)
        guard Set(fields.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw ConduitOfflineFailure("invalid_request_fields")
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(operationID: try c.decode(String.self, forKey: .operationID),
                  stagedRoot: try c.decode(String.self, forKey: .stagedRoot),
                  expectedManifestSHA256: try c.decode(String.self, forKey: .expectedManifestSHA256),
                  assets: try c.decode(ConduitOfflineAssets.self, forKey: .assets),
                  profileID: try c.decode(String.self, forKey: .profileID))
    }
}

private struct ConduitOfflineJSONKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

public struct ConduitOfflineInventory: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let identity: String
    public let entries: [ConduitOfflineAsset]
    public init(identity: String, entries: [ConduitOfflineAsset]) {
        schemaVersion = "conduit-offline-inventory/v1"; self.identity = identity; self.entries = entries
    }
}

public struct ConduitOfflinePreflightReport: Codable, Equatable, Sendable {
    public let profileID: String
    public let operationID: String
    public let blockers: [String]
    /// Preparation readiness is not guest provisioning or launch qualification.
    public let configurationReady: Bool
    public let admitted: Bool
}

public enum ConduitOfflinePreflight {
    /// Read-only observation. It never creates a claim, grants authority or repairs assets.
    public static func observe(request: ConduitOfflineRequest) -> ConduitOfflinePreflightReport {
        let preparation = configurationBlockers(request: request)
        return ConduitOfflinePreflightReport(profileID: request.profileID, operationID: request.operationID,
            blockers: preparation + ["execution_authority_unavailable", "batch_lifecycle_unavailable", "export_unavailable"],
            configurationReady: preparation.isEmpty, admitted: false)
    }

    static func configurationBlockers(request: ConduitOfflineRequest) -> [String] {
        var blockers: [String] = []
        let profile = ConduitOfflineProfile.v1
        if request.profileID != profile.profileID { blockers.append("unsupported_profile") }
        if request.operationID.isEmpty || request.operationID.utf8.count > 128 ||
            !request.operationID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) {
            blockers.append("invalid_operation_id")
        }
        #if !os(macOS) || !arch(arm64)
        blockers.append("unsupported_host")
        #endif
        if !request.assets.ownerKnown { blockers.append("unknown_vm_owner") }
        if request.assets.previousOperationClaim != nil { blockers.append("recovery_required") }
        if !request.assets.exchangeDetached { blockers.append("exchange_not_detached") }
        if request.assets.preparedGuestIdentity?.isEmpty != false { blockers.append("prepared_guest_identity_missing") }
        if (request.assets.standardWorkerUID ?? 0) < 501 { blockers.append("standard_worker_identity_missing") }
        if !validHash(request.expectedManifestSHA256) { blockers.append("invalid_manifest_identity") }
        do {
            let manifest = try ConduitOfflineWorkspace.manifest(stagedRoot: URL(fileURLWithPath: request.stagedRoot))
            if manifest.sha256 != request.expectedManifestSHA256 { blockers.append("input_identity_changed") }
        } catch { blockers.append("staged_workspace_unavailable") }
        var paths = Set<String>()
        for (name, descriptor) in request.assets.named {
            guard let asset = descriptor else { blockers.append("asset_missing:" + name); continue }
            if !paths.insert(asset.path).inserted { blockers.append("asset_path_reused:" + name) }
            do {
                guard validHash(asset.sha256), asset.byteCount > 0 else { throw ConduitOfflineFailure("invalid_asset_identity") }
                let maximumBytes: UInt64
                switch name {
                case "boot_disk": maximumBytes = 64 * 1024 * 1024 * 1024
                case "exchange_disk": maximumBytes = 256 * 1024 * 1024
                case "auxiliary_storage": maximumBytes = 16 * 1024 * 1024
                case "guest_worker": maximumBytes = 128 * 1024 * 1024
                case "hardware_model", "machine_identifier": maximumBytes = 1024 * 1024
                default: maximumBytes = 256 * 1024
                }
                guard asset.byteCount <= maximumBytes else { throw ConduitOfflineFailure("asset_byte_limit") }
                let observed = try ConduitOfflineFS.asset(at: asset.path, maximumBytes: maximumBytes)
                guard observed == asset else { throw ConduitOfflineFailure("asset_identity_mismatch") }
                if name == "boot_disk" || name == "exchange_disk" {
                    guard asset.path.hasSuffix(".img"), asset.byteCount % 512 == 0 else { throw ConduitOfflineFailure("raw_disk_required") }
                }
                if name == "toolchain_inventory" || name == "dependency_inventory" {
                    let data = try ConduitOfflineFS.readAbsolute(asset.path, maximumBytes: 262_144)
                    let inventory = try JSONDecoder().decode(ConduitOfflineInventory.self, from: data)
                    guard inventory.schemaVersion == "conduit-offline-inventory/v1", !inventory.identity.isEmpty,
                          !inventory.entries.isEmpty, inventory.entries.count <= 2048,
                          Set(inventory.entries.map(\.path)).count == inventory.entries.count,
                          inventory.entries.allSatisfy({ (try? ConduitOfflineFS.absoluteComponents($0.path)) != nil && validHash($0.sha256) && $0.byteCount <= 2_147_483_648 }) else {
                        throw ConduitOfflineFailure("invalid_offline_inventory")
                    }
                }
            } catch let failure as ConduitOfflineFailure { blockers.append(failure.code + ":" + name) }
            catch { blockers.append("asset_unavailable:" + name) }
        }
        return blockers
    }

    static func validHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

enum ConduitOfflineHash {
    static func bytes(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func encoded<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return bytes(try encoder.encode(value))
    }
}
