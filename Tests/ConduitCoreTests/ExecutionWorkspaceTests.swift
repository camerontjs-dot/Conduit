import Foundation
import XCTest
@testable import ConduitCore

final class ExecutionWorkspaceTests: XCTestCase {
    func testReadOnlyWorkspaceDiscoveryDoesNotAllocateWorktree() throws {
        let repo = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repo) }

        let controller = GitExecutionWorkspaceController()
        let before = try controller.discoverWorktrees(repositoryRoot: repo)
        let workspace = try controller.makeSharedReadOnlyWorkspace(repositoryRoot: repo)
        let after = try controller.discoverWorktrees(repositoryRoot: repo)

        XCTAssertEqual(workspace.mode, .sharedReadOnly)
        XCTAssertEqual(workspace.authority, .readOnly)
        XCTAssertEqual(workspace.path, repo.standardizedFileURL.path)
        XCTAssertEqual(before, after)
        XCTAssertEqual(after.count, 1)
    }

    func testExactBaseAllocationPreservesHumanCheckoutAndDoesNotRetargetMovedBase() throws {
        let repo = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let managed = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-workspace-managed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: managed) }

        let controller = GitExecutionWorkspaceController()
        let branch = try currentBranch(repo)
        let plan = try controller.prepareAllocation(
            repositoryRoot: repo,
            workspaceRoot: managed,
            branchName: "conduit/test-exact-base",
            baseRevision: branch
        )
        let preparedHead = plan.baseSHA

        try "second\n".write(
            to: repo.appendingPathComponent("second.txt"),
            atomically: true,
            encoding: .utf8
        )
        try git(repo, ["add", "second.txt"])
        try git(repo, ["commit", "-m", "advance human checkout"])
        let humanHeadBefore = try head(repo)
        XCTAssertNotEqual(humanHeadBefore, preparedHead)

        let receipt = try controller.allocate(plan)
        let humanHeadAfter = try head(repo)

        XCTAssertEqual(humanHeadAfter, humanHeadBefore)
        XCTAssertEqual(receipt.worktree.headSHA, preparedHead)
        XCTAssertEqual(receipt.workspace.expectedHeadSHA, preparedHead)
        XCTAssertEqual(receipt.workspace.branchRef, "refs/heads/conduit/test-exact-base")
        XCTAssertEqual(receipt.warnings.count, 1)
        if case .baseRevisionMoved(let revision, let old, let current) = receipt.warnings[0] {
            XCTAssertEqual(revision, branch)
            XCTAssertEqual(old, preparedHead)
            XCTAssertEqual(current, humanHeadBefore)
        } else {
            XCTFail("Expected base movement warning")
        }
    }

    func testTwoWritableWorkspacesUseDistinctWorktreesAndLeaseAuthority() throws {
        let repo = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let managed = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-workspaces-\(UUID().uuidString)", isDirectory: true)
        let leases = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-workspace-leases-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: managed)
            try? FileManager.default.removeItem(at: leases)
        }

        let controller = GitExecutionWorkspaceController()
        let base = try currentBranch(repo)
        let first = try controller.allocate(
            controller.prepareAllocation(
                repositoryRoot: repo,
                workspaceRoot: managed,
                branchName: "conduit/test-worker-a",
                baseRevision: base
            )
        ).workspace
        let second = try controller.allocate(
            controller.prepareAllocation(
                repositoryRoot: repo,
                workspaceRoot: managed,
                branchName: "conduit/test-worker-b",
                baseRevision: base
            )
        ).workspace

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.path, second.path)

        let store = WorkspaceLeaseStore(directory: leases)
        let firstLease = try store.acquire(workspaceID: first.id, ownerID: "worker-a")
        XCTAssertEqual(
            try store.acquire(workspaceID: first.id, ownerID: "worker-a"),
            firstLease,
            "same writer acquisition should be idempotent"
        )
        XCTAssertThrowsError(
            try store.acquire(workspaceID: first.id, ownerID: "worker-b")
        ) { error in
            guard case WorkspaceLeaseStoreError.writerCollision(let id, let owner) = error else {
                return XCTFail("Unexpected error \(error)")
            }
            XCTAssertEqual(id, first.id)
            XCTAssertEqual(owner, "worker-a")
        }
        XCTAssertNoThrow(
            try store.acquire(workspaceID: second.id, ownerID: "worker-b")
        )
    }

    func testDirtyWorkspaceRequiresPreservationAndLeaseReleaseDoesNotDeleteWorktree() throws {
        let fixture = try makeAllocatedWorkspace(branch: "conduit/test-dirty")
        defer { fixture.cleanup() }

        let store = WorkspaceLeaseStore(directory: fixture.leaseDirectory)
        let lease = try store.acquire(
            workspaceID: fixture.workspace.id,
            ownerID: "worker-a"
        )
        let bound = fixture.workspace.binding(lease)
        let path = try XCTUnwrap(bound.path)
        try "keep me\n".write(
            to: URL(fileURLWithPath: path).appendingPathComponent("untracked.txt"),
            atomically: true,
            encoding: .utf8
        )

        let dirty = fixture.controller.reconcile(bound, leaseStore: store)
        XCTAssertEqual(dirty.disposition, .preservationRequired)
        XCTAssertTrue(dirty.issues.contains {
            if case .dirtyWorkspace = $0 { return true }
            return false
        })

        _ = try store.release(
            workspaceID: bound.id,
            ownerID: "worker-a",
            expectedLeaseID: lease.id
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertNil(try store.activeLease(workspaceID: bound.id))
    }

    func testBranchAndHeadDriftAreReportedBeforeReuse() throws {
        let fixture = try makeAllocatedWorkspace(branch: "conduit/test-drift")
        defer { fixture.cleanup() }
        let path = URL(fileURLWithPath: try XCTUnwrap(fixture.workspace.path))

        try git(path, ["switch", "-c", "conduit/unexpected-branch"])
        let branchDrift = fixture.controller.reconcile(fixture.workspace)
        XCTAssertEqual(branchDrift.disposition, .drifted)
        XCTAssertTrue(branchDrift.issues.contains {
            if case .branchDrift = $0 { return true }
            return false
        })

        try "changed\n".write(
            to: path.appendingPathComponent("changed.txt"),
            atomically: true,
            encoding: .utf8
        )
        try git(path, ["add", "changed.txt"])
        try git(path, ["commit", "-m", "advance workspace"])
        let headDrift = fixture.controller.reconcile(fixture.workspace)
        XCTAssertEqual(headDrift.disposition, .drifted)
        XCTAssertTrue(headDrift.issues.contains {
            if case .headDrift = $0 { return true }
            return false
        })
    }

    func testMismatchedResumedWorkerCWDIsReported() throws {
        let fixture = try makeAllocatedWorkspace(branch: "conduit/test-cwd")
        defer { fixture.cleanup() }

        let result = fixture.controller.reconcile(
            fixture.workspace,
            observedWorkerCWD: fixture.repository.path
        )
        XCTAssertEqual(result.disposition, .drifted)
        XCTAssertTrue(result.issues.contains {
            if case .cwdMismatch(let expected, let actual) = $0 {
                return expected == fixture.workspace.path
                    && actual == fixture.repository.standardizedFileURL.path
            }
            return false
        })
    }

    func testDeletedOrDeregisteredWorktreeDoesNotFallBackToHumanCheckout() throws {
        let fixture = try makeAllocatedWorkspace(branch: "conduit/test-missing")
        defer { fixture.cleanup() }
        let path = try XCTUnwrap(fixture.workspace.path)

        try git(fixture.repository, ["worktree", "remove", "--force", path])

        let result = fixture.controller.reconcile(fixture.workspace)
        XCTAssertEqual(result.disposition, .missing)
        XCTAssertNil(result.worktree)
        XCTAssertTrue(result.issues.contains {
            if case .worktreeMissing(let missing) = $0 { return missing == path }
            return false
        })
        XCTAssertNotEqual(fixture.workspace.path, fixture.repository.path)
    }

    func testExpectedLeaseDisappearanceFailsClosed() throws {
        let fixture = try makeAllocatedWorkspace(branch: "conduit/test-lease-missing")
        defer { fixture.cleanup() }

        let store = WorkspaceLeaseStore(directory: fixture.leaseDirectory)
        let lease = try store.acquire(
            workspaceID: fixture.workspace.id,
            ownerID: "worker-a"
        )
        let bound = fixture.workspace.binding(lease)
        _ = try store.release(
            workspaceID: bound.id,
            ownerID: "worker-a",
            expectedLeaseID: lease.id
        )

        let result = fixture.controller.reconcile(bound, leaseStore: store)
        XCTAssertEqual(result.disposition, .unknown)
        XCTAssertTrue(result.issues.contains {
            if case .writerLeaseMissing(let expected) = $0 {
                return expected == lease.id
            }
            return false
        })
    }

    func testWorktreePorcelainParserPreservesBranchAndDetachedState() {
        let text = """
        worktree /tmp/repo
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        worktree /tmp/repo-wt
        HEAD 2222222222222222222222222222222222222222
        detached
        locked reason

        """
        let rows = GitWorktreeRecord.parsePorcelain(text)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].branchName, "main")
        XCTAssertFalse(rows[0].isDetached)
        XCTAssertNil(rows[1].branchName)
        XCTAssertTrue(rows[1].isDetached)
        XCTAssertTrue(rows[1].isLocked)
    }

    private struct Fixture {
        let repository: URL
        let managedDirectory: URL
        let leaseDirectory: URL
        let controller: GitExecutionWorkspaceController
        let workspace: ExecutionWorkspace

        func cleanup() {
            if let path = workspace.path,
               FileManager.default.fileExists(atPath: path) {
                try? ExecutionWorkspaceTests.git(
                    repository,
                    ["worktree", "remove", "--force", path]
                )
            }
            try? FileManager.default.removeItem(at: repository)
            try? FileManager.default.removeItem(at: managedDirectory)
            try? FileManager.default.removeItem(at: leaseDirectory)
        }
    }

    private func makeAllocatedWorkspace(branch: String) throws -> Fixture {
        let repo = try makeRepository()
        let managed = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-workspaces-\(UUID().uuidString)", isDirectory: true)
        let leaseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-workspace-leases-\(UUID().uuidString)", isDirectory: true)
        let controller = GitExecutionWorkspaceController()
        let plan = try controller.prepareAllocation(
            repositoryRoot: repo,
            workspaceRoot: managed,
            branchName: branch,
            baseRevision: try currentBranch(repo)
        )
        let workspace = try controller.allocate(plan).workspace
        return Fixture(
            repository: repo,
            managedDirectory: managed,
            leaseDirectory: leaseDirectory,
            controller: controller,
            workspace: workspace
        )
    }

    private func makeRepository() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-execution-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(root, ["init"])
        try git(root, ["config", "user.name", "Conduit Test"])
        try git(root, ["config", "user.email", "conduit@example.invalid"])
        try "baseline\n".write(
            to: root.appendingPathComponent("baseline.txt"),
            atomically: true,
            encoding: .utf8
        )
        try git(root, ["add", "baseline.txt"])
        try git(root, ["commit", "-m", "baseline"])
        return root
    }

    private func currentBranch(_ repo: URL) throws -> String {
        try git(repo, ["symbolic-ref", "--quiet", "--short", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func head(_ repo: URL) throws -> String {
        try git(repo, ["rev-parse", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private func git(_ directory: URL, _ arguments: [String]) throws -> String {
        try Self.git(directory, arguments)
    }

    @discardableResult
    private static func git(_ directory: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory.path] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "LC_ALL": "C",
            "LANG": "C",
            "GIT_TERMINAL_PROMPT": "0",
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
            throw NSError(
                domain: "ExecutionWorkspaceTests",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "git \(arguments.joined(separator: " ")) failed: "
                        + String(decoding: error, as: UTF8.self)
                ]
            )
        }
        return String(decoding: output, as: UTF8.self)
    }
}
