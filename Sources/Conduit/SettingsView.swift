#if os(macOS)
import ConduitCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    var body: some View {
        Form {
            Section("Palette") {
                ForEach(PaletteID.allCases, id: \.self) { id in
                    paletteRow(id)
                }
            }

            Section("Density") {
                Picker("Density", selection: $model.density) {
                    ForEach(Density.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Workspace density")
                .accessibilityValue(model.density.displayName)

                Text("Controls how densely workspace information is shown. Layout behavior is applied by density mode.")
                    .font(.caption)
                    .foregroundStyle(palette.dim)
            }

            Section("MainFrame") {
                HStack {
                    Text(model.settings.mainframeRoot?.path ?? "Not configured")
                        .lineLimit(1)
                        .foregroundStyle(model.settings.mainframeRoot == nil ? palette.dim : palette.text)
                    Spacer()
                    Button("Choose…", action: model.chooseMainframeRoot)
                }
                Toggle("Show project context by default", isOn: $model.settings.showContextByDefault)
                Toggle("Use durable tmux sessions when available", isOn: $model.settings.restoreSessions)
                    .help("When enabled, closing a Conduit tab detaches the tmux session instead of ending the underlying work.")
            }

            Section("Agent CLIs") {
                ForEach($model.settings.agents) { $agent in
                    HStack {
                        Toggle("", isOn: $agent.enabled).labelsHidden()
                        TextField("Name", text: $agent.name).frame(width: 95)
                        TextField("Command", text: $agent.command)
                        TextField("Arguments", text: Binding(
                            get: { ArgumentTokenizer.join(agent.arguments) },
                            set: { agent.arguments = ArgumentTokenizer.tokenize($0) }
                        ))
                        .frame(width: 150)
                        Button(role: .destructive) {
                            model.settings.agents.removeAll { $0.id == agent.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(agent.name) profile")
                    }
                }
                Button("Add Agent") {
                    model.settings.agents.append(AgentProfile(name: "Agent", command: ""))
                }
            }

            Section("Local conversation history") {
                Text("Select a task in the left sidebar to reopen its retained thread. New prompts, local attachment references, and source-labelled rendered output are stored in ~/.conduit/conversations.")
                    .font(.caption)
                    .foregroundStyle(palette.dim)
                Text("Attaching a path does not copy that file, but text the CLI renders—including file contents or secrets—may be retained. Each rendered projection revision is capped at 16,000 characters; append-only earlier revisions remain in the local source.")
                    .font(.caption)
                    .foregroundStyle(palette.faint)
                Text("Raw PTY bytes are not stored there. Conduit does not silently upload, index, expire, or clear this history.")
                    .font(.caption)
                    .foregroundStyle(palette.faint)
            }

            Section("Utilities") {
                HStack {
                    Button("Run Conduit Doctor") { model.showDiagnostics = true }
                    Button("Open Resource Deck") { model.showResources = true }
                    Spacer()
                }
                Text("Conduit records process facts and Git state, but does not treat terminal prose as completion evidence.")
                    .font(.caption)
                    .foregroundStyle(palette.dim)
            }

            HStack {
                Spacer()
                Button("Save", action: model.saveSettings)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .padding()
        .tint(palette.accent)
        .background(palette.app)
        .scrollContentBackground(.hidden)
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
