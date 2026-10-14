import Foundation

/// One bounded observation surface over Explorer's live filesystem authority.
/// This type has no task, runtime, provider, index, or persistence dependency.
public enum ConduitFilesystemReadTool {
    public static let name = "conduit_read_filesystem"
    public static let maximumEntries = 500
    public static let maximumBytes = 512_000

    public static func call(arguments: CodexJSON, root: URL?) -> [String: Any] {
        let payload = observe(arguments: arguments, root: root)
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return [
            "isError": payload["error"] != nil,
            "content": [["type": "text", "text": data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"]],
            "structuredContent": payload,
        ]
    }

    public static func observe(arguments: CodexJSON, root: URL?) -> [String: Any] {
        var result: [String: Any] = [
            "schema_version": "conduit-filesystem-read/v1",
            "authority": "filesystem_observation",
            "verification": "unverified_contents",
            "root_boundary": "configured_mainframe",
            "observed_at": timestamp(Date()),
        ]
        func failure(_ status: String, _ message: String) -> [String: Any] {
            result["status"] = status
            result["error"] = message
            return result
        }
        guard case .object(let fields) = arguments,
              Set(fields.keys).isSubset(of: ["operation", "path", "max_entries", "max_bytes"]),
              let operation = fields["operation"]?.stringValue,
              ["list", "read", "stat"].contains(operation),
              let path = fields["path"]?.stringValue,
              !path.utf8.contains(0), path.utf8.count <= 4096 else {
            return failure("invalid_arguments", "Require operation list/read/stat and an exact root-relative path; no root override or extra fields.")
        }
        result["operation"] = operation
        result["path"] = path
        // Absolute paths and parent components never nominate another root.
        // Dot alone names the selected root; filenames are not trimmed/decoded.
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"), !parts.contains("..") else {
            return failure("outside_root", "Only paths relative to the configured MainFrame root are allowed.")
        }
        let relativePath = path == "." ? "" : path
        guard relativePath.isEmpty || !parts.contains(where: { $0.isEmpty || $0 == "." }) else {
            return failure("invalid_arguments", "Use the exact relative path without empty or dot components.")
        }
        guard !parts.contains(where: { MainframeExplorerScanner.defaultIgnoredNames.contains(String($0)) }) else {
            return failure("excluded_path", "The path is excluded by Explorer's default policy.")
        }
        func boundedInteger(_ key: String, default fallback: Int, maximum: Int) -> Int? {
            guard let value = fields[key] else { return fallback }
            guard case .number(let number) = value, number.isFinite,
                  number >= 1, number <= Double(maximum), number.rounded() == number else { return nil }
            return Int(number)
        }
        guard let entries = boundedInteger("max_entries", default: 200, maximum: maximumEntries),
              let bytes = boundedInteger("max_bytes", default: 128_000, maximum: maximumBytes),
              (operation == "list" || fields["max_entries"] == nil),
              (operation == "read" || fields["max_bytes"] == nil) else {
            return failure("invalid_arguments", "Use operation-specific integer bounds: max_entries 1...500 for list; max_bytes 1...512000 for read.")
        }
        guard let root else { return failure("root_unavailable", "Conduit's authorized MainFrame root is not ready.") }
        let item = relativePath.isEmpty ? root : root.appendingPathComponent(relativePath)
        let scanner = MainframeExplorerScanner()
        do {
            let facts = try scanner.fileFacts(root: root, item: item)
            result["path"] = facts.relativePath
            result["metadata"] = metadata(facts)
            switch operation {
            case "list":
                let snapshot = try scanner.directorySnapshot(root: root, directory: item, maxEntries: entries)
                result["entries"] = snapshot.entries.map { metadata($0.facts) }
                result["returned"] = snapshot.entries.count
                result["max_entries"] = entries
                result["truncated"] = snapshot.truncated
                result["completeness"] = snapshot.truncated ? "bounded_subset" : "complete_at_observation"
            case "read":
                result["max_bytes"] = bytes
                let snapshot = try scanner.readUTF8Snapshot(root: root, file: item, maxBytes: bytes, ordinaryTextOnly: true)
                result["metadata"] = metadata(snapshot.facts)
                result["text"] = snapshot.text
                result["encoding"] = "utf-8"
                result["truncated"] = false
                result["read_consistency"] = "metadata_unchanged_during_read"
            default:
                break
            }
            result["status"] = facts.kind == .symbolicLink ? "symbolic_link" : "ok"
            return result
        } catch let error as MainframeExplorerError {
            let status: String
            switch error {
            case .unsafePath: status = "outside_root"
            case .symbolicLinkTraversal: status = "symlink_traversal"
            case .missingRoot: status = "root_unavailable"
            case .missingPath: status = "missing"
            case .inaccessiblePath: status = "inaccessible"
            case .notDirectory: status = "not_directory"
            case .notFile, .unsupportedFile, .nonUTF8: status = "unsupported"
            case .fileTooLarge: status = "oversized"
            case .changedDuringRead: status = "changed_during_read"
            case .notSymbolicLink: status = "unsupported"
            }
            return failure(status, error.localizedDescription)
        } catch {
            return failure("io_error", error.localizedDescription)
        }
    }

    private static func metadata(_ facts: MainframeExplorerFileFacts) -> [String: Any] {
        [
            "path": facts.relativePath,
            "kind": facts.kind.rawValue,
            "size_bytes": facts.byteCount,
            "modified_at": timestamp(facts.modifiedAt),
            "regular_file": facts.isRegularFile,
            "freshness": "observed_on_disk",
        ]
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
