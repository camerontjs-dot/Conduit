import Darwin
import Foundation
import XCTest
@testable import ConduitCore

final class SessionAPITransportSecurityTests: XCTestCase {
    func testExactBearerAuthorizationRejectsExtendedAndDuplicateCredentials() {
        let token = "synthetic-token"

        XCTAssertTrue(
            SessionAPITransportSecurity.exactBearerAuthorization(
                headerLines: ["Authorization: Bearer synthetic-token"],
                token: token
            )
        )
        XCTAssertTrue(
            SessionAPITransportSecurity.exactBearerAuthorization(
                headerLines: ["authorization: bEaReR synthetic-token"],
                token: token
            )
        )
        XCTAssertFalse(
            SessionAPITransportSecurity.exactBearerAuthorization(
                headerLines: ["Authorization: Bearer synthetic-token-suffix"],
                token: token
            )
        )
        XCTAssertFalse(
            SessionAPITransportSecurity.exactBearerAuthorization(
                headerLines: ["Authorization: Bearer synthetic-token extra"],
                token: token
            )
        )
        XCTAssertFalse(
            SessionAPITransportSecurity.exactBearerAuthorization(
                headerLines: [
                    "Authorization: Bearer synthetic-token",
                    "Authorization: Bearer synthetic-token"
                ],
                token: token
            )
        )
    }

    func testContentLengthRequiresOneBoundedDecimalValue() {
        XCTAssertEqual(
            SessionAPITransportSecurity.contentLength(
                headerLines: ["Content-Length: 42"],
                maximum: 100
            ),
            .valid(42)
        )
        XCTAssertEqual(
            SessionAPITransportSecurity.contentLength(
                headerLines: [],
                maximum: 100
            ),
            .absent
        )
        for headers in [
            ["Content-Length: nope"],
            ["Content-Length: 101"],
            ["Content-Length: 2", "Content-Length: 2"],
            ["Content-Length: -1"],
        ] {
            XCTAssertEqual(
                SessionAPITransportSecurity.contentLength(
                    headerLines: headers,
                    maximum: 100
                ),
                .invalid
            )
        }
    }

    func testTokenCreationAndExistingFileRepairAreOwnerOnly() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConduitSessionAPITransportSecurityTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let tokenURL = directory.appendingPathComponent("session-api-token")
        let created = try SessionAPITransportSecurity.loadOrCreateToken(
            at: tokenURL
        )
        XCTAssertFalse(created.isEmpty)
        XCTAssertEqual(try permissions(of: tokenURL), 0o600)

        try "synthetic-existing-token".write(
            to: tokenURL,
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(
            tokenURL.path.withCString { Darwin.chmod($0, mode_t(0o644)) },
            0
        )

        XCTAssertEqual(
            try SessionAPITransportSecurity.loadOrCreateToken(at: tokenURL),
            "synthetic-existing-token"
        )
        XCTAssertEqual(try permissions(of: tokenURL), 0o600)

        let symlinkTarget = directory.appendingPathComponent("synthetic-target")
        try "synthetic-target-token".write(
            to: symlinkTarget,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.removeItem(at: tokenURL)
        try FileManager.default.createSymbolicLink(
            at: tokenURL,
            withDestinationURL: symlinkTarget
        )
        XCTAssertThrowsError(
            try SessionAPITransportSecurity.loadOrCreateToken(at: tokenURL)
        )
        }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
