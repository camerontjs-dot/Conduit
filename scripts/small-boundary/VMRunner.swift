import Foundation
import Virtualization
import CryptoKit
import Darwin

// Fixture actuator only. No app integration, host shares, NIC or disk devices.
func event(_ name: String, _ detail: String = "") {
    let bytes = try! JSONSerialization.data(withJSONObject: ["event": name, "detail": detail], options: [.sortedKeys])
    FileHandle.standardError.write(bytes + Data("\n".utf8))
}

final class Owner: NSObject, VZVirtualMachineDelegate {
    var machine: VZVirtualMachine!
    var ending = false
    var timedOut = false
    var supervisorStopping = false
    var termSource: DispatchSourceSignal?
    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        if supervisorStopping { return }  // The stop callback owns its acknowledgement.
        event("guest_stopped"); ending = true; exit(timedOut ? 124 : 0)
    }
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        event("guest_error", error.localizedDescription); ending = true; exit(3)
    }
    func liveEvent(_ name: String) {
        let state = machine.state
        let row: [String: Any] = [
            "event": name, "nonce": fixtureNonce,
            "state": state == .running ? "running" : state == .stopped ? "stopped" : String(state.rawValue),
            "pid": getpid(), "pgid": getpgrp(), "monotonic_ns": DispatchTime.now().uptimeNanoseconds
        ]
        let bytes = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        FileHandle.standardError.write(bytes + Data("\n".utf8))
    }
    func installTimeoutWitness() {
        guard fixtureTermMode != "none" else { return }
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [self] in
            guard !ending && !supervisorStopping else { return }
            liveEvent("supervisor_term_received")
            if fixtureTermMode == "default" {
                signal(SIGTERM, SIG_DFL)
                _ = kill(getpid(), SIGTERM)
                return
            }
            guard machine.state == .running && machine.canStop else {
                liveEvent("supervisor_stop_unavailable"); exit(125)
            }
            supervisorStopping = true
            machine.stop { error in
                guard error == nil && self.machine.state == .stopped else {
                    self.liveEvent("supervisor_stop_unconfirmed"); exit(125)
                }
                self.liveEvent("supervisor_stop_observed")
                self.ending = true
                exit(124)
            }
        }
        termSource = source
        source.resume()
    }
    func start(kernel: URL, initrd: URL) throws {
        let loader = VZLinuxBootLoader(kernelURL: kernel)
        loader.initialRamdiskURL = initrd
        loader.commandLine = "console=hvc0 loglevel=3 panic=0 rdinit=/init"
        let config = VZVirtualMachineConfiguration()
        config.platform = VZGenericPlatformConfiguration()
        config.bootLoader = loader
        config.cpuCount = 1
        config.memorySize = 128 * 1024 * 1024
        let console = VZVirtioConsoleDeviceSerialPortConfiguration()
        console.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil,
                                                             fileHandleForWriting: FileHandle.standardOutput)
        config.serialPorts = [console]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.networkDevices = []
        config.storageDevices = []
        config.directorySharingDevices = []
        config.socketDevices = []
        try config.validate()
        event("configuration_validated", "cpu=1 memory=134217728 nic=0 disks=0 shares=0 sockets=0 serial=1")
        machine = VZVirtualMachine(configuration: config)
        machine.delegate = self
        installTimeoutWitness()
        machine.start { result in
            switch result {
            case .success: event("guest_started")
            case .failure(let error): event("start_failed", error.localizedDescription); exit(2)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + fixtureDeadlineSeconds) { [self] in
            guard !ending && !supervisorStopping else { return }
            timedOut = true
            event("deadline_stop_requested")
            machine.stop { error in
                if let error { event("ownership_unknown", error.localizedDescription); exit(125) }
                event("deadline_stop_observed"); exit(124)
            }
        }
    }
}

// FixtureGate.swift is generated only in the owned run directory, then linked
// into this actuator. Its digest and claim path cannot be supplied as argv or
// settings. The trusted host owner is outside this development threat model.
func refuse(_ reason: String) -> Never { event("authority_refused", reason); exit(77) }
func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
func assetDigest(_ path: String) -> String {
    var info = stat()
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { refuse("asset_unavailable") }
    defer { close(fd) }
    guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_nlink == 1,
          info.st_mode & S_IFMT == S_IFREG, info.st_size > 0,
          info.st_size <= 64 * 1024 * 1024 else { refuse("asset_identity") }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    guard let bytes = try? file.readToEnd() else { refuse("asset_read") }
    return digest(bytes)
}
guard CommandLine.arguments.count == 4, CommandLine.arguments[3] == "--fixture-fd=3" else { refuse("fixture_capability_absent") }
var pipeInfo = stat()
guard fstat(3, &pipeInfo) == 0, pipeInfo.st_mode & S_IFMT == S_IFIFO else { refuse("fixture_pipe_required") }
let pipe = FileHandle(fileDescriptor: 3, closeOnDealloc: true)
guard let ticket = try? pipe.read(upToCount: 16385), ticket.count <= 16384,
      digest(ticket) == fixtureGrantDigest else { refuse("fixture_capability_invalid") }
try? pipe.close()
guard let grant = try? JSONSerialization.jsonObject(with: ticket) as? [String: String],
      grant["operation"] == "linux-suite",
      assetDigest(CommandLine.arguments[1]) == grant["kernel_sha256"],
      assetDigest(CommandLine.arguments[2]) == grant["initrd_sha256"] else { refuse("fixture_assets_changed") }
let claim = open(fixtureClaimPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
guard claim >= 0 else { refuse("fixture_claim_unavailable_or_replay") }
guard ticket.withUnsafeBytes({ write(claim, $0.baseAddress, $0.count) }) == ticket.count,
      fsync(claim) == 0 else { close(claim); refuse("fixture_claim_persistence") }
close(claim)
let owner = Owner()
do {
    try owner.start(kernel: URL(fileURLWithPath: CommandLine.arguments[1]),
                    initrd: URL(fileURLWithPath: CommandLine.arguments[2]))
    dispatchMain()
} catch { event("configuration_failed", error.localizedDescription); exit(2) }
