import ConduitCore
import Darwin
import Foundation

private struct NativeFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
private struct DriverSnapshot: Equatable {
    let thread: String?
    let turn: String?
    let active: Bool
    let ready: Bool
    let approval: CodexAppServerApproval?
    let status: String?
    let error: String?
    let failure: String?
    init(_ client: CodexAppServerClient) {
        thread = client.threadID; turn = client.activeTurnID
        active = client.isTurnActive; ready = client.isReady
        approval = client.pendingApproval; status = client.lastTurnStatus
        error = client.lastError; failure = client.turnFailure
    }
}

/// Actual maintained client + actual owned stdio processes. This is owner
/// behavior evidence, never real-provider or independent qualification.
@main
@MainActor
struct CodexMetadataOwnerHarness {
    static let driverID = "0192e7f0-0000-7000-8000-000000000001"
    static let externalID = "0192e7f0-0000-7000-8000-000000000002"
    static let scenarios = [
        "no-host", "healthy", "unknown-id", "duplicate", "cursor-cycle", "page-bound",
        "malformed", "loaded-duplicate", "loaded-malformed", "unexpected-turns", "wrong-read", "stale-read", "rpc-error", "wrong-envelope",
        "timeout-control", "cancel", "host-stop", "capacity",
    ]

    static func main() async {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let executable = CommandLine.arguments[1]
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        var results: [[String: Any]] = []
        for scenario in scenarios {
            do {
                let result = try await run(scenario, executable: executable, root: root)
                results.append(result)
                print("PASS native Codex metadata \(scenario)")
            } catch {
                results.append(["scenario": scenario, "disposition": "FAIL", "error": error.localizedDescription])
                do { try save(results, root: root, disposition: "FAIL") }
                catch { print("APPARATUS_INVALID native receipt could not be preserved"); exit(2) }
                print("FAIL native Codex metadata \(scenario): \(error.localizedDescription)")
                exit(1)
            }
        }
        do { try save(results, root: root, disposition: "PASS_OWNER_FAKE_WIRE_ONLY") }
        catch { print("APPARATUS_INVALID native receipt could not be preserved"); exit(2) }
        print("\(results.count) native owner scenarios passed; real provider, mounted HTTP and independent qualification UNKNOWN/NOT_RUN")
    }

    static func run(_ scenario: String, executable: String, root: URL) async throws -> [String: Any] {
        let directory = root.appendingPathComponent(scenario, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data(scenario.utf8).write(to: directory.appendingPathComponent("scenario"), options: .withoutOverwriting)
        let client = CodexAppServerClient(cwd: directory, model: nil)
        if scenario == "no-host" {
            try await refuses(.notReady) { _ = try await client.observeProviderSessions() }
            try require(client.metadataObservationHostID == nil && !client.isReady, "read started a host")
            try require(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("wire.jsonl").path), "unstarted client produced wire traffic")
            return ["scenario": scenario, "disposition": "PASS", "owned_provider_processes_created": 0]
        }
        var effects: [CodexAppServerEffect] = []
        client.onEffect = { effects.append($0) }
        var pid: Int32?
        var problem: Error?
        var wire: [[String: Any]] = []
        do {
            try await client.start(executable: executable)
            guard let hostID = client.metadataObservationHostID,
                  let pidString = hostID.split(separator: ":").last, let child = Int32(pidString)
            else { throw NativeFailure(message: "fake host identity missing") }
            pid = child
            try client.sendTurn(text: "qualification-owned fake turn; no model invocation")
            try await waitFor { client.activeTurnID == "fixture-turn-distinct" && client.pendingApproval != nil }
            let before = DriverSnapshot(client)
            let beforeEffects = effects
            try require(before.thread == driverID && before.active, "fake driving setup did not settle")
            switch scenario {
            case "healthy":
                let inventory = try await client.observeProviderSessions()
                try require(inventory.hostID == hostID && inventory.threads.map(\.id) == [driverID, externalID], "inventory host/order changed")
                try require(inventory.loadedThreadIDs == Set([driverID]), "loaded scope widened")
                let loadedWorker = inventory.threads[0].worker(
                    hostID: hostID, loadedOnHost: true, binding: nil, observedAt: inventory.observedAt
                )
                try require(loadedWorker.providerHostID.value == hostID, "exact loaded worker lost its observed host identity")
                let read = try await client.observeProviderSession(exactID: externalID)
                guard let thread = read.threads.first else { throw NativeFailure(message: "no external metadata") }
                let worker = thread.worker(hostID: read.hostID, loadedOnHost: read.loadedThreadIDs.contains(thread.id), binding: nil, observedAt: read.observedAt)
                let text = String(decoding: try JSONEncoder().encode(worker), as: UTF8.self)
                try require(worker.turns.isEmpty && !worker.conduitTaskID.isKnown && !worker.writerControllerID.isKnown && worker.terminal.objectiveAcceptance == .unknown, "metadata gained consequential authority")
                try require(!worker.providerHostID.isKnown && text.contains("observation_host_id"), "unloaded worker inherited query-host identity")
                try require(!text.contains("fixture-private") && text.contains("configured_or_persisted_model"), "content leaked or model metadata misclassified")
                try await Task.sleep(nanoseconds: 150_000_000)
            case "unknown-id":
                for id in [String(externalID.prefix(8)), UUID().uuidString, externalID.uppercased() + " "] {
                    let expected: CodexObservationError = id.hasSuffix(" ") ? .invalidMetadata : .unknownSession
                    try await refuses(expected) { _ = try await client.observeProviderSession(exactID: id) }
                }
            case "duplicate", "cursor-cycle", "page-bound", "loaded-duplicate":
                try await refuses(.incompleteInventory) { _ = try await client.observeProviderSessions() }
            case "malformed", "loaded-malformed":
                try await refuses(.invalidMetadata) { _ = try await client.observeProviderSessions() }
            case "unexpected-turns", "wrong-read":
                try await refuses(.invalidMetadata) { _ = try await client.observeProviderSession(exactID: externalID) }
                try await Task.sleep(nanoseconds: 150_000_000)
            case "stale-read":
                try await refuses(.staleMetadata) { _ = try await client.observeProviderSession(exactID: externalID) }
                try await Task.sleep(nanoseconds: 150_000_000)
            case "rpc-error", "wrong-envelope":
                try await refuses(.providerRejected) { _ = try await client.observeProviderSessions() }
            case "timeout-control":
                let control = Task { try await client.readRateLimits() }
                try await refuses(.timedOut) { _ = try await client.observeProviderSessions() }
                let limits = try await control.value
                try require(String(decoding: limits, as: UTF8.self).contains("fixtureOnly"), "metadata timeout cancelled a driving request")
                try await Task.sleep(nanoseconds: 150_000_000)
            case "cancel":
                let observation = Task { try await client.observeProviderSessions() }
                try await Task.sleep(nanoseconds: 50_000_000)
                observation.cancel()
                try await refuses(.cancelled) { _ = try await observation.value }
                try await Task.sleep(nanoseconds: 500_000_000)
            case "host-stop":
                let observation = Task { try await client.observeProviderSessions() }
                try await Task.sleep(nanoseconds: 50_000_000)
                client.stop()
                try await refuses(.hostChanged) { _ = try await observation.value }
                try require(client.metadataObservationHostID == nil, "stopped host remains observable")
            case "capacity":
                let observations = (0..<CodexObservationRPC.maximumPendingRequests).map { _ in
                    Task { try await client.observeProviderSessions() }
                }
                try await Task.sleep(nanoseconds: 100_000_000)
                try await refuses(.tooManyRequests) { _ = try await client.observeProviderSessions() }
                for observation in observations { observation.cancel() }
                for observation in observations { try await refuses(.cancelled) { _ = try await observation.value } }
            default: throw NativeFailure(message: "unknown native fixture scenario")
            }
            if scenario != "host-stop" {
                try require(DriverSnapshot(client) == before && effects == beforeEffects, "observation changed driving thread, turn, approval, error or output effects")
                try require(client.metadataObservationHostID == hostID, "observation changed its provider host")
            }
            wire = try readWire(directory)
            let setupEnd = wire.lastIndex(where: { $0["method"] as? String == "turn/start" })!
            let observedWire = wire.suffix(from: setupEnd + 1)
            try require(observedWire.allSatisfy { ["thread/list", "thread/loaded/list", "thread/read", "account/rateLimits/read"].contains($0["method"] as? String ?? "") }, "observation caused a mutation verb")
            for request in observedWire where request["method"] as? String != "account/rateLimits/read" {
                try require((request["id"] as? String)?.hasPrefix(CodexObservationRPC.prefix) == true, "observation reused a driving request identity")
            }
            if scenario == "unknown-id" { try require(!observedWire.contains(where: { $0["method"] as? String == "thread/read" }), "unknown/prefix identity reached thread/read") }
            if scenario == "page-bound" { try require(observedWire.count == 4, "page limit silently widened") }
            if scenario == "capacity" { try require(observedWire.count == 8, "request limit silently widened") }
        } catch { problem = error }
        client.stop()
        if let pid {
            do { try await waitFor { kill(pid, 0) == -1 && errno == ESRCH } }
            catch { if problem == nil { problem = NativeFailure(message: "owned fixture PID did not disappear after stop") } }
        }
        if let problem { throw problem }
        return ["scenario": scenario, "disposition": "PASS", "owned_fixture_pid": pid.map { Int($0) } ?? 0,
                "owned_fixture_pid_gone": true, "wire_request_count": wire.count,
                "wire_methods": wire.compactMap { $0["method"] }, "driving_state_protected": scenario != "host-stop"]
    }

    static func refuses(_ expected: CodexObservationError, _ body: () async throws -> Void) async throws {
        do { try await body() }
        catch let error as CodexObservationError {
            try require(error == expected, "unexpected metadata refusal: \(error.localizedDescription)")
            return
        }
        throw NativeFailure(message: "metadata boundary did not refuse \(expected.localizedDescription)")
    }

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NativeFailure(message: message) }
    }

    static func waitFor(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !predicate() {
            guard Date() < deadline else { throw NativeFailure(message: "bounded native wait expired") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    static func readWire(_ directory: URL) throws -> [[String: Any]] {
        let text = try String(contentsOf: directory.appendingPathComponent("wire.jsonl"), encoding: .utf8)
        return try text.split(separator: "\n").map { line in
            guard let value = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                throw NativeFailure(message: "fixture wire trace was malformed")
            }
            return value
        }
    }

    static func save(_ results: [[String: Any]], root: URL, disposition: String) throws {
        let receipt: [String: Any] = [
            "disposition": disposition, "authority": "Source-exposed implementation owner; fake native stdio only",
            "scenarios": results, "remaining_scenarios": Array(scenarios.dropFirst(results.count)),
            "real_provider": "NOT_RUN", "mounted_http": "NOT_RUN", "independent_qualification": "NOT_RUN",
            "provider_turns_or_spending": "none; all fixture turns are synthetic owned process setup",
        ]
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("receipt.json"), options: .withoutOverwriting)
    }
}
