import XCTest
@testable import ConduitCore

final class DeterministicRoutingTests: XCTestCase {
    private let profile = ModelCapabilityProfileReference(
        profileID: "fixture-profile",
        version: "fixture-v1"
    )

    func testRegularChatGitHubIsPreferredWhenItSatisfiesRequirements() {
        let requirements = work()
        let decision = DeterministicRouteResolver.route(
            requirements: requirements,
            runtimes: [
                runtime(
                    id: "chat",
                    surface: .regularChatGitHub,
                    locality: .externalChat,
                    thread: .unknown,
                    canContinue: false,
                    canCreate: false,
                    configID: "chat-config"
                ),
                runtime(
                    id: "local",
                    surface: .localAgent,
                    locality: .localMachine,
                    thread: .known("ses-local"),
                    canContinue: true,
                    canCreate: true,
                    configID: "local-config"
                ),
            ],
            allowances: [],
            policy: policy()
        )

        XCTAssertEqual(decision.disposition, .selected)
        XCTAssertEqual(decision.selectedCandidateID, "chat::chat-config")
        XCTAssertEqual(
            decision.candidates.first(where: { $0.id == "chat::chat-config" })?.action,
            .externalRegularChat
        )
    }

    func testChatGPTWorkCannotSilentlyReplaceRegularChatWhenProhibited() {
        let requirements = work(
            allowedSurfaces: [.regularChatGitHub, .chatGPTWork],
            prohibitedSurfaces: [.chatGPTWork]
        )
        let decision = DeterministicRouteResolver.route(
            requirements: requirements,
            runtimes: [
                runtime(
                    id: "work",
                    surface: .chatGPTWork,
                    locality: .hosted,
                    thread: .known("work-thread"),
                    canContinue: true,
                    canCreate: true,
                    configID: "work-config"
                )
            ],
            allowances: [],
            policy: policy()
        )

        XCTAssertEqual(decision.disposition, .noEligibleRoute)
        XCTAssertTrue(decision.candidates[0].hardBlocks.contains(.surfaceProhibited(.chatGPTWork)))
    }

    func testMissingCapabilityReturnsNoEligibleRoute() {
        let requirements = work(requiredCapabilities: [.installedMacOSApp])
        let decision = DeterministicRouteResolver.route(
            requirements: requirements,
            runtimes: [
                runtime(
                    id: "chat",
                    surface: .regularChatGitHub,
                    locality: .externalChat,
                    thread: .unknown,
                    canContinue: false,
                    canCreate: false,
                    configID: "chat-config"
                )
            ],
            allowances: [],
            policy: policy()
        )

        XCTAssertEqual(decision.disposition, .noEligibleRoute)
        XCTAssertTrue(decision.reasons.contains(where: { $0.contains("installed_macos_app") }))
    }

    func testExistingExactThreadCanBeSelectedForContinuation() {
        let decision = DeterministicRouteResolver.route(
            requirements: work(
                allowedSurfaces: [.localAgent],
                locality: .localRequired
            ),
            runtimes: [
                runtime(
                    id: "local",
                    surface: .localAgent,
                    locality: .localMachine,
                    thread: .known("ses-exact"),
                    canContinue: true,
                    canCreate: true,
                    configID: "local-config"
                )
            ],
            allowances: [],
            policy: policy(surfacePreference: [.localAgent])
        )

        XCTAssertEqual(decision.disposition, .selected)
        XCTAssertEqual(decision.selectedCandidateID, "local::local-config")
        XCTAssertEqual(decision.candidates[0].exactThreadID.value, "ses-exact")
        XCTAssertEqual(decision.candidates[0].action, .continueExisting)
    }

    func testEligibleConfigurationWithoutThreadReturnsCreationRequiredWhenCreationDisabled() {
        let decision = DeterministicRouteResolver.route(
            requirements: work(
                allowedSurfaces: [.localAgent],
                locality: .localRequired
            ),
            runtimes: [
                runtime(
                    id: "local",
                    surface: .localAgent,
                    locality: .localMachine,
                    thread: .unknown,
                    canContinue: true,
                    canCreate: true,
                    configID: "local-config"
                )
            ],
            allowances: [],
            policy: policy(surfacePreference: [.localAgent], allowCreation: false)
        )

        XCTAssertEqual(decision.disposition, .threadCreationRequired)
        XCTAssertEqual(decision.selectedCandidateID, "local::local-config")
        XCTAssertEqual(decision.candidates[0].action, .createWorker)
    }

    func testWorkspaceWriterCollisionBlocksOtherwiseEligibleRoute() {
        var local = runtime(
            id: "local",
            surface: .localAgent,
            locality: .localMachine,
            thread: .known("ses-exact"),
            canContinue: true,
            canCreate: true,
            configID: "local-config"
        )
        local.workspace = .writerCollision

        let decision = DeterministicRouteResolver.route(
            requirements: work(
                allowedSurfaces: [.localAgent],
                locality: .localRequired,
                workspace: .isolatedWritable
            ),
            runtimes: [local],
            allowances: [],
            policy: policy(surfacePreference: [.localAgent])
        )

        XCTAssertEqual(decision.disposition, .workspaceCollision)
        XCTAssertTrue(decision.candidates[0].hardBlocks.contains(.workspaceCollision))
    }

    func testUnknownAllowanceRemainsUnknownInsteadOfBecomingFree() {
        let local = runtime(
            id: "local",
            surface: .localAgent,
            locality: .localMachine,
            thread: .known("ses-exact"),
            canContinue: true,
            canCreate: true,
            configID: "local-config",
            allowancePoolID: .known("provider-pool")
        )

        let permissive = DeterministicRouteResolver.route(
            requirements: work(
                allowedSurfaces: [.localAgent],
                locality: .localRequired,
                requiresKnownAllowance: false
            ),
            runtimes: [local],
            allowances: [],
            policy: policy(surfacePreference: [.localAgent])
        )
        XCTAssertEqual(permissive.disposition, .selected)
        XCTAssertEqual(permissive.candidates[0].allowance.state, .unknown)

        let constrained = DeterministicRouteResolver.route(
            requirements: work(
                allowedSurfaces: [.localAgent],
                locality: .localRequired,
                requiresKnownAllowance: true
            ),
            runtimes: [local],
            allowances: [],
            policy: policy(surfacePreference: [.localAgent])
        )
        XCTAssertEqual(constrained.disposition, .noEligibleRoute)
        XCTAssertTrue(constrained.reasons.contains(where: { $0.contains("UNKNOWN") }))
    }

    func testUnknownContextCapacityFailsClosedWhenContextRequirementIsKnown() {
        let decision = DeterministicRouteResolver.route(
            requirements: work(
                allowedSurfaces: [.localAgent],
                locality: .localRequired,
                requiredContextTokens: .known(20_000)
            ),
            runtimes: [
                runtime(
                    id: "local",
                    surface: .localAgent,
                    locality: .localMachine,
                    thread: .known("ses-exact"),
                    canContinue: true,
                    canCreate: true,
                    configID: "local-config",
                    contextWindow: .unknown
                )
            ],
            allowances: [],
            policy: policy(surfacePreference: [.localAgent])
        )

        XCTAssertEqual(decision.disposition, .noEligibleRoute)
        XCTAssertTrue(decision.candidates[0].hardBlocks.contains(.contextCapacityUnknown))
    }

    func testSameInputsProduceSameDecision() {
        let requirements = work(
            allowedSurfaces: [.localAgent],
            locality: .localRequired
        )
        let runtimes = [
            runtime(
                id: "local",
                surface: .localAgent,
                locality: .localMachine,
                thread: .known("ses-exact"),
                canContinue: true,
                canCreate: true,
                configID: "local-config"
            )
        ]
        let policy = policy(surfacePreference: [.localAgent])

        XCTAssertEqual(
            DeterministicRouteResolver.route(
                requirements: requirements,
                runtimes: runtimes,
                allowances: [],
                policy: policy
            ),
            DeterministicRouteResolver.route(
                requirements: requirements,
                runtimes: runtimes,
                allowances: [],
                policy: policy
            )
        )
    }

    func testEqualBestCandidatesRequireExplicitPolicyInsteadOfInventedModelRanking() {
        let requirements = work(
            allowedSurfaces: [.localAgent],
            locality: .localRequired
        )
        let first = runtime(
            id: "a",
            surface: .localAgent,
            locality: .localMachine,
            thread: .known("ses-a"),
            canContinue: true,
            canCreate: true,
            configID: "model-a"
        )
        let second = runtime(
            id: "b",
            surface: .localAgent,
            locality: .localMachine,
            thread: .known("ses-b"),
            canContinue: true,
            canCreate: true,
            configID: "model-b"
        )

        let unresolved = DeterministicRouteResolver.route(
            requirements: requirements,
            runtimes: [second, first],
            allowances: [],
            policy: policy(surfacePreference: [.localAgent])
        )
        XCTAssertEqual(unresolved.disposition, .policyInsufficient)
        XCTAssertNil(unresolved.selectedCandidateID)

        let explicit = DeterministicRouteResolver.route(
            requirements: requirements,
            runtimes: [second, first],
            allowances: [],
            policy: DeterministicRoutingPolicy(
                version: "fixture-policy",
                surfacePreference: [.localAgent],
                configurationPreference: ["model-b", "model-a"],
                allowWorkerCreation: false
            )
        )
        XCTAssertEqual(explicit.disposition, .selected)
        XCTAssertEqual(explicit.selectedCandidateID, "b::model-b")
    }

    private func work(
        requiredCapabilities: Set<RoutingRuntimeCapability> = [.sourceInspection, .gitHubMutation],
        allowedSurfaces: Set<RoutingExecutionSurface> = [.regularChatGitHub, .localAgent],
        prohibitedSurfaces: Set<RoutingExecutionSurface> = [.chatGPTWork],
        locality: RoutingLocalityRequirement = .any,
        workspace: RoutingWorkspaceRequirement = .none,
        requiredContextTokens: OrchestrationValue<Int> = .unknown,
        requiresKnownAllowance: Bool = false
    ) -> RoutingWorkRequirements {
        RoutingWorkRequirements(
            id: "requirements-1",
            packageID: "package-1",
            role: .implementer,
            taskClass: .implementation,
            requiredCapabilities: requiredCapabilities,
            requiredTools: [],
            allowedSurfaces: allowedSurfaces,
            prohibitedSurfaces: prohibitedSurfaces,
            locality: locality,
            workspace: workspace,
            requiredContextTokens: requiredContextTokens,
            requiresKnownAllowance: requiresKnownAllowance
        )
    }

    private func policy(
        surfacePreference: [RoutingExecutionSurface] = [.regularChatGitHub, .localAgent],
        allowCreation: Bool = false
    ) -> DeterministicRoutingPolicy {
        DeterministicRoutingPolicy(
            version: "fixture-policy",
            surfacePreference: surfacePreference,
            configurationPreference: [],
            allowWorkerCreation: allowCreation
        )
    }

    private func runtime(
        id: String,
        surface: RoutingExecutionSurface,
        locality: RoutingLocality,
        thread: OrchestrationValue<String>,
        canContinue: Bool,
        canCreate: Bool,
        configID: String,
        allowancePoolID: OrchestrationValue<String> = .unknown,
        contextWindow: OrchestrationValue<Int> = .known(128_000)
    ) -> RuntimeCapabilityProfile {
        RuntimeCapabilityProfile(
            id: id,
            surface: surface,
            locality: locality,
            capabilities: [.sourceInspection, .gitHubMutation],
            tools: [],
            exactThreadID: thread,
            canContinueExisting: canContinue,
            canCreateWorker: canCreate,
            workspace: .notRequired,
            configurations: [
                ModelExecutionConfiguration(
                    id: configID,
                    profile: profile,
                    providerID: "fixture-provider",
                    modelID: "fixture-model",
                    applicableRoles: [.implementer],
                    applicableTaskClasses: [.implementation],
                    capabilities: [],
                    tools: [],
                    contextWindowTokens: contextWindow,
                    allowancePoolID: allowancePoolID
                )
            ]
        )
    }
}
