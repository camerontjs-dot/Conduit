import Foundation
import XCTest
@testable import ConduitCore

final class AgentContextSnapshotStoreTests: XCTestCase {
    func testPreviewDoesNotWriteUntilRecordIsCalled() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("context-snapshot-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentContextSnapshotStore(directory: root)
        let bundle = sampleBundle(commit: "abc")

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertNil(try store.latest(matching: bundle))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))

        _ = try store.record(bundle)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        XCTAssertEqual(try store.loadAll().count, 1)
    }

    func testLatestAndDiffRemainScopedToRepositoryAndScope() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("context-snapshot-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentContextSnapshotStore(directory: root)

        let previous = sampleBundle(commit: "abc")
        _ = try store.record(previous, at: Date(timeIntervalSince1970: 100))

        let added = AgentContextItem(
            id: "receipt",
            title: "Qualification receipt",
            kind: .testReceipt,
            authority: .testReceipt,
            sourceReference: "receipt.md",
            revisionIdentity: "sha256:1",
            freshness: .current
        )
        let current = AgentContextBundle(
            taskTitle: previous.taskTitle,
            scopePath: previous.scopePath,
            repository: previous.repository,
            branch: previous.branch,
            commitSHA: "def",
            items: previous.items + [added]
        )

        let latest = try store.latest(matching: current)
        XCTAssertEqual(latest?.bundle.commitSHA, "abc")

        let diff = try store.diffFromLatest(to: current)
        XCTAssertEqual(diff?.added.map(\.id), ["receipt"])
        XCTAssertEqual(diff?.removed, [])

        let other = AgentContextBundle(
            taskTitle: "Other",
            scopePath: "30_projects/other",
            repository: "/tmp/other",
            items: []
        )
        XCTAssertNil(try store.latest(matching: other))
    }

    private func sampleBundle(commit: String) -> AgentContextBundle {
        AgentContextBundle(
            taskTitle: "Context IDE",
            scopePath: "30_projects/conduit",
            repository: "/tmp/conduit",
            branch: "feat/context",
            commitSHA: commit,
            items: [
                AgentContextItem(
                    id: "file",
                    title: "README",
                    kind: .file,
                    authority: .filesystemSource,
                    sourceReference: "README.md",
                    revisionIdentity: commit,
                    isPinned: true,
                    freshness: .current
                )
            ]
        )
    }
}
