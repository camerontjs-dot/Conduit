import Darwin
import Foundation
@testable import ConduitCore

/// Observation-only development check, linked with the original private pins.
/// It has no fixture executor and cannot launch or signal a command/VM.
@main
struct NativeOfflineReplayFixture {
    static func require(_ value: Bool, _ code: String) throws {
        guard value else { throw ConduitOfflineFailure("portable_replay_" + code) }
    }
    static func bytes(_ directory: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(atPath: directory.path).map {
            ($0, try Data(contentsOf: directory.appendingPathComponent($0)))
        })
    }
    static func run() throws {
        try require(CommandLine.arguments.count == 1, "no_arguments")
        let binding = try JSONDecoder().decode(ConduitPortableOfflineBinding.self, from: fixturePortableBindingData)
        let root = URL(fileURLWithPath: binding.fixtureRoot.path), store = root.appendingPathComponent("supervisor-store")
        let authority = try ConduitPortableOfflineAuthority(fixtureKey: fixturePortableAuthorityKey)
        let permit = try ConduitPortableOfflineAuthority.read(root.path + "/native-permit.json", maximumBytes: 16_384)
        // Reconstitute only the original issuer's sealed object at its recorded
        // issue time. Actual fresh admission below is tested AFTER expiry and
        // must refuse. The service used for observation has no executor.
        let grant = try authority.redeem(permit, expected: binding, launcherPath: fixtureNativeLauncherPath,
            now: Date(timeIntervalSince1970: binding.issuedAtUnixSeconds + 1))
        let expired = Date(timeIntervalSince1970: binding.expiresAtUnixSeconds + 1)
        var expiryRefused = false
        do { _ = try authority.authorize(binding, grant: grant, now: expired) }
        catch let error as ConduitOfflineFailure { expiryRefused = error.code == "portable_grant_expired" }
        try require(expiryRefused, "expired_fresh_authority_not_refused")
        let before = try bytes(store)
        let preserved = ["native-permit.json", "native-bridge.claim", "native-launch.claim", "bridge-entries", "native-guest-receipt.json"]
        func facts() throws -> [String: Data] {
            var result = [String: Data]()
            for name in preserved where FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) {
                result[name] = try Data(contentsOf: root.appendingPathComponent(name))
            }
            return result
        }
        let claimsBefore = try facts()
        let slotBefore = try binding.slot.map { try bytes(URL(fileURLWithPath: $0.path)) }
        let reader = ConduitDirectCommandService(storeDirectory: store)
        let adapter = ConduitPortableOfflineLauncher(service: reader, authority: authority)
        var writes = 0
        let original = try reader.lookup(operationID: binding.operationID, projectSlug: "fixture",
            projectRoot: URL(fileURLWithPath: binding.projectRoot.path))
        let replay = try adapter.submit(binding, grant: grant, now: expired) { writes += 1 }
        try require(replay.idempotentReplay && replay.phase == original.phase && replay.exitCode == original.exitCode
                    && replay.terminationSignal == original.terminationSignal && replay.stdout == original.stdout
                    && replay.stderr == original.stderr && !replay.executionCapacityReleased, "historical_facts_changed")
        var absentRefused = false
        do { _ = try adapter.submit(binding, grant: nil, now: expired) { writes += 1 } }
        catch let error as ConduitOfflineFailure { absentRefused = error.code == "portable_execution_authority_unavailable" }
        try require(absentRefused && writes == 0 && (try bytes(store)) == before && (try facts()) == claimsBefore
                    && (try binding.slot.map { try bytes(URL(fileURLWithPath: $0.path)) }) == slotBefore,
                    "observation_wrote_or_restored_authority")
        let report: [String: Any] = ["status": "READ_ONLY_REPLAY_NO_NEW_AUTHORITY", "phase": replay.phase.rawValue,
            "idempotent_replay": true, "fresh_expired_authority_refused": true, "absent_authority_refused": true,
            "write_hook_calls": writes, "store_claims_slot_unchanged": true,
            "execution_capacity_released_by_reader": false, "VM_starts": 0]
        try ConduitPortableOfflineAuthority.persist(JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
            name: "native-read-only-replay.json", root: binding.fixtureRoot)
        print("NATIVE_READ_ONLY_REPLAY_PASS")
    }
    static func main() {
        do { try run() }
        catch { FileHandle.standardError.write(Data("NATIVE_READ_ONLY_REPLAY_FAIL \(error)\n".utf8)); exit(2) }
    }
}
