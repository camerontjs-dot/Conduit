import Foundation

public enum ShellCommandExecutionState: String, Codable, Equatable, Sendable {
    case active
    case exited
    case unknown
}

public struct ShellTelemetryHistorySnapshot: Equatable, Sendable {
    public let runtimeAttemptID: String
    public let shellExecutionID: String
    public let latestEvent: ShellTelemetryEvent
    public let latestCommandEvent: ShellTelemetryEvent?
    public let latestCommandStartedAt: Date?
    public let processObservation: ProcessTreeObservation?

    public init(
        runtimeAttemptID: String,
        shellExecutionID: String,
        latestEvent: ShellTelemetryEvent,
        latestCommandEvent: ShellTelemetryEvent?,
        latestCommandStartedAt: Date?,
        processObservation: ProcessTreeObservation?
    ) {
        self.runtimeAttemptID = runtimeAttemptID
        self.shellExecutionID = shellExecutionID
        self.latestEvent = latestEvent
        self.latestCommandEvent = latestCommandEvent
        self.latestCommandStartedAt = latestCommandStartedAt
        self.processObservation = processObservation
    }

    public func commandState(liveRuntimeAttemptID: String?) -> ShellCommandExecutionState {
        guard let latestCommandEvent else { return .unknown }
        switch latestCommandEvent.phase {
        case .commandStarted:
            guard latestEvent.phase != .shellExited,
                  liveRuntimeAttemptID == runtimeAttemptID
            else { return .unknown }
            return .active
        case .commandExited: return .exited
        case .executionStarted, .directoryChanged, .shellExited: return .unknown
        }
    }

    /// Persisted hook state remains stale after its telemetry-owning runtime
    /// is gone. A matching live hook endpoint can continue to expose its last
    /// received boundary as current; OS process liveness is not substituted.
    public func observationStamp(liveRuntimeAttemptID: String?) -> SupervisionObservationStamp {
        var stamp = latestEvent.observation
        stamp.freshness = liveRuntimeAttemptID == runtimeAttemptID ? .current : .stale
        return stamp
    }
}

public enum ShellTelemetryProjection {
    /// Rebuilds the latest Shell execution entirely from the append-only task
    /// event stream. File order is authoritative; PTY capture state does not
    /// participate in command or process lifecycle projection.
    public static func latest(
        taskSessionID: TaskSessionID,
        events: [TaskSessionEvent]
    ) -> ShellTelemetryHistorySnapshot? {
        let validEvents = events.filter {
            $0.taskSessionID == taskSessionID && $0.hasValidAuthority
        }
        let telemetry = validEvents.compactMap { event -> ShellTelemetryEvent? in
            guard case .shellTelemetryRecorded(let telemetry) = event.kind else {
                return nil
            }
            return telemetry
        }
        guard let executionStart = telemetry.last(where: {
            $0.phase == .executionStarted
        }) ?? telemetry.last else { return nil }

        let executionEvents = telemetry.filter {
            $0.shellExecutionID == executionStart.shellExecutionID
                && $0.runtimeAttemptID == executionStart.runtimeAttemptID
        }
        guard let latestEvent = executionEvents.last else { return nil }
        let latestCommand = executionEvents.last(where: {
            $0.phase == .commandStarted || $0.phase == .commandExited
        })
        let latestCommandStart = latestCommand.flatMap { command in
            executionEvents.last(where: {
                $0.phase == .commandStarted
                    && $0.commandID == command.commandID
            })
        }
        let processObservation = validEvents.compactMap { event -> ProcessTreeObservation? in
            guard case .shellProcessObservationRecorded(let observation) = event.kind,
                  observation.runtimeAttemptID.value == executionStart.runtimeAttemptID
            else { return nil }
            return observation
        }.last

        return ShellTelemetryHistorySnapshot(
            runtimeAttemptID: executionStart.runtimeAttemptID,
            shellExecutionID: executionStart.shellExecutionID,
            latestEvent: latestEvent,
            latestCommandEvent: latestCommand,
            latestCommandStartedAt: latestCommandStart?.observation.observedAt.value,
            processObservation: processObservation
        )
    }
}
