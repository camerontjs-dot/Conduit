import Foundation
import XCTest
@testable import ConduitCore

final class LifecyclePreflightPlannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(
        kind: LifecycleRuntimeKind,
        providerSessionID: OrchestrationValue<String> = .unknown,
        providerHostID: OrchestrationValue<String> = .unknown,
        tmuxSessionName: OrchestrationValue<String> = .unknown,
        turnActive: OrchestrationValue<Bool> = .unknown,
        hostStopsOnAdapterStop: OrchestrationValue<Bool> = .unknown
    ) -> LifecycleRuntimeSnapshot {
        LifecycleRuntimeSnapshot(
            kind: kind,
            taskSessionID: "task-fixture",
            runtimeAttemptID: .known("attempt-fixture"),
            providerSessionID: providerSessionID,
            providerHostID: providerHostID,
            tmuxSessionName: tmuxSessionName,
            turnActive: turnActive,
            adapterStopWillStopProviderHost: hostStopsOnAdapterStop,
            observedAt: now
        )
    }

    func testOpenCodeLastOwnedLeaseStopReportsHostStopAndProviderResume() {
        let input = snapshot(
            kind: .openCodeHTTP,
            providerSessionID: .known("ses-open"),
            providerHostID: .known("pid:4100"),
            turnActive: .known(false),
            hostStopsOnAdapterStop: .known(true)
        )

        let plan = LifecyclePreflightPlanner.preflight(
            operation: .stopProviderHost,
            snapshot: input
        )

        XCTAssertEqual(plan.support, .supported)
        XCTAssertEqual(plan.target.kind, .providerHost)
        XCTAssertEqual(plan.target.identifier.value, "pid:4100")
        XCTAssertEqual(plan.willStopProvider.value, true)
        XCTAssertEqual(plan.willReleaseSlot.value, true)
        XCTAssertEqual(plan.recoverableAfterward.value, true)
        XCTAssertEqual(plan.exactResumeHandle.value, "ses-open")
        XCTAssertEqual(plan.expectedProcessScope.value, .providerHost)
        XCTAssertTrue(
            plan.sideEffects.value?.contains(
                "provider session/history is not deleted"
            ) == true
        )
    }

    func testOpenCodeSharedHostRefusesStopInsteadOfPretendingClientReleaseStopsHost() {
        let plan = LifecyclePreflightPlanner.preflight(
            operation: .stopProviderHost,
            snapshot: snapshot(
                kind: .openCodeHTTP,
                providerSessionID: .known("ses-shared"),
                providerHostID: .known("pid:4200"),
                hostStopsOnAdapterStop: .known(false)
            )
        )

        XCTAssertEqual(plan.support, .unsupported)
        XCTAssertEqual(plan.willStopProvider.value, false)
        XCTAssertEqual(plan.willReleaseSlot.value, false)
        XCTAssertTrue(
            plan.unsupportedConsequences.value?.first?
                .contains("shared/external provider host") == true
        )
    }

    func testOpenCodeUnknownLeaseConsequenceStaysUnknown() {
        let plan = LifecyclePreflightPlanner.preflight(
            operation: .stopProviderHost,
            snapshot: snapshot(
                kind: .openCodeHTTP,
                providerSessionID: .known("ses-open"),
                hostStopsOnAdapterStop: .unknown
            )
        )

        XCTAssertEqual(plan.support, .unknown)
        XCTAssertEqual(plan.willStopProvider.state, .unknown)
        XCTAssertEqual(plan.willReleaseSlot.state, .unknown)
        XCTAssertEqual(plan.unknownConsequences.state, .known)
        XCTAssertTrue(
            plan.unknownConsequences.value?.first?
                .contains("whether releasing this OpenCode lease") == true
        )
    }

    func testCodexStopPreservesThreadResumeHandleWithoutClaimingDeletion() {
        let plan = LifecyclePreflightPlanner.preflight(
            operation: .stopProviderHost,
            snapshot: snapshot(
                kind: .codexAppServer,
                providerSessionID: .known("thread-codex"),
                providerHostID: .known("pid:5100"),
                turnActive: .known(false),
                hostStopsOnAdapterStop: .known(true)
            )
        )

        XCTAssertEqual(plan.support, .supported)
        XCTAssertEqual(plan.willStopProvider.value, true)
        XCTAssertEqual(plan.recoverableAfterward.value, true)
        XCTAssertEqual(plan.exactResumeHandle.value, "thread-codex")
        XCTAssertTrue(
            plan.sideEffects.value?.contains(
                "provider session/history is not deleted"
            ) == true
        )
    }

    func testTmuxReleaseAndDirectPTYTerminationAreDifferentOperations() {
        let tmux = LifecyclePreflightPlanner.preflight(
            operation: .releaseSupervision,
            snapshot: snapshot(
                kind: .tmux,
                tmuxSessionName: .known("conduit-task")
            )
        )
        let directRelease = LifecyclePreflightPlanner.preflight(
            operation: .releaseSupervision,
            snapshot: snapshot(kind: .directPTY)
        )
        let directStop = LifecyclePreflightPlanner.preflight(
            operation: .stopProviderHost,
            snapshot: snapshot(kind: .directPTY)
        )

        XCTAssertEqual(tmux.support, .supported)
        XCTAssertEqual(tmux.willStopProvider.value, false)
        XCTAssertEqual(tmux.willReleaseSlot.value, true)
        XCTAssertEqual(tmux.recoverableAfterward.value, true)
        XCTAssertEqual(tmux.exactResumeHandle.value, "conduit-task")
        XCTAssertEqual(tmux.expectedProcessScope.value, .none)

        XCTAssertEqual(directRelease.support, .unsupported)
        XCTAssertEqual(directStop.support, .supported)
        XCTAssertEqual(directStop.willStopProvider.value, true)
        XCTAssertEqual(directStop.recoverableAfterward.value, false)
        XCTAssertEqual(directStop.expectedProcessScope.value, .session)
    }

    func testAbortTurnDoesNotStopProviderOrReleaseCapacity() {
        let plan = LifecyclePreflightPlanner.preflight(
            operation: .abortTurn,
            snapshot: snapshot(
                kind: .codexAppServer,
                providerSessionID: .known("thread-codex"),
                turnActive: .known(true),
                hostStopsOnAdapterStop: .known(true)
            )
        )

        XCTAssertEqual(plan.support, .supported)
        XCTAssertEqual(plan.target.kind, .turn)
        XCTAssertEqual(plan.willStopProvider.value, false)
        XCTAssertEqual(plan.willReleaseSlot.value, false)
        XCTAssertEqual(plan.recoverableAfterward.value, true)
        XCTAssertEqual(plan.expectedProcessScope.value, .turn)
    }

    func testOpenCodeSharedHostCanReleaseSupervisionWithoutStoppingHost() {
        let plan = LifecyclePreflightPlanner.preflight(
            operation: .releaseSupervision,
            snapshot: snapshot(
                kind: .openCodeHTTP,
                providerSessionID: .known("ses-shared"),
                providerHostID: .known("pid:4200"),
                hostStopsOnAdapterStop: .known(false)
            )
        )

        XCTAssertEqual(plan.support, .supported)
        XCTAssertEqual(plan.willStopProvider.value, false)
        XCTAssertEqual(plan.willReleaseSlot.value, true)
        XCTAssertEqual(plan.recoverableAfterward.value, true)
        XCTAssertEqual(plan.exactResumeHandle.value, "ses-shared")
        XCTAssertTrue(
            plan.sideEffects.value?.contains(
                "the shared or externally owned OpenCode provider host remains running"
            ) == true
        )
    }

    func testReleaseWhileStructuredProviderContinuesFailsClosed() {
        let plan = LifecyclePreflightPlanner.preflight(
            operation: .releaseSupervision,
            snapshot: snapshot(
                kind: .codexAppServer,
                providerSessionID: .known("thread-codex"),
                hostStopsOnAdapterStop: .known(true)
            )
        )

        XCTAssertEqual(plan.support, .unsupported)
        XCTAssertEqual(plan.willStopProvider.state, .unknown)
        XCTAssertEqual(plan.willReleaseSlot.state, .unknown)
        XCTAssertTrue(
            plan.unsupportedConsequences.value?.first?
                .contains("no detach/release path") == true
        )
    }

    func testProviderHistoryArchiveIsExplicitlyUnsupportedAndNonMutating() {
        let plan = LifecyclePreflightPlanner.preflight(
            operation: .archiveProviderHistory,
            snapshot: snapshot(
                kind: .codexAppServer,
                providerSessionID: .known("thread-codex")
            )
        )

        XCTAssertEqual(plan.support, .unsupported)
        XCTAssertEqual(plan.willStopProvider.value, false)
        XCTAssertEqual(plan.willReleaseSlot.value, false)
        XCTAssertEqual(plan.expectedProcessScope.value, .none)
        XCTAssertTrue(
            plan.unsupportedConsequences.value?.first?
                .contains("no provider-history archive/delete") == true
        )
    }

    func testPlanningIsPureAndDoesNotMutateRuntimeSnapshot() {
        let input = snapshot(
            kind: .tmux,
            tmuxSessionName: .known("conduit-task")
        )
        let before = input

        _ = LifecyclePreflightPlanner.preflight(
            operation: .releaseSupervision,
            snapshot: input
        )

        XCTAssertEqual(input, before)
    }

    func testInactiveTurnIsUnsupportedRatherThanConvertedToHostStop() {
        let plan = LifecyclePreflightPlanner.preflight(
            operation: .abortTurn,
            snapshot: snapshot(
                kind: .openCodeHTTP,
                providerSessionID: .known("ses-open"),
                turnActive: .known(false),
                hostStopsOnAdapterStop: .known(true)
            )
        )

        XCTAssertEqual(plan.support, .unsupported)
        XCTAssertEqual(plan.willStopProvider.value, false)
        XCTAssertEqual(plan.willReleaseSlot.value, false)
        XCTAssertEqual(plan.expectedProcessScope.value, .turn)
    }
}
