import Foundation

public extension GitWorkspaceInspector {
    /// Returns the Git blob identity of the current on-disk bytes without
    /// writing an object into the repository. This is useful for context
    /// snapshots because a dirty working-tree file must not be labelled with the
    /// blob identity from HEAD.
    func workingTreeBlobIdentity(
        startingAt location: URL,
        relativePath: String
    ) throws -> String? {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.split(separator: "/").contains("..") else {
            throw GitWorkspaceInspectorError.gitUnavailable(
                "Refusing non-relative inspection path: \(relativePath)"
            )
        }

        let snapshot = try snapshot(startingAt: location)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "git", "-C", snapshot.repositoryRoot,
            "hash-object", "--no-filters", "--", trimmed
        ]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "LC_ALL": "C",
            "LANG": "C",
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_TERMINAL_PROMPT": "0"
        ]) { _, new in new }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw GitWorkspaceInspectorError.gitUnavailable(error.localizedDescription)
        }
        process.waitUntilExit()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: errorData, as: UTF8.self)
            // A path that does not exist is absence of an identity, not a reason
            // to invent one. Other command failures remain visible.
            if detail.localizedCaseInsensitiveContains("could not open")
                || detail.localizedCaseInsensitiveContains("no such file") {
                return nil
            }
            throw GitWorkspaceInspectorError.commandFailed(
                arguments: ["hash-object", "--no-filters", "--", trimmed],
                status: process.terminationStatus,
                stderr: detail
            )
        }
        let identity = String(decoding: output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return identity.isEmpty ? nil : identity
    }
}
