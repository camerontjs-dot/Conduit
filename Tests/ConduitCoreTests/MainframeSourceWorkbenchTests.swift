import XCTest
@testable import ConduitCore

final class MainframeSourceWorkbenchTests: XCTestCase {
    func testSourceClassificationAndEditAllowlist() {
        XCTAssertEqual(MainframeSourcePolicy.classify(fileName: "Foo.swift"), .swift)
        XCTAssertEqual(MainframeSourcePolicy.classify(fileName: "script.py"), .python)
        XCTAssertEqual(MainframeSourcePolicy.classify(fileName: "config.yaml"), .yaml)
        XCTAssertEqual(MainframeSourcePolicy.classify(fileName: "Dockerfile"), .plainText)
        XCTAssertEqual(MainframeSourcePolicy.classify(fileName: "image.png"), .unsupported)

        XCTAssertEqual(
            MainframeSourcePolicy.editPermission(
                relativePath: "30_projects/demo/Sources/Foo.swift",
                fileName: "Foo.swift"
            ),
            .editable(kind: .swift)
        )

        XCTAssertEqual(
            MainframeSourcePolicy.editPermission(
                relativePath: "30_projects/demo/.build/debug/generated.swift",
                fileName: "generated.swift"
            ),
            .readOnly(
                kind: .swift,
                reason: "Files under .build stay read-only in the Context IDE."
            )
        )
    }

    func testUnknownFileTypeStaysReadOnly() {
        XCTAssertEqual(
            MainframeSourcePolicy.editPermission(
                relativePath: "30_projects/demo/artifact.bin",
                fileName: "artifact.bin"
            ),
            .readOnly(
                kind: .unsupported,
                reason: "This file type is not on the explicit UTF-8 edit allowlist."
            )
        )
    }

    func testSwiftOutlineIsExplicitlyIncompleteNavigationAid() {
        let source = """
        import Foundation

        struct Widget {
            func render() {}
        }

        extension Widget {
            func debug() {}
        }
        """

        let outline = MainframeSourceOutlineExtractor.extract(source: source, kind: .swift)

        XCTAssertTrue(outline.mayBeIncomplete)
        XCTAssertEqual(outline.entries.map(\.line), [3, 4, 7, 8])
        XCTAssertEqual(outline.entries.map(\.kind), [.type, .function, .extensionDecl, .function])
    }

    func testNonCodeOutlineIsEmptyAndNotClaimedIncomplete() {
        let outline = MainframeSourceOutlineExtractor.extract(
            source: "{\"ok\": true}",
            kind: .json
        )
        XCTAssertEqual(outline.entries, [])
        XCTAssertFalse(outline.mayBeIncomplete)
    }

    func testDiagnosticParserFindsPathLineAndColumn() {
        XCTAssertEqual(
            MainframeDiagnosticParser.parseLocation(
                from: "Sources/Foo.swift:127:18: error: something failed"
            ),
            MainframeDiagnosticLocation(path: "Sources/Foo.swift", line: 127, column: 18)
        )
        XCTAssertEqual(
            MainframeDiagnosticParser.parseLocation(from: "Tests/test_example.py:42"),
            MainframeDiagnosticLocation(path: "Tests/test_example.py", line: 42)
        )
    }

    func testDiagnosticParserRejectsNonLocations() {
        XCTAssertNil(MainframeDiagnosticParser.parseLocation(from: "build failed"))
        XCTAssertNil(MainframeDiagnosticParser.parseLocation(from: "Foo.swift:zero"))
        XCTAssertNil(MainframeDiagnosticParser.parseLocation(from: ":12"))
    }
}
