import Foundation

public struct ContextDocument: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let label: String
    public let trustLabel: String

    public init(url: URL, label: String, trustLabel: String) {
        self.url = url
        self.label = label
        self.trustLabel = trustLabel
    }
}

public struct ContextBundle: Hashable, Sendable {
    public let markdown: String
    public let includedDocuments: [ContextDocument]
    public let truncated: Bool

    public init(markdown: String, includedDocuments: [ContextDocument], truncated: Bool) {
        self.markdown = markdown
        self.includedDocuments = includedDocuments
        self.truncated = truncated
    }
}

public struct ContextBundleBuilder: Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func candidates(for project: MainframeProject) -> [ContextDocument] {
        var candidates: [ContextDocument] = []
        var seen = Set<String>()

        func add(_ url: URL, label: String, trustLabel: String) {
            guard fileManager.fileExists(atPath: url.path), seen.insert(url.standardizedFileURL.path).inserted else { return }
            candidates.append(ContextDocument(url: url, label: label, trustLabel: trustLabel))
        }

        if let readme = project.readmePath {
            add(readme, label: "Project README", trustLabel: "project coordination")
        }
        add(project.path.appendingPathComponent("AGENTS.md"), label: "Local agent contract", trustLabel: "operating contract")
        add(project.path.appendingPathComponent("decisions.md"), label: "Decisions", trustLabel: "project decisions")
        add(project.path.appendingPathComponent("log.md"), label: "Work log", trustLabel: "project timeline")
        add(project.path.appendingPathComponent("STATUS.md"), label: "Workbench status", trustLabel: "volatile project state")
        add(project.path.appendingPathComponent("workbench/STATUS.md"), label: "Workbench status", trustLabel: "volatile project state")

        let plans = project.path.appendingPathComponent("plans", isDirectory: true)
        if let enumerator = fileManager.enumerator(
            at: plans,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            let recentPlans = enumerator.compactMap { $0 as? URL }
                .filter { $0.pathExtension.lowercased() == "md" }
                .compactMap { url -> (URL, Date)? in
                    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                    guard values?.isRegularFile == true else { return nil }
                    return (url, values?.contentModificationDate ?? .distantPast)
                }
                .sorted { $0.1 > $1.1 }
                .prefix(3)
            for (url, _) in recentPlans {
                add(url, label: "Plan: \(url.lastPathComponent)", trustLabel: "project plan")
            }
        }

        return candidates
    }

    public func assemble(documents: [ContextDocument], maximumBytes: Int = 120_000) -> ContextBundle {
        var output = """
        # Conduit context bundle

        This bundle nominates local context for inspection. It is not verification of any claim.

        """
        var included: [ContextDocument] = []
        var truncated = false
        var remaining = max(maximumBytes - output.utf8.count, 0)

        for document in documents {
            guard remaining > 0 else {
                truncated = true
                break
            }
            guard let data = try? Data(contentsOf: document.url),
                  let content = String(data: data, encoding: .utf8) else { continue }

            let header = """
            ## \(document.label)

            - Path: `\(document.url.path)`
            - Trust label: \(document.trustLabel)

            """
            let headerBytes = header.utf8.count
            guard remaining > headerBytes else {
                truncated = true
                break
            }
            output += header
            remaining -= headerBytes

            let contentData = Data(content.utf8)
            if contentData.count <= remaining {
                output += content
                if !content.hasSuffix("\n") { output += "\n" }
                remaining -= contentData.count
            } else {
                let prefix = contentData.prefix(remaining)
                output += String(decoding: prefix, as: UTF8.self)
                output += "\n\n[truncated by Conduit]\n"
                remaining = 0
                truncated = true
            }
            output += "\n"
            included.append(document)
        }

        return ContextBundle(markdown: output, includedDocuments: included, truncated: truncated)
    }
}

public enum WorkSessionReceiptError: LocalizedError {
    case missingLiveDirectory(URL)

    public var errorDescription: String? {
        switch self {
        case .missingLiveDirectory(let root):
            return "No 20_live directory exists under \(root.path)"
        }
    }
}

public struct WorkSessionReceiptWriter: Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func write(root: URL, receipt: RenderedReceipt) throws -> URL {
        let live = root.appendingPathComponent("20_live", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: live.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WorkSessionReceiptError.missingLiveDirectory(root)
        }

        let directory = live.appendingPathComponent("conduit/sessions", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let timestamp = Self.filenameFormatter.string(from: receipt.endedAt)
        var destination = directory.appendingPathComponent("\(timestamp)-\(slugify(receipt.projectSlug)).md")
        var suffix = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(timestamp)-\(slugify(receipt.projectSlug))-\(suffix).md")
            suffix += 1
        }

        try receipt.markdown.write(to: destination, atomically: true, encoding: .utf8)
        return destination
    }

    private func slugify(_ value: String) -> String {
        let pieces = value.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        let slug = String(pieces).split(separator: "-").filter { !$0.isEmpty }.joined(separator: "-")
        return slug.isEmpty ? "session" : slug
    }

    private static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()

    private static let isoFormatter = ISO8601DateFormatter()
}

public enum TerminalForwarder {
    public static func prompt(selection: String, sourceAgent: String?, destinationAgent: String) -> String {
        let clean = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "" }
        let source = sourceAgent?.isEmpty == false ? sourceAgent! : "another terminal session"
        return """
        Review the following selected output from \(source).

        Evidence boundary: this is unverified terminal output. Inspect the actual files, repository state, and relevant commands before accepting any completion claim. Re-run deterministic checks where available.

        ```text
        \(clean)
        ```
        """
    }
}
