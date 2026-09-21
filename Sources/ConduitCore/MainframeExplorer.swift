import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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

public enum MainframeExplorerFilesystemFreshness {
    /// The smallest containing directory that must be re-read before an exact
    /// relative-path miss can be treated as authoritative.
    public static func containingDirectoryPath(for relativePath: String) -> String {
        let parts = relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard parts.count > 1 else { return "" }
        return parts.dropLast().joined(separator: "/")
    }

    /// Direct children that disappeared, or stopped being directories, are
    /// subtree invalidation roots. Callers can remove only those cached
    /// descendants instead of rebuilding the entire Explorer tree.
    public static func staleSubtreeRoots(
        previous: [MainframeExplorerNode],
        current: [MainframeExplorerNode]
    ) -> [String] {
        let currentByPath = Dictionary(
            uniqueKeysWithValues: current.map { ($0.relativePath, $0) }
        )
        return previous.compactMap { oldNode in
            guard let newNode = currentByPath[oldNode.relativePath] else {
                return oldNode.relativePath
            }
            if oldNode.kind == .directory, newNode.kind != .directory {
                return oldNode.relativePath
            }
            return nil
        }
        .sorted()
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
        let canonicalRoot = try canonicalExistingURL(validatedRoot)
        let lexicalDirectory = directory.standardizedFileURL

        if symbolicLinkDestination(at: lexicalDirectory) != nil {
            throw MainframeExplorerError.symbolicLinkTraversal(directory.path)
        }
        let directoryValues = try lexicalDirectory.resourceValues(forKeys: [.isDirectoryKey])
        guard directoryValues.isDirectory == true else {
            throw MainframeExplorerError.notDirectory(directory.path)
        }
        let canonicalDirectory = try canonicalExistingURL(lexicalDirectory)
        guard isPath(canonicalDirectory.path, containedIn: canonicalRoot.path) else {
            throw MainframeExplorerError.unsafePath(directory.path)
        }

        let urls = try fileManager.contentsOfDirectory(
            at: lexicalDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: []
        )
        return try urls
            .filter { !ignoredNames.contains($0.lastPathComponent) }
            .map { try node(root: canonicalRoot, canonicalParent: canonicalDirectory, url: $0) }
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
        let canonicalRoot = try canonicalExistingURL(validatedRoot)
        let lexicalFile = file.standardizedFileURL
        if symbolicLinkDestination(at: lexicalFile) != nil {
            throw MainframeExplorerError.symbolicLinkTraversal(file.path)
        }
        let values = try lexicalFile.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw MainframeExplorerError.notFile(file.path)
        }
        let canonicalFile = try canonicalExistingURL(lexicalFile)
        guard isPath(canonicalFile.path, containedIn: canonicalRoot.path) else {
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
        let canonicalRoot = try canonicalExistingURL(validatedRoot)
        let lexicalLink = link.standardizedFileURL
        guard let rawTarget = symbolicLinkDestination(at: lexicalLink) else {
            throw MainframeExplorerError.notSymbolicLink(link.path)
        }
        let canonicalLink = try canonicalLeafPreservingURL(lexicalLink)
        guard isPath(canonicalLink.path, containedIn: canonicalRoot.path) else {
            throw MainframeExplorerError.unsafePath(link.path)
        }

        let targetURL: URL
        if rawTarget.hasPrefix("/") {
            targetURL = URL(fileURLWithPath: rawTarget)
        } else {
            targetURL = lexicalLink.deletingLastPathComponent().appendingPathComponent(rawTarget)
        }
        let standardizedTarget = targetURL.standardizedFileURL
        let exists = fileManager.fileExists(atPath: standardizedTarget.path)

        let resolvedTarget: URL
        if exists, let canonical = try? canonicalExistingURL(standardizedTarget) {
            resolvedTarget = canonical
        } else if let preserved = try? canonicalLeafPreservingURL(standardizedTarget) {
            resolvedTarget = preserved
        } else {
            resolvedTarget = standardizedTarget
        }

        let location: MainframeSymlinkTargetLocation
        let relativeTargetPath: String?
        if !exists {
            location = .missing
            relativeTargetPath = nil
        } else if isPath(resolvedTarget.path, containedIn: canonicalRoot.path) {
            location = .insideRoot
            relativeTargetPath = try relativePath(root: canonicalRoot, canonicalURL: resolvedTarget, original: targetURL)
        } else {
            location = .outsideRoot
            relativeTargetPath = nil
        }

        return MainframeSymlinkInspection(
            linkPath: try relativePath(root: canonicalRoot, canonicalURL: canonicalLink, original: link),
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
        if symbolicLinkDestination(at: lexicalRoot) != nil {
            throw MainframeExplorerError.symbolicLinkTraversal(root.path)
        }
        return lexicalRoot
    }

    private func node(
        root canonicalRoot: URL,
        canonicalParent: URL,
        url: URL
    ) throws -> MainframeExplorerNode {
        let lexicalURL = url.standardizedFileURL
        let isSymbolicLink = symbolicLinkDestination(at: lexicalURL) != nil
        let values = try lexicalURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        let kind: MainframeExplorerNodeKind
        if isSymbolicLink {
            kind = .symbolicLink
        } else if values.isDirectory == true {
            kind = .directory
        } else {
            kind = .file
        }

        // `contentsOfDirectory` may rewrite an ancestor spelling on macOS
        // (`/tmp` -> `/private/tmp`). The parent directory has already been
        // canonicalized and containment-checked, so derive the child identity
        // from that authorized parent plus the literal leaf name. This also
        // preserves a dangling symlink as a leaf instead of resolving it.
        let canonicalURL = canonicalParent
            .appendingPathComponent(lexicalURL.lastPathComponent, isDirectory: false)
            .standardizedFileURL
        guard isPath(canonicalURL.path, containedIn: canonicalRoot.path) else {
            throw MainframeExplorerError.unsafePath(url.path)
        }
        let relativePath = try relativePath(root: canonicalRoot, canonicalURL: canonicalURL, original: url)
        return MainframeExplorerNode(
            name: lexicalURL.lastPathComponent,
            relativePath: relativePath,
            url: lexicalURL,
            kind: kind,
            zone: MainframeExplorerZone.classify(relativePath: relativePath),
            recordScope: MainframeExplorerRecordScope.derive(relativePath: relativePath)
        )
    }

    /// Canonicalize an existing filesystem object using POSIX `realpath`, which
    /// normalizes filesystem aliases such as macOS `/var` -> `/private/var` and
    /// resolves intermediate symlinks. Callers use this only for objects that
    /// are allowed to resolve fully, never for a symlink leaf that must remain
    /// a leaf.
    private func canonicalExistingURL(_ url: URL) throws -> URL {
        let path = url.standardizedFileURL.path
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let succeeded = buffer.withUnsafeMutableBufferPointer { output in
            path.withCString { input in
                realpath(input, output.baseAddress) != nil
            }
        }
        guard succeeded else {
            throw MainframeExplorerError.unsafePath(url.path)
        }
        let terminator = buffer.firstIndex(of: 0) ?? buffer.endIndex
        let bytes = buffer[..<terminator].map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).standardizedFileURL
    }

    /// Canonicalize all ancestors while deliberately preserving the final path
    /// component. This is the key boundary for dangling symlinks: their parent
    /// directory may be canonicalized, but the link itself is never followed.
    private func canonicalLeafPreservingURL(_ url: URL) throws -> URL {
        let lexical = url.standardizedFileURL
        let canonicalParent = try canonicalExistingURL(lexical.deletingLastPathComponent())
        return canonicalParent
            .appendingPathComponent(lexical.lastPathComponent, isDirectory: false)
            .standardizedFileURL
    }

    private func symbolicLinkDestination(at url: URL) -> String? {
        try? fileManager.destinationOfSymbolicLink(atPath: url.standardizedFileURL.path)
    }

    private func isPath(_ candidatePath: String, containedIn rootPath: String) -> Bool {
        candidatePath == rootPath
            || candidatePath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    private func relativePath(root: URL, canonicalURL: URL, original: URL) throws -> String {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = canonicalURL.standardizedFileURL.path
        guard isPath(candidatePath, containedIn: rootPath) else {
            throw MainframeExplorerError.unsafePath(original.path)
        }
        if candidatePath == rootPath { return "" }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return String(candidatePath.dropFirst(prefix.count))
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
