import Darwin
import Foundation

/// Descriptor-anchored reader for the exact-file adapter. Checks detect path
/// replacement and observable mutation during two bounded read passes. This is
/// an observation boundary, not filesystem transaction or adversarial tamper
/// authenticity: a writer that restores all observable state cannot be ruled out.
final class ContextFileSourceReader {
    let canonicalRootPath: String
    private let rootPath: String
    private let rootDescriptor: Int32
    private let rootIdentity: stat

    init(root: URL) throws {
        guard root.isFileURL else {
            throw ContextFileSourceFailure(.unsafePath, detail: "Selected root must be a file URL.")
        }
        let path = root.standardizedFileURL.path
        var lexical = stat()
        guard path.withCString({ lstat($0, &lexical) }) == 0 else { throw Self.failure(errno) }
        guard Self.kind(lexical) != S_IFLNK else {
            throw ContextFileSourceFailure(.symbolicLink, detail: "Selected root is a symbolic link.")
        }
        let descriptor = path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else { throw Self.failure(errno) }
        do {
            var identity = stat()
            guard fstat(descriptor, &identity) == 0 else { throw Self.failure(errno) }
            guard Self.kind(identity) == S_IFDIR, Self.sameObject(lexical, identity) else {
                throw ContextFileSourceFailure(.changedDuringRead, detail: "Selected root changed while opening.")
            }
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            let canonical = path.withCString { input in
                buffer.withUnsafeMutableBufferPointer { realpath(input, $0.baseAddress) != nil }
            }
            guard canonical else { throw Self.failure(errno) }
            let canonicalPath = String(cString: buffer)
            // Finish every throwing check before initializing all stored
            // properties, so a failed initializer has exactly one FD closer.
            try Self.verifyRoot(path: path, canonicalPath: canonicalPath, identity: identity)
            canonicalRootPath = canonicalPath
            rootPath = path
            rootDescriptor = descriptor
            rootIdentity = identity
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    deinit { Darwin.close(rootDescriptor) }

    func read(
        relativePath: String, maximumBytes: Int, reserveBytes: (Int) -> Void,
        afterFirstRead: ((String) -> Void)?
    ) throws -> Data {
        try verifyRoot()
        let components = relativePath.split(separator: "/").map(String.init)
        var parent = rootDescriptor
        var owned: [Int32] = []
        var bindings: [(parent: Int32, name: String, identity: stat)] = []
        defer { for descriptor in owned.reversed() { Darwin.close(descriptor) } }

        for (index, component) in components.enumerated() {
            let isLeaf = index == components.count - 1
            var lexical = stat()
            guard component.withCString({ fstatat(parent, $0, &lexical, AT_SYMLINK_NOFOLLOW) }) == 0 else {
                throw Self.failure(errno)
            }
            guard Self.kind(lexical) != S_IFLNK else {
                throw ContextFileSourceFailure(.symbolicLink, detail: "Source path contains a symbolic link.")
            }
            let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | (isLeaf ? 0 : O_DIRECTORY)
            let descriptor = component.withCString { Darwin.openat(parent, $0, flags) }
            guard descriptor >= 0 else { throw Self.failure(errno) }
            owned.append(descriptor)
            var identity = stat()
            guard fstat(descriptor, &identity) == 0 else { throw Self.failure(errno) }
            guard Self.sameObject(lexical, identity) else {
                throw ContextFileSourceFailure(.changedDuringRead, detail: "Source path changed while opening.")
            }
            guard Self.kind(identity) == (isLeaf ? S_IFREG : S_IFDIR) else {
                throw ContextFileSourceFailure(isLeaf ? .notRegularFile : .notDirectory, detail: "Source path has the wrong filesystem kind.")
            }
            bindings.append((parent, component, identity))
            parent = descriptor
        }
        let descriptor = parent
        var before = stat()
        guard fstat(descriptor, &before) == 0 else { throw Self.failure(errno) }
        guard before.st_size >= 0, before.st_size <= maximumBytes else {
            throw ContextFileSourceFailure(.fileByteLimitExceeded, detail: "Source exceeds the bounded file byte limit.")
        }
        reserveBytes(Int(before.st_size))
        let first = try Self.readBytes(descriptor, count: Int(before.st_size))
        afterFirstRead?(relativePath)
        var middle = stat()
        guard fstat(descriptor, &middle) == 0 else { throw Self.failure(errno) }
        guard Self.sameReadState(before, middle) else {
            throw ContextFileSourceFailure(.changedDuringRead, detail: "Source changed between bounded read passes.")
        }
        let second = try Self.readBytes(descriptor, count: Int(before.st_size))
        var after = stat()
        guard fstat(descriptor, &after) == 0 else { throw Self.failure(errno) }
        guard first == second, Self.sameReadState(before, after) else {
            throw ContextFileSourceFailure(.changedDuringRead, detail: "Source bytes or identity changed during observation.")
        }
        for binding in bindings {
            var current = stat()
            guard binding.name.withCString({ fstatat(binding.parent, $0, &current, AT_SYMLINK_NOFOLLOW) }) == 0,
                  Self.sameObject(current, binding.identity), Self.kind(current) == Self.kind(binding.identity) else {
                throw ContextFileSourceFailure(.changedDuringRead, detail: "Source path binding changed during observation.")
            }
        }
        try verifyRoot()
        return first
    }

    private func verifyRoot() throws {
        try Self.verifyRoot(path: rootPath, canonicalPath: canonicalRootPath, identity: rootIdentity)
    }

    private static func verifyRoot(path: String, canonicalPath: String, identity: stat) throws {
        var lexical = stat()
        guard path.withCString({ lstat($0, &lexical) }) == 0,
              Self.kind(lexical) == S_IFDIR, Self.sameObject(lexical, identity) else {
            throw ContextFileSourceFailure(.changedDuringRead, detail: "Selected root binding changed.")
        }
        var canonical = stat()
        guard canonicalPath.withCString({ lstat($0, &canonical) }) == 0,
              Self.kind(canonical) == S_IFDIR, Self.sameObject(canonical, identity) else {
            throw ContextFileSourceFailure(.changedDuringRead, detail: "Canonical root binding changed.")
        }
    }

    private static func readBytes(_ descriptor: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let size = data.withUnsafeMutableBytes { buffer in
                pread(descriptor, buffer.baseAddress!.advanced(by: offset), min(65_536, count - offset), off_t(offset))
            }
            if size < 0 {
                if errno == EINTR { continue }
                throw failure(errno)
            }
            guard size > 0 else {
                throw ContextFileSourceFailure(.changedDuringRead, detail: "Source ended before its observed size.")
            }
            offset += size
        }
        var extra: UInt8 = 0
        let size = pread(descriptor, &extra, 1, off_t(count))
        guard size == 0 else {
            throw ContextFileSourceFailure(.changedDuringRead, detail: "Source size changed during the bounded read.")
        }
        return data
    }

    private static func kind(_ value: stat) -> mode_t { value.st_mode & S_IFMT }
    private static func sameObject(_ left: stat, _ right: stat) -> Bool {
        left.st_dev == right.st_dev && left.st_ino == right.st_ino
    }
    private static func sameReadState(_ left: stat, _ right: stat) -> Bool {
        sameObject(left, right) && left.st_mode == right.st_mode && left.st_size == right.st_size
            && left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec
            && left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec
            && left.st_ctimespec.tv_sec == right.st_ctimespec.tv_sec
            && left.st_ctimespec.tv_nsec == right.st_ctimespec.tv_nsec
    }
    private static func failure(_ code: Int32) -> ContextFileSourceFailure {
        switch code {
        case ENOENT: return .init(.missing, detail: "Source filesystem object is missing.")
        case ELOOP: return .init(.symbolicLink, detail: "Source path is a symbolic link.")
        case ENOTDIR: return .init(.notDirectory, detail: "Source ancestor is not a directory.")
        default: return .init(.readFailed, detail: "Filesystem read failed with errno \(code).")
        }
    }
}
