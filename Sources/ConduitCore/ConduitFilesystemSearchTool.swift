import Foundation
import CryptoKit

/// Bounded, literal observations of ordinary UTF-8 files in one resolved project.
/// The caller supplies an already-authorized root; no request can nominate a root.
public enum ConduitFilesystemSearchTool {
    public static let name = "conduit_search_files"
    public static let maximumResults = 200
    public static let maximumEntries = 5_000
    public static let maximumFiles = 1_000
    public static let maximumFileBytes = 512_000
    public static let maximumTotalBytes = 8_388_608
    public static let maximumDepth = 32
    public static let maximumQueryBytes = 256
    public static let maximumSnippetBytes = 512

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
        var payload: [String: Any] = [
            "schema_version": "conduit-filesystem-search/v1",
            "authority": "filesystem_observation",
            "verification": "unverified_contents",
            "root_boundary": "resolved_project",
            "observed_at": ISO8601DateFormatter().string(from: Date()),
            "match_semantics": "case-sensitive literal UTF-8 bytes; one result per matching LF-delimited line",
            "consistency": "per-file metadata checks; no cross-file snapshot or transaction",
        ]
        func failure(_ status: String, _ message: String) -> [String: Any] {
            payload["status"] = status
            payload["error"] = message
            return payload
        }
        guard case .object(let fields) = arguments,
              Set(fields.keys).isSubset(of: [
                "project_slug", "path", "query", "max_results", "max_entries",
                "max_files", "max_file_bytes", "max_total_bytes", "max_depth",
              ]),
              let project = fields["project_slug"]?.stringValue,
              !project.isEmpty, project.utf8.count <= 128, !project.utf8.contains(0),
              let query = fields["query"]?.stringValue,
              !query.isEmpty, query.utf8.count <= maximumQueryBytes,
              !query.utf8.contains(where: { $0 == 0 || $0 == 10 || $0 == 13 }),
              fields["path"] == nil || fields["path"]?.stringValue != nil
        else {
            return failure("invalid_arguments", "Require an exact project_slug and a nonempty single-line literal query of at most 256 UTF-8 bytes; no extra fields or root override.")
        }
        let path = fields["path"]?.stringValue ?? "."
        guard !path.utf8.contains(0), path.utf8.count <= 4096 else {
            return failure("invalid_arguments", "The project-relative path is invalid or too long.")
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"), !parts.contains("..") else {
            return failure("outside_root", "Only an exact project-relative directory is accepted.")
        }
        let relativePath = path == "." ? "" : path
        guard relativePath.isEmpty || !parts.contains(where: { $0.isEmpty || $0 == "." }) else {
            return failure("invalid_arguments", "Use a literal directory path without empty or dot components.")
        }
        guard !parts.contains(where: { MainframeExplorerScanner.defaultIgnoredNames.contains(String($0)) }) else {
            return failure("excluded_path", "The directory is excluded by Explorer policy.")
        }
        func bound(_ key: String, default fallback: Int, maximum: Int, minimum: Int = 1) -> Int? {
            guard let value = fields[key] else { return fallback }
            guard case .number(let number) = value, number.isFinite,
                  number >= Double(minimum), number <= Double(maximum),
                  number.rounded() == number else { return nil }
            return Int(number)
        }
        guard let maxResults = bound("max_results", default: 50, maximum: maximumResults),
              let maxEntries = bound("max_entries", default: 1_000, maximum: maximumEntries),
              let maxFiles = bound("max_files", default: 200, maximum: maximumFiles),
              let maxFileBytes = bound("max_file_bytes", default: 128_000, maximum: maximumFileBytes),
              let maxTotalBytes = bound("max_total_bytes", default: 1_048_576, maximum: maximumTotalBytes, minimum: 2),
              let maxDepth = bound("max_depth", default: 8, maximum: maximumDepth, minimum: 0)
        else {
            return failure("invalid_arguments", "Search bounds must be integers within the published limits.")
        }
        payload["project_slug"] = project
        payload["path"] = relativePath
        payload["query"] = query
        payload["limits"] = [
            "max_results": maxResults, "max_entries": maxEntries,
            "max_files": maxFiles, "max_file_bytes": maxFileBytes,
            "max_total_bytes": maxTotalBytes, "max_depth": maxDepth,
        ]
        guard let root else {
            return failure("project_unavailable", "The exact project is unavailable, ambiguous, outside the authorized root, or not authorized.")
        }

        let scanner = MainframeExplorerScanner()
        let start = relativePath.isEmpty ? root : root.appendingPathComponent(relativePath)
        do {
            let facts = try scanner.fileFacts(root: root, item: start)
            guard facts.kind == .directory else {
                return failure(facts.kind == .symbolicLink ? "symlink_traversal" : "not_directory", "Search starts from an ordinary directory; links are never followed.")
            }
        } catch {
            return failure(status(for: error), error.localizedDescription)
        }

        var directories: [(url: URL, depth: Int)] = [(start, 0)]
        var directoryIndex = 0
        var entriesVisited = 0
        var filesConsidered = 0
        var filesRead = 0
        var readBudgetCharged = 0
        var sourceBytesRead = 0
        var matches: [[String: Any]] = []
        var skipped: [String: Int] = [:]
        var partialReasons = Set<String>()
        var stopped = false
        let needle = Data(query.utf8)

        func skip(_ reason: String, makesPartial: Bool) {
            skipped[reason, default: 0] += 1
            if makesPartial { partialReasons.insert(reason) }
        }
        while directoryIndex < directories.count && !stopped {
            guard entriesVisited < maxEntries else {
                partialReasons.insert("entry_limit")
                break
            }
            let directory = directories[directoryIndex]
            directoryIndex += 1
            let snapshot: MainframeExplorerDirectorySnapshot
            do {
                snapshot = try scanner.directorySnapshot(
                    root: root, directory: directory.url, maxEntries: maxEntries - entriesVisited
                )
            } catch {
                skip(status(for: error), makesPartial: true)
                continue
            }
            if snapshot.truncated { partialReasons.insert("entry_limit") }
            for entry in snapshot.entries {
                entriesVisited += 1
                if entry.facts.kind == .directory {
                    if directory.depth < maxDepth {
                        directories.append((entry.node.url, directory.depth + 1))
                    } else {
                        skip("depth_limit", makesPartial: true)
                    }
                    continue
                }
                guard entry.facts.isRegularFile, entry.facts.kind != .symbolicLink else {
                    skip(entry.facts.kind == .symbolicLink ? "symbolic_link" : "non_regular_file", makesPartial: false)
                    continue
                }
                guard filesConsidered < maxFiles else {
                    partialReasons.insert("file_limit")
                    stopped = true
                    break
                }
                filesConsidered += 1
                guard entry.facts.byteCount <= maxFileBytes else {
                    skip("oversized", makesPartial: true)
                    continue
                }
                let remaining = maxTotalBytes - readBudgetCharged
                guard remaining > 1, entry.facts.byteCount < remaining else {
                    skip("byte_limit", makesPartial: true)
                    continue
                }
                let readLimit = min(maxFileBytes, remaining - 1)
                // Reserve the complete bounded read plus its lookahead. On an
                // unsuccessful read retain that charge because consumed bytes
                // are unknown; successful snapshots refund unused capacity.
                let reservation = readLimit + 1
                readBudgetCharged += reservation
                let source: MainframeExplorerTextSnapshot
                do {
                    source = try scanner.readUTF8Snapshot(
                        root: root, file: entry.node.url, maxBytes: readLimit, ordinaryTextOnly: true
                    )
                } catch {
                    let reason = status(for: error)
                    skip(reason, makesPartial: reason != "unsupported" && reason != "symlink_traversal")
                    continue
                }
                let bytes = source.bytes
                readBudgetCharged -= reservation - bytes.count
                sourceBytesRead += bytes.count
                filesRead += 1
                let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                var lineStart = 0
                var lineNumber = 1
                for lineSlice in bytes.split(separator: 10, omittingEmptySubsequences: false) {
                    var line = Data(lineSlice)
                    if line.last == 13 { line.removeLast() }
                    if let range = line.range(of: needle) {
                        if matches.count == maxResults {
                            partialReasons.insert("result_limit")
                            stopped = true
                            break
                        }
                        let excerpt = snippet(line, match: range)
                        matches.append([
                            "path": source.facts.relativePath,
                            "line": lineNumber,
                            "column_bytes": range.lowerBound + 1,
                            "byte_offset": lineStart + range.lowerBound,
                            "text": excerpt.text,
                            "text_truncated": excerpt.truncated,
                            "sha256": digest,
                            "size_bytes": bytes.count,
                        ])
                    }
                    lineStart += lineSlice.count + 1
                    lineNumber += 1
                }
                if stopped { break }
            }
        }
        payload["status"] = partialReasons.isEmpty ? "ok" : "partial"
        payload["matches"] = matches
        payload["returned"] = matches.count
        payload["truncated"] = !partialReasons.isEmpty
        payload["completeness"] = partialReasons.isEmpty ? "complete_traversal_within_policy" : "partial_traversal"
        payload["partial_reasons"] = partialReasons.sorted()
        payload["skipped"] = skipped
        payload["entries_visited"] = entriesVisited
        payload["files_considered"] = filesConsidered
        payload["files_read"] = filesRead
        payload["source_bytes_read"] = sourceBytesRead
        payload["read_budget_charged_bytes"] = readBudgetCharged
        return payload
    }

    private static func snippet(_ line: Data, match: Range<Data.Index>) -> (text: String, truncated: Bool) {
        var start = max(0, match.lowerBound - 80)
        while start > 0 && line[start] & 0xC0 == 0x80 { start -= 1 }
        var end = min(line.count, start + maximumSnippetBytes)
        while end < line.count && end > start && line[end] & 0xC0 == 0x80 { end -= 1 }
        let data = line.subdata(in: start..<end)
        return (String(decoding: data, as: UTF8.self), start != 0 || end != line.count)
    }

    private static func status(for error: Error) -> String {
        guard let error = error as? MainframeExplorerError else { return "io_error" }
        switch error {
        case .unsafePath: return "outside_root"
        case .symbolicLinkTraversal: return "symlink_traversal"
        case .missingRoot: return "project_unavailable"
        case .missingPath: return "missing"
        case .inaccessiblePath: return "inaccessible"
        case .notDirectory: return "not_directory"
        case .fileTooLarge: return "oversized"
        case .changedDuringRead: return "changed_during_read"
        case .notFile, .unsupportedFile, .nonUTF8, .notSymbolicLink: return "unsupported"
        }
    }
}
