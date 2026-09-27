import XCTest
@testable import ConduitCore

final class SessionAPIReadinessTests: XCTestCase {
    func testQualificationPortOverridePreservesDefaultAndAcceptsReservedRange() throws {
        XCTAssertEqual(
            try SessionAPIListenPort.resolved(environment: [:]),
            8750
        )
        for port in [18750, 18800, 18849] {
            XCTAssertEqual(
                try SessionAPIListenPort.resolved(
                    environment: ["CONDUIT_SESSION_API_PORT": String(port)]
                ),
                port
            )
        }
    }

    func testQualificationPortOverrideFailsClosedForInvalidValues() {
        for raw in ["", "8750", "18749", "18850", "0", "+18750", " 18750", "18750 ", "١٨٧٥٠"] {
            XCTAssertThrowsError(
                try SessionAPIListenPort.resolved(
                    environment: ["CONDUIT_SESSION_API_PORT": raw]
                ),
                "invalid override: \(raw)"
            ) { error in
                XCTAssertEqual(
                    error as? SessionAPIListenPortError,
                    .invalidOverride
                )
            }
        }
    }

    func testHealthReadinessStatesUseFailClosedHTTPStatus() {
        for state in ConduitSessionAPIReadiness.allCases where state != .ready {
            XCTAssertFalse(state.isReady)
            XCTAssertEqual(state.httpStatusCode, 503)
        }
        XCTAssertTrue(ConduitSessionAPIReadiness.ready.isReady)
        XCTAssertEqual(ConduitSessionAPIReadiness.ready.httpStatusCode, 200)
    }

    func testBootstrapStatesAllowReadsButBlockWrites() {
        let read = ConduitSessionCommand.listProjects
        let processTree = ConduitSessionCommand.processTree(
            taskSessionID: "task-fixture"
        )
        let observeWorker = ConduitSessionCommand.observeWorker(
            provider: "opencode",
            providerSessionID: "ses_fixture"
        )
        let fleetSnapshot = ConduitSessionCommand.fleetSnapshot(
            taskCursor: nil,
            providerCursor: nil,
            limit: 40
        )
        let write = ConduitSessionCommand.createTask(
            agent: "Shell",
            projectSlug: "synthetic",
            objective: "",
            idempotencyKey: nil
        )

        for state in ConduitSessionAPIReadiness.allCases where state != .ready {
            XCTAssertTrue(
                ConduitSessionAPI.allowsCommand(read, readiness: state)
            )
            XCTAssertFalse(ConduitSessionAPI.isWrite(observeWorker))
            XCTAssertTrue(
                ConduitSessionAPI.allowsCommand(observeWorker, readiness: state)
            )
            XCTAssertFalse(ConduitSessionAPI.isWrite(processTree))
            XCTAssertTrue(
                ConduitSessionAPI.allowsCommand(processTree, readiness: state)
            )
            XCTAssertFalse(ConduitSessionAPI.isWrite(fleetSnapshot))
            XCTAssertTrue(
                ConduitSessionAPI.allowsCommand(fleetSnapshot, readiness: state)
            )
            XCTAssertFalse(
                ConduitSessionAPI.allowsCommand(write, readiness: state)
            )
        }

        XCTAssertTrue(
            ConduitSessionAPI.allowsCommand(read, readiness: .ready)
        )
        XCTAssertTrue(
            ConduitSessionAPI.allowsCommand(write, readiness: .ready)
        )
    }
}
