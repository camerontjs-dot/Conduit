import Foundation

/// Direct lifecycle identity exposed by public MainFrame v0.4.0.
///
/// This type is intentionally independent from `MainframeProject`: existing
/// task/session flows remain project-scoped until they are migrated explicitly,
/// while Explorer can consume the complete project + operation namespace.
public enum MainframeLifecycleRecordType: String, Codable, CaseIterable, Sendable {
    case project
    case operation
}

public enum MainframeLifecycleRootKind: String, Codable, CaseIterable, Sendable {
    case projects
    case operations

    public var directoryName: String {
        switch self {
        case .projects: return "30_projects"
        case .operations: return "40_operations"
        }
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

    public init(
        records: [MainframeLifecycleRecord],
        issues: [String],
        rootIssues: [String]
    ) {
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
        case .missingRoot(let path):
            return "MainFrame root does not exist: \(path)"
        case .invalidSlug(let slug):
            return "Invalid lifecycle slug: \(slug)"
        case .cannotProveUniqueness(let issues):
            return "Cannot prove cross-root lifecycle uniqueness: \(issues.joined(separator: "; "))"
        case .missingIdentity(let slug):
            return "No direct lifecycle authority for \(slug)"
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
    case missingClosingDelimiter
    case unsupportedNestedDeclaration
    case malformedDeclaration(String)
    case invalidKey(String)
    case duplicateKey(String)

    public var errorDescription: String? {
        switch self {
        case .missingClosingDelimiter:
            return "frontmatter opening delimiter has no closing delimiter"
        case .unsupportedNestedDeclaration:
            return "indented/nested frontmatter declarations are not supported"
        case .malformedDeclaration(let line):
            return "frontmatter line is not a key/value declaration: \(line)"
        case .invalidKey(let key):
            return "frontmatter key is invalid: \(key)"
        case .duplicateKey(let key):
            return "duplicate frontmatter key: \(key)"
        }
    }
}

public enum MainframeLifecycleFrontmatterParser {
    public static func parse(_ markdown: String) throws -> MainframeLifecycleMetadata {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") || normalized == "---" else {
            return MainframeLifecycleMetadata(title: heading(in: normalized))
        }
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let closeIndex = lines.indices.dropFirst().first(where: { lines[$0].trimmingCharacters(in: .whitespaces) == "---" }) else {
            throw MainframeLifecycleFrontmatterError.missingClosingDelimiter
        }

        var values: [String: String] = [:]
        var tags: [String] = []
        for line in lines[1..<closeIndex] {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if line.first?.isWhitespace == true {
                throw MainframeLifecycleFrontmatterError.unsupportedNestedDeclaration
            }
            guard let colon = line.firstIndex(of: ":") else {
                throw MainframeLifecycleFrontmatterError.malformedDeclaration(line)
            }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            guard isValidKey(key) else {
                throw MainframeLifecycleFrontmatterError.invalidKey(key)
            }
            guard values[key] == nil else {
                throw MainframeLifecycleFrontmatterError.duplicateKey(key)
            }
            let raw = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if key == "tags" {
                tags = parseInlineArray(raw)
                values[key] = raw
            } else {
                values[key] = unquote(raw)
            }
        }

        return MainframeLifecycleMetadata(
            title: nonEmpty(values["title"]) ?? heading(in: normalized),
            domain: nonEmpty(values["domain"]),
            status: nonEmpty(values["status"]),
            projectState: nonEmpty(values["project_state"]),
            lifecycleState: nonEmpty(values["lifecycle_state"]),
            goal: nonEmpty(values["goal"]),
            nextAction: nonEmpty(values["next_action"]),
            updated: nonEmpty(values["updated"]),
            wipClass: nonEmpty(values["wip_class"]),
            recordTypeDeclaration: nonEmpty(values["record_type"]),
            typeDeclaration: nonEmpty(values["type"]),
            tags: tags
        )
    }

    private static func isValidKey(_ key: String) -> Bool {
        key.range(of: #"^[A-Za-z_][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil
    }

    private static func heading(in markdown: String) -> String? {
        markdown
            .split(separator: "\n")
            .map(String.init)
            .first(where: { $0.hasPrefix("# ") })?
            .dropFirst(2)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'")) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func parseInlineArray(_ value: String) -> [String] {
        let normalized = unquote(value)
        guard normalized.hasPrefix("["), normalized.hasSuffix("]") else { return [] }
        return normalized
            .dropFirst()
            .dropLast()
            .split(separator: ",")
            .map { unquote($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.isEmpty }
    }
}

/// Scanner for the public MainFrame project/operation identity contract.
///
/// Compatibility reference: camerontjs-dot/MainFrame main at
/// 200a95e847e7f69a35c9e4d9d3f5a9e48c02f508 (v0.4.0 public candidate).
/// Missing lifecycle roots are tolerated; malformed roots make uniqueness
/// unprovable and therefore make direct resolution fail closed.
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

        for rootKind in MainframeLifecycleRootKind.allCases {
            let lifecycleRoot = root.appendingPathComponent(rootKind.directoryName, isDirectory: true)
            let rootValues = try? lifecycleRoot.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if rootValues?.isSymbolicLink == true {
                let issue = "\(rootKind.rawValue) lifecycle root is symlinked: \(lifecycleRoot.path)"
                issues.append(issue)
                rootIssues.append(issue)
                continue
            }
            guard fileManager.fileExists(atPath: lifecycleRoot.path, isDirectory: &isDirectory) else {
                continue
            }
            guard isDirectory.boolValue else {
                let issue = "\(rootKind.rawValue) lifecycle root is not a directory: \(lifecycleRoot.path)"
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
                let issue = "cannot enumerate \(rootKind.rawValue) lifecycle root: \(error.localizedDescription)"
                issues.append(issue)
                rootIssues.append(issue)
                continue
            }

            for child in children {
                let childValues = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard childValues?.isDirectory == true || childValues?.isSymbolicLink == true else { continue }
                let record = record(for: child, rootKind: rootKind)
                records.append(record)
                issues.append(contentsOf: record.issues.map {
                    "\(rootKind.directoryName)/\(record.slug): \($0)"
                })
            }
        }

        let grouped = Dictionary(grouping: records, by: \.slug)
        for (slug, matches) in grouped where matches.count > 1 {
            let locations = matches.map { relativePath(root: root, url: $0.path) }.sorted()
            issues.append("duplicate lifecycle identity \(slug): \(locations.joined(separator: ", "))")
        }

        return MainframeLifecycleScan(records: records, issues: issues, rootIssues: rootIssues)
    }

    public func resolveRecord(
        root: URL,
        slug: String,
        expectedRecordType: MainframeLifecycleRecordType? = nil
    ) throws -> MainframeLifecycleRecord {
        guard isValidSlug(slug) else {
            throw MainframeLifecycleIdentityError.invalidSlug(slug)
        }
        let result = try scan(root: root)
        guard result.rootIssues.isEmpty else {
            throw MainframeLifecycleIdentityError.cannotProveUniqueness(result.rootIssues)
        }
        let matches = result.bySlug[slug] ?? []
        guard !matches.isEmpty else {
            throw MainframeLifecycleIdentityError.missingIdentity(slug)
        }
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

    private func record(
        for child: URL,
        rootKind: MainframeLifecycleRootKind
    ) -> MainframeLifecycleRecord {
        let slug = child.lastPathComponent
        var issues: [String] = []

        let childValues = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if childValues?.isSymbolicLink == true {
            issues.append("symlinked lifecycle entity is not an authority")
        }
        if !isValidSlug(slug) {
            issues.append("invalid lifecycle slug")
        }
        if !isContained(child, in: child.deletingLastPathComponent()) {
            issues.append("lifecycle entity escapes its root")
        }
        if childValues?.isDirectory != true && childValues?.isSymbolicLink != true {
            issues.append("lifecycle entity is not a directory")
        }

        let readme = child.appendingPathComponent("README.md")
        let metadata = readMetadata(
            at: readme,
            ownerDirectory: child,
            label: "README.md",
            required: true,
            issues: &issues
        ) ?? MainframeLifecycleMetadata()

        let coordination = child.appendingPathComponent("PROJECT.md")
        let coordinationMetadata = readMetadata(
            at: coordination,
            ownerDirectory: child,
            label: "PROJECT.md",
            required: false,
            issues: &issues
        )

        let recordType = effectiveRecordType(metadata: metadata, rootKind: rootKind)
        if recordType == nil {
            issues.append("record_type is missing or invalid")
        }
        if rootKind == .operations,
           normalizeType(metadata.recordTypeDeclaration) != MainframeLifecycleRecordType.operation.rawValue {
            issues.append("operation-root README must declare record_type: operation")
        }

        let readmeState = lifecycleState(metadata: metadata, label: nil, issues: &issues)
        let coordinationState = coordinationMetadata.flatMap {
            lifecycleState(metadata: $0, label: "PROJECT.md", issues: &issues)
        }
        let state: String?
        let stateSource: String
        if let coordinationState {
            if let readmeState, readmeState != coordinationState {
                issues.append("README lifecycle state differs from PROJECT.md owner")
            }
            state = coordinationState
            stateSource = "PROJECT.md"
        } else {
            state = readmeState
            stateSource = "README.md"
        }

        let readmeWip = metadata.wipClass
        let coordinationWip = coordinationMetadata?.wipClass
        if let readmeWip, let coordinationWip, readmeWip != coordinationWip {
            issues.append("README wip_class differs from PROJECT.md owner")
        }
        let wipClass = coordinationWip ?? readmeWip
        if let wipClass, !["product", "eval", "anchor"].contains(wipClass) {
            issues.append("invalid wip_class: \(wipClass)")
        }

        if let coordinationMetadata,
           coordinationMetadata.recordTypeDeclaration != nil,
           effectiveRecordType(metadata: coordinationMetadata, rootKind: rootKind) != recordType {
            issues.append("README and PROJECT.md record_type declarations differ")
        }

        return MainframeLifecycleRecord(
            slug: slug,
            path: child,
            rootKind: rootKind,
            recordType: recordType,
            readmePath: readme,
            coordinationPath: coordinationMetadata == nil ? nil : coordination,
            metadata: metadata,
            coordinationMetadata: coordinationMetadata,
            lifecycleState: state,
            stateSource: stateSource,
            wipClass: wipClass,
            issues: unique(issues)
        )
    }

    private func readMetadata(
        at file: URL,
        ownerDirectory: URL,
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
        guard isContained(file, in: ownerDirectory) else {
            issues.append("\(label) escapes lifecycle entity")
            return nil
        }
        do {
            let text = try String(contentsOf: file, encoding: .utf8)
            return try MainframeLifecycleFrontmatterParser.parse(text)
        } catch let error as MainframeLifecycleFrontmatterError {
            issues.append("\(label == "README.md" ? "" : "\(label): ")\(error.localizedDescription)")
            return nil
        } catch {
            issues.append("\(label) unreadable: \(error.localizedDescription)")
            return nil
        }
    }

    private func effectiveRecordType(
        metadata: MainframeLifecycleMetadata,
        rootKind: MainframeLifecycleRootKind
    ) -> MainframeLifecycleRecordType? {
        let declarations = [metadata.recordTypeDeclaration, metadata.typeDeclaration].compactMap { $0 }
        guard !declarations.isEmpty else {
            return rootKind == .projects ? .project : nil
        }
        let values = declarations.map { declaration -> MainframeLifecycleRecordType? in
            switch normalizeType(declaration) {
            case "operation": return .operation
            case "project", "program", "evaluation", "lifecycle": return .project
            default: return nil
            }
        }
        if values.count == 2, values[0] != values[1] { return nil }
        return values[0]
    }

    private func lifecycleState(
        metadata: MainframeLifecycleMetadata,
        label: String?,
        issues: inout [String]
    ) -> String? {
        if let projectState = metadata.projectState,
           let lifecycleState = metadata.lifecycleState,
           projectState != lifecycleState {
            let prefix = label.map { "\($0): " } ?? ""
            issues.append("\(prefix)project_state and lifecycle_state conflict")
            return nil
        }
        return metadata.lifecycleState ?? metadata.projectState ?? metadata.status
    }

    private func normalizeType(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .lowercased()
    }

    private func isValidSlug(_ slug: String) -> Bool {
        slug.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
    }

    private func isContained(_ candidate: URL, in parent: URL) -> Bool {
        let resolvedParent = parent.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        return resolvedCandidate == resolvedParent || resolvedCandidate.hasPrefix(resolvedParent + "/")
    }

    private func relativePath(root: URL, url: URL) -> String {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return path }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
