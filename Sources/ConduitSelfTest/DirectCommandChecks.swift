import ConduitCore
import Foundation

func runDirectCommandSelfChecks(_ report: (String, Bool) -> Void) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("conduit-command-selfcheck-\(UUID().uuidString)")
    let service = ConduitDirectCommandService(storeDirectory: base.appendingPathComponent("receipts"))
    var admissionCalls = 0
    let arguments: CodexJSON = .object([
        "operation_id": .string("selfcheck"), "project_slug": .string("fixture"),
        "argv": .array([.string("/usr/bin/printf"), .string("unused")]),
    ])
    let result = ConduitDirectCommandTool.perform(operation: "execute", arguments: arguments,
                                                 projectRoot: base, service: service) { admissionCalls += 1 }
    report("direct command production authority is unavailable", result["status"] as? String == "execution_authority_unavailable")
    report("direct command unavailable authority consumes no write admission", admissionCalls == 0)
    report("direct command unavailable authority creates no files", !FileManager.default.fileExists(atPath: base.path))
    let status = ConduitDirectCommandTool.perform(operation: "status", arguments: .object([
        "operation_id": .string("selfcheck"), "project_slug": .string("fixture"),
    ]), projectRoot: base, service: service)
    report("direct command absent lookup is explicit", status["status"] as? String == "operation_not_found")
    report("direct command status remains read-only", !FileManager.default.fileExists(atPath: base.path))
    let overridden = ConduitDirectCommandTool.perform(operation: "status", arguments: arguments,
                                                     projectRoot: base, service: service)
    report("direct command read tool cannot be changed into execution", overridden["status"] as? String == "invalid_arguments")
    report("direct command requested cancellation is not terminal", !ConduitDirectCommandPhase.cancelRequested.isTerminal)
    report("direct command uncertainty is an explicit disposition", ConduitDirectCommandPhase.unknown.isTerminal)
}
