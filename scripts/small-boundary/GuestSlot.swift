import Darwin
import Foundation

struct GuestSlotFailure: Error {
    let reason: String
    init(_ reason: String) { self.reason = reason }
}

/// A single slot shared by the signed runners of one owned development
/// campaign. The process lock serializes changes; immutable claims survive
/// owner loss. Only the owning runner can record its observed VM stop.
final class GuestSlot {
    private let directory: Int32
    private let nonce: String
    private let ticket: Data
    private static let maximumRecordBytes = 16_384

    private init(directory: Int32, nonce: String, ticket: Data) {
        self.directory = directory
        self.nonce = nonce
        self.ticket = ticket
    }

    deinit { close(directory) }

    private static func validNonce(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func reserve(path: String, grant: [String: String], ticket: Data) throws -> GuestSlot {
        guard let nonce = grant["nonce"], validNonce(nonce) else { throw GuestSlotFailure("guest_slot_identity_invalid") }
        let directory = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw GuestSlotFailure("guest_slot_unavailable") }
        var transferred = false
        defer { if !transferred { close(directory) } }
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              grant["slot_device"] == String(info.st_dev), grant["slot_inode"] == String(info.st_ino) else {
            throw GuestSlotFailure("guest_slot_identity_invalid")
        }
        guard flock(directory, LOCK_EX | LOCK_NB) == 0 else { throw GuestSlotFailure("guest_slot_owned") }

        let names = Set(try FileManager.default.contentsOfDirectory(atPath: path))
        guard names.count <= 16 else { throw GuestSlotFailure("guest_slot_evidence_bound") }
        var claims = Set<String>()
        var stops = Set<String>()
        for name in names {
            let fields = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 2, validNonce(fields[0]) else { throw GuestSlotFailure("guest_slot_evidence_invalid") }
            switch fields[1] {
            case "claim": claims.insert(fields[0])
            case "stopped": stops.insert(fields[0])
            default: throw GuestSlotFailure("guest_slot_evidence_invalid")
            }
        }
        guard stops.isSubset(of: claims) else { throw GuestSlotFailure("guest_slot_evidence_invalid") }
        for id in claims {
            let claim = try read(directory, id + ".claim")
            guard let record = try JSONSerialization.jsonObject(with: claim) as? [String: String],
                  record["nonce"] == id, record["operation"] == "linux-suite",
                  record["slot_device"] == grant["slot_device"], record["slot_inode"] == grant["slot_inode"] else {
                throw GuestSlotFailure("guest_slot_evidence_invalid")
            }
            guard stops.contains(id) else { throw GuestSlotFailure("guest_slot_stop_unacknowledged") }
            guard try read(directory, id + ".stopped") == claim else { throw GuestSlotFailure("guest_slot_stop_unacknowledged") }
        }
        guard !claims.contains(nonce) else { throw GuestSlotFailure("fixture_claim_unavailable_or_replay") }
        // Reserve space for both this claim and its eventual stop record.
        guard names.count <= 14 else { throw GuestSlotFailure("guest_slot_evidence_bound") }
        try writeOnce(directory, nonce + ".claim", ticket)
        transferred = true
        return GuestSlot(directory: directory, nonce: nonce, ticket: ticket)
    }

    func acknowledgeStop() throws {
        guard try Self.read(directory, nonce + ".claim") == ticket else { throw GuestSlotFailure("guest_slot_claim_changed") }
        try Self.writeOnce(directory, nonce + ".stopped", ticket)
    }

    private static func read(_ directory: Int32, _ name: String) throws -> Data {
        let fd = openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw GuestSlotFailure("guest_slot_evidence_unavailable") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_size > 0, info.st_size <= maximumRecordBytes else {
            throw GuestSlotFailure("guest_slot_evidence_invalid")
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let bytes = try file.read(upToCount: maximumRecordBytes + 1), bytes.count == info.st_size else {
            throw GuestSlotFailure("guest_slot_evidence_invalid")
        }
        return bytes
    }

    private static func writeOnce(_ directory: Int32, _ name: String, _ bytes: Data) throws {
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw GuestSlotFailure("guest_slot_persistence_unavailable") }
        defer { close(fd) }
        guard bytes.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == bytes.count,
              fsync(fd) == 0, fsync(directory) == 0 else { throw GuestSlotFailure("guest_slot_persistence_unavailable") }
    }
}
