import Foundation

public enum MainframeSourceKind: String, Codable, CaseIterable, Sendable {
    case markdown
    case swift
    case python
    case javascript
    case typescript
    case json
    case yaml
    case shell
    case toml
    case rust
    case go
    case java
    case cFamily
    case plainText
    case unsupported

    public var displayName: String {
        switch self {
        case .markdown: return "Markdown"
        case .swift: return "Swift"
        case .python: return "Python"
        case .javascript: return "JavaScript"
        case .typescript: return "TypeScript"
        case .json: return "JSON"
        case .yaml: return "YAML"
        case .shell: return "Shell"
        case .toml: return "TOML"
        case .rust: return "Rust"
        case .go: return "Go"
        case .java: return "Java"
        case .cFamily: return "C / C++ / Objective-C"
        case .plainText: return "Plain text"
        case .unsupported: return "Unsupported"
        }
    }

    public var isCode: Bool {
        switch self {
        case .swift, .python, .javascript, .typescript, .shell, .rust, .go, .java, .cFamily:
            return true
        case .markdown, .json, .yaml, .toml, .plainText, .unsupported:
            return false
        }
    }
}

public enum MainframeSourceEditPermission: Equatable, Sendable {
    case editable(kind: MainframeSourceKind)
    case readOnly(kind: MainframeSourceKind, reason: String)
}

/// Conservative source policy for the Context IDE workbench. This policy only
/// decides whether a UTF-8 text file may be offered to the existing explicit
/// conflict-aware writer. The writer and Explorer scanner remain the mutation
/// and containment authority.
public enum MainframeSourcePolicy {
    private static let generatedOrDependencyComponents: Set<String> = [
        ".git", ".build", "DerivedData", "node_modules"
    ]

    public static func classify(fileName: String) -> MainframeSourceKind {
        let lower = fileName.lowercased()
        let ext = URL(fileURLWithPath: lower).pathExtension
        switch ext {
        case "md", "markdown", "mdown", "mkd": return .markdown
        case "swift": return .swift
        case "py", "pyw": return .python
        case "js", "jsx", "mjs", "cjs": return .javascript
        case "ts", "tsx", "mts", "cts": return .typescript
        case "json", "jsonl": return .json
        case "yaml", "yml": return .yaml
        case "sh", "bash", "zsh", "fish": return .shell
        case "toml": return .toml
        case "rs": return .rust
        case "go": return .go
        case "java": return .java
        case "c", "h", "cc", "cpp", "cxx", "hpp", "m", "mm": return .cFamily
        case "txt", "text", "log", "csv", "tsv", "ini", "conf", "cfg": return .plainText
        default:
            // Common extensionless text/config files are explicit rather than
            // guessed from bytes so an unknown binary never becomes editable.
            switch lower {
            case "dockerfile", "makefile", "rakefile", "gemfile", "procfile":
                return .plainText
            default:
                return .unsupported
            }
        }
    }

    public static func editPermission(
        relativePath: String,
        fileName: String
    ) -> MainframeSourceEditPermission {
        let kind = classify(fileName: fileName)
        let components = relativePath.split(separator: "/").map(String.init)
        if let blocked = components.first(where: { generatedOrDependencyComponents.contains($0) }) {
            return .readOnly(
                kind: kind,
                reason: "Files under \(blocked) stay read-only in the Context IDE."
            )
        }
        guard kind != .unsupported else {
            return .readOnly(
                kind: kind,
                reason: "This file type is not on the explicit UTF-8 edit allowlist."
            )
        }
        return .editable(kind: kind)
    }
}

public enum MainframeSourceOutlineKind: String, Codable, Sendable {
    case type
    case function
    case extensionDecl
}

public struct MainframeSourceOutlineEntry: Identifiable, Equatable, Codable, Sendable {
    public var id: String { "\(line):\(kind.rawValue):\(title)" }
    public let line: Int
    public let title: String
    public let kind: MainframeSourceOutlineKind

    public init(line: Int, title: String, kind: MainframeSourceOutlineKind) {
        self.line = line
        self.title = title
        self.kind = kind
    }
}

public struct MainframeSourceOutline: Equatable, Codable, Sendable {
    public let entries: [MainframeSourceOutlineEntry]
    public let mayBeIncomplete: Bool

    public init(entries: [MainframeSourceOutlineEntry], mayBeIncomplete: Bool) {
        self.entries = entries
        self.mayBeIncomplete = mayBeIncomplete
    }
}

/// Deliberately lightweight declaration outline. This is navigation assistance,
/// not a compiler or semantic index, and always reports itself as potentially
/// incomplete. LSP/compiler-backed symbols can replace or supplement it later.
public enum MainframeSourceOutlineExtractor {
    public static func extract(
        source: String,
        kind: MainframeSourceKind
    ) -> MainframeSourceOutline {
        guard kind.isCode else {
            return MainframeSourceOutline(entries: [], mayBeIncomplete: false)
        }

        var entries: [MainframeSourceOutlineEntry] = []
        for (offset, raw) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let match = declaration(in: line, kind: kind) {
                entries.append(.init(line: offset + 1, title: match.0, kind: match.1))
            }
        }
        return MainframeSourceOutline(entries: entries, mayBeIncomplete: true)
    }

    private static func declaration(
        in line: String,
        kind: MainframeSourceKind
    ) -> (String, MainframeSourceOutlineKind)? {
        switch kind {
        case .swift:
            let candidate = strippingLeadingTokens(
                line,
                tokens: [
                    "public", "internal", "private", "fileprivate", "open",
                    "final", "static", "nonisolated", "override", "mutating",
                    "nonmutating", "required", "convenience", "indirect"
                ],
                stripAttributes: true
            )
            return firstPrefix(
                candidate,
                title: line,
                rules: [
                    ("struct ", .type), ("class ", .type), ("enum ", .type),
                    ("protocol ", .type), ("actor ", .type),
                    ("extension ", .extensionDecl), ("func ", .function)
                ]
            )
        case .python:
            return firstPrefix(
                line,
                rules: [("class ", .type), ("async def ", .function), ("def ", .function)]
            )
        case .javascript, .typescript:
            let candidate = strippingLeadingTokens(
                line,
                tokens: ["export", "default", "declare", "abstract", "public", "private", "protected", "static", "readonly"]
            )
            return firstPrefix(
                candidate,
                title: line,
                rules: [
                    ("class ", .type), ("interface ", .type), ("type ", .type),
                    ("function ", .function)
                ]
            )
        case .rust:
            let candidate = strippingLeadingTokens(
                line,
                tokens: ["pub", "async", "unsafe"],
                tokenPrefix: "pub("
            )
            return firstPrefix(
                candidate,
                title: line,
                rules: [
                    ("struct ", .type), ("enum ", .type), ("trait ", .type),
                    ("impl ", .extensionDecl), ("fn ", .function)
                ]
            )
        case .go:
            return firstPrefix(line, rules: [("type ", .type), ("func ", .function)])
        case .java, .cFamily:
            let candidate = strippingLeadingTokens(
                line,
                tokens: ["public", "private", "protected", "static", "final", "abstract", "sealed", "non-sealed"]
            )
            return firstPrefix(
                candidate,
                title: line,
                rules: [("class ", .type), ("struct ", .type), ("enum ", .type), ("interface ", .type)]
            )
        case .shell:
            if line.hasSuffix("() {") || line.hasSuffix("(){") {
                return (line, .function)
            }
            return nil
        case .markdown, .json, .yaml, .toml, .plainText, .unsupported:
            return nil
        }
    }

    private static func firstPrefix(
        _ line: String,
        title: String? = nil,
        rules: [(String, MainframeSourceOutlineKind)]
    ) -> (String, MainframeSourceOutlineKind)? {
        for (prefix, kind) in rules where line.hasPrefix(prefix) {
            return (title ?? line, kind)
        }
        return nil
    }

    /// Removes only a small allowlist of declaration modifiers. This improves
    /// navigation coverage without pretending to parse a language grammar.
    private static func strippingLeadingTokens(
        _ line: String,
        tokens: Set<String>,
        stripAttributes: Bool = false,
        tokenPrefix: String? = nil
    ) -> String {
        var parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        while let first = parts.first {
            let isAttribute = stripAttributes && first.hasPrefix("@")
            let hasAllowedPrefix = tokenPrefix.map { first.hasPrefix($0) } ?? false
            guard isAttribute || tokens.contains(first) || hasAllowedPrefix else { break }
            parts.removeFirst()
        }
        return parts.joined(separator: " ")
    }
}

/// Common `path:line[:column]` diagnostic location. Parsing a string does not
/// grant filesystem authority; callers must still resolve the path through the
/// selected MainFrame/repository boundary before navigation.
public struct MainframeDiagnosticLocation: Equatable, Sendable {
    public let path: String
    public let line: Int
    public let column: Int?

    public init(path: String, line: Int, column: Int? = nil) {
        self.path = path
        self.line = line
        self.column = column
    }
}

public enum MainframeDiagnosticParser {
    private static let locationExpression = try! NSRegularExpression(
        pattern: #"^(.+?):([1-9][0-9]*)(?::([1-9][0-9]*))?(?::|$)"#
    )

    public static func parseLocation(from text: String) -> MainframeDiagnosticLocation? {
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? text
        let nsRange = NSRange(firstLine.startIndex..<firstLine.endIndex, in: firstLine)
        guard let match = locationExpression.firstMatch(in: firstLine, range: nsRange),
              let pathRange = Range(match.range(at: 1), in: firstLine),
              let lineRange = Range(match.range(at: 2), in: firstLine),
              let line = Int(firstLine[lineRange]), line > 0 else {
            return nil
        }

        let path = String(firstLine[pathRange])
        guard !path.isEmpty else { return nil }

        var column: Int?
        if match.range(at: 3).location != NSNotFound,
           let columnRange = Range(match.range(at: 3), in: firstLine),
           let parsed = Int(firstLine[columnRange]), parsed > 0 {
            column = parsed
        }
        return MainframeDiagnosticLocation(path: path, line: line, column: column)
    }
}
