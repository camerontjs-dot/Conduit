import XCTest
@testable import ConduitCore

final class SessionAPICallerTests: XCTestCase {
    func testSharedBearerFactoryKeepsAuditMetadataSeparate() {
        let firstStamp = Date(timeIntervalSince1970: 100)
        let secondStamp = Date(timeIntervalSince1970: 200)
        let first = ConduitSessionCaller.authenticatedBySharedBearer(
            clientInfo: " fixture-a/1 ", observedAt: firstStamp
        )
        let second = ConduitSessionCaller.authenticatedBySharedBearer(
            clientInfo: "fixture-b/2", observedAt: secondStamp
        )
        XCTAssertEqual(first.identity, "session-api-shared-bearer-v1")
        XCTAssertEqual(second.identity, first.identity)
        XCTAssertEqual(first.clientInfo, "fixture-a/1")
        XCTAssertEqual(second.clientInfo, "fixture-b/2")
        XCTAssertEqual(first.observedAt, firstStamp)
        XCTAssertEqual(second.observedAt, secondStamp)
    }

    func testMissingOrBlankInitializeMetadataRemainsUnidentified() {
        for label: String? in [nil, "", " \n\t "] {
            XCTAssertEqual(
                ConduitSessionCaller.authenticatedBySharedBearer(
                    clientInfo: label, observedAt: Date(timeIntervalSince1970: 100)
                ),
                .unidentified
            )
        }
    }

    func testEveryCurrentTypedWriteRequiresCallerContextAndReadsRemainAvailable() {
        let writes: [ConduitSessionCommand] = [
            .adoptProviderSession(provider: "fixture", providerSessionID: "session", controllerID: "controller"),
            .createTask(agent: "Shell", projectSlug: "fixture", objective: "", idempotencyKey: nil),
            .reconcileTask(taskSessionID: "task"),
            .sendPrompt(taskSessionID: "task", text: "fixture", origin: .chatgpt),
            .lifecycleOperation(taskSessionID: "task", operation: .abortTurn),
            .interrupt(taskSessionID: "task"),
            .closeSession(taskSessionID: "task"),
        ]
        let reads: [ConduitSessionCommand] = [
            .listProjects, .listSessions(cursor: nil, limit: nil), .listAdapters,
            .listProviderSessions(provider: "fixture"),
            .fleetSnapshot(taskCursor: nil, providerCursor: nil, limit: nil),
            .observeWorker(provider: "fixture", providerSessionID: "session"),
            .sessionStatus(taskSessionID: "task"), .processTree(taskSessionID: "task"),
            .sessionEvents(taskSessionID: "task", cursor: nil, limit: nil),
            .queryMindGraph(question: "fixture", scope: "projects"),
            .lifecyclePreflight(taskSessionID: "task", operation: .abortTurn),
        ]
        XCTAssertEqual(writes.count, ConduitSessionToolCatalog.writeToolNames.count)
        XCTAssertEqual(reads.count, ConduitSessionToolCatalog.readToolNames.count)
        let initialized = ConduitSessionCaller.authenticatedBySharedBearer(
            clientInfo: "fixture/1", observedAt: Date(timeIntervalSince1970: 100)
        )
        for command in writes {
            XCTAssertTrue(ConduitSessionAPI.isWrite(command))
            XCTAssertFalse(ConduitSessionAPI.callerContextAllows(command, caller: .unidentified))
            XCTAssertFalse(ConduitSessionAPI.callerContextAllows(
                command, caller: ConduitSessionCaller(identity: " \n ", observedAt: nil)
            ))
            XCTAssertTrue(ConduitSessionAPI.callerContextAllows(command, caller: initialized))
        }
        for command in reads {
            XCTAssertFalse(ConduitSessionAPI.isWrite(command))
            XCTAssertTrue(ConduitSessionAPI.callerContextAllows(command, caller: .unidentified))
        }
    }
}
