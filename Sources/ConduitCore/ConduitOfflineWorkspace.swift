import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct ConduitOfflineManifest: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let path: String
        public let sha256: String
        public let byteCount: UInt64
        public let posixMode: UInt16
    }
    public let schemaVersion: String
    public let sourceIdentity: String
    public let files: [Entry]
    public let directories: [String]
    public let excludedNames: [String]
    public let sha256: String

    init(sourceIdentity: String, files: [Entry], directories: [String]) throws {
        schemaVersion = "conduit-offline-source/v1"; self.sourceIdentity = sourceIdentity
        self.files = files.sorted { $0.path < $1.path }
        self.directories = directories.sorted()
        excludedNames = ConduitOfflineWorkspace.excludedNames.sorted()
        struct Identity: Encodable {
            let schemaVersion: String
            let files: [Entry]; let directories: [String]; let excludedNames: [String]
        }
        sha256 = try ConduitOfflineHash.encoded(Identity(schemaVersion: schemaVersion,
            files: self.files, directories: self.directories, excludedNames: excludedNames))
    }
}

/// Explicit standalone snapshots only. No process or VM execution surface.
/// Descriptor walks reject symlinks and hard links. As with the native writer,
/// this assumes exclusive ownership; it is not CAS against hostile writers.
public enum ConduitOfflineWorkspace {
    public static let maximumFileBytes = 4_194_304
    public static let maximumTotalBytes = 67_108_864
    public static let maximumFiles = 20_000
    public static let excludedNames: Set<String> = [".git", ".build", ".swiftpm", ".DS_Store", "node_modules"]
    private static let markerName = ".conduit-offline-workspace.json"
    private static let protectedNames: Set<String> = ["agents.md", "claude.md", "harness.md"]

    private struct Marker: Codable {
        let schemaVersion: String
        let directoryIdentity: String
        let sourceIdentity: String
        let initialManifestSHA256: String
        let receiptDirectory: String
    }

    /// Destination must be absent and outside the original tree. Incomplete
    /// staging remains unmarked and unusable; failures never delete evidence.
    public static func stage(sourceRoot: URL, stagedRoot: URL) throws -> ConduitOfflineManifest {
        let source = try ConduitOfflineFS.openAbsolute(sourceRoot.path, directory: true)
        defer { close(source) }
        let sourcePath = try ConduitOfflineFS.absoluteComponents(sourceRoot.path).joined(separator: "/")
        let destination = try ConduitOfflineFS.absoluteComponents(stagedRoot.path)
        guard let name = destination.last, !name.hasPrefix("."), sourceRoot.path != "/",
              !stagedRoot.path.hasPrefix(sourceRoot.path + "/"),
              !sourceRoot.path.hasPrefix(stagedRoot.path + "/"), stagedRoot.path != sourceRoot.path else {
            throw ConduitOfflineFailure("overlapping_or_invalid_stage")
        }
        let parentPath = "/" + destination.dropLast().joined(separator: "/")
        let parent = try ConduitOfflineFS.openAbsolute(parentPath, directory: true)
        defer { close(parent) }
        guard mkdirat(parent, name, mode_t(0o700)) == 0 else { throw ConduitOfflineFailure("stage_must_be_absent") }
        let stage = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stage >= 0 else { throw ConduitOfflineFailure("stage_unavailable") }
        defer { close(stage) }
        let sourceIdentity = ConduitOfflineHash.bytes(Data(("/" + sourcePath + ":" + (try ConduitOfflineFS.identity(source))).utf8))
        let before = try collect(source, sourceIdentity: sourceIdentity)
        var budget = Budget()
        try copyTree(source: source, destination: stage, depth: 0, budget: &budget)
        guard try collect(source, sourceIdentity: sourceIdentity) == before,
              try collect(stage, sourceIdentity: sourceIdentity) == before else {
            throw ConduitOfflineFailure("source_changed_during_stage")
        }
        let receiptPath = parentPath + "/" + name + ".conduit-offline-receipts-" + UUID().uuidString
        let marker = Marker(schemaVersion: "conduit-offline-workspace/v1",
            directoryIdentity: try ConduitOfflineFS.identity(stage), sourceIdentity: sourceIdentity,
            initialManifestSHA256: before.sha256, receiptDirectory: receiptPath)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try ConduitOfflineFS.writeExclusive(parent: stage, name: markerName, data: encoder.encode(marker), mode: mode_t(0o600))
        guard fsync(stage) == 0, fsync(parent) == 0 else { throw ConduitOfflineFailure("stage_durability_unknown") }
        return before
    }

    public static func manifest(stagedRoot: URL) throws -> ConduitOfflineManifest {
        let (fd, marker) = try openStage(stagedRoot)
        defer { close(fd) }
        return try collect(fd, sourceIdentity: marker.sourceIdentity)
    }

    /// Materialize the portable guest input, without copying local authority or
    /// receipt paths. This creates no disk image, mount or execution grant.
    public static func exportInput(stagedRoot: URL, destination: URL) throws -> ConduitOfflineManifest {
        let (source, marker) = try openStage(stagedRoot); defer { close(source) }
        let before = try collect(source, sourceIdentity: marker.sourceIdentity)
        let parts = try ConduitOfflineFS.absoluteComponents(destination.path)
        guard let leaf = parts.last, !leaf.hasPrefix("."), destination.path != stagedRoot.path,
              !destination.path.hasPrefix(stagedRoot.path + "/"), !stagedRoot.path.hasPrefix(destination.path + "/") else {
            throw ConduitOfflineFailure("overlapping_or_invalid_export")
        }
        let parent = try ConduitOfflineFS.openAbsolute("/" + parts.dropLast().joined(separator: "/"), directory: true)
        defer { close(parent) }
        guard mkdirat(parent, leaf, 0o700) == 0 else { throw ConduitOfflineFailure("export_must_be_absent") }
        let output = openat(parent, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard output >= 0 else { throw ConduitOfflineFailure("export_unavailable") }; defer { close(output) }
        var budget = Budget()
        try copyTree(source: source, destination: output, depth: 0, budget: &budget, excludeStageMarker: true)
        guard try collect(source, sourceIdentity: marker.sourceIdentity) == before,
              try collect(output, sourceIdentity: marker.sourceIdentity) == before,
              fsync(output) == 0, fsync(parent) == 0 else { throw ConduitOfflineFailure("export_changed_or_unsynced") }
        return before
    }

    public static func inspect(stagedRoot: URL, relativePath: String, maximumBytes: Int = 512_000) throws -> String {
        guard (1...512_000).contains(maximumBytes) else { throw ConduitOfflineFailure("invalid_read_limit") }
        let (root, _) = try openStage(stagedRoot); defer { close(root) }
        let file = try ConduitOfflineFS.openRelative(root: root, path: relativePath, directory: false)
        defer { close(file) }
        let bytes = try ConduitOfflineFS.read(file, maximumBytes: maximumBytes)
        guard let text = String(data: bytes, encoding: .utf8), !bytes.contains(0) else { throw ConduitOfflineFailure("unsupported_text") }
        return text
    }

    /// At most 500 matching relative paths. Contents are never returned here.
    public static func search(stagedRoot: URL, literal: String) throws -> [String] {
        guard !literal.isEmpty, literal.utf8.count <= 4096, !literal.utf8.contains(0) else { throw ConduitOfflineFailure("invalid_search") }
        let inventory = try manifest(stagedRoot: stagedRoot)
        var matches: [String] = []
        for entry in inventory.files {
            // Text inspection enforces a narrower byte bound than staging.
            guard entry.byteCount <= 512_000 else { continue }
            if let text = try? inspect(stagedRoot: stagedRoot, relativePath: entry.path), text.contains(literal) {
                matches.append(entry.path)
                if matches.count == 500 { break }
            }
        }
        return matches
    }

    /// One existing UTF-8 replacement through the existing descriptor-anchored
    /// native writer. Its before bytes and outcome remain in the sibling store.
    public static func replace(stagedRoot: URL, relativePath: String, expectedSHA256: String,
                               replacement: String) throws -> ConduitOfflineManifest {
        let components = try ConduitOfflineFS.relativeComponents(relativePath)
        guard !components.contains(where: { $0.hasPrefix(".") || protectedNames.contains($0.lowercased()) }),
              ConduitOfflinePreflight.validHash(expectedSHA256) else { throw ConduitOfflineFailure("protected_or_invalid_edit") }
        let (fd, marker) = try openStage(stagedRoot); defer { close(fd) }
        let file = try ConduitOfflineFS.openRelative(root: fd, path: relativePath, directory: false)
        defer { close(file) }
        guard ConduitOfflineHash.bytes(try ConduitOfflineFS.read(file, maximumBytes: 512_000)) == expectedSHA256 else {
            throw ConduitOfflineFailure("input_identity_changed")
        }
        let service = ConduitFilesystemMutationService(receiptDirectory: URL(fileURLWithPath: marker.receiptDirectory))
        let result = service.mutate(arguments: .object([
            "operation_id": .string(UUID().uuidString), "project_slug": .string("offline-staged-project"),
            "path": .string(relativePath), "text": .string(replacement), "expected_sha256": .string(expectedSHA256),
        ]), root: stagedRoot, admitWrite: { nil })
        guard result["status"] as? String == "succeeded" else {
            throw ConduitOfflineFailure(result["error_code"] as? String ?? result["status"] as? String ?? "edit_outcome_unknown")
        }
        return try manifest(stagedRoot: stagedRoot)
    }

    private static func openStage(_ root: URL) throws -> (Int32, Marker) {
        let fd = try ConduitOfflineFS.openAbsolute(root.path, directory: true)
        do {
            let markerFD = try ConduitOfflineFS.openRelative(root: fd, path: markerName, directory: false)
            defer { close(markerFD) }
            let marker = try JSONDecoder().decode(Marker.self, from: ConduitOfflineFS.read(markerFD, maximumBytes: 16_384))
            let parentPath = root.deletingLastPathComponent().path
            guard marker.schemaVersion == "conduit-offline-workspace/v1",
                  marker.directoryIdentity == (try ConduitOfflineFS.identity(fd)),
                  marker.receiptDirectory.hasPrefix(parentPath + "/" + root.lastPathComponent + ".conduit-offline-receipts-"),
                  marker.receiptDirectory != root.path,
                  ConduitOfflinePreflight.validHash(marker.initialManifestSHA256),
                  ConduitOfflinePreflight.validHash(marker.sourceIdentity) else { throw ConduitOfflineFailure("invalid_staged_workspace") }
            _ = try ConduitOfflineFS.absoluteComponents(marker.receiptDirectory)
            return (fd, marker)
        } catch { close(fd); throw error }
    }

    private struct Budget { var files = 0; var bytes = 0; var entries = 0 }
    private static func collect(_ fd: Int32, sourceIdentity: String) throws -> ConduitOfflineManifest {
        var files: [ConduitOfflineManifest.Entry] = []; var directories: [String] = []; var budget = Budget()
        try walk(fd, prefix: "", depth: 0, budget: &budget, directories: &directories) { path, data, mode in
            files.append(.init(path: path, sha256: ConduitOfflineHash.bytes(data), byteCount: UInt64(data.count), posixMode: mode))
        }
        return try ConduitOfflineManifest(sourceIdentity: sourceIdentity, files: files, directories: directories)
    }
    private static func checkName(_ name: String) throws {
        guard name != markerName, !name.hasPrefix(".env"),
              ![".ssh", ".aws", ".config", ".codex", ".claude"].contains(name),
              !name.utf8.contains(where: { $0 < 32 || $0 == 127 }) else { throw ConduitOfflineFailure("protected_source_path") }
    }
    private static func walk(_ fd: Int32, prefix: String, depth: Int, budget: inout Budget,
                             directories: inout [String], visit: (String, Data, UInt16) throws -> Void) throws {
        guard depth <= 64 else { throw ConduitOfflineFailure("workspace_depth_limit") }
        for name in try ConduitOfflineFS.names(fd) {
            if excludedNames.contains(name) || (prefix.isEmpty && name == markerName) { continue }
            try checkName(name)
            budget.entries += 1
            guard budget.entries <= maximumFiles else { throw ConduitOfflineFailure("workspace_entry_limit") }
            let child = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard child >= 0 else { throw ConduitOfflineFailure("unsafe_source_entry") }
            defer { close(child) }
            let info = try ConduitOfflineFS.info(child)
            let path = prefix + name
            if info.st_mode & S_IFMT == S_IFDIR {
                directories.append(path)
                try walk(child, prefix: path + "/", depth: depth + 1, budget: &budget, directories: &directories, visit: visit)
            } else {
                let bytes = try ConduitOfflineFS.read(child, maximumBytes: maximumFileBytes)
                budget.files += 1; budget.bytes += bytes.count
                guard budget.files <= maximumFiles, budget.bytes <= maximumTotalBytes else { throw ConduitOfflineFailure("workspace_byte_limit") }
                try visit(path, bytes, UInt16(info.st_mode & mode_t(0o777)))
            }
        }
    }
    private static func copyTree(source: Int32, destination: Int32, depth: Int, budget: inout Budget, excludeStageMarker: Bool = false) throws {
        guard depth <= 64 else { throw ConduitOfflineFailure("workspace_depth_limit") }
        for name in try ConduitOfflineFS.names(source) {
            if excludedNames.contains(name) || (excludeStageMarker && depth == 0 && name == markerName) { continue }
            try checkName(name)
            budget.entries += 1
            guard budget.entries <= maximumFiles else { throw ConduitOfflineFailure("workspace_entry_limit") }
            let child = openat(source, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard child >= 0 else { throw ConduitOfflineFailure("unsafe_source_entry") }
            defer { close(child) }
            let info = try ConduitOfflineFS.info(child)
            if info.st_mode & S_IFMT == S_IFDIR {
                guard mkdirat(destination, name, mode_t(0o700)) == 0 else { throw ConduitOfflineFailure("stage_copy_failed") }
                let target = openat(destination, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard target >= 0 else { throw ConduitOfflineFailure("stage_copy_failed") }
                defer { close(target) }
                try copyTree(source: child, destination: target, depth: depth + 1, budget: &budget)
                guard fsync(target) == 0 else { throw ConduitOfflineFailure("stage_durability_unknown") }
            } else {
                let bytes = try ConduitOfflineFS.read(child, maximumBytes: maximumFileBytes)
                budget.files += 1; budget.bytes += bytes.count
                guard budget.files <= maximumFiles, budget.bytes <= maximumTotalBytes else { throw ConduitOfflineFailure("workspace_byte_limit") }
                try ConduitOfflineFS.writeExclusive(parent: destination, name: name, data: bytes, mode: info.st_mode & mode_t(0o777))
            }
        }
    }
}

/// Internal descriptor primitives shared by observation and VM configuration.
enum ConduitOfflineFS {
    static func relativeComponents(_ path: String) throws -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.hasPrefix("/"), !path.isEmpty, path.utf8.count <= 4096, !path.utf8.contains(0),
              parts.count <= 64, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw ConduitOfflineFailure("unsafe_path")
        }
        return parts
    }
    static func absoluteComponents(_ path: String) throws -> [String] {
        guard path.hasPrefix("/"), path != "/" else { throw ConduitOfflineFailure("unsafe_path") }
        return try relativeComponents(String(path.dropFirst()))
    }
    static func openAbsolute(_ path: String, directory: Bool) throws -> Int32 {
        let parts = try absoluteComponents(path)
        let root = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard root >= 0 else { throw ConduitOfflineFailure("path_unavailable") }
        defer { close(root) }
        return try openComponents(root: root, parts: parts, directory: directory)
    }
    static func openRelative(root: Int32, path: String, directory: Bool) throws -> Int32 {
        try openComponents(root: root, parts: relativeComponents(path), directory: directory)
    }
    private static func openComponents(root: Int32, parts: [String], directory: Bool) throws -> Int32 {
        var current = dup(root)
        guard current >= 0 else { throw ConduitOfflineFailure("path_unavailable") }
        do {
            for (index, component) in parts.enumerated() {
                let last = index == parts.count - 1
                let flags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | ((!last || directory) ? O_DIRECTORY : 0)
                let next = openat(current, component, flags)
                guard next >= 0 else { throw ConduitOfflineFailure("unsafe_or_missing_path") }
                close(current); current = next
            }
            return current
        } catch { close(current); throw error }
    }
    static func info(_ fd: Int32) throws -> stat {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw ConduitOfflineFailure("metadata_unavailable") }
        return value
    }
    static func identity(_ fd: Int32) throws -> String {
        let value = try info(fd)
        return "\(value.st_dev):\(value.st_ino)"
    }
    private static func same(_ a: stat, _ b: stat) -> Bool {
        #if canImport(Darwin)
        let times = a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
        #else
        let times = a.st_mtim.tv_sec == b.st_mtim.tv_sec && a.st_mtim.tv_nsec == b.st_mtim.tv_nsec && a.st_ctim.tv_sec == b.st_ctim.tv_sec && a.st_ctim.tv_nsec == b.st_ctim.tv_nsec
        #endif
        return a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size && a.st_mode == b.st_mode && a.st_nlink == b.st_nlink && times
    }
    private static func ordinary(_ value: stat) throws {
        guard value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1, value.st_uid == geteuid(),
              value.st_mode & mode_t(0o7000) == 0 else { throw ConduitOfflineFailure("ordinary_owned_file_required") }
    }
    static func read(_ fd: Int32, maximumBytes: Int) throws -> Data {
        let before = try info(fd); try ordinary(before)
        guard before.st_size >= 0, UInt64(before.st_size) <= UInt64(maximumBytes) else { throw ConduitOfflineFailure("file_byte_limit") }
        var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 65_536)
        while bytes.count <= maximumBytes {
            let count = buffer.withUnsafeMutableBytes { buffer in
                systemRead(fd, buffer.baseAddress!, min(buffer.count, maximumBytes + 1 - bytes.count))
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw ConduitOfflineFailure("read_failed") }
            if count == 0 { break }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        guard bytes.count <= maximumBytes, same(before, try info(fd)) else { throw ConduitOfflineFailure("file_changed_or_oversized") }
        return bytes
    }
    static func readAbsolute(_ path: String, maximumBytes: Int) throws -> Data {
        let fd = try openAbsolute(path, directory: false); defer { close(fd) }
        return try read(fd, maximumBytes: maximumBytes)
    }
    static func asset(at path: String, maximumBytes: UInt64) throws -> ConduitOfflineAsset {
        let fd = try openAbsolute(path, directory: false); defer { close(fd) }
        let before = try info(fd); try ordinary(before)
        guard before.st_size > 0 else { throw ConduitOfflineFailure("empty_asset") }
        // Check the actual descriptor metadata before the first byte is read;
        // a request's claimed byte count cannot enlarge this scan budget.
        guard UInt64(before.st_size) <= maximumBytes else { throw ConduitOfflineFailure("asset_byte_limit") }
        var hasher = SHA256(); var count: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = buffer.withUnsafeMutableBytes { systemRead(fd, $0.baseAddress!, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n >= 0 else { throw ConduitOfflineFailure("read_failed") }
            if n == 0 { break }
            count += UInt64(n)
            guard count <= UInt64(before.st_size), count <= maximumBytes else { throw ConduitOfflineFailure("asset_identity_changed") }
            hasher.update(data: Data(buffer.prefix(n)))
        }
        guard count == UInt64(before.st_size), same(before, try info(fd)) else { throw ConduitOfflineFailure("asset_identity_changed") }
        return ConduitOfflineAsset(path: path, sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(), byteCount: count)
    }
    static func names(_ fd: Int32) throws -> [String] {
        // A separately opened directory description avoids advancing fd's own
        // enumeration offset, so repeated before/after observations are real.
        let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard copy >= 0 else { throw ConduitOfflineFailure("directory_unavailable") }
        guard let stream = fdopendir(copy) else { close(copy); throw ConduitOfflineFailure("directory_unavailable") }
        defer { closedir(stream) }
        var result: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            let capacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            if name != "." && name != ".." { result.append(name) }
            guard result.count <= ConduitOfflineWorkspace.maximumFiles else { throw ConduitOfflineFailure("workspace_entry_limit") }
            errno = 0
        }
        guard errno == 0 else { throw ConduitOfflineFailure("directory_read_failed") }
        return result.sorted()
    }
    static func writeExclusive(parent: Int32, name: String, data: Data, mode: mode_t) throws {
        let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw ConduitOfflineFailure("exclusive_write_failed") }
        defer { close(fd) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { throw ConduitOfflineFailure("write_failed") }
                offset += n
            }
        }
        guard fchmod(fd, mode) == 0, fsync(fd) == 0 else { throw ConduitOfflineFailure("write_durability_unknown") }
    }
    private static func systemRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        Darwin.read(fd, buffer, count)
        #else
        Glibc.read(fd, buffer, count)
        #endif
    }
}
