import Foundation
import XCTest
@testable import ConduitCore

final class ConduitOfflineGuestContractTests: XCTestCase {
    private var job: [String: Any] {
        let sha = String(repeating: "a", count: 64)
        return ["schemaVersion": "conduit-offline-guest-job/v1", "operationID": "sample-1", "attemptID": "1D33EEA0-BB15-4E49-BE85-7815CCF2185E", "profileID": "profile-1",
                "workerUID": 501, "workerSHA256": sha, "projectManifestSHA256": sha, "checkScriptSHA256": sha,
                "toolchainInventorySHA256": sha, "dependencyInventorySHA256": sha]
    }
    func testGuestRequestCannotSupplyCommandEnvironmentOrHostAuthority() throws {
        let valid = try JSONSerialization.data(withJSONObject: job)
        XCTAssertEqual(try ConduitOfflineGuestJob.decode(valid).operationID, "sample-1")
        for key in ["argv", "environment", "grant", "project_root"] {
            var changed = job; changed[key] = "untrusted"
            XCTAssertThrowsError(try ConduitOfflineGuestJob.decode(JSONSerialization.data(withJSONObject: changed)))
        }
        var root = job; root["workerUID"] = 0
        XCTAssertThrowsError(try ConduitOfflineGuestJob.decode(JSONSerialization.data(withJSONObject: root)))
        XCTAssertEqual(ConduitOfflineGuestJob.argv, ["/bin/bash", "/work/project/scripts/test.sh", "--jobs", "2"])
        XCTAssertEqual(Set(ConduitOfflineGuestJob.environment.keys), ["PATH", "LANG", "DEVELOPER_DIR", "HOME", "TMPDIR"])
    }
    func testRetainedPrefixAccountsForBytesBeyondLimitAndKeepsEOFSeparate() {
        var output = ConduitOfflineGuestOutput(limit: 4)
        output.append(Data([0, 255, 1])); output.append(Data([2, 3, 4]))
        XCTAssertEqual(output.prefix, Data([0, 255, 1, 2]))
        XCTAssertEqual(output.observedBytes, 6); XCTAssertEqual(output.omittedBytes, 2)
        XCTAssertFalse(output.reachedEOF)
        output.finish(); XCTAssertTrue(output.reachedEOF)
    }
    func testEvidenceCannotReplacePriorClaimOrResult() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("conduit-guest-contract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { ConduitOfflineFixtureEvidence.preserveAndClean(dir, test: name) }
        for name in ["attempt.claim", "result.json"] {
            try ConduitOfflineGuestEvidence.writeOnce(Data("original".utf8), directory: dir, name: name)
            XCTAssertThrowsError(try ConduitOfflineGuestEvidence.writeOnce(Data("replacement".utf8), directory: dir, name: name))
            XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(name)), Data("original".utf8))
        }
        XCTAssertThrowsError(try ConduitOfflineGuestEvidence.writeOnce(Data(), directory: dir, name: "../escape"))
    }
}
