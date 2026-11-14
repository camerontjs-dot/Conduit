import Darwin
import Foundation
@testable import ConduitCore

// Compiled only into an owned fixture with generated private binding/key pins.
// This executable is CDS1's root R, not a public application execution route.
@main
struct NativeOfflineWorker {
    private static func require(_ value: Bool, _ code: String) throws {
        guard value else { throw ConduitOfflineFailure("portable_" + code) }
    }
    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                try require(count > 0, "stream_write_failed")
                offset += count
            }
        }
    }
    private static func save(_ object: [String: Any], _ name: String, _ root: ConduitPortableDirectory) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) + Data("\n".utf8)
        try ConduitPortableOfflineAuthority.persist(data, name: name, root: root)
    }

    private final class Stream {
        let outputFD: Int32
        var pipeFD: Int32 = -1
        var bytes = Data()
        var total: Int64 = 0
        var eof = false
        var failed = false
        var overflow = false
        let limit: Int
        init(outputFD: Int32, limit: Int) { self.outputFD = outputFD; self.limit = limit }
        deinit { if pipeFD >= 0 { close(pipeFD) }; close(outputFD) }
        func drain() {
            guard !eof && !failed else { return }
            var buffer = [UInt8](repeating: 0, count: 16_384)
            for _ in 0..<16 {
                let count = read(pipeFD, &buffer, buffer.count)
                if count == 0 { eof = true; return }
                if count < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { return }
                    failed = true; return
                }
                total += Int64(count)
                let retained = Data(buffer.prefix(min(count, max(0, limit - bytes.count))))
                bytes.append(retained)
                do { try NativeOfflineWorker.writeAll(outputFD, retained) }
                catch { failed = true; return }
                overflow = total > Int64(limit)
            }
        }
        func sync() throws { try NativeOfflineWorker.require(fsync(outputFD) == 0, "capture_persistence_failed") }
    }
    private final class Capture {
        let stdout: Stream
        let stderr: Stream
        var timedOut = false
        var forced = false
        var signalError: Int32 = 0
        var started = ProcessInfo.processInfo.systemUptime
        var ended = ProcessInfo.processInfo.systemUptime
        init(root: ConduitPortableDirectory, limit: Int) throws {
            try NativeOfflineWorker.require(try ConduitPortableDirectory.observe(root.path, privateDirectory: true) == root,
                                            "root_changed")
            let directory = try ConduitOfflineFS.openAbsolute(root.path, directory: true)
            defer { close(directory) }
            let out = openat(directory, "supervised-serial.stdout", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            try NativeOfflineWorker.require(out >= 0, "capture_unavailable")
            let err = openat(directory, "supervised-host.stderr", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard err >= 0 else { close(out); throw ConduitOfflineFailure("portable_capture_unavailable") }
            stdout = Stream(outputFD: out, limit: limit)
            stderr = Stream(outputFD: err, limit: limit)
            try NativeOfflineWorker.require(fsync(directory) == 0, "capture_persistence_failed")
        }
        var complete: Bool { stdout.eof && stderr.eof && !stdout.failed && !stderr.failed
            && !stdout.overflow && !stderr.overflow && !timedOut && !forced && signalError == 0 }

        func run(child: inout CNWChild, deadline: Double, forceTermination: Bool) {
            started = ProcessInfo.processInfo.systemUptime
            var terminationAt: Double?, killSent = false
            while true {
                stdout.drain(); stderr.drain()
                let waited = cnw_wait(&child)
                let now = ProcessInfo.processInfo.systemUptime
                let streamsDone = (stdout.eof || stdout.failed) && (stderr.eof || stderr.failed)
                if waited == 1 && streamsDone { break }
                if now - started >= deadline { timedOut = true }
                if terminationAt == nil && (forceTermination || timedOut || stdout.overflow || stderr.overflow
                                            || stdout.failed || stderr.failed || waited < 0) {
                    forced = forceTermination || stdout.overflow || stderr.overflow || stdout.failed || stderr.failed || waited < 0
                    terminationAt = now
                    if child.reaped == 0 && child.wait_lost == 0 {
                        let error = cnw_signal_child(&child, SIGTERM)
                        if error != 0 && error != ESRCH { signalError = error }
                    }
                }
                if let terminationAt {
                    if !killSent && now - terminationAt >= 0.5 {
                        killSent = true
                        if child.reaped == 0 && child.wait_lost == 0 {
                            let error = cnw_signal_child(&child, SIGKILL)
                            if error != 0 && error != ESRCH { signalError = error }
                        }
                    }
                    if now - terminationAt >= 1.5 { break }
                }
                var items = [pollfd(fd: stdout.eof || stdout.failed ? -1 : stdout.pipeFD,
                                    events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0),
                             pollfd(fd: stderr.eof || stderr.failed ? -1 : stderr.pipeFD,
                                    events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)]
                let itemCount = nfds_t(items.count)
                if poll(&items, itemCount, 5) < 0 && errno != EINTR {
                    stdout.failed = true; stderr.failed = true
                }
            }
            stdout.drain(); stderr.drain()
            _ = cnw_wait(&child)
            ended = ProcessInfo.processInfo.systemUptime
        }
        func sync() throws { try stdout.sync(); try stderr.sync() }
        func facts(_ child: CNWChild) -> [String: Any] {
            let code: Any = child.reaped == 0 || child.wait_lost != 0 ? NSNull()
                : child.termination_signal == 0 ? child.exit_code : -child.termination_signal
            return ["exit_code": code, "host_timeout": timedOut,
                    "capture_truncated": stdout.overflow || stderr.overflow,
                    "observed_bytes": ["stdout": stdout.total, "stderr": stderr.total],
                    "native_wall_s": ended - started,
                    "stdout_eof": stdout.eof, "stderr_eof": stderr.eof,
                    "capture_io_failed": stdout.failed || stderr.failed,
                    "exact_child_reaped": child.reaped != 0 && child.wait_lost == 0,
                    "setup_error": child.setup_error, "signal_error": signalError]
        }
    }

    private static func execute(_ grant: ConduitPortableOfflineGrant,
                                authority: ConduitPortableOfflineAuthority, reservedFD: Int32) throws -> Int32 {
        let binding = grant.binding, root = binding.fixtureRoot
        let ticket = try ConduitPortableOfflineAuthority.read(root.path + "/native-ticket.json", maximumBytes: 16_384)
        try require(ConduitPortableOfflineAuthority.digest(ticket) == binding.nativeTicketSHA256, "native_ticket_changed")
        let capture = try Capture(root: root, limit: binding.profile.maximumNativeCaptureBytes)
        var child = CNWChild()
        let fd3OccupiedAtSpawn = fcntl(3, F_GETFD) >= 0
        let spawnError = binding.nativeExecutable.path.withCString { executable in
            binding.kernel.path.withCString { kernel in
                binding.initramfs.path.withCString { initrd in
                    ticket.withUnsafeBytes { raw in
                        cnw_spawn(&child, executable, kernel, initrd, raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
                    }
                }
            }
        }
        try require(spawnError == 0 && child.pid > 0, spawnError == ECANCELED ? "term_before_native_spawn" : "native_spawn_failed")
        capture.stdout.pipeFD = child.stdout_fd; capture.stderr.pipeFD = child.stderr_fd
        let nativePGID = getpgid(child.pid)
        var firstError: Error?
        do { try save(["pid": child.pid, "pgid": nativePGID], "live-native-child.json", root) }
        catch { firstError = error }
        let forceTermination = firstError != nil || child.setup_error != 0 || nativePGID != getpgrp()
        capture.run(child: &child, deadline: binding.vmDeadlineSeconds + 1, forceTermination: forceTermination)
        var lifecycleSaved = false
        func lifecycle(_ reraise: Bool) throws {
            try save(["native_pid": child.pid, "native_pgid": nativePGID,
                      "child_reaped": child.reaped != 0, "wait_lost": child.wait_lost != 0,
                      "wait_status": child.wait_status,
                      "native_exit_code": child.exit_code >= 0 ? child.exit_code as Any : NSNull(),
                      "native_signal": child.termination_signal == 0 ? NSNull() : child.termination_signal as Any,
                      "term_observed": cnw_term_observed() != 0, "term_forwarded": child.term_forwarded != 0,
                      "reraiseRequested": reraise, "reserved_fd": reservedFD,
                      "fd3_occupied_at_spawn": fd3OccupiedAtSpawn,
                      "setup_error": child.setup_error], "native-bridge-lifecycle.json", root)
            lifecycleSaved = true
        }
        do {
            try capture.sync()
            try save(capture.facts(child), "supervised-vm-capture.json", root)
            if let firstError { throw firstError }
            try require(child.setup_error == 0 && child.wait_lost == 0 && child.reaped != 0
                        && nativePGID == getpgrp(), "native_ownership_incomplete")
            var acknowledged = false
            if let slot = binding.slot {
                let claim = try? ConduitPortableOfflineAuthority.read(slot.path + "/" + binding.nonce + ".claim", maximumBytes: 16_384)
                let stopped = try? ConduitPortableOfflineAuthority.read(slot.path + "/" + binding.nonce + ".stopped", maximumBytes: 16_384)
                acknowledged = claim == ticket && stopped == ticket
            }
            let result = try ConduitPortableGuestDecoder.decode(serial: capture.stdout.bytes, native: capture.stderr.bytes,
                nonce: binding.nonce, mode: binding.mode, expectedCases: binding.expectedCases,
                nativeProcessID: child.pid, nativeProcessGroupID: nativePGID,
                nativeExitCode: child.exit_code < 0 ? nil : child.exit_code,
                nativeSignal: child.termination_signal == 0 ? nil : child.termination_signal,
                captureComplete: capture.complete, slotRequired: binding.slot != nil, slotAcknowledged: acknowledged)
            let term = cnw_term_observed() != 0
            try require(binding.mode == "complete" || term, "supervisor_term_unobserved")
            try ConduitPortableOfflineAuthority.persist(authority.encodeGuestResult(result, grant: grant),
                name: "native-guest-receipt.json", root: root)
            try save(["exit_code": result.checkExitCode, "guest_stop": result.guestStop == "observed" ? "OBSERVED" : "UNKNOWN",
                      "mode": binding.mode, "stdout_bytes": result.stdout.count, "stderr_bytes": result.stderr.count],
                     "supervised-command.json", root)
            try lifecycle(term)
            try writeAll(STDOUT_FILENO, result.stdout)
            try writeAll(STDERR_FILENO, result.stderr)
            if term {
                _ = cnw_reraise_term()
                throw ConduitOfflineFailure("portable_term_reraise_failed")
            }
            return result.checkExitCode
        } catch {
            if !lifecycleSaved { try? lifecycle(false) }
            throw error
        }
    }

    static func main() {
        var admitted = false
        let reservedFD = open("/dev/null", O_RDONLY | O_CLOEXEC)
        defer { if reservedFD >= 0 { close(reservedFD) } }
        do {
            try require(reservedFD >= 0 && cnw_install_term_handler() == 0, "native_signal_setup_failed")
            try require(CommandLine.arguments.count == 1 && CommandLine.arguments[0].hasPrefix("/"), "native_arguments_invalid")
            let expected = try JSONDecoder().decode(ConduitPortableOfflineBinding.self, from: portableFixtureBindingData)
            let authority = try ConduitPortableOfflineAuthority(fixtureKey: portableFixtureAuthorityKey)
            let permit = try ConduitPortableOfflineAuthority.read(expected.fixtureRoot.path + "/native-permit.json", maximumBytes: 16_384)
            let grant = try authority.redeem(permit, expected: expected, launcherPath: CommandLine.arguments[0])
            admitted = true
            try require(cnw_term_observed() == 0, "term_before_native_admission")
            try ConduitPortableOfflineAuthority.persist(grant.encodedPermit, name: "native-bridge.claim", root: expected.fixtureRoot)
            try ConduitPortableOfflineAuthority.persist(Data("entered\n".utf8), name: "bridge-entries", root: expected.fixtureRoot)
            exit(try execute(grant, authority: authority, reservedFD: reservedFD))
        } catch {
            let code = (error as? ConduitOfflineFailure)?.code ?? (admitted ? "portable_native_worker_failed" : "portable_execution_authority_unavailable")
            try? writeAll(STDERR_FILENO, Data((code.hasPrefix("portable_") ? code : "portable_execution_authority_unavailable").utf8) + Data("\n".utf8))
            exit(admitted ? 125 : 77)
        }
    }
}
