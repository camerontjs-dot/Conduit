import XCTest
@testable import ConduitCore

final class DeterministicRoutingPressureTests: XCTestCase {
    func testModelMetadataCannotSupplyMissingRuntimeCapability() {
        var configuration = config()
        configuration.capabilities = [.localShell]
        let decision = route(requirements: work(capabilities: [.localShell]), runtimes: [runtime(configuration: configuration)])
        XCTAssertNotEqual(decision.disposition, .selected)
        XCTAssertNil(decision.selectedCandidateID)
    }

    func testModelMetadataCannotSupplyMissingRuntimeTool() {
        var configuration = config()
        configuration.tools = ["shell"]
        var requirements = work()
        requirements.requiredTools = ["shell"]
        let decision = route(requirements: requirements, runtimes: [runtime(configuration: configuration)])
        XCTAssertNotEqual(decision.disposition, .selected)
        XCTAssertNil(decision.selectedCandidateID)
    }

    func testEmptyExactThreadDoesNotAuthorizeContinuation() {
        let decision = route(runtimes: [runtime(thread: .known("  "))])
        XCTAssertNotEqual(decision.disposition, .selected)
        XCTAssertNil(decision.selectedCandidateID)
    }

    func testReadyWorkspaceRequiresExactIdentity() {
        var local = runtime()
        local.workspace = .init(kind: .ready, workspaceID: .unknown)
        var requirements = work()
        requirements.workspace = .isolatedWritable
        let decision = route(requirements: requirements, runtimes: [local])
        XCTAssertNotEqual(decision.disposition, .selected)
        XCTAssertNil(decision.selectedCandidateID)
    }

    func testNegativeContextRequirementDoesNotBecomeEligible() {
        var requirements = work()
        requirements.requiredContextTokens = .known(-1)
        let decision = route(requirements: requirements, runtimes: [runtime()])
        XCTAssertNotEqual(decision.disposition, .selected)
        XCTAssertNil(decision.selectedCandidateID)
    }

    func testUnsupportedPolicySchemaDoesNotRoute() {
        let decision = route(runtimes: [runtime()], policy: .init(schemaVersion: 999, version: "future", surfacePreference: [.localAgent]))
        XCTAssertNotEqual(decision.disposition, .selected)
        XCTAssertNil(decision.selectedCandidateID)
    }

    func testMissingThreadCannotDisplaceExistingEligibleThread() {
        var absent = runtime(id: "absent", thread: .unknown, configuration: config(id: "favored"))
        absent.canContinueExisting = false
        let existing = runtime(id: "existing", configuration: config(id: "usable"))
        let decision = route(runtimes: [absent, existing], policy: .init(version: "fixture", surfacePreference: [.localAgent], configurationPreference: ["favored", "usable"]))
        XCTAssertEqual(decision.disposition, .selected)
        XCTAssertEqual(decision.selectedCandidateID, "existing::usable")
    }

    func testEmptyCandidateSnapshotHasInspectableReason() {
        let decision = route(runtimes: [])
        XCTAssertNotEqual(decision.disposition, .selected)
        XCTAssertFalse(decision.reasons.isEmpty)
    }

    func testDuplicateAllowanceIdentitiesDoNotTrapOrSelect() {
        let pool = AllowancePoolMetadata(poolID: "duplicate", unit: .turns, remaining: .known(1))
        let decision = DeterministicRouteResolver.route(requirements: work(), runtimes: [runtime()], allowances: [pool, pool], policy: .init(version: "fixture"))
        XCTAssertNotEqual(decision.disposition, .selected)
        XCTAssertNil(decision.selectedCandidateID)
    }

    func testDuplicateSurfaceAndConfigurationPreferencesFailClosed() {
        for policy in [
            DeterministicRoutingPolicy(version: "fixture", surfacePreference: [.localAgent, .localAgent]),
            DeterministicRoutingPolicy(version: "fixture", configurationPreference: ["config", "config"])
        ] {
            let decision = route(runtimes: [runtime()], policy: policy)
            XCTAssertEqual(decision.disposition, .invalidInput)
            XCTAssertNil(decision.selectedCandidateID)
        }
    }

    func testDuplicateRuntimeAndDelimitedCandidateIdentityFailClosed() {
        for inputs in [[runtime(), runtime()], [runtime(id: "a::b")], [runtime(configuration: config(id: "a::b"))]] {
            let decision = route(runtimes: inputs)
            XCTAssertEqual(decision.disposition, .invalidInput)
            XCTAssertNil(decision.selectedCandidateID)
        }
    }

    func testDuplicateModelConfigurationsCannotSelectAmbiguousIdentity() {
        var local = runtime()
        local.configurations = [config(), config()]
        XCTAssertEqual(route(runtimes: [local]).disposition, .invalidInput)
    }

    func testSupportedUnsupportedUnknownAndStaleCapabilityClaimsStayDistinct() {
        for support in [RoutingCapabilitySupport.supported, .unsupported, .unknown] {
            var local = runtime()
            local.capabilities = [.localShell]
            local.capabilityClaims = [.init(capability: .localShell, support: support, evidence: [.init(reference: "fixture-only")], freshness: .current)]
            let decision = route(requirements: work(capabilities: [.localShell]), runtimes: [local])
            XCTAssertEqual(decision.disposition, support == .supported ? .selected : .noEligibleRoute)
            XCTAssertEqual(decision.inputs.runtimes[0].capabilityClaims[0].support, support)
        }
        var stale = runtime()
        stale.capabilityClaims = [.init(capability: .localShell, support: .supported, freshness: .stale)]
        let decision = route(requirements: work(capabilities: [.localShell]), runtimes: [stale])
        XCTAssertEqual(decision.disposition, .noEligibleRoute)
        XCTAssertTrue(decision.candidates[0].hardBlocks.contains(.unknownCapabilities([.localShell])))
    }

    func testModelClaimCannotCreateIndependentQualificationRuntime() {
        var configuration = config()
        configuration.capabilities = [.independentQualification]
        var requirements = work()
        requirements.requiresIndependentVerification = true
        let decision = route(requirements: requirements, runtimes: [runtime(configuration: configuration)])
        XCTAssertEqual(decision.disposition, .noEligibleRoute)
        XCTAssertTrue(decision.candidates[0].hardBlocks.contains(.independenceCapabilityMissing))
    }

    func testCreationDisabledPrefersUsableContinuationWithoutChangingPolicy() {
        var create = runtime(id: "create", thread: .unknown, configuration: config(id: "favored"))
        create.canCreateWorker = true
        let existing = runtime(id: "existing", configuration: config(id: "usable"))
        let policy = DeterministicRoutingPolicy(version: "fixture", surfacePreference: [.localAgent], configurationPreference: ["favored", "usable"])
        let decision = route(runtimes: [create, existing], policy: policy)
        XCTAssertEqual(decision.disposition, .selected)
        XCTAssertEqual(decision.selectedCandidateID, "existing::usable")
        XCTAssertFalse(decision.inputs.policy.allowWorkerCreation)
        XCTAssertEqual(route(runtimes: [create], policy: policy).disposition, .threadCreationRequired)
    }

    func testDefaultPolicyProhibitsWorkEvenWhenRequirementsOmitProhibition() {
        var requirements = work()
        requirements.allowedSurfaces = [.chatGPTWork]
        requirements.prohibitedSurfaces = []
        var workRuntime = runtime()
        workRuntime.surface = .chatGPTWork
        let decision = route(requirements: requirements, runtimes: [workRuntime])
        XCTAssertEqual(decision.disposition, .noEligibleRoute)
        XCTAssertTrue(decision.candidates[0].hardBlocks.contains(.surfaceProhibited(.chatGPTWork)))
    }

    func testKnownRequiredAllowanceNeedsKnownUnitAndAvailableResource() {
        var configuration = config()
        configuration.allowancePoolID = .known("pool")
        var requirements = work()
        requirements.requiresKnownAllowance = true
        for pool in [
            AllowancePoolMetadata(poolID: "pool", unit: .unknown, remaining: .known(1)),
            AllowancePoolMetadata(poolID: "pool", unit: .turns, remaining: .unknown),
            AllowancePoolMetadata(poolID: "pool", unit: .turns, remaining: .known(0))
        ] {
            let decision = DeterministicRouteResolver.route(requirements: requirements, runtimes: [runtime(configuration: configuration)], allowances: [pool], policy: .init(version: "fixture"))
            XCTAssertEqual(decision.disposition, .noEligibleRoute)
            XCTAssertNil(decision.selectedCandidateID)
        }
    }

    func testMalformedNumericAllowanceFailsClosedWithoutFabricatingReceipt() {
        for remaining in [Double.nan, Double.infinity, -1] {
            let decision = DeterministicRouteResolver.route(requirements: work(), runtimes: [runtime()], allowances: [.init(poolID: "pool", unit: .turns, remaining: .known(remaining))], policy: .init(version: "fixture"))
            XCTAssertEqual(decision.disposition, .invalidInput)
            XCTAssertNil(decision.selectedCandidateID)
            if !remaining.isFinite { XCTAssertThrowsError(try decision.receiptData()) }
        }
    }

    func testReceiptRetainsInputsReasonsUnknownsAndRoundTrips() throws {
        var requirements = work(capabilities: [.localShell])
        requirements.requiredContextTokens = .known(100)
        var local = runtime()
        local.capabilityClaims = [.init(capability: .localShell, support: .supported, evidence: [.init(reference: "synthetic-fixture", sampleSize: .unknown)])]
        let decision = route(requirements: requirements, runtimes: [local])
        XCTAssertEqual(decision.disposition, .selected)
        XCTAssertFalse(decision.reasons.isEmpty)
        XCTAssertFalse(decision.preferenceRulesApplied.isEmpty)
        XCTAssertEqual(decision.inputs.requirements, requirements)
        XCTAssertEqual(decision.candidates[0].allowance, .unknown)
        XCTAssertEqual(decision.inputs.runtimes[0].capabilityClaims[0].freshness, .unknown)
        XCTAssertEqual(try JSONDecoder().decode(RouteDecision.self, from: decision.receiptData()), decision)
        XCTAssertEqual(try decision.receiptData(), try decision.receiptData())
        print("ROUTING_FIXTURE_FINGERPRINT=\(try decision.fingerprint())")
    }

    func testOrderOfUnorderedFactsDoesNotChooseOrRewritePreference() throws {
        let requirements = work(capabilities: [.localShell, .localFilesystem, .sourceInspection])
        var first = runtime(id: "a", configuration: config(id: "alpha"))
        first.capabilities = [.localShell, .localFilesystem, .sourceInspection]
        var second = runtime(id: "b", configuration: config(id: "beta"))
        second.capabilities = [.sourceInspection, .localFilesystem, .localShell]
        let policy = DeterministicRoutingPolicy(version: "fixture", surfacePreference: [.localAgent], configurationPreference: ["beta", "alpha"])
        let forward = route(requirements: requirements, runtimes: [first, second], policy: policy)
        let reverse = route(requirements: requirements, runtimes: [second, first], policy: policy)
        XCTAssertEqual(forward, reverse)
        XCTAssertEqual(try forward.receiptData(), try reverse.receiptData())
        XCTAssertEqual(forward.selectedCandidateID, "b::beta")
        XCTAssertEqual(forward.inputs.policy.configurationPreference, ["beta", "alpha"])
    }

    func testMalformedUnknownPayloadCannotBecomeKnown() throws {
        let data = Data("{\"state\":\"unknown\",\"value\":\"thread\"}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(OrchestrationValue<String>.self, from: data))
    }

    func testKnownWriterCollisionRejectsContinuationWithoutWorkspaceRequirement() {
        var local = runtime()
        local.workspace = .writerCollision
        let decision = route(runtimes: [local])
        XCTAssertEqual(decision.disposition, .workspaceCollision)
        XCTAssertNil(decision.selectedCandidateID)
    }

    private func work(capabilities: Set<RoutingRuntimeCapability> = []) -> RoutingWorkRequirements {
        .init(id: "requirements", packageID: "package", role: .implementer, taskClass: .implementation, requiredCapabilities: capabilities, allowedSurfaces: [.localAgent], prohibitedSurfaces: [.chatGPTWork])
    }

    private func config(id: String = "config") -> ModelExecutionConfiguration {
        .init(id: id, profile: .init(profileID: "fixture", version: "v1"), providerID: "provider", modelID: "model", applicableRoles: [.implementer], applicableTaskClasses: [.implementation], contextWindowTokens: .known(1024))
    }

    private func runtime(id: String = "runtime", thread: OrchestrationValue<String> = .known("thread"), configuration: ModelExecutionConfiguration? = nil) -> RuntimeCapabilityProfile {
        .init(id: id, surface: .localAgent, locality: .localMachine, exactThreadID: thread, canContinueExisting: true, canCreateWorker: false, configurations: [configuration ?? config()])
    }

    private func route(requirements: RoutingWorkRequirements? = nil, runtimes: [RuntimeCapabilityProfile], policy: DeterministicRoutingPolicy = .init(version: "fixture", surfacePreference: [.localAgent])) -> RouteDecision {
        DeterministicRouteResolver.route(requirements: requirements ?? work(), runtimes: runtimes, allowances: [], policy: policy)
    }
}
