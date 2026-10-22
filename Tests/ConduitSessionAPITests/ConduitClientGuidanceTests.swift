#if os(macOS)
import Foundation
import XCTest
import ConduitCore
@testable import Conduit

@MainActor
final class ConduitClientGuidanceTests: XCTestCase {
    private func request(_ server: ConduitSessionAPIServer, method: String,
                         authorized: Bool = true) throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1,
            "method": method, "params": ["clientInfo": ["name": "guidance-fixture", "version": "1"]]])
        let header = "POST /mcp HTTP/1.1\r\n"
            + (authorized ? "Authorization: Bearer fixture-token\r\n" : "")
            + "Content-Length: \(body.count)\r\n\r\n"
        let response = server.response(for: Data(header.utf8) + body)
        let split = try XCTUnwrap(response.range(of: Data("\r\n\r\n".utf8)))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: response.suffix(from: split.upperBound)) as? [String: Any])
    }

    func testAuthenticatedInitializePublishesCompactDirectFirstInstructionsWithoutEffects() throws {
        for writes in [false, true] {
            var resolutions = 0, admissions = 0, actions = 0
            let server = ConduitSessionAPIServer(token: "fixture-token", allowWrites: writes,
                projectFilesystemRoot: { _ in resolutions += 1; return nil },
                directWriteAdmission: { _ in admissions += 1; return nil }) { _, _ in
                    actions += 1; return [:]
                }
            let reply = try request(server, method: "initialize")
            let result = try XCTUnwrap(reply["result"] as? [String: Any])
            let instructions = try XCTUnwrap(result["instructions"] as? String)
            XCTAssertEqual(instructions, ConduitSessionToolCatalog.clientInstructions)
            XCTAssertLessThan(instructions.utf8.count, 4_000, "Guidance must fit a small client context budget")
            XCTAssertTrue(instructions.contains("before deploying another agent"))
            XCTAssertTrue(instructions.contains("execution_authority_unavailable"))
            XCTAssertTrue(instructions.contains("do not bypass it through a Shell task"))
            XCTAssertTrue(instructions.contains("original operation ID"))
            XCTAssertEqual(resolutions, 0)
            XCTAssertEqual(admissions, 0)
            XCTAssertEqual(actions, 0)
            let tools = try XCTUnwrap((try request(server, method: "tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]])
            let names = Set(tools.compactMap { $0["name"] as? String })
            let pattern = try NSRegularExpression(pattern: "conduit_[a-z_]+")
            for match in pattern.matches(in: instructions, range: NSRange(instructions.startIndex..., in: instructions)) {
                let range = try XCTUnwrap(Range(match.range, in: instructions))
                XCTAssertTrue(names.contains(String(instructions[range])), "Do not instruct clients to call an unpublished tool")
            }
        }
    }

    func testUnauthorizedInitializationDoesNotExposeInstructionsOrDispatch() throws {
        let server = ConduitSessionAPIServer(token: "fixture-token") { _, _ in
            XCTFail("Unauthorized discovery cannot dispatch an operation"); return [:]
        }
        let reply = try request(server, method: "initialize", authorized: false)
        XCTAssertEqual(reply["error"] as? String, "unauthorized")
        XCTAssertNil(reply["result"])
        XCTAssertNil(reply["instructions"])
    }
}
#endif
