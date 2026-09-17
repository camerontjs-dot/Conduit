import Foundation

/// Presentation-only visual categories for MainFrame Explorer rows.
///
/// These values help operators scan a large file tree. They do not carry
/// lifecycle, verification, task-progress, health, priority, or Git authority.
public enum MainframeExplorerVisualKind: String, CaseIterable, Sendable {
    case folder
    case inboxFolder
    case ingestFolder
    case knowledgeFolder
    case liveFolder
    case projectsFolder
    case operationsFolder
    case archiveFolder
    case projectFolder
    case operationFolder
    case sourceFolder
    case testFolder
    case documentationFolder
    case assetFolder
    case configurationFolder
    case generatedFolder
    case symbolicLink
    case sourceFile
    case markdownFile
    case testFile
    case configurationFile
    case scriptFile
    case assetFile
    case gitFile
    case textFile
    case binaryFile
    case unknownFile

    /// Visual de-emphasis is a navigation hint only. It never means ignored,
    /// unimportant, safe to delete, or excluded from filesystem authority.
    public var isDeemphasized: Bool {
        switch self {
        case .generatedFolder, .binaryFile:
            return true
        default:
            return false
        }
    }
}

public enum MainframeExplorerVisualClassifier {
    public static func classify(_ node: MainframeExplorerNode) -> MainframeExplorerVisualKind {
        if node.kind == .symbolicLink { return .symbolicLink }
        if node.kind == .directory { return classifyDirectory(node) }
        return classifyFile(node)
    }

    private static func classifyDirectory(_ node: MainframeExplorerNode) -> MainframeExplorerVisualKind {
        let parts = pathParts(node.relativePath)
        let lowerName = node.name.lowercased()

        if parts.count == 1 {
            switch node.name {
            case "00_inbox": return .inboxFolder
            case "01_ingest": return .ingestFolder
            case "10_knowledge": return .knowledgeFolder
            case "20_live": return .liveFolder
            case "30_projects": return .projectsFolder
            case "40_operations": return .operationsFolder
            case "90_archive": return .archiveFolder
            default: break
            }
        }

        if parts.count == 2, parts.first == "30_projects" { return .projectFolder }
        if parts.count == 2, parts.first == "40_operations" { return .operationFolder }

        if generatedDirectoryNames.contains(lowerName) { return .generatedFolder }
        if sourceDirectoryNames.contains(lowerName) { return .sourceFolder }
        if testDirectoryNames.contains(lowerName) { return .testFolder }
        if documentationDirectoryNames.contains(lowerName) { return .documentationFolder }
        if assetDirectoryNames.contains(lowerName) { return .assetFolder }
        if configurationDirectoryNames.contains(lowerName) { return .configurationFolder }
        return .folder
    }

    private static func classifyFile(_ node: MainframeExplorerNode) -> MainframeExplorerVisualKind {
        let lowerName = node.name.lowercased()
        let ext = node.url.pathExtension.lowercased()
        let parts = pathParts(node.relativePath).map { $0.lowercased() }
        let stem = node.url.deletingPathExtension().lastPathComponent.lowercased()

        if gitFileNames.contains(lowerName) { return .gitFile }
        if isTestPath(parts: parts, stem: stem) { return .testFile }
        if sourceExtensions.contains(ext) { return .sourceFile }
        if markdownExtensions.contains(ext) { return .markdownFile }
        if configurationExtensions.contains(ext) || configurationFileNames.contains(lowerName) {
            return .configurationFile
        }
        if scriptExtensions.contains(ext) || scriptFileNames.contains(lowerName) { return .scriptFile }
        if assetExtensions.contains(ext) { return .assetFile }
        if textExtensions.contains(ext) { return .textFile }
        if binaryExtensions.contains(ext) { return .binaryFile }
        return .unknownFile
    }

    private static func isTestPath(parts: [String], stem: String) -> Bool {
        if parts.dropLast().contains(where: { testDirectoryNames.contains($0) }) { return true }
        let normalized = stem.replacingOccurrences(of: "-", with: "_")
        let words = normalized.split(separator: "_").map(String.init)
        return words.contains("test") || words.contains("tests") || words.contains("spec") || words.contains("specs")
            || stem.hasSuffix("tests") || stem.hasSuffix("test") || stem.hasSuffix("spec")
    }

    private static func pathParts(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private static let sourceDirectoryNames: Set<String> = [
        "source", "sources", "src", "lib", "libs", "app"
    ]
    private static let testDirectoryNames: Set<String> = [
        "test", "tests", "spec", "specs"
    ]
    private static let documentationDirectoryNames: Set<String> = [
        "doc", "docs", "documentation", "knowledge"
    ]
    private static let assetDirectoryNames: Set<String> = [
        "asset", "assets", "resource", "resources", "images", "media", "public"
    ]
    private static let configurationDirectoryNames: Set<String> = [
        "config", "configs", ".github", ".agents", ".context"
    ]
    private static let generatedDirectoryNames: Set<String> = [
        ".build", "deriveddata", "node_modules", "pods", "vendor", ".swiftpm"
    ]

    private static let sourceExtensions: Set<String> = [
        "swift", "py", "js", "jsx", "ts", "tsx", "rs", "go", "java", "kt",
        "c", "h", "cc", "cpp", "cxx", "hh", "hpp", "m", "mm", "cs", "rb", "php"
    ]
    private static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]
    private static let configurationExtensions: Set<String> = [
        "json", "jsonc", "yaml", "yml", "toml", "plist", "xcconfig", "ini", "conf", "env"
    ]
    private static let scriptExtensions: Set<String> = ["sh", "bash", "zsh", "fish", "command"]
    private static let assetExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "pdf", "mov", "mp4", "wav", "mp3"
    ]
    private static let textExtensions: Set<String> = ["txt", "log", "csv", "tsv", "rtf"]
    private static let binaryExtensions: Set<String> = [
        "zip", "gz", "tgz", "bz2", "xz", "dmg", "pkg", "bin", "sqlite", "sqlite3", "db", "o", "a", "dylib"
    ]

    private static let gitFileNames: Set<String> = [".gitignore", ".gitattributes", ".gitmodules"]
    private static let configurationFileNames: Set<String> = [
        ".editorconfig", ".swiftlint.yml", ".swiftformat", "package.resolved"
    ]
    private static let scriptFileNames: Set<String> = [
        "makefile", "dockerfile", "rakefile", "gemfile", "procfile"
    ]
}

/// Deterministic filename/path filter used by Explorer's local navigation box.
/// It is deliberately lexical and separate from semantic MindGraph retrieval.
public enum MainframeExplorerTreeFilter {
    public static func matches(_ node: MainframeExplorerNode, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        return node.name.lowercased().contains(needle)
            || node.relativePath.lowercased().contains(needle)
    }

    public static func matches(
        _ entries: [MainframeExplorerNode],
        query: String,
        limit: Int = 200
    ) -> [MainframeExplorerNode] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return entries
            .filter { matches($0, query: needle) }
            .sorted { lhs, rhs in
                let leftName = lhs.name.lowercased()
                let rightName = rhs.name.lowercased()
                let normalized = needle.lowercased()
                let leftExact = leftName == normalized
                let rightExact = rightName == normalized
                if leftExact != rightExact { return leftExact }
                if leftName != rightName { return leftName < rightName }
                return lhs.relativePath.localizedCaseInsensitiveCompare(rhs.relativePath) == .orderedAscending
            }
            .prefix(max(1, limit))
            .map { $0 }
    }
}
