import Foundation

/// Deterministic, dependency-free Markdown projection for Conduit's read-only
/// reader. It is intentionally not a Markdown editing or round-tripping AST.
/// The source string remains authoritative.
public enum MainframeMarkdownParser {
    public static func parse(_ source: String) -> MainframeMarkdownDocument {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let frontmatterResult = parseFrontmatter(lines)
        let bodyStart = frontmatterResult.bodyStart
        let links = parseLinks(lines: lines, startingAt: bodyStart)

        var blocks: [MainframeMarkdownBlock] = []
        var headings: [MainframeMarkdownHeading] = []
        var headingCounts: [String: Int] = [:]
        var index = bodyStart

        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                index += 1
                continue
            }

            if let fence = fenceMarker(line) {
                let language = fence.language
                var captured: [String] = []
                index += 1
                while index < lines.count {
                    if closesFence(lines[index], marker: fence.marker) {
                        index += 1
                        break
                    }
                    captured.append(lines[index])
                    index += 1
                }
                blocks.append(.fencedCode(language: language, text: captured.joined(separator: "\n")))
                continue
            }

            if let heading = heading(from: line, lineNumber: index + 1, counts: &headingCounts) {
                headings.append(heading)
                blocks.append(.heading(heading))
                index += 1
                continue
            }

            if isHorizontalRule(line) {
                blocks.append(.horizontalRule)
                index += 1
                continue
            }

            if isTableHeader(at: index, lines: lines) {
                let headers = tableCells(lines[index])
                index += 2
                var rows: [[String]] = []
                while index < lines.count {
                    let candidate = lines[index]
                    guard candidate.contains("|"), !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
                    rows.append(tableCells(candidate))
                    index += 1
                }
                blocks.append(.table(MainframeMarkdownTable(headers: headers, rows: rows)))
                continue
            }

            if isBlockquote(line) {
                var quote: [String] = []
                while index < lines.count, isBlockquote(lines[index]) {
                    quote.append(stripBlockquote(lines[index]))
                    index += 1
                }
                blocks.append(.blockquote(quote.joined(separator: "\n")))
                continue
            }

            if unorderedListItem(line) != nil {
                var items: [String] = []
                while index < lines.count, let item = unorderedListItem(lines[index]) {
                    items.append(item)
                    index += 1
                }
                blocks.append(.unorderedList(items))
                continue
            }

            if orderedListItem(line) != nil {
                var items: [String] = []
                while index < lines.count, let item = orderedListItem(lines[index]) {
                    items.append(item)
                    index += 1
                }
                blocks.append(.orderedList(items))
                continue
            }

            var paragraph: [String] = [line]
            index += 1
            while index < lines.count {
                let candidate = lines[index]
                if candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
                if startsBlock(at: index, lines: lines) { break }
                paragraph.append(candidate)
                index += 1
            }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
        }

        return MainframeMarkdownDocument(
            source: normalized,
            frontmatter: frontmatterResult.values,
            blocks: blocks,
            headings: headings,
            links: links
        )
    }

    public static func anchorID(for heading: String) -> String {
        let lowered = heading.lowercased()
        var output = ""
        var previousHyphen = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                output.unicodeScalars.append(scalar)
                previousHyphen = false
            } else if scalar == "-" || CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !output.isEmpty && !previousHyphen {
                    output.append("-")
                    previousHyphen = true
                }
            }
        }
        while output.hasSuffix("-") { output.removeLast() }
        return output.isEmpty ? "section" : output
    }

    private static func parseFrontmatter(_ lines: [String]) -> (values: [String: String], bodyStart: Int) {
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            return ([:], 0)
        }
        guard let close = lines.indices.dropFirst().first(where: {
            lines[$0].trimmingCharacters(in: .whitespacesAndNewlines) == "---"
        }) else {
            return ([:], 0)
        }
        var values: [String: String] = [:]
        for line in lines[1..<close] {
            guard line.first?.isWhitespace != true, let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            let raw = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, values[key] == nil else { continue }
            values[key] = stripQuotes(raw)
        }
        return (values, min(close + 1, lines.count))
    }

    private static func parseLinks(lines: [String], startingAt start: Int) -> [MainframeMarkdownLink] {
        guard let regex = try? NSRegularExpression(pattern: #"(!?)\[([^\]]*)\]\(([^)]+)\)"#) else { return [] }
        var result: [MainframeMarkdownLink] = []
        var sequence = 0
        var insideFence: String?

        for index in start..<lines.count {
            let line = lines[index]
            if let fence = fenceMarker(line) {
                if insideFence == nil { insideFence = fence.marker }
                else if closesFence(line, marker: insideFence!) { insideFence = nil }
                continue
            }
            if insideFence != nil { continue }

            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            for match in regex.matches(in: line, range: range) {
                guard let imageRange = Range(match.range(at: 1), in: line),
                      let labelRange = Range(match.range(at: 2), in: line),
                      let targetRange = Range(match.range(at: 3), in: line) else { continue }
                sequence += 1
                let rawTarget = String(line[targetRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                result.append(MainframeMarkdownLink(
                    id: "L\(index + 1)-\(sequence)",
                    label: String(line[labelRange]),
                    target: linkDestination(from: rawTarget),
                    line: index + 1,
                    isImage: !String(line[imageRange]).isEmpty
                ))
            }
        }
        return result
    }

    private static func linkDestination(from raw: String) -> String {
        if raw.hasPrefix("<"), let closing = raw.firstIndex(of: ">") {
            return String(raw[raw.index(after: raw.startIndex)..<closing])
        }
        var escaped = false
        var output = ""
        for character in raw {
            if character == "\\" && !escaped {
                escaped = true
                output.append(character)
                continue
            }
            if character.isWhitespace && !escaped { break }
            output.append(character)
            escaped = false
        }
        return output
    }

    private static func stripQuotes(_ raw: String) -> String {
        guard raw.count >= 2 else { return raw }
        if (raw.hasPrefix("\"") && raw.hasSuffix("\"")) || (raw.hasPrefix("'") && raw.hasSuffix("'")) {
            return String(raw.dropFirst().dropLast())
        }
        return raw
    }

    private static func heading(
        from line: String,
        lineNumber: Int,
        counts: inout [String: Int]
    ) -> MainframeMarkdownHeading? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let hashes = trimmed.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count) else { return nil }
        let after = trimmed.dropFirst(hashes.count)
        guard after.first?.isWhitespace == true else { return nil }
        var text = after.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let base = anchorID(for: text)
        let count = (counts[base] ?? 0) + 1
        counts[base] = count
        let id = count == 1 ? base : "\(base)-\(count)"
        return MainframeMarkdownHeading(id: id, level: hashes.count, text: text, line: lineNumber)
    }

    private static func fenceMarker(_ line: String) -> (marker: String, language: String?)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let marker: String
        if trimmed.hasPrefix("```") { marker = "```" }
        else if trimmed.hasPrefix("~~~") { marker = "~~~" }
        else { return nil }
        let suffix = String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        return (marker, suffix.isEmpty ? nil : suffix)
    }

    private static func closesFence(_ line: String, marker: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix(marker)
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        let stripped = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3, let first = stripped.first, ["-", "*", "_"].contains(first) else { return false }
        return stripped.allSatisfy { $0 == first }
    }

    private static func isTableHeader(at index: Int, lines: [String]) -> Bool {
        guard index + 1 < lines.count, lines[index].contains("|") else { return false }
        let delimiter = tableCells(lines[index + 1])
        guard !delimiter.isEmpty else { return false }
        return delimiter.allSatisfy { cell in
            let stripped = cell.trimmingCharacters(in: .whitespaces)
            let core = stripped.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return core.count >= 3 && core.allSatisfy { $0 == "-" }
        }
    }

    private static func tableCells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.split(separator: "|", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    private static func isBlockquote(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix(">")
    }

    private static func stripBlockquote(_ line: String) -> String {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(">") else { return line }
        trimmed.removeFirst()
        if trimmed.hasPrefix(" ") { trimmed.removeFirst() }
        return trimmed
    }

    private static func unorderedListItem(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, let first = trimmed.first, ["-", "*", "+"].contains(first) else { return nil }
        let next = trimmed.index(after: trimmed.startIndex)
        guard next < trimmed.endIndex, trimmed[next].isWhitespace else { return nil }
        return String(trimmed[trimmed.index(after: next)...]).trimmingCharacters(in: .whitespaces)
    }

    private static func orderedListItem(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let delimiter = trimmed.firstIndex(where: { $0 == "." || $0 == ")" }) else { return nil }
        let number = trimmed[..<delimiter]
        guard !number.isEmpty, number.allSatisfy(\.isNumber) else { return nil }
        let after = trimmed.index(after: delimiter)
        guard after < trimmed.endIndex, trimmed[after].isWhitespace else { return nil }
        return String(trimmed[trimmed.index(after: after)...]).trimmingCharacters(in: .whitespaces)
    }

    private static func startsBlock(at index: Int, lines: [String]) -> Bool {
        let line = lines[index]
        if fenceMarker(line) != nil { return true }
        var counts: [String: Int] = [:]
        if heading(from: line, lineNumber: index + 1, counts: &counts) != nil { return true }
        if isHorizontalRule(line) || isBlockquote(line) { return true }
        if unorderedListItem(line) != nil || orderedListItem(line) != nil { return true }
        return isTableHeader(at: index, lines: lines)
    }
}
