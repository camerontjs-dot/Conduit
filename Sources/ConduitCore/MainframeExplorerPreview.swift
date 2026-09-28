import Foundation

public enum MainframeExplorerPreviewRoute: String, Codable, CaseIterable, Sendable {
    case text
    case image
    case pdf
    case unsupportedBinary = "unsupported_binary"
    case none
}

/// Pure presentation routing for an exact Explorer node.
///
/// This does not resolve, authorize, or traverse a path. The existing Explorer
/// scanner remains authoritative for root containment, exact-path recovery,
/// symlink handling, and file identity.
public enum MainframeExplorerPreviewRouter {
    private static let textExtensions: Set<String> = [
        "md", "markdown", "txt", "text", "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp",
        "py", "rb", "rs", "go", "java", "kt", "kts", "js", "jsx", "ts", "tsx", "css", "scss",
        "html", "htm", "xml", "json", "jsonl", "yaml", "yml", "toml", "ini", "cfg", "conf",
        "sh", "bash", "zsh", "fish", "ps1", "sql", "csv", "tsv", "log", "diff", "patch",
        "gitignore", "gitattributes", "editorconfig"
    ]

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp"
    ]

    private static let extensionlessTextNames: Set<String> = [
        "readme", "license", "copying", "notice", "makefile", "dockerfile", "gemfile", "rakefile"
    ]

    public static func route(for node: MainframeExplorerNode) -> MainframeExplorerPreviewRoute {
        guard node.kind == .file else { return .none }

        let ext = node.url.pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if imageExtensions.contains(ext) { return .image }
        if textExtensions.contains(ext) { return .text }

        let base = node.url.lastPathComponent.lowercased()
        if ext.isEmpty, extensionlessTextNames.contains(base) {
            return .text
        }
        return .unsupportedBinary
    }
}
