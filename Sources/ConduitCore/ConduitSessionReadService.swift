import Foundation

/// Observed state of one task as its owner reports it.
///
/// Plain values only. The read service keeps no reference back to the owner
/// and cannot act on anything through this type.
public struct ConduitSessionTaskObservation: Equatable, Sendable {
    public var backend: AgentSessionBackend
    public var lifecycle: String
    public var runtimeState: String
    public var live: Bool
    public var ready: Bool
    public var adapter: ConduitSessionAdapterSnapshot?
    public var runtimeAttemptID: RuntimeAttemptID?
    public var persistedThreadID: String?

    public init(
        backend: AgentSessionBackend,
        lifecycle: String,
        runtimeState: String,
        live: Bool,
        ready: Bool,
        adapter: ConduitSessionAdapterSnapshot? = nil,
        runtimeAttemptID: RuntimeAttemptID? = nil,
        persistedThreadID: String? = nil
    ) {
        self.backend = backend
        self.lifecycle = lifecycle
        self.runtimeState = runtimeState
        self.live = live
        self.ready = ready
        self.adapter = adapter
        self.runtimeAttemptID = runtimeAttemptID
        self.persistedThreadID = persistedThreadID
    }
}

/// The read-only interface a task owner exposes to Session API reads.
///
/// Every requirement returns state the owner already holds. None can launch,
/// resume, prompt, interrupt or reconnect a runtime, so a read built on this
/// interface cannot cause provider work. Task, runtime and admission
/// authority stay with the owner.
public protocol ConduitSessionReadOwner {
    /// Nil when the owner has no such task.
    func observation(of task: TaskSessionID) -> ConduitSessionTaskObservation?
    /// In-memory events of a live runtime, or nil when no runtime is live.
    func liveTimeline(of task: TaskSessionID) -> [SessionPresentationEvent]?
    /// History the owner loaded from the durable log, or nil when not loaded.
    func cachedTimeline(of task: TaskSessionID) -> [SessionPresentationEvent]?
    func conversationLog(of task: TaskSessionID) -> ConversationEventLog
}

/// Closure-backed owner, so an app object can supply its state without
/// conforming its own type to a Core protocol.
public struct ConduitSessionClosureReadOwner: ConduitSessionReadOwner {
    public var observe: (TaskSessionID) -> ConduitSessionTaskObservation?
    public var live: (TaskSessionID) -> [SessionPresentationEvent]?
    public var cached: (TaskSessionID) -> [SessionPresentationEvent]?
    public var log: (TaskSessionID) -> ConversationEventLog

    public init(
        observe: @escaping (TaskSessionID) -> ConduitSessionTaskObservation?,
        live: @escaping (TaskSessionID) -> [SessionPresentationEvent]?,
        cached: @escaping (TaskSessionID) -> [SessionPresentationEvent]?,
        log: @escaping (TaskSessionID) -> ConversationEventLog
    ) {
        self.observe = observe
        self.live = live
        self.cached = cached
        self.log = log
    }

    public func observation(of task: TaskSessionID) -> ConduitSessionTaskObservation? {
        observe(task)
    }

    public func liveTimeline(of task: TaskSessionID) -> [SessionPresentationEvent]? {
        live(task)
    }

    public func cachedTimeline(of task: TaskSessionID) -> [SessionPresentationEvent]? {
        cached(task)
    }

    public func conversationLog(of task: TaskSessionID) -> ConversationEventLog {
        log(task)
    }
}

public enum ConduitSessionReadError: Error, Equatable, Sendable {
    case unknownTask
}

/// In-process service boundary for Session API conversation reads.
///
/// This is the first slice of the UI-independent boundary in issue #4: the
/// ordering and projection of a read live here and run without AppKit, while
/// the owner remains the only holder of task and runtime state. It selects
/// no process packaging and says nothing about surviving a GUI restart.
public enum ConduitSessionReadService {
    /// One `conduit_session_events` read.
    ///
    /// When the change feed is requested, the durable log is read before the
    /// timeline is chosen, and with no live runtime that read is the timeline.
    /// A write that lands between the two can then only put a live timeline
    /// ahead of the returned head cursor, which a reader sees again on
    /// catch-up, never behind it, which a reader would miss.
    public static func events(
        owner: ConduitSessionReadOwner,
        taskSessionID rawID: String,
        cursor: String?,
        limit: Int?,
        options: ConduitSessionEventReadOptions = .none,
        observedAt: Date = Date()
    ) -> Result<ConduitSessionEventPage, ConduitSessionReadError> {
        guard let uuid = UUID(uuidString: rawID) else {
            return .failure(.unknownTask)
        }
        let task = TaskSessionID(rawValue: uuid)
        guard let observation = owner.observation(of: task) else {
            return .failure(.unknownTask)
        }

        let durable: ConversationRevisionReadResult? =
            options.needsDurableRevisions
                ? owner.conversationLog(of: task).readRevisions()
                : nil

        let events: [SessionPresentationEvent]
        let timelineSource: ConduitSessionTimelineSource
        if let live = owner.liveTimeline(of: task) {
            events = live
            timelineSource = ConduitSessionTimelineSource(
                kind: .liveRuntime,
                durableCoverage: durable?.coverage,
                rejectedRecordCount: durable?.diagnostics.count
            )
        } else if let durable {
            // Cached history is a copy loaded earlier and can lag the log
            // (an exited runtime's tab keeps it until removed). When the log
            // was just read, serve that, so the timeline is never behind the
            // head cursor returned with it.
            events = durable.events
            timelineSource = ConduitSessionTimelineSource(
                kind: .durableLog,
                durableCoverage: durable.coverage,
                rejectedRecordCount: durable.diagnostics.count
            )
        } else if let cached = owner.cachedTimeline(of: task), !cached.isEmpty {
            events = cached
            timelineSource = ConduitSessionTimelineSource(kind: .cachedHistory)
        } else {
            let read = owner.conversationLog(of: task).readWithCoverage()
            events = read.events
            timelineSource = ConduitSessionTimelineSource(
                kind: .durableLog,
                durableCoverage: read.coverage,
                rejectedRecordCount: read.diagnostics.count
            )
        }

        let source = ConduitSessionEventSource(
            taskSessionID: rawID,
            backend: observation.backend,
            sessionLifecycle: observation.lifecycle,
            runtimeState: observation.runtimeState,
            live: observation.live,
            ready: observation.ready,
            events: events,
            adapter: observation.adapter,
            runtimeAttemptID: observation.runtimeAttemptID,
            persistedThreadID: observation.persistedThreadID,
            observedAt: observedAt,
            timelineSource: timelineSource,
            durableRevisions: durable
        )
        return .success(
            ConduitSessionEventExport.page(
                source: source,
                cursor: cursor,
                limit: limit,
                options: options
            )
        )
    }
}
