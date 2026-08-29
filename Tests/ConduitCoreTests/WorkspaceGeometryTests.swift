import XCTest
@testable import ConduitCore

final class WorkspaceGeometryTests: XCTestCase {
    func testSmallAndNormalWidthsUseInspectorOverlayWithoutChangingDensity() {
        for density in Density.allCases {
            let small = WorkspaceGeometryPolicy.resolve(
                windowWidth: 1_080,
                density: density,
                isInspectorPresented: true
            )
            XCTAssertEqual(small.inspectorLayout, .overlay)
            XCTAssertEqual(
                [small.railMinimumWidth, small.railIdealWidth, small.railMaximumWidth],
                [232, 240, 244]
            )
            XCTAssertEqual(small.inspectorWidth, 300)

            let normal = WorkspaceGeometryPolicy.resolve(
                windowWidth: 1_280,
                density: density,
                isInspectorPresented: true
            )
            XCTAssertEqual(normal.inspectorLayout, .overlay)
            XCTAssertEqual(
                [normal.railMinimumWidth, normal.railIdealWidth, normal.railMaximumWidth],
                [244, 252, 260]
            )
            XCTAssertEqual(normal.inspectorWidth, 312)
        }
    }

    func testLargeFocusedOverlaysWhileBalancedAndOperatorPin() {
        XCTAssertEqual(
            WorkspaceGeometryPolicy.resolve(
                windowWidth: 1_440,
                density: .focused,
                isInspectorPresented: true
            ).inspectorLayout,
            .overlay
        )
        XCTAssertEqual(
            WorkspaceGeometryPolicy.resolve(
                windowWidth: 1_440,
                density: .balanced,
                isInspectorPresented: true
            ).inspectorLayout,
            .pinned
        )
        let operatorGeometry = WorkspaceGeometryPolicy.resolve(
            windowWidth: 1_600,
            density: .operator,
            isInspectorPresented: true
        )
        XCTAssertEqual(operatorGeometry.inspectorLayout, .pinned)
        XCTAssertEqual(operatorGeometry.inspectorWidth, 336)
        XCTAssertEqual(
            [
                operatorGeometry.railMinimumWidth,
                operatorGeometry.railIdealWidth,
                operatorGeometry.railMaximumWidth
            ],
            [260, 270, 280]
        )
    }

    func testHiddenInspectorConsumesNoPanelLayoutInEveryDensity() {
        for density in Density.allCases {
            XCTAssertEqual(
                WorkspaceGeometryPolicy.resolve(
                    windowWidth: 1_600,
                    density: density,
                    isInspectorPresented: false
                ).inspectorLayout,
                .hidden
            )
        }
    }

    func testPinnedLargeGeometryProtectsTheSpecifiedCentreMinimum() {
        for density in [Density.balanced, .operator] {
            let geometry = WorkspaceGeometryPolicy.resolve(
                windowWidth: 1_440,
                density: density,
                isInspectorPresented: true
            )
            let conservativeCentre = 1_440
                - geometry.railMaximumWidth
                - geometry.inspectorWidth
            XCTAssertGreaterThanOrEqual(conservativeCentre, 520)
        }
    }

    func testResponsiveBoundariesAreExact() {
        let at1199 = WorkspaceGeometryPolicy.resolve(
            windowWidth: 1_199,
            density: .operator,
            isInspectorPresented: true
        )
        XCTAssertEqual(at1199.inspectorLayout, .overlay)
        XCTAssertEqual(at1199.inspectorWidth, 300)
        XCTAssertEqual(at1199.railMaximumWidth, 244)

        let at1200 = WorkspaceGeometryPolicy.resolve(
            windowWidth: 1_200,
            density: .operator,
            isInspectorPresented: true
        )
        XCTAssertEqual(at1200.inspectorLayout, .overlay)
        XCTAssertEqual(at1200.inspectorWidth, 312)
        XCTAssertEqual(at1200.railMinimumWidth, 244)

        XCTAssertEqual(
            WorkspaceGeometryPolicy.resolve(
                windowWidth: 1_439,
                density: .balanced,
                isInspectorPresented: true
            ).inspectorLayout,
            .overlay
        )
        XCTAssertEqual(
            WorkspaceGeometryPolicy.resolve(
                windowWidth: 1_440,
                density: .balanced,
                isInspectorPresented: true
            ).inspectorLayout,
            .pinned
        )
    }

    func testSmallOverlayLeavesAtLeastTheSpecifiedUnobscuredCentre() {
        let geometry = WorkspaceGeometryPolicy.resolve(
            windowWidth: 1_080,
            density: .operator,
            isInspectorPresented: true
        )
        let unobscuredWorkspaceWidth = 1_080
            - geometry.railMaximumWidth
            - geometry.inspectorWidth
            - 1 // Inspector divider.
        XCTAssertEqual(geometry.inspectorLayout, .overlay)
        XCTAssertGreaterThanOrEqual(unobscuredWorkspaceWidth, 520)
    }

    func testPreferredInspectorWidthAppliesWithinConservativeBounds() {
        let preferred = WorkspaceGeometryPolicy.resolve(
            windowWidth: 1_280,
            density: .balanced,
            isInspectorPresented: true,
            preferredInspectorWidth: 380
        )
        XCTAssertEqual(preferred.inspectorMinimumWidth, 300)
        XCTAssertEqual(preferred.inspectorWidth, 380)
        XCTAssertEqual(preferred.inspectorMaximumWidth, 420)

        XCTAssertEqual(
            WorkspaceGeometryPolicy.resolve(
                windowWidth: 1_280,
                density: .balanced,
                isInspectorPresented: true,
                preferredInspectorWidth: 120
            ).inspectorWidth,
            300
        )
        XCTAssertEqual(
            WorkspaceGeometryPolicy.resolve(
                windowWidth: 1_280,
                density: .balanced,
                isInspectorPresented: true,
                preferredInspectorWidth: 900
            ).inspectorWidth,
            420
        )
    }

    func testInvalidPreferredInspectorWidthsRestoreResponsiveDefault() {
        for invalid in [0.0, -40, .nan, .infinity, -.infinity] {
            XCTAssertEqual(
                WorkspaceGeometryPolicy.resolve(
                    windowWidth: 1_280,
                    density: .focused,
                    isInspectorPresented: true,
                    preferredInspectorWidth: invalid
                ).inspectorWidth,
                312
            )
        }
    }

    func testWidePreferenceTemporarilyClampsThenRestoresAtLargeWidth() {
        let narrow = WorkspaceGeometryPolicy.resolve(
            windowWidth: 1_080,
            density: .operator,
            isInspectorPresented: true,
            preferredInspectorWidth: 420
        )
        XCTAssertEqual(narrow.inspectorMaximumWidth, 315)
        XCTAssertEqual(narrow.inspectorWidth, 315)
        XCTAssertEqual(
            1_080 - narrow.railMaximumWidth - narrow.inspectorWidth - 1,
            WorkspaceGeometryPolicy.workspaceCentreMinimum
        )

        let wide = WorkspaceGeometryPolicy.resolve(
            windowWidth: 1_600,
            density: .operator,
            isInspectorPresented: true,
            preferredInspectorWidth: 420
        )
        XCTAssertEqual(wide.inspectorWidth, 420)
        XCTAssertEqual(wide.inspectorLayout, .pinned)
    }

    func testPreferredWidthNeverChangesResponsiveLayoutMode() {
        for preferred in [300.0, 420.0] {
            XCTAssertEqual(
                WorkspaceGeometryPolicy.resolve(
                    windowWidth: 1_439,
                    density: .balanced,
                    isInspectorPresented: true,
                    preferredInspectorWidth: preferred
                ).inspectorLayout,
                .overlay
            )
            XCTAssertEqual(
                WorkspaceGeometryPolicy.resolve(
                    windowWidth: 1_440,
                    density: .balanced,
                    isInspectorPresented: true,
                    preferredInspectorWidth: preferred
                ).inspectorLayout,
                .pinned
            )
        }
    }

    func testClampedNoOpDoesNotReplaceAStoredWiderPreference() {
        let narrow = WorkspaceGeometryPolicy.resolve(
            windowWidth: 1_080,
            density: .operator,
            isInspectorPresented: true,
            preferredInspectorWidth: 420
        )
        XCTAssertEqual(narrow.inspectorWidth, 315)
        XCTAssertFalse(
            WorkspaceGeometryPolicy.shouldCommitInspectorWidth(
                currentEffectiveWidth: narrow.inspectorWidth,
                proposedWidth: narrow.inspectorMaximumWidth
            )
        )
        XCTAssertTrue(
            WorkspaceGeometryPolicy.shouldCommitInspectorWidth(
                currentEffectiveWidth: narrow.inspectorWidth,
                proposedWidth: 300
            )
        )
    }
}
