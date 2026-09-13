import Foundation

public enum MainframeResolvedLink: Equatable, Sendable {
    case local(path: String, anchor: String?)
    case sameDocumentAnchor(String)
    case external(String)
    case unresolved(String)
}

public struct MainframeDocumentLinkRecord: Identifiable, Equatable, Sendable {
    public var id: String { "\(sourcePath):\(link.id)" }
    public let sourcePath: String
    public let link: MainframeMarkdownLink
    public let resolution: MainframeResolvedLink

    public init(sourcePath: String, link: MainframeMarkdownLink, resolution: MainframeResolvedLink) {
        self.sourcePath = sourcePath
        self.link = link
        self.resolution = resolution
    }
}

public struct MainframeLinkIndex: Sendable {
    public let outgoing: [String: [MainframeDocumentLinkRecord]]
    public let incoming: [String: [MainframeDocumentLinkRecord]]
    public let unresolved: [MainframeDocumentLinkRecord]

    public init(
        outgoing: [String: [MainframeDocumentLinkRecord]],
        incoming: [String: [MainframeDocumentLinkRecord]],
        unresolved: [MainframeDocumentLinkRecord]
    ) {
        self.outgoing = outgoing
        self.incoming = incoming
        self.unresolved = unresolved
    }

    public static func build(documents: [String: MainframeMarkdownDocument]) -> MainframeLinkIndex {
        let knownPaths = Set(documents.keys)
        var outgoing: [String: [MainframeDocumentLinkRecord]] = [:]
        var incoming: [String: [MainframeDocumentLinkRecord]] = [:]
        var unresolved: [MainframeDocumentLinkRecord] = []

        for sourcePath in documents.keys.sorted() {
            guard let document = documents[sourcePath] else { continue }
            for link in document.links {
                let resolution = MainframeLinkResolver.resolve(
                    sourcePath: sourcePath,
                    target: link.target,
                    documents: documents,
                    knownPaths: knownPaths
                )
                let record = MainframeDocumentLinkRecord(sourcePath: sourcePath, link: link, resolution: resolution)
                outgoing[sourcePath, default: []].append(record)
                switch resolution {
                case .local(let path, _):
                    incoming[path, default: []].append(record)
                case .sameDocumentAnchor:
                    incoming[sourcePath, default: []].append(record)
                case .external:
                    break
                case .unresolved:
                    unresolved.append(record)
                }
            }
        }
        return MainframeLinkIndex(outgoing: outgoing, incoming: incoming, unresolved: unresolved)
    }
}

public enum MainframeLinkResolver {
    public static func resolve(
        sourcePath: String,
        target: String,
        documents: [String: MainframeMarkdownDocument],
        knownPaths: Set<String>
    ) -> MainframeResolvedLink {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unresolved("empty target") }

        if let scheme = scheme(of: trimmed) {
            if ["http", "https", "mailto", "tel"].contains(scheme.lowercased()) {
                return .external(trimmed)
            }
            return .unresolved("unsupported URL scheme: \(scheme)")
        }

        let decoded = trimmed.removingPercentEncoding ?? trimmed
        if decoded.hasPrefix("#") {
            let anchor = String(decoded.dropFirst())
            guard !anchor.isEmpty else { return .unresolved("empty heading anchor") }
            guard let document = documents[sourcePath], document.headings.contains(where: { $0.id == anchor }) else {
                return .unresolved("heading anchor not found")
            }
            return .sameDocumentAnchor(anchor)
        }

        let split = splitAnchor(decoded)
        guard !split.path.contains("?") else { return .unresolved("local link query parameters are not supported") }
        let candidate: String
        if split.path.hasPrefix("/") {
            candidate = normalizePath(String(split.path.dropFirst())) ?? ""
        } else {
            let parent = parentPath(sourcePath)
            candidate = normalizePath(parent.isEmpty ? split.path : "\(parent)/\(split.path)") ?? ""
        }
        guard !candidate.isEmpty else { return .unresolved("target escapes MainFrame root") }
        guard knownPaths.contains(candidate) else { return .unresolved("target path not found") }

        if let anchor = split.anchor, !anchor.isEmpty {
            guard let document = documents[candidate], document.headings.contains(where: { $0.id == anchor }) else {
                return .unresolved("target heading anchor not found")
            }
        }
        return .local(path: candidate, anchor: split.anchor)
    }

    private static func splitAnchor(_ value: String) -> (path: String, anchor: String?) {
        guard let hash = value.firstIndex(of: "#") else { return (value, nil) }
        return (String(value[..<hash]), String(value[value.index(after: hash)...]))
    }

    private static func parentPath(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        return parts.dropLast().joined(separator: "/")
    }

    private static func normalizePath(_ raw: String) -> String? {
        var stack: [Substring] = []
        for component in raw.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..":
                guard !stack.isEmpty else { return nil }
                stack.removeLast()
            default:
                stack.append(component)
            }
        }
        return stack.joined(separator: "/")
    }

    private static func scheme(of value: String) -> String? {
        guard let colon = value.firstIndex(of: ":") else { return nil }
        let candidate = String(value[..<colon])
        guard !candidate.isEmpty,
              candidate.first?.isLetter == true,
              candidate.dropFirst().allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }) else { return nil }
        return candidate
    }
}
