import Foundation

public struct MainframeDocumentRecord: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let zone: MainframeExplorerZone
    public let recordScope: MainframeExplorerRecordScope?
    public let text: String
    public let byteCount: Int
    public let markdown: MainframeMarkdownDocument?

    public init(
        path: String,
        name: String,
        zone: MainframeExplorerZone,
        recordScope: MainframeExplorerRecordScope?,
        text: String,
        byteCount: Int,
        markdown: MainframeMarkdownDocument?
    ) {
        self.path = path
        self.name = name
        self.zone = zone
        self.recordScope = recordScope
        self.text = text
        self.byteCount = byteCount
        self.markdown = markdown
    }
}

public struct MainframeContentIndex: Sendable {
    public let records: [MainframeDocumentRecord]
    public let filesystemEntries: [MainframeExplorerNode]
    public let filesystemIndexTruncated: Bool
    public let contentTruncated: Bool
    public let bytesIndexed: Int
    public let skippedNonText: Int
    public let skippedTooLarge: Int

    public init(
        records: [MainframeDocumentRecord],
        filesystemEntries: [MainframeExplorerNode],
        filesystemIndexTruncated: Bool,
        contentTruncated: Bool,
        bytesIndexed: Int,
        skippedNonText: Int,
        skippedTooLarge: Int
    ) {
        self.records = records
        self.filesystemEntries = filesystemEntries
        self.filesystemIndexTruncated = filesystemIndexTruncated
        self.contentTruncated = contentTruncated
        self.bytesIndexed = bytesIndexed
        self.skippedNonText = skippedNonText
        self.skippedTooLarge = skippedTooLarge
    }

    public var markdownDocuments: [String: MainframeMarkdownDocument] {
        Dictionary(uniqueKeysWithValues: records.compactMap { record in
            record.markdown.map { (record.path, $0) }
        })
    }

    public var linkIndex: MainframeLinkIndex {
        MainframeLinkIndex.build(documents: markdownDocuments)
    }

    public var mayBeIncomplete: Bool { filesystemIndexTruncated || contentTruncated }
}

/// Bounded ephemeral corpus over the same read-only scanner used by Explorer.
/// It does not persist an index and never follows symbolic links.
public struct MainframeContentIndexer: Sendable {
    public let maxEntries: Int
    public let maxFileBytes: Int
    public let maxTotalBytes: Int

    public init(maxEntries: Int = 20_000, maxFileBytes: Int = 512_000, maxTotalBytes: Int = 64_000_000) {
        self.maxEntries = max(1, maxEntries)
        self.maxFileBytes = max(1, maxFileBytes)
        self.maxTotalBytes = max(1, maxTotalBytes)
    }

    public func build(root: URL) throws -> MainframeContentIndex {
        let scanner = MainframeExplorerScanner()
        let filesystem = try scanner.buildIndex(root: root, maxEntries: maxEntries)
        var records: [MainframeDocumentRecord] = []
        var bytesIndexed = 0
        var skippedNonText = 0
        var skippedTooLarge = 0
        var contentTruncated = false

        for node in filesystem.entries where node.kind == .file {
            do {
                let text = try scanner.readUTF8Text(root: root, file: node.url, maxBytes: maxFileBytes)
                let bytes = text.utf8.count
                if bytesIndexed + bytes > maxTotalBytes {
                    contentTruncated = true
                    break
                }
                bytesIndexed += bytes
                let ext = node.url.pathExtension.lowercased()
                let markdown = ["md", "markdown", "mdown", "mkd"].contains(ext)
                    ? MainframeMarkdownParser.parse(text)
                    : nil
                records.append(MainframeDocumentRecord(
                    path: node.relativePath,
                    name: node.name,
                    zone: node.zone,
                    recordScope: node.recordScope,
                    text: text,
                    byteCount: bytes,
                    markdown: markdown
                ))
            } catch MainframeExplorerError.nonUTF8 {
                skippedNonText += 1
            } catch MainframeExplorerError.fileTooLarge {
                skippedTooLarge += 1
            }
        }

        return MainframeContentIndex(
            records: records,
            filesystemEntries: filesystem.entries,
            filesystemIndexTruncated: filesystem.truncated,
            contentTruncated: contentTruncated,
            bytesIndexed: bytesIndexed,
            skippedNonText: skippedNonText,
            skippedTooLarge: skippedTooLarge
        )
    }
}
