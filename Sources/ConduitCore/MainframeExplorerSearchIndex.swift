import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Recursive search policy only. Ordinary Explorer directory listings and
/// deterministic Find/Related content indexing keep their existing policy.
public struct MainframeExplorerSearchPolicy: Equatable, Sendable {
    public static let defaultExcludedDirectoryNames: Set<String> = [
        "node_modules", ".build", ".venv", "venv", "__pycache__", ".cache",
        "DerivedData", "build", "dist",
    ]

    public let excludedDirectoryNames: Set<String>
    public let entryLimit: Int
    public let examinedEntryLimit: Int
    public let timeLimitSeconds: TimeInterval
    public let depthLimit: Int

    public init(
        excludedDirectoryNames: Set<String> = Self.defaultExcludedDirectoryNames,
        entryLimit: Int = 20_000,
        examinedEntryLimit: Int = 40_000,
        timeLimitSeconds: TimeInterval = 3,
        depthLimit: Int = 64
    ) {
        self.excludedDirectoryNames = excludedDirectoryNames
        self.entryLimit = min(20_000, max(1, entryLimit))
        self.examinedEntryLimit = min(40_000, max(1, examinedEntryLimit))
        self.timeLimitSeconds = timeLimitSeconds.isFinite ? min(10, max(0.001, timeLimitSeconds)) : 3
        self.depthLimit = min(64, max(1, depthLimit))
    }
}

public enum MainframeExplorerSearchStop: String, Codable, Sendable {
    case entryLimit
    case workLimit
    case timeLimit
    case cancelled
}

public enum MainframeExplorerSearchError: LocalizedError, Equatable {
    case rootUnavailable
    case rootChanged

    public var errorDescription: String? {
        switch self {
        case .rootUnavailable: return "The selected search root is unavailable or is no longer an ordinary directory."
        case .rootChanged: return "The selected search root changed while opening it. Refresh before searching."
        }
    }
}

public struct MainframeExplorerSearchIssue: Codable, Equatable, Sendable {
    public let relativePath: String
    public let reason: String
}

public struct MainframeExplorerSearchReceipt: Codable, Equatable, Sendable {
    public let observedAt: Date
    public let scannedDirectories: Int
    public let examinedEntries: Int
    public let excludedDirectoryCount: Int
    public let excludedDirectorySample: [String]
    public let issueCount: Int
    public let issueSample: [MainframeExplorerSearchIssue]
    public let stop: MainframeExplorerSearchStop?
    public let isInProgress: Bool
    public let entryLimit: Int
    public let examinedEntryLimit: Int
    public let timeLimitSeconds: TimeInterval
    public let depthLimit: Int

    public var isComplete: Bool {
        !isInProgress && stop == nil && excludedDirectoryCount == 0 && issueCount == 0
    }

    public var summary: String {
        var parts: [String] = []
        if isInProgress { parts.append("Indexing; results are partial") }
        else if isComplete { parts.append("Search snapshot completed") }
        else { parts.append("Partial search snapshot") }
        if excludedDirectoryCount > 0 { parts.append("\(excludedDirectoryCount) generated/cache subtrees skipped") }
        if issueCount > 0 { parts.append("\(issueCount) filesystem issues") }
        switch stop {
        case .entryLimit: parts.append("\(entryLimit)-entry cap reached")
        case .workLimit: parts.append("\(examinedEntryLimit)-entry examination budget reached")
        case .timeLimit: parts.append("\(timeLimitSeconds)-second time budget reached")
        case .cancelled: parts.append("Cancelled")
        case nil: break
        }
        return parts.joined(separator: " · ")
    }
}

public struct MainframeExplorerSearchIndex: Sendable {
    public let entries: [MainframeExplorerNode]
    public let receipt: MainframeExplorerSearchReceipt
}

/// Read-only Quick Open snapshots. Descriptors stay anchored to the selected
/// root; no-follow traversal prevents a renamed directory from becoming a
/// symlink traversal. One unreadable subtree cannot erase healthy siblings.
public struct MainframeExplorerSearchIndexer: Sendable {
    public init() {}

    public func build(
        root: URL,
        policy: MainframeExplorerSearchPolicy = .init(),
        isCancelled: @Sendable () -> Bool = { Task.isCancelled },
        onProgress: (@Sendable (MainframeExplorerSearchIndex) -> Void)? = nil
    ) throws -> MainframeExplorerSearchIndex {
        let lexicalRoot = root.standardizedFileURL
        let rootFD = lexicalRoot.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard rootFD >= 0 else { throw MainframeExplorerSearchError.rootUnavailable }
        defer { close(rootFD) }

        var rootStat = stat()
        guard fstat(rootFD, &rootStat) == 0 else { throw MainframeExplorerSearchError.rootChanged }
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolvedOK = lexicalRoot.path.withCString { path in
            resolved.withUnsafeMutableBufferPointer { realpath(path, $0.baseAddress) != nil }
        }
        guard resolvedOK else { throw MainframeExplorerSearchError.rootChanged }
        let canonicalRoot = URL(fileURLWithPath: String(cString: resolved)).standardizedFileURL
        var canonicalStat = stat()
        guard canonicalRoot.path.withCString({ lstat($0, &canonicalStat) }) == 0,
              rootStat.st_dev == canonicalStat.st_dev, rootStat.st_ino == canonicalStat.st_ino else {
            throw MainframeExplorerSearchError.rootChanged
        }

        let started = ProcessInfo.processInfo.systemUptime
        var entries: [MainframeExplorerNode] = []
        var queue = [""]
        var cursor = 0
        var examined = 0
        var scanned = 0
        var excluded = 0
        var excludedSample: [String] = []
        var issues = 0
        var issueSample: [MainframeExplorerSearchIssue] = []
        var stop: MainframeExplorerSearchStop?
        var nextProgress = 1_000

        func issue(_ path: String, _ reason: String) {
            issues += 1
            if issueSample.count < 40 { issueSample.append(.init(relativePath: path, reason: reason)) }
        }
        func snapshot(inProgress: Bool) -> MainframeExplorerSearchIndex {
            MainframeExplorerSearchIndex(
                entries: entries.sorted { $0.relativePath < $1.relativePath },
                receipt: .init(observedAt: Date(), scannedDirectories: scanned, examinedEntries: examined,
                               excludedDirectoryCount: excluded, excludedDirectorySample: excludedSample,
                               issueCount: issues, issueSample: issueSample, stop: stop, isInProgress: inProgress,
                               entryLimit: policy.entryLimit, examinedEntryLimit: policy.examinedEntryLimit,
                               timeLimitSeconds: policy.timeLimitSeconds, depthLimit: policy.depthLimit)
            )
        }
        func shouldStop() -> Bool {
            if isCancelled() { stop = .cancelled }
            else if examined >= policy.examinedEntryLimit { stop = .workLimit }
            else if ProcessInfo.processInfo.systemUptime - started >= policy.timeLimitSeconds { stop = .timeLimit }
            return stop != nil
        }

        traversal: while cursor < queue.count {
            if shouldStop() { break }
            let relativeDirectory = queue[cursor]
            cursor += 1
            let directoryFD: Int32
            do { directoryFD = try openDirectory(relativeDirectory, rootFD: rootFD) }
            catch {
                if relativeDirectory.isEmpty { throw error }
                issue(relativeDirectory, "Directory is unavailable or was replaced; descendants were not scanned")
                continue
            }
            guard let directory = fdopendir(directoryFD) else {
                close(directoryFD)
                if relativeDirectory.isEmpty { throw MainframeExplorerError.notDirectory(root.path) }
                issue(relativeDirectory, "Directory could not be enumerated")
                continue
            }
            defer { closedir(directory) }
            scanned += 1
            var subdirectories: [String] = []
            while true {
                if shouldStop() { break traversal }
                errno = 0
                guard let entry = readdir(directory) else {
                    if errno != 0 { issue(relativeDirectory, "Directory enumeration ended with a filesystem error") }
                    break
                }
                var nameBytes = entry.pointee.d_name
                let nameCapacity = MemoryLayout.size(ofValue: nameBytes)
                let name = withUnsafePointer(to: &nameBytes) {
                    $0.withMemoryRebound(to: CChar.self, capacity: nameCapacity) {
                        String(validatingUTF8: $0)
                    }
                }
                guard let name else {
                    examined += 1
                    issue(relativeDirectory, "A non-UTF-8 directory entry could not be indexed exactly")
                    continue
                }
                if name == "." || name == ".." || MainframeExplorerScanner.defaultIgnoredNames.contains(name) { continue }
                examined += 1
                let relative = relativeDirectory.isEmpty ? name : relativeDirectory + "/" + name
                var metadata = stat()
                guard name.withCString({ fstatat(directoryFD, $0, &metadata, AT_SYMLINK_NOFOLLOW) }) == 0 else {
                    issue(relative, "Entry metadata is unavailable; entry was omitted")
                    continue
                }
                if entries.count >= policy.entryLimit { stop = .entryLimit; break traversal }
                let mode = metadata.st_mode & mode_t(S_IFMT)
                let kind: MainframeExplorerNodeKind = mode == mode_t(S_IFLNK) ? .symbolicLink : mode == mode_t(S_IFDIR) ? .directory : .file
                entries.append(.init(name: name, relativePath: relative, url: canonicalRoot.appendingPathComponent(relative),
                                     kind: kind, zone: .classify(relativePath: relative), recordScope: .derive(relativePath: relative)))
                if kind == .directory {
                    if policy.excludedDirectoryNames.contains(name) {
                        excluded += 1
                        if excludedSample.count < 40 { excludedSample.append(relative) }
                    } else if relative.split(separator: "/").count >= policy.depthLimit {
                        issue(relative, "Directory-depth budget reached; descendants were not scanned")
                    } else {
                        subdirectories.append(relative)
                    }
                }
                if entries.count >= nextProgress {
                    onProgress?(snapshot(inProgress: true))
                    nextProgress += 1_000
                }
            }
            queue.append(contentsOf: subdirectories.sorted())
        }
        return snapshot(inProgress: false)
    }

    private func openDirectory(_ relative: String, rootFD: Int32) throws -> Int32 {
        var current = dup(rootFD)
        guard current >= 0 else { throw MainframeExplorerError.unsafePath(relative) }
        guard fcntl(current, F_SETFD, FD_CLOEXEC) == 0 else {
            close(current)
            throw MainframeExplorerError.unsafePath(relative)
        }
        for part in relative.split(separator: "/") {
            let next = String(part).withCString { openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            close(current)
            guard next >= 0 else { throw MainframeExplorerError.symbolicLinkTraversal(relative) }
            current = next
        }
        return current
    }
}
