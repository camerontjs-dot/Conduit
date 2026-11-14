import CryptoKit
import Foundation
import XCTest
@testable import ConduitCore

/// Synthetic protocol frames only; these tests do not execute or qualify a VM.
final class ConduitPortableGuestResultTests: XCTestCase {
    private let nonce = String(repeating: "a", count: 64)
    private let cases = ["permitted-check", "outside-read"]
    private struct Frames { var serial: [String]; var native: [String] }

    private func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
    private func row(_ name: String, exit: Int = 0) -> [String: Any] {
        ["nonce": nonce, "case": name, "confined": true, "root_observed": true,
         "exit_code": exit, "signal": 0, "deadline": false, "output_limit": false,
         "extra_reaped": 0, "orphan_exit": -1, "job_pids": 0, "oom_kill_delta": 0,
         "pids_max_delta": 0, "throttled_delta": 0, "wall_ms": 1,
         "stdout_hex": "00ff0a", "stderr_hex": "6572720a", "stdout_bytes": 3,
         "stderr_bytes": 4, "stdout_eof": true, "stderr_eof": true]
    }
    private func frames(mode: String = "complete", exit: Int = 0) throws -> Frames {
        var serial = [
            "kernel diagnostic", "M2_META " + (try json([
                "nonce": nonce, "landlock_abi": 3, "project_readonly_noexec": true,
                "scratch_bytes": 1_048_576, "job_memory_bytes": 33_554_432,
                "job_pids_max": 16, "job_cpu_quota": "20000 100000"])),
            "M2_RESULT " + (try json(row(cases[0], exit: exit))),
            "M2_RESULT " + (try json(row(cases[1]))),
            "M2_INSPECT " + (try json(["nonce": nonce, "message_hex": "61667465720a",
                "artifact_hex": "66697874757265", "escaped_file_exists": false])),
            "M2_DONE " + nonce
        ]
        var native = [try json(["event": "configuration_validated",
            "detail": "cpu=1 memory=134217728 nic=0 disks=0 shares=0 sockets=0 serial=1"]),
            try json(["event": "guest_started", "detail": ""])]
        if mode == "complete" {
            native.append(try json(["event": "guest_stopped", "detail": ""]))
        } else {
            serial.append("M2_LIVE " + (try json(["nonce": nonce, "job_pids": 1, "child_pid": 7, "job_wall_ms": 100])))
            native.append(try json(["event": "supervisor_term_received", "nonce": nonce,
                "state": "running", "pid": 100, "pgid": 99, "monotonic_ns": 10]))
            if mode == "cooperative" {
                native.append(try json(["event": "supervisor_stop_observed", "nonce": nonce,
                    "state": "stopped", "pid": 100, "pgid": 99, "monotonic_ns": 11]))
            }
        }
        return Frames(serial: serial, native: native)
    }
    private func bytes(_ lines: [String]) -> Data { Data((lines.joined(separator: "\n") + "\n").utf8) }
    private func decode(_ value: Frames, mode: String = "complete", complete: Bool = true,
                        required: Bool = false, acknowledged: Bool = false,
                        exit: Int32? = 0, signal: Int32? = nil,
                        expected: [String]? = nil) throws -> ConduitPortableGuestResult {
        try ConduitPortableGuestDecoder.decode(serial: bytes(value.serial), native: bytes(value.native),
            nonce: nonce, mode: mode, expectedCases: expected ?? cases,
            nativeProcessID: 100, nativeProcessGroupID: 99, nativeExitCode: exit, nativeSignal: signal,
            captureComplete: complete, slotRequired: required, slotAcknowledged: acknowledged)
    }
    private func changed(_ original: Frames, index: Int = 2, key: String, value: Any?) throws -> Frames {
        var result = original
        let line = result.serial[index]
        let separator = try XCTUnwrap(line.firstIndex(of: " "))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line[line.index(after: separator)...].utf8)) as? [String: Any])
        object[key] = value
        result.serial[index] = String(line[...separator]) + (try json(object))
        return result
    }
    private func refuses(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertTrue(($0 as? ConduitOfflineFailure)?.code.hasPrefix("portable_") == true, file: file, line: line)
        }
    }

    func testExactZeroAndNonzeroCheckBytesArePassiveCodableObservations() throws {
        for code in [0, 23, 125] {
            let input = try frames(exit: code)
            let result = try decode(input)
            XCTAssertEqual(result.checkExitCode, Int32(code))
            XCTAssertEqual(result.stdout, Data([0, 255, 10]))
            XCTAssertEqual(result.stderr, Data("err\n".utf8))
            XCTAssertEqual(result.guestStop, "observed")
            XCTAssertEqual(result.guestSlot, "not_used")
            XCTAssertEqual(result.finalGuestJobReaping, "observed")
            XCTAssertEqual(result.fullControlVerdict, "external_oracle_required")
            // outside-read's synthetic exit 0 is deliberately not a denial verdict.
            XCTAssertEqual(result.serialSHA256, SHA256.hash(data: bytes(input.serial)).map { String(format: "%02x", $0) }.joined())
            XCTAssertEqual(try JSONDecoder().decode(ConduitPortableGuestResult.self, from: JSONEncoder().encode(result)), result)
        }
    }
    func testTimeoutKeepsNativeStopAndFinalJobReapingSeparate() throws {
        let cooperative = try decode(frames(mode: "cooperative"), mode: "cooperative", required: true, acknowledged: true, exit: 124)
        XCTAssertEqual(cooperative.guestStop, "observed")
        XCTAssertEqual(cooperative.guestSlot, "acknowledged")
        XCTAssertEqual(cooperative.finalGuestJobReaping, "unobserved")
        let lost = try decode(frames(mode: "default"), mode: "default", required: true, exit: nil, signal: 15)
        XCTAssertEqual(lost.guestStop, "unknown")
        XCTAssertEqual(lost.guestSlot, "held")
        XCTAssertEqual(lost.finalGuestJobReaping, "unobserved")
    }
    func testSerialCRLFAndMixedNativeLFKeepExactCaptureIdentity() throws {
        let input = try frames()
        let serial = Data((input.serial.joined(separator: "\r\n") + "\r\n").utf8)
        func observed(_ data: Data) throws -> ConduitPortableGuestResult {
            try ConduitPortableGuestDecoder.decode(serial: data, native: bytes(input.native), nonce: nonce,
                mode: "complete", expectedCases: cases, nativeProcessID: 100, nativeProcessGroupID: 99,
                nativeExitCode: 0, nativeSignal: nil, captureComplete: true, slotRequired: false, slotAcknowledged: false)
        }
        let result = try observed(serial)
        XCTAssertEqual(result.stdout, Data([0, 255, 10]))
        XCTAssertEqual(result.serialSHA256, SHA256.hash(data: serial).map { String(format: "%02x", $0) }.joined())
        refuses { _ = try observed(serial.dropLast()) }
        refuses { _ = try observed(Data(String(decoding: serial, as: UTF8.self).replacingOccurrences(of: "M2_DONE", with: "M2_\rDONE").utf8)) }
    }
    func testCaptureAndMissingBackendFailClosed() throws {
        let input = try frames()
        refuses { _ = try decode(input, complete: false) }
        for bad in [Data(), Data([255]), Data(repeating: 97, count: 256 * 1024 + 1), Data("M2_DONE".utf8)] {
            refuses {
                _ = try ConduitPortableGuestDecoder.decode(serial: bad, native: self.bytes(input.native), nonce: self.nonce,
                    mode: "complete", expectedCases: self.cases, nativeProcessID: 100, nativeProcessGroupID: 99,
                    nativeExitCode: 0, nativeSignal: nil, captureComplete: true, slotRequired: false, slotAcknowledged: false)
            }
            refuses {
                _ = try ConduitPortableGuestDecoder.decode(serial: self.bytes(input.serial), native: bad, nonce: self.nonce,
                    mode: "complete", expectedCases: self.cases, nativeProcessID: 100, nativeProcessGroupID: 99,
                    nativeExitCode: 0, nativeSignal: nil, captureComplete: true, slotRequired: false, slotAcknowledged: false)
            }
        }
    }
    func testMissingDuplicateForeignReorderedAndFatalFramesRefuse() throws {
        let input = try frames()
        for index in 1..<input.serial.count {
            var missing = input; missing.serial.remove(at: index)
            refuses { _ = try decode(missing) }
            var duplicate = input; duplicate.serial.insert(input.serial[index], at: index)
            refuses { _ = try decode(duplicate) }
        }
        var reordered = input; reordered.serial.swapAt(2, 3)
        refuses { _ = try decode(reordered) }
        refuses { _ = try decode(changed(input, key: "case", value: "foreign-check")) }
        refuses { _ = try decode(changed(input, key: "nonce", value: String(repeating: "b", count: 64))) }
        for line in ["M2_FATAL {\"where\":\"synthetic\",\"errno\":5}", "M2_UNKNOWN {}", "M2_RESULT {", "M2_DONE"] {
            var altered = input; altered.serial.append(line)
            refuses { _ = try decode(altered) }
        }
        refuses { _ = try decode(input, expected: ["permitted-check", "permitted-check"]) }
    }
    func testIncompleteStreamsAndContradictoryJobFactsRefuse() throws {
        let input = try frames()
        for (key, value) in [("stdout_eof", false), ("stderr_eof", false), ("root_observed", false),
                             ("confined", false), ("deadline", true), ("output_limit", true)] {
            refuses { _ = try decode(changed(input, key: key, value: value)) }
        }
        for (key, value) in [("job_pids", 1), ("stdout_bytes", 4), ("stderr_bytes", 5),
                             ("exit_code", 126), ("signal", 9), ("extra_reaped", -1)] {
            refuses { _ = try decode(changed(input, key: key, value: value)) }
        }
        for value in ["0", "zz", String(repeating: "a", count: 8194)] {
            refuses { _ = try decode(changed(input, key: "stdout_hex", value: value)) }
        }
        refuses { _ = try decode(changed(input, key: "stdout_eof", value: nil)) }
        refuses { _ = try decode(changed(input, key: "stdout_eof", value: "true")) }
        refuses { _ = try decode(changed(input, index: 1, key: "job_memory_bytes", value: 1)) }
        refuses { _ = try decode(changed(input, index: 4, key: "escaped_file_exists", value: true)) }
    }
    func testNativeExitLifecycleIdentityAndSlotContradictionsRefuse() throws {
        let input = try frames()
        refuses { _ = try decode(input, exit: 124) }
        refuses { _ = try decode(input, signal: 15) }
        refuses { _ = try decode(input, required: true) }
        refuses { _ = try decode(input, acknowledged: true) }
        var missingStop = input; missingStop.native.removeLast()
        refuses { _ = try decode(missingStop) }
        var guestError = input; guestError.native[2] = try json(["event": "guest_error", "detail": "synthetic failure"])
        refuses { _ = try decode(guestError) }
        var duplicate = input; duplicate.native.append(input.native[2])
        refuses { _ = try decode(duplicate) }
        let live = try frames(mode: "cooperative")
        for (key, value) in [("nonce", "foreign"), ("pid", 101), ("pgid", 98),
                             ("state", "running"), ("monotonic_ns", 9)] as [(String, Any)] {
            var altered = live
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(altered.native[3].utf8)) as? [String: Any])
            object[key] = value; altered.native[3] = try json(object)
            refuses { _ = try decode(altered, mode: "cooperative", exit: 124) }
        }
        refuses { _ = try decode(live, mode: "cooperative", exit: 0) }
        let lost = try frames(mode: "default")
        refuses { _ = try decode(lost, mode: "default", required: true, acknowledged: true, exit: nil, signal: 15) }
        refuses { _ = try decode(lost, mode: "default", exit: nil, signal: 9) }
        var noWitness = live; noWitness.serial.removeLast()
        refuses { _ = try decode(noWitness, mode: "cooperative", exit: 124) }
        refuses { _ = try decode(changed(live, index: 6, key: "job_wall_ms", value: 3000), mode: "cooperative", exit: 124) }
    }
}
