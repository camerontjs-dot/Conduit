import XCTest
@testable import ConduitCore

final class ConduitWorkspaceTests: XCTestCase {
    func testAllCasesKeepSessionsExploreOrchestrateOrder() {
        XCTAssertEqual(
            ConduitWorkspace.allCases.map(\.rawValue),
            ["sessions", "explore", "orchestrate"]
        )
    }

    func testExplorePresentation() {
        XCTAssertEqual(ConduitWorkspace.explore.displayName, "Explore")
        XCTAssertEqual(ConduitWorkspace.explore.symbolName, "folder")
    }

    func testExistingWorkspacePresentationRemainsUnchanged() {
        XCTAssertEqual(ConduitWorkspace.sessions.displayName, "Sessions")
        XCTAssertEqual(ConduitWorkspace.sessions.symbolName, "rectangle.3.group")
        XCTAssertEqual(ConduitWorkspace.orchestrate.displayName, "Orchestrate")
        XCTAssertEqual(
            ConduitWorkspace.orchestrate.symbolName,
            "point.3.connected.trianglepath.dotted"
        )
    }
}
