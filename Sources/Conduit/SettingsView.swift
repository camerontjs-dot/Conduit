#if os(macOS)
import ConduitCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("MainFrame") {
                HStack {
                    Text(model.settings.mainframeRoot?.path ?? "Not configured")
                        .lineLimit(1)
                        .foregroundStyle(model.settings.mainframeRoot == nil ? .secondary : .primary)
                    Spacer()
                    Button("Choose…", action: model.chooseMainframeRoot)
                }
                Toggle("Show project context by default", isOn: $model.settings.showContextByDefault)
                Toggle("Restore session definitions on launch", isOn: $model.settings.restoreSessions)
                    .disabled(true)
                    .help("Reserved for the next persistence pass; terminal processes are never silently resurrected.")
            }

            Section("Agent CLIs") {
                ForEach($model.settings.agents) { $agent in
                    HStack {
                        Toggle("", isOn: $agent.enabled).labelsHidden()
                        TextField("Name", text: $agent.name).frame(width: 95)
                        TextField("Command", text: $agent.command)
                        TextField("Arguments", text: Binding(
                            get: { agent.arguments.joined(separator: " ") },
                            set: { agent.arguments = $0.split(separator: " ").map(String.init) }
                        ))
                        .frame(width: 150)
                        Button(role: .destructive) {
                            model.settings.agents.removeAll { $0.id == agent.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add Agent") {
                    model.settings.agents.append(AgentProfile(name: "Agent", command: ""))
                }
            }

            HStack {
                Spacer()
                Button("Save", action: model.saveSettings)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
#endif
