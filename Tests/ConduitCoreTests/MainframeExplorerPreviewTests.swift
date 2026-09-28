import XCTest
@testable import ConduitCore

final class MainframeExplorerPreviewTests: XCTestCase {
    func testPreviewRouterClassifiesNativeAndTextFormats() {
        XCTAssertEqual(route("notes.md"), .text)
        XCTAssertEqual(route("data.json"), .text)
        XCTAssertEqual(route("README"), .text)
        XCTAssertEqual(route("figure.png"), .image)
        XCTAssertEqual(route("photo.JPEG"), .image)
        XCTAssertEqual(route("paper.pdf"), .pdf)
        XCTAssertEqual(route("archive.zip"), .unsupportedBinary)
    }

    func testDirectoriesAndSymlinksDoNotBecomePreviewRoutes() {
        let directory = MainframeExplorerNode(
            name: "artifacts",
            relativePath: "artifacts",
            url: URL(fileURLWithPath: "/tmp/artifacts"),
            kind: .directory,
            zone: .system,
            recordScope: nil
        )
        let link = MainframeExplorerNode(
            name: "linked.pdf",
            relativePath: "linked.pdf",
            url: URL(fileURLWithPath: "/tmp/linked.pdf"),
            kind: .symbolicLink,
            zone: .system,
            recordScope: nil
        )

        XCTAssertEqual(MainframeExplorerPreviewRouter.route(for: directory), .none)
        XCTAssertEqual(MainframeExplorerPreviewRouter.route(for: link), .none)
    }

    private func route(_ name: String) -> MainframeExplorerPreviewRoute {
        MainframeExplorerPreviewRouter.route(
            for: MainframeExplorerNode(
                name: name,
                relativePath: "artifacts/\(name)",
                url: URL(fileURLWithPath: "/tmp").appendingPathComponent(name),
                kind: .file,
                zone: .system,
                recordScope: nil
            )
        )
    }
}
