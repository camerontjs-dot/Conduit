import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum MainframeExplorerPreviewError: LocalizedError, Equatable {
    case pathIdentityMismatch(String)
    case unavailable(path: String, code: Int32)
    case changedDuringRead(String)
    case binaryText(String)

    public var errorDescription: String? {
        switch self {
        case .pathIdentityMismatch(let path):
            return "The preview URL does not identify the exact selected path: \(path)"
        case .unavailable(let path, let code):
            return "The selected preview file is unavailable (filesystem error \(code)): \(path)"
        case .changedDuringRead(let path):
            return "The selected file changed while it was being read. Reload the preview: \(path)"
        case .binaryText(let path):
            return "The selected file contains binary control bytes and cannot be shown as text: \(path)"
        }
    }
}

/// Read one exact regular file into a bounded snapshot for native decoders.
/// Each descendant is opened relative to the held root descriptor with
/// O_NOFOLLOW; native image/PDF readers receive bytes, never a second URL read.
public struct MainframeExplorerPreviewLoader: Sendable {
    public static let mediaByteLimit = 64 * 1_024 * 1_024

    public init() {}

    public func byteCount(root: URL, node: MainframeExplorerNode) throws -> Int64 {
        let fd = try openExactFile(root: root, node: node)
        defer { close(fd) }
        return try regularFileStat(fd: fd, path: node.relativePath).st_size
    }

    public func read(root: URL, node: MainframeExplorerNode, maxBytes: Int = mediaByteLimit) throws -> Data {
        let fd = try openExactFile(root: root, node: node)
        defer { close(fd) }
        let before = try regularFileStat(fd: fd, path: node.relativePath)
        let limit = max(1, maxBytes)
        guard before.st_size <= Int64(limit) else {
            throw MainframeExplorerError.fileTooLarge(path: node.relativePath, bytes: Int(before.st_size), limit: limit)
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes { storage in
                systemRead(fd, storage.baseAddress!, storage.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw MainframeExplorerPreviewError.unavailable(path: node.relativePath, code: errno)
            }
            if count == 0 { break }
            guard data.count <= limit - count else {
                throw MainframeExplorerError.fileTooLarge(path: node.relativePath, bytes: data.count + count, limit: limit)
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        let after = try regularFileStat(fd: fd, path: node.relativePath)
        guard before.st_size == after.st_size,
              before.st_size == Int64(data.count),
              modificationStamp(before) == modificationStamp(after) else {
            throw MainframeExplorerPreviewError.changedDuringRead(node.relativePath)
        }
        return data
    }

    public func readUTF8Text(root: URL, node: MainframeExplorerNode, maxBytes: Int = 2_000_000) throws -> String {
        let data = try read(root: root, node: node, maxBytes: maxBytes)
        guard let text = String(data: data, encoding: .utf8) else {
            throw MainframeExplorerError.nonUTF8(node.relativePath)
        }
        guard !data.contains(where: { ($0 < 32 && ![9, 10, 12, 13].contains($0)) || $0 == 127 }) else {
            throw MainframeExplorerPreviewError.binaryText(node.relativePath)
        }
        return text
    }

    private func openExactFile(root: URL, node: MainframeExplorerNode) throws -> Int32 {
        guard node.kind == .file else { throw MainframeExplorerError.notFile(node.relativePath) }
        let parts = node.relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard root.isFileURL, node.url.isFileURL, !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw MainframeExplorerError.unsafePath(node.relativePath)
        }
        let lexicalRoot = root.standardizedFileURL
        var rootStat = stat()
        guard lstat(lexicalRoot.path, &rootStat) == 0 else {
            throw MainframeExplorerError.missingRoot(root.path)
        }
        guard (rootStat.st_mode & mode_t(S_IFMT)) != mode_t(S_IFLNK) else {
            throw MainframeExplorerError.symbolicLinkTraversal(root.path)
        }
        guard let resolved = realpath(lexicalRoot.path, nil) else {
            throw MainframeExplorerError.missingRoot(root.path)
        }
        let canonicalRoot = URL(fileURLWithPath: String(cString: resolved))
        free(resolved)
        let supplied = node.url.standardizedFileURL.path
        guard supplied == lexicalRoot.appendingPathComponent(node.relativePath).standardizedFileURL.path
                || supplied == canonicalRoot.appendingPathComponent(node.relativePath).standardizedFileURL.path else {
            throw MainframeExplorerPreviewError.pathIdentityMismatch(node.relativePath)
        }
        var parent = open(canonicalRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else {
            throw MainframeExplorerPreviewError.unavailable(path: node.relativePath, code: errno)
        }
        defer { close(parent) }
        for component in parts.dropLast() {
            let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw openError(parent: parent, component: component, path: node.relativePath) }
            close(parent)
            parent = next
        }
        let fd = openat(parent, parts.last!, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw openError(parent: parent, component: parts.last!, path: node.relativePath) }
        return fd
    }

    private func openError(parent: Int32, component: String, path: String) -> Error {
        let code = errno
        var value = stat()
        if fstatat(parent, component, &value, AT_SYMLINK_NOFOLLOW) == 0,
           (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) {
            return MainframeExplorerError.symbolicLinkTraversal(path)
        }
        return MainframeExplorerPreviewError.unavailable(path: path, code: code)
    }

    private func regularFileStat(fd: Int32, path: String) throws -> stat {
        var value = stat()
        guard fstat(fd, &value) == 0 else {
            throw MainframeExplorerPreviewError.unavailable(path: path, code: errno)
        }
        guard (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw MainframeExplorerError.notFile(path)
        }
        return value
    }

    private func modificationStamp(_ value: stat) -> [Int] {
        #if canImport(Darwin)
        return [value.st_mtimespec.tv_sec, value.st_mtimespec.tv_nsec, value.st_ctimespec.tv_sec, value.st_ctimespec.tv_nsec]
        #else
        return [value.st_mtim.tv_sec, value.st_mtim.tv_nsec, value.st_ctim.tv_sec, value.st_ctim.tv_nsec]
        #endif
    }

    private func systemRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.read(fd, buffer, count)
        #else
        return Glibc.read(fd, buffer, count)
        #endif
    }
}
