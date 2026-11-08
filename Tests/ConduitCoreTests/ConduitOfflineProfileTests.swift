import Foundation
import XCTest
@testable import ConduitCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class ConduitOfflineProfileTests: XCTestCase {
    private func fixture(_ body: (URL, URL, URL) throws -> Void) throws {
        let nominated = FileManager.default.temporaryDirectory.appendingPathComponent("conduit-offline-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: nominated, withIntermediateDirectories: true)
        guard let resolved = realpath(nominated.path, nil) else { throw ConduitOfflineFailure("fixture_unavailable") }
        let base = URL(fileURLWithPath: String(cString: resolved)); free(resolved)
        defer { ConduitOfflineFixtureEvidence.preserveAndClean(base, test: name) }
        let source = base.appendingPathComponent("source")
        let stage = base.appendingPathComponent("stage")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("original\n".utf8).write(to: source.appendingPathComponent("note.txt"))
        try body(base, source, stage)
    }

    private func failure(_ expected: String, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(($0 as? ConduitOfflineFailure)?.code, expected, file: file, line: line)
        }
    }

    func testFixedProfileDoesNotOfferCallerArgvOrEnvironment() throws {
        let profile = ConduitOfflineProfile.v1
        XCTAssertEqual(profile.argv, ["/bin/bash", "/work/project/scripts/test.sh", "--jobs", "2"])
        XCTAssertEqual(profile.cpuCount, 2)
        XCTAssertEqual(profile.memoryBytes, 4 * 1024 * 1024 * 1024)
        XCTAssertEqual(profile.deadlineSeconds, 600)
        let request = ConduitOfflineRequest(operationID: "one", stagedRoot: "/absent", expectedManifestSHA256: String(repeating: "a", count: 64))
        let data = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(ConduitOfflineRequest.self, from: data), request)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["argv", "environment", "grant", "networkDevices"] {
            var injected = object; injected[key] = ["untrusted"]
            XCTAssertThrowsError(try JSONDecoder().decode(ConduitOfflineRequest.self, from: JSONSerialization.data(withJSONObject: injected)))
        }
        object["profileID"] = "caller-profile"
        let changed = try JSONDecoder().decode(ConduitOfflineRequest.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(ConduitOfflinePreflight.observe(request: changed).blockers.contains("unsupported_profile"))
    }

    func testStandaloneStageInspectSearchAndScopedEditPreserveOriginal() throws {
        try fixture { _, source, stage in
            let git = source.appendingPathComponent(".git")
            try FileManager.default.createDirectory(at: git, withIntermediateDirectories: false)
            try Data("not copied".utf8).write(to: git.appendingPathComponent("config"))
            let initial = try ConduitOfflineWorkspace.stage(sourceRoot: source, stagedRoot: stage)
            XCTAssertEqual(initial.files.map(\.path), ["note.txt"])
            XCTAssertTrue(initial.excludedNames.contains(".git"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: stage.appendingPathComponent(".git").path))
            XCTAssertEqual(try ConduitOfflineWorkspace.manifest(stagedRoot: stage), initial)
            XCTAssertEqual(try ConduitOfflineWorkspace.inspect(stagedRoot: stage, relativePath: "note.txt"), "original\n")
            XCTAssertEqual(try ConduitOfflineWorkspace.search(stagedRoot: stage, literal: "original"), ["note.txt"])
            let after = try ConduitOfflineWorkspace.replace(stagedRoot: stage, relativePath: "note.txt",
                expectedSHA256: initial.files[0].sha256, replacement: "edited\n")
            XCTAssertNotEqual(after.sha256, initial.sha256)
            XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("note.txt"), encoding: .utf8), "original\n")
            XCTAssertEqual(try ConduitOfflineWorkspace.inspect(stagedRoot: stage, relativePath: "note.txt"), "edited\n")
            failure("input_identity_changed") {
                _ = try ConduitOfflineWorkspace.replace(stagedRoot: stage, relativePath: "note.txt",
                    expectedSHA256: initial.files[0].sha256, replacement: "stale")
            }
        }
    }

    func testOriginalAndUntrustedPathsCannotBeUsedAsStage() throws {
        try fixture { _, source, stage in
            XCTAssertThrowsError(try ConduitOfflineWorkspace.inspect(stagedRoot: source, relativePath: "note.txt"))
            _ = try ConduitOfflineWorkspace.stage(sourceRoot: source, stagedRoot: stage)
            for path in ["../source/note.txt", "/etc/passwd", "a/../note.txt", "./note.txt", "a//b"] {
                XCTAssertThrowsError(try ConduitOfflineWorkspace.inspect(stagedRoot: stage, relativePath: path))
            }
            XCTAssertThrowsError(try ConduitOfflineWorkspace.replace(stagedRoot: stage, relativePath: ".git/config",
                expectedSHA256: String(repeating: "a", count: 64), replacement: "x"))
            XCTAssertThrowsError(try ConduitOfflineWorkspace.stage(sourceRoot: source, stagedRoot: source.appendingPathComponent("nested")))
            XCTAssertThrowsError(try ConduitOfflineWorkspace.stage(sourceRoot: source, stagedRoot: stage))
        }
    }

    func testPortableManifestPinsModesAndEmptyDirectoriesWithoutLocalRootIdentity() throws {
        try fixture { base, source, stage in
            try FileManager.default.createDirectory(at: source.appendingPathComponent("empty"), withIntermediateDirectories: false)
            let first = try ConduitOfflineWorkspace.stage(sourceRoot: source, stagedRoot: stage)
            let otherSource = base.appendingPathComponent("other-source")
            try FileManager.default.copyItem(at: source, to: otherSource)
            let other = try ConduitOfflineWorkspace.stage(sourceRoot: otherSource, stagedRoot: base.appendingPathComponent("other-stage"))
            XCTAssertNotEqual(first.sourceIdentity, other.sourceIdentity)
            XCTAssertEqual(first.sha256, other.sha256)
            XCTAssertEqual(first.directories, ["empty"])
            let note = stage.appendingPathComponent("note.txt")
            let prior = try FileManager.default.attributesOfItem(atPath: note.path)[.posixPermissions] as? NSNumber
            let permissions = try XCTUnwrap(prior).uint16Value
            XCTAssertEqual(chmod(note.path, mode_t(permissions ^ 0o100)), 0)
            let modeChanged = try ConduitOfflineWorkspace.manifest(stagedRoot: stage)
            XCTAssertNotEqual(modeChanged.sha256, first.sha256)
            try FileManager.default.removeItem(at: stage.appendingPathComponent("empty"))
            XCTAssertNotEqual(try ConduitOfflineWorkspace.manifest(stagedRoot: stage).sha256, modeChanged.sha256)
        }
    }

    func testGuestInputExportOmitsHostMarkerAndRestagesWithPortableIdentity() throws {
        try fixture { base, source, stage in
            let original = try ConduitOfflineWorkspace.stage(sourceRoot: source, stagedRoot: stage)
            let exchangeInput = base.appendingPathComponent("exchange-input")
            let exported = try ConduitOfflineWorkspace.exportInput(stagedRoot: stage, destination: exchangeInput)
            XCTAssertEqual(exported.sha256, original.sha256)
            XCTAssertFalse(FileManager.default.fileExists(atPath: exchangeInput.appendingPathComponent(".conduit-offline-workspace.json").path))
            let guest = try ConduitOfflineWorkspace.stage(sourceRoot: exchangeInput, stagedRoot: base.appendingPathComponent("guest-project"))
            XCTAssertEqual(guest.sha256, original.sha256)
            XCTAssertThrowsError(try ConduitOfflineWorkspace.exportInput(stagedRoot: stage, destination: exchangeInput))
            XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("note.txt")), "original\n")
        }
    }

    func testSymlinkHardlinkAndMarkerIdentityChangesRefuse() throws {
        try fixture { base, source, stage in
            let outside = base.appendingPathComponent("outside.txt")
            try Data("outside".utf8).write(to: outside)
            try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("link"), withDestinationURL: outside)
            XCTAssertThrowsError(try ConduitOfflineWorkspace.stage(sourceRoot: source, stagedRoot: stage))
            try FileManager.default.removeItem(at: source.appendingPathComponent("link"))
            let nextStage = base.appendingPathComponent("next-stage")
            _ = try ConduitOfflineWorkspace.stage(sourceRoot: source, stagedRoot: nextStage)
            try FileManager.default.linkItem(at: outside, to: nextStage.appendingPathComponent("hardlink"))
            XCTAssertThrowsError(try ConduitOfflineWorkspace.manifest(stagedRoot: nextStage))
            try FileManager.default.removeItem(at: nextStage.appendingPathComponent("hardlink"))
            let moved = base.appendingPathComponent("replacement")
            try FileManager.default.copyItem(at: nextStage, to: moved)
            failure("invalid_staged_workspace") { _ = try ConduitOfflineWorkspace.manifest(stagedRoot: moved) }
        }
    }

    func testPreflightFailsClosedForMissingAssetsChangedInputAndOldClaim() throws {
        try fixture { _, source, stage in
            let initial = try ConduitOfflineWorkspace.stage(sourceRoot: source, stagedRoot: stage)
            var assets = ConduitOfflineAssets()
            assets.previousOperationClaim = "prior-operation"
            let request = ConduitOfflineRequest(operationID: "one", stagedRoot: stage.path,
                expectedManifestSHA256: initial.sha256, assets: assets)
            let report = ConduitOfflinePreflight.observe(request: request)
            XCTAssertFalse(report.admitted)
            XCTAssertFalse(report.configurationReady)
            for blocker in ["execution_authority_unavailable", "batch_lifecycle_unavailable", "export_unavailable", "unknown_vm_owner", "recovery_required",
                            "exchange_not_detached", "asset_missing:boot_disk", "asset_missing:dependency_inventory"] {
                XCTAssertTrue(report.blockers.contains(blocker), blocker)
            }
            try Data("changed externally".utf8).write(to: stage.appendingPathComponent("note.txt"))
            XCTAssertTrue(ConduitOfflinePreflight.observe(request: request).blockers.contains("input_identity_changed"))
            // No VM object is constructed by this factory refusal.
            XCTAssertThrowsError(try ConduitOfflineVMConfiguration.make(request: request))
        }
    }

    func testAssetObservationRejectsHashChangeAndSymlinkParent() throws {
        try fixture { base, source, stage in
            let initial = try ConduitOfflineWorkspace.stage(sourceRoot: source, stagedRoot: stage)
            let disk = base.appendingPathComponent("disk.img")
            try Data(repeating: 0, count: 512).write(to: disk)
            let pinned = try ConduitOfflineFS.asset(at: disk.path, maximumBytes: 512)
            var assets = ConduitOfflineAssets(bootDisk: pinned)
            let request = ConduitOfflineRequest(operationID: "one", stagedRoot: stage.path,
                expectedManifestSHA256: initial.sha256, assets: assets)
            XCTAssertFalse(ConduitOfflinePreflight.observe(request: request).blockers.contains("asset_identity_mismatch:boot_disk"))
            try Data(repeating: 1, count: 512).write(to: disk)
            XCTAssertTrue(ConduitOfflinePreflight.observe(request: request).blockers.contains("asset_identity_mismatch:boot_disk"))
            let link = base.appendingPathComponent("linked")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: base)
            assets.bootDisk = ConduitOfflineAsset(path: link.appendingPathComponent("disk.img").path, sha256: pinned.sha256, byteCount: pinned.byteCount)
            let throughLink = ConduitOfflineRequest(operationID: "one", stagedRoot: stage.path,
                expectedManifestSHA256: initial.sha256, assets: assets)
            XCTAssertTrue(ConduitOfflinePreflight.observe(request: throughLink).blockers.contains("unsafe_or_missing_path:boot_disk"))
        }
    }

    func testActualAssetSizeRefusesBeforeHashEvenWhenDescriptorClaimsSmallFile() throws {
        try fixture { base, source, stage in
            let initial = try ConduitOfflineWorkspace.stage(sourceRoot: source, stagedRoot: stage)
            let inventory = base.appendingPathComponent("oversized-inventory.json")
            try Data(repeating: 0, count: 262_145).write(to: inventory)
            failure("asset_byte_limit") {
                _ = try ConduitOfflineFS.asset(at: inventory.path, maximumBytes: 262_144)
            }
            let liar = ConduitOfflineAsset(path: inventory.path, sha256: String(repeating: "a", count: 64), byteCount: 1)
            let assets = ConduitOfflineAssets(toolchainInventory: liar)
            let request = ConduitOfflineRequest(operationID: "small-claim", stagedRoot: stage.path,
                expectedManifestSHA256: initial.sha256, assets: assets)
            XCTAssertTrue(ConduitOfflinePreflight.observe(request: request).blockers.contains("asset_byte_limit:toolchain_inventory"))
        }
    }

    func testProductionCommandGuardStillRefusesWithoutSpendingWriteGate() throws {
        try fixture { base, source, _ in
            let store = base.appendingPathComponent("unused-command-store")
            let service = ConduitDirectCommandService(storeDirectory: store)
            let request = ConduitDirectCommandRequest(operationID: "offline-does-not-grant", projectSlug: "fixture",
                argv: ["/bin/true"], cwd: ".", timeoutMS: 1000, maxOutputBytes: 1024)
            var gateCalls = 0
            XCTAssertThrowsError(try service.submit(request, projectRoot: source, admitWrite: { gateCalls += 1 })) {
                XCTAssertEqual(($0 as? ConduitDirectCommandError)?.code, "execution_authority_unavailable")
            }
            XCTAssertEqual(gateCalls, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
        }
    }
}
