import XCTest
@testable import ConduitCore

final class ConduitSessionCallerTests: XCTestCase {
    func testSharedBearerPrincipalDoesNotChangeWithClientInfo() {
        let first = ConduitSessionCaller.authenticatedBySharedBearer(
            clientInfo: "chatgpt-developer-mode/1.0",
            observedAt: Date(timeIntervalSince1970: 1)
        )
        let second = ConduitSessionCaller.authenticatedBySharedBearer(
            clientInfo: "another-client/99",
            observedAt: Date(timeIntervalSince1970: 2)
        )

        XCTAssertEqual(first.identity, ConduitSessionCaller.sharedBearerPrincipal)
        XCTAssertEqual(second.identity, ConduitSessionCaller.sharedBearerPrincipal)
        XCTAssertNotEqual(first.clientInfo, second.clientInfo)
    }

    func testClientInfoRemainsAuditMetadata() {
        let caller = ConduitSessionCaller.authenticatedBySharedBearer(
            clientInfo: "chatgpt-developer-mode/1.0",
            observedAt: nil
        )

        XCTAssertEqual(caller.clientInfo, "chatgpt-developer-mode/1.0")
        XCTAssertNotEqual(caller.identity, caller.clientInfo)
    }

    func testMissingInitializeIdentityStillFailsClosed() {
        XCTAssertEqual(
            ConduitSessionCaller.authenticatedBySharedBearer(
                clientInfo: nil,
                observedAt: nil
            ),
            .unidentified
        )
        XCTAssertEqual(
            ConduitSessionCaller.authenticatedBySharedBearer(
                clientInfo: "   ",
                observedAt: nil
            ),
            .unidentified
        )
    }
}
