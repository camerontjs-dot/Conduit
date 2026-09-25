#if os(macOS)
import Darwin
import Foundation

/// macOS process observation for the provider-neutral Core read model.
///
/// This observer is deliberately read-only. It uses libproc snapshots and
/// `kill(pid, 0)` probes only; it never signals a process. The caller must
/// explicitly supply whether the selected root has task-specific ownership
/// evidence. A root PID used only for observation defaults to UNKNOWN and
/// cannot grant ownership to descendants from topology or timing alone. PPID
/// and command name are retained as observations, not ownership proof.
public enum MacOSProcessTreeObserver {
    private static let maximumProcesses = 512
    private static let maximumDepth = 32

    private struct RawProcessInfo {
        let pid: pid_t
        let parentPID: pid_t
        let processGroupID: pid_t
        let startTime: Date
        let commandName: String
    }

    private enum ProbeResult {
        case live
        case exited
        case unknown
    }

    /// Returns argv only for a process whose PID/start identity still matches
    /// the just-observed node. Callers must inspect only the allowlisted
    /// provider executable and discard the arguments after extracting exact
    /// identity flags; command text is never persisted.
    public static func arguments(for node: ProcessNodeObservation) -> [String]? {
        guard node.liveness == .live,
              ShellProviderCorrelationResolver.isOpenCodeProcessName(
                node.commandName.value
              ),
              let before = readProcess(pid_t(node.pid)),
              sameProcessIdentity(before, node)
        else { return nil }

        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, node.pid]
        var byteCount = 0
        let sizeResult = mib.withUnsafeMutableBufferPointer { pointer in
            sysctl(
                pointer.baseAddress,
                u_int(pointer.count),
                nil,
                &byteCount,
                nil,
                0
            )
        }
        guard sizeResult == 0,
              byteCount >= MemoryLayout<Int32>.size,
              byteCount <= 1_048_576
        else { return nil }

        var bytes = [UInt8](repeating: 0, count: byteCount)
        var resultSize = byteCount
        let result = mib.withUnsafeMutableBufferPointer { mibPointer in
            bytes.withUnsafeMutableBytes { buffer in
                sysctl(
                    mibPointer.baseAddress,
                    u_int(mibPointer.count),
                    buffer.baseAddress,
                    &resultSize,
                    nil,
                    0
                )
            }
        }
        guard result == 0,
              resultSize >= MemoryLayout<Int32>.size,
              resultSize <= bytes.count
        else { return nil }

        let data = bytes.prefix(resultSize)
        let argc = data.withUnsafeBytes { raw in
            raw.loadUnaligned(as: Int32.self)
        }
        guard argc > 0, argc <= 256 else { return nil }

        var cursor = MemoryLayout<Int32>.size
        while cursor < data.count, data[cursor] != 0 { cursor += 1 }
        guard cursor < data.count else { return nil }
        while cursor < data.count, data[cursor] == 0 { cursor += 1 }

        var arguments: [String] = []
        arguments.reserveCapacity(Int(argc))
        for _ in 0..<argc {
            guard cursor < data.count else { return nil }
            let start = cursor
            while cursor < data.count, data[cursor] != 0 { cursor += 1 }
            guard cursor < data.count,
                  cursor - start <= 4096
            else { return nil }
            arguments.append(String(decoding: data[start..<cursor], as: UTF8.self))
            cursor += 1
        }

        guard let after = readProcess(pid_t(node.pid)),
              sameProcessIdentity(after, node),
              sameProcessIdentity(before, node)
        else { return nil }
        return arguments
    }

    public static func observe(
        rootPID: pid_t,
        taskSessionID: String,
        runtimeAttemptID: String?,
        rootOwnership: ProcessOwnership = .unknown,
        providerTurnID: String? = nil,
        prior: ProcessTreeObservation? = nil,
        observedAt: Date = Date()
    ) -> ProcessTreeObservation {
        let runtimeAttempt = runtimeAttemptID.map(OrchestrationValue<String>.known)
            ?? .unknown
        let providerTurn = providerTurnID.map(OrchestrationValue<String>.known)
            ?? .unknown
        let stamp = SupervisionObservationStamp(
            authority: .processObserved,
            freshness: .current,
            observedAt: .known(observedAt)
        )

        guard rootPID > 0 else {
            return .unavailable(
                taskSessionID: taskSessionID,
                runtimeAttemptID: runtimeAttempt,
                providerTurnID: providerTurn,
                reason: "runtime launcher PID is not available",
                observedAt: observedAt
            )
        }

        var diagnostics: [String] = []
        let rootInfo = readProcess(rootPID)
        let priorLauncher = prior?.launcher.value
        let priorRootMatches: Bool = {
            guard let rootInfo, let priorLauncher else { return false }
            return sameProcessIdentity(rootInfo, priorLauncher)
        }()

        if let rootInfo {
            let rootClassification: (ProcessOwnership, ProcessOwnershipBasis)
            if let priorLauncher, priorRootMatches {
                rootClassification = (
                    priorLauncher.ownership,
                    .preservedFromPriorIdentity
                )
            } else if priorLauncher != nil {
                diagnostics.append(
                    "launcher PID was observed with a different start identity; PID reuse or runtime replacement is ambiguous"
                )
                rootClassification = (.unknown, .notEstablished)
            } else {
                rootClassification = initialRootClassification(
                    requestedOwnership: rootOwnership
                )
            }
            let launcher = node(
                info: rootInfo,
                ownership: rootClassification.0,
                ownershipBasis: rootClassification.1,
                liveness: .live,
                observation: stamp
            )
            let walk = walkDescendants(
                root: rootInfo,
                rootOwnership: rootClassification.0,
                prior: prior,
                observation: stamp,
                diagnostics: &diagnostics
            )
            return ProcessTreeObservation(
                taskSessionID: taskSessionID,
                runtimeAttemptID: runtimeAttempt,
                providerTurnID: providerTurn,
                launcher: .known(launcher),
                descendants: walk.nodes,
                coverage: priorRootMatches || prior == nil
                    ? walk.coverage
                    : .ambiguous,
                observation: stamp,
                diagnostics: diagnostics.isEmpty
                    ? .known([])
                    : .known(diagnostics)
            )
        }

        guard let priorLauncher,
              priorLauncher.pid == rootPID
        else {
            return ProcessTreeObservation(
                taskSessionID: taskSessionID,
                runtimeAttemptID: runtimeAttempt,
                providerTurnID: providerTurn,
                launcher: .unknown,
                descendants: [],
                coverage: .unavailable,
                observation: stamp,
                diagnostics: .known([
                    "libproc could not observe the launcher and no identity-bound prior snapshot was available"
                ])
            )
        }

        switch probe(rootPID) {
        case .live, .unknown:
            diagnostics.append(
                "launcher PID could not be read after the prior snapshot; launcher liveness is not proven"
            )
            return ProcessTreeObservation(
                taskSessionID: taskSessionID,
                runtimeAttemptID: runtimeAttempt,
                providerTurnID: providerTurn,
                launcher: .known(unknownNode(
                    from: priorLauncher,
                    observation: stamp
                )),
                descendants: [],
                coverage: .ambiguous,
                observation: stamp,
                diagnostics: .known(diagnostics)
            )
        case .exited:
            let launcher = exitedNode(from: priorLauncher, observation: stamp)
            let priorNodes = prior?.descendants ?? []
            let descendants = reobservePriorNodes(
                priorNodes,
                observation: stamp,
                diagnostics: &diagnostics
            )
            let coverage: ProcessTreeObservationCoverage =
                prior?.coverage == .complete && !diagnostics.contains(where: {
                    $0.contains("PID reuse") || $0.contains("liveness is not proven")
                })
                    ? .complete
                    : .ambiguous
            return ProcessTreeObservation(
                taskSessionID: taskSessionID,
                runtimeAttemptID: runtimeAttempt,
                providerTurnID: providerTurn,
                launcher: .known(launcher),
                descendants: descendants,
                coverage: coverage,
                observation: stamp,
                diagnostics: diagnostics.isEmpty
                    ? .known([])
                    : .known(diagnostics)
            )
        }
    }

    private static func walkDescendants(
        root: RawProcessInfo,
        rootOwnership: ProcessOwnership,
        prior: ProcessTreeObservation?,
        observation: SupervisionObservationStamp,
        diagnostics: inout [String]
    ) -> (nodes: [ProcessNodeObservation], coverage: ProcessTreeObservationCoverage) {
        var nodes: [ProcessNodeObservation] = []
        var visited: Set<pid_t> = [root.pid]
        var frontier: [(RawProcessInfo, Int)] = [(root, 0)]
        var coverage: ProcessTreeObservationCoverage = .complete

        while let (parent, depth) = frontier.first {
            frontier.removeFirst()
            guard visited.count < maximumProcesses else {
                coverage = .partial
                diagnostics.append("process-tree observation reached its process limit")
                break
            }
            guard depth < maximumDepth else {
                coverage = .partial
                diagnostics.append("process-tree observation reached its depth limit")
                continue
            }

            guard let childPIDs = childPIDs(of: parent.pid) else {
                coverage = .partial
                diagnostics.append(
                    "child enumeration was unavailable for parent PID \(parent.pid)"
                )
                continue
            }

            for childPID in childPIDs {
                guard visited.insert(childPID).inserted else { continue }
                guard visited.count <= maximumProcesses else {
                    coverage = .partial
                    diagnostics.append("process-tree observation reached its process limit")
                    break
                }
                guard let childInfo = readProcess(childPID) else {
                    coverage = .partial
                    diagnostics.append(
                        "child PID \(childPID) was listed but its process identity could not be read"
                    )
                    nodes.append(
                        unknownListedNode(
                            pid: childPID,
                            parentPID: parent.pid,
                            observation: observation
                        )
                    )
                    continue
                }

                let priorNode = prior.flatMap {
                    matchingNode(childInfo, in: $0.descendants)
                }
                let ownership: (ProcessOwnership, ProcessOwnershipBasis)
                if let priorNode {
                    ownership = (
                        priorNode.ownership,
                        .preservedFromPriorIdentity
                    )
                } else {
                    ownership = ownershipForNewDescendant(
                        childInfo,
                        launcher: root,
                        rootOwnership: rootOwnership
                    )
                }
                nodes.append(
                    node(
                        info: childInfo,
                        ownership: ownership.0,
                        ownershipBasis: ownership.1,
                        liveness: .live,
                        observation: observation
                    )
                )
                frontier.append((childInfo, depth + 1))
            }
        }

        // A child can survive by reparenting. Re-observe every identity from
        // the prior sample that is no longer under the current root walk so a
        // known task-created residual is not erased merely because its PPID
        // changed.
        if let prior {
            let missingPrior = prior.descendants.filter { priorNode in
                !nodes.contains { current in
                    sameProcessIdentity(current, priorNode)
                }
            }
            nodes.append(contentsOf: reobservePriorNodes(
                missingPrior,
                observation: observation,
                diagnostics: &diagnostics
            ))
            let hasUnknownMissingPrior = missingPrior.contains { priorNode in
                nodes.contains { current in
                    current.pid == priorNode.pid
                        && current.ownership == .unknown
                        && current.liveness == .live
                }
            }
            if hasUnknownMissingPrior {
                coverage = .ambiguous
            }
        }

        return (deduplicated(nodes), coverage)
    }

    private static func reobservePriorNodes(
        _ priorNodes: [ProcessNodeObservation],
        observation: SupervisionObservationStamp,
        diagnostics: inout [String]
    ) -> [ProcessNodeObservation] {
        var result: [ProcessNodeObservation] = []
        for priorNode in priorNodes {
            guard let current = readProcess(priorNode.pid) else {
                switch probe(priorNode.pid) {
                case .exited:
                    result.append(exitedNode(from: priorNode, observation: observation))
                case .live, .unknown:
                    diagnostics.append(
                        "PID \(priorNode.pid) liveness is not proven after the prior snapshot"
                    )
                    result.append(unknownNode(from: priorNode, observation: observation))
                }
                continue
            }
            guard sameProcessIdentity(current, priorNode) else {
                diagnostics.append(
                    "PID reuse observed for PID \(priorNode.pid); prior process identity is exited but the replacement is UNKNOWN"
                )
                result.append(exitedNode(from: priorNode, observation: observation))
                result.append(
                    unknownReplacementNode(
                        info: current,
                        observation: observation
                    )
                )
                continue
            }
            var retained = node(
                info: current,
                ownership: priorNode.ownership,
                ownershipBasis: .preservedFromPriorIdentity,
                liveness: .live,
                observation: observation
            )
            // Parent relationship is intentionally copied from the current
            // observation. It can be PID 1 after an orphaning transition; it
            // does not rewrite the preserved ownership classification.
            retained.parentPID = .known(current.parentPID)
            result.append(retained)
        }
        return result
    }

    static func initialRootClassification(
        requestedOwnership: ProcessOwnership
    ) -> (ProcessOwnership, ProcessOwnershipBasis) {
        switch requestedOwnership {
        case .taskCreated:
            return (.taskCreated, .launcherIdentity)
        case .preExisting:
            return (.preExisting, .preExistingObservation)
        case .unknown:
            return (.unknown, .notEstablished)
        }
    }

    static func classifyNewDescendantOwnership(
        descendantStartTime: Date,
        launcherStartTime: Date,
        rootOwnership: ProcessOwnership
    ) -> (ProcessOwnership, ProcessOwnershipBasis) {
        guard rootOwnership == .taskCreated else {
            return (.unknown, .notEstablished)
        }
        guard descendantStartTime >= launcherStartTime else {
            return (.preExisting, .preExistingObservation)
        }
        return (.taskCreated, .descendantObservedAfterLauncher)
    }

    private static func ownershipForNewDescendant(
        _ info: RawProcessInfo,
        launcher: RawProcessInfo,
        rootOwnership: ProcessOwnership
    ) -> (ProcessOwnership, ProcessOwnershipBasis) {
        classifyNewDescendantOwnership(
            descendantStartTime: info.startTime,
            launcherStartTime: launcher.startTime,
            rootOwnership: rootOwnership
        )
    }

    private static func node(
        info: RawProcessInfo,
        ownership: ProcessOwnership,
        ownershipBasis: ProcessOwnershipBasis,
        liveness: ProcessLiveness,
        observation: SupervisionObservationStamp
    ) -> ProcessNodeObservation {
        ProcessNodeObservation(
            pid: info.pid,
            parentPID: .known(info.parentPID),
            processGroupID: .known(info.processGroupID),
            startIdentity: .known(
                ProcessStartIdentity(startTime: .known(info.startTime))
            ),
            commandName: .known(info.commandName),
            ownership: ownership,
            ownershipBasis: ownershipBasis,
            liveness: liveness,
            observation: observation
        )
    }

    private static func unknownListedNode(
        pid: pid_t,
        parentPID: pid_t,
        observation: SupervisionObservationStamp
    ) -> ProcessNodeObservation {
        ProcessNodeObservation(
            pid: pid,
            parentPID: .known(parentPID),
            processGroupID: .unknown,
            startIdentity: .unknown,
            commandName: .unknown,
            ownership: .unknown,
            ownershipBasis: .notEstablished,
            liveness: .unknown,
            observation: observation
        )
    }

    private static func unknownReplacementNode(
        info: RawProcessInfo,
        observation: SupervisionObservationStamp
    ) -> ProcessNodeObservation {
        node(
            info: info,
            ownership: .unknown,
            ownershipBasis: .notEstablished,
            liveness: .live,
            observation: observation
        )
    }

    private static func exitedNode(
        from prior: ProcessNodeObservation,
        observation: SupervisionObservationStamp
    ) -> ProcessNodeObservation {
        ProcessNodeObservation(
            pid: prior.pid,
            parentPID: .unknown,
            processGroupID: .unknown,
            startIdentity: prior.startIdentity,
            commandName: .unknown,
            ownership: prior.ownership,
            ownershipBasis: prior.ownershipBasis,
            liveness: .exited,
            exitObservedAt: observation.observedAt,
            observation: observation
        )
    }

    private static func unknownNode(
        from prior: ProcessNodeObservation,
        observation: SupervisionObservationStamp
    ) -> ProcessNodeObservation {
        ProcessNodeObservation(
            pid: prior.pid,
            parentPID: .unknown,
            processGroupID: .unknown,
            startIdentity: prior.startIdentity,
            commandName: .unknown,
            ownership: .unknown,
            ownershipBasis: .notEstablished,
            liveness: .unknown,
            observation: observation
        )
    }

    private static func sameProcessIdentity(
        _ info: RawProcessInfo,
        _ node: ProcessNodeObservation
    ) -> Bool {
        guard let startIdentity = node.startIdentity.value,
              let expected = startIdentity.startTime.value
        else {
            return false
        }
        return info.pid == node.pid && info.startTime == expected
    }

    private static func sameProcessIdentity(
        _ lhs: ProcessNodeObservation,
        _ rhs: ProcessNodeObservation
    ) -> Bool {
        guard lhs.pid == rhs.pid,
              let lhsStart = lhs.startIdentity.value?.startTime.value,
              let rhsStart = rhs.startIdentity.value?.startTime.value
        else {
            return false
        }
        return lhsStart == rhsStart
    }

    private static func matchingNode(
        _ info: RawProcessInfo,
        in nodes: [ProcessNodeObservation]
    ) -> ProcessNodeObservation? {
        nodes.first { sameProcessIdentity(info, $0) }
    }

    private static func deduplicated(
        _ nodes: [ProcessNodeObservation]
    ) -> [ProcessNodeObservation] {
        var seen = Set<String>()
        return nodes.filter { node in
            let start = node.startIdentity.value?.startTime.value
                .map { String($0.timeIntervalSince1970) } ?? "unknown"
            return seen.insert("\(node.pid):\(start):\(node.liveness.rawValue)").inserted
        }
    }

    private static func readProcess(_ pid: pid_t) -> RawProcessInfo? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let written = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, size)
        }
        guard written == size else { return nil }
        let start = Date(
            timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
                + TimeInterval(info.pbi_start_tvusec) / 1_000_000
        )
        return RawProcessInfo(
            pid: pid,
            parentPID: pid_t(info.pbi_ppid),
            processGroupID: pid_t(info.pbi_pgid),
            startTime: start,
            commandName: decodeCString(info.pbi_comm)
        )
    }

    private static func decodeCString<T>(_ value: T) -> String {
        withUnsafeBytes(of: value) { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
            return String(decoding: bytes[..<end], as: UTF8.self)
        }
    }

    private static func childPIDs(of parent: pid_t) -> [pid_t]? {
        let byteCount = proc_listpids(
            UInt32(PROC_PPID_ONLY),
            UInt32(parent),
            nil,
            0
        )
        guard byteCount >= 0 else { return nil }
        guard byteCount > 0 else { return [] }
        let capacity = Int(byteCount) / MemoryLayout<pid_t>.size
        guard capacity > 0 else { return [] }
        var buffer = [pid_t](repeating: 0, count: capacity)
        let written = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_listpids(
                UInt32(PROC_PPID_ONLY),
                UInt32(parent),
                pointer.baseAddress,
                Int32(byteCount)
            )
        }
        guard written >= 0 else { return nil }
        guard written > 0 else { return [] }
        let found = Int(written) / MemoryLayout<pid_t>.size
        return Array(buffer.prefix(found)).filter { $0 > 0 }
    }

    private static func probe(_ pid: pid_t) -> ProbeResult {
        guard pid > 0 else { return .unknown }
        if kill(pid, 0) == 0 { return .live }
        switch errno {
        case ESRCH: return .exited
        case EPERM: return .unknown
        default: return .unknown
        }
    }
}
#endif
