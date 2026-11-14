import Foundation
import XCTest
@testable import ConduitCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Owned component fixtures only. These checks grant no product authority and
/// do not substitute for the native worker/guest campaign.
final class ConduitPortableOfflineLauncherTests: XCTestCase {
    private final class Fixture {
        let root: URL
        let launcher: ConduitOfflineAsset
        let binding: ConduitPortableOfflineBinding
        let authority: ConduitPortableOfflineAuthority
        let now = Date()
        init() throws {
            let nominated = FileManager.default.temporaryDirectory
                .appendingPathComponent("conduit-portable-unit-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: nominated, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            guard let resolved = realpath(nominated.path, nil) else { throw ConduitOfflineFailure("fixture_unavailable") }
            root = URL(fileURLWithPath: String(cString: resolved)); free(resolved)
            let input = root.appendingPathComponent("input")
            let scripts = input.appendingPathComponent("scripts")
            try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
            let sample = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Samples/OfflineProject/project/scripts/test.sh")
            try Data(contentsOf: sample).write(to: scripts.appendingPathComponent("test.sh"))
            try Data("after\n".utf8).write(to: input.appendingPathComponent("message.txt"))
            let stage = root.appendingPathComponent("staged-project")
            let manifest = try ConduitOfflineWorkspace.stage(sourceRoot: input, stagedRoot: stage)
            for name in ["VMRunner", "kernel", "initrd.cpio.gz", "supervisor", "native-offline-worker"] {
                try Data(("owned-component-" + name).utf8).write(to: root.appendingPathComponent(name))
                if ["VMRunner", "supervisor", "native-offline-worker"].contains(name) {
                    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent(name).path)
                }
            }
            let assetRoot = root
            func asset(_ name: String) throws -> ConduitOfflineAsset {
                try ConduitOfflineFS.asset(at: assetRoot.appendingPathComponent(name).path, maximumBytes: 67_108_864)
            }
            let worker = try asset("VMRunner"), kernel = try asset("kernel"), initrd = try asset("initrd.cpio.gz")
            let nonce = String(repeating: "a", count: 64)
            let ticket = try JSONSerialization.data(withJSONObject: ["operation": "linux-suite", "nonce": nonce,
                "kernel_sha256": kernel.sha256, "initrd_sha256": initrd.sha256], options: [.sortedKeys])
            try ticket.write(to: root.appendingPathComponent("native-ticket.json"))
            try Data(nonce.utf8).write(to: root.appendingPathComponent("launch.claim"))
            binding = ConduitPortableOfflineBinding(profile: .v1, operationID: "portable-check", nonce: nonce,
                fixtureRoot: try .observe(root.path, privateDirectory: true),
                projectRoot: try .observe(stage.path, privateDirectory: true), manifestSHA256: manifest.sha256,
                nativeTicketSHA256: ConduitPortableOfflineAuthority.digest(ticket), nativeExecutable: worker,
                kernel: kernel, initramfs: initrd, supervisor: try asset("supervisor"), slot: nil,
                expectedCases: ["permitted-check"], mode: "complete", issuedAtUnixSeconds: now.timeIntervalSince1970,
                expiresAtUnixSeconds: now.timeIntervalSince1970 + 240)
            launcher = try asset("native-offline-worker")
            authority = try ConduitPortableOfflineAuthority(fixtureKey: Data(repeating: 7, count: 32))
        }
        deinit { ConduitOfflineFixtureEvidence.preserveAndClean(root, test: "portable-launcher-component") }
        func changed(_ edit: (inout [String: Any]) -> Void) throws -> ConduitPortableOfflineBinding {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ConduitPortableOfflineAuthority.encode(binding)) as? [String: Any])
            edit(&object)
            return try JSONDecoder().decode(ConduitPortableOfflineBinding.self, from: JSONSerialization.data(withJSONObject: object))
        }
        func grant() throws -> ConduitPortableOfflineGrant { try authority.issue(binding: binding, launcher: launcher, now: now) }
    }

    func testValidFixtureAuthorityRoundTripsButDescriptionGrantsNothing() throws {
        let f = try Fixture(), grant = try f.grant()
        XCTAssertTrue(try f.authority.authorize(f.binding, grant: grant, now: f.now) === grant)
        let redeemed = try f.authority.redeem(grant.encodedPermit, expected: f.binding, launcherPath: f.launcher.path, now: f.now)
        XCTAssertEqual(redeemed.grantID, grant.grantID)
        XCTAssertEqual(redeemed.binding, f.binding)
        XCTAssertEqual(ConduitPortableOfflineProfile.v1.cpuCount, 1)
        XCTAssertEqual(ConduitOfflineProfile.v1.cpuCount, 2)
        XCTAssertEqual(ConduitOfflineProfile.v1.memoryBytes, 4 * 1024 * 1024 * 1024)
        var writes = 0
        let store = f.root.appendingPathComponent("never-created")
        let publicService = ConduitDirectCommandService(storeDirectory: store)
        let adapter = ConduitPortableOfflineLauncher(service: publicService, authority: f.authority)
        XCTAssertThrowsError(try adapter.submit(f.binding, grant: grant, now: f.now) { writes += 1 }) {
            XCTAssertEqual(($0 as? ConduitDirectCommandError)?.code, "execution_authority_unavailable")
        }
        XCTAssertEqual(writes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
    }

    func testAbsentForeignAndExpiredGrantsRefuseBeforeEffects() throws {
        let f = try Fixture(), grant = try f.grant()
        let other = try ConduitPortableOfflineAuthority(fixtureKey: Data(repeating: 8, count: 32))
        let foreign = try other.issue(binding: f.binding, launcher: f.launcher, now: f.now)
        let store = f.root.appendingPathComponent("never-created")
        let service = ConduitDirectCommandService(storeDirectory: store, disposableFixtureRoot: URL(fileURLWithPath: f.binding.projectRoot.path))
        let adapter = ConduitPortableOfflineLauncher(service: service, authority: f.authority)
        let before = try FileManager.default.contentsOfDirectory(atPath: f.root.path)
        var writes = 0
        for candidate in [nil, foreign] as [ConduitPortableOfflineGrant?] {
            XCTAssertThrowsError(try adapter.submit(f.binding, grant: candidate, now: f.now) { writes += 1 })
        }
        XCTAssertThrowsError(try adapter.submit(f.binding, grant: grant, now: f.now.addingTimeInterval(241)) { writes += 1 })
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.path), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
    }

    func testChangedOperationProfileBudgetEnvironmentAndNonceRefuse() throws {
        let f = try Fixture(), grant = try f.grant()
        var variants = [try f.changed { $0["operationID"] = "different-operation" },
                        try f.changed { $0["nonce"] = String(repeating: "b", count: 64) }]
        for (key, value) in [("profileID", "wrong-profile"), ("hostDeadlineMS", 6000),
                             ("cpuCount", 2), ("argv", ["/bin/unsafe"]),
                             ("environment", ["PATH": "/untrusted"])] as [(String, Any)] {
            variants.append(try f.changed { root in
                var profile = root["profile"] as! [String: Any]; profile[key] = value; root["profile"] = profile
            })
        }
        for changed in variants {
            XCTAssertThrowsError(try f.authority.authorize(changed, grant: grant, now: f.now))
            XCTAssertThrowsError(try f.authority.issue(binding: changed, launcher: f.launcher, now: f.now))
        }
        XCTAssertThrowsError(try f.authority.redeem(grant.encodedPermit, expected: f.binding,
            launcherPath: f.root.appendingPathComponent("other-worker").path, now: f.now))
    }

    func testChangedAssetsAndStagedInputsAreRechecked() throws {
        do {
            let f = try Fixture(), grant = try f.grant()
            try Data("changed".utf8).write(to: URL(fileURLWithPath: f.binding.kernel.path))
            XCTAssertThrowsError(try f.authority.authorize(f.binding, grant: grant, now: f.now))
        }
        do {
            let f = try Fixture(), grant = try f.grant()
            try Data("changed\n".utf8).write(to: URL(fileURLWithPath: f.binding.projectRoot.path).appendingPathComponent("message.txt"))
            XCTAssertThrowsError(try f.authority.authorize(f.binding, grant: grant, now: f.now))
        }
        do {
            let f = try Fixture(), grant = try f.grant()
            try FileManager.default.removeItem(atPath: f.binding.nativeExecutable.path)
            XCTAssertThrowsError(try f.authority.redeem(grant.encodedPermit, expected: f.binding, launcherPath: f.launcher.path, now: f.now))
        }
    }

    func testRootReplacementAndSymlinkAliasRefuse() throws {
        let f = try Fixture(), grant = try f.grant()
        let stage = URL(fileURLWithPath: f.binding.projectRoot.path)
        let moved = f.root.appendingPathComponent("retained-stage")
        try FileManager.default.moveItem(at: stage, to: moved)
        try FileManager.default.createSymbolicLink(at: stage, withDestinationURL: moved)
        XCTAssertThrowsError(try f.authority.authorize(f.binding, grant: grant, now: f.now))
    }

    func testWireTamperingExtraFieldsAndCrossIssuerCannotMintAuthority() throws {
        let f = try Fixture(), grant = try f.grant()
        var wire = try XCTUnwrap(JSONSerialization.jsonObject(with: grant.encodedPermit) as? [String: Any])
        wire["mac"] = Data(repeating: 0, count: 32).base64EncodedString()
        XCTAssertThrowsError(try f.authority.redeem(JSONSerialization.data(withJSONObject: wire), expected: f.binding,
            launcherPath: f.launcher.path, now: f.now))
        wire = try XCTUnwrap(JSONSerialization.jsonObject(with: grant.encodedPermit) as? [String: Any]); wire["authority"] = true
        XCTAssertThrowsError(try f.authority.redeem(JSONSerialization.data(withJSONObject: wire), expected: f.binding,
            launcherPath: f.launcher.path, now: f.now))
        XCTAssertThrowsError(try f.authority.redeem(Data(), expected: f.binding, launcherPath: f.launcher.path, now: f.now))
        XCTAssertThrowsError(try ConduitPortableOfflineAuthority(fixtureKey: Data()))
    }

    func testExclusivePersistenceKeepsFirstBytesAndRejectsTraversal() throws {
        let f = try Fixture()
        let original = Data("first record\n".utf8)
        try ConduitPortableOfflineAuthority.persist(original, name: "owned-record.json", root: f.binding.fixtureRoot)
        XCTAssertThrowsError(try ConduitPortableOfflineAuthority.persist(Data("replacement".utf8), name: "owned-record.json", root: f.binding.fixtureRoot))
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("owned-record.json")), original)
        for name in ["../outside", "nested/file", "..", ""] {
            XCTAssertThrowsError(try ConduitPortableOfflineAuthority.persist(original, name: name, root: f.binding.fixtureRoot))
        }
    }

    func testExpiredExactRetryObservesExistingReceiptWithoutNewAuthorityOrEffects() throws {
        let f = try Fixture()
        // Harmless host component actuator only; no VM or confinement claim.
        let bridge = URL(fileURLWithPath: f.launcher.path)
        try Data("#!/bin/sh\nprintf 'component receipt\\n'\n".utf8).write(to: bridge)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bridge.path)
        let executable = try ConduitOfflineFS.asset(at: bridge.path, maximumBytes: 65_536)
        let grant = try f.authority.issue(binding: f.binding, launcher: executable, now: f.now)
        try ConduitPortableOfflineAuthority.persist(grant.encodedPermit, name: "native-permit.json", root: f.binding.fixtureRoot)
        let project = URL(fileURLWithPath: f.binding.projectRoot.path), store = f.root.appendingPathComponent("receipts")
        let service = ConduitDirectCommandService(storeDirectory: store, disposableFixtureRoot: project)
        let adapter = ConduitPortableOfflineLauncher(service: service, authority: f.authority)
        var writes = 0
        _ = try adapter.submit(f.binding, grant: grant, now: f.now) { writes += 1 }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var final = try service.lookup(operationID: f.binding.operationID, projectSlug: "fixture", projectRoot: project)
        while !final.phase.isTerminal && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
            final = try service.lookup(operationID: f.binding.operationID, projectSlug: "fixture", projectRoot: project)
        }
        XCTAssertEqual(final.exitCode, 0)
        XCTAssertEqual(final.stdout.bytes, Data("component receipt\n".utf8))
        func bytes() throws -> [String: Data] {
            try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(atPath: store.path).map {
                ($0, try Data(contentsOf: store.appendingPathComponent($0)))
            })
        }
        let before = try bytes(), expired = f.now.addingTimeInterval(301)
        try Data("later owned input\n".utf8).write(to: project.appendingPathComponent("message.txt"))
        try Data("changed non-executable bytes".utf8).write(to: bridge)
        let replay = try adapter.submit(f.binding, grant: grant, now: expired) { writes += 1 }
        XCTAssertTrue(replay.idempotentReplay)
        XCTAssertEqual(replay.stdout, final.stdout)
        let reader = ConduitPortableOfflineLauncher(service: ConduitDirectCommandService(storeDirectory: store), authority: f.authority)
        let historical = try reader.submit(f.binding, grant: grant, now: expired) { writes += 1 }
        XCTAssertTrue(historical.idempotentReplay)
        XCTAssertFalse(historical.executionCapacityReleased)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(try bytes(), before)
        XCTAssertThrowsError(try reader.submit(f.binding, grant: nil, now: expired) { writes += 1 })
        let absent = f.root.appendingPathComponent("absent-receipts")
        let fresh = ConduitPortableOfflineLauncher(service: ConduitDirectCommandService(storeDirectory: absent,
            disposableFixtureRoot: project), authority: f.authority)
        XCTAssertThrowsError(try fresh.submit(f.binding, grant: grant, now: expired) { writes += 1 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
        try Data("tampered permit".utf8).write(to: f.root.appendingPathComponent("native-permit.json"))
        XCTAssertThrowsError(try reader.submit(f.binding, grant: grant, now: expired) { writes += 1 })
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(try bytes(), before)
    }
}
