import Foundation
import Dispatch
import Darwin

// Native signal apparatus only. The two Owner methods are extracted from the
// selected VMRunner source. No Virtualization framework or VM is used here.
func witnessRow(_ row: [String: Any]) {
    let bytes = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
    FileHandle.standardError.write(bytes + Data("\n".utf8))
}
func witnessReady() {
    witnessRow(["event": "witness_ready", "nonce": fixtureNonce,
                "pid": getpid(), "pgid": getpgrp(), "no_vm": true])
}

// Log the handoff request, then physically call Darwin. This common observer
// is not a kernel syscall trace and does not report successful delivery.
func kill(_ pid: pid_t, _ signalNumber: Int32) -> Int32 {
    witnessRow(["event": "self_signal_requested", "nonce": fixtureNonce,
                "pid": getpid(), "target_pid": pid, "signal": signalNumber])
    return Darwin.kill(pid, signalNumber)
}

enum UnavailableVMState: Int { case unavailable = -1, running = 1, stopped = 2 }
func unexpectedVMAccess(_ operation: String) -> Never {
    witnessRow(["event": "unexpected_vm_access", "operation": operation])
    exit(126)
}
final class UnavailableVM {
    let state = UnavailableVMState.unavailable
    let canStop = false
    func stop(_ completion: (Error?) -> Void) { unexpectedVMAccess("stop") }
}

final class Owner {
    let machine = UnavailableVM()
    var ending = false
    var supervisorStopping = false
    var termSource: DispatchSourceSignal?
    func persistSlotStop() { unexpectedVMAccess("acknowledgement") }

    // INSERT_LIVE_EVENT

    // INSERT_TIMEOUT_WITNESS
}

@main
struct IsolatedTimeoutWitness {
    static func main() {
        guard CommandLine.arguments.count == 1 else { exit(77) }
        let owner = Owner()
        owner.installTimeoutWitness()
        dispatchMain()
    }
}
