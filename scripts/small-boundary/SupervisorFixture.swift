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
        let request = ConduitDirectCommandRequest(
            operationID: fixtureOperationID, projectSlug: "fixture",
            argv: [fixturePythonPath, "-B", fixtureBridgePath, "--owned-bridge", directory.path, fixtureMode],
            timeoutMS: fixtureHostTimeoutMS, maxOutputBytes: 4096
        )
        var admissions = 0
        let guardOnly = ConduitDirectCommandService(storeDirectory: ungrantedStore)
        try refusal("execution_authority_unavailable") {
            _ = try guardOnly.submit(request, projectRoot: project) { admissions += 1 }
        }
        try require(admissions == 0 && !FileManager.default.fileExists(atPath: ungrantedStore.path), "public_refusal_had_effects")
        let service = ConduitDirectCommandService(storeDirectory: store, disposableFixtureRoot: project,
                                                  maximumConcurrentOperations: 1, supervisorExecutable: helper)
        let queued = try service.submit(request, projectRoot: project) { admissions += 1 }
        try save(queued, "supervisor-accepted", directory)
        if !liveTimeout {
            let activeReplay = try service.submit(request, projectRoot: project) { admissions += 1 }
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
        let replay = try service.submit(request, projectRoot: project) { admissions += 1 }
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
