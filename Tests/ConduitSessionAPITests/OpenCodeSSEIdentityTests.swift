#if os(macOS)
import XCTest
import ConduitCore
@testable import Conduit

@MainActor
final class OpenCodeSSEIdentityTests: XCTestCase {
    final class HTTP {
        var continuation: CheckedContinuation<(Data, URLResponse), Error>?
        var started: XCTestExpectation?
        var request: URLRequest?
        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            self.request = request
            return try await withCheckedThrowingContinuation {
                continuation = $0
                started?.fulfill()
            }
        }
        func respond(_ status: Int, message: String?, session: String = "S") {
            let body = message.map { "{\"info\":{\"id\":\"\($0)\",\"sessionID\":\"\(session)\",\"role\":\"assistant\"},\"parts\":[]}" } ?? "{}"
            continuation?.resume(returning: (Data(body.utf8), HTTPURLResponse(url: request!.url!, statusCode: status, httpVersion: nil, headerFields: nil)!))
            continuation = nil
        }
    }
    private func part(_ client: OpenCodeHTTPClient, _ message: String, _ text: String, session: String = "S") {
        client.receiveSSELine("data: {\"type\":\"message.part.updated\",\"properties\":{\"part\":{\"id\":\"part_\(message)\",\"messageID\":\"\(message)\",\"sessionID\":\"\(session)\",\"type\":\"text\",\"text\":\"\(text)\"}}}")
    }
    private func done(_ client: OpenCodeHTTPClient, _ message: String, session: String = "S") {
        client.receiveSSELine("data: {\"type\":\"message.updated\",\"properties\":{\"info\":{\"id\":\"\(message)\",\"sessionID\":\"\(session)\",\"role\":\"assistant\",\"time\":{\"completed\":1}}}}")
    }
    private func outputs(_ runtime: TerminalRuntime) -> [AgentVisibleOutput] {
        runtime.presentationEvents.compactMap { if case .agentOutput(let output) = $0.kind { return output }; return nil }
    }
    func testLateP1CannotOwnQueuedOrAcceptedP3() async {
        for success in [false, true] {
            let http = HTTP()
            let client = OpenCodeHTTPClient(cwd: URL(fileURLWithPath: NSTemporaryDirectory()), sessionID: "S", httpTransport: http.send)
            var settled: XCTestExpectation?
            var outputOrigins: [SessionControlOrigin] = []
            let runtime = TerminalRuntime(descriptor: SessionDescriptor(projectPath: URL(fileURLWithPath: NSTemporaryDirectory()), agent: AgentProfile(name: "Fixture", command: "fixture")), useDetachedSessions: false, entry: .started(agentName: "Fixture", requestedBackend: "fixture"), recordEventRevision: { event, origin in
                if case .agentOutput = event.kind { outputOrigins.append(origin) }
                if case .userPrompt(let prompt) = event.kind, prompt.delivery != .queued { settled?.fulfill() }
            })
            runtime.wireStructured(client)
            func send(_ text: String) async -> UUID {
                http.started = expectation(description: "POST \(text)")
                let id = runtime.recordPrompt(text: text, attachmentPaths: [], renderedPayload: text, controlOrigin: text == "P1" ? .sessionAPI : .operatorUI)
                XCTAssertEqual(runtime.deliverStructuredPrompt(eventID: id, text: text), .queued)
                await fulfillment(of: [http.started!], timeout: 2)
                XCTAssertEqual(http.request?.httpMethod, "POST")
                XCTAssertEqual(http.request?.url?.path, "/session/S/message")
                return id
            }
            func respond(_ status: Int, _ message: String?) async {
                settled = expectation(description: "HTTP settled")
                http.respond(status, message: message)
                await fulfillment(of: [settled!], timeout: 2)
                settled = nil
            }
            let p1 = await send("P1")
            await respond(200, "M1")
            XCTAssertNil(client.lastTurnStatus, "2xx is not completion")
            part(client, "M1", "original")
            done(client, "M1")
            XCTAssertEqual(outputs(runtime).first?.promptEventID, p1)
            _ = await send("P2")
            await respond(503, nil)
            let p3 = await send("P3")
            part(client, "M1", "stale")
            done(client, "M1")
            XCTAssertEqual(outputs(runtime).count, 1, "late P1 must not create P3 output")
            XCTAssertEqual(outputs(runtime).first?.text, "original")
            XCTAssertNil(client.lastTurnStatus, "late P1 must not close P3")
            XCTAssertTrue(outputOrigins.allSatisfy { $0 == .sessionAPI }, "stale SSE must not create operator feedback")
            await respond(success ? 200 : 503, success ? "M3" : nil)
            if success {
                part(client, "M1", "late again")
                done(client, "M1")
                part(client, "M3", "foreign", session: "other")
                done(client, "M3", session: "other")
                XCTAssertNil(client.lastTurnStatus)
                part(client, "M3", "correct")
                done(client, "M3")
                XCTAssertEqual(outputs(runtime).last?.promptEventID, p3)
                XCTAssertEqual(outputs(runtime).last?.text, "correct")
                XCTAssertEqual(outputOrigins.last, .operatorUI)
            } else {
                XCTAssertEqual(outputs(runtime).count, 1)
                XCTAssertNotNil(client.turnFailure)
                XCTAssertNil(client.lastTurnStatus)
            }
            guard let event = runtime.presentationEvents.first(where: { $0.id == p3 }),
                  case .userPrompt(let submitted) = event.kind else { return XCTFail("missing P3") }
            XCTAssertEqual(submitted.delivery, success ? .delivered : .failed)
            let snapshot = runtime.presentationEvents
            done(client, "M1")
            client.stop()
            part(client, "M3", "after stop")
            done(client, "M3")
            XCTAssertEqual(runtime.presentationEvents, snapshot)
        }
    }
    func testSSEBeforeHTTPIsReplayedOnlyWithProvenIdentity() async {
        for mode in ["bound", "missing", "foreign", "overflow", "refused", "stopped"] {
            let http = HTTP()
            let client = OpenCodeHTTPClient(cwd: URL(fileURLWithPath: NSTemporaryDirectory()), sessionID: "S", httpTransport: http.send)
            var settled: XCTestExpectation?
            let runtime = TerminalRuntime(descriptor: SessionDescriptor(projectPath: URL(fileURLWithPath: NSTemporaryDirectory()), agent: AgentProfile(name: "Fixture", command: "fixture")), useDetachedSessions: false, entry: .started(agentName: "Fixture", requestedBackend: "fixture"), recordEventRevision: { event, _ in
                if case .userPrompt(let prompt) = event.kind, prompt.delivery != .queued { settled?.fulfill() }
            })
            runtime.wireStructured(client)
            http.started = expectation(description: "POST started")
            let id = runtime.recordPrompt(text: "early", attachmentPaths: [], renderedPayload: "early")
            XCTAssertEqual(runtime.deliverStructuredPrompt(eventID: id, text: "early"), .queued)
            await fulfillment(of: [http.started!], timeout: 2)
            part(client, "M", "early answer")
            done(client, "M")
            XCTAssertTrue(outputs(runtime).isEmpty)
            XCTAssertNil(client.lastTurnStatus)
            XCTAssertTrue(client.identityDiagnostic?.contains("UNKNOWN") == true)
            if mode == "overflow" {
                for _ in 0..<2048 { part(client, "M", "excess") }
            }
            settled = expectation(description: "HTTP outcome")
            if mode == "stopped" { client.stop() }
            http.respond(mode == "refused" ? 503 : 200, message: mode == "missing" ? nil : "M", session: mode == "foreign" ? "other" : "S")
            await fulfillment(of: [settled!], timeout: 2)
            if mode == "bound" {
                XCTAssertEqual(outputs(runtime).last?.promptEventID, id)
                XCTAssertEqual(outputs(runtime).last?.text, "early answer")
                XCTAssertEqual(outputs(runtime).last?.state, .closed)
                XCTAssertEqual(client.lastTurnStatus, "completed")
                let snapshot = runtime.presentationEvents
                part(client, "M", "duplicate")
                done(client, "M")
                XCTAssertEqual(runtime.presentationEvents, snapshot)
            } else {
                XCTAssertTrue(outputs(runtime).isEmpty)
                XCTAssertNil(client.lastTurnStatus)
                if mode != "refused" && mode != "stopped" {
                    XCTAssertTrue(runtime.conversationCaptureNotice?.contains("UNKNOWN") == true)
                }
            }
            client.stop()
        }
    }

}
#endif
