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

/// Operator-set budgets for Conduit-observed usage (not vendor token quotas).
///
/// Zero means "no limit configured". Meters compare Conduit's own prompt and
/// attach observations against these caps so you can track weekly/session
/// budgets without inventing CLI cost claims.
public struct AgentUsageBudget: Codable, Hashable, Sendable, Equatable {
    /// Soft weekly cap on prompts Conduit delivered (0 = unset).
    public var weeklyPromptLimit: Int
    /// Soft weekly cap on minutes Conduit was attached (0 = unset).
    public var weeklyAttachedMinutesLimit: Int
    /// Soft cap on prompts within the current live attach (0 = unset).
    public var sessionPromptLimit: Int

    public init(
        weeklyPromptLimit: Int = 0,
        weeklyAttachedMinutesLimit: Int = 0,
        sessionPromptLimit: Int = 0
    ) {
        self.weeklyPromptLimit = max(0, weeklyPromptLimit)
        self.weeklyAttachedMinutesLimit = max(0, weeklyAttachedMinutesLimit)
        self.sessionPromptLimit = max(0, sessionPromptLimit)
    }

    public var hasAnyLimit: Bool {
        weeklyPromptLimit > 0
            || weeklyAttachedMinutesLimit > 0
            || sessionPromptLimit > 0
    }
}

public struct AgentProfile: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var command: String
    public var arguments: [String]
    public var kind: AgentKind
    public var enabled: Bool
    /// Conduit-injected permission posture for new launches of this profile.
    public var permissionMode: AgentPermissionMode
    /// Optional weekly / session budgets for observed usage meters.
    public var usageBudget: AgentUsageBudget
    /// Provider model selected for the next launch. Nil means the CLI default.
    public var model: String?
    /// How Conduit passes ``model`` to the executable.
    public var modelLaunchStyle: AgentModelLaunchStyle
    /// Provider-reported or operator-configured context limit, when known.
    public var contextWindowTokens: Int?

    public init(
        id: UUID = UUID(),
        name: String,
        command: String,
        arguments: [String] = [],
        kind: AgentKind = .cli,
        enabled: Bool = true,
        permissionMode: AgentPermissionMode = .agentDefault,
        usageBudget: AgentUsageBudget = AgentUsageBudget(),
        model: String? = nil,
        modelLaunchStyle: AgentModelLaunchStyle = .auto,
        contextWindowTokens: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.arguments = arguments
        self.kind = kind
        self.enabled = enabled
        self.permissionMode = permissionMode
        self.usageBudget = usageBudget
        self.model = model
        self.modelLaunchStyle = modelLaunchStyle
        self.contextWindowTokens = contextWindowTokens.map { max(0, $0) }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, command, arguments, kind, enabled, permissionMode, usageBudget
        case model, modelLaunchStyle, contextWindowTokens
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        command = try container.decode(String.self, forKey: .command)
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        kind = try container.decodeIfPresent(AgentKind.self, forKey: .kind) ?? .cli
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        permissionMode = try container.decodeIfPresent(
            AgentPermissionMode.self,
            forKey: .permissionMode
        ) ?? .agentDefault
        usageBudget = try container.decodeIfPresent(
            AgentUsageBudget.self,
            forKey: .usageBudget
        ) ?? AgentUsageBudget()
        model = try container.decodeIfPresent(String.self, forKey: .model)
        modelLaunchStyle = try container.decodeIfPresent(
            AgentModelLaunchStyle.self,
            forKey: .modelLaunchStyle
        ) ?? .auto
        contextWindowTokens = try container.decodeIfPresent(
            Int.self,
            forKey: .contextWindowTokens
        ).map { max(0, $0) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(command, forKey: .command)
        try container.encode(arguments, forKey: .arguments)
        try container.encode(kind, forKey: .kind)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(permissionMode, forKey: .permissionMode)
        try container.encode(usageBudget, forKey: .usageBudget)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encode(modelLaunchStyle, forKey: .modelLaunchStyle)
        try container.encodeIfPresent(contextWindowTokens, forKey: .contextWindowTokens)
    }

    public static let defaults: [AgentProfile] = [
        AgentProfile(name: "Shell", command: "/bin/zsh", arguments: ["-l"], kind: .shell),
        AgentProfile(name: "Claude", command: "claude"),
        AgentProfile(name: "Codex", command: "codex"),
        AgentProfile(name: "Antigravity", command: "agy"),
        AgentProfile(name: "Gemini CLI", command: "gemini"),
        AgentProfile(name: "Grok", command: "grok"),
        AgentProfile(name: "OpenCode", command: "opencode"),
        AgentProfile(
            name: "Ollama",
            command: "ollama",
            modelLaunchStyle: .ollamaRun
        ),
        AgentProfile(name: "Cursor Agent", command: "cursor-agent"),
        AgentProfile(name: "Aider", command: "aider")
    ]

    /// Research-backed profiles that can be offered as an explicit settings
    /// migration for existing configs. Existing user profiles are never
    /// silently rewritten.
    public static let recommendedCLIProfiles: [AgentProfile] = [
        AgentProfile(
            name: "Ollama",
            command: "ollama",
            modelLaunchStyle: .ollamaRun
        ),
        AgentProfile(name: "Cursor Agent", command: "cursor-agent"),
        AgentProfile(name: "Gemini CLI", command: "gemini"),
        AgentProfile(name: "Aider", command: "aider")
    ]
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
    /// When true, CLI prompt delivery prepends a compact host envelope.
    public var injectHostEnvelope: Bool
    /// When true, Conversation follows new events by default.
    public var followConversationByDefault: Bool
    /// When true, show the in-Conversation terminal control strip for menu replies.
    public var showConversationControls: Bool
    /// Loopback session API (D-039). Off by default.
    public var enableSessionAPI: Bool
    /// Allow ChatGPT/phone clients to create, send, interrupt, and close.
    /// Approvals still stay Mac-side. Off unless Session API is also on.
    public var enableSessionAPIWrites: Bool

    public init(
        mainframeRoot: URL? = nil,
        mainframeRootBookmark: Data? = nil,
        agents: [AgentProfile] = AgentProfile.defaults,
        showContextByDefault: Bool = true,
        restoreSessions: Bool = true,
        injectHostEnvelope: Bool = true,
        followConversationByDefault: Bool = true,
        showConversationControls: Bool = true,
        enableSessionAPI: Bool = false,
        enableSessionAPIWrites: Bool = false
    ) {
        self.mainframeRoot = mainframeRoot
        self.mainframeRootBookmark = mainframeRootBookmark
        self.agents = agents
        self.showContextByDefault = showContextByDefault
        self.restoreSessions = restoreSessions
        self.injectHostEnvelope = injectHostEnvelope
        self.followConversationByDefault = followConversationByDefault
        self.showConversationControls = showConversationControls
        self.enableSessionAPI = enableSessionAPI
        self.enableSessionAPIWrites = enableSessionAPIWrites
    }

    private enum CodingKeys: String, CodingKey {
        case mainframeRoot, mainframeRootBookmark, agents
        case showContextByDefault, restoreSessions
        case injectHostEnvelope, followConversationByDefault, showConversationControls
        case enableSessionAPI, enableSessionAPIWrites
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mainframeRoot = try container.decodeIfPresent(URL.self, forKey: .mainframeRoot)
        mainframeRootBookmark = try container.decodeIfPresent(
            Data.self,
            forKey: .mainframeRootBookmark
        )
        agents = try container.decodeIfPresent([AgentProfile].self, forKey: .agents)
            ?? AgentProfile.defaults
        showContextByDefault = try container.decodeIfPresent(
            Bool.self,
            forKey: .showContextByDefault
        ) ?? true
        restoreSessions = try container.decodeIfPresent(
            Bool.self,
            forKey: .restoreSessions
        ) ?? true
        injectHostEnvelope = try container.decodeIfPresent(
            Bool.self,
            forKey: .injectHostEnvelope
        ) ?? true
        followConversationByDefault = try container.decodeIfPresent(
            Bool.self,
            forKey: .followConversationByDefault
        ) ?? true
        showConversationControls = try container.decodeIfPresent(
            Bool.self,
            forKey: .showConversationControls
        ) ?? true
        enableSessionAPI = try container.decodeIfPresent(
            Bool.self,
            forKey: .enableSessionAPI
        ) ?? false
        enableSessionAPIWrites = try container.decodeIfPresent(
            Bool.self,
            forKey: .enableSessionAPIWrites
        ) ?? false
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

/// Compact Conduit-recorded host context prepended to CLI prompt delivery.
///
/// This is not completion evidence, private reasoning, or a substitute for Raw.
/// Conversation still records the human prompt text separately from the
/// rendered delivery payload that may include this envelope.
public enum HostEnvelope {
    public struct Context: Equatable, Sendable {
        public var taskSessionID: String?
        public var projectPath: String?
        public var agentName: String
        public var surface: String
        public var tmuxSessionName: String?
        public var attachmentCount: Int

        public init(
            taskSessionID: String? = nil,
            projectPath: String? = nil,
            agentName: String,
            surface: String = "conversation",
            tmuxSessionName: String? = nil,
            attachmentCount: Int = 0
        ) {
            self.taskSessionID = taskSessionID
            self.projectPath = projectPath
            self.agentName = agentName
            self.surface = surface
            self.tmuxSessionName = tmuxSessionName
            self.attachmentCount = attachmentCount
        }
    }

    /// Whether Conduit should inject a host envelope for this agent profile.
    /// App-server Codex already has structured task/cwd/model on the thread;
    /// wrapping those turns as a PTY host block pollutes Conversation records.
    public static func shouldInject(for agent: AgentProfile) -> Bool {
        agent.kind != .shell && !agent.preferredSessionBackend.isStructured
    }

    public static func render(_ context: Context) -> String {
        var lines = ["<<CONDUIT_HOST"]
        if let task = context.taskSessionID, !task.isEmpty {
            lines.append("task: \(task)")
        }
        if let project = context.projectPath, !project.isEmpty {
            lines.append("project: \(project)")
        }
        lines.append("agent: \(context.agentName)")
        lines.append("surface: \(context.surface)")
        if let tmux = context.tmuxSessionName, !tmux.isEmpty {
            lines.append("tmux: \(tmux)")
        }
        if context.attachmentCount > 0 {
            lines.append("attachments: \(context.attachmentCount)")
        }
        lines.append("note: host context only; not completion or verification")
        lines.append(">>")
        return lines.joined(separator: "\n")
    }

    public static func wrap(prompt: String, context: Context) -> String {
        let envelope = render(context)
        let body = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { return envelope }
        return envelope + "\n\n" + body
    }
}

/// Presentation-only compaction for Derived-from-Raw blocks.
///
/// Does not mutate retained JSONL; Conversation may show this form while the
/// source event keeps the full projected text. Scrubbing never invents prose —
/// it only drops blank runs and common TUI chrome so Conversation can read as
/// a turn stream instead of a terminal viewport.
public enum ConversationDisplayText {
    /// Collapses long blank runs and trailing per-line whitespace so TUI chrome
    /// is less sparse without inventing content.
    public static func compactDerived(_ text: String) -> String {
        compactLines(canonicalLines(text)).joined(separator: "\n")
    }

    /// Workstation-facing form: turn multi-column TUI paint into a clean
    /// document (main prose only). Presentation only — retained JSONL stays raw.
    public static func workstationDerived(_ text: String) -> String {
        let compacted = compactLines(canonicalLines(text))
        let columnStripped = compacted.map(stripSideColumn)
        var kept: [String] = []
        var blankRun = 0
        var droppedOnlyChrome = true
        for line in columnStripped {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                blankRun += 1
                if blankRun <= 1 {
                    kept.append("")
                }
                continue
            }
            blankRun = 0
            if isPresentationChromeLine(line) || isAgentAppChromeLine(trimmed) {
                continue
            }
            droppedOnlyChrome = false
            kept.append(line.trimmingCharacters(in: .whitespaces))
        }
        // If scrubbing would erase the block entirely, fall back to compact form
        // so the operator still sees something rather than a silent hole.
        if droppedOnlyChrome {
            return compacted.joined(separator: "\n")
        }
        kept = reflowSoftWrappedProse(kept)
        while kept.first?.isEmpty == true {
            kept.removeFirst()
        }
        while kept.last?.isEmpty == true {
            kept.removeLast()
        }
        return kept.joined(separator: "\n")
    }

    /// Lightweight block parse for document-style Conversation rendering.
    /// Not a full Markdown engine — headings, fences, bullets, and paragraphs only.
    public static func proseBlocks(in text: String) -> [ConversationProseBlock] {
        let lines = canonicalLines(text)
        var blocks: [ConversationProseBlock] = []
        var index = 0
        var paragraph: [String] = []

        func flushParagraph() {
            let body = paragraph.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else {
                paragraph = []
                return
            }
            blocks.append(.paragraph(body))
            paragraph = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                let language = String(trimmed.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
                index += 1
                var code: [String] = []
                while index < lines.count {
                    let codeLine = lines[index]
                    if codeLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        index += 1
                        break
                    }
                    code.append(codeLine)
                    index += 1
                }
                blocks.append(
                    .code(
                        language: language.isEmpty ? nil : language,
                        body: code.joined(separator: "\n")
                    )
                )
                continue
            }

            if let heading = headingMatch(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if let bullet = bulletMatch(line) {
                flushParagraph()
                var items = [bullet]
                index += 1
                while index < lines.count, let next = bulletMatch(lines[index]) {
                    items.append(next)
                    index += 1
                }
                blocks.append(.bullets(items))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            paragraph.append(line)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    // MARK: - Private helpers

    private static func canonicalLines(_ text: String) -> [String] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }
    }

    private static func compactLines(_ lines: [String]) -> [String] {
        var compacted: [String] = []
        var blankRun = 0
        for raw in lines {
            let line = raw.replacingOccurrences(
                of: "\\s+$",
                with: "",
                options: .regularExpression
            )
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                blankRun += 1
                if blankRun <= 1 {
                    compacted.append("")
                }
            } else {
                blankRun = 0
                compacted.append(line)
            }
        }
        while compacted.first?.isEmpty == true {
            compacted.removeFirst()
        }
        while compacted.last?.isEmpty == true {
            compacted.removeLast()
        }
        return compacted
    }

    /// Drop right-hand inspector columns that TUI agents paint beside the
    /// main message stream (OpenCode Context/LSP, etc.).
    private static func stripSideColumn(_ line: String) -> String {
        // Split on a wide gap (2+ spaces) when the right fragment looks like
        // side-panel chrome rather than sentence continuation.
        guard let regex = try? NSRegularExpression(
            pattern: #"^(.*?)  {2,}(\S.*)$"#
        ) else { return line }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              match.numberOfRanges >= 3,
              let leftRange = Range(match.range(at: 1), in: line),
              let rightRange = Range(match.range(at: 2), in: line)
        else { return line }
        let left = String(line[leftRange])
        let right = String(line[rightRange]).trimmingCharacters(in: .whitespaces)
        if isAgentAppChromeLine(right) || isSidePanelFragment(right) {
            return left
        }
        return line
    }

    private static func isSidePanelFragment(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower == "context" || lower == "lsp" { return true }
        if lower.hasSuffix(" tokens") { return true }
        if lower.hasSuffix("% used") { return true }
        if lower.hasPrefix("$") && lower.contains("spent") { return true }
        if lower.hasPrefix("writing a ") { return true }
        if lower.hasPrefix("lsps are") { return true }
        if text.count <= 24 && !text.contains(" ") { return true }
        return false
    }

    /// OpenCode / Claude-style chrome that is not the assistant answer.
    private static func isAgentAppChromeLine(_ trimmed: String) -> Bool {
        let lower = trimmed.lowercased()

        // Input caret / echoed slash in the agent input box.
        if trimmed == "|" || trimmed == "▌" || trimmed == "❚" {
            return true
        }
        if trimmed.hasPrefix("| ") || trimmed.hasPrefix("│ ") {
            let rest = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("/") || rest.isEmpty { return true }
        }
        if lower.range(of: #"^/[a-z][a-z0-9_-]*$"#, options: .regularExpression) != nil {
            // Lone slash-command echo (already shown as You).
            return true
        }

        // Thought *duration* chrome only (e.g. "+ Thought: 1.0s"). Keep real
        // thought/reasoning content so Conversation can show it while live and
        // merge can preserve it after the TUI collapses the block.
        if ConversationCaptureMerge.isThoughtDurationOnly(trimmed) {
            return true
        }
        if lower.hasPrefix("compaction") || lower.hasPrefix("build ·")
            || lower.hasPrefix("build ·") || lower.contains(" · big pickle")
        {
            return true
        }
        if lower.hasPrefix("build ") && lower.contains("·") { return true }
        if lower == "context" || lower == "lsp" { return true }
        if lower == "lsps are disabled" || lower.hasPrefix("lsps are") {
            return true
        }
        if lower.hasSuffix("% used") { return true }
        if lower.hasSuffix(" tokens") && trimmed.count < 40 { return true }
        if lower.hasPrefix("$") && lower.contains("spent") { return true }
        if lower.hasPrefix("writing a ") { return true }
        if lower.contains("ctrl+p") { return true }
        if lower.hasPrefix("opencode ") && lower.range(
            of: #"\d+\.\d+"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        // Footer path alone.
        if trimmed.hasPrefix("/") && (
            lower.contains("/users/")
                || lower.contains("/home/")
                || lower.contains("desktop/")
                || lower.hasSuffix(":main")
        ) {
            return true
        }
        // Model / agent brand row like "Build · Big Pickle OpenCode Zen"
        if lower.contains("opencode") && lower.contains("·") && trimmed.count < 80 {
            return true
        }
        return false
    }

    /// Join soft-wrapped terminal lines into readable paragraphs.
    private static func reflowSoftWrappedProse(_ lines: [String]) -> [String] {
        var out: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                out.append("")
                continue
            }
            if let last = out.last, !last.isEmpty {
                let lastTrimmed = last.trimmingCharacters(in: .whitespaces)
                let lastEndsSentence = lastTrimmed.last.map {
                    ".!?:)".contains($0)
                } ?? true
                let looksContinuation = trimmed.first?.isLowercase == true
                    || (!lastEndsSentence && !trimmed.hasPrefix("-")
                        && !trimmed.hasPrefix("•")
                        && !trimmed.hasPrefix("#")
                        && !trimmed.hasPrefix("```"))
                if looksContinuation && !lastEndsSentence {
                    out[out.count - 1] = lastTrimmed + " " + trimmed
                    continue
                }
            }
            out.append(trimmed)
        }
        return out
    }

    /// Pure presentation chrome — never drops numbered menu options or prose.
    private static func isPresentationChromeLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }

        // Box / rule / spinner-only lines.
        let decorative = CharacterSet.whitespaces
            .union(CharacterSet(charactersIn: "─━═╌╍┄┅┐└┴┬├─┤┼╭╮╯╰│┃┏┓┗┛╔╗╚╝║═╒╓╔╕╖╗╘╙╚╛╜╝╞╟╠╡╢╣╤╥╦╧╨╩╪╫╬░▒▓█▀▄▌▐■□▪▫●○◦•·▸▹►▻╱╳╲+*|`~_"))
        if trimmed.unicodeScalars.allSatisfy({ decorative.contains($0) }) {
            return true
        }

        // Braille / classic spinner glyphs (optionally with trailing status).
        let spinnerPrefix = CharacterSet(charactersIn: "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏◐◓◑◒⣾⣽⣻⢿⡿⣟⣯⣷⠁⠂⠄⡀⢀⠠⠐⠈")
        if let first = trimmed.unicodeScalars.first, spinnerPrefix.contains(first) {
            let rest = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            if rest.isEmpty
                || rest.lowercased().hasPrefix("thinking")
                || rest.lowercased().hasPrefix("working")
                || rest.lowercased().hasPrefix("waiting")
            {
                return true
            }
        }

        let lower = trimmed.lowercased()
        let chromeExact: Set<String> = [
            "esc to interrupt",
            "esc to cancel",
            "press esc to cancel",
            "ctrl+c to interrupt",
            "ctrl-c to interrupt",
            "working…",
            "working...",
            "thinking…",
            "thinking...",
            "awaiting input",
        ]
        if chromeExact.contains(lower) {
            return true
        }

        // Navigation chrome that is not a numbered choice line.
        if lower.contains("↑/↓") || lower.contains("up/down") {
            if lower.contains("navigate") || lower.contains("arrow") {
                return true
            }
        }
        if lower.hasPrefix("tab ") && lower.contains("amend") {
            return true
        }
        if lower == "esc to cancel" || lower.hasPrefix("esc ·") {
            return true
        }

        // Pure status footers like "claude-opus · 2.1k tokens" without prose body.
        if trimmed.contains("·") {
            let parts = trimmed.split(separator: "·").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if parts.count >= 2,
               parts.allSatisfy({ part in
                   part.count <= 28
                       || part.lowercased().contains("token")
                       || part.lowercased().contains("context")
                       || part.range(of: #"^\d+(\.\d+)?[kKmM]?$"#, options: .regularExpression) != nil
               }),
               !trimmed.contains("http"),
               trimmed.count < 80
            {
                // Only drop when there is no sentence punctuation (likely chrome).
                if !trimmed.contains(where: { ".!?:".contains($0) }) {
                    return true
                }
            }
        }

        return false
    }

    private static func headingMatch(_ trimmed: String) -> (level: Int, text: String)? {
        guard trimmed.hasPrefix("#") else { return nil }
        var level = 0
        for ch in trimmed {
            if ch == "#" {
                level += 1
                if level > 3 { return nil }
            } else {
                break
            }
        }
        guard level >= 1, level <= 3 else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.first == " " || rest.first == "\t" else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (level, text)
    }

    private static func bulletMatch(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for prefix in ["- ", "* ", "• "] {
            if trimmed.hasPrefix(prefix) {
                let body = String(trimmed.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces)
                return body.isEmpty ? nil : body
            }
        }
        // Numbered list "1. item" used as prose (not interactive "1. Yes").
        if let range = trimmed.range(
            of: #"^\d+\.\s+\S"#,
            options: .regularExpression
        ), range.lowerBound == trimmed.startIndex {
            if let dot = trimmed.firstIndex(of: ".") {
                let body = trimmed[trimmed.index(after: dot)...]
                    .trimmingCharacters(in: .whitespaces)
                return body.isEmpty ? nil : body
            }
        }
        return nil
    }
}

/// One display block inside a Conversation assistant turn. Presentation only.
public enum ConversationProseBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullets([String])
    case code(language: String?, body: String)
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
