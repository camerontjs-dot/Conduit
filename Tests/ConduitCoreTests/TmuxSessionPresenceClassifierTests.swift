import XCTest
@testable import ConduitCore

final class TmuxSessionPresenceClassifierTests: XCTestCase {
    func testZeroStatusIsPresent() {
        XCTAssertEqual(
            TmuxSessionPresenceClassifier.classify(
                exitStatus: 0,
                output: ""
            ),
            .present
        )
    }

    func testMissingNamedSessionIsAbsent() {
        XCTAssertEqual(
            TmuxSessionPresenceClassifier.classify(
                exitStatus: 1,
                output: "can't find session: conduit-test"
            ),
            .absent
        )
    }

    func testLegacyNoServerDiagnosticIsAbsent() {
        XCTAssertEqual(
            TmuxSessionPresenceClassifier.classify(
                exitStatus: 1,
                output: "no server running on /private/tmp/tmux-501/default"
            ),
            .absent
        )
    }

    func testTmux36MissingServerSocketIsAbsent() {
        XCTAssertEqual(
            TmuxSessionPresenceClassifier.classify(
                exitStatus: 1,
                output: "error connecting to /private/tmp/tmux-501/default (No such file or directory)"
            ),
            .absent
        )
    }

    func testGenericMissingFileDoesNotProveSessionAbsence() {
        XCTAssertEqual(
            TmuxSessionPresenceClassifier.classify(
                exitStatus: 1,
                output: "No such file or directory"
            ),
            .unknown
        )
    }

    func testConnectionRefusedRemainsUnknown() {
        XCTAssertEqual(
            TmuxSessionPresenceClassifier.classify(
                exitStatus: 1,
                output: "error connecting to /private/tmp/tmux-501/default (Connection refused)"
            ),
            .unknown
        )
    }

    func testPermissionFailureRemainsUnknown() {
        XCTAssertEqual(
            TmuxSessionPresenceClassifier.classify(
                exitStatus: 1,
                output: "error connecting to /private/tmp/tmux-501/default (Permission denied)"
            ),
            .unknown
        )
    }

    func testTimeoutRemainsUnknown() {
        XCTAssertEqual(
            TmuxSessionPresenceClassifier.classify(
                exitStatus: -1,
                output: "[timed out after 5s]"
            ),
            .unknown
        )
    }
}
