import XCTest
@testable import ConduitCore

final class SessionAPIReadinessTests: XCTestCase {
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
