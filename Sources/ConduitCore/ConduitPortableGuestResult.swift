import CryptoKit
import Foundation

/// Passive observations from one private fixture. This value grants no execution,
/// signalling, replay or guest-slot recovery authority.
public struct ConduitPortableGuestResult: Codable, Equatable, Sendable {
    public let nonce: String
    public let mode: String
    public let checkExitCode: Int32
    public let stdout: Data
    public let stderr: Data
    public let guestStop: String
    public let guestSlot: String
    public let nativeProcessID: Int32
    public let nativeProcessGroupID: Int32
    public let nativeExitCode: Int32?
    public let nativeSignal: Int32?
    public let finalGuestJobReaping: String
    public let serialSHA256: String
    public let nativeSHA256: String
    public let fullControlVerdict: String
}

public enum ConduitPortableGuestDecoder {
    private static let captureLimit = 256 * 1024

    private struct Metadata: Decodable {
        let nonce: String, landlock_abi: UInt64, project_readonly_noexec: Bool
        let scratch_bytes: UInt64, job_memory_bytes: UInt64, job_pids_max: UInt64
        let job_cpu_quota: String
    }
    private struct Row: Decodable {
        let nonce: String, `case`: String
        let confined: Bool, root_observed: Bool
        let exit_code: Int32, signal: Int32
        let deadline: Bool, output_limit: Bool
        let extra_reaped: UInt64, orphan_exit: Int32, job_pids: UInt64
        let oom_kill_delta: UInt64, pids_max_delta: UInt64, throttled_delta: UInt64, wall_ms: UInt64
        let stdout_hex: String, stderr_hex: String
        let stdout_bytes: UInt64, stderr_bytes: UInt64
        let stdout_eof: Bool, stderr_eof: Bool
    }
    private struct Inspection: Decodable {
        let nonce: String, message_hex: String, artifact_hex: String
        let escaped_file_exists: Bool
    }
    private struct Live: Decodable {
        let nonce: String, job_pids: UInt64, child_pid: Int32, job_wall_ms: UInt64
    }
    private struct Native: Decodable {
        let event: String
        let detail: String?
        let nonce: String?
        let state: String?
        let pid: Int32?
        let pgid: Int32?
        let monotonic_ns: UInt64?
    }

    private static func require(_ value: Bool, _ code: String) throws {
        guard value else { throw ConduitOfflineFailure("portable_" + code) }
    }
    private static func parsed<T: Decodable>(_ type: T.Type, _ payload: String) throws -> T {
        do { return try JSONDecoder().decode(type, from: Data(payload.utf8)) }
        catch { throw ConduitOfflineFailure("portable_frame_invalid") }
    }
    private static func hex(_ text: String) throws -> Data {
        let bytes = Array(text.utf8)
        try require(bytes.count <= 8192 && bytes.count % 2 == 0, "stream_invalid")
        func nibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 97...102: return byte - 87
            default: return nil
            }
        }
        var result = Data()
        for offset in stride(from: 0, to: bytes.count, by: 2) {
            guard let high = nibble(bytes[offset]), let low = nibble(bytes[offset + 1]) else {
                throw ConduitOfflineFailure("portable_stream_invalid")
            }
            result.append(high * 16 + low)
        }
        return result
    }
    private static func lines(_ data: Data) throws -> [String] {
        try require(!data.isEmpty && data.count <= captureLimit, "capture_invalid")
        guard let text = String(data: data, encoding: .utf8) else {
            throw ConduitOfflineFailure("portable_capture_invalid")
        }
        // A serial CRLF is one Swift Character. Frame termination is a byte
        // contract; remove exactly its final LF, retaining CR for normalization.
        try require(data.last == 10 && !text.contains("\0"), "capture_incomplete")
        return try String(decoding: data.dropLast(), as: UTF8.self).components(separatedBy: "\n").map { line in
            let normalized = line.hasSuffix("\r") ? String(line.dropLast()) : line
            try require(!normalized.contains("\r"), "frame_invalid")
            return normalized
        }
    }
    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func decode(serial: Data, native: Data, nonce: String, mode: String,
                              expectedCases: [String], nativeProcessID: Int32,
                              nativeProcessGroupID: Int32, nativeExitCode: Int32?, nativeSignal: Int32?,
                              captureComplete: Bool, slotRequired: Bool,
                              slotAcknowledged: Bool) throws -> ConduitPortableGuestResult {
        try require(captureComplete, "capture_incomplete")
        try require(nonce.utf8.count == 64 && nonce.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }, "nonce_invalid")
        try require(["complete", "cooperative", "default"].contains(mode), "mode_invalid")
        try require(!expectedCases.isEmpty && expectedCases.count <= 64
                    && Set(expectedCases).count == expectedCases.count
                    && expectedCases.filter { $0 == "permitted-check" }.count == 1, "cases_invalid")
        try require(nativeProcessID > 1 && nativeProcessGroupID > 1, "native_identity_invalid")
        var rows: [Row] = [], metadataSeen = false, inspected = false, done = false
        var liveRows: [Live] = []
        for line in try lines(serial) {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            let prefix = String(parts[0])
            guard prefix.hasPrefix("M2_") else { continue } // Kernel diagnostics are private capture only.
            try require(parts.count == 2, "frame_invalid")
            let payload = String(parts[1])
            switch prefix {
            case "M2_META":
                try require(!metadataSeen && rows.isEmpty && !inspected && !done, "frame_order")
                let meta = try parsed(Metadata.self, payload)
                try require(meta.nonce == nonce && meta.landlock_abi >= 3 && meta.project_readonly_noexec
                            && meta.scratch_bytes == 1_048_576 && meta.job_memory_bytes == 33_554_432
                            && meta.job_pids_max == 16 && meta.job_cpu_quota == "20000 100000", "profile_invalid")
                metadataSeen = true
            case "M2_RESULT":
                try require(metadataSeen && !inspected && !done && rows.count < expectedCases.count, "frame_order")
                let row = try parsed(Row.self, payload)
                try require(row.case == expectedCases[rows.count] && row.nonce == nonce, "case_identity_invalid")
                try require(row.root_observed && row.job_pids == 0 && row.stdout_eof && row.stderr_eof
                            && row.confined == !row.case.hasPrefix("ambient-"), "job_ownership_incomplete")
                try require((row.exit_code >= 0 && row.exit_code <= 255 && row.signal == 0)
                            || (row.exit_code == -1 && (1...64).contains(row.signal)), "job_exit_invalid")
                try require((-1...255).contains(row.orphan_exit) && !(row.deadline && row.output_limit)
                            && (!(row.deadline || row.output_limit) || row.signal != 0), "job_facts_invalid")
                for (stream, count) in [(row.stdout_hex, row.stdout_bytes), (row.stderr_hex, row.stderr_bytes)] {
                    try require(try hex(stream).count == Int(min(4096, count)), "stream_incomplete")
                }
                rows.append(row)
            case "M2_INSPECT":
                try require(metadataSeen && rows.count == expectedCases.count && !inspected && !done, "frame_order")
                let inspection = try parsed(Inspection.self, payload)
                try require(inspection.nonce == nonce && inspection.message_hex == "61667465720a"
                            && inspection.artifact_hex == "66697874757265" && !inspection.escaped_file_exists,
                            "inspection_invalid")
                inspected = true
            case "M2_DONE":
                try require(inspected && !done && payload == nonce, "completion_invalid")
                done = true
            case "M2_LIVE":
                try require(done && mode != "complete", "live_witness_invalid")
                let witness = try parsed(Live.self, payload)
                try require(witness.nonce == nonce && witness.job_pids == 1 && witness.child_pid > 0
                            && witness.job_wall_ms < 3000, "live_witness_invalid")
                if let previous = liveRows.last {
                    try require(witness.child_pid == previous.child_pid && witness.job_wall_ms > previous.job_wall_ms,
                                "live_witness_invalid")
                }
                liveRows.append(witness)
            case "M2_FATAL": throw ConduitOfflineFailure("portable_guest_fatal")
            default: throw ConduitOfflineFailure("portable_frame_unknown")
            }
        }
        try require(metadataSeen && inspected && done && rows.count == expectedCases.count, "guest_incomplete")
        try require(mode == "complete" || !liveRows.isEmpty, "live_witness_missing")
        guard let check = rows.first(where: { $0.case == "permitted-check" }) else {
            throw ConduitOfflineFailure("portable_check_missing")
        }
        try require((0...125).contains(check.exit_code) && check.signal == 0
                    && !check.deadline && !check.output_limit
                    && check.stdout_bytes <= 4096 && check.stderr_bytes <= 4096, "check_invalid")
        let stdout = try hex(check.stdout_hex), stderr = try hex(check.stderr_hex)
        let events = try lines(native).map { try parsed(Native.self, $0) }
        let expected = ["configuration_validated", "guest_started"] + (mode == "complete"
            ? ["guest_stopped"] : mode == "cooperative"
                ? ["supervisor_term_received", "supervisor_stop_observed"] : ["supervisor_term_received"])
        try require(events.map(\.event) == expected, "native_lifecycle_invalid")
        try require(events[0].detail == "cpu=1 memory=134217728 nic=0 disks=0 shares=0 sockets=0 serial=1"
                    && events[1].detail == "", "native_profile_invalid")
        if mode == "complete" {
            try require(nativeExitCode == 0 && nativeSignal == nil && events[2].detail == "", "native_exit_invalid")
        } else {
            try require(mode == "cooperative" ? nativeExitCode == 124 && nativeSignal == nil
                        : nativeExitCode == nil && nativeSignal == 15, "native_exit_invalid")
            for (index, event) in events.enumerated() where index >= 2 {
                try require(event.nonce == nonce && event.pid == nativeProcessID && event.pgid == nativeProcessGroupID
                            && event.state == (index == 2 ? "running" : "stopped")
                            && event.monotonic_ns != nil, "native_stop_invalid")
            }
            if mode == "cooperative" {
                try require(events[3].monotonic_ns! >= events[2].monotonic_ns!, "native_stop_invalid")
            }
        }
        let stopped = mode != "default"
        try require(slotRequired ? slotAcknowledged == stopped : !slotAcknowledged, "slot_facts_invalid")
        return ConduitPortableGuestResult(nonce: nonce, mode: mode, checkExitCode: check.exit_code,
            stdout: stdout, stderr: stderr, guestStop: stopped ? "observed" : "unknown",
            guestSlot: slotRequired ? (slotAcknowledged ? "acknowledged" : "held") : "not_used",
            nativeProcessID: nativeProcessID, nativeProcessGroupID: nativeProcessGroupID,
            nativeExitCode: nativeExitCode, nativeSignal: nativeSignal,
            finalGuestJobReaping: mode == "complete" ? "observed" : "unobserved",
            serialSHA256: hash(serial), nativeSHA256: hash(native), fullControlVerdict: "external_oracle_required")
    }
}
