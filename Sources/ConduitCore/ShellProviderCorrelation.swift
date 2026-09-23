import Foundation

public enum ShellProviderCorrelationKind: String, Codable, Equatable, Sendable {
    case exact
    case candidate
    case ambiguous
    case unknown
}

/// A read-only link from a Shell execution and an owned OS process to an exact
/// provider session identity in a current persistence inventory. Exact identity
/// does not establish provider-host liveness, turn state, task association, or
/// writer authority.
public struct ShellProviderCorrelation: Codable, Equatable, Sendable {
    public var kind: ShellProviderCorrelationKind
    public var taskSessionID: OrchestrationValue<String>
    public var runtimeAttemptID: OrchestrationValue<String>
    public var shellExecutionID: OrchestrationValue<String>
    public var commandID: OrchestrationValue<String>
    public var processPID: OrchestrationValue<Int32>
    public var providerSessionID: OrchestrationValue<String>
    public var candidateSessionIDs: [String]
    public var processObservation: SupervisionObservationStamp
    public var providerObservation: SupervisionObservationStamp
    public var diagnostics: [String]

    public init(
        kind: ShellProviderCorrelationKind,
        taskSessionID: OrchestrationValue<String> = .unknown,
        runtimeAttemptID: OrchestrationValue<String> = .unknown,
        shellExecutionID: OrchestrationValue<String> = .unknown,
        commandID: OrchestrationValue<String> = .unknown,
        processPID: OrchestrationValue<Int32> = .unknown,
        providerSessionID: OrchestrationValue<String> = .unknown,
        candidateSessionIDs: [String] = [],
        processObservation: SupervisionObservationStamp,
        providerObservation: SupervisionObservationStamp,
        diagnostics: [String] = []
    ) {
        self.kind = kind
        self.taskSessionID = taskSessionID
        self.runtimeAttemptID = runtimeAttemptID
        self.shellExecutionID = shellExecutionID
        self.commandID = commandID
        self.processPID = processPID
        self.providerSessionID = providerSessionID
        self.candidateSessionIDs = candidateSessionIDs
        self.processObservation = processObservation
        self.providerObservation = providerObservation
        self.diagnostics = diagnostics
    }
}

public struct ShellOpenCodeProcessCandidate: Equatable, Sendable {
    public var node: ProcessNodeObservation
    /// Arguments are transient observation input. The resolver retains only
    /// the exact session id when the executable and flags establish one.
    public var arguments: [String]

    public init(node: ProcessNodeObservation, arguments: [String]) {
        self.node = node
        self.arguments = arguments
    }
}

public enum ShellProviderCorrelationResolver {
    private enum SessionArgumentResult {
        case absent
        case exact(String)
        case ambiguous([String])
    }

    /// Joins process argv to provider persistence only when the process is an
    /// owned member of the Shell process tree and argv carries `--session` or
    /// `-s`. Working directory, timing, and command text are not join keys.
    public static func isOpenCodeProcessName(_ name: String?) -> Bool {
        guard let name, !name.isEmpty else { return false }
        let executable = URL(fileURLWithPath: name).lastPathComponent.lowercased()
        return executable == "opencode" || executable == "opencode.exe"
    }

    public static func resolve(
        taskSessionID: String,
        runtimeAttemptID: String,
        shellExecutionID: String,
        processCandidates: [ShellOpenCodeProcessCandidate],
        processTree: ProcessTreeObservation,
        providerSessionIDs: OrchestrationValue<[String]>,
        providerObservation: SupervisionObservationStamp
    ) -> ShellProviderCorrelation {
        var exactCandidates: [(ProcessNodeObservation, String)] = []
        var ambiguousIDs = Set<String>()

        guard processTree.taskSessionID == taskSessionID,
              processTree.runtimeAttemptID.value == runtimeAttemptID,
              processTree.observation.authority == .processObserved,
              processTree.observation.freshness == .current
        else {
            return ShellProviderCorrelation(
                kind: .unknown,
                taskSessionID: .known(taskSessionID),
                runtimeAttemptID: .known(runtimeAttemptID),
                shellExecutionID: .known(shellExecutionID),
                processObservation: processTree.observation,
                providerObservation: providerObservation,
                diagnostics: ["Current process evidence does not match the Shell task and runtime identity."]
            )
        }
        let observedNodes = [processTree.launcher.value].compactMap { $0 }
            + processTree.descendants

        for candidate in processCandidates {
            let node = candidate.node
            guard observedNodes.contains(node),
                  node.observation.authority == .processObserved,
                  node.observation.freshness == .current,
                  node.pid > 0,
                  node.startIdentity.value?.startTime.value != nil,
                  isOpenCodeProcessName(node.commandName.value),
                  isOwnedShellProcess(node)
            else { continue }

            switch sessionArgument(in: candidate.arguments) {
            case .absent:
                continue
            case .exact(let id):
                exactCandidates.append((node, id))
            case .ambiguous(let ids):
                ambiguousIDs.formUnion(ids)
            }
        }

        guard ambiguousIDs.isEmpty else {
            return ShellProviderCorrelation(
                kind: .ambiguous,
                taskSessionID: .known(taskSessionID),
                runtimeAttemptID: .known(runtimeAttemptID),
                shellExecutionID: .known(shellExecutionID),
                commandID: .unknown,
                candidateSessionIDs: ambiguousIDs.sorted(),
                processObservation: processTree.observation,
                providerObservation: providerObservation,
                diagnostics: ["An owned OpenCode process exposed conflicting exact session arguments."]
            )
        }

        guard exactCandidates.count == 1,
              let (node, sessionID) = exactCandidates.first
        else {
            let reason = exactCandidates.isEmpty
                ? "No owned OpenCode process exposed an exact session argument."
                : "Multiple owned OpenCode processes exposed session arguments; the Shell relationship is ambiguous."
            return ShellProviderCorrelation(
                kind: exactCandidates.isEmpty ? .unknown : .ambiguous,
                taskSessionID: .known(taskSessionID),
                runtimeAttemptID: .known(runtimeAttemptID),
                shellExecutionID: .known(shellExecutionID),
                commandID: .unknown,
                candidateSessionIDs: exactCandidates.map(\.1).sorted(),
                processObservation: processTree.observation,
                providerObservation: providerObservation,
                diagnostics: [reason]
            )
        }

        let persistenceConfirmsCandidate = providerSessionIDs.state == .known
            && providerSessionIDs.value?.filter({ $0 == sessionID }).count == 1
            && providerObservation.authority == .providerObserved
            && providerObservation.freshness == .current

        switch processTree.coverage {
        case .complete:
            break
        case .partial:
            let diagnostic = persistenceConfirmsCandidate
                ? "Current provider persistence confirms the candidate, but partial process-tree coverage cannot establish that it is unique."
                : "Partial process-tree coverage leaves the observed OpenCode session as a candidate; a second owned process may be unobserved."
            return ShellProviderCorrelation(
                kind: .candidate,
                taskSessionID: .known(taskSessionID),
                runtimeAttemptID: .known(runtimeAttemptID),
                shellExecutionID: .known(shellExecutionID),
                commandID: .unknown,
                processPID: .known(node.pid),
                providerSessionID: .known(sessionID),
                candidateSessionIDs: [sessionID],
                processObservation: processTree.observation,
                providerObservation: providerObservation,
                diagnostics: [diagnostic]
            )
        case .ambiguous:
            let diagnostic = persistenceConfirmsCandidate
                ? "Current provider persistence confirms the observed session, but ambiguous process-tree coverage cannot establish its unique Shell relationship."
                : "Ambiguous process-tree coverage cannot establish a unique Shell-to-session relationship."
            return ShellProviderCorrelation(
                kind: .ambiguous,
                taskSessionID: .known(taskSessionID),
                runtimeAttemptID: .known(runtimeAttemptID),
                shellExecutionID: .known(shellExecutionID),
                candidateSessionIDs: [sessionID],
                processObservation: processTree.observation,
                providerObservation: providerObservation,
                diagnostics: [diagnostic]
            )
        case .unavailable:
            return ShellProviderCorrelation(
                kind: .unknown,
                taskSessionID: .known(taskSessionID),
                runtimeAttemptID: .known(runtimeAttemptID),
                shellExecutionID: .known(shellExecutionID),
                processObservation: processTree.observation,
                providerObservation: providerObservation,
                diagnostics: ["Process-tree coverage is unavailable; an exact Shell-to-session relationship cannot be established."]
            )
        }

        guard persistenceConfirmsCandidate else {
            return ShellProviderCorrelation(
                kind: .candidate,
                taskSessionID: .known(taskSessionID),
                runtimeAttemptID: .known(runtimeAttemptID),
                shellExecutionID: .known(shellExecutionID),
                commandID: .unknown,
                processPID: .known(node.pid),
                providerSessionID: .known(sessionID),
                candidateSessionIDs: [sessionID],
                processObservation: processTree.observation,
                providerObservation: providerObservation,
                diagnostics: ["An owned OpenCode process exposed an exact session argument, but current provider persistence did not confirm it."]
            )
        }

        return ShellProviderCorrelation(
            kind: .exact,
            taskSessionID: .known(taskSessionID),
            runtimeAttemptID: .known(runtimeAttemptID),
            shellExecutionID: .known(shellExecutionID),
            commandID: .unknown,
            processPID: .known(node.pid),
            providerSessionID: .known(sessionID),
            candidateSessionIDs: [sessionID],
            processObservation: processTree.observation,
            providerObservation: providerObservation
        )
    }

    private static func isOwnedShellProcess(_ node: ProcessNodeObservation) -> Bool {
        guard node.liveness == .live,
              node.ownership == .taskCreated
        else { return false }
        switch node.ownershipBasis {
        case .launcherIdentity, .descendantObservedAfterLauncher, .preservedFromPriorIdentity:
            return true
        case .preExistingObservation, .notEstablished:
            return false
        }
    }

    private static func sessionArgument(in arguments: [String]) -> SessionArgumentResult {
        guard let executable = arguments.first,
              isOpenCodeProcessName(executable)
        else { return .absent }

        var ids: [String] = []
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--session" || argument == "-s" {
                guard index + 1 < arguments.count else { return .absent }
                let value = arguments[index + 1]
                guard !value.isEmpty, !value.hasPrefix("-") else { return .absent }
                ids.append(value)
                index += 2
                continue
            }
            if argument.hasPrefix("--session=") {
                let value = String(argument.dropFirst("--session=".count))
                guard !value.isEmpty else { return .absent }
                ids.append(value)
            }
            index += 1
        }

        let unique = Array(Set(ids)).sorted()
        if unique.count > 1 { return .ambiguous(unique) }
        guard let id = unique.first else { return .absent }
        return .exact(id)
    }
}
