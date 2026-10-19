import Foundation
import ConduitCore

func runOpenCodeIdentityChecks(_ check: (String, Bool) -> Void) {
    var mapper = OpenCodeEventMapper()
    mapper.sessionID = "S"
    let prompt = UUID()
    let response = CodexJSON.parseLine(#"{"info":{"sessionID":"S","id":"M","role":"assistant"},"parts":[]}"#)!
    let part = OpenCodeEventMapper.parseSSELine(#"data: {"type":"message.part.updated","properties":{"part":{"sessionID":"S","messageID":"M","id":"part","type":"text","text":"answer"}}}"#)!
    let done = OpenCodeEventMapper.parseSSELine(#"data: {"type":"message.updated","properties":{"info":{"sessionID":"S","id":"M","role":"assistant","time":{"completed":1}}}}"#)!
    check("OpenCode unbound SSE has no authority", mapper.applyIdentified(part).isEmpty)
    check("OpenCode unbound identity is explicit", mapper.identityDiagnostic?.contains("UNKNOWN") == true)
    check("OpenCode exact HTTP assistant binds", mapper.accept(response, promptEventID: prompt))
    check("OpenCode HTTP acceptance is not completion", mapper.lastTurnStatus == nil)
    let output = mapper.applyIdentified(part)
    check("OpenCode effect retains exact prompt", output.first?.identity.promptEventID == prompt)
    check("OpenCode effect retains exact message", output.first?.identity.messageID == "M")
    check("OpenCode matched SSE completes", mapper.applyIdentified(done).last?.effect == .turnCompleted(status: "completed"))
    check("OpenCode closed message cannot reopen", mapper.applyIdentified(part).isEmpty)
    mapper.resetTurn()
    check("OpenCode old completion cannot close next prompt", mapper.applyIdentified(done).isEmpty)
    check("OpenCode reused response identity is rejected", !mapper.accept(response, promptEventID: UUID()))
}
