import Foundation

/// Presentation grouping for paths in a MainFrame root. Only the seven
/// lifecycle directories have lifecycle meaning; every other root child is a
/// system surface for Explorer presentation.
public enum MainframeExplorerZone: String, Codable, CaseIterable, Sendable {
    case inbox
    case ingest
    case knowledge
    case live
    case projects
    case operations
    case archive
    case system

    public static func classify(relativePath: String) -> MainframeExplorerZone {
        let first = relativePath.split(separator: "/", omittingEmptySubsequences: true).first.map(String.init)
        switch first {
        case "00_inbox": return .inbox
        case "01_ingest": return .ingest
        case "10_knowledge": return .knowledge
        case "20_live": return .live
        case "30_projects": return .projects
        case "40_operations": return .operations
        case "90_archive": return .archive
        default: return .system
        }
    }
}

public enum MainframeExplorerRecordType: String, Codable, Sendable {
    case project
    case operation
}

/// Pure path-derived scope hint for navigation. This does not assert that the
/// lifecycle record is valid; callers that need authority must resolve it with
/// `MainframeLifecycleScanner`.
public struct MainframeExplorerRecordScope: Codable, Hashable, Sendable {
    public let recordType: MainframeExplorerRecordType
    public let slug: String

    public init(recordType: MainframeExplorerRecordType, slug: String) {
        self.recordType = recordType
        self.slug = slug
    }

    public static func derive(relativePath: String) -> MainframeExplorerRecordScope? {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }
        if parts[0] == "30_projects" {
            return MainframeExplorerRecordScope(recordType: .project, slug: parts[1])
        }
        if parts[0] == "40_operations" {
            return MainframeExplorerRecordScope(recordType: .operation, slug: parts[1])
        }
        return nil
    }
}

public enum MainframeExplorerNodeKind: String, Codable, Sendable {
    case directory
    case file
    case symbolicLink

    fileprivate var sortRank: Int {
        switch self {
        case .directory: return 0
        case .file: return 1
        case .symbolicLink: return 2
        }
    }
}

public struct MainframeExplorerNode: Identifiable, Codable, Hashable, Sendable {
    public var id: String { relativePath }
    public let name: String
    public let relativePath: String
    public let url: URL
    public let kind: MainframeExplorerNodeKind
    public let zone: MainframeExplorerZone
    public let recordScope: MainframeExplorerRecordScope?

    public init(
        name: String,
        relativePath: String,
        url: URL,
        kind: MainframeExplorerNodeKind,
        zone: MainframeExplorerZone,
        recordScope: MainframeExplorerRecordScope?
    ) {
        self.name = name
        self.relativePath = relativePath
        self.url = url
        self.kind = kind
        self.zone = zone
        self.recordScope = recordScope
    }
}

public struct MainframeExplorerIndex: Sendable {
    public let entries: [MainframeExplorerNode]
    public let truncated: Bool

    public init(entries: [MainframeExplorerNode], truncated: Bool) {
        self.entries = entries
        self.truncated = truncated
    }
}

/// Factual classification for a selected symbolic-link target. This does not
/// authorize traversal; ordinary Explorer scans continue to treat links as
/// leaves.
public enum MainframeSymlinkTargetLocation: String, Codable, Sendable {
    case insideRoot
    case outsideRoot
    case missing
}

public struct MainframeSymlinkInspection: Equatable, Sendable {
    public let linkPath: String
    public let rawTarget: String
    public let resolvedTargetPath: String
    public let location: MainframeSymlinkTargetLocation
    public let relativeTargetPath: String?

    public init(
        linkPath: String,
        rawTarget: String,
        resolvedTargetPath: String,
        location: MainframeSymlinkTargetLocation,
        relativeTargetPath: String?
    ) {
        self.linkPath = linkPath
        self.rawTarget = rawTarget
        self.resolvedTargetPath = resolvedTargetPath
        self.location = location
        self.relativeTargetPath = relativeTargetPath
    }
}

public enum MainframeExplorerError: LocalizedError, Equatable {
    case missingRoot(String)
    case unsafePath(String)
    case notDirectory(String)
    case notFile(String)
    case notSymbolicLink(String)
    case symbolicLinkTraversal(String)
    case fileTooLarge(path: String, bytes: Int, limit: Int)
    case nonUTF8(String)

    public var errorDescription: String? {
        switch self {
        case .missingRoot(let path): return "MainFrame root does not exist: \(path)"
        case .unsafePath(let path): return "Path escapes the selected MainFrame root: \(path)"
        case .notDirectory(let path): return "Explorer path is not a directory: \(path)"
        case .notFile(let path): return "Explorer path is not a regular file: \(path)"
        case .notSymbolicLink(let path): return "Explorer path is not a symbolic link: \(path)"
        case .symbolicLinkTraversal(let path): return "Explorer does not follow symbolic links: \(path)"
        case .fileTooLarge(let path, let bytes, let limit):
            return "File is too large for the Explorer reader (\(bytes) bytes; limit \(limit)): \(path)"
        case .nonUTF8(let path): return "File is not valid UTF-8 text: \(path)"
        }
    }
}

/// Read-only, lazy-friendly filesystem projection for MainFrame Explorer.
///
/// The scanner lists exactly one directory at a time. Symbolic links are shown
/// as leaf nodes but never traversed. Hidden MainFrame contract surfaces such
/// as `.agents`, `.context`, and `.github` remain visible; `.git` and Finder
/// metadata are excluded by the default policy.
public struct MainframeExplorerScanner: @unchecked Sendable {
    public static let defaultIgnoredNames: Set<String> = [".git", ".DS_Store"]

    private let fileManager: FileManager
    private let ignoredNames: Set<String>

    public init(
        fileManager: FileManager = .default,
        ignoredNames: Set<String> = MainframeExplorerScanner.defaultIgnoredNames
    ) {
        self.fileManager = fileManager
        self.ignoredNames = ignoredNames
    }

    public func rootChildren(root: URL) throws -> [MainframeExplorerNode] {
        try children(root: root, directory: root)
    }

    public func children(root: URL, directory: URL) throws -> [MainframeExplorerNode] {
        let validatedRoot = try validateRoot(root)
        let lexicalDirectory = directory.standardizedFileURL
        guard isLexicallyContained(lexicalDirectory, in: validatedRoot) else {
            throw MainframeExplorerError.unsafePath(directory.path)
        }
        let directoryValues = try lexicalDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if directoryValues.isSymbolicLink == true {
            throw MainframeExplorerError.symbolicLinkTraversal(directory.path)
        }
        guard directoryValues.isDirectory == true else {
            throw MainframeExplorerError.notDirectory(directory.path)
        }
        guard isResolvedContained(lexicalDirectory, in: validatedRoot) else {
            throw MainframeExplorerError.unsafePath(directory.path)
        }

        let urls = try fileManager.contentsOfDirectory(
            at: lexicalDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        )
        return try urls
            .filter { !ignoredNames.contains($0.lastPathComponent) }
            .map { try node(root: validatedRoot, url: $0) }
            .sorted(by: nodeSort)
    }

    /// Bounded recursive index used by Quick Open. It never follows symbolic
    /// links and returns a `truncated` receipt rather than pretending an
    /// incomplete traversal is complete.
    public func buildIndex(root: URL, maxEntries: Int = 20_000) throws -> MainframeExplorerIndex {
        let validatedRoot = try validateRoot(root)
        let limit = max(1, maxEntries)
        var entries: [MainframeExplorerNode] = []
        var queue: [URL] = [validatedRoot]
        var cursor = 0
        var truncated = false

        while cursor < queue.count {
            let directory = queue[cursor]
            cursor += 1
            let nodes = try children(root: validatedRoot, directory: directory)
            for node in nodes {
                if entries.count >= limit {
                    truncated = true
                    return MainframeExplorerIndex(entries: entries, truncated: truncated)
                }
                entries.append(node)
                if node.kind == .directory {
                    queue.append(node.url)
                }
            }
        }
        return MainframeExplorerIndex(entries: entries, truncated: truncated)
    }

    public func readUTF8Text(
        root: URL,
        file: URL,
        maxBytes: Int = 2_000_000
    ) throws -> String {
        let validatedRoot = try validateRoot(root)
        let lexicalFile = file.standardizedFileURL
        guard isLexicallyContained(lexicalFile, in: validatedRoot) else {
            throw MainframeExplorerError.unsafePath(file.path)
        }
        let values = try lexicalFile.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        if values.isSymbolicLink == true {
            throw MainframeExplorerError.symbolicLinkTraversal(file.path)
        }
        guard values.isRegularFile == true else {
            throw MainframeExplorerError.notFile(file.path)
        }
        guard isResolvedContained(lexicalFile, in: validatedRoot) else {
            throw MainframeExplorerError.unsafePath(file.path)
        }
        let limit = max(1, maxBytes)
        let size = values.fileSize ?? 0
        guard size <= limit else {
            throw MainframeExplorerError.fileTooLarge(path: file.path, bytes: size, limit: limit)
        }
        let data = try Data(contentsOf: lexicalFile, options: [.mappedIfSafe])
        guard data.count <= limit else {
            throw MainframeExplorerError.fileTooLarge(path: file.path, bytes: data.count, limit: limit)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw MainframeExplorerError.nonUTF8(file.path)
        }
        return text
    }

    /// Inspect a selected symbolic link without traversing it during ordinary
    /// scanning. The result is presentation information only. Callers may offer
    /// an explicit navigation action only when `relativeTargetPath` is present.
    public func inspectSymbolicLink(root: URL, link: URL) throws -> MainframeSymlinkInspection {
        let validatedRoot = try validateRoot(root)
        let lexicalLink = link.standardizedFileURL
        guard isLexicallyContained(lexicalLink, in: validatedRoot) else {
            throw MainframeExplorerError.unsafePath(link.path)
        }
        let values = try lexicalLink.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink == true else {
            throw MainframeExplorerError.notSymbolicLink(link.path)
        }

        let rawTarget = try fileManager.destinationOfSymbolicLink(atPath: lexicalLink.path)
        let targetURL: URL
        if rawTarget.hasPrefix("/") {
            targetURL = URL(fileURLWithPath: rawTarget)
        } else {
            targetURL = lexicalLink.deletingLastPathComponent().appendingPathComponent(rawTarget)
        }
        let resolvedTarget = targetURL.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let exists = fileManager.fileExists(atPath: resolvedTarget.path)

        let location: MainframeSymlinkTargetLocation
        let relativeTargetPath: String?
        if !exists {
            location = .missing
            relativeTargetPath = nil
        } else if isResolvedContained(resolvedTarget, in: validatedRoot) {
            location = .insideRoot
            relativeTargetPath = relativePath(root: validatedRoot, url: resolvedTarget)
        } else {
            location = .outsideRoot
            relativeTargetPath = nil
        }

        return MainframeSymlinkInspection(
            linkPath: relativePath(root: validatedRoot, url: lexicalLink),
            rawTarget: rawTarget,
            resolvedTargetPath: resolvedTarget.path,
            location: location,
            relativeTargetPath: relativeTargetPath
        )
    }

    private func validateRoot(_ root: URL) throws -> URL {
        let lexicalRoot = root.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: lexicalRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MainframeExplorerError.missingRoot(root.path)
        }
        let values = try lexicalRoot.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values.isSymbolicLink == true {
            throw MainframeExplorerError.symbolicLinkTraversal(root.path)
        }
        return lexicalRoot
    }

    private func node(root: URL, url: URL) throws -> MainframeExplorerNode {
        let lexicalURL = url.standardizedFileURL
        guard isLexicallyContained(lexicalURL, in: root) else {
            throw MainframeExplorerError.unsafePath(url.path)
        }
        let values = try lexicalURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        let kind: MainframeExplorerNodeKind
        if values.isSymbolicLink == true {
            kind = .symbolicLink
        } else if values.isDirectory == true {
            kind = .directory
        } else {
            kind = .file
        }
        if kind != .symbolicLink, !isResolvedContained(lexicalURL, in: root) {
            throw MainframeExplorerError.unsafePath(url.path)
        }
        let relativePath = relativePath(root: root, url: lexicalURL)
        return MainframeExplorerNode(
            name: lexicalURL.lastPathComponent,
            relativePath: relativePath,
            url: lexicalURL,
            kind: kind,
            zone: MainframeExplorerZone.classify(relativePath: relativePath),
            recordScope: MainframeExplorerRecordScope.derive(relativePath: relativePath)
        )
    }

    private func relativePath(root: URL, url: URL) -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let urlComponents = url.standardizedFileURL.pathComponents
        return urlComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private func isLexicallyContained(_ candidate: URL, in root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    private func isResolvedContained(_ candidate: URL, in root: URL) -> Bool {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        return resolvedCandidate == resolvedRoot || resolvedCandidate.hasPrefix(resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/")
    }

    private func nodeSort(_ lhs: MainframeExplorerNode, _ rhs: MainframeExplorerNode) -> Bool {
        if lhs.kind.sortRank != rhs.kind.sortRank {
            return lhs.kind.sortRank < rhs.kind.sortRank
        }
        let left = lhs.name.lowercased()
        let right = rhs.name.lowercased()
        if left != right { return left < right }
        return lhs.name < rhs.name
    }
}

public enum MainframeQuickOpen {
    /// Stable fuzzy-ish ranking over a bounded filesystem index. The source
    /// entries stay unchanged; this is presentation-only navigation.
    public static func matches(
        _ entries: [MainframeExplorerNode],
        query: String,
        limit: Int = 50
    ) -> [MainframeExplorerNode] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cap = max(1, limit)
        guard !needle.isEmpty else {
            return Array(entries.prefix(cap))
        }
        return entries
            .compactMap { node -> (MainframeExplorerNode, Int)? in
                let name = node.name.lowercased()
                let path = node.relativePath.lowercased()
                let score: Int
                if name == needle { score = 0 }
                else if name.hasPrefix(needle) { score = 10 }
                else if name.contains(needle) { score = 20 }
                else if path.contains(needle) { score = 30 }
                else if orderedSubsequence(needle, in: name) { score = 40 }
                else if orderedSubsequence(needle, in: path) { score = 50 }
                else { return nil }
                return (node, score)
            }
            .sorted {
                if $0.1 != $1.1 { return $0.1 < $1.1 }
                if $0.0.relativePath.count != $1.0.relativePath.count {
                    return $0.0.relativePath.count < $1.0.relativePath.count
                }
                return $0.0.relativePath < $1.0.relativePath
            }
            .prefix(cap)
            .map(\.0)
    }

    private static func orderedSubsequence(_ needle: String, in haystack: String) -> Bool {
        guard !needle.isEmpty else { return true }
        var needleIndex = needle.startIndex
        for character in haystack {
            if character == needle[needleIndex] {
                needle.formIndex(after: &needleIndex)
                if needleIndex == needle.endIndex { return true }
            }
        }
        return false
    }
}

/// Pure navigation history for Explorer and later Graph focus transitions.
public struct MainframeNavigationHistory: Equatable, Sendable {
    public private(set) var entries: [String] = []
    public private(set) var currentIndex: Int? = nil

    public init() {}

    public var current: String? {
        guard let currentIndex, entries.indices.contains(currentIndex) else { return nil }
        return entries[currentIndex]
    }

    public var canGoBack: Bool { (currentIndex ?? 0) > 0 }
    public var canGoForward: Bool {
        guard let currentIndex else { return false }
        return currentIndex + 1 < entries.count
    }

    public mutating func visit(_ relativePath: String) {
        guard !relativePath.isEmpty else { return }
        if current == relativePath { return }
        if let currentIndex, currentIndex + 1 < entries.count {
            entries.removeSubrange((currentIndex + 1)..<entries.count)
        }
        entries.append(relativePath)
        currentIndex = entries.count - 1
    }

    @discardableResult
    public mutating func goBack() -> String? {
        guard canGoBack, let currentIndex else { return current }
        self.currentIndex = currentIndex - 1
        return current
    }

    @discardableResult
    public mutating func goForward() -> String? {
        guard canGoForward, let currentIndex else { return current }
        self.currentIndex = currentIndex + 1
        return current
    }
}
