import Foundation

public struct ProjectMetadata: Codable, Hashable, Sendable {
    public var title: String
    public var domain: String?
    public var status: String?
    public var projectState: String?
    public var goal: String?
    public var nextAction: String?
    public var updated: String?
    public var tags: [String]

    public init(
        title: String,
        domain: String? = nil,
        status: String? = nil,
        projectState: String? = nil,
        goal: String? = nil,
        nextAction: String? = nil,
        updated: String? = nil,
        tags: [String] = []
    ) {
        self.title = title
        self.domain = domain
        self.status = status
        self.projectState = projectState
        self.goal = goal
        self.nextAction = nextAction
        self.updated = updated
        self.tags = tags
    }
}

public struct MainframeProject: Identifiable, Codable, Hashable, Sendable {
    public var id: String { path.path }
    public let slug: String
    public let path: URL
    public let readmePath: URL?
    public let metadata: ProjectMetadata
    public let isMainframeRoot: Bool

    public init(
        slug: String,
        path: URL,
        readmePath: URL?,
        metadata: ProjectMetadata,
        isMainframeRoot: Bool = false
    ) {
        self.slug = slug
        self.path = path
        self.readmePath = readmePath
        self.metadata = metadata
        self.isMainframeRoot = isMainframeRoot
    }
}

public enum AgentKind: String, Codable, CaseIterable, Sendable {
    case shell
    case cli
}

public struct AgentProfile: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var command: String
    public var arguments: [String]
    public var kind: AgentKind
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        command: String,
        arguments: [String] = [],
        kind: AgentKind = .cli,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.arguments = arguments
        self.kind = kind
        self.enabled = enabled
    }

    public static let defaults: [AgentProfile] = [
        AgentProfile(name: "Shell", command: "/bin/zsh", arguments: ["-l"], kind: .shell),
        AgentProfile(name: "Claude", command: "claude"),
        AgentProfile(name: "Codex", command: "codex"),
        AgentProfile(name: "Antigravity", command: "agy"),
        AgentProfile(name: "Grok", command: "grok"),
        AgentProfile(name: "OpenCode", command: "opencode")
    ]
}

public enum AgentSpriteSkin: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
}

public struct AgentSpriteResolution: Equatable, Sendable {
    public let skin: AgentSpriteSkin?
    public let isExactMatch: Bool

    public init(skin: AgentSpriteSkin?, isExactMatch: Bool) {
        self.skin = skin
        self.isExactMatch = isExactMatch
    }
}

/// Maps only identities backed by copied, provenance-noted art. Every other
/// profile deliberately receives Conduit's generic in-code pixel character;
/// a similar-looking name must never masquerade as a known agent identity.
public enum AgentSpriteResolver {
    public static func resolve(_ profile: AgentProfile) -> AgentSpriteResolution {
        let name = normalized(profile.name)
        let executable = normalized(URL(fileURLWithPath: profile.command).lastPathComponent)
        if name == AgentSpriteSkin.codex.rawValue || executable == AgentSpriteSkin.codex.rawValue {
            return AgentSpriteResolution(skin: .codex, isExactMatch: true)
        }
        if name == AgentSpriteSkin.claude.rawValue || executable == AgentSpriteSkin.claude.rawValue {
            return AgentSpriteResolution(skin: .claude, isExactMatch: true)
        }
        return AgentSpriteResolution(skin: nil, isExactMatch: false)
    }

    private static func normalized(_ value: String) -> String {
        value
            .lowercased()
            .unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
    }
}

public struct SessionDescriptor: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var projectPath: URL
    public var agent: AgentProfile
    public var title: String
    public var createdAt: Date
    /// The durable tmux session this descriptor binds to. Set explicitly so a
    /// resumed session attaches to the name that was actually discovered, and
    /// a second instance of the same agent gets its own name, instead of every
    /// session re-deriving one shared name from project + agent.
    ///
    /// Nil means a direct PTY with no durable session.
    public var tmuxSessionName: String?
    /// Stable user-facing task history this concrete runtime attempt belongs
    /// to. Optional for descriptors decoded from before task continuity
    /// existed and for deliberately unbound direct PTY sessions.
    public var taskSessionID: TaskSessionID?
    /// True only after the operator explicitly chose a discovered legacy tmux
    /// session whose task option was absent. Optional keeps pre-task-history
    /// descriptor payloads decodable as a conservative false.
    public var adoptsLegacyTaskSession: Bool?
    /// True for an explicit reconnect. If the named tmux session disappears,
    /// Conduit must stop instead of creating or launching a replacement.
    /// Optional keeps older descriptor payloads conservatively false.
    public var requiresExistingTmuxSession: Bool?
    /// Which instance of this agent-in-this-project the session is. Instance 1
    /// keeps the historic tmux name; later instances are suffixed.
    public var instance: Int
    /// Whether Conduit actually knows whose session this is, and may therefore
    /// record project/agent identity onto the tmux session.
    ///
    /// False when resuming a session that carried no identity: the agent shown
    /// there is a display placeholder, and writing it back would turn a guess
    /// into a permanent record.
    public var recordsIdentity: Bool

    public init(
        id: UUID = UUID(),
        projectPath: URL,
        agent: AgentProfile,
        title: String? = nil,
        createdAt: Date = Date(),
        tmuxSessionName: String? = nil,
        taskSessionID: TaskSessionID? = nil,
        adoptsLegacyTaskSession: Bool = false,
        requiresExistingTmuxSession: Bool = false,
        instance: Int = 1,
        recordsIdentity: Bool = true
    ) {
        self.id = id
        self.projectPath = projectPath
        self.agent = agent
        self.title = title ?? (instance > 1 ? "\(agent.name) \(instance)" : agent.name)
        self.createdAt = createdAt
        self.tmuxSessionName = tmuxSessionName
        self.taskSessionID = taskSessionID
        self.adoptsLegacyTaskSession = adoptsLegacyTaskSession
        self.requiresExistingTmuxSession = requiresExistingTmuxSession
        self.instance = instance
        self.recordsIdentity = recordsIdentity
    }
}

public struct ConduitSettings: Codable, Sendable {
    public var mainframeRoot: URL?
    /// Security-scoped bookmark captured by the system folder picker. The URL
    /// remains human-readable in config; this opaque value lets the installed
    /// app renew access without treating a stored path as permission.
    public var mainframeRootBookmark: Data?
    public var agents: [AgentProfile]
    public var showContextByDefault: Bool
    public var restoreSessions: Bool

    public init(
        mainframeRoot: URL? = nil,
        mainframeRootBookmark: Data? = nil,
        agents: [AgentProfile] = AgentProfile.defaults,
        showContextByDefault: Bool = true,
        restoreSessions: Bool = true
    ) {
        self.mainframeRoot = mainframeRoot
        self.mainframeRootBookmark = mainframeRootBookmark
        self.agents = agents
        self.showContextByDefault = showContextByDefault
        self.restoreSessions = restoreSessions
    }
}

public struct Attachment: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let url: URL

    public init(id: UUID = UUID(), url: URL) {
        self.id = id
        self.url = url
    }
}

public enum FrontmatterParser {
    public static func parse(_ markdown: String, fallbackTitle: String) -> ProjectMetadata {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else {
            return ProjectMetadata(title: heading(in: normalized) ?? fallbackTitle)
        }

        let bodyStart = normalized.index(normalized.startIndex, offsetBy: 4)
        guard let closeRange = normalized.range(of: "\n---", range: bodyStart..<normalized.endIndex) else {
            return ProjectMetadata(title: heading(in: normalized) ?? fallbackTitle)
        }

        let block = String(normalized[bodyStart..<closeRange.lowerBound])
        var values: [String: String] = [:]
        var tags: [String] = []

        for rawLine in block.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let rawValue = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let value = unquote(rawValue)
            if key == "tags" {
                tags = parseInlineArray(value)
            } else if !value.isEmpty {
                values[key] = value
            }
        }

        return ProjectMetadata(
            title: values["title"] ?? heading(in: normalized) ?? fallbackTitle,
            domain: values["domain"],
            status: values["status"],
            projectState: values["project_state"],
            goal: values["goal"],
            nextAction: values["next_action"],
            updated: values["updated"],
            tags: tags
        )
    }

    private static func heading(in markdown: String) -> String? {
        markdown
            .split(separator: "\n")
            .map(String.init)
            .first(where: { $0.hasPrefix("# ") })?
            .dropFirst(2)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard value.hasPrefix("["), value.hasSuffix("]") else { return [] }
        return value
            .dropFirst()
            .dropLast()
            .split(separator: ",")
            .map { unquote($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.isEmpty }
    }
}

public enum MainframeScannerError: LocalizedError {
    case missingRoot(URL)
    case missingProjectsDirectory(URL)

    public var errorDescription: String? {
        switch self {
        case .missingRoot(let url):
            return "MainFrame root does not exist: \(url.path)"
        case .missingProjectsDirectory(let url):
            return "Expected a 30_projects directory under \(url.path)"
        }
    }
}

/// FileManager's filesystem APIs are thread-safe; Swift's Foundation overlay
/// does not yet declare the reference type Sendable on this deployment range.
public struct MainframeScanner: @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func scan(root: URL) throws -> [MainframeProject] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MainframeScannerError.missingRoot(root)
        }

        var projects: [MainframeProject] = [rootProject(at: root)]
        let projectsDirectory = root.appendingPathComponent("30_projects", isDirectory: true)
        guard fileManager.fileExists(atPath: projectsDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MainframeScannerError.missingProjectsDirectory(root)
        }

        let children = try fileManager.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        for child in children.sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }) {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { continue }
            let readme = child.appendingPathComponent("README.md")
            let markdown = (try? String(contentsOf: readme, encoding: .utf8)) ?? ""
            let metadata = FrontmatterParser.parse(markdown, fallbackTitle: humanize(child.lastPathComponent))
            projects.append(
                MainframeProject(
                    slug: child.lastPathComponent,
                    path: child,
                    readmePath: fileManager.fileExists(atPath: readme.path) ? readme : nil,
                    metadata: metadata
                )
            )
        }

        return projects
    }

    public static func autodetect(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let candidates = [
            home.appendingPathComponent("MainFrame"),
            home.appendingPathComponent("mainframe"),
            home.appendingPathComponent("Documents/MainFrame"),
            home.appendingPathComponent("Documents/mainframe"),
            home.appendingPathComponent("Developer/MainFrame"),
            home.appendingPathComponent("Projects/MainFrame")
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("30_projects").path) }
    }

    private func rootProject(at root: URL) -> MainframeProject {
        let readme = root.appendingPathComponent("README.md")
        let markdown = (try? String(contentsOf: readme, encoding: .utf8)) ?? ""
        let metadata = FrontmatterParser.parse(markdown, fallbackTitle: "MainFrame")
        return MainframeProject(
            slug: "mainframe",
            path: root,
            readmePath: fileManager.fileExists(atPath: readme.path) ? readme : nil,
            metadata: metadata,
            isMainframeRoot: true
        )
    }

    private func humanize(_ slug: String) -> String {
        slug
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

public enum PromptAssembler {
    public static func assemble(text: String, attachments: [Attachment]) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !attachments.isEmpty else { return trimmed }

        let paths = attachments
            .map { "- \($0.url.path)" }
            .joined(separator: "\n")

        let prefix = trimmed.isEmpty ? "Review the attached local files." : trimmed
        return "\(prefix)\n\nAttached local files:\n\(paths)"
    }
}

public enum InboxWriterError: LocalizedError {
    case missingInbox(URL)
    case emptyCapture

    public var errorDescription: String? {
        switch self {
        case .missingInbox(let url): return "No 00_inbox directory exists under \(url.path)"
        case .emptyCapture: return "There is nothing to capture."
        }
    }
}

public struct InboxWriter: @unchecked Sendable {
    private let fileManager: FileManager
    private let now: @Sendable () -> Date

    public init(
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileManager = fileManager
        self.now = now
    }

    public func capture(
        root: URL,
        project: MainframeProject?,
        text: String,
        attachments: [Attachment]
    ) throws -> URL {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty || !attachments.isEmpty else { throw InboxWriterError.emptyCapture }

        let inbox = root.appendingPathComponent("00_inbox", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: inbox.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw InboxWriterError.missingInbox(root)
        }

        let date = now()
        let id = Self.timestampFormatter.string(from: date)
        let slug = slugify(cleanText.isEmpty ? "attachment-capture" : cleanText)
        var destination = inbox.appendingPathComponent("\(id)-\(slug).md")
        var suffix = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = inbox.appendingPathComponent("\(id)-\(slug)-\(suffix).md")
            suffix += 1
        }

        let displayDate = Self.isoFormatter.string(from: date)
        let projectValue = project?.slug ?? "unscoped"
        let attachmentBlock = attachments.isEmpty
            ? ""
            : "\n## Attachments\n\n" + attachments.map { "- `\($0.url.path)`" }.joined(separator: "\n") + "\n"
        let body = """
        ---
        title: "Conduit capture: \(escapeYAML(title(from: cleanText)))"
        domain: "mainframe"
        type: "raw"
        status: "queued"
        source: "conduit://project/\(projectValue)"
        tags: ["conduit", "capture"]
        captured: "\(displayDate)"
        ---

        # Conduit capture

        ## Context

        - Project: `\(projectValue)`
        - Captured: \(displayDate)

        ## Note

        \(cleanText.isEmpty ? "Attachment-only capture." : cleanText)
        \(attachmentBlock)
        """

        try body.write(to: destination, atomically: true, encoding: .utf8)
        return destination
    }

    private func title(from text: String) -> String {
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? "Attachment capture"
        return String(firstLine.prefix(80))
    }

    private func slugify(_ text: String) -> String {
        let source = title(from: text).lowercased()
        let allowed = source.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        let collapsed = String(allowed)
            .split(separator: "-", omittingEmptySubsequences: true)
            .prefix(8)
            .joined(separator: "-")
        return collapsed.isEmpty ? "capture" : collapsed
    }

    private func escapeYAML(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()

    private static let isoFormatter = ISO8601DateFormatter()
}

public actor SettingsStore {
    private let fileManager: FileManager
    public let directory: URL
    public let file: URL

    public init(
        fileManager: FileManager = .default,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.directory = home.appendingPathComponent(".conduit", isDirectory: true)
        self.file = directory.appendingPathComponent("config.json")
    }

    public func load() -> ConduitSettings {
        Self.loadSnapshot(file: file)
    }

    /// A tiny synchronous snapshot read for app startup. Writes remain
    /// actor-isolated; reads do not need an executor hop that can delay first
    /// window restoration.
    public nonisolated static func loadSnapshot(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ConduitSettings {
        loadSnapshot(file: home.appendingPathComponent(".conduit/config.json"))
    }

    private nonisolated static func loadSnapshot(file: URL) -> ConduitSettings {
        guard let data = try? Data(contentsOf: file),
              let settings = try? JSONDecoder().decode(ConduitSettings.self, from: data) else {
            return ConduitSettings(mainframeRoot: MainframeScanner.autodetect())
        }
        return settings
    }

    public func save(_ settings: ConduitSettings) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: file, options: .atomic)
    }
}
