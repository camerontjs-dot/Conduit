import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// One explicit process boundary for an owned qualification app. Parsing never
/// falls back to operator defaults after either qualification variable is set.
public struct ConduitInstanceConfiguration: Equatable, Sendable {
    public let stateDirectory: URL
    public let sessionAPIPort: Int
    public let isQualification: Bool
    public static let qualificationPorts = 18750...18849
    public static let rootMarkerName = "qualification-root.json"

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> Self {
        let root = environment["CONDUIT_QUALIFICATION_ROOT"]
        let rawPort = environment["CONDUIT_SESSION_API_PORT"]
        if root == nil && rawPort == nil {
            return Self(stateDirectory: home.appendingPathComponent(".conduit", isDirectory: true), sessionAPIPort: ConduitSessionAPI.loopbackPort, isQualification: false)
        }
        guard let root, let rawPort, !root.isEmpty, root.hasPrefix("/"),
              let port = Int(rawPort), String(port) == rawPort,
              qualificationPorts.contains(port) else {
            throw ConfigurationError("Qualification requires an absolute CONDUIT_QUALIFICATION_ROOT and canonical CONDUIT_SESSION_API_PORT in 18750...18849.")
        }
        let url = URL(fileURLWithPath: root, isDirectory: true)
        let homePath = home.path
        let operatorPath = home.appendingPathComponent(".conduit").path
        guard root == url.path, url.path != "/", url.path != homePath,
              url.path != operatorPath, !url.path.hasPrefix(operatorPath + "/"),
              try canonicalPOSIXPath(root) == root else {
            throw ConfigurationError("Qualification root must be canonical, separate from operator state, and free of symlink ancestors.")
        }
        return Self(stateDirectory: url, sessionAPIPort: port, isQualification: true)
    }

    /// Foundation file-URL normalization can choose a display alias for an
    /// existing macOS temporary path. Filesystem ownership uses POSIX realpath,
    /// including the deepest existing ancestor when the final root is new.
    public static func canonicalPOSIXPath(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.contains("\0"),
              path == "/" || (!path.hasSuffix("/") && !path.contains("//")),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw ConfigurationError("Qualification path is not lexically canonical.")
        }
        var existing = path
        var suffix: [String] = []
        var attributes = stat()
        while lstat(existing, &attributes) != 0 {
            guard errno == ENOENT, existing != "/" else {
                throw ConfigurationError("Could not inspect qualification path ancestor.")
            }
            let components = existing.split(separator: "/").map(String.init)
            guard let last = components.last else { throw ConfigurationError("Invalid qualification path.") }
            suffix.insert(last, at: 0)
            existing = components.count == 1 ? "/" : "/" + components.dropLast().joined(separator: "/")
        }
        guard let pointer = realpath(existing, nil) else {
            throw ConfigurationError("Qualification path has an unresolved filesystem identity.")
        }
        let base = String(cString: pointer)
        free(pointer)
        return suffix.reduce(base) { ($0 == "/" ? "" : $0) + "/" + $1 }
    }

    public func containsOwnedURL(_ url: URL) -> Bool {
        guard isQualification else { return true }
        guard let path = try? Self.canonicalPOSIXPath(url.path) else { return false }
        return path.hasPrefix(stateDirectory.path + "/")
    }

    public func stateURL(_ component: String, isDirectory: Bool = false) -> URL {
        precondition(!component.contains("/") && component != "." && component != ".." && !component.isEmpty)
        return stateDirectory.appendingPathComponent(component, isDirectory: isDirectory)
    }

    /// Only a new/empty root or a previously marked qualification root may be
    /// opened. Existing foreign files, symlinks and hard links are not adopted.
    public func prepareQualificationStateRoot(fileManager: FileManager = .default) throws {
        guard isQualification else { return }
        guard try Self.canonicalPOSIXPath(stateDirectory.path) == stateDirectory.path else {
            throw ConfigurationError("Qualification root acquired a symlink.")
        }
        let marker = stateURL(Self.rootMarkerName)
        if fileManager.fileExists(atPath: stateDirectory.path) {
            let attributes = try fileManager.attributesOfItem(atPath: stateDirectory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
                throw ConfigurationError("Qualification root is not an owned directory.")
            }
            let children = try fileManager.contentsOfDirectory(atPath: stateDirectory.path)
            if !children.isEmpty {
                try validateOwnedTree(fileManager: fileManager)
                let data = try Data(contentsOf: marker)
                let value = try JSONDecoder().decode(RootMarker.self, from: data)
                guard value.schema_version == 1,
                      value.kind == "conduit_qualification",
                      value.root == stateDirectory.path else {
                    throw ConfigurationError("Existing state lacks the exact qualification root marker.")
                }
                return
            }
        } else {
            try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateDirectory.path)
        let data = try JSONSerialization.data(withJSONObject: ["schema_version": 1, "kind": "conduit_qualification", "root": stateDirectory.path], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: marker, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
    }

    private func validateOwnedTree(fileManager: FileManager) throws {
        guard let enumerator = fileManager.enumerator(at: stateDirectory, includingPropertiesForKeys: nil) else {
            throw ConfigurationError("Could not inspect qualification state.")
        }
        var count = 0
        for case let url as URL in enumerator {
            count += 1
            guard count <= 10_000 else { throw ConfigurationError("Qualification state inspection exceeded its bound.") }
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            let type = attributes[.type] as? FileAttributeType
            guard type == .typeDirectory || type == .typeRegular,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  type != .typeRegular || (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else {
                throw ConfigurationError("Qualification state contains a foreign, linked or nonregular artifact.")
            }
        }
    }

    private struct RootMarker: Decodable {
        let schema_version: Int
        let kind: String
        let root: String
    }

    private static var rootLease: Int32 = -1
    public static let current: Self = {
        do {
            let value = try resolve()
            try value.prepareQualificationStateRoot()
            if value.isQualification {
                let path = value.stateURL("qualification-owner.lock").path
                let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw ConfigurationError("Could not open qualification root lease.") }
                guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                    close(fd)
                    throw ConfigurationError("Another process owns this qualification root.")
                }
                rootLease = fd // process lifetime, close-on-exec; never a provider lease
            }
            return value
        } catch {
            fputs("Conduit configuration refused: \(error.localizedDescription)\n", stderr)
            exit(78)
        }
    }()

    public struct ConfigurationError: LocalizedError {
        public let detail: String
        public init(_ detail: String) { self.detail = detail }
        public var errorDescription: String? { detail }
    }
}
