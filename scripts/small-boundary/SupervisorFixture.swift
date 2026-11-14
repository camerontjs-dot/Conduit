import CryptoKit
import Darwin
import Foundation
@testable import ConduitCore

// Standalone test driver. Link only against a development build of ConduitCore.
@main
struct SupervisorFixture {
    struct Failure: Error { let reason: String }

    static func require(_ condition: @autoclosure () throws -> Bool, _ reason: String) throws {
        if try !condition() { throw Failure(reason: reason) }
    }

    static func refusal(_ code: String, _ run: () throws -> Void) throws {
        do { try run() }
        catch let error as ConduitDirectCommandError where error.code == code { return }
        throw Failure(reason: "expected_refusal_\(code)")
    }

    static let encoder: JSONEncoder = {
        let value = JSONEncoder()
        value.outputFormatting = [.prettyPrinted, .sortedKeys]
        return value
    }()

    static func save(_ receipt: ConduitDirectCommandReceipt, _ name: String, _ at: URL) throws {
        try encoder.encode(receipt).write(to: at.appendingPathComponent(name + ".json"), options: .withoutOverwriting)
    }

    static func normalized(_ receipt: ConduitDirectCommandReceipt) throws -> Data {
        var copy = receipt
        copy.idempotentReplay = false
        // A reader must not inherit the live owner's capacity acknowledgement.
        copy.executionCapacityReleased = false
        return try encoder.encode(copy)
    }

    static func storeBytes(_ store: URL) throws -> [String: Data] {
        let names = try FileManager.default.contentsOfDirectory(atPath: store.path)
        return try Dictionary(uniqueKeysWithValues: names.map {
            ($0, try Data(contentsOf: store.appendingPathComponent($0)))
        })
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func admit(_ directory: URL) throws {
        // The pins are generated for one admitted run. No caller-selected
        // executable, project or authority value is taken from argv.
        try require(CommandLine.arguments.count == 1, "fixture_driver_has_no_arguments")
        var info = stat()
        try require(fstat(3, &info) == 0 && info.st_mode & S_IFMT == S_IFIFO, "fixture_capability_required")
        let channel = FileHandle(fileDescriptor: 3, closeOnDealloc: true)
        let ticket = try channel.read(upToCount: 16385) ?? Data()
        try channel.close()
        try require(ticket.count <= 16384 && digest(ticket) == fixtureTicketDigest, "fixture_capability_invalid")
        try require(lstat(directory.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
                    && info.st_uid == getuid() && info.st_mode & 0o077 == 0, "owned_private_fixture_required")
        let object = try JSONSerialization.jsonObject(with: ticket) as? [String: String]
        guard let nonce = object?["nonce"] else { throw Failure(reason: "fixture_nonce_unavailable") }
        try require(try Data(contentsOf: directory.appendingPathComponent("launch.claim")) == Data(nonce.utf8),
                    "host_admission_changed")
        for (path, expected) in fixtureExecutablePins {
            try require(try digest(Data(contentsOf: URL(fileURLWithPath: path))) == expected, "fixture_executable_changed")
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        try require(!names.contains("native-launch.claim") && !names.contains("supervisor-store"), "fixture_already_claimed")
    }

    static func run() throws {
        let directory = URL(fileURLWithPath: fixtureRunPath, isDirectory: true)
        try admit(directory)
        let project = directory.appendingPathComponent("staged-project", isDirectory: true)
        let store = directory.appendingPathComponent("supervisor-store", isDirectory: true)
        let ungrantedStore = directory.appendingPathComponent("ungranted-store", isDirectory: true)
        let helper = URL(fileURLWithPath: fixtureSupervisorPath)
        let liveTimeout = ["cooperative", "default"].contains(fixtureMode)
#if CONDUIT_NATIVE_OFFLINE_BRIDGE
        let binding = try JSONDecoder().decode(ConduitPortableOfflineBinding.self, from: fixturePortableBindingData)
        let authority = try ConduitPortableOfflineAuthority(fixtureKey: fixturePortableAuthorityKey)
        let launcherAsset = ConduitOfflineAsset(path: fixtureNativeLauncherPath,
            sha256: fixtureNativeLauncherSHA256, byteCount: fixtureNativeLauncherBytes)
        let grant = try authority.issue(binding: binding, launcher: launcherAsset)
        let request = ConduitDirectCommandRequest(operationID: fixtureOperationID, projectSlug: "fixture",
            argv: [fixtureNativeLauncherPath], timeoutMS: fixtureHostTimeoutMS, maxOutputBytes: 4096)
#else
        let request = ConduitDirectCommandRequest(
            operationID: fixtureOperationID, projectSlug: "fixture",
            argv: [fixturePythonPath, "-B", fixtureBridgePath, "--owned-bridge", directory.path, fixtureMode],
            timeoutMS: fixtureHostTimeoutMS, maxOutputBytes: 4096
        )
#endif
        var admissions = 0
        let guardOnly = ConduitDirectCommandService(storeDirectory: ungrantedStore)
        try refusal("execution_authority_unavailable") {
            _ = try guardOnly.submit(request, projectRoot: project) { admissions += 1 }
        }
        try require(admissions == 0 && !FileManager.default.fileExists(atPath: ungrantedStore.path), "public_refusal_had_effects")
        let service = ConduitDirectCommandService(storeDirectory: store, disposableFixtureRoot: project,
                                                  maximumConcurrentOperations: 1, supervisorExecutable: helper)
#if CONDUIT_NATIVE_OFFLINE_BRIDGE
        let adapter = ConduitPortableOfflineLauncher(service: service, authority: authority)
        try require(adapter.request(for: grant) == request, "portable_request_not_fixed")
        let preparedNames = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        var controls = [[String: Any]]()
        func denied(_ name: String, _ run: () throws -> Void) throws {
            var code = "unexpected_admission"
            do { try run() } catch let error as ConduitOfflineFailure { code = error.code }
            let unchanged = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == preparedNames
            try require(code.hasPrefix("portable_") && code != "unexpected_admission"
                        && unchanged && admissions == 0, "portable_authority_refusal_had_effects_" + name)
            controls.append(["case": name, "code": code, "refused_before_effects": true])
        }
        try denied("absent") { _ = try adapter.submit(binding, grant: nil) { admissions += 1 } }
        let otherAuthority = try ConduitPortableOfflineAuthority(fixtureKey: Data(repeating: 0, count: 32))
        let foreign = try otherAuthority.issue(binding: binding, launcher: launcherAsset)
        try denied("unissued-by-this-owner") { _ = try adapter.submit(binding, grant: foreign) { admissions += 1 } }
        try denied("expired") {
            _ = try adapter.submit(binding, grant: grant, now: Date(timeIntervalSince1970: binding.expiresAtUnixSeconds + 1)) { admissions += 1 }
        }
        for field in ["operationID", "nonce", "manifestSHA256", "profile", "projectRoot", "nativeExecutable", "slot"] {
            var object = try JSONSerialization.jsonObject(with: fixturePortableBindingData) as! [String: Any]
            if field == "profile" {
                var profile = object[field] as! [String: Any]; profile["profileID"] = "untrusted"; object[field] = profile
            } else if ["projectRoot", "nativeExecutable"].contains(field) {
                var asset = object[field] as! [String: Any]; asset["path"] = directory.path + "/untrusted"; object[field] = asset
            } else if field == "slot" {
                object[field] = ["path": directory.path + "/untrusted", "identity": "0:0"]
            } else { object[field] = field == "operationID" ? "untrusted" : String(repeating: "0", count: 64) }
            let changed = try JSONDecoder().decode(ConduitPortableOfflineBinding.self,
                from: JSONSerialization.data(withJSONObject: object))
            try denied("wrong-" + field) { _ = try adapter.submit(changed, grant: grant) { admissions += 1 } }
        }
        try ConduitPortableOfflineAuthority.persist(JSONSerialization.data(withJSONObject: controls, options: [.sortedKeys]),
            name: "portable-authority-refusals.json", root: binding.fixtureRoot)
        try ConduitPortableOfflineAuthority.persist(grant.encodedPermit, name: "native-permit.json", root: binding.fixtureRoot)
        let queued = try adapter.submit(binding, grant: grant) { admissions += 1 }
#else
        let queued = try service.submit(request, projectRoot: project) { admissions += 1 }
#endif
        try save(queued, "supervisor-accepted", directory)
        if !liveTimeout {
#if CONDUIT_NATIVE_OFFLINE_BRIDGE
            let activeReplay = try adapter.submit(binding, grant: grant) { admissions += 1 }
#else
            let activeReplay = try service.submit(request, projectRoot: project) { admissions += 1 }
#endif
            try save(activeReplay, "supervisor-active-replay", directory)
            try require(activeReplay.idempotentReplay && !activeReplay.phase.isTerminal && admissions == 1, "active_replay_not_idempotent")
        }

        let stopWaiting = ProcessInfo.processInfo.systemUptime + 9
        var final = try service.lookup(operationID: request.operationID, projectSlug: "fixture", projectRoot: project)
        while !final.phase.isTerminal && ProcessInfo.processInfo.systemUptime < stopWaiting {
            Thread.sleep(forTimeInterval: 0.01)
            final = try service.lookup(operationID: request.operationID, projectSlug: "fixture", projectRoot: project)
        }
        try save(final, "supervisor-final", directory)
        try require(final.phase.isTerminal, "terminal_receipt_unobserved")
#if CONDUIT_NATIVE_OFFLINE_BRIDGE
        let guestData = try ConduitPortableOfflineAuthority.read(directory.path + "/native-guest-receipt.json", maximumBytes: 65_536)
        let bound = try adapter.bind(final, guestData: guestData, grant: grant)
        try ConduitPortableOfflineAuthority.persist(encoder.encode(bound), name: "portable-bound-result.json", root: binding.fixtureRoot)
        var tampered = guestData; tampered[tampered.startIndex] ^= 1
        var rejected = false
        do { _ = try adapter.bind(final, guestData: tampered, grant: grant) } catch { rejected = true }
        try require(rejected, "unauthenticated_guest_receipt_accepted")
#endif
        if liveTimeout {
            try require(final.phase == .timedOut && final.supervision?.cleanupCause == 2
                        && final.supervision?.goCommitted == true && final.supervision?.finalFrameObserved == true
                        && final.directChildExitObserved && final.processGroupAbsentObserved
                        && final.stdout.reachedEOF && final.stderr.reachedEOF && admissions == 1,
                        "live_host_timeout_or_cleanup_unconfirmed")
            if !(fixtureSharedGuestSlot && fixtureMode == "default") {
                print("SUPERVISOR_FIXTURE_HOST_TIMEOUT")
                return
            }
        }
        let before = try storeBytes(store)
        let claim = directory.appendingPathComponent("native-launch.claim")
        let claimBefore = try Data(contentsOf: claim)
#if CONDUIT_NATIVE_OFFLINE_BRIDGE
        let replay = try adapter.submit(binding, grant: grant) { admissions += 1 }
#else
        let replay = try service.submit(request, projectRoot: project) { admissions += 1 }
#endif
        try save(replay, "supervisor-replay", directory)
        let reader = ConduitDirectCommandService(storeDirectory: store)
        let historical = try reader.submit(request, projectRoot: project) { admissions += 1 }
        try save(historical, "supervisor-reader-replay", directory)
        let conflict = ConduitDirectCommandRequest(operationID: request.operationID, projectSlug: "fixture",
                                                    argv: request.argv, timeoutMS: 4999, maxOutputBytes: 4096)
        try refusal("operation_id_conflict") {
            _ = try service.submit(conflict, projectRoot: project) { admissions += 1 }
        }
        try require(try normalized(replay) == normalized(final) && normalized(historical) == normalized(final), "replay_receipt_changed")
        try require(replay.idempotentReplay && historical.idempotentReplay && !historical.executionCapacityReleased, "replay_ownership_incorrect")
        try require(try storeBytes(store) == before && Data(contentsOf: claim) == claimBefore, "replay_wrote_to_store_or_claim")
#if CONDUIT_NATIVE_OFFLINE_BRIDGE
        try require(try ConduitPortableOfflineAuthority.read(directory.path + "/native-guest-receipt.json", maximumBytes: 65_536) == guestData,
                    "replay_changed_guest_evidence")
#endif
        let entries = try Data(contentsOf: directory.appendingPathComponent("bridge-entries"))
        try require(admissions == 1 && entries == Data("entered\n".utf8), "duplicate_command_effect")
        try require(final.schemaVersion == "conduit-direct-command/v2" && final.supervision?.goCommitted == true
                    && final.supervision?.finalFrameObserved == true && final.directChildExitObserved
                    && final.processGroupAbsentObserved && final.executionCapacityReleased, "host_cleanup_unconfirmed")
        if liveTimeout {
            print("SUPERVISOR_FIXTURE_HOST_REPLAY_PASS admissions=\(admissions) entries=1")
            return
        }
        try require(final.stdout.bytes == Data("sample check passed\n".utf8) && final.stderr.bytes.isEmpty
                    && final.stdout.reachedEOF && final.stderr.reachedEOF && !final.stdout.truncated && !final.stderr.truncated,
                    "typed_streams_incomplete")
        if fixtureMode == "timeout-after-stop" {
            try require(final.phase == .timedOut && final.exitCode == nil && final.terminationSignal == SIGTERM
                        && final.supervision?.cleanupCause == 2, "host_deadline_not_observed")
        } else {
            try require(final.phase == .exited && final.exitCode == 0 && final.terminationSignal == nil
                        && final.supervision?.cleanupCause == 0, "permitted_check_not_exited_zero")
        }
        print("SUPERVISOR_FIXTURE_PASS \(final.phase.rawValue) admissions=\(admissions) entries=1")
    }

    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("SUPERVISOR_FIXTURE_FAIL \(error)\n".utf8))
            exit(2)
        }
    }
}
