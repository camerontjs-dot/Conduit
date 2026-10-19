import XCTest
@testable import ConduitCore

final class SessionAPIStructuredDeliveryTests: XCTestCase {
    func testStructuredSendFailureDoesNotMasqueradeAsAccepted() throws {
        let task = UUID().uuidString, event = UUID().uuidString
        let failed = ConduitSessionAPI.structuredPromptResult(
            taskSessionID: task, eventID: event, delivered: false,
            backend: "stream-json", origin: .chatgpt
        )
        XCTAssertEqual(failed["taskSessionID"] as? String, task)
        XCTAssertEqual(failed["eventID"] as? String, event)
        XCTAssertEqual(failed["delivered"] as? Bool, false)
        XCTAssertEqual(failed["delivery"] as? String, "failed")
        XCTAssertNotNil(failed["error"] as? String)
        let succeeded = ConduitSessionAPI.structuredPromptResult(
            taskSessionID: task, eventID: event, delivered: true,
            backend: "stream-json", origin: .chatgpt
        )
        XCTAssertEqual(succeeded["delivered"] as? Bool, true)
        XCTAssertEqual(succeeded["delivery"] as? String, "delivered")
        XCTAssertNil(succeeded["error"])
    }
}
