import Foundation

/// Separates MindGraph's progress logging from its JSON payload.
///
/// The query CLI writes lines like
/// `08:29:04 INFO    mindgraph | Loading embedding model ...` to the same
/// stream as its results, so a caller that parses from byte 0 fails. The MCP
/// surface used to forward the whole thing as one `output` string and leave
/// every consumer to strip the preamble itself.
public enum MindGraphOutput {
    /// The payload, starting at the first line that opens a JSON array or
    /// object. Line-anchored rather than character-anchored, so a bracket
    /// inside a log message cannot be mistaken for the start of results.
    public static func jsonPayload(in output: String) -> String? {
        let lines = output.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("[") || trimmed.hasPrefix("{")
        }) else { return nil }
        let payload = lines[start...]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return payload.isEmpty ? nil : payload
    }

    /// Fields worth forwarding to an external orchestrator.
    ///
    /// Deliberately an allowlist, not a denylist. MindGraph rows carry
    /// retrieval mechanics and `source_root`, which is an absolute path on
    /// this machine. Logical index/source identity is retained separately from
    /// the selected scope alias so clients can inspect the nominated file. A denylist
    /// would forward the next path-bearing field somebody adds upstream.
    ///
    /// `provenance_warning`, `query_scope_warning`, `trust_profile`, and
    /// `weak_fit` are kept: they are how a nomination admits it is weak, and
    /// dropping them would make results look more confident than they are.
    public static let forwardedFields: [String] = [
        "path",
        "display_path",
        "source_path",
        "doc_id",
        "chunk_index",
        "index_id",
        "namespace",
        "content_hash",
        "title",
        "chunk_text",
        "rrf_score",
        "doc_type",
        "domain",
        "status",
        "trust_profile",
        "citation_class",
        "weak_fit",
        "provenance_warning",
        "query_scope_warning",
    ]

    /// Splits nominations into ones a caller may cite and ones it must not.
    ///
    /// Retrieval ranking is trust-blind. A fabricated source is written to be
    /// on topic, so it scores like any other and can take the top rank —
    /// observed live on 2026-08-20, where a quarantined document from the
    /// fabricated-citations incident was the highest-scoring hit for a
    /// research question. Forwarding one ranked list with a prose warning
    /// attached leaves the whole control resting on the caller reading English
    /// and choosing to obey it.
    ///
    /// Order is preserved inside each bucket and nothing is dropped, so this
    /// separates without re-ranking or hiding. `unverified` stays with the
    /// usable results: it means "nomination, not evidence", which is a caveat
    /// on use rather than a bar on it.
    public static func partitionByCitation(
        _ rows: [[String: Any]]
    ) -> (citable: [[String: Any]], notCitable: [[String: Any]]) {
        var citable: [[String: Any]] = []
        var notCitable: [[String: Any]] = []
        for row in rows {
            if (row["citation_class"] as? String) == "not_citable" {
                notCitable.append(row)
            } else {
                citable.append(row)
            }
        }
        return (citable, notCitable)
    }

    /// Counts by citation class, always reporting all three keys.
    public static func citationCounts(_ rows: [[String: Any]]) -> [String: Int] {
        var counts = ["citable": 0, "unverified": 0, "not_citable": 0]
        for row in rows {
            let key = (row["citation_class"] as? String) ?? "citable"
            counts[key, default: 0] += 1
        }
        return counts
    }

    /// One result reduced to what a caller can act on, with the matched text
    /// bounded. Absent and null fields are omitted rather than sent as nulls.
    public static func projectResult(
        _ row: [String: Any],
        textLimit: Int = 600
    ) -> [String: Any] {
        var projected: [String: Any] = [:]
        for key in forwardedFields {
            guard let value = row[key], !(value is NSNull) else { continue }
            if key == "chunk_text", let text = value as? String {
                projected[key] = String(text.prefix(textLimit))
                if text.count > textLimit {
                    projected["chunk_text_truncated"] = true
                }
                continue
            }
            projected[key] = value
        }
        return projected
    }

    /// Whatever MindGraph logged before the payload. Kept so a diagnostic is
    /// still available without gluing it onto the results.
    public static func logPreamble(in output: String) -> String {
        let lines = output.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("[") || trimmed.hasPrefix("{")
        }) else {
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return lines[..<start]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
