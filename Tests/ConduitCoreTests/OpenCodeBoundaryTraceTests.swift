import ConduitCore
import Foundation
import XCTest

final class OpenCodeBoundaryTraceTests: XCTestCase {
    private let binding = OpenCodeBoundaryTrace.Binding(
        taskSessionID: UUID(), runtimeID: UUID(), runtimeAttemptID: UUID()
    )
    private func trace(recordLimit: Int = 256, requestLimit: Int = 32) -> OpenCodeBoundaryTrace {
        var value = OpenCodeBoundaryTrace(binding: binding, recordLimit: recordLimit,
                                          requestLimit: requestLimit, now: 0)
        value.bindSession("ses_owned", now: 1)
        return value
    }
    private func event(_ type: String, _ properties: [String: CodexJSON]) -> CodexJSON {
        .object(["type": .string(type), "properties": .object(properties)])
    }
    private func busy(_ session: CodexJSON = .string("ses_owned")) -> CodexJSON {
        event("session.status", ["sessionID": session, "status": .object(["type": .string("busy")])])
    }
    private func started(_ value: inout OpenCodeBoundaryTrace, now: UInt64 = 2) -> OpenCodeBoundaryTrace.Ticket {
        let ticket = value.beginDelivery(sessionID: "ses_owned", ready: true, now: now)!
        value.scheduled(ticket, now: now); value.entered(ticket, now: now)
        value.requestStarted(ticket, now: now)
        return ticket
    }
    func testBindingKeepsEveryDeclaredIdentityAndUnknownTask() throws {
        let value = trace()
        XCTAssertEqual(value.snapshot.binding, binding)
        let unknown = OpenCodeBoundaryTrace.Binding(taskSessionID: nil, runtimeID: UUID(), runtimeAttemptID: UUID())
        let encoded = String(data: try JSONEncoder().encode(unknown), encoding: .utf8)!
        XCTAssertTrue(encoded.contains("unknown"))
        XCTAssertEqual(unknown.taskSessionKnowledge, .unknown)
    }
    func testNonReadyDeliveryDoesNotCreateRequest() {
        var value = trace()
        XCTAssertNil(value.beginDelivery(sessionID: "ses_owned", ready: false, now: 2))
        XCTAssertEqual(value.snapshot.records.last?.kind, .deliveryRefused)
        XCTAssertEqual(value.snapshot.records.last?.reason, .notReady)
        XCTAssertFalse(value.snapshot.records.contains { $0.kind == .httpRequestStarted })
    }
    func testLocalStagesAreDistinctAndHTTPDoesNotMintProviderFact() {
        var value = trace(); let ticket = started(&value)
        value.response(ticket, statusCode: 204, now: 7)
        XCTAssertEqual(value.snapshot.records.suffix(5).map(\.kind),
                       [.localDelivery, .taskScheduled, .taskEntered, .httpRequestStarted, .httpResponse])
        XCTAssertEqual(value.snapshot.records.last?.localDeliveryID, ticket.localDeliveryID)
        XCTAssertEqual(value.snapshot.records.last?.providerState, .unknown)
        XCTAssertEqual(value.snapshot.records.last?.providerTurnIdentity, .unknown)
    }
    func testResponseBeforeDispatchAndDuplicateCallbacksRefuse() {
        var value = trace()
        let ticket = value.beginDelivery(sessionID: "ses_owned", ready: true, now: 2)!
        value.response(ticket, statusCode: 200, now: 3)
        XCTAssertEqual(value.snapshot.records.last?.reason, .invalidOrder)
        value.scheduled(ticket, now: 4); value.entered(ticket, now: 5); value.requestStarted(ticket, now: 6)
        value.response(ticket, statusCode: 200, now: 7); value.response(ticket, statusCode: 200, now: 8)
        XCTAssertEqual(value.snapshot.records.last?.reason, .duplicateCallback)
        XCTAssertEqual(value.snapshot.records.filter { $0.kind == .httpResponse }.count, 1)
    }
    func testReverseResponsesRetainTheirOriginalLocalIdentity() {
        var value = trace(); let first = started(&value); let second = started(&value, now: 3)
        value.response(second, statusCode: 201, now: 4); value.response(first, statusCode: 500, now: 5)
        let responses = value.snapshot.records.filter { $0.kind == .httpResponse }
        XCTAssertEqual(responses.map(\.localDeliveryID), [second.localDeliveryID, first.localDeliveryID])
        XCTAssertEqual(responses.map(\.httpStatusCode), [201, 500])
    }
    func testForeignTraceTicketCannotAcquireCallbackAuthority() {
        var first = trace(); let ticket = started(&first); var second = trace()
        second.response(ticket, statusCode: 200, now: 3)
        XCTAssertEqual(second.snapshot.records.last?.reason, .unknownRequest)
        XCTAssertNil(second.snapshot.records.last?.localDeliveryID)
    }
    func testStopAndRebindRefuseStaleLocalAndStreamCallbacks() {
        var value = trace(); let oldEpoch = value.streamEpoch; let ticket = started(&value)
        value.stop(now: 3); value.bindSession("ses_owned", now: 4)
        value.response(ticket, statusCode: 200, now: 5)
        XCTAssertEqual(value.snapshot.records.last?.reason, .staleEpoch)
        value.observe(busy(), streamEpoch: oldEpoch, now: 6)
        XCTAssertEqual(value.snapshot.records.last?.reason, .staleEpoch)
    }
    func testExactBusyReportHasUnknownFreshnessAndNoLatestRequest() {
        var value = trace(); _ = started(&value)
        value.observe(busy(), streamEpoch: value.streamEpoch, now: 3)
        let record = value.snapshot.records.last!
        XCTAssertEqual(record.kind, .sessionBusyReported)
        XCTAssertEqual(record.providerObservationFreshness, .unknown)
        XCTAssertEqual(record.providerTurnIdentity, .unknown)
        XCTAssertEqual(record.localRequestCorrelation, .unknown)
        XCTAssertNil(record.localDeliveryID)
    }
    func testMissingNullMalformedForeignSessionDoNotMintBusy() {
        let inputs = [event("session.status", ["status": .object(["type": .string("busy")])]),
                      busy(.null), busy(.number(1)), busy(.string("ses_foreign")), busy(.string("ses_"))]
        for input in inputs {
            var value = trace(); value.observe(input, streamEpoch: value.streamEpoch, now: 2)
            XCTAssertEqual(value.snapshot.records.last?.kind, .eventRefused)
            XCTAssertFalse(value.snapshot.records.contains { $0.kind == .sessionBusyReported })
        }
    }
    func testEveryConflictingSessionLocationRefuses() {
        for additional in [
            ["info": CodexJSON.object(["sessionID": .string("ses_foreign")])],
            ["part": CodexJSON.object(["sessionID": .string("ses_foreign")])],
            ["session": CodexJSON.object(["id": .string("ses_foreign")])],
            ["id": CodexJSON.string("ses_foreign")]
        ] {
            var props: [String: CodexJSON] = ["sessionID": .string("ses_owned"),
                                             "status": .object(["type": .string("busy")])]
            props.merge(additional) { _, new in new }
            var value = trace(); value.observe(event("session.status", props), streamEpoch: value.streamEpoch, now: 2)
            XCTAssertEqual(value.snapshot.records.last?.reason, .conflictingIdentity)
        }
    }
    func testTopLevelConflictingSessionAndMalformedContainerRefuse() {
        var value = trace()
        value.observe(.object(["type": .string("session.status"), "sessionID": .string("ses_foreign"),
                               "properties": .object(["sessionID": .string("ses_owned")])]),
                      streamEpoch: value.streamEpoch, now: 2)
        XCTAssertEqual(value.snapshot.records.last?.reason, .conflictingIdentity)
        value.observe(event("session.status", ["sessionID": .string("ses_owned"), "info": .null]),
                      streamEpoch: value.streamEpoch, now: 3)
        XCTAssertEqual(value.snapshot.records.last?.reason, .malformedEvent)
    }
    func testAssistantSnapshotAndCompletionAreReportsWithoutTurnAuthority() {
        var value = trace()
        value.observe(event("message.updated", ["info": .object([
            "sessionID": .string("ses_owned"), "id": .string("msg_owned"), "role": .string("assistant"),
            "time": .object(["completed": .number(100)])
        ])]), streamEpoch: value.streamEpoch, now: 2)
        XCTAssertEqual(value.snapshot.records.suffix(2).map(\.kind), [.messageSnapshotObserved, .messageCompletionReported])
        XCTAssertTrue(value.snapshot.records.suffix(2).allSatisfy { $0.providerTurnIdentity == .unknown && $0.localDeliveryID == nil })
    }
    func testMalformedCompletionAndRoleDoNotMintCompletion() {
        for completed in [CodexJSON.null, .string("100"), .number(.infinity), .number(-1), .bool(true)] {
            var value = trace()
            value.observe(event("message.updated", ["info": .object([
                "sessionID": .string("ses_owned"), "id": .string("msg_owned"), "role": .string("assistant"),
                "time": .object(["completed": completed])
            ])]), streamEpoch: value.streamEpoch, now: 2)
            XCTAssertFalse(value.snapshot.records.contains { $0.kind == .messageCompletionReported })
        }
        var value = trace()
        value.observe(event("message.updated", ["info": .object([
            "sessionID": .string("ses_owned"), "id": .string("msg_owned"), "role": .string("unknown")
        ])]), streamEpoch: value.streamEpoch, now: 2)
        XCTAssertEqual(value.snapshot.records.last?.reason, .malformedEvent)
    }
    func testToolRunningRequiresExactPartAndMessageIdentity() {
        var value = trace()
        let part: CodexJSON = .object(["sessionID": .string("ses_owned"), "id": .string("prt_owned"),
                                       "messageID": .string("msg_owned"), "type": .string("tool"),
                                       "state": .object(["status": .string("running")])])
        value.observe(event("message.part.updated", ["part": part]), streamEpoch: value.streamEpoch, now: 2)
        XCTAssertEqual(value.snapshot.records.last?.kind, .toolPartReported)
        XCTAssertEqual(value.snapshot.records.last?.providerState, .running)
        value.observe(event("message.part.updated", ["part": part, "messageID": .string("msg_other")]),
                      streamEpoch: value.streamEpoch, now: 3)
        XCTAssertEqual(value.snapshot.records.last?.reason, .conflictingIdentity)
    }
    func testDuplicateReplayReportsRemainUnsequencedAndUnattributed() {
        var value = trace()
        for index in 2...6 { value.observe(busy(), streamEpoch: value.streamEpoch, now: UInt64(index)) }
        let reports = value.snapshot.records.filter { $0.kind == .sessionBusyReported }
        XCTAssertEqual(reports.count, 5)
        XCTAssertTrue(reports.allSatisfy { $0.providerObservationFreshness == .unknown && $0.localRequestCorrelation == .unknown })
    }
    func testProviderIDsAreKindBoundedHashesAndDoNotLeakStrings() throws {
        let secret = "NEVER_COPY_FIXTURE"
        var value = trace()
        value.observe(event("message.updated", ["info": .object([
            "sessionID": .string("ses_owned"), "id": .string("msg_" + secret), "role": .string("assistant"),
            "text": .string(secret), "url": .string(secret), "model": .string(secret), "error": .string(secret)
        ]), "output": .string(secret), "auth": .string(secret)]), streamEpoch: value.streamEpoch, now: 2)
        let encoded = String(data: try JSONEncoder().encode(value.snapshot), encoding: .utf8)!
        XCTAssertFalse(encoded.contains(secret)); XCTAssertFalse(encoded.contains("ses_owned"))
        XCTAssertTrue(encoded.contains("unknown"))
        XCTAssertEqual(value.snapshot.records.last?.providerMessage?.digest.count, 64)
    }
    func testIdentifierLimitsAndInvalidUnicodeDoNotAcquireAuthority() {
        XCTAssertNil(OpenCodeBoundaryTrace.ProviderIdentifier.observing("ses_" + String(repeating: "a", count: 125), kind: .session))
        XCTAssertNil(OpenCodeBoundaryTrace.ProviderIdentifier.observing("ses_é", kind: .session))
        XCTAssertNil(OpenCodeBoundaryTrace.ProviderIdentifier.observing("msg_owned", kind: .session))
        XCTAssertNil(OpenCodeBoundaryTrace.ProviderIdentifier.observing("ses_owned\n", kind: .session))
    }
    func testRecordAndRequestCapsDiscloseLossAndCanRetireCompletedRequests() {
        var value = trace(recordLimit: 3, requestLimit: 1); let ticket = started(&value)
        XCTAssertNil(value.beginDelivery(sessionID: "ses_owned", ready: true, now: 3))
        XCTAssertEqual(value.snapshot.untrackedDeliveryCount, 1)
        value.response(ticket, statusCode: 200, now: 4)
        XCTAssertNotNil(value.beginDelivery(sessionID: "ses_owned", ready: true, now: 5))
        XCTAssertEqual(value.snapshot.records.count, 3)
        XCTAssertGreaterThan(value.snapshot.droppedRecordCount, 0)
        XCTAssertFalse(value.snapshot.completeRetention)
    }
    func testBackwardClockRefusesAndEqualTimeIsAllowed() {
        var value = trace(); let before = value.snapshot.records.count
        value.observe(busy(), streamEpoch: value.streamEpoch, now: 0)
        XCTAssertEqual(value.snapshot.records.count, before)
        XCTAssertEqual(value.snapshot.refusedClockCount, 1)
        value.observe(busy(), streamEpoch: value.streamEpoch, now: 1)
        XCTAssertEqual(value.snapshot.records.last?.kind, .sessionBusyReported)
    }
    func testMalformedTopLevelTypeAliasesStatusAndPropertiesRefuse() {
        let inputs: [CodexJSON] = [.null, .array([]), .object(["type": .number(1)]),
            .object(["type": .string("session.status"), "event": .string("session.idle")]),
            .object(["type": .string("session.status"), "properties": .null]),
            event("session.status", ["sessionID": .string("ses_owned"), "status": .string("busy")])]
        for input in inputs {
            var value = trace(); value.observe(input, streamEpoch: value.streamEpoch, now: 2)
            XCTAssertEqual(value.snapshot.records.last?.kind, .eventRefused)
        }
    }
    func testTransportFailureCannotBecomeResponseOrProviderBusy() {
        var value = trace(); let ticket = started(&value)
        value.transportFailed(ticket, now: 3)
        XCTAssertEqual(value.snapshot.records.last?.kind, .transportFailure)
        XCTAssertFalse(value.snapshot.records.contains { $0.kind == .httpResponse || $0.kind == .sessionBusyReported })
    }
    func testNonHTTPAndInvalidStatusRemainUnknown() {
        for status in [nil, 0, 600] as [Int?] {
            var value = trace(); let ticket = started(&value)
            value.response(ticket, statusCode: status, now: 3)
            XCTAssertEqual(value.snapshot.records.last?.httpStatusKnowledge, .unknown)
            XCTAssertNil(value.snapshot.records.last?.httpStatusCode)
        }
    }
}
