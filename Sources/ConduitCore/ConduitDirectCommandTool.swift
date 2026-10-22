import Foundation

/// Three catalog entries bind `operation` on the server, so status remains a
/// read-only tool and execute/cancel retain their separate write admission.
public enum ConduitDirectCommandTool {
    public static let executeName = "conduit_run_command"
    public static let statusName = "conduit_command_status"
    public static let cancelName = "conduit_cancel_command"
    public static let maximumPageBytes = 16_384

    public static func call(operation: String, arguments: CodexJSON, projectRoot: URL?,
                            service: ConduitDirectCommandService?,
                            admitWrite: (() throws -> Void)? = nil) -> [String: Any] {
        let payload = perform(operation: operation, arguments: arguments, projectRoot: projectRoot,
                              service: service, admitWrite: admitWrite)
        let bytes = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return [
            "isError": payload["error"] != nil,
            "content": [["type": "text", "text": bytes.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"]],
            "structuredContent": payload,
        ]
    }

    public static func perform(operation: String, arguments: CodexJSON, projectRoot: URL?,
                               service: ConduitDirectCommandService?,
                               admitWrite: (() throws -> Void)? = nil) -> [String: Any] {
        var payload: [String: Any] = [
            "schema_version": "conduit-direct-command/v1",
            "operation": operation,
            "authority": "direct_command_receipt",
            "verification": "observed_process_facts_only",
            "observed_at": timestamp(Date()),
            "execution_boundary": "native process; no OS confinement claim",
            "retry_guidance": "Reuse the same operation_id only with the same exact request. After an uncertain response, inspect status; never generate a new ID to retry unobserved execution.",
        ]
        do {
            let fields = try parse(arguments, operation: operation)
            let id = fields["operation_id"]!.stringValue!
            let project = fields["project_slug"]!.stringValue!
            payload["operation_id"] = id; payload["project_slug"] = project
            guard let projectRoot else {
                throw ConduitDirectCommandError(code: "project_unavailable", detail: "The exact project is unavailable, ambiguous or outside the caller's authorized project scope.")
            }
            guard let service else {
                throw ConduitDirectCommandError(code: "command_service_unavailable", detail: "The command receipt service is unavailable; no process was launched.")
            }
            let receipt: ConduitDirectCommandReceipt
            switch operation {
            case "execute":
                let argv = array(fields["argv"])!.map { $0.stringValue! }
                receipt = try service.submit(.init(
                    operationID: id, projectSlug: project, argv: argv,
                    cwd: fields["cwd"]?.stringValue ?? ".",
                    timeoutMS: integer(fields["timeout_ms"], default: 10_000),
                    maxOutputBytes: integer(fields["max_output_bytes"], default: 128_000),
                    maxTailBytes: fields["max_tail_bytes"].map { integer($0, default: 0) }
                ), projectRoot: projectRoot, admitWrite: admitWrite)
            case "status":
                receipt = try service.lookup(operationID: id, projectSlug: project, projectRoot: projectRoot)
            default:
                receipt = try service.cancel(operationID: id, projectSlug: project, projectRoot: projectRoot, admitWrite: admitWrite)
            }
            payload["status"] = receipt.phase.rawValue
            let paged = ["stdout_offset", "stderr_offset", "output_page_bytes"].contains { fields[$0] != nil }
            payload["receipt"] = try json(receipt, pageBytes: paged ? integer(fields["output_page_bytes"], default: 8_192) : nil,
                                          stdoutOffset: Int64(integer(fields["stdout_offset"], default: 0)),
                                          stderrOffset: Int64(integer(fields["stderr_offset"], default: 0)))
            // Nonzero exit, timeout and cancellation are actual command
            // outcomes, not transport failures that invite duplicate execution.
            return payload
        } catch let error as ConduitDirectCommandError {
            payload["status"] = error.code; payload["error"] = error.detail
            return payload
        } catch {
            payload["status"] = "command_observation_unavailable"
            payload["error"] = error.localizedDescription
            return payload
        }
    }

    private static func parse(_ arguments: CodexJSON, operation: String) throws -> [String: CodexJSON] {
        let common: Set<String> = ["operation_id", "project_slug"]
        let allowed: Set<String>
        switch operation {
        case "execute": allowed = common.union(["argv", "cwd", "timeout_ms", "max_output_bytes", "max_tail_bytes"])
        case "status": allowed = common.union(["stdout_offset", "stderr_offset", "output_page_bytes"])
        default: allowed = common
        }
        guard ["execute", "status", "cancel"].contains(operation),
              case .object(let fields) = arguments, Set(fields.keys).isSubset(of: allowed),
              let id = fields["operation_id"]?.stringValue, !id.isEmpty,
              let project = fields["project_slug"]?.stringValue, !project.isEmpty else {
            throw invalid()
        }
        if operation == "execute" {
            guard let argv = array(fields["argv"]), !argv.isEmpty,
                  argv.allSatisfy({ $0.stringValue != nil }),
                  fields["cwd"] == nil || fields["cwd"]?.stringValue != nil else { throw invalid() }
        }
        let bounds: [String: ClosedRange<Double>] = [
            "timeout_ms": 10...Double(ConduitDirectCommandService.maximumTimeoutMS),
            "max_output_bytes": 1...Double(ConduitDirectCommandService.maximumOutputBytes),
            "max_tail_bytes": 0...Double(ConduitDirectCommandService.maximumTailBytes),
            "stdout_offset": 0...9_007_199_254_740_991,
            "stderr_offset": 0...9_007_199_254_740_991,
            "output_page_bytes": 1...Double(maximumPageBytes),
        ]
        for (key, range) in bounds {
            if let value = fields[key] {
                guard case .number(let number) = value, number.isFinite,
                      range.contains(number), number.rounded() == number else { throw invalid() }
            }
        }
        return fields
    }

    private static func invalid() -> ConduitDirectCommandError {
        .init(code: "invalid_arguments", detail: "Use only the fields published for this exact command tool. A caller cannot select an operation, root, environment, shell mode, executable profile or authority override.")
    }

    private static func array(_ value: CodexJSON?) -> [CodexJSON]? {
        guard case .array(let values) = value else { return nil }
        return values
    }

    private static func integer(_ value: CodexJSON?, default fallback: Int) -> Int {
        guard case .number(let value) = value else { return fallback }
        return Int(value)
    }

    private static func json(_ receipt: ConduitDirectCommandReceipt, pageBytes: Int?,
                             stdoutOffset: Int64, stderrOffset: Int64) throws -> [String: Any] {
        func output(_ value: ConduitDirectCommandOutput, offset: Int64) throws -> [String: Any] {
            var result: [String: Any] = [
                "bytes_base64": value.bytes.base64EncodedString(),
                "retained_bytes": value.bytes.count, "total_bytes_observed": value.totalBytesObserved,
                "truncated": value.truncated, "reached_eof": value.reachedEOF,
                "retained_bytes_are_utf8_text": value.utf8Text != nil,
            ]
            if let text = value.utf8Text { result["text"] = text }
            // No paging arguments preserves the original prefix response. An
            // opted-in reader gets only one bounded page, never both buffers.
            guard let pageBytes else { return result }
            guard offset <= value.totalBytesObserved else {
                throw ConduitDirectCommandError(code: "output_offset_out_of_range", detail: "The requested byte offset is beyond this stream's observed end; no output or command was changed.")
            }
            let prefixEnd = Int64(value.bytes.count)
            let tail = value.tailBytes ?? Data()
            let tailStart = value.totalBytesObserved - Int64(tail.count)
            var ranges: [[String: Int64]] = []
            if prefixEnd > 0 { ranges.append(["start": 0, "end": prefixEnd]) }
            if !tail.isEmpty, value.totalBytesObserved > prefixEnd {
                ranges.append(["start": max(prefixEnd, tailStart), "end": value.totalBytesObserved])
            }
            var bytes = Data(), next = offset, status: String
            if offset < prefixEnd {
                bytes = Data(value.bytes.dropFirst(Int(offset)).prefix(pageBytes)); status = "data"
            } else if offset < tailStart {
                // Never silently jump a cursor across output that was not kept.
                status = "gap"; next = tailStart
                result["missing_range"] = ["start": offset, "end": tailStart]
            } else if offset < value.totalBytesObserved {
                bytes = Data(tail.dropFirst(Int(offset - tailStart)).prefix(pageBytes)); status = "data"
            } else {
                status = value.reachedEOF ? "end" : (receipt.phase.isTerminal ? "incomplete" : "pending")
            }
            if !bytes.isEmpty { next = offset + Int64(bytes.count) }
            let text = bytes.contains(0) ? nil : String(data: bytes, encoding: .utf8)
            result["text"] = text
            result["bytes_base64"] = bytes.base64EncodedString()
            result["retained_bytes_are_utf8_text"] = text != nil
            result["byte_offset"] = offset
            result["next_byte_offset"] = next
            result["returned_bytes"] = bytes.count
            result["page_status"] = status
            result["page_limited"] = status == "data" && next < value.totalBytesObserved
            result["available_ranges"] = ranges
            result["tail_retained_bytes"] = tail.count
            result["tail_start_offset"] = tailStart
            result["all_observed_bytes_retained"] = prefixEnd >= tailStart
            return result
        }
        var result: [String: Any] = [
            "operation_id": receipt.request.operationID, "project_slug": receipt.request.projectSlug,
            "argv": receipt.request.argv, "cwd": receipt.request.cwd,
            "resolved_project_root": receipt.resolvedProjectRoot, "resolved_cwd": receipt.resolvedCwd,
            "project_root_identity": receipt.projectRootIdentity, "cwd_identity": receipt.cwdIdentity,
            "owner_instance_id": receipt.ownerInstanceID,
            "timeout_ms": receipt.request.timeoutMS, "max_output_bytes_per_stream": receipt.request.maxOutputBytes,
            "phase": receipt.phase.rawValue, "accepted_at": timestamp(receipt.acceptedAt),
            "transitions": receipt.transitions.map { ["phase": $0.phase.rawValue, "at": timestamp($0.at)] },
            "stdout": try output(receipt.stdout, offset: stdoutOffset),
            "stderr": try output(receipt.stderr, offset: stderrOffset),
            "direct_child_exit_observed": receipt.directChildExitObserved,
            "process_group_absent_observed": receipt.processGroupAbsentObserved,
            "execution_capacity_released": receipt.executionCapacityReleased,
            "idempotent_replay": receipt.idempotentReplay,
            "descendant_containment": "not_enforced; descendants can leave the original process group",
        ]
        if let tailBytes = receipt.request.maxTailBytes { result["max_tail_bytes_per_stream"] = tailBytes }
        if let date = receipt.startedAt { result["started_at"] = timestamp(date) }
        if let date = receipt.endedAt { result["ended_at"] = timestamp(date) }
        if let pid = receipt.pid { result["pid"] = pid }
        if let group = receipt.processGroupID { result["process_group_id"] = group }
        if let code = receipt.exitCode { result["exit_code"] = code }
        if let signal = receipt.terminationSignal { result["termination_signal"] = signal }
        if let note = receipt.note { result["note"] = note }
        return result
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
