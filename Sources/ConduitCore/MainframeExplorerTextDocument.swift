import Foundation

public enum MainframeExplorerTextDocumentError: LocalizedError, Equatable {
    case readOnly(String)
    case tooManyMatches(Int)
    case emptyQuery

    public var errorDescription: String? {
        switch self {
        case .readOnly(let reason): return reason
        case .tooManyMatches(let limit): return "Replace was not applied: the file has more than \(limit) literal matches. Narrow the query."
        case .emptyQuery: return "Enter a nonempty literal search query."
        }
    }
}

public enum MainframeExplorerTextLineEnding: String, Equatable, Sendable {
    case lf = "LF"
    case crlf = "CRLF"
}

/// Eligible UTF-8 is edited as LF in memory and encoded with its original EOL
/// on explicit save. Unsupported encoding/EOL combinations remain read-only.
public struct MainframeExplorerTextDocument: Equatable, Sendable {
    public static let byteLimit = 2_000_000
    public static let replacementMatchLimit = 500
    public static let historyByteLimit = 4_000_000
    public static let historyEntryLimit = 40

    public let relativePath: String
    public let absolutePath: String
    public private(set) var baseline: String
    public private(set) var buffer: String
    public let lineEnding: MainframeExplorerTextLineEnding
    private var undoHistory: [String] = []
    private var redoHistory: [String] = []

    public init(node: MainframeExplorerNode, source: String, isWritable: Bool) throws {
        guard MainframeExplorerPreviewRouter.route(for: node) == .text else {
            throw MainframeExplorerTextDocumentError.readOnly("This file type is read-only in Explorer.")
        }
        guard isWritable else { throw MainframeExplorerTextDocumentError.readOnly("This file is not writable. Explorer keeps it read-only.") }
        guard !source.hasPrefix("\u{FEFF}") else { throw MainframeExplorerTextDocumentError.readOnly("UTF-8 with a byte-order mark is read-only in this editor.") }
        try Self.validateText(source)
        let normalized = Self.normalized(source)
        guard !normalized.contains("\r") else { throw MainframeExplorerTextDocumentError.readOnly("Lone carriage-return line endings are read-only in this editor.") }
        let pairs = source.components(separatedBy: "\r\n").count - 1
        let newlines = normalized.filter { $0 == "\n" }.count
        guard pairs == 0 || pairs == newlines else { throw MainframeExplorerTextDocumentError.readOnly("Mixed LF/CRLF line endings are read-only in this editor.") }
        relativePath = node.relativePath
        absolutePath = node.url.standardizedFileURL.path
        baseline = source
        buffer = normalized
        lineEnding = pairs > 0 ? .crlf : .lf
    }

    public var hasUnsavedChanges: Bool { !buffer.utf8.elementsEqual(Self.normalized(baseline).utf8) }
    public var canUndo: Bool { !undoHistory.isEmpty }
    public var canRedo: Bool { !redoHistory.isEmpty }

    /// Edits are in memory only. Byte/encoding limits are checked at save too.
    @discardableResult
    public mutating func updateBuffer(_ value: String) -> Bool {
        let normalized = Self.normalized(value)
        guard normalized.utf8.count <= Self.byteLimit else { return false }
        guard !normalized.utf8.elementsEqual(buffer.utf8) else { return true }
        undoHistory.append(buffer)
        redoHistory = []
        buffer = normalized
        trimHistory()
        return true
    }

    public mutating func undo() {
        guard let value = undoHistory.popLast() else { return }
        redoHistory.append(buffer)
        buffer = value
        trimHistory()
    }

    public mutating func redo() {
        guard let value = redoHistory.popLast() else { return }
        undoHistory.append(buffer)
        buffer = value
        trimHistory()
    }

    public mutating func revert() {
        updateBuffer(Self.normalized(baseline))
    }

    public func sourceForSave() throws -> String {
        try Self.validateText(buffer)
        guard !buffer.contains("\r"), !buffer.hasPrefix("\u{FEFF}") else {
            throw MainframeExplorerTextDocumentError.readOnly("The edit introduced unsupported line endings or a byte-order mark. The disk file is unchanged.")
        }
        let encoded = lineEnding == .crlf ? buffer.replacingOccurrences(of: "\n", with: "\r\n") : buffer
        try Self.validateText(encoded)
        return encoded
    }

    public mutating func noteSaved(_ source: String) {
        baseline = source
    }

    public func literalMatchCount(_ query: String) throws -> Int {
        try matchRanges(query).count
    }

    public mutating func replaceLiteral(_ query: String, with replacement: String, all: Bool) throws -> Int {
        let ranges = try matchRanges(query)
        guard !ranges.isEmpty else { return 0 }
        let chosen = all ? ranges : Array(ranges.prefix(1))
        var result = buffer
        for range in chosen.reversed() { result.replaceSubrange(range, with: replacement) }
        try Self.validateText(result)
        updateBuffer(result)
        return chosen.count
    }

    private func matchRanges(_ query: String) throws -> [Range<String.Index>] {
        guard !query.isEmpty else { throw MainframeExplorerTextDocumentError.emptyQuery }
        var ranges: [Range<String.Index>] = []
        var position = buffer.startIndex
        while position < buffer.endIndex, let range = buffer.range(of: query, options: .literal, range: position..<buffer.endIndex) {
            guard ranges.count < Self.replacementMatchLimit else { throw MainframeExplorerTextDocumentError.tooManyMatches(Self.replacementMatchLimit) }
            ranges.append(range)
            position = range.upperBound
        }
        return ranges
    }

    private static func normalized(_ text: String) -> String { text.replacingOccurrences(of: "\r\n", with: "\n") }

    private static func validateText(_ text: String) throws {
        let bytes = Array(text.utf8)
        guard bytes.count <= byteLimit else { throw MainframeExplorerTextDocumentError.readOnly("Text exceeds the \(byteLimit)-byte edit limit. The disk file is unchanged.") }
        guard !bytes.contains(where: { ($0 < 32 && ![9, 10, 12, 13].contains($0)) || $0 == 127 }) else {
            throw MainframeExplorerTextDocumentError.readOnly("Binary control bytes are not eligible for text editing.")
        }
    }

    private mutating func trimHistory() {
        while undoHistory.count + redoHistory.count > Self.historyEntryLimit || undoHistory.reduce(0, { $0 + $1.utf8.count }) + redoHistory.reduce(0, { $0 + $1.utf8.count }) > Self.historyByteLimit {
            if !undoHistory.isEmpty { undoHistory.removeFirst() }
            else if !redoHistory.isEmpty { redoHistory.removeFirst() }
            else { break }
        }
    }
}
