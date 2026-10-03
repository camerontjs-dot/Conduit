import XCTest
@testable import ConduitCore

final class WorkGroupTests: XCTestCase {
    func testCreateRenameArchiveAndPrimaryRepositoryPersist() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = WorkGroupStore(directory: directory)
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let primary = WorkGroupRepositoryReference(
            projectID: .known("conduit"),
            repositoryRoot: .known("/tmp/Conduit"),
            repositoryFullName: .known("camerontjs-dot/Conduit"),
            worktreePath: .unknown
        )
        let created = try store.create(
            name: " Runtime ",
            primary: primary,
            createdAt: createdAt
        )

        XCTAssertEqual(created.name, "Runtime")
        XCTAssertEqual(created.primary.repositoryFullName.value, "camerontjs-dot/Conduit")
        XCTAssertEqual(try store.list(), [created])

        let renamed = try store.rename(
            id: created.id,
            name: "Runtime Authority",
            updatedAt: createdAt.addingTimeInterval(10)
        )
        XCTAssertEqual(renamed.name, "Runtime Authority")

        let archived = try store.setArchived(
            id: created.id,
            archived: true,
            updatedAt: createdAt.addingTimeInterval(20)
        )
        XCTAssertTrue(archived.archived)
        XCTAssertEqual(try store.list(), [])
        XCTAssertEqual(try store.list(includeArchived: true).first?.id, created.id)

        let reopened = WorkGroupStore(directory: directory)
        XCTAssertEqual(
            try reopened.group(id: created.id)?.name,
            "Runtime Authority"
        )
        XCTAssertTrue(try XCTUnwrap(reopened.group(id: created.id)).archived)
    }

    func testCanonicalMemberReferencesAreIdempotentAndRolesCanChange() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = WorkGroupStore(directory: directory)
        let group = try store.create(name: "MindGraph")
        let task = WorkGroupMemberReference.conduitTask("task-123")

        let first = try store.addMember(
            groupID: group.id,
            reference: task,
            role: .implementer
        )
        XCTAssertEqual(first.members.count, 1)
        XCTAssertEqual(first.members[0].id, "task:task-123")

        let roleUpdated = try store.addMember(
            groupID: group.id,
            reference: task,
            role: .reviewer
        )
        XCTAssertEqual(roleUpdated.members.count, 1)
        XCTAssertEqual(roleUpdated.members[0].role, .reviewer)

        let thread = WorkGroupMemberReference.providerThread(
            providerID: "opencode",
            threadID: "ses-456"
        )
        let withThread = try store.addMember(
            groupID: group.id,
            reference: thread,
            role: .researcher
        )
        XCTAssertEqual(withThread.members.map(\.id).sorted(), [
            "provider:opencode:ses-456",
            "task:task-123",
        ])

        let removed = try store.removeMember(
            groupID: group.id,
            reference: task
        )
        XCTAssertEqual(removed.members.map(\.id), ["provider:opencode:ses-456"])
    }

    func testExternalRegularChatIsReferenceOnlyCoordinationState() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = WorkGroupStore(directory: directory)
        let group = try store.create(name: "Supervisor Desk")
        let external = WorkGroupMemberReference.externalRegularChat("chat-thread-abc")
        let updated = try store.addMember(
            groupID: group.id,
            reference: external,
            role: .supervisor
        )

        XCTAssertEqual(updated.members.first?.reference.kind, .externalRegularChat)
        XCTAssertEqual(updated.members.first?.id, "regular-chat:chat-thread-abc")
        XCTAssertNil(updated.members.first?.reference.providerID)
        XCTAssertNil(updated.members.first?.reference.threadID)
    }

    func testThreadRailFiltersToMembersAndPreservesAuthoritativeProjectionFacts() {
        let task = WorkGroupMemberReference.conduitTask("task-a")
        let provider = WorkGroupMemberReference.providerThread(
            providerID: "opencode",
            threadID: "ses-b"
        )
        let unrelated = WorkGroupMemberReference.conduitTask("task-outside")
        let group = WorkGroup(
            name: "Routing",
            members: [
                WorkGroupMember(reference: task, role: .implementer),
                WorkGroupMember(reference: provider, role: .reviewer),
            ]
        )
        let newest = Date(timeIntervalSince1970: 1_800_000_100)
        let older = Date(timeIntervalSince1970: 1_800_000_000)
        let observations = [
            WorkGroupThreadObservation(
                reference: task,
                displayTitle: "Implementation",
                providerLabel: .known("Conduit task"),
                lastActivityAt: .known(older),
                unseenCount: .known(2)
            ),
            WorkGroupThreadObservation(
                reference: provider,
                displayTitle: "Review",
                providerLabel: .known("OpenCode"),
                lastActivityAt: .known(newest),
                unseenCount: .known(1)
            ),
            WorkGroupThreadObservation(
                reference: unrelated,
                displayTitle: "Should not appear",
                providerLabel: .known("Shell"),
                lastActivityAt: .known(newest.addingTimeInterval(100)),
                unseenCount: .known(99)
            ),
        ]

        let rows = WorkGroupThreadRailProjection.items(
            group: group,
            observations: observations
        )

        XCTAssertEqual(rows.map(\.id), [
            "provider:opencode:ses-b",
            "task:task-a",
        ])
        XCTAssertEqual(rows[0].observation?.providerLabel.value, "OpenCode")
        XCTAssertEqual(rows[0].observation?.unseenCount.value, 1)
        XCTAssertEqual(rows[1].observation?.unseenCount.value, 2)
    }

    func testMissingThreadObservationStaysMissingInsteadOfInventingRuntimeState() {
        let task = WorkGroupMemberReference.conduitTask("task-a")
        let group = WorkGroup(
            name: "Evidence Room",
            members: [WorkGroupMember(reference: task, role: .researcher)]
        )

        let rows = WorkGroupThreadRailProjection.items(
            group: group,
            observations: []
        )

        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].observation)
        XCTAssertEqual(rows[0].displayTitle, "task:task-a")
    }

    func testComposerDestinationBreadcrumbNamesGroupAndExactTarget() {
        let target = WorkGroupMemberReference.providerThread(
            providerID: "claude",
            threadID: "thread-1"
        )
        let destination = WorkGroupComposerDestination(
            groupID: WorkGroupID(rawValue: "group-1"),
            groupName: "MindGraph",
            target: target,
            targetTitle: "Local qualification"
        )

        XCTAssertEqual(
            destination.breadcrumb,
            "Work Group: MindGraph [group-1] → Local qualification [provider:claude:thread-1] · role: UNKNOWN · provider: claude"
        )
        XCTAssertEqual(destination.target.canonicalID, "provider:claude:thread-1")
    }

    func testNonMemberTargetProducesDeterministicWarning() {
        let member = WorkGroupMemberReference.conduitTask("member")
        let outside = WorkGroupMemberReference.conduitTask("outside")
        let group = WorkGroup(
            name: "CAL",
            members: [WorkGroupMember(reference: member, role: .implementer)]
        )

        XCTAssertEqual(
            WorkGroupTargetValidator.warnings(
                group: group,
                target: outside,
                observation: nil
            ),
            [.nonMemberTarget]
        )
    }

    func testRepositoryAndWorktreeMismatchWarnOnlyWhenExactIdentityExists() {
        let target = WorkGroupMemberReference.conduitTask("task-a")
        let group = WorkGroup(
            name: "Conduit",
            primary: WorkGroupRepositoryReference(
                projectID: .known("conduit"),
                repositoryRoot: .known("/tmp/Conduit"),
                repositoryFullName: .known("camerontjs-dot/Conduit"),
                worktreePath: .known("/tmp/Conduit-worktree")
            ),
            members: [WorkGroupMember(reference: target, role: .implementer)]
        )
        let mismatch = WorkGroupThreadObservation(
            reference: target,
            displayTitle: "Implementation",
            repositoryRoot: .known("/tmp/Other"),
            worktreePath: .known("/tmp/Other-worktree")
        )

        XCTAssertEqual(
            WorkGroupTargetValidator.warnings(
                group: group,
                target: target,
                observation: mismatch
            ),
            [
                .repositoryMismatch(
                    expected: "/tmp/Conduit",
                    actual: "/tmp/Other"
                ),
                .worktreeMismatch(
                    expected: "/tmp/Conduit-worktree",
                    actual: "/tmp/Other-worktree"
                ),
            ]
        )

        let unknown = WorkGroupThreadObservation(
            reference: target,
            displayTitle: "Implementation"
        )
        XCTAssertEqual(
            WorkGroupTargetValidator.warnings(
                group: group,
                target: target,
                observation: unknown
            ),
            []
        )
    }

    func testMalformedMemberReferenceFailsClosed() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = WorkGroupStore(directory: directory)
        let group = try store.create(name: "Conduit")
        let malformed = WorkGroupMemberReference(kind: .providerThread)

        XCTAssertThrowsError(
            try store.addMember(
                groupID: group.id,
                reference: malformed,
                role: .implementer
            )
        ) { error in
            XCTAssertEqual(error as? WorkGroupStoreError, .invalidReference)
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-work-group-\(UUID().uuidString)", isDirectory: true)
    }
}
