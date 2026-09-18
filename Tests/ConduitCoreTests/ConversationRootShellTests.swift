import XCTest
@testable import ConduitCore

final class ConversationRootShellTests: XCTestCase {
    func testConversationOwnsEntireWindowAtRest() {
        let geometry = ConversationRootShellPolicy.resolve(
            windowWidth: 1400,
            taskDrawerPresented: false,
            taskDrawerPinned: false,
            inspectorPresented: false,
            inspectorPinned: false
        )

        XCTAssertEqual(geometry.taskDrawer, .hidden)
        XCTAssertEqual(geometry.inspector, .hidden)
        XCTAssertEqual(geometry.contentLeadingInset, 0)
        XCTAssertEqual(geometry.contentTrailingInset, 0)
    }

    func testUnpinnedPanelsOverlayWithoutShrinkingConversation() {
        let geometry = ConversationRootShellPolicy.resolve(
            windowWidth: 1400,
            taskDrawerPresented: true,
            taskDrawerPinned: false,
            inspectorPresented: true,
            inspectorPinned: false
        )

        XCTAssertEqual(geometry.taskDrawer, .overlay)
        XCTAssertEqual(geometry.inspector, .overlay)
        XCTAssertEqual(geometry.contentLeadingInset, 0)
        XCTAssertEqual(geometry.contentTrailingInset, 0)
    }

    func testExplicitPinsShrinkConversationWhenRoomRemains() {
        let geometry = ConversationRootShellPolicy.resolve(
            windowWidth: 1500,
            taskDrawerPresented: true,
            taskDrawerPinned: true,
            inspectorPresented: true,
            inspectorPinned: true
        )

        XCTAssertEqual(geometry.taskDrawer, .pinned)
        XCTAssertEqual(geometry.inspector, .pinned)
        XCTAssertGreaterThan(geometry.contentLeadingInset, 0)
        XCTAssertGreaterThan(geometry.contentTrailingInset, 0)
        XCTAssertGreaterThanOrEqual(
            1500 - geometry.contentLeadingInset - geometry.contentTrailingInset,
            620
        )
    }

    func testPinsFallBackToOverlayRatherThanCrushChat() {
        let geometry = ConversationRootShellPolicy.resolve(
            windowWidth: 900,
            taskDrawerPresented: true,
            taskDrawerPinned: true,
            inspectorPresented: true,
            inspectorPinned: true
        )

        XCTAssertEqual(geometry.taskDrawer, .overlay)
        XCTAssertEqual(geometry.inspector, .overlay)
        XCTAssertEqual(geometry.contentLeadingInset, 0)
        XCTAssertEqual(geometry.contentTrailingInset, 0)
    }

    func testSinglePinCanRemainPinnedAtOrdinaryDesktopWidth() {
        let geometry = ConversationRootShellPolicy.resolve(
            windowWidth: 1100,
            taskDrawerPresented: true,
            taskDrawerPinned: true,
            inspectorPresented: false,
            inspectorPinned: false
        )

        XCTAssertEqual(geometry.taskDrawer, .pinned)
        XCTAssertEqual(geometry.inspector, .hidden)
        XCTAssertGreaterThan(geometry.contentLeadingInset, 0)
        XCTAssertEqual(geometry.contentTrailingInset, 0)
    }
}
