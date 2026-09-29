import XCTest
@testable import ConduitCore

final class ChatGPTTunnelControlTests: XCTestCase {
    private let ready = ChatGPTTunnelPrerequisites(
        sessionAPIListening: true,
        tunnelClientAvailable: true,
        profilePresent: true,
        tunnelIDPresent: true,
        controlPlaneKeyPresent: true,
        sessionTokenPresent: true
    )

    func testDisabledControlStopsOnlyOwnedProcess() {
        XCTAssertEqual(
            ChatGPTTunnelControlPolicy.action(
                desiredRunning: false,
                ownsRunningProcess: true,
                healthReachable: true,
                prerequisites: ready
            ),
            .stopOwned
        )
        XCTAssertEqual(
            ChatGPTTunnelControlPolicy.action(
                desiredRunning: false,
                ownsRunningProcess: false,
                healthReachable: true,
                prerequisites: ready
            ),
            .noChange
        )
    }

    func testExternalHealthyTunnelIsObservedNotReplaced() {
        XCTAssertEqual(
            ChatGPTTunnelControlPolicy.action(
                desiredRunning: true,
                ownsRunningProcess: false,
                healthReachable: true,
                prerequisites: ready
            ),
            .observeExternal
        )
    }

    func testReadyConfigurationStartsOwnedTunnel() {
        XCTAssertEqual(
            ChatGPTTunnelControlPolicy.action(
                desiredRunning: true,
                ownsRunningProcess: false,
                healthReachable: false,
                prerequisites: ready
            ),
            .startOwned
        )
    }

    func testMissingRequirementsFailClosedBeforeLaunch() {
        let missing = ChatGPTTunnelPrerequisites(
            sessionAPIListening: false,
            tunnelClientAvailable: false,
            profilePresent: false,
            tunnelIDPresent: true,
            controlPlaneKeyPresent: true,
            sessionTokenPresent: false
        )
        XCTAssertEqual(
            ChatGPTTunnelControlPolicy.action(
                desiredRunning: true,
                ownsRunningProcess: false,
                healthReachable: false,
                prerequisites: missing
            ),
            .blocked([
                "Session API is not listening",
                "tunnel-client is unavailable",
                "tunnel-client profile is missing",
                "Session API token is missing",
            ])
        )
    }

    func testOwnedRunningTunnelNeedsNoSecondLaunch() {
        XCTAssertEqual(
            ChatGPTTunnelControlPolicy.action(
                desiredRunning: true,
                ownsRunningProcess: true,
                healthReachable: true,
                prerequisites: ready
            ),
            .noChange
        )
    }
}
