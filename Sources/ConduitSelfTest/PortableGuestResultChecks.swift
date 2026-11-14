import ConduitCore
import Foundation

/// Synthetic decoder checks only. No VM or native execution is performed.
func runPortableGuestResultSelfChecks(_ report: (String, Bool) -> Void) {
    do {
        let profile = ConduitPortableOfflineProfile.v1
        var profileJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as! [String: Any]
        profileJSON["memoryBytes"] = 1
        let changed = try JSONDecoder().decode(ConduitPortableOfflineProfile.self,
            from: JSONSerialization.data(withJSONObject: profileJSON))
        report("portable profile has a distinct identity and decoded budgets are compared",
               profile.profileID == "conduit-portable-offline-check/v1" && profile.memoryBytes == 134_217_728
                   && profile.cpuCount == 1 && changed != profile && ConduitOfflineProfile.v1.cpuCount == 2)
        let nonce = String(repeating: "c", count: 64)
        func json(_ object: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        }
        let meta = try json(["nonce": nonce, "landlock_abi": 3, "project_readonly_noexec": true,
            "scratch_bytes": 1_048_576, "job_memory_bytes": 33_554_432,
            "job_pids_max": 16, "job_cpu_quota": "20000 100000"])
        let row = try json(["nonce": nonce, "case": "permitted-check", "confined": true,
            "root_observed": true, "exit_code": 7, "signal": 0, "deadline": false,
            "output_limit": false, "extra_reaped": 0, "orphan_exit": -1, "job_pids": 0,
            "oom_kill_delta": 0, "pids_max_delta": 0, "throttled_delta": 0, "wall_ms": 1,
            "stdout_hex": "00ff", "stderr_hex": "", "stdout_bytes": 2, "stderr_bytes": 0,
            "stdout_eof": true, "stderr_eof": true])
        let inspect = try json(["nonce": nonce, "message_hex": "61667465720a",
            "artifact_hex": "66697874757265", "escaped_file_exists": false])
        let serialText = "M2_META \(meta)\nM2_RESULT \(row)\nM2_INSPECT \(inspect)\nM2_DONE \(nonce)\n"
        let nativeText = (try [
            json(["event": "configuration_validated", "detail": "cpu=1 memory=134217728 nic=0 disks=0 shares=0 sockets=0 serial=1"]),
            json(["event": "guest_started", "detail": ""]),
            json(["event": "guest_stopped", "detail": ""])
        ]).joined(separator: "\n") + "\n"
        func decode(_ serial: String, _ native: String, complete: Bool = true,
                    slotRequired: Bool = false, slotAcknowledged: Bool = false) throws -> ConduitPortableGuestResult {
            try ConduitPortableGuestDecoder.decode(serial: Data(serial.utf8), native: Data(native.utf8),
                nonce: nonce, mode: "complete", expectedCases: ["permitted-check"],
                nativeProcessID: 123, nativeProcessGroupID: 122, nativeExitCode: 0, nativeSignal: nil,
                captureComplete: complete, slotRequired: slotRequired, slotAcknowledged: slotAcknowledged)
        }
        func refused(_ body: () throws -> Void) -> Bool {
            do { try body(); return false }
            catch let error as ConduitOfflineFailure { return error.code.hasPrefix("portable_") }
            catch { return false }
        }
        let result = try decode(serialText, nativeText)
        let serialCRLF = serialText.replacingOccurrences(of: "\n", with: "\r\n")
        report("portable serial CRLF is a byte terminator with complete native LF capture",
               try decode(serialCRLF, nativeText).stdout == result.stdout
                   && refused { _ = try decode(String(serialCRLF.dropLast()), nativeText) })
        report("portable guest decoder preserves exact nonzero check bytes without granting authority",
               result.checkExitCode == 7 && result.stdout == Data([0, 255]) && result.stderr.isEmpty
                && result.guestStop == "observed" && result.guestSlot == "not_used"
                && result.fullControlVerdict == "external_oracle_required")
        report("portable guest decoder refuses incomplete capture and missing native backend",
               refused { _ = try decode(serialText, nativeText, complete: false) }
                && refused { _ = try decode(serialText, "") })
        report("portable guest decoder refuses duplicate completion and foreign nonce",
               refused { _ = try decode(serialText + "M2_DONE \(nonce)\n", nativeText) }
                && refused { _ = try decode(serialText.replacingOccurrences(of: nonce, with: String(repeating: "d", count: 64)), nativeText) })
        report("portable guest decoder refuses missing stop and contradictory slot acknowledgement",
               refused { _ = try decode(serialText, nativeText.replacingOccurrences(of: "guest_stopped", with: "guest_error")) }
                && refused { _ = try decode(serialText, nativeText, slotRequired: true) }
                && refused { _ = try decode(serialText, nativeText, slotAcknowledged: true) })
        report("portable guest observations round trip without acquiring slot or execution authority",
               try JSONDecoder().decode(ConduitPortableGuestResult.self, from: JSONEncoder().encode(result)) == result)
    } catch {
        report("portable guest synthetic decoder checks: \(error.localizedDescription)", false)
    }
}
