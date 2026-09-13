import Foundation

public struct MainframeMarkdownHeading: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let level: Int
    public let text: String
    public let line: Int

    public init(id: String, level: Int, text: String, line: Int) {
        self.id = id
        self.level = level
        self.text = text
        self.line = line
    }
}

public struct MainframeMarkdownLink: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let target: String
    public let line: Int
    public let isImage: Bool

    public init(id: String, label: String, target: String, line: Int, isImage: Bool = false) {
        self.id = id
        self.label = label
        self.target = target
        self.line = line
        self.isImage = isImage
    }
}

public struct MainframeMarkdownTable: Equatable, Sendable {
    public let headers: [String]
    public let rows: [[String]]

    public init(headers: [String], rows: [[String]]) {
        self.headers = headers
        self.rows = rows
    }
}

public enum MainframeMarkdownBlock: Equatable, Sendable {
    case heading(MainframeMarkdownHeading)
    case paragraph(String)
    case unorderedList([String])
    case orderedList([String])
    case blockquote(String)
    case fencedCode(language: String?, text: String)
    case table(MainframeMarkdownTable)
    case horizontalRule
}

public struct MainframeMarkdownDocument: Equatable, Sendable {
    public let source: String
    public let frontmatter: [String: String]
    public let blocks: [MainframeMarkdownBlock]
    public let headings: [MainframeMarkdownHeading]
    public let links: [MainframeMarkdownLink]

    public init(
        source: String,
        frontmatter: [String: String],
        blocks: [MainframeMarkdownBlock],
        headings: [MainframeMarkdownHeading],
        links: [MainframeMarkdownLink]
    ) {
        self.source = source
        self.frontmatter = frontmatter
        self.blocks = blocks
        self.headings = headings
        self.links = links
    }
}
