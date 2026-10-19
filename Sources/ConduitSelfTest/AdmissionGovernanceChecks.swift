import Foundation
import ConduitCore

private final class AdmissionFixtureObserver: ProviderSessionObserving {
        let providerID = "fixture"
        var listedSessionID = "ses_existing"
        var observedSessionID = "ses_existing"
        var listCalls = 0
        var observeCalls = 0

        func listSessions(
            bindingResolver: ((String) -> ProviderObservationBinding?)?
        ) throws -> [WorkerLineage] {
            listCalls += 1
            return [
                makeWorker(
                    sessionID: listedSessionID,
                    binding: bindingResolver?(listedSessionID)
                )
            ]
        }

        func observeSession(
            providerSessionID: String,
            binding: ProviderObservationBinding?
        ) throws -> WorkerLineage {
            observeCalls += 1
            return makeWorker(
                sessionID: observedSessionID,
                binding: binding
            )
        }

        private func makeWorker(
            sessionID: String,
            binding: ProviderObservationBinding?
        ) -> WorkerLineage {
            let observed = SupervisionObservationStamp(
                authority: .providerObserved,
                freshness: .unknown,
                observedAt: .known(
                    Date(timeIntervalSince1970: 1_797_000_000)
                )
            )
            return WorkerLineage(
                conduitTaskID: binding.map {
                    .known($0.conduitTaskID)
                } ?? .unknown,
                runtimeAttemptID: binding?.runtimeAttemptID.map {
                    .known($0)
                } ?? .unknown,
                runtime: .known("fixture"),
                adapter: .known("fixture_read_only"),
                providerHostID: .unknown,
                providerSessionID: .known(sessionID),
                turns: [
                    ProviderTurnLineage(
                        turnID: .known("turn-1"),
                        state: .completed,
                        model: .known(
                            ProviderModelIdentity(
                                providerID: "fixture-model-provider",
                                modelID: "fixture-model"
                            )
                        ),
                        observation: observed
                    )
                ],
                workspace: WorkerWorkspaceLineage(
                    projectSlug: .unknown,
                    cwd: .known("/tmp/fixture"),
                    repositoryRoot: .unknown,
                    worktree: .unknown
                ),
                process: WorkerProcessLineage(
                    launcherPID: .unknown,
                    processGroupID: .unknown,
                    parentPID: .unknown
                ),
                origin: .unknown,
                relationship: .discovered,
                writerControllerID: .unknown,
                terminal: WorkerTerminalState(
                    receipt: .unknown,
                    verification: .unknown,
                    objectiveAcceptance: .unknown
                ),
                observation: observed,
                providerSpecific: .unknown
            )
        }
    }

func runAdmissionGovernanceChecks(_ check: (String, Bool) -> Void) {
    enum Denied: Error { case admission }
    do {
        let observer = AdmissionFixtureObserver()
        let registry = ProviderSessionAuthorityRegistry()
        let coordinator = ProviderSessionAuthorityCoordinator(observer: observer, registry: registry)
        var charges = 0
        let deny: () throws -> Void = { charges += 1; throw Denied.admission }
        let before = try registry.snapshot(providerID: "fixture", providerSessionID: "ses_existing")
        do {
            _ = try coordinator.adoptSession(providerSessionID: "ses_existing", controllerID: "A", admitWrite: deny)
            check("adoption denial throws", false)
        } catch { check("adoption denial throws", true) }
        check("denied adoption preserves ownership", try registry.snapshot(providerID: "fixture", providerSessionID: "ses_existing") == before)
        _ = try? coordinator.adoptSession(providerSessionID: "ses_existing", controllerID: " ", admitWrite: deny)
        observer.observedSessionID = "wrong"
        _ = try? coordinator.adoptSession(providerSessionID: "ses_existing", controllerID: "A", admitWrite: deny)
        check("invalid adoption does not charge admission", charges == 1)
        observer.observedSessionID = "ses_existing"
        _ = try coordinator.adoptSession(providerSessionID: "ses_existing", controllerID: "A")
        let owned = try registry.snapshot(providerID: "fixture", providerSessionID: "ses_existing")
        _ = try? coordinator.adoptSession(providerSessionID: "ses_existing", controllerID: "B", admitWrite: deny)
        check("denied adoption preserves existing writer", try registry.snapshot(providerID: "fixture", providerSessionID: "ses_existing") == owned)
        check("admitted adoption preserves collision", try coordinator.adoptSession(providerSessionID: "ses_existing", controllerID: "B", admitWrite: {}).receipt.disposition == .writerCollision)
    } catch { check("admission governance fixture: \(error)", false) }
}
