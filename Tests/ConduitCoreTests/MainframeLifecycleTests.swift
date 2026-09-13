import Foundation
import XCTest
@testable import ConduitCore

final class MainframeLifecycleScannerTests: XCTestCase {
    private let fm = FileManager.default

    private func makeRoot() throws -> URL {
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testDiscoversLegacyProjectAndExplicitOperation() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        try write("# Legacy Project\n", to: root.appendingPathComponent("30_projects/legacy/README.md"))
        try write("""
        ---
        title: "Research Radar"
        record_type: operation
        lifecycle_state: active
        next_action: "Run the next scan"
        ---
        # Research Radar
        """, to: root.appendingPathComponent("40_operations/research-radar/README.md"))

        let scan = try MainframeLifecycleScanner().scan(root: root)
        XCTAssertEqual(scan.records.count, 2)
        XCTAssertTrue(scan.rootIssues.isEmpty)
        XCTAssertEqual(scan.bySlug["legacy"]?.first?.recordType, .project)
        XCTAssertEqual(scan.bySlug["legacy"]?.first?.metadata.title, "Legacy Project")
        XCTAssertEqual(scan.bySlug["research-radar"]?.first?.recordType, .operation)
        XCTAssertEqual(scan.bySlug["research-radar"]?.first?.lifecycleState, "active")
        XCTAssertTrue(scan.bySlug["research-radar"]?.first?.isValid == true)
    }

    func testMissingOperationsRootIsCompatible() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        try write("# Project\n", to: root.appendingPathComponent("30_projects/project/README.md"))

        let scan = try MainframeLifecycleScanner().scan(root: root)
        XCTAssertEqual(scan.records.map(\.slug), ["project"])
        XCTAssertTrue(scan.rootIssues.isEmpty)
    }

    func testOperationMustOptInWithRecordType() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        try write("# Operation Without Identity\n", to: root.appendingPathComponent("40_operations/radar/README.md"))

        let scan = try MainframeLifecycleScanner().scan(root: root)
        let record = try XCTUnwrap(scan.bySlug["radar"]?.first)
        XCTAssertNil(record.recordType)
        XCTAssertTrue(record.issues.contains("record_type is missing or invalid"))
        XCTAssertTrue(record.issues.contains("operation-root README must declare record_type: operation"))
        XCTAssertThrowsError(try MainframeLifecycleScanner().resolveRecord(root: root, slug: "radar"))
    }

    func testDuplicateSlugAcrossRootsFailsClosed() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        try write("# Shared\n", to: root.appendingPathComponent("30_projects/shared/README.md"))
        try write("""
        ---
        record_type: operation
        ---
        # Shared Operation
        """, to: root.appendingPathComponent("40_operations/shared/README.md"))

        let scan = try MainframeLifecycleScanner().scan(root: root)
        XCTAssertEqual(scan.bySlug["shared"]?.count, 2)
        XCTAssertTrue(scan.issues.contains { $0.contains("duplicate lifecycle identity shared") })
        XCTAssertThrowsError(try MainframeLifecycleScanner().resolveRecord(root: root, slug: "shared")) { error in
            guard case MainframeLifecycleIdentityError.duplicateIdentity = error else {
                return XCTFail("Expected duplicate identity, got \(error)")
            }
        }
    }

    func testMissingReadmeIsInvalidAuthority() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("30_projects/no-readme"), withIntermediateDirectories: true)

        let record = try XCTUnwrap(try MainframeLifecycleScanner().scan(root: root).bySlug["no-readme"]?.first)
        XCTAssertFalse(record.isValid)
        XCTAssertTrue(record.issues.contains("README.md missing or not a regular file"))
    }

    func testConflictingLifecycleStateFailsValidation() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        try write("""
        ---
        project_state: active
        lifecycle_state: parked
        ---
        # Conflict
        """, to: root.appendingPathComponent("30_projects/conflict/README.md"))

        let record = try XCTUnwrap(try MainframeLifecycleScanner().scan(root: root).bySlug["conflict"]?.first)
        XCTAssertFalse(record.isValid)
        XCTAssertTrue(record.issues.contains("project_state and lifecycle_state conflict"))
        XCTAssertNil(record.lifecycleState)
    }

    func testProjectCoordinationStateOwnsStateButMismatchRemainsVisible() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        try write("""
        ---
        project_state: active
        ---
        # Project
        """, to: root.appendingPathComponent("30_projects/project/README.md"))
        try write("""
        ---
        lifecycle_state: parked
        ---
        """, to: root.appendingPathComponent("30_projects/project/PROJECT.md"))

        let record = try XCTUnwrap(try MainframeLifecycleScanner().scan(root: root).bySlug["project"]?.first)
        XCTAssertEqual(record.lifecycleState, "parked")
        XCTAssertEqual(record.stateSource, "PROJECT.md")
        XCTAssertTrue(record.issues.contains("README lifecycle state differs from PROJECT.md owner"))
    }

    func testMalformedFrontmatterIsRejectedInsteadOfSilentlyParsed() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        try write("""
        ---
          nested: nope
        ---
        # Project
        """, to: root.appendingPathComponent("30_projects/project/README.md"))

        let record = try XCTUnwrap(try MainframeLifecycleScanner().scan(root: root).bySlug["project"]?.first)
        XCTAssertFalse(record.isValid)
        XCTAssertTrue(record.issues.contains("indented/nested frontmatter declarations are not supported"))
    }

    func testExpectedRecordTypeCanBeEnforced() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        try write("# Project\n", to: root.appendingPathComponent("30_projects/project/README.md"))

        XCTAssertThrowsError(
            try MainframeLifecycleScanner().resolveRecord(
                root: root,
                slug: "project",
                expectedRecordType: .operation
            )
        ) { error in
            guard case MainframeLifecycleIdentityError.unexpectedRecordType = error else {
                return XCTFail("Expected type mismatch, got \(error)")
            }
        }
    }

    func testBlankProjectRecordTypeDoesNotFallBackToLegacyProjectDefault() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        try write("""
        ---
        record_type:
        ---
        # Project
        """, to: root.appendingPathComponent("30_projects/project/README.md"))

        let record = try XCTUnwrap(try MainframeLifecycleScanner().scan(root: root).bySlug["project"]?.first)
        XCTAssertNil(record.recordType)
        XCTAssertFalse(record.isValid)
    }

    func testOperationRecordTypeOptInIsExactLowercaseDeclaration() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        try write("""
        ---
        record_type: Operation
        ---
        # Operation
        """, to: root.appendingPathComponent("40_operations/radar/README.md"))

        let record = try XCTUnwrap(try MainframeLifecycleScanner().scan(root: root).bySlug["radar"]?.first)
        XCTAssertEqual(record.recordType, .operation)
        XCTAssertTrue(record.issues.contains("operation-root README must declare record_type: operation"))
        XCTAssertFalse(record.isValid)
    }
}
