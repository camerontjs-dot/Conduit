import Foundation
import XCTest
@testable import ConduitCore

final class MainframeExplorerTests: XCTestCase {
    private let fm = FileManager.default

    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try body(root)
    }

    private func mkdir(_ root: URL, _ path: String) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ root: URL, _ path: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testRootShowsUsefulHiddenSurfacesButSkipsGitMetadata() throws {
        try withRoot { root in
            for path in [".agents", ".context", ".github", ".git", "30_projects", "40_operations"] {
                _ = try mkdir(root, path)
            }
            _ = try write(root, ".DS_Store", "metadata")
            _ = try write(root, "README.md", "# MainFrame")
            let nodes = try MainframeExplorerScanner().rootChildren(root: root)
            let names = nodes.map(\.name)
            XCTAssertTrue(names.contains(".agents"))
            XCTAssertTrue(names.contains(".context"))
            XCTAssertTrue(names.contains(".github"))
            XCTAssertFalse(names.contains(".git"))
            XCTAssertFalse(names.contains(".DS_Store"))
            XCTAssertEqual(nodes.first?.kind, .directory)
        }
    }

    func testLifecycleZoneAndRecordScopeArePathDerivedOnly() throws {
        try withRoot { root in
            let project = try mkdir(root, "30_projects/cal")
            let operation = try mkdir(root, "40_operations/research-radar")
            let projectNodes = try MainframeExplorerScanner().children(root: root, directory: project.deletingLastPathComponent())
            let opNodes = try MainframeExplorerScanner().children(root: root, directory: operation.deletingLastPathComponent())
            XCTAssertEqual(projectNodes.first?.zone, .projects)
            XCTAssertEqual(projectNodes.first?.recordScope, .init(recordType: .project, slug: "cal"))
            XCTAssertEqual(opNodes.first?.zone, .operations)
            XCTAssertEqual(opNodes.first?.recordScope, .init(recordType: .operation, slug: "research-radar"))
        }
    }

    func testOutsideDirectoryIsRejected() throws {
        try withRoot { root in
            let outside = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: outside, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: outside) }
            XCTAssertThrowsError(try MainframeExplorerScanner().children(root: root, directory: outside)) { error in
                guard case MainframeExplorerError.unsafePath = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
        }
    }

    func testSymbolicLinkIsVisibleButNeverTraversed() throws {
        try withRoot { root in
            let outside = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: outside, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: outside) }
            let link = root.appendingPathComponent("outside-link")
            try fm.createSymbolicLink(at: link, withDestinationURL: outside)
            let nodes = try MainframeExplorerScanner().rootChildren(root: root)
            XCTAssertEqual(nodes.first(where: { $0.name == "outside-link" })?.kind, .symbolicLink)
            XCTAssertThrowsError(try MainframeExplorerScanner().children(root: root, directory: link))
        }
    }

    func testSymlinkInspectionClassifiesInsideOutsideAndMissingWithoutTraversal() throws {
        try withRoot { root in
            let insideTarget = try write(root, "10_knowledge/inside.md", "inside")
            let insideLink = root.appendingPathComponent("inside-link")
            try fm.createSymbolicLink(
                atPath: insideLink.path,
                withDestinationPath: "10_knowledge/inside.md"
            )

            let outsideTarget = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try "outside".write(to: outsideTarget, atomically: true, encoding: .utf8)
            defer { try? fm.removeItem(at: outsideTarget) }
            let outsideLink = root.appendingPathComponent("outside-link")
            try fm.createSymbolicLink(at: outsideLink, withDestinationURL: outsideTarget)

            let missingLink = root.appendingPathComponent("missing-link")
            try fm.createSymbolicLink(
                atPath: missingLink.path,
                withDestinationPath: "does-not-exist.md"
            )

            let scanner = MainframeExplorerScanner()
            let inside = try scanner.inspectSymbolicLink(root: root, link: insideLink)
            XCTAssertEqual(inside.location, .insideRoot)
            XCTAssertEqual(inside.rawTarget, "10_knowledge/inside.md")
            XCTAssertEqual(inside.relativeTargetPath, "10_knowledge/inside.md")
            XCTAssertEqual(
                inside.resolvedTargetPath,
                insideTarget.resolvingSymlinksInPath().standardizedFileURL.path
            )

            let outside = try scanner.inspectSymbolicLink(root: root, link: outsideLink)
            XCTAssertEqual(outside.location, .outsideRoot)
            XCTAssertNil(outside.relativeTargetPath)
            XCTAssertEqual(
                outside.resolvedTargetPath,
                outsideTarget.resolvingSymlinksInPath().standardizedFileURL.path
            )

            let missing = try scanner.inspectSymbolicLink(root: root, link: missingLink)
            XCTAssertEqual(missing.location, .missing)
            XCTAssertNil(missing.relativeTargetPath)
        }
    }

    func testIndexNeverFollowsSymbolicLinkAndReportsBound() throws {
        try withRoot { root in
            _ = try write(root, "30_projects/cal/README.md", "# CAL")
            _ = try write(root, "30_projects/cal/notes/a.md", "A")
            _ = try write(root, "30_projects/cal/notes/b.md", "B")
            let outside = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: outside, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: outside) }
            try "SECRET".write(to: outside.appendingPathComponent("secret.md"), atomically: true, encoding: .utf8)
            try fm.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: outside)

            let complete = try MainframeExplorerScanner().buildIndex(root: root, maxEntries: 100)
            XCTAssertFalse(complete.entries.contains(where: { $0.relativePath.contains("secret.md") }))
            let bounded = try MainframeExplorerScanner().buildIndex(root: root, maxEntries: 2)
            XCTAssertEqual(bounded.entries.count, 2)
            XCTAssertTrue(bounded.truncated)
        }
    }

    func testDirectoryRescanReflectsCreateRenameAndDeleteAfterInitialListing() throws {
        try withRoot { root in
            let directory = try mkdir(root, "30_projects/demo")
            let scanner = MainframeExplorerScanner()

            XCTAssertTrue(try scanner.children(root: root, directory: directory).isEmpty)

            _ = try write(root, "30_projects/demo/new.md", "new")
            XCTAssertEqual(
                try scanner.children(root: root, directory: directory).map(\.name),
                ["new.md"]
            )

            try fm.moveItem(
                at: root.appendingPathComponent("30_projects/demo/new.md"),
                to: root.appendingPathComponent("30_projects/demo/renamed.md")
            )
            XCTAssertEqual(
                try scanner.children(root: root, directory: directory).map(\.name),
                ["renamed.md"]
            )

            try fm.removeItem(at: root.appendingPathComponent("30_projects/demo/renamed.md"))
            XCTAssertTrue(try scanner.children(root: root, directory: directory).isEmpty)
        }
    }

    func testFreshnessContainingDirectoryUsesSmallestParent() {
        XCTAssertEqual(
            MainframeExplorerFilesystemFreshness.containingDirectoryPath(
                for: "30_projects/demo/artifacts/report.pdf"
            ),
            "30_projects/demo/artifacts"
        )
        XCTAssertEqual(
            MainframeExplorerFilesystemFreshness.containingDirectoryPath(for: "README.md"),
            ""
        )
    }

    func testFreshnessInvalidatesRemovedAndDirectoryToFileSubtreesOnly() {
        func node(_ path: String, _ kind: MainframeExplorerNodeKind) -> MainframeExplorerNode {
            MainframeExplorerNode(
                name: URL(fileURLWithPath: path).lastPathComponent,
                relativePath: path,
                url: URL(fileURLWithPath: "/mf").appendingPathComponent(path),
                kind: kind,
                zone: .projects,
                recordScope: nil
            )
        }

        let previous = [
            node("30_projects/demo/kept", .directory),
            node("30_projects/demo/replaced", .directory),
            node("30_projects/demo/deleted.md", .file),
        ]
        let current = [
            node("30_projects/demo/kept", .directory),
            node("30_projects/demo/replaced", .file),
            node("30_projects/demo/created.md", .file),
        ]

        XCTAssertEqual(
            MainframeExplorerFilesystemFreshness.staleSubtreeRoots(
                previous: previous,
                current: current
            ),
            [
                "30_projects/demo/deleted.md",
                "30_projects/demo/replaced",
            ]
        )
    }

    func testQuickOpenRanksExactNameBeforePathOnlyHit() {
        let exact = MainframeExplorerNode(name: "README.md", relativePath: "30_projects/cal/README.md", url: URL(fileURLWithPath: "/tmp/a"), kind: .file, zone: .projects, recordScope: nil)
        let prefix = MainframeExplorerNode(name: "README-notes.md", relativePath: "10_knowledge/README-notes.md", url: URL(fileURLWithPath: "/tmp/b"), kind: .file, zone: .knowledge, recordScope: nil)
        let pathOnly = MainframeExplorerNode(name: "design.md", relativePath: "30_projects/readme-work/design.md", url: URL(fileURLWithPath: "/tmp/c"), kind: .file, zone: .projects, recordScope: nil)
        let result = MainframeQuickOpen.matches([pathOnly, prefix, exact], query: "readme")
        XCTAssertEqual(result.map(\.name), ["README.md", "README-notes.md", "design.md"])
    }

    func testQuickOpenSupportsOrderedSubsequence() {
        let node = MainframeExplorerNode(name: "authorization-envelope.md", relativePath: "10_knowledge/authorization-envelope.md", url: URL(fileURLWithPath: "/tmp/a"), kind: .file, zone: .knowledge, recordScope: nil)
        XCTAssertEqual(MainframeQuickOpen.matches([node], query: "atzenv").count, 1)
    }

    func testReaderReadsUTF8AndRejectsOversizedFile() throws {
        try withRoot { root in
            let file = try write(root, "10_knowledge/note.md", "hello")
            XCTAssertEqual(try MainframeExplorerScanner().readUTF8Text(root: root, file: file), "hello")
            XCTAssertThrowsError(try MainframeExplorerScanner().readUTF8Text(root: root, file: file, maxBytes: 4)) { error in
                guard case MainframeExplorerError.fileTooLarge = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
        }
    }

    func testReaderRejectsSymlinkAndOutsidePath() throws {
        try withRoot { root in
            let outside = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try "outside".write(to: outside, atomically: true, encoding: .utf8)
            defer { try? fm.removeItem(at: outside) }
            let link = root.appendingPathComponent("linked.md")
            try fm.createSymbolicLink(at: link, withDestinationURL: outside)
            XCTAssertThrowsError(try MainframeExplorerScanner().readUTF8Text(root: root, file: link))
            XCTAssertThrowsError(try MainframeExplorerScanner().readUTF8Text(root: root, file: outside))
        }
    }

    func testNavigationHistoryBackForwardAndBranching() {
        var history = MainframeNavigationHistory()
        history.visit("a.md")
        history.visit("b.md")
        history.visit("c.md")
        XCTAssertEqual(history.goBack(), "b.md")
        XCTAssertEqual(history.goBack(), "a.md")
        XCTAssertEqual(history.goForward(), "b.md")
        history.visit("d.md")
        XCTAssertEqual(history.entries, ["a.md", "b.md", "d.md"])
        XCTAssertFalse(history.canGoForward)
    }
}
