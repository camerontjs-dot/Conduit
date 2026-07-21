#if os(macOS)
import AppKit
import ConduitCore
import SwiftUI

struct WorkspaceHeader: View {
    @EnvironmentObject private var model: AppModel
    let project: MainframeProject

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.metadata.title).font(.headline)
                Text(project.path.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            ForEach(model.enabledAgents) { agent in
                Button(agent.name) { model.launch(agent: agent) }
                    .buttonStyle(.bordered)
                    .help("Launch \(agent.name) in \(project.metadata.title)")
            }
            Button {
                model.showContext.toggle()
            } label: {
                Image(systemName: "sidebar.trailing")
            }
            .help("Toggle project context")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

struct SessionBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.sessionsForSelectedProject) { runtime in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(runtime.controller.isRunning ? .green : .secondary)
                            .frame(width: 7, height: 7)
                        Button(runtime.controller.terminalTitle) {
                            model.activeSessionID = runtime.id
                        }
                        .buttonStyle(.plain)
                        Button {
                            model.closeSession(runtime)
                        } label: {
                            Image(systemName: "xmark").font(.caption2)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(runtime.id == model.activeSessionID ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
                    .clipShape(Capsule())
                }
                Button {
                    model.launchDefaultShell()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .background(.bar)
    }
}

struct ContextPanel: View {
    let project: MainframeProject
    @State private var markdown = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Project Context", systemImage: "doc.text")
                    .font(.headline)
                Spacer()
                Button {
                    NSWorkspace.shared.open(project.path)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Open in Finder")
            }
            .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let goal = project.metadata.goal {
                        contextSection("Goal", goal)
                    }
                    if let next = project.metadata.nextAction {
                        contextSection("Next action", next)
                    }
                    if let state = project.metadata.projectState ?? project.metadata.status {
                        contextSection("State", state)
                    }
                    Divider()
                    Text(markdown.isEmpty ? "No README.md was found for this workspace." : markdown)
                        .textSelection(.enabled)
                        .font(.system(.body, design: .monospaced))
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: project.id) {
            guard let readme = project.readmePath else {
                markdown = ""
                return
            }
            markdown = (try? String(contentsOf: readme, encoding: .utf8)) ?? "Unable to read \(readme.path)"
        }
    }

    private func contextSection(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}
#endif
