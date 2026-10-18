import ConduitCore
import CryptoKit
import Foundation

func runDirectFilesystemSelfChecks(_ report: (String, Bool) -> Void) {
    let files = FileManager.default
    let base = files.temporaryDirectory.appendingPathComponent("conduit-filesystem-selfcheck-\(UUID().uuidString)")
    let root = base.appendingPathComponent("project")
    let stateParent = base.appendingPathComponent("application-state")
    let receipts = stateParent.appendingPathComponent("receipts")
    defer { try? files.removeItem(at: base) }

    func hash(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    do {
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        try files.createDirectory(at: stateParent, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.txt")
        let sourceBytes = Data([0xEF, 0xBB, 0xBF]) + Data("a.b\r\naXb\r\na.b\r\n".utf8)
        try sourceBytes.write(to: source)
        func search(_ maximumResults: Int) -> [String: Any] {
            ConduitFilesystemSearchTool.observe(arguments: .object([
                "project_slug": .string("fixture"), "query": .string("a.b"),
                "max_results": .number(Double(maximumResults)), "max_entries": .number(4),
                "max_files": .number(2), "max_file_bytes": .number(128),
                "max_total_bytes": .number(256), "max_depth": .number(0),
            ]), root: root)
        }
        let found = search(3)
        let matches = found["matches"] as? [[String: Any]] ?? []
        report("direct filesystem search treats regex punctuation as literal bytes",
               found["status"] as? String == "ok"
                && matches.compactMap { $0["line"] as? Int } == [1, 3])
        report("direct filesystem search retains BOM byte offsets and exact raw hash",
               matches.count == 2 && matches.first?["byte_offset"] as? Int == 3
                && matches.allSatisfy { $0["sha256"] as? String == hash(sourceBytes)
                    && $0["path"] as? String == "source.txt" })
        let partial = search(1)
        report("direct filesystem search reports bounded partial results",
               partial["status"] as? String == "partial"
                && partial["returned"] as? Int == 1 && partial["truncated"] as? Bool == true)
        report("direct filesystem search preserves source bytes", try Data(contentsOf: source) == sourceBytes)

        let service = ConduitFilesystemMutationService(receiptDirectory: receipts)
        var admissions = 0
        let gate: () -> [String: Any]? = { admissions += 1; return nil }
        let invalid = service.mutate(arguments: .object([
            "operation_id": .string("invalid"), "project_slug": .string("fixture"),
            "path": .string("../outside.txt"), "text": .string("unused"),
            "expected_absent": .bool(true),
        ]), root: root, admitWrite: gate)
        report("direct filesystem invalid write refuses the outside path", invalid["status"] as? String == "outside_root")
        report("direct filesystem invalid write consumes no admission or receipt storage",
               admissions == 0 && !files.fileExists(atPath: receipts.path)
                && !files.fileExists(atPath: base.appendingPathComponent("outside.txt").path))

        let text = "Café\r\n雪\n"
        let bytes = Data(text.utf8)
        let target = root.appendingPathComponent("created.txt")
        let create: CodexJSON = .object([
            "operation_id": .string("create"), "project_slug": .string("fixture"),
            "path": .string("created.txt"), "text": .string(text), "expected_absent": .bool(true),
        ])
        let created = service.mutate(arguments: create, root: root, admitWrite: gate)
        report("direct filesystem creates an ordinary UTF-8 file after one admission",
               created["status"] as? String == "succeeded"
                && created["operation"] as? String == "create" && admissions == 1)
        report("direct filesystem create retains exact bytes and observed hash",
               try Data(contentsOf: target) == bytes
                && (created["after"] as? [String: Any])?["sha256"] as? String == hash(bytes))

        let externalBytes = Data("external later edit\r\n".utf8)
        try externalBytes.write(to: target)
        let restarted = ConduitFilesystemMutationService(receiptDirectory: receipts)
        let replay = restarted.mutate(arguments: create, root: root, admitWrite: gate)
        report("direct filesystem exact retry returns its durable historical receipt",
               replay["status"] as? String == "succeeded" && replay["replayed"] as? Bool == true
                && replay["current_call_mutation_observed"] as? Bool == false)
        report("direct filesystem replay preserves later bytes without another admission",
               try Data(contentsOf: target) == externalBytes && admissions == 1)

        let stale = restarted.mutate(arguments: .object([
            "operation_id": .string("stale"), "project_slug": .string("fixture"),
            "path": .string("created.txt"), "text": .string("must not replace"),
            "expected_sha256": .string(hash(bytes)),
        ]), root: root, admitWrite: gate)
        report("direct filesystem stale expected hash refuses replacement", stale["status"] as? String == "precondition_failed")
        report("direct filesystem stale request preserves external bytes without admission",
               try Data(contentsOf: target) == externalBytes && admissions == 1)
    } catch {
        report("direct filesystem disposable fixture completed without I/O failure: \(error.localizedDescription)", false)
    }
}
