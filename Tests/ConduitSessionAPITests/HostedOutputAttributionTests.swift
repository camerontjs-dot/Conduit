#if os(macOS)
import XCTest
import ConduitCore
@testable import Conduit

@MainActor
final class HostedOutputAttributionTests: XCTestCase {
    private func runtime(_ revision: ((SessionPresentationEvent, SessionControlOrigin) -> Void)? = nil) -> TerminalRuntime {
        TerminalRuntime(descriptor: SessionDescriptor(projectPath: URL(fileURLWithPath: NSTemporaryDirectory()),
            agent: AgentProfile(name: "Fixture", command: "fixture")), useDetachedSessions: false,
            entry: .started(agentName: "Fixture", requestedBackend: "fixture"), recordEventRevision: revision)
    }
    private func prompt(_ runtime: TerminalRuntime, _ text: String, origin: SessionControlOrigin = .operatorUI) -> UUID {
        runtime.recordPrompt(text: text, attachmentPaths: [], renderedPayload: text, controlOrigin: origin)
    }
    private func delivery(_ runtime: TerminalRuntime, _ id: UUID) -> PromptDeliveryState? {
        guard let event = runtime.presentationEvents.first(where: { $0.id == id }),
              case .userPrompt(let prompt) = event.kind else { return nil }
        return prompt.delivery
    }
    func testRefusedOverlapPreservesOwnerBeforeAndAfterFirstOutput() {
        for hasOutput in [false, true] {
            var outputOrigins: [SessionControlOrigin] = []
            let runtime = runtime { event, origin in
                if case .agentOutput = event.kind { outputOrigins.append(origin) }
            }
            let p1 = prompt(runtime, "P1", origin: .sessionAPI)
            XCTAssertEqual(runtime.deliverStructuredPrompt(eventID: p1, text: "P1", send: {}), .delivered)
            if hasOutput { runtime.applyStructuredEffect(.upsertOutput(text: "first", state: .live), backend: .structuredCli) }
            let outputID = runtime.activeOutputEventID
            let p2 = prompt(runtime, "P2")
            XCTAssertEqual(runtime.deliverStructuredPrompt(eventID: p2, text: "P2", send: {
                throw StreamJSONClient.ClientError.protocolError("a stream-json turn is already running")
            }), .failed)
            XCTAssertEqual(runtime.activeOutputEventID, outputID)
            runtime.applyStructuredEffect(.upsertOutput(text: "later P1", state: .live), backend: .structuredCli)
            let outputs = runtime.presentationEvents.compactMap { event -> AgentVisibleOutput? in
                if case .agentOutput(let output) = event.kind { return output }; return nil
            }
            XCTAssertEqual(outputs.count, 1)
            XCTAssertEqual(outputs.last?.promptEventID, p1)
            XCTAssertEqual(delivery(runtime, p2), .failed)
            XCTAssertTrue(outputOrigins.allSatisfy { $0 == .sessionAPI })
        }
    }
    func testHTTPPendingThenExactAcceptanceOrFailure() async {
        for fails in [false, true] {
            var continuation: CheckedContinuation<Void, Error>?
            let started = expectation(description: "HTTP request started")
            let client = OpenCodeHTTPClient(cwd: URL(fileURLWithPath: NSTemporaryDirectory()), promptTransport: { _ in
                try await withCheckedThrowingContinuation {
                    continuation = $0
                    started.fulfill()
                }
            })
            let settled = expectation(description: "exact HTTP prompt settled")
            var p1: UUID?
            let runtime = runtime { event, _ in
                if event.id == p1, case .userPrompt(let prompt) = event.kind,
                   prompt.delivery != .queued { settled.fulfill() }
            }
            runtime.wireStructured(client)
            p1 = prompt(runtime, "P1")
            let promptID = p1!
            XCTAssertEqual(runtime.deliverStructuredPrompt(eventID: promptID, text: "P1"), .queued)
            XCTAssertEqual(delivery(runtime, promptID), .queued)
            await fulfillment(of: [started], timeout: 2)
            let p2 = prompt(runtime, "P2")
            if fails { continuation?.resume(throwing: OpenCodeHTTPClient.ClientError.protocolError("fixture HTTP 503")) }
            else { continuation?.resume() }
            await fulfillment(of: [settled], timeout: 2)
            XCTAssertEqual(delivery(runtime, promptID), fails ? .failed : .delivered)
            XCTAssertEqual(delivery(runtime, p2), .queued)
            XCTAssertNil(client.lastTurnStatus)
        }
    }
    func testHTTPOverlapRefusedAndLateResponseAfterStopCannotRewriteEvents() async {
        for lateFailure in [false, true] {
            var continuation: CheckedContinuation<Void, Error>?
            let started = expectation(description: "HTTP request started")
            let client = OpenCodeHTTPClient(cwd: URL(fileURLWithPath: NSTemporaryDirectory()), promptTransport: { _ in
                try await withCheckedThrowingContinuation {
                    continuation = $0
                    started.fulfill()
                }
            })
            let runtime = runtime()
            runtime.wireStructured(client)
            let p1 = prompt(runtime, "P1", origin: .sessionAPI)
            XCTAssertEqual(runtime.deliverStructuredPrompt(eventID: p1, text: "P1"), .queued)
            await fulfillment(of: [started], timeout: 2)
            runtime.applyStructuredEffect(.upsertOutput(text: "P1 output", state: .live), backend: .httpServer)
            let outputID = runtime.activeOutputEventID
            let p2 = prompt(runtime, "P2")
            XCTAssertEqual(runtime.deliverStructuredPrompt(eventID: p2, text: "P2"), .failed)
            XCTAssertEqual(runtime.activeOutputEventID, outputID)
            client.stop()
            XCTAssertEqual(delivery(runtime, p1), .failed)
            XCTAssertTrue(runtime.conversationCaptureNotice?.contains("unknown") == true)
            var nextContinuation: CheckedContinuation<Void, Error>?
            let nextStarted = expectation(description: "replacement HTTP request started")
            let nextClient = OpenCodeHTTPClient(cwd: URL(fileURLWithPath: NSTemporaryDirectory()), promptTransport: { _ in
                try await withCheckedThrowingContinuation {
                    nextContinuation = $0
                    nextStarted.fulfill()
                }
            })
            runtime.wireStructured(nextClient)
            let p3 = prompt(runtime, "P3")
            XCTAssertEqual(runtime.deliverStructuredPrompt(eventID: p3, text: "P3"), .queued)
            await fulfillment(of: [nextStarted], timeout: 2)
            runtime.applyStructuredEffect(.upsertOutput(text: "P3 output", state: .live), backend: .httpServer)
            let snapshot = runtime.presentationEvents
            let staleFailure = expectation(description: "stale failure must not emit")
            staleFailure.isInverted = true
            client.onFailed = { _ in staleFailure.fulfill() }
            if lateFailure { continuation?.resume(throwing: OpenCodeHTTPClient.ClientError.protocolError("late HTTP error")) }
            else { continuation?.resume() }
            await fulfillment(of: [staleFailure], timeout: 0.1)
            XCTAssertEqual(runtime.presentationEvents, snapshot)
            XCTAssertEqual(delivery(runtime, p3), .queued)
            XCTAssertNil(client.lastTurnStatus)
            XCTAssertNil(client.lastError)
            nextClient.stop()
            nextContinuation?.resume()
        }
    }

    func testHeldHTTPPromptRemainsQueuedUntilAcceptance() async {
        var continuation: CheckedContinuation<Void, Error>?
        let started = expectation(description: "held request started")
        let client = OpenCodeHTTPClient(cwd: URL(fileURLWithPath: NSTemporaryDirectory()), promptTransport: { _ in
            try await withCheckedThrowingContinuation {
                continuation = $0
                started.fulfill()
            }
        })
        let settled = expectation(description: "held prompt delivered")
        let runtime = runtime { event, _ in
            if case .userPrompt(let prompt) = event.kind, prompt.delivery == .delivered { settled.fulfill() }
        }
        runtime.wireStructured(client)
        let p1 = prompt(runtime, "held")
        runtime.holdPromptUntilReady(eventID: p1, text: "held")
        runtime.deliverHeldPrompts()
        XCTAssertEqual(runtime.heldPromptCount, 0)
        XCTAssertEqual(delivery(runtime, p1), .queued)
        await fulfillment(of: [started], timeout: 2)
        continuation?.resume()
        await fulfillment(of: [settled], timeout: 2)
        XCTAssertEqual(delivery(runtime, p1), .delivered)
        XCTAssertNil(client.lastTurnStatus)
    }

}
#endif
