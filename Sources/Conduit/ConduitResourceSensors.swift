#if os(macOS)
import ConduitCore
import Darwin
import Foundation

/// Fast, synchronous, in-process resource sensors for the MCP admission
/// boundary.
///
/// These must stay cheap enough to run on the main actor inside a single
/// Session API request. `ResourceService` shells out to `vm_stat` and `ps` for
/// the Settings panel; that path costs seconds and cannot gate a write.
///
/// Every reading here is a real measurement or `.unknown`. Nothing is
/// defaulted to zero to make a check pass.
enum ConduitResourceSensors {
    /// Physical memory the kernel reports as reclaimable right now.
    ///
    /// Uses the same page classes as `ResourceService.parseAvailableMemory`
    /// (free + inactive + speculative + purgeable) so the admission boundary
    /// and the Settings readout cannot disagree about the same machine.
    static func availablePhysicalMemoryBytes() -> UInt64? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pageSize = UInt64(vm_kernel_page_size)
        let pages = UInt64(stats.free_count)
            + UInt64(stats.inactive_count)
            + UInt64(stats.speculative_count)
            + UInt64(stats.purgeable_count)
        return pages * pageSize
    }

    /// Resident bytes for Conduit itself plus the descendants still parented to
    /// it.
    ///
    /// Known narrowing: agents launched into durable tmux are reparented to the
    /// tmux server and are **not** counted here. This metric bounds Conduit's
    /// own footprint — the in-process stream/persistence growth behind the
    /// 2026-08-18 overload — not total agent-fleet memory. Fleet size is capped
    /// separately by `MCPAdmissionPolicy.globalLiveTaskLimit`.
    static func ownedProcessTreeRSSBytes(
        maximumProcesses: Int = 256,
        maximumDepth: Int = 4
    ) -> UInt64? {
        guard let own = residentSize(of: getpid()) else { return nil }
        var total = own
        var visited: Set<pid_t> = [getpid()]
        var frontier: [pid_t] = [getpid()]
        var depth = 0

        while !frontier.isEmpty, depth < maximumDepth,
              visited.count < maximumProcesses {
            var next: [pid_t] = []
            for parent in frontier {
                for child in childPIDs(of: parent) {
                    guard visited.count < maximumProcesses else { break }
                    guard visited.insert(child).inserted else { continue }
                    // A child that exits mid-walk contributes nothing rather
                    // than invalidating the whole sample.
                    if let rss = residentSize(of: child) { total += rss }
                    next.append(child)
                }
            }
            frontier = next
            depth += 1
        }
        return total
    }

    private static func residentSize(of pid: pid_t) -> UInt64? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let written = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)
        guard written == size else { return nil }
        return info.pti_resident_size
    }

    private static func childPIDs(of parent: pid_t) -> [pid_t] {
        let byteCount = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(parent), nil, 0)
        guard byteCount > 0 else { return [] }
        let capacity = Int(byteCount) / MemoryLayout<pid_t>.size
        var buffer = [pid_t](repeating: 0, count: capacity)
        let written = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_listpids(
                UInt32(PROC_PPID_ONLY),
                UInt32(parent),
                pointer.baseAddress,
                Int32(byteCount)
            )
        }
        guard written > 0 else { return [] }
        let found = Int(written) / MemoryLayout<pid_t>.size
        return buffer.prefix(found).filter { $0 > 0 }
    }
}
#endif
