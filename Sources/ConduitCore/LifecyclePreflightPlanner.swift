import Foundation

/// Runtime shape used to plan lifecycle operations before mutation.
///
/// This is deliberately narrower than WorkerLineage. It carries only facts
/// needed to describe lifecycle consequences and keeps absent facts UNKNOWN.
public enum LifecycleRuntimeKind: String, Codable, Equatable, Sendable {
    case absent
    case codexAppServer = "codex_app_server"
    case openCodeHTTP = "opencode_http"
    case acp
    case structuredCLI = "structured_cli"
    case tmux
    case directPTY = "direct_pty"
}

public struct LifecycleRuntimeSnapshot: Codable, Equatable, Sendable {
    public var kind: LifecycleRuntimeKind
    public var taskSessionID: String
    public var runtimeAttemptID: OrchestrationValue<String>
    public var providerSessionID: OrchestrationValue<String>
    public var providerHostID: OrchestrationValue<String>
    public var tmuxSessionName: OrchestrationValue<String>
    public var turnActive: OrchestrationValue<Bool>
    /// Whether stopping this task's structured adapter is known to stop the
    /// provider host. This matters for OpenCode because one serve process is
    /// shared by multiple retained clients.
    public var adapterStopWillStopProviderHost: OrchestrationValue<Bool>
    /// Read-only OS process observation available at preflight time. This is
    /// never a promise that a later lifecycle operation will stop every
    /// descendant; the operation must reconcile its own postcondition.
    public var processTree: OrchestrationValue<ProcessTreeObservation>
    public var observedAt: Date

    public init(
        kind: LifecycleRuntimeKind,
        taskSessionID: String,
        runtimeAttemptID: OrchestrationValue<String>,
        providerSessionID: OrchestrationValue<String>,
        providerHostID: OrchestrationValue<String>,
        tmuxSessionName: OrchestrationValue<String>,
        turnActive: OrchestrationValue<Bool>,
        adapterStopWillStopProviderHost: OrchestrationValue<Bool>,
        processTree: OrchestrationValue<ProcessTreeObservation> = .unknown,
        observedAt: Date
    ) {
        self.kind = kind
        self.taskSessionID = taskSessionID
        self.runtimeAttemptID = runtimeAttemptID
        self.providerSessionID = providerSessionID
        self.providerHostID = providerHostID
        self.tmuxSessionName = tmuxSessionName
        self.turnActive = turnActive
        self.adapterStopWillStopProviderHost = adapterStopWillStopProviderHost
        self.processTree = processTree
        self.observedAt = observedAt
    }
}

/// Pure lifecycle planning. No method in this type mutates a provider, process,
/// Conduit task, admission slot, or provider-session authority record.
public enum LifecyclePreflightPlanner {
    public static func preflight(
        operation: LifecycleOperation,
        snapshot: LifecycleRuntimeSnapshot
    ) -> LifecyclePreflight {
        switch operation {
        case .observe:
            return plan(
                operation: operation,
                snapshot: snapshot,
                target: sessionTarget(snapshot),
                support: .supported,
                willStopProvider: .known(false),
                willReleaseSlot: .known(false),
                recoverableAfterward: .known(true),
                expectedProcessScope: .known(.none),
                sideEffects: .known([]),
                unsupported: .known([]),
                unknown: .known([])
            )

        case .adopt:
            return dedicatedSurface(
                operation: operation,
                snapshot: snapshot,
                reason: "adoption is owned by conduit_adopt_provider_session; lifecycle execution does not alias it"
            )

        case .startTurn:
            return dedicatedSurface(
                operation: operation,
                snapshot: snapshot,
                reason: "turn start is owned by conduit_send_prompt; lifecycle execution does not alias it"
            )

        case .abortTurn:
            return abortTurn(snapshot)

        case .releaseSupervision:
            return releaseSupervision(snapshot)

        case .stopProviderHost:
            return stopProviderHost(snapshot)

        case .archiveProviderHistory:
            return plan(
                operation: operation,
                snapshot: snapshot,
                target: providerSessionTarget(snapshot),
                support: .unsupported,
                willStopProvider: .known(false),
                willReleaseSlot: .known(false),
                recoverableAfterward: resumeHandle(snapshot).isKnown
                    ? .known(true)
                    : .unknown,
                expectedProcessScope: .known(.none),
                sideEffects: .known([]),
                unsupported: .known([
                    "Conduit exposes no provider-history archive/delete mutation in this slice"
                ]),
                unknown: .known([])
            )
        }
    }

    private static func abortTurn(
        _ snapshot: LifecycleRuntimeSnapshot
    ) -> LifecyclePreflight {
        switch snapshot.kind {
        case .codexAppServer, .openCodeHTTP, .acp, .structuredCLI:
            if snapshot.turnActive.value == false {
                return plan(
                    operation: .abortTurn,
                    snapshot: snapshot,
                    target: LifecycleTarget(kind: .turn, identifier: .unknown),
                    support: .unsupported,
                    willStopProvider: .known(false),
                    willReleaseSlot: .known(false),
                    recoverableAfterward: resumeHandle(snapshot).isKnown
                        ? .known(true)
                        : .unknown,
                    expectedProcessScope: .known(.turn),
                    sideEffects: .known([]),
                    unsupported: .known(["no active provider turn is observed"]),
                    unknown: .known([])
                )
            }
            if !snapshot.turnActive.isKnown {
                return plan(
                    operation: .abortTurn,
                    snapshot: snapshot,
                    target: LifecycleTarget(kind: .turn, identifier: .unknown),
                    support: .unknown,
                    willStopProvider: .known(false),
                    willReleaseSlot: .known(false),
                    recoverableAfterward: resumeHandle(snapshot).isKnown
                        ? .known(true)
                        : .unknown,
                    expectedProcessScope: .known(.turn),
                    sideEffects: .unknown,
                    unsupported: .known([]),
                    unknown: .known(["whether a provider turn is currently active"])
                )
            }
            return plan(
                operation: .abortTurn,
                snapshot: snapshot,
                target: LifecycleTarget(kind: .turn, identifier: .unknown),
                support: .supported,
                willStopProvider: .known(false),
                willReleaseSlot: .known(false),
                recoverableAfterward: .known(true),
                expectedProcessScope: .known(.turn),
                sideEffects: .known([
                    "provider turn cancellation/abort is requested",
                    "provider session/history is not deleted",
                    "Conduit supervision and execution capacity remain"
                ]),
                unsupported: .known([]),
                unknown: .known([
                    "preflight does not claim that the provider has completed cancellation"
                ])
            )

        case .tmux, .directPTY:
            return plan(
                operation: .abortTurn,
                snapshot: snapshot,
                target: sessionTarget(snapshot),
                support: .unsupported,
                willStopProvider: .unknown,
                willReleaseSlot: .known(false),
                recoverableAfterward: snapshot.kind == .tmux
                    ? .known(true)
                    : .unknown,
                expectedProcessScope: .unknown,
                sideEffects: .known([]),
                unsupported: .known([
                    "raw PTY Ctrl-C is process input, not a provider-defined turn-abort contract; use legacy conduit_interrupt only when that weaker semantic is intended"
                ]),
                unknown: .known(["which process or subprocess would consume raw Ctrl-C"])
            )

        case .absent:
            return noLiveRuntime(.abortTurn, snapshot)
        }
    }

    private static func releaseSupervision(
        _ snapshot: LifecycleRuntimeSnapshot
    ) -> LifecyclePreflight {
        switch snapshot.kind {
        case .tmux:
            return plan(
                operation: .releaseSupervision,
                snapshot: snapshot,
                target: sessionTarget(snapshot),
                support: .supported,
                willStopProvider: .known(false),
                willReleaseSlot: .known(true),
                recoverableAfterward: .known(true),
                expectedProcessScope: .known(.none),
                sideEffects: .known([
                    "Conduit detaches its tmux client and releases task execution capacity",
                    "this release does not intentionally stop the tmux session or its provider/runtime",
                    "task history is preserved"
                ]),
                unsupported: .known([]),
                unknown: .known([
                    "provider/runtime liveness after detach is not re-observed by preflight",
                    "provider work may continue after Conduit stops supervising it"
                ])
            )

        case .openCodeHTTP:
            if snapshot.adapterStopWillStopProviderHost.value == false {
                return plan(
                    operation: .releaseSupervision,
                    snapshot: snapshot,
                    target: providerSessionTarget(snapshot),
                    support: .supported,
                    willStopProvider: .known(false),
                    willReleaseSlot: .known(true),
                    recoverableAfterward: resumeHandle(snapshot).isKnown
                        ? .known(true)
                        : .unknown,
                    expectedProcessScope: .known(.none),
                    sideEffects: .known([
                        "Conduit stops this OpenCode client/SSE supervision and releases one server lease",
                        "this release does not intentionally stop the shared or externally owned OpenCode provider host",
                        "the Conduit task runtime closes and releases execution capacity",
                        "provider session/history is not deleted"
                    ]),
                    unsupported: .known([]),
                    unknown: .known([
                        "provider-host liveness after release is not re-observed by preflight"
                    ])
                )
            }
            if snapshot.adapterStopWillStopProviderHost.value == true {
                return plan(
                    operation: .releaseSupervision,
                    snapshot: snapshot,
                    target: providerSessionTarget(snapshot),
                    support: .unsupported,
                    willStopProvider: .known(true),
                    willReleaseSlot: .unknown,
                    recoverableAfterward: resumeHandle(snapshot).isKnown
                        ? .known(true)
                        : .unknown,
                    expectedProcessScope: .known(.providerHost),
                    sideEffects: .known([]),
                    unsupported: .known([
                        "releasing this final Conduit OpenCode lease would also stop the provider host; use stop_provider_host if that consequence is intended"
                    ]),
                    unknown: .known([])
                )
            }
            return plan(
                operation: .releaseSupervision,
                snapshot: snapshot,
                target: providerSessionTarget(snapshot),
                support: .unknown,
                willStopProvider: .unknown,
                willReleaseSlot: .unknown,
                recoverableAfterward: resumeHandle(snapshot).isKnown
                    ? .known(true)
                    : .unknown,
                expectedProcessScope: .unknown,
                sideEffects: .unknown,
                unsupported: .known([]),
                unknown: .known([
                    "whether releasing this OpenCode client would also stop the shared provider host"
                ])
            )

        case .codexAppServer, .acp, .structuredCLI:
            return plan(
                operation: .releaseSupervision,
                snapshot: snapshot,
                target: providerSessionTarget(snapshot),
                support: .unsupported,
                willStopProvider: .unknown,
                willReleaseSlot: .unknown,
                recoverableAfterward: resumeHandle(snapshot).isKnown
                    ? .known(true)
                    : .unknown,
                expectedProcessScope: .unknown,
                sideEffects: .known([]),
                unsupported: .known([
                    "the current structured adapter has no detach/release path that guarantees the provider host continues unchanged"
                ]),
                unknown: .known([
                    "stopStructuredAdapter would change provider-host consequences and is not a release substitute"
                ])
            )

        case .directPTY:
            return plan(
                operation: .releaseSupervision,
                snapshot: snapshot,
                target: sessionTarget(snapshot),
                support: .unsupported,
                willStopProvider: .unknown,
                willReleaseSlot: .unknown,
                recoverableAfterward: .known(false),
                expectedProcessScope: .unknown,
                sideEffects: .known([]),
                unsupported: .known([
                    "direct PTY has no detach path; closing it terminates the PTY process"
                ]),
                unknown: .known([])
            )

        case .absent:
            return noLiveRuntime(.releaseSupervision, snapshot)
        }
    }

    private static func stopProviderHost(
        _ snapshot: LifecycleRuntimeSnapshot
    ) -> LifecyclePreflight {
        switch snapshot.kind {
        case .codexAppServer, .acp, .structuredCLI:
            return structuredStop(snapshot)

        case .openCodeHTTP:
            if snapshot.adapterStopWillStopProviderHost.value == true {
                return structuredStop(snapshot)
            }
            if snapshot.adapterStopWillStopProviderHost.value == false {
                return plan(
                    operation: .stopProviderHost,
                    snapshot: snapshot,
                    target: providerHostTarget(snapshot),
                    support: .unsupported,
                    willStopProvider: .known(false),
                    willReleaseSlot: .known(false),
                    recoverableAfterward: resumeHandle(snapshot).isKnown
                        ? .known(true)
                        : .unknown,
                    expectedProcessScope: .known(.providerHost),
                    sideEffects: .known([]),
                    unsupported: .known([
                        "this OpenCode client does not own the last live Conduit lease; stopping its adapter would leave the shared/external provider host running"
                    ]),
                    unknown: .known([])
                )
            }
            return plan(
                operation: .stopProviderHost,
                snapshot: snapshot,
                target: providerHostTarget(snapshot),
                support: .unknown,
                willStopProvider: .unknown,
                willReleaseSlot: .unknown,
                recoverableAfterward: resumeHandle(snapshot).isKnown
                    ? .known(true)
                    : .unknown,
                expectedProcessScope: .known(.providerHost),
                sideEffects: .unknown,
                unsupported: .known([]),
                unknown: .known([
                    "whether releasing this OpenCode lease would actually stop the provider host"
                ])
            )

        case .tmux:
            return plan(
                operation: .stopProviderHost,
                snapshot: snapshot,
                target: sessionTarget(snapshot),
                support: .supported,
                willStopProvider: .known(true),
                willReleaseSlot: .known(true),
                recoverableAfterward: .known(false),
                expectedProcessScope: .known(.session),
                sideEffects: .known([
                    "Conduit requests tmux kill-session and releases task execution capacity",
                    "task history is preserved"
                ]),
                unsupported: .known([]),
                unknown: .known([
                    "tmux termination is confirmed only after mutation; failure leaves the runtime detached",
                    "tmux process topology is not claimed as a direct Conduit-owned process tree"
                ])
            )

        case .directPTY:
            return plan(
                operation: .stopProviderHost,
                snapshot: snapshot,
                target: sessionTarget(snapshot),
                support: .supported,
                willStopProvider: .unknown,
                willReleaseSlot: .unknown,
                recoverableAfterward: .known(false),
                expectedProcessScope: .known(.session),
                sideEffects: .known([
                    "Conduit requests termination of the direct PTY runtime",
                    "task history is preserved",
                    "execution capacity is released only after process exit is observed"
                ]),
                unsupported: .known([]),
                unknown: .known([
                    "whether the direct PTY process has exited after the termination request",
                    "post-action process-tree reconciliation is required before declaring the stop complete"
                ])
            )

        case .absent:
            return noLiveRuntime(.stopProviderHost, snapshot)
        }
    }

    private static func structuredStop(
        _ snapshot: LifecycleRuntimeSnapshot
    ) -> LifecyclePreflight {
        plan(
            operation: .stopProviderHost,
            snapshot: snapshot,
            target: providerHostTarget(snapshot),
            support: .supported,
            willStopProvider: .known(true),
            willReleaseSlot: .known(true),
            recoverableAfterward: resumeHandle(snapshot).isKnown
                ? .known(true)
                : .unknown,
            expectedProcessScope: .known(.providerHost),
            sideEffects: .known([
                "Conduit stops the structured provider host/client for this task",
                "the Conduit task runtime closes and releases execution capacity",
                "provider session/history is not deleted"
            ]),
            unsupported: .known([]),
            unknown: .known([
                "provider-host termination is requested; post-action process-tree reconciliation is required before declaring the stop complete"
            ])
        )
    }

    private static func dedicatedSurface(
        operation: LifecycleOperation,
        snapshot: LifecycleRuntimeSnapshot,
        reason: String
    ) -> LifecyclePreflight {
        plan(
            operation: operation,
            snapshot: snapshot,
            target: providerSessionTarget(snapshot),
            support: .unsupported,
            willStopProvider: .known(false),
            willReleaseSlot: .known(false),
            recoverableAfterward: .known(true),
            expectedProcessScope: .known(.none),
            sideEffects: .known([]),
            unsupported: .known([reason]),
            unknown: .known([])
        )
    }

    private static func noLiveRuntime(
        _ operation: LifecycleOperation,
        _ snapshot: LifecycleRuntimeSnapshot
    ) -> LifecyclePreflight {
        plan(
            operation: operation,
            snapshot: snapshot,
            target: sessionTarget(snapshot),
            support: .unsupported,
            willStopProvider: .known(false),
            willReleaseSlot: .known(false),
            recoverableAfterward: resumeHandle(snapshot).isKnown
                ? .known(true)
                : .unknown,
            expectedProcessScope: .known(.none),
            sideEffects: .known([]),
            unsupported: .known(["no live runtime exists for this lifecycle mutation"]),
            unknown: .known([])
        )
    }

    private static func plan(
        operation: LifecycleOperation,
        snapshot: LifecycleRuntimeSnapshot,
        target: LifecycleTarget,
        support: LifecycleSupport,
        willStopProvider: OrchestrationValue<Bool>,
        willReleaseSlot: OrchestrationValue<Bool>,
        recoverableAfterward: OrchestrationValue<Bool>,
        expectedProcessScope: OrchestrationValue<LifecycleProcessScope>,
        sideEffects: OrchestrationValue<[String]>,
        unsupported: OrchestrationValue<[String]>,
        unknown: OrchestrationValue<[String]>
    ) -> LifecyclePreflight {
        LifecyclePreflight(
            operation: operation,
            target: target,
            support: support,
            willStopProvider: willStopProvider,
            willReleaseSlot: willReleaseSlot,
            recoverableAfterward: recoverableAfterward,
            exactResumeHandle: resumeHandle(snapshot),
            expectedProcessScope: expectedProcessScope,
            knownDescendantPIDs: knownDescendantPIDs(snapshot),
            sideEffects: sideEffects,
            unsupportedConsequences: unsupported,
            unknownConsequences: unknown,
            observation: SupervisionObservationStamp(
                authority: .conduitRecorded,
                freshness: .current,
                observedAt: .known(snapshot.observedAt)
            )
        )
    }

    private static func resumeHandle(
        _ snapshot: LifecycleRuntimeSnapshot
    ) -> OrchestrationValue<String> {
        if let provider = snapshot.providerSessionID.value {
            return .known(provider)
        }
        if let tmux = snapshot.tmuxSessionName.value {
            return .known(tmux)
        }
        return .unknown
    }

    private static func knownDescendantPIDs(
        _ snapshot: LifecycleRuntimeSnapshot
    ) -> OrchestrationValue<[Int32]> {
        guard let processTree = snapshot.processTree.value else {
            return .unknown
        }
        guard processTree.coverage == .complete else {
            return .unknown
        }
        return .known(
            processTree.descendants
                .filter { $0.liveness == .live }
                .map(\.pid)
                .sorted()
        )
    }

    private static func sessionTarget(
        _ snapshot: LifecycleRuntimeSnapshot
    ) -> LifecycleTarget {
        if snapshot.kind == .tmux, let tmux = snapshot.tmuxSessionName.value {
            return LifecycleTarget(kind: .session, identifier: .known(tmux))
        }
        if let provider = snapshot.providerSessionID.value {
            return LifecycleTarget(kind: .session, identifier: .known(provider))
        }
        if let attempt = snapshot.runtimeAttemptID.value {
            return LifecycleTarget(kind: .session, identifier: .known(attempt))
        }
        return LifecycleTarget(
            kind: .session,
            identifier: .known(snapshot.taskSessionID)
        )
    }

    private static func providerSessionTarget(
        _ snapshot: LifecycleRuntimeSnapshot
    ) -> LifecycleTarget {
        LifecycleTarget(
            kind: .session,
            identifier: snapshot.providerSessionID.isKnown
                ? snapshot.providerSessionID
                : .known(snapshot.taskSessionID)
        )
    }

    private static func providerHostTarget(
        _ snapshot: LifecycleRuntimeSnapshot
    ) -> LifecycleTarget {
        LifecycleTarget(kind: .providerHost, identifier: snapshot.providerHostID)
    }
}
