import Foundation
import XCTest
@testable import ConduitCore

final class GitWorkspaceInspectorTests: XCTestCase {
    func testSnapshotReportsExactHeadBranchAndWorkingTreeState() throws {
        let repo = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repo) }

        let tracked = repo.appendingPathComponent("Sources/Widget.swift")
        try FileManager.default.createDirectory(
            at: tracked.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "let value = 1\n".write(to: tracked, atomically: true, encoding: .utf8)
        try git(repo, ["add", "Sources/Widget.swift"])
        try git(repo, ["commit", "-m", "baseline"])

        let expectedHead = try git(repo, ["rev-parse", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try "let value = 2\n".write(to: tracked, atomically: true, encoding: .utf8)
        try "scratch\n".write(
            to: repo.appendingPathComponent("notes.txt"),
            atomically: true,
            encoding: .utf8
        )

        let snapshot = try GitWorkspaceInspector().snapshot(startingAt: tracked)

        XCTAssertEqual(snapshot.repositoryRoot, repo.standardizedFileURL.path)
        XCTAssertEqual(snapshot.headSHA, expectedHead)
        XCTAssertFalse(snapshot.isDetached)
        XCTAssertNotNil(snapshot.branch)
        XCTAssertTrue(snapshot.status.contains { row in
            row.path == "Sources/Widget.swift" && row.hasWorkTreeChange
        })
        XCTAssertTrue(snapshot.status.contains { row in
            row.path == "notes.txt" && row.isUntracked
        })
        XCTAssertFalse(snapshot.statusWasTruncated)
    }

    func testDiffIsBoundedToNamedFileAndDoesNotMutateRepository() throws {
        let repo = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repo) }

        let first = repo.appendingPathComponent("first.swift")
        let second = repo.appendingPathComponent("second.swift")
        try "let first = 1\n".write(to: first, atomically: true, encoding: .utf8)
        try "let second = 1\n".write(to: second, atomically: true, encoding: .utf8)
        try git(repo, ["add", "."])
        try git(repo, ["commit", "-m", "baseline"])
        try "let first = 2\n".write(to: first, atomically: true, encoding: .utf8)
        try "let second = 2\n".write(to: second, atomically: true, encoding: .utf8)

        let before = try git(repo, ["status", "--porcelain=v1"])
        let diff = try GitWorkspaceInspector().diff(
            startingAt: repo,
            relativePath: "first.swift"
        )
        let after = try git(repo, ["status", "--porcelain=v1"])

        XCTAssertTrue(diff.text.contains("let first = 2"))
        XCTAssertFalse(diff.text.contains("let second = 2"))
        XCTAssertEqual(diff.path, "first.swift")
        XCTAssertEqual(diff.basis, .workingTree)
        XCTAssertEqual(before, after, "read-only Git inspection must not mutate status")
    }

    func testHeadBlobIdentityRequiresCleanTrackedPath() throws {
        let repo = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repo) }

        let file = repo.appendingPathComponent("File.swift")
        try "let value = 1\n".write(to: file, atomically: true, encoding: .utf8)
        try git(repo, ["add", "File.swift"])
        try git(repo, ["commit", "-m", "baseline"])

        let expectedBlob = try git(repo, ["rev-parse", "HEAD:File.swift"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let inspector = GitWorkspaceInspector()
        XCTAssertEqual(
            try inspector.headBlobIdentity(startingAt: file, relativePath: "File.swift"),
            expectedBlob
        )

        try "let value = 2\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertNil(
            try inspector.headBlobIdentity(startingAt: file, relativePath: "File.swift"),
            "a dirty working-tree file must not be labelled with the HEAD blob identity"
        )
    }

    func testWorkingTreeBlobIdentityTracksExactOnDiskBytesWithoutMutatingGit() throws {
        let repo = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repo) }

        let file = repo.appendingPathComponent("File.swift")
        try "let value = 1\n".write(to: file, atomically: true, encoding: .utf8)
        try git(repo, ["add", "File.swift"])
        try git(repo, ["commit", "-m", "baseline"])

        let headBlob = try git(repo, ["rev-parse", "HEAD:File.swift"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try "let value = 99\n".write(to: file, atomically: true, encoding: .utf8)
        let before = try git(repo, ["status", "--porcelain=v1"])
        let expectedWorkingBlob = try git(repo, ["hash-object", "--no-filters", "--", "File.swift"])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let actual = try GitWorkspaceInspector().workingTreeBlobIdentity(
            startingAt: file,
            relativePath: "File.swift"
        )
        let after = try git(repo, ["status", "--porcelain=v1"])

        XCTAssertEqual(actual, expectedWorkingBlob)
        XCTAssertNotEqual(actual, headBlob)
        XCTAssertEqual(before, after, "content identity inspection must not mutate Git state")
    }

    func testWorkingTreeBlobIdentityRejectsTraversal() throws {
        let repo = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repo) }

        XCTAssertThrowsError(
            try GitWorkspaceInspector().workingTreeBlobIdentity(
                startingAt: repo,
                relativePath: "../outside.txt"
            )
        )
    }

    func testBlameReturnsExactCommitAndAuthorForRequestedLine() throws {
        let repo = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repo) }

        let file = repo.appendingPathComponent("File.swift")
        try "let first = 1\nlet second = 2\n".write(to: file, atomically: true, encoding: .utf8)
        try git(repo, ["add", "File.swift"])
        try git(repo, ["commit", "-m", "baseline blame"])
        let expectedHead = try git(repo, ["rev-parse", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let blame = try GitWorkspaceInspector().blame(
            startingAt: file,
            relativePath: "File.swift",
            line: 2
        )

        XCTAssertEqual(blame?.path, "File.swift")
        XCTAssertEqual(blame?.line, 2)
        XCTAssertEqual(blame?.commitSHA, expectedHead)
        XCTAssertEqual(blame?.author, "Conduit Test")
        XCTAssertEqual(blame?.summary, "baseline blame")
    }

    func testStatusParserPreservesRenameOriginalPath() {
        let data = Data("R  new name.swift\0old name.swift\0?? loose.txt\0".utf8)
        let rows = GitWorkspaceInspector.parsePorcelainV1Z(data)

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].path, "new name.swift")
        XCTAssertEqual(rows[0].originalPath, "old name.swift")
        XCTAssertEqual(rows[1].path, "loose.txt")
        XCTAssertTrue(rows[1].isUntracked)
    }

    func testOutsideTraversalPathIsRejectedBeforeDiffCommand() throws {
        let repo = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repo) }

        XCTAssertThrowsError(
            try GitWorkspaceInspector().diff(
                startingAt: repo,
                relativePath: "../outside.txt"
            )
        )
    }

    private func makeRepository() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-git-inspector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(root, ["init"])
        try git(root, ["config", "user.name", "Conduit Test"])
        try git(root, ["config", "user.email", "conduit@example.invalid"])
        return root
    }

    @discardableResult
    private func git(_ directory: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory.path] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "LC_ALL": "C",
            "LANG": "C",
            "GIT_TERMINAL_PROMPT": "0"
        ]) { _, new in new }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            XCTFail(String(decoding: error, as: UTF8.self))
            throw NSError(domain: "GitWorkspaceInspectorTests", code: Int(process.terminationStatus))
        }
        return String(decoding: output, as: UTF8.self)
    }
}
