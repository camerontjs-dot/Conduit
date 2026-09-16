import Foundation

public enum MainframeTextEditError: LocalizedError, Equatable {
    case conflict(String)
    case newContentTooLarge(path: String, bytes: Int, limit: Int)

    public var errorDescription: String? {
        switch self {
        case .conflict(let path):
            return "The file changed on disk after editing began. Reload before saving: \(path)"
        case .newContentTooLarge(let path, let bytes, let limit):
            return "Edited content is too large to save (\(bytes) bytes; limit \(limit)): \(path)"
        }
    }
}

/// Bounded exact-file UTF-8 writer shared by Explorer and the Context IDE.
///
/// Editability is a caller policy. This writer supplies the mutation boundary:
/// the caller names one exact file and the exact source text observed when the
/// edit buffer was opened. Save re-reads that authoritative file immediately
/// before replacement and refuses to write if the source changed. Replacement
/// is staged in the same directory and performed through FileManager's item
/// replacement so a failed staging/replacement does not intentionally mutate
/// adjacent files.
public struct MainframeTextFileWriter: @unchecked Sendable {
    private let fileManager: FileManager
    private let scanner: MainframeExplorerScanner

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.scanner = MainframeExplorerScanner(fileManager: fileManager)
    }

    public func saveUTF8Text(
        root: URL,
        file: URL,
        expectedSource: String,
        newSource: String,
        maxBytes: Int = 2_000_000
    ) throws {
        let limit = max(1, maxBytes)
        let bytes = Data(newSource.utf8)
        guard bytes.count <= limit else {
            throw MainframeTextEditError.newContentTooLarge(
                path: file.path,
                bytes: bytes.count,
                limit: limit
            )
        }

        let observed = try scanner.readUTF8Text(root: root, file: file, maxBytes: limit)
        guard observed == expectedSource else {
            throw MainframeTextEditError.conflict(file.path)
        }

        let parent = file.standardizedFileURL.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(
            ".\(file.lastPathComponent).conduit-edit-\(UUID().uuidString).tmp"
        )
        defer { try? fileManager.removeItem(at: temporary) }

        try bytes.write(to: temporary, options: [.atomic])

        // Re-check after staging to narrow the window in which an external
        // writer could otherwise be silently overwritten.
        let immediatelyBeforeReplace = try scanner.readUTF8Text(
            root: root,
            file: file,
            maxBytes: limit
        )
        guard immediatelyBeforeReplace == expectedSource else {
            throw MainframeTextEditError.conflict(file.path)
        }

        _ = try fileManager.replaceItemAt(
            file.standardizedFileURL,
            withItemAt: temporary,
            backupItemName: nil,
            options: []
        )
    }
}
