import Foundation
import XCTest
@testable import ConduitCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private final class SearchProgressCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [MainframeExplorerSearchIndex] = []
    private var cancelled = false
    func note(_ value: MainframeExplorerSearchIndex, cancel: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        values.append(value)
        cancelled = cancel
    }
    var snapshots: [MainframeExplorerSearchIndex] { lock.lock(); defer { lock.unlock() }; return values }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

final class MainframeExplorerSearchIndexTests: XCTestCase {
    private let fm = FileManager.default
    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try body(root)
    }
    private func write(_ root: URL, _ path: String) throws {
        let file = root.appendingPathComponent(path)
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture\n".utf8).write(to: file)
    }

    func testSearchExclusionLeavesCanonicalTreeAndLegacyContentIndexVisible() throws {
        try withRoot { root in
            try write(root, "node_modules/package/source.js")
            try write(root, "notes/ordinary.md")
            let index = try MainframeExplorerSearchIndexer().build(root: root)
            XCTAssertTrue(index.entries.contains { $0.relativePath == "node_modules" })
            XCTAssertFalse(index.entries.contains { $0.relativePath.hasPrefix("node_modules/") })
            XCTAssertEqual(index.receipt.excludedDirectoryCount, 1)
            XCTAssertFalse(index.receipt.isComplete)
            XCTAssertEqual(try MainframeExplorerScanner().children(root: root, directory: root.appendingPathComponent("node_modules")).map(\.name), ["package"])
            XCTAssertTrue(try MainframeExplorerScanner().buildIndex(root: root).entries.contains { $0.relativePath == "node_modules/package/source.js" })
            let included = try MainframeExplorerSearchIndexer().build(root: root, policy: .init(excludedDirectoryNames: []))
            XCTAssertTrue(included.entries.contains { $0.relativePath == "node_modules/package/source.js" })
            XCTAssertTrue(included.receipt.isComplete)
        }
    }

    func testSymbolicLinksRemainLeavesIncludingDanglingAndRootLinksAreRejected() throws {
        try withRoot { root in
            try write(root, "inside/actual.md")
            let outside = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: outside, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: outside) }
            try Data("outside\n".utf8).write(to: outside.appendingPathComponent("secret.md"))
            try fm.createSymbolicLink(at: root.appendingPathComponent("outside-link"), withDestinationURL: outside)
            try fm.createSymbolicLink(at: root.appendingPathComponent("inside-link"), withDestinationURL: root.appendingPathComponent("inside"))
            try fm.createSymbolicLink(atPath: root.appendingPathComponent("dangling").path, withDestinationPath: "missing")
            let index = try MainframeExplorerSearchIndexer().build(root: root)
            XCTAssertEqual(index.entries.filter { $0.kind == .symbolicLink }.count, 3)
            XCTAssertFalse(index.entries.contains { $0.relativePath.contains("secret.md") || $0.relativePath.hasPrefix("inside-link/") })
            XCTAssertThrowsError(try MainframeExplorerSearchIndexer().build(root: root.appendingPathComponent("inside-link")))
        }
    }

    func testUnreadableSubtreeRetainsHealthySiblingWithAnExplicitPartialReceipt() throws {
        guard geteuid() != 0 else { throw XCTSkip("A privileged process cannot provide an actual directory permission-denial control") }
        try withRoot { root in
            try write(root, "bad/hidden.md")
            try write(root, "good/visible.md")
            let bad = root.appendingPathComponent("bad")
            try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: bad.path)
            defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bad.path) }
            let index = try MainframeExplorerSearchIndexer().build(root: root)
            XCTAssertTrue(index.entries.contains { $0.relativePath == "good/visible.md" })
            XCTAssertFalse(index.entries.contains { $0.relativePath == "bad/hidden.md" })
            XCTAssertEqual(index.receipt.issueCount, 1)
            XCTAssertEqual(index.receipt.issueSample.first?.relativePath, "bad")
            XCTAssertFalse(index.receipt.isComplete)
        }
    }

    func testWideDirectoryCannotExceedEntryOrExaminationBounds() throws {
        try withRoot { root in
            for number in 0..<80 { try write(root, "file-\(number).txt") }
            let entries = try MainframeExplorerSearchIndexer().build(root: root, policy: .init(entryLimit: 7))
            XCTAssertEqual(entries.entries.count, 7)
            XCTAssertEqual(entries.receipt.stop, .entryLimit)
            XCTAssertFalse(entries.receipt.isComplete)
            let work = try MainframeExplorerSearchIndexer().build(root: root, policy: .init(examinedEntryLimit: 8))
            XCTAssertEqual(work.receipt.examinedEntries, 8)
            XCTAssertEqual(work.receipt.stop, .workLimit)
            XCTAssertFalse(work.receipt.isComplete)
            XCTAssertEqual(MainframeExplorerSearchPolicy(entryLimit: 100_000).entryLimit, 20_000)
        }
    }

    func testDepthOmissionIsExplicitAndNeverPresentedAsComplete() throws {
        try withRoot { root in
            try write(root, "a/b/c/d/e/hidden.txt")
            let index = try MainframeExplorerSearchIndexer().build(root: root, policy: .init(depthLimit: 4))
            XCTAssertTrue(index.entries.contains { $0.relativePath == "a/b/c/d" })
            XCTAssertFalse(index.entries.contains { $0.relativePath == "a/b/c/d/e/hidden.txt" })
            XCTAssertEqual(index.receipt.issueCount, 1)
            XCTAssertFalse(index.receipt.isComplete)
        }
    }

    func testProgressAndCancellationPreserveBoundedObservedResultsWithoutCompleteness() throws {
        try withRoot { root in
            for number in 0..<1_050 { try write(root, "file-\(number).txt") }
            let capture = SearchProgressCapture()
            let index = try MainframeExplorerSearchIndexer().build(root: root, isCancelled: { capture.isCancelled }, onProgress: { capture.note($0, cancel: true) })
            XCTAssertEqual(capture.snapshots.count, 1)
            XCTAssertEqual(capture.snapshots.first?.entries.count, 1_000)
            XCTAssertEqual(capture.snapshots.first?.receipt.isInProgress, true)
            XCTAssertEqual(capture.snapshots.first?.receipt.isComplete, false)
            XCTAssertEqual(index.receipt.stop, .cancelled)
            XCTAssertEqual(index.entries.count, 1_000)
            XCTAssertFalse(index.receipt.isComplete)
        }
    }

    func testDiagnosticPathSamplesAreBoundedAndTotalOmissionsRemainVisible() throws {
        try withRoot { root in
            for number in 0..<45 { try write(root, "project-\(number)/node_modules/package.js") }
            let index = try MainframeExplorerSearchIndexer().build(root: root)
            XCTAssertEqual(index.receipt.excludedDirectoryCount, 45)
            XCTAssertEqual(index.receipt.excludedDirectorySample.count, 40)
            XCTAssertFalse(index.receipt.isComplete)
        }
    }

    func testFreshExplicitSnapshotFindsANewFileWithoutPersistentShadowState() throws {
        try withRoot { root in
            let indexer = MainframeExplorerSearchIndexer()
            XCTAssertTrue(try indexer.build(root: root).entries.isEmpty)
            try write(root, "created-after-snapshot.md")
            let refreshed = try indexer.build(root: root)
            XCTAssertEqual(refreshed.entries.map(\.relativePath), ["created-after-snapshot.md"])
            XCTAssertTrue(refreshed.receipt.isComplete)
        }
    }
}
