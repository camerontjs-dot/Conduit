import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Private API intent/outcome receipts, never project history. One owner for the
/// lifetime of the journal. A durable intent without a valid outcome is UNKNOWN.
public final class SessionAPIReplayJournal {
    public enum Failure: String, Error { case unavailable, conflict, unknown, capacity, invalidKey }
    private struct Envelope: Codable {
        let bytes: Data
        let digest: String
    }
    private struct Receipt: Codable {
        let version: Int
        let identity: String
        let fingerprint: String
        let reservation: UUID
        let outcome: [String: String]?
    }
    private let location: URL
    private let directory: Int32
    private let owner: Int32
    private let mutex = NSLock()
    private let capacity: Int
    private let sync: (Int32) -> Int32
    private static let limit = 16_384

    public convenience init(directory: URL, capacity: Int = 2048) throws {
        try self.init(directory: directory, capacity: capacity, synchronize: { fsync($0) })
    }

    // Injectable disk failure seam; production always synchronizes files and directory.
    init(directory url: URL, capacity: Int, synchronize: @escaping (Int32) -> Int32) throws {
        self.location = url
        self.capacity = min(max(capacity, 1), 2048)
        self.sync = synchronize
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unavailable }
        do {
            let components = url.pathComponents.filter { $0 != "/" }
            guard !components.isEmpty else { throw Failure.unavailable }
            for (index, component) in components.enumerated() {
                guard component != ".", component != ".." else { throw Failure.unavailable }
                if index == components.count - 1 {
                    if mkdirat(fd, component, 0o700) == 0 {
                        guard synchronize(fd) == 0 else { throw Failure.unavailable }
                    } else if errno != EEXIST { throw Failure.unavailable }
                }
                let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw Failure.unavailable }
                close(fd); fd = next
            }
            try Self.validate(fd, directory: true)
            let lock = openat(fd, "owner", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
            guard lock >= 0 else { throw Failure.unavailable }
            do {
                try Self.validate(lock, directory: false)
                guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw Failure.unavailable }
            } catch { close(lock); throw error }
            self.directory = fd
            self.owner = lock
        } catch { close(fd); throw error }
    }

    deinit { close(owner); close(directory) }

    /// The action includes admission and dispatch. No action (and therefore no
    /// rate budget) is spent on replay/conflict/unknown/storage refusal.
    public func perform(caller: String?, operation: String, key: String,
                        fields: [String], action: () -> [String: Any]) -> [String: Any] {
        perform(caller: caller, operation: operation, key: key, fields: fields, admission: { beginDispatch in
            guard beginDispatch() else { return [:] }
            return action()
        })
    }

    /// Admission may refuse without creating intent. The synchronous caller MUST
    /// check beginDispatch immediately before its first possible task/event/effect.
    /// A false checkpoint forbids dispatch; reservation cleanup remains the
    /// caller's responsibility. The checkpoint synchronizes intent exactly once.
    /// Neither errors nor missing task IDs are evidence of no effect afterward.
    public func perform(caller: String?, operation: String, key: String,
                        fields: [String], admission: (_ beginDispatch: () -> Bool) -> [String: Any]) -> [String: Any] {
        mutex.lock(); defer { mutex.unlock() }
        do {
            guard let caller, !caller.isEmpty else { throw Failure.unavailable }
            guard !key.isEmpty, key.utf8.count <= 512 else { throw Failure.invalidKey }
            try validateLocation()
            try Self.validate(directory, directory: true)
            try Self.validate(owner, directory: false)
            let identity = Self.hash([caller, operation, key])
            let fingerprint = Self.hash([caller, operation] + fields)
            let names = try entries()
            // Validate the bounded store, including orphan outcomes and corrupt
            // unrelated records. No silent repair or pruning of uncertain intent.
            for name in names where name != "owner" {
                let receipt = try read(name)
                let stem = String(name.split(separator: ".")[0])
                guard receipt.version == 1, receipt.identity == stem else { throw Failure.unknown }
                if name.hasSuffix(".outcome") {
                    guard names.contains(stem + ".intent") else { throw Failure.unknown }
                    let intent = try read(stem + ".intent")
                    guard intent.outcome == nil, intent.reservation == receipt.reservation,
                          intent.fingerprint == receipt.fingerprint,
                          let outcome = receipt.outcome else { throw Failure.unknown }
                    _ = try Self.restore(outcome)
                } else if receipt.outcome != nil { throw Failure.unknown }
            }
            let intentName = identity + ".intent"
            let outcomeName = identity + ".outcome"
            if names.contains(intentName) {
                let intent = try read(intentName)
                guard intent.identity == identity, intent.version == 1, intent.outcome == nil else { throw Failure.unknown }
                guard intent.fingerprint == fingerprint else { throw Failure.conflict }
                guard names.contains(outcomeName) else { throw Failure.unknown }
                let completed = try read(outcomeName)
                guard completed.identity == identity, completed.version == 1,
                      completed.fingerprint == fingerprint,
                      completed.reservation == intent.reservation,
                      let result = completed.outcome else { throw Failure.unknown }
                var payload = try Self.restore(result)
                if operation == "conduit_send_prompt", result["eventID"] == nil { throw Failure.unknown }
                payload["deduplicated"] = true
                payload["replay_state"] = "completed"
                payload["authority"] = "original API acceptance snapshot; inspect task events for current delivery"
                return payload
            }
            guard !names.contains(outcomeName) else { throw Failure.unknown }
            guard names.filter({ $0.hasSuffix(".intent") }).count < capacity else { throw Failure.capacity }
            let reservation = UUID()
            var attempted = false
            var checkpointFailure: Error?
            let payload = admission {
                guard !attempted else {
                    checkpointFailure = Failure.unknown
                    return false
                }
                attempted = true
                do {
                    try self.write(Receipt(version: 1, identity: identity, fingerprint: fingerprint,
                                           reservation: reservation, outcome: nil), name: intentName)
                    return true
                } catch {
                    checkpointFailure = error
                    return false
                }
            }
            if let checkpointFailure { throw checkpointFailure }
            guard attempted else {
                var refused = payload
                refused["replay_state"] = "not_dispatched"
                return refused
            }
            let result = Self.snapshot(payload)
            // No trustworthy identity means we cannot promise a completed replay.
            // After the checkpoint, retain intent even when the action reports refusal.
            do {
                _ = try Self.restore(result)
                if operation == "conduit_send_prompt", result["eventID"] == nil { throw Failure.unknown }
            } catch {
                // Preserve the original authoritative refusal, including the
                // reconcile-first instruction. Intent still prevents replay.
                if payload["error"] != nil {
                    var refused = payload
                    refused["replay_state"] = "unknown"
                    return refused
                }
                throw Failure.unknown
            }
            try write(Receipt(version: 1, identity: identity, fingerprint: fingerprint,
                              reservation: reservation, outcome: result), name: outcomeName)
            return payload
        } catch {
            let code = (error as? Failure)?.rawValue ?? Failure.unavailable.rawValue
            return ["error": "Keyed request blocked (\(code)); reconcile before any new request. No replay was dispatched.",
                    "replay_state": code, "outcome": "UNKNOWN"]
        }
    }

    private static func hash(_ fields: [String]) -> String {
        // Length framing prevents delimiter ambiguity. Only digests reach disk.
        ConduitSafetyHash.digest(namespace: "session-api-replay-v1",
            text: fields.map { "\($0.utf8.count):\($0)" }.joined())
    }

    private static func snapshot(_ payload: [String: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for key in ["taskSessionID", "eventID", "objective_event_id", "delivery", "objective_delivery_state"] {
            if let value = payload[key] as? String { result[key] = value }
        }
        for key in ["delivered", "objective_delivered", "objective_resend_required", "created", "ready"] {
            if let value = payload[key] as? Bool { result[key] = value ? "true" : "false" }
        }
        if payload["error"] != nil { result["error"] = "Original API operation reported a failure; inspect the task before retrying." }
        if payload["ancillary_warnings"] != nil { result["warning"] = "Original operation reported an ancillary work-log warning." }
        return result
    }

    private static func restore(_ result: [String: String]) throws -> [String: Any] {
        let allowed: Set<String> = ["taskSessionID", "eventID", "objective_event_id", "delivery", "objective_delivery_state", "delivered", "objective_delivered", "objective_resend_required", "created", "ready", "error", "warning"]
        guard Set(result.keys).isSubset(of: allowed),
              let task = result["taskSessionID"], UUID(uuidString: task) != nil else { throw Failure.unknown }
        var payload: [String: Any] = result
        for key in ["eventID", "objective_event_id"] {
            if let value = result[key], UUID(uuidString: value) == nil { throw Failure.unknown }
        }
        for key in ["delivered", "objective_delivered", "objective_resend_required", "created", "ready"] {
            if let value = result[key] {
                guard value == "true" || value == "false" else { throw Failure.unknown }
                payload[key] = value == "true"
            }
        }
        if let warning = payload.removeValue(forKey: "warning") { payload["ancillary_warnings"] = [warning] }
        return payload
    }

    private static func validate(_ fd: Int32, directory: Bool) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & 0o7777 == (directory ? 0o700 : 0o600),
              info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              directory || (info.st_nlink == 1 && info.st_size <= limit) else { throw Failure.unavailable }
    }

    private func validateLocation() throws {
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw Failure.unavailable }
        defer { close(current) }
        for component in location.pathComponents where component != "/" {
            let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw Failure.unavailable }
            close(current); current = next
        }
        var retained = stat(), observed = stat()
        guard fstat(directory, &retained) == 0, fstat(current, &observed) == 0,
              retained.st_dev == observed.st_dev, retained.st_ino == observed.st_ino,
              fstat(owner, &retained) == 0,
              fstatat(directory, "owner", &observed, AT_SYMLINK_NOFOLLOW) == 0,
              retained.st_dev == observed.st_dev, retained.st_ino == observed.st_ino else { throw Failure.unavailable }
    }

    private func entries() throws -> Set<String> {
        // Independent directory offset, retaining the validated directory handle.
        let fd = openat(directory, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unavailable }
        guard let stream = fdopendir(fd) else { close(fd); throw Failure.unavailable }
        defer { closedir(stream) }
        var names = Set<String>()
        errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard name == "owner" || name.hasSuffix(".intent") || name.hasSuffix(".outcome") else { throw Failure.unknown }
            names.insert(name)
            guard names.count <= capacity * 2 + 1 else { throw Failure.capacity }
            errno = 0
        }
        guard errno == 0 else { throw Failure.unavailable }
        // Count intents, including incomplete ones. Never prune them.
        guard names.filter({ $0.hasSuffix(".intent") }).count <= capacity else { throw Failure.capacity }
        return names
    }

    private func read(_ name: String) throws -> Receipt {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.unknown }
        defer { close(fd) }
        try Self.validate(fd, directory: false)
        var bytes = [UInt8](repeating: 0, count: Self.limit + 1)
        let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard count > 0, count <= Self.limit else { throw Failure.unknown }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(bytes.prefix(count)))
        guard envelope.digest == ConduitSafetyHash.digest(namespace: "session-api-receipt", bytes: envelope.bytes) else {
            throw Failure.unknown
        }
        return try JSONDecoder().decode(Receipt.self, from: envelope.bytes)
    }

    private func write(_ receipt: Receipt, name: String) throws {
        let bytes = try JSONEncoder().encode(receipt)
        let data = try JSONEncoder().encode(Envelope(bytes: bytes,
            digest: ConduitSafetyHash.digest(namespace: "session-api-receipt", bytes: bytes)))
        guard data.count <= Self.limit else { throw Failure.capacity }
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.unavailable }
        defer { close(fd) }
        try Self.validate(fd, directory: false)
        let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard count == data.count, sync(fd) == 0, sync(directory) == 0 else { throw Failure.unavailable }
    }
}
