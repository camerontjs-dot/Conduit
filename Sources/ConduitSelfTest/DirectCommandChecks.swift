import ConduitCore
import Foundation

func runDirectCommandSelfChecks(_ report: (String, Bool) -> Void) {
    let guidance = ConduitSessionToolCatalog.clientInstructions
    report("direct workflow guidance keeps routine work in the current conversation", guidance.contains("before deploying another agent"))
    report("direct workflow guidance preserves the unavailable authority boundary", guidance.contains("do not bypass it through a Shell task"))
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
    let longRequest: CodexJSON = .object([
        "operation_id": .string("long-selfcheck"), "project_slug": .string("fixture"),
        "argv": .array([.string("/usr/bin/printf"), .string("unused")]),
        "timeout_ms": .number(600_000), "max_tail_bytes": .number(16_384),
    ])
    let longResult = ConduitDirectCommandTool.perform(operation: "execute", arguments: longRequest,
                                                      projectRoot: base, service: service)
    report("long command budgets do not grant production authority", longResult["status"] as? String == "execution_authority_unavailable")
    let invalidPage = ConduitDirectCommandTool.perform(operation: "status", arguments: .object([
        "operation_id": .string("selfcheck"), "project_slug": .string("fixture"),
        "stdout_offset": .number(1e100),
    ]), projectRoot: base, service: service)
    report("command output offsets refuse unsafe numeric conversion", invalidPage["status"] as? String == "invalid_arguments")
    let helperOverride = ConduitDirectCommandTool.perform(operation: "execute", arguments: .object([
        "operation_id": .string("helper-override"), "project_slug": .string("fixture"),
        "argv": .array([.string("/usr/bin/printf"), .string("unused")]),
        "supervisor_executable": .string("/not-an-admitted-helper"),
    ]), projectRoot: base, service: service)
    report("caller fields cannot select the internal supervisor", helperOverride["status"] as? String == "invalid_arguments")
    report("supervisor override refusal creates no storage", !FileManager.default.fileExists(atPath: base.path))
    do {
        let store = base.appendingPathComponent("receipts")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        for suffix in ["reserved", "launch-claim"] {
            let id = "missing-\(suffix)"
            let marker = store.appendingPathComponent("\(id).\(suffix)")
            let evidence = Data("ambiguous-attempt\n".utf8)
            try evidence.write(to: marker)
            let reader = ConduitDirectCommandService(storeDirectory: store)
            let input: CodexJSON = .object([
                "operation_id": .string(id), "project_slug": .string("fixture"),
            ])
            let missing = ConduitDirectCommandTool.perform(operation: "status", arguments: input, projectRoot: base, service: reader)
            report("\(suffix)-only status reports missing outcome evidence", missing["status"] as? String == "operation_receipt_missing")
            let replayRequest = ConduitDirectCommandRequest(operationID: id, projectSlug: "fixture", argv: ["/usr/bin/printf", "unused"])
            do {
                _ = try reader.submit(replayRequest, projectRoot: base) { admissionCalls += 1 }
                report("\(suffix)-only attempt cannot be replayed", false)
            } catch {
                report("\(suffix)-only attempt cannot be replayed", (error as? ConduitDirectCommandError)?.code == "operation_receipt_missing")
            }
            report("\(suffix)-only observation preserves marker bytes", try Data(contentsOf: marker) == evidence)
            report("\(suffix)-only refusal consumes no write admission", admissionCalls == 0)
        }
        // Declared synthetic retained record; no helper or payload is started.
        let output: [String: Any] = ["bytes": "", "totalBytesObserved": 0, "reachedEOF": false]
        let inconsistent: [String: Any] = [
            "schemaVersion": "conduit-direct-command/v2",
            "request": ["operationID": "inconsistent-v2", "projectSlug": "fixture", "argv": ["/usr/bin/printf", "unused"],
                        "cwd": ".", "timeoutMS": 10_000, "maxOutputBytes": 128_000],
            "resolvedProjectRoot": base.path, "resolvedCwd": base.path,
            "projectRootIdentity": "synthetic", "cwdIdentity": "synthetic", "ownerInstanceID": "synthetic-former-owner",
            "phase": "exited", "transitions": [], "acceptedAt": 0, "stdout": output, "stderr": output,
            "directChildExitObserved": true, "processGroupAbsentObserved": true,
            "executionCapacityReleased": true, "idempotentReplay": false,
            "supervision": ["protocolVersion": "CDS1", "attemptNonce": "0123456789abcdef0123456789abcdef",
                            "helperIdentity": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                            "lastEventRevision": 5, "goCommitted": true, "rootExitObserved": true,
                            "controlClosed": true, "finalFrameObserved": true, "cleanupCause": 0,
                            "cleanupScope": "original_process_group", "descendantContainment": "not_provided"],
        ]
        let corruptBytes = try JSONSerialization.data(withJSONObject: inconsistent, options: [.sortedKeys])
        let corruptPath = store.appendingPathComponent("inconsistent-v2.json")
        try corruptBytes.write(to: corruptPath)
        let corruptStatus = ConduitDirectCommandTool.perform(operation: "status", arguments: .object([
            "operation_id": .string("inconsistent-v2"), "project_slug": .string("fixture"),
        ]), projectRoot: base, service: ConduitDirectCommandService(storeDirectory: store))
        report("v2 disk capacity acknowledgment is rejected as corrupt", corruptStatus["status"] as? String == "receipt_corrupt")
        report("v2 corrupt-capacity observation preserves receipt bytes", try Data(contentsOf: corruptPath) == corruptBytes)
    } catch { report("missing-outcome self-check fixture completed", false) }
}
