import Foundation

/// Typed direct-authority record for MainFrame's shared project/operation slug namespace.
/// Kept separate from `MainframeProject` so existing task/runtime flows stay unchanged
/// until they are migrated deliberately.
public enum MainframeLifecycleRecordType: String, Codable, CaseIterable, Sendable {
    case project
    case operation
}

public enum MainframeLifecycleRootKind: String, Codable, CaseIterable, Sendable {
    case projects
    case operations

    public var directoryName: String {
        self == .projects ? "30_projects" : "40_operations"
    }
}

public struct MainframeLifecycleMetadata: Codable, Hashable, Sendable {
    public var title: String?
    public var domain: String?
    public var status: String?
    public var projectState: String?
    public var lifecycleState: String?
    public var goal: String?
    public var nextAction: String?
    public var updated: String?
    public var wipClass: String?
    public var recordTypeDeclaration: String?
    public var typeDeclaration: String?
    public var tags: [String]

    public init(
        title: String? = nil,
        domain: String? = nil,
        status: String? = nil,
        projectState: String? = nil,
        lifecycleState: String? = nil,
        goal: String? = nil,
        nextAction: String? = nil,
        updated: String? = nil,
        wipClass: String? = nil,
        recordTypeDeclaration: String? = nil,
        typeDeclaration: String? = nil,
        tags: [String] = []
    ) {
        self.title = title
        self.domain = domain
        self.status = status
        self.projectState = projectState
        self.lifecycleState = lifecycleState
        self.goal = goal
        self.nextAction = nextAction
        self.updated = updated
        self.wipClass = wipClass
        self.recordTypeDeclaration = recordTypeDeclaration
        self.typeDeclaration = typeDeclaration
        self.tags = tags
    }
}

public struct MainframeLifecycleRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: String { path.path }
    public let slug: String
    public let path: URL
    public let rootKind: MainframeLifecycleRootKind
    public let recordType: MainframeLifecycleRecordType?
    public let readmePath: URL
    public let coordinationPath: URL?
    public let metadata: MainframeLifecycleMetadata
    public let coordinationMetadata: MainframeLifecycleMetadata?
    public let lifecycleState: String?
    public let stateSource: String
    public let wipClass: String?
    public let issues: [String]

    public var isValid: Bool { issues.isEmpty && recordType != nil }

    public init(
        slug: String,
        path: URL,
        rootKind: MainframeLifecycleRootKind,
        recordType: MainframeLifecycleRecordType?,
        readmePath: URL,
        coordinationPath: URL?,
        metadata: MainframeLifecycleMetadata,
        coordinationMetadata: MainframeLifecycleMetadata?,
        lifecycleState: String?,
        stateSource: String,
        wipClass: String?,
        issues: [String]
    ) {
        self.slug = slug
        self.path = path
        self.rootKind = rootKind
        self.recordType = recordType
        self.readmePath = readmePath
        self.coordinationPath = coordinationPath
        self.metadata = metadata
        self.coordinationMetadata = coordinationMetadata
        self.lifecycleState = lifecycleState
        self.stateSource = stateSource
        self.wipClass = wipClass
        self.issues = issues
    }
}

public struct MainframeLifecycleScan: Sendable {
    public let records: [MainframeLifecycleRecord]
    public let issues: [String]
    public let rootIssues: [String]

    public init(records: [MainframeLifecycleRecord], issues: [String], rootIssues: [String]) {
        self.records = records
        self.issues = issues
        self.rootIssues = rootIssues
    }

    public var bySlug: [String: [MainframeLifecycleRecord]] {
        Dictionary(grouping: records, by: \.slug)
    }
}

public enum MainframeLifecycleIdentityError: LocalizedError, Equatable {
    case missingRoot(String)
    case invalidSlug(String)
    case cannotProveUniqueness([String])
    case missingIdentity(String)
    case duplicateIdentity(slug: String, locations: [String])
    case invalidIdentity(path: String, issues: [String])
    case unexpectedRecordType(slug: String, actual: String?, expected: MainframeLifecycleRecordType)

    public var errorDescription: String? {
        switch self {
        case .missingRoot(let path): return "MainFrame root does not exist: \(path)"
        case .invalidSlug(let slug): return "Invalid lifecycle slug: \(slug)"
        case .cannotProveUniqueness(let issues):
            return "Cannot prove cross-root lifecycle uniqueness: \(issues.joined(separator: "; "))"
        case .missingIdentity(let slug): return "No direct lifecycle authority for \(slug)"
        case .duplicateIdentity(let slug, let locations):
            return "Duplicate lifecycle identity \(slug): \(locations.joined(separator: ", "))"
        case .invalidIdentity(let path, let issues):
            return "Invalid lifecycle authority \(path): \(issues.joined(separator: "; "))"
        case .unexpectedRecordType(let slug, let actual, let expected):
            return "\(slug) has record_type=\(actual ?? "invalid"), expected \(expected.rawValue)"
        }
    }
}

public enum MainframeLifecycleFrontmatterError: LocalizedError, Equatable {
    case invalid(String)

    public var errorDescription: String? {
        if case .invalid(let message) = self { return message }
        return nil
    }
}

public enum MainframeLifecycleFrontmatterParser {
    public static func parse(_ markdown: String) throws -> MainframeLifecycleMetadata {
        let text = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        guard text.hasPrefix("---\n") || text == "---" else {
            return MainframeLifecycleMetadata(title: heading(in: text))
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let end = lines.indices.dropFirst().first(where: {
            lines[$0].trimmingCharacters(in: .whitespaces) == "---"
        }) else {
            throw MainframeLifecycleFrontmatterError.invalid(
                "frontmatter opening delimiter has no closing delimiter"
            )
        }

        var values: [String: String] = [:]
        var tags: [String] = []
        for line in lines[1..<end] {
            let stripped = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if stripped.isEmpty || stripped.hasPrefix("#") { continue }
            if line.first?.isWhitespace == true {
                throw MainframeLifecycleFrontmatterError.invalid(
                    "indented/nested frontmatter declarations are not supported"
                )
            }
            guard let colon = line.firstIndex(of: ":") else {
                throw MainframeLifecycleFrontmatterError.invalid(
                    "frontmatter line is not a key/value declaration: \(line)"
                )
            }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            guard key.range(of: #"^[A-Za-z_][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil else {
                throw MainframeLifecycleFrontmatterError.invalid("frontmatter key is invalid: \(key)")
            }
            guard values[key] == nil else {
                throw MainframeLifecycleFrontmatterError.invalid("duplicate frontmatter key: \(key)")
            }
            let raw = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            values[key] = unquote(raw)
            if key == "tags" { tags = parseInlineArray(raw) }
        }

        return MainframeLifecycleMetadata(
            title: value(values["title"]) ?? heading(in: text),
            domain: value(values["domain"]),
            status: nullable(values["status"]),
            projectState: nullable(values["project_state"]),
            lifecycleState: nullable(values["lifecycle_state"]),
            goal: value(values["goal"]),
            nextAction: value(values["next_action"]),
            updated: value(values["updated"]),
            wipClass: nullable(values["wip_class"]),
            // Presence matters here: an explicit blank/unknown declaration must
            // not fall back to the legacy project default.
            recordTypeDeclaration: values["record_type"],
            typeDeclaration: values["type"],
            tags: tags
        )
    }

    private static func value(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    private static func nullable(_ raw: String?) -> String? {
        guard let raw = value(raw) else { return nil }
        return ["null", "none", "~"].contains(raw.lowercased()) ? nil : raw
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'")) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func parseInlineArray(_ raw: String) -> [String] {
        let value = unquote(raw)
        guard value.hasPrefix("["), value.hasSuffix("]") else { return [] }
        return value.dropFirst().dropLast().split(separator: ",").map {
            unquote($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }.filter { !$0.isEmpty }
    }

    private static func heading(in markdown: String) -> String? {
        markdown.split(separator: "\n").map(String.init).first(where: { $0.hasPrefix("# ") })?
            .dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Compatibility reference: camerontjs-dot/MainFrame
/// `200a95e847e7f69a35c9e4d9d3f5a9e48c02f508` (public v0.4.0 candidate).
public struct MainframeLifecycleScanner: @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func scan(root: URL) throws -> MainframeLifecycleScan {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MainframeLifecycleIdentityError.missingRoot(root.path)
        }

        var records: [MainframeLifecycleRecord] = []
        var issues: [String] = []
        var rootIssues: [String] = []
        for kind in MainframeLifecycleRootKind.allCases {
            let lifecycleRoot = root.appendingPathComponent(kind.directoryName, isDirectory: true)
            let rootValues = try? lifecycleRoot.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if rootValues?.isSymbolicLink == true {
                let issue = "\(kind.rawValue) lifecycle root is symlinked: \(lifecycleRoot.path)"
                issues.append(issue)
                rootIssues.append(issue)
                continue
            }
            guard fileManager.fileExists(atPath: lifecycleRoot.path, isDirectory: &isDirectory) else { continue }
            guard isDirectory.boolValue else {
                let issue = "\(kind.rawValue) lifecycle root is not a directory: \(lifecycleRoot.path)"
                issues.append(issue)
                rootIssues.append(issue)
                continue
            }

            let children: [URL]
            do {
                children = try fileManager.contentsOfDirectory(
                    at: lifecycleRoot,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                ).sorted { $0.lastPathComponent < $1.lastPathComponent }
            } catch {
                let issue = "cannot enumerate \(kind.rawValue) lifecycle root: \(error.localizedDescription)"
                issues.append(issue)
                rootIssues.append(issue)
                continue
            }

            for child in children {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true || values?.isSymbolicLink == true else { continue }
                let record = record(for: child, rootKind: kind)
                records.append(record)
                issues += record.issues.map { "\(kind.directoryName)/\(record.slug): \($0)" }
            }
        }

        let grouped = Dictionary(grouping: records, by: \.slug)
        for (slug, matches) in grouped where matches.count > 1 {
            issues.append(
                "duplicate lifecycle identity \(slug): " + matches.map {
                    relativePath(root: root, url: $0.path)
                }.sorted().joined(separator: ", ")
            )
        }
        return MainframeLifecycleScan(records: records, issues: issues, rootIssues: rootIssues)
    }

    public func resolveRecord(
        root: URL,
        slug: String,
        expectedRecordType: MainframeLifecycleRecordType? = nil
    ) throws -> MainframeLifecycleRecord {
        guard validSlug(slug) else { throw MainframeLifecycleIdentityError.invalidSlug(slug) }
        let scan = try scan(root: root)
        guard scan.rootIssues.isEmpty else {
            throw MainframeLifecycleIdentityError.cannotProveUniqueness(scan.rootIssues)
        }
        let matches = scan.bySlug[slug] ?? []
        guard !matches.isEmpty else { throw MainframeLifecycleIdentityError.missingIdentity(slug) }
        guard matches.count == 1 else {
            throw MainframeLifecycleIdentityError.duplicateIdentity(
                slug: slug,
                locations: matches.map { relativePath(root: root, url: $0.path) }.sorted()
            )
        }
        let record = matches[0]
        guard record.isValid else {
            throw MainframeLifecycleIdentityError.invalidIdentity(
                path: relativePath(root: root, url: record.path),
                issues: record.issues
            )
        }
        if let expectedRecordType, record.recordType != expectedRecordType {
            throw MainframeLifecycleIdentityError.unexpectedRecordType(
                slug: slug,
                actual: record.recordType?.rawValue,
                expected: expectedRecordType
            )
        }
        return record
    }

    private func record(for child: URL, rootKind: MainframeLifecycleRootKind) -> MainframeLifecycleRecord {
        let slug = child.lastPathComponent
        var issues: [String] = []
        let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values?.isSymbolicLink == true { issues.append("symlinked lifecycle entity is not an authority") }
        if !validSlug(slug) { issues.append("invalid lifecycle slug") }
        if !contained(child, in: child.deletingLastPathComponent()) { issues.append("lifecycle entity escapes its root") }
        if values?.isDirectory != true && values?.isSymbolicLink != true { issues.append("lifecycle entity is not a directory") }

        let readme = child.appendingPathComponent("README.md")
        let metadata = readMetadata(
            at: readme,
            owner: child,
            label: "README.md",
            required: true,
            issues: &issues
        ) ?? MainframeLifecycleMetadata()
        let project = child.appendingPathComponent("PROJECT.md")
        let projectMetadata = readMetadata(
            at: project,
            owner: child,
            label: "PROJECT.md",
            required: false,
            issues: &issues
        )

        let type = effectiveRecordType(metadata, rootKind: rootKind)
        if type == nil { issues.append("record_type is missing or invalid") }
        // Public MainFrame requires this exact direct declaration for operations.
        if rootKind == .operations, metadata.recordTypeDeclaration != "operation" {
            issues.append("operation-root README must declare record_type: operation")
        }

        let readmeState = state(metadata, label: nil, issues: &issues)
        let projectState = projectMetadata.flatMap { state($0, label: "PROJECT.md", issues: &issues) }
        let lifecycleState: String?
        let stateSource: String
        if let projectState {
            if let readmeState, readmeState != projectState {
                issues.append("README lifecycle state differs from PROJECT.md owner")
            }
            lifecycleState = projectState
            stateSource = "PROJECT.md"
        } else {
            lifecycleState = readmeState
            stateSource = "README.md"
        }

        let readmeWip = metadata.wipClass
        let projectWip = projectMetadata?.wipClass
        if let readmeWip, let projectWip, readmeWip != projectWip {
            issues.append("README wip_class differs from PROJECT.md owner")
        }
        let wipClass = projectWip ?? readmeWip
        if let wipClass, !["product", "eval", "anchor"].contains(wipClass) {
            issues.append("invalid wip_class: \(wipClass)")
        }
        if let projectMetadata,
           projectMetadata.recordTypeDeclaration != nil,
           effectiveRecordType(projectMetadata, rootKind: rootKind) != type {
            issues.append("README and PROJECT.md record_type declarations differ")
        }

        return MainframeLifecycleRecord(
            slug: slug,
            path: child,
            rootKind: rootKind,
            recordType: type,
            readmePath: readme,
            coordinationPath: projectMetadata == nil ? nil : project,
            metadata: metadata,
            coordinationMetadata: projectMetadata,
            lifecycleState: lifecycleState,
            stateSource: stateSource,
            wipClass: wipClass,
            issues: deduplicated(issues)
        )
    }

    private func readMetadata(
        at file: URL,
        owner: URL,
        label: String,
        required: Bool,
        issues: inout [String]
    ) -> MainframeLifecycleMetadata? {
        let values = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        if values?.isSymbolicLink == true {
            issues.append("\(label) is symlinked")
            return nil
        }
        guard fileManager.fileExists(atPath: file.path) else {
            if required { issues.append("\(label) missing or not a regular file") }
            return nil
        }
        guard values?.isRegularFile == true else {
            issues.append("\(label) is not a regular file")
            return nil
        }
        guard contained(file, in: owner) else {
            issues.append("\(label) escapes lifecycle entity")
            return nil
        }
        do {
            return try MainframeLifecycleFrontmatterParser.parse(
                String(contentsOf: file, encoding: .utf8)
            )
        } catch {
            let prefix = label == "README.md" ? "" : "\(label): "
            issues.append(prefix + error.localizedDescription)
            return nil
        }
    }

    private func effectiveRecordType(
        _ metadata: MainframeLifecycleMetadata,
        rootKind: MainframeLifecycleRootKind
    ) -> MainframeLifecycleRecordType? {
        let declarations = [metadata.recordTypeDeclaration, metadata.typeDeclaration].compactMap { $0 }
        guard !declarations.isEmpty else { return rootKind == .projects ? .project : nil }
        let types = declarations.map { raw -> MainframeLifecycleRecordType? in
            switch normalizedType(raw) {
            case "operation": return .operation
            case "project", "program", "evaluation", "lifecycle": return .project
            default: return nil
            }
        }
        if types.count == 2, types[0] != types[1] { return nil }
        return types[0]
    }

    private func state(
        _ metadata: MainframeLifecycleMetadata,
        label: String?,
        issues: inout [String]
    ) -> String? {
        if let projectState = metadata.projectState,
           let lifecycleState = metadata.lifecycleState,
           projectState != lifecycleState {
            issues.append(
                (label.map { "\($0): " } ?? "") + "project_state and lifecycle_state conflict"
            )
            return nil
        }
        return metadata.lifecycleState ?? metadata.projectState ?? metadata.status
    }

    private func normalizedType(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .lowercased()
    }

    private func validSlug(_ slug: String) -> Bool {
        slug.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
    }

    private func contained(_ candidate: URL, in parent: URL) -> Bool {
        let parentPath = parent.resolvingSymlinksInPath().standardizedFileURL.path
        let candidatePath = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        return candidatePath == parentPath || candidatePath.hasPrefix(parentPath + "/")
    }

    private func relativePath(root: URL, url: URL) -> String {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return path }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
