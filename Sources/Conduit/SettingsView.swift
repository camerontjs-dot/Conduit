#if os(macOS)
import ConduitCore
import SwiftUI

/// Grouped settings surface for daily-driver Conduit configuration.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var tab: SettingsTab = .general

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    private enum SettingsTab: String, CaseIterable, Identifiable {
        case general
        case appearance
        case agents
        case conversation
        case privacy
        case utilities

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "General"
            case .appearance: return "Appearance"
            case .agents: return "Agents"
            case .conversation: return "Conversation"
            case .privacy: return "Privacy"
            case .utilities: return "Utilities"
            }
        }

        var systemImage: String {
            switch self {
            case .general: return "gearshape"
            case .appearance: return "paintpalette"
            case .agents: return "cpu"
            case .conversation: return "bubble.left.and.bubble.right"
            case .privacy: return "lock.shield"
            case .utilities: return "wrench.and.screwdriver"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "gearshape.2.fill")
                    .foregroundStyle(palette.accent)
                Text("Conduit Settings")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(palette.text)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(palette.surface)

            Divider().overlay(palette.line)

            HStack(alignment: .top, spacing: 0) {
                sidebar
                Divider().overlay(palette.line)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider().overlay(palette.line)
            HStack {
                Text("Settings save to ~/.conduit/config.json")
                    .font(.caption)
                    .foregroundStyle(palette.faint)
                Spacer()
                Button("Save", action: model.saveSettings)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
            .background(palette.rail)
        }
        .frame(minWidth: 720, minHeight: 480)
        .background(palette.app)
        .tint(palette.accent)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SettingsTab.allCases) { item in
                Button {
                    tab = item
                } label: {
                    Label(item.title, systemImage: item.systemImage)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            tab == item ? palette.accentSoft : Color.clear
                        )
                        .foregroundStyle(tab == item ? palette.ink : palette.text)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(10)
        .frame(width: 180)
        .background(palette.rail)
    }

    @ViewBuilder
    private var detail: some View {
        Form {
            switch tab {
            case .general:
                generalSection
            case .appearance:
                appearanceSection
            case .agents:
                agentsSection
            case .conversation:
                conversationSection
            case .privacy:
                privacySection
            case .utilities:
                utilitiesSection
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding(8)
    }

    private var generalSection: some View {
        Section("MainFrame") {
            HStack {
                Text(model.settings.mainframeRoot?.path ?? "Not configured")
                    .lineLimit(1)
                    .foregroundStyle(
                        model.settings.mainframeRoot == nil ? palette.dim : palette.text
                    )
                Spacer()
                Button("Choose…", action: model.chooseMainframeRoot)
            }
            Toggle(
                "Use durable tmux sessions when available",
                isOn: $model.settings.restoreSessions
            )
            .help("Closing a Conduit tab detaches tmux instead of ending the work.")
            Toggle(
                "Listen for read-only Session API on loopback",
                isOn: $model.settings.enableSessionAPI
            )
            .help("D-039. 127.0.0.1:8750/mcp with a local bearer token. Write tools stay off. Save settings to apply.")
            if let address = model.sessionAPIAddress {
                Text("Listening at \(address). Token: ~/.conduit/session-api-token")
                    .font(.caption2)
                    .foregroundStyle(palette.dim)
            }
            Toggle(
                "Show project context by default",
                isOn: $model.settings.showContextByDefault
            )
        }
    }

    private var appearanceSection: some View {
        Group {
            Section("Palette") {
                ForEach(PaletteID.allCases, id: \.self) { id in
                    paletteRow(id)
                }
            }
            Section("Surface finish") {
                Toggle(
                    "Sheen (shiny matte)",
                    isOn: Binding(
                        get: { themeStore.surfaceFinish == .sheen },
                        set: { themeStore.surfaceFinish = $0 ? .sheen : .matte }
                    )
                )
                .help("Soft satin highlight layered on top of the selected palette. Try it with every colour.")
                Text(themeStore.surfaceFinish.help)
                    .font(.caption)
                    .foregroundStyle(palette.dim)
            }
            Section("Density") {
                Picker("Density", selection: $model.density) {
                    ForEach(Density.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text("Focused Flow, Balanced, or Operator Deck layout density. Density sets Inspector card and peek defaults until you customize them.")
                    .font(.caption)
                    .foregroundStyle(palette.dim)
            }
            Section("Companions & peek (optional)") {
                Toggle(
                    "Operator peek shelf",
                    isOn: Binding(
                        get: { model.showsOperatorPeek },
                        set: { model.setOperatorPeekEnabled($0) }
                    )
                )
                .help("Optional multi-agent shelf. Off by default in Focused/Balanced; on in Operator until customized.")
                Button("Reset peek to density default") {
                    model.resetOperatorPeekToDensityDefault()
                }
                .buttonStyle(.borderless)

                Picker(
                    "Companion size",
                    selection: Binding(
                        get: { model.companionScale },
                        set: { model.setCompanionScale($0) }
                    )
                ) {
                    ForEach(CompanionScale.allCases, id: \.self) { scale in
                        Text(scale.displayName).tag(scale)
                    }
                }
                .pickerStyle(.segmented)
                Button("Reset companion size to density default") {
                    model.resetCompanionScaleToDensityDefault()
                }
                .buttonStyle(.borderless)

                Toggle(
                    "Conversation companion bar",
                    isOn: $model.companionChromeEnabled
                )
                .help(
                    "Optional selected-agent strip above Conversation. Uses locked masters or exact poses; never launches."
                )
                Toggle("Selected companion shelf in rail", isOn: $model.companionShelfEnabled)
                Toggle("Sprites on all known-profile rows", isOn: $model.railSpritesForAllRows)
                Toggle("Juicy operator feedback", isOn: $model.juicyFeedbackEnabled)
                    .help("Select/send/inspector micro-motion. Never XP or progress. Honors Reduce Motion.")
                Toggle("Output-active companion pulse", isOn: $model.outputActivePulseEnabled)
                    .help("Only while observed terminal output is active. Stops when quiet.")

                if !model.enabledAgents.isEmpty {
                    Text("Peek agents (empty filter = all enabled)")
                        .font(.caption)
                        .foregroundStyle(palette.dim)
                    ForEach(model.enabledAgents) { agent in
                        Toggle(
                            agent.name,
                            isOn: Binding(
                                get: {
                                    model.operatorPeekAgentIDs.isEmpty
                                        || model.operatorPeekAgentIDs.contains(agent.id)
                                },
                                set: { on in
                                    if model.operatorPeekAgentIDs.isEmpty {
                                        // Start from all enabled, then drop this one if off.
                                        model.operatorPeekAgentIDs = Set(
                                            model.enabledAgents.map(\.id)
                                        )
                                    }
                                    if on {
                                        model.operatorPeekAgentIDs.insert(agent.id)
                                        if model.operatorPeekAgentIDs.count
                                            == model.enabledAgents.count {
                                            model.clearOperatorPeekAgentFilter()
                                        }
                                    } else {
                                        model.operatorPeekAgentIDs.remove(agent.id)
                                    }
                                }
                            )
                        )
                    }
                    Button("Show all enabled agents in peek") {
                        model.clearOperatorPeekAgentFilter()
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private var agentsSection: some View {
        Section {
            Text("Permission mode injects launch flags for supported CLIs. It applies on the next launch, not to an already-running process.")
                .font(.caption)
                .foregroundStyle(palette.dim)
            Text("Model catalogs come from the installed CLI. A context value is provider-reported or operator-entered; blank means unknown. OpenCode's free models and Ollama's local/cloud-tagged models appear after refresh. Cursor Agent, Gemini CLI, and Aider accept configured model IDs without a hardcoded catalog.")
                .font(.caption)
                .foregroundStyle(palette.dim)

            ForEach($model.settings.agents) { $agent in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Toggle("", isOn: $agent.enabled).labelsHidden()
                        TextField("Name", text: $agent.name)
                            .frame(width: 110)
                        TextField("Command", text: $agent.command)
                        Button(role: .destructive) {
                            model.settings.agents.removeAll { $0.id == agent.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(agent.name)")
                    }
                    HStack {
                        Text("Arguments")
                            .font(.caption)
                            .foregroundStyle(palette.dim)
                            .frame(width: 70, alignment: .leading)
                        TextField(
                            "Optional flags",
                            text: Binding(
                                get: { ArgumentTokenizer.join(agent.arguments) },
                                set: { agent.arguments = ArgumentTokenizer.tokenize($0) }
                            )
                        )
                    }
                    if agent.kind != .shell {
                        HStack {
                            Text("Model")
                                .font(.caption)
                                .foregroundStyle(palette.dim)
                                .frame(width: 70, alignment: .leading)
                            TextField(
                                "Blank = CLI default",
                                text: Binding(
                                    get: { agent.model ?? "" },
                                    set: {
                                        let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                                        agent.model = value.isEmpty ? nil : value
                                    }
                                )
                            )
                            Picker("Launch style", selection: $agent.modelLaunchStyle) {
                                ForEach(AgentModelLaunchStyle.allCases, id: \.self) { style in
                                    Text(style.displayName).tag(style)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 150)
                        }
                        HStack {
                            Text("Context")
                                .font(.caption)
                                .foregroundStyle(palette.dim)
                                .frame(width: 70, alignment: .leading)
                            TextField(
                                "0 = unknown",
                                text: Binding(
                                    get: {
                                        agent.contextWindowTokens.map(String.init) ?? ""
                                    },
                                    set: {
                                        agent.contextWindowTokens = Int($0.filter(\.isNumber))
                                    }
                                )
                            )
                            .frame(width: 120)
                            Text("tokens · visible composer estimate only")
                                .font(.caption2)
                                .foregroundStyle(palette.faint)
                        }
                    }
                    HStack {
                        Text("Permission")
                            .font(.caption)
                            .foregroundStyle(palette.dim)
                            .frame(width: 70, alignment: .leading)
                        if agent.kind == .shell {
                            Text("Shell has no agent permission mode")
                                .font(.caption)
                                .foregroundStyle(palette.faint)
                        } else {
                            Picker("Permission", selection: $agent.permissionMode) {
                                ForEach(AgentPermissionMode.allCases, id: \.self) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 220)
                            Text(agent.permissionMode.help)
                                .font(.caption2)
                                .foregroundStyle(palette.faint)
                                .lineLimit(2)
                        }
                    }
                    if agent.kind != .shell {
                        let resolved = AgentLaunchArguments.resolved(for: agent)
                        Text("Launch: \(agent.command) \(ArgumentTokenizer.join(resolved))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(palette.faint)
                            .lineLimit(2)
                            .help(ArgumentTokenizer.join(resolved))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Usage limits (Conduit-observed, not vendor tokens)")
                            .font(.caption)
                            .foregroundStyle(palette.dim)
                        HStack {
                            Text("Week prompts")
                                .font(.caption2)
                                .foregroundStyle(palette.faint)
                                .frame(width: 100, alignment: .leading)
                            TextField(
                                "0 = none",
                                value: $agent.usageBudget.weeklyPromptLimit,
                                format: .number
                            )
                            .frame(maxWidth: 90)
                            Text("Week minutes")
                                .font(.caption2)
                                .foregroundStyle(palette.faint)
                            TextField(
                                "0 = none",
                                value: $agent.usageBudget.weeklyAttachedMinutesLimit,
                                format: .number
                            )
                            .frame(maxWidth: 90)
                        }
                        HStack {
                            Text("Session prompts")
                                .font(.caption2)
                                .foregroundStyle(palette.faint)
                                .frame(width: 100, alignment: .leading)
                            TextField(
                                "0 = none",
                                value: $agent.usageBudget.sessionPromptLimit,
                                format: .number
                            )
                            .frame(maxWidth: 90)
                            Text("0 disables a limit")
                                .font(.caption2)
                                .foregroundStyle(palette.faint)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Button("Add Agent") {
                model.settings.agents.append(
                    AgentProfile(name: "Agent", command: "")
                )
            }
            Button("Add recommended CLI profiles") {
                model.addRecommendedCLIProfiles()
            }
            .help("Adds Ollama, Cursor Agent, Gemini CLI, and Aider without changing existing agents")
        } header: {
            Text("Agent CLIs")
        }
    }

    private var conversationSection: some View {
        Section("Conversation surface") {
            Toggle(
                "Inject Conduit host envelope on CLI deliveries",
                isOn: $model.settings.injectHostEnvelope
            )
            .help("Prepends task/project/agent context for non-shell agents. Conversation still shows what you typed.")
            Toggle(
                "Follow latest messages by default",
                isOn: $model.settings.followConversationByDefault
            )
            Toggle(
                "Show Conversation control strip (menu replies)",
                isOn: $model.settings.showConversationControls
            )
            .help("Number keys, arrows, Esc, and Enter for agent permission menus without opening Raw.")
            Text("Menu replies and slash commands from Conversation inject into the live PTY without ending capture. Switching to Raw keeps capture warm so the turn stream can catch up.")
                .font(.caption)
                .foregroundStyle(palette.dim)
        }
    }

    private var privacySection: some View {
        Section("Local data") {
            Text("Conversation history is stored under ~/.conduit/conversations as append-only JSONL. Task metadata is under ~/.conduit/task-sessions.")
                .font(.caption)
                .foregroundStyle(palette.dim)
            Text("Attachments are local path references (and temporary images under ~/.conduit/attachments). Conduit does not upload or index this data.")
                .font(.caption)
                .foregroundStyle(palette.dim)
            Text("Derived-from-Raw blocks can retain secrets the CLI printed. There is no automatic expiry or remote sync.")
                .font(.caption)
                .foregroundStyle(palette.faint)
            Text("Permission full-auto modes reduce prompts by telling the agent CLI to skip its own gates — use only on machines and trees you trust.")
                .font(.caption)
                .foregroundStyle(palette.faint)
        }
    }

    private var utilitiesSection: some View {
        Section("Diagnostics") {
            HStack {
                Button("Run Conduit Doctor") { model.showDiagnostics = true }
                Button("Open Resource Deck") { model.showResources = true }
                Spacer()
            }
            Text("Conduit records process facts and Git state, but does not treat terminal prose as completion evidence.")
                .font(.caption)
                .foregroundStyle(palette.dim)
        }
    }

    private func paletteRow(_ id: PaletteID) -> some View {
        let isSelected = themeStore.selectedPalette == id
        let swatch = themeStore.accentSwatch(for: id, colorScheme: colorScheme)
        return Button {
            themeStore.select(id)
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(swatch)
                    .frame(width: 18, height: 18)
                    .overlay(
                        Circle()
                            .strokeBorder(palette.line, lineWidth: 1)
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(id.displayName)
                        .foregroundStyle(palette.text)
                    Text(id.mood)
                        .font(.caption)
                        .foregroundStyle(palette.dim)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(swatch)
                        .accessibilityLabel("Selected")
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(id.displayName) palette")
        .accessibilityValue(isSelected ? "Selected" : id.mood)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
#endif
