import Darwin
import Foundation

public enum SessionAPIContentLength: Equatable, Sendable {
    case absent
    case valid(Int)
    case invalid
}

/// Small, transport-specific helpers shared by the app listener and Core tests.
///
/// These helpers deliberately do not decide MCP semantics or caller authority.
public enum SessionAPITransportSecurity {
    public static func exactBearerAuthorization(
        headerLines: [String],
        token: String
    ) -> Bool {
        let authorizationValues = headerLines.compactMap { line -> String? in
            guard let separator = line.firstIndex(of: ":") else { return nil }
            let name = line[..<separator]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.caseInsensitiveCompare("Authorization") == .orderedSame else {
                return nil
            }
            return String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard authorizationValues.count == 1,
              !token.isEmpty
        else {
            return false
        }

        let parts = authorizationValues[0].split(
            maxSplits: 1,
            omittingEmptySubsequences: true,
            whereSeparator: { $0 == " " || $0 == "\t" }
        )
        guard parts.count == 2,
              parts[0].caseInsensitiveCompare("Bearer") == .orderedSame
        else {
            return false
        }
        return String(parts[1]) == token
    }

    public static func contentLength(
        headerLines: [String],
        maximum: Int
    ) -> SessionAPIContentLength {
        let values = headerLines.compactMap { line -> String? in
            guard let separator = line.firstIndex(of: ":") else { return nil }
            let name = line[..<separator]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.caseInsensitiveCompare("Content-Length") == .orderedSame else {
                return nil
            }
            return String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !values.isEmpty else { return .absent }
        guard values.count == 1,
              !values[0].isEmpty,
              values[0].allSatisfy({ $0.isNumber }),
              let length = Int(values[0]),
              length <= maximum
        else {
            return .invalid
        }
        return .valid(length)
    }

    public static func hasTransferEncoding(headerLines: [String]) -> Bool {
        headerLines.contains { line in
            guard let separator = line.firstIndex(of: ":") else { return false }
            return line[..<separator]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("Transfer-Encoding") == .orderedSame
        }
    }

    public static func loadOrCreateToken(at url: URL) throws -> String {
        let manager = FileManager.default
        try manager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if manager.fileExists(atPath: url.path) {
            try protectTokenFile(at: url)
            let existing = try String(contentsOf: url, encoding: .utf8)
            let token = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                return token
            }
        }

        let token = UUID().uuidString.lowercased()
        let data = Data(token.utf8)
        let descriptor = url.path.withCString {
            Darwin.open(
                $0,
                O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = Darwin.close(descriptor) }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0
        else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var written = 0
        try data.withUnsafeBytes { raw in
            while written < data.count {
                let count = Darwin.write(
                    descriptor,
                    raw.baseAddress!.advanced(by: written),
                    data.count - written
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                written += count
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return token
    }

    private static func protectTokenFile(at url: URL) throws {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = Darwin.close(descriptor) }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0
        else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
