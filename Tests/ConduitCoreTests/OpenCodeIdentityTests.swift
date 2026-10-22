import XCTest
@testable import ConduitCore

final class OpenCodeIdentityTests: XCTestCase {
    private let response = CodexJSON.parseLine(#"{"info":{"sessionID":"S","id":"M","role":"assistant"},"parts":[]}"#)!
    private func event(_ payload: String) -> CodexJSON { OpenCodeEventMapper.parseSSELine("data: " + payload)! }

    func testMessageCannotBeReboundAndEffectsRetainIdentity() {
        var mapper = OpenCodeEventMapper()
        mapper.sessionID = "S"
        let id = UUID()
        XCTAssertTrue(mapper.accept(response, promptEventID: id))
        let output = mapper.applyIdentified(event(#"{"type":"message.part.updated","properties":{"part":{"sessionID":"S","messageID":"M","id":"part","type":"text","text":"answer"}}}"#))
        XCTAssertEqual(output.first?.identity.promptEventID, id)
        XCTAssertEqual(output.first?.identity.sessionID, "S")
        XCTAssertEqual(output.first?.identity.messageID, "M")
        mapper.resetTurn()
        XCTAssertFalse(mapper.accept(response, promptEventID: UUID()))
        XCTAssertNil(mapper.identity)
        XCTAssertTrue(mapper.identityDiagnostic?.contains("UNKNOWN") == true)
    }

    func testMissingConflictingAndSessionOnlyIDsHaveNoAuthority() {
        var mapper = OpenCodeEventMapper()
        mapper.sessionID = "S"
        XCTAssertTrue(mapper.accept(response, promptEventID: UUID()))
        for json in [
            #"{"type":"session.idle","properties":{"sessionID":"S"}}"#,
            #"{"type":"message.updated","properties":{"info":{"sessionID":"other","id":"M","role":"assistant","time":{"completed":1}}}}"#,
            #"{"type":"message.updated","properties":{"sessionID":"S","info":{"sessionID":"other","id":"M","role":"assistant","time":{"completed":1}}}}"#,
            #"{"type":"message.part.updated","properties":{"part":{"messageID":"M","id":"part","type":"text","text":"no session"}}}"#,
            #"{"type":"message.part.updated","properties":{"messageID":"M","part":{"sessionID":"S","messageID":"other","id":"part","type":"text","text":"conflict"}}}"#,
            #"{"type":"message.updated","properties":{"info":{"sessionID":"S","id":"M","role":"user","time":{"completed":1}}}}"#,
            #"{"type":"message.updated","properties":{"info":{"sessionID":"S","id":"M","role":"assistant","time":{"completed":null}}}}"#
        ] {
            XCTAssertTrue(mapper.applyIdentified(event(json)).isEmpty)
            XCTAssertNil(mapper.lastTurnStatus)
            XCTAssertEqual(mapper.accumulatedText, "")
        }
    }

    func testAssistantErrorIsNotCompletion() {
        var mapper = OpenCodeEventMapper()
        mapper.sessionID = "S"
        XCTAssertTrue(mapper.accept(response, promptEventID: UUID()))
        let effects = mapper.applyIdentified(event(#"{"type":"message.updated","properties":{"info":{"sessionID":"S","id":"M","role":"assistant","time":{"completed":1},"error":{"name":"APIError"}}}}"#))
        XCTAssertEqual(effects.count, 1)
        guard case .failed = effects.first?.effect else { return XCTFail("error must not complete") }
        XCTAssertEqual(mapper.lastTurnStatus, "failed")
    }
    func testResponseErrorClosesIdentityBeforeAnySSE() {
        var mapper = OpenCodeEventMapper()
        mapper.sessionID = "S"
        let prompt = UUID()
        let error = CodexJSON.parseLine(#"{"info":{"sessionID":"S","id":"M","role":"assistant","error":{"name":"APIError"},"time":{"completed":1}}}"#)!
        XCTAssertTrue(mapper.accept(error, promptEventID: prompt))
        XCTAssertEqual(mapper.responseFailure?.identity.promptEventID, prompt)
        guard case .failed = mapper.responseFailure?.effect else { return XCTFail("missing failure") }
        XCTAssertEqual(mapper.lastTurnStatus, "failed")
        XCTAssertTrue(mapper.applyIdentified(event(#"{"type":"message.updated","properties":{"info":{"sessionID":"S","id":"M","role":"assistant","time":{"completed":1}}}}"#)).isEmpty)
    }

    func testIdenticalDeltasWithoutUniqueIdentityRemainRepeatedText() {
        var mapper = OpenCodeEventMapper()
        mapper.sessionID = "S"
        XCTAssertTrue(mapper.accept(response, promptEventID: UUID()))
        let delta = event(#"{"type":"message.part.delta","properties":{"sessionID":"S","messageID":"M","partID":"p","field":"text","delta":"ha"}}"#)
        _ = mapper.applyIdentified(delta)
        _ = mapper.applyIdentified(delta)
        XCTAssertEqual(mapper.accumulatedText, "haha")
    }

}
