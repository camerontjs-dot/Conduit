import Foundation
import XCTest
import Darwin
@testable import ConduitCore

final class ConduitOfflinePreparationTests: XCTestCase {
    // Synthetic metadata exercises budget policy, never native compatibility.
    private func observation(bytes: UInt64? = 1024, cpus: Int = 2,
                             memory: UInt64 = 4 * 1024 * 1024 * 1024,
                             url: String = "https://updates.cdn-apple.com/fixture.ipsw") -> ConduitOfflineRestoreObservation {
        .init(version: "synthetic", build: "unit-fixture", sourceURL: url, byteCount: bytes,
              minimumCPUCount: cpus, minimumMemoryBytes: memory,
              hardwareModelSHA256: ConduitOfflineHash.bytes(Data("synthetic hardware".utf8)))
    }

    private func report(_ restore: ConduitOfflineRestoreObservation?, available: UInt64 = UInt64.max) throws -> ConduitOfflinePreparationReport {
        try ConduitOfflinePreparation.evaluate(storageDirectory: "/synthetic-storage", storageIdentity: "synthetic",
                                              availableBytes: available, restore: restore)
    }

    private func fixture(_ body: (URL) throws -> Void) throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("conduit-preparation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard let resolved = realpath(path.path, nil) else { throw ConduitOfflineFailure("fixture_unavailable") }
        let base = URL(fileURLWithPath: String(cString: resolved)); free(resolved)
        defer { ConduitOfflineFixtureEvidence.preserveAndClean(base, test: name) }
        try body(base)
    }

    func testCapacityAndCompatibleSyntheticMetadataNeverAdmitAllocationOrExecution() throws {
        let result = try report(observation())
        XCTAssertEqual(result.requiredBytes, ConduitOfflinePreparation.minimumRequiredBytes + 1024)
        XCTAssertTrue(result.capacitySufficient)
        XCTAssertTrue(result.restoreFitsProfile)
        XCTAssertFalse(result.imageAllocationAdmitted)
        XCTAssertFalse(result.executionAdmitted)
        for code in ["storage_not_reserved", "guest_assets_not_prepared", "offline_toolchain_not_packaged", "execution_authority_unavailable"] {
            XCTAssertTrue(result.blockers.contains(code), code)
        }
        let data = try JSONEncoder().encode(result)
        XCTAssertEqual(try JSONDecoder().decode(ConduitOfflinePreparationReport.self, from: data), result)
    }

    func testMissingAndOverBudgetRestoreCannotCreateCapacitySuccess() throws {
        let missing = try report(nil, available: 1024)
        XCTAssertNil(missing.requiredBytes)
        XCTAssertFalse(missing.capacitySufficient)
        XCTAssertTrue(missing.blockers.contains("restore_metadata_unavailable"))
        XCTAssertTrue(missing.blockers.contains("insufficient_storage_capacity"))
        for size: UInt64? in [nil, 0, ConduitOfflinePreparation.maximumRestoreBytes + 1, UInt64.max] {
            let result = try report(observation(bytes: size))
            XCTAssertNil(result.requiredBytes)
            XCTAssertFalse(result.capacitySufficient)
            XCTAssertTrue(result.blockers.contains("restore_size_unknown_or_over_budget"))
        }
        let required = try XCTUnwrap(report(observation()).requiredBytes)
        XCTAssertFalse(try report(observation(), available: required - 1).capacitySufficient)
        XCTAssertTrue(try report(observation(), available: required).capacitySufficient)
    }

    func testFixedCPUAndMemoryAreNotSilentlyIncreasedForRestore() throws {
        for metadata in [observation(cpus: 3), observation(memory: 4 * 1024 * 1024 * 1024 + 1)] {
            let result = try report(metadata)
            XCTAssertFalse(result.restoreFitsProfile)
            XCTAssertTrue(result.blockers.contains("restore_exceeds_fixed_cpu_or_memory_profile"))
            XCTAssertFalse(result.executionAdmitted)
        }
        XCTAssertThrowsError(try report(observation(cpus: 0)))
        XCTAssertThrowsError(try report(observation(memory: 0)))
    }

    func testAppleMetadataOriginsRejectSpoofsCredentialsPortsAndOtherSchemes() throws {
        for value in ["http://apple.com/file", "https://apple.com.attacker.test/file", "https://attacker.test/apple.com",
                      "https://user@apple.com/file", "https://apple.com:443/file", "ftp://apple.com/file"] {
            XCTAssertFalse(ConduitOfflinePreparation.allowedAppleURL(try XCTUnwrap(URL(string: value))), value)
            XCTAssertThrowsError(try report(observation(url: value)), value)
        }
        for value in ["https://apple.com/file", "https://updates.cdn-apple.com/file", "https://updates.apple.com/file"] {
            XCTAssertTrue(ConduitOfflinePreparation.allowedAppleURL(try XCTUnwrap(URL(string: value))))
        }
    }

    func testActualStorageObservationIsReadOnlyAndRejectsSharedOrLinkedDirectory() throws {
        try fixture { base in
            let sentinel = base.appendingPathComponent("sentinel")
            let bytes = Data("unchanged".utf8); try bytes.write(to: sentinel)
            let result = try ConduitOfflinePreparation.observe(storageDirectory: base, restore: nil)
            XCTAssertFalse(result.executionAdmitted)
            XCTAssertFalse(result.imageAllocationAdmitted)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: base.path), ["sentinel"])
            XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
            let link = base.appendingPathComponent("linked")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: base)
            XCTAssertThrowsError(try ConduitOfflinePreparation.observe(storageDirectory: link, restore: nil))
            XCTAssertEqual(chmod(base.path, 0o777), 0)
            defer { _ = chmod(base.path, 0o700) }
            XCTAssertThrowsError(try ConduitOfflinePreparation.observe(storageDirectory: base, restore: nil))
        }
    }

    func testPacketUsesExclusivePrivateFilesAndCannotReplaceExistingEvidence() throws {
        try fixture { base in
            let destination = base.appendingPathComponent("packet")
            let hardware = Data("synthetic hardware".utf8), machine = Data("synthetic identifier".utf8)
            let metadata = try report(observation())
            let hashes = try ConduitOfflinePreparation.writePacket(report: metadata, hardwareModel: hardware,
                machineIdentifier: machine, destination: destination)
            XCTAssertEqual(Set(hashes.keys), ["PREPARATION.json", "hardware-model.bin", "machine-identifier.bin"])
            for (name, hash) in hashes {
                let url = destination.appendingPathComponent(name)
                XCTAssertEqual(try ConduitOfflineHash.bytes(Data(contentsOf: url)), hash)
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            }
            XCTAssertThrowsError(try ConduitOfflinePreparation.writePacket(report: metadata, hardwareModel: hardware,
                machineIdentifier: Data("replacement".utf8), destination: destination))
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("machine-identifier.bin")), machine)
            XCTAssertThrowsError(try ConduitOfflinePreparation.writePacket(report: metadata, hardwareModel: Data("wrong".utf8),
                machineIdentifier: machine, destination: base.appendingPathComponent("invalid")))
            XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("invalid").path))
            let oversized = try ConduitOfflinePreparation.evaluate(storageDirectory: String(repeating: "x", count: 1_048_577),
                storageIdentity: "synthetic", availableBytes: UInt64.max, restore: observation())
            XCTAssertThrowsError(try ConduitOfflinePreparation.writePacket(report: oversized, hardwareModel: hardware,
                machineIdentifier: machine, destination: base.appendingPathComponent("oversized"))) {
                XCTAssertEqual(($0 as? ConduitOfflineFailure)?.code, "packet_byte_limit")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("oversized").path))
            let link = base.appendingPathComponent("linked")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: base)
            XCTAssertThrowsError(try ConduitOfflinePreparation.writePacket(report: metadata, hardwareModel: hardware,
                machineIdentifier: machine, destination: link.appendingPathComponent("escape")))
            XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("escape").path))
        }
    }

    func testRestoreIdentityHashesOwnedBytesAndRefusesHardlinksSymlinksAndOversizedImage() throws {
        try fixture { base in
            let url = base.appendingPathComponent("invalid.ipsw"), bytes = Data("not an IPSW".utf8)
            try bytes.write(to: url)
            let actual = try ConduitOfflinePreparation.restoreFileIdentity(at: url)
            XCTAssertEqual(actual.sha256, ConduitOfflineHash.bytes(bytes))
            XCTAssertEqual(actual.byteCount, UInt64(bytes.count))
            let link = base.appendingPathComponent("linked.ipsw")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
            XCTAssertThrowsError(try ConduitOfflinePreparation.restoreFileIdentity(at: link))
            let hardlink = base.appendingPathComponent("hardlink.ipsw")
            try FileManager.default.linkItem(at: url, to: hardlink)
            XCTAssertThrowsError(try ConduitOfflinePreparation.restoreFileIdentity(at: url))
            try FileManager.default.removeItem(at: hardlink)
            let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
            try handle.truncate(atOffset: ConduitOfflinePreparation.maximumRestoreBytes + 1)
            XCTAssertThrowsError(try ConduitOfflinePreparation.restoreFileIdentity(at: url)) {
                XCTAssertEqual(($0 as? ConduitOfflineFailure)?.code, "asset_byte_limit")
            }
            // Restore a small fixture before evidence retention; no disk payload was allocated.
            try handle.truncate(atOffset: UInt64(bytes.count))
        }
    }

    func testRequestInputRejectsActualOversizeAndAliasesBeforeReading() throws {
        try fixture { base in
            let input = base.appendingPathComponent("input.json")
            try Data(repeating: 0, count: 262_145).write(to: input)
            XCTAssertThrowsError(try ConduitOfflinePreparation.readSampleInput(atPath: input.path)) {
                XCTAssertEqual(($0 as? ConduitOfflineFailure)?.code, "file_byte_limit")
            }
            try Data("{}".utf8).write(to: input)
            XCTAssertEqual(try ConduitOfflinePreparation.readSampleInput(atPath: input.path), Data("{}".utf8))
            let link = base.appendingPathComponent("link.json")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: input)
            XCTAssertThrowsError(try ConduitOfflinePreparation.readSampleInput(atPath: link.path))
            XCTAssertThrowsError(try ConduitOfflinePreparation.readSampleInput(atPath: base.path + "/../input.json"))
            let existing = base.appendingPathComponent("existing")
            try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
            XCTAssertThrowsError(try ConduitOfflinePreparation.validatePacketDestination(existing))
            XCTAssertNoThrow(try ConduitOfflinePreparation.validatePacketDestination(base.appendingPathComponent("new")))
            XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("new").path))
        }
    }
}
